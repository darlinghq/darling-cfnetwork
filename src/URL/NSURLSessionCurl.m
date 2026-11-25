//
//  NSURLSessionCurl.m
//  CFNetwork
//
//  One libcurl multi handle, driven by a dedicated thread, carries every
//  NSURLSession transfer. The design follows swift-corelibs-foundation's
//  URLSession (Apache License 2.0 with Runtime Library Exception).
//

#import "NSURLSessionCurl.h"
#import <Foundation/NSArray.h>
#import <Foundation/NSString.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSValue.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

static const char kCurlLibraryPath[] = "/usr/lib/libcurl.4.dylib";

// Upper bound for one curl_multi_wait; curl shortens it to its own timers.
static const int kIdleWaitMilliseconds = 10000;

static _NSURLSessionCurlAPI curlAPI;
static NSString *curlLoadError = nil;

static struct {
    CURLcode (*global_init)(long flags);
    CURLM *(*multi_init)(void);
    CURLMcode (*multi_add_handle)(CURLM *multi, CURL *easy);
    CURLMcode (*multi_remove_handle)(CURLM *multi, CURL *easy);
    CURLMcode (*multi_perform)(CURLM *multi, int *running);
    CURLMcode (*multi_wait)(CURLM *multi, struct curl_waitfd extra[], unsigned int extraCount, int timeoutMs, int *numfds);
    CURLMsg *(*multi_info_read)(CURLM *multi, int *queued);
} multiAPI;

// A socket the transport thread waits on besides libcurl's own.
@interface _NSURLSessionCurlWatch : NSObject {
@public
    curl_socket_t _socket;
    short _events;
    void (^_handler)(short events);
}
@end

@implementation _NSURLSessionCurlWatch
- (void)dealloc
{
    [_handler release];
    [super dealloc];
}
@end

static CURLM *multi = NULL;
// Only touched on the transport thread.
static NSMutableArray *watches = nil;
static int wakeFds[2] = { -1, -1 };
static pthread_mutex_t pendingLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray *pendingBlocks = nil;

#define LOAD(table, field, name) \
    if ((table.field = dlsym(lib, name)) == NULL) \
        return [[NSString alloc] initWithFormat:@"%s lacks %s", kCurlLibraryPath, name]

static NSString *loadCurl(void)
{
    void *lib = dlopen(kCurlLibraryPath, RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL)
        return [[NSString alloc] initWithFormat:@"cannot load %s: %s", kCurlLibraryPath, dlerror()];

    LOAD(curlAPI, easy_init, "curl_easy_init");
    LOAD(curlAPI, easy_setopt, "curl_easy_setopt");
    LOAD(curlAPI, easy_getinfo, "curl_easy_getinfo");
    LOAD(curlAPI, easy_pause, "curl_easy_pause");
    LOAD(curlAPI, easy_cleanup, "curl_easy_cleanup");
    LOAD(curlAPI, easy_strerror, "curl_easy_strerror");
    LOAD(curlAPI, slist_append, "curl_slist_append");
    LOAD(curlAPI, slist_free_all, "curl_slist_free_all");
    LOAD(curlAPI, easy_send, "curl_easy_send");
    LOAD(curlAPI, easy_recv, "curl_easy_recv");
    LOAD(multiAPI, global_init, "curl_global_init");
    LOAD(multiAPI, multi_init, "curl_multi_init");
    LOAD(multiAPI, multi_add_handle, "curl_multi_add_handle");
    LOAD(multiAPI, multi_remove_handle, "curl_multi_remove_handle");
    LOAD(multiAPI, multi_perform, "curl_multi_perform");
    LOAD(multiAPI, multi_wait, "curl_multi_wait");
    LOAD(multiAPI, multi_info_read, "curl_multi_info_read");

    CURLcode rc = multiAPI.global_init(CURL_GLOBAL_ALL);
    if (rc != CURLE_OK)
        return [[NSString alloc] initWithFormat:@"curl_global_init failed: %s", curlAPI.easy_strerror(rc)];
    return nil;
}

static void drainWakePipe(void)
{
    char buffer[64];
    while (read(wakeFds[0], buffer, sizeof(buffer)) > 0)
        ;
}

static void runPendingBlocks(void)
{
    pthread_mutex_lock(&pendingLock);
    NSArray *blocks = pendingBlocks;
    pendingBlocks = [[NSMutableArray alloc] init];
    pthread_mutex_unlock(&pendingLock);

    for (void (^block)(void) in blocks)
        block();
    [blocks release];
}

static BOOL hasPendingBlocks(void)
{
    pthread_mutex_lock(&pendingLock);
    BOOL result = [pendingBlocks count] != 0;
    pthread_mutex_unlock(&pendingLock);
    return result;
}

static void deliverCompletions(void)
{
    CURLMsg *message;
    int queued;
    while ((message = multiAPI.multi_info_read(multi, &queued)) != NULL)
    {
        if (message->msg != CURLMSG_DONE)
            continue;
        CURL *easy = message->easy_handle;
        CURLcode code = message->data.result;
        id <_NSURLSessionCurlTransfer> transfer = nil;
        curlAPI.easy_getinfo(easy, CURLINFO_PRIVATE, (char **)&transfer);
        if (![transfer respondsToSelector:@selector(_curlTransferKeepsHandle)] || ![transfer _curlTransferKeepsHandle])
            multiAPI.multi_remove_handle(multi, easy);
        [transfer _curlTransferDidCompleteWithCode:code];
    }
}

static void *transportThread(void *unused)
{
    for (;;)
    {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        runPendingBlocks();

        int running;
        multiAPI.multi_perform(multi, &running);
        deliverCompletions();

        if (!hasPendingBlocks())
        {
            // The wake pipe first, then the watched sockets.
            NSUInteger count = [watches count];
            struct curl_waitfd *waits = calloc(count + 1, sizeof(struct curl_waitfd));
            waits[0].fd = wakeFds[0];
            waits[0].events = CURL_WAIT_POLLIN;
            for (NSUInteger i = 0; i < count; i++)
            {
                _NSURLSessionCurlWatch *watch = [watches objectAtIndex:i];
                waits[i + 1].fd = watch->_socket;
                waits[i + 1].events = watch->_events;
            }
            multiAPI.multi_wait(multi, waits, (unsigned int)count + 1, kIdleWaitMilliseconds, NULL);
            if (waits[0].revents != 0)
                drainWakePipe();
            // A handler may watch or unwatch sockets, so the matches are
            // collected first.
            NSMutableArray *ready = [NSMutableArray array];
            NSMutableArray *readyEvents = [NSMutableArray array];
            for (NSUInteger i = 0; i < count; i++)
            {
                if (waits[i + 1].revents == 0)
                    continue;
                [ready addObject:[watches objectAtIndex:i]];
                [readyEvents addObject:[NSNumber numberWithShort:waits[i + 1].revents]];
            }
            free(waits);
            for (NSUInteger i = 0; i < [ready count]; i++)
            {
                _NSURLSessionCurlWatch *watch = [ready objectAtIndex:i];
                if ([watches indexOfObjectIdenticalTo:watch] == NSNotFound)
                    continue;
                void (^handler)(short) = [[watch->_handler retain] autorelease];
                handler([[readyEvents objectAtIndex:i] shortValue]);
            }
        }
        [pool drain];
    }
    return NULL;
}

static void startTransport(void)
{
    curlLoadError = loadCurl();
    if (curlLoadError != nil)
        return;

    multi = multiAPI.multi_init();
    pendingBlocks = [[NSMutableArray alloc] init];
    watches = [[NSMutableArray alloc] init];
    if (multi == NULL || pipe(wakeFds) != 0)
    {
        curlLoadError = @"cannot create the libcurl multi handle";
        return;
    }
    fcntl(wakeFds[0], F_SETFL, O_NONBLOCK);
    fcntl(wakeFds[1], F_SETFL, O_NONBLOCK);
    fcntl(wakeFds[0], F_SETFD, FD_CLOEXEC);
    fcntl(wakeFds[1], F_SETFD, FD_CLOEXEC);

    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attributes, transportThread, NULL) != 0)
        curlLoadError = @"cannot start the NSURLSession transport thread";
    pthread_attr_destroy(&attributes);
}

const _NSURLSessionCurlAPI *_NSURLSessionCurlGetAPI(NSString **errorDescription)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        startTransport();
    });
    if (curlLoadError != nil)
    {
        *errorDescription = curlLoadError;
        return NULL;
    }
    return &curlAPI;
}

void _NSURLSessionCurlPerform(void (^block)(void))
{
    void (^copy)(void) = [block copy];
    pthread_mutex_lock(&pendingLock);
    [pendingBlocks addObject:copy];
    pthread_mutex_unlock(&pendingLock);
    [copy release];

    char byte = 0;
    write(wakeFds[1], &byte, 1);
}

CURLMcode _NSURLSessionCurlAddHandle(CURL *easy)
{
    return multiAPI.multi_add_handle(multi, easy);
}

void _NSURLSessionCurlRemoveHandle(CURL *easy)
{
    multiAPI.multi_remove_handle(multi, easy);
}

static NSUInteger indexOfWatch(curl_socket_t socket)
{
    for (NSUInteger i = 0; i < [watches count]; i++)
    {
        if (((_NSURLSessionCurlWatch *)[watches objectAtIndex:i])->_socket == socket)
            return i;
    }
    return NSNotFound;
}

void _NSURLSessionCurlWatchSocket(curl_socket_t socket, short events, void (^handler)(short events))
{
    _NSURLSessionCurlWatch *watch = [[_NSURLSessionCurlWatch alloc] init];
    watch->_socket = socket;
    watch->_events = events;
    watch->_handler = [handler copy];
    NSUInteger index = indexOfWatch(socket);
    if (index != NSNotFound)
        [watches replaceObjectAtIndex:index withObject:watch];
    else
        [watches addObject:watch];
    [watch release];
}

void _NSURLSessionCurlUnwatchSocket(curl_socket_t socket)
{
    NSUInteger index = indexOfWatch(socket);
    if (index != NSNotFound)
        [watches removeObjectAtIndex:index];
}

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
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
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

static CURLM *multi = NULL;
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
            struct curl_waitfd wake = { .fd = wakeFds[0], .events = CURL_WAIT_POLLIN, .revents = 0 };
            multiAPI.multi_wait(multi, &wake, 1, kIdleWaitMilliseconds, NULL);
            if (wake.revents != 0)
                drainWakePipe();
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

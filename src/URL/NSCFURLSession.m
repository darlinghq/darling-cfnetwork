//
//  NSCFURLSession.m
//  CFNetwork
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//
//  Data tasks run on libcurl (see NSURLSessionCurl.m). Redirect handling, the
//  libcurl error mapping and the response-disposition pause follow
//  swift-corelibs-foundation's URLSession (Apache License 2.0 with Runtime
//  Library Exception).
//

#import "NSCFURLSession.h"
#import "NSURLSessionCurl.h"
#import "NSURLRequestInternal.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSException.h>
#import <Foundation/NSLock.h>
#import <Foundation/NSOperation.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSURLError.h>
#import <Foundation/NSURLResponse.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdlib.h>
#include <sys/utsname.h>

// swift-corelibs-foundation's limit; Apple does not document one.
static const NSUInteger kMaximumRedirects = 20;

typedef void (^DataTaskCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error);

@interface __NSCFURLSession ()
- (NSURLSessionConfiguration *)_configurationNoCopy;
- (id)_delegateRespondingTo:(SEL)selector;
- (void)_addDelegateBlock:(void (^)(void))block;
- (void)_taskDidFinish:(NSURLSessionTask *)task;
@end

@interface __NSCFURLSessionDataTask () <_NSURLSessionCurlTransfer>
- (void)_receivedHeaderLine:(const char *)bytes length:(size_t)length;
- (size_t)_receivedBody:(const char *)bytes length:(size_t)length;
- (void)_uploadedBytes:(int64_t)uploaded;
@end

@implementation __NSCFURLSession

@synthesize delegateQueue = _delegateQueue;

- (id)initWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id <NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue
{
    if (configuration == nil)
    {
        [self release];
        [NSException raise:NSInvalidArgumentException format:@"NSURLSession requires a configuration"];
    }
    self = [super init];
    if (self)
    {
        _configuration = [configuration copy];
        _delegate = [delegate retain];
        if (queue != nil)
        {
            _delegateQueue = [queue retain];
        }
        else
        {
            _delegateQueue = [[NSOperationQueue alloc] init];
            [_delegateQueue setMaxConcurrentOperationCount:1];
        }
        _lock = [[NSLock alloc] init];
        _tasks = [[NSMutableSet alloc] init];
        _nextTaskIdentifier = 1;
    }
    return self;
}

- (void)dealloc
{
    [_configuration release];
    [_delegateQueue release];
    [_delegate release];
    [_sessionDescription release];
    [_lock release];
    [_tasks release];
    [super dealloc];
}

- (void)_markShared
{
    _isSharedSession = YES;
}

- (NSURLSessionConfiguration *)configuration
{
    return [[_configuration copy] autorelease];
}

- (NSURLSessionConfiguration *)_configurationNoCopy
{
    return _configuration;
}

- (id <NSURLSessionDelegate>)delegate
{
    [_lock lock];
    id delegate = [_delegate retain];
    [_lock unlock];
    return [delegate autorelease];
}

- (id)_delegateRespondingTo:(SEL)selector
{
    id delegate = [self delegate];
    return [delegate respondsToSelector:selector] ? delegate : nil;
}

- (NSString *)sessionDescription
{
    [_lock lock];
    NSString *description = [_sessionDescription retain];
    [_lock unlock];
    return [description autorelease];
}

- (void)setSessionDescription:(NSString *)description
{
    NSString *copy = [description copy];
    [_lock lock];
    NSString *old = _sessionDescription;
    _sessionDescription = copy;
    [_lock unlock];
    [old release];
}

- (void)_addDelegateBlock:(void (^)(void))block
{
    [_delegateQueue addOperationWithBlock:block];
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(DataTaskCompletionHandler)completionHandler
{
    if (request == nil)
    {
        [NSException raise:NSInvalidArgumentException format:@"Cannot create a data task without a request"];
    }
    [_lock lock];
    if (_invalid)
    {
        [_lock unlock];
        [NSException raise:NSGenericException format:@"Task created in a session that has been invalidated"];
    }
    __NSCFURLSessionDataTask *task = [[__NSCFURLSessionDataTask alloc] _initWithSession:self request:request identifier:_nextTaskIdentifier++ completionHandler:completionHandler];
    [_tasks addObject:task];
    [_lock unlock];
    return [task autorelease];
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
    return [self dataTaskWithRequest:request completionHandler:nil];
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(DataTaskCompletionHandler)completionHandler
{
    return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
{
    return [self dataTaskWithURL:url completionHandler:nil];
}

- (NSURLSessionDataTask *)dataTaskWithHTTPGetRequest:(NSURL *)url
{
    return [self dataTaskWithURL:url completionHandler:nil];
}

- (NSURLSessionDataTask *)dataTaskWithHTTPGetRequest:(NSURL *)url completionHandler:(DataTaskCompletionHandler)completionHandler
{
    return [self dataTaskWithURL:url completionHandler:completionHandler];
}

- (void)getTasksWithCompletionHandler:(void (^)(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks))completionHandler
{
    NSMutableArray *dataTasks = [NSMutableArray array];
    [_lock lock];
    for (NSURLSessionTask *task in _tasks)
    {
        if ([task state] != NSURLSessionTaskStateCompleted)
            [dataTasks addObject:task];
    }
    [_lock unlock];
    [self _addDelegateBlock:^{
        completionHandler(dataTasks, [NSArray array], [NSArray array]);
    }];
}

// Returns YES if the caller must deliver the invalidation.
- (BOOL)_invalidateLocked
{
    if (_invalid)
        return NO;
    _invalid = YES;
    return [_tasks count] == 0;
}

- (void)_deliverInvalidation
{
    [self _addDelegateBlock:^{
        id delegate = [self _delegateRespondingTo:@selector(URLSession:didBecomeInvalidWithError:)];
        [delegate URLSession:self didBecomeInvalidWithError:nil];
        [_lock lock];
        id old = _delegate;
        _delegate = nil;
        [_lock unlock];
        [old release];
    }];
}

- (void)finishTasksAndInvalidate
{
    if (_isSharedSession)
        return;
    [_lock lock];
    BOOL deliver = [self _invalidateLocked];
    [_lock unlock];
    if (deliver)
        [self _deliverInvalidation];
}

- (void)invalidateAndCancel
{
    if (_isSharedSession)
        return;
    [_lock lock];
    BOOL deliver = [self _invalidateLocked];
    NSArray *tasks = [_tasks allObjects];
    [_lock unlock];
    for (NSURLSessionTask *task in tasks)
        [task cancel];
    if (deliver)
        [self _deliverInvalidation];
}

// Called on the delegate queue after the task's last callback.
- (void)_taskDidFinish:(NSURLSessionTask *)task
{
    [_lock lock];
    [_tasks removeObject:task];
    BOOL deliver = _invalid && [_tasks count] == 0;
    [_lock unlock];
    if (deliver)
        [self _deliverInvalidation];
}

@end

static NSString *defaultUserAgent(void)
{
    static NSString *agent = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = [[NSProcessInfo processInfo] processName];
        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (version == nil)
            version = @"(unknown version)";
        int32_t cfnetwork = NSVersionOfRunTimeLibrary("CFNetwork");
        struct utsname host;
        uname(&host);
        agent = [[NSString alloc] initWithFormat:@"%@/%@ CFNetwork/%d.%d.%d Darwin/%s", name, version,
                 cfnetwork >> 16, (cfnetwork >> 8) & 0xff, cfnetwork & 0xff, host.release];
    });
    return agent;
}

static NSInteger errorCodeForCurlCode(CURLcode code)
{
    switch (code)
    {
        case CURLE_UNSUPPORTED_PROTOCOL:
            return NSURLErrorUnsupportedURL;
        case CURLE_URL_MALFORMAT:
            return NSURLErrorBadURL;
        case CURLE_COULDNT_RESOLVE_HOST:
        case CURLE_COULDNT_RESOLVE_PROXY:
            return NSURLErrorCannotFindHost;
        case CURLE_COULDNT_CONNECT:
            return NSURLErrorCannotConnectToHost;
        case CURLE_OPERATION_TIMEDOUT:
            return NSURLErrorTimedOut;
        case CURLE_SEND_ERROR:
        case CURLE_RECV_ERROR:
        case CURLE_PARTIAL_FILE:
            return NSURLErrorNetworkConnectionLost;
        case CURLE_GOT_NOTHING:
        case CURLE_WEIRD_SERVER_REPLY:
            return NSURLErrorBadServerResponse;
        case CURLE_BAD_CONTENT_ENCODING:
            return NSURLErrorCannotDecodeContentData;
        case CURLE_PEER_FAILED_VERIFICATION:
            return NSURLErrorServerCertificateUntrusted;
        case CURLE_SSL_CONNECT_ERROR:
        case CURLE_SSL_CIPHER:
        case CURLE_SSL_CACERT_BADFILE:
        case CURLE_SSL_ENGINE_NOTFOUND:
        case CURLE_SSL_ENGINE_SETFAILED:
            return NSURLErrorSecureConnectionFailed;
        case CURLE_SSL_CERTPROBLEM:
            return NSURLErrorClientCertificateRejected;
        default:
            return NSURLErrorUnknown;
    }
}

static size_t headerCallback(char *buffer, size_t size, size_t count, void *task)
{
    [(__NSCFURLSessionDataTask *)task _receivedHeaderLine:buffer length:size * count];
    return size * count;
}

static size_t writeCallback(char *buffer, size_t size, size_t count, void *task)
{
    return [(__NSCFURLSessionDataTask *)task _receivedBody:buffer length:size * count];
}

static int progressCallback(void *task, curl_off_t downloadTotal, curl_off_t downloaded, curl_off_t uploadTotal, curl_off_t uploaded)
{
    [(__NSCFURLSessionDataTask *)task _uploadedBytes:uploaded];
    return 0;
}

static BOOL isRedirectStatus(NSInteger status)
{
    return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
}

// CR or LF would let a field add header lines or split the request.
static BOOL isValidHeaderField(NSString *name, NSString *value)
{
    static NSCharacterSet *badNameCharacters, *badValueCharacters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        badNameCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"\r\n: \t"] retain];
        badValueCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"\r\n"] retain];
    });
    return [name length] != 0 &&
        [name rangeOfCharacterFromSet:badNameCharacters].location == NSNotFound &&
        [value rangeOfCharacterFromSet:badValueCharacters].location == NSNotFound;
}

static NSInteger effectivePort(NSURL *url)
{
    if ([url port] != nil)
        return [[url port] integerValue];
    return [[[url scheme] lowercaseString] isEqualToString:@"https"] ? 443 : 80;
}

static BOOL isSameOrigin(NSURL *a, NSURL *b)
{
    if ([a host] == nil || [b host] == nil)
        return NO;
    return [[a scheme] caseInsensitiveCompare:[b scheme]] == NSOrderedSame &&
        [[a host] caseInsensitiveCompare:[b host]] == NSOrderedSame &&
        effectivePort(a) == effectivePort(b);
}

@implementation __NSCFURLSessionDataTask

- (id)_initWithSession:(__NSCFURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)identifier completionHandler:(DataTaskCompletionHandler)completionHandler
{
    self = [super init];
    if (self)
    {
        _session = [session retain];
        _taskIdentifier = identifier;
        _originalRequest = [request copy];
        _currentRequest = [_originalRequest retain];
        _completionHandler = [completionHandler copy];
        _state = NSURLSessionTaskStateSuspended;
        _suspendCount = 1;
        _countOfBytesExpectedToSend = [[request HTTPBody] length];
        _pendingHeaderLines = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_session release];
    [_originalRequest release];
    [_currentRequest release];
    [_response release];
    [_taskDescription release];
    [_error release];
    [_completionHandler release];
    [_pendingHTTPVersion release];
    [_pendingHeaderLines release];
    [_receivedData release];
    [_redirectBody release];
    [_redirectRequest release];
    [_redirectResponse release];
    free(_curlErrorBuffer);
    [super dealloc];
}

- (NSUInteger)taskIdentifier
{
    return _taskIdentifier;
}

- (NSURLRequest *)originalRequest
{
    return _originalRequest;
}

#define LOCKED_GETTER(type, name, ivar) \
- (type)name \
{ \
    @synchronized(self) { return ivar; } \
}

#define LOCKED_OBJECT_GETTER(type, name, ivar) \
- (type)name \
{ \
    @synchronized(self) { return [[ivar retain] autorelease]; } \
}

LOCKED_OBJECT_GETTER(NSURLRequest *, currentRequest, _currentRequest)
LOCKED_OBJECT_GETTER(NSURLResponse *, response, _response)
LOCKED_OBJECT_GETTER(NSError *, error, _error)
LOCKED_OBJECT_GETTER(NSString *, taskDescription, _taskDescription)
LOCKED_GETTER(NSURLSessionTaskState, state, _state)
LOCKED_GETTER(int64_t, countOfBytesReceived, _countOfBytesReceived)
LOCKED_GETTER(int64_t, countOfBytesSent, _countOfBytesSent)
LOCKED_GETTER(int64_t, countOfBytesExpectedToSend, _countOfBytesExpectedToSend)
LOCKED_GETTER(int64_t, countOfBytesExpectedToReceive, _countOfBytesExpectedToReceive)

- (void)setTaskDescription:(NSString *)taskDescription
{
    NSString *copy = [taskDescription copy];
    @synchronized(self)
    {
        [_taskDescription release];
        _taskDescription = copy;
    }
}

- (NSError *)_errorWithCode:(NSInteger)code description:(NSString *)description
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (description != nil)
        [info setObject:description forKey:NSLocalizedDescriptionKey];
    NSURL *url = [[self currentRequest] URL];
    if (url != nil)
    {
        [info setObject:url forKey:NSURLErrorFailingURLErrorKey];
        [info setObject:[url absoluteString] forKey:NSURLErrorFailingURLStringErrorKey];
    }
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:info];
}

- (void)resume
{
    BOOL start;
    @synchronized(self)
    {
        if (_state == NSURLSessionTaskStateCompleted || _state == NSURLSessionTaskStateCanceling || _suspendCount == 0)
            return;
        if (--_suspendCount > 0)
            return;
        _state = NSURLSessionTaskStateRunning;
        start = !_started;
        _started = YES;
    }

    NSString *loadError = nil;
    if (_NSURLSessionCurlGetAPI(&loadError) == NULL)
    {
        [self _finishWithError:[self _errorWithCode:NSURLErrorUnknown description:loadError]];
        return;
    }
    _NSURLSessionCurlPerform(^{
        if (start)
            [self _startTransferWithRequest:_currentRequest];
        else
            [self _updatePause];
    });
}

- (void)suspend
{
    BOOL started;
    @synchronized(self)
    {
        if (_state == NSURLSessionTaskStateCompleted || _state == NSURLSessionTaskStateCanceling)
            return;
        if (++_suspendCount > 1)
            return;
        _state = NSURLSessionTaskStateSuspended;
        started = _started;
    }
    if (started)
    {
        _NSURLSessionCurlPerform(^{
            [self _updatePause];
        });
    }
}

- (void)cancel
{
    BOOL started;
    @synchronized(self)
    {
        if (_state == NSURLSessionTaskStateCompleted || _state == NSURLSessionTaskStateCanceling)
            return;
        _state = NSURLSessionTaskStateCanceling;
        started = _started;
    }
    NSError *error = [self _errorWithCode:NSURLErrorCancelled description:@"cancelled"];
    if (started)
    {
        _NSURLSessionCurlPerform(^{
            [self _abortTransfer];
            [self _finishWithError:error];
        });
    }
    else
    {
        [self _finishWithError:error];
    }
}

// The methods below run on the transport thread unless noted.

- (const _NSURLSessionCurlAPI *)_curl
{
    NSString *unused;
    return _NSURLSessionCurlGetAPI(&unused);
}

- (void)_updatePause
{
    if (_easy == NULL)
        return;
    BOOL suspended;
    @synchronized(self)
    {
        suspended = _suspendCount > 0;
    }
    int mask = suspended ? CURLPAUSE_ALL : (_writePaused ? CURLPAUSE_RECV : CURLPAUSE_CONT);
    [self _curl]->easy_pause(_easy, mask);
}

- (void)_releaseEasy
{
    const _NSURLSessionCurlAPI *curl = [self _curl];
    if (_easy != NULL)
    {
        curl->easy_cleanup(_easy);
        _easy = NULL;
    }
    if (_headerList != NULL)
    {
        curl->slist_free_all(_headerList);
        _headerList = NULL;
    }
    [_uploadBody release];
    _uploadBody = nil;
}

- (void)_abortTransfer
{
    if (_easy != NULL)
        _NSURLSessionCurlRemoveHandle(_easy);
    [self _releaseEasy];
}

- (void)_setCurrentRequest:(NSURLRequest *)request
{
    @synchronized(self)
    {
        if (request != _currentRequest)
        {
            [_currentRequest release];
            _currentRequest = [request copy];
        }
    }
}

- (NSTimeInterval)_idleTimeoutForRequest:(NSURLRequest *)request
{
    // NSURLRequest cannot tell whether its timeout was set explicitly, so the
    // default value defers to the session configuration.
    NSTimeInterval timeout = [request timeoutInterval];
    if (timeout == [NSURLRequest defaultTimeoutInterval])
        timeout = [[_session _configurationNoCopy] timeoutIntervalForRequest];
    return timeout;
}

- (struct curl_slist *)_headerListForRequest:(NSURLRequest *)request
{
    const _NSURLSessionCurlAPI *curl = [self _curl];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSMutableSet *lowercaseNames = [NSMutableSet set];
    NSDictionary *sources[2] = { [request allHTTPHeaderFields], [[_session _configurationNoCopy] HTTPAdditionalHeaders] };
    for (int i = 0; i < 2; i++)
    {
        for (NSString *name in sources[i])
        {
            if (!isValidHeaderField(name, [sources[i] objectForKey:name]))
                continue;
            NSString *lowercase = [name lowercaseString];
            if ([lowercaseNames containsObject:lowercase])
                continue;
            [lowercaseNames addObject:lowercase];
            [headers setObject:[sources[i] objectForKey:name] forKey:name];
        }
    }

    struct curl_slist *list = NULL;
    for (NSString *name in headers)
    {
        NSString *value = [headers objectForKey:name];
        // "Name;" is libcurl's spelling of a header with an empty value.
        NSString *line = [value length] != 0 ? [NSString stringWithFormat:@"%@: %@", name, value] : [name stringByAppendingString:@";"];
        list = curl->slist_append(list, [line UTF8String]);
    }
    if (![lowercaseNames containsObject:@"expect"])
        list = curl->slist_append(list, "Expect:");
    if (![lowercaseNames containsObject:@"user-agent"])
        list = curl->slist_append(list, [[@"User-Agent: " stringByAppendingString:defaultUserAgent()] UTF8String]);
    return list;
}

- (void)_startTransferWithRequest:(NSURLRequest *)request
{
    if (_finished)
        return;
    [self _setCurrentRequest:request];
    _pendingStatusCode = 0;
    [_pendingHeaderLines removeAllObjects];
    _writePaused = NO;
    _transferDoneWhileAwaiting = NO;

    NSURL *url = [request URL];
    NSString *scheme = [[url scheme] lowercaseString];
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]))
    {
        [self _finishWithError:[self _errorWithCode:NSURLErrorUnsupportedURL description:@"unsupported URL"]];
        return;
    }
    if ([request HTTPBodyStream] != nil)
    {
        [self _finishWithError:[self _errorWithCode:NSURLErrorUnknown description:@"HTTPBodyStream request bodies are not supported yet"]];
        return;
    }

    NSURLSessionConfiguration *configuration = [_session _configurationNoCopy];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_resourceDeadline == 0 && [configuration timeoutIntervalForResource] > 0)
        _resourceDeadline = now + [configuration timeoutIntervalForResource];
    if (_resourceDeadline != 0 && now >= _resourceDeadline)
    {
        [self _finishWithError:[self _errorWithCode:NSURLErrorTimedOut description:@"The resource timeout expired"]];
        return;
    }

    const _NSURLSessionCurlAPI *curl = [self _curl];
    CURL *easy = curl->easy_init();
    if (easy == NULL)
    {
        [self _finishWithError:[self _errorWithCode:NSURLErrorUnknown description:@"curl_easy_init failed"]];
        return;
    }
    _easy = easy;
    if (_curlErrorBuffer == NULL)
        _curlErrorBuffer = malloc(CURL_ERROR_SIZE);
    _curlErrorBuffer[0] = '\0';

    curl->easy_setopt(easy, CURLOPT_URL, [[url absoluteString] UTF8String]);
    curl->easy_setopt(easy, CURLOPT_PRIVATE, self);
    curl->easy_setopt(easy, CURLOPT_ERRORBUFFER, _curlErrorBuffer);
    curl->easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl->easy_setopt(easy, CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    curl->easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl->easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
    curl->easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, "");
    curl->easy_setopt(easy, CURLOPT_HEADERFUNCTION, headerCallback);
    curl->easy_setopt(easy, CURLOPT_HEADERDATA, self);
    curl->easy_setopt(easy, CURLOPT_WRITEFUNCTION, writeCallback);
    curl->easy_setopt(easy, CURLOPT_WRITEDATA, self);

    NSString *method = [[request HTTPMethod] uppercaseString];
    NSData *body = [request HTTPBody];
    if ([body length] != 0)
    {
        _uploadBody = [body retain];
        curl->easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)[body length]);
        curl->easy_setopt(easy, CURLOPT_POSTFIELDS, [body bytes]);
        if (![method isEqualToString:@"POST"])
            curl->easy_setopt(easy, CURLOPT_CUSTOMREQUEST, [method UTF8String]);
        curl->easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
        curl->easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, progressCallback);
        curl->easy_setopt(easy, CURLOPT_XFERINFODATA, self);
    }
    else if ([method isEqualToString:@"GET"])
    {
        curl->easy_setopt(easy, CURLOPT_HTTPGET, 1L);
    }
    else if ([method isEqualToString:@"HEAD"])
    {
        curl->easy_setopt(easy, CURLOPT_NOBODY, 1L);
    }
    else if ([method isEqualToString:@"POST"])
    {
        curl->easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)0);
        curl->easy_setopt(easy, CURLOPT_POSTFIELDS, "");
    }
    else
    {
        curl->easy_setopt(easy, CURLOPT_CUSTOMREQUEST, [method UTF8String]);
    }
    @synchronized(self)
    {
        _countOfBytesSent = 0;
        _countOfBytesExpectedToSend = [body length];
    }

    _headerList = [self _headerListForRequest:request];
    curl->easy_setopt(easy, CURLOPT_HTTPHEADER, _headerList);

    NSTimeInterval idle = [self _idleTimeoutForRequest:request];
    if (idle > 0)
    {
        curl->easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, (long)(idle * 1000));
        curl->easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 1L);
        curl->easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, (long)ceil(idle));
    }
    if (_resourceDeadline != 0)
        curl->easy_setopt(easy, CURLOPT_TIMEOUT_MS, (long)ceil((_resourceDeadline - now) * 1000));

    CURLMcode added = _NSURLSessionCurlAddHandle(easy);
    if (added != CURLM_OK)
    {
        [self _releaseEasy];
        [self _finishWithError:[self _errorWithCode:NSURLErrorUnknown description:[NSString stringWithFormat:@"curl_multi_add_handle failed (%d)", added]]];
        return;
    }
    [self _updatePause];
}

- (void)_receivedHeaderLine:(const char *)bytes length:(size_t)length
{
    NSString *raw = [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
    [raw release];

    if ([line hasPrefix:@"HTTP/"])
    {
        NSArray *parts = [line componentsSeparatedByString:@" "];
        if ([parts count] < 2)
            return;
        [_pendingHTTPVersion release];
        _pendingHTTPVersion = [[parts objectAtIndex:0] copy];
        _pendingStatusCode = [[parts objectAtIndex:1] integerValue];
        [_pendingHeaderLines removeAllObjects];
        return;
    }
    // Trailers after a chunked body arrive with no status line before them.
    if (_pendingStatusCode == 0)
        return;
    if ([line length] == 0)
    {
        if (_pendingStatusCode >= 100 && _pendingStatusCode < 200)
            return;
        [self _headersComplete];
        return;
    }
    unichar first = [line characterAtIndex:0];
    if ((first == ' ' || first == '\t') && [_pendingHeaderLines count] != 0)
    {
        NSString *folded = [[_pendingHeaderLines lastObject] stringByAppendingFormat:@" %@", [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        [_pendingHeaderLines replaceObjectAtIndex:[_pendingHeaderLines count] - 1 withObject:folded];
        return;
    }
    [_pendingHeaderLines addObject:line];
}

- (NSDictionary *)_pendingHeaderFields
{
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSMutableDictionary *namesByLowercase = [NSMutableDictionary dictionary];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *line in _pendingHeaderLines)
    {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:whitespace];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:whitespace];
        NSString *existingName = [namesByLowercase objectForKey:[name lowercaseString]];
        if (existingName != nil)
        {
            NSString *joined = [NSString stringWithFormat:@"%@, %@", [fields objectForKey:existingName], value];
            [fields setObject:joined forKey:existingName];
        }
        else
        {
            [namesByLowercase setObject:name forKey:[name lowercaseString]];
            [fields setObject:value forKey:name];
        }
    }
    return fields;
}

- (NSURLRequest *)_redirectRequestForResponse:(NSHTTPURLResponse *)response
{
    NSInteger status = [response statusCode];
    if (!isRedirectStatus(status))
        return nil;
    NSString *location = [[response allHeaderFields] objectForKey:@"Location"];
    if (location == nil)
        return nil;
    NSURL *target = [[NSURL URLWithString:location relativeToURL:[_currentRequest URL]] absoluteURL];
    if (target == nil)
        return nil;

    NSMutableURLRequest *request = [[_currentRequest mutableCopy] autorelease];
    [request setURL:target];
    NSMutableSet *dropped = [NSMutableSet set];
    if (!isSameOrigin([_currentRequest URL], target))
        [dropped addObjectsFromArray:@[ @"authorization", @"cookie" ]];
    NSString *method = [[request HTTPMethod] uppercaseString];
    if ((status == 303 && ![method isEqualToString:@"HEAD"]) ||
        ((status == 301 || status == 302) && [method isEqualToString:@"POST"]))
    {
        [request setHTTPMethod:@"GET"];
        [request setHTTPBody:nil];
        [dropped addObjectsFromArray:@[ @"content-type", @"content-length", @"transfer-encoding" ]];
    }
    if ([dropped count] != 0)
    {
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        NSDictionary *current = [request allHTTPHeaderFields];
        for (NSString *name in current)
        {
            if (![dropped containsObject:[name lowercaseString]])
                [headers setObject:[current objectForKey:name] forKey:name];
        }
        [request setAllHTTPHeaderFields:headers];
    }
    return request;
}

- (void)_headersComplete
{
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[_currentRequest URL]
                                                              statusCode:_pendingStatusCode
                                                             HTTPVersion:_pendingHTTPVersion
                                                            headerFields:[self _pendingHeaderFields]] autorelease];
    _pendingStatusCode = 0;
    [_pendingHeaderLines removeAllObjects];

    NSURLRequest *redirect = [self _redirectRequestForResponse:response];
    if (redirect != nil)
    {
        _redirectRequest = [redirect retain];
        _redirectResponse = [response retain];
        // Kept in case the delegate declines the redirect.
        if ([_session _delegateRespondingTo:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)] != nil)
            _redirectBody = [[NSMutableData alloc] init];
        return;
    }
    [self _deliverResponse:response];
}

- (void)_deliverResponse:(NSURLResponse *)response
{
    @synchronized(self)
    {
        [_response release];
        _response = [response retain];
        _countOfBytesExpectedToReceive = [response expectedContentLength];
    }
    if (_completionHandler != nil)
        return;
    id delegate = [_session _delegateRespondingTo:@selector(URLSession:dataTask:didReceiveResponse:completionHandler:)];
    if (delegate == nil)
        return;

    _awaitingDisposition = YES;
    [_session _addDelegateBlock:^{
        [delegate URLSession:_session dataTask:self didReceiveResponse:response completionHandler:^(NSURLSessionResponseDisposition disposition) {
            _NSURLSessionCurlPerform(^{
                [self _applyDisposition:disposition];
            });
        }];
    }];
}

- (void)_applyDisposition:(NSURLSessionResponseDisposition)disposition
{
    if (_finished || !_awaitingDisposition)
        return;
    _awaitingDisposition = NO;

    if (disposition == NSURLSessionResponseAllow)
    {
        if (_transferDoneWhileAwaiting)
        {
            [self _transferDoneWithCode:_doneCode];
        }
        else
        {
            _writePaused = NO;
            [self _updatePause];
        }
        return;
    }

    @synchronized(self)
    {
        _state = NSURLSessionTaskStateCanceling;
    }
    [self _abortTransfer];
    if (disposition == NSURLSessionResponseCancel)
        [self _finishWithError:[self _errorWithCode:NSURLErrorCancelled description:@"cancelled"]];
    else
        [self _finishWithError:[self _errorWithCode:NSURLErrorUnknown description:[NSString stringWithFormat:@"response disposition %ld is not supported yet", (long)disposition]]];
}

- (void)_deliverData:(NSData *)data
{
    @synchronized(self)
    {
        _countOfBytesReceived += [data length];
    }
    if (_completionHandler != nil)
    {
        if (_receivedData == nil)
            _receivedData = [[NSMutableData alloc] init];
        [_receivedData appendData:data];
        return;
    }
    id delegate = [_session _delegateRespondingTo:@selector(URLSession:dataTask:didReceiveData:)];
    if (delegate != nil)
    {
        [_session _addDelegateBlock:^{
            [delegate URLSession:_session dataTask:self didReceiveData:data];
        }];
    }
}

- (size_t)_receivedBody:(const char *)bytes length:(size_t)length
{
    if (_redirectRequest != nil)
    {
        [_redirectBody appendBytes:bytes length:length];
        return length;
    }
    if (_awaitingDisposition)
    {
        _writePaused = YES;
        return CURL_WRITEFUNC_PAUSE;
    }
    [self _deliverData:[NSData dataWithBytes:bytes length:length]];
    return length;
}

- (void)_uploadedBytes:(int64_t)uploaded
{
    int64_t sent, expected, delta;
    @synchronized(self)
    {
        delta = uploaded - _countOfBytesSent;
        if (delta <= 0)
            return;
        _countOfBytesSent = uploaded;
        sent = _countOfBytesSent;
        expected = _countOfBytesExpectedToSend;
    }
    id delegate = [_session _delegateRespondingTo:@selector(URLSession:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)];
    if (delegate == nil)
        return;
    [_session _addDelegateBlock:^{
        [delegate URLSession:_session task:self didSendBodyData:delta totalBytesSent:sent totalBytesExpectedToSend:expected];
    }];
}

- (void)_curlTransferDidCompleteWithCode:(CURLcode)code
{
    if (_awaitingDisposition)
    {
        _transferDoneWhileAwaiting = YES;
        _doneCode = code;
        return;
    }
    [self _transferDoneWithCode:code];
}

- (void)_transferDoneWithCode:(CURLcode)code
{
    NSString *message = nil;
    if (code != CURLE_OK)
    {
        const char *text = (_curlErrorBuffer != NULL && _curlErrorBuffer[0] != '\0') ? _curlErrorBuffer : [self _curl]->easy_strerror(code);
        message = [NSString stringWithUTF8String:text];
    }
    [self _releaseEasy];
    _transferDoneWhileAwaiting = NO;

    if (code != CURLE_OK)
    {
        [self _finishWithError:[self _errorWithCode:errorCodeForCurlCode(code) description:message]];
        return;
    }
    if (_redirectRequest != nil)
    {
        [self _followRedirect];
        return;
    }
    if (_redirectBody != nil)
    {
        // The body of a redirect the delegate declined.
        NSData *body = [_redirectBody autorelease];
        _redirectBody = nil;
        [self _deliverData:body];
    }
    [self _finishWithError:nil];
}

- (void)_followRedirect
{
    NSURLRequest *request = [_redirectRequest autorelease];
    NSHTTPURLResponse *response = [_redirectResponse autorelease];
    _redirectRequest = nil;
    _redirectResponse = nil;

    if (++_redirectCount > kMaximumRedirects)
    {
        [self _finishWithError:[self _errorWithCode:NSURLErrorHTTPTooManyRedirects description:@"too many HTTP redirects"]];
        return;
    }

    id delegate = [_session _delegateRespondingTo:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)];
    if (delegate == nil)
    {
        [self _redirectDecided:request response:response];
        return;
    }
    [_session _addDelegateBlock:^{
        [delegate URLSession:_session task:self willPerformHTTPRedirection:response newRequest:request completionHandler:^(NSURLRequest *chosen) {
            NSURLRequest *copy = [chosen copy];
            _NSURLSessionCurlPerform(^{
                [self _redirectDecided:copy response:response];
            });
            [copy release];
        }];
    }];
}

- (void)_redirectDecided:(NSURLRequest *)request response:(NSHTTPURLResponse *)response
{
    if (_finished)
        return;
    if (request != nil)
    {
        [_redirectBody release];
        _redirectBody = nil;
        [self _startTransferWithRequest:request];
        return;
    }

    // Declined: the redirect response and its body become the result.
    [self _deliverResponse:response];
    if (_awaitingDisposition)
    {
        _transferDoneWhileAwaiting = YES;
        _doneCode = CURLE_OK;
        return;
    }
    [self _transferDoneWithCode:CURLE_OK];
}

// May run on any thread when no transfer was ever started.
- (void)_finishWithError:(NSError *)error
{
    @synchronized(self)
    {
        if (_finished)
            return;
        _finished = YES;
        _state = NSURLSessionTaskStateCompleted;
        [_error release];
        _error = [error copy];
    }
    if (_easy != NULL)
        [self _abortTransfer];

    NSData *data = nil;
    if (error == nil)
        data = _receivedData != nil ? [[_receivedData copy] autorelease] : [NSData data];
    NSURLResponse *response = [self response];
    __NSCFURLSession *session = _session;
    [session _addDelegateBlock:^{
        if (_completionHandler != nil)
        {
            _completionHandler(data, response, error);
        }
        else
        {
            id delegate = [session _delegateRespondingTo:@selector(URLSession:task:didCompleteWithError:)];
            [delegate URLSession:session task:self didCompleteWithError:error];
        }
        [session _taskDidFinish:self];
    }];
}

@end

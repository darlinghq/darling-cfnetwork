//
//  NSCFURLSessionWebSocketTask.m
//  CFNetwork
//
//  Copyright (C) 2026 Lubos Dolezel
//
//  Darling is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  WebSocket tasks (RFC 6455). libcurl makes the connection (TCP, TLS and a
//  proxy tunnel) in CURLOPT_CONNECT_ONLY mode; the opening handshake and the
//  framing are done here, over curl_easy_send and curl_easy_recv, on the
//  transport thread of NSURLSessionCurl.m.
//
//  Where RFC 6455 leaves a choice open, the behaviour is that observed on
//  macOS 26.7.3 through the public API (tests/nsurlsession-websocket-task.m):
//  the errors and close codes for each failure, the order of the delegate
//  messages, and that messages sent before the connection opens wait for it.
//  No extensions (permessage-deflate) are offered.
//

#import "NSCFURLSession.h"
#import "NSURLSessionCurl.h"
#import "NSURLSessionCurlErrors.h"
#import "NSURLRequestInternal.h"
#import <CFNetwork/CFNSURLConnection.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDateInterval.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSException.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSURLError.h>
#import <Foundation/NSURLResponse.h>
#import <Foundation/NSValue.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>

// macOS 26.7.3's default.
static const NSInteger kDefaultMaximumMessageSize = 1048576;

// How long a close started with cancelWithCloseCode:reason: waits for the
// server's close before the task completes anyway. Darling's choice: RFC 6455
// asks only that the wait be bounded.
static const int64_t kCloseWaitNanoseconds = 30 * NSEC_PER_SEC;

// RFC 6455, section 1.3.
static NSString *const kAcceptGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// A handshake response larger than this is not taken.
static const NSUInteger kMaximumHandshakeLength = 65536;

enum {
    kPhaseIdle,
    kPhaseConnecting,
    kPhaseHandshake,
    kPhaseOpen,
    kPhaseClosing,
    kPhaseFinished,
};

enum {
    kOpcodeContinuation = 0x0,
    kOpcodeText = 0x1,
    kOpcodeBinary = 0x2,
    kOpcodeClose = 0x8,
    kOpcodePing = 0x9,
    kOpcodePong = 0xA,
};

@interface __NSCFURLSession ()
- (NSURLSessionConfiguration *)_configurationNoCopy;
- (id)_delegateForTask:(NSURLSessionTask *)task respondingTo:(SEL)selector;
- (void)_addDelegateBlock:(void (^)(void))block;
- (void)_taskDidFinish:(NSURLSessionTask *)task;
@end

@protocol _NSURLSessionWebSocketMetricsDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics;
@end

// A message or ping waiting for the connection to open.
@interface _NSURLSessionWebSocketOutgoing : NSObject {
@public
    int _opcode;
    NSData *_payload;
    void (^_handler)(NSError *error);
}
@end

@implementation _NSURLSessionWebSocketOutgoing
- (void)dealloc
{
    [_payload release];
    [_handler release];
    [super dealloc];
}
@end

// A handler to call once the bytes up to _end have been written.
@interface _NSURLSessionWebSocketWrite : NSObject {
@public
    int64_t _end;
    void (^_handler)(NSError *error);
}
@end

@implementation _NSURLSessionWebSocketWrite
- (void)dealloc
{
    [_handler release];
    [super dealloc];
}
@end

static NSError *posixError(int code)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

static NSString *schemeForConnection(NSString *scheme)
{
    scheme = [scheme lowercaseString];
    if ([scheme isEqualToString:@"ws"])
        return @"http";
    if ([scheme isEqualToString:@"wss"])
        return @"https";
    return scheme;
}

static BOOL isWebSocketScheme(NSString *scheme)
{
    scheme = [scheme lowercaseString];
    return [scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"];
}

// The URL with its scheme replaced by the one of the connection it needs
// (ws by http, wss by https).
static NSURL *connectionURL(NSURL *url)
{
    NSString *scheme = [url scheme];
    NSString *absolute = [url absoluteString];
    if (scheme == nil || ![absolute hasPrefix:[scheme stringByAppendingString:@":"]])
        return url;
    NSString *rest = [absolute substringFromIndex:[scheme length]];
    return [NSURL URLWithString:[schemeForConnection(scheme) stringByAppendingString:rest]];
}

static NSString *acceptValueForKey(NSString *key)
{
    NSData *input = [[key stringByAppendingString:kAcceptGUID] dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([input bytes], (CC_LONG)[input length], digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

// The comma-separated tokens of a header value, without surrounding spaces.
static NSArray *headerTokens(NSString *value)
{
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *part in [value componentsSeparatedByString:@","])
    {
        NSString *token = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([token length] != 0)
            [tokens addObject:token];
    }
    return tokens;
}

static NSString *headerValue(NSDictionary *headers, NSString *name)
{
    for (NSString *key in headers)
    {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame)
            return [headers objectForKey:key];
    }
    return nil;
}

static BOOL containsTokenIgnoringCase(NSArray *tokens, NSString *token)
{
    for (NSString *candidate in tokens)
    {
        if ([candidate caseInsensitiveCompare:token] == NSOrderedSame)
            return YES;
    }
    return NO;
}

@implementation __NSCFURLSession (WebSocket)

- (NSURLSessionWebSocketTask *)_webSocketTaskWithRequest:(NSURLRequest *)request protocols:(NSArray *)protocols
{
    [_lock lock];
    if (_invalid)
    {
        [_lock unlock];
        [NSException raise:NSGenericException format:@"Task created in a session that has been invalidated"];
    }
    NSUInteger identifier = _nextTaskIdentifier++;
    [_lock unlock];

    __NSCFURLSessionWebSocketTask *task = [[__NSCFURLSessionWebSocketTask alloc] _initWithSession:self request:request protocols:protocols identifier:identifier];

    [_lock lock];
    [_tasks addObject:task];
    [_lock unlock];
    return [task autorelease];
}

- (NSURLSessionWebSocketTask *)webSocketTaskWithURL:(NSURL *)url protocols:(NSArray *)protocols
{
    if (url == nil || !isWebSocketScheme([url scheme]))
        [NSException raise:NSGenericException format:@"A WebSocket task needs a URL with the ws or wss scheme"];
    // As on macOS, the task's request has the URL of the connection: http for
    // ws, https for wss.
    return [self _webSocketTaskWithRequest:[NSURLRequest requestWithURL:connectionURL(url)] protocols:protocols];
}

- (NSURLSessionWebSocketTask *)webSocketTaskWithURL:(NSURL *)url
{
    return [self webSocketTaskWithURL:url protocols:@[]];
}

- (NSURLSessionWebSocketTask *)webSocketTaskWithRequest:(NSURLRequest *)request
{
    NSString *scheme = [[[request URL] scheme] lowercaseString];
    if (request == nil || !(isWebSocketScheme(scheme) || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]))
        [NSException raise:NSGenericException format:@"A WebSocket task needs a URL with the ws or wss scheme"];
    // The subprotocols are those the request offers itself.
    NSString *offered = headerValue([request allHTTPHeaderFields], @"Sec-WebSocket-Protocol");
    return [self _webSocketTaskWithRequest:request protocols:offered != nil ? headerTokens(offered) : @[]];
}

@end

@interface __NSCFURLSessionWebSocketTask () <_NSURLSessionCurlTransfer>
@end

@implementation __NSCFURLSessionWebSocketTask

- (id)_initWithSession:(__NSCFURLSession *)session request:(NSURLRequest *)request protocols:(NSArray *)protocols identifier:(NSUInteger)identifier
{
    self = [super init];
    if (self)
    {
        _session = [session retain];
        _taskIdentifier = identifier;
        _state = NSURLSessionTaskStateSuspended;
        _suspendCount = 1;
        _priority = NSURLSessionTaskPriorityDefault;
        _maximumMessageSize = kDefaultMaximumMessageSize;
        _socket = -1;
        _protocols = [protocols copy];

        unsigned char nonce[16];
        arc4random_buf(nonce, sizeof(nonce));
        _key = [[[NSData dataWithBytes:nonce length:sizeof(nonce)] base64EncodedStringWithOptions:0] retain];

        // The handshake's fields are in the task's request from the start.
        NSMutableURLRequest *handshake = [[request mutableCopy] autorelease];
        [handshake setValue:_key forHTTPHeaderField:@"Sec-WebSocket-Key"];
        [handshake setValue:@"13" forHTTPHeaderField:@"Sec-WebSocket-Version"];
        [handshake setValue:@"websocket" forHTTPHeaderField:@"Upgrade"];
        [handshake setValue:@"Upgrade" forHTTPHeaderField:@"Connection"];
        if ([protocols count] != 0)
            [handshake setValue:[protocols componentsJoinedByString:@", "] forHTTPHeaderField:@"Sec-WebSocket-Protocol"];
        _originalRequest = [handshake copy];
        _currentRequest = [handshake copy];

        _input = [[NSMutableData alloc] init];
        _output = [[NSMutableData alloc] init];
        _writeCompletions = [[NSMutableArray alloc] init];
        _waitingSends = [[NSMutableArray alloc] init];
        _receiveHandlers = [[NSMutableArray alloc] init];
        _messages = [[NSMutableArray alloc] init];
        _pongHandlers = [[NSMutableArray alloc] init];
        _settings = [[_NSURLSessionTaskSettings alloc] init];
    }
    return self;
}

- (_NSURLSessionTaskSettings *)_settings
{
    return _settings;
}

- (void)dealloc
{
    [_session release];
    [_originalRequest release];
    [_currentRequest release];
    [_response release];
    [_taskDescription release];
    [_error release];
    [_delegate release];
    [_settings release];
    [_closeReason release];
    [_key release];
    [_cookieHeader release];
    [_protocols release];
    [_input release];
    [_output release];
    [_writeCompletions release];
    [_waitingSends release];
    [_receiveHandlers release];
    [_messages release];
    [_pongHandlers release];
    [_fragments release];
    [_terminalError release];
    free(_curlErrorBuffer);
    [super dealloc];
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

- (NSUInteger)taskIdentifier
{
    return _taskIdentifier;
}

- (NSURLRequest *)originalRequest
{
    return _originalRequest;
}

LOCKED_OBJECT_GETTER(NSURLRequest *, currentRequest, _currentRequest)
LOCKED_OBJECT_GETTER(NSURLResponse *, response, _response)
LOCKED_OBJECT_GETTER(NSError *, error, _error)
LOCKED_OBJECT_GETTER(NSString *, taskDescription, _taskDescription)
LOCKED_OBJECT_GETTER(id <NSURLSessionTaskDelegate>, delegate, _delegate)
LOCKED_OBJECT_GETTER(NSData *, closeReason, _closeReason)
LOCKED_GETTER(NSURLSessionTaskState, state, _state)
LOCKED_GETTER(int64_t, countOfBytesReceived, _countOfBytesReceived)
LOCKED_GETTER(int64_t, countOfBytesSent, _countOfBytesSent)
LOCKED_GETTER(float, priority, _priority)
LOCKED_GETTER(NSInteger, maximumMessageSize, _maximumMessageSize)
LOCKED_GETTER(NSURLSessionWebSocketCloseCode, closeCode, _closeCode)

- (int64_t)countOfBytesExpectedToSend
{
    return 0;
}

- (int64_t)countOfBytesExpectedToReceive
{
    return 0;
}

- (void)setTaskDescription:(NSString *)taskDescription
{
    NSString *copy = [taskDescription copy];
    NSString *old;
    @synchronized(self)
    {
        old = _taskDescription;
        _taskDescription = copy;
    }
    [old release];
}

- (void)setDelegate:(id <NSURLSessionTaskDelegate>)delegate
{
    id old;
    [delegate retain];
    @synchronized(self)
    {
        old = _delegate;
        _delegate = delegate;
    }
    [old release];
}

- (void)setPriority:(float)priority
{
    // As for the other tasks: a value outside 0 to 1 is ignored.
    if (priority < 0 || priority > 1)
        return;
    @synchronized(self)
    {
        _priority = priority;
    }
}

- (void)setMaximumMessageSize:(NSInteger)maximumMessageSize
{
    @synchronized(self)
    {
        _maximumMessageSize = maximumMessageSize;
    }
}

// Runs block on the transport thread; NO when libcurl cannot be loaded.
- (BOOL)_perform:(void (^)(void))block
{
    NSString *unused = nil;
    if (_NSURLSessionCurlGetAPI(&unused) == NULL)
        return NO;
    _NSURLSessionCurlPerform(block);
    return YES;
}

- (const _NSURLSessionCurlAPI *)_curl
{
    NSString *unused;
    return _NSURLSessionCurlGetAPI(&unused);
}

- (void)_deliver:(void (^)(void))block
{
    [_session _addDelegateBlock:block];
}

- (NSError *)_URLErrorWithCode:(NSInteger)code description:(NSString *)description
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

- (NSError *)_cancelledError
{
    return [self _URLErrorWithCode:NSURLErrorCancelled description:@"cancelled"];
}

#pragma mark - Public operations

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
    BOOL performed = [self _perform:^{
        if (start)
            [self _connect];
        else
            [self _updateWatch];
    }];
    if (!performed)
    {
        NSString *loadError = nil;
        _NSURLSessionCurlGetAPI(&loadError);
        [self _finishWithError:[self _URLErrorWithCode:NSURLErrorUnknown description:loadError]];
    }
}

// A suspended task neither reads nor writes; what is sent or received in the
// meantime waits for it to resume.
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
        [self _perform:^{ [self _updateWatch]; }];
}

- (BOOL)_isSuspended
{
    @synchronized(self)
    {
        return _suspendCount > 0;
    }
}

- (void)cancel
{
    @synchronized(self)
    {
        if (_state == NSURLSessionTaskStateCompleted || _state == NSURLSessionTaskStateCanceling)
            return;
        _state = NSURLSessionTaskStateCanceling;
    }
    NSError *error = [self _cancelledError];
    if (![self _perform:^{ [self _cancelWithError:error]; }])
        [self _finishWithError:error];
}

- (void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason
{
    NSData *reasonCopy = [[reason copy] autorelease];
    NSError *error = [self _cancelledError];
    BOOL performed = [self _perform:^{
        if (_phase == kPhaseOpen)
            [self _closeWithCode:closeCode reason:reasonCopy];
        else if (_phase != kPhaseClosing && _phase != kPhaseFinished)
            // Before the connection opens, the close is a plain cancel.
            [self _cancelWithError:error];
    }];
    if (!performed)
        [self _finishWithError:error];
}

- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *error))completionHandler
{
    if (message == nil)
        [NSException raise:NSInvalidArgumentException format:@"Cannot send a nil message"];
    NSData *payload = [message type] == NSURLSessionWebSocketMessageTypeString
        ? [[message string] dataUsingEncoding:NSUTF8StringEncoding]
        : [message data];
    [self _queueOpcode:[message type] == NSURLSessionWebSocketMessageTypeString ? kOpcodeText : kOpcodeBinary
               payload:payload != nil ? payload : [NSData data]
               handler:completionHandler];
}

- (void)sendPingWithPongReceiveHandler:(void (^)(NSError *error))pongReceiveHandler
{
    [self _queueOpcode:kOpcodePing payload:nil handler:pongReceiveHandler];
}

- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *message, NSError *error))completionHandler
{
    _NSURLSessionWebSocketReceiveHandler handler = [[completionHandler copy] autorelease];
    BOOL performed = [self _perform:^{
        if ([_messages count] != 0)
        {
            NSURLSessionWebSocketMessage *message = [[[_messages objectAtIndex:0] retain] autorelease];
            [_messages removeObjectAtIndex:0];
            [self _deliver:^{ handler(message, nil); }];
        }
        else if (_terminalError != nil)
        {
            NSError *error = [[_terminalError retain] autorelease];
            [self _deliver:^{ handler(nil, error); }];
        }
        else
        {
            [_receiveHandlers addObject:handler];
        }
    }];
    if (!performed)
        [self _deliver:^{ handler(nil, [self error]); }];
}

- (void)_queueOpcode:(int)opcode payload:(NSData *)payload handler:(void (^)(NSError *error))handler
{
    _NSURLSessionWebSocketOutgoing *outgoing = [[[_NSURLSessionWebSocketOutgoing alloc] init] autorelease];
    outgoing->_opcode = opcode;
    outgoing->_payload = [payload copy];
    outgoing->_handler = [handler copy];
    BOOL performed = [self _perform:^{
        if (_terminalError != nil)
            [self _failOutgoing:outgoing error:_terminalError];
        else if (_phase == kPhaseOpen)
            [self _sendOutgoing:outgoing];
        else
            [_waitingSends addObject:outgoing];
    }];
    if (!performed)
        [self _failOutgoing:outgoing error:[self error]];
}

#pragma mark - Transport thread

- (void)_failOutgoing:(_NSURLSessionWebSocketOutgoing *)outgoing error:(NSError *)error
{
    void (^handler)(NSError *) = outgoing->_handler;
    if (handler == nil)
        return;
    handler = [[handler retain] autorelease];
    [self _deliver:^{ handler(error); }];
}

- (void)_sendOutgoing:(_NSURLSessionWebSocketOutgoing *)outgoing
{
    if (outgoing->_opcode == kOpcodePing)
    {
        // Pings carry a counter; pongs answer them in order.
        uint32_t counter = _nextPing++;
        unsigned char bytes[4] = { counter >> 24, counter >> 16, counter >> 8, counter };
        [self _writeFrame:kOpcodePing payload:[NSData dataWithBytes:bytes length:4] handler:nil];
        if (outgoing->_handler != nil)
            [_pongHandlers addObject:outgoing->_handler];
        else
            [_pongHandlers addObject:[NSNull null]];
        return;
    }
    [self _writeFrame:outgoing->_opcode payload:outgoing->_payload handler:outgoing->_handler];
}

// Queues one masked frame, as a client sends them (RFC 6455, section 5.3).
- (void)_writeFrame:(int)opcode payload:(NSData *)payload handler:(void (^)(NSError *error))handler
{
    NSUInteger length = [payload length];
    unsigned char header[14];
    size_t headerLength = 2;
    header[0] = 0x80 | opcode;
    if (length < 126)
    {
        header[1] = 0x80 | length;
    }
    else if (length <= 0xffff)
    {
        header[1] = 0x80 | 126;
        header[2] = length >> 8;
        header[3] = length;
        headerLength = 4;
    }
    else
    {
        header[1] = 0x80 | 127;
        for (int i = 0; i < 8; i++)
            header[2 + i] = (uint64_t)length >> (56 - 8 * i);
        headerLength = 10;
    }
    unsigned char mask[4];
    arc4random_buf(mask, sizeof(mask));
    memcpy(header + headerLength, mask, 4);
    headerLength += 4;

    [_output appendBytes:header length:headerLength];
    NSUInteger start = [_output length];
    [_output appendData:payload];
    unsigned char *bytes = (unsigned char *)[_output mutableBytes] + start;
    for (NSUInteger i = 0; i < length; i++)
        bytes[i] ^= mask[i % 4];

    if (handler != nil)
    {
        _NSURLSessionWebSocketWrite *write = [[_NSURLSessionWebSocketWrite alloc] init];
        @synchronized(self)
        {
            write->_end = _countOfBytesSent + [_output length];
        }
        write->_handler = [handler copy];
        [_writeCompletions addObject:write];
        [write release];
    }
    [self _flushOutput];
    [self _updateWatch];
}

- (void)_connect
{
    if (_phase != kPhaseIdle)
        return;
    _phase = kPhaseConnecting;
    _startTime = CFAbsoluteTimeGetCurrent();

    // The opening handshake carries the stored cookies, as a data task's request does (macOS
    // 26.7.3; test: tests/nsurlsession-cookies.m).
    NSURLSessionConfiguration *configuration = [_session _configurationNoCopy];
    NSURLRequest *request = [self currentRequest];
    NSHTTPCookieStorage *cookieStorage = _NSURLSessionCookieStorageForRequest(configuration, request);
    if (cookieStorage == nil || _NSURLSessionHasCookieHeader(configuration, request))
    {
        [self _openConnection];
        return;
    }
    _NSURLSessionGetCookieHeader(cookieStorage, self, ^(NSString *header) {
        [_cookieHeader release];
        _cookieHeader = [header copy];
        [self _openConnection];
    });
}

- (void)_openConnection
{
    if (_phase != kPhaseConnecting)
        return;
    const _NSURLSessionCurlAPI *curl = [self _curl];
    CURL *easy = curl->easy_init();
    if (easy == NULL)
    {
        [self _finishWithError:[self _URLErrorWithCode:NSURLErrorUnknown description:@"curl_easy_init failed"]];
        return;
    }
    _easy = easy;
    if (_curlErrorBuffer == NULL)
        _curlErrorBuffer = malloc(CURL_ERROR_SIZE);
    _curlErrorBuffer[0] = '\0';

    NSURLRequest *request = [self currentRequest];
    NSURL *url = connectionURL([request URL]);
    curl->easy_setopt(easy, CURLOPT_URL, [[url absoluteString] UTF8String]);
    curl->easy_setopt(easy, CURLOPT_CONNECT_ONLY, 1L);
    curl->easy_setopt(easy, CURLOPT_PRIVATE, self);
    curl->easy_setopt(easy, CURLOPT_ERRORBUFFER, _curlErrorBuffer);
    curl->easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl->easy_setopt(easy, CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    // The opening handshake is HTTP/1.1 (RFC 6455, section 4.1), so TLS must
    // not negotiate HTTP/2 for the connection.
    curl->easy_setopt(easy, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    // Through an HTTP proxy, the connection is a tunnel to the server.
    curl->easy_setopt(easy, CURLOPT_HTTPPROXYTUNNEL, 1L);
    // As for data tasks: libcurl's TLS backend decides server trust.
    curl->easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl->easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);

    NSTimeInterval timeout = [request timeoutInterval];
    if (timeout == [NSURLRequest defaultTimeoutInterval])
        timeout = [[_session _configurationNoCopy] timeoutIntervalForRequest];
    if (timeout > 0)
        curl->easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, (long)ceil(timeout * 1000));

    CURLMcode added = _NSURLSessionCurlAddHandle(easy);
    if (added != CURLM_OK)
    {
        [self _finishWithError:[self _URLErrorWithCode:NSURLErrorUnknown description:[NSString stringWithFormat:@"curl_multi_add_handle failed (%d)", added]]];
        return;
    }
}

// The handle stays in the multi handle for as long as the connection is used.
- (BOOL)_curlTransferKeepsHandle
{
    return YES;
}

// The connection is made, or failed.
- (void)_curlTransferDidCompleteWithCode:(CURLcode)code
{
    if (_phase != kPhaseConnecting)
        return;
    const _NSURLSessionCurlAPI *curl = [self _curl];
    if (code != CURLE_OK)
    {
        const char *text = _curlErrorBuffer[0] != '\0' ? _curlErrorBuffer : curl->easy_strerror(code);
        long verifyResult = 0;
        if (code == CURLE_PEER_FAILED_VERIFICATION)
            curl->easy_getinfo(_easy, CURLINFO_SSL_VERIFYRESULT, &verifyResult);
        [self _finishWithError:[self _URLErrorWithCode:_NSURLSessionErrorCodeForCurl(code, verifyResult)
                                           description:[NSString stringWithUTF8String:text]]];
        return;
    }
    curl_socket_t socket = CURL_SOCKET_BAD;
    if (curl->easy_getinfo(_easy, CURLINFO_ACTIVESOCKET, &socket) != CURLE_OK || socket == CURL_SOCKET_BAD)
    {
        [self _finishWithError:[self _URLErrorWithCode:NSURLErrorNetworkConnectionLost description:@"The connection has no socket"]];
        return;
    }
    _socket = socket;
    _phase = kPhaseHandshake;
    [_output appendData:[self _handshakeRequest]];
    [self _flushOutput];
    [self _updateWatch];
}

// The opening handshake (RFC 6455, section 4.1): a GET of the request's
// resource with its header fields and the session's.
- (NSData *)_handshakeRequest
{
    NSURLRequest *request = [self currentRequest];
    NSURL *url = [request URL];
    NSString *path = [(NSString *)CFURLCopyPath((CFURLRef)url) autorelease];
    if ([path length] == 0)
        path = @"/";
    NSString *query = [(NSString *)CFURLCopyQueryString((CFURLRef)url, NULL) autorelease];
    if (query != nil)
        path = [path stringByAppendingFormat:@"?%@", query];

    NSString *host = [url host];
    if ([host rangeOfString:@":"].location != NSNotFound)
        host = [NSString stringWithFormat:@"[%@]", host];
    if ([url port] != nil)
        host = [host stringByAppendingFormat:@":%@", [url port]];

    NSMutableString *text = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\n", path, host];
    NSMutableSet *names = [NSMutableSet setWithObject:@"host"];
    NSDictionary *sources[2] = { [request allHTTPHeaderFields], [[_session _configurationNoCopy] HTTPAdditionalHeaders] };
    NSCharacterSet *badName = [NSCharacterSet characterSetWithCharactersInString:@"\r\n: \t"];
    NSCharacterSet *badValue = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    for (int i = 0; i < 2; i++)
    {
        for (NSString *name in sources[i])
        {
            NSString *value = [sources[i] objectForKey:name];
            NSString *lowercase = [name lowercaseString];
            if ([name length] == 0 || [names containsObject:lowercase] ||
                [name rangeOfCharacterFromSet:badName].location != NSNotFound ||
                [value rangeOfCharacterFromSet:badValue].location != NSNotFound)
                continue;
            [names addObject:lowercase];
            [text appendFormat:@"%@: %@\r\n", name, value];
        }
    }
    if ([_cookieHeader length] != 0 && ![names containsObject:@"cookie"])
        [text appendFormat:@"Cookie: %@\r\n", _cookieHeader];
    if (![names containsObject:@"user-agent"])
        [text appendFormat:@"User-Agent: %@\r\n", _NSURLSessionDefaultUserAgent()];
    [text appendString:@"\r\n"];
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)_updateWatch
{
    if (_socket < 0 || _phase == kPhaseFinished)
        return;
    short events = 0;
    if (![self _isSuspended])
    {
        events |= CURL_WAIT_POLLIN;
        if ([_output length] != 0)
            events |= CURL_WAIT_POLLOUT;
    }
    if (events == 0)
    {
        _NSURLSessionCurlUnwatchSocket(_socket);
        return;
    }
    _NSURLSessionCurlWatchSocket(_socket, events, ^(short ready) {
        [self _socketReady:ready];
    });
}

- (void)_socketReady:(short)events
{
    if (_phase == kPhaseFinished)
        return;
    if ([_output length] != 0)
        [self _flushOutput];
    if (_phase != kPhaseFinished && (events & CURL_WAIT_POLLIN))
        [self _readInput];
    [self _updateWatch];
}

- (void)_flushOutput
{
    if (_easy == NULL || _socket < 0 || [self _isSuspended])
        return;
    const _NSURLSessionCurlAPI *curl = [self _curl];
    while ([_output length] != 0)
    {
        size_t sent = 0;
        CURLcode code = curl->easy_send(_easy, [_output bytes], [_output length], &sent);
        if (code == CURLE_AGAIN)
            break;
        if (code != CURLE_OK)
        {
            [self _connectionLost];
            return;
        }
        [_output replaceBytesInRange:NSMakeRange(0, sent) withBytes:NULL length:0];
        @synchronized(self)
        {
            _countOfBytesSent += sent;
        }
    }

    int64_t written;
    @synchronized(self)
    {
        written = _countOfBytesSent;
    }
    while ([_writeCompletions count] != 0)
    {
        _NSURLSessionWebSocketWrite *write = [_writeCompletions objectAtIndex:0];
        if (write->_end > written)
            break;
        void (^handler)(NSError *) = [[write->_handler retain] autorelease];
        [_writeCompletions removeObjectAtIndex:0];
        [self _deliver:^{ handler(nil); }];
    }
}

- (void)_readInput
{
    const _NSURLSessionCurlAPI *curl = [self _curl];
    char buffer[16384];
    for (;;)
    {
        size_t received = 0;
        CURLcode code = curl->easy_recv(_easy, buffer, sizeof(buffer), &received);
        if (code == CURLE_AGAIN)
            break;
        if (code != CURLE_OK || received == 0)
        {
            [self _processInput];
            if (_phase != kPhaseFinished)
                [self _connectionLost];
            return;
        }
        [_input appendBytes:buffer length:received];
        @synchronized(self)
        {
            _countOfBytesReceived += received;
        }
    }
    [self _processInput];
}

- (void)_processInput
{
    if (_phase == kPhaseHandshake)
        [self _readHandshakeResponse];
    while ((_phase == kPhaseOpen || _phase == kPhaseClosing) && [self _readFrame])
        ;
}

- (void)_readHandshakeResponse
{
    NSData *separator = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSRange end = [_input rangeOfData:separator options:0 range:NSMakeRange(0, [_input length])];
    if (end.location == NSNotFound)
    {
        if ([_input length] > kMaximumHandshakeLength)
            [self _failHandshakeWithResponse:nil];
        return;
    }
    NSData *head = [_input subdataWithRange:NSMakeRange(0, end.location)];
    [_input replaceBytesInRange:NSMakeRange(0, NSMaxRange(end)) withBytes:NULL length:0];

    NSString *text = [[[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding] autorelease];
    NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray *status = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
    if ([status count] < 2 || ![[status objectAtIndex:0] hasPrefix:@"HTTP/"])
    {
        [self _failHandshakeWithResponse:nil];
        return;
    }
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
    for (NSUInteger i = 1; i < [lines count]; i++)
    {
        NSString *line = [lines objectAtIndex:i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:whitespace];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:whitespace];
        NSString *existing = nil;
        for (NSString *key in fields)
        {
            if ([key caseInsensitiveCompare:name] == NSOrderedSame)
                existing = key;
        }
        if (existing != nil)
            [fields setObject:[NSString stringWithFormat:@"%@, %@", [fields objectForKey:existing], value] forKey:existing];
        else
            [fields setObject:value forKey:name];
    }
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[[self currentRequest] URL]
                                                              statusCode:[[status objectAtIndex:1] integerValue]
                                                             HTTPVersion:[status objectAtIndex:0]
                                                            headerFields:fields] autorelease];
    @synchronized(self)
    {
        [_response release];
        _response = [response retain];
    }
    _NSURLSessionStoreResponseCookies(_NSURLSessionCookieStorageForRequest([_session _configurationNoCopy], [self currentRequest]), self, response);

    // RFC 6455, section 4.1: what the client checks before the connection
    // counts as open.
    NSString *protocol = headerValue(fields, @"Sec-WebSocket-Protocol");
    BOOL valid = [response statusCode] == 101 &&
        [headerValue(fields, @"Upgrade") caseInsensitiveCompare:@"websocket"] == NSOrderedSame &&
        containsTokenIgnoringCase(headerTokens(headerValue(fields, @"Connection")), @"Upgrade") &&
        [headerValue(fields, @"Sec-WebSocket-Accept") isEqualToString:acceptValueForKey(_key)] &&
        // No extension was offered, so none can be in use.
        headerValue(fields, @"Sec-WebSocket-Extensions") == nil &&
        // A subprotocol has to be one that was offered.
        (protocol == nil || [_protocols containsObject:protocol]);
    if (!valid)
    {
        [self _failHandshakeWithResponse:response];
        return;
    }

    _phase = kPhaseOpen;
    NSURLSessionTaskMetrics *metrics = [self _metrics];
    _metricsDelivered = YES;
    __NSCFURLSession *session = _session;
    [self _deliver:^{
        id metricsDelegate = [session _delegateForTask:self respondingTo:@selector(URLSession:task:didFinishCollectingMetrics:)];
        [(id <_NSURLSessionWebSocketMetricsDelegate>)metricsDelegate URLSession:session task:self didFinishCollectingMetrics:metrics];
        id delegate = [session _delegateForTask:self respondingTo:@selector(URLSession:webSocketTask:didOpenWithProtocol:)];
        [(id <NSURLSessionWebSocketDelegate>)delegate URLSession:session webSocketTask:self didOpenWithProtocol:protocol];
    }];

    NSArray *waiting = [[_waitingSends copy] autorelease];
    [_waitingSends removeAllObjects];
    for (_NSURLSessionWebSocketOutgoing *outgoing in waiting)
        [self _sendOutgoing:outgoing];
}

- (void)_failHandshakeWithResponse:(NSHTTPURLResponse *)response
{
    [self _finishWithError:[self _URLErrorWithCode:NSURLErrorBadServerResponse description:@"There was a bad response from the server."]];
}

// Reads one frame from the input; NO when it holds no complete frame or the
// task ended (RFC 6455, section 5.2).
- (BOOL)_readFrame
{
    NSUInteger available = [_input length];
    const unsigned char *bytes = [_input bytes];
    if (available < 2)
        return NO;
    BOOL fin = (bytes[0] & 0x80) != 0;
    int reserved = (bytes[0] >> 4) & 0x7;
    int opcode = bytes[0] & 0xf;
    BOOL masked = (bytes[1] & 0x80) != 0;
    uint64_t length = bytes[1] & 0x7f;
    NSUInteger headerLength = 2;
    if (length == 126)
    {
        if (available < 4)
            return NO;
        length = ((uint64_t)bytes[2] << 8) | bytes[3];
        headerLength = 4;
    }
    else if (length == 127)
    {
        if (available < 10)
            return NO;
        length = 0;
        for (int i = 0; i < 8; i++)
            length = (length << 8) | bytes[2 + i];
        headerLength = 10;
    }

    BOOL control = (opcode & 0x8) != 0;
    BOOL knownOpcode = opcode == kOpcodeContinuation || opcode == kOpcodeText || opcode == kOpcodeBinary ||
        opcode == kOpcodeClose || opcode == kOpcodePing || opcode == kOpcodePong;
    // A server does not mask its frames, no extension gives the reserved bits
    // a meaning, control frames are short and whole, and a continuation
    // continues a message.
    if (masked || reserved != 0 || !knownOpcode || (control && (!fin || length > 125)) ||
        (opcode == kOpcodeContinuation && _fragments == nil) ||
        ((opcode == kOpcodeText || opcode == kOpcodeBinary) && _fragments != nil))
    {
        [self _failWithCloseCode:NSURLSessionWebSocketCloseCodeProtocolError error:posixError(EPROTO)];
        return NO;
    }

    if (!control)
    {
        uint64_t total = (uint64_t)[_fragments length] + length;
        NSInteger maximum = [self maximumMessageSize];
        if (maximum >= 0 && total > (uint64_t)maximum)
        {
            [self _failWithCloseCode:NSURLSessionWebSocketCloseCodeMessageTooBig error:posixError(EMSGSIZE)];
            return NO;
        }
    }
    if (available - headerLength < length)
        return NO;

    NSData *payload = [_input subdataWithRange:NSMakeRange(headerLength, (NSUInteger)length)];
    [_input replaceBytesInRange:NSMakeRange(0, headerLength + (NSUInteger)length) withBytes:NULL length:0];

    switch (opcode)
    {
    case kOpcodeText:
    case kOpcodeBinary:
    case kOpcodeContinuation:
        if (_fragments == nil)
        {
            _fragments = [[NSMutableData alloc] init];
            _fragmentOpcode = opcode;
        }
        [_fragments appendData:payload];
        if (fin)
            return [self _messageComplete];
        return YES;
    case kOpcodePing:
        if (_phase == kPhaseOpen)
            [self _writeFrame:kOpcodePong payload:payload handler:nil];
        return YES;
    case kOpcodePong:
        [self _pongReceived];
        return YES;
    case kOpcodeClose:
        return [self _closeReceived:payload];
    }
    return YES;
}

- (BOOL)_messageComplete
{
    NSData *data = [[_fragments retain] autorelease];
    int opcode = _fragmentOpcode;
    [_fragments release];
    _fragments = nil;

    NSURLSessionWebSocketMessage *message;
    if (opcode == kOpcodeText)
    {
        NSString *string = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (string == nil)
        {
            // Text that is not UTF-8 ends the connection as a protocol
            // error, as on macOS 26.7.3.
            [self _failWithCloseCode:NSURLSessionWebSocketCloseCodeProtocolError error:posixError(EPROTO)];
            return NO;
        }
        message = [[[NSURLSessionWebSocketMessage alloc] initWithString:string] autorelease];
    }
    else
    {
        message = [[[NSURLSessionWebSocketMessage alloc] initWithData:[[data copy] autorelease]] autorelease];
    }

    if (_phase != kPhaseOpen)
        return YES;
    if ([_receiveHandlers count] != 0)
    {
        _NSURLSessionWebSocketReceiveHandler handler = [[[_receiveHandlers objectAtIndex:0] retain] autorelease];
        [_receiveHandlers removeObjectAtIndex:0];
        [self _deliver:^{ handler(message, nil); }];
    }
    else
    {
        [_messages addObject:message];
    }
    return YES;
}

- (void)_pongReceived
{
    if ([_pongHandlers count] == 0)
        return;
    id handler = [[[_pongHandlers objectAtIndex:0] retain] autorelease];
    [_pongHandlers removeObjectAtIndex:0];
    if (handler == [NSNull null])
        return;
    [self _deliver:^{ ((void (^)(NSError *))handler)(nil); }];
}

- (void)_failPending:(NSError *)error
{
    for (_NSURLSessionWebSocketReceiveHandler handler in _receiveHandlers)
    {
        _NSURLSessionWebSocketReceiveHandler retained = [[handler retain] autorelease];
        [self _deliver:^{ retained(nil, error); }];
    }
    [_receiveHandlers removeAllObjects];
    for (id handler in _pongHandlers)
    {
        if (handler == [NSNull null])
            continue;
        id retained = [[handler retain] autorelease];
        [self _deliver:^{ ((void (^)(NSError *))retained)(error); }];
    }
    [_pongHandlers removeAllObjects];
    for (_NSURLSessionWebSocketOutgoing *outgoing in _waitingSends)
        [self _failOutgoing:outgoing error:error];
    [_waitingSends removeAllObjects];
    for (_NSURLSessionWebSocketWrite *write in _writeCompletions)
    {
        void (^handler)(NSError *) = [[write->_handler retain] autorelease];
        [self _deliver:^{ handler(error); }];
    }
    [_writeCompletions removeAllObjects];
}

- (void)_setTerminalError:(NSError *)error
{
    if (_terminalError != nil)
        return;
    _terminalError = [error retain];
    [self _failPending:error];
}

// The server's close frame (RFC 6455, section 5.5.1).
- (BOOL)_closeReceived:(NSData *)payload
{
    if ([payload length] == 1)
    {
        [self _failWithCloseCode:NSURLSessionWebSocketCloseCodeProtocolError error:posixError(EPROTO)];
        return NO;
    }
    if (_closeSent)
    {
        // The answer to the close the client started.
        [self _finishWithError:nil];
        return NO;
    }

    // A close the server started: it is answered with the same payload, and
    // the task ends without an error. Without a status code the close counts
    // as 1005 (section 7.1.5), with an empty reason.
    const unsigned char *bytes = [payload bytes];
    NSURLSessionWebSocketCloseCode code = NSURLSessionWebSocketCloseCodeNoStatusReceived;
    NSData *reason = [NSData data];
    if ([payload length] >= 2)
    {
        code = ((NSInteger)bytes[0] << 8) | bytes[1];
        reason = [payload subdataWithRange:NSMakeRange(2, [payload length] - 2)];
    }
    @synchronized(self)
    {
        _closeCode = code;
        [_closeReason release];
        _closeReason = [reason copy];
    }
    _closeSent = YES;
    _phase = kPhaseClosing;
    [self _writeFrame:kOpcodeClose payload:payload handler:nil];
    [self _setTerminalError:posixError(ENOTCONN)];

    @synchronized(self)
    {
        _state = NSURLSessionTaskStateCompleted;
    }
    __NSCFURLSession *session = _session;
    [self _deliver:^{
        id delegate = [session _delegateForTask:self respondingTo:@selector(URLSession:webSocketTask:didCloseWithCode:reason:)];
        [(id <NSURLSessionWebSocketDelegate>)delegate URLSession:session webSocketTask:self didCloseWithCode:code reason:reason];
    }];
    [self _finishWithError:nil];
    return NO;
}

// The client closes the connection with code (no reason) and the task ends
// with error, without a close for the delegate.
- (void)_failWithCloseCode:(NSURLSessionWebSocketCloseCode)code error:(NSError *)error
{
    unsigned char bytes[2] = { code >> 8, code };
    _closeSent = YES;
    [self _writeFrame:kOpcodeClose payload:[NSData dataWithBytes:bytes length:2] handler:nil];
    [self _finishWithError:error];
}

// cancelWithCloseCode:reason: on an open connection: the delegate hears of
// the close at once, and the task ends without an error once the server has
// answered (or closed the connection).
- (void)_closeWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason
{
    @synchronized(self)
    {
        _state = NSURLSessionTaskStateCanceling;
        _closeCode = code;
        [_closeReason release];
        _closeReason = [reason copy];
    }
    _phase = kPhaseClosing;
    _closeSent = YES;
    [self _setTerminalError:[self _cancelledError]];

    __NSCFURLSession *session = _session;
    [self _deliver:^{
        id delegate = [session _delegateForTask:self respondingTo:@selector(URLSession:webSocketTask:didCloseWithCode:reason:)];
        [(id <NSURLSessionWebSocketDelegate>)delegate URLSession:session webSocketTask:self didCloseWithCode:code reason:reason];
    }];

    NSMutableData *payload = [NSMutableData data];
    if (code != NSURLSessionWebSocketCloseCodeInvalid)
    {
        unsigned char bytes[2] = { code >> 8, code };
        [payload appendBytes:bytes length:2];
        if (reason != nil)
            [payload appendData:reason];
    }
    [self _writeFrame:kOpcodeClose payload:payload handler:nil];

    [self retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kCloseWaitNanoseconds), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        _NSURLSessionCurlPerform(^{
            if (_phase == kPhaseClosing)
                [self _finishWithError:nil];
            [self release];
        });
    });
}

// cancel, or a close before the connection opened: an open connection is
// closed without a status code.
- (void)_cancelWithError:(NSError *)error
{
    @synchronized(self)
    {
        _state = NSURLSessionTaskStateCanceling;
    }
    if (_phase == kPhaseOpen && !_closeSent)
    {
        _closeSent = YES;
        [self _writeFrame:kOpcodeClose payload:[NSData data] handler:nil];
    }
    [self _finishWithError:error];
}

- (void)_connectionLost
{
    if (_phase == kPhaseClosing)
        [self _finishWithError:nil];
    else if (_phase == kPhaseHandshake)
        [self _finishWithError:[self _URLErrorWithCode:NSURLErrorNetworkConnectionLost description:@"The network connection was lost."]];
    else
        [self _finishWithError:posixError(ENOTCONN)];
}

- (NSURLSessionTaskMetrics *)_metrics
{
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime start = _startTime != 0 ? _startTime : end;
    NSDateInterval *interval = [[[NSDateInterval alloc] initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:start]
                                                                   endDate:[NSDate dateWithTimeIntervalSinceReferenceDate:end]] autorelease];
    return [[[NSURLSessionTaskMetrics alloc] _initWithTaskInterval:interval redirectCount:0] autorelease];
}

// Ends the task. Runs on the transport thread, or on any thread when the
// transport could not be used.
- (void)_finishWithError:(NSError *)error
{
    if (_phase == kPhaseFinished)
        return;
    _phase = kPhaseFinished;
    @synchronized(self)
    {
        _state = NSURLSessionTaskStateCompleted;
        [_error release];
        _error = [error copy];
    }
    // What is sent or received afterwards fails as the task did, and after a
    // close as a connection that is gone.
    [self _setTerminalError:error != nil ? error : posixError(ENOTCONN)];
    [self _failPending:_terminalError];

    // Whatever close frame is still queued gets its chance to leave.
    if (_easy != NULL && _socket >= 0 && [_output length] != 0)
        [self _flushOutput];
    if (_socket >= 0)
        _NSURLSessionCurlUnwatchSocket(_socket);
    if (_easy != NULL)
    {
        // This closes the connection.
        _NSURLSessionCurlRemoveHandle(_easy);
        [self _curl]->easy_cleanup(_easy);
        _easy = NULL;
    }
    _socket = -1;
    [_output setLength:0];
    [_input setLength:0];

    NSURLSessionTaskMetrics *metrics = _metricsDelivered ? nil : [self _metrics];
    _metricsDelivered = YES;
    __NSCFURLSession *session = _session;
    [self retain];
    [self _deliver:^{
        if (metrics != nil)
        {
            id metricsDelegate = [session _delegateForTask:self respondingTo:@selector(URLSession:task:didFinishCollectingMetrics:)];
            [(id <_NSURLSessionWebSocketMetricsDelegate>)metricsDelegate URLSession:session task:self didFinishCollectingMetrics:metrics];
        }
        id delegate = [session _delegateForTask:self respondingTo:@selector(URLSession:task:didCompleteWithError:)];
        [delegate URLSession:session task:self didCompleteWithError:error];
        [self setDelegate:nil];
        [session _taskDidFinish:self];
        [self release];
    }];
}

@end

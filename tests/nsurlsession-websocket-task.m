#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// NSURLSessionWebSocketTask
// (https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)
// against a WebSocket server (RFC 6455) in this process, and the per-task
// delegate of NSURLSessionTask.
//
// Where the documentation is silent, the expectations are what macOS 26.7.3
// does, observed through the public API: which error ends the task in each
// case, the order of the delegate messages, and what the client sends.

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

#pragma mark - Event log

// What the client's delegates and handlers saw, and what the server read, in
// the order it happened.
static NSMutableArray *events;

static void record(NSString *event)
{
    @synchronized(events)
    {
        [events addObject:event];
    }
}

static NSArray *recorded(void)
{
    @synchronized(events)
    {
        return [[events copy] autorelease];
    }
}

static void resetEvents(void)
{
    @synchronized(events)
    {
        [events removeAllObjects];
    }
}

static BOOL hasEvent(NSString *event)
{
    return [recorded() containsObject:event];
}

// Whether every event of the list was recorded, in that order.
static BOOL inOrder(NSArray *list)
{
    NSArray *all = recorded();
    NSUInteger last = 0;
    BOOL first = YES;
    for (NSString *event in list)
    {
        NSUInteger index = [all indexOfObject:event];
        if (index == NSNotFound || (!first && index < last))
            return NO;
        last = index;
        first = NO;
    }
    return YES;
}

static NSString *errorText(NSError *error)
{
    if (error == nil)
        return @"nil";
    return [NSString stringWithFormat:@"%@ %ld", [error domain], (long)[error code]];
}

static NSString *dataText(NSData *data)
{
    if (data == nil)
        return @"(nil)";
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

static void runFor(NSTimeInterval seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// Runs the main run loop until the event is recorded, then a little longer so
// that the server sees what was sent last.
static BOOL waitFor(NSString *event)
{
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!hasEvent(event) && [limit timeIntervalSinceNow] > 0)
        runFor(0.02);
    runFor(0.3);
    return hasEvent(event);
}

#pragma mark - Server

static int listener;
static int port;

static int readFully(int fd, void *buffer, size_t length)
{
    size_t done = 0;
    while (done < length)
    {
        ssize_t got = read(fd, (char *)buffer + done, length - done);
        if (got <= 0)
            return -1;
        done += got;
    }
    return 0;
}

static void writeFully(int fd, const void *buffer, size_t length)
{
    size_t done = 0;
    while (done < length)
    {
        ssize_t wrote = write(fd, (const char *)buffer + done, length - done);
        if (wrote <= 0)
            return;
        done += wrote;
    }
}

// An unmasked frame, as a server sends them.
static void sendFrame(int fd, BOOL fin, int opcode, const void *payload, size_t length)
{
    unsigned char header[10];
    size_t headerLength = 2;
    header[0] = (fin ? 0x80 : 0) | opcode;
    if (length < 126)
    {
        header[1] = length;
    }
    else if (length < 65536)
    {
        header[1] = 126;
        header[2] = length >> 8;
        header[3] = length;
        headerLength = 4;
    }
    else
    {
        header[1] = 127;
        for (int i = 0; i < 8; i++)
            header[2 + i] = (uint64_t)length >> (56 - 8 * i);
        headerLength = 10;
    }
    writeFully(fd, header, headerLength);
    if (length != 0)
        writeFully(fd, payload, length);
}

// Reads a frame and records it; returns its opcode, or -1 at the end of the
// connection.
static int readFrame(int fd, NSMutableData *payload)
{
    unsigned char header[2];
    if (readFully(fd, header, 2) != 0)
        return -1;
    int opcode = header[0] & 0xf;
    BOOL masked = (header[1] & 0x80) != 0;
    uint64_t length = header[1] & 0x7f;
    if (length == 126)
    {
        unsigned char extended[2];
        if (readFully(fd, extended, 2) != 0)
            return -1;
        length = (extended[0] << 8) | extended[1];
    }
    else if (length == 127)
    {
        unsigned char extended[8];
        if (readFully(fd, extended, 8) != 0)
            return -1;
        length = 0;
        for (int i = 0; i < 8; i++)
            length = (length << 8) | extended[i];
    }
    unsigned char mask[4] = { 0 };
    if (masked && readFully(fd, mask, 4) != 0)
        return -1;
    [payload setLength:(NSUInteger)length];
    unsigned char *bytes = [payload mutableBytes];
    if (length != 0 && readFully(fd, bytes, (size_t)length) != 0)
        return -1;
    for (uint64_t i = 0; i < length; i++)
        bytes[i] ^= mask[i % 4];

    if (!masked)
        record(@"server: unmasked frame");
    if (opcode == 0x8)
    {
        if (length >= 2)
            record([NSString stringWithFormat:@"server: close %d '%@'", (bytes[0] << 8) | bytes[1],
                       dataText([payload subdataWithRange:NSMakeRange(2, (NSUInteger)length - 2)])]);
        else
            record([NSString stringWithFormat:@"server: close, %llu bytes", (unsigned long long)length]);
    }
    else if (opcode == 0x1)
    {
        record([NSString stringWithFormat:@"server: text '%@'", dataText(payload)]);
    }
    else if (opcode == 0x2)
    {
        record([NSString stringWithFormat:@"server: binary, %lu bytes", (unsigned long)[payload length]]);
    }
    else if (opcode == 0x9)
    {
        record(@"server: ping");
    }
    return opcode;
}

static NSString *requestHeader(NSString *request, NSString *name)
{
    for (NSString *line in [request componentsSeparatedByString:@"\r\n"])
    {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        if ([[line substringToIndex:colon.location] caseInsensitiveCompare:name] == NSOrderedSame)
            return [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

static NSString *acceptFor(NSString *key)
{
    NSData *input = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"] dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([input bytes], (CC_LONG)[input length], digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

// The scenario is the request's path. The server answers the handshake, does
// what the scenario says, then echoes messages, answers pings and replies to
// a close with the same close.
static void serveConnection(int fd)
{
    NSMutableData *head = [NSMutableData data];
    char byte;
    while ([head length] < 16384 && read(fd, &byte, 1) == 1)
    {
        [head appendBytes:&byte length:1];
        if ([head length] >= 4 && memcmp((const char *)[head bytes] + [head length] - 4, "\r\n\r\n", 4) == 0)
            break;
    }
    NSString *request = [[[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding] autorelease];
    NSArray *requestLine = [[[request componentsSeparatedByString:@"\r\n"] objectAtIndex:0] componentsSeparatedByString:@" "];
    if ([requestLine count] < 3)
        return;
    NSString *scenario = [[requestLine objectAtIndex:1] substringFromIndex:1];
    record([NSString stringWithFormat:@"server: %@ %@", [requestLine objectAtIndex:0], [requestLine objectAtIndex:1]]);
    if (requestHeader(request, @"User-Agent") != nil)
        record(@"server: has a User-Agent");
    NSString *offered = requestHeader(request, @"Sec-WebSocket-Protocol");
    if (offered != nil)
        record([NSString stringWithFormat:@"server: offered '%@'", offered]);

    if ([scenario isEqualToString:@"notfound"])
    {
        const char *response = "HTTP/1.1 404 Not Found\r\nContent-Length: 5\r\n\r\nnope\n";
        writeFully(fd, response, strlen(response));
        return;
    }

    NSString *chosen = nil;
    if ([scenario isEqualToString:@"badprotocol"])
        chosen = @"unoffered";
    else if (offered != nil)
        chosen = [[[offered componentsSeparatedByString:@","] objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *accept = [scenario isEqualToString:@"badaccept"] ? @"AAAAAAAAAAAAAAAAAAAAAAAAAAA=" : acceptFor(requestHeader(request, @"Sec-WebSocket-Key"));
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                                     "Sec-WebSocket-Accept: %@\r\n%@X-Test: yes\r\n\r\n",
                                                     accept, chosen != nil ? [NSString stringWithFormat:@"Sec-WebSocket-Protocol: %@\r\n", chosen] : @""];
    writeFully(fd, [response UTF8String], strlen([response UTF8String]));

    if ([scenario isEqualToString:@"serverclose"])
    {
        unsigned char close[] = { 4001 >> 8, 4001 & 0xff, 'b', 'y', 'e' };
        sendFrame(fd, YES, 0x8, close, sizeof(close));
    }
    else if ([scenario isEqualToString:@"nocode"])
    {
        sendFrame(fd, YES, 0x8, NULL, 0);
    }
    else if ([scenario isEqualToString:@"big"])
    {
        char *big = malloc(2000);
        memset(big, 'x', 2000);
        sendFrame(fd, YES, 0x2, big, 2000);
        free(big);
    }
    else if ([scenario isEqualToString:@"fragments"])
    {
        sendFrame(fd, NO, 0x1, "hel", 3);
        sendFrame(fd, YES, 0x9, "in between", 10);
        sendFrame(fd, NO, 0x0, "lo ", 3);
        sendFrame(fd, YES, 0x0, "world", 5);
    }
    else if ([scenario isEqualToString:@"masked"])
    {
        unsigned char frame[] = { 0x81, 0x82, 1, 2, 3, 4, 'h' ^ 1, 'i' ^ 2 };
        writeFully(fd, frame, sizeof(frame));
    }
    else if ([scenario isEqualToString:@"badutf8"])
    {
        unsigned char text[] = { 0xff, 0xfe, 'a' };
        sendFrame(fd, YES, 0x1, text, sizeof(text));
    }
    else if ([scenario isEqualToString:@"badopcode"])
    {
        sendFrame(fd, YES, 0x3, "x", 1);
    }
    else if ([scenario isEqualToString:@"drop"])
    {
        usleep(200000);
        return;
    }

    NSMutableData *payload = [NSMutableData data];
    for (;;)
    {
        int opcode = readFrame(fd, payload);
        if (opcode < 0)
            break;
        if (opcode == 0x1 || opcode == 0x2)
        {
            sendFrame(fd, YES, opcode, [payload bytes], [payload length]);
        }
        else if (opcode == 0x9)
        {
            sendFrame(fd, YES, 0xA, [payload bytes], [payload length]);
        }
        else if (opcode == 0x8)
        {
            if ([scenario isEqualToString:@"closereply"])
            {
                unsigned char close[] = { 4002 >> 8, 4002 & 0xff, 'o', 'k' };
                sendFrame(fd, YES, 0x8, close, sizeof(close));
            }
            else
            {
                sendFrame(fd, YES, 0x8, [payload bytes], [payload length]);
            }
            break;
        }
    }
    usleep(100000);
}

static void *serve(void *unused)
{
    for (;;)
    {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            return NULL;
        @autoreleasepool
        {
            serveConnection(fd);
        }
        record(@"server: closed");
        close(fd);
    }
}

static void startServer(void)
{
    listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(listener, (struct sockaddr *)&address, sizeof(address));
    socklen_t length = sizeof(address);
    getsockname(listener, (struct sockaddr *)&address, &length);
    port = ntohs(address.sin_port);
    listen(listener, 8);
    pthread_t thread;
    pthread_create(&thread, NULL, serve, NULL);
}

#pragma mark - Client

@interface SessionDelegate : NSObject <NSURLSessionWebSocketDelegate>
@end

@implementation SessionDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol
{
    record([NSString stringWithFormat:@"open %@, state %ld, status %ld", protocol != nil ? protocol : @"(nil)",
               (long)[task state], (long)[(NSHTTPURLResponse *)[task response] statusCode]]);
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason
{
    // The task's state at this point depends on how soon the server answers.
    record([NSString stringWithFormat:@"close %ld '%@'", (long)code, dataText(reason)]);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    record([NSString stringWithFormat:@"complete %@, state %ld", errorText(error), (long)[task state]]);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics
{
    record(@"metrics");
}

@end

// A delegate of one task that only hears of its completion.
@interface TaskDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation TaskDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    record([NSString stringWithFormat:@"task delegate: complete %@", errorText(error)]);
}

@end

static NSURLSession *session;

static NSURL *urlFor(NSString *scheme, NSString *scenario)
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://127.0.0.1:%d/%@", scheme, port, scenario]];
}

static NSURLSessionWebSocketTask *taskFor(NSString *scenario)
{
    resetEvents();
    return [session webSocketTaskWithURL:urlFor(@"ws", scenario)];
}

static void receive(NSURLSessionWebSocketTask *task, NSString *label)
{
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        if (message == nil)
            record([NSString stringWithFormat:@"%@: %@", label, errorText(error)]);
        else if ([message type] == NSURLSessionWebSocketMessageTypeString)
            record([NSString stringWithFormat:@"%@: text '%@'%@", label, [message string], error != nil ? @" with an error" : @""]);
        else
            record([NSString stringWithFormat:@"%@: binary, %lu bytes", label, (unsigned long)[[message data] length]]);
    }];
}

static void sendText(NSURLSessionWebSocketTask *task, NSString *text, NSString *label)
{
    NSURLSessionWebSocketMessage *message = [[[NSURLSessionWebSocketMessage alloc] initWithString:text] autorelease];
    [task sendMessage:message completionHandler:^(NSError *error) {
        record([NSString stringWithFormat:@"%@: %@", label, errorText(error)]);
    }];
}

static void dumpEvents(NSString *scenario)
{
    if (failures != 0)
        NSLog(@"events of %@: %@", scenario, recorded());
}

static void testCreation(void)
{
    NSURLSessionWebSocketTask *task = [session webSocketTaskWithURL:urlFor(@"ws", @"echo") protocols:@[@"chat", @"other"]];
    expect([task isKindOfClass:[NSURLSessionWebSocketTask class]], @"a WebSocket task");
    expect([task state] == NSURLSessionTaskStateSuspended, @"a new task is suspended");
    expect([task maximumMessageSize] == 1048576, @"the maximum message size is 1 MiB");
    expect([task closeCode] == NSURLSessionWebSocketCloseCodeInvalid && [task closeReason] == nil, @"no close yet");
    expect([[[[task originalRequest] URL] scheme] isEqualToString:@"http"], @"ws becomes http in the request");
    NSDictionary *headers = [[task currentRequest] allHTTPHeaderFields];
    NSData *key = [[[NSData alloc] initWithBase64EncodedString:[headers objectForKey:@"Sec-WebSocket-Key"] options:0] autorelease];
    expect([key length] == 16, @"the key is 16 random bytes in base64");
    expect([[headers objectForKey:@"Sec-WebSocket-Version"] isEqualToString:@"13"], @"version 13");
    expect([[headers objectForKey:@"Upgrade"] isEqualToString:@"websocket"], @"Upgrade: websocket");
    expect([[headers objectForKey:@"Connection"] isEqualToString:@"Upgrade"], @"Connection: Upgrade");
    expect([[headers objectForKey:@"Sec-WebSocket-Protocol"] isEqualToString:@"chat, other"], @"the subprotocols are offered in order");
    [task cancel];

    task = [session webSocketTaskWithURL:urlFor(@"wss", @"echo")];
    expect([[[[task originalRequest] URL] scheme] isEqualToString:@"https"], @"wss becomes https in the request");
    expect([[[task currentRequest] allHTTPHeaderFields] objectForKey:@"Sec-WebSocket-Protocol"] == nil, @"no subprotocol offered");
    [task cancel];

    BOOL raised = NO;
    @try
    {
        [session webSocketTaskWithURL:urlFor(@"http", @"echo")];
    }
    @catch (NSException *exception)
    {
        raised = YES;
    }
    expect(raised, @"a URL that is not ws or wss raises");
    runFor(0.3);
}

static void testEcho(void)
{
    NSURLSessionWebSocketTask *task = [session webSocketTaskWithURL:urlFor(@"ws", @"echo") protocols:@[@"chat", @"other"]];
    resetEvents();
    // Sent before the connection opens: it waits for it.
    sendText(task, @"early", @"send early");
    receive(task, @"receive 1");
    [task resume];
    expect(waitFor(@"receive 1: text 'early'"), @"the early message is echoed");
    expect(hasEvent(@"open chat, state 0, status 101"), @"opened with the server's subprotocol");
    expect(inOrder(@[@"metrics", @"open chat, state 0, status 101", @"receive 1: text 'early'"]), @"metrics, then open, then the message");
    expect(hasEvent(@"send early: nil"), @"the early send completes");
    expect(hasEvent(@"server: offered 'chat, other'"), @"the server is offered the subprotocols");
    expect(hasEvent(@"server: has a User-Agent"), @"the handshake has a User-Agent");
    expect(!hasEvent(@"server: unmasked frame"), @"client frames are masked");
    expect([[[(NSHTTPURLResponse *)[task response] allHeaderFields] objectForKey:@"X-Test"] isEqualToString:@"yes"], @"the response has the server's fields");

    NSMutableData *data = [NSMutableData dataWithLength:70000];
    ((unsigned char *)[data mutableBytes])[69999] = 7;
    NSURLSessionWebSocketMessage *binary = [[[NSURLSessionWebSocketMessage alloc] initWithData:data] autorelease];
    [task sendMessage:binary completionHandler:^(NSError *error) { record([NSString stringWithFormat:@"send binary: %@", errorText(error)]); }];
    receive(task, @"receive 2");
    expect(waitFor(@"receive 2: binary, 70000 bytes"), @"a 64-bit length message is echoed");
    expect(hasEvent(@"server: binary, 70000 bytes"), @"the server got the binary message");

    [task sendPingWithPongReceiveHandler:^(NSError *error) { record([NSString stringWithFormat:@"pong: %@", errorText(error)]); }];
    expect(waitFor(@"pong: nil"), @"a pong answers the ping");

    [task cancelWithCloseCode:4000 reason:[@"done" dataUsingEncoding:NSUTF8StringEncoding]];
    expect(waitFor(@"complete nil, state 3"), @"the task completes without an error");
    expect(inOrder(@[@"close 4000 'done'", @"complete nil, state 3"]), @"the delegate hears of the close, then the task completes");
    expect(hasEvent(@"server: close 4000 'done'"), @"the server gets the close code and reason");
    expect([task closeCode] == 4000 && [dataText([task closeReason]) isEqualToString:@"done"], @"the task keeps its close code and reason");

    resetEvents();
    receive(task, @"receive after");
    sendText(task, @"late", @"send after");
    waitFor(@"send after: NSURLErrorDomain -999");
    expect(hasEvent(@"receive after: NSURLErrorDomain -999") && hasEvent(@"send after: NSURLErrorDomain -999"), @"later operations are cancelled");
    dumpEvents(@"echo");
}

static void testCloseReply(void)
{
    NSURLSessionWebSocketTask *task = taskFor(@"closereply");
    [task resume];
    waitFor(@"open (nil), state 0, status 101");
    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    expect(waitFor(@"complete nil, state 3"), @"completes");
    expect(hasEvent(@"close 1000 '(nil)'"), @"the delegate hears of the client's close");
    expect([task closeCode] == 1000 && [task closeReason] == nil, @"the client's close code stays, whatever the server answers");
    dumpEvents(@"closereply");
}

static void testServerClose(void)
{
    NSURLSessionWebSocketTask *task = taskFor(@"serverclose");
    receive(task, @"receive");
    [task resume];
    expect(waitFor(@"complete nil, state 3"), @"a close from the server ends the task without an error");
    expect(inOrder(@[@"receive: NSPOSIXErrorDomain 57", @"close 4001 'bye'", @"complete nil, state 3"]), @"receive fails, then close, then complete");
    expect(hasEvent(@"server: close 4001 'bye'"), @"the client answers with the same close");
    expect([task closeCode] == 4001 && [dataText([task closeReason]) isEqualToString:@"bye"], @"the server's close code and reason");
    dumpEvents(@"serverclose");

    // macOS reads what the server sends only while a receive is waiting.
    task = taskFor(@"nocode");
    receive(task, @"receive");
    [task resume];
    expect(waitFor(@"complete nil, state 3"), @"a close without a code");
    expect(hasEvent(@"close 1005 ''"), @"counts as 1005 with an empty reason");
    expect([task closeCode] == 1005 && [task closeReason] != nil && [[task closeReason] length] == 0, @"1005 and an empty reason");
    dumpEvents(@"nocode");
}

static void testFailures(void)
{
    NSURLSessionWebSocketTask *task = taskFor(@"notfound");
    receive(task, @"receive");
    [task resume];
    expect(waitFor(@"complete NSURLErrorDomain -1011, state 3"), @"a response other than 101 is a bad server response");
    expect([(NSHTTPURLResponse *)[task response] statusCode] == 404, @"the task has the response");
    expect(hasEvent(@"receive: NSURLErrorDomain -1011") && hasEvent(@"metrics"), @"receive fails, metrics are delivered");
    expect(inOrder(@[@"metrics", @"complete NSURLErrorDomain -1011, state 3"]), @"metrics before complete");
    dumpEvents(@"notfound");

    task = taskFor(@"badprotocol");
    [task resume];
    expect(waitFor(@"complete NSURLErrorDomain -1011, state 3"), @"a subprotocol that was not offered is a bad server response");
    expect(!hasEvent(@"open unoffered, state 0, status 101"), @"no open");
    dumpEvents(@"badprotocol");

    task = taskFor(@"badaccept");
    [task resume];
    expect(waitFor(@"complete NSURLErrorDomain -1011, state 3"), @"a wrong Sec-WebSocket-Accept is a bad server response");
    dumpEvents(@"badaccept");

    task = taskFor(@"big");
    [task setMaximumMessageSize:1000];
    receive(task, @"receive");
    [task resume];
    expect(waitFor(@"complete NSPOSIXErrorDomain 40, state 3"), @"a message over the maximum ends the task with EMSGSIZE");
    expect(hasEvent(@"receive: NSPOSIXErrorDomain 40"), @"receive fails with EMSGSIZE");
    expect(hasEvent(@"server: close 1009 ''"), @"the client closes with 1009");
    expect([task closeCode] == 0, @"no close code");
    dumpEvents(@"big");

    for (NSString *scenario in @[@"masked", @"badutf8", @"badopcode"])
    {
        task = taskFor(scenario);
        receive(task, @"receive");
        [task resume];
        expect(waitFor(@"complete NSPOSIXErrorDomain 100, state 3"), [scenario stringByAppendingString:@": a protocol error ends the task with EPROTO"]);
        expect(hasEvent(@"receive: NSPOSIXErrorDomain 100"), [scenario stringByAppendingString:@": receive fails with EPROTO"]);
        expect(hasEvent(@"server: close 1002 ''"), [scenario stringByAppendingString:@": the client closes with 1002"]);
        expect([task closeCode] == 0, [scenario stringByAppendingString:@": no close code"]);
        dumpEvents(scenario);
    }

    task = taskFor(@"drop");
    receive(task, @"receive");
    [task resume];
    expect(waitFor(@"complete NSPOSIXErrorDomain 57, state 3"), @"a lost connection ends the task with ENOTCONN");
    expect(hasEvent(@"receive: NSPOSIXErrorDomain 57"), @"receive fails with ENOTCONN");
    dumpEvents(@"drop");
}

static void testFragments(void)
{
    NSURLSessionWebSocketTask *task = taskFor(@"fragments");
    receive(task, @"receive");
    [task resume];
    expect(waitFor(@"receive: text 'hello world'"), @"fragments make one message, with a ping in between");
    [task cancel];
    expect(waitFor(@"complete NSURLErrorDomain -999, state 3"), @"cancel ends the task as cancelled");
    expect(hasEvent(@"server: close, 0 bytes"), @"cancel sends a close without a code");
    expect([task closeCode] == 0, @"cancel has no close code");
    expect(!hasEvent(@"close 0 '(nil)'"), @"cancel does not tell of a close");
    dumpEvents(@"fragments");
}

static void testEarlyCancel(void)
{
    NSURLSessionWebSocketTask *task = taskFor(@"echo");
    [task cancel];
    receive(task, @"receive");
    expect(waitFor(@"complete NSURLErrorDomain -999, state 3"), @"cancel before resume");
    expect(hasEvent(@"receive: NSURLErrorDomain -999") && hasEvent(@"metrics"), @"receive is cancelled, metrics delivered");
    expect([task response] == nil, @"no response");
    expect(!hasEvent(@"server: GET /echo"), @"no connection");

    task = taskFor(@"echo");
    [task cancelWithCloseCode:4005 reason:nil];
    expect(waitFor(@"complete NSURLErrorDomain -999, state 3"), @"a close before resume is a cancel");
    expect([task closeCode] == 0, @"without a close code");
    [task resume];
    runFor(0.3);
    expect([task state] == NSURLSessionTaskStateCompleted, @"resume after the end does nothing");
    dumpEvents(@"early cancel");
}

static void testSuspend(void)
{
    NSURLSessionWebSocketTask *task = taskFor(@"echo");
    [task resume];
    waitFor(@"open (nil), state 0, status 101");
    [task suspend];
    expect([task state] == NSURLSessionTaskStateSuspended, @"suspended");
    sendText(task, @"while suspended", @"send");
    receive(task, @"receive");
    runFor(0.5);
    expect(!hasEvent(@"server: text 'while suspended'"), @"nothing is sent while suspended");
    [task resume];
    expect(waitFor(@"receive: text 'while suspended'"), @"resume sends it");
    [task cancelWithCloseCode:1000 reason:nil];
    waitFor(@"complete nil, state 3");
    dumpEvents(@"suspend");
}

static void testTaskDelegate(void)
{
    NSURLSessionWebSocketTask *task = taskFor(@"echo");
    expect([task delegate] == nil, @"no task delegate by default");
    TaskDelegate *delegate = [[TaskDelegate alloc] init];
    [task setDelegate:delegate];
    expect([task delegate] == delegate, @"the task has its delegate");
    expect([delegate retainCount] > 1, @"the task retains its delegate");
    [task resume];
    waitFor(@"open (nil), state 0, status 101");
    [task cancelWithCloseCode:1000 reason:nil];
    expect(waitFor(@"task delegate: complete nil"), @"the task's delegate hears of the completion");
    expect(!hasEvent(@"complete nil, state 3"), @"the session's delegate does not");
    expect(hasEvent(@"open (nil), state 0, status 101") && hasEvent(@"metrics"),
           @"the session's delegate gets what the task's delegate does not implement");
    expect([task delegate] == nil, @"the task lets go of its delegate when it completes");
    [delegate release];
    dumpEvents(@"task delegate");
}

static void testRequest(void)
{
    resetEvents();
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:urlFor(@"ws", @"echo")];
    [request setValue:@"yes" forHTTPHeaderField:@"X-Client"];
    NSURLSessionWebSocketTask *task = [session webSocketTaskWithRequest:request];
    expect([[[[task originalRequest] URL] scheme] isEqualToString:@"ws"], @"a request keeps its URL");
    expect([[[task currentRequest] valueForHTTPHeaderField:@"X-Client"] isEqualToString:@"yes"], @"and its fields");
    receive(task, @"receive");
    sendText(task, @"via request", @"send");
    [task resume];
    expect(waitFor(@"receive: text 'via request'"), @"a task made from a request works");
    [task cancelWithCloseCode:1000 reason:nil];
    waitFor(@"complete nil, state 3");
    dumpEvents(@"request");
}

int main(void)
{
    @autoreleasepool
    {
        events = [[NSMutableArray alloc] init];
        startServer();
        SessionDelegate *delegate = [[[SessionDelegate alloc] init] autorelease];
        session = [[NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                 delegate:delegate
                                            delegateQueue:[NSOperationQueue mainQueue]] retain];

        testCreation();
        testEcho();
        testCloseReply();
        testServerClose();
        testFailures();
        testFragments();
        testEarlyCancel();
        testSuspend();
        testTaskDelegate();
        testRequest();

        [session invalidateAndCancel];
        [session release];
    }

    if (failures == 0)
        NSLog(@"PASS");
    return failures != 0;
}

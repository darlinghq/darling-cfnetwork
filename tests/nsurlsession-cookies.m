#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// Cookies of NSURLSession tasks, with the session configuration's
// HTTPCookieStorage
// (https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpcookiestorage),
// as observed on macOS 26.7.3:
// - a request carries the stored cookies for its URL, and the cookies a
//   response sets (redirects included) are stored, so that the redirected
//   request already carries them;
// - neither happens if the configuration's HTTPShouldSetCookies or the
//   request's HTTPShouldHandleCookies is NO, or there is no storage;
// - a Cookie header of the request or of the configuration's
//   HTTPAdditionalHeaders is sent instead of the stored cookies, which are
//   still updated from the responses;
// - the storage's accept policy applies, with the request's mainDocumentURL;
// - the session gets and stores the cookies with the storage's
//   -getCookiesForTask:completionHandler: and -storeCookies:forTask:, which a
//   subclass can override;
// - a WebSocket task's opening handshake carries the stored cookies too, and
//   the cookies of the handshake response are stored.

@interface NSHTTPCookieStorage (PrivateSPI)
- (id)_initWithIdentifier:(NSString *)identifier private:(bool)isPrivate;
@end

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition)
        failures++;
}

static void expectEqual(NSString *got, NSString *expected, NSString *what)
{
    BOOL ok = [got isEqualToString:expected];
    expect(ok, ok ? what : [NSString stringWithFormat:@"%@ (got \"%@\", expected \"%@\")", what, got, expected]);
}

static int listener;
static int port;

static char lastWebSocketCookie[2048];

// The Sec-WebSocket-Accept value for a key (RFC 6455, section 4.2.2).
static NSString *acceptValue(const char *key)
{
    NSString *text = [NSString stringWithFormat:@"%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(text.UTF8String, (CC_LONG)strlen(text.UTF8String), digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

// GET /set/<cookie> sets the cookie, /redir/<cookie> sets it and redirects to
// /echo; every response's body is "cookie[<the request's Cookie header>]".
// A WebSocket opening handshake is accepted with a response that sets "ws=1",
// and its Cookie header kept in lastWebSocketCookie.
static void *serve(void *unused)
{
    for (;;)
    {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            return NULL;
        char request[8192];
        size_t length = 0;
        while (length < sizeof(request) - 1 && read(fd, request + length, 1) == 1)
        {
            length++;
            if (length >= 4 && memcmp(request + length - 4, "\r\n\r\n", 4) == 0)
                break;
        }
        request[length] = '\0';

        char path[1024] = "";
        sscanf(request, "GET %1023s", path);
        char cookie[2048] = "";
        const char *field = strcasestr(request, "\r\nCookie:");
        if (field != NULL)
        {
            field += strlen("\r\nCookie:");
            while (*field == ' ')
                field++;
            size_t n = strcspn(field, "\r");
            if (n >= sizeof(cookie))
                n = sizeof(cookie) - 1;
            memcpy(cookie, field, n);
            cookie[n] = '\0';
        }

        const char *key = strcasestr(request, "\r\nSec-WebSocket-Key:");
        if (key != NULL)
        {
            key += strlen("\r\nSec-WebSocket-Key:");
            while (*key == ' ')
                key++;
            char keyText[128];
            size_t n = strcspn(key, "\r");
            if (n >= sizeof(keyText))
                n = sizeof(keyText) - 1;
            memcpy(keyText, key, n);
            keyText[n] = '\0';
            strcpy(lastWebSocketCookie, cookie);
            @autoreleasepool
            {
                NSString *response = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                                                 @"Sec-WebSocket-Accept: %@\r\nSet-Cookie: ws=1; Path=/\r\n\r\n", acceptValue(keyText)];
                write(fd, response.UTF8String, strlen(response.UTF8String));
            }
            // the connection stays open; the client cancels its task
            continue;
        }

        char body[2200];
        snprintf(body, sizeof(body), "cookie[%s]", cookie);
        char head[2048];
        if (strncmp(path, "/set/", 5) == 0)
            snprintf(head, sizeof(head), "HTTP/1.1 200 OK\r\nSet-Cookie: %s; Path=/\r\n", path + 5);
        else if (strncmp(path, "/redir/", 7) == 0)
            snprintf(head, sizeof(head), "HTTP/1.1 302 Found\r\nSet-Cookie: %s; Path=/\r\nLocation: /echo\r\n", path + 7);
        else
            snprintf(head, sizeof(head), "HTTP/1.1 200 OK\r\n");
        char response[4400];
        snprintf(response, sizeof(response), "%sContent-Length: %zu\r\nConnection: close\r\n\r\n%s", head, strlen(body), body);
        write(fd, response, strlen(response));
        close(fd);
    }
}

static NSMutableArray *calls;

@interface RecordingStorage : NSHTTPCookieStorage
@end

@implementation RecordingStorage

- (void)getCookiesForTask:(NSURLSessionTask *)task completionHandler:(void (^)(NSArray *))completionHandler
{
    @synchronized(calls)
    {
        [calls addObject:[NSString stringWithFormat:@"get %@", task.currentRequest.URL.path]];
    }
    [super getCookiesForTask:task completionHandler:completionHandler];
}

- (void)storeCookies:(NSArray *)cookies forTask:(NSURLSessionTask *)task
{
    @synchronized(calls)
    {
        [calls addObject:[NSString stringWithFormat:@"store %lu", (unsigned long)cookies.count]];
    }
    [super storeCookies:cookies forTask:task];
}

- (NSArray *)cookiesForURL:(NSURL *)URL
{
    @synchronized(calls)
    {
        [calls addObject:@"cookiesForURL"];
    }
    return [super cookiesForURL:URL];
}

- (void)setCookies:(NSArray *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL
{
    @synchronized(calls)
    {
        [calls addObject:@"setCookies"];
    }
    [super setCookies:cookies forURL:URL mainDocumentURL:mainDocumentURL];
}

@end

static NSString *fetch(NSURLSession *session, NSString *host, NSString *path, void (^tweak)(NSMutableURLRequest *))
{
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d%@", host, port, path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (tweak)
        tweak(request);
    __block NSString *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        result = error ? [[NSString alloc] initWithFormat:@"error %ld", (long)error.code] : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0)
        return @"timeout";
    dispatch_release(done);
    return [result autorelease];
}

static NSString *stored(NSHTTPCookieStorage *storage)
{
    NSMutableArray *result = [NSMutableArray array];
    for (NSHTTPCookie *c in storage.cookies)
        [result addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
    [result sortUsingSelector:@selector(compare:)];
    return [result componentsJoinedByString:@","];
}

// Runs /echo, /set/new=2 and /redir/rd=3 on a session whose storage holds
// "pre=1" for 127.0.0.1, and returns what the server saw and what was stored.
static NSString *run(NSHTTPCookieStorage *storage, NSString *host,
                     void (^configure)(NSURLSessionConfiguration *, NSHTTPCookieStorage *),
                     void (^tweak)(NSMutableURLRequest *))
{
    if (storage == nil)
    {
        storage = [[[NSHTTPCookieStorage alloc] _initWithIdentifier:nil private:YES] autorelease];
        storage.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    }
    [storage setCookie:[NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"pre", NSHTTPCookieValue: @"1", NSHTTPCookieDomain: @"127.0.0.1", NSHTTPCookiePath: @"/" }]];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPCookieStorage = storage;
    if (configure)
        configure(configuration, storage);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSString *echo = fetch(session, host, @"/echo", tweak);
    NSString *set = fetch(session, host, @"/set/new=2", tweak);
    NSString *redirect = fetch(session, host, @"/redir/rd=3", tweak);
    [session invalidateAndCancel];
    return [NSString stringWithFormat:@"%@ %@ %@ stored[%@]", echo, set, redirect, stored(storage)];
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool
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

        NSString *all = @"cookie[pre=1] cookie[pre=1] cookie[new=2; pre=1; rd=3] stored[new=2,pre=1,rd=3]";
        NSString *none = @"cookie[] cookie[] cookie[] stored[pre=1]";

        expectEqual(run(nil, @"127.0.0.1", nil, nil), all, @"stored cookies are sent and the responses' cookies stored, redirects included");
        expectEqual(run(nil, @"127.0.0.1", ^(NSURLSessionConfiguration *c, NSHTTPCookieStorage *s) { c.HTTPShouldSetCookies = NO; }, nil),
                    none, @"HTTPShouldSetCookies NO: no cookies are sent or stored");
        expectEqual(run(nil, @"127.0.0.1", nil, ^(NSMutableURLRequest *r) { r.HTTPShouldHandleCookies = NO; }),
                    none, @"HTTPShouldHandleCookies NO: no cookies are sent or stored");
        expectEqual(run(nil, @"127.0.0.1", ^(NSURLSessionConfiguration *c, NSHTTPCookieStorage *s) { c.HTTPCookieStorage = nil; }, nil),
                    none, @"no storage: no cookies are sent");
        expectEqual(run(nil, @"127.0.0.1", nil, ^(NSMutableURLRequest *r) { [r setValue:@"mine=x" forHTTPHeaderField:@"Cookie"]; }),
                    @"cookie[mine=x] cookie[mine=x] cookie[mine=x] stored[new=2,pre=1,rd=3]", @"a Cookie header of the request is sent instead");
        expectEqual(run(nil, @"127.0.0.1", ^(NSURLSessionConfiguration *c, NSHTTPCookieStorage *s) { c.HTTPAdditionalHeaders = @{ @"Cookie": @"add=y" }; }, nil),
                    @"cookie[add=y] cookie[add=y] cookie[add=y] stored[new=2,pre=1,rd=3]", @"a Cookie header of HTTPAdditionalHeaders is sent instead");
        expectEqual(run(nil, @"127.0.0.1", ^(NSURLSessionConfiguration *c, NSHTTPCookieStorage *s) {
                        c.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
                        s.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
                    }, nil),
                    @"cookie[pre=1] cookie[pre=1] cookie[pre=1] stored[pre=1]", @"the storage's accept policy Never applies");

        void (^mainDocumentPolicy)(NSURLSessionConfiguration *, NSHTTPCookieStorage *) = ^(NSURLSessionConfiguration *c, NSHTTPCookieStorage *s) {
            s.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain;
        };
        expectEqual(run(nil, @"localhost", mainDocumentPolicy, ^(NSMutableURLRequest *r) { r.mainDocumentURL = [NSURL URLWithString:@"http://other.example/"]; }),
                    @"cookie[] cookie[] cookie[] stored[pre=1]", @"main document policy: another site's main document");
        expectEqual(run(nil, @"localhost", mainDocumentPolicy, ^(NSMutableURLRequest *r) { r.mainDocumentURL = r.URL; }),
                    @"cookie[] cookie[] cookie[new=2; rd=3] stored[new=2,pre=1,rd=3]", @"main document policy: the same site's main document");

        {
            NSHTTPCookieStorage *storage = [[[NSHTTPCookieStorage alloc] _initWithIdentifier:nil private:YES] autorelease];
            storage.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
            [storage setCookie:[NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"pre", NSHTTPCookieValue: @"1", NSHTTPCookieDomain: @"127.0.0.1", NSHTTPCookiePath: @"/" }]];
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            configuration.HTTPCookieStorage = storage;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%d/ws", port]];
            NSMutableArray *seen = [NSMutableArray array];
            for (int i = 0; i < 2; i++)
            {
                lastWebSocketCookie[0] = '\0';
                NSURLSessionWebSocketTask *task = [session webSocketTaskWithURL:url];
                [task resume];
                for (int wait = 0; wait < 100 && (lastWebSocketCookie[0] == '\0' || [storage cookiesForURL:[NSURL URLWithString:@"http://127.0.0.1/"]].count < 2); wait++)
                    usleep(50000);
                [seen addObject:[NSString stringWithUTF8String:lastWebSocketCookie]];
                [task cancel];
            }
            [session invalidateAndCancel];
            expectEqual([NSString stringWithFormat:@"%@ stored[%@]", [seen componentsJoinedByString:@" | "], stored(storage)],
                        @"pre=1 | pre=1; ws=1 stored[pre=1,ws=1]", @"WebSocket handshakes send and set cookies");
        }

        calls = [[NSMutableArray alloc] init];
        RecordingStorage *recording = [[[RecordingStorage alloc] init] autorelease];
        recording.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        run(recording, @"127.0.0.1", nil, nil);
        expectEqual([calls componentsJoinedByString:@", "],
                    @"get /echo, get /set/new=2, store 1, get /redir/rd=3, store 1, get /echo",
                    @"the session goes through -getCookiesForTask:completionHandler: and -storeCookies:forTask:");
    }
    printf(failures ? "FAILED\n" : "PASSED\n");
    return failures != 0;
}

// Copyright (C) 2026 Darling Developers
#import <Foundation/Foundation.h>

// -[NSURLSession resetWithCompletionHandler:] and -[NSURLSession flushWithCompletionHandler:].
// Documented contract: reset empties all cookies, caches and credential stores and ensures later
// requests use a new socket; flush ensures later requests use a new TCP connection; both call the
// handler on the delegate queue.
// https://developer.apple.com/documentation/foundation/urlsession/reset(completionhandler:)
// https://developer.apple.com/documentation/foundation/urlsession/flush(completionhandler:)
// Server: tests/urlsession-test-server.py; its /peer path answers with the client port of the
// connection, which tells connections apart.
// usage: nsurlsession-reset-flush HTTP_BASE
// e.g.   nsurlsession-reset-flush http://127.0.0.1:8766

static int failures;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

static NSString *peer(NSURLSession *session, NSString *base)
{
    __block NSString *port = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/peer"]];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data != nil)
            port = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
        expect(NO, @"/peer timed out");
    return port;
}

// Calls a reset or flush and returns the queue the handler ran on, or nil if it never ran.
static NSOperationQueue *callAndWait(void (^call)(void (^handler)(void)))
{
    __block NSOperationQueue *queue = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    call(^{
        queue = [NSOperationQueue currentQueue];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
        expect(NO, @"completion handler never ran");
    return queue;
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        if (argc != 2)
        {
            NSLog(@"usage: %s HTTP_BASE", argv[0]);
            return 2;
        }
        NSString *base = [NSString stringWithUTF8String:argv[1]];

        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:1 << 20 diskCapacity:0 diskPath:nil];
        NSURLCredentialStorage *credentials = [[NSURLCredentialStorage alloc] init];
        NSHTTPCookieStorage *cookies = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        [configuration setURLCache:cache];
        [configuration setURLCredentialStorage:credentials];
        [configuration setHTTPCookieStorage:cookies];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:delegateQueue];

        NSURLProtectionSpace *space = [[NSURLProtectionSpace alloc] initWithHost:@"reset.example" port:443 protocol:NSURLProtectionSpaceHTTPS realm:@"r" authenticationMethod:NSURLAuthenticationMethodHTTPBasic];
        NSURLCredential *credential = [NSURLCredential credentialWithUser:@"user" password:@"secret" persistence:NSURLCredentialPersistencePermanent];
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"reset-test", NSHTTPCookieValue: @"1", NSHTTPCookieDomain: @"reset.example", NSHTTPCookiePath: @"/" }];
        NSURLRequest *cachedRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://reset.example/cached"]];
        NSURLResponse *cachedResponse = [[NSURLResponse alloc] initWithURL:[cachedRequest URL] MIMEType:@"text/plain" expectedContentLength:2 textEncodingName:nil];
        NSCachedURLResponse *entry = [[NSCachedURLResponse alloc] initWithResponse:cachedResponse data:[NSData dataWithBytes:"hi" length:2]];

        void (^populate)(void) = ^{
            [credentials setCredential:credential forProtectionSpace:space];
            [cookies setCookie:cookie];
            [cache storeCachedResponse:entry forRequest:cachedRequest];
        };
        BOOL (^cookiePresent)(void) = ^BOOL {
            for (NSHTTPCookie *c in [cookies cookies])
                if ([[c name] isEqualToString:@"reset-test"])
                    return YES;
            return NO;
        };
        populate();
        expect([[credentials allCredentials] count] == 1 && cookiePresent() && [cache cachedResponseForRequest:cachedRequest] != nil, @"stores are populated");

        // a reused connection has the same client port; without that, the checks below prove nothing
        NSString *first = peer(session, base);
        NSString *second = peer(session, base);
        expect(first != nil && [first isEqualToString:second], @"two requests share a connection before the call");

        // flush: later requests use a new connection, the handler runs on the delegate queue, the stores stay
        NSOperationQueue *ran = callAndWait(^(void (^handler)(void)) { [session flushWithCompletionHandler:handler]; });
        expect(ran == delegateQueue, @"flush handler runs on the delegate queue");
        NSString *afterFlush = peer(session, base);
        expect(afterFlush != nil && ![afterFlush isEqualToString:first], @"a request after flush uses a new connection");
        expect([[credentials allCredentials] count] == 1 && cookiePresent() && [cache cachedResponseForRequest:cachedRequest] != nil, @"flush leaves cookies, credentials and cache alone");

        // reset: all three stores are emptied, later requests use a new connection, handler on the delegate queue
        ran = callAndWait(^(void (^handler)(void)) { [session resetWithCompletionHandler:handler]; });
        expect(ran == delegateQueue, @"reset handler runs on the delegate queue");
        expect([[credentials allCredentials] count] == 0, @"reset empties the credential store");
        expect([credentials defaultCredentialForProtectionSpace:space] == nil, @"reset leaves no default credential");
        expect(!cookiePresent(), @"reset empties the cookie store");
        expect([cache cachedResponseForRequest:cachedRequest] == nil, @"reset empties the cache");
        NSString *afterReset = peer(session, base);
        expect(afterReset != nil && ![afterReset isEqualToString:first] && ![afterReset isEqualToString:afterFlush], @"a request after reset uses a new connection");

        // a session with no stores of its own has nothing to empty and still calls the handler
        NSURLSession *bare = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:nil delegateQueue:delegateQueue];
        populate();
        ran = callAndWait(^(void (^handler)(void)) { [bare resetWithCompletionHandler:handler]; });
        expect(ran == delegateQueue, @"reset on a session without stores calls the handler on its delegate queue");
        expect([[credentials allCredentials] count] == 1 && cookiePresent(), @"the stores of another session are not emptied");

        [session invalidateAndCancel];
        [bare invalidateAndCancel];
        [credentials removeCredential:credential forProtectionSpace:space];
        [cookies deleteCookie:cookie];
    }
    if (failures == 0)
        NSLog(@"PASS");
    return failures;
}

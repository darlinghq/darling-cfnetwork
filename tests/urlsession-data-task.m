#import <Foundation/Foundation.h>

// NSURLSession data tasks against tests/urlsession-test-server.py.
// usage: urlsession-data-task HTTP_BASE [UNTRUSTED_HTTPS_BASE [TRUSTED_HTTPS_URL]]
// e.g.   urlsession-data-task http://127.0.0.1:8766 https://127.0.0.1:8767 https://example.com/

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

typedef struct
{
    NSData *data;
    NSHTTPURLResponse *response;
    NSError *error;
} Result;

static NSString *base;

static NSURL *url(NSString *path)
{
    return [NSURL URLWithString:[base stringByAppendingString:path]];
}

static Result run(NSURLSession *session, NSURLRequest *request, NSURLSessionDataTask **taskOut)
{
    __block Result result = { nil, nil, nil };
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        result.data = data;
        result.response = (NSHTTPURLResponse *)response;
        result.error = error;
        dispatch_semaphore_signal(done);
    }];
    expect([task state] == NSURLSessionTaskStateSuspended, @"new task is suspended");
    [task resume];
    expect([task state] != NSURLSessionTaskStateSuspended, @"resumed task is not suspended");
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
        expect(NO, [NSString stringWithFormat:@"%@ timed out", [request URL]]);
    if (taskOut)
        *taskOut = task;
    return result;
}

static NSDictionary *json(NSData *data)
{
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}

static NSString *string(NSData *data)
{
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void testConfiguration(void)
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    expect([configuration timeoutIntervalForRequest] == 60, @"default request timeout");
    expect([configuration timeoutIntervalForResource] == 604800, @"default resource timeout");
    expect([configuration HTTPMaximumConnectionsPerHost] == 6, @"default connections per host");
    expect([configuration allowsCellularAccess], @"default allowsCellularAccess");
    expect([configuration HTTPCookieStorage] == [NSHTTPCookieStorage sharedHTTPCookieStorage], @"default cookie storage");
    expect([configuration URLCache] == [NSURLCache sharedURLCache], @"default URL cache");
    expect([NSURLSessionConfiguration defaultSessionConfiguration] != configuration, @"defaultSessionConfiguration returns a new object");

    NSURLSessionConfiguration *ephemeral = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    expect([ephemeral HTTPCookieStorage] == nil && [ephemeral URLCache] == nil, @"ephemeral has no persistent stores");

    [configuration setHTTPAdditionalHeaders:@{ @"X-Session": @"s" }];
    [configuration setTimeoutIntervalForRequest:5];
    NSURLSessionConfiguration *copy = [configuration copy];
    expect([[copy HTTPAdditionalHeaders] isEqual:@{ @"X-Session": @"s" }] && [copy timeoutIntervalForRequest] == 5, @"configuration copy");
    [configuration setTimeoutIntervalForRequest:9];
    expect([copy timeoutIntervalForRequest] == 5, @"configuration copy is independent");

    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [configuration setTimeoutIntervalForRequest:7];
    expect([[session configuration] timeoutIntervalForRequest] == 9, @"session copies its configuration");

    expect([NSURLSession sharedSession] == [NSURLSession sharedSession], @"sharedSession is a singleton");
    expect([[NSURLSession sharedSession] isKindOfClass:[NSURLSession class]], @"sharedSession is an NSURLSession");
    expect([[NSURLSession sharedSession] delegateQueue] != nil, @"sharedSession has a delegate queue");
}

static void testGet(void)
{
    NSURLSessionDataTask *task = nil;
    Result r = run([NSURLSession sharedSession], [NSURLRequest requestWithURL:url(@"/text")], &task);
    expect(r.error == nil, [NSString stringWithFormat:@"GET error %@", r.error]);
    expect([string(r.data) isEqualToString:@"hello from host\n"], @"GET body");
    expect([r.response isKindOfClass:[NSHTTPURLResponse class]], @"GET response class");
    expect([r.response statusCode] == 200, @"GET status");
    expect([[r.response MIMEType] isEqualToString:@"text/plain"], [NSString stringWithFormat:@"GET MIME type %@", [r.response MIMEType]]);
    expect([[r.response textEncodingName] isEqualToString:@"utf-8"], @"GET text encoding");
    expect([r.response expectedContentLength] == 16, @"GET expected length");
    expect([[[r.response allHeaderFields] objectForKey:@"Content-Length"] isEqualToString:@"16"], @"GET Content-Length header");
    expect([[[r.response URL] absoluteString] isEqualToString:[url(@"/text") absoluteString]], @"GET response URL");
    expect([task state] == NSURLSessionTaskStateCompleted, @"GET task completed");
    expect([task countOfBytesReceived] == 16, @"GET countOfBytesReceived");
    expect([task countOfBytesExpectedToReceive] == 16, @"GET countOfBytesExpectedToReceive");
    expect([task response] == r.response, @"task.response");
    expect([task error] == nil, @"task.error nil on success");

    Result chunked = run([NSURLSession sharedSession], [NSURLRequest requestWithURL:url(@"/chunked")], NULL);
    expect([string(chunked.data) isEqualToString:@"one two three"], @"chunked body");
    expect([chunked.response expectedContentLength] == NSURLResponseUnknownLength, @"chunked expected length is unknown");

    Result empty = run([NSURLSession sharedSession], [NSURLRequest requestWithURL:url(@"/empty")], NULL);
    expect(empty.error == nil && [empty.response statusCode] == 204 && [empty.data length] == 0, @"204 response");

    Result notFound = run([NSURLSession sharedSession], [NSURLRequest requestWithURL:url(@"/status?code=404")], NULL);
    expect(notFound.error == nil && [notFound.response statusCode] == 404, @"404 is a response, not an error");
    expect([string(notFound.data) isEqualToString:@"status body"], @"404 body");

    Result dup = run([NSURLSession sharedSession], [NSURLRequest requestWithURL:url(@"/duplicate-headers")], NULL);
    expect([[[dup.response allHeaderFields] objectForKey:@"X-Dup"] isEqualToString:@"a, b"], @"repeated headers are joined");
    expect([[[dup.response allHeaderFields] objectForKey:@"x-dup"] isEqualToString:@"a, b"], @"header lookup ignores case");

    __block NSData *viaURL = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithURL:url(@"/echo") completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        viaURL = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    expect([[json(viaURL) objectForKey:@"method"] isEqualToString:@"GET"], @"dataTaskWithURL sends GET");
}

static void testMethodsAndHeaders(void)
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    [configuration setHTTPAdditionalHeaders:@{ @"X-Session": @"session", @"X-Override": @"session" }];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

    NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:url(@"/echo")];
    [post setHTTPMethod:@"POST"];
    [post setHTTPBody:[@"name=value&x=1" dataUsingEncoding:NSUTF8StringEncoding]];
    [post setValue:@"application/x-test" forHTTPHeaderField:@"Content-Type"];
    [post setValue:@"request" forHTTPHeaderField:@"X-Override"];
    [post setValue:@"yes" forHTTPHeaderField:@"X-Test"];
    NSURLSessionDataTask *task = nil;
    Result r = run(session, post, &task);
    NSDictionary *echo = json(r.data);
    NSDictionary *headers = [echo objectForKey:@"headers"];
    expect(r.error == nil && [r.response statusCode] == 200, @"POST status");
    expect([[echo objectForKey:@"method"] isEqualToString:@"POST"], @"POST method");
    expect([[echo objectForKey:@"body"] isEqualToString:@"name=value&x=1"], @"POST body");
    expect([[headers objectForKey:@"content-type"] isEqualToString:@"application/x-test"], @"POST Content-Type");
    expect([[headers objectForKey:@"x-test"] isEqualToString:@"yes"], @"request header");
    expect([[headers objectForKey:@"x-session"] isEqualToString:@"session"], @"HTTPAdditionalHeaders");
    expect([[headers objectForKey:@"x-override"] isEqualToString:@"request"], @"request header wins over HTTPAdditionalHeaders");
    expect([[headers objectForKey:@"user-agent"] rangeOfString:@"CFNetwork/"].location != NSNotFound, [NSString stringWithFormat:@"User-Agent %@", [headers objectForKey:@"user-agent"]]);
    expect([headers objectForKey:@"expect"] == nil, @"no Expect header");
    expect([[[r.response MIMEType] lowercaseString] isEqualToString:@"application/json"], @"POST response MIME type");
    expect([task countOfBytesExpectedToSend] == 14 && [task countOfBytesSent] == 14, [NSString stringWithFormat:@"POST byte counts %lld/%lld", [task countOfBytesSent], [task countOfBytesExpectedToSend]]);

    NSMutableURLRequest *put = [NSMutableURLRequest requestWithURL:url(@"/echo")];
    [put setHTTPMethod:@"PUT"];
    [put setHTTPBody:[@"put body" dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary *putEcho = json(run(session, put, NULL).data);
    expect([[putEcho objectForKey:@"method"] isEqualToString:@"PUT"] && [[putEcho objectForKey:@"body"] isEqualToString:@"put body"], @"PUT with body");

    NSMutableURLRequest *del = [NSMutableURLRequest requestWithURL:url(@"/echo")];
    [del setHTTPMethod:@"DELETE"];
    expect([[json(run(session, del, NULL).data) objectForKey:@"method"] isEqualToString:@"DELETE"], @"DELETE");

    NSMutableURLRequest *head = [NSMutableURLRequest requestWithURL:url(@"/text")];
    [head setHTTPMethod:@"HEAD"];
    Result h = run(session, head, NULL);
    expect(h.error == nil && [h.response statusCode] == 200 && [h.data length] == 0 && [h.response expectedContentLength] == 16, @"HEAD");

    NSMutableURLRequest *injected = [NSMutableURLRequest requestWithURL:url(@"/echo")];
    [injected setValue:@"a\r\nX-Injected: 1" forHTTPHeaderField:@"X-Bad"];
    [injected setValue:@"kept" forHTTPHeaderField:@"X-Good"];
    NSDictionary *injectedHeaders = [json(run(session, injected, NULL).data) objectForKey:@"headers"];
    expect([injectedHeaders objectForKey:@"x-injected"] == nil && [injectedHeaders objectForKey:@"x-bad"] == nil, @"header value with CR LF is not sent");
    expect([[injectedHeaders objectForKey:@"x-good"] isEqualToString:@"kept"], @"valid header next to an invalid one");

    NSMutableURLRequest *emptyPost = [NSMutableURLRequest requestWithURL:url(@"/echo")];
    [emptyPost setHTTPMethod:@"POST"];
    NSDictionary *emptyEcho = json(run(session, emptyPost, NULL).data);
    expect([[emptyEcho objectForKey:@"method"] isEqualToString:@"POST"] && [[[emptyEcho objectForKey:@"headers"] objectForKey:@"content-length"] isEqualToString:@"0"], @"POST without body");
    [session finishTasksAndInvalidate];
}

static void testRedirects(void)
{
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = nil;
    NSURLRequest *request = [NSURLRequest requestWithURL:url(@"/redirect?status=302&to=/text")];
    Result r = run(session, request, &task);
    expect(r.error == nil && [r.response statusCode] == 200 && [string(r.data) isEqualToString:@"hello from host\n"], @"302 is followed");
    expect([[[r.response URL] path] isEqualToString:@"/text"], @"redirected response URL");
    expect([[[[task currentRequest] URL] path] isEqualToString:@"/text"], @"currentRequest follows the redirect");
    expect([[[[task originalRequest] URL] path] isEqualToString:@"/redirect"], @"originalRequest is unchanged");

    NSMutableURLRequest *post303 = [NSMutableURLRequest requestWithURL:url(@"/redirect?status=303&to=/echo")];
    [post303 setHTTPMethod:@"POST"];
    [post303 setHTTPBody:[@"dropped" dataUsingEncoding:NSUTF8StringEncoding]];
    [post303 setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *echo303 = json(run(session, post303, NULL).data);
    expect([[echo303 objectForKey:@"method"] isEqualToString:@"GET"] && [[echo303 objectForKey:@"body"] length] == 0, @"303 turns POST into GET");
    expect([[echo303 objectForKey:@"headers"] objectForKey:@"content-type"] == nil, @"303 drops Content-Type with the body");

    NSMutableURLRequest *post307 = [NSMutableURLRequest requestWithURL:url(@"/redirect?status=307&to=/echo")];
    [post307 setHTTPMethod:@"POST"];
    [post307 setHTTPBody:[@"kept" dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary *echo307 = json(run(session, post307, NULL).data);
    expect([[echo307 objectForKey:@"method"] isEqualToString:@"POST"] && [[echo307 objectForKey:@"body"] isEqualToString:@"kept"], @"307 keeps method and body");

    Result absolute = run(session, [NSURLRequest requestWithURL:url([@"/redirect?status=301&to=" stringByAppendingString:[url(@"/text") absoluteString]])], NULL);
    expect([absolute.response statusCode] == 200 && [[[absolute.response URL] path] isEqualToString:@"/text"], @"absolute Location");

    NSMutableURLRequest *authorized = [NSMutableURLRequest requestWithURL:url(@"/redirect?to=/echo")];
    [authorized setValue:@"Bearer t" forHTTPHeaderField:@"Authorization"];
    [authorized setValue:@"c=1" forHTTPHeaderField:@"Cookie"];
    NSDictionary *sameOrigin = [json(run(session, authorized, NULL).data) objectForKey:@"headers"];
    expect([[sameOrigin objectForKey:@"authorization"] isEqualToString:@"Bearer t"], @"same-origin redirect keeps Authorization");

    NSString *otherOrigin = [[url(@"/echo") absoluteString] stringByReplacingOccurrencesOfString:@"127.0.0.1" withString:@"localhost"];
    [authorized setURL:url([@"/redirect?to=" stringByAppendingString:otherOrigin])];
    Result crossed = run(session, authorized, NULL);
    NSDictionary *crossOrigin = [json(crossed.data) objectForKey:@"headers"];
    expect(crossed.error == nil && [[[crossed.response URL] host] isEqualToString:@"localhost"], [NSString stringWithFormat:@"cross-origin redirect %@", crossed.error]);
    expect([crossOrigin objectForKey:@"authorization"] == nil && [crossOrigin objectForKey:@"cookie"] == nil, @"cross-origin redirect drops Authorization and Cookie");

    Result loop = run(session, [NSURLRequest requestWithURL:url(@"/loop")], NULL);
    expect([loop.error code] == NSURLErrorHTTPTooManyRedirects && loop.data == nil, [NSString stringWithFormat:@"redirect loop error %@", loop.error]);
}

static void testErrors(NSString *untrustedBase, NSString *trustedURL)
{
    NSURLSession *session = [NSURLSession sharedSession];
    Result refused = run(session, [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/"]], NULL);
    expect([[refused.error domain] isEqualToString:NSURLErrorDomain] && [refused.error code] == NSURLErrorCannotConnectToHost, [NSString stringWithFormat:@"refused connection error %@", refused.error]);
    expect([[[refused.error userInfo] objectForKey:NSURLErrorFailingURLErrorKey] isEqual:[NSURL URLWithString:@"http://127.0.0.1:1/"]], @"failing URL in error");
    expect([[[refused.error userInfo] objectForKey:NSURLErrorFailingURLStringErrorKey] isEqualToString:@"http://127.0.0.1:1/"], @"failing URL string in error");
    expect(refused.data == nil && refused.response == nil, @"no data or response on error");

    Result unknownHost = run(session, [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://host.invalid/"]], NULL);
    expect([unknownHost.error code] == NSURLErrorCannotFindHost, [NSString stringWithFormat:@"unknown host error %@", unknownHost.error]);

    Result unsupported = run(session, [NSURLRequest requestWithURL:[NSURL URLWithString:@"gopher://127.0.0.1/"]], NULL);
    expect([unsupported.error code] == NSURLErrorUnsupportedURL, @"unsupported scheme error");

    NSURLRequest *slow = [NSURLRequest requestWithURL:url(@"/slow?seconds=4") cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:1];
    Result timedOut = run(session, slow, NULL);
    expect([timedOut.error code] == NSURLErrorTimedOut, [NSString stringWithFormat:@"request timeout error %@", timedOut.error]);

    NSURLSessionConfiguration *resourceLimited = [NSURLSessionConfiguration defaultSessionConfiguration];
    [resourceLimited setTimeoutIntervalForResource:1];
    Result resourceTimeout = run([NSURLSession sessionWithConfiguration:resourceLimited], [NSURLRequest requestWithURL:url(@"/slow?seconds=4")], NULL);
    expect([resourceTimeout.error code] == NSURLErrorTimedOut, [NSString stringWithFormat:@"resource timeout error %@", resourceTimeout.error]);

    if (untrustedBase != nil)
    {
        Result untrusted = run(session, [NSURLRequest requestWithURL:[NSURL URLWithString:[untrustedBase stringByAppendingString:@"/text"]]], NULL);
        expect([untrusted.error code] == NSURLErrorServerCertificateUntrusted, [NSString stringWithFormat:@"self-signed HTTPS error %@", untrusted.error]);
    }
    if (trustedURL != nil)
    {
        Result trusted = run(session, [NSURLRequest requestWithURL:[NSURL URLWithString:trustedURL]], NULL);
        expect(trusted.error == nil && [trusted.response statusCode] == 200 && [trusted.data length] > 0, [NSString stringWithFormat:@"HTTPS %@: %@", trustedURL, trusted.error]);
    }
}

static void testCancel(void)
{
    __block NSError *cancelError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url(@"/slow?seconds=5") completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        cancelError = error;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    usleep(300000);
    [task cancel];
    expect([task state] == NSURLSessionTaskStateCanceling || [task state] == NSURLSessionTaskStateCompleted, @"cancel changes state");
    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    expect(waited == 0, @"cancel completes before the server answers");
    expect([cancelError code] == NSURLErrorCancelled, [NSString stringWithFormat:@"cancel error %@", cancelError]);
    expect([task state] == NSURLSessionTaskStateCompleted && [[task error] code] == NSURLErrorCancelled, @"cancelled task state and error");

    __block NSError *neverStarted = nil;
    dispatch_semaphore_t done2 = dispatch_semaphore_create(0);
    NSURLSessionDataTask *idle = [[NSURLSession sharedSession] dataTaskWithURL:url(@"/text") completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        neverStarted = error;
        dispatch_semaphore_signal(done2);
    }];
    [idle cancel];
    dispatch_semaphore_wait(done2, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    expect([neverStarted code] == NSURLErrorCancelled, @"cancelling a task that never started");
}

static void testSuspend(void)
{
    __block NSData *body = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url(@"/slow?seconds=1") completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        body = data;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    [task suspend];
    expect([task state] == NSURLSessionTaskStateSuspended, @"suspend");
    [task resume];
    expect([task state] == NSURLSessionTaskStateRunning, @"resume after suspend");
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    expect([string(body) isEqualToString:@"slow"], @"suspended task finishes after resume");
}

static void testInvalidation(void)
{
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    [session invalidateAndCancel];
    BOOL raised = NO;
    @try
    {
        [session dataTaskWithURL:url(@"/text")];
    }
    @catch (NSException *exception)
    {
        raised = YES;
    }
    expect(raised, @"creating a task on an invalidated session raises");

    [[NSURLSession sharedSession] invalidateAndCancel];
    Result r = run([NSURLSession sharedSession], [NSURLRequest requestWithURL:url(@"/text")], NULL);
    expect(r.error == nil, @"invalidating the shared session has no effect");
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        if (argc < 2)
        {
            fprintf(stderr, "usage: %s HTTP_BASE [UNTRUSTED_HTTPS_BASE [TRUSTED_HTTPS_URL]]\n", argv[0]);
            return 2;
        }
        base = [NSString stringWithUTF8String:argv[1]];
        NSString *untrusted = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
        NSString *trusted = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : nil;

        testConfiguration();
        testGet();
        testMethodsAndHeaders();
        testRedirects();
        testErrors(untrusted, trusted);
        testCancel();
        testSuspend();
        testInvalidation();
    }
    if (failures == 0)
        NSLog(@"PASS: urlsession-data-task");
    return failures == 0 ? 0 : 1;
}

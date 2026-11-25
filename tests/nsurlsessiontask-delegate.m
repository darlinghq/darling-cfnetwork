#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// NSURLSessionTask.delegate
// (https://developer.apple.com/documentation/foundation/urlsessiontask/delegate):
// a task's own delegate gets the task's delegate messages that it implements,
// the session's delegate gets the others, and the task holds its delegate
// until it completes. With a completion handler, the handler takes the place
// of the data and completion messages (observed on macOS 26.7.3).

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

static NSMutableArray *events;

static void record(NSString *event)
{
    @synchronized(events)
    {
        [events addObject:event];
    }
}

static BOOL hasEvent(NSString *event)
{
    @synchronized(events)
    {
        return [events containsObject:event];
    }
}

static BOOL waitFor(NSString *event)
{
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!hasEvent(event) && [limit timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    return hasEvent(event);
}

static int listener;
static int port;

// Answers every request with "hello".
static void *serve(void *unused)
{
    for (;;)
    {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            return NULL;
        char buffer[4096];
        size_t length = 0;
        while (length < sizeof(buffer) && read(fd, buffer + length, 1) == 1)
        {
            length++;
            if (length >= 4 && memcmp(buffer + length - 4, "\r\n\r\n", 4) == 0)
                break;
        }
        const char *response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
        write(fd, response, strlen(response));
        close(fd);
    }
}

@interface SessionDelegate : NSObject <NSURLSessionDataDelegate>
@end

@implementation SessionDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    record([NSString stringWithFormat:@"session: response %@", [task taskDescription]]);
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    record([NSString stringWithFormat:@"session: data %@", [task taskDescription]]);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    record([NSString stringWithFormat:@"session: complete %@", [task taskDescription]]);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics
{
    record([NSString stringWithFormat:@"session: metrics %@", [task taskDescription]]);
}

@end

@interface TaskDelegate : NSObject <NSURLSessionDataDelegate>
@end

@implementation TaskDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    record([NSString stringWithFormat:@"task: data %@ '%@'", [task taskDescription],
               [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]]);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    record([NSString stringWithFormat:@"task: complete %@ %@, delegate %@", [task taskDescription],
               error != nil ? @"error" : @"nil", [task delegate] == self ? @"held" : @"gone"]);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics
{
    record([NSString stringWithFormat:@"task: metrics %@", [task taskDescription]]);
}

@end

int main(void)
{
    @autoreleasepool
    {
        events = [[NSMutableArray alloc] init];
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
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", port]];

        SessionDelegate *sessionDelegate = [[[SessionDelegate alloc] init] autorelease];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                              delegate:sessionDelegate
                                                         delegateQueue:[NSOperationQueue mainQueue]];

        // A task delegate beside the session's.
        NSURLSessionDataTask *task = [session dataTaskWithURL:url];
        [task setTaskDescription:@"A"];
        expect([task delegate] == nil, @"no task delegate by default");
        TaskDelegate *taskDelegate = [[TaskDelegate alloc] init];
        [task setDelegate:taskDelegate];
        expect([task delegate] == taskDelegate, @"the task has its delegate");
        expect([taskDelegate retainCount] > 1, @"the task retains its delegate");
        [task resume];
        expect(waitFor(@"task: complete A nil, delegate held"), @"the task's delegate hears of the completion, holding on until then");
        expect(hasEvent(@"task: data A 'hello'") && hasEvent(@"task: metrics A"), @"and gets the data and the metrics");
        expect(hasEvent(@"session: response A"), @"the session's delegate gets what the task's delegate does not implement");
        expect(!hasEvent(@"session: data A") && !hasEvent(@"session: complete A") && !hasEvent(@"session: metrics A"),
               @"and nothing the task's delegate implements");
        expect([task delegate] == nil, @"the task lets go of its delegate after it completes");

        // With a completion handler.
        task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            record([NSString stringWithFormat:@"handler: %lu bytes", (unsigned long)[data length]]);
        }];
        [task setTaskDescription:@"B"];
        [task setDelegate:taskDelegate];
        [task resume];
        expect(waitFor(@"handler: 5 bytes"), @"the completion handler gets the data");
        expect(hasEvent(@"task: metrics B"), @"the task's delegate gets the metrics");
        expect(!hasEvent(@"task: data B 'hello'") && ![[events description] containsString:@"complete B"],
               @"the handler takes the place of the data and completion messages");

        // No task delegate: as before, everything goes to the session's.
        task = [session dataTaskWithURL:url];
        [task setTaskDescription:@"C"];
        [task resume];
        expect(waitFor(@"session: complete C"), @"without a task delegate the session's delegate hears of the completion");
        expect(hasEvent(@"session: data C") && hasEvent(@"session: metrics C"), @"and gets the data and metrics");

        // The shared session has no delegate, but a task delegate still works.
        task = [[NSURLSession sharedSession] dataTaskWithURL:url];
        [task setTaskDescription:@"D"];
        [task setDelegate:taskDelegate];
        [task resume];
        expect(waitFor(@"task: complete D nil, delegate held"), @"a task of the shared session calls its delegate");
        expect(hasEvent(@"task: data D 'hello'"), @"with the data");

        [taskDelegate release];
        [session invalidateAndCancel];
    }

    if (failures == 0)
        NSLog(@"PASS");
    return failures != 0;
}

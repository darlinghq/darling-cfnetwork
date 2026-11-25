#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

// -[NSURLSessionTask set_preconnect:] (SPI that WebKit uses): a preconnect
// task opens a connection to the server but sends no request. It completes
// without a response or data, with no error, and with the usual connection
// error when the server can't be reached (observed on macOS 26.7.3).

@interface NSURLSessionTask (PreconnectSPI)
@property (setter=set_preconnect:) BOOL _preconnect;
@end

static int failures = 0;

static void expect(BOOL condition, const char *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition)
        failures++;
}

static int listener;
static volatile int connections;
static volatile long requestBytes;

static void *serve(void *unused)
{
    for (;;)
    {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            return NULL;
        __sync_fetch_and_add(&connections, 1);
        // Whatever the client sends within a second counts as a request.
        struct pollfd p = { fd, POLLIN, 0 };
        if (poll(&p, 1, 1000) > 0)
        {
            char buffer[512];
            ssize_t n = read(fd, buffer, sizeof(buffer));
            if (n > 0)
                __sync_fetch_and_add(&requestBytes, n);
        }
        close(fd);
    }
}

@interface Delegate : NSObject <NSURLSessionDataDelegate>
@property BOOL done;
@property BOOL gotResponse;
@property BOOL gotData;
@property (retain) NSError *error;
@end

@implementation Delegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler
{
    self.gotResponse = YES;
    handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    self.gotData = YES;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    self.error = error;
    self.done = YES;
}
@end

static NSURLSessionDataTask *runPreconnect(NSURLSession *session, Delegate *delegate, NSURL *url)
{
    delegate.done = NO;
    delegate.gotResponse = NO;
    delegate.gotData = NO;
    delegate.error = nil;
    NSURLSessionDataTask *task = [session dataTaskWithURL:url];
    task._preconnect = YES;
    [task resume];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!delegate.done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return task;
}

static int freePort(int *fdOut)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { 0 };
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(fd, (struct sockaddr *)&address, sizeof(address));
    socklen_t length = sizeof(address);
    getsockname(fd, (struct sockaddr *)&address, &length);
    *fdOut = fd;
    return ntohs(address.sin_port);
}

int main(void)
{
    @autoreleasepool
    {
        int port = freePort(&listener);
        listen(listener, 8);
        pthread_t thread;
        pthread_create(&thread, NULL, serve, NULL);

        Delegate *delegate = [[Delegate new] autorelease];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                              delegate:delegate
                                                         delegateQueue:[NSOperationQueue mainQueue]];

        NSURLSessionDataTask *task = runPreconnect(session, delegate, [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/index.html", port]]);
        expect(task._preconnect, "the task keeps the setting");
        expect(delegate.done, "a preconnect task completes");
        expect(delegate.error == nil, "a preconnect task to a listening server completes without an error");
        expect(!delegate.gotResponse && !delegate.gotData && task.response == nil, "a preconnect task gets no response");
        expect(task.state == NSURLSessionTaskStateCompleted, "a preconnect task ends completed");
        // Give the server time to read anything the client sent.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        expect(connections >= 1, "a preconnect task connects to the server");
        expect(requestBytes == 0, "a preconnect task sends no request");

        int closed;
        int closedPort = freePort(&closed);
        close(closed);
        runPreconnect(session, delegate, [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", closedPort]]);
        expect(delegate.done, "a preconnect task to a closed port completes");
        expect([delegate.error.domain isEqualToString:NSURLErrorDomain] && delegate.error.code == NSURLErrorCannotConnectToHost,
               "a preconnect task to a closed port fails with NSURLErrorCannotConnectToHost");

        [session invalidateAndCancel];
    }
    return failures != 0;
}

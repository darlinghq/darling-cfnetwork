#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// NSURLSessionTaskMetrics and NSURLSessionTaskTransactionMetrics
// (https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics):
// the classes exist, a task delegate may implement
// URLSession:task:didFinishCollectingMetrics:, and a value that was not
// measured reads as nil, 0, NO or the Unknown case. NSURLSessionWebSocketTask
// is a kind of NSURLSessionTask, and its close codes are those of RFC 6455.

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

@interface MetricsDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation MetricsDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics
{
}
@end

int main(void)
{
    @autoreleasepool
    {
        expect(NSClassFromString(@"NSURLSessionTaskMetrics") != nil, @"NSURLSessionTaskMetrics exists");
        expect(NSClassFromString(@"NSURLSessionTaskTransactionMetrics") != nil, @"NSURLSessionTaskTransactionMetrics exists");
        expect([NSURLSessionWebSocketTask isSubclassOfClass:[NSURLSessionTask class]], @"a WebSocket task is a task");
        expect(@protocol(NSURLSessionTaskDelegate) != nil
               && protocol_getMethodDescription(@protocol(NSURLSessionTaskDelegate),
                      @selector(URLSession:task:didFinishCollectingMetrics:), NO, YES).name != NULL,
               @"the task delegate has an optional metrics method");

        NSURLSessionTaskTransactionMetrics *transaction = [[NSURLSessionTaskTransactionMetrics alloc] init];
        expect(transaction.fetchStartDate == nil && transaction.responseEndDate == nil, @"unmeasured dates are nil");
        expect(transaction.networkProtocolName == nil && transaction.remoteAddress == nil, @"unmeasured details are nil");
        expect(transaction.countOfResponseBodyBytesReceived == 0, @"unmeasured counts are 0");
        expect(!transaction.isReusedConnection && !transaction.isProxyConnection, @"unmeasured flags are NO");
        expect(transaction.resourceFetchType == NSURLSessionTaskMetricsResourceFetchTypeUnknown, @"fetch type unknown");
        expect(transaction.domainResolutionProtocol == NSURLSessionTaskMetricsDomainResolutionProtocolUnknown, @"resolution protocol unknown");
        [transaction release];

        NSURLSessionTaskMetrics *metrics = [[NSURLSessionTaskMetrics alloc] init];
        expect(metrics.transactionMetrics != nil && metrics.transactionMetrics.count == 0, @"no transactions");
        expect(metrics.taskInterval != nil && metrics.taskInterval.duration == 0, @"an empty task interval");
        expect(metrics.redirectCount == 0, @"no redirects");
        [metrics release];

        expect(NSURLSessionWebSocketCloseCodeNormalClosure == 1000 && NSURLSessionWebSocketCloseCodeGoingAway == 1001
               && NSURLSessionWebSocketCloseCodeNoStatusReceived == 1005
               && NSURLSessionWebSocketCloseCodeTLSHandshakeFailure == 1015, @"RFC 6455 close codes");
    }

    if (failures == 0)
        NSLog(@"PASS");
    return failures != 0;
}

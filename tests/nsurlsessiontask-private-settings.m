#import <Foundation/Foundation.h>

// Private task settings that WebKit sets on its data tasks. A new data task
// has NO, nil and 0 for all of them, each setter's value reads back, and the
// string settings are copied. The task has metrics before it has started.
// (Observed on macOS 26.7.3.)

@interface NSURLSessionTask (PrivateSettingsSPI)
@property (setter=set_preconnect:) BOOL _preconnect;
@property (setter=set_isTopLevelNavigation:) BOOL _isTopLevelNavigation;
@property (copy, setter=set_siteForCookies:) NSURL *_siteForCookies;
@property (copy, setter=set_storagePartitionIdentifier:) NSString *_storagePartitionIdentifier;
@property (setter=set_bytesPerSecondLimit:) int64_t _bytesPerSecondLimit;
@property (copy, setter=set_pathToDownloadTaskFile:) NSString *_pathToDownloadTaskFile;
@property (copy, setter=set_cookieTransformCallback:) NSArray *(^_cookieTransformCallback)(NSArray *);
@property (readonly) int64_t _countOfBytesReceivedEncoded;
@property (readonly) NSArray *_resolvedCNAMEChain;
@property (readonly) NSURLSessionTaskMetrics *_incompleteTaskMetrics;
- (void)_adoptEffectiveConfiguration:(NSURLSessionConfiguration *)configuration;
- (void)_setExplicitCookieStorage:(CFTypeRef)storage;
@end

static int failures = 0;

static void expect(BOOL condition, const char *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition)
        failures++;
}

int main(void)
{
    @autoreleasepool
    {
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
        NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:@"http://example.com/"]];

        expect(!task._preconnect, "_preconnect defaults to NO");
        expect(!task._isTopLevelNavigation, "_isTopLevelNavigation defaults to NO");
        expect(task._siteForCookies == nil, "_siteForCookies defaults to nil");
        expect(task._storagePartitionIdentifier == nil, "_storagePartitionIdentifier defaults to nil");
        expect(task._bytesPerSecondLimit == 0, "_bytesPerSecondLimit defaults to 0");
        expect(task._pathToDownloadTaskFile == nil, "_pathToDownloadTaskFile defaults to nil");
        expect(task._cookieTransformCallback == nil, "_cookieTransformCallback defaults to nil");
        expect(task._countOfBytesReceivedEncoded == 0, "_countOfBytesReceivedEncoded starts at 0");
        expect(task._resolvedCNAMEChain == nil, "_resolvedCNAMEChain starts nil");
        expect([task._incompleteTaskMetrics isKindOfClass:[NSURLSessionTaskMetrics class]], "_incompleteTaskMetrics exists before the task starts");

        task._preconnect = YES;
        task._isTopLevelNavigation = YES;
        NSURL *site = [NSURL URLWithString:@"http://site.example/"];
        task._siteForCookies = site;
        NSMutableString *partition = [NSMutableString stringWithString:@"part"];
        task._storagePartitionIdentifier = partition;
        [partition appendString:@"-changed"];
        task._bytesPerSecondLimit = 1000;
        task._pathToDownloadTaskFile = @"/tmp/download";

        expect(task._preconnect, "_preconnect reads back");
        expect(task._isTopLevelNavigation, "_isTopLevelNavigation reads back");
        expect([task._siteForCookies isEqual:site], "_siteForCookies reads back");
        expect([task._storagePartitionIdentifier isEqualToString:@"part"], "_storagePartitionIdentifier is copied");
        expect(task._bytesPerSecondLimit == 1000, "_bytesPerSecondLimit reads back");
        expect([task._pathToDownloadTaskFile isEqualToString:@"/tmp/download"], "_pathToDownloadTaskFile reads back");

        NSArray *(^transform)(NSArray *) = [[^NSArray *(NSArray *cookies) { return cookies; } copy] autorelease];
        task._cookieTransformCallback = transform;
        expect(task._cookieTransformCallback == transform, "_cookieTransformCallback reads back");
        task._cookieTransformCallback = nil;
        expect(task._cookieTransformCallback == nil, "_cookieTransformCallback can be cleared");

        task._siteForCookies = nil;
        expect(task._siteForCookies == nil, "_siteForCookies can be cleared");

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCredentialStorage = nil;
        [task _adoptEffectiveConfiguration:configuration];
        [task _setExplicitCookieStorage:NULL];
        expect(task.currentRequest.timeoutInterval == 60, "adopting a configuration leaves the request alone");
        [task cancel];
        [session invalidateAndCancel];
    }
    return failures != 0;
}

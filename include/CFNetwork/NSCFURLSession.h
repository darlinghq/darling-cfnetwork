#import <os/object.h>
#import <Foundation/NSURLSession.h>
#import <dispatch/dispatch.h>

@class NSOperationQueue, NSString, NSMutableSet, NSMutableData, NSMutableArray, NSLock, NSHTTPURLResponse;

// Concrete classes behind the abstract NSURLSession API. Instance variables
// live in these @interfaces so that the i386 (fragile ABI) build can lay them out.

__attribute__((visibility("hidden")))
@interface __NSCFURLSessionConfiguration : NSURLSessionConfiguration {
    NSString *_identifier;
    NSURLRequestCachePolicy _requestCachePolicy;
    NSTimeInterval _timeoutIntervalForRequest;
    NSTimeInterval _timeoutIntervalForResource;
    NSURLRequestNetworkServiceType _networkServiceType;
    BOOL _allowsCellularAccess;
    BOOL _discretionary;
    BOOL _sessionSendsLaunchEvents;
    NSDictionary *_connectionProxyDictionary;
    SSLProtocol _TLSMinimumSupportedProtocol;
    SSLProtocol _TLSMaximumSupportedProtocol;
    BOOL _HTTPShouldUsePipelining;
    BOOL _HTTPShouldSetCookies;
    NSHTTPCookieAcceptPolicy _HTTPCookieAcceptPolicy;
    NSDictionary *_HTTPAdditionalHeaders;
    NSInteger _HTTPMaximumConnectionsPerHost;
    NSHTTPCookieStorage *_HTTPCookieStorage;
    NSURLCredentialStorage *_URLCredentialStorage;
    NSURLCache *_URLCache;
    NSArray *_protocolClasses;
}
@end

__attribute__((visibility("hidden")))
@interface __NSCFURLSession : NSURLSession {
    NSURLSessionConfiguration *_configuration;
    BOOL _invalid;
    BOOL _isSharedSession;
    NSOperationQueue *_delegateQueue;
    id <NSURLSessionDelegate> _delegate;
    NSString *_sessionDescription;
    NSLock *_lock;
    NSMutableSet *_tasks;
    NSUInteger _nextTaskIdentifier;
}

- (id)initWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id <NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue;
- (void)_markShared;

@end

__attribute__((visibility("hidden")))
@interface __NSCFURLSessionDataTask : NSURLSessionDataTask {
    // Written under @synchronized(self), or on the transport thread.
    __NSCFURLSession *_session;
    NSUInteger _taskIdentifier;
    NSURLRequest *_originalRequest;
    NSURLRequest *_currentRequest;
    NSURLResponse *_response;
    int64_t _countOfBytesReceived;
    int64_t _countOfBytesSent;
    int64_t _countOfBytesExpectedToSend;
    int64_t _countOfBytesExpectedToReceive;
    NSString *_taskDescription;
    NSURLSessionTaskState _state;
    NSError *_error;
    NSUInteger _suspendCount;

    // Only touched on the transport thread.
    void (^_completionHandler)(NSData *data, NSURLResponse *response, NSError *error);
    void *_easy;
    void *_headerList;
    NSData *_uploadBody;
    char *_curlErrorBuffer;
    NSInteger _pendingStatusCode;
    NSString *_pendingHTTPVersion;
    NSMutableArray *_pendingHeaderLines;
    NSMutableData *_receivedData;
    NSURLRequest *_redirectRequest;
    NSUInteger _redirectCount;
    CFAbsoluteTime _resourceDeadline;
    BOOL _started;
    BOOL _finished;
}

- (id)_initWithSession:(__NSCFURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)identifier completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;

@end

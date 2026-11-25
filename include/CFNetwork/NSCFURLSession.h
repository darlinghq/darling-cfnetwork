#import <os/object.h>
#import <Foundation/NSURLSession.h>
#import <dispatch/dispatch.h>

@class _NSHSTSStorage, NSHTTPCookieStorage, NSURLSessionTaskMetrics, NSOperationQueue, NSString, NSData, NSSet, NSDictionary, NSMutableSet, NSMutableData, NSMutableArray, NSLock, NSHTTPURLResponse;

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
    BOOL _waitsForConnectivity;
    BOOL _allowsExpensiveNetworkAccess;
    BOOL _allowsConstrainedNetworkAccess;
    BOOL _requiresDNSSECValidation;
    NSURLSessionMultipathServiceType _multipathServiceType;
    BOOL _shouldUseExtendedBackgroundIdleMode;
    NSString *_sharedContainerIdentifier;
    uint16_t _TLSMinimumSupportedProtocolVersion;
    uint16_t _TLSMaximumSupportedProtocolVersion;
    // SPI that WebKit sets; kept and copied, but not acted on by Darling's loader.
    int64_t _timingDataOptions;
    NSData *_sourceApplicationAuditTokenData;
    NSString *_sourceApplicationBundleIdentifier;
    NSString *_sourceApplicationSecondaryIdentifier;
    NSString *_attributedBundleIdentifier;
    NSSet *_suppressedAutoAddedHTTPHeaders;
    NSDictionary *_socketStreamProperties;
    NSInteger _connectionCacheNumPriorityLevels;
    NSInteger _connectionCacheNumFastLanes;
    NSInteger _connectionCacheMinimumFastLanePriority;
    BOOL _shouldSkipPreferredClientCertificateLookup;
    BOOL _preventsSystemHTTPProxyAuthentication;
    BOOL _requiresSecureHTTPSProxyConnection;
    BOOL _usesNWLoader;
    BOOL _allowsHSTSWithUntrustedRootCertificate;
    BOOL _skipsStackTraceCapture;
@package
    // Set by NSURLSessionConfiguration's factory methods.
    _NSHSTSStorage *_hstsStorage;
    BOOL _ephemeral;
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
// The private per-task settings that NSURLSessionTask's SPI reads and writes. Every
// concrete task class holds one and returns it from -_settings.
__attribute__((visibility("hidden")))
@interface _NSURLSessionTaskSettings : NSObject {
    BOOL _preconnect;
    BOOL _isTopLevelNavigation;
    NSURL *_siteForCookies;
    NSString *_storagePartitionIdentifier;
    int64_t _bytesPerSecondLimit;
    NSString *_pathToDownloadTaskFile;
    id _hostOverride;
    id _explicitCookieStorage;
    NSURLSessionConfiguration *_effectiveConfiguration;
    NSArray *(^_cookieTransformCallback)(NSArray *cookies);
}
@property BOOL preconnect;
@property BOOL isTopLevelNavigation;
@property (copy) NSURL *siteForCookies;
@property (copy) NSString *storagePartitionIdentifier;
@property int64_t bytesPerSecondLimit;
@property (copy) NSString *pathToDownloadTaskFile;
@property (retain) id hostOverride;
@property (retain) id explicitCookieStorage;
@property (copy) NSURLSessionConfiguration *effectiveConfiguration;
@property (copy) NSArray *(^cookieTransformCallback)(NSArray *cookies);
@end

@interface NSURLSessionTask (CFNSettings)
- (_NSURLSessionTaskSettings *)_settings;
@end

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
    float _priority;
    id <NSURLSessionTaskDelegate> _delegate;

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
    NSMutableData *_redirectBody;
    NSURLRequest *_redirectRequest;
    NSHTTPURLResponse *_redirectResponse;
    NSUInteger _redirectCount;
    CFAbsoluteTime _resourceDeadline;
    CFAbsoluteTime _startTime;
    BOOL _started;
    BOOL _metricsReportedByOwner;
    BOOL _finished;
    BOOL _awaitingDisposition;
    BOOL _writePaused;
    BOOL _transferDoneWhileAwaiting;
    int _doneCode;
    void (^_bodyObserver)(int64_t received, int64_t expected);
    _NSURLSessionTaskSettings *_settings;
}

- (id)_initWithSession:(__NSCFURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)identifier completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;

// Metrics of the finished transfer; a task wrapping this one (a download task) reports them
// as its own instead of this task reporting them to the delegate.
- (NSURLSessionTaskMetrics *)_metrics;
- (void)_setMetricsReportedByOwner;

@end

typedef void (^DownloadTaskCompletionHandler)(NSURL *location, NSURLResponse *response, NSError *error);

__attribute__((visibility("hidden")))
@interface __NSCFURLSessionDownloadTask : NSURLSessionDownloadTask {
    __NSCFURLSession *_session;
    NSURLRequest *_originalRequest;
    NSURLRequest *_currentRequest;
    NSURLResponse *_response;
    NSURLSessionTaskState _state;
    NSError *_error;
    NSURLSessionDataTask *_innerTask;
    DownloadTaskCompletionHandler _completionHandler;
    NSUInteger _taskIdentifier;
    NSString *_taskDescription;
    int64_t _countOfBytesReceived;
    int64_t _countOfBytesExpectedToReceive;
    float _priority;
    id <NSURLSessionTaskDelegate> _delegate;
    _NSURLSessionTaskSettings *_settings;
}

- (id)_initWithSession:(__NSCFURLSession *)session request:(NSURLRequest *)request identifier:(NSUInteger)identifier completionHandler:(DownloadTaskCompletionHandler)completionHandler;

@end

typedef void (^_NSURLSessionWebSocketReceiveHandler)(NSURLSessionWebSocketMessage *message, NSError *error);

__attribute__((visibility("hidden")))
@interface __NSCFURLSessionWebSocketTask : NSURLSessionWebSocketTask {
    // Written under @synchronized(self), or on the transport thread.
    __NSCFURLSession *_session;
    NSUInteger _taskIdentifier;
    NSURLRequest *_originalRequest;
    NSURLRequest *_currentRequest;
    NSURLResponse *_response;
    NSString *_taskDescription;
    NSURLSessionTaskState _state;
    NSError *_error;
    float _priority;
    id <NSURLSessionTaskDelegate> _delegate;
    int64_t _countOfBytesReceived;
    int64_t _countOfBytesSent;
    NSInteger _maximumMessageSize;
    NSURLSessionWebSocketCloseCode _closeCode;
    NSData *_closeReason;
    BOOL _started;
    NSUInteger _suspendCount;

    // Only touched on the transport thread.
    void *_easy;
    char *_curlErrorBuffer;
    int _socket;
    int _phase;
    NSString *_key;
    NSString *_cookieHeader;
    NSArray *_protocols;
    CFAbsoluteTime _startTime;
    NSMutableData *_input;
    NSMutableData *_output;
    NSMutableArray *_writeCompletions;
    NSMutableArray *_waitingSends;
    NSMutableArray *_receiveHandlers;
    NSMutableArray *_messages;
    NSMutableArray *_pongHandlers;
    _NSURLSessionTaskSettings *_settings;
    uint32_t _nextPing;
    NSMutableData *_fragments;
    int _fragmentOpcode;
    BOOL _closeSent;
    BOOL _metricsDelivered;
    NSError *_terminalError;
}

- (id)_initWithSession:(__NSCFURLSession *)session request:(NSURLRequest *)request protocols:(NSArray *)protocols identifier:(NSUInteger)identifier;

@end

// The User-Agent of requests that do not set one.
__attribute__((visibility("hidden"))) NSString *_NSURLSessionDefaultUserAgent(void);

// The cookies of a task's requests (as observed on macOS 26.7.3; test: tests/nsurlsession-cookies.m).
// The storage of the cookies the request sends and its responses set, or nil if it neither sends
// nor sets any.
__attribute__((visibility("hidden"))) NSHTTPCookieStorage *_NSURLSessionCookieStorageForRequest(NSURLSessionConfiguration *configuration, NSURLRequest *request);
// A Cookie header of the request or of the session's additional headers is sent instead of the
// stored cookies.
__attribute__((visibility("hidden"))) BOOL _NSURLSessionHasCookieHeader(NSURLSessionConfiguration *configuration, NSURLRequest *request);
// Gets the value of the Cookie header with the stored cookies for the task's current request, from
// the storage's -getCookiesForTask:completionHandler:, and passes it (nil if there are none) to the
// block on the transport thread.
__attribute__((visibility("hidden"))) void _NSURLSessionGetCookieHeader(NSHTTPCookieStorage *storage, NSURLSessionTask *task, void (^block)(NSString *header));
// Stores the cookies a response of the task's current request sets.
__attribute__((visibility("hidden"))) void _NSURLSessionStoreResponseCookies(NSHTTPCookieStorage *storage, NSURLSessionTask *task, NSHTTPURLResponse *response);

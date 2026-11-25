//
//  NSURLSession.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/NSURLSession.h>
#import <Foundation/NSHTTPCookieStorage.h>
#import <Foundation/NSURLCache.h>
#import "NSCFURLSession.h"
#import "CFNSURLConnection.h"
#import "NSHSTSStorage.h"
#import <Foundation/NSBundle.h>
#import <Foundation/NSException.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSProcessInfo.h>

const int64_t NSURLSessionTransferSizeUnknown = -1LL;
NSString* const NSURLSessionDownloadTaskResumeData = @"NSURLSessionDownloadTaskResumeData";

const float NSURLSessionTaskPriorityDefault = 0.5;
const float NSURLSessionTaskPriorityLow = 0.25;
const float NSURLSessionTaskPriorityHigh = 0.75;

// Documented defaults of URLSessionConfiguration.
static const NSTimeInterval kDefaultRequestTimeout = 60;
static const NSTimeInterval kDefaultResourceTimeout = 7 * 24 * 60 * 60;
static const NSInteger kDefaultMaximumConnectionsPerHost = 6;

@implementation NSURLSession

@dynamic delegateQueue, delegate, configuration, sessionDescription;

+ (NSURLSession *)sharedSession
{
    static dispatch_once_t once = 0L;
    static __NSCFURLSession *sharedSession = nil;
    dispatch_once(&once, ^{
        sharedSession = [[__NSCFURLSession alloc] initWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:nil delegateQueue:nil];
        [sharedSession _markShared];
    });
    return sharedSession;
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
{
    return [self sessionWithConfiguration:configuration delegate:nil delegateQueue:nil];
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id <NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue
{
    return [[[__NSCFURLSession alloc] initWithConfiguration:configuration delegate:delegate delegateQueue:queue] autorelease];
}

@end

@implementation NSURLSessionTask

@dynamic taskIdentifier, originalRequest, currentRequest, response;
@dynamic countOfBytesReceived, countOfBytesSent, countOfBytesExpectedToSend, countOfBytesExpectedToReceive;
@dynamic taskDescription, state, error, priority, delegate;

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

@end

@implementation _NSURLSessionTaskSettings

@synthesize preconnect = _preconnect, isTopLevelNavigation = _isTopLevelNavigation;
@synthesize siteForCookies = _siteForCookies, storagePartitionIdentifier = _storagePartitionIdentifier;
@synthesize bytesPerSecondLimit = _bytesPerSecondLimit, pathToDownloadTaskFile = _pathToDownloadTaskFile;
@synthesize hostOverride = _hostOverride, explicitCookieStorage = _explicitCookieStorage;
@synthesize effectiveConfiguration = _effectiveConfiguration;
@synthesize cookieTransformCallback = _cookieTransformCallback;

- (void)dealloc
{
    [_siteForCookies release];
    [_storagePartitionIdentifier release];
    [_pathToDownloadTaskFile release];
    [_hostOverride release];
    [_explicitCookieStorage release];
    [_effectiveConfiguration release];
    [_cookieTransformCallback release];
    [super dealloc];
}

@end

// Private settings of a task that WebKit and other system frameworks use; their
// defaults (NO, nil and 0) are what macOS 26.7.3 gives for a new data task. Test:
// nsurlsessiontask-private-settings. Darling's loader acts on _preconnect,
// _bytesPerSecondLimit and the adopted configuration; the others are kept for
// callers to read back.
@implementation NSURLSessionTask (NSURLSessionTaskPrivate)

- (_NSURLSessionTaskSettings *)_settings
{
    return nil;
}

- (BOOL)_preconnect { return [[self _settings] preconnect]; }
- (void)set_preconnect:(BOOL)value { [[self _settings] setPreconnect:value]; }
- (BOOL)_isTopLevelNavigation { return [[self _settings] isTopLevelNavigation]; }
- (void)set_isTopLevelNavigation:(BOOL)value { [[self _settings] setIsTopLevelNavigation:value]; }
- (NSURL *)_siteForCookies { return [[self _settings] siteForCookies]; }
- (void)set_siteForCookies:(NSURL *)value { [[self _settings] setSiteForCookies:value]; }
- (NSString *)_storagePartitionIdentifier { return [[self _settings] storagePartitionIdentifier]; }
- (void)set_storagePartitionIdentifier:(NSString *)value { [[self _settings] setStoragePartitionIdentifier:value]; }
- (int64_t)_bytesPerSecondLimit { return [[self _settings] bytesPerSecondLimit]; }
- (void)set_bytesPerSecondLimit:(int64_t)value { [[self _settings] setBytesPerSecondLimit:value]; }
- (NSString *)_pathToDownloadTaskFile { return [[self _settings] pathToDownloadTaskFile]; }
- (void)set_pathToDownloadTaskFile:(NSString *)value { [[self _settings] setPathToDownloadTaskFile:value]; }

// A block that may change the cookies a response sets before they are stored. Darling's
// sessions store the cookies of responses without calling it.
- (NSArray *(^)(NSArray *))_cookieTransformCallback { return [[self _settings] cookieTransformCallback]; }
- (void)set_cookieTransformCallback:(NSArray *(^)(NSArray *))value { [[self _settings] setCookieTransformCallback:value]; }

// A Network framework endpoint (nw_endpoint_t) to connect to instead of the URL's host.
- (id)_hostOverride { return [[self _settings] hostOverride]; }
- (void)set_hostOverride:(id)value { [[self _settings] setHostOverride:value]; }

- (void)_setExplicitCookieStorage:(CFTypeRef)storage
{
    [[self _settings] setExplicitCookieStorage:(id)storage];
}

// The task uses this configuration in place of its session's.
- (void)_adoptEffectiveConfiguration:(NSURLSessionConfiguration *)configuration
{
    [[self _settings] setEffectiveConfiguration:configuration];
}

// Content-coded bytes of the response body. macOS reports 0 for a response
// without a Content-Encoding, and Darling doesn't count them otherwise yet.
- (int64_t)_countOfBytesReceivedEncoded
{
    return 0;
}

- (NSArray *)_resolvedCNAMEChain
{
    return nil;
}

// The task's metrics so far; there are metrics before the task has started.
- (NSURLSessionTaskMetrics *)_incompleteTaskMetrics
{
    NSDate *now = [NSDate date];
    NSDateInterval *interval = [[[NSDateInterval alloc] initWithStartDate:now endDate:now] autorelease];
    return [[[NSURLSessionTaskMetrics alloc] _initWithTaskInterval:interval redirectCount:0] autorelease];
}

@end

@implementation NSURLSessionDataTask
@end

@implementation NSURLSessionWebSocketMessage

- (instancetype)initWithData:(NSData *)data
{
    if ((self = [super init])) {
        _type = NSURLSessionWebSocketMessageTypeData;
        _data = [data copy];
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string
{
    if ((self = [super init])) {
        _type = NSURLSessionWebSocketMessageTypeString;
        _string = [string copy];
    }
    return self;
}

- (void)dealloc
{
    [_data release];
    [_string release];
    [super dealloc];
}

- (NSURLSessionWebSocketMessageType)type
{
    return _type;
}

// A message holds either data or a string; the other accessor returns nil.
- (NSData *)data
{
    return _data;
}

- (NSString *)string
{
    return _string;
}

@end


// Darling's sessions do not measure their transactions yet, so every value is
// one that was not measured: nil, 0, NO or the Unknown case.
@implementation NSURLSessionTaskTransactionMetrics

- (NSURLRequest *)request { return nil; }
- (NSURLResponse *)response { return nil; }
- (NSDate *)fetchStartDate { return nil; }
- (NSDate *)domainLookupStartDate { return nil; }
- (NSDate *)domainLookupEndDate { return nil; }
- (NSDate *)connectStartDate { return nil; }
- (NSDate *)secureConnectionStartDate { return nil; }
- (NSDate *)secureConnectionEndDate { return nil; }
- (NSDate *)connectEndDate { return nil; }
- (NSDate *)requestStartDate { return nil; }
- (NSDate *)requestEndDate { return nil; }
- (NSDate *)responseStartDate { return nil; }
- (NSDate *)responseEndDate { return nil; }
- (NSString *)networkProtocolName { return nil; }
- (NSString *)localAddress { return nil; }
- (NSNumber *)localPort { return nil; }
- (NSString *)remoteAddress { return nil; }
- (NSNumber *)remotePort { return nil; }
- (NSNumber *)negotiatedTLSProtocolVersion { return nil; }
- (NSNumber *)negotiatedTLSCipherSuite { return nil; }
- (int64_t)countOfRequestHeaderBytesSent { return 0; }
- (int64_t)countOfRequestBodyBytesSent { return 0; }
- (int64_t)countOfRequestBodyBytesBeforeEncoding { return 0; }
- (int64_t)countOfResponseHeaderBytesReceived { return 0; }
- (int64_t)countOfResponseBodyBytesReceived { return 0; }
- (int64_t)countOfResponseBodyBytesAfterDecoding { return 0; }
- (BOOL)isProxyConnection { return NO; }
- (BOOL)isReusedConnection { return NO; }
- (BOOL)isCellular { return NO; }
- (BOOL)isExpensive { return NO; }
- (BOOL)isConstrained { return NO; }
- (BOOL)isMultipath { return NO; }
- (NSURLSessionTaskMetricsResourceFetchType)resourceFetchType { return NSURLSessionTaskMetricsResourceFetchTypeUnknown; }
- (NSURLSessionTaskMetricsDomainResolutionProtocol)domainResolutionProtocol { return NSURLSessionTaskMetricsDomainResolutionProtocolUnknown; }

@end

@implementation NSURLSessionWebSocketTask
@end

@implementation NSURLSessionDownloadTask
@end

@implementation NSURLSessionUploadTask
@end

@implementation NSURLSessionConfiguration

@dynamic identifier, requestCachePolicy, timeoutIntervalForRequest, timeoutIntervalForResource;
@dynamic networkServiceType, allowsCellularAccess, discretionary, sessionSendsLaunchEvents;
@dynamic connectionProxyDictionary, TLSMinimumSupportedProtocol, TLSMaximumSupportedProtocol;
@dynamic HTTPShouldUsePipelining, HTTPShouldSetCookies, HTTPCookieAcceptPolicy, HTTPAdditionalHeaders;
@dynamic HTTPMaximumConnectionsPerHost, HTTPCookieStorage, URLCredentialStorage, URLCache, protocolClasses;
@dynamic waitsForConnectivity, allowsExpensiveNetworkAccess, allowsConstrainedNetworkAccess, requiresDNSSECValidation;
@dynamic multipathServiceType, shouldUseExtendedBackgroundIdleMode, sharedContainerIdentifier;
@dynamic TLSMinimumSupportedProtocolVersion, TLSMaximumSupportedProtocolVersion;

+ (NSURLSessionConfiguration *)defaultSessionConfiguration
{
    __NSCFURLSessionConfiguration *configuration = [[__NSCFURLSessionConfiguration alloc] init];
    // URLCredentialStorage stays nil: Darling's NSURLCredentialStorage has no shared store.
    [configuration setHTTPCookieStorage:[NSHTTPCookieStorage sharedHTTPCookieStorage]];
    [configuration setURLCache:[NSURLCache sharedURLCache]];
    configuration->_hstsStorage = [[_NSHSTSStorage alloc] initPersistentStoreWithURL:[self _defaultHSTSStorageURL]];
    return [configuration autorelease];
}

// No persistent cookie, credential or cache store. Sessions do not use these
// stores yet, so the in-memory ones Apple provides are left out as well.
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration
{
    __NSCFURLSessionConfiguration *configuration = [[__NSCFURLSessionConfiguration alloc] init];
    configuration->_ephemeral = YES;
    configuration->_hstsStorage = [[_NSHSTSStorage alloc] initInMemoryStore];
    return [configuration autorelease];
}

// ~/Library/HTTPStorages/<bundle identifier or process name>, beside the cookies of the process.
+ (NSURL *)_defaultHSTSStorageURL
{
    NSString *name = [[NSBundle mainBundle] bundleIdentifier];
    if ([name length] == 0)
        name = [[NSProcessInfo processInfo] processName];
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/HTTPStorages"] stringByAppendingPathComponent:name];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

@end

@implementation __NSCFURLSessionConfiguration

@synthesize identifier = _identifier;
@synthesize requestCachePolicy = _requestCachePolicy;
@synthesize timeoutIntervalForRequest = _timeoutIntervalForRequest;
@synthesize timeoutIntervalForResource = _timeoutIntervalForResource;
@synthesize networkServiceType = _networkServiceType;
@synthesize allowsCellularAccess = _allowsCellularAccess;
@synthesize discretionary = _discretionary;
@synthesize sessionSendsLaunchEvents = _sessionSendsLaunchEvents;
@synthesize connectionProxyDictionary = _connectionProxyDictionary;
@synthesize TLSMinimumSupportedProtocol = _TLSMinimumSupportedProtocol;
@synthesize TLSMaximumSupportedProtocol = _TLSMaximumSupportedProtocol;
@synthesize HTTPShouldUsePipelining = _HTTPShouldUsePipelining;
@synthesize HTTPShouldSetCookies = _HTTPShouldSetCookies;
@synthesize HTTPCookieAcceptPolicy = _HTTPCookieAcceptPolicy;
@synthesize HTTPAdditionalHeaders = _HTTPAdditionalHeaders;
@synthesize HTTPMaximumConnectionsPerHost = _HTTPMaximumConnectionsPerHost;
@synthesize HTTPCookieStorage = _HTTPCookieStorage;
@synthesize URLCredentialStorage = _URLCredentialStorage;
@synthesize URLCache = _URLCache;
@synthesize protocolClasses = _protocolClasses;
// Recorded for the app to read back; the libcurl transport does not act on them (it does not
// wait for connectivity, and every network counts as unconstrained and inexpensive).
@synthesize waitsForConnectivity = _waitsForConnectivity;
@synthesize allowsExpensiveNetworkAccess = _allowsExpensiveNetworkAccess;
@synthesize allowsConstrainedNetworkAccess = _allowsConstrainedNetworkAccess;
@synthesize requiresDNSSECValidation = _requiresDNSSECValidation;
@synthesize multipathServiceType = _multipathServiceType;
@synthesize shouldUseExtendedBackgroundIdleMode = _shouldUseExtendedBackgroundIdleMode;
@synthesize sharedContainerIdentifier = _sharedContainerIdentifier;
@synthesize TLSMinimumSupportedProtocolVersion = _TLSMinimumSupportedProtocolVersion;
@synthesize TLSMaximumSupportedProtocolVersion = _TLSMaximumSupportedProtocolVersion;

- (id)init
{
    self = [super init];
    if (self)
    {
        _requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
        _timeoutIntervalForRequest = kDefaultRequestTimeout;
        _timeoutIntervalForResource = kDefaultResourceTimeout;
        _networkServiceType = NSURLNetworkServiceTypeDefault;
        _allowsCellularAccess = YES;
        _HTTPShouldSetCookies = YES;
        _HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain;
        _HTTPMaximumConnectionsPerHost = kDefaultMaximumConnectionsPerHost;
        _allowsExpensiveNetworkAccess = YES;
        _allowsConstrainedNetworkAccess = YES;
        _TLSMinimumSupportedProtocolVersion = 0x0303; // tls_protocol_version_TLSv12
        _TLSMaximumSupportedProtocolVersion = 0x0304; // tls_protocol_version_TLSv13
        // as on macOS 26.7.3 (test: tests/nsurlsessionconfiguration-spi.m)
        _connectionCacheNumPriorityLevels = 4;
        _connectionCacheMinimumFastLanePriority = 1;
    }
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [_connectionProxyDictionary release];
    [_HTTPAdditionalHeaders release];
    [_HTTPCookieStorage release];
    [_URLCredentialStorage release];
    [_URLCache release];
    [_protocolClasses release];
    [_sharedContainerIdentifier release];
    [_hstsStorage release];
    [_sourceApplicationAuditTokenData release];
    [_sourceApplicationBundleIdentifier release];
    [_sourceApplicationSecondaryIdentifier release];
    [_attributedBundleIdentifier release];
    [_suppressedAutoAddedHTTPHeaders release];
    [_socketStreamProperties release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    __NSCFURLSessionConfiguration *copy = [[__NSCFURLSessionConfiguration allocWithZone:zone] init];
    copy->_identifier = [_identifier copy];
    copy->_requestCachePolicy = _requestCachePolicy;
    copy->_timeoutIntervalForRequest = _timeoutIntervalForRequest;
    copy->_timeoutIntervalForResource = _timeoutIntervalForResource;
    copy->_networkServiceType = _networkServiceType;
    copy->_allowsCellularAccess = _allowsCellularAccess;
    copy->_discretionary = _discretionary;
    copy->_sessionSendsLaunchEvents = _sessionSendsLaunchEvents;
    copy->_connectionProxyDictionary = [_connectionProxyDictionary copy];
    copy->_TLSMinimumSupportedProtocol = _TLSMinimumSupportedProtocol;
    copy->_TLSMaximumSupportedProtocol = _TLSMaximumSupportedProtocol;
    copy->_HTTPShouldUsePipelining = _HTTPShouldUsePipelining;
    copy->_HTTPShouldSetCookies = _HTTPShouldSetCookies;
    copy->_HTTPCookieAcceptPolicy = _HTTPCookieAcceptPolicy;
    copy->_HTTPAdditionalHeaders = [_HTTPAdditionalHeaders copy];
    copy->_HTTPMaximumConnectionsPerHost = _HTTPMaximumConnectionsPerHost;
    copy->_HTTPCookieStorage = [_HTTPCookieStorage retain];
    copy->_URLCredentialStorage = [_URLCredentialStorage retain];
    copy->_URLCache = [_URLCache retain];
    copy->_protocolClasses = [_protocolClasses copy];
    copy->_waitsForConnectivity = _waitsForConnectivity;
    copy->_allowsExpensiveNetworkAccess = _allowsExpensiveNetworkAccess;
    copy->_allowsConstrainedNetworkAccess = _allowsConstrainedNetworkAccess;
    copy->_requiresDNSSECValidation = _requiresDNSSECValidation;
    copy->_multipathServiceType = _multipathServiceType;
    copy->_shouldUseExtendedBackgroundIdleMode = _shouldUseExtendedBackgroundIdleMode;
    copy->_sharedContainerIdentifier = [_sharedContainerIdentifier copy];
    copy->_TLSMinimumSupportedProtocolVersion = _TLSMinimumSupportedProtocolVersion;
    copy->_TLSMaximumSupportedProtocolVersion = _TLSMaximumSupportedProtocolVersion;
    copy->_hstsStorage = [_hstsStorage retain];
    copy->_ephemeral = _ephemeral;
    copy->_timingDataOptions = _timingDataOptions;
    copy->_sourceApplicationAuditTokenData = [_sourceApplicationAuditTokenData copy];
    copy->_sourceApplicationBundleIdentifier = [_sourceApplicationBundleIdentifier copy];
    copy->_sourceApplicationSecondaryIdentifier = [_sourceApplicationSecondaryIdentifier copy];
    copy->_attributedBundleIdentifier = [_attributedBundleIdentifier copy];
    copy->_suppressedAutoAddedHTTPHeaders = [_suppressedAutoAddedHTTPHeaders copy];
    copy->_socketStreamProperties = [_socketStreamProperties copy];
    copy->_connectionCacheNumPriorityLevels = _connectionCacheNumPriorityLevels;
    copy->_connectionCacheNumFastLanes = _connectionCacheNumFastLanes;
    copy->_connectionCacheMinimumFastLanePriority = _connectionCacheMinimumFastLanePriority;
    copy->_shouldSkipPreferredClientCertificateLookup = _shouldSkipPreferredClientCertificateLookup;
    copy->_preventsSystemHTTPProxyAuthentication = _preventsSystemHTTPProxyAuthentication;
    copy->_requiresSecureHTTPSProxyConnection = _requiresSecureHTTPSProxyConnection;
    copy->_usesNWLoader = _usesNWLoader;
    copy->_allowsHSTSWithUntrustedRootCertificate = _allowsHSTSWithUntrustedRootCertificate;
    // QUIRK: a copy doesn't keep _skipsStackTraceCapture. Not documented. Evidence:
    // black-box observation on macOS 26.7.3 (tier 2). Test: tests/nsurlsessionconfiguration-spi.m,
    // "quirk: copy drops _skipsStackTraceCapture".
    return copy;
}

#pragma mark - SPI

// The properties below are SPI that WebKit sets on its sessions. Darling's loader does not act
// on them; they are kept, and copied with the configuration, as observed on macOS 26.7.3.

#define SPI_SCALAR(type, name, setter) \
    - (type)name { return name; } \
    - (void)setter:(type)value { name = value; }
#define SPI_COPY(type, name, setter) \
    - (type)name { return name; } \
    - (void)setter:(type)value { if (value == name) return; [name release]; name = [value copy]; }

SPI_SCALAR(int64_t, _timingDataOptions, set_timingDataOptions)
SPI_SCALAR(NSInteger, _connectionCacheNumPriorityLevels, set_connectionCacheNumPriorityLevels)
SPI_SCALAR(NSInteger, _connectionCacheNumFastLanes, set_connectionCacheNumFastLanes)
SPI_SCALAR(NSInteger, _connectionCacheMinimumFastLanePriority, set_connectionCacheMinimumFastLanePriority)
SPI_SCALAR(BOOL, _shouldSkipPreferredClientCertificateLookup, set_shouldSkipPreferredClientCertificateLookup)
SPI_SCALAR(BOOL, _preventsSystemHTTPProxyAuthentication, set_preventsSystemHTTPProxyAuthentication)
SPI_SCALAR(BOOL, _requiresSecureHTTPSProxyConnection, set_requiresSecureHTTPSProxyConnection)
SPI_SCALAR(BOOL, _usesNWLoader, set_usesNWLoader)
SPI_SCALAR(BOOL, _allowsHSTSWithUntrustedRootCertificate, set_allowsHSTSWithUntrustedRootCertificate)
SPI_SCALAR(BOOL, _skipsStackTraceCapture, set_skipsStackTraceCapture)
SPI_COPY(NSString *, _sourceApplicationBundleIdentifier, set_sourceApplicationBundleIdentifier)
SPI_COPY(NSString *, _sourceApplicationSecondaryIdentifier, set_sourceApplicationSecondaryIdentifier)
SPI_COPY(NSString *, _attributedBundleIdentifier, set_attributedBundleIdentifier)
SPI_COPY(NSSet *, _suppressedAutoAddedHTTPHeaders, set_suppressedAutoAddedHTTPHeaders)
SPI_COPY(NSDictionary *, _socketStreamProperties, set_socketStreamProperties)

#undef SPI_SCALAR
#undef SPI_COPY

- (NSData *)_sourceApplicationAuditTokenData
{
    return _sourceApplicationAuditTokenData;
}

// QUIRK: only an audit token's worth of data (32 bytes, the size of audit_token_t) is kept;
// data of any other length clears the property. Not documented. Evidence: black-box observation
// on macOS 26.7.3 (tier 2). Test: tests/nsurlsessionconfiguration-spi.m, "quirk: audit token
// data of another length is dropped".
- (void)set_sourceApplicationAuditTokenData:(NSData *)data
{
    NSData *kept = [data length] == 32 ? [data copy] : nil;
    [_sourceApplicationAuditTokenData release];
    _sourceApplicationAuditTokenData = kept;
}

- (_NSHSTSStorage *)_hstsStorage
{
    return _hstsStorage;
}

// QUIRK: an ephemeral configuration refuses a store kept on disk, raising
// NSInvalidArgumentException. Not documented. Evidence: black-box observation on macOS 26.7.3
// (tier 2), with the reason "Ephemeral sessions must use ephemeral HSTS storage.".
// Test: tests/nshstsstorage.m, "quirk: ephemeral configuration refuses a persistent store".
- (void)set_hstsStorage:(_NSHSTSStorage *)storage
{
    if (_ephemeral && [storage _isPersistent])
        [NSException raise:NSInvalidArgumentException format:@"Ephemeral sessions must use ephemeral HSTS storage."];
    [storage retain];
    [_hstsStorage release];
    _hstsStorage = storage;
}

@end

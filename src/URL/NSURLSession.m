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

const int64_t NSURLSessionTransferSizeUnknown = -1LL;
NSString* const NSURLSessionDownloadTaskResumeData = @"NSURLSessionDownloadTaskResumeData";

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
@dynamic taskDescription, state, error;

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

@end

@implementation NSURLSessionDataTask
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

+ (NSURLSessionConfiguration *)defaultSessionConfiguration
{
    __NSCFURLSessionConfiguration *configuration = [[__NSCFURLSessionConfiguration alloc] init];
    // URLCredentialStorage stays nil: Darling's NSURLCredentialStorage has no shared store.
    [configuration setHTTPCookieStorage:[NSHTTPCookieStorage sharedHTTPCookieStorage]];
    [configuration setURLCache:[NSURLCache sharedURLCache]];
    return [configuration autorelease];
}

// No persistent cookie, credential or cache store. Sessions do not use these
// stores yet, so the in-memory ones Apple provides are left out as well.
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration
{
    return [[[__NSCFURLSessionConfiguration alloc] init] autorelease];
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
    return copy;
}

@end

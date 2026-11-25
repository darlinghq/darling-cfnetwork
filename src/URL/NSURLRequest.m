//
//  NSURLRequest.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/NSURLRequest.h>
#import "NSURLRequestInternal.h"
#import "CFURLRequestInternal.h"
#import <Foundation/NSURL.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSData.h>
#import <Foundation/NSException.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSSet.h>

@implementation NSURLRequestInternal

- (void)dealloc
{
    CFRelease(request);
    [super dealloc];
}

@end


@implementation NSURLRequest

static NSTimeInterval defaultTimeout = 60.0;

+ (NSTimeInterval)defaultTimeoutInterval
{
    return defaultTimeout;
}

+ (void)setDefaultTimeoutInterval:(NSTimeInterval)ti
{
    defaultTimeout = ti;
}

+ (id)requestWithURL:(NSURL *)URL
{
    return [[[self alloc] initWithURL:URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:[NSURLRequest defaultTimeoutInterval]] autorelease];
}

+ (id)requestWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeoutInterval
{
    return [[[self alloc] initWithURL:URL cachePolicy:cachePolicy timeoutInterval:timeoutInterval] autorelease];
}

- (id)init
{
    return [self initWithURL:nil];
}

- (id)initWithURL:(NSURL *)URL
{
    return [self initWithURL:URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:[NSURLRequest defaultTimeoutInterval]];
}

- (id)_initWithCFURLRequest:(CFURLRequestRef)req
{
    self = [super init];
    if (self)
    {
        _internal = [[NSURLRequestInternal alloc] init];
        _internal->request = (CFURLRequestRef)CFRetain(req);
    }
    return self;
}

- (id)initWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeoutInterval
{
    CFURLRequestRef request = CFURLRequestCreate(kCFAllocatorDefault, (CFURLRef)URL, (CFURLRequestCachePolicy)cachePolicy, (CFTimeInterval)timeoutInterval);
    self = [self _initWithCFURLRequest:request];
    CFRelease(request);
    return self;
}

- (void)dealloc
{
    [_internal release];
    [super dealloc];
}

- (NSURL *)URL
{
    return (NSURL *)CFURLRequestGetURL(_internal->request);
}

- (NSURLRequestCachePolicy)cachePolicy
{
    return (NSURLRequestCachePolicy)CFURLRequestGetCachePolicy(_internal->request);
}

- (NSTimeInterval)timeoutInterval
{
    return (NSTimeInterval)CFURLRequestGetTimeout(_internal->request);
}

- (NSURL *)mainDocumentURL
{
    return [(NSURL *)CFURLRequestCopyMainDocumentURL(_internal->request) autorelease];
}

- (NSURLRequestNetworkServiceType)networkServiceType
{
    return (NSURLRequestNetworkServiceType)CFURLRequestGetServiceType(_internal->request);
}

- (BOOL)allowsCellularAccess
{
    return CFURLRequestAllowsCellularAccess(_internal->request);
}

- (BOOL)allowsExpensiveNetworkAccess
{
    return CFURLRequestAllowsExpensiveNetworkAccess(_internal->request);
}

- (BOOL)allowsConstrainedNetworkAccess
{
    return CFURLRequestAllowsConstrainedNetworkAccess(_internal->request);
}

// Keyed coding. The archive holds the URL, cache policy, timeout, main document
// URL, network service type, cellular access, and the HTTP method, header
// fields, body and the cookie and pipelining flags. An HTTP body stream is not
// archived (it cannot be). All decodes are class-checked, so the request can
// be unarchived with secure coding required.
+ (BOOL)supportsSecureCoding
{
    return YES;
}

// The Content-Disposition encodings as NSURLRequest gives and takes them
// (NSStringEncodings) and as the request keeps them (CFStringEncodings). An
// NSStringEncoding without a CFStringEncoding becomes kCFStringEncodingInvalidId.
static CFArrayRef createCFEncodings(NSArray *encodings)
{
    if (encodings == nil)
    {
        return NULL;
    }
    CFMutableArrayRef cfEncodings = CFArrayCreateMutable(kCFAllocatorDefault, [encodings count], &kCFTypeArrayCallBacks);
    for (NSNumber *encoding in encodings)
    {
        CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding([encoding unsignedLongValue]);
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &cfEncoding);
        CFArrayAppendValue(cfEncodings, number);
        CFRelease(number);
    }
    return cfEncodings;
}

static NSArray *nsEncodings(CFArrayRef cfEncodings)
{
    if (cfEncodings == NULL)
    {
        return nil;
    }
    NSMutableArray *encodings = [NSMutableArray arrayWithCapacity:CFArrayGetCount(cfEncodings)];
    for (NSNumber *cfEncoding in (NSArray *)cfEncodings)
    {
        [encodings addObject:@(CFStringConvertEncodingToNSStringEncoding([cfEncoding unsignedIntValue]))];
    }
    return encodings;
}

// The private settings, archived under the keys macOS archives them under.
static const struct {
    _CFURLRequestFlag flag;
    NSString *key;
} archivedFlags[] = {
    { _kCFURLRequestIgnoreHSTS, @"ignoreHSTS" },
    { _kCFURLRequestPreventHSTSStorage, @"preventHSTSStorage" },
    { _kCFURLRequestSchemeWasUpgradedDueToDynamicHSTS, @"schemeWasUpgradedDueToDynamicHSTS" },
    { _kCFURLRequestPrivacyProxyFailClosed, @"privacyProxyFailClosed" },
    { _kCFURLRequestUseEnhancedPrivacyMode, @"useEnhancedPrivacyMode" },
    { _kCFURLRequestPrivacyProxyFailClosedForUnreachableNonMainHosts, @"privacyProxyFailClosedForUnreachableNonMainHosts" },
    { _kCFURLRequestPrivacyProxyFailClosedForUnreachableHosts, @"privacyProxyFailClosedForUnreachableHosts" },
    { _kCFURLRequestNeedsNetworkTrackingPrevention, @"knownTracker" },
    { _kCFURLRequestProhibitPrivacyProxy, @"prohibitPrivacyProxy" },
    { _kCFURLRequestBlockTrackers, @"blockTrackers" },
    { _kCFURLRequestAllowPrivateAccessTokensForThirdParty, @"allowPrivateAccessTokensForThirdParty" },
    { _kCFURLRequestWebSearchContent, @"isWebSearchContent" },
    { _kCFURLRequestPrivacyProxyStrictFailClosed, @"privacyProxyStrictFailClosed" },
    { _kCFURLRequestAllowOnlyPartitionedCookies, @"allowOnlyPartitionedCookies" },
};

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [NSException raise:NSInvalidArchiveOperationException format:@"NSURLRequest can only be encoded by a keyed archiver."];
    }
    if ([self URL] != nil)
    {
        [coder encodeObject:[self URL] forKey:@"NS.url"];
    }
    [coder encodeInteger:[self cachePolicy] forKey:@"NS.cachePolicy"];
    [coder encodeDouble:[self timeoutInterval] forKey:@"NS.timeout"];
    if ([self mainDocumentURL] != nil)
    {
        [coder encodeObject:[self mainDocumentURL] forKey:@"NS.mainDocumentURL"];
    }
    [coder encodeInteger:[self networkServiceType] forKey:@"NS.networkServiceType"];
    [coder encodeBool:[self allowsCellularAccess] forKey:@"NS.allowsCellularAccess"];
    [coder encodeBool:[self allowsExpensiveNetworkAccess] forKey:@"NS.allowsExpensiveNetworkAccess"];
    [coder encodeBool:[self allowsConstrainedNetworkAccess] forKey:@"NS.allowsConstrainedNetworkAccess"];
    if ([self HTTPMethod] != nil)
    {
        [coder encodeObject:[[[self HTTPMethod] copy] autorelease] forKey:@"NS.HTTPMethod"];
    }
    if ([self allHTTPHeaderFields] != nil)
    {
        [coder encodeObject:[[[self allHTTPHeaderFields] copy] autorelease] forKey:@"NS.HTTPHeaders"];
    }
    if ([self HTTPBody] != nil)
    {
        [coder encodeObject:[[[self HTTPBody] copy] autorelease] forKey:@"NS.HTTPBody"];
    }
    [coder encodeBool:[self HTTPShouldHandleCookies] forKey:@"NS.HTTPShouldHandleCookies"];
    [coder encodeBool:[self HTTPShouldUsePipelining] forKey:@"NS.HTTPShouldUsePipelining"];
    for (size_t i = 0; i < sizeof(archivedFlags) / sizeof(archivedFlags[0]); i++)
    {
        [coder encodeBool:_CFURLRequestGetFlag(_internal->request, archivedFlags[i].flag) forKey:archivedFlags[i].key];
    }
    // Values are written as immutable copies, so that the archive holds the classes that
    // -initWithCoder: asks for even when secure decoding is strict about exact classes (as
    // WebKit's is for requests it sends between its processes). Test:
    // tests/nsurlrequest-strict-secure-coding.m.
    NSArray *encodings = [[[self contentDispositionEncodingFallbackArray] copy] autorelease];
    if (encodings != nil)
    {
        [coder encodeObject:encodings forKey:@"contentDispositionEncodingFallbackArray"];
    }
    NSString *boundInterface = (NSString *)_CFURLRequestGetBoundInterfaceIdentifier(_internal->request);
    if (boundInterface != nil)
    {
        [coder encodeObject:boundInterface forKey:@"boundInterfaceIdentifier"];
    }
}

- (id)initWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [self release];
        return nil;
    }

    NSURL *url = [coder decodeObjectOfClass:[NSURL class] forKey:@"NS.url"];
    NSURL *mainDocumentURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"NS.mainDocumentURL"];
    // The mutable classes are accepted too: archives made elsewhere hold them (macOS writes the
    // header fields as an NSMutableDictionary), and a strict unarchiver accepts only the classes
    // named here, not their subclasses.
    NSString *method = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSString class], [NSMutableString class], nil] forKey:@"NS.HTTPMethod"];
    NSData *body = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSData class], [NSMutableData class], nil] forKey:@"NS.HTTPBody"];
    NSDictionary *headers = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSDictionary class], [NSMutableDictionary class], [NSString class], [NSMutableString class], nil] forKey:@"NS.HTTPHeaders"];
    NSArray *encodings = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSMutableArray class], [NSNumber class], nil] forKey:@"contentDispositionEncodingFallbackArray"];
    NSString *boundInterface = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSString class], [NSMutableString class], nil] forKey:@"boundInterfaceIdentifier"];
    // An object that is archived but of an unexpected class decodes to nil.
    if (([coder containsValueForKey:@"NS.url"] && url == nil) ||
        ([coder containsValueForKey:@"NS.mainDocumentURL"] && mainDocumentURL == nil) ||
        ([coder containsValueForKey:@"NS.HTTPMethod"] && method == nil) ||
        ([coder containsValueForKey:@"NS.HTTPBody"] && body == nil) ||
        ([coder containsValueForKey:@"NS.HTTPHeaders"] && headers == nil) ||
        ([coder containsValueForKey:@"contentDispositionEncodingFallbackArray"] && encodings == nil) ||
        ([coder containsValueForKey:@"boundInterfaceIdentifier"] && boundInterface == nil))
    {
        [self release];
        return nil;
    }
    for (id key in headers)
    {
        if (![key isKindOfClass:[NSString class]] || ![[headers objectForKey:key] isKindOfClass:[NSString class]])
        {
            [self release];
            return nil;
        }
    }

    NSURLRequestCachePolicy policy = NSURLRequestUseProtocolCachePolicy;
    if ([coder containsValueForKey:@"NS.cachePolicy"])
    {
        policy = (NSURLRequestCachePolicy)[coder decodeIntegerForKey:@"NS.cachePolicy"];
    }
    NSTimeInterval timeout = [NSURLRequest defaultTimeoutInterval];
    if ([coder containsValueForKey:@"NS.timeout"])
    {
        timeout = [coder decodeDoubleForKey:@"NS.timeout"];
    }

    self = [self initWithURL:url cachePolicy:policy timeoutInterval:timeout];
    if (self == nil)
    {
        return nil;
    }

    // The initializer above returns an immutable or mutable request according to the class
    // being decoded; fill in the rest through a mutable working copy.
    CFMutableURLRequestRef request = CFURLRequestCreateMutableCopy(kCFAllocatorDefault, _internal->request);
    CFURLRequestSetMainDocumentURL(request, (CFURLRef)mainDocumentURL);
    if ([coder containsValueForKey:@"NS.networkServiceType"])
    {
        CFURLRequestSetNetworkServiceType(request, (CFURLRequestNetworkServiceType)[coder decodeIntegerForKey:@"NS.networkServiceType"]);
    }
    if ([coder containsValueForKey:@"NS.allowsCellularAccess"])
    {
        CFURLRequestSetAllowsCellularAccess(request, [coder decodeBoolForKey:@"NS.allowsCellularAccess"]);
    }
    if ([coder containsValueForKey:@"NS.allowsExpensiveNetworkAccess"])
    {
        CFURLRequestSetAllowsExpensiveNetworkAccess(request, [coder decodeBoolForKey:@"NS.allowsExpensiveNetworkAccess"]);
    }
    if ([coder containsValueForKey:@"NS.allowsConstrainedNetworkAccess"])
    {
        CFURLRequestSetAllowsConstrainedNetworkAccess(request, [coder decodeBoolForKey:@"NS.allowsConstrainedNetworkAccess"]);
    }
    if (method != nil)
    {
        CFURLRequestSetHTTPMethod(request, (CFStringRef)method);
    }
    if (headers != nil)
    {
        CFURLRequestSetHTTPFields(request, (CFArrayRef)[headers allKeys], (CFArrayRef)[headers allValues]);
    }
    if (body != nil)
    {
        CFURLRequestSetHTTPBody(request, (CFDataRef)body);
    }
    if ([coder containsValueForKey:@"NS.HTTPShouldHandleCookies"])
    {
        CFURLRequestHandleCookies(request, [coder decodeBoolForKey:@"NS.HTTPShouldHandleCookies"]);
    }
    if ([coder containsValueForKey:@"NS.HTTPShouldUsePipelining"])
    {
        CFURLRequestUseHTTPPipelining(request, [coder decodeBoolForKey:@"NS.HTTPShouldUsePipelining"]);
    }
    for (size_t i = 0; i < sizeof(archivedFlags) / sizeof(archivedFlags[0]); i++)
    {
        _CFURLRequestSetFlag(request, archivedFlags[i].flag, [coder decodeBoolForKey:archivedFlags[i].key]);
    }
    for (id encoding in encodings)
    {
        if (![encoding isKindOfClass:[NSNumber class]])
        {
            CFRelease(request);
            [self release];
            return nil;
        }
    }
    CFArrayRef cfEncodings = createCFEncodings(encodings);
    _CFURLRequestSetContentDispositionEncodingFallbackArray(request, cfEncodings);
    if (cfEncodings != NULL)
    {
        CFRelease(cfEncodings);
    }
    _CFURLRequestSetBoundInterfaceIdentifier(request, (CFStringRef)boundInterface);
    CFRelease(_internal->request);
    if ([self isKindOfClass:[NSMutableURLRequest class]])
    {
        _internal->request = request;
    }
    else
    {
        _internal->request = CFURLRequestCreateCopy(kCFAllocatorDefault, request);
        CFRelease(request);
    }
    return self;
}

- (CFURLRequestRef)_CFURLRequest
{
    return _internal->request;
}

// Mutable and immutable requests with the same settings are equal.
- (BOOL)isEqual:(id)object
{
    if (object == self)
    {
        return YES;
    }
    if (![object isKindOfClass:[NSURLRequest class]])
    {
        return NO;
    }
    return CFEqual(_internal->request, [(NSURLRequest *)object _CFURLRequest]);
}

- (NSUInteger)hash
{
    return CFHash(_internal->request);
}

- (id)copyWithZone:(NSZone *)zone
{
    CFURLRequestRef req = CFURLRequestCreateCopy(kCFAllocatorDefault, _internal->request);
    NSURLRequest *copy = [[NSURLRequest alloc] _initWithCFURLRequest:req];
    CFRelease(req);
    return copy;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    return [[NSMutableURLRequest alloc] _initWithCFURLRequest:_internal->request];
}

- (NSString *)debugDescription
{
    CFStringRef reqDesc = CFURLRequestCopyDebugDescription(_internal->request);
    NSString *desc = [NSString stringWithFormat:@"<NSURLRequest %p %@>", self, reqDesc];
    CFRelease(reqDesc);
    return desc;
}

@end


@implementation NSURLRequest (NSHTTPURLRequest)

- (NSString *)HTTPMethod
{
    return [(NSString *)CFURLRequestCopyHTTPMethod([self _CFURLRequest]) autorelease];
}

- (NSDictionary *)allHTTPHeaderFields
{
    CFURLRequestRef req = [self _CFURLRequest];
    return [(NSDictionary *)CFURLRequestCopyAllHTTPFields(req) autorelease];
}

- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    return [(NSString *)CFURLRequestCopyValueForHTTPField([self _CFURLRequest], (CFStringRef)field) autorelease];
}

- (NSData *)HTTPBody
{
    return (NSData *)CFURLRequestGetHTTPBody([self _CFURLRequest]);
}

- (NSInputStream *)HTTPBodyStream
{
    return (NSInputStream *)CFURLRequestGetHTTPBodyStream([self _CFURLRequest]);
}

- (BOOL)HTTPShouldHandleCookies
{
    return CFURLRequestShouldHandleCookes([self _CFURLRequest]);
}

- (BOOL)HTTPShouldUsePipelining
{
    return CFURLRequestShouldUseHTTPPipelining([self _CFURLRequest]);
}

@end

@implementation NSMutableURLRequest

// The getters are inherited from NSURLRequest; the setters are written out below.
@dynamic allowsCellularAccess, allowsExpensiveNetworkAccess, allowsConstrainedNetworkAccess;

- (id)_initWithCFURLRequest:(CFURLRequestRef)req
{
    CFMutableURLRequestRef request = CFURLRequestCreateMutableCopy(kCFAllocatorDefault, req);
    self = [super _initWithCFURLRequest:request];
    CFRelease(request);
    return self;
}

- (void)setURL:(NSURL *)URL
{
    CFURLRequestSetURL((CFMutableURLRequestRef)[self _CFURLRequest], (CFURLRef)URL);
}

- (void)setCachePolicy:(NSURLRequestCachePolicy)policy
{
    CFURLRequestSetCachePolicy((CFMutableURLRequestRef)[self _CFURLRequest], (CFURLRequestCachePolicy)policy);
}

- (void)setTimeoutInterval:(NSTimeInterval)seconds
{
    CFURLRequestSetTimeout((CFMutableURLRequestRef)[self _CFURLRequest], (CFTimeInterval)seconds);
}

- (void)setMainDocumentURL:(NSURL *)URL
{
    CFURLRequestSetMainDocumentURL((CFMutableURLRequestRef)[self _CFURLRequest], (CFURLRef)URL);
}

- (void)setNetworkServiceType:(NSURLRequestNetworkServiceType)networkServiceType
{
    CFURLRequestSetNetworkServiceType((CFMutableURLRequestRef)[self _CFURLRequest], (CFURLRequestNetworkServiceType)networkServiceType);
}

- (void)setAllowsCellularAccess:(BOOL)allow
{
    CFURLRequestSetAllowsCellularAccess((CFMutableURLRequestRef)[self _CFURLRequest], allow);
}

- (void)setAllowsExpensiveNetworkAccess:(BOOL)allow
{
    CFURLRequestSetAllowsExpensiveNetworkAccess((CFMutableURLRequestRef)[self _CFURLRequest], allow);
}

- (void)setAllowsConstrainedNetworkAccess:(BOOL)allow
{
    CFURLRequestSetAllowsConstrainedNetworkAccess((CFMutableURLRequestRef)[self _CFURLRequest], allow);
}

@end

@implementation NSMutableURLRequest (NSMutableHTTPURLRequest)

- (void)setHTTPMethod:(NSString *)method
{
    CFURLRequestSetHTTPMethod((CFMutableURLRequestRef)[self _CFURLRequest], (CFStringRef)method);
}

- (void)setAllHTTPHeaderFields:(NSDictionary *)headerFields
{
    CFURLRequestSetHTTPFields((CFMutableURLRequestRef)[self _CFURLRequest], (CFArrayRef)[headerFields allKeys], (CFArrayRef)[headerFields allValues]);
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    CFMutableURLRequestRef req = (CFMutableURLRequestRef)[self _CFURLRequest];
    CFIndex idx = CFURLRequestFirstFieldIndex(req, (CFStringRef)field, 0);
    if (value == nil)
    {
        if (idx != kCFNotFound)
        {
            CFURLRequestRemoveHTTPField(req, idx);
        }
    }
    else if (idx != kCFNotFound)
    {
        CFURLRequestReplaceHTTPField(req, idx, (CFStringRef)value);
    }
    else
    {
        CFURLRequestAddValueForHTTPField(req, (CFStringRef)field, (CFStringRef)value);
    }
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    CFURLRequestAddValueForHTTPField((CFMutableURLRequestRef)[self _CFURLRequest], (CFStringRef)field, (CFStringRef)value);
}

- (void)setHTTPBody:(NSData *)data
{
    CFURLRequestSetHTTPBody((CFMutableURLRequestRef)[self _CFURLRequest], (CFDataRef)data);
}

- (void)setHTTPBodyStream:(NSInputStream *)inputStream
{
    CFURLRequestSetHTTPBodyStream((CFMutableURLRequestRef)[self _CFURLRequest], (CFReadStreamRef)inputStream);
}

- (void)setHTTPShouldHandleCookies:(BOOL)should
{
    CFURLRequestHandleCookies((CFMutableURLRequestRef)[self _CFURLRequest], should);
}

- (void)setHTTPShouldUsePipelining:(BOOL)shouldUsePipelining
{
    CFURLRequestUseHTTPPipelining((CFMutableURLRequestRef)[self _CFURLRequest], shouldUsePipelining);
}

@end

// Private settings that WebKit and other system frameworks use. The getters are
// NSURLRequest's and the setters NSMutableURLRequest's, as on macOS.
#define REQUEST_FLAG_GETTER(getter, flag) \
    - (BOOL)getter \
    { \
        return _CFURLRequestGetFlag(_internal->request, flag); \
    }
#define REQUEST_FLAG_SETTER(setter, flag) \
    - (void)setter(BOOL)value \
    { \
        _CFURLRequestSetFlag((CFMutableURLRequestRef)_internal->request, flag, value); \
    }

@implementation NSURLRequest (NSURLRequestPrivate)

// The same storage as NSURLProtocol's properties of the request; a request
// that isn't mutable takes them too.
- (id)_propertyForKey:(NSString *)key
{
    return [(id)_CFURLRequestCopyProtocolPropertyForKey(_internal->request, (CFStringRef)key) autorelease];
}

- (void)_setProperty:(id)value forKey:(NSString *)key
{
    _CFURLRequestSetProtocolProperty(_internal->request, (CFStringRef)key, (CFTypeRef)value);
}

- (void)_removePropertyForKey:(NSString *)key
{
    _CFURLRequestSetProtocolProperty(_internal->request, (CFStringRef)key, NULL);
}

- (NSArray *)contentDispositionEncodingFallbackArray
{
    return nsEncodings(_CFURLRequestGetContentDispositionEncodingFallbackArray(_internal->request));
}

REQUEST_FLAG_GETTER(_ignoreHSTS, _kCFURLRequestIgnoreHSTS)
REQUEST_FLAG_GETTER(_preventHSTSStorage, _kCFURLRequestPreventHSTSStorage)
REQUEST_FLAG_GETTER(_schemeWasUpgradedDueToDynamicHSTS, _kCFURLRequestSchemeWasUpgradedDueToDynamicHSTS)
REQUEST_FLAG_GETTER(_privacyProxyFailClosed, _kCFURLRequestPrivacyProxyFailClosed)
REQUEST_FLAG_GETTER(_useEnhancedPrivacyMode, _kCFURLRequestUseEnhancedPrivacyMode)
REQUEST_FLAG_GETTER(_privacyProxyFailClosedForUnreachableNonMainHosts, _kCFURLRequestPrivacyProxyFailClosedForUnreachableNonMainHosts)
REQUEST_FLAG_GETTER(_privacyProxyFailClosedForUnreachableHosts, _kCFURLRequestPrivacyProxyFailClosedForUnreachableHosts)
REQUEST_FLAG_GETTER(_needsNetworkTrackingPrevention, _kCFURLRequestNeedsNetworkTrackingPrevention)
REQUEST_FLAG_GETTER(_prohibitPrivacyProxy, _kCFURLRequestProhibitPrivacyProxy)
REQUEST_FLAG_GETTER(_blockTrackers, _kCFURLRequestBlockTrackers)
REQUEST_FLAG_GETTER(_allowPrivateAccessTokensForThirdParty, _kCFURLRequestAllowPrivateAccessTokensForThirdParty)
REQUEST_FLAG_GETTER(_isWebSearchContent, _kCFURLRequestWebSearchContent)
REQUEST_FLAG_GETTER(_privacyProxyStrictFailClosed, _kCFURLRequestPrivacyProxyStrictFailClosed)
REQUEST_FLAG_GETTER(_allowOnlyPartitionedCookies, _kCFURLRequestAllowOnlyPartitionedCookies)

- (NSString *)boundInterfaceIdentifier
{
    return (NSString *)_CFURLRequestGetBoundInterfaceIdentifier(_internal->request);
}

@end

@implementation NSMutableURLRequest (NSMutableURLRequestPrivate)

- (void)setContentDispositionEncodingFallbackArray:(NSArray *)encodings
{
    CFArrayRef cfEncodings = createCFEncodings(encodings);
    _CFURLRequestSetContentDispositionEncodingFallbackArray((CFMutableURLRequestRef)_internal->request, cfEncodings);
    if (cfEncodings != NULL)
    {
        CFRelease(cfEncodings);
    }
}

REQUEST_FLAG_SETTER(_setIgnoreHSTS:, _kCFURLRequestIgnoreHSTS)
REQUEST_FLAG_SETTER(_setPreventHSTSStorage:, _kCFURLRequestPreventHSTSStorage)
REQUEST_FLAG_SETTER(_setSchemeWasUpgradedDueToDynamicHSTS:, _kCFURLRequestSchemeWasUpgradedDueToDynamicHSTS)
REQUEST_FLAG_SETTER(_setPrivacyProxyFailClosed:, _kCFURLRequestPrivacyProxyFailClosed)
REQUEST_FLAG_SETTER(_setUseEnhancedPrivacyMode:, _kCFURLRequestUseEnhancedPrivacyMode)
REQUEST_FLAG_SETTER(_setPrivacyProxyFailClosedForUnreachableNonMainHosts:, _kCFURLRequestPrivacyProxyFailClosedForUnreachableNonMainHosts)
REQUEST_FLAG_SETTER(_setPrivacyProxyFailClosedForUnreachableHosts:, _kCFURLRequestPrivacyProxyFailClosedForUnreachableHosts)
REQUEST_FLAG_SETTER(_setNeedsNetworkTrackingPrevention:, _kCFURLRequestNeedsNetworkTrackingPrevention)
REQUEST_FLAG_SETTER(_setProhibitPrivacyProxy:, _kCFURLRequestProhibitPrivacyProxy)
REQUEST_FLAG_SETTER(_setBlockTrackers:, _kCFURLRequestBlockTrackers)
REQUEST_FLAG_SETTER(_setAllowPrivateAccessTokensForThirdParty:, _kCFURLRequestAllowPrivateAccessTokensForThirdParty)
REQUEST_FLAG_SETTER(_setWebSearchContent:, _kCFURLRequestWebSearchContent)
REQUEST_FLAG_SETTER(_setPrivacyProxyStrictFailClosed:, _kCFURLRequestPrivacyProxyStrictFailClosed)
REQUEST_FLAG_SETTER(_setAllowOnlyPartitionedCookies:, _kCFURLRequestAllowOnlyPartitionedCookies)

- (void)setBoundInterfaceIdentifier:(NSString *)identifier
{
    _CFURLRequestSetBoundInterfaceIdentifier((CFMutableURLRequestRef)_internal->request, (CFStringRef)identifier);
}

@end

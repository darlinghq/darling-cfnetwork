//
//  NSURLCache.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import "NSURLCacheInternal.h"
#import "NSURLResponseInternal.h"
#import "NSURLRequestInternal.h"
#import <Foundation/NSException.h>
#import <Foundation/NSData.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSPathUtilities.h>

static NSUInteger NSURLCacheDefaultMemoryCapacity = 512000;
static NSUInteger NSURLCacheDefaultDiskCapacity = 10000000;

// The public header says only <NSCoding, NSCopying>, and NSKeyedArchiver refuses to archive under secure coding an
// object whose class does not conform to NSSecureCoding.
@interface NSCachedURLResponse () <NSSecureCoding>
@end

@implementation NSCachedURLResponse

- (id)initWithResponse:(NSURLResponse*)response data:(NSData*)data
{
    return [self initWithResponse:response data:data userInfo:nil storagePolicy:NSURLCacheStorageAllowed];
}

- (id)initWithResponse:(NSURLResponse*)response data:(NSData*)data userInfo:(NSDictionary*)userInfo storagePolicy:(NSURLCacheStoragePolicy)storagePolicy
{
    CFCachedURLResponseRef cachedResponse = CFCachedURLResponseCreate(
        kCFAllocatorDefault,
        response._CFURLResponse,
        (CFDataRef)data,
        (CFDictionaryRef)userInfo,
        (CFCachedURLStoragePolicy)storagePolicy);
    self = [self _initWithCFCachedURLResponse:cachedResponse];
    if (self)
    {
        _response = [response retain];
    }
    if (cachedResponse)
    {
        CFRelease(cachedResponse);
    }
    return self;
}

- (id)_initWithCFCachedURLResponse:(CFCachedURLResponseRef)cachedResponse
{
    NSAssert([self class] == [NSCachedURLResponse class], @"Subclassing of NSCachedURLResponse is not supported");

    if (!cachedResponse)
    {
        [self release];
        return nil;
    }
    self = [super init];
    if (self)
    {
        _cachedResponseRef = (CFCachedURLResponseRef)CFRetain(cachedResponse);
    }
    return self;
}

- (id)copyWithZone:(NSZone*)zone
{
    return [self retain];
}

- (void)dealloc
{
    [_response release];
    if (_cachedResponseRef != NULL)
    {
        CFRelease(_cachedResponseRef);
    }
    [super dealloc];
}

// Keyed coding of the response, the data, the user info and the storage policy: the properties the documentation
// lists for NSCachedURLResponse. Decodes are class-checked, so a cached response can be unarchived with secure
// coding required.
// GUESS: the key names are this implementation's own (the documentation gives no archive layout), as in
// NSURLResponse; only archives written by this implementation are promised to decode. macOS 26.7.3 and 10.14.4 write
// a different layout (private numbered and _CFCachedURLResponse... keys around the private archive layout of the
// response, which this implementation does not write either), so archives are not exchanged with macOS in either
// direction; a user info holding arrays or dates is also accepted here under secure coding, where macOS refuses it.
// GUESS: under secure coding the user info may hold only property list classes (dictionaries, arrays, strings,
// numbers, data and dates); the documentation does not say which classes a user info may carry.
+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)initWithCoder:(NSCoder*)coder
{
    if (![coder allowsKeyedCoding])
    {
        [self release];
        return nil;
    }
    NSURLResponse* response = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSURLResponse class], [NSHTTPURLResponse class], nil] forKey:@"NS.response"];
    NSData* data = [coder decodeObjectOfClass:[NSData class] forKey:@"NS.data"];
    NSSet* userInfoClasses = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class], [NSData class], [NSDate class], nil];
    NSDictionary* userInfo = [coder decodeObjectOfClasses:userInfoClasses forKey:@"NS.userInfo"];
    NSInteger policy = [coder decodeIntegerForKey:@"NS.storagePolicy"];
    // The response and the data are needed to make a cached response. Decoding without secure coding does not check
    // the class of a stored object, so the classes are checked here: a response, data or user info of another class
    // gives nil, and so does a storage policy outside the documented three.
    if (![response isKindOfClass:[NSURLResponse class]] || ![data isKindOfClass:[NSData class]] ||
        ([coder containsValueForKey:@"NS.userInfo"] && ![userInfo isKindOfClass:[NSDictionary class]]) ||
        policy < (NSInteger)NSURLCacheStorageAllowed || policy > (NSInteger)NSURLCacheStorageNotAllowed)
    {
        [self release];
        return nil;
    }
    return [self initWithResponse:response data:data userInfo:userInfo storagePolicy:(NSURLCacheStoragePolicy)policy];
}

- (void)encodeWithCoder:(NSCoder*)coder
{
    if (![coder allowsKeyedCoding])
    {
        [NSException raise:NSInvalidArchiveOperationException format:@"NSCachedURLResponse can only be encoded by a keyed archiver."];
    }
    [coder encodeObject:[self response] forKey:@"NS.response"];
    [coder encodeObject:[self data] forKey:@"NS.data"];
    if ([self userInfo] != nil)
    {
        [coder encodeObject:[self userInfo] forKey:@"NS.userInfo"];
    }
    [coder encodeInteger:(NSInteger)[self storagePolicy] forKey:@"NS.storagePolicy"];
}

- (CFCachedURLResponseRef)_CFCachedURLResponse
{
    return _cachedResponseRef;
}

- (NSURLResponse*)response
{
    if (!_response)
    {
        CFURLResponseRef response = CFCachedURLResponseGetResponse(_cachedResponseRef);
        if (CFURLResponseIsHTTPResponse(response)) {
            _response = [[NSHTTPURLResponse _responseWithCFURLResponse:response] retain];
        } else {
            _response = [[NSURLResponse _responseWithCFURLResponse:response] retain];
        }
    }
    return _response;
}

- (NSData*)data
{
    CFDataRef data = NULL;
    CFCachedURLResponseLoadData(_cachedResponseRef, &data);
    NSAssert(data, @"Cached URL response data is not available");
    return [(NSData*)data autorelease];
}

- (NSDictionary*)userInfo
{
    return (NSDictionary*)CFCachedURLResponseGetUserInfo(_cachedResponseRef);
}

- (NSURLCacheStoragePolicy)storagePolicy
{
    return (NSURLCacheStoragePolicy)CFCachedURLResponseGetStoragePolicy(_cachedResponseRef);
}

@end

@implementation NSURLCache

static NSURLCache* sharedURLCache = nil;
static Boolean sharedURLCacheSet = false;

+ (void)setSharedURLCache:(NSURLCache*)cache
{
    @synchronized(self)
    {
        if (sharedURLCache != cache)
        {
            [sharedURLCache release];
            sharedURLCache = [cache retain];
            CFURLCacheSetShared(sharedURLCache._CFURLCache);
            sharedURLCacheSet = true;
        }
    }
}

+ (NSURLCache*)sharedURLCache
{
    NSURLCache* cache;
    @synchronized(self)
    {
        cache = [sharedURLCache retain];

        // Hack to default initialize NSURLCache
        if (!cache && !sharedURLCacheSet) {
            cache = [[NSURLCache alloc] init];
            [self setSharedURLCache:cache];
        }
    }
    return [cache autorelease];
}

- (id)init
{
    return [self initWithMemoryCapacity:NSURLCacheDefaultMemoryCapacity diskCapacity:NSURLCacheDefaultDiskCapacity diskPath:nil];
}

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString*)path
{
    // Calculate full path for the cache.
    NSString* cachePath;
    {
        const char* cacheDir = getenv("CACHEDIR");
        if (!cacheDir)
        {
            // Memory caching only
            cachePath = nil;
        }
        else
        {
            NSString* basePath = [[NSString stringWithUTF8String:cacheDir] stringByAppendingPathComponent:@"NSURLCache"];
            if (path)
            {
                // Discard everything but the last component from the 'path' argument.
                cachePath = [basePath stringByAppendingPathComponent:[path lastPathComponent]];
            }
            else
            {
                // Nil 'path' means "default cache location"
                cachePath = basePath;
            }
        }
    }
    return [self _initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity fullCachePath:cachePath];
}

// The directory is where the cache is kept, used as given; without one the default location of
// -initWithMemoryCapacity:diskCapacity:diskPath: applies.
- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity directoryURL:(NSURL *)directoryURL
{
    if (directoryURL == nil)
    {
        return [self initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:nil];
    }
    return [self _initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity fullCachePath:[directoryURL path]];
}

- (id)_initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity fullCachePath:(NSString *)cachePath
{
    CFURLCacheRef cache = CFURLCacheCreate(kCFAllocatorDefault, memoryCapacity, diskCapacity, (CFStringRef)cachePath);
    if (!cache) {
        [self release];
        return nil;
    }

    self = [self _initWithExistingSharedCFURLCache:cache];
    if (self) {
        _CFURLCacheSetNSCache(cache, self);
    }
    CFRelease(cache);
    return self;
}

- (id)_initWithExistingSharedCFURLCache:(CFURLCacheRef)cache
{
    self = [super init];
    if (self)
    {
        _cacheRef = (CFURLCacheRef)CFRetain(cache);
    }
    return self;
}

- (void)dealloc
{
    _CFURLCacheSetNSCache(_cacheRef, NULL);
    CFRelease(_cacheRef);
    [super dealloc];
}

- (CFURLCacheRef)_CFURLCache
{
    return _cacheRef;
}

- (NSUInteger)memoryCapacity
{
    return _CFURLCacheMemoryCapacity(_cacheRef);
}

- (NSUInteger)_cf_memoryCapacity
{
    return [self memoryCapacity];
}

- (void)setMemoryCapacity:(NSUInteger)capacity
{
    _CFURLCacheSetMemoryCapacity(_cacheRef, capacity);
}

- (void)_cf_setMemoryCapacity:(NSUInteger)capacity
{
    [self setMemoryCapacity:capacity];
}

- (NSUInteger)diskCapacity
{
    return _CFURLCacheDiskCapacity(_cacheRef);
}

- (NSUInteger)_cf_diskCapacity
{
    return [self diskCapacity];
}

- (void)setDiskCapacity:(NSUInteger)capacity
{
    _CFURLCacheSetDiskCapacity(_cacheRef, capacity);
}

- (void)_cf_setDiskCapacity:(NSUInteger)capacity
{
    [self setDiskCapacity:capacity];
}

- (NSUInteger)currentMemoryUsage
{
    return _CFURLCacheCurrentMemoryUsage(_cacheRef);
}

- (NSUInteger)_cf_currentMemoryUsage
{
    return [self currentMemoryUsage];
}

- (NSUInteger)currentDiskUsage
{
    return _CFURLCacheCurrentDiskUsage(_cacheRef);
}

- (NSUInteger)_cf_currentDiskUsage
{
    return [self currentDiskUsage];
}

- (NSCachedURLResponse*)cachedResponseForRequest:(NSURLRequest*)request
{
    CFCachedURLResponseRef cachedResponse = _CFURLCacheCopyResponseForRequest(_cacheRef, request._CFURLRequest);
    if (!cachedResponse)
    {
        return nil;
    }
    NSCachedURLResponse* cached = [[[NSCachedURLResponse alloc] _initWithCFCachedURLResponse:cachedResponse] autorelease];
    CFRelease(cachedResponse);
    return cached;
}

- (CFCachedURLResponseRef)_cf_cachedResponseForRequest:(CFURLRequestRef)cfRequest
{
    NSURLRequest *request = [[[NSURLRequest alloc] _initWithCFURLRequest:cfRequest] autorelease];
    return [self cachedResponseForRequest:request]._CFCachedURLResponse;
}

- (void)storeCachedResponse:(NSCachedURLResponse*)cachedResponse forRequest:(NSURLRequest*)request
{
    _CFURLCacheAddCachedResponseForRequest(_cacheRef, cachedResponse._CFCachedURLResponse, request._CFURLRequest);
}

- (Boolean)_cf_storeCachedResponse:(CFCachedURLResponseRef)cfCachedResponse forCFRequest:(CFURLRequestRef)cfRequest
{
    NSCachedURLResponse *cachedResponse = [[[NSCachedURLResponse alloc] _initWithCFCachedURLResponse:cfCachedResponse] autorelease];
    NSURLRequest *request = [[[NSURLRequest alloc] _initWithCFURLRequest:cfRequest] autorelease];
    [self storeCachedResponse:cachedResponse forRequest:request];
    return true;
}

- (void)removeCachedResponseForRequest:(NSURLRequest*)request
{
    _CFURLCacheRemoveCachedResponseForRequest(_cacheRef, request._CFURLRequest);
}

- (void)_cf_removeCachedResponseForRequest:(CFURLRequestRef)cfRequest
{
    NSURLRequest *request = [[[NSURLRequest alloc] _initWithCFURLRequest:cfRequest] autorelease];
    [self removeCachedResponseForRequest:request];
}

- (void)removeAllCachedResponses
{
    _CFURLCacheRemoveAllCachedResponses(_cacheRef);
}

- (void)_cf_removeAllCachedResponses
{
    [self removeAllCachedResponses];
}

@end

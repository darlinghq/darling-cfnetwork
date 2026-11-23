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
#import <Foundation/NSNull.h>
#import <Foundation/NSPropertyList.h>
#import <Foundation/NSURL.h>
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

// Keyed coding of the response, the data, the user info and the storage policy, in the layout that macOS writes (found
// by reading keyed archives written by macOS 26.7.3 and 10.14.4, x86_64 and i386, as property lists; the layout is the
// same for plain and secure archivers). Two unkeyed integers (12 and the storage policy), then under the keys
// _NSURLResponseType (the response, in the layout of NSURLResponse), _CFCachedURLResponseReceiverDataArray (an array
// with the data), _NSDataType (the data), _NSDictionaryType (the user info as an ordinary dictionary, or nil) and
// _CFCachedURLResponseUserInfo, the user info as a binary property list, present only when the user info is a valid
// property list. The reader takes the user info from the property list, so a user info that is not one (it holds a
// URL, null or a non-string key) comes back as nil; macOS 10.14.4 wraps the property list data in an NSMutableData
// and 26.7.3 does not, both archives are read by both systems and the wrapper of 10.14.4 is written. Decodes are
// class-checked, so a cached response can be unarchived with secure coding required.
// Test: tests/nscachedurlresponse-macos-archive.m
static const int CachedURLResponseArchiveFormat = 12;

// The classes that a secure unarchiver allows in the dictionary stored under _NSDictionaryType.
static NSSet *cachedUserInfoSecureClasses(void)
{
    return [NSSet setWithObjects:[NSDictionary class], [NSString class], [NSNumber class], [NSData class], nil];
}

static NSSet *cachedUserInfoWideClasses(void)
{
    return [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class], [NSData class],
        [NSDate class], [NSNull class], [NSURL class], nil];
}

static BOOL cachedUserInfoHasOnlySecureClasses(id object)
{
    if ([object isKindOfClass:[NSDictionary class]])
    {
        for (id key in object)
        {
            if (!cachedUserInfoHasOnlySecureClasses(key) || !cachedUserInfoHasOnlySecureClasses([object objectForKey:key]))
            {
                return NO;
            }
        }
        return YES;
    }
    return [object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] || [object isKindOfClass:[NSData class]];
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)initWithCoder:(NSCoder*)coder
{
    int format = 0;
    int policy = -1;
    if (![coder allowsKeyedCoding])
    {
        [self release];
        return nil;
    }
    // The unkeyed values ($0, $1) cannot be tested with containsValueForKey:, so an archive without them reads as
    // zeros or raises, and either way is not accepted.
    @try
    {
        [coder decodeValueOfObjCType:@encode(int) at:&format size:sizeof(format)];
        [coder decodeValueOfObjCType:@encode(int) at:&policy size:sizeof(policy)];
    }
    @catch (NSException* exception)
    {
        [self release];
        return nil;
    }
    NSURLResponse* response = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSURLResponse class], [NSHTTPURLResponse class], nil] forKey:@"_NSURLResponseType"];
    NSData* data = [coder decodeObjectOfClass:[NSData class] forKey:@"_NSDataType"];
    if (data == nil)
    {
        NSArray* dataArray = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSData class], nil] forKey:@"_CFCachedURLResponseReceiverDataArray"];
        data = [dataArray isKindOfClass:[NSArray class]] && [dataArray count] > 0 ? [dataArray objectAtIndex:0] : nil;
    }
    NSData* userInfoData = [coder decodeObjectOfClass:[NSData class] forKey:@"_CFCachedURLResponseUserInfo"];
    // Decoding without secure coding does not check the class of a stored object, so the classes are checked here: a
    // response or data of another class gives nil, and so does a storage policy outside the documented three.
    if (format != CachedURLResponseArchiveFormat || ![response isKindOfClass:[NSURLResponse class]] || ![data isKindOfClass:[NSData class]] ||
        policy < (int)NSURLCacheStorageAllowed || policy > (int)NSURLCacheStorageNotAllowed)
    {
        [self release];
        return nil;
    }
    NSDictionary* userInfo = nil;
    if ([userInfoData isKindOfClass:[NSData class]])
    {
        id list = [NSPropertyListSerialization propertyListWithData:userInfoData options:NSPropertyListImmutable format:NULL error:NULL];
        userInfo = [list isKindOfClass:[NSDictionary class]] ? list : nil;
    }
    // QUIRK: a secure unarchiver does not refuse a cached response whose archived user info dictionary holds a class
    // other than dictionary, string, number or data (an array, a date, null, a URL); it returns an object that has the
    // response but no data and no user info (the storage policy of that object is not set on macOS; it is
    // NSURLCacheStorageNotAllowed here, so the object is not stored). Evidence: black-box reading of archives on macOS
    // 26.7.3 and 10.14.4 (x86_64 and i386), tier 2, the same results from both; not documented.
    // Test: test_quirk_secure_user_info_with_other_classes in tests/nscachedurlresponse-macos-archive.m
    if ([coder requiresSecureCoding] && [coder containsValueForKey:@"_NSDictionaryType"])
    {
        BOOL refused = NO;
        id archivedUserInfo = [coder decodeObjectOfClasses:cachedUserInfoWideClasses() forKey:@"_NSDictionaryType"];
        if (archivedUserInfo != nil)
        {
            // The unarchiver may check the classes of the nested objects itself or only those of the top level, so
            // the tree is checked here as well.
            refused = !cachedUserInfoHasOnlySecureClasses(archivedUserInfo);
            if (!refused)
            {
                @try
                {
                    refused = [coder decodeObjectOfClasses:cachedUserInfoSecureClasses() forKey:@"_NSDictionaryType"] == nil;
                }
                @catch (NSException* exception)
                {
                    refused = YES;
                }
            }
        }
        if (refused)
        {
            return [self initWithResponse:response data:[NSData data] userInfo:nil storagePolicy:NSURLCacheStorageNotAllowed];
        }
    }
    return [self initWithResponse:response data:data userInfo:userInfo storagePolicy:(NSURLCacheStoragePolicy)policy];
}

- (void)encodeWithCoder:(NSCoder*)coder
{
    if (![coder allowsKeyedCoding])
    {
        [NSException raise:NSInvalidArchiveOperationException format:@"NSCachedURLResponse can only be encoded by a keyed archiver."];
    }
    int format = CachedURLResponseArchiveFormat;
    int policy = (int)[self storagePolicy];
    NSData* data = [self data];
    [coder encodeValueOfObjCType:@encode(int) at:&format];
    [coder encodeValueOfObjCType:@encode(int) at:&policy];
    [coder encodeObject:[self response] forKey:@"_NSURLResponseType"];
    [coder encodeObject:[NSArray arrayWithObject:data] forKey:@"_CFCachedURLResponseReceiverDataArray"];
    [coder encodeObject:data forKey:@"_NSDataType"];
    [coder encodeObject:[self userInfo] forKey:@"_NSDictionaryType"];
    if ([self userInfo] != nil)
    {
        NSData* list = [NSPropertyListSerialization dataWithPropertyList:[self userInfo] format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        if (list != nil)
        {
            [coder encodeObject:[NSMutableData dataWithData:list] forKey:@"_CFCachedURLResponseUserInfo"];
        }
    }
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
    if (CFCachedURLResponseLoadData(_cachedResponseRef, &data) && data == NULL)
    {
        // The data is empty (CFCachedURLResponseLoadData has no data object for an entry of no bytes).
        return [NSData data];
    }
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

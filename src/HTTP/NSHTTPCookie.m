//
//  NSHTTPCookie.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/NSHTTPCookie.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSValue.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSRegularExpression.h>
#import <CFNetwork/CFHTTPCookie.h>
#import "NSHTTPCookie+private.h"

NSString * const NSHTTPCookieName = @"Name";
NSString * const NSHTTPCookieValue = @"Value";
NSString * const NSHTTPCookieOriginURL = @"OriginURL";
NSString * const NSHTTPCookieVersion = @"Version";
NSString * const NSHTTPCookieDomain = @"Domain";
NSString * const NSHTTPCookiePath = @"Path";
NSString * const NSHTTPCookieSecure = @"Secure";
NSString * const NSHTTPCookieExpires = @"Expires";
NSString * const NSHTTPCookieComment = @"Comment";
NSString * const NSHTTPCookieCommentURL = @"CommentURL";
NSString * const NSHTTPCookieDiscard = @"Discard";
NSString * const NSHTTPCookieMaximumAge = @"Max-Age";
NSString * const NSHTTPCookiePort = @"Port";
// Apple's reference does not give these strings: the key is the cookie
// attribute's name and the values its lower-case values (RFC 6265bis), as on
// macOS 26.7.3 (test: tests/nshttpcookie-same-site.m).
NSHTTPCookiePropertyKey const NSHTTPCookieSameSitePolicy = @"SameSite";
NSHTTPCookieStringPolicy const NSHTTPCookieSameSiteLax = @"lax";
NSHTTPCookieStringPolicy const NSHTTPCookieSameSiteStrict = @"strict";


@implementation NSHTTPCookie

+ (id)cookieWithProperties:(NSDictionary *)properties
{
    return [[[self alloc] initWithProperties:properties] autorelease];
}

+ (NSDictionary *)requestHeaderFieldsWithCookies:(NSArray *)cookies
{
    NSMutableArray *cfCookies = [NSMutableArray arrayWithCapacity:[cookies count]];
    
    for (NSHTTPCookie *cookie in cookies) {
        CFHTTPCookieRef cfCookie = [cookie privateCookie];
        [cfCookies addObject:(id)cfCookie];
    }
    
    NSDictionary *result = [(NSDictionary *)CFHTTPCookieCopyRequestHeaderFields((CFArrayRef)cfCookies) autorelease];
    return result;
}

+ (NSArray *)cookiesWithResponseHeaderFields:(NSDictionary *)headerFields forURL:(NSURL *)URL
{
    NSArray * cfCookies = (NSArray *)CFHTTPCookieCreateWithResponseHeaderFields((CFDictionaryRef)headerFields, (CFURLRef)URL);
    
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:[cfCookies count]];
    
    
    for (id cfCookie in cfCookies) {
        NSHTTPCookie *cookie = [[NSHTTPCookie alloc] initWithCookie:(CFHTTPCookieRef)cfCookie];
        [result addObject:cookie];
        [cookie release];
    }
    
    [cfCookies release];
    return [NSArray arrayWithArray:result];
    
}

- (id)initWithCookie:(CFHTTPCookieRef)cookie
{
    self = [super init];
    if (self)
    {
        _cookiePrivate = (CFHTTPCookieRef)CFRetain(cookie);
    }
    return self;
}

- (id)initWithProperties:(NSDictionary *)properties
{
    self = [super init];
    if (self)
    {
        _cookiePrivate = CFHTTPCookieCreateWithProperties((CFDictionaryRef)properties);
    }
    if (_cookiePrivate == NULL) {
        [self release];
        self = nil;
    }
    return self;
}

- (void)dealloc
{
    if (_cookiePrivate != NULL) {
        CFRelease(_cookiePrivate);
    }
    [super dealloc];
}

-(CFHTTPCookieRef)privateCookie {
    return _cookiePrivate;
}

// The CFHTTPCookie the object wraps, under the names WebKit uses.
- (CFHTTPCookieRef)_CFHTTPCookie
{
    return [self privateCookie];
}

- (CFHTTPCookieRef)_GetInternalCFHTTPCookie
{
    return [self privateCookie];
}

// The partition the cookie is kept in (the CHIPS "Partitioned" attribute);
// Darling keeps every cookie outside any partition.
- (NSString *)_storagePartition
{
    return nil;
}

- (NSDictionary *)properties
{
    return [(NSDictionary *)CFHTTPCookieCopyProperties(_cookiePrivate) autorelease];
}

- (NSUInteger)version
{
    return [(NSNumber*)CFHTTPCookieGetVersion(_cookiePrivate) unsignedIntegerValue];
}

- (NSString *)name
{
    return (NSString *)CFHTTPCookieGetName(_cookiePrivate);
}

- (NSString *)value
{
    return (NSString *)CFHTTPCookieGetValue(_cookiePrivate);
}

- (NSDate *)expiresDate
{
    return (NSDate *)CFHTTPCookieGetExpirationDate(_cookiePrivate);
}

- (BOOL)isSessionOnly
{
    return CFHTTPCookieIsSessionOnly(_cookiePrivate);
}

- (NSString *)domain
{
    return (NSString *)CFHTTPCookieGetDomain(_cookiePrivate);
}

- (NSString *)path
{
    return (NSString *)CFHTTPCookieGetPath(_cookiePrivate);
}

- (BOOL)isSecure
{
    return CFHTTPCookieIsSecure(_cookiePrivate);
}

- (BOOL)isHTTPOnly
{
    return CFHTTPCookieIsHTTPOnly(_cookiePrivate);
}

- (NSHTTPCookieStringPolicy)sameSitePolicy
{
    id policy = [[self properties] objectForKey:NSHTTPCookieSameSitePolicy];
    if (![policy isKindOfClass:[NSString class]])
        return nil;
    if ([policy caseInsensitiveCompare:NSHTTPCookieSameSiteLax] == NSOrderedSame)
        return NSHTTPCookieSameSiteLax;
    if ([policy caseInsensitiveCompare:NSHTTPCookieSameSiteStrict] == NSOrderedSame)
        return NSHTTPCookieSameSiteStrict;
    return nil;
}

- (NSString *)comment
{
    return (NSString *)CFHTTPCookieGetComment(_cookiePrivate);
}

- (NSURL *)commentURL
{
    return (NSURL *)CFHTTPCookieGetCommentURL(_cookiePrivate);
}

- (NSArray *)portList
{
    return (NSArray *)CFHTTPCookieGetPortArray(_cookiePrivate);
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:[NSHTTPCookie class]]) {
        return NO;
    }
    return [[self properties] isEqual:[object properties]];
}

- (NSUInteger)hash {
    return [[self name] hash] ^ [[self domain] hash] ^ [[self path] hash];
}


@end

@implementation NSHTTPCookie (NSHTTPCookiePrivate)

// The cookie one Set-Cookie header value sets for a URL, parsed as
// +cookiesWithResponseHeaderFields:forURL: parses it; nil when it sets none. Darling
// keeps every cookie outside any partition (see -_storagePartition), so the partition
// isn't used.
+ (NSHTTPCookie *)_cookieForSetCookieString:(NSString *)setCookieString forURL:(NSURL *)URL partition:(NSString *)partition
{
    if (setCookieString == nil)
    {
        return nil;
    }
    NSArray *cookies = [self cookiesWithResponseHeaderFields:[NSDictionary dictionaryWithObject:setCookieString forKey:@"Set-Cookie"] forURL:URL];
    return [cookies count] != 0 ? [cookies objectAtIndex:0] : nil;
}

// Cookies as NSHTTPCookie objects, from an array of CFHTTPCookie or NSHTTPCookie objects.
+ (NSArray *)_cf2nsCookies:(CFArrayRef)cfCookies
{
    NSMutableArray *result = [NSMutableArray array];
    for (id cookie in (NSArray *)cfCookies)
    {
        if ([cookie isKindOfClass:[NSHTTPCookie class]])
        {
            [result addObject:cookie];
        }
        else if (CFGetTypeID((CFTypeRef)cookie) == CFHTTPCookieGetTypeID())
        {
            NSHTTPCookie *wrapped = [[NSHTTPCookie alloc] initWithCookie:(CFHTTPCookieRef)cookie];
            [result addObject:wrapped];
            [wrapped release];
        }
    }
    return result;
}

// The cookies as a new array of CFHTTPCookie objects, for the CFHTTPCookie and
// CFHTTPCookieStorage functions; NULL for nil.
+ (CFArrayRef)_ns2cfCookies:(NSArray *)nsCookies
{
    if (nsCookies == nil)
    {
        return NULL;
    }
    CFMutableArrayRef result = CFArrayCreateMutable(kCFAllocatorDefault, [nsCookies count], &kCFTypeArrayCallBacks);
    for (NSHTTPCookie *cookie in nsCookies)
    {
        CFArrayAppendValue(result, [cookie _CFHTTPCookie]);
    }
    return result;
}

@end

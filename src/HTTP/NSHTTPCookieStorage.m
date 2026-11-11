//
//  NSHTTPCookieStorage.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/NSHTTPCookieStorage.h>
#import <dispatch/dispatch.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSHTTPCookie.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSSortDescriptor.h>
#import <Foundation/NSNotification.h>
#import <CFNetwork/CFHTTPCookieStorage.h>
#import "NSHTTPCookie+private.h"

// The storage lives in CFNetwork's CFHTTPCookieStorage; this class is a wrapper over it, so a
// cookie set through either layer is seen by the other.

NSString * const NSHTTPCookieManagerAcceptPolicyChangedNotification = @"NSHTTPCookieManagerAcceptPolicyChangedNotification";
NSString * const NSHTTPCookieManagerCookiesChangedNotification = @"NSHTTPCookieManagerCookiesChangedNotification";

static NSArray *wrapCookies(CFArrayRef cfCookies)
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:CFArrayGetCount(cfCookies)];
    for (id cfCookie in (NSArray *)cfCookies)
    {
        NSHTTPCookie *cookie = [[NSHTTPCookie alloc] initWithCookie:(CFHTTPCookieRef)cfCookie];
        [result addObject:cookie];
        [cookie release];
    }
    return result;
}

static void storageChanged(CFHTTPCookieStorageRef storage, void *info)
{
    NSHTTPCookieStorage *object = (NSHTTPCookieStorage *)info;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSHTTPCookieManagerCookiesChangedNotification object:object];
}

@implementation NSHTTPCookieStorage

+ (NSHTTPCookieStorage *)sharedHTTPCookieStorage
{
    static NSHTTPCookieStorage *sharedStorage = nil;
    static dispatch_once_t once = 0L;
    dispatch_once(&once, ^{
        sharedStorage = [[NSHTTPCookieStorage alloc] initWithStorage:CFHTTPCookieStorageGetDefault()];
        CFHTTPCookieStorageSetChangeCallBack(CFHTTPCookieStorageGetDefault(), storageChanged, sharedStorage);
    });
    return sharedStorage;
}

- (id)initWithStorage:(CFHTTPCookieStorageRef) storage
{
    self = [super init];

    if (self)
    {
        _storage = (CFHTTPCookieStorageRef)CFRetain(storage);
    }

    return self;
}

- (void)dealloc
{
    if (_storage != NULL)
    {
        CFRelease(_storage);
    }
    [super dealloc];
}

- (NSArray *)cookies
{
    CFArrayRef cfCookies = CFHTTPCookieStorageCopyCookies(_storage);
    NSArray *result = wrapCookies(cfCookies);
    CFRelease(cfCookies);
    return result;
}

- (void)setCookie:(NSHTTPCookie *)cookie
{
    CFHTTPCookieStorageSetCookie(_storage, [cookie privateCookie]);
}

- (void)deleteCookie:(NSHTTPCookie *)cookie
{
    CFHTTPCookieStorageDeleteCookie(_storage, [cookie privateCookie]);
}

- (NSArray *)cookiesForURL:(NSURL *)URL
{
    if (URL == nil)
    {
        return nil;
    }
    CFArrayRef cfCookies = CFHTTPCookieStorageCopyCookiesForURL(_storage, (CFURLRef)URL);
    NSArray *result = wrapCookies(cfCookies);
    CFRelease(cfCookies);
    return result;
}

- (void)setCookies:(NSArray *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL
{
    if (URL == nil)
    {
        return;
    }
    CFMutableArrayRef cfCookies = CFArrayCreateMutable(kCFAllocatorDefault, [cookies count], &kCFTypeArrayCallBacks);
    for (NSHTTPCookie *cookie in cookies)
    {
        CFArrayAppendValue(cfCookies, [cookie privateCookie]);
    }
    CFHTTPCookieStorageSetCookiesForURL(_storage, cfCookies, (CFURLRef)URL, (CFURLRef)mainDocumentURL);
    CFRelease(cfCookies);
}

- (void)removeCookiesSinceDate:(NSDate *)date
{
    CFHTTPCookieStorageDeleteCookiesSinceDate(_storage, (CFDateRef)date);
}

- (NSHTTPCookieAcceptPolicy)cookieAcceptPolicy
{
    return (NSHTTPCookieAcceptPolicy)CFHTTPCookieStorageGetAcceptPolicy(_storage);
}

- (void)setCookieAcceptPolicy:(NSHTTPCookieAcceptPolicy)cookieAcceptPolicy
{
    CFHTTPCookieStorageSetAcceptPolicy(_storage, (CFHTTPCookieStorageAcceptPolicy)cookieAcceptPolicy);
}

- (NSArray *)sortedCookiesUsingDescriptors:(NSArray *)sortOrder
{
    NSArray *cookies = [self cookies];
    if ([sortOrder count] == 0)
    {
        return cookies;
    }
    return [cookies sortedArrayUsingDescriptors:sortOrder];
}

@end

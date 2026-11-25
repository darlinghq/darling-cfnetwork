//
//  NSHTTPCookieStorage.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/NSHTTPCookieStorage.h>
#import <dispatch/dispatch.h>
#include <pthread.h>
#include <stdlib.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSObjCRuntime.h>
#import <Foundation/NSHTTPCookie.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSSortDescriptor.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSURLRequest.h>
#import <Foundation/NSURLSession.h>
#import <CFNetwork/CFHTTPCookieStorage.h>
#import "NSHTTPCookie+private.h"
#include "../Cookies/CFHTTPCookieInternal.h"

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

// The CFNetwork cookies of NSHTTPCookie objects, autoreleased.
static NSArray *cookiesAsCF(NSArray *cookies)
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:[cookies count]];
    for (NSHTTPCookie *cookie in cookies)
    {
        [result addObject:(id)[cookie privateCookie]];
    }
    return result;
}

// The storage objects that post NSHTTPCookieManagerCookiesChangedNotification,
// by the CFNetwork storage they wrap. A CFNetwork storage has a single change
// callback, and several storage objects may wrap it (each posts for itself),
// so the callback is set once and looks its storage objects up here. Neither
// the storages nor the objects are retained: an object leaves the table when
// it is deallocated. The lock is recursive because an observer may change the
// cookies again.
static pthread_mutex_t notifyingLock;
static CFMutableDictionaryRef notifyingObjects; // CFHTTPCookieStorageRef -> CFMutableArrayRef

static void initNotifyingTable(void)
{
    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&notifyingLock, &attributes);
    pthread_mutexattr_destroy(&attributes);
    notifyingObjects = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
}

static void lockNotifyingTable(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, initNotifyingTable);
    pthread_mutex_lock(&notifyingLock);
}

static void storageChanged(CFHTTPCookieStorageRef storage, void *info)
{
    lockNotifyingTable();
    CFArrayRef objects = CFDictionaryGetValue(notifyingObjects, storage);
    CFArrayRef snapshot = objects != NULL ? CFArrayCreateCopy(kCFAllocatorDefault, objects) : NULL;
    if (snapshot != NULL)
    {
        for (CFIndex i = 0; i < CFArrayGetCount(snapshot); i++)
        {
            id object = (id)CFArrayGetValueAtIndex(snapshot, i);
            [[NSNotificationCenter defaultCenter] postNotificationName:NSHTTPCookieManagerCookiesChangedNotification object:object];
        }
        CFRelease(snapshot);
    }
    pthread_mutex_unlock(&notifyingLock);
}

static void addNotifyingObject(CFHTTPCookieStorageRef storage, NSHTTPCookieStorage *object)
{
    lockNotifyingTable();
    CFMutableArrayRef objects = (CFMutableArrayRef)CFDictionaryGetValue(notifyingObjects, storage);
    if (objects == NULL)
    {
        objects = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
        CFDictionarySetValue(notifyingObjects, storage, objects);
        CFRelease(objects);
        CFHTTPCookieStorageSetChangeCallBack(storage, storageChanged, NULL);
    }
    if (!CFArrayContainsValue(objects, CFRangeMake(0, CFArrayGetCount(objects)), object))
        CFArrayAppendValue(objects, object);
    pthread_mutex_unlock(&notifyingLock);
}

static void removeNotifyingObject(CFHTTPCookieStorageRef storage, NSHTTPCookieStorage *object)
{
    lockNotifyingTable();
    CFMutableArrayRef objects = (CFMutableArrayRef)CFDictionaryGetValue(notifyingObjects, storage);
    if (objects != NULL)
    {
        CFIndex index = CFArrayGetFirstIndexOfValue(objects, CFRangeMake(0, CFArrayGetCount(objects)), object);
        if (index != kCFNotFound)
            CFArrayRemoveValueAtIndex(objects, index);
        if (CFArrayGetCount(objects) == 0)
        {
            CFHTTPCookieStorageSetChangeCallBack(storage, NULL, NULL);
            CFDictionaryRemoveValue(notifyingObjects, storage);
        }
    }
    pthread_mutex_unlock(&notifyingLock);
}

// The state of an NSHTTPCookieStorage, which (as in Apple's public header)
// keeps only a pointer to it.
@interface NSHTTPCookieStorageInternal : NSObject
{
@public
    CFHTTPCookieStorageRef _storage;
    // the storage object the notifications are posted for, if any (not retained: it owns us)
    NSHTTPCookieStorage *_notificationContext;
    // SPI flag, kept per storage object; see -_overrideSessionCookieAcceptPolicy
    BOOL _overrideSessionCookieAcceptPolicy;
}
- (instancetype)initWithStorage:(CFHTTPCookieStorageRef)storage;
- (void)registerForPostingNotificationsWithContext:(NSHTTPCookieStorage *)context;
@end

@implementation NSHTTPCookieStorageInternal

- (instancetype)initWithStorage:(CFHTTPCookieStorageRef)storage
{
    self = [super init];
    if (self)
    {
        _storage = (CFHTTPCookieStorageRef)CFRetain(storage);
    }
    return self;
}

// From now on a change to the cookies posts
// NSHTTPCookieManagerCookiesChangedNotification with the context as its object.
- (void)registerForPostingNotificationsWithContext:(NSHTTPCookieStorage *)context
{
    if (context == _notificationContext)
        return;
    if (_notificationContext != nil)
        removeNotifyingObject(_storage, _notificationContext);
    _notificationContext = context;
    if (context != nil)
        addNotifyingObject(_storage, context);
}

- (void)dealloc
{
    if (_notificationContext != nil)
        removeNotifyingObject(_storage, _notificationContext);
    CFRelease(_storage);
    [super dealloc];
}

@end

#define STORAGE (_internal->_storage)

@implementation NSHTTPCookieStorage

// The shared storage, made the first time it is asked for unless a process has set one before.
static NSHTTPCookieStorage *sharedStorage = nil;
static pthread_mutex_t sharedStorageLock = PTHREAD_MUTEX_INITIALIZER;

+ (NSHTTPCookieStorage *)sharedHTTPCookieStorage
{
    pthread_mutex_lock(&sharedStorageLock);
    if (sharedStorage == nil) {
        sharedStorage = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:CFHTTPCookieStorageGetDefault()];
        [sharedStorage->_internal registerForPostingNotificationsWithContext:sharedStorage];
    }
    NSHTTPCookieStorage *storage = sharedStorage;
    pthread_mutex_unlock(&sharedStorageLock);
    return storage;
}

// SPI. Makes the storage the shared one, for every thread. It can only be done once, before
// anything has asked for the shared storage; the process aborts otherwise, as on macOS 26.7.3
// (test: tests/nshttpcookiestorage-set-shared.m). Nil is ignored.
+ (void)_setSharedHTTPCookieStorage:(NSHTTPCookieStorage *)storage
{
    if (storage == nil) {
        return;
    }
    pthread_mutex_lock(&sharedStorageLock);
    if (sharedStorage != nil) {
        pthread_mutex_unlock(&sharedStorageLock);
        NSLog(@"Attempted to set the shared cookie storage after it was already in use");
        abort();
    }
    sharedStorage = [storage retain];
    [sharedStorage->_internal registerForPostingNotificationsWithContext:sharedStorage];
    pthread_mutex_unlock(&sharedStorageLock);
}

// A storage object over a CFNetwork cookie storage; unlike the shared one, it
// posts no notifications unless asked to.
- (id)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage
{
    self = [super init];
    if (self)
    {
        if (storage == NULL)
        {
            [self release];
            return nil;
        }
        _internal = [[NSHTTPCookieStorageInternal alloc] initWithStorage:storage];
    }
    return self;
}

// A storage object made with -init (as a subclass's may be) has no CFNetwork storage: it keeps no
// cookies, gives nil for them, and its accept policy stays the default one (macOS 26.7.3; test:
// tests/nshttpcookiestorage-init.m).

- (CFHTTPCookieStorageRef)_cookieStorage
{
    return STORAGE;
}

// SPI. Whether sessions using this storage object take its accept policy over their
// configuration's. A flag of the object, not of the CFNetwork storage it wraps: NO until set,
// and setting it doesn't change cookieAcceptPolicy (macOS 26.7.3). Darling's sessions don't
// apply their configuration's accept policy, so the flag doesn't change what they do.
- (BOOL)_overrideSessionCookieAcceptPolicy
{
    if (_internal == nil)
    {
        return NO;
    }
    return _internal->_overrideSessionCookieAcceptPolicy;
}

- (void)set_overrideSessionCookieAcceptPolicy:(BOOL)override
{
    if (_internal == nil)
    {
        return;
    }
    _internal->_overrideSessionCookieAcceptPolicy = override;
}

- (void)dealloc
{
    [_internal release];
    [super dealloc];
}

- (NSArray *)cookies
{
    if (_internal == nil)
    {
        return nil;
    }
    CFArrayRef cfCookies = CFHTTPCookieStorageCopyCookies(STORAGE);
    NSArray *result = wrapCookies(cfCookies);
    CFRelease(cfCookies);
    return result;
}

- (void)setCookie:(NSHTTPCookie *)cookie
{
    if (_internal == nil)
    {
        return;
    }
    CFHTTPCookieStorageSetCookie(STORAGE, [cookie privateCookie]);
}

- (void)deleteCookie:(NSHTTPCookie *)cookie
{
    if (_internal == nil)
    {
        return;
    }
    CFHTTPCookieStorageDeleteCookie(STORAGE, [cookie privateCookie]);
}

- (NSArray *)cookiesForURL:(NSURL *)URL
{
    if (_internal == nil)
    {
        return nil;
    }
    if (URL == nil)
    {
        return nil;
    }
    CFArrayRef cfCookies = CFHTTPCookieStorageCopyCookiesForURL(STORAGE, (CFURLRef)URL);
    NSArray *result = wrapCookies(cfCookies);
    CFRelease(cfCookies);
    return result;
}

- (void)setCookies:(NSArray *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL
{
    if (_internal == nil)
    {
        return;
    }
    if (URL == nil)
    {
        return;
    }
    CFHTTPCookieStorageSetCookiesForURL(STORAGE, (CFArrayRef)cookiesAsCF(cookies), (CFURLRef)URL, (CFURLRef)mainDocumentURL);
}

- (void)removeCookiesSinceDate:(NSDate *)date
{
    if (_internal == nil)
    {
        return;
    }
    CFHTTPCookieStorageDeleteCookiesSinceDate(STORAGE, (CFDateRef)date);
}

#pragma mark - Tasks

// NSURLSession stores and looks up the cookies of its tasks through these two methods, not through
// -setCookies:forURL:mainDocumentURL: and -cookiesForURL: (macOS 26.7.3; test:
// tests/nsurlsession-cookies.m), so they are what a subclass overrides to see them.

- (void)storeCookies:(NSArray *)cookies forTask:(NSURLSessionTask *)task
{
    if (_internal == nil)
    {
        return;
    }
    NSURLRequest *request = [task currentRequest];
    if ([request URL] == nil || cookies == nil)
    {
        return;
    }
    CFHTTPCookieStorageSetCookiesForURL(STORAGE, (CFArrayRef)cookiesAsCF(cookies), (CFURLRef)[request URL], (CFURLRef)[request mainDocumentURL]);
}

- (void)getCookiesForTask:(NSURLSessionTask *)task completionHandler:(void (^)(NSArray *))completionHandler
{
    NSURL *url = [[task currentRequest] URL];
    NSArray *cookies = nil;
    if (url != nil && _internal != nil)
    {
        CFArrayRef cfCookies = CFHTTPCookieStorageCopyCookiesForURL(STORAGE, (CFURLRef)url);
        cookies = wrapCookies(cfCookies);
        CFRelease(cfCookies);
    }
    if (completionHandler)
    {
        completionHandler(cookies);
    }
}

#pragma mark - Partitions and policy properties

// Darling's cookies belong to no partition (see -[NSHTTPCookie
// _storagePartition]), so a partition selects only the cookies outside any:
// all of them. The policy properties (the SameSite context of a load) are not
// applied: the storage does not enforce SameSite.

- (void)_getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition completionHandler:(void (^)(NSArray *))completionHandler
{
    [self _getCookiesForURL:url mainDocumentURL:mainDocumentURL partition:partition policyProperties:nil completionHandler:completionHandler];
}

// The handler is called before the method returns.
- (void)_getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition policyProperties:(NSDictionary *)properties completionHandler:(void (^)(NSArray *))completionHandler
{
    NSArray *cookies = url ? [self cookiesForURL:url] : @[];
    if (completionHandler)
    {
        completionHandler(cookies ?: @[]);
    }
}

// The handler is called before the method returns.
- (void)_getCookiesForPartition:(NSString *)partition completionHandler:(void (^)(NSArray *))completionHandler
{
    if (completionHandler)
    {
        completionHandler([self cookies] ?: @[]);
    }
}

- (void)_setCookies:(NSArray *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL policyProperties:(NSDictionary *)properties
{
    [self setCookies:cookies forURL:URL mainDocumentURL:mainDocumentURL];
}

// The storage writes its cookies out as they change, so they are saved
// already; the handler is called before the method returns.
- (void)_saveCookies:(dispatch_block_t)completionHandler
{
    if (completionHandler)
    {
        completionHandler();
    }
}

#pragma mark - Change handlers

// SPI. The handlers and the subscribed hosts belong to the CFNetwork storage, not to this object:
// another storage object over the same storage replaces them and gets the same changes (macOS
// 26.7.3). What they are called for is described in CFHTTPCookieStorage.c.

- (void)_setCookiesChangedHandler:(void (^)(NSArray *addedCookies, NSString *domainForChangedCookie))handler onQueue:(dispatch_queue_t)queue
{
    if (_internal == nil)
    {
        return;
    }
    _CFHTTPCookieStorageCookiesAddedHandler storageHandler = NULL;
    if (handler != nil)
    {
        storageHandler = ^(CFArrayRef cookies, CFStringRef host) {
            @autoreleasepool
            {
                handler(wrapCookies(cookies), (NSString *)host);
            }
        };
    }
    _CFHTTPCookieStorageSetCookiesAddedHandler(STORAGE, storageHandler, queue);
}

- (void)_setCookiesRemovedHandler:(void (^)(NSArray *removedCookies, NSString *domainForRemovedCookies, bool removeAllCookies))handler onQueue:(dispatch_queue_t)queue
{
    if (_internal == nil)
    {
        return;
    }
    _CFHTTPCookieStorageCookiesRemovedHandler storageHandler = NULL;
    if (handler != nil)
    {
        storageHandler = ^(CFArrayRef cookies, CFStringRef host, Boolean removeAll) {
            @autoreleasepool
            {
                handler(cookies != NULL ? wrapCookies(cookies) : nil, (NSString *)host, removeAll);
            }
        };
    }
    _CFHTTPCookieStorageSetCookiesRemovedHandler(STORAGE, storageHandler, queue);
}

// The hosts the handlers are called for; nil or an empty set stops them.
- (void)_setSubscribedDomainsForCookieChanges:(NSSet *)domainList
{
    if (_internal == nil)
    {
        return;
    }
    _CFHTTPCookieStorageSetSubscribedHosts(STORAGE, (CFSetRef)domainList);
}

- (NSHTTPCookieAcceptPolicy)cookieAcceptPolicy
{
    if (_internal == nil)
    {
        return NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain;
    }
    return (NSHTTPCookieAcceptPolicy)CFHTTPCookieStorageGetAcceptPolicy(STORAGE);
}

- (void)setCookieAcceptPolicy:(NSHTTPCookieAcceptPolicy)cookieAcceptPolicy
{
    if (_internal == nil)
    {
        return;
    }
    CFHTTPCookieStorageSetAcceptPolicy(STORAGE, (CFHTTPCookieStorageAcceptPolicy)cookieAcceptPolicy);
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

#pragma mark - Storages of their own and cookies by domain

// SPI: a storage of its own that starts empty, separate from the shared one and
// from every other (macOS 26.7.3). Darling keeps it in memory: a storage that
// isn't private isn't written to disk either, and the identifier names nothing.
// Test: nshttpcookiestorage-private-spi.m.
- (id)_initWithIdentifier:(NSString *)identifier private:(bool)isPrivate
{
    CFHTTPCookieStorageRef storage = __CFHTTPCookieStorageCreateInMemory(kCFAllocatorDefault);
    self = [self _initWithCFHTTPCookieStorage:storage];
    if (storage != NULL)
    {
        CFRelease(storage);
    }
    return self;
}

// SPI: the cookies that a request to the host would carry by their domain:
// host-only cookies of that host and domain cookies of it or of a domain above
// it, whatever their path. A leading dot in the host and its case don't matter
// (macOS 26.7.3). Test: nshttpcookiestorage-private-spi.m.
- (NSArray *)_getCookiesForDomain:(NSString *)domain
{
    NSString *host = [domain lowercaseString];
    while ([host hasPrefix:@"."])
    {
        host = [host substringFromIndex:1];
    }
    NSMutableArray *result = [NSMutableArray array];
    if ([host length] == 0)
    {
        return result;
    }
    for (NSHTTPCookie *cookie in [self cookies])
    {
        if (_CFHTTPCookieDomainMatchesHost((CFStringRef)[cookie domain], (CFStringRef)host))
        {
            [result addObject:cookie];
        }
    }
    return result;
}

@end

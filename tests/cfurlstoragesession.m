// CFNetwork's storage sessions and the shared storage, as WebKit's
// NetworkStorageSession uses them:
// - a session has a cookie storage of its own, apart from the default one,
//   and the same one each time it is asked;
// - its cache is there until the session's cache is disabled, then NULL;
// - _CFHTTPCookieStorageGetDefault is CFHTTPCookieStorageGetDefault, and the
//   ...CookieAcceptPolicy accessors are the ...AcceptPolicy ones;
// - CFHTTPCookieStorageDeleteAllCookies empties a storage;
// - CFURLCacheCopySharedURLCache gives the cache +[NSURLCache sharedURLCache]
//   wraps, whichever is asked first;
// - a request keeps its session when copied (the session is the request's,
//   like its other properties);
// - no host is a known HSTS host (the loader keeps no HSTS state);
// - _CFURLCacheCopyCacheDirectory gives the directory of a cache kept on
//   disk, and NULL for one kept in memory only;
// - a proxy's challenge (407) with the proxy's URL recorded on the response
//   still gives a valid authentication.
// The functions are private, so they are declared here.
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#include <stdio.h>

typedef struct __CFHTTPCookieStorage *CFHTTPCookieStorageRef;
typedef struct __CFHTTPCookie *CFHTTPCookieRef;
typedef struct _CFURLCache *CFURLCacheRef;
typedef const struct __CFURLStorageSession *CFURLStorageSessionRef;
typedef const struct _CFURLRequest *CFURLRequestRef;
typedef struct _CFURLRequest *CFMutableURLRequestRef;

extern const CFStringRef _kCFURLStorageSessionIsPrivate;
extern CFURLStorageSessionRef _CFURLStorageSessionCreate(CFAllocatorRef, CFStringRef, CFDictionaryRef);
extern CFHTTPCookieStorageRef _CFURLStorageSessionCopyCookieStorage(CFAllocatorRef, CFURLStorageSessionRef);
extern CFURLCacheRef _CFURLStorageSessionCopyCache(CFAllocatorRef, CFURLStorageSessionRef);
extern void _CFURLStorageSessionDisableCache(CFURLStorageSessionRef);
extern CFHTTPCookieStorageRef CFHTTPCookieStorageGetDefault(void);
extern CFHTTPCookieStorageRef _CFHTTPCookieStorageGetDefault(CFAllocatorRef);
extern CFIndex CFHTTPCookieStorageGetCookieAcceptPolicy(CFHTTPCookieStorageRef);
extern void CFHTTPCookieStorageSetCookieAcceptPolicy(CFHTTPCookieStorageRef, CFIndex);
extern CFIndex CFHTTPCookieStorageGetAcceptPolicy(CFHTTPCookieStorageRef);
extern void CFHTTPCookieStorageSetCookie(CFHTTPCookieStorageRef, CFHTTPCookieRef);
extern CFArrayRef CFHTTPCookieStorageCopyCookies(CFHTTPCookieStorageRef);
extern void CFHTTPCookieStorageDeleteAllCookies(CFHTTPCookieStorageRef);
extern CFURLCacheRef CFURLCacheCopySharedURLCache(void);
extern CFMutableURLRequestRef CFURLRequestCreateMutableCopy(CFAllocatorRef, CFURLRequestRef);
extern void _CFURLRequestSetStorageSession(CFMutableURLRequestRef, CFURLStorageSessionRef);
extern Boolean _CFNetworkIsKnownHSTSHostWithSession(CFURLRef, CFURLStorageSessionRef);
extern CFStringRef _CFURLCacheCopyCacheDirectory(CFURLCacheRef);
extern void _CFHTTPMessageSetResponseURL(CFHTTPMessageRef, CFURLRef);
extern void _CFHTTPMessageSetResponseProxyURL(CFHTTPMessageRef, CFURLRef);

@interface NSHTTPCookie (Private)
- (CFHTTPCookieRef)_CFHTTPCookie;
@end

@interface NSURLCache (Private)
- (CFURLCacheRef)_CFURLCache;
@end

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); failures++; } else printf("PASS: %s\n", what); } while (0)

static CFIndex cookieCount(CFHTTPCookieStorageRef storage)
{
    CFArrayRef cookies = CFHTTPCookieStorageCopyCookies(storage);
    CFIndex count = cookies ? CFArrayGetCount(cookies) : -1;
    if (cookies)
        CFRelease(cookies);
    return count;
}

int main(void)
{
    @autoreleasepool
    {
        // Asked before NSURLCache: the CF shared cache is the one NSURLCache then wraps.
        CFURLCacheRef shared = CFURLCacheCopySharedURLCache();
        CHECK(shared != NULL, "there is a shared cache before the process sets one");
        CHECK([[NSURLCache sharedURLCache] _CFURLCache] == shared, "NSURLCache's shared cache wraps the same cache");
        CFURLCacheRef again = CFURLCacheCopySharedURLCache();
        CHECK(again == shared, "the shared cache is the same each time");
        CFRelease(again);
        CFRelease(shared);

        CHECK(_CFHTTPCookieStorageGetDefault(kCFAllocatorDefault) == CFHTTPCookieStorageGetDefault(),
              "_CFHTTPCookieStorageGetDefault is the default storage");

        NSDictionary *properties = @{ (id)_kCFURLStorageSessionIsPrivate: @YES };
        CFURLStorageSessionRef session = _CFURLStorageSessionCreate(kCFAllocatorDefault, CFSTR("org.darlinghq.test"), (CFDictionaryRef)properties);
        CHECK(session != NULL, "a session can be made");

        CFHTTPCookieStorageRef cookies = _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, session);
        CFHTTPCookieStorageRef cookiesAgain = _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, session);
        CHECK(cookies != NULL && cookies == cookiesAgain, "a session has one cookie storage");
        CHECK(cookies != CFHTTPCookieStorageGetDefault(), "the session's cookie storage is not the default one");
        CFRelease(cookiesAgain);

        CFHTTPCookieStorageSetCookieAcceptPolicy(cookies, 1 /* never */);
        CHECK(CFHTTPCookieStorageGetCookieAcceptPolicy(cookies) == 1 && CFHTTPCookieStorageGetAcceptPolicy(cookies) == 1,
              "the cookie accept policy accessors are the accept policy ones");
        CFHTTPCookieStorageSetCookieAcceptPolicy(cookies, 0 /* always */);

        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: @"session", NSHTTPCookieValue: @"1", NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"example.org" }];
        CFIndex defaultCount = cookieCount(CFHTTPCookieStorageGetDefault());
        CFHTTPCookieStorageSetCookie(cookies, [cookie _CFHTTPCookie]);
        CHECK(cookieCount(cookies) == 1, "a cookie is kept by the session's storage");
        CHECK(cookieCount(CFHTTPCookieStorageGetDefault()) == defaultCount, "and not by the default one");
        CFHTTPCookieStorageDeleteAllCookies(cookies);
        CHECK(cookieCount(cookies) == 0, "deleting all cookies empties the storage");

        CFURLCacheRef cache = _CFURLStorageSessionCopyCache(kCFAllocatorDefault, session);
        CHECK(cache != NULL && cache != [[NSURLCache sharedURLCache] _CFURLCache], "a session has a cache of its own");
        if (cache)
            CFRelease(cache);
        _CFURLStorageSessionDisableCache(session);
        CHECK(_CFURLStorageSessionCopyCache(kCFAllocatorDefault, session) == NULL, "a disabled cache is gone");

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.org/"]];
        CFMutableURLRequestRef cfRequest = CFURLRequestCreateMutableCopy(kCFAllocatorDefault, (CFURLRequestRef)[request performSelector:@selector(_CFURLRequest)]);
        _CFURLRequestSetStorageSession(cfRequest, session);
        CFRelease(session);
        // the request keeps the session alive
        CFMutableURLRequestRef copy = CFURLRequestCreateMutableCopy(kCFAllocatorDefault, cfRequest);
        CHECK(copy != NULL, "a request with a session can be copied");
        CFRelease(cfRequest);
        CFRelease(copy);

        CFRelease(cookies);

        CHECK(!_CFNetworkIsKnownHSTSHostWithSession((CFURLRef)[NSURL URLWithString:@"https://example.org/"], NULL),
              "no host is a known HSTS host");

        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cfurlstoragesession-cache"];
        NSURLCache *onDisk = [[[NSURLCache alloc] initWithMemoryCapacity:1024 diskCapacity:1024 * 1024
                                                            directoryURL:[NSURL fileURLWithPath:directory]] autorelease];
        CFStringRef onDiskDirectory = _CFURLCacheCopyCacheDirectory([onDisk _CFURLCache]);
        CHECK(onDiskDirectory != NULL && [(NSString *)onDiskDirectory isEqualToString:directory],
              "a cache on disk gives its directory");
        if (onDiskDirectory)
            CFRelease(onDiskDirectory);
        CFURLStorageSessionRef memorySession = _CFURLStorageSessionCreate(kCFAllocatorDefault, CFSTR("org.darlinghq.memory"), NULL);
        CFURLCacheRef memoryCache = _CFURLStorageSessionCopyCache(kCFAllocatorDefault, memorySession);
        CHECK(memoryCache != NULL && _CFURLCacheCopyCacheDirectory(memoryCache) == NULL,
              "a cache kept in memory only has no directory");
        if (memoryCache)
            CFRelease(memoryCache);
        CFRelease(memorySession);

        CFHTTPMessageRef challenge = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 407, NULL, kCFHTTPVersion1_1);
        CFHTTPMessageSetHeaderFieldValue(challenge, CFSTR("Proxy-Authenticate"), CFSTR("Basic realm=\"proxy\""));
        _CFHTTPMessageSetResponseURL(challenge, (CFURLRef)[NSURL URLWithString:@"https://example.org/"]);
        _CFHTTPMessageSetResponseProxyURL(challenge, (CFURLRef)[NSURL URLWithString:@"https://proxy.example:3128"]);
        CFHTTPAuthenticationRef authentication = CFHTTPAuthenticationCreateFromResponse(kCFAllocatorDefault, challenge);
        CHECK(authentication != NULL && CFHTTPAuthenticationIsValid(authentication, NULL),
              "a proxy's challenge with the proxy's URL gives a valid authentication");
        if (authentication)
            CFRelease(authentication);
        CFRelease(challenge);
    }
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

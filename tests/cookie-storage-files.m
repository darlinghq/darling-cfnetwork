// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: cookie storages kept in a file, opened again through their
// identifying data, and the cookies of file URLs.
// - CFHTTPCookieStorageCreateFromFile makes a storage on a file;
//   CFHTTPCookieStorageCreateIdentifyingData gives data naming it, and
//   CFHTTPCookieStorageCreateFromIdentifyingData a new storage object that
//   has the same cookies. Data that names nothing gives NULL. Without a URL,
//   or with a URL of another scheme, there is still a storage that has
//   identifying data (macOS uses the default cookie file and the URL's path).
// - Quirk: cookies set for a file URL get the domain kCFHTTPCookieLocalFileDomain
//   (".^filecookies^"), and match file URLs under their path only.
// Expected values were observed on macOS 26.7.3 (x86_64) with the same inputs.
// - Darling only: with CFHTTPCookieStorageScheduleWithRunLoop, the storage's
//   change callback runs on that run loop. Skipped where the callback SPI is
//   missing (macOS has none of that name).
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef struct __CFHTTPCookieStorage *CFHTTPCookieStorageRef;
extern CFHTTPCookieStorageRef CFHTTPCookieStorageCreateFromFile(CFAllocatorRef, CFURLRef, CFHTTPCookieStorageRef);
extern CFDataRef CFHTTPCookieStorageCreateIdentifyingData(CFAllocatorRef, CFHTTPCookieStorageRef);
extern CFHTTPCookieStorageRef CFHTTPCookieStorageCreateFromIdentifyingData(CFAllocatorRef, CFDataRef);
extern void CFHTTPCookieStorageScheduleWithRunLoop(CFHTTPCookieStorageRef, CFRunLoopRef, CFStringRef);
extern CFStringRef const kCFHTTPCookieLocalFileDomain;

@interface NSHTTPCookieStorage (Private)
- (id)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage;
@end

typedef void (*ChangeCallBack)(CFHTTPCookieStorageRef, void *);
typedef void (*SetChangeCallBack)(CFHTTPCookieStorageRef, ChangeCallBack, void *);

static int failures;

static void report(const char *name, BOOL ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok)
        failures++;
}

static void changed(CFHTTPCookieStorageRef storage, void *info)
{
    (*(int *)info)++;
}

static NSHTTPCookieStorage *wrap(CFHTTPCookieStorageRef storage)
{
    return [[[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage: storage] autorelease];
}

int main(void)
{
    @autoreleasepool {
        report("kCFHTTPCookieLocalFileDomain", [(NSString *) kCFHTTPCookieLocalFileDomain isEqualToString: @".^filecookies^"]);

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat: @"cookie-storage-files-%d.cookies", getpid()]];
        [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
        CFHTTPCookieStorageRef storage = CFHTTPCookieStorageCreateFromFile(NULL, (CFURLRef) [NSURL fileURLWithPath: path], NULL);
        report("CreateFromFile", storage != NULL);
        NSHTTPCookieStorage *cookies = wrap(storage);
        cookies.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;

        // quirk: file URLs
        NSURL *page = [NSURL fileURLWithPath: @"/tmp/page.html"];
        NSArray *parsed = [NSHTTPCookie cookiesWithResponseHeaderFields: @{ @"Set-Cookie": @"a=1; Max-Age=600" } forURL: page];
        NSHTTPCookie *cookie = parsed.firstObject;
        report("quirk: file URLs: the local file domain", parsed.count == 1
               && [cookie.domain isEqualToString: @".^filecookies^"] && [cookie.path isEqualToString: @"/tmp"]);
        [cookies setCookies: parsed forURL: page mainDocumentURL: page];
        report("quirk: file URLs: stored and matched", cookies.cookies.count == 1
               && [cookies cookiesForURL: [NSURL fileURLWithPath: @"/tmp/other.html"]].count == 1);
        report("quirk: file URLs: not under another path", [cookies cookiesForURL: [NSURL fileURLWithPath: @"/var/page.html"]].count == 0);
        report("quirk: file URLs: not for a host", [cookies cookiesForURL: [NSURL URLWithString: @"http://example.com/tmp/"]].count == 0);

        NSHTTPCookie *web = [NSHTTPCookie cookieWithProperties: @{ NSHTTPCookieName: @"b", NSHTTPCookieValue: @"2",
            NSHTTPCookieDomain: @"example.com", NSHTTPCookiePath: @"/", NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow: 3600] }];
        [cookies setCookie: web];

        CFDataRef data = CFHTTPCookieStorageCreateIdentifyingData(NULL, storage);
        report("CreateIdentifyingData", data != NULL && CFDataGetLength(data) > 0);
        CFHTTPCookieStorageRef reopened = CFHTTPCookieStorageCreateFromIdentifyingData(NULL, data);
        report("CreateFromIdentifyingData: another storage", reopened != NULL && reopened != storage);
        NSArray *names = [[wrap(reopened).cookies valueForKey: @"name"] sortedArrayUsingSelector: @selector(compare:)];
        report("CreateFromIdentifyingData: the same cookies", [names isEqualToArray: @[ @"a", @"b" ]]);
        report("CreateFromIdentifyingData: nothing named",
               CFHTTPCookieStorageCreateFromIdentifyingData(NULL, (CFDataRef) [@"garbage" dataUsingEncoding: NSUTF8StringEncoding]) == NULL);

        // Without a URL, or with one of another scheme, there is still a storage, on the
        // default cookie file or on the URL's path, and data that opens it again.
        NSURL *otherScheme = [NSURL URLWithString: @"http://example.com/cookie-storage-files.binarycookies"];
        CFURLRef urls[] = { NULL, (CFURLRef) otherScheme };
        const char *urlNames[] = { "no URL", "an http URL" };
        for (int i = 0; i < 2; i++) {
            CFHTTPCookieStorageRef other = CFHTTPCookieStorageCreateFromFile(NULL, urls[i], NULL);
            CFDataRef otherData = other != NULL ? CFHTTPCookieStorageCreateIdentifyingData(NULL, other) : NULL;
            CFHTTPCookieStorageRef otherReopened = otherData != NULL ? CFHTTPCookieStorageCreateFromIdentifyingData(NULL, otherData) : NULL;
            char name[64];
            snprintf(name, sizeof name, "CreateFromFile with %s", urlNames[i]);
            report(name, other != NULL && otherData != NULL && otherReopened != NULL);
            if (otherReopened != NULL)
                CFRelease(otherReopened);
            if (otherData != NULL)
                CFRelease(otherData);
            if (other != NULL)
                CFRelease(other);
        }

        SetChangeCallBack setChangeCallBack = (SetChangeCallBack) dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageSetChangeCallBack");
        if (setChangeCallBack != NULL) {
            int calls = 0;
            setChangeCallBack(storage, changed, &calls);
            [cookies deleteCookie: web];
            report("Darling: unscheduled, the callback right away", calls == 1);
            CFHTTPCookieStorageScheduleWithRunLoop(storage, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            [cookies setCookie: web];
            BOOL deferred = calls == 1;
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
            report("Darling: scheduled, the callback on the run loop", deferred && calls == 2);
            setChangeCallBack(storage, NULL, NULL);
        }

        [cookies removeCookiesSinceDate: [NSDate distantPast]];
        if (reopened != NULL)
            CFRelease(reopened);
        if (data != NULL)
            CFRelease(data);
        CFRelease(storage);
        [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
    }
    return failures != 0;
}

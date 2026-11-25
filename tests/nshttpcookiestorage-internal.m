// NSHTTPCookieStorage's layout and its wrapping of a CFNetwork cookie storage.
// Apple's public NSHTTPCookieStorage.h gives the class one ivar, _internal;
// code that reaches it (WebKit's CookieStorageObserver does) asks it, with
// -registerForPostingNotificationsWithContext:, to post
// NSHTTPCookieManagerCookiesChangedNotification for a storage object other
// than the shared one. -_initWithCFHTTPCookieStorage: and -_cookieStorage are
// the private methods that make and read such a storage object.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

typedef struct __CFHTTPCookieStorage *CFHTTPCookieStorageRef;
extern CFHTTPCookieStorageRef CFHTTPCookieStorageGetDefault(void);

@interface NSHTTPCookieStorage (Private)
- (id)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage;
- (CFHTTPCookieStorageRef)_cookieStorage;
@property (nonatomic, readwrite) BOOL _overrideSessionCookieAcceptPolicy;
@end

@interface NSObject (CookieStorageInternal)
- (void)registerForPostingNotificationsWithContext:(NSHTTPCookieStorage *)context;
@end

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); failures++; } else printf("PASS: %s\n", what); } while (0)

@interface Counter : NSObject
@property NSUInteger count;
@property (assign) id lastObject;
- (void)changed:(NSNotification *)notification;
@end

@implementation Counter
- (void)changed:(NSNotification *)notification
{
    self.count++;
    self.lastObject = notification.object;
}
@end

int main(void)
{
    @autoreleasepool
    {
        Class cls = [NSHTTPCookieStorage class];
        CHECK(class_getInstanceSize(cls) == 2 * sizeof(void *), "the instance is an isa and one pointer, as in Apple's header");
        Ivar internalIvar = class_getInstanceVariable(cls, "_internal");
        CHECK(internalIvar != NULL && ivar_getOffset(internalIvar) == sizeof(void *), "the ivar is _internal, right after isa");

        NSHTTPCookieStorage *shared = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        CHECK([shared _cookieStorage] == CFHTTPCookieStorageGetDefault(), "the shared storage wraps CFNetwork's default storage");

        CHECK([[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:NULL] == nil, "there is no storage object without a storage");

        NSHTTPCookieStorage *wrapper = [[[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:CFHTTPCookieStorageGetDefault()] autorelease];
        CHECK(wrapper != nil && wrapper != shared && [wrapper _cookieStorage] == CFHTTPCookieStorageGetDefault(),
              "a storage object can wrap a given storage");

        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: @"internal", NSHTTPCookieValue: @"1", NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"example.org" }];
        [shared setCookie:cookie];
        NSArray *seen = [wrapper cookiesForURL:[NSURL URLWithString:@"http://example.org/"]];
        CHECK(seen.count == 1 && [[seen[0] name] isEqualToString:@"internal"], "both objects see the same cookies");

        id internal = object_getIvar(wrapper, internalIvar);
        CHECK([internal respondsToSelector:@selector(registerForPostingNotificationsWithContext:)],
              "the internal object takes the notification registration");

        Counter *counter = [[[Counter alloc] init] autorelease];
        [[NSNotificationCenter defaultCenter] addObserver:counter selector:@selector(changed:)
                                                     name:NSHTTPCookieManagerCookiesChangedNotification object:wrapper];
        [internal registerForPostingNotificationsWithContext:wrapper];
        [wrapper deleteCookie:cookie];
        CHECK(counter.count >= 1 && counter.lastObject == wrapper, "once registered, a change posts the notification for the context");
        [[NSNotificationCenter defaultCenter] removeObserver:counter];

        // another object over the same storage, registered and then gone,
        // leaves the shared storage's notifications alone
        NSHTTPCookieStorage *transient = [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:CFHTTPCookieStorageGetDefault()];
        [object_getIvar(transient, internalIvar) registerForPostingNotificationsWithContext:transient];
        [transient release];
        Counter *sharedCounter = [[[Counter alloc] init] autorelease];
        [[NSNotificationCenter defaultCenter] addObserver:sharedCounter selector:@selector(changed:)
                                                     name:NSHTTPCookieManagerCookiesChangedNotification object:shared];
        [shared setCookie:cookie];
        CHECK(sharedCounter.count >= 1 && sharedCounter.lastObject == shared,
              "the shared storage still posts after another object over its storage is gone");
        [[NSNotificationCenter defaultCenter] removeObserver:sharedCounter];
        [shared deleteCookie:cookie];
    }
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    @autoreleasepool {
        // -_overrideSessionCookieAcceptPolicy: NO until set, a flag of the storage
        // object (another object on the same CFNetwork storage doesn't see it), and
        // independent of cookieAcceptPolicy (macOS 26.7.3).
        NSHTTPCookieStorage *first = [[[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage: CFHTTPCookieStorageGetDefault()] autorelease];
        NSHTTPCookieStorage *second = [[[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage: CFHTTPCookieStorageGetDefault()] autorelease];
        NSHTTPCookieAcceptPolicy policy = first.cookieAcceptPolicy;
        BOOL initially = first._overrideSessionCookieAcceptPolicy;
        first._overrideSessionCookieAcceptPolicy = YES;
        printf("%s: _overrideSessionCookieAcceptPolicy is per object\n",
               !initially && first._overrideSessionCookieAcceptPolicy && !second._overrideSessionCookieAcceptPolicy
               && first.cookieAcceptPolicy == policy ? "PASS" : "FAIL");
        if (initially || !first._overrideSessionCookieAcceptPolicy || second._overrideSessionCookieAcceptPolicy || first.cookieAcceptPolicy != policy)
            failures++;
    }
    return failures != 0;
}

#import <Foundation/Foundation.h>
#include <stdio.h>

// The cookie change handlers of NSHTTPCookieStorage (SPI that WebKit's cookie
// cache uses), as observed on macOS 26.7.3:
// - the handlers and the subscribed hosts belong to the CFNetwork storage: a
//   handler set through one storage object is called for changes made through
//   another over the same storage, and replaced by a handler set through it;
// - no handler is called until a host is subscribed to;
// - for each subscribed host, the changed handler gets the cookies that one
//   call stored or changed and that a request to the host would carry (host-only
//   cookies of the host, domain cookies of it or of a domain above it), and the
//   host; storing a cookie again unchanged calls nothing;
// - deleting a cookie calls the removed handler with it, even if it wasn't
//   stored; removeCookiesSinceDate: calls it with the cookies it removed;
// - deleting all cookies calls the removed handler once, with nil cookies, a
//   nil domain and removeAllCookies set;
// - an expired cookie that replaces a stored one is reported as added;
// - the host is compared as it is, so an uppercase host matches nothing;
// - the handlers run on their queue, or else on another thread.

typedef struct OpaqueCFHTTPCookieStorage *CFHTTPCookieStorageRef;
extern void CFHTTPCookieStorageDeleteAllCookies(CFHTTPCookieStorageRef storage);

@interface NSHTTPCookieStorage (ChangeHandlersSPI)
- (id)_initWithIdentifier:(NSString *)identifier private:(bool)isPrivate;
- (id)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage;
- (CFHTTPCookieStorageRef)_cookieStorage;
- (void)_setSubscribedDomainsForCookieChanges:(NSSet *)domainList;
- (void)_setCookiesChangedHandler:(void (^)(NSArray *addedCookies, NSString *domainForChangedCookie))handler onQueue:(dispatch_queue_t)queue;
- (void)_setCookiesRemovedHandler:(void (^)(NSArray *removedCookies, NSString *domainForRemovedCookies, bool removeAllCookies))handler onQueue:(dispatch_queue_t)queue;
@end

static int failures = 0;
static dispatch_queue_t queue;
static int queueKey;
static NSMutableArray *events;
static BOOL offQueue;

static void expect(BOOL condition, NSString *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition)
        failures++;
}

static NSHTTPCookie *cookie(NSString *name, NSString *value, NSString *domain, NSDate *expires)
{
    NSMutableDictionary *properties = [NSMutableDictionary dictionaryWithDictionary:@{ NSHTTPCookieName: name, NSHTTPCookieValue: value, NSHTTPCookieDomain: domain, NSHTTPCookiePath: @"/" }];
    if (expires != nil)
        properties[NSHTTPCookieExpires] = expires;
    return [NSHTTPCookie cookieWithProperties:properties];
}

static NSString *names(NSArray *cookies)
{
    NSMutableArray *result = [NSMutableArray array];
    for (NSHTTPCookie *c in cookies)
        [result addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
    [result sortUsingSelector:@selector(compare:)];
    return [result componentsJoinedByString:@","];
}

static void record(NSString *event)
{
    if (dispatch_get_specific(&queueKey) != &queueKey)
        offQueue = YES;
    @synchronized(events)
    {
        [events addObject:event];
    }
}

static void watch(NSHTTPCookieStorage *storage, NSString *tag)
{
    [storage _setCookiesChangedHandler:^(NSArray *added, NSString *domain) {
        record([NSString stringWithFormat:@"%@added %@: %@", tag, domain, names(added)]);
    } onQueue:queue];
    [storage _setCookiesRemovedHandler:^(NSArray *removed, NSString *domain, bool all) {
        if (all)
            record([NSString stringWithFormat:@"%@removed all (cookies %@, domain %@)", tag, removed == nil ? @"nil" : @"non-nil", domain == nil ? @"nil" : domain]);
        else
            record([NSString stringWithFormat:@"%@removed %@: %@", tag, domain, names(removed)]);
    } onQueue:queue];
}

// The events since the last call, sorted (the order of the hosts is not specified).
static NSString *drain(void)
{
    usleep(100000);
    dispatch_sync(queue, ^{});
    NSArray *result;
    @synchronized(events)
    {
        result = [events sortedArrayUsingSelector:@selector(compare:)];
        [events removeAllObjects];
    }
    return [result componentsJoinedByString:@" | "];
}

static void expectEvents(NSString *expected, NSString *what)
{
    NSString *got = drain();
    BOOL ok = [got isEqualToString:expected];
    expect(ok, ok ? what : [NSString stringWithFormat:@"%@ (got \"%@\", expected \"%@\")", what, got, expected]);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool
    {
        queue = dispatch_queue_create("handlers", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
        events = [[NSMutableArray alloc] init];

        NSHTTPCookieStorage *storage = [[[NSHTTPCookieStorage alloc] _initWithIdentifier:nil private:YES] autorelease];
        NSHTTPCookieStorage *other = [[[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:[storage _cookieStorage]] autorelease];
        storage.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        watch(storage, @"");

        [storage setCookie:cookie(@"n", @"1", @"www.example.com", nil)];
        expectEvents(@"", @"no handler is called without a subscribed host");

        [storage _setSubscribedDomainsForCookieChanges:[NSSet setWithObject:@"www.example.com"]];
        [storage setCookie:cookie(@"h", @"1", @"www.example.com", nil)];
        expectEvents(@"added www.example.com: h=1", @"a host-only cookie of the subscribed host");
        [storage setCookie:cookie(@"d", @"1", @".example.com", nil)];
        expectEvents(@"added www.example.com: d=1", @"a domain cookie of a domain above the subscribed host");
        [storage setCookie:cookie(@"o", @"1", @"other.com", nil)];
        [storage setCookie:cookie(@"s", @"1", @"sub.www.example.com", nil)];
        [storage setCookie:cookie(@"e", @"1", @"example.com", nil)];
        expectEvents(@"", @"cookies a request to the subscribed host wouldn't carry");

        [other setCookie:cookie(@"b", @"2", @"www.example.com", nil)];
        expectEvents(@"added www.example.com: b=2", @"a change made through another object over the same storage");
        [storage setCookie:cookie(@"h", @"changed", @"www.example.com", nil)];
        expectEvents(@"added www.example.com: h=changed", @"a changed cookie");
        [storage setCookie:cookie(@"h", @"changed", @"www.example.com", nil)];
        expectEvents(@"", @"storing a cookie again unchanged");

        NSURL *url = [NSURL URLWithString:@"http://www.example.com/"];
        [storage setCookies:@[ cookie(@"m1", @"1", @"www.example.com", nil), cookie(@"m2", @"2", @"www.example.com", nil) ] forURL:url mainDocumentURL:url];
        expectEvents(@"added www.example.com: m1=1,m2=2", @"the cookies of one call are reported together");

        [storage setCookie:cookie(@"m1", @"x", @"www.example.com", [NSDate dateWithTimeIntervalSinceNow:-100])];
        expectEvents(@"added www.example.com: m1=x", @"quirk: expired cookie replacing a stored one");
        [storage setCookie:cookie(@"never", @"x", @"www.example.com", [NSDate dateWithTimeIntervalSinceNow:-100])];
        expectEvents(@"", @"an expired cookie that replaces nothing");

        [storage deleteCookie:cookie(@"b", @"2", @"www.example.com", nil)];
        expectEvents(@"removed www.example.com: b=2", @"deleting a cookie");
        [storage deleteCookie:cookie(@"nope", @"1", @"www.example.com", nil)];
        expectEvents(@"removed www.example.com: nope=1", @"quirk: deleting a cookie that is not stored");
        [storage deleteCookie:cookie(@"o", @"1", @"other.com", nil)];
        expectEvents(@"", @"deleting a cookie of another host");

        [storage removeCookiesSinceDate:[NSDate distantPast]];
        expectEvents(@"removed www.example.com: d=1,h=changed,m2=2,n=1", @"removeCookiesSinceDate: reports what it removed");

        [storage _setSubscribedDomainsForCookieChanges:[NSSet setWithObjects:@"www.example.com", @"example.com", nil]];
        [storage setCookie:cookie(@"ov", @"1", @".example.com", nil)];
        expectEvents(@"added example.com: ov=1 | added www.example.com: ov=1", @"a cookie for two subscribed hosts is reported for each");

        [storage _setSubscribedDomainsForCookieChanges:[NSSet setWithObject:@"WWW.Example.COM"]];
        [storage setCookie:cookie(@"up", @"1", @"www.example.com", nil)];
        expectEvents(@"", @"quirk: uppercase host");

        [storage _setSubscribedDomainsForCookieChanges:[NSSet setWithObject:@"www.example.com"]];
        CFHTTPCookieStorageDeleteAllCookies([storage _cookieStorage]);
        expectEvents(@"removed all (cookies nil, domain nil)", @"deleting all cookies");
        CFHTTPCookieStorageDeleteAllCookies([storage _cookieStorage]);
        expectEvents(@"removed all (cookies nil, domain nil)", @"deleting all cookies of an empty storage");

        watch(other, @"other ");
        [storage setCookie:cookie(@"r", @"1", @"www.example.com", nil)];
        expectEvents(@"other added www.example.com: r=1", @"a handler set through another object replaces the first");

        [other _setCookiesChangedHandler:nil onQueue:nil];
        [storage setCookie:cookie(@"r", @"2", @"www.example.com", nil)];
        expectEvents(@"", @"a nil handler stops the calls");

        [storage _setCookiesChangedHandler:^(NSArray *added, NSString *domain) {
            record([NSString stringWithFormat:@"main thread %d", [NSThread isMainThread]]);
        } onQueue:nil];
        offQueue = NO;
        [storage setCookie:cookie(@"q", @"1", @"www.example.com", nil)];
        usleep(300000);
        expectEvents(@"main thread 0", @"without a queue, the handler runs on another thread");
        expect(offQueue, @"... and not on the queue of the other handler");

        watch(storage, @"");
        offQueue = NO;
        [storage setCookie:cookie(@"q", @"2", @"www.example.com", nil)];
        drain();
        expect(!offQueue, @"the handlers run on their queue");

        [storage _setSubscribedDomainsForCookieChanges:nil];
        [storage setCookie:cookie(@"z", @"1", @"www.example.com", nil)];
        CFHTTPCookieStorageDeleteAllCookies([storage _cookieStorage]);
        expectEvents(@"", @"no handler is called once the subscription is cleared");
    }
    printf(failures ? "FAILED\n" : "PASSED\n");
    return failures != 0;
}

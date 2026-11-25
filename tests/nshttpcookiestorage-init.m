#import <Foundation/Foundation.h>
#include <stdio.h>

// A storage object made with -init, of NSHTTPCookieStorage or of a subclass,
// is not backed by any storage (observed on macOS 26.7.3): it keeps no
// cookies, returns nil for -cookies and -cookiesForURL:, its accept policy is
// NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain and can't be changed, and
// what is set on it doesn't reach the shared storage.

@interface SubclassStorage : NSHTTPCookieStorage
@end

@implementation SubclassStorage
@end

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition)
        failures++;
}

static void check(NSHTTPCookieStorage *storage, NSString *what)
{
    NSURL *url = [NSURL URLWithString:@"http://init-test.example/"];
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"a", NSHTTPCookieValue: @"1", NSHTTPCookieDomain: @"init-test.example", NSHTTPCookiePath: @"/" }];

    expect(storage.cookieAcceptPolicy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain, [what stringByAppendingString:@": default accept policy"]);
    storage.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    expect(storage.cookieAcceptPolicy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain, [what stringByAppendingString:@": the accept policy can't be changed"]);
    [storage setCookie:cookie];
    [storage setCookies:@[ cookie ] forURL:url mainDocumentURL:nil];
    expect(storage.cookies == nil, [what stringByAppendingString:@": cookies is nil"]);
    expect([storage cookiesForURL:url] == nil, [what stringByAppendingString:@": cookiesForURL: is nil"]);
    [storage deleteCookie:cookie];
    [storage removeCookiesSinceDate:[NSDate distantPast]];
    expect([[[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url] count] == 0, [what stringByAppendingString:@": the shared storage is not changed"]);
}

int main(void)
{
    @autoreleasepool
    {
        check([[[NSHTTPCookieStorage alloc] init] autorelease], @"NSHTTPCookieStorage");
        check([[[SubclassStorage alloc] init] autorelease], @"subclass");
    }
    printf(failures ? "FAILED\n" : "PASSED\n");
    return failures != 0;
}

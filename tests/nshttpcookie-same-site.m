// NSHTTPCookie's sameSitePolicy (Apple's NSHTTPCookie reference, macOS 10.15)
// and the SameSite cookie attribute (RFC 6265bis, section 5.6.7): Lax and
// Strict, in any case, give the matching policy; None, an unknown value or no
// attribute at all give none. A policy can also come from the properties.
#import <Foundation/Foundation.h>
#include <stdio.h>

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); failures++; } else printf("PASS: %s\n", what); } while (0)

static NSHTTPCookie *cookieFromHeader(NSString *header)
{
    NSURL *url = [NSURL URLWithString:@"https://example.com/"];
    NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": header } forURL:url];
    return cookies.count == 1 ? cookies[0] : nil;
}

int main(void)
{
    @autoreleasepool
    {
        CHECK([NSHTTPCookieSameSiteLax isEqualToString:@"lax"] && [NSHTTPCookieSameSiteStrict isEqualToString:@"strict"]
              && [NSHTTPCookieSameSitePolicy isEqualToString:@"SameSite"],
              "the SameSite constants have the macOS strings");

        CHECK([cookieFromHeader(@"a=1; SameSite=Lax").sameSitePolicy isEqualToString:NSHTTPCookieSameSiteLax],
              "SameSite=Lax gives the lax policy");
        CHECK([cookieFromHeader(@"a=1; samesite=STRICT").sameSitePolicy isEqualToString:NSHTTPCookieSameSiteStrict],
              "the attribute's name and value are case-insensitive");
        CHECK(cookieFromHeader(@"a=1; SameSite=None; Secure").sameSitePolicy == nil,
              "SameSite=None gives no policy");
        CHECK(cookieFromHeader(@"a=1; SameSite=bogus").sameSitePolicy == nil,
              "an unknown value gives no policy");
        CHECK(cookieFromHeader(@"a=1").sameSitePolicy == nil,
              "a cookie without the attribute has no policy");
        CHECK([cookieFromHeader(@"a=1; SameSite=Strict; SameSite=Lax").sameSitePolicy isEqualToString:NSHTTPCookieSameSiteLax],
              "the last SameSite attribute wins");

        NSHTTPCookie *fromProperties = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: @"b", NSHTTPCookieValue: @"2", NSHTTPCookiePath: @"/",
            NSHTTPCookieDomain: @"example.com", NSHTTPCookieSameSitePolicy: NSHTTPCookieSameSiteStrict }];
        CHECK([fromProperties.sameSitePolicy isEqualToString:NSHTTPCookieSameSiteStrict],
              "the policy can be given in the properties");

        NSHTTPCookie *secure = cookieFromHeader(@"a=1; Secure; HttpOnly");
        CHECK(secure.secure && secure.HTTPOnly && secure.sessionOnly,
              "the secure, HTTPOnly and sessionOnly properties read the flags");
    }
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

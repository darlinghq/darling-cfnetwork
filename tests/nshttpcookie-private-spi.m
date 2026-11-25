#import <Foundation/Foundation.h>

// SPI of NSHTTPCookie that WebKit uses (observed on macOS 26.7.3):
// +_cookieForSetCookieString:forURL:partition: parses one Set-Cookie header
// value as +cookiesWithResponseHeaderFields:forURL: does and gives the cookie,
// or nil when it sets none. +_ns2cfCookies: and +_cf2nsCookies: convert arrays
// of cookies between the CFNetwork and Foundation types and keep the cookies.

@interface NSHTTPCookie (PrivateSPI)
+ (NSHTTPCookie *)_cookieForSetCookieString:(NSString *)setCookieString forURL:(NSURL *)URL partition:(NSString *)partition;
+ (NSArray *)_cf2nsCookies:(CFArrayRef)cookies;
+ (CFArrayRef)_ns2cfCookies:(NSArray *)cookies CF_RETURNS_RETAINED;
@end

static int failures = 0;

static void expect(BOOL condition, const char *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition)
        failures++;
}

int main(void)
{
    @autoreleasepool
    {
        NSURL *http = [NSURL URLWithString:@"http://www.example.com/dir/page.html"];
        NSURL *https = [NSURL URLWithString:@"https://www.example.com/dir/page.html"];

        NSHTTPCookie *c = [NSHTTPCookie _cookieForSetCookieString:@"a=b" forURL:http partition:nil];
        expect([c.name isEqualToString:@"a"] && [c.value isEqualToString:@"b"], "name and value");
        expect([c.domain isEqualToString:@"www.example.com"] && [c.path isEqualToString:@"/dir"], "host-only cookie with the default path");
        expect(c.sessionOnly && !c.secure && !c.HTTPOnly, "a plain cookie is a session cookie");

        c = [NSHTTPCookie _cookieForSetCookieString:@" a = b ; path=/y" forURL:http partition:@"part"];
        expect([c.name isEqualToString:@"a"] && [c.value isEqualToString:@"b"] && [c.path isEqualToString:@"/y"], "spaces are trimmed and the Path attribute applies");
        c = [NSHTTPCookie _cookieForSetCookieString:@"a=b; Domain=example.com" forURL:http partition:nil];
        expect([c.domain isEqualToString:@".example.com"], "the Domain attribute makes a domain cookie");
        c = [NSHTTPCookie _cookieForSetCookieString:@"a=b; HttpOnly; SameSite=Lax" forURL:http partition:nil];
        expect(c.HTTPOnly && [c.sameSitePolicy isEqualToString:NSHTTPCookieSameSiteLax], "HttpOnly and SameSite");
        c = [NSHTTPCookie _cookieForSetCookieString:@"a=b; Max-Age=100" forURL:http partition:nil];
        expect(!c.sessionOnly && fabs([c.expiresDate timeIntervalSinceNow] - 100) < 5, "Max-Age sets the expiry");

        expect([NSHTTPCookie _cookieForSetCookieString:@"a=b; Secure" forURL:http partition:nil] == nil, "a Secure cookie from http is ignored");
        expect([NSHTTPCookie _cookieForSetCookieString:@"a=b; Secure" forURL:https partition:nil].secure, "a Secure cookie from https is kept");
        expect([NSHTTPCookie _cookieForSetCookieString:@"a" forURL:http partition:nil] == nil, "no '=' sets no cookie");
        expect([NSHTTPCookie _cookieForSetCookieString:@"=v" forURL:http partition:nil] == nil, "an empty name sets no cookie");
        expect([NSHTTPCookie _cookieForSetCookieString:@"" forURL:http partition:nil] == nil, "an empty string sets no cookie");

        NSHTTPCookie *x = [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"x", NSHTTPCookieValue: @"1", NSHTTPCookieDomain: @"example.com", NSHTTPCookiePath: @"/" }];
        NSHTTPCookie *y = [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: @"y", NSHTTPCookieValue: @"2", NSHTTPCookieDomain: @"other.com", NSHTTPCookiePath: @"/" }];
        CFArrayRef cf = [NSHTTPCookie _ns2cfCookies:@[ x, y ]];
        expect(cf != NULL && CFArrayGetCount(cf) == 2, "_ns2cfCookies: keeps every cookie");
        NSArray *back = [NSHTTPCookie _cf2nsCookies:cf];
        expect([back isEqual:(@[ x, y ])], "_cf2nsCookies: gives the same cookies back");
        if (cf != NULL)
            CFRelease(cf);
        expect([NSHTTPCookie _ns2cfCookies:nil] == NULL, "_ns2cfCookies: of nil is NULL");
        CFArrayRef empty = [NSHTTPCookie _ns2cfCookies:@[]];
        expect(empty != NULL && CFArrayGetCount(empty) == 0, "_ns2cfCookies: of an empty array is empty");
        if (empty != NULL)
            CFRelease(empty);
    }
    return failures != 0;
}

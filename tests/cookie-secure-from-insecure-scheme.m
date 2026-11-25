#import <Foundation/Foundation.h>

// A Secure cookie set over an insecure web protocol is ignored (RFC 6265bis,
// section 5.7, https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/).
// macOS 26.7.3 ignores it for http and ws, localhost included, keeps it for
// https and wss whatever the case of the scheme, and for other schemes too.

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition)
        failures++;
}

static NSUInteger count(NSString *setCookie, NSString *url)
{
    return [[NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": setCookie } forURL:[NSURL URLWithString:url]] count];
}

int main(void)
{
    @autoreleasepool
    {
        for (NSString *url in @[ @"http://www.example.com/", @"http://localhost/", @"http://127.0.0.1/", @"ws://example.com/" ])
        {
            expect(count(@"a=b; Secure", url) == 0, [NSString stringWithFormat:@"a Secure cookie from %@ is ignored", url]);
            expect(count(@"a=b; Partitioned; Secure", url) == 0, [NSString stringWithFormat:@"a partitioned Secure cookie from %@ is ignored", url]);
            expect(count(@"a=b", url) == 1, [NSString stringWithFormat:@"a cookie that isn't Secure from %@ is kept", url]);
        }
        for (NSString *url in @[ @"https://www.example.com/", @"HTTPS://example.com/", @"wss://example.com/", @"file:///tmp/x", @"ftp://example.com/" ])
            expect(count(@"a=b; Secure", url) == 1, [NSString stringWithFormat:@"a Secure cookie from %@ is kept", url]);

        // Only the Secure cookie of several in one header is dropped.
        NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": @"a=1; Secure, b=2" } forURL:[NSURL URLWithString:@"http://www.example.com/"]];
        expect(cookies.count == 1 && [[cookies[0] name] isEqualToString:@"b"], @"only the Secure cookie of a header is dropped");
    }
    return failures != 0;
}

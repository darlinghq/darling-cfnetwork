#import <Foundation/Foundation.h>

// SPI of NSHTTPCookieStorage that WebKit uses:
// -_initWithIdentifier:private: makes a storage of its own that starts empty,
// separate from the shared storage and from every other, and
// -_getCookiesForDomain: gives the cookies a request to that host would carry
// by their domain: host-only cookies of the host and domain cookies of it or of
// a domain above it. A leading dot and the case of the host don't matter.
// (Observed on macOS 26.7.3.)

@interface NSHTTPCookieStorage (PrivateSPI)
- (id)_initWithIdentifier:(NSString *)identifier private:(bool)isPrivate;
- (NSArray *)_getCookiesForDomain:(NSString *)domain;
@end

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition)
        failures++;
}

static NSHTTPCookie *cookie(NSString *name, NSString *domain)
{
    return [NSHTTPCookie cookieWithProperties:@{ NSHTTPCookieName: name, NSHTTPCookieValue: @"v", NSHTTPCookieDomain: domain, NSHTTPCookiePath: @"/" }];
}

static NSString *names(NSArray *cookies)
{
    NSMutableArray *result = [NSMutableArray array];
    for (NSHTTPCookie *c in cookies)
        [result addObject:c.name];
    [result sortUsingSelector:@selector(compare:)];
    return [result componentsJoinedByString:@","];
}

int main(void)
{
    @autoreleasepool
    {
        NSHTTPCookieStorage *storage = [[[NSHTTPCookieStorage alloc] _initWithIdentifier:nil private:YES] autorelease];
        NSHTTPCookieStorage *other = [[[NSHTTPCookieStorage alloc] _initWithIdentifier:nil private:YES] autorelease];
        expect(storage != nil && storage != [NSHTTPCookieStorage sharedHTTPCookieStorage], @"a private storage isn't the shared one");
        expect(storage.cookies.count == 0, @"a private storage starts empty");

        NSUInteger sharedCount = [NSHTTPCookieStorage sharedHTTPCookieStorage].cookies.count;
        for (NSHTTPCookie *c in @[ cookie(@"a", @"example.com"), cookie(@"b", @".example.com"), cookie(@"c", @"sub.example.com"),
                                   cookie(@"d", @"other.com"), cookie(@"e", @"www.example.com") ])
            [storage setCookie:c];
        expect(storage.cookies.count == 5, @"a private storage keeps its cookies");
        expect(other.cookies.count == 0, @"two private storages are separate");
        expect([NSHTTPCookieStorage sharedHTTPCookieStorage].cookies.count == sharedCount, @"a private storage is separate from the shared one");

        NSDictionary *expected = @{
            @"example.com": @"a,b",
            @".example.com": @"a,b",
            @"EXAMPLE.com": @"a,b",
            @"sub.example.com": @"b,c",
            @"www.example.com": @"b,e",
            @"other.com": @"d",
            @"nope.org": @"",
        };
        for (NSString *domain in expected)
        {
            NSString *got = names([storage _getCookiesForDomain:domain]);
            expect([got isEqualToString:expected[domain]], [NSString stringWithFormat:@"cookies for %@: %@ (expected %@)", domain, got, expected[domain]]);
        }
    }
    return failures != 0;
}

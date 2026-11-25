#import <Foundation/Foundation.h>

// Private request settings that WebKit sets: the bound network interface,
// strict fail-closed privacy proxying and partitioned-only cookies. Each
// defaults to nil or NO, is kept by the copies of the request (by -copy and
// -mutableCopy) and survives secure archiving. The two flags take part in
// -isEqual:, the interface doesn't, and none changes -hash. (Observed on
// macOS 26.7.3.)

@interface NSURLRequest (NetworkSettingsSPI)
@property (readonly) NSString *boundInterfaceIdentifier;
@property (readonly) BOOL _privacyProxyStrictFailClosed;
@property (readonly) BOOL _allowOnlyPartitionedCookies;
@end

@interface NSMutableURLRequest (NetworkSettingsSPI)
- (void)setBoundInterfaceIdentifier:(NSString *)identifier;
- (void)_setPrivacyProxyStrictFailClosed:(BOOL)value;
- (void)_setAllowOnlyPartitionedCookies:(BOOL)value;
@end

static int failures = 0;

static void expect(BOOL condition, const char *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition)
        failures++;
}

static NSURLRequest *roundTrip(NSURLRequest *request)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:request requiringSecureCoding:YES error:NULL];
    return [NSKeyedUnarchiver unarchivedObjectOfClass:[NSURLRequest class] fromData:data error:NULL];
}

int main(void)
{
    @autoreleasepool
    {
        NSURL *url = [NSURL URLWithString:@"http://example.com/"];
        NSMutableURLRequest *plain = [NSMutableURLRequest requestWithURL:url];
        expect(plain.boundInterfaceIdentifier == nil, "boundInterfaceIdentifier defaults to nil");
        expect(!plain._privacyProxyStrictFailClosed, "_privacyProxyStrictFailClosed defaults to NO");
        expect(!plain._allowOnlyPartitionedCookies, "_allowOnlyPartitionedCookies defaults to NO");

        NSMutableURLRequest *bound = [NSMutableURLRequest requestWithURL:url];
        [bound setBoundInterfaceIdentifier:@"en0"];
        expect([bound.boundInterfaceIdentifier isEqualToString:@"en0"], "boundInterfaceIdentifier reads back");
        expect([((NSURLRequest *)[[bound copy] autorelease]).boundInterfaceIdentifier isEqualToString:@"en0"], "-copy keeps boundInterfaceIdentifier");
        expect([((NSURLRequest *)[[bound mutableCopy] autorelease]).boundInterfaceIdentifier isEqualToString:@"en0"], "-mutableCopy keeps boundInterfaceIdentifier");
        expect([roundTrip(bound).boundInterfaceIdentifier isEqualToString:@"en0"], "archiving keeps boundInterfaceIdentifier");
        expect([bound isEqual:plain] && bound.hash == plain.hash, "boundInterfaceIdentifier doesn't affect equality");
        [bound setBoundInterfaceIdentifier:nil];
        expect(bound.boundInterfaceIdentifier == nil, "boundInterfaceIdentifier can be cleared");

        NSMutableURLRequest *strict = [NSMutableURLRequest requestWithURL:url];
        [strict _setPrivacyProxyStrictFailClosed:YES];
        expect(strict._privacyProxyStrictFailClosed, "_privacyProxyStrictFailClosed reads back");
        expect([[[strict copy] autorelease] _privacyProxyStrictFailClosed], "-copy keeps _privacyProxyStrictFailClosed");
        expect([[[strict mutableCopy] autorelease] _privacyProxyStrictFailClosed], "-mutableCopy keeps _privacyProxyStrictFailClosed");
        expect(roundTrip(strict)._privacyProxyStrictFailClosed, "archiving keeps _privacyProxyStrictFailClosed");
        expect(![strict isEqual:plain] && strict.hash == plain.hash, "_privacyProxyStrictFailClosed affects equality but not the hash");
        expect([roundTrip(strict) isEqual:strict], "an archived strict request equals the original");

        NSMutableURLRequest *partitioned = [NSMutableURLRequest requestWithURL:url];
        [partitioned _setAllowOnlyPartitionedCookies:YES];
        expect(partitioned._allowOnlyPartitionedCookies, "_allowOnlyPartitionedCookies reads back");
        expect([[[partitioned copy] autorelease] _allowOnlyPartitionedCookies], "-copy keeps _allowOnlyPartitionedCookies");
        expect(roundTrip(partitioned)._allowOnlyPartitionedCookies, "archiving keeps _allowOnlyPartitionedCookies");
        expect(![partitioned isEqual:plain] && partitioned.hash == plain.hash, "_allowOnlyPartitionedCookies affects equality but not the hash");
    }
    return failures != 0;
}

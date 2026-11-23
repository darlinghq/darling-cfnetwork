// Copyright (C) 2026 Lubos Dolezel
//
// NSSecureCoding for NSURLProtectionSpace, which the documentation lists as conforming to NSCoding and
// NSSecureCoding (https://developer.apple.com/documentation/foundation/urlprotectionspace): +supportsSecureCoding,
// and round trips of host, port, protocol, realm, authentication method and proxy-ness through a secure and a
// default NSKeyedArchiver. The documentation gives no archive layout, so the layout is not tested; the file
// checks the public contract and is meant to pass on macOS as well. The malformed-archive checks name this
// implementation's own keys and run only with the argument "strict" (on Darling).
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

// Darling's headers declare setRequiresSecureCoding: nowhere; the test declares the one method it calls (NSCoder.h
// has the getter). Conformance of the class under test is deliberately not declared here: the test checks it.
@interface NSKeyedUnarchiver (SecureCodingTestDeclaration)
- (void)setRequiresSecureCoding:(BOOL)flag;
@end

static int failures;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

static id roundTrip(id obj, BOOL secure) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:secure];
    [archiver encodeObject:obj forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];
    NSData *data = [[[archiver encodedData] retain] autorelease];
    [archiver release];
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
    [u setRequiresSecureCoding:secure];
    id result = nil;
    @try {
        result = [u decodeObjectOfClass:[NSURLProtectionSpace class] forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        result = nil;
    }
    [u finishDecoding];
    return result;
}

static void checkServer(NSString *host, NSInteger port, NSString *protocol, NSString *realm, NSString *method) {
    NSURLProtectionSpace *space = [[[NSURLProtectionSpace alloc] initWithHost:host port:port protocol:protocol realm:realm authenticationMethod:method] autorelease];
    for (int secure = 0; secure < 2; secure++) {
        NSURLProtectionSpace *back = roundTrip(space, secure);
        CHECK(back != nil);
        CHECK([back isKindOfClass:[NSURLProtectionSpace class]]);
        CHECK([back.host isEqualToString:host]);
        CHECK(back.port == port);
        CHECK([back.protocol isEqualToString:protocol]);
        CHECK((back.realm == nil && realm == nil) || [back.realm isEqualToString:realm]);
        CHECK([back.authenticationMethod isEqualToString:method]);
        CHECK(back.isProxy == NO);
        CHECK(back.proxyType == nil);
        CHECK([back isEqual:space]);
        CHECK(back.hash == space.hash);
    }
}

static void checkProxy(NSString *type) {
    NSURLProtectionSpace *space = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"proxy.example.test" port:3128 type:type realm:@"proxy realm" authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
    for (int secure = 0; secure < 2; secure++) {
        NSURLProtectionSpace *back = roundTrip(space, secure);
        CHECK(back != nil);
        CHECK(back.isProxy == YES);
        CHECK([back.proxyType isEqualToString:type]);
        CHECK([back.host isEqualToString:@"proxy.example.test"] && back.port == 3128);
        CHECK([back.realm isEqualToString:@"proxy realm"]);
        CHECK([back.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]);
        CHECK([back isEqual:space]);
    }
}

// Archives with arbitrary stored fields under the class name NSURLProtectionSpace, to make malformed archives.
@interface Spoof : NSObject <NSSecureCoding> { @public NSDictionary *objects; NSDictionary *ints; }
@end
@implementation Spoof
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {
    for (NSString *key in ints) [coder encodeInt64:[ints[key] longLongValue] forKey:key];
    for (NSString *key in objects) [coder encodeObject:objects[key] forKey:key];
}
- (id)initWithCoder:(NSCoder *)coder { return nil; }
@end

static id decodeSpoof(NSDictionary *objects, NSDictionary *ints, BOOL secure) {
    Spoof *s = [[[Spoof alloc] init] autorelease];
    s->objects = objects; s->ints = ints;
    NSKeyedArchiver *a = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
    [a setClassName:@"NSURLProtectionSpace" forClass:[Spoof class]];
    [a encodeObject:s forKey:NSKeyedArchiveRootObjectKey];
    [a finishEncoding];
    NSData *data = [[[a encodedData] retain] autorelease];
    [a release];
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
    [u setRequiresSecureCoding:secure];
    id r = nil;
    @try {
        r = [u decodeObjectOfClass:[NSURLProtectionSpace class] forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        r = nil;
    }
    [u finishDecoding];
    return r;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL strict = argc > 1 && strcmp(argv[1], "strict") == 0;

        CHECK([NSURLProtectionSpace conformsToProtocol:@protocol(NSSecureCoding)]);
        CHECK([(Class<NSSecureCoding>)[NSURLProtectionSpace class] supportsSecureCoding]);

        checkServer(@"example.test", 443, NSURLProtectionSpaceHTTPS, @"members", NSURLAuthenticationMethodHTTPBasic);
        checkServer(@"example.test", 80, NSURLProtectionSpaceHTTP, @"area", NSURLAuthenticationMethodHTTPDigest);
        checkServer(@"ftp.example.test", 21, NSURLProtectionSpaceFTP, @"files", NSURLAuthenticationMethodDefault);
        checkServer(@"example.test", 0, NSURLProtectionSpaceHTTP, nil, NSURLAuthenticationMethodDefault);
        checkServer(@"example.test", 8443, NSURLProtectionSpaceHTTPS, @"unicode é世", NSURLAuthenticationMethodNTLM);

        // Every documented authentication method survives.
        NSArray *methods = @[NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                             NSURLAuthenticationMethodHTMLForm, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
                             NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust];
        for (NSString *m in methods)
            checkServer(@"example.test", 443, NSURLProtectionSpaceHTTPS, @"r", m);

        checkProxy(NSURLProtectionSpaceHTTPProxy);
        checkProxy(NSURLProtectionSpaceHTTPSProxy);
        checkProxy(NSURLProtectionSpaceFTPProxy);
        checkProxy(NSURLProtectionSpaceSOCKSProxy);

        // Spaces that differ stay different after the round trip.
        NSURLProtectionSpace *a = [[[NSURLProtectionSpace alloc] initWithHost:@"example.test" port:443 protocol:NSURLProtectionSpaceHTTPS realm:@"a" authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        NSURLProtectionSpace *b = [[[NSURLProtectionSpace alloc] initWithHost:@"example.test" port:443 protocol:NSURLProtectionSpaceHTTPS realm:@"b" authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        CHECK(![roundTrip(a, YES) isEqual:roundTrip(b, YES)]);

        // A secure unarchiver refuses a class that was not allowed.
        NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:YES] autorelease];
        [archiver encodeObject:a forKey:NSKeyedArchiveRootObjectKey];
        [archiver finishEncoding];
        NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:[archiver encodedData] error:NULL] autorelease];
        [u setRequiresSecureCoding:YES];
        id refused = nil;
        @try {
            refused = [u decodeObjectOfClass:[NSURLRequest class] forKey:NSKeyedArchiveRootObjectKey];
        } @catch (NSException *exception) {
            refused = nil;
        }
        CHECK(refused == nil);

        if (strict) {
            // GUESS keys of src/URL/NSURLProtectionSpace.m. Stored values of the wrong class are not accepted.
            NSDictionary *good = @{@"NS.host": @"example.test", @"NS.protocol": @"https", @"NS.authenticationMethod": NSURLAuthenticationMethodDefault};
            NSDictionary *port = @{@"NS.port": @443};
            // Without secure coding the unarchiver does not check classes itself, so both modes are run.
            for (int secure = 0; secure < 2; secure++) {
                CHECK(decodeSpoof(good, port, secure) != nil);
                CHECK(decodeSpoof(@{@"NS.host": @5}, port, secure) == nil);
                CHECK(decodeSpoof(@{@"NS.host": @"example.test", @"NS.protocol": @[@"https"]}, port, secure) == nil);
                CHECK(decodeSpoof(@{@"NS.host": @"example.test", @"NS.realm": [NSURL URLWithString:@"http://x.test/"]}, port, secure) == nil);
                CHECK(decodeSpoof(@{@"NS.host": @"example.test", @"NS.authenticationMethod": @1}, port, secure) == nil);
                NSURLProtectionSpace *p = decodeSpoof(good, @{@"NS.port": @8080}, secure);
                CHECK(p.isProxy == NO && p.port == 8080);
            }
        }

        if (failures) { printf("%d failure(s)\n", failures); return 1; }
        printf("PASS: NSURLProtectionSpace secure coding\n");
    }
    return 0;
}

// Copyright (C) 2026 Lubos Dolezel
//
// NSSecureCoding for NSURLProtectionSpace, which the documentation lists as conforming to NSCoding and
// NSSecureCoding (https://developer.apple.com/documentation/foundation/urlprotectionspace): +supportsSecureCoding,
// and round trips of host, port, protocol, realm, authentication method and proxy-ness through a secure and a
// default NSKeyedArchiver. The documentation gives no archive layout; the layout checks (test_quirk_archive_layout,
// test_quirk_decode_archive_written_by_macos) pin what macOS 26.7.3 and 10.14.4 write and are meant to pass on
// macOS as well. The malformed-archive checks are specific to this implementation's decoder and run only with the
// argument "strict" (on Darling).
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
        CHECK(back.realm == nil); // test_quirk_proxy_space_has_no_realm: macOS drops the realm of a proxy space
        CHECK([back.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]);
        CHECK([back isEqual:space]);
    }
}

// Reads back the dictionary the protection space archives (an unkeyed encodeObject:, stored in the slot "$0", or the
// key "__nsurlprotectionspace_proto_plist" under secure coding) when it is unarchived in place of the protection space.
@interface Reader : NSObject <NSSecureCoding> { @public NSDictionary *entries; }
@end
@implementation Reader
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (id)initWithCoder:(NSCoder *)coder {
    self = [super init];
    NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSString class], [NSNumber class], nil];
    if ([coder containsValueForKey:@"__nsurlprotectionspace_proto_plist"])
        entries = [[coder decodeObjectOfClasses:classes forKey:@"__nsurlprotectionspace_proto_plist"] retain];
    else
        entries = [[coder decodeObject] retain];
    return self;
}
@end

// Archives with arbitrary stored fields under the class name NSURLProtectionSpace, to make malformed archives.
@interface Spoof : NSObject <NSSecureCoding> { @public NSDictionary *entries; }
@end
@implementation Spoof
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {
    if (!entries) return;
    if ([coder requiresSecureCoding]) [coder encodeObject:entries forKey:@"__nsurlprotectionspace_proto_plist"];
    else [coder encodeObject:entries];
}
- (id)initWithCoder:(NSCoder *)coder { return nil; }
@end

static id decodeSpoof(NSDictionary *entries, BOOL secure) {
    Spoof *s = [[[Spoof alloc] init] autorelease];
    s->entries = entries;
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

static NSDictionary *layoutOf(NSURLProtectionSpace *space, BOOL secure) {
    NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:secure] autorelease];
    [archiver encodeObject:space forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:[archiver encodedData] error:NULL] autorelease];
    [u setRequiresSecureCoding:secure];
    [u setClass:[Reader class] forClassName:@"NSURLProtectionSpace"];
    Reader *reader = [u decodeObjectOfClass:[Reader class] forKey:NSKeyedArchiveRootObjectKey];
    return reader ? reader->entries : nil;
}

static NSDictionary *replace(NSDictionary *dict, NSString *key, id value) {
    NSMutableDictionary *copy = [[dict mutableCopy] autorelease];
    if (value) copy[key] = value; else [copy removeObjectForKey:key];
    return copy;
}

// Archives of NSURLProtectionSpace written by macOS 26.7.3 (NSKeyedArchiver, no secure coding).
static NSString * const kMacArchiveHTTPS =
    @"YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8Q"
    @"D05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBILDBElJicoKSorLC0uLzAxMjlVJG51bGzSDQ4P"
    @"EFIkMFYkY2xhc3OAAoAR0xITDhQcJFdOUy5rZXlzWk5TLm9iamVjdHOnFRYXGBkaG4ADgASABYAG"
    @"gAeACIAJpx0eHyAhIh6ACoALgAyADYAOgA+AC4AQVHBvcnRWc2NoZW1lWF92ZXJzaW9uVV9raW5k"
    @"VGhvc3RVcmVhbG1UdHlwZREBuxACEANfEBBwcm90ZWN0aW9uX3NwYWNlXGV4YW1wbGUudGVzdFdt"
    @"ZW1iZXJz0jM0NTZaJGNsYXNzbmFtZVgkY2xhc3Nlc18QE05TTXV0YWJsZURpY3Rpb25hcnmjNTc4"
    @"XE5TRGljdGlvbmFyeVhOU09iamVjdNIzNDo7XxAUTlNVUkxQcm90ZWN0aW9uU3BhY2WiPDhfEBRO"
    @"U1VSTFByb3RlY3Rpb25TcGFjZQAIABEAGgAkACkAMgA3AEkATABRAFMAaABuAHMAdgB9AH8AgQCI"
    @"AJAAmwCjAKUApwCpAKsArQCvALEAuQC7AL0AvwDBAMMAxQDHAMkAzgDVAN4A5ADpAO8A9AD3APkA"
    @"+wEOARsBIwEoATMBPAFSAVYBYwFsAXEBiAGLAAAAAAAAAgEAAAAAAAAAPQAAAAAAAAAAAAAAAAAA"
    @"AaI=";
static NSString * const kMacArchiveHTTPSSecure =
    @"YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8Q"
    @"D05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBILDBElJicoKSorLC0uLzAxMjlVJG51bGzSDQ4P"
    @"EF8QIl9fbnN1cmxwcm90ZWN0aW9uc3BhY2VfcHJvdG9fcGxpc3RWJGNsYXNzgAKAEdMSEw4UHCRX"
    @"TlMua2V5c1pOUy5vYmplY3RzpxUWFxgZGhuAA4AEgAWABoAHgAiACacdHh8gISIegAqAC4AMgA2A"
    @"DoAPgAuAEFRwb3J0VnNjaGVtZVhfdmVyc2lvblVfa2luZFRob3N0VXJlYWxtVHR5cGURAbsQAhAD"
    @"XxAQcHJvdGVjdGlvbl9zcGFjZVxleGFtcGxlLnRlc3RXbWVtYmVyc9IzNDU2WiRjbGFzc25hbWVY"
    @"JGNsYXNzZXNfEBNOU011dGFibGVEaWN0aW9uYXJ5ozU3OFxOU0RpY3Rpb25hcnlYTlNPYmplY3TS"
    @"MzQ6O18QFE5TVVJMUHJvdGVjdGlvblNwYWNlojw4XxAUTlNVUkxQcm90ZWN0aW9uU3BhY2UACAAR"
    @"ABoAJAApADIANwBJAEwAUQBTAGgAbgBzAJgAnwChAKMAqgCyAL0AxQDHAMkAywDNAM8A0QDTANsA"
    @"3QDfAOEA4wDlAOcA6QDrAPAA9wEAAQYBCwERARYBGQEbAR0BMAE9AUUBSgFVAV4BdAF4AYUBjgGT"
    @"AaoBrQAAAAAAAAIBAAAAAAAAAD0AAAAAAAAAAAAAAAAAAAHE";
static NSString * const kMacArchiveFTP =
    @"YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8Q"
    @"D05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBILDBElJicoKSorLC0uLzAxMjlVJG51bGzSDQ4P"
    @"EFIkMFYkY2xhc3OAAoAR0xITDhQcJFdOUy5rZXlzWk5TLm9iamVjdHOnFRYXGBkaG4ADgASABYAG"
    @"gAeACIAJpx0eHyAhIh+ACoALgAyADYAOgA+ADIAQVHBvcnRWc2NoZW1lWF92ZXJzaW9uVV9raW5k"
    @"VGhvc3RVcmVhbG1UdHlwZRAVEAUQA18QEHByb3RlY3Rpb25fc3BhY2VfEBBmdHAuZXhhbXBsZS50"
    @"ZXN0VWZpbGVz0jM0NTZaJGNsYXNzbmFtZVgkY2xhc3Nlc18QE05TTXV0YWJsZURpY3Rpb25hcnmj"
    @"NTc4XE5TRGljdGlvbmFyeVhOU09iamVjdNIzNDo7XxAUTlNVUkxQcm90ZWN0aW9uU3BhY2WiPDhf"
    @"EBROU1VSTFByb3RlY3Rpb25TcGFjZQAIABEAGgAkACkAMgA3AEkATABRAFMAaABuAHMAdgB9AH8A"
    @"gQCIAJAAmwCjAKUApwCpAKsArQCvALEAuQC7AL0AvwDBAMMAxQDHAMkAzgDVAN4A5ADpAO8A9AD2"
    @"APgA+gENASABJgErATYBPwFVAVkBZgFvAXQBiwGOAAAAAAAAAgEAAAAAAAAAPQAAAAAAAAAAAAAA"
    @"AAAAAaU=";
static NSString * const kMacArchiveProxy =
    @"YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8Q"
    @"D05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBELDBEjJCUmJygpKissLS4vNlUkbnVsbNINDg8Q"
    @"UiQwViRjbGFzc4ACgBDTEhMOFBsiV05TLmtleXNaTlMub2JqZWN0c6YVFhcYGRqAA4AEgAWABoAH"
    @"gAimHB0eHyAhgAmACoALgAyADYAOgA9UcG9ydFhfdmVyc2lvblRob3N0VHR5cGVWc2NoZW1lVV9r"
    @"aW5kEQw4EANfEBJwcm94eS5leGFtcGxlLnRlc3QQBRACXxAQcHJvdGVjdGlvbl9zcGFjZdIwMTIz"
    @"WiRjbGFzc25hbWVYJGNsYXNzZXNfEBNOU011dGFibGVEaWN0aW9uYXJ5ozI0NVxOU0RpY3Rpb25h"
    @"cnlYTlNPYmplY3TSMDE3OF8QFE5TVVJMUHJvdGVjdGlvblNwYWNlojk1XxAUTlNVUkxQcm90ZWN0"
    @"aW9uU3BhY2UACAARABoAJAApADIANwBJAEwAUQBTAGcAbQByAHUAfAB+AIAAhwCPAJoAoQCjAKUA"
    @"pwCpAKsArQC0ALYAuAC6ALwAvgDAAMIAxwDQANUA2gDhAOcA6gDsAQEBAwEFARgBHQEoATEBRwFL"
    @"AVgBYQFmAX0BgAAAAAAAAAIBAAAAAAAAADoAAAAAAAAAAAAAAAAAAAGX";

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

        // The values of the authentication method constants are their names (printed on macOS 26.7.3 and on 10.14.4
        // x86_64); a wrong HTTP basic value once made it indistinguishable from the default method. The i386 slice of
        // 10.14.4 gives HTTP basic the value of the default method (observed), so the checks that need the two to
        // differ are skipped when they are equal.
        BOOL basicIsDefault = [NSURLAuthenticationMethodHTTPBasic isEqualToString:NSURLAuthenticationMethodDefault];
#ifndef __i386__
        CHECK(!basicIsDefault);
        CHECK([NSURLAuthenticationMethodHTTPBasic isEqualToString:@"NSURLAuthenticationMethodHTTPBasic"]);
#endif
        CHECK([NSURLAuthenticationMethodHTTPDigest isEqualToString:@"NSURLAuthenticationMethodHTTPDigest"]);
        CHECK([NSURLAuthenticationMethodDefault isEqualToString:@"NSURLAuthenticationMethodDefault"]);

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

        // test_quirk_proxy_space_has_no_realm: the realm given to the proxy initializer is not kept.
        NSURLProtectionSpace *proxyWithRealm = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"p.test" port:8 type:NSURLProtectionSpaceHTTPProxy realm:@"R" authenticationMethod:NSURLAuthenticationMethodDefault] autorelease];
        CHECK(proxyWithRealm.realm == nil);

        // test_quirk_archive_layout: one dictionary under "$0", numbers as written by macOS.
        {
            struct { NSString *protocol; int type; } servers[] = {{NSURLProtectionSpaceHTTP, 1}, {NSURLProtectionSpaceHTTPS, 2}, {NSURLProtectionSpaceFTP, 3}};
            for (int i = 0; i < 3; i++) {
                NSURLProtectionSpace *s = [[[NSURLProtectionSpace alloc] initWithHost:@"h.test" port:7 protocol:servers[i].protocol realm:nil authenticationMethod:NSURLAuthenticationMethodDefault] autorelease];
                NSDictionary *e = layoutOf(s, NO);
                CHECK([e[@"type"] intValue] == servers[i].type);
                CHECK([layoutOf(s, YES) isEqual:e]); // the secure archive keeps the dictionary under its own key
                CHECK([e[@"_kind"] isEqual:@"protection_space"] && [e[@"_version"] intValue] == 3);
                CHECK([e[@"host"] isEqual:@"h.test"] && [e[@"port"] intValue] == 7 && e[@"realm"] == nil && [e[@"scheme"] intValue] == 1);
            }
            struct { NSString *type; int number; } proxies[] = {{NSURLProtectionSpaceHTTPProxy, 5}, {NSURLProtectionSpaceHTTPSProxy, 6}, {NSURLProtectionSpaceFTPProxy, 7}, {NSURLProtectionSpaceSOCKSProxy, 8}};
            for (int i = 0; i < 4; i++) {
                NSURLProtectionSpace *s = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"h.test" port:7 type:proxies[i].type realm:nil authenticationMethod:NSURLAuthenticationMethodDefault] autorelease];
                CHECK([layoutOf(s, NO)[@"type"] intValue] == proxies[i].number);
            }
            NSString *methods[] = {NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodHTMLForm, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust};
            for (int i = 0; i < 8; i++) {
                NSURLProtectionSpace *s = [[[NSURLProtectionSpace alloc] initWithHost:@"h.test" port:7 protocol:NSURLProtectionSpaceHTTPS realm:@"r" authenticationMethod:methods[i]] autorelease];
                NSDictionary *e = layoutOf(s, NO);
                CHECK([e[@"scheme"] intValue] == i + 1 || (i == 1 && basicIsDefault));
                CHECK([e[@"realm"] isEqual:@"r"]);
                CHECK([[(NSURLProtectionSpace *)roundTrip(s, YES) authenticationMethod] isEqualToString:methods[i]]);
            }
        }

        // test_quirk_decode_archive_written_by_macos: archives written by the proxies' and servers' creators on
        // macOS 26.7.3 (the same bytes as 10.14.4 apart from the order of the dictionary entries).
        {
            struct { NSString *base64; NSString *host; NSInteger port; NSString *protocol; NSString *realm; NSString *method; BOOL proxy; } macArchives[] = {
                {kMacArchiveHTTPS, @"example.test", 443, NSURLProtectionSpaceHTTPS, @"members", NSURLAuthenticationMethodHTTPBasic, NO},
                {kMacArchiveFTP, @"ftp.example.test", 21, NSURLProtectionSpaceFTP, @"files", NSURLAuthenticationMethodNTLM, NO},
                {kMacArchiveProxy, @"proxy.example.test", 3128, NSURLProtectionSpaceHTTPProxy, nil, NSURLAuthenticationMethodHTTPBasic, YES},
            };
            for (int i = 0; i < 3; i++) {
                NSData *data = [[[NSData alloc] initWithBase64EncodedString:macArchives[i].base64 options:0] autorelease];
                // The archives were written without secure coding, so they are read without it.
                {
                    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
                    [u setRequiresSecureCoding:NO];
                    NSURLProtectionSpace *s = nil;
                    @try { s = [u decodeObjectOfClass:[NSURLProtectionSpace class] forKey:NSKeyedArchiveRootObjectKey]; } @catch (NSException *e) { s = nil; }
                    CHECK(s != nil);
                    CHECK([s.host isEqualToString:macArchives[i].host] && s.port == macArchives[i].port);
                    CHECK([s.protocol isEqualToString:macArchives[i].protocol]);
                    CHECK((s.realm == nil && macArchives[i].realm == nil) || [s.realm isEqualToString:macArchives[i].realm]);
                    CHECK([s.authenticationMethod isEqualToString:macArchives[i].method] && s.isProxy == macArchives[i].proxy);
                }
            }
        }

        // test_quirk_decode_archive_written_by_macos, secure coding: the archive written with secure coding.
        {
            NSData *data = [[[NSData alloc] initWithBase64EncodedString:kMacArchiveHTTPSSecure options:0] autorelease];
            NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
            [u setRequiresSecureCoding:YES];
            NSURLProtectionSpace *s = nil;
            @try { s = [u decodeObjectOfClass:[NSURLProtectionSpace class] forKey:NSKeyedArchiveRootObjectKey]; } @catch (NSException *e) { s = nil; }
            CHECK(s != nil && [s.host isEqualToString:@"example.test"] && s.port == 443 && [s.realm isEqualToString:@"members"]);
        }

        if (strict) {
            // GUESS (this implementation's decoder): entries of the wrong class or outside the tables are refused.
            NSDictionary *good = @{@"_kind": @"protection_space", @"_version": @3, @"host": @"example.test", @"port": @443, @"type": @2, @"scheme": @1};
            // Without secure coding the unarchiver does not check classes itself, so both modes are run.
            for (int secure = 0; secure < 2; secure++) {
                CHECK(decodeSpoof(good, secure) != nil);
                CHECK(decodeSpoof(replace(good, @"host", @5), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"realm", @[@"r"]), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"_kind", nil), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"_kind", @"other"), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"port", nil), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"port", @"443"), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"type", @4), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"type", @0), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"type", @9), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"scheme", @0), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"scheme", @9), secure) == nil);
                CHECK(decodeSpoof(replace(good, @"scheme", nil), secure) == nil);
                NSURLProtectionSpace *p = decodeSpoof(replace(good, @"type", @8), secure);
                CHECK(p.isProxy == YES && [p.proxyType isEqualToString:NSURLProtectionSpaceSOCKSProxy]);
                NSURLProtectionSpace *noHost = decodeSpoof(replace(good, @"host", nil), secure);
                CHECK(noHost != nil && noHost.host == nil);
                CHECK(decodeSpoof(nil, secure) == nil);
            }
        }

        if (failures) { printf("%d failure(s)\n", failures); return 1; }
        printf("PASS: NSURLProtectionSpace secure coding\n");
    }
    return 0;
}

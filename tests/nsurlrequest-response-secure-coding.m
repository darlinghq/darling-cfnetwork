// Copyright (C) 2026 Lubos Dolezel
//
// NSSecureCoding for NSURLRequest, NSMutableURLRequest, NSURLResponse and
// NSHTTPURLResponse: +supportsSecureCoding, round trips through a secure
// NSKeyedArchiver, the default (non-secure) archiver, and refusal of archives
// whose stored values have the wrong class. The archive layout is not the
// same as macOS's, so the malformed-archive checks run only with the argument
// "strict" (on Darling); without it the file checks the public contract and
// passes on macOS 27 as well.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

static int failures;
static BOOL strict;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

static id roundTrip(id obj, NSArray *classes, BOOL secure) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:secure];
    [archiver encodeObject:obj forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];
    NSData *data = [[[archiver encodedData] retain] autorelease];
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
    [u setRequiresSecureCoding:secure];
    // A refused class makes the decoding fail: macOS reports the error and returns nil, while Darling's
    // unarchiver raises NSInvalidUnarchiveOperationException.
    id result = nil;
    @try {
        result = [u decodeObjectOfClasses:[NSSet setWithArray:classes] forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        result = nil;
    }
    [u finishDecoding];
    return result;
}

// HTTPShouldUsePipelining is compared with the original, as macOS ignores the setting.
static void checkRequest(NSURLRequest *r, BOOL pipelining) {
    CHECK([r.URL isEqual:[NSURL URLWithString:@"http://example.test/a?b=c"]]);
    CHECK([r.mainDocumentURL isEqual:[NSURL URLWithString:@"http://main.example.test/"]]);
    CHECK(r.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData);
    CHECK(r.timeoutInterval == 12.5);
    CHECK(r.networkServiceType == NSURLNetworkServiceTypeVoIP);
    CHECK(r.allowsCellularAccess == NO);
    CHECK([r.HTTPMethod isEqualToString:@"PUT"]);
    CHECK([r.HTTPBody isEqualToData:[@"payload" dataUsingEncoding:NSUTF8StringEncoding]]);
    CHECK([[r valueForHTTPHeaderField:@"X-Probe"] isEqualToString:@"1"]);
    CHECK([[r valueForHTTPHeaderField:@"Content-Type"] isEqualToString:@"text/plain"]);
    CHECK(r.HTTPShouldHandleCookies == NO);
    CHECK(r.HTTPShouldUsePipelining == pipelining);
}

static NSMutableURLRequest *fullRequest(void) {
    NSMutableURLRequest *m = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/a?b=c"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.5];
    m.HTTPMethod = @"PUT";
    m.allHTTPHeaderFields = @{@"X-Probe": @"1", @"Content-Type": @"text/plain"};
    m.HTTPBody = [@"payload" dataUsingEncoding:NSUTF8StringEncoding];
    m.HTTPShouldHandleCookies = NO;
    m.HTTPShouldUsePipelining = YES;
    m.networkServiceType = NSURLNetworkServiceTypeVoIP;
    m.allowsCellularAccess = NO;
    m.mainDocumentURL = [NSURL URLWithString:@"http://main.example.test/"];
    return m;
}

// Archives with arbitrary stored fields under a chosen class name, to produce malformed archives.
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

static id decodeSpoof(NSString *className, NSDictionary *objects, NSDictionary *ints, Class expected, BOOL secure) {
    Spoof *s = [[[Spoof alloc] init] autorelease];
    s->objects = objects; s->ints = ints;
    NSKeyedArchiver *a = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
    [a setClassName:className forClass:[Spoof class]];
    [a encodeObject:s forKey:NSKeyedArchiveRootObjectKey];
    [a finishEncoding];
    NSData *data = [[[a encodedData] retain] autorelease];
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
    [u setRequiresSecureCoding:secure];
    // NSDecodingFailurePolicySetErrorAndReturn; Darling's unarchiver has no such policy and raises instead.
    if ([u respondsToSelector:@selector(setDecodingFailurePolicy:)])
        [(id)u setDecodingFailurePolicy:(NSInteger)1];
    id r = nil;
    @try {
        r = [u decodeObjectOfClass:expected forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        r = nil;
    }
    [u finishDecoding];
    return r;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        strict = argc > 1 && strcmp(argv[1], "strict") == 0;

        CHECK([NSURLRequest supportsSecureCoding]);
        CHECK([NSMutableURLRequest supportsSecureCoding]);
        CHECK([NSURLResponse supportsSecureCoding]);
        CHECK([NSHTTPURLResponse supportsSecureCoding]);

        // Requests.
        NSArray *reqClasses = @[[NSURLRequest class], [NSMutableURLRequest class]];
        NSMutableURLRequest *full = fullRequest();
        NSURLRequest *r = roundTrip(full, reqClasses, YES);
        CHECK([r isKindOfClass:[NSMutableURLRequest class]]);
        checkRequest(r, full.HTTPShouldUsePipelining);
        NSURLRequest *immutable = [[full copy] autorelease];
        r = roundTrip(immutable, reqClasses, YES);
        CHECK(r != nil);
        checkRequest(r, immutable.HTTPShouldUsePipelining);
        NSMutableURLRequest *mutated = [[roundTrip(full, reqClasses, YES) mutableCopy] autorelease];
        mutated.HTTPMethod = @"POST"; // decoded mutable requests stay mutable
        CHECK([mutated.HTTPMethod isEqualToString:@"POST"]);

        NSURLRequest *plain = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/"]];
        r = roundTrip(plain, reqClasses, YES);
        CHECK([r.URL isEqual:plain.URL] && r.cachePolicy == plain.cachePolicy && r.timeoutInterval == plain.timeoutInterval);
        CHECK([r.HTTPMethod isEqualToString:@"GET"] && r.HTTPBody == nil && r.HTTPShouldHandleCookies == YES);
        CHECK([r class] == [NSURLRequest class]); // an immutable request decodes as immutable

        // The default archiver round trips too; a secure unarchiver refuses a class that was not allowed.
        r = roundTrip(full, reqClasses, NO);
        checkRequest(r, full.HTTPShouldUsePipelining);
        CHECK(roundTrip(full, @[[NSURLResponse class]], YES) == nil);

        // Responses.
        NSURL *url = [NSURL URLWithString:@"http://example.test/file.txt"];
        NSURLResponse *resp = [[[NSURLResponse alloc] initWithURL:url MIMEType:@"text/html" expectedContentLength:123 textEncodingName:@"utf-8"] autorelease];
        NSArray *respClasses = @[[NSURLResponse class], [NSHTTPURLResponse class]];
        NSURLResponse *back = roundTrip(resp, respClasses, YES);
        CHECK(back != nil && ![back isKindOfClass:[NSHTTPURLResponse class]]);
        CHECK([back.URL isEqual:url] && [back.MIMEType isEqualToString:@"text/html"]);
        CHECK(back.expectedContentLength == 123 && [back.textEncodingName isEqualToString:@"utf-8"]);
        CHECK([back.suggestedFilename isEqualToString:resp.suggestedFilename]);
        CHECK(roundTrip(resp, respClasses, NO) != nil);

        NSHTTPURLResponse *http = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:404 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"text/plain; charset=utf-8", @"X-A": @"1"}] autorelease];
        NSHTTPURLResponse *hback = roundTrip(http, respClasses, YES);
        CHECK([hback isKindOfClass:[NSHTTPURLResponse class]]);
        CHECK(hback.statusCode == 404 && [hback.URL isEqual:url]);
        CHECK([[hback.allHeaderFields objectForKey:@"X-A"] isEqualToString:@"1"]);
        CHECK([[hback.allHeaderFields objectForKey:@"Content-Type"] isEqualToString:@"text/plain; charset=utf-8"]);
        CHECK([hback.MIMEType isEqualToString:@"text/plain"] && [hback.textEncodingName isEqualToString:@"utf-8"]);
        CHECK(roundTrip(http, @[[NSURLRequest class]], YES) == nil);

        if (strict) {
            // Malformed archives: stored values of the wrong class must not be accepted.
            CHECK(decodeSpoof(@"NSURLRequest", @{@"NS.url": @"http://example.test/"}, @{}, [NSURLRequest class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLRequest", @{@"NS.url": url, @"NS.HTTPMethod": @[@"GET"]}, @{}, [NSURLRequest class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLRequest", @{@"NS.url": url, @"NS.HTTPBody": @"text"}, @{}, [NSURLRequest class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLRequest", @{@"NS.url": url, @"NS.mainDocumentURL": @"x"}, @{}, [NSURLRequest class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLRequest", @{@"NS.url": url, @"NS.HTTPHeaders": @[@"a"]}, @{}, [NSURLRequest class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLRequest", @{@"NS.url": url, @"NS.HTTPHeaders": @{@"a": @1}}, @{}, [NSURLRequest class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLRequest", @{@"NS.url": url}, @{}, [NSURLRequest class], YES) != nil); // minimal archive is fine
            CHECK(decodeSpoof(@"NSURLResponse", @{@"NS.url": @"http://example.test/"}, @{}, [NSURLResponse class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLResponse", @{@"NS.url": url, @"NS.MIMEType": @5}, @{}, [NSURLResponse class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLResponse", @{@"NS.url": url, @"NS.textEncodingName": [NSURL URLWithString:@"http://other.example.test/"]}, @{}, [NSURLResponse class], YES) == nil);
            CHECK(decodeSpoof(@"NSURLResponse", @{@"NS.url": url}, @{}, [NSURLResponse class], YES) != nil);
            CHECK(decodeSpoof(@"NSHTTPURLResponse", @{@"NS.url": url}, @{}, [NSHTTPURLResponse class], YES) == nil); // no status code
            CHECK(decodeSpoof(@"NSHTTPURLResponse", @{@"NS.url": url, @"NS.headerFields": @"x"}, @{@"NS.statusCode": @200}, [NSHTTPURLResponse class], YES) == nil);
            CHECK(decodeSpoof(@"NSHTTPURLResponse", @{@"NS.url": url, @"NS.headerFields": @{@"a": @1}}, @{@"NS.statusCode": @200}, [NSHTTPURLResponse class], YES) == nil);
            NSHTTPURLResponse *ok = decodeSpoof(@"NSHTTPURLResponse", @{@"NS.url": url}, @{@"NS.statusCode": @204}, [NSHTTPURLResponse class], YES);
            CHECK(ok.statusCode == 204);
        }

        if (failures) { printf("%d failure(s)\n", failures); return 1; }
        printf("PASS: NSURLRequest/NSURLResponse secure coding\n");
    }
    return 0;
}

// Copyright (C) 2026 Lubos Dolezel
//
// NSSecureCoding for NSCachedURLResponse, which the documentation lists as conforming to NSCoding and
// NSSecureCoding (https://developer.apple.com/documentation/foundation/cachedurlresponse): +supportsSecureCoding,
// and round trips of the response, data, user info and storage policy through a secure and a default
// NSKeyedArchiver, with data of every size including none. The documentation gives no archive layout, so the layout is
// not tested here; the file checks the public contract and passes on macOS as well. The archive layout (that of
// macOS), archives written by macOS and the malformed-archive checks are in nscachedurlresponse-macos-archive.m.
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
        result = [u decodeObjectOfClass:[NSCachedURLResponse class] forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        result = nil;
    }
    [u finishDecoding];
    return result;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:@"http://example.test/page.html"];
        NSData *body = [@"<html>cached body</html>" dataUsingEncoding:NSUTF8StringEncoding];

        CHECK([NSCachedURLResponse conformsToProtocol:@protocol(NSSecureCoding)]);
        CHECK([(Class<NSSecureCoding>)[NSCachedURLResponse class] supportsSecureCoding]);

        // An HTTP response with user info, for every storage policy and both archivers.
        NSHTTPURLResponse *http = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"text/html; charset=utf-8", @"X-Probe": @"1"}] autorelease];
        // macOS 26.7.3 and 10.14.4 decode a user info holding an array or a date only without secure coding (a secure
        // unarchiver returns an invalid object), so those values are in the Darling-only checks below.
        NSDictionary *info = @{@"name": @"value", @"count": @3, @"nested": @{@"k": @"v"}, @"blob": [NSData dataWithBytes:"" length:2]};
        NSURLCacheStoragePolicy policies[] = {NSURLCacheStorageAllowed, NSURLCacheStorageAllowedInMemoryOnly, NSURLCacheStorageNotAllowed};
        for (int i = 0; i < 3; i++) {
            NSCachedURLResponse *cached = [[[NSCachedURLResponse alloc] initWithResponse:http data:body userInfo:info storagePolicy:policies[i]] autorelease];
            for (int secure = 0; secure < 2; secure++) {
                NSCachedURLResponse *back = roundTrip(cached, secure);
                CHECK(back != nil);
                CHECK([back isKindOfClass:[NSCachedURLResponse class]]);
                CHECK(back.storagePolicy == policies[i]);
                CHECK([back.data isEqualToData:body]);
                CHECK([back.userInfo isEqualToDictionary:info]);
                CHECK([back.response isKindOfClass:[NSHTTPURLResponse class]]);
                NSHTTPURLResponse *r = (NSHTTPURLResponse *)back.response;
                CHECK(r.statusCode == 200 && [r.URL isEqual:url]);
                CHECK([[r.allHeaderFields objectForKey:@"X-Probe"] isEqualToString:@"1"]);
                CHECK([r.MIMEType isEqualToString:@"text/html"] && [r.textEncodingName isEqualToString:@"utf-8"]);
            }
        }

        // A plain NSURLResponse, no user info (the convenience initializer allows caching on disk).
        NSURLResponse *plain = [[[NSURLResponse alloc] initWithURL:url MIMEType:@"text/plain" expectedContentLength:(NSInteger)[body length] textEncodingName:nil] autorelease];
        NSCachedURLResponse *simple = [[[NSCachedURLResponse alloc] initWithResponse:plain data:body] autorelease];
        NSCachedURLResponse *back = roundTrip(simple, YES);
        CHECK(back != nil);
        CHECK(back.userInfo == nil);
        CHECK(back.storagePolicy == NSURLCacheStorageAllowed);
        CHECK([back.data isEqualToData:body]);
        CHECK(![back.response isKindOfClass:[NSHTTPURLResponse class]]);
        CHECK([back.response.URL isEqual:url] && [back.response.MIMEType isEqualToString:@"text/plain"]);
        CHECK(back.response.expectedContentLength == (long long)[body length]);

        // The unarchived object is a usable cached response: it round trips again.
        NSCachedURLResponse *again = roundTrip(back, YES);
        CHECK(again != nil && [again.data isEqualToData:body] && [again.response.URL isEqual:url]);

        // A secure unarchiver refuses a class that was not allowed.
        NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:YES] autorelease];
        [archiver encodeObject:simple forKey:NSKeyedArchiveRootObjectKey];
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

        // Empty data: a cached response may have no body.
        NSCachedURLResponse *emptyCached = [[[NSCachedURLResponse alloc] initWithResponse:http data:[NSData data] userInfo:nil storagePolicy:NSURLCacheStorageAllowed] autorelease];
        CHECK([emptyCached.data length] == 0);
        for (int secure = 0; secure < 2; secure++) {
            NSCachedURLResponse *emptyBack = roundTrip(emptyCached, secure);
            CHECK(emptyBack != nil && [emptyBack.data length] == 0 && [emptyBack.response.URL isEqual:url]);
        }

        if (failures) { printf("%d failure(s)\n", failures); return 1; }
        printf("PASS: NSCachedURLResponse secure coding\n");
    }
    return 0;
}

// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: -[NSURLCache initWithMemoryCapacity:diskCapacity:directoryURL:] keeps the
// capacities, stores and returns a response, and accepts a nil directory.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int failures;
static void expect(BOOL condition, NSString *label)
{
    printf("%s %s\n", condition ? "PASS" : "FAIL", [label UTF8String]);
    failures += !condition;
}

static void roundTrip(NSURLCache *cache, NSString *label)
{
    NSURL *url = [NSURL URLWithString: @"http://example.test/cached"];
    NSURLRequest *request = [NSURLRequest requestWithURL: url];
    NSData *body = [@"cached body" dataUsingEncoding: NSUTF8StringEncoding];
    NSURLResponse *response = [[[NSURLResponse alloc] initWithURL: url MIMEType: @"text/plain" expectedContentLength: [body length] textEncodingName: @"utf-8"] autorelease];
    NSCachedURLResponse *stored = [[[NSCachedURLResponse alloc] initWithResponse: response data: body] autorelease];
    [cache storeCachedResponse: stored forRequest: request];
    NSCachedURLResponse *found = [cache cachedResponseForRequest: request];
    expect(found != nil && [[found data] isEqualToData: body], [label stringByAppendingString: @": a stored response is returned"]);
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    char tmpl[] = "/tmp/nsurlcache-dir.XXXXXX";
    char *dir = mkdtemp(tmpl);
    NSURL *directory = [NSURL fileURLWithPath: [NSString stringWithUTF8String: dir] isDirectory: YES];

    NSURLCache *cache = [[[NSURLCache alloc] initWithMemoryCapacity: 1 << 20 diskCapacity: 4 << 20 directoryURL: directory] autorelease];
    expect(cache != nil, @"created with a directory URL");
    expect([cache memoryCapacity] == (1 << 20) && [cache diskCapacity] == (4 << 20), @"capacities are kept");
    roundTrip(cache, @"directory URL");

    NSURLCache *defaulted = [[[NSURLCache alloc] initWithMemoryCapacity: 1 << 20 diskCapacity: 0 directoryURL: nil] autorelease];
    expect(defaulted != nil && [defaulted memoryCapacity] == (1 << 20), @"a nil directory URL uses the default location");
    roundTrip(defaulted, @"nil directory");

    system([[NSString stringWithFormat: @"rm -rf '%s'", dir] UTF8String]);
    [pool drain];
    return failures ? 1 : 0;
}

// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: an NSCachedURLResponse initializer that rejects its input (nil response or nil data)
// returns nil and releasing the rejected object does not crash.
#import <Foundation/Foundation.h>
#include <stdio.h>

static int failures;
static void expect(BOOL condition, NSString *label)
{
    printf("%s %s\n", condition ? "PASS" : "FAIL", [label UTF8String]);
    failures += !condition;
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSURL *url = [NSURL URLWithString: @"http://example.test/rejected"];
    NSData *body = [@"body" dataUsingEncoding: NSUTF8StringEncoding];
    NSURLResponse *response = [[[NSURLResponse alloc] initWithURL: url MIMEType: @"text/plain" expectedContentLength: [body length] textEncodingName: @"utf-8"] autorelease];

    NSCachedURLResponse *noResponse = [[NSCachedURLResponse alloc] initWithResponse: nil data: body];
    expect(noResponse == nil, @"a nil response is rejected");
    NSCachedURLResponse *noData = [[NSCachedURLResponse alloc] initWithResponse: response data: nil];
    expect(noData == nil, @"nil data is rejected");

    NSCachedURLResponse *valid = [[NSCachedURLResponse alloc] initWithResponse: response data: body];
    expect(valid != nil && [[valid data] isEqualToData: body], @"a valid response is accepted");
    [valid release];

    [pool drain];
    puts(failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}

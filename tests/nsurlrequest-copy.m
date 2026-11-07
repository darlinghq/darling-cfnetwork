#import <Foundation/Foundation.h>

// copy and mutableCopy of NSURLRequest must keep every field (VibeDarling/darling#831).

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

static void checkRequest(NSURLRequest *r, NSString *label)
{
    expect([[r URL] isEqual:[NSURL URLWithString:@"http://example.test/a?b=c"]], [label stringByAppendingString:@": URL"]);
    expect([[r mainDocumentURL] isEqual:[NSURL URLWithString:@"http://main.example.test/"]], [label stringByAppendingString:@": mainDocumentURL"]);
    expect([r networkServiceType] == NSURLNetworkServiceTypeBackground, [label stringByAppendingString:@": networkServiceType"]);
    expect([r allowsCellularAccess] == NO, [label stringByAppendingString:@": allowsCellularAccess"]);
    expect([r cachePolicy] == NSURLRequestReloadIgnoringLocalCacheData, [label stringByAppendingString:@": cachePolicy"]);
    expect([r timeoutInterval] == 12.5, [label stringByAppendingString:@": timeoutInterval"]);
    expect([[r HTTPMethod] isEqualToString:@"PUT"], [label stringByAppendingString:@": HTTPMethod"]);
    expect([[r HTTPBody] isEqualToData:[@"payload" dataUsingEncoding:NSUTF8StringEncoding]], [label stringByAppendingString:@": HTTPBody"]);
    expect([[r valueForHTTPHeaderField:@"X-Probe"] isEqualToString:@"1"], [label stringByAppendingString:@": X-Probe header"]);
    expect([[r valueForHTTPHeaderField:@"Content-Type"] isEqualToString:@"text/plain"], [label stringByAppendingString:@": Content-Type header"]);
    expect([r HTTPShouldHandleCookies] == NO, [label stringByAppendingString:@": HTTPShouldHandleCookies"]);
    expect([r HTTPShouldUsePipelining] == YES, [label stringByAppendingString:@": HTTPShouldUsePipelining"]);
}

int main(void)
{
    @autoreleasepool
    {
        NSMutableURLRequest *original = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/a?b=c"]
                                                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                            timeoutInterval:12.5];
        [original setMainDocumentURL:[NSURL URLWithString:@"http://main.example.test/"]];
        [original setNetworkServiceType:NSURLNetworkServiceTypeBackground];
        [original setAllowsCellularAccess:NO];
        [original setHTTPMethod:@"PUT"];
        [original setHTTPBody:[@"payload" dataUsingEncoding:NSUTF8StringEncoding]];
        [original setValue:@"1" forHTTPHeaderField:@"X-Probe"];
        [original setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
        [original setHTTPShouldHandleCookies:NO];
        [original setHTTPShouldUsePipelining:YES];
        checkRequest(original, @"original");

        NSURLRequest *copy = [original copy];
        checkRequest(copy, @"copy");
        expect(![copy isKindOfClass:[NSMutableURLRequest class]], @"copy is immutable");

        NSMutableURLRequest *mutableCopy = [original mutableCopy];
        checkRequest(mutableCopy, @"mutableCopy");

        NSURLRequest *copyOfCopy = [copy copy];
        checkRequest(copyOfCopy, @"copy of copy");
        NSMutableURLRequest *mutableCopyOfCopy = [copy mutableCopy];
        checkRequest(mutableCopyOfCopy, @"mutableCopy of copy");

        [mutableCopy setValue:@"2" forHTTPHeaderField:@"X-Probe"];
        [mutableCopy setMainDocumentURL:[NSURL URLWithString:@"http://other.example.test/"]];
        checkRequest(original, @"original after mutating its mutableCopy");
        checkRequest(copy, @"copy after mutating the mutableCopy");
    }

    if (failures == 0)
        NSLog(@"PASS: nsurlrequest-copy");
    return failures == 0 ? 0 : 1;
}

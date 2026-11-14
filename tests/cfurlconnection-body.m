// Copyright (C) 2026 Lubos Dolezel
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// Response bodies loaded through NSURLConnection (CFURLConnection underneath) from
// tests/cfurlconnection-test-server.py, and Set-Cookie parsing without a Domain attribute.
// usage: cfurlconnection-body HTTP_BASE     e.g.  cfurlconnection-body http://127.0.0.1:8770
// Prints PASS/FAIL lines; the exit status is the number of failures.

static int failures;

static void expect(BOOL ok, NSString *what)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", [what UTF8String]);
    if (!ok)
        failures++;
}

static NSData *load(NSString *base, NSString *path, NSHTTPURLResponse **response, NSError **error)
{
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:30];
    return [NSURLConnection sendSynchronousRequest:request returningResponse:(NSURLResponse **)response error:error];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s HTTP_BASE\n", argv[0]);
            return 2;
        }
        NSString *base = [NSString stringWithUTF8String:argv[1]];
        NSMutableData *textBytes = [NSMutableData data];
        for (int i = 0; i < 40; i++)
            [textBytes appendData:[@"The quick brown fox jumps over the lazy dog. " dataUsingEncoding:NSUTF8StringEncoding]];

        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = load(base, @"/plain", &response, &error);
        expect([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqualToString:@"plain body"], @"no Content-Encoding: body unchanged");

        data = load(base, @"/gzip", &response, &error);
        expect([data isEqualToData:textBytes], @"gzip body, sent in pieces, is inflated across chunks");

        data = load(base, @"/deflate", &response, &error);
        expect([data isEqualToData:textBytes], @"deflate body, sent in pieces, is inflated across chunks");

        data = load(base, @"/gzip-big", &response, &error);
        expect([data length] == (1u << 20), @"gzip body that expands 1000-fold is complete");

        error = nil;
        data = load(base, @"/unknown-encoding", &response, &error);
        expect(error == nil && [data isEqualToData:textBytes], @"unknown Content-Encoding value: body delivered as received");

        error = nil;
        data = load(base, @"/identity", &response, &error);
        expect(error == nil && [data isEqualToData:textBytes], @"Content-Encoding identity: body delivered as received");

        /* a Set-Cookie header without a Domain attribute takes the request host */
        NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/cookie"]];
        NSDictionary *fields = @{ @"Set-Cookie": @"session=abc123; Path=/" };
        NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:fields forURL:url];
        expect([cookies count] == 1 && [[[cookies firstObject] domain] isEqualToString:[url host]], @"Set-Cookie without Domain gets the request host");
    }
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures;
}

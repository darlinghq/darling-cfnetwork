#import <Foundation/Foundation.h>

// -[NSHTTPURLResponse valueForHTTPHeaderField:]
// (https://developer.apple.com/documentation/foundation/httpurlresponse/value(forhttpheaderfield:)):
// the value of a header field, whatever the case of its name, or nil. Looking
// a field up in allHeaderFields ignores the case too. (Observed on macOS 26.7.3.)

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition)
        failures++;
}

int main(void)
{
    @autoreleasepool
    {
        NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.com/"] statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                                 headerFields:@{ @"Content-Type": @"text/html", @"X-Custom": @"1" }] autorelease];
        for (NSString *name in @[ @"Content-Type", @"content-type", @"CONTENT-TYPE" ])
        {
            expect([[response valueForHTTPHeaderField:name] isEqualToString:@"text/html"], [NSString stringWithFormat:@"valueForHTTPHeaderField: %@", name]);
            expect([response.allHeaderFields[name] isEqualToString:@"text/html"], [NSString stringWithFormat:@"allHeaderFields[%@]", name]);
        }
        expect([[response valueForHTTPHeaderField:@"x-custom"] isEqualToString:@"1"], @"valueForHTTPHeaderField: x-custom");
        expect([response valueForHTTPHeaderField:@"Missing"] == nil, @"a missing field is nil");
        expect([response valueForHTTPHeaderField:@""] == nil, @"an empty name is nil");

        NSHTTPURLResponse *empty = [[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.com/"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil] autorelease];
        expect([empty valueForHTTPHeaderField:@"Content-Type"] == nil, @"a response without fields has none");
    }
    return failures != 0;
}

#import <Foundation/Foundation.h>

// NSHTTPURLResponse expectedContentLength, MIMEType and textEncodingName from header fields.

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

static NSHTTPURLResponse *response(NSDictionary *headers)
{
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.test/"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:headers];
}

static void checkLength(NSDictionary *headers, long long expected)
{
    long long length = [response(headers) expectedContentLength];
    expect(length == expected, [NSString stringWithFormat:@"%@: expectedContentLength %lld, want %lld", headers, length, expected]);
}

static void checkContentType(NSString *contentType, NSString *mimeType, NSString *encoding)
{
    NSHTTPURLResponse *r = response(@{ @"Content-Type": contentType });
    expect([[r MIMEType] isEqualToString:mimeType], [NSString stringWithFormat:@"'%@': MIMEType %@, want %@", contentType, [r MIMEType], mimeType]);
    BOOL encodingMatches = encoding == nil ? [r textEncodingName] == nil : [[r textEncodingName] isEqualToString:encoding];
    expect(encodingMatches, [NSString stringWithFormat:@"'%@': textEncodingName %@, want %@", contentType, [r textEncodingName], encoding]);
}

int main(void)
{
    @autoreleasepool
    {
        checkLength(@{ @"Content-Length": @"16" }, 16);
        checkLength(@{ @"Content-Length": @"0" }, 0);
        checkLength(@{ @"Content-Length": @"5000000000" }, 5000000000LL);
        checkLength(@{}, NSURLResponseUnknownLength);
        checkLength(@{ @"Content-Length": @"abc" }, NSURLResponseUnknownLength);
        checkLength(@{ @"Content-Length": @"-3" }, NSURLResponseUnknownLength);

        checkContentType(@"text/plain", @"text/plain", nil);
        checkContentType(@"text/plain; charset=utf-8", @"text/plain", @"utf-8");
        checkContentType(@"text/html;charset=ISO-8859-1", @"text/html", @"ISO-8859-1");
        checkContentType(@"text/html; Charset=\"utf-8\"", @"text/html", @"utf-8");
        checkContentType(@"text/plain; charset=utf-8; format=flowed", @"text/plain", @"utf-8");
    }

    if (failures == 0)
        NSLog(@"PASS: nshttpurlresponse-fields");
    return failures == 0 ? 0 : 1;
}

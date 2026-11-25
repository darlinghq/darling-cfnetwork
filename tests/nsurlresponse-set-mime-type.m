#import <Foundation/Foundation.h>

// -[NSURLResponse _setMIMEType:] (SPI that WebKit uses) replaces the MIME type
// and nothing else: the header fields and text encoding name stay as they are,
// and nil clears it. (Observed on macOS 26.7.3.)

@interface NSURLResponse (SetMIMETypeSPI)
- (void)_setMIMEType:(NSString *)type;
@end

static int failures = 0;

static void expect(BOOL condition, const char *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition)
        failures++;
}

int main(void)
{
    @autoreleasepool
    {
        NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.com/a.txt"] statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                                 headerFields:@{ @"Content-Type": @"text/plain; charset=utf-8" }] autorelease];
        expect([response.MIMEType isEqualToString:@"text/plain"], "the MIME type comes from Content-Type");
        [response _setMIMEType:@"text/html"];
        expect([response.MIMEType isEqualToString:@"text/html"], "_setMIMEType: replaces the MIME type");
        expect([response.textEncodingName isEqualToString:@"utf-8"], "_setMIMEType: keeps the text encoding name");
        expect([response.allHeaderFields[@"Content-Type"] isEqualToString:@"text/plain; charset=utf-8"], "_setMIMEType: keeps the header fields");
        [response _setMIMEType:nil];
        expect(response.MIMEType == nil, "_setMIMEType: nil clears the MIME type");

        NSURLResponse *plain = [[[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"file:///tmp/x"] MIMEType:@"text/plain" expectedContentLength:1 textEncodingName:nil] autorelease];
        [plain _setMIMEType:@"image/png"];
        expect([plain.MIMEType isEqualToString:@"image/png"] && plain.expectedContentLength == 1, "_setMIMEType: on a response that isn't HTTP");
    }
    return failures != 0;
}

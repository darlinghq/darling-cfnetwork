// Guest test: an archived NSURLRequest decodes under strict secure decoding
// (-[NSKeyedUnarchiver _enableStrictSecureDecodingMode], which accepts only the
// classes asked for, not subclasses), with the set of classes WebKit allows
// when it sends requests between its processes. The request's values are
// mutable objects, as an application's often are. Checked on macOS 26.7.3
// (x86_64) with the same calls.
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface NSKeyedUnarchiver (StrictSPI)
- (void)_enableStrictSecureDecodingMode;
@end

@interface NSMutableURLRequest (EncodingFallbackSPI)
- (void)setContentDispositionEncodingFallbackArray:(NSArray *)array;
@end
@interface NSURLRequest (EncodingFallbackSPI)
- (NSArray *)contentDispositionEncodingFallbackArray;
@end

static int failures;

static void report(const char *name, BOOL ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok)
        failures++;
}

int main(void)
{
    @autoreleasepool {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL: [NSURL URLWithString: @"http://example.com/path"]];
        request.HTTPMethod = [[@"POST" mutableCopy] autorelease];
        request.allHTTPHeaderFields = [NSMutableDictionary dictionaryWithObject: [[@"text/html" mutableCopy] autorelease] forKey: @"Accept"];
        request.HTTPBody = [NSMutableData dataWithBytes: "a=1" length: 3];
        request.mainDocumentURL = [NSURL URLWithString: @"http://example.com/"];
        BOOL hasFallback = [request respondsToSelector: @selector(setContentDispositionEncodingFallbackArray:)];
        if (hasFallback)
            [request setContentDispositionEncodingFallbackArray: [NSMutableArray arrayWithObject: @(NSUTF8StringEncoding)]];

        NSError *error = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject: request requiringSecureCoding: YES error: &error];
        report("archives", data != nil && error == nil);

        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData: data error: NULL];
        unarchiver.decodingFailurePolicy = NSDecodingFailurePolicyRaiseException;
        [unarchiver _enableStrictSecureDecodingMode];
        NSSet *allowed = [NSSet setWithObjects: [NSURLRequest class], [NSMutableURLRequest class], [NSMutableString class], [NSMutableArray class],
                                                [NSMutableDictionary class], [NSMutableData class], [NSURL class], nil];
        NSURLRequest *decoded = nil;
        NSString *reason = nil;
        @try {
            decoded = [unarchiver decodeObjectOfClasses: allowed forKey: NSKeyedArchiveRootObjectKey];
        } @catch (NSException *exception) {
            reason = exception.reason;
        }
        [unarchiver finishDecoding];
        report("decodes strictly", decoded != nil);
        if (reason != nil)
            printf("  exception: %s\n", reason.UTF8String);
        report("URL", [decoded.URL isEqual: request.URL]);
        report("HTTP method", [decoded.HTTPMethod isEqualToString: @"POST"]);
        report("header field", [[decoded valueForHTTPHeaderField: @"Accept"] isEqualToString: @"text/html"]);
        report("body", [decoded.HTTPBody isEqual: [NSData dataWithBytes: "a=1" length: 3]]);
        report("main document URL", [decoded.mainDocumentURL isEqual: request.mainDocumentURL]);
        if (hasFallback)
            report("encoding fallback array", [[decoded contentDispositionEncodingFallbackArray] isEqual: @[ @(NSUTF8StringEncoding) ]]);
        [unarchiver release];
    }
    return failures != 0;
}

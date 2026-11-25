// The CFNetwork SPI WebKit's ResourceRequest, ResourceResponse and cookie code
// call, checked through the public classes they back:
// - a request's priority is 0 until set, is kept by a mutable request and
//   survives copying; an immutable request ignores the setter;
// - protocol properties set with _CFURLRequestSetProtocolProperty are the
//   ones +[NSURLProtocol propertyForKey:inRequest:] reads, they survive
//   copying, and a NULL value removes one;
// - CFURLResponseGetHTTPResponse gives an HTTP response's status and fields,
//   and NULL for a response that is not an HTTP one;
// - CFURLResponseSetMIMEType changes the type the NSURLResponse reports;
// - an NSHTTPCookie gives its CFHTTPCookie under both private names, and
//   belongs to no partition;
// - the partition-scoped cookie getters call their handler before they
//   return, with the storage's cookies.
// The functions are private, so they are declared here.
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#include <stdio.h>

typedef const struct _CFURLRequest *CFURLRequestRef;
typedef const struct _CFURLResponse *CFURLResponseRef;
typedef struct __CFHTTPCookie *CFHTTPCookieRef;

extern CFIndex CFURLRequestGetRequestPriority(CFURLRequestRef);
extern void CFURLRequestSetRequestPriority(CFURLRequestRef, CFIndex);
extern void _CFURLRequestSetProtocolProperty(CFURLRequestRef, CFStringRef, CFTypeRef);
extern CFHTTPMessageRef CFURLResponseGetHTTPResponse(CFURLResponseRef);
extern void CFURLResponseSetMIMEType(CFURLResponseRef, CFStringRef);

@interface NSURLRequest (Private)
- (CFURLRequestRef)_CFURLRequest;
@end

@interface NSURLResponse (Private)
- (CFURLResponseRef)_CFURLResponse;
@end

@interface NSHTTPCookie (Private)
- (CFHTTPCookieRef)_CFHTTPCookie;
- (CFHTTPCookieRef)_GetInternalCFHTTPCookie;
- (NSString *)_storagePartition;
@end

@interface NSHTTPCookieStorage (Private)
- (void)_getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition policyProperties:(NSDictionary *)props completionHandler:(void (^)(NSArray *))completionHandler;
- (void)_getCookiesForPartition:(NSString *)partition completionHandler:(void (^)(NSArray *))completionHandler;
- (void)_saveCookies:(dispatch_block_t)completionHandler;
@end

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); failures++; } else printf("PASS: %s\n", what); } while (0)

int main(void)
{
    @autoreleasepool
    {
        NSURL *url = [NSURL URLWithString:@"http://example.org/page"];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        CHECK(CFURLRequestGetRequestPriority([request _CFURLRequest]) == 0, "a request's priority is 0 until set");
        CFURLRequestSetRequestPriority([request _CFURLRequest], 3);
        CHECK(CFURLRequestGetRequestPriority([request _CFURLRequest]) == 3, "a mutable request keeps its priority");
        NSURLRequest *copy = [[request copy] autorelease];
        CHECK(CFURLRequestGetRequestPriority([copy _CFURLRequest]) == 3, "the priority survives copying");
        CFURLRequestSetRequestPriority([copy _CFURLRequest], 1);
        CHECK(CFURLRequestGetRequestPriority([copy _CFURLRequest]) == 3, "an immutable request ignores the setter");

        _CFURLRequestSetProtocolProperty([request _CFURLRequest], CFSTR("org.darlinghq.key"), kCFBooleanTrue);
        CHECK([[NSURLProtocol propertyForKey:@"org.darlinghq.key" inRequest:request] isEqual:@YES],
              "NSURLProtocol reads a property CFNetwork set");
        [NSURLProtocol setProperty:@"value" forKey:@"org.darlinghq.other" inRequest:request];
        NSURLRequest *withProperties = [[request copy] autorelease];
        CHECK([[NSURLProtocol propertyForKey:@"org.darlinghq.other" inRequest:withProperties] isEqual:@"value"],
              "the properties survive copying");
        NSString *key = [NSString stringWithFormat:@"org.darlinghq.%@", @"other"];
        CHECK([[NSURLProtocol propertyForKey:key inRequest:request] isEqual:@"value"],
              "a property is found by an equal key, not only the same object");
        _CFURLRequestSetProtocolProperty([request _CFURLRequest], CFSTR("org.darlinghq.key"), NULL);
        CHECK([NSURLProtocol propertyForKey:@"org.darlinghq.key" inRequest:request] == nil, "a NULL value removes the property");

        NSHTTPURLResponse *http = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:404 HTTPVersion:@"HTTP/1.1"
                                                              headerFields:@{ @"Content-Type": @"text/html", @"X-Test": @"1" }] autorelease];
        CFHTTPMessageRef message = CFURLResponseGetHTTPResponse([http _CFURLResponse]);
        CHECK(message != NULL && CFHTTPMessageGetResponseStatusCode(message) == 404, "an HTTP response has its message and status");
        CFStringRef field = message ? CFHTTPMessageCopyHeaderFieldValue(message, CFSTR("X-Test")) : NULL;
        CHECK(field != NULL && CFEqual(field, CFSTR("1")), "the message has the response's fields");
        if (field)
            CFRelease(field);
        CHECK(CFURLResponseGetHTTPResponse([http _CFURLResponse]) == message, "the message is the same each time");

        NSURLResponse *plain = [[[NSURLResponse alloc] initWithURL:url MIMEType:@"text/plain" expectedContentLength:3 textEncodingName:nil] autorelease];
        CHECK(CFURLResponseGetHTTPResponse([plain _CFURLResponse]) == NULL, "a response that is not an HTTP one has no message");
        CFURLResponseSetMIMEType([plain _CFURLResponse], CFSTR("application/json"));
        CHECK([[plain MIMEType] isEqualToString:@"application/json"], "setting the MIME type changes the response's");

        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: @"spi", NSHTTPCookieValue: @"1", NSHTTPCookiePath: @"/", NSHTTPCookieDomain: @"example.org" }];
        CHECK([cookie _CFHTTPCookie] != NULL && [cookie _CFHTTPCookie] == [cookie _GetInternalCFHTTPCookie],
              "a cookie gives its CFHTTPCookie under both names");
        CHECK([cookie _storagePartition] == nil, "a cookie belongs to no partition");

        NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        [storage setCookie:cookie];
        __block NSArray *forURL = nil;
        [storage _getCookiesForURL:url mainDocumentURL:url partition:nil policyProperties:nil completionHandler:^(NSArray *cookies) {
            forURL = [cookies retain];
        }];
        CHECK(forURL != nil && [[forURL valueForKey:@"name"] containsObject:@"spi"],
              "the cookies for a URL are given before the call returns");
        [forURL release];
        __block BOOL gotPartition = NO;
        [storage _getCookiesForPartition:@"https://example.org" completionHandler:^(NSArray *cookies) {
            gotPartition = cookies != nil;
        }];
        CHECK(gotPartition, "the cookies of a partition are given before the call returns");
        __block BOOL saved = NO;
        [storage _saveCookies:^{ saved = YES; }];
        CHECK(saved, "saving calls its handler before it returns");
        [storage deleteCookie:cookie];
    }
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

// The CFNetwork SPI WebKit's CFNetwork loader calls to give a request its body,
// and to size its connection scheduler, checked through the public classes:
// - CFURLRequestSetHTTPRequestBody gives the request the data NSURLRequest's
//   HTTPBody reports, and CFURLRequestSetHTTPRequestBodyStream the stream
//   HTTPBodyStream reports;
// - a request has a body or a body stream, never both: setting one discards
//   the other, as NSMutableURLRequest documents for its setters;
// - a NULL body or stream removes it;
// - _CFNetworkHTTPConnectionCacheGetLimit gives back the value last set
//   with _CFNetworkHTTPConnectionCacheSetLimit for the same key;
// - NSURLAuthenticationMethodOAuth is a constant that differs from the
//   documented methods.
// The functions are private, so they are declared here.
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#include <stdio.h>

typedef const struct _CFURLRequest *CFURLRequestRef;
typedef struct _CFURLRequest *CFMutableURLRequestRef;

extern void CFURLRequestSetHTTPRequestBody(CFMutableURLRequestRef, CFDataRef);
extern void CFURLRequestSetHTTPRequestBodyStream(CFMutableURLRequestRef, CFReadStreamRef);

enum { kHTTPLoadWidth = 0, kHTTPNumFastLanes = 4 };
extern int _CFNetworkHTTPConnectionCacheGetLimit(int key);
extern void _CFNetworkHTTPConnectionCacheSetLimit(int key, int value);

extern NSString * const NSURLAuthenticationMethodOAuth;

@interface NSURLRequest (Private)
- (CFURLRequestRef)_CFURLRequest;
@end

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); failures++; } else printf("PASS: %s\n", what); } while (0)

int main(void)
{
    @autoreleasepool
    {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.org/form"]];
        [request setHTTPMethod:@"POST"];
        CFMutableURLRequestRef cfRequest = (CFMutableURLRequestRef)[request _CFURLRequest];

        NSData *body = [@"a=1&b=2" dataUsingEncoding:NSUTF8StringEncoding];
        CFURLRequestSetHTTPRequestBody(cfRequest, (CFDataRef)body);
        CHECK([[request HTTPBody] isEqualToData:body], "the body set through the SPI is the request's HTTPBody");
        CHECK([request HTTPBodyStream] == nil, "a request with a body has no body stream");

        NSInputStream *stream = [NSInputStream inputStreamWithData:body];
        CFURLRequestSetHTTPRequestBodyStream(cfRequest, (CFReadStreamRef)stream);
        CHECK([request HTTPBodyStream] == stream, "the stream set through the SPI is the request's HTTPBodyStream");
        CHECK([request HTTPBody] == nil, "setting a body stream discards the body");

        CFURLRequestSetHTTPRequestBody(cfRequest, (CFDataRef)body);
        CHECK([request HTTPBody] != nil && [request HTTPBodyStream] == nil, "setting a body discards the body stream");

        CFURLRequestSetHTTPRequestBody(cfRequest, NULL);
        CHECK([request HTTPBody] == nil, "a NULL body removes the body");

        CFURLRequestSetHTTPRequestBodyStream(cfRequest, (CFReadStreamRef)stream);
        CFURLRequestSetHTTPRequestBodyStream(cfRequest, NULL);
        CHECK([request HTTPBodyStream] == nil, "a NULL body stream removes the stream");

        // The same rule holds for the public setters, which share the storage.
        [request setHTTPBodyStream:stream];
        [request setHTTPBody:body];
        CHECK([request HTTPBodyStream] == nil, "-setHTTPBody: discards the body stream");
        [request setHTTPBodyStream:stream];
        CHECK([request HTTPBody] == nil, "-setHTTPBodyStream: discards the body");

        _CFNetworkHTTPConnectionCacheSetLimit(kHTTPLoadWidth, 6);
        CHECK(_CFNetworkHTTPConnectionCacheGetLimit(kHTTPLoadWidth) == 6, "a connection cache limit reads back as set");
        _CFNetworkHTTPConnectionCacheSetLimit(kHTTPNumFastLanes, 1);
        CHECK(_CFNetworkHTTPConnectionCacheGetLimit(kHTTPNumFastLanes) == 1
              && _CFNetworkHTTPConnectionCacheGetLimit(kHTTPLoadWidth) == 6, "each key keeps its own limit");

        CHECK(NSURLAuthenticationMethodOAuth != nil
              && ![NSURLAuthenticationMethodOAuth isEqualToString:NSURLAuthenticationMethodDefault]
              && ![NSURLAuthenticationMethodOAuth isEqualToString:NSURLAuthenticationMethodHTTPDigest]
              && ![NSURLAuthenticationMethodOAuth isEqualToString:NSURLAuthenticationMethodServerTrust],
              "NSURLAuthenticationMethodOAuth is a method of its own");
    }
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

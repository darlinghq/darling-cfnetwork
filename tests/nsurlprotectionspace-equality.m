#import <Foundation/Foundation.h>

// NSURLProtectionSpace equality and hash sit on CFURLProtectionSpace: two spaces made from the same host, port,
// protocol, realm and authentication method are equal and hash alike; changing any one of them breaks equality.
// Which fields isEqual compares is not documented (the NSURLProtectionSpace overview names host, port, protocol and
// realm as what a credential is matched on), so the authentication method is included on a GUESS. Known gap, not
// tested: a protocol the server types do not cover ("smtp") is stored as HTTP.

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

static NSURLProtectionSpace *make(NSString *host, NSInteger port, NSString *protocol, NSString *realm, NSString *method)
{
    return [[[NSURLProtectionSpace alloc] initWithHost:host port:port protocol:protocol realm:realm authenticationMethod:method] autorelease];
}

int main(void)
{
    @autoreleasepool
    {
        NSURLProtectionSpace *base = make(@"example.test", 443, NSURLProtectionSpaceHTTPS, @"realm", NSURLAuthenticationMethodHTTPBasic);
        NSURLProtectionSpace *same = make(@"example.test", 443, NSURLProtectionSpaceHTTPS, @"realm", NSURLAuthenticationMethodHTTPBasic);
        expect(base != same, @"separate objects");
        expect([base isEqual:same] && [same isEqual:base], @"equal spaces are equal both ways");
        expect([base hash] == [same hash], @"equal spaces hash alike");
        expect([base isEqual:base], @"a space equals itself");

        expect(![base isEqual:make(@"other.test", 443, NSURLProtectionSpaceHTTPS, @"realm", NSURLAuthenticationMethodHTTPBasic)], @"host");
        expect(![base isEqual:make(@"example.test", 8443, NSURLProtectionSpaceHTTPS, @"realm", NSURLAuthenticationMethodHTTPBasic)], @"port");
        expect(![base isEqual:make(@"example.test", 443, NSURLProtectionSpaceHTTP, @"realm", NSURLAuthenticationMethodHTTPBasic)], @"protocol");
        expect(![base isEqual:make(@"example.test", 443, NSURLProtectionSpaceHTTPS, @"other", NSURLAuthenticationMethodHTTPBasic)], @"realm");
        expect(![base isEqual:make(@"example.test", 443, NSURLProtectionSpaceHTTPS, @"realm", NSURLAuthenticationMethodHTTPDigest)], @"authentication method (GUESS)");
        expect(![base isEqual:nil] && ![base isEqual:@"example.test"], @"not equal to nil or another class");

        // The proxy type strings equal the server protocol strings, but a proxy space is a different space from an origin
        // server space with the same host, port, realm and method, and is told so by isProxy.
        NSURLProtectionSpace *server = make(@"proxy.example.test", 80, NSURLProtectionSpaceHTTP, @"realm", NSURLAuthenticationMethodHTTPBasic);
        NSURLProtectionSpace *proxy = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"proxy.example.test" port:80 type:NSURLProtectionSpaceHTTPProxy realm:@"realm"
                                                                  authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        expect([proxy isProxy] && ![server isProxy], @"isProxy tells the two apart");
        expect([[proxy proxyType] isEqualToString:NSURLProtectionSpaceHTTPProxy] && [server proxyType] == nil, @"proxyType");
        expect([[proxy protocol] isEqualToString:NSURLProtectionSpaceHTTP] && [[server protocol] isEqualToString:NSURLProtectionSpaceHTTP], @"protocol of a proxy space (observed on macOS)");
        expect(![proxy isEqual:server] && ![server isEqual:proxy], @"a proxy space is not the origin server space");
        NSURLProtectionSpace *proxy2 = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"proxy.example.test" port:80 type:NSURLProtectionSpaceHTTPProxy realm:@"realm"
                                                                   authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        expect([proxy isEqual:proxy2] && [proxy hash] == [proxy2 hash], @"equal proxy spaces");
        NSURLProtectionSpace *socks = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"proxy.example.test" port:80 type:NSURLProtectionSpaceSOCKSProxy realm:@"realm"
                                                                  authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        expect(![proxy isEqual:socks], @"proxy types differ");
        NSURLProtectionSpace *httpsProxy = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"proxy.example.test" port:80 type:NSURLProtectionSpaceHTTPSProxy realm:@"realm"
                                                                       authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        expect(![proxy isEqual:httpsProxy], @"HTTP and HTTPS proxies differ");
        expect([[socks proxyType] isEqualToString:NSURLProtectionSpaceSOCKSProxy] && [[socks protocol] isEqualToString:NSURLProtectionSpaceSOCKSProxy], @"SOCKS proxy type");
        // SOCKS is only a proxy type: asking for it as a server protocol does not make a proxy space.
        NSURLProtectionSpace *socksServer = make(@"proxy.example.test", 80, NSURLProtectionSpaceSOCKSProxy, @"realm", NSURLAuthenticationMethodHTTPBasic);
        expect(![socksServer isProxy] && ![socksServer isEqual:socks], @"a server space is never a proxy space");

        // A nil realm matches a nil realm only.
        NSURLProtectionSpace *noRealm = make(@"example.test", 80, NSURLProtectionSpaceHTTP, nil, NSURLAuthenticationMethodDefault);
        expect([noRealm isEqual:make(@"example.test", 80, NSURLProtectionSpaceHTTP, nil, NSURLAuthenticationMethodDefault)], @"nil realms are equal");
        expect(![noRealm isEqual:make(@"example.test", 80, NSURLProtectionSpaceHTTP, @"r", NSURLAuthenticationMethodDefault)], @"nil realm differs from a realm");

        // Usable as a dictionary key, which is what NSURLCredentialStorage does.
        NSDictionary *byKey = [NSDictionary dictionaryWithObject:@"found" forKey:base];
        expect([[byKey objectForKey:same] isEqualToString:@"found"], @"lookup by an equal space");
        expect([byKey objectForKey:make(@"other.test", 443, NSURLProtectionSpaceHTTPS, @"realm", NSURLAuthenticationMethodHTTPBasic)] == nil, @"no match for another space");
    }

    if (failures == 0)
        NSLog(@"PASS: nsurlprotectionspace-equality");
    return failures == 0 ? 0 : 1;
}

// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: the NSURLSessionConfiguration SPI properties that WebKit's
// network process sets. Observed on macOS 26.7.3 (x86_64) with the same calls:
// - default and ephemeral configurations start with nil, NO and 0, except
//   _connectionCacheNumPriorityLevels (4) and
//   _connectionCacheMinimumFastLanePriority (1);
// - values set are kept (objects copied), and copies and a session's
//   configuration keep them;
// - quirk: a copy drops _skipsStackTraceCapture;
// - quirk: _sourceApplicationAuditTokenData keeps only 32 bytes of data (an
//   audit_token_t); data of another length clears it.
#import <Foundation/Foundation.h>

@interface NSURLSessionConfiguration (SPI)
@property (assign) int64_t _timingDataOptions;
@property (copy) NSData *_sourceApplicationAuditTokenData;
@property (copy) NSString *_sourceApplicationBundleIdentifier;
@property (copy) NSString *_sourceApplicationSecondaryIdentifier;
@property BOOL _shouldSkipPreferredClientCertificateLookup;
@property BOOL _preventsSystemHTTPProxyAuthentication;
@property BOOL _requiresSecureHTTPSProxyConnection;
@property (copy) NSSet *_suppressedAutoAddedHTTPHeaders;
@property BOOL _usesNWLoader;
@property NSInteger _connectionCacheNumPriorityLevels;
@property NSInteger _connectionCacheNumFastLanes;
@property NSInteger _connectionCacheMinimumFastLanePriority;
@property (copy) NSString *_attributedBundleIdentifier;
@property (copy) NSDictionary *_socketStreamProperties;
@property BOOL _allowsHSTSWithUntrustedRootCertificate;
@property BOOL _skipsStackTraceCapture;
@end

static int failures;

static void report(NSString *name, BOOL ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name.UTF8String);
    if (!ok)
        failures++;
}

static BOOL hasDefaults(NSURLSessionConfiguration *c)
{
    return c._timingDataOptions == 0 && c._sourceApplicationAuditTokenData == nil
        && c._sourceApplicationBundleIdentifier == nil && c._sourceApplicationSecondaryIdentifier == nil
        && !c._shouldSkipPreferredClientCertificateLookup && !c._preventsSystemHTTPProxyAuthentication
        && !c._requiresSecureHTTPSProxyConnection && c._suppressedAutoAddedHTTPHeaders == nil && !c._usesNWLoader
        && c._connectionCacheNumPriorityLevels == 4 && c._connectionCacheNumFastLanes == 0
        && c._connectionCacheMinimumFastLanePriority == 1 && c._attributedBundleIdentifier == nil
        && c._socketStreamProperties == nil && !c._allowsHSTSWithUntrustedRootCertificate && !c._skipsStackTraceCapture;
}

static NSData *token;

static BOOL keepsValues(NSURLSessionConfiguration *c)
{
    return c._timingDataOptions == 1 && [c._sourceApplicationAuditTokenData isEqual: token]
        && [c._sourceApplicationBundleIdentifier isEqual: @"com.example.app"]
        && [c._sourceApplicationSecondaryIdentifier isEqual: @"second"]
        && c._shouldSkipPreferredClientCertificateLookup && c._preventsSystemHTTPProxyAuthentication
        && c._requiresSecureHTTPSProxyConnection && [c._suppressedAutoAddedHTTPHeaders isEqual: [NSSet setWithObject: @"Content-Type"]]
        && c._usesNWLoader && c._connectionCacheNumPriorityLevels == 5 && c._connectionCacheNumFastLanes == 1
        && c._connectionCacheMinimumFastLanePriority == 2 && [c._attributedBundleIdentifier isEqual: @"attr"]
        && [c._socketStreamProperties isEqual: @{ @"k": @NO }] && c._allowsHSTSWithUntrustedRootCertificate;
}

int main(void)
{
    @autoreleasepool {
        unsigned char raw[64];
        for (int i = 0; i < 64; i++)
            raw[i] = i + 1;
        token = [NSData dataWithBytes: raw length: 32];

        report(@"defaults: default configuration", hasDefaults([NSURLSessionConfiguration defaultSessionConfiguration]));
        report(@"defaults: ephemeral configuration", hasDefaults([NSURLSessionConfiguration ephemeralSessionConfiguration]));

        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSMutableString *bundleIdentifier = [NSMutableString stringWithString: @"com.example.app"];
        c._timingDataOptions = 1;
        c._sourceApplicationAuditTokenData = token;
        c._sourceApplicationBundleIdentifier = bundleIdentifier;
        c._sourceApplicationSecondaryIdentifier = @"second";
        c._shouldSkipPreferredClientCertificateLookup = YES;
        c._preventsSystemHTTPProxyAuthentication = YES;
        c._requiresSecureHTTPSProxyConnection = YES;
        c._suppressedAutoAddedHTTPHeaders = [NSSet setWithObject: @"Content-Type"];
        c._usesNWLoader = YES;
        c._connectionCacheNumPriorityLevels = 5;
        c._connectionCacheNumFastLanes = 1;
        c._connectionCacheMinimumFastLanePriority = 2;
        c._attributedBundleIdentifier = @"attr";
        c._socketStreamProperties = @{ @"k": @NO };
        c._allowsHSTSWithUntrustedRootCertificate = YES;
        c._skipsStackTraceCapture = YES;
        [bundleIdentifier appendString: @".changed"];

        report(@"set values are kept, objects copied", keepsValues(c) && c._skipsStackTraceCapture);
        NSURLSessionConfiguration *copy = [[c copy] autorelease];
        report(@"a copy keeps them", keepsValues(copy));
        report(@"quirk: copy drops _skipsStackTraceCapture", !copy._skipsStackTraceCapture);
        report(@"a session's configuration keeps them", keepsValues([NSURLSession sessionWithConfiguration: c].configuration));

        c._sourceApplicationBundleIdentifier = nil;
        report(@"nil clears a string", c._sourceApplicationBundleIdentifier == nil);

        BOOL othersDropped = YES;
        for (int length = 0; length <= 64; length += 4) {
            NSURLSessionConfiguration *t = [NSURLSessionConfiguration defaultSessionConfiguration];
            t._sourceApplicationAuditTokenData = [NSData dataWithBytes: raw length: length];
            if (length == 32 ? t._sourceApplicationAuditTokenData.length != 32 : t._sourceApplicationAuditTokenData != nil)
                othersDropped = NO;
        }
        report(@"quirk: audit token data of another length is dropped", othersDropped);
        c._sourceApplicationAuditTokenData = [NSData dataWithBytes: raw length: 4];
        report(@"quirk: and clears a token set before", c._sourceApplicationAuditTokenData == nil);
    }
    return failures != 0;
}

// Private NSURLRequest settings that WebKit's ResourceRequest reads and
// writes. Observed on macOS 26.7.3 (x86_64) with the same calls:
// - each flag is NO until set; NSURLRequest has the getters and
//   NSMutableURLRequest the setters; the flags survive copy, mutableCopy and
//   keyed archiving; all but the three HSTS ones make two requests unequal;
// - the Content-Disposition encoding fallback array is nil until set, holds
//   NSStringEncodings, and is copied with the request; an NSStringEncoding
//   that has no CFStringEncoding comes back as kCFStringEncodingInvalidId;
// - -_propertyForKey: and -_setProperty:forKey: use the same storage as
//   NSURLProtocol's properties, work on an immutable request too (as does
//   _CFURLRequestSetProtocolProperty), and a nil value removes a property;
// - equality: requests with the same settings are equal, mutable or not, and
//   hash alike; the URL, cache policy, method, header fields (by name, in any
//   case), main document URL, cookie handling, network access settings and
//   protocol properties count; the body data, timeout, network service type
//   and pipelining don't.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>

@interface NSURLRequest (PrivateSettings)
- (id)_propertyForKey:(NSString *)key;
- (void)_setProperty:(id)value forKey:(NSString *)key;
- (void)_removePropertyForKey:(NSString *)key;
- (NSArray *)contentDispositionEncodingFallbackArray;
@end

@interface NSMutableURLRequest (PrivateSettings)
- (void)setContentDispositionEncodingFallbackArray:(NSArray *)encodings;
@end

typedef const struct _CFURLRequest *CFURLRequestRef;
extern CFURLRequestRef CFURLRequestCreate(CFAllocatorRef, CFURLRef, int, CFTimeInterval);
extern void _CFURLRequestSetProtocolProperty(CFURLRequestRef, CFStringRef, CFTypeRef);
extern CFTypeRef _CFURLRequestCopyProtocolPropertyForKey(CFURLRequestRef, CFStringRef);

static int failures;

static void report(const char *name, BOOL ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok)
        failures++;
}

static BOOL getFlag(NSURLRequest *request, NSString *getter)
{
    return ((BOOL (*)(id, SEL))objc_msgSend)(request, NSSelectorFromString(getter));
}

static void setFlag(NSMutableURLRequest *request, NSString *setter, BOOL value)
{
    ((void (*)(id, SEL, BOOL))objc_msgSend)(request, NSSelectorFromString(setter), value);
}

int main(void)
{
    @autoreleasepool {
        NSArray *flags = @[
            @[ @"_ignoreHSTS", @"_setIgnoreHSTS:" ],
            @[ @"_preventHSTSStorage", @"_setPreventHSTSStorage:" ],
            @[ @"_schemeWasUpgradedDueToDynamicHSTS", @"_setSchemeWasUpgradedDueToDynamicHSTS:" ],
            @[ @"_privacyProxyFailClosed", @"_setPrivacyProxyFailClosed:" ],
            @[ @"_useEnhancedPrivacyMode", @"_setUseEnhancedPrivacyMode:" ],
            @[ @"_privacyProxyFailClosedForUnreachableNonMainHosts", @"_setPrivacyProxyFailClosedForUnreachableNonMainHosts:" ],
            @[ @"_privacyProxyFailClosedForUnreachableHosts", @"_setPrivacyProxyFailClosedForUnreachableHosts:" ],
            @[ @"_needsNetworkTrackingPrevention", @"_setNeedsNetworkTrackingPrevention:" ],
            @[ @"_prohibitPrivacyProxy", @"_setProhibitPrivacyProxy:" ],
            @[ @"_blockTrackers", @"_setBlockTrackers:" ],
            @[ @"_allowPrivateAccessTokensForThirdParty", @"_setAllowPrivateAccessTokensForThirdParty:" ],
            @[ @"_isWebSearchContent", @"_setWebSearchContent:" ],
        ];
        NSURL *url = [NSURL URLWithString:@"https://example.com/"];
        NSMutableURLRequest *plain = [NSMutableURLRequest requestWithURL:url];

        for (NSArray *flag in flags) {
            NSString *getter = flag[0], *setter = flag[1];
            const char *name = getter.UTF8String;
            char label[160];

            snprintf(label, sizeof(label), "%s is on NSURLRequest, its setter on NSMutableURLRequest", name);
            report(label, class_getInstanceMethod([NSURLRequest class], NSSelectorFromString(getter)) != NULL &&
                          class_getInstanceMethod([NSURLRequest class], NSSelectorFromString(setter)) == NULL &&
                          class_getInstanceMethod([NSMutableURLRequest class], NSSelectorFromString(setter)) != NULL);

            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            snprintf(label, sizeof(label), "%s is NO by default", name);
            report(label, !getFlag(request, getter));
            setFlag(request, setter, YES);
            NSURLRequest *copy = [[request copy] autorelease];
            NSMutableURLRequest *mutableCopy = [[copy mutableCopy] autorelease];
            NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:request requiringSecureCoding:YES error:NULL];
            NSURLRequest *unarchived = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSURLRequest class] fromData:archive error:NULL];
            snprintf(label, sizeof(label), "%s is set, copied and archived", name);
            report(label, getFlag(request, getter) && getFlag(copy, getter) && getFlag(mutableCopy, getter) && getFlag(unarchived, getter));
            BOOL hsts = [getter rangeOfString:@"HSTS"].location != NSNotFound;
            snprintf(label, sizeof(label), hsts ? "%s doesn't affect equality" : "%s affects equality", name);
            report(label, [request isEqual:plain] == hsts);
            setFlag(request, setter, NO);
            snprintf(label, sizeof(label), "%s can be cleared", name);
            report(label, !getFlag(request, getter));
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        report("no encoding fallback array by default", [request contentDispositionEncodingFallbackArray] == nil);
        NSArray *encodings = @[ @(NSWindowsCP1252StringEncoding), @(NSMacOSRomanStringEncoding) ];
        [request setContentDispositionEncodingFallbackArray:encodings];
        report("encoding fallback array is kept", [[request contentDispositionEncodingFallbackArray] isEqual:encodings]);
        report("encoding fallback array is copied with the request",
               [[[[request copy] autorelease] contentDispositionEncodingFallbackArray] isEqual:encodings]);
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:request requiringSecureCoding:YES error:NULL];
        report("encoding fallback array is archived",
               [[[NSKeyedUnarchiver unarchivedObjectOfClass:[NSURLRequest class] fromData:archive error:NULL]
                   contentDispositionEncodingFallbackArray] isEqual:encodings]);
        [request setContentDispositionEncodingFallbackArray:@[ @(kCFStringEncodingWindowsLatin1) ]];
        report("an NSStringEncoding without a CFStringEncoding",
               [[request contentDispositionEncodingFallbackArray] isEqual:@[ @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingInvalidId)) ]]);

        [request _setProperty:@"value" forKey:@"key"];
        report("property is kept", [[request _propertyForKey:@"key"] isEqual:@"value"]);
        report("NSURLProtocol sees the property", [[NSURLProtocol propertyForKey:@"key" inRequest:request] isEqual:@"value"]);
        report("property is copied", [[[[request copy] autorelease] _propertyForKey:@"key"] isEqual:@"value"]);
        NSMutableURLRequest *viaProtocol = [NSMutableURLRequest requestWithURL:url];
        [NSURLProtocol setProperty:@"other" forKey:@"protocolKey" inRequest:viaProtocol];
        report("NSURLProtocol's property is seen", [[viaProtocol _propertyForKey:@"protocolKey"] isEqual:@"other"]);
        [request _setProperty:nil forKey:@"key"];
        report("nil removes a property", [request _propertyForKey:@"key"] == nil);
        [request _setProperty:@"value" forKey:@"key"];
        [request _removePropertyForKey:@"key"];
        report("_removePropertyForKey: removes it", [request _propertyForKey:@"key"] == nil);

        NSMutableURLRequest *base = [NSMutableURLRequest requestWithURL:url];
        NSMutableURLRequest *same = [NSMutableURLRequest requestWithURL:url];
        report("same settings are equal", [base isEqual:same] && [base hash] == [same hash]);
        report("mutable and immutable are equal", [[NSURLRequest requestWithURL:url] isEqual:base]);
        report("not equal to another class", ![base isEqual:@"https://example.com/"]);
#define DIFFERS(label, change, equal)                                       \
        {                                                                   \
            NSMutableURLRequest *other = [NSMutableURLRequest requestWithURL:url]; \
            change;                                                         \
            report(label, [base isEqual:other] == (equal));                 \
        }
        DIFFERS("URL counts", other.URL = [NSURL URLWithString:@"https://example.com/other"], NO)
        DIFFERS("cache policy counts", other.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData, NO)
        DIFFERS("method counts", other.HTTPMethod = @"POST", NO)
        DIFFERS("header fields count", [other setValue:@"v" forHTTPHeaderField:@"X-Test"], NO)
        DIFFERS("main document URL counts", other.mainDocumentURL = url, NO)
        DIFFERS("cookie handling counts", other.HTTPShouldHandleCookies = NO, NO)
        DIFFERS("cellular access counts", other.allowsCellularAccess = NO, NO)
        DIFFERS("expensive network access counts", other.allowsExpensiveNetworkAccess = NO, NO)
        DIFFERS("constrained network access counts", other.allowsConstrainedNetworkAccess = NO, NO)
        DIFFERS("properties count", [NSURLProtocol setProperty:@"v" forKey:@"k" inRequest:other], NO)
        DIFFERS("body data doesn't count", other.HTTPBody = [NSData dataWithBytes:"body" length:4], YES)
        DIFFERS("timeout doesn't count", other.timeoutInterval = 5, YES)
        DIFFERS("network service type doesn't count", other.networkServiceType = NSURLNetworkServiceTypeVoIP, YES)
        DIFFERS("pipelining doesn't count", other.HTTPShouldUsePipelining = YES, YES)
        [base setValue:@"v" forHTTPHeaderField:@"x-test"];
        DIFFERS("header field names are case-insensitive", [other setValue:@"v" forHTTPHeaderField:@"X-Test"], YES)

        NSURLRequest *immutable = [NSURLRequest requestWithURL:url];
        [immutable _setProperty:@"value" forKey:@"key"];
        report("an immutable request takes a property", [[immutable _propertyForKey:@"key"] isEqual:@"value"]);

        CFURLRequestRef cfRequest = CFURLRequestCreate(NULL, (CFURLRef)url, 0, 60);
        _CFURLRequestSetProtocolProperty(cfRequest, CFSTR("key"), CFSTR("value"));
        CFTypeRef value = _CFURLRequestCopyProtocolPropertyForKey(cfRequest, CFSTR("key"));
        report("an immutable CFURLRequest takes a property", value != NULL && CFEqual(value, CFSTR("value")));
        if (value)
            CFRelease(value);
        CFRelease(cfRequest);
    }
    return failures != 0;
}

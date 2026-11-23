//
//  NSURLProtectionSpace.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import "NSURLProtectionSpaceInternal.h"
#import <Foundation/NSCoder.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSException.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>
#import <CFNetwork/CFURLProtectionSpace.h>


@class NSURLProtectionSpaceInternal;

// The public header says only <NSCoding, NSCopying>, and NSKeyedArchiver refuses to archive under secure coding an
// object whose class does not conform to NSSecureCoding.
@interface NSURLProtectionSpace () <NSSecureCoding>
@end

static NSString * const ProtectionSpaceSecureKey = @"__nsurlprotectionspace_proto_plist";

@implementation NSURLProtectionSpace

static CFURLProtectionSpaceServerType protocolToCFServerType(NSString * const protocol)
{
    if ([protocol isEqualToString:NSURLProtectionSpaceHTTP])
    {
        return kCFURLProtectionSpaceServerHTTP;
    }
    else if ([protocol isEqualToString:NSURLProtectionSpaceHTTPS])
    {
        return kCFURLProtectionSpaceServerHTTPS;
    }
    else if ([protocol isEqualToString:NSURLProtectionSpaceFTP])
    {
        return kCFURLProtectionSpaceServerFTP;
    }
    else
    {
        // The proxy type constants are for initWithProxyHost: (SOCKS is only a proxy type, and the others equal
        // the server strings), so a server space never becomes a proxy space here. A protocol with no server
        // type is stored as HTTP (known gap).
        return kCFURLProtectionSpaceServerHTTP;
    }
}

// The proxy type strings are the same as the server protocol strings (NSURLProtectionSpaceHTTPProxy is "http"),
// so a proxy space is told from a server space by how it was created, not by the string.
static CFURLProtectionSpaceServerType proxyTypeToCFServerType(NSString * const type)
{
    if ([type isEqualToString:NSURLProtectionSpaceHTTPSProxy])
    {
        return kCFURLProtectionSpaceProxyHTTPS;
    }
    else if ([type isEqualToString:NSURLProtectionSpaceFTPProxy])
    {
        return kCFURLProtectionSpaceProxyFTP;
    }
    else if ([type isEqualToString:NSURLProtectionSpaceSOCKSProxy])
    {
        return kCFURLProtectionSpaceProxySOCKS;
    }
    else
    {
        // GUESS: an unknown proxy type is an HTTP proxy, as an unknown protocol is HTTP for a server space.
        return kCFURLProtectionSpaceProxyHTTP;
    }
}

static CFURLProtectionSpaceAuthenticationSchemeType methodToCFAuthScheme(NSString * const method)
{
    if ([method isEqualToString:NSURLAuthenticationMethodDefault])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeDefault;
    }
    else if ([method isEqualToString:NSURLAuthenticationMethodHTTPBasic])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeHTTPBasic;
    }
    else if ([method isEqualToString:NSURLAuthenticationMethodHTTPDigest])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeHTTPDigest;
    }
    else if ([method isEqualToString:NSURLAuthenticationMethodHTMLForm])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeHTMLForm;
    }
    else if ([method isEqualToString:NSURLAuthenticationMethodNTLM])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeNTLM;
    }
    else if ([method isEqualToString:NSURLAuthenticationMethodNegotiate])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeNegotiate;
    }
    else if ([method isEqualToString:NSURLAuthenticationMethodServerTrust])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeServerTrustEvaluationRequested;
    }
    else if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate])
    {
        return kCFURLProtectionSpaceAuthenticationSchemeClientCertificateRequested;
    }
    else
    {
        return kCFURLProtectionSpaceAuthenticationSchemeDefault;
    }
}

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)init
{
    [self release];
    return nil;
}

- (id)_internalInit
{
    self = [super init];
    if (self != nil)
    {
        _internal = nil;
    }
    return self;
}

- (id)_initWithCFURLProtectionSpace:(CFURLProtectionSpaceRef)protectionSpace
{
    self = [self _internalInit];
    if (self != nil)
    {
        CFRetain(protectionSpace);
        _internal = (NSURLProtectionSpaceInternal *)protectionSpace;
    }
    return self;
}

- (id)initWithHost:(NSString *)host port:(NSInteger)port protocol:(NSString *)protocol realm:(NSString *)realm authenticationMethod:(NSString *)authenticationMethod
{
    self = [self _internalInit];
    if (self != nil)
    {
        CFURLProtectionSpaceServerType serverType = protocolToCFServerType(protocol);
        CFURLProtectionSpaceAuthenticationSchemeType scheme = methodToCFAuthScheme(authenticationMethod);
        _internal = (NSURLProtectionSpaceInternal *)CFURLProtectionSpaceCreate(kCFAllocatorDefault, (CFStringRef)host, port, serverType, (CFStringRef)realm, scheme);
    }
    return self;
}

- (id)initWithProxyHost:(NSString *)host port:(NSInteger)port type:(NSString *)type realm:(NSString *)realm authenticationMethod:(NSString *)authenticationMethod
{
    self = [self _internalInit];
    if (self != nil)
    {
        CFURLProtectionSpaceAuthenticationSchemeType scheme = methodToCFAuthScheme(authenticationMethod);
        // QUIRK: a proxy space has no realm: -realm answers nil whatever realm the initializer was given, and the
        // realm is not archived. Evidence (tier 2): identical on macOS 26.7.3 and 10.14.4 (x86_64), black-box
        // observation through the public API. Test: tests/nsurlprotectionspace-secure-coding.m
        // (test_quirk_proxy_space_has_no_realm).
        _internal = (NSURLProtectionSpaceInternal *)CFURLProtectionSpaceCreate(kCFAllocatorDefault, (CFStringRef)host, port, proxyTypeToCFServerType(type), NULL, scheme);
    }
    return self;
}

// QUIRK: the archive layout of a protection space is the one written by macOS: one dictionary, archived with an
// unkeyed encodeObject: (the slot "$0" of the archive entry) or, when the archiver requires secure coding, under the
// key "__nsurlprotectionspace_proto_plist". Its entries are _kind ("protection_space"), _version (3), host (left
// out when nil), port, type, scheme and realm (left out when nil). type counts server types as 1 HTTP, 2 HTTPS,
// 3 FTP, 5 HTTP proxy, 6 HTTPS proxy, 7 FTP proxy, 8 SOCKS proxy (4 is not used by any space made through the
// public initializers); scheme counts authentication methods as 1 default, 2 HTTP basic, 3 HTTP digest, 4 HTML
// form, 5 NTLM, 6 negotiate, 7 client certificate, 8 server trust. The numbers differ from this implementation's CF
// enumerations, so they are mapped. Evidence (tier 2, black-box observation of the archives written through the
// public API): identical on macOS 26.7.3 and 10.14.4 (x86_64). The distinguished names and the server trust are not
// archived (the documented creating methods do not take them). Archives written here decode on both and the other
// way round. Test: tests/nsurlprotectionspace-secure-coding.m (test_quirk_archive_layout and
// test_quirk_decode_archive_written_by_macos).
static NSString * const ProtectionSpaceKind = @"protection_space";


static NSInteger archivedServerType(CFURLProtectionSpaceServerType type)
{
    switch ((UInt32)type)
    {
        case kCFURLProtectionSpaceServerHTTP: return 1;
        case kCFURLProtectionSpaceServerHTTPS: return 2;
        case kCFURLProtectionSpaceServerFTP: return 3;
        case kCFURLProtectionSpaceProxyHTTP: return 5;
        case kCFURLProtectionSpaceProxyHTTPS: return 6;
        case kCFURLProtectionSpaceProxyFTP: return 7;
        default: return 8;
    }
}

static BOOL serverTypeFromArchive(NSInteger value, CFURLProtectionSpaceServerType *type)
{
    switch (value)
    {
        case 1: *type = kCFURLProtectionSpaceServerHTTP; return YES;
        case 2: *type = kCFURLProtectionSpaceServerHTTPS; return YES;
        case 3: *type = kCFURLProtectionSpaceServerFTP; return YES;
        case 5: *type = kCFURLProtectionSpaceProxyHTTP; return YES;
        case 6: *type = kCFURLProtectionSpaceProxyHTTPS; return YES;
        case 7: *type = kCFURLProtectionSpaceProxyFTP; return YES;
        case 8: *type = kCFURLProtectionSpaceProxySOCKS; return YES;
        default: return NO;
    }
}

static NSInteger archivedScheme(CFURLProtectionSpaceAuthenticationSchemeType scheme)
{
    switch ((UInt32)scheme)
    {
        case kCFURLProtectionSpaceAuthenticationSchemeDefault: return 1;
        case kCFURLProtectionSpaceAuthenticationSchemeHTTPBasic: return 2;
        case kCFURLProtectionSpaceAuthenticationSchemeHTTPDigest: return 3;
        case kCFURLProtectionSpaceAuthenticationSchemeHTMLForm: return 4;
        case kCFURLProtectionSpaceAuthenticationSchemeNTLM: return 5;
        case kCFURLProtectionSpaceAuthenticationSchemeNegotiate: return 6;
        case kCFURLProtectionSpaceAuthenticationSchemeClientCertificateRequested: return 7;
        default: return 8;
    }
}

static BOOL schemeFromArchive(NSInteger value, CFURLProtectionSpaceAuthenticationSchemeType *scheme)
{
    switch (value)
    {
        case 1: *scheme = kCFURLProtectionSpaceAuthenticationSchemeDefault; return YES;
        case 2: *scheme = kCFURLProtectionSpaceAuthenticationSchemeHTTPBasic; return YES;
        case 3: *scheme = kCFURLProtectionSpaceAuthenticationSchemeHTTPDigest; return YES;
        case 4: *scheme = kCFURLProtectionSpaceAuthenticationSchemeHTMLForm; return YES;
        case 5: *scheme = kCFURLProtectionSpaceAuthenticationSchemeNTLM; return YES;
        case 6: *scheme = kCFURLProtectionSpaceAuthenticationSchemeNegotiate; return YES;
        case 7: *scheme = kCFURLProtectionSpaceAuthenticationSchemeClientCertificateRequested; return YES;
        case 8: *scheme = kCFURLProtectionSpaceAuthenticationSchemeServerTrustEvaluationRequested; return YES;
        default: return NO;
    }
}

// Decodes are class-checked, so a space can be unarchived with secure coding required, and a value of another class
// or a number outside the table gives nil even without it.
- (id)initWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [self release];
        return nil;
    }
    NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSString class], [NSNumber class], nil];
    NSDictionary *entries = nil;
    if ([coder requiresSecureCoding] || [coder containsValueForKey:ProtectionSpaceSecureKey])
    {
        entries = [coder decodeObjectOfClasses:classes forKey:ProtectionSpaceSecureKey];
    }
    else
    {
        entries = [coder decodeObject];
    }
    id host = [entries objectForKey:@"host"];
    id realm = [entries objectForKey:@"realm"];
    id port = [entries objectForKey:@"port"];
    id type = [entries objectForKey:@"type"];
    id scheme = [entries objectForKey:@"scheme"];
    CFURLProtectionSpaceServerType serverType;
    CFURLProtectionSpaceAuthenticationSchemeType authenticationScheme;
    if (![entries isKindOfClass:[NSDictionary class]] ||
        ![[entries objectForKey:@"_kind"] isEqual:ProtectionSpaceKind] ||
        (host != nil && ![host isKindOfClass:[NSString class]]) ||
        (realm != nil && ![realm isKindOfClass:[NSString class]]) ||
        ![port isKindOfClass:[NSNumber class]] ||
        ![type isKindOfClass:[NSNumber class]] || !serverTypeFromArchive([type integerValue], &serverType) ||
        ![scheme isKindOfClass:[NSNumber class]] || !schemeFromArchive([scheme integerValue], &authenticationScheme))
    {
        [self release];
        return nil;
    }
    self = [self _internalInit];
    if (self != nil)
    {
        _internal = (NSURLProtectionSpaceInternal *)CFURLProtectionSpaceCreate(kCFAllocatorDefault, (CFStringRef)host, [port integerValue], serverType, (CFStringRef)realm, authenticationScheme);
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [NSException raise:NSInvalidArchiveOperationException format:@"NSURLProtectionSpace can only be encoded by a keyed archiver."];
    }
    CFURLProtectionSpaceRef space = (CFURLProtectionSpaceRef)_internal;
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    [entries setObject:ProtectionSpaceKind forKey:@"_kind"];
    [entries setObject:[NSNumber numberWithInt:3] forKey:@"_version"];
    if ([self host] != nil)
    {
        [entries setObject:[self host] forKey:@"host"];
    }
    [entries setObject:[NSNumber numberWithInteger:[self port]] forKey:@"port"];
    [entries setObject:[NSNumber numberWithInteger:archivedServerType(CFURLProtectionSpaceGetServerType(space))] forKey:@"type"];
    [entries setObject:[NSNumber numberWithInteger:archivedScheme(CFURLProtectionSpaceGetAuthenticationScheme(space))] forKey:@"scheme"];
    if ([self realm] != nil)
    {
        [entries setObject:[self realm] forKey:@"realm"];
    }
    if ([coder requiresSecureCoding])
    {
        [coder encodeObject:entries forKey:ProtectionSpaceSecureKey];
    }
    else
    {
        [coder encodeObject:entries];
    }
}

- (void)dealloc
{
    if (_internal != nil)
    {
        CFRelease((CFURLProtectionSpaceRef)_internal);
    }

    [super dealloc];
}

- (BOOL)isEqual:(id)other
{
    if (self == other)
    {
        return YES;
    }

    if (![other isKindOfClass:[NSURLProtectionSpace self]])
    {
        return NO;
    }

    CFURLProtectionSpaceRef otherSpace = (CFURLProtectionSpaceRef)(((NSURLProtectionSpace *)other)->_internal);

    if ((CFURLProtectionSpaceRef)_internal == NULL || otherSpace == NULL)
    {
        return NO;
    }

    return CFEqual((CFURLProtectionSpaceRef)_internal, otherSpace) ? YES : NO;
}

- (NSUInteger)hash
{
    return CFHash((CFURLProtectionSpaceRef)_internal);
}

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

- (NSString *)description
{
    NSString *superDescription = [super description];
    NSString *host = [self host];
    NSString *protocol = [self protocol];
    NSString *realm = [self protocol];
    long port = [self port];
    NSString *isProxy = [self protocol] ? @"yes" : @"no";
    NSString *proxyType = [self protocol];
    NSString *authenticationMethod = [self protocol];

    return [NSString stringWithFormat:@"%@ host:%@ protocol:%@ realm:%@ port:%ld isProxy:%@ proxyType:%@ authenticationMethod:%@",
                     superDescription, host, protocol, realm, port, isProxy, proxyType, authenticationMethod];
}

- (CFURLProtectionSpaceRef)_cfurlprtotectionspace
{
    return (CFURLProtectionSpaceRef)_internal;
}

- (NSString *)realm
{
    CFStringRef cfrealm = CFURLProtectionSpaceGetRealm((CFURLProtectionSpaceRef)_internal);
    return [[(NSString *)cfrealm retain] autorelease];
}

- (BOOL)receivesCredentialSecurely
{
    return CFURLProtectionSpaceReceivesCredentialSecurely((CFURLProtectionSpaceRef)_internal) ? YES : NO;
}

- (BOOL)isProxy
{
    return CFURLProtectionSpaceIsProxy((CFURLProtectionSpaceRef)_internal) ? YES : NO;
}

- (NSString *)host
{
    CFStringRef cfhost = CFURLProtectionSpaceGetHost((CFURLProtectionSpaceRef)_internal);
    return [[(NSString *)cfhost retain] autorelease];
}

- (NSInteger)port
{
    return CFURLProtectionSpaceGetPort((CFURLProtectionSpaceRef)_internal);
}

- (NSString *)proxyType
{
    // nil unless the receiver is a proxy space (documented on URLProtectionSpace.proxyType).
    switch ((UInt32)CFURLProtectionSpaceGetServerType((CFURLProtectionSpaceRef)_internal))
    {
        case kCFURLProtectionSpaceProxyHTTP:
        {
            return NSURLProtectionSpaceHTTPProxy;
        }
        case kCFURLProtectionSpaceProxyHTTPS:
        {
            return NSURLProtectionSpaceHTTPSProxy;
        }
        case kCFURLProtectionSpaceProxyFTP:
        {
            return NSURLProtectionSpaceFTPProxy;
        }
        case kCFURLProtectionSpaceProxySOCKS:
        {
            return NSURLProtectionSpaceSOCKSProxy;
        }
        default:
        {
            return nil;
        }
    }
}

- (NSString *)protocol
{
    // A proxy space reports its proxy type string as the protocol (observed on macOS 26.7.3, tier 2: an HTTP proxy
    // space has protocol "http", a SOCKS one "SOCKS"), although the documentation says it is nil. Test:
    // tests/nsurlprotectionspace-equality.m, "protocol of a proxy space".
    switch ((UInt32)CFURLProtectionSpaceGetServerType((CFURLProtectionSpaceRef)_internal))
    {
        case kCFURLProtectionSpaceServerHTTP:
        {
            return NSURLProtectionSpaceHTTP;
        }
        case kCFURLProtectionSpaceServerHTTPS:
        {
            return NSURLProtectionSpaceHTTPS;
        }
        case kCFURLProtectionSpaceServerFTP:
        {
            return NSURLProtectionSpaceFTP;
        }
        case kCFURLProtectionSpaceProxyHTTP:
        {
            return NSURLProtectionSpaceHTTPProxy;
        }
        case kCFURLProtectionSpaceProxyHTTPS:
        {
            return NSURLProtectionSpaceHTTPSProxy;
        }
        case kCFURLProtectionSpaceProxyFTP:
        {
            return NSURLProtectionSpaceFTPProxy;
        }
        case kCFURLProtectionSpaceProxySOCKS:
        {
            return NSURLProtectionSpaceSOCKSProxy;
        }
        default:
        {
            return NSURLProtectionSpaceHTTP;
        }
    }
}

- (NSString *)authenticationMethod
{
    switch ((UInt32)CFURLProtectionSpaceGetAuthenticationScheme((CFURLProtectionSpaceRef)_internal))
    {
        case kCFURLProtectionSpaceAuthenticationSchemeDefault:
        {
            return NSURLAuthenticationMethodDefault;
        }
        case kCFURLProtectionSpaceAuthenticationSchemeHTTPBasic:
        {
            return NSURLAuthenticationMethodHTTPBasic;
        }
        case kCFURLProtectionSpaceAuthenticationSchemeHTTPDigest:
        {
            return NSURLAuthenticationMethodHTTPDigest;
        }
        case kCFURLProtectionSpaceAuthenticationSchemeHTMLForm:
        {
            return NSURLAuthenticationMethodHTMLForm;
        }
        case kCFURLProtectionSpaceAuthenticationSchemeNTLM:
        {
            return NSURLAuthenticationMethodNTLM;
        }
        case kCFURLProtectionSpaceAuthenticationSchemeNegotiate:
        {
            return NSURLAuthenticationMethodNegotiate;
        }
        case kCFURLProtectionSpaceAuthenticationSchemeServerTrustEvaluationRequested:
        {
            return NSURLAuthenticationMethodServerTrust;
        }
        case kCFURLProtectionSpaceAuthenticationSchemeClientCertificateRequested:
        {
            return NSURLAuthenticationMethodClientCertificate;
        }
        default:
        {
            return NSURLAuthenticationMethodDefault;
        }
    }
}

- (NSArray *)distinguishedNames
{
    return (NSArray *)CFURLProtectionSpaceGetDistinguishedNames((CFURLProtectionSpaceRef)_internal);
}

- (SecTrustRef)serverTrust
{
    return CFURLProtectionSpaceGetServerTrust((CFURLProtectionSpaceRef)_internal);
}

@end

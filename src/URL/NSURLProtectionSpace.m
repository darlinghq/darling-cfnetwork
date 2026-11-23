//
//  NSURLProtectionSpace.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import "NSURLProtectionSpaceInternal.h"
#import <Foundation/NSCoder.h>
#import <Foundation/NSException.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSString.h>
#import <CFNetwork/CFURLProtectionSpace.h>


@class NSURLProtectionSpaceInternal;

// The public header says only <NSCoding, NSCopying>, and NSKeyedArchiver refuses to archive under secure coding an
// object whose class does not conform to NSSecureCoding.
@interface NSURLProtectionSpace () <NSSecureCoding>
@end

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
        _internal = (NSURLProtectionSpaceInternal *)CFURLProtectionSpaceCreate(kCFAllocatorDefault, (CFStringRef)host, port, proxyTypeToCFServerType(type), (CFStringRef)realm, scheme);
    }
    return self;
}

static BOOL decodeOptionalString(NSCoder *coder, NSString *key, NSString **value)
{
    *value = [coder decodeObjectOfClass:[NSString class] forKey:key];
    return ![coder containsValueForKey:key] || [*value isKindOfClass:[NSString class]];
}

// Keyed coding of the host, port, protocol (a proxy space's proxy type string), whether it is a proxy, the realm and
// the authentication method: the properties the documentation lists for creating a protection space. Decodes are
// class-checked, so a space can be unarchived with secure coding required and bad values are refused without it.
// GUESS: the key names are this implementation's own (the documentation does not give an archive layout), as in
// NSURLResponse; only archives written by this implementation are promised to decode.
// GUESS: the distinguished names and the server trust are not archived; a trust cannot be written to an archive,
// and neither is part of what the creating methods take.
- (id)initWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [self release];
        return nil;
    }
    NSString *host = nil;
    NSString *protocol = nil;
    NSString *realm = nil;
    NSString *method = nil;
    // A value that is archived but not a string is refused. Decoding without secure coding does not check the class
    // itself, so the check is made here.
    if (!decodeOptionalString(coder, @"NS.host", &host) ||
        !decodeOptionalString(coder, @"NS.protocol", &protocol) ||
        !decodeOptionalString(coder, @"NS.realm", &realm) ||
        !decodeOptionalString(coder, @"NS.authenticationMethod", &method))
    {
        [self release];
        return nil;
    }
    NSInteger port = (NSInteger)[coder decodeInt64ForKey:@"NS.port"];
    if ([coder decodeBoolForKey:@"NS.isProxy"])
    {
        return [self initWithProxyHost:host port:port type:protocol realm:realm authenticationMethod:method];
    }
    return [self initWithHost:host port:port protocol:protocol realm:realm authenticationMethod:method];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [NSException raise:NSInvalidArchiveOperationException format:@"NSURLProtectionSpace can only be encoded by a keyed archiver."];
    }
    if ([self host] != nil)
    {
        [coder encodeObject:[self host] forKey:@"NS.host"];
    }
    [coder encodeInt64:(int64_t)[self port] forKey:@"NS.port"];
    [coder encodeObject:[self protocol] forKey:@"NS.protocol"];
    [coder encodeBool:[self isProxy] forKey:@"NS.isProxy"];
    if ([self realm] != nil)
    {
        [coder encodeObject:[self realm] forKey:@"NS.realm"];
    }
    [coder encodeObject:[self authenticationMethod] forKey:@"NS.authenticationMethod"];
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

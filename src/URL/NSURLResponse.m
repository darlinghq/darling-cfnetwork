//
//  NSURLResponse.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import "NSURLResponseInternal.h"
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSException.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSNull.h>
#import <Foundation/NSData.h>
#import <Foundation/NSPropertyList.h>
#import <Foundation/NSKeyedArchiver.h>
#include <float.h>

// Keyed coding of NSURLResponse and NSHTTPURLResponse, in the layout that macOS writes (found by reading keyed
// archives written by macOS 26.7.3 and 10.14.4, x86_64 and i386, as property lists; the two agree). The archived
// object has three unkeyed integers (a format number, 0 for a plain response and 1 for an HTTP one, and the number of
// properties), then the properties, each an object (an NSNumber for a number): written in sequence as unkeyed
// objects, or, when the archiver requires secure coding, under the keys __nsurlrequest_proto_prop_obj_<index>. An
// HTTP response ends with two more unkeyed values. A plain response has the properties URL, creation time,
// 0, MIME type, text encoding name, expected content length and DBL_MAX. An HTTP response has URL, creation time, 0,
// status code, header fields, nil and MIME type; the last two are left out (a count of 5) when there is no MIME
// type, and the text encoding and content length are derived from the headers again. The header dictionary has one
// more entry than the header fields, under the key __hhaa__: a binary property list of header name to array of values
// (as a string, in base 64 after four line-break characters). Both Macs read each other's archives, and this reader
// takes both forms of the properties whatever the archiver's secure coding setting.
// Test: tests/nscachedurlresponse-macos-archive.m
static NSString *const ResponseArchivePropertyKeyFormat = @"__nsurlrequest_proto_prop_obj_%d";
static NSString *const ResponseArchiveHeaderOrderKey = @"__hhaa__";
static const int ResponseArchiveFormat = 8;
static const int ResponseArchiveHTTPTrailer = 9;
static const int ResponseArchiveMaxProperties = 16;

static NSString *responseArchivePropertyKey(int index)
{
    return [NSString stringWithFormat:ResponseArchivePropertyKeyFormat, index];
}

// A nil property is archived as nil; properties are NSNull in the array.
static void encodeResponseArchive(NSCoder *coder, BOOL http, NSArray *properties)
{
    int format = ResponseArchiveFormat;
    int httpFlag = http ? 1 : 0;
    int count = (int)[properties count];
    [coder encodeValueOfObjCType:@encode(int) at:&format];
    [coder encodeValueOfObjCType:@encode(int) at:&httpFlag];
    [coder encodeValueOfObjCType:@encode(int) at:&count];
    BOOL keyed = [coder requiresSecureCoding];
    for (int i = 0; i < count; i++)
    {
        id property = [properties objectAtIndex:i];
        if (property == [NSNull null])
        {
            property = nil;
        }
        if (keyed)
        {
            [coder encodeObject:property forKey:responseArchivePropertyKey(i)];
        }
        else
        {
            [coder encodeObject:property];
        }
    }
    if (http)
    {
        int trailer = ResponseArchiveHTTPTrailer;
        [coder encodeValueOfObjCType:@encode(int) at:&trailer];
        // The value after it is a boolean in the archive, not an integer: macOS 26.7.3 and 10.14.4 decode the data and
        // the storage policy of an NSCachedURLResponse around an HTTP response as invalid when it is an integer
        // (observed). NSKeyedArchiver archives a C99 bool as a boolean; a Foundation without that support (before the
        // darling-foundation change that adds it) raises for the type, and an integer is written then.
        bool flag = false;
        @try
        {
            [coder encodeValueOfObjCType:@encode(bool) at:&flag];
        }
        @catch (NSException *exception)
        {
            BOOL integerFlag = NO;
            [coder encodeValueOfObjCType:@encode(BOOL) at:&integerFlag];
        }
    }
}

// Reads the archive written by encodeResponseArchive. classes holds, per property index, the classes that the
// property may have (an NSSet); a property of another class, a wrong format number or an HTTP flag that does not match
// gives NO. The properties come back with NSNull for nil, in an array of the archived count.
static BOOL decodeResponseArchive(NSCoder *coder, BOOL http, NSArray *classes, NSArray **properties)
{
    int format = 0, httpFlag = -1, count = -1;
    // The unkeyed values ($0, $1, ...) cannot be tested with containsValueForKey:, so an archive without them reads
    // as zeros or raises, and either way is not accepted.
    @try
    {
        [coder decodeValueOfObjCType:@encode(int) at:&format size:sizeof(format)];
        [coder decodeValueOfObjCType:@encode(int) at:&httpFlag size:sizeof(httpFlag)];
        [coder decodeValueOfObjCType:@encode(int) at:&count size:sizeof(count)];
    }
    @catch (NSException *exception)
    {
        return NO;
    }
    if (format != ResponseArchiveFormat || httpFlag != (http ? 1 : 0) || count < 0 || count > ResponseArchiveMaxProperties)
    {
        return NO;
    }
    BOOL keyed = NO;
    for (int i = 0; i < count && !keyed; i++)
    {
        keyed = [coder containsValueForKey:responseArchivePropertyKey(i)];
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++)
    {
        NSSet *allowed = i < (int)[classes count] ? [classes objectAtIndex:i] : nil;
        id property = nil;
        if (keyed)
        {
            NSString *key = responseArchivePropertyKey(i);
            if (allowed != nil && [coder containsValueForKey:key])
            {
                property = [coder decodeObjectOfClasses:allowed forKey:key];
            }
        }
        else
        {
            property = [coder decodeObject];
        }
        if (allowed == nil)
        {
            // A property beyond the known ones is read and ignored.
            property = nil;
        }
        else if (property != nil)
        {
            // Without secure coding the unarchiver does not check the classes.
            BOOL matches = NO;
            for (Class cls in allowed)
            {
                matches = matches || [property isKindOfClass:cls];
            }
            if (!matches)
            {
                return NO;
            }
        }
        [result addObject:property ? property : (id)[NSNull null]];
    }
    *properties = result;
    return YES;
}

static id propertyAt(NSArray *properties, NSUInteger index)
{
    if (index >= [properties count])
    {
        return nil;
    }
    id property = [properties objectAtIndex:index];
    return property == [NSNull null] ? nil : property;
}

static NSArray *plainResponseClasses(void)
{
    NSSet *number = [NSSet setWithObject:[NSNumber class]];
    NSSet *string = [NSSet setWithObject:[NSString class]];
    return [NSArray arrayWithObjects:[NSSet setWithObject:[NSURL class]], number, number, string, string, number, number, nil];
}

static NSArray *httpResponseClasses(void)
{
    NSSet *number = [NSSet setWithObject:[NSNumber class]];
    NSSet *string = [NSSet setWithObject:[NSString class]];
    return [NSArray arrayWithObjects:[NSSet setWithObject:[NSURL class]], number, number, number,
        [NSSet setWithObjects:[NSDictionary class], [NSString class], nil], string, string, nil];
}


@implementation NSURLResponseInternal

- (id)initWithURLResponse:(CFURLResponseRef)resp
{
    self = [super init];
    if (self)
    {
        response = (CFURLResponseRef)CFRetain(resp);
    }
    return self;
}

- (void)dealloc
{
    CFRelease(response);
    [super dealloc];
}

@end

@implementation NSURLResponse

+ (id)_responseWithCFURLResponse:(CFURLResponseRef)response
{
    if (response == NULL)
    {
        return nil;
    }
    
    return [[[self alloc] _initWithCFURLResponse:response] autorelease];
}

- (id)init
{
    return [self initWithURL:nil MIMEType:nil expectedContentLength:0 textEncodingName:nil];
}

- (id)initWithURL:(NSURL *)URL MIMEType:(NSString *)MIMEType expectedContentLength:(NSInteger)length textEncodingName:(NSString *)name
{
    // QUIRK: a response made without a MIME type has the type application/octet-stream (the documentation says only
    // that the MIME type of a response may be unknown). Evidence: black-box observation on macOS 26.7.3 and 10.14.4
    // (x86_64, i386), tier 2, with and without a URL and a text encoding name; the same in all of them.
    // Test: test_quirk_nil_mime_type_is_octet_stream in tests/nscachedurlresponse-macos-archive.m
    CFURLResponseRef resp = CFURLResponseCreate(kCFAllocatorDefault, (CFURLRef)URL, MIMEType != nil ? (CFStringRef)MIMEType : CFSTR("application/octet-stream"), length, (CFStringRef)name);
    id response = [self _initWithCFURLResponse:resp];
    CFRelease(resp);
    return response;
}


// Keyed coding of the URL, MIME type, expected content length and text encoding name, in the layout of macOS (see
// encodeResponseArchive). Decodes are class-checked, so a response can be unarchived with secure coding required.
+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)initWithCoder:(NSCoder *)coder
{
    NSArray *properties = nil;
    if (![coder allowsKeyedCoding] || !decodeResponseArchive(coder, NO, plainResponseClasses(), &properties))
    {
        [self release];
        return nil;
    }
    NSNumber *length = propertyAt(properties, 5);
    return [self initWithURL:propertyAt(properties, 0)
                    MIMEType:propertyAt(properties, 3)
       expectedContentLength:(NSInteger)(length != nil ? [length longLongValue] : -1)
            textEncodingName:propertyAt(properties, 4)];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [NSException raise:NSInvalidArchiveOperationException format:@"NSURLResponse can only be encoded by a keyed archiver."];
    }
    NSNull *null = [NSNull null];
    NSArray *properties = [NSArray arrayWithObjects:
        [self URL] ? (id)[self URL] : (id)null,
        [NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]],
        [NSNumber numberWithInt:0],
        [self MIMEType] ? (id)[self MIMEType] : (id)null,
        [self textEncodingName] ? (id)[self textEncodingName] : (id)null,
        [NSNumber numberWithLongLong:[self expectedContentLength]],
        [NSNumber numberWithDouble:DBL_MAX],
        nil];
    encodeResponseArchive(coder, NO, properties);
}

- (id)_initWithCFURLResponse:(CFURLResponseRef)response
{
    self = [super init];
    if (self)
    {
        _internal = [[NSURLResponseInternal alloc] initWithURLResponse:response];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

- (void)dealloc
{
    [_internal release];
    [super dealloc];
}

- (NSString *)suggestedFilename
{
    return [(NSString *)CFURLResponseCopySuggestedFilename([self _CFURLResponse]) autorelease];
}

- (long long)expectedContentLength
{
    return CFURLResponseGetExpectedContentLength([self _CFURLResponse]);
}

- (NSString *)textEncodingName
{
    return (NSString *)CFURLResponseGetTextEncodingName([self _CFURLResponse]);
}

- (NSString *)MIMEType
{
    return (NSString *)CFURLResponseGetMIMEType([self _CFURLResponse]);
}

// SPI: replaces the MIME type and nothing else; the header fields and text
// encoding stay as they are (macOS 26.7.3). Test: nsurlresponse-set-mime-type.m.
- (void)_setMIMEType:(NSString *)MIMEType
{
    CFURLResponseSetMIMEType([self _CFURLResponse], (CFStringRef)MIMEType);
}

- (NSURL *)URL
{
    return (NSURL *)CFURLResponseGetURL([self _CFURLResponse]);
}

- (CFURLResponseRef)_CFURLResponse
{
    return _internal->response;
}

@end

static inline NSString *NSURLLocalizedString(NSString *key)
{
#warning TODO https://code.google.com/p/apportable/issues/detail?id=256
    return key;
}

@implementation NSHTTPURLResponseInternal

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self)
    {

    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{

}

- (void)dealloc
{
    if (peerTrust != NULL)
    {
        CFRelease(peerTrust);
    }
    [super dealloc];
}

@end

@implementation NSHTTPURLResponse

// Restated next to this class's own -initWithCoder:; a secure unarchiver refuses a class whose
// decoding initializer comes from below its +supportsSecureCoding.
+ (BOOL)supportsSecureCoding
{
    return YES;
}

+ (BOOL)isErrorStatusCode:(NSInteger)statusCode
{
    if (statusCode < 100)
    {
        return YES;
    }
    else if (statusCode < 400)
    {
        return NO;
    }
    else
    {
        return YES;
    }
}

// Keyed coding of an HTTP response in the layout of macOS (see encodeResponseArchive): the status code and the header
// fields are archived; the MIME type, length and encoding are derived from the headers again when decoding.
- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
    {
        [NSException raise:NSInvalidArchiveOperationException format:@"NSHTTPURLResponse can only be encoded by a keyed archiver."];
    }
    NSDictionary *fields = [self allHeaderFields];
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:fields];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (id name in fields)
    {
        [values setObject:[NSArray arrayWithObject:[fields objectForKey:name]] forKey:name];
    }
    NSData *order = [NSPropertyListSerialization dataWithPropertyList:values format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (order != nil)
    {
        [headers setObject:[@"\r\n\r\n" stringByAppendingString:[order base64EncodedStringWithOptions:0]] forKey:ResponseArchiveHeaderOrderKey];
    }
    NSNull *null = [NSNull null];
    NSMutableArray *properties = [NSMutableArray arrayWithObjects:
        [self URL] ? (id)[self URL] : (id)null,
        [NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]],
        [NSNumber numberWithInt:0],
        [NSNumber numberWithInteger:[self statusCode]],
        headers,
        nil];
    if ([self MIMEType] != nil)
    {
        [properties addObject:null];
        [properties addObject:[NSMutableString stringWithString:[self MIMEType]]];
    }
    encodeResponseArchive(coder, YES, properties);
}

- (id)initWithCoder:(NSCoder *)coder
{
    NSArray *properties = nil;
    if (![coder allowsKeyedCoding] || !decodeResponseArchive(coder, YES, httpResponseClasses(), &properties))
    {
        [self release];
        return nil;
    }
    NSNumber *status = propertyAt(properties, 3);
    NSDictionary *headers = propertyAt(properties, 4);
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (id name in headers)
    {
        id value = [headers objectForKey:name];
        if (![name isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]])
        {
            status = nil;
            break;
        }
        if (![name isEqualToString:ResponseArchiveHeaderOrderKey])
        {
            [fields setObject:value forKey:name];
        }
    }
    if (status == nil)
    {
        [self release];
        return nil;
    }
    return [self initWithURL:propertyAt(properties, 0) statusCode:[status integerValue] HTTPVersion:(NSString *)kCFHTTPVersion1_1 headerFields:fields];
}

- (id)initWithURL:(NSURL *)URL statusCode:(NSInteger)statusCode HTTPVersion:(NSString *)version headerFields:(NSDictionary *)fields
{
    // A nil HTTPVersion means HTTP/1.1, as on macOS (checked on 26.7.3 and 10.14.4), and CFHTTPMessageCreateResponse
    // crashes without a version.
    CFHTTPMessageRef message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, (int)statusCode, NULL, version != nil ? (CFStringRef)version : kCFHTTPVersion1_1);
    for (NSString *fieldKey in fields)
    {
        NSString *fieldValue = [fields objectForKey:fieldKey];
        CFHTTPMessageSetHeaderFieldValue(message, (CFStringRef)fieldKey, (CFStringRef)fieldValue);
    }
    CFURLResponseRef response = CFURLResponseCreateWithCFHTTPMessage(kCFAllocatorDefault, (CFURLRef)URL, message);
    CFRelease(message);
    self = [super _initWithCFURLResponse:response];
    CFRelease(response);
    if (self)
    {

    }
    return self;
}

- (id)initWithURL:(NSURL *)URL statusCode:(NSInteger)statusCode headerFields:(NSDictionary *)fields requestTime:(NSTimeInterval)ti
{
    return [self initWithURL:URL statusCode:statusCode HTTPVersion:(NSString *)kCFHTTPVersion1_1 headerFields:fields];
}

- (id)_initWithCFURLResponse:(CFURLResponseRef)response
{
    self = [super _initWithCFURLResponse:response];
    if (self)
    {

    }
    return self;
}

- (SecTrustRef)_peerTrust
{
    return _httpInternal->peerTrust;
}

- (void)_setPeerTrust:(SecTrustRef)trust
{
    if (_httpInternal->peerTrust != trust)
    {
        if (_httpInternal->peerTrust != NULL)
        {
            CFRelease(_httpInternal->peerTrust);
        }
        if (trust != NULL) {
            _httpInternal->peerTrust = (SecTrustRef)CFRetain(trust);
        } else {
            _httpInternal->peerTrust = NULL;
        }
    }
}

- (id)_clientCertificateState
{
    return nil;
}

- (id)_clientCertificateChain
{
    return nil;
}

- (id)_peerCertificateChain
{
    return nil;
}

+ (NSString *)localizedStringForStatusCode:(NSInteger)statusCode
{
    if (statusCode < 100)
    {
        return NSURLLocalizedString(@"server error");
    }
    else if (statusCode == 100)
    {
        return NSURLLocalizedString(@"continue");
    }
    else if (statusCode == 101)
    {
        return NSURLLocalizedString(@"switching protocols");
    }
    else if (102 <= statusCode && statusCode <= 199)
    {
        return NSURLLocalizedString(@"informational");
    }
    else if (statusCode == 200)
    {
        return NSURLLocalizedString(@"no error");
    }
    else if (statusCode == 201)
    {
        return NSURLLocalizedString(@"created");
    }
    else if (statusCode == 202)
    {
        return NSURLLocalizedString(@"accepted");
    }
    else if (statusCode == 203)
    {
        return NSURLLocalizedString(@"non-authoritative information");
    }
    else if (statusCode == 204)
    {
        return NSURLLocalizedString(@"no content");
    }
    else if (statusCode == 205)
    {
        return NSURLLocalizedString(@"resetContent");
    }
    else if (statusCode == 206)
    {
        return NSURLLocalizedString(@"partial content");
    }
    else if (207 <= statusCode && statusCode <= 299)
    {
        return NSURLLocalizedString(@"success");
    }
    else if (statusCode == 300)
    {
        return NSURLLocalizedString(@"multiple choices");
    }
    else if (statusCode == 301)
    {
        return NSURLLocalizedString(@"moved permanently");
    }
    else if (statusCode == 302)
    {
        return NSURLLocalizedString(@"found");
    }
    else if (statusCode == 303)
    {
        return NSURLLocalizedString(@"see other");
    }
    else if (statusCode == 304)
    {
        return NSURLLocalizedString(@"not modified");
    }
    else if (statusCode == 305)
    {
        return NSURLLocalizedString(@"needs proxy");
    }
    else if (statusCode == 306)
    {
        return NSURLLocalizedString(@"redirected");
    }
    else if (statusCode == 307)
    {
        return NSURLLocalizedString(@"temporarily redirected");
    }
    else if (308 <= statusCode && statusCode <= 399)
    {
        return NSURLLocalizedString(@"redirected");
    }
    else if (statusCode == 400)
    {
        return NSURLLocalizedString(@"bad request");
    }
    else if (statusCode == 401)
    {
        return NSURLLocalizedString(@"unauthorized");
    }
    else if (statusCode == 402)
    {
        return NSURLLocalizedString(@"payment required");
    }
    else if (statusCode == 403)
    {
        return NSURLLocalizedString(@"forbidden");
    }
    else if (statusCode == 404)
    {
        return NSURLLocalizedString(@"not found");
    }
    else if (statusCode == 405)
    {
        return NSURLLocalizedString(@"method not allowed");
    }
    else if (statusCode == 406)
    {
        return NSURLLocalizedString(@"unacceptable");
    }
    else if (statusCode == 407)
    {
        return NSURLLocalizedString(@"proxy authentication required");
    }
    else if (statusCode == 408)
    {
        return NSURLLocalizedString(@"request timed out");
    }
    else if (statusCode == 409)
    {
        return NSURLLocalizedString(@"conflict");
    }
    else if (statusCode == 410)
    {
        return NSURLLocalizedString(@"no longer exists");
    }
    else if (statusCode == 411)
    {
        return NSURLLocalizedString(@"length required");
    }
    else if (statusCode == 412)
    {
        return NSURLLocalizedString(@"precondition failed");
    }
    else if (statusCode == 413)
    {
        return NSURLLocalizedString(@"request too large");
    }
    else if (statusCode == 414)
    {
        return NSURLLocalizedString(@"requested URL too long");
    }
    else if (statusCode == 416)
    {
        return NSURLLocalizedString(@"requested range not satisfiable");
    }
    else if (statusCode == 417)
    {
        return NSURLLocalizedString(@"expectation failed");
    }
    else if (418 <= statusCode && statusCode <= 499)
    {
        return NSURLLocalizedString(@"client error");
    }
    else if (statusCode == 500)
    {
        return NSURLLocalizedString(@"internal server error");
    }
    else if (statusCode == 501)
    {
        return NSURLLocalizedString(@"unimplemented");
    }
    else if (statusCode == 502)
    {
        return NSURLLocalizedString(@"bad gateway");
    }
    else if (statusCode == 503)
    {
        return NSURLLocalizedString(@"service unavailable");
    }
    else if (statusCode == 504)
    {
        return NSURLLocalizedString(@"gateway unavailable");
    }
    else if (statusCode == 505)
    {
        return NSURLLocalizedString(@"unsupported version");
    }
    else /*if (statusCode <= 506)*/
    {
        return NSURLLocalizedString(@"server error");
    }
}

- (NSInteger)statusCode
{
    return (NSInteger)CFURLResponseGetStatusCode([self _CFURLResponse]);
}

- (NSDictionary *)allHeaderFields
{
    return (NSDictionary *)CFURLResponseGetHeaderFields([self _CFURLResponse]);
}

// Header field names are case-insensitive (RFC 9110, section 5.1).
- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    NSDictionary *fields = [self allHeaderFields];
    NSString *value = [fields objectForKey:field];
    if (value != nil)
    {
        return value;
    }
    for (NSString *name in fields)
    {
        if ([name caseInsensitiveCompare:field] == NSOrderedSame)
        {
            return [fields objectForKey:name];
        }
    }
    return nil;
}

@end

//
//  CFURLRequest.c
//  CFNetwork
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#include "CFURLRequest.h"
#include <CoreFoundation/CFBundle.h>
#include <CoreFoundation/CFLocale.h>
#include <CoreFoundation/CFNumber.h>
#include <stdio.h>
#include "CFRuntime.h"
#include "CFMiscUtils.h"
#include "CFURLStorageSessionInternal.h"
#include "CFURLRequestInternal.h"

#define STACK_BUFFER_SIZE 256

// http://www.w3.org/Protocols/rfc2616/rfc2616-sec9.html
// Keys of NSURLProtocol properties (_CFURLRequestSetProtocolProperty) that
// loaders on macOS read. The strings are Darling's own; the keys are used by
// name only, and the loader does not act on them yet:
// - the partition of the cache that the response is kept in (a CFString);
const CFStringRef _kCFURLCachePartitionKey = CFSTR("_kCFURLCachePartitionKey");
// - whether responses to POST requests may be cached too (a CFBoolean);
const CFStringRef kCFURLRequestAllowAllPOSTCaching = CFSTR("kCFURLRequestAllowAllPOSTCaching");
// - whether content is decoded whatever the URL's extension (a CFBoolean).
const CFStringRef kCFURLRequestContentDecoderSkipURLCheck = CFSTR("kCFURLRequestContentDecoderSkipURLCheck");

const CFStringRef kCFURLRequestGETMethod = CFSTR("GET");
const CFStringRef kCFURLRequestPOSTMethod = CFSTR("POST");
const CFStringRef kCFURLRequestOPTIONSMethod = CFSTR("OPTIONS");
const CFStringRef kCFURLRequestHEADMethod = CFSTR("HEAD");
const CFStringRef kCFURLRequestPUTMethod = CFSTR("PUT");
const CFStringRef kCFURLRequestDELETEMethod = CFSTR("DELETE");
const CFStringRef kCFURLRequestCONNECTMethod = CFSTR("CONNECT");

struct _CFURLRequest {
    CFRuntimeBase _base;

    CFURLRef _url;
    CFURLRef _mainDocument;
    CFStringRef _method;
    CFStringRef _version;
    CFMutableArrayRef _keys;
    CFMutableArrayRef _values;

    CFDataRef _body;
    CFReadStreamRef _stream;

    CFURLRequestCachePolicy _cachePolicy;
    CFURLRequestNetworkServiceType _serviceType;
    CFTimeInterval _timeout;

    Boolean _allowCellularAccess;
    Boolean _allowsExpensiveNetworkAccess;
    Boolean _allowsConstrainedNetworkAccess;
    Boolean _shouldHandleCookies;
    Boolean _shouldUseHTTPPipelining;

    CFURLRequestPriority _priority;
    // NSURLProtocol's properties of the request, made on first use
    CFMutableDictionaryRef _protocolProperties;
    CFURLStorageSessionRef _storageSession;
    _CFURLRequestFlag _flags;
    CFArrayRef _contentDispositionEncodingFallbackArray;
    CFStringRef _boundInterfaceIdentifier;

    Boolean _mutable;
};

static void __CFURLRequestDeallocate(CFTypeRef cf) {
    CFURLRequestRef request = (CFURLRequestRef)cf;
    if (request->_url) {
        CFRelease(request->_url);
    }
    CFRelease(request->_method);
    CFRelease(request->_version);
    if (request->_mainDocument) {
        CFRelease(request->_mainDocument);
    }
    if (request->_keys) {
        CFRelease(request->_keys);
    }
    if (request->_values) {
        CFRelease(request->_values);
    }
    if (request->_protocolProperties) {
        CFRelease(request->_protocolProperties);
    }
    if (request->_storageSession) {
        CFRelease(request->_storageSession);
    }
    if (request->_contentDispositionEncodingFallbackArray) {
        CFRelease(request->_contentDispositionEncodingFallbackArray);
    }
    if (request->_boundInterfaceIdentifier) {
        CFRelease(request->_boundInterfaceIdentifier);
    }
}

static Boolean __CFURLRequestOptionalEqual(CFTypeRef value1, CFTypeRef value2) {
    if (value1 == NULL || value2 == NULL) {
        return value1 == value2;
    }
    return CFEqual(value1, value2);
}

// The same fields with the same values; field names are case-insensitive.
static Boolean __CFURLRequestHTTPFieldsEqual(CFURLRequestRef request1, CFURLRequestRef request2) {
    CFIndex count = CFArrayGetCount(request1->_keys);
    if (count != CFArrayGetCount(request2->_keys)) {
        return false;
    }
    for (CFIndex i = 0; i < count; i++) {
        CFIndex other = CFURLRequestFirstFieldIndex(request2, CFArrayGetValueAtIndex(request1->_keys, i), 0);
        if (other == kCFNotFound ||
            !CFEqual(CFArrayGetValueAtIndex(request1->_values, i), CFArrayGetValueAtIndex(request2->_values, other))) {
            return false;
        }
    }
    return true;
}

static CFIndex __CFURLRequestProtocolPropertyCount(CFURLRequestRef request) {
    return request->_protocolProperties ? CFDictionaryGetCount(request->_protocolProperties) : 0;
}

// What makes two requests equal, as observed on macOS 26.7.3 (test:
// cfnetwork-request-private-settings): the body data, the timeout, the
// network service type, pipelining and the HSTS flags don't count.
static Boolean __CFURLRequestEqual(CFTypeRef cf1, CFTypeRef cf2) {
    CFURLRequestRef request1 = (CFURLRequestRef)cf1;
    CFURLRequestRef request2 = (CFURLRequestRef)cf2;

    if (request1 == request2) {
        return true;
    }

    if (request1->_cachePolicy != request2->_cachePolicy ||
        request1->_shouldHandleCookies != request2->_shouldHandleCookies ||
        request1->_allowCellularAccess != request2->_allowCellularAccess ||
        request1->_allowsExpensiveNetworkAccess != request2->_allowsExpensiveNetworkAccess ||
        request1->_allowsConstrainedNetworkAccess != request2->_allowsConstrainedNetworkAccess ||
        request1->_priority != request2->_priority ||
        request1->_stream != request2->_stream ||
        (request1->_flags & _kCFURLRequestFlagsAffectingEquality) !=
            (request2->_flags & _kCFURLRequestFlagsAffectingEquality)) {
        return false;
    }

    if (!__CFURLRequestOptionalEqual(request1->_url, request2->_url) ||
        !__CFURLRequestOptionalEqual(request1->_mainDocument, request2->_mainDocument) ||
        !CFEqual(request1->_method, request2->_method) ||
        !__CFURLRequestHTTPFieldsEqual(request1, request2)) {
        return false;
    }

    if (__CFURLRequestProtocolPropertyCount(request1) != __CFURLRequestProtocolPropertyCount(request2)) {
        return false;
    }
    if (__CFURLRequestProtocolPropertyCount(request1) != 0 &&
        !CFEqual(request1->_protocolProperties, request2->_protocolProperties)) {
        return false;
    }

    return true;
}

static CFHashCode __CFURLRequestHash(CFTypeRef cf) {
    CFURLRequestRef request = (CFURLRequestRef)cf;
    return (request->_url ? CFHash(request->_url) : 0) ^ (CFHashCode)request->_cachePolicy;
}

static CFTypeID __kCFURLRequestTypeID = _kCFRuntimeNotATypeID;

static const CFRuntimeClass __CFURLRequestClass = {
    _kCFRuntimeScannedObject,
    "CFURLRequest",
    NULL,   // init
    NULL,   // copy
    __CFURLRequestDeallocate,
    __CFURLRequestEqual,
    __CFURLRequestHash,
    NULL,   //
    NULL
};

static void __CFURLRequestInitialize(void) {
    __kCFURLRequestTypeID = _CFRuntimeRegisterClass(&__CFURLRequestClass);
}

static CFStringRef CFURLRequestDefaultUserAgent() {
    static CFStringRef agent = NULL;
    static dispatch_once_t once = 0L;
    dispatch_once(&once, ^{
        CFBundleRef bundle = CFBundleGetMainBundle();
        CFStringRef name = CFBundleGetValueForInfoDictionaryKey(bundle, kCFBundleExecutableKey);
        CFStringRef ver = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleShortVersionString"));
#if DEVELOPERS_CAN_BE_TRUSTED_TO_NOT_SNIFF_USER_AGENTS // too bad this is not reality..
        agent = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@/%@ CFNetwork/129.20 Apportable/1.0"), name, ver);
#else
        agent = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@/%@ CFNetwork/672.0.2 Darwin/13.0.0"), name, ver);
#endif
    });
    return agent;
}

CFStringRef CFURLRequestCopyDebugDescription(CFURLRequestRef req) {
    CFMutableStringRef string = CFStringCreateMutable(kCFAllocatorDefault, 0);

    CFStringAppend(string, CFSTR("curl -k -i "));

    struct _CFURLRequest* reqStruct = (struct _CFURLRequest*)req;
    if (CFEqual(CFSTR("POST"), reqStruct->_method) && reqStruct->_body != NULL) {

        const UInt8* bodyBytes = CFDataGetBytePtr(reqStruct->_body);
        size_t len = CFDataGetLength(reqStruct->_body);
        CFStringRef params = CFStringCreateWithBytes(kCFAllocatorDefault, bodyBytes, len, kCFStringEncodingUTF8, true);
        CFStringAppendFormat(string, NULL, CFSTR("-d \"%@\" "), params);
        CFRelease(params);
    }

    for (CFIndex i = 0; i < CFArrayGetCount(reqStruct->_keys); i++) {
        CFStringRef key = (CFStringRef)CFArrayGetValueAtIndex(reqStruct->_keys, i);
        CFStringRef val = (CFStringRef)CFArrayGetValueAtIndex(reqStruct->_values, i);
        CFStringAppendFormat(string, NULL, CFSTR("-H \"%@\":\"%@\" "), key, val);
    }

    CFStringRef accept_encoding = CFURLRequestGetHeaderFieldValue(req, CFSTR("Accept-Encoding"));
    if (accept_encoding == NULL) {
        CFStringAppend(string, CFSTR("-H \"Accept-Encoding\":\"gzip, deflate\" "));
    }

    CFStringRef connection = CFURLRequestGetHeaderFieldValue(req, CFSTR("Connection"));
    if (connection == NULL) {
        CFStringAppend(string, CFSTR("-H \"Connection\":\"keep-alive\" "));
    }

    CFStringRef user_agent = CFURLRequestGetHeaderFieldValue(req, CFSTR("User-Agent"));
    if (user_agent == NULL) {
        CFStringRef agent = CFURLRequestDefaultUserAgent();
        CFStringAppendFormat(string, NULL, CFSTR("-H \"User-Agent\":\"%@\" "), agent);
    }

    CFStringRef accept_language = CFURLRequestGetHeaderFieldValue(req, CFSTR("Accept-Language"));
    if (accept_language == NULL) {
        CFLocaleRef locale = CFLocaleCopyCurrent();
        CFStringAppendFormat(string, NULL, CFSTR("-H \"Accept-Language\":\"%@\" "), CFLocaleGetIdentifier(locale));
        CFRelease(locale);
    }

    CFStringRef accept = CFURLRequestGetHeaderFieldValue(req, CFSTR("Accept"));
    if (accept == NULL) {
        CFStringAppend(string, CFSTR("-H \"Accept\":\"*/*\" "));
    }

    CFURLRef url = CFURLCopyAbsoluteURL(reqStruct->_url);
    CFStringAppendFormat(string, NULL, CFSTR("\"%@\""), CFURLGetString(url));
    CFRelease(url);

    return string;
}

#ifdef APPORTABLE_CFURLREQUEST_LOGGING
int __CFURLRequestLogging = 1;
#else
int __CFURLRequestLogging = 0;
#endif

void __CFURLRequestLog(CFURLRequestRef req) {
    if (__CFURLRequestLogging) {
        CFStringRef string = CFURLRequestCopyDebugDescription(req);
        RELEASE_LOG("%s\n", CFStringGetCStringPtr(string, kCFStringEncodingUTF8));
        CFRelease(string);
    }
}

CFTypeID CFURLRequestGetTypeID(void) {
    if (__kCFURLRequestTypeID == _kCFRuntimeNotATypeID) {
        __CFURLRequestInitialize();
    }
    return __kCFURLRequestTypeID;
}

CFURLRequestRef CFURLRequestCreate(CFAllocatorRef allocator, CFURLRef url, CFURLRequestCachePolicy policy, CFTimeInterval timeout) {
    CFIndex size = sizeof(struct _CFURLRequest) - sizeof(CFRuntimeBase);
    struct _CFURLRequest *request = (struct _CFURLRequest *)_CFRuntimeCreateInstance(allocator, CFURLRequestGetTypeID(), size, NULL);
    if (url == NULL) {
        request->_url = NULL;
    } else {
        request->_url = (CFURLRef)CFRetain(url);
    }
    request->_method = kCFURLRequestGETMethod;
    request->_version = kCFHTTPVersion1_1;
    request->_cachePolicy = policy;
    request->_timeout = timeout;
    request->_mutable = false;
    request->_serviceType = CFURLNetworkServiceTypeDefault;
    request->_allowCellularAccess = true;
    request->_allowsExpensiveNetworkAccess = true;
    request->_allowsConstrainedNetworkAccess = true;
    request->_shouldHandleCookies = true;
    request->_keys = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    request->_values = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    request->_shouldUseHTTPPipelining = false;
    return (CFURLRequestRef)request;
}

CFURLRequestRef CFURLRequestCreateCopy(CFAllocatorRef allocator, CFURLRequestRef originalRequest) {
    if (!originalRequest->_mutable &&
        CFGetAllocator(originalRequest) == (allocator ? allocator : CFAllocatorGetDefault()))
    {
        return (CFURLRequestRef)CFRetain(originalRequest);
    }

    CFMutableURLRequestRef request = CFURLRequestCreateMutableCopy(allocator, originalRequest);
    request->_mutable = false;
    return request;
}

CFURLRef CFURLRequestGetURL(CFURLRequestRef request) {
    return request->_url;
}

CFURLRequestCachePolicy CFURLRequestGetCachePolicy(CFURLRequestRef request) {
    return request->_cachePolicy;
}

CFTimeInterval CFURLRequestGetTimeout(CFURLRequestRef request) {
    return request->_timeout;
}

CFURLRef CFURLRequestCopyMainDocumentURL(CFURLRequestRef request) {
    if (request->_mainDocument == NULL) {
        return NULL;
    } else {
        return CFRetain(request->_mainDocument);
    }
}

CFURLRequestNetworkServiceType CFURLRequestGetServiceType(CFURLRequestRef request) {
    return request->_serviceType;
}

Boolean CFURLRequestAllowsCellularAccess(CFURLRequestRef request) {
    return request->_allowCellularAccess;
}

Boolean CFURLRequestAllowsExpensiveNetworkAccess(CFURLRequestRef request) {
    return request->_allowsExpensiveNetworkAccess;
}

Boolean CFURLRequestAllowsConstrainedNetworkAccess(CFURLRequestRef request) {
    return request->_allowsConstrainedNetworkAccess;
}

CFStringRef CFURLRequestCopyHTTPMethod(CFURLRequestRef request) {
    return CFStringCreateCopy(kCFAllocatorDefault, request->_method);
}

CFStringRef CFURLRequestCopyHTTPVersion(CFURLRequestRef request) {
    return CFStringCreateCopy(kCFAllocatorDefault, request->_version);
}

CFStringRef CFURLRequestCopyValueForHTTPField(CFURLRequestRef request, CFStringRef field) {
    CFIndex idx = CFURLRequestFirstFieldIndex(request, field, 0);
    if (idx != kCFNotFound) {
        return (CFStringRef)CFRetain((CFTypeRef)CFArrayGetValueAtIndex(request->_values, idx));
    } else {
        return NULL;
    }
}

CFArrayRef CFURLRequestCopyHTTPFields(CFURLRequestRef request) {
    return CFArrayCreateCopy(kCFAllocatorDefault, request->_keys);
}

CFArrayRef CFURLRequestCopyHTTPValues(CFURLRequestRef request) {
    return CFArrayCreateCopy(kCFAllocatorDefault, request->_values);
}

CFDictionaryRef CFURLRequestCopyAllHTTPFields(CFURLRequestRef request) {
    CFDictionaryRef allFields = NULL;

    void *stack_keys[STACK_BUFFER_SIZE];
    void *stack_values[STACK_BUFFER_SIZE];

    void **keys = &stack_keys[0];
    void **values = &stack_values[0];

    do {
        CFIndex count = CFArrayGetCount(request->_keys);
        if (count == 0) {
            break;
        }
        if (count > STACK_BUFFER_SIZE) {
            keys = malloc(sizeof(void *) * count);
            if (keys == NULL) {
                break;
            }
            values = malloc(sizeof(void *) * count);
            if (values == NULL) {
                break;
            }
        }
        CFArrayGetValues(request->_keys, CFRangeMake(0, count), (const void **)keys);
        CFArrayGetValues(request->_values, CFRangeMake(0, count), (const void **)values);
        allFields = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, (const void **)values, count, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    } while (0);
    if (keys != stack_keys && keys != NULL) {
        free(keys);
    }
    if (values != stack_values && values != NULL) {
        free(values);
    }

    return allFields;
}

CFDataRef CFURLRequestGetHTTPBody(CFURLRequestRef request) {
    return request->_body;
}

CFReadStreamRef CFURLRequestGetHTTPBodyStream(CFURLRequestRef request) {
    return request->_stream;
}

Boolean CFURLRequestShouldHandleCookes(CFURLRequestRef request) {
    return request->_shouldHandleCookies;
}

Boolean CFURLRequestShouldUseHTTPPipelining(CFURLRequestRef request) {
    return request->_shouldUseHTTPPipelining;
}

CFIndex CFURLRequestFirstFieldIndex(CFURLRequestRef request, CFStringRef key, CFIndex start) {
    // HTTP field names are case-insensitive.
    for (CFIndex i = start; i < CFArrayGetCount(request->_keys); i++) {
        if (CFStringCompare(CFArrayGetValueAtIndex(request->_keys, i), key, kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
            return i;
        }
    }
    return kCFNotFound;
}

CFStringRef CFURLRequestGetHeaderFieldValue(CFURLRequestRef request, CFStringRef key) {
    CFIndex found = CFArrayGetFirstIndexOfValue(request->_keys, CFRangeMake(0, CFArrayGetCount(request->_keys)), key);
    if (found != kCFNotFound) {
        return CFArrayGetValueAtIndex(request->_values, found);
    } else {
        return NULL;
    }
}

void _CFURLSetMutable(CFURLRequestRef request, Boolean canMutate) {
    struct _CFURLRequest *req = (struct _CFURLRequest *)request;
    req->_mutable = canMutate;
}

CFMutableURLRequestRef CFURLRequestCreateMutableCopy(CFAllocatorRef allocator, CFURLRequestRef request) {
    CFIndex size = sizeof(struct _CFURLRequest) - sizeof(CFRuntimeBase);
    struct _CFURLRequest *newReq = (struct _CFURLRequest *)_CFRuntimeCreateInstance(allocator, __kCFURLRequestTypeID, size, NULL);
    
    if (request->_url == NULL) {
        newReq->_url = NULL;
    } else {
        newReq->_url = (CFURLRef)CFRetain(request->_url);
    }
    
    if (request->_mainDocument == NULL) {
        newReq->_mainDocument = NULL;
    } else {
        newReq->_mainDocument = (CFURLRef)CFRetain(request->_mainDocument);   
    }
    
    newReq->_method = CFRetain(request->_method);
    newReq->_version = CFStringCreateCopy(allocator, request->_version);
    newReq->_keys = CFArrayCreateMutableCopy(allocator, 0, request->_keys);
    newReq->_values = CFArrayCreateMutableCopy(allocator, 0, request->_values);
    
    if (request->_body == NULL) {
        newReq->_body = NULL;
    } else {
        newReq->_body = CFDataCreateCopy(kCFAllocatorDefault, request->_body);
    }
    
    if (request->_stream == NULL) {
        newReq->_stream = NULL;
    } else {
        newReq->_stream = (CFReadStreamRef)CFRetain(request->_stream);
    }

    newReq->_cachePolicy = request->_cachePolicy;
    newReq->_serviceType = request->_serviceType;
    newReq->_timeout = request->_timeout;

    newReq->_allowCellularAccess = request->_allowCellularAccess;
    newReq->_allowsExpensiveNetworkAccess = request->_allowsExpensiveNetworkAccess;
    newReq->_allowsConstrainedNetworkAccess = request->_allowsConstrainedNetworkAccess;
    newReq->_shouldHandleCookies = request->_shouldHandleCookies;
    newReq->_shouldUseHTTPPipelining = request->_shouldUseHTTPPipelining;

    newReq->_priority = request->_priority;
    newReq->_protocolProperties = request->_protocolProperties
        ? CFDictionaryCreateMutableCopy(allocator, 0, request->_protocolProperties) : NULL;
    newReq->_storageSession = request->_storageSession
        ? (CFURLStorageSessionRef)CFRetain(request->_storageSession) : NULL;
    newReq->_flags = request->_flags;
    newReq->_contentDispositionEncodingFallbackArray = request->_contentDispositionEncodingFallbackArray
        ? (CFArrayRef)CFRetain(request->_contentDispositionEncodingFallbackArray) : NULL;
    newReq->_boundInterfaceIdentifier = request->_boundInterfaceIdentifier
        ? (CFStringRef)CFRetain(request->_boundInterfaceIdentifier) : NULL;

    newReq->_mutable = true;

    return (CFMutableURLRequestRef)newReq;
}

Boolean CFURLRequestSetURL(CFMutableURLRequestRef request, CFURLRef url) {
    if (request->_mutable == false) {
        return false;
    }
    if (url == NULL) {
        return false;
    }
    if (request->_url != url) {
        if (request->_url != NULL) {
            CFRelease(request->_url);
        }
        request->_url = (CFURLRef)CFRetain(url);
    }
    return true;
}

Boolean CFURLRequestSetCachePolicy(CFMutableURLRequestRef request, CFURLRequestCachePolicy policy) {
    if (request->_mutable == false) {
        return false;
    }
    request->_cachePolicy = policy;
    return true;
}

Boolean CFURLRequestSetTimeout(CFMutableURLRequestRef request, CFTimeInterval timeout) {
    if (request->_mutable == false) {
        return false;
    }
    request->_timeout = timeout;
    return true;
}

Boolean CFURLRequestSetMainDocumentURL(CFMutableURLRequestRef request, CFURLRef url) {
    if (request->_mutable == false) {
        return false;
    }
    if (request->_mainDocument != url) {
        if (url) {
            if (request->_mainDocument) {
                CFRelease(request->_mainDocument);
            }
            request->_mainDocument = (CFURLRef)CFRetain(url);
        } else {
            request = NULL;
        }
    }
    return true;
}

Boolean CFURLRequestSetNetworkServiceType(CFMutableURLRequestRef request, CFURLRequestNetworkServiceType type) {
    if (request->_mutable == false) {
        return false;
    }
    request->_serviceType = type;
    return true;
}

Boolean CFURLRequestSetAllowsCellularAccess(CFMutableURLRequestRef request, Boolean allowed) {
    if (request->_mutable == false) {
        return false;
    }
    request->_allowCellularAccess = allowed;
    return true;
}

Boolean CFURLRequestSetAllowsExpensiveNetworkAccess(CFMutableURLRequestRef request, Boolean allowed) {
    if (request->_mutable == false) {
        return false;
    }
    request->_allowsExpensiveNetworkAccess = allowed;
    return true;
}

Boolean CFURLRequestSetAllowsConstrainedNetworkAccess(CFMutableURLRequestRef request, Boolean allowed) {
    if (request->_mutable == false) {
        return false;
    }
    request->_allowsConstrainedNetworkAccess = allowed;
    return true;
}

Boolean CFURLRequestSetHTTPMethod(CFMutableURLRequestRef request, CFStringRef method) {
    if (request->_mutable == false) {
        return false;
    }
    if (method == NULL) {
        return false;
    }
    if (request->_method != method) {
        CFRelease(request->_method);
        request->_method = CFStringCreateCopy(kCFAllocatorDefault, method);
    }
    return true;
}

CFIndex CFURLRequestAddValueForHTTPField(CFMutableURLRequestRef request, CFStringRef field, CFStringRef value) {
    if (request->_mutable == false) {
        return kCFNotFound;
    }

    CFIndex idx = CFURLRequestFirstFieldIndex(request, field, 0);
    if (idx != kCFNotFound) {
        if (value == NULL) {
            CFArrayRemoveValueAtIndex(request->_keys, idx);
            CFArrayRemoveValueAtIndex(request->_values, idx);
        } else {
            // if the key already exists, append.
            // the http delimiter is a comma.
            CFStringRef oldValue = CFArrayGetValueAtIndex(request->_values, idx);
            CFStringRef newValue = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@,%@"), oldValue, value);
            CFArraySetValueAtIndex(request->_values, idx, newValue);
            CFRelease(newValue);
        }
    } else {
        CFArrayAppendValue(request->_keys, field);
        CFArrayAppendValue(request->_values, value);
    }


    return CFArrayGetCount(request->_keys) - 1;
}

Boolean CFURLRequestSetHTTPFields(CFMutableURLRequestRef request, CFArrayRef keys, CFArrayRef values) {
    if (request->_mutable == false) {
        return false;
    }
    if (keys == NULL && values == NULL) {
        CFArrayRemoveAllValues(request->_keys);
        CFArrayRemoveAllValues(request->_values);
        return true;
    } else if (keys == NULL || values == NULL) {
        return false;
    }
    if (CFArrayGetCount(keys) != CFArrayGetCount(values)) {
        return false; // probably should be a bit sterner than just failing silently
    }
    if (request->_keys != keys) {
        CFRelease(request->_keys);
        request->_keys = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, keys);
    }
    if (request->_values != values) {
        CFRelease(request->_values);
        request->_values = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, values);
    }
    return true;
}

Boolean CFURLRequestRemoveHTTPField(CFMutableURLRequestRef request, CFIndex index) {
    if (request->_mutable == false) {
        return false;
    }
    CFArrayRemoveValueAtIndex(request->_keys, index);
    CFArrayRemoveValueAtIndex(request->_values, index);
    return true;
}

Boolean CFURLRequestReplaceHTTPField(CFMutableURLRequestRef request, CFIndex index, CFStringRef value) {
    if (request->_mutable == false) {
        return false;
    }
    CFArraySetValueAtIndex(request->_values, index, value);
    return true;
}

Boolean CFURLRequestSetHTTPBody(CFMutableURLRequestRef request, CFDataRef data) {
    if (request->_mutable == false) {
        return false;
    }
    if (request->_body != data) {
        if (request->_body != NULL) {
            CFRelease(request->_body);
        }
        request->_body = data != NULL ? CFRetain(data) : NULL;
    }
    // A request carries either a body or a body stream, never both: setting
    // a body discards the stream (see -[NSMutableURLRequest setHTTPBody:]).
    if (data != NULL && request->_stream != NULL) {
        CFRelease(request->_stream);
        request->_stream = NULL;
    }
    return true;
}

Boolean CFURLRequestSetHTTPBodyStream(CFMutableURLRequestRef request, CFReadStreamRef stream) {
    if (request->_mutable == false) {
        return false;
    }
    if (request->_stream != stream) {
        if (request->_stream != NULL) {
            CFRelease(request->_stream);
        }
        request->_stream = stream != NULL ? (CFReadStreamRef)CFRetain(stream) : NULL;
    }
    // Setting a body stream discards the body data
    // (see -[NSMutableURLRequest setHTTPBodyStream:]).
    if (stream != NULL && request->_body != NULL) {
        CFRelease(request->_body);
        request->_body = NULL;
    }
    return true;
}

// The names WebKit's CFNetwork loader uses for the two setters above.
void CFURLRequestSetHTTPRequestBody(CFMutableURLRequestRef request, CFDataRef body) {
    CFURLRequestSetHTTPBody(request, body);
}

void CFURLRequestSetHTTPRequestBodyStream(CFMutableURLRequestRef request, CFReadStreamRef bodyStream) {
    CFURLRequestSetHTTPBodyStream(request, bodyStream);
}

Boolean CFURLRequestHandleCookies(CFMutableURLRequestRef request, Boolean enabled) {
    if (request->_mutable == false) {
        return false;
    }
    request->_shouldHandleCookies = enabled;
    return true;
}

Boolean CFURLRequestUseHTTPPipelining(CFMutableURLRequestRef request, Boolean enabled) {
    if (request->_mutable == false) {
        return false;
    }
    request->_shouldUseHTTPPipelining = enabled;
    return true;
}

// The priority of the load, from -1 (lowest) to 4 (highest), as WebKit maps
// its load priorities. A request that was not given one has 0; that default
// was not observed on macOS.
CFURLRequestPriority CFURLRequestGetRequestPriority(CFURLRequestRef request) {
    return request->_priority;
}

void CFURLRequestSetRequestPriority(CFURLRequestRef request, CFURLRequestPriority priority) {
    if (request->_mutable == false) {
        return;
    }
    ((struct _CFURLRequest *)request)->_priority = priority;
}

// Whether the request may be pipelined. The second flag, for requests other
// than GET and HEAD, is not kept: the loader does not pipeline at all.
void CFURLRequestSetShouldPipelineHTTP(CFURLRequestRef request, Boolean shouldPipeline, Boolean shouldPipelineNonIdempotent) {
    CFURLRequestUseHTTPPipelining((CFMutableURLRequestRef)request, shouldPipeline);
}

// A hint that the first callbacks of the load may be made synchronously. The
// loader always starts loads asynchronously, which the hint allows.
void CFURLRequestSetShouldStartSynchronously(CFURLRequestRef request, Boolean shouldStartSynchronously) {
}

CFTypeRef _CFURLRequestCopyProtocolPropertyForKey(CFURLRequestRef request, CFStringRef key) {
    if (key == NULL || request->_protocolProperties == NULL) {
        return NULL;
    }
    CFTypeRef value = CFDictionaryGetValue(request->_protocolProperties, key);
    return value ? CFRetain(value) : NULL;
}

// A NULL value removes the property. Immutable requests take properties too
// (observed on macOS 26.7.3; test: cfnetwork-request-private-settings).
void _CFURLRequestSetProtocolProperty(CFURLRequestRef request, CFStringRef key, CFTypeRef value) {
    if (key == NULL) {
        return;
    }
    struct _CFURLRequest *mutableRequest = (struct _CFURLRequest *)request;
    if (value == NULL) {
        if (mutableRequest->_protocolProperties) {
            CFDictionaryRemoveValue(mutableRequest->_protocolProperties, key);
        }
        return;
    }
    if (mutableRequest->_protocolProperties == NULL) {
        mutableRequest->_protocolProperties = CFDictionaryCreateMutable(CFGetAllocator(request), 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    CFDictionarySetValue(mutableRequest->_protocolProperties, key, value);
}

void _CFURLRequestSetStorageSession(CFMutableURLRequestRef request, CFURLStorageSessionRef session) {
    if (request->_mutable == false) {
        return;
    }
    if (session) {
        CFRetain(session);
    }
    if (request->_storageSession) {
        CFRelease(request->_storageSession);
    }
    request->_storageSession = session;
}

CFURLStorageSessionRef __CFURLRequestGetStorageSession(CFURLRequestRef request) {
    return request->_storageSession;
}

CFHTTPMessageRef CFHTTPMessageCreateRequestFromURLRequest(CFAllocatorRef allocator, CFURLRequestRef request) {
    CFHTTPMessageRef message = CFHTTPMessageCreateRequest(allocator, request->_method, request->_url, request->_version);
    
    if (message == NULL) {
        return NULL;
    }
    
    CFIndex count = CFArrayGetCount(request->_keys);
    for (CFIndex idx = 0; idx < count; idx++) {
        CFStringRef headerField = (CFStringRef)CFArrayGetValueAtIndex(request->_keys, idx);
        CFStringRef value = (CFStringRef)CFArrayGetValueAtIndex(request->_values, idx);
        CFHTTPMessageSetHeaderFieldValue(message, headerField, value);
    }

    CFStringRef accept_encoding = CFHTTPMessageCopyHeaderFieldValue(message, CFSTR("Accept-Encoding"));
    if (accept_encoding == NULL) {
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Accept-Encoding"), CFSTR("gzip, deflate"));
    } else {
        CFRelease(accept_encoding);
    }

    CFStringRef connection = CFHTTPMessageCopyHeaderFieldValue(message, CFSTR("Connection"));
    if (connection == NULL) {
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Connection"), CFSTR("keep-alive"));
    } else {
        CFRelease(connection);
    }

    CFStringRef user_agent = CFHTTPMessageCopyHeaderFieldValue(message, CFSTR("User-Agent"));
    if (user_agent == NULL) {
        CFStringRef agent = CFURLRequestDefaultUserAgent();
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("User-Agent"), agent);
    } else {
        CFRelease(user_agent);
    }

    CFStringRef accept_language = CFHTTPMessageCopyHeaderFieldValue(message, CFSTR("Accept-Language"));
    if (accept_language == NULL) {
        CFLocaleRef locale = CFLocaleCopyCurrent();
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Accept-Language"), CFLocaleGetIdentifier(locale));
        CFRelease(locale);
    } else {
        CFRelease(accept_language);
    }

    CFStringRef accept = CFHTTPMessageCopyHeaderFieldValue(message, CFSTR("Accept"));
    if (accept == NULL) {
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Accept"), CFSTR("*/*"));
    } else {
        CFRelease(accept);
    }

    if (request->_body) {
        //Set default content type to application/x-www-form-urlencoded if the method is POST
        CFStringRef requestMethod = CFHTTPMessageCopyRequestMethod(message);
        static CFStringRef contentType = CFSTR("Content-Type");
        CFStringRef contentTypeValue = CFHTTPMessageCopyHeaderFieldValue(message, contentType);
        if (contentTypeValue == NULL && CFStringCompare(requestMethod, kCFURLRequestPOSTMethod, kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
            CFHTTPMessageSetHeaderFieldValue(message, contentType, CFSTR("application/x-www-form-urlencoded"));
        }
        if (contentTypeValue != NULL) {
            CFRelease(contentTypeValue);
        }
        if (requestMethod != NULL) {
            CFRelease(requestMethod);
        }
        CFHTTPMessageSetBody(message, request->_body);
    } else if (request->_stream) {
        // TOOD: Body streams are not yet supported for serialization
    }
    return message;
}

CFURLRequestRef _CFURLRequestCreateFromParcel(CFAllocatorRef allocator, CFPropertyListRef rawParcel) {
    if (!rawParcel || CFGetTypeID(rawParcel) != CFDictionaryGetTypeID()) {
        return NULL;
    }
    CFDictionaryRef parcel = (CFDictionaryRef)rawParcel;

    struct _CFURLRequest* request = (struct _CFURLRequest*)_CFRuntimeCreateInstance(
        allocator,
        CFURLRequestGetTypeID(),
        sizeof(struct _CFURLRequest) - sizeof(CFRuntimeBase),
        NULL);
    
    request->_version = kCFHTTPVersion1_1;
    request->_keys = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    request->_values = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);

    PARCEL_GET_URL(parcel, request->_url, "url");
    PARCEL_GET_URL(parcel, request->_mainDocument, "mainDocument");
    PARCEL_GET_RETAINED_OBJECT(parcel, CFString, request->_method, "method");
    PARCEL_GET_RETAINED_OBJECT(parcel, CFData, request->_body, "body");
    PARCEL_GET_BOOL(parcel, request->_allowCellularAccess, "allowCellularAccess");
    // Parcels written before these flags existed lack them; both default to allowed.
    request->_allowsExpensiveNetworkAccess = true;
    request->_allowsConstrainedNetworkAccess = true;
    PARCEL_GET_BOOL(parcel, request->_allowsExpensiveNetworkAccess, "allowsExpensiveNetworkAccess");
    PARCEL_GET_BOOL(parcel, request->_allowsConstrainedNetworkAccess, "allowsConstrainedNetworkAccess");
    PARCEL_GET_BOOL(parcel, request->_shouldHandleCookies, "shouldHandleCookies");
    PARCEL_GET_BOOL(parcel, request->_shouldUseHTTPPipelining, "shouldUseHTTPPipelining");
    PARCEL_GET_NUMBER(parcel, Double, double, request->_timeout, "timeout");
    PARCEL_GET_ENUM(parcel, request->_cachePolicy, "cachePolicy");
    PARCEL_GET_ENUM(parcel, request->_serviceType, "serviceType");

    CFArrayRef keys = NULL;
    PARCEL_GET_RETAINED_OBJECT(parcel, CFArray, keys, "keys");
    if (keys) {
        CFArrayAppendArray(request->_keys, keys, CFRangeMake(0, CFArrayGetCount(keys)));
        CFRelease(keys);
    }

    CFArrayRef values = NULL;
    PARCEL_GET_RETAINED_OBJECT(parcel, CFArray, values, "values");
    if (values) {
        CFArrayAppendArray(request->_values, values, CFRangeMake(0, CFArrayGetCount(values)));
        CFRelease(values);
    }

    return request;
}

CFPropertyListRef _CFURLRequestCreateParcel(CFURLRequestRef request) {
    if (request->_stream) {
        // Don't know how to serialize stream
        return NULL;
    }

    CFMutableDictionaryRef parcel = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    PARCEL_SET_URL(parcel, request->_url, "url");
    PARCEL_SET_URL(parcel, request->_mainDocument, "mainDocument");
    PARCEL_SET_OBJECT(parcel, request->_method, "method");
    PARCEL_SET_OBJECT(parcel, request->_keys, "keys");
    PARCEL_SET_OBJECT(parcel, request->_values, "values");
    PARCEL_SET_OBJECT(parcel, request->_body, "body");
    PARCEL_SET_BOOL(parcel, request->_allowCellularAccess, "allowCellularAccess");
    PARCEL_SET_BOOL(parcel, request->_allowsExpensiveNetworkAccess, "allowsExpensiveNetworkAccess");
    PARCEL_SET_BOOL(parcel, request->_allowsConstrainedNetworkAccess, "allowsConstrainedNetworkAccess");
    PARCEL_SET_BOOL(parcel, request->_shouldHandleCookies, "shouldHandleCookies");
    PARCEL_SET_BOOL(parcel, request->_shouldUseHTTPPipelining, "shouldUseHTTPPipelining");
    PARCEL_SET_NUMBER(parcel, Double, double, request->_timeout, "timeout");
    PARCEL_SET_ENUM(parcel, request->_cachePolicy, "cachePolicy");
    PARCEL_SET_ENUM(parcel, request->_serviceType, "serviceType");

    return parcel;
}

Boolean _CFURLRequestGetFlag(CFURLRequestRef request, _CFURLRequestFlag flag) {
    return (request->_flags & flag) != 0;
}

void _CFURLRequestSetFlag(CFMutableURLRequestRef request, _CFURLRequestFlag flag, Boolean value) {
    if (!request->_mutable) {
        return;
    }
    if (value) {
        request->_flags |= flag;
    } else {
        request->_flags &= ~flag;
    }
}

CFArrayRef _CFURLRequestGetContentDispositionEncodingFallbackArray(CFURLRequestRef request) {
    return request->_contentDispositionEncodingFallbackArray;
}

void _CFURLRequestSetContentDispositionEncodingFallbackArray(CFMutableURLRequestRef request, CFArrayRef encodings) {
    if (!request->_mutable) {
        return;
    }
    CFArrayRef copy = encodings ? CFArrayCreateCopy(CFGetAllocator(request), encodings) : NULL;
    if (request->_contentDispositionEncodingFallbackArray) {
        CFRelease(request->_contentDispositionEncodingFallbackArray);
    }
    request->_contentDispositionEncodingFallbackArray = copy;
}

CFStringRef _CFURLRequestGetBoundInterfaceIdentifier(CFURLRequestRef request) {
    return request->_boundInterfaceIdentifier;
}

void _CFURLRequestSetBoundInterfaceIdentifier(CFMutableURLRequestRef request, CFStringRef identifier) {
    if (!request->_mutable) {
        return;
    }
    // Kept, not copied, as on macOS 26.7.3.
    if (identifier) {
        CFRetain(identifier);
    }
    if (request->_boundInterfaceIdentifier) {
        CFRelease(request->_boundInterfaceIdentifier);
    }
    request->_boundInterfaceIdentifier = identifier;
}

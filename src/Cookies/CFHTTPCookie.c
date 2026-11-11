//
//  CFHTTPCookie.c
//  CFNetwork
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#include "CFBase.h"
#include "CFRuntime.h"
#include "CFHTTPCookie.h"
#include "CFHTTPCookieInternal.h"
#include "CFNumber.h"
#include "CFDate.h"
#include <ctype.h>
#include <errno.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <strings.h>
#include <stdlib.h>
#include <string.h>

static const CFStringRef kCFHTTPCookieName = CFSTR("Name");
static const CFStringRef kCFHTTPCookieValue = CFSTR("Value");
static const CFStringRef kCFHTTPCookieOriginURL = CFSTR("OriginURL");
static const CFStringRef kCFHTTPCookieVersion = CFSTR("Version");
static const CFStringRef kCFHTTPCookieDomain = CFSTR("Domain");
static const CFStringRef kCFHTTPCookiePath = CFSTR("Path");
static const CFStringRef kCFHTTPCookieSecure = CFSTR("Secure");
static const CFStringRef kCFHTTPCookieExpires = CFSTR("Expires");
static const CFStringRef kCFHTTPCookieComment = CFSTR("Comment");
static const CFStringRef kCFHTTPCookieCommentURL = CFSTR("CommentURL");
static const CFStringRef kCFHTTPCookieDiscard = CFSTR("Discard");
static const CFStringRef kCFHTTPCookieMaximumAge = CFSTR("Max-Age");
static const CFStringRef kCFHTTPCookiePort = CFSTR("Port");
static const CFStringRef kCFHTTPCookieHTTPOnly = CFSTR("HTTPOnly");
static const CFStringRef kCFHTTPCookieHttpOnly = CFSTR("HttpOnly");

// A cookie is immutable once created, so it can be shared between threads without locking.
struct __CFHTTPCookie {
    CFRuntimeBase _base;
    CFDictionaryRef _properties;
    CFStringRef _domain;        // lowercased; a leading dot means "this domain and its subdomains"
    CFDateRef _expires;         // NULL for session cookies without an expiry
    CFAbsoluteTime _expiresTime;
    CFAbsoluteTime _storedTime;
    Boolean _secure;
    Boolean _httpOnly;
    Boolean _sessionOnly;
};

static void __CFHTTPCookieDeallocate(CFTypeRef cf) {
    struct __CFHTTPCookie *item = (struct __CFHTTPCookie *)cf;
    if (item->_properties != NULL) CFRelease(item->_properties);
    if (item->_domain != NULL) CFRelease(item->_domain);
    if (item->_expires != NULL) CFRelease(item->_expires);
}

static CFTypeID __kCFHTTPCookieTypeID = _kCFRuntimeNotATypeID;

static const CFRuntimeClass __CFHTTPCookieClass = {
    _kCFRuntimeScannedObject,
    "CFHTTPCookie",
    NULL,   // init
    NULL,   // copy
    __CFHTTPCookieDeallocate,
    NULL,
    NULL,
    NULL,
    NULL
};

static void __CFHTTPCookieInitialize(void) {
    __kCFHTTPCookieTypeID = _CFRuntimeRegisterClass(&__CFHTTPCookieClass);
}

CFTypeID CFHTTPCookieGetTypeID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __CFHTTPCookieInitialize();
    });
    return __kCFHTTPCookieTypeID;
}

CFHTTPCookieRef _CFHTTPCookieCreate(CFAllocatorRef allocator) {
    CFIndex size = sizeof(struct __CFHTTPCookie) - sizeof(CFRuntimeBase);
    return (CFHTTPCookieRef)_CFRuntimeCreateInstance(allocator, CFHTTPCookieGetTypeID(), size, NULL);
}

#pragma mark - String helpers

static CFStringRef __stringValue(CFDictionaryRef properties, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    return (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) ? (CFStringRef)value : NULL;
}

static CFStringRef __copyLowercased(CFStringRef string) {
    CFMutableStringRef copy = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, string);
    CFStringLowercase(copy, NULL);
    return copy;
}

static CFStringRef __copyTrimmed(CFStringRef string) {
    CFMutableStringRef copy = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, string);
    CFStringTrimWhitespace(copy);
    return copy;
}

static Boolean __isTrueValue(CFTypeRef value) {
    if (value == NULL) {
        return false;
    }
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue(value);
    }
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int n = 0;
        CFNumberGetValue(value, kCFNumberIntType, &n);
        return n != 0;
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        return CFStringCompare(value, CFSTR("TRUE"), kCFCompareCaseInsensitive) == kCFCompareEqualTo
            || CFStringCompare(value, CFSTR("YES"), kCFCompareCaseInsensitive) == kCFCompareEqualTo
            || CFStringCompare(value, CFSTR("1"), 0) == kCFCompareEqualTo;
    }
    return false;
}

static Boolean __hasProperty(CFDictionaryRef properties, CFStringRef key) {
    return CFDictionaryContainsKey(properties, key);
}

#pragma mark - Matching helpers

Boolean _CFHTTPCookieHostIsIPAddress(CFStringRef host) {
    if (host == NULL) {
        return false;
    }
    if (CFStringFind(host, CFSTR(":"), 0).location != kCFNotFound) {
        return true; // IPv6 literal
    }
    CFIndex length = CFStringGetLength(host);
    if (length == 0) {
        return false;
    }
    int dots = 0;
    for (CFIndex i = 0; i < length; i++) {
        UniChar c = CFStringGetCharacterAtIndex(host, i);
        if (c == '.') {
            dots++;
        } else if (c < '0' || c > '9') {
            return false;
        }
    }
    return dots == 3;
}

CFStringRef _CFHTTPCookieCopyHostOfURL(CFURLRef url) {
    if (url == NULL) {
        return NULL;
    }
    CFStringRef host = CFURLCopyHostName(url);
    if (host == NULL) {
        return NULL;
    }
    CFStringRef lowered = __copyLowercased(host);
    CFRelease(host);
    if (CFStringGetLength(lowered) == 0) {
        CFRelease(lowered);
        return NULL;
    }
    return lowered;
}

Boolean _CFHTTPCookieDomainMatchesHost(CFStringRef cookieDomain, CFStringRef host) {
    if (cookieDomain == NULL || host == NULL || CFStringGetLength(cookieDomain) == 0) {
        return false;
    }
    if (CFStringGetCharacterAtIndex(cookieDomain, 0) != '.') {
        // host-only cookie
        return CFStringCompare(cookieDomain, host, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    }

    CFStringRef bare = CFStringCreateWithSubstring(kCFAllocatorDefault, cookieDomain, CFRangeMake(1, CFStringGetLength(cookieDomain) - 1));
    Boolean match = false;
    if (CFStringGetLength(bare) > 0) {
        if (CFStringCompare(bare, host, kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
            match = true;
        } else if (!_CFHTTPCookieHostIsIPAddress(host)) {
            // The host must end with ".<domain>": the match has to fall on a label boundary.
            CFIndex hostLength = CFStringGetLength(host);
            CFIndex bareLength = CFStringGetLength(bare);
            if (hostLength > bareLength + 1 && CFStringGetCharacterAtIndex(host, hostLength - bareLength - 1) == '.') {
                CFRange tail = CFRangeMake(hostLength - bareLength, bareLength);
                match = CFStringCompareWithOptions(host, bare, tail, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
            }
        }
    }
    CFRelease(bare);
    return match;
}

Boolean _CFHTTPCookiePathMatchesPath(CFStringRef cookiePath, CFStringRef requestPath) {
    if (cookiePath == NULL || requestPath == NULL) {
        return false;
    }
    CFIndex cookieLength = CFStringGetLength(cookiePath);
    CFIndex requestLength = CFStringGetLength(requestPath);
    if (cookieLength == 0) {
        return true;
    }
    if (requestLength < cookieLength) {
        return false;
    }
    if (CFStringCompareWithOptions(requestPath, cookiePath, CFRangeMake(0, cookieLength), 0) != kCFCompareEqualTo) {
        return false;
    }
    return requestLength == cookieLength
        || CFStringGetCharacterAtIndex(cookiePath, cookieLength - 1) == '/'
        || CFStringGetCharacterAtIndex(requestPath, cookieLength) == '/';
}

#pragma mark - Cookie creation

CFHTTPCookieRef CFHTTPCookieCreateWithProperties(CFDictionaryRef properties) {
    if (properties == NULL) {
        return NULL;
    }

    CFStringRef name = __stringValue(properties, kCFHTTPCookieName);
    CFStringRef value = __stringValue(properties, kCFHTTPCookieValue);
    CFStringRef path = __stringValue(properties, kCFHTTPCookiePath);
    if (name == NULL || value == NULL || path == NULL || CFStringGetLength(name) == 0) {
        return NULL;
    }

    // The domain comes from the Domain property, or else from the host of OriginURL.
    CFStringRef domain = NULL;
    CFStringRef domainProperty = __stringValue(properties, kCFHTTPCookieDomain);
    if (domainProperty != NULL) {
        CFStringRef trimmed = __copyTrimmed(domainProperty);
        if (CFStringGetLength(trimmed) > 0) {
            domain = __copyLowercased(trimmed);
        }
        CFRelease(trimmed);
    } else {
        CFTypeRef origin = CFDictionaryGetValue(properties, kCFHTTPCookieOriginURL);
        if (origin != NULL) {
            CFURLRef url = NULL;
            if (CFGetTypeID(origin) == CFStringGetTypeID()) {
                url = CFURLCreateWithString(kCFAllocatorDefault, origin, NULL);
            } else if (CFGetTypeID(origin) == CFURLGetTypeID()) {
                url = CFRetain(origin);
            }
            if (url != NULL) {
                domain = _CFHTTPCookieCopyHostOfURL(url);
                CFRelease(url);
            }
        }
    }
    if (domain == NULL) {
        return NULL;
    }

    CFHTTPCookieRef cookie = _CFHTTPCookieCreate(kCFAllocatorDefault);
    if (cookie == NULL) {
        CFRelease(domain);
        return NULL;
    }

    CFMutableDictionaryRef canonical = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, properties);
    CFDictionarySetValue(canonical, kCFHTTPCookieDomain, domain);
    cookie->_properties = canonical;
    cookie->_domain = domain;

    // QUIRK: the Secure property marks the cookie secure whenever the key is present, whatever its
    // value (including "FALSE"). Not documented. Evidence: black-box observation on macOS 27 (tier 2),
    // probe vd-upstream/mac-probes/v377-cookie-storage.m. Same for HttpOnly.
    // Test: cookie-storage.m, "Secure property with value FALSE".
    cookie->_secure = __hasProperty(properties, kCFHTTPCookieSecure);
    cookie->_httpOnly = __hasProperty(properties, kCFHTTPCookieHTTPOnly) || __hasProperty(properties, kCFHTTPCookieHttpOnly);

    // Max-Age takes precedence over Expires (RFC 6265 section 4.1.2.2).
    Boolean hasExpiry = false;
    CFTypeRef maxAge = CFDictionaryGetValue(properties, kCFHTTPCookieMaximumAge);
    if (maxAge != NULL) {
        long long seconds = 0;
        Boolean valid = false;
        if (CFGetTypeID(maxAge) == CFNumberGetTypeID()) {
            valid = CFNumberGetValue(maxAge, kCFNumberLongLongType, &seconds);
        } else if (CFGetTypeID(maxAge) == CFStringGetTypeID()) {
            char buffer[32];
            if (CFStringGetCString(maxAge, buffer, sizeof buffer, kCFStringEncodingASCII)) {
                char *end = NULL;
                seconds = strtoll(buffer, &end, 10);
                valid = end != buffer && *end == '\0';
            }
        }
        if (valid) {
            cookie->_expiresTime = CFAbsoluteTimeGetCurrent() + (double)seconds;
            hasExpiry = true;
        }
    }
    if (!hasExpiry) {
        CFTypeRef expires = CFDictionaryGetValue(properties, kCFHTTPCookieExpires);
        if (expires != NULL && CFGetTypeID(expires) == CFDateGetTypeID()) {
            cookie->_expiresTime = CFDateGetAbsoluteTime(expires);
            hasExpiry = true;
        }
    }
    if (hasExpiry) {
        cookie->_expires = CFDateCreate(kCFAllocatorDefault, cookie->_expiresTime);
    }
    cookie->_sessionOnly = !hasExpiry || __isTrueValue(CFDictionaryGetValue(properties, kCFHTTPCookieDiscard));
    return cookie;
}

CFHTTPCookieRef _CFHTTPCookieCreateStoredCopy(CFHTTPCookieRef cookie, CFAbsoluteTime storedTime) {
    CFHTTPCookieRef copy = _CFHTTPCookieCreate(kCFAllocatorDefault);
    if (copy == NULL) {
        return NULL;
    }
    copy->_properties = CFRetain(cookie->_properties);
    copy->_domain = CFRetain(cookie->_domain);
    copy->_expires = cookie->_expires != NULL ? CFRetain(cookie->_expires) : NULL;
    copy->_expiresTime = cookie->_expiresTime;
    copy->_secure = cookie->_secure;
    copy->_httpOnly = cookie->_httpOnly;
    copy->_sessionOnly = cookie->_sessionOnly;
    copy->_storedTime = storedTime;
    return copy;
}

CFAbsoluteTime _CFHTTPCookieGetExpirationTime(CFHTTPCookieRef cookie) {
    return cookie->_expiresTime;
}

Boolean _CFHTTPCookieIsExpired(CFHTTPCookieRef cookie, CFAbsoluteTime now) {
    return cookie->_expires != NULL && cookie->_expiresTime <= now;
}

CFAbsoluteTime _CFHTTPCookieGetStoredTime(CFHTTPCookieRef cookie) {
    return cookie->_storedTime;
}

Boolean _CFHTTPCookieIsHostOnly(CFHTTPCookieRef cookie) {
    return CFStringGetLength(cookie->_domain) == 0 || CFStringGetCharacterAtIndex(cookie->_domain, 0) != '.';
}

Boolean _CFHTTPCookieHasSameIdentity(CFHTTPCookieRef a, CFHTTPCookieRef b) {
    return CFStringCompare(CFHTTPCookieGetName(a), CFHTTPCookieGetName(b), 0) == kCFCompareEqualTo
        && CFStringCompare(a->_domain, b->_domain, kCFCompareCaseInsensitive) == kCFCompareEqualTo
        // QUIRK: the path is compared without regard to case when deciding whether two cookies are the
        // same cookie, although path matching for requests is case-sensitive. Not documented. Evidence:
        // black-box observation on macOS 27 (tier 2), probe vd-upstream/mac-probes/v377-cookie-storage.m
        // (section E). Test: cookie-storage.m, "quirk: paths that differ in case are one cookie".
        && CFStringCompare(CFHTTPCookieGetPath(a), CFHTTPCookieGetPath(b), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
}

#pragma mark - Accessors

CFNumberRef CFHTTPCookieGetVersion(CFHTTPCookieRef cookie) {
    CFTypeRef version = CFDictionaryGetValue(cookie->_properties, kCFHTTPCookieVersion);
    return (version != NULL && CFGetTypeID(version) == CFNumberGetTypeID()) ? version : NULL;
}

CFStringRef CFHTTPCookieGetName(CFHTTPCookieRef cookie) {
    return CFDictionaryGetValue(cookie->_properties, kCFHTTPCookieName);
}

CFStringRef CFHTTPCookieGetDomain(CFHTTPCookieRef cookie) {
    return cookie->_domain;
}

CFDateRef CFHTTPCookieGetExpirationDate(CFHTTPCookieRef cookie) {
    return cookie->_expires;
}

CFStringRef CFHTTPCookieGetPath(CFHTTPCookieRef cookie) {
    return CFDictionaryGetValue(cookie->_properties, kCFHTTPCookiePath);
}

CFStringRef CFHTTPCookieGetValue(CFHTTPCookieRef cookie) {
    return CFDictionaryGetValue(cookie->_properties, kCFHTTPCookieValue);
}

CFStringRef CFHTTPCookieGetComment(CFHTTPCookieRef cookie) {
    return __stringValue(cookie->_properties, kCFHTTPCookieComment);
}

CFURLRef CFHTTPCookieGetCommentURL(CFHTTPCookieRef cookie) {
    CFTypeRef value = CFDictionaryGetValue(cookie->_properties, kCFHTTPCookieCommentURL);
    return (value != NULL && CFGetTypeID(value) == CFURLGetTypeID()) ? value : NULL;
}

CFArrayRef CFHTTPCookieGetPortArray(CFHTTPCookieRef cookie) {
    CFTypeRef value = CFDictionaryGetValue(cookie->_properties, kCFHTTPCookiePort);
    return (value != NULL && CFGetTypeID(value) == CFArrayGetTypeID()) ? value : NULL;
}

Boolean CFHTTPCookieIsSecure(CFHTTPCookieRef cookie) {
    return cookie->_secure;
}

Boolean CFHTTPCookieIsHTTPOnly(CFHTTPCookieRef cookie) {
    return cookie->_httpOnly;
}

Boolean CFHTTPCookieIsSessionOnly(CFHTTPCookieRef cookie) {
    return cookie->_sessionOnly;
}

CFDictionaryRef CFHTTPCookieCopyProperties(CFHTTPCookieRef cookie) {
    return CFDictionaryCreateCopy(kCFAllocatorDefault, cookie->_properties);
}

CFDictionaryRef CFHTTPCookieCopyRequestHeaderFields(CFArrayRef cookies) {
    CFIndex count = cookies != NULL ? CFArrayGetCount(cookies) : 0;
    if (count == 0) {
        return CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }

    CFMutableStringRef resultCookieString = CFStringCreateMutable(kCFAllocatorDefault, 0);
    for (CFIndex i = 0; i < count; i++) {
        if (i > 0) {
            CFStringAppend(resultCookieString, CFSTR("; "));
        }
        CFHTTPCookieRef cookie = (CFHTTPCookieRef)CFArrayGetValueAtIndex(cookies, i);
        CFStringAppendFormat(resultCookieString, NULL, CFSTR("%@=%@"), CFHTTPCookieGetName(cookie), CFHTTPCookieGetValue(cookie));
    }

    const void *keys[] = { CFSTR("Cookie") };
    const void *values[] = { resultCookieString };
    CFDictionaryRef result = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(resultCookieString);
    return result;
}

#pragma mark - Set-Cookie parsing

// RFC 6265 section 5.1.1: tolerant date parser. Returns false if the text is not a date.
static Boolean __parseCookieDate(const char *text, CFAbsoluteTime *result) {
    static const char *months[] = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    int hour = -1, minute = -1, second = -1, day = -1, month = -1, year = -1;
    const char *p = text;

    while (*p != '\0') {
        while (*p != '\0' && ((unsigned char)*p == 0x09 || ((unsigned char)*p >= 0x20 && (unsigned char)*p <= 0x2F)
               || ((unsigned char)*p >= 0x3B && (unsigned char)*p <= 0x40) || ((unsigned char)*p >= 0x5B && (unsigned char)*p <= 0x60)
               || ((unsigned char)*p >= 0x7B && (unsigned char)*p <= 0x7E))) {
            p++;
        }
        const char *start = p;
        while (*p != '\0' && !((unsigned char)*p == 0x09 || ((unsigned char)*p >= 0x20 && (unsigned char)*p <= 0x2F)
               || ((unsigned char)*p >= 0x3B && (unsigned char)*p <= 0x40) || ((unsigned char)*p >= 0x5B && (unsigned char)*p <= 0x60)
               || ((unsigned char)*p >= 0x7B && (unsigned char)*p <= 0x7E))) {
            p++;
        }
        size_t length = (size_t)(p - start);
        if (length == 0) {
            continue;
        }
        char token[64];
        if (length >= sizeof token) {
            continue;
        }
        memcpy(token, start, length);
        token[length] = '\0';

        int h, m, s, n = 0;
        if (hour < 0 && sscanf(token, "%2d:%2d:%2d%n", &h, &m, &s, &n) == 3 && n > 0 && !isdigit((unsigned char)token[n])) {
            hour = h; minute = m; second = s;
            continue;
        }
        if (day < 0) {
            int d;
            n = 0;
            if (isdigit((unsigned char)token[0]) && sscanf(token, "%2d%n", &d, &n) == 1 && !isdigit((unsigned char)token[n])) {
                day = d;
                continue;
            }
        }
        if (month < 0 && length >= 3) {
            Boolean found = false;
            for (int i = 0; i < 12; i++) {
                if (strncasecmp(token, months[i], 3) == 0) {
                    month = i + 1;
                    found = true;
                    break;
                }
            }
            if (found) {
                continue;
            }
        }
        if (year < 0) {
            int y;
            n = 0;
            if (isdigit((unsigned char)token[0]) && sscanf(token, "%4d%n", &y, &n) == 1 && n >= 2 && !isdigit((unsigned char)token[n])) {
                year = y;
                continue;
            }
        }
    }

    if (hour < 0 || day < 0 || month < 0 || year < 0) {
        return false;
    }
    if (year >= 70 && year <= 99) {
        year += 1900;
    } else if (year >= 0 && year <= 69) {
        year += 2000;
    }
    if (day < 1 || day > 31 || year < 1601 || hour > 23 || minute > 59 || second > 59) {
        return false;
    }

    CFGregorianDate date;
    date.year = year;
    date.month = (SInt8)month;
    date.day = (SInt8)day;
    date.hour = (SInt8)hour;
    date.minute = (SInt8)minute;
    date.second = second;
    *result = CFGregorianDateGetAbsoluteTime(date, NULL);
    return true;
}

static Boolean __isSpace(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

// Default-path of RFC 6265 section 5.1.4, from the path of the request URL.
static CFStringRef __copyDefaultPath(CFURLRef url) {
    CFStringRef path = url != NULL ? CFURLCopyPath(url) : NULL;
    CFStringRef result = NULL;
    if (path != NULL && CFStringGetLength(path) > 1 && CFStringGetCharacterAtIndex(path, 0) == '/') {
        CFRange slash;
        if (CFStringFindWithOptions(path, CFSTR("/"), CFRangeMake(0, CFStringGetLength(path)), kCFCompareBackwards, &slash) && slash.location > 0) {
            result = CFStringCreateWithSubstring(kCFAllocatorDefault, path, CFRangeMake(0, slash.location));
        }
    }
    if (path != NULL) {
        CFRelease(path);
    }
    return result != NULL ? result : CFRetain(CFSTR("/"));
}

static CFStringRef __createString(const char *start, const char *end) {
    while (start < end && __isSpace(*start)) start++;
    while (end > start && __isSpace(end[-1])) end--;
    return CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)start, end - start, kCFStringEncodingUTF8, false);
}

// QUIRK: an expiry set by a Set-Cookie header lies at most 400 days in the future; later dates, and
// Max-Age values beyond that, are shortened to 400 days. Not documented in the public API contract
// (RFC 6265bis draft limits cookie lifetime the same way). Evidence: black-box observation on
// macOS 27 (tier 2), probe vd-upstream/mac-probes/v377-cookie-storage.m (section J, 2037 date).
// Test: cookie-storage.m, "quirk: Set-Cookie expiry is capped at 400 days".
static void __capExpiry(CFMutableDictionaryRef properties) {
    const CFTimeInterval maxLifetime = 400.0 * 24 * 60 * 60;
    CFAbsoluteTime limit = CFAbsoluteTimeGetCurrent() + maxLifetime;
    CFTypeRef maxAge = CFDictionaryGetValue(properties, kCFHTTPCookieMaximumAge);
    if (maxAge != NULL && CFGetTypeID(maxAge) == CFStringGetTypeID()) {
        char buffer[32];
        if (CFStringGetCString(maxAge, buffer, sizeof buffer, kCFStringEncodingASCII)) {
            // more digits than a long long holds, or a larger value than the cap: use the cap
            char *end = NULL;
            errno = 0;
            long long seconds = strtoll(buffer, &end, 10);
            if (errno == ERANGE || seconds > (long long)maxLifetime) {
                CFStringRef capped = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%lld"), (long long)maxLifetime);
                CFDictionarySetValue(properties, kCFHTTPCookieMaximumAge, capped);
                CFRelease(capped);
            }
        }
    }
    CFTypeRef expires = CFDictionaryGetValue(properties, kCFHTTPCookieExpires);
    if (expires != NULL && CFGetTypeID(expires) == CFDateGetTypeID() && CFDateGetAbsoluteTime(expires) > limit) {
        CFDateRef capped = CFDateCreate(kCFAllocatorDefault, limit);
        CFDictionarySetValue(properties, kCFHTTPCookieExpires, capped);
        CFRelease(capped);
    }
}

// Builds one cookie from a single "name=value; attribute; ..." string, or returns NULL.
static CFHTTPCookieRef __createCookieFromSetCookie(const char *start, const char *end, CFURLRef url) {
    const char *attrEnd = memchr(start, ';', end - start);
    const char *pairEnd = attrEnd != NULL ? attrEnd : end;
    const char *equals = memchr(start, '=', pairEnd - start);
    if (equals == NULL) {
        return NULL;
    }
    CFStringRef name = __createString(start, equals);
    CFStringRef value = __createString(equals + 1, pairEnd);
    if (name == NULL || value == NULL || CFStringGetLength(name) == 0) {
        if (name != NULL) CFRelease(name);
        if (value != NULL) CFRelease(value);
        return NULL;
    }

    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(properties, kCFHTTPCookieName, name);
    CFDictionarySetValue(properties, kCFHTTPCookieValue, value);
    CFRelease(name);
    CFRelease(value);
    if (url != NULL) {
        CFDictionarySetValue(properties, kCFHTTPCookieOriginURL, url);
    }

    CFStringRef path = NULL;
    const char *p = attrEnd;
    while (p != NULL && p < end) {
        const char *attrStart = p + 1;
        const char *next = memchr(attrStart, ';', end - attrStart);
        const char *attrStop = next != NULL ? next : end;
        const char *attrEquals = memchr(attrStart, '=', attrStop - attrStart);
        CFStringRef attrName = __createString(attrStart, attrEquals != NULL ? attrEquals : attrStop);
        CFStringRef attrValue = attrEquals != NULL ? __createString(attrEquals + 1, attrStop) : CFRetain(CFSTR(""));
        if (attrName != NULL && attrValue != NULL) {
            if (CFStringCompare(attrName, CFSTR("path"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
                if (CFStringGetLength(attrValue) > 0 && CFStringGetCharacterAtIndex(attrValue, 0) == '/') {
                    if (path != NULL) CFRelease(path);
                    path = CFRetain(attrValue);
                } else if (path != NULL) {
                    CFRelease(path);
                    path = NULL;
                }
            } else if (CFStringCompare(attrName, CFSTR("domain"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
                CFMutableStringRef domain = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, attrValue);
                CFStringLowercase(domain, NULL);
                while (CFStringGetLength(domain) > 0 && CFStringGetCharacterAtIndex(domain, 0) == '.') {
                    CFStringDelete(domain, CFRangeMake(0, 1));
                }
                if (CFStringGetLength(domain) > 0) {
                    CFStringInsert(domain, 0, CFSTR("."));
                    CFDictionarySetValue(properties, kCFHTTPCookieDomain, domain);
                }
                CFRelease(domain);
            } else if (CFStringCompare(attrName, CFSTR("expires"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
                char buffer[128];
                CFAbsoluteTime time;
                if (CFStringGetCString(attrValue, buffer, sizeof buffer, kCFStringEncodingUTF8) && __parseCookieDate(buffer, &time)) {
                    CFDateRef date = CFDateCreate(kCFAllocatorDefault, time);
                    CFDictionarySetValue(properties, kCFHTTPCookieExpires, date);
                    CFRelease(date);
                }
            } else if (CFStringCompare(attrName, CFSTR("max-age"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
                // Only an optional minus sign followed by digits is a valid Max-Age.
                CFIndex length = CFStringGetLength(attrValue);
                Boolean valid = length > 0;
                for (CFIndex i = 0; i < length && valid; i++) {
                    UniChar c = CFStringGetCharacterAtIndex(attrValue, i);
                    valid = (c >= '0' && c <= '9') || (i == 0 && c == '-' && length > 1);
                }
                if (valid) {
                    CFDictionarySetValue(properties, kCFHTTPCookieMaximumAge, attrValue);
                }
            } else if (CFStringCompare(attrName, CFSTR("secure"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
                CFDictionarySetValue(properties, kCFHTTPCookieSecure, CFSTR("TRUE"));
            } else if (CFStringCompare(attrName, CFSTR("httponly"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
                CFDictionarySetValue(properties, kCFHTTPCookieHttpOnly, CFSTR("TRUE"));
            }
        }
        if (attrName != NULL) CFRelease(attrName);
        if (attrValue != NULL) CFRelease(attrValue);
        p = next;
    }

    if (path == NULL) {
        path = __copyDefaultPath(url);
    }
    CFDictionarySetValue(properties, kCFHTTPCookiePath, path);
    CFRelease(path);

    __capExpiry(properties);
    CFHTTPCookieRef cookie = CFHTTPCookieCreateWithProperties(properties);
    CFRelease(properties);
    return cookie;
}

// Does the comma at `comma` end the cookie that starts at `segmentStart`? A comma inside the Expires
// date (right after the weekday) or inside a value does not.
static Boolean __commaSeparatesCookies(const char *segmentStart, const char *comma, const char *end) {
    const char *lastAttr = comma;
    while (lastAttr > segmentStart && lastAttr[-1] != ';') {
        lastAttr--;
    }
    while (lastAttr < comma && __isSpace(*lastAttr)) {
        lastAttr++;
    }
    if (comma - lastAttr >= 7 && strncasecmp(lastAttr, "expires", 7) == 0) {
        const char *q = lastAttr + 7;
        while (q < comma && __isSpace(*q)) q++;
        if (q < comma && *q == '=') {
            q++;
            while (q < comma && __isSpace(*q)) q++;
            Boolean onlyLetters = q < comma;
            for (const char *r = q; r < comma; r++) {
                if (!isalpha((unsigned char)*r)) {
                    onlyLetters = false;
                }
            }
            if (onlyLetters) {
                return false;
            }
        }
    }

    // A new cookie starts with "token=".
    const char *q = comma + 1;
    while (q < end && __isSpace(*q)) q++;
    const char *tokenStart = q;
    while (q < end && *q != '=' && *q != ';' && *q != ',' && !__isSpace(*q)) q++;
    return q < end && q > tokenStart && *q == '=';
}

static CFStringRef __copyHeaderValue(CFDictionaryRef headerFields, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(headerFields, key);
    if (value == NULL) {
        CFIndex count = CFDictionaryGetCount(headerFields);
        if (count > 0) {
            const void **keys = malloc(count * sizeof(void *));
            const void **values = malloc(count * sizeof(void *));
            CFDictionaryGetKeysAndValues(headerFields, keys, values);
            for (CFIndex i = 0; i < count; i++) {
                if (CFGetTypeID(keys[i]) == CFStringGetTypeID() && CFStringCompare(keys[i], key, kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
                    value = values[i];
                    break;
                }
            }
            free(keys);
            free(values);
        }
    }
    if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
        return CFRetain(value);
    }
    return NULL;
}

CFArrayRef CFHTTPCookieCreateWithResponseHeaderFields(CFDictionaryRef headerFields, CFURLRef url) {
    if (headerFields == NULL) {
        return NULL;
    }
    CFStringRef header = __copyHeaderValue(headerFields, CFSTR("Set-Cookie"));
    if (header == NULL) {
        return NULL;
    }

    CFIndex maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(header), kCFStringEncodingUTF8) + 1;
    char *buffer = malloc(maxSize);
    CFMutableArrayRef result = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (buffer != NULL && CFStringGetCString(header, buffer, maxSize, kCFStringEncodingUTF8)) {
        const char *end = buffer + strlen(buffer);
        const char *segmentStart = buffer;
        for (const char *p = buffer; p <= end; p++) {
            if (p == end || (*p == ',' && __commaSeparatesCookies(segmentStart, p, end))) {
                CFHTTPCookieRef cookie = __createCookieFromSetCookie(segmentStart, p, url);
                if (cookie != NULL) {
                    CFArrayAppendValue(result, cookie);
                    CFRelease(cookie);
                }
                segmentStart = p + 1;
            }
        }
    }
    free(buffer);
    CFRelease(header);

    CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, result);
    CFRelease(result);
    return copy;
}

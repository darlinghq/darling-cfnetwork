//
//  CFURLProtectionSpace.c
//  CFNetwork
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#include "CFBase.h"
#include "CFRuntime.h"
#include "CFURLProtectionSpace.h"

struct _CFURLProtectionSpace {
    CFRuntimeBase _base;
    CFStringRef host;
    CFIndex port;
    CFURLProtectionSpaceServerType serverType;
    CFStringRef realm;
    CFURLProtectionSpaceAuthenticationSchemeType scheme;
    CFArrayRef distinguishedNames;
};

static void __CFURLProtectionSpaceDeallocate(CFTypeRef cf) {
    struct _CFURLProtectionSpace *item = (struct _CFURLProtectionSpace *)cf;
    if (item->host != NULL) {
        CFRelease(item->host);
    }
    if (item->realm != NULL) {
        CFRelease(item->realm);
    }
    if (item->distinguishedNames != NULL) {
        CFRelease(item->distinguishedNames);
    }
}

static Boolean __CFURLProtectionSpaceStringsEqual(CFStringRef a, CFStringRef b) {
    return a == b || (a != NULL && b != NULL && CFEqual(a, b));
}

// Two protection spaces are the same when they agree on host, port, server type (which tells a proxy from an
// origin server and gives the protocol), realm and authentication method. Known gap: NSURLProtectionSpace maps a
// protocol the server types do not cover (such as "smtp") to HTTP, so such spaces compare equal to HTTP ones. GUESS: the documentation of NSURLProtectionSpace names host, port, protocol and
// realm as what a credential is matched on and does not say what isEqual compares; the authentication
// method is added because spaces that differ in it ask for different credentials.
static Boolean __CFURLProtectionSpaceEqual(CFTypeRef cf1, CFTypeRef cf2) {
    const struct _CFURLProtectionSpace *a = (const struct _CFURLProtectionSpace *)cf1;
    const struct _CFURLProtectionSpace *b = (const struct _CFURLProtectionSpace *)cf2;
    return a->port == b->port
        && a->serverType == b->serverType
        && a->scheme == b->scheme
        && __CFURLProtectionSpaceStringsEqual(a->host, b->host)
        && __CFURLProtectionSpaceStringsEqual(a->realm, b->realm);
}

static CFHashCode __CFURLProtectionSpaceHash(CFTypeRef cf) {
    const struct _CFURLProtectionSpace *space = (const struct _CFURLProtectionSpace *)cf;
    CFHashCode hash = (CFHashCode)space->port;
    hash = hash * 31 + (CFHashCode)space->serverType;
    hash = hash * 31 + (CFHashCode)space->scheme;
    hash = hash * 31 + (space->host != NULL ? CFHash(space->host) : 0);
    hash = hash * 31 + (space->realm != NULL ? CFHash(space->realm) : 0);
    return hash;
}

static CFTypeID __kCFURLProtectionSpaceTypeID = _kCFRuntimeNotATypeID;

static const CFRuntimeClass __CFURLProtectionSpaceClass = {
    _kCFRuntimeScannedObject,
    "CFURLProtectionSpace",
    NULL,
    NULL,
    __CFURLProtectionSpaceDeallocate,
    __CFURLProtectionSpaceEqual,
    __CFURLProtectionSpaceHash,
    NULL,
    NULL
};

static void __CFURLProtectionSpaceInitialize(void) {
    __kCFURLProtectionSpaceTypeID = _CFRuntimeRegisterClass(&__CFURLProtectionSpaceClass);
}

CFTypeID CFURLProtectionSpaceGetTypeID(void) {
    if (__kCFURLProtectionSpaceTypeID == _kCFRuntimeNotATypeID) {
        __CFURLProtectionSpaceInitialize();
    }
    return __kCFURLProtectionSpaceTypeID;
}

static struct _CFURLProtectionSpace *_CFURLProtectionSpaceCreate(CFAllocatorRef allocator) {
    CFIndex size = sizeof(struct _CFURLProtectionSpace) - sizeof(CFRuntimeBase);
    return (struct _CFURLProtectionSpace *)_CFRuntimeCreateInstance(allocator, CFURLProtectionSpaceGetTypeID(), size, NULL);
}


CFURLProtectionSpaceRef CFURLProtectionSpaceCreate(CFAllocatorRef allocator, 
                                                   CFStringRef host,
                                                   CFIndex port, 
                                                   CFURLProtectionSpaceServerType serverType, 
                                                   CFStringRef realm, 
                                                   CFURLProtectionSpaceAuthenticationSchemeType scheme) {
    struct _CFURLProtectionSpace *space = _CFURLProtectionSpaceCreate(allocator);
    if (host != NULL) {
        space->host = CFStringCreateCopy(allocator, host);
    } else {
        space->host = NULL; // exception/crash?
    }
    space->port = port;
    space->serverType = serverType;
    if (realm != NULL) {
        space->realm = CFStringCreateCopy(allocator, realm);
    } else {
        space->realm = NULL;
    }

    space->scheme = scheme;

    return (CFURLProtectionSpaceRef)space;
}

CFURLProtectionSpaceAuthenticationSchemeType CFURLProtectionSpaceGetAuthenticationScheme(CFURLProtectionSpaceRef space) {
    return space->scheme;
}

static void resolveDistinguishedNames(CFURLProtectionSpaceRef space) {
    DEBUG_BREAK();
}

CFArrayRef CFURLProtectionSpaceGetDistinguishedNames(CFURLProtectionSpaceRef space) {
    if (space->distinguishedNames == NULL) {
        resolveDistinguishedNames(space);
    }
    return space->distinguishedNames;
}

CFStringRef CFURLProtectionSpaceGetHost(CFURLProtectionSpaceRef space) {
    return space->host;
}

CFIndex CFURLProtectionSpaceGetPort(CFURLProtectionSpaceRef space) {
    return space->port;
}

CFStringRef CFURLProtectionSpaceGetRealm(CFURLProtectionSpaceRef space) {
    return space->realm;
}

SecTrustRef CFURLProtectionSpaceGetServerTrust(CFURLProtectionSpaceRef space) {
    DEBUG_BREAK();
    return NULL;
}

CFURLProtectionSpaceServerType CFURLProtectionSpaceGetServerType(CFURLProtectionSpaceRef space) {
    return space->serverType;
}

Boolean CFURLProtectionSpaceIsProxy(CFURLProtectionSpaceRef space) {
    return space->serverType >= kCFURLProtectionSpaceProxyHTTP;
}

Boolean CFURLProtectionSpaceReceivesCredentialSecurely(CFURLProtectionSpaceRef space) {
    DEBUG_BREAK();
    return false;
}

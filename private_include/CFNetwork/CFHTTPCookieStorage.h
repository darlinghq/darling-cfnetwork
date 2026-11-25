#ifndef CFNetwork_CFHTTPCookieStorage_h
#define CFNetwork_CFHTTPCookieStorage_h

#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFDate.h>
#include <CoreFoundation/CFURL.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFData.h>
#include <CoreFoundation/CFRunLoop.h>
#include "CFHTTPCookie.h"
#if PRAGMA_ONCE
#pragma once
#endif

__BEGIN_DECLS

typedef struct __CFHTTPCookieStorage *CFHTTPCookieStorageRef;


// Same values as NSHTTPCookieAcceptPolicy.
typedef CF_ENUM(CFIndex, CFHTTPCookieStorageAcceptPolicy) {
    kCFHTTPCookieStorageAcceptPolicyAlways = 0,
    kCFHTTPCookieStorageAcceptPolicyNever = 1,
    kCFHTTPCookieStorageAcceptPolicyOnlyFromMainDocumentDomain = 2
};

// Called after the storage's cookies changed (not the accept policy), without any lock held.
typedef void (*CFHTTPCookieStorageChangeCallBack)(CFHTTPCookieStorageRef storage, void *info);

CFTypeID CFHTTPCookieStorageGetTypeID(void);
CFHTTPCookieStorageRef CFHTTPCookieStorageGetDefault();
void CFHTTPCookieStorageDeleteCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie);
void CFHTTPCookieStorageSetCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie);
void CFHTTPCookieStorageSetCookies(CFHTTPCookieStorageRef storage, CFArrayRef cookies);
CFArrayRef CFHTTPCookieStorageCopyCookies(CFHTTPCookieStorageRef storage);
CFArrayRef CFHTTPCookieStorageCopyCookiesForURL(CFHTTPCookieStorageRef storage, CFURLRef url);

// Stores cookies set by a response from `url`, subject to the accept policy and to the cookies' domains
// covering the host of `url`. `mainDocumentURL` may be NULL.
void CFHTTPCookieStorageSetCookiesForURL(CFHTTPCookieStorageRef storage, CFArrayRef cookies, CFURLRef url, CFURLRef mainDocumentURL);
void CFHTTPCookieStorageDeleteCookiesSinceDate(CFHTTPCookieStorageRef storage, CFDateRef date);
void CFHTTPCookieStorageDeleteAllCookies(CFHTTPCookieStorageRef storage);
CFHTTPCookieStorageAcceptPolicy CFHTTPCookieStorageGetAcceptPolicy(CFHTTPCookieStorageRef storage);
void CFHTTPCookieStorageSetAcceptPolicy(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageAcceptPolicy policy);
CFHTTPCookieStorageAcceptPolicy CFHTTPCookieStorageGetCookieAcceptPolicy(CFHTTPCookieStorageRef storage);
void CFHTTPCookieStorageSetCookieAcceptPolicy(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageAcceptPolicy policy);
// The default storage; the allocator is not used.
CFHTTPCookieStorageRef _CFHTTPCookieStorageGetDefault(CFAllocatorRef allocator);
void CFHTTPCookieStorageSetChangeCallBack(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageChangeCallBack callBack, void *info);
// Calls the change callback on the run loop, in the mode, rather than on the thread that made the change.
void CFHTTPCookieStorageScheduleWithRunLoop(CFHTTPCookieStorageRef storage, CFRunLoopRef runLoop, CFStringRef mode);

// A persistent storage kept in the file at `url`; `sharedStorage` is not used.
CFHTTPCookieStorageRef CFHTTPCookieStorageCreateFromFile(CFAllocatorRef allocator, CFURLRef url, CFHTTPCookieStorageRef sharedStorage);
// Data naming a persistent storage's file, and a new storage on the file such data names.
CFDataRef CFHTTPCookieStorageCreateIdentifyingData(CFAllocatorRef allocator, CFHTTPCookieStorageRef storage);
CFHTTPCookieStorageRef CFHTTPCookieStorageCreateFromIdentifyingData(CFAllocatorRef allocator, CFDataRef data);

void CFHTTPCookieStorageSetCookiesWithResponseHeaderFieldsForMainDocument(CFHTTPCookieStorageRef storage, CFDictionaryRef headerFields, CFURLRef url, CFURLRef mainDocumentURL);
void CFHTTPCookieStorageSetCookiesWithResponseHeaderFields(CFHTTPCookieStorageRef storage, CFDictionaryRef headerFields, CFURLRef url);
CFDictionaryRef CFHTTPCookieStorageCopyRequestHeaderFieldsForURL(CFHTTPCookieStorageRef storage, CFURLRef url);


__END_DECLS
#endif

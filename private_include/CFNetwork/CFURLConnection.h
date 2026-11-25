#ifndef __CFURLCONNECTION__
#define __CFURLCONNECTION__

#include "CFURLAuthChallenge.h"
#include "CFURLProtectionSpace.h"
#include "CFURLRequest.h"
#include "CFURLResponse.h"
#include "CFCachedURLResponse.h"

#if PRAGMA_ONCE
#pragma once
#endif

__BEGIN_DECLS

typedef const struct _CFURLConnection *CFURLConnectionRef;

typedef struct {
    CFIndex version;
    const void *info;
    const void *(*retain)(const void *info);
    void (*release)(const void *info);
    CFStringRef (*copyDescription)(const void *info);
    Boolean (*equal)(const void *info1, const void *info2);
    CFHashCode (*hash)(const void *info);

    Boolean (*handledByProtocol)(const void *info);
    Boolean (*canAuth)(const void *info, CFURLProtectionSpaceRef space);
    void (*cancelledAuthChallenge)(const void *info, CFURLAuthChallengeRef challenge);
    void (*failed)(const void *info, CFErrorRef error);
    void (*receivedAuthChallenge)(const void *info, CFURLAuthChallengeRef challenge);
    void (*sendRequestForAuthChallenge)(const void *info, CFURLAuthChallengeRef challenge);
    Boolean (*useCredentialStorage)(const void *info);

} CFURLConnectionContext;

typedef struct {
    CFIndex version;
    const void *info;
    const void *(*retain)(const void *info);
    void (*release)(const void *info);
    CFStringRef (*copyDescription)(const void *info);
    Boolean (*equal)(const void *info1, const void *info2);
    CFHashCode (*hash)(const void *info);

    CFURLRequestRef (*redirect)(const void *info, CFURLRequestRef request, CFURLResponseRef response);
    void (*response)(const void *info, CFURLResponseRef response);
    void (*data)(const void *info, CFDataRef data);
    CFReadStreamRef (*newBodyStream)(const void *info, CFURLRequestRef request);
    void (*sent)(const void *info, CFIndex bytesWritten, CFIndex totalBytesWritten, CFIndex totalBytesExpectedToWrite);
    void (*finished)(const void *info);
    CFCachedURLResponseRef (*cache)(const void *info, CFCachedURLResponseRef cachedResponse);
} CFURLConnectionHandlerContext;

CFURLConnectionRef CFURLConnectionCreate(CFAllocatorRef allocator, CFURLRequestRef request, const CFURLConnectionContext *ctx);
Boolean CFURLConnectionGetResponse(CFURLConnectionRef connection, CFURLResponseRef *response, CFErrorRef *error);
void CFURLConnectionSetHandler(CFURLConnectionRef connection, const CFURLConnectionHandlerContext *handlerContext);
void CFURLConnectionScheduleWithRunLoop(CFURLConnectionRef connection, CFRunLoopRef runLoop, CFStringRef runLoopMode);
void CFURLConnectionUnscheduleFromRunLoop(CFURLConnectionRef connection, CFRunLoopRef runLoop, CFStringRef runLoopMode);
Boolean CFURLConnectionSendSynchronousRequest(CFURLRequestRef request, CFDataRef *data, CFURLResponseRef *response, CFErrorRef *error);
void CFURLConnectionSendAsynchronousRequest(CFURLRequestRef request, void (^)(CFURLResponseRef, CFDataRef, CFErrorRef));
void CFURLConnectionStart(CFURLConnectionRef connection);
void CFURLConnectionCancel(CFURLConnectionRef connection);

// Keychain functions a process substitutes for the ones CFNetwork would call (version 0).
struct _CFNFrameworksStubs {
    CFIndex version;
    OSStatus (*SecItem_stub_CopyMatching)(CFDictionaryRef query, CFTypeRef *result);
    OSStatus (*SecItem_stub_Add)(CFDictionaryRef attributes, CFTypeRef *result);
    OSStatus (*SecItem_stub_Update)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
    OSStatus (*SecItem_stub_Delete)(CFDictionaryRef query);
};
void _CFURLConnectionSetFrameworkStubs(const struct _CFNFrameworksStubs *stubs);

// The App Transport Security context, as property list data, that a process passes to its helpers.
CFDataRef _CFNetworkCopyATSContext(void);
Boolean _CFNetworkSetATSContext(CFDataRef context);

__END_DECLS

#endif

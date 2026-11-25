//
//  CFNetworkATS.c
//  CFNetwork
//
//  Copyright (C) 2026 Lubos Dolezel
//
//  The App Transport Security context a process hands to its helper processes,
//  and the keychain functions a process may substitute for the ones CFNetwork
//  calls. Darling's CFNetwork enforces no App Transport Security policy and
//  makes no keychain calls, so both only record what they are given.
//

#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <string.h>
#include "CFURLConnection.h"

static pthread_mutex_t gATSLock = PTHREAD_MUTEX_INITIALIZER;
static CFDataRef gATSContext;

// The context as a property list: the effective policy, which allows every load since nothing is
// enforced. A context set with _CFNetworkSetATSContext is returned as it was given.
CFDataRef _CFNetworkCopyATSContext(void) {
    pthread_mutex_lock(&gATSLock);
    CFDataRef context = gATSContext != NULL ? (CFDataRef)CFRetain(gATSContext) : NULL;
    pthread_mutex_unlock(&gATSLock);
    if (context != NULL) {
        return context;
    }
    const void *key = CFSTR("NSAllowsArbitraryLoads");
    const void *value = kCFBooleanTrue;
    CFDictionaryRef policy = CFDictionaryCreate(kCFAllocatorDefault, &key, &value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    context = CFPropertyListCreateData(kCFAllocatorDefault, policy, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(policy);
    return context;
}

// QUIRK: returns false, also for a context that was accepted, and for NULL. Not documented.
// Evidence: black-box observation on macOS 26.7.3 (tier 2): false for the process's own context,
// for data that is not a property list and for NULL, and the context copied afterwards is unchanged.
// Test: tests/cfnetwork-ats-context.c, "quirk: set returns false".
Boolean _CFNetworkSetATSContext(CFDataRef context) {
    if (context == NULL || CFGetTypeID(context) != CFDataGetTypeID()) {
        return false;
    }
    CFPropertyListRef plist = CFPropertyListCreateWithData(kCFAllocatorDefault, context, kCFPropertyListImmutable, NULL, NULL);
    if (plist == NULL) {
        return false;
    }
    Boolean isDictionary = CFGetTypeID(plist) == CFDictionaryGetTypeID();
    CFRelease(plist);
    if (isDictionary) {
        CFDataRef copy = CFDataCreateCopy(kCFAllocatorDefault, context);
        pthread_mutex_lock(&gATSLock);
        CFDataRef old = gATSContext;
        gATSContext = copy;
        pthread_mutex_unlock(&gATSLock);
        if (old != NULL) CFRelease(old);
    }
    return false;
}

static pthread_mutex_t gStubsLock = PTHREAD_MUTEX_INITIALIZER;
static struct _CFNFrameworksStubs gStubs;

// Records the substitutes. Only version 0 of the structure is known.
void _CFURLConnectionSetFrameworkStubs(const struct _CFNFrameworksStubs *stubs) {
    if (stubs == NULL || stubs->version != 0) {
        return;
    }
    pthread_mutex_lock(&gStubsLock);
    gStubs = *stubs;
    pthread_mutex_unlock(&gStubsLock);
}

/*
 This file is part of Darling.

 Copyright (C) 2026 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/


#include "CFURLStorageSession.h"
#include "CFURLStorageSessionInternal.h"
#include "CFRuntime.h"
#include "CFRuntimeUtils.h"
#include "../Cookies/CFHTTPCookieInternal.h"
#include <pthread.h>

// Darling's own string: the key is used by name only.
const CFStringRef _kCFURLStorageSessionIsPrivate = CFSTR("_kCFURLStorageSessionIsPrivate");

struct __CFURLStorageSession {
    CFRuntimeBase _base;
    pthread_mutex_t lock;
    CFStringRef identifier;
    CFHTTPCookieStorageRef cookieStorage;
    // made on first use, until the cache is disabled
    CFURLCacheRef cache;
    Boolean cacheDisabled;
};

static void storageSessionDeallocate(CFTypeRef cf) {
    struct __CFURLStorageSession* session = (struct __CFURLStorageSession*)cf;
    if (session->identifier) {
        CFRelease(session->identifier);
    }
    CFRelease(session->cookieStorage);
    if (session->cache) {
        CFRelease(session->cache);
    }
    pthread_mutex_destroy(&session->lock);
}

static const CFRuntimeClass storageSessionClass = {
    .version = 0,
    .className = "CFURLStorageSession",
    .finalize = &storageSessionDeallocate,
};

static CFTypeID storageSessionTypeID = _kCFRuntimeNotATypeID;

CFTypeID _CFURLStorageSessionGetTypeID(void) {
    _CFRuntimeRegisterClassOnce(&storageSessionTypeID, &storageSessionClass);
    return storageSessionTypeID;
}

// A session keeps its cookies and its cache in memory, whether or not its
// properties make it private (_kCFURLStorageSessionIsPrivate): Darling does not
// keep a named session's storage on disk, so the property changes nothing.
CFURLStorageSessionRef _CFURLStorageSessionCreate(CFAllocatorRef allocator, CFStringRef identifier, CFDictionaryRef properties) {
    struct __CFURLStorageSession* session = (struct __CFURLStorageSession*)_CFRuntimeCreateInstance(
        allocator, _CFURLStorageSessionGetTypeID(),
        sizeof(struct __CFURLStorageSession) - sizeof(CFRuntimeBase), NULL);
    if (!session) {
        return NULL;
    }
    pthread_mutex_init(&session->lock, NULL);
    session->identifier = identifier ? CFStringCreateCopy(allocator, identifier) : NULL;
    session->cookieStorage = __CFHTTPCookieStorageCreateInMemory(allocator);
    if (!session->cookieStorage) {
        CFRelease(session);
        return NULL;
    }
    return session;
}

CFHTTPCookieStorageRef _CFURLStorageSessionCopyCookieStorage(CFAllocatorRef allocator, CFURLStorageSessionRef session) {
    if (!session) {
        return NULL;
    }
    return (CFHTTPCookieStorageRef)CFRetain(session->cookieStorage);
}

CFURLCacheRef _CFURLStorageSessionCopyCache(CFAllocatorRef allocator, CFURLStorageSessionRef session) {
    if (!session) {
        return NULL;
    }
    struct __CFURLStorageSession* mutableSession = (struct __CFURLStorageSession*)session;
    CFURLCacheRef cache = NULL;
    pthread_mutex_lock(&mutableSession->lock);
    if (!mutableSession->cacheDisabled) {
        if (!mutableSession->cache) {
            mutableSession->cache = CFURLCacheCreate(kCFAllocatorDefault, kCFURLCacheDefaultMemoryCapacity, 0, NULL);
        }
        if (mutableSession->cache) {
            cache = (CFURLCacheRef)CFRetain(mutableSession->cache);
        }
    }
    pthread_mutex_unlock(&mutableSession->lock);
    return cache;
}

void _CFURLStorageSessionDisableCache(CFURLStorageSessionRef session) {
    if (!session) {
        return;
    }
    struct __CFURLStorageSession* mutableSession = (struct __CFURLStorageSession*)session;
    pthread_mutex_lock(&mutableSession->lock);
    CFURLCacheRef cache = mutableSession->cache;
    mutableSession->cache = NULL;
    mutableSession->cacheDisabled = true;
    pthread_mutex_unlock(&mutableSession->lock);
    if (cache) {
        CFRelease(cache);
    }
}

// Whether the host of the URL is known, in the session or (without one) in the
// process, to require HTTPS (HTTP Strict Transport Security, RFC 6797). The
// loader keeps no HSTS state, so no host is known as one.
Boolean _CFNetworkIsKnownHSTSHostWithSession(CFURLRef url, CFURLStorageSessionRef session) {
    return false;
}

CFHTTPCookieStorageRef __CFURLStorageSessionCopyCookieStorageOrDefault(CFURLStorageSessionRef session) {
    if (session) {
        return _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, session);
    }
    return (CFHTTPCookieStorageRef)CFRetain(CFHTTPCookieStorageGetDefault());
}

CFURLCacheRef __CFURLStorageSessionCopyCacheOrShared(CFURLStorageSessionRef session) {
    if (session) {
        return _CFURLStorageSessionCopyCache(kCFAllocatorDefault, session);
    }
    CFURLCacheRef cache = NULL;
    return CFURLCacheGetShared(&cache) ? cache : NULL;
}

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

#ifndef __CFURLSTORAGESESSION__
#define __CFURLSTORAGESESSION__

#include <CoreFoundation/CoreFoundation.h>
#include "CFHTTPCookieStorage.h"
#include "CFURLCache.h"

CF_EXTERN_C_BEGIN

// A storage session: a cookie storage and a URL cache of their own, which
// the requests given the session (_CFURLRequestSetStorageSession) use in
// place of the default cookie storage and the shared cache.
typedef const struct __CFURLStorageSession* CFURLStorageSessionRef;

// A property of the session: a CFBoolean, whether the session is private.
CF_EXPORT const CFStringRef _kCFURLStorageSessionIsPrivate;

CF_EXPORT CFTypeID _CFURLStorageSessionGetTypeID(void);
// The identifier names the session; the properties may be NULL.
CF_EXPORT CFURLStorageSessionRef _CFURLStorageSessionCreate(CFAllocatorRef allocator, CFStringRef identifier, CFDictionaryRef properties);
CF_EXPORT CFHTTPCookieStorageRef _CFURLStorageSessionCopyCookieStorage(CFAllocatorRef allocator, CFURLStorageSessionRef session);
// NULL once the cache is disabled.
CF_EXPORT CFURLCacheRef _CFURLStorageSessionCopyCache(CFAllocatorRef allocator, CFURLStorageSessionRef session);
// The session's requests are then neither answered from nor kept in a cache.
CF_EXPORT void _CFURLStorageSessionDisableCache(CFURLStorageSessionRef session);

// Whether the URL's host is known to require HTTPS (HSTS); session may be NULL.
CF_EXPORT Boolean _CFNetworkIsKnownHSTSHostWithSession(CFURLRef url, CFURLStorageSessionRef session);

CF_EXTERN_C_END

#endif // __CFURLSTORAGESESSION__

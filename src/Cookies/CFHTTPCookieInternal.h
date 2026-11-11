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

// Helpers shared by CFHTTPCookie.c and CFHTTPCookieStorage.c. Not exported.

#ifndef CFNetwork_CFHTTPCookieInternal_h
#define CFNetwork_CFHTTPCookieInternal_h

#include <CoreFoundation/CoreFoundation.h>
#include "CFHTTPCookie.h"

__BEGIN_DECLS

#define _CFHTTPCookieHidden __attribute__((visibility("hidden")))

// Absolute time at which the cookie expires; meaningful only if it is not a session cookie.
_CFHTTPCookieHidden CFAbsoluteTime _CFHTTPCookieGetExpirationTime(CFHTTPCookieRef cookie);
_CFHTTPCookieHidden Boolean _CFHTTPCookieIsExpired(CFHTTPCookieRef cookie, CFAbsoluteTime now);
// The time at which a storage last stored the cookie (0 if it never did).
_CFHTTPCookieHidden CFAbsoluteTime _CFHTTPCookieGetStoredTime(CFHTTPCookieRef cookie);
// Copy of the cookie recording the time it was stored.
_CFHTTPCookieHidden CFHTTPCookieRef _CFHTTPCookieCreateStoredCopy(CFHTTPCookieRef cookie, CFAbsoluteTime storedTime);
// Same name, domain and path (name and path compared exactly, domain case-insensitively).
_CFHTTPCookieHidden Boolean _CFHTTPCookieHasSameIdentity(CFHTTPCookieRef a, CFHTTPCookieRef b);
// A cookie whose domain has no leading dot is only sent to exactly that host.
_CFHTTPCookieHidden Boolean _CFHTTPCookieIsHostOnly(CFHTTPCookieRef cookie);

// Host name of a URL, lowercased; NULL if the URL has none.
_CFHTTPCookieHidden CFStringRef _CFHTTPCookieCopyHostOfURL(CFURLRef url);
_CFHTTPCookieHidden Boolean _CFHTTPCookieHostIsIPAddress(CFStringRef host);
// Does the cookie's domain attribute cover the host (RFC 6265 section 5.1.3 for dotted domains, exact match for host-only)?
_CFHTTPCookieHidden Boolean _CFHTTPCookieDomainMatchesHost(CFStringRef cookieDomain, CFStringRef host);
// Does the cookie's path cover the request path (RFC 6265 section 5.1.4)?
_CFHTTPCookieHidden Boolean _CFHTTPCookiePathMatchesPath(CFStringRef cookiePath, CFStringRef requestPath);

__END_DECLS

#endif

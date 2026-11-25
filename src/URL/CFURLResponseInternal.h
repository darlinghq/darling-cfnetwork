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


// What the connection records on the responses it makes. Not exported.

#ifndef __CFURLRESPONSEINTERNAL__
#define __CFURLRESPONSEINTERNAL__

#include "CFURLResponse.h"

CF_EXTERN_C_BEGIN

// The server's trust of the TLS connection that gave the response, for
// _CFURLResponseGetSSLCertificateContext. Set at most once.
__attribute__((visibility("hidden"))) void __CFURLResponseSetSSLPeerTrust(CFURLResponseRef response, CFTypeRef peerTrust);

CF_EXTERN_C_END

#endif

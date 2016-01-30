/*
This file is part of Darling.

Copyright (C) 2013-2015 Lubos Dolezel

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

#ifndef __CFNETWORK_CFSOCKETSTREAM_H__
#define __CFNETWORK_CFSOCKETSTREAM_H__

#include <CoreFoundation/CFStream.h>

// TODO: many more declarations

#if OS_API_VERSION(MAC_OS_X_VERSION_10_2, GS_API_LATEST)
CF_EXPORT const CFStringRef kCFStreamPropertyShouldCloseNativeSocket;
#endif

#if OS_API_VERSION(MAC_OS_X_VERSION_10_3, GS_API_LATEST)
CF_EXPORT void
CFStreamCreatePairWithSocket (CFAllocatorRef alloc, CFSocketNativeHandle sock,
                              CFReadStreamRef *readStream,
                              CFWriteStreamRef *writeStream);
#endif

#endif /* __CFNETWORK_CFSOCKETSTREAM_H__ */


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

#include "CFNetwork/CFSocketStream.h"
#include <CFStringConst.h>
#include <CoreFoundation/CFStreamPriv.h>
#include <CoreFoundation/CFNumber.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <netdb.h>
#include <string.h>
#include <stdlib.h>

CONST_STRING_DECL(kCFStreamPropertyShouldCloseNativeSocket,
		"kCFStreamPropertyShouldCloseNativeSocket");

// Private functions defined by CoreBase
void CFWriteStreamSetError(CFWriteStreamRef stream, int error);
void CFReadStreamSetError(CFReadStreamRef stream, int error);

static void CFWriteStreamSocketFinalize(CFWriteStreamRef s);
static void CFWriteStreamSocketClose(CFWriteStreamRef s);
static CFTypeRef CFWriteStreamSocketCopyProperty(CFWriteStreamRef s, CFStringRef propertyName);
static Boolean CFWriteStreamSocketSetProperty(CFWriteStreamRef s, CFStringRef propertyName,
		CFTypeRef propertyValue);
static CFIndex CFWriteStreamSocketWrite(CFWriteStreamRef s, const UInt8 *buffer,
		CFIndex bufferLength);
static Boolean CFWriteStreamSocketOpen(CFWriteStreamRef s);

struct CFWriteStreamSocket
{
	struct __CFWriteStream parent;
	int fd;
	int originalFd;
	Boolean closeOriginal;

	/* reference to related read stream for socket streams */
	struct CFReadStreamSocket *readStream;
};

static const struct CFWriteStreamImpl CFWriteStreamSocketImpl = {
	CFWriteStreamSocketClose,
	CFWriteStreamSocketFinalize,
	CFWriteStreamSocketOpen,
	CFWriteStreamSocketWrite,
	CFWriteStreamSocketCopyProperty,
	CFWriteStreamSocketSetProperty,
	NULL
};

static void CFReadStreamSocketFinalize(CFReadStreamRef s);
static void CFReadStreamSocketClose(CFReadStreamRef s);
static Boolean CFReadStreamSocketOpen(CFReadStreamRef s);
static CFIndex CFReadStreamSocketRead(CFReadStreamRef s, UInt8 *buffer, CFIndex bufferLength);
static Boolean CFReadStreamSocketSetProperty(CFReadStreamRef s, CFStringRef propertyName,
		CFTypeRef propertyValue);
static CFTypeRef CFReadStreamSocketCopyProperty(CFReadStreamRef s, CFStringRef propertyName);

struct CFReadStreamSocket
{
	struct __CFReadStream parent;
	int fd;
	int originalFd;
	Boolean closeOriginal;
	struct CFWriteStreamSocket *writeStream;
};

static const struct CFReadStreamImpl CFReadStreamSocketImpl = {
	CFReadStreamSocketClose,
	CFReadStreamSocketFinalize,
	CFReadStreamSocketOpen,
	CFReadStreamSocketRead,
	CFReadStreamSocketCopyProperty,
	CFReadStreamSocketSetProperty,
	NULL,
	NULL
};

#define CFWRITESTREAMSOCKET_SIZE (sizeof(struct CFWriteStreamSocket) - sizeof(CFRuntimeBase))
#define CFREADSTREAMSOCKET_SIZE (sizeof(struct CFReadStreamSocket) - sizeof(CFRuntimeBase))

void
CFStreamCreatePairWithSocket(CFAllocatorRef alloc, CFSocketNativeHandle sock,
		CFReadStreamRef *readStream,
		CFWriteStreamRef *writeStream)
{
	struct CFWriteStreamSocket* sfd;
	struct CFReadStreamSocket* rfd;

	*writeStream = (CFWriteStreamRef)
			_CFRuntimeCreateInstance(alloc, CFWriteStreamGetTypeID(),
			CFWRITESTREAMSOCKET_SIZE, 0);
	sfd = (struct CFWriteStreamSocket*) *writeStream;

	memcpy(&(*writeStream)->impl, &CFWriteStreamSocketImpl, sizeof (CFWriteStreamSocketImpl));
	sfd->fd = dup(sock);
	sfd->originalFd = sock;

	*readStream = (CFReadStreamRef)
			_CFRuntimeCreateInstance(alloc, CFReadStreamGetTypeID(),
			CFREADSTREAMSOCKET_SIZE, 0);
	rfd = (struct CFReadStreamSocket*) *readStream;

	memcpy(&(*readStream)->impl, &CFReadStreamSocketImpl, sizeof (CFReadStreamSocketImpl));
	rfd->fd = dup(sock);
	rfd->originalFd = sock;
}

static void
CFWriteStreamSocketClose(CFWriteStreamRef s)
{
	struct CFWriteStreamSocket* stream = (struct CFWriteStreamSocket*) s;
	if (stream->fd != -1)
	{
		close(stream->fd);
		stream->fd = -1;
	}
}

static void
CFWriteStreamSocketFinalize(CFWriteStreamRef s)
{
	struct CFWriteStreamSocket* stream = (struct CFWriteStreamSocket*) s;

	if (stream->readStream != NULL)
	{
		stream->readStream->writeStream = NULL;
	}
}

static CFTypeRef
CFStreamGetSocketProperty(int fd, CFStringRef propertyName)
{
	char hbuf[NI_MAXHOST];
	struct sockaddr* sa = NULL;
	socklen_t len = 0;

	getpeername(fd, sa, &len);

	if (errno != ENOBUFS)
		return NULL;

	sa = (struct sockaddr*) malloc(len);

	if (getpeername(fd, sa, &len) == -1)
	{
		free(sa);

		return NULL;
	}

	if (CFEqual(propertyName, kCFStreamPropertySocketRemoteHostName))
	{
		if (getnameinfo(sa, len, hbuf, sizeof (hbuf), NULL, 0, 0) == -1)
		{
			free(sa);

			return NULL;
		}

		free(sa);
		return CFStringCreateWithCString(NULL, hbuf, kCFStringEncodingISOLatin1);
	}
	else
	{
		int port = 0;

		if (sa->sa_family == AF_INET)
			port = ntohs(((struct sockaddr_in*) sa)->sin_port);
		else if (sa->sa_family == AF_INET6)
			port = ntohs(((struct sockaddr_in6*) sa)->sin6_port);

		free(sa);
		return CFNumberCreate(NULL, kCFNumberIntType, &port);
	}
}

static CFTypeRef
CFWriteStreamSocketCopyProperty(CFWriteStreamRef s, CFStringRef propertyName)
{
	struct CFWriteStreamSocket* stream = (struct CFWriteStreamSocket*) s;

	if (CFEqual(propertyName, kCFStreamPropertyFileCurrentOffset))
	{
		CFIndex zero = 0;
		return CFNumberCreate(NULL, kCFNumberCFIndexType, &zero);
	}
	else if (CFEqual(propertyName, kCFStreamPropertySocketNativeHandle))
	{
		return CFDataCreate(NULL, (UInt8*) & stream->fd, sizeof (stream->fd));
	}
	else if (CFEqual(propertyName, kCFStreamPropertySocketRemoteHostName)
			|| CFEqual(propertyName, kCFStreamPropertySocketRemotePortNumber))
	{
		CFTypeRef rv = CFStreamGetSocketProperty(stream->fd, propertyName);

		if (rv == NULL)
			CFWriteStreamSetError(s, errno);

		return rv;
	}
	else if (CFEqual(propertyName, kCFStreamPropertyShouldCloseNativeSocket))
		return stream->closeOriginal ? kCFBooleanTrue : kCFBooleanFalse;

	CFWriteStreamSetError(s, EINVAL);
	return false;
}

static Boolean
CFWriteStreamSocketSetProperty(CFWriteStreamRef s, CFStringRef propertyName,
		CFTypeRef propertyValue)
{
	struct CFWriteStreamSocket* stream = (struct CFWriteStreamSocket*) s;

	if (CFEqual(propertyName, kCFStreamPropertyShouldCloseNativeSocket))
	{
		stream->closeOriginal = propertyValue == kCFBooleanTrue;
		if (stream->readStream != NULL)
			stream->readStream->closeOriginal = stream->closeOriginal;
		return true;
	}

	CFWriteStreamSetError(s, EINVAL);
	return false;
}

static CFIndex
CFWriteStreamSocketWrite(CFWriteStreamRef s, const UInt8 *buffer,
		CFIndex bufferLength)
{
	struct CFWriteStreamSocket* stream = (struct CFWriteStreamSocket*) s;
	int wr;

	wr = write(stream->fd, buffer, bufferLength);
	if (wr == -1)
		CFWriteStreamSetError(s, errno);

	return wr;
}

static Boolean
CFWriteStreamSocketOpen(CFWriteStreamRef s)
{
	struct CFWriteStreamSocket* stream = (struct CFWriteStreamSocket*) s;

	if (stream->fd != -1)
		return true; /* nothing to do */

	return false;
}

static void
CFReadStreamSocketClose(CFReadStreamRef s)
{
	struct CFWriteStreamSocket* stream = (struct CFWriteStreamSocket*) s;

	if (stream->fd != -1)
	{
		close(stream->fd);
		stream->fd = -1;
	}

	if (stream->closeOriginal && stream->readStream != NULL
			&& stream->readStream->fd == 1)
	{
		close(stream->originalFd);
		stream->originalFd = -1;
	}
}

static Boolean
CFReadStreamSocketOpen(CFReadStreamRef s)
{
	struct CFReadStreamSocket* stream = (struct CFReadStreamSocket*) s;

	if (stream->fd != -1)
		return true; /* nothing to do */

	return false;
}

static CFIndex
CFReadStreamSocketRead(CFReadStreamRef s, UInt8 *buffer, CFIndex bufferLength)
{
	int rd;
	struct CFReadStreamSocket* stream = (struct CFReadStreamSocket*) s;

	rd = read(stream->fd, buffer, bufferLength);

	if (rd == -1)
		CFReadStreamSetError(s, errno);

	return rd;
}

static Boolean
CFReadStreamSocketSetProperty(CFReadStreamRef s, CFStringRef propertyName,
		CFTypeRef propertyValue)
{
	struct CFReadStreamSocket* stream = (struct CFReadStreamSocket*) s;

	if (CFEqual(propertyName, kCFStreamPropertyShouldCloseNativeSocket))
	{
		stream->closeOriginal = propertyValue == kCFBooleanTrue;
		if (stream->writeStream != NULL)
			stream->writeStream->closeOriginal = stream->closeOriginal;
		return true;
	}

	CFReadStreamSetError(s, EINVAL);
	return false;
}

static CFTypeRef
CFReadStreamSocketCopyProperty(CFReadStreamRef s, CFStringRef propertyName)
{
	struct CFReadStreamSocket* stream = (struct CFReadStreamSocket*) s;

	if (CFEqual(propertyName, kCFStreamPropertyFileCurrentOffset))
	{
		CFIndex zero = 0;
		return CFNumberCreate(NULL, kCFNumberCFIndexType, &zero);
	}
	else if (CFEqual(propertyName, kCFStreamPropertySocketNativeHandle))
	{
		return CFDataCreate(NULL, (UInt8*) & stream->fd, sizeof (stream->fd));
	}
	else if (CFEqual(propertyName, kCFStreamPropertySocketRemoteHostName)
			|| CFEqual(propertyName, kCFStreamPropertySocketRemotePortNumber))
	{
		CFTypeRef rv = CFStreamGetSocketProperty(stream->fd, propertyName);

		if (rv == NULL)
			CFReadStreamSetError(s, errno);

		return rv;
	}
	else if (CFEqual(propertyName, kCFStreamPropertyShouldCloseNativeSocket))
		return stream->closeOriginal ? kCFBooleanTrue : kCFBooleanFalse;

	CFReadStreamSetError(s, EINVAL);
	return false;
}

static void
CFReadStreamSocketFinalize(CFReadStreamRef s)
{
	struct CFReadStreamSocket* stream = (struct CFReadStreamSocket*) s;

	if (stream->writeStream != NULL)
	{
		stream->writeStream->readStream = NULL;
	}
}


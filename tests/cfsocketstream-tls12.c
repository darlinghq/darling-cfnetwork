/* Copyright (C) 2026 Lubos Dolezel */
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#include <stdio.h>
#include <string.h>

/*
 * The default (negotiated) security level of an https read stream must offer TLS
 * versions up to 1.2. Run against tests/cfurlconnection-test-server.py started
 * with a certificate and key (it accepts TLS 1.2 only).
 * usage: cfsocketstream-tls12 HTTPS_HOST_PORT_URL   e.g. https://127.0.0.1:8771/plain
 * The server's certificate is self-signed, so the test turns chain validation off on its
 * own stream; no library default is changed.
 * Prints PASS/FAIL lines; the exit status is the number of failures.
 */

static int failures;
#define CHECK(cond, what) do { \
	if (cond) printf("PASS: %s\n", what); else { printf("FAIL: %s\n", what); failures++; } \
} while (0)

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s HTTPS_URL\n", argv[0]);
		return 2;
	}
	CFStringRef urlString = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
	CFURLRef url = CFURLCreateWithString(NULL, urlString, NULL);
	CFHTTPMessageRef request = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), url, kCFHTTPVersion1_1);
	CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(NULL, request);

	CFBooleanRef no = kCFBooleanFalse;
	const void *keys[] = { kCFStreamSSLValidatesCertificateChain };
	const void *values[] = { no };
	CFDictionaryRef ssl = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFReadStreamSetProperty(stream, kCFStreamPropertySSLSettings, ssl);
	CFReadStreamSetProperty(stream, CFSTR("kCFStreamPropertyHTTPShouldAutoredirect"), kCFBooleanTrue);

	CHECK(CFReadStreamOpen(stream), "stream opens");
	UInt8 buffer[256];
	CFIndex got, total = 0;
	char body[256] = "";
	while ((got = CFReadStreamRead(stream, buffer, sizeof(buffer) - 1)) > 0) {
		if (total + got < (CFIndex)sizeof(body)) {
			memcpy(body + total, buffer, got);
			body[total + got] = 0;
		}
		total += got;
	}
	CHECK(got == 0, "read ends at the end of the body, not with an error (TLS 1.2 handshake succeeded)");

	CFHTTPMessageRef reply = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
	CHECK(reply != NULL && CFHTTPMessageGetResponseStatusCode(reply) == 200, "status 200");
	CHECK(strcmp(body, "plain body") == 0, "body received");
	CFReadStreamClose(stream);
	printf("%s\n", failures ? "FAILED" : "ALL PASSED");
	return failures;
}

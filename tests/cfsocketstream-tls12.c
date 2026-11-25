/* Copyright (C) 2026 Lubos Dolezel */
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>

/*
 * The default (negotiated) security level of an https read stream must offer TLS
 * versions up to 1.2, and kCFStreamSocketSecurityLevelTLSv1_2 must connect
 * with 1.2. Run against tests/cfurlconnection-test-server.py started
 * with a certificate and key (it accepts TLS 1.2 only).
 * usage: cfsocketstream-tls12 HTTPS_HOST_PORT_URL   e.g. https://127.0.0.1:8771/plain
 * The server's certificate is self-signed, so the test turns chain validation off on its
 * own stream; no library default is changed.
 * Prints PASS/FAIL lines; the exit status is the number of failures.
 */

/* the TLS 1.2-only level; not in the public headers */
extern const CFStringRef kCFStreamSocketSecurityLevelTLSv1_2;

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

	/* kCFStreamPropertySSLPeerTrust (macOS 10.5): after the handshake the stream has
	 * the server's trust, holding the certificate it presented */
	SecTrustRef trust = (SecTrustRef)CFReadStreamCopyProperty(stream, kCFStreamPropertySSLPeerTrust);
	CHECK(trust != NULL && CFGetTypeID(trust) == SecTrustGetTypeID(), "peer trust is a SecTrust");
	CHECK(trust != NULL && SecTrustGetCertificateCount(trust) >= 1, "peer trust holds the server certificate");
	if (trust)
		CFRelease(trust);
	CFReadStreamClose(stream);

	/* kCFStreamSocketSecurityLevelTLSv1_2 asks for TLS 1.2 alone, which the server speaks */
	CFReadStreamRef strict = CFReadStreamCreateForHTTPRequest(NULL, request);
	const void *strictKeys[] = { kCFStreamSSLValidatesCertificateChain, kCFStreamSSLLevel };
	const void *strictValues[] = { no, kCFStreamSocketSecurityLevelTLSv1_2 };
	CFDictionaryRef strictSSL = CFDictionaryCreate(NULL, strictKeys, strictValues, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFReadStreamSetProperty(strict, kCFStreamPropertySSLSettings, strictSSL);
	CHECK(CFReadStreamOpen(strict), "a TLS 1.2-only stream opens");
	while ((got = CFReadStreamRead(strict, buffer, sizeof(buffer))) > 0)
		;
	CFHTTPMessageRef strictReply = (CFHTTPMessageRef)CFReadStreamCopyProperty(strict, kCFStreamPropertyHTTPResponseHeader);
	CHECK(got == 0 && strictReply != NULL && CFHTTPMessageGetResponseStatusCode(strictReply) == 200,
	      "the TLS 1.2-only stream gets its response");
	if (strictReply)
		CFRelease(strictReply);
	CFReadStreamClose(strict);
	CFRelease(strict);
	CFRelease(strictSSL);
	printf("%s\n", failures ? "FAILED" : "ALL PASSED");
	return failures;
}

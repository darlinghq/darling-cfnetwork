// Copyright (C) 2026 Lubos Dolezel
#import <Foundation/Foundation.h>
#include <curl/curl.h>
#include "../src/URL/NSURLSessionCurlErrors.m"

// The mapping of libcurl results to NSURLErrorDomain codes, as a table (no network).
// build: guest-cc.sh -o t tests/nsurlsession-curl-error-map.m -Isrc/URL -I<curl include dir> -framework Foundation
// Prints PASS/FAIL lines; the exit status is the number of failures.

static int failures;

static void row(const char *name, int curlCode, long verifyResult, NSInteger expected)
{
    NSInteger code = _NSURLSessionErrorCodeForCurl(curlCode, verifyResult);
    printf("%s: %s (%ld, expected %ld)\n", code == expected ? "PASS" : "FAIL", name, (long)code, (long)expected);
    if (code != expected)
        failures++;
}

int main(void)
{
    row("host lookup", CURLE_COULDNT_RESOLVE_HOST, 0, NSURLErrorCannotFindHost);
    row("proxy lookup", CURLE_COULDNT_RESOLVE_PROXY, 0, NSURLErrorCannotFindHost);
    row("connection refused", CURLE_COULDNT_CONNECT, 0, NSURLErrorCannotConnectToHost);
    row("timeout", CURLE_OPERATION_TIMEDOUT, 0, NSURLErrorTimedOut);
    row("connection reset", CURLE_RECV_ERROR, 0, NSURLErrorNetworkConnectionLost);
    row("HTTP/2 framing error", CURLE_HTTP2, 0, NSURLErrorNetworkConnectionLost);
    row("HTTP/2 stream error", CURLE_HTTP2_STREAM, 0, NSURLErrorNetworkConnectionLost);
    row("too many redirects", CURLE_TOO_MANY_REDIRECTS, 0, NSURLErrorHTTPTooManyRedirects);
    row("aborted by the client", CURLE_ABORTED_BY_CALLBACK, 0, NSURLErrorCancelled);
    row("bad URL", CURLE_URL_MALFORMAT, 0, NSURLErrorBadURL);
    row("unsupported scheme", CURLE_UNSUPPORTED_PROTOCOL, 0, NSURLErrorUnsupportedURL);
    row("file not found", CURLE_REMOTE_FILE_NOT_FOUND, 0, NSURLErrorFileDoesNotExist);
    row("access denied", CURLE_REMOTE_ACCESS_DENIED, 0, NSURLErrorNoPermissionsToReadFile);
    row("login denied", CURLE_LOGIN_DENIED, 0, NSURLErrorUserAuthenticationRequired);
    row("file size exceeded", CURLE_FILESIZE_EXCEEDED, 0, NSURLErrorDataLengthExceedsMaximum);

    row("certificate expired", CURLE_PEER_FAILED_VERIFICATION, 10, NSURLErrorServerCertificateHasBadDate);
    row("CRL expired", CURLE_PEER_FAILED_VERIFICATION, 12, NSURLErrorServerCertificateHasBadDate);
    row("certificate not yet valid", CURLE_PEER_FAILED_VERIFICATION, 9, NSURLErrorServerCertificateNotYetValid);
    row("CRL not yet valid", CURLE_PEER_FAILED_VERIFICATION, 11, NSURLErrorServerCertificateNotYetValid);
    row("self-signed certificate", CURLE_PEER_FAILED_VERIFICATION, 18, NSURLErrorServerCertificateUntrusted);
    row("unknown issuer", CURLE_PEER_FAILED_VERIFICATION, 20, NSURLErrorServerCertificateUntrusted);
    row("host name mismatch (chain fine)", CURLE_PEER_FAILED_VERIFICATION, 0, NSURLErrorServerCertificateUntrusted);
    row("pinned key mismatch", CURLE_SSL_PINNEDPUBKEYNOTMATCH, 0, NSURLErrorServerCertificateUntrusted);
    row("TLS handshake failure", CURLE_SSL_CONNECT_ERROR, 0, NSURLErrorSecureConnectionFailed);
    row("TLS shutdown failure", CURLE_SSL_SHUTDOWN_FAILED, 0, NSURLErrorSecureConnectionFailed);
    row("client certificate rejected", CURLE_SSL_CERTPROBLEM, 0, NSURLErrorClientCertificateRejected);
    row("client certificate required", 98, 0, NSURLErrorClientCertificateRequired);
    row("anything else", CURLE_OUT_OF_MEMORY, 0, NSURLErrorUnknown);

    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures;
}

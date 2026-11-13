//
//  Copyright (C) 2026 Lubos Dolezel
//
//  Darling is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
#import "NSURLSessionCurlErrors.h"
#import <Foundation/NSURLError.h>
#include <curl/curl.h>

// Codes newer than the libcurl headers this is built with.
enum {
    kCurlAuthError = 94,         // CURLE_AUTH_ERROR
    kCurlSSLClientCert = 98      // CURLE_SSL_CLIENTCERT
};

// OpenSSL verification results that mean the date of a certificate or CRL is wrong.
enum {
    kVerifyCertNotYetValid = 9,
    kVerifyCertHasExpired = 10,
    kVerifyCRLNotYetValid = 11,
    kVerifyCRLHasExpired = 12
};

NSInteger _NSURLSessionErrorCodeForCurl(int code, long verifyResult)
{
    switch (code)
    {
        case CURLE_UNSUPPORTED_PROTOCOL:
            return NSURLErrorUnsupportedURL;
        case CURLE_URL_MALFORMAT:
            return NSURLErrorBadURL;
        case CURLE_COULDNT_RESOLVE_HOST:
        case CURLE_COULDNT_RESOLVE_PROXY:
            return NSURLErrorCannotFindHost;
        case CURLE_COULDNT_CONNECT:
            return NSURLErrorCannotConnectToHost;
        case CURLE_OPERATION_TIMEDOUT:
            return NSURLErrorTimedOut;
        case CURLE_SEND_ERROR:
        case CURLE_RECV_ERROR:
        case CURLE_PARTIAL_FILE:
        case CURLE_HTTP2:
        case CURLE_HTTP2_STREAM:
            return NSURLErrorNetworkConnectionLost;
        case CURLE_GOT_NOTHING:
        case CURLE_WEIRD_SERVER_REPLY:
            return NSURLErrorBadServerResponse;
        case CURLE_BAD_CONTENT_ENCODING:
            return NSURLErrorCannotDecodeContentData;
        case CURLE_TOO_MANY_REDIRECTS:
            return NSURLErrorHTTPTooManyRedirects;
        case CURLE_ABORTED_BY_CALLBACK:
            // the transfer was stopped from our side, which is what cancelling does
            return NSURLErrorCancelled;
        case CURLE_FILESIZE_EXCEEDED:
            return NSURLErrorDataLengthExceedsMaximum;
        case CURLE_FILE_COULDNT_READ_FILE:
        case CURLE_REMOTE_FILE_NOT_FOUND:
            return NSURLErrorFileDoesNotExist;
        case CURLE_REMOTE_ACCESS_DENIED:
            return NSURLErrorNoPermissionsToReadFile;
        case CURLE_LOGIN_DENIED:
        case kCurlAuthError:
            return NSURLErrorUserAuthenticationRequired;
        case CURLE_PEER_FAILED_VERIFICATION:
            // Only the date failures get their own codes. Every other failure of the certificate
            // chain (unknown or self-signed root, wrong host name) is -1202: macOS reports an
            // untrusted chain that way, even when the certificate is also expired.
            switch (verifyResult)
            {
                case kVerifyCertHasExpired:
                case kVerifyCRLHasExpired:
                    return NSURLErrorServerCertificateHasBadDate;
                case kVerifyCertNotYetValid:
                case kVerifyCRLNotYetValid:
                    return NSURLErrorServerCertificateNotYetValid;
                default:
                    return NSURLErrorServerCertificateUntrusted;
            }
        case CURLE_SSL_PINNEDPUBKEYNOTMATCH:
        case CURLE_SSL_INVALIDCERTSTATUS:
        case CURLE_SSL_ISSUER_ERROR:
            return NSURLErrorServerCertificateUntrusted;
        case CURLE_SSL_CONNECT_ERROR:
        case CURLE_SSL_CIPHER:
        case CURLE_SSL_CACERT_BADFILE:
        case CURLE_SSL_ENGINE_NOTFOUND:
        case CURLE_SSL_ENGINE_SETFAILED:
        case CURLE_SSL_SHUTDOWN_FAILED:
        case CURLE_SSL_CRL_BADFILE:
            return NSURLErrorSecureConnectionFailed;
        case CURLE_SSL_CERTPROBLEM:
            return NSURLErrorClientCertificateRejected;
        case kCurlSSLClientCert:
            return NSURLErrorClientCertificateRequired;
        default:
            return NSURLErrorUnknown;
    }
}

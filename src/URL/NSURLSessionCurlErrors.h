//
//  Copyright (C) 2026 Lubos Dolezel
//
//  Darling is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
// The NSURLErrorDomain code for a failed libcurl transfer.

#import <Foundation/NSObject.h>

// curlCode is a CURLcode; verifyResult is CURLINFO_SSL_VERIFYRESULT (an X509_V_ERR_* value from
// OpenSSL, 0 when unknown) and only refines certificate verification failures.
NSInteger _NSURLSessionErrorCodeForCurl(int curlCode, long verifyResult);

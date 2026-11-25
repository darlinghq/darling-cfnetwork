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

// Settings of a request that NSURLRequest's private methods read and write.
// Not exported.

#ifndef __CFURLREQUESTINTERNAL__
#define __CFURLREQUESTINTERNAL__

#include "CFURLRequest.h"

CF_EXTERN_C_BEGIN

#define _CFURLRequestHidden __attribute__((visibility("hidden")))

// Flags that are copied with the request and archived. The loader doesn't act
// on any of them yet: Darling has no HSTS upgrades, privacy proxy, tracker
// blocking or private access tokens.
typedef CF_OPTIONS(uint32_t, _CFURLRequestFlag) {
    _kCFURLRequestIgnoreHSTS = 1 << 0,
    _kCFURLRequestPreventHSTSStorage = 1 << 1,
    _kCFURLRequestSchemeWasUpgradedDueToDynamicHSTS = 1 << 2,
    _kCFURLRequestPrivacyProxyFailClosed = 1 << 3,
    _kCFURLRequestUseEnhancedPrivacyMode = 1 << 4,
    _kCFURLRequestPrivacyProxyFailClosedForUnreachableNonMainHosts = 1 << 5,
    _kCFURLRequestPrivacyProxyFailClosedForUnreachableHosts = 1 << 6,
    _kCFURLRequestNeedsNetworkTrackingPrevention = 1 << 7,
    _kCFURLRequestProhibitPrivacyProxy = 1 << 8,
    _kCFURLRequestBlockTrackers = 1 << 9,
    _kCFURLRequestAllowPrivateAccessTokensForThirdParty = 1 << 10,
    _kCFURLRequestWebSearchContent = 1 << 11,
    _kCFURLRequestPrivacyProxyStrictFailClosed = 1 << 12,
    _kCFURLRequestAllowOnlyPartitionedCookies = 1 << 13,
};

// The flags that two requests must share to be equal: all but the HSTS ones
// (observed on macOS 26.7.3; test: cfnetwork-request-private-settings).
#define _kCFURLRequestFlagsAffectingEquality \
    (~(_CFURLRequestFlag)(_kCFURLRequestIgnoreHSTS | _kCFURLRequestPreventHSTSStorage | \
                          _kCFURLRequestSchemeWasUpgradedDueToDynamicHSTS))

_CFURLRequestHidden Boolean _CFURLRequestGetFlag(CFURLRequestRef request, _CFURLRequestFlag flag);
_CFURLRequestHidden void _CFURLRequestSetFlag(CFMutableURLRequestRef request, _CFURLRequestFlag flag, Boolean value);

// The text encodings (CFStringEncodings in CFNumbers) to try, in order, for a
// Content-Disposition filename that isn't UTF-8. NSURLRequest gives and takes
// them as NSStringEncodings.
_CFURLRequestHidden CFArrayRef _CFURLRequestGetContentDispositionEncodingFallbackArray(CFURLRequestRef request);
_CFURLRequestHidden void _CFURLRequestSetContentDispositionEncodingFallbackArray(CFMutableURLRequestRef request, CFArrayRef encodings);

// The network interface the request is bound to, by name; NULL when it isn't bound. It is
// copied and archived with the request but doesn't affect equality (observed on macOS
// 26.7.3; test: nsurlrequest-network-settings). The loader doesn't act on it yet.
_CFURLRequestHidden CFStringRef _CFURLRequestGetBoundInterfaceIdentifier(CFURLRequestRef request);
_CFURLRequestHidden void _CFURLRequestSetBoundInterfaceIdentifier(CFMutableURLRequestRef request, CFStringRef identifier);

CF_EXTERN_C_END

#endif

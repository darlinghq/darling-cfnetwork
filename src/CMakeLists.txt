project(cfnetwork)

include(darling_framework)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -nostdinc \
	-include ${CMAKE_SOURCE_DIR}/src/external/corefoundation/macros.h")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -nostdinc -nostdinc++ \
	-include ${CMAKE_SOURCE_DIR}/src/external/corefoundation/macros.h")

include_directories(
	${CMAKE_CURRENT_SOURCE_DIR}
	${CMAKE_CURRENT_SOURCE_DIR}/SharedCode
	${CMAKE_CURRENT_SOURCE_DIR}/Proxies
	${CMAKE_CURRENT_SOURCE_DIR}/HTTP
	${CMAKE_CURRENT_SOURCE_DIR}/HTTP/SPNEGO
	${CMAKE_CURRENT_SOURCE_DIR}/Headers
	${CMAKE_CURRENT_SOURCE_DIR}/Utils
	${CMAKE_CURRENT_SOURCE_DIR}/../include
	${CMAKE_CURRENT_SOURCE_DIR}/../include/CFNetwork
	${CMAKE_CURRENT_SOURCE_DIR}/../private_include
	${CMAKE_CURRENT_SOURCE_DIR}/../private_include/CFNetwork
	${CMAKE_SOURCE_DIR}/src/launchd/liblaunch
	${CMAKE_SOURCE_DIR}/src/CommonCrypto
	${CMAKE_SOURCE_DIR}/src/libinfo/lookup.subproj
	${CMAKE_SOURCE_DIR}/src/external/corefoundation
	${CMAKE_SOURCE_DIR}/src/external/objc4/runtime
	${CMAKE_SOURCE_DIR}/src/external/libclosure
	${CMAKE_SOURCE_DIR}/src/external/zlib
	${CMAKE_SOURCE_DIR}/src/external/icu/icuSources/i18n
	${CMAKE_SOURCE_DIR}/src/external/icu/icuSources/common
	${CMAKE_SOURCE_DIR}/src/external/coretls/lib
	#${CMAKE_SOURCE_DIR}/src/external/configd/SystemConfiguration.fproj
	${CMAKE_SOURCE_DIR}/src/SystemConfiguration
	${CMAKE_SOURCE_DIR}/src/external/security/include
	${CMAKE_SOURCE_DIR}/src/external/security/include/Security
)

set(cfnetwork_sources
	resolv_stub.c
	Stream/CFSocketStream.c
	SharedCode/CFNetworkSchedule.c
	SharedCode/CFNetworkThreadSupport.c
	SharedCode/CFServer.c
	SharedCode/CFNetConnection.c
	SharedCode/CFError.c
	# JavaScriptGlue.c
	CFProxySupport.c
	URL/CFURLConnection.c
	URL/CFURLProtectionSpace.c
	URL/CFCachedURLResponse.c
	URL/CFURLCache.c
	URL/CFURLResponse.c
	URL/_CFURLAccess.c
	URL/CFURLAuthChallenge.c
	URL/CFURLRequest.c
	HTTP/CFHTTPServer.c
	HTTP/CFHTTPMessage.c
	HTTP/CFHTTPStream.c
	# HTTP/SPNEGO/spnegoKrb.cpp
	# HTTP/SPNEGO/spnegoDER.cpp
	# HTTP/SPNEGO/spnegoBlob.cpp
	HTTP/CFHTTPFilter.c
	#HTTP/NTLM/NtlmGenerator.cpp
	#HTTP/NTLM/ntlmBlobPriv.cpp
	HTTP/CFHTTPAuthentication.c
	HTTP/CFHTTPConnection.c
	CFNetServices.c # requires Bonjour
	Host/CFHost.c
	Proxies/ProxySupport.c
	Cookies/CFHTTPCookie.c
	Cookies/CFHTTPCookieStorage.c
	Utils/CFHTTPUtils.c
	Utils/CFFSUtils.c
	Utils/CFRuntimeUtils.c
	FTP/CFFTPStream.c
	#NetDiagnostics/CFNetDiagnosticsProtocolUser.c
	#NetDiagnostics/CFNetDiagnostics.c
	#NetDiagnostics/CFNetDiagnosticPing.c
	CFNetwork.c
	#libresolv.c
	#NetServices/DeprecatedDNSServiceDiscovery.c
	#NetServices/CFNetServices.c
	#NetServices/CFNetServiceMonitor.c
	#NetServices/CFNetServiceBrowser.c
	#security_cdsa_utils.c
	dnssd_stub.c
)

add_framework(CFNetwork
	FAT
	CURRENT_VERSION
	SOURCES
		${cfnetwork_sources}
	VERSION "A"
	DEPENDENCIES
		system
		CoreFoundation
		z
		CommonCrypto
		objc
		icucore
		SystemConfiguration
)

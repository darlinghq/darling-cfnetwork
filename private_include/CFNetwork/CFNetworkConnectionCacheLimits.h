#ifndef __CFNETWORKCONNECTIONCACHELIMITS__
#define __CFNETWORKCONNECTIONCACHELIMITS__

#include <CoreFoundation/CoreFoundation.h>

CF_EXTERN_C_BEGIN

// Keys of the HTTP connection cache limits. The numbers are the ones WebKit's
// PAL (CFNetworkConnectionCacheSPI.h) passes; other keys are accepted too.
enum HTTPConnectionCacheLimitKeys {
    kHTTPLoadWidth = 0,
    kHTTPPriorityNumLevels = 3,
    kHTTPNumFastLanes = 4,
    kHTTPMinimumFastLanePriority = 5,
};

// Returns the value last set for the key. macOS's initial values are not
// documented, so every limit starts at 0 here.
CF_EXPORT int _CFNetworkHTTPConnectionCacheGetLimit(enum HTTPConnectionCacheLimitKeys key);
CF_EXPORT void _CFNetworkHTTPConnectionCacheSetLimit(enum HTTPConnectionCacheLimitKeys key, int value);

CF_EXTERN_C_END

#endif

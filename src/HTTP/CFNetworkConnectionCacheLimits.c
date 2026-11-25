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

#include "CFNetworkConnectionCacheLimits.h"

// The limits a client sets for the HTTP connection cache (connections per
// host, number of priority levels, fast lanes). Darling's loaders do not
// schedule connections by them yet, so they are only kept and read back: a
// client such as WebKit reads the per-host width it set to size its own
// request scheduler.
#define CONNECTION_CACHE_LIMIT_COUNT 16

static int connectionCacheLimits[CONNECTION_CACHE_LIMIT_COUNT];

static Boolean isValidLimitKey(enum HTTPConnectionCacheLimitKeys key) {
    return (unsigned int)key < CONNECTION_CACHE_LIMIT_COUNT;
}

int _CFNetworkHTTPConnectionCacheGetLimit(enum HTTPConnectionCacheLimitKeys key) {
    if (!isValidLimitKey(key)) {
        return 0;
    }
    return __atomic_load_n(&connectionCacheLimits[key], __ATOMIC_RELAXED);
}

void _CFNetworkHTTPConnectionCacheSetLimit(enum HTTPConnectionCacheLimitKeys key, int value) {
    if (!isValidLimitKey(key)) {
        return;
    }
    __atomic_store_n(&connectionCacheLimits[key], value, __ATOMIC_RELAXED);
}

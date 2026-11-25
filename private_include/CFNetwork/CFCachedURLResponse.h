#ifndef __CFCACHEDURLRESPONSE__
#define __CFCACHEDURLRESPONSE__

#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFDictionary.h>
#include "CFURLResponse.h"

CF_EXTERN_C_BEGIN

typedef CF_ENUM(CFIndex, CFCachedURLStoragePolicy) {
    CFURLCacheStorageAllowed,
    CFURLCacheStorageAllowedInMemoryOnly,
    CFURLCacheStorageNotAllowed,
};

typedef struct _CFCachedURLResponse* CFCachedURLResponseRef;

// An HTTP response made from its message; the storage policy is not kept.
CF_EXPORT CFURLResponseRef CFURLResponseCreateWithHTTPResponse(CFAllocatorRef allocator, CFURLRef url,
                                                               CFHTTPMessageRef responseMessage,
                                                               CFCachedURLStoragePolicy storagePolicy);

CF_EXPORT CFCachedURLResponseRef CFCachedURLResponseCreate(CFAllocatorRef allocator,
                                                           CFURLResponseRef response,
                                                           CFTypeRef dataOrDataPath,
                                                           CFDictionaryRef userInfo,
                                                           CFCachedURLStoragePolicy storagePolicy);

CF_EXPORT CFURLResponseRef CFCachedURLResponseGetResponse(CFCachedURLResponseRef);
CF_EXPORT size_t CFCachedURLResponseGetDataSize(CFCachedURLResponseRef);
CF_EXPORT Boolean CFCachedURLResponseLoadData(CFCachedURLResponseRef, CFDataRef* data); // CFRelease() data
CF_EXPORT CFDictionaryRef CFCachedURLResponseGetUserInfo(CFCachedURLResponseRef);
CF_EXPORT CFCachedURLStoragePolicy CFCachedURLResponseGetStoragePolicy(CFCachedURLResponseRef);

// These functions return either 0 or CFCachedURLResponseGetDataSize().
CF_EXPORT size_t _CFCachedURLResponseGetMemorySize(CFCachedURLResponseRef);
CF_EXPORT size_t _CFCachedURLResponseGetDiskSize(CFCachedURLResponseRef);

CF_EXPORT Boolean _CFCachedURLResponseClaimOwnership(CFCachedURLResponseRef, const void* owner);
CF_EXPORT void _CFCachedURLResponseReleaseOwnership(CFCachedURLResponseRef, const void* owner);
CF_EXPORT Boolean _CFCachedURLResponseSetDataPath(CFCachedURLResponseRef, const void* owner, CFStringRef dataPath);
CF_EXPORT Boolean _CFCachedURLResponseEvictFromMemory(CFCachedURLResponseRef, const void* owner);
CF_EXPORT Boolean _CFCachedURLResponseCacheToMemory(CFCachedURLResponseRef, const void* owner);

// The response's data as a read-only mapping of the file that backs it, or
// NULL while the data is not in a file. The data lives as long as the response
// stays backed by the same file; retain it to keep it longer.
CF_EXPORT CFDataRef _CFCachedURLResponseGetMemMappedData(CFCachedURLResponseRef);

#if __BLOCKS__
#include <dispatch/dispatch.h>
// Runs `block` on `queue`, once, when the response's data comes to be kept in
// a file (at once if it already is). A later call replaces the block; a NULL
// block cancels it.
typedef void (^CFCachedURLResponseCallBackBlock)(CFCachedURLResponseRef);
CF_EXPORT void _CFCachedURLResponseSetBecameFileBackedCallBackBlock(CFCachedURLResponseRef, CFCachedURLResponseCallBackBlock block, dispatch_queue_t queue);
#endif

CF_EXTERN_C_END

#endif // __CFCACHEDURLRESPONSE__

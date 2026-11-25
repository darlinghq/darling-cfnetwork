//
//  CFCachedURLResponse.c
//  CFNetwork
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#include "CFCachedURLResponse.h"
#include "CFRuntime.h"
#include "CFFSUtils.h"
#include "CFRuntimeUtils.h"
#include <libkern/OSAtomic.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct _CFCachedURLResponse {
    CFRuntimeBase _base;
    OSSpinLock lock;
    CFURLResponseRef response;
    size_t dataSize;
    CFDataRef data;
    CFDictionaryRef userInfo;
    CFCachedURLStoragePolicy policy;
    const void* owner;
    CFStringRef dataPath;
    // a mapping of the file at dataPath, made on demand
    CFDataRef mappedData;
    // what to run when the data comes to be kept in a file
    CFCachedURLResponseCallBackBlock fileBackedBlock;
    dispatch_queue_t fileBackedQueue;
} _CFCachedURLResponse;


static Boolean loadCachedResponseData(CFCachedURLResponseRef, CFDataRef*);


/* Class */

static void cachedResponseDeallocate(CFTypeRef cf) {
    _CFCachedURLResponse* cachedResponse = (_CFCachedURLResponse *)cf;
    if (cachedResponse->response != NULL) {
        CFRelease(cachedResponse->response);
    }
    if (cachedResponse->data != NULL) {
        CFRelease(cachedResponse->data);
    }
    if (cachedResponse->userInfo != NULL) {
        CFRelease(cachedResponse->userInfo);
    }
    if (cachedResponse->dataPath != NULL) {
        CFRelease(cachedResponse->dataPath);
    }
    if (cachedResponse->mappedData != NULL) {
        CFRelease(cachedResponse->mappedData);
    }
    if (cachedResponse->fileBackedBlock != NULL) {
        Block_release(cachedResponse->fileBackedBlock);
        dispatch_release(cachedResponse->fileBackedQueue);
    }
}

static void takeFileBackedCallBack(_CFCachedURLResponse* cachedResponse,
                                   CFCachedURLResponseCallBackBlock* block,
                                   dispatch_queue_t* queue);
static void runFileBackedCallBack(CFCachedURLResponseRef cachedResponse,
                                  CFCachedURLResponseCallBackBlock block,
                                  dispatch_queue_t queue);

static CFTypeID cachedResponseTypeID = _kCFRuntimeNotATypeID;

static const CFRuntimeClass cachedResponseClass = {
    .version = 0,
    .className = "CFCachedURLResponse",
    .finalize = &cachedResponseDeallocate,
};

CFTypeID CFCachedURLResponseGetTypeID(void) {
    _CFRuntimeRegisterClassOnce(&cachedResponseTypeID, &cachedResponseClass);
    return cachedResponseTypeID;
}


/* API */

CFCachedURLResponseRef CFCachedURLResponseCreate(CFAllocatorRef allocator,
                                                 CFURLResponseRef response,
                                                 CFTypeRef dataOrDataPath,
                                                 CFDictionaryRef userInfo,
                                                 CFCachedURLStoragePolicy storagePolicy) {
    if (!response || !dataOrDataPath) {
        return NULL;
    }

    _CFCachedURLResponse* cachedResponse = (_CFCachedURLResponse*)_CFRuntimeCreateInstance(
        allocator,
        CFCachedURLResponseGetTypeID(),
        sizeof(_CFCachedURLResponse) - sizeof(CFRuntimeBase),
        NULL);
    if (!cachedResponse) {
        return NULL;
    }

    if (CFGetTypeID(dataOrDataPath) == CFDataGetTypeID()) {
        cachedResponse->data = CFDataCreateCopy(kCFAllocatorDefault, (CFDataRef)dataOrDataPath);
        cachedResponse->dataSize = CFDataGetLength(cachedResponse->data);
    } else if (CFGetTypeID(dataOrDataPath) == CFStringGetTypeID()) {
        cachedResponse->dataPath = CFStringCreateCopy(kCFAllocatorDefault, (CFStringRef)dataOrDataPath);
        struct stat dataStat = {0};
        if (_CFFSStat(cachedResponse->dataPath, &dataStat) || dataStat.st_size > SIZE_MAX) {
            CFRelease(cachedResponse);
            return NULL;
        }
        cachedResponse->dataSize = (size_t)dataStat.st_size;
    }

    if (userInfo) {
        cachedResponse->userInfo = CFDictionaryCreateCopy(kCFAllocatorDefault, userInfo);
    }

    cachedResponse->lock = OS_SPINLOCK_INIT;
    cachedResponse->response = (CFURLResponseRef)CFRetain(response);
    cachedResponse->policy = storagePolicy;

    return cachedResponse;
}

CFURLResponseRef CFCachedURLResponseGetResponse(CFCachedURLResponseRef cachedResponse) {
    return cachedResponse->response;
}

size_t CFCachedURLResponseGetDataSize(CFCachedURLResponseRef cachedResponse) {
    return cachedResponse->dataSize;
}

Boolean CFCachedURLResponseLoadData(CFCachedURLResponseRef cachedResponse, CFDataRef* data) {
    Boolean result = false;
    OSSpinLockLock(&cachedResponse->lock);
    {
        if (!cachedResponse->dataSize) {
            *data = NULL;
            result = true;
        } else {
            result = loadCachedResponseData(cachedResponse, data);
        }
    }
    OSSpinLockUnlock(&cachedResponse->lock);
    return result;
}

CFCachedURLStoragePolicy CFCachedURLResponseGetStoragePolicy(CFCachedURLResponseRef cachedResponse) {
    return cachedResponse->policy;
}

CFDictionaryRef CFCachedURLResponseGetUserInfo(CFCachedURLResponseRef cachedResponse) {
    return cachedResponse->userInfo;
}

size_t _CFCachedURLResponseGetDataSize(CFCachedURLResponseRef cachedResponse) {
    return cachedResponse->dataSize;
}

size_t _CFCachedURLResponseGetMemorySize(CFCachedURLResponseRef cachedResponse) {
    size_t result = 0;
    OSSpinLockLock(&cachedResponse->lock);
    {
        if (cachedResponse->data != 0) {
            result = cachedResponse->dataSize;
        }
    }
    OSSpinLockUnlock(&cachedResponse->lock);
    return result;
}

size_t _CFCachedURLResponseGetDiskSize(CFCachedURLResponseRef cachedResponse) {
    return (cachedResponse->policy == CFURLCacheStorageAllowed) ?
        cachedResponse->dataSize :
        0;
}

Boolean _CFCachedURLResponseClaimOwnership(CFCachedURLResponseRef cachedResponse,
                                           const void* owner) {
    if (!owner) {
        return false;
    }
    Boolean result = false;
    OSSpinLockLock(&cachedResponse->lock);
    {
        if (!cachedResponse->owner) {
            cachedResponse->owner = owner;
        }
        result = (cachedResponse->owner == owner);
    }
    OSSpinLockUnlock(&cachedResponse->lock);
    return result;
}

void _CFCachedURLResponseReleaseOwnership(CFCachedURLResponseRef cachedResponse,
                                          const void* owner)
{
    OSSpinLockLock(&cachedResponse->lock);
    {
        if (cachedResponse->owner == owner) {
            cachedResponse->owner = NULL;
        }
    }
    OSSpinLockUnlock(&cachedResponse->lock);
}

Boolean _CFCachedURLResponseSetDataPath(CFCachedURLResponseRef cachedResponse,
                                        const void* owner,
                                        CFStringRef dataPath)
{
    Boolean result = false;
    CFCachedURLResponseCallBackBlock block = NULL;
    dispatch_queue_t queue = NULL;
    OSSpinLockLock(&cachedResponse->lock);
    do {
        if (!owner || cachedResponse->owner != owner) {
            break;
        }
        if (cachedResponse->policy != CFURLCacheStorageAllowed) {
            break;
        }

        if (_CFFSIsSamePath(cachedResponse->dataPath, dataPath)) {
            result = true;
            break;
        }

        CFDataRef data = NULL;
        result = loadCachedResponseData(cachedResponse, &data);
        if (!result) {
            break;
        }

        if (dataPath) {
            result = _CFFSWriteDataToFile(data, dataPath);
        } else {
            if (!cachedResponse->data) {
                cachedResponse->data = (CFDataRef)CFRetain(data);
            }
            result = true;
        }
        CFRelease(data);

        if (result) {
            if (cachedResponse->dataPath) {
                _CFFSUnlink(cachedResponse->dataPath);
                CFRelease(cachedResponse->dataPath);
            }
            if (dataPath) {
                cachedResponse->dataPath = (CFStringRef)CFRetain(dataPath);
            } else {
                cachedResponse->dataPath = NULL;
            }
            // a mapping of the previous file is no longer the response's
            if (cachedResponse->mappedData) {
                CFRelease(cachedResponse->mappedData);
                cachedResponse->mappedData = NULL;
            }
            if (dataPath) {
                takeFileBackedCallBack(cachedResponse, &block, &queue);
            }
        }
    } while (0);
    OSSpinLockUnlock(&cachedResponse->lock);
    runFileBackedCallBack(cachedResponse, block, queue);
    return result;
}

Boolean _CFCachedURLResponseEvictFromMemory(CFCachedURLResponseRef cachedResponse,
                                            const void* owner)
{
    Boolean result = false;
    OSSpinLockLock(&cachedResponse->lock);
    do {
        if (!owner || cachedResponse->owner != owner) {
            break;
        }

        if (cachedResponse->dataPath) {
            if (cachedResponse->data) {
                CFRelease(cachedResponse->data);
                cachedResponse->data = NULL;
                result = true;
            }
        }
    } while(0);
    OSSpinLockUnlock(&cachedResponse->lock);
    return result;
}

Boolean _CFCachedURLResponseCacheToMemory(CFCachedURLResponseRef cachedResponse,
                                          const void* owner)
{
    Boolean result = false;
    OSSpinLockLock(&cachedResponse->lock);
    do {
        if (!owner || cachedResponse->owner != owner) {
            break;
        }

        if (cachedResponse->data) {
            result = true;
        } else {
            result = _CFFSCreateDataFromFile(&cachedResponse->data, cachedResponse->dataPath);
        }
    } while (0);
    OSSpinLockUnlock(&cachedResponse->lock);
    return result;
}


static void unmapData(void* info, void* bytes) {
    munmap(bytes, (size_t)(uintptr_t)info);
}

static CFDataRef createMappedData(CFStringRef path) {
    char filePath[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation(path, filePath, sizeof(filePath))) {
        return NULL;
    }
    int fd = open(filePath, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return NULL;
    }
    struct stat fileStat;
    CFDataRef result = NULL;
    if (fstat(fd, &fileStat) == 0 && fileStat.st_size > 0 && (uintmax_t)fileStat.st_size <= SIZE_MAX) {
        size_t length = (size_t)fileStat.st_size;
        void* bytes = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
        if (bytes != MAP_FAILED) {
            CFAllocatorContext context = {
                .info = (void*)(uintptr_t)length,
                .deallocate = (CFAllocatorDeallocateCallBack)unmapData,
            };
            CFAllocatorRef deallocator = CFAllocatorCreate(kCFAllocatorDefault, &context);
            result = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, bytes, (CFIndex)length, deallocator);
            CFRelease(deallocator);
            if (!result) {
                munmap(bytes, length);
            }
        }
    }
    close(fd);
    return result;
}

CFDataRef _CFCachedURLResponseGetMemMappedData(CFCachedURLResponseRef cachedResponse) {
    CFStringRef path = NULL;
    OSSpinLockLock(&cachedResponse->lock);
    {
        if (cachedResponse->mappedData) {
            CFDataRef data = cachedResponse->mappedData;
            OSSpinLockUnlock(&cachedResponse->lock);
            return data;
        }
        if (cachedResponse->dataPath) {
            path = (CFStringRef)CFRetain(cachedResponse->dataPath);
        }
    }
    OSSpinLockUnlock(&cachedResponse->lock);
    if (!path) {
        return NULL;
    }

    // Mapped without the lock held; the mapping is kept only if the same file
    // still backs the response.
    CFDataRef mapped = createMappedData(path);
    CFDataRef result = NULL;
    OSSpinLockLock(&cachedResponse->lock);
    {
        if (cachedResponse->mappedData) {
            result = cachedResponse->mappedData;
        } else if (mapped && cachedResponse->dataPath && CFEqual(cachedResponse->dataPath, path)) {
            cachedResponse->mappedData = (CFDataRef)CFRetain(mapped);
            result = cachedResponse->mappedData;
        }
    }
    OSSpinLockUnlock(&cachedResponse->lock);
    if (mapped) {
        CFRelease(mapped);
    }
    CFRelease(path);
    return result;
}

void _CFCachedURLResponseSetBecameFileBackedCallBackBlock(CFCachedURLResponseRef cachedResponse,
                                                          CFCachedURLResponseCallBackBlock block,
                                                          dispatch_queue_t queue)
{
    CFCachedURLResponseCallBackBlock newBlock = (block && queue) ? Block_copy(block) : NULL;
    if (newBlock) {
        dispatch_retain(queue);
    }
    CFCachedURLResponseCallBackBlock oldBlock = NULL;
    dispatch_queue_t oldQueue = NULL;
    CFCachedURLResponseCallBackBlock runBlock = NULL;
    dispatch_queue_t runQueue = NULL;
    OSSpinLockLock(&cachedResponse->lock);
    {
        oldBlock = cachedResponse->fileBackedBlock;
        oldQueue = cachedResponse->fileBackedQueue;
        cachedResponse->fileBackedBlock = newBlock;
        cachedResponse->fileBackedQueue = newBlock ? queue : NULL;
        // QUIRK: Not documented. A response whose data is already in a file
        // runs the block at once, so that a caller does not wait for an event
        // that has already happened. Evidence: inference only, from the
        // purpose of the call; not observed on macOS (weakest tier, needs
        // maintainer approval).
        // Test: tests/cachedurlresponse-file-backed.c ("quirk: a response
        // already in a file runs the block at once")
        if (newBlock && cachedResponse->dataPath) {
            takeFileBackedCallBack(cachedResponse, &runBlock, &runQueue);
        }
    }
    OSSpinLockUnlock(&cachedResponse->lock);
    if (oldBlock) {
        Block_release(oldBlock);
        dispatch_release(oldQueue);
    }
    runFileBackedCallBack(cachedResponse, runBlock, runQueue);
}


/* Private */

// Called with the lock held: hands over the pending block, which runs once.
static void takeFileBackedCallBack(_CFCachedURLResponse* cachedResponse,
                                   CFCachedURLResponseCallBackBlock* block,
                                   dispatch_queue_t* queue)
{
    *block = cachedResponse->fileBackedBlock;
    *queue = cachedResponse->fileBackedQueue;
    cachedResponse->fileBackedBlock = NULL;
    cachedResponse->fileBackedQueue = NULL;
}

// Called without the lock: runs a handed-over block on its queue.
static void runFileBackedCallBack(CFCachedURLResponseRef cachedResponse,
                                  CFCachedURLResponseCallBackBlock block,
                                  dispatch_queue_t queue)
{
    if (!block) {
        return;
    }
    CFRetain(cachedResponse);
    dispatch_async(queue, ^{
        block(cachedResponse);
        Block_release(block);
        CFRelease(cachedResponse);
    });
    dispatch_release(queue);
}

static Boolean loadCachedResponseData(CFCachedURLResponseRef cachedResponse, CFDataRef* data) {
    if (cachedResponse->data) {
        *data = (CFDataRef)CFRetain(cachedResponse->data);
        return true;
    } else {
        return _CFFSCreateDataFromFile(data, cachedResponse->dataPath);
    }
}

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// The file backing of a cached response, as WebKit's DiskCacheMonitor uses it:
// - a response whose data is in memory has no mapped data;
// - one whose data is in a file maps that file, with its contents, and gives
//   the same mapping each time;
// - the block set with _CFCachedURLResponseSetBecameFileBackedCallBackBlock
//   runs on its queue once the cache moves the data into a file;
// - quirk: a response already in a file runs the block at once (see the
//   QUIRK comment in CFCachedURLResponse.c; inferred, not observed on macOS).
// The functions are private, so they are declared here.

typedef const struct _CFURLResponse *CFURLResponseRef;
typedef struct _CFCachedURLResponse *CFCachedURLResponseRef;
typedef void (^CFCachedURLResponseCallBackBlock)(CFCachedURLResponseRef);

extern CFURLResponseRef CFURLResponseCreate(CFAllocatorRef, CFURLRef, CFStringRef, int64_t, CFStringRef);
extern CFCachedURLResponseRef CFCachedURLResponseCreate(CFAllocatorRef, CFURLResponseRef, CFTypeRef, CFDictionaryRef, CFIndex);
extern Boolean _CFCachedURLResponseClaimOwnership(CFCachedURLResponseRef, const void *);
extern Boolean _CFCachedURLResponseSetDataPath(CFCachedURLResponseRef, const void *, CFStringRef);
extern CFDataRef _CFCachedURLResponseGetMemMappedData(CFCachedURLResponseRef);
extern void _CFCachedURLResponseSetBecameFileBackedCallBackBlock(CFCachedURLResponseRef, CFCachedURLResponseCallBackBlock, dispatch_queue_t);

static int failures = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); failures++; } else printf("PASS: %s\n", msg); } while (0)

static const char contents[] = "cached response body";

// Waits for the semaphore, for at most two seconds.
static int signalled(dispatch_semaphore_t semaphore)
{
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
}

int main(void)
{
    const char *tmp = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    char path[1024];
    snprintf(path, sizeof path, "%s/cachedurlresponse-file-backed-%d", tmp, (int)getpid());
    CFStringRef dataPath = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);

    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, CFSTR("http://example.org/"), NULL);
    CFURLResponseRef response = CFURLResponseCreate(kCFAllocatorDefault, url, CFSTR("text/plain"), sizeof contents - 1, NULL);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)contents, sizeof contents - 1);
    CFCachedURLResponseRef cached = CFCachedURLResponseCreate(kCFAllocatorDefault, response, data, NULL, 0 /* allowed */);
    EXPECT(cached != NULL, "a cached response can be made from data");
    EXPECT(_CFCachedURLResponseGetMemMappedData(cached) == NULL, "data kept in memory has no mapping");

    dispatch_queue_t queue = dispatch_queue_create("org.darlinghq.test", NULL);
    dispatch_semaphore_t moved = dispatch_semaphore_create(0);
    __block CFCachedURLResponseRef calledWith = NULL;
    _CFCachedURLResponseSetBecameFileBackedCallBackBlock(cached, ^(CFCachedURLResponseRef r) {
        calledWith = r;
        dispatch_semaphore_signal(moved);
    }, queue);

    static const int owner = 0;
    EXPECT(_CFCachedURLResponseClaimOwnership(cached, &owner), "the cache can own the response");
    EXPECT(_CFCachedURLResponseSetDataPath(cached, &owner, dataPath), "the data can be moved into a file");
    EXPECT(signalled(moved) && calledWith == cached, "moving the data into a file runs the block with the response");

    CFDataRef mapped = _CFCachedURLResponseGetMemMappedData(cached);
    EXPECT(mapped != NULL && CFDataGetLength(mapped) == (CFIndex)(sizeof contents - 1)
           && memcmp(CFDataGetBytePtr(mapped), contents, sizeof contents - 1) == 0,
           "the mapping has the file's contents");
    EXPECT(_CFCachedURLResponseGetMemMappedData(cached) == mapped, "the mapping is the same each time");

    dispatch_semaphore_t atOnce = dispatch_semaphore_create(0);
    _CFCachedURLResponseSetBecameFileBackedCallBackBlock(cached, ^(CFCachedURLResponseRef r) {
        dispatch_semaphore_signal(atOnce);
    }, queue);
    EXPECT(signalled(atOnce), "quirk: a response already in a file runs the block at once");

    CFRelease(cached);
    CFRelease(data);
    CFRelease(response);
    CFRelease(url);
    CFRelease(dataPath);
    unlink(path);
    dispatch_release(queue);

    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

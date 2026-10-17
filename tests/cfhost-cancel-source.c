#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#include <stdio.h>

// CFHostCancelInfoResolution schedules a cancel source that must keep the host alive until it
// is delivered, and must not keep it alive once it can no longer be delivered.
// usage: cfhost-cancel-source   (no network needed, resolves "localhost")

static int failures = 0;
static int callbacks = 0;

#define EXPECT(cond, msg) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); failures++; } } while (0)

static void hostCallback(CFHostRef host, CFHostInfoType type, const CFStreamError *error, void *info)
{
    (void)host; (void)type; (void)error; (void)info;
    callbacks++;
}

static CFHostRef startAndCancel(void)
{
    CFHostRef host = CFHostCreateWithName(kCFAllocatorDefault, CFSTR("localhost"));
    CFHostClientContext ctx = { 0, NULL, NULL, NULL, NULL };
    CFHostSetClient(host, hostCallback, &ctx);
    CFHostScheduleWithRunLoop(host, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFHostStartInfoResolution(host, kCFHostAddresses, NULL);
    CFHostCancelInfoResolution(host, kCFHostAddresses);
    return host;
}

int main(void)
{
    // The caller drops its reference right after cancelling: the source owns the host until
    // the cancel is delivered. Before the fix the source had no context and trapped in
    // _HostCancel(NULL).
    CFHostRef host = startAndCancel();
    CFRelease(host);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    EXPECT(callbacks == 1, "cancel delivered exactly one callback after the caller released the host");

    // SetClient(NULL) tears the pending cancel source down and drops its reference.
    host = startAndCancel();
    CFHostSetClient(host, NULL, NULL);
    EXPECT(CFGetRetainCount(host) == 1, "SetClient(NULL) releases the cancel source's reference");
    CFRelease(host);

    // Unscheduling from the last run loop makes delivery impossible: no reference may remain.
    host = startAndCancel();
    CFHostUnscheduleFromRunLoop(host, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    EXPECT(CFGetRetainCount(host) == 1, "Unschedule from the last run loop releases the cancel source's reference");
    CFRelease(host);

    if (failures)
        return 1;
    printf("PASS\n");
    return 0;
}

// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: the App Transport Security context SPI.
// - _CFNetworkCopyATSContext gives property list data holding a dictionary,
//   and the same data again later.
// - Quirk: _CFNetworkSetATSContext returns false, for the process's own
//   context, for data that is not a property list and for NULL, and the
//   context copied afterwards is unchanged.
// Expected values were observed on macOS 26.7.3 (x86_64) with the same calls.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

extern CFDataRef _CFNetworkCopyATSContext(void);
extern Boolean _CFNetworkSetATSContext(CFDataRef);

static int failures;

static void report(const char *name, int ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok)
        failures++;
}

int main(void)
{
    CFDataRef context = _CFNetworkCopyATSContext();
    CFPropertyListRef plist = context != NULL ? CFPropertyListCreateWithData(NULL, context, 0, NULL, NULL) : NULL;
    report("copy: a dictionary", plist != NULL && CFGetTypeID(plist) == CFDictionaryGetTypeID());

    report("quirk: set returns false: own context", !_CFNetworkSetATSContext(context));
    CFDataRef garbage = CFDataCreate(NULL, (const UInt8 *) "x", 1);
    report("quirk: set returns false: garbage", !_CFNetworkSetATSContext(garbage));
    report("quirk: set returns false: NULL", !_CFNetworkSetATSContext(NULL));

    CFDataRef again = _CFNetworkCopyATSContext();
    report("copy: unchanged", context != NULL && again != NULL && CFEqual(context, again));

    if (again != NULL) CFRelease(again);
    CFRelease(garbage);
    if (plist != NULL) CFRelease(plist);
    if (context != NULL) CFRelease(context);
    return failures != 0;
}

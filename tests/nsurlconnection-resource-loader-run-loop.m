// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: +[NSURLConnection resourceLoaderRunLoop], the SPI that WebKit's
// network process schedules its cookie storage on. Observed on macOS 26.7.3
// (x86_64) with the same calls: it returns a CFRunLoopRef, the same one on
// every call and from every thread, that is neither the main run loop nor the
// caller's, and that runs blocks scheduled in the default and the common
// modes on a background thread named com.apple.NSURLConnectionLoader.
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

@interface NSURLConnection (ResourceLoaderSPI)
+ (CFRunLoopRef)resourceLoaderRunLoop;
@end

static int failures;

static void report(const char *name, BOOL ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok)
        failures++;
}

static volatile int ran;
static volatile BOOL ranOnMainThread;
static char threadName[64];

static BOOL waitFor(volatile int *flag)
{
    for (int i = 0; i < 100 && !*flag; i++)
        usleep(20000);
    return *flag != 0;
}

static void *otherThread(void *result)
{
    *(CFRunLoopRef *)result = [NSURLConnection resourceLoaderRunLoop];
    return NULL;
}

int main(void)
{
    @autoreleasepool {
        CFRunLoopRef loop = [NSURLConnection resourceLoaderRunLoop];
        report("a run loop", loop != NULL && CFGetTypeID(loop) == CFRunLoopGetTypeID());
        report("the same on every call", loop == [NSURLConnection resourceLoaderRunLoop]);
        report("not the main run loop", loop != CFRunLoopGetMain());
        report("not the caller's", loop != CFRunLoopGetCurrent());

        pthread_t thread;
        CFRunLoopRef fromOtherThread = NULL;
        pthread_create(&thread, NULL, otherThread, &fromOtherThread);
        pthread_join(thread, NULL);
        report("the same from another thread", fromOtherThread == loop);

        ran = 0;
        CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, ^{
            ranOnMainThread = [NSThread isMainThread];
            pthread_getname_np(pthread_self(), threadName, sizeof threadName);
            ran = 1;
        });
        CFRunLoopWakeUp(loop);
        report("runs blocks in the default mode", waitFor(&ran));
        report("on a background thread", ran && !ranOnMainThread);
        report("named com.apple.NSURLConnectionLoader", ran && strcmp(threadName, "com.apple.NSURLConnectionLoader") == 0);

        ran = 0;
        CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ ran = 1; });
        CFRunLoopWakeUp(loop);
        report("runs blocks in the common modes", waitFor(&ran));
    }
    return failures != 0;
}

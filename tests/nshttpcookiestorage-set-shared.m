// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: +[NSHTTPCookieStorage _setSharedHTTPCookieStorage:], the SPI that
// WebKit's network process uses to make the UI process's cookie storage the
// shared one. Observed on macOS 26.7.3 (x86_64) with the same calls:
// - set before anything asks for the shared storage, the object becomes the
//   shared storage on every thread, and cookies set through it are its own;
// - set a second time, or after the shared storage was asked for, the process
//   aborts (SIGABRT). Each of those cases runs in a forked child.
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct __CFHTTPCookieStorage *CFHTTPCookieStorageRef;
extern CFHTTPCookieStorageRef CFHTTPCookieStorageCreateFromFile(CFAllocatorRef, CFURLRef, CFHTTPCookieStorageRef);

@interface NSHTTPCookieStorage (SetSharedSPI)
+ (void)_setSharedHTTPCookieStorage:(NSHTTPCookieStorage *)storage;
- (id)_initWithCFHTTPCookieStorage:(CFHTTPCookieStorageRef)storage;
@end

static int failures;

static void report(const char *name, BOOL ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    fflush(stdout);
    if (!ok)
        failures++;
}

static NSHTTPCookieStorage *makeStorage(NSString *path)
{
    CFHTTPCookieStorageRef cf = CFHTTPCookieStorageCreateFromFile(NULL, (CFURLRef) [NSURL fileURLWithPath: path], NULL);
    NSHTTPCookieStorage *storage = [[[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage: cf] autorelease];
    CFRelease(cf);
    return storage;
}

static BOOL abortsInChild(void (*body)(void))
{
    fflush(stdout);
    pid_t child = fork();
    if (child == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        dup2(devnull, STDERR_FILENO);
        @autoreleasepool {
            body();
        }
        _exit(0);
    }
    int status = 0;
    waitpid(child, &status, 0);
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

static void setTwice(void)
{
    [NSHTTPCookieStorage _setSharedHTTPCookieStorage: makeStorage(@"/tmp/set-shared-a.binarycookies")];
    [NSHTTPCookieStorage _setSharedHTTPCookieStorage: makeStorage(@"/tmp/set-shared-b.binarycookies")];
}

static void setAfterUse(void)
{
    [NSHTTPCookieStorage sharedHTTPCookieStorage];
    [NSHTTPCookieStorage _setSharedHTTPCookieStorage: makeStorage(@"/tmp/set-shared-a.binarycookies")];
}

static NSHTTPCookieStorage *seenOnOtherThread;

static void *otherThread(void *unused)
{
    seenOnOtherThread = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    return NULL;
}

int main(void)
{
    @autoreleasepool {
        report("set twice: aborts", abortsInChild(setTwice));
        report("set after use: aborts", abortsInChild(setAfterUse));

        NSString *path = [NSString stringWithFormat: @"/tmp/set-shared-%d.binarycookies", (int)getpid()];
        NSHTTPCookieStorage *mine = makeStorage(path);
        [NSHTTPCookieStorage _setSharedHTTPCookieStorage: mine];
        report("becomes the shared storage", [NSHTTPCookieStorage sharedHTTPCookieStorage] == mine);

        pthread_t thread;
        pthread_create(&thread, NULL, otherThread, NULL);
        pthread_join(thread, NULL);
        report("on every thread", seenOnOtherThread == mine);

        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties: @{ NSHTTPCookieName: @"n", NSHTTPCookieValue: @"v",
            NSHTTPCookieDomain: @"example.com", NSHTTPCookiePath: @"/" }];
        [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie: cookie];
        report("cookies go to it", mine.cookies.count == 1);
        [mine removeCookiesSinceDate: [NSDate distantPast]];
        [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
    }
    return failures != 0;
}

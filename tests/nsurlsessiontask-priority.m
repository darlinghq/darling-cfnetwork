// Copyright (C) 2026 Lubos Dolezel
//
// NSURLSessionTask's priority: the constants, the default of data and
// download tasks, values from 0 to 1 at any time in the task's life, and
// (a quirk) values out of that range, which are ignored. Values match
// macOS 26.7.3 and Mac OS X 10.14.4, where the program builds and runs too.
// Nothing is transferred: the tasks are cancelled, and the address refuses.
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>

static int failures;

static void expect(BOOL ok, const char *what)
{
    printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        failures++;
}

int main(void)
{
    @autoreleasepool {
        expect(NSURLSessionTaskPriorityDefault == 0.5f && NSURLSessionTaskPriorityLow == 0.25f
                   && NSURLSessionTaskPriorityHigh == 0.75f,
               "the priority constants");

        NSURLSession *session = [NSURLSession sessionWithConfiguration: [NSURLSessionConfiguration ephemeralSessionConfiguration]];
        NSURL *url = [NSURL URLWithString: @"http://127.0.0.1:1/"];
        NSURLSessionDataTask *task = [session dataTaskWithURL: url];
        NSURLSessionDownloadTask *download = [session downloadTaskWithURL: url];
        expect(task.priority == NSURLSessionTaskPriorityDefault, "a data task starts at the default priority");
        expect(download.priority == NSURLSessionTaskPriorityDefault, "a download task starts at the default priority");

        task.priority = 0.25f;
        expect(task.priority == 0.25f, "a priority reads back");
        task.priority = 0;
        expect(task.priority == 0, "0 is taken");
        task.priority = 1;
        expect(task.priority == 1, "1 is taken");

        float outOfRange[] = { -1, 2, 1.0001f, -0.0001f, INFINITY };
        BOOL ignored = YES;
        for (unsigned i = 0; i < sizeof outOfRange / sizeof outOfRange[0]; i++) {
            task.priority = 0.6f;
            task.priority = outOfRange[i];
            ignored &= task.priority == 0.6f;
            download.priority = 0.6f;
            download.priority = outOfRange[i];
            ignored &= download.priority == 0.6f;
        }
        expect(ignored, "quirk: a priority out of range is ignored");
        task.priority = NAN;
        expect(isnan(task.priority), "quirk: NaN is taken");

        [task resume];
        task.priority = 0.9f;
        expect(task.priority == 0.9f, "the priority changes after resume");
        [task cancel];
        task.priority = 0.3f;
        expect(task.priority == 0.3f, "the priority changes after cancel");
        [download cancel];
        [session invalidateAndCancel];
    }
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

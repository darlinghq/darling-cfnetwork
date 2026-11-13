// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: NSURLRequest allowsExpensiveNetworkAccess and
// allowsConstrainedNetworkAccess default to YES, can be changed on a mutable
// request, survive copy and mutableCopy, and round trip through keyed archiving.
#import <Foundation/Foundation.h>
#include <stdio.h>

static int failures;
static void expect(BOOL condition, NSString *label)
{
    printf("%s %s\n", condition ? "PASS" : "FAIL", [label UTF8String]);
    failures += !condition;
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSURL *url = [NSURL URLWithString: @"http://example.test/"];

    NSURLRequest *plain = [NSURLRequest requestWithURL: url];
    expect([plain allowsExpensiveNetworkAccess] && [plain allowsConstrainedNetworkAccess], @"both default to YES");

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL: url];
    expect([r allowsExpensiveNetworkAccess] && [r allowsConstrainedNetworkAccess], @"mutable request defaults to YES");
    [r setAllowsExpensiveNetworkAccess: NO];
    expect(![r allowsExpensiveNetworkAccess] && [r allowsConstrainedNetworkAccess], @"expensive flag is independent");
    [r setAllowsConstrainedNetworkAccess: NO];
    expect(![r allowsExpensiveNetworkAccess] && ![r allowsConstrainedNetworkAccess], @"constrained flag is set");
    expect([r allowsCellularAccess], @"cellular flag is unchanged");

    NSURLRequest *copy = [[r copy] autorelease];
    expect(![copy allowsExpensiveNetworkAccess] && ![copy allowsConstrainedNetworkAccess], @"copy keeps the flags");
    NSMutableURLRequest *mcopy = [[r mutableCopy] autorelease];
    expect(![mcopy allowsExpensiveNetworkAccess] && ![mcopy allowsConstrainedNetworkAccess], @"mutableCopy keeps the flags");
    [mcopy setAllowsExpensiveNetworkAccess: YES];
    expect([mcopy allowsExpensiveNetworkAccess] && ![r allowsExpensiveNetworkAccess], @"changing the copy leaves the original");

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject: r];
    NSURLRequest *back = [NSKeyedUnarchiver unarchiveObjectWithData: data];
    expect(back != nil && ![back allowsExpensiveNetworkAccess] && ![back allowsConstrainedNetworkAccess], @"keyed archive round trip keeps NO");
    data = [NSKeyedArchiver archivedDataWithRootObject: plain];
    back = [NSKeyedUnarchiver unarchiveObjectWithData: data];
    expect(back != nil && [back allowsExpensiveNetworkAccess] && [back allowsConstrainedNetworkAccess], @"keyed archive round trip keeps YES");

    [pool drain];
    return failures ? 1 : 0;
}

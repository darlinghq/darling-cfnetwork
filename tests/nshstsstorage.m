// Copyright (C) 2026 Lubos Dolezel
//
// Guest test: _NSHSTSStorage and NSURLSessionConfiguration's _hstsStorage.
// - A store made on a directory or on nil exists, lists no non-preloaded host
//   and takes resets of a host or since a date.
// - A host the process has never loaded is not promoted to HTTPS.
// - Default and ephemeral configurations come with a store each.
// - Quirk: an ephemeral configuration refuses a store kept on disk with
//   NSInvalidArgumentException; a default one takes it.
// Expected values were observed on macOS 26.7.3 (x86_64) with the same calls.
// (macOS also promotes hosts of its preloaded list, which Darling does not
// have, so no preloaded host is checked.)
#import <Foundation/Foundation.h>

@interface _NSHSTSStorage : NSObject
- (instancetype)initPersistentStoreWithURL:(NSURL *)url;
- (BOOL)shouldPromoteHostToHTTPS:(NSString *)host;
- (NSArray *)nonPreloadedHosts;
- (void)resetHSTSForHost:(NSString *)host;
- (void)resetHSTSHostsSinceDate:(NSDate *)date;
@end

@interface NSURLSessionConfiguration (HSTS)
@property (retain) _NSHSTSStorage *_hstsStorage;
@end

static int failures;

static void report(const char *name, BOOL ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok)
        failures++;
}

int main(void)
{
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat: @"nshstsstorage-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: NULL];
        _NSHSTSStorage *persistent = [[[_NSHSTSStorage alloc] initPersistentStoreWithURL: [NSURL fileURLWithPath: dir isDirectory: YES]] autorelease];
        _NSHSTSStorage *memory = [[[_NSHSTSStorage alloc] initPersistentStoreWithURL: nil] autorelease];
        report("stores", persistent != nil && memory != nil);
        report("no non-preloaded hosts", [[persistent nonPreloadedHosts] count] == 0 && [[memory nonPreloadedHosts] count] == 0);
        report("unknown host not promoted", ![persistent shouldPromoteHostToHTTPS: @"example.com"]
               && ![memory shouldPromoteHostToHTTPS: @"example.com"]);
        [persistent resetHSTSForHost: @"example.com"];
        [persistent resetHSTSHostsSinceDate: [NSDate distantPast]];
        report("resets", [[persistent nonPreloadedHosts] count] == 0);

        NSURLSessionConfiguration *defaultConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLSessionConfiguration *ephemeral = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        report("default configuration has a store", [defaultConfiguration._hstsStorage isKindOfClass: [_NSHSTSStorage class]]);
        report("ephemeral configuration has a store", [ephemeral._hstsStorage isKindOfClass: [_NSHSTSStorage class]]);

        defaultConfiguration._hstsStorage = persistent;
        report("default configuration takes a persistent store", defaultConfiguration._hstsStorage == persistent);
        report("copy keeps the store", ((NSURLSessionConfiguration *) [[defaultConfiguration copy] autorelease])._hstsStorage == persistent);
        NSURLSession *session = [NSURLSession sessionWithConfiguration: defaultConfiguration];
        report("session keeps the store", session.configuration._hstsStorage == persistent);
        [session invalidateAndCancel];

        BOOL raised = NO;
        @try {
            ephemeral._hstsStorage = persistent;
        } @catch (NSException *exception) {
            raised = [exception.name isEqualToString: NSInvalidArgumentException];
        }
        report("quirk: ephemeral configuration refuses a persistent store", raised);
        ephemeral._hstsStorage = memory;
        report("ephemeral configuration takes an in-memory store", ephemeral._hstsStorage == memory);

        [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
    }
    return failures != 0;
}

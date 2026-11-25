#import <Foundation/NSObject.h>

@class NSArray, NSDate, NSString, NSURL;

// The HSTS hosts a session configuration uses (_hstsStorage). Darling's loader records none.
@interface _NSHSTSStorage : NSObject {
    NSURL *_url;
}
// Kept in the directory at the URL, or in memory only when it is nil.
- (instancetype)initPersistentStoreWithURL:(NSURL *)url;
- (instancetype)initInMemoryStore;
- (BOOL)shouldPromoteHostToHTTPS:(NSString *)host;
- (NSArray *)nonPreloadedHosts;
- (void)resetHSTSForHost:(NSString *)host;
- (void)resetHSTSHostsSinceDate:(NSDate *)date;
@end

@interface _NSHSTSStorage (Internal)
- (BOOL)_isPersistent;
@end

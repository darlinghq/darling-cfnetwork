//
//  NSHSTSStorage.m
//  CFNetwork
//
//  Copyright (C) 2026 Lubos Dolezel
//
//  The store of hosts that must be loaded over HTTPS (HTTP Strict Transport
//  Security, RFC 6797) that a session configuration names. Darling's loader
//  records no HSTS hosts and has no preloaded list, so the store holds no host:
//  none is promoted to HTTPS, and resetting does nothing.
//

#import "NSHSTSStorage.h"
#import <Foundation/NSArray.h>
#import <Foundation/NSURL.h>

@implementation _NSHSTSStorage

// A store kept in the directory, or in memory only when the URL is nil. Nothing is written,
// since the store holds no host.
- (instancetype)initPersistentStoreWithURL:(NSURL *)url
{
    self = [super init];
    if (self != nil)
        _url = [url copy];
    return self;
}

- (instancetype)initInMemoryStore
{
    return [self initPersistentStoreWithURL:nil];
}

- (void)dealloc
{
    [_url release];
    [super dealloc];
}

- (BOOL)_isPersistent
{
    return _url != nil;
}

- (BOOL)shouldPromoteHostToHTTPS:(NSString *)host
{
    return NO;
}

- (NSArray *)nonPreloadedHosts
{
    return [NSArray array];
}

- (void)resetHSTSForHost:(NSString *)host
{
}

- (void)resetHSTSHostsSinceDate:(NSDate *)date
{
}

@end

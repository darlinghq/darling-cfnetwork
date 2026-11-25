//
//  NSURLCredentialStorage.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Foundation/NSURLCredentialStorage.h>
#import <Foundation/NSURLCredential.h>
#import <Foundation/NSURLProtectionSpace.h>
#import <objc/runtime.h>

NSString *const NSURLCredentialStorageChangedNotification = @"NSURLCredentialStorageChangedNotification";

// The credentials of one storage live in a state object attached to it, so that subclasses (which the documentation
// allows) get their own store and the i386 legacy Objective-C ABI sees no ivars in the Foundation header.
@interface __NSURLCredentialStorageState : NSObject
{
@public
    // protection space -> (user name -> credential)
    NSMutableDictionary *credentials;
    // protection space -> default credential
    NSMutableDictionary *defaults;
}
@end

@implementation __NSURLCredentialStorageState

- (id)init
{
    if ((self = [super init]) != nil)
    {
        credentials = [[NSMutableDictionary alloc] init];
        defaults = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [credentials release];
    [defaults release];
    [super dealloc];
}

@end

static const char kStateKey;

static __NSURLCredentialStorageState *stateOf(NSURLCredentialStorage *storage)
{
    return objc_getAssociatedObject(storage, &kStateKey);
}

// Credentials are kept in memory only. NSURLCredentialPersistencePermanent asks for the keychain, which this
// storage does not use: a permanent credential lasts as long as the process, like a session one.
// A credential with NSURLCredentialPersistenceNone is for a single request and is not stored (URLCredential
// overview). GUESS: a credential with no user name (identity, trust) cannot be keyed by user name and is not
// stored either; the documentation does not say.
static BOOL isStorable(NSURLCredential *credential)
{
    return credential.user != nil && credential.persistence != NSURLCredentialPersistenceNone;
}

@implementation NSURLCredentialStorage

+ (NSURLCredentialStorage *)sharedCredentialStorage
{
    static dispatch_once_t once;
    static NSURLCredentialStorage *shared;
    dispatch_once(&once, ^{
        shared = [[NSURLCredentialStorage alloc] init];
    });
    return shared;
}

- (id)init
{
    if ((self = [super init]) != nil)
    {
        __NSURLCredentialStorageState *state = [[__NSURLCredentialStorageState alloc] init];
        objc_setAssociatedObject(self, &kStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [state release];
    }
    return self;
}

// Adds the credential to the space's set, replacing one with the same user name (documented on
// setCredential:forProtectionSpace:). Returns whether the set changed. The caller holds the lock.
- (BOOL)_addLocked:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space state:(__NSURLCredentialStorageState *)state
{
    NSMutableDictionary *byUser = [state->credentials objectForKey:space];
    if (byUser == nil)
    {
        byUser = [NSMutableDictionary dictionary];
        [state->credentials setObject:byUser forKey:space];
    }
    if ([[byUser objectForKey:credential.user] isEqual:credential])
    {
        return NO;
    }
    [byUser setObject:credential forKey:credential.user];
    // GUESS: when the replaced credential was the default of the space, the new one takes its place, so the set
    // and the default do not disagree (the documentation is silent).
    NSURLCredential *currentDefault = [state->defaults objectForKey:space];
    if (currentDefault != nil && [currentDefault.user isEqual:credential.user])
    {
        [state->defaults setObject:credential forKey:space];
    }
    return YES;
}

// GUESS: the notification is also posted when only the default credential changes; the documentation says it is
// posted when the set of stored credentials changes.
- (void)_postChange
{
    [[NSNotificationCenter defaultCenter] postNotificationName:NSURLCredentialStorageChangedNotification object:self];
}

- (NSDictionary *)credentialsForProtectionSpace:(NSURLProtectionSpace *)space
{
    __NSURLCredentialStorageState *state = stateOf(self);
    @synchronized (state)
    {
        // GUESS: nil, not an empty dictionary, when the space has no credentials (the Swift API is optional).
        return [[[state->credentials objectForKey:space] copy] autorelease];
    }
}

- (NSDictionary *)allCredentials
{
    __NSURLCredentialStorageState *state = stateOf(self);
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    @synchronized (state)
    {
        for (NSURLProtectionSpace *space in state->credentials)
        {
            [all setObject:[[[state->credentials objectForKey:space] copy] autorelease] forKey:space];
        }
    }
    return all;
}

- (void)setCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space
{
    if (credential == nil || space == nil || !isStorable(credential))
    {
        return;
    }
    __NSURLCredentialStorageState *state = stateOf(self);
    BOOL changed = NO;
    @synchronized (state)
    {
        changed = [self _addLocked:credential forProtectionSpace:space state:state];
    }
    if (changed)
    {
        [self _postChange];
    }
}

- (void)removeCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space
{
    if (credential == nil || space == nil || credential.user == nil)
    {
        return;
    }
    __NSURLCredentialStorageState *state = stateOf(self);
    BOOL changed = NO;
    @synchronized (state)
    {
        NSMutableDictionary *byUser = [state->credentials objectForKey:space];
        // GUESS: the credential to remove is identified by its user name.
        if ([byUser objectForKey:credential.user] != nil)
        {
            [byUser removeObjectForKey:credential.user];
            if (byUser.count == 0)
            {
                [state->credentials removeObjectForKey:space];
            }
            changed = YES;
        }
        // GUESS: removing a credential also clears the default of the space when that is the same user's; the
        // documentation does not say what removal does to the default.
        NSURLCredential *currentDefault = [state->defaults objectForKey:space];
        if (currentDefault != nil && [currentDefault.user isEqual:credential.user])
        {
            [state->defaults removeObjectForKey:space];
            changed = YES;
        }
    }
    if (changed)
    {
        [self _postChange];
    }
}

- (NSURLCredential *)defaultCredentialForProtectionSpace:(NSURLProtectionSpace *)space
{
    __NSURLCredentialStorageState *state = stateOf(self);
    @synchronized (state)
    {
        return [[[state->defaults objectForKey:space] retain] autorelease];
    }
}

// If the storage does not contain the credential in the space it is added (documented on
// setDefaultCredential:forProtectionSpace:), replacing one with the same user name as set does.
- (void)setDefaultCredential:(NSURLCredential *)credential forProtectionSpace:(NSURLProtectionSpace *)space
{
    if (credential == nil || space == nil || !isStorable(credential))
    {
        return;
    }
    __NSURLCredentialStorageState *state = stateOf(self);
    BOOL changed = NO;
    @synchronized (state)
    {
        changed = [self _addLocked:credential forProtectionSpace:space state:state];
        if (![[state->defaults objectForKey:space] isEqual:credential])
        {
            [state->defaults setObject:credential forKey:space];
            changed = YES;
        }
    }
    if (changed)
    {
        [self _postChange];
    }
}

// SPI: a storage of its own, separate from the shared one and from every other.
// Darling keeps no credentials on disk, so the identifier names nothing and a
// storage that isn't private is the same as a private one.
- (id)_initWithIdentifier:(NSString *)identifier private:(bool)isPrivate
{
    return [self init];
}

@end

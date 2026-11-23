//
//  NSURLCredential.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Foundation/NSURLCredential.h>
#import <objc/runtime.h>

// The credential's fields live in a state object attached to the instance, because the Foundation header
// declares no ivars and the i386 slice uses the legacy Objective-C ABI, which needs every ivar in the interface.
@interface __NSURLCredentialState : NSObject
{
@public
    NSString *user;
    NSString *password;
    SecIdentityRef identity;
    NSArray *certificates;
    SecTrustRef trust;
    NSURLCredentialPersistence persistence;
}
@end

@implementation __NSURLCredentialState

- (void)dealloc
{
    [user release];
    [password release];
    [certificates release];
    if (identity != NULL)
    {
        CFRelease(identity);
    }
    if (trust != NULL)
    {
        CFRelease(trust);
    }
    [super dealloc];
}

@end

static const char kStateKey;

static __NSURLCredentialState *stateOf(NSURLCredential *credential)
{
    return objc_getAssociatedObject(credential, &kStateKey);
}

static void attachState(NSURLCredential *credential, __NSURLCredentialState *state)
{
    objc_setAssociatedObject(credential, &kStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void attachNewState(NSURLCredential *credential)
{
    __NSURLCredentialState *state = [[__NSURLCredentialState alloc] init];
    attachState(credential, state);
    [state release];
}

static BOOL objectsMatch(id a, id b)
{
    return a == b || (a != nil && b != nil && [a isEqual:b]);
}

static BOOL refsMatch(CFTypeRef a, CFTypeRef b)
{
    return a == b || (a != NULL && b != NULL && CFEqual(a, b));
}

// NSURLCredential supports secure coding (as documented); a secure unarchiver only decodes classes
// that adopt NSSecureCoding.
@interface NSURLCredential () <NSSecureCoding>
@end

@implementation NSURLCredential

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id)init
{
    if ((self = [super init]) != nil)
    {
        // A credential made with plain -init has no user, password, identity or trust.
        attachNewState(self);
    }
    return self;
}

- (NSURLCredentialPersistence)persistence
{
    return stateOf(self)->persistence;
}

- (id)copyWithZone:(NSZone *)zone
{
    // Credentials are immutable.
    return [self retain];
}

// GUESS: the documentation lists Equatable and Hashable without saying what equal means. Two credentials
// are equal when they are of one class and all of their fields match.
- (BOOL)isEqual:(id)other
{
    if (other == self)
    {
        return YES;
    }
    if (![other isMemberOfClass:[self class]])
    {
        return NO;
    }
    __NSURLCredentialState *a = stateOf(self);
    __NSURLCredentialState *b = stateOf(other);
    return a->persistence == b->persistence
        && objectsMatch(a->user, b->user)
        && objectsMatch(a->password, b->password)
        && objectsMatch(a->certificates, b->certificates)
        && refsMatch(a->identity, b->identity)
        && refsMatch(a->trust, b->trust);
}

- (NSUInteger)hash
{
    __NSURLCredentialState *state = stateOf(self);
    return [state->user hash] ^ [state->password hash] ^ (NSUInteger)state->persistence;
}

// The password is left out on purpose.
- (NSString *)description
{
    __NSURLCredentialState *state = stateOf(self);
    return [NSString stringWithFormat:@"<%@: %p> user:%@ persistence:%ld", [self class], self, state->user, (long)state->persistence];
}

// GUESS: only user and password credentials can be archived; an identity or a trust cannot be written to an
// archive, so encoding one raises instead of silently dropping it. The key names are this implementation's own.
- (void)encodeWithCoder:(NSCoder *)coder
{
    __NSURLCredentialState *state = stateOf(self);
    if (state->identity != NULL || state->trust != NULL)
    {
        [NSException raise:NSInvalidArgumentException format:@"NSURLCredential with an identity or a trust cannot be encoded"];
    }
    [coder encodeObject:state->user forKey:@"user"];
    [coder encodeObject:state->password forKey:@"password"];
    [coder encodeInteger:state->persistence forKey:@"persistence"];
}

- (id)initWithCoder:(NSCoder *)coder
{
    // GUESS: a non-keyed coder is not supported (the keyed format below is this implementation's own).
    if (![coder allowsKeyedCoding])
    {
        [self release];
        return nil;
    }
    NSString *user = [coder decodeObjectOfClass:[NSString class] forKey:@"user"];
    NSString *password = [coder decodeObjectOfClass:[NSString class] forKey:@"password"];
    NSURLCredentialPersistence persistence = (NSURLCredentialPersistence)[coder decodeIntegerForKey:@"persistence"];
    return [self initWithUser:user password:password persistence:persistence];
}

@end

@implementation NSURLCredential (NSInternetPassword)

+ (NSURLCredential *)credentialWithUser:(NSString *)user password:(NSString *)password persistence:(NSURLCredentialPersistence)persistence
{
    return [[[self alloc] initWithUser:user password:password persistence:persistence] autorelease];
}

- (id)initWithUser:(NSString *)user password:(NSString *)password persistence:(NSURLCredentialPersistence)persistence
{
    // [super init], not [self init]: a subclass whose -init calls this method must not recurse.
    if ((self = [super init]) != nil)
    {
        attachNewState(self);
        __NSURLCredentialState *state = stateOf(self);
        state->user = [user copy];
        state->password = [password copy];
        state->persistence = persistence;
    }
    return self;
}

- (NSString *)user
{
    return stateOf(self)->user;
}

- (NSString *)password
{
    return stateOf(self)->password;
}

- (BOOL)hasPassword
{
    return stateOf(self)->password != nil;
}

@end

@implementation NSURLCredential (NSClientCertificate)

+ (NSURLCredential *)credentialWithIdentity:(SecIdentityRef)identity certificates:(NSArray *)certArray persistence:(NSURLCredentialPersistence)persistence
{
    return [[[self alloc] initWithIdentity:identity certificates:certArray persistence:persistence] autorelease];
}

- (id)initWithIdentity:(SecIdentityRef)identity certificates:(NSArray *)certArray persistence:(NSURLCredentialPersistence)persistence
{
    if ((self = [super init]) != nil)
    {
        attachNewState(self);
        __NSURLCredentialState *state = stateOf(self);
        state->identity = identity != NULL ? (SecIdentityRef)CFRetain(identity) : NULL;
        // certificates is nil for a credential created with no intermediate certificates (documented on
        // URLCredential.certificates). GUESS: an empty array counts as none.
        state->certificates = certArray.count > 0 ? [certArray copy] : nil;
        // The documentation says the persistence parameter is ignored and recommends passing ForSession, the
        // behaviour it reflects.
        state->persistence = NSURLCredentialPersistenceForSession;
    }
    return self;
}

- (SecIdentityRef)identity
{
    return stateOf(self)->identity;
}

- (NSArray *)certificates
{
    return stateOf(self)->certificates;
}

@end

@implementation NSURLCredential (NSServerTrust)

+ (NSURLCredential *)credentialForTrust:(SecTrustRef)trust
{
    return [[[self alloc] initWithTrust:trust] autorelease];
}

- (id)initWithTrust:(SecTrustRef)trust
{
    if ((self = [super init]) != nil)
    {
        attachNewState(self);
        __NSURLCredentialState *state = stateOf(self);
        state->trust = trust != NULL ? (SecTrustRef)CFRetain(trust) : NULL;
        // GUESS: a trust credential is kept for the session, not stored permanently.
        state->persistence = NSURLCredentialPersistenceForSession;
    }
    return self;
}

@end

#import <Foundation/Foundation.h>

// NSURLCredential: user/password, client certificate and server trust credentials keep what they were made with,
// report hasPassword and persistence as documented
// (https://developer.apple.com/documentation/foundation/urlcredential), are immutable under copy and compare by value.
// Behaviours the documentation leaves open are marked GUESS.

static int failures = 0;

// A subclass whose -init uses the documented initializer must not recurse through the base class's -init.
@interface FixedCredential : NSURLCredential
@end
@implementation FixedCredential
- (id)init
{
    return [self initWithUser:@"fixed" password:@"pw" persistence:NSURLCredentialPersistenceForSession];
}
@end

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

int main(void)
{
    @autoreleasepool
    {
        NSURLCredential *password = [NSURLCredential credentialWithUser:@"alice" password:@"secret" persistence:NSURLCredentialPersistenceForSession];
        expect([[password user] isEqualToString:@"alice"], @"user");
        expect([[password password] isEqualToString:@"secret"], @"password");
        expect([password hasPassword], @"hasPassword with a password");
        expect([password persistence] == NSURLCredentialPersistenceForSession, @"persistence");
        expect([password identity] == NULL, @"a password credential has no identity");

        NSURLCredential *permanent = [[[NSURLCredential alloc] initWithUser:@"bob" password:@"pw" persistence:NSURLCredentialPersistencePermanent] autorelease];
        expect([permanent persistence] == NSURLCredentialPersistencePermanent, @"permanent persistence is recorded");
        NSURLCredential *synchronizable = [[[NSURLCredential alloc] initWithUser:@"bob" password:@"pw" persistence:NSURLCredentialPersistenceSynchronizable] autorelease];
        expect([synchronizable persistence] == NSURLCredentialPersistenceSynchronizable && NSURLCredentialPersistenceSynchronizable == 3,
               @"synchronizable persistence (macOS 10.8) is recorded and keeps its public value");
        NSURLCredential *single = [NSURLCredential credentialWithUser:@"carol" password:@"pw" persistence:NSURLCredentialPersistenceNone];
        expect([single persistence] == NSURLCredentialPersistenceNone, @"none persistence is recorded");

        NSURLCredential *noPassword = [NSURLCredential credentialWithUser:@"dave" password:nil persistence:NSURLCredentialPersistenceNone];
        expect(![noPassword hasPassword] && [noPassword password] == nil, @"no password");

        // Immutable: copying hands back an equal credential.
        NSURLCredential *copy = [[password copy] autorelease];
        expect(copy == password || [copy isEqual:password], @"copy equals the original");

        NSURLCredential *same = [NSURLCredential credentialWithUser:@"alice" password:@"secret" persistence:NSURLCredentialPersistenceForSession];
        expect([same isEqual:password] && [same hash] == [password hash], @"equal credentials (GUESS: by value)");
        expect(![[NSURLCredential credentialWithUser:@"alice" password:@"other" persistence:NSURLCredentialPersistenceForSession] isEqual:password], @"different password");
        expect(![[NSURLCredential credentialWithUser:@"alice" password:@"secret" persistence:NSURLCredentialPersistenceNone] isEqual:password], @"different persistence");
        expect(![password isEqual:nil] && ![password isEqual:@"alice"], @"not equal to nil or a string");
        expect([[password description] rangeOfString:@"secret"].location == NSNotFound, @"description does not reveal the password");

        // Client certificate credential. A CFString stands in for the identity: the credential only retains it.
        SecIdentityRef identity = (SecIdentityRef)CFSTR("test-identity");
        NSArray *certificates = [NSArray arrayWithObject:@"intermediate"];
        NSURLCredential *cert = [NSURLCredential credentialWithIdentity:identity certificates:certificates persistence:NSURLCredentialPersistencePermanent];
        expect([cert identity] == identity, @"identity");
        expect([[cert certificates] isEqualToArray:certificates], @"certificates");
        // The persistence argument is ignored; the credential reports ForSession (documented on init(identity:certificates:persistence:)).
        expect([cert persistence] == NSURLCredentialPersistenceForSession, @"identity credentials report ForSession whatever was passed");
        expect([cert user] == nil && [cert password] == nil && ![cert hasPassword], @"a certificate credential has no user or password");
        NSURLCredential *noIntermediates = [NSURLCredential credentialWithIdentity:identity certificates:nil persistence:NSURLCredentialPersistenceNone];
        expect([noIntermediates certificates] == nil, @"nil with no intermediate certificates (documented on URLCredential.certificates)");
        NSURLCredential *emptyIntermediates = [NSURLCredential credentialWithIdentity:identity certificates:[NSArray array] persistence:NSURLCredentialPersistenceNone];
        expect([emptyIntermediates certificates] == nil, @"GUESS: an empty array counts as no intermediate certificates");
        expect([password certificates] == nil, @"nil for a credential that is not a client certificate credential");
        expect([cert isEqual:[NSURLCredential credentialWithIdentity:identity certificates:certificates persistence:NSURLCredentialPersistenceNone]], @"equal certificate credentials");

        FixedCredential *fixed = [[[FixedCredential alloc] init] autorelease];
        expect([[fixed user] isEqualToString:@"fixed"] && [fixed hasPassword], @"a subclass can build on the documented initializer");

        // Server trust credential. A CFString stands in for the trust.
        SecTrustRef trust = (SecTrustRef)CFSTR("test-trust");
        NSURLCredential *trusted = [NSURLCredential credentialForTrust:trust];
        expect([trusted user] == nil && ![trusted hasPassword] && [trusted identity] == NULL, @"a trust credential has no user, password or identity");
        expect([trusted persistence] == NSURLCredentialPersistenceForSession, @"trust persistence (GUESS: session)");
        expect(![trusted isEqual:password], @"trust credential differs from a password one");

        // Archiving round trip for a password credential (the key names are this implementation's own).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:password];
        NSURLCredential *unarchived = [NSKeyedUnarchiver unarchiveObjectWithData:archived];
#pragma clang diagnostic pop
        expect([unarchived isEqual:password], @"password credential survives archiving");

        BOOL raised = NO;
        @try
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [NSKeyedArchiver archivedDataWithRootObject:cert];
#pragma clang diagnostic pop
        }
        @catch (NSException *e)
        {
            raised = [[e name] isEqualToString:NSInvalidArgumentException];
        }
        expect(raised, @"an identity credential cannot be archived (GUESS: raises)");
    }

    if (failures == 0)
        NSLog(@"PASS: nsurlcredential-basic");
    return failures == 0 ? 0 : 1;
}

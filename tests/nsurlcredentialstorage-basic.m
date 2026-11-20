#import <Foundation/Foundation.h>

// NSURLCredentialStorage keeps credentials per protection space, with a default credential per space, and posts
// NSURLCredentialStorageChangedNotification when the set changes
// (https://developer.apple.com/documentation/foundation/urlcredentialstorage). Storage is in memory: keychain
// persistence is not implemented, so Permanent credentials last as long as the process. Behaviours the documentation
// leaves open are marked GUESS.

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

static NSURLProtectionSpace *space(NSString *host)
{
    return [[[NSURLProtectionSpace alloc] initWithHost:host port:443 protocol:NSURLProtectionSpaceHTTPS realm:@"realm"
                                  authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
}

@interface Counter : NSObject
{
    int _fired;
}
@property (nonatomic) int fired;
- (void)changed:(NSNotification *)note;
@end

@implementation Counter
@synthesize fired = _fired;
- (void)changed:(NSNotification *)note
{
    self.fired++;
}
@end

@interface MyStorage : NSURLCredentialStorage
@end
@implementation MyStorage
@end

int main(void)
{
    @autoreleasepool
    {
        expect([NSURLCredentialStorage sharedCredentialStorage] != nil, @"shared storage exists");
        expect([NSURLCredentialStorage sharedCredentialStorage] == [NSURLCredentialStorage sharedCredentialStorage], @"shared storage is one object");

        NSURLCredentialStorage *storage = [[[NSURLCredentialStorage alloc] init] autorelease];
        Counter *counter = [[[Counter alloc] init] autorelease];
        [[NSNotificationCenter defaultCenter] addObserver:counter selector:@selector(changed:) name:NSURLCredentialStorageChangedNotification object:storage];

        NSURLProtectionSpace *a = space(@"a.example.test");
        NSURLProtectionSpace *b = space(@"b.example.test");
        expect([storage credentialsForProtectionSpace:a] == nil, @"no credentials yet (GUESS: nil)");
        expect([[storage allCredentials] count] == 0, @"nothing stored");
        expect([storage defaultCredentialForProtectionSpace:a] == nil, @"no default yet");

        NSURLCredential *alice = [NSURLCredential credentialWithUser:@"alice" password:@"1" persistence:NSURLCredentialPersistenceForSession];
        NSURLCredential *bob = [NSURLCredential credentialWithUser:@"bob" password:@"2" persistence:NSURLCredentialPersistencePermanent];
        [storage setCredential:alice forProtectionSpace:a];
        [storage setCredential:bob forProtectionSpace:a];
        NSDictionary *forA = [storage credentialsForProtectionSpace:a];
        expect([forA count] == 2 && [forA objectForKey:@"alice"] == alice && [forA objectForKey:@"bob"] == bob, @"credentials are keyed by user name");
        expect([storage credentialsForProtectionSpace:b] == nil, @"other spaces are separate");
        // An equal protection space finds the same credentials.
        expect([[storage credentialsForProtectionSpace:space(@"a.example.test")] count] == 2, @"lookup by an equal space");
        expect(counter.fired == 2, @"one notification per change");

        // The same user is replaced, not duplicated.
        NSURLCredential *alice2 = [NSURLCredential credentialWithUser:@"alice" password:@"changed" persistence:NSURLCredentialPersistenceForSession];
        [storage setCredential:alice2 forProtectionSpace:a];
        expect([[[storage credentialsForProtectionSpace:a] objectForKey:@"alice"] isEqual:alice2] && [[storage credentialsForProtectionSpace:a] count] == 2, @"replaced");

        [storage setCredential:alice forProtectionSpace:b];
        NSDictionary *all = [storage allCredentials];
        expect([all count] == 2 && [[all objectForKey:a] count] == 2 && [[all objectForKey:b] count] == 1, @"allCredentials covers every space");

        // The returned dictionaries are snapshots.
        NSDictionary *snapshot = [storage credentialsForProtectionSpace:b];
        [storage removeCredential:alice forProtectionSpace:b];
        expect([snapshot count] == 1 && [storage credentialsForProtectionSpace:b] == nil, @"removing the last credential empties the space");
        expect([[storage allCredentials] objectForKey:b] == nil, @"an empty space is gone from allCredentials");

        // Single-request credentials are not stored (documented); GUESS: neither are user-less ones.
        int before = counter.fired;
        [storage setCredential:[NSURLCredential credentialWithUser:@"once" password:@"x" persistence:NSURLCredentialPersistenceNone] forProtectionSpace:b];
        [storage setCredential:[NSURLCredential credentialForTrust:(SecTrustRef)CFSTR("t")] forProtectionSpace:b];
        expect([storage credentialsForProtectionSpace:b] == nil && counter.fired == before, @"not stored, no notification");

        // Setting the same credential again changes nothing, so it posts nothing.
        before = counter.fired;
        [storage setCredential:alice2 forProtectionSpace:a];
        expect(counter.fired == before, @"no notification when nothing changed");

        // Defaults.
        [storage setDefaultCredential:bob forProtectionSpace:a];
        expect([storage defaultCredentialForProtectionSpace:a] == bob, @"default credential");
        expect([storage defaultCredentialForProtectionSpace:b] == nil, @"defaults are per space");
        NSURLCredential *carol = [NSURLCredential credentialWithUser:@"carol" password:@"3" persistence:NSURLCredentialPersistenceForSession];
        [storage setDefaultCredential:carol forProtectionSpace:b];
        expect([[storage credentialsForProtectionSpace:b] objectForKey:@"carol"] == carol, @"a default that is not in the set is added (documented)");

        // The documented rule is about the credential, not the user name: a different credential for a stored user
        // is not "contained", so it is added, replacing the old one, and becomes the default.
        NSURLCredential *carolNew = [NSURLCredential credentialWithUser:@"carol" password:@"new" persistence:NSURLCredentialPersistenceForSession];
        [storage setDefaultCredential:carolNew forProtectionSpace:b];
        expect([[storage credentialsForProtectionSpace:b] objectForKey:@"carol"] == carolNew, @"the new credential replaces the old one in the set");
        expect([storage defaultCredentialForProtectionSpace:b] == carolNew, @"and is the default");
        before = counter.fired;
        [storage setDefaultCredential:carolNew forProtectionSpace:b];
        expect(counter.fired == before, @"setting the same default again changes nothing");
        [storage removeCredential:bob forProtectionSpace:a];
        expect([storage defaultCredentialForProtectionSpace:a] == nil, @"GUESS: removing the default credential clears the default");
        expect([[storage credentialsForProtectionSpace:a] objectForKey:@"bob"] == nil, @"and removes it from the set");

        // GUESS: replacing the default's user in the set moves the default with it.
        NSURLCredential *dana1 = [NSURLCredential credentialWithUser:@"dana" password:@"1" persistence:NSURLCredentialPersistenceForSession];
        NSURLCredential *dana2 = [NSURLCredential credentialWithUser:@"dana" password:@"2" persistence:NSURLCredentialPersistenceForSession];
        NSURLProtectionSpace *c = space(@"c.example.test");
        [storage setDefaultCredential:dana1 forProtectionSpace:c];
        [storage setCredential:dana2 forProtectionSpace:c];
        expect([[storage credentialsForProtectionSpace:c] objectForKey:@"dana"] == dana2 && [storage defaultCredentialForProtectionSpace:c] == dana2,
               @"the set and the default agree after a replacement");

        // A proxy space and an origin server space for the same host are separate buckets.
        NSURLProtectionSpace *server = space(@"proxy.example.test");
        NSURLProtectionSpace *proxy = [[[NSURLProtectionSpace alloc] initWithProxyHost:@"proxy.example.test" port:443 type:NSURLProtectionSpaceHTTPSProxy realm:@"realm"
                                                                  authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        [storage setCredential:dana1 forProtectionSpace:proxy];
        expect([storage credentialsForProtectionSpace:server] == nil && [[storage credentialsForProtectionSpace:proxy] count] == 1, @"proxy and server spaces do not share credentials");

        before = counter.fired;
        [storage removeCredential:bob forProtectionSpace:a];
        expect(counter.fired == before, @"removing a credential that is not there changes nothing");

        // Subclasses (the documentation allows them) get a store of their own.
        MyStorage *mine = [[[MyStorage alloc] init] autorelease];
        [mine setCredential:alice forProtectionSpace:a];
        expect([[mine credentialsForProtectionSpace:a] count] == 1 && [[storage credentialsForProtectionSpace:a] objectForKey:@"alice"] != nil
               && [[storage credentialsForProtectionSpace:a] count] == 1, @"subclass storage is separate");

        [[NSNotificationCenter defaultCenter] removeObserver:counter];
    }

    if (failures == 0)
        NSLog(@"PASS: nsurlcredentialstorage-basic");
    return failures == 0 ? 0 : 1;
}

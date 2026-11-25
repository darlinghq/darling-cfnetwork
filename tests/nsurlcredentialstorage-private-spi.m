#import <Foundation/Foundation.h>

// -[NSURLCredentialStorage _initWithIdentifier:private:] (SPI that WebKit uses)
// makes a credential storage of its own that starts empty, separate from the
// shared storage and from every other. (Observed on macOS 26.7.3.)

@interface NSURLCredentialStorage (PrivateSPI)
- (id)_initWithIdentifier:(NSString *)identifier private:(bool)isPrivate;
@end

static int failures = 0;

static void expect(BOOL condition, const char *message)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message);
    if (!condition)
        failures++;
}

int main(void)
{
    @autoreleasepool
    {
        NSURLCredentialStorage *storage = [[[NSURLCredentialStorage alloc] _initWithIdentifier:@"test-identifier" private:YES] autorelease];
        NSURLCredentialStorage *other = [[[NSURLCredentialStorage alloc] _initWithIdentifier:@"test-identifier" private:YES] autorelease];
        expect(storage != nil && storage != [NSURLCredentialStorage sharedCredentialStorage], "a private storage isn't the shared one");
        expect(storage.allCredentials.count == 0, "a private storage starts empty");

        NSURLProtectionSpace *space = [[[NSURLProtectionSpace alloc] initWithHost:@"example.com" port:80 protocol:NSURLProtectionSpaceHTTP realm:@"r"
                                                             authenticationMethod:NSURLAuthenticationMethodHTTPBasic] autorelease];
        NSURLCredential *credential = [NSURLCredential credentialWithUser:@"u" password:@"p" persistence:NSURLCredentialPersistenceForSession];
        [storage setCredential:credential forProtectionSpace:space];
        expect([[storage credentialsForProtectionSpace:space][@"u"] isEqual:credential], "a private storage keeps its credentials");
        expect([other credentialsForProtectionSpace:space].count == 0, "two private storages are separate");
        expect([[NSURLCredentialStorage sharedCredentialStorage] credentialsForProtectionSpace:space].count == 0, "a private storage is separate from the shared one");
    }
    return failures != 0;
}

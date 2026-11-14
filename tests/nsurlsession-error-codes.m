// Copyright (C) 2026 Lubos Dolezel
#import <Foundation/Foundation.h>

// NSURLSession failures carry the NSURLErrorDomain code macOS uses for the cause.
// Servers: tests/cfurlconnection-test-server.py with certificates from tests/make-test-certs.py
// (valid, expired, notyet, wronghost; all self-signed, so none is trusted), plus a closed port.
// usage: nsurlsession-error-codes VALID_URL EXPIRED_URL NOTYET_URL WRONGHOST_URL CLOSED_PORT_URL
// e.g.   nsurlsession-error-codes https://127.0.0.1:8780/plain https://127.0.0.1:8781/plain \
//          https://127.0.0.1:8782/plain https://127.0.0.1:8783/plain http://127.0.0.1:1/
// With the argument "print" first, only prints the codes. Certificate validation is never
// disabled: every certificate here must be refused. macOS 26.7.3 answers -1202 for all four, because an
// untrusted chain is reported before the dates; the date-specific codes need a certificate that chains
// to a trusted root and are covered by tests/nsurlsession-curl-error-map.m.

static int failures;

static NSInteger codeFor(NSString *urlString, NSString **domain)
{
    __block NSError *error = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        error = e;
        dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC)) != 0)
        return 1;
    if (domain)
        *domain = error.domain;
    return error ? error.code : 0;
}

static void expect(NSString *what, NSString *url, NSInteger expected, BOOL print)
{
    NSString *domain = nil;
    NSInteger code = codeFor(url, &domain);
    if (print) {
        printf("%s: %s %ld\n", [what UTF8String], [domain UTF8String], (long)code);
        return;
    }
    BOOL ok = code == expected && (code == 0 || [domain isEqualToString:NSURLErrorDomain]);
    printf("%s: %s (code %ld, expected %ld)\n", ok ? "PASS" : "FAIL", [what UTF8String], (long)code, (long)expected);
    if (!ok)
        failures++;
}

int main(int argc, char **argv)
{
    BOOL print = argc > 1 && strcmp(argv[1], "print") == 0;
    @autoreleasepool {
        int first = print ? 2 : 1;
        if (argc < first + 5) {
            fprintf(stderr, "usage: %s [print] VALID EXPIRED NOTYET WRONGHOST CLOSED\n", argv[0]);
            return 2;
        }
        NSString *(^arg)(int) = ^NSString *(int i) { return [NSString stringWithUTF8String:argv[first + i]]; };
        expect(@"self-signed certificate", arg(0), NSURLErrorServerCertificateUntrusted, print);
        expect(@"expired self-signed certificate", arg(1), NSURLErrorServerCertificateUntrusted, print);
        expect(@"not yet valid self-signed certificate", arg(2), NSURLErrorServerCertificateUntrusted, print);
        expect(@"certificate for another host name", arg(3), NSURLErrorServerCertificateUntrusted, print);
        expect(@"connection refused", arg(4), NSURLErrorCannotConnectToHost, print);
    }
    if (!print)
        printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures;
}

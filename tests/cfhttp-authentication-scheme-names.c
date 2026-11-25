// Copyright (C) 2026 Lubos Dolezel
//
// The kCFHTTPAuthenticationScheme constants that CFHTTPMessage.h declares are
// the scheme names as HTTP writes them (RFC 7617 Basic, RFC 7616 Digest,
// RFC 4559 Negotiate, and NTLM). Values match macOS 26.7.3 and Mac OS X
// 10.14.4, where the program builds and runs too.
#include <CFNetwork/CFNetwork.h>
#include <stdio.h>

static int failures;

static void expect(CFStringRef value, const char *name)
{
    char text[32] = "";
    if (value != NULL)
        CFStringGetCString(value, text, sizeof text, kCFStringEncodingUTF8);
    CFStringRef wanted = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    int ok = value != NULL && CFEqual(value, wanted);
    CFRelease(wanted);
    printf("%s %s (got \"%s\")\n", ok ? "PASS" : "FAIL", name, text);
    if (!ok)
        failures++;
}

int main(void)
{
    expect(kCFHTTPAuthenticationSchemeBasic, "Basic");
    expect(kCFHTTPAuthenticationSchemeDigest, "Digest");
    expect(kCFHTTPAuthenticationSchemeNegotiate, "Negotiate");
    expect(kCFHTTPAuthenticationSchemeNTLM, "NTLM");
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

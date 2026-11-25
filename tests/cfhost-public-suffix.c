/* Copyright (C) 2026 Lubos Dolezel */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

/*
 * _CFHostIsDomainTopLevel answers whether a domain is a public suffix, by the
 * rules of Mozilla's Public Suffix List and its algorithm
 * (https://publicsuffix.org/list/). The cases use rules of the list shipped
 * in CFNetwork's Resources (version 2026-11-21_04-33-45_UTC): "com", "uk",
 * "co.uk", "jp", "*.kawasaki.jp" with "!city.kawasaki.jp", "*.ck" with
 * "!www.ck", "github.io" (in the private section) and "公司.cn".
 * The function is private, so it is declared here.
 * Prints PASS/FAIL lines; the exit status is the number of failures.
 */

extern Boolean _CFHostIsDomainTopLevel(CFStringRef domain);

static int failures;

static void check(const char *domain, Boolean expected)
{
	CFStringRef name = CFStringCreateWithCString(NULL, domain, kCFStringEncodingUTF8);
	Boolean got = _CFHostIsDomainTopLevel(name);
	CFRelease(name);
	if (got == expected) {
		printf("PASS: \"%s\" %s a public suffix\n", domain, expected ? "is" : "is not");
	} else {
		printf("FAIL: \"%s\" should %sbe a public suffix\n", domain, expected ? "" : "not ");
		failures++;
	}
}

int main(void)
{
	/* normal rules */
	check("com", true);
	check("example.com", false);
	check("uk", true);
	check("co.uk", true);
	check("example.co.uk", false);
	check("www.example.co.uk", false);
	check("github.io", true);
	check("example.github.io", false);
	check("公司.cn", true);
	check("example.公司.cn", false);

	/* wildcard rules and their exceptions */
	check("foo.kawasaki.jp", true);
	check("bar.foo.kawasaki.jp", false);
	check("city.kawasaki.jp", false);
	check("www.city.kawasaki.jp", false);
	check("ck", true);
	check("foo.ck", true);
	check("www.ck", false);
	check("a.www.ck", false);

	/* the implicit "*" rule: any single label, and nothing longer */
	check("localhost", true);
	check("example.notatld", false);

	/* case and a final dot do not matter; empty labels make no domain */
	check("CO.UK", true);
	check("com.", true);
	check("", false);
	check(".com", false);
	check("example..com", false);
	if (_CFHostIsDomainTopLevel(NULL)) {
		printf("FAIL: NULL should not be a public suffix\n");
		failures++;
	}

	printf("%s\n", failures ? "FAILED" : "ALL PASSED");
	return failures;
}

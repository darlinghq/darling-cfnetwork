/*
 This file is part of Darling.

 Copyright (C) 2026 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/


// Whether a domain is a public suffix: a name under which anyone can register
// names (such as "com", "co.uk" or "github.io"), so that names under it
// belong to different owners. The rules are those of Mozilla's Public Suffix
// List (https://publicsuffix.org/list/), shipped in the framework's Resources
// as public_suffix_list.dat (MPL 2.0), and are applied by the list's own
// algorithm:
// - an exception rule ("!www.ck") makes its name a registrable name, which
//   names under it are too;
// - a normal rule ("co.uk") makes its name a public suffix, and a wildcard
//   rule ("*.ck") every name one label under its base;
// - a name no rule matches is a public suffix only if it is a single label
//   (the list's implicit "*" rule).
// The names are matched as Unicode, ignoring case and a final dot; the list
// gives internationalized names in Unicode, so a punycode ("xn--") name is
// not matched to its rule.

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CFMutableSetRef normalRules;    // "co.uk"
static CFMutableSetRef wildcardBases;  // "ck" for "*.ck"
static CFMutableSetRef exceptionRules; // "www.ck" for "!www.ck"

// The list sits in the Resources of the framework this code is in.
static FILE *openList(void) {
    Dl_info info;
    if (!dladdr((const void *)&openList, &info) || info.dli_fname == NULL) {
        return NULL;
    }
    char binary[PATH_MAX];
    strncpy(binary, info.dli_fname, sizeof(binary) - 1);
    binary[sizeof(binary) - 1] = '\0';
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/Resources/public_suffix_list.dat", dirname(binary)) >= (int)sizeof(path)) {
        return NULL;
    }
    return fopen(path, "r");
}

static void addRule(CFMutableSetRef set, const char *name, size_t length) {
    CFStringRef rule = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)name, length, kCFStringEncodingUTF8, false);
    if (rule != NULL) {
        CFSetAddValue(set, rule);
        CFRelease(rule);
    }
}

static void loadRules(void *unused) {
    normalRules = CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks);
    wildcardBases = CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks);
    exceptionRules = CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks);

    // Without the list only the implicit rule applies.
    FILE *list = openList();
    if (list == NULL) {
        return;
    }
    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, list) != -1) {
        // a rule is the line up to the first white space
        size_t length = strcspn(line, " \t\r\n");
        if (length == 0 || (length >= 2 && line[0] == '/' && line[1] == '/')) {
            continue;
        }
        if (line[0] == '!') {
            addRule(exceptionRules, line + 1, length - 1);
        } else if (length > 2 && line[0] == '*' && line[1] == '.') {
            addRule(wildcardBases, line + 2, length - 2);
        } else {
            addRule(normalRules, line, length);
        }
    }
    free(line);
    fclose(list);
}

// The name after its first label, or NULL for a single label.
static CFStringRef copyParent(CFStringRef name) {
    CFRange dot = CFStringFind(name, CFSTR("."), 0);
    if (dot.location == kCFNotFound) {
        return NULL;
    }
    CFIndex start = dot.location + 1;
    return CFStringCreateWithSubstring(kCFAllocatorDefault, name, CFRangeMake(start, CFStringGetLength(name) - start));
}

Boolean _CFHostIsDomainTopLevel(CFStringRef domain) {
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, loadRules);

    if (domain == NULL || CFStringGetLength(domain) == 0) {
        return false;
    }
    CFMutableStringRef name = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, domain);
    CFStringLowercase(name, NULL);
    CFIndex length = CFStringGetLength(name);
    if (CFStringGetCharacterAtIndex(name, length - 1) == '.') {
        CFStringDelete(name, CFRangeMake(length - 1, 1));
    }
    // an empty label is no domain at all
    if (CFStringGetLength(name) == 0 || CFStringHasPrefix(name, CFSTR(".")) || CFStringFind(name, CFSTR(".."), 0).location != kCFNotFound) {
        CFRelease(name);
        return false;
    }

    // An exception for the name or a name above it makes it registrable.
    Boolean excepted = false;
    CFStringRef suffix = CFRetain(name);
    while (suffix != NULL && !excepted) {
        excepted = CFSetContainsValue(exceptionRules, suffix);
        CFStringRef parent = copyParent(suffix);
        CFRelease(suffix);
        suffix = parent;
    }
    if (suffix != NULL) {
        CFRelease(suffix);
    }

    Boolean result = false;
    if (!excepted) {
        CFStringRef parent = copyParent(name);
        if (CFSetContainsValue(normalRules, name)) {
            result = true;
        } else if (parent != NULL) {
            result = CFSetContainsValue(wildcardBases, parent);
        } else {
            // the implicit "*" rule
            result = true;
        }
        if (parent != NULL) {
            CFRelease(parent);
        }
    }
    CFRelease(name);
    return result;
}

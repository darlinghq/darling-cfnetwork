//
//  CFHTTPCookieStorage.c
//  CFNetwork
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#include "CFBase.h"
#include "CFRuntime.h"
#include "CFHTTPCookieStorage.h"
#include "CFHTTPCookie.h"
#include "CFHTTPCookieInternal.h"
#include "CFArray.h"
#include <CoreFoundation/CFBundle.h>
#include <CoreFoundation/CFPropertyList.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The storage holds immutable cookies in an array protected by a mutex. The default storage is
// persistent: its non-session cookies live in a property list under ~/Library/Cookies, named after
// the main bundle identifier (or the process name when there is none). The file is read the first
// time the storage is used and rewritten atomically whenever a persistent cookie changes.

struct __CFHTTPCookieStorage {
    CFRuntimeBase _base;
    pthread_mutex_t _lock;
    CFMutableArrayRef _cookies;
    CFHTTPCookieStorageAcceptPolicy _policy;
    Boolean _persistent;
    Boolean _loaded;
    Boolean _dirty;
    char *_persistPath;
    CFHTTPCookieStorageChangeCallBack _changeCallBack;
    void *_changeInfo;
};

#define kPersistenceFormatVersion 1

static void __CFHTTPCookieStorageDeallocate(CFTypeRef cf) {
    struct __CFHTTPCookieStorage *item = (struct __CFHTTPCookieStorage *)cf;
    CFRelease(item->_cookies);
    free(item->_persistPath);
    pthread_mutex_destroy(&item->_lock);
}

static CFTypeID __kCFHTTPCookieStorageTypeID = _kCFRuntimeNotATypeID;

static const CFRuntimeClass __CFHTTPCookieStorageClass = {
    _kCFRuntimeScannedObject,
    "CFHTTPCookieStorage",
    NULL,   // init
    NULL,   // copy
    __CFHTTPCookieStorageDeallocate,
    NULL,
    NULL,
    NULL,
    NULL
};

static void __CFHTTPCookieStorageInitialize(void) {
    __kCFHTTPCookieStorageTypeID = _CFRuntimeRegisterClass(&__CFHTTPCookieStorageClass);
}

CFTypeID CFHTTPCookieStorageGetTypeID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __CFHTTPCookieStorageInitialize();
    });
    return __kCFHTTPCookieStorageTypeID;
}

static struct __CFHTTPCookieStorage *_CFHTTPCookieStorageCreate(CFAllocatorRef allocator, Boolean persistent) {
    CFIndex size = sizeof(struct __CFHTTPCookieStorage) - sizeof(CFRuntimeBase);
    struct __CFHTTPCookieStorage *cookieStorage = (struct __CFHTTPCookieStorage *)_CFRuntimeCreateInstance(allocator, CFHTTPCookieStorageGetTypeID(), size, NULL);

    pthread_mutex_init(&cookieStorage->_lock, NULL);
    cookieStorage->_cookies = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    cookieStorage->_policy = kCFHTTPCookieStorageAcceptPolicyOnlyFromMainDocumentDomain;
    cookieStorage->_persistent = persistent;
    cookieStorage->_loaded = !persistent;
    return cookieStorage;
}

CFHTTPCookieStorageRef CFHTTPCookieStorageGetDefault() {
    static struct __CFHTTPCookieStorage *sharedStorage = NULL;
    static dispatch_once_t once = 0L;
    dispatch_once(&once, ^{
        sharedStorage = _CFHTTPCookieStorageCreate(kCFAllocatorDefault, true);
    });
    return (CFHTTPCookieStorageRef)sharedStorage;
}

#pragma mark - Persistence

static void __lock(CFHTTPCookieStorageRef storage) {
    pthread_mutex_lock(&storage->_lock);
}

static void __unlock(CFHTTPCookieStorageRef storage) {
    pthread_mutex_unlock(&storage->_lock);
}

// ~/Library/Cookies/<bundle identifier or process name>.cookies.plist
static char *__createPersistencePath(void) {
    const char *home = getenv("HOME");
    char *passwdHome = NULL;
    if (home == NULL || home[0] != '/') {
        struct passwd pwd, *result = NULL;
        char buffer[4096];
        if (getpwuid_r(getuid(), &pwd, buffer, sizeof buffer, &result) == 0 && result != NULL && result->pw_dir != NULL && result->pw_dir[0] == '/') {
            passwdHome = strdup(result->pw_dir);
            home = passwdHome;
        } else {
            return NULL;
        }
    }

    char identifier[256];
    identifier[0] = '\0';
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef bundleIdentifier = bundle != NULL ? CFBundleGetIdentifier(bundle) : NULL;
    if (bundleIdentifier != NULL) {
        CFStringGetCString(bundleIdentifier, identifier, sizeof identifier, kCFStringEncodingUTF8);
    }
    if (identifier[0] == '\0') {
        const char *name = getprogname();
        strlcpy(identifier, name != NULL ? name : "", sizeof identifier);
    }
    if (identifier[0] == '\0') {
        strlcpy(identifier, "default", sizeof identifier);
    }
    // The identifier must stay a single path component.
    for (char *c = identifier; *c != '\0'; c++) {
        if (*c == '/') {
            *c = '_';
        }
    }
    if (identifier[0] == '.') {
        identifier[0] = '_';
    }

    size_t length = strlen(home) + strlen("/Library/Cookies/") + strlen(identifier) + strlen(".cookies.plist") + 1;
    char *path = malloc(length);
    if (path != NULL) {
        snprintf(path, length, "%s/Library/Cookies/%s.cookies.plist", home, identifier);
    }
    free(passwdHome);
    return path;
}

static CFDictionaryRef __copyPersistentRepresentation(CFHTTPCookieRef cookie) {
    CFMutableDictionaryRef entry = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(entry, CFSTR("Name"), CFHTTPCookieGetName(cookie));
    CFDictionarySetValue(entry, CFSTR("Value"), CFHTTPCookieGetValue(cookie));
    CFDictionarySetValue(entry, CFSTR("Domain"), CFHTTPCookieGetDomain(cookie));
    CFDictionarySetValue(entry, CFSTR("Path"), CFHTTPCookieGetPath(cookie));
    CFDictionarySetValue(entry, CFSTR("Secure"), CFHTTPCookieIsSecure(cookie) ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(entry, CFSTR("HTTPOnly"), CFHTTPCookieIsHTTPOnly(cookie) ? kCFBooleanTrue : kCFBooleanFalse);
    if (CFHTTPCookieGetExpirationDate(cookie) != NULL) {
        CFDictionarySetValue(entry, CFSTR("Expires"), CFHTTPCookieGetExpirationDate(cookie));
    }
    CFDateRef stored = CFDateCreate(kCFAllocatorDefault, _CFHTTPCookieGetStoredTime(cookie));
    CFDictionarySetValue(entry, CFSTR("Stored"), stored);
    CFRelease(stored);
    if (CFHTTPCookieGetVersion(cookie) != NULL) {
        CFDictionarySetValue(entry, CFSTR("Version"), CFHTTPCookieGetVersion(cookie));
    }
    if (CFHTTPCookieGetComment(cookie) != NULL) {
        CFDictionarySetValue(entry, CFSTR("Comment"), CFHTTPCookieGetComment(cookie));
    }
    if (CFHTTPCookieGetCommentURL(cookie) != NULL) {
        CFDictionarySetValue(entry, CFSTR("CommentURL"), CFURLGetString(CFHTTPCookieGetCommentURL(cookie)));
    }
    return entry;
}

static CFHTTPCookieRef __createCookieFromPersistentRepresentation(CFDictionaryRef entry) {
    if (CFGetTypeID(entry) != CFDictionaryGetTypeID()) {
        return NULL;
    }
    CFTypeRef expires = CFDictionaryGetValue(entry, CFSTR("Expires"));
    if (expires == NULL || CFGetTypeID(expires) != CFDateGetTypeID()) {
        return NULL; // only cookies with an expiry date are ever written
    }

    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    static const CFStringRef stringKeys[] = { CFSTR("Name"), CFSTR("Value"), CFSTR("Domain"), CFSTR("Path"), CFSTR("Comment") };
    for (size_t i = 0; i < sizeof stringKeys / sizeof stringKeys[0]; i++) {
        CFTypeRef value = CFDictionaryGetValue(entry, stringKeys[i]);
        if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
            CFDictionarySetValue(properties, stringKeys[i], value);
        }
    }
    CFDictionarySetValue(properties, CFSTR("Expires"), expires);
    CFTypeRef version = CFDictionaryGetValue(entry, CFSTR("Version"));
    if (version != NULL && CFGetTypeID(version) == CFNumberGetTypeID()) {
        CFDictionarySetValue(properties, CFSTR("Version"), version);
    }
    CFTypeRef commentURL = CFDictionaryGetValue(entry, CFSTR("CommentURL"));
    if (commentURL != NULL && CFGetTypeID(commentURL) == CFStringGetTypeID()) {
        CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, commentURL, NULL);
        if (url != NULL) {
            CFDictionarySetValue(properties, CFSTR("CommentURL"), url);
            CFRelease(url);
        }
    }
    CFTypeRef flag = CFDictionaryGetValue(entry, CFSTR("Secure"));
    if (flag != NULL && CFGetTypeID(flag) == CFBooleanGetTypeID() && CFBooleanGetValue(flag)) {
        CFDictionarySetValue(properties, CFSTR("Secure"), CFSTR("TRUE"));
    }
    flag = CFDictionaryGetValue(entry, CFSTR("HTTPOnly"));
    if (flag != NULL && CFGetTypeID(flag) == CFBooleanGetTypeID() && CFBooleanGetValue(flag)) {
        CFDictionarySetValue(properties, CFSTR("HTTPOnly"), CFSTR("TRUE"));
    }

    CFHTTPCookieRef cookie = CFHTTPCookieCreateWithProperties(properties);
    CFRelease(properties);
    if (cookie == NULL) {
        return NULL;
    }
    CFTypeRef stored = CFDictionaryGetValue(entry, CFSTR("Stored"));
    CFAbsoluteTime storedTime = (stored != NULL && CFGetTypeID(stored) == CFDateGetTypeID()) ? CFDateGetAbsoluteTime(stored) : CFAbsoluteTimeGetCurrent();
    CFHTTPCookieRef result = _CFHTTPCookieCreateStoredCopy(cookie, storedTime);
    CFRelease(cookie);
    return result;
}

static CFIndex __indexOfCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie) {
    CFIndex count = CFArrayGetCount(storage->_cookies);
    for (CFIndex i = 0; i < count; i++) {
        if (_CFHTTPCookieHasSameIdentity((CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, i), cookie)) {
            return i;
        }
    }
    return kCFNotFound;
}

// Reads the persistent file the first time the storage is used. Must be called with the lock held.
static void __ensureLoaded(CFHTTPCookieStorageRef storage) {
    if (storage->_loaded) {
        return;
    }
    storage->_loaded = true;
    storage->_persistPath = __createPersistencePath();
    if (storage->_persistPath == NULL) {
        return;
    }

    int fd = open(storage->_persistPath, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return;
    }
    struct stat st;
    const off_t maxSize = 64 * 1024 * 1024;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > maxSize) {
        close(fd);
        return;
    }
    UInt8 *bytes = malloc((size_t)st.st_size);
    size_t got = 0;
    while (bytes != NULL && got < (size_t)st.st_size) {
        ssize_t n = read(fd, bytes + got, (size_t)st.st_size - got);
        if (n <= 0) {
            break;
        }
        got += (size_t)n;
    }
    close(fd);
    if (bytes == NULL) {
        return;
    }

    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, bytes, (CFIndex)got, kCFAllocatorMalloc);
    CFPropertyListRef plist = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    if (plist == NULL) {
        return;
    }

    if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFTypeRef list = CFDictionaryGetValue(plist, CFSTR("Cookies"));
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (list != NULL && CFGetTypeID(list) == CFArrayGetTypeID()) {
            for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
                CFHTTPCookieRef cookie = __createCookieFromPersistentRepresentation(CFArrayGetValueAtIndex(list, i));
                if (cookie == NULL) {
                    continue;
                }
                if (!_CFHTTPCookieIsExpired(cookie, now)) {
                    CFIndex existing = __indexOfCookie(storage, cookie);
                    if (existing == kCFNotFound) {
                        CFArrayAppendValue(storage->_cookies, cookie);
                    } else {
                        CFArraySetValueAtIndex(storage->_cookies, existing, cookie);
                    }
                }
                CFRelease(cookie);
            }
        }
    }
    CFRelease(plist);
}

static Boolean __makeDirectory(const char *path) {
    if (mkdir(path, 0700) == 0 || errno == EEXIST) {
        return true;
    }
    return false;
}

// Writes the persistent cookies atomically (temporary file, then rename). Must be called with the lock held.
static void __flushLocked(CFHTTPCookieStorageRef storage) {
    if (!storage->_persistent || !storage->_dirty || storage->_persistPath == NULL) {
        return;
    }
    storage->_dirty = false;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFMutableArrayRef entries = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(storage->_cookies); i++) {
        CFHTTPCookieRef cookie = (CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, i);
        if (CFHTTPCookieIsSessionOnly(cookie) || _CFHTTPCookieIsExpired(cookie, now)) {
            continue;
        }
        CFDictionaryRef entry = __copyPersistentRepresentation(cookie);
        CFArrayAppendValue(entries, entry);
        CFRelease(entry);
    }
    CFMutableDictionaryRef plist = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int version = kPersistenceFormatVersion;
    CFNumberRef versionNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &version);
    CFDictionarySetValue(plist, CFSTR("Version"), versionNumber);
    CFDictionarySetValue(plist, CFSTR("Cookies"), entries);
    CFRelease(versionNumber);
    CFRelease(entries);
    CFDataRef data = CFPropertyListCreateData(kCFAllocatorDefault, plist, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    CFRelease(plist);
    if (data == NULL) {
        return;
    }

    // Create ~/Library and ~/Library/Cookies if needed (owner-only), then write beside the target.
    char *directory = strdup(storage->_persistPath);
    char *slash = directory != NULL ? strrchr(directory, '/') : NULL;
    if (slash != NULL) {
        *slash = '\0';
        char *parent = strdup(directory);
        char *parentSlash = parent != NULL ? strrchr(parent, '/') : NULL;
        if (parentSlash != NULL) {
            *parentSlash = '\0';
            if (parent[0] != '\0') {
                __makeDirectory(parent);
            }
        }
        free(parent);
        if (__makeDirectory(directory)) {
            size_t length = strlen(storage->_persistPath) + 8;
            char *temporary = malloc(length);
            if (temporary != NULL) {
                snprintf(temporary, length, "%s.XXXXXX", storage->_persistPath);
                int fd = mkstemp(temporary); // created with mode 0600
                if (fd >= 0) {
                    const UInt8 *bytes = CFDataGetBytePtr(data);
                    size_t size = (size_t)CFDataGetLength(data), written = 0;
                    Boolean ok = true;
                    while (written < size) {
                        ssize_t n = write(fd, bytes + written, size - written);
                        if (n <= 0) {
                            ok = false;
                            break;
                        }
                        written += (size_t)n;
                    }
                    ok = ok && fsync(fd) == 0;
                    ok = (close(fd) == 0) && ok;
                    if (!ok || rename(temporary, storage->_persistPath) != 0) {
                        unlink(temporary);
                    }
                }
                free(temporary);
            }
        }
    }
    free(directory);
    CFRelease(data);
}

#pragma mark - Storage operations (lock held)

static void __markDirtyIfPersistent(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie) {
    if (cookie != NULL && !CFHTTPCookieIsSessionOnly(cookie)) {
        storage->_dirty = true;
    }
}

static void __removeAtIndex(CFHTTPCookieStorageRef storage, CFIndex index) {
    __markDirtyIfPersistent(storage, (CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, index));
    CFArrayRemoveValueAtIndex(storage->_cookies, index);
}

static void __pruneExpired(CFHTTPCookieStorageRef storage, CFAbsoluteTime now) {
    for (CFIndex i = CFArrayGetCount(storage->_cookies) - 1; i >= 0; i--) {
        if (_CFHTTPCookieIsExpired((CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, i), now)) {
            __removeAtIndex(storage, i);
        }
    }
}

// Stores the cookie, replacing the one with the same name, domain and path. A cookie that has
// already expired removes that one instead.
static void __setCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie, CFAbsoluteTime now) {
    CFIndex existing = __indexOfCookie(storage, cookie);
    if (_CFHTTPCookieIsExpired(cookie, now)) {
        if (existing != kCFNotFound) {
            __removeAtIndex(storage, existing);
        }
        return;
    }
    CFHTTPCookieRef stored = _CFHTTPCookieCreateStoredCopy(cookie, now);
    if (existing == kCFNotFound) {
        CFArrayAppendValue(storage->_cookies, stored);
    } else {
        __markDirtyIfPersistent(storage, (CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, existing));
        CFArraySetValueAtIndex(storage->_cookies, existing, stored);
    }
    __markDirtyIfPersistent(storage, stored);
    CFRelease(stored);
}

// Called after the lock is released.
static void __notifyChanged(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageChangeCallBack callBack, void *info) {
    if (callBack != NULL) {
        callBack(storage, info);
    }
}

#define BEGIN_MUTATION(storage) \
    __lock(storage); \
    __ensureLoaded(storage); \
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(); \
    Boolean changed = true; \
    __pruneExpired(storage, now);

#define END_MUTATION(storage) \
    __flushLocked(storage); \
    CFHTTPCookieStorageChangeCallBack callBack = changed ? storage->_changeCallBack : NULL; \
    void *callBackInfo = storage->_changeInfo; \
    __unlock(storage); \
    __notifyChanged(storage, callBack, callBackInfo);

#pragma mark - Public API

void CFHTTPCookieStorageSetChangeCallBack(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageChangeCallBack callBack, void *info) {
    __lock(storage);
    storage->_changeCallBack = callBack;
    storage->_changeInfo = info;
    __unlock(storage);
}

CFHTTPCookieStorageAcceptPolicy CFHTTPCookieStorageGetAcceptPolicy(CFHTTPCookieStorageRef storage) {
    __lock(storage);
    CFHTTPCookieStorageAcceptPolicy policy = storage->_policy;
    __unlock(storage);
    return policy;
}

void CFHTTPCookieStorageSetAcceptPolicy(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageAcceptPolicy policy) {
    if (policy != kCFHTTPCookieStorageAcceptPolicyAlways && policy != kCFHTTPCookieStorageAcceptPolicyNever
        && policy != kCFHTTPCookieStorageAcceptPolicyOnlyFromMainDocumentDomain) {
        return;
    }
    __lock(storage);
    storage->_policy = policy;
    __unlock(storage);
}

void CFHTTPCookieStorageDeleteCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie) {
    if (cookie == NULL) {
        return;
    }
    BEGIN_MUTATION(storage)
    CFIndex index = __indexOfCookie(storage, cookie);
    if (index != kCFNotFound) {
        __removeAtIndex(storage, index);
    }
    END_MUTATION(storage)
}

void CFHTTPCookieStorageSetCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie) {
    if (cookie == NULL) {
        return;
    }
    BEGIN_MUTATION(storage)
    __setCookie(storage, cookie, now);
    END_MUTATION(storage)
}

void CFHTTPCookieStorageSetCookies(CFHTTPCookieStorageRef storage, CFArrayRef cookies) {
    if (cookies == NULL) {
        return;
    }
    BEGIN_MUTATION(storage)
    for (CFIndex i = 0; i < CFArrayGetCount(cookies); i++) {
        __setCookie(storage, (CFHTTPCookieRef)CFArrayGetValueAtIndex(cookies, i), now);
    }
    END_MUTATION(storage)
}

void CFHTTPCookieStorageDeleteCookiesSinceDate(CFHTTPCookieStorageRef storage, CFDateRef date) {
    if (date == NULL) {
        return;
    }
    CFAbsoluteTime since = CFDateGetAbsoluteTime(date);
    BEGIN_MUTATION(storage)
    for (CFIndex i = CFArrayGetCount(storage->_cookies) - 1; i >= 0; i--) {
        if (_CFHTTPCookieGetStoredTime((CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, i)) >= since) {
            __removeAtIndex(storage, i);
        }
    }
    END_MUTATION(storage)
}

CFArrayRef CFHTTPCookieStorageCopyCookies(CFHTTPCookieStorageRef storage) {
    __lock(storage);
    __ensureLoaded(storage);
    __pruneExpired(storage, CFAbsoluteTimeGetCurrent());
    __flushLocked(storage);
    CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, storage->_cookies);
    __unlock(storage);
    return copy;
}

#pragma mark - URL matching

// Hosts that belong to the same site: equal, one a subdomain of the other, or sharing the registrable
// domain. Without a public suffix list, the registrable domain is the last two labels, or the last
// three under a two-letter country code whose second-level label is a common generic one.
static Boolean __isLabelSuffix(CFStringRef host, CFStringRef suffix) {
    CFIndex hostLength = CFStringGetLength(host), suffixLength = CFStringGetLength(suffix);
    if (CFStringCompare(host, suffix, 0) == kCFCompareEqualTo) {
        return true;
    }
    return hostLength > suffixLength + 1 && CFStringGetCharacterAtIndex(host, hostLength - suffixLength - 1) == '.'
        && CFStringCompareWithOptions(host, suffix, CFRangeMake(hostLength - suffixLength, suffixLength), 0) == kCFCompareEqualTo;
}

static CFStringRef __copyRegistrableDomain(CFStringRef host) {
    CFArrayRef labels = CFStringCreateArrayBySeparatingStrings(kCFAllocatorDefault, host, CFSTR("."));
    CFIndex count = CFArrayGetCount(labels);
    CFIndex keep = 2;
    if (count >= 3) {
        CFStringRef tld = CFArrayGetValueAtIndex(labels, count - 1);
        CFStringRef second = CFArrayGetValueAtIndex(labels, count - 2);
        if (CFStringGetLength(tld) == 2 && (CFStringCompare(second, CFSTR("co"), 0) == kCFCompareEqualTo
            || CFStringCompare(second, CFSTR("com"), 0) == kCFCompareEqualTo || CFStringCompare(second, CFSTR("org"), 0) == kCFCompareEqualTo
            || CFStringCompare(second, CFSTR("net"), 0) == kCFCompareEqualTo || CFStringCompare(second, CFSTR("gov"), 0) == kCFCompareEqualTo
            || CFStringCompare(second, CFSTR("edu"), 0) == kCFCompareEqualTo || CFStringCompare(second, CFSTR("ac"), 0) == kCFCompareEqualTo)) {
            keep = 3;
        }
    }
    CFStringRef result;
    if (count <= keep) {
        result = CFRetain(host);
    } else {
        const void *values[3];
        CFArrayGetValues(labels, CFRangeMake(count - keep, keep), values);
        CFArrayRef tail = CFArrayCreate(kCFAllocatorDefault, values, keep, &kCFTypeArrayCallBacks);
        result = CFStringCreateByCombiningStrings(kCFAllocatorDefault, tail, CFSTR("."));
        CFRelease(tail);
    }
    CFRelease(labels);
    return result;
}

static Boolean __hostsShareSite(CFStringRef a, CFStringRef b) {
    if (CFStringCompare(a, b, 0) == kCFCompareEqualTo) {
        return true;
    }
    if (_CFHTTPCookieHostIsIPAddress(a) || _CFHTTPCookieHostIsIPAddress(b)) {
        return false;
    }
    if (__isLabelSuffix(a, b) || __isLabelSuffix(b, a)) {
        return true;
    }
    CFStringRef siteA = __copyRegistrableDomain(a), siteB = __copyRegistrableDomain(b);
    Boolean same = CFStringCompare(siteA, siteB, 0) == kCFCompareEqualTo;
    CFRelease(siteA);
    CFRelease(siteB);
    return same;
}

// May a response from `host` set a cookie with this domain? The domain has to cover the host and,
// when it is a domain cookie, must not be a single label such as a top-level domain.
static Boolean __cookieDomainAcceptableForHost(CFHTTPCookieRef cookie, CFStringRef host) {
    CFStringRef domain = CFHTTPCookieGetDomain(cookie);
    if (_CFHTTPCookieIsHostOnly(cookie)) {
        return _CFHTTPCookieDomainMatchesHost(domain, host);
    }
    if (!_CFHTTPCookieDomainMatchesHost(domain, host)) {
        return false;
    }
    CFRange moreDots;
    if (CFStringFindWithOptions(domain, CFSTR("."), CFRangeMake(1, CFStringGetLength(domain) - 1), 0, &moreDots)) {
        return true;
    }
    // ".localhost"-style single labels are accepted only for the host itself.
    CFStringRef bare = CFStringCreateWithSubstring(kCFAllocatorDefault, domain, CFRangeMake(1, CFStringGetLength(domain) - 1));
    Boolean same = CFStringCompare(bare, host, 0) == kCFCompareEqualTo;
    CFRelease(bare);
    return same;
}

void CFHTTPCookieStorageSetCookiesForURL(CFHTTPCookieStorageRef storage, CFArrayRef cookies, CFURLRef url, CFURLRef mainDocumentURL) {
    if (cookies == NULL) {
        return;
    }
    CFStringRef host = _CFHTTPCookieCopyHostOfURL(url);
    CFStringRef mainHost = _CFHTTPCookieCopyHostOfURL(mainDocumentURL);

    BEGIN_MUTATION(storage)
    CFHTTPCookieStorageAcceptPolicy policy = storage->_policy;
    Boolean accept = host != NULL && policy != kCFHTTPCookieStorageAcceptPolicyNever;
    // QUIRK: with the main-document policy, a missing main document URL does not block the cookies.
    // Not documented. Evidence: black-box observation on macOS 27 (tier 2), probe
    // vd-upstream/mac-probes/v377-cookie-storage.m (section I).
    // Test: cookie-storage.m, "accept policy: main document nil".
    if (accept && policy == kCFHTTPCookieStorageAcceptPolicyOnlyFromMainDocumentDomain && mainHost != NULL) {
        accept = __hostsShareSite(host, mainHost);
    }
    changed = false;
    if (accept) {
        for (CFIndex i = 0; i < CFArrayGetCount(cookies); i++) {
            CFHTTPCookieRef cookie = (CFHTTPCookieRef)CFArrayGetValueAtIndex(cookies, i);
            if (__cookieDomainAcceptableForHost(cookie, host)) {
                __setCookie(storage, cookie, now);
                changed = true;
            }
        }
    }
    END_MUTATION(storage)

    if (host != NULL) CFRelease(host);
    if (mainHost != NULL) CFRelease(mainHost);
}

struct __CookieMatch {
    CFHTTPCookieRef cookie;
    CFIndex order;
    CFIndex pathLength;
};

// Longer paths first (RFC 6265 section 5.4). Among equal paths, QUIRK: by domain and then by name,
// both ascending, rather than by creation time. Not documented. Evidence: black-box observation on
// macOS 27 (tier 2), probe vd-upstream/mac-probes/v377-cookie-storage.m (sections B, F, P).
// Test: cookie-storage.m, "quirk: cookies with equal paths are ordered by domain, then name".
static Boolean __matchComesBefore(const struct __CookieMatch *a, const struct __CookieMatch *b) {
    if (a->pathLength != b->pathLength) {
        return a->pathLength > b->pathLength;
    }
    CFComparisonResult domains = CFStringCompare(CFHTTPCookieGetDomain(a->cookie), CFHTTPCookieGetDomain(b->cookie), 0);
    if (domains != kCFCompareEqualTo) {
        return domains == kCFCompareLessThan;
    }
    CFComparisonResult names = CFStringCompare(CFHTTPCookieGetName(a->cookie), CFHTTPCookieGetName(b->cookie), 0);
    if (names != kCFCompareEqualTo) {
        return names == kCFCompareLessThan;
    }
    return a->order < b->order;
}

CFArrayRef CFHTTPCookieStorageCopyCookiesForURL(CFHTTPCookieStorageRef storage, CFURLRef url) {
    CFStringRef host = _CFHTTPCookieCopyHostOfURL(url);
    if (host == NULL) {
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }

    CFStringRef scheme = CFURLCopyScheme(url);
    Boolean secureTransport = scheme != NULL
        && (CFStringCompare(scheme, CFSTR("https"), kCFCompareCaseInsensitive) == kCFCompareEqualTo
            || CFStringCompare(scheme, CFSTR("wss"), kCFCompareCaseInsensitive) == kCFCompareEqualTo);
    if (scheme != NULL) CFRelease(scheme);

    CFStringRef urlPath = CFURLCopyPath(url);
    CFStringRef requestPath = (urlPath == NULL || CFStringGetLength(urlPath) == 0) ? CFRetain(CFSTR("/")) : CFRetain(urlPath);
    if (urlPath != NULL) CFRelease(urlPath);

    __lock(storage);
    __ensureLoaded(storage);
    __pruneExpired(storage, CFAbsoluteTimeGetCurrent());
    __flushLocked(storage);

    CFIndex count = CFArrayGetCount(storage->_cookies);
    struct __CookieMatch *matches = malloc((count > 0 ? count : 1) * sizeof(struct __CookieMatch));
    CFIndex matchCount = 0;
    for (CFIndex i = 0; matches != NULL && i < count; i++) {
        CFHTTPCookieRef cookie = (CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, i);
        if ((CFHTTPCookieIsSecure(cookie) && !secureTransport)
            || !_CFHTTPCookieDomainMatchesHost(CFHTTPCookieGetDomain(cookie), host)
            || !_CFHTTPCookiePathMatchesPath(CFHTTPCookieGetPath(cookie), requestPath)) {
            continue;
        }
        struct __CookieMatch entry = { cookie, i, CFStringGetLength(CFHTTPCookieGetPath(cookie)) };
        CFIndex j = matchCount++;
        while (j > 0 && __matchComesBefore(&entry, &matches[j - 1])) {
            matches[j] = matches[j - 1];
            j--;
        }
        matches[j] = entry;
    }

    CFMutableArrayRef result = CFArrayCreateMutable(kCFAllocatorDefault, matchCount, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < matchCount; i++) {
        CFArrayAppendValue(result, matches[i].cookie);
    }
    __unlock(storage);

    free(matches);
    CFRelease(host);
    CFRelease(requestPath);
    CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, result);
    CFRelease(result);
    return copy;
}

void CFHTTPCookieStorageSetCookiesWithResponseHeaderFields(CFHTTPCookieStorageRef storage, CFDictionaryRef headerFields, CFURLRef url) {
    CFHTTPCookieStorageSetCookiesWithResponseHeaderFieldsForMainDocument(storage, headerFields, url, NULL);
}

void CFHTTPCookieStorageSetCookiesWithResponseHeaderFieldsForMainDocument(CFHTTPCookieStorageRef storage, CFDictionaryRef headerFields, CFURLRef url, CFURLRef mainDocumentURL) {
    CFArrayRef cookies = CFHTTPCookieCreateWithResponseHeaderFields(headerFields, url);
    if (cookies != NULL) {
        CFHTTPCookieStorageSetCookiesForURL(storage, cookies, url, mainDocumentURL);
        CFRelease(cookies);
    }
}

CFDictionaryRef CFHTTPCookieStorageCopyRequestHeaderFieldsForURL(CFHTTPCookieStorageRef storage, CFURLRef url) {
    CFArrayRef cookies = CFHTTPCookieStorageCopyCookiesForURL(storage, url);
    CFDictionaryRef result = NULL;
    if (CFArrayGetCount(cookies) > 0) {
        result = CFHTTPCookieCopyRequestHeaderFields(cookies);
    }
    CFRelease(cookies);
    return result;
}

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
#include <CoreFoundation/CFRunLoop.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The storage holds immutable cookies in an array protected by a mutex. The default storage is
// persistent: its non-session cookies live in a property list under ~/Library/Cookies, named after
// the main bundle identifier (or the process name when there is none). A storage made with
// CFHTTPCookieStorageCreateFromFile, or from the identifying data of another, keeps them in that
// file instead. The file is read the first time the storage is used and rewritten atomically
// whenever a persistent cookie changes.

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
    // where the change callback is called, when the storage is scheduled
    CFRunLoopRef _runLoop;
    CFStringRef _runLoopMode;
    // the change handlers (SPI) and the hosts they are called for; see "Change handlers" below
    _CFHTTPCookieStorageCookiesAddedHandler _addedHandler;
    dispatch_queue_t _addedQueue;
    _CFHTTPCookieStorageCookiesRemovedHandler _removedHandler;
    dispatch_queue_t _removedQueue;
    CFSetRef _subscribedHosts;
    // what the mutation in progress adds and removes, for the change handlers (NULL if there are none)
    CFMutableArrayRef _changeAdded;
    CFMutableArrayRef _changeRemoved;
    Boolean _changeRemovedAll;
};

#define kPersistenceFormatVersion 1

static void __CFHTTPCookieStorageDeallocate(CFTypeRef cf) {
    struct __CFHTTPCookieStorage *item = (struct __CFHTTPCookieStorage *)cf;
    CFRelease(item->_cookies);
    free(item->_persistPath);
    if (item->_runLoop != NULL) CFRelease(item->_runLoop);
    if (item->_runLoopMode != NULL) CFRelease(item->_runLoopMode);
    if (item->_addedHandler != NULL) Block_release(item->_addedHandler);
    if (item->_addedQueue != NULL) dispatch_release(item->_addedQueue);
    if (item->_removedHandler != NULL) Block_release(item->_removedHandler);
    if (item->_removedQueue != NULL) dispatch_release(item->_removedQueue);
    if (item->_subscribedHosts != NULL) CFRelease(item->_subscribedHosts);
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

// A storage of its own that is kept in memory only, for a storage session.
CFHTTPCookieStorageRef __CFHTTPCookieStorageCreateInMemory(CFAllocatorRef allocator) {
    return (CFHTTPCookieStorageRef)_CFHTTPCookieStorageCreate(allocator, false);
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
    if (storage->_persistPath == NULL) {
        storage->_persistPath = __createPersistencePath();
    }
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

// Records a cookie the mutation in progress added (or removed) for the change handlers.
static void __recordAdded(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie) {
    if (storage->_changeAdded != NULL) {
        CFArrayAppendValue(storage->_changeAdded, cookie);
    }
}

static void __recordRemoved(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie) {
    if (storage->_changeRemoved != NULL) {
        CFArrayAppendValue(storage->_changeRemoved, cookie);
    }
}

// Stores the cookie, replacing the one with the same name, domain and path. A cookie that has
// already expired removes that one instead.
static void __setCookie(CFHTTPCookieStorageRef storage, CFHTTPCookieRef cookie, CFAbsoluteTime now) {
    CFIndex existing = __indexOfCookie(storage, cookie);
    if (_CFHTTPCookieIsExpired(cookie, now)) {
        if (existing != kCFNotFound) {
            __removeAtIndex(storage, existing);
            // QUIRK: the change handlers are told that the expired cookie was added, not that the
            // stored one was removed. Not documented. Evidence: black-box observation on macOS
            // 26.7.3 (tier 2). Test: tests/nshttpcookiestorage-change-handlers.m, "expired cookie
            // replacing a stored one".
            __recordAdded(storage, cookie);
        }
        return;
    }
    CFHTTPCookieRef stored = _CFHTTPCookieCreateStoredCopy(cookie, now);
    if (existing == kCFNotFound) {
        CFArrayAppendValue(storage->_cookies, stored);
        __recordAdded(storage, stored);
    } else {
        CFHTTPCookieRef previous = (CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, existing);
        // storing the same cookie again is no change to report
        if (!_CFHTTPCookieHasSameProperties(previous, stored)) {
            __recordAdded(storage, stored);
        }
        __markDirtyIfPersistent(storage, previous);
        CFArraySetValueAtIndex(storage->_cookies, existing, stored);
    }
    __markDirtyIfPersistent(storage, stored);
    CFRelease(stored);
}

#pragma mark - Change handlers

// SPI. The handlers of a storage are called (asynchronously, on their queue or else on a global
// one) for the hosts subscribed to, as observed on macOS 26.7.3 (test:
// tests/nshttpcookiestorage-change-handlers.m):
// - with nobody subscribed, no handler is called;
// - for each subscribed host, the added handler gets the cookies one call to the storage stored
//   or changed that a request to that host would carry (a host-only cookie of the host, or a
//   domain cookie of it or of a domain above it), with the host; storing a cookie again unchanged
//   is no change;
// - the removed handler gets the deleted cookies the same way;
// - deleting all cookies calls the removed handler once, with no cookies and no host.
// Cookies a storage drops because they have expired are not reported.

typedef struct {
    _CFHTTPCookieStorageCookiesAddedHandler addedHandler;
    dispatch_queue_t addedQueue;
    _CFHTTPCookieStorageCookiesRemovedHandler removedHandler;
    dispatch_queue_t removedQueue;
    CFSetRef hosts;
    CFArrayRef added;
    CFArrayRef removed;
    Boolean removedAll;
} __CFHTTPCookieStorageChanges;

// Lock held. Starts recording the changes of a mutation if a handler will want them.
static void __beginChanges(CFHTTPCookieStorageRef storage) {
    storage->_changeAdded = NULL;
    storage->_changeRemoved = NULL;
    storage->_changeRemovedAll = false;
    if (storage->_subscribedHosts == NULL || CFSetGetCount(storage->_subscribedHosts) == 0) {
        return;
    }
    if (storage->_addedHandler != NULL) {
        storage->_changeAdded = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    }
    if (storage->_removedHandler != NULL) {
        storage->_changeRemoved = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    }
}

// Lock held. Takes the recorded changes, with what is needed to report them once the lock is released.
static void __takeChanges(CFHTTPCookieStorageRef storage, __CFHTTPCookieStorageChanges *changes) {
    memset(changes, 0, sizeof(*changes));
    changes->added = storage->_changeAdded;
    changes->removed = storage->_changeRemoved;
    changes->removedAll = storage->_changeRemovedAll && storage->_changeRemoved != NULL;
    storage->_changeAdded = NULL;
    storage->_changeRemoved = NULL;
    storage->_changeRemovedAll = false;
    if (changes->added == NULL && changes->removed == NULL) {
        return;
    }
    changes->hosts = CFSetCreateCopy(kCFAllocatorDefault, storage->_subscribedHosts);
    if (changes->added != NULL) {
        changes->addedHandler = Block_copy(storage->_addedHandler);
        changes->addedQueue = storage->_addedQueue;
        if (changes->addedQueue != NULL) dispatch_retain(changes->addedQueue);
    }
    if (changes->removed != NULL) {
        changes->removedHandler = Block_copy(storage->_removedHandler);
        changes->removedQueue = storage->_removedQueue;
        if (changes->removedQueue != NULL) dispatch_retain(changes->removedQueue);
    }
}

// QUIRK: a subscribed host is compared with the cookies' (lowercase) domains as it is, so a host
// that is not in lowercase is told about no cookie. Not documented. Evidence: black-box observation
// on macOS 26.7.3 (tier 2). Test: tests/nshttpcookiestorage-change-handlers.m, "uppercase host".
static Boolean __subscribedHostMatches(CFHTTPCookieRef cookie, CFStringRef host) {
    CFMutableStringRef lowercase = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, host);
    CFStringLowercase(lowercase, NULL);
    Boolean isLowercase = CFStringCompare(lowercase, host, 0) == kCFCompareEqualTo;
    CFRelease(lowercase);
    return isLowercase && _CFHTTPCookieDomainMatchesHost(CFHTTPCookieGetDomain(cookie), host);
}

static dispatch_queue_t __handlerQueue(dispatch_queue_t queue) {
    return queue != NULL ? queue : dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
}

// Lock not held. Calls the handlers for the changes and releases them.
static void __reportChanges(__CFHTTPCookieStorageChanges *changes) {
    if (changes->hosts != NULL) {
        CFIndex hostCount = CFSetGetCount(changes->hosts);
        CFStringRef *hosts = malloc(sizeof(CFStringRef) * (hostCount > 0 ? hostCount : 1));
        CFSetGetValues(changes->hosts, (const void **)hosts);
        for (CFIndex h = 0; h < hostCount; h++) {
            CFStringRef host = hosts[h];
            if (CFGetTypeID(host) != CFStringGetTypeID()) {
                continue;
            }
            for (int kind = 0; kind < 2; kind++) {
                CFArrayRef cookies = kind == 0 ? changes->added : changes->removed;
                if (cookies == NULL) {
                    continue;
                }
                CFMutableArrayRef matching = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
                for (CFIndex i = 0; i < CFArrayGetCount(cookies); i++) {
                    CFHTTPCookieRef cookie = (CFHTTPCookieRef)CFArrayGetValueAtIndex(cookies, i);
                    if (__subscribedHostMatches(cookie, host)) {
                        CFArrayAppendValue(matching, cookie);
                    }
                }
                if (CFArrayGetCount(matching) == 0) {
                    CFRelease(matching);
                    continue;
                }
                CFRetain(host);
                if (kind == 0) {
                    _CFHTTPCookieStorageCookiesAddedHandler handler = changes->addedHandler;
                    dispatch_async(__handlerQueue(changes->addedQueue), ^{
                        handler(matching, host);
                        CFRelease(matching);
                        CFRelease(host);
                    });
                } else {
                    _CFHTTPCookieStorageCookiesRemovedHandler handler = changes->removedHandler;
                    dispatch_async(__handlerQueue(changes->removedQueue), ^{
                        handler(matching, host, false);
                        CFRelease(matching);
                        CFRelease(host);
                    });
                }
            }
        }
        free(hosts);
        CFRelease(changes->hosts);
    }
    if (changes->removedAll) {
        _CFHTTPCookieStorageCookiesRemovedHandler handler = changes->removedHandler;
        dispatch_async(__handlerQueue(changes->removedQueue), ^{
            handler(NULL, NULL, true);
        });
    }
    if (changes->added != NULL) CFRelease(changes->added);
    if (changes->removed != NULL) CFRelease(changes->removed);
    if (changes->addedHandler != NULL) Block_release(changes->addedHandler);
    if (changes->addedQueue != NULL) dispatch_release(changes->addedQueue);
    if (changes->removedHandler != NULL) Block_release(changes->removedHandler);
    if (changes->removedQueue != NULL) dispatch_release(changes->removedQueue);
}

void _CFHTTPCookieStorageSetCookiesAddedHandler(CFHTTPCookieStorageRef storage, _CFHTTPCookieStorageCookiesAddedHandler handler, dispatch_queue_t queue) {
    handler = handler != NULL ? Block_copy(handler) : NULL;
    if (queue != NULL) dispatch_retain(queue);
    __lock(storage);
    _CFHTTPCookieStorageCookiesAddedHandler oldHandler = storage->_addedHandler;
    dispatch_queue_t oldQueue = storage->_addedQueue;
    storage->_addedHandler = handler;
    storage->_addedQueue = queue;
    __unlock(storage);
    if (oldHandler != NULL) Block_release(oldHandler);
    if (oldQueue != NULL) dispatch_release(oldQueue);
}

void _CFHTTPCookieStorageSetCookiesRemovedHandler(CFHTTPCookieStorageRef storage, _CFHTTPCookieStorageCookiesRemovedHandler handler, dispatch_queue_t queue) {
    handler = handler != NULL ? Block_copy(handler) : NULL;
    if (queue != NULL) dispatch_retain(queue);
    __lock(storage);
    _CFHTTPCookieStorageCookiesRemovedHandler oldHandler = storage->_removedHandler;
    dispatch_queue_t oldQueue = storage->_removedQueue;
    storage->_removedHandler = handler;
    storage->_removedQueue = queue;
    __unlock(storage);
    if (oldHandler != NULL) Block_release(oldHandler);
    if (oldQueue != NULL) dispatch_release(oldQueue);
}

void _CFHTTPCookieStorageSetSubscribedHosts(CFHTTPCookieStorageRef storage, CFSetRef hosts) {
    CFSetRef copy = hosts != NULL ? CFSetCreateCopy(kCFAllocatorDefault, hosts) : NULL;
    __lock(storage);
    CFSetRef old = storage->_subscribedHosts;
    storage->_subscribedHosts = copy;
    __unlock(storage);
    if (old != NULL) CFRelease(old);
}

// Called after the lock is released, with the run loop and mode the storage was scheduled with
// (retained) or NULL: the callback is then called on that run loop, or else right away.
static void __notifyChanged(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageChangeCallBack callBack, void *info,
                            CFRunLoopRef runLoop, CFStringRef mode) {
    if (callBack != NULL) {
        if (runLoop != NULL) {
            CFRetain(storage);
            CFRunLoopPerformBlock(runLoop, mode, ^{
                callBack(storage, info);
                CFRelease(storage);
            });
            CFRunLoopWakeUp(runLoop);
        } else {
            callBack(storage, info);
        }
    }
    if (runLoop != NULL) CFRelease(runLoop);
    if (mode != NULL) CFRelease(mode);
}

#define BEGIN_MUTATION(storage) \
    __lock(storage); \
    __ensureLoaded(storage); \
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(); \
    Boolean changed = true; \
    __pruneExpired(storage, now); \
    __beginChanges(storage);

#define END_MUTATION(storage) \
    __flushLocked(storage); \
    CFHTTPCookieStorageChangeCallBack callBack = changed ? storage->_changeCallBack : NULL; \
    void *callBackInfo = storage->_changeInfo; \
    CFRunLoopRef callBackRunLoop = callBack != NULL && storage->_runLoop != NULL ? (CFRunLoopRef)CFRetain(storage->_runLoop) : NULL; \
    CFStringRef callBackMode = callBackRunLoop != NULL ? (CFStringRef)CFRetain(storage->_runLoopMode) : NULL; \
    __CFHTTPCookieStorageChanges handlerChanges; \
    __takeChanges(storage, &handlerChanges); \
    __unlock(storage); \
    __notifyChanged(storage, callBack, callBackInfo, callBackRunLoop, callBackMode); \
    __reportChanges(&handlerChanges);

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

// Calls the change callback on the run loop, in the mode, from now on, rather than right away on the
// thread that changed the cookies.
void CFHTTPCookieStorageScheduleWithRunLoop(CFHTTPCookieStorageRef storage, CFRunLoopRef runLoop, CFStringRef mode) {
    if (runLoop == NULL || mode == NULL) {
        return;
    }
    CFRetain(runLoop);
    CFStringRef modeCopy = CFStringCreateCopy(kCFAllocatorDefault, mode);
    __lock(storage);
    CFRunLoopRef oldRunLoop = storage->_runLoop;
    CFStringRef oldMode = storage->_runLoopMode;
    storage->_runLoop = runLoop;
    storage->_runLoopMode = modeCopy;
    __unlock(storage);
    if (oldRunLoop != NULL) CFRelease(oldRunLoop);
    if (oldMode != NULL) CFRelease(oldMode);
}

#pragma mark - Storages in files

// The file that a storage made from the URL keeps its cookies in: the URL's path, for a URL of any
// scheme (as on macOS 26.7.3, where http://example.com/c gives a storage on /c). NULL when the URL
// has no usable path.
static char *__createPathFromURL(CFURLRef url) {
    char path[PATH_MAX];
    if (CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path) && path[0] == '/') {
        return strdup(path);
    }
    CFStringRef urlPath = CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle);
    if (urlPath == NULL) {
        return NULL;
    }
    Boolean ok = CFStringGetFileSystemRepresentation(urlPath, path, sizeof path) && path[0] == '/';
    CFRelease(urlPath);
    return ok ? strdup(path) : NULL;
}

// A persistent storage whose cookies are kept in the file. Without a URL, or with one that has no
// path, the file is the process's default cookie file, as for the default storage (macOS 26.7.3
// gives a storage on ~/Library/HTTPStorages/<process>.binarycookies for a NULL URL). The third
// argument, a storage to share with, is not used.
CFHTTPCookieStorageRef CFHTTPCookieStorageCreateFromFile(CFAllocatorRef allocator, CFURLRef url, CFHTTPCookieStorageRef sharedStorage) {
    struct __CFHTTPCookieStorage *storage = _CFHTTPCookieStorageCreate(allocator, true);
    if (url != NULL) {
        storage->_persistPath = __createPathFromURL(url);
    }
    return (CFHTTPCookieStorageRef)storage;
}

// The identifying data names the storage's file, so that another storage, in this process or
// another, can be opened on the same cookies. Its format is Darling's own: a binary property list
// holding the path. NULL for a storage kept in memory only, which has no file, and when no home
// directory can be found for the default file.
static const CFStringRef kIdentifyingDataPathKey = CFSTR("Path");

CFDataRef CFHTTPCookieStorageCreateIdentifyingData(CFAllocatorRef allocator, CFHTTPCookieStorageRef storage) {
    if (storage == NULL) {
        return NULL;
    }
    __lock(storage);
    if (storage->_persistent && storage->_persistPath == NULL) {
        storage->_persistPath = __createPersistencePath();
    }
    CFStringRef path = storage->_persistent && storage->_persistPath != NULL
        ? CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, storage->_persistPath) : NULL;
    __unlock(storage);
    if (path == NULL) {
        return NULL;
    }
    CFDictionaryRef plist = CFDictionaryCreate(kCFAllocatorDefault, (const void **)&kIdentifyingDataPathKey, (const void **)&path, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(path);
    CFDataRef data = CFPropertyListCreateData(allocator, plist, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(plist);
    return data;
}

// A new storage on the file that the data names; NULL when the data does not name one.
CFHTTPCookieStorageRef CFHTTPCookieStorageCreateFromIdentifyingData(CFAllocatorRef allocator, CFDataRef data) {
    if (data == NULL) {
        return NULL;
    }
    CFPropertyListRef plist = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
    if (plist == NULL) {
        return NULL;
    }
    CFHTTPCookieStorageRef storage = NULL;
    if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFTypeRef path = CFDictionaryGetValue(plist, kIdentifyingDataPathKey);
        char buffer[PATH_MAX];
        if (path != NULL && CFGetTypeID(path) == CFStringGetTypeID()
            && CFStringGetFileSystemRepresentation(path, buffer, sizeof buffer) && buffer[0] == '/') {
            struct __CFHTTPCookieStorage *created = _CFHTTPCookieStorageCreate(allocator, true);
            created->_persistPath = strdup(buffer);
            storage = (CFHTTPCookieStorageRef)created;
        }
    }
    CFRelease(plist);
    return storage;
}

// The same storage as CFHTTPCookieStorageGetDefault(); the allocator is not used.
CFHTTPCookieStorageRef _CFHTTPCookieStorageGetDefault(CFAllocatorRef allocator) {
    return CFHTTPCookieStorageGetDefault();
}

// The names WebKit and Foundation use for the accept policy accessors.
CFHTTPCookieStorageAcceptPolicy CFHTTPCookieStorageGetCookieAcceptPolicy(CFHTTPCookieStorageRef storage) {
    return CFHTTPCookieStorageGetAcceptPolicy(storage);
}

void CFHTTPCookieStorageSetCookieAcceptPolicy(CFHTTPCookieStorageRef storage, CFHTTPCookieStorageAcceptPolicy policy) {
    CFHTTPCookieStorageSetAcceptPolicy(storage, policy);
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
    // QUIRK: the removed handler is told about the cookie even if the storage did not have it. Not
    // documented. Evidence: black-box observation on macOS 26.7.3 (tier 2). Test:
    // tests/nshttpcookiestorage-change-handlers.m, "deleting a cookie that is not stored".
    __recordRemoved(storage, cookie);
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

void CFHTTPCookieStorageDeleteAllCookies(CFHTTPCookieStorageRef storage) {
    BEGIN_MUTATION(storage)
    changed = CFArrayGetCount(storage->_cookies) > 0;
    for (CFIndex i = CFArrayGetCount(storage->_cookies) - 1; i >= 0; i--) {
        __removeAtIndex(storage, i);
    }
    // the removed handler is called even if there was nothing to delete (macOS 26.7.3)
    storage->_changeRemovedAll = true;
    END_MUTATION(storage)
}

void CFHTTPCookieStorageDeleteCookiesSinceDate(CFHTTPCookieStorageRef storage, CFDateRef date) {
    if (date == NULL) {
        return;
    }
    CFAbsoluteTime since = CFDateGetAbsoluteTime(date);
    BEGIN_MUTATION(storage)
    for (CFIndex i = CFArrayGetCount(storage->_cookies) - 1; i >= 0; i--) {
        CFHTTPCookieRef cookie = (CFHTTPCookieRef)CFArrayGetValueAtIndex(storage->_cookies, i);
        if (_CFHTTPCookieGetStoredTime(cookie) >= since) {
            __recordRemoved(storage, cookie);
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
    // A domain that is the host itself, such as the local file domain for a file URL.
    if (domain != NULL && CFStringCompare(domain, host, kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        return true;
    }
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

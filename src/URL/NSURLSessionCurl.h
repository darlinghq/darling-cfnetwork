#import <Foundation/NSObject.h>
#include <curl/curl.h>

@class NSString;

// libcurl is loaded on first use instead of being linked: libcurl links
// Kerberos, which links Heimdal, which links CFNetwork.
typedef struct {
    CURL *(*easy_init)(void);
    CURLcode (*easy_setopt)(CURL *handle, CURLoption option, ...);
    CURLcode (*easy_getinfo)(CURL *handle, CURLINFO info, ...);
    CURLcode (*easy_pause)(CURL *handle, int bitmask);
    void (*easy_cleanup)(CURL *handle);
    const char *(*easy_strerror)(CURLcode code);
    struct curl_slist *(*slist_append)(struct curl_slist *list, const char *string);
    void (*slist_free_all)(struct curl_slist *list);
} _NSURLSessionCurlAPI;

// Returns NULL and sets *errorDescription if libcurl cannot be loaded.
const _NSURLSessionCurlAPI *_NSURLSessionCurlGetAPI(NSString **errorDescription);

// Called on the transport thread when a transfer added with
// _NSURLSessionCurlAddHandle finishes; the handle is already removed.
@protocol _NSURLSessionCurlTransfer <NSObject>
- (void)_curlTransferDidCompleteWithCode:(CURLcode)code;
@end

// Runs block on the transport thread, which owns every easy handle.
// Only valid after _NSURLSessionCurlGetAPI succeeded.
void _NSURLSessionCurlPerform(void (^block)(void));

// Transport thread only. The transfer is CURLOPT_PRIVATE of the handle.
CURLMcode _NSURLSessionCurlAddHandle(CURL *easy);
void _NSURLSessionCurlRemoveHandle(CURL *easy);

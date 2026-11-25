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
    CURLcode (*easy_send)(CURL *handle, const void *buffer, size_t length, size_t *sent);
    CURLcode (*easy_recv)(CURL *handle, void *buffer, size_t length, size_t *received);
} _NSURLSessionCurlAPI;

// Returns NULL and sets *errorDescription if libcurl cannot be loaded.
const _NSURLSessionCurlAPI *_NSURLSessionCurlGetAPI(NSString **errorDescription);

// Called on the transport thread when a transfer added with
// _NSURLSessionCurlAddHandle finishes; the handle is already removed.
@protocol _NSURLSessionCurlTransfer <NSObject>
- (void)_curlTransferDidCompleteWithCode:(CURLcode)code;
@optional
// YES leaves the handle in the multi handle once its transfer is done; the
// transfer removes it with _NSURLSessionCurlRemoveHandle. A handle made with
// CURLOPT_CONNECT_ONLY needs this, since libcurl closes its connection when
// it leaves the multi handle.
- (BOOL)_curlTransferKeepsHandle;
@end

// Runs block on the transport thread, which owns every easy handle.
// Only valid after _NSURLSessionCurlGetAPI succeeded.
void _NSURLSessionCurlPerform(void (^block)(void));

// Transport thread only. The transfer is CURLOPT_PRIVATE of the handle.
CURLMcode _NSURLSessionCurlAddHandle(CURL *easy);
void _NSURLSessionCurlRemoveHandle(CURL *easy);

// Transport thread only. While the socket of a connection that a handle made
// with CURLOPT_CONNECT_ONLY is watched, handler runs on the transport thread
// each time the socket has any of events (CURL_WAIT_POLLIN, CURL_WAIT_POLLOUT)
// to report, with those it has. Watching a socket again replaces the events
// and the handler.
void _NSURLSessionCurlWatchSocket(curl_socket_t socket, short events, void (^handler)(short events));
void _NSURLSessionCurlUnwatchSocket(curl_socket_t socket);

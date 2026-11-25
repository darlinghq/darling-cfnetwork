// Copyright (C) 2026 Lubos Dolezel
//
// _kCFStreamSocketSetNoDelay, the socket stream property with which a client
// asks for TCP_NODELAY. Values are those observed on macOS 26.7.3 and
// Mac OS X 10.14.4, where the program builds and runs too:
//  - the property reads back as kCFBooleanTrue or kCFBooleanFalse, false
//    until it is set and whether or not the streams are open;
//  - only kCFBooleanTrue turns it on; any other value, or none, turns it off;
//  - setting it succeeds before or after open, on either stream of a pair,
//    and the option is on the socket once both it and the flag are;
//  - quirk: turning the flag off leaves the option on a socket it was on for;
//  - a stream that is not a socket stream refuses it.
// Connects to a listening socket on the loopback interface.
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

extern const CFStringRef _kCFStreamSocketSetNoDelay;

static int failures;

static void expect(int ok, const char *what)
{
    printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        failures++;
}

static int listener;
static int port;

static int optionOn(CFWriteStreamRef stream)
{
    CFDataRef handle = CFWriteStreamCopyProperty(stream, kCFStreamPropertySocketNativeHandle);
    if (handle == NULL)
        return -1;
    CFSocketNativeHandle fd = -1;
    CFDataGetBytes(handle, CFRangeMake(0, sizeof fd), (UInt8 *) &fd);
    CFRelease(handle);
    int value = 0;
    socklen_t length = sizeof value;
    if (getsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, &length) != 0)
        return -1;
    return value != 0;
}

// The value the write stream reports: 1 true, 0 false, -1 anything else.
static int flag(CFWriteStreamRef stream)
{
    CFTypeRef value = CFWriteStreamCopyProperty(stream, _kCFStreamSocketSetNoDelay);
    int result = value == kCFBooleanTrue ? 1 : value == kCFBooleanFalse ? 0 : -1;
    if (value != NULL)
        CFRelease(value);
    return result;
}

typedef struct {
    CFReadStreamRef read;
    CFWriteStreamRef write;
    int peer;
} Pair;

static Pair makePair(void)
{
    Pair pair = { NULL, NULL, -1 };
    CFStreamCreatePairWithSocketToHost(NULL, CFSTR("127.0.0.1"), port, &pair.read, &pair.write);
    return pair;
}

static int openPair(Pair *pair)
{
    CFReadStreamOpen(pair->read);
    CFWriteStreamOpen(pair->write);
    for (int i = 0; i < 500 && CFWriteStreamGetStatus(pair->write) == kCFStreamStatusOpening; i++)
        usleep(10000);
    pair->peer = accept(listener, NULL, NULL);
    return CFWriteStreamGetStatus(pair->write) == kCFStreamStatusOpen;
}

static void dispose(Pair *pair)
{
    CFReadStreamClose(pair->read);
    CFWriteStreamClose(pair->write);
    CFRelease(pair->read);
    CFRelease(pair->write);
    if (pair->peer >= 0)
        close(pair->peer);
}

int main(void)
{
    struct sockaddr_in address = { 0 };
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof address;
    listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *) &address, length) != 0 || listen(listener, 4) != 0
        || getsockname(listener, (struct sockaddr *) &address, &length) != 0) {
        perror("listen");
        return 1;
    }
    port = ntohs(address.sin_port);

    Pair pair = makePair();
    expect(flag(pair.write) == 0, "the flag is off before it is set");
    expect(openPair(&pair), "the streams open");
    expect(flag(pair.write) == 0 && optionOn(pair.write) == 0, "unset, the option stays off");
    dispose(&pair);

    pair = makePair();
    expect(CFWriteStreamSetProperty(pair.write, _kCFStreamSocketSetNoDelay, kCFBooleanTrue), "set true before open");
    expect(flag(pair.write) == 1, "the flag reads back before open");
    openPair(&pair);
    expect(flag(pair.write) == 1 && optionOn(pair.write) == 1, "set before open, the socket gets the option");
    CFWriteStreamClose(pair.write);
    expect(flag(pair.write) == 1, "the flag reads back after close");
    dispose(&pair);

    CFTypeRef offValues[] = { kCFBooleanFalse, CFSTR("yes"), NULL };
    const char *offNames[] = { "kCFBooleanFalse", "a string", "no value" };
    for (int i = 0; i < 3; i++) {
        char what[100];
        pair = makePair();
        CFWriteStreamSetProperty(pair.write, _kCFStreamSocketSetNoDelay, kCFBooleanTrue);
        snprintf(what, sizeof what, "setting %s succeeds", offNames[i]);
        expect(CFWriteStreamSetProperty(pair.write, _kCFStreamSocketSetNoDelay, offValues[i]), what);
        openPair(&pair);
        snprintf(what, sizeof what, "%s turns the flag off before open", offNames[i]);
        expect(flag(pair.write) == 0 && optionOn(pair.write) == 0, what);
        dispose(&pair);
    }

    pair = makePair();
    openPair(&pair);
    expect(CFWriteStreamSetProperty(pair.write, _kCFStreamSocketSetNoDelay, kCFBooleanTrue), "set true after open");
    expect(flag(pair.write) == 1 && optionOn(pair.write) == 1, "set after open, the socket gets the option at once");
    expect(CFWriteStreamSetProperty(pair.write, _kCFStreamSocketSetNoDelay, kCFBooleanFalse), "set false after open");
    expect(flag(pair.write) == 0 && optionOn(pair.write) == 1, "quirk: turning the flag off leaves the option on");
    dispose(&pair);

    pair = makePair();
    openPair(&pair);
    expect(CFReadStreamSetProperty(pair.read, _kCFStreamSocketSetNoDelay, kCFBooleanTrue), "set on the read stream");
    expect(flag(pair.write) == 1 && optionOn(pair.write) == 1, "the read and write streams share the setting");
    dispose(&pair);

    CFWriteStreamRef memory = CFWriteStreamCreateWithAllocatedBuffers(NULL, NULL);
    expect(!CFWriteStreamSetProperty(memory, _kCFStreamSocketSetNoDelay, kCFBooleanTrue),
           "a memory stream refuses the property");
    CFRelease(memory);

    close(listener);
    printf("%s\n", failures ? "FAILED" : "ALL PASSED");
    return failures != 0;
}

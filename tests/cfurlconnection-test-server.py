#!/usr/bin/env python3
# Copyright (C) 2026 Lubos Dolezel
"""Host-side HTTP(S) server for tests/cfurlconnection-body.m and tests/cfsocketstream-tls12.c.

usage: cfurlconnection-test-server.py PORT [CERTFILE KEYFILE]
Binds 127.0.0.1 only. With a certificate and key it serves HTTPS and accepts
TLS 1.2 only, so a client that caps its offer at TLS 1.0 cannot connect.

Paths:
  /plain            "plain body", no Content-Encoding
  /gzip, /deflate   the text below compressed, sent in small pieces with pauses
  /gzip-big         about 1 MiB of a repeated byte, gzip-compressed (a tiny input
                    that expands a lot)
  /unknown-encoding the plain text with "Content-Encoding: utf-8"
  /identity         the plain text with "Content-Encoding: identity"
  /cookie           Set-Cookie without a Domain attribute
"""
import gzip
import ssl
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TEXT = b"The quick brown fox jumps over the lazy dog. " * 40
BIG = b"A" * (1 << 20)


def deflate(data):
    return zlib.compress(data)  # zlib-wrapped, as HTTP "deflate" is specified


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_body(self, body, encoding=None, pieces=0, extra=()):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        if encoding:
            self.send_header("Content-Encoding", encoding)
        for name, value in extra:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if pieces:
            size = max(1, len(body) // pieces)
            for i in range(0, len(body), size):
                self.wfile.write(body[i:i + size])
                self.wfile.flush()
                time.sleep(0.02)
        else:
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/plain":
            self.send_body(b"plain body")
        elif path == "/gzip":
            self.send_body(gzip.compress(TEXT), "gzip", pieces=5)
        elif path == "/deflate":
            self.send_body(deflate(TEXT), "deflate", pieces=5)
        elif path == "/gzip-big":
            self.send_body(gzip.compress(BIG), "gzip")
        elif path == "/unknown-encoding":
            self.send_body(TEXT, "utf-8")
        elif path == "/identity":
            self.send_body(TEXT, "identity")
        elif path == "/cookie":
            self.send_body(b"cookie", extra=[("Set-Cookie", "session=abc123; Path=/")])
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


def main():
    port = int(sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    if len(sys.argv) >= 4:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.maximum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(sys.argv[2], sys.argv[3])
        server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

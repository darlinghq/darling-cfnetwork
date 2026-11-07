#!/usr/bin/env python3
"""Host-side HTTP(S) server for the NSURLSession guest tests.

usage: urlsession-test-server.py PORT [CERTFILE KEYFILE]
Binds 127.0.0.1 only. With a certificate and key it serves HTTPS.
"""
import json
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def reply(self, status, body=b"", content_type="text/plain; charset=utf-8", headers=()):
        self.send_response(status)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_any(self):
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""

        if url.path == "/text":
            self.reply(200, b"hello from host\n")
        elif url.path == "/echo":
            echo = {
                "method": self.command,
                "body": body.decode("latin-1"),
                "headers": {k.lower(): v for k, v in self.headers.items()},
            }
            self.reply(200, json.dumps(echo).encode(), "application/json")
        elif url.path == "/redirect":
            status = int(query.get("status", "302"))
            self.reply(status, b"redirect body", headers=[("Location", query["to"])])
        elif url.path == "/loop":
            self.reply(302, headers=[("Location", "/loop")])
        elif url.path == "/slow":
            time.sleep(float(query.get("seconds", "5")))
            self.reply(200, b"slow")
        elif url.path == "/status":
            self.reply(int(query["code"]), b"status body")
        elif url.path == "/empty":
            self.send_response(204)
            self.end_headers()
        elif url.path == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for chunk in (b"one ", b"two ", b"three"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"0\r\n\r\n")
        elif url.path == "/duplicate-headers":
            self.reply(200, b"dup", headers=[("X-Dup", "a"), ("X-Dup", "b")])
        else:
            self.reply(404, b"not found")

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = handle_any


def main():
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    if len(sys.argv) == 4:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[2], sys.argv[3])
        server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# Copyright (C) 2026 Lubos Dolezel
"""usage: nsurlsession-tls-test-server.py PORT CERT KEY
HTTPS server on 127.0.0.1 that answers every GET with "ok", for tests/nsurlsession-error-codes.m."""
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()

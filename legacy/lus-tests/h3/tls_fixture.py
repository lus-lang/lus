#!/usr/bin/env python3
"""Serve deterministic local HTTPS responses for one H3 child process."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import ssl
import subprocess
import sys
import threading


HERE = Path(__file__).resolve().parent


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.errors = []

    def handle_error(self, request, client_address):
        self.errors.append(f"request from {client_address} failed")
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def do_GET(self):
        routes = {
            "/status/200": (200, b"release-ready\n", {}),
            "/status/201": (201, b"created\n", {}),
            "/status/204": (204, b"", {}),
            "/status/400": (400, b"bad request\n", {}),
            "/status/404": (404, b"missing\n", {}),
            "/status/500": (500, b"server error\n", {}),
            "/redirect": (301, b"redirect\n", {"Location": "/status/200"}),
        }
        status, body, headers = routes.get(self.path, (404, b"missing\n", {}))
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "text/plain")
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def log_message(self, format, *args):
        return


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--program", required=True)
    value.add_argument("--source", required=True)
    return value


def main() -> int:
    args = parser().parse_args()
    certificate = HERE / "fixtures" / "localhost-cert.pem"
    private_key = HERE / "fixtures" / "localhost-key.pem"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, private_key)
    server = FixtureServer(("127.0.0.1", 0), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, name="lus-h3-tls")
    thread.start()
    environment = os.environ.copy()
    environment["LUS_H3_TLS_PORT"] = str(server.server_address[1])
    environment["SSL_CERT_FILE"] = str(certificate)
    child = None
    teardown_error = None
    try:
        child = subprocess.run(
            [args.program, args.source],
            env=environment,
            capture_output=True,
            text=True,
            timeout=20,
        )
        sys.stdout.write(child.stdout)
        sys.stderr.write(child.stderr)
    finally:
        try:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            if thread.is_alive():
                teardown_error = "TLS fixture thread did not stop"
        except Exception as error:
            teardown_error = f"TLS fixture teardown failed: {error}"
    if teardown_error:
        print(teardown_error, file=sys.stderr)
        return 1
    if server.errors:
        print("TLS fixture request handling failed", file=sys.stderr)
        return 1
    if child is None or child.returncode != 0:
        return child.returncode if child is not None else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Loopback HTTPS stub used by the Wheel sandbox escape tests.

The stub is the upstream provider for the proxy tests: it terminates TLS with
a throwaway certificate that the host relay is told to trust, records request
metadata (including whether an ``Authorization`` header arrived and whether it
matched the expected synthetic value), and returns a fixed JSON body.

It never writes the header value: only presence and a boolean match, so a
failure cannot leak the synthetic credential into the test artifacts.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class State:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def write(self, record):
        record = dict(record)
        record.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        line = json.dumps(record, sort_keys=True, separators=(",", ":"))
        with self.lock:
            with open(self.path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")


STATE = None  # type: State | None
EXPECTED = ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.handle_any()

    def do_POST(self):
        self.handle_any()

    def handle_any(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b""
        authorization = self.headers.get("Authorization") or ""
        assert STATE is not None
        STATE.write(
            {
                "event": "request",
                "method": self.command,
                "path": self.path.split("?", 1)[0][:256],
                "host": (self.headers.get("Host") or "")[:256],
                "auth_present": bool(authorization),
                "auth_matches": bool(EXPECTED) and authorization == EXPECTED,
                "body_bytes": len(body),
            }
        )
        payload = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        return None


def main(argv=None):
    global STATE, EXPECTED
    parser = argparse.ArgumentParser()
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--shutdown-marker", required=True)
    args = parser.parse_args(argv)
    EXPECTED = os.environ.get("STUB_EXPECT_AUTH", "")
    STATE = State(args.state)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    port = server.socket.getsockname()[1]

    temporary = args.port_file + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(str(port) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, args.port_file)

    stopping = threading.Event()

    def stop(_signum, _frame):
        if not stopping.is_set():
            stopping.set()
            threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
        with open(args.shutdown_marker, "w", encoding="utf-8") as handle:
            handle.write("clean\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

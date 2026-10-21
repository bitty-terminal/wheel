#!/usr/bin/env python3
"""Key-free negative test for the live-test HTTP client redirect policy.

Starts two loopback HTTP servers:

* the redirector returns 302 responses to a different host and to a different
  scheme;
* the target records every request and Authorization header it receives.

The client must refuse each redirect without making a second request. This test
never reads a provider credential and never reaches an external network; it is
run by ``just test-live`` (and the offline ``just check`` aggregate) before the
live key check.
"""

from __future__ import annotations

import http.server
import io
import json
import os
import sys
import threading
from pathlib import Path
from typing import Any
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True

import live_http_client as client

FAKE_KEY = "not-a-real-key"
INITIAL_HOST = "127.0.0.1"
TARGET_HOST = "127.0.0.2"

# Keep loopback traffic out of any inherited proxy configuration.
os.environ["no_proxy"] = "127.0.0.1,127.0.0.2,localhost"
os.environ["NO_PROXY"] = os.environ["no_proxy"]
# The negative test must not depend on a real credential.
for _provider in client.PROVIDERS.values():
    os.environ.pop(_provider.api_key_env, None)

redirect_requests: list[dict[str, Any]] = []
target_requests: list[dict[str, Any]] = []


class _BinarySink:
    def __init__(self) -> None:
        self.data = b""

    def write(self, data: bytes) -> int:
        self.data += data
        return len(data)

    def flush(self) -> None:
        pass


class _FakeStdin:
    def __init__(self, data: bytes) -> None:
        self.buffer = io.BytesIO(data)


class _FakeStdout:
    def __init__(self) -> None:
        self.buffer = _BinarySink()


class _QuietHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass


class RedirectHandler(_QuietHandler):
    def do_POST(self) -> None:
        redirect_requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
            }
        )
        location = self.server.location_by_path[self.path]  # type: ignore[attr-defined]
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()


class TargetHandler(_QuietHandler):
    def _respond(self) -> None:
        target_requests.append(
            {
                "path": self.path,
                "method": self.command,
                "authorization": self.headers.get("Authorization"),
            }
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def do_GET(self) -> None:
        self._respond()

    def do_POST(self) -> None:
        self._respond()


def _start_server(
    host: str, handler: type[http.server.BaseHTTPRequestHandler]
) -> http.server.ThreadingHTTPServer:
    server = http.server.ThreadingHTTPServer((host, 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _expect_redirect_refused(path: str) -> None:
    spec = {
        "url": f"http://{INITIAL_HOST}:{redirect_server.server_port}{path}",
        "method": "POST",
        "headers": {
            "Content-Type": "application/json",
            # Caller-supplied credentials must be discarded in favor of the
            # helper's own environment credential.
            "Authorization": "Bearer caller-supplied-value",
            "x-api-key": "caller-supplied-value",
        },
        "body": "{}",
    }
    try:
        client.fetch(spec, FAKE_KEY, allowed_host=INITIAL_HOST, require_https=False)
    except client.RedirectRefused:
        return
    raise AssertionError("client followed or accepted an HTTP redirect")


target_server = _start_server(TARGET_HOST, TargetHandler)
target_port = target_server.server_port

redirect_server = _start_server(INITIAL_HOST, RedirectHandler)
redirect_server.location_by_path = {  # type: ignore[attr-defined]
    "/host-change": f"http://{TARGET_HOST}:{target_port}/target",
    "/scheme-change": f"https://{INITIAL_HOST}:{target_port}/target",
}

try:
    # 1. Redirect to a different host. If the client followed it, the target
    #    server would receive the Authorization header.
    _expect_redirect_refused("/host-change")
    assert redirect_requests and redirect_requests[0]["path"] == "/host-change"
    assert redirect_requests[0]["authorization"] == f"Bearer {FAKE_KEY}", (
        "the initial request must carry the credential so the negative test is meaningful"
    )
    assert target_requests == [], "a host-change redirect reached the target server"
    print(
        "PASS live HTTP client refuses a cross-host redirect (no forwarded Authorization)"
    )

    # 2. Redirect from the allowed HTTP test scheme to HTTPS on a different
    #    scheme. The client must refuse before attempting the hop.
    _expect_redirect_refused("/scheme-change")
    assert redirect_requests[1]["path"] == "/scheme-change"
    assert target_requests == [], "a scheme-change redirect reached the target server"
    print("PASS live HTTP client refuses a scheme-change redirect")
finally:
    redirect_server.shutdown()
    redirect_server.server_close()
    target_server.shutdown()
    target_server.server_close()

# 3. main() turns a refused redirect into a bounded, generic diagnostic that
#    contains no URL, header, body, or credential material. Exercise every
#    selectable provider so the credential environment selection is covered.
for _provider in client.PROVIDERS.values():
    fake_stdout = _FakeStdout()
    stderr = io.StringIO()
    request_spec = json.dumps(
        {
            "url": f"https://{_provider.allowed_host}/api/v1/chat/completions",
            "body": "{}",
        }
    ).encode("utf-8")
    with (
        mock.patch.object(client, "fetch", side_effect=client.RedirectRefused),
        mock.patch.dict(
            os.environ,
            {
                client.PROVIDER_SELECTOR_ENV: _provider.name,
                _provider.api_key_env: FAKE_KEY,
            },
        ),
        mock.patch.object(sys, "stdin", _FakeStdin(request_spec)),
        mock.patch.object(sys, "stdout", fake_stdout),
        mock.patch.object(sys, "stderr", stderr),
    ):
        exit_code = client.main()

    assert exit_code == 1
    message = stderr.getvalue()
    assert message == "test client refused an HTTP redirect\n"
    assert FAKE_KEY not in message
    assert _provider.allowed_host not in message and "http" not in message
    assert fake_stdout.buffer.data == b""
print("PASS live HTTP client redirect diagnostic is generic and key-free")

print("PASS live HTTP client redirect policy")

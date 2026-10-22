#!/usr/bin/env python3
"""One-shot loopback HTTP transport for the Gate 2 provider-stub test.

The Lua test serializes one request as JSON on stdin:

    {"url": "...", "method": "POST", "headers": {...}, "body": "..."}

and receives one bounded JSON object on stdout:

    {"status": 200, "body": "..."}

Security boundary:

* The synthetic credential is read only from ``WHEEL_PROVIDER_STUB_KEY`` in
  this process's inherited environment. It is never accepted through argv, a
  request file, or the request JSON, and it is never written to stdout or
  stderr. A value that appears in this process's own argv is treated as a test
  defect and the helper refuses to run.
* Any caller-supplied ``Authorization``/``X-Api-Key`` header is discarded, so
  the Lua adapter cannot forward a credential through a captured request file.
  The key is attached only as ``Authorization: Bearer <key>`` for this one
  request.
* The destination is restricted to ``http://127.0.0.1:<port>`` or
  ``http://[::1]:<port>`` with no userinfo, no query, no fragment, and the
  exact path ``/chat/completions``. Redirects are never followed: ``http.client``
  has no redirect handler, and a 3xx response is refused without a second hop.
* Plaintext HTTP is allowed here only because the destination is the loopback
  stub on an ephemeral port with no TLS terminator, the traffic never leaves
  the host, and the payload carries a synthetic credential. Production
  adapters keep HTTPS and this helper is test-only: it is not imported by, or
  shipped with, the harness.
"""

from __future__ import annotations

import http.client
import json
import os
import sys
import urllib.parse

KEY_ENV = "WHEEL_PROVIDER_STUB_KEY"
ALLOWED_HOSTS = frozenset({"127.0.0.1", "::1"})
ALLOWED_PATH = "/chat/completions"
ALLOWED_METHOD = "POST"
REQUEST_TIMEOUT_SECONDS = 30
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
DISCARDED_HEADERS = frozenset({"authorization", "x-api-key", "user-agent"})
REFUSED_HEADERS = frozenset(
    {"host", "content-length", "transfer-encoding", "connection", "expect"}
)


class InvalidRequest(Exception):
    """A request specification failed local validation."""


class TransportFailure(Exception):
    """The request failed before a bounded response was available."""


def _fail(message: str) -> int:
    """Write one bounded, key-free diagnostic to stderr."""
    sys.stderr.write(message[:512] + "\n")
    return 1


def _validate_url(url: str) -> tuple[str, int]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http":
        raise InvalidRequest(
            "test client only permits plaintext HTTP to the loopback stub"
        )
    if parsed.hostname not in ALLOWED_HOSTS:
        raise InvalidRequest("test client only permits a loopback destination")
    if parsed.username is not None or parsed.password is not None:
        raise InvalidRequest("request url must not carry userinfo")
    if parsed.path != ALLOWED_PATH:
        raise InvalidRequest("test client only permits the stub completion path")
    if parsed.query or parsed.fragment:
        raise InvalidRequest("request url must not carry a query or fragment")
    try:
        port = parsed.port
    except ValueError:
        raise InvalidRequest("request url port is invalid") from None
    if port is None or not 0 < port < 65536:
        raise InvalidRequest("request url must carry an explicit loopback port")
    return parsed.hostname, port


def _safe_headers(headers: dict, key: str) -> dict:
    safe: dict[str, str] = {}
    for name, value in headers.items():
        if not isinstance(name, str) or not isinstance(value, str):
            raise InvalidRequest("request headers must be strings")
        lowered = name.lower()
        if lowered in REFUSED_HEADERS:
            raise InvalidRequest("request carries a header the client sets itself")
        if lowered in DISCARDED_HEADERS:
            continue
        safe[name] = value
    safe["Authorization"] = f"Bearer {key}"
    return safe


def fetch(spec: dict, key: str) -> tuple[int, str]:
    url = spec.get("url")
    method = spec.get("method", ALLOWED_METHOD)
    body = spec.get("body", "")
    headers = spec.get("headers") or {}

    if not isinstance(url, str) or not isinstance(body, str):
        raise InvalidRequest("request url and body must be strings")
    if not isinstance(headers, dict) or not isinstance(method, str):
        raise InvalidRequest("request headers must be an object")
    if method != ALLOWED_METHOD:
        raise InvalidRequest("test client only permits POST")

    host, port = _validate_url(url)
    safe_headers = _safe_headers(headers, key)

    connection = http.client.HTTPConnection(host, port, timeout=REQUEST_TIMEOUT_SECONDS)
    try:
        connection.request(
            ALLOWED_METHOD,
            ALLOWED_PATH,
            body=body.encode("utf-8"),
            headers=safe_headers,
        )
        response = connection.getresponse()
        status = response.status
        payload = response.read(MAX_RESPONSE_BYTES + 1)
    except (OSError, http.client.HTTPException):
        raise TransportFailure() from None
    finally:
        connection.close()

    if 300 <= status < 400:
        raise TransportFailure("redirect refused")
    if len(payload) > MAX_RESPONSE_BYTES:
        raise TransportFailure("response exceeded the client bound")
    return status, payload.decode("utf-8", "replace")


def main() -> int:
    key = os.environ.get(KEY_ENV, "")
    if not key:
        return _fail(f"{KEY_ENV} is not set in the helper environment")
    if any(key in argument for argument in sys.argv[1:]):
        return _fail(f"{KEY_ENV} must not appear in the helper's argv")

    try:
        raw_spec = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    except OSError:
        return _fail("failed to read the request specification from stdin")
    if len(raw_spec) > MAX_REQUEST_BYTES:
        return _fail("request specification exceeds the test client bound")

    try:
        spec = json.loads(raw_spec.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return _fail("request specification is not valid JSON")
    if not isinstance(spec, dict):
        return _fail("request specification must be a JSON object")

    try:
        status, body = fetch(spec, key)
    except InvalidRequest as error:
        return _fail(str(error))
    except TransportFailure as error:
        return _fail(f"test request failed: {error}")

    output = json.dumps({"status": status, "body": body}, separators=(",", ":"))
    if len(output) > MAX_OUTPUT_BYTES:
        return _fail("response exceeds the test client output bound")
    sys.stdout.write(output)
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

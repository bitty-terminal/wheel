#!/usr/bin/env python3
"""Test-only HTTP transport for the opt-in OpenRouter live test.

The Lua test writes one request specification as JSON on stdin and reads the
provider response from stdout:

    STATUS <http-status>\n<raw-response-body>

The API key is read only from this process's inherited ``OPENROUTER_API_KEY``
environment variable. It is never accepted through argv, a file, or the
request JSON, and it is never written to stdout or stderr. Any caller-supplied
Authorization or x-api-key header is discarded so the key cannot travel through
the Lua adapter or a captured request artifact.

Redirects are rejected outright: a provider response in the 3xx range aborts
the request without a second hop, so the Authorization header is never
forwarded to another host or downgraded from HTTPS. The refusal diagnostic is
static and never includes the URL, headers, or response body.

This helper exists only for ``just test-live``. It is not a production HTTP
client and is not imported by, or shipped with, the harness.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API_KEY_ENV = "OPENROUTER_API_KEY"
ALLOWED_HOST = "openrouter.ai"
REQUEST_TIMEOUT_SECONDS = 90
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
STATUS_PREFIX = "STATUS"


class InvalidRequest(Exception):
    """A request specification failed local validation."""


class RedirectRefused(Exception):
    """The provider attempted a redirect; no second request was made."""


class TransportFailure(Exception):
    """The HTTP request failed before a usable response was available."""


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect instead of forwarding the request and its headers."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: object,
        code: int,
        msg: str,
        headers: object,
        newurl: str,
    ) -> None:
        return None


def _fail(message: str) -> int:
    """Write a bounded, key-free diagnostic to stderr."""
    sys.stderr.write(message[:512] + "\n")
    return 1


def fetch(
    spec: dict,
    api_key: str,
    allowed_host: str = ALLOWED_HOST,
    require_https: bool = True,
) -> tuple[int, bytes]:
    """Execute one request specification without following redirects.

    ``allowed_host`` and ``require_https`` are explicit so the committed
    negative test can point at loopback servers without weakening the live
    entry point. ``main`` always uses the defaults.
    """
    if not isinstance(spec, dict):
        raise InvalidRequest("request specification must be a JSON object")

    url = spec.get("url")
    body = spec.get("body", "")
    headers = spec.get("headers") or {}
    method = spec.get("method") or "POST"

    if not isinstance(url, str) or not isinstance(body, str):
        raise InvalidRequest("request url and body must be strings")
    if not isinstance(headers, dict) or not isinstance(method, str):
        raise InvalidRequest(
            "request headers must be an object and method must be a string"
        )

    parsed = urllib.parse.urlparse(url)
    scheme = "https" if require_https else "http"
    if parsed.scheme != scheme or parsed.hostname != allowed_host:
        raise InvalidRequest(
            "test client only permits the configured provider host and scheme"
        )

    # The credential belongs to this process only. Never forward a caller
    # Authorization header, even if one somehow reached the serialized request.
    safe_headers = {
        str(name): str(value)
        for name, value in headers.items()
        if str(name).lower() not in ("authorization", "x-api-key")
    }
    safe_headers["Authorization"] = f"Bearer {api_key}"

    request = urllib.request.Request(
        url,
        data=body.encode("utf-8"),
        headers=safe_headers,
        method=method,
    )

    opener = urllib.request.build_opener(_RejectRedirects)
    try:
        with opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            status = response.status
            payload = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            # Do not read or echo the redirect body. No second request is made
            # because _RejectRedirects declines every redirect.
            raise RedirectRefused() from None
        status = error.code
        try:
            payload = error.read(MAX_RESPONSE_BYTES + 1)
        except OSError:
            payload = b""
    except (urllib.error.URLError, TimeoutError, OSError):
        # Deliberately generic: exception text can contain request details.
        raise TransportFailure() from None

    if len(payload) > MAX_RESPONSE_BYTES:
        raise TransportFailure()

    return status, payload


def main() -> int:
    api_key = os.environ.get(API_KEY_ENV, "")
    if not api_key:
        return _fail(f"{API_KEY_ENV} is not set in the helper environment")

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

    try:
        status, payload = fetch(spec, api_key)
    except InvalidRequest as error:
        return _fail(str(error))
    except RedirectRefused:
        return _fail("test client refused an HTTP redirect")
    except TransportFailure:
        return _fail("test HTTP request failed before a response was available")

    stdout = sys.stdout.buffer
    stdout.write(f"{STATUS_PREFIX} {status}\n".encode("ascii"))
    stdout.write(payload)
    stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

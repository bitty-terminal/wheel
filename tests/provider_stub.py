#!/usr/bin/env python3
"""Loopback OpenAI-compatible provider stub for Gate 2 evidence.

Boundary (CTX-0029 / wheel#95):

* The server binds ``127.0.0.1:0`` only. It never listens on a non-loopback
  address and never contacts another host.
* The expected synthetic credential is read once from the process environment
  variable ``WHEEL_PROVIDER_STUB_KEY``. It is never accepted through argv, a
  file, or the request body, and it is never written to stdout, stderr, or the
  request record. The argv scan runs before argument parsing with a static
  diagnostic, so an unrecognized option containing the key cannot be echoed by
  ``argparse``.
* Exactly one route is served: ``POST /chat/completions``. Every other path,
  method, or malformed request is rejected with a static response. The stub
  never issues a redirect. ``--redirect URL`` is a test-only mode that answers
  the authorized route with a 302 so the client's redirect refusal can be
  exercised; it never follows or contacts that URL.
* The request record keeps metadata only: path, method, status, whether an
  Authorization header was present, whether it matched the expected key, and
  the declared body size. Header values, the key, and prompt bodies are never
  recorded.
* The readiness file carries the bound port, the process id, and the protocol
  marker. It is written atomically with mode ``0600`` so the test can wait for
  a fully initialized server and later signal only that recorded pid.
  ``--stopped PATH`` writes an atomic clean-shutdown marker after SIGTERM/SIGINT
  teardown completes, which proves graceful termination without SIGKILL.
* SIGTERM/SIGINT requests a clean shutdown; the test only ever signals the pid
  it recorded at launch and confirmed with the readiness file.

The stub is test-only. It is not a production HTTP server, is not imported by
the harness, and is never packaged into a release artifact.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY_ENV = "WHEEL_PROVIDER_STUB_KEY"
READY_PROTOCOL = "wheel-provider-stub/1"
ALLOWED_PATH = "/chat/completions"
ALLOWED_METHOD = "POST"
MAX_REQUEST_BYTES = 1024 * 1024
STUB_CONTENT = "stub-ok"
STUB_MODEL = "wheel-stub-model"
READY_FILE_MODE = 0o600
RECORD_FILE_MODE = 0o600
SHUTDOWN_POLL_SECONDS = 0.05
THREAD_JOIN_TIMEOUT_SECONDS = 30


class HttpRejection(Exception):
    """A request was rejected before the deterministic response was served."""

    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason


def _fail(message: str) -> int:
    """Write one bounded, key-free diagnostic to stderr and exit."""
    sys.stderr.write(message[:512] + "\n")
    return 1


def _write_ready_atomically(path: str, payload: dict) -> None:
    """Publish the readiness record atomically with restrictive permissions."""
    temporary = path + ".tmp"
    descriptor = os.open(
        temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, READY_FILE_MODE
    )
    try:
        os.fchmod(descriptor, READY_FILE_MODE)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    os.replace(temporary, path)


class RequestRecorder:
    """Append request metadata to a private file. Never records header values."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.lock = threading.Lock()
        descriptor = os.open(
            path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, RECORD_FILE_MODE
        )
        os.fchmod(descriptor, RECORD_FILE_MODE)
        self.descriptor = descriptor

    def record(self, entry: dict) -> None:
        line = json.dumps(entry, separators=(",", ":"), sort_keys=True) + "\n"
        data = line.encode("utf-8")
        with self.lock:
            os.write(self.descriptor, data)

    def close(self) -> None:
        with self.lock:
            try:
                os.close(self.descriptor)
            except OSError:
                pass


class StubServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(
        self,
        address,
        handler,
        key: str,
        recorder: RequestRecorder,
        redirect_url: str | None = None,
    ) -> None:
        super().__init__(address, handler)
        self.expected_key = key
        self.recorder = recorder
        self.redirect_url = redirect_url


class StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "WheelProviderStub/1"
    sys_version = ""

    def log_message(self, format: str, *args: object) -> None:
        """Never log request lines or headers."""

    def do_GET(self) -> None:  # BaseHTTPRequestHandler method name
        self._reject(405, "method_not_allowed")

    def do_PUT(self) -> None:  # BaseHTTPRequestHandler method name
        self._reject(405, "method_not_allowed")

    def do_DELETE(self) -> None:  # BaseHTTPRequestHandler method name
        self._reject(405, "method_not_allowed")

    def do_PATCH(self) -> None:  # BaseHTTPRequestHandler method name
        self._reject(405, "method_not_allowed")

    def do_HEAD(self) -> None:  # BaseHTTPRequestHandler method name
        self._reject(405, "method_not_allowed")

    def do_POST(self) -> None:  # BaseHTTPRequestHandler method name
        if self.path != ALLOWED_PATH:
            self._reject(404, "not_found")
            return
        try:
            self._read_body()
            self._authorize()
        except HttpRejection as error:
            self._reject(error.status, error.reason)
            return

        if self.server.redirect_url:
            self._respond(302, b"", location=self.server.redirect_url)
            return

        payload = {
            "id": "chatcmpl-wheel-stub-0001",
            "object": "chat.completion",
            "created": 0,
            "model": STUB_MODEL,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": STUB_CONTENT,
                        "reasoning_content": json.dumps(
                            {
                                "schema": "wheel-rationale/1",
                                "decision": "Use the deterministic stub response",
                                "evidence": ["loopback request accepted"],
                                "uncertainty": "none",
                                "risk": "stub-only response",
                                "rejected_alternatives": ["external provider"],
                                "next_action": "return the bounded result",
                            },
                            separators=(",", ":"),
                        ),
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        self._respond(200, json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    def _read_body(self) -> bytes:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise HttpRejection(411, "missing_content_length")
        try:
            length = int(raw_length)
        except ValueError:
            raise HttpRejection(400, "invalid_content_length") from None
        if length < 0:
            raise HttpRejection(400, "invalid_content_length")
        if length > MAX_REQUEST_BYTES:
            raise HttpRejection(413, "request_too_large")
        return self.rfile.read(length)

    def _authorize(self) -> None:
        header = self.headers.get("Authorization", "")
        expected = f"Bearer {self.server.expected_key}"
        if not header:
            raise HttpRejection(401, "missing_authorization")
        if not hmac.compare_digest(
            header.encode("utf-8", "replace"), expected.encode("utf-8")
        ):
            raise HttpRejection(401, "invalid_authorization")

    def _reject(self, status: int, reason: str) -> None:
        body = json.dumps(
            {"error": {"type": "invalid_request_error", "message": reason}},
            separators=(",", ":"),
        ).encode("utf-8")
        self._respond(status, body)

    def _declared_length(self) -> int | None:
        try:
            return int(self.headers.get("Content-Length", ""))
        except (TypeError, ValueError):
            return None

    def _respond(self, status: int, body: bytes, location: str | None = None) -> None:
        authorization = self.headers.get("Authorization", "")
        authorization_present = bool(authorization)
        authorization_valid = False
        if authorization_present:
            expected = f"Bearer {self.server.expected_key}"
            authorization_valid = hmac.compare_digest(
                authorization.encode("utf-8", "replace"), expected.encode("utf-8")
            )
        self.server.recorder.record(
            {
                "path": self.path,
                "method": self.command,
                "status": status,
                "authorization_present": authorization_present,
                "authorization_valid": authorization_valid,
                "request_bytes": self._declared_length(),
            }
        )

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if location is not None:
            self.send_header("Location", location)
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def _wait_for_stop(stop_event: threading.Event) -> None:
    """Bound the wait so a signal always reaches the handler promptly."""
    while not stop_event.wait(SHUTDOWN_POLL_SECONDS):
        pass


def main(argv: list[str] | None = None) -> int:
    # Credential checks run before argument parsing: argparse echoes an
    # unrecognized argument in its error text, so an argv value carrying the
    # key must be refused first, with a static diagnostic.
    key = os.environ.get(KEY_ENV, "")
    if not key:
        return _fail(f"{KEY_ENV} is not set in the stub environment")
    scanned_argv = sys.argv[1:] if argv is None else argv
    if any(key in argument for argument in scanned_argv):
        return _fail(f"{KEY_ENV} must not appear in the stub's argv")

    parser = argparse.ArgumentParser(
        description="Loopback OpenAI-compatible provider stub (test only)."
    )
    parser.add_argument("--ready", required=True, help="atomic readiness file")
    parser.add_argument("--requests", required=True, help="request metadata record")
    parser.add_argument(
        "--redirect",
        default=None,
        help="answer the authorized route with a 302 to this URL (test only)",
    )
    parser.add_argument(
        "--stopped",
        default=None,
        help="atomic clean-shutdown marker written after SIGTERM/SIGINT teardown",
    )
    options = parser.parse_args(argv)

    ready_path = os.path.abspath(options.ready)
    requests_path = os.path.abspath(options.requests)
    stopped_path = os.path.abspath(options.stopped) if options.stopped else None

    recorder = RequestRecorder(requests_path)
    server = StubServer(
        ("127.0.0.1", 0),
        StubHandler,
        key,
        recorder,
        redirect_url=options.redirect,
    )
    stop_event = threading.Event()

    def _request_stop(_signum: int, _frame: object) -> None:
        stop_event.set()

    signal.signal(signal.SIGTERM, _request_stop)
    signal.signal(signal.SIGINT, _request_stop)

    address = server.server_address
    _write_ready_atomically(
        ready_path,
        {
            "protocol": READY_PROTOCOL,
            "host": "127.0.0.1",
            "port": int(address[1]),
            "pid": os.getpid(),
            "key_env": KEY_ENV,
            "path": ALLOWED_PATH,
        },
    )

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        _wait_for_stop(stop_event)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=THREAD_JOIN_TIMEOUT_SECONDS)
        recorder.close()
    if stopped_path:
        _write_ready_atomically(
            stopped_path, {"protocol": READY_PROTOCOL, "status": "stopped"}
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

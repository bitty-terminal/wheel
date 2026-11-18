#!/usr/bin/env python3
"""Wheel sandbox egress relay: host-side CONNECT proxy over a Unix socket.

The sandboxed harness has no route to the network: the Linux backend runs the
session in a private network namespace whose only interface is loopback. This
relay is the single egress path and runs on the host, outside that namespace.

Contract:

- Listen on a Unix socket inside the sandbox session directory (mode 0600).
- Accept ``CONNECT host:port`` only. Every destination is denied unless it
  matches the default-deny allowlist from ``WHEEL_SANDBOX_ALLOW``. A bare
  domain entry covers port 443; any other port needs an explicit
  ``host:port`` entry.
- For an allowed destination, terminate the client TLS leg with a per-session
  certificate and re-originate one HTTP/1.1 request upstream over verified
  TLS. Because the relay terminates TLS it can replace the credential header
  with the upstream credential read from ``WHEEL_SANDBOX_UPSTREAM_AUTH`` or
  ``OPENCODE_GO_API_KEY``. The sandbox never receives that value.
- ``--tunnel-only`` relays opaque bytes instead: destination allowlisting is
  preserved, credential injection is impossible and is not claimed.
- Log one JSON record per request (destination, method, path, status, sizes,
  decision) to the session directory. Header values and bodies are never
  logged.
- Bound every read and every connection; a bound breach is a refusal.

This process is not a privilege boundary against another process running as
the same OS user: the socket is reachable by that user, and that user can read
the harness environment. It removes the credential and the route from the
*sandbox*, which is a narrower principal.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time

PROG = "wheel-sandbox-proxy"

EXIT_USAGE = 2
EXIT_UNAVAILABLE = 3

DEFAULT_MAX_HEADER_BYTES = 32 * 1024
DEFAULT_MAX_REQUEST_BYTES = 8 * 1024 * 1024
DEFAULT_MAX_RESPONSE_BYTES = 8 * 1024 * 1024
DEFAULT_CONNECT_TIMEOUT = 10.0
DEFAULT_IO_TIMEOUT = 180.0
DEFAULT_MAX_CONNECTIONS = 16

HOP_BY_HOP_HEADERS = frozenset(
    {
        b"connection",
        b"keep-alive",
        b"proxy-authenticate",
        b"proxy-authorization",
        b"proxy-connection",
        b"te",
        b"trailer",
        b"upgrade",
    }
)

# Headers the relay itself owns; an injected header may not name one of them.
RESERVED_HEADERS = frozenset(
    {b"host", b"content-length", b"connection", b"transfer-encoding", b"proxy-authorization"}
)

TOKEN_RE = re.compile(rb"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9.\-_]*[a-z0-9])?$")
HEADER_NAME_RE = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


def fail(message: str, code: int = EXIT_USAGE):
    """Exit with a static diagnostic that names no host, path, or credential."""
    sys.stderr.write("%s: %s\n" % (PROG, message))
    raise SystemExit(code)


class AllowEntry:
    """One allowlist entry: a bare domain (port 443) or an explicit host:port."""

    __slots__ = ("host", "port", "exact_port")

    def __init__(self, host, port, exact_port):
        self.host = host
        self.port = port
        self.exact_port = exact_port

    def matches(self, host, port):
        if self.exact_port:
            return host == self.host and port == self.port
        if port != 443:
            return False
        return host == self.host or host.endswith("." + self.host)


def parse_allowlist(raw):
    entries = []
    for item in raw.split(","):
        entry = item.strip().lower()
        if not entry:
            continue
        if "*" in entry:
            fail("allowlist entries must not contain wildcards")
        if "/" in entry or "@" in entry or " " in entry:
            fail("allowlist entries must be host[:port] without scheme or path")
        port = 443
        exact_port = False
        host = entry
        if entry.startswith("["):
            if not entry.endswith("]") and entry.count(":") > 1:
                host, _, raw_port = entry.rpartition(":")
                if not raw_port.isdigit():
                    fail("allowlist entry has a non-numeric port")
                port = int(raw_port)
                exact_port = True
            host = host.strip("[]")
        elif entry.count(":") == 1:
            host, _, raw_port = entry.partition(":")
            if not raw_port.isdigit():
                fail("allowlist entry has a non-numeric port")
            port = int(raw_port)
            exact_port = True
        elif entry.count(":") > 1:
            fail("allowlist entry is not host[:port]")
        host = host.strip("[]").lower()
        if not host:
            fail("allowlist entry is empty")
        if port < 1 or port > 65535:
            fail("allowlist entry has an out-of-range port")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            if not HOST_RE.match(host):
                fail("allowlist entry is not a valid host name")
            if "." not in host and host != "localhost":
                fail("allowlist entries must be a full domain name")
        entries.append(AllowEntry(host, port, exact_port))
    if not entries:
        fail("allowlist is empty; proxy mode is deny-all without one")
    return entries


def allowlist_match(entries, host, port):
    return any(entry.matches(host, port) for entry in entries)


def is_exact_entry(entries, host, port):
    return any(
        entry.exact_port and entry.host == host and entry.port == port
        for entry in entries
    )


def read_upstream_credential():
    """Return [(name, value)] for one injected header, or an empty list."""
    raw = os.environ.get("WHEEL_SANDBOX_UPSTREAM_AUTH", "")
    if raw:
        name, sep, value = raw.partition(":")
        if not sep:
            fail(
                "WHEEL_SANDBOX_UPSTREAM_AUTH must be a header line of the form 'Name: value'"
            )
        name = name.strip()
        value = value.strip()
        if not HEADER_NAME_RE.match(name) or CONTROL_RE.search(value):
            fail("WHEEL_SANDBOX_UPSTREAM_AUTH is not a valid header line")
        if name.lower().encode("ascii") in RESERVED_HEADERS:
            fail("WHEEL_SANDBOX_UPSTREAM_AUTH must not name a request-framing header")
        return [(name.encode("ascii"), value.encode("latin-1"))]
    key = os.environ.get("OPENCODE_GO_API_KEY", "")
    if key:
        if CONTROL_RE.search(key):
            fail(
                "OPENCODE_GO_API_KEY contains control characters; refusing to inject it"
            )
        return [(b"Authorization", ("Bearer " + key).encode("latin-1"))]
    return []


class Relay:
    def __init__(self, args, entries):
        self.args = args
        self.entries = entries
        self.log_lock = threading.Lock()
        self.conn_slots = threading.BoundedSemaphore(max(1, args.max_connections))
        self.expected_host = threading.local()
        self.upstream_context = ssl.create_default_context(
            cafile=args.upstream_ca or None
        )
        self.auth_headers = read_upstream_credential()
        self.client_context = None
        self.tls_ca_path = None

    # -- logging ---------------------------------------------------------
    def log(self, record):
        payload = dict(record)
        payload.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        payload.setdefault("session", self.args.session)
        payload.setdefault("component", "relay")
        line = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        with self.log_lock:
            try:
                with open(self.args.log, "a", encoding="utf-8") as handle:
                    handle.write(line + "\n")
            except OSError:
                # A relay that cannot record a decision still refuses or
                # forwards per policy; the missing record is reported at exit.
                sys.stderr.write("%s: request log is unavailable\n" % PROG)

    # -- TLS material ----------------------------------------------------
    def prepare_tls(self):
        if self.args.tunnel_only:
            self.log({"event": "startup", "mode": "tunnel-only", "injected": False})
            return
        cert, key, ca_cert = select_certificates(self.args, self.entries)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        context.set_alpn_protocols(["http/1.1"])
        context.sni_callback = self.sni_callback
        self.client_context = context
        self.tls_ca_path = ca_cert
        self.log(
            {
                "event": "startup",
                "mode": "terminate",
                "injected": bool(self.auth_headers),
            }
        )

    def sni_callback(self, _sock, server_name, _context):
        expected = getattr(self.expected_host, "value", None)
        if expected is None:
            return None
        if server_name is None:
            # curl sends no SNI when the destination is an IP literal.
            try:
                ipaddress.ip_address(expected)
            except ValueError:
                raise ssl.SSLError("missing SNI for a DNS destination")
            return None
        if server_name.lower() != expected:
            raise ssl.SSLError("SNI does not match the CONNECT destination")
        return None

    # -- serving ---------------------------------------------------------
    def serve(self):
        path = self.args.socket
        parent = os.path.dirname(path) or "."
        os.makedirs(parent, mode=0o700, exist_ok=True)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(64)
        server.settimeout(1.0)
        write_ready(self.args.ready_file, self.tls_ca_path)
        while True:
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if not self.conn_slots.acquire(blocking=False):
                close_quietly(conn)
                self.log({"event": "refuse", "reason": "connection-budget"})
                continue
            threading.Thread(
                target=self.handle_guarded, args=(conn,), daemon=True
            ).start()

    def handle_guarded(self, conn):
        try:
            self.handle(conn)
        except (OSError, ssl.SSLError, ValueError):
            self.log({"event": "refuse", "reason": "connection-error"})
        finally:
            close_quietly(conn)
            self.conn_slots.release()

    def handle(self, conn):
        conn.settimeout(self.args.io_timeout)
        deadline = time.monotonic() + self.args.io_timeout
        reader = Reader(conn)
        head = reader.read_head(self.args.max_header_bytes, deadline)
        if head is None:
            self.log({"event": "refuse", "reason": "request-head-budget"})
            send_status(conn, 400, "Bad Request")
            return
        parsed = parse_head(head)
        if parsed is None:
            self.log({"event": "refuse", "reason": "malformed-head"})
            send_status(conn, 400, "Bad Request")
            return
        method, target, _version, _headers = parsed
        if method != b"CONNECT":
            self.log({"event": "refuse", "reason": "method-not-connect"})
            send_status(conn, 405, "Method Not Allowed")
            return
        destination = parse_authority(target)
        if destination is None:
            self.log({"event": "refuse", "reason": "invalid-authority"})
            send_status(conn, 400, "Bad Request")
            return
        host, port = destination
        if not allowlist_match(self.entries, host, port):
            self.log(
                {
                    "event": "deny",
                    "reason": "not-allowlisted",
                    "host": host,
                    "port": port,
                }
            )
            send_status(conn, 403, "Forbidden")
            return
        if port != 443 and not is_exact_entry(self.entries, host, port):
            self.log(
                {
                    "event": "deny",
                    "reason": "port-not-allowlisted",
                    "host": host,
                    "port": port,
                }
            )
            send_status(conn, 403, "Forbidden")
            return
        conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        if self.client_context is None:
            self.tunnel(conn, host, port, reader.buffer)
            return
        self.terminate(conn, host, port)

    # -- transparent tunnel (destination allowlist only) -----------------
    def tunnel(self, conn, host, port, buffered=b""):
        upstream = connect_upstream(
            host, port, self.args.connect_timeout, self.args.io_timeout, None
        )
        if upstream is None:
            self.log(
                {
                    "event": "refuse",
                    "reason": "upstream-unreachable",
                    "host": host,
                    "port": port,
                }
            )
            return
        try:
            if buffered:
                upstream.sendall(buffered)
            pump(conn, upstream, self.args.max_response_bytes, self.args.io_timeout)
            self.log({"event": "tunnel", "host": host, "port": port, "injected": False})
        finally:
            close_quietly(upstream)

    # -- TLS-terminating, credential-injecting HTTP forward --------------
    def terminate(self, conn, host, port):
        self.expected_host.value = host
        try:
            tls_client = self.client_context.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            self.log(
                {
                    "event": "refuse",
                    "reason": "client-tls-failed",
                    "host": host,
                    "port": port,
                }
            )
            return
        finally:
            self.expected_host.value = None
        try:
            self.forward(tls_client, host, port)
        finally:
            close_quietly(tls_client)

    def forward(self, client, host, port):
        deadline = time.monotonic() + self.args.io_timeout
        reader = Reader(client)
        head = reader.read_head(self.args.max_header_bytes, deadline)
        if head is None:
            self.log(
                {
                    "event": "refuse",
                    "reason": "request-head-budget",
                    "host": host,
                    "port": port,
                }
            )
            send_status(client, 431, "Request Header Fields Too Large")
            return
        parsed = parse_head(head)
        if parsed is None:
            self.log(
                {
                    "event": "refuse",
                    "reason": "malformed-head",
                    "host": host,
                    "port": port,
                }
            )
            send_status(client, 400, "Bad Request")
            return
        method, target, _version, headers = parsed
        if not target.startswith(b"/"):
            self.log(
                {
                    "event": "refuse",
                    "reason": "non-origin-form",
                    "host": host,
                    "port": port,
                }
            )
            send_status(client, 400, "Bad Request")
            return
        if header_value(headers, b"transfer-encoding") is not None:
            self.log(
                {
                    "event": "refuse",
                    "reason": "transfer-encoding-unsupported",
                    "host": host,
                    "port": port,
                }
            )
            send_status(client, 501, "Not Implemented")
            return
        body = b""
        length_header = header_value(headers, b"content-length")
        if length_header is not None:
            try:
                length = int(length_header)
            except ValueError:
                self.log(
                    {
                        "event": "refuse",
                        "reason": "invalid-content-length",
                        "host": host,
                        "port": port,
                    }
                )
                send_status(client, 400, "Bad Request")
                return
            if length < 0 or length > self.args.max_request_bytes:
                self.log(
                    {
                        "event": "refuse",
                        "reason": "request-body-budget",
                        "host": host,
                        "port": port,
                    }
                )
                send_status(client, 413, "Payload Too Large")
                return
            body = reader.read_exact(length, deadline)
            if body is None:
                self.log(
                    {
                        "event": "refuse",
                        "reason": "request-body-truncated",
                        "host": host,
                        "port": port,
                    }
                )
                return
        upstream_head = build_upstream_head(
            method, target, host, port, headers, self.auth_headers, body
        )
        upstream = connect_upstream(
            host,
            port,
            self.args.connect_timeout,
            self.args.io_timeout,
            self.upstream_context,
        )
        if upstream is None:
            self.log(
                {
                    "event": "refuse",
                    "reason": "upstream-unreachable",
                    "host": host,
                    "port": port,
                }
            )
            send_status(client, 502, "Bad Gateway")
            return
        try:
            upstream.sendall(upstream_head + body)
            response = read_response(
                upstream,
                self.args.max_header_bytes,
                self.args.max_response_bytes,
                deadline,
            )
            if response is None:
                self.log(
                    {
                        "event": "refuse",
                        "reason": "response-budget",
                        "host": host,
                        "port": port,
                    }
                )
                send_status(client, 502, "Bad Gateway")
                return
            response_head, response_body, status_code = response
            client.sendall(response_head + response_body)
            self.log(
                {
                    "event": "forward",
                    "host": host,
                    "port": port,
                    "method": method.decode("ascii", "replace"),
                    "path": sanitize_path(target),
                    "status": status_code,
                    "request_bytes": len(body),
                    "response_bytes": len(response_body),
                    "injected": bool(self.auth_headers),
                }
            )
        finally:
            close_quietly(upstream)


def select_certificates(args, entries):
    if args.tls_cert and args.tls_key and args.tls_ca:
        return args.tls_cert, args.tls_key, args.tls_ca
    return generate_session_certs(args.tls_dir, entries)


def generate_session_certs(tls_dir, entries):
    if not tls_dir:
        fail(
            "proxy mode needs --tls-dir to mint session certificates", EXIT_UNAVAILABLE
        )
    cert = os.path.join(tls_dir, "leaf.pem")
    key = os.path.join(tls_dir, "leaf.key")
    ca_cert = os.path.join(tls_dir, "ca.pem")
    ca_key = os.path.join(tls_dir, "ca.key")
    if os.path.exists(cert) and os.path.exists(key) and os.path.exists(ca_cert):
        return cert, key, ca_cert
    openssl = shutil.which("openssl")
    if not openssl:
        fail(
            "proxy mode needs openssl to mint session certificates, or "
            "WHEEL_SANDBOX_TLS_CA/WHEEL_SANDBOX_TLS_CERT/WHEEL_SANDBOX_TLS_KEY to supply them",
            EXIT_UNAVAILABLE,
        )
    os.makedirs(tls_dir, mode=0o700, exist_ok=True)
    dns_names = []
    ip_names = []
    for entry in entries:
        try:
            ipaddress.ip_address(entry.host)
            ip_names.append(entry.host)
        except ValueError:
            dns_names.append(entry.host)
    sans = ["DNS:" + name for name in dict.fromkeys(dns_names)]
    sans.extend("IP:" + name for name in dict.fromkeys(ip_names))
    extension = (
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature\n"
        "extendedKeyUsage=serverAuth\n"
        "subjectKeyIdentifier=hash\n"
        "authorityKeyIdentifier=keyid:always\n"
        "subjectAltName=" + ",".join(sans) + "\n"
    )
    conf_path = os.path.join(tls_dir, "leaf.ext")
    csr_path = os.path.join(tls_dir, "leaf.csr")
    with open(conf_path, "w", encoding="utf-8") as handle:
        handle.write(extension)
    run_openssl(
        openssl,
        [
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
            "-nodes",
            "-keyout",
            ca_key,
            "-out",
            ca_cert,
            "-days",
            "2",
            "-subj",
            "/CN=Wheel Sandbox Relay CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
            "-addext",
            "subjectKeyIdentifier=hash",
        ],
    )
    run_openssl(
        openssl,
        [
            "req",
            "-new",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
            "-nodes",
            "-keyout",
            key,
            "-out",
            csr_path,
            "-subj",
            "/CN=Wheel Sandbox Relay",
        ],
    )
    run_openssl(
        openssl,
        [
            "x509",
            "-req",
            "-in",
            csr_path,
            "-CA",
            ca_cert,
            "-CAkey",
            ca_key,
            "-CAcreateserial",
            "-out",
            cert,
            "-days",
            "2",
            "-extfile",
            conf_path,
        ],
    )
    os.chmod(ca_key, 0o600)
    os.chmod(key, 0o600)
    os.unlink(csr_path)
    return cert, key, ca_cert


def run_openssl(openssl, argv):
    result = subprocess.run(
        [openssl] + argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail("session certificate generation failed", EXIT_UNAVAILABLE)


def write_ready(path, ca_path):
    if not path:
        return
    payload = json.dumps({"pid": os.getpid(), "ca": ca_path or ""}, sort_keys=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(payload + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def connect_upstream(host, port, connect_timeout, io_timeout, context):
    try:
        raw = socket.create_connection((host, port), timeout=connect_timeout)
    except OSError:
        return None
    if context is None:
        raw.settimeout(io_timeout)
        return raw
    try:
        raw.settimeout(connect_timeout)
        tls = context.wrap_socket(raw, server_hostname=host)
    except (ssl.SSLError, OSError):
        close_quietly(raw)
        return None
    tls.settimeout(io_timeout)
    return tls


def parse_head(head):
    lines = head.split(b"\r\n")
    if len(lines) < 2:
        return None
    parts = lines[0].split(b" ")
    if len(parts) != 3:
        return None
    method, target, version = parts
    if not TOKEN_RE.match(method) or not version.startswith(b"HTTP/1."):
        return None
    headers = []
    for line in lines[1:]:
        if not line:
            continue
        name, sep, value = line.partition(b":")
        if not sep or not TOKEN_RE.match(name):
            return None
        headers.append((name.lower(), value.strip()))
    return method, target, version, headers


def header_value(headers, name):
    for header_name, value in headers:
        if header_name == name:
            return value
    return None


def parse_authority(target):
    try:
        text = target.decode("ascii")
    except UnicodeDecodeError:
        return None
    if CONTROL_RE.search(text) or "@" in text or " " in text:
        return None
    host = text
    port = 443
    if text.startswith("["):
        end = text.find("]")
        if end < 0:
            return None
        host = text[1:end]
        rest = text[end + 1 :]
        if rest:
            if not rest.startswith(":") or not rest[1:].isdigit():
                return None
            port = int(rest[1:])
    elif text.count(":") == 1:
        host, _, port_text = text.partition(":")
        if not port_text.isdigit():
            return None
        port = int(port_text)
    elif text.count(":") > 1:
        return None
    host = host.lower()
    if not host or port < 1 or port > 65535:
        return None
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not HOST_RE.match(host):
            return None
    return host, port


def build_upstream_head(method, target, host, port, headers, auth_headers, body):
    lines = [method + b" " + target + b" HTTP/1.1"]
    injected_names = {name.lower() for name, _value in auth_headers}
    replaced = set()
    seen_host = False
    for name, value in headers:
        if name in HOP_BY_HOP_HEADERS or name == b"content-length":
            continue
        if name == b"host":
            lines.append(b"Host: " + format_authority(host, port))
            seen_host = True
            replaced.add(b"host")
            continue
        if name in injected_names:
            if name in replaced:
                continue
            lines.append(name + b": " + next(v for n, v in auth_headers if n.lower() == name))
            replaced.add(name)
            continue
        lines.append(name + b": " + value)
    if not seen_host:
        lines.append(b"Host: " + format_authority(host, port))
    for name, value in auth_headers:
        if name.lower() not in replaced:
            lines.append(name + b": " + value)
    lines.append(b"Content-Length: " + str(len(body)).encode("ascii"))
    lines.append(b"Connection: close")
    return b"\r\n".join(lines) + b"\r\n\r\n"


def format_authority(host, port):
    text = host
    try:
        if ipaddress.ip_address(host).version == 6:
            text = "[" + host + "]"
    except ValueError:
        pass
    if port != 443:
        text = text + ":" + str(port)
    return text.encode("ascii")


class Reader:
    """Buffered reader that never drops bytes beyond a head terminator.

    ``recv`` returns whatever has arrived, so a header read can consume the
    first bytes of a request or response body. Keeping the remainder in the
    buffer is what makes a POST body survive the header parse.
    """

    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""

    def read_head(self, limit, deadline):
        while True:
            marker = self.buffer.find(b"\r\n\r\n")
            if marker >= 0:
                end = marker + 4
                if end > limit:
                    return None
                head, self.buffer = self.buffer[:end], self.buffer[end:]
                return head
            if len(self.buffer) > limit:
                return None
            if deadline is not None and time.monotonic() > deadline:
                return None
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                return None
            if not chunk:
                return None
            self.buffer += chunk

    def read_exact(self, length, deadline):
        while len(self.buffer) < length:
            if deadline is not None and time.monotonic() > deadline:
                return None
            try:
                chunk = self.sock.recv(min(max(length - len(self.buffer), 4096), 65536))
            except socket.timeout:
                return None
            if not chunk:
                return None
            self.buffer += chunk
        data, self.buffer = self.buffer[:length], self.buffer[length:]
        return data

    def read_to_eof(self, limit, deadline):
        while True:
            if deadline is not None and time.monotonic() > deadline:
                return None
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                break
            self.buffer += chunk
            if len(self.buffer) > limit:
                return None
        data, self.buffer = self.buffer, b""
        return data


def read_response(conn, head_limit, body_limit, deadline):
    reader = Reader(conn)
    head = reader.read_head(head_limit, deadline)
    if head is None:
        return None
    lines = head.split(b"\r\n")
    status_parts = lines[0].split(b" ", 2)
    if len(status_parts) < 2 or not status_parts[1].isdigit():
        return None
    status_code = int(status_parts[1])
    kept = [lines[0]]
    for line in lines[1:]:
        if not line:
            continue
        name, sep, _value = line.partition(b":")
        if not sep or name.lower() in HOP_BY_HOP_HEADERS:
            continue
        kept.append(line)
    kept.append(b"Connection: close")
    head_out = b"\r\n".join(kept) + b"\r\n\r\n"
    body = reader.read_to_eof(body_limit, deadline)
    if body is None:
        return None
    return head_out, body, status_code


def sanitize_path(target):
    text = target.split(b"?", 1)[0].decode("latin-1", "replace")
    if CONTROL_RE.search(text):
        text = "<control>"
    return text[:256]


def send_status(conn, code, reason):
    try:
        conn.sendall(
            (
                "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                % (code, reason)
            ).encode("ascii")
        )
    except OSError:
        pass


def pump(client, upstream, limit, timeout):
    import select

    total = 0
    client.setblocking(False)
    upstream.setblocking(False)
    try:
        while True:
            readable, _writable, exceptional = select.select(
                [client, upstream], [], [client, upstream], timeout
            )
            if exceptional:
                return
            if not readable:
                return
            for source in readable:
                sink = upstream if source is client else client
                try:
                    data = source.recv(65536)
                except BlockingIOError:
                    continue
                if not data:
                    try:
                        sink.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    return
                total += len(data)
                if total > limit:
                    return
                sink.sendall(data)
    finally:
        client.setblocking(True)
        upstream.setblocking(True)


def close_quietly(sock):
    if sock is None:
        return
    try:
        sock.close()
    except OSError:
        pass


def build_parser():
    parser = argparse.ArgumentParser(prog=PROG, add_help=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--allow", default=os.environ.get("WHEEL_SANDBOX_ALLOW", ""))
    parser.add_argument("--log", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--ready-file", default=None)
    parser.add_argument(
        "--tls-dir", default=os.environ.get("WHEEL_SANDBOX_TLS_DIR", "")
    )
    parser.add_argument(
        "--tls-cert", default=os.environ.get("WHEEL_SANDBOX_TLS_CERT", "")
    )
    parser.add_argument(
        "--tls-key", default=os.environ.get("WHEEL_SANDBOX_TLS_KEY", "")
    )
    parser.add_argument("--tls-ca", default=os.environ.get("WHEEL_SANDBOX_TLS_CA", ""))
    parser.add_argument(
        "--upstream-ca", default=os.environ.get("WHEEL_SANDBOX_UPSTREAM_CA", "")
    )
    parser.add_argument(
        "--tunnel-only",
        action="store_true",
        default=os.environ.get("WHEEL_SANDBOX_TUNNEL_ONLY", "") == "1",
    )
    parser.add_argument(
        "--max-header-bytes", type=int, default=DEFAULT_MAX_HEADER_BYTES
    )
    parser.add_argument(
        "--max-request-bytes", type=int, default=DEFAULT_MAX_REQUEST_BYTES
    )
    parser.add_argument(
        "--max-response-bytes", type=int, default=DEFAULT_MAX_RESPONSE_BYTES
    )
    parser.add_argument(
        "--connect-timeout", type=float, default=DEFAULT_CONNECT_TIMEOUT
    )
    parser.add_argument("--io-timeout", type=float, default=DEFAULT_IO_TIMEOUT)
    parser.add_argument("--max-connections", type=int, default=DEFAULT_MAX_CONNECTIONS)
    return parser


def main(argv=None):
    os.umask(0o077)
    args = build_parser().parse_args(argv)
    entries = parse_allowlist(args.allow)
    relay = Relay(args, entries)
    relay.prepare_tls()
    try:
        relay.serve()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""In-sandbox loopback bridge from 127.0.0.1 to the host relay socket.

The Linux sandbox backend runs the session in a private network namespace that
has loopback but no route out. The egress relay lives on the host, outside that
namespace, and is reachable only through a bind-mounted Unix socket. This
bridge is the in-sandbox half: it listens on an ephemeral loopback port, sets
``HTTPS_PROXY`` to it, and splices each connection to the relay socket.

It carries no credential and makes no policy decision: the relay decides every
destination and injects the upstream credential. A refused connection is a
closed connection, so the caller sees a transport failure and never a
half-open tunnel.
"""

from __future__ import annotations

import argparse
import os
import socket
import sys
import threading

PROG = "wheel-sandbox-bridge"

DEFAULT_MAX_CONNECTIONS = 32
DEFAULT_IDLE_TIMEOUT = 180.0


def pump(client, upstream, timeout):
    """Relay bytes both ways until either side closes.

    Each direction owns a thread so a destination that is not writable at that
    instant cannot make the bridge drop the pending bytes it already read.
    """

    def relay(source, sink):
        try:
            while True:
                data = source.recv(65536)
                if not data:
                    break
                sink.sendall(data)
        except OSError:
            pass
        finally:
            try:
                sink.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    reverse = threading.Thread(target=relay, args=(upstream, client), daemon=True)
    reverse.start()
    relay(client, upstream)
    reverse.join(timeout)


def serve_connection(client, relay_path, timeout):
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    upstream.settimeout(timeout)
    try:
        upstream.connect(relay_path)
        client.settimeout(timeout)
        pump(client, upstream, timeout)
    except OSError:
        pass
    finally:
        for sock in (client, upstream):
            try:
                sock.close()
            except OSError:
                pass


def serve_forever(listener, relay_path, max_connections, timeout):
    slots = threading.BoundedSemaphore(max_connections)
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return
        if not slots.acquire(blocking=False):
            client.close()
            continue

        def run(connection):
            try:
                serve_connection(connection, relay_path, timeout)
            finally:
                slots.release()

        threading.Thread(target=run, args=(client,), daemon=True).start()


def main(argv=None):
    parser = argparse.ArgumentParser(prog=PROG, add_help=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--max-connections", type=int, default=DEFAULT_MAX_CONNECTIONS)
    parser.add_argument("--idle-timeout", type=float, default=DEFAULT_IDLE_TIMEOUT)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        sys.stderr.write("%s: no command to run\n" % PROG)
        return 2

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(64)
    port = listener.getsockname()[1]

    proxy_url = "http://127.0.0.1:%d" % port
    environment = dict(os.environ)
    environment["HTTPS_PROXY"] = proxy_url
    environment["https_proxy"] = proxy_url
    for name in ("ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"):
        environment.pop(name, None)

    pid = os.fork()
    if pid == 0:
        try:
            serve_forever(
                listener, args.socket, args.max_connections, args.idle_timeout
            )
        finally:
            os._exit(0)

    try:
        os.execvpe(command[0], command, environment)
    except OSError as error:
        sys.stderr.write(
            "%s: cannot run the sandboxed command: %s\n" % (PROG, error.strerror)
        )
        return 127


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run the pinned Core `bittyd` conformance corpus against `WheelBittydAdapter`.

Implements `wheel#108` (`CTX-0036`):
  * Verifies `tests/fixtures/bittyd-corpus.pin.json` and the SHA-256 of the
    unmodified Core `corpus.json` snapshot (`bittyd-conformance-corpus/1`).
  * Drives every fake/adapter-capable vector (including the Wheel-owned `V-29`,
    `V-30`, and adapter-audit half of `V-33`) through the real Lua
    `WheelBittydAdapter` (`lua/wheel/bittyd_adapter.lua`) over a persistent
    stdio JSON-lines bridge (`tests/bittyd_adapter_bridge.lua`) backed by an
    in-memory reference fake server (`candidate-not-bittyd`).
  * Records typed skip reasons for `D-01`-gated worker rows (`V-42`, `V-50`)
    and `real`-only rows, and never marks a real-service vector passed from an
    adapter run.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
CORPUS_PATH = REPO_ROOT / "tests" / "fixtures" / "bittyd-corpus.json"
PIN_PATH = REPO_ROOT / "tests" / "fixtures" / "bittyd-corpus.pin.json"
BRIDGE_SCRIPT = REPO_ROOT / "tests" / "bittyd_adapter_bridge.lua"
TEST_GATE_SCRIPT = REPO_ROOT / "scripts" / "test-gate.sh"

CORPUS_SCHEMA = "bittyd-conformance-corpus/1"
PIN_SCHEMA = "bittyd-corpus-pin/1"
DRIVER_LABEL = "candidate-not-bittyd"

FAKE_WORKER_SESSIONS = False
FAKE_TERMINAL_SPAWN = True
FAKE_PEER_UID = 1000
FAKE_PEER_PID = 4242
FAKE_DAEMON_PID = 4242
FAKE_INPUT_BYTES = 4096

# Compiled limit table in exact contract order (`crates/bitty-daemon/src/limits.rs`).
LIMIT_SPECS: list[tuple[str, int, int, bool]] = [
    ("max_sessions", 16, 64, False),
    ("max_attaches_per_session", 8, 16, False),
    ("max_attaches_per_connection", 8, 16, False),
    ("max_retained_terminal_records", 64, 64, False),
    ("session_record_bytes", 4096, 4096, False),
    ("terminal_retention_ms", 600_000, 3_600_000, False),
    ("max_event_backlog_events", 256, 256, False),
    ("max_event_backlog_bytes", 262_144, 262_144, False),
    ("max_lease_queue_events", 256, 256, False),
    ("max_lease_queue_bytes", 65_536, 65_536, False),
    ("max_connection_pending_bytes", 1_048_576, 1_048_576, False),
    ("max_connection_outbound_bytes", 1_048_576, 1_048_576, False),
    ("attach_heartbeat_interval_ms", 5_000, 5_000, False),
    ("attach_lease_ttl_ms", 15_000, 15_000, False),
    ("observer_grant_ttl_ms", 60_000, 300_000, False),
    ("max_pending_observer_grants_per_session", 8, 8, False),
    ("host_grant_ttl_ms", 300_000, 900_000, False),
    ("max_pending_host_grants", 8, 8, False),
    ("host_grant_record_bytes", 128, 128, False),
    ("grant_id_bytes", 32, 32, False),
    ("transport_idle_ms", 30_000, 30_000, False),
    ("request_timeout_ms", 10_000, 10_000, False),
    ("negotiate_timeout_ms", 5_000, 5_000, False),
    ("pre_auth_max_bytes", 8_192, 8_192, False),
    ("spawn_bind_timeout_ms", 30_000, 30_000, False),
    ("abort_grace_ms", 5_000, 5_000, False),
    ("drain_grace_ms", 10_000, 10_000, False),
    ("orphan_reap_grace_ms", 5_000, 5_000, False),
    ("orphan_record_retention_ms", 3_600_000, 86_400_000, False),
    ("max_idempotency_keys_per_session", 512, 512, False),
    ("max_idempotency_bytes_per_session", 65_536, 65_536, False),
    ("max_create_idempotency_keys", 128, 128, False),
    ("max_create_idempotency_bytes", 32_768, 32_768, False),
    ("create_idempotency_ttl_ms", 600_000, 3_600_000, False),
    ("max_orphan_records", 64, 64, False),
    ("orphan_record_bytes", 4_096, 4_096, False),
    ("terminal_id_bytes", 128, 128, False),
    ("attach_id_bytes", 32, 32, False),
    ("refusal_audit_budget_per_sec", 20, 20, False),
    ("audit_file_bytes", 1_048_576, 2_097_152, False),
    ("audit_segments", 2, 2, False),
    ("max_spawn_argv_entries", 64, 64, False),
    ("max_spawn_env_entries", 128, 128, False),
    ("max_spawn_field_bytes", 4_096, 4_096, False),
    ("max_spawn_spec_bytes", 65_536, 65_536, False),
    ("max_content_bytes_per_session", 268_435_456, 268_435_456, False),
    ("max_frame_bytes", 262_144, 262_144, True),
    ("max_chunk_bytes", 262_144, 262_144, True),
    ("max_pending_requests", 64, 64, True),
    ("max_channel_capacity", 256, 256, True),
    ("max_request_rate_per_sec", 100, 100, True),
    ("max_request_burst", 200, 200, True),
    ("max_connections_per_endpoint", 16, 16, True),
    ("max_request_payload_bytes", 1_048_576, 1_048_576, True),
]
LIMIT_BY_NAME = {
    name: (default, sys_max, fixed) for name, default, sys_max, fixed in LIMIT_SPECS
}
CONTENT_FRAME_BYTES = LIMIT_BY_NAME["max_chunk_bytes"][0] // 4

BASELINE_SCOPES = [
    "session.inspect",
    "session.attach",
    "session.control",
    "terminal.inspect",
    "terminal.input",
    "terminal.manage",
    "process.spawn",
]
SCOPE_ORDER = [
    "session.inspect",
    "session.host",
    "session.attach",
    "session.control",
    "daemon.inspect",
    "daemon.control",
    "terminal.inspect",
    "terminal.input",
    "terminal.manage",
    "process.spawn",
]
CAPABILITY_ORDER = [
    ("terminal_sessions", True),
    ("worker_sessions", FAKE_WORKER_SESSIONS),
    ("events", True),
    ("observer_grants", True),
    ("control_transfer", True),
    ("idempotent_mutations", True),
]
DEADLINE_EXEMPT_METHODS = {"daemon.stop", "daemon.orphans.verify"}
CORRELATION_DOMAIN = b"bittyd:client_correlation:v1\0"
SPEC_DIGEST_DOMAIN = b"bittyd/spawn-spec/v1"


def is_uint(val: Any) -> bool:
    return type(val) is int and val >= 0


def is_terminal_state(state: str) -> bool:
    return state in ("exited", "failed", "terminated")


def well_formed_method(method: str) -> bool:
    segments = method.split(".")
    if len(segments) < 2:
        return False
    for seg in segments:
        if not seg:
            return False
        if not all(ch.islower() or ch.isdigit() or ch == "_" for ch in seg):
            return False
    return True


def parse_client_correlation(raw: str) -> str | None:
    encoded = raw.encode("utf-8")
    if len(encoded) > 128:
        return None
    if any(b < 0x20 or b == 0x7F for b in encoded):
        return None
    digest = hashlib.sha256(CORRELATION_DOMAIN + encoded).digest()[:16]
    return digest.hex()


def parse_grant_correlation(raw: Any) -> str | None:
    if not isinstance(raw, str) or len(raw) != 32:
        return None
    if not all(ch in "0123456789abcdef" for ch in raw):
        return None
    return raw


def correlation_accepts(bound: str | None, observed: str | None) -> bool:
    if bound is None:
        return True
    return observed == bound


def raw_json_equal(left: Any, right: Any) -> bool:
    if type(left) is not type(right):
        return False
    return left == right


def canonical_generation(params: Any) -> int | None:
    if not isinstance(params, dict):
        return None
    has_gen = "generation" in params
    has_alias = "expected_generation" in params
    if (
        has_gen
        and has_alias
        and not raw_json_equal(params["generation"], params["expected_generation"])
    ):
        return None
    chosen = params["generation"] if has_gen else params.get("expected_generation")
    if not is_uint(chosen):
        return None
    return int(chosen)


def canonical_target_attach(params: Any) -> str | None:
    if not isinstance(params, dict):
        return None
    has_canon = "target_attach_id" in params
    has_alias = "attach_id" in params
    if (
        has_canon
        and has_alias
        and not raw_json_equal(params["target_attach_id"], params["attach_id"])
    ):
        return None
    chosen = params["target_attach_id"] if has_canon else params.get("attach_id")
    return chosen if isinstance(chosen, str) else None


class SpawnSpecFailure(Exception):
    def __init__(self, counts: tuple[int, int] | None = None) -> None:
        super().__init__("spawn spec failure")
        self.counts = counts


def parse_spawn_spec(params: Any, limits: dict[str, int]) -> str:
    if not isinstance(params, dict):
        raise SpawnSpecFailure()
    argv_limit = limits["max_spawn_argv_entries"]
    env_limit = limits["max_spawn_env_entries"]
    field_limit = limits["max_spawn_field_bytes"]
    spec_limit = limits["max_spawn_spec_bytes"]

    def check_field(text: str) -> None:
        raw_len = len(text.encode("utf-8"))
        if raw_len > field_limit:
            raise SpawnSpecFailure((raw_len, field_limit))
        if "\x00" in text:
            raise SpawnSpecFailure()

    argv = params.get("argv")
    if (
        not isinstance(argv, list)
        or not argv
        or not all(isinstance(x, str) for x in argv)
    ):
        raise SpawnSpecFailure()
    if len(argv) > argv_limit:
        raise SpawnSpecFailure((len(argv), argv_limit))
    total = 0
    for item in argv:
        check_field(item)
        if not item:
            raise SpawnSpecFailure()
        total += len(item.encode("utf-8"))

    env_raw = params.get("env")
    if env_raw is None:
        env_list: list[str] = []
    elif isinstance(env_raw, list) and all(isinstance(x, str) for x in env_raw):
        env_list = env_raw
    else:
        raise SpawnSpecFailure()
    if len(env_list) > env_limit:
        raise SpawnSpecFailure((len(env_list), env_limit))
    parsed_env: list[tuple[str, str]] = []
    for entry in env_list:
        check_field(entry)
        if "=" not in entry:
            raise SpawnSpecFailure()
        name, val = entry.split("=", 1)
        if not name or "\x00" in name or "\x00" in val:
            raise SpawnSpecFailure()
        total += len(entry.encode("utf-8"))
        parsed_env.append((name, val))

    cwd = params.get("cwd")
    if not isinstance(cwd, str):
        raise SpawnSpecFailure()
    check_field(cwd)
    if not os.path.isabs(cwd):
        raise SpawnSpecFailure()
    total += len(cwd.encode("utf-8"))

    def parse_dim(key: str, default: int) -> int:
        if key not in params or params[key] is None:
            return default
        val = params[key]
        if not is_uint(val) or val < 1 or val > 1000:
            raise SpawnSpecFailure()
        return int(val)

    cols = parse_dim("cols", 80)
    rows = parse_dim("rows", 24)

    term_raw = params.get("term")
    if term_raw is None:
        term = "xterm-256color"
    elif isinstance(term_raw, str):
        term = term_raw
    else:
        raise SpawnSpecFailure()
    check_field(term)
    if not term:
        raise SpawnSpecFailure()
    total += len(term.encode("utf-8"))

    if total > spec_limit:
        raise SpawnSpecFailure((total, spec_limit))

    hasher = hashlib.sha256()
    hasher.update(SPEC_DIGEST_DOMAIN)
    for item in argv:
        b = item.encode("utf-8")
        hasher.update(len(b).to_bytes(8, "big"))
        hasher.update(b)
    hasher.update(b"\xff")
    for name, val in parsed_env:
        nb = name.encode("utf-8")
        vb = val.encode("utf-8")
        hasher.update(len(nb).to_bytes(8, "big"))
        hasher.update(nb)
        hasher.update(len(vb).to_bytes(8, "big"))
        hasher.update(vb)
    hasher.update(b"\xff")
    cb = cwd.encode("utf-8")
    hasher.update(len(cb).to_bytes(8, "big"))
    hasher.update(cb)
    hasher.update(cols.to_bytes(2, "big"))
    hasher.update(rows.to_bytes(2, "big"))
    tb = term.encode("utf-8")
    hasher.update(len(tb).to_bytes(8, "big"))
    hasher.update(tb)
    return hasher.digest()[:16].hex()


def decode_hex_bounded(
    encoded: str, limit: int
) -> tuple[bytes | None, tuple[int, int] | None]:
    if len(encoded) % 2 != 0:
        return None, None
    byte_len = len(encoded) // 2
    if byte_len > limit:
        return None, (byte_len, limit)
    if not all(ch in "0123456789abcdefABCDEF" for ch in encoded):
        return None, None
    return bytes.fromhex(encoded), None


class ReferenceFakeServer:
    """Reference fake cell (`candidate-not-bittyd`) matching Core `fake.rs`."""

    def __init__(self, vector: dict[str, Any]) -> None:
        injected = vector.get("injected") or {}
        overrides = injected.get("limits") or {}
        self.limits: dict[str, int] = {}
        for name, default, sys_max, fixed in LIMIT_SPECS:
            if name in overrides:
                val = int(overrides[name])
                if fixed and val != default:
                    raise ValueError(f"cannot override fixed limit {name}")
                if val <= 0 or val > sys_max:
                    raise ValueError(f"invalid override for {name}")
                self.limits[name] = val
            else:
                self.limits[name] = default
        for name in overrides:
            if name not in LIMIT_BY_NAME:
                raise ValueError(f"unknown injected limit {name}")

        self.clock_ms: int = int(injected.get("clock_ms") or 0)
        self.handler_delay_ms: int = int(injected.get("handler_delay_ms") or 0)
        self.handler_delay_method: str | None = injected.get("handler_delay_method")
        self.id_seq: int = 0
        self.request_seq: int = 0
        self.state: str = "running"
        self.sessions: dict[str, dict[str, Any]] = {}
        self.grants: dict[str, dict[str, Any]] = {}
        self.connections: dict[str, dict[str, Any]] = {}
        self.create_keys: dict[str, tuple[str, str]] = {}
        self.grant_keys: dict[str, tuple[str, str]] = {}
        self.deliveries: dict[str, str] = {}
        self.detached: dict[str, tuple[str, str]] = {}
        self.requests: list[dict[str, Any]] = []
        self.audit: list[str] = []

        self.instance: str = self._mint_id()
        self.operator_capability: str = self._mint_token()
        setup = vector.get("setup") or {}
        self.needs_host_grant: bool = bool(setup.get("host_grant"))
        self.host_grant: str | None = (
            self._mint_host_grant_with(self.limits["host_grant_ttl_ms"], None)
            if self.needs_host_grant
            else None
        )

    def _mint_id(self) -> str:
        self.id_seq += 1
        return f"{self.id_seq:032x}"

    def _mint_token(self) -> str:
        self.id_seq += 1
        return f"{self.id_seq:064x}"

    def _mint_host_grant_with(self, ttl_ms: int, correlation: str | None) -> str:
        gid = self._mint_id()
        bearer = self._mint_token()
        self.grants[bearer] = {
            "id": gid,
            "session": "",
            "kind": "host",
            "expires_ms": self.clock_ms + ttl_ms,
            "consumed": False,
            "revoked": False,
            "correlation": correlation,
        }
        return bearer

    def facts(self) -> dict[str, Any]:
        return {
            "instance_id": self.instance,
            "capabilities": dict(CAPABILITY_ORDER),
            "limits": dict(self.limits),
            "features": {
                "terminal_spawn": FAKE_TERMINAL_SPAWN,
                "verified_cleanup_sweep": FAKE_TERMINAL_SPAWN,
            },
            "seams": {
                "request_deadline_seam": True,
                "retention_clock_seam": True,
            },
        }

    def seeds(self, cwd_seed: str) -> dict[str, Any]:
        out: dict[str, Any] = {
            "operator_capability": self.operator_capability,
            "worker_sessions": FAKE_WORKER_SESSIONS,
            "cwd": cwd_seed,
        }
        if self.host_grant is not None:
            out["host_grant"] = self.host_grant
        return out

    def _conn(self, name: str) -> dict[str, Any]:
        if name not in self.connections:
            self.connections[name] = {
                "negotiated": False,
                "scopes": set(),
                "leases": set(),
                "host_grant": None,
                "pending": {},
                "client_id": "",
                "correlation": None,
                "events": False,
                "event_cursor": {},
                "closed": False,
            }
        return self.connections[name]

    def _has_scope(self, connection: str, scope: str) -> bool:
        conn = self.connections.get(connection)
        return bool(conn and scope in conn["scopes"])

    def _connection_scopes(self, connection: str) -> list[str]:
        return [s for s in SCOPE_ORDER if self._has_scope(connection, s)]

    def _audit_line(self, method: str, result: str) -> None:
        self.audit.append(f"v1 i={self.instance} a={method} r={result}")

    def _reply(self, method: str, value: Any) -> dict[str, Any]:
        self._audit_line(method, "ok")
        return {"ok": True, "result": value, "error": None}

    def _refuse(
        self,
        method: str,
        err_class: str,
        code: str,
        counts: tuple[int, int] | None = None,
        fields: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        self._audit_line(method, f"refused c={code}")
        err: dict[str, Any] = {
            "class": err_class,
            "code": code,
            "counts": list(counts) if counts is not None else None,
            "fields": fields or {},
        }
        return {"ok": False, "result": None, "error": err}

    def _sweep_expired(self) -> None:
        now = self.clock_ms
        expired_leases: list[tuple[str, str]] = []
        for sid, sess in self.sessions.items():
            for aid, lease in sess["leases"].items():
                if lease["expires_ms"] <= now:
                    expired_leases.append((sid, aid))
        for sid, aid in expired_leases:
            sess = self.sessions.get(sid)
            if sess and aid in sess["leases"]:
                del sess["leases"][aid]
                sess["revision"] += 1
                if sess["controller"] == aid:
                    sess["controller"] = None
                for conn in self.connections.values():
                    conn["leases"].discard(aid)
                self.deliveries.pop(aid, None)

        retired = [b for b, g in self.grants.items() if g["expires_ms"] <= now]
        expired_sessions: set[str] = set()
        for bearer in retired:
            grant = self.grants.pop(bearer, None)
            if (
                grant
                and grant["kind"] == "observer"
                and not grant["consumed"]
                and not grant["revoked"]
            ):
                sess = self.sessions.get(grant["session"])
                if sess:
                    sess["pending_grants"] = max(0, sess["pending_grants"] - 1)
                expired_sessions.add(grant["session"])
        for sid in sorted(expired_sessions):
            sess = self.sessions.get(sid)
            if sess and not is_terminal_state(sess["state"]):
                sess["revision"] += 1

    def _collect_retained(self) -> None:
        now = self.clock_ms
        retention = self.limits["terminal_retention_ms"]
        to_drop = [
            sid
            for sid, sess in self.sessions.items()
            if sess["terminalized_ms"] is not None
            and (now - sess["terminalized_ms"]) >= retention
        ]
        for sid in to_drop:
            del self.sessions[sid]

    def _active_sessions(self) -> int:
        return sum(
            1 for s in self.sessions.values() if not is_terminal_state(s["state"])
        )

    def _session_visible(
        self, connection: str, session_id: str, token: str | None
    ) -> bool:
        if self._has_scope(connection, "daemon.inspect"):
            return True
        now = self.clock_ms
        conn = self.connections.get(connection)
        sess = self.sessions.get(session_id)
        if conn and sess:
            for aid in conn["leases"]:
                lease = sess["leases"].get(aid)
                if lease and lease["expires_ms"] > now:
                    return True
        return bool(token is not None and sess is not None and sess["token"] == token)

    def _control_visible(
        self, connection: str, session_id: str, token: str | None
    ) -> tuple[str, str] | None:
        if self._session_visible(connection, session_id, token):
            return None
        sess = self.sessions.get(session_id)
        if sess and not is_terminal_state(sess["state"]) and sess["controller"] is None:
            return ("Denied", "InvalidControlToken")
        return ("NotFound", "NotFound")

    def _control_authority(
        self, connection: str, session_id: str, token: str | None
    ) -> tuple[str, str] | None:
        if self._has_scope(connection, "daemon.control"):
            return None
        sess = self.sessions.get(session_id)
        if not sess:
            return ("NotFound", "NotFound")
        now = self.clock_ms
        own_observer = False
        conn = self.connections.get(connection)
        if conn:
            for aid in conn["leases"]:
                lease = sess["leases"].get(aid)
                if lease and lease["expires_ms"] > now:
                    if lease["role"] == "controller" and sess["controller"] == aid:
                        return None
                    own_observer = True
        if own_observer:
            return ("Denied", "ControllerRequired")
        if sess["controller"] is not None:
            return ("Denied", "ControlHeld")
        if token is not None and token == sess["token"]:
            return None
        return ("Denied", "InvalidControlToken")

    def _session_json(
        self, sess: dict[str, Any], operator: bool, now: int
    ) -> dict[str, Any]:
        value: dict[str, Any] = {
            "session_id": sess["id"],
            "kind": sess["kind"],
            "terminal_id": sess["terminal_id"],
            "state": sess["state"],
            "generation": sess["generation"],
            "state_revision": sess["revision"],
            "attach_count": len(sess["leases"]),
            "attached": len(sess["leases"]) > 0,
            "controller_present": sess["controller"] is not None,
            "pending_observer_grants": sess["pending_grants"],
            "created_at_ms": sess["created_ms"],
            "last_seen_ms": sess["last_seen_ms"],
            "state_changed_at_ms": sess["state_changed_ms"],
            "created_by_kind": sess["created_by_kind"],
        }
        if sess["last_worker_seen_ms"] is not None:
            value["last_worker_seen_at_ms"] = sess["last_worker_seen_ms"]
        if sess["generation"] > 0 and sess["worker_handle"] is not None:
            value["worker_handle"] = sess["worker_handle"]
        if sess["exit_code"] is not None:
            value["exit_code"] = sess["exit_code"]
        if sess["signal"] is not None:
            value["signal"] = sess["signal"]
        if is_terminal_state(sess["state"]):
            value["terminal_reason"] = sess["terminal_reason"]
            value["cleanup"] = sess["cleanup"]
        if operator:
            value["owner_client_id"] = sess["owner_client_id"]
            if sess["requested_by"] is not None:
                req_kind, req_cid = sess["requested_by"]
                requester: dict[str, Any] = {"kind": req_kind}
                if req_cid is not None:
                    requester["client_id"] = req_cid
                value["requested_by"] = requester
            attached: list[dict[str, Any]] = []
            for aid in sorted(sess["leases"]):
                lease = sess["leases"][aid]
                if lease["expires_ms"] > now:
                    entry: dict[str, Any] = {
                        "attach_id": aid,
                        "role": lease["role"],
                        "attached_at_ms": lease["attached_ms"],
                        "last_seen_at_ms": lease["last_seen_ms"],
                        "lease_expires_at_ms": lease["expires_ms"],
                    }
                    if lease["client_id"] is not None:
                        entry["client_id"] = lease["client_id"]
                    attached.append(entry)
            value["attached_leases"] = attached
        return value

    def _limits_triples(self) -> list[dict[str, Any]]:
        return [
            {
                "name": name,
                "effective": self.limits[name],
                "default": default,
                "system_max": sys_max,
            }
            for name, default, sys_max, _ in LIMIT_SPECS
        ]

    def _route(self, connection: str) -> None:
        conn = self.connections.get(connection)
        if not conn:
            return
        for aid in sorted(conn["leases"]):
            if aid in self.deliveries:
                conn["pending"][aid] = self.deliveries.pop(aid)

    def _terminate(self, session_id: str, reason: str) -> bool:
        sess = self.sessions.get(session_id)
        if not sess or is_terminal_state(sess["state"]):
            return False
        now = self.clock_ms
        leases = sorted(sess["leases"].keys())
        for aid in leases:
            del sess["leases"][aid]
            sess["revision"] += 1
        sess["controller"] = None
        sess["pending_grants"] = 0
        sess["initial_token"] = None
        sess["state"] = "terminated"
        sess["terminalized_ms"] = now
        sess["state_changed_ms"] = now
        sess["terminal_reason"] = reason
        sess["cleanup"] = "swept" if sess["generation"] > 0 else "not_started"
        sess["content"].clear()
        sess["input_remaining"] = 0
        sess["subscription_sequence"] = 0
        sess["subscribed"] = False
        sess["last_seen_ms"] = now
        sess["revision"] += 1
        for aid in leases:
            for conn in self.connections.values():
                conn["leases"].discard(aid)
            self.deliveries.pop(aid, None)
        return True

    def call(self, connection: str, method: str, params: Any) -> dict[str, Any]:
        conn = self._conn(connection)
        if conn["closed"]:
            return {"transport": "closed"}
        self._sweep_expired()
        self._collect_retained()
        self.requests.append({"method": method, "params": copy.deepcopy(params)})

        if method == "daemon.negotiate":
            return self._negotiate(connection, params)

        if not conn["negotiated"]:
            outcome = self._refuse(method, "Denied", "AlreadyNegotiated")
            conn["closed"] = True
            return outcome

        self.request_seq += 1
        if self.handler_delay_ms > 0 and (
            self.handler_delay_method is None or self.handler_delay_method == method
        ):
            self.clock_ms += self.handler_delay_ms
            bound = self.limits["request_timeout_ms"]
            if method not in DEADLINE_EXEMPT_METHODS and self.handler_delay_ms >= bound:
                self._audit_line("request", "refused c=Timeout")
                return {
                    "ok": False,
                    "result": None,
                    "error": {
                        "class": "Timeout",
                        "code": "Timeout",
                        "counts": None,
                        "fields": {
                            "request_id": str(self.request_seq),
                            "timeout_ms": bound,
                        },
                    },
                }

        if not well_formed_method(method):
            return self._refuse(method, "Validation", "InvalidMethod")

        p = params if isinstance(params, dict) else {}
        handlers = {
            "daemon.status": lambda: self._daemon_status(connection),
            "daemon.stop": lambda: self._daemon_stop(connection, p),
            "daemon.host_grant": lambda: self._daemon_host_grant(connection, p),
            "daemon.orphans.verify": lambda: self._daemon_orphans_verify(connection, p),
            "session.create": lambda: self._session_create(connection, p),
            "session.status": lambda: self._session_status(connection, p),
            "session.list": lambda: self._session_list(connection),
            "session.attach": lambda: self._session_attach(connection, p),
            "session.grant": lambda: self._session_grant(connection, p),
            "session.grant.revoke": lambda: self._session_grant_revoke(connection, p),
            "session.detach": lambda: self._session_detach(connection, p),
            "session.control.transfer": lambda: self._session_transfer(connection, p),
            "session.resize": lambda: self._session_resize(connection, p),
            "session.read": lambda: self._session_read(connection, p),
            "session.write": lambda: self._session_write(connection, p),
            "session.subscribe": lambda: self._session_subscribe(connection, p),
            "session.abort": lambda: self._session_abort(connection, p),
            "session.kill": lambda: self._session_kill(connection, p),
            "lease.heartbeat": lambda: self._lease_heartbeat(connection, p),
        }
        handler = handlers.get(method)
        outcome = handler() if handler else self._refuse(method, "NotFound", "NotFound")
        self._route(connection)
        return outcome

    def call_dropping(
        self, connection: str, method: str, params: Any
    ) -> dict[str, Any]:
        self.call(connection, method, params)
        self._conn(connection)["closed"] = True
        return {"transport": "closed"}

    def _negotiate(self, connection: str, params: Any) -> dict[str, Any]:
        conn = self._conn(connection)
        if conn["negotiated"]:
            out = self._refuse("daemon.negotiate", "Denied", "AlreadyNegotiated")
            conn["closed"] = True
            return out
        p = params if isinstance(params, dict) else {}
        cv = (
            p.get("client_version") if isinstance(p.get("client_version"), dict) else {}
        )
        major = cv.get("major")
        minor = cv.get("minor")
        if not (is_uint(major) and major == 1 and is_uint(minor) and 0 <= minor <= 5):
            out = self._refuse("daemon.negotiate", "Validation", "VersionMismatch")
            conn["closed"] = True
            return out
        has_op_field = (
            "operator_capability" in p and p["operator_capability"] is not None
        )
        op_ok = isinstance(p.get("operator_capability"), str) and (
            p["operator_capability"] == self.operator_capability
        )
        if has_op_field and not op_ok:
            out = self._refuse("daemon.negotiate", "Unauthenticated", "Unauthenticated")
            conn["closed"] = True
            return out

        correlation: str | None = None
        if isinstance(p.get("client_correlation"), str):
            correlation = parse_client_correlation(p["client_correlation"])
            if correlation is None:
                out = self._refuse("daemon.negotiate", "Validation", "InvalidRequest")
                conn["closed"] = True
                return out

        conn["negotiated"] = True
        conn["scopes"] = set(BASELINE_SCOPES)
        conn["correlation"] = correlation
        conn["events"] = p.get("events") is True
        if op_ok:
            conn["scopes"].add("daemon.inspect")
            conn["scopes"].add("daemon.control")

        bearer = p.get("host_grant")
        if isinstance(bearer, str):
            grant = self.grants.get(bearer)
            if (
                grant
                and grant["kind"] == "host"
                and not grant["consumed"]
                and not grant["revoked"]
                and grant["expires_ms"] > self.clock_ms
                and correlation_accepts(grant["correlation"], correlation)
            ):
                grant["consumed"] = True
                conn["scopes"].add("session.host")
                conn["host_grant"] = bearer

        client_id = self._mint_id()
        conn["client_id"] = client_id
        return self._reply(
            "daemon.negotiate",
            {
                "wire_version": 1,
                "service_api_version": {"major": 1, "minor": 5, "min_client_minor": 0},
                "daemon_instance_id": self.instance,
                "daemon_pid": FAKE_DAEMON_PID,
                "server_identity": {
                    "uid": FAKE_PEER_UID,
                    "endpoint_kind": "unix_socket",
                    "endpoint_owner": FAKE_PEER_UID,
                    "endpoint_mode": 384,
                },
                "peer_identity": {
                    "uid": FAKE_PEER_UID,
                    "pid": FAKE_PEER_PID,
                    "start_time": 1,
                },
                "client_id": client_id,
                "scopes": self._connection_scopes(connection),
                "capabilities": dict(CAPABILITY_ORDER),
                "limits": self._limits_triples(),
                "server_monotonic_ms": self.clock_ms,
                "daemon_state": self.state,
            },
        )

    def _daemon_status(self, connection: str) -> dict[str, Any]:
        if not self._has_scope(connection, "daemon.inspect"):
            return self._refuse("daemon.status", "Denied", "ScopeViolation")
        active = self._active_sessions()
        return self._reply(
            "daemon.status",
            {
                "daemon_instance_id": self.instance,
                "daemon_state": self.state,
                "active_sessions": active,
                "sessions": {
                    "created": active,
                    "running": 0,
                    "stopping": 0,
                    "terminal": len(self.sessions) - active,
                },
                "audit_degraded": False,
                "daemon_pid": FAKE_DAEMON_PID,
                "uptime_ms": self.clock_ms,
                "drain_deadline_ms": None,
                "limits": self._limits_triples(),
                "orphans": {
                    "verify": "served",
                    "mechanism": "fake",
                    "records": {
                        "reserved": 0,
                        "committed": 0,
                        "unverified": 0,
                        "reaped": 0,
                        "stale": 0,
                    },
                },
            },
        )

    def _daemon_orphans_verify(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self._has_scope(connection, "daemon.control"):
            return self._refuse("daemon.orphans.verify", "Denied", "ScopeViolation")
        raw_action = params.get("action")
        if raw_action is None:
            action = "verify"
        elif isinstance(raw_action, str):
            action = raw_action
        else:
            return self._refuse("daemon.orphans.verify", "Validation", "InvalidRequest")
        if action not in ("verify", "retire"):
            return self._refuse("daemon.orphans.verify", "Validation", "InvalidRequest")
        if action == "retire":
            rid = params.get("record_id")
            if not (
                isinstance(rid, str)
                and len(rid) == 32
                and all(c in "0123456789abcdef" for c in rid)
            ):
                return self._refuse(
                    "daemon.orphans.verify", "Validation", "InvalidRequest"
                )
            return self._refuse("daemon.orphans.verify", "NotFound", "NotFound")
        return self._reply(
            "daemon.orphans.verify",
            {"reaped": 0, "unverified": 0, "stale": 0, "reserved": 0, "committed": 0},
        )

    def _daemon_stop(self, connection: str, params: dict[str, Any]) -> dict[str, Any]:
        if not self._has_scope(connection, "daemon.control"):
            return self._refuse("daemon.stop", "Denied", "ScopeViolation")
        if self.state == "stopping":
            return self._refuse("daemon.stop", "Denied", "DaemonStopping")
        mode = params.get("mode", "refuse")
        if mode is None:
            mode = "refuse"
        if mode not in ("refuse", "drain", "force"):
            return self._refuse("daemon.stop", "Validation", "InvalidRequest")
        active = self._active_sessions()
        if mode == "refuse" and active > 0:
            return self._refuse(
                "daemon.stop",
                "Denied",
                "ActiveSessions",
                (active, self.limits["max_sessions"]),
            )
        terminated = 0
        if mode != "refuse":
            live_ids = [
                sid
                for sid, s in sorted(self.sessions.items())
                if not is_terminal_state(s["state"])
            ]
            for sid in live_ids:
                self.sessions[sid]["requested_by"] = ("daemon", None)
                if self._terminate(sid, "daemon_stop"):
                    terminated += 1
            self.state = "stopping"
        return self._reply(
            "daemon.stop",
            {
                "accepted": True,
                "mode": mode,
                "active_sessions": active,
                "terminated": terminated,
                "drain_deadline_ms": None,
            },
        )

    def _optional_ttl(
        self, params: dict[str, Any], key: str, limit_ms: int
    ) -> tuple[bool, int | None, tuple[int, int] | None]:
        if key not in params:
            return True, None, None
        val = params[key]
        if not is_uint(val):
            return False, None, None
        if val == 0 or val > limit_ms:
            return False, None, (int(val), limit_ms)
        return True, int(val), None

    def _daemon_host_grant(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self._has_scope(connection, "daemon.control"):
            return self._refuse("daemon.host_grant", "Denied", "ScopeViolation")
        if "observer_correlation_digest" in params:
            return self._refuse("daemon.host_grant", "Validation", "InvalidRequest")
        action = params.get("action")
        ttl_limit = self.limits["host_grant_ttl_ms"]
        if action == "mint":
            ok, ttl_ms, counts = self._optional_ttl(params, "ttl_ms", ttl_limit)
            if not ok:
                return self._refuse(
                    "daemon.host_grant", "Validation", "InvalidRequest", counts
                )
            correlation: str | None = None
            if "client_correlation_digest" in params:
                correlation = parse_grant_correlation(
                    params["client_correlation_digest"]
                )
                if correlation is None:
                    return self._refuse(
                        "daemon.host_grant", "Validation", "InvalidRequest"
                    )
            limit = self.limits["max_pending_host_grants"]
            active = sum(
                1
                for g in self.grants.values()
                if g["kind"] == "host"
                and not g["consumed"]
                and not g["revoked"]
                and g["expires_ms"] > self.clock_ms
            )
            if active >= limit:
                return self._refuse(
                    "daemon.host_grant", "Framing", "LimitExceeded", (0, limit)
                )
            bearer = self._mint_host_grant_with(
                ttl_ms if ttl_ms is not None else ttl_limit, correlation
            )
            grant = self.grants[bearer]
            return self._reply(
                "daemon.host_grant",
                {
                    "grant_id": grant["id"],
                    "grant": bearer,
                    "expires_at_ms": grant["expires_ms"],
                },
            )
        if action == "revoke":
            if "ttl_ms" in params or "client_correlation_digest" in params:
                return self._refuse("daemon.host_grant", "Validation", "InvalidRequest")
            gid = params.get("grant_id")
            if not isinstance(gid, str):
                return self._refuse("daemon.host_grant", "Validation", "InvalidRequest")
            bearer_found = next(
                (
                    b
                    for b, g in self.grants.items()
                    if g["id"] == gid and g["kind"] == "host"
                ),
                None,
            )
            if bearer_found is not None:
                grant = self.grants[bearer_found]
                active_flag = (
                    not grant["consumed"]
                    and not grant["revoked"]
                    and grant["expires_ms"] > self.clock_ms
                )
                grant["revoked"] = True
                revoked, not_active = active_flag, not active_flag
            else:
                revoked, not_active = False, True
            return self._reply(
                "daemon.host_grant",
                {"grant_id": gid, "revoked": revoked, "not_active": not_active},
            )
        return self._refuse("daemon.host_grant", "Validation", "InvalidRequest")

    def _session_create(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        spawn = self._has_scope(connection, "process.spawn")
        host = self._has_scope(connection, "session.host")
        if not spawn:
            return self._refuse("session.create", "Denied", "ScopeViolation")
        if not host:
            return self._refuse("session.create", "Denied", "ConsentRequired")
        kind = params.get("kind", "terminal")
        if kind is None:
            kind = "terminal"
        if kind not in ("terminal", "worker"):
            return self._refuse("session.create", "Validation", "InvalidRequest")
        if kind == "worker" and not FAKE_WORKER_SESSIONS:
            return self._refuse("session.create", "Denied", "UnsupportedCapability")

        conn = self._conn(connection)
        bound_bearer = conn.get("host_grant")
        bound_ok = False
        if isinstance(bound_bearer, str):
            grant = self.grants.get(bound_bearer)
            bound_ok = bool(
                grant
                and grant["kind"] == "host"
                and grant["consumed"]
                and not grant["revoked"]
                and grant["expires_ms"] > self.clock_ms
            )
        if not bound_ok:
            return self._refuse("session.create", "Denied", "ConsentRequired")

        wants_spawn = kind == "worker" or (
            "argv" in params and params["argv"] is not None
        )
        if "argv" in params and params["argv"] is None:
            wants_spawn = True
        spec_digest: str | None = None
        if wants_spawn:
            try:
                spec_digest = parse_spawn_spec(params, self.limits)
            except SpawnSpecFailure as err:
                if err.counts is not None:
                    return self._refuse(
                        "session.create", "Framing", "LimitExceeded", err.counts
                    )
                return self._refuse("session.create", "Validation", "InvalidRequest")

        key = params.get("idempotency_key")
        if not isinstance(key, str):
            return self._refuse("session.create", "Validation", "InvalidRequest")
        tid_opt = (
            params.get("terminal_id")
            if isinstance(params.get("terminal_id"), str)
            else None
        )
        fingerprint = (
            f"{kind}:{tid_opt or ''}:{spec_digest}"
            if spec_digest is not None
            else f"{kind}:{tid_opt or ''}"
        )
        if key in self.create_keys:
            remembered, sid_prev = self.create_keys[key]
            if remembered == fingerprint and sid_prev in self.sessions:
                sess = self.sessions[sid_prev]
                return self._reply(
                    "session.create",
                    {
                        "session": self._session_json(
                            sess,
                            self._has_scope(connection, "daemon.inspect"),
                            self.clock_ms,
                        ),
                        "control_token": sess["initial_token"],
                        "replayed": True,
                    },
                )
            return self._refuse("session.create", "Denied", "IdempotencyConflict")

        if self._active_sessions() >= self.limits["max_sessions"]:
            return self._refuse(
                "session.create",
                "Framing",
                "LimitExceeded",
                (self._active_sessions(), self.limits["max_sessions"]),
            )

        sid = self._mint_id()
        terminal_id = tid_opt if tid_opt is not None else self._mint_id()
        if any(
            s["terminal_id"] == terminal_id and not is_terminal_state(s["state"])
            for s in self.sessions.values()
        ):
            return self._refuse("session.create", "Denied", "TerminalAlreadyHosted")
        token = self._mint_token()
        now = self.clock_ms
        bound = spec_digest is not None
        worker_handle = self._mint_id() if bound else None
        sess = {
            "id": sid,
            "kind": kind,
            "terminal_id": terminal_id,
            "state": "running" if bound else "created",
            "generation": 1 if bound else 0,
            "revision": 1 if bound else 0,
            "controller": None,
            "pending_grants": 0,
            "token": token,
            "initial_token": token,
            "leases": {},
            "created_ms": now,
            "last_seen_ms": now,
            "state_changed_ms": now,
            "owner_client_id": conn["client_id"],
            "created_by_kind": "operator"
            if self._has_scope(connection, "daemon.inspect")
            else "consumer",
            "requested_by": None,
            "last_worker_seen_ms": now if bound else None,
            "worker_handle": worker_handle,
            "exit_code": None,
            "signal": None,
            "terminalized_ms": None,
            "terminal_reason": None,
            "cleanup": None,
            "content": bytearray(),
            "input_remaining": FAKE_INPUT_BYTES,
            "subscription_sequence": 0,
            "subscribed": False,
        }
        self.create_keys[key] = (fingerprint, sid)
        self.sessions[sid] = sess
        return self._reply(
            "session.create",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), now
                ),
                "control_token": token,
                "replayed": False,
            },
        )

    def _session_resize(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self._has_scope(connection, "terminal.manage"):
            return self._refuse("session.resize", "Denied", "ScopeViolation")
        sid = params.get("session_id")
        gen = params.get("generation")
        cols = params.get("cols")
        rows = params.get("rows")
        if not (
            isinstance(sid, str)
            and is_uint(gen)
            and is_uint(cols)
            and 1 <= cols <= 1000
            and is_uint(rows)
            and 1 <= rows <= 1000
        ):
            return self._refuse("session.resize", "Validation", "InvalidRequest")
        if not self._session_visible(connection, sid, None) or sid not in self.sessions:
            return self._refuse("session.resize", "NotFound", "NotFound")
        sess = self.sessions[sid]
        if sess["generation"] != gen:
            return self._refuse(
                "session.resize",
                "Denied",
                "StaleGeneration",
                (sess["generation"], sess["revision"]),
            )
        if is_terminal_state(sess["state"]):
            return self._refuse("session.resize", "Denied", "NotRunning")
        if sess["state"] == "stopping":
            return self._refuse("session.resize", "Denied", "SessionStopping")
        ctrl = sess["controller"]
        conn = self._conn(connection)
        authorized = bool(
            ctrl
            and ctrl in conn["leases"]
            and ctrl in sess["leases"]
            and sess["leases"][ctrl]["role"] == "controller"
            and sess["leases"][ctrl]["expires_ms"] > self.clock_ms
        )
        if not authorized:
            return self._refuse("session.resize", "Denied", "ControllerRequired")
        if sess["state"] != "running" or sess["generation"] == 0:
            return self._refuse("session.resize", "Denied", "NotRunning")
        now = self.clock_ms
        sess["revision"] += 1
        sess["state_changed_ms"] = now
        sess["last_seen_ms"] = now
        sess["leases"][ctrl]["expires_ms"] = now + self.limits["attach_lease_ttl_ms"]
        return self._reply(
            "session.resize",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), now
                )
            },
        )

    def _content_target(
        self, connection: str, session_id: str, generation: int
    ) -> tuple[str, str, tuple[int, int] | None] | None:
        if (
            not self._session_visible(connection, session_id, None)
            or session_id not in self.sessions
        ):
            return ("NotFound", "NotFound", None)
        sess = self.sessions[session_id]
        if sess["generation"] != generation:
            return ("Denied", "StaleGeneration", (sess["generation"], sess["revision"]))
        if is_terminal_state(sess["state"]):
            return ("Denied", "NotRunning", None)
        if sess["state"] == "stopping":
            return ("Denied", "SessionStopping", None)
        if sess["kind"] != "terminal" or sess["generation"] == 0:
            return ("Denied", "NotRunning", None)
        ctrl = sess["controller"]
        conn = self._conn(connection)
        authorized = bool(
            ctrl
            and ctrl in conn["leases"]
            and ctrl in sess["leases"]
            and sess["leases"][ctrl]["role"] == "controller"
            and sess["leases"][ctrl]["expires_ms"] > self.clock_ms
        )
        if not authorized:
            return ("Denied", "ControllerRequired", None)
        return None

    def _session_read(self, connection: str, params: dict[str, Any]) -> dict[str, Any]:
        if not self._has_scope(connection, "terminal.inspect"):
            return self._refuse("session.read", "Denied", "ScopeViolation")
        sid = params.get("session_id")
        gen = params.get("generation")
        if not isinstance(sid, str) or not is_uint(gen):
            return self._refuse("session.read", "Validation", "InvalidRequest")
        max_bytes = params.get("max_bytes", CONTENT_FRAME_BYTES)
        if max_bytes is None:
            max_bytes = CONTENT_FRAME_BYTES
        if not is_uint(max_bytes) or max_bytes == 0:
            return self._refuse("session.read", "Validation", "InvalidRequest")
        if max_bytes > CONTENT_FRAME_BYTES:
            return self._refuse(
                "session.read",
                "Framing",
                "LimitExceeded",
                (int(max_bytes), CONTENT_FRAME_BYTES),
            )
        err = self._content_target(connection, sid, int(gen))
        if err is not None:
            return self._refuse("session.read", err[0], err[1], err[2])
        sess = self.sessions[sid]
        take = min(int(max_bytes), len(sess["content"]))
        data = bytes(sess["content"][:take])
        del sess["content"][:take]
        sess["input_remaining"] = min(
            FAKE_INPUT_BYTES, sess["input_remaining"] + len(data)
        )
        return self._reply(
            "session.read",
            {
                "session_id": sid,
                "generation": sess["generation"],
                "data": data.hex(),
                "bytes": len(data),
                "buffered_bytes": len(sess["content"]),
                "is_untrusted_surface": True,
            },
        )

    def _session_write(self, connection: str, params: dict[str, Any]) -> dict[str, Any]:
        if not self._has_scope(connection, "terminal.input"):
            return self._refuse("session.write", "Denied", "ScopeViolation")
        sid = params.get("session_id")
        gen = params.get("generation")
        encoded = params.get("data")
        if not isinstance(sid, str) or not is_uint(gen) or not isinstance(encoded, str):
            return self._refuse("session.write", "Validation", "InvalidRequest")
        data, counts = decode_hex_bounded(encoded, CONTENT_FRAME_BYTES)
        if counts is not None:
            return self._refuse("session.write", "Framing", "LimitExceeded", counts)
        if data is None or len(data) == 0:
            return self._refuse("session.write", "Validation", "InvalidRequest")
        err = self._content_target(connection, sid, int(gen))
        if err is not None:
            return self._refuse("session.write", err[0], err[1], err[2])
        sess = self.sessions[sid]
        window = sess["input_remaining"]
        if window == 0:
            return self._refuse("session.write", "Denied", "ChannelFull")
        attempted = len(data)
        accepted = min(attempted, window)
        sess["input_remaining"] -= accepted
        room = max(0, CONTENT_FRAME_BYTES - len(sess["content"]))
        sess["content"].extend(data[: min(accepted, room)])
        return self._reply(
            "session.write",
            {
                "session_id": sid,
                "generation": sess["generation"],
                "accepted": accepted,
                "remaining": attempted - accepted,
                "backpressure": accepted < attempted,
            },
        )

    def _session_subscribe(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self._has_scope(connection, "terminal.inspect"):
            return self._refuse("session.subscribe", "Denied", "ScopeViolation")
        sid = params.get("session_id")
        gen = params.get("generation")
        if not isinstance(sid, str) or not is_uint(gen):
            return self._refuse("session.subscribe", "Validation", "InvalidRequest")
        err = self._content_target(connection, sid, int(gen))
        if err is not None:
            return self._refuse("session.subscribe", err[0], err[1], err[2])
        if not self._conn(connection)["events"]:
            return self._refuse("session.subscribe", "Denied", "UnsupportedCapability")
        sess = self.sessions[sid]
        already = sess["subscribed"]
        sess["subscribed"] = True
        return self._reply(
            "session.subscribe",
            {
                "session_id": sid,
                "generation": sess["generation"],
                "subscribed": True,
                "already_subscribed": already,
                "sequence": sess["subscription_sequence"],
            },
        )

    def _session_status(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        sid = params.get("session_id")
        if not isinstance(sid, str):
            return self._refuse("session.status", "Validation", "InvalidRequest")
        token = (
            params.get("control_token")
            if isinstance(params.get("control_token"), str)
            else None
        )
        if (
            not self._session_visible(connection, sid, token)
            or sid not in self.sessions
        ):
            return self._refuse("session.status", "NotFound", "NotFound")
        return self._reply(
            "session.status",
            {
                "session": self._session_json(
                    self.sessions[sid],
                    self._has_scope(connection, "daemon.inspect"),
                    self.clock_ms,
                )
            },
        )

    def _session_list(self, connection: str) -> dict[str, Any]:
        operator = self._has_scope(connection, "daemon.inspect")
        now = self.clock_ms
        leases = self._conn(connection)["leases"]
        items: list[dict[str, Any]] = []
        for sid in sorted(self.sessions):
            sess = self.sessions[sid]
            visible = operator or any(
                aid in sess["leases"] and sess["leases"][aid]["expires_ms"] > now
                for aid in leases
            )
            if visible:
                val = self._session_json(sess, operator, now)
                if operator:
                    val["owner"] = {"uid": FAKE_PEER_UID, "pid": FAKE_PEER_PID}
                items.append(val)
        return self._reply("session.list", {"sessions": items})

    def _session_attach(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        role = params.get("attach_role")
        if role == "controller":
            return self._attach_controller(connection, params)
        if role == "observer":
            return self._attach_observer(connection, params)
        return self._refuse("session.attach", "Validation", "InvalidRequest")

    def _attach_controller(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self._has_scope(connection, "session.control"):
            return self._refuse("session.attach", "Denied", "ScopeViolation")
        sid = params.get("session_id")
        gen = params.get("expected_generation")
        if not isinstance(sid, str) or not is_uint(gen):
            return self._refuse("session.attach", "Validation", "InvalidRequest")
        token = (
            params.get("control_token")
            if isinstance(params.get("control_token"), str)
            else None
        )
        vis_err = self._control_visible(connection, sid, token)
        if vis_err is not None:
            return self._refuse("session.attach", vis_err[0], vis_err[1])
        sess = self.sessions.get(sid)
        if not sess:
            return self._refuse("session.attach", "NotFound", "NotFound")
        if sess["generation"] != gen:
            return self._refuse(
                "session.attach",
                "Denied",
                "StaleGeneration",
                (sess["generation"], sess["revision"]),
            )
        if sess["controller"] is not None:
            return self._refuse("session.attach", "Denied", "ControlHeld")
        if token != sess["token"]:
            return self._refuse("session.attach", "Denied", "InvalidControlToken")
        attach = self._mint_id()
        rotated = self._mint_token()
        now = self.clock_ms
        expires = now + self.limits["attach_lease_ttl_ms"]
        conn = self._conn(connection)
        sess["revision"] += 1
        sess["state_changed_ms"] = now
        sess["controller"] = attach
        sess["token"] = rotated
        sess["initial_token"] = None
        sess["leases"][attach] = {
            "role": "controller",
            "expires_ms": expires,
            "client_id": conn["client_id"],
            "attached_ms": now,
            "last_seen_ms": now,
        }
        conn["leases"].add(attach)
        conn["event_cursor"][attach] = sess["revision"]
        return self._reply(
            "session.attach",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), now
                ),
                "attach_id": attach,
                "role": "controller",
                "lease_expires_at_ms": expires,
                "control_token": rotated,
                "replayed": False,
                "scopes": self._connection_scopes(connection),
                "server_monotonic_ms": now,
            },
        )

    def _attach_observer(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self._has_scope(connection, "session.attach"):
            return self._refuse("session.attach", "Denied", "ScopeViolation")
        sid = params.get("session_id")
        if not isinstance(sid, str):
            return self._refuse("session.attach", "Validation", "InvalidRequest")
        bearer = params.get("observer_grant")
        if not isinstance(bearer, str):
            return self._refuse("session.attach", "Denied", "ObserverGrantRequired")
        now = self.clock_ms
        conn = self._conn(connection)
        grant = self.grants.get(bearer)
        valid = bool(
            grant
            and grant["kind"] == "observer"
            and grant["session"] == sid
            and not grant["consumed"]
            and not grant["revoked"]
            and grant["expires_ms"] > now
            and correlation_accepts(grant["correlation"], conn["correlation"])
        )
        if not valid:
            return self._refuse("session.attach", "Denied", "ObserverGrantRequired")
        sess = self.sessions.get(sid)
        if not sess:
            return self._refuse("session.attach", "NotFound", "NotFound")
        limit = self.limits["max_attaches_per_session"]
        observers = sum(
            1
            for l in sess["leases"].values()
            if l["role"] == "observer" and l["expires_ms"] > now
        )
        if observers >= limit:
            return self._refuse(
                "session.attach", "Framing", "LimitExceeded", (0, limit)
            )
        grant["consumed"] = True
        sess["pending_grants"] = max(0, sess["pending_grants"] - 1)
        attach = self._mint_id()
        expires = now + self.limits["attach_lease_ttl_ms"]
        sess["revision"] += 2
        sess["state_changed_ms"] = now
        sess["leases"][attach] = {
            "role": "observer",
            "expires_ms": expires,
            "client_id": conn["client_id"],
            "attached_ms": now,
            "last_seen_ms": now,
        }
        conn["leases"].add(attach)
        conn["event_cursor"][attach] = sess["revision"]
        return self._reply(
            "session.attach",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), now
                ),
                "attach_id": attach,
                "role": "observer",
                "lease_expires_at_ms": expires,
                "replayed": False,
                "scopes": self._connection_scopes(connection),
                "server_monotonic_ms": now,
            },
        )

    def _session_grant(self, connection: str, params: dict[str, Any]) -> dict[str, Any]:
        if "client_correlation_digest" in params:
            return self._refuse("session.grant", "Validation", "InvalidRequest")
        sid = params.get("session_id")
        if not isinstance(sid, str):
            return self._refuse("session.grant", "Validation", "InvalidRequest")
        token = (
            params.get("control_token")
            if isinstance(params.get("control_token"), str)
            else None
        )
        vis_err = self._control_visible(connection, sid, token)
        if vis_err is not None:
            return self._refuse("session.grant", vis_err[0], vis_err[1])
        sess = self.sessions.get(sid)
        if sess and is_terminal_state(sess["state"]):
            return self._refuse("session.grant", "Denied", "NotRunning")
        auth_err = self._control_authority(connection, sid, token)
        if auth_err is not None:
            return self._refuse("session.grant", auth_err[0], auth_err[1])
        key_raw = params.get("idempotency_key")
        if not isinstance(key_raw, str):
            return self._refuse("session.grant", "Validation", "InvalidRequest")
        ok, ttl_ms, counts = self._optional_ttl(
            params, "ttl_ms", self.limits["observer_grant_ttl_ms"]
        )
        if not ok:
            return self._refuse("session.grant", "Validation", "InvalidRequest", counts)
        correlation: str | None = None
        if "observer_correlation_digest" in params:
            correlation = parse_grant_correlation(params["observer_correlation_digest"])
            if correlation is None:
                return self._refuse("session.grant", "Validation", "InvalidRequest")
        limit = self.limits["max_pending_observer_grants_per_session"]
        active = sum(
            1
            for g in self.grants.values()
            if g["kind"] == "observer"
            and g["session"] == sid
            and not g["consumed"]
            and not g["revoked"]
            and g["expires_ms"] > self.clock_ms
        )
        if active >= limit:
            return self._refuse("session.grant", "Framing", "LimitExceeded", (0, limit))
        key = f"grant:{sid}:{key_raw}"
        fp = f"{ttl_ms or 0}|{correlation or 'none'}"
        if key in self.grant_keys:
            gid, recorded = self.grant_keys[key]
            if recorded != fp:
                return self._refuse("session.grant", "Denied", "IdempotencyConflict")
            bearer_found = next(
                (b for b, g in self.grants.items() if g["id"] == gid), None
            )
            if bearer_found is not None:
                return self._reply(
                    "session.grant",
                    {
                        "grant_id": gid,
                        "grant": bearer_found,
                        "grant_active": not self.grants[bearer_found]["consumed"],
                        "session_id": sid,
                        "replayed": True,
                    },
                )
            return self._reply(
                "session.grant",
                {
                    "grant_id": gid,
                    "grant": None,
                    "grant_active": False,
                    "session_id": sid,
                    "replayed": True,
                },
            )
        gid = self._mint_id()
        bearer = self._mint_token()
        expires = self.clock_ms + (
            ttl_ms if ttl_ms is not None else self.limits["observer_grant_ttl_ms"]
        )
        self.grants[bearer] = {
            "id": gid,
            "session": sid,
            "kind": "observer",
            "expires_ms": expires,
            "consumed": False,
            "revoked": False,
            "correlation": correlation,
        }
        self.grant_keys[key] = (gid, fp)
        if sess:
            sess["pending_grants"] += 1
            sess["revision"] += 1
        return self._reply(
            "session.grant",
            {
                "grant_id": gid,
                "grant": bearer,
                "expires_at_ms": expires,
                "session_id": sid,
                "replayed": False,
            },
        )

    def _session_grant_revoke(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        if (
            "ttl_ms" in params
            or "observer_correlation_digest" in params
            or "client_correlation_digest" in params
        ):
            return self._refuse("session.grant.revoke", "Validation", "InvalidRequest")
        gid = params.get("grant_id")
        if not isinstance(gid, str):
            return self._refuse("session.grant.revoke", "Validation", "InvalidRequest")
        bearer = next(
            (
                b
                for b, g in self.grants.items()
                if g["id"] == gid and g["kind"] == "observer"
            ),
            None,
        )
        if bearer is not None:
            grant = self.grants[bearer]
            observed = self._conn(connection)["correlation"]
            if not self._has_scope(
                connection, "daemon.control"
            ) and not correlation_accepts(grant["correlation"], observed):
                return self._reply(
                    "session.grant.revoke",
                    {"grant_id": gid, "revoked": False, "not_active": True},
                )
            sid = grant["session"]
            token = (
                params.get("control_token")
                if isinstance(params.get("control_token"), str)
                else None
            )
            vis_err = self._control_visible(connection, sid, token)
            if vis_err is not None:
                return self._refuse("session.grant.revoke", vis_err[0], vis_err[1])
            sess = self.sessions.get(sid)
            if sess and is_terminal_state(sess["state"]):
                return self._refuse("session.grant.revoke", "Denied", "NotRunning")
            auth_err = self._control_authority(connection, sid, token)
            if auth_err is not None:
                return self._refuse("session.grant.revoke", auth_err[0], auth_err[1])
            active = (
                not grant["consumed"]
                and not grant["revoked"]
                and grant["expires_ms"] > self.clock_ms
            )
            grant["revoked"] = True
            if active and sess:
                sess["pending_grants"] = max(0, sess["pending_grants"] - 1)
                sess["revision"] += 1
            return self._reply(
                "session.grant.revoke",
                {"grant_id": gid, "revoked": active, "not_active": not active},
            )
        return self._reply(
            "session.grant.revoke",
            {"grant_id": gid, "revoked": False, "not_active": True},
        )

    def _session_detach(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        attach = params.get("attach_id")
        if not isinstance(attach, str):
            return self._refuse("session.detach", "Validation", "InvalidRequest")
        conn = self._conn(connection)
        own = attach in conn["leases"]
        target_sid = next(
            (sid for sid, s in self.sessions.items() if attach in s["leases"]),
            None,
        )
        if not own:
            if not (
                self._has_scope(connection, "session.control")
                or self._has_scope(connection, "daemon.control")
            ):
                return self._refuse("session.detach", "Denied", "ScopeViolation")
            if target_sid is None:
                det = self.detached.get(attach)
                if det is not None and det[1] == connection and det[0] in self.sessions:
                    sess = self.sessions[det[0]]
                    return self._reply(
                        "session.detach",
                        {
                            "session": self._session_json(
                                sess,
                                self._has_scope(connection, "daemon.inspect"),
                                self.clock_ms,
                            ),
                            "attach_id": attach,
                            "was_attached": False,
                            "not_attached": True,
                            "revoked": False,
                        },
                    )
                return self._refuse("session.detach", "NotFound", "NotFound")
            token = (
                params.get("control_token")
                if isinstance(params.get("control_token"), str)
                else None
            )
            vis_err = self._control_visible(connection, target_sid, token)
            if vis_err is not None:
                return self._refuse("session.detach", vis_err[0], vis_err[1])
            auth_err = self._control_authority(connection, target_sid, token)
            if auth_err is not None:
                return self._refuse("session.detach", auth_err[0], auth_err[1])
        if target_sid is None:
            return self._refuse("session.detach", "NotFound", "NotFound")
        sess = self.sessions[target_sid]
        removed = sess["leases"].pop(attach, None) is not None
        now = self.clock_ms
        if removed:
            sess["revision"] += 1
            sess["state_changed_ms"] = now
            if sess["controller"] == attach:
                sess["controller"] = None
            for c in self.connections.values():
                c["leases"].discard(attach)
            self.detached[attach] = (target_sid, connection)
        conn["leases"].discard(attach)
        return self._reply(
            "session.detach",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), now
                ),
                "attach_id": attach,
                "was_attached": removed,
                "not_attached": not removed,
                "revoked": removed and not own,
            },
        )

    def _session_transfer(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        sid = params.get("session_id")
        target = canonical_target_attach(params)
        gen = canonical_generation(params)
        if not isinstance(sid, str) or target is None or gen is None:
            return self._refuse(
                "session.control.transfer", "Validation", "InvalidRequest"
            )
        token = (
            params.get("control_token")
            if isinstance(params.get("control_token"), str)
            else None
        )
        vis_err = self._control_visible(connection, sid, token)
        if vis_err is not None:
            return self._refuse("session.control.transfer", vis_err[0], vis_err[1])
        sess = self.sessions.get(sid)
        if not sess:
            return self._refuse("session.control.transfer", "NotFound", "NotFound")
        if sess["generation"] != gen:
            return self._refuse("session.control.transfer", "Denied", "StaleGeneration")
        auth_err = self._control_authority(connection, sid, token)
        if auth_err is not None:
            return self._refuse("session.control.transfer", auth_err[0], auth_err[1])
        now = self.clock_ms
        target_lease = sess["leases"].get(target)
        if (
            not target_lease
            or target_lease["role"] != "observer"
            or target_lease["expires_ms"] <= now
        ):
            return self._refuse(
                "session.control.transfer", "Denied", "ControllerRequired"
            )
        previous = sess["controller"]
        rotated = self._mint_token()
        if previous and previous in sess["leases"]:
            sess["leases"][previous]["role"] = "observer"
        sess["leases"][target]["role"] = "controller"
        sess["controller"] = target
        sess["token"] = rotated
        sess["initial_token"] = None
        sess["revision"] += 1
        sess["state_changed_ms"] = now
        self.deliveries[target] = rotated
        return self._reply(
            "session.control.transfer",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), now
                ),
                "controller": target,
                "previous_controller": previous,
                "replayed": False,
            },
        )

    def _session_abort(self, connection: str, params: dict[str, Any]) -> dict[str, Any]:
        sid = params.get("session_id")
        gen = canonical_generation(params)
        if not isinstance(sid, str) or gen is None:
            return self._refuse("session.abort", "Validation", "InvalidRequest")
        reason = params.get("reason_class", "")
        token = (
            params.get("control_token")
            if isinstance(params.get("control_token"), str)
            else None
        )
        vis_err = self._control_visible(connection, sid, token)
        if vis_err is not None:
            return self._refuse("session.abort", vis_err[0], vis_err[1])
        sess = self.sessions.get(sid)
        if not sess:
            return self._refuse("session.abort", "NotFound", "NotFound")
        if is_terminal_state(sess["state"]):
            return self._reply(
                "session.abort",
                {
                    "session": self._session_json(
                        sess,
                        self._has_scope(connection, "daemon.inspect"),
                        self.clock_ms,
                    ),
                    "accepted": False,
                    "not_running": True,
                },
            )
        if sess["generation"] != gen:
            return self._refuse(
                "session.abort",
                "Denied",
                "StaleGeneration",
                (sess["generation"], sess["revision"]),
            )
        if reason not in ("cancel", "timeout", "operator"):
            return self._refuse("session.abort", "Validation", "InvalidRequest")
        if reason == "operator":
            if not self._has_scope(connection, "daemon.control"):
                return self._refuse("session.abort", "Denied", "ScopeViolation")
        else:
            auth_err = self._control_authority(connection, sid, token)
            if auth_err is not None:
                return self._refuse("session.abort", auth_err[0], auth_err[1])
        terminal = {
            "cancel": "consumer_cancel",
            "timeout": "consumer_timeout",
            "operator": "operator_abort",
        }[reason]
        req_kind = "operator" if reason == "operator" else "consumer"
        sess["requested_by"] = (req_kind, self._conn(connection)["client_id"])
        self._terminate(sid, terminal)
        return self._reply(
            "session.abort",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), self.clock_ms
                ),
                "accepted": True,
                "reason": terminal,
                "stage": "not_started",
                "cleanup": "not_started",
            },
        )

    def _session_kill(self, connection: str, params: dict[str, Any]) -> dict[str, Any]:
        sid = params.get("session_id")
        gen = canonical_generation(params)
        if not isinstance(sid, str) or gen is None:
            return self._refuse("session.kill", "Validation", "InvalidRequest")
        if not self._session_visible(connection, sid, None) or sid not in self.sessions:
            return self._refuse("session.kill", "NotFound", "NotFound")
        sess = self.sessions[sid]
        if is_terminal_state(sess["state"]):
            return self._reply(
                "session.kill",
                {
                    "session": self._session_json(
                        sess,
                        self._has_scope(connection, "daemon.inspect"),
                        self.clock_ms,
                    ),
                    "accepted": False,
                    "not_running": True,
                },
            )
        if sess["generation"] != gen:
            return self._refuse("session.kill", "Denied", "StaleGeneration")
        auth_err = self._control_authority(connection, sid, None)
        if auth_err is not None:
            return self._refuse("session.kill", auth_err[0], auth_err[1])
        sess["requested_by"] = ("operator", self._conn(connection)["client_id"])
        self._terminate(sid, "operator_abort")
        return self._reply(
            "session.kill",
            {
                "session": self._session_json(
                    sess, self._has_scope(connection, "daemon.inspect"), self.clock_ms
                ),
                "accepted": True,
                "reason": "operator_abort",
                "stage": "not_started",
                "cleanup": "not_started",
            },
        )

    def _lease_heartbeat(
        self, connection: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        attach = params.get("attach_id")
        if not isinstance(attach, str):
            return self._refuse("lease.heartbeat", "Validation", "InvalidRequest")
        conn = self._conn(connection)
        if attach not in conn["leases"]:
            return self._refuse("lease.heartbeat", "NotFound", "NotFound")
        now = self.clock_ms
        found: tuple[str, int] | None = None
        for sid, sess in self.sessions.items():
            lease = sess["leases"].get(attach)
            if lease is not None:
                if lease["expires_ms"] <= now:
                    break
                lease["expires_ms"] = now + self.limits["attach_lease_ttl_ms"]
                lease["last_seen_ms"] = now
                sess["last_seen_ms"] = now
                found = (sid, lease["expires_ms"])
                break
        if found is None:
            return self._refuse("lease.heartbeat", "NotFound", "NotFound")
        sid, expires = found
        token = conn["pending"].pop(attach, None)
        return self._reply(
            "lease.heartbeat",
            {
                "session": self._session_json(
                    self.sessions[sid],
                    self._has_scope(connection, "daemon.inspect"),
                    now,
                ),
                "attach_id": attach,
                "lease_expires_at_ms": expires,
                "control_token": token,
                "server_monotonic_ms": now,
            },
        )

    def queue_pressure(
        self, connection: str, method: str, count: int, params: Any
    ) -> dict[str, Any]:
        limit = self.limits["max_connection_outbound_bytes"]
        queued = 0
        for _ in range(count):
            out = self.call(connection, method, params)
            if out.get("transport") == "closed":
                return out
            queued += len(
                json.dumps(out.get("result"), separators=(",", ":")).encode("utf-8")
            )
            if queued > limit:
                self._conn(connection)["closed"] = True
                self.audit.append("v1 a=wire r=refused c=limit_exceeded")
                return {"transport": "closed"}
        return self._refuse(method, "Harness", "DidNotClose")

    def oversized_frame(self, connection: str, declared: int) -> dict[str, Any]:
        if declared <= self.limits["max_frame_bytes"]:
            return {"transport": "closed"}
        self._conn(connection)["closed"] = True
        self.audit.append("v1 a=wire r=refused c=limit_exceeded")
        return {"transport": "closed"}

    def partial_frame(
        self, connection: str, declared: int, body: int
    ) -> dict[str, Any]:
        if (
            body + 4 <= self.limits["pre_auth_max_bytes"]
            and declared <= self.limits["max_frame_bytes"]
        ):
            return {"transport": "closed"}
        self._conn(connection)["closed"] = True
        self.audit.append("v1 a=wire r=refused c=limit_exceeded")
        return {"transport": "closed"}

    def read_events(self, connection: str, count: int) -> list[dict[str, Any]]:
        conn = self.connections.get(connection)
        if not conn:
            raise RuntimeError("unknown connection")
        if not conn["events"]:
            raise RuntimeError("connection did not opt in to events")
        cursors = dict(conn["event_cursor"])
        events: list[dict[str, Any]] = []
        for attach in sorted(conn["leases"]):
            sess = next(
                (s for s in self.sessions.values() if attach in s["leases"]), None
            )
            if not sess:
                continue
            cursor = cursors.get(attach, 0)
            for rev in range(cursor + 1, sess["revision"] + 1):
                terminal = is_terminal_state(sess["state"]) and rev == sess["revision"]
                events.append(
                    {
                        "kind": "session_terminal" if terminal else "session_state",
                        "instance_id": self.instance,
                        "session_id": sess["id"],
                        "attach_id": attach,
                        "revision": rev,
                        "terminal": terminal,
                    }
                )
            cursors[attach] = sess["revision"]
        if len(events) != count:
            raise RuntimeError(
                f"fake has {len(events)} queued events, expected {count}"
            )
        conn["event_cursor"] = cursors
        return events

    def child_process_count(self) -> int:
        return sum(
            1
            for s in self.sessions.values()
            if s["generation"] >= 1 and not is_terminal_state(s["state"])
        )

    def cli_stop(self, mode: str) -> tuple[int, str]:
        out = self._daemon_stop("operator", {"mode": mode})
        if out.get("transport") == "closed":
            raise RuntimeError("fake stop closed operator connection")
        if out["ok"]:
            code = 0
        else:
            err_code = (out.get("error") or {}).get("code")
            if err_code == "ActiveSessions":
                code = 3
            elif err_code == "DaemonStopping":
                code = 0
            else:
                code = 1
        return code, f"bittyd: stop ({mode})\n"


class LuaAdapterBridge:
    """Persistent stdio client driving `lua/wheel/bittyd_adapter.lua`."""

    def __init__(self, interpreter: str) -> None:
        self.proc = subprocess.Popen(
            [interpreter, str(BRIDGE_SCRIPT)],
            cwd=str(REPO_ROOT),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    def _send_line(self, payload: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        try:
            self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
            self.proc.stdin.flush()
        except BrokenPipeError as exc:
            stderr = self.proc.stderr.read() if self.proc.stderr else ""
            raise RuntimeError(
                f"Lua adapter bridge exited unexpectedly: {stderr.strip()}"
            ) from exc

    def _recv_line(self) -> dict[str, Any]:
        assert self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if not line:
            stderr = self.proc.stderr.read() if self.proc.stderr else ""
            raise RuntimeError(
                f"Lua adapter bridge exited unexpectedly: {stderr.strip()}"
            )
        return json.loads(line)

    def reset(
        self, *, server_available: bool, refuse_connections: list[str] | None = None
    ) -> None:
        self._send_line(
            {
                "cmd": "reset",
                "server_available": server_available,
                "refuse_connections": refuse_connections or [],
            }
        )
        ack = self._recv_line()
        if ack.get("op") != "reset_ok":
            raise RuntimeError(f"unexpected bridge reset response: {ack}")

    def call(
        self,
        connection: str,
        method: str,
        params: Any,
        fault: str | None,
        fake: ReferenceFakeServer | None,
    ) -> tuple[dict[str, Any], bool]:
        self._send_line(
            {
                "cmd": "call",
                "connection": connection,
                "method": method,
                "params": params,
                "fault": fault,
            }
        )
        msg = self._recv_line()
        transport_used = False
        while msg.get("op") == "transport":
            transport_used = True
            if fake is None:
                raise RuntimeError(
                    "Lua adapter attempted transport send when server_available=False"
                )
            conn_name = msg["connection"]
            m_name = msg["method"]
            req_fault = msg.get("fault")
            # Preserve exact JSON types (e.g. `1` vs `1.0` alias checks) while
            # sending through the Lua adapter's verified envelope.
            wire_out = (
                fake.call_dropping(conn_name, m_name, params)
                if req_fault == "drop_before_reply"
                else fake.call(conn_name, m_name, params)
            )
            self._send_line(wire_out)
            msg = self._recv_line()
        if msg.get("op") != "result":
            raise RuntimeError(f"unexpected bridge response: {msg}")
        return msg["reply"], transport_used

    def adapter_state(self) -> dict[str, Any]:
        self._send_line({"cmd": "adapter_state"})
        msg = self._recv_line()
        if msg.get("op") != "state":
            raise RuntimeError(f"unexpected bridge state response: {msg}")
        return msg

    def close(self) -> None:
        try:
            if self.proc.poll() is None:
                self._send_line({"cmd": "quit"})
                self._recv_line()
        except RuntimeError:
            pass
        finally:
            if self.proc.poll() is None:
                self.proc.terminate()
            self.proc.wait(timeout=5)


def normalize_path(path: str) -> str:
    return path.removeprefix("result.")


def path_get(value: Any, path: str) -> tuple[bool, Any]:
    cur = value
    for seg in normalize_path(path).split("."):
        if isinstance(cur, dict):
            if seg not in cur:
                return False, None
            cur = cur[seg]
        elif isinstance(cur, list):
            if not seg.isdigit():
                return False, None
            idx = int(seg)
            if idx < 0 or idx >= len(cur):
                return False, None
            cur = cur[idx]
        else:
            return False, None
    return True, cur


def has_field_recursive(value: Any, field: str) -> bool:
    if isinstance(value, dict):
        return any(
            k == field or has_field_recursive(v, field) for k, v in value.items()
        )
    if isinstance(value, list):
        return any(has_field_recursive(item, field) for item in value)
    return False


def substitute_text(text: str, vars_map: dict[str, Any]) -> str:
    out = text
    for name, val in vars_map.items():
        if isinstance(val, str):
            out = out.replace("{{" + name + "}}", val)
    return out


def resolve_value(value: Any, vars_map: dict[str, Any]) -> Any:
    if isinstance(value, str):
        if value.startswith("@"):
            key = value[1:]
            if key in vars_map:
                return copy.deepcopy(vars_map[key])
        return substitute_text(value, vars_map)
    if isinstance(value, list):
        return [resolve_value(item, vars_map) for item in value]
    if isinstance(value, dict):
        return {k: resolve_value(v, vars_map) for k, v in value.items()}
    return copy.deepcopy(value)


def resolve_needle(text: str, vars_map: dict[str, Any]) -> str:
    if text.startswith("@"):
        val = vars_map.get(text[1:])
        if isinstance(val, str):
            return val
    return substitute_text(text, vars_map)


def check_audit_expect(
    expect_audit: dict[str, Any], audit_text: str, vars_map: dict[str, Any]
) -> None:
    for raw_needle in expect_audit.get("contains") or []:
        needle = resolve_needle(raw_needle, vars_map)
        if needle not in audit_text:
            raise AssertionError(f"audit does not contain {needle!r}")
    for raw_needle in expect_audit.get("not_contains") or []:
        needle = resolve_needle(raw_needle, vars_map)
        if needle and needle in audit_text:
            raise AssertionError("audit contains a forbidden value")
    for bound in expect_audit.get("line_bounds") or []:
        needle = bound["needle"]
        min_c = int(bound.get("min", 0))
        max_c = int(bound.get("max", 10**9))
        count = sum(1 for line in audit_text.splitlines() if needle in line)
        if count < min_c or count > max_c:
            raise AssertionError(
                f"audit has {count} lines with {needle!r}, expected {min_c}..={max_c}"
            )


def check_expect(
    expect: dict[str, Any],
    outcome: dict[str, Any],
    fake: ReferenceFakeServer | None,
    adapter_closed: bool,
    connection: str,
    vars_map: dict[str, Any],
    gated: dict[str, str],
) -> list[str]:
    if expect.get("transport") == "closed":
        if outcome.get("transport") != "closed":
            raise AssertionError("expected transport to close without a reply")
        return []
    if outcome.get("transport") == "closed":
        raise AssertionError("expected a reply, transport closed")

    ok = bool(outcome.get("ok"))
    if "ok" in expect and expect["ok"] is not None and ok != bool(expect["ok"]):
        raise AssertionError(
            f"expected ok={expect['ok']}, observed ok={ok} ({outcome.get('error')})"
        )
    if outcome.get("error") is not None and outcome.get("result") is not None:
        raise AssertionError("an error reply must not carry a result")

    if "error_code" in expect and expect["error_code"] is not None:
        err = outcome.get("error")
        if not isinstance(err, dict):
            raise AssertionError(
                f"expected error {expect['error_code']}, observed success"
            )
        if err.get("code") != expect["error_code"]:
            raise AssertionError(
                f"expected error code {expect['error_code']}, observed {err.get('code')}"
            )
        if (
            expect.get("error_class") is not None
            and err.get("class") != expect["error_class"]
        ):
            raise AssertionError(
                f"expected error class {expect['error_class']}, observed {err.get('class')}"
            )
        if expect.get("counts") is not None:
            want_counts = [
                int(expect["counts"]["actual"]),
                int(expect["counts"]["limit"]),
            ]
            if err.get("counts") != want_counts:
                raise AssertionError(
                    f"expected counts {want_counts}, observed {err.get('counts')}"
                )
        err_fields = err.get("fields") or {}
        for path, want_raw in (expect.get("error_fields") or {}).items():
            want = resolve_value(want_raw, vars_map)
            if path not in err_fields:
                raise AssertionError(f"missing error field {path}")
            if not raw_json_equal(err_fields[path], want):
                raise AssertionError(f"error field {path} mismatch")
        for path in expect.get("error_present") or []:
            if err_fields.get(path) is None:
                raise AssertionError(f"missing error field {path}")

    skipped: list[str] = []
    result = outcome.get("result")
    for raw_path, want_raw in (expect.get("result") or {}).items():
        path = normalize_path(raw_path)
        if path in gated:
            found, val = path_get(result, path)
            if not found or val is None:
                raise AssertionError(f"missing result path {path}")
            skipped.append(f"{path}: requires-{gated[path]}")
            continue
        want = resolve_value(want_raw, vars_map)
        found, actual = path_get(result, path)
        if not found:
            raise AssertionError(f"missing result path {path}")
        if not raw_json_equal(actual, want):
            sensitive = any(
                s in path for s in ("token", "grant", "capability", "secret", "bearer")
            )
            if sensitive:
                raise AssertionError(f"result {path} does not match expectation")
            raise AssertionError(f"result {path} is {actual!r}, expected {want!r}")

    for raw_path, minimum in (expect.get("result_min") or {}).items():
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if not found or not is_uint(actual) or actual < int(minimum):
            raise AssertionError(f"result {path} is {actual!r}, expected >= {minimum}")

    for raw_path in expect.get("present") or []:
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if not found or actual is None:
            raise AssertionError(f"missing field {path}")

    for raw_path in expect.get("absent") or []:
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if found and actual is not None:
            raise AssertionError(f"field {path} must be absent")

    for raw_path, want_raw in (expect.get("array") or {}).items():
        path = normalize_path(raw_path)
        want = resolve_value(want_raw, vars_map)
        found, actual = path_get(result, path)
        if not found or not raw_json_equal(actual, want):
            raise AssertionError(f"array {path} mismatch: {actual!r} != {want!r}")

    for raw_path, want_len in (expect.get("array_len") or {}).items():
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if not found or not isinstance(actual, list) or len(actual) != int(want_len):
            raise AssertionError(f"array {path} length mismatch: expected {want_len}")

    for raw_path, min_len in (expect.get("min_array_len") or {}).items():
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if not found or not isinstance(actual, list) or len(actual) < int(min_len):
            raise AssertionError(f"array {path} length below {min_len}")

    for raw_path, hex_len in (expect.get("hex_len") or {}).items():
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if (
            not found
            or not isinstance(actual, str)
            or len(actual) != int(hex_len)
            or not all(c in "0123456789abcdefABCDEF" for c in actual)
        ):
            raise AssertionError(f"{path} is not {hex_len} hex chars")

    distinct_paths = [normalize_path(p) for p in (expect.get("distinct") or [])]
    if distinct_paths:
        seen: set[str] = set()
        for path in distinct_paths:
            found, actual = path_get(result, path)
            if not found:
                raise AssertionError(f"missing distinct path {path}")
            key = json.dumps(actual, sort_keys=True)
            if key in seen:
                raise AssertionError(f"{path} repeats a value")
            seen.add(key)

    for raw_path, var_ref in (expect.get("not_equal") or {}).items():
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if not found:
            raise AssertionError(f"missing path {path}")
        var_name = var_ref.lstrip("@")
        if var_name not in vars_map:
            raise AssertionError(f"unknown variable {var_ref}")
        if raw_json_equal(actual, vars_map[var_name]):
            raise AssertionError(f"{path} equals {var_ref}")

    for raw_path, var_refs in (expect.get("not_equal_any") or {}).items():
        path = normalize_path(raw_path)
        found, actual = path_get(result, path)
        if not found:
            raise AssertionError(f"missing path {path}")
        for var_ref in var_refs:
            var_name = var_ref.lstrip("@")
            if var_name not in vars_map:
                raise AssertionError(f"unknown variable {var_ref}")
            if raw_json_equal(actual, vars_map[var_name]):
                raise AssertionError(f"{path} equals {var_ref}")

    for raw_path, raw_other in (expect.get("path_equal") or {}).items():
        path = normalize_path(raw_path)
        other = normalize_path(raw_other)
        found_a, actual_a = path_get(result, path)
        found_b, actual_b = path_get(result, other)
        if not found_a:
            raise AssertionError(f"missing path {path}")
        if not found_b:
            raise AssertionError(f"missing path {other}")
        if not raw_json_equal(actual_a, actual_b):
            raise AssertionError(f"{path} is {actual_a!r}, {other} is {actual_b!r}")

    if expect.get("closed"):
        fake_eof = bool(fake and fake.connections.get(connection, {}).get("closed"))
        if not (fake_eof or adapter_closed):
            raise AssertionError("expected connection to close after refusal")

    return skipped


def run_vector(
    vector: dict[str, Any], bridge: LuaAdapterBridge, cwd_seed: str
) -> dict[str, Any]:
    vid = vector["id"]
    drivers = vector.get("drivers") or []
    fake_skip = vector.get("fake_skip")

    # Never mark a real-service-only row passed from an adapter run.
    if "fake" not in drivers:
        reason = (
            vector.get("real_skip")
            or "driver-not-required: real-only vector (adapter runner)"
        )
        return {"id": vid, "status": "skip", "skip_reason": reason}

    # Skip D-01 unamended rows; run adapter-owned rows (V-29, V-30) here!
    if fake_skip and not fake_skip.startswith("adapter-owned:"):
        return {"id": vid, "status": "skip", "skip_reason": fake_skip}

    is_v29 = vid == "V-29"
    is_v30 = vid == "V-30"
    is_v33 = vid == "V-33"

    fake = None if is_v29 else ReferenceFakeServer(vector)
    bridge.reset(
        server_available=not is_v29,
        refuse_connections=["client"] if is_v30 else [],
    )

    vars_map = {"worker_sessions": FAKE_WORKER_SESSIONS, "cwd": cwd_seed}
    if fake is not None:
        vars_map = fake.seeds(cwd_seed)
        if is_v30:
            # Pre-negotiate the operator inspection channel so V-30's `operator`
            # status checks observe the daemon while `client` sends 0 connections.
            op_neg = fake.call(
                "operator",
                "daemon.negotiate",
                {
                    "client_version": {"major": 1, "minor": 0},
                    "operator_capability": fake.operator_capability,
                },
            )
            assert op_neg.get("ok") is True

    gated: dict[str, str] = {}
    if fake is not None:
        facts = fake.facts()
        for req in vector.get("requires") or []:
            if (
                facts["capabilities"].get(req) is not True
                and facts["features"].get(req) is not True
                and facts["seams"].get(req) is not True
            ):
                return {
                    "id": vid,
                    "status": "skip",
                    "skip_reason": f"cell-not-servable: {req}",
                }
        for raw_path, req in (vector.get("gated_assertions") or {}).items():
            path = normalize_path(raw_path)
            if req not in facts["features"]:
                raise AssertionError(f"{vid}: unmodeled gated capability {req}")
            if not facts["features"][req]:
                gated[path] = req

    all_steps = list(vector.get("steps") or []) + list(vector.get("state") or [])
    for step_idx, step in enumerate(all_steps):
        try:
            expect = step.get("expect") or {}
            action = step.get("action")
            if action is not None:
                conn = step.get("connection") or "default"
                args = step.get("args") or {}
                if action == "advance_clock":
                    assert fake is not None
                    fake.clock_ms += int(args["ms"])
                elif action == "oversized_frame":
                    assert fake is not None
                    out = fake.oversized_frame(conn, int(args["declared_len"]))
                    check_expect(expect, out, fake, False, conn, vars_map, gated)
                elif action == "partial_frame":
                    assert fake is not None
                    out = fake.partial_frame(
                        conn, int(args["declared_len"]), int(args["body_bytes"])
                    )
                    check_expect(expect, out, fake, False, conn, vars_map, gated)
                elif action == "queue_pressure":
                    assert fake is not None
                    out = fake.queue_pressure(
                        conn,
                        str(args["method"]),
                        int(args["count"]),
                        args.get("params"),
                    )
                    check_expect(expect, out, fake, False, conn, vars_map, gated)
                elif action == "audit":
                    assert fake is not None
                    audit_exp = expect["audit"]
                    check_audit_expect(audit_exp, "\n".join(fake.audit), vars_map)
                    if is_v33:
                        # V-33 adapter half (`wheel#108`): verify the Lua Wheel
                        # adapter audit carries daemon_instance_id, client_id,
                        # session_id, and `a=session.create r=ok` with zero tokens.
                        ad_state = bridge.adapter_state()
                        ad_audit = ad_state["audit_text"]
                        check_audit_expect(audit_exp, ad_audit, vars_map)
                        if f"inst={fake.instance}" not in ad_audit:
                            raise AssertionError(
                                "V-33 adapter audit missing daemon_instance_id"
                            )
                        creator_info = ad_state["connections"].get("creator") or {}
                        cid = creator_info.get("client_id")
                        if not cid or f"client={cid}" not in ad_audit:
                            raise AssertionError("V-33 adapter audit missing client_id")
                        sid_captured = vars_map.get("session_id")
                        if (
                            isinstance(sid_captured, str)
                            and f"sid={sid_captured}" not in ad_audit
                        ):
                            raise AssertionError(
                                "V-33 adapter audit missing session_id"
                            )
                elif action == "child_processes":
                    want_children = int(expect["result"]["count"])
                    if is_v29:
                        actual_children = int(bridge.adapter_state()["child_processes"])
                    else:
                        assert fake is not None
                        actual_children = fake.child_process_count()
                    if actual_children != want_children:
                        raise AssertionError(
                            f"{actual_children} child processes, expected {want_children}"
                        )
                elif action == "cli_stop":
                    assert fake is not None
                    code, stdout = fake.cli_stop(str(args["mode"]))
                    if expect.get("exit_code") is not None and code != int(
                        expect["exit_code"]
                    ):
                        raise AssertionError(
                            f"cli_stop exit {code}, expected {expect['exit_code']}"
                        )
                    for needle in expect.get("stdout_contains") or []:
                        if needle not in stdout:
                            raise AssertionError(f"cli_stop stdout missing {needle!r}")
                elif action == "request_log":
                    assert fake is not None
                    rlog = expect["request_log"]
                    for req in fake.requests:
                        for forbidden in rlog.get("no_fields") or []:
                            if has_field_recursive(req["params"], forbidden):
                                raise AssertionError(
                                    f"request {req['method']} carries forbidden field {forbidden}"
                                )
                    for m_name, want_count in (rlog.get("method_counts") or {}).items():
                        got_count = sum(
                            1 for r in fake.requests if r["method"] == m_name
                        )
                        if got_count != int(want_count):
                            raise AssertionError(
                                f"sent {got_count} {m_name} requests, expected {want_count}"
                            )
                elif action == "read_events":
                    assert fake is not None
                    events = fake.read_events(conn, int(args["count"]))
                    per_event = args.get("events")
                    for ev_idx, event in enumerate(events):
                        assertions = (
                            per_event[ev_idx]
                            if isinstance(per_event, list) and ev_idx < len(per_event)
                            else (expect.get("result") or {})
                        )
                        for raw_path, want_raw in assertions.items():
                            found, actual = path_get(event, raw_path)
                            if not found:
                                raise AssertionError(
                                    f"event {ev_idx} missing {raw_path}"
                                )
                            want = resolve_value(want_raw, vars_map)
                            if not raw_json_equal(actual, want):
                                raise AssertionError(
                                    f"event[{ev_idx}].{raw_path} is {actual!r}, expected {want!r}"
                                )
                        for raw_path, other_raw in (
                            expect.get("not_equal") or {}
                        ).items():
                            found, actual = path_get(event, raw_path)
                            if not found:
                                raise AssertionError(
                                    f"event {ev_idx} missing {raw_path}"
                                )
                            other = resolve_needle(other_raw, vars_map)
                            if actual == other:
                                raise AssertionError(
                                    f"event[{ev_idx}].{raw_path} == {other!r}"
                                )
                        for raw_path in expect.get("present") or []:
                            if not has_field_recursive(event, raw_path):
                                raise AssertionError(
                                    f"event {ev_idx} missing {raw_path}"
                                )
                        for raw_path in expect.get("absent") or []:
                            if has_field_recursive(event, raw_path):
                                raise AssertionError(
                                    f"event {ev_idx} carries forbidden {raw_path}"
                                )
                    if expect.get("closed") and not fake.connections.get(conn, {}).get(
                        "closed"
                    ):
                        raise AssertionError("connection did not close after events")
                else:
                    raise AssertionError(f"unsupported action {action!r}")
                continue

            conn = str(step["connection"])
            method = str(step["method"])
            resolved_params = resolve_value(step.get("params"), vars_map)
            fault = step.get("fault")
            reply, transport_used = bridge.call(
                conn, method, resolved_params, fault, fake
            )
            if is_v29 and transport_used:
                raise AssertionError("V-29 used transport when daemon is absent")
            if is_v30 and conn == "client" and transport_used:
                raise AssertionError(
                    "V-30 refused client call still sent a transport frame"
                )
            ad_closed = reply.get("refused_by_adapter") is True
            check_expect(expect, reply, fake, ad_closed, conn, vars_map, gated)

            if reply.get("ok") is True:
                for cap_name, cap_path in (step.get("capture") or {}).items():
                    found, captured = path_get(reply.get("result"), cap_path)
                    if not found:
                        raise AssertionError(f"capture {cap_name}: missing {cap_path}")
                    vars_map[cap_name] = copy.deepcopy(captured)
        except Exception as exc:  # noqa: BLE001
            return {
                "id": vid,
                "status": "fail",
                "failure_step": step_idx,
                "failure": str(exc),
            }

    if is_v30:
        assert fake is not None
        if "client" in fake.connections:
            return {
                "id": vid,
                "status": "fail",
                "failure_step": 0,
                "failure": "V-30 refused adapter call opened a client connection on the daemon",
            }
        if any(
            r
            for r in fake.requests
            if r["method"] not in ("daemon.negotiate", "daemon.status")
        ):
            return {
                "id": vid,
                "status": "fail",
                "failure_step": 0,
                "failure": "V-30 unexpected request observed on daemon",
            }

    return {"id": vid, "status": "pass", "driver": DRIVER_LABEL}


def select_lua_interpreter() -> str:
    res = subprocess.run(
        ["bash", str(TEST_GATE_SCRIPT), "--print-selection"],
        cwd=str(REPO_ROOT),
        check=True,
        capture_output=True,
        text=True,
    )
    selected = res.stdout.strip()
    if not selected or selected == "none":
        raise RuntimeError(
            "bittyd conformance runner requires lua5.1, luajit, or lua on PATH"
        )
    return selected


def verify_pin_and_load_corpus() -> tuple[dict[str, Any], dict[str, Any]]:
    pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
    if pin.get("schema") != PIN_SCHEMA:
        raise RuntimeError(f"unexpected pin schema: {pin.get('schema')!r}")
    raw_bytes = CORPUS_PATH.read_bytes()
    digest = hashlib.sha256(raw_bytes).hexdigest()
    if digest != pin.get("sha256"):
        raise RuntimeError(
            f"corpus SHA-256 mismatch: expected {pin.get('sha256')}, observed {digest}"
        )
    corpus = json.loads(raw_bytes.decode("utf-8"))
    if corpus.get("schema") != CORPUS_SCHEMA:
        raise RuntimeError(f"unexpected corpus schema: {corpus.get('schema')!r}")
    frozen = corpus.get("frozen") or {}
    if frozen.get("session.attach.request_role") != "attach_role":
        raise RuntimeError("corpus must freeze session.attach.request_role=attach_role")
    vectors = corpus.get("vectors") or []
    counts = pin.get("vector_counts") or {}
    if len(vectors) != int(counts.get("total", -1)):
        raise RuntimeError(
            f"vector total {len(vectors)} != pinned {counts.get('total')}"
        )
    seen_ids: set[str] = set()
    for vec in vectors:
        vid = vec["id"]
        if vid in seen_ids:
            raise RuntimeError(f"duplicate vector id {vid}")
        seen_ids.add(vid)
    return corpus, counts


def main() -> int:
    corpus, pin_counts = verify_pin_and_load_corpus()
    interpreter = select_lua_interpreter()

    # Run the standalone Lua adapter unit suite first.
    subprocess.run(
        [interpreter, str(REPO_ROOT / "tests" / "test_bittyd_adapter.lua")],
        cwd=str(REPO_ROOT),
        check=True,
    )

    temp_root = Path(tempfile.gettempdir()).resolve()
    cwd_seed = str(temp_root)

    bridge = LuaAdapterBridge(interpreter)
    try:
        outcomes = [run_vector(vec, bridge, cwd_seed) for vec in corpus["vectors"]]
    finally:
        bridge.close()

    passed = [o for o in outcomes if o["status"] == "pass"]
    skipped = [o for o in outcomes if o["status"] == "skip"]
    failed = [o for o in outcomes if o["status"] == "fail"]

    for failure in failed:
        print(
            f"[FAIL] {failure['id']} at step {failure['failure_step']}: {failure['failure']}",
            file=sys.stderr,
        )
    if failed:
        return 1

    # Verify exact expected partition: 51 passed (including V-29, V-30, V-33), 32 typed skips.
    passed_ids = {o["id"] for o in passed}
    for required_id in ("V-29", "V-30", "V-31", "V-32", "V-33", "V-34"):
        if required_id not in passed_ids:
            print(
                f"[FAIL] required adapter vector {required_id} did not pass",
                file=sys.stderr,
            )
            return 1

    for sk in skipped:
        reason = sk.get("skip_reason")
        if not isinstance(reason, str) or not reason.strip():
            print(
                f"[FAIL] skipped vector {sk['id']} has no typed skip_reason",
                file=sys.stderr,
            )
            return 1

    if len(passed) != int(pin_counts.get("adapter_executable", 51)) or len(
        skipped
    ) != int(pin_counts.get("adapter_skipped", 32)):
        print(
            f"[FAIL] unexpected vector counts: passed={len(passed)}, skipped={len(skipped)}",
            file=sys.stderr,
        )
        return 1

    print(
        f"[PASS] bittyd_conformance ({DRIVER_LABEL}): "
        f"{len(passed)} passed (V-29, V-30, V-33 verified), {len(skipped)} typed skips, 0 failed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

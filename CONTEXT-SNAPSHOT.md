# WheelContext snapshots

Status: implemented in the Wheel harness. This document describes the
in-memory snapshot contract; it is not a release note and does not claim daemon
transport support.

## Purpose and scope

`WheelContext` models shared context as slots, a Merkle tree, commits, refs, a
reflog, and an event bus. A snapshot is a versioned, deterministic, plain Lua
table that captures enough of that state to reconstruct a working context in a
new process or session.

The snapshot layer performs no file I/O, logging, or transport. The caller owns
persistence, storage permissions, and any later wire encoding.

## Public API

```lua
local WheelContext = require("wheel.context")

local snapshot, err = context:export_snapshot()
local valid, validation_err = WheelContext.validate_snapshot(snapshot)
local restored, import_err = WheelContext.import_snapshot(snapshot, opts)
local bytes, encode_err = WheelContext.canonical_snapshot(snapshot)
```

- `context:export_snapshot(opts)` returns a deep, caller-owned snapshot table.
  `opts` is reserved and must be a table when provided. The method returns
  `nil, typed_error` when the live state is not representable (for example an
  oversized snapshot or a commit graph with a missing parent).
- `WheelContext.validate_snapshot(snapshot)` returns `true`, or
  `nil, typed_error`. It never constructs a context.
- `WheelContext.import_snapshot(snapshot, opts)` validates and deep-copies the
  snapshot before constructing a new `WheelContext`. It never mutates the
  snapshot table and never exposes a partially populated object. `opts` are the
  normal `WheelContext.new` options (`kernel`, `config`, `bus`, and budget
  overrides); they are local policy and are not read from the snapshot. When
  `opts.bus` is supplied, the snapshot bus history replaces that bus's existing
  history and its subscribers are retained; the provided bus is the only
  caller-owned object import mutates.
- `WheelContext.canonical_snapshot(snapshot)` validates the snapshot and returns
  canonical bytes for deterministic comparison. The bytes are not a stable wire
  format; a future transport must version its own encoding.

Snapshot validation failures use the `wheel.errors` bridge shape with class
`validation` and code `E_SNAPSHOT_INVALID`. Invalid `opts` are argument failures
and use `E_ARGS_INVALID`. The message is a bounded, single-line schema path and
reason. Schema paths may name caller-provided slot, ref, or event keys; slot
content is never included.

## Format version 1

The top-level fields are all required and are the only accepted fields:

| Field         | Shape                                                                |
| ------------- | -------------------------------------------------------------------- |
| `format`      | Exact string `wheel-context-snapshot/1`.                             |
| `version`     | Number `1`.                                                          |
| `slots`       | Map of slot name to a slot record.                                   |
| `tree_hash`   | 64-character lowercase hexadecimal Merkle root of the working slots. |
| `head`        | `refs/heads/<branch>` or a detached 64-hex commit hash.              |
| `refs`        | Map of `refs/heads/<branch>` to a commit hash.                       |
| `commits`     | Map of commit hash to a commit record.                               |
| `reflog`      | Dense array of reflog records in chronological order.                |
| `bus_history` | Dense array of recent event tables in chronological order.           |

A slot record has exactly `name`, `content`, `hash`, `version`, `kind`,
`size_bytes`, and `updated_at_ms`. The map key must equal `name`; names are at
most 256 bytes; `hash` must be the SHA-256 of `content`; `size_bytes` must equal
the content length; `version` is an integer from 1 to 2147483647; `kind` must be
one of the known slot kinds and must match the name's prefix.

A commit record has exactly `hash`, `tree_hash`, `slots`, `parent_hashes`,
`author`, `message`, and `timestamp_ms`, plus optional `task_id` and
`rationale`. The map key must equal `hash`; the tree hash must match the
commit's slot map; the commit hash must match the existing `commit:v1` preimage;
and every parent hash must name another commit in the same snapshot. `rationale`
must be plain data (the same depth, node, string, and key bounds as events).

A reflog record has exactly `index`, `from_hash`, `to_hash`, `ref`, `action`,
`message`, and `timestamp_ms`. Reflog indexes are strictly increasing integers
from 1 to 2147483647. The `from_hash` and `to_hash` endpoints may be `(empty)`,
`(initial)`, a branch ref, or a commit hash present in `commits`. The `ref` is a
branch ref, `(detached)`, or a commit hash when a commit moved HEAD while
detached.

An event record is any plain-data table with a finite `timestamp_ms`; a `type`
field, when present, must be a string. Map keys are limited to 256 bytes. Events
are preserved as audit history, not replayed. `stash_pushed` and `stash_popped`
events are normalized to bounded metadata (`id`, `message`, `head_hash`,
`branch`, `timestamp_ms`, and `redacted = true`); their `stash.slots` map is
removed by validation on export, import, and canonical encoding. Optional
metadata on a normal stash event that is not a bounded string or valid
timestamp is omitted rather than stringified or rejected. An event that exposes
its stash fields only through `__pairs`/`__index` is sanitized after plain-data
copying; an over-bound optional field exposed that way may still fail closed on
the plain-data bounds before sanitization. In every case an unredacted event
cannot carry stash content through a snapshot.

`head` may name a branch ref that has no commit yet (an unborn branch, including
a force-deleted active branch). That is a valid context state; the snapshot does
not synthesize a commit for it.

## Canonical encoding

Lua map iteration order is undefined. `canonical_snapshot` encodes a validated
snapshot as follows:

- map keys are sorted bytewise;
- strings are escaped to printable ASCII (`\n`, `\r`, `\t`, `\\`, `\"`, and
  `\xNN` for other non-printable bytes);
- arrays preserve their order;
- numbers use a fixed representation.

Two snapshots with the same state therefore produce identical canonical bytes
regardless of insertion order. `export(import(export(x)))` is table- and
byte-stable for every accepted snapshot.

## Bounds and validation

Validation fails closed before constructing a context. The accepted bounds are:

- slot names: 256 bytes; slot content: 16 MiB per slot; slot versions: 1 to
  2147483647;
- total snapshot: 64 MiB of logical payload and structure;
- slots: 4096 per map, 65536 slot entries across the working tree and commits;
- commits: 4096, with at most 64 parents per commit;
- refs: 256 entries, each branch name at most 256 bytes;
- reflog: 256 records, each index 1 to 2147483647 and strictly increasing, each
  action at most 64 bytes;
- bus history: 64 events;
- metadata strings (author, message, task ID, rationale strings, and event
  string values): 64 KiB per string;
- schema field names: 64 bytes; plain-data map keys: 256 bytes;
- plain-data values: depth 32 and 100000 nodes, counting map keys as nodes.

The producer refuses a slot write when its version reaches the bound
(`version_exhausted`) and deterministically renumbers a retained reflog when its
index reaches the reflog bound, so a bounded context remains exportable.

Validation rejects:

- unknown `format` or `version`, missing required fields, and unknown fields;
- invalid slot names, kinds, versions, sizes, hashes, or timestamps;
- inconsistent working-tree or commit tree hashes;
- non-64-hex or uppercase hashes;
- malformed branch refs, refs to unknown commits, and malformed heads;
- commit hashes that do not match their preimage, unknown commit parents, and
  commit parent cycles;
- reflog endpoints that name unknown commits or malformed refs;
- non-plain event payloads (functions, threads, userdata), cycles, over-bound
  keys, or over-bound history.

A snapshot whose commits reference parents outside the snapshot is rejected as
partial. The live context must have a closed commit graph before export; there is
no export option that omits commits.

## Integrity limits

Validation detects structural tampering, content-hash mismatches, tree-hash
mismatches, commit-hash mismatches, dangling refs, and commit-graph cycles. It
does not authenticate the snapshot as a whole, and the existing hashes do not
cover every field:

- the tree hash binds slot names, sizes, and content hashes, not slot `version`
  or `updated_at_ms`;
- the commit preimage binds the tree hash, parents, author, task ID, timestamp,
  and message, not `rationale`;
- `head` and `refs` are unauthenticated pointers; a tamperer can redirect either
  to any commit that already exists in the snapshot while every hash remains
  valid;
- reflog entries and bus events have no cryptographic binding.

An attacker who can rewrite a snapshot can therefore alter those unbound fields
while keeping every hash valid. Use an authenticated transport or an external
integrity check if snapshot provenance matters.

## Trust boundary and storage

Snapshot content is caller-owned sensitive data. Slot content can contain source
code, workspace paths, prompts, or secrets. The snapshot adds no host paths or
secret fields of its own, but it faithfully preserves whatever the caller stored.

Callers that persist a snapshot must:

- keep it in private storage (directory and file mode `0600`, owner-only);
- never log it, include it in telemetry, or send it to a provider;
- treat it as untrusted input when reading it back, and pass it through
  `import_snapshot` rather than indexing it directly;
- apply the same redaction policy to slot content that they apply to prompts and
  checkpoints.

## State that is not preserved

Snapshot v1 captures working slots, the tree hash, `HEAD`, refs, commits, the
reflog, and bus history. It deliberately does not capture:

- stash entries (`stash_push`), which are transient working state; their bus
  events are retained with bounded metadata and the slot map removed
  (`stash.redacted = true`), so stash content cannot bypass this exclusion
  through export, import, or canonical encoding;
- bus subscribers and callbacks; a caller-supplied import bus keeps its existing
  subscribers, but snapshot subscribers are not recreated;
- the `kernel` link;
- the `config` table/directives and local budget configuration
  (`max_budget_bytes`, zone limits); pass `config` and budget overrides as
  import options or accept the defaults;
- cached derived values beyond the tree hash.

Restoring a snapshot into a context with a different kernel, configuration, or
budget policy is supported; the caller owns that policy decision.

## Daemon integration

The session daemon does not consume this API yet. A follow-up task owns the
transport, storage location, lifecycle, and protocol versioning. Until then,
this module is an in-memory primitive with unit evidence only.

## Autonomous runner history

`WheelRunner` applies a separate bounded conversation policy before each
provider request. The named defaults are 48 KiB of message history, 10 turns,
four retained recent turns, a 12 KiB `ContextRef`, eight structured evidence
items, and 2 KiB per raw-evidence preview. When a byte or turn bound is
reached, older messages are replaced by a deterministic `ContextRef` stored at
`tasks/<task-id>/context_ref` and committed through the existing
`WheelContext:commit_checkpoint` API. Complete assistant/tool observation pairs
remain together; an unfinished tool call is retained rather than dropped.

The retained state records tool-call identities, failures, decisions, evidence,
risks, and next actions. Large tool output remains addressable through the
existing bounded action `blob_hash`/preview representation instead of being
copied into the provider request. The runner sends the compiler's Zone 1 as
the system prefix and Zone 2/3 as the dynamic tail, so tail-only compaction does
not change the stable prefix bytes.

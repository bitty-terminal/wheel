# Changelog

All notable changes to Bitty Wheel (`bitty-terminal.wheel`) are recorded
here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Opt-in OpenRouter caller attribution (CTX-0032 / wheel#102):
  `OpenAIAdapter.new` accepts an optional `attribution` block (`referer`,
  `title`, optional `categories`, and `visibility = "hidden"`) and sends
  `HTTP-Referer`, `X-OpenRouter-Title`, `X-OpenRouter-Categories`, and
  `X-OpenRouter-App-Visibility` only when configured. `WheelProvider.create`
  forwards it for the `openai` and `deepseek` routes. An absent block sends no
  identity headers, and no product URL, title, or category is defaulted.
  Values are validated fail-closed (absolute `http`/`https` referer without
  userinfo, printable ASCII, bounded lengths, plain table, known fields) with
  the typed `E_ARGS_INVALID` code before any HTTP request; caller header maps
  cannot inject or override adapter-owned headers. `ATTRIBUTION.md` records
  the identity/title/icon relationship and the deferred
  `https://wheel.bitty.run` switch. No OpenRouter application is created, and
  the broader attribution decision remains open.
- Local append-only execution audit stream (CTX-0030 / wheel#98):
  `lua/wheel/audit.lua` writes one JSON object per line under
  `$XDG_STATE_HOME/wheel/audit/` (fallback
  `$HOME/.local/state/wheel/audit/`), repairs the directory to `0700`, keeps
  every record file an owned `0600` regular file, bounds records at 16 KiB,
  rotates at 1 MiB with four retained files, and carries a monotonic sequence
  plus a SHA-256 previous-hash chain. Command previews, argv, metadata, and
  reasons are redacted with stable `[redacted:<SHA-256 prefix>]` markers;
  prompts, output, environment values, file contents, provider responses, and
  authorization header values are never record fields. `WheelHost.proc`
  accepts an optional `opts.audit` table and writes pre-spawn and completion
  records; a `deny` decision never launches, and a high-risk spawn whose
  pre-spawn record cannot be written returns the typed `E_AUDIT_UNAVAILABLE`
  failure without spawning. Lower-risk failures continue with a visible
  `result.audit_warning`. `just test-audit` covers append, rotation, private
  modes, chain, redaction, bounds, fail-closed, and warning behavior; the
  real-host fixture reads the JSONL after a real permitted and denied command.
  Review hardening consumes the complete Authorization and Proxy-Authorization
  value for Token/ApiKey/SSWS/Digest/AWS4 and quoted/JSON forms, including
  shell-escaped JSON keys/values (ambiguous escaped values are over-redacted
  through the end of the preview), and replaces complete quoted or unquoted
  values for authorization environment assignments and flags, including
  escaped inner quotes. It also refuses
  an unsafe active audit file (symlink or weak mode), rejects `opts.audit` with
  an injected `command_runner`, reports `spawned = false` on a high-risk
  refusal, and documents that only a torn/corrupt tail blocks append while
  `WheelAudit.verify` scans earlier corruption. The sink is intentionally
  opt-in in this slice: tool and trust call sites do not yet supply audit
  metadata, and default-on wiring plus cross-process append serialization
  remain follow-ups.
- Offline Gate 2 provider-stub evidence (CTX-0029 / wheel#95): `just
test-provider-stub` starts a real `ThreadingHTTPServer` on `127.0.0.1:0`
  (`tests/provider_stub.py`), performs one completion through the real
  `OpenAIAdapter` and a test-only Python `http.client` transport
  (`tests/provider_stub_client.py`), and audits stdout, stderr, errors, the
  adapter description, request/response captures, and every file the run
  creates for the fixed synthetic key. A wrong key returns 401 and a missing
  key fails before any request; non-loopback destinations, userinfo, other
  paths, and other methods are refused locally. The key reaches only child
  environments through an anonymous `sh -s` pipe, never argv or a request file,
  and the stub records only path, method, status, and authorization
  presence/validity. Review hardening adds static transport diagnostics that
  report only the exception type (`http.client` embeds rejected header values
  in its `ValueError` message), a CRLF-key regression, an ambient-value
  missing-key probe backed by an explicit `unset`, a key-bearing-argv guard
  before `argparse`, missing-authorization 401, query/fragment and redirect
  refusal, a graceful SIGTERM shutdown marker, and a non-vacuous `/proc`
  cmdline check. The gate is part of `just check` and CI; audit output,
  asynchronous cancellation, and panel presentation remain open Gate 2 items
  (`SECURITY-MODEL.md`, `tests/PROVIDER-STUB.md`).
- Experimental local session daemon (CTX-0024 / wheel#85): a detached per-user
  process owns one `WheelContext` and serves the bounded `wheel-session/1`
  control plane over private POSIX FIFOs. `scripts/wheel-session` starts, probes,
  inspects, snapshots, updates context, and stops it; requests are serialized by
  a per-session client lock and stale-lock reclamation by a per-lock mutex,
  metadata and FIFOs are user-owned `0600` inside a `0700` runtime directory,
  frames are bounded at 64 KiB/1 MiB, snapshots omit slot content, and shutdown
  is explicit. `just test-session` starts a real daemon and covers cross-process
  context persistence, CAS conflicts, invalid names, unsafe/symlinked paths,
  oversized frames, stale-pid recovery, and clean shutdown, plus deterministic
  regression tests for concurrent stale-lock reclamation, write failures, and
  cleanup ownership. The same-user FIFO residual (no peer credentials) is
  recorded in `SECURITY-MODEL.md`. Follow-up hardening adds start-lock handoff
  before metadata publication, client-side root revalidation, non-replacing
  lock restore, stale-state pruning, and a 10 KiB worst-case-safe content cap.
- Repository scaffold generated from
  [bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template):
  static manifest (`bitty-plugin.toml`), Lua entry point (`lua/wheel/init.lua`),
  and the CI quality gate.
- Wheel harness implementation under `lua/wheel/`: kernel dispatch, hierarchical
  configuration, agent runtime, team orchestration, Git-inspired context
  versioning, tool execution engine, model provider adapters, execution runner,
  and UI visualizer, with unit and cross-process test suites.
- Repository governance: `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  CarryCtx baseline (`.carryctx/config.toml`), and the Wheel/Bittie naming
  record (bitty-ai-docs `DEC-0003`).
- Typed command failure boundary (`lua/wheel/errors.lua`): sandbox denials
  surface as the accepted `runtime` / `E_CAPABILITY_DENIED` error table with a
  bounded message naming the missing capability, and unexpected handler
  failures stay distinguishable as a Wheel-local `E_INTERNAL` error.
- Wheel Coding-Agent scope and Non-goals recorded in `README.md` and
  `AGENTS.md` (owner-approved scope).
- `SECURITY-MODEL.md`: the 0.1.0 authority policy for workspace read/write,
  arbitrary argv, shell command strings, network egress, and secret environment
  reads, including the path sandbox, role gates, command deny-list, audit and
  redaction rules, executable project-config trust gate, trust boundary,
  residual risks, and the mock/unit plus real host fixture evidence gates.
- Explicit OQ-068 divergence record for executable `.wheel/init.lua`, scoped to
  the Wheel harness and bounded by the trust gate.
- Bounded command schemas (`lua/wheel/schema.lua`): all 14 commands declare a
  closed `args_schema` and `result_schema` in one lazy command table.
  Registration rejects unsupported or unbounded schemas with `E_SCHEMA_INVALID`,
  invocation arguments are validated before dispatch with `E_ARGS_INVALID`, and
  handlers return the bounded `{ title, body }` notification projection. The
  result body (8000 bytes) and title (64 bytes) fit the host bridge's 8 KiB
  `DEFAULT_MAX_VALUE_BYTES`, and oversized bodies are truncated at a UTF-8
  boundary. The transitional manifest is unchanged.
- Real-host activation and command-smoke fixture (`tests/real_host_fixture.lua`,
  opt-in `just test-real-host`) for the standalone Option B harness. It creates
  an ephemeral base and workspace, sets private `XDG_RUNTIME_DIR`,
  `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and `HOME` before requiring Wheel, and
  selects the standalone POSIX backend explicitly. The only host double is the
  presentation table `bitty` (`commands.register`, `notify.show`); it is not an
  fs/process/temp/time mock, and no plugin VM or loader runs. The fixture
  asserts the exact 14 registrations and eager/lazy split, `hello` notification
  behavior, real filesystem/process/temporary-file/tool paths, path-escape and
  destructive-command denials, read-only role gating, and typed backend
  denials. Cold and warm activation are measured against RC-1 (10^7
  instructions, 50 ms CPU, 8 ms warning) with the series, interpreter, CPU, OS,
  and revision recorded in gitignored `recording/real-host-2026-10-21.md`.
  This is implementation evidence only, not a release claim or full Gate 2
  evidence; CTX-0016 later added the process timeout, process-group, and
  scrubbed-environment bounds, while asynchronous cancellation remains open.
- Versioned 0.1.0 harness artifact (CTX-0018 / wheel#58): the root `VERSION`
  file is the single version source, and `just package` builds the deterministic
  `dist/wheel-0.1.0.tar.gz` with a SHA-256 sidecar and a manifest record. The
  archive contains `lua/`, `LICENSE`, `README.md`, `SECURITY-MODEL.md`,
  `CONTEXT-SNAPSHOT.md`, `repo.toml`, and `VERSION`, and excludes tests,
  recording, dependencies, Git metadata, CI, scripts, the justfile, and
  `dist/`. The release build refuses a dirty worktree, a missing input, or an
  unsupported version; `--allow-dirty` and `--version` are local test-build
  options only.
- Local install, upgrade, and rollback path (`just install-local`,
  `just rollback-local`): installed versions live at
  `<prefix>/wheel/<version>/`, `current` is a relative symlink, and the outgoing
  version is recorded in `previous`. The offline installer verifies the digest,
  rejects absolute/traversal/symlinked archive members, refuses `/`,
  trailing-slash, `..`, symlinked, and non-owned prefixes, extracts into
  staging, and switches `current` atomically. There is no `eval`, no
  archive-supplied shell string, and no post-install script.
- `just verify-package` builds the release artifact twice to prove determinism,
  installs it into a temporary prefix, runs the real-host fixture against the
  installed tree, upgrades to a locally built 0.1.1, rolls back, and exercises
  the refusal paths. CI runs it after `just test-real-host`.
- The real-host fixture accepts `WHEEL_ROOT` to test an installed artifact tree
  and `WHEEL_EVIDENCE_PATH` to keep evidence out of the repository. It asserts
  that loaded modules resolved from `WHEEL_ROOT`; the real-host boundary and
  measurements are unchanged.
- Bounded process primitive (CTX-0016 / wheel#74): `WheelHost.proc.run_program`
  and `WheelHost.proc.run_command` run under a `setsid -w` session leader and
  GNU `timeout` (or `gtimeout`) with a recorded process group, bounded
  SIGTERM-to-SIGKILL escalation, a post-exit TERM/KILL group sweep, a fixed
  256 KiB capture cap per stream read back from exclusive `0600` files, and an
  explicit stdin channel (`opts.stdin`; `/dev/null` by default). Results
  carry `exit_code`, `timed_out`, `truncated`, per-stream truncation flags, and
  a typed `outcome` (`exited`/`timeout`/`unavailable`/`failure`). The child
  environment is rebuilt from a fixed allowlist (`PATH`, `HOME`, `LANG`,
  `LC_ALL`, `TERM`, `TMPDIR`, `XDG_RUNTIME_DIR`, `XDG_STATE_HOME`,
  `XDG_CONFIG_HOME`) plus explicit declarations; `PATH` must contain absolute
  entries and secret-shaped or injection names are refused. The new
  `WheelHost.tmp.create` / `create_exclusive` primitives create files
  exclusively with mode 0600 and refuse pre-existing paths and symlinks.
- Offline benchmark suite (CTX-0025 / wheel#86): `bench/` measures cold and warm
  entry-point activation (CPU plus separate instrumented instruction counts),
  `WheelHost.proc.run_program` normal exit and timeout at 1/5/20 calls,
  `WheelRunner.run_task` mock-provider turns at 1/5/10, mock-team orchestration
  at 1/5/10 tasks, and context slot write/read plus Three-Zone compilation at
  10/100/1,000 slots. `just bench` and `just bench-json` run the full manual
  suite; `just bench-release-smoke` is a short bounded subset with generous
  regression ceilings. Results record revision, interpreter, CPU/OS/kernel,
  pinning, cardinality, sample count, and min/median/p95/max/IQR, with no host
  paths or committed host baseline. `just check` now runs the benchmark unit
  tests and one short context-scenario run.
- Versioned `WheelContext` snapshots (CTX-0026 / wheel#87):
  `WheelContext:export_snapshot`, `WheelContext.import_snapshot`,
  `WheelContext.validate_snapshot`, and `WheelContext.canonical_snapshot`
  export and restore working slots, the Merkle `tree_hash`, `HEAD`, refs,
  commits, the bounded reflog, and the bounded bus history. Restore validates
  the `wheel-context-snapshot/1` format, required and unknown fields, slot
  names/kinds/content hashes, slot-version and reflog-index maxima, 16 MiB
  content and 64 MiB total bounds, bounded keys, 64-hex hashes, tree-hash and
  commit-hash consistency, branch refs, commit-parent closure and cycles, and
  reflog references before constructing an object. Reflog indexes advance from
  the last retained index across the ring; an exhausted index is renumbered
  deterministically, and a slot at its version bound fails with
  `version_exhausted` instead of overflowing. Snapshot validation failures use
  the typed `E_SNAPSHOT_INVALID` cause; invalid options use `E_ARGS_INVALID`.
  Import deep-copies the snapshot and never exposes a partial context. Stash
  slot payloads are redacted from preserved `stash_pushed`/`stash_popped` bus
  events; a caller-supplied import bus keeps its subscribers but has its history
  replaced by the snapshot history. `canonical_snapshot` provides
  hash-table-order-independent bytes for round-trip comparison. Snapshot v1
  deliberately excludes stash entries, bus subscribers, the kernel link,
  `config` directives, and local budget configuration; daemon transport
  integration remains a follow-up.

### Changed

- `create_branch` publishes its caller-visible 256-byte ref-name bound
  (`WheelContext.MAX_REF_NAME_BYTES`): a longer branch name fails with
  `invalid_branch_name`, a name at exactly 256 bytes remains valid, and the
  same bound applies to snapshot refs so every live branch can be exported.
- Opt-in live provider selector (CTX-0023 / wheel#82):
  `WHEEL_LIVE_PROVIDER=openrouter|commandcode` (default `openrouter`, matched
  case-insensitively) selects the credential environment, host, and completion
  budgets for `just test-live`. Command Code uses `COMMANDCODE_API_KEY` and a
  1024-token budget for its reasoning model; the key-free redirect-policy and
  selector tests remain offline and now run in `just check`.
- CTX-0022 local gate: `just test` selects `lua5.1`, then `luajit`, then `lua`
  through `scripts/test-gate.sh`; `just test-gate` self-tests the selection
  branches, and LuaJIT disables the JIT for the evaluated config chunk so the
  instruction-limit test cannot hang. `tmp_root` normalization collapses
  repeated `/` separators and drops `.` segments before the `.../wheel/tmp`
  symlink guard.
- `StdioAdapter` passes the formatted prompt on stdin through the argv process
  primitive instead of writing a non-exclusive prompt temp file and invoking a
  shell redirection. String commands are tokenized conservatively (quotes only)
  and shell syntax is refused; callers that need shell syntax pass an argv
  table. The provider factory default is now an argv table.
- `search_code` captures at most 64 KiB of `grep` output before the 100-line
  observation cap, `read_file` reads at most `max_bytes + 1` bytes in fixed-size
  chunks instead of loading the whole file, and `run_command` forwards
  `timeout_ms` and reports typed timeout/truncation fields. Native SHA-256
  staging uses the exclusive temp primitive and fails closed if cleanup fails.
- CI installs Lua 5.1 before the quality gates, so `just test` runs the Lua
  suite in CI, runs `just test-real-host` after `just check`, and then runs
  `just verify-package`. The `package.json` version follows the canonical
  `VERSION` file, and `dist/` is ignored.
- The README Install section now documents the artifact contents, digest,
  install/launch, upgrade/rollback, compatibility, and `v0.1.0` release target.
  `SECURITY-MODEL.md` records the install/upgrade trust path and its limits.
- The harness now selects the standalone POSIX backend explicitly through
  `WheelHost.select_backend("standalone")` and fails closed on non-POSIX
  platforms or unknown backends with a typed `E_CAPABILITY_DENIED` error. Every
  filesystem, process, temporary-file, wall-clock, and CPU-time primitive used
  by `lua/wheel` routes through `WheelHost`; no direct `io.open`, `io.popen`,
  `os.remove`, `os.execute`, `os.tmpname`, `os.time`, or `os.clock` call
  remains outside `lua/wheel/host.lua`. Temporary files use a private runtime
  directory with mode 0700, inspect-intent tools pass argv through
  `WheelHost.proc.run_program`, and cwd quoting uses a POSIX single-quote
  helper. The manifest and authority ceiling are unchanged; CTX-0016 later
  completed the process timeout, process-group, and scrubbed-environment
  hardening.
- Repository README reorganized into the uniform SDK user-documentation
  contract: `Overview`, `Install`, `Commands`, `Configuration`, `Keybindings`,
  and `Troubleshooting` lead in order, with the existing developer and
  architecture reference following. The `bitty-plugin-sdk` devDependency moves
  to commit `5a67942` and `just check` now runs the SDK README checker
  (`bitty-plugin-docs-check`) alongside the manifest linter. The transitional
  `bitty-plugin.toml` and its `[settings]`-free surface are unchanged.
- Product position recorded (owner decisions D1-D7, wheel#51, 2026-10-20):
  Wheel is an independent out-of-process harness that holds execution
  authority, ships a single artifact for 0.1.0, and drops plugin packaging and
  `compat.plugin-api`. `repo.toml`, `README.md`, `AGENTS.md`, `SECURITY.md`,
  and `CONTRIBUTING.md` now describe the harness position. The transitional
  `bitty-plugin.toml` is unchanged and is not the authority model.
- Process, tmp, and wall-clock time operations route through an injectable
  `WheelHost` seam (`lua/wheel/host.lua`); the standalone POSIX backend is the
  production backend for the 0.1.0 harness, and a host ABI adapter is not part
  of the 0.1.0 path. CTX-0015 completes the migration to filesystem, CPU-time,
  and private temporary-file primitives.
- Command handlers now cross the typed failure boundary: `plan`, `trust`, and
  `orchestrate` report missing `env.read`/`fs.read` authority instead of raw
  nil-member failures, and the `trust` command reads project configuration
  through the `WheelHost` seam. The manifest and requested capabilities are
  unchanged.
- Repository repositioned as an independent agent-harness repository: removed
  from the official plugin set (bitty-plugins #98); descriptors, documentation,
  and the GitHub repository description aligned with the independence direction
  (wheel #45). No behavior changes.

### Fixed

- CTX-0028 / wheel#93 snapshot and session hardening: snapshot validation now
  sanitizes `stash_pushed`/`stash_popped` bus events on import and canonical
  encoding as well as export, so a crafted or pre-fix unredacted snapshot
  cannot restore stash slot content; non-string or invalid optional stash
  metadata is omitted instead of failing a live export. Session cleanup leaves
  metadata and FIFOs untouched when metadata is missing or unreadable unless
  the start lock was already self-owned from a failed startup; Lua 5.1 raw
  signal statuses normalize to `128 + signal` and fail the liveness probe
  closed; stale start-lock tails are pruned only while the start-lock mutex is
  held; and `Session.acquire_lock` releases a self-owned lock and mutex after an
  unexpected host exception. The README error table records
  `E_SESSION_START_MISMATCH` and `E_SESSION_UNRESPONSIVE`.
- CTX-0027 concurrent test scratch roots: `tests/test_wheel.lua` now derives one
  private root per run from `WHEEL_TEST_TMP` or `os.tmpname()` and builds every
  filesystem fixture under it, instead of sharing fixed global scratch
  directories. The suite removes only its own root, normalizes Lua 5.1/LuaJIT
  numeric and Lua 5.2+ boolean `os.execute` success, rejects a `WHEEL_TEST_TMP`
  base outside a safe absolute charset or containing a `..` segment before the
  run root is created, and guards the CWD-local relative-root fixture.
  `just test` adds a removable outer base; the cross-process drill uses a
  unique FIFO/database directory, waits for each recorded host process, and
  cleans recorded processes and the directory on failure. `just test-concurrent`
  stops and waits for both suites before removing their scratch tree on an
  interrupt, asserts two distinct roots while both run, and proves they pass
  without deleting each other's files; `just test-roots` proves an unsafe base
  is rejected without deleting a sentinel. Test-only change; no production
  behavior.
- CTX-0021 / wheel#81 process-group identity: the `setsid` session leader is
  now retained through the bounded TERM/grace/KILL sweep, writes the direct
  command's exit status to the private status file before sending any signal,
  and signals only its own recorded PGID, so the PGID cannot be reused while
  the sweep runs. GNU `timeout` now runs with `--foreground`, which signals only
  the direct child on expiry; the leader then sweeps background grandchildren.
  Process results add `cleanup` (`swept`/`unverified`/`not_run`) and the
  recorded `pgid`; if the leader is lost before the sweep, no signal is sent,
  the run fails with `cleanup = unverified`, and the failure says the group was
  not swept. Tests add status preservation with a swept background child, a
  retained-leader liveness check at TERM time, a decoy group that survives, and
  an identity-loss fixture. The accepted "same-user PGID reuse after leader
  exit" residual is removed; a child that calls `setsid` or joins another
  process group still escapes, and an externally killed leader can leave
  descendants unswept (reported, never guessed).
- CTX-0022 typed loader diagnostics: `team`, `context`, and `tool` load
  `wheel.errors` first, clear Lua 5.1 failed-require sentinels, preserve the
  typed `E_CAPABILITY_DENIED` class/code and rooted cause, keep present-but-
  broken module causes, and restore the alternate `lua.wheel.errors` root.
- CTX-0016 final security pass: temp files use `mktemp` plus 0600 regular-file
  ownership/link validation, exact paths are committed with a hard link, and
  FIFO/symlink-to-device/pre-existing paths are refused; the PGID file is
  validated and the group checked before signals (same-user PGID reuse remains
  an accepted residual); `read_file` marks a prefix ending inside an included
  line as truncated. `list_directory` reports capture truncation. Tests add
  FIFO/symlink-to-/dev/null refusal, partial-line read, missing sleep/timeout,
  `=` program rejection, pagination, and truncation flags.
- CTX-0016 second security pass: a `setsid`-recorded supervisor now sweeps the
  process group with bounded TERM/KILL after normal completion, so a
  backgrounded grandchild cannot outlive the tool call; `env --` prevents a
  program named `-S`/`-i` from being parsed as an env option; `read_file` fails
  loud when `start_line` is beyond the bounded prefix; `search_code` and
  `list_directory` fail closed on nonzero `grep`/`ls`/timeout instead of
  returning success with diagnostic text; `StdioAdapter` retains stderr
  diagnostics; and temp write-cleanup failures are surfaced. Tests add the
  normal-exit sweep, TERM-ignoring KILL, `env -S`/`-i`, read/list/search
  failures, 1 MiB stdin, spawn-failure cleanup, capture-file 0600, and
  cleanup-failure typing. Setsid/timeout/sleep unavailability is a typed
  `unavailable` outcome. A grandchild that calls `setsid` itself still escapes.
- CTX-0015 review findings for CTX-0016 / wheel#74: the stdio prompt path no
  longer creates a non-exclusive file through `WheelHost.fs.write_file`, so it
  cannot follow a pre-existing link or leave an ignored cleanup failure; the
  prompt travels on stdin and every staged/capture file is created exclusively
  with mode 0600 in the private 0700 directory and removed fail-closed.
  `search_code` no longer captures unbounded `grep` output before keeping 100
  lines, and `read_file` no longer loads the whole file before applying
  `max_bytes`. Tests cover timeout, timeout process-group cleanup with a
  grandchild, normal-exit background-child cleanup, TERM-ignoring KILL
  escalation, environment scrubbing, stdin round-trip, output truncation,
  bounded file reads, symlink/pre-existing-path refusal, and cleanup on
  success, error, and timeout.
- Executable project-configuration trust gate hardened for CTX-0019 /
  wheel#54 (CTX-0020, including PX-0112 fixes). `trust`/`trust show` resolves
  the canonical project root through the host, refuses symlinked, non-regular,
  and larger-than-32-KiB entries before hashing, and shows the full entry under
  a per-run nonce delimiter with every line escaped and prefixed, a pure-Lua
  line diff against the previously trusted bytes, the full 64-hex SHA-256, and
  a statement that effects are evaluated only after confirmation. The returned
  result is a bounded consent summary; the full view is the notification
  series. `trust confirm <sha256>` requires the exact current hash;
  `trust revoke [path]` is user-facing and removes the canonical record plus
  aliases.
  The trust store has no `/tmp` fallback, is created `0700`/`0600` with atomic
  temp-plus-rename, checks ownership and group/world-writable modes, surfaces
  corruption instead of returning an empty store, enforces matching read/write
  caps, preserves temporarily unresolvable records, and uses schema version 1
  with hash, content, and approval time (legacy string hashes migrate on the
  next approval). Confirmation repairs a user-owned group/world-writable
  parent directory to `0700` and re-reads the store before writing, while
  foreign, symlinked, and non-directory parents remain fatal. SHA-256 of the
  exact entry bytes uses
  `sha256sum`/`shasum`/`openssl` with the pure-Lua fallback. The evaluator no
  longer exposes `pcall`/`xpcall`; direct and method-call forms of
  `string.rep`/`table.concat` carry per-call and cumulative caps by patching
  and restoring the real tables. Host file writes now check write/close errors
  and bounded reads return an error instead of a false empty string. The 14
  command ids and the standalone authority boundary are unchanged; process
  timeout, true wall-clock/heap limits, audit fail-closed approval, and field
  validation remain open.

- Packaging normalizes generated file modes independently of the caller's
  umask (the artifact `VERSION` was previously 0644 under 022 and 0600 under
  077, changing the digest). The verifier now rebuilds under both umasks and
  compares the archive, sidecar, and manifest byte-for-byte.
- Packaging copies only Git-tracked files under `lua/`, so ignored or
  untracked files (for example an ignored `lua/wheel/agent.luac`) cannot enter
  the release archive. The manifest now records `source_revision` (full HEAD
  for clean builds, `null` for `--allow-dirty` test builds), and the verifier
  asserts both the ignored-file exclusion and the recorded revision.
- CTX-0015 review fixes: `WheelHost.tmp_path` no longer reads wall-clock time or
  substitutes a `"0"` stamp (uniqueness is process-local; exclusive creation
  was completed by CTX-0016), and `tmp_dir` normalizes trailing separators,
  rejects the filesystem root and any all-dots segment (`.`, `..`, `...`, ...),
  and rejects a symlinked harness-owned temporary directory before `chmod` can
  follow it. A non-string `tmp_root` fails with the same typed denial.
  `read_file` reports `total_lines` as the emitted line count and `search_code`
  keeps the previous trailing newline. Typed platform denials now survive the
  config/tool/provider host loaders, and a repeated lazy host access keeps the
  original cause instead of the Lua 5.1 failed-require sentinel. Full-output
  capture before the 100-line bound, whole-file reads before `max_bytes`, and
  exclusive `0600` temporary-file creation were fixed in CTX-0016 / wheel#74.
- Entry-point activation now loads only the required registration and status
  surface (typed errors, command schemas, command layer, kernel, and UI).
  `agent`, `config`, `team`, `context`, `tool`, `provider`, `runner`, and `host`
  load on first use through one lazy accessor, and `wheel.tools` shares the
  default registry with the `tools` command. A submodule that cannot load now
  raises the typed `resolution` / `E_MODULE_LOAD_FAILED` table naming the rooted
  module and a bounded, path-free cause instead of falling through to a bare
  `require`. Under the CTX-0008 workload the eager payload drops from 269,708
  bytes / 3.19 ms to 95,377 bytes / 1.34 ms (lua5.1 warm median); the
  instruction count remains far below RC-1 (see
  `recording/activation-budget.md`).
- Provider requests now carry an explicit completion `max_tokens` bound
  (`WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS`, 4096) on the OpenAI-compatible
  and Anthropic HTTP `complete` and `stream` paths, including every runner
  turn. A request or model-profile `max_completion_tokens` override is validated
  as a positive integer no larger than `WheelProvider.MAX_COMPLETION_TOKENS`
  (32768); invalid values fail with typed `E_COMPLETION_BUDGET_INVALID` before
  an HTTP request is sent. The context-window budget remains separate. This
  prevents providers such as OpenRouter from assuming a model's maximum
  completion window for credit checks and returning HTTP 402 on a low-balance
  key.
- Added the opt-in `just test-live` target: a manual OpenRouter smoke test for
  complete, tool call, SSE stream, and one runner ReAct turn. It is absent from
  `just check` and CI, skips the live portion cleanly without
  `OPENROUTER_API_KEY`, and uses a test-only stdlib helper that reads the key
  from its inherited environment.
- The live-test HTTP helper now refuses every redirect before a second hop, so
  the authorization header is never forwarded to another host or downgraded to
  plaintext HTTP. A key-free loopback test covers cross-host and scheme-change
  302 responses and asserts that no target request or Authorization header is
  sent.

# Changelog

All notable changes to Bitty Wheel (`bitty-terminal.wheel`) are recorded
here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
  `repo.toml`, and `VERSION`, and excludes tests, recording, dependencies, Git
  metadata, CI, scripts, the justfile, and `dist/`. The release build refuses a
  dirty worktree, a missing input, or an unsupported version; `--allow-dirty`
  and `--version` are local test-build options only.
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

### Changed

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

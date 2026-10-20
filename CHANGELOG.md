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

### Changed

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
  of the 0.1.0 path. Several file and configuration paths still call `io.open`
  directly, and CPU time (`os.clock`) is still read directly; the seam does not
  yet cover them (recorded in `SECURITY-MODEL.md`). No user-visible behavior
  change.
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

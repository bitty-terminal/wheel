# Wheel

Wheel — the agent harness for the Bitty terminal (mascot: Bittie the hamster). Independent out-of-process harness for the 0.1.0 window.

This repository began as a
[bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template)
scaffold and now carries the Wheel harness implementation under `lua/wheel/`,
its unit and cross-process test suites, and the CI quality gates. The owner
decision of 2026-10-20 (wheel#51) positions Wheel as an independent harness
process rather than a Bitty plugin: the harness holds execution authority, a
Bitty panel or terminal supplies only presentation and input, and plugin
packaging is not part of the 0.1.0 deliverable.

> Status: pre-release. The harness implementation lives in `lua/wheel/` with
> unit and cross-process test suites. No harness artifact has been released and
> no released-host integration is claimed. The 0.1.0 scope is a **single harness
> artifact**: plugin packaging and `compat.plugin-api` are dropped (owner D6).
> Authority and its controls are defined in [SECURITY-MODEL.md](SECURITY-MODEL.md);
> the 0.1.0 ceiling is workspace read/write, arbitrary argv, shell command
> strings, network egress, and secret environment reads, with shell strings and
> secret reads in the higher-risk class. The in-tree `bitty-plugin.toml` is
> retained unchanged by the position record as a transitional artifact and is
> not a supported distribution path.

## Product position

- **Independent harness process (Option B).** Wheel runs as its own OS process
  with the user's authority, constrained by Wheel's policy layer. It does not
  run inside the Bitty plugin VM and receives no plugin capability grant at
  runtime (owner decisions D1/D2).
- **Software-engineering domain only.** The product position does not change
  the task domain, the role model, or the non-goals below.
- **One artifact.** The 0.1.0 deliverable is the harness itself. A thin plugin
  facade may return later only if a host-brokered execution service is accepted
  (owner D6).
- **Optional Bitty integration.** Running in a Bitty panel or terminal is
  presentation, not authority. An optional host IPC client for host-visible
  operations is a post-decision follow-up, not a 0.1.0 claim.
- **Policy before code.** [SECURITY-MODEL.md](SECURITY-MODEL.md) owns the
  authority policy, path and role gates, command deny-list, audit, secret
  handling, executable project-config gate, and evidence gates. No capability
  widens without an independent security review plus mock/unit and real host
  fixture evidence (owner D7).

## Scope

Wheel is the agent harness for the Bitty terminal, scoped to software
engineering only: its task domain is always software development. It
may support multi-agent, multi-role, multi-model, and multi-workspace/panel
operation within that domain. Roles (Primary, Commander, Coding, Debug,
Research, Reviewer) vary by configuration, never by class explosion. The staged
MVP direction is a single Primary Coding Agent, then Primary plus Subagents,
then a Commander.

### Non-goals

Wheel is not intended to be:

- a personal AI assistant
- a general-purpose autonomous agent
- a messaging gateway
- an email/calendar assistant
- a home automation agent
- a lifelong user-memory system
- a cron/automation daemon
- a general cloud-management agent

Wheel is focused on software engineering workflows.

## Layout

| Path                          | Purpose                                                                                                                                                                                                             |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bitty-plugin.toml`           | Transitional v1 plugin manifest (identity, compatibility, capability requests, lazy triggers). Retained unchanged by CTX-0010; not the 0.1.0 distribution path, and removal is a follow-up.                         |
| `lua/wheel/init.lua`          | Harness entry point and legacy command surface (14 command definitions: `hello`, `status`, `graph`, `plan`, `run`, `trust`, `team`, `context`, `tools`, `orchestrate`, `models`, `branch`, `checkpoint`, `reflog`). |
| `lua/wheel/errors.lua`        | Typed command failure boundary: capability denials in the accepted bridge shape, validation failures, and a Wheel-local generic internal error.                                                                     |
| `lua/wheel/schema.lua`        | Bounded command schema validator: finite vocabulary, registration admission, invocation argument checks, and typed validation failures.                                                                             |
| `lua/wheel/commands.lua`      | Command registration layer: no-argument/result schema factories, host-bounded result truncation, argument/result dispatch checks.                                                                                   |
| `lua/wheel/config.lua`        | WheelConfig loader: hierarchical layering, executable project-config trust gate, and skill capability discovery.                                                                                                    |
| `lua/wheel/host.lua`          | WheelHost authority seam: process, tmp, and time primitives over the production standalone POSIX backend; some file paths still use direct `io.open` (gaps in SECURITY-MODEL).                                      |
| `lua/wheel/kernel.lua`        | WheelKernel Lua client: JSON-RPC dispatch, DAG control plane, Merkle slots, cognitive checkpoints.                                                                                                                  |
| `lua/wheel/agent.lua`         | WheelAgent runtime: Headless Panel working containers, Commander, Worker (Coding, Debug, Research), and Reviewer roles.                                                                                             |
| `lua/wheel/team.lua`          | WheelTeam coordinator: multi-agent peer colleague collaboration, autonomous wave orchestration, atomic claims, and handoffs.                                                                                        |
| `lua/wheel/context.lua`       | WheelContext engine: shared semantic slots, CAS concurrency, ContextBus pubsub, 3-way merge, and Three-Zone prefix-cache compiler.                                                                                  |
| `lua/wheel/tool.lua`          | WheelTool engine: standardized ActionIntent protocol, path sandboxing, core tools, role gating, and auto-spillover pipeline.                                                                                        |
| `lua/wheel/provider.lua`      | WheelProvider abstraction: line-buffered SSE streaming parser, tool formatters, and adapters (Mock, OpenAI, Anthropic, Stdio).                                                                                      |
| `lua/wheel/runner.lua`        | WheelRunner execution loop: autonomous ReAct turn loop, streaming token callbacks, tool dispatch, and checkpointing.                                                                                                |
| `lua/wheel/ui.lua`            | WheelUI visualizer: ASCII Task DAG, topological wave decomposition, and telemetry renderer.                                                                                                                         |
| `tests/test_wheel.lua`        | Comprehensive test suite covering kernel dispatch, agent role loops, UI rendering, configuration layering, and trust gates.                                                                                         |
| `tests/e2e_cross_process.lua` | End-to-end integration test suite exercising all 11 lifecycle stages against the real Rust `wheel_stdio_host` binary over Unix FIFOs.                                                                               |
| `package.json`                | Pinned dev dependencies: the transitional `bitty-plugin-lint` (by commit) and `luaparse`.                                                                                                                           |
| `bun.lock`                    | Locked dependency graph installed by `just install`.                                                                                                                                                                |
| `justfile`                    | Quality gates with pinned tool versions.                                                                                                                                                                            |
| `.github/workflows/ci.yml`    | CI gate with a read-only token and SHA-pinned actions.                                                                                                                                                              |

## Configuration and Architecture

### Headless Panel Working Container Invariant

Under Bitty Core Rule R1, `ExecutionContext` is primary: panels describe presentation and view projections, not execution authority (`PanelId != ViewId != TerminalId`). Every Wheel agent defaults to running in an isolated **Headless Panel working container** (`panel_id = "headless:panel:<agent_name>"`, `headless = true`), binding its execution environment without requiring desktop screen rendering. Presentation UI panels are optional observation projections.

### Hierarchical Configuration Layering

Wheel configuration is resolved across three hierarchical layers with fail-closed security:

1. **Defaults (Layer 0)**: Built-in baseline defining roles, directives, context budgets, and headless container policies.
2. **Global (Layer 1)**: User-wide defaults located at `~/.config/wheel/init.lua` (`$XDG_CONFIG_HOME/wheel/init.lua`).
3. **Project (Layer 2)**: Project-specific overrides located at `.wheel/init.lua` in the repository root (highest precedence).

The security model restricts project-layer effects to narrowing within the
approved ceiling; project configuration may not add a root, destination, secret
name, or authority for a role. Current loader behavior is not evidence of that
restriction until the evidence gates in
[SECURITY-MODEL.md](SECURITY-MODEL.md) pass.

### Executable Project Configuration Trust Gate

Project configuration (`.wheel/init.lua`) is executable code, and cloning or
entering a repository never executes it silently. The full policy is in
[SECURITY-MODEL.md](SECURITY-MODEL.md); the gates are:

- First contact is inert. Discovery, scan, help, and status do not evaluate the
  entry; only a command that needs project configuration reaches the gate.
- Approval is explicit and per project. The user sees the canonical project
  root, the full entry, its SHA-256 content hash, and the configuration effects
  it can request. There is no trust-on-first-use, no inherited trust, and no
  `--yes` default.
- The trust record binds the canonical root and the entry hash in
  `$XDG_STATE_HOME/wheel/trusted_projects.json`. Any content change, including
  whitespace, invalidates trust and forces re-approval.
- Revocation and store deletion remove trust. A missing, corrupt, or unreadable
  store fails closed; it is never recreated with existing approvals.
- Evaluation must run in a restricted environment with no filesystem, process,
  network, environment, or module-loading access, under instruction,
  wall-clock, and memory budgets. The current instruction hook is catchable and
  the wall-clock and memory budgets are not implemented; the result is validated
  as data only after those gates exist (see
  [SECURITY-MODEL.md](SECURITY-MODEL.md#relationship-to-current-code)).
- Project configuration may narrow behavior inside the approved ceiling. It may
  not add a workspace root, network destination, secret name, or authority for a
  role, and it may not disable audit, redaction, the deny-list, the path
  sandbox, or the trust gate.

Keeping the executable entry is a deliberate departure from OQ-068. It is
recorded as a Wheel-local divergence in
[SECURITY-MODEL.md](SECURITY-MODEL.md#oq-068-divergence-record); it does not
change OQ-068 or grant any other consumer permission to execute project code.

### Shared Context Memory & Prefix-Cache Optimization

Wheel coordinates peer colleague agents through content-addressed shared state:

- **Semantic Slots & CAS**: Structured slots (`workspace/*`, `tasks/<id>/*`, `decisions/*`, `scratch/*`) with optimistic Compare-And-Swap (`expected_version`) concurrency control and Merkle tree root hashing (`tree:v1\0`).
- **Semantic 3-Way Merge**: Non-conflicting additions or edits merge automatically; concurrent edits surface structured conflict records for explicit resolution.
- **Context Event Bus**: Real-time in-memory pubsub (`ContextBus`) notifying peer agents of slot modifications, checkpoint commits, and task handoffs without polling.
- **Three-Zone Prompt Compiler**: Pinned, byte-stable **Zone 1 (Stable Prefix)** shared across agents of the same model family for maximum KV cache reuse (>90%), coupled with a multi-tier budget reduction pipeline (Tier 1 scratchpad pruning, Tier 2 rationale compression, Tier 3 tail truncation).

### Standardized Action Protocol & Tool Execution Engine

Wheel executes software engineering tools under policy gates and bounded
context budgets:

- **Action Intents**: Typed action intents (`Inspect`, `Modify`, `Execute`, `Verify`, `Custom`) aligned with upstream Rust architecture (`bitty-ai-slice`).
- **Path Sandboxing**: Lexical workspace-boundary verification (`sanitize_path`) rejects `..` traversal and absolute paths outside the root. Symlink target resolution, non-regular file rejection, and atomic writes are required by [SECURITY-MODEL.md](SECURITY-MODEL.md) and are not yet evidenced.
- **Role Authority Gating**: `Research` and `Reviewer` roles are strictly read-only and fail-closed on `Modify` or `Execute` intents; `Commander` plans and orchestrates without direct file mutation.
- **Catastrophic Command Protection**: Pattern scanning against a deny-list subset (`rm -rf /`, `mkfs`, fork bombs, and similar). It is defense-in-depth, not a sandbox; the missing categories and limits are recorded in [SECURITY-MODEL.md](SECURITY-MODEL.md).
- **Auto-Spillover Observation Pipeline**: Oversized tool output (> 4 KiB) is automatically persisted as a content-addressed blob in context memory (`blobs/<hash>`), providing bounded head/tail previews to preserve the context window while ensuring full byte-exact recovery via `read_blob`.
- **Core Engineering Tools**: Built-in pure Lua implementations of `read_file` (with line slicing), `write_file` (truncating write with directory creation; atomic replace not yet implemented), `edit_file` (exact target replacement), `run_command` (process execution with metrics), `list_directory`, `search_code`, and `read_blob`.

### Autonomous Wave Orchestration & Task Execution Loop

Wheel provides an autonomous execution engine (`WheelTeam:run_orchestration_loop`) executing complex Task DAGs across topological execution waves:

- **Topological Wave Decomposition**: Uses dynamic programming (`WheelUI.calculate_waves`) to schedule independent ready tasks in parallel waves.
- **Worker Execution & Artifact Publishing**: Peer workers claim ready tasks, execute steps, and publish structured deliverables to semantic slots (`tasks/<id>/artifacts`).
- **Worker-to-Reviewer Verification Handoff**: Completed deliverables automatically hand off to an independent Reviewer peer colleague (`tasks/<id>/handoff`), triggering an acceptance review (`tasks/<id>/review`) and verification checkpoint prior to task release.
- **Cascading Readiness & Block Detection**: Succeeded tasks automatically promote downstream dependents to `Ready`. Any failed task or reviewer rejection cascades downstream tasks to `Blocked`, terminating the loop cleanly with deadlock diagnostics.
- **Fail-Closed Execution Telemetry**: Returns structured execution reports (`completed_tasks`, `failed_tasks`, `waves_executed`, `total_handoffs`, `total_checkpoints`, `duration_ms`) and persists summaries to `workspace/orchestration/last_run`.

### Live LLM Provider Adapters & Streaming Execution Runner

Wheel integrates heterogeneous large language models and autonomous ReAct execution loops:

- **Universal Model Provider Abstraction**: Uniform interface (`complete`, `stream`) across vendor protocols with pure Lua line-buffered SSE stream parsing (`WheelProvider.SSEParser`).
- **Pluggable Model Adapters**:
  - `MockProvider`: In-memory deterministic completion and chunk streaming simulation for offline tests and CI.
  - `OpenAIAdapter`: OpenAI-compatible `/v1/chat/completions` REST and SSE streaming (supporting OpenAI GPT-4o, DeepSeek Reasoner, Ollama `/v1`, vLLM, OpenRouter).
  - `AnthropicAdapter`: Anthropic Messages API (`/v1/messages`) supporting Claude 3.5 Sonnet, `thinking` token blocks, and `tool_use` blocks.
  - `StdioAdapter`: Subprocess CLI streaming runner (pipes to `ollama run`, `llm`, or local model binaries).
- **Tool Schema Normalization**: Automatic formatting of `WheelTool` definitions to OpenAI (`type="function"`) and Anthropic (`input_schema`) function calling specifications.
- **Autonomous ReAct Turn Runner**: Multi-turn execution loop (`WheelRunner.run_task`) combining Three-Zone context compilation, streaming token callbacks, structured 6-field `Rationale` extraction, path-sandboxed tool dispatch with auto-spillover, and automated checkpoint commits.

### Git-Inspired Context Versioning Engine

Wheel models agent context as an immutable, content-addressed versioned DAG inspired by Git principles:

- **Checkpoints as Commits**: Checkpoints bind a Merkle context tree snapshot, parent commit hashes, author, task ID, structured 6-field `Rationale`, and timestamp into a deterministic 64-hex SHA-256 commit hash (`commit:v1\0`).
- **Branching & Checkout**: Cheap context branching (`refs/heads/*`) for isolated hypothesis exploration. Checking out a branch or detached commit automatically restores working slots to that historical snapshot without transcript loss.
- **Reflog Recovery Journal**: Every `HEAD` movement (commit, branch, checkout, reset, merge) appends an immutable entry to `refs/reflog`, ensuring catastrophic rollback recovery and full auditability.
- **Context Stash**: In-progress uncommitted working slot modifications can be suspended (`stash_push`) before switching context and cleanly restored (`stash_pop`, `stash_drop`).
- **3-Way Semantic Merge & Fast-Forward**: Merges branches semantically by computing the lowest common ancestor (LCA) in the commit DAG; non-conflicting slot deltas merge automatically, while conflicting slots are preserved with structured diagnostics in `decisions/conflicts/*`.
- **Cherry-Pick**: Imports specific findings, artifacts, or decisions from foreign branches (`cherry_pick`) without pulling along entire branch histories or transcripts ("parents absorb conclusions, never transcripts").
- **Task-Isolated Workflows**: Multi-agent wave orchestration supports running worker tasks in dedicated task branches (`task/<id>`), merging deliverables into `main` upon reviewer acceptance.

## Commands

The harness currently defines the following commands. The
`bitty-terminal.wheel:` qualification and the host command registry belong to
the transitional plugin surface; they are not the 0.1.0 distribution path.

- `bitty-terminal.wheel:hello`: Print a greeting from Wheel (Bittie the hamster 🐹).
- `bitty-terminal.wheel:status`: Display kernel status, active task, checkpoint count, and telemetry.
- `bitty-terminal.wheel:graph`: Render an ASCII visualization of the Task DAG grouped into topological execution waves.
- `bitty-terminal.wheel:plan`: Initialize or decompose software engineering tasks into the Task DAG (Commander role).
- `bitty-terminal.wheel:run`: Execute ready tasks in the DAG using WheelAgent (Worker role).
- `bitty-terminal.wheel:trust`: Inspect and approve project configuration (`.wheel/init.lua`) with hash pinning.
- `bitty-terminal.wheel:team`: Display multi-agent peer colleague roster, roles, models, and live states.
- `bitty-terminal.wheel:context`: Inspect active semantic slots, Merkle root hash, and prefix-cache status.
- `bitty-terminal.wheel:tools`: List registered Wheel agent tools, intent categories, and schema descriptions.
- `bitty-terminal.wheel:orchestrate`: Run autonomous multi-agent wave orchestration loop over Task DAG.
- `bitty-terminal.wheel:models`: Display configured model profiles, providers, and capabilities.
- `bitty-terminal.wheel:branch`: List context branches or display active branch and HEAD commit.
- `bitty-terminal.wheel:checkpoint`: Display recent context checkpoints (commit ancestry log).
- `bitty-terminal.wheel:reflog`: Display recent context reflog transitions and audit journal.

Every command is declared once in the lazy command table in `lua/wheel/init.lua`
with an explicit `args_schema` and `result_schema`. All 14 commands currently
accept no arguments: their argument schema is a closed object with no declared
properties, so any supplied field is rejected with `E_ARGS_INVALID` (class
`validation`) before the handler runs. Each command returns the notification
projection it displays, `{ title, body }`, so CLI, palette, IPC, and agent
consumers can type the result without scraping presentation text. The title is
bounded at 64 bytes and the body at 8000 bytes: the current host bridge
marshals a command result through `DEFAULT_MAX_VALUE_BYTES` (8 KiB), and the
body bound reserves a 128-byte marshalling margin (the two keys plus headroom)
above the title. A
larger body is truncated at a UTF-8 boundary before the notification is shown,
so the visible and returned text stay schema-valid and host-compatible. A
malformed or unbounded schema fails registration with `E_SCHEMA_INVALID`, and a
handler result that drifts from its schema fails with `E_RESULT_INVALID`; both
are `validation` errors. The schema vocabulary is finite: `string`, `integer`,
`number`, `boolean`, `array`, and `object` types with `properties`, `required`,
`additionalProperties` (always `false` for objects), `items`, `enum`,
`minimum`/`maximum`, `minLength`/`maxLength`, and `minItems`/`maxItems`.
Unsupported keywords, unbounded strings, arrays, or numbers, cycles, and
over-deep schemas are rejected rather than ignored.

## Development

Install the pinned dependencies once, then run the same gate CI runs:

```sh
just install   # bun install --frozen-lockfile; the only network step
just check
```

`just install` materializes `bitty-plugin-lint` (bitty-plugin-sdk, pinned by
commit in `package.json` and `bun.lock`) and `luaparse`; every gate then runs
offline. `just manifest` validates the transitional `bitty-plugin.toml` with the
authoritative SDK linter against the accepted contract in bitty-docs
`docs/specifications/plugin-platform-rfc.md` (file name, identity,
compatibility, capability closed set, lazy triggers, hard limits). `just lua`
runs the pinned `luaparse` 0.3.1 CLI over every Lua source under `lua/` and
`tests/`; `just lua-control`
feeds the same parser an invalid snippet and requires rejection, so a recipe
that stopped reading the entry point cannot pass silently. `just check` runs
all three. The manifest gate keeps the transitional artifact honest until a
follow-up removes it; it is not evidence of plugin compatibility.

`bitty-plugin-lint` also validates table-form `[lazy].commands` schemas when a
manifest carries them, but the transitional manifest is intentionally unchanged
and stays in string form, so the linter never sees the Lua registration
schemas. `lua/wheel/schema.lua` is therefore the admission authority, applied
by `lua/wheel/commands.lua` at registration: it rejects unknown keywords,
unbounded strings, arrays, or numbers, missing `additionalProperties = false`,
cycles, and over-deep schemas before a command is captured. The unit suite
exercises those admission bounds, the host result budget, truncation, and the
invocation checks; it does not claim host-side validation evidence.

Run the unit test suite and the cross-process end-to-end integration drill:

```sh
just test      # runs unit tests across lua5.1, luajit, or lua
just e2e       # runs the 11-step cross-process drill with wheel_stdio_host over Unix FIFOs
```

## Authority

Wheel 0.1.0 runs as an independent harness process and holds the user's OS
authority under its own policy, not under a plugin manifest. The owner-approved
ceiling is:

- workspace read and workspace write inside the session's workspace root;
- arbitrary argv with a workspace working directory;
- shell command strings, a higher-risk class with session opt-in for unattended
  runs, deny-list screening, and mandatory audit;
- network egress to configured provider endpoints, with no inbound service;
- secret environment reads for named provider keys only. Child-process
  non-inheritance is a required control and is not implemented yet; the current
  process path inherits the parent environment (see
  [SECURITY-MODEL.md](SECURITY-MODEL.md#relationship-to-current-code)).

[SECURITY-MODEL.md](SECURITY-MODEL.md) is the normative repository policy for
these classes, the path sandbox, role gates, command deny-list, audit,
redaction, project-config trust gate, residual risk, and evidence gates. Any
widening requires independent security review plus mock/unit and real host
fixture evidence (owner D7).

The in-tree `bitty-plugin.toml` still requests only `platform.notify` and is
unchanged by the position record. It is transitional, must not be widened, and
does not describe harness authority; removal is a follow-up task.

## Plugin API surface (transitional)

The `bitty` namespace used by `init.lua` is the accepted Plugin API v1 surface.
The authoritative Lua bindings and type definitions are generated by the SDK
(`bitty.d.lua`, R-SDK-1). This surface is retained only while the transitional
manifest remains in tree; the 0.1.0 harness does not depend on plugin
activation, and no plugin compatibility is claimed.

### Command error contract

Every command handler crosses the typed failure boundary in
`lua/wheel/errors.lua`. A public failure is a catchable Lua error table with
exactly three fields, matching the accepted bridge error shape
(`bitty-plugins-docs/sdk/reference/overview.md`): `class`, `code`, and
`message`. Match on `code`, never on message text.

The boundary enforces that shape. A typed table that matches it passes
through unchanged; a recognized nil-global message becomes
`E_CAPABILITY_DENIED`; a table with extra fields, non-string fields, or a
message longer than the 160-character Wheel bound is normalized to
`E_INTERNAL`, as is every other non-capability failure. A malformed table is
never presented as a capability denial. Schema and argument validation errors
use the same three-field shape with class `validation`. One internal exception
exists: the
dispatch-budget sentinel is marked with a module-local token
(`WheelErrors.passthrough`) and keeps its identity so the budget failure is
not misreported. The token is not reachable from a handler and cannot be
forged with a table field; it is not part of the public error contract.

| `code`                | `class`      | Meaning                                                                                                            |
| --------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------ |
| `E_CAPABILITY_DENIED` | `runtime`    | The host removed a surface the command needs. The message names the missing capability family.                     |
| `E_INTERNAL`          | `runtime`    | The handler failed unexpectedly. The message is generic and never describes the underlying defect as a capability. |
| `E_ARGS_INVALID`      | `validation` | Arguments did not match the command's closed `args_schema`; the handler did not run.                               |
| `E_SCHEMA_INVALID`    | `validation` | A command's `args_schema` or `result_schema` was malformed or unbounded at registration.                           |
| `E_RESULT_INVALID`    | `validation` | A handler result did not match its closed `result_schema`.                                                         |

Capability denials use host wording, for example
`capability 'env.read' is not granted`, and name the capability family
(`env.read`, `fs.read`, `fs.write`, or `process.spawn`) the host would have to
grant. Temporary-file creation maps to `fs.write`; there is no separate temp
capability. These denials apply only to the transitional host command surface;
the manifest and its granted capability set are unchanged, and harness
authority is governed by [SECURITY-MODEL.md](SECURITY-MODEL.md).

`E_INTERNAL` has no accepted host code yet. It is deliberately Wheel-local
until the host vocabulary defines a generic internal or runtime failure code;
replace it when that code lands. Messages are bounded to one line and never
include tracebacks, host paths, secrets, or raw interpreter wording.

## Release checklist (0.1.0)

1. Ship a single harness artifact with a version and an install/launch
   contract; do not ship the plugin packaging path or claim `plugin-api`
   compatibility.
2. Complete the controls in [SECURITY-MODEL.md](SECURITY-MODEL.md) for the
   approved ceiling, pass both evidence gates, and obtain independent security
   review.
3. Replace this README's status note once the harness artifact is functional,
   tested against a real host fixture, and the evidence is recorded.
4. Remove or retire the transitional `bitty-plugin.toml` and its SDK lint gate
   in a scoped follow-up; do not widen the manifest in the meantime.
5. Keep the repository free of secrets and of install scripts with ambient
   authority.

## Security

Report vulnerabilities through the process in [SECURITY.md](SECURITY.md), not a
public issue. The 0.1.0 harness holds workspace read/write, arbitrary argv,
shell command strings, network egress, and secret environment reads under the
policy in [SECURITY-MODEL.md](SECURITY-MODEL.md). Executable project
configuration requires explicit per-project trust, and secrets are read only
from a named allowlist and redacted before persistence. The repository contains
no credentials.

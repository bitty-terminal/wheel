# Wheel

Wheel — the official Agent Harness plugin for the Bitty terminal (mascot: Bittie the hamster). Pre-implementation scaffold.

This repository was generated from
[bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template).
It is a minimal Bitty plugin package: a static manifest, one Lua entry point,
and a CI quality gate.

> Status: pre-implementation. The Bitty plugin host and the accepted Plugin
> API v1 bindings are still landing. `just check` validates the manifest with
> the authoritative `bitty-plugin-lint` from
> [bitty-plugin-sdk](https://github.com/bitty-terminal/bitty-plugin-sdk)
> (pinned by commit in `package.json` and `bun.lock`) and parses the Lua entry
> point, with a fail-closed parser control so the parse cannot silently pass.
> The `lua/<module>/` layout follows the candidate plugin-repository structure
> in bitty-docs; confirm it against the host loader contract before publishing.

## Scope

Wheel is the official Agent Harness plugin for the Bitty terminal, scoped to
software engineering only: its task domain is always software development. It
may support multi-agent, multi-role, multi-model, and multi-workspace/panel
operation within that domain. Roles (Primary, Commander, Coding, Review,
Debug, Research) vary by configuration, never by class explosion. The staged
MVP direction is a single Primary Coding Agent, then Primary plus Subagents,
then a Commander (research record 046).

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

| Path                          | Purpose                                                                                                                               |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `bitty-plugin.toml`           | Static manifest: identity, compatibility, capability requests, and lazy triggers.                                                     |
| `lua/wheel/init.lua`          | Entry point evaluated once per activation; registers commands (`hello`, `status`, `graph`, `plan`, `run`, `trust`).                   |
| `lua/wheel/config.lua`        | WheelConfig loader: 8 function classes schema, hierarchical layering, direnv trust gate, and skill capability discovery.              |
| `lua/wheel/kernel.lua`        | WheelKernel Lua client: JSON-RPC dispatch, DAG control plane, Merkle slots, cognitive checkpoints.                                    |
| `lua/wheel/agent.lua`         | WheelAgent runtime: Headless Panel working containers, Commander, Worker (Coding, Debug, Research), and Reviewer roles.               |
| `lua/wheel/team.lua`          | WheelTeam coordinator: multi-agent peer colleague collaboration, autonomous wave orchestration, atomic claims, and handoffs.          |
| `lua/wheel/context.lua`       | WheelContext engine: shared semantic slots, CAS concurrency, ContextBus pubsub, 3-way merge, and Three-Zone prefix-cache compiler.    |
| `lua/wheel/tool.lua`          | WheelTool engine: standardized ActionIntent protocol, path sandboxing, core tools, role gating, and auto-spillover pipeline.          |
| `lua/wheel/ui.lua`            | WheelUI visualizer: ASCII Task DAG, topological wave decomposition, and telemetry renderer.                                           |
| `tests/test_wheel.lua`        | Comprehensive test suite covering kernel dispatch, agent role loops, UI rendering, configuration layering, and trust gates.           |
| `tests/e2e_cross_process.lua` | End-to-end integration test suite exercising all 11 lifecycle stages against the real Rust `wheel_stdio_host` binary over Unix FIFOs. |
| `package.json`                | Pinned dev dependencies: the authoritative `bitty-plugin-lint` (by commit) and `luaparse`.                                            |
| `bun.lock`                    | Locked dependency graph installed by `just install`.                                                                                  |
| `justfile`                    | Quality gates with pinned tool versions.                                                                                              |
| `.github/workflows/ci.yml`    | CI gate with a read-only token and SHA-pinned actions.                                                                                |

## Configuration and Architecture

### Headless Panel Working Container Invariant

Under Bitty Core Rule R1, `ExecutionContext` is primary: panels describe presentation and view projections, not execution authority (`PanelId != ViewId != TerminalId`). Every Wheel agent defaults to running in an isolated **Headless Panel working container** (`panel_id = "headless:panel:<agent_name>"`, `headless = true`), binding its execution environment without requiring desktop screen rendering. Presentation UI panels are optional observation projections.

### Hierarchical Configuration Layering

Wheel configuration is resolved across three hierarchical layers with fail-closed security:

1. **Defaults (Layer 0)**: Built-in baseline defining roles, directives, context budgets, and headless container policies.
2. **Global (Layer 1)**: User-wide defaults located at `~/.config/wheel/init.lua` (`$XDG_CONFIG_HOME/wheel/init.lua`).
3. **Project (Layer 2)**: Project-specific overrides located at `.wheel/init.lua` in the repository root (highest precedence).

### Security Trust Gate (Direnv-Style)

To prevent arbitrary code execution when cloning untrusted repositories, project configurations (`.wheel/init.lua`) are gated by a security trust store (`$XDG_STATE_HOME/wheel/trusted_projects.json`):

- An untrusted `.wheel/init.lua` fails closed (`ok = false, error = "untrusted_project_config"`) and falls back to safe Global and Default configurations.
- Users explicitly inspect and approve configurations using `bitty-terminal.wheel:trust` or `WheelConfig.trust(path)`.
- Content tampering invalidates the pinned 64-hex SHA-256 cryptographic content hash immediately, requiring re-approval.

### Shared Context Memory & Prefix-Cache Optimization

Wheel coordinates peer colleague agents through content-addressed shared state:

- **Semantic Slots & CAS**: Structured slots (`workspace/*`, `tasks/<id>/*`, `decisions/*`, `scratch/*`) with optimistic Compare-And-Swap (`expected_version`) concurrency control and Merkle tree root hashing (`tree:v1\0`).
- **Semantic 3-Way Merge**: Non-conflicting additions or edits merge automatically; concurrent edits surface structured conflict records for explicit resolution.
- **Context Event Bus**: Real-time in-memory pubsub (`ContextBus`) notifying peer agents of slot modifications, checkpoint commits, and task handoffs without polling.
- **Three-Zone Prompt Compiler**: Pinned, byte-stable **Zone 1 (Stable Prefix)** shared across agents of the same model family for maximum KV cache reuse (>90%), coupled with a multi-tier budget reduction pipeline (Tier 1 scratchpad pruning, Tier 2 rationale compression, Tier 3 tail truncation).

### Standardized Action Protocol & Tool Execution Engine

Wheel executes software engineering tools under strict safety and context-budget guarantees:

- **Action Intents**: Typed action intents (`Inspect`, `Modify`, `Execute`, `Verify`, `Custom`) aligned with upstream Rust architecture (`bitty-ai-slice`).
- **Fail-Closed Path Sandboxing**: Strict workspace boundary verification (`sanitize_path`), rejecting all directory traversal attacks (`../../`) and uncontained path escapes.
- **Role Authority Gating**: `Research` and `Reviewer` roles are strictly read-only and fail-closed on `Modify` or `Execute` intents; `Commander` plans and orchestrates without direct file mutation.
- **Catastrophic Command Protection**: Proactive pattern scanning blocking destructive irreversible shell commands (`rm -rf /`, `mkfs`, fork bombs, etc.).
- **Auto-Spillover Observation Pipeline**: Oversized tool output (> 4 KiB) is automatically persisted as a content-addressed blob in context memory (`blobs/<hash>`), providing bounded head/tail previews to preserve the context window while ensuring full byte-exact recovery via `read_blob`.
- **Core Engineering Tools**: Built-in pure Lua implementations of `read_file` (with line slicing), `write_file` (atomic with directory creation), `edit_file` (exact target replacement), `run_command` (process execution with metrics), `list_directory`, `search_code`, and `read_blob`.

### Autonomous Wave Orchestration & Task Execution Loop

Wheel provides an autonomous execution engine (`WheelTeam:run_orchestration_loop`) executing complex Task DAGs across topological execution waves:

- **Topological Wave Decomposition**: Uses dynamic programming (`WheelUI.calculate_waves`) to schedule independent ready tasks in parallel waves.
- **Worker Execution & Artifact Publishing**: Peer workers claim ready tasks, execute steps, and publish structured deliverables to semantic slots (`tasks/<id>/artifacts`).
- **Worker-to-Reviewer Verification Handoff**: Completed deliverables automatically hand off to an independent Reviewer peer colleague (`tasks/<id>/handoff`), triggering an acceptance review (`tasks/<id>/review`) and verification checkpoint prior to task release.
- **Cascading Readiness & Block Detection**: Succeeded tasks automatically promote downstream dependents to `Ready`. Any failed task or reviewer rejection cascades downstream tasks to `Blocked`, terminating the loop cleanly with deadlock diagnostics.
- **Fail-Closed Execution Telemetry**: Returns structured execution reports (`completed_tasks`, `failed_tasks`, `waves_executed`, `total_handoffs`, `total_checkpoints`, `duration_ms`) and persists summaries to `workspace/orchestration/last_run`.

## Commands

Wheel provides the following commands via Bitty's command registry:

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

## Development

Install the pinned dependencies once, then run the same gate CI runs:

```sh
just install   # bun install --frozen-lockfile; the only network step
just check
```

`just install` materializes `bitty-plugin-lint` (bitty-plugin-sdk, pinned by
commit in `package.json` and `bun.lock`) and `luaparse`; every gate then runs
offline. `just manifest` validates `bitty-plugin.toml` with the authoritative
SDK linter against the accepted contract in bitty-docs
`docs/specifications/plugin-platform-rfc.md` (file name, identity,
compatibility, capability closed set, lazy triggers, hard limits). `just lua`
runs the pinned `luaparse` 0.3.1 CLI over the entry point; `just lua-control`
feeds the same parser an invalid snippet and requires rejection, so a recipe
that stopped reading the entry point cannot pass silently. `just check` runs
all three.

Run the unit test suite and the cross-process end-to-end integration drill:

```sh
just test      # runs unit tests across lua5.1, luajit, or lua
just e2e       # runs the 11-step cross-process drill with wheel_stdio_host over Unix FIFOs
```

## Capabilities

Capabilities are deny by default: a request absent from `[capabilities]` is
denied, identifiers come from a closed set, and there is no allow-all entry.
Request the narrowest identifier the plugin actually uses, one at a time.
High-risk identifiers (`terminal.raw-read`, `terminal.input.all`,
`ui.protocol-register`, `debug.control`, `runtime.plugin-manage`, and similar)
trigger distinct consent and should not be added without a reviewed need.

Filesystem access is declared as structured requests with explicit patterns:

```toml
[[capabilities.filesystem]]
access = "read"
paths = ["~/Documents/**/*.md"]
```

## API contract

The `bitty` namespace used by `init.lua` is the accepted Plugin API v1 surface
sketch. The authoritative Lua bindings and type definitions are generated by
the SDK (`bitty.d.lua`, R-SDK-1); re-check `init.lua` against that contract
when it lands, and do not use surface the contract does not define.

## Before publishing

1. Add a `LICENSE` file and set `plugin.license` in `bitty-plugin.toml`.
2. Confirm `compat.bitty` and `compat.plugin-api` match the host releases you
   support.
3. Replace this README's status note once the plugin is functional and tested
   against a released host.
4. Keep the repository free of secrets, install scripts, and ambient
   authority.

## Security

Report vulnerabilities through the process in the umbrella project's security
policy rather than a public issue. This scaffold contains no credentials and no
install-time execution.

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

## Commands

Wheel provides the following commands via Bitty's command registry:

- `bitty-terminal.wheel:hello`: Print a greeting from Wheel (Bittie the hamster 🐹).
- `bitty-terminal.wheel:status`: Display kernel status, active task, checkpoint count, and telemetry.
- `bitty-terminal.wheel:graph`: Render an ASCII visualization of the Task DAG grouped into topological execution waves.
- `bitty-terminal.wheel:plan`: Initialize or decompose software engineering tasks into the Task DAG (Commander role).
- `bitty-terminal.wheel:run`: Execute ready tasks in the DAG using WheelAgent (Worker role).
- `bitty-terminal.wheel:trust`: Inspect and approve project configuration (`.wheel/init.lua`) with hash pinning.

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

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
> unit and cross-process test suites. The 0.1.0 artifact and its local
> install/upgrade path are defined and validated, but no artifact has been
> published and no released-host integration is claimed. The 0.1.0 scope is a
> **single harness artifact**: plugin packaging and `compat.plugin-api` are
> dropped (owner D6).
> Authority and its controls are defined in [SECURITY-MODEL.md](SECURITY-MODEL.md);
> the 0.1.0 ceiling is workspace read/write, arbitrary argv, shell command
> strings, network egress, and secret environment reads, with shell strings and
> secret reads in the higher-risk class. The in-tree `bitty-plugin.toml` is
> retained unchanged by the position record as a transitional artifact and is
> not a supported distribution path.

## Overview

### Product position

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

### Scope

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

## Install

Wheel 0.1.0 defines the harness artifact and its local install, upgrade, and
rollback path. No release artifact has been published: there is no tag, no
registry entry, and no released-host integration claim. `just package` builds
the same archive locally, and `just verify-package` proves install, activation,
upgrade, and rollback. The release target is `v0.1.0`; see
[Release checklist (0.1.0)](#release-checklist-010).

### Artifact

`dist/wheel-0.1.0.tar.gz` contains the standalone harness library:

- `lua/` — the `wheel` module tree (`lua/wheel/*.lua`).
- `LICENSE`, `README.md`, and `SECURITY-MODEL.md`.
- `repo.toml` — repository identity and release pointer.
- `VERSION` — the artifact version (`0.1.0`).

It excludes tests, `recording/`, `node_modules`, `.git`, CI workflows, `dist/`,
`scripts/`, the justfile, `package.json`, `bun.lock`, and the transitional
`bitty-plugin.toml`. It is a Lua library tree, not a Bitty plugin: there is no
plugin packaging, no `compat.plugin-api` field, and no Bitty host version
requirement. The installed layout is `<prefix>/wheel/<version>/` with a
relative `current` symlink at `<prefix>/wheel/current`.

Build the artifact and its sidecar:

```sh
just package
(cd dist && sha256sum -c wheel-0.1.0.tar.gz.sha256)
```

`just package` is offline. It writes `dist/wheel-0.1.0.tar.gz`, the
`.sha256` sidecar, and a `.manifest.json` record with the artifact name,
version, source revision, clean/dirty marker, contents, per-file digests, and
archive digest. Only `lua/` files tracked by Git are copied, so ignored or
untracked files cannot enter the archive. It fails closed on a dirty worktree,
a missing input, or an unsupported version. The archive is
deterministic — sorted member order, fixed mtime and ownership, normalized
modes, and gzip without a name or timestamp — so the same revision and
packaging toolchain produce the same bytes and digest. The digest provides
integrity checking only; 0.1.0 is unsigned and has no update channel.

### Install and launch

`just install-local <prefix>` installs a built archive under
`<prefix>/wheel/<version>/` and switches the `current` symlink:

```sh
just package
just install-local "$HOME/.local"
```

The installer verifies the SHA-256 sidecar, accepts only regular files and
directories under the expected archive root, rejects absolute, `..`, and
symlinked members, refuses `/`, trailing-slash, `..`-containing, symlinked, and
non-owned prefixes, extracts into a private staging directory, and switches
`current` atomically. It records the outgoing version in
`<prefix>/wheel/previous`. It is offline and contains no `eval`, no
archive-supplied shell string, and no post-install script.

There is no standalone launcher executable in the 0.1.0 artifact. The launch
contract is the Lua 5.1 module root:

```sh
LUA_PATH="$HOME/.local/wheel/current/lua/?.lua;$HOME/.local/wheel/current/lua/?/init.lua;;" \
  lua5.1 -e 'local wheel = require("wheel"); print(wheel.command_catalog[1].id)'
```

When Wheel runs in a Bitty panel or terminal, the presentation table `_G.bitty`
supplies `commands.register` and `notify.show`; it supplies presentation and
input only, never execution authority.

### Upgrade and rollback

Update `VERSION` and the sources for the next release, then build and install:

```sh
just package
just install-local "$HOME/.local"
```

For a specific locally built archive, build it with an explicit test version
(the `--allow-dirty` flag marks a non-release build), then install it:

```sh
scripts/package.sh --version 0.1.1 --allow-dirty --output-dir dist
just install-local "$HOME/.local" \
  --version 0.1.1 --archive dist/wheel-0.1.1.tar.gz
```

The old version stays installed and is recorded as `previous`. Roll back to it
with:

```sh
just rollback-local "$HOME/.local"
```

Rollback swaps `current` and `previous`, so repeating the command returns to
the newer version. Remove a retired version directory only when it is neither
the current nor the previous version.

### Compatibility

- **Gate interpreter:** Lua 5.1 (PUC-Rio 5.1.5 in CI and the real-host
  fixture). LuaJIT may run the development suites but is not the release gate.
- **Platform:** POSIX hosts with GNU coreutils, tar, and gzip; Linux is
  tested. Windows is not supported and macOS is not verified.
- **Bitty host:** no host version is required. Wheel is an independent
  process; a host supplies presentation and input only.
- **Plugin API:** none. `bitty-plugin.toml` is transitional, is not in the
  artifact, and grants no authority or compatibility claim.
- **Versioning:** semantic versioning. Before 1.0, only the documented module
  path and command catalog are stable enough to rely on.

Standalone harness development does not require a Bitty host. Prerequisites:

- [Bun](https://bun.sh/) 1.4.2, the version pinned by `package.json`
  (`packageManager`) and used by CI.
- [just](https://github.com/casey/just) for the repository recipes.
- Lua 5.1 or LuaJIT for the test and end-to-end recipes; a `lua` binary also
  satisfies the recipe when neither is installed.
- A POSIX host with standard shell utilities. Windows support is not claimed.

From a checkout of the repository:

```sh
just install   # bun install --frozen-lockfile; the only network step
just check     # lint, format check, manifest, docs, Lua parse, and tests
```

`just test` runs the unit suite and `just e2e` runs the optional cross-process
drill against the separate `wheel_stdio_host` binary. The drill skips cleanly
when no Lua interpreter is available; it reports a failure when the host binary
is absent.

`just test-real-host` runs the opt-in real-host activation and command-smoke
fixture. It requires `lua5.1` and fails closed when the interpreter is absent.
CI installs Lua 5.1 before the quality gates, so `just check` runs the Lua
suite there, and then runs `just test-real-host` after `just check`.

`just verify-package` builds the 0.1.0 artifact, installs it into a temporary
prefix, runs the same fixture against the installed tree, upgrades to a locally
built 0.1.1, rolls back, and checks the refusal paths. It is offline and does
not publish anything. CI runs it after the real-host fixture.

The in-tree `bitty-plugin.toml` is a transitional v1 plugin manifest, not an
installation path. Installing Wheel through a Bitty plugin manager, or claiming
`plugin-api` compatibility from that file, is outside the 0.1.0 deliverable. A
thin plugin facade may return only if a host-brokered execution service is
accepted (owner D6).

## Commands

Wheel exposes 14 commands. The `bitty-terminal.wheel:` qualification and the
host command registry belong to the transitional plugin surface; they are not
the 0.1.0 distribution path. The harness catalog is the single declaration in
`lua/wheel/init.lua` (`M.command_catalog`), and every command is registered
from it with the same argument and result contract.

| Command       | Invocation                         | Arguments schema                            | Result contract   |
| ------------- | ---------------------------------- | ------------------------------------------- | ----------------- |
| `hello`       | `bitty-terminal.wheel:hello`       | No arguments; closed object, no properties. | `{ title, body }` |
| `status`      | `bitty-terminal.wheel:status`      | No arguments; closed object, no properties. | `{ title, body }` |
| `graph`       | `bitty-terminal.wheel:graph`       | No arguments; closed object, no properties. | `{ title, body }` |
| `plan`        | `bitty-terminal.wheel:plan`        | No arguments; closed object, no properties. | `{ title, body }` |
| `run`         | `bitty-terminal.wheel:run`         | No arguments; closed object, no properties. | `{ title, body }` |
| `trust`       | `bitty-terminal.wheel:trust`       | No arguments; closed object, no properties. | `{ title, body }` |
| `team`        | `bitty-terminal.wheel:team`        | No arguments; closed object, no properties. | `{ title, body }` |
| `context`     | `bitty-terminal.wheel:context`     | No arguments; closed object, no properties. | `{ title, body }` |
| `tools`       | `bitty-terminal.wheel:tools`       | No arguments; closed object, no properties. | `{ title, body }` |
| `orchestrate` | `bitty-terminal.wheel:orchestrate` | No arguments; closed object, no properties. | `{ title, body }` |
| `models`      | `bitty-terminal.wheel:models`      | No arguments; closed object, no properties. | `{ title, body }` |
| `branch`      | `bitty-terminal.wheel:branch`      | No arguments; closed object, no properties. | `{ title, body }` |
| `checkpoint`  | `bitty-terminal.wheel:checkpoint`  | No arguments; closed object, no properties. | `{ title, body }` |
| `reflog`      | `bitty-terminal.wheel:reflog`      | No arguments; closed object, no properties. | `{ title, body }` |

What the commands display:

- `hello`: a greeting from Wheel (Bittie the hamster 🐹).
- `status`: kernel status, active task, checkpoint count, and telemetry.
- `graph`: an ASCII visualization of the Task DAG grouped into topological
  execution waves.
- `plan`: initialize or decompose software engineering tasks into the Task DAG
  (Commander role).
- `run`: execute ready tasks in the DAG using WheelAgent (Worker role).
- `trust`: inspect and approve project configuration (`.wheel/init.lua`) with
  hash pinning.
- `team`: the multi-agent peer colleague roster, roles, models, and live states.
- `context`: active semantic slots, Merkle root hash, and prefix-cache status.
- `tools`: registered Wheel agent tools, intent categories, and schema
  descriptions.
- `orchestrate`: the autonomous multi-agent wave orchestration loop over the
  Task DAG.
- `models`: configured model profiles, providers, and capabilities.
- `branch`: context branches, or the active branch and HEAD commit.
- `checkpoint`: recent context checkpoints (commit ancestry log).
- `reflog`: recent context reflog transitions and audit journal.

All 14 commands accept no arguments: `args_schema` is a closed object with no
declared properties, so any supplied field is rejected with `E_ARGS_INVALID`
(class `validation`) before the handler runs. Each command returns the
notification projection it displays, `{ title, body }`, so CLI, palette, IPC,
and agent consumers can type the result without scraping presentation text. The
title is bounded at 64 bytes and the body at 8000 bytes: the current host bridge
marshals a command result through `DEFAULT_MAX_VALUE_BYTES` (8 KiB), and the
body bound reserves a 128-byte marshalling margin above the title. A larger
body is truncated at a UTF-8 boundary before the notification is shown, so the
visible and returned text stay schema-valid and host-compatible.

A malformed or unbounded schema fails registration with `E_SCHEMA_INVALID`, and
a handler result that drifts from its schema fails with `E_RESULT_INVALID`; both
are `validation` errors. The schema vocabulary is finite: `string`, `integer`,
`number`, `boolean`, `array`, and `object` types with `properties`, `required`,
`additionalProperties` (always `false` for objects), `items`, `enum`,
`minimum`/`maximum`, `minLength`/`maxLength`, and `minItems`/`maxItems`.
Unsupported keywords, unbounded strings, arrays, or numbers, cycles, and
over-deep schemas are rejected rather than ignored. The full failure contract is
in [Troubleshooting](#troubleshooting).

## Configuration

This plugin declares no settings.

### Wheel harness configuration

Wheel does not read plugin settings from `bitty-plugin.toml`: the transitional
manifest has no `[settings]` table and is intentionally unchanged. Configuration
is resolved by `lua/wheel/config.lua` across three layers and grouped into eight
function classes.

- **XDG layers.**
  - **Layer 0 — built-in defaults.** Compiled into `WheelConfig.DEFAULTS` in
    `lua/wheel/config.lua`.
  - **Layer 1 — user-wide file.** `$XDG_CONFIG_HOME/wheel/init.lua`, falling
    back to `$HOME/.config/wheel/init.lua`.
  - **Layer 2 — project file.** `.wheel/init.lua` under the project root;
    highest precedence and evaluated only after the trust gate approves it.
  - **Trust store.** `$XDG_STATE_HOME/wheel/trusted_projects.json`, falling back
    to `$HOME/.local/state/wheel/trusted_projects.json`. A missing, corrupt, or
    unreadable store fails closed and is never recreated with existing
    approvals.
- **Function classes.** `lua/wheel/config.lua` groups the schema into exactly
  eight classes:
  - `roles` — role definitions and model references (Commander, Coding, Debug,
    Research, Reviewer). A role's `model_profile` may set
    `max_completion_tokens` to override the provider completion budget;
    `context_budget` remains the separate context-window policy.
  - `directives` — structured prompt directives applied to every role.
  - `tools` — tool allow and deny lists plus custom tool declarations.
  - `skills` — session skill filters discovered from `.agents/`.
  - `verification` — change-gated verification declarations and the test
    command.
  - `context` — context budgets: 64 KiB total, 16 KiB Zone 1, 32 KiB Zone 2,
    16 KiB Zone 3, and the 4 KiB spillover threshold.
  - `panel` — the Headless Panel working-container policy.
  - `hooks` — lifecycle hooks.
- **Executable `.wheel/init.lua` trust gate.** Project configuration is code,
  and cloning or entering a project never executes it silently. The policy
  target is defined in
  [SECURITY-MODEL.md](SECURITY-MODEL.md#executable-project-configuration-trust-gate):
  - First contact is inert. Discovery, scan, help, and status do not evaluate the
    entry; only a command that needs project configuration reaches the gate.
  - Approval is an explicit interactive action. The consent view must show the
    canonical project root (symlinks resolved), the full entry, its SHA-256
    content hash, the change diff on re-approval, and the configuration effects
    the entry can request; a truncated preview is not sufficient consent. There
    is no trust-on-first-use, no inherited trust, and no `--yes` default.
  - The trust record binds the canonical project root and the entry hash in
    `$XDG_STATE_HOME/wheel/trusted_projects.json`. Any content change, including
    whitespace, invalidates trust and forces re-approval.
  - Revocation and store deletion remove trust. A missing, corrupt, or unreadable
    store fails closed; it is never recreated with existing approvals.
  - Evaluation runs in a restricted environment with no filesystem, process,
    network, environment, or module-loading access. The current instruction hook
    is catchable and the wall-clock and memory budgets are not implemented; the
    result is validated as data only after those gates exist (see
    [SECURITY-MODEL.md](SECURITY-MODEL.md#relationship-to-current-code)).
  - Project configuration may narrow behavior inside the approved ceiling. It
    may not add a workspace root, network destination, secret name, or authority
    for a role, and it may not disable audit, redaction, the deny-list, the path
    sandbox, or the trust gate.
- **Current trust-gate gaps.** The present `trust` command is not the consent
  flow above. It approves the current working directory and keys the record by
  a lexical path normalization (separator, `.` segment, and trailing-slash
  cleanup; no `..` or symlink resolution), shows a 120-character preview and a
  16-hex hash prefix, lists no configuration effects, and records trust without
  an interactive confirmation. Hash pinning and fail-closed untrusted handling
  exist, but the full-content consent view, the change diff, field validation,
  narrowing-only enforcement, and the evaluation budgets are still gaps. See
  [SECURITY-MODEL.md](SECURITY-MODEL.md#relationship-to-current-code); this
  inventory is not a claim of compliance.
- **Future plugin facade.** If a later facade declares `[settings]` in
  `bitty-plugin.toml`, the SDK-rendered `Setting`/`Type`/`Default`/`Description`
  table replaces the no-settings sentence above and is generated from the
  manifest. The harness layers in this list remain the runtime configuration
  surface.

The security model restricts project-layer effects to narrowing within the
approved ceiling; project configuration may not add a root, destination, secret
name, or authority for a role. Current loader behavior is not evidence of that
restriction until the evidence gates in
[SECURITY-MODEL.md](SECURITY-MODEL.md) pass.

Keeping the executable entry is a deliberate departure from OQ-068. It is
recorded as a Wheel-local divergence in
[SECURITY-MODEL.md](SECURITY-MODEL.md#oq-068-divergence-record); it does not
change OQ-068 or grant any other consumer permission to execute project code.

## Keybindings

Wheel exposes commands, not keybindings. The Bitty host owns keybinding
registration and dispatch: it decides which keys invoke which commands, so Wheel
registers no default keybindings and claims no key conflicts. The transitional
`bitty-plugin.toml` declares no keybindings either. Consumers invoke commands by
name or bind them in their own host configuration.

## Troubleshooting

### Command error contract

Every command handler crosses the typed failure boundary in
`lua/wheel/errors.lua`. A public failure is a catchable Lua error table with
exactly three fields, matching the accepted bridge error shape
(`bitty-plugins-docs/sdk/reference/overview.md`): `class`, `code`, and
`message`. Match on `code`, never on message text.

The boundary enforces that shape. A typed table that matches it passes through
unchanged; a recognized nil-global message becomes `E_CAPABILITY_DENIED`; a
table with extra fields, non-string fields, or a message longer than the
160-character Wheel bound is normalized to `E_INTERNAL`, as is every other
non-capability failure. A malformed table is never presented as a capability
denial. Schema and argument validation errors use the same three-field shape
with class `validation`. One internal exception exists: the dispatch-budget
sentinel is marked with a module-local token (`WheelErrors.passthrough`) and
keeps its identity so the budget failure is not misreported. The token is not
reachable from a handler and cannot be forged with a table field; it is not part
of the public error contract.

| `code`                        | `class`      | Meaning                                                                                                            |
| ----------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------ |
| `E_CAPABILITY_DENIED`         | `runtime`    | The host removed a surface the command needs. The message names the missing capability family.                     |
| `E_INTERNAL`                  | `runtime`    | The handler failed unexpectedly. The message is generic and never describes the underlying defect as a capability. |
| `E_ARGS_INVALID`              | `validation` | Arguments did not match the command's closed `args_schema`; the handler did not run.                               |
| `E_SCHEMA_INVALID`            | `validation` | A command's `args_schema` or `result_schema` was malformed or unbounded at registration.                           |
| `E_RESULT_INVALID`            | `validation` | A handler result did not match its closed `result_schema`.                                                         |
| `E_COMPLETION_BUDGET_INVALID` | `validation` | A completion-token bound override was zero, negative, non-integer, non-numeric, or above the named maximum.        |
| `E_MODULE_LOAD_FAILED`        | `resolution` | A Wheel submodule could not be loaded; the message names the rooted module and a bounded, path-free cause.         |

`E_COMPLETION_BUDGET_INVALID` is raised by the provider adapters and
`WheelRunner` before a network request when a `max_completion_tokens` override
fails validation; it is not a command argument failure.

`E_MODULE_LOAD_FAILED` is raised at activation when a required Wheel submodule
cannot be loaded, or on first use when an optional lazy submodule fails. The
message names the rooted module (for example `wheel.agent`) and keeps only a
bounded, path-free cause; no stack trace, host path, or secret is included.

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

### Configuration failures

Named configuration failures returned by `lua/wheel/config.lua`: `untrusted_project_config` and `project_config_eval_error`.

- `untrusted_project_config` — the project entry exists but its content hash is
  not approved in the trust store. The loader returns the safe defaults plus
  the global layer, marks `layers.project = false`, and does not evaluate the
  entry. Approve it with the `trust` command or remove it.
- `project_config_eval_error` — the trusted entry failed to evaluate or did not
  return a table. The loader falls back to the safe defaults plus the global
  layer, reports the evaluation message, and never applies a partial project
  overlay.

### Common failures

- `dependencies are not installed` — run `just install`.
- `No lua interpreter found` — install Lua 5.1 or LuaJIT; the test and e2e
  recipes skip execution rather than silently claiming success.
- `bitty-plugin-lint` or `bitty-plugin-docs-check` reports the tool is not
  installed — run `just install`; both binaries come from the pinned
  `bitty-plugin-sdk` commit.
- `just docs-check` reports `readme.section.missing`, `readme.section.order`, or
  `readme.settings.none` — restore the six required H2 sections, their order,
  or the no-settings sentence in `## Configuration`.
- `just e2e` cannot find `wheel_stdio_host` — the cross-process drill needs the
  separate Rust host binary; unit tests do not.
- `test-real-host requires lua5.1 on PATH` — the real-host fixture fails closed
  instead of skipping; install Lua 5.1. CI installs it before the quality gates.
- `E_COMPLETION_BUDGET_INVALID` — a `max_completion_tokens` override was zero,
  negative, fractional, non-numeric, or above `MAX_COMPLETION_TOKENS` (32768).
  Use a positive integer within the bound or omit the override for the named
  default.
- `just manifest` rejects `bitty-plugin.toml` — the transitional manifest is
  unchanged by the harness position; fix the manifest or the SDK pin rather than
  widening it.

## Layout

| Path                                      | Purpose                                                                                                                                                                                                              |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`                               | Canonical user document: the six required H2 sections plus developer and architecture reference.                                                                                                                     |
| `bitty-plugin.toml`                       | Transitional v1 plugin manifest (identity, compatibility, capability requests, lazy triggers). Retained unchanged by CTX-0010; not the 0.1.0 distribution path, and removal is a follow-up.                          |
| `lua/wheel/init.lua`                      | Harness entry point and legacy command surface (14 command definitions: `hello`, `status`, `graph`, `plan`, `run`, `trust`, `team`, `context`, `tools`, `orchestrate`, `models`, `branch`, `checkpoint`, `reflog`).  |
| `lua/wheel/errors.lua`                    | Typed command failure boundary: capability denials in the accepted bridge shape, validation failures, and a Wheel-local generic internal error.                                                                      |
| `lua/wheel/schema.lua`                    | Bounded command schema validator: finite vocabulary, registration admission, invocation argument checks, and typed validation failures.                                                                              |
| `lua/wheel/commands.lua`                  | Command registration layer: no-argument/result schema factories, host-bounded result truncation, argument/result dispatch checks.                                                                                    |
| `lua/wheel/config.lua`                    | WheelConfig loader: hierarchical layering, executable project-config trust gate, and skill capability discovery.                                                                                                     |
| `lua/wheel/host.lua`                      | WheelHost authority seam: explicitly selected standalone POSIX backend for filesystem, process, temporary-file, wall-clock, and CPU-time primitives; typed denials on unsupported platforms or unavailable surfaces. |
| `lua/wheel/kernel.lua`                    | WheelKernel Lua client: JSON-RPC dispatch, DAG control plane, Merkle slots, cognitive checkpoints.                                                                                                                   |
| `lua/wheel/agent.lua`                     | WheelAgent runtime: Headless Panel working containers, Commander, Worker (Coding, Debug, Research), and Reviewer roles.                                                                                              |
| `lua/wheel/team.lua`                      | WheelTeam coordinator: multi-agent peer colleague collaboration, autonomous wave orchestration, atomic claims, and handoffs.                                                                                         |
| `lua/wheel/context.lua`                   | WheelContext engine: shared semantic slots, CAS concurrency, ContextBus pubsub, 3-way merge, and Three-Zone prefix-cache compiler.                                                                                   |
| `lua/wheel/tool.lua`                      | WheelTool engine: standardized ActionIntent protocol, path sandboxing, core tools, role gating, and auto-spillover pipeline.                                                                                         |
| `lua/wheel/provider.lua`                  | WheelProvider abstraction: line-buffered SSE streaming parser, tool formatters, and adapters (Mock, OpenAI, Anthropic, Stdio).                                                                                       |
| `lua/wheel/runner.lua`                    | WheelRunner execution loop: autonomous ReAct turn loop, streaming token callbacks, tool dispatch, and checkpointing.                                                                                                 |
| `lua/wheel/ui.lua`                        | WheelUI visualizer: ASCII Task DAG, topological wave decomposition, and telemetry renderer.                                                                                                                          |
| `tests/test_wheel.lua`                    | Comprehensive test suite covering kernel dispatch, agent role loops, UI rendering, configuration layering, trust gates, and README contract parity.                                                                  |
| `tests/test_live_openrouter.lua`          | Opt-in live OpenRouter test (`just test-live`): complete, tool call, SSE stream, and runner ReAct turn; runs after the key-free redirect-policy test.                                                                |
| `tests/live_http_client.py`               | Test-only stdlib HTTP transport for `just test-live`; reads the key from its inherited environment, rejects redirects, and never accepts the key through argv, files, or request JSON.                               |
| `tests/test_live_http_client_redirect.py` | Key-free loopback negative test: the HTTP client refuses cross-host and scheme-change 302 redirects and forwards no Authorization header.                                                                            |
| `tests/e2e_cross_process.lua`             | End-to-end integration test suite exercising all 11 lifecycle stages against the real Rust `wheel_stdio_host` binary over Unix FIFOs.                                                                                |
| `VERSION`                                 | Canonical harness version (`0.1.0`); the single source used by `just package`.                                                                                                                                       |
| `scripts/package.sh`                      | Deterministic artifact builder: archive, SHA-256 sidecar, and manifest; fails closed on dirty inputs.                                                                                                                |
| `scripts/install-local.sh`                | Offline install/upgrade/rollback under `<prefix>/wheel/<version>` with digest, prefix, ownership, and symlink checks.                                                                                                |
| `scripts/verify-package.sh`               | Builds, installs, runs the real-host fixture on the installed tree, upgrades, rolls back, and tests refusals.                                                                                                        |
| `dist/`                                   | Gitignored package output (`wheel-<version>.tar.gz`, `.sha256`, `.manifest.json`).                                                                                                                                   |
| `package.json`                            | Pinned dev dependencies: the `bitty-plugin-sdk` commit (manifest linter and README docs checker) and `luaparse`.                                                                                                     |
| `bun.lock`                                | Locked dependency graph installed by `just install`.                                                                                                                                                                 |
| `justfile`                                | Quality gates with pinned tool versions, including the SDK README checker in `just check` and the package/install recipes.                                                                                           |
| `.github/workflows/ci.yml`                | CI gate with a read-only token and SHA-pinned actions.                                                                                                                                                               |

## Architecture

### Headless Panel Working Container Invariant

Under Bitty Core Rule R1, `ExecutionContext` is primary: panels describe presentation and view projections, not execution authority (`PanelId != ViewId != TerminalId`). Every Wheel agent defaults to running in an isolated **Headless Panel working container** (`panel_id = "headless:panel:<agent_name>"`, `headless = true`), binding its execution environment without requiring desktop screen rendering. Presentation UI panels are optional observation projections.

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
- **Bounded Completion Budget**: Every OpenAI-compatible and Anthropic HTTP provider request carries an explicit completion `max_tokens` from `WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS` (4096) or a validated `max_completion_tokens` override, bounded at 32768. The stdio adapter has no completion-token field and is outside this boundary. The context window remains a separate `context_budget`; zero, negative, non-integer, non-numeric, and oversized overrides fail with a typed `E_COMPLETION_BUDGET_INVALID` error before an HTTP request is sent.
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

## Development

Install the pinned dependencies once, then run the same gate CI runs:

```sh
just install   # bun install --frozen-lockfile; the only network step
just check
```

`just install` materializes the pinned `bitty-plugin-sdk` (commit-pinned in
`package.json` and `bun.lock`) and `luaparse`; every gate then runs offline. The
SDK supplies both `bitty-plugin-lint` and `bitty-plugin-docs-check`. The pin has
exactly one location pair; update `package.json` and refresh `bun.lock` with
`bun install`, never a second pin in the justfile.

- `just manifest` validates the transitional `bitty-plugin.toml` with the
  authoritative SDK linter against the accepted contract in bitty-docs
  `docs/specifications/plugin-platform-rfc.md` (file name, identity,
  compatibility, capability closed set, lazy triggers, hard limits).
- `just docs-check` validates `README.md` against the SDK user-documentation
  contract: the six required H2 sections lead in order, and `## Configuration`
  matches the manifest `[settings]`. Wheel declares no settings, so the section
  carries the required no-settings sentence and the harness configuration
  bullet list.
- `just lua` runs the pinned `luaparse` 0.3.1 CLI over every Lua source under
  `lua/` and `tests/`; `just lua-control` feeds the same parser an invalid
  snippet and requires rejection, so a recipe that stopped reading the entry
  point cannot pass silently.
- `just lint` and `just fmt-check` run markdownlint-cli2 and Prettier over the
  repository.
- `just test` runs the unit suite across `lua5.1`, `luajit`, or `lua`.
- `just test-real-host` runs the opt-in real-host fixture with `lua5.1`; the
  fixture execution is not part of `just check` locally (the Lua gate still
  parses the file), and CI runs it after the quality gates.
- `just check` runs lint, format check, manifest, docs check, Lua parse, the
  parser control, and the test suite. It fails closed when dependencies are
  missing instead of fetching.

The manifest gate keeps the transitional artifact honest until a follow-up
removes it; it is not evidence of plugin compatibility.

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

The unit suite also parses `README.md` and asserts that the documented command
catalog, the eight configuration classes, the troubleshooting error codes, and
the named configuration failures match the Lua sources.

### Real-host fixture

`just test-real-host` runs `tests/real_host_fixture.lua` against the real OS
boundary of the standalone harness process (Option B). The fixture creates an
ephemeral base and workspace, points `XDG_RUNTIME_DIR`, `XDG_CONFIG_HOME`,
`XDG_STATE_HOME`, and `HOME` at it before `require("wheel")`, and selects the
standalone POSIX backend explicitly. No Bitty plugin VM, plugin loader, or
plugin capability grant is involved.

The only host double is the presentation table `bitty`, carrying
`commands.register` and `notify.show`. It is a presentation boundary, not an
fs/process/temp/time mock: every filesystem, process, temporary-file,
wall-clock, and CPU-time operation in the harness under test is real OS
behavior through `WheelHost`. Lua 5.1 has no `os.setenv`, so the fixture's
bootstrap parent creates the ephemeral base and re-executes the child with the
private environment; the parent performs no harness operation.

The fixture asserts the exact 14 command ids in catalog order and the
eager/lazy module split, dispatches `hello` and checks the notification, and
exercises real filesystem, process, temporary-file, and tool paths
(`read_file`, `write_file`, `edit_file`, `list_directory`, `search_code`,
`run_command`). It also checks typed denials for `..` and absolute
outside-workspace paths, the destructive-command deny-list, the read-only role
gate, and unsupported backends. Activation is measured cold and warm with
`os.clock()` and a `debug.sethook` instruction count against RC-1 (10^7
instructions, 50 ms CPU, 8 ms warning); the series, interpreter, CPU, OS, and
revision are written to `recording/real-host-2026-10-21.md`, which is
gitignored durable scratch rather than a committed artifact.

Evidence limits: the fixture is offline and uses no credentials. It is
implementation evidence, not a release claim and not full Gate 2 evidence. It
does not cover process timeout, cancellation, process-group, or
scrubbed-environment bounds (CTX-0016), OS sandboxing, or a Bitty
panel/terminal presentation run. `os.clock()` measures process CPU time, not
elapsed wall clock; CPU frequency is not pinned, and one host runs one
interpreter per run. The record is not a canonical specification and does not
satisfy SECURITY-MODEL.md Gate 2 on its own.

### Offline and live tests

`just check`, `just test`, and CI are offline: they use mock providers and never
use a live credential for a request or reach the network. The live provider test
is a separate, manual, opt-in target:

```sh
OPENROUTER_API_KEY=... just test-live
```

- `just test-live` is not part of `just check` or CI. It runs the key-free
  redirect-policy test first, then skips the live portion with exit 0 and a
  clear message when `OPENROUTER_API_KEY` is absent.
- The live portion calls `deepseek/deepseek-v4.1-flash` through
  `https://openrouter.ai/api/v1` and covers a non-streaming completion, a tool
  call with parsed arguments, an SSE stream, and one runner ReAct turn with a
  stub tool.
- The credential stays in the environment. The Lua adapter is constructed
  without an API key; `tests/live_http_client.py` (Python standard library,
  test-only) reads `OPENROUTER_API_KEY` from its inherited environment and adds
  the authorization header after receiving a key-free request JSON over stdin.
  The key is never passed in argv, written to a request file, logged, or placed
  in a captured artifact, and the live test asserts it never appears in its
  captured output.
- The client refuses every HTTP redirect without a second hop, so the
  authorization header cannot be forwarded to another host or downgraded to
  plaintext HTTP. `tests/test_live_http_client_redirect.py` proves this against
  loopback servers for both a cross-host and a scheme-change 302; it requires no
  key and no external network.
- Every live request carries an explicit completion `max_tokens` from the named
  default or a validated override, so the provider's credit check cannot assume
  the model's maximum completion window.
- The test helper is not a production HTTP client and adds no runtime
  dependency; the harness provider boundary is unchanged.

## Authority

Wheel 0.1.0 runs as an independent harness process and holds the user's OS
authority under its own policy, not under a plugin manifest. Its one execution
backend is the standalone POSIX surface, selected explicitly by the host seam;
there is no plugin-host adapter and no `bitty.api_version` authority probe. The
owner-approved ceiling is:

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
activation, and no plugin compatibility is claimed. The typed failure contract
for this surface is documented under
[Troubleshooting](#command-error-contract).

## Release checklist (0.1.0)

1. Confirm `VERSION` is `0.1.0`, then run `just check`, `just package`, and
   `just verify-package` on the release revision. Record the archive digest,
   sidecar, and manifest; do not publish a plugin package or claim `plugin-api`
   compatibility.
2. Complete the controls in [SECURITY-MODEL.md](SECURITY-MODEL.md) for the
   approved ceiling, pass both evidence gates, and obtain independent security
   review of the authority and install paths.
3. Tag `v0.1.0` and publish the single harness artifact, its SHA-256 sidecar,
   and its manifest only after review and green CI. This task defines the
   artifact and validates the local path; it does not create the tag or release.
4. Replace this README's status note once the artifact is published and the
   evidence is recorded; keep the six user sections and the developer sections
   synchronized with that release.
5. Remove or retire the transitional `bitty-plugin.toml` and its SDK lint gate
   in a scoped follow-up; do not widen the manifest in the meantime.
6. Keep the repository free of secrets and of install scripts with ambient
   authority. The 0.1.0 installer is offline, digest-verified, and does not
   evaluate artifact content.

## Security

Report vulnerabilities through the process in [SECURITY.md](SECURITY.md), not a
public issue. The 0.1.0 harness holds workspace read/write, arbitrary argv,
shell command strings, network egress, and secret environment reads under the
policy in [SECURITY-MODEL.md](SECURITY-MODEL.md). Executable project
configuration requires explicit per-project trust, and secrets are read only
from a named allowlist and redacted before persistence. The repository contains
no credentials.

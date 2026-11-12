# Wheel

Wheel — the coding-agent harness for the Bitty terminal (mascot: Bittie the hamster). Independent out-of-process harness (`lua/wheel/`) for the `0.1.0` window.

> **Documentation & Ecosystem (`https://wheel.bitty.run`):** Because Wheel's configuration surface, multi-agent runtime, and companion plugins are extensive, this `README.md` stays concise as the repository and command-surface overview. Full configuration guides, architecture deep-dives, and Wheel-related plugins will live on the dedicated **`https://wheel.bitty.run`** documentation and ecosystem site (hosted from this repository). See [SECURITY-MODEL.md](SECURITY-MODEL.md), [CONTEXT-ARCHITECTURE.md](CONTEXT-ARCHITECTURE.md), and [CONTEXT-SNAPSHOT.md](CONTEXT-SNAPSHOT.md) for normative specifications in-tree.

## Overview

- **Independent harness process (Option B).** Wheel runs as its own OS process under the user's authority, governed by [SECURITY-MODEL.md](SECURITY-MODEL.md). A Bitty panel or terminal supplies presentation and input only.
- **Software-engineering domain only.** Roles (`Primary`, `Commander`, `Coding`, `Debug`, `Research`, `Reviewer`) vary by configuration and capability bindings (`RoleBinding` + monotonic `policy_generation`), never by class explosion.
- **One artifact for `0.1.0`.** `dist/wheel-0.1.0.tar.gz` ships the Lua module tree and core reference docs. The in-tree `bitty-plugin.toml` is retained only as a transitional artifact and is not the `0.1.0` distribution or authority model.
- **Daemon ownership stays with `bittyd`.** Final session hosting, IPC, attach/detach, lease generation, and worker supervision belong to `bittyd`. Wheel consumes that contract through the replaceable transport-injectable `WheelBittydAdapter` (`lua/wheel/bittyd_adapter.lua`); `scripts/wheel-session` remains a local development prototype.

## Install

Build, verify, and install the standalone `0.1.0` harness archive locally (offline after `just install`):

```sh
just install                        # bun install --frozen-lockfile (one-time dev setup)
just package                        # builds dist/wheel-0.1.0.tar.gz + .sha256 + .manifest.json
just install-local "$HOME/.local"   # installs under <prefix>/wheel/0.1.0 and switches current
just rollback-local "$HOME/.local"  # switches current back to the recorded previous version
```

Launch against the Lua 5.1 module root:

```sh
LUA_PATH="$HOME/.local/wheel/current/lua/?.lua;$HOME/.local/wheel/current/lua/?/init.lua;;" \
  lua5.1 -e 'local wheel = require("wheel"); print(wheel.command_catalog[1].id)'
```

- **Gate interpreter:** Lua 5.1 (`lua5.1` primary release gate; `luajit` and `lua` development fallbacks with JIT disabled for evaluated project-config chunks).
- **Platform:** POSIX hosts with GNU coreutils, `util-linux` (`setsid`), `tar`, and `gzip`.

## Commands

Wheel exposes 14 commands declared in `lua/wheel/init.lua` (`M.command_catalog`). Every command validates arguments against a closed schema before running and returns a bounded `{ title, body }` projection (`title <= 64` bytes, `body <= 8000` bytes).

| Command       | Invocation                         | Arguments schema                                                       | Result contract   |
| ------------- | ---------------------------------- | ---------------------------------------------------------------------- | ----------------- |
| `hello`       | `bitty-terminal.wheel:hello`       | No arguments; closed object, no properties.                            | `{ title, body }` |
| `status`      | `bitty-terminal.wheel:status`      | No arguments; closed object, no properties.                            | `{ title, body }` |
| `graph`       | `bitty-terminal.wheel:graph`       | No arguments; closed object, no properties.                            | `{ title, body }` |
| `plan`        | `bitty-terminal.wheel:plan`        | No arguments; closed object, no properties.                            | `{ title, body }` |
| `run`         | `bitty-terminal.wheel:run`         | No arguments; closed object, no properties.                            | `{ title, body }` |
| `trust`       | `bitty-terminal.wheel:trust`       | Optional object: `action` (`show`/`confirm`/`revoke`), `hash`, `path`. | `{ title, body }` |
| `team`        | `bitty-terminal.wheel:team`        | No arguments; closed object, no properties.                            | `{ title, body }` |
| `context`     | `bitty-terminal.wheel:context`     | No arguments; closed object, no properties.                            | `{ title, body }` |
| `tools`       | `bitty-terminal.wheel:tools`       | No arguments; closed object, no properties.                            | `{ title, body }` |
| `orchestrate` | `bitty-terminal.wheel:orchestrate` | No arguments; closed object, no properties.                            | `{ title, body }` |
| `models`      | `bitty-terminal.wheel:models`      | No arguments; closed object, no properties.                            | `{ title, body }` |
| `branch`      | `bitty-terminal.wheel:branch`      | No arguments; closed object, no properties.                            | `{ title, body }` |
| `checkpoint`  | `bitty-terminal.wheel:checkpoint`  | No arguments; closed object, no properties.                            | `{ title, body }` |
| `reflog`      | `bitty-terminal.wheel:reflog`      | No arguments; closed object, no properties.                            | `{ title, body }` |

## Configuration

This plugin declares no settings.

### Wheel harness configuration

Configuration is resolved by `lua/wheel/config.lua` across three layers (`WheelConfig.DEFAULTS`, `$XDG_CONFIG_HOME/wheel/init.lua`, and `.wheel/init.lua`) and gated by the executable project-config trust gate pinned in `$XDG_STATE_HOME/wheel/trusted_projects.json` (see [SECURITY-MODEL.md](SECURITY-MODEL.md#executable-project-configuration-trust-gate)). Comprehensive configuration examples and plugin docs will be published at `https://wheel.bitty.run`.

- **Function classes** (`lua/wheel/config.lua` schema):
  - `roles` — role definitions, capability narrowing, and model profile references.
  - `directives` — structured prompt directives applied across roles.
  - `tools` — tool allow/deny lists and custom tool declarations.
  - `skills` — session skill filters discovered from `.agents/`.
  - `verification` — change-gated verification declarations and test commands.
  - `context` — Three-Zone context budgets (64 KiB total: 16 KiB Zone 1, 32 KiB Zone 2, 16 KiB Zone 3) and 4 KiB spillover threshold.
  - `panel` — Headless Panel working-container policy.
  - `hooks` — lifecycle hooks.

## Keybindings

Wheel exposes commands, not keybindings. The Bitty host owns keybinding registration and dispatch, so Wheel registers no default keybindings and claims no key conflicts.

## Troubleshooting

### Command error contract

Every command crosses the typed failure boundary in `lua/wheel/errors.lua` and surfaces a three-field `{ class, code, message }` table:

| `code`                        | `class`      | Meaning                                                                                                                           |
| ----------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `E_CAPABILITY_DENIED`         | `runtime`    | The host removed a surface the command needs. The message names the missing capability family.                                    |
| `E_INTERNAL`                  | `runtime`    | The handler failed unexpectedly. The message is generic and never describes the underlying defect as a capability.                |
| `E_ARGS_INVALID`              | `validation` | Arguments did not match the command's closed `args_schema`; the handler did not run.                                              |
| `E_SCHEMA_INVALID`            | `validation` | A command's `args_schema` or `result_schema` was malformed or unbounded at registration.                                          |
| `E_RESULT_INVALID`            | `validation` | A handler result did not match its closed `result_schema`.                                                                        |
| `E_COMPLETION_BUDGET_INVALID` | `validation` | A completion-token bound override was zero, negative, non-integer, non-numeric, or above the named maximum.                       |
| `E_SNAPSHOT_INVALID`          | `validation` | A `WheelContext` snapshot failed format, bounds, hash, ref, reflog, or commit-graph validation; no context was built.             |
| `E_PROJECTION_INVALID`        | `validation` | A role-aware Context projection received malformed, cyclic, unsupported, out-of-scope, or over-budget input and failed closed.    |
| `E_MODULE_LOAD_FAILED`        | `resolution` | A Wheel submodule could not be loaded; the message names the rooted module and a bounded, path-free cause.                        |
| `E_AUDIT_UNAVAILABLE`         | `runtime`    | A local audit record could not be written; the message is static and never includes a path, value, or filesystem diagnostic.      |
| `E_JOB_NOT_FOUND`             | `runtime`    | The requested job record or its private root does not exist; no signal was sent.                                                  |
| `E_JOB_METADATA_INVALID`      | `runtime`    | A job record is malformed, unowned, wrongly moded, oversized, or names an invalid id/generation; no signal was sent.              |
| `E_JOB_GENERATION_MISMATCH`   | `runtime`    | The recorded leader generation, process group, session, or owner uid does not match the live retained leader; no signal was sent. |
| `E_JOB_NOT_RUNNING`           | `runtime`    | The job did not reach `running`, or its retained leader already exited without a terminal record; no signal was sent.             |
| `E_JOB_BUSY`                  | `runtime`    | The bounded terminal-transition lock stayed held; the request was refused rather than racing the transition.                      |
| `E_JOB_SIGNAL_FAILED`         | `runtime`    | The recorded process group could not be signalled after validation; the failure is reported without a fallback pattern kill.      |
| `E_JOB_UNAVAILABLE`           | `runtime`    | The private job root, random source, capture file, or bounded sleep is unavailable; no weaker execution path was used.            |
| `E_JOB_CLEANUP_FAILED`        | `runtime`    | A terminal job's private files could not be removed; the record was kept for diagnosis and no other path was deleted.             |

### Configuration failures

Named configuration failures returned by `lua/wheel/config.lua`: `untrusted_project_config`, `project_config_rejected`, and `project_config_eval_error`.

## Development

```sh
just install                  # bun install --frozen-lockfile
just check                    # lint, fmt-check, manifest, docs-check, lua parse, bittyd conformance, unit & offline suites
just test-bittyd-conformance  # run pinned Core bittyd-conformance-corpus/1 (V-29, V-30, V-33) against WheelBittydAdapter
just test-real-host           # opt-in real-host fixture (requires lua5.1)
just verify-package           # deterministic package build, install, upgrade, rollback, and refusal checks
```

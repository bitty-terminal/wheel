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
- **Daemon ownership stays with Bitty.** The experimental `wheel-session`
  daemon is a local/headless/development/CI prototype and transport reference,
  not Wheel's final daemon. Final lifecycle, IPC and authentication,
  attach/detach, session registry, generation, and worker supervision belong to
  `bittyd`
  ([bitty#2546](https://github.com/bitty-terminal/bitty/issues/2546),
  [bitty#2064](https://github.com/bitty-terminal/bitty/issues/2064),
  [bitty#2218](https://github.com/bitty-terminal/bitty/issues/2218)), which does
  not ship today. Wheel remains the Coding Agent Harness and will adapt through
  a replaceable transport adapter. No new Wheel daemon scope is added while
  that contract is pending.
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
- a long-lived session daemon or worker supervisor (the experimental
  `wheel-session` prototype is developer tooling; the final daemon belongs to
  `bittyd`)
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
- `LICENSE`, `README.md`, `SECURITY-MODEL.md`, and `CONTEXT-SNAPSHOT.md`.
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
modes independent of the caller's umask, and gzip without a name or timestamp
— so the same revision and packaging toolchain produce the same bytes and
digest. The digest provides
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
  fixture). `just test` prefers `lua5.1`, then `luajit`, then `lua`. LuaJIT is a
  development fallback, not the release gate; the evaluator disables the JIT for
  the project-config chunk so the instruction limit stays enforceable and the
  LuaJIT suite cannot hang.
- **Platform:** POSIX hosts with GNU coreutils, util-linux `setsid`, tar, and
  gzip; Linux is tested. Windows is not supported and macOS is not verified.
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
- Lua 5.1 for the release gate; the test and end-to-end recipes fall back to
  LuaJIT and then to a plain `lua` binary when `lua5.1` is absent. LuaJIT runs
  with the JIT disabled for evaluated project-config chunks.
- A POSIX host with standard shell utilities. Process execution additionally
  requires `env`, `sleep`, `mktemp`, `stat`, `id`, `ln`, GNU `timeout` (or
  Homebrew `gtimeout`), and util-linux `setsid` on `PATH`; without them the
  process/temp primitive fails closed as `unavailable` instead of running
  without a recorded process group, timeout, or verified private file. Windows
  support is not claimed.

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

What the commands display:

- `hello`: a greeting from Wheel (Bittie the hamster 🐹).
- `status`: kernel status, active task, checkpoint count, and telemetry.
- `graph`: an ASCII visualization of the Task DAG grouped into topological
  execution waves.
- `plan`: initialize or decompose software engineering tasks into the Task DAG
  (Commander role).
- `run`: execute ready tasks in the DAG using WheelAgent (Worker role).
- `trust`: inspect, approve, or revoke project configuration
  (`.wheel/init.lua`) with canonical-root and content-hash pinning. `trust`
  (or `trust show`) displays the bounded full entry, the diff against the
  previously trusted bytes, the full 64-hex SHA-256, and the canonical root;
  `trust confirm <sha256>` requires that exact current hash; `trust revoke`
  removes the record. No command argument is a `--yes` approval.
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

Thirteen commands accept no arguments: `args_schema` is a closed object with no
declared properties, so any supplied field is rejected with `E_ARGS_INVALID`
(class `validation`) before the handler runs. `trust` is the one optional
argument object (`action`, `hash`, `path`); unknown fields are still rejected.
Each command returns the notification projection it displays, `{ title, body }`,
so CLI, palette, IPC, and agent consumers can type the result without scraping
presentation text. `trust show` is the exception in content volume: its full
escaped entry and diff are delivered as a notification series, and its returned
`{ title, body }` is a bounded consent summary (canonical root, full hash,
status, store state, and chunk count). The
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
    to `$HOME/.local/state/wheel/trusted_projects.json`; there is no `/tmp` or
    other predictable fallback. When neither variable is set, trust operations
    fail closed. The directory is created `0700` and the file `0600`, written
    with a same-directory temporary file plus atomic rename. A symlinked,
    non-regular, foreign-owned, group/world-writable, oversized, corrupt, or
    foreign-version store fails closed and surfaces a warning; it is never
    silently read as an empty approving store. Confirmation may repair a
    group/world-writable but user-owned real parent to `0700`, then re-reads the
    store before writing; a foreign, symlinked, or non-directory parent remains
    fatal and no write occurs. Schema version 1 records
    `{hash, content, approved_at}` per canonical root; legacy flat string
    hashes are accepted as hash-only and migrated on the next approval.
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
  - Approval is an explicit interactive action. `trust` (or `trust show`)
    resolves the canonical project root through the host (`realpath`,
    `readlink -f`, or `cd -P ... && pwd -P`), rejects a symlinked, non-regular,
    or larger-than-32-KiB entry before hashing, and displays the bounded full
    entry, a pure-Lua line diff against the previously trusted content, the
    full 64-hex SHA-256, and the canonical root. Every content and diff line is
    escaped (non-printables as `\xNN`) and prefixed inside a per-run nonce
    delimiter, so a forged marker or control byte cannot look like the real
    boundary. A truncated preview is not sufficient consent.
    `trust confirm <sha256>` re-reads the entry and writes the record only when
    the supplied hash equals the exact current bytes. There is no
    trust-on-first-use, no inherited trust, and no `--yes` default.
  - A concrete entry-specific effects list cannot be produced without evaluating
    the entry. The consent view says so explicitly, states the class of effects
    the configuration surface can request, and does not evaluate the entry
    before confirmation; effects are applied only when a later configuration
    load reads the approved record under the restricted evaluator.
  - The trust record binds the canonical project root and the entry hash in
    `$XDG_STATE_HOME/wheel/trusted_projects.json`. Any content change, including
    whitespace, invalidates trust and forces re-approval with a diff.
  - `trust revoke [path]` removes the canonical record and any alias or legacy
    keys that resolve to the same root, without requiring entry files.
    Revocation and store deletion remove trust. A missing, corrupt, or
    unreadable store fails closed; it is never recreated with existing
    approvals.
  - Evaluation runs in a restricted environment with no filesystem, process,
    network, environment, or module-loading access. `pcall`/`xpcall` are
    removed so the instruction-hook error is not catchable; `string.rep` and
    `table.concat` carry per-call and cumulative byte caps for direct and
    method-call forms by patching the real string/table tables for the eval
    duration and restoring them on every path. These are best-effort bounds,
    not a wall-clock or heap sandbox: `string.format`, pattern matching,
    concatenation, sort comparators, and other C-library allocations are not
    metered, and a killable evaluation subprocess remains future work (see
    [SECURITY-MODEL.md](SECURITY-MODEL.md#relationship-to-current-code)).
  - Project configuration may narrow behavior inside the approved ceiling. It
    may not add a workspace root, network destination, secret name, or authority
    for a role, and it may not disable audit, redaction, the deny-list, the path
    sandbox, or the trust gate. The loader does not yet enforce every field or
    narrowing rule; a trusted entry is user-approved code, not a validated data
    contract.
- **Current trust-gate gaps.** Canonical-root pinning, escaped full-content
  consent, pure-Lua diff-on-change, exact-hash confirmation, user-facing
  revocation, bounded reads, native hashing, atomic `0700`/`0600` store writes,
  matched store read/write caps (256 projects and 1 MiB), and the removed
  `pcall`/`xpcall` path are implemented and covered by unit plus real-host
  tests. Field validation and
  narrowing-only enforcement of the merged configuration are still absent: a
  trusted config can set fields the policy expects the loader to reject.
  Evaluation remains in-process with best-effort instruction and string/table
  bounds; direct and method forms of `string.rep`/`table.concat` are capped,
  but `string.format`, patterns, concatenation, sort comparators, and other
  C-library allocations are not metered. The execution audit sink exists, but
  trust approval does not yet write through it, so approval cannot yet fail
  closed on an audit write. The store is not tamper-proof against same-user
  processes and is not fsynced or signed. Native hashing and host primitives
  resolve
  `sha256sum`/`shasum`/`openssl`, `realpath`/`readlink`, `stat`, `test`, `id`,
  and `mktemp` through `PATH`, which is same-user authority. `trust_file` and
  `global_path` are internal call-site/test overrides, not command or
  environment inputs. The consent result body is a host-body-bounded summary;
  the notification series is authoritative, a line longer than a notification
  chunk may span bodies under the same nonce, and zero-byte entries or stores
  are refused as unreadable rather than treated as empty. See
  [SECURITY-MODEL.md](SECURITY-MODEL.md#relationship-to-current-code); this
  inventory is not a claim of compliance. The independent review that closes
  wheel#54 is recorded in
  [SECURITY-MODEL.md](SECURITY-MODEL.md#security-review-record).
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

`E_COMPLETION_BUDGET_INVALID` is raised by the provider adapters and
`WheelRunner` before a network request when a `max_completion_tokens` override
fails validation; it is not a command argument failure.

`E_SNAPSHOT_INVALID` is raised by `export_snapshot`, `import_snapshot`,
`validate_snapshot`, and `canonical_snapshot` when snapshot state fails
validation. Validation completes before any new context is exposed. The message
is a bounded schema path and reason; slot content is never included (schema paths
may name caller-provided slot, ref, or event keys). Invalid snapshot options are
argument failures and use `E_ARGS_INVALID`. Snapshot v1 does not restore stash
entries, bus subscribers, the kernel link, `config` directives, or budget
configuration; stash event slot payloads are redacted on export and again by
validation on import, so a crafted or pre-fix unredacted snapshot cannot restore
them. The format and bounds are documented in
[CONTEXT-SNAPSHOT.md](CONTEXT-SNAPSHOT.md).

`E_PROJECTION_INVALID` is raised by `WheelContext:project` and
`WheelContext:semantic_delta` when caller-owned records, scopes, or budgets do
not satisfy the bounded plain-data projection contract. Unknown slot prefixes
and records excluded by a role lens or explicit scope are omitted with bounded
references and provenance; malformed values are rejected before projection.

`E_MODULE_LOAD_FAILED` is raised at activation when a required Wheel submodule
cannot be loaded, or on first use when an optional lazy submodule fails. The
message names the rooted module (for example `wheel.agent`) and keeps only a
bounded, path-free cause; no stack trace, host path, or secret is included.

`E_AUDIT_UNAVAILABLE` is returned or attached by the process seam when the
local audit sink cannot write:

- a high-risk pre-spawn failure returns the typed failure with
  `spawned = false`, no `audit_warning`, and the command is not launched;
- a lower-risk pre-spawn failure runs the command, sets `audit_warning`, and
  leaves `audit_error` unset;
- a completion-record failure after a launched command sets both
  `audit_error` and `audit_warning` (the command already ran);
- a denied command whose deny record cannot be written returns `denied = true`,
  `spawned = false`, and sets both fields, but still does not launch.

Its message is the fixed `the audit record could not be written`; the sink's
reason code (`no_state_dir`, `audit_directory`, `audit_file`, `audit_corrupt`,
`rotation_failed`, `write_failed`, `record_too_large`, `hash_unavailable`,
`invalid_event`) is the static failure class and never a path or value.

The `E_JOB_*` codes are raised only by the recorded-process cancellation
surface (`WheelHost.proc.start`/`handle:cancel` and `scripts/wheel-proc`). They
cover a missing record, malformed or foreign metadata, a generation/process-group
mismatch, an unpublished or already-exited leader, a busy transition lock, a
failed signal after validation, an unavailable private job root, and a failed
cleanup of an already terminal record. A refusal never signals anything; the
message never includes a job id, generation token, pid, or path.

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

Named configuration failures returned by `lua/wheel/config.lua`: `untrusted_project_config`, `project_config_rejected`, and `project_config_eval_error`.

- `untrusted_project_config` — the project entry exists but its content hash is
  not approved in the trust store, or the store is corrupt/insecure. The loader
  returns the safe defaults plus the global layer, marks `layers.project =
false`, and does not evaluate the entry. Inspect it with `trust`, then
  `trust confirm <sha256>` or `trust revoke`.
- `project_config_rejected` — the entry could not be inspected safely: the
  project root is unresolvable, the entry is a symlink or non-regular file, it
  exceeds the 32 KiB cap, or no SHA-256 implementation is available. The entry
  is never evaluated. The `code` field carries the specific
  `E_PROJECT_CONFIG_*` reason.
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
- `E_SNAPSHOT_INVALID` — a `WheelContext` snapshot is malformed, tampered,
  oversized, partial, or cryptographically inconsistent. Re-export from the live
  context instead of editing the snapshot table; see
  [CONTEXT-SNAPSHOT.md](CONTEXT-SNAPSHOT.md).
- `E_AUDIT_UNAVAILABLE` — the local audit sink could not write a record. A
  high-risk spawn is refused before launch; a lower-risk pre-spawn failure runs
  the command with `audit_warning` and no `audit_error`; a completion failure
  after launch sets both fields; a denied command whose record cannot be
  written remains denied with both fields. Check that
  `$XDG_STATE_HOME/wheel/audit` (or the explicit override) is a real,
  user-owned `0700` directory with no symlink, and that the active `0600`
  JSONL file has a complete last line. A torn or corrupt tail blocks the next
  append; corruption in an earlier retained line does not block appends and is
  reported by `WheelAudit.verify`. The sink never repairs a torn or corrupt
  tail silently.
- `unavailable` from the temp/process primitive — check `mktemp`, `ln`,
  `setsid`, `sleep`, `env`, `timeout`/`gtimeout`, `stat`, `id`, and `sh` on
  `PATH`; these
  are documented host prerequisites. Temp files are created with `mktemp` and
  verified as user-owned regular `0600` files with link count 1; FIFOs, devices,
  symlinks, and pre-existing paths are refused.
- `timed out` or `unavailable` from `run_command`/`search_code` — the process
  primitive maps GNU timeout expiry to exit code 124/137 and fails closed with
  `unavailable` when `env`, `sleep`, `timeout`/`gtimeout`, `setsid`, or `sh` is
  missing from `PATH`. Install GNU coreutils (or Homebrew coreutils for
  `gtimeout`) and util-linux; the harness never falls back to unbounded
  execution, an unrecorded process group, or an inherited environment. The
  recorded process group is held by a retained session leader through the
  TERM/grace/KILL sweep; if that leader is lost, the result reports
  `cleanup = unverified` and no signal is sent.
- session control-plane failures from `scripts/wheel-session` — the request
  failed closed. A not-running code means no live metadata/FIFO pair; a busy
  code means another client holds the per-session lock; an unsafe-path code
  means the session directory, metadata, or FIFO is a symlink, foreign-owned,
  or not `0700`/`0600`; a frame-too-large code means a request exceeded 64 KiB;
  a start-mismatch code means the live metadata belongs to a different starter
  and was not adopted. A start-failed code usually means `setsid`, `mkfifo`,
  `kill`, or a Lua interpreter is unavailable. The daemon writes no log content;
  diagnose with probe/status and correct the path.
- a session daemon is unreachable but its pid still exists — the control plane
  never force-kills an unverified pid. Confirm the recorded pid in
  `meta.json`, then stop it explicitly with `wheel-session stop` or, after
  manual verification, signal that exact pid. Deleting a live session
  directory leaves the daemon unreachable; it must be stopped by its recorded
  pid. This prototype has no attach/reattach, generation, or worker-supervision
  contract; see [Continuation boundary](#continuation-boundary).
- `just manifest` rejects `bitty-plugin.toml` — the transitional manifest is
  unchanged by the harness position; fix the manifest or the SDK pin rather than
  widening it.

## Layout

| Path                                      | Purpose                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`                               | Canonical user document: the six required H2 sections plus developer and architecture reference.                                                                                                                                                                                                                           |
| `CONTEXT-SNAPSHOT.md`                     | WheelContext snapshot v1 format, canonical encoding, bounds, integrity limits, trust boundary, and excluded state.                                                                                                                                                                                                         |
| `bitty-plugin.toml`                       | Transitional v1 plugin manifest (identity, compatibility, capability requests, lazy triggers). Retained unchanged by CTX-0010; not the 0.1.0 distribution path, and removal is a follow-up.                                                                                                                                |
| `lua/wheel/init.lua`                      | Harness entry point and legacy command surface (14 command definitions: `hello`, `status`, `graph`, `plan`, `run`, `trust`, `team`, `context`, `tools`, `orchestrate`, `models`, `branch`, `checkpoint`, `reflog`).                                                                                                        |
| `lua/wheel/errors.lua`                    | Typed command failure boundary: capability denials in the accepted bridge shape, validation failures, and a Wheel-local generic internal error.                                                                                                                                                                            |
| `lua/wheel/schema.lua`                    | Bounded command schema validator: finite vocabulary, registration admission, invocation argument checks, and typed validation failures.                                                                                                                                                                                    |
| `lua/wheel/commands.lua`                  | Command registration layer: no-argument/result schema factories, host-bounded result truncation, argument/result dispatch checks.                                                                                                                                                                                          |
| `lua/wheel/config.lua`                    | WheelConfig loader: hierarchical layering, executable project-config trust gate, and skill capability discovery.                                                                                                                                                                                                           |
| `lua/wheel/host.lua`                      | WheelHost authority seam: explicitly selected standalone POSIX backend for filesystem, process, temporary-file, wall-clock, and CPU-time primitives; synchronous run primitives plus the asynchronous job handle (`start`/`poll`/`wait`/`cancel`/`close`); typed denials on unsupported platforms or unavailable surfaces. |
| `lua/wheel/job.lua`                       | Private process-job record and recorded-group cancellation: `0700`/`0600` metadata, random job/generation tokens, generation validation against the live retained leader, TERM/grace/KILL, terminal-reason lock, and typed job failures.                                                                                   |
| `lua/wheel/audit.lua`                     | Local append-only execution audit sink: `0700`/`0600` JSONL, 16 KiB records, 1 MiB x 4 rotation, SHA-256 previous-hash chain, redaction markers, cancellation fields, size-based tail refresh for sequential cross-process writers, and typed `E_AUDIT_UNAVAILABLE` failures.                                              |
| `lua/wheel/kernel.lua`                    | WheelKernel Lua client: JSON-RPC dispatch, DAG control plane, Merkle slots, cognitive checkpoints.                                                                                                                                                                                                                         |
| `lua/wheel/agent.lua`                     | WheelAgent runtime: Headless Panel working containers, Commander, Worker (Coding, Debug, Research), and Reviewer roles.                                                                                                                                                                                                    |
| `lua/wheel/team.lua`                      | WheelTeam coordinator: multi-agent peer colleague collaboration, autonomous wave orchestration, atomic claims, and handoffs.                                                                                                                                                                                               |
| `lua/wheel/context.lua`                   | WheelContext engine: shared semantic slots, CAS concurrency, ContextBus pubsub, 3-way merge, and Three-Zone prefix-cache compiler.                                                                                                                                                                                         |
| `lua/wheel/context_snapshot.lua`          | Versioned snapshot schema validation, bounded plain-data copying, and canonical encoding for WheelContext.                                                                                                                                                                                                                 |
| `lua/wheel/session.lua`                   | Local session control plane (client/shared): bounded strict JSON framing, session-name and private-path validation, metadata, serialization lock, and RPC.                                                                                                                                                                 |
| `lua/wheel/daemon.lua`                    | Detached session daemon: owns one WheelContext, serves the `wheel-session/1` methods over private FIFOs, and shuts down explicitly.                                                                                                                                                                                        |
| `lua/wheel/session_cli.lua`               | Script entry point used by `scripts/wheel-session`; bootstraps the module path and prints structured results.                                                                                                                                                                                                              |
| `lua/wheel/tool.lua`                      | WheelTool engine: standardized ActionIntent protocol, path sandboxing, core tools, role gating, and auto-spillover pipeline.                                                                                                                                                                                               |
| `lua/wheel/provider.lua`                  | WheelProvider abstraction: line-buffered SSE streaming parser, tool formatters, and adapters (Mock, OpenAI, Anthropic, Stdio).                                                                                                                                                                                             |
| `lua/wheel/rationale.lua`                 | Bounded provider-neutral rationale schema and deterministic malformed-output fallback; private thinking remains transient.                                                                                                                                                                                                 |
| `lua/wheel/runner.lua`                    | WheelRunner execution loop: autonomous ReAct turn loop, streaming token callbacks, tool dispatch, and checkpointing.                                                                                                                                                                                                       |
| `lua/wheel/ui.lua`                        | WheelUI visualizer: ASCII Task DAG, topological wave decomposition, and telemetry renderer.                                                                                                                                                                                                                                |
| `tests/test_wheel.lua`                    | Comprehensive test suite covering kernel dispatch, agent role loops, UI rendering, configuration layering, trust gates, and README contract parity.                                                                                                                                                                        |
| `tests/test_context_snapshot.lua`         | Focused snapshot tests: round-trip, tamper, bounds, reflog wrap, stash redaction, caller-bus behavior, and canonical ordering.                                                                                                                                                                                             |
| `tests/test_live_provider.lua`            | Opt-in live test (`just test-live`) selected by `WHEEL_LIVE_PROVIDER` (OpenRouter default, Command Code): complete, tool call, stream, and runner.                                                                                                                                                                         |
| `tests/test_session.lua`                  | Integration suite for the local session daemon: real detached start, cross-process context reads, snapshots, shutdown, invalid/oversized frames, unsafe paths, and stale-pid recovery.                                                                                                                                     |
| `tests/test_audit.lua`                    | Execution-audit suite (`just test-audit`): append/rotation, private modes, hash chain, redaction, 16 KiB bounds, high-risk fail-closed, non-high-risk warning, and denied no-spawn behavior.                                                                                                                               |
| `tests/test_cancel.lua`                   | Real cancellation suite (`just test-cancel`): separate CLI process, prompt terminal result, no orphan/unrelated signal, repeated cancel, timeout/cancel race, forged/stale generation refusal, and audit.                                                                                                                  |
| `tests/live_http_client.py`               | Test-only stdlib HTTP transport for `just test-live`; reads the selected provider key, binds HTTPS to its host, rejects redirects, and never accepts the key via argv, files, or JSON.                                                                                                                                     |
| `tests/test_bench.lua`                    | Benchmark harness tests: statistics, strict argument parsing, deterministic JSON, fail-closed CLI behavior, and short offline scenario runs.                                                                                                                                                                               |
| `bench/`                                  | Offline benchmark suite (`bench/README.md`): activation, process, runner, orchestration, and context scenarios with human and JSON output.                                                                                                                                                                                 |
| `tests/test_live_http_client_redirect.py` | Key-free loopback negative test: the HTTP client refuses cross-host and scheme-change 302 redirects and forwards no Authorization header.                                                                                                                                                                                  |
| `tests/test_live_provider_selection.py`   | Key-free offline selector test: default/case-insensitive selection, per-provider key and host binding, HTTPS-only requests, and fail-closed diagnostics.                                                                                                                                                                   |
| `tests/e2e_cross_process.lua`             | End-to-end integration test suite exercising all 11 lifecycle stages against the real Rust `wheel_stdio_host` binary over Unix FIFOs.                                                                                                                                                                                      |
| `VERSION`                                 | Canonical harness version (`0.1.0`); the single source used by `just package`.                                                                                                                                                                                                                                             |
| `scripts/package.sh`                      | Deterministic artifact builder: archive, SHA-256 sidecar, and manifest; fails closed on dirty inputs.                                                                                                                                                                                                                      |
| `scripts/install-local.sh`                | Offline install/upgrade/rollback under `<prefix>/wheel/<version>` with digest, prefix, ownership, and symlink checks.                                                                                                                                                                                                      |
| `scripts/wheel-session`                   | POSIX shell CLI for the experimental local session daemon: start/stop, ping/status/snapshot, context put/get/list, and bounded client calls.                                                                                                                                                                               |
| `scripts/wheel-proc`                      | POSIX shell cancellation client: `cancel <job-id>`, explicit `--root`, bounded grace, one JSON result, and no name/pattern signal.                                                                                                                                                                                         |
| `scripts/verify-package.sh`               | Builds, installs, runs the real-host fixture on the installed tree, upgrades, rolls back, and tests refusals.                                                                                                                                                                                                              |
| `dist/`                                   | Gitignored package output (`wheel-<version>.tar.gz`, `.sha256`, `.manifest.json`).                                                                                                                                                                                                                                         |
| `package.json`                            | Pinned dev dependencies: the `bitty-plugin-sdk` commit (manifest linter and README docs checker) and `luaparse`.                                                                                                                                                                                                           |
| `bun.lock`                                | Locked dependency graph installed by `just install`.                                                                                                                                                                                                                                                                       |
| `justfile`                                | Quality gates with pinned tool versions, including the SDK README checker in `just check` and the package/install recipes.                                                                                                                                                                                                 |
| `.github/workflows/ci.yml`                | CI gate with a read-only token and SHA-pinned actions.                                                                                                                                                                                                                                                                     |

## Architecture

### Headless Panel Working Container Invariant

Under Bitty Core Rule R1, `ExecutionContext` is primary: panels describe presentation and view projections, not execution authority (`PanelId != ViewId != TerminalId`). Every Wheel agent defaults to running in an isolated **Headless Panel working container** (`panel_id = "headless:panel:<agent_name>"`, `headless = true`), binding its execution environment without requiring desktop screen rendering. Presentation UI panels are optional observation projections.

### Shared Context Memory & Prefix-Cache Optimization

Wheel coordinates peer colleague agents through content-addressed shared state:

- **Semantic Slots & CAS**: Structured slots (`workspace/*`, `tasks/<id>/*`, `decisions/*`, `scratch/*`) with optimistic Compare-And-Swap (`expected_version`) concurrency control and Merkle tree root hashing (`tree:v1\0`).
- **Semantic 3-Way Merge**: Non-conflicting additions or edits merge automatically; concurrent edits surface structured conflict records for explicit resolution.
- **Context Event Bus**: Real-time in-memory pubsub (`ContextBus`) notifying peer agents of slot modifications, checkpoint commits, and task handoffs without polling.
- **Three-Zone Prompt Compiler**: Pinned, byte-stable **Zone 1 (Stable Prefix)** shared across agents of the same model family for maximum KV cache reuse (>90%), coupled with a multi-tier budget reduction pipeline (Tier 1 scratchpad pruning, Tier 2 rationale compression, Tier 3 tail truncation).

### Context Graph Projections (CTX-0037)

`WheelContext:project(opts)` is the deterministic source for role- and
task-specific prompt inputs. It reads immutable Context commits and
caller-owned structured records; it does not read conversation transcripts,
persist Agent/Panel lifecycle state, summarize with an LLM, or add a `bittyd`
surface. Every result records `base_commit`, `current_commit`, role, task and
session identifiers, byte budgets, provenance, and explicit omitted
references.

The projection keeps five inputs separate:

- **P0 project knowledge** — eligible architecture, accepted decisions,
  documentation, security facts, and workspace knowledge.
- **P1 role lens** — marker-only deterministic category selection for Planner,
  Documentation, Coding, Debug, Research, and Reviewer; it is not caller
  content.
- **P2 task projection** — task-scoped slots and structured records.
- **P3 session delta** — structured added/modified/removed records between
  immutable commits, never raw string subtraction.
- **P4 recent tail** — explicitly supplied recent structured records, ordered
  newest-first with a reference for every omitted record.

Caller record categories are derived from the record reference prefix using
Wheel's explicit category allowlist; caller metadata cannot widen a scope.
Transitions are admitted only when both structured sides pass the same role and
scope eligibility predicate. A record matching both the active task and
session is assigned to P2 and not repeated in P4.

Caller-owned projection values use the snapshot plain-data depth and node
policies. Validation, copying, and canonicalization all enforce the named
`WheelContext.MAX_PROJECTION_VALUE_DEPTH` depth bound and fail with
`E_PROJECTION_INVALID` before deeply nested data can exhaust the Lua stack.

The default per-layer budgets are 16 KiB, 8 KiB, 16 KiB, 16 KiB, and 8 KiB
respectively. Selection is byte-bounded and deterministic: records are sorted
by stable reference (with P4 using timestamp then reference), and records that
do not fit are omitted rather than silently truncated. `semantic_delta` is
available independently when a structured change set is needed before prompt
compilation. `total_bytes` and `canonical_bytes` describe the rendered,
selected layer content; projection metadata remains separately structured and
does not silently consume the layer content budget. These are Wheel context
budgets, not provider cache controls.

### Standardized Action Protocol & Tool Execution Engine

Wheel executes software engineering tools under policy gates and bounded
context budgets:

- **Action Intents**: Typed action intents (`Inspect`, `Modify`, `Execute`, `Verify`, `Custom`) aligned with upstream Rust architecture (`bitty-ai-slice`).
- **Path Sandboxing**: Lexical workspace-boundary verification (`sanitize_path`) rejects `..` traversal and absolute paths outside the root. Symlink target resolution, non-regular file rejection, and atomic writes are required by [SECURITY-MODEL.md](SECURITY-MODEL.md) and are not yet evidenced.
- **Role Authority Gating**: `Research` and `Reviewer` roles are strictly read-only and fail-closed on `Modify` or `Execute` intents; `Commander` plans and orchestrates without direct file mutation.
- **Catastrophic Command Protection**: Pattern scanning against a deny-list subset (`rm -rf /`, `mkfs`, fork bombs, and similar). It is defense-in-depth, not a sandbox; the missing categories and limits are recorded in [SECURITY-MODEL.md](SECURITY-MODEL.md).
- **Auto-Spillover Observation Pipeline**: Oversized tool output (> 4 KiB) is automatically persisted as a content-addressed blob in context memory (`blobs/<hash>`), providing bounded head/tail previews to preserve the context window while ensuring full byte-exact recovery via `read_blob`.
- **Core Engineering Tools**: Built-in pure Lua implementations of `read_file` (bounded chunked reads; line ranges apply inside the bounded prefix, a `start_line` beyond it fails loud, and a prefix ending inside an included line reports `truncated=true` with a marker), `write_file` (truncating write with directory creation; atomic replace not yet implemented), `edit_file` (exact target replacement), `run_command` (bounded process execution with a timeout, a `setsid`-recorded process group held by a retained leader through the TERM/grace/KILL sweep, scrubbed environment, typed timeout/unavailable/cleanup outcomes, and metrics), `list_directory` (fails closed on `ls` errors/timeouts), `search_code` (bounded `grep` capture before the 100-line observation cap; grep errors fail closed), and `read_blob`.

### Process Cancellation (CTX-0034)

`WheelHost.proc.start(program, args, opts)` starts a bounded command without
blocking and returns a handle with `poll()`, `wait(timeout_ms)`, `cancel(opts)`,
and `close()`. `run_program` and `run_command` keep their synchronous contract;
they do not expose the handle. A job is one private `0700` directory under
`$XDG_RUNTIME_DIR/wheel/jobs` (or the explicit `opts.job_root`) containing an
owned `0600` metadata record: a 32-hex job id, a random generation token, the
recorded leader PID/PGID, the timeout, and optional audit identity. Capture
files are `0600`; a caller passes the job id to the external client, plus
`--root` when the job uses an explicit non-default job root.

```sh
scripts/wheel-proc cancel <job-id> [--root <job-root>] [--grace-ms <ms>]
```

The CLI validates the id, metadata ownership/mode/size, and the live retained
leader's generation and real/effective uid (`/proc/<pid>` on Linux, with a
`ps -ww` fallback), then signals only the recorded process group. A foreign or
credential-transitioned leader is refused with `E_JOB_GENERATION_MISMATCH`
before any signal. The backend accepts signal 0 for a liveness probe and
TERM/KILL for cancellation; the CLI uses TERM/KILL only. There is no name- or
pattern-based kill.
The request sends TERM while holding the terminal-transition lock, publishes
`cancelled` before releasing it, then waits the bounded grace (250 ms by
default, at most 2 s) and sends KILL to the same recorded group only if the
leader is still present. A refused TERM never leaves a `cancelled` terminal
record behind. The retained leader ignores TERM while it waits for the direct
child, so the recorded PGID cannot be reused during the sweep; the leader's
normal TERM/grace/KILL sweep still runs after the direct child exits.

The result distinguishes cancellation from timeout: `cancel_requested = true`,
`terminal_reason = "cancelled"`, `outcome = "cancelled"`, and `timed_out = false`.
A timeout keeps `terminal_reason = "timeout"` and `timed_out = true`. Repeated
cancellation is idempotent (`already_requested`/`already_cancelled`); a job that
already published `exited` or `timeout` is a typed no-op (`already_exited`, CLI
exit 3, no signal); a missing or unpublished job is refused (`E_JOB_NOT_FOUND`
or `E_JOB_NOT_RUNNING`) before any signal. A tampered generation, process group,
session, or owner uid is refused with `E_JOB_GENERATION_MISMATCH`; a foreign PID
is never signaled.

When `opts.audit` is supplied to `start`, the pre-spawn record is followed by
`process.cancel_requested`, `process.cancel_outcome`, and a completion record
carrying `cancel_requested`, `terminal_reason`, and `outcome = "cancelled"`.
A high-risk cancellation whose request record cannot be written is refused
before any signal; a low-risk failure continues with `audit_warning`. The audit
sink re-reads its tail when another process appended, so the sequential CLI and
harness writers continue one chain; simultaneous appenders remain the documented
cross-process residual.

`just test-cancel` starts real long commands, cancels them from the separate
`scripts/wheel-proc` process, and checks prompt exit, no child/grandchild orphan,
no signal to an unrelated recorded job, repeated cancel, timeout/cancel
distinctness, the timeout race, forged/stale generation refusal, and the
cancellation audit. The real-host fixture also exercises the handle path and,
in a development checkout, the CLI path. The 0.1.0 library artifact does not
package `scripts/`, so the installed-tree fixture uses the handle API; the CLI
is a checkout/operator surface. Cancellation is same-user only: a same-user
process can read the private job record and act with the same OS authority.
Cross-user isolation is not claimed, and Windows remains unsupported (the
standalone host and the POSIX shell client fail closed). A child that calls
`setsid` or joins another process group can still leave the recorded group; that
orphan residual is unchanged.

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
  - `StdioAdapter`: Subprocess CLI runner for `ollama run`, `llm`, or local model binaries. The command is parsed into argv (or supplied as an argv table), shell syntax is refused, and the prompt is delivered on stdin through the bounded `WheelHost.proc.run_program` primitive; no shell redirection or prompt temp file is used.
- **Tool Schema Normalization**: Automatic formatting of `WheelTool` definitions to OpenAI (`type="function"`) and Anthropic (`input_schema`) function calling specifications.
- **Bounded Completion Budget**: Every OpenAI-compatible and Anthropic HTTP provider request carries an explicit completion `max_tokens` from `WheelProvider.DEFAULT_MAX_COMPLETION_TOKENS` (4096) or a validated `max_completion_tokens` override, bounded at 32768. The stdio adapter has no completion-token field and is outside this boundary. The context window remains a separate `context_budget`; zero, negative, non-integer, non-numeric, and oversized overrides fail with a typed `E_COMPLETION_BUDGET_INVALID` error before an HTTP request is sent.
- **Bounded Rationale Records**: Runner checkpoints and `tasks/<id>/rationale` Context slots contain only the versioned `wheel-rationale/1` fields `decision`, `evidence`, `uncertainty`, `risk`, `rejected_alternatives`, and `next_action`, plus task/session links. Each field and list is bounded and passes the shared audit redaction boundary before persistence. Provider thinking/reasoning remains transient and is never replayed into a later prompt; missing, prose-only, truncated, or malformed structured output receives a deterministic fallback. Thinking stream chunks remain distinguishable from content and tool-call events.
- **Autonomous ReAct Turn Runner**: Multi-turn execution loop (`WheelRunner.run_task`) combining Three-Zone context compilation, distinguishable thinking/content/tool streaming callbacks, bounded rationale records, path-sandboxed tool dispatch with auto-spillover, and automated checkpoint commits.

### Git-Inspired Context Versioning Engine

Wheel models agent context as an immutable, content-addressed versioned DAG inspired by Git principles:

- **Checkpoints as Commits**: Checkpoints bind a Merkle context tree snapshot, parent commit hashes, author, task ID, structured 6-field `Rationale`, and timestamp into a deterministic 64-hex SHA-256 commit hash (`commit:v1\0`).
- **Branching & Checkout**: Cheap context branching (`refs/heads/*`) for isolated hypothesis exploration. Checking out a branch or detached commit automatically restores working slots to that historical snapshot without transcript loss.
- **Reflog Recovery Journal**: Every `HEAD` movement (commit, branch, checkout, reset, merge) appends an immutable entry to `refs/reflog`, ensuring catastrophic rollback recovery and full auditability.
- **Context Stash**: In-progress uncommitted working slot modifications can be suspended (`stash_push`) before switching context and cleanly restored (`stash_pop`, `stash_drop`).
- **3-Way Semantic Merge & Fast-Forward**: Merges branches semantically by computing the lowest common ancestor (LCA) in the commit DAG; non-conflicting slot deltas merge automatically, while conflicting slots are preserved with structured diagnostics in `decisions/conflicts/*`.
- **Cherry-Pick**: Imports specific findings, artifacts, or decisions from foreign branches (`cherry_pick`) without pulling along entire branch histories or transcripts ("parents absorb conclusions, never transcripts").
- **Task-Isolated Workflows**: Multi-agent wave orchestration supports running worker tasks in dedicated task branches (`task/<id>`), merging deliverables into `main` upon reviewer acceptance.

### Local Session Daemon (Experimental)

> **Prototype, not the final daemon.** `scripts/wheel-session` is an
> experimental local/headless/development/CI prototype and a transport
> reference. It is same-user only and is not a substitute for `bittyd`, which
> owns the final lifecycle, IPC and authentication, attach/detach, session
> registry, generation, and worker supervision. `bittyd` does not ship today.
> Wheel remains the Coding Agent Harness and will adapt through a replaceable
> transport adapter; no new Wheel daemon scope is added while that contract is
> pending.

A Wheel runtime can outlive one client. `scripts/wheel-session start NAME`
prepares a private per-session runtime directory, launches
`lua/wheel/daemon.lua` detached with `setsid`, and waits for metadata that is
published only after both control FIFOs are open. The daemon owns one
`WheelContext` plus session metadata; clients use a local-only control plane
and never embed the runtime.

- **Transport**: two POSIX FIFOs (`request.fifo`, `response.fifo`) under
  `$XDG_RUNTIME_DIR/wheel/sessions/<name>`, with an XDG state fallback. No TCP,
  Unix socket library, or remote listener is involved.
- **Protocol**: one bounded JSON document per line with the marker
  `wheel-session/1`. Requests are capped at 64 KiB and responses at 1 MiB;
  framing is bounded before parsing, and errors are static.
- **Methods**: `ping`, `session.status`, `session.snapshot`, `context.put`,
  `context.get`, `context.list`, and `shutdown`. `context.put` honors the
  existing `expected_version` compare-and-swap; a conflict returns
  `E_SESSION_CAS_CONFLICT`. The daemon bounds the context store at 1024 slots
  and 16 MiB total, and a value is at most 10 KiB per request. The cap is
  derived from the 64 KiB request frame and six-byte worst-case JSON escaping,
  so any accepted value fits the frame without a late frame-too-large error.
- **Serialization**: a per-session client lock file serializes requests; a
  concurrent CLI call fails with `E_SESSION_BUSY`. A per-lock mutex serializes
  stale-lock reclamation: the dead owner's path is renamed, its moved owner is
  verified before removal, and a changed owner is restored with a non-replacing
  hard link. The replacement main lock is created while the mutex is held.
- **Lifecycle**: `start` rejects a live duplicate, cleans only a dead session's
  metadata/FIFOs, and publishes metadata after readiness. The daemon takes over
  the start lock under its mutex before publishing metadata, so a delayed stale
  starter aborts instead of clobbering a newer session. `stop` sends the explicit
  `shutdown` method and waits for the recorded pid; it never signals an
  unrecorded process.
- **Errors**: session failures use the same static three-field shape as command
  failures. The lifecycle codes are:

  | `code`                       | Meaning                                                                                    |
  | ---------------------------- | ------------------------------------------------------------------------------------------ |
  | `E_SESSION_NOT_RUNNING`      | No live metadata/FIFO pair exists for the session.                                         |
  | `E_SESSION_ALREADY_RUNNING`  | A live daemon already owns the session.                                                    |
  | `E_SESSION_START_FAILED`     | The daemon did not become ready; a required host primitive is usually unavailable.         |
  | `E_SESSION_START_MISMATCH`   | Live metadata belongs to a different starter and was not adopted by the waiting start.     |
  | `E_SESSION_UNRESPONSIVE`     | Metadata reports a live pid but the control plane did not answer the probe.                |
  | `E_SESSION_BUSY`             | Another client holds the per-session lock or a start-lock mutex is held by a live process. |
  | `E_SESSION_METADATA_INVALID` | Metadata is present but fails protocol, name, pid, or version validation.                  |
  | `E_SESSION_UNSAFE_PATH`      | A session path, metadata, or FIFO is symlinked, foreign-owned, or not `0700`/`0600`.       |
  | `E_SESSION_CAS_CONFLICT`     | `context.put` expected a different slot version.                                           |

- **Private state**: the session root and directory are `0700`; metadata and
  FIFOs are `0600`; symlinked or foreign-owned paths are refused. Snapshots
  contain slot names, kinds, hashes, versions, and sizes, never slot content.

```sh
# WHEEL_SESSION_ROOT is optional; unset uses the XDG runtime directory.
scripts/wheel-session start demo
scripts/wheel-session put demo scratch/note < note.txt
scripts/wheel-session get demo scratch/note
scripts/wheel-session snapshot demo
scripts/wheel-session stop demo
```

This slice is a runtime boundary foundation, not an agent executor: it does not
own a task DAG, call a provider, run an agent, authenticate multiple users, or
expose a network service. The same-user FIFO residual is recorded in
[SECURITY-MODEL.md](SECURITY-MODEL.md). The `scripts/wheel-session` CLI is
repository-local developer tooling; it is not part of the 0.1.0 library
artifact.

#### Continuation boundary

The prototype deliberately promises less than a session host:

- **Client lifetime is not worker lifetime.** Closing a Bitty panel or a
  `wheel-session` client is not a promise that a Wheel worker continues.
  Presentation ends at the client; worker lifetime is a separate execution
  concern that this prototype does not attach, reattach, or supervise.
- **Stop, crash, and reboot need the upstream contract.** The prototype's
  `stop` is an explicit shutdown of the process it started, and its metadata is
  private local state, not a durable session registry. Continuation after a
  daemon stop, a daemon crash, or a host reboot requires the `bittyd` contract;
  this slice makes no recovery or restart promise for those events.
- **`bittyd` owns the final daemon.** Final daemon lifecycle, IPC and
  authentication, attach/detach, session registry, generation, and worker
  supervision belong to `bittyd`
  ([bitty#2546](https://github.com/bitty-terminal/bitty/issues/2546),
  [bitty#2064](https://github.com/bitty-terminal/bitty/issues/2064),
  [bitty#2218](https://github.com/bitty-terminal/bitty/issues/2218)), not to
  additional Wheel daemon features. `bittyd` does not ship today, and this
  repository does not claim otherwise.
- **No competing Wheel daemon.** Wheel CTX-0031
  ([wheel#101](https://github.com/bitty-terminal/wheel/issues/101)) records the
  same boundary in its blocked note (CarryCtx PX-0195): cancellation work waits
  for the `bittyd` session-host, ownership, generation, IPC,
  worker-supervision, and cancellation contract, and non-daemon cancellation
  may be re-scoped separately. Wheel adds no new daemon scope while that
  contract is pending.

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
- `just test` selects `lua5.1`, then `luajit`, then `lua`, prints the choice,
  and runs the unit suite. `just test-gate` verifies those selection branches
  with fake interpreters on a controlled `PATH`.
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
just test      # select lua5.1, luajit, or lua and run the unit suite
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
gate, and unsupported backends. Process evidence covers a real timeout with a
child-plus-grandchild process-group check, a normal-exit background-child sweep
with status preservation and the recorded PGID, a scrubbed-environment probe
(harness and secret-shaped variables absent), stdin round-trip, typed timeout
results, and CTX-0034 cancellation: a long command cancelled through the handle
(and, in a development checkout, the separate `scripts/wheel-proc` process)
with a distinct `cancelled` terminal reason, a swept group, no child/grandchild
orphan, an untouched unrelated recorded job, an idempotent repeat, and a
timeout/cancel distinction. Temporary-file evidence covers exclusive `0600`
creation and refusal of a pre-existing file and symlink. Activation is measured
cold and warm with `os.clock()` and a `debug.sethook` instruction count against
RC-1 (10^7 instructions, 50 ms CPU, 8 ms warning); the series, interpreter, CPU,
OS, and revision are written to `recording/real-host-2026-10-21.md`, which is
gitignored durable scratch rather than a committed artifact.

Evidence limits: the fixture is offline and uses no credentials. It is
implementation evidence, not a release claim and not full Gate 2 evidence. It
does not cover OS sandboxing or a Bitty panel/terminal presentation run.
Cancellation is same-user only and the installed-tree run exercises the handle
rather than the CLI because `scripts/` is not packaged. A grandchild that calls
`setsid` or joins another process group can leave the setsid-recorded process
group; timeout enforcement is not a real-time guarantee; and disk capture during
a run has no per-file quota. The session leader is retained through the sweep,
so the recorded PGID cannot be reused while the group is signaled; if the leader
is killed before the sweep, no signal is sent, `cleanup` reports `unverified`,
and descendants may survive (CTX-0021 / wheel#81).
`os.clock()` measures process CPU time, not elapsed wall clock; CPU frequency
is not pinned, and one host runs one interpreter per run. The record is not a
canonical specification and does not satisfy SECURITY-MODEL.md Gate 2 on its
own.

### Offline and live tests

`just check`, `just test`, and CI are offline: they use mock providers and never
use a live credential for a request or reach the network. The live provider test
is a separate, manual, opt-in target with an explicit provider selector:

```sh
just test-live                                  # OpenRouter (default)
WHEEL_LIVE_PROVIDER=commandcode just test-live  # Command Code
```

- `WHEEL_LIVE_PROVIDER` is `openrouter` (default) or `commandcode` and is
  matched case-insensitively; an unknown value fails closed with a non-zero
  exit. The default stays OpenRouter.
- OpenRouter uses `OPENROUTER_API_KEY`, `https://openrouter.ai/api/v1`, and
  model `deepseek/deepseek-v4.1-flash`. Command Code uses
  `COMMANDCODE_API_KEY`, `https://api.commandcode.ai/provider/v1`, and the same
  model.
- `just test-live` is not part of `just check` or CI. Its key-free offline
  gates (`test-live-offline`: redirect policy, provider selection, host
  binding) run first and are also part of `check`; the live portion then skips
  with exit 0 and a clear message when the selected provider's key is absent.
- The live portion calls the selected provider's model and covers a
  non-streaming completion, a tool call with parsed arguments, an SSE stream,
  and one runner ReAct turn with a stub tool.
- Command Code serves a reasoning model, so content-bearing checks use a
  1024-token completion budget (at least 512 is required; a 64-token budget can
  be consumed entirely by reasoning and return empty content with
  `finish_reason: length`). The completion, tool-call, and stream paths assert
  non-empty content and reject `finish_reason: length`; the runner path asserts
  the dispatched tool, iteration count, and non-empty deliverables.
- The credential stays in the environment. The Lua adapter is constructed
  without an API key; `tests/live_http_client.py` (Python standard library,
  test-only) reads the selected provider's key variable from its inherited
  environment and adds the authorization header after receiving a key-free
  request JSON over stdin. The key is never passed in argv, written to a
  request file, logged, or placed in a captured artifact, and the live test
  asserts it never appears in its captured output.
- The client is HTTPS-only and accepts only the selected provider host on the
  default HTTPS port. It refuses every HTTP redirect without a second hop, so
  the authorization header cannot be forwarded to another host or downgraded to
  plaintext HTTP. `tests/test_live_http_client_redirect.py` proves this against
  loopback servers for both a cross-host and a scheme-change 302; it requires no
  key and no external network. The helper sends one fixed, non-secret
  `User-Agent` because Command Code's edge rejects Python's default urllib
  signature with a Cloudflare 1010 response; the Lua caller cannot override it.
- Every live request carries an explicit completion `max_tokens` from the named
  default or a validated override, so the provider's credit check cannot assume
  the model's maximum completion window.
- The test helper is not a production HTTP client and adds no runtime
  dependency; the harness provider boundary is unchanged.

`just test-provider-stub` is the offline Gate 2 provider slice: it starts a real
loopback OpenAI-compatible stub on `127.0.0.1:0`, performs a completion through
the real `OpenAIAdapter` and a test-only Python `http.client` transport, and
fails if the fixed synthetic key appears in stdout, stderr, errors, the adapter
description, request/response captures, shutdown markers, or any file the run
creates. A wrong key returns 401; a missing key fails before any request even
with an ambient value; a request without an authorization header returns 401;
a CRLF-bearing key is reported only as a static exception type; non-loopback
hosts, userinfo, query strings, fragments, other paths, other methods, and
redirects are refused. The key reaches only child environments (never argv or a
request file). The gate runs in `just check` and CI; `tests/PROVIDER-STUB.md`
records the trust boundary and limits. The real-host fixture also reads the
execution audit JSONL after a permitted and a denied command, and CTX-0034 adds
the cancellation evidence described above; Bitty panel presentation remains an
open Gate 2 item.

## Benchmarks

Wheel has an offline benchmark suite for its multiplicative paths: entry-point
activation, bounded process calls, runner turns, multi-agent orchestration, and
context compilation. Every scenario is deterministic and uses mock providers;
there is no network, credential, live provider, or artificial sleep.

```sh
just bench                 # full suite, human-readable (manual, about a minute)
just bench-json            # full suite, machine-readable record on stdout
just bench-release-smoke   # bounded subset with generous regression ceilings
```

The suite records the revision, interpreter, CPU/OS/kernel, pinning, wall-clock
source, scenario, cardinality, sample count, and min/median/p95/max/IQR. It
selects `lua5.1` first and warns when a fallback interpreter is used; `taskset`
pinning is optional with a documented unpinned fallback. No host-specific
baseline is committed. The release-smoke ceilings are a regression signal, not
a release performance claim, until the owner accepts thresholds.

`just check` runs the benchmark unit tests and one short context-scenario run;
the full suite stays manual. See [bench/README.md](bench/README.md) for the
method, sample counts, JSON shape, and limitations.

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
- secret environment reads for named provider keys only. Commands launched
  through the bounded process primitive receive a rebuilt allowlist environment
  (`PATH` copied and sanitized, `HOME`, locale/terminal variables, `TMPDIR`, and
  XDG directories) with secret-shaped names refused; `HOME` still grants the
  child the user's ambient file access, which is a residual risk rather than a
  sandbox claim. Host path helpers still use the parent environment and are
  listed in the known gaps (see
  [SECURITY-MODEL.md](SECURITY-MODEL.md#relationship-to-current-code)).

[SECURITY-MODEL.md](SECURITY-MODEL.md) is the normative repository policy for
these classes, the path sandbox, role gates, command deny-list, audit,
redaction, project-config trust gate, residual risk, and evidence gates. Any
widening requires independent security review plus mock/unit and real host
fixture evidence (owner D7).

The in-tree `bitty-plugin.toml` still requests only `platform.notify` and is
unchanged by the position record. It is transitional, must not be widened, and
does not describe harness authority; removal is a follow-up task.

## Audit and logging

Wheel has a local, append-only execution audit stream in
`lua/wheel/audit.lua`. The default location is
`$XDG_STATE_HOME/wheel/audit/`, falling back to
`$HOME/.local/state/wheel/audit/`; an explicit directory override exists only
for tests and embedders. The directory is repaired to `0700`, every record file
is an owned, singly linked `0600` regular file, and a symbolic link, foreign
owner, or weaker mode is refused.

- **Format.** One JSON object per line (`wheel-audit/1`). Recorded fields are
  the event name, sequence number, previous and current SHA-256 hash, wall-clock
  time, role/agent/task/tool/intent when supplied, redacted argv or shell
  command, cwd, allow/deny decision and reason, risk class, and, for a
  completion, exit status, duration, truncation, outcome, and process-group
  cleanup. Prompts, output, environment values, file contents, provider
  responses, and authorization header values are never record fields.
- **Bounds.** A record is at most 16 KiB. The active file rotates at 1 MiB and
  four files are retained (`audit.jsonl` plus `audit.1.jsonl` through
  `audit.3.jsonl`), so the stream is bounded at 4 MiB. A torn or corrupt
  **tail** fails the next append closed instead of being repaired silently.
  Opening the sink reads only the tail, so corruption in an earlier retained
  line does not block appends; `WheelAudit.verify` scans the retained files and
  reports the first broken line.
- **Chain.** Each record carries a monotonic `seq` and the previous record's
  `hash`; `hash` is the SHA-256 of the canonical record without that field.
  `WheelAudit.verify` walks the retained files and reports the first broken
  line. This raises the cost of silent edits within the retained files; it is
  not a same-user boundary, and the stream is not externally anchored.
- **Redaction.** Command previews, argv elements, metadata, and reasons pass
  header, flag, environment-assignment, query, token-shape, and URL-userinfo
  passes. A credential-bearing header is removed as a complete value (name,
  scheme, and every parameter), including escaped JSON keys/values and shell
  quotes; an ambiguous escaped JSON value is over-redacted through the end of
  the preview rather than guessing a closing delimiter. Secret-shaped
  environment assignments and flags replace their complete quoted or unquoted
  shell value. A removed value becomes
  `[redacted:<16 hex of its SHA-256>]`, so the
  same value correlates across events without being recoverable from the
  record. Pattern redaction is heuristic for a value Wheel did not load itself.
- **Process boundary.** `WheelHost.proc.run_program` and `run_command` accept an
  optional `opts.audit` table. When supplied, a pre-spawn record is written
  before the wrapper launches and a completion record after the bounded sweep.
  A `deny` decision is a recorded refusal and never launches. When
  `opts.audit.high_risk` is true, a failed pre-spawn write returns the typed
  `E_AUDIT_UNAVAILABLE` failure and the command is not launched. A lower-risk
  write failure continues with `result.audit_warning`.
- **Current scope.** The sink is opt-in. No tool or trust call site supplies
  `opts.audit` yet, so a normal run does not create an audit directory and the
  policy's mandatory pre-spawn record is not yet applied to every invocation.
  Default-on wiring, cross-process append serialization, and trust-approval
  records are follow-ups. This is implemented evidence, not a completed Gate 1
  or Gate 2 claim.

Inspect the stream with an ordinary line reader, for example
`tail -n 20 "$XDG_STATE_HOME/wheel/audit/audit.jsonl"`. `just test-audit` covers
the sink and `tests/real_host_fixture.lua` reads the JSONL after a real
permitted and denied command as Gate 2 evidence.

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
7. Run `just bench-release-smoke` on the release revision and keep its record
   under `recording/`. The ceilings are regression signals; they become a
   release budget only after the owner accepts them.

## Security

Report vulnerabilities through the process in [SECURITY.md](SECURITY.md), not a
public issue. The 0.1.0 harness holds workspace read/write, arbitrary argv,
shell command strings, network egress, and secret environment reads under the
policy in [SECURITY-MODEL.md](SECURITY-MODEL.md). Executable project
configuration requires explicit per-project trust, and secrets are read only
from a named allowlist and redacted before persistence. The repository contains
no credentials.

# Contributing to wheel

This guide is for contributors to the `wheel` repository. The repository is
pre-release: the Lua sources, tests, and transitional manifest are reviewed as
harness implementation, not shipped plugin behavior. The 0.1.0 product position
is an independent out-of-process harness that holds execution authority; see
[SECURITY-MODEL.md](SECURITY-MODEL.md).

## Repository ground rules

- Read [AGENTS.md](AGENTS.md) before making any change. It defines authority,
  scope boundaries, CarryCtx workflow, toolchain policy, and the security and
  capability constraints that override convenience.
- The binding rules under [.carryctx/rules/](.carryctx/rules/) (delivery,
  documentation, security) apply to every agent and contributor.
- Canonical platform architecture, API, packaging, compatibility, and security
  contracts live in `bitty-docs` and `bitty-plugins-docs`. Wheel's own authority
  policy lives in [SECURITY-MODEL.md](SECURITY-MODEL.md). This repository must
  not invent platform capabilities, lifecycle semantics, or release policy
  independently; the transitional manifest is not the harness authority source.
- Never commit, push, publish packages, or mutate remote state without
  explicit authorization from the owning task.

## Prerequisites

Toolchain expectations (dependency versions are pinned in
[package.json](package.json) and locked in `bun.lock`; never invoke formatters
or linters by name):

- `just` — command runner owning all quality-gate invocations.
- `bun` / `bun run <bin>` — JavaScript execution and package management; the
  justfile invokes installed tools as `bun run <bin>`. Never use `npm`, `npx`,
  or `yarn` in any Bitty repository.
- `markdownlint-cli2`, `prettier`, `commitlint`, `lefthook` — materialized by
  `just install` and invoked through the justfile.
- `bitty-plugin-lint` and `bitty-plugin-docs-check` (bitty-plugin-sdk,
  commit-pinned) plus `luaparse` — transitional manifest, README contract, and
  Lua parse gates; `just test` prefers Lua 5.1, then falls back to LuaJIT and
  then `lua` for the behavior suite.

## Development setup

1. Enter this repository before running Git, CarryCtx, or toolchain commands.
2. Install pinned development dependencies: `just install`
   (`bun install --frozen-lockfile`).
3. Enable Git hooks (optional): `just hooks-install`.
4. Run all quality gates: `just check` (Markdown lint, Prettier format check,
   transitional manifest validation, README user-documentation check, Lua
   parse, the parser control, and the Lua behavior suite).
   CI runs the same aggregate target and then the real-host fixture with
   `just test-real-host`; `just check` runs offline once `just install` has
   completed. Run `just test-real-host` locally when changing the host seam,
   activation, or command dispatch; it requires `lua5.1` and fails closed
   without it.
5. Run the opt-in live provider test only when needed: `just test-live` first
   runs the key-free offline gates. `WHEEL_LIVE_PROVIDER` selects the live
   provider, case-insensitively: `openrouter` (the default) uses only
   `OPENROUTER_API_KEY`, `commandcode` uses only `COMMANDCODE_API_KEY`, and
   `openai-cache` uses only `OPENAI_API_KEY`. Keep the selected key exclusively
   in the Python helper's environment. The live portion is never part of
   `just check` or CI and skips cleanly when its selected key is absent; keys
   for other providers do not satisfy that requirement. See the README's
   offline/live test section for scenario coverage and credential isolation.
6. Record scoped work in CarryCtx (task, session, progress, checkpoint) and
   stop at review; independent review is required for acceptance.

## Test scratch roots

`tests/test_wheel.lua` creates one private root per run: a unique child of
`WHEEL_TEST_TMP` when that variable is set, otherwise the unique path returned
by `os.tmpname()`. Every filesystem fixture is constructed under that root, and
the suite removes only its own root, so concurrent worktrees cannot delete each
other's data. `just test` adds an outer temporary base and removes it when the
suite exits, even before the suite's own cleanup hook runs.

`WHEEL_TEST_TMP` must be an absolute path built from `A-Z`, `a-z`, `0-9`, `.`,
`_`, `-`, and `/`, without a `..` segment. Whitespace, shell metacharacters,
relative paths, and parent-directory segments are rejected before the suite
creates its run directory or any fixture, because fixture commands embed
derived paths in shell strings. The suite first removes its `os.tmpname()`
probe placeholder, so only that probe exists before validation. Run
`just test-roots` to verify an unsafe base is rejected without touching a
sentinel file outside the run root.

Run `just test-concurrent` to prove the isolation: it starts two suites
concurrently against one shared scratch base, asserts that two distinct per-run
roots exist while both run, and fails if either suite fails or if the base is
not empty afterwards. The check roughly doubles the suite runtime, so it is a
local gate rather than part of `just check`. The cross-process drill in
`tests/e2e_cross_process.lua` also creates its own per-run FIFO/database
directory and cleans recorded host processes and the directory on failure.

## Delivery lifecycle

Changes follow Issue -> Branch -> Commit -> Pull Request -> Review -> Merge,
where independent review plus required CI must pass before merge. Every pull
request states its Issue and CarryCtx task links, impact areas (authority
policy, manifest transition, SDK/API, security, DX, CI/release, documentation,
compatibility), reproducible gate evidence, dependencies, cross-repository
ordering, and documentation synchronization status. Labels
(`feat`/`fix`/`docs`/`chore`, `P0`/`P1`/`P2`, `area:*`) and milestone `v0.1.0`
are kept in sync. Commits are Conventional Commits validated by commitlint
through the `commit-msg` hook and `just commit-check`.

## Contributor branches

Branches are managed with CarryCtx. Official branches use
`ctx-XXXX/<type>-<slug>`, where `XXXX` is the owning CarryCtx task number,
`<type>` is one of `feat|fix|chore|docs`, and the slug is short kebab-case;
commander housekeeping branches may use `cmd/<slug>`. External contributors
must use a distinguishable prefix, for example `<github-handle>/<type>-<slug>`.
CarryCtx-bound worktrees live at `.worktrees/ctx-XXXX-<type>-<short-slug>`,
mapping `/` to `-`; one branch per task.

## Authority and privacy

Wheel 0.1.0 is an independent harness with the owner-approved ceiling of
workspace read/write, arbitrary argv, shell command strings, network egress, and
secret environment reads. Shell strings and secret reads are the higher-risk
class. The controls, path and role gates, audit, redaction, project-config trust
gate, and widening process are normative in [SECURITY-MODEL.md](SECURITY-MODEL.md);
do not widen authority or weaken a control without an explicitly scoped task,
both evidence gates, and independent security review. The transitional
`bitty-plugin.toml` must not be widened and is not the authority model.

## Workflow snapshots

The engineering workflow snapshot lives in this repository on the branch
`refs/heads/carryctx-snapshots`. Merges run `just workflow-publish` (dry run:
`just workflow-publish-dry`) as part of the commander closeout; snapshots are
redacted publication artifacts and are never merged back. Fresh clones restore
with `just workflow-import` (`just workflow-import-dry`).

## Reporting

Report bugs and feature requests through the GitHub issue templates. Report
security issues privately per [SECURITY.md](SECURITY.md); never open a public
issue for a vulnerability.

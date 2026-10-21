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
   runs a key-free loopback redirect-policy test, then requires
   `OPENROUTER_API_KEY` in the inherited environment for the live portion. It
   is never part of `just check` or CI, and skips the live portion cleanly when
   the key is absent. See the README's offline/live test section for the
   env-only key handling contract.
6. Record scoped work in CarryCtx (task, session, progress, checkpoint) and
   stop at review; independent review is required for acceptance.

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

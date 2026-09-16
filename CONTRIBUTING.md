# Contributing to wheel

This guide is for contributors to the `wheel` repository. The repository is
pre-implementation: the Lua sources, manifest, and tests are reviewed
scaffolding, not shipped plugin behavior.

## Repository ground rules

- Read [AGENTS.md](AGENTS.md) before making any change. It defines authority,
  scope boundaries, CarryCtx workflow, toolchain policy, and the security and
  capability constraints that override convenience.
- The binding rules under [.carryctx/rules/](.carryctx/rules/) (delivery,
  documentation, security) apply to every agent and contributor.
- Canonical plugin architecture, API, packaging, compatibility, and security
  contracts live in `bitty-docs` and `bitty-plugins-docs`. This repository must
  not invent capabilities, lifecycle semantics, or release policy
  independently; the manifest is the single source of the authority the plugin
  receives.
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
- `bitty-plugin-lint` (bitty-plugin-sdk, commit-pinned), `luaparse`, and
  `lua5.4` — manifest, Lua parse, and Lua 5.4 behavior/conformance gates.

## Development setup

1. Enter this repository before running Git, CarryCtx, or toolchain commands.
2. Install pinned development dependencies: `just install`
   (`bun install --frozen-lockfile`).
3. Enable Git hooks (optional): `just hooks-install`.
4. Run all quality gates: `just check` (Markdown lint, Prettier format check,
   manifest validation, Lua parse, Lua behavior suite, and LuaLS conformance).
   CI runs the same aggregate target, and `just check` runs offline once
   `just install` has completed.
5. Record scoped work in CarryCtx (task, session, progress, checkpoint) and
   stop at review; independent review is required for acceptance.

## Delivery lifecycle

Changes follow Issue -> Branch -> Commit -> Pull Request -> Review -> Merge,
where independent review plus required CI must pass before merge. Every pull
request states its Issue and CarryCtx task links, impact areas (manifest
capabilities, SDK/API, security, DX, CI/release, documentation,
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

## Capabilities and privacy

Manifest capability requests are deny by default and must stay minimal. This
plugin requests only `ui.rich` and `ui.overlay` (overlay composition through
declarative list and text primitives); filesystem, process, network, clipboard,
terminal input, and persistent-state authority, and install-time code
execution, stay out. A wider request needs an explicitly scoped task plus a
reviewed privacy and security note; never widen silently.

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

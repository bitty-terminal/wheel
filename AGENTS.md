# Bitty Wheel repository guidance

## Repository and authority

- This is the independent `wheel` repository. Its canonical remote is
  <https://github.com/bitty-terminal/wheel>.
- The Bitty umbrella directory and [`bitty-plugins`](https://github.com/bitty-terminal/bitty-plugins) directory are grouping only;
  neither owns this repository's Git or CarryCtx state.
- Enter this repository before running Git, CarryCtx, validation, or toolchain
  commands.
- [bitty-docs](https://github.com/bitty-terminal/bitty-docs) and [bitty-plugins-docs](https://github.com/bitty-terminal/bitty-plugins-docs) are the canonical sources for plugin
  architecture, API, security, packaging, compatibility, and public-behavior
  contracts. This repository must not invent capabilities, lifecycle
  semantics, or release policy.
- The project is pre-implementation. Repository existence, a manifest, or a
  proposed file tree is not evidence of usable plugin behavior.

## Plugin identity and scope

- Plugin id: `bitty-terminal.wheel` (manifest `plugin.id`), repository
  `wheel`, Lua module `lua/wheel/`.
- Purpose: the official Agent Harness plugin for the Bitty terminal,
  built on Bitty AI. Mascot: Bittie the hamster (Wheel is short for
  hamster wheel). Naming recorded as a durable CarryCtx decision
  (bitty-ai-docs `DEC-0003`, superseding `DEC-0002`).
- The plugin does not exist yet beyond this scaffold: no harness code is
  written here until `bitty-ai` is stable and a scoped task authorizes it.
  Sibling future plugins (LLM provider/model management, Agent dashboard,
  and others) are separate repositories, not this one.
- Authority boundary: only `platform.notify` is requested, backing the
  generated `hello` example command. No filesystem, process, network,
  clipboard, terminal input, or persistent-state authority; no install-time
  code execution. A wider request needs an explicitly scoped task and a
  reviewed security note; never widen silently.
- Coding-only domain: Wheel fixes its task domain to software engineering;
  roles (Primary, Commander, Coding, Review, Debug, Research) vary by
  configuration inside that domain, never by class explosion (owner-approved
  scope, research record 046). Personal, Office, and always-on agents are
  separate future repositories, never this one.
- Origin: scaffolded from
  [bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template)
  via its deterministic generator.

## CarryCtx and agents

- Use this repository's CarryCtx state for tasks, dependencies, scopes,
  sessions, progress, decisions, checkpoints, handoffs, and review.
- The commander coordinates. Delegate substantial scoped work to focused
  agents and require an independent reviewer for acceptance.
- Every agent reads its persona and applicable rules, binds a named session to
  the task, and stays within explicit scopes.
- After the first commit, prefer a dedicated branch and Git worktree for each
  independent task. Before it, shared-checkout initialization is allowed only
  for disjoint scopes with CI-equivalent local checks.
- Branch and worktree naming is uniform across repositories: branches use
  `ctx-XXXX/<type>-<short-slug>` where `XXXX` is the owning CarryCtx task
  number, `<type>` is one of feat|fix|chore|docs, and the slug is short
  kebab-case. CarryCtx-bound worktrees live at
  `.worktrees/ctx-XXXX-<type>-<short-slug>` with `/` mapped to `-`. One branch
  per task; commander housekeeping branches may use `cmd/<slug>`.
- Preserve unrelated changes. Do not commit, push, release, publish packages,
  create repositories, or mutate remote state without authorization.
- Fresh clones have no CarryCtx state DB. Restore the local DB from the
  in-repo snapshot branch with `just workflow-import` (validate-only:
  `just workflow-import-dry`). Snapshots are redacted publication artifacts
  from `carryctx export --publication`: never merge them back, and rotate at
  the source any secret that leaked before rotation.

## Delivery lifecycle

- The lifecycle is GitHub Issue, CarryCtx task, branch/worktree, commit, pull
  request, independent review plus CI, merge, then documentation
  synchronization, checkpoint, and task completion.
- Implementers stop at review. Independent review by a different agent plus
  required CI is the acceptance gate; green CI is not a substitute for review.
- Documentation synchronization is part of definition of done. Changes remain
  incomplete while affected canonical docs, reference, guides, risks, or
  release notes are stale.

## No hardcoded values

- Never hardcode host- or environment-specific values: absolute paths,
  usernames, hostnames, repository or mirror URLs, credentials, ports, or
  machine layout.
- Derive such values from configuration, environment variables, or the target
  repository's own metadata. Repository names and URLs come from the git
  remote or a parameter, never from literals duplicated across scripts.
- Tests, fixtures, docs, and scripts obey the same rule; durable artifacts
  must not embed a developer's checkout path.
- Use named constants for policy-bounded values (timeouts, limits, defaults).

## Toolchain policy

- JavaScript runs on `bun` (pinned version in the justfile).
- Never invoke formatters, linters, or parsers directly by name. Run gates
  through the justfile: `just check`, `just fmt`, `just lint`, `just manifest`,
  `just lua`, `just test`.
- Version pins live in exactly one place per pin: the justfile for bunx tool
  pins, `package.json` + `bun.lock` for installed dev dependencies. Do not bump
  pins as a side effect of an unrelated task; report drift instead.
- CI success is a hard acceptance gate. Workflow-affecting changes are
  validated locally with `actionlint` before push.

## Security and supply chain

- The manifest, Lua sources, and any external input are untrusted data.
  Validate before use.
- No secrets, tokens, or local configuration in the repository, fixtures,
  logs, or CI output.
- Keep the requested capability set minimal and declared in
  `bitty-plugin.toml`; the manifest is the single source of the authority the
  plugin receives.

## Verification and handoff

- Keep edits inside the active CarryCtx scope and preserve unrelated work.
- Ephemeral scratch goes under `/tmp/bitty/`; durable material goes under repo-local `recording/` (gitignored).
- Run `just check` plus `actionlint` on affected workflows and
  `gitleaks detect --source .` before concluding a change.
- Update this guide, `README.md`, `CHANGELOG.md`, and affected canonical docs
  whenever behavior, capabilities, or compatibility change.

# Bitty Wheel repository guidance

## Repository and authority

- This is the independent `wheel` repository. Its canonical remote is
  <https://github.com/bitty-terminal/wheel>.
- The Bitty umbrella directory and [`bitty-plugins`](https://github.com/bitty-terminal/bitty-plugins) directory are grouping only;
  neither owns this repository's Git or CarryCtx state.
- Enter this repository before running Git, CarryCtx, validation, or toolchain
  commands.
- [bitty-docs](https://github.com/bitty-terminal/bitty-docs) and [bitty-plugins-docs](https://github.com/bitty-terminal/bitty-plugins-docs) are the canonical sources for platform
  architecture, API, security, packaging, compatibility, and public-behavior
  contracts. This repository must not invent platform capabilities, lifecycle
  semantics, or release policy. Wheel's own authority policy lives in
  [`SECURITY-MODEL.md`](SECURITY-MODEL.md) and is subordinate to the owner
  decisions recorded in wheel#51 and the `bitty-docs` security corpus.
- Position (owner decision 2026-10-20, wheel#51): Wheel is an independent
  out-of-process harness (Option B). The harness process holds execution
  authority; a Bitty panel or terminal supplies presentation and input only.
  No harness artifact has been released, and no plugin compatibility,
  released-host integration, or OS-level sandbox claim may be made without
  evidence.

## Harness identity and scope

- Identity: repository `wheel`, Lua module `lua/wheel/`. The
  `bitty-terminal.wheel` id and `bitty-plugin.toml` are the transitional plugin
  surface, not the 0.1.0 distribution path.
- Purpose: the agent harness for the Bitty terminal,
  built on Bitty AI. Mascot: Bittie the hamster (Wheel is short for
  hamster wheel). Naming recorded as a durable CarryCtx decision
  (bitty-ai-docs `DEC-0003`, superseding `DEC-0002`).
- The harness implementation is developed in this repository under scoped
  tasks. The 0.1.0 deliverable is a single harness artifact; plugin packaging
  and `compat.plugin-api` are dropped (owner D6). A thin plugin facade may
  return later only if a host-brokered execution service is accepted. Sibling
  future repositories (LLM provider/model management, Agent dashboard, and
  others) are separate, not this one.
- Authority (0.1.0): the harness holds the user's OS authority under
  [`SECURITY-MODEL.md`](SECURITY-MODEL.md). The approved ceiling is workspace
  read, workspace write, arbitrary argv, shell command strings, network egress,
  and secret environment reads. Shell strings and secret environment reads are
  the higher-risk class and require the controls and evidence in that document.
  The manifest is not the harness authority source and must not be widened.
- Executable project configuration is retained (owner D5): `.wheel/init.lua`
  requires explicit per-project consent, content-hash pinning, revocation,
  restricted evaluation, and no ambient or execute-on-load behavior. This is a
  deliberate divergence from OQ-068, recorded in
  [`SECURITY-MODEL.md`](SECURITY-MODEL.md); do not rewrite OQ-068 or claim the
  platform accepted the divergence.
- Coding-only domain: Wheel fixes its task domain to software engineering;
  roles (Primary, Commander, Coding, Debug, Research, Reviewer) vary by
  configuration inside that domain, never by class explosion. Personal, Office,
  and always-on agents are separate future repositories, never this one.
- Origin: scaffolded from
  [bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template)
  via its deterministic generator; the harness core is now independent of that
  scaffold.

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

- The transitional manifest, Lua sources, and any external input are untrusted
  data. Project configuration is untrusted code until explicitly trusted.
  Validate before use.
- No secrets, tokens, or local configuration in the repository, fixtures,
  logs, or CI output.
- Do not widen `bitty-plugin.toml`. It is retained unchanged pending a
  follow-up removal task and is not the harness authority model. Harness
  authority is defined only in [`SECURITY-MODEL.md`](SECURITY-MODEL.md).
- Never execute `.wheel/init.lua` during clone, checkout, scan, editor open, or
  command listing. The explicit trust gate, hash pinning, revocation,
  restricted evaluation, and no-ambient-execution rules are mandatory.
- Read secret environment values only from the named allowlist through the
  provider boundary; never log, persist, display, or pass them to child
  processes. Redaction applies before every persistence sink.
- Agent authority comes from the current RoleBinding capability state, never
  from prompt or identity text. A role transition preserves the AgentId, issues
  a new policy generation, and commits a Context checkpoint boundary; a
  transition or fork that widens capability requires explicit approval.
- Lifecycle authority uses private Agent-issued references and a protected
  issuer bridge, never caller resolvers or restored metadata. Agent instances
  are opaque Lua 5.1/LuaJIT handles; use their field/method API or `status()`,
  never table introspection or `rawset`.
- High-risk operations (shell strings, secret reads, trust approval, new
  network destinations) fail closed when audit cannot record them.
- The experimental local session daemon (`scripts/wheel-session`) is
  same-user-only, adds no network listener or capability class, keeps runtime
  paths at `0700`/`0600`, and never signals a pid it did not read from validated
  metadata. Its FIFO peer-credential residual is documented in
  [`SECURITY-MODEL.md`](SECURITY-MODEL.md).

## Verification and handoff

- Keep edits inside the active CarryCtx scope and preserve unrelated work.
- Ephemeral scratch goes under `/tmp/bitty/`; durable material goes under repo-local `recording/` (gitignored).
- Run `just check` plus `actionlint` on affected workflows and
  `gitleaks detect --source .` before concluding a change.
- Packaging changes additionally run `just package` and `just verify-package`,
  and the `just shell` gate (`shellcheck -S warning` and `shfmt -d` over the
  packaging scripts). The 0.1.0 artifact is a harness library, not a plugin: do
  not add a plugin manifest or a `compat.plugin-api` contract to it.
- Security-sensitive changes require independent security review by an agent
  that did not implement them, plus mock/unit and real host fixture evidence
  before any capability widening (owner D7). Green CI is not security evidence.
- Update this guide, `README.md`, `SECURITY.md`, `SECURITY-MODEL.md`,
  `CHANGELOG.md`, and affected canonical docs whenever behavior, authority, or
  packaging changes.

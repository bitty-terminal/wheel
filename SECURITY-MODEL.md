# Wheel security model (0.1.0)

> Status: **policy record for owner decisions D1-D7** (2026-10-20, wheel#51).
> This document defines the authority boundary the 0.1.0 harness must hold and
> the controls that boundary requires. It is **not** evidence that any control
> is implemented, verified, or released. Where it names a mechanism that exists
> in the repository, that mechanism is unverified until the evidence gates in
> this document pass. No capability is widened by this record.
>
> Policy statements use **must** for a required control. They are normative
> requirements, not evidence that the current code implements them. The current
> implementation inventory, including every known gap, is in
> [Relationship to current code](#relationship-to-current-code).

## Purpose and scope

This document records Wheel's product position after the owner's Option B
decision and defines the authority policy for the 0.1.0 window:

- Wheel is an independent out-of-process harness. The harness process, not a
  Bitty plugin VM, holds execution authority.
- The first-release authority ceiling is approved as a whole: workspace read,
  workspace write, arbitrary argv, shell command strings, network egress, and
  secret environment reads. Shell command strings and secret environment reads
  are the higher-risk class and carry additional controls and evidence.
- Executable `.wheel/init.lua` is retained with an explicit per-project trust
  gate. This departs from OQ-068 and is recorded as a divergence below.
- The 0.1.0 deliverable is a single harness artifact. Plugin packaging and
  `compat.plugin-api` are dropped from the 0.1.0 scope.
- Any later capability widening requires independent security review plus dual
  evidence (mock/unit and a real host fixture).

In scope: authority classes, path and role gates, command deny-list, audit,
secret handling, project-configuration trust, residual risk, and the evidence
gates. Out of scope: implementation design of the execution backend, the
packaging and launch contract, optional IPC client scopes, and any change to
canonical platform contracts.

## Owner decision record

| Decision | Ruling (2026-10-20, wheel#51)                                                             | Recorded in                                 |
| -------- | ----------------------------------------------------------------------------------------- | ------------------------------------------- |
| D1       | Independent harness process (Option B), not a plugin or hybrid                            | Product position; `repo.toml`; `README.md`  |
| D2       | The Wheel harness holds execution authority (Option B)                                    | Trust boundary; authority ledger            |
| D3       | Approve workspace read/write, arbitrary argv, shell strings, network egress, secret env   | Authority policy; authority ledger          |
| D4       | Not applicable: no host-brokered execution service in the Option B window                 | Out of scope; a plugin facade is later work |
| D5       | Keep executable `.wheel/init.lua` with an explicit, reviewed trust gate                   | Executable project configuration trust gate |
| D6       | Single harness artifact; drop plugin packaging and `compat.plugin-api`                    | `repo.toml`; `README.md`; release checklist |
| D7       | Independent security review plus mock/unit and real host fixture evidence before widening | Evidence gates before widening              |

## Normative sources this model must not weaken

- The `bitty-docs` security corpus (overview, threat model, and risk register)
  remains normative for the platform. This document does not relax it.
- The owner decisions recorded in wheel#51 (2026-10-20) authorize the product
  position and the 0.1.0 ceiling. They do not authorize anything beyond it.
- The accepted execution contract
  (`bitty-terminal-docs/specifications/execution-extraction-contract.md`, W-132)
  keeps execution principal-scoped, bounded, and typed. A plugin principal is
  not a general spawn principal; Wheel does not gain plugin execution authority
  from that contract.
- The accepted manifest and capability grammar
  (`bitty-plugins-docs/specifications/manifest-capability-authority.md` and the
  Plugin Platform RFC) still governs plugin manifests. It is not the authority
  model for an out-of-process harness, and the in-tree manifest is not widened
  to describe harness authority.
- OQ-068 records the platform position that `.wheel/` is declarative-data-only.
  This document records a deliberate, owner-approved Wheel-local divergence; it
  does not rewrite OQ-068 or reinterpret it for any other consumer.

## Terminology

- **Harness**: the Wheel process, its Lua runtime, and the tools it invokes.
- **Workspace root**: the canonical directory tree a harness session is bound
  to at launch. It is never derived from model output or project configuration.
- **Authority class**: one of the six approved capabilities in the ledger.
- **High-risk class**: shell command strings and secret environment reads.
- **Project configuration**: the executable `.wheel/init.lua` entry evaluated
  after an explicit per-project trust decision.
- **Widening**: any new authority class, broader path or destination scope, new
  secret name, new configuration power, weaker audit/redaction/trust, or larger
  blast radius inside an existing class.
- **Evidence gate**: a reproducible test suite whose artifacts an independent
  reviewer can inspect; prose claims do not satisfy a gate.

## Product position and trust boundary

Wheel 0.1.0 is user-installed software that runs as the invoking OS user. It is
not sandboxed by the Bitty plugin VM and receives no manifest grant at runtime.
Its authority is the user's OS authority, constrained by Wheel's own policy
layer. Bitty supplies presentation and input when the harness runs in a
terminal panel; that integration never supplies execution authority.

The trust boundary is therefore the OS user account:

- **Trusted**: the harness artifact and its reviewed code, the user's global
  Wheel configuration, and the OS user account itself.
- **Untrusted**: model output and tool calls, repository content, project
  configuration before consent (and code after consent), command output,
  network responses, third-party tools and dependencies, and any future IPC
  peer.

A harness defect is user-level compromise. No claim in this repository may
describe the 0.1.0 harness as sandboxed, confined, or least-privilege at the OS
level.

### Authority ledger

| Authority class       | 0.1.0 status        | Default scope                                                     | Default mode                                                                                         |
| --------------------- | ------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Workspace read        | Approved            | The session workspace root                                        | Enabled for Inspect-intent tools                                                                     |
| Workspace write       | Approved            | The session workspace root                                        | Enabled for Modify-intent tools, subject to role gates                                               |
| Arbitrary argv        | Approved            | Programs resolved on `PATH` or by absolute path; cwd in workspace | Enabled for Execute-intent tools                                                                     |
| Shell command strings | Approved, high risk | Non-login shell; cwd in workspace                                 | Interactive sessions only unless an unattended session opts in                                       |
| Network egress        | Approved            | Outbound TLS to configured provider endpoints                     | Enabled for harness provider clients; no inbound or listening socket                                 |
| Secret environment    | Approved, high risk | Named provider keys only                                          | Enabled per configured provider; child-process non-inheritance is required but not implemented (gap) |

Every class is deny-by-default at the policy layer even though the owner
approved the ceiling: a session, role, or tool that is not granted a class does
not receive it.

## Authority policy

### Workspace read and write

- The workspace root is fixed at session launch from an explicit argument or
  the launch directory, then canonicalized. Model output, project
  configuration, and repository content cannot change it.
- Every harness-mediated file operation resolves under the root. The resolver
  normalizes separators and `.`/`..`, rejects NUL and control bytes, rejects
  absolute paths outside the root, and rejects a symlink whose canonical target
  leaves the root. Lexical prefix checks alone are insufficient.
- Writes must use a temporary file inside the destination directory plus an
  atomic rename, never a direct truncate of an existing file. Parent directories
  are created only inside the root. The current file tools truncate in place;
  atomic replace is a known gap.
- The harness's own global configuration, trust store, audit log, and secret
  material must be outside model-visible workspace authority. Tools must not
  read or write them even when they live under the user's home directory. A
  home-rooted workspace is not currently excluded from file-tool authority;
  this is a known gap.
- `.git` is workspace content for Git operations, but direct rewrites of Git
  internals are not an intended tool primitive. Destructive repository
  operations (`reset --hard`, `clean -fdx`, force-push, history rewrite)
  require explicit user confirmation. The current `write_file` can still write
  `.git` content; a guard is a known gap.
- Writing `.wheel/init.lua` changes its hash and therefore invalidates its trust
  record. A tool may write it only with Modify authority; the next load must
  re-enter the trust gate.
- A session may hold multiple workspace roots (multi-workspace operation). Each
  root is independent; a tool bound to one root cannot read or write another
  without an explicit root grant. Roots are never nested implicitly.
- File reads and command output are bounded by finite, named limits. Oversized
  output spills to a content-addressed artifact inside the workspace or is
  truncated with an explicit marker; it is never silently buffered without
  bound.

### Arbitrary argv

- The preferred execution primitive is an explicit program plus argument
  vector, with no unquoted shell string at the call site. The current standalone
  backend joins single-quoted arguments and executes them through the POSIX
  shell; a native argv spawn remains CTX-0016 work.
- The working directory must resolve inside the workspace root. The resolver
  rules above apply.
- The child environment must be a scrubbed baseline plus explicitly allowed
  variables. Secret names in the ledger must never be included. `HOME` is passed
  only because ordinary build tools require it; that still grants the child the
  user's ambient file access, which is a residual risk, not a sandbox claim.
  The current `run_command` path calls `io.popen` with the parent environment,
  so allowlisted provider keys are inherited today; this is a known gap.
- The harness records the resolved executable path, argv, cwd, exit status, and
  duration before the process is allowed to run.
- Each invocation has a finite timeout, bounded output, and a process group
  owned by the harness. Cancellation targets only PIDs and process groups the
  harness recorded at launch. Name- or pattern-based killing is forbidden.
- Interactive stdin and TTY allocation are off by default. A user-requested
  attach may enable them for that job only.
- Detached execution, daemonization, and reparenting out of the owned process
  tree are denied. A child that daemonizes is treated as an orphan risk and
  cleaned up through its recorded process group.
- Executing setuid/setgid binaries and invoking privilege-transition tools
  (`sudo`, `su`, `doas`, `pkexec`) is denied.
- Network access by spawned programs is not mediated by the harness. The argv
  class is user-level authority; the network policy below governs harness
  clients, not arbitrary child processes.

### Shell command strings

Shell strings are approved for 0.1.0 but are a higher-risk class. The following
controls are mandatory:

1. **Argv first.** If an operation can be expressed as program plus argv, the
   harness must use the argv primitive. Shell execution is reserved for
   compound commands, pipelines, and redirections that require shell
   semantics.
2. **Separate primitive and intent.** Shell execution is an Execute-intent
   operation behind the same role gates as argv, with its own audit event. It
   is not folded into the generic process call.
3. **Non-login, non-interactive shell.** The harness invokes a non-login shell
   with `-c`, does not source profile or rc files, and does not allocate a TTY
   unless the user explicitly attaches.
4. **Workspace cwd.** The working directory resolves inside the workspace root.
5. **Scrubbed environment.** The shell receives the same scrubbed environment
   as argv. Secret environment variables are absent.
6. **Deny-list screening.** Every command string is screened before execution
   against the deny-list below (the current scanner covers a subset; see the
   known gaps). A match is refused, not confirmed into.
7. **Audit before execution.** The full command is redacted and recorded before
   spawn. If the audit sink is unavailable, shell execution fails closed.
8. **Unattended opt-in.** Autonomous or scheduled runs are argv-only by
   default. A session may enable shell strings only through an explicit,
   recorded user decision; the decision is scoped to that session.
9. **No remote-pipe execution.** Piping downloaded content directly into a shell
   or interpreter is denied. The content must be fetched, inspected, and
   executed as a separate recorded step.
10. **Bounded execution.** The same timeout, output bound, process-group
    ownership, and recorded-PID cancellation rules as argv apply.

Residual risk: a shell command can write outside the workspace root because the
harness has no OS-level confinement in 0.1.0. The path sandbox governs
harness-mediated file tools, not arbitrary programs. Audit, cwd, environment
scrubbing, the deny-list, and explicit session opt-in reduce the blast radius;
they do not eliminate it. OS confinement (for example Landlock or a cgroup) is
an open point and a prerequisite candidate before any widening of shell
authority.

### Network egress

- The harness opens outbound connections only. It never listens on a socket,
  accepts inbound connections, or exposes a local service in 0.1.0.
- Harness-owned clients connect only to provider endpoints resolved from
  user-level configuration and built-in adapter defaults. A project
  configuration may select an existing provider profile but may not add a
  destination, change a host, or override a base URL.
- TLS certificate verification is mandatory and cannot be disabled by project
  configuration, model output, or a tool call. Plaintext HTTP is permitted only
  for a loopback provider endpoint that the user configured explicitly.
- Redirects are followed only within the same allowlisted host and scheme, with
  a finite redirect bound. A redirect to a new host is refused.
- Proxy settings come from the user's environment or user-level configuration.
  A project configuration cannot set a proxy for the harness process.
- Each request records the destination host, port, purpose (provider profile
  and operation), and outcome. Authorization headers, API keys, prompt bodies,
  and response bodies are never recorded.
- Secret environment values are attached only to the matching provider client.
  They are never forwarded to a different destination, a redirect target, or a
  child process.
- Child processes spawned through argv or shell are outside this mediation.
  Their egress is user-level authority and remains a residual risk.
- The harness sends no telemetry by default. Any future telemetry is a separate
  authority decision and evidence gate.

### Secret environment reads

- The harness reads only an explicit, finite allowlist of names: the provider
  key names it supports (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
  `DEEPSEEK_API_KEY`) and additional provider key names a user references by
  exact name in user-level provider configuration. Prefix wildcards, bulk
  environment imports, and `env.read:*` equivalents are forbidden. Non-provider
  secret names (source-host tokens, cloud credentials) are outside this 0.1.0
  model; adding one is a widening.
- Secret access is centralized in the provider adapter boundary. Other modules
  do not call the environment directly for secret material.
- Values are held in memory only for the lifetime of the provider client. They
  are never written to global or project configuration, the trust store, the
  workspace, context slots, checkpoints, blobs, audit records, error messages,
  or model prompts.
- Provider clients place the value only in the authorization header for that
  provider. Project configuration cannot redirect the header to another host.
- Child processes must never inherit an allowlisted secret. A command that needs
  a credential must obtain it outside Wheel or through a future explicit
  credential-helper design with its own review. The current `run_command` path
  inherits the parent environment; this is a release-blocking known gap.
- Every output sink applies two redaction passes: exact-value redaction for
  loaded secrets, and shape-based redaction for bearer tokens, key prefixes,
  `api_key`/`token`/`secret` assignments, and long token-like runs. Redaction
  failure is fail-closed for persistence.
- Provider error bodies, HTTP headers, and streamed fragments are redacted
  before display, audit, or artifact storage.
- A leaked secret is rotated at the source. Deleting a log or rewriting history
  does not make the value safe again.
- Crash reports, core dumps, and interpreter traces must not include secret
  values. If the runtime cannot guarantee that, crash reporting is disabled for
  the release artifact.
- Tests use synthetic secret values only. A fixture must never contain a real
  credential.

### Time, temporary files, and persistent state

- Wall-clock and CPU time are read through the harness seam; time is not an
  authority negotiation item.
- Temporary files are created inside the workspace or in a user-private runtime
  directory with restrictive permissions, and are removed when the job closes.
  The standalone backend uses `$XDG_RUNTIME_DIR/wheel` when set, otherwise
  `$XDG_STATE_HOME/wheel/tmp`, otherwise `$HOME/.local/state/wheel/tmp`; the
  directory is created or repaired with mode 0700 before a path is returned.
  The ambient `os.tmpname` location is not used.
- Durable harness state lives under `$XDG_STATE_HOME/wheel/`; user
  configuration lives under `$XDG_CONFIG_HOME/wheel/`. Both are user-owned and
  outside model-visible workspace authority. No state path is hardcoded to a
  developer checkout.
- The trust store is written atomically with restrictive permissions: the
  harness-owned directory is `0700`, the file `0600`, and a same-directory
  temporary file is renamed over the target. The store has no `/tmp` or other
  predictable fallback, and a symlinked, non-regular, foreign-owned,
  group/world-writable, oversized, corrupt, or foreign-version store fails
  closed with a surfaced warning. No execution audit log exists yet; see
  [Relationship to current code](#relationship-to-current-code).

## Path sandbox and role gates

### Path sandbox

The path sandbox is a policy gate, not an OS boundary. It must:

- resolve the root once per session and re-check containment on every access;
- reject traversal after normalization, not before;
- resolve symlinks and reject targets outside the root, including for writes;
- reject devices, sockets, FIFOs, and other non-regular files for file tools;
- reject NUL and control bytes in paths;
- apply the same rules to tool arguments, cwd selection, glob results, and
  artifact paths;
- fail closed on resolver errors and never fall back to the process cwd;
- re-validate immediately before open/write to narrow the time-of-check to
  time-of-use window where the runtime permits it.

The sandbox does not constrain programs launched through argv or shell. That
limitation is stated in the residual risks.

### Role gates

Roles are configuration within the software-engineering domain, not separate
security principals. The following matrix is mandatory and fail-closed:

| Role      | Inspect | Modify | Execute | Custom mutating |
| --------- | ------- | ------ | ------- | --------------- |
| Primary   | Allow   | Allow  | Allow   | Allow           |
| Commander | Allow   | Deny   | Allow   | Deny            |
| Coding    | Allow   | Allow  | Allow   | Allow           |
| Debug     | Allow   | Allow  | Allow   | Allow           |
| Research  | Allow   | Deny   | Deny    | Deny            |
| Reviewer  | Allow   | Deny   | Deny    | Deny            |

- `Research` and `Reviewer` are strictly read-only. They cannot execute shell
  strings, argv, network tools, or mutating custom tools.
- `Commander` plans and orchestrates; direct code modification is delegated to
  a worker.
- A subagent cannot exceed the authority of the agent that dispatched it. A
  reviewer is dispatched with read-only authority and cannot approve work it
  implemented.
- A role gate denial is a typed failure, recorded in audit, and never presented
  as a capability denial for a surface that does not exist.
- Project configuration may narrow a role's tool set. It may not widen a role
  beyond the matrix, grant a read-only role a mutating tool, or disable a gate.

## Command deny-list

The deny-list is intended as categorical defense-in-depth, not a sandbox and not
a complete enumeration. A match refuses the command before spawn. The current
scanner implements only a subset of the categories below; the missing categories
are a known gap. The categories are:

- recursive or forced deletion of a filesystem root, the user's home directory,
  the workspace root itself, or any path outside the workspace root;
- disk formatting, partition editing, raw block-device writes, and `dd` to a
  device;
- fork bombs, process-table exhaustion, and unbounded recursive process
  creation;
- system shutdown, reboot, suspend, and power-state changes;
- privilege transitions: `sudo`, `su`, `doas`, `pkexec`, setuid/setgid
  execution, and capability changes;
- credential-store exfiltration: commands targeting SSH, GPG, cloud, or
  keychain material, including archive-and-upload patterns;
- piping remote or decoded content directly into a shell or interpreter;
- disabling, truncating, or redirecting the audit log, trust store, or
  redaction path;
- ownership or permission changes outside the workspace root;
- detached execution intended to outlive the harness process group.

Rules:

- Patterns are maintained as named constants in one place and covered by
  positive and negative tests.
- A denied command returns a structured failure and is audited with the matched
  category, never the raw secret-bearing command.
- Destructive but legitimate operations not on the list (for example a forced
  Git clean inside the workspace) require explicit user confirmation rather than
  silent execution.
- The deny-list must never be described as making arbitrary shell safe.

## Executable project configuration trust gate

Wheel retains executable `.wheel/init.lua` for 0.1.0. Project configuration is
code, and cloning or entering a repository must never execute it silently.

### Consent and pinning

- First contact is inert. Discovery, opening a repository, scanning a
  directory, listing commands, `--help`, or a status query must not read and
  evaluate the project entry.
- On the first command that needs project configuration, the harness shows the
  canonical project root, the full entry content within the accepted size cap,
  its full 64-hex SHA-256 content hash, and a pure-Lua line diff against the
  previously trusted bytes on re-approval. A truncated preview is not sufficient
  consent. Every content and diff line is escaped (non-printables as `\xNN`) and
  prefixed inside a per-run nonce delimiter, so a forged marker or control byte
  cannot impersonate the boundary. The entry is refused, never truncated, when
  it exceeds the cap or is a symlink or other non-regular file.
- A concrete entry-specific list of the configuration effects cannot be
  produced without evaluating it. The consent view states that limitation, the
  class of effects the configuration surface can request (roles/models,
  directives, tool lists, skill filters, verification, context, panel, hooks),
  and does not evaluate untrusted code; effects are applied only after
  confirmation, by the restricted evaluator on a later load. The policy does
  not require pre-consent evaluation to produce an entry-specific list. The
  class-level statement is a description of the existing configuration surface,
  not a new owner decision or an entry-specific effects list.
- Approval is an explicit interactive action by the user. The confirmation
  requires the full current SHA-256; a stale, partial, or mismatched hash writes
  no record. There is no `--yes`-style default, no environment variable that
  pre-approves a project, and no trust inherited from a parent directory, a
  previous checkout path, or another machine.
- The trust record binds the canonical project root and the SHA-256 hash of the
  entry bytes. Any content change, including a whitespace-only change,
  invalidates the record and forces re-approval.
- A changed entry is shown as a diff against the previously trusted content
  before re-approval.
- The trust store lives at `$XDG_STATE_HOME/wheel/trusted_projects.json`, is
  user-owned with restrictive permissions, and contains no secrets beyond the
  project path, hash, approved content, and approval timestamp. It is created
  `0700`/`0600` and replaced atomically; there is no `/tmp` fallback. Write-side
  project-count and byte caps match the read-side caps (256 projects and 1 MiB),
  so a successful write cannot create a store that the next read rejects.
- A missing, symlinked, non-regular, foreign-owned, group/world-writable,
  corrupt, foreign-version, oversized, or unreadable trust store fails closed:
  every project is untrusted and the warning is surfaced. It is never silently
  read as an empty approving store or recreated with existing approvals.
- CI and unattended runs have no implicit trust. They must either use a fixture
  that is explicitly approved out of band or fail closed.
- A symlinked project root resolves to its canonical path. Moving or copying a
  repository changes the trust key and requires re-approval. Distinct Git
  worktrees are distinct roots.

### Revocation

- The user can revoke one project or all projects. `trust revoke [path]` removes
  the canonical record and every alias or legacy key that resolves to the same
  root; it does not require the entry file to exist and does not require
  deleting files.
- Deleting the trust store is equivalent to revoking all projects.
- Revocation takes effect for the next configuration load. An already running
  session may continue with the configuration it loaded; the harness must
  surface that state and require a restart for a full rollback.
- A project that fails evaluation does not become trusted by retry.

### No ambient or execute-on-load execution

- The entry is never evaluated during installation, clone, checkout, editor
  open, file watch, dependency install, or repository indexing.
- Loading a command definition, rendering help, or starting a session without a
  configuration-needing command does not evaluate project code.
- There is no auto-trust for repositories owned by the current user, no
  "trust on first use", and no trust derived from a remote URL.
- Project hooks, if adopted, run only inside the same consent and restricted
  environment. A hook cannot acquire process, filesystem, network, or secret
  authority that the configuration environment does not have.

### Restricted evaluation environment

The project entry is evaluated as a single Lua chunk in a fresh environment
with no ambient authority:

- no `io`, `os`, `require`, `package`, `debug`, `load`, `loadstring`, `dofile`,
  `getfenv`, `setfenv`, or module loader;
- no `pcall` or `xpcall`, so the instruction-budget error cannot be caught by
  the entry;
- no filesystem, process, network, environment, clock, or random-device access;
- no access to the harness's global environment, trust store, audit log, or
  secret material;
- only pure data and computation libraries needed to return a configuration
  table;
- a finite instruction, wall-clock, and memory budget, enforced before the
  chunk can exhaust the harness;
- errors are captured and reported as a configuration failure, never as an
  execution path.

The evaluation result is data. Full field validation and narrowing-only
enforcement are not implemented yet: the loader currently merges the returned
table without validating every field, which is a known gap below. The trust
gate itself never evaluates the entry before consent.

Current implementation status for the budget bullet: the evaluator installs an
instruction-count hook and removes `pcall`/`xpcall` so the hook error is not
catchable. It caps direct and method-call forms of `string.rep`/`table.concat`
per call and cumulatively by patching the real string/table tables for the eval
duration and restoring them on every path. It does not yet enforce a wall-clock
kill or a true heap limit, and long-running C library calls (patterns,
formatting, sorting, compression) and other allocations are not preempted or
metered. These bounds are best-effort; a killable evaluation subprocess remains
the durable fix.

### Project configuration cannot widen authority

Project configuration may narrow behavior inside the approved ceiling:

- select among user-configured provider profiles;
- restrict tools, paths inside the workspace, budgets, and roles;
- define project commands, prompts, policies, and verification steps that run
  later through normal gated tool calls.

It may not:

- change the workspace root or add another root;
- add a network destination, proxy, or base URL;
- name a new secret environment variable;
- grant shell, argv, network, or secret authority to a role that lacks it;
- disable audit, redaction, the deny-list, the path sandbox, or the trust gate;
- read the harness's global configuration, trust store, audit log, or secrets;
- execute processes, access the filesystem, or open sockets during evaluation.

A project configuration that requests an effect outside these limits is a
policy violation and must be rejected as a policy error, not silently clamped.
The current loader does not yet validate every field or enforce narrowing-only
merging; it merges the returned table and is listed as a known gap below. A
trusted entry therefore remains user-approved code, not a validated data
contract.

### OQ-068 divergence record

OQ-068 (owner ruling 2026-09-23) records the platform position that Git-tracked
`.wheel/` is declarative-data-only (`project.toml`, `agents/`, `workflows/`,
`prompts/`, `policies/`, `tools/`, `skills/`) and does not authorize execution
of a project entry.

The owner decision of 2026-10-20 (wheel#51, D5) keeps executable
`.wheel/init.lua` for Wheel 0.1.0. This is a deliberate Wheel-local divergence,
recorded here rather than edited into the accepted corpus:

- It applies only to the independent Wheel harness. No Bitty host, plugin, or
  other consumer gains permission to execute `.wheel/init.lua`.
- It does not modify OQ-068, RFC-0005, the Plugin Platform RFC, or any accepted
  contract. Those documents remain authoritative for their own consumers.
- It is bounded by this trust gate: no ambient execution, explicit per-project
  consent, content-hash pinning, revocation, and restricted evaluation.
- If Wheel later ships a plugin facade, OQ-068 applies to that facade; the
  executable entry remains harness-only.
- If the platform later adopts an executable project-configuration contract,
  Wheel reconciles with it through a new scoped decision rather than treating
  this divergence as precedent.

## Installation and upgrade trust path

Wheel 0.1.0 installs from a local artifact, not a registry or plugin manager.
The install path is part of the trust boundary because it decides which code
runs with the user's authority.

- **Artifact definition.** The root `VERSION` file is the single source of the
  harness version. `just package` builds `dist/wheel-<version>.tar.gz` from
  tracked inputs only and refuses a dirty worktree, a missing input, or a
  version outside `X.Y.Z`. The archive contains `lua/`, `LICENSE`, `README.md`,
  `SECURITY-MODEL.md`, `repo.toml`, and `VERSION`; it excludes tests,
  recording, dependency trees, Git metadata, CI, scripts, the justfile, and
  `dist/`. Only `lua/` files tracked by Git are copied; ignored and untracked
  files are never package inputs. It carries no plugin manifest and no
  plugin-api compatibility field.
- **Determinism and integrity.** The archive uses sorted members, fixed mtime
  and ownership, normalized modes regardless of the caller's umask, and
  timestamp-free gzip. A SHA-256 sidecar
  and a manifest record the digest, contents, and the full source revision for
  a clean build (a null revision and clean flag false for a local test build). The installer verifies the
  sidecar before extraction. The digest is integrity only; 0.1.0 is unsigned,
  has no publisher authentication, and has no update channel. An attacker who
  can replace both the archive and its sidecar is outside this control.
- **No evaluation or network.** The installer contains no `eval`, does not
  construct shell commands from archive members, does not execute post-install
  scripts, and performs no network request. Artifact content is data until a
  Lua 5.1 process requires the module tree.
- **Prefix and target rules.** A prefix must be absolute, exist, be writable,
  and must not be `/`, end with `/`, contain `.`/`..` components, or be a
  symlink. The install root `<prefix>/wheel` must carry the Wheel ownership
  marker; an existing root without it is refused as non-owned. Version
  directories, `current`, and `previous` targets must be real directories or
  the expected relative symlink and are never followed outside the root.
- **Archive member rules.** Extraction rejects absolute paths, `..` segments,
  members outside `wheel-<version>/`, symlinks, hard links, devices, and other
  non-regular members. The tree is extracted into a private staging directory,
  its `VERSION` and allowed top-level entries are validated, and only then is
  it renamed into place.
- **Switch and rollback.** `current` is replaced atomically with a relative
  symlink (GNU `mv -T`); the outgoing version is written to `previous`. Rollback is an
  explicit local action that swaps the two; it does not fetch, verify a
  signature, or contact a registry. A failed digest check, extraction, or tree
  validation leaves no version directory; a failure after the rename leaves
  the version unreferenced by `current`.
- **Not a security boundary.** The marker, digest, and path checks defend
  against accidental clobbering and corrupted transport, not against a
  same-user attacker who controls the prefix or the repository checkout.
  Installing as root or into a system prefix is not a 0.1.0 use case.

## Audit and logging

- The harness writes a local, append-only audit stream under
  `$XDG_STATE_HOME/wheel/audit/`, user-owned with restrictive permissions, in a
  line-delimited structured format.
- Recorded events include: session start and stop; workspace root selection;
  configuration load, trust approval, denial, and revocation; every tool
  invocation with role, agent, task, tool name, and intent; argv or redacted
  shell command; cwd; allow or deny decision and reason; exit status; duration;
  output truncation; network destination and purpose; secret read by name only;
  and every policy or authority change.
- Never recorded: secret values, authorization headers, full prompts or
  transcripts by default, file contents, or raw provider responses.
- Shell commands and argv are redacted with the same passes as other outputs.
  When redaction removes a value, the record keeps a stable hash so an operator
  can correlate events without recovering the secret.
- High-risk operations (shell strings, secret reads, trust approval, network
  requests to a new destination) fail closed if the audit record cannot be
  written. Lower-risk operations surface a visible warning and continue.
- The audit stream is rotated under a finite size and retention policy. It is
  local only; no remote telemetry is sent by default.
- Audit integrity is not a boundary against the same OS user. A user or a
  compromised process running as that user can modify the files. Append-only
  structure and an optional hash chain raise the cost of silent tampering; they
  do not make the log tamper-proof.
- The user can inspect and export the audit stream without exposing redacted
  values.

## Secret handling and redaction

The secret path is treated as a data-flow problem, not a string-filter problem:

1. **Intake.** Read only named allowlisted variables through one accessor.
2. **Use.** Attach the value only to the matching provider client's
   authorization header.
3. **Propagation.** Never place it in prompts, context slots, checkpoints,
   blobs, artifacts, child environments, command lines, project configuration,
   global configuration, the trust store, or audit records.
4. **Egress.** Send it only to the configured provider host over verified TLS;
   refuse redirects to another host.
5. **Persistence.** Apply exact-value and shape-based redaction before any write
   to disk or display. Fail closed if redaction cannot be applied.
6. **Recovery.** Rotate at the source after any suspected exposure. Removing a
   log, checkpoint, or artifact does not revoke a leaked credential.
7. **Verification.** Tests use synthetic values and assert absence in every
   sink: stdout, stderr, errors, audit, blobs, checkpoints, context slots, and
   artifact exports.

Known limits: the value exists in process memory and in the TLS terminator;
redaction is heuristic for values the harness did not load itself; a child
process with network access can exfiltrate anything the user can read. These
limits are recorded in the residual risks and are not waived by the approval of
secret environment reads.

## Threat model and residual risks

### Trusted and untrusted

| Element                              | Trust                   | Consequence                                             |
| ------------------------------------ | ----------------------- | ------------------------------------------------------- |
| Harness artifact and reviewed code   | Trusted                 | A defect is user-level compromise                       |
| User-level Wheel configuration       | Trusted (user-owned)    | Can redirect providers and weaken policy by user choice |
| OS user account                      | Trusted boundary        | No privilege separation inside the account              |
| Model output and tool calls          | Untrusted               | May attempt destructive or exfiltrating actions         |
| Repository content                   | Untrusted               | May contain prompt injection and hostile scripts        |
| `.wheel/init.lua` before consent     | Untrusted               | Never evaluated                                         |
| `.wheel/init.lua` after consent      | Reviewed but still code | Runs in the restricted config environment               |
| Command output and network responses | Untrusted               | May contain injection payloads and secrets              |
| Third-party tools and dependencies   | Untrusted supply chain  | Run with the user's authority                           |
| Future IPC peer                      | Untrusted               | Requires per-scope consent and its own review           |

### Threats and controls

| Threat                                            | Control                                                                                    | Residual risk                                              |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------- |
| Model-driven destructive command                  | Role gates, deny-list, confirmation gates, audit, process ownership                        | A legitimate-looking destructive command can still pass    |
| Prompt injection in repository or command output  | Treat all content as data, no automatic tool escalation, audit, explicit user approval     | The model can be persuaded within its granted authority    |
| Malicious project configuration                   | No ambient execution, explicit consent, hash pinning, restricted evaluation, budget        | Trusted code can still consume CPU/memory and shape policy |
| Path traversal or symlink escape                  | Canonical root, normalized containment, symlink target resolution, fail-closed errors      | TOCTOU races the runtime cannot fully close                |
| Secret leakage through logs or artifacts          | Central accessor, exact and shape redaction, fail-closed persistence, synthetic tests      | Novel secret shapes may evade heuristic redaction          |
| Secret exfiltration through network redirection   | Provider allowlist, no project base-URL override, same-host redirects, TLS verification    | Compromised harness or user-level malware can exfiltrate   |
| Shell escaping the workspace                      | cwd, scrubbed env, deny-list, audit, unattended opt-in                                     | Shell can write anywhere the user can; no OS confinement   |
| Supply-chain compromise of tools or dependencies  | Pinned versions, lockfiles, provenance review, no install scripts with ambient authority   | Upstream compromise remains possible                       |
| Trust-store tampering                             | User-owned restrictive file, atomic writes, fail-closed corruption handling                | Same-user processes can rewrite it                         |
| Audit bypass                                      | Mandatory pre-spawn records, fail-closed high-risk operations                              | Same-user processes can tamper with the log                |
| Orphaned or daemonized processes                  | Owned process groups, no detach, recorded-PID cancellation, cleanup on close               | A child can still escape supervision by design or defect   |
| Denial of service through output or configuration | Finite output, timeouts, instruction/time/memory budget for project configuration          | Resource exhaustion can still degrade the session          |
| Stale manifest misread as authority               | Descriptor and docs state the manifest is transitional; manifest unchanged and not widened | A reader may still assume plugin semantics                 |
| Future IPC confused deputy                        | Per-scope, per-client consent and server-side evaluation; no authority lending             | Not designed or implemented in 0.1.0                       |
| Update-channel compromise                         | Signed artifacts and verified updates are required before release                          | No signing or update channel exists yet                    |
| Cross-workspace access in multi-root sessions     | Tool bound to one root; explicit root grants; no implicit nesting                          | A tool with a root grant can reach that whole root         |
| Secret exposure through crash reporting           | No secret values in traces; disable crash reporting when it cannot be guaranteed           | Runtime-level dumps are outside harness control            |

### Residual risks accepted for 0.1.0

- The harness is trusted software running as the user. There is no OS sandbox,
  privilege drop, or per-agent isolation.
- Shell strings and argv can reach anything the user can reach. The workspace
  path policy governs harness-mediated file tools, not arbitrary programs.
- Project configuration is code after consent. The restricted environment
  removes ambient authority, but a trusted configuration can still consume
  resources and shape policy within the allowed fields.
- Model providers receive prompts and code by design. Secret values are not
  included, but repository content sent to a provider leaves the machine.
- Third-party tools and dependencies run with user authority.
- The audit log and trust store are same-user files, not a tamper-proof record.
- No release artifact, signature, or update channel exists yet; none may be
  claimed.
- No mock/unit or real host fixture evidence exists yet for the 0.1.0 ceiling;
  this document is a gate definition, not a pass.

## Evidence gates before widening

The 0.1.0 ceiling is approved, but it is not released evidence. Both gates
below are required for the ceiling before a 0.1.0 artifact may claim it, and for
any widening at any later time.

### Gate 1: mock and unit evidence

Deterministic tests, no real host required, covering at minimum:

- allow and deny for every authority class and every role/intent pair;
- path traversal, absolute escape, symlink escape, dangling symlink, NUL byte,
  encoded traversal, and non-regular file rejection;
- deny-list positive and negative cases, including bypass attempts;
- trust gate: no execution before consent, hash change invalidation, revocation,
  corrupt store fail-closed, no implicit CI trust, no permissive bypass in
  production paths;
- secret handling: synthetic secrets absent from stdout, stderr, errors, audit,
  blobs, checkpoints, context slots, and child environments;
- audit: pre-spawn record, required fields, redaction, fail-closed behavior;
- shell: unattended default, explicit opt-in, non-login invocation, scrubbed
  environment, timeout and output bounds;
- network: endpoint allowlist, redirect refusal, TLS verification, no project
  base-URL override;
- process ownership: timeout, cancellation by recorded PID only, orphan cleanup.

### Gate 2: real host fixture evidence

An end-to-end run in a real environment, with no mocked filesystem, process, or
network boundary, covering at minimum:

- a real workspace with nested directories and symlinks that point outside the
  root;
- real argv and shell execution, including a denied destructive command and a
  permitted build or test command;
- real process timeout and cancellation, with an orphan check after the run;
- a loopback provider stub with a synthetic key, proving the key reaches only
  the stub and never appears in logs or artifacts;
- trust approval, content change, re-approval, and revocation across a restart;
- audit output inspected by the reviewer, not summarized by the implementer;
- the terminal presentation path where the harness runs in a Bitty panel,
  recorded with the host version and tool versions.

The current `tests/real_host_fixture.lua` covers activation, command smoke, real
filesystem/process/temporary-file behavior, path and destructive-command
denials, and the trust approval/content-change/re-approval/revocation-across-
restart flow against a private XDG state directory. It does not cover process
timeout/cancellation, a provider stub, audit output, or a Bitty panel
presentation, so Gate 2 remains open and this is not a security approval.

Because Wheel is out of process, the "real host fixture" is the real OS and
terminal boundary, not a plugin VM activation. A plugin-host fixture is not
evidence for this model.

### Widening definition and process

Widening includes: a new authority class; a broader workspace root or path
pattern; a new secret name or prefix; a new network destination, proxy, or
plaintext endpoint; shell or TTY capabilities for unattended sessions;
detached or background execution; new project-configuration powers; weaker
audit, redaction, trust, or role gating; and any change that increases the
blast radius inside an approved class.

Before widening:

1. Record the proposed change and its blast-radius rationale in a scoped task.
2. Pass Gate 1 and Gate 2 on the widened behavior.
3. Obtain independent security review by an agent that did not implement it.
4. Obtain owner approval for the widened ceiling.
5. Record the evidence artifacts in the pull request and CarryCtx; a prose
   claim or a green generic CI run is not evidence.

## Relationship to current code

This section is inventory, not assurance. The repository contains mechanisms
that the policy relies on, and they remain unverified until the gates pass:

- a lexical path resolver and canonicalization routine used by file and cwd
  arguments (containment only; see gaps);
- role gates for the read-only roles and Commander Modify, plus a partial
  custom-tool check;
- a dangerous-command scanner covering a subset of the policy categories;
- a project-configuration trust gate with a bounded 32 KiB reader, regular-file
  and symlink refusal, host canonical-root resolution, native SHA-256 over the
  exact bytes, full-content/diff consent, exact-hash confirmation, canonical
  plus alias revocation, a versioned `0700`/`0600` atomically replaced store,
  and a restricted evaluation environment with no `pcall`/`xpcall` and
  per-call/aggregate string and table caps;
- a provider adapter boundary that reads named environment variables;
- a `WheelHost` seam that concentrates filesystem, process, temporary-file,
  wall-clock, and CPU-time calls. The production backend is the standalone
  POSIX surface, selected explicitly with `select_backend("standalone")`;
  unsupported platforms and unavailable primitives fail closed with typed
  denials. No direct `io.open`, `io.popen`, `os.remove`, `os.execute`,
  `os.tmpname`, `os.time`, or `os.clock` call remains outside `host.lua`.

Backend-selection decision: the 0.1.0 harness has exactly one execution
backend, the standalone POSIX surface, selected explicitly with
`WheelHost.select_backend("standalone")`. There is no fallback to a plugin
host, no `bitty.api_version` authority probe, and no implicit in-process
adapter. A non-POSIX platform fails closed at seam construction. A future host
IPC client is presentation-only; adding an execution adapter requires the
widening process above.

Known gaps relative to this policy (not claims of compliance):

- Path containment is lexical only. The resolver rejects `..` traversal and
  absolute paths outside the root, but does not reject NUL/control bytes,
  resolve symlink targets, reject non-regular files, or re-validate at open
  time. Writes truncate in place; there is no atomic temp-file-plus-rename.
- Inspect-intent tools now pass argv through `WheelHost.proc.run_program` and
  quote cwd with a single-quote helper, but `run_command` remains the explicit
  shell-string primitive: the command body is model-provided by design and is
  screened only by the partial deny-list.
- The child environment is inherited from the parent. `run_command` does not
  scrub allowlisted provider keys, so spawned processes can read them.
  Non-inheritance is required before release.
- A home-rooted workspace does not exclude the harness's own
  `$XDG_CONFIG_HOME`/`$XDG_STATE_HOME` files, so a file tool can read or write
  the trust store or audit log when they fall under the root. The trust-store
  self-approval path is open.
- `write_file` can write `.git/hooks/*` and `.git/config`; there is no guard
  against direct Git-internals rewrites.
- The dangerous-command scanner covers only a subset of the policy categories:
  it does not implement privilege-transition (`sudo`, `su`, `doas`, `pkexec`),
  setuid/setgid, credential-store exfiltration, remote-pipe, audit/trust
  tampering, ownership-outside-root, or detach screening. Rejections are
  free-form errors, not the typed failure boundary.
- The role matrix is only partially enforced: `Research`/`Reviewer` are
  read-only and `Commander` is denied Modify, but there is no `Primary` role,
  and Commander Custom-mutating and the full matrix are not enforced.
- The process backend does not enforce the accepted timeout, bounded output,
  interactive stdin/TTY-off default, detached-execution denial, or an owned
  process group; cancellation by recorded PID/process group is policy only.
- The project-configuration trust gate now refuses symlinks/non-regular and
  oversized entries before hashing, resolves the canonical root through the
  host, shows escaped full content plus a pure-Lua change diff under a per-run
  nonce delimiter, requires the exact full hash to confirm, supports
  user-facing canonical/alias revocation, and writes a `0700`/`0600` versioned
  store atomically with matching read/write caps. `pcall`/`xpcall` are no
  longer exposed and direct and method-call forms of
  `string.rep`/`table.concat` have per-call and cumulative caps. Remaining
  gaps: evaluation is still in-process, so the instruction hook counts VM
  instructions but cannot preempt a long-running C library call, and there is
  no wall-clock kill or real memory limit; patterns, `string.format`,
  concatenation, sort comparators, and other allocations are not metered. The
  bounded caps are best-effort, not an OS sandbox. A killable evaluation
  subprocess is the durable fix. The loader still exposes internal
  `opts.trusted`, `trust_mode = "permissive"`, `trust_file`, and `global_path`
  seams; no command or environment variable reaches them in production paths,
  but they are not a policy boundary.
- Native hashing and host metadata resolve `sha256sum`/`shasum`/`openssl`,
  `realpath`/`readlink`, `stat`, `test`, `id`, and `mktemp` through `PATH`. A
  same-user attacker who controls the environment or `PATH` can influence
  those tools; the checks are not a privilege boundary. Trust approval is a
  high-risk operation, and the policy requires it to fail closed when audit
  cannot record it; no execution audit stream exists yet, so that control is
  not implemented.
- The trust store is a same-user file, so a same-user process can still rewrite
  it; ownership and permission checks narrow accidental or cross-user misuse,
  not a compromised account. The atomic rename orders the replacement but the
  store is not fsynced, and the format has no signature or hash chain.
  Temporarily unresolvable project records are preserved by the write path
  rather than dropped, but they remain untrusted until their root resolves.
- There is no append-only execution audit stream with pre-spawn records and
  fail-closed behavior, and no exact-value secret redaction across every sink.
- Project configuration is merged as an unvalidated table; field validation and
  narrowing-only enforcement are absent. Multi-root operation is not
  implemented (one `workspace_root` per session).
- CI and unattended runs have no implicit-trust enforcement in the current
  loader; trust behavior in CI is not gated.
- There is no OS-level confinement for argv or shell execution, no reviewed
  in-tree network client (provider adapters accept an injected client), no
  signed release artifact or update channel, and no Gate 1/Gate 2 evidence for
  the 0.1.0 ceiling. The local install path verifies a SHA-256 digest and
  rejects unsafe members and targets, but it provides integrity only: it does
  not authenticate the publisher, and the marker and sidecar are same-user
  mutable.
- The in-tree plugin manifest still describes `platform.notify` and
  `compat.plugin-api`; it is retained unchanged pending a follow-up removal
  task. It is not the harness authority model and must not be widened.

These gaps are blockers for release evidence, not for recording the policy.

## Open points

- OS confinement for spawned programs: Landlock, cgroups, seccomp, or an
  equivalent, and whether it becomes a prerequisite for shell authority.
- Audit format, rotation bounds, retention, and optional hash-chain integrity.
- Redaction coverage for provider-specific key shapes and streamed fragments.
- Default shell mode for unattended and scheduled sessions.
- Instruction, time, and memory budgets for project-configuration evaluation.
- Trust-store integrity and same-user tampering expectations.
- Trust coverage if project configuration ever loads modules or referenced
  files rather than a single entry chunk.
- Global configuration permissions and whether it needs an explicit review step
  in addition to user ownership.
- Artifact signing, distribution, and update verification.
- Optional IPC client scopes and consent UX, if host-visible operations are
  added after 0.1.0.
- Removal of the transitional plugin manifest and its SDK lint gate.
- Whether project configuration may ever narrow network destinations without
  user-level approval.

## Security review checklist

An independent reviewer verifies at least:

1. The six approved classes are recorded accurately and no seventh class is
   implied.
2. Shell strings and secret environment reads have controls beyond ordinary
   file access, as the owner required.
3. Project-configuration execution has explicit consent, hash pinning,
   revocation, no ambient execution, and no execute-on-load path.
4. The OQ-068 divergence is explicit, scoped, and does not rewrite accepted
   documents.
5. The path sandbox and role gates are described as policy, not as an OS
   boundary.
6. The deny-list is described as defense-in-depth, with its limits stated.
7. Audit and redaction requirements cover every persistence sink and fail
   closed where required.
8. Residual risks are honest about user-level authority, shell escape, trusted
   configuration, and missing confinement.
9. The evidence gates are reproducible and the widening process requires both
   gates plus independent review and owner approval.
10. No implementation, release, or compatibility claim exceeds the evidence.

## Affected contracts

- No canonical contract is changed by this document.
- `repo.toml`, `README.md`, `AGENTS.md`, `SECURITY.md`, and this file record the
  owner-approved position change. `workspace.toml` is updated by the umbrella
  owner.
- `bitty-plugin.toml` is unchanged by this task. It remains a transitional
  artifact and is not the 0.1.0 distribution path.
- The 0.1.0 artifact path (`VERSION`, `just package`, `just install-local`,
  `just rollback-local`) is repository-local implementation. It consumes no
  Bitty plugin, registry, or package contract and claims no host compatibility.
- OQ-068 and RFC-0005 remain in force for their own consumers. The divergence
  is Wheel-local and recorded above.

## Acceptance criteria

- An independent security reviewer approves this model, and no high-severity
  finding remains open.
- The owner decisions D1-D7 are represented without extension or dilution.
- Descriptor and scope documents agree with this model and with each other.
- The manifest and execution code are unchanged by the position record.
- Technical terms are used consistently; no implementation or release claim is
  made beyond the evidence.
- Widening and release evidence are tracked as follow-up work, not asserted
  here.

## References

- wheel#51, owner decision comments of 2026-10-20 (D1-D7).
- [SECURITY.md](SECURITY.md), the repository reporting policy.
- `bitty-docs` security corpus: overview, threat model, and risk register.
- `bitty-docs` OQ-068, `.wheel/` declarative-data-only position.
- `bitty-docs` RFC-0005, filesystem host surface (v2-only; mediated read).
- `bitty-plugins-docs/specifications/manifest-capability-authority.md`,
  accepted manifest and capability grammar.
- `bitty-plugins-docs/specifications/plugin-platform-rfc.md`, capability closed
  set and deny-by-default model.
- `bitty-terminal-docs/specifications/execution-extraction-contract.md`,
  principal-scoped execution and typed failures.
- `bitty-ai-docs/specifications/wheel-project-config-candidate.md`, candidate
  project-configuration shape (draft; not a runtime specification).

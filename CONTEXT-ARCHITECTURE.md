# Wheel Context and Runtime Architecture

> Status: **draft design, not a complete implementation contract.** This page
> records the target architecture for the work tracked by Wheel issue #109 and
> its child issues. Existing implementation notes are marked explicitly; a
> design statement must not be read as shipped behavior.

## 1. Scope and authority

Wheel is an independent out-of-process Coding Agent Harness. Its runtime Team
contains peer Agents; it is not a Main Agent/Subagent product. `Commander`,
`Coding`, `Debug`, `Research`, and `Reviewer` are roles and capability policies,
not an ownership hierarchy.

This design borrows durable lifecycle patterns from CarryCtx — separate Agent,
Session, Task, Worktree, Checkpoint, Decision, Handoff, and Event records — but
does not embed CarryCtx's database or turn Wheel into a project-management
replacement. CarryCtx remains a local-first project-state manager; Wheel owns
runtime execution, Context projection, provider requests, Panels, and Dashboard
interaction.

The design must not weaken:

- [`SECURITY-MODEL.md`](SECURITY-MODEL.md), which owns Wheel's authority ceiling,
  capability gates, redaction, audit, and process safety;
- the independent-harness position in [`README.md`](README.md);
- the `bittyd` boundary: `bittyd` owns session facts and lifecycle mechanisms,
  not prompts, Context content, Agent roles, model policy, Team policy, or
  Agent-to-Agent messages.

## 2. Independent entities

The independent identifier set below is the target architecture, not a
complete current runtime model. Current Wheel primitives cover only portions
of these concepts; the distinct identity and lifecycle boundaries described
here must not be read as implemented behavior.

The following identifiers are intentionally different:

```text
AgentId          who the long-lived Team member is
SessionId        one contiguous runtime period for an Agent
PanelId          the Headless working container or presentation attachment
TaskId           the engineering work item
ContextCommitId  an immutable structured-knowledge snapshot
BranchRef        a movable Context history reference
WorktreeId       an optional code workspace isolation record
CheckpointId     an immutable progress and evidence record
HandoffId        an audited transfer of Task continuity
```

Required non-equivalences:

```text
AgentId  != SessionId != PanelId != TaskId != ContextCommitId
```

An Agent can process many Tasks over its lifetime. Concurrent Tasks should use
independent Sessions and Panels; whether the harness permits that concurrency
is a runtime policy, not an identity change. Closing a Panel does not delete its
Agent or Task. A Session can move from one Panel to another only through an
explicit checkpointed detach/attach transition.

## 3. Agent lifecycle and role binding

### 3.1 Agent identity

The target Agent lifecycle is:

```text
registered -> available -> active -> paused/inactive -> available
                                      -> deactivated/archived
```

An Agent identity survives Task completion, Session end, Panel close, and
provider changes. Its durable lineage may include:

```text
forked_from_agent
forked_from_session
base_context_commit
fork_reason
```

### 3.2 Role transitions

Role is a binding applied at Team, Session, or Task scope. It determines actual
tool and capability policy; it is never trusted merely because the model says
that it has a role.

An ordinary role transition keeps the same AgentId but creates a new policy
generation and checkpoint boundary:

```text
Agent A / Session S1 / Coding
        -> checkpoint + role transition
Agent A / Session S2 / Reviewer
```

An Agent fork creates a new AgentId from an immutable ContextCommit when the
new participant needs independent identity, audit, concurrency, authority, or
lineage:

```text
Agent A --fork ContextCommit C1--> Agent B / Reviewer / Branch agent-b/review
```

Forking copies references and structured knowledge, not an unbounded chat
transcript.

## 4. Session and Panel lifecycle

### 4.1 Session

The target Session states are:

```text
created -> active -> paused -> active
                  -> stale
                  -> ended
                  -> abandoned
```

A Session records the Agent, optional Task, Panel attachment, RoleBinding,
ModelProfile, Context branch/head, optional Worktree, start/last-activity/end
times, and termination summary. Session state is not Agent state.

### 4.2 Panel

The target Panel states are:

```text
created -> ready -> attached -> active
                              -> paused
                              -> detached
                              -> closed
```

A Panel can be reused by different historical Sessions, but it must not host
two conflicting active Sessions at once. Observers do not receive execution
authority. A user-visible Dashboard view is an observation projection, not the
execution boundary.

The current `WheelAgent.panel_id` and `headless` fields implement only the
initial invariant. Panel registry, attachment history, and explicit lifecycle
transitions are tracked by issue #114.

## 5. Task lifecycle and hierarchy

Wheel's target Task states align with the durable CarryCtx model:

```text
planned -> ready -> in_progress -> review -> completed
                         |             |
                         v             v
                      blocked       cancelled
```

`parent_task_id` expresses hierarchy; dependency edges express execution
ordering. They must not be encoded only in display IDs such as
`TASK-0010.2.3`. A flat stable TaskId plus explicit parent and dependency
records supports tree, DAG, and flat Dashboard views simultaneously.

A Task may be handled by several Agent Sessions over time:

```text
Task T1 -> Agent A / Session S1 -> Handoff -> Agent B / Session S2 -> Review
```

Task ownership, Context history, and evidence survive every transfer. The
current Kernel has dependency promotion, generation fencing, and failure
cascade; parent tasks, the normalized review lifecycle, multiple active Tasks
per Agent identity, and durable Handoff state are tracked by issue #116.

## 6. Context as a versioned knowledge graph

Context is not a growing conversation string. It is a structured graph and
immutable history:

```text
Project Context Commit C0
  ├── Task branch T1 -> Session S1
  ├── Task branch T2 -> Session S2
  └── Agent fork branch B -> Session S3
```

Existing Wheel primitives already provide Semantic Slots, hashes, a Merkle
root, commits, refs, reflog, stash, three-way merge, cherry-pick, snapshots,
and canonical encoding. The target projection layer is:

```text
Raw records / evidence
        -> Context Graph
        -> role/task/session projection
        -> three-zone Prompt compiler
        -> provider message format
```

### 6.1 Prefix and delta model

The prefix analogy is a semantic delta, not string subtraction:

```text
BaseCommit = C1
CurrentCommit = C3
Delta = semantic_diff(C1, C3)
View = Project(BaseCommit, RoleLens, TaskView, SessionDelta, RecentTail)
```

The target layers are:

```text
P0 Project Prefix  stable project facts and documentation
P1 Role Prefix     role policy, tools, capability version
P2 Task Prefix     task, dependencies, scope, decisions, checkpoints
P3 Session Delta   new findings, evidence, risks, handoffs
P4 Recent Tail    current turn, recent actions, unresolved immediate work
```

P0 should primarily contain project documentation and durable architecture
facts, not the entire source tree. Code and raw logs are task-specific evidence
selected through scopes, graph references, symbol maps, and bounded reads.

### 6.2 Role-aware projections

Runtime implementation roles (`Commander`, `Coding`, `Debug`, `Research`, and
`Reviewer`) govern execution capability policy, whereas projection lenses
(`Planner`, `Documentation`, `Coding`, `Reviewer`, and `Research`) shape which
Context slots and deltas are compiled into the prompt view. Candidate or
domain-specific roles may compose a projection lens with a narrowed capability
binding, but a lens never widens runtime authority.

The same project must yield different views:

| Role          | Default high-value view                                                                  |
| ------------- | ---------------------------------------------------------------------------------------- |
| Planner       | project map, architecture, Task DAG, dependencies, scopes, decisions, blockers           |
| Documentation | document map, spine, terminology, canonical sources, open questions, link/metadata rules |
| Coding        | scoped modules, APIs, tests, build commands, related decisions, failure diagnostics      |
| Reviewer      | changed files, requirements, diff, evidence, security impact, known risks                |
| Research      | project map, external references, questions, provenance, read-only evidence              |

Role views are authorization-aware. A RoleLens can change what is projected;
it cannot grant a capability that the runtime did not grant.

## 7. High-density Prompt compilation

The current `WheelContext:compile_prompt()` provides a foundation toward these
target budgets and intended bounds:

```text
Zone 1: stable prefix, default 16 KiB
Zone 2: cognitive state, default 32 KiB
Zone 3: dynamic tail, default 16 KiB
Total: 64 KiB
```

Zone 1 remains fail-closed when its stable prefix exceeds its configured
budget. Zone 2 and the total are not guaranteed current enforcement limits:
large `workspace/*` slots are retained during the current reduction pipeline,
so they can leave Zone 2 over its target budget. If Zone 1 and Zone 2 already
consume more than the total target, the minimum Zone 3 tail can also leave the
final prompt over the total target. In either case, `compile_prompt()` can
still report `success = true`.

Its reduction order is intentionally asymmetric:

1. prune `scratch/*`;
2. shorten decision/task previews;
3. truncate the dynamic tail;
4. never silently truncate an over-budget stable prefix.

The current Zone 2 shortening is a bounded byte preview, not a semantic LLM
summary. The current Zone 3 action shortening is also a bounded preview. Issue
wheel#110 upgrades these into deterministic structured projections and semantic
delta references. Issue #111 bounds the autonomous conversation history and
replaces old messages with ContextRefs.

Provider cache negotiation is implemented behind `off`, `prefer` (the
default), and `required` policies. When supported and requested, the provider
cache key is derived from the exact bounded system-prefix bytes serialized in
the request and a domain containing the provider, model, endpoint, policy,
tool-schema, and capability versions. A caller-declared prefix that does not
match the serialized bytes, or exceeds the named bound, does not receive cache
controls; `required` fails closed. Unsupported providers remain usable in
`prefer` mode and fail closed in `required` mode.

Local prefix hashes and prefix-share ratios remain design/local-reuse signals,
not provider cache-hit evidence. Provider cache status and read/write token
counts are reported only from explicit provider response usage, and are kept
separate from local prefix telemetry. Wheel does not persist provider KV cache
contents, and `bittyd` owns neither prompt content nor provider cache state.

Normalized `prompt_tokens` preserves the provider's reported prompt/input
count. OpenAI `usage.prompt_tokens` includes cached tokens when reported, with
`prompt_tokens_details.cached_tokens` describing a subset of that count;
Anthropic `usage.input_tokens` is uncached input, with cache-read and
cache-creation counts reported separately. `uncached_input_tokens` is the
cross-provider uncached count. Consumers must not add OpenAI cache-read tokens
to `prompt_tokens`. Native cache counters take precedence over top-level
aliases, including explicit zeroes; supported aliases are fallbacks only when
the native field is absent. Normalized counts and cache status use the same
selected counters. Malformed, impossible, or contradictory cache counters
produce `error` while retaining independently valid native counts. Runner
cache status is independent of token totals and
aggregates by evidence priority: `error` > `verified_hit` > `write_only` >
`verified_miss` > `unknown` > `not_requested` > `unsupported`.

## 8. Output and reasoning density

The intended storage split is:

```text
raw evidence -> bounded capture / content-addressed blob
model view   -> diagnostics + preview + reference
Context      -> conclusions, evidence, risks, decisions, next actions
```

The current implementation already has:

- 256 KiB per-stream process capture bounds;
- 4 KiB tool spillover threshold;
- content-addressed `blobs/<hash>` storage;
- head/tail previews;
- bounded `search_code` output;
- `read_blob` range reads;
- timeout/truncation/spillover metadata.

Issue #112 moves the density boundary into durable Action Records and adds
deterministic build/compiler diagnostics so a middle-of-log error is preferred
over a generic tail such as `build failed`.

Provider thinking is transient by default. Issue #113 replaces fixed 300-byte
thinking excerpts with bounded structured Rationale fields such as decision,
evidence, uncertainty, risk, and next action. Full private reasoning is not a
normal Context slot, checkpoint, audit record, or replayed message.

## 9. Agent collaboration and Dashboard

Handoff is not the same as a question. The target runtime distinguishes:

```text
Handoff          transfers Task continuity and ownership
AgentRequest     asks a peer for information or clarification
AgentReply       answers a request
ContextShare     shares a ContextCommit/Branch reference
Decision         persists a project-level conclusion
```

Issue #117 exposes these operations to a Dashboard. Dashboard controls must
remain presentation and user-control surfaces; they must call the same runtime
authorization, fencing, audit, and bounded-output paths as autonomous Agents.

## 10. Capability ecosystem roadmap (#120)

> Status: **target architecture roadmap only (issue #120).** None of the
> candidate families below is implemented in current Wheel; each family requires
> a dedicated follow-up issue, conformance vectors, and independent security
> review before implementation.

Wheel remains a peer-Team harness (`AgentId != SessionId != PanelId != TaskId !=
ContextCommitId != WorktreeId`). Comparing external agent ecosystems (such as
OpenCode V2) informs capability coverage without importing a Main Agent ->
Subagent hierarchy or moving harness logic into `bittyd`.

### 10.1 Ownership matrix

| Capability family               | Wheel core (deterministic mechanism)                                                              | External adapter (out-of-process / stdio / IPC)                                           | Project extension (`.wheel/` / `~/.config/wheel/`)                         | Future sibling repository                                   | `bittyd` (forbidden beyond session host) |
| ------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------- |
| **LSP adapter**                 | Bounded diagnostic/symbol/reference schema, capability gate, Context slot projection              | Language-server process lifecycle, JSON-RPC framing, workspace root & timeout enforcement | Per-project server selection and read-only file-type bindings              | Shared multi-language LSP bridge if reused outside Wheel    | No LSP state, symbols, or authority      |
| **Project commands**            | Parameterized argv template validator, shell-refusal gate, output spillover, audit record         | Host process runner (`WheelHost.proc.run_program`)                                        | Named command definitions with explicit parameter schemas and role scopes  | None                                                        | No command templates or execution        |
| **Custom tools & MCP**          | Namespaced tool registry, schema/bound validator, per-request tool snapshot hash, capability gate | Local stdio or remote MCP client transport behind explicit capability & network policy    | Declarative tool/MCP server registrations pinned by digest and trust state | Standalone MCP protocol/transport library if shared         | No tool registry, dispatch, or MCP state |
| **Skills, instructions & refs** | Provenance record, SHA-256 content pin, trust-state gate, Context P0/P2 projection rules          | Git/filesystem fetcher under read-only path and size bounds                               | Skill packages and pinned documentation references                         | Curated skill/reference corpus repository                   | No prompt, skill, or reference storage   |
| **Formatter & lifecycle hooks** | Ordered hook runner, deterministic timeout/cancellation, byte bounds, failure policy, audit trail | External formatter binaries invoked as argv-only subprocesses                             | Hook bindings (`post_edit`, `pre_prompt`, `pre_compact`) with pinned argv  | None                                                        | No hook scheduling or execution          |
| **Permission & policy**         | Deterministic `allow`/`ask`/`deny` evaluator, policy-generation fence, fail-closed unattended ask | Optional interactive approval surface (Dashboard / CLI)                                   | Project/user policy files narrowing (never widening) higher scopes         | Shared policy-schema validator if adopted across Bitty AI   | Session lease/fence only; no tool policy |
| **Session & VCS integrations**  | `SessionId`, `ContextCommitId`, `WorktreeId`, compaction checkpoints, durable evidence links      | `bittyd` session-host client adapter; Git worktree CLI adapter                            | Project branch/worktree naming conventions                                 | CarryCtx (`carryctx`) for durable project lifecycle records | Session registry, leases, fences, audit  |

### 10.2 Audit separation (`bittyd` vs Wheel execution vs Dashboard)

Audit streams are partitioned by authority boundary:

1. **`bittyd` mechanism audit**: records only session-host mechanism facts
   (session creation/termination, attach/detach role, lease acquisition/expiry,
   generation fences, protocol handshake, and transport refusals). It never
   contains prompts, tool arguments, file contents, or model outputs.
2. **Wheel execution audit**: records harness authorization and activity
   (tool calls, command template expansions, LSP queries, MCP requests, hook
   executions, provider calls, policy-generation IDs, and redaction-safe
   summaries).
3. **Dashboard projections**: read-only observation views compiled from bounded
   Wheel execution audit and session status. Dashboard views never bypass
   execution audit or mutate state directly.

### 10.3 Permission and policy precedence

Authorization evaluates an ordered lattice across scopes:

```text
1. Organization ceiling (highest authority)
2. Project policy (.wheel/)
3. User policy (~/.config/wheel/)
4. Team policy
5. Agent role binding
6. Session binding
7. Task scope
8. Extension manifest (lowest authority)
```

Evaluation rules:

- **Deny wins**: an explicit `deny` at any layer is final; no lower layer may
  widen a capability denied or omitted by a higher ceiling.
- **Effective rule**: among non-denying layers, the most restrictive outcome
  (`deny` > `ask` > `allow`) applies over `(action, resource, capability_scope)`.
- **Generation binding**: every authorization decision records the active
  `capability_version` and `policy_generation` in the Action/Audit record; a
  policy change increments `policy_generation` and invalidates cached approvals.
- **Unattended `ask` fails closed**: in headless, batch, or unattended Sessions
  where no interactive approval channel is attached within the bounded deadline,
  `ask` evaluates to `deny` (`E_CAPABILITY_DENIED`).
- **Prompt text is never authority**: model output, skill prose, and reference
  documents cannot alter the policy lattice or grant capabilities.

### 10.4 Family safety, provenance, and bounds

- **LSP safety**: servers launch strictly via explicit `argv` (never shell
  evaluation), rooted at the validated workspace path with a scrubbed
  environment, no implicit network access, per-request deadlines, cancellation
  propagation, and bounded structured responses (diagnostics, symbols,
  definitions, references). The minimal first slice is **read-only**; workspace
  edits or code actions require the same write capability and path-sandbox check
  as `edit_file`.
- **Command-template safety**: project commands declare typed parameters and an
  `argv` array. Parameter values are passed as discrete `argv` elements without
  shell interpolation; raw shell blocks are refused unless an explicit,
  organization-permitted shell capability is granted and audited. Output obeys
  the 256 KiB stream cap and 4 KiB spillover boundary.
- **Custom tools, MCP, and stable snapshots**: each registered tool or MCP
  source carries `namespace`, `name`, `version`, `source_identity`,
  `schema_hash`, `capability_scope`, `timeout_ms`, and cancellation support.
  Before the first turn of a Session (or upon an explicit policy generation
  bump), Wheel freezes an immutable tool snapshot so mid-run registry changes
  cannot invalidate the provider prompt-cache domain or inject unreviewed tools.
- **Skills and references provenance**: every skill package or reference carries
  `source_uri`, `commit_or_version`, `sha256`, `trust_state` (`trusted`,
  `pinned`, `untrusted`, `revoked`), and refresh policy. Revoked or hash-mismatched
  entries fail closed before compilation. Untrusted reference text is fenced as
  quoted data in P2/P3 and never enters P0/P1 system instructions.
- **Formatter and lifecycle hooks**: hooks execute in deterministic declared
  order under explicit `timeout_ms`, byte bounds, cancellation propagation, and
  audit logging. A failing `pre_prompt` or `pre_compact` hook fails closed; a
  failing `post_edit` formatter hook records structured diagnostics without
  corrupting the working tree.

### 10.5 Minimal first slice and required conformance vectors

The minimal first implementation slice is limited to:

1. Deterministic permission/policy evaluator with generation fencing and
   fail-closed unattended `ask`;
2. Read-only argv-only LSP diagnostic/symbol query adapter;
3. Argv-only parameterized project commands with audit records.

Before any slice lands, its test suite must cover these conformance vectors:

- **Identity non-equivalence**: `AgentId`, `SessionId`, `PanelId`, `TaskId`,
  `ContextCommitId`, and `WorktreeId` remain distinct across capability calls.
- **Peer dispatch**: peer Agents invoke capabilities under their own role
  bindings without parent/subagent privilege inheritance.
- **Multi-session and multi-task isolation**: concurrent Sessions/Tasks cannot
  bleed tool snapshots, approvals, or hook state across bindings.
- **Handoff continuity**: transferring a Task preserves recorded Action/Audit
  provenance while re-evaluating capabilities against the receiving Agent's role
  and current `policy_generation`.
- **Branch and worktree isolation**: LSP, command, and hook side effects stay
  confined to the bound Context branch and `WorktreeId`.
- **Extension trust and revocation**: unpinned, hash-mismatched, or revoked
  skills/tools/MCP descriptors are rejected before execution or prompt
  compilation.
- **`bittyd` boundary**: zero LSP, command, MCP, skill, hook, or permission
  payloads cross the `bittyd` session-host wire protocol.

## 11. Verification matrix

| Area                | Existing evidence                                                                                                                                                                                                                                                                                  | Remaining evidence                                                                                                     |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Three-zone compiler | Unit tests for ordering, budgets, pruning, and tail truncation; cross-process compiler step                                                                                                                                                                                                        | Role views, provenance, semantic deltas, full Runner integration                                                       |
| Tool spillover      | Unit spillover/blob recovery; real cross-process oversized action                                                                                                                                                                                                                                  | Durable Action Record density; compiler middle-error extraction                                                        |
| Process output      | Real-host capture, timeout, truncation, cancellation                                                                                                                                                                                                                                               | Retention and raw-output lifecycle policy                                                                              |
| Thinking            | OpenAI/Anthropic stream parsing and bounded Rationale excerpt                                                                                                                                                                                                                                      | Structured Rationale schema and no-replay tests                                                                        |
| Context history     | Commit/branch/merge/snapshot tests                                                                                                                                                                                                                                                                 | Per-session branches and immutable projection refs                                                                     |
| Agent/Panel/Session | Initial headless `panel_id` telemetry                                                                                                                                                                                                                                                              | Lifecycle state machine and attach/detach evidence                                                                     |
| Tasks/Handoff       | DAG, claim, generation, handoff, reviewer tests                                                                                                                                                                                                                                                    | Parent tasks, multi-task identity, durable handoff state                                                               |
| Provider cache      | Offline provider controls, exact prefix/domain isolation, policy negotiation including stdio fail-closed tests; normalized native/alias counters and conflict errors; usage-only stream parsing and status aggregation; helper credential isolation/echo rejection; key-absent live-selector skips | Credentialed provider evidence and actual cache-hit observation; Dashboard presentation; independent review acceptance |

No row in this table authorizes implementation in `bittyd`. Wheel issues #110–#118
own the follow-up work; issue #109 is the parent index.

## 12. References

- [Wheel README](README.md), especially the existing Context, spillover,
  provider, and Git-inspired versioning sections.
- [Context Snapshot Contract](CONTEXT-SNAPSHOT.md).
- [Wheel Security Model](SECURITY-MODEL.md).
- CarryCtx's project-state model: separate Agent, Session, Task, Worktree,
  Checkpoint, Decision, Handoff, and Event records; Team is a durable
  coordination index, not a runtime worker pool.
- Parent issue [wheel#109](https://github.com/bitty-terminal/wheel/issues/109)
  and child issues [#110](https://github.com/bitty-terminal/wheel/issues/110)
  through [#118](https://github.com/bitty-terminal/wheel/issues/118).

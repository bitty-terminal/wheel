# Security Policy

This document describes how security reports for the `wheel` repository are
handled. Normative platform security requirements live in the canonical
`bitty-docs` security corpus and take precedence over anything stated here and
in [`SECURITY-MODEL.md`](SECURITY-MODEL.md).

## Supported Versions

| Version    | Supported                                         |
| ---------- | ------------------------------------------------- |
| Unreleased | No — no version of this project has been released |

There are currently no supported releases. Do not rely on this repository for
production use.

## Reporting a Vulnerability

Report security vulnerabilities privately by opening a
[GitHub Security Advisory](https://github.com/bitty-terminal/wheel/security/advisories/new).

Do not report security vulnerabilities through public GitHub issues, pull
requests, or discussion channels.

When reporting, please include as much of the following as possible:

- A description of the vulnerability and its potential impact.
- Steps to reproduce, or a proof of concept.
- Affected files, Lua modules, manifests, or generated outputs.
- Any known mitigations or workarounds.

## Disclosure Policy

Reports are handled through coordinated disclosure:

1. The report is acknowledged and triaged privately.
2. A fix is developed and validated out of public view.
3. Once releases exist, a release containing the fix is published.
4. A public advisory is published afterward, crediting the reporter unless
   anonymity is requested.

## Response Expectations

The targets below take effect once this repository accepts them:

- Acknowledge a new advisory within 5 business days.
- Provide a status update at least every 14 calendar days while a report is
  open.
- Publish the advisory after a fixed version is available, or after 90 days if
  no fix is feasible, whichever comes first.

## Authority and Scope

Wheel 0.1.0 is an independent out-of-process harness. It does not run inside
the Bitty plugin VM; the harness process holds execution authority under its
own policy. The owner-approved ceiling (2026-10-20, wheel#51) is workspace
read, workspace write, arbitrary argv, shell command strings, network egress,
and secret environment reads. Shell command strings and secret environment
reads are the higher-risk class and carry additional controls and evidence.

[`SECURITY-MODEL.md`](SECURITY-MODEL.md) is the repository's normative model:
authority policy, path sandbox and role gates, command deny-list, audit and
redaction, the executable `.wheel/init.lua` trust gate, the OQ-068 divergence,
trust boundary and residual risks, and the mock/unit plus real host fixture
evidence gates required before any capability widening.

Findings that contradict those boundaries are security-relevant defects.
Examples: an escape from the workspace path sandbox, execution of an untrusted
`.wheel/init.lua` or execution on load, secret material in logs, artifacts,
prompts, or child environments, a shell or network path that bypasses audit or
redaction, an unauthorized privilege transition, a role change that widens
capability without an audited policy generation and checkpoint, a fork that
exceeds its parent's authority, or any authority wider than the approved
ceiling.

Lifecycle authority references must be issued by the Agent's private registry;
caller resolvers, forged tokens, or restored metadata cannot authorize role
transitions or widening. Public Agent handles reject `rawset`, keeping direct
identity and lineage reads consistent with status, authorization, and routing.

### Superseded plugin-sandbox scope (historical)

The following text described the pre-decision plugin position. It is superseded
by the owner decisions of 2026-10-20 (D1/D2/D3/D5/D6), which moved Wheel to an
independent harness and approved the 0.1.0 authority ceiling. It is retained
for history only and must not be used to scope reports against the 0.1.0
harness.

> The plugin requests only `platform.notify`: it holds no filesystem, process,
> network, clipboard, terminal input, or persistent-state authority, and it
> executes no install-time code.
> Findings that contradict those boundaries — including a manifest change that
> would widen the capability set, unbounded input handling, or an escape from
> the declarative UI primitives — are security-relevant defects.

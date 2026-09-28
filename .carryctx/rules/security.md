# Security rules

1. The normative security overview, threat model, and risk register in
   `bitty-docs` override historical sources and non-security suggestions.
2. Treat PTY bytes, protocols, plugins, projects, IPC/MCP/Agent clients,
   packages, dependencies, and reference repositories as untrusted.
3. P0 requires bounded protocol parsing, explicit tool execution sandboxes,
   least-privilege scopes, path traversal prevention, dangerous command guards,
   and supply-chain controls.
4. Plugin and agent environments use restricted standard libraries, deny-by-default
   tool authority gating, and CPU/memory/task/turn budgets.
5. Forbid native in-process plugins, install scripts, allow-all capabilities,
   silent permission elevation, ambient authority, and unbounded input or work.
6. Direnv-style security trust gates fail closed on untrusted or tampered project
   configuration files (`.wheel/init.lua`), falling back to safe defaults.
7. Role authority gates fail closed: `Research` and `Reviewer` roles cannot perform
   mutating actions (`Modify` or `Execute` intents); `Commander` orchestrates.
8. Security-sensitive changes require negative, malformed, limit, timeout, denial,
   rollback, and path traversal test evidence.
9. Keep risks open until both mitigation and independent reviewer evidence are
   complete.

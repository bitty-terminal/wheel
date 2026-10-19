# Changelog

All notable changes to Bitty Wheel (`bitty-terminal.wheel`) are recorded
here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository scaffold generated from
  [bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template):
  static manifest (`bitty-plugin.toml`), Lua entry point (`lua/wheel/init.lua`),
  and the CI quality gate.
- Wheel harness implementation under `lua/wheel/`: kernel dispatch, hierarchical
  configuration, agent runtime, team orchestration, Git-inspired context
  versioning, tool execution engine, model provider adapters, execution runner,
  and UI visualizer, with unit and cross-process test suites.
- Repository governance: `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  CarryCtx baseline (`.carryctx/config.toml`), and the Wheel/Bittie naming
  record (bitty-ai-docs `DEC-0003`).
- Typed command failure boundary (`lua/wheel/errors.lua`): sandbox denials
  surface as the accepted `runtime` / `E_CAPABILITY_DENIED` error table with a
  bounded message naming the missing capability, and unexpected handler
  failures stay distinguishable as a Wheel-local `E_INTERNAL` error.
- Wheel Coding-Agent scope and Non-goals recorded in `README.md` and
  `AGENTS.md` (owner-approved scope, research record 046).

### Changed

- Host filesystem, process, tmp, and time operations now route through a
  single injectable `WheelHost` seam (`lua/wheel/host.lua`) with the previous
  POSIX behavior as the default backend; a future Bitty host ABI adapter swaps
  only the backend. No user-visible behavior change.
- Command handlers now cross the typed failure boundary: `plan`, `trust`, and
  `orchestrate` report missing `env.read`/`fs.read` authority instead of raw
  nil-member failures, and the `trust` command reads project configuration
  through the `WheelHost` seam. The manifest and requested capabilities are
  unchanged.
- Repository repositioned as an independent agent-harness repository: removed
  from the official plugin set (bitty-plugins #98); descriptors, documentation,
  and the GitHub repository description aligned with the independence direction
  (wheel #45). No behavior changes.

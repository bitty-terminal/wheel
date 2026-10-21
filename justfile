# Quality gates for Bitty Wheel (bitty-terminal.wheel).
#
# Dependencies live in package.json and are locked in bun.lock; `just install`
# materializes them. Installed tools are invoked with `bun run <bin>` so every
# gate resolves from node_modules and runs offline once install has completed.
# The manifest and README gates run the authoritative SDK tools
# (bitty-plugin-lint and bitty-plugin-docs-check, commit-pinned in package.json
# + bun.lock), not vendored re-implementations.
# A gate with missing dependencies fails closed (`just deps`) instead of
# fetching. Never use npm, npx, or yarn in this repository.

# Pinned parser version; keep identical to the luaparse devDependency in
# package.json.
luaparse_pin := "0.3.1"

# List available recipes.
default:
    @just --list

# Install pinned dev dependencies from bun.lock. This is the only gate step
# that may use the network; install once, then `just check` is offline.
install:
    bun install --frozen-lockfile

# Fail closed when dependencies are absent, so a gate never silently fetches
# from the network. Run `just install` first.
deps:
    @test -d node_modules || { echo "dependencies are not installed; run 'just install'" >&2; exit 1; }

# Lint all Markdown sources with markdownlint-cli2 (.markdownlint-cli2.jsonc).
lint: deps
    bun run markdownlint-cli2

# Lint specific Markdown files (used by the pre-commit hook).
lint-files *files: deps
    bun run markdownlint-cli2 {{files}}

# Format all files with Prettier.
fmt: deps
    bun run prettier --write . --ignore-unknown

# Format specific files (used by the pre-commit hook).
fmt-files *files: deps
    bun run prettier --write {{files}}

# Check formatting of all files with Prettier.
fmt-check: deps
    bun run prettier --check . --ignore-unknown

# Check formatting of specific files (used by the pre-commit hook).
fmt-check-files *files: deps
    bun run prettier --check {{files}}

# Validate a commit message file with commitlint (conventional commits).
commit-check message=".git/COMMIT_EDITMSG": deps
    bun run commitlint --edit "{{message}}"

# Install Git hooks managed by lefthook (opt-in per contributor checkout).
hooks-install: deps
    bun run lefthook install

# Remove lefthook-managed Git hooks.
hooks-uninstall: deps
    bun run lefthook uninstall

# Validate bitty-plugin.toml with the authoritative SDK linter (R-SDK-2),
# pinned by commit in package.json and bun.lock. The manifest schema is owned
# by bitty-docs, not by this repository.
manifest: deps
    @test -x node_modules/.bin/bitty-plugin-lint || { echo "bitty-plugin-lint is not installed; run 'just install'" >&2; exit 1; }
    bun run bitty-plugin-lint bitty-plugin.toml

# Validate README.md with the authoritative SDK user-documentation checker,
# pinned by commit in package.json and bun.lock. The six required H2 sections
# must lead in order and the Configuration section must match the manifest
# [settings]; this repository declares none.
docs-check: deps
    @test -x node_modules/.bin/bitty-plugin-docs-check || { echo "bitty-plugin-docs-check is not installed; run 'just install'" >&2; exit 1; }
    bun run bitty-plugin-docs-check .

# Parse all Lua sources with the pinned Lua 5.1 grammar parser (luaparse,
# version pinned in package.json + bun.lock).
lua: deps
    bun run luaparse --quiet --file lua/wheel/init.lua
    bun run luaparse --quiet --file lua/wheel/errors.lua
    bun run luaparse --quiet --file lua/wheel/schema.lua
    bun run luaparse --quiet --file lua/wheel/commands.lua
    bun run luaparse --quiet --file lua/wheel/kernel.lua
    bun run luaparse --quiet --file lua/wheel/config.lua
    bun run luaparse --quiet --file lua/wheel/host.lua
    bun run luaparse --quiet --file lua/wheel/agent.lua
    bun run luaparse --quiet --file lua/wheel/team.lua
    bun run luaparse --quiet --file lua/wheel/context.lua
    bun run luaparse --quiet --file lua/wheel/context_snapshot.lua
    bun run luaparse --quiet --file lua/wheel/ui.lua
    bun run luaparse --quiet --file lua/wheel/tool.lua
    bun run luaparse --quiet --file lua/wheel/provider.lua
    bun run luaparse --quiet --file lua/wheel/runner.lua
    bun run luaparse --quiet --file bench/run.lua
    bun run luaparse --quiet --file bench/lib/cli.lua
    bun run luaparse --quiet --file bench/lib/env.lua
    bun run luaparse --quiet --file bench/lib/json.lua
    bun run luaparse --quiet --file bench/lib/smoke.lua
    bun run luaparse --quiet --file bench/lib/stats.lua
    bun run luaparse --quiet --file bench/lib/time.lua
    bun run luaparse --quiet --file bench/scenarios/activation.lua
    bun run luaparse --quiet --file bench/scenarios/context.lua
    bun run luaparse --quiet --file bench/scenarios/orchestration.lua
    bun run luaparse --quiet --file bench/scenarios/process.lua
    bun run luaparse --quiet --file bench/scenarios/runner.lua
    bun run luaparse --quiet --file tests/e2e_cross_process.lua
    bun run luaparse --quiet --file tests/test_bench.lua
    bun run luaparse --quiet --file tests/test_wheel.lua
    bun run luaparse --quiet --file tests/test_context_snapshot.lua
    bun run luaparse --quiet --file tests/test_live_provider.lua
    bun run luaparse --quiet --file tests/real_host_fixture.lua

# Run the test suite with the deterministic interpreter selection: lua5.1
# first, then luajit, then lua. Lua 5.1 is the release gate; the LuaJIT
# fallback disables the JIT for evaluated config chunks so the instruction-limit
# test cannot hang. `just test-gate` verifies the selection branches.
test: deps
    bash scripts/test-gate.sh

# Verify the interpreter-selection branches of `just test` without running the
# suite: lua5.1 wins when present, luajit/lua fall back in order, and absence is
# reported as a skip.
test-gate: deps
    bash scripts/test-gate.sh --self-test

# Unit tests for the benchmark statistics, argument parsing, JSON encoding, and
# fail-closed CLI behavior, plus one short context-scenario run. Uses the same
# interpreter selection as `just test` and stays offline.
test-bench: deps
    @set -e; \
    interpreter="$(bash scripts/test-gate.sh --print-selection)"; \
    if [ "$interpreter" = "none" ]; then \
        echo "No lua interpreter found; skipping benchmark tests" >&2; \
    else \
        "$interpreter" tests/test_bench.lua; \
    fi

# Opt-in real-host activation and command-smoke fixture for the standalone
# Option B harness. Requires lua5.1 and fails closed when it is absent instead
# of skipping. CI installs Lua 5.1 and runs this after `just check`; the fixture
# execution is deliberately not part of the local `check` aggregate, while the
# Lua gate still parses the file.
test-real-host:
    @set -e; \
    if ! command -v lua5.1 >/dev/null 2>&1; then \
        echo "test-real-host requires lua5.1 on PATH" >&2; \
        exit 1; \
    fi; \
    lua5.1 tests/real_host_fixture.lua

# Run the full offline benchmark suite (manual). Mock providers only: no
# network, credentials, or live provider latency. Expect roughly a minute
# because each process call pays the production 250 ms post-exit sweep grace.
# Extra arguments go to bench/run.lua.
bench *args:
    sh bench/run.sh {{args}}

# Emit the full benchmark record as machine-readable JSON on stdout. Redirect
# it under gitignored recording/ when keeping a result.
bench-json *args:
    sh bench/run.sh --format json {{args}}

# Short bounded release-smoke subset with generous regression ceilings. This is
# a regression signal, not a host baseline or a release performance claim.
bench-release-smoke *args:
    sh bench/run.sh --smoke {{args}}

# Build the deterministic standalone harness artifact for the version in the
# root VERSION file: dist/wheel-<version>.tar.gz, its SHA-256 sidecar, and a
# manifest record. The release gate refuses a dirty worktree or unsupported
# version. Extra arguments go to scripts/package.sh (--allow-dirty and
# --version are local test-build options only).
package *args:
    bash scripts/package.sh {{args}}

# Install a locally built artifact under <prefix>/wheel/<version> and switch
# the relative `current` symlink. Verifies the digest, archive members, target
# ownership, and prefix shape before extracting; never uses the network.
install-local prefix *args:
    bash scripts/install-local.sh "{{prefix}}" {{args}}

# Switch <prefix>/wheel/current back to the recorded previous version.
rollback-local prefix:
    bash scripts/install-local.sh --rollback "{{prefix}}"

# Build the 0.1.0 artifact, install it into a temporary prefix, run the
# real-host fixture against the installed tree, upgrade to a locally built
# 0.1.1, roll back, and verify the refusal paths. Offline; no release.
verify-package:
    bash scripts/verify-package.sh

# Shell gates for the packaging, benchmark, and test-gate scripts (not part of
# `check` because the CI image does not guarantee shfmt). The older
# workflow-*.sh scripts are outside this gate; reformatting them is a separate
# change.
shell:
    shellcheck -S warning scripts/package.sh scripts/install-local.sh scripts/verify-package.sh scripts/test-gate.sh bench/run.sh
    shfmt -d scripts/package.sh scripts/install-local.sh scripts/verify-package.sh scripts/test-gate.sh bench/run.sh

# Offline gates for the live provider test: no credential, no network. The
# key-free redirect-policy test runs first, then the provider-selection and
# host-binding tests. Part of `check`, so CI exercises the selector without a
# key.
test-live-offline:
    @command -v python3 >/dev/null 2>&1 || { echo "test-live-offline requires python3" >&2; exit 1; }
    python3 tests/test_live_http_client_redirect.py
    python3 tests/test_live_provider_selection.py

# Opt-in live provider test. Manual only; never part of `just check` or CI.
# WHEEL_LIVE_PROVIDER selects openrouter (default) or commandcode,
# case-insensitively. The key-free offline gates run first; the live portion
# skips with exit 0 after them when the selected provider's key is unset. The
# test-only Python client reads the key from its own environment; the Lua
# harness adapter never receives it.
test-live: test-live-offline
    @set -e; \
    if command -v lua5.1 >/dev/null 2>&1; then \
        lua5.1 tests/test_live_provider.lua; \
    elif command -v luajit >/dev/null 2>&1; then \
        luajit tests/test_live_provider.lua; \
    elif command -v lua >/dev/null 2>&1; then \
        lua tests/test_live_provider.lua; \
    else \
        echo "No lua interpreter found; skipping live test execution" >&2; \
    fi

# Run end-to-end cross-process host integration drill when binary is available.
e2e: deps
    @if command -v lua5.1 >/dev/null 2>&1; then \
        lua5.1 tests/e2e_cross_process.lua; \
    elif command -v luajit >/dev/null 2>&1; then \
        luajit tests/e2e_cross_process.lua; \
    elif command -v lua >/dev/null 2>&1; then \
        lua tests/e2e_cross_process.lua; \
    else \
        echo "No lua interpreter found; skipping runtime e2e execution" >&2; \
    fi

# Fail-closed control for the `lua` gate: the same pinned parser must reject an
# invalid snippet. `luaparse` exits 0 on empty input, so without this control a
# recipe that lost its `--file` argument would silently pass rather than parse
# the generated entry point.
lua-control: deps
    @! bun run luaparse --quiet --code 'local ='

# Aggregate gate run locally and in CI (after `just install`).
check: lint fmt-check manifest docs-check lua test-gate test-live-offline test test-bench lua-control

actionlint:
    actionlint .github/workflows/*.yml

# Publish a redacted CarryCtx snapshot inside this repo (commander merge
# closeout only; never a git hook). `carryctx export --publication` redacts the
# bundle, stamps manifest.redacted, and commits one snapshot to the fixed ref
# `refs/heads/carryctx-snapshots`.
workflow-publish *args:
    bash scripts/workflow-publish.sh {{args}}

workflow-publish-dry *args:
    bash scripts/workflow-publish.sh --dry-run {{args}}

# Restore the local CarryCtx DB from the in-repo snapshot branch
# `refs/heads/carryctx-snapshots` (fresh-clone recipe). Refuses to replace a
# non-empty local DB without --force, e.g. `just workflow-import --force`.
workflow-import *args:
    bash scripts/workflow-import.sh {{args}}

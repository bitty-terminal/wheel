# Quality gates for Bitty Wheel (bitty-terminal.wheel).
#
# Dependencies live in package.json and are locked in bun.lock; `just install`
# materializes them. Installed tools are invoked with `bun run <bin>` so every
# gate resolves from node_modules and runs offline once install has completed.
# The manifest gate runs the authoritative SDK linter (bitty-plugin-lint,
# commit-pinned in package.json + bun.lock), not a vendored re-implementation.
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

# Parse the Lua entry point with the pinned Lua 5.1 grammar parser (luaparse,
# version pinned in package.json + bun.lock).
lua: deps
    bun run luaparse --quiet --file lua/wheel/init.lua

# Fail-closed control for the `lua` gate: the same pinned parser must reject an
# invalid snippet. `luaparse` exits 0 on empty input, so without this control a
# recipe that lost its `--file` argument would silently pass rather than parse
# the generated entry point.
lua-control: deps
    @! bun run luaparse --quiet --code 'local ='

# Aggregate gate run locally and in CI (after `just install`).
check: lint fmt-check manifest lua lua-control

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

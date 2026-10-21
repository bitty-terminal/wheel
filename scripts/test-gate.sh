#!/usr/bin/env bash
# Select the Lua interpreter for the Wheel unit suite and run it.
#
# Lua 5.1 is the release gate and always wins when present. LuaJIT is a
# development fallback: the evaluated project-config chunk disables the JIT so
# the instruction-limit hook remains enforceable (a JIT-compiled loop would
# otherwise ignore the count hook and hang the gate). Plain `lua` is the last
# resort, and a missing interpreter skips execution with a clear message.
#
# `--print-selection` reports the selected interpreter without running the
# suite, and `--self-test` exercises the selection branches with fake
# interpreters on a controlled PATH (used by `just test-gate`).
set -euo pipefail

readonly PRIMARY_INTERPRETER="lua5.1"
readonly FALLBACK_INTERPRETERS=(luajit lua)
readonly SCRATCH_BASE="${WHEEL_TEST_GATE_SCRATCH:-${TMPDIR:-/tmp}/bitty}"

self_test_scratch=""

usage() {
  cat <<'EOF'
Usage: scripts/test-gate.sh [--print-selection | --self-test]

Run the Wheel unit suite with lua5.1, luajit, or lua (in that order).

Options:
  --print-selection  Print the selected interpreter (or "none") and exit.
  --self-test        Verify the selection branches with fake interpreters.
  -h, --help         Show this help.
EOF
}

# Print the first available interpreter, or "none". Only shell builtins are
# used so the self-test can run with a PATH that contains fixture binaries only.
print_selection() {
  local candidate
  for candidate in "$PRIMARY_INTERPRETER" "${FALLBACK_INTERPRETERS[@]}"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf 'none\n'
}

cleanup_self_test() {
  if [ -n "$self_test_scratch" ] && [ -d "$self_test_scratch" ]; then
    rm -rf -- "$self_test_scratch"
  fi
}

self_test() {
  mkdir -p -- "$SCRATCH_BASE"
  self_test_scratch="$(mktemp -d -- "$SCRATCH_BASE/wheel-test-gate-XXXXXX")"
  trap cleanup_self_test EXIT

  # Each fixture directory stands in for a PATH whose available interpreters
  # are exactly the names it contains.
  make_fake() {
    local dir=$1
    shift
    local name
    mkdir -p -- "$self_test_scratch/$dir"
    for name in "$@"; do
      printf '#!/bin/sh\nexit 0\n' >"$self_test_scratch/$dir/$name"
      chmod 0755 -- "$self_test_scratch/$dir/$name"
    done
  }

  make_fake all "$PRIMARY_INTERPRETER" "${FALLBACK_INTERPRETERS[@]}"
  make_fake luajit-only luajit lua
  make_fake lua-only lua
  make_fake none

  assert_selection() {
    local dir=$1 want=$2 got
    got="$(PATH="$self_test_scratch/$dir" "$BASH" "$0" --print-selection)"
    if [ "$got" != "$want" ]; then
      printf '[FAIL] test-gate: PATH '%s' selected '%s', expected '%s'\n' \
        "$dir" "$got" "$want" >&2
      return 1
    fi
    printf '[PASS] test-gate: PATH %s selects %s\n' "$dir" "$got"
  }

  assert_selection all "$PRIMARY_INTERPRETER"
  assert_selection luajit-only luajit
  assert_selection lua-only lua
  assert_selection none none
}

case "${1:-run}" in
--print-selection)
  print_selection
  exit 0
  ;;
--self-test)
  self_test
  exit 0
  ;;
-h | --help)
  usage
  exit 0
  ;;
run) ;;
*)
  usage >&2
  exit 2
  ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT

run_scratch=""

cleanup_run_scratch() {
  if [ -n "$run_scratch" ] && [ -d "$run_scratch" ]; then
    rm -rf -- "$run_scratch"
  fi
}

trap cleanup_run_scratch EXIT

# The suite creates its own unique child under WHEEL_TEST_TMP; this outer
# directory is only the fallback base that guarantees cleanup when the suite
# exits before its own cleanup hook runs.
if [ -z "${WHEEL_TEST_TMP:-}" ]; then
  mkdir -p -- "$SCRATCH_BASE"
  run_scratch="$(mktemp -d -- "$SCRATCH_BASE/wheel-test-run-XXXXXX")"
  export WHEEL_TEST_TMP="$run_scratch"
fi

interpreter="$(print_selection)"
case "$interpreter" in
none)
  printf 'No lua interpreter found; skipping runtime test execution\n' >&2
  exit 0
  ;;
"$PRIMARY_INTERPRETER")
  printf 'test: using %s (primary gate)\n' "$interpreter"
  ;;
luajit)
  printf 'test: lua5.1 not found; using luajit fallback (JIT is disabled for evaluated config chunks; not the release gate)\n'
  ;;
lua)
  printf 'test: lua5.1 and luajit not found; using lua fallback\n'
  ;;
esac

status=0
"$interpreter" "$REPO_ROOT/tests/test_wheel.lua" || status=$?
exit "$status"

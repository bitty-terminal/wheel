#!/usr/bin/env bash
# Prove that an unsafe WHEEL_TEST_TMP base is rejected before the suite
# creates or removes anything. The base carries whitespace and shell syntax; a
# fixed interpolation regression would delete the sentinel file.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
SCRATCH_BASE="${WHEEL_TEST_GUARD_SCRATCH:-${TMPDIR:-/tmp}/bitty}"

work=""

cleanup() {
  if [ -n "$work" ] && [ -d "$work" ]; then
    rm -rf -- "$work"
  fi
}

trap cleanup EXIT

interpreter="$(bash "$SCRIPT_DIR/test-gate.sh" --print-selection)"
if [ "$interpreter" = "none" ]; then
  printf 'No lua interpreter found; skipping the base guard check\n' >&2
  exit 0
fi

mkdir -p -- "$SCRATCH_BASE"
work="$(mktemp -d -- "$SCRATCH_BASE/wheel-test-guard-XXXXXX")"
sentinel="$work/sentinel"
log="$work/guard.log"
: >"$sentinel"

unsafe_base="$work/unsafe base; rm -f $sentinel"

status=0
(
  cd -- "$REPO_ROOT"
  WHEEL_TEST_TMP="$unsafe_base" timeout 120 "$interpreter" tests/test_wheel.lua
) >"$log" 2>&1 || status=$?

if [ "$status" -eq 0 ]; then
  printf '[FAIL] an unsafe WHEEL_TEST_TMP base was accepted\n' >&2
  tail -20 "$log" >&2
  exit 1
fi

if [ ! -f "$sentinel" ]; then
  printf '[FAIL] the unsafe base deleted a file outside the run root\n' >&2
  exit 1
fi

if ! grep -q 'WHEEL_TEST_TMP' "$log"; then
  printf '[FAIL] the rejection did not explain the unsafe WHEEL_TEST_TMP base\n' >&2
  tail -20 "$log" >&2
  exit 1
fi

leftover="$(find "$work" -mindepth 1 -maxdepth 1 ! -name sentinel ! -name guard.log -print -quit)"
if [ -n "$leftover" ]; then
  printf '[FAIL] the unsafe base created filesystem entries: %s\n' "$leftover" >&2
  exit 1
fi

printf '[PASS] unsafe WHEEL_TEST_TMP base rejected without creating or deleting files\n'

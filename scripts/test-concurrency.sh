#!/usr/bin/env bash
# Prove that two concurrent Wheel suite runs never share or delete each
# other's scratch roots.
#
# Both runs use the same WHEEL_TEST_TMP base and the same checkout, which is a
# stricter setup than two worktrees: each process must create and remove its own
# unique child, so a fixed-path regression fails immediately. This doubles the
# suite runtime, so it is a documented local check rather than part of
# `just check`.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
SCRATCH_BASE="${WHEEL_TEST_CONCURRENCY_SCRATCH:-${TMPDIR:-/tmp}/bitty}"

work=""

cleanup() {
  if [ -n "$work" ] && [ -d "$work" ]; then
    rm -rf -- "$work"
  fi
}

trap cleanup EXIT

interpreter="$(bash "$SCRIPT_DIR/test-gate.sh" --print-selection)"
if [ "$interpreter" = "none" ]; then
  printf 'No lua interpreter found; skipping the concurrency check\n' >&2
  exit 0
fi

mkdir -p -- "$SCRATCH_BASE"
work="$(mktemp -d -- "$SCRATCH_BASE/wheel-concurrency-XXXXXX")"
shared_base="$work/shared"
mkdir -p -- "$shared_base"

(
  cd -- "$REPO_ROOT"
  WHEEL_TEST_TMP="$shared_base" "$interpreter" tests/test_wheel.lua
) >"$work/a.log" 2>&1 &
pid_a=$!

(
  cd -- "$REPO_ROOT"
  WHEEL_TEST_TMP="$shared_base" "$interpreter" tests/test_wheel.lua
) >"$work/b.log" 2>&1 &
pid_b=$!

status=0
wait "$pid_a" || status=1
wait "$pid_b" || status=1

if [ "$status" -ne 0 ]; then
  printf '[FAIL] concurrent Wheel suite runs failed\n' >&2
  printf '%s\n' '--- run A ---' >&2
  tail -20 "$work/a.log" >&2
  printf '%s\n' '--- run B ---' >&2
  tail -20 "$work/b.log" >&2
  exit 1
fi

if [ -n "$(find "$shared_base" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  printf '[FAIL] concurrent runs left scratch entries behind\n' >&2
  find "$shared_base" -mindepth 1 -maxdepth 1 >&2
  exit 1
fi

printf '[PASS] two concurrent Wheel suites passed with isolated scratch roots\n'

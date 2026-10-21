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
readonly SUITE_TIMEOUT_SECONDS=1500

work=""
suite_pids=()
suites_finished=0

stop_suites() {
  local pid attempt alive
  if [ "${#suite_pids[@]}" -gt 0 ]; then
    for pid in "${suite_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        # Each suite leads its own private session, so the negative PID targets
        # only that suite and its descendants.
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    for pid in "${suite_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    for ((attempt = 0; attempt < 50; attempt++)); do
      alive=0
      for pid in "${suite_pids[@]}"; do
        if kill -0 -- "-$pid" 2>/dev/null; then
          alive=1
        fi
      done
      if [ "$alive" -eq 0 ]; then
        break
      fi
      sleep 0.1
    done
    for pid in "${suite_pids[@]}"; do
      if kill -0 -- "-$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null || true
      fi
    done
  fi
}

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [ "$suites_finished" -eq 0 ]; then
    stop_suites
    if [ -n "$work" ] && [ -d "$work" ]; then
      printf '[INFO] interrupted; suite logs preserved in %s\n' "$work" >&2
    fi
  elif [ -n "$work" ] && [ -d "$work" ]; then
    rm -rf -- "$work"
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

interpreter="$(bash "$SCRIPT_DIR/test-gate.sh" --print-selection)"
if [ "$interpreter" = "none" ]; then
  printf 'No lua interpreter found; skipping the concurrency check\n' >&2
  exit 0
fi

command -v setsid >/dev/null || {
  printf 'test-concurrency requires setsid to manage suite process groups\n' >&2
  exit 1
}

mkdir -p -- "$SCRATCH_BASE"
work="$(mktemp -d -- "$SCRATCH_BASE/wheel-concurrency-XXXXXX")"
shared_base="$work/shared"
mkdir -p -- "$shared_base"

(
  cd -- "$REPO_ROOT"
  # `exec` makes the recorded PID the `setsid`/`timeout` leader itself, so
  # cleanup can signal the whole private suite session.
  exec setsid env WHEEL_TEST_TMP="$shared_base" timeout "$SUITE_TIMEOUT_SECONDS" \
    "$interpreter" tests/test_wheel.lua
) >"$work/a.log" 2>&1 &
pid_a=$!
suite_pids+=("$pid_a")

(
  cd -- "$REPO_ROOT"
  exec setsid env WHEEL_TEST_TMP="$shared_base" timeout "$SUITE_TIMEOUT_SECONDS" \
    "$interpreter" tests/test_wheel.lua
) >"$work/b.log" 2>&1 &
pid_b=$!
suite_pids+=("$pid_b")

# Both suites must be running under distinct per-run roots while they overlap;
# one shared root would produce a single directory here.
roots_distinct=0
for ((attempt = 0; attempt < 100; attempt++)); do
  root_count="$(find "$shared_base" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d ' ')"
  if [ "$root_count" -eq 2 ]; then
    roots_distinct=1
    break
  fi
  if [ "$root_count" -gt 2 ]; then
    break
  fi
  sleep 0.1
done
if [ "$roots_distinct" -ne 1 ]; then
  printf '[FAIL] expected two distinct per-run roots under the shared base (saw %s)\n' "$root_count" >&2
  exit 1
fi

status=0
wait "$pid_a" || status=1
wait "$pid_b" || status=1
suites_finished=1

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

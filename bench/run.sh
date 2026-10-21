#!/bin/sh
# bench/run.sh - POSIX shell entry point for the Wheel benchmark suite.
#
# Selects the release-gate interpreter (lua5.1), then luajit, then lua, and
# pins the process to one CPU with taskset when available. WHEEL_BENCH_LUA
# overrides the interpreter; WHEEL_BENCH_NO_PIN=1 disables pinning. A missing
# interpreter fails closed; a missing taskset only warns and runs unpinned.
#
# All arguments are passed through to bench/run.lua (see --help there).

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

if [ -n "${WHEEL_BENCH_LUA:-}" ]; then
  interpreter=$WHEEL_BENCH_LUA
  if ! command -v "$interpreter" >/dev/null 2>&1; then
    echo "bench: WHEEL_BENCH_LUA='$interpreter' is not executable on PATH" >&2
    exit 1
  fi
else
  interpreter=""
  for candidate in lua5.1 luajit lua; do
    if command -v "$candidate" >/dev/null 2>&1; then
      interpreter=$candidate
      break
    fi
  done
  if [ -z "$interpreter" ]; then
    echo "bench: no Lua interpreter found; install lua5.1 (the release gate)" >&2
    exit 1
  fi
fi

if [ "$interpreter" != "lua5.1" ]; then
  echo "bench: warning: '$interpreter' is not the Lua 5.1 release baseline; treat results as a sensitivity check" >&2
fi

if [ -z "${WHEEL_BENCH_NO_PIN:-}" ] && command -v taskset >/dev/null 2>&1; then
  # Derive the first allowed CPU from the current affinity mask instead of
  # assuming a CPU count or a machine layout.
  affinity=$(taskset -pc "$$" 2>/dev/null | sed -n 's/.*: //p' || true)
  first_cpu=${affinity%%,*}
  first_cpu=${first_cpu%%-*}
  case "$first_cpu" in
  '' | *[!0-9]*)
    echo "bench: warning: cannot derive a CPU from the affinity mask; running unpinned" >&2
    ;;
  *)
    export WHEEL_BENCH_PINNED_CPU=$first_cpu
    exec taskset -c "$first_cpu" "$interpreter" "$SCRIPT_DIR/run.lua" "$@"
    ;;
  esac
fi

exec "$interpreter" "$SCRIPT_DIR/run.lua" "$@"

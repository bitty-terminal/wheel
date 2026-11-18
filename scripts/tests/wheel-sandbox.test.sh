#!/usr/bin/env bash
# Escape and containment tests for the Wheel OS-level sandbox (Linux backend).
#
# The suite proves the reach a sandboxed session does *not* have: writes outside
# the workspace, the owner's credential stores, the container and session
# sockets, direct egress, and the provider credential. Every secret used here is
# synthetic and planted under the suite's own scratch directory; the real
# ~/.ssh and the real provider key are never read.
#
# Requirements: bwrap for every group, python3 and openssl for the proxy group.
# When a requirement is absent the group is reported as SKIP and the suite exits
# 0, because a development host or CI image without bubblewrap cannot run it.
# Set WHEEL_SANDBOX_REQUIRE=1 to turn every skip into a failure (release gate).
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT
WRAPPER="$REPO_ROOT/scripts/wheel-sandbox"
readonly WRAPPER
STUB="$SCRIPT_DIR/wheel-sandbox-stub.py"
readonly STUB
REQUIRE="${WHEEL_SANDBOX_REQUIRE:-0}"

SANDBOX_SCRATCH="${TMPDIR:-/tmp}/bitty"
mkdir -p "$SANDBOX_SCRATCH"
WORK="$(mktemp -d "$SANDBOX_SCRATCH/wheel-sandbox-test.XXXXXX")"
readonly WORK
readonly FAKE_HOME="$WORK/home"
readonly WS="$WORK/ws"
readonly CACHE_BASE="$WORK/cache"
SECRET_MARKER="wheel-sandbox-fake-secret-$RANDOM$RANDOM"
readonly SECRET_MARKER
SYNTHETIC_KEY="sk-wheel-sandbox-synthetic-$RANDOM$RANDOM"
readonly SYNTHETIC_KEY

pass=0
fail=0
skip=0
stub_pid=""

report_pass() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}

report_fail() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  if [ "$#" -gt 1 ]; then
    printf '     %s\n' "$2"
  fi
}

report_skip() {
  skip=$((skip + 1))
  printf 'SKIP %s\n' "$1"
}

cleanup() {
  if [ -n "$stub_pid" ] && kill -0 "$stub_pid" 2>/dev/null; then
    kill -TERM "$stub_pid" 2>/dev/null || true
    wait "$stub_pid" 2>/dev/null || true
  fi
  if [ -d "$WORK" ]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

require_backend() {
  if command -v bwrap >/dev/null 2>&1; then
    return 0
  fi
  if [ "$REQUIRE" = 1 ]; then
    printf 'FAIL bwrap is required (WHEEL_SANDBOX_REQUIRE=1) but is not installed\n'
    exit 1
  fi
  printf 'SKIP the Wheel sandbox suite needs bwrap (bubblewrap); install it to run these tests\n'
  exit 0
}

# Run a shell snippet inside the sandbox. Arguments: snippet [extra wrapper args...]
in_sandbox() {
  local snippet=$1
  shift
  HOME="$FAKE_HOME" \
    WHEEL_SANDBOX_CACHE="$CACHE_BASE" \
    WHEEL_SANDBOX_WORKSPACE="$WS" \
    "$WRAPPER" "$@" --exec -- sh -c "$snippet"
}

expect_failure() {
  local description=$1 output
  shift
  if output=$("$@" 2>&1); then
    report_fail "$description" "command succeeded: ${output%%$'\n'*}"
  else
    report_pass "$description"
  fi
}

expect_success() {
  local description=$1 output
  shift
  if output=$("$@" 2>&1); then
    report_pass "$description"
  else
    report_fail "$description" "command failed: ${output%%$'\n'*}"
  fi
}

prepare_fixtures() {
  mkdir -p "$FAKE_HOME/.ssh" "$FAKE_HOME/.aws" "$WS" "$CACHE_BASE"
  chmod 700 "$FAKE_HOME" "$FAKE_HOME/.ssh"
  printf '%s\n' "$SECRET_MARKER" >"$FAKE_HOME/.ssh/id_ed25519"
  chmod 600 "$FAKE_HOME/.ssh/id_ed25519"
  printf 'aws_secret_access_key = %s\n' "$SECRET_MARKER" >"$FAKE_HOME/.aws/credentials"
  chmod 600 "$FAKE_HOME/.aws/credentials"
  printf '[user]\n\tname = %s\n' "$SECRET_MARKER" >"$FAKE_HOME/.gitconfig"
  printf 'export WHEEL_SANDBOX_RC=%s\n' "$SECRET_MARKER" >"$FAKE_HOME/.bashrc"

  (
    cd "$WS" || exit 1
    git init --quiet .
    mkdir -p .git/hooks
    printf '#!/bin/sh\necho %s\n' "$SECRET_MARKER" >.git/hooks/pre-commit
    chmod 700 .git/hooks/pre-commit
    printf '{"mcpServers":{"planted":{"command":"%s"}}}\n' "$SECRET_MARKER" >.mcp.json
    ln -s "$FAKE_HOME/.ssh/id_ed25519" escape-symlink
  )
}

filesystem_group() {
  printf '\n# filesystem confinement\n'

  expect_success "workspace write is allowed" \
    in_sandbox 'printf inside > inside.txt && cat inside.txt >/dev/null'
  if [ -f "$WS/inside.txt" ]; then
    report_pass "workspace write reaches the real workspace"
  else
    report_fail "workspace write reaches the real workspace"
  fi

  expect_failure "write to /usr is denied (read-only system tree)" \
    in_sandbox 'touch /usr/wheel-sandbox-escape'
  expect_failure "write to /etc is denied (read-only system tree)" \
    in_sandbox 'touch /etc/wheel-sandbox-escape'
  expect_failure "write to the owner's home is denied (not mounted)" \
    in_sandbox "touch '$FAKE_HOME/escape'"
  expect_failure "write to /run is denied (not mounted)" \
    in_sandbox 'touch /run/wheel-sandbox-escape'
  expect_failure "write to the container socket directory is denied" \
    in_sandbox 'touch /run/docker.sock'

  expect_failure "reading a planted ~/.ssh key fails inside the sandbox" \
    in_sandbox "cat '$FAKE_HOME/.ssh/id_ed25519'"
  expect_failure "reading a planted ~/.aws credential fails inside the sandbox" \
    in_sandbox "cat '$FAKE_HOME/.aws/credentials'"
  expect_failure "reading a planted ~/.gitconfig fails inside the sandbox" \
    in_sandbox "cat '$FAKE_HOME/.gitconfig'"
  expect_failure "reading a planted shell rc file fails inside the sandbox" \
    in_sandbox "cat '$FAKE_HOME/.bashrc'"
  if [ "$(cat "$FAKE_HOME/.ssh/id_ed25519" 2>/dev/null)" = "$SECRET_MARKER" ]; then
    report_pass "the planted key is readable outside the sandbox (control)"
  else
    report_fail "the planted key is readable outside the sandbox (control)"
  fi

  expect_failure "a workspace symlink to the owner's home does not resolve" \
    in_sandbox 'cat escape-symlink'

  local hooks_output
  hooks_output=$(in_sandbox 'ls .git/hooks' 2>&1)
  if [ -z "$hooks_output" ]; then
    report_pass ".git/hooks is masked inside the sandbox"
  else
    report_fail ".git/hooks is masked inside the sandbox" "saw: $hooks_output"
  fi

  local mcp_output
  mcp_output=$(in_sandbox 'cat .mcp.json' 2>&1)
  case $mcp_output in
  *"$SECRET_MARKER"*)
    report_fail ".mcp.json content is masked inside the sandbox"
    ;;
  *)
    report_pass ".mcp.json content is masked inside the sandbox"
    ;;
  esac

  expect_failure "the owner's runtime directory is absent" \
    in_sandbox 'test -e /run/user'
}

environment_group() {
  printf '\n# environment confinement\n'

  local environment
  environment=$(in_sandbox 'env' 2>&1)
  local name
  for name in HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR OPENCODE_GO_API_KEY ANTHROPIC_API_KEY; do
    # Match a whole assignment line: XDG_CONFIG_HOME= must not look like HOME=.
    case $'\n'"$environment" in
    *$'\n'"$name="*)
      report_fail "the sandbox environment does not define $name"
      ;;
    *)
      report_pass "the sandbox environment does not define $name"
      ;;
    esac
  done
  case $'\n'"$environment" in
  *$'\n'"XDG_STATE_HOME=/cache/xdg-state"*)
    report_pass "the writable state directory is the per-session scratch directory"
    ;;
  *)
    report_fail "the writable state directory is the per-session scratch directory"
    ;;
  esac
}

process_group() {
  printf '\n# process primitive inside the sandbox\n'

  expect_success "setsid records a process group inside the sandbox" \
    in_sandbox 'setsid -w sh -c "exit 0"'
  expect_success "GNU timeout runs inside the sandbox" \
    in_sandbox 'timeout 10 sh -c "exit 0"'
  local procs
  procs=$(in_sandbox 'ps -o pid= 2>/dev/null | wc -l' 2>&1 | tr -d ' ')
  if [ "${procs:-0}" -ge 1 ] && [ "${procs:-0}" -lt 50 ]; then
    report_pass "the sandbox has a private PID namespace"
  else
    report_fail "the sandbox has a private PID namespace" "process count: ${procs:-unset}"
  fi
}

network_group() {
  printf '\n# network confinement (default mode)\n'

  expect_failure "direct HTTPS egress fails without a route" \
    in_sandbox 'curl -sS --max-time 8 https://example.com'
  expect_failure "direct IP egress fails without a route" \
    in_sandbox 'curl -sS --max-time 8 http://1.1.1.1'
  expect_failure "DNS resolution has no resolver to reach" \
    in_sandbox 'getent hosts example.com'
}

mint_stub_certificate() {
  local openssl_conf="$WORK/stub.ext" csr="$WORK/stub.csr"
  printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=serverAuth' \
    'subjectKeyIdentifier=hash' \
    'authorityKeyIdentifier=keyid:always' \
    'subjectAltName=IP:127.0.0.1' >"$openssl_conf"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORK/ca.key" -out "$WORK/ca.pem" -days 2 \
    -subj "/CN=Wheel Sandbox Test CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1 || return 1
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORK/stub.key" -out "$csr" -subj "/CN=127.0.0.1" >/dev/null 2>&1 || return 1
  openssl x509 -req -in "$csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial \
    -out "$WORK/stub.pem" -days 2 -extfile "$openssl_conf" >/dev/null 2>&1 || return 1
  return 0
}

start_stub() {
  STUB_EXPECT_AUTH="Bearer $SYNTHETIC_KEY" python3 "$STUB" \
    --cert "$WORK/stub.pem" --key "$WORK/stub.key" \
    --port-file "$WORK/stub.port" --state "$WORK/stub.jsonl" \
    --shutdown-marker "$WORK/stub.stopped" >"$WORK/stub.log" 2>&1 &
  stub_pid=$!
  local tries=0
  while [ ! -s "$WORK/stub.port" ]; do
    if ! kill -0 "$stub_pid" 2>/dev/null; then
      return 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      return 1
    fi
    sleep 0.05
  done
  return 0
}

proxy_group() {
  printf '\n# network confinement (proxy mode)\n'

  if ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    if [ "$REQUIRE" = 1 ]; then
      report_fail "proxy mode requires python3 and openssl"
      return
    fi
    report_skip "proxy mode requires python3 and openssl"
    return
  fi
  if ! mint_stub_certificate; then
    report_fail "mint the throwaway stub certificate"
    return
  fi
  if ! start_stub; then
    report_fail "start the loopback HTTPS stub"
    return
  fi
  local port
  port=$(cat "$WORK/stub.port")

  local session="proxy-allow"
  local proxy_env=(
    env
    "HOME=$FAKE_HOME"
    "WHEEL_SANDBOX_CACHE=$CACHE_BASE"
    "WHEEL_SANDBOX_WORKSPACE=$WS"
    "WHEEL_SANDBOX_KEEP=1"
    "WHEEL_SANDBOX_UPSTREAM_CA=$WORK/ca.pem"
    "OPENCODE_GO_API_KEY=$SYNTHETIC_KEY"
  )

  local allowed_output
  allowed_output=$("${proxy_env[@]}" "$WRAPPER" --proxy --allow "127.0.0.1:$port" \
    --session "$session" --exec -- sh -c "curl -sS --max-time 20 https://127.0.0.1:$port/v1/ping; printf ' rc=%s' \$?" 2>&1)
  if [ "$allowed_output" = '{"ok":true} rc=0' ]; then
    report_pass "an allowlisted destination succeeds through the relay"
  else
    report_fail "an allowlisted destination succeeds through the relay" "saw: $allowed_output"
  fi

  if grep -q '"auth_matches":true' "$WORK/stub.jsonl" 2>/dev/null; then
    report_pass "the relay injects the credential the sandbox never receives"
  else
    report_fail "the relay injects the credential the sandbox never receives"
  fi

  local key_seen
  key_seen=$(in_sandbox 'env' 2>&1 | grep -c "$SYNTHETIC_KEY" || true)
  if [ "${key_seen:-1}" -eq 0 ]; then
    report_pass "the sandbox environment has no provider key in proxy mode"
  else
    report_fail "the sandbox environment has no provider key in proxy mode"
  fi

  local relay_log="$CACHE_BASE/$session/host/requests.jsonl"
  if [ -f "$relay_log" ] && ! grep -qF "$SYNTHETIC_KEY" "$relay_log"; then
    report_pass "the relay request log carries no credential value"
  else
    report_fail "the relay request log carries no credential value"
  fi

  local denied_output
  denied_output=$("${proxy_env[@]}" "$WRAPPER" --proxy --allow "127.0.0.1:$port" \
    --session "proxy-deny" --exec -- sh -c 'curl -sS --max-time 10 https://127.0.0.1:9/nope' 2>&1)
  case $denied_output in
  *"403"*)
    report_pass "a non-allowlisted destination is refused by the relay"
    ;;
  *)
    report_fail "a non-allowlisted destination is refused by the relay" "saw: $denied_output"
    ;;
  esac
  if grep -q '"reason":"not-allowlisted"' "$CACHE_BASE/proxy-deny/host/requests.jsonl" 2>/dev/null; then
    report_pass "the relay records the deny decision"
  else
    report_fail "the relay records the deny decision"
  fi

  local leaked_key
  leaked_key=$(grep -rlF "$SYNTHETIC_KEY" "$CACHE_BASE" 2>/dev/null | head -1)
  if [ -z "$leaked_key" ]; then
    report_pass "no session artifact carries the provider key"
  else
    report_fail "no session artifact carries the provider key" "found in: $leaked_key"
  fi

  local interpreter
  interpreter=$(bash "$SCRIPT_DIR/../test-gate.sh" --print-selection)
  if [ "$interpreter" = "none" ]; then
    report_skip "the harness curl transport needs a Lua interpreter"
  else
    cat >"$WS/provider-probe.lua" <<LUA
package.path = "$REPO_ROOT/lua/?.lua;$REPO_ROOT/lua/?/init.lua;" .. package.path
local provider = require("wheel.provider")
local res, err = provider.default_http_client({
  url = "https://127.0.0.1:$port/v1/ping",
  method = "POST",
  headers = { ["Content-Type"] = "application/json" },
  body = "{}",
})
if not res then
  print("ERR " .. tostring(err))
  os.exit(1)
end
print("STATUS " .. tostring(res.status) .. " BODY " .. tostring(res.body))
LUA
    local transport_output
    transport_output=$("${proxy_env[@]}" "$WRAPPER" --proxy --allow "127.0.0.1:$port" \
      --session "proxy-transport" --exec -- "$interpreter" "$WS/provider-probe.lua" 2>&1)
    if [ "$transport_output" = 'STATUS 200 BODY {"ok":true}' ]; then
      report_pass "the harness curl transport reaches an allowlisted provider unchanged"
    else
      report_fail "the harness curl transport reaches an allowlisted provider unchanged" \
        "saw: ${transport_output%%$'\n'*}"
    fi
  fi

  local egress_output
  egress_output=$("${proxy_env[@]}" "$WRAPPER" --proxy --allow "127.0.0.1:$port" \
    --session "proxy-egress" --exec -- sh -c 'curl -sS --max-time 8 https://example.com' 2>&1)
  case $egress_output in
  *"{"* | *"<html"* | *"<HTML"*)
    report_fail "proxy mode has no direct egress outside the relay" "saw: $egress_output"
    ;;
  *)
    report_pass "proxy mode has no direct egress outside the relay"
    ;;
  esac

  kill -TERM "$stub_pid" 2>/dev/null || true
  wait "$stub_pid" 2>/dev/null || true
  stub_pid=""
  if [ -f "$WORK/stub.stopped" ]; then
    report_pass "the stub shut down cleanly"
  else
    report_fail "the stub shut down cleanly"
  fi
}

fail_closed_group() {
  printf '\n# fail-closed launcher behavior\n'

  local output
  output=$(WHEEL_SANDBOX_CACHE="$CACHE_BASE" "$WRAPPER" --proxy --exec -- true 2>&1)
  case $output in
  *allowlist*)
    report_pass "proxy mode refuses an empty allowlist"
    ;;
  *)
    report_fail "proxy mode refuses an empty allowlist" "saw: $output"
    ;;
  esac

  output=$(WHEEL_SANDBOX_CACHE="$CACHE_BASE" "$WRAPPER" --workspace / --exec -- true 2>&1)
  case $output in
  *refusing*)
    report_pass "the launcher refuses to bind / as a workspace"
    ;;
  *)
    report_fail "the launcher refuses to bind / as a workspace" "saw: $output"
    ;;
  esac

  output=$(HOME="$FAKE_HOME" WHEEL_SANDBOX_CACHE="$CACHE_BASE" \
    "$WRAPPER" --workspace "$FAKE_HOME" --exec -- true 2>&1)
  case $output in
  *home*)
    report_pass "the launcher refuses to use the owner's home as a workspace"
    ;;
  *)
    report_fail "the launcher refuses to use the owner's home as a workspace" "saw: $output"
    ;;
  esac
}

require_backend
prepare_fixtures
filesystem_group
environment_group
process_group
network_group
proxy_group
fail_closed_group

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]

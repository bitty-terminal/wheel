#!/usr/bin/env bash
# Verify the Wheel artifact install, upgrade, and rollback path.
#
# The check builds the 0.1.0 artifact, proves it is byte-for-byte
# deterministic, installs it into a temporary prefix, runs the CTX-0017
# real-host fixture against the installed tree, upgrades to a locally built
# 0.1.1, runs the fixture again, rolls back, and runs the fixture once more.
# It also proves the refusal paths: root, trailing slash, `..`, symlinked
# prefix, non-owned install root, digest mismatch, duplicate version, and a
# symlinked archive member.
#
# Nothing is published. The 0.1.1 build is a local test artifact produced with
# --allow-dirty; the 0.1.0 build uses the release gate.
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly PACKAGE_NAME="wheel"
readonly TEST_VERSION="0.1.1"
readonly TMP_BASE="${WHEEL_VERIFY_SCRATCH:-${TMPDIR:-/tmp}/bitty}"

work=""
cleanup() {
  if [ -n "$work" ] && [ -d "$work" ]; then
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

fail() {
  printf '[FAIL] verify-package: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[PASS] verify-package: %s\n' "$*"
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

expect_failure() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description (unexpected success)"
  fi
  pass "refusal: $description"
}

assert_current() {
  local expected=$1 current="$prefix/$PACKAGE_NAME/current"
  [ -L "$current" ] || fail "current is not a symlink: $current"
  [ "$(readlink -- "$current")" = "$expected" ] ||
    fail "current expected '$expected', got '$(readlink -- "$current")'"
}

assert_previous() {
  local expected=$1 previous="$prefix/$PACKAGE_NAME/previous"
  [ -f "$previous" ] || fail "previous file is missing: $previous"
  [ "$(<"$previous")" = "$expected" ] ||
    fail "previous expected '$expected', got '$(<"$previous")'"
}

assert_tree() {
  local tree=$1 expected_version=$2
  local allowed=" VERSION LICENSE README.md SECURITY-MODEL.md repo.toml lua "
  local required path name

  [ -d "$tree" ] || fail "installed tree is missing: $tree"
  [ -f "$tree/VERSION" ] || fail "installed tree is missing VERSION"
  [ "$(<"$tree/VERSION")" = "$expected_version" ] ||
    fail "installed VERSION does not match $expected_version"
  for required in LICENSE README.md SECURITY-MODEL.md repo.toml lua/wheel/init.lua; do
    [ -f "$tree/$required" ] || fail "installed tree is missing $required"
  done
  [ -z "$(find "$tree" -type l -print -quit)" ] ||
    fail "installed tree contains a symlink"
  while IFS= read -r path; do
    name=${path##*/}
    case "$allowed" in
    *" $name "*) ;;
    *) fail "unexpected installed entry: $name" ;;
    esac
  done < <(find "$tree" -mindepth 1 -maxdepth 1 -print)

  for name in tests recording node_modules .git .github dist scripts .carryctx .worktrees; do
    [ ! -e "$tree/$name" ] || fail "installed tree must not contain $name"
  done
  for name in justfile package.json bun.lock bitty-plugin.toml; do
    [ ! -e "$tree/$name" ] || fail "installed tree must not contain $name"
  done
}

run_fixture() {
  local label=$1
  local evidence="$work/evidence-$label.md"
  (
    cd "$REPO_ROOT"
    WHEEL_ROOT="$prefix/$PACKAGE_NAME/current" \
      WHEEL_EVIDENCE_PATH="$evidence" \
      lua5.1 tests/real_host_fixture.lua
  )
  [ -s "$evidence" ] || fail "real-host evidence was not written for $label"
  grep -q '^Status: PASSED' "$evidence" ||
    fail "real-host evidence for $label is not PASSED"
  pass "real-host fixture against installed tree: $label"
}

command -v lua5.1 >/dev/null 2>&1 || fail "lua5.1 is required"
command -v just >/dev/null 2>&1 || fail "just is required"
[ -f "$REPO_ROOT/VERSION" ] || fail "missing VERSION"
VERSION="$(<"$REPO_ROOT/VERSION")"
readonly VERSION
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unsupported VERSION: $VERSION"

mkdir -p -- "$TMP_BASE"
work="$(mktemp -d "$TMP_BASE/wheel-verify.XXXXXX")"
prefix="$work/prefix"
mkdir -p -- "$prefix"

# 1. Release-gate build through the justfile recipe. WHEEL_VERIFY_ALLOW_DIRTY=1
# is a pre-commit development escape hatch; CI and release verification must
# run without it.
package_args=()
if [ "${WHEEL_VERIFY_ALLOW_DIRTY:-0}" = "1" ]; then
  package_args+=(--allow-dirty)
fi
(
  cd "$REPO_ROOT"
  just package "${package_args[@]}"
)
archive="$REPO_ROOT/dist/$PACKAGE_NAME-$VERSION.tar.gz"
sidecar="$archive.sha256"
manifest="$REPO_ROOT/dist/$PACKAGE_NAME-$VERSION.manifest.json"
[ -f "$archive" ] || fail "missing archive: $archive"
[ -f "$sidecar" ] || fail "missing digest sidecar: $sidecar"
[ -f "$manifest" ] || fail "missing manifest: $manifest"
archive_digest="$(hash_file "$archive")"
[ "$(awk 'NR==1 {print $1}' "$sidecar")" = "$archive_digest" ] ||
  fail "digest sidecar does not match the archive"
grep -q "\"version\": \"$VERSION\"" "$manifest" ||
  fail "manifest does not record version $VERSION"
grep -q "\"archive_sha256\": \"$archive_digest\"" "$manifest" ||
  fail "manifest does not record the archive digest"
pass "release artifact and SHA-256 sidecar"

# 2. Rebuild determinism: same inputs, same bytes, fixed metadata.
rebuild_args=(--output-dir "$work/rebuilt")
if [ "${WHEEL_VERIFY_ALLOW_DIRTY:-0}" = "1" ]; then
  rebuild_args+=(--allow-dirty)
fi
bash "$REPO_ROOT/scripts/package.sh" "${rebuild_args[@]}" >/dev/null
cmp -s "$archive" "$work/rebuilt/$PACKAGE_NAME-$VERSION.tar.gz" ||
  fail "the artifact is not byte-for-byte deterministic"
pass "deterministic rebuild"

# 3. Install and validate the installed tree.
bash "$REPO_ROOT/scripts/install-local.sh" "$prefix"
assert_current "$VERSION"
assert_tree "$prefix/$PACKAGE_NAME/$VERSION" "$VERSION"
[ ! -e "$prefix/$PACKAGE_NAME/previous" ] ||
  fail "a first install must not record a previous version"
pass "install under <prefix>/wheel/<version> and current switch"

run_fixture "installed-$VERSION"

# 4. Upgrade to a locally built second version. Never published.
bash "$REPO_ROOT/scripts/package.sh" \
  --version "$TEST_VERSION" --allow-dirty --output-dir "$work/dist-$TEST_VERSION"
bash "$REPO_ROOT/scripts/install-local.sh" "$prefix" \
  --version "$TEST_VERSION" \
  --archive "$work/dist-$TEST_VERSION/$PACKAGE_NAME-$TEST_VERSION.tar.gz"
assert_current "$TEST_VERSION"
assert_previous "$VERSION"
assert_tree "$prefix/$PACKAGE_NAME/$TEST_VERSION" "$TEST_VERSION"
pass "upgrade $VERSION -> $TEST_VERSION with previous recorded"

run_fixture "upgraded-$TEST_VERSION"

# 5. Roll back to the previous installed version.
bash "$REPO_ROOT/scripts/install-local.sh" --rollback "$prefix"
assert_current "$VERSION"
assert_previous "$TEST_VERSION"
assert_tree "$prefix/$PACKAGE_NAME/$VERSION" "$VERSION"
pass "rollback $TEST_VERSION -> $VERSION"

run_fixture "rolled-back-$VERSION"

# 6. Refusals.
expect_failure "filesystem root prefix" \
  bash "$REPO_ROOT/scripts/install-local.sh" /
expect_failure "trailing-slash prefix" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$prefix/"
expect_failure "parent traversal in prefix" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$work/../work/prefix"
ln -s -- "$prefix" "$work/prefix-link"
expect_failure "symlinked prefix" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$work/prefix-link"
expect_failure "duplicate version" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$prefix"

mkdir -p -- "$work/foreign/$PACKAGE_NAME"
expect_failure "non-owned install root" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$work/foreign"

cp -- "$archive" "$work/tampered.tar.gz"
printf '%064d  %s\n' 0 "$(basename -- "$work/tampered.tar.gz")" \
  >"$work/tampered.tar.gz.sha256"
mkdir -p -- "$work/tamper-prefix"
expect_failure "digest mismatch" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$work/tamper-prefix" \
  --archive "$work/tampered.tar.gz"

cp -- "$archive" "$work/nodigest.tar.gz"
expect_failure "missing digest sidecar" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$work/tamper-prefix" \
  --archive "$work/nodigest.tar.gz"

mkdir -p -- "$work/evil/$PACKAGE_NAME-0.1.2"
ln -s -- /etc/passwd "$work/evil/$PACKAGE_NAME-0.1.2/link"
tar -czf "$work/evil.tar.gz" -C "$work/evil" "$PACKAGE_NAME-0.1.2"
printf '%s  %s\n' "$(hash_file "$work/evil.tar.gz")" "$(basename -- "$work/evil.tar.gz")" \
  >"$work/evil.tar.gz.sha256"
expect_failure "symlinked archive member" \
  bash "$REPO_ROOT/scripts/install-local.sh" "$work/tamper-prefix" \
  --version 0.1.2 --archive "$work/evil.tar.gz"

pass "package install/upgrade/rollback verification complete"

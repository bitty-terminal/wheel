#!/usr/bin/env bash
# Install, upgrade, or roll back a locally built Wheel harness artifact.
#
# Layout:
#   <prefix>/wheel/<version>/        installed artifact tree
#   <prefix>/wheel/current -> <version>
#   <prefix>/wheel/previous          version that `current` replaced
#   <prefix>/wheel/.wheel-install    ownership marker for the install root
#
# The installer is offline and never evaluates artifact content. It verifies
# the SHA-256 sidecar, rejects unsafe archive members and symlinks, refuses
# non-owned or symlinked targets, and switches `current` atomically. There is
# no eval, no shell-string construction from the archive, and no network.
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly PACKAGE_NAME="wheel"
readonly VERSION_FILE="$REPO_ROOT/VERSION"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly DEFAULT_OUTPUT_DIR="$REPO_ROOT/dist"
readonly TMP_BASE="${WHEEL_INSTALL_SCRATCH:-${TMPDIR:-/tmp}/bitty}"
readonly MARKER_NAME=".wheel-install"
readonly MARKER_CONTENT="wheel-install-root v1"

prefix=""
version=""
archive=""
rollback=0
work=""
staging=""
tmp_link=""

usage() {
  cat <<'EOF'
Usage: scripts/install-local.sh <prefix> [options]
       scripts/install-local.sh --rollback <prefix>

Install a locally built wheel-<version>.tar.gz under <prefix>/wheel/<version>/
and point <prefix>/wheel/current at it. The prefix must be an absolute,
existing directory; a leading `/`, a trailing slash, `.`/`..` components,
symlinked targets, and non-owned install roots are refused.

Options:
  --version <x.y.z>  Version to install (default: root VERSION file).
  --archive <path>   Archive to install (default: dist/wheel-<version>.tar.gz).
  --rollback         Switch current back to the recorded previous version.
  -h, --help         Show this help.

Every install requires the archive's .sha256 sidecar. No network is used.
EOF
}

die() {
  printf 'install-local: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$staging" ] && [ -d "$staging" ]; then
    rm -rf -- "$staging"
  fi
  if [ -n "$tmp_link" ] && [ -L "$tmp_link" ]; then
    rm -f -- "$tmp_link"
  fi
  if [ -n "$work" ] && [ -d "$work" ]; then
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

validate_version() {
  local candidate=$1
  if ! [[ $candidate =~ $VERSION_PATTERN ]]; then
    die "unsupported version '$candidate' (expected X.Y.Z)"
  fi
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

validate_prefix() {
  local candidate=$1
  case "$candidate" in
  /*) ;;
  *) die "prefix must be absolute: $candidate" ;;
  esac
  [ "$candidate" != "/" ] || die "refusing the filesystem root as a prefix"
  case "$candidate" in
  */) die "prefix must not end with '/': $candidate" ;;
  *$'\n'* | *$'\r'* | *$'\t'*) die "prefix contains control characters" ;;
  esac

  local trimmed=${candidate#/}
  local -a components=()
  IFS='/' read -r -a components <<<"$trimmed"
  local component
  for component in "${components[@]}"; do
    [ -n "$component" ] || die "prefix contains an empty component: $candidate"
    case "$component" in
    . | ..) die "prefix contains a '.' or '..' component: $candidate" ;;
    esac
  done

  [ ! -L "$candidate" ] || die "prefix must not be a symlink: $candidate"
  [ -d "$candidate" ] || die "prefix is not an existing directory: $candidate"
  [ -w "$candidate" ] || die "prefix is not writable: $candidate"
}

assert_owned_root() {
  local root=$1 marker="$1/$MARKER_NAME"
  [ ! -L "$root" ] || die "install root must not be a symlink: $root"
  [ -d "$root" ] || die "not an installed Wheel root: $root"
  [ ! -L "$marker" ] || die "install marker must not be a symlink: $marker"
  [ -f "$marker" ] || die "refusing a non-owned install root (missing $MARKER_NAME): $root"
  local marker_line
  marker_line="$(head -n 1 -- "$marker")"
  [ "$marker_line" = "$MARKER_CONTENT" ] ||
    die "unrecognized install root marker in $marker"
}

ensure_owned_root() {
  local root=$1 marker="$1/$MARKER_NAME"
  if [ -e "$root" ] || [ -L "$root" ]; then
    assert_owned_root "$root"
    return 0
  fi
  mkdir -m 0755 -- "$root"
  printf '%s\n' "$MARKER_CONTENT" >"$marker"
  chmod 0644 -- "$marker"
}

read_current_version() {
  local root=$1 current="$1/current" target target_dir
  [ -L "$current" ] || die "current is not a symlink: $current"
  target="$(readlink -- "$current")"
  case "$target" in
  "" | . | .. | */*) die "current has an unsafe target: $target" ;;
  esac
  validate_version "$target"
  target_dir="$root/$target"
  [ -d "$target_dir" ] && [ ! -L "$target_dir" ] ||
    die "current target is not an installed directory: $target"
  printf '%s\n' "$target"
}

switch_current() {
  local root=$1 value=$2
  tmp_link="$root/.current.tmp.$$"
  [ ! -e "$tmp_link" ] && [ ! -L "$tmp_link" ] || die "stale temporary link: $tmp_link"
  ln -s -- "$value" "$tmp_link"
  # -T keeps mv from following an existing `current` symlink to a directory;
  # the rename replaces the link itself.
  mv -Tf -- "$tmp_link" "$root/current"
  tmp_link=""
}

write_previous() {
  local root=$1 value=$2 tmp
  tmp="$(mktemp "$root/.previous.XXXXXX")"
  printf '%s\n' "$value" >"$tmp"
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$root/previous"
}

verify_digest() {
  local candidate=$1 sidecar="$1.sha256" expected_digest expected_name actual_digest
  [ ! -L "$candidate" ] || die "archive must not be a symlink: $candidate"
  [ -f "$candidate" ] || die "archive not found: $candidate"
  [ ! -L "$sidecar" ] || die "digest sidecar must not be a symlink: $sidecar"
  [ -f "$sidecar" ] || die "digest sidecar not found: $sidecar"
  [ "$(wc -l <"$sidecar")" -eq 1 ] ||
    die "digest sidecar must contain exactly one line: $sidecar"
  read -r expected_digest expected_name <"$sidecar"
  [[ $expected_digest =~ ^[0-9a-f]{64}$ ]] ||
    die "digest sidecar does not carry a lowercase SHA-256 digest: $sidecar"
  [ "$expected_name" = "$(basename -- "$candidate")" ] ||
    die "digest sidecar names a different archive: $sidecar"
  actual_digest="$(hash_file "$candidate")"
  [ "$actual_digest" = "$expected_digest" ] ||
    die "SHA-256 mismatch for $candidate"
}

validate_archive() {
  local candidate=$1 expected_version=$2
  local listing="$work/archive.list" types="$work/archive.types"
  local package_root="$PACKAGE_NAME-$expected_version"
  local entry line type

  tar --list --gzip --file="$candidate" >"$listing" || die "cannot list archive: $candidate"
  [ -s "$listing" ] || die "archive is empty: $candidate"
  while IFS= read -r entry; do
    case "$entry" in
    /* | .. | ../* | */.. | */../* | ./* | */./*)
      die "unsafe archive member: $entry"
      ;;
    esac
    case "$entry" in
    "$package_root" | "$package_root/"*) ;;
    *) die "unexpected archive member: $entry" ;;
    esac
  done <"$listing"

  tar --list --verbose --gzip --file="$candidate" >"$types" || die "cannot inspect archive members: $candidate"
  while IFS= read -r line; do
    type=${line:0:1}
    case "$type" in
    - | d) ;;
    *) die "archive contains a non-regular member: $line" ;;
    esac
  done <"$types"
}

validate_installed_tree() {
  local tree=$1 expected_version=$2
  local allowed=" VERSION LICENSE README.md SECURITY-MODEL.md repo.toml lua "
  local required path name installed_version
  [ -d "$tree" ] && [ ! -L "$tree" ] || die "installed tree is not a directory: $tree"
  [ -f "$tree/VERSION" ] || die "installed tree is missing VERSION"
  installed_version="$(<"$tree/VERSION")"
  [ "$installed_version" = "$expected_version" ] ||
    die "installed VERSION '$installed_version' does not match '$expected_version'"
  for required in LICENSE README.md SECURITY-MODEL.md repo.toml lua/wheel/init.lua; do
    [ -f "$tree/$required" ] || die "installed tree is missing $required"
  done
  [ -z "$(find "$tree" -type l -print -quit)" ] ||
    die "installed tree contains a symlink"
  while IFS= read -r path; do
    name=${path##*/}
    case "$allowed" in
    *" $name "*) ;;
    *) die "unexpected installed entry: $name" ;;
    esac
  done < <(find "$tree" -mindepth 1 -maxdepth 1 -print)
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --version)
    [ "$#" -ge 2 ] || die "--version requires a value"
    version=$2
    shift 2
    ;;
  --archive)
    [ "$#" -ge 2 ] || die "--archive requires a value"
    archive=$2
    shift 2
    ;;
  --rollback)
    rollback=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    die "unknown option: $1"
    ;;
  *)
    [ -z "$prefix" ] || die "only one prefix may be given"
    prefix=$1
    shift
    ;;
  esac
done

[ -n "$prefix" ] || die "a prefix is required"
validate_prefix "$prefix"
install_root="$prefix/$PACKAGE_NAME"

if [ "$rollback" -eq 1 ] && { [ -n "$version" ] || [ -n "$archive" ]; }; then
  die "--rollback does not accept --version or --archive"
fi

if [ "$rollback" -eq 1 ]; then
  assert_owned_root "$install_root"
  [ -f "$install_root/previous" ] && [ ! -L "$install_root/previous" ] ||
    die "no previous version recorded: $install_root/previous"
  previous="$(<"$install_root/previous")"
  validate_version "$previous"
  previous_dir="$install_root/$previous"
  validate_installed_tree "$previous_dir" "$previous"
  current_version="$(read_current_version "$install_root")"
  [ "$current_version" != "$previous" ] ||
    die "previous and current are both $previous; nothing to roll back"
  validate_installed_tree "$install_root/$current_version" "$current_version"
  switch_current "$install_root" "$previous"
  write_previous "$install_root" "$current_version"
  printf 'rollback: %s/current -> %s (previous: %s)\n' \
    "$install_root" "$previous" "$current_version"
  exit 0
fi

if [ -z "$version" ]; then
  [ -f "$VERSION_FILE" ] || die "missing VERSION file: $VERSION_FILE"
  version="$(<"$VERSION_FILE")"
fi
validate_version "$version"

if [ -z "$archive" ]; then
  archive="$DEFAULT_OUTPUT_DIR/$PACKAGE_NAME-$version.tar.gz"
fi
verify_digest "$archive"

mkdir -p -- "$TMP_BASE"
work="$(mktemp -d "$TMP_BASE/wheel-install.XXXXXX")"
validate_archive "$archive" "$version"

if [ -e "$install_root" ] || [ -L "$install_root" ]; then
  assert_owned_root "$install_root"
fi
version_dir="$install_root/$version"
[ ! -e "$version_dir" ] && [ ! -L "$version_dir" ] ||
  die "version already installed: $version"

ensure_owned_root "$install_root"
current_version=""
if [ -L "$install_root/current" ]; then
  current_version="$(read_current_version "$install_root")"
  validate_installed_tree "$install_root/$current_version" "$current_version"
elif [ -e "$install_root/current" ]; then
  die "current exists and is not a symlink: $install_root/current"
fi

staging="$install_root/.staging.$version.$$"
[ ! -e "$staging" ] && [ ! -L "$staging" ] || die "stale staging directory: $staging"
mkdir -m 0700 -- "$staging"
tar --extract --gzip --file="$archive" -C "$staging" --no-same-owner --no-same-permissions
source_dir="$staging/$PACKAGE_NAME-$version"
validate_installed_tree "$source_dir" "$version"
find "$source_dir" -type d -exec chmod 0755 {} +
find "$source_dir" -type f -exec chmod 0644 {} +
mv -- "$source_dir" "$version_dir"
rmdir -- "$staging"
staging=""

if [ -n "$current_version" ] && [ "$current_version" != "$version" ]; then
  write_previous "$install_root" "$current_version"
fi
switch_current "$install_root" "$version"

printf 'installed: %s (current -> %s)\n' "$version_dir" "$version"
if [ -n "$current_version" ] && [ "$current_version" != "$version" ]; then
  printf 'previous: %s\n' "$current_version"
fi

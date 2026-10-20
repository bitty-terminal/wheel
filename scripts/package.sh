#!/usr/bin/env bash
# Build the standalone Wheel harness artifact.
#
# Output (all under dist/ by default):
#   wheel-<version>.tar.gz
#   wheel-<version>.tar.gz.sha256
#   wheel-<version>.manifest.json
#
# The archive is deterministic: sorted member order, fixed mtime, fixed
# ownership, normalized modes, and gzip without a name or timestamp. The
# archive is a library tree, not a Bitty plugin: it carries no manifest
# capability grant and no plugin-api compatibility contract.
#
# The release build refuses a dirty worktree and an unsupported version. A
# local test build may pass --allow-dirty (and a different --version) to
# exercise the install/upgrade path without publishing anything.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly PACKAGE_NAME="wheel"
readonly VERSION_FILE="$REPO_ROOT/VERSION"
readonly DEFAULT_OUTPUT_DIR="$REPO_ROOT/dist"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly ARTIFACT_INPUTS=(LICENSE README.md SECURITY-MODEL.md repo.toml VERSION lua)
readonly TMP_BASE="${WHEEL_PACKAGE_SCRATCH:-${TMPDIR:-/tmp}/bitty}"

version=""
output_dir="$DEFAULT_OUTPUT_DIR"
allow_dirty=0
stage=""
tmp_archive=""

usage() {
  cat <<'EOF'
Usage: scripts/package.sh [options]

Build dist/wheel-<version>.tar.gz, its SHA-256 sidecar, and a manifest record.

Options:
  --version <x.y.z>   Build a different local version (requires --allow-dirty).
  --output-dir <dir>  Write artifacts to <dir> instead of dist/.
  --allow-dirty       Skip the clean-worktree gate for a local test build.
  -h, --help          Show this help.

The version comes from the root VERSION file unless --version is given.
EOF
}

die() {
  printf 'package: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$stage" ] && [ -d "$stage" ]; then
    rm -rf -- "$stage"
  fi
  if [ -n "$tmp_archive" ] && [ -e "$tmp_archive" ]; then
    rm -f -- "$tmp_archive"
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

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

require_clean_inputs() {
  command -v git >/dev/null 2>&1 || die "git is required for the clean-worktree gate"
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "not a Git work tree: $REPO_ROOT"
  local dirty
  dirty="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty" >&2
    die "worktree is dirty; commit or stash the changes, or pass --allow-dirty for a local test build"
  fi
}

check_package_metadata() {
  local expected=$1 package_version
  [ -f "$REPO_ROOT/package.json" ] || die "missing package.json"
  package_version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$REPO_ROOT/package.json" | head -n 1)"
  [ -n "$package_version" ] || die "package.json carries no version"
  [ "$package_version" = "$expected" ] ||
    die "package.json version '$package_version' must match VERSION '$expected'"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --version)
    [ "$#" -ge 2 ] || die "--version requires a value"
    version=$2
    shift 2
    ;;
  --version=*)
    version=${1#*=}
    shift
    ;;
  --output-dir)
    [ "$#" -ge 2 ] || die "--output-dir requires a value"
    output_dir=$2
    shift 2
    ;;
  --output-dir=*)
    output_dir=${1#*=}
    shift
    ;;
  --allow-dirty)
    allow_dirty=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown argument: $1"
    ;;
  esac
done

[ -f "$VERSION_FILE" ] || die "missing VERSION file: $VERSION_FILE"
canonical_version="$(<"$VERSION_FILE")"
validate_version "$canonical_version"

if [ -n "$version" ] && [ "$version" != "$canonical_version" ] && [ "$allow_dirty" -eq 0 ]; then
  die "version override '$version' requires --allow-dirty (local test build only)"
fi
version=${version:-$canonical_version}
validate_version "$version"

if [ "$allow_dirty" -eq 1 ]; then
  printf 'package: WARNING local test build (--allow-dirty); not a release artifact\n' >&2
else
  require_clean_inputs
fi
if [ "$version" = "$canonical_version" ]; then
  check_package_metadata "$version"
fi

for input in "${ARTIFACT_INPUTS[@]}"; do
  [ -e "$REPO_ROOT/$input" ] || die "missing artifact input: $input"
done
[ -f "$REPO_ROOT/lua/wheel/init.lua" ] || die "missing artifact entry point: lua/wheel/init.lua"

symlink="$(find "$REPO_ROOT/lua" -type l -print -quit)"
if [ -n "$symlink" ]; then
  die "artifact input contains a symlink: ${symlink#"$REPO_ROOT/"}"
fi

if [ -e "$output_dir" ] && [ -L "$output_dir" ]; then
  die "output directory must not be a symlink: $output_dir"
fi
mkdir -p -- "$output_dir"

mkdir -p -- "$TMP_BASE"
stage="$(mktemp -d "$TMP_BASE/wheel-package.XXXXXX")"
package_dir="$PACKAGE_NAME-$version"
package_root="$stage/$package_dir"
mkdir -p -- "$package_root/lua"

for file in LICENSE README.md SECURITY-MODEL.md repo.toml; do
  install -m 0644 -- "$REPO_ROOT/$file" "$package_root/$file"
done
printf '%s\n' "$version" >"$package_root/VERSION"
cp -R -- "$REPO_ROOT/lua/." "$package_root/lua/"

find "$package_root" -type d -exec chmod 0755 {} +
find "$package_root" -type f -exec chmod 0644 {} +

archive="$output_dir/$PACKAGE_NAME-$version.tar.gz"
digest_file="$archive.sha256"
manifest="$output_dir/$PACKAGE_NAME-$version.manifest.json"

(cd -- "$stage" && find "$package_dir" -print | LC_ALL=C sort) >"$stage/archive.list"
tar --format=ustar --mtime='@0' --owner=0 --group=0 --numeric-owner \
  --no-recursion -C "$stage" -T "$stage/archive.list" -cf "$stage/archive.tar"

tmp_archive="$(mktemp "$output_dir/.wheel-package.XXXXXX")"
gzip -9 -n -c "$stage/archive.tar" >"$tmp_archive"
chmod 0644 "$tmp_archive"
mv -f -- "$tmp_archive" "$archive"
tmp_archive=""

digest="$(hash_file "$archive")"
digest_tmp="$(mktemp "$output_dir/.wheel-digest.XXXXXX")"
printf '%s  %s\n' "$digest" "$(basename -- "$archive")" >"$digest_tmp"
chmod 0644 "$digest_tmp"
mv -f -- "$digest_tmp" "$digest_file"

(cd -- "$package_root" && find . -type f -print | LC_ALL=C sort) |
  sed 's|^\./||' >"$stage/manifest-files.list"

if [ "$allow_dirty" -eq 1 ]; then
  source_clean_verified=false
else
  source_clean_verified=true
fi

manifest_tmp="$(mktemp "$output_dir/.wheel-manifest.XXXXXX")"
{
  printf '{\n'
  printf '  "name": "%s",\n' "$PACKAGE_NAME"
  printf '  "version": "%s",\n' "$version"
  printf '  "archive": "%s",\n' "$(basename -- "$archive")"
  printf '  "archive_sha256": "%s",\n' "$digest"
  printf '  "source_clean_verified": %s,\n' "$source_clean_verified"
  printf '  "files": [\n'
  first=1
  while IFS= read -r relative; do
    absolute="$package_root/$relative"
    size="$(wc -c <"$absolute" | tr -d '[:space:]')"
    file_digest="$(hash_file "$absolute")"
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '    {"path": "%s", "sha256": "%s", "size": %s}' \
      "$(json_escape "$relative")" "$file_digest" "$size"
  done <"$stage/manifest-files.list"
  printf '\n  ]\n}\n'
} >"$manifest_tmp"
chmod 0644 "$manifest_tmp"
mv -f -- "$manifest_tmp" "$manifest"

printf 'package: %s\n' "$archive"
printf 'sha256: %s\n' "$digest"
printf 'manifest: %s\n' "$manifest"

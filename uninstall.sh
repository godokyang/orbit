#!/usr/bin/env sh
set -eu

MARKER_NAME=".orbit-install"
MARKER_SCHEMA="orbit-install-v1"

usage() {
  cat <<'USAGE'
Uninstall the Orbit CLI.

Usage:
  sh uninstall.sh [--bin-dir DIR] [--runtime-dir DIR]

Options:
  --bin-dir DIR      Directory containing the orbit command wrapper.
                     Default: $ORBIT_INSTALL_DIR or $HOME/.local/bin
  --runtime-dir DIR  Runtime directory whose install marker lists owned files.
                     Default: $ORBIT_RUNTIME_DIR or
                     $XDG_DATA_HOME/orbit/orbit or $HOME/.local/share/orbit/orbit
  -h, --help         Show this help.

Removes only files recorded in the install marker plus a matching wrapper.
Unknown files are left in place. Project .orbit data is not touched.

Environment:
  ORBIT_INSTALL_DIR  Same as --bin-dir.
  ORBIT_RUNTIME_DIR  Same as --runtime-dir.
USAGE
}

fail() {
  printf 'orbit uninstall: %s\n' "$*" >&2
  exit 1
}

need_value() {
  option="$1"
  value="${2:-}"
  [ -n "$value" ] || fail "missing value for $option"
  case "$value" in
    --*) fail "missing value for $option" ;;
  esac
}

parent_dir() {
  path="$1"
  dir=${path%/*}
  if [ "$dir" = "$path" ]; then
    printf '.\n'
  else
    printf '%s\n' "$dir"
  fi
}

bin_dir="${ORBIT_INSTALL_DIR:-${HOME:-}/.local/bin}"
if [ -n "${ORBIT_RUNTIME_DIR:-}" ]; then
  runtime_dir="$ORBIT_RUNTIME_DIR"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  runtime_dir="$XDG_DATA_HOME/orbit/orbit"
else
  runtime_dir="${HOME:-}/.local/share/orbit/orbit"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir)
      need_value "$1" "${2:-}"
      bin_dir="$2"
      shift 2
      ;;
    --runtime-dir)
      need_value "$1" "${2:-}"
      runtime_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[ -n "$bin_dir" ] || fail "bin directory is empty"
[ -n "$runtime_dir" ] || fail "runtime directory is empty"
command -v ruby >/dev/null 2>&1 || fail "Ruby is required to identify this installation"
bin_dir=$(ruby --disable-gems -e 'puts File.expand_path(ARGV.fetch(0))' "$bin_dir")
runtime_dir=$(ruby --disable-gems -e 'puts File.expand_path(ARGV.fetch(0))' "$runtime_dir")

target_wrapper="$bin_dir/orbit"
target_cli="$runtime_dir/scripts/orbit"
quoted_cli=$(ruby --disable-gems -rshellwords -e 'puts Shellwords.escape(ARGV.fetch(0))' "$target_cli")
marker_path="$runtime_dir/$MARKER_NAME"
kept=0

if [ -f "$target_wrapper" ] || [ -L "$target_wrapper" ]; then
  if grep -Fxq "ORBIT_CLI=$quoted_cli" "$target_wrapper" 2>/dev/null &&
     grep -q 'exec "$ORBIT_CLI" "$@"' "$target_wrapper" 2>/dev/null; then
    rm -f "$target_wrapper"
    printf 'Removed orbit wrapper: %s\n' "$target_wrapper"
  else
    printf 'Skipped wrapper not owned by this runtime: %s\n' "$target_wrapper" >&2
    kept=1
  fi
else
  printf 'No orbit wrapper found at %s\n' "$target_wrapper"
fi

if [ ! -e "$runtime_dir" ]; then
  printf 'No runtime directory found at %s\n' "$runtime_dir"
  exit 0
fi

if [ ! -d "$runtime_dir" ]; then
  fail "runtime path exists and is not a directory: $runtime_dir"
fi

if [ ! -f "$marker_path" ]; then
  printf 'No %s marker in %s; leaving directory untouched (not an Orbit runtime this uninstaller owns).\n' "$MARKER_NAME" "$runtime_dir" >&2
  exit 0
fi

header=$(head -n 1 "$marker_path")
if [ "$header" != "$MARKER_SCHEMA" ]; then
  printf 'Unknown install marker in %s; leaving directory untouched.\n' "$runtime_dir" >&2
  exit 0
fi

# Skip the schema line; delete only recorded relative paths under runtime_dir.
tail -n +2 "$marker_path" | while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    /*|..|../*|*/..|*/../*)
      printf 'Skipped unsafe marker path: %s\n' "$rel" >&2
      continue
      ;;
  esac
  path="$runtime_dir/$rel"
  case "$path" in
    "$runtime_dir"/*) ;;
    *)
      printf 'Skipped path outside runtime: %s\n' "$rel" >&2
      continue
      ;;
  esac
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    rm -rf "$path"
  elif [ -e "$path" ] || [ -L "$path" ]; then
    rm -f "$path"
  fi
done

rm -f "$marker_path"

# Drop empty directories this install left behind; keep anything still occupied.
if command -v find >/dev/null 2>&1; then
  find "$runtime_dir" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
fi

if [ -d "$runtime_dir" ]; then
  printf 'Left remaining files in %s (not recorded as this install).\n' "$runtime_dir"
  kept=1
else
  printf 'Removed runtime directory: %s\n' "$runtime_dir"
fi

if [ "$kept" -eq 1 ]; then
  printf 'Uninstall kept paths that were not owned by this installer.\n'
fi

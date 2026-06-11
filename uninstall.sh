#!/usr/bin/env sh
set -eu

usage() {
  cat <<'USAGE'
Uninstall the Orbit CLI.

Usage:
  sh uninstall.sh [--bin-dir DIR] [--runtime-dir DIR]

Options:
  --bin-dir DIR      Directory containing the orbit command wrapper.
                     Default: $ORBIT_INSTALL_DIR or $HOME/.local/bin
  --runtime-dir DIR  Runtime directory to remove.
                     Default: $ORBIT_RUNTIME_DIR or
                     $XDG_DATA_HOME/orbit/orbit or
                     $HOME/.local/share/orbit/orbit
  -h, --help         Show this help.

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

target_wrapper="$bin_dir/orbit"

if [ -f "$target_wrapper" ]; then
  if grep -q 'ORBIT_CLI=' "$target_wrapper" &&
     grep -q 'exec "$ORBIT_CLI" "$@"' "$target_wrapper"; then
    rm -f "$target_wrapper"
    printf 'Removed orbit wrapper: %s\n' "$target_wrapper"
  else
    printf 'Skipped wrapper not created by Orbit installer: %s\n' "$target_wrapper" >&2
  fi
else
  printf 'No orbit wrapper found at %s\n' "$target_wrapper"
fi

if [ -d "$runtime_dir" ]; then
  rm -rf "$runtime_dir"
  printf 'Removed runtime directory: %s\n' "$runtime_dir"
else
  printf 'No runtime directory found at %s\n' "$runtime_dir"
fi

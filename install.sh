#!/usr/bin/env sh
set -eu

DEFAULT_REF="main"
ORBIT_REF="${ORBIT_REF:-$DEFAULT_REF}"

usage() {
  cat <<'USAGE'
Install or update the Orbit CLI.

Usage:
  curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
  sh install.sh [--bin-dir DIR] [--runtime-dir DIR] [--ref REF]

Options:
  --bin-dir DIR      Install the orbit command wrapper here.
                     Default: $ORBIT_INSTALL_DIR or $HOME/.local/bin
  --runtime-dir DIR  Install the skill runtime files here.
                     Default: $ORBIT_RUNTIME_DIR or
                     $XDG_DATA_HOME/orbit/orbit or
                     $HOME/.local/share/orbit/orbit
  --ref REF          Git ref used by curl installs. Default: main
  -h, --help         Show this help.

Environment:
  ORBIT_INSTALL_DIR  Same as --bin-dir.
  ORBIT_RUNTIME_DIR  Same as --runtime-dir.
  ORBIT_REF          Same as --ref.
  ORBIT_RAW_BASE     Override raw file base URL for advanced installs.
USAGE
}

fail() {
  printf 'orbit install: %s\n' "$*" >&2
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
    --ref)
      need_value "$1" "${2:-}"
      ORBIT_REF="$2"
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
command -v ruby >/dev/null 2>&1 || fail "ruby is required but was not found in PATH"

raw_base="${ORBIT_RAW_BASE:-https://raw.githubusercontent.com/godokyang/orbit/${ORBIT_REF}}"
target_cli="$runtime_dir/scripts/orbit"
target_wrapper="$bin_dir/orbit"

runtime_files="
SKILL.md
scripts/orbit
lib/orbit/cli.rb
lib/orbit/core.rb
lib/orbit/identity_rules.rb
lib/orbit/task_launch_dispatch.rb
lib/orbit/evidence.rb
lib/orbit/state_validate_gate.rb
lib/orbit/audit_tools.rb
lib/orbit/handoff.rb
lib/orbit/docs_lifecycle.rb
assets/templates/roles.yaml
assets/templates/instances.yaml
assets/templates/loop-state.yaml
assets/templates/task.yaml
assets/templates/evidence.json
assets/templates/review-report.yaml
assets/templates/test-report.yaml
references/runtime/guide.md
references/runtime/core-operating-model.md
references/runtime/coding-guideline.md
references/runtime/quality-outcome-and-review.md
references/runtime/testing-guideline.md
"

parent_dir() {
  path="$1"
  dir=${path%/*}
  if [ "$dir" = "$path" ]; then
    printf '.\n'
  else
    printf '%s\n' "$dir"
  fi
}

download_file() {
  url="$1"
  dest="$2"
  tmp="${dest}.tmp.$$"

  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || {
      rm -f "$tmp"
      return 1
    }
  else
    fail "curl or wget is required for remote installs"
  fi

  mv "$tmp" "$dest"
}

copy_file() {
  source="$1"
  dest="$2"
  tmp="${dest}.tmp.$$"

  rm -f "$tmp"
  cp "$source" "$tmp"
  mv "$tmp" "$dest"
}

install_local_runtime() {
  source_root="$1"

  for file in $runtime_files; do
    source_file="$source_root/$file"
    target_file="$runtime_dir/$file"
    [ -f "$source_file" ] || fail "missing runtime source file: $source_file"
    mkdir -p "$(parent_dir "$target_file")"
    copy_file "$source_file" "$target_file"
  done
}

install_remote_runtime() {
  for file in $runtime_files; do
    target_file="$runtime_dir/$file"
    mkdir -p "$(parent_dir "$target_file")"
    download_file "$raw_base/$file" "$target_file" ||
      fail "failed to download $raw_base/$file"
  done
}

script_dir=""
case "$0" in
  */*)
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P || printf '')
    ;;
  *)
    if [ -f "./$0" ]; then
      script_dir=$(pwd -P 2>/dev/null || printf '')
    fi
    ;;
esac

if [ -n "$script_dir" ] &&
   [ -f "$script_dir/install.sh" ] &&
   [ -f "$script_dir/scripts/orbit" ] &&
   [ -f "$script_dir/assets/templates/roles.yaml" ]; then
  install_local_runtime "$script_dir"
else
  install_remote_runtime
fi

chmod 0755 "$target_cli"
mkdir -p "$bin_dir"
wrapper_tmp="${target_wrapper}.tmp.$$"
rm -f "$wrapper_tmp"
{
  printf '%s\n' '#!/usr/bin/env sh'
  printf '%s\n' "ORBIT_CLI=\"$target_cli\""
  printf '%s\n' 'exec "$ORBIT_CLI" "$@"'
} >"$wrapper_tmp"
chmod 0755 "$wrapper_tmp"
mv "$wrapper_tmp" "$target_wrapper"

"$target_wrapper" version >/dev/null || fail "installed orbit command failed verification"

printf 'Installed orbit to %s\n' "$target_wrapper"
printf 'Runtime files installed to %s\n' "$runtime_dir"
printf 'Update: rerun this installer.\n'
printf 'Uninstall: sh uninstall.sh --bin-dir %s --runtime-dir %s\n' "$bin_dir" "$runtime_dir"

case ":${PATH:-}:" in
  *":$bin_dir:"*) ;;
  *)
    printf 'Add %s to PATH to run orbit from any shell.\n' "$bin_dir"
    ;;
esac

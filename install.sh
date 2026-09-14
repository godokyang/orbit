#!/usr/bin/env sh
set -eu

DEFAULT_REF="main"
ORBIT_REF="${ORBIT_REF:-$DEFAULT_REF}"
MARKER_NAME=".orbit-install"
MARKER_SCHEMA="orbit-install-v1"

usage() {
  cat <<'USAGE'
Install or update the Orbit CLI.

Usage:
  curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
  sh install.sh [--bin-dir DIR] [--runtime-dir DIR] [--ref REF]

Options:
  --bin-dir DIR      Wrapper directory. Default: $ORBIT_INSTALL_DIR or $HOME/.local/bin
  --runtime-dir DIR  Runtime directory. Default: $ORBIT_RUNTIME_DIR or
                     $XDG_DATA_HOME/orbit/orbit or $HOME/.local/share/orbit/orbit
  --ref REF          Git ref for curl installs. Default: main
  -h, --help         Show this help.

Requires Ruby >= 3.2, Node >= 18, npm, and an existing Codex CLI on PATH.
Does not install Codex, write a global npm prefix, or touch project AGENTS/.orbit.
A non-empty runtime directory without an Orbit install marker is refused;
choose an empty directory. Old protocol/epoch layouts are not migrated.

Environment:
  ORBIT_INSTALL_DIR  Same as --bin-dir.
  ORBIT_RUNTIME_DIR  Same as --runtime-dir.
  ORBIT_REF          Same as --ref.
  ORBIT_RAW_BASE     Override raw file base URL for advanced installs.
  ORBIT_INSTALL_QUIET=1
                     Suppress progress messages.
USAGE
}

fail() {
  printf 'orbit install: %s\n' "$*" >&2
  exit 1
}

install_log() {
  [ "${ORBIT_INSTALL_QUIET:-0}" = "1" ] && return 0
  printf 'orbit install: %s\n' "$*"
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

dir_occupied() {
  dir="$1"
  [ -d "$dir" ] || return 1
  for p in "$dir"/.[!.]* "$dir"/..?* "$dir"/*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    return 0
  done
  return 1
}

download_file() {
  url="$1"
  dest="$2"
  tmp="${dest}.tmp.$$"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || { rm -f "$tmp"; return 1; }
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

# Owned payload. Do not add v2 lib, orbit-v2 contracts, old references, or templates.
runtime_files="
README.md
package.json
npm-shrinkwrap.json
scripts/orbit
scripts/codex-socket.cjs
lib/orbit/cli.rb
lib/orbit/task_record.rb
lib/orbit/task_runtime.rb
lib/orbit/workspace_snapshot.rb
lib/orbit/codex_connection.rb
lib/orbit/check_runner.rb
contracts/task-runtime.md
contracts/check-result.schema.json
skills/orbit/SKILL.md
skills/orbit/references/model-selection.md
skills/orbit/assets/rule-library/resident/AGENTS.md.template
skills/orbit/assets/rule-library/shared/escalation-payload.md
skills/orbit/assets/rule-library/tasks/minimal-implementation.md
skills/orbit/assets/rule-library/tasks/targeted-fix.md
skills/orbit/assets/rule-library/tasks/test-selection.md
skills/orbit/assets/rule-library/tasks/review.md
skills/orbit/assets/rule-library/tasks/vantage-audit.md
skills/orbit/assets/rule-library/tasks/structured-boundary.md
skills/orbit/assets/rule-library/tasks/mutating-surface.md
skills/orbit/assets/rule-library/tasks/quality-outcome.md
"

write_marker() {
  marker="$runtime_dir/$MARKER_NAME"
  tmp="${marker}.tmp.$$"
  {
    printf '%s\n' "$MARKER_SCHEMA"
    for file in $runtime_files; do
      printf '%s\n' "$file"
    done
    printf '%s\n' "node_modules"
    printf '%s\n' ".npm-cache"
  } >"$tmp"
  mv "$tmp" "$marker"
}

place_files() {
  for file in $runtime_files; do
    target_file="$runtime_dir/$file"
    mkdir -p "$(parent_dir "$target_file")"
    if [ "$source_mode" = "local" ]; then
      source_file="$source_root/$file"
      [ -f "$source_file" ] || fail "missing runtime source file: $source_file"
      copy_file "$source_file" "$target_file"
    else
      download_file "$raw_base/$file" "$target_file" ||
        fail "failed to download $raw_base/$file"
    fi
  done
  chmod 0755 "$runtime_dir/scripts/orbit" "$runtime_dir/scripts/codex-socket.cjs"
}

install_npm() {
  command -v npm >/dev/null 2>&1 || fail "npm is required to install the ws runtime dependency"
  install_log "npm ci in $runtime_dir"
  (
    cd "$runtime_dir"
    npm ci --ignore-scripts --omit=dev --omit=optional --no-audit --no-fund --cache "$runtime_dir/.npm-cache"
  ) || fail "npm ci failed"
}

write_wrapper() {
  mkdir -p "$bin_dir"
  if [ -e "$target_wrapper" ] || [ -L "$target_wrapper" ]; then
    if grep -Fxq "ORBIT_CLI=$quoted_cli" "$target_wrapper" 2>/dev/null &&
       grep -q 'exec "$ORBIT_CLI" "$@"' "$target_wrapper" 2>/dev/null; then
      :
    else
      fail "refusing to overwrite existing file that this installer does not own: $target_wrapper"
    fi
  fi
  wrapper_tmp="${target_wrapper}.tmp.$$"
  rm -f "$wrapper_tmp"
  {
    printf '%s\n' '#!/usr/bin/env sh'
    printf '%s\n' "ORBIT_CLI=$quoted_cli"
    printf '%s\n' 'exec "$ORBIT_CLI" "$@"'
  } >"$wrapper_tmp"
  chmod 0755 "$wrapper_tmp"
  mv "$wrapper_tmp" "$target_wrapper"
}

require_ruby() {
  command -v ruby >/dev/null 2>&1 || fail "Ruby >= 3.2 is required but ruby was not found in PATH"
  ruby -e 'v=RUBY_VERSION.split(".").map(&:to_i); exit(v[0]>3 || (v[0]==3 && v[1]>=2) ? 0 : 1)' \
    || fail "Ruby >= 3.2 is required (Queue.pop timeout); found $(ruby -e 'print RUBY_VERSION')"
}

require_node() {
  command -v node >/dev/null 2>&1 || fail "Node >= 18 is required but node was not found in PATH"
  node -e 'process.exit(parseInt(process.versions.node, 10) >= 18 ? 0 : 1)' \
    || fail "Node >= 18 is required; found $(node -p process.versions.node)"
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
    --mode)
      fail "install modes are not supported; omit --mode and install into an empty runtime directory"
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

require_ruby
require_node
bin_dir=$(ruby --disable-gems -e 'puts File.expand_path(ARGV.fetch(0))' "$bin_dir")
runtime_dir=$(ruby --disable-gems -e 'puts File.expand_path(ARGV.fetch(0))' "$runtime_dir")
command -v npm >/dev/null 2>&1 || fail "npm is required but was not found in PATH"
command -v codex >/dev/null 2>&1 || fail "Codex CLI is required on PATH; install Codex separately, this installer does not ship it"

raw_base="${ORBIT_RAW_BASE:-https://raw.githubusercontent.com/godokyang/orbit/${ORBIT_REF}}"
target_cli="$runtime_dir/scripts/orbit"
quoted_cli=$(ruby --disable-gems -rshellwords -e 'puts Shellwords.escape(ARGV.fetch(0))' "$target_cli")
target_wrapper="$bin_dir/orbit"
marker_path="$runtime_dir/$MARKER_NAME"

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

source_mode="remote"
source_root=""
if [ -n "$script_dir" ] &&
   [ -f "$script_dir/scripts/orbit" ] &&
   [ -f "$script_dir/scripts/codex-socket.cjs" ] &&
   [ -f "$script_dir/lib/orbit/cli.rb" ] &&
   [ -f "$script_dir/npm-shrinkwrap.json" ]; then
  source_mode="local"
  source_root="$script_dir"
fi

if [ -e "$runtime_dir" ] && [ ! -d "$runtime_dir" ]; then
  fail "runtime path exists and is not a directory: $runtime_dir"
fi

if dir_occupied "$runtime_dir"; then
  if [ ! -f "$marker_path" ]; then
    fail "runtime directory is not empty and has no $MARKER_NAME marker: $runtime_dir (choose an empty directory; old installs are not migrated)"
  fi
  header=$(head -n 1 "$marker_path")
  [ "$header" = "$MARKER_SCHEMA" ] ||
    fail "runtime directory has an unknown install marker; choose an empty directory: $runtime_dir"
  install_log "updating existing Orbit runtime"
else
  mkdir -p "$runtime_dir"
fi

install_log "installing Orbit CLI"
install_log "wrapper: $target_wrapper"
install_log "runtime: $runtime_dir"
install_log "source: $source_mode"

write_marker
place_files
install_npm
write_marker
write_wrapper

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

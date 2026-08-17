#!/usr/bin/env sh
set -eu

DEFAULT_REF="main"
ORBIT_REF="${ORBIT_REF:-$DEFAULT_REF}"

usage() {
  cat <<'USAGE'
Install or update the Orbit CLI.

Usage:
  curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
  sh install.sh [--mode manual|automatic] [--bin-dir DIR] [--runtime-dir DIR] [--ref REF]

Options:
  --mode MODE       manual (default) installs the stable file/JSON protocol
                    without Herdr. automatic also checks the Herdr adapter;
                    runtime remains preview and direct dispatch stays unavailable
                    until trusted proof and provider E2E pass.
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
  ORBIT_INSTALL_MODE Same as --mode. Default: manual.
  ORBIT_RAW_BASE     Override raw file base URL for advanced installs.
  ORBIT_INSTALL_QUIET=1
                     Suppress progress messages.
USAGE
}

fail() {
  printf 'orbit install: %s\n' "$*" >&2
  exit 1
}

progress_enabled() {
  [ "${ORBIT_INSTALL_QUIET:-0}" != "1" ]
}

install_log() {
  progress_enabled || return 0
  printf 'orbit install: %s\n' "$*"
}

progress_update() {
  current="$1"
  total="$2"
  action="$3"
  file="$4"

  progress_enabled || return 0
  if [ -t 1 ]; then
    printf '\rorbit install: [%s/%s] %s %s' "$current" "$total" "$action" "$file"
    return 0
  fi

  if [ "$current" -eq 1 ] ||
     [ $((current % 10)) -eq 0 ]; then
    install_log "[$current/$total] $action $file"
  fi
}

progress_done() {
  total="$1"
  action="$2"

  progress_enabled || return 0
  if [ -t 1 ]; then
    printf '\n'
  fi
  install_log "$action complete ($total files)"
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
install_mode="${ORBIT_INSTALL_MODE:-manual}"
if [ -n "${ORBIT_RUNTIME_DIR:-}" ]; then
  runtime_dir="$ORBIT_RUNTIME_DIR"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  runtime_dir="$XDG_DATA_HOME/orbit/orbit"
else
  runtime_dir="${HOME:-}/.local/share/orbit/orbit"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      need_value "$1" "${2:-}"
      install_mode="$2"
      shift 2
      ;;
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
case "$install_mode" in
  manual|automatic) ;;
  *) fail "mode must be manual or automatic" ;;
esac
command -v ruby >/dev/null 2>&1 || fail "ruby is required but was not found in PATH"
if [ "$install_mode" = "automatic" ]; then
  command -v herdr >/dev/null 2>&1 || fail "Herdr is required for --mode automatic. Use --mode manual or install Herdr first: curl -fsSL https://herdr.dev/install.sh | sh && herdr --version"
  herdr --version >/dev/null 2>&1 || fail 'Herdr was found but `herdr --version` failed. Fix Herdr, use --mode manual, or rerun the Orbit installer.'
fi

raw_base="${ORBIT_RAW_BASE:-https://raw.githubusercontent.com/godokyang/orbit/${ORBIT_REF}}"
target_cli="$runtime_dir/scripts/orbit"
target_wrapper="$bin_dir/orbit"

runtime_files="
package.json
scripts/orbit
lib/orbit/v2/active_root.rb
lib/orbit/v2/aggregate_outcome.rb
lib/orbit/v2/authority_verifier.rb
lib/orbit/v2/budget_projection.rb
lib/orbit/v2/canonical_json.rb
lib/orbit/v2/cli.rb
lib/orbit/v2/cli/document_factory.rb
lib/orbit/v2/code_surface.rb
lib/orbit/v2/context_projection.rb
lib/orbit/v2/control_authority.rb
lib/orbit/v2/control_store.rb
lib/orbit/v2/durable_file.rb
lib/orbit/v2/errors.rb
lib/orbit/v2/evaluation_subject.rb
lib/orbit/v2/evidence_contract.rb
lib/orbit/v2/evidence_store.rb
lib/orbit/v2/gate_engine.rb
lib/orbit/v2/gate_fact_store.rb
lib/orbit/v2/gate_strength.rb
lib/orbit/v2/identifiers.rb
lib/orbit/v2/immutable_store.rb
lib/orbit/v2/integrity_audit.rb
lib/orbit/v2/invariant_graph.rb
lib/orbit/v2/json_schema.rb
lib/orbit/v2/lead_control.rb
lib/orbit/v2/lifecycle_verifier.rb
lib/orbit/v2/local_provider.rb
lib/orbit/v2/path_scope.rb
lib/orbit/v2/policy_issuance.rb
lib/orbit/v2/policy_store.rb
lib/orbit/v2/projection_primitives.rb
lib/orbit/v2/protected_change.rb
lib/orbit/v2/protocol_root.rb
lib/orbit/v2/relationship_view.rb
lib/orbit/v2/rule_resolution.rb
lib/orbit/v2/runtime_identity_verifier.rb
lib/orbit/v2/schema_catalog.rb
lib/orbit/v2/task_authority.rb
lib/orbit/v2/task_scopes.rb
lib/orbit/v2/task_store.rb
lib/orbit/v2/transaction_log.rb
lib/orbit/v2/validator.rb
lib/orbit/v2/validator/authority_policy.rb
lib/orbit/v2/validator/evidence_evaluation.rb
lib/orbit/v2/validator/findings_lineage.rb
lib/orbit/v2/validator/lead_control.rb
lib/orbit/v2/validator/runtime_lifecycle.rb
lib/orbit/v2/validator/task_work_gate.rb
lib/orbit/v2/work_authority.rb
skills/orbit/SKILL.md
skills/orbit/assets/templates/README.md
skills/orbit/assets/templates/roles.yaml.v1-deprecated
skills/orbit/assets/templates/instances.yaml.v1-deprecated
skills/orbit/assets/templates/loop-state.yaml.v1-deprecated
skills/orbit/assets/templates/task.yaml.v1-deprecated
skills/orbit/assets/templates/evidence.json.v1-deprecated
skills/orbit/assets/templates/review-report.yaml.v1-deprecated
skills/orbit/assets/templates/design-review-report.yaml.v1-deprecated
skills/orbit/assets/templates/test-report.yaml.v1-deprecated
skills/orbit/assets/templates/test-hooks.yaml.v1-deprecated
skills/orbit/references/overview.md
skills/orbit/references/runtime/README.md
skills/orbit/assets/rule-library/MANIFEST.yaml
skills/orbit/assets/rule-library/resident/AGENTS.md.template
skills/orbit/assets/rule-library/shared/escalation-payload.md
skills/orbit/assets/rule-library/reference/report-and-evidence-examples.md
skills/orbit/assets/rule-library/tasks/minimal-implementation.md
skills/orbit/assets/rule-library/tasks/targeted-fix.md
skills/orbit/assets/rule-library/tasks/test-selection.md
skills/orbit/assets/rule-library/tasks/review.md
skills/orbit/assets/rule-library/tasks/vantage-audit.md
skills/orbit/assets/rule-library/tasks/structured-boundary.md
skills/orbit/assets/rule-library/tasks/mutating-surface.md
skills/orbit/assets/rule-library/tasks/quality-outcome.md
"

runtime_file_count() {
  set -- $runtime_files
  printf '%s\n' "$#"
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
  total=$(runtime_file_count)
  current=0
  install_log "copying runtime files from $source_root ($total files)"

  for file in $runtime_files; do
    current=$((current + 1))
    source_file="$source_root/$file"
    target_file="$runtime_dir/$file"
    progress_update "$current" "$total" "copy" "$file"
    [ -f "$source_file" ] || fail "missing runtime source file: $source_file"
    mkdir -p "$(parent_dir "$target_file")"
    copy_file "$source_file" "$target_file"
  done
  progress_done "$total" "copying runtime files"
}

install_remote_runtime() {
  total=$(runtime_file_count)
  current=0
  install_log "downloading Orbit runtime from $raw_base"
  install_log "this can take a minute on slower networks; progress updates in place on terminals"
  for file in $runtime_files; do
    current=$((current + 1))
    target_file="$runtime_dir/$file"
    progress_update "$current" "$total" "download" "$file"
    mkdir -p "$(parent_dir "$target_file")"
    download_file "$raw_base/$file" "$target_file" ||
      fail "failed to download $raw_base/$file"
  done
  progress_done "$total" "downloading runtime files"
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
   [ -f "$script_dir/scripts/orbit" ] &&
   [ -f "$script_dir/skills/orbit/assets/templates/roles.yaml.v1-deprecated" ]; then
  install_log "installing Orbit CLI"
  install_log "mode: $install_mode"
  install_log "wrapper: $target_wrapper"
  install_log "runtime: $runtime_dir"
  install_local_runtime "$script_dir"
else
  install_log "installing Orbit CLI"
  install_log "mode: $install_mode"
  install_log "wrapper: $target_wrapper"
  install_log "runtime: $runtime_dir"
  install_remote_runtime
fi

install_log "writing command wrapper"
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

install_log "verifying installed orbit command"
"$target_wrapper" v2 --help >/dev/null || fail "installed orbit command failed verification"

printf 'Installed orbit to %s\n' "$target_wrapper"
printf 'Runtime files installed to %s\n' "$runtime_dir"
printf 'Install mode: %s\n' "$install_mode"
if [ "$install_mode" = "automatic" ]; then
  printf 'Automatic runtime status: preview until trusted identity proof and provider E2E are available.\n'
else
  printf 'Manual protocol is ready; Herdr is not required.\n'
fi
printf 'Update: rerun this installer.\n'
printf 'Uninstall: sh uninstall.sh --bin-dir %s --runtime-dir %s\n' "$bin_dir" "$runtime_dir"

case ":${PATH:-}:" in
  *":$bin_dir:"*) ;;
  *)
    printf 'Add %s to PATH to run orbit from any shell.\n' "$bin_dir"
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLI="$SKILL_ROOT/scripts/orbit"
TMPROOT=$(mktemp -d)
PASS_COUNT=0
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_CLIENT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %02d %s\n' "$PASS_COUNT" "$1"
}

expect_failure() {
  local name="$1"
  shift

  if "$@"; then
    printf 'FAIL %s: command unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi

  pass "$name"
}

json_assert() {
  local name="$1"
  local file="$2"
  local expr="$3"
  shift 3

  ruby --disable-gems -rjson -e "j=JSON.parse(File.read(ARGV[0])); abort(ARGV[1]) unless (${expr})" "$file" "$name" "$@"
  pass "$name"
}

yaml_assert() {
  local name="$1"
  local file="$2"
  local expr="$3"
  shift 3

  ruby --disable-gems -ryaml -e "j=YAML.safe_load(File.read(ARGV[0]), aliases: true); abort(ARGV[1]) unless (${expr})" "$file" "$name" "$@"
  pass "$name"
}

ruby --disable-gems -c "$CLI"
pass 'script syntax'

test -x "$CLI"
pass 'script executable'

"$SKILL_ROOT/install.sh" --help >"$TMPROOT/install-help.txt" 2>"$TMPROOT/install-help.err"
test ! -s "$TMPROOT/install-help.err"
! grep -qiE -- 'token|github-token|private|Authorization|Bearer|--key' "$TMPROOT/install-help.txt"
pass 'installer help omits private repository token options'

INSTALL_BIN="$TMPROOT/install-bin"
INSTALL_RUNTIME="$TMPROOT/install-runtime"
sh "$SKILL_ROOT/install.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/install.out" 2>"$TMPROOT/install.err"
test ! -s "$TMPROOT/install.err"
test -x "$INSTALL_BIN/orbit"
test -x "$INSTALL_RUNTIME/scripts/orbit"
test -f "$INSTALL_RUNTIME/SKILL.md"
test -f "$INSTALL_RUNTIME/references/runtime/guide.md"
test -f "$INSTALL_RUNTIME/references/runtime/core-operating-model.md"
test -f "$INSTALL_RUNTIME/references/runtime/coding-guideline.md"
test -f "$INSTALL_RUNTIME/references/runtime/quality-outcome-and-review.md"
test -f "$INSTALL_RUNTIME/references/runtime/testing-guideline.md"
test -f "$INSTALL_RUNTIME/assets/templates/review-report.yaml"
test -f "$INSTALL_RUNTIME/assets/templates/design-review-report.yaml"
test -f "$INSTALL_RUNTIME/assets/templates/test-report.yaml"
"$INSTALL_BIN/orbit" version >"$TMPROOT/installed-version.txt"
grep -qx '0.1.0' "$TMPROOT/installed-version.txt"
pass 'installer creates runnable orbit command'

INSTALLED_PROJECT="$TMPROOT/installed-project"
mkdir -p "$INSTALLED_PROJECT"
(cd "$INSTALLED_PROJECT" && "$INSTALL_BIN/orbit" init >/dev/null)
INSTALLED_TASK="$TMPROOT/installed-task.yaml"
(cd "$INSTALLED_PROJECT" && "$INSTALL_BIN/orbit" new-task --target-role lead --task-type implementation --output "$INSTALLED_TASK" >/dev/null)
(cd "$INSTALLED_PROJECT" && ORBIT_INSTANCE=lead "$INSTALL_BIN/orbit" rules print-context --task "$INSTALLED_TASK" --json >"$TMPROOT/installed-rules-context.json")
json_assert 'installed orbit can load packaged default runtime rules' "$TMPROOT/installed-rules-context.json" 'j["valid"] == true && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "SKILL.md" && r["exists"] == true } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "references/runtime/coding-guideline.md" && r["exists"] == true }'

sh "$SKILL_ROOT/install.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/update.out" 2>"$TMPROOT/update.err"
test ! -s "$TMPROOT/update.err"
"$INSTALL_BIN/orbit" version >"$TMPROOT/updated-version.txt"
grep -qx '0.1.0' "$TMPROOT/updated-version.txt"
pass 'installer can be rerun as update'

sh "$SKILL_ROOT/uninstall.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/uninstall.out" 2>"$TMPROOT/uninstall.err"
test ! -s "$TMPROOT/uninstall.err"
test ! -e "$INSTALL_BIN/orbit"
test ! -d "$INSTALL_RUNTIME"
pass 'uninstaller removes orbit wrapper and runtime'

mkdir -p "$INSTALL_BIN" "$INSTALL_RUNTIME"
printf '%s\n' '#!/usr/bin/env sh' 'exit 0' >"$INSTALL_BIN/orbit"
chmod 0755 "$INSTALL_BIN/orbit"
sh "$SKILL_ROOT/uninstall.sh" --bin-dir "$INSTALL_BIN" --runtime-dir "$INSTALL_RUNTIME" >"$TMPROOT/uninstall-skip.out" 2>"$TMPROOT/uninstall-skip.err"
test -f "$INSTALL_BIN/orbit"
grep -q 'Skipped wrapper not created by Orbit installer' "$TMPROOT/uninstall-skip.err"
test ! -d "$INSTALL_RUNTIME"
pass 'uninstaller preserves unrelated orbit wrapper'

INSTALL_CWD_BIN="$TMPROOT/install-cwd-bin"
INSTALL_CWD_RUNTIME="$TMPROOT/install-cwd-runtime"
(cd "$SKILL_ROOT" && sh install.sh --bin-dir "$INSTALL_CWD_BIN" --runtime-dir "$INSTALL_CWD_RUNTIME" >"$TMPROOT/install-cwd.out" 2>"$TMPROOT/install-cwd.err")
test ! -s "$TMPROOT/install-cwd.err"
"$INSTALL_CWD_BIN/orbit" version >"$TMPROOT/install-cwd-version.txt"
grep -qx '0.1.0' "$TMPROOT/install-cwd-version.txt"
pass 'installer detects local skill when run as sh install.sh from skill directory'

"$CLI" --help >"$TMPROOT/help.txt" 2>"$TMPROOT/help.err"
test ! -s "$TMPROOT/help.err"
grep -q 'orbit validate' "$TMPROOT/help.txt"
grep -q 'orbit evidence add' "$TMPROOT/help.txt"
grep -q 'orbit evidence submit' "$TMPROOT/help.txt"
grep -q 'orbit evidence waive' "$TMPROOT/help.txt"
grep -q 'orbit evidence attach-rule' "$TMPROOT/help.txt"
grep -q 'orbit classify-intent --text TEXT --json' "$TMPROOT/help.txt"
grep -q 'orbit compact-evidence --task PATH --evidence PATH' "$TMPROOT/help.txt"
grep -q 'orbit docs alias --id ID --path PATH' "$TMPROOT/help.txt"
grep -q 'orbit audit' "$TMPROOT/help.txt"
grep -q 'orbit dispatch' "$TMPROOT/help.txt"
grep -q 'orbit handoff' "$TMPROOT/help.txt"
grep -Fq 'orbit dispatch --task PATH --to INSTANCE [--transport generic|herdr] [--pane PANE] [--reply-to PANE] [--dry-run] --json' "$TMPROOT/help.txt"
grep -Fq 'orbit handoff --task PATH --state PATH --evidence PATH [--transport NAME] [--output PATH] [--record-state] --json' "$TMPROOT/help.txt"
grep -Fq 'orbit rules print-context --json [--task PATH] [--role ROLE] [--instance NAME] [--output PATH]' "$TMPROOT/help.txt"
grep -q 'orbit start INSTANCE' "$TMPROOT/help.txt"
grep -q 'orbit state progress' "$TMPROOT/help.txt"
grep -q 'orbit state start' "$TMPROOT/help.txt"
grep -q 'orbit state transition' "$TMPROOT/help.txt"
grep -q 'orbit state show --json' "$TMPROOT/help.txt"
grep -q 'orbit tools detect --json' "$TMPROOT/help.txt"
grep -q 'orbit wait-gate --task PATH --evidence PATH --json' "$TMPROOT/help.txt"
pass 'help lists implemented commands without stderr'

"$CLI" audit --help >"$TMPROOT/audit-help.txt" 2>"$TMPROOT/audit-help.err"
test ! -s "$TMPROOT/audit-help.err"
grep -q 'orbit audit --task PATH --state PATH --evidence PATH --json' "$TMPROOT/audit-help.txt"
grep -q 'not an evidence directory' "$TMPROOT/audit-help.txt"
pass 'audit subcommand help works'

"$CLI" dispatch --help >"$TMPROOT/dispatch-help.txt" 2>"$TMPROOT/dispatch-help.err"
test ! -s "$TMPROOT/dispatch-help.err"
grep -Fq 'orbit dispatch --task PATH --to INSTANCE [--transport generic|herdr] [--pane PANE] [--reply-to PANE] [--dry-run] --json' "$TMPROOT/dispatch-help.txt"
grep -q 'wait-gate' "$TMPROOT/dispatch-help.txt"
grep -q 'sends text to an existing agent pane' "$TMPROOT/dispatch-help.txt"
pass 'dispatch subcommand help works'

"$CLI" classify-intent --help >"$TMPROOT/classify-intent-help.txt" 2>"$TMPROOT/classify-intent-help.err"
test ! -s "$TMPROOT/classify-intent-help.err"
grep -Fq 'orbit classify-intent --text TEXT --json' "$TMPROOT/classify-intent-help.txt"
grep -q 'workflow intent' "$TMPROOT/classify-intent-help.txt"
pass 'classify-intent subcommand help works'

"$CLI" compact-evidence --help >"$TMPROOT/compact-evidence-help.txt" 2>"$TMPROOT/compact-evidence-help.err"
test ! -s "$TMPROOT/compact-evidence-help.err"
grep -Fq 'orbit compact-evidence --task PATH --evidence PATH [--handoff PATH] [--output PATH] --json' "$TMPROOT/compact-evidence-help.txt"
grep -q 'durable evidence summary' "$TMPROOT/compact-evidence-help.txt"
pass 'compact-evidence subcommand help works'

"$CLI" docs --help >"$TMPROOT/docs-help.txt" 2>"$TMPROOT/docs-help.err"
test ! -s "$TMPROOT/docs-help.err"
grep -Fq 'orbit docs alias --id ID --path PATH [--registry PATH] --json' "$TMPROOT/docs-help.txt"
grep -Fq 'orbit docs check [--registry PATH] [--open-dir PATH] [--archive-dir PATH] --json' "$TMPROOT/docs-help.txt"
pass 'docs subcommand help works'

"$CLI" handoff --help >"$TMPROOT/handoff-help.txt" 2>"$TMPROOT/handoff-help.err"
test ! -s "$TMPROOT/handoff-help.err"
grep -Fq 'orbit handoff --task PATH --state PATH --evidence PATH [--transport NAME] [--output PATH] [--record-state] --json' "$TMPROOT/handoff-help.txt"
grep -q 'not an evidence directory' "$TMPROOT/handoff-help.txt"
pass 'handoff subcommand help works'

"$CLI" validate --help >"$TMPROOT/validate-help.txt" 2>"$TMPROOT/validate-help.err"
test ! -s "$TMPROOT/validate-help.err"
grep -Fq 'orbit validate [--task PATH] [--evidence PATH] [--state PATH] [--json]' "$TMPROOT/validate-help.txt"
grep -q 'not an evidence directory' "$TMPROOT/validate-help.txt"
pass 'validate subcommand help works'

"$CLI" rules resolve --help >"$TMPROOT/rules-resolve-help.txt" 2>"$TMPROOT/rules-resolve-help.err"
test ! -s "$TMPROOT/rules-resolve-help.err"
grep -Fq 'orbit rules resolve --json [--task PATH] [--role ROLE] [--instance NAME] [--output PATH]' "$TMPROOT/rules-resolve-help.txt"
grep -q 'deterministic code' "$TMPROOT/rules-resolve-help.txt"
pass 'rules resolve subcommand help works'

"$CLI" rules print-context --help >"$TMPROOT/rules-print-context-help.txt" 2>"$TMPROOT/rules-print-context-help.err"
test ! -s "$TMPROOT/rules-print-context-help.err"
grep -Fq 'orbit rules print-context --json [--task PATH] [--role ROLE] [--instance NAME] [--output PATH]' "$TMPROOT/rules-print-context-help.txt"
grep -q 'Project rules are additive' "$TMPROOT/rules-print-context-help.txt"
pass 'rules print-context subcommand help works'

"$CLI" classify-intent --text "先讨论一下这个方案怎么看" --json >"$TMPROOT/intent-discussion.json"
json_assert 'classify-intent keeps discussion orbit-aware without formal task' "$TMPROOT/intent-discussion.json" 'j["intent"] == "discussion" && j["policy"]["formal_task"] == false && j["policy"]["skip_task_reason_required"] == true'
"$CLI" classify-intent --text "Orbit 是什么？先解释一下，不要开任务" --json >"$TMPROOT/intent-orbit-question.json"
json_assert 'classify-intent does not formalize plain Orbit discussion' "$TMPROOT/intent-orbit-question.json" 'j["intent"] == "discussion" && j["explicit_orbit_workflow"] == false && j["policy"]["formal_task"] == false && j["policy"]["skip_task_reason_required"] == true'
"$CLI" classify-intent --text "按 Orbit 流程继续实现这个功能" --json >"$TMPROOT/intent-orbit-coding.json"
json_assert 'classify-intent explicit Orbit workflow requires formal task' "$TMPROOT/intent-orbit-coding.json" 'j["explicit_orbit_workflow"] == true && j["intent"] == "coding" && j["policy"]["formal_task"] == true && j["policy"]["evidence"] == true && j["policy"]["gates"] == true'
"$CLI" classify-intent --text "整理文档并更新 .orbit evidence 历史路径" --json >"$TMPROOT/intent-docs-orbit.json"
json_assert 'classify-intent docs maintenance touching orbit evidence requires task' "$TMPROOT/intent-docs-orbit.json" 'j["intent"] == "docs_maintenance" && j["policy"]["formal_task"] == true && j["policy"]["evidence"] == true && j["policy"]["gates"] == true'
"$CLI" classify-intent --text "review 这个变更" --json >"$TMPROOT/intent-review.json"
json_assert 'classify-intent review emits review policy' "$TMPROOT/intent-review.json" 'j["intent"] == "review" && j["policy"]["default_task_type"] == "review" && j["policy"]["evidence"] == true'

"$CLI" start --help >"$TMPROOT/start-help.txt" 2>"$TMPROOT/start-help.err"
test ! -s "$TMPROOT/start-help.err"
grep -Fq 'orbit start INSTANCE [--transport local|herdr] [--cwd PATH] [--allow-create] [--dry-run] [--json]' "$TMPROOT/start-help.txt"
grep -q 'not through a shell string' "$TMPROOT/start-help.txt"
pass 'start subcommand help works'

"$CLI" wait-gate --help >"$TMPROOT/wait-gate-help.txt" 2>"$TMPROOT/wait-gate-help.err"
test ! -s "$TMPROOT/wait-gate-help.err"
grep -Fq 'orbit wait-gate --task PATH --evidence PATH --json' "$TMPROOT/wait-gate-help.txt"
grep -q 'does not replace reviewer/tester judgment' "$TMPROOT/wait-gate-help.txt"
pass 'wait-gate subcommand help works'

"$CLI" version >"$TMPROOT/version.txt"
grep -qx '0.1.0' "$TMPROOT/version.txt"
pass 'version outputs 0.1.0'

PROJECT="$TMPROOT/project"
mkdir -p "$PROJECT"
cd "$PROJECT"

"$CLI" init >"$TMPROOT/init.out" 2>"$TMPROOT/init.err"
test ! -s "$TMPROOT/init.err"
test -f .orbit/roles.yaml
test -f .orbit/instances.yaml
test -f .orbit/loop-state.yaml
cmp "$SKILL_ROOT/assets/templates/roles.yaml" .orbit/roles.yaml
cmp "$SKILL_ROOT/assets/templates/instances.yaml" .orbit/instances.yaml
pass 'init creates config from templates'
"$CLI" instances status --json >"$TMPROOT/instances-status.json"
json_assert 'instances status defaults user-managed unbound instances to ask_user_or_bind' "$TMPROOT/instances-status.json" 'j["schema_version"] == "orbit-instances-status-v1" && j["instances"].any? { |i| i["instance"] == "reviewer" && i["management"] == "user_managed" && i["binding_status"] == "unbound" && i["recommended_action"] == "ask_user_or_bind" }'
yaml_assert 'init creates user-managed instance bindings by default' .orbit/instances.yaml 'j["instances"].values.all? { |i| i["management"] == "user_managed" && i["transport"].is_a?(Hash) && i["transport"]["binding"].is_a?(Hash) && i["transport"]["health"].is_a?(Hash) }'
expect_failure 'start blocks unbound user-managed instance by default' "$CLI" start reviewer --dry-run --json
for role in lead reviewer tester; do
  "$CLI" bind-pane --instance "$role" --pane "concurrent-$role" --transport herdr --json >"$TMPROOT/concurrent-bind-$role.json" &
done
wait
yaml_assert 'concurrent bind-pane preserves all instance bindings' .orbit/instances.yaml 'j["instances"]["lead"]["transport"]["binding"]["pane"] == "concurrent-lead" && j["instances"]["reviewer"]["transport"]["binding"]["pane"] == "concurrent-reviewer" && j["instances"]["tester"]["transport"]["binding"]["pane"] == "concurrent-tester"'
"$CLI" bind-pane --instance reviewer --pane pane-reviewer --transport herdr --json >"$TMPROOT/bind-pane-reviewer.json"
json_assert 'bind-pane records reviewer binding and status reuse' "$TMPROOT/bind-pane-reviewer.json" 'j["schema_version"] == "orbit-bind-pane-v1" && j["instance"] == "reviewer" && j["status"]["binding_status"] == "healthy" && j["status"]["recommended_action"] == "reuse" && j["status"]["transport"]["binding"]["pane"] == "pane-reviewer"'
mkdir -p "$TMPROOT/fakebin"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[{"pane_id":"pane-reviewer","agent":"codex","agent_status":"idle"}]}}\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer --dry-run --json >"$TMPROOT/start-reviewer-reuse.json"
json_assert 'start reuses healthy user-managed binding only when agent is detected' "$TMPROOT/start-reviewer-reuse.json" 'j["action"] == "reuse" && j["reuse_probe"]["agent_detected"] == true && j["reuse_probe"]["agent"] == "codex" && j["instance_status"]["recommended_action"] == "reuse" && j["instance_status"]["transport"]["binding"]["pane"] == "pane-reviewer" && j["context_preflight"]["required_files"].any? { |r| r["path"] == "SKILL.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/guide.md" }'
"$CLI" bind-pane --instance reviewer --pane shell-pane --transport herdr --json >"$TMPROOT/bind-pane-reviewer-shell.json"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  "pane read")
    printf 'project %%\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer --dry-run --json >"$TMPROOT/start-reviewer-wake-dry-run.json"
json_assert 'start wakes bound Herdr shell pane in dry-run when no agent is detected' "$TMPROOT/start-reviewer-wake-dry-run.json" 'j["action"] == "wake_dry_run" && j["reuse_probe"]["agent_detected"] == false && j["reuse_probe"]["safe_to_wake"] == true && j["wake_adapter"]["command"][0,4] == ["herdr", "pane", "run", "shell-pane"] && j["wake_adapter"]["command"][4].include?("ORBIT_INSTANCE") && j["wake_adapter"]["command"][4].include?("reviewer") && j["wake_adapter"]["command"][4].include?("ORBIT_ROLE") && j["wake_adapter"]["command"][4].include?("codex")'
"$CLI" bind-pane --instance reviewer --pane busy-pane --transport herdr --json >"$TMPROOT/bind-pane-reviewer-busy.json"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  "pane read")
    printf 'running build\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer --dry-run --json >"$TMPROOT/start-reviewer-needs-attention.json" 2>"$TMPROOT/start-reviewer-needs-attention.err"; then
  printf 'FAIL start stale busy binding: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'start fails closed for bound Herdr pane that is not safe to wake' "$TMPROOT/start-reviewer-needs-attention.json" 'j["action"] == "needs_attention" && j["reuse_probe"]["agent_detected"] == false && j["reuse_probe"]["safe_to_wake"] == false && j["reuse_probe"]["decision"] == "needs_attention"'
"$CLI" init --force >/dev/null
"$CLI" start reviewer --allow-create --dry-run --json >"$TMPROOT/start-reviewer.json"
json_assert 'start dry-run resolves instance command env cwd client and context metadata' "$TMPROOT/start-reviewer.json" 'j["schema_version"] == "orbit-start-plan-v1" && j["action"] == "dry_run" && j["transport"] == "local" && j["instance"] == "reviewer" && j["argv"] == ["codex"] && j["client"]["expected_client"] == "codex" && j["client"]["full_permission"]["known_client"] == true && j["client"]["full_permission"]["configured"] == false && j["env"]["ORBIT_INSTANCE"] == "reviewer" && j["env"]["ORBIT_ROLE"] == "reviewer" && j["cwd"] == Dir.pwd && j["context_preflight"]["required_files"].any? { |r| r["path"] == "SKILL.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/guide.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" }'
"$CLI" start reviewer --allow-create --dry-run >"$TMPROOT/start-reviewer-human.txt" 2>"$TMPROOT/start-reviewer-human.err"
test ! -s "$TMPROOT/start-reviewer-human.err"
grep -q 'Orbit start plan:' "$TMPROOT/start-reviewer-human.txt"
grep -q -- '- instance: reviewer' "$TMPROOT/start-reviewer-human.txt"
grep -q -- '- command: codex' "$TMPROOT/start-reviewer-human.txt"
pass 'start dry-run works without json'
env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_TAB -u HERDR_WORKSPACE_ID -u HERDR_WORKSPACE -u HERDR_SPACE_ID -u HERDR_SPACE "$CLI" start reviewer --transport herdr --allow-create --dry-run --json >"$TMPROOT/start-herdr-dry-run.json"
json_assert 'start herdr dry-run emits adapter plan' "$TMPROOT/start-herdr-dry-run.json" 'j["schema_version"] == "orbit-start-plan-v1" && j["action"] == "dry_run" && j["transport"] == "herdr" && j["adapter"]["schema_version"] == "orbit-herdr-start-v1" && j["adapter"]["command"] == ["herdr", "agent", "start", "reviewer", "--cwd", Dir.pwd, "--split", "right", "--no-focus", "--", "codex"] && j["adapter"]["env"]["ORBIT_INSTANCE"] == "reviewer" && j["adapter"]["ready_wait"]["mode"] == "output_match"'
json_assert 'start herdr dry-run exposes create policy and permission setup' "$TMPROOT/start-herdr-dry-run.json" 'j["creation_policy"]["reuse_first"] == true && j["creation_policy"]["same_level_view"]["strategy"] == "fallback_default_view" && j["creation_policy"]["permission_setup"]["required"] == true && j["creation_policy"]["permission_setup"]["summary"].include?("does not silently bypass")'
env HERDR_PANE_ID=lead-pane HERDR_TAB_ID=lead-tab "$CLI" start reviewer --transport herdr --allow-create --dry-run --json >"$TMPROOT/start-herdr-same-tab-dry-run.json"
json_assert 'start herdr prefers lead same-level tab when available' "$TMPROOT/start-herdr-same-tab-dry-run.json" 'j["creation_policy"]["same_level_view"]["strategy"] == "same_tab" && j["creation_policy"]["same_level_view"]["source_pane"] == "lead-pane" && j["creation_policy"]["same_level_view"]["tab"] == "lead-tab" && j["adapter"]["command"] == ["herdr", "agent", "start", "reviewer", "--cwd", Dir.pwd, "--tab", "lead-tab", "--split", "right", "--no-focus", "--", "codex"]'
mkdir -p "$TMPROOT/fakebin"
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_ARGS:?}"
: "${ORBIT_FAKE_HERDR_ENV:?}"
: "${ORBIT_FAKE_HERDR_CWD:?}"
case "$1 $2" in
  "agent start")
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_ARGS"
    printf '%s/%s\n' "$ORBIT_INSTANCE" "$ORBIT_ROLE" >"$ORBIT_FAKE_HERDR_ENV"
    pwd >"$ORBIT_FAKE_HERDR_CWD"
    printf '{"result":{"agent":{"pane_id":"fake-pane","agent":"codex"}}}\n'
    ;;
  "wait output")
    : "${ORBIT_FAKE_HERDR_WAIT_ARGS:?}"
    printf '%s\n' "$@" >"$ORBIT_FAKE_HERDR_WAIT_ARGS"
    printf 'OpenAI Codex\n'
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
ORBIT_FAKE_HERDR_ARGS="$TMPROOT/fake-herdr-args.txt" ORBIT_FAKE_HERDR_WAIT_ARGS="$TMPROOT/fake-herdr-wait-args.txt" ORBIT_FAKE_HERDR_ENV="$TMPROOT/fake-herdr-env.txt" ORBIT_FAKE_HERDR_CWD="$TMPROOT/fake-herdr-cwd.txt" HERDR_PANE_ID=lead-pane HERDR_TAB_ID=lead-tab PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer --transport herdr --allow-create --json >"$TMPROOT/start-herdr-real.json"
json_assert 'start herdr invokes adapter, returns result, and records actual client' "$TMPROOT/start-herdr-real.json" 'j["action"] == "started" && j["adapter_result"]["success"] == true && j["adapter_result"]["stdout"].include?("fake-pane") && j["adapter_result"]["pane_id"] == "fake-pane" && j["adapter_result"]["ready_wait"]["success"] == true && j["creation_policy"]["same_level_view"]["strategy"] == "same_tab" && j["instance_status_after_start"]["transport"]["binding"]["tab"] == "lead-tab" && j["instance_status_after_start"]["transport"]["health"]["actual_client"] == "codex"'
ruby --disable-gems -e 'expected=["agent","start","reviewer","--cwd",Dir.pwd,"--tab","lead-tab","--split","right","--no-focus","--","codex"]; actual=File.read(ARGV[0]).lines.map(&:chomp); abort(actual.inspect) unless actual == expected' "$TMPROOT/fake-herdr-args.txt"
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); abort(actual.inspect) unless actual[0,3] == ["wait","output","fake-pane"] && actual.include?("--regex") && actual.include?("OpenAI Codex|›")' "$TMPROOT/fake-herdr-wait-args.txt"
grep -qx 'reviewer/reviewer' "$TMPROOT/fake-herdr-env.txt"
grep -qx "$PROJECT" "$TMPROOT/fake-herdr-cwd.txt"
pass 'start herdr passes argv env cwd and waits for codex readiness'
"$CLI" init --force >/dev/null
ORBIT_FAKE_HERDR_ARGS="$TMPROOT/fake-herdr-human-args.txt" ORBIT_FAKE_HERDR_WAIT_ARGS="$TMPROOT/fake-herdr-human-wait-args.txt" ORBIT_FAKE_HERDR_ENV="$TMPROOT/fake-herdr-human-env.txt" ORBIT_FAKE_HERDR_CWD="$TMPROOT/fake-herdr-human-cwd.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer --transport herdr --allow-create >"$TMPROOT/start-herdr-human.txt" 2>"$TMPROOT/start-herdr-human.err"
test ! -s "$TMPROOT/start-herdr-human.err"
grep -q 'Started Orbit instance:' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- instance: reviewer' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- pane: fake-pane' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- ready: pass' "$TMPROOT/start-herdr-human.txt"
pass 'start herdr works without json'
cp .orbit/instances.yaml "$TMPROOT/start-instances.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["command"]="printf;printf"; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'start rejects shell metacharacter command string' "$CLI" start reviewer --allow-create --dry-run --json
cp "$TMPROOT/start-instances.yaml.bak" .orbit/instances.yaml
expect_failure 'start rejects unknown instance' "$CLI" start missing --dry-run --json
yaml_assert 'init creates loop state from template' .orbit/loop-state.yaml 'j["schema_version"] == "orbit-loop-state-v1" && j["project"] == File.basename(Dir.pwd) && j["phase"] == "idle" && j["status"] == "idle" && j["history"].is_a?(Array) && j["budget"].is_a?(Hash) && j["artifacts"].is_a?(Hash)'
yaml_assert 'init leaves project rules empty by default' .orbit/roles.yaml 'j["roles"].values.all? { |role| role["rules"].is_a?(Array) && role["rules"].empty? }'

ruby --disable-gems -e 'File.open(ARGV[0], "a") { |f| f.puts "# local edit" }' .orbit/roles.yaml
expect_failure 'init refuses overwrite' "$CLI" init
ruby --disable-gems -e 'abort unless File.readlines(ARGV[0]).last.include?("# local edit")' .orbit/roles.yaml
pass 'init preserves existing local edit'
"$CLI" init --force >/dev/null
cmp "$SKILL_ROOT/assets/templates/roles.yaml" .orbit/roles.yaml
pass 'init --force overwrites with template'
yaml_assert 'init --force regenerates loop state' .orbit/loop-state.yaml 'j["schema_version"] == "orbit-loop-state-v1" && j["project"] == File.basename(Dir.pwd) && j["phase"] == "idle"'

"$CLI" state show --json >"$TMPROOT/state.json" 2>"$TMPROOT/state.err"
test ! -s "$TMPROOT/state.err"
json_assert 'state show outputs loop state json' "$TMPROOT/state.json" 'j["schema_version"] == "orbit-loop-state-v1" && j["project"] == File.basename(Dir.pwd) && j["phase"] == "idle" && j["history"].is_a?(Array)'
"$CLI" state show --json --state .orbit/loop-state.yaml >"$TMPROOT/state-custom.json"
json_assert 'state show supports explicit state path' "$TMPROOT/state-custom.json" 'j["schema_version"] == "orbit-loop-state-v1"'
expect_failure 'state show requires json' "$CLI" state show
expect_failure 'state show rejects missing state option value' "$CLI" state show --json --state
cp .orbit/loop-state.yaml "$TMPROOT/loop-state.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["budget"]="bad"; File.write(p, YAML.dump(y))' .orbit/loop-state.yaml
expect_failure 'state show fails invalid optional budget' "$CLI" state show --json
cp "$TMPROOT/loop-state.yaml.bak" .orbit/loop-state.yaml

"$CLI" validate --json >"$TMPROOT/valid-project.json" 2>"$TMPROOT/valid-project.err"
test ! -s "$TMPROOT/valid-project.err"
json_assert 'validate project config passes' "$TMPROOT/valid-project.json" 'j["valid"] == true && j["checked"] == ["project_config"] && j["trust_level"]["mode"] == "audit_only" && j["trust_level"]["known_bypasses"].is_a?(Array) && j["trust_level"]["required_before_done"].is_a?(Array)'
cp .orbit/instances.yaml "$TMPROOT/schema-instances.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["command"]=["codex","--profile","review"]; File.write(p, YAML.dump(y))' .orbit/instances.yaml
"$CLI" validate --json >"$TMPROOT/valid-array-command.json"
json_assert 'validate accepts array instance command' "$TMPROOT/valid-array-command.json" 'j["valid"] == true'
"$CLI" start reviewer --allow-create --dry-run --json >"$TMPROOT/start-array-command.json"
json_assert 'start dry-run preserves array instance command' "$TMPROOT/start-array-command.json" 'j["argv"] == ["codex", "--profile", "review"]'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["command"]=["codex","--dangerously-bypass-approvals-and-sandbox"]; y["instances"]["lead"]["command"]=["claude","--dangerously-skip-permissions"]; y["instances"]["tester"]["command"]=["opencode","run","--interactive","--dangerously-skip-permissions"]; File.write(p, YAML.dump(y))' .orbit/instances.yaml
"$CLI" start reviewer --allow-create --dry-run --json >"$TMPROOT/start-codex-full-permission.json"
"$CLI" start lead --allow-create --dry-run --json >"$TMPROOT/start-claude-full-permission.json"
"$CLI" start tester --allow-create --dry-run --json >"$TMPROOT/start-opencode-full-permission.json"
json_assert 'start dry-run audits codex full-permission flag' "$TMPROOT/start-codex-full-permission.json" 'j["client"]["expected_client"] == "codex" && j["client"]["full_permission"]["configured"] == true && j["client"]["full_permission"]["present_flags"].include?("--dangerously-bypass-approvals-and-sandbox")'
json_assert 'start dry-run audits claude full-permission flag' "$TMPROOT/start-claude-full-permission.json" 'j["client"]["expected_client"] == "claude" && j["client"]["full_permission"]["configured"] == true && j["client"]["full_permission"]["present_flags"].include?("--dangerously-skip-permissions")'
json_assert 'start dry-run audits opencode full-permission flag' "$TMPROOT/start-opencode-full-permission.json" 'j["client"]["expected_client"] == "opencode" && j["client"]["full_permission"]["configured"] == true && j["client"]["full_permission"]["present_flags"].include?("--dangerously-skip-permissions")'
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["command"]=""; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate rejects empty instance command' "$CLI" validate --json
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["env"]=["bad"]; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate rejects non-mapping instance env' "$CLI" validate --json
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["env"]["ORBIT_ROLE"]=7; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate rejects non-string instance env value' "$CLI" validate --json
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["env"]["ORBIT_INSTANCE"]="other"; y["instances"]["reviewer"]["env"]["ORBIT_ROLE"]="lead"; File.write(p, YAML.dump(y))' .orbit/instances.yaml
"$CLI" validate --json >"$TMPROOT/warn-env-identity.json"
json_assert 'validate warns on instance env identity mismatch' "$TMPROOT/warn-env-identity.json" 'j["valid"] == true && j["warnings"].any? { |w| w["source"] == "project_config.instances.reviewer.env.ORBIT_INSTANCE" } && j["warnings"].any? { |w| w["source"] == "project_config.instances.reviewer.env.ORBIT_ROLE" }'
cp "$TMPROOT/schema-instances.yaml.bak" .orbit/instances.yaml
mkdir -p "$TMPROOT/evidence-dir"
if "$CLI" validate --evidence "$TMPROOT/evidence-dir" --json >"$TMPROOT/validate-evidence-dir.json" 2>"$TMPROOT/validate-evidence-dir.err"; then
  printf 'FAIL validate evidence directory: command unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -s "$TMPROOT/validate-evidence-dir.err"
json_assert 'validate evidence directory reports manifest hint' "$TMPROOT/validate-evidence-dir.json" 'j["valid"] == false && j["errors"].any? { |e| e["source"] == "evidence_file" && e["message"].include?("got directory") && e["message"].include?("orbit evidence init") }'
"$CLI" tools detect --json >"$TMPROOT/tools-detect.json" 2>"$TMPROOT/tools-detect.err"
test ! -s "$TMPROOT/tools-detect.err"
json_assert 'tools detect outputs generic capabilities' "$TMPROOT/tools-detect.json" 'j["schema_version"] == "orbit-tools-v1" && j["detected"].any? { |t| t["name"] == "local_shell" && t["available"] == true } && %w[herdr tmux ci git].all? { |name| j["detected"].any? { |t| t["name"] == name && [true, false].include?(t["available"]) } }'
"$CLI" tools doctor --json >"$TMPROOT/tools-doctor.json" 2>"$TMPROOT/tools-doctor.err"
test ! -s "$TMPROOT/tools-doctor.err"
json_assert 'tools doctor reports audit-only transport health' "$TMPROOT/tools-doctor.json" 'j["schema_version"] == "orbit-tools-doctor-v1" && %w[pass warn].include?(j["health"]) && %w[herdr tmux generic].include?(j["preferred_transport"]) && j["detected"].any? { |t| t["name"] == "local_shell" && t["available"] == true } && j["findings"].is_a?(Array)'
expect_failure 'tools detect requires json' "$CLI" tools detect
expect_failure 'tools rejects missing subcommand' "$CLI" tools

mkdir -p docs/open docs/archive
printf '%s\n' '# Active Design' 'status: active' >docs/open/active.md
printf '%s\n' '# Archive' >docs/archive/README.md
"$CLI" docs alias --id docs.active --path docs/open/active.md --registry "$TMPROOT/docs-registry.json" --json >"$TMPROOT/docs-alias.json"
json_assert 'docs alias writes stable doc registry entry' "$TMPROOT/docs-alias.json" 'j["schema_version"] == "orbit-docs-alias-v1" && j["entry"]["id"] == "docs.active" && j["entry"]["current_path"] == "docs/open/active.md" && j["entry"]["content_hash"].start_with?("sha256:")'
"$CLI" docs check --registry "$TMPROOT/docs-registry.json" --open-dir docs/open --archive-dir docs/archive --json >"$TMPROOT/docs-check-valid.json"
json_assert 'docs check passes valid registry' "$TMPROOT/docs-check-valid.json" 'j["schema_version"] == "orbit-docs-check-v1" && j["valid"] == true && j["aliases"].any? { |a| a["id"] == "docs.active" && a["exists"] == true && a["hash_matches"] == true }'
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["docs"]["docs.active"]["current_path"]="docs/open/missing.md"; j["docs"]["docs.active"]["absolute_path"]=""; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/docs-registry.json"
if "$CLI" docs check --registry "$TMPROOT/docs-registry.json" --open-dir docs/open --archive-dir docs/archive --json >"$TMPROOT/docs-check-missing.json"; then
  printf 'FAIL docs check missing alias: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'docs check fails missing alias target' "$TMPROOT/docs-check-missing.json" 'j["valid"] == false && j["issues"].any? { |i| i["source"] == "docs_registry.docs.active.current_path" }'
printf '%s\n' '# Done Design' 'status: done' >docs/open/done.md
"$CLI" docs alias --id docs.active --path docs/open/active.md --registry "$TMPROOT/docs-registry.json" --json >/dev/null
if "$CLI" docs check --registry "$TMPROOT/docs-registry.json" --open-dir docs/open --archive-dir docs/archive --json >"$TMPROOT/docs-check-closed-open.json"; then
  printf 'FAIL docs check closed open doc: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'docs check reports closed open docs not archived or indexed' "$TMPROOT/docs-check-closed-open.json" 'j["valid"] == false && j["open_docs"].any? { |d| d["path"] == "docs/open/done.md" && d["issue"] == "closed_open_doc_not_archived_or_indexed" }'

NO_CFG="$TMPROOT/no-config"
mkdir -p "$NO_CFG"
cd "$NO_CFG"
expect_failure 'validate fails without project config' "$CLI" validate --json
expect_failure 'state show fails without loop state' "$CLI" state show --json
cd "$PROJECT"

cp .orbit/roles.yaml "$TMPROOT/roles.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("capability_registry"); File.write(p, YAML.dump(y))' .orbit/roles.yaml
expect_failure 'validate fails without capability_registry' "$CLI" validate --json
cp "$TMPROOT/roles.yaml.bak" .orbit/roles.yaml

cp .orbit/instances.yaml "$TMPROOT/instances.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["role_ref"]="missing-role"; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'validate fails on missing role_ref target' "$CLI" validate --json
cp "$TMPROOT/instances.yaml.bak" .orbit/instances.yaml

for role in lead reviewer tester; do
  env ORBIT_INSTANCE="$role" ORBIT_ROLE="$role" "$CLI" whoami --json >"$TMPROOT/whoami-$role.json" 2>"$TMPROOT/whoami-$role.err"
  test ! -s "$TMPROOT/whoami-$role.err"
  json_assert "whoami resolves $role" "$TMPROOT/whoami-$role.json" "j[\"resolved_role\"] == \"$role\" && j[\"instance\"] == \"$role\" && j[\"resolved_instance\"] == \"$role\" && j[\"role_ref\"] == \"$role\" && j[\"expected_command\"] == \"codex\" && j[\"transport_binding\"].is_a?(Hash) && j[\"conflicts\"].empty?"
done
env ORBIT_INSTANCE=reviewer ORBIT_ROLE=reviewer ORBIT_CLIENT=codex "$CLI" whoami --json >"$TMPROOT/whoami-reviewer-client.json"
json_assert 'whoami exposes actual client from env' "$TMPROOT/whoami-reviewer-client.json" 'j["actual_client"] == "codex" && j["binding_status"] == "unbound"'
expect_failure 'whoami fails on actual client mismatch' env ORBIT_INSTANCE=reviewer ORBIT_ROLE=reviewer ORBIT_CLIENT=opencode "$CLI" whoami --json
json_assert 'whoami returns no project rules until user configures them' "$TMPROOT/whoami-reviewer.json" 'j["rules"].is_a?(Array) && j["rules"].empty?'

env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer "$CLI" whoami --json >"$TMPROOT/whoami-reviewer-main.json"
json_assert 'whoami supports reviewer-main alias' "$TMPROOT/whoami-reviewer-main.json" 'j["resolved_role"] == "reviewer" && j["instance"] == "reviewer-main" && j["role_sources"]["project_config.instance_alias"] == "reviewer"'

ORBIT_ROLE=reviewer "$CLI" whoami --json >"$TMPROOT/whoami-role-only.json"
json_assert 'whoami infers unique instance from role' "$TMPROOT/whoami-role-only.json" 'j["resolved_role"] == "reviewer" && j["conflicts"].empty?'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y={"schema_version"=>"orbit-rule-packs-v1","rule_packs"=>{"common"=>["project-common"],"review"=>[{"id"=>"brooks-review","path"=>"references/rule-packs/brooks-review.md"}],"test"=>["brooks-test"],"audit"=>["orbit-drift"]}}; File.write(p, YAML.dump(y))' .orbit/rule-packs.yaml
ORBIT_INSTANCE=reviewer "$CLI" whoami --json >"$TMPROOT/whoami-reviewer-rule-packs.json"
json_assert 'whoami exposes configured review rule packs' "$TMPROOT/whoami-reviewer-rule-packs.json" 'j["rule_packs"].any? { |p| p["category"] == "common" && p["id"] == "project-common" } && j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" && p["path"] == "references/rule-packs/brooks-review.md" }'

expect_failure 'whoami fails on env role conflict' env ORBIT_INSTANCE=reviewer ORBIT_ROLE=lead "$CLI" whoami --json
expect_failure 'whoami fails on unknown instance' env ORBIT_INSTANCE=missing "$CLI" whoami --json
expect_failure 'whoami fails without runtime identity' "$CLI" whoami --json

TASK="$TMPROOT/review-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$TASK" >"$TMPROOT/new-task.out" 2>"$TMPROOT/new-task.err"
test ! -s "$TMPROOT/new-task.err"
yaml_assert 'new-task writes required fields' "$TASK" 'j["schema_version"] == "orbit-task-v1" && j["project"] == File.basename(Dir.pwd) && j["target_role"] == "reviewer" && j["task_type"] == "implementation_review" && %w[quality_outcome scope acceptance evidence_requirements stop_policy].all? { |k| j.key?(k) }'
yaml_assert 'new-task initializes runtime guardrail fields' "$TASK" 'j["source_contract"].is_a?(Hash) && j["traceability"].is_a?(Array) && j["worktree_safety"]["require_status_check"] == true && j["release_surface"].is_a?(Hash) && j["supply_chain"].is_a?(Hash) && j["final_audit"]["required"] == true'
yaml_assert 'new-task initializes non-empty quality outcome template' "$TASK" 'j["quality_outcome"]["user_problem"].is_a?(String) && !j["quality_outcome"]["user_problem"].empty? && j["quality_outcome"]["desired_property"].is_a?(String) && !j["quality_outcome"]["desired_property"].empty? && j["quality_outcome"]["measurable_thresholds"].is_a?(Array) && !j["quality_outcome"]["measurable_thresholds"].empty? && j["quality_outcome"]["invalid_completions"].is_a?(Array) && !j["quality_outcome"]["invalid_completions"].empty?'
yaml_assert 'new-task initializes outcome-first review strategy' "$TASK" 'j["review_strategy"]["entrypoints"].include?("quality_outcome") && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Outcome:") } && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Structure:") } && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Evidence:") }'
yaml_assert 'new-task does not invent project quality rules' "$TASK" 'j["quality_rules"].is_a?(Array) && j["quality_rules"].empty?'
yaml_assert 'new-task exposes configured review rule packs' "$TASK" 'j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }'
for typed in refactor docs performance ux; do
  TYPED_TASK="$TMPROOT/${typed}-task.yaml"
  "$CLI" new-task --target-role lead --task-type "${typed}_improvement" --output "$TYPED_TASK" >/dev/null
  case "$typed" in
    refactor) expected="responsibilities" ;;
    docs) expected="docs" ;;
    performance) expected="baseline" ;;
    ux) expected="user path" ;;
  esac
  yaml_assert "new-task writes ${typed} quality outcome template" "$TYPED_TASK" 'text = j["quality_outcome"].values.flatten.join(" ").downcase; !j["quality_outcome"]["measurable_thresholds"].empty? && text.include?(ARGV[2])' "$expected"
done
PERFORMANCE_TASK="$TMPROOT/performance-measurement-task.yaml"
"$CLI" new-task --target-role lead --task-type performance_improvement --output "$PERFORMANCE_TASK" >/dev/null
yaml_assert 'new-task initializes baseline and after quality measurement contract' "$PERFORMANCE_TASK" 'j["quality_measurement"]["required"] == true && j["quality_measurement"]["baseline_required"] == true && j["quality_measurement"]["after_required"] == true && j["quality_measurement"]["metrics"].is_a?(Array) && !j["quality_measurement"]["metrics"].empty?'
DESIGN_TASK="$TMPROOT/design-task.yaml"
"$CLI" new-task --target-role lead --task-type design --output "$DESIGN_TASK" >/dev/null
yaml_assert 'new-task initializes design lifecycle for design task' "$DESIGN_TASK" 'j["design_lifecycle"]["enabled"] == true && j["design_lifecycle"]["current_phase"] == "drafting" && j["design_lifecycle"]["phases"].include?("coding_ready") && j["design_lifecycle"]["user_confirmation_required"] == true'
CODING_TASK="$TMPROOT/coding-task.yaml"
"$CLI" new-task --target-role lead --task-type coding --output "$CODING_TASK" >/dev/null
yaml_assert 'new-task marks coding tasks as requiring confirmed design' "$CODING_TASK" 'j["design_reference"]["required_for_coding"] == true && j["design_reference"]["status"] == "unconfirmed"'
DECOMP_TASK="$TMPROOT/decomposition-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$DECOMP_TASK" >/dev/null
yaml_assert 'new-task initializes decomposition contract fields' "$DECOMP_TASK" 'j["implementation_plan"]["required"] == true && j["decomposition"]["child_slices"].is_a?(Array) && j["decomposition"]["aggregate_outcome_metrics"].is_a?(Array) && j["final_aggregate_audit"]["required"] == true'
expect_failure 'new-task refuses overwrite' "$CLI" new-task --target-role reviewer --task-type implementation_review --output "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer --json >"$TMPROOT/dispatch-generic.json"
json_assert 'dispatch generic emits manual delivery payload with context preflight' "$TMPROOT/dispatch-generic.json" 'j["schema_version"] == "orbit-dispatch-v1" && j["action"] == "manual_delivery_required" && j["transport"] == "generic" && j["to_instance"] == "reviewer" && j["resolved_role"] == "reviewer" && j["task"] == File.expand_path(ARGV[2]) && j["message"].include?("orbit whoami --json") && !j["message"].include?("orbit whoami --task") && j["message"].include?("orbit rules print-context --task") && j["message"].include?("context_preflight.required_files") && j["context_preflight"]["commands"].include?(["orbit", "whoami", "--json"]) && j["context_preflight"]["required_files"].any? { |r| r["path"] == "SKILL.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/guide.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" } && j["checks"]["target_role_matches"] == true' "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --reply-to observer-pane --dry-run --json >"$TMPROOT/dispatch-herdr-dry-run.json"
json_assert 'dispatch herdr dry-run emits adapter plan with explicit reply-to' "$TMPROOT/dispatch-herdr-dry-run.json" 'j["action"] == "dry_run" && j["reply_to"] == "observer-pane" && j["reply_to_source"] == "explicit_option" && j["message"].include?("reply-to:observer-pane") && j["adapter"]["schema_version"] == "orbit-herdr-dispatch-v1" && j["adapter"]["submit_delay_seconds"] > 0 && j["adapter"]["commands"][0][0,4] == ["herdr", "pane", "send-text", "pane-123"] && j["adapter"]["commands"][0][4].include?(File.expand_path(ARGV[2])) && j["adapter"]["commands"][1] == ["herdr", "pane", "send-keys", "pane-123", "Enter"]' "$TASK"
HERDR_PANE_ID=lead-reply-pane "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --dry-run --json >"$TMPROOT/dispatch-herdr-env-reply-to.json"
json_assert 'dispatch herdr reply-to defaults to current Herdr pane' "$TMPROOT/dispatch-herdr-env-reply-to.json" 'j["reply_to"] == "lead-reply-pane" && j["reply_to_source"] == "HERDR_PANE_ID" && j["message"].include?("reply-to:lead-reply-pane")'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_DISPATCH_ARGS:?}"
printf '%s\n' "$@" >>"$ORBIT_FAKE_HERDR_DISPATCH_ARGS"
printf '%s\n' '---' >>"$ORBIT_FAKE_HERDR_DISPATCH_ARGS"
printf 'sent:%s\n' "$3"
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
ORBIT_FAKE_HERDR_DISPATCH_ARGS="$TMPROOT/fake-herdr-dispatch-args.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --json >"$TMPROOT/dispatch-herdr-real.json"
json_assert 'dispatch herdr sends through adapter' "$TMPROOT/dispatch-herdr-real.json" 'j["action"] == "sent" && j["adapter_result"]["success"] == true && j["adapter_result"]["commands"].length == 2 && j["adapter_result"]["commands"].all? { |c| c["success"] }'
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); first_sep=actual.index("---"); second=actual[(first_sep + 1)..]; second_sep=second.index("---"); first=actual[0...first_sep]; second=second[0...second_sep]; message=first[3..].join("\n"); abort(actual.inspect) unless first[0,3] == ["pane","send-text","pane-123"] && message.include?(File.expand_path(ARGV[1])) && message.include?("kind:request") && second == ["pane","send-keys","pane-123","Enter"]' "$TMPROOT/fake-herdr-dispatch-args.txt" "$TASK"
pass 'dispatch herdr sends message text and enter to adapter'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
printf 'transport denied\n' >&2
exit 42
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --json >"$TMPROOT/dispatch-herdr-fail.json" 2>"$TMPROOT/dispatch-herdr-fail.err"; then
  printf 'FAIL dispatch herdr failure: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'dispatch herdr failure exits with fallback payload' "$TMPROOT/dispatch-herdr-fail.json" 'j["action"] == "failed" && j["adapter_result"]["success"] == false && j["fallback"]["transport"] == "generic" && j["fallback"]["action"] == "manual_delivery_required" && j["fallback"]["message"].include?(File.expand_path(ARGV[2]))' "$TASK"
expect_failure 'dispatch herdr requires pane' "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --json
expect_failure 'dispatch rejects unknown target instance' "$CLI" dispatch --task "$TASK" --to missing --json

mkdir -p docs
printf '%s\n' '# Review Rule' '- Check project-specific review constraints.' >docs/review-rule.md
cp .orbit/roles.yaml "$TMPROOT/roles-before-rules.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["roles"]["reviewer"]["rules"]=["docs/review-rule.md", {"path"=>"docs/review-rule.md", "id"=>"duplicate-review-rule", "relation"=>"supplements"}]; File.write(p, YAML.dump(y))' .orbit/roles.yaml
ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/rules-resolution.json" >"$TMPROOT/rules-resolution.stdout" 2>"$TMPROOT/rules-resolution.err"
test ! -s "$TMPROOT/rules-resolution.err"
cmp "$TMPROOT/rules-resolution.json" "$TMPROOT/rules-resolution.stdout"
json_assert 'rules resolve includes default, project, task, and rule pack sources' "$TMPROOT/rules-resolution.json" 'j["schema_version"] == "orbit-rule-resolution-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["sources"]["orbit_default"].any? { |r| r["path"] == "SKILL.md" && r["id"].is_a?(String) && r["relation"] == "baseline" && r["exists"] == true } && j["sources"]["orbit_default"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" && r["load_policy"] == "required" } && j["sources"]["project_rules"].any? { |r| r["path"] == "docs/review-rule.md" && r["id"].is_a?(String) && r["relation"] == "supplements" && r["exists"] == true } && j["sources"]["project_rules"].any? { |r| r["path"] == "docs/review-rule.md" && r["id"] == "duplicate-review-rule" } && j["sources"]["task_rules"]["path"] == File.expand_path(ARGV[2]) && j["sources"]["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }' "$TASK"
ORBIT_INSTANCE=reviewer "$CLI" rules print-context --task "$TASK" --json --output "$TMPROOT/rules-context.json" >"$TMPROOT/rules-context.stdout" 2>"$TMPROOT/rules-context.err"
test ! -s "$TMPROOT/rules-context.err"
cmp "$TMPROOT/rules-context.json" "$TMPROOT/rules-context.stdout"
json_assert 'rules print-context emits ordered default project task and pack context' "$TMPROOT/rules-context.json" 'j["schema_version"] == "orbit-rules-context-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["load_model"]["default_rules_always_loaded"] == true && j["load_model"]["project_rules_are_additive"] == true && j["load_order"].all? { |r| r["rule_id"].is_a?(String) && r["relation"].is_a?(String) && r["dedupe_status"].is_a?(String) } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "SKILL.md" && r["required"] == true && r["exists"] == true && r["dedupe_status"] == "active" } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "references/runtime/core-operating-model.md" && r["required"] == false } && j["load_order"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" && r["required"] == true && r["exists"] == true && r["dedupe_status"] == "active" } && j["load_order"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" && r["id"] == "duplicate-review-rule" && r["dedupe_status"] == "deduped" } && j["load_order"].any? { |r| r["source"] == "task_rules" && r["path"] == File.expand_path(ARGV[2]) && r["required"] == true } && j["load_order"].any? { |r| r["source"] == "rule_packs" && r["id"] == "brooks-review" && r["required"] == false } && j["required_files"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" } && j["required_files"].select { |r| r["path"] == "docs/review-rule.md" }.length == 1 && j["context_budget"]["deduped"].any? { |r| r["path"] == "docs/review-rule.md" } && j["context_budget"]["shadowed"].is_a?(Array) && j["context_budget"]["not_loaded_but_related"].is_a?(Array) && j["rule_resolution"]["schema_version"] == "orbit-rule-resolution-v1"' "$TASK"
ORBIT_ROLE=reviewer "$CLI" rules resolve --task "$TASK" --json >"$TMPROOT/rules-resolution-role.json"
json_assert 'rules resolve supports role identity' "$TMPROOT/rules-resolution-role.json" 'j["resolved_role"] == "reviewer" && j["valid"] == true'
ORBIT_INSTANCE=tester "$CLI" rules resolve --role reviewer --task "$TASK" --json >"$TMPROOT/rules-resolution-role-override.json"
json_assert 'rules resolve role option overrides ambient instance' "$TMPROOT/rules-resolution-role-override.json" 'j["resolved_role"] == "reviewer" && j["valid"] == true && !j["role_sources"].key?("env.ORBIT_INSTANCE")'
expect_failure 'rules resolve fails on task target mismatch' env ORBIT_INSTANCE=tester "$CLI" rules resolve --task "$TASK" --json
rm docs/review-rule.md
expect_failure 'rules resolve fails on missing project rule file' env ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$TASK" --json
expect_failure 'validate fails on missing configured project rule file' "$CLI" validate --json
cp "$TMPROOT/roles-before-rules.yaml" .orbit/roles.yaml
ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/current-rule-resolution.json" >/dev/null

APPEND_EVIDENCE="$TMPROOT/append-evidence.json"
"$CLI" evidence init --output "$APPEND_EVIDENCE" >"$TMPROOT/evidence-init.out" 2>"$TMPROOT/evidence-init.err"
test ! -s "$TMPROOT/evidence-init.err"
json_assert 'evidence init writes empty manifest' "$APPEND_EVIDENCE" 'j["schema_version"] == "orbit-evidence-v1" && j["project"] == File.basename(Dir.pwd) && j["records"].is_a?(Array) && j["records"].empty?'
json_assert 'evidence init initializes runtime evidence fields' "$APPEND_EVIDENCE" 'j["worktree_safety"]["status"] == "not_applicable" && j["regression_guard"]["status"] == "not_applicable" && j["release_surface"]["status"] == "not_applicable" && j["rule_resolution"]["file"] == "" && j["tool_calls"].is_a?(Array)'
expect_failure 'wait-gate fails before required review evidence' "$CLI" wait-gate --task "$TASK" --evidence "$APPEND_EVIDENCE" --json
expect_failure 'lead cannot submit review evidence' env ORBIT_INSTANCE=lead "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "lead review attempt"
expect_failure 'lead cannot submit test evidence' env ORBIT_INSTANCE=lead "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind test --status pass --summary "lead test attempt"
expect_failure 'client mismatch cannot submit review evidence' env ORBIT_INSTANCE=reviewer ORBIT_ROLE=reviewer ORBIT_CLIENT=opencode "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "client mismatch review attempt"
cat >"$TMPROOT/review-report.md" <<'REPORT'
APPROVED
review report confirms the implementation is acceptable.
REPORT
ORBIT_INSTANCE=reviewer "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-report.md" --json >"$TMPROOT/evidence-from-review-report.json"
json_assert 'evidence from-report imports markdown review verdict' "$TMPROOT/evidence-from-review-report.json" 'j["schema_version"] == "orbit-evidence-import-v1" && j["record"]["kind"] == "review" && j["record"]["status"] == "pass" && j["record"]["source_report"] == File.expand_path(ARGV[2]) && j["record"]["identity"]["resolved_role"] == "reviewer" && j["record"]["identity"]["resolved_instance"] == "reviewer"' "$TMPROOT/review-report.md"
printf '%s\n' 'APPROVED_WITH_NOTES' 'notes are not an automatic pass token.' >"$TMPROOT/review-with-notes-report.md"
expect_failure 'evidence from-report rejects non-contract verdict token' "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-with-notes-report.md" --json
"$CLI" wait-gate --task "$TASK" --evidence "$APPEND_EVIDENCE" --json >"$TMPROOT/wait-gate-review-pass.json"
json_assert 'wait-gate passes after imported review evidence' "$TMPROOT/wait-gate-review-pass.json" 'j["schema_version"] == "orbit-gate-status-v1" && j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true }'
json_assert 'wait-gate exposes aggregate verdict' "$TMPROOT/wait-gate-review-pass.json" 'j["aggregate_verdict"].is_a?(Hash) && j["aggregate_verdict"]["mode"] == "aggregate"'

STRUCTURED_REVIEW_EVIDENCE="$TMPROOT/structured-review-evidence.json"
"$CLI" evidence init --output "$STRUCTURED_REVIEW_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review.yaml" <<'YAML'
kind: review
verdict: pass
summary: Structured reviewer verdict passed.
source_message_id: herdr:reviewer:structured-pass
quality_outcome_verdict: pass
quality_outcome_reasoning: Outcome and acceptance evidence were checked.
findings: []
coverage:
  - review checked aggregate verdict behavior
artifacts:
  - tests/orbit_test.sh
YAML
expect_failure 'lead cannot structured submit review evidence' env ORBIT_INSTANCE=lead "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --json
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --json >"$TMPROOT/evidence-submit-review.json"
json_assert 'evidence submit records structured review verdict' "$TMPROOT/evidence-submit-review.json" 'j["schema_version"] == "orbit-evidence-submit-v1" && j["record"]["structured_submit"] == true && j["record"]["source_message_id"] == "herdr:reviewer:structured-pass" && j["record"]["coverage"].include?("review checked aggregate verdict behavior") && j["verdict"]["mode"] == "aggregate" && j["verdict"]["gates"]["review"]["structured"] == true'
cat >"$TMPROOT/review-missing-quality-outcome.yaml" <<'YAML'
kind: review
verdict: pass
summary: Missing quality outcome verdict.
source_message_id: herdr:reviewer:missing-qo
findings: []
coverage:
  - review checked behavior
artifacts:
  - tests/orbit_test.sh
YAML
expect_failure 'evidence submit rejects review pass without quality_outcome_verdict' env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-missing-quality-outcome.yaml" --json
cat >"$TMPROOT/review-high-finding-incomplete.yaml" <<'YAML'
kind: review
verdict: fail
summary: High finding lacks required detail.
source_message_id: herdr:reviewer:high-incomplete
quality_outcome_verdict: fail
quality_outcome_reasoning: A high severity issue remains.
findings:
  - severity: high
    summary: Missing required detail.
coverage:
  - review checked finding schema
artifacts:
  - tests/orbit_test.sh
YAML
expect_failure 'evidence submit rejects high finding missing remedy fields' env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-high-finding-incomplete.yaml" --json
cat >"$TMPROOT/malformed-structured-review.yaml" <<'YAML'
kind: review
verdict: pass
summary: Malformed structured reviewer verdict.
source_message_id: herdr:reviewer:malformed
quality_outcome_verdict: pass
quality_outcome_reasoning: Outcome checked before schema validation.
findings: []
coverage:
  - name: malformed coverage object
artifacts:
  - tests/orbit_test.sh
YAML
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/structured-review-before-malformed.json"
if env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/malformed-structured-review.yaml" --json >"$TMPROOT/malformed-submit.out" 2>"$TMPROOT/malformed-submit.err"; then
  printf 'FAIL evidence submit rejects malformed coverage entries before gate: command unexpectedly succeeded\n' >&2
  exit 1
fi
cmp "$TMPROOT/structured-review-before-malformed.json" "$STRUCTURED_REVIEW_EVIDENCE"
grep -q 'field: submit_report.coverage' "$TMPROOT/malformed-submit.err"
grep -q 'expected: list of non-empty strings' "$TMPROOT/malformed-submit.err"
grep -q 'actual: array<mapping>' "$TMPROOT/malformed-submit.err"
grep -q 'template: assets/templates/review-report.yaml' "$TMPROOT/malformed-submit.err"
pass 'evidence submit rejects malformed coverage entries before gate'
"$CLI" wait-gate --task "$TASK" --evidence "$STRUCTURED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-structured-review-pass.json"
json_assert 'wait-gate passes after structured review submit' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true && g["structured"] == true }'
json_assert 'wait-gate exposes role-authorized gate summary' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["gate_summary"]["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["identity_expected_role"] == "reviewer" && g["identity_resolved_role"] == "reviewer" && g["identity_valid"] == true }'

IDENTITY_MISMATCH_EVIDENCE="$TMPROOT/identity-mismatch-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$IDENTITY_MISMATCH_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["identity"]["resolved_role"]="lead"; File.write(p, JSON.pretty_generate(j))' "$IDENTITY_MISMATCH_EVIDENCE"
if "$CLI" wait-gate --task "$TASK" --evidence "$IDENTITY_MISMATCH_EVIDENCE" --json >"$TMPROOT/wait-gate-identity-mismatch.json" 2>"$TMPROOT/wait-gate-identity-mismatch.err"; then
  printf 'FAIL wait-gate rejects identity-mismatched structured review evidence: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects identity-mismatched structured review evidence'
json_assert 'wait-gate reports identity mismatch blocker' "$TMPROOT/wait-gate-identity-mismatch.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "identity_mismatch" } && j["gates"].any? { |g| g["kind"] == "review" && g["identity_resolved_role"] == "lead" && g["identity_valid"] == false }'
expect_failure 'validate rejects identity-mismatched structured review evidence' "$CLI" validate --task "$TASK" --evidence "$IDENTITY_MISMATCH_EVIDENCE" --json
MISSING_IDENTITY_EVIDENCE="$TMPROOT/missing-identity-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$MISSING_IDENTITY_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last.delete("identity"); File.write(p, JSON.pretty_generate(j))' "$MISSING_IDENTITY_EVIDENCE"
if "$CLI" wait-gate --task "$TASK" --evidence "$MISSING_IDENTITY_EVIDENCE" --json >"$TMPROOT/wait-gate-missing-identity.json" 2>"$TMPROOT/wait-gate-missing-identity.err"; then
  printf 'FAIL wait-gate rejects hand-written structured review without identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects hand-written structured review without identity'
json_assert 'wait-gate reports missing identity as mismatch blocker' "$TMPROOT/wait-gate-missing-identity.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "identity_mismatch" } && j["gates"].any? { |g| g["kind"] == "review" && g["identity_resolved_role"].nil? && g["identity_valid"] == false }'
MISSING_QO_EVIDENCE="$TMPROOT/missing-quality-outcome-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$MISSING_QO_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last.delete("quality_outcome_verdict"); File.write(p, JSON.pretty_generate(j))' "$MISSING_QO_EVIDENCE"
expect_failure 'validate rejects hand-written structured review without quality_outcome_verdict' "$CLI" validate --task "$TASK" --evidence "$MISSING_QO_EVIDENCE" --json

BLOCKED_REVIEW_EVIDENCE="$TMPROOT/blocked-review-evidence.json"
"$CLI" evidence init --output "$BLOCKED_REVIEW_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review-blocked.yaml" <<'YAML'
kind: review
verdict: blocked
summary: Structured reviewer verdict is blocked on missing acceptance criteria.
source_message_id: herdr:reviewer:structured-blocked
quality_outcome_verdict: blocked
quality_outcome_reasoning: Acceptance criteria are ambiguous, so the outcome cannot be verified.
findings:
  - acceptance criteria are still ambiguous
coverage:
  - review checked task contract and evidence contract
artifacts:
  - review transcript
blocked:
  reason: acceptance criteria are ambiguous
  next_step: lead must clarify pass criteria before implementation can close
  owner: lead
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$BLOCKED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review-blocked.yaml" --json >"$TMPROOT/evidence-submit-blocked-review.json"
json_assert 'evidence submit records blocked detail as partial verdict' "$TMPROOT/evidence-submit-blocked-review.json" 'j["record"]["status"] == "partial" && j["record"]["blocked"]["reason"] == "acceptance criteria are ambiguous" && j["verdict"]["gates"]["review"]["blocked"]["owner"] == "lead"'
if "$CLI" wait-gate --task "$TASK" --evidence "$BLOCKED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-blocked-review.json" 2>"$TMPROOT/wait-gate-blocked-review.err"; then
  printf 'FAIL wait-gate reports blocked structured review evidence: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate reports blocked structured review evidence'
json_assert 'wait-gate includes blocked detail in gate status' "$TMPROOT/wait-gate-blocked-review.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["status"] == "blocked" && g["record_status"] == "partial" && g["blocked"]["owner"] == "lead" } && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["status"] == "blocked" }'
TEMPLATE_REVIEW_EVIDENCE="$TMPROOT/template-review-evidence.json"
"$CLI" evidence init --output "$TEMPLATE_REVIEW_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$TEMPLATE_REVIEW_EVIDENCE" --report "$SKILL_ROOT/assets/templates/review-report.yaml" --json >"$TMPROOT/template-review-submit.json"
json_assert 'review report template is directly submittable as blocked evidence' "$TMPROOT/template-review-submit.json" 'j["record"]["kind"] == "review" && j["record"]["status"] == "partial" && j["record"]["blocked"]["owner"] == "lead" && j["record"]["findings"].all? { |f| f.is_a?(String) }'

AGGREGATE_EVIDENCE="$TMPROOT/aggregate-evidence.json"
"$CLI" evidence init --output "$AGGREGATE_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review-fail.yaml" <<'YAML'
kind: review
verdict: fail
summary: Structured reviewer verdict failed.
source_message_id: herdr:reviewer:structured-fail
quality_outcome_verdict: fail
quality_outcome_reasoning: Blocking review finding remains.
findings:
  - blocking finding retained
coverage:
  - review checked failure path
artifacts:
  - review transcript
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$AGGREGATE_EVIDENCE" --report "$TMPROOT/structured-review-fail.yaml" --json >/dev/null
"$CLI" evidence add --file "$AGGREGATE_EVIDENCE" --kind command --status pass --summary "later command pass must not mask review fail" >/dev/null
json_assert 'aggregate verdict is not overwritten by latest command pass' "$AGGREGATE_EVIDENCE" 'j["verdict"]["mode"] == "aggregate" && j["verdict"]["status"] == "fail" && j["verdict"]["latest_record"]["kind"] == "command" && j["verdict"]["gates"]["review"]["status"] == "fail"'

WAIVER_EVIDENCE="$TMPROOT/waiver-evidence.json"
"$CLI" evidence init --output "$WAIVER_EVIDENCE" >/dev/null
cat >"$TMPROOT/invalid-waiver.yaml" <<'YAML'
owner: lead
scope: browser e2e
reason: missing risk fields
YAML
expect_failure 'evidence waive rejects incomplete waiver schema' "$CLI" evidence waive --file "$WAIVER_EVIDENCE" --waiver "$TMPROOT/invalid-waiver.yaml" --json
cat >"$TMPROOT/valid-waiver.yaml" <<'YAML'
owner: lead
scope: browser e2e
reason: CLI schema-only slice
risk: Browser runtime behavior is not proven by this slice.
replacement_evidence: tests/orbit_test.sh covers CLI behavior.
expiry: P2-S7
revoked_by_user_requirement: false
YAML
"$CLI" evidence waive --file "$WAIVER_EVIDENCE" --waiver "$TMPROOT/valid-waiver.yaml" --json >"$TMPROOT/evidence-waive.json"
json_assert 'evidence waive records structured waiver and aggregate risk' "$TMPROOT/evidence-waive.json" 'j["schema_version"] == "orbit-evidence-waiver-v1" && j["waiver"]["owner"] == "lead" && j["waiver"]["risk"].include?("Browser runtime") && j["verdict"]["mode"] == "aggregate" && j["verdict"]["status"] == "partial" && j["verdict"]["waivers"]["open"] == 1'
"$CLI" validate --evidence "$WAIVER_EVIDENCE" --json >"$TMPROOT/valid-waiver-evidence.json"
json_assert 'validate accepts structured waiver schema' "$TMPROOT/valid-waiver-evidence.json" 'j["valid"] == true'
TEST_TASK="$TMPROOT/test-task.yaml"
"$CLI" new-task --target-role tester --task-type implementation_test --output "$TEST_TASK" >/dev/null
yaml_assert 'new-task initializes test environment contract' "$TEST_TASK" 'j["test_environment"]["required"] == true && %w[environment test_tab_or_pane server_owner browser_owner cleanup_hook artifact_cleanup duration_budget resource_budget].all? { |k| j["test_environment"][k].is_a?(String) && !j["test_environment"][k].empty? }'
yaml_assert 'new-task initializes test level contract' "$TEST_TASK" 'j["test_level"] == "repo_regression"'
TEST_EVIDENCE="$TMPROOT/test-evidence.json"
"$CLI" evidence init --output "$TEST_EVIDENCE" >/dev/null
TEMPLATE_TEST_EVIDENCE="$TMPROOT/template-test-evidence.json"
"$CLI" evidence init --output "$TEMPLATE_TEST_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$TEMPLATE_TEST_EVIDENCE" --report "$SKILL_ROOT/assets/templates/test-report.yaml" --json >"$TMPROOT/template-test-submit.json"
json_assert 'test report template is directly submittable as blocked evidence' "$TMPROOT/template-test-submit.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "partial" && j["record"]["blocked"]["owner"] == "lead" && j["record"]["test_environment"]["cleanup_status"].is_a?(String)'
cat >"$TMPROOT/test-report.yaml" <<'REPORT'
kind: test
status: PASS
summary: Browser scenarios passed.
REPORT
ORBIT_INSTANCE=tester "$CLI" evidence from-report --file "$TEST_EVIDENCE" --report "$TMPROOT/test-report.yaml" --json >"$TMPROOT/evidence-from-test-report.json"
json_assert 'evidence from-report imports structured test verdict' "$TMPROOT/evidence-from-test-report.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "pass" && j["record"]["summary"] == "Browser scenarios passed."'
"$CLI" wait-gate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json >"$TMPROOT/wait-gate-test-pass.json"
json_assert 'wait-gate passes after imported test evidence' "$TMPROOT/wait-gate-test-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "test" && g["passed"] == true }'
expect_failure 'validate rejects passing test evidence without environment contract evidence' "$CLI" validate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json
cat >"$TMPROOT/complete-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Structured test evidence includes environment lifecycle.
source_message_id: herdr:tester:complete-test-env
test_level: repo_regression
findings: []
coverage:
  - test exercised success path and cleanup path
artifacts:
  - .orbit/test-artifacts/complete-test-env.log
test_environment:
  environment: local shell
  test_tab_or_pane: current pane
  server_owner: none
  browser_owner: none
  cleanup_hook: trap removed temp directory
  artifact_cleanup: retained compact log only
  duration: 1s
  resource_usage: one shell process
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: artifact path is stable and small
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$TEST_EVIDENCE" --report "$TMPROOT/complete-test-submit.yaml" --json >"$TMPROOT/complete-test-submit.json"
"$CLI" validate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json >"$TMPROOT/valid-complete-test-env.json"
json_assert 'validate accepts passing test evidence with environment lifecycle' "$TMPROOT/valid-complete-test-env.json" 'j["valid"] == true'
cp "$TEST_EVIDENCE" "$TMPROOT/missing-test-level-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last.delete("test_level"); File.write(p, JSON.pretty_generate(j))' "$TMPROOT/missing-test-level-evidence.json"
expect_failure 'validate rejects passing test evidence without test_level' "$CLI" validate --task "$TEST_TASK" --evidence "$TMPROOT/missing-test-level-evidence.json" --json
cp "$TEST_EVIDENCE" "$TMPROOT/mismatched-test-level-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["test_level"]="manual"; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/mismatched-test-level-evidence.json"
expect_failure 'validate rejects passing test evidence overclaiming test_level' "$CLI" validate --task "$TEST_TASK" --evidence "$TMPROOT/mismatched-test-level-evidence.json" --json
OPTIONAL_GATE_TASK="$TMPROOT/optional-gate-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$OPTIONAL_GATE_TASK" >/dev/null
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"].each { |g| g["required"]=false if g["kind"]=="test" }; File.write(p, YAML.dump(y))' "$OPTIONAL_GATE_TASK"
OPTIONAL_GATE_EVIDENCE="$TMPROOT/optional-gate-evidence.json"
"$CLI" evidence init --output "$OPTIONAL_GATE_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$OPTIONAL_GATE_EVIDENCE" --kind review --status pass --summary "required review passed" >/dev/null
"$CLI" wait-gate --task "$OPTIONAL_GATE_TASK" --evidence "$OPTIONAL_GATE_EVIDENCE" --json >"$TMPROOT/wait-gate-optional-pass.json"
json_assert 'wait-gate ignores optional gates' "$TMPROOT/wait-gate-optional-pass.json" 'j["ready"] == true && j["gates"].map { |g| g["kind"] } == ["review"]'
expect_failure 'evidence init refuses overwrite' "$CLI" evidence init --output "$APPEND_EVIDENCE"
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "review passed" >"$TMPROOT/evidence-add-review.out" 2>"$TMPROOT/evidence-add-review.err"
test ! -s "$TMPROOT/evidence-add-review.err"
"$CLI" evidence show --file "$APPEND_EVIDENCE" --json >"$TMPROOT/evidence-show.json" 2>"$TMPROOT/evidence-show.err"
test ! -s "$TMPROOT/evidence-show.err"
json_assert 'evidence add appends review record' "$TMPROOT/evidence-show.json" 'j["records"].length >= 2 && j["records"].last["kind"] == "review" && j["records"].last["status"] == "pass" && j["records"].last["summary"] == "review passed" && j["records"].last["created_at"].is_a?(String)'
"$CLI" evidence add --file "$APPEND_EVIDENCE" --kind command --status partial --summary "command evidence retained" >/dev/null
json_assert 'evidence add preserves history' "$APPEND_EVIDENCE" 'j["records"].length >= 3 && j["records"][-2]["kind"] == "review" && j["records"][-1]["kind"] == "command"'
expect_failure 'evidence add rejects invalid status' env ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status maybe --summary "bad status"
expect_failure 'evidence add rejects empty summary' env ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary ""
"$CLI" validate --task "$TASK" --evidence "$APPEND_EVIDENCE" --json >"$TMPROOT/valid-append-evidence.json"
json_assert 'validate reads appended review evidence' "$TMPROOT/valid-append-evidence.json" 'j["valid"] == true && j["checked"].include?("evidence")'
BAD_RELEASE_STATUS_EVIDENCE="$TMPROOT/bad-release-status-evidence.json"
cp "$APPEND_EVIDENCE" "$BAD_RELEASE_STATUS_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["release_surface"]={"status"=>"not_git","checked"=>[],"gaps"=>[]}; File.write(p, JSON.pretty_generate(j))' "$BAD_RELEASE_STATUS_EVIDENCE"
expect_failure 'validate rejects not_git outside worktree safety release surface' "$CLI" validate --evidence "$BAD_RELEASE_STATUS_EVIDENCE" --json
BAD_TOOL_STATUS_EVIDENCE="$TMPROOT/bad-tool-status-evidence.json"
cp "$APPEND_EVIDENCE" "$BAD_TOOL_STATUS_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["tool_calls"]=[{"tool_name"=>"git status","status"=>"not_git","used_for"=>"status check"}]; File.write(p, JSON.pretty_generate(j))' "$BAD_TOOL_STATUS_EVIDENCE"
expect_failure 'validate rejects not_git outside worktree safety tool calls' "$CLI" validate --evidence "$BAD_TOOL_STATUS_EVIDENCE" --json

LEGACY_TASK="$TMPROOT/legacy-task.yaml"
ruby --disable-gems -e 'File.write(ARGV[0], "schema_version: orbit-task-v1\nproject: project\ntarget_role: lead\ntask_type: implementation\nevidence_requirements: []\n")' "$LEGACY_TASK"
"$CLI" validate --task "$LEGACY_TASK" --json >"$TMPROOT/legacy-task-validate.json"
json_assert 'validate warns on legacy task missing runtime guardrails' "$TMPROOT/legacy-task-validate.json" 'j["valid"] == true && j["warnings"].any? { |w| w["source"] == "task_file.source_contract" } && j["warnings"].any? { |w| w["source"] == "task_file.traceability" }'

BAD_RUNTIME_TASK="$TMPROOT/bad-runtime-task.yaml"
cp "$TASK" "$BAD_RUNTIME_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["worktree_safety"]["require_status_check"]="yes"; File.write(p, YAML.dump(y))' "$BAD_RUNTIME_TASK"
expect_failure 'validate rejects invalid runtime guardrail task fields' "$CLI" validate --task "$BAD_RUNTIME_TASK" --evidence "$APPEND_EVIDENCE" --json

BAD_RUNTIME_EVIDENCE="$TMPROOT/bad-runtime-evidence.json"
cp "$APPEND_EVIDENCE" "$BAD_RUNTIME_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["regression_guard"]={"status"=>"present","evidence"=>""}; File.write(p, JSON.pretty_generate(j))' "$BAD_RUNTIME_EVIDENCE"
expect_failure 'validate rejects invalid runtime guardrail evidence fields' "$CLI" validate --task "$TASK" --evidence "$BAD_RUNTIME_EVIDENCE" --json

REVIEW_JUDGMENT_EVIDENCE="$TMPROOT/review-judgment-evidence.json"
cp "$APPEND_EVIDENCE" "$REVIEW_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["review_judgment"]={"verdict"=>"pass","quality_outcome"=>{"verdict"=>"pass","reasoning"=>"outcome satisfied"},"findings"=>[],"residual_risk"=>{"accepted"=>true,"reason"=>"no known blocking risk"}}; File.write(p, JSON.pretty_generate(j))' "$REVIEW_JUDGMENT_EVIDENCE"
"$CLI" evidence attach-rule --file "$REVIEW_JUDGMENT_EVIDENCE" --rule-resolution "$TMPROOT/current-rule-resolution.json" >"$TMPROOT/evidence-attach-rule.out" 2>"$TMPROOT/evidence-attach-rule.err"
test ! -s "$TMPROOT/evidence-attach-rule.err"
json_assert 'evidence attach-rule records rule resolution summary' "$REVIEW_JUDGMENT_EVIDENCE" 'j["rule_resolution"]["file"] == File.expand_path(ARGV[2]) && j["rule_resolution"]["valid"] == true && j["rule_resolution"]["resolved_role"] == "reviewer" && j["rule_resolution"]["conflict_count"] == 0' "$TMPROOT/current-rule-resolution.json"
CONCURRENT_EVIDENCE="$TMPROOT/concurrent-evidence.json"
"$CLI" evidence init --output "$CONCURRENT_EVIDENCE" >/dev/null
cat >"$TMPROOT/concurrent-review-submit.yaml" <<'YAML'
kind: review
verdict: pass
summary: Concurrent review submit passed.
source_message_id: herdr:reviewer:concurrent
quality_outcome_verdict: pass
quality_outcome_reasoning: Concurrent review record is complete.
findings: []
coverage:
  - concurrent review record retained
artifacts:
  - tests/orbit_test.sh
YAML
cat >"$TMPROOT/concurrent-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Concurrent test submit passed.
source_message_id: herdr:tester:concurrent
test_level: repo_regression
findings: []
coverage:
  - concurrent test record retained
artifacts:
  - tests/orbit_test.sh
test_environment:
  environment: local shell
  test_tab_or_pane: current pane
  server_owner: none
  browser_owner: none
  cleanup_hook: no persistent runtime started
  artifact_cleanup: retained compact log only
  duration: 1s
  resource_usage: shell processes
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: stable test artifact
YAML
"$CLI" evidence attach-rule --file "$CONCURRENT_EVIDENCE" --rule-resolution "$TMPROOT/current-rule-resolution.json" >/dev/null &
"$CLI" evidence add --file "$CONCURRENT_EVIDENCE" --kind command --status pass --summary "concurrent command retained" >/dev/null &
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/concurrent-review-submit.yaml" --json >/dev/null &
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/concurrent-test-submit.yaml" --json >/dev/null &
wait
json_assert 'concurrent evidence writers preserve rules and all records' "$CONCURRENT_EVIDENCE" 'j["rule_resolution"]["file"] == File.expand_path(ARGV[2]) && j["records"].any? { |r| r["kind"] == "command" && r["summary"] == "concurrent command retained" } && j["records"].any? { |r| r["kind"] == "review" && r["source_message_id"] == "herdr:reviewer:concurrent" } && j["records"].any? { |r| r["kind"] == "test" && r["source_message_id"] == "herdr:tester:concurrent" }' "$TMPROOT/current-rule-resolution.json"
"$CLI" validate --task "$TASK" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/valid-review-judgment.json"
json_assert 'validate accepts structured review judgment' "$TMPROOT/valid-review-judgment.json" 'j["valid"] == true'
BAD_RULE_RESOLUTION_EVIDENCE="$TMPROOT/bad-rule-resolution-evidence.json"
cp "$REVIEW_JUDGMENT_EVIDENCE" "$BAD_RULE_RESOLUTION_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["rule_resolution"]["file"]=File.expand_path(ARGV[1]); File.write(p, JSON.pretty_generate(j))' "$BAD_RULE_RESOLUTION_EVIDENCE" "$TMPROOT/missing-rule-resolution.json"
expect_failure 'validate rejects missing attached rule resolution' "$CLI" validate --task "$TASK" --evidence "$BAD_RULE_RESOLUTION_EVIDENCE" --json
ORBIT_ROLE=reviewer "$CLI" rules resolve --json --output "$TMPROOT/no-task-rule-resolution.json" >/dev/null
NO_TASK_RULE_EVIDENCE="$TMPROOT/no-task-rule-evidence.json"
cp "$REVIEW_JUDGMENT_EVIDENCE" "$NO_TASK_RULE_EVIDENCE"
"$CLI" evidence attach-rule --file "$NO_TASK_RULE_EVIDENCE" --rule-resolution "$TMPROOT/no-task-rule-resolution.json" >/dev/null
expect_failure 'validate rejects task evidence with no-task rule resolution' "$CLI" validate --task "$TASK" --evidence "$NO_TASK_RULE_EVIDENCE" --json
BAD_REVIEW_JUDGMENT_EVIDENCE="$TMPROOT/bad-review-judgment-evidence.json"
cp "$REVIEW_JUDGMENT_EVIDENCE" "$BAD_REVIEW_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["review_judgment"]["quality_outcome"].delete("reasoning"); File.write(p, JSON.pretty_generate(j))' "$BAD_REVIEW_JUDGMENT_EVIDENCE"
expect_failure 'validate rejects incomplete review judgment' "$CLI" validate --task "$TASK" --evidence "$BAD_REVIEW_JUDGMENT_EVIDENCE" --json

LATEST_FAIL_EVIDENCE="$TMPROOT/latest-fail-evidence.json"
"$CLI" evidence init --output "$LATEST_FAIL_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$LATEST_FAIL_EVIDENCE" --kind review --status pass --summary "review passed first" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$LATEST_FAIL_EVIDENCE" --kind review --status fail --summary "review failed latest" >/dev/null
expect_failure 'validate uses latest review fail verdict' "$CLI" validate --task "$TASK" --evidence "$LATEST_FAIL_EVIDENCE" --json

LATEST_PASS_EVIDENCE="$TMPROOT/latest-pass-evidence.json"
"$CLI" evidence init --output "$LATEST_PASS_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$LATEST_PASS_EVIDENCE" --kind review --status fail --summary "review failed first" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$LATEST_PASS_EVIDENCE" --kind review --status pass --summary "review passed latest" >/dev/null
"$CLI" validate --task "$TASK" --evidence "$LATEST_PASS_EVIDENCE" --json >"$TMPROOT/latest-pass-validate.json"
json_assert 'validate uses latest review pass verdict' "$TMPROOT/latest-pass-validate.json" 'j["valid"] == true'

PARTIAL_EVIDENCE="$TMPROOT/partial-evidence.json"
"$CLI" evidence init --output "$PARTIAL_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$PARTIAL_EVIDENCE" --kind review --status partial --summary "review partially passed" >/dev/null
expect_failure 'validate rejects partial verdict for done gate' "$CLI" validate --task "$TASK" --evidence "$PARTIAL_EVIDENCE" --json

INVALID_ONLY_EVIDENCE="$TMPROOT/invalid-only-evidence.json"
"$CLI" evidence init --output "$INVALID_ONLY_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$INVALID_ONLY_EVIDENCE" --kind review --status invalid --summary "invalid review evidence" >/dev/null
expect_failure 'validate ignores invalid-only verdict' "$CLI" validate --task "$TASK" --evidence "$INVALID_ONLY_EVIDENCE" --json

INVALID_LATEST_EVIDENCE="$TMPROOT/invalid-latest-evidence.json"
"$CLI" evidence init --output "$INVALID_LATEST_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$INVALID_LATEST_EVIDENCE" --kind review --status pass --summary "review passed before invalid" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$INVALID_LATEST_EVIDENCE" --kind review --status invalid --summary "invalid latest ignored" >/dev/null
"$CLI" validate --task "$TASK" --evidence "$INVALID_LATEST_EVIDENCE" --json >"$TMPROOT/invalid-latest-validate.json"
json_assert 'validate ignores invalid latest verdict' "$TMPROOT/invalid-latest-validate.json" 'j["valid"] == true'

TEST_ONLY_EVIDENCE="$TMPROOT/test-only-evidence.json"
"$CLI" evidence init --output "$TEST_ONLY_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence add --file "$TEST_ONLY_EVIDENCE" --kind test --status pass --summary "test passed only" >/dev/null
expect_failure 'validate review task rejects test-only evidence' "$CLI" validate --task "$TASK" --evidence "$TEST_ONLY_EVIDENCE" --json

BAD_TIME_EVIDENCE="$TMPROOT/bad-time-evidence.json"
"$CLI" evidence init --output "$BAD_TIME_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$BAD_TIME_EVIDENCE" --kind review --status pass --summary "bad time evidence" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"][0]["created_at"]="not-a-time"; File.write(p, JSON.pretty_generate(j))' "$BAD_TIME_EVIDENCE"
expect_failure 'validate fails unsortable evidence time' "$CLI" validate --task "$TASK" --evidence "$BAD_TIME_EVIDENCE" --json

expect_failure 'state start rejects owner role conflict' env ORBIT_ROLE=lead "$CLI" state start --task "$TASK" --owner-role reviewer
ORBIT_ROLE=lead "$CLI" state start --task "$TASK" >"$TMPROOT/state-start.out" 2>"$TMPROOT/state-start.err"
test ! -s "$TMPROOT/state-start.err"
"$CLI" state show --json >"$TMPROOT/state-working.json"
json_assert 'state start infers owner and binds task' "$TMPROOT/state-working.json" 'j["phase"] == "working" && j["owner_role"] == "lead" && j["current_task"] == File.expand_path(ARGV[2]) && j["history"].last["event"] == "start"' "$TASK"
DESIGN_STATE="$TMPROOT/design-loop-state.yaml"
cp .orbit/loop-state.yaml "$DESIGN_STATE"
ORBIT_INSTANCE=lead "$CLI" state start --state "$DESIGN_STATE" --task "$DESIGN_TASK" --owner-role lead >/dev/null
yaml_assert 'state start enters drafting for design task' "$DESIGN_STATE" 'j["phase"] == "drafting" && j["history"].last["to"] == "drafting"'
DESIGN_GATE_EVIDENCE="$TMPROOT/design-gate-evidence.json"
"$CLI" evidence init --output "$DESIGN_GATE_EVIDENCE" >/dev/null
cat >"$TMPROOT/design-review-pass.yaml" <<'YAML'
kind: review
verdict: pass
summary: Design review passed for coding readiness.
source_message_id: design-review-pass
quality_outcome_verdict: pass
quality_outcome_reasoning: Reviewed design artifact is ready for user confirmation.
findings: []
coverage:
  - Design artifact was reviewed before coding.
artifacts:
  - docs/open/design.md
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$DESIGN_GATE_EVIDENCE" --report "$TMPROOT/design-review-pass.yaml" --json >/dev/null
expect_failure 'state transition blocks design coding_ready before user_confirmed phase' "$CLI" state transition --state "$DESIGN_STATE" --to coding_ready --evidence "$DESIGN_GATE_EVIDENCE"
"$CLI" state transition --state "$DESIGN_STATE" --to review_requested >/dev/null
expect_failure 'state transition blocks user_confirmed without user confirmation evidence' "$CLI" state transition --state "$DESIGN_STATE" --to user_confirmed --evidence "$DESIGN_GATE_EVIDENCE"
"$CLI" evidence add --file "$DESIGN_GATE_EVIDENCE" --kind implementation --status pass --summary "user_confirmed: user approved reviewed design artifact for coding." >/dev/null
"$CLI" state transition --state "$DESIGN_STATE" --to user_confirmed --evidence "$DESIGN_GATE_EVIDENCE" >/dev/null
"$CLI" state transition --state "$DESIGN_STATE" --to coding_ready --evidence "$DESIGN_GATE_EVIDENCE" >/dev/null
yaml_assert 'state transition reaches coding_ready only after review and user confirmation' "$DESIGN_STATE" 'j["phase"] == "coding_ready" && j["history"].last["to"] == "coding_ready" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2])' "$DESIGN_GATE_EVIDENCE"
expect_failure 'state transition to blocked requires reason' "$CLI" state transition --to blocked
cp .orbit/loop-state.yaml "$TMPROOT/block-state.yaml"
"$CLI" state transition --state "$TMPROOT/block-state.yaml" --to blocked --reason "needs input" >/dev/null
yaml_assert 'state transition to blocked records reason' "$TMPROOT/block-state.yaml" 'j["phase"] == "blocked" && j["status"].include?("needs input") && j["history"].last["reason"] == "needs input"'
expect_failure 'state transition blocks working to done without evidence' "$CLI" state transition --to done
"$CLI" state transition --to in_review >"$TMPROOT/state-in-review.out" 2>"$TMPROOT/state-in-review.err"
test ! -s "$TMPROOT/state-in-review.err"
"$CLI" state show --json >"$TMPROOT/state-in-review.json"
json_assert 'state transition working to in_review passes' "$TMPROOT/state-in-review.json" 'j["phase"] == "in_review" && j["history"].last["from"] == "working" && j["history"].last["to"] == "in_review"'
FAIL_EVIDENCE="$TMPROOT/fail-evidence.json"
"$CLI" evidence init --output "$FAIL_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$FAIL_EVIDENCE" --kind review --status fail --summary "review failed" >/dev/null
expect_failure 'state transition blocks done on fail evidence' "$CLI" state transition --to done --evidence "$FAIL_EVIDENCE"
"$CLI" state transition --to done --evidence "$REVIEW_JUDGMENT_EVIDENCE" >"$TMPROOT/state-done.out" 2>"$TMPROOT/state-done.err"
test ! -s "$TMPROOT/state-done.err"
"$CLI" state show --json >"$TMPROOT/state-done.json"
json_assert 'state transition to done records evidence' "$TMPROOT/state-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2]) && j["history"].last["to"] == "done"' "$REVIEW_JUDGMENT_EVIDENCE"
cp .orbit/loop-state.yaml "$TMPROOT/review-done-state.yaml"

IMPL_TASK="$TMPROOT/implementation-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$IMPL_TASK" >/dev/null
yaml_assert 'new-task adds implementation review/test gates' "$IMPL_TASK" 'j["gates"].is_a?(Array) && j["gates"].any? { |g| g["kind"] == "review" && g["roles"].include?("reviewer") } && j["gates"].any? { |g| g["kind"] == "test" && g["roles"].include?("tester") }'
yaml_assert 'new-task marks implementation test gate level' "$IMPL_TASK" 'j["test_level"] == "repo_regression"'
ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$IMPL_TASK" --json >"$TMPROOT/implementation-reviewer-rules.json"
json_assert 'rules resolve allows reviewer gate role on implementation task' "$TMPROOT/implementation-reviewer-rules.json" 'j["valid"] == true && j["resolved_role"] == "reviewer" && j["role_sources"]["task_file.target_role"] == "lead"'
BAD_GATE_TASK="$TMPROOT/bad-gate-task.yaml"
cp "$IMPL_TASK" "$BAD_GATE_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"deploy","roles"=>["reviewer"],"required"=>true}]; File.write(p, YAML.dump(y))' "$BAD_GATE_TASK"
expect_failure 'rules resolve rejects invalid gate kind role bypass' env ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$BAD_GATE_TASK" --json
IMPL_EVIDENCE="$TMPROOT/implementation-evidence.json"
"$CLI" evidence init --output "$IMPL_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$IMPL_EVIDENCE" --kind implementation --status pass --summary "implementation evidence passed" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["worktree_safety"]={"status"=>"not_git","reason"=>"generated test app is not a git repository","unexpected_changes"=>[]}; File.write(p, JSON.pretty_generate(j))' "$IMPL_EVIDENCE"
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$IMPL_TASK" >/dev/null
"$CLI" state progress --message "implementation complete, waiting for gates" --evidence "$IMPL_EVIDENCE" >"$TMPROOT/state-progress.out" 2>"$TMPROOT/state-progress.err"
test ! -s "$TMPROOT/state-progress.err"
"$CLI" state show --json >"$TMPROOT/state-progress.json"
json_assert 'state progress records heartbeat without phase change' "$TMPROOT/state-progress.json" 'j["phase"] == "working" && j["status"].include?("implementation complete") && j["history"].last["event"] == "progress" && j["history"].last["evidence"] == File.expand_path(ARGV[2]) && !j["artifacts"].key?("evidence_file")' "$IMPL_EVIDENCE"
CONCURRENT_STATE="$TMPROOT/concurrent-loop-state.yaml"
cp .orbit/loop-state.yaml "$CONCURRENT_STATE"
"$CLI" state progress --state "$CONCURRENT_STATE" --message "concurrent progress one" >/dev/null &
"$CLI" state progress --state "$CONCURRENT_STATE" --message "concurrent progress two" >/dev/null &
wait
yaml_assert 'concurrent state progress preserves both history entries' "$CONCURRENT_STATE" 'messages = j["history"].select { |h| h["event"] == "progress" }.map { |h| h["message"] }; messages.include?("concurrent progress one") && messages.include?("concurrent progress two")'
expect_failure 'state transition blocks done until implementation gates pass' "$CLI" state transition --to done --evidence "$IMPL_EVIDENCE"
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$IMPL_EVIDENCE" --kind review --status pass --summary "review gate passed" >/dev/null
cat >"$TMPROOT/implementation-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Implementation test gate passed with environment lifecycle.
source_message_id: herdr:tester:implementation-gate
test_level: repo_regression
findings: []
coverage:
  - implementation gate success path
artifacts:
  - .orbit/test-artifacts/implementation-gate.log
test_environment:
  environment: local shell
  test_tab_or_pane: current pane
  server_owner: none
  browser_owner: none
  cleanup_hook: no persistent runtime started
  artifact_cleanup: retained compact log only
  duration: 1s
  resource_usage: one shell process
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: artifact path is stable and small
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$IMPL_EVIDENCE" --report "$TMPROOT/implementation-test-submit.yaml" --json >/dev/null
"$CLI" state transition --to done --evidence "$IMPL_EVIDENCE" >"$TMPROOT/implementation-done.out" 2>"$TMPROOT/implementation-done.err"
test ! -s "$TMPROOT/implementation-done.err"
"$CLI" state show --json >"$TMPROOT/implementation-done.json"
json_assert 'state transition allows done with implementation pass evidence' "$TMPROOT/implementation-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2])' "$IMPL_EVIDENCE"
"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-valid.json" 2>"$TMPROOT/audit-valid.err"
test ! -s "$TMPROOT/audit-valid.err"
json_assert 'audit passes done state with matching evidence' "$TMPROOT/audit-valid.json" 'j["schema_version"] == "orbit-audit-v1" && j["trust_level"]["mode"] == "audit_only" && j["done_ready"] == true && j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == false && j["blocking_findings"].empty? && j["warnings"].any? { |e| e["source"] == "state_file.artifacts.handoff_packet" && e["remediation"].is_a?(String) } && j["issues"].length == j["blocking_findings"].length + j["warnings"].length && j["validation"]["valid"] == true'
"$CLI" handoff --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --output "$TMPROOT/implementation-handoff.json" --record-state --json >"$TMPROOT/implementation-handoff.stdout"
json_assert 'handoff can write artifact and record it in state' "$TMPROOT/implementation-handoff.json" 'j["schema_version"] == "orbit-handoff-v1" && j["blocking_errors"].empty? && j["gate_summary"]["ready"] == true && j["judgment_summary"]["review_judgment"]["present"] == true && j["judgment_summary"]["review_judgment"]["source"] == "latest_evidence_record" && j["judgment_summary"]["test_judgment"]["present"] == true && j["latest_gate_verdicts"]["review"]["status"] == "pass" && j["latest_gate_verdicts"]["test"]["status"] == "pass" && j["closure_checklist"].is_a?(Array) && j["closure_checklist"].any? { |c| c["item"] == "latest_test_verdict" } && j["known_gaps"].is_a?(Array) && j["readable_summary"]["next_action"] == "none" && j["worktree_safety_summary"]["status"] == "not_git"'
yaml_assert 'handoff record-state stores artifact path' .orbit/loop-state.yaml 'j["artifacts"]["handoff_packet"] == File.expand_path(ARGV[2]) && j["history"].last["event"] == "handoff"' "$TMPROOT/implementation-handoff.json"
"$CLI" compact-evidence --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --handoff "$TMPROOT/implementation-handoff.json" --output "$TMPROOT/durable-summary.json" --json >"$TMPROOT/durable-summary.stdout"
cmp "$TMPROOT/durable-summary.json" "$TMPROOT/durable-summary.stdout"
json_assert 'compact-evidence writes durable summary with hashes and refs' "$TMPROOT/durable-summary.json" 'j["schema_version"] == "orbit-durable-evidence-summary-v1" && j["inputs"]["task"]["sha256"].is_a?(String) && j["inputs"]["evidence"]["sha256"].is_a?(String) && j["inputs"]["handoff"]["sha256"].is_a?(String) && j["evidence_summary"]["records"]["count"] >= 3 && j["evidence_summary"]["aggregate_verdict"]["mode"] == "aggregate" && j["handoff_summary"]["current_phase"] == "done" && j["handoff_summary"]["latest_gate_verdicts"]["test"]["status"] == "pass" && j["handoff_summary"]["closure_checklist"].is_a?(Array) && j["handoff_summary"]["known_gaps"].is_a?(Array) && j["handoff_summary"]["readable_summary"]["next_action"] == "none" && j["transient_artifacts"]["policy"] == "referenced_by_path_and_hash" && j["transient_artifacts"]["large_artifacts_not_embedded"] == true'
"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-release.json"
json_assert 'audit trusts release when handoff artifact is recorded' "$TMPROOT/audit-release.json" 'j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == true && j["warnings"].empty?'
RISKY_EVIDENCE="$TMPROOT/risky-evidence.json"
cp "$IMPL_EVIDENCE" "$RISKY_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["regression_guard"]={"status"=>"absent","evidence"=>""}; j["release_surface"]={"status"=>"partial","checked"=>["package"],"gaps"=>["release asset not checked"]}; File.write(p, JSON.pretty_generate(j))' "$RISKY_EVIDENCE"
RISKY_STATE="$TMPROOT/risky-state.yaml"
cp .orbit/loop-state.yaml "$RISKY_STATE"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["artifacts"]["evidence_file"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(y))' "$RISKY_STATE" "$RISKY_EVIDENCE"
"$CLI" audit --task "$IMPL_TASK" --evidence "$RISKY_EVIDENCE" --state "$RISKY_STATE" --json >"$TMPROOT/audit-risky-evidence.json"
json_assert 'audit lowers release trust on runtime guardrail warnings' "$TMPROOT/audit-risky-evidence.json" 'j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == false && j["warnings"].any? { |w| w["source"] == "evidence_file.regression_guard" } && j["warnings"].any? { |w| w["source"] == "evidence_file.release_surface.gaps" }'
expect_failure 'handoff record-state requires output' "$CLI" handoff --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --record-state --json
cp .orbit/loop-state.yaml "$TMPROOT/audit-drift-state.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["current_task"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(y))' "$TMPROOT/audit-drift-state.yaml" "$TASK"
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state "$TMPROOT/audit-drift-state.yaml" --json >"$TMPROOT/audit-drift.json"; then
  printf 'FAIL audit drift: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit reports state task drift' "$TMPROOT/audit-drift.json" 'j["blocking_findings"].any? { |e| e["source"] == "state_file.current_task" && e["severity"] == "high" && e["remediation"].include?("orbit state start") } && j["trusted_for_handoff"] == false && j["trusted_for_done"] == false && j["trusted_for_release"] == false && j["done_ready"] == false'
expect_failure 'audit rejects missing evidence option value' "$CLI" audit --task "$IMPL_TASK" --evidence --state .orbit/loop-state.yaml --json

"$CLI" validate --task "$TASK" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --state "$TMPROOT/review-done-state.yaml" --json >"$TMPROOT/valid-task-evidence-state.json"
json_assert 'validate includes loop state and trust level' "$TMPROOT/valid-task-evidence-state.json" 'j["valid"] == true && j["checked"].include?("state") && j["trust_level"]["mode"] == "audit_only"'
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/handoff-valid.json" 2>"$TMPROOT/handoff-valid.err"
test ! -s "$TMPROOT/handoff-valid.err"
json_assert 'handoff outputs valid packet' "$TMPROOT/handoff-valid.json" 'j["schema_version"] == "orbit-handoff-v1" && j["target_role"] == "reviewer" && j["current_phase"] == "done" && j["required_action"] == "none" && j["next_action"] == "none" && j["blocking_errors"].empty? && j["validation_summary"]["valid"] == true && j["audit_summary"]["done_ready"] == true && j["tools_summary"]["preferred_transport"].is_a?(String) && j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["payload"]["required_action"] == "none" && j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" } && j["rule_packs"].any? { |p| p["category"] == "audit" && p["id"] == "orbit-drift" } && j["rule_resolution_summary"]["present"] == true && j["rule_resolution_summary"]["valid"] == true && j["rule_resolution_summary"]["resolved_role"] == "reviewer" && j["judgment_summary"]["review_judgment"]["present"] == true && j["closure_checklist"].is_a?(Array) && j["readable_summary"]["next_action"] == "none" && j["evidence_summary"]["records"] >= 1'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y={"schema_version"=>"orbit-tools-config-v1","transport_profiles"=>{"generic"=>{"handoff"=>{"format"=>"json","delivery"=>"manual"}},"herdr"=>{"fallback"=>"generic","handoff"=>{"format"=>"json","delivery"=>"pane.message"}}},"preference"=>{"handoff"=>"herdr"}}; File.write(p, YAML.dump(y))' .orbit/tools.yaml
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport generic --json >"$TMPROOT/handoff-generic-transport.json"
json_assert 'handoff outputs generic transport payload' "$TMPROOT/handoff-generic-transport.json" 'j["required_action"] == "none" && j["transport_profile"]["requested"] == "generic" && j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["fallback_used"] == false && j["transport_profile"]["payload"]["delivery"] == "manual"'
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport herdr --json >"$TMPROOT/handoff-herdr-transport.json"
json_assert 'handoff outputs herdr transport or generic fallback payload' "$TMPROOT/handoff-herdr-transport.json" 'j["required_action"] == "none" && j["transport_profile"]["requested"] == "herdr" && ((j["transport_profile"]["selected"] == "herdr" && j["transport_profile"]["payload"]["delivery"] == "pane.message") || (j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["fallback_used"] == true))'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y={"schema_version"=>"orbit-tools-config-v1","transport_profiles"=>{"generic"=>{"handoff"=>{"format"=>"json","delivery"=>"manual"}}}}; File.write(p, YAML.dump(y))' .orbit/tools.yaml
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport herdr --json >"$TMPROOT/handoff-missing-profile-fallback.json"
json_assert 'handoff falls back when transport profile is missing' "$TMPROOT/handoff-missing-profile-fallback.json" 'j["required_action"] == "none" && j["transport_profile"]["requested"] == "herdr" && j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["fallback_used"] == true && j["transport_profile"]["reason"].include?("not configured")'
expect_failure 'handoff rejects missing transport option value' "$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport --json
INVALID_HANDOFF_TASK="$TMPROOT/invalid-handoff-task.yaml"
cp "$TASK" "$INVALID_HANDOFF_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("target_role"); File.write(p, YAML.dump(y))' "$INVALID_HANDOFF_TASK"
if "$CLI" handoff --task "$INVALID_HANDOFF_TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/handoff-invalid.json"; then
  printf 'FAIL handoff invalid task: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'handoff invalid task reports blocking errors' "$TMPROOT/handoff-invalid.json" 'j["blocking_errors"].any? { |e| e["source"] == "task_file.target_role" } && j["required_action"] == "resolve_blocking_errors"'
expect_failure 'handoff fails role conflict' env ORBIT_INSTANCE=tester "$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json

EQ_TASK="$TMPROOT/eq-task.yaml"
"$CLI" new-task --target-role=tester --task-type=implementation_test --project=explicit --output="$EQ_TASK" >/dev/null
yaml_assert 'new-task supports equals syntax and explicit project' "$EQ_TASK" 'j["project"] == "explicit" && j["target_role"] == "tester" && j["task_type"] == "implementation_test" && j["rule_packs"].any? { |p| p["category"] == "test" && p["id"] == "brooks-test" }'
expect_failure 'validate test task rejects review-only appended evidence' "$CLI" validate --task "$EQ_TASK" --evidence "$APPEND_EVIDENCE" --json
cat >"$TMPROOT/eq-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Explicit test task passed with environment lifecycle.
source_message_id: herdr:tester:eq-test-pass
test_level: repo_regression
findings: []
coverage:
  - explicit task test evidence path
artifacts:
  - .orbit/test-artifacts/eq-test.log
test_environment:
  environment: local shell
  test_tab_or_pane: current pane
  server_owner: none
  browser_owner: none
  cleanup_hook: no persistent runtime started
  artifact_cleanup: retained compact log only
  duration: 1s
  resource_usage: one shell process
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: artifact path is stable and small
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$APPEND_EVIDENCE" --report "$TMPROOT/eq-test-submit.yaml" --json >"$TMPROOT/eq-test-submit.json"
"$CLI" validate --task "$EQ_TASK" --evidence "$APPEND_EVIDENCE" --json >"$TMPROOT/valid-test-append-evidence.json"
json_assert 'validate reads appended test evidence' "$TMPROOT/valid-test-append-evidence.json" 'j["valid"] == true'
TEST_JUDGMENT_EVIDENCE="$TMPROOT/test-judgment-evidence.json"
cp "$APPEND_EVIDENCE" "$TEST_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["test_judgment"]={"verdict"=>"pass","environment"=>"local shell","scenarios"=>[{"name"=>"happy path","result"=>"pass","evidence"=>"command output retained"}],"coverage_gap"=>[]}; File.write(p, JSON.pretty_generate(j))' "$TEST_JUDGMENT_EVIDENCE"
"$CLI" validate --task "$EQ_TASK" --evidence "$TEST_JUDGMENT_EVIDENCE" --json >"$TMPROOT/valid-test-judgment.json"
json_assert 'validate accepts structured test judgment' "$TMPROOT/valid-test-judgment.json" 'j["valid"] == true'
BAD_TEST_JUDGMENT_EVIDENCE="$TMPROOT/bad-test-judgment-evidence.json"
cp "$TEST_JUDGMENT_EVIDENCE" "$BAD_TEST_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["test_judgment"].delete("scenarios"); File.write(p, JSON.pretty_generate(j))' "$BAD_TEST_JUDGMENT_EVIDENCE"
expect_failure 'validate rejects incomplete test judgment' "$CLI" validate --task "$EQ_TASK" --evidence "$BAD_TEST_JUDGMENT_EVIDENCE" --json
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$EQ_TASK" >/dev/null
"$CLI" state show --json >"$TMPROOT/state-owner-instance.json"
json_assert 'state start infers owner from instance' "$TMPROOT/state-owner-instance.json" 'j["phase"] == "working" && j["owner_role"] == "lead"'
expect_failure 'new-task requires output' "$CLI" new-task --target-role reviewer --task-type review
expect_failure 'new-task rejects missing target-role value' "$CLI" new-task --target-role --task-type review --output "$TMPROOT/bad.yaml"

MISMATCH_TASK="$TMPROOT/task-mismatch.yaml"
ruby --disable-gems -e 'File.write(ARGV[0], "schema_version: orbit-task-v1\nproject: project\ntarget_role: tester\n")' "$MISMATCH_TASK"
expect_failure 'whoami fails on task target mismatch' env ORBIT_INSTANCE=reviewer "$CLI" whoami --json --task "$MISMATCH_TASK"
expect_failure 'whoami fails on missing task file conflict' env ORBIT_INSTANCE=reviewer "$CLI" whoami --json --task "$TMPROOT/missing.yaml"

EVIDENCE="$SKILL_ROOT/assets/templates/evidence.json"
expect_failure 'validate review task requires evidence' "$CLI" validate --task "$TASK" --json
"$CLI" validate --task "$TASK" --evidence "$EVIDENCE" --json >"$TMPROOT/valid-task-evidence.json" 2>"$TMPROOT/valid-task-evidence.err"
test ! -s "$TMPROOT/valid-task-evidence.err"
json_assert 'validate passes valid task with evidence' "$TMPROOT/valid-task-evidence.json" 'j["valid"] == true && j["checked"].include?("task") && j["checked"].include?("evidence")'

cp "$TASK" "$TMPROOT/task-missing-target.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("target_role"); File.write(p, YAML.dump(y))' "$TMPROOT/task-missing-target.yaml"
expect_failure 'validate fails task missing target_role' "$CLI" validate --task "$TMPROOT/task-missing-target.yaml" --evidence "$EVIDENCE" --json

cp "$TASK" "$TMPROOT/task-missing-evidence-req.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("evidence_requirements"); File.write(p, YAML.dump(y))' "$TMPROOT/task-missing-evidence-req.yaml"
expect_failure 'validate fails task missing evidence_requirements' "$CLI" validate --task "$TMPROOT/task-missing-evidence-req.yaml" --evidence "$EVIDENCE" --json

cp "$TASK" "$TMPROOT/task-missing-qo.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_type"]="quality_improvement"; y.delete("quality_outcome"); File.write(p, YAML.dump(y))' "$TMPROOT/task-missing-qo.yaml"
expect_failure 'validate fails improvement task missing quality_outcome' "$CLI" validate --task "$TMPROOT/task-missing-qo.yaml" --evidence "$EVIDENCE" --json

cp "$TASK" "$TMPROOT/task-empty-qo.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_type"]="quality_improvement"; y["quality_outcome"]={"user_problem"=>"","desired_property"=>"","measurable_thresholds"=>[],"invalid_completions"=>[]}; File.write(p, YAML.dump(y))' "$TMPROOT/task-empty-qo.yaml"
expect_failure 'validate fails improvement task empty quality_outcome fields' "$CLI" validate --task "$TMPROOT/task-empty-qo.yaml" --evidence "$EVIDENCE" --json

expect_failure 'validate fails coding task without confirmed design reference' "$CLI" validate --task "$CODING_TASK" --evidence "$EVIDENCE" --json
cp "$CODING_TASK" "$TMPROOT/coding-confirmed-design.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["design_reference"]={"required_for_coding"=>true,"artifact"=>"docs/open/design.md","confirmation_evidence"=>"evidence:user_confirmed","status"=>"confirmed"}; File.write(p, YAML.dump(y))' "$TMPROOT/coding-confirmed-design.yaml"
"$CLI" validate --task "$TMPROOT/coding-confirmed-design.yaml" --evidence "$EVIDENCE" --json >"$TMPROOT/coding-confirmed-design.json"
json_assert 'validate passes coding task with confirmed design reference' "$TMPROOT/coding-confirmed-design.json" 'j["valid"] == true'

expect_failure 'validate fails decomposition task missing aggregate contract details' "$CLI" validate --task "$DECOMP_TASK" --evidence "$EVIDENCE" --json
cp "$DECOMP_TASK" "$TMPROOT/decomposition-complete.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["implementation_plan"]["summary"]="Split parent work into reviewed child slices."; y["decomposition"]["child_slices"]=[{"id"=>"S1","include"=>"first child behavior","exclude"=>"second child behavior","order_basis"=>"unblocks shared contract first","stop_condition"=>"slice review and tests pass","replan_path"=>"return to parent plan before continuing"}]; y["decomposition"]["aggregate_outcome_metrics"]=["parent outcome rechecked after child slices"]; y["decomposition"]["stop_conditions"]=["all child slices and parent audit pass"]; y["decomposition"]["replanning_path"]="return to design review"; y["final_aggregate_audit"]["checks"]=["parent outcome still holds"]; File.write(p, YAML.dump(y))' "$TMPROOT/decomposition-complete.yaml"
"$CLI" validate --task "$TMPROOT/decomposition-complete.yaml" --evidence "$EVIDENCE" --json >"$TMPROOT/decomposition-complete.json"
json_assert 'validate passes complete decomposition contract' "$TMPROOT/decomposition-complete.json" 'j["valid"] == true'

QUALITY_EVIDENCE="$TMPROOT/quality-measurement-evidence.json"
"$CLI" evidence init --output "$QUALITY_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$QUALITY_EVIDENCE" --kind review --status pass --summary "quality review passed" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence add --file "$QUALITY_EVIDENCE" --kind test --status pass --summary "quality test missing baseline" >/dev/null
expect_failure 'validate rejects quality measurement pass without baseline after evidence' "$CLI" validate --task "$PERFORMANCE_TASK" --evidence "$QUALITY_EVIDENCE" --json
cat >"$TMPROOT/quality-measurement-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Performance quality measurement includes baseline and after values.
source_message_id: herdr:tester:quality-measurement-pass
test_level: repo_regression
findings: []
coverage:
  - measured baseline and after behavior
artifacts:
  - .orbit/test-artifacts/quality-measurement.json
test_environment:
  environment: local shell
  test_tab_or_pane: current pane
  server_owner: none
  browser_owner: none
  cleanup_hook: no persistent runtime started
  artifact_cleanup: retained compact log only
  duration: 1s
  resource_usage: one shell process
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: artifact path is stable and small
quality_measurement:
  baseline: 120
  after: 80
  metrics:
    - name: command runtime ms
      baseline: 120
      after: 80
      evidence: .orbit/test-artifacts/quality-measurement.json
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$QUALITY_EVIDENCE" --report "$TMPROOT/quality-measurement-submit.yaml" --json >"$TMPROOT/quality-measurement-submit.json"
"$CLI" validate --task "$PERFORMANCE_TASK" --evidence "$QUALITY_EVIDENCE" --json >"$TMPROOT/valid-quality-measurement.json"
json_assert 'validate accepts quality measurement baseline and after evidence' "$TMPROOT/valid-quality-measurement.json" 'j["valid"] == true'

cp "$EVIDENCE" "$TMPROOT/invalid-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["verdict"]["status"]="maybe"; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/invalid-evidence.json"
expect_failure 'validate fails invalid evidence verdict' "$CLI" validate --evidence "$TMPROOT/invalid-evidence.json" --json
expect_failure 'validate rejects missing task option value' "$CLI" validate --task --json
expect_failure 'validate rejects missing evidence option value' "$CLI" validate --evidence --json
expect_failure 'validate rejects missing state option value' "$CLI" validate --state --json

printf 'REAL_TESTS_PASS count=%s tmp=%s\n' "$PASS_COUNT" "$TMPROOT"

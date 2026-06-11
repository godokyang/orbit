#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLI="$SKILL_ROOT/scripts/orbit"
TMPROOT=$(mktemp -d)
PASS_COUNT=0

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
grep -q 'orbit evidence attach-rule' "$TMPROOT/help.txt"
grep -q 'orbit audit' "$TMPROOT/help.txt"
grep -q 'orbit dispatch' "$TMPROOT/help.txt"
grep -q 'orbit handoff' "$TMPROOT/help.txt"
grep -Fq 'orbit dispatch --task PATH --to INSTANCE [--transport generic|herdr] [--pane PANE] [--dry-run] --json' "$TMPROOT/help.txt"
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
grep -Fq 'orbit dispatch --task PATH --to INSTANCE [--transport generic|herdr] [--pane PANE] [--dry-run] --json' "$TMPROOT/dispatch-help.txt"
grep -q 'sends text to an existing agent pane' "$TMPROOT/dispatch-help.txt"
pass 'dispatch subcommand help works'

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

"$CLI" start --help >"$TMPROOT/start-help.txt" 2>"$TMPROOT/start-help.err"
test ! -s "$TMPROOT/start-help.err"
grep -Fq 'orbit start INSTANCE [--transport local|herdr] [--cwd PATH] [--dry-run] [--json]' "$TMPROOT/start-help.txt"
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
"$CLI" start reviewer --dry-run --json >"$TMPROOT/start-reviewer.json"
json_assert 'start dry-run resolves instance command env and cwd' "$TMPROOT/start-reviewer.json" 'j["schema_version"] == "orbit-start-plan-v1" && j["action"] == "dry_run" && j["transport"] == "local" && j["instance"] == "reviewer" && j["argv"] == ["codex"] && j["env"]["ORBIT_INSTANCE"] == "reviewer" && j["env"]["ORBIT_ROLE"] == "reviewer" && j["cwd"] == Dir.pwd'
"$CLI" start reviewer --dry-run >"$TMPROOT/start-reviewer-human.txt" 2>"$TMPROOT/start-reviewer-human.err"
test ! -s "$TMPROOT/start-reviewer-human.err"
grep -q 'Orbit start plan:' "$TMPROOT/start-reviewer-human.txt"
grep -q -- '- instance: reviewer' "$TMPROOT/start-reviewer-human.txt"
grep -q -- '- command: codex' "$TMPROOT/start-reviewer-human.txt"
pass 'start dry-run works without json'
"$CLI" start reviewer --transport herdr --dry-run --json >"$TMPROOT/start-herdr-dry-run.json"
json_assert 'start herdr dry-run emits adapter plan' "$TMPROOT/start-herdr-dry-run.json" 'j["schema_version"] == "orbit-start-plan-v1" && j["action"] == "dry_run" && j["transport"] == "herdr" && j["adapter"]["schema_version"] == "orbit-herdr-start-v1" && j["adapter"]["command"] == ["herdr", "agent", "start", "reviewer", "--cwd", Dir.pwd, "--split", "right", "--no-focus", "--", "codex"] && j["adapter"]["env"]["ORBIT_INSTANCE"] == "reviewer" && j["adapter"]["ready_wait"]["mode"] == "output_match"'
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
    printf '{"pane_id":"fake-pane","agent":"%s"}\n' "$ORBIT_INSTANCE"
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
ORBIT_FAKE_HERDR_ARGS="$TMPROOT/fake-herdr-args.txt" ORBIT_FAKE_HERDR_WAIT_ARGS="$TMPROOT/fake-herdr-wait-args.txt" ORBIT_FAKE_HERDR_ENV="$TMPROOT/fake-herdr-env.txt" ORBIT_FAKE_HERDR_CWD="$TMPROOT/fake-herdr-cwd.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer --transport herdr --json >"$TMPROOT/start-herdr-real.json"
json_assert 'start herdr invokes adapter and returns result' "$TMPROOT/start-herdr-real.json" 'j["action"] == "started" && j["adapter_result"]["success"] == true && j["adapter_result"]["stdout"].include?("fake-pane") && j["adapter_result"]["pane_id"] == "fake-pane" && j["adapter_result"]["ready_wait"]["success"] == true'
ruby --disable-gems -e 'expected=["agent","start","reviewer","--cwd",Dir.pwd,"--split","right","--no-focus","--","codex"]; actual=File.read(ARGV[0]).lines.map(&:chomp); abort(actual.inspect) unless actual == expected' "$TMPROOT/fake-herdr-args.txt"
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); abort(actual.inspect) unless actual[0,3] == ["wait","output","fake-pane"] && actual.include?("--regex") && actual.include?("OpenAI Codex|›")' "$TMPROOT/fake-herdr-wait-args.txt"
grep -qx 'reviewer/reviewer' "$TMPROOT/fake-herdr-env.txt"
grep -qx "$PROJECT" "$TMPROOT/fake-herdr-cwd.txt"
pass 'start herdr passes argv env cwd and waits for codex readiness'
ORBIT_FAKE_HERDR_ARGS="$TMPROOT/fake-herdr-human-args.txt" ORBIT_FAKE_HERDR_WAIT_ARGS="$TMPROOT/fake-herdr-human-wait-args.txt" ORBIT_FAKE_HERDR_ENV="$TMPROOT/fake-herdr-human-env.txt" ORBIT_FAKE_HERDR_CWD="$TMPROOT/fake-herdr-human-cwd.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" start reviewer --transport herdr >"$TMPROOT/start-herdr-human.txt" 2>"$TMPROOT/start-herdr-human.err"
test ! -s "$TMPROOT/start-herdr-human.err"
grep -q 'Started Orbit instance:' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- instance: reviewer' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- pane: fake-pane' "$TMPROOT/start-herdr-human.txt"
grep -q -- '- ready: pass' "$TMPROOT/start-herdr-human.txt"
pass 'start herdr works without json'
cp .orbit/instances.yaml "$TMPROOT/start-instances.yaml.bak"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer"]["command"]="printf;printf"; File.write(p, YAML.dump(y))' .orbit/instances.yaml
expect_failure 'start rejects shell metacharacter command string' "$CLI" start reviewer --dry-run --json
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
"$CLI" start reviewer --dry-run --json >"$TMPROOT/start-array-command.json"
json_assert 'start dry-run preserves array instance command' "$TMPROOT/start-array-command.json" 'j["argv"] == ["codex", "--profile", "review"]'
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
  ORBIT_INSTANCE="$role" "$CLI" whoami --json >"$TMPROOT/whoami-$role.json" 2>"$TMPROOT/whoami-$role.err"
  test ! -s "$TMPROOT/whoami-$role.err"
  json_assert "whoami resolves $role" "$TMPROOT/whoami-$role.json" "j[\"resolved_role\"] == \"$role\" && j[\"instance\"] == \"$role\" && j[\"conflicts\"].empty?"
done
json_assert 'whoami returns no project rules until user configures them' "$TMPROOT/whoami-reviewer.json" 'j["rules"].is_a?(Array) && j["rules"].empty?'

ORBIT_INSTANCE=reviewer-main "$CLI" whoami --json >"$TMPROOT/whoami-reviewer-main.json"
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
yaml_assert 'new-task does not invent project quality rules' "$TASK" 'j["quality_rules"].is_a?(Array) && j["quality_rules"].empty?'
yaml_assert 'new-task exposes configured review rule packs' "$TASK" 'j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }'
expect_failure 'new-task refuses overwrite' "$CLI" new-task --target-role reviewer --task-type implementation_review --output "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer --json >"$TMPROOT/dispatch-generic.json"
json_assert 'dispatch generic emits manual delivery payload' "$TMPROOT/dispatch-generic.json" 'j["schema_version"] == "orbit-dispatch-v1" && j["action"] == "manual_delivery_required" && j["transport"] == "generic" && j["to_instance"] == "reviewer" && j["resolved_role"] == "reviewer" && j["task"] == File.expand_path(ARGV[2]) && j["message"].include?("orbit whoami --task") && j["message"].include?("orbit rules print-context --task") && j["checks"]["target_role_matches"] == true' "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --dry-run --json >"$TMPROOT/dispatch-herdr-dry-run.json"
json_assert 'dispatch herdr dry-run emits adapter plan' "$TMPROOT/dispatch-herdr-dry-run.json" 'j["action"] == "dry_run" && j["adapter"]["schema_version"] == "orbit-herdr-dispatch-v1" && j["adapter"]["submit_delay_seconds"] > 0 && j["adapter"]["commands"][0][0,4] == ["herdr", "pane", "send-text", "pane-123"] && j["adapter"]["commands"][0][4].include?(File.expand_path(ARGV[2])) && j["adapter"]["commands"][1] == ["herdr", "pane", "send-keys", "pane-123", "Enter"]' "$TASK"
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
expect_failure 'dispatch herdr requires pane' "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --json
expect_failure 'dispatch rejects unknown target instance' "$CLI" dispatch --task "$TASK" --to missing --json

mkdir -p docs
printf '%s\n' '# Review Rule' '- Check project-specific review constraints.' >docs/review-rule.md
cp .orbit/roles.yaml "$TMPROOT/roles-before-rules.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["roles"]["reviewer"]["rules"]=["docs/review-rule.md"]; File.write(p, YAML.dump(y))' .orbit/roles.yaml
ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/rules-resolution.json" >"$TMPROOT/rules-resolution.stdout" 2>"$TMPROOT/rules-resolution.err"
test ! -s "$TMPROOT/rules-resolution.err"
cmp "$TMPROOT/rules-resolution.json" "$TMPROOT/rules-resolution.stdout"
json_assert 'rules resolve includes default, project, task, and rule pack sources' "$TMPROOT/rules-resolution.json" 'j["schema_version"] == "orbit-rule-resolution-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["sources"]["orbit_default"].any? { |r| r["path"] == "SKILL.md" && r["exists"] == true } && j["sources"]["orbit_default"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" && r["load_policy"] == "required" } && j["sources"]["project_rules"].any? { |r| r["path"] == "docs/review-rule.md" && r["exists"] == true } && j["sources"]["task_rules"]["path"] == File.expand_path(ARGV[2]) && j["sources"]["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }' "$TASK"
ORBIT_INSTANCE=reviewer "$CLI" rules print-context --task "$TASK" --json --output "$TMPROOT/rules-context.json" >"$TMPROOT/rules-context.stdout" 2>"$TMPROOT/rules-context.err"
test ! -s "$TMPROOT/rules-context.err"
cmp "$TMPROOT/rules-context.json" "$TMPROOT/rules-context.stdout"
json_assert 'rules print-context emits ordered default project task and pack context' "$TMPROOT/rules-context.json" 'j["schema_version"] == "orbit-rules-context-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["load_model"]["default_rules_always_loaded"] == true && j["load_model"]["project_rules_are_additive"] == true && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "SKILL.md" && r["required"] == true && r["exists"] == true } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "references/runtime/core-operating-model.md" && r["required"] == false } && j["load_order"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" && r["required"] == true && r["exists"] == true } && j["load_order"].any? { |r| r["source"] == "task_rules" && r["path"] == File.expand_path(ARGV[2]) && r["required"] == true } && j["load_order"].any? { |r| r["source"] == "rule_packs" && r["id"] == "brooks-review" && r["required"] == false } && j["required_files"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" } && j["rule_resolution"]["schema_version"] == "orbit-rule-resolution-v1"' "$TASK"
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
cat >"$TMPROOT/review-report.md" <<'REPORT'
APPROVED
review report confirms the implementation is acceptable.
REPORT
"$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-report.md" --json >"$TMPROOT/evidence-from-review-report.json"
json_assert 'evidence from-report imports markdown review verdict' "$TMPROOT/evidence-from-review-report.json" 'j["schema_version"] == "orbit-evidence-import-v1" && j["record"]["kind"] == "review" && j["record"]["status"] == "pass" && j["record"]["source_report"] == File.expand_path(ARGV[2])' "$TMPROOT/review-report.md"
printf '%s\n' 'APPROVED_WITH_NOTES' 'notes are not an automatic pass token.' >"$TMPROOT/review-with-notes-report.md"
expect_failure 'evidence from-report rejects non-contract verdict token' "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-with-notes-report.md" --json
"$CLI" wait-gate --task "$TASK" --evidence "$APPEND_EVIDENCE" --json >"$TMPROOT/wait-gate-review-pass.json"
json_assert 'wait-gate passes after imported review evidence' "$TMPROOT/wait-gate-review-pass.json" 'j["schema_version"] == "orbit-gate-status-v1" && j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true }'
TEST_TASK="$TMPROOT/test-task.yaml"
"$CLI" new-task --target-role tester --task-type implementation_test --output "$TEST_TASK" >/dev/null
TEST_EVIDENCE="$TMPROOT/test-evidence.json"
"$CLI" evidence init --output "$TEST_EVIDENCE" >/dev/null
cat >"$TMPROOT/test-report.yaml" <<'REPORT'
kind: test
status: PASS
summary: Browser scenarios passed.
REPORT
"$CLI" evidence from-report --file "$TEST_EVIDENCE" --report "$TMPROOT/test-report.yaml" --json >"$TMPROOT/evidence-from-test-report.json"
json_assert 'evidence from-report imports structured test verdict' "$TMPROOT/evidence-from-test-report.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "pass" && j["record"]["summary"] == "Browser scenarios passed."'
"$CLI" wait-gate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json >"$TMPROOT/wait-gate-test-pass.json"
json_assert 'wait-gate passes after imported test evidence' "$TMPROOT/wait-gate-test-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "test" && g["passed"] == true }'
OPTIONAL_GATE_TASK="$TMPROOT/optional-gate-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$OPTIONAL_GATE_TASK" >/dev/null
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"].each { |g| g["required"]=false if g["kind"]=="test" }; File.write(p, YAML.dump(y))' "$OPTIONAL_GATE_TASK"
OPTIONAL_GATE_EVIDENCE="$TMPROOT/optional-gate-evidence.json"
"$CLI" evidence init --output "$OPTIONAL_GATE_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$OPTIONAL_GATE_EVIDENCE" --kind review --status pass --summary "required review passed" >/dev/null
"$CLI" wait-gate --task "$OPTIONAL_GATE_TASK" --evidence "$OPTIONAL_GATE_EVIDENCE" --json >"$TMPROOT/wait-gate-optional-pass.json"
json_assert 'wait-gate ignores optional gates' "$TMPROOT/wait-gate-optional-pass.json" 'j["ready"] == true && j["gates"].map { |g| g["kind"] } == ["review"]'
expect_failure 'evidence init refuses overwrite' "$CLI" evidence init --output "$APPEND_EVIDENCE"
"$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "review passed" >"$TMPROOT/evidence-add-review.out" 2>"$TMPROOT/evidence-add-review.err"
test ! -s "$TMPROOT/evidence-add-review.err"
"$CLI" evidence show --file "$APPEND_EVIDENCE" --json >"$TMPROOT/evidence-show.json" 2>"$TMPROOT/evidence-show.err"
test ! -s "$TMPROOT/evidence-show.err"
json_assert 'evidence add appends review record' "$TMPROOT/evidence-show.json" 'j["records"].length >= 2 && j["records"].last["kind"] == "review" && j["records"].last["status"] == "pass" && j["records"].last["summary"] == "review passed" && j["records"].last["created_at"].is_a?(String)'
"$CLI" evidence add --file "$APPEND_EVIDENCE" --kind command --status partial --summary "command evidence retained" >/dev/null
json_assert 'evidence add preserves history' "$APPEND_EVIDENCE" 'j["records"].length >= 3 && j["records"][-2]["kind"] == "review" && j["records"][-1]["kind"] == "command"'
expect_failure 'evidence add rejects invalid status' "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status maybe --summary "bad status"
expect_failure 'evidence add rejects empty summary' "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary ""
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
"$CLI" evidence add --file "$LATEST_FAIL_EVIDENCE" --kind review --status pass --summary "review passed first" >/dev/null
"$CLI" evidence add --file "$LATEST_FAIL_EVIDENCE" --kind review --status fail --summary "review failed latest" >/dev/null
expect_failure 'validate uses latest review fail verdict' "$CLI" validate --task "$TASK" --evidence "$LATEST_FAIL_EVIDENCE" --json

LATEST_PASS_EVIDENCE="$TMPROOT/latest-pass-evidence.json"
"$CLI" evidence init --output "$LATEST_PASS_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$LATEST_PASS_EVIDENCE" --kind review --status fail --summary "review failed first" >/dev/null
"$CLI" evidence add --file "$LATEST_PASS_EVIDENCE" --kind review --status pass --summary "review passed latest" >/dev/null
"$CLI" validate --task "$TASK" --evidence "$LATEST_PASS_EVIDENCE" --json >"$TMPROOT/latest-pass-validate.json"
json_assert 'validate uses latest review pass verdict' "$TMPROOT/latest-pass-validate.json" 'j["valid"] == true'

PARTIAL_EVIDENCE="$TMPROOT/partial-evidence.json"
"$CLI" evidence init --output "$PARTIAL_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$PARTIAL_EVIDENCE" --kind review --status partial --summary "review partially passed" >/dev/null
expect_failure 'validate rejects partial verdict for done gate' "$CLI" validate --task "$TASK" --evidence "$PARTIAL_EVIDENCE" --json

INVALID_ONLY_EVIDENCE="$TMPROOT/invalid-only-evidence.json"
"$CLI" evidence init --output "$INVALID_ONLY_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$INVALID_ONLY_EVIDENCE" --kind review --status invalid --summary "invalid review evidence" >/dev/null
expect_failure 'validate ignores invalid-only verdict' "$CLI" validate --task "$TASK" --evidence "$INVALID_ONLY_EVIDENCE" --json

INVALID_LATEST_EVIDENCE="$TMPROOT/invalid-latest-evidence.json"
"$CLI" evidence init --output "$INVALID_LATEST_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$INVALID_LATEST_EVIDENCE" --kind review --status pass --summary "review passed before invalid" >/dev/null
"$CLI" evidence add --file "$INVALID_LATEST_EVIDENCE" --kind review --status invalid --summary "invalid latest ignored" >/dev/null
"$CLI" validate --task "$TASK" --evidence "$INVALID_LATEST_EVIDENCE" --json >"$TMPROOT/invalid-latest-validate.json"
json_assert 'validate ignores invalid latest verdict' "$TMPROOT/invalid-latest-validate.json" 'j["valid"] == true'

TEST_ONLY_EVIDENCE="$TMPROOT/test-only-evidence.json"
"$CLI" evidence init --output "$TEST_ONLY_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$TEST_ONLY_EVIDENCE" --kind test --status pass --summary "test passed only" >/dev/null
expect_failure 'validate review task rejects test-only evidence' "$CLI" validate --task "$TASK" --evidence "$TEST_ONLY_EVIDENCE" --json

BAD_TIME_EVIDENCE="$TMPROOT/bad-time-evidence.json"
"$CLI" evidence init --output "$BAD_TIME_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$BAD_TIME_EVIDENCE" --kind review --status pass --summary "bad time evidence" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"][0]["created_at"]="not-a-time"; File.write(p, JSON.pretty_generate(j))' "$BAD_TIME_EVIDENCE"
expect_failure 'validate fails unsortable evidence time' "$CLI" validate --task "$TASK" --evidence "$BAD_TIME_EVIDENCE" --json

expect_failure 'state start rejects owner role conflict' env ORBIT_ROLE=lead "$CLI" state start --task "$TASK" --owner-role reviewer
ORBIT_ROLE=lead "$CLI" state start --task "$TASK" >"$TMPROOT/state-start.out" 2>"$TMPROOT/state-start.err"
test ! -s "$TMPROOT/state-start.err"
"$CLI" state show --json >"$TMPROOT/state-working.json"
json_assert 'state start infers owner and binds task' "$TMPROOT/state-working.json" 'j["phase"] == "working" && j["owner_role"] == "lead" && j["current_task"] == File.expand_path(ARGV[2]) && j["history"].last["event"] == "start"' "$TASK"
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
"$CLI" evidence add --file "$FAIL_EVIDENCE" --kind review --status fail --summary "review failed" >/dev/null
expect_failure 'state transition blocks done on fail evidence' "$CLI" state transition --to done --evidence "$FAIL_EVIDENCE"
"$CLI" state transition --to done --evidence "$REVIEW_JUDGMENT_EVIDENCE" >"$TMPROOT/state-done.out" 2>"$TMPROOT/state-done.err"
test ! -s "$TMPROOT/state-done.err"
"$CLI" state show --json >"$TMPROOT/state-done.json"
json_assert 'state transition to done records evidence' "$TMPROOT/state-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2]) && j["history"].last["to"] == "done"' "$REVIEW_JUDGMENT_EVIDENCE"
cp .orbit/loop-state.yaml "$TMPROOT/review-done-state.yaml"

IMPL_TASK="$TMPROOT/implementation-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$IMPL_TASK" >/dev/null
yaml_assert 'new-task adds implementation review/test gates' "$IMPL_TASK" 'j["gates"].is_a?(Array) && j["gates"].any? { |g| g["kind"] == "review" && g["roles"].include?("reviewer") } && j["gates"].any? { |g| g["kind"] == "test" && g["roles"].include?("tester") }'
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
expect_failure 'state transition blocks done until implementation gates pass' "$CLI" state transition --to done --evidence "$IMPL_EVIDENCE"
"$CLI" evidence add --file "$IMPL_EVIDENCE" --kind review --status pass --summary "review gate passed" >/dev/null
"$CLI" evidence add --file "$IMPL_EVIDENCE" --kind test --status pass --summary "test gate passed" >/dev/null
"$CLI" state transition --to done --evidence "$IMPL_EVIDENCE" >"$TMPROOT/implementation-done.out" 2>"$TMPROOT/implementation-done.err"
test ! -s "$TMPROOT/implementation-done.err"
"$CLI" state show --json >"$TMPROOT/implementation-done.json"
json_assert 'state transition allows done with implementation pass evidence' "$TMPROOT/implementation-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2])' "$IMPL_EVIDENCE"
"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-valid.json" 2>"$TMPROOT/audit-valid.err"
test ! -s "$TMPROOT/audit-valid.err"
json_assert 'audit passes done state with matching evidence' "$TMPROOT/audit-valid.json" 'j["schema_version"] == "orbit-audit-v1" && j["trust_level"]["mode"] == "audit_only" && j["done_ready"] == true && j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == false && j["blocking_findings"].empty? && j["warnings"].any? { |e| e["source"] == "state_file.artifacts.handoff_packet" && e["remediation"].is_a?(String) } && j["issues"].length == j["blocking_findings"].length + j["warnings"].length && j["validation"]["valid"] == true'
"$CLI" handoff --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --output "$TMPROOT/implementation-handoff.json" --record-state --json >"$TMPROOT/implementation-handoff.stdout"
json_assert 'handoff can write artifact and record it in state' "$TMPROOT/implementation-handoff.json" 'j["schema_version"] == "orbit-handoff-v1" && j["blocking_errors"].empty? && j["judgment_summary"]["review_judgment"]["present"] == true && j["judgment_summary"]["review_judgment"]["source"] == "latest_evidence_record" && j["judgment_summary"]["test_judgment"]["present"] == true && j["worktree_safety_summary"]["status"] == "not_git"'
yaml_assert 'handoff record-state stores artifact path' .orbit/loop-state.yaml 'j["artifacts"]["handoff_packet"] == File.expand_path(ARGV[2]) && j["history"].last["event"] == "handoff"' "$TMPROOT/implementation-handoff.json"
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
json_assert 'handoff outputs valid packet' "$TMPROOT/handoff-valid.json" 'j["schema_version"] == "orbit-handoff-v1" && j["target_role"] == "reviewer" && j["current_phase"] == "done" && j["required_action"] == "none" && j["next_action"] == "none" && j["blocking_errors"].empty? && j["validation_summary"]["valid"] == true && j["audit_summary"]["done_ready"] == true && j["tools_summary"]["preferred_transport"].is_a?(String) && j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["payload"]["required_action"] == "none" && j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" } && j["rule_packs"].any? { |p| p["category"] == "audit" && p["id"] == "orbit-drift" } && j["rule_resolution_summary"]["present"] == true && j["rule_resolution_summary"]["valid"] == true && j["rule_resolution_summary"]["resolved_role"] == "reviewer" && j["judgment_summary"]["review_judgment"]["present"] == true && j["evidence_summary"]["records"] >= 1'
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
"$CLI" evidence add --file "$APPEND_EVIDENCE" --kind test --status pass --summary "test passed" >/dev/null
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

cp "$EVIDENCE" "$TMPROOT/invalid-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["verdict"]["status"]="maybe"; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/invalid-evidence.json"
expect_failure 'validate fails invalid evidence verdict' "$CLI" validate --evidence "$TMPROOT/invalid-evidence.json" --json
expect_failure 'validate rejects missing task option value' "$CLI" validate --task --json
expect_failure 'validate rejects missing evidence option value' "$CLI" validate --evidence --json
expect_failure 'validate rejects missing state option value' "$CLI" validate --state --json

printf 'REAL_TESTS_PASS count=%s tmp=%s\n' "$PASS_COUNT" "$TMPROOT"

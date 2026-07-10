# ---------------------------------------------------------------------------
# High-level task workflow, concise rule context, and uniform command help
# ---------------------------------------------------------------------------

TASK_WORKFLOW_PROJECT="$TMPROOT/task-workflow-project"
mkdir -p "$TASK_WORKFLOW_PROJECT"
TASK_WORKFLOW_ORIGINAL_DIR=$PWD
cd "$TASK_WORKFLOW_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

"$CLI" init --operation-mode solo >/dev/null
mkdir -p .orbit/tasks
"$CLI" task draft --task-type implementation --output .orbit/tasks/high-level.yaml --json >task-draft.json
json_assert 'task draft emits a concise structured next-step packet' task-draft.json 'j["schema_version"] == "orbit-task-draft-v1" && j["task"] == ".orbit/tasks/high-level.yaml" && j["risk_level"] == "standard" && j["next"].include?("orbit task start")'

if ORBIT_INSTANCE=lead-main "$CLI" task start --task .orbit/tasks/high-level.yaml --json >not-ready.json 2>not-ready.err; then
  printf 'FAIL task start accepted a placeholder execution contract\n' >&2
  exit 1
fi
test ! -e .orbit/evidence/high-level.json
test ! -d .orbit/rules
yaml_assert 'failed task start performs no workflow writes' .orbit/loop-state.yaml 'j["current_task"].nil? && j["phase"] == "idle"'

make_task_execution_ready .orbit/tasks/high-level.yaml
ORBIT_INSTANCE=lead-main "$CLI" task start --task .orbit/tasks/high-level.yaml --json >task-start.json
json_assert 'task start completes validation revision evidence rules and state in one command' task-start.json 'j["schema_version"] == "orbit-task-start-v1" && j["revision_id"].match?(/\Ar1-/) && j["revision_number"] == 1 && j["phase"] == "working" && j["evidence_created"] == true && j["commands_required"] == 1 && j["workflow_commands_from_init"] <= 5 && File.file?(j["evidence"]) && File.file?(j["rules_resolution"])'
yaml_assert 'task start freezes the contract and starts portable loop state' .orbit/loop-state.yaml 'j["current_task"] == ".orbit/tasks/high-level.yaml" && j["task_id"].match?(/\Aotask_/) && j["task_revision_id"].match?(/\Ar1-/) && j["phase"] == "working"'
json_assert 'task start attaches its current task-bound role rule resolution' .orbit/evidence/high-level.json 'r=j["rule_resolution"]; j["task_id"].match?(/\Aotask_/) && r["task_id"] == j["task_id"] && r["valid"] == true && r["resolved_role"] == "lead" && r["resolved_instance"] == "lead-main" && r["file"].include?("/.orbit/rules/high-level-r1-")'
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file .orbit/evidence/high-level.json --kind implementation --status pass --summary 'High-level workflow implementation fixture.' --task .orbit/tasks/high-level.yaml --changed-file lib/high-level.rb --verification 'high-level fixture passed' >/dev/null
ORBIT_INSTANCE=lead-main "$CLI" state transition --to implemented_not_independently_accepted --evidence .orbit/evidence/high-level.json >/dev/null
yaml_assert 'task-start evidence remains valid during later state transitions' .orbit/loop-state.yaml 'j["phase"] == "implemented_not_independently_accepted" && j.dig("artifacts", "evidence_file") == ".orbit/evidence/high-level.json"'

ORBIT_INSTANCE=lead-main "$CLI" rules print-context --task .orbit/tasks/high-level.yaml >rules-context.txt
test "$(wc -l <rules-context.txt | tr -d ' ')" -le 10
test "$(grep -c '^Rules context=' rules-context.txt)" = "1"
test "$(grep -c '^Required files (' rules-context.txt)" = "1"
test "$(grep -c '^Conflicts: none$' rules-context.txt)" = "1"
if grep -q 'schema_version' rules-context.txt; then
  printf 'FAIL concise rules context leaked the full protocol\n' >&2
  exit 1
fi
pass 'rules print-context defaults to active required files hash and conflicts only'

ORBIT_INSTANCE=lead-main "$CLI" rules print-context --task .orbit/tasks/high-level.yaml --output .orbit/rules/high-level-context.json --json >rules-context-full.json
json_assert 'rules print-context keeps the complete protocol behind json' rules-context-full.json 'j["schema_version"] == "orbit-rules-context-v1" && j["required_files"].all? { |f| f["required"] == true && f["dedupe_status"] == "active" } && j["context_hash"].match?(/\A[0-9a-f]{64}\z/)'
cmp -s rules-context-full.json .orbit/rules/high-level-context.json
pass 'rules context output artifact remains the full machine record'

"$CLI" task draft --task-type implementation --output .orbit/tasks/human.yaml >/dev/null
make_task_execution_ready .orbit/tasks/human.yaml
expect_failure 'a second same-shaped task cannot reuse nonempty evidence from the first task' env ORBIT_INSTANCE=lead-main "$CLI" task start --task .orbit/tasks/human.yaml --evidence .orbit/evidence/high-level.json --json
yaml_assert 'cross-task evidence rejection happens before revision freeze' .orbit/tasks/human.yaml 'j["revision_id"] == "draft" && j["revision_number"] == 0'
ORBIT_INSTANCE=lead-main "$CLI" task start --task .orbit/tasks/human.yaml >task-start-human.txt
test "$(wc -l <task-start-human.txt | tr -d ' ')" -le 3
test "$(grep -c '^Started ' task-start-human.txt)" = "1"
if grep -q 'schema_version' task-start-human.txt; then
  printf 'FAIL human task start leaked the full protocol\n' >&2
  exit 1
fi
pass 'task start human output stays within one concise screen'
json_assert 'separate same-shaped tasks never share a task-bound rule cache entry' .orbit/evidence/human.json 'first=JSON.parse(File.read(".orbit/evidence/high-level.json")); j.dig("rule_resolution", "file") != first.dig("rule_resolution", "file") && j.dig("rule_resolution", "task").end_with?("/.orbit/tasks/human.yaml")'
yaml_assert 'same-shaped tasks receive distinct immutable identities and revision ids' .orbit/tasks/human.yaml 'first=YAML.safe_load(File.read(".orbit/tasks/high-level.yaml"), aliases: true); j["task_id"] != first["task_id"] && j["revision_id"] != first["revision_id"]'

for command in audit artifact bind-pane classify-intent compact-evidence dispatch docs evidence handoff hook init instances new-task notice next revision rules runtime start state status task test-hook tools validate wait-gate whoami version; do
  if ! "$CLI" "$command" --help >command-help.txt 2>command-help.err; then
    printf 'FAIL %s --help did not exit successfully\n' "$command" >&2
    exit 1
  fi
  if test -s command-help.err; then
    printf 'FAIL %s --help wrote an error\n' "$command" >&2
    exit 1
  fi
done
pass 'all first-level commands expose a uniform successful help entry'

"$CLI" task draft --help >/dev/null
"$CLI" task start --help >/dev/null
"$CLI" rules print-context --help >/dev/null
pass 'high-level task and concise rules subcommands expose help'

cd "$TASK_WORKFLOW_ORIGINAL_DIR"

# ---------------------------------------------------------------------------
# Explicit task revisions, selective invalidation, cache, and durable knowledge
# ---------------------------------------------------------------------------

REVISION_PROJECT="$TMPROOT/revision-knowledge-project"
mkdir -p "$REVISION_PROJECT"
REVISION_ORIGINAL_DIR=$PWD
cd "$REVISION_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

"$CLI" init --operation-mode solo >/dev/null
mkdir -p .orbit/tasks .orbit/evidence .orbit/test-artifacts
"$CLI" new-task --task-type implementation --output .orbit/tasks/revision-task.yaml >/dev/null
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["gates"] << {"kind"=>"test", "roles"=>["tester"], "required"=>true, "pass_condition"=>"revision regression test passes"}
  y["test_level"]="repo_regression"
  File.write(p, YAML.dump(y))
' .orbit/tasks/revision-task.yaml
make_task_execution_ready .orbit/tasks/revision-task.yaml
yaml_assert 'new task starts with a draft revision contract' .orbit/tasks/revision-task.yaml 'j["revision_id"] == "draft" && j["revision_number"] == 0 && j["revision_history"] == []'
ruby --disable-gems -ryaml -e '
  ORBIT_ROOT = File.expand_path(ARGV.shift)
  require File.expand_path(ARGV.shift)
  template = YAML.safe_load(File.read(ARGV.shift), aliases: true)
  semantic_fields = template.keys - REVISION_METADATA_FIELDS
  missing = semantic_fields - REVISION_FIELD_CHANGE_TYPES.keys
  abort("unmapped template fields: #{missing.join(", ")}") unless missing.empty?
' "$SKILL_ROOT" "$SKILL_ROOT/lib/orbit/cli.rb" "$SKILL_ROOT/skills/orbit/assets/templates/task.yaml"
pass 'every task template field has an explicit revision change-type mapping'
ORBIT_INSTANCE=lead-main "$CLI" state start --task .orbit/tasks/revision-task.yaml >/dev/null
yaml_assert 'state start freezes revision one and persists portable task paths' .orbit/tasks/revision-task.yaml 'j["revision_id"].match?(/\Ar1-[0-9a-f]{12}\z/) && j["revision_number"] == 1 && j["revision_signature"].match?(/\A[0-9a-f]{64}\z/) && j.dig("revision_history", 0, "reason") == "execution_start"'
yaml_assert 'loop state binds the frozen revision using project-relative paths' .orbit/loop-state.yaml 'j["current_task"] == ".orbit/tasks/revision-task.yaml" && j.dig("artifacts", "task_file") == ".orbit/tasks/revision-task.yaml" && j["task_revision_id"].match?(/\Ar1-/) && j["task_revision_number"] == 1'

printf 'revision implementation output\n' >.orbit/test-artifacts/revision-output.log
"$CLI" artifact inspect --path .orbit/test-artifacts/revision-output.log --task .orbit/tasks/revision-task.yaml --id revision-implementation-output --producer-command 'revision fixture implementation' --lifecycle transient --json >revision-artifact-ref.json
"$CLI" evidence init --output .orbit/evidence/revision-task.json >/dev/null
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file .orbit/evidence/revision-task.json --kind implementation --status pass --summary 'Revision one implementation is complete.' --task .orbit/tasks/revision-task.yaml --changed-file lib/revision-feature.rb --verification 'revision fixture passed' --artifact-ref @revision-artifact-ref.json >/dev/null
write_review_pass_report revision-review.yaml 'Revision one outcome review passed.' 'manual:reviewer:revision-one'
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file .orbit/evidence/revision-task.json --report revision-review.yaml --task .orbit/tasks/revision-task.yaml --json >/dev/null
write_test_pass_report revision-test.yaml 'Revision one regression test passed.' 'manual:tester:revision-one'
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file .orbit/evidence/revision-task.json --report revision-test.yaml --task .orbit/tasks/revision-task.yaml --json >/dev/null
json_assert 'implementation review and test evidence bind explicit revision one' .orbit/evidence/revision-task.json 'records=j["records"].select { |r| %w[implementation review test].include?(r["kind"]) }; records.length == 3 && records.all? { |r| r["task_revision_id"].match?(/\Ar1-/) && r["task_revision_number"] == 1 }'
"$CLI" wait-gate --task .orbit/tasks/revision-task.yaml --evidence .orbit/evidence/revision-task.json --json >revision-one-gate.json
json_assert 'revision one closes its review and test gates' revision-one-gate.json 'j["ready"] == true && j.dig("gate_summary", "passed").sort == ["review", "test"]'

ORBIT_INSTANCE=lead-main "$CLI" rules resolve --task .orbit/tasks/revision-task.yaml --json >revision-rules-miss.json
ORBIT_INSTANCE=lead-main "$CLI" rules resolve --task .orbit/tasks/revision-task.yaml --json >revision-rules-hit.json
json_assert 'rules resolution caches one artifact per revision role and rules hash' revision-rules-hit.json 'first=JSON.parse(File.read("revision-rules-miss.json")); j.dig("cache", "status") == "hit" && first.dig("cache", "status") == "miss" && j.dig("cache", "key") == first.dig("cache", "key") && j.dig("cache", "identity", "task_revision").match?(/\Ar1-/)'

ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["source_documents"]=["README.md"]; File.write(p, YAML.dump(y))' .orbit/tasks/revision-task.yaml
if "$CLI" validate --task .orbit/tasks/revision-task.yaml --evidence .orbit/evidence/revision-task.json --json >revision-drift.json; then
  printf 'FAIL direct frozen task edit unexpectedly validated\n' >&2
  exit 1
fi
json_assert 'direct frozen task edits require a declared revision' revision-drift.json 'j["errors"].any? { |e| e["source"] == "task_file.revision_signature" && e["message"].include?("source_documents") }'
"$CLI" revision create --task .orbit/tasks/revision-task.yaml --reason 'Add a durable source reference.' --change-type documentation --json >revision-two.json
json_assert 'documentation revision records why it changed without invalidating gates' revision-two.json 'r=j["revision"]; r["number"] == 2 && r["revision_id"].match?(/\Ar2-/) && r["changed_fields"] == ["source_documents"] && r["invalidated_evidence"] == [] && j["state"] == ".orbit/loop-state.yaml"'
yaml_assert 'loop state advances to revision two' .orbit/loop-state.yaml 'j["task_revision_number"] == 2 && j["task_revision_id"].match?(/\Ar2-/) && j["history"].last["event"] == "revision"'
"$CLI" wait-gate --task .orbit/tasks/revision-task.yaml --evidence .orbit/evidence/revision-task.json --json >revision-two-gate.json
json_assert 'documentation-only revision preserves unaffected review and test evidence' revision-two-gate.json 'j["ready"] == true && j["gates"].all? { |g| g["passed"] == true && g.dig("latest", "task_revision_number") == 1 }'
ORBIT_INSTANCE=lead-main "$CLI" rules resolve --task .orbit/tasks/revision-task.yaml --json >revision-two-rules-miss.json
ORBIT_INSTANCE=lead-main "$CLI" rules resolve --task .orbit/tasks/revision-task.yaml --json >revision-two-rules-hit.json
json_assert 'new revision receives a new cache key and then reuses it' revision-two-rules-hit.json 'r1=JSON.parse(File.read("revision-rules-hit.json")); miss=JSON.parse(File.read("revision-two-rules-miss.json")); miss.dig("cache", "status") == "miss" && j.dig("cache", "status") == "hit" && j.dig("cache", "key") != r1.dig("cache", "key")'

ORBIT_INSTANCE=lead-main "$CLI" handoff --task .orbit/tasks/revision-task.yaml --state .orbit/loop-state.yaml --evidence .orbit/evidence/revision-task.json --record-state --json >revision-handoff.stdout.json
test -f .orbit/handoffs/revision-task.json
pass 'handoff defaults to the canonical plural directory'
json_assert 'handoff packet and loop state persist project-relative paths' .orbit/handoffs/revision-task.json 'j["task"] == ".orbit/tasks/revision-task.yaml" && j.dig("delivery", "payload", "state") == ".orbit/loop-state.yaml" && j.dig("delivery", "payload", "evidence") == ".orbit/evidence/revision-task.json" && j.dig("task_revision", "revision_number") == 2 && !JSON.generate(j).include?(Dir.pwd + "/")'
yaml_assert 'record-state stores the canonical relative handoff path' .orbit/loop-state.yaml 'j.dig("artifacts", "handoff_packet") == ".orbit/handoffs/revision-task.json" && j["history"].last["handoff_packet"] == ".orbit/handoffs/revision-task.json"'
expect_failure 'singular .orbit/handoff directory is rejected' env ORBIT_INSTANCE=lead-main "$CLI" handoff --task .orbit/tasks/revision-task.yaml --state .orbit/loop-state.yaml --evidence .orbit/evidence/revision-task.json --output .orbit/handoff/legacy.json --json

"$CLI" compact-evidence --task .orbit/tasks/revision-task.yaml --evidence .orbit/evidence/revision-task.json --handoff .orbit/handoffs/revision-task.json --dry-run-cleanup --json >revision-compact-dry-run.json
test -f orbit-summaries/revision-task.json
pass 'compact-evidence writes one default versionable summary per task'
json_assert 'durable summary keeps portable refs and plans transient cleanup' revision-compact-dry-run.json 'j["durable_output"] == "orbit-summaries/revision-task.json" && j["task_revision_number"] == 2 && j.dig("cleanup", "dry_run") == true && j.dig("cleanup", "planned").include?(".orbit/test-artifacts/revision-output.log") && !JSON.generate(j).include?(Dir.pwd + "/")'
test -f .orbit/test-artifacts/revision-output.log
"$CLI" compact-evidence --task .orbit/tasks/revision-task.yaml --evidence .orbit/evidence/revision-task.json --handoff .orbit/handoffs/revision-task.json --cleanup-transient --json >revision-compact-cleanup.json
test ! -f .orbit/test-artifacts/revision-output.log
test "$(find orbit-summaries -type f -name 'revision-task.json' | wc -l | tr -d ' ')" = "1"
json_assert 'cleanup removes only structured transient runtime artifacts after compaction' revision-compact-cleanup.json 'j.dig("cleanup", "removed") == [".orbit/test-artifacts/revision-output.log"] && j.dig("transient_artifacts", "large_artifacts_not_embedded") == true'

ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["acceptance"] << "Revised acceptance needs fresh independent evidence."; File.write(p, YAML.dump(y))' .orbit/tasks/revision-task.yaml
expect_failure 'revision declaration cannot misclassify an acceptance change as documentation' "$CLI" revision create --task .orbit/tasks/revision-task.yaml --reason 'Wrong type.' --change-type documentation --json
"$CLI" revision create --task .orbit/tasks/revision-task.yaml --reason 'Acceptance semantics changed.' --change-type acceptance --json >revision-three.json
json_assert 'acceptance revision precisely invalidates implementation and independent gates' revision-three.json 'r=j["revision"]; r["number"] == 3 && r["changed_fields"] == ["acceptance"] && %w[implementation review test].all? { |kind| r["invalidated_evidence"].include?(kind) }'
if "$CLI" wait-gate --task .orbit/tasks/revision-task.yaml --evidence .orbit/evidence/revision-task.json --json >revision-three-gate.json; then
  printf 'FAIL acceptance revision unexpectedly reused old gates\n' >&2
  exit 1
fi
json_assert 'acceptance revision makes old review and test evidence stale' revision-three-gate.json 'j["ready"] == false && j["gates"].all? { |g| g["passed"] == false && g["blocking_reason"] == "stale_verdict" }'

ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["execution_contract"]["source"]="revision-contract-change"; File.write(p, YAML.dump(y))' .orbit/tasks/revision-task.yaml
expect_failure 'execution_contract revision cannot be mislabeled as documentation' "$CLI" revision create --task .orbit/tasks/revision-task.yaml --reason 'Wrong execution mapping.' --change-type documentation --json
"$CLI" revision create --task .orbit/tasks/revision-task.yaml --reason 'Execution authority contract metadata changed.' --change-type runtime --json >revision-four.json
json_assert 'execution_contract uses runtime mapping and invalidates implementation plus gates' revision-four.json 'r=j["revision"]; r["changed_fields"] == ["execution_contract"] && %w[implementation review test release rules].all? { |kind| r["invalidated_evidence"].include?(kind) }'

ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["future_contract"]={"enabled"=>true}; File.write(p, YAML.dump(y))' .orbit/tasks/revision-task.yaml
expect_failure 'unknown future task fields fail closed until explicitly mapped' "$CLI" revision create --task .orbit/tasks/revision-task.yaml --reason 'Unknown contract.' --change-type runtime --json
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("future_contract"); File.write(p, YAML.dump(y))' .orbit/tasks/revision-task.yaml

ORIGINAL_TASK_ID=$(ruby --disable-gems -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0]), aliases: true)["task_id"]' .orbit/tasks/revision-task.yaml)
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_id"]="otask_000000000000000000000000"; File.write(p, YAML.dump(y))' .orbit/tasks/revision-task.yaml
expect_failure 'task_id remains immutable across revisions' "$CLI" revision create --task .orbit/tasks/revision-task.yaml --reason 'Identity rewrite.' --change-type runtime --json
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_id"]=ARGV[1]; File.write(p, YAML.dump(y))' .orbit/tasks/revision-task.yaml "$ORIGINAL_TASK_ID"

cd "$REVISION_ORIGINAL_DIR"

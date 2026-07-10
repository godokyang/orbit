# ---------------------------------------------------------------------------
# Structured artifact provenance and cross-gate fact binding
# ---------------------------------------------------------------------------

ARTIFACT_PROJECT="$TMPROOT/artifact-provenance-project"
mkdir -p "$ARTIFACT_PROJECT"
ARTIFACT_ORIGINAL_DIR=$PWD
cd "$ARTIFACT_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

"$CLI" init --operation-mode solo >/dev/null
mkdir -p .orbit/tasks .orbit/evidence .orbit/test-artifacts lib
"$CLI" new-task --task-type implementation --change-surface user_flow --output .orbit/tasks/artifact-task.yaml >/dev/null
make_task_execution_ready .orbit/tasks/artifact-task.yaml
yaml_assert 'real-path tasks enable structured artifact provenance by default' .orbit/tasks/artifact-task.yaml 'j.dig("artifact_provenance", "required") == true && j.dig("artifact_provenance", "require_implementation_facts") == true && j.dig("artifact_provenance", "require_gate_cross_reference") == true'

printf 'implemented fixture behavior\n' >lib/feature.rb
printf '{"result":"implementation verified"}\n' >.orbit/test-artifacts/implementation.json
"$CLI" artifact inspect \
  --path .orbit/test-artifacts/implementation.json \
  --task .orbit/tasks/artifact-task.yaml \
  --id implementation-output \
  --producer-command 'ruby fixture implementation verification' \
  --lifecycle durable --json >implementation-ref.json
json_assert 'artifact inspect binds bytes, producer, git head, task revision, and lifecycle' implementation-ref.json 'a=j["artifact"]; j["schema_version"] == "orbit-artifact-ref-v1" && a["path"] == ".orbit/test-artifacts/implementation.json" && a["sha256"].match?(/\A[0-9a-f]{64}\z/) && a["producer_command"].include?("verification") && a["git_head"] == "not_git" && a["task_revision"].start_with?("sha256:") && a["lifecycle"] == "durable"'
expect_failure 'artifact inspect rejects absolute artifact paths' "$CLI" artifact inspect --path "$ARTIFACT_PROJECT/.orbit/test-artifacts/implementation.json" --task .orbit/tasks/artifact-task.yaml --id absolute-output --producer-command fixture --json
ln -s /etc/hosts .orbit/test-artifacts/outside-link
expect_failure 'artifact inspect rejects project-relative symlinks that escape the project' "$CLI" artifact inspect --path .orbit/test-artifacts/outside-link --task .orbit/tasks/artifact-task.yaml --id escaped-output --producer-command fixture --json
rm .orbit/test-artifacts/outside-link

"$CLI" evidence init --output .orbit/evidence/artifact-valid.json >/dev/null
expect_failure 'implementation PASS requires facts and structured artifact refs' env ORBIT_INSTANCE=lead-main "$CLI" evidence add --file .orbit/evidence/artifact-valid.json --kind implementation --status pass --summary 'Implementation lacks provenance.' --task .orbit/tasks/artifact-task.yaml
ORBIT_INSTANCE=lead-main "$CLI" evidence add \
  --file .orbit/evidence/artifact-valid.json \
  --kind implementation --status pass \
  --summary 'Implementation and verification output are recorded.' \
  --task .orbit/tasks/artifact-task.yaml \
  --changed-file lib/feature.rb \
  --verification 'fixture implementation verification passed' \
  --artifact-ref @implementation-ref.json >/dev/null
json_assert 'implementation PASS records changed files, verification, and artifact validation' .orbit/evidence/artifact-valid.json 'r=j["records"].last; r.dig("implementation_facts", "changed_files") == ["lib/feature.rb"] && r.dig("implementation_facts", "verification", 0).include?("passed") && r.dig("artifact_validation", "valid") == true && r.dig("artifact_refs", 0, "id") == "implementation-output"'

printf 'fixture browser path passed\n' >.orbit/test-artifacts/user-flow.log
printf 'fixture screenshot bytes\n' >.orbit/test-artifacts/user-flow.png
"$CLI" artifact inspect \
  --path .orbit/test-artifacts/user-flow.log \
  --task .orbit/tasks/artifact-task.yaml \
  --id user-flow-output \
  --producer-command 'orbit test-hook run --journey fixture_real_path' \
  --json >test-ref.json

write_test_pass_report artifact-test.yaml 'The real user flow and its artifact passed.' 'manual:tester:artifact-valid'
ruby --disable-gems -rjson -ryaml -e '
  report_path, task_path, ref_path = ARGV
  report = YAML.safe_load(File.read(report_path), aliases: true)
  task = YAML.safe_load(File.read(task_path), aliases: true)
  ref = JSON.parse(File.read(ref_path)).fetch("artifact")
  report["test_level"] = task["test_level"]
  report["artifact_refs"] = [ref]
  report["implementation_artifact_refs"] = ["implementation-output"]
  report["user_outcomes"] = [{
    "journey_id"=>"fixture_real_path",
    "verdict"=>"pass",
    "actual_steps"=>[{"step"=>"Run the configured fixture path.", "result"=>"The fixture provider completed successfully."}],
    "observed_results"=>["The real-path fixture printed its success result."],
    "artifacts"=>{"screenshots"=>[".orbit/test-artifacts/user-flow.png"], "crash_logs"=>[], "network_requests"=>[], "media_state"=>[]},
    "environment"=>{"browser"=>{"name"=>"fixture-browser", "version"=>"1"}},
    "uncovered_paths"=>[],
    "test_hook"=>{"id"=>"fixture_real_path", "status"=>"pass", "command"=>["ruby", "-e", "puts \"fixture real path\""]}
  }]
  File.write(report_path, YAML.dump(report))
' artifact-test.yaml .orbit/tasks/artifact-task.yaml test-ref.json
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file .orbit/evidence/artifact-valid.json --report artifact-test.yaml --task .orbit/tasks/artifact-task.yaml --json >artifact-test-submit.json
json_assert 'test PASS remains pass with a current artifact and implementation cross-reference' artifact-test-submit.json 'r=j["record"]; r["status"] == "pass" && r.dig("artifact_validation", "valid") == true && r["implementation_artifact_refs"] == ["implementation-output"] && r.dig("artifact_refs", 0, "id") == "user-flow-output"'
write_review_pass_report artifact-review.yaml 'The implementation and its current output are independently traceable.' 'manual:reviewer:artifact-valid'
ruby --disable-gems -rjson -ryaml -e '
  report_path, ref_path = ARGV
  report = YAML.safe_load(File.read(report_path), aliases: true)
  report["artifact_refs"] = [JSON.parse(File.read(ref_path)).fetch("artifact")]
  report["implementation_artifact_refs"] = ["implementation-output"]
  File.write(report_path, YAML.dump(report))
' artifact-review.yaml test-ref.json
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file .orbit/evidence/artifact-valid.json --report artifact-review.yaml --task .orbit/tasks/artifact-task.yaml --json >artifact-review-submit.json
json_assert 'review PASS also cross-references the current implementation artifact' artifact-review-submit.json 'r=j["record"]; r["status"] == "pass" && r.dig("artifact_validation", "valid") == true && r["implementation_artifact_refs"] == ["implementation-output"]'
"$CLI" wait-gate --task .orbit/tasks/artifact-task.yaml --evidence .orbit/evidence/artifact-valid.json --json >artifact-valid-gate.json
json_assert 'current structured artifacts close the real-path gate' artifact-valid-gate.json 'j["ready"] == true && j["gates"].all? { |g| g["passed"] == true && g.dig("artifact_provenance", "valid") == true }'
"$CLI" validate --task .orbit/tasks/artifact-task.yaml --evidence .orbit/evidence/artifact-valid.json --json >artifact-valid-validate.json
json_assert 'validator accepts current artifact bytes and task revision' artifact-valid-validate.json 'j["valid"] == true'

"$CLI" evidence init --output .orbit/evidence/artifact-wrong-ref.json >/dev/null
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file .orbit/evidence/artifact-wrong-ref.json --kind implementation --status pass --summary 'Current implementation output.' --task .orbit/tasks/artifact-task.yaml --changed-file lib/feature.rb --verification 'fixture passed' --artifact-ref @implementation-ref.json >/dev/null
cp artifact-test.yaml artifact-wrong-ref.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["implementation_artifact_refs"]=["old-implementation-output"]; File.write(p, YAML.dump(y))' artifact-wrong-ref.yaml
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file .orbit/evidence/artifact-wrong-ref.json --report artifact-wrong-ref.yaml --task .orbit/tasks/artifact-task.yaml --json >artifact-wrong-ref-submit.json
json_assert 'gate evidence that references the wrong implementation is downgraded' artifact-wrong-ref-submit.json 'r=j["record"]; r["status"] == "partial" && r.dig("artifact_validation", "blocking_reason") == "missing_implementation_artifact_reference"'

cp .orbit/evidence/artifact-valid.json .orbit/evidence/artifact-mutated.json
printf 'overwritten by a later run\n' >.orbit/test-artifacts/user-flow.log
if "$CLI" wait-gate --task .orbit/tasks/artifact-task.yaml --evidence .orbit/evidence/artifact-mutated.json --json >artifact-mutated-gate.json; then
  printf 'FAIL mutated artifact unexpectedly supported PASS\n' >&2
  exit 1
fi
json_assert 'overwritten artifact bytes cannot continue supporting PASS' artifact-mutated-gate.json 'j["ready"] == false && j["gates"].any? { |g| g["blocking_reason"].to_s.include?("sha256 does not match") }'

rm .orbit/test-artifacts/user-flow.log
if "$CLI" wait-gate --task .orbit/tasks/artifact-task.yaml --evidence .orbit/evidence/artifact-mutated.json --json >artifact-missing-gate.json; then
  printf 'FAIL missing artifact unexpectedly supported PASS\n' >&2
  exit 1
fi
json_assert 'missing artifact file cannot continue supporting PASS' artifact-missing-gate.json 'j["ready"] == false && j["gates"].any? { |g| g["blocking_reason"] == "artifact file does not exist inside the project" }'

cp .orbit/tasks/artifact-task.yaml .orbit/tasks/artifact-stale-task.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["acceptance"] << "A changed revision requires new evidence."; File.write(p, YAML.dump(y))' .orbit/tasks/artifact-stale-task.yaml
if "$CLI" validate --task .orbit/tasks/artifact-stale-task.yaml --evidence .orbit/evidence/artifact-valid.json --json >artifact-stale-task.json; then
  printf 'FAIL stale task revision unexpectedly validated artifact PASS\n' >&2
  exit 1
fi
json_assert 'artifact from an older task revision cannot support PASS' artifact-stale-task.json 'j["valid"] == false && j["errors"].any? { |e| e["message"].include?("task_revision does not match") }'

cd "$ARTIFACT_ORIGINAL_DIR"

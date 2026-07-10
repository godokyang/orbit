# ---------------------------------------------------------------------------
# User journey contracts, project hooks, and real-path gate enforcement
# ---------------------------------------------------------------------------

JOURNEY_PROJECT="$TMPROOT/user-journey-project"
mkdir -p "$JOURNEY_PROJECT"
JOURNEY_ORIGINAL_DIR=$PWD
cd "$JOURNEY_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

"$CLI" init --operation-mode solo >/dev/null
mkdir -p .orbit/tasks .orbit/evidence .orbit/test-artifacts
"$CLI" new-task --task-type implementation --change-surface user_flow --output .orbit/tasks/journey-task.yaml >/dev/null
expect_failure 'real-path task is not execution-ready without a user journey' "$CLI" validate --task .orbit/tasks/journey-task.yaml --stage execution-ready --json
make_task_execution_ready .orbit/tasks/journey-task.yaml
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["user_journeys"]=[{
    "id"=>"upload_and_review",
    "actor"=>"collector",
    "surface"=>"android_to_web",
    "steps"=>["Upload media on Android.", "Open the processed result in Web."],
    "expected_observables"=>["Upload request succeeds.", "Processed media is visible in Web."],
    "required_evidence"=>"repo_regression",
    "test_hook"=>"android_to_web"
  }]
  File.write(p, YAML.dump(y))
' .orbit/tasks/journey-task.yaml
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y={
    "schema_version"=>"orbit-test-hooks-v1",
    "hooks"=>{
      "android_to_web"=>{
        "enabled"=>true,
        "surfaces"=>["android_to_web"],
        "command"=>["ruby", "-e", "puts ENV.fetch(\"ORBIT_JOURNEY_ID\")"],
        "evidence_provider"=>"project_e2e"
      }
    }
  }; File.write(p, YAML.dump(y))
' .orbit/test-hooks.yaml
"$CLI" validate --task .orbit/tasks/journey-task.yaml --stage execution-ready --json >journey-ready.json
json_assert 'real-path task becomes execution-ready with a compatible project hook' journey-ready.json 'j["valid"] == true && j["stage"] == "execution-ready"'

"$CLI" test-hook run --task .orbit/tasks/journey-task.yaml --journey upload_and_review --dry-run --json >hook-dry-run.json
json_assert 'test-hook dry-run resolves project argv without executing it' hook-dry-run.json 'j["status"] == "planned" && j["hook_id"] == "android_to_web" && j["command"].is_a?(Array) && j["evidence_provider"] == "project_e2e"'
"$CLI" test-hook run --task .orbit/tasks/journey-task.yaml --journey upload_and_review --json >hook-run.json
json_assert 'test-hook run executes the configured project provider with journey context' hook-run.json 'j["status"] == "pass" && j["stdout"].strip == "upload_and_review" && j["exit_status"] == 0'

"$CLI" evidence init --output .orbit/evidence/journey-missing.json >/dev/null
write_test_pass_report journey-missing.yaml "Build and regression commands passed without user journey evidence." "manual:tester:journey-missing"
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file .orbit/evidence/journey-missing.json --report journey-missing.yaml --task .orbit/tasks/journey-task.yaml --json >journey-missing-submit.json
json_assert 'test submit downgrades a technical pass without required journey evidence to partial' journey-missing-submit.json 'j.dig("record", "status") == "partial" && j.dig("record", "journey_validation", "valid") == false && j.dig("record", "journey_validation", "blocking_reason") == "missing_user_journey_evidence"'
if "$CLI" wait-gate --task .orbit/tasks/journey-task.yaml --evidence .orbit/evidence/journey-missing.json --json >journey-missing-gate.json; then
  printf 'FAIL real-path gate without journey evidence: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'real-path gate reports the missing journey evidence blocker' journey-missing-gate.json 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "test" && g["blocking_reason"] == "missing_user_journey_evidence" }'

"$CLI" evidence init --output .orbit/evidence/journey-valid.json >/dev/null
write_test_pass_report journey-valid.yaml "Android to Web user journey completed." "manual:tester:journey-valid"
cat >>journey-valid.yaml <<'YAML'
user_outcomes:
  - journey_id: upload_and_review
    verdict: pass
    actual_steps:
      - step: Upload media on Android.
        result: POST /uploads returned 201 and a job id.
      - step: Open the processed result in Web.
        result: The Web player rendered the processed media.
    observed_results:
      - Upload request, worker completion, and Web media visibility were observed.
    artifacts:
      screenshots:
        - .orbit/test-artifacts/web-player-visible.png
      crash_logs: []
      network_requests:
        - .orbit/test-artifacts/upload-network.json
      media_state:
        - .orbit/test-artifacts/media-state.json
    environment:
      device:
        model: Pixel fixture
        os: Android fixture
      browser:
        name: Chromium fixture
        version: fixture
      services:
        api: fixture
        worker: fixture
        storage: fixture
    uncovered_paths: []
    test_hook:
      id: android_to_web
      status: pass
      command:
        - ruby
        - -e
        - puts ENV.fetch("ORBIT_JOURNEY_ID")
YAML
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file .orbit/evidence/journey-valid.json --report journey-valid.yaml --task .orbit/tasks/journey-task.yaml --json >journey-valid-submit.json
json_assert 'complete user journey test evidence remains pass' journey-valid-submit.json 'j.dig("record", "status") == "pass" && j.dig("record", "journey_validation", "valid") == true && j.dig("record", "user_outcomes", 0, "journey_id") == "upload_and_review"'
"$CLI" wait-gate --task .orbit/tasks/journey-task.yaml --evidence .orbit/evidence/journey-valid.json --json >journey-valid-gate.json
json_assert 'complete real-path journey evidence closes the test gate' journey-valid-gate.json 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "test" && g["passed"] == true && g.dig("user_journey_evidence", "status") == "pass" }'
"$CLI" validate --task .orbit/tasks/journey-task.yaml --evidence .orbit/evidence/journey-valid.json --json >journey-valid-validate.json
json_assert 'validator accepts complete user journey evidence' journey-valid-validate.json 'j["valid"] == true'
ORBIT_INSTANCE=lead-main "$CLI" state start --task .orbit/tasks/journey-task.yaml >/dev/null
ORBIT_INSTANCE=lead-main "$CLI" handoff --task .orbit/tasks/journey-task.yaml --evidence .orbit/evidence/journey-valid.json --state .orbit/loop-state.yaml --json >journey-handoff.json
json_assert 'handoff presents user outcomes with the latest test judgment' journey-handoff.json 'j.dig("judgment_summary", "test_judgment", "user_outcomes", 0, "journey_id") == "upload_and_review" && j.dig("judgment_summary", "test_judgment", "journey_validation", "valid") == true'

cp .orbit/evidence/journey-valid.json .orbit/evidence/journey-artifact-mismatch.json
ruby --disable-gems -rjson -e '
  p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["user_outcomes"].last["artifacts"]={"screenshots"=>[]}; File.write(p, JSON.pretty_generate(j))
' .orbit/evidence/journey-artifact-mismatch.json
if "$CLI" wait-gate --task .orbit/tasks/journey-task.yaml --evidence .orbit/evidence/journey-artifact-mismatch.json --json >journey-artifact-mismatch.json; then
  printf 'FAIL real-path gate with inconsistent artifact state: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'real-path gate fails closed when artifact state contradicts a pass record' journey-artifact-mismatch.json 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["blocking_reason"] == "missing_real_path_artifact" }'

"$CLI" evidence init --output .orbit/evidence/journey-unit-only.json >/dev/null
cp journey-valid.yaml journey-unit-only.yaml
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["test_level"]="unit"; File.write(p, YAML.dump(y))' journey-unit-only.yaml
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file .orbit/evidence/journey-unit-only.json --report journey-unit-only.yaml --task .orbit/tasks/journey-task.yaml --json >journey-unit-only-submit.json
json_assert 'unit-only evidence cannot replace the required real user path' journey-unit-only-submit.json 'j.dig("record", "status") == "partial" && j.dig("record", "journey_validation", "blocking_reason") == "insufficient_journey_evidence_level"'

cd "$JOURNEY_ORIGINAL_DIR"

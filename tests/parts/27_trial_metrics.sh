# ---------------------------------------------------------------------------
# Privacy-minimized 30-day trial metrics collection and report
# ---------------------------------------------------------------------------

METRICS_PROJECT="$TMPROOT/trial-metrics-project"
mkdir -p "$METRICS_PROJECT"
METRICS_ORIGINAL_DIR=$PWD
cd "$METRICS_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

"$CLI" init --operation-mode solo >/dev/null
mkdir -p .orbit/tasks .orbit/test-artifacts
"$CLI" task draft --task-type implementation --output .orbit/tasks/trial.yaml >/dev/null
make_task_execution_ready .orbit/tasks/trial.yaml
ORBIT_INSTANCE=lead-main "$CLI" task start --task .orbit/tasks/trial.yaml >/dev/null
printf 'trial artifact\n' >.orbit/test-artifacts/trial-output.log
"$CLI" artifact inspect --path .orbit/test-artifacts/trial-output.log --task .orbit/tasks/trial.yaml --id trial-output --producer-command 'trial fixture' --json >trial-artifact.json
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file .orbit/evidence/trial.json --kind implementation --status pass --summary 'Trial metrics fixture implementation.' --task .orbit/tasks/trial.yaml --changed-file lib/trial.rb --verification 'trial fixture passed' --artifact-ref @trial-artifact.json >/dev/null
write_review_pass_report trial-review.yaml 'Trial metrics fixture review passed.' 'manual:reviewer:trial-metrics'
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file .orbit/evidence/trial.json --report trial-review.yaml --task .orbit/tasks/trial.yaml --json >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] << {"kind"=>"review", "status"=>"pass", "summary"=>"foreign stale pass must not drive metrics", "created_at"=>"2099-01-01T00:00:00Z", "structured_submit"=>true}; File.write(p, JSON.pretty_generate(j)+"\n")' .orbit/evidence/trial.json

"$CLI" metrics capture --task .orbit/tasks/trial.yaml --evidence .orbit/evidence/trial.json --stage baseline --duration-seconds 120 --tokens 500 --json >metrics-baseline.json
"$CLI" metrics capture --task .orbit/tasks/trial.yaml --evidence .orbit/evidence/trial.json --stage after --duration-seconds 90 --tokens 350 --json >metrics-after.json
json_assert 'metrics capture records task identity cost footprint and arbitrated gate wait' metrics-after.json 'd=j["dimensions"]; j["schema_version"] == "orbit-trial-metric-event-v1" && j["task"] == ".orbit/tasks/trial.yaml" && j["task_id"].match?(/\Aotask_/) && d["task_type"] == "implementation" && d["risk_level"] == "standard" && d["duration_seconds"] == 90 && d["tokens"] == 350 && d["artifact_count"] == 1 && d["artifact_bytes"] > 0 && d["implementation_to_gate_seconds"].is_a?(Integer) && d["implementation_to_gate_seconds"] < 60'

"$CLI" metrics record --metric workflow_failure --failure-kind identity --json >/dev/null
"$CLI" metrics record --metric workflow_failure --failure-kind schema --json >/dev/null
"$CLI" metrics record --metric workflow_failure --failure-kind revision --json >/dev/null
"$CLI" metrics record --metric independent_defect --source reviewer --severity high --json >/dev/null
"$CLI" metrics record --metric independent_defect --source tester --severity medium --json >/dev/null
"$CLI" metrics record --metric post_gate_defect --severity P0 --json >/dev/null
"$CLI" metrics record --metric post_gate_defect --severity P1 --json >/dev/null
"$CLI" metrics record --metric status_question --topic status --json >/dev/null
"$CLI" metrics record --metric status_question --topic next --json >/dev/null
"$CLI" metrics record --metric status_question --topic who --json >/dev/null
"$CLI" metrics record --metric automatic_session --outcome verified --json >/dev/null
"$CLI" metrics record --metric automatic_session --outcome pending --json >/dev/null

"$CLI" metrics report --window-days 30 --json >metrics-report.json
json_assert '30-day report pairs baseline and after by task identity and reports deltas' metrics-report.json 'm=j["metrics"]; j["schema_version"] == "orbit-trial-metrics-report-v1" && j["window"]["days"] == 30 && j["event_count"] == 14 && !j["coverage"].values.include?("missing") && j["coverage"]["artifact_footprint"] == "observed_zero" && j["observation_status"] == "ready_for_trial_decision" && j.dig("denominators", "paired_tasks") == 1 && m.dig("task_cost", "duration_seconds", "baseline", "total") == 120 && m.dig("task_cost", "duration_seconds", "after", "total") == 90 && m.dig("task_cost", "duration_seconds", "delta", "total") == -30 && m.dig("task_cost", "tokens", "baseline", "total") == 500 && m.dig("task_cost", "tokens", "after", "total") == 350 && m.dig("task_cost", "tokens", "delta", "total") == -150 && m.dig("artifact_footprint", "count", "delta", "total") == 0 && m.dig("implementation_to_gate_wait", "comparable_pairs") == 1 && m.dig("workflow_failures", "identity") == 1 && m.dig("workflow_failures", "schema") == 1 && m.dig("workflow_failures", "revision") == 1 && m.dig("independent_defects", "total") == 2 && m.dig("post_gate_user_defects", "P0") == 1 && m.dig("post_gate_user_defects", "P1") == 1 && m.dig("status_questions", "status") == 1 && m.dig("automatic_verified_ratio", "ratio") == 0.5'
json_assert 'trial metrics report stores dimensions but no prompt or free text' metrics-report.json 'j.dig("privacy", "prompt_content_stored") == false && j.dig("privacy", "free_text_stored") == false && j["events_file"] == ".orbit/metrics/trial-events.jsonl"'
if rg -q 'prompt|note|summary|text' .orbit/metrics/trial-events.jsonl; then
  printf 'FAIL trial metrics ledger stored a free-text field\n' >&2
  exit 1
fi
pass 'trial metrics JSONL contains no prompt or report prose fields'

"$CLI" metrics report --file .orbit/metrics/no-observations.jsonl --window-days 30 --json >metrics-empty-report.json
json_assert 'metrics distinguish missing observations from observed zero deltas' metrics-empty-report.json 'j["coverage"].values.all? { |state| state == "missing" } && j["observation_status"] == "collect_more_data" && j.dig("denominators", "paired_tasks") == 0'

expect_failure 'metrics reject invalid negative token counts' "$CLI" metrics capture --task .orbit/tasks/trial.yaml --evidence .orbit/evidence/trial.json --tokens -1 --json
expect_failure 'metrics reject post-gate defects outside P0 P1 P2' "$CLI" metrics record --metric post_gate_defect --severity high --json

cd "$METRICS_ORIGINAL_DIR"

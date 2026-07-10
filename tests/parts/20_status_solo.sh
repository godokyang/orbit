# ---------------------------------------------------------------------------
# Status/next read model and explicit solo completion semantics
# ---------------------------------------------------------------------------

STATUS_PROJECT="$TMPROOT/status-solo-project"
mkdir -p "$STATUS_PROJECT"
STATUS_ORIGINAL_DIR=$PWD
  cd "$STATUS_PROJECT"
  unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
  unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

  "$CLI" init --operation-mode solo >/dev/null
  mkdir -p .orbit/tasks .orbit/evidence
  "$CLI" new-task --task-type implementation --output .orbit/tasks/status-task.yaml >/dev/null
  make_task_execution_ready .orbit/tasks/status-task.yaml
  "$CLI" evidence init --output .orbit/evidence/status-task.json >/dev/null
  ORBIT_INSTANCE=lead-main "$CLI" state start --task .orbit/tasks/status-task.yaml >/dev/null
  ORBIT_INSTANCE=lead-main "$CLI" evidence add --file .orbit/evidence/status-task.json --kind implementation --status pass --summary "Solo implementation and self-test complete." --task .orbit/tasks/status-task.yaml >/dev/null

  ORBIT_INSTANCE=lead-main "$CLI" status --evidence .orbit/evidence/status-task.json --json >status-working.json
  json_assert 'status derives task risk mode identity and activity' status-working.json 'j.dig("task", "risk_level") == "standard" && j.dig("task", "operation_mode") == "solo" && j.dig("runtime", "verification") == "manual" && j.dig("activity", "implementation", "status") == "pass" && j.dig("activity", "review", "status") == "missing"'

  ORBIT_INSTANCE=lead-main "$CLI" state transition --to implemented_not_independently_accepted --evidence .orbit/evidence/status-task.json >/dev/null
  STATE_BEFORE_STATUS=$(ruby --disable-gems -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' .orbit/loop-state.yaml)
  ORBIT_INSTANCE=lead-main "$CLI" status --json >status-unaccepted.json
  ORBIT_INSTANCE=lead-main "$CLI" next >next-unaccepted.txt
  STATE_AFTER_STATUS=$(ruby --disable-gems -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' .orbit/loop-state.yaml)
  test "$STATE_BEFORE_STATUS" = "$STATE_AFTER_STATUS"
  pass 'status and next are read-only over authoritative state'
  json_assert 'status exposes explicit unaccepted solo implementation semantic' status-unaccepted.json 'j.dig("completion", "status") == "implemented_not_independently_accepted" && j.dig("completion", "independently_accepted") == false && j["blockers"].any? { |b| b["kind"] == "independent_acceptance" } && j.dig("next", "command").include?("--manual-payload")'
  grep -q 'orbit dispatch --task' next-unaccepted.txt
  grep -q 'independent review' next-unaccepted.txt
  pass 'orbit next explains how to obtain independent acceptance'

  ORBIT_INSTANCE=lead-main "$CLI" audit --task .orbit/tasks/status-task.yaml --evidence .orbit/evidence/status-task.json --state .orbit/loop-state.yaml --json >audit-unaccepted.json
  json_assert 'audit allows handoff but never claims solo implementation is done' audit-unaccepted.json 'j["trusted_for_handoff"] == true && j["trusted_for_done"] == false && j["done_ready"] == false && j.dig("completion_semantics", "complete_claim_allowed") == false'
  ORBIT_INSTANCE=lead-main "$CLI" handoff --task .orbit/tasks/status-task.yaml --evidence .orbit/evidence/status-task.json --state .orbit/loop-state.yaml --json >handoff-unaccepted.json
  json_assert 'handoff preserves unaccepted completion meaning and next action' handoff-unaccepted.json 'j["required_action"] == "obtain_independent_acceptance" && j.dig("completion_semantics", "status") == "implemented_not_independently_accepted" && j.dig("audit_summary", "trusted_for_done") == false && j["blocking_errors"].empty?'

  write_review_report review-blocked.yaml blocked "Reviewer found a user-visible blocker." "manual:reviewer:status-blocked"
  ruby --disable-gems -ryaml -e '
    p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
    y["findings"]=[{"severity"=>"high", "summary"=>"Primary user action is unavailable.", "symptom"=>"The action cannot complete.", "source"=>"manual journey", "consequence"=>"The user outcome remains blocked.", "remedy"=>"Fix the action and rerun independent review."}]
    File.write(p, YAML.dump(y))
  ' review-blocked.yaml
  ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file .orbit/evidence/status-task.json --report review-blocked.yaml --task .orbit/tasks/status-task.yaml --json >/dev/null
  ORBIT_INSTANCE=lead-main "$CLI" status --json >status-finding.json
  json_assert 'status surfaces latest open High and Medium findings' status-finding.json 'j["open_findings"].any? { |f| f["severity"] == "high" && f["summary"].include?("Primary user action") } && j["blockers"].any? { |b| b["kind"] == "finding" }'

  write_review_pass_report review.yaml "Fresh-context manual reviewer accepted the outcome." "manual:reviewer:status-solo"
  ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file .orbit/evidence/status-task.json --report review.yaml --task .orbit/tasks/status-task.yaml --json >/dev/null
  ORBIT_INSTANCE=lead-main "$CLI" state transition --to done --evidence .orbit/evidence/status-task.json >/dev/null
  ORBIT_INSTANCE=lead-main "$CLI" status --json >status-done.json
  json_assert 'solo-assisted review promotes the task to genuine done' status-done.json 'j.dig("completion", "status") == "done" && j.dig("completion", "independently_accepted") == true && j.dig("activity", "review", "status") == "pass" && j.dig("next", "command") == "none"'
  ORBIT_INSTANCE=lead-main "$CLI" status >status-human.txt
  test "$(wc -l <status-human.txt | tr -d ' ')" -le 12
  grep -q -- '- blocker: none' status-human.txt
  pass 'status human output fits on one screen and names the blocker'
  cp .orbit/evidence/status-task.json .orbit/evidence/status-task-invalid.json
  ruby --disable-gems -rjson -e '
    p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].reject! { |r| r["kind"] == "review" }; File.write(p, JSON.pretty_generate(j))
  ' .orbit/evidence/status-task-invalid.json
  ORBIT_INSTANCE=lead-main "$CLI" audit --task .orbit/tasks/status-task.yaml --evidence .orbit/evidence/status-task-invalid.json --state .orbit/loop-state.yaml --json >audit-done-invalid.json 2>/dev/null || true
  json_assert 'audit never labels a structurally done but invalid task as complete' audit-done-invalid.json 'j["state_phase"] == "done" && j.dig("completion_semantics", "status") == "done_not_trusted" && j.dig("completion_semantics", "complete_claim_allowed") == false && j["trusted_for_done"] == false'
cd "$STATUS_ORIGINAL_DIR"

STATUS_TEAM_PROJECT="$TMPROOT/status-team-project"
mkdir -p "$STATUS_TEAM_PROJECT"
  cd "$STATUS_TEAM_PROJECT"
  unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
  unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB
  "$CLI" init --operation-mode team >/dev/null
  mkdir -p .orbit/tasks .orbit/evidence
  "$CLI" new-task --task-type implementation --output .orbit/tasks/team-task.yaml >/dev/null
  make_task_execution_ready .orbit/tasks/team-task.yaml
  "$CLI" evidence init --output .orbit/evidence/team-task.json >/dev/null
  ORBIT_INSTANCE=lead-main "$CLI" state start --task .orbit/tasks/team-task.yaml >/dev/null
  ORBIT_INSTANCE=coder-main "$CLI" evidence add --file .orbit/evidence/team-task.json --kind implementation --status pass --summary "Team implementation complete." --task .orbit/tasks/team-task.yaml >/dev/null
  expect_failure 'team task cannot use solo unaccepted completion phase' env ORBIT_INSTANCE=lead-main "$CLI" state transition --to implemented_not_independently_accepted --evidence .orbit/evidence/team-task.json
cd "$STATUS_ORIGINAL_DIR"

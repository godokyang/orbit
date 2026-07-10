# ---------------------------------------------------------------------------
# Multi-signal intent classification, audited override, and task risk authority
# ---------------------------------------------------------------------------

INTENT_PROJECT="$TMPROOT/intent-classification-project"
mkdir -p "$INTENT_PROJECT"
INTENT_ORIGINAL_DIR=$PWD
cd "$INTENT_PROJECT"
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_SESSION_ID ORBIT_LAUNCH_ID
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

"$CLI" init --operation-mode solo >/dev/null
mkdir -p .orbit/tasks

"$CLI" classify-intent --text '修复这个问题' --json >fix-problem.json
json_assert 'fix this problem is classified as coding rather than discussion' fix-problem.json 'j["schema_version"] == "orbit-intent-classification-v2" && j["intent"] == "coding" && j["risk_recommendation"]["level"] == "standard" && j["matched_signals"].any? { |s| s["id"] == "coding_action" } && j["matched_signals"].none? { |s| s["matched_text"].include?("问题") }'

"$CLI" classify-intent --text '审视当前项目' --json >review-project.json
json_assert 'review the current project stays formal and non-light' review-project.json 'j["intent"] == "review" && j["policy"]["formal_task"] == true && j["risk_recommendation"]["level"] == "standard"'

"$CLI" classify-intent --text '评估功能效果' --json >evaluate-outcome.json
json_assert 'evaluate functional outcome stays formal and non-light' evaluate-outcome.json 'j["intent"] == "review" && j["policy"]["formal_task"] == true && j["risk_recommendation"]["level"] == "standard"'

"$CLI" classify-intent --text '先讨论如何修复登录问题并测试' --json >mixed-signals.json
json_assert 'classifier returns every workflow signal and exposes conflicts' mixed-signals.json 'ids=j["matched_signals"].map { |s| s["intent"] }; %w[discussion coding test].all? { |i| ids.include?(i) } && j["candidate_intents"].length >= 3 && j["conflicts"].any? { |c| c["kind"] == "multiple_workflow_signals" }'

if "$CLI" classify-intent --text '修复这个问题' --intent discussion --json >override-no-reason.json 2>override-no-reason.err; then
  printf 'FAIL explicit intent override succeeded without a reason\n' >&2
  exit 1
fi
pass 'explicit intent override requires an audit reason'

"$CLI" classify-intent --text '修复这个问题' --intent discussion --reason 'The user requested exploration before implementation.' --json >override.json
json_assert 'explicit override records detected selected and reason without hiding conflict' override.json 'j["detected_intent"] == "coding" && j["intent"] == "discussion" && j["confidence"] == "explicit" && j.dig("override", "applied") == true && j.dig("override", "reason").include?("exploration") && j["conflicts"].any? { |c| c["kind"] == "explicit_override" }'

"$CLI" classify-intent --text '问题' --json >generic-problem.json
json_assert 'generic problem is not treated as a discussion signal' generic-problem.json 'j["intent"] == "discussion" && j["confidence"] == "low" && j["matched_signals"].empty? && j["reason"].include?("generic words")'

"$CLI" new-task --task-type implementation --risk-level strict --risk-sink auth --output .orbit/tasks/strict.yaml >/dev/null
"$CLI" classify-intent --text 'fix a typo in the README' --task .orbit/tasks/strict.yaml --json >task-risk.json
json_assert 'structured task risk remains authoritative over a light language recommendation' task-risk.json 'j.dig("risk_recommendation", "level") == "light" && j.dig("risk_recommendation", "authority") == "advisory_only" && j.dig("risk_contract", "source") == "task_contract" && j.dig("risk_contract", "effective_level") == "strict" && j.dig("risk_contract", "classification_can_override") == false && j.dig("risk_contract", "recommendation_differs") == true'

json_assert 'intent policy can never skip task-required gates' task-risk.json 'j.dig("policy", "authority") == "advisory_only" && j.dig("policy", "task_contract_authoritative") == true && j.dig("policy", "may_skip_required_gates") == false'
json_assert 'classification without a task never invents an effective risk' fix-problem.json 'j.dig("risk_contract", "source") == "task_contract_required" && j.dig("risk_contract", "effective_level").nil? && j.dig("risk_contract", "classification_can_override") == false'

cd "$INTENT_ORIGINAL_DIR"

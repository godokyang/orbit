#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLI="$SKILL_ROOT/scripts/orbit"
TMPROOT=$(mktemp -d)
PASS_COUNT=0
unset ORBIT_INSTANCE ORBIT_ROLE ORBIT_CLIENT
unset HERDR_ENV HERDR_SOCKET_PATH HERDR_SESSION_ID HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_WORKSPACE HERDR_TAB_ID HERDR_TAB

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

make_task_execution_ready() {
  ruby --disable-gems -ryaml -e '
    path = ARGV[0]
    task = YAML.safe_load(File.read(path), aliases: true)
    exit 0 if task.dig("task_risk", "level") == "light"
    task["source_contract"] ||= {}
    task["source_contract"]["required_outcomes"] = ["Required behavior is implemented and independently verifiable."]
    task["acceptance"] = ["Required behavior passes its risk-matched verification path."]
    task["evidence_requirements"] = ["Record implementation and required gate evidence."]
    task["traceability"] = [{"requirement" => "required behavior", "slice" => "test-fixture"}]
    task["quality_outcome"] ||= {}
    task["quality_outcome"]["user_problem"] = "The test fixture needs a concrete, execution-ready user problem."
    if task["task_type"].to_s.include?("decomposition")
      task["implementation_plan"]["summary"] = "Execute one bounded fixture slice and aggregate its outcome evidence."
      task["decomposition"]["child_slices"] = [{
        "id" => "S1",
        "include" => "the bounded fixture behavior",
        "exclude" => "unrelated fixture behavior",
        "order_basis" => "single dependency-free test slice",
        "stop_condition" => "stop when the required behavior is verifiable",
        "replan_path" => "return to the parent fixture contract"
      }]
      task["decomposition"]["aggregate_outcome_metrics"] = ["The required fixture behavior is evidenced."]
      task["decomposition"]["stop_conditions"] = ["Stop if the fixture contract changes."]
    end
    if task["real_path_required"] == true
      task["user_journeys"] = [{
        "id" => "fixture_real_path",
        "actor" => "test user",
        "surface" => task["change_surface"],
        "steps" => ["Run the configured fixture path."],
        "expected_observables" => ["The fixture path completes without an error."],
        "required_evidence" => task["test_level"],
        "test_hook" => "fixture_real_path"
      }]
      hooks_path = File.join(Dir.pwd, ".orbit", "test-hooks.yaml")
      hooks = File.file?(hooks_path) ? YAML.safe_load(File.read(hooks_path), aliases: true) : {}
      hooks = {} unless hooks.is_a?(Hash)
      hooks["schema_version"] = "orbit-test-hooks-v1"
      hooks["hooks"] ||= {}
      hooks["hooks"]["fixture_real_path"] = {
        "enabled" => true,
        "surfaces" => ["*"],
        "command" => ["ruby", "-e", "puts \"fixture real path\""],
        "evidence_provider" => "test_fixture"
      }
      File.write(hooks_path, YAML.dump(hooks))
    end
    File.write(path, YAML.dump(task))
  ' "$1"
}

append_review_quality_fields() {
  cat >>"$1" <<'YAML'
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - skills/orbit/references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: outcome_review
      verdict: pass
      evidence: Outcome, evidence boundary, and counterexample paths were checked.
  not_applicable: []
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: The reviewed evidence proves the expected behavior.
  - id: counterexamples
    verdict: pass
    evidence: No counterexamples found; invalid completion patterns were checked and addressed.
  - id: evidence_sufficiency
    verdict: pass
    evidence: Evidence boundary confirms, assumed, and missing paths are explicit.
  - id: residual_risk
    verdict: pass
    evidence: Residual risk is acceptable; no untested required paths remain.
confirmed:
  - Reviewed evidence proves the expected behavior.
assumed: []
missing: []
residual_risk: "No residual risk: all required paths covered by evidence."
counterexample_cases:
  - Latest command pass must not mask gate verdict failures.
implementation_readiness_verdict: not_checked
YAML
}

append_test_quality_fields() {
  cat >>"$1" <<'YAML'
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - skills/orbit/references/runtime/testing-guideline.md
  applied_checks:
    - id: behavior_test
      verdict: pass
      evidence: Test evidence covers the expected behavior and cleanup contract.
  not_applicable: []
confirmed:
  - Test evidence covers the expected behavior.
assumed: []
missing: []
residual_risk: "No residual risk: all required paths covered by test evidence."
runtime_binding:
  build:
    git_head: "fixture-build"
  browser:
    name: "fixture-browser"
    owner: "tester"
YAML
}

write_review_pass_report() {
  local path="$1"
  local summary="$2"
  local source_message_id="$3"
  cat >"$path" <<YAML
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
verdict: pass
summary: ${summary}
source_message_id: ${source_message_id}
quality_outcome_verdict: pass
quality_outcome_reasoning: Outcome and acceptance evidence were checked.
findings: []
coverage:
  - review checked aggregate verdict behavior
artifacts:
  - tests/orbit_test.sh
YAML
  append_review_quality_fields "$path"
}

write_test_pass_report() {
  local path="$1"
  local summary="$2"
  local source_message_id="$3"
  cat >"$path" <<YAML
kind: test
report_template_version: test-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    schema_semantics: v1
verdict: pass
summary: ${summary}
source_message_id: ${source_message_id}
test_level: repo_regression
findings: []
coverage:
  - test exercised success path and cleanup path
artifacts:
  - .orbit/test-artifacts/orbit-test.log
YAML
  append_test_quality_fields "$path"
  cat >>"$path" <<'YAML'
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
}

register_manual_runtime_instance() {
  local instance="$1"
  local role="$2"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION_ID -u HERDR_SESSION -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u ORBIT_SESSION_ID -u ORBIT_LAUNCH_ID \
    ORBIT_INSTANCE="$instance" ORBIT_ROLE="$role" "$CLI" runtime register --json >"$TMPROOT/manual-runtime-${instance}.json"
  json_assert "manual runtime registers ${instance}" "$TMPROOT/manual-runtime-${instance}.json" 'j["identity_verification"] == "manual_runtime" && j["runtime_session"]["state"] == "active" && j["runtime_session"].dig("identity", "verification") == "manual_runtime" && j["runtime_session"]["diagnostic_only"] == true && j["runtime_session"]["persistence"] == "not_written"'
}

register_manual_runtime_instances() {
  for pair in lead-main:lead reviewer-main:reviewer tester-main:tester; do
    register_manual_runtime_instance "${pair%%:*}" "${pair##*:}"
  done
}


# ---------------------------------------------------------------------------
# Test parts (sourced to share TMPROOT/PASS_COUNT/CLI state)
# ---------------------------------------------------------------------------
PARTS_DIR="$SCRIPT_DIR/parts"
source "$PARTS_DIR/01_installer.sh"
register_manual_runtime_instances
source "$PARTS_DIR/02_task_evidence.sh"
source "$PARTS_DIR/03_validate.sh"
source "$PARTS_DIR/04_schema_version.sh"
source "$PARTS_DIR/05_slice1_new.sh"
source "$PARTS_DIR/06_parent_goal.sh"
source "$PARTS_DIR/07_destructive.sh"
source "$PARTS_DIR/08_identity_policy.sh"
source "$PARTS_DIR/09_identity_full.sh"
source "$PARTS_DIR/10_retention_compact.sh"
source "$PARTS_DIR/11_runtime_reconcile.sh"
source "$PARTS_DIR/12_gate_lease.sh"
source "$PARTS_DIR/13_doc_lifecycle.sh"
source "$PARTS_DIR/14_project_profile_risk.sh"
source "$PARTS_DIR/15_data_classification_retention.sh"
source "$PARTS_DIR/16_ci_release_readiness.sh"
source "$PARTS_DIR/17_protocol_schema_versioning_full.sh"
source "$PARTS_DIR/18_orbit_dogfood_governance.sh"
source "$PARTS_DIR/19_landing_governance_calibration.sh"
source "$PARTS_DIR/20_status_solo.sh"
source "$PARTS_DIR/21_user_journey.sh"
source "$PARTS_DIR/22_artifact_provenance.sh"
source "$PARTS_DIR/23_revision_knowledge.sh"
source "$PARTS_DIR/24_task_workflow.sh"
source "$PARTS_DIR/25_intent_classification.sh"
source "$PARTS_DIR/26_automatic_runtime.sh"
source "$PARTS_DIR/27_trial_metrics.sh"

printf 'REAL_TESTS_PASS count=%s tmp=%s\n' "$PASS_COUNT" "$TMPROOT"

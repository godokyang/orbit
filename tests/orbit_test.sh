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

append_review_quality_fields() {
  cat >>"$1" <<'YAML'
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
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
    - references/runtime/testing-guideline.md
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


# ---------------------------------------------------------------------------
# Test parts (sourced to share TMPROOT/PASS_COUNT/CLI state)
# ---------------------------------------------------------------------------
PARTS_DIR="$SCRIPT_DIR/parts"
source "$PARTS_DIR/01_installer.sh"
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

printf 'REAL_TESTS_PASS count=%s tmp=%s\n' "$PASS_COUNT" "$TMPROOT"

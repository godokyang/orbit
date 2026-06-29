# ---------------------------------------------------------------------------
# Schema versioning minimum scaffolding tests (Slice 14 step 1)
# ---------------------------------------------------------------------------

# Test 1: New task from `new-task` includes schema_semantics with feature_versions
SCHEMA_TASK="$TMPROOT/schema-test-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$SCHEMA_TASK" >/dev/null
yaml_assert 'new-task includes schema_semantics with feature_versions' "$SCHEMA_TASK" \
  'j["schema_semantics"].is_a?(Hash) && j["schema_semantics"]["feature_versions"].is_a?(Hash) && j["schema_semantics"]["feature_versions"]["schema_semantics"] == "v1"'

# Test 2: orbit evidence init produces schema_semantics in new evidence manifest
SCHEMA_EVIDENCE_FRESH="$TMPROOT/schema-fresh-evidence.json"
"$CLI" evidence init --output "$SCHEMA_EVIDENCE_FRESH" >/dev/null
json_assert 'evidence init includes schema_semantics with feature_versions' "$SCHEMA_EVIDENCE_FRESH" \
  'j["schema_semantics"].is_a?(Hash) && j["schema_semantics"]["feature_versions"].is_a?(Hash) && j["schema_semantics"]["feature_versions"]["schema_semantics"] == "v1"'

# Test 3: Audit of evidence lacking schema_semantics produces legacy_warning (not hard fail)
# Build a minimal passing evidence + state setup for the audit command
LEGACY_SCHEMA_TASK="$TMPROOT/legacy-schema-task.yaml"
"$CLI" new-task --target-role reviewer --task-type slice_review --output "$LEGACY_SCHEMA_TASK" >/dev/null
LEGACY_SCHEMA_EVIDENCE="$TMPROOT/legacy-schema-evidence.json"
"$CLI" evidence init --output "$LEGACY_SCHEMA_EVIDENCE" >/dev/null
# Strip schema_semantics to simulate pre-versioning evidence
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p)); j.delete("schema_semantics"); File.write(p, JSON.pretty_generate(j))' \
  "$LEGACY_SCHEMA_EVIDENCE"
LEGACY_STATE="$TMPROOT/legacy-schema-state.yaml"
cp .orbit/loop-state.yaml "$LEGACY_STATE"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["current_task"]=ARGV[1]; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=ARGV[2]; s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  "$LEGACY_STATE" "$(realpath "$LEGACY_SCHEMA_TASK")" "$(realpath "$LEGACY_SCHEMA_EVIDENCE")"
"$CLI" audit --task "$LEGACY_SCHEMA_TASK" --state "$LEGACY_STATE" --evidence "$LEGACY_SCHEMA_EVIDENCE" --json \
  >"$TMPROOT/audit-legacy-semantics.json" 2>/dev/null || true
json_assert 'audit of evidence without schema_semantics emits legacy_warning (not hard fail)' \
  "$TMPROOT/audit-legacy-semantics.json" \
  'svs = j["schema_version_summary"]; svs.is_a?(Hash) && svs["legacy_warnings"].is_a?(Array) && svs["legacy_warnings"].any? { |w| w["kind"] == "legacy_warning" && w["source"] == "evidence_file.schema_semantics" }'

# Test 4: validate of evidence with unknown future schema version outputs explicit compatibility message
FUTURE_SCHEMA_EVIDENCE="$TMPROOT/future-schema-evidence.json"
ruby --disable-gems -rjson -e \
  'src, dst = ARGV; j=JSON.parse(File.read(src)); j["schema_version"]="orbit-evidence-v9999"; File.write(dst, JSON.pretty_generate(j))' \
  "$SCHEMA_EVIDENCE_FRESH" "$FUTURE_SCHEMA_EVIDENCE"
"$CLI" validate --evidence "$FUTURE_SCHEMA_EVIDENCE" --json >"$TMPROOT/validate-future-schema.json" 2>/dev/null || true
json_assert 'validate of unknown future schema version emits explicit compatibility message' \
  "$TMPROOT/validate-future-schema.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["message"].include?("not recognized") || e["message"].include?("unknown_future_version") }'

# Test 5: Audit detects prose PASS / structured fail conflict and surfaces it
CONFLICT_TASK="$TMPROOT/conflict-test-task.yaml"
"$CLI" new-task --target-role reviewer --task-type slice_review --output "$CONFLICT_TASK" >/dev/null
CONFLICT_EVIDENCE="$TMPROOT/conflict-test-evidence.json"
"$CLI" evidence init --output "$CONFLICT_EVIDENCE" >/dev/null
# Inject a record with prose PASS summary but structured fail verdict
ruby --disable-gems -rjson -rtime -e '
  p = ARGV[0]
  j = JSON.parse(File.read(p))
  j["records"] = [{
    "kind" => "review",
    "status" => "fail",
    "summary" => "PASS - all checks look good and everything is green",
    "created_at" => Time.now.utc.iso8601
  }]
  File.write(p, JSON.pretty_generate(j))
' "$CONFLICT_EVIDENCE"
CONFLICT_STATE="$TMPROOT/conflict-test-state.yaml"
cp .orbit/loop-state.yaml "$CONFLICT_STATE"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["current_task"]=ARGV[1]; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=ARGV[2]; s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  "$CONFLICT_STATE" "$(realpath "$CONFLICT_TASK")" "$(realpath "$CONFLICT_EVIDENCE")"
"$CLI" audit --task "$CONFLICT_TASK" --state "$CONFLICT_STATE" --evidence "$CONFLICT_EVIDENCE" --json \
  >"$TMPROOT/audit-conflict.json" 2>/dev/null || true
json_assert 'audit detects prose PASS / structured fail conflict and flags it' \
  "$TMPROOT/audit-conflict.json" \
  'svs = j["schema_version_summary"]; svs.is_a?(Hash) && svs["prose_conflicts"].is_a?(Array) && svs["prose_conflicts"].any? { |c| c["conflict_type"] == "prose_pass_structured_fail" && c["resolution"] == "structured_verdict_wins" }'

# Test 6: evidence submit writes source_report_semantics into the evidence record
SEMANTICS_TASK="$TMPROOT/semantics-submit-task.yaml"
"$CLI" new-task --target-role reviewer --task-type slice_review --output "$SEMANTICS_TASK" >/dev/null
SEMANTICS_EVIDENCE="$TMPROOT/semantics-submit-evidence.json"
"$CLI" evidence init --output "$SEMANTICS_EVIDENCE" >/dev/null
SEMANTICS_REPORT="$TMPROOT/semantics-submit-report.yaml"
write_review_pass_report "$SEMANTICS_REPORT" "Semantics versioning test review." "herdr:reviewer:semantics-test"
# Add report_template_version and schema_semantics to the report
cat >>"$SEMANTICS_REPORT" <<'YAML'
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    schema_semantics: v1
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$SEMANTICS_EVIDENCE" --report "$SEMANTICS_REPORT" --json \
  >"$TMPROOT/semantics-submit-result.json"
json_assert 'evidence submit persists source_report_semantics with template version and feature_versions' \
  "$TMPROOT/semantics-submit-result.json" \
  'srs = j["record"]["source_report_semantics"]; srs.is_a?(Hash) && srs["report_template_version"] == "review-report-v1" && srs["feature_versions"].is_a?(Hash) && srs["feature_versions"]["schema_semantics"] == "v1"'

# Test 7: evidence submit of report missing report_template_version records legacy_warning in source_report_semantics
LEGACY_REPORT="$TMPROOT/legacy-template-report.yaml"
LEGACY_TEMPLATE_EVIDENCE="$TMPROOT/legacy-template-evidence.json"
"$CLI" evidence init --output "$LEGACY_TEMPLATE_EVIDENCE" >/dev/null
write_review_pass_report "$LEGACY_REPORT" "Legacy template report without version field." "herdr:reviewer:legacy-template"
# No report_template_version field added – simulates pre-versioning report
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$LEGACY_TEMPLATE_EVIDENCE" --report "$LEGACY_REPORT" --json \
  >"$TMPROOT/legacy-template-submit.json"
json_assert 'evidence submit of report without report_template_version records legacy_warning in source_report_semantics' \
  "$TMPROOT/legacy-template-submit.json" \
  'srs = j["record"]["source_report_semantics"]; srs.is_a?(Hash) && srs["compatibility_state"] == "legacy" && srs["legacy_warnings"].is_a?(Array) && srs["legacy_warnings"].any? { |w| w["kind"] == "legacy_warning" }'

# Test 8: evidence submit blocks on unknown future report_template_version
FUTURE_TEMPLATE_EVIDENCE="$TMPROOT/future-template-evidence.json"
"$CLI" evidence init --output "$FUTURE_TEMPLATE_EVIDENCE" >/dev/null
FUTURE_TEMPLATE_REPORT="$TMPROOT/future-template-report.yaml"
write_review_pass_report "$FUTURE_TEMPLATE_REPORT" "Future template version report." "herdr:reviewer:future-template"
echo "report_template_version: review-report-v9999" >>"$FUTURE_TEMPLATE_REPORT"
expect_failure 'evidence submit blocks on unknown future report_template_version' \
  env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$FUTURE_TEMPLATE_EVIDENCE" --report "$FUTURE_TEMPLATE_REPORT" --json

# Test 9: evidence submit blocks when report_template_version is valid globally but wrong for kind
KINDMISMATCH_EVIDENCE="$TMPROOT/kindmismatch-evidence.json"
"$CLI" evidence init --output "$KINDMISMATCH_EVIDENCE" >/dev/null
KINDMISMATCH_REPORT="$TMPROOT/kindmismatch-report.yaml"
write_test_pass_report "$KINDMISMATCH_REPORT" "Test pass report with wrong template version for kind." "herdr:tester:kindmismatch"
echo "report_template_version: review-report-v1" >>"$KINDMISMATCH_REPORT"
expect_failure 'evidence submit blocks when report_template_version does not match kind' \
  env ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$KINDMISMATCH_EVIDENCE" --report "$KINDMISMATCH_REPORT" --json

# Test 10: current template version without schema_semantics records known_gap in source_report_semantics
NOGAP_EVIDENCE="$TMPROOT/no-schema-semantics-evidence.json"
"$CLI" evidence init --output "$NOGAP_EVIDENCE" >/dev/null
NOGAP_REPORT="$TMPROOT/no-schema-semantics-report.yaml"
write_review_pass_report "$NOGAP_REPORT" "Review pass with known template but no schema_semantics." "herdr:reviewer:nogap"
echo "report_template_version: review-report-v1" >>"$NOGAP_REPORT"
# Intentionally no schema_semantics block
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$NOGAP_EVIDENCE" --report "$NOGAP_REPORT" --json \
  >"$TMPROOT/nogap-submit.json"
json_assert 'current template version without schema_semantics records known_gap in source_report_semantics' \
  "$TMPROOT/nogap-submit.json" \
  'srs = j["record"]["source_report_semantics"]; srs.is_a?(Hash) && srs["compatibility_state"] == "current" && srs["known_gaps"].is_a?(Array) && !srs["known_gaps"].empty?'

# Test 11: handoff includes schema_version_summary
HANDOFF_TASK="$TMPROOT/handoff-schema-task.yaml"
"$CLI" new-task --target-role reviewer --task-type slice_review --output "$HANDOFF_TASK" >/dev/null
HANDOFF_EVIDENCE="$TMPROOT/handoff-schema-evidence.json"
"$CLI" evidence init --output "$HANDOFF_EVIDENCE" >/dev/null
HANDOFF_STATE="$TMPROOT/handoff-schema-state.yaml"
cp .orbit/loop-state.yaml "$HANDOFF_STATE"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["current_task"]=ARGV[1]; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=ARGV[2]; s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  "$HANDOFF_STATE" "$(realpath "$HANDOFF_TASK")" "$(realpath "$HANDOFF_EVIDENCE")"
ORBIT_INSTANCE=reviewer "$CLI" handoff --task "$HANDOFF_TASK" --state "$HANDOFF_STATE" --evidence "$HANDOFF_EVIDENCE" --json \
  >"$TMPROOT/handoff-schema.json" 2>/dev/null || true
json_assert 'handoff includes schema_version_summary with compatibility_state' \
  "$TMPROOT/handoff-schema.json" \
  'svs = j["schema_version_summary"]; svs.is_a?(Hash) && svs.key?("compatibility_state")'

# Test: review gate rejects implementation_readiness substituting for outcome_quality minimum
# (cross-family substitution is prohibited: review_quality family ≠ design_readiness family)
IMPL_FOR_OUTCOME_EVIDENCE="$TMPROOT/impl-review-for-outcome-gate.json"
"$CLI" evidence init --output "$IMPL_FOR_OUTCOME_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/impl-review-for-outcome-gate.yaml" "Implementation readiness review pass." "herdr:reviewer:impl-for-outcome"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="implementation_readiness"; y["implementation_readiness_verdict"]="pass"; File.write(p, YAML.dump(y))' "$TMPROOT/impl-review-for-outcome-gate.yaml"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$IMPL_FOR_OUTCOME_EVIDENCE" --report "$TMPROOT/impl-review-for-outcome-gate.yaml" --json >/dev/null
if "$CLI" wait-gate --task "$MIN_OUTCOME_TASK" --evidence "$IMPL_FOR_OUTCOME_EVIDENCE" --json >"$TMPROOT/wait-gate-impl-for-outcome.json"; then
  printf 'FAIL review gate rejects implementation_readiness substituting for outcome_quality: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'review gate rejects implementation_readiness substituting for outcome_quality'
json_assert 'review gate cross-family substitution reports below_minimum blocker' \
  "$TMPROOT/wait-gate-impl-for-outcome.json" \
  'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "evidence_level_below_minimum" && g["evidence_level"] == "implementation_readiness" && g["minimum_evidence_level"] == "outcome_quality" }'

# Test: test gate rejects outcome_quality evidence (wrong gate kind – not in test_quality family)
TEST_WRONGKIND_EVIDENCE="$TMPROOT/test-wrongkind-evidence.json"
"$CLI" evidence init --output "$TEST_WRONGKIND_EVIDENCE" >/dev/null
cat >"$TMPROOT/test-wrongkind-report.yaml" <<'REPORT'
kind: test
verdict: pass
summary: Test pass with outcome_quality (wrong evidence family for test gate).
source_message_id: herdr:tester:wrongkind
test_level: repo_regression
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: wrongkind_test
      verdict: pass
      evidence: Wrong evidence family for test gate.
  not_applicable: []
confirmed:
  - Wrong evidence family for test gate.
assumed: []
missing: []
residual_risk: "No residual risk: all required paths covered by test evidence."
findings: []
coverage:
  - test exercised success path
artifacts:
  - tests/orbit_test.sh
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
REPORT
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$TEST_WRONGKIND_EVIDENCE" --report "$TMPROOT/test-wrongkind-report.yaml" --json >/dev/null
if "$CLI" wait-gate --task "$TEST_TASK" --evidence "$TEST_WRONGKIND_EVIDENCE" --json >"$TMPROOT/wait-gate-test-wrongkind.json"; then
  printf 'FAIL test gate rejects outcome_quality (wrong gate kind): command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'test gate rejects outcome_quality evidence (wrong gate kind)'
json_assert 'test gate wrong_gate_kind blocker reported' \
  "$TMPROOT/wait-gate-test-wrongkind.json" \
  'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "test" && g["blocking_reason"] == "evidence_level_wrong_gate_kind" && g["evidence_level"] == "outcome_quality" }'


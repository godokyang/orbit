# ---------------------------------------------------------------------------
# Slice 14: Protocol schema versioning full — consistency_check + negative_evidence
# ---------------------------------------------------------------------------

S14_TASK="$TMPROOT/s14-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S14_TASK" >/dev/null

S14_STATE="$TMPROOT/s14-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S14_TASK" "$TMPROOT/dummy.json" "$S14_STATE"

# ---- Group 1: prose PASS + structured fail yields consistency_check conflict ----

S14_CONFLICT_EVIDENCE="$TMPROOT/s14-conflict-evidence.json"
"$CLI" evidence init --output "$S14_CONFLICT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"]=[{"kind"=>"review","status"=>"fail","summary"=>"PASS - all checks green, no issues found.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"source_message_id"=>"s14-conflict"}]; File.write(p,JSON.pretty_generate(j))' "$S14_CONFLICT_EVIDENCE"
"$CLI" audit --task "$S14_TASK" --evidence "$S14_CONFLICT_EVIDENCE" --state "$S14_STATE" --json >"$TMPROOT/s14-conflict-audit.json" 2>/dev/null || true
json_assert 'audit consistency_checks has conflict for prose-pass-structured-fail' "$TMPROOT/s14-conflict-audit.json" \
  'svs = j["schema_version_summary"]; svs["consistency_checks"].is_a?(Array) && svs["consistency_checks"].any? { |c| !c["conflicts"].empty? && c["structured_verdict"] == "fail" && c["summary_verdict_detected"] == "pass" && c["resolution"] == "structured_verdict_wins" }'
json_assert 'audit prose_conflicts still present for compatibility' "$TMPROOT/s14-conflict-audit.json" \
  'j["schema_version_summary"]["prose_conflicts"].is_a?(Array) && !j["schema_version_summary"]["prose_conflicts"].empty?'
json_assert 'audit blocking_findings include prose conflict' "$TMPROOT/s14-conflict-audit.json" \
  'j["blocking_findings"].any? { |f| f["source"].include?("records[0]") }'
pass 'prose PASS + structured fail yields consistency_check conflict and audit blocks'

# ---- Group 2: prose FAIL + structured pass yields conflict, structured remains pass ----

S14_REV_CONFLICT_EVIDENCE="$TMPROOT/s14-rev-conflict-evidence.json"
"$CLI" evidence init --output "$S14_REV_CONFLICT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"]=[{"kind"=>"review","status"=>"pass","summary"=>"FAIL - critical issues found in this review.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"source_message_id"=>"s14-rev"}]; File.write(p,JSON.pretty_generate(j))' "$S14_REV_CONFLICT_EVIDENCE"
"$CLI" audit --task "$S14_TASK" --evidence "$S14_REV_CONFLICT_EVIDENCE" --state "$S14_STATE" --json >"$TMPROOT/s14-rev-conflict-audit.json" 2>/dev/null || true
json_assert 'audit consistency_checks shows structured pass with summary fail conflict' "$TMPROOT/s14-rev-conflict-audit.json" \
  'svs = j["schema_version_summary"]; svs["consistency_checks"].any? { |c| c["structured_verdict"] == "pass" && c["summary_verdict_detected"] == "fail" && !c["conflicts"].empty? }'
pass 'prose FAIL + structured pass yields conflict; structured verdict remains pass'

# ---- Group 3: prose PASS + structured partial yields conflict ----

S14_PARTIAL_CONFLICT_EVIDENCE="$TMPROOT/s14-partial-conflict-evidence.json"
"$CLI" evidence init --output "$S14_PARTIAL_CONFLICT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"]=[{"kind"=>"review","status"=>"partial","summary":"PASS - review completed successfully.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"source_message_id"=>"s14-partial"}]; File.write(p,JSON.pretty_generate(j))' "$S14_PARTIAL_CONFLICT_EVIDENCE"
"$CLI" audit --task "$S14_TASK" --evidence "$S14_PARTIAL_CONFLICT_EVIDENCE" --state "$S14_STATE" --json >"$TMPROOT/s14-partial-conflict-audit.json" 2>/dev/null || true
json_assert 'audit consistency_checks has conflict for prose-pass-structured-partial' "$TMPROOT/s14-partial-conflict-audit.json" \
  'svs = j["schema_version_summary"]; svs["consistency_checks"].any? { |c| c["structured_verdict"] == "partial" && c["summary_verdict_detected"] == "pass" && !c["conflicts"].empty? }'
pass 'prose PASS + structured partial yields consistency_check conflict'

# ---- Group 4: negative_evidence not_tested in a pass report is persisted ----

S14_NEG_EVIDENCE="$TMPROOT/s14-neg-evidence.json"
"$CLI" evidence init --output "$S14_NEG_EVIDENCE" >/dev/null
cat >"$TMPROOT/s14-review-with-neg.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review pass with negative evidence for untested browser E2E.
source_message_id: herdr:reviewer:s14-neg
quality_outcome_verdict: pass
quality_outcome_reasoning: Pass despite untested paths documented as negative evidence.
findings: []
coverage: []
artifacts: []
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: neg_check
      verdict: pass
      evidence: negative evidence documented.
  not_applicable: []
confirmed: [negative evidence documented]
assumed: []
missing: []
residual_risk: "Browser E2E not tested; documented as negative evidence."
counterexample_cases: [browser E2E untested]
implementation_readiness_verdict: not_checked
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: ok
  - id: counterexamples
    verdict: pass
    evidence: ok
  - id: evidence_sufficiency
    verdict: pass
    evidence: ok
  - id: residual_risk
    verdict: pass
    evidence: ok
negative_evidence:
  - claim: "browser E2E passed"
    status: not_tested
    reason: "docs-only task, no browser changes"
  - claim: "performance regression check"
    status: not_applicable
    reason: "no performance-sensitive code changed"
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S14_NEG_EVIDENCE" \
  --report "$TMPROOT/s14-review-with-neg.yaml" \
  --task "$S14_TASK" \
  --json >"$TMPROOT/s14-neg-submit.json"
json_assert 'evidence submit persists negative_evidence' "$TMPROOT/s14-neg-submit.json" \
  'r = j["record"]; r["negative_evidence"].is_a?(Array) && r["negative_evidence"].length == 2 && r["negative_evidence"][0]["status"] == "not_tested"'
pass 'negative_evidence not_tested in pass report is persisted via submit'

# validate accepts pass with negative_evidence (not a fail).
"$CLI" validate --task "$S14_TASK" --evidence "$S14_NEG_EVIDENCE" --json >"$TMPROOT/s14-neg-validate.json" 2>/dev/null || true
json_assert 'validate accepts pass with negative_evidence' "$TMPROOT/s14-neg-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("negative_evidence") }'

# audit includes negative_evidence_summary.
"$CLI" audit --task "$S14_TASK" --evidence "$S14_NEG_EVIDENCE" --state "$S14_STATE" --json >"$TMPROOT/s14-neg-audit.json" 2>/dev/null || true
json_assert 'audit includes negative_evidence_summary' "$TMPROOT/s14-neg-audit.json" \
  'j.key?("negative_evidence_summary") && j["negative_evidence_summary"]["total"] == 2 && j["negative_evidence_summary"]["by_status"]["not_tested"] == 1'

# handoff includes negative_evidence_summary.
S14_NEG_HANDOFF_STATE="$TMPROOT/s14-neg-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S14_TASK" "$S14_NEG_EVIDENCE" "$S14_NEG_HANDOFF_STATE"
"$CLI" handoff --task "$S14_TASK" --evidence "$S14_NEG_EVIDENCE" --state "$S14_NEG_HANDOFF_STATE" --json >"$TMPROOT/s14-neg-handoff.json" 2>/dev/null || true
json_assert 'handoff includes negative_evidence_summary' "$TMPROOT/s14-neg-handoff.json" \
  'j.key?("negative_evidence_summary") && j["negative_evidence_summary"]["total"] == 2'
pass 'negative_evidence appears in audit and handoff summary without becoming fail'

# ---- Group 5: evidence from-report persists negative_evidence ----

S14_NEG_FR_EVIDENCE="$TMPROOT/s14-neg-fr-evidence.json"
"$CLI" evidence init --output "$S14_NEG_FR_EVIDENCE" >/dev/null
cat >"$TMPROOT/s14-neg-fr-report.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review pass via from-report with negative evidence.
source_message_id: herdr:reviewer:s14-neg-fr
quality_outcome_verdict: pass
quality_outcome_reasoning: ok
findings: []
coverage: []
artifacts: []
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: c
      verdict: pass
      evidence: ok
  not_applicable: []
confirmed: [c]
assumed: []
missing: []
residual_risk: "none"
counterexample_cases: [neg fr]
implementation_readiness_verdict: not_checked
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: ok
  - id: counterexamples
    verdict: pass
    evidence: ok
  - id: evidence_sufficiency
    verdict: pass
    evidence: ok
  - id: residual_risk
    verdict: pass
    evidence: ok
negative_evidence:
  - claim: "E2E test suite"
    status: not_tested
    reason: "no E2E changes in this task"
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence from-report \
  --file "$S14_NEG_FR_EVIDENCE" \
  --report "$TMPROOT/s14-neg-fr-report.yaml" \
  --json >"$TMPROOT/s14-neg-fr-submit.json"
json_assert 'evidence from-report persists negative_evidence' "$TMPROOT/s14-neg-fr-submit.json" \
  'r = j["record"]; r["negative_evidence"].is_a?(Array) && r["negative_evidence"][0]["status"] == "not_tested"'
pass 'negative_evidence persisted via evidence from-report'

# ---- Group 6: malformed negative_evidence rejected by validate and submit ----

S14_BAD_NEG_EVIDENCE="$TMPROOT/s14-bad-neg-evidence.json"
"$CLI" evidence init --output "$S14_BAD_NEG_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"]=[{"kind"=>"command","status"=>"pass","summary":"bad neg.","created_at"=>"2026-06-29T10:00:00Z","negative_evidence"=>[{"claim"=>"ok","status"=>"invalid_status","reason"=>"r"}]}]; File.write(p,JSON.pretty_generate(j))' "$S14_BAD_NEG_EVIDENCE"
expect_failure 'validate rejects invalid negative_evidence status' "$CLI" validate --task "$S14_TASK" --evidence "$S14_BAD_NEG_EVIDENCE" --json

S14_NONLIST_NEG_EVIDENCE="$TMPROOT/s14-nonlist-neg-evidence.json"
"$CLI" evidence init --output "$S14_NONLIST_NEG_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"]=[{"kind"=>"command","status"=>"pass","summary":"nonlist neg.","created_at"=>"2026-06-29T10:00:00Z","negative_evidence"=>"not-a-list"}]; File.write(p,JSON.pretty_generate(j))' "$S14_NONLIST_NEG_EVIDENCE"
expect_failure 'validate rejects non-list negative_evidence' "$CLI" validate --task "$S14_TASK" --evidence "$S14_NONLIST_NEG_EVIDENCE" --json

S14_BAD_SUBMIT_EVIDENCE="$TMPROOT/s14-bad-submit-evidence.json"
"$CLI" evidence init --output "$S14_BAD_SUBMIT_EVIDENCE" >/dev/null
cat >"$TMPROOT/s14-bad-neg-report.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review pass with bad negative evidence.
source_message_id: herdr:reviewer:s14-bad-neg
quality_outcome_verdict: pass
quality_outcome_reasoning: ok
findings: []
coverage: []
artifacts: []
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: c
      verdict: pass
      evidence: ok
  not_applicable: []
confirmed: [c]
assumed: []
missing: []
residual_risk: "none"
counterexample_cases: [bad neg]
implementation_readiness_verdict: not_checked
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: ok
  - id: counterexamples
    verdict: pass
    evidence: ok
  - id: evidence_sufficiency
    verdict: pass
    evidence: ok
  - id: residual_risk
    verdict: pass
    evidence: ok
negative_evidence:
  - claim: "test"
    status: bogus
    reason: "r"
YAML
expect_failure 'evidence submit rejects invalid negative_evidence status' env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$S14_BAD_SUBMIT_EVIDENCE" --report "$TMPROOT/s14-bad-neg-report.yaml" --task "$S14_TASK" --json

# ---- Group 7: consistency_checks present on clean records with stable keys ----

S14_CLEAN_EVIDENCE="$TMPROOT/s14-clean-evidence.json"
"$CLI" evidence init --output "$S14_CLEAN_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$S14_CLEAN_EVIDENCE" --kind command --status pass --summary "command executed" >/dev/null
"$CLI" audit --task "$S14_TASK" --evidence "$S14_CLEAN_EVIDENCE" --state "$S14_STATE" --json >"$TMPROOT/s14-clean-audit.json" 2>/dev/null || true
json_assert 'audit consistency_checks present on clean records' "$TMPROOT/s14-clean-audit.json" \
  'svs = j["schema_version_summary"]; svs["consistency_checks"].is_a?(Array) && svs["consistency_checks"].any? { |c| c["conflicts"].empty? }'
json_assert 'audit consistency_checks has stable keys structured_verdict and summary_verdict_detected' "$TMPROOT/s14-clean-audit.json" \
  'svs = j["schema_version_summary"]; svs["consistency_checks"].any? { |c| c.key?("structured_verdict") && c.key?("summary_verdict_detected") && c.key?("conflicts") && c.key?("resolution") }'
pass 'consistency_checks have stable keys on clean records'

# ---- Group 8: schema_semantics includes protocol_schema_versioning v1 ----

S14_IMPL_TASK="$TMPROOT/s14-impl-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S14_IMPL_TASK" >/dev/null
yaml_assert 'new-task includes protocol_schema_versioning feature version' "$S14_IMPL_TASK" \
  'j.dig("schema_semantics","feature_versions","protocol_schema_versioning") == "v1"'

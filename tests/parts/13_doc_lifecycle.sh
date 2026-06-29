# ---------------------------------------------------------------------------
# Slice 10: doc-lifecycle-and-decision-record acceptance tests
# ---------------------------------------------------------------------------

# ---- Group 1: docs alias carries doc_lifecycle metadata ----

S10_REGISTRY="$TMPROOT/s10-docs-registry.json"
mkdir -p "$TMPROOT/s10-docs"
printf '%s\n' '# Active Design Doc' 'status: active' >"$TMPROOT/s10-docs/active.md"
"$CLI" docs alias --id s10.active --path "$TMPROOT/s10-docs/active.md" \
  --registry "$S10_REGISTRY" --status open_design --json >"$TMPROOT/s10-alias-active.json"
json_assert 'docs alias carries doc_lifecycle status' "$TMPROOT/s10-alias-active.json" \
  'e = j["entry"]; e["doc_lifecycle"].is_a?(Hash) && e["doc_lifecycle"]["status"] == "open_design" && e["doc_lifecycle"]["doc_id"] == "s10.active"'
json_assert 'docs alias doc_lifecycle has content_sha256' "$TMPROOT/s10-alias-active.json" \
  'j["entry"]["doc_lifecycle"]["content_sha256"].start_with?("sha256:")'

# Baseline doc has active_baseline status.
printf '%s\n' '# Baseline Doc' >"$TMPROOT/s10-docs/baseline.md"
"$CLI" docs alias --id s10.baseline --path "$TMPROOT/s10-docs/baseline.md" \
  --registry "$S10_REGISTRY" --status active_baseline --json >"$TMPROOT/s10-alias-baseline.json"
json_assert 'docs alias active_baseline status recorded' "$TMPROOT/s10-alias-baseline.json" \
  'j["entry"]["doc_lifecycle"]["status"] == "active_baseline"'

# ---- Group 2: docs check passes with valid doc_lifecycle ----

"$CLI" docs check --registry "$S10_REGISTRY" --open-dir "$TMPROOT/s10-docs" --json >"$TMPROOT/s10-check-valid.json" 2>/dev/null || true
json_assert 'docs check passes with valid doc_lifecycle' "$TMPROOT/s10-check-valid.json" \
  'j["valid"] == true'
json_assert 'docs check includes doc_lifecycle_summary' "$TMPROOT/s10-check-valid.json" \
  'dls = j["doc_lifecycle_summary"]; dls.is_a?(Hash) && dls["doc_count"] == 2 && dls["statuses"]["open_design"] == 1 && dls["statuses"]["active_baseline"] == 1 && dls["has_open_design"] == true'

# ---- Group 3: missing alias target fails docs check ----

ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["docs"]["s10.active"]["current_path"]="s10-docs/missing.md"; j["docs"]["s10.active"]["absolute_path"]=""; File.write(p, JSON.pretty_generate(j))' "$S10_REGISTRY"
if "$CLI" docs check --registry "$S10_REGISTRY" --open-dir "$TMPROOT/s10-docs-noop" --json >"$TMPROOT/s10-check-missing.json" 2>/dev/null; then
  printf 'FAIL docs check missing alias target: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'docs check fails missing alias target (Slice 10)'
json_assert 'docs check reports missing alias issue' "$TMPROOT/s10-check-missing.json" \
  'j["valid"] == false && j["issues"].any? { |i| i["source"] == "docs_registry.s10.active.current_path" }'

# Restore alias for subsequent tests.
"$CLI" docs alias --id s10.active --path "$TMPROOT/s10-docs/active.md" --registry "$S10_REGISTRY" --status open_design --json >/dev/null

# ---- Group 4: implemented doc still marked open_design triggers warning ----

printf '%s\n' '# Implemented Design' 'status: done' >"$TMPROOT/s10-docs/active.md"
"$CLI" docs check --registry "$S10_REGISTRY" --open-dir "$TMPROOT/s10-docs-noop" --json >"$TMPROOT/s10-check-stale-design.json" 2>/dev/null || true
json_assert 'docs check warns open_design with done content' "$TMPROOT/s10-check-stale-design.json" \
  'j["warnings"].any? { |w| w["source"] == "docs_registry.s10.active.doc_lifecycle.status" && w["message"].include?("open_design") }'
pass 'implemented doc still marked open_design triggers warning'

# ---- Group 5: evidence submit carries decision_record ----

S10_TASK="$TMPROOT/s10-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S10_TASK" >/dev/null
S10_EVIDENCE="$TMPROOT/s10-evidence.json"
"$CLI" evidence init --output "$S10_EVIDENCE" >/dev/null
cat >"$TMPROOT/s10-review-with-decision.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review pass carrying a user confirmation decision record.
source_message_id: herdr:reviewer:s10-decision
quality_outcome_verdict: pass
quality_outcome_reasoning: User confirmed scope before review.
findings: []
coverage:
  - decision record propagation checked
artifacts: []
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: decision_check
      verdict: pass
      evidence: decision_record carried through submit.
  not_applicable: []
confirmed:
  - decision_record carried through submit.
assumed: []
missing: []
residual_risk: "No residual risk."
counterexample_cases:
  - decision_record must propagate to evidence record.
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
decision_record:
  id: "decision-s10-001"
  kind: user_confirmation
  summary: "User confirmed the design scope before implementation."
  source: "chat:herdr:user:2026-06-29"
  applies_to:
    task: "s10-implementation-task"
    doc_id: "s10.active"
  expires: "2099-12-31T00:00:00Z"
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S10_EVIDENCE" \
  --report "$TMPROOT/s10-review-with-decision.yaml" \
  --task "$S10_TASK" \
  --json >"$TMPROOT/s10-submit-decision.json"
json_assert 'evidence submit carries decision_record to record' "$TMPROOT/s10-submit-decision.json" \
  'dr = j["record"]["decision_record"]; dr.is_a?(Hash) && dr["id"] == "decision-s10-001" && dr["kind"] == "user_confirmation"'
json_assert 'evidence submit preserves decision_record applies_to' "$TMPROOT/s10-submit-decision.json" \
  'j["record"]["decision_record"]["applies_to"]["doc_id"] == "s10.active"'
json_assert 'evidence submit preserves decision_record expires' "$TMPROOT/s10-submit-decision.json" \
  'j["record"]["decision_record"]["expires"] == "2099-12-31T00:00:00Z"'
pass 'user confirmation is not only in chat: evidence persists decision_record'

# ---- Group 6: validate accepts evidence with valid decision_record ----

"$CLI" validate --task "$S10_TASK" --evidence "$S10_EVIDENCE" --json >"$TMPROOT/s10-validate-decision.json"
json_assert 'validate accepts evidence with decision_record' "$TMPROOT/s10-validate-decision.json" \
  'j["valid"] == true && j["errors"].empty?'

# ---- Group 7: validate rejects malformed decision_record ----

S10_BAD_DECISION_EVIDENCE="$TMPROOT/s10-bad-decision-evidence.json"
"$CLI" evidence init --output "$S10_BAD_DECISION_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"bad decision.","created_at"=>"2026-06-29T10:00:00Z","decision_record"=>"not-a-hash"}
File.write(p, JSON.pretty_generate(j))' "$S10_BAD_DECISION_EVIDENCE"
if "$CLI" validate --task "$S10_TASK" --evidence "$S10_BAD_DECISION_EVIDENCE" --json >"$TMPROOT/s10-bad-decision-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects non-Hash decision_record: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects non-Hash decision_record'
json_assert 'validate reports decision_record error for string value' "$TMPROOT/s10-bad-decision-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".decision_record") }'

# Validate rejects decision_record with invalid kind.
S10_BAD_KIND_EVIDENCE="$TMPROOT/s10-bad-kind-evidence.json"
"$CLI" evidence init --output "$S10_BAD_KIND_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"bad kind.","created_at"=>"2026-06-29T10:00:00Z","decision_record"=>{"id"=>"x","kind"=>"totally_invalid","summary"=>"s","source":"src"}}
File.write(p, JSON.pretty_generate(j))' "$S10_BAD_KIND_EVIDENCE"
if "$CLI" validate --task "$S10_TASK" --evidence "$S10_BAD_KIND_EVIDENCE" --json >"$TMPROOT/s10-bad-kind-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects invalid decision_record kind: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects decision_record with invalid kind'
json_assert 'validate reports decision_record.kind error' "$TMPROOT/s10-bad-kind-validate.json" \
  'j["errors"].any? { |e| e["source"].end_with?(".decision_record.kind") }'

# ---- Group 8: handoff lists active decisions and expired constraints ----

S10_HANDOFF_STATE="$TMPROOT/s10-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S10_TASK" "$S10_EVIDENCE" "$S10_HANDOFF_STATE"
"$CLI" handoff --task "$S10_TASK" --evidence "$S10_EVIDENCE" \
  --state "$S10_HANDOFF_STATE" --json >"$TMPROOT/s10-handoff.json" 2>/dev/null || true
json_assert 'handoff includes decision_record_summary' "$TMPROOT/s10-handoff.json" \
  'j.key?("decision_record_summary") && j["decision_record_summary"].is_a?(Hash)'
json_assert 'handoff decision_record_summary has active user_confirmation' "$TMPROOT/s10-handoff.json" \
  'drs = j["decision_record_summary"]; drs["active_count"] == 1 && drs["active_decisions"].any? { |d| d["kind"] == "user_confirmation" && d["effective_status"] == "active" }'
json_assert 'handoff readable_summary has active_decisions_count' "$TMPROOT/s10-handoff.json" \
  'j["readable_summary"]["active_decisions_count"] == 1'
pass 'handoff includes active user confirmation decision'

# ---- Group 9: handoff reports expired decisions ----

S10_EXPIRED_EVIDENCE="$TMPROOT/s10-expired-evidence.json"
"$CLI" evidence init --output "$S10_EXPIRED_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"expired decision.","created_at"=>"2026-06-29T10:00:00Z","decision_record"=>{"id"=>"decision-expired","kind"=>"user_confirmation","summary":"old confirmation","source":"chat","expires":"2020-01-01T00:00:00Z"}}
File.write(p, JSON.pretty_generate(j))' "$S10_EXPIRED_EVIDENCE"
"$CLI" handoff --task "$S10_TASK" --evidence "$S10_EXPIRED_EVIDENCE" \
  --state "$S10_HANDOFF_STATE" --json >"$TMPROOT/s10-handoff-expired.json" 2>/dev/null || true
json_assert 'handoff reports expired decision' "$TMPROOT/s10-handoff-expired.json" \
  'drs = j["decision_record_summary"]; drs["expired_count"] == 1 && drs["expired_decisions"].any? { |d| d["effective_status"] == "expired" }'
json_assert 'handoff readable_summary has expired_decisions_count' "$TMPROOT/s10-handoff-expired.json" \
  'j["readable_summary"]["expired_decisions_count"] == 1'

# ---- Group 10: lesson_candidate not auto-promoted to promoted_rule ----

printf '%s\n' '# Lesson Doc' 'status: active' >"$TMPROOT/s10-docs/lesson.md"
"$CLI" docs alias --id s10.lesson --path "$TMPROOT/s10-docs/lesson.md" \
  --registry "$S10_REGISTRY" --status lesson_candidate --json >"$TMPROOT/s10-alias-lesson.json"
json_assert 'docs alias lesson_candidate status recorded' "$TMPROOT/s10-alias-lesson.json" \
  'j["entry"]["doc_lifecycle"]["status"] == "lesson_candidate"'
# docs check should show lesson_candidate in summary but NOT as promoted_rule.
"$CLI" docs check --registry "$S10_REGISTRY" --open-dir "$TMPROOT/s10-docs-noop" --json >"$TMPROOT/s10-check-lesson.json" 2>/dev/null || true
json_assert 'docs check lesson_candidate not auto-promoted' "$TMPROOT/s10-check-lesson.json" \
  'dls = j["doc_lifecycle_summary"]; dls["statuses"]["lesson_candidate"] == 1 && dls["statuses"]["promoted_rule"].nil? && dls["has_promoted_rule"] == false'

# Lesson with content claiming promoted but lifecycle not changed triggers warning.
printf '%s\n' '# Promoted Lesson' 'status: active' 'promoted: true' >"$TMPROOT/s10-docs/lesson.md"
"$CLI" docs check --registry "$S10_REGISTRY" --open-dir "$TMPROOT/s10-docs-noop" --json >"$TMPROOT/s10-check-lesson-promoted.json" 2>/dev/null || true
json_assert 'docs check warns lesson_candidate claiming promoted' "$TMPROOT/s10-check-lesson-promoted.json" \
  'j["warnings"].any? { |w| w["source"] == "docs_registry.s10.lesson.doc_lifecycle.status" && w["message"].include?("promoted_rule") }'
pass 'lesson promotion to runtime rules requires explicit status change'

# Explicit promotion to promoted_rule clears the warning.
"$CLI" docs alias --id s10.lesson --path "$TMPROOT/s10-docs/lesson.md" \
  --registry "$S10_REGISTRY" --status promoted_rule --json >"$TMPROOT/s10-alias-promoted.json"
"$CLI" docs check --registry "$S10_REGISTRY" --open-dir "$TMPROOT/s10-docs-noop" --json >"$TMPROOT/s10-check-promoted.json" 2>/dev/null || true
json_assert 'docs check promoted_rule no lesson_candidate warning' "$TMPROOT/s10-check-promoted.json" \
  'dls = j["doc_lifecycle_summary"]; dls["statuses"]["promoted_rule"] == 1 && j["warnings"].none? { |w| w["source"] == "docs_registry.s10.lesson.doc_lifecycle.status" }'

# ---- Group 11: doc status validation rejects invalid status ----

if "$CLI" docs alias --id s10.bad --path "$TMPROOT/s10-docs/baseline.md" --registry "$S10_REGISTRY" --status totally_invalid --json 2>/dev/null; then
  printf 'FAIL docs alias rejects invalid doc_lifecycle status: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'docs alias rejects invalid doc_lifecycle status'

# ---- Group 12: audit includes decision_record_summary ----

S10_STATE="$TMPROOT/s10-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S10_TASK" "$S10_EVIDENCE" "$S10_STATE"
"$CLI" audit --task "$S10_TASK" --evidence "$S10_EVIDENCE" --state "$S10_STATE" --json >"$TMPROOT/s10-audit.json" 2>/dev/null || true
json_assert 'audit packet includes decision_record_summary' "$TMPROOT/s10-audit.json" \
  'j.key?("decision_record_summary") && j["decision_record_summary"]["active_count"] == 1'

# ---- Group 13: evidence add --decision-record persists decision_record ----

S10_ADD_EVIDENCE="$TMPROOT/s10-add-evidence.json"
"$CLI" evidence init --output "$S10_ADD_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add \
  --file "$S10_ADD_EVIDENCE" \
  --kind command \
  --status pass \
  --summary "Command with user confirmation decision." \
  --decision-record '{"id":"decision-add-001","kind":"user_confirmation","summary":"User confirmed approach","source":"chat:user","applies_to":{"task":"s10-task"},"expires":"2099-12-31T00:00:00Z"}' \
  --json >/dev/null
json_assert 'evidence add persists decision_record' "$S10_ADD_EVIDENCE" \
  'j["records"].any? { |r| r["decision_record"].is_a?(Hash) && r["decision_record"]["id"] == "decision-add-001" && r["decision_record"]["kind"] == "user_confirmation" }'

# validate passes with evidence add decision_record.
"$CLI" validate --task "$S10_TASK" --evidence "$S10_ADD_EVIDENCE" --json >"$TMPROOT/s10-validate-add.json" 2>/dev/null || true
json_assert 'validate accepts evidence add with decision_record' "$TMPROOT/s10-validate-add.json" \
  'j["errors"].none? { |e| e["source"].include?("decision_record") }'

# handoff sees the active decision from evidence add.
S10_ADD_HANDOFF_STATE="$TMPROOT/s10-add-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S10_TASK" "$S10_ADD_EVIDENCE" "$S10_ADD_HANDOFF_STATE"
"$CLI" handoff --task "$S10_TASK" --evidence "$S10_ADD_EVIDENCE" --state "$S10_ADD_HANDOFF_STATE" --json >"$TMPROOT/s10-add-handoff.json" 2>/dev/null || true
json_assert 'handoff sees active decision from evidence add' "$TMPROOT/s10-add-handoff.json" \
  'j["decision_record_summary"]["active_decisions"].any? { |d| d["id"] == "decision-add-001" }'
pass 'evidence add --decision-record persists and surfaces in handoff'

# evidence add rejects invalid decision_record kind.
if ORBIT_INSTANCE=reviewer "$CLI" evidence add \
  --file "$S10_ADD_EVIDENCE" \
  --kind command \
  --status pass \
  --summary "bad kind" \
  --decision-record '{"id":"x","kind":"totally_invalid","summary":"s","source":"src"}' \
  --json 2>/dev/null; then
  printf 'FAIL evidence add rejects invalid decision_record kind: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'evidence add rejects invalid decision_record kind'

# ---- Group 14: evidence submit rejects invalid decision_record before writing ----

S10_BAD_SUBMIT_EVIDENCE="$TMPROOT/s10-bad-submit-evidence.json"
"$CLI" evidence init --output "$S10_BAD_SUBMIT_EVIDENCE" >/dev/null
cat >"$TMPROOT/s10-review-bad-decision.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review with invalid decision_record kind.
source_message_id: herdr:reviewer:s10-bad-dr
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
counterexample_cases: [bad dr]
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
decision_record:
  id: "bad-001"
  kind: totally_invalid_kind
  summary: "bad"
  source: "chat"
YAML
if ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S10_BAD_SUBMIT_EVIDENCE" \
  --report "$TMPROOT/s10-review-bad-decision.yaml" \
  --task "$S10_TASK" \
  --json 2>/dev/null; then
  printf 'FAIL evidence submit rejects invalid decision_record kind: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'evidence submit rejects invalid decision_record before writing'
# Verify evidence manifest was not polluted.
json_assert 'evidence manifest not polluted by invalid submit' "$S10_BAD_SUBMIT_EVIDENCE" \
  'j["records"].empty?'

# ---- Group 15: docs alias --doc-lifecycle rejects invalid status ----

S10_INVALID_STATUS_REGISTRY="$TMPROOT/s10-invalid-status-registry.json"
printf '%s\n' '# Doc' >"$TMPROOT/s10-docs/doc-for-invalid.md"
if "$CLI" docs alias --id s10.bad --path "$TMPROOT/s10-docs/doc-for-invalid.md" \
  --registry "$S10_INVALID_STATUS_REGISTRY" \
  --doc-lifecycle '{"doc_id":"s10.bad","status":"totally_invalid"}' \
  --json 2>/dev/null; then
  printf 'FAIL docs alias --doc-lifecycle rejects invalid status: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'docs alias --doc-lifecycle rejects invalid status'

# docs alias --doc-lifecycle with valid status succeeds.
"$CLI" docs alias --id s10.good --path "$TMPROOT/s10-docs/doc-for-invalid.md" \
  --registry "$S10_INVALID_STATUS_REGISTRY" \
  --doc-lifecycle '{"doc_id":"s10.good","status":"promoted_rule"}' \
  --json >"$TMPROOT/s10-alias-good-dl.json" 2>/dev/null
json_assert 'docs alias --doc-lifecycle valid status accepted' "$TMPROOT/s10-alias-good-dl.json" \
  'j["entry"]["doc_lifecycle"]["status"] == "promoted_rule"'

# ---- Group 16: decision_record.expires must be valid ISO8601 ----

# a) evidence add --decision-record invalid expires fails and does not add record.
S10_EXPIRES_ADD_EVIDENCE="$TMPROOT/s10-expires-add-evidence.json"
"$CLI" evidence init --output "$S10_EXPIRES_ADD_EVIDENCE" >/dev/null
if ORBIT_INSTANCE=reviewer "$CLI" evidence add \
  --file "$S10_EXPIRES_ADD_EVIDENCE" \
  --kind command --status pass --summary "bad expires add" \
  --decision-record '{"id":"dr-bad-exp-add","kind":"user_confirmation","summary":"s","source":"src","expires":"not-a-date"}' \
  --json 2>/dev/null; then
  printf 'FAIL evidence add invalid expires: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'evidence add invalid expires fails'
json_assert 'evidence add invalid expires does not pollute manifest' "$S10_EXPIRES_ADD_EVIDENCE" \
  'j["records"].empty?'

# b) evidence submit invalid expires fails and does not add record.
S10_EXPIRES_SUBMIT_EVIDENCE="$TMPROOT/s10-expires-submit-evidence.json"
"$CLI" evidence init --output "$S10_EXPIRES_SUBMIT_EVIDENCE" >/dev/null
cat >"$TMPROOT/s10-submit-bad-expires.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review with bad expires.
source_message_id: herdr:reviewer:s10-bad-exp-submit
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
counterexample_cases: [bad expires]
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
decision_record:
  id: "dr-bad-exp-submit"
  kind: user_confirmation
  summary: "bad"
  source: "chat"
  expires: "not-a-date"
YAML
if ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S10_EXPIRES_SUBMIT_EVIDENCE" \
  --report "$TMPROOT/s10-submit-bad-expires.yaml" \
  --task "$S10_TASK" \
  --json 2>/dev/null; then
  printf 'FAIL evidence submit invalid expires: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'evidence submit invalid expires fails'
json_assert 'evidence submit invalid expires does not pollute manifest' "$S10_EXPIRES_SUBMIT_EVIDENCE" \
  'j["records"].empty?'

# c) evidence from-report invalid expires fails and does not add record.
S10_EXPIRES_FROMREPORT_EVIDENCE="$TMPROOT/s10-expires-fromreport-evidence.json"
"$CLI" evidence init --output "$S10_EXPIRES_FROMREPORT_EVIDENCE" >/dev/null
cat >"$TMPROOT/s10-fromreport-bad-expires.yaml" <<'YAML'
kind: review
verdict: pass
summary: From-report with bad expires.
source_message_id: herdr:reviewer:s10-bad-exp-fr
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
counterexample_cases: [bad expires fr]
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
decision_record:
  id: "dr-bad-exp-fr"
  kind: user_confirmation
  summary: "bad fr"
  source: "chat"
  expires: "also-not-a-date"
YAML
if ORBIT_INSTANCE=reviewer "$CLI" evidence from-report \
  --file "$S10_EXPIRES_FROMREPORT_EVIDENCE" \
  --report "$TMPROOT/s10-fromreport-bad-expires.yaml" \
  --json 2>/dev/null; then
  printf 'FAIL evidence from-report invalid expires: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'evidence from-report invalid expires fails'
json_assert 'evidence from-report invalid expires does not pollute manifest' "$S10_EXPIRES_FROMREPORT_EVIDENCE" \
  'j["records"].empty?'

# d) validate rejects manually injected invalid expires.
S10_INJECT_EXPIRES_EVIDENCE="$TMPROOT/s10-inject-expires-evidence.json"
"$CLI" evidence init --output "$S10_INJECT_EXPIRES_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary"=>"injected bad expires.","created_at"=>"2026-06-29T10:00:00Z","decision_record"=>{"id"=>"x","kind"=>"user_confirmation","summary":"s","source":"src","expires":"not-a-date"}}
File.write(p, JSON.pretty_generate(j))' "$S10_INJECT_EXPIRES_EVIDENCE"
if "$CLI" validate --task "$S10_TASK" --evidence "$S10_INJECT_EXPIRES_EVIDENCE" --json >"$TMPROOT/s10-inject-expires-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects injected invalid expires: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects injected invalid expires'
json_assert 'validate reports decision_record.expires error' "$TMPROOT/s10-inject-expires-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".decision_record.expires") }'

# ---- Group 17: docs alias --doc-lifecycle hard fails on non-mapping or missing doc_id ----

# e1) --doc-lifecycle with array (non-mapping) fails.
S10_ARRAY_DL_REGISTRY="$TMPROOT/s10-array-dl-registry.json"
if "$CLI" docs alias --id s10.arr --path "$TMPROOT/s10-docs/doc-for-invalid.md" \
  --registry "$S10_ARRAY_DL_REGISTRY" \
  --doc-lifecycle '["not","a","hash"]' \
  --json 2>/dev/null; then
  printf 'FAIL docs alias --doc-lifecycle array: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'docs alias --doc-lifecycle rejects non-mapping (array)'

# e2) --doc-lifecycle with mapping but missing doc_id fails.
S10_NO_DOCID_DL_REGISTRY="$TMPROOT/s10-no-docid-dl-registry.json"
if "$CLI" docs alias --id s10.nodocid --path "$TMPROOT/s10-docs/doc-for-invalid.md" \
  --registry "$S10_NO_DOCID_DL_REGISTRY" \
  --doc-lifecycle '{"status":"open_design"}' \
  --json 2>/dev/null; then
  printf 'FAIL docs alias --doc-lifecycle missing doc_id: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'docs alias --doc-lifecycle rejects missing doc_id'

# ---- Group 18: docs alias --doc-lifecycle doc_id must match --id ----

S10_MISMATCH_REGISTRY="$TMPROOT/s10-mismatch-registry.json"
if "$CLI" docs alias --id doc.real --path "$TMPROOT/s10-docs/doc-for-invalid.md" \
  --registry "$S10_MISMATCH_REGISTRY" \
  --doc-lifecycle '{"doc_id":"doc.other","status":"open_design"}' \
  --json 2>/dev/null; then
  printf 'FAIL docs alias --doc-lifecycle mismatched doc_id: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'docs alias --doc-lifecycle rejects mismatched doc_id'
# Registry file must not have been created or polluted.
test ! -f "$S10_MISMATCH_REGISTRY"
pass 'docs alias mismatched doc_id does not create registry'

# Matching doc_id still succeeds.
S10_MATCH_REGISTRY="$TMPROOT/s10-match-registry.json"
"$CLI" docs alias --id doc.match --path "$TMPROOT/s10-docs/doc-for-invalid.md" \
  --registry "$S10_MATCH_REGISTRY" \
  --doc-lifecycle '{"doc_id":"doc.match","status":"open_design"}' \
  --json >"$TMPROOT/s10-alias-match.json" 2>/dev/null
json_assert 'docs alias --doc-lifecycle matching doc_id accepted' "$TMPROOT/s10-alias-match.json" \
  'j["entry"]["doc_lifecycle"]["doc_id"] == "doc.match" && j["entry"]["doc_lifecycle"]["status"] == "open_design"'

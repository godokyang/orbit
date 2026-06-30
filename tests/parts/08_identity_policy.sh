# ---------------------------------------------------------------------------
# Slice 5: Role Identity And Write Policy Minimum
# ---------------------------------------------------------------------------

S5_TASK="$TMPROOT/s5-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S5_TASK" >/dev/null

# new-task seeds write_policy_enforcement: standard
yaml_assert 'new-task seeds write_policy_enforcement: standard' "$S5_TASK" \
  'j["write_policy_enforcement"] == "standard"'

# new-task includes role_identity_minimum in feature_versions
yaml_assert 'new-task includes role_identity_minimum in feature_versions' "$S5_TASK" \
  'j.dig("schema_semantics","feature_versions","role_identity_minimum") == "v1"'

# validate accepts write_policy_enforcement: standard
"$CLI" validate --task "$S5_TASK" --json >"$TMPROOT/s5-validate.json" 2>/dev/null || true
json_assert 'validate accepts task with write_policy_enforcement: standard' "$TMPROOT/s5-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("write_policy_enforcement") }'

# validate accepts write_policy_enforcement: strict
S5_STRICT_TASK="$TMPROOT/s5-strict-task.yaml"
cp "$S5_TASK" "$S5_STRICT_TASK"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["write_policy_enforcement"]="strict"
   File.write(p, YAML.dump(y))' \
  "$S5_STRICT_TASK"
"$CLI" validate --task "$S5_STRICT_TASK" --json >"$TMPROOT/s5-strict-validate.json" 2>/dev/null || true
json_assert 'validate accepts write_policy_enforcement: strict' "$TMPROOT/s5-strict-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("write_policy_enforcement") }'

# validate rejects invalid write_policy_enforcement value
S5_BAD_WPE_TASK="$TMPROOT/s5-bad-wpe-task.yaml"
cp "$S5_TASK" "$S5_BAD_WPE_TASK"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["write_policy_enforcement"]="always"
   File.write(p, YAML.dump(y))' \
  "$S5_BAD_WPE_TASK"
if "$CLI" validate --task "$S5_BAD_WPE_TASK" --json >"$TMPROOT/s5-bad-wpe.json" 2>/dev/null; then
  printf 'FAIL validate rejects write_policy_enforcement with invalid value: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects write_policy_enforcement with invalid value'
json_assert 'write_policy_enforcement error references task_file.write_policy_enforcement' "$TMPROOT/s5-bad-wpe.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.write_policy_enforcement" }'

# evidence submit with --task records task_sha256 in role context or legacy identity
S5_REVIEW_TASK="$TMPROOT/s5-review-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S5_REVIEW_TASK" >/dev/null
cat >"$TMPROOT/s5-review-report.yaml" <<'YAML'
kind: review
verdict: pass
summary: Slice 5 identity hash test.
source_message_id: slice5:test:hash
quality_outcome_verdict: pass
quality_outcome_reasoning: Identity fields test.
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: identity_hash_propagation
      verdict: pass
      evidence: task SHA256 stored in identity block
  not_applicable: []
confirmed:
  - identity hash fields present in submitted record
assumed: []
missing: []
residual_risk: None identified.
counterexample_cases:
  - no counterexamples found; identity hash is purely additive
implementation_readiness_verdict: not_checked
findings: []
coverage:
  - identity hash propagation verified
artifacts: []
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: task quality_outcome satisfied
  - id: counterexamples
    verdict: pass
    evidence: no counterexamples identified
  - id: evidence_sufficiency
    verdict: pass
    evidence: identity hash fields verified
  - id: residual_risk
    verdict: pass
    evidence: no residual risk
YAML
S5_HASH_EVIDENCE="$TMPROOT/s5-hash-evidence.json"
"$CLI" evidence init --output "$S5_HASH_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S5_HASH_EVIDENCE" \
  --report "$TMPROOT/s5-review-report.yaml" \
  --task "$S5_REVIEW_TASK" \
  --json >"$TMPROOT/s5-hash-submit.json"
json_assert 'evidence submit with --task records task_sha256 in role context' "$TMPROOT/s5-hash-submit.json" \
  '(j["record"]["role_execution_context"] || j["record"]["identity"]).fetch("task_sha256", nil).is_a?(String) && (j["record"]["role_execution_context"] || j["record"]["identity"]).fetch("task_sha256", nil).length == 64'

# evidence submit without --task has no task_sha256
S5_NO_HASH_EVIDENCE="$TMPROOT/s5-no-hash-evidence.json"
"$CLI" evidence init --output "$S5_NO_HASH_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S5_NO_HASH_EVIDENCE" \
  --report "$TMPROOT/s5-review-report.yaml" \
  --json >"$TMPROOT/s5-no-hash-submit.json"
json_assert 'evidence submit without --task has no task_sha256 in role context' "$TMPROOT/s5-no-hash-submit.json" \
  '(j["record"]["role_execution_context"] || j["record"]["identity"] || {}).fetch("task_sha256", nil).nil?'

# evidence submit with write_policy in report includes write_policy in record
cat >"$TMPROOT/s5-review-with-wp.yaml" <<'YAML'
kind: review
verdict: pass
summary: Slice 5 write policy propagation test.
source_message_id: slice5:test:write-policy
quality_outcome_verdict: pass
quality_outcome_reasoning: Write policy test.
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: write_policy_propagation
      verdict: pass
      evidence: write_policy block propagated from report to record
  not_applicable: []
confirmed:
  - write_policy propagated to evidence record
assumed: []
missing: []
residual_risk: None.
counterexample_cases:
  - no counterexamples found; write_policy is purely additive
implementation_readiness_verdict: not_checked
findings: []
coverage:
  - write policy propagation verified
artifacts: []
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: task quality_outcome satisfied
  - id: counterexamples
    verdict: pass
    evidence: no counterexamples identified
  - id: evidence_sufficiency
    verdict: pass
    evidence: write_policy propagation verified
  - id: residual_risk
    verdict: pass
    evidence: no residual risk
write_policy:
  expected: no_production_writes
  changed_files:
    - docs/NOTES.md
  violations: []
YAML
S5_WP_EVIDENCE="$TMPROOT/s5-wp-evidence.json"
"$CLI" evidence init --output "$S5_WP_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S5_WP_EVIDENCE" \
  --report "$TMPROOT/s5-review-with-wp.yaml" \
  --json >"$TMPROOT/s5-wp-submit.json"
json_assert 'evidence submit with write_policy in report includes write_policy in record' "$TMPROOT/s5-wp-submit.json" \
  'j["record"]["write_policy"]["expected"] == "no_production_writes" && j["record"]["write_policy"]["changed_files"] == ["docs/NOTES.md"] && j["record"]["write_policy"]["violations"] == []'

# validate passes evidence record with valid write_policy
"$CLI" validate --task "$S5_REVIEW_TASK" --evidence "$S5_WP_EVIDENCE" --json \
  >"$TMPROOT/s5-wp-validate.json" 2>/dev/null || true
json_assert 'validate passes evidence record with valid write_policy' "$TMPROOT/s5-wp-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("write_policy") }'

# validate rejects evidence record with non-array write_policy.changed_files
S5_BAD_WP_EVIDENCE="$TMPROOT/s5-bad-wp-evidence.json"
"$CLI" evidence init --output "$S5_BAD_WP_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"audit","status"=>"pass","summary"=>"Bad write_policy.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "write_policy"=>{"expected"=>"no_production_writes","changed_files"=>"not-a-list","violations"=>[]}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S5_BAD_WP_EVIDENCE"
if "$CLI" validate --task "$S5_TASK" --evidence "$S5_BAD_WP_EVIDENCE" --json \
     >"$TMPROOT/s5-bad-wp.json" 2>/dev/null; then
  printf 'FAIL validate rejects evidence record with non-array write_policy.changed_files: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects evidence record with non-array write_policy.changed_files'
json_assert 'write_policy.changed_files error references write_policy source' "$TMPROOT/s5-bad-wp.json" \
  'j["errors"].any? { |e| e["source"].include?("write_policy") }'

# wait-gate passes when write_policy has violations but enforcement is standard (default)
S5_REVIEW_TASK_STD="$TMPROOT/s5-review-task-std.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S5_REVIEW_TASK_STD" >/dev/null
# Build strict task first so its sha256 can be embedded in evidence records
S5_STRICT_REVIEW_TASK="$TMPROOT/s5-strict-review-task.yaml"
cp "$S5_REVIEW_TASK_STD" "$S5_STRICT_REVIEW_TASK"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["write_policy_enforcement"]="strict"
   File.write(p, YAML.dump(y))' \
  "$S5_STRICT_REVIEW_TASK"
S5_VIOLATION_EVIDENCE="$TMPROOT/s5-violation-evidence.json"
"$CLI" evidence init --output "$S5_VIOLATION_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"review","status"=>"pass","summary"=>"Review with write violations.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "identity"=>{"resolved_role"=>"reviewer","task_sha256"=>sha,"rules_context_sha256"=>"b"*64},
     "quality_outcome_verdict"=>"pass",
     "evidence_level"=>"outcome_quality",
     "quality_question_answers"=>[
       {"id"=>"outcome","verdict"=>"pass"},
       {"id"=>"counterexamples","verdict"=>"pass"},
       {"id"=>"evidence_sufficiency","verdict"=>"pass"},
       {"id"=>"residual_risk","verdict"=>"pass"}
     ],
     "write_policy"=>{"expected"=>"no_production_writes","changed_files"=>["src/impl.rb"],"violations"=>["src/impl.rb"]}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S5_VIOLATION_EVIDENCE" "$S5_STRICT_REVIEW_TASK"
# Slice 9: evidence must carry the current task sha to avoid stale-verdict arbitration.
# Build a standard-task evidence variant with the standard task sha for the standard-enforcement test.
S5_VIOLATION_EVIDENCE_STD="$TMPROOT/s5-violation-evidence-std.json"
"$CLI" evidence init --output "$S5_VIOLATION_EVIDENCE_STD" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"review","status"=>"pass","summary"=>"Review with write violations.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "identity"=>{"resolved_role"=>"reviewer","task_sha256"=>sha,"rules_context_sha256"=>"b"*64},
     "quality_outcome_verdict"=>"pass",
     "evidence_level"=>"outcome_quality",
     "quality_question_answers"=>[
       {"id"=>"outcome","verdict"=>"pass"},
       {"id"=>"counterexamples","verdict"=>"pass"},
       {"id"=>"evidence_sufficiency","verdict"=>"pass"},
       {"id"=>"residual_risk","verdict"=>"pass"}
     ],
     "write_policy"=>{"expected"=>"no_production_writes","changed_files"=>["src/impl.rb"],"violations"=>["src/impl.rb"]}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S5_VIOLATION_EVIDENCE_STD" "$S5_REVIEW_TASK_STD"
"$CLI" wait-gate --task "$S5_REVIEW_TASK_STD" --evidence "$S5_VIOLATION_EVIDENCE_STD" --json \
  >"$TMPROOT/s5-wg-standard.json" 2>/dev/null || true
json_assert 'wait-gate passes when write_policy has violations but enforcement is standard' "$TMPROOT/s5-wg-standard.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true }'

# wait-gate blocks when write_policy has violations and enforcement is strict
if "$CLI" wait-gate --task "$S5_STRICT_REVIEW_TASK" --evidence "$S5_VIOLATION_EVIDENCE" --json \
     >"$TMPROOT/s5-wg-strict.json" 2>/dev/null; then
  printf 'FAIL wait-gate blocks when write_policy has violations and strict enforcement: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate blocks when write_policy has violations and strict enforcement'
json_assert 'wait-gate strict blocking_reason is write_policy_violations' "$TMPROOT/s5-wg-strict.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "write_policy_violations" }'

# wait-gate passes when no violations under strict enforcement
S5_NO_VIOLATION_EVIDENCE="$TMPROOT/s5-no-violation-evidence.json"
"$CLI" evidence init --output "$S5_NO_VIOLATION_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"review","status"=>"pass","summary"=>"Review with no violations.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "identity"=>{"resolved_role"=>"reviewer","task_sha256"=>sha,"rules_context_sha256"=>"b"*64},
     "quality_outcome_verdict"=>"pass",
     "evidence_level"=>"outcome_quality",
     "quality_question_answers"=>[
       {"id"=>"outcome","verdict"=>"pass"},
       {"id"=>"counterexamples","verdict"=>"pass"},
       {"id"=>"evidence_sufficiency","verdict"=>"pass"},
       {"id"=>"residual_risk","verdict"=>"pass"}
     ],
     "write_policy"=>{"expected"=>"no_production_writes","changed_files"=>[],"violations"=>[]}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S5_NO_VIOLATION_EVIDENCE" "$S5_STRICT_REVIEW_TASK"
"$CLI" wait-gate --task "$S5_STRICT_REVIEW_TASK" --evidence "$S5_NO_VIOLATION_EVIDENCE" --json \
  >"$TMPROOT/s5-wg-no-violation.json" 2>/dev/null
json_assert 'wait-gate passes when no write_policy violations under strict enforcement' "$TMPROOT/s5-wg-no-violation.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true }'

# audit includes write_policy_summary
S5_AUDIT_TASK="$TMPROOT/s5-audit-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S5_AUDIT_TASK" >/dev/null
S5_AUDIT_EVIDENCE="$TMPROOT/s5-audit-evidence.json"
"$CLI" evidence init --output "$S5_AUDIT_EVIDENCE" >/dev/null
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S5_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="done"; s["status"]="done"; File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml
"$CLI" audit --task "$S5_AUDIT_TASK" --evidence "$S5_AUDIT_EVIDENCE" \
  --state .orbit/loop-state.yaml --json >"$TMPROOT/s5-audit.json" 2>/dev/null || true
json_assert 'audit includes write_policy_summary field' "$TMPROOT/s5-audit.json" \
  'j.key?("write_policy_summary")'
json_assert 'audit write_policy_summary enforcement is standard' "$TMPROOT/s5-audit.json" \
  'j["write_policy_summary"]["enforcement"] == "standard"'

# audit write_policy_summary counts legacy structured gate records without task_sha256
S5_LEGACY_EVIDENCE="$TMPROOT/s5-legacy-evidence.json"
"$CLI" evidence init --output "$S5_LEGACY_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"review","status"=>"pass","summary"=>"Legacy review (no task_sha256).",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "identity"=>{"resolved_role"=>"reviewer"}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S5_LEGACY_EVIDENCE"
"$CLI" audit --task "$S5_AUDIT_TASK" --evidence "$S5_LEGACY_EVIDENCE" \
  --state .orbit/loop-state.yaml --json >"$TMPROOT/s5-legacy-audit.json" 2>/dev/null || true
json_assert 'audit write_policy_summary counts legacy records without task_sha256' "$TMPROOT/s5-legacy-audit.json" \
  'j["write_policy_summary"]["legacy_records_without_hash"] == 1'

# ---------------------------------------------------------------------------
# Regression: strict task blocks gate when review evidence has no task_sha256
# ---------------------------------------------------------------------------

# evidence with structured review pass but no task_sha256
S5_NO_HASH_REVIEW_EVIDENCE="$TMPROOT/s5-no-hash-review-evidence.json"
"$CLI" evidence init --output "$S5_NO_HASH_REVIEW_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{"kind"=>"review","status"=>"pass","summary"=>"No task_sha256 review.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "identity"=>{"resolved_role"=>"reviewer"},
     "quality_outcome_verdict"=>"pass",
     "evidence_level"=>"outcome_quality",
     "quality_question_answers"=>[
       {"id"=>"outcome","verdict"=>"pass"},
       {"id"=>"counterexamples","verdict"=>"pass"},
       {"id"=>"evidence_sufficiency","verdict"=>"pass"},
       {"id"=>"residual_risk","verdict"=>"pass"}
     ]}
   File.write(p, JSON.pretty_generate(j))' \
  "$S5_NO_HASH_REVIEW_EVIDENCE"

# standard enforcement: missing task_sha256 does not block gate
"$CLI" wait-gate --task "$S5_REVIEW_TASK_STD" --evidence "$S5_NO_HASH_REVIEW_EVIDENCE" --json \
  >"$TMPROOT/s5-no-hash-standard.json" 2>/dev/null || true
json_assert 'wait-gate passes when task_sha256 missing and enforcement is standard' "$TMPROOT/s5-no-hash-standard.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true }'

# strict enforcement: missing task_sha256 blocks gate
if "$CLI" wait-gate --task "$S5_STRICT_REVIEW_TASK" --evidence "$S5_NO_HASH_REVIEW_EVIDENCE" --json \
     >"$TMPROOT/s5-no-hash-strict.json" 2>/dev/null; then
  printf 'FAIL wait-gate blocks strict task when review evidence missing task_sha256: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate blocks strict task when review evidence missing task_sha256'
json_assert 'wait-gate strict missing_task_sha256 blocking_reason' "$TMPROOT/s5-no-hash-strict.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "missing_task_sha256" }'

# ---------------------------------------------------------------------------
# Regression: evidence submit records role_config_sha256 in role_execution_context
# ---------------------------------------------------------------------------

# Reuse existing submit result (s5-hash-submit.json from above)
json_assert 'evidence submit records role_config_sha256 in role_execution_context' "$TMPROOT/s5-hash-submit.json" \
  'r=j["record"]["role_execution_context"]; r.is_a?(Hash) && r["role_config_sha256"].is_a?(String) && r["role_config_sha256"].length == 64'

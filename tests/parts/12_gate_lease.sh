# ---------------------------------------------------------------------------
# Slice 9: gate-lease-and-stale-verdict acceptance tests
#
# Slice 9 adds: gate_lease metadata on records, verdict_arbitration reporting
# (accepted/superseded/stale/conflict), gate_lease_summary (active/expired/
# replaceable), and stale-verdict blocking across all gate-trust paths.
# Gate pass/block decisions are arbitration-aware: a stale (old task sha)
# verdict is ignored and cannot close the gate in wait-gate, validate, audit,
# or handoff. Records without a stored task_sha256 (legacy evidence) are still
# accepted for backward compatibility.
# ---------------------------------------------------------------------------

# S9_TASK is a review task (standard enforcement).
S9_TASK="$TMPROOT/s9-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S9_TASK" >/dev/null

# ---- Group 1: late verdict for old task sha is reported stale by arbitration ----

S9_STALE_EVIDENCE="$TMPROOT/s9-stale-evidence.json"
"$CLI" evidence init --output "$S9_STALE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s9-review-pass-stale.yaml" "Review pass for original task revision." "herdr:reviewer:s9-stale"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_STALE_EVIDENCE" \
  --report "$TMPROOT/s9-review-pass-stale.yaml" \
  --task "$S9_TASK" \
  --json >/dev/null

# Mutate the record's stored task_sha256 to simulate a verdict for an OLD task revision.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="review" }; ctx=r["role_execution_context"] || {}; ctx["task_sha256"]="0"*64; r["role_execution_context"]=ctx; File.write(p, JSON.pretty_generate(j))' "$S9_STALE_EVIDENCE"

# wait-gate runs (standard enforcement still accepts latest record, but arbitration reports stale).
"$CLI" wait-gate --task "$S9_TASK" --evidence "$S9_STALE_EVIDENCE" --json >"$TMPROOT/s9-wait-gate-stale.json" 2>/dev/null || true
json_assert 'arbitration reports stale_records for old task sha' "$TMPROOT/s9-wait-gate-stale.json" \
  'va = j["verdict_arbitration"]["gates"].find { |g| g["gate"] == "review" }; va["stale_records"].is_a?(Array) && !va["stale_records"].empty? && va["has_stale"] == true'
json_assert 'gate verdict_arbitration reports stale_records inline' "$TMPROOT/s9-wait-gate-stale.json" \
  'g = j["gates"].find { |x| x["kind"] == "review" }; g["verdict_arbitration"]["has_stale"] == true'
json_assert 'arbitration marks any_stale true when old task sha present' "$TMPROOT/s9-wait-gate-stale.json" \
  'j["verdict_arbitration"]["any_stale"] == true'
pass 'late verdict for old task sha is reported stale by arbitration'

# Under strict enforcement, a stale verdict cannot pass the gate (Slice 6 behavior,
# re-verified here to confirm Slice 9 did not regress stale-verdict blocking).
S9_STRICT_TASK="$TMPROOT/s9-strict-task.yaml"
cp "$S9_TASK" "$S9_STRICT_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["write_policy_enforcement"]="strict"; File.write(p, YAML.dump(y))' "$S9_STRICT_TASK"
# Re-submit a fresh review pass linked to the strict task so role_execution_context carries its sha.
S9_STRICT_EVIDENCE="$TMPROOT/s9-strict-evidence.json"
"$CLI" evidence init --output "$S9_STRICT_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s9-strict-review-pass.yaml" "Review pass linked to strict task." "herdr:reviewer:s9-strict"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_STRICT_EVIDENCE" \
  --report "$TMPROOT/s9-strict-review-pass.yaml" \
  --task "$S9_STRICT_TASK" \
  --json >/dev/null
# Mutate to an old task sha.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="review" }; ctx=r["role_execution_context"] || {}; ctx["task_sha256"]="0"*64; r["role_execution_context"]=ctx; File.write(p, JSON.pretty_generate(j))' "$S9_STRICT_EVIDENCE"
if "$CLI" wait-gate --task "$S9_STRICT_TASK" --evidence "$S9_STRICT_EVIDENCE" --json >"$TMPROOT/s9-wait-gate-strict-stale.json" 2>/dev/null; then
  printf 'FAIL stale task sha verdict does not close current gate under strict enforcement: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'stale verdict for old task sha does not pass gate under strict enforcement'
json_assert 'strict stale gate reports stale_verdict blocking reason' "$TMPROOT/s9-wait-gate-strict-stale.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "stale_verdict" }'
json_assert 'strict stale arbitration reports stale_records' "$TMPROOT/s9-wait-gate-strict-stale.json" \
  'j["verdict_arbitration"]["any_stale"] == true'

# ---- Group 2: new fail supersedes old pass for same gate revision ----

S9_SUPERSEDE_EVIDENCE="$TMPROOT/s9-supersede-evidence.json"
"$CLI" evidence init --output "$S9_SUPERSEDE_EVIDENCE" >/dev/null
# Submit an early review pass linked to S9_TASK.
write_review_pass_report "$TMPROOT/s9-review-pass-early.yaml" "Early review pass (will be superseded)." "herdr:reviewer:s9-early-pass"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_SUPERSEDE_EVIDENCE" \
  --report "$TMPROOT/s9-review-pass-early.yaml" \
  --task "$S9_TASK" \
  --json >/dev/null
# Backdate the early pass record.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["source_message_id"]=="herdr:reviewer:s9-early-pass" }; r["created_at"]="2026-06-01T10:00:00Z"; File.write(p, JSON.pretty_generate(j))' "$S9_SUPERSEDE_EVIDENCE"

# Submit a later review fail for the same task revision.
cat >"$TMPROOT/s9-review-fail-late.yaml" <<'YAML'
kind: review
verdict: fail
summary: Late review fail supersedes early pass.
source_message_id: herdr:reviewer:s9-late-fail
quality_outcome_verdict: fail
quality_outcome_reasoning: A real defect was found after the initial pass.
findings:
  - severity: high
    summary: Defect found in reviewed behavior.
    symptom: Behavior diverges from contract.
    source: evidence review
    consequence: Incorrect output under load.
    remedy: Fix the behavior and re-review.
    failure_class: code_failure
coverage: []
artifacts: []
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_SUPERSEDE_EVIDENCE" \
  --report "$TMPROOT/s9-review-fail-late.yaml" \
  --task "$S9_TASK" \
  --json >/dev/null
# Ensure the late fail is newer.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["source_message_id"]=="herdr:reviewer:s9-late-fail" }; r["created_at"]="2026-06-02T10:00:00Z"; File.write(p, JSON.pretty_generate(j))' "$S9_SUPERSEDE_EVIDENCE"

if "$CLI" wait-gate --task "$S9_TASK" --evidence "$S9_SUPERSEDE_EVIDENCE" --json >"$TMPROOT/s9-wait-gate-supersede.json" 2>/dev/null; then
  printf 'FAIL new fail supersedes old pass: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'new fail supersedes old pass for same gate revision'
json_assert 'arbitration accepted_status is fail when late fail is newest' "$TMPROOT/s9-wait-gate-supersede.json" \
  'va = j["verdict_arbitration"]["gates"].find { |g| g["gate"] == "review" }; va["accepted_status"] == "fail"'
json_assert 'arbitration reports superseded early pass' "$TMPROOT/s9-wait-gate-supersede.json" \
  'va = j["verdict_arbitration"]["gates"].find { |g| g["gate"] == "review" }; va["superseded_records"].is_a?(Array) && !va["superseded_records"].empty?'
json_assert 'arbitration reports conflict between pass and fail' "$TMPROOT/s9-wait-gate-supersede.json" \
  'j["verdict_arbitration"]["any_conflict"] == true'
json_assert 'arbitration accepted_record_id points to late fail' "$TMPROOT/s9-wait-gate-supersede.json" \
  'va = j["verdict_arbitration"]["gates"].find { |g| g["gate"] == "review" }; va["accepted_record_id"] == "herdr:reviewer:s9-late-fail"'

# ---- Group 3: expired lease lets waiting status become replaceable ----

S9_LEASE_EVIDENCE="$TMPROOT/s9-lease-evidence.json"
"$CLI" evidence init --output "$S9_LEASE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {
  "kind"=>"review","status"=>"pass","summary"=>"Review pass with expired lease.",
  "created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,
  "source_message_id"=>"herdr:reviewer:s9-lease",
  "evidence_level"=>"outcome_quality",
  "quality_outcome_verdict"=>"pass",
  "quality_question_answers"=>[{"id"=>"outcome","verdict"=>"pass"},{"id"=>"counterexamples","verdict"=>"pass"},{"id"=>"evidence_sufficiency","verdict"=>"pass"},{"id"=>"residual_risk","verdict"=>"pass"}],
  "residual_risk"=>"none",
  "identity"=>{"resolved_role"=>"reviewer"},
  "gate_lease"=>{
    "gate"=>"review","owner_instance"=>"reviewer","task_sha256"=>"expired-task-sha",
    "status"=>"claimed","claimed_at"=>"2026-06-01T00:00:00Z","expires_at"=>"2026-06-02T00:00:00Z",
    "replacement_policy"=>"allow_after_expiry"
  }
}
File.write(p, JSON.pretty_generate(j))' "$S9_LEASE_EVIDENCE"

"$CLI" wait-gate --task "$S9_TASK" --evidence "$S9_LEASE_EVIDENCE" --json >"$TMPROOT/s9-wait-gate-lease.json" 2>/dev/null || true
json_assert 'wait-gate gate_lease_summary reports expired lease' "$TMPROOT/s9-wait-gate-lease.json" \
  'ls = j["gate_lease_summary"]; ls["expired_count"] == 1'
json_assert 'expired lease is replaceable under allow_after_expiry' "$TMPROOT/s9-wait-gate-lease.json" \
  'ls = j["gate_lease_summary"]; ls["expired_leases"].any? { |l| l["replaceable"] == true && l["effective_status"] == "expired" } && ls["any_replaceable"] == true'
pass 'expired lease lets waiting status become replaceable'

# An active (not-yet-expired) lease is not replaceable.
S9_ACTIVE_LEASE_EVIDENCE="$TMPROOT/s9-active-lease-evidence.json"
"$CLI" evidence init --output "$S9_ACTIVE_LEASE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {
  "kind"=>"review","status"=>"pass","summary"=>"Review pass with active lease.",
  "created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,
  "source_message_id"=>"herdr:reviewer:s9-active-lease",
  "evidence_level"=>"outcome_quality",
  "quality_outcome_verdict"=>"pass",
  "quality_question_answers"=>[{"id"=>"outcome","verdict"=>"pass"},{"id"=>"counterexamples","verdict"=>"pass"},{"id"=>"evidence_sufficiency","verdict"=>"pass"},{"id"=>"residual_risk","verdict"=>"pass"}],
  "residual_risk"=>"none",
  "identity"=>{"resolved_role"=>"reviewer"},
  "gate_lease"=>{
    "gate"=>"review","owner_instance"=>"reviewer",
    "status"=>"claimed","claimed_at"=>"2026-06-29T00:00:00Z","expires_at"=>"2099-12-31T00:00:00Z",
    "replacement_policy"=>"allow_after_expiry"
  }
}
File.write(p, JSON.pretty_generate(j))' "$S9_ACTIVE_LEASE_EVIDENCE"
"$CLI" wait-gate --task "$S9_TASK" --evidence "$S9_ACTIVE_LEASE_EVIDENCE" --json >"$TMPROOT/s9-wait-gate-active-lease.json" 2>/dev/null || true
json_assert 'active lease is not replaceable' "$TMPROOT/s9-wait-gate-active-lease.json" \
  'ls = j["gate_lease_summary"]; ls["active_count"] == 1 && ls["expired_count"] == 0 && ls["any_replaceable"] == false'
json_assert 'active lease reports owner_instance' "$TMPROOT/s9-wait-gate-active-lease.json" \
  'ls = j["gate_lease_summary"]; ls["active_leases"].any? { |l| l["owner_instance"] == "reviewer" && l["effective_status"] == "claimed" }'

# ---- Group 4: audit lists active/expired leases and accepted verdict ----

S9_STATE="$TMPROOT/s9-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S9_TASK" "$S9_LEASE_EVIDENCE" "$S9_STATE"

"$CLI" audit --task "$S9_TASK" --evidence "$S9_LEASE_EVIDENCE" \
  --state "$S9_STATE" \
  --json >"$TMPROOT/s9-audit-lease.json" || true
json_assert 'audit packet includes verdict_arbitration_summary' "$TMPROOT/s9-audit-lease.json" \
  'j.key?("verdict_arbitration_summary") && j["verdict_arbitration_summary"].is_a?(Hash)'
json_assert 'audit packet includes gate_lease_summary with expired lease' "$TMPROOT/s9-audit-lease.json" \
  'ls = j["gate_lease_summary"]; ls["expired_count"] == 1 && ls["expired_leases"].any? { |l| l["owner_instance"] == "reviewer" }'
# Separate evidence with a record whose identity carries a stale task_sha256 for arbitration reporting.
S9_AUDIT_STALE_EVIDENCE="$TMPROOT/s9-audit-stale-evidence.json"
"$CLI" evidence init --output "$S9_AUDIT_STALE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {
  "kind"=>"review","status"=>"pass","summary"=>"Review pass with stale task sha.",
  "created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,
  "source_message_id"=>"herdr:reviewer:s9-audit-stale",
  "evidence_level"=>"outcome_quality",
  "quality_outcome_verdict"=>"pass",
  "quality_question_answers"=>[{"id"=>"outcome","verdict"=>"pass"},{"id"=>"counterexamples","verdict"=>"pass"},{"id"=>"evidence_sufficiency","verdict"=>"pass"},{"id"=>"residual_risk","verdict"=>"pass"}],
  "residual_risk"=>"none",
  "identity"=>{"resolved_role"=>"reviewer","task_sha256"=>"0"*64}
}
File.write(p, JSON.pretty_generate(j))' "$S9_AUDIT_STALE_EVIDENCE"
S9_AUDIT_STALE_STATE="$TMPROOT/s9-audit-stale-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S9_TASK" "$S9_AUDIT_STALE_EVIDENCE" "$S9_AUDIT_STALE_STATE"
"$CLI" audit --task "$S9_TASK" --evidence "$S9_AUDIT_STALE_EVIDENCE" --state "$S9_AUDIT_STALE_STATE" --json >"$TMPROOT/s9-audit-stale.json" || true
json_assert 'audit verdict_arbitration_summary reports stale_records' "$TMPROOT/s9-audit-stale.json" \
  'va = j["verdict_arbitration_summary"]; va["any_stale"] == true && va["gates"].find { |g| g["gate"] == "review" }["has_stale"] == true'

# ---- Group 5: handoff states gate owner, lease status, replacement allowed ----

S9_HANDOFF_STATE="$TMPROOT/s9-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S9_TASK" "$S9_LEASE_EVIDENCE" "$S9_HANDOFF_STATE"

"$CLI" handoff --task "$S9_TASK" --evidence "$S9_LEASE_EVIDENCE" \
  --state "$S9_HANDOFF_STATE" --json >"$TMPROOT/s9-handoff-lease.json" 2>/dev/null || true
json_assert 'handoff packet includes verdict_arbitration' "$TMPROOT/s9-handoff-lease.json" \
  'j.key?("verdict_arbitration") && j["verdict_arbitration"].is_a?(Hash)'
json_assert 'handoff packet includes gate_lease_summary' "$TMPROOT/s9-handoff-lease.json" \
  'j.key?("gate_lease_summary") && j["gate_lease_summary"].is_a?(Hash)'
json_assert 'handoff readable_summary surfaces gate lease counts' "$TMPROOT/s9-handoff-lease.json" \
  'rs = j["readable_summary"]; rs.key?("gate_lease_active") && rs.key?("gate_lease_expired") && rs.key?("gate_owner_replaceable")'
json_assert 'handoff reports expired lease as replaceable' "$TMPROOT/s9-handoff-lease.json" \
  'j["gate_lease_summary"]["any_replaceable"] == true && j["readable_summary"]["gate_owner_replaceable"] == true'

# ---- Group 6: evidence submit carries gate_lease from report to record ----

S9_SUBMIT_LEASE_EVIDENCE="$TMPROOT/s9-submit-lease-evidence.json"
"$CLI" evidence init --output "$S9_SUBMIT_LEASE_EVIDENCE" >/dev/null
cat >"$TMPROOT/s9-review-with-lease.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review pass carrying a gate lease.
source_message_id: herdr:reviewer:s9-submit-lease
quality_outcome_verdict: pass
quality_outcome_reasoning: Lease metadata submitted with the verdict.
findings: []
coverage:
  - lease propagation checked
artifacts: []
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: lease_check
      verdict: pass
      evidence: gate_lease carried through submit.
  not_applicable: []
confirmed:
  - gate_lease carried through submit.
assumed: []
missing: []
residual_risk: "No residual risk."
counterexample_cases:
  - gate_lease must propagate to evidence record.
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
gate_lease:
  gate: review
  owner_instance: reviewer
  status: claimed
  claimed_at: "2026-06-29T00:00:00Z"
  expires_at: "2099-12-31T00:00:00Z"
  replacement_policy: allow_after_expiry
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_SUBMIT_LEASE_EVIDENCE" \
  --report "$TMPROOT/s9-review-with-lease.yaml" \
  --task "$S9_TASK" \
  --json >"$TMPROOT/s9-submit-lease.json"
json_assert 'evidence submit carries gate_lease to record' "$TMPROOT/s9-submit-lease.json" \
  'r = j["record"]; r["gate_lease"].is_a?(Hash) && r["gate_lease"]["gate"] == "review" && r["gate_lease"]["owner_instance"] == "reviewer" && r["gate_lease"]["status"] == "claimed"'
json_assert 'evidence submit preserves gate_lease replacement_policy' "$TMPROOT/s9-submit-lease.json" \
  'j["record"]["gate_lease"]["replacement_policy"] == "allow_after_expiry"'

# ---- Group 7: validate rejects malformed gate_lease mutated after submit ----

S9_BAD_LEASE_EVIDENCE="$TMPROOT/s9-bad-lease-evidence.json"
"$CLI" evidence init --output "$S9_BAD_LEASE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"review","status"=>"pass","summary"=>"bad lease.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"source_message_id"=>"bad","evidence_level"=>"outcome_quality","quality_outcome_verdict"=>"pass","quality_question_answers"=>[{"id"=>"outcome","verdict"=>"pass"},{"id"=>"counterexamples","verdict"=>"pass"},{"id"=>"evidence_sufficiency","verdict"=>"pass"},{"id"=>"residual_risk","verdict"=>"pass"}],"residual_risk"=>"none","identity"=>{"resolved_role"=>"reviewer"},"gate_lease"=>{"gate":"","status"=>"weird"}}
File.write(p, JSON.pretty_generate(j))' "$S9_BAD_LEASE_EVIDENCE"
if "$CLI" validate --task "$S9_TASK" --evidence "$S9_BAD_LEASE_EVIDENCE" --json >"$TMPROOT/s9-bad-lease-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects malformed gate_lease: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects malformed gate_lease metadata'
json_assert 'validate reports gate_lease.gate error for empty gate' "$TMPROOT/s9-bad-lease-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".gate_lease.gate") }'
json_assert 'validate reports gate_lease.status error for unknown status' "$TMPROOT/s9-bad-lease-validate.json" \
  'j["errors"].any? { |e| e["source"].end_with?(".gate_lease.status") }'

# ---- Group 8: evidence manifest schema_semantics includes gate_lease=v1 ----

ruby --disable-gems -rjson -e '
j = JSON.parse(File.read(ARGV[0]))
fv = j["schema_semantics"]["feature_versions"] rescue {}
exit 1 unless fv["gate_lease"] == "v1"' "$S9_STALE_EVIDENCE"
pass 'evidence manifest schema_semantics includes gate_lease=v1'

# ---- Group 9: standard enforcement stale verdict does not close gate (Slice 9 fix) ----

# Submit a legit review pass for S9_TASK (standard enforcement), then mutate task_sha256 to old sha.
S9_STD_STALE_EVIDENCE="$TMPROOT/s9-std-stale-evidence.json"
"$CLI" evidence init --output "$S9_STD_STALE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s9-std-stale-review.yaml" "Standard task review pass with stale sha." "herdr:reviewer:s9-std-stale"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_STD_STALE_EVIDENCE" \
  --report "$TMPROOT/s9-std-stale-review.yaml" \
  --task "$S9_TASK" \
  --json >/dev/null
# Mutate to old task sha.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="review" }; ctx=r["role_execution_context"]||r["identity"]||{}; ctx["task_sha256"]="0"*64; r["role_execution_context"] ? r["role_execution_context"]=ctx : r["identity"]=ctx; File.write(p, JSON.pretty_generate(j))' "$S9_STD_STALE_EVIDENCE"
if "$CLI" wait-gate --task "$S9_TASK" --evidence "$S9_STD_STALE_EVIDENCE" --json >"$TMPROOT/s9-std-stale-wait-gate.json" 2>/dev/null; then
  printf 'FAIL standard enforcement stale verdict does not close gate: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'standard enforcement stale verdict does not close current gate'
json_assert 'standard stale gate passed is false' "$TMPROOT/s9-std-stale-wait-gate.json" \
  'j["ready"] == false && j["gates"].none? { |g| g["passed"] == true }'
json_assert 'standard stale gate blocking_reason is stale_verdict' "$TMPROOT/s9-std-stale-wait-gate.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "stale_verdict" }'
json_assert 'standard stale gate still reports stale_task_sha256 flag' "$TMPROOT/s9-std-stale-wait-gate.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["stale_task_sha256"] == true }'

# ---- Group 10: handoff with stale verdict reports stale, not accepted ----

S9_HANDOFF_STALE_EVIDENCE="$TMPROOT/s9-handoff-stale-evidence.json"
"$CLI" evidence init --output "$S9_HANDOFF_STALE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s9-handoff-stale-review.yaml" "Review pass with stale sha for handoff." "herdr:reviewer:s9-ho-stale"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_HANDOFF_STALE_EVIDENCE" \
  --report "$TMPROOT/s9-handoff-stale-review.yaml" \
  --task "$S9_TASK" \
  --json >/dev/null
# Mutate to old task sha.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="review" }; ctx=r["role_execution_context"]||{}; ctx["task_sha256"]="0"*64; r["role_execution_context"]=ctx; File.write(p, JSON.pretty_generate(j))' "$S9_HANDOFF_STALE_EVIDENCE"
S9_HANDOFF_STALE_STATE="$TMPROOT/s9-handoff-stale-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S9_TASK" "$S9_HANDOFF_STALE_EVIDENCE" "$S9_HANDOFF_STALE_STATE"
"$CLI" handoff --task "$S9_TASK" --evidence "$S9_HANDOFF_STALE_EVIDENCE" \
  --state "$S9_HANDOFF_STALE_STATE" --json >"$TMPROOT/s9-handoff-stale.json" 2>/dev/null || true
json_assert 'handoff arbitration reports stale for old task sha' "$TMPROOT/s9-handoff-stale.json" \
  'va = j["verdict_arbitration"]; va["any_stale"] == true && va["gates"].find { |g| g["gate"] == "review" }["has_stale"] == true'
json_assert 'handoff arbitration does not accept stale record' "$TMPROOT/s9-handoff-stale.json" \
  'va = j["verdict_arbitration"]["gates"].find { |g| g["gate"] == "review" }; va["accepted_record_id"].nil? && !va["stale_records"].empty?'

# ---- Group 11: validate rejects non-Hash gate_lease ----

S9_STRING_LEASE_EVIDENCE="$TMPROOT/s9-string-lease-evidence.json"
"$CLI" evidence init --output "$S9_STRING_LEASE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"review","status"=>"pass","summary"=>"string lease.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"source_message_id"=>"strlease","evidence_level"=>"outcome_quality","quality_outcome_verdict"=>"pass","quality_question_answers"=>[{"id"=>"outcome","verdict"=>"pass"},{"id"=>"counterexamples","verdict"=>"pass"},{"id"=>"evidence_sufficiency","verdict"=>"pass"},{"id"=>"residual_risk","verdict"=>"pass"}],"residual_risk"=>"none","identity"=>{"resolved_role"=>"reviewer"},"gate_lease"=>"bad-string"}
File.write(p, JSON.pretty_generate(j))' "$S9_STRING_LEASE_EVIDENCE"
if "$CLI" validate --task "$S9_TASK" --evidence "$S9_STRING_LEASE_EVIDENCE" --json >"$TMPROOT/s9-string-lease-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects non-Hash gate_lease (string): command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects non-Hash gate_lease (string)'
json_assert 'validate reports gate_lease error for string value' "$TMPROOT/s9-string-lease-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".gate_lease") }'

S9_ARRAY_LEASE_EVIDENCE="$TMPROOT/s9-array-lease-evidence.json"
"$CLI" evidence init --output "$S9_ARRAY_LEASE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"review","status"=>"pass","summary"=>"array lease.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"source_message_id"=>"arrlease","evidence_level"=>"outcome_quality","quality_outcome_verdict"=>"pass","quality_question_answers"=>[{"id"=>"outcome","verdict"=>"pass"},{"id"=>"counterexamples","verdict"=>"pass"},{"id"=>"evidence_sufficiency","verdict"=>"pass"},{"id"=>"residual_risk","verdict"=>"pass"}],"residual_risk"=>"none","identity"=>{"resolved_role"=>"reviewer"},"gate_lease"=>["not","a","hash"]}
File.write(p, JSON.pretty_generate(j))' "$S9_ARRAY_LEASE_EVIDENCE"
if "$CLI" validate --task "$S9_TASK" --evidence "$S9_ARRAY_LEASE_EVIDENCE" --json >"$TMPROOT/s9-array-lease-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects non-Hash gate_lease (array): command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects non-Hash gate_lease (array)'
json_assert 'validate reports gate_lease error for array value' "$TMPROOT/s9-array-lease-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".gate_lease") }'

# ---- Group 12: validate rejects stale verdict (not just wait-gate) ----

S9_VALIDATE_STALE_EVIDENCE="$TMPROOT/s9-validate-stale-evidence.json"
"$CLI" evidence init --output "$S9_VALIDATE_STALE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s9-validate-stale-review.yaml" "Review pass with stale sha for validate." "herdr:reviewer:s9-val-stale"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_VALIDATE_STALE_EVIDENCE" \
  --report "$TMPROOT/s9-validate-stale-review.yaml" \
  --task "$S9_TASK" \
  --json >/dev/null
# Mutate to old task sha.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="review" }; ctx=r["role_execution_context"]||{}; ctx["task_sha256"]="0"*64; r["role_execution_context"]=ctx; File.write(p, JSON.pretty_generate(j))' "$S9_VALIDATE_STALE_EVIDENCE"
if "$CLI" validate --task "$S9_TASK" --evidence "$S9_VALIDATE_STALE_EVIDENCE" --json >"$TMPROOT/s9-validate-stale.json" 2>/dev/null; then
  printf 'FAIL validate rejects stale verdict: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects stale verdict for old task sha'
json_assert 'validate reports stale verdict error' "$TMPROOT/s9-validate-stale.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].include?("review") && e["message"].include?("stale") }'

# ---- Group 13: audit done-state blocks on stale verdict ----

S9_AUDIT_DONE_EVIDENCE="$TMPROOT/s9-audit-done-evidence.json"
"$CLI" evidence init --output "$S9_AUDIT_DONE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s9-audit-done-review.yaml" "Review pass with stale sha for audit done." "herdr:reviewer:s9-audit-done"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S9_AUDIT_DONE_EVIDENCE" \
  --report "$TMPROOT/s9-audit-done-review.yaml" \
  --task "$S9_TASK" \
  --json >/dev/null
# Mutate to old task sha.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="review" }; ctx=r["role_execution_context"]||{}; ctx["task_sha256"]="0"*64; r["role_execution_context"]=ctx; File.write(p, JSON.pretty_generate(j))' "$S9_AUDIT_DONE_EVIDENCE"
S9_AUDIT_DONE_STATE="$TMPROOT/s9-audit-done-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "done", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S9_TASK" "$S9_AUDIT_DONE_EVIDENCE" "$S9_AUDIT_DONE_STATE"
"$CLI" audit --task "$S9_TASK" --evidence "$S9_AUDIT_DONE_EVIDENCE" --state "$S9_AUDIT_DONE_STATE" --json >"$TMPROOT/s9-audit-done-stale.json" || true
json_assert 'audit done-state not done_ready with stale verdict' "$TMPROOT/s9-audit-done-stale.json" \
  'j["done_ready"] == false && j["trusted_for_done"] == false'
json_assert 'audit done-state blocking_findings include stale/gate evidence source' "$TMPROOT/s9-audit-done-stale.json" \
  'j["blocking_findings"].any? { |f| f["source"].include?("review") }'

# ---- Group 14: wait-gate gate_summary is arbitration-aware (not contradictory) ----

# Under stale pass, gate_summary.ready=false, passed does not include review.
json_assert 'wait-gate gate_summary ready is false under stale verdict' "$TMPROOT/s9-std-stale-wait-gate.json" \
  'j["gate_summary"]["ready"] == false'
json_assert 'wait-gate gate_summary passed does not include review under stale' "$TMPROOT/s9-std-stale-wait-gate.json" \
  'gs = j["gate_summary"]; gs["passed"].is_a?(Array) && !gs["passed"].include?("review")'
json_assert 'wait-gate gate_summary not_ready includes stale_verdict blocking reason' "$TMPROOT/s9-std-stale-wait-gate.json" \
  'j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "stale_verdict" }'

# ---- Group 15: handoff summaries are arbitration-aware (not contradictory) ----

json_assert 'handoff gate_summary ready is false under stale verdict' "$TMPROOT/s9-handoff-stale.json" \
  'j["gate_summary"]["ready"] == false'
json_assert 'handoff gate_summary passed does not include review under stale' "$TMPROOT/s9-handoff-stale.json" \
  'gs = j["gate_summary"]; gs["passed"].is_a?(Array) && !gs["passed"].include?("review")'
json_assert 'handoff latest_gate_verdicts review status is not pass under stale' "$TMPROOT/s9-handoff-stale.json" \
  'j["latest_gate_verdicts"]["review"]["status"] != "pass"'
json_assert 'handoff readable_summary latest_review_verdict is not pass under stale' "$TMPROOT/s9-handoff-stale.json" \
  'j["readable_summary"]["latest_review_verdict"] != "pass"'
json_assert 'handoff verdict_arbitration any_stale is true' "$TMPROOT/s9-handoff-stale.json" \
  'j["verdict_arbitration"]["any_stale"] == true'

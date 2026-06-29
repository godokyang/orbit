# ---------------------------------------------------------------------------
# Slice 6: role-identity-and-write-policy-full acceptance tests
# ---------------------------------------------------------------------------

# ---- Group 1: evidence submit writes role_execution_context ----
# Reuse s5-hash-submit.json from 08_identity_policy.sh (submitted with --task)

json_assert 'evidence submit writes role_execution_context block' "$TMPROOT/s5-hash-submit.json" \
  'j["record"].key?("role_execution_context")'

json_assert 'role_execution_context.resolved_role is non-empty string' "$TMPROOT/s5-hash-submit.json" \
  'r=j["record"]["role_execution_context"]; r["resolved_role"].is_a?(String) && !r["resolved_role"].empty?'

json_assert 'role_execution_context.role_config_sha256 is 64-char hex' "$TMPROOT/s5-hash-submit.json" \
  'r=j["record"]["role_execution_context"]; r["role_config_sha256"].is_a?(String) && r["role_config_sha256"].length == 64'

json_assert 'role_execution_context.task_sha256 is 64-char hex' "$TMPROOT/s5-hash-submit.json" \
  'r=j["record"]["role_execution_context"]; r["task_sha256"].is_a?(String) && r["task_sha256"].length == 64'

json_assert 'role_execution_context.permission_profile.mode is audit_only' "$TMPROOT/s5-hash-submit.json" \
  'j["record"]["role_execution_context"]["permission_profile"]["mode"] == "audit_only"'

json_assert 'role_execution_context.worktree is a Hash with git_head key' "$TMPROOT/s5-hash-submit.json" \
  'w=j["record"]["role_execution_context"]["worktree"]; w.is_a?(Hash) && w["git_head"].is_a?(String)'

# ---- Group 2: whoami exposes role_config_sha256 ----

"$CLI" whoami --json >"$TMPROOT/s6-whoami.json" 2>/dev/null || true
json_assert 'whoami includes role_config_sha256 as 64-char hex' "$TMPROOT/s6-whoami.json" \
  'v=j["role_config_sha256"]; v.is_a?(String) && v.length == 64 && v.match?(/\A[0-9a-f]{64}\z/)'

# ---- Group 3: rules print-context writes context_hash ----

ORBIT_INSTANCE=reviewer "$CLI" rules print-context --json \
  >"$TMPROOT/s6-print-context.json" 2>/dev/null || true
json_assert 'rules print-context includes context_hash as 64-char hex' "$TMPROOT/s6-print-context.json" \
  'v=j["context_hash"]; v.is_a?(String) && v.length == 64 && v.match?(/\A[0-9a-f]{64}\z/)'

# ---- Group 4: wait-gate stale_task_sha256 detection ----

# Create two review tasks; differentiate task_B so its sha256 differs from task_A
S6_STALE_TASK_A="$TMPROOT/s6-stale-task-a.yaml"
S6_STALE_TASK_B="$TMPROOT/s6-stale-task-b.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S6_STALE_TASK_A" >/dev/null
cp "$S6_STALE_TASK_A" "$S6_STALE_TASK_B"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["custom_label"] = "stale_task_b_variant"
   File.write(p, YAML.dump(y))' \
  "$S6_STALE_TASK_B"

# Strict version of task_B (for blocking test)
S6_STALE_TASK_B_STRICT="$TMPROOT/s6-stale-task-b-strict.yaml"
cp "$S6_STALE_TASK_B" "$S6_STALE_TASK_B_STRICT"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["write_policy_enforcement"] = "strict"
   File.write(p, YAML.dump(y))' \
  "$S6_STALE_TASK_B_STRICT"

# Submit evidence linked to task_A (record gets task_sha256 of A)
S6_STALE_EVIDENCE="$TMPROOT/s6-stale-evidence.json"
"$CLI" evidence init --output "$S6_STALE_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S6_STALE_EVIDENCE" \
  --report "$TMPROOT/s5-review-report.yaml" \
  --task "$S6_STALE_TASK_A" \
  --json >"$TMPROOT/s6-stale-submit.json"

# Call wait-gate with task_B (sha differs) → stale flag set
"$CLI" wait-gate --task "$S6_STALE_TASK_B" --evidence "$S6_STALE_EVIDENCE" --json \
  >"$TMPROOT/s6-stale-standard.json" 2>/dev/null || true
json_assert 'wait-gate stale evidence sets stale_task_sha256 flag' "$TMPROOT/s6-stale-standard.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["stale_task_sha256"] == true }'

json_assert 'wait-gate standard enforcement passes despite stale evidence' "$TMPROOT/s6-stale-standard.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true }'

# Strict mode + stale → blocked
if "$CLI" wait-gate --task "$S6_STALE_TASK_B_STRICT" --evidence "$S6_STALE_EVIDENCE" --json \
     >"$TMPROOT/s6-stale-strict.json" 2>/dev/null; then
  printf 'FAIL wait-gate strict mode blocks stale evidence: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate strict mode blocks stale evidence'
json_assert 'wait-gate strict stale blocking_reason is stale_task_sha256' "$TMPROOT/s6-stale-strict.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "stale_task_sha256" }'

# ---- Group 5: missing_rules_context_sha256 via role_execution_context (strict mode) ----
# Build inline evidence with role_execution_context: has task_sha256 matching S5_STRICT_REVIEW_TASK
# but deliberately omits rules_context_sha256

S6_NO_RULES_EVIDENCE="$TMPROOT/s6-no-rules-ctx-evidence.json"
"$CLI" evidence init --output "$S6_NO_RULES_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{
     "kind"=>"review","status"=>"pass",
     "summary"=>"role_execution_context without rules_context_sha256.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "role_execution_context"=>{
       "resolved_role"=>"reviewer","task_sha256"=>sha,
       "role_config_sha256"=>"a"*64,
       "instance"=>"reviewer","role_ref"=>"reviewer",
       "worktree"=>{"git_head"=>"abc123","dirty_files_before"=>[]},
       "permission_profile"=>{"mode"=>"audit_only"}},
     "quality_outcome_verdict"=>"pass",
     "evidence_level"=>"outcome_quality",
     "quality_question_answers"=>[
       {"id"=>"outcome","verdict"=>"pass"},
       {"id"=>"counterexamples","verdict"=>"pass"},
       {"id"=>"evidence_sufficiency","verdict"=>"pass"},
       {"id"=>"residual_risk","verdict"=>"pass"}
     ]}
   File.write(p, JSON.pretty_generate(j))' \
  "$S6_NO_RULES_EVIDENCE" "$S5_STRICT_REVIEW_TASK"

if "$CLI" wait-gate --task "$S5_STRICT_REVIEW_TASK" --evidence "$S6_NO_RULES_EVIDENCE" --json \
     >"$TMPROOT/s6-no-rules-strict.json" 2>/dev/null; then
  printf 'FAIL wait-gate strict blocks role_execution_context missing rules_context_sha256: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate strict blocks role_execution_context missing rules_context_sha256'
json_assert 'wait-gate strict role_execution_context no rules_context_sha256 blocking_reason' "$TMPROOT/s6-no-rules-strict.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "missing_rules_context_sha256" }'

# ---- Group 6: audit includes stale_records_summary ----

"$CLI" audit --task "$S5_AUDIT_TASK" --evidence "$S6_STALE_EVIDENCE" \
  --state .orbit/loop-state.yaml --json >"$TMPROOT/s6-audit-stale.json" 2>/dev/null || true
json_assert 'audit includes stale_records_summary field' "$TMPROOT/s6-audit-stale.json" \
  'j.key?("stale_records_summary")'
json_assert 'audit stale_records_summary stale_count is 1' "$TMPROOT/s6-audit-stale.json" \
  'j["stale_records_summary"]["stale_count"] == 1'

# ---- Group 7: validate accepts/rejects role_execution_context schema ----

# Valid role_execution_context: all required SHA256 fields present and hex
S6_VALID_EV="$TMPROOT/s6-valid-rec-evidence.json"
"$CLI" evidence init --output "$S6_VALID_EV" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{
     "kind"=>"audit","status"=>"pass","summary"=>"Valid role_execution_context.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "role_execution_context"=>{
       "resolved_role"=>"lead","task_sha256"=>sha,
       "role_config_sha256"=>"a"*64,"rules_resolution_sha256"=>"b"*64,
       "rules_context_sha256"=>"c"*64,"evidence_manifest_sha256_before_submit"=>"d"*64,
       "instance"=>"lead","role_ref"=>"lead",
       "worktree"=>{"git_head"=>"abc","dirty_files_before"=>[]},
       "permission_profile"=>{"mode"=>"audit_only"}}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S6_VALID_EV" "$S5_AUDIT_TASK"
"$CLI" validate --task "$S5_AUDIT_TASK" --evidence "$S6_VALID_EV" --json \
  >"$TMPROOT/s6-valid-rec.json" 2>/dev/null || true
json_assert 'validate accepts evidence with valid role_execution_context' "$TMPROOT/s6-valid-rec.json" \
  'j["errors"].none? { |e| e["source"].include?("role_execution_context") }'

# Invalid: non-hex role_config_sha256
S6_BAD_EV="$TMPROOT/s6-bad-rec-evidence.json"
"$CLI" evidence init --output "$S6_BAD_EV" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{
     "kind"=>"audit","status"=>"pass","summary"=>"Bad role_config_sha256.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "role_execution_context"=>{
       "resolved_role"=>"lead","task_sha256"=>sha,
       "role_config_sha256"=>"not-a-valid-hex-sha256",
       "instance"=>"lead","role_ref"=>"lead",
       "worktree"=>{"git_head"=>"abc","dirty_files_before"=>[]},
       "permission_profile"=>{"mode"=>"audit_only"}}}
   File.write(p, JSON.pretty_generate(j))' \
  "$S6_BAD_EV" "$S5_AUDIT_TASK"
if "$CLI" validate --task "$S5_AUDIT_TASK" --evidence "$S6_BAD_EV" --json \
     >"$TMPROOT/s6-bad-rec.json" 2>/dev/null; then
  printf 'FAIL validate rejects role_execution_context with non-hex role_config_sha256: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects role_execution_context with non-hex role_config_sha256'
json_assert 'role_execution_context sha256 validation error references source' "$TMPROOT/s6-bad-rec.json" \
  'j["errors"].any? { |e| e["source"].include?("role_execution_context") }'

# ---- Group 7b: validate rejects role_execution_context that is not a mapping ----
S6_NONMAP_EV="$TMPROOT/s6-nonmap-rec-evidence.json"
"$CLI" evidence init --output "$S6_NONMAP_EV" >/dev/null
ruby --disable-gems -rjson -e \
  'p=ARGV[0]
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{
     "kind"=>"command","status"=>"pass","summary"=>"bad rec ctx type.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "role_execution_context"=>"not-a-map"}
   File.write(p, JSON.pretty_generate(j))' \
  "$S6_NONMAP_EV"
if "$CLI" validate --task "$S5_AUDIT_TASK" --evidence "$S6_NONMAP_EV" --json \
     >"$TMPROOT/s6-nonmap-rec.json" 2>/dev/null; then
  printf 'FAIL validate rejects non-mapping role_execution_context: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects non-mapping role_execution_context'
json_assert 'non-mapping role_execution_context error message mentions must be a mapping' "$TMPROOT/s6-nonmap-rec.json" \
  'j["errors"].any? { |e| e["message"].include?("must be a mapping") }'

# ---- Group 8: wait-gate blocks malformed role_execution_context (no identity fallback) ----
# Build evidence: structured review with valid identity + malformed role_execution_context (string).
# wait-gate strict should block with malformed_role_execution_context, not fall through to identity.
S6_MALFORMED_EV="$TMPROOT/s6-malformed-ctx-evidence.json"
"$CLI" evidence init --output "$S6_MALFORMED_EV" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{
     "kind"=>"review","status"=>"pass",
     "summary"=>"malformed role_execution_context with valid identity.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "identity"=>{"resolved_role"=>"reviewer","task_sha256"=>sha},
     "role_execution_context"=>"not-a-map",
     "quality_outcome_verdict"=>"pass",
     "evidence_level"=>"outcome_quality",
     "quality_question_answers"=>[
       {"id"=>"outcome","verdict"=>"pass"},
       {"id"=>"counterexamples","verdict"=>"pass"},
       {"id"=>"evidence_sufficiency","verdict"=>"pass"},
       {"id"=>"residual_risk","verdict"=>"pass"}
     ]}
   File.write(p, JSON.pretty_generate(j))' \
  "$S6_MALFORMED_EV" "$S5_STRICT_REVIEW_TASK"
if "$CLI" wait-gate --task "$S5_STRICT_REVIEW_TASK" --evidence "$S6_MALFORMED_EV" --json \
     >"$TMPROOT/s6-malformed-gate.json" 2>/dev/null; then
  printf 'FAIL wait-gate strict blocks malformed role_execution_context: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate strict blocks malformed role_execution_context'
json_assert 'wait-gate malformed blocking_reason is malformed_role_execution_context' "$TMPROOT/s6-malformed-gate.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "malformed_role_execution_context" }'
json_assert 'wait-gate malformed sets malformed_role_execution_context flag' "$TMPROOT/s6-malformed-gate.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && g["malformed_role_execution_context"] == true }'

# ---- Group 9: wait-gate blocks partial role_execution_context (no identity fallback) ----
# role_execution_context is a Hash but missing resolved_role/task_sha256/rules_context_sha256.
# identity is fully populated. strict wait-gate must NOT fall back and must block.
S6_PARTIAL_EV="$TMPROOT/s6-partial-ctx-evidence.json"
"$CLI" evidence init --output "$S6_PARTIAL_EV" >/dev/null
ruby --disable-gems -rjson -rdigest -e \
  'p=ARGV[0]; t=ARGV[1]; sha=Digest::SHA256.file(t).hexdigest
   j=JSON.parse(File.read(p))
   j["records"]||=[]
   j["records"]<<{
     "kind"=>"review","status"=>"pass",
     "summary"=>"partial role_execution_context with complete identity.",
     "created_at"=>Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "structured_submit"=>true,
     "identity"=>{
       "resolved_role"=>"reviewer","task_sha256"=>sha,
       "rules_context_sha256"=>"c"*64},
     "role_execution_context"=>{"role_config_sha256"=>"a"*64},
     "quality_outcome_verdict"=>"pass",
     "evidence_level"=>"outcome_quality",
     "quality_question_answers"=>[
       {"id"=>"outcome","verdict"=>"pass"},
       {"id"=>"counterexamples","verdict"=>"pass"},
       {"id"=>"evidence_sufficiency","verdict"=>"pass"},
       {"id"=>"residual_risk","verdict"=>"pass"}
     ]}
   File.write(p, JSON.pretty_generate(j))' \
  "$S6_PARTIAL_EV" "$S5_STRICT_REVIEW_TASK"
if "$CLI" wait-gate --task "$S5_STRICT_REVIEW_TASK" --evidence "$S6_PARTIAL_EV" --json \
     >"$TMPROOT/s6-partial-gate.json" 2>/dev/null; then
  printf 'FAIL wait-gate strict blocks partial role_execution_context no fallback: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate strict blocks partial role_execution_context no fallback'
json_assert 'wait-gate partial ctx blocking_reason is identity_mismatch not passing' "$TMPROOT/s6-partial-gate.json" \
  'j["gates"].any? { |g| g["kind"] == "review" && ["identity_mismatch","missing_task_sha256","stale_task_sha256","missing_rules_context_sha256"].include?(g["blocking_reason"]) }'

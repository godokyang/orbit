# ---------------------------------------------------------------------------
# Slice 15: Orbit dogfood and governance acceptance tests
# ---------------------------------------------------------------------------

S15_TASK="$TMPROOT/s15-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S15_TASK" >/dev/null

# ---- Group 1: dogfood index covers all P0/P1 adjustments ----
S15_INDEX="$SCRIPT_DIR/fixtures/dogfood-index.json"
json_assert 'dogfood index covers all P0/P1 adjustments' "$S15_INDEX" \
  'j["dogfood_cases"].is_a?(Array) && j["dogfood_cases"].length >= 11 && j["dogfood_cases"].all? { |c| c["source_adjustment"].is_a?(String) && !c["source_adjustment"].empty? && c["expected_outcome"].is_a?(String) && !c["expected_outcome"].empty? }'
json_assert 'dogfood index has governance block' "$S15_INDEX" \
  'j["governance"].is_a?(Hash) && j["governance"]["failure_review_required"] == true && j["governance"]["exit_criteria"].is_a?(Array) && !j["governance"]["exit_criteria"].empty?'
pass 'dogfood index covers all P0/P1 adjustments with source_adjustment and expected_outcome'
ruby --disable-gems -rjson -e '
root = ARGV[1]
index = JSON.parse(File.read(ARGV[0]))
missing = index["dogfood_cases"].select { |c| !File.file?(File.join(root, c["fixture"].to_s)) }.map { |c| c["fixture"] }
abort("missing dogfood fixtures: #{missing.join(", ")}") unless missing.empty?
puts "OK"' "$S15_INDEX" "$SKILL_ROOT"
pass 'dogfood index fixture references resolve to real files'

# ---- Group 2: failed dogfood case maps to source_adjustment and expected behavior ----

ruby --disable-gems "-I$SCRIPT_DIR/../lib" -rjson -e '
require "orbit/dogfood_governance"
# Use the actual helper to load and map a dogfood failure.
index = load_dogfood_index(ARGV[0])
mapping = map_dogfood_failure(index, "stale-gate-detection")
abort("mapping nil") unless mapping
abort("no source_adjustment") unless mapping["source_adjustment"] == "P1.3"
abort("no expected_outcome") unless mapping["expected_outcome"].include?("stale_verdict")
puts "OK"' "$S15_INDEX"
pass 'failed dogfood case maps to source_adjustment and expected behavior via helper'


# ---- Group 3: stale gate fixture represents before-fix failure and current behavior blocks ----

S15_STALE_EVIDENCE="$TMPROOT/s15-stale-evidence.json"
"$CLI" evidence init --output "$S15_STALE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s15-stale-review.yaml" "Review pass linked to original task." "herdr:reviewer:s15-stale"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S15_STALE_EVIDENCE" \
  --report "$TMPROOT/s15-stale-review.yaml" \
  --task "$S15_TASK" \
  --json >/dev/null
# Mutate to old task sha.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="review" }; ctx=r["role_execution_context"]||{}; ctx["task_sha256"]="0"*64; r["role_execution_context"]=ctx; File.write(p, JSON.pretty_generate(j))' "$S15_STALE_EVIDENCE"
if "$CLI" wait-gate --task "$S15_TASK" --evidence "$S15_STALE_EVIDENCE" --json >"$TMPROOT/s15-stale-wait-gate.json" 2>/dev/null; then
  printf 'FAIL stale gate fixture should block: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'stale gate fixture blocks gate with old task sha'

# ---- Group 4: transport DONE fixture cannot satisfy gate ----

S15_TRANSPORT_EVIDENCE="$TMPROOT/s15-transport-evidence.json"
"$CLI" evidence init --output "$S15_TRANSPORT_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add \
  --file "$S15_TRANSPORT_EVIDENCE" \
  --kind command --status pass --summary "DONE: transport notification only" >/dev/null
if "$CLI" wait-gate --task "$S15_TASK" --evidence "$S15_TRANSPORT_EVIDENCE" --json >"$TMPROOT/s15-transport-wait-gate.json" 2>/dev/null; then
  printf 'FAIL transport DONE should not satisfy gate\n' >&2
  exit 1
fi
pass 'transport DONE cannot satisfy gate'

# ---- Group 5: destructive dry-run fixture blocks unsafe deletion ----

S15_DESTRUCTIVE_EVIDENCE="$TMPROOT/s15-destructive-evidence.json"
"$CLI" evidence init --output "$S15_DESTRUCTIVE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []
j["records"] << {"kind"=>"command","status"=>"pass","summary":"unsafe deletion plan","created_at"=>"2026-06-29T10:00:00Z",
  "destructive_action_plan"=>{"action"=>"delete","targets"=>[{"path"=>"important.log","tracked"=>false,"owner"=>"agent","recoverability"=>"none","evidence_impact":"evidence_loss"}],"dry_run"=>false,"user_confirmation"=>{"required"=>true,"received"=>false}}}
File.write(p, JSON.pretty_generate(j))' "$S15_DESTRUCTIVE_EVIDENCE"
expect_failure 'validate rejects unsafe destructive plan without dry_run' "$CLI" validate --task "$S15_TASK" --evidence "$S15_DESTRUCTIVE_EVIDENCE" --json
pass 'destructive dry-run fixture blocks unsafe deletion'

# ---- Group 6: protocol-changing release without dogfood status is blocked ----

S15_RELEASE_TASK="$TMPROOT/s15-release-task.yaml"
"$CLI" new-task --target-role lead --task-type release_implementation --output "$S15_RELEASE_TASK" >/dev/null
# Set protocol_changed=true and fill all release_readiness fields except dogfood_suite.
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["protocol_changed"]=true
  y["compatibility_policy"]={"mode"=>"warn_legacy","applies_to"=>["task","evidence"],"breaking_change"=>false,"migration_path"=>""}
  y["self_review_guard"]={"protocol_changed"=>true,"independent_check"=>"reviewer-report:s15-protocol-release","independent_check_required"=>true,"same_system_self_approval_allowed"=>false}
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"1","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"a"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"up_to_date"}
  y["release_readiness"]["generated_artifacts"]=[{"path"=>"dist/app.js","checked"=>true}]
  File.write(p, YAML.dump(y))' "$S15_RELEASE_TASK"
"$CLI" validate --task "$S15_RELEASE_TASK" --json >"$TMPROOT/s15-no-dogfood-validate.json" 2>/dev/null || true
json_assert 'validate blocks protocol-changing release without dogfood' "$TMPROOT/s15-no-dogfood-validate.json" \
  'j["errors"].any? { |e| e["source"].include?("dogfood_suite") }'
pass 'protocol-changing release without dogfood status is blocked'

S15_GUARD_PROTOCOL_TASK="$TMPROOT/s15-guard-protocol-task.yaml"
cp "$S15_RELEASE_TASK" "$S15_GUARD_PROTOCOL_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y.delete("protocol_changed")
  y["compatibility_policy"]={"mode"=>"warn_legacy","applies_to"=>["task","evidence"],"breaking_change"=>false,"migration_path"=>""}
  y["self_review_guard"]={"protocol_changed"=>true,"independent_check"=>"reviewer-report:s15-protocol-release","independent_check_required"=>true,"same_system_self_approval_allowed"=>false}
  File.write(p, YAML.dump(y))' "$S15_GUARD_PROTOCOL_TASK"
"$CLI" validate --task "$S15_GUARD_PROTOCOL_TASK" --json >"$TMPROOT/s15-guard-protocol-validate.json" 2>/dev/null || true
json_assert 'validate blocks self_review_guard protocol change without dogfood' "$TMPROOT/s15-guard-protocol-validate.json" \
  'j["errors"].any? { |e| e["source"].include?("dogfood_suite") }'
pass 'self_review_guard protocol-changing release without dogfood status is blocked'

# ---- Group 7: protocol-changing release with dogfood waiver is allowed ----

S15_WAIVER_TASK="$TMPROOT/s15-waiver-task.yaml"
cp "$S15_RELEASE_TASK" "$S15_WAIVER_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["dogfood_suite"]={"status"=>"failed","case_ids"=>["stale-gate-detection"],"waiver"=>"known failure in test environment, tracked in INC-001"}
  File.write(p, YAML.dump(y))' "$S15_WAIVER_TASK"
"$CLI" validate --task "$S15_WAIVER_TASK" --json >"$TMPROOT/s15-waiver-validate.json" 2>/dev/null || true
json_assert 'validate allows protocol-changing release with dogfood waiver' "$TMPROOT/s15-waiver-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("dogfood_suite") }'
pass 'protocol-changing release with explicit dogfood waiver is allowed'

# audit shows the waiver/gap.
S15_EMPTY_EVIDENCE="$TMPROOT/s15-empty-evidence.json"
"$CLI" evidence init --output "$S15_EMPTY_EVIDENCE" >/dev/null
S15_AUDIT_STATE="$TMPROOT/s15-audit-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "done", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S15_WAIVER_TASK" "$S15_EMPTY_EVIDENCE" "$S15_AUDIT_STATE"
"$CLI" audit --task "$S15_WAIVER_TASK" --evidence "$S15_EMPTY_EVIDENCE" --state "$S15_AUDIT_STATE" --json >"$TMPROOT/s15-waiver-audit.json" 2>/dev/null || true
json_assert 'audit shows dogfood waiver as visible gap' "$TMPROOT/s15-waiver-audit.json" \
  'j.key?("release_blockers") && j["release_blockers"].none? { |b| b["source"].include?("dogfood_suite") }'
json_assert 'audit dogfood_governance_summary shows suite status and waiver' "$TMPROOT/s15-waiver-audit.json" \
  'dgs = j["dogfood_governance_summary"]; dgs.is_a?(Hash) && dgs["dogfood_suite"]["status"] == "failed" && dgs["dogfood_suite"]["waiver"].include?("INC-001") && dgs["has_waiver"] == true'

# ---- Group 8: non-protocol release does not require dogfood ----

S15_NON_PROTO_TASK="$TMPROOT/s15-non-proto-task.yaml"
"$CLI" new-task --target-role lead --task-type release_implementation --output "$S15_NON_PROTO_TASK" >/dev/null
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"2","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"b"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"up_to_date"}
  y["release_readiness"]["generated_artifacts"]=[{"path"=>"dist/app.js","checked"=>true}]
  File.write(p, YAML.dump(y))' "$S15_NON_PROTO_TASK"
"$CLI" validate --task "$S15_NON_PROTO_TASK" --json >"$TMPROOT/s15-non-proto-validate.json" 2>/dev/null || true
json_assert 'non-protocol release does not require dogfood_suite' "$TMPROOT/s15-non-proto-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("dogfood_suite") }'
pass 'non-protocol-changing release does not require dogfood'

# ---- Group 9: retrospective task without done criteria fails ----

S15_RETRO_TASK="$TMPROOT/s15-retro-task.yaml"
"$CLI" new-task --target-role lead --task-type retrospective --output "$S15_RETRO_TASK" >/dev/null
# Clear acceptance to simulate missing done criteria.
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["acceptance"]=[]; File.write(p, YAML.dump(y))' "$S15_RETRO_TASK"
expect_failure 'validate rejects retrospective without done criteria' "$CLI" validate --task "$S15_RETRO_TASK" --json
pass 'retrospective task without done criteria fails validation'

# ---- Group 10: postmortem task with done criteria passes ----

S15_POSTMORTEM_TASK="$TMPROOT/s15-postmortem-task.yaml"
"$CLI" new-task --target-role lead --task-type postmortem --output "$S15_POSTMORTEM_TASK" >/dev/null
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["acceptance"]=["Root cause identified","Action items assigned","Follow-up verification planned"]; File.write(p, YAML.dump(y))' "$S15_POSTMORTEM_TASK"
"$CLI" validate --task "$S15_POSTMORTEM_TASK" --json >"$TMPROOT/s15-postmortem-validate.json" 2>/dev/null || true
json_assert 'validate accepts postmortem with done criteria' "$TMPROOT/s15-postmortem-validate.json" \
  'j["errors"].none? { |e| e["source"] == "task_file.acceptance" }'
pass 'postmortem task with done criteria passes validation'

# ---- Group 11: schema_semantics includes orbit_dogfood_governance v1 ----

S15_IMPL_TASK="$TMPROOT/s15-impl-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S15_IMPL_TASK" >/dev/null
yaml_assert 'new-task includes orbit_dogfood_governance feature version' "$S15_IMPL_TASK" \
  'j.dig("schema_semantics","feature_versions","orbit_dogfood_governance") == "v1"'


# ---- Group 12: handoff includes dogfood_governance_summary ----

S15_HANDOFF_STATE="$TMPROOT/s15-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S15_WAIVER_TASK" "$S15_EMPTY_EVIDENCE" "$S15_HANDOFF_STATE"
"$CLI" handoff --task "$S15_WAIVER_TASK" --evidence "$S15_EMPTY_EVIDENCE" --state "$S15_HANDOFF_STATE" --json >"$TMPROOT/s15-handoff.json" 2>/dev/null || true
json_assert 'handoff includes dogfood_governance_summary' "$TMPROOT/s15-handoff.json" \
  'dgs = j["dogfood_governance_summary"]; dgs.is_a?(Hash) && dgs["dogfood_suite"]["status"] == "failed" && dgs["has_waiver"] == true'

# ---- Group 13: invalid dogfood status blocked even with waiver ----

S15_BAD_STATUS_TASK="$TMPROOT/s15-bad-status-task.yaml"
cp "$S15_RELEASE_TASK" "$S15_BAD_STATUS_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["dogfood_suite"]={"status"=>"totally_invalid","case_ids"=>[],"waiver"=>"should not help"}
  File.write(p, YAML.dump(y))' "$S15_BAD_STATUS_TASK"
"$CLI" validate --task "$S15_BAD_STATUS_TASK" --json >"$TMPROOT/s15-bad-status-validate.json" 2>/dev/null || true
json_assert 'validate blocks invalid dogfood status even with waiver' "$TMPROOT/s15-bad-status-validate.json" \
  'j["errors"].any? { |e| e["source"].include?("dogfood_suite.status") && e["message"].include?("totally_invalid") }'
pass 'invalid dogfood suite status blocked even with waiver'

# ---- Group 14: dogfood_coverage_complete? via helper ----

ruby --disable-gems "-I$SKILL_ROOT/lib" -rjson -e '
require "orbit/dogfood_governance"
index = load_dogfood_index(ARGV[0])
abort("coverage not complete") unless dogfood_coverage_complete?(index)
puts "OK"' "$S15_INDEX"
pass 'dogfood_coverage_complete? confirms all P0/P1 adjustments covered'

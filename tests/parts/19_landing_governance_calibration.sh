# ---------------------------------------------------------------------------
# Slice 16: Landing governance and calibration acceptance tests
# ---------------------------------------------------------------------------

S16_TASK="$TMPROOT/s16-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S16_TASK" >/dev/null
S16_STATE="$TMPROOT/s16-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S16_TASK" "$TMPROOT/dummy.json" "$S16_STATE"
S16_EMPTY_EVIDENCE="$TMPROOT/s16-empty-evidence.json"
"$CLI" evidence init --output "$S16_EMPTY_EVIDENCE" >/dev/null

# ---- Group 1: schema_semantics includes landing_governance_calibration v1 ----

S16_IMPL_TASK="$TMPROOT/s16-impl-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S16_IMPL_TASK" >/dev/null
yaml_assert 'new-task includes landing_governance_calibration feature version' "$S16_IMPL_TASK" \
  'j.dig("schema_semantics","feature_versions","landing_governance_calibration") == "v1"'
pass 'new-task includes landing_governance_calibration feature version'

# ---- Group 2: warn_legacy policy reports warning in audit, not hard failure ----

S16_WARN_LEGACY_TASK="$TMPROOT/s16-warn-legacy-task.yaml"
cp "$S16_TASK" "$S16_WARN_LEGACY_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["compatibility_policy"]={"mode"=>"warn_legacy","applies_to"=>["evidence"],"breaking_change"=>false,"migration_path"=>""}; File.write(p, YAML.dump(y))' "$S16_WARN_LEGACY_TASK"
"$CLI" validate --task "$S16_WARN_LEGACY_TASK" --json >"$TMPROOT/s16-warn-validate.json" 2>/dev/null || true
json_assert 'validate passes with warn_legacy policy (no error)' "$TMPROOT/s16-warn-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("compatibility_policy") }'
"$CLI" audit --task "$S16_WARN_LEGACY_TASK" --evidence "$S16_EMPTY_EVIDENCE" --state "$S16_STATE" --json >"$TMPROOT/s16-warn-audit.json" 2>/dev/null || true
json_assert 'audit warns on warn_legacy compatibility policy' "$TMPROOT/s16-warn-audit.json" \
  'j["warnings"].any? { |w| w["source"].include?("compatibility_policy") }'
json_assert 'audit includes compatibility_policy_summary' "$TMPROOT/s16-warn-audit.json" \
  'j.key?("compatibility_policy_summary") && j["compatibility_policy_summary"]["mode"] == "warn_legacy" && j["compatibility_policy_summary"]["has_legacy_gap"] == true'
pass 'warn_legacy policy reports warning not hard failure'

# ---- Group 3: protocol change self-review blocked under strict risk ----

S16_STRICT_PROTO_TASK="$TMPROOT/s16-strict-proto-task.yaml"
"$CLI" new-task --target-role lead --task-type security_migration --output "$S16_STRICT_PROTO_TASK" >/dev/null
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["compatibility_policy"]={"mode"=>"warn_legacy","applies_to"=>["task","evidence"],"breaking_change"=>false,"migration_path"=>""}; y["self_review_guard"]={"protocol_changed"=>true,"independent_check_required"=>true,"same_system_self_approval_allowed"=>false}; File.write(p, YAML.dump(y))' "$S16_STRICT_PROTO_TASK"
expect_failure 'validate blocks strict protocol change without independent check' "$CLI" validate --task "$S16_STRICT_PROTO_TASK" --json
pass 'protocol change under strict risk with only self-review is blocked'

# Same with explicit waiver passes.
S16_STRICT_PROTO_WAIVER_TASK="$TMPROOT/s16-strict-proto-waiver-task.yaml"
cp "$S16_STRICT_PROTO_TASK" "$S16_STRICT_PROTO_WAIVER_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["self_review_guard"]["waiver"]="User approved hotfix without independent reviewer"; File.write(p, YAML.dump(y))' "$S16_STRICT_PROTO_WAIVER_TASK"
"$CLI" validate --task "$S16_STRICT_PROTO_WAIVER_TASK" --json >"$TMPROOT/s16-waiver-validate.json" 2>/dev/null || true
json_assert 'validate passes protocol change with explicit waiver' "$TMPROOT/s16-waiver-validate.json" \
  'j["errors"].none? { |e| e["source"] == "task_file.self_review_guard" }'
pass 'protocol change with explicit waiver is allowed'

# Disabling the requirement is not enough; explicit waiver or independent check is required.
S16_STRICT_PROTO_INDEP_TASK="$TMPROOT/s16-strict-proto-indep-task.yaml"
cp "$S16_STRICT_PROTO_TASK" "$S16_STRICT_PROTO_INDEP_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["self_review_guard"]["independent_check_required"]=false; File.write(p, YAML.dump(y))' "$S16_STRICT_PROTO_INDEP_TASK"
expect_failure 'validate blocks protocol change when independent_check_required is disabled without waiver' "$CLI" validate --task "$S16_STRICT_PROTO_INDEP_TASK" --json
pass 'protocol change cannot bypass independent check by disabling requirement'

S16_STRICT_PROTO_CHECK_TASK="$TMPROOT/s16-strict-proto-check-task.yaml"
cp "$S16_STRICT_PROTO_TASK" "$S16_STRICT_PROTO_CHECK_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["self_review_guard"]["independent_check"]="reviewer-report:s16-independent-protocol-check"; File.write(p, YAML.dump(y))' "$S16_STRICT_PROTO_CHECK_TASK"
"$CLI" validate --task "$S16_STRICT_PROTO_CHECK_TASK" --json >"$TMPROOT/s16-indep-validate.json" 2>/dev/null || true
json_assert 'validate passes protocol change with independent_check evidence' "$TMPROOT/s16-indep-validate.json" \
  'j["errors"].none? { |e| e["source"] == "task_file.self_review_guard" }'
pass 'protocol change with independent_check evidence is allowed'

S16_STRICT_PROTO_NO_COMPAT_TASK="$TMPROOT/s16-strict-proto-no-compat-task.yaml"
cp "$S16_STRICT_PROTO_CHECK_TASK" "$S16_STRICT_PROTO_NO_COMPAT_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("compatibility_policy"); File.write(p, YAML.dump(y))' "$S16_STRICT_PROTO_NO_COMPAT_TASK"
expect_failure 'validate blocks protocol change without compatibility_policy' "$CLI" validate --task "$S16_STRICT_PROTO_NO_COMPAT_TASK" --json
pass 'protocol change requires compatibility_policy'

S16_TOP_LEVEL_PROTO_TASK="$TMPROOT/s16-top-level-proto-task.yaml"
"$CLI" new-task --target-role lead --task-type release_implementation --output "$S16_TOP_LEVEL_PROTO_TASK" >/dev/null
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["protocol_changed"]=true; File.write(p, YAML.dump(y))' "$S16_TOP_LEVEL_PROTO_TASK"
expect_failure 'validate blocks top-level protocol change without governance fields' "$CLI" validate --task "$S16_TOP_LEVEL_PROTO_TASK" --json
pass 'top-level protocol_changed requires compatibility and self-review governance'

S16_TOP_LEVEL_PROTO_OK_TASK="$TMPROOT/s16-top-level-proto-ok-task.yaml"
cp "$S16_TOP_LEVEL_PROTO_TASK" "$S16_TOP_LEVEL_PROTO_OK_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["compatibility_policy"]={"mode"=>"warn_legacy","applies_to"=>["task","evidence"],"breaking_change"=>false,"migration_path"=>""}; y["self_review_guard"]={"protocol_changed"=>true,"independent_check"=>"reviewer-report:s16-top-level-protocol","independent_check_required"=>true,"same_system_self_approval_allowed"=>false}; y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"3","status"=>"passed"}; y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"c"*64,"contents_checked"=>true}; y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"up_to_date"}; y["release_readiness"]["generated_artifacts"]=[{"path"=>"dist/app.js","checked"=>true}]; y["release_readiness"]["dogfood_suite"]={"status"=>"passed","case_ids"=>["stale-gate-detection"]}; File.write(p, YAML.dump(y))' "$S16_TOP_LEVEL_PROTO_OK_TASK"
"$CLI" validate --task "$S16_TOP_LEVEL_PROTO_OK_TASK" --json >"$TMPROOT/s16-top-level-ok-validate.json" 2>/dev/null || true
json_assert 'validate accepts top-level protocol change with governance fields' "$TMPROOT/s16-top-level-ok-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("compatibility_policy") || e["source"].include?("self_review_guard") }'
pass 'top-level protocol_changed uses the same governance guard as self_review_guard protocol_changed'

# ---- Group 4: backup export without restore_check fails validate ----

S16_BACKUP_TASK="$TMPROOT/s16-backup-task.yaml"
cp "$S16_TASK" "$S16_BACKUP_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["backup_migration"]={"export_format"=>"json","restore_check"=>"","evidence_index"=>"index.json"}; File.write(p, YAML.dump(y))' "$S16_BACKUP_TASK"
expect_failure 'validate rejects backup without restore_check' "$CLI" validate --task "$S16_BACKUP_TASK" --json
pass 'backup export without restore_check fails validate'

# With restore_check passes.
S16_BACKUP_OK_TASK="$TMPROOT/s16-backup-ok-task.yaml"
cp "$S16_BACKUP_TASK" "$S16_BACKUP_OK_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["backup_migration"]["restore_check"]="verified with test restore"; File.write(p, YAML.dump(y))' "$S16_BACKUP_OK_TASK"
"$CLI" validate --task "$S16_BACKUP_OK_TASK" --json >"$TMPROOT/s16-backup-ok-validate.json" 2>/dev/null || true
json_assert 'validate passes backup with restore_check' "$TMPROOT/s16-backup-ok-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("restore_check") }'
pass 'backup with restore_check passes validate'

# ---- Group 5: breaking_change without migration_path fails ----

S16_BREAKING_TASK="$TMPROOT/s16-breaking-task.yaml"
cp "$S16_TASK" "$S16_BREAKING_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["compatibility_policy"]={"mode"=>"enforce_current","breaking_change"=>true,"migration_path"=>""}; File.write(p, YAML.dump(y))' "$S16_BREAKING_TASK"
expect_failure 'validate rejects breaking change without migration_path' "$CLI" validate --task "$S16_BREAKING_TASK" --json
pass 'breaking change without migration_path fails validate'

# ---- Group 6: handoff includes multi_user_ownership summary ----

S16_MULTI_USER_TASK="$TMPROOT/s16-multi-user-task.yaml"
cp "$S16_TASK" "$S16_MULTI_USER_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["multi_user_ownership"]={"file_owner"=>"lead","artifact_owner"=>"tester","pane_owner"=>"reviewer","evidence_access"=>"shared"}; File.write(p, YAML.dump(y))' "$S16_MULTI_USER_TASK"
S16_HANDOFF_STATE="$TMPROOT/s16-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S16_MULTI_USER_TASK" "$S16_EMPTY_EVIDENCE" "$S16_HANDOFF_STATE"
"$CLI" handoff --task "$S16_MULTI_USER_TASK" --evidence "$S16_EMPTY_EVIDENCE" --state "$S16_HANDOFF_STATE" --json >"$TMPROOT/s16-handoff.json" 2>/dev/null || true
json_assert 'handoff includes multi_user_ownership_summary' "$TMPROOT/s16-handoff.json" \
  'muo = j["multi_user_ownership_summary"]; muo.is_a?(Hash) && muo["file_owner"] == "lead" && muo["ownership_assumptions"].is_a?(String)'
pass 'handoff includes multi_user_ownership and ownership assumptions'

# Malformed ownership is rejected so owners are identifiable.
S16_BAD_MULTI_USER_TASK="$TMPROOT/s16-bad-multi-user-task.yaml"
cp "$S16_TASK" "$S16_BAD_MULTI_USER_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["multi_user_ownership"]={"file_owner"=>"","artifact_owner"=>"tester","pane_owner"=>"reviewer","evidence_access"=>"shared"}; File.write(p, YAML.dump(y))' "$S16_BAD_MULTI_USER_TASK"
expect_failure 'validate rejects multi_user_ownership with empty owner' "$CLI" validate --task "$S16_BAD_MULTI_USER_TASK" --json
pass 'multi_user_ownership requires identifiable owners'

# ---- Group 7: audit includes self_review_guard_summary ----

S16_GUARD_AUDIT_TASK="$TMPROOT/s16-guard-audit-task.yaml"
cp "$S16_IMPL_TASK" "$S16_GUARD_AUDIT_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["self_review_guard"]={"protocol_changed"=>true,"independent_check_required"=>true,"same_system_self_approval_allowed"=>false,"waiver"=>"approved by lead"}; File.write(p, YAML.dump(y))' "$S16_GUARD_AUDIT_TASK"
"$CLI" audit --task "$S16_GUARD_AUDIT_TASK" --evidence "$S16_EMPTY_EVIDENCE" --state "$S16_STATE" --json >"$TMPROOT/s16-guard-audit.json" 2>/dev/null || true
json_assert 'audit includes self_review_guard_summary' "$TMPROOT/s16-guard-audit.json" \
  'srg = j["self_review_guard_summary"]; srg.is_a?(Hash) && srg["protocol_changed"] == true && srg["waiver"] == "approved by lead"'

# ---- Group 8: quality calibration and risk tradeoff summaries ----

S16_CALIBRATION_TASK="$TMPROOT/s16-calibration-task.yaml"
cp "$S16_IMPL_TASK" "$S16_CALIBRATION_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["quality_calibration"]={"sample_rate"=>"weekly 5% audit sample","metrics"=>{"false_pass"=>1,"false_block"=>2,"user_corrections"=>3,"median_gate_wait"=>"4m"}}
  File.write(p, YAML.dump(y))' "$S16_CALIBRATION_TASK"
"$CLI" validate --task "$S16_CALIBRATION_TASK" --json >"$TMPROOT/s16-calibration-validate.json" 2>/dev/null || true
json_assert 'validate accepts quality_calibration metrics' "$TMPROOT/s16-calibration-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("quality_calibration") }'
"$CLI" audit --task "$S16_CALIBRATION_TASK" --evidence "$S16_EMPTY_EVIDENCE" --state "$S16_STATE" --json >"$TMPROOT/s16-calibration-audit.json" 2>/dev/null || true
json_assert 'audit includes quality_calibration_summary' "$TMPROOT/s16-calibration-audit.json" \
  'qc = j["quality_calibration_summary"]; qc.is_a?(Hash) && qc.dig("metrics","false_pass") == 1 && qc.dig("metrics","median_gate_wait") == "4m"'
json_assert 'audit includes risk_level_tradeoff_summary' "$TMPROOT/s16-calibration-audit.json" \
  'rt = j["risk_level_tradeoff_summary"]; rt.is_a?(Hash) && rt["level"] == "standard" && rt["speed"].is_a?(String) && rt["rigor"].is_a?(String) && rt["tradeoff"].include?("review/test")'

S16_BAD_CALIBRATION_TASK="$TMPROOT/s16-bad-calibration-task.yaml"
cp "$S16_CALIBRATION_TASK" "$S16_BAD_CALIBRATION_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["quality_calibration"]["metrics"]["false_pass"]=-1; File.write(p, YAML.dump(y))' "$S16_BAD_CALIBRATION_TASK"
expect_failure 'validate rejects malformed quality_calibration metrics' "$CLI" validate --task "$S16_BAD_CALIBRATION_TASK" --json
pass 'quality_calibration metrics are validated'

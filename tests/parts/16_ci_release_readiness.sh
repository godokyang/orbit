# ---------------------------------------------------------------------------
# Slice 13: CI release readiness acceptance tests
# ---------------------------------------------------------------------------

# ---- Group 1: new-task writes full release_readiness skeleton ----

S13_RELEASE_TASK="$TMPROOT/s13-release-task.yaml"
"$CLI" new-task --target-role lead --task-type release_implementation --output "$S13_RELEASE_TASK" >/dev/null
yaml_assert 'new-task release writes release_readiness.source' "$S13_RELEASE_TASK" \
  'j.dig("release_readiness","source").is_a?(Hash)'
yaml_assert 'new-task release writes release_readiness.ci' "$S13_RELEASE_TASK" \
  'j.dig("release_readiness","ci").is_a?(Hash) && j.dig("release_readiness","ci","status") == ""'
yaml_assert 'new-task release writes release_readiness.package' "$S13_RELEASE_TASK" \
  'j.dig("release_readiness","package").is_a?(Hash) && j.dig("release_readiness","package","artifact_sha256") == ""'
yaml_assert 'new-task release writes release_readiness.remote_state' "$S13_RELEASE_TASK" \
  'j.dig("release_readiness","remote_state").is_a?(Hash) && j.dig("release_readiness","remote_state","branch") == ""'
yaml_assert 'new-task release writes release_readiness.version_fields' "$S13_RELEASE_TASK" \
  'j.dig("release_readiness","version_fields").is_a?(Array)'
yaml_assert 'new-task release writes release_readiness.generated_artifacts' "$S13_RELEASE_TASK" \
  'j.dig("release_readiness","generated_artifacts").is_a?(Array)'
yaml_assert 'new-task release has ci_release_readiness feature version' "$S13_RELEASE_TASK" \
  'j.dig("schema_semantics","feature_versions","ci_release_readiness") == "v1"'
pass 'new-task writes full release_readiness skeleton'

# ---- Group 2: validate on empty skeleton reports blockers ----

"$CLI" validate --task "$S13_RELEASE_TASK" --json >"$TMPROOT/s13-empty-validate.json" 2>/dev/null || true
json_assert 'validate reports CI status missing' "$TMPROOT/s13-empty-validate.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.release_readiness.ci.status" }'
json_assert 'validate reports package hash missing' "$TMPROOT/s13-empty-validate.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.release_readiness.package.artifact_sha256" }'
json_assert 'validate reports contents_checked not true' "$TMPROOT/s13-empty-validate.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.release_readiness.package.contents_checked" }'
json_assert 'validate reports remote branch missing' "$TMPROOT/s13-empty-validate.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.release_readiness.remote_state.branch" }'

# ---- Group 3: audit on empty skeleton blocks release trust ----

S13_EMPTY_EVIDENCE="$TMPROOT/s13-empty-evidence.json"
"$CLI" evidence init --output "$S13_EMPTY_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add \
  --file "$S13_EMPTY_EVIDENCE" --kind command --status pass --summary "local pass only" >/dev/null
S13_AUDIT_STATE="$TMPROOT/s13-audit-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "done", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S13_RELEASE_TASK" "$S13_EMPTY_EVIDENCE" "$S13_AUDIT_STATE"
"$CLI" audit --task "$S13_RELEASE_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-empty-audit.json" 2>/dev/null || true
json_assert 'audit not trusted_for_release with empty release_readiness' "$TMPROOT/s13-empty-audit.json" \
  'j["trusted_for_release"] == false'
json_assert 'audit release_blockers list is non-empty' "$TMPROOT/s13-empty-audit.json" \
  'j["release_blockers"].is_a?(Array) && !j["release_blockers"].empty?'
json_assert 'audit includes release_readiness_summary' "$TMPROOT/s13-empty-audit.json" \
  'j.key?("release_readiness_summary") && j["release_readiness_summary"]["ready"] == false'
pass 'local pass but missing CI blocks release audit'

# ---- Group 4: audit blocks when package hash missing ----

S13_NO_HASH_TASK="$TMPROOT/s13-no-hash-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_NO_HASH_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"123","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"","contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"up_to_date"}
  File.write(p, YAML.dump(y))' "$S13_NO_HASH_TASK"
"$CLI" audit --task "$S13_NO_HASH_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-no-hash-audit.json" 2>/dev/null || true
json_assert 'audit blocks release when package hash missing' "$TMPROOT/s13-no-hash-audit.json" \
  'j["release_blockers"].any? { |b| b["source"].include?("artifact_sha256") }'
pass 'missing package hash blocks release readiness'

# ---- Group 5: audit reports remote branch mismatch ----

S13_DIVERGED_TASK="$TMPROOT/s13-diverged-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_DIVERGED_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"456","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"a"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"diverged"}
  File.write(p, YAML.dump(y))' "$S13_DIVERGED_TASK"
"$CLI" audit --task "$S13_DIVERGED_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-diverged-audit.json" 2>/dev/null || true
json_assert 'audit reports remote branch diverged' "$TMPROOT/s13-diverged-audit.json" \
  'j["release_blockers"].any? { |b| b["source"].include?("ahead_behind") && b["message"].include?("diverged") }'
pass 'remote branch mismatch reported'

# ---- Group 6: complete release_readiness passes release readiness checks ----

S13_COMPLETE_TASK="$TMPROOT/s13-complete-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_COMPLETE_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["source"]={"git_head"=>"abc1234","reviewed_diff_base"=>"def5678"}
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"789","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"f"*64,"contents_checked"=>true}
  y["release_readiness"]["version_fields"]=[{"name"=>"version","value"=>"1.0.0"}]
  y["release_readiness"]["generated_artifacts"]=[{"path"=>"dist/app.js","checked"=>true}]
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"up_to_date"}
  File.write(p, YAML.dump(y))' "$S13_COMPLETE_TASK"
"$CLI" audit --task "$S13_COMPLETE_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-complete-audit.json" 2>/dev/null || true
json_assert 'audit release_readiness_summary ready is true' "$TMPROOT/s13-complete-audit.json" \
  'j["release_readiness_summary"]["ready"] == true'
json_assert 'audit release_blockers is empty with complete readiness' "$TMPROOT/s13-complete-audit.json" \
  'j["release_blockers"].empty?'
pass 'complete release_readiness passes release readiness checks'

# ---- Group 7: handoff includes release_blockers and release_readiness_summary ----

S13_HANDOFF_STATE="$TMPROOT/s13-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S13_RELEASE_TASK" "$S13_EMPTY_EVIDENCE" "$S13_HANDOFF_STATE"
"$CLI" handoff --task "$S13_RELEASE_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_HANDOFF_STATE" --json >"$TMPROOT/s13-handoff.json" 2>/dev/null || true
json_assert 'handoff includes release_readiness_summary' "$TMPROOT/s13-handoff.json" \
  'j.key?("release_readiness_summary") && j["release_readiness_summary"]["ready"] == false'
json_assert 'handoff includes release_blockers list' "$TMPROOT/s13-handoff.json" \
  'j.key?("release_blockers") && j["release_blockers"].is_a?(Array) && !j["release_blockers"].empty?'
pass 'handoff separates release blockers from implementation blockers'

# ---- Group 8: validate on complete release_readiness passes (no release errors) ----

"$CLI" validate --task "$S13_COMPLETE_TASK" --json >"$TMPROOT/s13-complete-validate.json" 2>/dev/null || true
json_assert 'validate has no release_readiness errors on complete task' "$TMPROOT/s13-complete-validate.json" \
  'j["errors"].none? { |e| e["source"].include?("release_readiness") }'

# ---- Group 9: unchecked generated_artifacts blocks, waiver passes ----

S13_UNCHECKED_GEN_TASK="$TMPROOT/s13-unchecked-gen-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_UNCHECKED_GEN_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"1","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"e"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"up_to_date"}
  y["release_readiness"]["generated_artifacts"]=[{"path"=>"dist/app.js","checked"=>false}]
  File.write(p, YAML.dump(y))' "$S13_UNCHECKED_GEN_TASK"
"$CLI" audit --task "$S13_UNCHECKED_GEN_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-unchecked-gen-audit.json" 2>/dev/null || true
json_assert 'audit blocks when generated_artifacts unchecked' "$TMPROOT/s13-unchecked-gen-audit.json" \
  'j["release_blockers"].any? { |b| b["source"].include?("generated_artifacts") }'
pass 'unchecked generated artifact blocks release readiness'

# Same artifact with waiver passes.
S13_WAIVED_GEN_TASK="$TMPROOT/s13-waived-gen-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_WAIVED_GEN_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"2","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"e"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"up_to_date"}
  y["release_readiness"]["generated_artifacts"]=[{"path"=>"dist/app.js","checked"=>false,"waiver"=>"vendored file, no changes"}]
  File.write(p, YAML.dump(y))' "$S13_WAIVED_GEN_TASK"
"$CLI" audit --task "$S13_WAIVED_GEN_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-waived-gen-audit.json" 2>/dev/null || true
json_assert 'audit passes when generated_artifacts has waiver' "$TMPROOT/s13-waived-gen-audit.json" \
  'j["release_blockers"].none? { |b| b["source"].include?("generated_artifacts") }'
pass 'waived generated artifact does not block release readiness'

# ---- Group 10: ahead_behind empty/ahead/unknown blocks release readiness ----

# branch present but ahead_behind empty → blocker.
S13_EMPTY_AB_TASK="$TMPROOT/s13-empty-ab-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_EMPTY_AB_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"1","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"a"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>""}
  File.write(p, YAML.dump(y))' "$S13_EMPTY_AB_TASK"
"$CLI" audit --task "$S13_EMPTY_AB_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-empty-ab-audit.json" 2>/dev/null || true
json_assert 'audit blocks when ahead_behind is empty' "$TMPROOT/s13-empty-ab-audit.json" \
  'j["release_blockers"].any? { |b| b["source"].include?("ahead_behind") && b["message"].include?("missing") }'
pass 'empty ahead_behind blocks release readiness'

# ahead_behind = ahead → blocker.
S13_AHEAD_TASK="$TMPROOT/s13-ahead-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_AHEAD_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"2","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"a"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"ahead"}
  File.write(p, YAML.dump(y))' "$S13_AHEAD_TASK"
"$CLI" audit --task "$S13_AHEAD_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-ahead-audit.json" 2>/dev/null || true
json_assert 'audit blocks when ahead_behind is ahead' "$TMPROOT/s13-ahead-audit.json" \
  'j["release_blockers"].any? { |b| b["source"].include?("ahead_behind") && b["message"].include?("ahead") }'
pass 'ahead_behind=ahead blocks release readiness'

# ahead_behind = unknown → blocker.
S13_UNKNOWN_AB_TASK="$TMPROOT/s13-unknown-ab-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_UNKNOWN_AB_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]={"provider"=>"github","run_id"=>"3","status"=>"passed"}
  y["release_readiness"]["package"]={"artifact_path"=>"pkg.tgz","artifact_sha256"=>"a"*64,"contents_checked"=>true}
  y["release_readiness"]["remote_state"]={"branch"=>"main","ahead_behind"=>"unknown"}
  File.write(p, YAML.dump(y))' "$S13_UNKNOWN_AB_TASK"
"$CLI" audit --task "$S13_UNKNOWN_AB_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-unknown-ab-audit.json" 2>/dev/null || true
json_assert 'audit blocks when ahead_behind is unknown' "$TMPROOT/s13-unknown-ab-audit.json" \
  'j["release_blockers"].any? { |b| b["source"].include?("ahead_behind") && b["message"].include?("unknown") }'
pass 'ahead_behind=unknown blocks release readiness'

# ---- Group 11: malformed nested release_readiness does not crash ----

S13_MALFORMED_TASK="$TMPROOT/s13-malformed-task.yaml"
cp "$S13_RELEASE_TASK" "$S13_MALFORMED_TASK"
ruby --disable-gems -ryaml -e '
  p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
  y["release_readiness"]["ci"]="not-a-hash"
  y["release_readiness"]["package"]=42
  y["release_readiness"]["remote_state"]=nil
  File.write(p, YAML.dump(y))' "$S13_MALFORMED_TASK"
# validate reports structure errors.
"$CLI" validate --task "$S13_MALFORMED_TASK" --json >"$TMPROOT/s13-malformed-validate.json" 2>/dev/null || true
json_assert 'validate reports release_readiness.ci structure error' "$TMPROOT/s13-malformed-validate.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.release_readiness.ci" && e["message"].include?("mapping") }'
json_assert 'validate reports release_readiness.package structure error' "$TMPROOT/s13-malformed-validate.json" \
  'j["errors"].any? { |e| e["source"] == "task_file.release_readiness.package" && e["message"].include?("mapping") }'
# audit does not crash and reports blockers.
"$CLI" audit --task "$S13_MALFORMED_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_AUDIT_STATE" --json >"$TMPROOT/s13-malformed-audit.json" 2>/dev/null || true
json_assert 'audit reports release_readiness structure blockers for malformed' "$TMPROOT/s13-malformed-audit.json" \
  'j["release_blockers"].any? { |b| b["source"].include?("release_readiness.ci") }'
json_assert 'audit release_readiness_summary has_structure is false for malformed' "$TMPROOT/s13-malformed-audit.json" \
  'j["release_readiness_summary"]["has_structure"] == false'
pass 'malformed nested release_readiness does not crash and produces blockers'

# ---- Group 12: handoff does not crash with malformed release_readiness ----

"$CLI" handoff --task "$S13_MALFORMED_TASK" --evidence "$S13_EMPTY_EVIDENCE" --state "$S13_HANDOFF_STATE" --json >"$TMPROOT/s13-malformed-handoff.json" 2>/dev/null || true
json_assert 'handoff does not crash with malformed release_readiness' "$TMPROOT/s13-malformed-handoff.json" \
  'j.key?("release_readiness_summary")'

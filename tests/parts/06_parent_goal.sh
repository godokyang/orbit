# ---------------------------------------------------------------------------
# High regression: design_readiness gate required_questions coverage
# ---------------------------------------------------------------------------

# design_readiness gate must apply required_questions coverage (same as review gate)
DR_RQ_TASK="$TMPROOT/slice2-dr-rq-task.yaml"
"$CLI" new-task --target-role reviewer --task-type design_review --output "$DR_RQ_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"design_readiness","roles"=>["reviewer"],"required"=>true,"pass_condition"=>"design readiness passed"}]; File.write(p, YAML.dump(y))' \
  "$DR_RQ_TASK"
DR_RQ_EVIDENCE="$TMPROOT/slice2-dr-rq-evidence.json"
"$CLI" evidence init --output "$DR_RQ_EVIDENCE" >/dev/null
# Build a review pass report with correct evidence_level (implementation_readiness) but incomplete required questions
DR_PARTIAL_REPORT="$TMPROOT/slice2-dr-partial-report.yaml"
write_review_pass_report "$DR_PARTIAL_REPORT" "Design readiness partial answers." "herdr:reviewer:dr-partial"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["evidence_level"]="implementation_readiness"
   y["implementation_readiness_verdict"]="pass"
   y["quality_question_answers"]=[{"id"=>"outcome","verdict"=>"pass","evidence"=>"only outcome answered"}]
   File.write(p, YAML.dump(y))' \
  "$DR_PARTIAL_REPORT"
# evidence submit succeeds (submit does not have task context; task-aware check is in validate/wait-gate)
DR_PARTIAL_EVIDENCE="$TMPROOT/slice2-dr-partial-evidence.json"
"$CLI" evidence init --output "$DR_PARTIAL_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$DR_PARTIAL_EVIDENCE" --report "$DR_PARTIAL_REPORT" --json >/dev/null
# validate and wait-gate must reject partial required_questions coverage
expect_failure 'validate rejects design_readiness review pass with incomplete required questions' "$CLI" validate --task "$DR_RQ_TASK" --evidence "$DR_PARTIAL_EVIDENCE" --json
if "$CLI" wait-gate --task "$DR_RQ_TASK" --evidence "$DR_PARTIAL_EVIDENCE" --json >"$TMPROOT/slice2-dr-partial-wait.json" 2>/dev/null; then
  printf 'FAIL wait-gate blocks design_readiness gate with incomplete required questions: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate blocks design_readiness gate with incomplete required questions'
json_assert 'design_readiness wait-gate reports required_questions_not_met for incomplete coverage' "$TMPROOT/slice2-dr-partial-wait.json" \
  'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "design_readiness" && g["blocking_reason"] == "required_questions_not_met" }'

# Submit with full required questions, then verify wait-gate passes; then corrupt one answer and verify it blocks
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$DR_RQ_EVIDENCE" --report "$TMPROOT/design-readiness-review-pass.yaml" --json >/dev/null
"$CLI" wait-gate --task "$DR_RQ_TASK" --evidence "$DR_RQ_EVIDENCE" --json >"$TMPROOT/slice2-dr-rq-pass.json"
json_assert 'design_readiness gate passes with full required_questions coverage' "$TMPROOT/slice2-dr-rq-pass.json" \
  'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "design_readiness" && g["passed"] == true }'

DR_BLOCKED_EVIDENCE="$TMPROOT/slice2-dr-blocked-evidence.json"
cp "$DR_RQ_EVIDENCE" "$DR_BLOCKED_EVIDENCE"
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["quality_question_answers"].find { |a| a["id"]=="counterexamples" }["verdict"]="blocked"; File.write(p, JSON.pretty_generate(j))' \
  "$DR_BLOCKED_EVIDENCE"
if "$CLI" wait-gate --task "$DR_RQ_TASK" --evidence "$DR_BLOCKED_EVIDENCE" --json >"$TMPROOT/slice2-dr-blocked.json" 2>/dev/null; then
  printf 'FAIL wait-gate blocks design_readiness gate when counterexamples verdict is blocked: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate blocks design_readiness gate when required question verdict is blocked'
json_assert 'design_readiness gate reports required_questions_not_met' "$TMPROOT/slice2-dr-blocked.json" \
  'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "design_readiness" && g["blocking_reason"] == "required_questions_not_met" }'

# ---------------------------------------------------------------------------
# Phase 1 Slice 3 regression: reviewer findings fixed
# ---------------------------------------------------------------------------

# High fix 1a: validate rejects parent_done with unevidenced criteria
S3R_DONE_TASK="$TMPROOT/s3r-done-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3R_DONE_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["objective"]="A real decomposition objective."
   y["parent_goal"]["done_criteria"]=["All slices pass.","Evidence covers all criteria."]
   y["parent_goal_status"]["state"]="parent_done"
   y["parent_goal_status"]["done_criteria_status"]=[]
   File.write(p, YAML.dump(y))' \
  "$S3R_DONE_TASK"
S3R_EVIDENCE="$TMPROOT/s3r-evidence.json"
"$CLI" evidence init --output "$S3R_EVIDENCE" >/dev/null
expect_failure 'validate rejects parent_done with unevidenced done criteria' \
  "$CLI" validate --task "$S3R_DONE_TASK" --evidence "$S3R_EVIDENCE" --json

# High fix 1b: audit exit code is 1 when parent_done with unevidenced criteria
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S3R_DONE_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml
if "$CLI" audit --task "$S3R_DONE_TASK" --evidence "$S3R_EVIDENCE" \
    --state .orbit/loop-state.yaml --json >"$TMPROOT/s3r-done-audit.json" 2>/dev/null; then
  printf 'FAIL audit blocks (exit 1) when parent_done with unevidenced criteria: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'audit blocks (exit 1) when parent_done with unevidenced criteria'
json_assert 'audit blocking_findings includes parent_goal_status.done_criteria source' \
  "$TMPROOT/s3r-done-audit.json" \
  'j["blocking_findings"].any? { |b| b["source"] == "parent_goal_status.done_criteria" }'

# High fix 2: validate rejects missing parent_goal_status when parent_goal.required=true
S3R_NO_STATUS_TASK="$TMPROOT/s3r-no-status-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3R_NO_STATUS_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["objective"]="Objective is set."
   y.delete("parent_goal_status")
   File.write(p, YAML.dump(y))' \
  "$S3R_NO_STATUS_TASK"
expect_failure 'validate rejects parent_goal.required=true task with missing parent_goal_status' \
  "$CLI" validate --task "$S3R_NO_STATUS_TASK" --evidence "$S3R_EVIDENCE" --json

# Medium fix 3: state progress --parent-state rejects invalid state enum
"$CLI" init --force >/dev/null
S3R_PROGRESS_TASK="$TMPROOT/s3r-progress-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3R_PROGRESS_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["parent_goal"]["objective"]="Valid."; File.write(p, YAML.dump(y))' \
  "$S3R_PROGRESS_TASK"
ORBIT_INSTANCE=lead "$CLI" state start --task "$S3R_PROGRESS_TASK" >/dev/null
if ORBIT_INSTANCE=lead "$CLI" state progress --task "$S3R_PROGRESS_TASK" \
    --message "test" --parent-state bogus_invalid_state 2>/dev/null; then
  printf 'FAIL state progress rejects invalid --parent-state enum: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'state progress rejects invalid --parent-state enum'

# Verify loop state has NO side-effect when --parent-state validation fails
# (the progress record must NOT appear in loop-state history)
S3R_HIST_BEFORE=$(ruby --disable-gems -ryaml -e \
  'puts (YAML.safe_load(File.read(ARGV[0]), aliases: true)["history"] || []).length' \
  .orbit/loop-state.yaml)
ORBIT_INSTANCE=lead "$CLI" state progress --task "$S3R_PROGRESS_TASK" \
  --message "bad parent" --parent-state bogus_invalid_state 2>/dev/null || true
S3R_HIST_AFTER=$(ruby --disable-gems -ryaml -e \
  'puts (YAML.safe_load(File.read(ARGV[0]), aliases: true)["history"] || []).length' \
  .orbit/loop-state.yaml)
if [ "$S3R_HIST_BEFORE" -ne "$S3R_HIST_AFTER" ]; then
  printf 'FAIL loop state history unchanged after invalid --parent-state: grew %s -> %s\n' \
    "$S3R_HIST_BEFORE" "$S3R_HIST_AFTER" >&2
  exit 1
fi
pass 'loop state history unchanged after invalid --parent-state'

# Low/Medium fix 2: audit issues list includes parent_goal blocking source (not just blocking_findings)
json_assert 'audit issues includes parent_goal_status.done_criteria source' \
  "$TMPROOT/s3r-done-audit.json" \
  'j["issues"].any? { |b| b["source"] == "parent_goal_status.done_criteria" }'

# ---------------------------------------------------------------------------
# Phase 1 Slice 3: Parent Goal Status And User Next Action
# ---------------------------------------------------------------------------

# Test S3-1: new-task decomposition creates parent_goal with required=true and done_criteria
S3_DECOMP_TASK="$TMPROOT/slice3-decomp-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_DECOMP_TASK" >/dev/null
yaml_assert 'new-task decomposition seeds parent_goal with required=true' "$S3_DECOMP_TASK" \
  'j["parent_goal"].is_a?(Hash) && j["parent_goal"]["required"] == true && j["parent_goal"]["done_criteria"].is_a?(Array) && !j["parent_goal"]["done_criteria"].empty?'
yaml_assert 'new-task decomposition seeds parent_goal_status with parent_in_progress state' "$S3_DECOMP_TASK" \
  'j["parent_goal_status"].is_a?(Hash) && j["parent_goal_status"]["state"] == "parent_in_progress"'
yaml_assert 'new-task decomposition parent_goal_status has user_next_action default' "$S3_DECOMP_TASK" \
  'j["parent_goal_status"]["user_next_action"].is_a?(Hash) && !j["parent_goal_status"]["user_next_action"]["default"].to_s.strip.empty?'

# Test S3-2: new-task implementation creates parent_goal with required=false
S3_IMPL_TASK="$TMPROOT/slice3-impl-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S3_IMPL_TASK" >/dev/null
yaml_assert 'new-task implementation seeds parent_goal with required=false' "$S3_IMPL_TASK" \
  'j["parent_goal"].is_a?(Hash) && j["parent_goal"]["required"] == false'
yaml_assert 'new-task implementation seeds parent_goal_status with not_applicable state' "$S3_IMPL_TASK" \
  'j["parent_goal_status"].is_a?(Hash) && j["parent_goal_status"]["state"] == "not_applicable"'

# Test S3-3: validate fails when parent_goal.required=true but objective is empty
S3_NO_OBJ_TASK="$TMPROOT/slice3-no-objective-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_NO_OBJ_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["parent_goal"]["objective"]=""; File.write(p, YAML.dump(y))' \
  "$S3_NO_OBJ_TASK"
S3_EVIDENCE="$TMPROOT/slice3-evidence.json"
"$CLI" evidence init --output "$S3_EVIDENCE" >/dev/null
expect_failure 'validate rejects parent task with empty objective' \
  "$CLI" validate --task "$S3_NO_OBJ_TASK" --evidence "$S3_EVIDENCE" --json

# Test S3-4: validate fails when parent_goal.required=true but done_criteria is empty
S3_NO_CRITERIA_TASK="$TMPROOT/slice3-no-criteria-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_NO_CRITERIA_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["done_criteria"]=[]
   y["parent_goal"]["objective"]="This is a valid objective."
   File.write(p, YAML.dump(y))' \
  "$S3_NO_CRITERIA_TASK"
expect_failure 'validate rejects parent task with empty done_criteria' \
  "$CLI" validate --task "$S3_NO_CRITERIA_TASK" --evidence "$S3_EVIDENCE" --json

# Test S3-5: validate passes (no parent ceremony) when parent_goal.required=false
# (uses the implementation task from S3-2 which already has required=false)
"$CLI" validate --task "$S3_IMPL_TASK" --evidence "$S3_EVIDENCE" --json >"$TMPROOT/slice3-impl-validate.json" 2>/dev/null || true
json_assert 'validate passes for non-parent task (required=false) without parent ceremony' \
  "$TMPROOT/slice3-impl-validate.json" \
  '!j["errors"].any? { |e| e["source"].to_s.include?("parent_goal") }'

# Test S3-6: schema_semantics includes parent_goal_status feature version
yaml_assert 'new-task includes parent_goal_status in schema_semantics feature_versions' \
  "$S3_IMPL_TASK" \
  'j["schema_semantics"]["feature_versions"]["parent_goal_status"] == "v1"'

# Test S3-7: audit includes parent_goal_summary
S3_AUDIT_TASK="$TMPROOT/slice3-audit-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["objective"]="Achieve a well-scoped parent outcome."
   File.write(p, YAML.dump(y))' \
  "$S3_AUDIT_TASK"
S3_AUDIT_EVIDENCE="$TMPROOT/slice3-audit-evidence.json"
"$CLI" evidence init --output "$S3_AUDIT_EVIDENCE" >/dev/null
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S3_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml
"$CLI" audit --task "$S3_AUDIT_TASK" --evidence "$S3_AUDIT_EVIDENCE" --state .orbit/loop-state.yaml --json \
  >"$TMPROOT/slice3-audit.json" 2>/dev/null || true
json_assert 'audit includes parent_goal_summary for decomposition task' \
  "$TMPROOT/slice3-audit.json" \
  'j["parent_goal_summary"].is_a?(Hash) && j["parent_goal_summary"]["required"] == true'

# Test S3-8: audit reports unevidenced criteria when parent_goal_status.state=parent_done but criteria not evidenced
S3_DONE_TASK="$TMPROOT/slice3-done-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_DONE_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["objective"]="Deliver the parent outcome."
   y["parent_goal"]["done_criteria"]=["All slices complete.", "Evidence covers all criteria."]
   y["parent_goal_status"]["state"]="parent_done"
   y["parent_goal_status"]["done_criteria_status"]=[]
   File.write(p, YAML.dump(y))' \
  "$S3_DONE_TASK"
S3_DONE_EVIDENCE="$TMPROOT/slice3-done-evidence.json"
"$CLI" evidence init --output "$S3_DONE_EVIDENCE" >/dev/null
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S3_DONE_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml
"$CLI" audit --task "$S3_DONE_TASK" --evidence "$S3_DONE_EVIDENCE" --state .orbit/loop-state.yaml --json \
  >"$TMPROOT/slice3-done-audit.json" 2>/dev/null || true
json_assert 'audit parent_goal_summary reports unevidenced criteria when parent_done with no evidence' \
  "$TMPROOT/slice3-done-audit.json" \
  'pgs = j["parent_goal_summary"]; pgs["unevidenced_criteria"].is_a?(Array) && !pgs["unevidenced_criteria"].empty? && pgs["blocking"].is_a?(Array) && !pgs["blocking"].empty?'
json_assert 'audit parent_goal_summary blocking contains done_criteria message' \
  "$TMPROOT/slice3-done-audit.json" \
  'pgs = j["parent_goal_summary"]; pgs["blocking"].any? { |b| b["source"] == "parent_goal_status.done_criteria" }'

# Test S3-9: handoff includes parent_goal_status with user_next_action
S3_HO_TASK="$TMPROOT/slice3-handoff-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_HO_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["objective"]="Deliver the decomposed parent outcome."
   File.write(p, YAML.dump(y))' \
  "$S3_HO_TASK"
S3_HO_EVIDENCE="$TMPROOT/slice3-handoff-evidence.json"
"$CLI" evidence init --output "$S3_HO_EVIDENCE" >/dev/null
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S3_HO_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true)
   s["current_task"]=ARGV[1]; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=ARGV[2]
   s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml "$S3_HO_TASK" "$S3_HO_EVIDENCE"
ORBIT_INSTANCE=lead "$CLI" handoff --task "$S3_HO_TASK" --state .orbit/loop-state.yaml \
  --evidence "$S3_HO_EVIDENCE" --json >"$TMPROOT/slice3-handoff.json" 2>/dev/null || true
json_assert 'handoff includes parent_goal_status' \
  "$TMPROOT/slice3-handoff.json" \
  'j["parent_goal_status"].is_a?(Hash) && j["parent_goal_status"]["state"] == "parent_in_progress"'
json_assert 'handoff parent_goal_status includes user_next_action' \
  "$TMPROOT/slice3-handoff.json" \
  'j["parent_goal_status"]["user_next_action"].is_a?(Hash) && !j["parent_goal_status"]["user_next_action"]["default"].to_s.strip.empty?'

# Test S3-10: wait-gate includes parent_goal_status in output
S3_WG_TASK="$TMPROOT/slice3-wg-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_WG_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["objective"]="Wait-gate parent goal."
   File.write(p, YAML.dump(y))' \
  "$S3_WG_TASK"
S3_WG_EVIDENCE="$TMPROOT/slice3-wg-evidence.json"
"$CLI" evidence init --output "$S3_WG_EVIDENCE" >/dev/null
"$CLI" wait-gate --task "$S3_WG_TASK" --evidence "$S3_WG_EVIDENCE" --json \
  >"$TMPROOT/slice3-wg.json" 2>/dev/null || true
json_assert 'wait-gate includes parent_goal_status from task' \
  "$TMPROOT/slice3-wg.json" \
  'j["parent_goal_status"].is_a?(Hash) && j["parent_goal_status"]["state"] == "parent_in_progress"'

# Test S3-11: state progress --parent-state updates task file
S3_PROGRESS_TASK="$TMPROOT/slice3-progress-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$S3_PROGRESS_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true)
   y["parent_goal"]["objective"]="Parent goal for progress test."
   File.write(p, YAML.dump(y))' \
  "$S3_PROGRESS_TASK"
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$S3_PROGRESS_TASK" >/dev/null
ORBIT_INSTANCE=lead "$CLI" state progress --task "$S3_PROGRESS_TASK" \
  --message "Slice 1 complete" --parent-state slice_ready --active-slice "S1" >/dev/null
yaml_assert 'state progress --parent-state updates parent_goal_status.state in task file' \
  "$S3_PROGRESS_TASK" \
  'j["parent_goal_status"]["state"] == "slice_ready"'
yaml_assert 'state progress --active-slice updates parent_goal_status.active_slice in task file' \
  "$S3_PROGRESS_TASK" \
  'j["parent_goal_status"]["active_slice"] == "S1"'


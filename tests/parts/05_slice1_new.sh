# ---------------------------------------------------------------------------
# Phase 1 Slice 1 new tests: gate-kind-aware minimum, residual_risk, defaults
# ---------------------------------------------------------------------------

# Fix 1 + Fix 2: test_strategy.minimum_evidence_level is read for test gate
# TEST_TASK now has test_strategy.minimum_evidence_level: real_path_test by default.
# Verify wait-gate passes with real_path_test evidence on TEST_TASK.
yaml_assert 'new-task for tester creates test_strategy with minimum_evidence_level real_path_test' \
  "$TEST_TASK" \
  'j["test_strategy"].is_a?(Hash) && j["test_strategy"]["minimum_evidence_level"] == "real_path_test"'

# Verify test gate blocks when evidence_level is below test_strategy minimum
BELOW_MIN_TEST_EVIDENCE="$TMPROOT/below-min-test-evidence.json"
"$CLI" evidence init --output "$BELOW_MIN_TEST_EVIDENCE" >/dev/null
cat >"$TMPROOT/below-min-test-report.yaml" <<'YAML'
kind: test
verdict: pass
summary: Test pass with mechanical_check level below test minimum.
source_message_id: herdr:tester:below-min
test_level: repo_regression
evidence_level: mechanical_check
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: below_min_test
      verdict: pass
      evidence: Mechanical check only.
  not_applicable: []
confirmed:
  - Mechanical check performed.
assumed: []
missing: []
residual_risk: "Minimal evidence only: mechanical_check."
findings: []
coverage:
  - mechanical check only
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
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$BELOW_MIN_TEST_EVIDENCE" --report "$TMPROOT/below-min-test-report.yaml" --json >/dev/null
if "$CLI" wait-gate --task "$TEST_TASK" --evidence "$BELOW_MIN_TEST_EVIDENCE" --json >"$TMPROOT/wait-gate-below-min-test.json"; then
  printf 'FAIL test gate rejects mechanical_check below real_path_test minimum: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'test gate rejects mechanical_check below real_path_test minimum'
json_assert 'test gate reports evidence_level_below_minimum for test_strategy minimum' \
  "$TMPROOT/wait-gate-below-min-test.json" \
  'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "test" && g["blocking_reason"] == "evidence_level_below_minimum" && g["evidence_level"] == "mechanical_check" && g["minimum_evidence_level"] == "real_path_test" }'

# Fix 2: design_readiness gate is satisfied by review evidence record
DESIGN_GATE_TASK="$TMPROOT/design-gate-kind-task.yaml"
"$CLI" new-task --target-role reviewer --task-type design_review --output "$DESIGN_GATE_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"design_readiness","roles"=>["reviewer"],"required"=>true,"pass_condition"=>"design artifact reviewed"}]; File.write(p, YAML.dump(y))' \
  "$DESIGN_GATE_TASK"
DESIGN_READINESS_EVIDENCE="$TMPROOT/design-readiness-evidence.json"
"$CLI" evidence init --output "$DESIGN_READINESS_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/design-readiness-review-pass.yaml" "Design readiness review passed." "herdr:reviewer:design-readiness"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="implementation_readiness"; y["implementation_readiness_verdict"]="pass"; File.write(p, YAML.dump(y))' \
  "$TMPROOT/design-readiness-review-pass.yaml"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$DESIGN_READINESS_EVIDENCE" --report "$TMPROOT/design-readiness-review-pass.yaml" --json >/dev/null
"$CLI" wait-gate --task "$DESIGN_GATE_TASK" --evidence "$DESIGN_READINESS_EVIDENCE" --json >"$TMPROOT/wait-gate-design-readiness.json"
json_assert 'design_readiness gate is satisfied by review evidence record' \
  "$TMPROOT/wait-gate-design-readiness.json" \
  'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "design_readiness" && g["passed"] == true && g["evidence_level"] == "implementation_readiness" }'

# Fix 3: evidence submit requires residual_risk for PASS
MISSING_RESIDUAL_EVIDENCE="$TMPROOT/missing-residual-evidence.json"
"$CLI" evidence init --output "$MISSING_RESIDUAL_EVIDENCE" >/dev/null
cat >"$TMPROOT/missing-residual-report.yaml" <<'YAML'
kind: review
verdict: pass
summary: Review pass missing required residual_risk.
source_message_id: herdr:reviewer:missing-residual
quality_outcome_verdict: pass
quality_outcome_reasoning: Outcome checked.
findings: []
coverage:
  - review checked behavior
artifacts:
  - tests/orbit_test.sh
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: outcome_review
      verdict: pass
      evidence: Outcome checked.
  not_applicable: []
quality_question_answers:
  - id: outcome_satisfied
    verdict: pass
    evidence: Outcome satisfied.
confirmed:
  - Outcome confirmed.
assumed: []
missing: []
counterexample_cases:
  - none
implementation_readiness_verdict: not_checked
YAML
expect_failure 'evidence submit rejects pass without residual_risk' \
  env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$MISSING_RESIDUAL_EVIDENCE" --report "$TMPROOT/missing-residual-report.yaml" --json

# Fix 4: new-task reviewer creates review_strategy.minimum_evidence_level: outcome_quality
REVIEWER_NEW_TASK="$TMPROOT/reviewer-new-task.yaml"
"$CLI" new-task --target-role reviewer --task-type review --output "$REVIEWER_NEW_TASK" >/dev/null
yaml_assert 'new-task for reviewer creates review_strategy minimum_evidence_level outcome_quality' \
  "$REVIEWER_NEW_TASK" \
  'j["review_strategy"]["minimum_evidence_level"] == "outcome_quality"'

# Fix 4: new-task design task creates review_strategy.minimum_evidence_level: implementation_readiness
DESIGN_NEW_TASK="$TMPROOT/design-new-task-fix4.yaml"
"$CLI" new-task --target-role lead --task-type design --output "$DESIGN_NEW_TASK" >/dev/null
yaml_assert 'new-task for design type creates review_strategy minimum_evidence_level implementation_readiness' \
  "$DESIGN_NEW_TASK" \
  'j["review_strategy"]["minimum_evidence_level"] == "implementation_readiness"'

# ---------------------------------------------------------------------------
# Phase 1 Slice 1 reviewer round-2 fixes
# ---------------------------------------------------------------------------

# Fix: release gate is satisfied by tester submitting test evidence with release_readiness level
RELEASE_GATE_TASK="$TMPROOT/release-gate-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$RELEASE_GATE_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"release","roles"=>["tester"],"required"=>true,"pass_condition"=>"release evidence accepted"}]; File.write(p, YAML.dump(y))' \
  "$RELEASE_GATE_TASK"
RELEASE_EVIDENCE="$TMPROOT/release-evidence.json"
"$CLI" evidence init --output "$RELEASE_EVIDENCE" >/dev/null
cat >"$TMPROOT/release-pass-report.yaml" <<'YAML'
kind: test
verdict: pass
summary: Release gate test evidence with release_readiness level.
source_message_id: herdr:tester:release-gate
test_level: repo_regression
evidence_level: release_readiness
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: release_gate_test
      verdict: pass
      evidence: Release readiness verified.
  not_applicable: []
confirmed:
  - Release readiness verified.
assumed: []
missing: []
residual_risk: "No residual risk: all release paths verified."
findings: []
coverage:
  - release gate test evidence accepted
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
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$RELEASE_EVIDENCE" --report "$TMPROOT/release-pass-report.yaml" --json >/dev/null
"$CLI" wait-gate --task "$RELEASE_GATE_TASK" --evidence "$RELEASE_EVIDENCE" --json >"$TMPROOT/wait-gate-release.json"
json_assert 'release gate is satisfied by tester test evidence with release_readiness level' \
  "$TMPROOT/wait-gate-release.json" \
  'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "release" && g["passed"] == true && g["evidence_level"] == "release_readiness" }'

# Fix: residual_risk surfaced in wait-gate gate status
json_assert 'wait-gate gate status includes residual_risk from pass record' \
  "$TMPROOT/wait-gate-release.json" \
  'j["gates"].any? { |g| g["kind"] == "release" && g["residual_risk"] == "No residual risk: all release paths verified." }'

# Fix: residual_risk surfaced in aggregate verdict entry
RELEASE_EVIDENCE_SHOW="$TMPROOT/release-evidence-show.json"
"$CLI" evidence show --file "$RELEASE_EVIDENCE" --json >"$RELEASE_EVIDENCE_SHOW"
json_assert 'aggregate verdict gate entry includes residual_risk' \
  "$RELEASE_EVIDENCE_SHOW" \
  'j["verdict"]["gates"]["test"]["residual_risk"] == "No residual risk: all release paths verified."'

# Fix: residual_risk surfaced in handoff judgment_summary
RELEASE_HANDOFF_TASK="$TMPROOT/release-handoff-task.yaml"
"$CLI" new-task --target-role tester --task-type implementation_test --output "$RELEASE_HANDOFF_TASK" >/dev/null
RELEASE_HANDOFF_EVIDENCE="$TMPROOT/release-handoff-evidence.json"
"$CLI" evidence init --output "$RELEASE_HANDOFF_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$RELEASE_HANDOFF_EVIDENCE" --report "$TMPROOT/release-pass-report.yaml" --json >/dev/null
RELEASE_HANDOFF_STATE="$TMPROOT/release-handoff-state.yaml"
cp .orbit/loop-state.yaml "$RELEASE_HANDOFF_STATE"
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["current_task"]=ARGV[1]; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=ARGV[2]; s["phase"]="working"; s["status"]="working"; File.write(p, YAML.dump(s))' \
  "$RELEASE_HANDOFF_STATE" "$(realpath "$RELEASE_HANDOFF_TASK")" "$(realpath "$RELEASE_HANDOFF_EVIDENCE")"
ORBIT_INSTANCE=tester "$CLI" handoff --task "$RELEASE_HANDOFF_TASK" --state "$RELEASE_HANDOFF_STATE" --evidence "$RELEASE_HANDOFF_EVIDENCE" --json \
  >"$TMPROOT/release-handoff.json" 2>/dev/null || true
json_assert 'handoff judgment_summary test_judgment includes residual_risk' \
  "$TMPROOT/release-handoff.json" \
  'j["judgment_summary"]["test_judgment"]["residual_risk"] == "No residual risk: all release paths verified."'

# Fix: review-report.yaml template includes residual_risk field
yaml_assert 'review-report template includes residual_risk field' \
  "$SKILL_ROOT/assets/templates/review-report.yaml" \
  'j.key?("residual_risk")'

# Fix: test-report.yaml template includes residual_risk field
yaml_assert 'test-report template includes residual_risk field' \
  "$SKILL_ROOT/assets/templates/test-report.yaml" \
  'j.key?("residual_risk")'

# ---------------------------------------------------------------------------
# High fix: audit done-state gate check respects GATE_KIND_EVIDENCE_RECORD_KIND
# ---------------------------------------------------------------------------

# audit done-state with release gate satisfied by tester test evidence (no identity_mismatch)
RELEASE_AUDIT_TASK="$TMPROOT/release-audit-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$RELEASE_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"release","roles"=>["tester"],"required"=>true,"pass_condition"=>"release gate passed"}]; File.write(p, YAML.dump(y))' \
  "$RELEASE_AUDIT_TASK"
RELEASE_AUDIT_EVIDENCE="$TMPROOT/release-audit-evidence.json"
"$CLI" evidence init --output "$RELEASE_AUDIT_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$RELEASE_AUDIT_EVIDENCE" --report "$TMPROOT/release-pass-report.yaml" --json >/dev/null
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$RELEASE_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="done"; s["status"]="done"; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml "$RELEASE_AUDIT_EVIDENCE"
"$CLI" audit --task "$RELEASE_AUDIT_TASK" --evidence "$RELEASE_AUDIT_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-release-gate.json" 2>/dev/null
json_assert 'audit done-state passes when release gate satisfied by tester test evidence' \
  "$TMPROOT/audit-release-gate.json" \
  'j["blocking_findings"].none? { |f| f["source"].include?("release") } && j["trusted_for_done"] == true'

# audit done-state with design_readiness gate satisfied by reviewer review evidence
DESIGN_AUDIT_TASK="$TMPROOT/design-audit-task.yaml"
"$CLI" new-task --target-role reviewer --task-type design_review --output "$DESIGN_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"design_readiness","roles"=>["reviewer"],"required"=>true,"pass_condition"=>"design readiness passed"}]; File.write(p, YAML.dump(y))' \
  "$DESIGN_AUDIT_TASK"
DESIGN_AUDIT_EVIDENCE="$TMPROOT/design-audit-evidence.json"
"$CLI" evidence init --output "$DESIGN_AUDIT_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$DESIGN_AUDIT_EVIDENCE" --report "$TMPROOT/design-readiness-review-pass.yaml" --json >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$DESIGN_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="done"; s["status"]="done"; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml "$DESIGN_AUDIT_EVIDENCE"
"$CLI" audit --task "$DESIGN_AUDIT_TASK" --evidence "$DESIGN_AUDIT_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-design-readiness-gate.json" 2>/dev/null
json_assert 'audit done-state passes when design_readiness gate satisfied by reviewer review evidence' \
  "$TMPROOT/audit-design-readiness-gate.json" \
  'j["blocking_findings"].none? { |f| f["source"].include?("design_readiness") } && j["trusted_for_done"] == true'

# ---------------------------------------------------------------------------
# High regression: gate_passed? with malformed created_at must not crash audit
# ---------------------------------------------------------------------------

MALFORMED_AUDIT_TASK="$TMPROOT/malformed-audit-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$MALFORMED_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"release","roles"=>["tester"],"required"=>true,"pass_condition"=>"release gate passed"}]; File.write(p, YAML.dump(y))' \
  "$MALFORMED_AUDIT_TASK"
MALFORMED_AUDIT_EVIDENCE="$TMPROOT/malformed-audit-evidence.json"
"$CLI" evidence init --output "$MALFORMED_AUDIT_EVIDENCE" >/dev/null
# Inject a test record with malformed created_at directly into the evidence file
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; ev=JSON.parse(File.read(p)); ev["records"]||=[]; ev["records"]<<{"kind"=>"test","status"=>"pass","structured_submit"=>true,"created_at"=>"not-a-date","identity"=>{"resolved_role"=>"tester"},"evidence_level"=>"release_readiness","residual_risk"=>"acceptable"}; File.write(p, JSON.generate(ev))' \
  "$MALFORMED_AUDIT_EVIDENCE"
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$MALFORMED_AUDIT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="done"; s["status"]="done"; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml "$MALFORMED_AUDIT_EVIDENCE"
"$CLI" audit --task "$MALFORMED_AUDIT_TASK" --evidence "$MALFORMED_AUDIT_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-malformed-created-at.json" 2>/dev/null || true
json_assert 'audit returns structured JSON (not crash) when evidence record has malformed created_at' \
  "$TMPROOT/audit-malformed-created-at.json" \
  'j.key?("blocking_findings") && j.key?("trusted_for_done")'

# ---------------------------------------------------------------------------
# Phase 1 Slice 2: Quality Outcome Guardrails
# ---------------------------------------------------------------------------

# new-task for improvement task type seeds invalid_completion_guards
IMPROVEMENT_TASK="$TMPROOT/slice2-improvement-task.yaml"
"$CLI" new-task --target-role reviewer --task-type docs_improvement --output "$IMPROVEMENT_TASK" >/dev/null
yaml_assert 'new-task improvement task seeds invalid_completion_guards' "$IMPROVEMENT_TASK" \
  'j["invalid_completion_guards"].is_a?(Array) && !j["invalid_completion_guards"].empty? && j["invalid_completion_guards"].all? { |g| g["id"].is_a?(String) && !g["id"].empty? && g["description"].is_a?(String) && !g["description"].empty? && g["evidence_required"].is_a?(String) && !g["evidence_required"].empty? }'
yaml_assert 'new-task review_strategy includes required_questions' "$IMPROVEMENT_TASK" \
  'j["review_strategy"]["required_questions"] == %w[outcome counterexamples evidence_sufficiency residual_risk]'

# validate rejects improvement task with malformed invalid_completion_guards
MALFORMED_GUARDS_TASK="$TMPROOT/slice2-malformed-guards-task.yaml"
cp "$IMPROVEMENT_TASK" "$MALFORMED_GUARDS_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["invalid_completion_guards"]=[{"id"=>"","description"=>"missing id"}]; File.write(p, YAML.dump(y))' "$MALFORMED_GUARDS_TASK"
expect_failure 'validate rejects improvement task with malformed invalid_completion_guards' "$CLI" validate --task "$MALFORMED_GUARDS_TASK" --json

# wait-gate blocks when review record has quality_outcome_verdict != pass (manual injection)
QO_FAIL_EVIDENCE="$TMPROOT/slice2-qo-fail-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$QO_FAIL_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["quality_outcome_verdict"]="fail"; File.write(p, JSON.pretty_generate(j))' "$QO_FAIL_EVIDENCE"
if "$CLI" wait-gate --task "$TASK" --evidence "$QO_FAIL_EVIDENCE" --json >"$TMPROOT/slice2-qo-fail-wait-gate.json" 2>/dev/null; then
  printf 'FAIL wait-gate blocks when quality_outcome_verdict is fail: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate blocks when quality_outcome_verdict is fail'
json_assert 'wait-gate reports quality_outcome_not_pass blocking reason' "$TMPROOT/slice2-qo-fail-wait-gate.json" \
  'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "quality_outcome_not_pass" }'

# wait-gate blocks when review record missing required question coverage
QO_MISSING_Q_EVIDENCE="$TMPROOT/slice2-missing-question-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$QO_MISSING_Q_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["quality_question_answers"]=[{"id"=>"outcome","verdict"=>"pass","evidence"=>"only outcome covered"}]; File.write(p, JSON.pretty_generate(j))' "$QO_MISSING_Q_EVIDENCE"
expect_failure 'validate rejects review pass missing required question coverage' "$CLI" validate --task "$TASK" --evidence "$QO_MISSING_Q_EVIDENCE" --json

# audit shows quality_outcome_summary
json_assert 'audit includes quality_outcome_summary with gate verdicts' \
  "$TMPROOT/audit-release-gate.json" \
  'j.key?("quality_outcome_summary") && j["quality_outcome_summary"].key?("gate_quality_outcomes")'

# audit shows invalid_completion_guards in quality_outcome_summary for improvement task
AUDIT_IMPROVEMENT_EVIDENCE="$TMPROOT/slice2-audit-improvement-evidence.json"
"$CLI" evidence init --output "$AUDIT_IMPROVEMENT_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$AUDIT_IMPROVEMENT_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --json >/dev/null
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$IMPROVEMENT_TASK" >/dev/null
ruby --disable-gems -ryaml -e \
  'p=ARGV[0]; s=YAML.safe_load(File.read(p), aliases: true); s["phase"]="done"; s["status"]="done"; s["artifacts"]||={}; s["artifacts"]["evidence_file"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(s))' \
  .orbit/loop-state.yaml "$AUDIT_IMPROVEMENT_EVIDENCE"
"$CLI" audit --task "$IMPROVEMENT_TASK" --evidence "$AUDIT_IMPROVEMENT_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/slice2-audit-improvement.json" 2>/dev/null || true
json_assert 'audit shows invalid_completion_guards for improvement task' \
  "$TMPROOT/slice2-audit-improvement.json" \
  'qos = j["quality_outcome_summary"]; qos.is_a?(Hash) && qos["invalid_completion_guards"].is_a?(Array) && !qos["invalid_completion_guards"].empty?'

# wait-gate blocks when a required question answer has verdict != pass
QO_BLOCKED_Q_EVIDENCE="$TMPROOT/slice2-blocked-question-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$QO_BLOCKED_Q_EVIDENCE"
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["quality_question_answers"].find { |a| a["id"]=="counterexamples" }["verdict"]="blocked"; File.write(p, JSON.pretty_generate(j))' \
  "$QO_BLOCKED_Q_EVIDENCE"
if "$CLI" wait-gate --task "$TASK" --evidence "$QO_BLOCKED_Q_EVIDENCE" --json >"$TMPROOT/slice2-blocked-question-wait-gate.json" 2>/dev/null; then
  printf 'FAIL wait-gate blocks when required question verdict is blocked: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate blocks when required question verdict is blocked'
json_assert 'wait-gate reports required_questions_not_met blocking reason' "$TMPROOT/slice2-blocked-question-wait-gate.json" \
  'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "required_questions_not_met" }'

# validate rejects review pass where required question answer is non-pass verdict
QO_FAIL_Q_EVIDENCE="$TMPROOT/slice2-fail-question-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$QO_FAIL_Q_EVIDENCE"
ruby --disable-gems -rjson -e \
  'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["quality_question_answers"].find { |a| a["id"]=="counterexamples" }["verdict"]="fail"; File.write(p, JSON.pretty_generate(j))' \
  "$QO_FAIL_Q_EVIDENCE"
expect_failure 'validate rejects review pass with counterexamples verdict fail' "$CLI" validate --task "$TASK" --evidence "$QO_FAIL_Q_EVIDENCE" --json

# audit shows addressed status per guard
json_assert 'audit guard summary includes addressed field per guard' \
  "$TMPROOT/slice2-audit-improvement.json" \
  'qos = j["quality_outcome_summary"]; qos["invalid_completion_guards"].all? { |g| g.key?("addressed") && g.key?("addressed_via") && g.key?("coverage") }'
json_assert 'audit guard without guard-specific answer has addressed=false and coverage=general_only or none' \
  "$TMPROOT/slice2-audit-improvement.json" \
  'qos = j["quality_outcome_summary"]; qos["invalid_completion_guards"].all? { |g| g["coverage"] == "guard_specific" || g["addressed"] == false }'
json_assert 'audit all_satisfied ignores test/release gates (not_applicable)' \
  "$TMPROOT/audit-release-gate.json" \
  'qos = j["quality_outcome_summary"]; qos["gate_quality_outcomes"].any? { |_k,v| v["satisfied"] == "not_applicable" } && [true, false].include?(qos["all_satisfied"])'


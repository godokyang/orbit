EVIDENCE="$SKILL_ROOT/assets/templates/evidence.json"
expect_failure 'validate review task requires evidence' "$CLI" validate --task "$TASK" --json
"$CLI" validate --task "$TASK" --evidence "$EVIDENCE" --json >"$TMPROOT/valid-task-evidence.json" 2>"$TMPROOT/valid-task-evidence.err"
test ! -s "$TMPROOT/valid-task-evidence.err"
json_assert 'validate passes valid task with evidence' "$TMPROOT/valid-task-evidence.json" 'j["valid"] == true && j["checked"].include?("task") && j["checked"].include?("evidence")'

cp "$TASK" "$TMPROOT/task-missing-target.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("target_role"); File.write(p, YAML.dump(y))' "$TMPROOT/task-missing-target.yaml"
expect_failure 'validate fails task missing target_role' "$CLI" validate --task "$TMPROOT/task-missing-target.yaml" --evidence "$EVIDENCE" --json

cp "$TASK" "$TMPROOT/task-missing-evidence-req.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("evidence_requirements"); File.write(p, YAML.dump(y))' "$TMPROOT/task-missing-evidence-req.yaml"
expect_failure 'validate fails task missing evidence_requirements' "$CLI" validate --task "$TMPROOT/task-missing-evidence-req.yaml" --evidence "$EVIDENCE" --json

cp "$TASK" "$TMPROOT/task-missing-qo.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_type"]="quality_improvement"; y.delete("quality_outcome"); File.write(p, YAML.dump(y))' "$TMPROOT/task-missing-qo.yaml"
expect_failure 'validate fails improvement task missing quality_outcome' "$CLI" validate --task "$TMPROOT/task-missing-qo.yaml" --evidence "$EVIDENCE" --json

cp "$TASK" "$TMPROOT/task-empty-qo.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_type"]="quality_improvement"; y["quality_outcome"]={"user_problem"=>"","desired_property"=>"","measurable_thresholds"=>[],"invalid_completions"=>[]}; File.write(p, YAML.dump(y))' "$TMPROOT/task-empty-qo.yaml"
expect_failure 'validate fails improvement task empty quality_outcome fields' "$CLI" validate --task "$TMPROOT/task-empty-qo.yaml" --evidence "$EVIDENCE" --json

expect_failure 'validate fails coding task without confirmed design reference' "$CLI" validate --task "$CODING_TASK" --evidence "$EVIDENCE" --json
cp "$CODING_TASK" "$TMPROOT/coding-confirmed-design.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["design_reference"]={"required_for_coding"=>true,"artifact"=>"docs/open/design.md","confirmation_evidence"=>"evidence:user_confirmed","status"=>"confirmed"}; File.write(p, YAML.dump(y))' "$TMPROOT/coding-confirmed-design.yaml"
"$CLI" validate --task "$TMPROOT/coding-confirmed-design.yaml" --evidence "$EVIDENCE" --json >"$TMPROOT/coding-confirmed-design.json"
json_assert 'validate passes coding task with confirmed design reference' "$TMPROOT/coding-confirmed-design.json" 'j["valid"] == true'

expect_failure 'validate fails decomposition task missing aggregate contract details' "$CLI" validate --task "$DECOMP_TASK" --evidence "$EVIDENCE" --json
cp "$DECOMP_TASK" "$TMPROOT/decomposition-complete.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["implementation_plan"]["summary"]="Split parent work into reviewed child slices."; y["decomposition"]["child_slices"]=[{"id"=>"S1","include"=>"first child behavior","exclude"=>"second child behavior","order_basis"=>"unblocks shared contract first","stop_condition"=>"slice review and tests pass","replan_path"=>"return to parent plan before continuing"}]; y["decomposition"]["aggregate_outcome_metrics"]=["parent outcome rechecked after child slices"]; y["decomposition"]["stop_conditions"]=["all child slices and parent audit pass"]; y["decomposition"]["replanning_path"]="return to design review"; y["final_aggregate_audit"]["checks"]=["parent outcome still holds"]; File.write(p, YAML.dump(y))' "$TMPROOT/decomposition-complete.yaml"
"$CLI" validate --task "$TMPROOT/decomposition-complete.yaml" --evidence "$EVIDENCE" --json >"$TMPROOT/decomposition-complete.json"
json_assert 'validate passes complete decomposition contract' "$TMPROOT/decomposition-complete.json" 'j["valid"] == true'

QUALITY_EVIDENCE="$TMPROOT/quality-measurement-evidence.json"
"$CLI" evidence init --output "$QUALITY_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/quality-review-pass.yaml" "Quality review passed." "herdr:reviewer:quality-review"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$QUALITY_EVIDENCE" --report "$TMPROOT/quality-review-pass.yaml" --json >/dev/null
write_test_pass_report "$TMPROOT/quality-test-missing-baseline.yaml" "Quality test missing baseline." "herdr:tester:quality-test-missing-baseline"
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$QUALITY_EVIDENCE" --report "$TMPROOT/quality-test-missing-baseline.yaml" --json >/dev/null
expect_failure 'validate rejects quality measurement pass without baseline after evidence' "$CLI" validate --task "$PERFORMANCE_TASK" --evidence "$QUALITY_EVIDENCE" --json
cat >"$TMPROOT/quality-measurement-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Performance quality measurement includes baseline and after values.
source_message_id: herdr:tester:quality-measurement-pass
test_level: repo_regression
findings: []
coverage:
  - measured baseline and after behavior
artifacts:
  - .orbit/test-artifacts/quality-measurement.json
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: quality_measurement_test
      verdict: pass
      evidence: Baseline and after behavior were measured.
  not_applicable: []
confirmed:
  - Baseline and after behavior were measured.
assumed: []
missing: []
residual_risk: "No residual risk: all required paths covered by test evidence."
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
quality_measurement:
  baseline: 120
  after: 80
  metrics:
    - name: command runtime ms
      baseline: 120
      after: 80
      evidence: .orbit/test-artifacts/quality-measurement.json
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$QUALITY_EVIDENCE" --report "$TMPROOT/quality-measurement-submit.yaml" --json >"$TMPROOT/quality-measurement-submit.json"
"$CLI" validate --task "$PERFORMANCE_TASK" --evidence "$QUALITY_EVIDENCE" --json >"$TMPROOT/valid-quality-measurement.json"
json_assert 'validate accepts quality measurement baseline and after evidence' "$TMPROOT/valid-quality-measurement.json" 'j["valid"] == true'

cp "$EVIDENCE" "$TMPROOT/invalid-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["verdict"]["status"]="maybe"; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/invalid-evidence.json"
expect_failure 'validate fails invalid evidence verdict' "$CLI" validate --evidence "$TMPROOT/invalid-evidence.json" --json
expect_failure 'validate rejects missing task option value' "$CLI" validate --task --json
expect_failure 'validate rejects missing evidence option value' "$CLI" validate --evidence --json
expect_failure 'validate rejects missing state option value' "$CLI" validate --state --json


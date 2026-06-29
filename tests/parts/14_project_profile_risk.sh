# ---------------------------------------------------------------------------
# Slice 11: project-profile-and-risk-level acceptance tests
# ---------------------------------------------------------------------------

# ---- Group 1: new-task writes task_risk and project_profile ----

S11_IMPL_TASK="$TMPROOT/s11-impl-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S11_IMPL_TASK" >/dev/null
yaml_assert 'new-task implementation writes task_risk' "$S11_IMPL_TASK" \
  'j["task_risk"].is_a?(Hash) && j["task_risk"]["level"].is_a?(String) && !j["task_risk"]["level"].empty?'
yaml_assert 'new-task implementation derives standard risk' "$S11_IMPL_TASK" \
  'j["task_risk"]["level"] == "standard"'
yaml_assert 'new-task writes project_profile' "$S11_IMPL_TASK" \
  'j["project_profile"].is_a?(Hash) && j["project_profile"]["default_risk_level"] == "standard"'
yaml_assert 'new-task implementation has review and test gates' "$S11_IMPL_TASK" \
  'j["gates"].is_a?(Array) && j["gates"].any? { |g| g["kind"] == "review" } && j["gates"].any? { |g| g["kind"] == "test" }'
yaml_assert 'new-task implementation has task_risk in schema_semantics' "$S11_IMPL_TASK" \
  'j["schema_semantics"]["feature_versions"]["project_profile_risk_level"] == "v1"'
pass 'new-task writes task_risk and project_profile for standard implementation'

# ---- Group 2: docs task derives light risk ----

S11_DOCS_TASK="$TMPROOT/s11-docs-task.yaml"
"$CLI" new-task --target-role reviewer --task-type docs_improvement --output "$S11_DOCS_TASK" >/dev/null
yaml_assert 'new-task docs derives light risk' "$S11_DOCS_TASK" \
  'j["task_risk"]["level"] == "light"'
yaml_assert 'new-task light task has no required gates' "$S11_DOCS_TASK" \
  'j["gates"].is_a?(Array) && j["gates"].empty?'
yaml_assert 'docs light task project_profile.default_risk_level stays standard' "$S11_DOCS_TASK" \
  'j["project_profile"]["default_risk_level"] == "standard"'
pass 'docs task derives light risk'

# ---- Group 3: release task type derives release risk ----

S11_RELEASE_TASK="$TMPROOT/s11-release-task.yaml"
"$CLI" new-task --target-role lead --task-type release_implementation --output "$S11_RELEASE_TASK" >/dev/null
yaml_assert 'new-task release derives release risk' "$S11_RELEASE_TASK" \
  'j["task_risk"]["level"] == "release"'
yaml_assert 'new-task release has release gate' "$S11_RELEASE_TASK" \
  'j["gates"].is_a?(Array) && j["gates"].any? { |g| g["kind"] == "release" }'
yaml_assert 'new-task release has strict write_policy_enforcement' "$S11_RELEASE_TASK" \
  'j["write_policy_enforcement"] == "strict"'
yaml_assert 'release task project_profile.default_risk_level stays standard' "$S11_RELEASE_TASK" \
  'j["project_profile"]["default_risk_level"] == "standard"'
pass 'release task type derives release risk with release gate and strict enforcement'

# ---- Group 4: light task validates without parent goal or review evidence ----

S11_LIGHT_EVIDENCE="$TMPROOT/s11-light-evidence.json"
"$CLI" evidence init --output "$S11_LIGHT_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add \
  --file "$S11_LIGHT_EVIDENCE" --kind command --status pass --summary "docs typo fixed" >/dev/null
"$CLI" validate --task "$S11_DOCS_TASK" --evidence "$S11_LIGHT_EVIDENCE" --json >"$TMPROOT/s11-light-validate.json"
json_assert 'light task validates without review evidence' "$TMPROOT/s11-light-validate.json" \
  'j["valid"] == true'
pass 'light task does not require parent goal or formal review gate'

# ---- Group 5: strict task requires review/test gates and write policy ----

S11_STRICT_TASK="$TMPROOT/s11-strict-task.yaml"
"$CLI" new-task --target-role lead --task-type security_migration --output "$S11_STRICT_TASK" >/dev/null
yaml_assert 'new-task security_migration derives strict risk' "$S11_STRICT_TASK" \
  'j["task_risk"]["level"] == "strict"'
yaml_assert 'strict task has strict write_policy_enforcement' "$S11_STRICT_TASK" \
  'j["write_policy_enforcement"] == "strict"'
yaml_assert 'strict task has review and test gates' "$S11_STRICT_TASK" \
  'j["gates"].any? { |g| g["kind"] == "review" } && j["gates"].any? { |g| g["kind"] == "test" }'
pass 'strict task requires review/test gates and strict write policy'

# validate: strict task without write_policy_enforcement: strict fails
S11_BAD_STRICT_TASK="$TMPROOT/s11-bad-strict-task.yaml"
cp "$S11_STRICT_TASK" "$S11_BAD_STRICT_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["write_policy_enforcement"]="standard"; File.write(p, YAML.dump(y))' "$S11_BAD_STRICT_TASK"
expect_failure 'validate rejects strict task with standard write_policy_enforcement' "$CLI" validate --task "$S11_BAD_STRICT_TASK" --evidence "$S11_LIGHT_EVIDENCE" --json

# ---- Group 6: release task requires release gate ----

S11_BAD_RELEASE_TASK="$TMPROOT/s11-bad-release-task.yaml"
cp "$S11_RELEASE_TASK" "$S11_BAD_RELEASE_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=y["gates"].reject{|g|g["kind"]=="release"}; File.write(p, YAML.dump(y))' "$S11_BAD_RELEASE_TASK"
expect_failure 'validate rejects release task without release gate' "$CLI" validate --task "$S11_BAD_RELEASE_TASK" --json

# ---- Group 7: lowering minimum_evidence_level below risk default fails ----

S11_LOWERED_TASK="$TMPROOT/s11-lowered-task.yaml"
cp "$S11_IMPL_TASK" "$S11_LOWERED_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_risk"]["minimum_evidence_levels"]["review"]="mechanical_check"; File.write(p, YAML.dump(y))' "$S11_LOWERED_TASK"
expect_failure 'validate rejects lowered minimum_evidence_level below risk default' "$CLI" validate --task "$S11_LOWERED_TASK" --json

# ---- Group 8: classify-intent outputs risk_recommendation ----

"$CLI" classify-intent --text "fix a typo in the README" --json >"$TMPROOT/s11-intent-light.json"
json_assert 'classify-intent recommends light for docs typo' "$TMPROOT/s11-intent-light.json" \
  'j["risk_recommendation"]["level"] == "light"'

"$CLI" classify-intent --text "change the checkout button behavior on the main page" --json >"$TMPROOT/s11-intent-ui.json"
json_assert 'classify-intent recommends standard for UI behavior change' "$TMPROOT/s11-intent-ui.json" \
  'j["risk_recommendation"]["level"] == "standard"'

"$CLI" classify-intent --text "release and deploy version 2.0 to production" --json >"$TMPROOT/s11-intent-release.json"
json_assert 'classify-intent recommends release for deploy intent' "$TMPROOT/s11-intent-release.json" \
  'j["risk_recommendation"]["level"] == "release"'

# Chinese text coverage
"$CLI" classify-intent --text "改 README 错别字" --json >"$TMPROOT/s11-intent-cn-light.json"
json_assert 'classify-intent recommends light for Chinese docs typo' "$TMPROOT/s11-intent-cn-light.json" \
  'j["risk_recommendation"]["level"] == "light"'

"$CLI" classify-intent --text "修改页面交互按钮" --json >"$TMPROOT/s11-intent-cn-ui.json"
json_assert 'classify-intent recommends standard for Chinese UI interaction' "$TMPROOT/s11-intent-cn-ui.json" \
  'j["risk_recommendation"]["level"] == "standard"'

"$CLI" classify-intent --text "发布新版本上线" --json >"$TMPROOT/s11-intent-cn-release.json"
json_assert 'classify-intent recommends release for Chinese deploy/release' "$TMPROOT/s11-intent-cn-release.json" \
  'j["risk_recommendation"]["level"] == "release"'
pass 'classify-intent outputs risk_recommendation for Chinese light/standard/release'

# ---- Group 9: audit includes task_risk_summary ----

S11_AUDIT_STATE="$TMPROOT/s11-audit-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "in_review", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S11_IMPL_TASK" "$S11_LIGHT_EVIDENCE" "$S11_AUDIT_STATE"
"$CLI" audit --task "$S11_IMPL_TASK" --evidence "$S11_LIGHT_EVIDENCE" --state "$S11_AUDIT_STATE" --json >"$TMPROOT/s11-audit.json" 2>/dev/null || true
json_assert 'audit includes task_risk_summary' "$TMPROOT/s11-audit.json" \
  'j.key?("task_risk_summary") && j["task_risk_summary"]["level"] == "standard"'
json_assert 'audit task_risk_summary confirms project rules are supplement' "$TMPROOT/s11-audit.json" \
  'j["task_risk_summary"]["project_rules_are_supplement"] == true'

# ---- Group 10: strict task with evidence and write_policy passes validate ----

S11_STRICT_EVIDENCE="$TMPROOT/s11-strict-evidence.json"
"$CLI" evidence init --output "$S11_STRICT_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/s11-strict-review.yaml" "Strict task review passed." "herdr:reviewer:s11-strict"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$S11_STRICT_EVIDENCE" --report "$TMPROOT/s11-strict-review.yaml" --task "$S11_STRICT_TASK" --json >/dev/null
# Add test evidence with proper runtime_binding
write_test_pass_report "$TMPROOT/s11-strict-test.yaml" "Strict task test passed." "herdr:tester:s11-strict"
# Append test_environment
cat >>"$TMPROOT/s11-strict-test.yaml" <<'YAML'
test_environment:
  environment: local shell
  test_tab_or_pane: current pane
  server_owner: none
  browser_owner: none
  cleanup_hook: none
  artifact_cleanup: none
  duration: 1s
  resource_usage: low
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: ok
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$S11_STRICT_EVIDENCE" --report "$TMPROOT/s11-strict-test.yaml" --task "$S11_STRICT_TASK" --json >/dev/null
"$CLI" validate --task "$S11_STRICT_TASK" --evidence "$S11_STRICT_EVIDENCE" --json >"$TMPROOT/s11-strict-validate.json"
json_assert 'strict task validates with proper evidence' "$TMPROOT/s11-strict-validate.json" \
  'j["valid"] == true'
pass 'strict task validates with review/test evidence and strict write policy'

# ---- Group 11: invalid task_risk.level rejected by validate ----

S11_BAD_RISK_TASK="$TMPROOT/s11-bad-risk-task.yaml"
cp "$S11_IMPL_TASK" "$S11_BAD_RISK_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["task_risk"]["level"]="extreme"; File.write(p, YAML.dump(y))' "$S11_BAD_RISK_TASK"
expect_failure 'validate rejects invalid task_risk.level' "$CLI" validate --task "$S11_BAD_RISK_TASK" --json

# ---- Group 12: lowering review_strategy minimum_evidence_level below risk default fails ----

S11_STRATEGY_LOWERED_TASK="$TMPROOT/s11-strategy-lowered-task.yaml"
cp "$S11_IMPL_TASK" "$S11_STRATEGY_LOWERED_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["review_strategy"]["minimum_evidence_level"]="mechanical_check"; File.write(p, YAML.dump(y))' "$S11_STRATEGY_LOWERED_TASK"
expect_failure 'validate rejects lowered review_strategy minimum below risk default' "$CLI" validate --task "$S11_STRATEGY_LOWERED_TASK" --json

# ---- Group 13: release task without release_readiness fails ----

S11_NO_RR_TASK="$TMPROOT/s11-no-release-readiness-task.yaml"
cp "$S11_RELEASE_TASK" "$S11_NO_RR_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("release_readiness"); File.write(p, YAML.dump(y))' "$S11_NO_RR_TASK"
expect_failure 'validate rejects release task without release_readiness fields' "$CLI" validate --task "$S11_NO_RR_TASK" --json

# ---- Group 14: release task with release_readiness gap_declared ----

# new-task writes release_readiness.status == gap_declared.
yaml_assert 'release task has release_readiness gap_declared' "$S11_RELEASE_TASK" \
  'j["release_readiness"].is_a?(Hash) && j["release_readiness"]["status"] == "gap_declared"'

# validate does not report a task_file.release_readiness missing-field error when gap_declared is present.
"$CLI" validate --task "$S11_RELEASE_TASK" --json >"$TMPROOT/s11-release-validate.json" 2>/dev/null || true
json_assert 'validate has no release_readiness missing error with gap_declared' "$TMPROOT/s11-release-validate.json" \
  'j["errors"].none? { |e| e["source"] == "task_file.release_readiness" }'

# release task with only gap_declared should NOT be trusted_for_release in audit.
S11_RR_AUDIT_STATE="$TMPROOT/s11-rr-audit-state.yaml"
ruby --disable-gems -ryaml -e '
  s = { "schema_version" => "orbit-loop-state-v1", "phase" => "done", "current_task" => ARGV[0], "history" => [], "artifacts" => { "evidence_file" => ARGV[1] } }
  File.write(ARGV[2], YAML.dump(s))' "$S11_RELEASE_TASK" "$S11_LIGHT_EVIDENCE" "$S11_RR_AUDIT_STATE"
"$CLI" audit --task "$S11_RELEASE_TASK" --evidence "$S11_LIGHT_EVIDENCE" --state "$S11_RR_AUDIT_STATE" --json >"$TMPROOT/s11-rr-audit.json" 2>/dev/null || true
json_assert 'release task with gap_declared is not trusted_for_release' "$TMPROOT/s11-rr-audit.json" \
  'j["trusted_for_release"] == false'

# ---- Group 15: new-task creates nested output directory ----

S11_NESTED_TASK="$TMPROOT/s11-nested/deep/task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$S11_NESTED_TASK" >/dev/null
test -f "$S11_NESTED_TASK"
pass 'new-task creates nested output directory'

# ---- Group 16: validate rejects malformed project_profile ----

S11_BAD_PROFILE_TASK="$TMPROOT/s11-bad-profile-task.yaml"
cp "$S11_IMPL_TASK" "$S11_BAD_PROFILE_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["project_profile"]={"default_risk_level"=>"extreme","workflow_traits"=>"not-a-list"}; File.write(p, YAML.dump(y))' "$S11_BAD_PROFILE_TASK"
expect_failure 'validate rejects malformed project_profile' "$CLI" validate --task "$S11_BAD_PROFILE_TASK" --json

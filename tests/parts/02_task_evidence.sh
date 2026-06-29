TASK="$TMPROOT/review-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$TASK" >"$TMPROOT/new-task.out" 2>"$TMPROOT/new-task.err"
test ! -s "$TMPROOT/new-task.err"
yaml_assert 'new-task writes required fields' "$TASK" 'j["schema_version"] == "orbit-task-v1" && j["project"] == File.basename(Dir.pwd) && j["target_role"] == "reviewer" && j["task_type"] == "implementation_review" && %w[quality_outcome scope acceptance evidence_requirements stop_policy].all? { |k| j.key?(k) }'
yaml_assert 'new-task initializes runtime guardrail fields' "$TASK" 'j["source_contract"].is_a?(Hash) && j["traceability"].is_a?(Array) && j["worktree_safety"]["require_status_check"] == true && j["release_surface"].is_a?(Hash) && j["supply_chain"].is_a?(Hash) && j["final_audit"]["required"] == true'
yaml_assert 'new-task initializes non-empty quality outcome template' "$TASK" 'j["quality_outcome"]["user_problem"].is_a?(String) && !j["quality_outcome"]["user_problem"].empty? && j["quality_outcome"]["desired_property"].is_a?(String) && !j["quality_outcome"]["desired_property"].empty? && j["quality_outcome"]["measurable_thresholds"].is_a?(Array) && !j["quality_outcome"]["measurable_thresholds"].empty? && j["quality_outcome"]["invalid_completions"].is_a?(Array) && !j["quality_outcome"]["invalid_completions"].empty?'
yaml_assert 'new-task initializes outcome-first review strategy' "$TASK" 'j["review_strategy"]["entrypoints"].include?("quality_outcome") && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Outcome:") } && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Structure:") } && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Evidence:") }'
yaml_assert 'new-task does not invent project quality rules' "$TASK" 'j["quality_rules"].is_a?(Array) && j["quality_rules"].empty?'
yaml_assert 'new-task exposes configured review rule packs' "$TASK" 'j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }'
for typed in refactor docs performance ux; do
  TYPED_TASK="$TMPROOT/${typed}-task.yaml"
  "$CLI" new-task --target-role lead --task-type "${typed}_improvement" --output "$TYPED_TASK" >/dev/null
  case "$typed" in
    refactor) expected="responsibilities" ;;
    docs) expected="docs" ;;
    performance) expected="baseline" ;;
    ux) expected="user path" ;;
  esac
  yaml_assert "new-task writes ${typed} quality outcome template" "$TYPED_TASK" 'text = j["quality_outcome"].values.flatten.join(" ").downcase; !j["quality_outcome"]["measurable_thresholds"].empty? && text.include?(ARGV[2])' "$expected"
done
PERFORMANCE_TASK="$TMPROOT/performance-measurement-task.yaml"
"$CLI" new-task --target-role lead --task-type performance_improvement --output "$PERFORMANCE_TASK" >/dev/null
yaml_assert 'new-task initializes baseline and after quality measurement contract' "$PERFORMANCE_TASK" 'j["quality_measurement"]["required"] == true && j["quality_measurement"]["baseline_required"] == true && j["quality_measurement"]["after_required"] == true && j["quality_measurement"]["metrics"].is_a?(Array) && !j["quality_measurement"]["metrics"].empty?'
DESIGN_TASK="$TMPROOT/design-task.yaml"
"$CLI" new-task --target-role lead --task-type design --output "$DESIGN_TASK" >/dev/null
yaml_assert 'new-task initializes design lifecycle for design task' "$DESIGN_TASK" 'j["design_lifecycle"]["enabled"] == true && j["design_lifecycle"]["current_phase"] == "drafting" && j["design_lifecycle"]["phases"].include?("coding_ready") && j["design_lifecycle"]["user_confirmation_required"] == true'
CODING_TASK="$TMPROOT/coding-task.yaml"
"$CLI" new-task --target-role lead --task-type coding --output "$CODING_TASK" >/dev/null
yaml_assert 'new-task marks coding tasks as requiring confirmed design' "$CODING_TASK" 'j["design_reference"]["required_for_coding"] == true && j["design_reference"]["status"] == "unconfirmed"'
DECOMP_TASK="$TMPROOT/decomposition-task.yaml"
"$CLI" new-task --target-role lead --task-type decomposition --output "$DECOMP_TASK" >/dev/null
yaml_assert 'new-task initializes decomposition contract fields' "$DECOMP_TASK" 'j["implementation_plan"]["required"] == true && j["decomposition"]["child_slices"].is_a?(Array) && j["decomposition"]["aggregate_outcome_metrics"].is_a?(Array) && j["final_aggregate_audit"]["required"] == true'
expect_failure 'new-task refuses overwrite' "$CLI" new-task --target-role reviewer --task-type implementation_review --output "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer --json >"$TMPROOT/dispatch-generic.json"
json_assert 'dispatch generic emits manual delivery payload with context preflight' "$TMPROOT/dispatch-generic.json" 'j["schema_version"] == "orbit-dispatch-v1" && j["action"] == "manual_delivery_required" && j["transport"] == "generic" && j["to_instance"] == "reviewer" && j["resolved_role"] == "reviewer" && j["task"] == File.expand_path(ARGV[2]) && j["message"].include?("orbit whoami --json") && !j["message"].include?("orbit whoami --task") && j["message"].include?("orbit rules print-context --task") && j["message"].include?("context_preflight.required_files") && j["context_preflight"]["commands"].include?(["orbit", "whoami", "--json"]) && j["context_preflight"]["required_files"].any? { |r| r["path"] == "SKILL.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/guide.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" } && j["checks"]["target_role_matches"] == true' "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --reply-to observer-pane --dry-run --json >"$TMPROOT/dispatch-herdr-dry-run.json"
json_assert 'dispatch herdr dry-run emits adapter plan with explicit reply-to' "$TMPROOT/dispatch-herdr-dry-run.json" 'j["action"] == "dry_run" && j["reply_to"] == "observer-pane" && j["reply_to_source"] == "explicit_option" && j["message"].include?("reply-to:observer-pane") && j["adapter"]["schema_version"] == "orbit-herdr-dispatch-v1" && !j["adapter"].key?("submit_delay_seconds") && j["adapter"]["commands"] == [["herdr", "pane", "run", "pane-123", j["message"]]] && j["adapter"]["commands"][0][4].include?(File.expand_path(ARGV[2]))' "$TASK"
HERDR_PANE_ID=lead-reply-pane "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --dry-run --json >"$TMPROOT/dispatch-herdr-env-reply-to.json"
json_assert 'dispatch herdr reply-to defaults to current Herdr pane' "$TMPROOT/dispatch-herdr-env-reply-to.json" 'j["reply_to"] == "lead-reply-pane" && j["reply_to_source"] == "HERDR_PANE_ID" && j["message"].include?("reply-to:lead-reply-pane")'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_DISPATCH_ARGS:?}"
printf '%s\n' "$@" >>"$ORBIT_FAKE_HERDR_DISPATCH_ARGS"
printf '%s\n' '---' >>"$ORBIT_FAKE_HERDR_DISPATCH_ARGS"
printf 'sent:%s\n' "$3"
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
ORBIT_FAKE_HERDR_DISPATCH_ARGS="$TMPROOT/fake-herdr-dispatch-args.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --json >"$TMPROOT/dispatch-herdr-real.json"
json_assert 'dispatch herdr sends through adapter' "$TMPROOT/dispatch-herdr-real.json" 'j["action"] == "sent" && j["adapter_result"]["success"] == true && j["adapter_result"]["commands"].length == 1 && j["adapter_result"]["commands"].all? { |c| c["success"] }'
ruby --disable-gems -e 'actual=File.read(ARGV[0]).lines.map(&:chomp); sep=actual.index("---"); first=actual[0...sep]; message=first[3..].join("\n"); abort(actual.inspect) unless first[0,3] == ["pane","run","pane-123"] && message.include?(File.expand_path(ARGV[1])) && message.include?("kind:request")' "$TMPROOT/fake-herdr-dispatch-args.txt" "$TASK"
pass 'dispatch herdr submits message through pane run adapter'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
printf 'transport denied\n' >&2
exit 42
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --pane pane-123 --json >"$TMPROOT/dispatch-herdr-fail.json" 2>"$TMPROOT/dispatch-herdr-fail.err"; then
  printf 'FAIL dispatch herdr failure: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'dispatch herdr failure exits with fallback payload' "$TMPROOT/dispatch-herdr-fail.json" 'j["action"] == "failed" && j["adapter_result"]["success"] == false && j["fallback"]["transport"] == "generic" && j["fallback"]["action"] == "manual_delivery_required" && j["fallback"]["message"].include?(File.expand_path(ARGV[2]))' "$TASK"
expect_failure 'dispatch herdr requires pane' "$CLI" dispatch --task "$TASK" --to reviewer --transport herdr --json
expect_failure 'dispatch rejects unknown target instance' "$CLI" dispatch --task "$TASK" --to missing --json

mkdir -p docs
printf '%s\n' '# Review Rule' '- Check project-specific review constraints.' >docs/review-rule.md
cp .orbit/roles.yaml "$TMPROOT/roles-before-rules.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["roles"]["reviewer"]["rules"]=["docs/review-rule.md", {"path"=>"docs/review-rule.md", "id"=>"duplicate-review-rule", "relation"=>"supplements"}]; File.write(p, YAML.dump(y))' .orbit/roles.yaml
ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/rules-resolution.json" >"$TMPROOT/rules-resolution.stdout" 2>"$TMPROOT/rules-resolution.err"
test ! -s "$TMPROOT/rules-resolution.err"
cmp "$TMPROOT/rules-resolution.json" "$TMPROOT/rules-resolution.stdout"
json_assert 'rules resolve includes default, project, task, and rule pack sources' "$TMPROOT/rules-resolution.json" 'j["schema_version"] == "orbit-rule-resolution-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["sources"]["orbit_default"].any? { |r| r["path"] == "SKILL.md" && r["id"].is_a?(String) && r["relation"] == "baseline" && r["exists"] == true } && j["sources"]["orbit_default"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" && r["load_policy"] == "required" } && j["sources"]["project_rules"].any? { |r| r["path"] == "docs/review-rule.md" && r["id"].is_a?(String) && r["relation"] == "supplements" && r["exists"] == true } && j["sources"]["project_rules"].any? { |r| r["path"] == "docs/review-rule.md" && r["id"] == "duplicate-review-rule" } && j["sources"]["task_rules"]["path"] == File.expand_path(ARGV[2]) && j["sources"]["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }' "$TASK"
ORBIT_INSTANCE=reviewer "$CLI" rules print-context --task "$TASK" --json --output "$TMPROOT/rules-context.json" >"$TMPROOT/rules-context.stdout" 2>"$TMPROOT/rules-context.err"
test ! -s "$TMPROOT/rules-context.err"
cmp "$TMPROOT/rules-context.json" "$TMPROOT/rules-context.stdout"
json_assert 'rules print-context emits ordered default project task and pack context' "$TMPROOT/rules-context.json" 'j["schema_version"] == "orbit-rules-context-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["load_model"]["default_rules_always_loaded"] == true && j["load_model"]["project_rules_are_additive"] == true && j["load_order"].all? { |r| r["rule_id"].is_a?(String) && r["relation"].is_a?(String) && r["dedupe_status"].is_a?(String) } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "SKILL.md" && r["required"] == true && r["exists"] == true && r["dedupe_status"] == "active" } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "references/runtime/core-operating-model.md" && r["required"] == false } && j["load_order"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" && r["required"] == true && r["exists"] == true && r["dedupe_status"] == "active" } && j["load_order"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" && r["id"] == "duplicate-review-rule" && r["dedupe_status"] == "deduped" } && j["load_order"].any? { |r| r["source"] == "task_rules" && r["path"] == File.expand_path(ARGV[2]) && r["required"] == true } && j["load_order"].any? { |r| r["source"] == "rule_packs" && r["id"] == "brooks-review" && r["required"] == false } && j["required_files"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" } && j["required_files"].select { |r| r["path"] == "docs/review-rule.md" }.length == 1 && j["context_budget"]["deduped"].any? { |r| r["path"] == "docs/review-rule.md" } && j["context_budget"]["shadowed"].is_a?(Array) && j["context_budget"]["not_loaded_but_related"].is_a?(Array) && j["rule_resolution"]["schema_version"] == "orbit-rule-resolution-v1"' "$TASK"
ORBIT_ROLE=reviewer "$CLI" rules resolve --task "$TASK" --json >"$TMPROOT/rules-resolution-role.json"
json_assert 'rules resolve supports role identity' "$TMPROOT/rules-resolution-role.json" 'j["resolved_role"] == "reviewer" && j["valid"] == true'
ORBIT_INSTANCE=tester "$CLI" rules resolve --role reviewer --task "$TASK" --json >"$TMPROOT/rules-resolution-role-override.json"
json_assert 'rules resolve role option overrides ambient instance' "$TMPROOT/rules-resolution-role-override.json" 'j["resolved_role"] == "reviewer" && j["valid"] == true && !j["role_sources"].key?("env.ORBIT_INSTANCE")'
expect_failure 'rules resolve fails on task target mismatch' env ORBIT_INSTANCE=tester "$CLI" rules resolve --task "$TASK" --json
rm docs/review-rule.md
expect_failure 'rules resolve fails on missing project rule file' env ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$TASK" --json
expect_failure 'validate fails on missing configured project rule file' "$CLI" validate --json
cp "$TMPROOT/roles-before-rules.yaml" .orbit/roles.yaml
ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/current-rule-resolution.json" >/dev/null

APPEND_EVIDENCE="$TMPROOT/append-evidence.json"
"$CLI" evidence init --output "$APPEND_EVIDENCE" >"$TMPROOT/evidence-init.out" 2>"$TMPROOT/evidence-init.err"
test ! -s "$TMPROOT/evidence-init.err"
json_assert 'evidence init writes empty manifest' "$APPEND_EVIDENCE" 'j["schema_version"] == "orbit-evidence-v1" && j["project"] == File.basename(Dir.pwd) && j["records"].is_a?(Array) && j["records"].empty?'
json_assert 'evidence init initializes runtime evidence fields' "$APPEND_EVIDENCE" 'j["worktree_safety"]["status"] == "not_applicable" && j["regression_guard"]["status"] == "not_applicable" && j["release_surface"]["status"] == "not_applicable" && j["rule_resolution"]["file"] == "" && j["tool_calls"].is_a?(Array)'
expect_failure 'wait-gate fails before required review evidence' "$CLI" wait-gate --task "$TASK" --evidence "$APPEND_EVIDENCE" --json
expect_failure 'lead cannot submit review evidence' env ORBIT_INSTANCE=lead "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "lead review attempt"
expect_failure 'lead cannot submit test evidence' env ORBIT_INSTANCE=lead "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind test --status pass --summary "lead test attempt"
expect_failure 'client mismatch cannot submit review evidence' env ORBIT_INSTANCE=reviewer ORBIT_ROLE=reviewer ORBIT_CLIENT=opencode "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "client mismatch review attempt"
expect_failure 'reviewer cannot evidence add review pass without structured report' env ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "reviewer add review pass attempt"
expect_failure 'tester cannot evidence add test pass without structured report' env ORBIT_INSTANCE=tester "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind test --status pass --summary "tester add test pass attempt"
cat >"$TMPROOT/review-report.md" <<'REPORT'
APPROVED
review report confirms the implementation is acceptable.
REPORT
expect_failure 'evidence from-report rejects markdown review pass' env ORBIT_INSTANCE=reviewer "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-report.md" --json
printf '%s\n' 'APPROVED_WITH_NOTES' 'notes are not an automatic pass token.' >"$TMPROOT/review-with-notes-report.md"
expect_failure 'evidence from-report rejects non-contract verdict token' "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-with-notes-report.md" --json

STRUCTURED_REVIEW_EVIDENCE="$TMPROOT/structured-review-evidence.json"
"$CLI" evidence init --output "$STRUCTURED_REVIEW_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review.yaml" <<'YAML'
kind: review
verdict: pass
summary: Structured reviewer verdict passed.
source_message_id: herdr:reviewer:structured-pass
quality_outcome_verdict: pass
quality_outcome_reasoning: Outcome and acceptance evidence were checked.
findings: []
coverage:
  - review checked aggregate verdict behavior
artifacts:
  - tests/orbit_test.sh
YAML
append_review_quality_fields "$TMPROOT/structured-review.yaml"
expect_failure 'lead cannot structured submit review evidence' env ORBIT_INSTANCE=lead "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --json
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --json >"$TMPROOT/evidence-submit-review.json"
json_assert 'evidence submit records structured review verdict' "$TMPROOT/evidence-submit-review.json" 'j["schema_version"] == "orbit-evidence-submit-v1" && j["record"]["structured_submit"] == true && j["record"]["source_message_id"] == "herdr:reviewer:structured-pass" && j["record"]["coverage"].include?("review checked aggregate verdict behavior") && j["verdict"]["mode"] == "aggregate" && j["verdict"]["gates"]["review"]["structured"] == true'
cat >"$TMPROOT/review-missing-quality-outcome.yaml" <<'YAML'
kind: review
verdict: pass
summary: Missing quality outcome verdict.
source_message_id: herdr:reviewer:missing-qo
findings: []
coverage:
  - review checked behavior
artifacts:
  - tests/orbit_test.sh
YAML
append_review_quality_fields "$TMPROOT/review-missing-quality-outcome.yaml"
expect_failure 'evidence submit rejects review pass without quality_outcome_verdict' env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-missing-quality-outcome.yaml" --json
cat >"$TMPROOT/review-high-finding-incomplete.yaml" <<'YAML'
kind: review
verdict: fail
summary: High finding lacks required detail.
source_message_id: herdr:reviewer:high-incomplete
quality_outcome_verdict: fail
quality_outcome_reasoning: A high severity issue remains.
findings:
  - severity: high
    summary: Missing required detail.
coverage:
  - review checked finding schema
artifacts:
  - tests/orbit_test.sh
YAML
expect_failure 'evidence submit rejects high finding missing remedy fields' env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-high-finding-incomplete.yaml" --json
cat >"$TMPROOT/malformed-structured-review.yaml" <<'YAML'
kind: review
verdict: pass
summary: Malformed structured reviewer verdict.
source_message_id: herdr:reviewer:malformed
quality_outcome_verdict: pass
quality_outcome_reasoning: Outcome checked before schema validation.
findings: []
coverage:
  - name: malformed coverage object
artifacts:
  - tests/orbit_test.sh
YAML
append_review_quality_fields "$TMPROOT/malformed-structured-review.yaml"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/structured-review-before-malformed.json"
if env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/malformed-structured-review.yaml" --json >"$TMPROOT/malformed-submit.out" 2>"$TMPROOT/malformed-submit.err"; then
  printf 'FAIL evidence submit rejects malformed coverage entries before gate: command unexpectedly succeeded\n' >&2
  exit 1
fi
cmp "$TMPROOT/structured-review-before-malformed.json" "$STRUCTURED_REVIEW_EVIDENCE"
grep -q 'field: submit_report.coverage' "$TMPROOT/malformed-submit.err"
grep -q 'expected: list of non-empty strings' "$TMPROOT/malformed-submit.err"
grep -q 'actual: array<mapping>' "$TMPROOT/malformed-submit.err"
grep -q 'template: assets/templates/review-report.yaml' "$TMPROOT/malformed-submit.err"
pass 'evidence submit rejects malformed coverage entries before gate'
"$CLI" wait-gate --task "$TASK" --evidence "$STRUCTURED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-structured-review-pass.json"
json_assert 'wait-gate passes after structured review submit' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true && g["structured"] == true }'
json_assert 'wait-gate exposes role-authorized gate summary' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["gate_summary"]["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["identity_expected_role"] == "reviewer" && g["identity_resolved_role"] == "reviewer" && g["identity_valid"] == true }'
json_assert 'wait-gate exposes review evidence quality summary' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["gate_summary"]["evidence_levels"]["review"] == "outcome_quality" && j["gates"].any? { |g| g["kind"] == "review" && g["evidence_level"] == "outcome_quality" && g["quality_outcome_verdict"] == "pass" && g["rule_application_summary"]["applied_checks_count"] == 1 && g["evidence_boundary_summary"]["confirmed_count"] == 1 }'

for field in evidence_level rule_application quality_question_answers confirmed assumed missing counterexample_cases; do
  cp "$TMPROOT/structured-review.yaml" "$TMPROOT/review-missing-${field}.yaml"
  ruby --disable-gems -ryaml -e 'p=ARGV[0]; field=ARGV[1]; y=YAML.safe_load(File.read(p), aliases: true); y.delete(field); File.write(p, YAML.dump(y))' "$TMPROOT/review-missing-${field}.yaml" "$field"
  expect_failure "evidence submit rejects review pass without ${field}" env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-missing-${field}.yaml" --json
done

cp "$TMPROOT/structured-review.yaml" "$TMPROOT/review-implementation-readiness-blocked.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="implementation_readiness"; y["implementation_readiness_verdict"]="blocked"; File.write(p, YAML.dump(y))' "$TMPROOT/review-implementation-readiness-blocked.yaml"
expect_failure 'evidence submit rejects implementation_readiness review without readiness pass' env ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-implementation-readiness-blocked.yaml" --json

MIN_OUTCOME_TASK="$TMPROOT/min-outcome-task.yaml"
cp "$TASK" "$MIN_OUTCOME_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["review_strategy"] ||= {}; y["review_strategy"]["minimum_evidence_level"]="outcome_quality"; File.write(p, YAML.dump(y))' "$MIN_OUTCOME_TASK"
"$CLI" wait-gate --task "$MIN_OUTCOME_TASK" --evidence "$STRUCTURED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-min-outcome-pass.json"
json_assert 'minimum outcome_quality accepts outcome review evidence' "$TMPROOT/wait-gate-min-outcome-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["minimum_evidence_level"] == "outcome_quality" && g["evidence_level"] == "outcome_quality" }'

MECHANICAL_REVIEW_EVIDENCE="$TMPROOT/mechanical-review-evidence.json"
"$CLI" evidence init --output "$MECHANICAL_REVIEW_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/mechanical-review-pass.yaml" "Mechanical review passed." "herdr:reviewer:mechanical"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="mechanical_check"; File.write(p, YAML.dump(y))' "$TMPROOT/mechanical-review-pass.yaml"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$MECHANICAL_REVIEW_EVIDENCE" --report "$TMPROOT/mechanical-review-pass.yaml" --json >/dev/null
if "$CLI" wait-gate --task "$MIN_OUTCOME_TASK" --evidence "$MECHANICAL_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-min-outcome-blocked.json"; then
  printf 'FAIL wait-gate rejects review below minimum evidence level: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects review below minimum evidence level'
json_assert 'wait-gate reports minimum evidence level blocker' "$TMPROOT/wait-gate-min-outcome-blocked.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "evidence_level_below_minimum" && g["evidence_level"] == "mechanical_check" && g["minimum_evidence_level"] == "outcome_quality" }'
expect_failure 'validate rejects review below minimum evidence level' "$CLI" validate --task "$MIN_OUTCOME_TASK" --evidence "$MECHANICAL_REVIEW_EVIDENCE" --json

MIN_IMPL_TASK="$TMPROOT/min-implementation-readiness-task.yaml"
cp "$TASK" "$MIN_IMPL_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["review_strategy"] ||= {}; y["review_strategy"]["minimum_evidence_level"]="implementation_readiness"; File.write(p, YAML.dump(y))' "$MIN_IMPL_TASK"
if "$CLI" wait-gate --task "$MIN_IMPL_TASK" --evidence "$STRUCTURED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-min-impl-blocked.json"; then
  printf 'FAIL wait-gate rejects outcome review below implementation readiness: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects outcome review below implementation readiness'
json_assert 'wait-gate reports implementation readiness minimum blocker' "$TMPROOT/wait-gate-min-impl-blocked.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "evidence_level_below_minimum" && g["evidence_level"] == "outcome_quality" && g["minimum_evidence_level"] == "implementation_readiness" }'

IMPLEMENTATION_READY_EVIDENCE="$TMPROOT/implementation-ready-review-evidence.json"
"$CLI" evidence init --output "$IMPLEMENTATION_READY_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/implementation-ready-review-pass.yaml" "Implementation readiness review passed." "herdr:reviewer:implementation-ready"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="implementation_readiness"; y["implementation_readiness_verdict"]="pass"; File.write(p, YAML.dump(y))' "$TMPROOT/implementation-ready-review-pass.yaml"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$IMPLEMENTATION_READY_EVIDENCE" --report "$TMPROOT/implementation-ready-review-pass.yaml" --json >/dev/null
"$CLI" wait-gate --task "$MIN_IMPL_TASK" --evidence "$IMPLEMENTATION_READY_EVIDENCE" --json >"$TMPROOT/wait-gate-min-impl-pass.json"
json_assert 'minimum implementation_readiness accepts readiness review evidence' "$TMPROOT/wait-gate-min-impl-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["minimum_evidence_level"] == "implementation_readiness" && g["evidence_level"] == "implementation_readiness" && g["implementation_readiness_verdict"] == "pass" }'

IDENTITY_MISMATCH_EVIDENCE="$TMPROOT/identity-mismatch-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$IDENTITY_MISMATCH_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); rec=j["records"].last; if rec.key?("role_execution_context"); rec["role_execution_context"]["resolved_role"]="lead"; else; rec["identity"]||={}; rec["identity"]["resolved_role"]="lead"; end; File.write(p, JSON.pretty_generate(j))' "$IDENTITY_MISMATCH_EVIDENCE"
if "$CLI" wait-gate --task "$TASK" --evidence "$IDENTITY_MISMATCH_EVIDENCE" --json >"$TMPROOT/wait-gate-identity-mismatch.json" 2>"$TMPROOT/wait-gate-identity-mismatch.err"; then
  printf 'FAIL wait-gate rejects identity-mismatched structured review evidence: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects identity-mismatched structured review evidence'
json_assert 'wait-gate reports identity mismatch blocker' "$TMPROOT/wait-gate-identity-mismatch.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "identity_mismatch" } && j["gates"].any? { |g| g["kind"] == "review" && g["identity_resolved_role"] == "lead" && g["identity_valid"] == false }'
expect_failure 'validate rejects identity-mismatched structured review evidence' "$CLI" validate --task "$TASK" --evidence "$IDENTITY_MISMATCH_EVIDENCE" --json
MISSING_IDENTITY_EVIDENCE="$TMPROOT/missing-identity-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$MISSING_IDENTITY_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last.delete("identity"); j["records"].last.delete("role_execution_context"); File.write(p, JSON.pretty_generate(j))' "$MISSING_IDENTITY_EVIDENCE"
if "$CLI" wait-gate --task "$TASK" --evidence "$MISSING_IDENTITY_EVIDENCE" --json >"$TMPROOT/wait-gate-missing-identity.json" 2>"$TMPROOT/wait-gate-missing-identity.err"; then
  printf 'FAIL wait-gate rejects hand-written structured review without identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects hand-written structured review without identity'
json_assert 'wait-gate reports missing identity as mismatch blocker' "$TMPROOT/wait-gate-missing-identity.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "identity_mismatch" } && j["gates"].any? { |g| g["kind"] == "review" && g["identity_resolved_role"].nil? && g["identity_valid"] == false }'
MISSING_QO_EVIDENCE="$TMPROOT/missing-quality-outcome-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$MISSING_QO_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last.delete("quality_outcome_verdict"); File.write(p, JSON.pretty_generate(j))' "$MISSING_QO_EVIDENCE"
expect_failure 'validate rejects hand-written structured review without quality_outcome_verdict' "$CLI" validate --task "$TASK" --evidence "$MISSING_QO_EVIDENCE" --json

BLOCKED_REVIEW_EVIDENCE="$TMPROOT/blocked-review-evidence.json"
"$CLI" evidence init --output "$BLOCKED_REVIEW_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review-blocked.yaml" <<'YAML'
kind: review
verdict: blocked
summary: Structured reviewer verdict is blocked on missing acceptance criteria.
source_message_id: herdr:reviewer:structured-blocked
quality_outcome_verdict: blocked
quality_outcome_reasoning: Acceptance criteria are ambiguous, so the outcome cannot be verified.
findings:
  - acceptance criteria are still ambiguous
coverage:
  - review checked task contract and evidence contract
artifacts:
  - review transcript
blocked:
  reason: acceptance criteria are ambiguous
  next_step: lead must clarify pass criteria before implementation can close
  owner: lead
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$BLOCKED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review-blocked.yaml" --json >"$TMPROOT/evidence-submit-blocked-review.json"
json_assert 'evidence submit records blocked detail as partial verdict' "$TMPROOT/evidence-submit-blocked-review.json" 'j["record"]["status"] == "partial" && j["record"]["blocked"]["reason"] == "acceptance criteria are ambiguous" && j["verdict"]["gates"]["review"]["blocked"]["owner"] == "lead"'
if "$CLI" wait-gate --task "$TASK" --evidence "$BLOCKED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-blocked-review.json" 2>"$TMPROOT/wait-gate-blocked-review.err"; then
  printf 'FAIL wait-gate reports blocked structured review evidence: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate reports blocked structured review evidence'
json_assert 'wait-gate includes blocked detail in gate status' "$TMPROOT/wait-gate-blocked-review.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["status"] == "blocked" && g["record_status"] == "partial" && g["blocked"]["owner"] == "lead" } && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["status"] == "blocked" }'
TEMPLATE_REVIEW_EVIDENCE="$TMPROOT/template-review-evidence.json"
"$CLI" evidence init --output "$TEMPLATE_REVIEW_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$TEMPLATE_REVIEW_EVIDENCE" --report "$SKILL_ROOT/assets/templates/review-report.yaml" --json >"$TMPROOT/template-review-submit.json"
json_assert 'review report template is directly submittable as blocked evidence' "$TMPROOT/template-review-submit.json" 'j["record"]["kind"] == "review" && j["record"]["status"] == "partial" && j["record"]["blocked"]["owner"] == "lead" && j["record"]["findings"].all? { |f| f.is_a?(String) }'

AGGREGATE_EVIDENCE="$TMPROOT/aggregate-evidence.json"
"$CLI" evidence init --output "$AGGREGATE_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review-fail.yaml" <<'YAML'
kind: review
verdict: fail
summary: Structured reviewer verdict failed.
source_message_id: herdr:reviewer:structured-fail
quality_outcome_verdict: fail
quality_outcome_reasoning: Blocking review finding remains.
findings:
  - blocking finding retained
coverage:
  - review checked failure path
artifacts:
  - review transcript
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$AGGREGATE_EVIDENCE" --report "$TMPROOT/structured-review-fail.yaml" --json >/dev/null
"$CLI" evidence add --file "$AGGREGATE_EVIDENCE" --kind command --status pass --summary "later command pass must not mask review fail" >/dev/null
json_assert 'aggregate verdict is not overwritten by latest command pass' "$AGGREGATE_EVIDENCE" 'j["verdict"]["mode"] == "aggregate" && j["verdict"]["status"] == "fail" && j["verdict"]["latest_record"]["kind"] == "command" && j["verdict"]["gates"]["review"]["status"] == "fail"'

WAIVER_EVIDENCE="$TMPROOT/waiver-evidence.json"
"$CLI" evidence init --output "$WAIVER_EVIDENCE" >/dev/null
cat >"$TMPROOT/invalid-waiver.yaml" <<'YAML'
owner: lead
scope: browser e2e
reason: missing risk fields
YAML
expect_failure 'evidence waive rejects incomplete waiver schema' "$CLI" evidence waive --file "$WAIVER_EVIDENCE" --waiver "$TMPROOT/invalid-waiver.yaml" --json
cat >"$TMPROOT/valid-waiver.yaml" <<'YAML'
owner: lead
scope: browser e2e
reason: CLI schema-only slice
risk: Browser runtime behavior is not proven by this slice.
replacement_evidence: tests/orbit_test.sh covers CLI behavior.
expiry: P2-S7
revoked_by_user_requirement: false
YAML
"$CLI" evidence waive --file "$WAIVER_EVIDENCE" --waiver "$TMPROOT/valid-waiver.yaml" --json >"$TMPROOT/evidence-waive.json"
json_assert 'evidence waive records structured waiver and aggregate risk' "$TMPROOT/evidence-waive.json" 'j["schema_version"] == "orbit-evidence-waiver-v1" && j["waiver"]["owner"] == "lead" && j["waiver"]["risk"].include?("Browser runtime") && j["verdict"]["mode"] == "aggregate" && j["verdict"]["status"] == "partial" && j["verdict"]["waivers"]["open"] == 1'
"$CLI" validate --evidence "$WAIVER_EVIDENCE" --json >"$TMPROOT/valid-waiver-evidence.json"
json_assert 'validate accepts structured waiver schema' "$TMPROOT/valid-waiver-evidence.json" 'j["valid"] == true'
TEST_TASK="$TMPROOT/test-task.yaml"
"$CLI" new-task --target-role tester --task-type implementation_test --output "$TEST_TASK" >/dev/null
yaml_assert 'new-task initializes test environment contract' "$TEST_TASK" 'j["test_environment"]["required"] == true && %w[environment test_tab_or_pane server_owner browser_owner cleanup_hook artifact_cleanup duration_budget resource_budget].all? { |k| j["test_environment"][k].is_a?(String) && !j["test_environment"][k].empty? }'
yaml_assert 'new-task initializes test level contract' "$TEST_TASK" 'j["test_level"] == "repo_regression"'
TEST_EVIDENCE="$TMPROOT/test-evidence.json"
"$CLI" evidence init --output "$TEST_EVIDENCE" >/dev/null
TEMPLATE_TEST_EVIDENCE="$TMPROOT/template-test-evidence.json"
"$CLI" evidence init --output "$TEMPLATE_TEST_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$TEMPLATE_TEST_EVIDENCE" --report "$SKILL_ROOT/assets/templates/test-report.yaml" --json >"$TMPROOT/template-test-submit.json"
json_assert 'test report template is directly submittable as blocked evidence' "$TMPROOT/template-test-submit.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "partial" && j["record"]["blocked"]["owner"] == "lead" && j["record"]["test_environment"]["cleanup_status"].is_a?(String)'
cat >"$TMPROOT/test-report.yaml" <<'REPORT'
kind: test
verdict: pass
summary: Browser scenarios passed.
source_message_id: herdr:tester:from-report-pass
test_level: repo_regression
findings: []
coverage:
  - browser scenarios passed
artifacts:
  - tests/orbit_test.sh
REPORT
append_test_quality_fields "$TMPROOT/test-report.yaml"
ORBIT_INSTANCE=tester "$CLI" evidence from-report --file "$TEST_EVIDENCE" --report "$TMPROOT/test-report.yaml" --json >"$TMPROOT/evidence-from-test-report.json"
json_assert 'evidence from-report imports structured test verdict' "$TMPROOT/evidence-from-test-report.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "pass" && j["record"]["summary"] == "Browser scenarios passed." && j["record"]["structured_submit"] == true && j["record"]["evidence_level"] == "real_path_test"'
"$CLI" wait-gate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json >"$TMPROOT/wait-gate-test-pass.json"
json_assert 'wait-gate passes after imported test evidence' "$TMPROOT/wait-gate-test-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "test" && g["passed"] == true }'
expect_failure 'validate rejects passing test evidence without environment contract evidence' "$CLI" validate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json
cat >"$TMPROOT/complete-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Structured test evidence includes environment lifecycle.
source_message_id: herdr:tester:complete-test-env
test_level: repo_regression
findings: []
coverage:
  - test exercised success path and cleanup path
artifacts:
  - .orbit/test-artifacts/complete-test-env.log
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: environment_lifecycle
      verdict: pass
      evidence: Test environment lifecycle was recorded.
  not_applicable: []
confirmed:
  - Test environment lifecycle was recorded.
assumed: []
missing: []
residual_risk: "No residual risk: all required paths covered by test evidence."
test_environment:
  environment: local shell
  test_tab_or_pane: current pane
  server_owner: none
  browser_owner: none
  cleanup_hook: trap removed temp directory
  artifact_cleanup: retained compact log only
  duration: 1s
  resource_usage: one shell process
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: artifact path is stable and small
runtime_binding:
  build:
    git_head: "fixture-build"
  browser:
    name: "fixture-browser"
    owner: "tester"
YAML
for field in evidence_level rule_application confirmed assumed missing; do
  cp "$TMPROOT/complete-test-submit.yaml" "$TMPROOT/test-missing-${field}.yaml"
  ruby --disable-gems -ryaml -e 'p=ARGV[0]; field=ARGV[1]; y=YAML.safe_load(File.read(p), aliases: true); y.delete(field); File.write(p, YAML.dump(y))' "$TMPROOT/test-missing-${field}.yaml" "$field"
  expect_failure "evidence submit rejects test pass without ${field}" env ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$TEST_EVIDENCE" --report "$TMPROOT/test-missing-${field}.yaml" --json
done
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$TEST_EVIDENCE" --report "$TMPROOT/complete-test-submit.yaml" --json >"$TMPROOT/complete-test-submit.json"
"$CLI" validate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json >"$TMPROOT/valid-complete-test-env.json"
json_assert 'validate accepts passing test evidence with environment lifecycle' "$TMPROOT/valid-complete-test-env.json" 'j["valid"] == true'

CONCURRENT_EVIDENCE="$TMPROOT/concurrent-gate-evidence.json"
CONCURRENT_GATE_TASK="$TMPROOT/concurrent-gate-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$CONCURRENT_GATE_TASK" >/dev/null
"$CLI" evidence init --output "$CONCURRENT_EVIDENCE" >/dev/null
(
  ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --json >"$TMPROOT/concurrent-review-submit.json"
) &
review_pid=$!
(
  ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/complete-test-submit.yaml" --json >"$TMPROOT/concurrent-test-submit.json"
) &
test_pid=$!
wait "$review_pid"
wait "$test_pid"
"$CLI" evidence show --file "$CONCURRENT_EVIDENCE" --json >"$TMPROOT/concurrent-gate-evidence-show.json"
json_assert 'concurrent evidence submits retain review and test records' "$TMPROOT/concurrent-gate-evidence-show.json" 'j["records"].count { |r| r["kind"] == "review" && r["status"] == "pass" } == 1 && j["records"].count { |r| r["kind"] == "test" && r["status"] == "pass" } == 1 && j["verdict"]["gates"]["review"]["status"] == "pass" && j["verdict"]["gates"]["test"]["status"] == "pass"'
"$CLI" wait-gate --task "$CONCURRENT_GATE_TASK" --evidence "$CONCURRENT_EVIDENCE" --json >"$TMPROOT/wait-gate-concurrent-submit.json"
json_assert 'wait-gate passes after concurrent structured review and test submit' "$TMPROOT/wait-gate-concurrent-submit.json" 'j["ready"] == true && j["gate_summary"]["required"].sort == ["review", "test"] && (["review", "test"] - j["gate_summary"]["passed"]).empty?'
MIN_TEST_TASK="$TMPROOT/min-test-quality-task.yaml"
cp "$TEST_TASK" "$MIN_TEST_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["test_strategy"] ||= {}; y["test_strategy"]["minimum_evidence_level"]="real_path_test"; File.write(p, YAML.dump(y))' "$MIN_TEST_TASK"
cp "$TEST_EVIDENCE" "$TMPROOT/legacy-test-missing-evidence-level.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].reverse.find { |r| r["kind"] == "test" && r["status"] == "pass" }.delete("evidence_level"); File.write(p, JSON.pretty_generate(j))' "$TMPROOT/legacy-test-missing-evidence-level.json"
if "$CLI" wait-gate --task "$MIN_TEST_TASK" --evidence "$TMPROOT/legacy-test-missing-evidence-level.json" --json >"$TMPROOT/wait-gate-test-missing-evidence-level.json"; then
  printf 'FAIL wait-gate rejects test pass missing evidence_level for quality-gated task: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects test pass missing evidence_level for quality-gated task'
json_assert 'wait-gate reports test missing evidence level blocker' "$TMPROOT/wait-gate-test-missing-evidence-level.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "test" && g["blocking_reason"] == "missing_evidence_level" } && j["gates"].any? { |g| g["kind"] == "test" && g["passed"] == false && g["blocking_reason"] == "missing_evidence_level" }'
expect_failure 'validate rejects test pass missing evidence_level for quality-gated task' "$CLI" validate --task "$MIN_TEST_TASK" --evidence "$TMPROOT/legacy-test-missing-evidence-level.json" --json
cp "$TEST_EVIDENCE" "$TMPROOT/missing-test-level-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last.delete("test_level"); File.write(p, JSON.pretty_generate(j))' "$TMPROOT/missing-test-level-evidence.json"
expect_failure 'validate rejects passing test evidence without test_level' "$CLI" validate --task "$TEST_TASK" --evidence "$TMPROOT/missing-test-level-evidence.json" --json
cp "$TEST_EVIDENCE" "$TMPROOT/mismatched-test-level-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last["test_level"]="manual"; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/mismatched-test-level-evidence.json"
expect_failure 'validate rejects passing test evidence overclaiming test_level' "$CLI" validate --task "$TEST_TASK" --evidence "$TMPROOT/mismatched-test-level-evidence.json" --json
OPTIONAL_GATE_TASK="$TMPROOT/optional-gate-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$OPTIONAL_GATE_TASK" >/dev/null
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"].each { |g| g["required"]=false if g["kind"]=="test" }; File.write(p, YAML.dump(y))' "$OPTIONAL_GATE_TASK"
OPTIONAL_GATE_EVIDENCE="$TMPROOT/optional-gate-evidence.json"
"$CLI" evidence init --output "$OPTIONAL_GATE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/optional-review-pass.yaml" "Required review passed." "herdr:reviewer:optional-gate"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$OPTIONAL_GATE_EVIDENCE" --report "$TMPROOT/optional-review-pass.yaml" --json >/dev/null
"$CLI" wait-gate --task "$OPTIONAL_GATE_TASK" --evidence "$OPTIONAL_GATE_EVIDENCE" --json >"$TMPROOT/wait-gate-optional-pass.json"
json_assert 'wait-gate ignores optional gates' "$TMPROOT/wait-gate-optional-pass.json" 'j["ready"] == true && j["gates"].map { |g| g["kind"] } == ["review"]'
expect_failure 'evidence init refuses overwrite' "$CLI" evidence init --output "$APPEND_EVIDENCE"
write_review_pass_report "$TMPROOT/append-review-pass.yaml" "Review passed." "herdr:reviewer:append-review"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$APPEND_EVIDENCE" --report "$TMPROOT/append-review-pass.yaml" --json >"$TMPROOT/evidence-add-review.out" 2>"$TMPROOT/evidence-add-review.err"
test ! -s "$TMPROOT/evidence-add-review.err"
"$CLI" evidence show --file "$APPEND_EVIDENCE" --json >"$TMPROOT/evidence-show.json" 2>"$TMPROOT/evidence-show.err"
test ! -s "$TMPROOT/evidence-show.err"
json_assert 'evidence submit appends structured review record' "$TMPROOT/evidence-show.json" 'j["records"].length >= 1 && j["records"].last["kind"] == "review" && j["records"].last["status"] == "pass" && j["records"].last["summary"] == "Review passed." && j["records"].last["structured_submit"] == true && j["records"].last["evidence_level"] == "outcome_quality" && j["records"].last["created_at"].is_a?(String)'
"$CLI" evidence add --file "$APPEND_EVIDENCE" --kind command --status partial --summary "command evidence retained" >/dev/null
json_assert 'evidence add preserves history' "$APPEND_EVIDENCE" 'j["records"].length >= 2 && j["records"][-2]["kind"] == "review" && j["records"][-1]["kind"] == "command"'
expect_failure 'evidence add rejects invalid status' env ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status maybe --summary "bad status"
expect_failure 'evidence add rejects empty summary' "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind command --status pass --summary ""
"$CLI" validate --task "$TASK" --evidence "$APPEND_EVIDENCE" --json >"$TMPROOT/valid-append-evidence.json"
json_assert 'validate reads appended review evidence' "$TMPROOT/valid-append-evidence.json" 'j["valid"] == true && j["checked"].include?("evidence")'
BAD_RELEASE_STATUS_EVIDENCE="$TMPROOT/bad-release-status-evidence.json"
cp "$APPEND_EVIDENCE" "$BAD_RELEASE_STATUS_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["release_surface"]={"status"=>"not_git","checked"=>[],"gaps"=>[]}; File.write(p, JSON.pretty_generate(j))' "$BAD_RELEASE_STATUS_EVIDENCE"
expect_failure 'validate rejects not_git outside worktree safety release surface' "$CLI" validate --evidence "$BAD_RELEASE_STATUS_EVIDENCE" --json
BAD_TOOL_STATUS_EVIDENCE="$TMPROOT/bad-tool-status-evidence.json"
cp "$APPEND_EVIDENCE" "$BAD_TOOL_STATUS_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["tool_calls"]=[{"tool_name"=>"git status","status"=>"not_git","used_for"=>"status check"}]; File.write(p, JSON.pretty_generate(j))' "$BAD_TOOL_STATUS_EVIDENCE"
expect_failure 'validate rejects not_git outside worktree safety tool calls' "$CLI" validate --evidence "$BAD_TOOL_STATUS_EVIDENCE" --json

LEGACY_TASK="$TMPROOT/legacy-task.yaml"
ruby --disable-gems -e 'File.write(ARGV[0], "schema_version: orbit-task-v1\nproject: project\ntarget_role: lead\ntask_type: implementation\nevidence_requirements: []\n")' "$LEGACY_TASK"
"$CLI" validate --task "$LEGACY_TASK" --json >"$TMPROOT/legacy-task-validate.json"
json_assert 'validate warns on legacy task missing runtime guardrails' "$TMPROOT/legacy-task-validate.json" 'j["valid"] == true && j["warnings"].any? { |w| w["source"] == "task_file.source_contract" } && j["warnings"].any? { |w| w["source"] == "task_file.traceability" }'

BAD_RUNTIME_TASK="$TMPROOT/bad-runtime-task.yaml"
cp "$TASK" "$BAD_RUNTIME_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["worktree_safety"]["require_status_check"]="yes"; File.write(p, YAML.dump(y))' "$BAD_RUNTIME_TASK"
expect_failure 'validate rejects invalid runtime guardrail task fields' "$CLI" validate --task "$BAD_RUNTIME_TASK" --evidence "$APPEND_EVIDENCE" --json

BAD_RUNTIME_EVIDENCE="$TMPROOT/bad-runtime-evidence.json"
cp "$APPEND_EVIDENCE" "$BAD_RUNTIME_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["regression_guard"]={"status"=>"present","evidence"=>""}; File.write(p, JSON.pretty_generate(j))' "$BAD_RUNTIME_EVIDENCE"
expect_failure 'validate rejects invalid runtime guardrail evidence fields' "$CLI" validate --task "$TASK" --evidence "$BAD_RUNTIME_EVIDENCE" --json

REVIEW_JUDGMENT_EVIDENCE="$TMPROOT/review-judgment-evidence.json"
cp "$APPEND_EVIDENCE" "$REVIEW_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["review_judgment"]={"verdict"=>"pass","quality_outcome"=>{"verdict"=>"pass","reasoning"=>"outcome satisfied"},"findings"=>[],"residual_risk"=>{"accepted"=>true,"reason"=>"no known blocking risk"}}; File.write(p, JSON.pretty_generate(j))' "$REVIEW_JUDGMENT_EVIDENCE"
"$CLI" evidence attach-rule --file "$REVIEW_JUDGMENT_EVIDENCE" --rule-resolution "$TMPROOT/current-rule-resolution.json" >"$TMPROOT/evidence-attach-rule.out" 2>"$TMPROOT/evidence-attach-rule.err"
test ! -s "$TMPROOT/evidence-attach-rule.err"
json_assert 'evidence attach-rule records rule resolution summary' "$REVIEW_JUDGMENT_EVIDENCE" 'j["rule_resolution"]["file"] == File.expand_path(ARGV[2]) && j["rule_resolution"]["valid"] == true && j["rule_resolution"]["resolved_role"] == "reviewer" && j["rule_resolution"]["conflict_count"] == 0' "$TMPROOT/current-rule-resolution.json"
CONCURRENT_EVIDENCE="$TMPROOT/concurrent-evidence.json"
"$CLI" evidence init --output "$CONCURRENT_EVIDENCE" >/dev/null
cat >"$TMPROOT/concurrent-review-submit.yaml" <<'YAML'
kind: review
verdict: pass
summary: Concurrent review submit passed.
source_message_id: herdr:reviewer:concurrent
quality_outcome_verdict: pass
quality_outcome_reasoning: Concurrent review record is complete.
findings: []
coverage:
  - concurrent review record retained
artifacts:
  - tests/orbit_test.sh
YAML
append_review_quality_fields "$TMPROOT/concurrent-review-submit.yaml"
cat >"$TMPROOT/concurrent-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Concurrent test submit passed.
source_message_id: herdr:tester:concurrent
test_level: repo_regression
findings: []
coverage:
  - concurrent test record retained
artifacts:
  - tests/orbit_test.sh
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: concurrent_test
      verdict: pass
      evidence: Concurrent test record retained.
  not_applicable: []
confirmed:
  - Concurrent test record retained.
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
  resource_usage: shell processes
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: stable test artifact
runtime_binding:
  build:
    git_head: "fixture-build"
  browser:
    name: "fixture-browser"
    owner: "tester"
YAML
"$CLI" evidence attach-rule --file "$CONCURRENT_EVIDENCE" --rule-resolution "$TMPROOT/current-rule-resolution.json" >/dev/null &
"$CLI" evidence add --file "$CONCURRENT_EVIDENCE" --kind command --status pass --summary "concurrent command retained" >/dev/null &
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/concurrent-review-submit.yaml" --json >/dev/null &
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/concurrent-test-submit.yaml" --json >/dev/null &
wait
json_assert 'concurrent evidence writers preserve rules and all records' "$CONCURRENT_EVIDENCE" 'j["rule_resolution"]["file"] == File.expand_path(ARGV[2]) && j["records"].any? { |r| r["kind"] == "command" && r["summary"] == "concurrent command retained" } && j["records"].any? { |r| r["kind"] == "review" && r["source_message_id"] == "herdr:reviewer:concurrent" } && j["records"].any? { |r| r["kind"] == "test" && r["source_message_id"] == "herdr:tester:concurrent" }' "$TMPROOT/current-rule-resolution.json"
"$CLI" validate --task "$TASK" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/valid-review-judgment.json"
json_assert 'validate accepts structured review judgment' "$TMPROOT/valid-review-judgment.json" 'j["valid"] == true'
BAD_RULE_RESOLUTION_EVIDENCE="$TMPROOT/bad-rule-resolution-evidence.json"
cp "$REVIEW_JUDGMENT_EVIDENCE" "$BAD_RULE_RESOLUTION_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["rule_resolution"]["file"]=File.expand_path(ARGV[1]); File.write(p, JSON.pretty_generate(j))' "$BAD_RULE_RESOLUTION_EVIDENCE" "$TMPROOT/missing-rule-resolution.json"
expect_failure 'validate rejects missing attached rule resolution' "$CLI" validate --task "$TASK" --evidence "$BAD_RULE_RESOLUTION_EVIDENCE" --json
ORBIT_ROLE=reviewer "$CLI" rules resolve --json --output "$TMPROOT/no-task-rule-resolution.json" >/dev/null
NO_TASK_RULE_EVIDENCE="$TMPROOT/no-task-rule-evidence.json"
cp "$REVIEW_JUDGMENT_EVIDENCE" "$NO_TASK_RULE_EVIDENCE"
"$CLI" evidence attach-rule --file "$NO_TASK_RULE_EVIDENCE" --rule-resolution "$TMPROOT/no-task-rule-resolution.json" >/dev/null
expect_failure 'validate rejects task evidence with no-task rule resolution' "$CLI" validate --task "$TASK" --evidence "$NO_TASK_RULE_EVIDENCE" --json
BAD_REVIEW_JUDGMENT_EVIDENCE="$TMPROOT/bad-review-judgment-evidence.json"
cp "$REVIEW_JUDGMENT_EVIDENCE" "$BAD_REVIEW_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["review_judgment"]["quality_outcome"].delete("reasoning"); File.write(p, JSON.pretty_generate(j))' "$BAD_REVIEW_JUDGMENT_EVIDENCE"
expect_failure 'validate rejects incomplete review judgment' "$CLI" validate --task "$TASK" --evidence "$BAD_REVIEW_JUDGMENT_EVIDENCE" --json

LATEST_FAIL_EVIDENCE="$TMPROOT/latest-fail-evidence.json"
"$CLI" evidence init --output "$LATEST_FAIL_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/latest-fail-review-pass.yaml" "Review passed first." "herdr:reviewer:latest-fail-pass"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$LATEST_FAIL_EVIDENCE" --report "$TMPROOT/latest-fail-review-pass.yaml" --json >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$LATEST_FAIL_EVIDENCE" --kind review --status fail --summary "review failed latest" >/dev/null
expect_failure 'validate uses latest review fail verdict' "$CLI" validate --task "$TASK" --evidence "$LATEST_FAIL_EVIDENCE" --json

LATEST_PASS_EVIDENCE="$TMPROOT/latest-pass-evidence.json"
"$CLI" evidence init --output "$LATEST_PASS_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$LATEST_PASS_EVIDENCE" --kind review --status fail --summary "review failed first" >/dev/null
write_review_pass_report "$TMPROOT/latest-pass-review-pass.yaml" "Review passed latest." "herdr:reviewer:latest-pass"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$LATEST_PASS_EVIDENCE" --report "$TMPROOT/latest-pass-review-pass.yaml" --json >/dev/null
"$CLI" validate --task "$TASK" --evidence "$LATEST_PASS_EVIDENCE" --json >"$TMPROOT/latest-pass-validate.json"
json_assert 'validate uses latest review pass verdict' "$TMPROOT/latest-pass-validate.json" 'j["valid"] == true'

PARTIAL_EVIDENCE="$TMPROOT/partial-evidence.json"
"$CLI" evidence init --output "$PARTIAL_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$PARTIAL_EVIDENCE" --kind review --status partial --summary "review partially passed" >/dev/null
expect_failure 'validate rejects partial verdict for done gate' "$CLI" validate --task "$TASK" --evidence "$PARTIAL_EVIDENCE" --json

INVALID_ONLY_EVIDENCE="$TMPROOT/invalid-only-evidence.json"
"$CLI" evidence init --output "$INVALID_ONLY_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$INVALID_ONLY_EVIDENCE" --kind review --status invalid --summary "invalid review evidence" >/dev/null
expect_failure 'validate ignores invalid-only verdict' "$CLI" validate --task "$TASK" --evidence "$INVALID_ONLY_EVIDENCE" --json

INVALID_LATEST_EVIDENCE="$TMPROOT/invalid-latest-evidence.json"
"$CLI" evidence init --output "$INVALID_LATEST_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/invalid-latest-review-pass.yaml" "Review passed before invalid." "herdr:reviewer:invalid-latest-pass"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$INVALID_LATEST_EVIDENCE" --report "$TMPROOT/invalid-latest-review-pass.yaml" --json >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$INVALID_LATEST_EVIDENCE" --kind review --status invalid --summary "invalid latest ignored" >/dev/null
"$CLI" validate --task "$TASK" --evidence "$INVALID_LATEST_EVIDENCE" --json >"$TMPROOT/invalid-latest-validate.json"
json_assert 'validate ignores invalid latest verdict' "$TMPROOT/invalid-latest-validate.json" 'j["valid"] == true'

TEST_ONLY_EVIDENCE="$TMPROOT/test-only-evidence.json"
"$CLI" evidence init --output "$TEST_ONLY_EVIDENCE" >/dev/null
write_test_pass_report "$TMPROOT/test-only-pass.yaml" "Test passed only." "herdr:tester:test-only"
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$TEST_ONLY_EVIDENCE" --report "$TMPROOT/test-only-pass.yaml" --json >/dev/null
expect_failure 'validate review task rejects test-only evidence' "$CLI" validate --task "$TASK" --evidence "$TEST_ONLY_EVIDENCE" --json

BAD_TIME_EVIDENCE="$TMPROOT/bad-time-evidence.json"
"$CLI" evidence init --output "$BAD_TIME_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/bad-time-review-pass.yaml" "Bad time evidence." "herdr:reviewer:bad-time"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$BAD_TIME_EVIDENCE" --report "$TMPROOT/bad-time-review-pass.yaml" --json >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"][0]["created_at"]="not-a-time"; File.write(p, JSON.pretty_generate(j))' "$BAD_TIME_EVIDENCE"
expect_failure 'validate fails unsortable evidence time' "$CLI" validate --task "$TASK" --evidence "$BAD_TIME_EVIDENCE" --json

expect_failure 'state start rejects owner role conflict' env ORBIT_ROLE=lead "$CLI" state start --task "$TASK" --owner-role reviewer
ORBIT_ROLE=lead "$CLI" state start --task "$TASK" >"$TMPROOT/state-start.out" 2>"$TMPROOT/state-start.err"
test ! -s "$TMPROOT/state-start.err"
"$CLI" state show --json >"$TMPROOT/state-working.json"
json_assert 'state start infers owner and binds task' "$TMPROOT/state-working.json" 'j["phase"] == "working" && j["owner_role"] == "lead" && j["current_task"] == File.expand_path(ARGV[2]) && j["history"].last["event"] == "start"' "$TASK"
DESIGN_STATE="$TMPROOT/design-loop-state.yaml"
cp .orbit/loop-state.yaml "$DESIGN_STATE"
ORBIT_INSTANCE=lead "$CLI" state start --state "$DESIGN_STATE" --task "$DESIGN_TASK" --owner-role lead >/dev/null
yaml_assert 'state start enters drafting for design task' "$DESIGN_STATE" 'j["phase"] == "drafting" && j["history"].last["to"] == "drafting"'
DESIGN_GATE_EVIDENCE="$TMPROOT/design-gate-evidence.json"
"$CLI" evidence init --output "$DESIGN_GATE_EVIDENCE" >/dev/null
cat >"$TMPROOT/design-review-pass.yaml" <<'YAML'
kind: review
verdict: pass
summary: Design review passed for coding readiness.
source_message_id: design-review-pass
quality_outcome_verdict: pass
quality_outcome_reasoning: Reviewed design artifact is ready for user confirmation.
findings: []
coverage:
  - Design artifact was reviewed before coding.
artifacts:
  - docs/open/design.md
YAML
append_review_quality_fields "$TMPROOT/design-review-pass.yaml"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$DESIGN_GATE_EVIDENCE" --report "$TMPROOT/design-review-pass.yaml" --json >/dev/null
expect_failure 'state transition blocks design coding_ready before user_confirmed phase' "$CLI" state transition --state "$DESIGN_STATE" --to coding_ready --evidence "$DESIGN_GATE_EVIDENCE"
"$CLI" state transition --state "$DESIGN_STATE" --to review_requested >/dev/null
expect_failure 'state transition blocks user_confirmed without user confirmation evidence' "$CLI" state transition --state "$DESIGN_STATE" --to user_confirmed --evidence "$DESIGN_GATE_EVIDENCE"
"$CLI" evidence add --file "$DESIGN_GATE_EVIDENCE" --kind implementation --status pass --summary "user_confirmed: user approved reviewed design artifact for coding." >/dev/null
"$CLI" state transition --state "$DESIGN_STATE" --to user_confirmed --evidence "$DESIGN_GATE_EVIDENCE" >/dev/null
"$CLI" state transition --state "$DESIGN_STATE" --to coding_ready --evidence "$DESIGN_GATE_EVIDENCE" >/dev/null
yaml_assert 'state transition reaches coding_ready only after review and user confirmation' "$DESIGN_STATE" 'j["phase"] == "coding_ready" && j["history"].last["to"] == "coding_ready" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2])' "$DESIGN_GATE_EVIDENCE"
expect_failure 'state transition to blocked requires reason' "$CLI" state transition --to blocked
cp .orbit/loop-state.yaml "$TMPROOT/block-state.yaml"
"$CLI" state transition --state "$TMPROOT/block-state.yaml" --to blocked --reason "needs input" >/dev/null
yaml_assert 'state transition to blocked records reason' "$TMPROOT/block-state.yaml" 'j["phase"] == "blocked" && j["status"].include?("needs input") && j["history"].last["reason"] == "needs input"'
expect_failure 'state transition blocks working to done without evidence' "$CLI" state transition --to done
"$CLI" state transition --to in_review >"$TMPROOT/state-in-review.out" 2>"$TMPROOT/state-in-review.err"
test ! -s "$TMPROOT/state-in-review.err"
"$CLI" state show --json >"$TMPROOT/state-in-review.json"
json_assert 'state transition working to in_review passes' "$TMPROOT/state-in-review.json" 'j["phase"] == "in_review" && j["history"].last["from"] == "working" && j["history"].last["to"] == "in_review"'
FAIL_EVIDENCE="$TMPROOT/fail-evidence.json"
"$CLI" evidence init --output "$FAIL_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence add --file "$FAIL_EVIDENCE" --kind review --status fail --summary "review failed" >/dev/null
expect_failure 'state transition blocks done on fail evidence' "$CLI" state transition --to done --evidence "$FAIL_EVIDENCE"
"$CLI" state transition --to done --evidence "$REVIEW_JUDGMENT_EVIDENCE" >"$TMPROOT/state-done.out" 2>"$TMPROOT/state-done.err"
test ! -s "$TMPROOT/state-done.err"
"$CLI" state show --json >"$TMPROOT/state-done.json"
json_assert 'state transition to done records evidence' "$TMPROOT/state-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2]) && j["history"].last["to"] == "done"' "$REVIEW_JUDGMENT_EVIDENCE"
cp .orbit/loop-state.yaml "$TMPROOT/review-done-state.yaml"

IMPL_TASK="$TMPROOT/implementation-task.yaml"
"$CLI" new-task --target-role lead --task-type implementation --output "$IMPL_TASK" >/dev/null
yaml_assert 'new-task adds implementation review/test gates' "$IMPL_TASK" 'j["gates"].is_a?(Array) && j["gates"].any? { |g| g["kind"] == "review" && g["roles"].include?("reviewer") } && j["gates"].any? { |g| g["kind"] == "test" && g["roles"].include?("tester") }'
yaml_assert 'new-task marks implementation test gate level' "$IMPL_TASK" 'j["test_level"] == "repo_regression"'
ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$IMPL_TASK" --json >"$TMPROOT/implementation-reviewer-rules.json"
json_assert 'rules resolve allows reviewer gate role on implementation task' "$TMPROOT/implementation-reviewer-rules.json" 'j["valid"] == true && j["resolved_role"] == "reviewer" && j["role_sources"]["task_file.target_role"] == "lead"'
BAD_GATE_TASK="$TMPROOT/bad-gate-task.yaml"
cp "$IMPL_TASK" "$BAD_GATE_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"deploy","roles"=>["reviewer"],"required"=>true}]; File.write(p, YAML.dump(y))' "$BAD_GATE_TASK"
expect_failure 'rules resolve rejects invalid gate kind role bypass' env ORBIT_INSTANCE=reviewer "$CLI" rules resolve --task "$BAD_GATE_TASK" --json
IMPL_EVIDENCE="$TMPROOT/implementation-evidence.json"
"$CLI" evidence init --output "$IMPL_EVIDENCE" >/dev/null
"$CLI" evidence add --file "$IMPL_EVIDENCE" --kind implementation --status pass --summary "implementation evidence passed" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["worktree_safety"]={"status"=>"not_git","reason"=>"generated test app is not a git repository","unexpected_changes"=>[]}; File.write(p, JSON.pretty_generate(j))' "$IMPL_EVIDENCE"
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$IMPL_TASK" >/dev/null
"$CLI" state progress --message "implementation complete, waiting for gates" --evidence "$IMPL_EVIDENCE" >"$TMPROOT/state-progress.out" 2>"$TMPROOT/state-progress.err"
test ! -s "$TMPROOT/state-progress.err"
"$CLI" state show --json >"$TMPROOT/state-progress.json"
json_assert 'state progress records heartbeat without phase change' "$TMPROOT/state-progress.json" 'j["phase"] == "working" && j["status"].include?("implementation complete") && j["history"].last["event"] == "progress" && j["history"].last["evidence"] == File.expand_path(ARGV[2]) && !j["artifacts"].key?("evidence_file")' "$IMPL_EVIDENCE"
CONCURRENT_STATE="$TMPROOT/concurrent-loop-state.yaml"
cp .orbit/loop-state.yaml "$CONCURRENT_STATE"
"$CLI" state progress --state "$CONCURRENT_STATE" --message "concurrent progress one" >/dev/null &
"$CLI" state progress --state "$CONCURRENT_STATE" --message "concurrent progress two" >/dev/null &
wait
yaml_assert 'concurrent state progress preserves both history entries' "$CONCURRENT_STATE" 'messages = j["history"].select { |h| h["event"] == "progress" }.map { |h| h["message"] }; messages.include?("concurrent progress one") && messages.include?("concurrent progress two")'
expect_failure 'state transition blocks done until implementation gates pass' "$CLI" state transition --to done --evidence "$IMPL_EVIDENCE"
write_review_pass_report "$TMPROOT/implementation-review-pass.yaml" "Review gate passed." "herdr:reviewer:implementation-gate"
ORBIT_INSTANCE=reviewer "$CLI" evidence submit --file "$IMPL_EVIDENCE" --report "$TMPROOT/implementation-review-pass.yaml" --json >/dev/null
cat >"$TMPROOT/implementation-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Implementation test gate passed with environment lifecycle.
source_message_id: herdr:tester:implementation-gate
test_level: repo_regression
findings: []
coverage:
  - implementation gate success path
artifacts:
  - .orbit/test-artifacts/implementation-gate.log
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: implementation_gate_test
      verdict: pass
      evidence: Implementation gate success path covered.
  not_applicable: []
confirmed:
  - Implementation gate success path covered.
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
runtime_binding:
  build:
    git_head: "fixture-build"
  browser:
    name: "fixture-browser"
    owner: "tester"
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$IMPL_EVIDENCE" --report "$TMPROOT/implementation-test-submit.yaml" --json >/dev/null
"$CLI" state transition --to done --evidence "$IMPL_EVIDENCE" >"$TMPROOT/implementation-done.out" 2>"$TMPROOT/implementation-done.err"
test ! -s "$TMPROOT/implementation-done.err"
"$CLI" state show --json >"$TMPROOT/implementation-done.json"
json_assert 'state transition allows done with implementation pass evidence' "$TMPROOT/implementation-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2])' "$IMPL_EVIDENCE"
"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-valid.json" 2>"$TMPROOT/audit-valid.err"
test ! -s "$TMPROOT/audit-valid.err"
json_assert 'audit passes done state with matching evidence' "$TMPROOT/audit-valid.json" 'j["schema_version"] == "orbit-audit-v1" && j["trust_level"]["mode"] == "audit_only" && j["done_ready"] == true && j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == false && j["blocking_findings"].empty? && j["warnings"].any? { |e| e["source"] == "state_file.artifacts.handoff_packet" && e["remediation"].is_a?(String) } && j["issues"].length == j["blocking_findings"].length + j["warnings"].length && j["validation"]["valid"] == true && j["evidence_summary"]["aggregate_verdict"]["gates"]["review"]["evidence_level"] == "outcome_quality" && j["evidence_summary"]["aggregate_verdict"]["gates"]["test"]["evidence_level"] == "real_path_test"'
"$CLI" handoff --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --output "$TMPROOT/implementation-handoff.json" --record-state --json >"$TMPROOT/implementation-handoff.stdout"
json_assert 'handoff can write artifact and record it in state' "$TMPROOT/implementation-handoff.json" 'j["schema_version"] == "orbit-handoff-v1" && j["blocking_errors"].empty? && j["gate_summary"]["ready"] == true && j["gate_summary"]["evidence_levels"]["review"] == "outcome_quality" && j["gate_summary"]["evidence_levels"]["test"] == "real_path_test" && j["judgment_summary"]["review_judgment"]["present"] == true && j["judgment_summary"]["review_judgment"]["source"] == "latest_evidence_record" && j["judgment_summary"]["review_judgment"]["evidence_level"] == "outcome_quality" && j["judgment_summary"]["review_judgment"]["rule_application_summary"]["applied_checks_count"] == 1 && j["judgment_summary"]["test_judgment"]["present"] == true && j["judgment_summary"]["test_judgment"]["evidence_level"] == "real_path_test" && j["latest_gate_verdicts"]["review"]["status"] == "pass" && j["latest_gate_verdicts"]["review"]["evidence_boundary_summary"]["confirmed_count"] == 1 && j["latest_gate_verdicts"]["test"]["status"] == "pass" && j["latest_gate_verdicts"]["test"]["rule_application_summary"]["applied_checks_count"] == 1 && j["closure_checklist"].is_a?(Array) && j["closure_checklist"].any? { |c| c["item"] == "latest_test_verdict" } && j["known_gaps"].is_a?(Array) && j["readable_summary"]["next_action"] == "none" && j["worktree_safety_summary"]["status"] == "not_git"'
yaml_assert 'handoff record-state stores artifact path' .orbit/loop-state.yaml 'j["artifacts"]["handoff_packet"] == File.expand_path(ARGV[2]) && j["history"].last["event"] == "handoff"' "$TMPROOT/implementation-handoff.json"
"$CLI" compact-evidence --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --handoff "$TMPROOT/implementation-handoff.json" --output "$TMPROOT/durable-summary.json" --json >"$TMPROOT/durable-summary.stdout"
cmp "$TMPROOT/durable-summary.json" "$TMPROOT/durable-summary.stdout"
json_assert 'compact-evidence writes durable summary with hashes and refs' "$TMPROOT/durable-summary.json" 'j["schema_version"] == "orbit-durable-evidence-summary-v1" && j["inputs"]["task"]["sha256"].is_a?(String) && j["inputs"]["evidence"]["sha256"].is_a?(String) && j["inputs"]["handoff"]["sha256"].is_a?(String) && j["evidence_summary"]["records"]["count"] >= 3 && j["evidence_summary"]["aggregate_verdict"]["mode"] == "aggregate" && j["handoff_summary"]["current_phase"] == "done" && j["handoff_summary"]["latest_gate_verdicts"]["test"]["status"] == "pass" && j["handoff_summary"]["closure_checklist"].is_a?(Array) && j["handoff_summary"]["known_gaps"].is_a?(Array) && j["handoff_summary"]["readable_summary"]["next_action"] == "none" && j["transient_artifacts"]["policy"] == "referenced_by_path_and_hash" && j["transient_artifacts"]["large_artifacts_not_embedded"] == true'
"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-release.json"
json_assert 'audit trusts release when handoff artifact is recorded' "$TMPROOT/audit-release.json" 'j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == true && j["warnings"].empty?'
RISKY_EVIDENCE="$TMPROOT/risky-evidence.json"
cp "$IMPL_EVIDENCE" "$RISKY_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["regression_guard"]={"status"=>"absent","evidence"=>""}; j["release_surface"]={"status"=>"partial","checked"=>["package"],"gaps"=>["release asset not checked"]}; File.write(p, JSON.pretty_generate(j))' "$RISKY_EVIDENCE"
RISKY_STATE="$TMPROOT/risky-state.yaml"
cp .orbit/loop-state.yaml "$RISKY_STATE"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["artifacts"]["evidence_file"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(y))' "$RISKY_STATE" "$RISKY_EVIDENCE"
"$CLI" audit --task "$IMPL_TASK" --evidence "$RISKY_EVIDENCE" --state "$RISKY_STATE" --json >"$TMPROOT/audit-risky-evidence.json"
json_assert 'audit lowers release trust on runtime guardrail warnings' "$TMPROOT/audit-risky-evidence.json" 'j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == false && j["warnings"].any? { |w| w["source"] == "evidence_file.regression_guard" } && j["warnings"].any? { |w| w["source"] == "evidence_file.release_surface.gaps" }'
expect_failure 'handoff record-state requires output' "$CLI" handoff --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --record-state --json
cp .orbit/loop-state.yaml "$TMPROOT/audit-drift-state.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["current_task"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(y))' "$TMPROOT/audit-drift-state.yaml" "$TASK"
if "$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state "$TMPROOT/audit-drift-state.yaml" --json >"$TMPROOT/audit-drift.json"; then
  printf 'FAIL audit drift: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit reports state task drift' "$TMPROOT/audit-drift.json" 'j["blocking_findings"].any? { |e| e["source"] == "state_file.current_task" && e["severity"] == "high" && e["remediation"].include?("orbit state start") } && j["trusted_for_handoff"] == false && j["trusted_for_done"] == false && j["trusted_for_release"] == false && j["done_ready"] == false'
expect_failure 'audit rejects missing evidence option value' "$CLI" audit --task "$IMPL_TASK" --evidence --state .orbit/loop-state.yaml --json

"$CLI" validate --task "$TASK" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --state "$TMPROOT/review-done-state.yaml" --json >"$TMPROOT/valid-task-evidence-state.json"
json_assert 'validate includes loop state and trust level' "$TMPROOT/valid-task-evidence-state.json" 'j["valid"] == true && j["checked"].include?("state") && j["trust_level"]["mode"] == "audit_only"'
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/handoff-valid.json" 2>"$TMPROOT/handoff-valid.err"
test ! -s "$TMPROOT/handoff-valid.err"
json_assert 'handoff outputs valid packet' "$TMPROOT/handoff-valid.json" 'j["schema_version"] == "orbit-handoff-v1" && j["target_role"] == "reviewer" && j["current_phase"] == "done" && j["required_action"] == "none" && j["next_action"] == "none" && j["blocking_errors"].empty? && j["validation_summary"]["valid"] == true && j["audit_summary"]["done_ready"] == true && j["tools_summary"]["preferred_transport"].is_a?(String) && j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["payload"]["required_action"] == "none" && j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" } && j["rule_packs"].any? { |p| p["category"] == "audit" && p["id"] == "orbit-drift" } && j["rule_resolution_summary"]["present"] == true && j["rule_resolution_summary"]["valid"] == true && j["rule_resolution_summary"]["resolved_role"] == "reviewer" && j["judgment_summary"]["review_judgment"]["present"] == true && j["closure_checklist"].is_a?(Array) && j["readable_summary"]["next_action"] == "none" && j["evidence_summary"]["records"] >= 1'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y={"schema_version"=>"orbit-tools-config-v1","transport_profiles"=>{"generic"=>{"handoff"=>{"format"=>"json","delivery"=>"manual"}},"herdr"=>{"fallback"=>"generic","handoff"=>{"format"=>"json","delivery"=>"pane.message"}}},"preference"=>{"handoff"=>"herdr"}}; File.write(p, YAML.dump(y))' .orbit/tools.yaml
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport generic --json >"$TMPROOT/handoff-generic-transport.json"
json_assert 'handoff outputs generic transport payload' "$TMPROOT/handoff-generic-transport.json" 'j["required_action"] == "none" && j["transport_profile"]["requested"] == "generic" && j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["fallback_used"] == false && j["transport_profile"]["payload"]["delivery"] == "manual"'
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport herdr --json >"$TMPROOT/handoff-herdr-transport.json"
json_assert 'handoff outputs herdr transport or generic fallback payload' "$TMPROOT/handoff-herdr-transport.json" 'j["required_action"] == "none" && j["transport_profile"]["requested"] == "herdr" && ((j["transport_profile"]["selected"] == "herdr" && j["transport_profile"]["payload"]["delivery"] == "pane.message") || (j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["fallback_used"] == true))'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y={"schema_version"=>"orbit-tools-config-v1","transport_profiles"=>{"generic"=>{"handoff"=>{"format"=>"json","delivery"=>"manual"}}}}; File.write(p, YAML.dump(y))' .orbit/tools.yaml
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport herdr --json >"$TMPROOT/handoff-missing-profile-fallback.json"
json_assert 'handoff falls back when transport profile is missing' "$TMPROOT/handoff-missing-profile-fallback.json" 'j["required_action"] == "none" && j["transport_profile"]["requested"] == "herdr" && j["transport_profile"]["selected"] == "generic" && j["transport_profile"]["fallback_used"] == true && j["transport_profile"]["reason"].include?("not configured")'
expect_failure 'handoff rejects missing transport option value' "$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --transport --json
INVALID_HANDOFF_TASK="$TMPROOT/invalid-handoff-task.yaml"
cp "$TASK" "$INVALID_HANDOFF_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("target_role"); File.write(p, YAML.dump(y))' "$INVALID_HANDOFF_TASK"
if "$CLI" handoff --task "$INVALID_HANDOFF_TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/handoff-invalid.json"; then
  printf 'FAIL handoff invalid task: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'handoff invalid task reports blocking errors' "$TMPROOT/handoff-invalid.json" 'j["blocking_errors"].any? { |e| e["source"] == "task_file.target_role" } && j["required_action"] == "resolve_blocking_errors"'
expect_failure 'handoff fails role conflict' env ORBIT_INSTANCE=tester "$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json

EQ_TASK="$TMPROOT/eq-task.yaml"
"$CLI" new-task --target-role=tester --task-type=implementation_test --project=explicit --output="$EQ_TASK" >/dev/null
yaml_assert 'new-task supports equals syntax and explicit project' "$EQ_TASK" 'j["project"] == "explicit" && j["target_role"] == "tester" && j["task_type"] == "implementation_test" && j["rule_packs"].any? { |p| p["category"] == "test" && p["id"] == "brooks-test" }'
expect_failure 'validate test task rejects review-only appended evidence' "$CLI" validate --task "$EQ_TASK" --evidence "$APPEND_EVIDENCE" --json
cat >"$TMPROOT/eq-test-submit.yaml" <<'YAML'
kind: test
verdict: pass
summary: Explicit test task passed with environment lifecycle.
source_message_id: herdr:tester:eq-test-pass
test_level: repo_regression
findings: []
coverage:
  - explicit task test evidence path
artifacts:
  - .orbit/test-artifacts/eq-test.log
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: explicit_task_test
      verdict: pass
      evidence: Explicit task test evidence path covered.
  not_applicable: []
confirmed:
  - Explicit task test evidence path covered.
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
runtime_binding:
  build:
    git_head: "fixture-build"
  browser:
    name: "fixture-browser"
    owner: "tester"
YAML
ORBIT_INSTANCE=tester "$CLI" evidence submit --file "$APPEND_EVIDENCE" --report "$TMPROOT/eq-test-submit.yaml" --json >"$TMPROOT/eq-test-submit.json"
"$CLI" validate --task "$EQ_TASK" --evidence "$APPEND_EVIDENCE" --json >"$TMPROOT/valid-test-append-evidence.json"
json_assert 'validate reads appended test evidence' "$TMPROOT/valid-test-append-evidence.json" 'j["valid"] == true'
TEST_JUDGMENT_EVIDENCE="$TMPROOT/test-judgment-evidence.json"
cp "$APPEND_EVIDENCE" "$TEST_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["test_judgment"]={"verdict"=>"pass","environment"=>"local shell","scenarios"=>[{"name"=>"happy path","result"=>"pass","evidence"=>"command output retained"}],"coverage_gap"=>[]}; File.write(p, JSON.pretty_generate(j))' "$TEST_JUDGMENT_EVIDENCE"
"$CLI" validate --task "$EQ_TASK" --evidence "$TEST_JUDGMENT_EVIDENCE" --json >"$TMPROOT/valid-test-judgment.json"
json_assert 'validate accepts structured test judgment' "$TMPROOT/valid-test-judgment.json" 'j["valid"] == true'
BAD_TEST_JUDGMENT_EVIDENCE="$TMPROOT/bad-test-judgment-evidence.json"
cp "$TEST_JUDGMENT_EVIDENCE" "$BAD_TEST_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["test_judgment"].delete("scenarios"); File.write(p, JSON.pretty_generate(j))' "$BAD_TEST_JUDGMENT_EVIDENCE"
expect_failure 'validate rejects incomplete test judgment' "$CLI" validate --task "$EQ_TASK" --evidence "$BAD_TEST_JUDGMENT_EVIDENCE" --json
"$CLI" init --force >/dev/null
ORBIT_INSTANCE=lead "$CLI" state start --task "$EQ_TASK" >/dev/null
"$CLI" state show --json >"$TMPROOT/state-owner-instance.json"
json_assert 'state start infers owner from instance' "$TMPROOT/state-owner-instance.json" 'j["phase"] == "working" && j["owner_role"] == "lead"'
expect_failure 'new-task requires output' "$CLI" new-task --target-role reviewer --task-type review
expect_failure 'new-task rejects missing target-role value' "$CLI" new-task --target-role --task-type review --output "$TMPROOT/bad.yaml"

MISMATCH_TASK="$TMPROOT/task-mismatch.yaml"
ruby --disable-gems -e 'File.write(ARGV[0], "schema_version: orbit-task-v1\nproject: project\ntarget_role: tester\n")' "$MISMATCH_TASK"
expect_failure 'whoami fails on task target mismatch' env ORBIT_INSTANCE=reviewer "$CLI" whoami --json --task "$MISMATCH_TASK"
expect_failure 'whoami fails on missing task file conflict' env ORBIT_INSTANCE=reviewer "$CLI" whoami --json --task "$TMPROOT/missing.yaml"


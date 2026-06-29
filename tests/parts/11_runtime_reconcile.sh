# ---------------------------------------------------------------------------
# Slice 8: runtime-reconcile-and-env-fingerprint acceptance tests
# ---------------------------------------------------------------------------

S11_TASK="$TMPROOT/s11-task.yaml"
"$CLI" new-task --target-role reviewer --task-type implementation_review --output "$S11_TASK" >/dev/null

S11_TEST_TASK="$TMPROOT/s11-test-task.yaml"
"$CLI" new-task --target-role tester --task-type implementation --output "$S11_TEST_TASK" >/dev/null

# ---- Group 1: evidence submit with runtime_binding (singular, new schema) ----

cat >"$TMPROOT/s11-review-report.yaml" <<'YAML'
kind: review
verdict: pass
summary: Slice 8 runtime_binding schema test.
source_message_id: slice8:review:runtime
quality_outcome_verdict: pass
quality_outcome_reasoning: Runtime binding fields validated.
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: runtime_binding_check
      verdict: pass
      evidence: runtime_binding fields present and schema-valid.
  not_applicable: []
confirmed:
  - runtime_binding written to evidence record.
assumed: []
missing: []
residual_risk: "No residual risk: runtime_binding is additive metadata."
counterexample_cases:
  - invalid failure_class is rejected; real_path_test without binding is rejected.
implementation_readiness_verdict: not_checked
findings: []
coverage:
  - runtime_binding propagation verified
artifacts: []
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: runtime_binding fields present in record
  - id: counterexamples
    verdict: pass
    evidence: no counterexamples identified
  - id: evidence_sufficiency
    verdict: pass
    evidence: runtime_binding schema verified
  - id: residual_risk
    verdict: pass
    evidence: no residual risk
runtime_binding:
  model_service:
    family: openai
    alias: gpt-4o
  build:
    git_head: "abc1234"
    artifact_hash: "def5678"
    artifact_paths:
      - tests/orbit_test.sh
YAML

S11_EVIDENCE="$TMPROOT/s11-evidence.json"
"$CLI" evidence init --output "$S11_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S11_EVIDENCE" \
  --report "$TMPROOT/s11-review-report.yaml" \
  --task "$S11_TASK" \
  --json >"$TMPROOT/s11-submit.json"

json_assert 'evidence submit with runtime_binding is accepted' "$TMPROOT/s11-submit.json" \
  'j["record"].key?("runtime_binding")'
json_assert 'runtime_binding.model_service.family written to record' "$TMPROOT/s11-submit.json" \
  'j["record"]["runtime_binding"]["model_service"]["family"] == "openai"'
json_assert 'runtime_binding.build.git_head written to record' "$TMPROOT/s11-submit.json" \
  'j["record"]["runtime_binding"]["build"]["git_head"] == "abc1234"'
json_assert 'runtime_binding.build.artifact_paths is an array' "$TMPROOT/s11-submit.json" \
  'j["record"]["runtime_binding"]["build"]["artifact_paths"].is_a?(Array)'

# ---- Group 2: failure_class validated for low/advisory (early-return bug fix) ----

cat >"$TMPROOT/s11-low-bad-fc-report.yaml" <<'YAML'
kind: review
verdict: fail
summary: Low finding with bad failure_class.
source_message_id: slice8:review:lowbadfc
quality_outcome_verdict: fail
findings:
  - severity: low
    summary: Minor style issue.
    failure_class: totally_invalid_class
coverage: []
artifacts: []
YAML

if ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
     --file "$S11_EVIDENCE" \
     --report "$TMPROOT/s11-low-bad-fc-report.yaml" \
     --task "$S11_TASK" \
     --json >/dev/null 2>/dev/null; then
  printf 'FAIL low/advisory finding invalid failure_class is rejected: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'low/advisory finding with invalid failure_class is rejected'

# ---- Group 3: real_path_test requires runtime_binding ----

cat >"$TMPROOT/s11-rpt-no-binding-report.yaml" <<'YAML'
kind: test
verdict: pass
summary: real_path_test without runtime_binding.
source_message_id: slice8:test:rpt:nobinding
test_level: repo_regression
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: real_path
      verdict: pass
      evidence: test path executed.
  not_applicable: []
confirmed:
  - test path executed
assumed: []
missing: []
residual_risk: "No residual risk."
findings: []
coverage: []
artifacts: []
test_environment:
  environment: local
  test_tab_or_pane: current
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

S11_TEST_EVIDENCE="$TMPROOT/s11-test-evidence.json"
"$CLI" evidence init --output "$S11_TEST_EVIDENCE" >/dev/null
if ORBIT_INSTANCE=tester "$CLI" evidence submit \
     --file "$S11_TEST_EVIDENCE" \
     --report "$TMPROOT/s11-rpt-no-binding-report.yaml" \
     --task "$S11_TEST_TASK" \
     --json >/dev/null 2>/dev/null; then
  printf 'FAIL real_path_test PASS without runtime_binding is rejected: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'real_path_test PASS without runtime_binding is rejected'

cat >"$TMPROOT/s11-rpt-with-binding-report.yaml" <<'YAML'
kind: test
verdict: pass
summary: real_path_test with runtime_binding.
source_message_id: slice8:test:rpt:withbinding
test_level: repo_regression
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: real_path
      verdict: pass
      evidence: test path executed.
  not_applicable: []
confirmed:
  - test path executed with recorded runtime binding
assumed: []
missing: []
residual_risk: "No residual risk."
findings: []
coverage: []
artifacts: []
test_environment:
  environment: local
  test_tab_or_pane: current
  server_owner: none
  browser_owner: none
  cleanup_hook: none
  artifact_cleanup: none
  duration: 1s
  resource_usage: low
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: ok
runtime_binding:
  build:
    git_head: "abc1234"
    artifact_hash: "def5678"
  browser:
    name: "fixture-browser"
    owner: "tester"
YAML

ORBIT_INSTANCE=tester "$CLI" evidence submit \
  --file "$S11_TEST_EVIDENCE" \
  --report "$TMPROOT/s11-rpt-with-binding-report.yaml" \
  --task "$S11_TEST_TASK" \
  --json >"$TMPROOT/s11-rpt-submit.json"
json_assert 'real_path_test PASS with runtime_binding is accepted' "$TMPROOT/s11-rpt-submit.json" \
  'j["record"]["runtime_binding"]["build"]["git_head"] == "abc1234"'

# ---- Group 4: blocker_classification top-level field ----

cat >"$TMPROOT/s11-bc-report.yaml" <<'YAML'
kind: review
verdict: blocked
summary: Blocked by missing environment.
source_message_id: slice8:review:bc
quality_outcome_verdict: blocked
findings: []
coverage: []
artifacts: []
blocker_classification:
  kind: environment_failure
  detail: "Test environment missing required service dependency."
YAML

S11_BC_EVIDENCE="$TMPROOT/s11-bc-evidence.json"
"$CLI" evidence init --output "$S11_BC_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S11_BC_EVIDENCE" \
  --report "$TMPROOT/s11-bc-report.yaml" \
  --task "$S11_TASK" \
  --json >"$TMPROOT/s11-bc-submit.json"
json_assert 'blocker_classification.kind written to record' "$TMPROOT/s11-bc-submit.json" \
  'j["record"]["blocker_classification"]["kind"] == "environment_failure"'
json_assert 'blocker_classification.detail written to record' "$TMPROOT/s11-bc-submit.json" \
  'j["record"]["blocker_classification"]["detail"].is_a?(String)'

# ---- Group 5: audit happy path with proper state (exits 0, no || true) ----

S11_STATE="$TMPROOT/s11-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "done",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TASK" "$S11_EVIDENCE" "$S11_STATE"

"$CLI" audit --task "$S11_TASK" --evidence "$S11_EVIDENCE" \
  --state "$S11_STATE" \
  --json >"$TMPROOT/s11-audit.json"
json_assert 'audit happy path exits 0 and has runtime_reconcile_summary' "$TMPROOT/s11-audit.json" \
  'j.key?("runtime_reconcile_summary")'
json_assert 'runtime_reconcile_summary.stale_artifact_paths is an array' "$TMPROOT/s11-audit.json" \
  'j["runtime_reconcile_summary"]["stale_artifact_paths"].is_a?(Array)'
json_assert 'runtime_reconcile_summary.build_identities is an array' "$TMPROOT/s11-audit.json" \
  'j["runtime_reconcile_summary"]["build_identities"].is_a?(Array)'
json_assert 'runtime_reconcile_summary.has_issues is a boolean' "$TMPROOT/s11-audit.json" \
  '[true, false].include?(j["runtime_reconcile_summary"]["has_issues"])'

# ---- Group 6: stale artifact path detection ----

S11_STALE_EVIDENCE="$TMPROOT/s11-stale-evidence.json"
"$CLI" evidence init --output "$S11_STALE_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["records"] ||= []
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"stale artifact test.",
    "created_at"=>"2026-06-29T10:00:00Z",
    "runtime_binding" => { "build" => { "artifact_paths" => ["/nonexistent/path/artifact.log"] } } }
  File.write(ARGV[0], JSON.pretty_generate(j))' "$S11_STALE_EVIDENCE"

S11_STALE_STATE="$TMPROOT/s11-stale-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TASK" "$S11_STALE_EVIDENCE" "$S11_STALE_STATE"

"$CLI" audit --task "$S11_TASK" --evidence "$S11_STALE_EVIDENCE" \
  --state "$S11_STALE_STATE" \
  --json >"$TMPROOT/s11-stale-audit.json" || true
json_assert 'stale artifact path appears in stale_artifact_paths' "$TMPROOT/s11-stale-audit.json" \
  'j["runtime_reconcile_summary"]["stale_artifact_paths"].include?("/nonexistent/path/artifact.log")'
json_assert 'stale artifact emits warning with source runtime.stale_artifacts' "$TMPROOT/s11-stale-audit.json" \
  'j["warnings"].any? { |w| w["source"] == "runtime.stale_artifacts" }'
json_assert 'has_issues true for stale artifact' "$TMPROOT/s11-stale-audit.json" \
  'j["runtime_reconcile_summary"]["has_issues"] == true'

# ---- Group 7: model drift detection ----

S11_DRIFT_EVIDENCE="$TMPROOT/s11-model-drift-evidence.json"
"$CLI" evidence init --output "$S11_DRIFT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["records"] ||= []
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"model A.",
    "created_at"=>"2026-06-29T10:00:00Z",
    "runtime_binding" => { "model_service" => { "family"=>"openai","alias"=>"gpt-4o" } } }
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"model B.",
    "created_at"=>"2026-06-29T12:00:00Z",
    "runtime_binding" => { "model_service" => { "family"=>"anthropic","alias"=>"claude-3-5-sonnet" } } }
  File.write(ARGV[0], JSON.pretty_generate(j))' "$S11_DRIFT_EVIDENCE"

S11_DRIFT_STATE="$TMPROOT/s11-drift-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TASK" "$S11_DRIFT_EVIDENCE" "$S11_DRIFT_STATE"

"$CLI" audit --task "$S11_TASK" --evidence "$S11_DRIFT_EVIDENCE" \
  --state "$S11_DRIFT_STATE" \
  --json >"$TMPROOT/s11-model-drift-audit.json" || true
json_assert 'model_drift_detected when two distinct model_service identities present' "$TMPROOT/s11-model-drift-audit.json" \
  'j["runtime_reconcile_summary"]["model_drift_detected"] == true'
json_assert 'model drift emits warning with source runtime.model_drift' "$TMPROOT/s11-model-drift-audit.json" \
  'j["warnings"].any? { |w| w["source"] == "runtime.model_drift" }'
json_assert 'model_identities count is 2 when two distinct models' "$TMPROOT/s11-model-drift-audit.json" \
  'j["runtime_reconcile_summary"]["model_identities"].size == 2'

# ---- Group 8: no model drift ----

S11_NODRIFT_EVIDENCE="$TMPROOT/s11-model-nodrift-evidence.json"
"$CLI" evidence init --output "$S11_NODRIFT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["records"] ||= []
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"same model 1.",
    "created_at"=>"2026-06-29T10:00:00Z",
    "runtime_binding" => { "model_service" => { "family"=>"openai","alias"=>"gpt-4o" } } }
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"same model 2.",
    "created_at"=>"2026-06-29T12:00:00Z",
    "runtime_binding" => { "model_service" => { "family"=>"openai","alias"=>"gpt-4o" } } }
  File.write(ARGV[0], JSON.pretty_generate(j))' "$S11_NODRIFT_EVIDENCE"

S11_NODRIFT_STATE="$TMPROOT/s11-nodrift-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TASK" "$S11_NODRIFT_EVIDENCE" "$S11_NODRIFT_STATE"

"$CLI" audit --task "$S11_TASK" --evidence "$S11_NODRIFT_EVIDENCE" \
  --state "$S11_NODRIFT_STATE" \
  --json >"$TMPROOT/s11-model-nodrift-audit.json" || true
json_assert 'model_drift_detected is false when same model_service in all records' "$TMPROOT/s11-model-nodrift-audit.json" \
  'j["runtime_reconcile_summary"]["model_drift_detected"] == false'

# ---- Group 9: build drift detection ----

S11_BUILD_DRIFT_EVIDENCE="$TMPROOT/s11-build-drift-evidence.json"
"$CLI" evidence init --output "$S11_BUILD_DRIFT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["records"] ||= []
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"build A.",
    "created_at"=>"2026-06-29T10:00:00Z",
    "runtime_binding" => { "build" => { "git_head"=>"aaa111","artifact_hash"=>"hash-a" } } }
  j["records"] << { "kind"=>"review","status"=>"pass","summary"=>"build B.",
    "created_at"=>"2026-06-29T12:00:00Z",
    "runtime_binding" => { "build" => { "git_head"=>"bbb222","artifact_hash"=>"hash-b" } } }
  File.write(ARGV[0], JSON.pretty_generate(j))' "$S11_BUILD_DRIFT_EVIDENCE"

S11_BUILD_DRIFT_STATE="$TMPROOT/s11-build-drift-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TASK" "$S11_BUILD_DRIFT_EVIDENCE" "$S11_BUILD_DRIFT_STATE"

"$CLI" audit --task "$S11_TASK" --evidence "$S11_BUILD_DRIFT_EVIDENCE" \
  --state "$S11_BUILD_DRIFT_STATE" \
  --json >"$TMPROOT/s11-build-drift-audit.json" || true
json_assert 'build_drift_detected when two distinct build identities present' "$TMPROOT/s11-build-drift-audit.json" \
  'j["runtime_reconcile_summary"]["build_drift_detected"] == true'
json_assert 'build drift emits warning with source runtime.build_drift' "$TMPROOT/s11-build-drift-audit.json" \
  'j["warnings"].any? { |w| w["source"] == "runtime.build_drift" }'
json_assert 'build_identities count is 2 when two distinct builds' "$TMPROOT/s11-build-drift-audit.json" \
  'j["runtime_reconcile_summary"]["build_identities"].size == 2'

# ---- Group 10: blocker_classes counts top-level blocker_classification + findings.failure_class ----

S11_BCAT_EVIDENCE="$TMPROOT/s11-bcat-evidence.json"
"$CLI" evidence init --output "$S11_BCAT_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  j["records"] ||= []
  j["records"] << { "kind"=>"review","status"=>"blocked","summary"=>"env missing.",
    "created_at"=>"2026-06-29T10:00:00Z",
    "blocker_classification" => { "kind"=>"environment_failure","detail"=>"missing dep." },
    "findings" => [
      { "severity"=>"high","summary"=>"service down.","symptom"=>"x","source"=>"y",
        "consequence"=>"z","remedy"=>"fix.","failure_class"=>"service_failure" }
    ] }
  File.write(ARGV[0], JSON.pretty_generate(j))' "$S11_BCAT_EVIDENCE"

S11_BCAT_STATE="$TMPROOT/s11-bcat-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TASK" "$S11_BCAT_EVIDENCE" "$S11_BCAT_STATE"

"$CLI" audit --task "$S11_TASK" --evidence "$S11_BCAT_EVIDENCE" \
  --state "$S11_BCAT_STATE" \
  --json >"$TMPROOT/s11-bcat-audit.json" || true
json_assert 'blocker_classes counts top-level blocker_classification.kind' "$TMPROOT/s11-bcat-audit.json" \
  'j["runtime_reconcile_summary"]["blocker_classes"]["environment_failure"] == 1'
json_assert 'blocker_classes counts findings.failure_class' "$TMPROOT/s11-bcat-audit.json" \
  'j["runtime_reconcile_summary"]["blocker_classes"]["service_failure"] == 1'

# ---- Group 11: validate catches real_path_test PASS whose runtime_binding was removed after submit ----

S11_MUTATE_EVIDENCE="$TMPROOT/s11-mutate-evidence.json"
"$CLI" evidence init --output "$S11_MUTATE_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence submit \
  --file "$S11_MUTATE_EVIDENCE" \
  --report "$TMPROOT/s11-rpt-with-binding-report.yaml" \
  --task "$S11_TEST_TASK" \
  --json >/dev/null
# Mutate: strip the runtime_binding from the submitted pass record.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["kind"]=="test" && x["status"]=="pass" }; r.delete("runtime_binding") if r; File.write(p, JSON.pretty_generate(j))' "$S11_MUTATE_EVIDENCE"
if "$CLI" validate --task "$S11_TEST_TASK" --evidence "$S11_MUTATE_EVIDENCE" --json >"$TMPROOT/s11-mutate-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects real_path_test PASS after runtime_binding removed: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects real_path_test PASS after runtime_binding stripped from record'
json_assert 'validate reports runtime_binding error source' "$TMPROOT/s11-mutate-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".runtime_binding") }'

# ---- Group 12: real_path_test PASS with build-only binding (no server/browser owner) is rejected ----

cat >"$TMPROOT/s11-rpt-build-only-report.yaml" <<'YAML'
kind: test
verdict: pass
summary: real_path_test with build-only runtime_binding (no server/browser owner).
source_message_id: slice8:test:rpt:buildonly
test_level: repo_regression
evidence_level: real_path_test
rule_application:
  required_rule_files_read:
    - references/runtime/testing-guideline.md
  applied_checks:
    - id: real_path_build_only
      verdict: pass
      evidence: build provenance recorded.
  not_applicable: []
confirmed:
  - build provenance recorded
assumed: []
missing: []
residual_risk: "No residual risk."
findings: []
coverage: []
artifacts: []
test_environment:
  environment: local
  test_tab_or_pane: current
  server_owner: none
  browser_owner: none
  cleanup_hook: none
  artifact_cleanup: none
  duration: 1s
  resource_usage: low
  cleanup_status: complete
  ux_quality: not_applicable
  artifact_quality: ok
runtime_binding:
  build:
    git_head: "abc1234"
    artifact_hash: "def5678"
YAML

S11_BUILD_ONLY_EVIDENCE="$TMPROOT/s11-build-only-evidence.json"
"$CLI" evidence init --output "$S11_BUILD_ONLY_EVIDENCE" >/dev/null
if ORBIT_INSTANCE=tester "$CLI" evidence submit \
  --file "$S11_BUILD_ONLY_EVIDENCE" \
  --report "$TMPROOT/s11-rpt-build-only-report.yaml" \
  --task "$S11_TEST_TASK" \
  --json >"$TMPROOT/s11-build-only-submit.json" 2>/dev/null; then
  printf 'FAIL real_path_test PASS with build-only binding (no server/browser owner) is rejected: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'real_path_test PASS with build-only binding is rejected at submit'

# Also confirm validate rejects a directly-injected build-only real_path_test pass record.
S11_BUILD_ONLY_INJECT="$TMPROOT/s11-build-only-inject.json"
"$CLI" evidence init --output "$S11_BUILD_ONLY_INJECT" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []; j["records"] << {"kind"=>"test","status"=>"pass","summary"=>"build only.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"evidence_level"=>"real_path_test","runtime_binding"=>{"build"=>{"git_head"=>"abc1234"}}}; File.write(p, JSON.pretty_generate(j))' "$S11_BUILD_ONLY_INJECT"
if "$CLI" validate --task "$S11_TEST_TASK" --evidence "$S11_BUILD_ONLY_INJECT" --json >"$TMPROOT/s11-build-only-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects real_path_test PASS with build-only binding: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects real_path_test PASS with build-only binding'

# ---- Group 13: handoff packet exposes runtime binding, cleanup status, reproducibility/runtime gaps ----

S11_HANDOFF_EVIDENCE="$TMPROOT/s11-handoff-evidence.json"
"$CLI" evidence init --output "$S11_HANDOFF_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester "$CLI" evidence submit \
  --file "$S11_HANDOFF_EVIDENCE" \
  --report "$TMPROOT/s11-rpt-with-binding-report.yaml" \
  --task "$S11_TEST_TASK" \
  --json >/dev/null
S11_HANDOFF_STATE="$TMPROOT/s11-handoff-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "done",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TEST_TASK" "$S11_HANDOFF_EVIDENCE" "$S11_HANDOFF_STATE"
"$CLI" handoff --task "$S11_TEST_TASK" --evidence "$S11_HANDOFF_EVIDENCE" \
  --state "$S11_HANDOFF_STATE" --json >"$TMPROOT/s11-handoff.json" 2>/dev/null || true
json_assert 'handoff packet includes runtime_summary' "$TMPROOT/s11-handoff.json" \
  'j.key?("runtime_summary") && j["runtime_summary"].is_a?(Hash)'
json_assert 'handoff runtime_summary includes runtime_bindings list' "$TMPROOT/s11-handoff.json" \
  'j["runtime_summary"]["runtime_bindings"].is_a?(Array) && j["runtime_summary"]["runtime_binding_count"] >= 1'
json_assert 'handoff runtime_summary includes cleanup_status mapping' "$TMPROOT/s11-handoff.json" \
  'j["runtime_summary"]["cleanup_status"].is_a?(Hash) && j["runtime_summary"]["cleanup_status"].key?("all_complete")'
json_assert 'handoff runtime_summary includes reproducibility_gaps list' "$TMPROOT/s11-handoff.json" \
  'j["runtime_summary"]["reproducibility_gaps"].is_a?(Array)'
json_assert 'handoff runtime_summary includes runtime_gaps list' "$TMPROOT/s11-handoff.json" \
  'j["runtime_summary"]["runtime_gaps"].is_a?(Array)'
json_assert 'handoff packet includes runtime_reconcile_summary' "$TMPROOT/s11-handoff.json" \
  'j.key?("runtime_reconcile_summary") && j["runtime_reconcile_summary"].is_a?(Hash)'
json_assert 'handoff readable_summary surfaces runtime counts' "$TMPROOT/s11-handoff.json" \
  'j["readable_summary"].key?("runtime_binding_count") && j["readable_summary"].key?("cleanup_all_complete") && j["readable_summary"].key?("runtime_gaps_count") && j["readable_summary"].key?("reproducibility_gaps_count")'
json_assert 'handoff runtime_summary has_gaps is false for complete binding' "$TMPROOT/s11-handoff.json" \
  'j["runtime_summary"]["has_gaps"] == false'

# handoff surfaces a runtime gap when real_path_test PASS lacks server/browser owner
S11_HANDOFF_GAP_EVIDENCE="$TMPROOT/s11-handoff-gap-evidence.json"
"$CLI" evidence init --output "$S11_HANDOFF_GAP_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []; j["records"] << {"kind"=>"test","status"=>"pass","summary"=>"gap.","created_at"=>"2026-06-29T10:00:00Z","structured_submit"=>true,"evidence_level"=>"real_path_test","runtime_binding"=>{"build"=>{"git_head"=>"abc1234"}}}; File.write(p, JSON.pretty_generate(j))' "$S11_HANDOFF_GAP_EVIDENCE"
"$CLI" handoff --task "$S11_TEST_TASK" --evidence "$S11_HANDOFF_GAP_EVIDENCE" \
  --state "$S11_HANDOFF_STATE" --json >"$TMPROOT/s11-handoff-gap.json" 2>/dev/null || true
json_assert 'handoff runtime_summary reports runtime_gaps when owner missing' "$TMPROOT/s11-handoff-gap.json" \
  'j["runtime_summary"]["runtime_gaps"].any? { |g| g["source"].include?("browser.owner") } && j["runtime_summary"]["has_gaps"] == true'

# ---- Group 14: status pass with non-code blocker_classification is rejected ----

# Submit-time: pass + environment_failure blocker_classification is rejected.
cat >"$TMPROOT/s11-pass-env-blocker-report.yaml" <<'YAML'
kind: review
verdict: pass
summary: Pass with environment blocker classification (contradictory).
source_message_id: slice8:review:passenvblocker
quality_outcome_verdict: pass
quality_outcome_reasoning: Contradictory pass.
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: blocker_check
      verdict: pass
      evidence: blocker classification present.
  not_applicable: []
confirmed:
  - blocker classification present
assumed: []
missing: []
residual_risk: "No residual risk."
counterexample_cases:
  - pass with environment blocker must be rejected.
implementation_readiness_verdict: not_checked
findings: []
coverage: []
artifacts: []
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: outcome checked
  - id: counterexamples
    verdict: pass
    evidence: no counterexamples
  - id: evidence_sufficiency
    verdict: pass
    evidence: sufficient
  - id: residual_risk
    verdict: pass
    evidence: no residual risk
blocker_classification:
  kind: environment_failure
  detail: "Service dependency missing during pass."
YAML

S11_PASS_ENV_EVIDENCE="$TMPROOT/s11-pass-env-blocker-evidence.json"
"$CLI" evidence init --output "$S11_PASS_ENV_EVIDENCE" >/dev/null
if ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S11_PASS_ENV_EVIDENCE" \
  --report "$TMPROOT/s11-pass-env-blocker-report.yaml" \
  --task "$S11_TASK" \
  --json >"$TMPROOT/s11-pass-env-blocker-submit.json" 2>/dev/null; then
  printf 'FAIL submit rejects pass with environment_failure blocker_classification: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'submit rejects pass with non-code blocker_classification'

# Validate-time: directly-injected pass record with service_failure blocker is rejected.
S11_SVC_BLOCKER_EVIDENCE="$TMPROOT/s11-svc-blocker-evidence.json"
"$CLI" evidence init --output "$S11_SVC_BLOCKER_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []; j["records"] << {"kind"=>"review","status"=>"pass","summary"=>"pass with service blocker.","created_at"=>"2026-06-29T10:00:00Z","blocker_classification"=>{"kind"=>"service_failure","detail"=>"svc down"}}; File.write(p, JSON.pretty_generate(j))' "$S11_SVC_BLOCKER_EVIDENCE"
if "$CLI" validate --task "$S11_TASK" --evidence "$S11_SVC_BLOCKER_EVIDENCE" --json >"$TMPROOT/s11-svc-blocker-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects pass with service_failure blocker_classification: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects pass with service_failure blocker_classification'
json_assert 'validate reports blocker_classification.kind error for pass' "$TMPROOT/s11-svc-blocker-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".blocker_classification.kind") }'

# Audit-time: pass with unknown blocker_classification is surfaced as blocking.
S11_UNK_BLOCKER_EVIDENCE="$TMPROOT/s11-unk-blocker-evidence.json"
"$CLI" evidence init --output "$S11_UNK_BLOCKER_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []; j["records"] << {"kind"=>"review","status"=>"pass","summary"=>"pass with unknown blocker.","created_at"=>"2026-06-29T10:00:00Z","blocker_classification"=>{"kind"=>"unknown","detail"=>"unresolved"}}; File.write(p, JSON.pretty_generate(j))' "$S11_UNK_BLOCKER_EVIDENCE"
S11_UNK_BLOCKER_STATE="$TMPROOT/s11-unk-blocker-state.yaml"
ruby --disable-gems -ryaml -e '
  s = {
    "schema_version" => "orbit-loop-state-v1",
    "phase" => "in_review",
    "current_task" => ARGV[0],
    "history" => [],
    "artifacts" => { "evidence_file" => ARGV[1] }
  }
  File.write(ARGV[2], YAML.dump(s))' \
  "$S11_TASK" "$S11_UNK_BLOCKER_EVIDENCE" "$S11_UNK_BLOCKER_STATE"
"$CLI" audit --task "$S11_TASK" --evidence "$S11_UNK_BLOCKER_EVIDENCE" \
  --state "$S11_UNK_BLOCKER_STATE" \
  --json >"$TMPROOT/s11-unk-blocker-audit.json" || true
json_assert 'audit blocks pass with unknown blocker_classification' "$TMPROOT/s11-unk-blocker-audit.json" \
  'j["blocking_findings"].any? { |f| f["source"].end_with?(".blocker_classification.kind") }'

# Sanity: pass with code_failure blocker_classification is allowed (code bug found is a valid pass outcome).
S11_CODE_FAIL_EVIDENCE="$TMPROOT/s11-code-fail-evidence.json"
"$CLI" evidence init --output "$S11_CODE_FAIL_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []; j["records"] << {"kind"=>"review","status"=>"pass","summary":"pass with code_failure blocker.","created_at"=>"2026-06-29T10:00:00Z","blocker_classification"=>{"kind"=>"code_failure","detail":"bug fixed"}}; File.write(p, JSON.pretty_generate(j))' "$S11_CODE_FAIL_EVIDENCE"
S11_CODE_FAIL_VALIDATE="$TMPROOT/s11-code-fail-validate.json"
"$CLI" validate --task "$S11_TASK" --evidence "$S11_CODE_FAIL_EVIDENCE" --json >"$S11_CODE_FAIL_VALIDATE" 2>/dev/null || true
json_assert 'validate allows pass with code_failure blocker_classification' "$S11_CODE_FAIL_VALIDATE" \
  'j["errors"].none? { |e| e["source"].end_with?(".blocker_classification.kind") }'

# ---- Group 15: validate rejects blocker_classification.kind not in ALLOWED_FAILURE_CLASSES ----

# Build a legit pass+code_failure record via normal submit, then mutate kind to an invented value.
S11_BAD_KIND_EVIDENCE="$TMPROOT/s11-bad-kind-evidence.json"
"$CLI" evidence init --output "$S11_BAD_KIND_EVIDENCE" >/dev/null
cat >"$TMPROOT/s11-code-fail-pass-report.yaml" <<'YAML'
kind: review
verdict: pass
summary: Pass with code_failure blocker classification (legit baseline).
source_message_id: slice8:review:codefailbaseline
quality_outcome_verdict: pass
quality_outcome_reasoning: Code bug found and fixed.
evidence_level: outcome_quality
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: code_fail_check
      verdict: pass
      evidence: code_failure blocker recorded.
  not_applicable: []
confirmed:
  - code_failure blocker recorded
assumed: []
missing: []
residual_risk: "No residual risk."
counterexample_cases:
  - mutated blocker kind must be rejected by validate.
implementation_readiness_verdict: not_checked
findings: []
coverage: []
artifacts: []
quality_question_answers:
  - id: outcome
    verdict: pass
    evidence: outcome checked
  - id: counterexamples
    verdict: pass
    evidence: no counterexamples
  - id: evidence_sufficiency
    verdict: pass
    evidence: sufficient
  - id: residual_risk
    verdict: pass
    evidence: no residual risk
blocker_classification:
  kind: code_failure
  detail: "Bug fixed before pass."
YAML
ORBIT_INSTANCE=reviewer "$CLI" evidence submit \
  --file "$S11_BAD_KIND_EVIDENCE" \
  --report "$TMPROOT/s11-code-fail-pass-report.yaml" \
  --task "$S11_TASK" \
  --json >/dev/null
# Mutate the recorded kind to an invented value not in ALLOWED_FAILURE_CLASSES.
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); r=j["records"].find { |x| x["blocker_classification"].is_a?(Hash) }; r["blocker_classification"]["kind"]="network_issue"; File.write(p, JSON.pretty_generate(j))' "$S11_BAD_KIND_EVIDENCE"
if "$CLI" validate --task "$S11_TASK" --evidence "$S11_BAD_KIND_EVIDENCE" --json >"$TMPROOT/s11-bad-kind-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects unknown blocker_classification.kind: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects unknown blocker_classification.kind after mutation'
json_assert 'validate reports blocker_classification.kind error for unknown kind' "$TMPROOT/s11-bad-kind-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".blocker_classification.kind") }'

# Non-pass status with unknown kind is also rejected (enum check is status-independent).
S11_BAD_KIND_FAIL_EVIDENCE="$TMPROOT/s11-bad-kind-fail-evidence.json"
"$CLI" evidence init --output "$S11_BAD_KIND_FAIL_EVIDENCE" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"] ||= []; j["records"] << {"kind"=>"review","status"=>"fail","summary":"fail with invented blocker kind.","created_at"=>"2026-06-29T10:00:00Z","blocker_classification"=>{"kind"=>"network_issue","detail"=>"net"}}; File.write(p, JSON.pretty_generate(j))' "$S11_BAD_KIND_FAIL_EVIDENCE"
if "$CLI" validate --task "$S11_TASK" --evidence "$S11_BAD_KIND_FAIL_EVIDENCE" --json >"$TMPROOT/s11-bad-kind-fail-validate.json" 2>/dev/null; then
  printf 'FAIL validate rejects unknown blocker_classification.kind on non-pass record: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'validate rejects unknown blocker_classification.kind on non-pass record'
json_assert 'validate reports blocker_classification.kind error for unknown kind on fail record' "$TMPROOT/s11-bad-kind-fail-validate.json" \
  'j["valid"] == false && j["errors"].any? { |e| e["source"].end_with?(".blocker_classification.kind") }'

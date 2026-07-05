TASK="$TMPROOT/review-task.yaml"
write_review_report() {
  local path="$1"
  local verdict="$2"
  local summary="$3"
  local source_message_id="$4"
  local outcome_verdict="$verdict"
  if [ "$verdict" = "blocked" ]; then
    outcome_verdict="partial"
  elif [ "$verdict" = "invalid" ]; then
    outcome_verdict="unknown"
  fi
  cat >"$path" <<YAML
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
verdict: ${verdict}
summary: ${summary}
source_message_id: ${source_message_id}
quality_outcome_verdict: ${outcome_verdict}
quality_outcome_reasoning: Review outcome was recorded for gate ordering coverage.
findings: []
coverage:
  - review checked aggregate verdict behavior
artifacts:
  - tests/orbit_test.sh
YAML
  if [ "$verdict" = "blocked" ]; then
    cat >>"$path" <<'YAML'
blocked:
  reason: Review is blocked by missing required evidence.
  next_step: Provide the missing evidence and resubmit review.
  owner: lead
YAML
  fi
  append_review_quality_fields "$path"
}

"$CLI" new-task --implementation-authority reviewer --assigned-instance reviewer-main --task-type implementation_review --output "$TASK" >"$TMPROOT/new-task.out" 2>"$TMPROOT/new-task.err"
test ! -s "$TMPROOT/new-task.err"
yaml_assert 'new-task writes required fields' "$TASK" 'j["schema_version"] == "orbit-task-v1" && j["project"] == File.basename(Dir.pwd) && !j.key?("target_role") && j.dig("execution_contract","implementation_authority") == "reviewer" && j.dig("execution_contract","assigned_instance") == "reviewer-main" && j["task_type"] == "implementation_review" && %w[quality_outcome scope acceptance evidence_requirements stop_policy].all? { |k| j.key?(k) }'
yaml_assert 'new-task infers team mode for delegated implementation contract' "$TASK" 'j.dig("execution_contract","operation_mode") == "team"'
expect_failure 'new-task rejects explicit solo delegated implementation contract' "$CLI" new-task --operation-mode solo --implementation-authority reviewer --assigned-instance reviewer-main --task-type implementation_review --output "$TMPROOT/bad-solo-delegated-task.yaml"
cp "$TASK" "$TMPROOT/bad-solo-contract-task.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["execution_contract"]["operation_mode"]="solo"; File.write(p, YAML.dump(y))' "$TMPROOT/bad-solo-contract-task.yaml"
expect_failure 'validate rejects solo contract with delegated implementation authority' "$CLI" validate --task "$TMPROOT/bad-solo-contract-task.yaml" --json
yaml_assert 'new-task initializes runtime guardrail fields' "$TASK" 'j["source_contract"].is_a?(Hash) && j["traceability"].is_a?(Array) && j["worktree_safety"]["require_status_check"] == true && j["release_surface"].is_a?(Hash) && j["supply_chain"].is_a?(Hash) && j["final_audit"]["required"] == true'
yaml_assert 'new-task initializes non-empty quality outcome template' "$TASK" 'j["quality_outcome"]["user_problem"].is_a?(String) && !j["quality_outcome"]["user_problem"].empty? && j["quality_outcome"]["desired_property"].is_a?(String) && !j["quality_outcome"]["desired_property"].empty? && j["quality_outcome"]["measurable_thresholds"].is_a?(Array) && !j["quality_outcome"]["measurable_thresholds"].empty? && j["quality_outcome"]["invalid_completions"].is_a?(Array) && !j["quality_outcome"]["invalid_completions"].empty?'
yaml_assert 'new-task initializes outcome-first review strategy' "$TASK" 'j["review_strategy"]["entrypoints"].include?("quality_outcome") && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Outcome:") } && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Structure:") } && j["review_strategy"]["suggested_checks"].any? { |s| s.start_with?("Evidence:") }'
yaml_assert 'new-task does not invent project quality rules' "$TASK" 'j["quality_rules"].is_a?(Array) && j["quality_rules"].empty?'
yaml_assert 'new-task exposes configured review rule packs' "$TASK" 'j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }'
for typed in refactor docs performance ux; do
  TYPED_TASK="$TMPROOT/${typed}-task.yaml"
  "$CLI" new-task --task-type "${typed}_improvement" --output "$TYPED_TASK" >/dev/null
  case "$typed" in
    refactor) expected="responsibilities" ;;
    docs) expected="docs" ;;
    performance) expected="baseline" ;;
    ux) expected="user path" ;;
  esac
  yaml_assert "new-task writes ${typed} quality outcome template" "$TYPED_TASK" 'text = j["quality_outcome"].values.flatten.join(" ").downcase; !j["quality_outcome"]["measurable_thresholds"].empty? && text.include?(ARGV[2])' "$expected"
done
PERFORMANCE_TASK="$TMPROOT/performance-measurement-task.yaml"
"$CLI" new-task --task-type performance_improvement --output "$PERFORMANCE_TASK" >/dev/null
yaml_assert 'new-task initializes baseline and after quality measurement contract' "$PERFORMANCE_TASK" 'j["quality_measurement"]["required"] == true && j["quality_measurement"]["baseline_required"] == true && j["quality_measurement"]["after_required"] == true && j["quality_measurement"]["metrics"].is_a?(Array) && !j["quality_measurement"]["metrics"].empty?'
DESIGN_TASK="$TMPROOT/design-task.yaml"
"$CLI" new-task --task-type design --output "$DESIGN_TASK" >/dev/null
yaml_assert 'new-task initializes design lifecycle for design task' "$DESIGN_TASK" 'j["design_lifecycle"]["enabled"] == true && j["design_lifecycle"]["current_phase"] == "drafting" && j["design_lifecycle"]["phases"].include?("coding_ready") && j["design_lifecycle"]["user_confirmation_required"] == true'
CODING_TASK="$TMPROOT/coding-task.yaml"
"$CLI" new-task --task-type coding --output "$CODING_TASK" >/dev/null
yaml_assert 'new-task creates coding tasks without mandatory design by default' "$CODING_TASK" 'j["design_lifecycle"]["enabled"] == false && j["design_lifecycle"]["coding_requires_confirmed_design"] == false && j["design_reference"]["required_for_coding"] == false && j["design_reference"]["status"] == "unconfirmed"'
"$CLI" validate --task "$CODING_TASK" --json >"$TMPROOT/coding-task-default-validate.json"
json_assert 'default coding task validates without confirmed design' "$TMPROOT/coding-task-default-validate.json" 'j["valid"] == true'
DECOMP_TASK="$TMPROOT/decomposition-task.yaml"
"$CLI" new-task --task-type decomposition --output "$DECOMP_TASK" >/dev/null
yaml_assert 'new-task initializes decomposition contract fields' "$DECOMP_TASK" 'j["implementation_plan"]["required"] == true && j["decomposition"]["child_slices"].is_a?(Array) && j["decomposition"]["aggregate_outcome_metrics"].is_a?(Array) && j["final_aggregate_audit"]["required"] == true'
expect_failure 'new-task refuses overwrite' "$CLI" new-task --implementation-authority reviewer --assigned-instance reviewer-main --task-type implementation_review --output "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer-main --manual-payload --json >"$TMPROOT/dispatch-generic.json"
json_assert 'dispatch manual payload emits delivery artifact with context preflight' "$TMPROOT/dispatch-generic.json" 'j["schema_version"] == "orbit-dispatch-v1" && j["action"] == "manual_delivery_required" && j["delivery"]["mode"] == "manual_artifact" && j["delivery"]["runtime_adapter"] == "none" && j["to_instance"] == "reviewer-main" && j["resolved_role"] == "reviewer" && j.dig("execution_contract","assigned_instance") == "reviewer-main" && j["task"] == File.expand_path(ARGV[2]) && !j["message"].include?("orbit runtime register --json") && j["message"].include?("orbit whoami --json") && !j["message"].include?("orbit whoami --task") && j["message"].include?("orbit rules print-context --task") && j["message"].include?("context_preflight.required_files") && !j["context_preflight"]["commands"].include?(["orbit", "runtime", "register", "--json"]) && j["context_preflight"]["commands"].include?(["orbit", "whoami", "--json"]) && j["context_preflight"]["required_files"].any? { |r| r["path"] == "SKILL.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/guide.md" } && j["context_preflight"]["required_files"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" } && j["checks"]["target_allowed_by_execution_contract"] == true && j["checks"]["delivery_precondition_met"] == true && j["checks"]["manual_artifact"] == true && j["checks"]["explicit_override"] == false && j["checks"]["live_binding_confirmed"] == false && j["checks"]["live_confirmed_for_delivery"] == false' "$TASK"
"$CLI" dispatch --task "$TASK" --to reviewer-main --pane pane-123 --reply-to observer-pane --dry-run --json >"$TMPROOT/dispatch-herdr-dry-run.json"
json_assert 'dispatch herdr dry-run emits adapter plan with explicit reply-to' "$TMPROOT/dispatch-herdr-dry-run.json" 'j["action"] == "dry_run" && j["reply_to"] == "observer-pane" && j["reply_to_source"] == "explicit_option" && j["message"].include?("reply-to:observer-pane") && j["adapter"]["schema_version"] == "orbit-herdr-dispatch-v1" && !j["adapter"].key?("submit_delay_seconds") && j["adapter"]["commands"] == [["herdr", "pane", "run", "pane-123", j["message"]]] && j["adapter"]["commands"][0][4].include?(File.expand_path(ARGV[2])) && j["checks"]["delivery_precondition_met"] == false && j["checks"]["manual_artifact"] == false && j["checks"]["explicit_override"] == true && j["checks"]["live_binding_confirmed"] == false && j["checks"]["live_confirmed_for_delivery"] == false && j.dig("target_runtime_resolution","identity_verification") == "override" && j["risk"].include?("do_not_use_as_evidence_runtime_identity")' "$TASK"
HERDR_PANE_ID=lead-reply-pane "$CLI" dispatch --task "$TASK" --to reviewer-main --pane pane-123 --dry-run --json >"$TMPROOT/dispatch-herdr-env-reply-to.json"
json_assert 'dispatch herdr reply-to defaults to current Herdr pane' "$TMPROOT/dispatch-herdr-env-reply-to.json" 'j["reply_to"] == "lead-reply-pane" && j["reply_to_source"] == "HERDR_PANE_ID" && j["message"].include?("reply-to:lead-reply-pane")'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
: "${ORBIT_FAKE_HERDR_DISPATCH_ARGS:?}"
printf '%s\n' "$@" >>"$ORBIT_FAKE_HERDR_DISPATCH_ARGS"
printf '%s\n' '---' >>"$ORBIT_FAKE_HERDR_DISPATCH_ARGS"
printf 'sent:%s\n' "$3"
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
expect_failure 'dispatch refuses unverified explicit pane direct delivery' env ORBIT_FAKE_HERDR_DISPATCH_ARGS="$TMPROOT/fake-herdr-dispatch-args.txt" PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --pane pane-123 --json
test ! -f "$TMPROOT/fake-herdr-dispatch-args.txt"
pass 'dispatch does not submit unverified explicit pane through adapter'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
printf 'transport denied\n' >&2
exit 42
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --pane pane-123 --json >"$TMPROOT/dispatch-herdr-fail.json" 2>"$TMPROOT/dispatch-herdr-fail.err"; then
  printf 'FAIL dispatch herdr failure: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'unverified Herdr override' "$TMPROOT/dispatch-herdr-fail.err"
pass 'dispatch explicit pane failure occurs before adapter transport'
"$CLI" bind-pane --instance reviewer-main --pane dispatch-live-pane --json >"$TMPROOT/dispatch-bind-reviewer.json"
ruby --disable-gems -rjson -ryaml -rdigest -rtime -rfileutils -e '
  roles = YAML.safe_load(File.read(".orbit/roles.yaml"), aliases: true).fetch("roles")
  instances = YAML.safe_load(File.read(".orbit/instances.yaml"), aliases: true).fetch("instances")
  stable_instance = ->(value) {
    copy = JSON.parse(JSON.generate(value))
    %w[binding herdr view].each { |key| copy.delete(key) }
    copy
  }
  instance = instances.fetch("reviewer-main")
  role = roles.fetch(instance.fetch("role_ref"))
  lead_instance = instances.fetch("lead-main")
  lead_role = roles.fetch(lead_instance.fetch("role_ref"))
  now = Time.now.utc.iso8601
  session = {
    "schema_version" => "orbit-runtime-session-v1",
    "session_id" => "ors-dispatch-live",
    "launch_id" => "orl-dispatch-live",
    "state" => "active",
    "project_root" => Dir.pwd,
    "project_root_sha256" => Digest::SHA256.hexdigest(File.expand_path(Dir.pwd)),
    "project_id" => File.basename(Dir.pwd),
    "host_id" => "test-host",
    "user" => "test-user",
    "instance" => "reviewer-main",
    "role" => "reviewer",
    "role_ref" => "reviewer",
    "role_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(role)),
    "instance_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(stable_instance.call(instance))),
    "client" => "codex",
    "command" => "codex",
    "herdr" => {
      "session" => "",
      "workspace" => "",
      "tab" => "",
      "pane" => "dispatch-live-pane",
      "canonical_pane" => "dispatch-live-pane"
    },
    "identity" => {
      "verification" => "herdr_verified",
      "whoami_valid" => true,
      "conflicts" => []
    },
    "created_at" => now,
    "updated_at" => now,
    "heartbeat" => {
      "last_seen_at" => now,
      "ttl_seconds" => 300
    }
  }
  lead_session = {
    "schema_version" => "orbit-runtime-session-v1",
    "session_id" => "ors-lead-owner",
    "launch_id" => "orl-lead-owner",
    "state" => "active",
    "project_root" => Dir.pwd,
    "project_root_sha256" => Digest::SHA256.hexdigest(File.expand_path(Dir.pwd)),
    "project_id" => File.basename(Dir.pwd),
    "host_id" => "test-host",
    "user" => "test-user",
    "instance" => "lead-main",
    "role" => "lead",
    "role_ref" => "lead",
    "role_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(lead_role)),
    "instance_config_sha256" => Digest::SHA256.hexdigest(JSON.generate(stable_instance.call(lead_instance))),
    "client" => "codex",
    "command" => "codex",
    "herdr" => {
      "session" => "",
      "workspace" => "",
      "tab" => "",
      "pane" => "lead-owner-pane",
      "canonical_pane" => "lead-owner-pane"
    },
    "identity" => {
      "verification" => "herdr_verified",
      "whoami_valid" => true,
      "conflicts" => []
    },
    "created_at" => now,
    "updated_at" => now,
    "heartbeat" => {
      "last_seen_at" => now,
      "ttl_seconds" => 300
    }
  }
  instance_record = {
    "schema_version" => "orbit-runtime-instance-v1",
    "instance" => "reviewer-main",
    "current_session_id" => "ors-dispatch-live",
    "current_state" => "active",
    "previous_sessions" => [],
    "replacement_diagnostics" => [],
    "ack" => nil,
    "updated_at" => now
  }
  FileUtils.mkdir_p(".orbit/runtime/sessions")
  FileUtils.mkdir_p(".orbit/runtime/instances")
  File.write(".orbit/runtime/sessions/ors-dispatch-live.json", JSON.pretty_generate(session) + "\n")
  File.write(".orbit/runtime/sessions/ors-lead-owner.json", JSON.pretty_generate(lead_session) + "\n")
  File.write(".orbit/runtime/instances/reviewer-main.json", JSON.pretty_generate(instance_record) + "\n")
'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    ruby_pwd=$(ruby --disable-gems -e 'print Dir.pwd')
    printf '{"result":{"agents":[{"pane_id":"dispatch-live-pane","agent":"codex","agent_status":"idle","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-live-confirmed.json" 2>"$TMPROOT/dispatch-live-confirmed.err"; then
  printf 'FAIL dispatch handwritten herdr_verified runtime: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-live-confirmed.err"
pass 'dispatch refuses handwritten herdr_verified runtime without trusted caller proof'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    ruby_pwd=$(ruby --disable-gems -e 'print Dir.pwd')
    printf '{"result":{"agents":[{"pane_id":"dispatch-live-pane","agent":"claude","agent_status":"idle","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-live-wrong-agent.json" 2>"$TMPROOT/dispatch-live-wrong-agent.err"; then
  printf 'FAIL dispatch wrong agent on verified pane: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-live-wrong-agent.err"
pass 'dispatch refuses verified session when Herdr pane now hosts different agent identity'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    ruby_pwd=$(ruby --disable-gems -e 'print Dir.pwd')
    printf '{"result":{"agents":[{"pane_id":"dispatch-live-pane","agent_status":"idle","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-live-missing-client.json" 2>"$TMPROOT/dispatch-live-missing-client.err"; then
  printf 'FAIL dispatch missing client on verified pane: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-live-missing-client.err"
pass 'dispatch refuses verified session when Herdr agent client is missing'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    ruby_pwd=$(ruby --disable-gems -e 'print Dir.pwd')
    printf '{"result":{"agents":[{"pane_id":"dispatch-live-pane","agent":"codex","agent_status":"done","cwd":"__PWD__"},{"pane_id":"lead-owner-pane","agent":"codex","agent_status":"idle","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-done-needs-ack.json" 2>"$TMPROOT/dispatch-done-needs-ack.err"; then
  printf 'FAIL dispatch done target without ack: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-done-needs-ack.err"
pass 'dispatch blocks untrusted done Herdr target before owner ack'
expect_failure 'runtime ack-session rejects non-owner identity' env ORBIT_INSTANCE=tester-main ORBIT_ROLE=tester PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime ack-session reviewer-main --json
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-done-after-non-owner-ack.json" 2>"$TMPROOT/dispatch-done-after-non-owner-ack.err"; then
  printf 'FAIL dispatch done target after non-owner ack: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-done-after-non-owner-ack.err"
pass 'dispatch remains blocked after non-owner ack-session attempt'
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime ack-session reviewer-main --json >"$TMPROOT/runtime-ack-reviewer-manual.json"
json_assert 'runtime ack-session reports unsupported without writing manual owner ack' "$TMPROOT/runtime-ack-reviewer-manual.json" 'j["action"] == "unsupported" && j["reason"] == "trusted_owner_ack_unavailable" && j["ack_written"] == false && j["dispatch_ready"] == false'
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-done-after-manual-ack.json" 2>"$TMPROOT/dispatch-done-after-manual-ack.err"; then
  printf 'FAIL dispatch done target after manual owner ack: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-done-after-manual-ack.err"
pass 'dispatch remains blocked after manual owner ack-session'
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead ORBIT_SESSION_ID=ors-lead-owner ORBIT_LAUNCH_ID=orl-lead-owner HERDR_PANE_ID=lead-owner-pane PATH="$TMPROOT/fakebin:$PATH" "$CLI" runtime ack-session reviewer-main --json >"$TMPROOT/runtime-ack-reviewer.json"
json_assert 'runtime env-spoofable owner ack-session is unsupported without caller proof' "$TMPROOT/runtime-ack-reviewer.json" 'j["action"] == "unsupported" && j["reason"] == "trusted_owner_ack_unavailable" && j["ack_written"] == false && j["acknowledged_by"]["runtime_identity"]["verification"] == "mismatch" && j["acknowledged_by"]["runtime_identity"]["reason"] == "session_not_active_herdr_verified" && j["dispatch_ready"] == false'
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-done-after-env-ack.json" 2>"$TMPROOT/dispatch-done-after-env-ack.err"; then
  printf 'FAIL dispatch done target after env-spoofable owner ack: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-done-after-env-ack.err"
pass 'dispatch remains blocked after env-spoofable owner ack-session'
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/bin/sh
case "$1 $2" in
  "agent list")
    ruby_pwd=$(ruby --disable-gems -e 'print Dir.pwd')
    printf '{"result":{"agents":[{"pane_id":"dispatch-live-pane","agent":"codex","cwd":"__PWD__"}]}}\n' | sed "s#__PWD__#$ruby_pwd#g"
    ;;
  *)
    printf 'unexpected herdr args: %s\n' "$*" >&2
    exit 1
    ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
if PATH="$TMPROOT/fakebin:$PATH" "$CLI" dispatch --task "$TASK" --to reviewer-main --dry-run --json >"$TMPROOT/dispatch-unknown-status.json" 2>"$TMPROOT/dispatch-unknown-status.err"; then
  printf 'FAIL dispatch unknown agent status: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'verified live Orbit runtime session' "$TMPROOT/dispatch-unknown-status.err"
pass 'dispatch refuses untrusted runtime before considering unknown Herdr agent status'
expect_failure 'dispatch requires live binding without pane override' "$CLI" dispatch --task "$TASK" --to reviewer-main --json
expect_failure 'dispatch rejects unknown target instance' "$CLI" dispatch --task "$TASK" --to missing --json

mkdir -p docs
printf '%s\n' '# Review Rule' '- Check project-specific review constraints.' >docs/review-rule.md
cp .orbit/roles.yaml "$TMPROOT/roles-before-rules.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["roles"]["reviewer"]["rules"]=["docs/review-rule.md", {"path"=>"docs/review-rule.md", "id"=>"duplicate-review-rule", "relation"=>"supplements"}]; File.write(p, YAML.dump(y))' .orbit/roles.yaml
ORBIT_INSTANCE=reviewer-main "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/rules-resolution.json" >"$TMPROOT/rules-resolution.stdout" 2>"$TMPROOT/rules-resolution.err"
test ! -s "$TMPROOT/rules-resolution.err"
cmp "$TMPROOT/rules-resolution.json" "$TMPROOT/rules-resolution.stdout"
json_assert 'rules resolve includes default, project, task, and rule pack sources' "$TMPROOT/rules-resolution.json" 'j["schema_version"] == "orbit-rule-resolution-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["sources"]["orbit_default"].any? { |r| r["path"] == "SKILL.md" && r["id"].is_a?(String) && r["relation"] == "baseline" && r["exists"] == true } && j["sources"]["orbit_default"].any? { |r| r["path"] == "references/runtime/quality-outcome-and-review.md" && r["load_policy"] == "required" } && j["sources"]["project_rules"].any? { |r| r["path"] == "docs/review-rule.md" && r["id"].is_a?(String) && r["relation"] == "supplements" && r["exists"] == true } && j["sources"]["project_rules"].any? { |r| r["path"] == "docs/review-rule.md" && r["id"] == "duplicate-review-rule" } && j["sources"]["task_rules"]["path"] == File.expand_path(ARGV[2]) && j["sources"]["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" }' "$TASK"
json_assert 'rules resolve records task_sha256 for artifact drift checks' "$TMPROOT/rules-resolution.json" 'j["task_sha256"].is_a?(String) && j["task_sha256"].length == 64'
ORBIT_INSTANCE=reviewer-main "$CLI" rules print-context --task "$TASK" --json --output "$TMPROOT/rules-context.json" >"$TMPROOT/rules-context.stdout" 2>"$TMPROOT/rules-context.err"
test ! -s "$TMPROOT/rules-context.err"
cmp "$TMPROOT/rules-context.json" "$TMPROOT/rules-context.stdout"
json_assert 'rules print-context emits ordered default project task and pack context' "$TMPROOT/rules-context.json" 'j["schema_version"] == "orbit-rules-context-v1" && j["valid"] == true && j["resolved_role"] == "reviewer" && j["load_model"]["default_rules_always_loaded"] == true && j["load_model"]["project_rules_are_additive"] == true && j["load_order"].all? { |r| r["rule_id"].is_a?(String) && r["relation"].is_a?(String) && r["dedupe_status"].is_a?(String) } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "SKILL.md" && r["required"] == true && r["exists"] == true && r["dedupe_status"] == "active" } && j["load_order"].any? { |r| r["source"] == "orbit_default" && r["path"] == "references/runtime/core-operating-model.md" && r["required"] == false } && j["load_order"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" && r["required"] == true && r["exists"] == true && r["dedupe_status"] == "active" } && j["load_order"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" && r["id"] == "duplicate-review-rule" && r["dedupe_status"] == "deduped" } && j["load_order"].any? { |r| r["source"] == "task_rules" && r["path"] == File.expand_path(ARGV[2]) && r["required"] == true } && j["load_order"].any? { |r| r["source"] == "rule_packs" && r["id"] == "brooks-review" && r["required"] == false } && j["required_files"].any? { |r| r["source"] == "project_role_rules" && r["path"] == "docs/review-rule.md" } && j["required_files"].select { |r| r["path"] == "docs/review-rule.md" }.length == 1 && j["context_budget"]["deduped"].any? { |r| r["path"] == "docs/review-rule.md" } && j["context_budget"]["shadowed"].is_a?(Array) && j["context_budget"]["not_loaded_but_related"].is_a?(Array) && j["rule_resolution"]["schema_version"] == "orbit-rule-resolution-v1"' "$TASK"
expect_failure 'rules output refuses overwrite with different role artifact' env ORBIT_INSTANCE=tester-main "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/rules-resolution.json"
ORBIT_ROLE=reviewer "$CLI" rules resolve --task "$TASK" --json >"$TMPROOT/rules-resolution-role.json"
json_assert 'rules resolve supports role identity' "$TMPROOT/rules-resolution-role.json" 'j["resolved_role"] == "reviewer" && j["valid"] == true'
ORBIT_INSTANCE=tester-main "$CLI" rules resolve --role reviewer --task "$TASK" --json >"$TMPROOT/rules-resolution-role-override.json"
json_assert 'rules resolve role option overrides ambient instance' "$TMPROOT/rules-resolution-role-override.json" 'j["resolved_role"] == "reviewer" && j["valid"] == true && !j["role_sources"].key?("env.ORBIT_INSTANCE")'
expect_failure 'rules resolve fails on task target mismatch' env ORBIT_INSTANCE=tester-main "$CLI" rules resolve --task "$TASK" --json
rm docs/review-rule.md
expect_failure 'rules resolve fails on missing project rule file' env ORBIT_INSTANCE=reviewer-main "$CLI" rules resolve --task "$TASK" --json
expect_failure 'validate fails on missing configured project rule file' "$CLI" validate --json
if "$CLI" dispatch --task "$TASK" --to reviewer-main --manual-payload --json >"$TMPROOT/dispatch-invalid-context.json" 2>"$TMPROOT/dispatch-invalid-context.err"; then
  printf 'FAIL dispatch invalid context preflight: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'context_preflight is invalid' "$TMPROOT/dispatch-invalid-context.err"
pass 'dispatch refuses invalid context preflight before delivery'
if "$CLI" start reviewer-main --dry-run --json >"$TMPROOT/start-invalid-context.json" 2>"$TMPROOT/start-invalid-context.err"; then
  printf 'FAIL start invalid context preflight: command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'context_preflight is invalid' "$TMPROOT/start-invalid-context.err"
pass 'start refuses invalid context preflight before launch'
cp "$TMPROOT/roles-before-rules.yaml" .orbit/roles.yaml
ORBIT_INSTANCE=reviewer-main "$CLI" rules resolve --task "$TASK" --json --output "$TMPROOT/current-rule-resolution.json" >/dev/null

APPEND_EVIDENCE="$TMPROOT/append-evidence.json"
"$CLI" evidence init --output "$APPEND_EVIDENCE" >"$TMPROOT/evidence-init.out" 2>"$TMPROOT/evidence-init.err"
test ! -s "$TMPROOT/evidence-init.err"
json_assert 'evidence init writes empty manifest' "$APPEND_EVIDENCE" 'j["schema_version"] == "orbit-evidence-v1" && j["project"] == File.basename(Dir.pwd) && j["records"].is_a?(Array) && j["records"].empty?'
json_assert 'evidence init initializes runtime evidence fields' "$APPEND_EVIDENCE" 'j["worktree_safety"]["status"] == "not_applicable" && j["regression_guard"]["status"] == "not_applicable" && j["release_surface"]["status"] == "not_applicable" && j["rule_resolution"]["file"] == "" && j["tool_calls"].is_a?(Array)'
NOTICE_EVIDENCE="$TMPROOT/notice-evidence.json"
"$CLI" evidence init --output "$NOTICE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/notice-review-pass.yaml" "Notice review passed." "herdr:reviewer:notice-pass"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$NOTICE_EVIDENCE" --report "$TMPROOT/notice-review-pass.yaml" --task "$TASK" --json >/dev/null
ORBIT_INSTANCE=reviewer-main "$CLI" notice add --task "$TASK" --event review_complete --evidence "$NOTICE_EVIDENCE" --json >"$TMPROOT/review-notice-add.json"
json_assert 'notice add writes review completion to owner inbox' "$TMPROOT/review-notice-add.json" 'j["schema_version"] == "orbit-notice-v1" && j["event"] == "review_complete" && j["from_role"] == "reviewer" && j["from_instance"] == "reviewer-main" && j["to_role"] == "lead" && j["to_instance"] == "lead-main" && j["status"] == "open" && j["evidence_ref"].is_a?(String) && j.dig("evidence_record","record_sha256").is_a?(String)'
"$CLI" notice list --role lead --json >"$TMPROOT/review-notice-list.json"
json_assert 'notice list reads owner runtime inbox' "$TMPROOT/review-notice-list.json" 'j["schema_version"] == "orbit-notice-list-v1" && j["role"] == "lead" && j["notices"].any? { |n| n["event"] == "review_complete" && n["to_instance"] == "lead-main" }'
ruby --disable-gems -rjson -e 'j=JSON.parse(File.read(ARGV[0])); File.write(ARGV[1], j.fetch("id"))' "$TMPROOT/review-notice-add.json" "$TMPROOT/review-notice-id.txt"
expect_failure 'notice ack rejects non-recipient identity' env ORBIT_INSTANCE=tester-main "$CLI" notice ack --role lead --id "$(cat "$TMPROOT/review-notice-id.txt")" --json
ORBIT_INSTANCE=lead-main "$CLI" notice ack --role lead --id "$(cat "$TMPROOT/review-notice-id.txt")" --json >"$TMPROOT/review-notice-ack.json"
json_assert 'notice ack records owner identity' "$TMPROOT/review-notice-ack.json" 'j["status"] == "acked" && j["acked_by_role"] == "lead" && j["acked_by_instance"] == "lead-main"'
expect_failure 'notice completion events require evidence manifest' env ORBIT_INSTANCE=reviewer-main "$CLI" notice add --task "$TASK" --event review_complete --json
expect_failure 'notice rejects explicit target instance mismatch' env ORBIT_INSTANCE=reviewer-main "$CLI" notice add --task "$TASK" --event review_complete --evidence "$NOTICE_EVIDENCE" --to-instance reviewer-main --json
cat >"$TMPROOT/hook-delete-runtime.json" <<'JSON'
{"command":["rm","-rf",".orbit/runtime"]}
JSON
"$CLI" hook pre-command --intent-json "$TMPROOT/hook-delete-runtime.json" --json >"$TMPROOT/hook-delete-runtime.out"
json_assert 'hook pre-command blocks direct runtime deletion' "$TMPROOT/hook-delete-runtime.out" 'j["allowed"] == false && j["blocked_reasons"].include?("direct_orbit_runtime_delete")'
expect_failure 'hook fails closed without intent json' "$CLI" hook pre-edit --json
cp .orbit/instances.yaml "$TMPROOT/hook-pre-start-instances-before.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["reviewer-main"]["binding"]={"adapter"=>"herdr","pane"=>"hook-pane","canonical_pane"=>"hook-pane"}; File.write(p, YAML.dump(y))' .orbit/instances.yaml
cat >"$TMPROOT/fakebin/herdr" <<'HERDR'
#!/usr/bin/env bash
case "$*" in
  "agent list")
    printf '%s\n' '{"agents":[{"pane_id":"hook-pane","agent_status":"working","client":"codex","cwd":"'"$PWD"'","cols":80,"rows":24}]}'
    ;;
  *) exit 1 ;;
esac
HERDR
chmod +x "$TMPROOT/fakebin/herdr"
cat >"$TMPROOT/hook-pre-start-narrow.json" <<'JSON'
{"command":["orbit","start","reviewer-main"],"observed_geometry":{"cols":220,"rows":80},"view":{"min_columns":10,"min_rows":10},"live_probe":{"decision":"reuse"}}
JSON
PATH="$TMPROOT/fakebin:$PATH" "$CLI" hook pre-start --intent-json "$TMPROOT/hook-pre-start-narrow.json" --json >"$TMPROOT/hook-pre-start-narrow.out"
json_assert 'hook pre-start ignores caller geometry and uses Orbit Herdr probe' "$TMPROOT/hook-pre-start-narrow.out" 'j["allowed"] == true && j["recommended_action"] == "resize_or_recreate_view" && j["warnings"].include?("pane_too_narrow") && j["warnings"].include?("caller_supplied_liveness_ignored") && j.dig("target_instance_status","view_status","observed_geometry","cols") == 80'
cp "$TMPROOT/hook-pre-start-instances-before.yaml" .orbit/instances.yaml
mkdir -p .orbit/runtime/replacements
ruby --disable-gems -rjson -rtime -e 'p=ARGV[0]; j={"schema_version"=>"orbit-start-replacement-v1","instance"=>"reviewer-main","replaced_at"=>Time.now.utc.iso8601}; File.write(p, JSON.pretty_generate(j))' .orbit/runtime/replacements/reviewer-main.json
cat >"$TMPROOT/hook-force-cooldown.json" <<'JSON'
{"command":["orbit","start","reviewer-main","--force"]}
JSON
"$CLI" hook pre-command --intent-json "$TMPROOT/hook-force-cooldown.json" --json >"$TMPROOT/hook-force-cooldown.out"
json_assert 'hook pre-command blocks repeated force during cooldown' "$TMPROOT/hook-force-cooldown.out" 'j["allowed"] == false && j["blocked_reasons"].include?("start_force_cooldown") && j["warnings"].include?("recent_force_replacement") && j["recommended_action"] == "wait_or_reuse_existing_replacement" && j.dig("force_cooldown","instance") == "reviewer-main"'
expect_failure 'wait-gate fails before required review evidence' "$CLI" wait-gate --task "$TASK" --evidence "$APPEND_EVIDENCE" --json
expect_failure 'lead cannot submit review evidence' env ORBIT_INSTANCE=lead-main "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "lead review attempt"
expect_failure 'lead cannot submit test evidence' env ORBIT_INSTANCE=lead-main "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind test --status pass --summary "lead test attempt"
expect_failure 'client mismatch cannot submit review evidence' env ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_CLIENT=opencode "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "client mismatch review attempt"
expect_failure 'reviewer cannot evidence add review verdict without structured submit' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind review --status pass --summary "reviewer add review pass attempt"
expect_failure 'tester cannot evidence add test verdict without structured submit' env ORBIT_INSTANCE=tester-main "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind test --status pass --summary "tester add test pass attempt"
cat >"$TMPROOT/review-report.md" <<'REPORT'
APPROVED
review report confirms the implementation is acceptable.
REPORT
expect_failure 'evidence from-report rejects markdown review pass' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-report.md" --json
printf '%s\n' 'APPROVED_WITH_NOTES' 'notes are not an automatic pass token.' >"$TMPROOT/review-with-notes-report.md"
expect_failure 'evidence from-report rejects non-contract verdict token' "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/review-with-notes-report.md" --json
cat >"$TMPROOT/from-report-status-alias.yaml" <<'YAML'
kind: command
status: pass
summary: status alias must not infer verdict
YAML
expect_failure 'evidence from-report rejects status alias inference' "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/from-report-status-alias.yaml" --json
printf '%s\n' 'PASS implementation imported from report.' >"$TMPROOT/implementation-report.md"
expect_failure 'evidence from-report rejects implementation evidence writer' "$CLI" evidence from-report --file "$APPEND_EVIDENCE" --report "$TMPROOT/implementation-report.md" --kind implementation --status pass --json

STRUCTURED_REVIEW_EVIDENCE="$TMPROOT/structured-review-evidence.json"
"$CLI" evidence init --output "$STRUCTURED_REVIEW_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
expect_failure 'lead cannot structured submit review evidence' env ORBIT_INSTANCE=lead-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --task "$TASK" --json
cp "$TMPROOT/structured-review.yaml" "$TMPROOT/structured-review-status-only.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["status"]=y.delete("verdict"); File.write(p, YAML.dump(y))' "$TMPROOT/structured-review-status-only.yaml"
expect_failure 'evidence submit rejects structured report using status instead of verdict' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review-status-only.yaml" --task "$TASK" --json
cp "$TMPROOT/structured-review.yaml" "$TMPROOT/structured-review-missing-kind.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("kind"); File.write(p, YAML.dump(y))' "$TMPROOT/structured-review-missing-kind.yaml"
expect_failure 'evidence submit rejects structured report missing kind' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review-missing-kind.yaml" --task "$TASK" --json
cp "$TMPROOT/structured-review.yaml" "$TMPROOT/structured-review-missing-findings.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("findings"); File.write(p, YAML.dump(y))' "$TMPROOT/structured-review-missing-findings.yaml"
expect_failure 'evidence submit rejects structured report missing findings' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review-missing-findings.yaml" --task "$TASK" --json
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --task "$TASK" --json >"$TMPROOT/evidence-submit-review.json"
json_assert 'evidence submit records structured review verdict' "$TMPROOT/evidence-submit-review.json" 'j["schema_version"] == "orbit-evidence-submit-v1" && j["record"]["structured_submit"] == true && j["record"]["source_message_id"] == "herdr:reviewer:structured-pass" && j["record"]["coverage"].include?("review checked aggregate verdict behavior") && j["record"]["runtime_identity"]["verification"] == "manual_runtime" && j["record"]["runtime_identity"]["source"] == "current_process" && j["verdict"]["mode"] == "aggregate" && j["verdict"]["gates"]["review"]["structured"] == true'
HERDR_ENV_EVIDENCE="$TMPROOT/herdr-env-review-evidence.json"
"$CLI" evidence init --output "$HERDR_ENV_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer-main HERDR_PANE_ID=dispatch-live-pane "$CLI" evidence submit --file "$HERDR_ENV_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --task "$TASK" --json >"$TMPROOT/evidence-submit-review-herdr-env.json"
json_assert 'evidence submit without Orbit session does not borrow Herdr verified runtime from env' "$TMPROOT/evidence-submit-review-herdr-env.json" 'j["record"]["runtime_identity"]["verification"] == "identity_pending" && j["record"]["runtime_identity"]["reason"] == "unbound_herdr_session"'
if "$CLI" wait-gate --task "$TASK" --evidence "$HERDR_ENV_EVIDENCE" --json >"$TMPROOT/herdr-env-wait-gate.json"; then
  printf 'FAIL wait-gate Herdr env without Orbit session: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'wait-gate rejects Herdr env evidence without Orbit session proof' "$TMPROOT/herdr-env-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "runtime_identity_identity_pending" }'
SPOOFED_SESSION_EVIDENCE="$TMPROOT/spoofed-session-review-evidence.json"
"$CLI" evidence init --output "$SPOOFED_SESSION_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer ORBIT_SESSION_ID=ors-dispatch-live ORBIT_LAUNCH_ID=orl-dispatch-live HERDR_PANE_ID=dispatch-live-pane "$CLI" evidence submit --file "$SPOOFED_SESSION_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --task "$TASK" --json >"$TMPROOT/evidence-submit-review-spoofed-session.json"
json_assert 'evidence submit with spoofable Orbit session env does not claim Herdr verified runtime' "$TMPROOT/evidence-submit-review-spoofed-session.json" 'j["record"]["runtime_identity"]["verification"] == "mismatch" && j["record"]["runtime_identity"]["reason"] == "session_not_active_herdr_verified"'
if "$CLI" wait-gate --task "$TASK" --evidence "$SPOOFED_SESSION_EVIDENCE" --json >"$TMPROOT/spoofed-session-wait-gate.json"; then
  printf 'FAIL wait-gate spoofed Orbit session env: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'wait-gate rejects spoofable Orbit session env evidence' "$TMPROOT/spoofed-session-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "runtime_identity_mismatch" }'
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/missing-runtime-identity-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec.delete("runtime_identity"); File.write(p, JSON.pretty_generate(j))' "$TMPROOT/missing-runtime-identity-evidence.json"
expect_failure 'validate rejects missing runtime identity gate evidence under default policy' "$CLI" validate --task "$TASK" --evidence "$TMPROOT/missing-runtime-identity-evidence.json" --json
if "$CLI" wait-gate --task "$TASK" --evidence "$TMPROOT/missing-runtime-identity-evidence.json" --json >"$TMPROOT/missing-runtime-identity-wait-gate.json"; then
  printf 'FAIL wait-gate missing runtime_identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'wait-gate rejects missing runtime identity gate evidence' "$TMPROOT/missing-runtime-identity-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == false && g["blocking_reason"] == "runtime_identity_missing" }'
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/malformed-runtime-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["runtime_identity"]="bad-shape"; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/malformed-runtime-evidence.json"
if "$CLI" validate --task "$TASK" --evidence "$TMPROOT/malformed-runtime-evidence.json" --json >"$TMPROOT/malformed-runtime-validate.json" 2>"$TMPROOT/malformed-runtime-validate.err"; then
  printf 'FAIL validate malformed runtime_identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -s "$TMPROOT/malformed-runtime-validate.err"
json_assert 'validate reports malformed runtime identity structurally' "$TMPROOT/malformed-runtime-validate.json" 'j["valid"] == false && j["errors"].any? { |e| e["source"].include?("runtime_identity") && e["message"].include?("must be a mapping") }'
if "$CLI" wait-gate --task "$TASK" --evidence "$TMPROOT/malformed-runtime-evidence.json" --json >"$TMPROOT/malformed-runtime-wait-gate.json" 2>"$TMPROOT/malformed-runtime-wait-gate.err"; then
  printf 'FAIL wait-gate malformed runtime_identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -s "$TMPROOT/malformed-runtime-wait-gate.err"
json_assert 'wait-gate reports malformed runtime identity without crashing' "$TMPROOT/malformed-runtime-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == false && g["blocking_reason"] == "runtime_identity_malformed" }'
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/bogus-runtime-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["runtime_identity"]={"verification"=>"bogus","source"=>"test"}; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/bogus-runtime-evidence.json"
expect_failure 'validate rejects unknown runtime identity gate evidence under default policy' "$CLI" validate --task "$TASK" --evidence "$TMPROOT/bogus-runtime-evidence.json" --json
if "$CLI" wait-gate --task "$TASK" --evidence "$TMPROOT/bogus-runtime-evidence.json" --json >"$TMPROOT/bogus-runtime-wait-gate.json"; then
  printf 'FAIL wait-gate bogus runtime_identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'wait-gate rejects unknown runtime identity gate evidence' "$TMPROOT/bogus-runtime-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == false && g["runtime_identity_verification"] == "bogus" && g["blocking_reason"] == "runtime_identity_bogus" }'
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/handwritten-herdr-verified-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["runtime_identity"]={"verification"=>"herdr_verified","session_id"=>"ors-handwritten","source"=>"test"}; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/handwritten-herdr-verified-evidence.json"
expect_failure 'validate rejects handwritten herdr_verified runtime identity under default policy' "$CLI" validate --task "$TASK" --evidence "$TMPROOT/handwritten-herdr-verified-evidence.json" --json
if "$CLI" wait-gate --task "$TASK" --evidence "$TMPROOT/handwritten-herdr-verified-evidence.json" --json >"$TMPROOT/handwritten-herdr-verified-wait-gate.json"; then
  printf 'FAIL wait-gate handwritten herdr_verified runtime_identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'wait-gate rejects handwritten herdr_verified runtime identity under default policy' "$TMPROOT/handwritten-herdr-verified-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == false && g["runtime_identity_verification"] == "herdr_verified" && g["blocking_reason"] == "runtime_identity_herdr_verified_untrusted" }'
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/replaced-runtime-evidence.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["runtime_identity"]={"verification"=>"replaced","session_id"=>"ors-replaced","source"=>"test"}; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/replaced-runtime-evidence.json"
expect_failure 'validate rejects replaced runtime gate evidence under default policy' "$CLI" validate --task "$TASK" --evidence "$TMPROOT/replaced-runtime-evidence.json" --json
if "$CLI" wait-gate --task "$TASK" --evidence "$TMPROOT/replaced-runtime-evidence.json" --json >"$TMPROOT/replaced-runtime-wait-gate.json"; then
  printf 'FAIL wait-gate replaced runtime: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'wait-gate rejects replaced runtime gate evidence' "$TMPROOT/replaced-runtime-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == false && g["runtime_identity_verification"] == "replaced" && g["blocking_reason"] == "runtime_identity_replaced" } && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "runtime_identity_replaced" }'
ruby --disable-gems -ryaml -e 'task,evidence,state=ARGV; y={"schema_version"=>"orbit-loop-state-v1","project"=>File.basename(Dir.pwd),"current_task"=>File.expand_path(task),"phase"=>"done","owner_role"=>"lead","status"=>"done","updated_at"=>"2026-01-01T00:00:00Z","history"=>[],"budget"=>{},"quality_outcome_ref"=>nil,"artifacts"=>{"evidence_file"=>File.expand_path(evidence)}}; File.write(state, YAML.dump(y))' "$TASK" "$TMPROOT/replaced-runtime-evidence.json" "$TMPROOT/replaced-runtime-state.yaml"
if "$CLI" audit --task "$TASK" --evidence "$TMPROOT/replaced-runtime-evidence.json" --state "$TMPROOT/replaced-runtime-state.yaml" --json >"$TMPROOT/replaced-runtime-audit.json"; then
  printf 'FAIL audit replaced runtime: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit rejects replaced runtime gate evidence' "$TMPROOT/replaced-runtime-audit.json" 'j["blocking_findings"].any? { |f| f["source"] == "evidence_file.records.review" && f["message"].include?("runtime_identity_replaced") }'
"$CLI" handoff --task "$TASK" --evidence "$TMPROOT/replaced-runtime-evidence.json" --state "$TMPROOT/replaced-runtime-state.yaml" --json >"$TMPROOT/replaced-runtime-handoff.json" 2>/dev/null || true
json_assert 'handoff does not surface replaced runtime gate as pass' "$TMPROOT/replaced-runtime-handoff.json" 'j["gate_summary"]["ready"] == false && j.dig("latest_gate_verdicts","review","status") == "blocked" && j.dig("latest_gate_verdicts","review","blocking_reason") == "runtime_identity_replaced"'
cp "$TASK" "$TMPROOT/strict-runtime-task.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["runtime_identity_policy"]={"gate"=>"herdr_verified"}; File.write(p, YAML.dump(y))' "$TMPROOT/strict-runtime-task.yaml"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/strict-runtime-manual-evidence.json"
ruby --disable-gems -rjson -rdigest -e 'p,t=ARGV; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["role_execution_context"]["task_sha256"]=Digest::SHA256.file(t).hexdigest; rec["runtime_identity"]={"verification"=>"manual_runtime","source"=>"test"}; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/strict-runtime-manual-evidence.json" "$TMPROOT/strict-runtime-task.yaml"
expect_failure 'validate blocks manual runtime gate evidence under strict Herdr policy' "$CLI" validate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-manual-evidence.json" --json
"$CLI" validate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-manual-evidence.json" --json >"$TMPROOT/strict-runtime-manual-validate.json" 2>/dev/null || true
json_assert 'strict runtime validation reports runtime identity blocker' "$TMPROOT/strict-runtime-manual-validate.json" 'j["valid"] == false && j["errors"].any? { |e| e["source"].include?("runtime_identity") && e["message"].include?("Herdr-verified") }'
cp "$STRUCTURED_REVIEW_EVIDENCE" "$TMPROOT/strict-runtime-handwritten-herdr-verified-evidence.json"
ruby --disable-gems -rjson -rdigest -e 'p,t=ARGV; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["role_execution_context"]["task_sha256"]=Digest::SHA256.file(t).hexdigest; rec["runtime_identity"]={"verification"=>"herdr_verified","session_id"=>"ors-handwritten","source"=>"test"}; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/strict-runtime-handwritten-herdr-verified-evidence.json" "$TMPROOT/strict-runtime-task.yaml"
expect_failure 'validate blocks handwritten herdr_verified gate evidence under strict Herdr policy' "$CLI" validate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-handwritten-herdr-verified-evidence.json" --json
if "$CLI" wait-gate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-handwritten-herdr-verified-evidence.json" --json >"$TMPROOT/strict-runtime-handwritten-herdr-verified-wait-gate.json"; then
  printf 'FAIL wait-gate strict handwritten herdr_verified runtime_identity: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'wait-gate blocks handwritten herdr_verified gate evidence under strict Herdr policy' "$TMPROOT/strict-runtime-handwritten-herdr-verified-wait-gate.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == false && g["runtime_identity_verification"] == "herdr_verified" && g["blocking_reason"] == "runtime_identity_herdr_verified_untrusted" }'
cp "$TMPROOT/strict-runtime-manual-evidence.json" "$TMPROOT/strict-runtime-waived-evidence.json"
ruby --disable-gems -rjson -rtime -rdigest -e '
  def canonical(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, memo| memo[key] = canonical(value[key]) }
    when Array
      value.map { |entry| canonical(entry) }
    else
      value
    end
  end
  p = ARGV[0]
  j = JSON.parse(File.read(p))
  rec = j["records"].find { |r| r["kind"] == "review" && r["status"] == "pass" }
  sha = Digest::SHA256.hexdigest(JSON.generate(canonical(rec)))
  j["waivers"] ||= []
  j["waivers"] << {
    "schema_version" => "orbit-runtime-identity-waiver-v1",
    "waiver_id" => "runtime-waiver-review",
    "owner_role" => "lead",
    "owner_instance" => "lead-main",
    "accepted_by_role" => "lead",
    "accepted_by_instance" => "lead-main",
    "scope" => "runtime_identity:review",
    "reason" => "Manual evidence accepted for strict runtime policy test.",
    "risk" => "Evidence was not Herdr-verified.",
    "replacement_evidence" => sha,
    "task_sha256" => Digest::SHA256.file(ARGV[1]).hexdigest,
    "evidence_record_sha256" => sha,
    "no_expiry" => true,
    "created_at" => Time.now.utc.iso8601,
    "revoked_by_user_requirement" => false
  }
  File.write(p, JSON.pretty_generate(j))
' "$TMPROOT/strict-runtime-waived-evidence.json" "$TMPROOT/strict-runtime-task.yaml"
"$CLI" validate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-waived-evidence.json" --json >"$TMPROOT/strict-runtime-waived-validate.json"
json_assert 'validate accepts manual runtime gate evidence with explicit runtime waiver' "$TMPROOT/strict-runtime-waived-validate.json" 'j["valid"] == true'
cp "$TMPROOT/strict-runtime-waived-evidence.json" "$TMPROOT/strict-runtime-bogus-waived-evidence.json"
ruby --disable-gems -rjson -rtime -rdigest -e '
  def canonical(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, memo| memo[key] = canonical(value[key]) }
    when Array
      value.map { |entry| canonical(entry) }
    else
      value
    end
  end
  p = ARGV[0]
  j = JSON.parse(File.read(p))
  rec = j["records"].find { |r| r["kind"] == "review" && r["status"] == "pass" }
  rec["runtime_identity"] = {"verification"=>"bogus","source"=>"test"}
  sha = Digest::SHA256.hexdigest(JSON.generate(canonical(rec)))
  j["waivers"][0]["replacement_evidence"] = sha
  j["waivers"][0]["evidence_record_sha256"] = sha
  File.write(p, JSON.pretty_generate(j))
' "$TMPROOT/strict-runtime-bogus-waived-evidence.json"
expect_failure 'validate rejects unknown runtime identity even with explicit runtime waiver' "$CLI" validate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-bogus-waived-evidence.json" --json
cp "$TMPROOT/strict-runtime-waived-evidence.json" "$TMPROOT/strict-runtime-waiver-missing-reason.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["waivers"][0].delete("reason"); File.write(p, JSON.pretty_generate(j))' "$TMPROOT/strict-runtime-waiver-missing-reason.json"
expect_failure 'validate rejects runtime waiver missing reason under strict Herdr policy' "$CLI" validate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-waiver-missing-reason.json" --json
cp "$TMPROOT/strict-runtime-waived-evidence.json" "$TMPROOT/strict-runtime-waiver-expired.json"
ruby --disable-gems -rjson -rtime -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["waivers"][0].delete("no_expiry"); j["waivers"][0]["expires_at"]=(Time.now.utc - 60).iso8601; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/strict-runtime-waiver-expired.json"
expect_failure 'validate rejects expired runtime waiver under strict Herdr policy' "$CLI" validate --task "$TMPROOT/strict-runtime-task.yaml" --evidence "$TMPROOT/strict-runtime-waiver-expired.json" --json
cat >"$TMPROOT/review-missing-quality-outcome.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
expect_failure 'evidence submit rejects review pass without quality_outcome_verdict' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-missing-quality-outcome.yaml" --task "$TASK" --json
cat >"$TMPROOT/review-high-finding-incomplete.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
expect_failure 'evidence submit rejects high finding missing remedy fields' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-high-finding-incomplete.yaml" --task "$TASK" --json
cat >"$TMPROOT/malformed-structured-review.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
if env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/malformed-structured-review.yaml" --task "$TASK" --json >"$TMPROOT/malformed-submit.out" 2>"$TMPROOT/malformed-submit.err"; then
  printf 'FAIL evidence submit rejects malformed coverage entries before gate: command unexpectedly succeeded\n' >&2
  exit 1
fi
cmp "$TMPROOT/structured-review-before-malformed.json" "$STRUCTURED_REVIEW_EVIDENCE"
grep -q 'field: submit_report.coverage' "$TMPROOT/malformed-submit.err"
grep -q 'expected: list of non-empty strings' "$TMPROOT/malformed-submit.err"
grep -q 'actual: array<mapping>' "$TMPROOT/malformed-submit.err"
grep -q 'template: assets/templates/review-report.yaml' "$TMPROOT/malformed-submit.err"
pass 'evidence submit rejects malformed coverage entries before gate'
PASS_REVIEW_EMPTY_BLOCKED_EVIDENCE="$TMPROOT/pass-review-empty-blocked-evidence.json"
"$CLI" evidence init --output "$PASS_REVIEW_EMPTY_BLOCKED_EVIDENCE" >/dev/null
cp "$TMPROOT/structured-review.yaml" "$TMPROOT/structured-review-empty-blocked.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["blocked"]={"reason"=>"","next_step"=>"","owner"=>""}; File.write(p, YAML.dump(y))' "$TMPROOT/structured-review-empty-blocked.yaml"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$PASS_REVIEW_EMPTY_BLOCKED_EVIDENCE" --report "$TMPROOT/structured-review-empty-blocked.yaml" --task "$TASK" --json >"$TMPROOT/pass-review-empty-blocked-submit.json"
json_assert 'review PASS ignores empty blocked placeholder' "$TMPROOT/pass-review-empty-blocked-submit.json" 'j["record"]["kind"] == "review" && j["record"]["status"] == "pass" && !j["record"].key?("blocked")'
"$CLI" wait-gate --task "$TASK" --evidence "$STRUCTURED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-structured-review-pass.json"
json_assert 'wait-gate passes after structured review submit' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["passed"] == true && g["structured"] == true }'
json_assert 'wait-gate exposes role-authorized gate summary' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["gate_summary"]["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["identity_expected_role"] == "reviewer" && g["identity_resolved_role"] == "reviewer" && g["identity_valid"] == true }'
json_assert 'wait-gate exposes review evidence quality summary' "$TMPROOT/wait-gate-structured-review-pass.json" 'j["gate_summary"]["evidence_levels"]["review"] == "outcome_quality" && j["gates"].any? { |g| g["kind"] == "review" && g["evidence_level"] == "outcome_quality" && g["quality_outcome_verdict"] == "pass" && g["rule_application_summary"]["applied_checks_count"] == 1 && g["evidence_boundary_summary"]["confirmed_count"] == 1 }'
BAD_IMPL_GATE_EVIDENCE="$TMPROOT/bad-impl-gate-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$BAD_IMPL_GATE_EVIDENCE"
ruby --disable-gems -rjson -rdigest -rtime -e 'p,t=ARGV; j=JSON.parse(File.read(p)); j["records"] << {"kind"=>"implementation","status"=>"pass","summary"=>"lead crossed into delegated implementation","created_at"=>Time.now.utc.iso8601,"role_execution_context"=>{"owner_role"=>"lead","owner_instance"=>"lead-main","operation_mode"=>"team","implementation_authority"=>"reviewer","assigned_instance"=>"reviewer-main","resolved_role"=>"lead","resolved_instance"=>"lead-main","execution_contract_source"=>"explicit_override","task_sha256"=>Digest::SHA256.file(t).hexdigest}}; File.write(p, JSON.pretty_generate(j))' "$BAD_IMPL_GATE_EVIDENCE" "$TASK"
if "$CLI" wait-gate --task "$TASK" --evidence "$BAD_IMPL_GATE_EVIDENCE" --json >"$TMPROOT/wait-gate-bad-impl.json" 2>/dev/null; then
  printf 'FAIL wait-gate blocks implementation role boundary violations: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate blocks implementation role boundary violations'
json_assert 'wait-gate reports implementation context errors' "$TMPROOT/wait-gate-bad-impl.json" 'j["ready"] == false && j["implementation_context_errors"].any? { |e| e["source"].include?("role_execution_context.resolved_role") } && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "implementation" && g["blocking_reason"] == "implementation_context_invalid" }'

for field in evidence_level rule_application quality_question_answers confirmed assumed missing counterexample_cases; do
  cp "$TMPROOT/structured-review.yaml" "$TMPROOT/review-missing-${field}.yaml"
  ruby --disable-gems -ryaml -e 'p=ARGV[0]; field=ARGV[1]; y=YAML.safe_load(File.read(p), aliases: true); y.delete(field); File.write(p, YAML.dump(y))' "$TMPROOT/review-missing-${field}.yaml" "$field"
  expect_failure "evidence submit rejects review pass without ${field}" env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-missing-${field}.yaml" --task "$TASK" --json
done

cp "$TMPROOT/structured-review.yaml" "$TMPROOT/review-implementation-readiness-blocked.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="implementation_readiness"; y["implementation_readiness_verdict"]="blocked"; File.write(p, YAML.dump(y))' "$TMPROOT/review-implementation-readiness-blocked.yaml"
expect_failure 'evidence submit rejects implementation_readiness review without readiness pass' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STRUCTURED_REVIEW_EVIDENCE" --report "$TMPROOT/review-implementation-readiness-blocked.yaml" --task "$TASK" --json

MIN_OUTCOME_TASK="$TMPROOT/min-outcome-task.yaml"
cp "$TASK" "$MIN_OUTCOME_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["review_strategy"] ||= {}; y["review_strategy"]["minimum_evidence_level"]="outcome_quality"; File.write(p, YAML.dump(y))' "$MIN_OUTCOME_TASK"
"$CLI" wait-gate --task "$MIN_OUTCOME_TASK" --evidence "$STRUCTURED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-min-outcome-pass.json"
json_assert 'minimum outcome_quality accepts outcome review evidence' "$TMPROOT/wait-gate-min-outcome-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "review" && g["minimum_evidence_level"] == "outcome_quality" && g["evidence_level"] == "outcome_quality" }'

MECHANICAL_REVIEW_EVIDENCE="$TMPROOT/mechanical-review-evidence.json"
"$CLI" evidence init --output "$MECHANICAL_REVIEW_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/mechanical-review-pass.yaml" "Mechanical review passed." "herdr:reviewer:mechanical"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="mechanical_check"; File.write(p, YAML.dump(y))' "$TMPROOT/mechanical-review-pass.yaml"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$MECHANICAL_REVIEW_EVIDENCE" --report "$TMPROOT/mechanical-review-pass.yaml" --task "$MIN_OUTCOME_TASK" --json >/dev/null
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
MIN_IMPL_OUTCOME_EVIDENCE="$TMPROOT/min-impl-outcome-review-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$MIN_IMPL_OUTCOME_EVIDENCE"
ruby --disable-gems -rjson -rdigest -e 'p,t=ARGV; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["role_execution_context"]["task_sha256"]=Digest::SHA256.file(t).hexdigest; File.write(p, JSON.pretty_generate(j))' "$MIN_IMPL_OUTCOME_EVIDENCE" "$MIN_IMPL_TASK"
if "$CLI" wait-gate --task "$MIN_IMPL_TASK" --evidence "$MIN_IMPL_OUTCOME_EVIDENCE" --json >"$TMPROOT/wait-gate-min-impl-blocked.json"; then
  printf 'FAIL wait-gate rejects outcome review below implementation readiness: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate rejects outcome review below implementation readiness'
json_assert 'wait-gate reports implementation readiness minimum blocker' "$TMPROOT/wait-gate-min-impl-blocked.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["blocking_reason"] == "evidence_level_below_minimum" && g["evidence_level"] == "outcome_quality" && g["minimum_evidence_level"] == "implementation_readiness" }'

IMPLEMENTATION_READY_EVIDENCE="$TMPROOT/implementation-ready-review-evidence.json"
"$CLI" evidence init --output "$IMPLEMENTATION_READY_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/implementation-ready-review-pass.yaml" "Implementation readiness review passed." "herdr:reviewer:implementation-ready"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["evidence_level"]="implementation_readiness"; y["implementation_readiness_verdict"]="pass"; File.write(p, YAML.dump(y))' "$TMPROOT/implementation-ready-review-pass.yaml"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$IMPLEMENTATION_READY_EVIDENCE" --report "$TMPROOT/implementation-ready-review-pass.yaml" --task "$MIN_IMPL_TASK" --json >/dev/null
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
json_assert 'wait-gate reports missing identity as fail-closed blocker' "$TMPROOT/wait-gate-missing-identity.json" 'j["ready"] == false && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && ["identity_mismatch","missing_task_sha256","stale_verdict"].include?(g["blocking_reason"]) } && j["gates"].any? { |g| g["kind"] == "review" && g["identity_resolved_role"].nil? && g["identity_valid"] == false }'
MISSING_QO_EVIDENCE="$TMPROOT/missing-quality-outcome-evidence.json"
cp "$STRUCTURED_REVIEW_EVIDENCE" "$MISSING_QO_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"].last.delete("quality_outcome_verdict"); File.write(p, JSON.pretty_generate(j))' "$MISSING_QO_EVIDENCE"
expect_failure 'validate rejects hand-written structured review without quality_outcome_verdict' "$CLI" validate --task "$TASK" --evidence "$MISSING_QO_EVIDENCE" --json

BLOCKED_REVIEW_EVIDENCE="$TMPROOT/blocked-review-evidence.json"
"$CLI" evidence init --output "$BLOCKED_REVIEW_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review-blocked.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$BLOCKED_REVIEW_EVIDENCE" --report "$TMPROOT/structured-review-blocked.yaml" --task "$TASK" --json >"$TMPROOT/evidence-submit-blocked-review.json"
json_assert 'evidence submit records blocked detail as partial verdict' "$TMPROOT/evidence-submit-blocked-review.json" 'j["record"]["status"] == "partial" && j["record"]["blocked"]["reason"] == "acceptance criteria are ambiguous" && j["verdict"]["gates"]["review"]["blocked"]["owner"] == "lead"'
if "$CLI" wait-gate --task "$TASK" --evidence "$BLOCKED_REVIEW_EVIDENCE" --json >"$TMPROOT/wait-gate-blocked-review.json" 2>"$TMPROOT/wait-gate-blocked-review.err"; then
  printf 'FAIL wait-gate reports blocked structured review evidence: command unexpectedly succeeded\n' >&2
  exit 1
fi
pass 'wait-gate reports blocked structured review evidence'
json_assert 'wait-gate includes blocked detail in gate status' "$TMPROOT/wait-gate-blocked-review.json" 'j["ready"] == false && j["gates"].any? { |g| g["kind"] == "review" && g["status"] == "blocked" && g["record_status"] == "partial" && g["blocked"]["owner"] == "lead" } && j["gate_summary"]["not_ready"].any? { |g| g["kind"] == "review" && g["status"] == "blocked" }'
TEMPLATE_REVIEW_EVIDENCE="$TMPROOT/template-review-evidence.json"
"$CLI" evidence init --output "$TEMPLATE_REVIEW_EVIDENCE" >/dev/null
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$TEMPLATE_REVIEW_EVIDENCE" --report "$SKILL_ROOT/assets/templates/review-report.yaml" --task "$TASK" --json >"$TMPROOT/template-review-submit.json"
json_assert 'review report template is directly submittable as blocked evidence' "$TMPROOT/template-review-submit.json" 'j["record"]["kind"] == "review" && j["record"]["status"] == "partial" && j["record"]["blocked"]["owner"] == "lead" && j["record"]["findings"].all? { |f| f.is_a?(String) }'

AGGREGATE_EVIDENCE="$TMPROOT/aggregate-evidence.json"
"$CLI" evidence init --output "$AGGREGATE_EVIDENCE" >/dev/null
cat >"$TMPROOT/structured-review-fail.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$AGGREGATE_EVIDENCE" --report "$TMPROOT/structured-review-fail.yaml" --task "$TASK" --json >/dev/null
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
"$CLI" new-task --implementation-authority tester --assigned-instance tester-main --task-type implementation_test --output "$TEST_TASK" >/dev/null
yaml_assert 'new-task initializes test environment contract' "$TEST_TASK" 'j["test_environment"]["required"] == true && %w[environment test_tab_or_pane server_owner browser_owner cleanup_hook artifact_cleanup duration_budget resource_budget].all? { |k| j["test_environment"][k].is_a?(String) && !j["test_environment"][k].empty? }'
yaml_assert 'new-task initializes test level contract' "$TEST_TASK" 'j["test_level"] == "repo_regression"'
TEST_EVIDENCE="$TMPROOT/test-evidence.json"
"$CLI" evidence init --output "$TEST_EVIDENCE" >/dev/null
TEMPLATE_TEST_EVIDENCE="$TMPROOT/template-test-evidence.json"
"$CLI" evidence init --output "$TEMPLATE_TEST_EVIDENCE" >/dev/null
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$TEMPLATE_TEST_EVIDENCE" --report "$SKILL_ROOT/assets/templates/test-report.yaml" --task "$TEST_TASK" --json >"$TMPROOT/template-test-submit.json"
json_assert 'test report template is directly submittable as blocked evidence' "$TMPROOT/template-test-submit.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "partial" && j["record"]["blocked"]["owner"] == "lead" && j["record"]["test_environment"]["cleanup_status"].is_a?(String)'
cat >"$TMPROOT/test-report.yaml" <<'REPORT'
kind: test
report_template_version: test-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    schema_semantics: v1
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
expect_failure 'evidence from-report rejects structured test verdict' env ORBIT_INSTANCE=tester-main "$CLI" evidence from-report --file "$TEST_EVIDENCE" --report "$TMPROOT/test-report.yaml" --task "$TEST_TASK" --json
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$TEST_EVIDENCE" --report "$TMPROOT/test-report.yaml" --task "$TEST_TASK" --json >"$TMPROOT/evidence-submit-test-report.json"
json_assert 'evidence submit imports structured test verdict' "$TMPROOT/evidence-submit-test-report.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "pass" && j["record"]["summary"] == "Browser scenarios passed." && j["record"]["structured_submit"] == true && j["record"]["evidence_level"] == "real_path_test"'
PASS_TEST_NA_BLOCKED_EVIDENCE="$TMPROOT/pass-test-not-applicable-blocked-evidence.json"
"$CLI" evidence init --output "$PASS_TEST_NA_BLOCKED_EVIDENCE" >/dev/null
cp "$TMPROOT/test-report.yaml" "$TMPROOT/test-report-not-applicable-blocked.yaml"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["blocked"]={"reason"=>"not_applicable: verdict is pass","next_step"=>"not_applicable: verdict is pass","owner"=>"none"}; File.write(p, YAML.dump(y))' "$TMPROOT/test-report-not-applicable-blocked.yaml"
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$PASS_TEST_NA_BLOCKED_EVIDENCE" --report "$TMPROOT/test-report-not-applicable-blocked.yaml" --task "$TEST_TASK" --json >"$TMPROOT/pass-test-not-applicable-blocked-submit.json"
json_assert 'test PASS ignores not_applicable blocked placeholder' "$TMPROOT/pass-test-not-applicable-blocked-submit.json" 'j["record"]["kind"] == "test" && j["record"]["status"] == "pass" && !j["record"].key?("blocked")'
"$CLI" wait-gate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json >"$TMPROOT/wait-gate-test-pass.json"
json_assert 'wait-gate passes after imported test evidence' "$TMPROOT/wait-gate-test-pass.json" 'j["ready"] == true && j["gates"].any? { |g| g["kind"] == "test" && g["passed"] == true }'
expect_failure 'validate rejects passing test evidence without environment contract evidence' "$CLI" validate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json
cat >"$TMPROOT/complete-test-submit.yaml" <<'YAML'
kind: test
report_template_version: test-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    schema_semantics: v1
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
  expect_failure "evidence submit rejects test pass without ${field}" env ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$TEST_EVIDENCE" --report "$TMPROOT/test-missing-${field}.yaml" --task "$TEST_TASK" --json
done
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$TEST_EVIDENCE" --report "$TMPROOT/complete-test-submit.yaml" --task "$TEST_TASK" --json >"$TMPROOT/complete-test-submit.json"
"$CLI" validate --task "$TEST_TASK" --evidence "$TEST_EVIDENCE" --json >"$TMPROOT/valid-complete-test-env.json"
json_assert 'validate accepts passing test evidence with environment lifecycle' "$TMPROOT/valid-complete-test-env.json" 'j["valid"] == true'

CONCURRENT_EVIDENCE="$TMPROOT/concurrent-gate-evidence.json"
CONCURRENT_GATE_TASK="$TMPROOT/concurrent-gate-task.yaml"
"$CLI" new-task --task-type implementation --output "$CONCURRENT_GATE_TASK" >/dev/null
"$CLI" evidence init --output "$CONCURRENT_EVIDENCE" >/dev/null
(
  ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/structured-review.yaml" --task "$CONCURRENT_GATE_TASK" --json >"$TMPROOT/concurrent-review-submit.json"
) &
review_pid=$!
(
  ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/complete-test-submit.yaml" --task "$CONCURRENT_GATE_TASK" --json >"$TMPROOT/concurrent-test-submit.json"
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
ruby --disable-gems -rjson -rdigest -e 'p,t=ARGV; j=JSON.parse(File.read(p)); rec=j["records"].reverse.find { |r| r["kind"] == "test" && r["status"] == "pass" }; rec.delete("evidence_level"); rec["role_execution_context"]["task_sha256"]=Digest::SHA256.file(t).hexdigest; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/legacy-test-missing-evidence-level.json" "$MIN_TEST_TASK"
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
"$CLI" new-task --task-type implementation --output "$OPTIONAL_GATE_TASK" >/dev/null
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"].each { |g| g["required"]=false if g["kind"]=="test" }; File.write(p, YAML.dump(y))' "$OPTIONAL_GATE_TASK"
OPTIONAL_GATE_EVIDENCE="$TMPROOT/optional-gate-evidence.json"
"$CLI" evidence init --output "$OPTIONAL_GATE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/optional-review-pass.yaml" "Required review passed." "herdr:reviewer:optional-gate"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$OPTIONAL_GATE_EVIDENCE" --report "$TMPROOT/optional-review-pass.yaml" --task "$OPTIONAL_GATE_TASK" --json >/dev/null
"$CLI" wait-gate --task "$OPTIONAL_GATE_TASK" --evidence "$OPTIONAL_GATE_EVIDENCE" --json >"$TMPROOT/wait-gate-optional-pass.json"
json_assert 'wait-gate ignores optional gates' "$TMPROOT/wait-gate-optional-pass.json" 'j["ready"] == true && j["gates"].map { |g| g["kind"] } == ["review"]'
expect_failure 'evidence init refuses overwrite' "$CLI" evidence init --output "$APPEND_EVIDENCE"
write_review_pass_report "$TMPROOT/append-review-pass.yaml" "Review passed." "herdr:reviewer:append-review"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$APPEND_EVIDENCE" --report "$TMPROOT/append-review-pass.yaml" --task "$TASK" --json >"$TMPROOT/evidence-add-review.out" 2>"$TMPROOT/evidence-add-review.err"
test ! -s "$TMPROOT/evidence-add-review.err"
"$CLI" evidence show --file "$APPEND_EVIDENCE" --json >"$TMPROOT/evidence-show.json" 2>"$TMPROOT/evidence-show.err"
test ! -s "$TMPROOT/evidence-show.err"
json_assert 'evidence submit appends structured review record' "$TMPROOT/evidence-show.json" 'j["records"].length >= 1 && j["records"].last["kind"] == "review" && j["records"].last["status"] == "pass" && j["records"].last["summary"] == "Review passed." && j["records"].last["structured_submit"] == true && j["records"].last["evidence_level"] == "outcome_quality" && j["records"].last["created_at"].is_a?(String)'
"$CLI" evidence add --file "$APPEND_EVIDENCE" --kind command --status partial --summary "command evidence retained" >/dev/null
json_assert 'evidence add preserves history' "$APPEND_EVIDENCE" 'j["records"].length >= 2 && j["records"][-2]["kind"] == "review" && j["records"][-1]["kind"] == "command"'
expect_failure 'evidence add rejects invalid status' "$CLI" evidence add --file "$APPEND_EVIDENCE" --kind command --status maybe --summary "bad status"
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
if "$CLI" validate --task "$LEGACY_TASK" --json >"$TMPROOT/legacy-task-validate.json"; then
  printf 'FAIL validate legacy task: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'validate rejects legacy target_role task schema' "$TMPROOT/legacy-task-validate.json" 'j["valid"] == false && j["errors"].any? { |e| e["source"] == "task_file.execution_contract" }'

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
"$CLI" evidence attach-rule --file "$REVIEW_JUDGMENT_EVIDENCE" --rule-resolution "$TMPROOT/current-rule-resolution.json" --task "$TASK" >"$TMPROOT/evidence-attach-rule.out" 2>"$TMPROOT/evidence-attach-rule.err"
test ! -s "$TMPROOT/evidence-attach-rule.err"
json_assert 'evidence attach-rule records rule resolution summary' "$REVIEW_JUDGMENT_EVIDENCE" 'j["rule_resolution"]["file"] == File.expand_path(ARGV[2]) && j["rule_resolution"]["valid"] == true && j["rule_resolution"]["resolved_role"] == "reviewer" && j["rule_resolution"]["task_sha256"].is_a?(String) && j["rule_resolution"]["conflict_count"] == 0' "$TMPROOT/current-rule-resolution.json"
cp "$TMPROOT/current-rule-resolution.json" "$TMPROOT/bad-task-sha-rule-resolution.json"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["task_sha256"]="0"*64; File.write(p, JSON.pretty_generate(j))' "$TMPROOT/bad-task-sha-rule-resolution.json"
expect_failure 'attach-rule rejects rule resolution with stale task_sha256' "$CLI" evidence attach-rule --file "$REVIEW_JUDGMENT_EVIDENCE" --rule-resolution "$TMPROOT/bad-task-sha-rule-resolution.json" --task "$TASK"
CONCURRENT_EVIDENCE="$TMPROOT/concurrent-evidence.json"
"$CLI" evidence init --output "$CONCURRENT_EVIDENCE" >/dev/null
cat >"$TMPROOT/concurrent-review-submit.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
report_template_version: test-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    schema_semantics: v1
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
"$CLI" evidence attach-rule --file "$CONCURRENT_EVIDENCE" --rule-resolution "$TMPROOT/current-rule-resolution.json" --task "$TASK" >/dev/null &
"$CLI" evidence add --file "$CONCURRENT_EVIDENCE" --kind command --status pass --summary "concurrent command retained" >/dev/null &
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/concurrent-review-submit.yaml" --task "$TASK" --json >/dev/null &
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$CONCURRENT_EVIDENCE" --report "$TMPROOT/concurrent-test-submit.yaml" --task "$TEST_TASK" --json >/dev/null &
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
expect_failure 'attach-rule rejects no-task rule resolution' "$CLI" evidence attach-rule --file "$NO_TASK_RULE_EVIDENCE" --rule-resolution "$TMPROOT/no-task-rule-resolution.json" --task "$TASK"
BAD_REVIEW_JUDGMENT_EVIDENCE="$TMPROOT/bad-review-judgment-evidence.json"
cp "$REVIEW_JUDGMENT_EVIDENCE" "$BAD_REVIEW_JUDGMENT_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["review_judgment"]["quality_outcome"].delete("reasoning"); File.write(p, JSON.pretty_generate(j))' "$BAD_REVIEW_JUDGMENT_EVIDENCE"
expect_failure 'validate rejects incomplete review judgment' "$CLI" validate --task "$TASK" --evidence "$BAD_REVIEW_JUDGMENT_EVIDENCE" --json

LATEST_FAIL_EVIDENCE="$TMPROOT/latest-fail-evidence.json"
"$CLI" evidence init --output "$LATEST_FAIL_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/latest-fail-review-pass.yaml" "Review passed first." "herdr:reviewer:latest-fail-pass"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$LATEST_FAIL_EVIDENCE" --report "$TMPROOT/latest-fail-review-pass.yaml" --task "$TASK" --json >/dev/null
write_review_report "$TMPROOT/latest-fail-review-fail.yaml" "fail" "Review failed latest." "herdr:reviewer:latest-fail"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$LATEST_FAIL_EVIDENCE" --report "$TMPROOT/latest-fail-review-fail.yaml" --task "$TASK" --json >/dev/null
expect_failure 'validate uses latest review fail verdict' "$CLI" validate --task "$TASK" --evidence "$LATEST_FAIL_EVIDENCE" --json

LATEST_PASS_EVIDENCE="$TMPROOT/latest-pass-evidence.json"
"$CLI" evidence init --output "$LATEST_PASS_EVIDENCE" >/dev/null
write_review_report "$TMPROOT/latest-pass-review-fail.yaml" "fail" "Review failed first." "herdr:reviewer:latest-pass-fail"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$LATEST_PASS_EVIDENCE" --report "$TMPROOT/latest-pass-review-fail.yaml" --task "$TASK" --json >/dev/null
write_review_pass_report "$TMPROOT/latest-pass-review-pass.yaml" "Review passed latest." "herdr:reviewer:latest-pass"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$LATEST_PASS_EVIDENCE" --report "$TMPROOT/latest-pass-review-pass.yaml" --task "$TASK" --json >/dev/null
"$CLI" validate --task "$TASK" --evidence "$LATEST_PASS_EVIDENCE" --json >"$TMPROOT/latest-pass-validate.json"
json_assert 'validate uses latest review pass verdict' "$TMPROOT/latest-pass-validate.json" 'j["valid"] == true'

PARTIAL_EVIDENCE="$TMPROOT/partial-evidence.json"
"$CLI" evidence init --output "$PARTIAL_EVIDENCE" >/dev/null
write_review_report "$TMPROOT/partial-review.yaml" "partial" "Review partially passed." "herdr:reviewer:partial"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$PARTIAL_EVIDENCE" --report "$TMPROOT/partial-review.yaml" --task "$TASK" --json >/dev/null
expect_failure 'validate rejects partial verdict for done gate' "$CLI" validate --task "$TASK" --evidence "$PARTIAL_EVIDENCE" --json

INVALID_ONLY_EVIDENCE="$TMPROOT/invalid-only-evidence.json"
"$CLI" evidence init --output "$INVALID_ONLY_EVIDENCE" >/dev/null
write_review_report "$TMPROOT/invalid-only-review.yaml" "invalid" "Invalid review evidence." "herdr:reviewer:invalid-only"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$INVALID_ONLY_EVIDENCE" --report "$TMPROOT/invalid-only-review.yaml" --task "$TASK" --json >/dev/null
expect_failure 'validate ignores invalid-only verdict' "$CLI" validate --task "$TASK" --evidence "$INVALID_ONLY_EVIDENCE" --json

INVALID_LATEST_EVIDENCE="$TMPROOT/invalid-latest-evidence.json"
"$CLI" evidence init --output "$INVALID_LATEST_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/invalid-latest-review-pass.yaml" "Review passed before invalid." "herdr:reviewer:invalid-latest-pass"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$INVALID_LATEST_EVIDENCE" --report "$TMPROOT/invalid-latest-review-pass.yaml" --task "$TASK" --json >/dev/null
write_review_report "$TMPROOT/invalid-latest-review-invalid.yaml" "invalid" "Invalid latest ignored." "herdr:reviewer:invalid-latest"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$INVALID_LATEST_EVIDENCE" --report "$TMPROOT/invalid-latest-review-invalid.yaml" --task "$TASK" --json >/dev/null
"$CLI" validate --task "$TASK" --evidence "$INVALID_LATEST_EVIDENCE" --json >"$TMPROOT/invalid-latest-validate.json"
json_assert 'validate ignores invalid latest verdict' "$TMPROOT/invalid-latest-validate.json" 'j["valid"] == true'

TEST_ONLY_EVIDENCE="$TMPROOT/test-only-evidence.json"
"$CLI" evidence init --output "$TEST_ONLY_EVIDENCE" >/dev/null
write_test_pass_report "$TMPROOT/test-only-pass.yaml" "Test passed only." "herdr:tester:test-only"
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$TEST_ONLY_EVIDENCE" --report "$TMPROOT/test-only-pass.yaml" --task "$TEST_TASK" --json >/dev/null
expect_failure 'validate review task rejects test-only evidence' "$CLI" validate --task "$TASK" --evidence "$TEST_ONLY_EVIDENCE" --json

BAD_TIME_EVIDENCE="$TMPROOT/bad-time-evidence.json"
"$CLI" evidence init --output "$BAD_TIME_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/bad-time-review-pass.yaml" "Bad time evidence." "herdr:reviewer:bad-time"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$BAD_TIME_EVIDENCE" --report "$TMPROOT/bad-time-review-pass.yaml" --task "$TASK" --json >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["records"][0]["created_at"]="not-a-time"; File.write(p, JSON.pretty_generate(j))' "$BAD_TIME_EVIDENCE"
expect_failure 'validate fails unsortable evidence time' "$CLI" validate --task "$TASK" --evidence "$BAD_TIME_EVIDENCE" --json

expect_failure 'state start rejects owner role conflict' env ORBIT_ROLE=lead "$CLI" state start --task "$TASK" --owner-role reviewer
ORBIT_ROLE=lead "$CLI" state start --task "$TASK" >"$TMPROOT/state-start.out" 2>"$TMPROOT/state-start.err"
test ! -s "$TMPROOT/state-start.err"
"$CLI" state show --json >"$TMPROOT/state-working.json"
json_assert 'state start infers owner and binds task' "$TMPROOT/state-working.json" 'j["phase"] == "working" && j["owner_role"] == "lead" && j["current_task"] == File.expand_path(ARGV[2]) && j["history"].last["event"] == "start"' "$TASK"
DESIGN_STATE="$TMPROOT/design-loop-state.yaml"
cp .orbit/loop-state.yaml "$DESIGN_STATE"
ORBIT_INSTANCE=lead-main "$CLI" state start --state "$DESIGN_STATE" --task "$DESIGN_TASK" --owner-role lead >/dev/null
yaml_assert 'state start enters drafting for design task' "$DESIGN_STATE" 'j["phase"] == "drafting" && j["history"].last["to"] == "drafting"'
DESIGN_GATE_EVIDENCE="$TMPROOT/design-gate-evidence.json"
"$CLI" evidence init --output "$DESIGN_GATE_EVIDENCE" >/dev/null
cat >"$TMPROOT/design-review-pass.yaml" <<'YAML'
kind: review
report_template_version: review-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    quality_outcome: v1
    schema_semantics: v1
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
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$DESIGN_GATE_EVIDENCE" --report "$TMPROOT/design-review-pass.yaml" --task "$DESIGN_TASK" --json >/dev/null
expect_failure 'state transition blocks design coding_ready before user_confirmed phase' "$CLI" state transition --state "$DESIGN_STATE" --to coding_ready --evidence "$DESIGN_GATE_EVIDENCE"
"$CLI" state transition --state "$DESIGN_STATE" --to review_requested >/dev/null
expect_failure 'state transition blocks user_confirmed without user confirmation evidence' "$CLI" state transition --state "$DESIGN_STATE" --to user_confirmed --evidence "$DESIGN_GATE_EVIDENCE"
"$CLI" evidence add --file "$DESIGN_GATE_EVIDENCE" --kind command --status pass --summary "user_confirmed: user approved reviewed design artifact for coding." >/dev/null
STRICT_DESIGN_TASK="$TMPROOT/strict-runtime-design-task.yaml"
STRICT_DESIGN_STATE="$TMPROOT/strict-runtime-design-state.yaml"
STRICT_DESIGN_EVIDENCE="$TMPROOT/strict-runtime-design-evidence.json"
cp "$DESIGN_TASK" "$STRICT_DESIGN_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["runtime_identity_policy"]={"gate"=>"herdr_verified"}; File.write(p, YAML.dump(y))' "$STRICT_DESIGN_TASK"
cp "$DESIGN_GATE_EVIDENCE" "$STRICT_DESIGN_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); rec=j["records"].find { |r| r["kind"]=="review" && r["status"]=="pass" }; rec["runtime_identity"]={"verification"=>"manual_runtime","source"=>"test"}; File.write(p, JSON.pretty_generate(j))' "$STRICT_DESIGN_EVIDENCE"
cp .orbit/loop-state.yaml "$STRICT_DESIGN_STATE"
ORBIT_INSTANCE=lead-main "$CLI" state start --state "$STRICT_DESIGN_STATE" --task "$STRICT_DESIGN_TASK" --owner-role lead >/dev/null
"$CLI" state transition --state "$STRICT_DESIGN_STATE" --to review_requested >/dev/null
expect_failure 'design transition blocks manual runtime review under strict runtime policy' "$CLI" state transition --state "$STRICT_DESIGN_STATE" --to user_confirmed --evidence "$STRICT_DESIGN_EVIDENCE"
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
write_review_report "$TMPROOT/fail-review.yaml" "fail" "Review failed." "herdr:reviewer:fail"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$FAIL_EVIDENCE" --report "$TMPROOT/fail-review.yaml" --task "$TASK" --json >/dev/null
expect_failure 'state transition blocks done on fail evidence' "$CLI" state transition --to done --evidence "$FAIL_EVIDENCE"
"$CLI" state transition --to done --evidence "$REVIEW_JUDGMENT_EVIDENCE" >"$TMPROOT/state-done.out" 2>"$TMPROOT/state-done.err"
test ! -s "$TMPROOT/state-done.err"
"$CLI" state show --json >"$TMPROOT/state-done.json"
json_assert 'state transition to done records evidence' "$TMPROOT/state-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2]) && j["history"].last["to"] == "done"' "$REVIEW_JUDGMENT_EVIDENCE"
cp .orbit/loop-state.yaml "$TMPROOT/review-done-state.yaml"

IMPL_TASK="$TMPROOT/implementation-task.yaml"
"$CLI" new-task --task-type implementation --output "$IMPL_TASK" >/dev/null
yaml_assert 'new-task adds implementation review/test gates' "$IMPL_TASK" 'j["gates"].is_a?(Array) && j["gates"].any? { |g| g["kind"] == "review" && g["roles"].include?("reviewer") } && j["gates"].any? { |g| g["kind"] == "test" && g["roles"].include?("tester") }'
yaml_assert 'new-task marks implementation test gate level' "$IMPL_TASK" 'j["test_level"] == "repo_regression"'
ORBIT_INSTANCE=reviewer-main "$CLI" rules resolve --task "$IMPL_TASK" --json >"$TMPROOT/implementation-reviewer-rules.json"
json_assert 'rules resolve allows reviewer gate role on implementation task' "$TMPROOT/implementation-reviewer-rules.json" 'j["valid"] == true && j["resolved_role"] == "reviewer" && j.dig("execution_context","mode") == "gate"'
BAD_GATE_TASK="$TMPROOT/bad-gate-task.yaml"
cp "$IMPL_TASK" "$BAD_GATE_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["gates"]=[{"kind"=>"deploy","roles"=>["reviewer"],"required"=>true}]; File.write(p, YAML.dump(y))' "$BAD_GATE_TASK"
expect_failure 'rules resolve rejects invalid gate kind role bypass' env ORBIT_INSTANCE=reviewer-main "$CLI" rules resolve --task "$BAD_GATE_TASK" --json
IMPL_EVIDENCE="$TMPROOT/implementation-evidence.json"
"$CLI" evidence init --output "$IMPL_EVIDENCE" >/dev/null
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file "$IMPL_EVIDENCE" --kind implementation --status pass --summary "implementation evidence passed" --task "$IMPL_TASK" >/dev/null
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["worktree_safety"]={"status"=>"not_git","reason"=>"generated test app is not a git repository","unexpected_changes"=>[]}; File.write(p, JSON.pretty_generate(j))' "$IMPL_EVIDENCE"
"$CLI" init --force --operation-mode solo >/dev/null
register_manual_runtime_instances
ORBIT_INSTANCE=lead-main "$CLI" state start --task "$IMPL_TASK" >/dev/null
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
sleep 1
write_review_pass_report "$TMPROOT/implementation-review-pass.yaml" "Review gate passed." "herdr:reviewer:implementation-gate"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$IMPL_EVIDENCE" --report "$TMPROOT/implementation-review-pass.yaml" --task "$IMPL_TASK" --json >/dev/null
cat >"$TMPROOT/implementation-test-submit.yaml" <<'YAML'
kind: test
report_template_version: test-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    schema_semantics: v1
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
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$IMPL_EVIDENCE" --report "$TMPROOT/implementation-test-submit.yaml" --task "$IMPL_TASK" --json >/dev/null
SAME_SECOND_GATE_EVIDENCE="$TMPROOT/same-second-gate-evidence.json"
cp "$IMPL_EVIDENCE" "$SAME_SECOND_GATE_EVIDENCE"
ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); impl=j["records"].find { |r| r["kind"]=="implementation" }; review=j["records"].find { |r| r["kind"]=="review" }; review["created_at"]=impl["created_at"]; File.write(p, JSON.pretty_generate(j))' "$SAME_SECOND_GATE_EVIDENCE"
"$CLI" validate --task "$IMPL_TASK" --evidence "$SAME_SECOND_GATE_EVIDENCE" --json >"$TMPROOT/same-second-gate-validate.json"
json_assert 'validate accepts same-second gate record appended after implementation' "$TMPROOT/same-second-gate-validate.json" 'j["valid"] == true'
"$CLI" state transition --to done --evidence "$IMPL_EVIDENCE" >"$TMPROOT/implementation-done.out" 2>"$TMPROOT/implementation-done.err"
test ! -s "$TMPROOT/implementation-done.err"
"$CLI" state show --json >"$TMPROOT/implementation-done.json"
json_assert 'state transition allows done with implementation pass evidence' "$TMPROOT/implementation-done.json" 'j["phase"] == "done" && j["artifacts"]["evidence_file"] == File.expand_path(ARGV[2])' "$IMPL_EVIDENCE"
"$CLI" audit --task "$IMPL_TASK" --evidence "$IMPL_EVIDENCE" --state .orbit/loop-state.yaml --json >"$TMPROOT/audit-valid.json" 2>"$TMPROOT/audit-valid.err"
test ! -s "$TMPROOT/audit-valid.err"
json_assert 'audit passes done state with matching evidence' "$TMPROOT/audit-valid.json" 'j["schema_version"] == "orbit-audit-v1" && j["trust_level"]["mode"] == "audit_only" && j["done_ready"] == true && j["trusted_for_handoff"] == true && j["trusted_for_done"] == true && j["trusted_for_release"] == false && j["blocking_findings"].empty? && j["warnings"].any? { |e| e["source"] == "state_file.artifacts.handoff_packet" && e["remediation"].is_a?(String) } && j["issues"].length == j["blocking_findings"].length + j["warnings"].length && j["validation"]["valid"] == true && j["notice_summary"]["required"] == false && j["notice_summary"]["missing_events"].include?("implementation_complete") && j["evidence_summary"]["aggregate_verdict"]["gates"]["review"]["evidence_level"] == "outcome_quality" && j["evidence_summary"]["aggregate_verdict"]["gates"]["test"]["evidence_level"] == "real_path_test"'
REQUIRED_NOTICE_TASK="$TMPROOT/required-notice-task.yaml"
REQUIRED_NOTICE_EVIDENCE="$TMPROOT/required-notice-evidence.json"
REQUIRED_NOTICE_STATE="$TMPROOT/required-notice-state.yaml"
cp "$IMPL_TASK" "$REQUIRED_NOTICE_TASK"
cp "$IMPL_EVIDENCE" "$REQUIRED_NOTICE_EVIDENCE"
cp .orbit/loop-state.yaml "$REQUIRED_NOTICE_STATE"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["completion_notice_policy"]="required"; File.write(p, YAML.dump(y))' "$REQUIRED_NOTICE_TASK"
ruby --disable-gems -rjson -rdigest -e 'p, task = ARGV; sha = Digest::SHA256.file(task).hexdigest; j = JSON.parse(File.read(p)); j["records"].each { |r| next unless r["role_execution_context"].is_a?(Hash); r["role_execution_context"]["task"] = File.expand_path(task); r["role_execution_context"]["task_sha256"] = sha }; File.write(p, JSON.pretty_generate(j))' "$REQUIRED_NOTICE_EVIDENCE" "$REQUIRED_NOTICE_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["current_task"]=File.expand_path(ARGV[1]); y["artifacts"]["evidence_file"]=File.expand_path(ARGV[2]); File.write(p, YAML.dump(y))' "$REQUIRED_NOTICE_STATE" "$REQUIRED_NOTICE_TASK" "$REQUIRED_NOTICE_EVIDENCE"
if "$CLI" audit --task "$REQUIRED_NOTICE_TASK" --evidence "$REQUIRED_NOTICE_EVIDENCE" --state "$REQUIRED_NOTICE_STATE" --json >"$TMPROOT/audit-missing-notice.json"; then
  printf 'FAIL audit missing completion notice: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit reports missing completion notice when policy requires it' "$TMPROOT/audit-missing-notice.json" 'j["notice_summary"]["required"] == true && j["notice_summary"]["missing_events"].include?("implementation_complete") && j["blocking_findings"].any? { |f| f["source"] == "notice_summary.missing_completion_notice" }'
mkdir -p .orbit/runtime/notices/lead
ruby --disable-gems -rjson -rdigest -e 'task,evidence,path=ARGV; record={"schema_version"=>"orbit-notice-v1","id"=>"fake-implementation-complete","task"=>File.expand_path(task),"task_sha256"=>Digest::SHA256.file(task).hexdigest,"evidence_ref"=>File.expand_path(evidence),"evidence_record"=>{"kind"=>"implementation","record_index"=>0,"record_created_at"=>"2000-01-01T00:00:00Z","record_sha256"=>"bad"},"event"=>"implementation_complete","status"=>"open","from_role"=>"tester","from_instance"=>"tester-main","to_role"=>"lead","to_instance"=>"wrong-owner","created_at"=>"2000-01-01T00:00:00Z"}; File.write(path, JSON.pretty_generate(record))' "$REQUIRED_NOTICE_TASK" "$REQUIRED_NOTICE_EVIDENCE" .orbit/runtime/notices/lead/fake-implementation-complete.json
if "$CLI" audit --task "$REQUIRED_NOTICE_TASK" --evidence "$REQUIRED_NOTICE_EVIDENCE" --state "$REQUIRED_NOTICE_STATE" --json >"$TMPROOT/audit-invalid-notice.json"; then
  printf 'FAIL audit invalid completion notice: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit ignores invalid completion notice for required policy' "$TMPROOT/audit-invalid-notice.json" 'j["notice_summary"]["missing_events"].include?("implementation_complete") && j["notice_summary"]["invalid_notices"].any? { |n| n["id"] == "fake-implementation-complete" && n["invalid_reasons"].include?("recipient_instance_mismatch") && n["invalid_reasons"].include?("source_not_allowed") && n["invalid_reasons"].include?("created_at_before_required_record") }'
ORBIT_INSTANCE=lead-main "$CLI" notice add --task "$REQUIRED_NOTICE_TASK" --event implementation_complete --evidence "$REQUIRED_NOTICE_EVIDENCE" --json >/dev/null
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file "$REQUIRED_NOTICE_EVIDENCE" --kind command --status pass --summary "post-notice command evidence" >/dev/null
if "$CLI" audit --task "$REQUIRED_NOTICE_TASK" --evidence "$REQUIRED_NOTICE_EVIDENCE" --state "$REQUIRED_NOTICE_STATE" --json >"$TMPROOT/audit-notice-survives-append.json"; then
  printf 'FAIL audit should still require review/test notices after append: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit keeps implementation notice valid after later evidence append' "$TMPROOT/audit-notice-survives-append.json" '!j["notice_summary"]["missing_events"].include?("implementation_complete") && j["notice_summary"]["missing_events"].include?("review_complete") && j["notice_summary"]["missing_events"].include?("test_complete")'
BRANCHED_NOTICE_EVIDENCE="$TMPROOT/branched-required-notice-evidence.json"
BRANCHED_NOTICE_STATE="$TMPROOT/branched-required-notice-state.yaml"
cp "$REQUIRED_NOTICE_EVIDENCE" "$BRANCHED_NOTICE_EVIDENCE"
cp "$REQUIRED_NOTICE_STATE" "$BRANCHED_NOTICE_STATE"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["artifacts"]["evidence_file"]=File.expand_path(ARGV[1]); File.write(p, YAML.dump(y))' "$BRANCHED_NOTICE_STATE" "$BRANCHED_NOTICE_EVIDENCE"
if "$CLI" audit --task "$REQUIRED_NOTICE_TASK" --evidence "$BRANCHED_NOTICE_EVIDENCE" --state "$BRANCHED_NOTICE_STATE" --json >"$TMPROOT/audit-notice-cross-manifest.json"; then
  printf 'FAIL audit cross-manifest completion notice: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit rejects completion notice from another evidence manifest' "$TMPROOT/audit-notice-cross-manifest.json" 'j["notice_summary"]["missing_events"].include?("implementation_complete") && j["notice_summary"]["invalid_notices"].any? { |n| n["event"] == "implementation_complete" && n["invalid_reasons"].include?("evidence_ref_mismatch") }'
cat >"$TMPROOT/hook-notice-cross-manifest.json" <<JSON
{"task":"$REQUIRED_NOTICE_TASK","evidence":"$BRANCHED_NOTICE_EVIDENCE"}
JSON
ORBIT_INSTANCE=lead-main "$CLI" hook pre-idle --intent-json "$TMPROOT/hook-notice-cross-manifest.json" --json >"$TMPROOT/hook-notice-cross-manifest.out"
json_assert 'hook pre-idle rejects completion notice from another evidence manifest' "$TMPROOT/hook-notice-cross-manifest.out" 'j["allowed"] == true && j["recommended_action"] == "write_completion_notice" && j["warnings"].include?("missing_completion_notice")'
ORBIT_INSTANCE=reviewer-main "$CLI" notice add --task "$REQUIRED_NOTICE_TASK" --event review_complete --evidence "$REQUIRED_NOTICE_EVIDENCE" --json >/dev/null
ORBIT_INSTANCE=tester-main "$CLI" notice add --task "$REQUIRED_NOTICE_TASK" --event test_complete --evidence "$REQUIRED_NOTICE_EVIDENCE" --json >/dev/null
"$CLI" audit --task "$REQUIRED_NOTICE_TASK" --evidence "$REQUIRED_NOTICE_EVIDENCE" --state "$REQUIRED_NOTICE_STATE" --json >"$TMPROOT/audit-required-notice-present.json"
json_assert 'audit accepts required completion notices when present' "$TMPROOT/audit-required-notice-present.json" 'j["notice_summary"]["required"] == true && j["notice_summary"]["missing_events"].empty? && j["blocking_findings"].empty?'
ACK_REQUIRED_NOTICE_TASK="$TMPROOT/ack-required-notice-task.yaml"
ACK_REQUIRED_NOTICE_EVIDENCE="$TMPROOT/ack-required-notice-evidence.json"
ACK_REQUIRED_NOTICE_STATE="$TMPROOT/ack-required-notice-state.yaml"
cp "$IMPL_TASK" "$ACK_REQUIRED_NOTICE_TASK"
cp "$IMPL_EVIDENCE" "$ACK_REQUIRED_NOTICE_EVIDENCE"
cp .orbit/loop-state.yaml "$ACK_REQUIRED_NOTICE_STATE"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["completion_notice_policy"]={"required"=>true,"ack_required"=>true}; File.write(p, YAML.dump(y))' "$ACK_REQUIRED_NOTICE_TASK"
ruby --disable-gems -rjson -rdigest -e 'p, task = ARGV; sha = Digest::SHA256.file(task).hexdigest; j = JSON.parse(File.read(p)); j["records"].each { |r| next unless r["role_execution_context"].is_a?(Hash); r["role_execution_context"]["task"] = File.expand_path(task); r["role_execution_context"]["task_sha256"] = sha }; File.write(p, JSON.pretty_generate(j))' "$ACK_REQUIRED_NOTICE_EVIDENCE" "$ACK_REQUIRED_NOTICE_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y["current_task"]=File.expand_path(ARGV[1]); y["artifacts"]["evidence_file"]=File.expand_path(ARGV[2]); File.write(p, YAML.dump(y))' "$ACK_REQUIRED_NOTICE_STATE" "$ACK_REQUIRED_NOTICE_TASK" "$ACK_REQUIRED_NOTICE_EVIDENCE"
ORBIT_INSTANCE=lead-main "$CLI" notice add --task "$ACK_REQUIRED_NOTICE_TASK" --event implementation_complete --evidence "$ACK_REQUIRED_NOTICE_EVIDENCE" --json >/dev/null
ORBIT_INSTANCE=reviewer-main "$CLI" notice add --task "$ACK_REQUIRED_NOTICE_TASK" --event review_complete --evidence "$ACK_REQUIRED_NOTICE_EVIDENCE" --json >/dev/null
ORBIT_INSTANCE=tester-main "$CLI" notice add --task "$ACK_REQUIRED_NOTICE_TASK" --event test_complete --evidence "$ACK_REQUIRED_NOTICE_EVIDENCE" --json >/dev/null
if "$CLI" audit --task "$ACK_REQUIRED_NOTICE_TASK" --evidence "$ACK_REQUIRED_NOTICE_EVIDENCE" --state "$ACK_REQUIRED_NOTICE_STATE" --json >"$TMPROOT/audit-required-notice-unacked.json"; then
  printf 'FAIL audit ack-required open notice: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'audit blocks open completion notices when ack is required' "$TMPROOT/audit-required-notice-unacked.json" 'j["notice_summary"]["ack_required"] == true && j["notice_summary"]["unacked_events"].include?("implementation_complete") && j["notice_summary"]["unacked_events"].include?("review_complete") && j["notice_summary"]["unacked_events"].include?("test_complete") && j["blocking_findings"].any? { |f| f["source"] == "notice_summary.unacked_completion_notice" }'
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
json_assert 'handoff outputs valid packet' "$TMPROOT/handoff-valid.json" 'j["schema_version"] == "orbit-handoff-v1" && j.dig("execution_contract","implementation_authority") == "reviewer" && j["current_phase"] == "done" && j["required_action"] == "none" && j["next_action"] == "none" && j["blocking_errors"].empty? && j["validation_summary"]["valid"] == true && j["audit_summary"]["done_ready"] == true && j["tools_summary"]["runtime_adapter"].is_a?(String) && j["tools_summary"]["manual_payload_available"] == true && j["delivery"]["mode"] == "manual_artifact" && j["delivery"]["runtime_adapter"] == "none" && j["delivery"]["payload"]["required_action"] == "none" && j["rule_packs"].any? { |p| p["category"] == "review" && p["id"] == "brooks-review" } && j["rule_packs"].any? { |p| p["category"] == "audit" && p["id"] == "orbit-drift" } && j["rule_resolution_summary"]["present"] == true && j["rule_resolution_summary"]["valid"] == true && j["rule_resolution_summary"]["resolved_role"] == "reviewer" && j["judgment_summary"]["review_judgment"]["present"] == true && j["closure_checklist"].is_a?(Array) && j["readable_summary"]["next_action"] == "none" && j["evidence_summary"]["records"] >= 1'
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y={"schema_version"=>"orbit-tools-config-v1","delivery_profiles"=>{"manual"=>{"format"=>"json","delivery"=>"manual"}},"preference"=>{"handoff"=>"manual"}}; File.write(p, YAML.dump(y))' .orbit/tools.yaml
"$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/handoff-manual-delivery.json"
json_assert 'handoff outputs manual delivery payload' "$TMPROOT/handoff-manual-delivery.json" 'j["required_action"] == "none" && j["delivery"]["mode"] == "manual_artifact" && j["delivery"]["selected"] == "manual" && j["delivery"]["payload"]["delivery"] == "manual"'
INVALID_HANDOFF_TASK="$TMPROOT/invalid-handoff-task.yaml"
cp "$TASK" "$INVALID_HANDOFF_TASK"
ruby --disable-gems -ryaml -e 'p=ARGV[0]; y=YAML.safe_load(File.read(p), aliases: true); y.delete("execution_contract"); File.write(p, YAML.dump(y))' "$INVALID_HANDOFF_TASK"
if "$CLI" handoff --task "$INVALID_HANDOFF_TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json >"$TMPROOT/handoff-invalid.json"; then
  printf 'FAIL handoff invalid task: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'handoff invalid task reports blocking errors' "$TMPROOT/handoff-invalid.json" 'j["blocking_errors"].any? { |e| e["source"] == "task_file.execution_contract" } && j["required_action"] == "resolve_blocking_errors"'
expect_failure 'handoff fails role conflict' env ORBIT_INSTANCE=tester-main "$CLI" handoff --task "$TASK" --state "$TMPROOT/review-done-state.yaml" --evidence "$REVIEW_JUDGMENT_EVIDENCE" --json

EQ_TASK="$TMPROOT/eq-task.yaml"
"$CLI" new-task --implementation-authority=tester --assigned-instance=tester-main --task-type=implementation_test --project=explicit --output="$EQ_TASK" >/dev/null
yaml_assert 'new-task supports equals syntax and explicit project' "$EQ_TASK" 'j["project"] == "explicit" && j.dig("execution_contract","implementation_authority") == "tester" && j.dig("execution_contract","assigned_instance") == "tester-main" && j["task_type"] == "implementation_test" && j["rule_packs"].any? { |p| p["category"] == "test" && p["id"] == "brooks-test" }'
expect_failure 'validate test task rejects review-only appended evidence' "$CLI" validate --task "$EQ_TASK" --evidence "$APPEND_EVIDENCE" --json
cat >"$TMPROOT/eq-test-submit.yaml" <<'YAML'
kind: test
report_template_version: test-report-v1
schema_semantics:
  feature_versions:
    evidence_level: v1
    schema_semantics: v1
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
ORBIT_INSTANCE=tester-main "$CLI" evidence submit --file "$APPEND_EVIDENCE" --report "$TMPROOT/eq-test-submit.yaml" --task "$EQ_TASK" --json >"$TMPROOT/eq-test-submit.json"
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
"$CLI" init --force --operation-mode solo >/dev/null
register_manual_runtime_instances
ORBIT_INSTANCE=lead-main "$CLI" state start --task "$EQ_TASK" >/dev/null
"$CLI" state show --json >"$TMPROOT/state-owner-instance.json"
json_assert 'state start infers owner from instance' "$TMPROOT/state-owner-instance.json" 'j["phase"] == "working" && j["owner_role"] == "lead"'
expect_failure 'new-task requires output' "$CLI" new-task --implementation-authority reviewer --assigned-instance reviewer-main --task-type review
expect_failure 'new-task rejects removed target-role option as unknown' "$CLI" new-task --target-role --task-type review --output "$TMPROOT/bad.yaml"

OVERRIDE_PROJECT="$TMPROOT/override-project"
mkdir -p "$OVERRIDE_PROJECT"
(
  cd "$OVERRIDE_PROJECT"
  "$CLI" init --operation-mode team >/dev/null
  ruby --disable-gems -ryaml -e 'p=".orbit/instances.yaml"; y=YAML.safe_load(File.read(p), aliases: true); y["instances"]["coder-android"]=Marshal.load(Marshal.dump(y["instances"]["coder-main"])); y["instances"]["coder-android"]["env"]={"ORBIT_INSTANCE"=>"coder-android","ORBIT_ROLE"=>"coder"}; File.write(p, YAML.dump(y))'
  register_manual_runtime_instance lead-main lead
  register_manual_runtime_instance coder-main coder
  register_manual_runtime_instance coder-android coder
  "$CLI" new-task --task-type docs_improvement --output task.yaml >/dev/null
  "$CLI" evidence init --output evidence.json >/dev/null
  expect_failure 'team implementation evidence rejects role-name instance alias' env ORBIT_INSTANCE=coder "$CLI" evidence add --file evidence.json --kind implementation --status pass --summary "alias implementation" --task task.yaml
  expect_failure 'team same-role non-assigned coder fails without override' env ORBIT_INSTANCE=coder-android "$CLI" whoami --task task.yaml --json
  cat >"$TMPROOT/hook-non-assigned-coder-edit.json" <<JSON
{"task":"$OVERRIDE_PROJECT/task.yaml","paths":["lib/feature.rb"],"live_probe":{"decision":"reuse"}}
JSON
  ORBIT_INSTANCE=coder-android "$CLI" hook pre-edit --intent-json "$TMPROOT/hook-non-assigned-coder-edit.json" --json >"$TMPROOT/hook-non-assigned-coder-edit.out"
  json_assert 'hook pre-edit blocks non-assigned same-role implementation without override' "$TMPROOT/hook-non-assigned-coder-edit.out" 'j["allowed"] == false && j["blocked_reasons"].include?("role_boundary") && j["warnings"].include?("caller_supplied_liveness_ignored")'
  cat >"$TMPROOT/hook-team-owner-edit.json" <<JSON
{"task":"$OVERRIDE_PROJECT/task.yaml","paths":["lib/feature.rb"]}
JSON
  ORBIT_INSTANCE=lead-main "$CLI" hook pre-edit --intent-json "$TMPROOT/hook-team-owner-edit.json" --json >"$TMPROOT/hook-team-owner-edit.out"
  json_assert 'hook pre-edit blocks team owner production edit' "$TMPROOT/hook-team-owner-edit.out" 'j["allowed"] == false && j["blocked_reasons"].include?("owner_cannot_edit_production") && j["recommended_action"] == "delegate_to_assigned_instance"'
  expect_failure 'notice rejects implementation completion without override' env ORBIT_INSTANCE=coder-android "$CLI" notice add --task task.yaml --event implementation_complete --evidence evidence.json --json
  expect_failure 'wrong authorizer cannot create implementation override' env ORBIT_INSTANCE=reviewer-main "$CLI" evidence add --file evidence.json --kind implementation_instance_override --task task.yaml --from-instance coder-main --to-instance coder-android --reason handoff --no-expiry
  ORBIT_INSTANCE=lead-main "$CLI" evidence add --file evidence.json --kind implementation_instance_override --task task.yaml --from-instance coder-main --to-instance coder-android --reason handoff --no-expiry >/dev/null
  ORBIT_INSTANCE=coder-android "$CLI" whoami --task task.yaml --evidence evidence.json --json >"$TMPROOT/override-whoami.json"
  json_assert 'valid override lets non-assigned same-role coder pass preflight' "$TMPROOT/override-whoami.json" 'j.dig("execution_context","mode") == "implementation_override" && j.dig("execution_context","allowed") == true'
  ORBIT_INSTANCE=coder-android "$CLI" rules resolve --task task.yaml --evidence evidence.json --json --output "$TMPROOT/override-rules-resolution.json" >"$TMPROOT/override-rules-resolution.stdout"
  json_assert 'rules resolve accepts override-backed implementation instance' "$TMPROOT/override-rules-resolution.json" 'j["valid"] == true && j["resolved_role"] == "coder" && j["resolved_instance"] == "coder-android" && j.dig("execution_context","mode") == "implementation_override"'
  "$CLI" evidence init --output no-override-evidence.json >/dev/null
  expect_failure 'attach-rule rejects same-role non-assigned resolution without override in manifest' "$CLI" evidence attach-rule --file no-override-evidence.json --rule-resolution "$TMPROOT/override-rules-resolution.json" --task task.yaml
  "$CLI" evidence attach-rule --file evidence.json --rule-resolution "$TMPROOT/override-rules-resolution.json" --task task.yaml >/dev/null
  json_assert 'attach-rule accepts override-backed implementation resolution' evidence.json 'j["rule_resolution"]["resolved_instance"] == "coder-android" && j["rule_resolution"]["valid"] == true'
  ORBIT_INSTANCE=coder-android "$CLI" evidence add --file evidence.json --kind implementation --status pass --summary "override implementation" --task task.yaml >/dev/null
  json_assert 'implementation evidence records full execution contract context' evidence.json 'impl = j["records"].find { |r| r["kind"] == "implementation" }; ctx = impl["role_execution_context"]; ctx["owner_role"] == "lead" && ctx["owner_instance"] == "lead-main" && ctx["operation_mode"] == "team" && ctx["implementation_authority"] == "coder" && ctx["assigned_instance"] == "coder-main" && ctx["resolved_role"] == "coder" && ctx["resolved_instance"] == "coder-android" && ctx["execution_contract_source"] == "project_defaults"'
  cp evidence.json tampered-role-evidence.json
  ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); impl=j["records"].find { |r| r["kind"]=="implementation" }; impl["role_execution_context"]["resolved_role"]="lead"; File.write(p, JSON.pretty_generate(j))' tampered-role-evidence.json
  if "$CLI" validate --task task.yaml --evidence tampered-role-evidence.json --json >"$TMPROOT/tampered-role-validate.json"; then
    printf 'FAIL tampered implementation role validate: command unexpectedly succeeded\n' >&2
    exit 1
  fi
  json_assert 'validate rejects tampered implementation resolved_role' "$TMPROOT/tampered-role-validate.json" 'j["errors"].any? { |e| e["source"].include?("role_execution_context.resolved_role") && e["message"].include?("implementation_authority") }'
  cp evidence.json missing-contract-context-evidence.json
  ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); impl=j["records"].find { |r| r["kind"]=="implementation" }; impl["role_execution_context"].delete("owner_role"); impl["role_execution_context"].delete("execution_contract_source"); File.write(p, JSON.pretty_generate(j))' missing-contract-context-evidence.json
  if "$CLI" validate --task task.yaml --evidence missing-contract-context-evidence.json --json >"$TMPROOT/missing-contract-context-validate.json"; then
    printf 'FAIL missing implementation contract context validate: command unexpectedly succeeded\n' >&2
    exit 1
  fi
  json_assert 'validate rejects missing implementation owner and contract source' "$TMPROOT/missing-contract-context-validate.json" 'j["errors"].any? { |e| e["source"].include?("role_execution_context.owner_role") } && j["errors"].any? { |e| e["source"].include?("role_execution_context.execution_contract_source") }'
  cp evidence.json forged-wrong-to-instance-evidence.json
  ruby --disable-gems -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); ov=j["records"].find { |r| r["kind"]=="implementation_instance_override" }; ov["to_instance"]="reviewer-main"; ov["to_role"]="coder"; impl=j["records"].find { |r| r["kind"]=="implementation" }; impl["role_execution_context"]["resolved_role"]="coder"; impl["role_execution_context"]["resolved_instance"]="reviewer-main"; File.write(p, JSON.pretty_generate(j))' forged-wrong-to-instance-evidence.json
  if "$CLI" validate --task task.yaml --evidence forged-wrong-to-instance-evidence.json --json >"$TMPROOT/forged-wrong-to-instance-validate.json"; then
    printf 'FAIL forged wrong to_instance override validate: command unexpectedly succeeded\n' >&2
    exit 1
  fi
  json_assert 'validate rejects override whose to_instance resolves to wrong role' "$TMPROOT/forged-wrong-to-instance-validate.json" 'j["errors"].any? { |e| e["source"].include?("to_instance") && e["message"].include?("implementation_authority") } && j["errors"].any? { |e| e["source"].include?("role_execution_context.resolved_instance") }'
  cat >"$TMPROOT/hook-override-idle.json" <<JSON
{"task":"$OVERRIDE_PROJECT/task.yaml","evidence":"$OVERRIDE_PROJECT/evidence.json"}
JSON
  ORBIT_INSTANCE=coder-android "$CLI" hook pre-idle --intent-json "$TMPROOT/hook-override-idle.json" --json >"$TMPROOT/hook-override-idle.out"
  json_assert 'hook pre-idle warns when completion notice is missing' "$TMPROOT/hook-override-idle.out" 'j["allowed"] == true && j["recommended_action"] == "write_completion_notice" && j["warnings"].include?("missing_completion_notice")'
  ORBIT_INSTANCE=coder-android "$CLI" notice add --task task.yaml --event implementation_complete --evidence evidence.json --json >"$TMPROOT/override-implementation-notice.json"
  json_assert 'notice add allows override-backed implementation completion' "$TMPROOT/override-implementation-notice.json" 'j["event"] == "implementation_complete" && j["from_role"] == "coder" && j["from_instance"] == "coder-android" && j["to_role"] == "lead" && j["to_instance"] == "lead-main"'
  "$CLI" validate --task task.yaml --evidence evidence.json --json >"$TMPROOT/override-validate.json"
  json_assert 'valid override-backed implementation evidence validates' "$TMPROOT/override-validate.json" 'j["valid"] == true'
  ORBIT_INSTANCE=lead-main "$CLI" state start --task task.yaml >/dev/null
  "$CLI" audit --task task.yaml --evidence evidence.json --state .orbit/loop-state.yaml --json >"$TMPROOT/override-audit.json" || true
  json_assert 'audit surfaces implementation override summary' "$TMPROOT/override-audit.json" 'j.dig("implementation_override_summary","valid_count") == 1 && j.dig("implementation_override_summary","overrides").any? { |o| o["to_instance"] == "coder-android" && o["authorized_by_instance"] == "lead-main" && o["valid"] == true }'

  "$CLI" evidence init --output expired.json >/dev/null
  ORBIT_INSTANCE=lead-main "$CLI" evidence add --file expired.json --kind implementation_instance_override --task task.yaml --from-instance coder-main --to-instance coder-android --reason expired --expires-at 2000-01-01T00:00:00Z >/dev/null
  if "$CLI" validate --task task.yaml --evidence expired.json --json >"$TMPROOT/expired-override-validate.json"; then
    printf 'FAIL expired override validate: command unexpectedly succeeded\n' >&2
    exit 1
  fi
  json_assert 'expired override fails validate' "$TMPROOT/expired-override-validate.json" 'j["errors"].any? { |e| e["source"].include?("expires_at") && e["message"].include?("expired") }'
  expect_failure 'expired override makes same-role replacement fail whoami again' env ORBIT_INSTANCE=coder-android "$CLI" whoami --task task.yaml --evidence expired.json --json
)

STALE_GATE_TASK="$TMPROOT/stale-gate-task.yaml"
STALE_GATE_EVIDENCE="$TMPROOT/stale-gate-evidence.json"
"$CLI" new-task --task-type implementation --output "$STALE_GATE_TASK" >/dev/null
"$CLI" evidence init --output "$STALE_GATE_EVIDENCE" >/dev/null
write_review_pass_report "$TMPROOT/stale-review-pass.yaml" "Review happened before implementation." "herdr:reviewer:stale"
ORBIT_INSTANCE=reviewer-main "$CLI" evidence submit --file "$STALE_GATE_EVIDENCE" --report "$TMPROOT/stale-review-pass.yaml" --task "$STALE_GATE_TASK" --json >/dev/null
sleep 1
ORBIT_INSTANCE=lead-main "$CLI" evidence add --file "$STALE_GATE_EVIDENCE" --kind implementation --status pass --summary "new implementation after review" --task "$STALE_GATE_TASK" >/dev/null
if "$CLI" validate --task "$STALE_GATE_TASK" --evidence "$STALE_GATE_EVIDENCE" --json >"$TMPROOT/stale-gate-validate.json"; then
  printf 'FAIL stale gate validate: command unexpectedly succeeded\n' >&2
  exit 1
fi
json_assert 'validate rejects review stale after implementation' "$TMPROOT/stale-gate-validate.json" 'j["errors"].any? { |e| e["source"].include?("stale_after_implementation") }'

MISMATCH_TASK="$TMPROOT/task-mismatch.yaml"
ruby --disable-gems -e 'File.write(ARGV[0], "schema_version: orbit-task-v1\nproject: project\ntarget_role: tester\n")' "$MISMATCH_TASK"
expect_failure 'whoami fails on task target mismatch' env ORBIT_INSTANCE=reviewer-main "$CLI" whoami --json --task "$MISMATCH_TASK"
expect_failure 'whoami fails on missing task file conflict' env ORBIT_INSTANCE=reviewer-main "$CLI" whoami --json --task "$TMPROOT/missing.yaml"

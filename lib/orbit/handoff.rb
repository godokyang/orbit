# frozen_string_literal: true

def parse_handoff_args(args)
  options = {
    "json" => false,
    "record_state" => false
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--state"
      options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/
      options["state"] = Regexp.last_match(1)
    when "--evidence"
      options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      options["evidence"] = Regexp.last_match(1)
    when "--output"
      options["output"] = option_value(args, "--output")
    when /\A--output=(.+)\z/
      options["output"] = Regexp.last_match(1)
    when "--record-state"
      options["record_state"] = true
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown handoff option: #{arg}")
    end
  end

  %w[task state evidence].each do |name|
    usage_error("Missing required option: --#{name}") if options[name].nil? || options[name].empty?
  end
  options["output"] ||= File.join(DEFAULT_HANDOFF_DIR, "#{durable_task_slug(options["task"])}.json")
  normalized_output = options["output"].tr("\\", "/")
  if normalized_output.start_with?(".orbit/handoff/") || normalized_output.include?("/.orbit/handoff/")
    usage_error("Use the canonical .orbit/handoffs/ directory; singular .orbit/handoff/ is no longer supported.")
  end
  usage_error("handoff currently requires --json") unless options["json"]

  options
end

def write_handoff_artifact(output_path, json)
  path = File.expand_path(output_path)
  write_file_atomically(path, json)
  path
end

def record_handoff_artifact(state_path, handoff_path)
  now = Time.now.utc.iso8601
  update_loop_state(state_path) do |state|
    state["artifacts"] ||= {}
    state_error("Loop state artifacts must be a mapping when present.") unless state["artifacts"].is_a?(Hash)
    relative_handoff = project_relative_persisted_path(handoff_path, field: "handoff")
    state["artifacts"]["handoff_packet"] = relative_handoff
    state["updated_at"] = now
    append_state_history(state, {
      "event" => "handoff",
      "handoff_packet" => relative_handoff,
      "created_at" => now
    })
    state
  end
end

def evidence_summary(evidence)
  summary = {
    "records" => 0,
    "by_kind" => {},
    "latest" => nil,
    "aggregate_verdict" => redact_aggregate_verdict_for_summary(evidence["verdict"]),
    "waivers" => {
      "total" => evidence["waivers"].is_a?(Array) ? evidence["waivers"].length : 0,
      "open" => evidence["waivers"].is_a?(Array) ? evidence["waivers"].count { |waiver| waiver.is_a?(Hash) && waiver["revoked_by_user_requirement"] != true } : 0
    }
  }
  return summary unless evidence.is_a?(Hash)

  records = evidence["records"]
  if records.is_a?(Array) && !records.empty?
    summary["records"] = records.length
    records.each do |record|
      next unless record.is_a?(Hash)

      kind = record["kind"] || "unknown"
      status = record["status"] || "unknown"
      summary["by_kind"][kind] ||= {}
      summary["by_kind"][kind][status] ||= 0
      summary["by_kind"][kind][status] += 1
    end
    summary["latest"] = redact_sensitive_record(records.last)
  elsif evidence["verdict"].is_a?(Hash)
    summary["records"] = 1
    summary["latest"] = evidence["verdict"]
  end

  summary
end

def latest_gate_verdicts_for_handoff(evidence, task_sha256 = nil, task = nil)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  %w[review test].each_with_object({}) do |kind, memo|
    gate = gate_status(records, kind, task, task_sha256: task_sha256, evidence: evidence)
    record = gate["latest"]
    memo[kind] = if record
                   status = gate["passed"] ? record["status"] : "blocked"
                   {
                     "status" => status,
                     "record_status" => record["status"],
                     "blocking_reason" => gate["blocking_reason"],
                     "runtime_identity_verification" => gate["runtime_identity_verification"],
                     "effective_status" => evidence_effective_verdict_status(kind, record),
                     "summary" => record["summary"],
                     "created_at" => record["created_at"],
                     "evidence_level" => record["evidence_level"],
                     "quality_outcome_verdict" => record["quality_outcome_verdict"],
                     "implementation_readiness_verdict" => record["implementation_readiness_verdict"],
                     "test_level" => record["test_level"],
                     "rule_application_summary" => rule_application_summary(record["rule_application"]),
                     "evidence_boundary_summary" => evidence_boundary_summary(record),
                     "source_report" => record["source_report"],
                     "source_message_id" => record["source_message_id"]
                   }.compact
                 else
                   { "status" => "missing" }
                 end
  end
end

def known_gaps_for_handoff(evidence, audit_warnings)
  gaps = []
  Array(audit_warnings).each do |warning|
    next unless warning.is_a?(Hash)

    gaps << {
      "source" => warning["source"],
      "message" => warning["message"],
      "severity" => warning["severity"] || "warning"
    }.compact
  end

  if evidence.is_a?(Hash)
    Array(evidence["waivers"]).each do |waiver|
      next unless waiver.is_a?(Hash)
      next if waiver["revoked_by_user_requirement"] == true

      gaps << {
        "source" => "evidence_file.waivers",
        "message" => "#{waiver["scope"]}: #{waiver["risk"]}",
        "severity" => "waiver",
        "replacement_evidence" => waiver["replacement_evidence"]
      }.compact
    end
  end

  gaps
end

# Machine-readable runtime summary for the handoff packet.
# Surfaces runtime_binding identities, aggregated cleanup status, and reproducibility/runtime gaps.
def handoff_runtime_summary(evidence)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []

  runtime_bindings = records.each_with_index.map do |r, idx|
    next unless r.is_a?(Hash) && r["runtime_binding"].is_a?(Hash)
    {
      "record_index" => idx,
      "kind" => r["kind"],
      "status" => r["status"],
      "binding" => r["runtime_binding"]
    }
  end.compact

  cleanup_counts = {}
  cleanup_records = 0
  cleanup_incomplete = 0
  records.each do |r|
    next unless r.is_a?(Hash) && r["test_environment"].is_a?(Hash)
    cs = r["test_environment"]["cleanup_status"]
    next unless cs.is_a?(String) && !cs.strip.empty?
    cleanup_records += 1
    norm = cs.strip
    cleanup_counts[norm] = (cleanup_counts[norm] || 0) + 1
    cleanup_incomplete += 1 unless norm == "complete"
  end

  reproducibility_gaps = []
  runtime_gaps = []
  runtime_bindings.each do |entry|
    b = entry["binding"]
    build = b["build"]
    if build.is_a?(Hash)
      git_head = build["git_head"]
      if !git_head.is_a?(String) || git_head.strip.empty?
        reproducibility_gaps << { "record_index" => entry["record_index"], "source" => "runtime_binding.build.git_head", "gap" => "build.git_head missing; artifact provenance unverifiable." }
      end
    else
      reproducibility_gaps << { "record_index" => entry["record_index"], "source" => "runtime_binding.build", "gap" => "build binding missing; artifact reproducibility unverifiable." }
    end

    if entry["kind"] == "test" && entry["status"] == "pass"
      has_owner = %w[server browser].any? { |k| b[k].is_a?(Hash) && b[k]["owner"].is_a?(String) && !b[k]["owner"].strip.empty? }
      unless has_owner
        runtime_gaps << { "record_index" => entry["record_index"], "source" => "runtime_binding.server.owner|runtime_binding.browser.owner", "gap" => "real_path_test PASS without server/browser owner; runtime path not attributable." }
      end
    end
  end

  {
    "runtime_binding_count" => runtime_bindings.length,
    "runtime_bindings" => runtime_bindings,
    "cleanup_status" => {
      "records_with_cleanup_status" => cleanup_records,
      "statuses" => cleanup_counts,
      "incomplete_count" => cleanup_incomplete,
      "all_complete" => cleanup_records > 0 && cleanup_incomplete == 0
    },
    "reproducibility_gaps" => reproducibility_gaps,
    "runtime_gaps" => runtime_gaps,
    "has_gaps" => !reproducibility_gaps.empty? || !runtime_gaps.empty?
  }
end

def closure_checklist_for_handoff(task, evidence, validation, audit_blocking, audit_warnings, task_sha256: nil)
  source_documents = task.is_a?(Hash) && task["source_documents"].is_a?(Array) ? task["source_documents"] : []
  verdicts = latest_gate_verdicts_for_handoff(evidence, task_sha256, task)
  [
    {
      "item" => "task_contract_valid",
      "status" => validation["errors"].empty? ? "pass" : "blocked",
      "detail" => "validate error_count=#{validation["errors"].length}"
    },
    {
      "item" => "source_documents_referenced",
      "status" => source_documents.empty? ? "not_applicable" : "pass",
      "detail" => "source_documents=#{source_documents.length}"
    },
    {
      "item" => "latest_review_verdict",
      "status" => verdicts.dig("review", "status") || "missing",
      "detail" => verdicts.dig("review", "summary").to_s
    },
    {
      "item" => "latest_test_verdict",
      "status" => verdicts.dig("test", "status") || "missing",
      "detail" => verdicts.dig("test", "summary").to_s
    },
    {
      "item" => "known_gaps_recorded",
      "status" => audit_blocking.empty? && audit_warnings.empty? ? "pass" : "partial",
      "detail" => "blocking=#{audit_blocking.length}, warnings=#{audit_warnings.length}"
    }
  ]
end

def rule_resolution_summary(evidence, evidence_path = nil)
  summary = {
    "present" => false
  }
  return summary unless evidence.is_a?(Hash)

  reference = evidence["rule_resolution"]
  return summary if empty_rule_resolution_reference?(reference)

  unless reference.is_a?(Hash)
    return {
      "present" => true,
      "valid" => false,
      "error" => "evidence rule_resolution is not a mapping"
    }
  end

  path = rule_resolution_path_from_reference(reference, evidence_path)
  unless path
    return {
      "present" => true,
      "valid" => false,
      "error" => "evidence rule_resolution.file is empty"
    }
  end

  resolution = load_yaml(path)
  sources = resolution["sources"].is_a?(Hash) ? resolution["sources"] : {}
  checks = resolution["checks"].is_a?(Hash) ? resolution["checks"] : {}
  conflicts = resolution["conflicts"].is_a?(Array) ? resolution["conflicts"] : []

  {
    "present" => true,
    "file" => path,
    "schema_version" => resolution["schema_version"],
    "valid" => resolution["valid"],
    "resolved_role" => resolution["resolved_role"],
    "conflict_count" => conflicts.length,
    "missing_project_rule_files" => checks["missing_project_rule_files"].is_a?(Array) ? checks["missing_project_rule_files"] : [],
    "default_rule_count" => sources["orbit_default"].is_a?(Array) ? sources["orbit_default"].length : 0,
    "project_rule_count" => sources["project_rules"].is_a?(Array) ? sources["project_rules"].length : 0,
    "rule_pack_count" => sources["rule_packs"].is_a?(Array) ? sources["rule_packs"].length : 0,
    "task_rule_path" => sources.dig("task_rules", "path")
  }
rescue RuntimeError => e
  {
    "present" => true,
    "file" => path,
    "valid" => false,
    "error" => e.message
  }
end

def worktree_safety_summary(evidence)
  summary = {
    "present" => false
  }
  return summary unless evidence.is_a?(Hash)

  worktree = evidence["worktree_safety"]
  return summary unless worktree.is_a?(Hash)

  {
    "present" => true,
    "status" => worktree["status"],
    "mode" => worktree["status"] == "not_git" ? "non_git_project" : "git_or_not_applicable",
    "reason" => worktree["reason"],
    "status_before_present" => worktree["status_before"].is_a?(String) && !worktree["status_before"].empty?,
    "head_before_present" => worktree["head_before"].is_a?(String) && !worktree["head_before"].empty?,
    "unexpected_changes_count" => worktree["unexpected_changes"].is_a?(Array) ? worktree["unexpected_changes"].length : nil
  }.compact
end

def destructive_action_audit(evidence)
  return { "present" => false } unless evidence.is_a?(Hash)

  records = evidence["records"]
  return { "present" => false } unless records.is_a?(Array)

  plans = []
  recovery_gaps = []

  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)

    plan = record["destructive_action_plan"]
    next unless plan.is_a?(Hash)

    targets = plan["targets"]
    if targets.is_a?(Array)
      targets.each do |target|
        next unless target.is_a?(Hash)

        evidence_impact = target["evidence_impact"].to_s.strip
        recoverability = target["recoverability"].to_s.strip
        if !evidence_impact.empty? && evidence_impact != "none"
          unless %w[hash_only hash_and_backup full_backup].include?(recoverability)
            recovery_gaps << {
              "record_index" => index,
              "path" => target["path"],
              "evidence_impact" => evidence_impact,
              "recoverability" => recoverability.empty? ? nil : recoverability,
              "message" => "Evidence-affecting destructive target has insufficient recoverability."
            }.compact
          end
        end
      end
    end

    plans << {
      "record_index" => index,
      "action" => plan["action"],
      "dry_run" => plan["dry_run"],
      "target_count" => targets.is_a?(Array) ? targets.length : 0,
      "user_confirmation_required" => plan.dig("user_confirmation", "required"),
      "user_confirmation_received" => plan.dig("user_confirmation", "received")
    }.compact
  end

  return { "present" => false } if plans.empty?

  {
    "present" => true,
    "plan_count" => plans.length,
    "plans" => plans,
    "recovery_gaps" => recovery_gaps
  }
end

def validation_summary(validation)
  {
    "valid" => validation["errors"].empty?,
    "checked" => validation["checked"],
    "error_count" => validation["errors"].length,
    "warning_count" => validation["warnings"].length
  }
end

def audit_summary(phase, validation, audit_blocking, audit_warnings)
  trust_flags = audit_trust_flags(phase, audit_blocking, audit_warnings)
  {
    "trust_level" => audit_trust_level,
    "trusted_for_handoff" => validation["errors"].empty? && trust_flags["trusted_for_handoff"],
    "trusted_for_done" => validation["errors"].empty? && trust_flags["trusted_for_done"],
    "trusted_for_release" => validation["errors"].empty? && trust_flags["trusted_for_release"],
    "done_ready" => validation["errors"].empty? && trust_flags["trusted_for_done"],
    "blocking_count" => audit_blocking.length,
    "warning_count" => audit_warnings.length,
    "blocking_findings" => audit_blocking,
    "warnings" => audit_warnings
  }
end

def tools_summary
  doctor = tools_doctor_packet
  {
    "health" => doctor["health"],
    "runtime_adapter" => doctor["runtime_adapter"],
    "manual_payload_available" => doctor["manual_payload_available"],
    "findings_count" => doctor["findings"].length,
    "available" => doctor["detected"].each_with_object({}) do |tool, memo|
      memo[tool["name"]] = tool["available"]
    end
  }
end

def load_tools_config
  path = File.join(Dir.pwd, ".orbit", "tools.yaml")
  return [{}, nil, nil] unless File.file?(path)

  config = load_yaml(path)
  unless config.is_a?(Hash)
    return [{}, path, "tools.yaml must contain a mapping."]
  end

  [config, path, nil]
rescue RuntimeError => e
  [{}, path, e.message]
end

def default_manual_delivery_profile
  {
    "format" => "json",
    "delivery" => "manual"
  }
end

def configured_delivery_profiles(config)
  profiles = config["delivery_profiles"]
  return {} unless profiles.is_a?(Hash)

  profiles.select { |_name, profile| profile.is_a?(Hash) }
end

def configured_handoff_preference(config)
  preference = config["preference"]
  return nil unless preference.is_a?(Hash)

  handoff = preference["handoff"]
  return handoff if handoff.is_a?(String) && !handoff.empty?

  nil
end

def tool_available?(name, detected_by_name)
  return true if name == "generic"

  tool = detected_by_name[name]
  tool.is_a?(Hash) && tool["available"] == true
end

def resolve_delivery_profile
  config, config_path, config_error = load_tools_config
  configured_profiles = configured_delivery_profiles(config)
  profiles = { "manual" => default_manual_delivery_profile }.merge(configured_profiles)
  selected = configured_handoff_preference(config) || "manual"
  unless profiles.key?(selected)
    selected = "manual"
  end
  profile = profiles.fetch(selected, default_manual_delivery_profile)
  {
    "mode" => "manual_artifact",
    "runtime_adapter" => "none",
    "payload_format" => profile["format"] || "json",
    "selected" => selected,
    "source" => config_path || "builtin",
    "config_error" => config_error,
    "profile" => profile
  }.compact
end

def manual_handoff_payload(resolution, task_path, state_path, evidence_path, next_action)
  profile = resolution["profile"].is_a?(Hash) ? resolution["profile"] : {}
  {
    "schema_version" => "orbit-manual-delivery-payload-v1",
    "format" => profile["format"] || resolution["payload_format"] || "json",
    "delivery" => profile["delivery"] || profile["action"] || "manual",
    "task" => project_relative_persisted_path(task_path, field: "task"),
    "state" => project_relative_persisted_path(state_path, field: "state"),
    "evidence" => project_relative_persisted_path(evidence_path, field: "evidence"),
    "required_action" => next_action
  }
end

def judgment_summary(evidence)
  summary = {
    "review_judgment" => {
      "present" => false
    },
    "test_judgment" => {
      "present" => false
    }
  }
  return summary unless evidence.is_a?(Hash)

  records = evidence["records"].is_a?(Array) ? evidence["records"] : []
  review_judgment = evidence["review_judgment"]
  if review_judgment.is_a?(Hash)
    findings = review_judgment["findings"]
    summary["review_judgment"] = {
      "present" => true,
      "source" => "structured_judgment",
      "verdict" => review_judgment["verdict"],
      "quality_outcome_verdict" => review_judgment.dig("quality_outcome", "verdict"),
      "findings_count" => findings.is_a?(Array) ? findings.length : nil
    }
  elsif (latest_review = latest_record_for_kind(records, "review", structured_gate_only: true, gate_identity_required: true))
    summary["review_judgment"] = {
      "present" => true,
      "source" => "latest_evidence_record",
      "verdict" => latest_review["status"],
      "summary" => latest_review["summary"],
      "created_at" => latest_review["created_at"],
      "evidence_level" => latest_review["evidence_level"],
      "residual_risk" => latest_review["residual_risk"],
      "quality_outcome_verdict" => latest_review["quality_outcome_verdict"],
      "implementation_readiness_verdict" => latest_review["implementation_readiness_verdict"],
      "artifact_refs" => latest_review["artifact_refs"],
      "implementation_artifact_refs" => latest_review["implementation_artifact_refs"],
      "artifact_validation" => latest_review["artifact_validation"],
      "rule_application_summary" => rule_application_summary(latest_review["rule_application"]),
      "evidence_boundary_summary" => evidence_boundary_summary(latest_review)
    }
  end

  test_judgment = evidence["test_judgment"]
  if test_judgment.is_a?(Hash)
    scenarios = test_judgment["scenarios"]
    coverage_gap = test_judgment["coverage_gap"]
    summary["test_judgment"] = {
      "present" => true,
      "source" => "structured_judgment",
      "verdict" => test_judgment["verdict"],
      "scenario_count" => scenarios.is_a?(Array) ? scenarios.length : nil,
      "coverage_gap_count" => coverage_gap.is_a?(Array) ? coverage_gap.length : nil
    }
  elsif (latest_test = latest_record_for_kind(records, "test", structured_gate_only: true, gate_identity_required: true))
    summary["test_judgment"] = {
      "present" => true,
      "source" => "latest_evidence_record",
      "verdict" => latest_test["status"],
      "summary" => latest_test["summary"],
      "created_at" => latest_test["created_at"],
      "evidence_level" => latest_test["evidence_level"],
      "residual_risk" => latest_test["residual_risk"],
      "test_level" => latest_test["test_level"],
      "user_outcomes" => latest_test["user_outcomes"],
      "journey_validation" => latest_test["journey_validation"],
      "artifact_refs" => latest_test["artifact_refs"],
      "implementation_artifact_refs" => latest_test["implementation_artifact_refs"],
      "artifact_validation" => latest_test["artifact_validation"],
      "rule_application_summary" => rule_application_summary(latest_test["rule_application"]),
      "evidence_boundary_summary" => evidence_boundary_summary(latest_test)
    }
  end

  summary
end

def required_action_for_phase(phase, blocking_errors)
  return "resolve_blocking_errors" unless blocking_errors.empty?

  case phase
  when "in_review"
    "submit_review_evidence"
  when "in_test"
    "submit_test_evidence"
  when "working"
    "continue_work"
  when "implemented_not_independently_accepted"
    "obtain_independent_acceptance"
  when "blocked"
    "resolve_blocked_state"
  when "done"
    "none"
  else
    "inspect_state"
  end
end

def handoff(args)
  options = parse_handoff_args(args)
  task_path = File.expand_path(options["task"])
  state_path = File.expand_path(options["state"])
  evidence_path = File.expand_path(options["evidence"])
  output_path = options["output"] ? File.expand_path(options["output"]) : nil
  current_task_sha256 = sha256_file(task_path)
  validation, task, evidence, state = audit_validation_result(task_path, evidence_path, state_path)
  blocking_errors = validation["errors"].dup
  audit_blocking, audit_warnings = audit_state_consistency(task_path, evidence_path, state, evidence, task, task_sha256: current_task_sha256)
  blocking_errors.concat(audit_blocking)

  current_role = nil
  current_instance = nil
  if runtime_role_present?
    begin
      identity_result = {
        "project" => File.basename(Dir.pwd),
        "instance" => nil,
        "resolved_role" => nil,
        "role_sources" => {},
        "conflicts" => []
      }
      roles, instances = load_project_config(identity_result)
      resolve_identity(identity_result, roles, instances)
      unless identity_result["conflicts"].empty?
        raise SystemExit
      end
      current_role = identity_result["resolved_role"]
      current_instance = identity_result["resolved_instance"] || identity_result["instance"]
    rescue SystemExit
      blocking_errors << {
        "source" => "runtime_identity",
        "message" => "Runtime identity could not be resolved."
      }
    end
  end

  execution_contract = task_execution_contract(task)
  if current_role && task.is_a?(Hash) && !task_allows_instance_role?(task, current_instance, current_role)
    blocking_errors << {
      "source" => "runtime_identity",
      "message" => "Current identity #{current_role.inspect}/#{current_instance.inspect} is not task assigned_instance, owner_instance, or gate role."
    }
  end

  if options["record_state"] && blocking_errors.empty?
    record_handoff_artifact(state_path, output_path)
    validation, task, evidence, state = audit_validation_result(task_path, evidence_path, state_path)
    blocking_errors = validation["errors"].dup
    audit_blocking, audit_warnings = audit_state_consistency(task_path, evidence_path, state, evidence, task, task_sha256: current_task_sha256)
    blocking_errors.concat(audit_blocking)
    execution_contract = task_execution_contract(task)
    if current_role && task.is_a?(Hash) && !task_allows_instance_role?(task, current_instance, current_role)
      blocking_errors << {
        "source" => "runtime_identity",
        "message" => "Current identity #{current_role.inspect}/#{current_instance.inspect} is not task assigned_instance, owner_instance, or gate role."
      }
    end
  end

  current_phase = state.is_a?(Hash) ? state["phase"] : nil
  next_action = required_action_for_phase(current_phase, blocking_errors)
  delivery = resolve_delivery_profile
  delivery["payload"] = manual_handoff_payload(delivery, task_path, state_path, evidence_path, next_action)
  latest_gate_verdicts = latest_gate_verdicts_for_handoff(evidence, current_task_sha256, task)
  known_gaps = known_gaps_for_handoff(evidence, audit_warnings)
  runtime_summary = handoff_runtime_summary(evidence)
  reconcile_summary = runtime_reconcile_summary(evidence)
  arbitration_summary = verdict_arbitration_summary(task, evidence, current_task_sha256)
  decisions_summary = decision_record_summary(evidence)
  lease_summary = gate_lease_summary(evidence)
  closure_checklist = closure_checklist_for_handoff(task, evidence, validation, audit_blocking, audit_warnings, task_sha256: current_task_sha256)
  packet = {
    "schema_version" => "orbit-handoff-v1",
    "project" => task.is_a?(Hash) && task["project"] ? task["project"] : File.basename(Dir.pwd),
    "task" => project_relative_persisted_path(task_path, field: "task"),
    "task_id" => task.is_a?(Hash) ? task["task_id"] : nil,
    "task_revision" => task_revision_frozen?(task) ? {
      "revision_id" => task["revision_id"],
      "revision_number" => task["revision_number"],
      "latest_change" => Array(task["revision_history"]).last
    } : nil,
    "execution_contract" => execution_contract,
    "current_phase" => current_phase,
    "completion_semantics" => completion_semantics_for_phase(
      current_phase,
      trusted_for_done: current_phase == "done" && blocking_errors.empty? && audit_blocking.empty?
    ),
    "required_action" => next_action,
    "next_action" => next_action,
    "validation_summary" => validation_summary(validation),
    "audit_summary" => audit_summary(current_phase, validation, audit_blocking, audit_warnings),
    "tools_summary" => tools_summary,
    "delivery" => delivery,
    "rule_packs" => rule_packs_for_context(task_implementation_authority(task), task.is_a?(Hash) ? task["task_type"] : nil, include_audit: true),
    "rule_resolution_summary" => rule_resolution_summary(evidence, evidence_path),
    "gate_summary" => task.is_a?(Hash) && evidence.is_a?(Hash) ? required_gate_summary(task, evidence, task_sha256: current_task_sha256) : nil,
    "latest_gate_verdicts" => latest_gate_verdicts,
    "judgment_summary" => judgment_summary(evidence),
    "closure_checklist" => closure_checklist,
    "known_gaps" => known_gaps,
    "parent_goal_status" => task.is_a?(Hash) ? task["parent_goal_status"] : nil,
    "destructive_actions_summary" => destructive_action_audit(evidence),
    "readable_summary" => {
      "current_task" => project_relative_persisted_path(task_path, field: "task"),
      "phase" => current_phase,
      "next_action" => next_action,
      "latest_review_verdict" => latest_gate_verdicts.dig("review", "status"),
      "latest_test_verdict" => latest_gate_verdicts.dig("test", "status"),
      "known_gaps_count" => known_gaps.length,
      "runtime_binding_count" => runtime_summary["runtime_binding_count"],
      "cleanup_all_complete" => runtime_summary["cleanup_status"]["all_complete"],
      "runtime_gaps_count" => runtime_summary["runtime_gaps"].length,
      "reproducibility_gaps_count" => runtime_summary["reproducibility_gaps"].length,
      "gate_lease_active" => lease_summary["active_count"].to_i,
      "gate_lease_expired" => lease_summary["expired_count"].to_i,
      "gate_owner_replaceable" => lease_summary["any_replaceable"],
      "active_decisions_count" => decisions_summary["active_count"].to_i,
      "expired_decisions_count" => decisions_summary["expired_count"].to_i
    },
    "runtime_summary" => runtime_summary,
    "runtime_reconcile_summary" => reconcile_summary,
    "verdict_arbitration" => arbitration_summary,
    "gate_lease_summary" => lease_summary,
    "decision_record_summary" => decisions_summary,
    "trust_repair_summary" => trust_repair_summary(evidence),
    "data_classification_summary" => data_classification_summary(evidence),
    "negative_evidence_summary" => negative_evidence_summary(evidence),
    "worktree_safety_summary" => worktree_safety_summary(evidence),
    "evidence_summary" => evidence_summary(evidence),
    "schema_version_summary" => evidence_schema_version_summary(evidence, task.is_a?(Hash) ? task : nil),
    "release_readiness_summary" => release_readiness_summary(task),
    "release_blockers" => release_risk?(task) ? release_readiness_blockers(task.is_a?(Hash) ? task["release_readiness"] : nil, task) : [],
    "dogfood_governance_summary" => dogfood_governance_summary(task),
    "compatibility_policy_summary" => compatibility_policy_summary(task),
    "multi_user_ownership_summary" => multi_user_ownership_summary(task),
    "self_review_guard_summary" => self_review_guard_summary(task),
    "quality_calibration_summary" => quality_calibration_summary(task),
    "risk_level_tradeoff_summary" => risk_level_tradeoff_summary(task),
    "blocking_errors" => blocking_errors
  }
  packet = portable_paths_for_summary(packet)

  json = JSON.pretty_generate(packet)
  write_handoff_artifact(output_path, json) if output_path

  puts json
  exit(blocking_errors.empty? ? 0 : 1)
end

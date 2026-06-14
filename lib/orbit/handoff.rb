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
    when "--transport"
      options["transport"] = option_value(args, "--transport")
    when /\A--transport=(.+)\z/
      options["transport"] = Regexp.last_match(1)
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
  usage_error("handoff currently requires --json") unless options["json"]
  if options["record_state"] && (options["output"].nil? || options["output"].empty?)
    usage_error("--record-state requires --output so loop state can reference a stable handoff artifact.")
  end

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
    state["artifacts"]["handoff_packet"] = File.expand_path(handoff_path)
    state["updated_at"] = now
    append_state_history(state, {
      "event" => "handoff",
      "handoff_packet" => File.expand_path(handoff_path),
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
    "aggregate_verdict" => evidence["verdict"],
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
    summary["latest"] = records.last
  elsif evidence["verdict"].is_a?(Hash)
    summary["records"] = 1
    summary["latest"] = evidence["verdict"]
  end

  summary
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
    "preferred_transport" => doctor["preferred_transport"],
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

def default_generic_transport_profile
  {
    "handoff" => {
      "format" => "json",
      "delivery" => "manual"
    }
  }
end

def configured_transport_profiles(config)
  profiles = config["transport_profiles"]
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

def resolve_transport_profile(requested_transport)
  config, config_path, config_error = load_tools_config
  configured_profiles = configured_transport_profiles(config)
  profiles = { "generic" => default_generic_transport_profile }.merge(configured_profiles)
  requested = requested_transport || configured_handoff_preference(config) || "generic"
  detected_by_name = detect_tools.to_h { |tool| [tool["name"], tool] }
  selected = requested
  reason = nil
  fallback_used = false

  unless profiles.key?(selected)
    reason = "Transport profile #{selected.inspect} is not configured; using generic."
    selected = "generic"
    fallback_used = true
  end

  unless tool_available?(selected, detected_by_name)
    reason = "Transport #{selected.inspect} is unavailable; using generic."
    selected = "generic"
    fallback_used = true
  end

  profile = profiles.fetch(selected, default_generic_transport_profile)
  {
    "requested" => requested,
    "selected" => selected,
    "fallback_used" => fallback_used,
    "source" => config_path || "builtin",
    "config_error" => config_error,
    "reason" => reason,
    "profile" => profile
  }.compact
end

def transport_handoff_payload(resolution, task_path, state_path, evidence_path, next_action)
  profile = resolution["profile"].is_a?(Hash) ? resolution["profile"] : {}
  handoff_config = profile["handoff"].is_a?(Hash) ? profile["handoff"] : {}
  {
    "schema_version" => "orbit-transport-payload-v1",
    "transport" => resolution["selected"],
    "format" => handoff_config["format"] || "json",
    "delivery" => handoff_config["delivery"] || handoff_config["action"] || "manual",
    "task" => task_path,
    "state" => state_path,
    "evidence" => evidence_path,
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
      "created_at" => latest_review["created_at"]
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
      "created_at" => latest_test["created_at"]
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
  validation, task, evidence, state = audit_validation_result(task_path, evidence_path, state_path)
  blocking_errors = validation["errors"].dup
  audit_blocking, audit_warnings = audit_state_consistency(task_path, evidence_path, state, evidence, task)
  blocking_errors.concat(audit_blocking)

  current_role = nil
  if runtime_role_present?
    begin
      current_role = resolved_runtime_role
    rescue SystemExit
      blocking_errors << {
        "source" => "runtime_identity",
        "message" => "Runtime identity could not be resolved."
      }
    end
  end

  target_role = task.is_a?(Hash) ? task["target_role"] : nil
  if current_role && target_role && current_role != target_role && !task_gate_role?(task, current_role)
    blocking_errors << {
      "source" => "runtime_identity",
      "message" => "Current role #{current_role.inspect} does not match task target_role #{target_role.inspect}."
    }
  end

  if options["record_state"] && blocking_errors.empty?
    record_handoff_artifact(state_path, output_path)
    validation, task, evidence, state = audit_validation_result(task_path, evidence_path, state_path)
    blocking_errors = validation["errors"].dup
    audit_blocking, audit_warnings = audit_state_consistency(task_path, evidence_path, state, evidence, task)
    blocking_errors.concat(audit_blocking)
    target_role = task.is_a?(Hash) ? task["target_role"] : nil
    if current_role && target_role && current_role != target_role && !task_gate_role?(task, current_role)
      blocking_errors << {
        "source" => "runtime_identity",
        "message" => "Current role #{current_role.inspect} does not match task target_role #{target_role.inspect}."
      }
    end
  end

  current_phase = state.is_a?(Hash) ? state["phase"] : nil
  next_action = required_action_for_phase(current_phase, blocking_errors)
  transport_profile = resolve_transport_profile(options["transport"])
  transport_profile["payload"] = transport_handoff_payload(transport_profile, task_path, state_path, evidence_path, next_action)
  packet = {
    "schema_version" => "orbit-handoff-v1",
    "project" => task.is_a?(Hash) && task["project"] ? task["project"] : File.basename(Dir.pwd),
    "task" => task_path,
    "target_role" => target_role,
    "current_phase" => current_phase,
    "required_action" => next_action,
    "next_action" => next_action,
    "validation_summary" => validation_summary(validation),
    "audit_summary" => audit_summary(current_phase, validation, audit_blocking, audit_warnings),
    "tools_summary" => tools_summary,
    "transport_profile" => transport_profile,
    "rule_packs" => rule_packs_for_context(target_role, task.is_a?(Hash) ? task["task_type"] : nil, include_audit: true),
    "rule_resolution_summary" => rule_resolution_summary(evidence, evidence_path),
    "gate_summary" => task.is_a?(Hash) && evidence.is_a?(Hash) ? required_gate_summary(task, evidence) : nil,
    "judgment_summary" => judgment_summary(evidence),
    "worktree_safety_summary" => worktree_safety_summary(evidence),
    "evidence_summary" => evidence_summary(evidence),
    "blocking_errors" => blocking_errors
  }

  json = JSON.pretty_generate(packet)
  write_handoff_artifact(output_path, json) if output_path

  puts json
  exit(blocking_errors.empty? ? 0 : 1)
end

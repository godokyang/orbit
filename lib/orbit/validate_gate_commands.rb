def empty_rule_resolution_reference?(reference)
  return true if reference.nil?
  return false unless reference.is_a?(Hash)

  reference["file"].to_s.empty? &&
    reference["valid"].nil? &&
    reference["resolved_role"].to_s.empty?
end

def rule_resolution_path_from_reference(reference, evidence_path)
  path = reference["file"]
  return nil unless path.is_a?(String) && !path.strip.empty?

  return File.expand_path(path) if path.start_with?("/")

  base_dir = evidence_path ? File.dirname(File.expand_path(evidence_path)) : Dir.pwd
  File.expand_path(path, base_dir)
end

def load_rule_resolution_for_validation(result, source, path)
  data = load_validation_file(result, source, path)
  return nil unless data

  unless data["schema_version"] == "orbit-rule-resolution-v1"
    validation_error(result, "#{source}.schema_version", "Rule resolution schema_version must be orbit-rule-resolution-v1.")
  end

  data
end

def validate_rule_resolution_reference(result, evidence_path, evidence, task = nil)
  reference = evidence["rule_resolution"]
  return if empty_rule_resolution_reference?(reference)

  unless reference.is_a?(Hash)
    validation_error(result, "evidence_file.rule_resolution", "Evidence rule_resolution must be a mapping when present.")
    return
  end

  path = rule_resolution_path_from_reference(reference, evidence_path)
  unless path
    validation_error(result, "evidence_file.rule_resolution.file", "Evidence rule_resolution.file must be a non-empty string.")
    return
  end

  resolution = load_rule_resolution_for_validation(result, "evidence_file.rule_resolution.file", path)
  return unless resolution

  conflicts = resolution["conflicts"]
  unless conflicts.is_a?(Array)
    validation_error(result, "evidence_file.rule_resolution.conflicts", "Rule resolution conflicts must be a list.")
    conflicts = []
  end

  unless resolution["valid"] == true
    validation_error(result, "evidence_file.rule_resolution.valid", "Attached rule resolution must be valid.")
  end

  if reference.key?("valid") && reference["valid"] != resolution["valid"]
    validation_error(result, "evidence_file.rule_resolution.valid", "Evidence rule_resolution.valid does not match attached rule resolution.")
  end

  if reference["resolved_role"].is_a?(String) &&
     !reference["resolved_role"].empty? &&
     reference["resolved_role"] != resolution["resolved_role"]
    validation_error(result, "evidence_file.rule_resolution.resolved_role", "Evidence rule_resolution.resolved_role does not match attached rule resolution.")
  end

  if task.is_a?(Hash)
    task_path = resolution.dig("sources", "task_rules", "path")
    if task_path.nil? || task_path.to_s.empty?
      validation_error(result, "evidence_file.rule_resolution.task", "Attached rule resolution must include task_rules for the current task.")
    elsif File.expand_path(task_path) != File.expand_path(task["__orbit_path"] || "")
      validation_error(result, "evidence_file.rule_resolution.task", "Attached rule resolution was generated for a different task.")
    end

    target_role = task["target_role"]
    if target_role && resolution["resolved_role"] && target_role != resolution["resolved_role"] && !task_gate_role?(task, resolution["resolved_role"])
      validation_error(result, "evidence_file.rule_resolution.resolved_role", "Attached rule resolution role does not match task target_role.")
    end
  end
end

def validate_evidence(result, evidence_path, task = nil, task_sha256: nil)
  evidence = load_validation_file(result, "evidence_file", evidence_path)
  return nil unless evidence

  ev_compat = schema_version_compat(evidence["schema_version"], "evidence")
  case ev_compat
  when :current
    # OK – known schema version
  when :legacy
    validation_error(result, "evidence_file.schema_version", "Evidence schema_version must be orbit-evidence-v1.")
  when :unknown_future
    entry = schema_unknown_version_entry("evidence_file.schema_version", evidence["schema_version"], "evidence")
    validation_error(result, "evidence_file.schema_version",
      "#{entry["message"]} #{entry["action"]}")
  end

  # Legacy warning: schema_semantics absent means record predates schema versioning.
  # This is a warning only – historical records remain readable per global compatibility policy.
  if ev_compat == :current && evidence["schema_semantics"].nil?
    validation_warning(result, "evidence_file.schema_semantics",
      "legacy_warning: Evidence manifest lacks schema_semantics; " \
      "feature version tracking unavailable. " \
      "Record was created before orbit-schema-versioning-v1. " \
      "Historical records remain readable.")
  end

  records = evidence["records"]
  if records
    unless records.is_a?(Array)
      validation_error(result, "evidence_file.records", "Evidence records must be a list.")
      records = []
    end

    records.each_with_index do |record, index|
      validate_evidence_record(result, "evidence_file.records[#{index}]", record)
    end
  end

  verdict = evidence["verdict"]
  if verdict
    unless verdict.is_a?(Hash)
      validation_error(result, "evidence_file.verdict", "Evidence verdict must be a mapping.")
      return evidence
    end

    status = verdict["status"]
    unless ALLOWED_EVIDENCE_VERDICT_STATUSES.include?(status)
      validation_error(result, "evidence_file.verdict.status", "Evidence verdict.status must be one of #{ALLOWED_EVIDENCE_VERDICT_STATUSES.join("|")}.")
    end
  elsif !records
    validation_error(result, "evidence_file.verdict", "Evidence must define verdict mapping or records list.")
  end

  validate_waivers(result, evidence["waivers"])
  validate_review_judgment(result, evidence["review_judgment"]) if evidence.key?("review_judgment")
  validate_test_judgment(result, evidence["test_judgment"]) if evidence.key?("test_judgment")
  validate_worktree_safety(result, evidence["worktree_safety"])
  validate_regression_guard(result, evidence["regression_guard"])
  validate_release_surface(result, evidence["release_surface"])
  validate_tool_calls(result, evidence["tool_calls"])
  validate_rule_resolution_reference(result, evidence_path, evidence, task)
  if task && records.is_a?(Array)
    validate_test_pass_environment_evidence(result, records, task)
    validate_quality_measurement_evidence(result, records, task)
  end

  if task && records.is_a?(Array) && !records.empty? && required_evidence_kinds(task).any?
    validate_required_gate_evidence(result, records, task, task_sha256)
  elsif task && review_or_test_gate?(task) && records.is_a?(Array) && !records.empty?
    expected_kind = expected_evidence_kind(task)
    validate_gate_verdict(result, records, expected_kind, task, task_sha256: task_sha256)
  end

  evidence
end

def validate_required_gate_evidence(result, records, task, task_sha256 = nil)
  return unless task.is_a?(Hash)

  required_evidence_kinds(task).each do |expected_kind|
    validate_gate_verdict(result, records.is_a?(Array) ? records : [], expected_kind, task, task_sha256: task_sha256)
  end
end

def evidence_has_done_signal?(evidence)
  return false unless evidence.is_a?(Hash)

  records = evidence["records"]
  if records.is_a?(Array)
    return true if records.any? { |record| record.is_a?(Hash) && record["status"] == "pass" }
  end

  verdict = evidence["verdict"]
  verdict.is_a?(Hash) && verdict["status"] == "pass"
end

def expected_gate_role(kind)
  EXPECTED_GATE_ROLES[kind]
end

# Reads resolved_role from role_execution_context (Slice 6) or identity (Slice 5 compat).
def record_resolved_role(record)
  ctx = record["role_execution_context"]
  # When role_execution_context is a Hash it is authoritative; no identity fallback
  return (ctx["resolved_role"].is_a?(String) && !ctx["resolved_role"].empty? ? ctx["resolved_role"] : nil) if ctx.is_a?(Hash)
  return nil if record.key?("role_execution_context") # present but non-Hash: malformed

  identity = record["identity"]
  identity.is_a?(Hash) ? identity["resolved_role"] : nil
end

# Reads task_sha256 from role_execution_context (Slice 6) or identity (Slice 5 compat).
def record_task_sha256_from(record)
  ctx = record["role_execution_context"]
  return (ctx["task_sha256"].is_a?(String) && !ctx["task_sha256"].empty? ? ctx["task_sha256"] : nil) if ctx.is_a?(Hash)
  return nil if record.key?("role_execution_context") # present but non-Hash: malformed

  identity = record["identity"]
  identity.is_a?(Hash) ? identity["task_sha256"] : nil
end

# Reads rules_context_sha256 from role_execution_context (Slice 6) or identity (Slice 5 compat).
def record_rules_context_sha256_from(record)
  ctx = record["role_execution_context"]
  if ctx.is_a?(Hash)
    return ctx["rules_context_sha256"] if !ctx["rules_context_sha256"].to_s.empty?
    return ctx["rules_resolution_sha256"] if !ctx["rules_resolution_sha256"].to_s.empty?
    return nil # Hash present but fields absent: no identity fallback
  end
  return nil if record.key?("role_execution_context") # present but non-Hash: malformed

  identity = record["identity"]
  identity.is_a?(Hash) ? identity["rules_context_sha256"] : nil
end

def record_identity_role(record)
  record_resolved_role(record)
end

def gate_record_identity_valid?(record, kind)
  expected_role = expected_gate_role(kind)
  return true unless expected_role

  record_identity_role(record) == expected_role
end

def latest_record_for_kind(records, kind, structured_gate_only: false, gate_identity_required: false)
  return nil unless records.is_a?(Array)

  candidates = []
  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)
    next unless record["kind"] == kind
    next if record["status"] == "invalid"
    next if structured_gate_only && STRUCTURED_SUBMIT_KINDS.include?(kind) && record["structured_submit"] != true
    next if gate_identity_required && !gate_record_identity_valid?(record, kind)

    begin
      created_at = Time.iso8601(record["created_at"].to_s)
    rescue ArgumentError
      next
    end
    candidates << [created_at, index, record]
  end
  candidates.max_by { |created_at, index, _record| [created_at, index] }&.last
end

def gate_passed?(records, kind, task_sha256: nil)
  result = { "errors" => [], "warnings" => [] }
  latest = latest_valid_gate_record(result, records, kind, task_sha256)
  latest&.fetch("status", nil) == "pass"
end

def parse_wait_gate_args(args)
  options = {
    "json" => false
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--evidence"
      options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      options["evidence"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown wait-gate option: #{arg}")
    end
  end

  usage_error("Missing required option: --task") if options["task"].nil? || options["task"].empty?
  usage_error("Missing required option: --evidence") if options["evidence"].nil? || options["evidence"].empty?
  usage_error("wait-gate currently requires --json") unless options["json"]
  options
end

def gate_status(records, kind, task = nil, task_sha256: nil)
  evidence_record_kind = GATE_KIND_EVIDENCE_RECORD_KIND[kind] || kind
  # Slice 9: arbitration is authoritative for which record can pass the gate.
  # When a current task_sha256 is supplied, a stale (old task sha) verdict is ignored and
  # cannot close the gate. Records without a stored task_sha256 (legacy evidence predating
  # identity capture) are still accepted by arbitration for backward compatibility.
  # raw_latest is kept for flag reporting (stale_task_sha256) even when the accepted record is nil.
  arbitration = verdict_arbitration_for_gate(records, kind, task_sha256)
  raw_latest = latest_record_for_kind(records, evidence_record_kind, structured_gate_only: true, gate_identity_required: false)
  stale_verdict_only = task_sha256 && arbitration["accepted_record"].nil? && arbitration["has_stale"]
  latest = stale_verdict_only ? nil : (arbitration["accepted_record"] || raw_latest)
  expected_role = expected_gate_role(kind)
  malformed_rec_ctx = latest.is_a?(Hash) && latest.key?("role_execution_context") && !latest["role_execution_context"].is_a?(Hash)
  identity_role = latest && !malformed_rec_ctx ? record_resolved_role(latest) : nil
  identity_valid = latest && !malformed_rec_ctx ? gate_record_identity_valid?(latest, kind) : false
  status = latest ? latest["status"] : "missing"
  display_status = latest.is_a?(Hash) && latest["blocked"].is_a?(Hash) ? "blocked" : status
  minimum_evidence_level = task_minimum_evidence_level_for_gate(task, kind)
  actual_evidence_level = latest.is_a?(Hash) ? latest["evidence_level"] : nil
  quality_evidence_fields_ok = !task_requires_quality_evidence_fields?(task) || status != "pass" || ALLOWED_EVIDENCE_LEVELS.include?(actual_evidence_level.to_s)
  wrong_gate_kind_level = !latest.nil? && status == "pass" && !evidence_level_valid_for_gate_kind?(actual_evidence_level, kind)
  evidence_level_ok = latest.nil? || status != "pass" || wrong_gate_kind_level || evidence_level_satisfies_minimum?(actual_evidence_level, minimum_evidence_level)
  # For structured review evidence passes (review and design_readiness gates): quality_outcome_verdict
  # must be "pass" AND all required_questions must have verdict "pass".
  quality_outcome_ok = if evidence_record_kind == "review" && latest.is_a?(Hash) && latest["structured_submit"] == true && status == "pass"
                         latest["quality_outcome_verdict"] == "pass"
                       else
                         true
                       end
  required_questions_ok = if evidence_record_kind == "review" && latest.is_a?(Hash) && latest["structured_submit"] == true && status == "pass"
                             required_questions_all_pass?(latest, task)
                           else
                             true
                           end
  write_violations = latest.is_a?(Hash) && latest["write_policy"].is_a?(Hash) && latest["write_policy"]["violations"].is_a?(Array) ? latest["write_policy"]["violations"].reject { |v| v.to_s.strip.empty? } : []
  write_policy_enforcement = task.is_a?(Hash) ? (task["write_policy_enforcement"] || "standard").to_s : "standard"
  write_policy_blocked = !write_violations.empty? && write_policy_enforcement == "strict" && expected_gate_role(kind) != nil
  stored_task_sha256 = raw_latest ? record_task_sha256_from(raw_latest) : nil
  stored_rules_context_sha256 = latest ? record_rules_context_sha256_from(latest) : nil
  missing_task_sha256 = latest.is_a?(Hash) && latest["structured_submit"] == true && expected_gate_role(kind) != nil && stored_task_sha256.nil?
  task_sha256_blocked = missing_task_sha256 && write_policy_enforcement == "strict"
  stale_task_sha256 = !!(task_sha256 && stored_task_sha256 && stored_task_sha256 != task_sha256)
  stale_blocked = stale_task_sha256 && write_policy_enforcement == "strict"
  missing_rules_context_sha256 = latest.is_a?(Hash) && latest["structured_submit"] == true && expected_gate_role(kind) != nil && stored_rules_context_sha256.nil?
  rules_context_blocked = missing_rules_context_sha256 && write_policy_enforcement == "strict"
  blocking_reason = if latest.nil? && stale_verdict_only
                      "stale_verdict"
                    elsif latest.nil?
                      "missing"
                    elsif malformed_rec_ctx
                      "malformed_role_execution_context"
                    elsif !identity_valid
                      "identity_mismatch"
                    elsif !quality_evidence_fields_ok
                      "missing_evidence_level"
                    elsif wrong_gate_kind_level
                      "evidence_level_wrong_gate_kind"
                    elsif !evidence_level_ok
                      "evidence_level_below_minimum"
                    elsif !quality_outcome_ok
                      "quality_outcome_not_pass"
                    elsif !required_questions_ok
                      "required_questions_not_met"
                    elsif task_sha256_blocked
                      "missing_task_sha256"
                    elsif stale_blocked
                      "stale_task_sha256"
                    elsif rules_context_blocked
                      "missing_rules_context_sha256"
                    elsif write_policy_blocked
                      "write_policy_violations"
                    elsif display_status != "pass"
                      display_status
                    end
  {
    "kind" => kind,
    "required" => true,
    "status" => display_status,
    "record_status" => status,
    "passed" => !stale_verdict_only && status == "pass" && !malformed_rec_ctx && identity_valid && quality_evidence_fields_ok && !wrong_gate_kind_level && evidence_level_ok && quality_outcome_ok && required_questions_ok && !write_policy_blocked && !task_sha256_blocked && !stale_blocked && !rules_context_blocked,
    "structured" => latest.is_a?(Hash) ? latest["structured_submit"] == true : false,
    "evidence_level" => actual_evidence_level,
    "minimum_evidence_level" => minimum_evidence_level,
    "residual_risk" => latest.is_a?(Hash) ? latest["residual_risk"] : nil,
    "quality_outcome_verdict" => latest.is_a?(Hash) ? latest["quality_outcome_verdict"] : nil,
    "implementation_readiness_verdict" => latest.is_a?(Hash) ? latest["implementation_readiness_verdict"] : nil,
    "test_level" => latest.is_a?(Hash) ? latest["test_level"] : nil,
    "rule_application_summary" => latest.is_a?(Hash) ? rule_application_summary(latest["rule_application"]) : nil,
    "evidence_boundary_summary" => latest.is_a?(Hash) ? evidence_boundary_summary(latest) : nil,
    "identity_expected_role" => expected_role,
    "identity_resolved_role" => identity_role,
    "identity_valid" => identity_valid,
    "malformed_role_execution_context" => malformed_rec_ctx ? true : nil,
    "missing_task_sha256" => missing_task_sha256 ? true : nil,
    "stale_task_sha256" => stale_task_sha256 ? true : nil,
    "missing_rules_context_sha256" => missing_rules_context_sha256 ? true : nil,
    "write_policy_violations_count" => write_violations.empty? ? nil : write_violations.length,
    "blocking_reason" => blocking_reason,
    "blocked" => latest.is_a?(Hash) ? latest["blocked"] : nil,
    "latest" => latest,
    "verdict_arbitration" => {
      "accepted_record_id" => arbitration["accepted_record_id"],
      "superseded_records" => arbitration["superseded_records"],
      "stale_records" => arbitration["stale_records"],
      "conflict_detected" => arbitration["conflict_detected"],
      "has_stale" => arbitration["has_stale"],
      "conflict_resolution" => arbitration["conflict_resolution"]
    }
  }.compact
end

def required_gate_summary(task, evidence, task_sha256: nil)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  gates = required_evidence_kinds(task).map { |kind| gate_status(records, kind, task, task_sha256: task_sha256) }
  missing_or_blocked = gates.reject { |gate| gate["passed"] }.map do |gate|
    {
      "kind" => gate["kind"],
      "status" => gate["status"],
      "blocking_reason" => gate["blocking_reason"],
      "evidence_level" => gate["evidence_level"],
      "minimum_evidence_level" => gate["minimum_evidence_level"]
    }.compact
  end
  {
    "ready" => missing_or_blocked.empty?,
    "required" => gates.map { |gate| gate["kind"] },
    "passed" => gates.select { |gate| gate["passed"] }.map { |gate| gate["kind"] },
    "evidence_levels" => gates.each_with_object({}) { |gate, memo| memo[gate["kind"]] = gate["evidence_level"] if gate["evidence_level"] },
    "not_ready" => missing_or_blocked
  }
end

def wait_gate(args)
  options = parse_wait_gate_args(args)
  task_path, task = load_dispatch_task(options["task"])
  current_task_sha256 = sha256_file(File.expand_path(options["task"]))
  evidence_path = File.expand_path(options["evidence"])
  evidence = load_evidence_manifest(evidence_path)
  records = evidence["records"].is_a?(Array) ? evidence["records"] : []
  kinds = required_evidence_kinds(task)
  gates = kinds.map { |kind| gate_status(records, kind, task, task_sha256: current_task_sha256) }
  ready = gates.all? { |gate| gate["passed"] }
  arbitration_summary = verdict_arbitration_summary(task, evidence, current_task_sha256)
  lease_summary = gate_lease_summary(evidence)
  gate_summary = required_gate_summary(task, evidence, task_sha256: current_task_sha256)
  packet = {
    "schema_version" => "orbit-gate-status-v1",
    "project" => task["project"] || File.basename(Dir.pwd),
    "task" => task_path,
    "evidence" => evidence_path,
    "ready" => ready,
    "aggregate_verdict" => evidence["verdict"],
    "gate_summary" => gate_summary,
    "gates" => gates,
    "parent_goal_status" => task.is_a?(Hash) ? task["parent_goal_status"] : nil,
    "verdict_arbitration" => arbitration_summary,
    "gate_lease_summary" => lease_summary,
    "summary" => ready ? "all required gates pass" : "required gates are not ready"
  }.compact

  puts JSON.pretty_generate(packet)
  exit(1) unless ready
end

def validate_done_transition!(state_path, task_path, evidence_path)
  state_error("Transition to done requires current_task in loop state.") if task_path.nil? || task_path.empty?
  state_error("Transition to done requires --evidence.") if evidence_path.nil? || evidence_path.empty?

  result = {
    "schema_version" => "orbit-validate-v1",
    "project" => File.basename(Dir.pwd),
    "checked" => [],
    "trust_level" => audit_trust_level,
    "valid" => false,
    "errors" => [],
    "warnings" => []
  }

  validate_project_config(result)
  result["checked"] << "project_config"
  task = validate_task(result, task_path)
  result["checked"] << "task"
  evidence = validate_evidence(result, evidence_path, task, task_sha256: sha256_file(task_path))
  result["checked"] << "evidence"
  validate_state_file(result, state_path)
  result["checked"] << "state"

  unless evidence_has_done_signal?(evidence)
    validation_error(result, "evidence_file", "Transition to done requires at least one pass evidence signal.")
  end

  validate_required_gate_evidence(result, evidence.is_a?(Hash) ? evidence["records"] : [], task, sha256_file(task_path))

  return if result["errors"].empty?

  details = result["errors"].map { |error| "#{error["source"]}: #{error["message"]}" }.join("; ")
  state_error("Transition to done requires valid task, evidence, and state: #{details}")
end

def validate_state_file(result, state_path)
  state = load_validation_file(result, "state_file", state_path)
  return nil unless state

  unless state["schema_version"] == "orbit-loop-state-v1"
    validation_error(result, "state_file.schema_version", "Loop state schema_version must be orbit-loop-state-v1.")
  end

  phase = state["phase"]
  unless ALLOWED_LOOP_PHASES.include?(phase)
    validation_error(result, "state_file.phase", "Loop state phase must be one of #{ALLOWED_LOOP_PHASES.join("|")}.")
  end

  unless state["history"].is_a?(Array)
    validation_error(result, "state_file.history", "Loop state history must be a list.")
  end

  state
end

def print_validation_result(result, json)
  result["valid"] = result["errors"].empty?

  if json
    puts JSON.pretty_generate(result)
    return
  end

  if result["valid"]
    puts "Validation passed."
  else
    puts "Validation failed:"
    result["errors"].each do |error|
      puts "- #{error["source"]}: #{error["message"]}"
    end
  end

  return if result["warnings"].empty?

  puts
  puts "Warnings:"
  result["warnings"].each do |warning|
    puts "- #{warning["source"]}: #{warning["message"]}"
  end
end

def validate(args)
  options = parse_validate_args(args)
  result = {
    "schema_version" => "orbit-validate-v1",
    "project" => File.basename(Dir.pwd),
    "checked" => [],
    "trust_level" => audit_trust_level,
    "valid" => false,
    "errors" => [],
    "warnings" => []
  }

  validate_project_config(result)
  result["checked"] << "project_config"

  task = nil
  if options["task"]
    task = validate_task(result, options["task"])
    result["checked"] << "task"
  end

  if options["evidence"]
    current_task_sha256 = options["task"] ? sha256_file(File.expand_path(options["task"])) : nil
    validate_evidence(result, options["evidence"], task, task_sha256: current_task_sha256)
    result["checked"] << "evidence"
  elsif task && review_or_test_gate?(task)
    validation_error(result, "evidence_file", "Task review/test gates require --evidence manifest before passing.")
  end

  if options["state"]
    validate_state_file(result, options["state"])
    result["checked"] << "state"
  end

  validate_scope_changed_files(result, task, options["changed_files"]) if task && options["changed_files"]

  validation_warning(result, "validate", "No task, evidence, or state file was provided; only project config was checked.") unless options["task"] || options["evidence"] || options["state"]

  print_validation_result(result, options["json"])
  exit(result["errors"].empty? ? 0 : 1)
end

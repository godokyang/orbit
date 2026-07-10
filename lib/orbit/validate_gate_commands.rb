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
    task_sha256 = resolution["task_sha256"]
    if !task_sha256.is_a?(String) || task_sha256.empty?
      validation_error(result, "evidence_file.rule_resolution.task_sha256", "Attached rule resolution must record task_sha256.")
    elsif task["__orbit_path"] && task_sha256 != sha256_file(task["__orbit_path"])
      pre_freeze_sha = Array(task["revision_history"]).first&.dig("pre_freeze_task_sha256")
      pre_freeze_compatible = task_revision_frozen?(task) && task["revision_number"].to_i == 1 && task_sha256 == pre_freeze_sha
      unless pre_freeze_compatible
        validation_error(result, "evidence_file.rule_resolution.task_sha256", "Attached rule resolution task_sha256 does not match current task revision.")
      end
    end

    resolved_role = resolution["resolved_role"]
    resolved_instance = resolution["instance"] || resolution["resolved_instance"]
    if resolved_role && !task_gate_role?(task, resolved_role)
      if resolved_role != task_implementation_authority(task)
        validation_error(result, "evidence_file.rule_resolution.resolved_role", "Attached rule resolution role does not match task implementation_authority or a task gate role.")
      elsif !resolved_instance.to_s.empty? &&
            resolved_instance != task_assigned_instance(task) &&
            !valid_implementation_override_for_identity(task, evidence, resolved_role, resolved_instance)
        validation_error(result, "evidence_file.rule_resolution.instance", "Attached rule resolution instance does not match task assigned_instance.")
      elsif resolved_instance.to_s.empty?
        validation_error(result, "evidence_file.rule_resolution.instance", "Attached implementation rule resolution must record instance.")
      end
    end
  end
end

def validate_implementation_records_for_task(result, records, task)
  return unless task.is_a?(Hash)

  records.each_with_index do |record, index|
    next unless record.is_a?(Hash) && record["kind"] == "implementation"

    expected_task_sha = task["__orbit_path"] ? sha256_file(task["__orbit_path"]) : nil
    if task_revision_frozen?(task)
      next unless evidence_record_revision_eligible?(record, task, "implementation", expected_task_sha)
    end

    ctx = record["role_execution_context"]
    unless ctx.is_a?(Hash)
      validation_error(result, "evidence_file.records[#{index}].role_execution_context", "implementation evidence must include role_execution_context.")
      next
    end

    required_fields = %w[
      owner_role
      owner_instance
      operation_mode
      implementation_authority
      assigned_instance
      resolved_role
      resolved_instance
      execution_contract_source
    ]
    required_fields.each do |field|
      unless ctx[field].is_a?(String) && !ctx[field].strip.empty?
        validation_error(result, "evidence_file.records[#{index}].role_execution_context.#{field}", "implementation evidence role_execution_context.#{field} is required.")
      end
    end

    if ctx["task_sha256"].is_a?(String) && task["__orbit_path"] && !task_revision_frozen?(task)
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.task_sha256", "implementation evidence task_sha256 does not match current task.") if expected_task_sha && ctx["task_sha256"] != expected_task_sha
    end

    if ctx["owner_role"] != task_owner_role(task)
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.owner_role", "implementation evidence owner_role does not match task owner_role.")
    end

    if ctx["owner_instance"] != task_owner_instance(task)
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.owner_instance", "implementation evidence owner_instance does not match task owner_instance.")
    end

    contract = task_execution_contract(task)
    if ctx["operation_mode"] != contract["operation_mode"]
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.operation_mode", "implementation evidence operation_mode does not match task execution_contract.")
    end

    if ctx["execution_contract_source"] != contract["source"]
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.execution_contract_source", "implementation evidence execution_contract_source does not match task execution_contract.")
    end

    if ctx["implementation_authority"] != task_implementation_authority(task)
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.implementation_authority", "implementation evidence role does not match task implementation_authority.")
    end

    if ctx["resolved_role"] != task_implementation_authority(task)
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.resolved_role", "implementation evidence resolved_role does not match task implementation_authority.")
    end

    override = valid_implementation_override_for_identity(task, { "records" => records }, ctx["resolved_role"], ctx["resolved_instance"])
    if ctx["assigned_instance"] != task_assigned_instance(task)
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.assigned_instance", "implementation evidence assigned_instance does not match task assigned_instance.")
    elsif ctx["resolved_instance"] != task_assigned_instance(task) && !override
      validation_error(result, "evidence_file.records[#{index}].role_execution_context.resolved_instance", "implementation evidence instance does not match task assigned_instance and has no valid override.")
    end
  end
end

def implementation_override_record_valid_for_task?(record, task, now: Time.now.utc)
  return false unless record.is_a?(Hash) && record["kind"] == "implementation_instance_override"
  return false unless record["status"] == "pass"
  current_sha = sha256_file(task["__orbit_path"])
  task_matches = if task_revision_frozen?(task)
                   evidence_record_revision_eligible?(record, task, "implementation", current_sha)
                 else
                   record["task_sha256"] == current_sha
                 end
  return false unless task_matches
  return false unless record["from_role"] == task_implementation_authority(task)
  return false unless record["from_instance"] == task_assigned_instance(task)
  return false unless record["authorized_by_role"] == task_owner_role(task)
  return false unless record["authorized_by_instance"] == task_owner_instance(task)
  return false unless record["to_role"] == task_implementation_authority(task)
  return false unless implementation_override_to_instance_role(record) == task_implementation_authority(task)
  return true if record["no_expiry"] == true
  return false if record["expires_at"].to_s.empty?

  Time.iso8601(record["expires_at"]) > now
rescue ArgumentError
  false
end

def implementation_override_to_instance_role(record)
  config_dir = File.join(Dir.pwd, ".orbit")
  roles_config = load_yaml(File.join(config_dir, "roles.yaml"))
  instances_config = load_yaml(File.join(config_dir, "instances.yaml"))
  role_for_instance_config(instances_config["instances"], roles_config["roles"], record["to_instance"])
rescue RuntimeError
  nil
end

def valid_implementation_override_for_identity(task, evidence, resolved_role, resolved_instance)
  return nil unless task.is_a?(Hash) && evidence.is_a?(Hash)
  return nil unless resolved_role == task_implementation_authority(task)

  Array(evidence["records"]).find do |record|
    implementation_override_record_valid_for_task?(record, task) &&
      record["to_instance"] == resolved_instance &&
      record["to_role"] == resolved_role
  end
end

def validate_implementation_overrides_for_task(result, records, task)
  return unless task.is_a?(Hash)

  records.each_with_index do |record, index|
    next unless record.is_a?(Hash) && record["kind"] == "implementation_instance_override"

    if task_revision_frozen?(task)
      next unless evidence_record_revision_eligible?(record, task, "implementation", sha256_file(task["__orbit_path"]))
    end

    unless task_revision_frozen?(task) || record["task_sha256"] == sha256_file(task["__orbit_path"])
      validation_error(result, "evidence_file.records[#{index}].task_sha256", "implementation_instance_override task_sha256 does not match current task.")
    end
    unless record["from_instance"] == task_assigned_instance(task)
      validation_error(result, "evidence_file.records[#{index}].from_instance", "implementation_instance_override from_instance must match task assigned_instance.")
    end
    unless record["authorized_by_role"] == task_owner_role(task) && record["authorized_by_instance"] == task_owner_instance(task)
      validation_error(result, "evidence_file.records[#{index}].authorized_by_role", "implementation_instance_override must be authorized by task owner identity.")
    end
    unless implementation_override_to_instance_role(record) == task_implementation_authority(task)
      validation_error(result, "evidence_file.records[#{index}].to_instance", "implementation_instance_override to_instance must resolve to task implementation_authority.")
    end
    if record["no_expiry"] != true
      begin
        expires_at = Time.iso8601(record["expires_at"].to_s)
        validation_error(result, "evidence_file.records[#{index}].expires_at", "implementation_instance_override is expired.") unless expires_at > Time.now.utc
      rescue ArgumentError
        validation_error(result, "evidence_file.records[#{index}].expires_at", "implementation_instance_override expires_at must be ISO8601.")
      end
    end
  end
end

def validate_evidence(result, evidence_path, task = nil, task_sha256: nil, allow_missing_independent_gates: false)
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

  if ev_compat == :current && evidence["schema_semantics"].nil?
    validation_error(result, "evidence_file.schema_semantics",
      "Evidence manifest must include schema_semantics; recreate evidence with current Orbit.")
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
    validate_implementation_records_for_task(result, records, task) if task
    validate_implementation_overrides_for_task(result, records, task) if task
    validate_runtime_identity_policy_for_task(result, records, evidence, task, task_sha256) if task
    validate_current_artifact_provenance(result, records, task) if task
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
    if allow_missing_independent_gates
      gate_result = { "errors" => [], "warnings" => [] }
      validate_required_gate_evidence(gate_result, records, task, task_sha256)
      gate_result["errors"].each do |error|
        if error["message"].to_s.start_with?("Review/test task requires structured valid")
          validation_warning(
            result,
            error["source"],
            "Independent acceptance is still pending; this is allowed only for implemented_not_independently_accepted handoff."
          )
        else
          result["errors"] << error
        end
      end
      result["warnings"].concat(gate_result["warnings"])
    else
      validate_required_gate_evidence(result, records, task, task_sha256)
    end
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

def task_requires_herdr_verified_runtime_gate?(task)
  return false unless task.is_a?(Hash)

  policy = task["runtime_identity_policy"] || task["runtime_policy"]
  return false unless policy.is_a?(Hash)

  policy["require_herdr_verified_gate"] == true ||
    policy["gate"] == "herdr_verified" ||
    policy["mode"] == "herdr_verified"
end

def runtime_identity_record_gate_kind(record)
  kind = record["kind"].to_s
  return "implementation" if kind == "implementation"
  return "review" if kind == "review"
  return "test" if kind == "test"

  nil
end

RUNTIME_IDENTITY_WAIVER_SCHEMA = "orbit-runtime-identity-waiver-v1"

def runtime_identity_waiver_expiry_valid?(waiver)
  return true if waiver["no_expiry"] == true

  expires_at = waiver["expires_at"].to_s
  return false if expires_at.empty?

  Time.iso8601(expires_at) > Time.now.utc
rescue ArgumentError
  false
end

def runtime_identity_waiver_matches?(waiver, task_sha256, record, gate_kind)
  return false unless waiver.is_a?(Hash)
  return false unless waiver["schema_version"].to_s == RUNTIME_IDENTITY_WAIVER_SCHEMA
  return false if waiver["revoked_by_user_requirement"] == true

  scope = waiver["scope"].to_s
  return false unless ["runtime_identity", "runtime_identity:#{gate_kind}", "herdr_verified_runtime"].include?(scope)
  return false unless waiver["task_sha256"].to_s == task_sha256.to_s
  return false if waiver["owner_role"].to_s.empty? || waiver["owner_instance"].to_s.empty?
  return false unless waiver["accepted_by_role"].to_s == waiver["owner_role"].to_s
  return false unless waiver["accepted_by_instance"].to_s == waiver["owner_instance"].to_s
  return false if waiver["reason"].to_s.empty? || waiver["risk"].to_s.empty?

  replacement = waiver["replacement_evidence"].to_s
  record_sha = stable_record_sha256(record)
  return false unless waiver["evidence_record_sha256"].to_s == record_sha
  source_report = record["source_report"].to_s
  source_message = record["source_message_id"].to_s
  return false unless [record_sha, source_report, source_message].any? { |value| !value.empty? && replacement.include?(value) }

  runtime_identity_waiver_expiry_valid?(waiver)
end

def runtime_identity_has_explicit_waiver?(evidence, task_sha256, record, gate_kind)
  Array(evidence["waivers"]).any? { |waiver| runtime_identity_waiver_matches?(waiver, task_sha256, record, gate_kind) }
end

RUNTIME_GATE_ALLOWED_DEFAULT_VERIFICATIONS = %w[herdr_verified manual_runtime].freeze
RUNTIME_GATE_WAIVABLE_STRICT_VERIFICATIONS = %w[manual_runtime].freeze

def runtime_identity_herdr_verified_trusted?(runtime_identity)
  return false unless runtime_identity.is_a?(Hash)

  # Herdr currently exposes caller pane/session through process environment
  # only. A serialized evidence record can be hand-written, so the string
  # "herdr_verified" is not itself a proof. Keep this fail-closed until a
  # non-spoofable caller-pane proof provider exists.
  false
end

def runtime_identity_verification(record)
  return [nil, "missing"] unless record.is_a?(Hash) && record.key?("runtime_identity")

  runtime_identity = record["runtime_identity"]
  return [nil, "malformed"] unless runtime_identity.is_a?(Hash)

  [runtime_identity["verification"].to_s, nil]
end

def runtime_identity_gate_blocking_reason(record, evidence = nil, task = nil, task_sha256 = nil, gate_kind = nil)
  return nil unless record.is_a?(Hash)
  return nil unless record["status"] == "pass"

  kind = gate_kind || runtime_identity_record_gate_kind(record)
  return nil unless kind

  verification, shape_error = runtime_identity_verification(record)
  return "runtime_identity_malformed" if shape_error == "malformed"
  return "runtime_identity_missing" if shape_error == "missing" || verification.to_s.empty?
  return "runtime_identity_#{verification}" unless RUNTIME_GATE_ALLOWED_DEFAULT_VERIFICATIONS.include?(verification)
  if verification == "herdr_verified" && !runtime_identity_herdr_verified_trusted?(record["runtime_identity"])
    return "runtime_identity_herdr_verified_untrusted"
  end

  strict_runtime = task_requires_herdr_verified_runtime_gate?(task)
  return nil unless strict_runtime
  return nil if verification == "herdr_verified"
  if RUNTIME_GATE_WAIVABLE_STRICT_VERIFICATIONS.include?(verification) &&
      runtime_identity_has_explicit_waiver?(evidence || {}, task_sha256, record, kind)
    return nil
  end

  "runtime_identity_#{verification}"
end

def validate_runtime_identity_policy_for_task(result, records, evidence, task, task_sha256 = nil)
  strict_runtime = task_requires_herdr_verified_runtime_gate?(task)

  records.each_with_index do |record, index|
    next unless record.is_a?(Hash) && record["status"] == "pass"

    gate_kind = runtime_identity_record_gate_kind(record)
    next unless gate_kind

    verification, shape_error = runtime_identity_verification(record)
    if shape_error == "malformed"
      validation_error(result, "evidence_file.records[#{index}].runtime_identity",
        "runtime_identity must be a mapping when present.")
      next
    end
    if shape_error == "missing" || verification.to_s.empty?
      validation_error(result, "evidence_file.records[#{index}].runtime_identity",
        "#{gate_kind} pass record cannot close a gate without runtime_identity; only herdr_verified or manual_runtime under default policy is allowed.")
      next
    end
    unless RUNTIME_GATE_ALLOWED_DEFAULT_VERIFICATIONS.include?(verification)
      validation_error(result, "evidence_file.records[#{index}].runtime_identity",
        "#{gate_kind} pass record cannot close a gate with unsupported runtime_identity #{verification.inspect}; only herdr_verified or manual_runtime are allowed.")
      next
    end
    if verification == "herdr_verified" && !runtime_identity_herdr_verified_trusted?(record["runtime_identity"])
      validation_error(result, "evidence_file.records[#{index}].runtime_identity",
        "#{gate_kind} pass record cannot close a gate with herdr_verified runtime_identity because trusted caller-pane proof is unavailable.")
      next
    end
    next unless strict_runtime

    next if verification == "herdr_verified"
    if RUNTIME_GATE_WAIVABLE_STRICT_VERIFICATIONS.include?(verification) &&
        runtime_identity_has_explicit_waiver?(evidence, task_sha256, record, gate_kind)
      next
    end

    validation_error(result, "evidence_file.records[#{index}].runtime_identity",
      "Task requires Herdr-verified runtime gate evidence; #{gate_kind} pass record has runtime_identity #{verification.empty? ? "missing" : verification.inspect} without explicit runtime waiver.")
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

# Reads resolved_role from role_execution_context. Flat identity is not a gate authority.
def record_resolved_role(record)
  ctx = record["role_execution_context"]
  return (ctx["resolved_role"].is_a?(String) && !ctx["resolved_role"].empty? ? ctx["resolved_role"] : nil) if ctx.is_a?(Hash)
  nil
end

# Reads task_sha256 from role_execution_context. Flat identity is not a gate authority.
def record_task_sha256_from(record)
  ctx = record["role_execution_context"]
  return (ctx["task_sha256"].is_a?(String) && !ctx["task_sha256"].empty? ? ctx["task_sha256"] : nil) if ctx.is_a?(Hash)
  nil
end

# Reads rules_context_sha256 from role_execution_context. Flat identity is not a gate authority.
def record_rules_context_sha256_from(record)
  ctx = record["role_execution_context"]
  if ctx.is_a?(Hash)
    return ctx["rules_context_sha256"] if !ctx["rules_context_sha256"].to_s.empty?
    return ctx["rules_resolution_sha256"] if !ctx["rules_resolution_sha256"].to_s.empty?
    return nil
  end
  nil
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

def gate_passed?(records, kind, task_sha256: nil, task: nil, evidence: nil)
  result = { "errors" => [], "warnings" => [] }
  latest = latest_valid_gate_record(result, records, kind, task_sha256, task: task)
  latest&.fetch("status", nil) == "pass" && runtime_identity_gate_blocking_reason(latest, evidence, task, task_sha256, kind).nil?
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

def gate_status(records, kind, task = nil, task_sha256: nil, evidence: nil)
  evidence_record_kind = GATE_KIND_EVIDENCE_RECORD_KIND[kind] || kind
  # Slice 9: arbitration is authoritative for which record can pass the gate.
  # When a current task_sha256 is supplied, stale verdicts and records missing task_sha256
  # cannot close the gate. raw_latest is kept for flag reporting even when no record is accepted.
  arbitration = verdict_arbitration_for_gate(records, kind, task_sha256, task: task)
  raw_latest = latest_record_for_kind(records, evidence_record_kind, structured_gate_only: true, gate_identity_required: false)
  stale_verdict_only = task_sha256 && arbitration["accepted_record"].nil? && arbitration["has_stale"]
  latest = stale_verdict_only ? nil : (arbitration["accepted_record"] || raw_latest)
  expected_role = expected_gate_role(kind)
  malformed_rec_ctx = latest.is_a?(Hash) && latest.key?("role_execution_context") && !latest["role_execution_context"].is_a?(Hash)
  identity_role = latest && !malformed_rec_ctx ? record_resolved_role(latest) : nil
  identity_valid = latest && !malformed_rec_ctx ? gate_record_identity_valid?(latest, kind) : false
  status = latest ? latest["status"] : "missing"
  latest_gate_time = latest.is_a?(Hash) ? (Time.iso8601(latest["created_at"].to_s) rescue nil) : nil
  latest_gate_index = latest.is_a?(Hash) ? record_index_for_object(records, latest) : nil
  latest_gate_position = latest_gate_time && latest_gate_index ? [latest_gate_time, latest_gate_index] : nil
  latest_impl_position = latest_implementation_position({ "errors" => [] }, records)
  stale_after_implementation = !!(status == "pass" && latest_gate_position && latest_impl_position && evidence_position_not_newer?(latest_gate_position, latest_impl_position))
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
  revision_eligible = latest.is_a?(Hash) && task_revision_frozen?(task) && evidence_record_revision_eligible?(latest, task, kind, task_sha256)
  missing_task_sha256 = latest.is_a?(Hash) && latest["structured_submit"] == true && expected_gate_role(kind) != nil && stored_task_sha256.nil? && !revision_eligible
  task_sha256_blocked = missing_task_sha256
  stale_task_sha256 = !!(task_sha256 && stored_task_sha256 && stored_task_sha256 != task_sha256 && !revision_eligible)
  stale_blocked = stale_task_sha256 && write_policy_enforcement == "strict"
  missing_rules_context_sha256 = latest.is_a?(Hash) && latest["structured_submit"] == true && expected_gate_role(kind) != nil && stored_rules_context_sha256.nil?
  rules_context_blocked = missing_rules_context_sha256 && write_policy_enforcement == "strict"
  runtime_identity_blocking_reason = latest.is_a?(Hash) ? runtime_identity_gate_blocking_reason(latest, evidence || {}, task, task_sha256, kind) : nil
  journey_assessment = if evidence_record_kind == "test" && latest.is_a?(Hash)
                         user_journey_evidence_assessment(task, latest)
                       else
                         { "required" => false, "valid" => true }
                       end
  journey_evidence_ok = journey_assessment["valid"] == true
  artifact_assessment = latest.is_a?(Hash) ? artifact_provenance_assessment(task || {}, latest, manifest: evidence) : { "required" => false, "valid" => true }
  artifact_evidence_ok = artifact_assessment["valid"] == true
  blocking_reason = if latest.nil? && stale_verdict_only
                      "stale_verdict"
                    elsif latest.nil?
                      "missing"
                    elsif stale_after_implementation
                      "stale_after_implementation"
                    elsif malformed_rec_ctx
                      "malformed_role_execution_context"
                    elsif !identity_valid
                      "identity_mismatch"
                    elsif runtime_identity_blocking_reason
                      runtime_identity_blocking_reason
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
                    elsif !journey_evidence_ok
                      journey_assessment["blocking_reason"] || "missing_user_journey_evidence"
                    elsif !artifact_evidence_ok
                      artifact_assessment["blocking_reason"] || "invalid_artifact_provenance"
                    elsif display_status != "pass"
                      display_status
                    end
  {
    "kind" => kind,
    "required" => true,
    "status" => display_status,
    "record_status" => status,
    "passed" => !stale_verdict_only && status == "pass" && !stale_after_implementation && !malformed_rec_ctx && identity_valid && runtime_identity_blocking_reason.nil? && quality_evidence_fields_ok && !wrong_gate_kind_level && evidence_level_ok && quality_outcome_ok && required_questions_ok && !write_policy_blocked && !task_sha256_blocked && !stale_blocked && !rules_context_blocked && journey_evidence_ok && artifact_evidence_ok,
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
    "runtime_identity_verification" => latest.is_a?(Hash) ? runtime_identity_verification(latest).first : nil,
    "runtime_identity_blocking_reason" => runtime_identity_blocking_reason,
    "malformed_role_execution_context" => malformed_rec_ctx ? true : nil,
    "missing_task_sha256" => missing_task_sha256 ? true : nil,
    "stale_task_sha256" => stale_task_sha256 ? true : nil,
    "stale_after_implementation" => stale_after_implementation ? true : nil,
    "missing_rules_context_sha256" => missing_rules_context_sha256 ? true : nil,
    "write_policy_violations_count" => write_violations.empty? ? nil : write_violations.length,
    "user_journey_evidence" => journey_assessment["required"] ? journey_assessment : nil,
    "artifact_provenance" => artifact_assessment["required"] || !artifact_assessment["artifact_ids"].to_a.empty? ? artifact_assessment : nil,
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
  gates = required_evidence_kinds(task).map { |kind| gate_status(records, kind, task, task_sha256: task_sha256, evidence: evidence) }
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
  task["__orbit_path"] = task_path
  current_task_sha256 = sha256_file(File.expand_path(options["task"]))
  evidence_path = File.expand_path(options["evidence"])
  evidence = load_evidence_manifest(evidence_path)
  records = evidence["records"].is_a?(Array) ? evidence["records"] : []
  implementation_result = { "errors" => [] }
  validate_implementation_records_for_task(implementation_result, records, task)
  validate_current_artifact_provenance(implementation_result, records, task)
  kinds = required_evidence_kinds(task)
  gates = kinds.map { |kind| gate_status(records, kind, task, task_sha256: current_task_sha256, evidence: evidence) }
  implementation_errors = implementation_result["errors"]
  ready = gates.all? { |gate| gate["passed"] } && implementation_errors.empty?
  arbitration_summary = verdict_arbitration_summary(task, evidence, current_task_sha256)
  lease_summary = gate_lease_summary(evidence)
  gate_summary = required_gate_summary(task, evidence, task_sha256: current_task_sha256)
  unless implementation_errors.empty?
    gate_summary["ready"] = false
    gate_summary["not_ready"] << {
      "kind" => "implementation",
      "status" => "invalid",
      "blocking_reason" => "implementation_context_invalid",
      "error_count" => implementation_errors.length
    }
  end
  packet = {
    "schema_version" => "orbit-gate-status-v1",
    "project" => task["project"] || File.basename(Dir.pwd),
    "task" => task_path,
    "evidence" => evidence_path,
    "ready" => ready,
    "aggregate_verdict" => evidence["verdict"],
    "gate_summary" => gate_summary,
    "gates" => gates,
    "implementation_context_errors" => implementation_errors,
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
    "stage" => options["stage"],
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
    validate_task_execution_readiness(result, task) if task && options["stage"] == "execution-ready"
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

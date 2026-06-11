# frozen_string_literal: true

def parse_validate_args(args)
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
    when "--state"
      options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/
      options["state"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown validate option: #{arg}")
    end
  end

  options
end

def validation_error(result, source, message)
  result["errors"] << {
    "source" => source,
    "message" => message
  }
end

def validation_warning(result, source, message)
  result["warnings"] << {
    "source" => source,
    "message" => message
  }
end

def load_validation_file(result, source, path)
  data = load_yaml(path)
  unless data.is_a?(Hash)
    validation_error(result, source, "#{path} must contain a mapping.")
    return nil
  end

  data
rescue RuntimeError => e
  validation_error(result, source, e.message)
  nil
end

ALLOWED_LOOP_PHASES = %w[idle working in_review in_test blocked done].freeze
ALLOWED_GATE_KINDS = %w[review test].freeze

def default_state_path
  File.join(Dir.pwd, ".orbit", "loop-state.yaml")
end

def parse_state_args(args)
  subcommand = args.shift
  usage_error("Missing state subcommand.") unless subcommand

  options = {
    "subcommand" => subcommand,
    "json" => false,
    "state" => default_state_path
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--json"
      options["json"] = true
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--owner-role"
      options["owner_role"] = option_value(args, "--owner-role")
    when /\A--owner-role=(.+)\z/
      options["owner_role"] = Regexp.last_match(1)
    when "--to"
      options["to"] = option_value(args, "--to")
    when /\A--to=(.+)\z/
      options["to"] = Regexp.last_match(1)
    when "--evidence"
      options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      options["evidence"] = Regexp.last_match(1)
    when "--reason"
      options["reason"] = option_value(args, "--reason")
    when /\A--reason=(.+)\z/
      options["reason"] = Regexp.last_match(1)
    when "--message"
      options["message"] = option_value(args, "--message")
    when /\A--message=(.+)\z/
      options["message"] = Regexp.last_match(1)
    when "--state"
      options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/
      options["state"] = Regexp.last_match(1)
    else
      usage_error("Unknown state #{subcommand} option: #{arg}")
    end
  end

  case subcommand
  when "show"
    usage_error("state show currently requires --json") unless options["json"]
  when "progress"
    usage_error("Missing required option: --message") if options["message"].nil? || options["message"].strip.empty?
  when "start"
    usage_error("Missing required option: --task") if options["task"].nil? || options["task"].empty?
  when "transition"
    usage_error("Missing required option: --to") if options["to"].nil? || options["to"].empty?
  else
    usage_error("Unknown state subcommand: #{subcommand}")
  end

  options
end

def state_error(message)
  warn message
  exit 1
end

def validate_loop_state!(state, path)
  state_error("#{path} must contain a mapping.") unless state.is_a?(Hash)

  unless state["schema_version"] == "orbit-loop-state-v1"
    state_error("Loop state schema_version must be orbit-loop-state-v1.")
  end

  {
    "project" => String,
    "phase" => String,
    "status" => String,
    "updated_at" => String
  }.each do |field, klass|
    state_error("Loop state #{field} must be a #{klass}.") unless state[field].is_a?(klass) && !state[field].empty?
  end

  unless ALLOWED_LOOP_PHASES.include?(state["phase"])
    state_error("Loop state phase must be one of #{ALLOWED_LOOP_PHASES.join("|")}.")
  end

  state_error("Loop state history must be a list.") unless state["history"].is_a?(Array)

  if state.key?("budget") && !state["budget"].nil? && !state["budget"].is_a?(Hash)
    state_error("Loop state budget must be a mapping when present.")
  end

  if state.key?("artifacts") && !state["artifacts"].nil? && !state["artifacts"].is_a?(Hash)
    state_error("Loop state artifacts must be a mapping when present.")
  end

  if state.key?("quality_outcome_ref") && !state["quality_outcome_ref"].nil? && !state["quality_outcome_ref"].is_a?(String)
    state_error("Loop state quality_outcome_ref must be a string when present.")
  end

  if state.key?("current_task") && !state["current_task"].nil? && !state["current_task"].is_a?(String)
    state_error("Loop state current_task must be a string when present.")
  end

  if state.key?("owner_role") && !state["owner_role"].nil? && !state["owner_role"].is_a?(String)
    state_error("Loop state owner_role must be a string when present.")
  end
end

def write_loop_state(path, state)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, YAML.dump(state))
end

def load_loop_state(path)
  state = load_yaml(path)
  validate_loop_state!(state, path)
  state
rescue RuntimeError => e
  state_error(e.message)
end

def load_state_task(path)
  task = load_yaml(path)
  state_error("Task file must contain a mapping.") unless task.is_a?(Hash)
  unless task["schema_version"] == "orbit-task-v1"
    state_error("Task schema_version must be orbit-task-v1.")
  end
  task
rescue RuntimeError => e
  state_error(e.message)
end

def runtime_role_present?
  env_instance = ENV["ORBIT_INSTANCE"]
  env_role = ENV["ORBIT_ROLE"]
  (env_instance && !env_instance.empty?) || (env_role && !env_role.empty?)
end

def resolved_runtime_role
  result = {
    "project" => File.basename(Dir.pwd),
    "instance" => nil,
    "resolved_role" => nil,
    "role_sources" => {},
    "conflicts" => []
  }
  roles, instances = load_project_config(result)
  resolve_identity(result, roles, instances)

  unless result["conflicts"].empty?
    messages = result["conflicts"].map { |conflict| "#{conflict["source"]}: #{conflict["message"]}" }
    state_error("Runtime identity conflict: #{messages.join("; ")}")
  end

  result["resolved_role"]
end

def resolve_owner_role(explicit_owner_role)
  runtime_role = runtime_role_present? ? resolved_runtime_role : nil

  if explicit_owner_role && !explicit_owner_role.empty?
    if runtime_role && explicit_owner_role != runtime_role
      state_error("Owner role #{explicit_owner_role.inspect} conflicts with runtime role #{runtime_role.inspect}.")
    end
    return explicit_owner_role
  end

  state_error("Missing owner role; set ORBIT_INSTANCE/ORBIT_ROLE or pass --owner-role.") unless runtime_role
  runtime_role
end

def append_state_history(state, entry)
  state["history"] ||= []
  state_error("Loop state history must be a list.") unless state["history"].is_a?(Array)
  state["history"] << entry
end

def state_show(options)
  path = File.expand_path(options["state"])
  puts JSON.pretty_generate(load_loop_state(path))
end

def state_start(options)
  state_path = File.expand_path(options["state"])
  task_path = File.expand_path(options["task"])
  task = load_state_task(task_path)
  owner_role = resolve_owner_role(options["owner_role"])
  state = load_loop_state(state_path)
  now = Time.now.utc.iso8601
  previous_phase = state["phase"]

  state["project"] = task["project"] || File.basename(Dir.pwd)
  state["current_task"] = task_path
  state["phase"] = "working"
  state["owner_role"] = owner_role
  state["status"] = "working"
  state["updated_at"] = now
  state["artifacts"] ||= {}
  state_error("Loop state artifacts must be a mapping when present.") unless state["artifacts"].is_a?(Hash)
  state["artifacts"]["task_file"] = task_path
  append_state_history(state, {
    "event" => "start",
    "from" => previous_phase,
    "to" => "working",
    "task" => task_path,
    "owner_role" => owner_role,
    "created_at" => now
  })

  write_loop_state(state_path, state)
  puts "Started Orbit task:"
  puts "- #{task_path}"
end

def state_transition(options)
  state_path = File.expand_path(options["state"])
  target_phase = options["to"]
  unless ALLOWED_LOOP_PHASES.include?(target_phase)
    state_error("Target phase must be one of #{ALLOWED_LOOP_PHASES.join("|")}.")
  end

  reason = options["reason"].to_s.strip
  state_error("Transition to blocked requires --reason.") if target_phase == "blocked" && reason.empty?

  state = load_loop_state(state_path)
  previous_phase = state["phase"]
  task_path = state["current_task"]
  task = task_path ? load_state_task(task_path) : nil

  if target_phase == "done"
    validate_done_transition!(state_path, task_path, options["evidence"])
  end

  if previous_phase == "working" && target_phase == "done" && task && review_or_test_gate?(task)
    state_error("Cannot transition directly from working to done for review/test task.")
  end

  now = Time.now.utc.iso8601
  state["phase"] = target_phase
  state["status"] = target_phase == "blocked" ? "blocked: #{reason}" : target_phase
  state["updated_at"] = now
  state["artifacts"] ||= {}
  state_error("Loop state artifacts must be a mapping when present.") unless state["artifacts"].is_a?(Hash)
  state["artifacts"]["evidence_file"] = File.expand_path(options["evidence"]) if options["evidence"]

  history_entry = {
    "event" => "transition",
    "from" => previous_phase,
    "to" => target_phase,
    "created_at" => now
  }
  history_entry["evidence"] = File.expand_path(options["evidence"]) if options["evidence"]
  history_entry["reason"] = reason if target_phase == "blocked"
  append_state_history(state, history_entry)

  write_loop_state(state_path, state)
  puts "Transitioned Orbit state:"
  puts "- #{previous_phase} -> #{target_phase}"
end

def state_progress(options)
  state_path = File.expand_path(options["state"])
  message = options["message"].to_s.strip
  state_error("Progress message must be non-empty.") if message.empty?

  state = load_loop_state(state_path)
  now = Time.now.utc.iso8601
  state["status"] = "progress: #{message}"
  state["updated_at"] = now

  history_entry = {
    "event" => "progress",
    "phase" => state["phase"],
    "message" => message,
    "created_at" => now
  }
  history_entry["evidence"] = File.expand_path(options["evidence"]) if options["evidence"]
  append_state_history(state, history_entry)

  write_loop_state(state_path, state)
  puts "Recorded Orbit progress:"
  puts "- #{message}"
end

def state(args)
  options = parse_state_args(args)

  case options["subcommand"]
  when "show"
    state_show(options)
  when "progress"
    state_progress(options)
  when "start"
    state_start(options)
  when "transition"
    state_transition(options)
  else
    usage_error("Unknown state subcommand: #{options["subcommand"]}")
  end
end

def validate_project_rule_files(result, roles)
  roles.each do |role_name, role_def|
    unless role_def.is_a?(Hash)
      validation_error(result, "project_config.roles.#{role_name}", "Role #{role_name.inspect} must be a mapping.")
      next
    end

    rules = role_def["rules"]
    next if rules.nil?

    unless rules.is_a?(Array)
      validation_error(result, "project_config.roles.#{role_name}.rules", "Role rules must be a list of project rule paths.")
      next
    end

    rules.each_with_index do |entry, index|
      rule_entry = normalize_project_rule_entry(entry, index)
      source = "project_config.roles.#{role_name}.rules[#{index}]"

      if rule_entry["invalid"] || rule_entry["path"].to_s.empty?
        validation_error(result, source, "Project rule entry must be a path string or mapping with path/file.")
      elsif !rule_entry["exists"]
        validation_error(result, source, "Project rule file is missing: #{rule_entry["path"].inspect}.")
      end
    end
  end
end

def validate_instance_command(result, source, command)
  error = command_config_error(command, "Instance #{source.inspect}")
  validation_error(result, "project_config.instances.#{source}.command", error) if error
end

def validate_instance_env(result, source, instance_name, env, resolved_role)
  if env.nil?
    validation_warning(result, "project_config.instances.#{source}.env", "Instance #{instance_name.inspect} should define env mapping with ORBIT_INSTANCE and ORBIT_ROLE.")
    return
  end

  unless env.is_a?(Hash)
    validation_error(result, "project_config.instances.#{source}.env", "Instance #{instance_name.inspect} env must be a mapping.")
    return
  end

  env.each do |key, value|
    unless key.is_a?(String) && !key.strip.empty?
      validation_error(result, "project_config.instances.#{source}.env", "Instance #{instance_name.inspect} env keys must be non-empty strings.")
    end

    unless value.is_a?(String)
      validation_error(result, "project_config.instances.#{source}.env.#{key}", "Instance #{instance_name.inspect} env values must be strings.")
    end
  end

  if env.key?("ORBIT_INSTANCE") && env["ORBIT_INSTANCE"] != instance_name
    validation_warning(result, "project_config.instances.#{source}.env.ORBIT_INSTANCE", "ORBIT_INSTANCE #{env["ORBIT_INSTANCE"].inspect} does not match instance #{instance_name.inspect}; launcher will set #{instance_name.inspect} first, then merge configured env.")
  end

  if resolved_role && env.key?("ORBIT_ROLE") && env["ORBIT_ROLE"] != resolved_role
    validation_warning(result, "project_config.instances.#{source}.env.ORBIT_ROLE", "ORBIT_ROLE #{env["ORBIT_ROLE"].inspect} does not match resolved role #{resolved_role.inspect}; launcher will set #{resolved_role.inspect} first, then merge configured env.")
  end
end

def validate_project_config(result)
  config_dir = File.join(Dir.pwd, ".orbit")
  roles_path = File.join(config_dir, "roles.yaml")
  instances_path = File.join(config_dir, "instances.yaml")

  roles_config = load_validation_file(result, "project_config.roles", roles_path)
  instances_config = load_validation_file(result, "project_config.instances", instances_path)
  return [nil, nil] unless roles_config && instances_config

  capability_registry = roles_config["capability_registry"]
  unless capability_registry.is_a?(Hash) && !capability_registry.empty?
    validation_error(result, "project_config.roles.capability_registry", ".orbit/roles.yaml must contain a non-empty capability_registry mapping.")
  end

  roles = roles_config["roles"]
  unless roles.is_a?(Hash) && !roles.empty?
    validation_error(result, "project_config.roles", ".orbit/roles.yaml must contain a non-empty roles mapping.")
    roles = {}
  end

  validate_project_rule_files(result, roles)

  instances = instances_config["instances"]
  unless instances.is_a?(Hash) && !instances.empty?
    validation_error(result, "project_config.instances", ".orbit/instances.yaml must contain a non-empty instances mapping.")
    instances = {}
  end

  instances.each do |name, instance|
    unless instance.is_a?(Hash)
      validation_error(result, "project_config.instances.#{name}", "Instance #{name.inspect} must be a mapping.")
      next
    end

    role_ref = instance["role_ref"]
    if role_ref.nil? || role_ref.empty?
      validation_error(result, "project_config.instances.#{name}.role_ref", "Instance #{name.inspect} must define role_ref.")
    elsif !roles.key?(role_ref)
      validation_error(result, "project_config.instances.#{name}.role_ref", "Instance #{name.inspect} references missing role #{role_ref.inspect}.")
    end

    validate_instance_command(result, name, instance["command"])

    role_def = role_ref && roles[role_ref]
    resolved_role = role_def.is_a?(Hash) ? (role_def["role"] || role_ref) : nil
    validate_instance_env(result, name, name, instance["env"], resolved_role)
  end

  [roles, instances]
end

def improvement_task?(task)
  task_type = task["task_type"].to_s
  task_type.include?("improvement")
end

def review_or_test_gate?(task)
  task_type = task["task_type"].to_s
  target_role = task["target_role"].to_s

  task_type.include?("review") ||
    task_type.include?("test") ||
    %w[reviewer tester].include?(target_role)
end

def normalize_task_gates(task)
  gates = task.is_a?(Hash) ? task["gates"] : nil
  return [] unless gates.is_a?(Array)

  gates.select { |gate| gate.is_a?(Hash) }
end

def task_gate_role?(task, role)
  normalize_task_gates(task).any? do |gate|
    next false unless ALLOWED_GATE_KINDS.include?(gate["kind"])

    roles = gate["roles"]
    role_list = if roles.is_a?(Array)
                  roles
                elsif gate["role"].is_a?(String)
                  [gate["role"]]
                else
                  []
                end
    role_list.include?(role)
  end
end

def task_gate_kinds(task, required_only: false)
  gates = normalize_task_gates(task)
  gates = gates.reject { |gate| gate["required"] == false } if required_only
  gates.map { |gate| gate["kind"] }.select { |kind| ALLOWED_GATE_KINDS.include?(kind) }.uniq
end

def expected_evidence_kind(task)
  task_type = task["task_type"].to_s
  target_role = task["target_role"].to_s

  return "test" if task_type.include?("test") || target_role == "tester"
  return "review" if task_type.include?("review") || target_role == "reviewer"

  nil
end

def required_evidence_kinds(task)
  kinds = []
  direct_kind = expected_evidence_kind(task)
  kinds << direct_kind if direct_kind
  kinds.concat(task_gate_kinds(task, required_only: true))
  kinds.uniq
end

def validate_task(result, task_path)
  task = load_validation_file(result, "task_file", task_path)
  return nil unless task

  task["__orbit_path"] = File.expand_path(task_path)

  unless task["schema_version"] == "orbit-task-v1"
    validation_error(result, "task_file.schema_version", "Task schema_version must be orbit-task-v1.")
  end

  if task["target_role"].nil? || task["target_role"].to_s.empty?
    validation_error(result, "task_file.target_role", "Task must define target_role.")
  end

  unless task.key?("evidence_requirements")
    validation_error(result, "task_file.evidence_requirements", "Task must define evidence_requirements.")
  end

  if improvement_task?(task) && !task.key?("quality_outcome")
    validation_error(result, "task_file.quality_outcome", "Improvement task must define quality_outcome.")
  end

  validate_task_runtime_fields(result, task)

  task
end

def validate_string_list(result, source, value, label)
  unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
    validation_error(result, source, "#{label} must be a list of strings.")
  end
end

def validate_optional_string_list(result, source, value, label)
  validate_string_list(result, source, value, label) unless value.nil?
end

def warn_missing_task_field(result, field)
  validation_warning(result, "task_file.#{field}", "Task should define #{field} so Orbit can audit runtime guardrail evidence.")
end

def validate_task_runtime_fields(result, task)
  if task.key?("source_documents")
    validate_string_list(result, "task_file.source_documents", task["source_documents"], "Task source_documents")
  else
    warn_missing_task_field(result, "source_documents")
  end

  source_contract = task["source_contract"]
  if source_contract.nil?
    warn_missing_task_field(result, "source_contract")
  elsif !source_contract.is_a?(Hash)
    validation_error(result, "task_file.source_contract", "Task source_contract must be a mapping.")
  else
    validate_optional_string_list(result, "task_file.source_contract.required_outcomes", source_contract["required_outcomes"], "Source contract required_outcomes")
    validate_optional_string_list(result, "task_file.source_contract.out_of_scope", source_contract["out_of_scope"], "Source contract out_of_scope")
    validate_optional_string_list(result, "task_file.source_contract.cleanup_plan", source_contract["cleanup_plan"], "Source contract cleanup_plan")
  end

  traceability = task["traceability"]
  if traceability.nil?
    warn_missing_task_field(result, "traceability")
  elsif !traceability.is_a?(Array)
    validation_error(result, "task_file.traceability", "Task traceability must be a list.")
  elsif traceability.any? { |item| !item.is_a?(Hash) }
    validation_error(result, "task_file.traceability", "Task traceability entries must be mappings.")
  end

  worktree_safety = task["worktree_safety"]
  if worktree_safety.nil?
    warn_missing_task_field(result, "worktree_safety")
  elsif !worktree_safety.is_a?(Hash)
    validation_error(result, "task_file.worktree_safety", "Task worktree_safety must be a mapping.")
  else
    unless [true, false].include?(worktree_safety["require_status_check"])
      validation_error(result, "task_file.worktree_safety.require_status_check", "Task worktree_safety.require_status_check must be true or false.")
    end
    validate_optional_string_list(result, "task_file.worktree_safety.before_public_action", worktree_safety["before_public_action"], "Worktree before_public_action")
  end

  release_surface = task["release_surface"]
  if release_surface.nil?
    warn_missing_task_field(result, "release_surface")
  elsif !release_surface.is_a?(Hash)
    validation_error(result, "task_file.release_surface", "Task release_surface must be a mapping.")
  else
    validate_optional_string_list(result, "task_file.release_surface.required_when_applicable", release_surface["required_when_applicable"], "Release surface required_when_applicable")
  end

  supply_chain = task["supply_chain"]
  if supply_chain.nil?
    warn_missing_task_field(result, "supply_chain")
  elsif !supply_chain.is_a?(Hash)
    validation_error(result, "task_file.supply_chain", "Task supply_chain must be a mapping.")
  elsif supply_chain.key?("third_party_tools") && !supply_chain["third_party_tools"].is_a?(Array)
    validation_error(result, "task_file.supply_chain.third_party_tools", "Task supply_chain.third_party_tools must be a list.")
  end

  final_audit = task["final_audit"]
  if final_audit.nil?
    warn_missing_task_field(result, "final_audit")
  elsif !final_audit.is_a?(Hash)
    validation_error(result, "task_file.final_audit", "Task final_audit must be a mapping.")
  else
    unless [true, false].include?(final_audit["required"])
      validation_error(result, "task_file.final_audit.required", "Task final_audit.required must be true or false.")
    end
    validate_optional_string_list(result, "task_file.final_audit.checks", final_audit["checks"], "Final audit checks")
  end

  gates = task["gates"]
  return if gates.nil?

  unless gates.is_a?(Array)
    validation_error(result, "task_file.gates", "Task gates must be a list when present.")
    return
  end

  gates.each_with_index do |gate, index|
    source = "task_file.gates[#{index}]"
    unless gate.is_a?(Hash)
      validation_error(result, source, "Task gate must be a mapping.")
      next
    end

    kind = gate["kind"]
    unless ALLOWED_GATE_KINDS.include?(kind)
      validation_error(result, "#{source}.kind", "Task gate kind must be one of #{ALLOWED_GATE_KINDS.join("|")}.")
    end

    roles = gate["roles"]
    roles = [gate["role"]] if roles.nil? && gate["role"].is_a?(String)
    unless roles.is_a?(Array) && roles.all? { |role| role.is_a?(String) && !role.strip.empty? }
      validation_error(result, "#{source}.roles", "Task gate roles must be a list of role strings.")
    end

    required = gate["required"]
    unless required.nil? || [true, false].include?(required)
      validation_error(result, "#{source}.required", "Task gate required must be true or false when present.")
    end
  end
end

def validate_evidence_record(result, source, record)
  unless record.is_a?(Hash)
    validation_error(result, source, "Evidence record must be a mapping.")
    return
  end

  kind = record["kind"]
  status = record["status"]
  summary = record["summary"]
  created_at = record["created_at"]

  unless ALLOWED_EVIDENCE_KINDS.include?(kind)
    validation_error(result, "#{source}.kind", "Evidence record kind must be one of #{ALLOWED_EVIDENCE_KINDS.join("|")}.")
  end

  unless ALLOWED_EVIDENCE_STATUSES.include?(status)
    validation_error(result, "#{source}.status", "Evidence record status must be one of #{ALLOWED_EVIDENCE_STATUSES.join("|")}.")
  end

  unless summary.is_a?(String) && !summary.strip.empty?
    validation_error(result, "#{source}.summary", "Evidence record summary must be a non-empty string.")
  end

  unless created_at.is_a?(String) && !created_at.empty?
    validation_error(result, "#{source}.created_at", "Evidence record created_at must be a non-empty string.")
  end
end

def parse_evidence_created_at(result, source, value)
  unless value.is_a?(String) && !value.empty?
    validation_error(result, source, "Evidence record created_at must be a non-empty string.")
    return nil
  end

  Time.iso8601(value)
rescue ArgumentError
  validation_error(result, source, "Evidence record created_at must be ISO8601 sortable.")
  nil
end

def latest_valid_gate_record(result, records, expected_kind)
  candidates = []

  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)
    next unless record["kind"] == expected_kind
    next if record["status"] == "invalid"
    next unless ALLOWED_EVIDENCE_STATUSES.include?(record["status"])

    created_at = parse_evidence_created_at(result, "evidence_file.records[#{index}].created_at", record["created_at"])
    next unless created_at

    candidates << [created_at, index, record]
  end

  candidates.max_by { |created_at, index, _record| [created_at, index] }&.last
end

def validate_gate_verdict(result, records, expected_kind)
  latest = latest_valid_gate_record(result, records, expected_kind)
  unless latest
    validation_error(result, "evidence_file.records", "Review/test task requires valid #{expected_kind.inspect} evidence with status pass.")
    return
  end

  case latest["status"]
  when "pass"
    nil
  when "fail"
    validation_error(result, "evidence_file.records", "Latest #{expected_kind} verdict is fail.")
  when "partial"
    validation_error(result, "evidence_file.records", "Latest #{expected_kind} verdict is partial; task remains blocked.")
  else
    validation_error(result, "evidence_file.records", "Latest #{expected_kind} verdict is not pass.")
  end
end

def validate_judgment_status(result, source, value)
  unless ALLOWED_EVIDENCE_STATUSES.include?(value)
    validation_error(result, source, "Judgment verdict must be one of #{ALLOWED_EVIDENCE_STATUSES.join("|")}.")
  end
end

def validate_severity(result, source, value)
  unless %w[high medium low].include?(value)
    validation_error(result, source, "Finding severity must be one of high|medium|low.")
  end
end

def validate_non_empty_string(result, source, value, label)
  unless value.is_a?(String) && !value.strip.empty?
    validation_error(result, source, "#{label} must be a non-empty string.")
  end
end

def validate_review_judgment(result, judgment)
  unless judgment.is_a?(Hash)
    validation_error(result, "evidence_file.review_judgment", "Review judgment must be a mapping.")
    return
  end

  validate_judgment_status(result, "evidence_file.review_judgment.verdict", judgment["verdict"])

  quality_outcome = judgment["quality_outcome"]
  unless quality_outcome.is_a?(Hash)
    validation_error(result, "evidence_file.review_judgment.quality_outcome", "Review judgment quality_outcome must be a mapping.")
  else
    unless %w[pass fail].include?(quality_outcome["verdict"])
      validation_error(result, "evidence_file.review_judgment.quality_outcome.verdict", "Quality outcome verdict must be pass or fail.")
    end
    validate_non_empty_string(result, "evidence_file.review_judgment.quality_outcome.reasoning", quality_outcome["reasoning"], "Quality outcome reasoning")
  end

  findings = judgment["findings"]
  unless findings.is_a?(Array)
    validation_error(result, "evidence_file.review_judgment.findings", "Review judgment findings must be a list.")
  else
    findings.each_with_index do |finding, index|
      source = "evidence_file.review_judgment.findings[#{index}]"
      unless finding.is_a?(Hash)
        validation_error(result, source, "Review finding must be a mapping.")
        next
      end

      validate_severity(result, "#{source}.severity", finding["severity"])
      validate_non_empty_string(result, "#{source}.summary", finding["summary"], "Review finding summary")
      validate_non_empty_string(result, "#{source}.evidence", finding["evidence"], "Review finding evidence")
      if %w[high medium].include?(finding["severity"])
        %w[symptom source consequence remedy trigger guard].each do |field|
          unless finding[field].is_a?(String) && !finding[field].strip.empty?
            validation_warning(result, "#{source}.#{field}", "High/medium review findings should include #{field} for the finding quality gate.")
          end
        end
      end
    end
  end

  residual_risk = judgment["residual_risk"]
  return if residual_risk.nil?

  unless residual_risk.is_a?(Hash)
    validation_error(result, "evidence_file.review_judgment.residual_risk", "Review judgment residual_risk must be a mapping when present.")
    return
  end

  unless [true, false].include?(residual_risk["accepted"])
    validation_error(result, "evidence_file.review_judgment.residual_risk.accepted", "Residual risk accepted must be true or false.")
  end
  validate_non_empty_string(result, "evidence_file.review_judgment.residual_risk.reason", residual_risk["reason"], "Residual risk reason")
end

def validate_test_judgment(result, judgment)
  unless judgment.is_a?(Hash)
    validation_error(result, "evidence_file.test_judgment", "Test judgment must be a mapping.")
    return
  end

  validate_judgment_status(result, "evidence_file.test_judgment.verdict", judgment["verdict"])
  validate_non_empty_string(result, "evidence_file.test_judgment.environment", judgment["environment"], "Test judgment environment")

  scenarios = judgment["scenarios"]
  unless scenarios.is_a?(Array)
    validation_error(result, "evidence_file.test_judgment.scenarios", "Test judgment scenarios must be a list.")
  else
    scenarios.each_with_index do |scenario, index|
      source = "evidence_file.test_judgment.scenarios[#{index}]"
      unless scenario.is_a?(Hash)
        validation_error(result, source, "Test scenario must be a mapping.")
        next
      end

      validate_non_empty_string(result, "#{source}.name", scenario["name"], "Test scenario name")
      unless %w[pass fail].include?(scenario["result"])
        validation_error(result, "#{source}.result", "Test scenario result must be pass or fail.")
      end
      validate_non_empty_string(result, "#{source}.evidence", scenario["evidence"], "Test scenario evidence")
    end
  end

  coverage_gap = judgment["coverage_gap"]
  return if coverage_gap.nil?

  unless coverage_gap.is_a?(Array) && coverage_gap.all? { |gap| gap.is_a?(String) && !gap.strip.empty? }
    validation_error(result, "evidence_file.test_judgment.coverage_gap", "Test judgment coverage_gap must be a list of non-empty strings when present.")
  end
end

ALLOWED_OPTIONAL_EVIDENCE_STATUSES = %w[not_applicable pass passed partial warning blocked failed missing available_not_invoked].freeze
ALLOWED_WORKTREE_SAFETY_STATUSES = (ALLOWED_OPTIONAL_EVIDENCE_STATUSES + %w[not_git]).freeze

def validate_optional_status(result, source, value, label, allowed_statuses = ALLOWED_OPTIONAL_EVIDENCE_STATUSES)
  unless allowed_statuses.include?(value)
    validation_error(result, source, "#{label} status must be one of #{allowed_statuses.join("|")}.")
  end
end

def validate_worktree_safety(result, value)
  if value.nil?
    validation_warning(result, "evidence_file.worktree_safety", "Evidence should include worktree_safety for git/worktree guardrails.")
    return
  end

  unless value.is_a?(Hash)
    validation_error(result, "evidence_file.worktree_safety", "Evidence worktree_safety must be a mapping.")
    return
  end

  status = value["status"] || "missing"
  validate_optional_status(result, "evidence_file.worktree_safety.status", status, "Worktree safety", ALLOWED_WORKTREE_SAFETY_STATUSES)
  if status == "not_git"
    validate_non_empty_string(result, "evidence_file.worktree_safety.reason", value["reason"], "Worktree safety non-git reason")
    return
  end
  return if status == "not_applicable"

  %w[status_before head_before status_after head_after].each do |field|
    unless value[field].is_a?(String) && !value[field].strip.empty?
      validation_warning(result, "evidence_file.worktree_safety.#{field}", "Worktree safety should record #{field}.")
    end
  end

  unless value["unexpected_changes"].is_a?(Array)
    validation_error(result, "evidence_file.worktree_safety.unexpected_changes", "Worktree safety unexpected_changes must be a list.")
  end
end

def validate_regression_guard(result, value)
  if value.nil?
    validation_warning(result, "evidence_file.regression_guard", "Evidence should include regression_guard for bugfix/high-risk change audit.")
    return
  end

  unless value.is_a?(Hash)
    validation_error(result, "evidence_file.regression_guard", "Evidence regression_guard must be a mapping.")
    return
  end

  status = value["status"]
  unless %w[present absent not_applicable].include?(status)
    validation_error(result, "evidence_file.regression_guard.status", "Regression guard status must be present|absent|not_applicable.")
    return
  end

  if status == "present"
    validate_non_empty_string(result, "evidence_file.regression_guard.evidence", value["evidence"], "Regression guard evidence")
  elsif status == "absent"
    validation_warning(result, "evidence_file.regression_guard", "Regression guard is absent; bugfix or high-risk changes should record a durable guard or residual risk.")
  end
end

def validate_release_surface(result, value)
  if value.nil?
    validation_warning(result, "evidence_file.release_surface", "Evidence should include release_surface for package/release artifact audit.")
    return
  end

  unless value.is_a?(Hash)
    validation_error(result, "evidence_file.release_surface", "Evidence release_surface must be a mapping.")
    return
  end

  status = value["status"] || "missing"
  validate_optional_status(result, "evidence_file.release_surface.status", status, "Release surface")

  unless value["checked"].is_a?(Array)
    validation_error(result, "evidence_file.release_surface.checked", "Release surface checked must be a list.")
  end

  unless value["gaps"].is_a?(Array)
    validation_error(result, "evidence_file.release_surface.gaps", "Release surface gaps must be a list.")
  end

  if value["gaps"].is_a?(Array) && !value["gaps"].empty?
    validation_warning(result, "evidence_file.release_surface.gaps", "Release surface has recorded gaps; release trust remains incomplete.")
  end
end

def validate_tool_calls(result, value)
  if value.nil?
    validation_warning(result, "evidence_file.tool_calls", "Evidence should include tool_calls so critical tool use can be audited.")
    return
  end

  unless value.is_a?(Array)
    validation_error(result, "evidence_file.tool_calls", "Evidence tool_calls must be a list.")
    return
  end

  value.each_with_index do |tool_call, index|
    source = "evidence_file.tool_calls[#{index}]"
    unless tool_call.is_a?(Hash)
      validation_error(result, source, "Tool call must be a mapping.")
      next
    end

    name = tool_call["tool_name"] || tool_call["name"]
    validate_non_empty_string(result, "#{source}.tool_name", name, "Tool call tool_name")
    validate_optional_status(result, "#{source}.status", tool_call["status"], "Tool call")
    validate_non_empty_string(result, "#{source}.used_for", tool_call["used_for"], "Tool call used_for") if tool_call.key?("used_for")
  end
end

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

def validate_evidence(result, evidence_path, task = nil)
  evidence = load_validation_file(result, "evidence_file", evidence_path)
  return nil unless evidence

  unless evidence["schema_version"] == "orbit-evidence-v1"
    validation_error(result, "evidence_file.schema_version", "Evidence schema_version must be orbit-evidence-v1.")
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
    unless ALLOWED_EVIDENCE_STATUSES.include?(status)
      validation_error(result, "evidence_file.verdict.status", "Evidence verdict.status must be one of #{ALLOWED_EVIDENCE_STATUSES.join("|")}.")
    end
  elsif !records
    validation_error(result, "evidence_file.verdict", "Evidence must define verdict mapping or records list.")
  end

  validate_review_judgment(result, evidence["review_judgment"]) if evidence.key?("review_judgment")
  validate_test_judgment(result, evidence["test_judgment"]) if evidence.key?("test_judgment")
  validate_worktree_safety(result, evidence["worktree_safety"])
  validate_regression_guard(result, evidence["regression_guard"])
  validate_release_surface(result, evidence["release_surface"])
  validate_tool_calls(result, evidence["tool_calls"])
  validate_rule_resolution_reference(result, evidence_path, evidence, task)

  if task && review_or_test_gate?(task) && records.is_a?(Array) && !records.empty?
    expected_kind = expected_evidence_kind(task)
    validate_gate_verdict(result, records, expected_kind)
  end

  evidence
end

def validate_required_gate_evidence(result, records, task)
  return unless task.is_a?(Hash)

  required_evidence_kinds(task).each do |expected_kind|
    validate_gate_verdict(result, records.is_a?(Array) ? records : [], expected_kind)
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

def latest_record_for_kind(records, kind)
  return nil unless records.is_a?(Array)

  candidates = []
  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)
    next unless record["kind"] == kind
    next if record["status"] == "invalid"

    begin
      created_at = Time.iso8601(record["created_at"].to_s)
    rescue ArgumentError
      next
    end
    candidates << [created_at, index, record]
  end
  candidates.max_by { |created_at, index, _record| [created_at, index] }&.last
end

def gate_passed?(records, kind)
  latest_record_for_kind(records, kind)&.fetch("status", nil) == "pass"
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

def gate_status(records, kind)
  latest = latest_record_for_kind(records, kind)
  status = latest ? latest["status"] : "missing"
  {
    "kind" => kind,
    "required" => true,
    "status" => status,
    "passed" => status == "pass",
    "latest" => latest
  }.compact
end

def wait_gate(args)
  options = parse_wait_gate_args(args)
  task_path, task = load_dispatch_task(options["task"])
  evidence_path = File.expand_path(options["evidence"])
  evidence = load_evidence_manifest(evidence_path)
  records = evidence["records"].is_a?(Array) ? evidence["records"] : []
  kinds = required_evidence_kinds(task)
  gates = kinds.map { |kind| gate_status(records, kind) }
  ready = gates.all? { |gate| gate["passed"] }
  packet = {
    "schema_version" => "orbit-gate-status-v1",
    "project" => task["project"] || File.basename(Dir.pwd),
    "task" => task_path,
    "evidence" => evidence_path,
    "ready" => ready,
    "gates" => gates,
    "summary" => ready ? "all required gates pass" : "required gates are not ready"
  }

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
  evidence = validate_evidence(result, evidence_path, task)
  result["checked"] << "evidence"
  validate_state_file(result, state_path)
  result["checked"] << "state"

  unless evidence_has_done_signal?(evidence)
    validation_error(result, "evidence_file", "Transition to done requires at least one pass evidence signal.")
  end

  validate_required_gate_evidence(result, evidence.is_a?(Hash) ? evidence["records"] : [], task)

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
    validate_evidence(result, options["evidence"], task)
    result["checked"] << "evidence"
  elsif task && review_or_test_gate?(task)
    validation_error(result, "evidence_file", "Task review/test gates require --evidence manifest before passing.")
  end

  if options["state"]
    validate_state_file(result, options["state"])
    result["checked"] << "state"
  end

  validation_warning(result, "validate", "No task, evidence, or state file was provided; only project config was checked.") unless options["task"] || options["evidence"] || options["state"]

  print_validation_result(result, options["json"])
  exit(result["errors"].empty? ? 0 : 1)
end


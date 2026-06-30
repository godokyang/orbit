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
    when "--changed-files"
      value = option_value(args, "--changed-files")
      options["changed_files"] ||= []
      options["changed_files"].concat(value.split(",").map(&:strip).reject(&:empty?))
    when /\A--changed-files=(.+)\z/
      options["changed_files"] ||= []
      options["changed_files"].concat(Regexp.last_match(1).split(",").map(&:strip).reject(&:empty?))
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown validate option: #{arg}")
    end
  end

  options
end

def validate_scope_changed_files(result, task, changed_files)
  return unless changed_files.is_a?(Array) && !changed_files.empty?
  return unless task.is_a?(Hash)

  scope = task["scope"]
  return unless scope.is_a?(Hash)

  include_patterns = scope["include"].is_a?(Array) ? scope["include"].reject { |p| p.to_s.strip.empty? } : []
  exclude_patterns = scope["exclude"].is_a?(Array) ? scope["exclude"].reject { |p| p.to_s.strip.empty? } : []
  return if include_patterns.empty? && exclude_patterns.empty?

  changed_files.each do |file|
    if !include_patterns.empty?
      matched = include_patterns.any? { |pattern| File.fnmatch(pattern, file, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
      unless matched
        validation_error(
          result,
          "task_file.scope.include",
          "Changed file #{file.inspect} is outside task scope.include patterns. Add to scope.include or obtain a scope waiver."
        )
        next
      end
    end

    next if exclude_patterns.empty?

    excluded = exclude_patterns.any? { |pattern| File.fnmatch(pattern, file, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
    next unless excluded

    validation_error(
      result,
      "task_file.scope.exclude",
      "Changed file #{file.inspect} is excluded by task scope.exclude patterns."
    )
  end
end

def validate_artifact_policy_field(result, task)
  policy = task["artifact_policy"]
  return if policy.nil?

  unless policy.is_a?(Hash)
    validation_error(result, "task_file.artifact_policy", "Task artifact_policy must be a mapping when present.")
    return
  end

  %w[generated build_outputs orbit_runtime runtime_artifacts].each do |field|
    value = policy[field]
    next if value.nil?

    unless value.is_a?(String) && !value.strip.empty?
      validation_error(result, "task_file.artifact_policy.#{field}", "Task artifact_policy.#{field} must be a non-empty string when present.")
    end
  end
end

def validate_destructive_actions_field(result, task)
  da = task["destructive_actions"]
  return if da.nil?

  unless da.is_a?(Hash)
    validation_error(result, "task_file.destructive_actions", "Task destructive_actions must be a mapping when present.")
    return
  end

  %w[required_protocol require_user_confirmation].each do |field|
    value = da[field]
    next if value.nil?

    unless [true, false].include?(value)
      validation_error(result, "task_file.destructive_actions.#{field}", "Task destructive_actions.#{field} must be true or false when present.")
    end
  end
end

def validate_write_policy_enforcement_field(result, task)
  return unless task.is_a?(Hash) && task.key?("write_policy_enforcement")

  enforcement = task["write_policy_enforcement"]
  return if enforcement.nil?

  unless %w[standard strict].include?(enforcement.to_s)
    validation_error(result, "task_file.write_policy_enforcement",
      "Task write_policy_enforcement must be standard or strict when present, got #{enforcement.inspect}.")
  end
end

def validate_destructive_action_plan_record(result, source, plan)
  return unless plan.is_a?(Hash)

  unless plan["dry_run"] == true
    validation_error(result, "#{source}.dry_run",
      "Destructive action plan dry_run must be true before execution.")
  end

  targets = plan["targets"]
  unless targets.is_a?(Array) && !targets.empty?
    validation_error(result, "#{source}.targets",
      "Destructive action plan must declare a non-empty targets list.")
    return
  end

  targets.each_with_index do |target, i|
    next unless target.is_a?(Hash)

    target_src = "#{source}.targets[#{i}]"
    recoverability = target["recoverability"].to_s.strip
    if recoverability.empty?
      validation_error(result, "#{target_src}.recoverability",
        "Destructive action plan target must declare recoverability.")
    end

    evidence_impact = target["evidence_impact"].to_s.strip
    if !evidence_impact.empty? && evidence_impact != "none"
      unless %w[hash_only hash_and_backup full_backup].include?(recoverability)
        validation_error(result, "#{target_src}.recoverability",
          "Evidence-affecting destructive action target requires hash or backup recoverability (got: #{recoverability.inspect}).")
      end
    end

    owner = target["owner"].to_s.strip
    next unless %w[user unknown].include?(owner)

    unless plan.dig("user_confirmation", "received") == true
      validation_error(result, "#{source}.user_confirmation.received",
        "Destructive action on #{owner}-owned files requires user_confirmation.received: true.")
    end
  end
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

ALLOWED_LOOP_PHASES = %w[idle working in_review in_test blocked done drafting review_requested changes_requested user_confirmed coding_ready].freeze
DESIGN_LIFECYCLE_PHASES = %w[drafting review_requested changes_requested user_confirmed coding_ready].freeze
ALLOWED_PARENT_GOAL_STATES = %w[not_applicable parent_in_progress slice_ready parent_blocked parent_done_ready parent_done].freeze
ALLOWED_GATE_KINDS = %w[review test design_readiness release].freeze
EXPECTED_GATE_ROLES = {
  "review"           => "reviewer",
  "test"             => "tester",
  "design_readiness" => "reviewer",
  "release"          => "tester"
}.freeze
# Maps gate kind to the evidence record kind used to satisfy it.
# design_readiness uses review records; release uses test records.
GATE_KIND_EVIDENCE_RECORD_KIND = {
  "review"           => "review",
  "test"             => "test",
  "design_readiness" => "review",
  "release"          => "test"
}.freeze

# Evidence levels are organized into semantic families. Levels from different families
# are NOT mutually substitutable: outcome_quality cannot satisfy implementation_readiness,
# and vice versa. mechanical_check is the universal base level for all families.
EVIDENCE_LEVEL_FAMILIES = {
  "review_quality"   => %w[mechanical_check outcome_quality],
  "design_readiness" => %w[mechanical_check implementation_readiness],
  "test_quality"     => %w[mechanical_check real_path_test],
  "release_quality"  => %w[mechanical_check release_readiness]
}.freeze

# Maps each non-universal evidence level to its semantic family.
# mechanical_check is universal (not in this map).
EVIDENCE_LEVEL_FAMILY_MAP = {
  "outcome_quality"          => "review_quality",
  "implementation_readiness" => "design_readiness",
  "real_path_test"           => "test_quality",
  "release_readiness"        => "release_quality"
}.freeze

# Evidence level families accepted at each gate kind.
# review gates accept both review_quality and design_readiness families for flexibility.
GATE_KIND_ACCEPTED_EVIDENCE_FAMILIES = {
  "review"           => %w[review_quality design_readiness],
  "design_readiness" => %w[design_readiness],
  "test"             => %w[test_quality],
  "release"          => %w[release_quality]
}.freeze

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
    when "--parent-state"
      options["parent_state"] = option_value(args, "--parent-state")
    when /\A--parent-state=(.+)\z/
      options["parent_state"] = Regexp.last_match(1)
    when "--active-slice"
      options["active_slice"] = option_value(args, "--active-slice")
    when /\A--active-slice=(.+)\z/
      options["active_slice"] = Regexp.last_match(1)
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
  write_file_atomically(path, YAML.dump(state))
end

def update_loop_state(path)
  update_yaml_file_atomically(path) do |state|
    validate_loop_state!(state, path)
    updated = yield(state)
    updated ||= state
    validate_loop_state!(updated, path)
    updated
  end
rescue RuntimeError => e
  state_error(e.message)
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
  now = Time.now.utc.iso8601
  start_phase = design_task?(task) ? "drafting" : "working"
  previous_phase = nil

  update_loop_state(state_path) do |state|
    previous_phase = state["phase"]
    state["project"] = task["project"] || File.basename(Dir.pwd)
    state["current_task"] = task_path
    state["phase"] = start_phase
    state["owner_role"] = owner_role
    state["status"] = start_phase
    state["updated_at"] = now
    state["artifacts"] ||= {}
    state_error("Loop state artifacts must be a mapping when present.") unless state["artifacts"].is_a?(Hash)
    state["artifacts"]["task_file"] = task_path
    append_state_history(state, {
      "event" => "start",
      "from" => previous_phase,
      "to" => start_phase,
      "task" => task_path,
      "owner_role" => owner_role,
      "created_at" => now
    })
    state
  end
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

  now = Time.now.utc.iso8601
  previous_phase = nil

  update_loop_state(state_path) do |state|
    previous_phase = state["phase"]
    task_path = state["current_task"]
    task = task_path ? load_state_task(task_path) : nil

    validate_done_transition!(state_path, task_path, options["evidence"]) if target_phase == "done"
    validate_design_transition!(previous_phase, target_phase, task, options["evidence"]) if task && design_task?(task)

    if previous_phase == "working" && target_phase == "done" && task && review_or_test_gate?(task)
      state_error("Cannot transition directly from working to done for review/test task.")
    end

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
    state
  end
  puts "Transitioned Orbit state:"
  puts "- #{previous_phase} -> #{target_phase}"
end

def user_confirmation_record?(record)
  return false unless record.is_a?(Hash)
  return false unless record["status"] == "pass"
  return false unless %w[implementation command].include?(record["kind"])

  summary = record["summary"].to_s.downcase
  summary.include?("user_confirmed") || summary.include?("user confirmation") || summary.include?("用户确认")
end

def evidence_has_user_confirmation?(evidence)
  records = evidence.is_a?(Hash) ? evidence["records"] : nil
  records.is_a?(Array) && records.any? { |record| user_confirmation_record?(record) }
end

def validate_design_coding_ready_evidence!(evidence_path)
  state_error("Design transition to user_confirmed/coding_ready requires --evidence.") if evidence_path.nil? || evidence_path.empty?

  evidence = load_evidence_manifest(File.expand_path(evidence_path))
  records = evidence["records"].is_a?(Array) ? evidence["records"] : []
  state_error("Design transition requires structured review pass evidence.") unless gate_passed?(records, "review")
  state_error("Design transition requires user_confirmed evidence from the user confirmation step.") unless evidence_has_user_confirmation?(evidence)
end

def validate_design_transition!(previous_phase, target_phase, task, evidence_path)
  return unless DESIGN_LIFECYCLE_PHASES.include?(target_phase)

  allowed = {
    "drafting" => %w[idle working drafting],
    "review_requested" => %w[drafting changes_requested],
    "changes_requested" => %w[review_requested],
    "user_confirmed" => %w[review_requested],
    "coding_ready" => %w[user_confirmed]
  }

  allowed_previous = allowed[target_phase] || []
  unless allowed_previous.include?(previous_phase)
    state_error("Invalid design transition #{previous_phase} -> #{target_phase}; expected previous phase one of #{allowed_previous.join("|")}.")
  end

  validate_design_coding_ready_evidence!(evidence_path) if %w[user_confirmed coding_ready].include?(target_phase)
end

def state_progress(options)
  state_path = File.expand_path(options["state"])
  message = options["message"].to_s.strip
  state_error("Progress message must be non-empty.") if message.empty?

  # Validate --parent-state enum before any side effects
  if options["parent_state"] && !ALLOWED_PARENT_GOAL_STATES.include?(options["parent_state"])
    state_error("--parent-state must be one of #{ALLOWED_PARENT_GOAL_STATES.join("|")}.")
  end

  now = Time.now.utc.iso8601

  update_loop_state(state_path) do |state|
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
    state
  end

  # Optionally update parent_goal_status in the task file if --task is given
  if options["parent_state"] || options["active_slice"]
    task_path_opt = options["task"]
    if task_path_opt.nil? || task_path_opt.empty?
      # Fall back to current_task from loop state
      raw_state = YAML.safe_load(File.read(File.expand_path(options["state"]))) rescue nil
      task_path_opt = raw_state.is_a?(Hash) ? raw_state["current_task"] : nil
    end
    if task_path_opt && !task_path_opt.empty?
      task_full_path = File.expand_path(task_path_opt)
      if File.exist?(task_full_path)
        raw_task = YAML.safe_load(File.read(task_full_path)) rescue nil
        if raw_task.is_a?(Hash)
          raw_task["parent_goal_status"] ||= {}
          raw_task["parent_goal_status"]["state"] = options["parent_state"] if options["parent_state"]
          raw_task["parent_goal_status"]["active_slice"] = options["active_slice"] if options["active_slice"]
          File.write(task_full_path, YAML.dump(raw_task))
          puts "Updated parent_goal_status in task file."
        end
      end
    end
  end

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


require_relative "validate_task_contract"
require_relative "validate_evidence_record"
require_relative "validate_gate_commands"

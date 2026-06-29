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

def validate_instance_management_field(result, source, instance_name, instance)
  management = instance_management(instance)
  unless ALLOWED_INSTANCE_MANAGEMENT.include?(management)
    validation_error(result, "project_config.instances.#{source}.management", "Instance #{instance_name.inspect} management must be one of #{ALLOWED_INSTANCE_MANAGEMENT.join("|")}.")
  end
end

def validate_instance_transport_field(result, source, instance_name, transport)
  return if transport.nil?

  unless transport.is_a?(Hash)
    validation_error(result, "project_config.instances.#{source}.transport", "Instance #{instance_name.inspect} transport must be a mapping.")
    return
  end

  kind = transport["kind"].to_s
  unless kind.empty? || ALLOWED_INSTANCE_TRANSPORTS.include?(kind)
    validation_error(result, "project_config.instances.#{source}.transport.kind", "Instance #{instance_name.inspect} transport.kind must be one of #{ALLOWED_INSTANCE_TRANSPORTS.join("|")}.")
  end

  %w[binding health].each do |field|
    value = transport[field]
    next if value.nil? || value.is_a?(Hash)

    validation_error(result, "project_config.instances.#{source}.transport.#{field}", "Instance #{instance_name.inspect} transport.#{field} must be a mapping when present.")
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
    validate_instance_management_field(result, name, name, instance)
    validate_instance_transport_field(result, name, name, instance["transport"])

    role_def = role_ref && roles[role_ref]
    resolved_role = role_def.is_a?(Hash) ? (role_def["role"] || role_ref) : nil
    validate_instance_env(result, name, name, instance["env"], resolved_role)
  end

  [roles, instances]
end

def improvement_task?(task)
  task_type = task["task_type"].to_s
  %w[improvement refactor split docs documentation performance speed latency ux workflow reliability architecture].any? do |token|
    task_type.include?(token)
  end
end

def task_type_value(task_or_type)
  task_or_type.is_a?(Hash) ? task_or_type["task_type"] : task_or_type
end

def design_task?(task_or_type)
  task_type = task_type_value(task_or_type).to_s.downcase
  task_type.include?("design") || task_type.include?("analysis")
end

def coding_task?(task_or_type)
  task_type_value(task_or_type).to_s.downcase.include?("coding")
end

def decomposition_task?(task_or_type)
  task_type = task_type_value(task_or_type).to_s.downcase
  task_type.include?("decomposition") || task_type.include?("parent")
end

def test_task_contract?(task)
  task.is_a?(Hash) && (task["target_role"].to_s == "tester" || task["task_type"].to_s.downcase.include?("test"))
end

def quality_measurement_task?(task_or_type)
  task_type = task_type_value(task_or_type).to_s.downcase
  %w[performance speed latency ux workflow quality eval llm measurement].any? { |token| task_type.include?(token) }
end

def validate_invalid_completion_guards(result, task)
  guards = task["invalid_completion_guards"]
  if guards.nil?
    validation_warning(result, "task_file.invalid_completion_guards",
      "Improvement task should define invalid_completion_guards so reviewers can explicitly address each failure pattern.")
    return
  end
  unless guards.is_a?(Array)
    validation_error(result, "task_file.invalid_completion_guards", "Task invalid_completion_guards must be a list when present.")
    return
  end
  guards.each_with_index do |guard, index|
    src = "task_file.invalid_completion_guards[#{index}]"
    unless guard.is_a?(Hash)
      validation_error(result, src, "Invalid completion guard must be a mapping.")
      next
    end
    validate_non_empty_string(result, "#{src}.id", guard["id"], "Guard id")
    validate_non_empty_string(result, "#{src}.description", guard["description"], "Guard description")
    validate_non_empty_string(result, "#{src}.evidence_required", guard["evidence_required"], "Guard evidence_required")
  end
end

def validate_required_questions_coverage(result, record, task)
  return unless record.is_a?(Hash) && task.is_a?(Hash)

  required_questions = task.dig("review_strategy", "required_questions")
  return unless required_questions.is_a?(Array) && !required_questions.empty?

  answers = record["quality_question_answers"]
  return unless answers.is_a?(Array)

  answered_pass_ids = answers.select { |a| a.is_a?(Hash) && a["verdict"] == "pass" }.map { |a| a["id"] }.compact
  required_questions.each do |qid|
    next if answered_pass_ids.include?(qid)

    existing = answers.find { |a| a.is_a?(Hash) && a["id"] == qid }
    if existing
      validation_error(
        result,
        "evidence_file.records.review.quality_question_answers",
        "Review PASS requires quality_question_answers[#{qid.inspect}].verdict to be pass (got: #{existing["verdict"].inspect})."
      )
    else
      validation_error(
        result,
        "evidence_file.records.review.quality_question_answers",
        "Review PASS requires quality_question_answers to include an answer for required question: #{qid.inspect}."
      )
    end
  end
end

def required_questions_all_pass?(record, task)
  return true unless task.is_a?(Hash)

  required_questions = task.dig("review_strategy", "required_questions")
  return true unless required_questions.is_a?(Array) && !required_questions.empty?

  answers = record["quality_question_answers"]
  return false unless answers.is_a?(Array) && !answers.empty?

  pass_ids = answers.select { |a| a.is_a?(Hash) && a["verdict"] == "pass" }.map { |a| a["id"] }.compact
  required_questions.all? { |qid| pass_ids.include?(qid) }
end

def validate_quality_outcome(result, task)
  source = "task_file.quality_outcome"
  outcome = task["quality_outcome"]
  unless outcome.is_a?(Hash)
    validation_error(result, source, "Improvement task quality_outcome must be a mapping.")
    return
  end

  validate_non_empty_string(result, "#{source}.user_problem", outcome["user_problem"], "Quality outcome user_problem")
  validate_non_empty_string(result, "#{source}.desired_property", outcome["desired_property"], "Quality outcome desired_property")

  thresholds = outcome["measurable_thresholds"]
  unless thresholds.is_a?(Array) && thresholds.any? && thresholds.all? { |item| item.is_a?(String) && !item.strip.empty? }
    validation_error(result, "#{source}.measurable_thresholds", "Quality outcome measurable_thresholds must be a non-empty list of non-empty strings.")
  end

  invalid_completions = outcome["invalid_completions"]
  unless invalid_completions.is_a?(Array) && invalid_completions.any? && invalid_completions.all? { |item| item.is_a?(String) && !item.strip.empty? }
    validation_error(result, "#{source}.invalid_completions", "Quality outcome invalid_completions must be a non-empty list of non-empty strings.")
  end
end

def validate_design_lifecycle(result, task)
  lifecycle = task["design_lifecycle"]
  if lifecycle.nil?
    validation_error(result, "task_file.design_lifecycle", "Design task must define design_lifecycle.")
    return
  end

  unless lifecycle.is_a?(Hash)
    validation_error(result, "task_file.design_lifecycle", "Task design_lifecycle must be a mapping.")
    return
  end

  unless lifecycle["enabled"] == true
    validation_error(result, "task_file.design_lifecycle.enabled", "Design task design_lifecycle.enabled must be true.")
  end

  phases = lifecycle["phases"]
  unless phases.is_a?(Array) && DESIGN_LIFECYCLE_PHASES.all? { |phase| phases.include?(phase) }
    validation_error(result, "task_file.design_lifecycle.phases", "Design task phases must include #{DESIGN_LIFECYCLE_PHASES.join("|")}.")
  end

  current_phase = lifecycle["current_phase"]
  unless DESIGN_LIFECYCLE_PHASES.include?(current_phase)
    validation_error(result, "task_file.design_lifecycle.current_phase", "Design task current_phase must be one of #{DESIGN_LIFECYCLE_PHASES.join("|")}.")
  end

  unless lifecycle["user_confirmation_required"] == true
    validation_error(result, "task_file.design_lifecycle.user_confirmation_required", "Design task must require user confirmation before coding_ready.")
  end

  unless lifecycle["coding_requires_confirmed_design"] == true
    validation_error(result, "task_file.design_lifecycle.coding_requires_confirmed_design", "Design task must require confirmed design before coding.")
  end
end

def validate_coding_design_reference(result, task)
  reference = task["design_reference"]
  if reference.nil?
    validation_error(result, "task_file.design_reference", "Coding task must define design_reference.")
    return
  end

  unless reference.is_a?(Hash)
    validation_error(result, "task_file.design_reference", "Coding task design_reference must be a mapping.")
    return
  end

  unless reference["required_for_coding"] == true
    validation_error(result, "task_file.design_reference.required_for_coding", "Coding task design_reference.required_for_coding must be true.")
  end

  validate_non_empty_string(result, "task_file.design_reference.artifact", reference["artifact"], "Coding task design artifact")
  validate_non_empty_string(result, "task_file.design_reference.confirmation_evidence", reference["confirmation_evidence"], "Coding task design confirmation evidence")

  unless reference["status"] == "confirmed"
    validation_error(result, "task_file.design_reference.status", "Coding task design_reference.status must be confirmed.")
  end
end

def validate_decomposition_contract(result, task)
  plan = task["implementation_plan"]
  if plan.nil?
    validation_error(result, "task_file.implementation_plan", "Decomposition task must define implementation_plan.")
  elsif !plan.is_a?(Hash)
    validation_error(result, "task_file.implementation_plan", "Task implementation_plan must be a mapping.")
  else
    unless plan["required"] == true
      validation_error(result, "task_file.implementation_plan.required", "Decomposition task implementation_plan.required must be true.")
    end
    validate_non_empty_string(result, "task_file.implementation_plan.summary", plan["summary"], "Implementation plan summary")
  end

  decomposition = task["decomposition"]
  if decomposition.nil?
    validation_error(result, "task_file.decomposition", "Decomposition task must define decomposition.")
  elsif !decomposition.is_a?(Hash)
    validation_error(result, "task_file.decomposition", "Task decomposition must be a mapping.")
  else
    child_slices = decomposition["child_slices"]
    required_slice_fields = %w[id include exclude order_basis stop_condition replan_path]
    unless child_slices.is_a?(Array) && child_slices.any?
      validation_error(result, "task_file.decomposition.child_slices", "Decomposition child_slices must be a non-empty list of mappings.")
    else
      child_slices.each_with_index do |slice, index|
        source = "task_file.decomposition.child_slices[#{index}]"
        unless slice.is_a?(Hash)
          validation_error(result, source, "Decomposition child slice must be a mapping.")
          next
        end

        required_slice_fields.each do |field|
          validate_non_empty_string(result, "#{source}.#{field}", slice[field], "Decomposition child slice #{field}")
        end
      end
    end

    metrics = decomposition["aggregate_outcome_metrics"]
    unless metrics.is_a?(Array) && metrics.any? && metrics.all? { |metric| metric.is_a?(String) && !metric.strip.empty? }
      validation_error(result, "task_file.decomposition.aggregate_outcome_metrics", "Decomposition aggregate_outcome_metrics must be a non-empty list of non-empty strings.")
    end

    stop_conditions = decomposition["stop_conditions"]
    unless stop_conditions.is_a?(Array) && stop_conditions.any? && stop_conditions.all? { |condition| condition.is_a?(String) && !condition.strip.empty? }
      validation_error(result, "task_file.decomposition.stop_conditions", "Decomposition stop_conditions must be a non-empty list of non-empty strings.")
    end

    validate_non_empty_string(result, "task_file.decomposition.replanning_path", decomposition["replanning_path"], "Decomposition replanning_path")
  end

  final_audit = task["final_aggregate_audit"]
  if final_audit.nil?
    validation_error(result, "task_file.final_aggregate_audit", "Decomposition task must define final_aggregate_audit.")
  elsif !final_audit.is_a?(Hash)
    validation_error(result, "task_file.final_aggregate_audit", "Task final_aggregate_audit must be a mapping.")
  else
    unless final_audit["required"] == true
      validation_error(result, "task_file.final_aggregate_audit.required", "Decomposition task final_aggregate_audit.required must be true.")
    end
    checks = final_audit["checks"]
    unless checks.is_a?(Array) && checks.any? && checks.all? { |check| check.is_a?(String) && !check.strip.empty? }
      validation_error(result, "task_file.final_aggregate_audit.checks", "Final aggregate audit checks must be a non-empty list of non-empty strings.")
    end
  end
end

def validate_test_environment_contract(result, task)
  env = task["test_environment"]
  if env.nil?
    validation_error(result, "task_file.test_environment", "Test task must define test_environment.")
    return
  end
  unless env.is_a?(Hash)
    validation_error(result, "task_file.test_environment", "Task test_environment must be a mapping.")
    return
  end
  validation_error(result, "task_file.test_environment.required", "Test task test_environment.required must be true.") unless env["required"] == true
  %w[environment test_tab_or_pane server_owner browser_owner cleanup_hook artifact_cleanup duration_budget resource_budget].each do |field|
    validate_non_empty_string(result, "task_file.test_environment.#{field}", env[field], "Test environment #{field}")
  end
end

def task_requires_test_evidence?(task)
  return false unless task.is_a?(Hash)

  test_task_contract?(task) || task_gate_kinds(task, required_only: true).include?("test")
end

def validate_task_test_level_contract(result, task)
  return unless task_requires_test_evidence?(task)

  level = task["test_level"]
  unless level.is_a?(String) && !level.strip.empty?
    validation_error(result, "task_file.test_level", "Task requiring test evidence must define test_level.")
    return
  end

  unless ALLOWED_TEST_LEVELS.include?(level)
    validation_error(result, "task_file.test_level", "Task test_level must be one of #{ALLOWED_TEST_LEVELS.join("|")}.")
  end

  if test_task_contract?(task) && level == "not_applicable"
    validation_error(result, "task_file.test_level", "Test task test_level must not be not_applicable.")
  end
end

def validate_quality_measurement_contract(result, task)
  measurement = task["quality_measurement"]
  if measurement.nil?
    validation_error(result, "task_file.quality_measurement", "Quality measurement task must define quality_measurement.")
    return
  end
  unless measurement.is_a?(Hash)
    validation_error(result, "task_file.quality_measurement", "Task quality_measurement must be a mapping.")
    return
  end
  validation_error(result, "task_file.quality_measurement.required", "Quality measurement required must be true.") unless measurement["required"] == true
  validation_error(result, "task_file.quality_measurement.baseline_required", "Quality measurement baseline_required must be true.") unless measurement["baseline_required"] == true
  validation_error(result, "task_file.quality_measurement.after_required", "Quality measurement after_required must be true.") unless measurement["after_required"] == true
  metrics = measurement["metrics"]
  unless metrics.is_a?(Array) && metrics.any? && metrics.all? { |item| item.is_a?(String) && !item.strip.empty? }
    validation_error(result, "task_file.quality_measurement.metrics", "Quality measurement metrics must be a non-empty list of non-empty strings.")
  end
  validate_non_empty_string(result, "task_file.quality_measurement.waiver_policy", measurement["waiver_policy"], "Quality measurement waiver_policy")
end

def review_or_test_gate?(task)
  return false if light_risk?(task)

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
  return [] if light_risk?(task)

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

  task_compat = schema_version_compat(task["schema_version"], "task")
  case task_compat
  when :current
    # OK
  when :legacy
    validation_error(result, "task_file.schema_version", "Task schema_version must be orbit-task-v1.")
  when :unknown_future
    entry = schema_unknown_version_entry("task_file.schema_version", task["schema_version"], "task")
    validation_error(result, "task_file.schema_version",
      "#{entry["message"]} #{entry["action"]}")
  end

  # Legacy warning: schema_semantics absent means task predates schema versioning.
  if task_compat == :current && task["schema_semantics"].nil?
    validation_warning(result, "task_file.schema_semantics",
      "legacy_warning: Task file lacks schema_semantics; " \
      "feature version tracking unavailable. " \
      "Task was created before orbit-schema-versioning-v1. " \
      "Existing tasks remain valid.")
  end

  if task["target_role"].nil? || task["target_role"].to_s.empty?
    validation_error(result, "task_file.target_role", "Task must define target_role.")
  end

  unless task.key?("evidence_requirements")
    validation_error(result, "task_file.evidence_requirements", "Task must define evidence_requirements.")
  end

  if improvement_task?(task)
    if !task.key?("quality_outcome")
      validation_error(result, "task_file.quality_outcome", "Improvement task must define quality_outcome.")
    else
      validate_quality_outcome(result, task)
    end
    validate_invalid_completion_guards(result, task)
  end

  validate_design_lifecycle(result, task) if design_task?(task)
  validate_coding_design_reference(result, task) if coding_task?(task)
  validate_decomposition_contract(result, task) if decomposition_task?(task)
  validate_test_environment_contract(result, task) if test_task_contract?(task)
  validate_task_test_level_contract(result, task)
  validate_quality_measurement_contract(result, task) if quality_measurement_task?(task)
  validate_parent_goal(result, task) if parent_goal_required?(task)

  validate_task_runtime_fields(result, task)

  validate_task_risk_level(result, task)
  validate_project_profile(result, task)
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

  review_strategy = task["review_strategy"]
  if review_strategy.is_a?(Hash) && review_strategy.key?("minimum_evidence_level")
    minimum = review_strategy["minimum_evidence_level"]
    unless minimum.nil? || minimum.to_s.strip.empty? || ALLOWED_EVIDENCE_LEVELS.include?(minimum)
      validation_error(result, "task_file.review_strategy.minimum_evidence_level", "Task review_strategy.minimum_evidence_level must be one of #{ALLOWED_EVIDENCE_LEVELS.join("|")}.")
    end
  end

  test_strategy = task["test_strategy"]
  if test_strategy.is_a?(Hash) && test_strategy.key?("minimum_evidence_level")
    minimum = test_strategy["minimum_evidence_level"]
    unless minimum.nil? || minimum.to_s.strip.empty? || ALLOWED_EVIDENCE_LEVELS.include?(minimum)
      validation_error(result, "task_file.test_strategy.minimum_evidence_level", "Task test_strategy.minimum_evidence_level must be one of #{ALLOWED_EVIDENCE_LEVELS.join("|")}.")
    end
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

  validate_artifact_policy_field(result, task)
  validate_destructive_actions_field(result, task)
  validate_write_policy_enforcement_field(result, task)

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

def parent_goal_required?(task)
  pg = task.is_a?(Hash) ? task["parent_goal"] : nil
  pg.is_a?(Hash) && pg["required"] == true
end

def validate_parent_goal(result, task)
  parent_goal = task["parent_goal"]
  unless parent_goal.is_a?(Hash)
    validation_error(result, "task_file.parent_goal", "Task with parent_goal.required must define parent_goal as a mapping.")
    return
  end

  objective = parent_goal["objective"]
  if objective.nil? || !objective.is_a?(String) || objective.strip.empty?
    validation_error(result, "task_file.parent_goal.objective", "Parent goal objective must be a non-empty string.")
  end

  done_criteria = parent_goal["done_criteria"]
  unless done_criteria.is_a?(Array) && !done_criteria.empty? && done_criteria.all? { |c| c.is_a?(String) && !c.strip.empty? }
    validation_error(result, "task_file.parent_goal.done_criteria", "Parent task done_criteria must be a non-empty list of non-empty strings.")
  end

  status = task["parent_goal_status"]
  unless status.is_a?(Hash)
    validation_error(result, "task_file.parent_goal_status", "Task with parent_goal.required must define parent_goal_status as a mapping.")
    return
  end

  state_val = status["state"].to_s
  if !state_val.empty? && !ALLOWED_PARENT_GOAL_STATES.include?(state_val)
    validation_error(result, "task_file.parent_goal_status.state", "parent_goal_status.state must be one of #{ALLOWED_PARENT_GOAL_STATES.join("|")}.")
  end

  if state_val == "parent_done"
    pg_criteria = parent_goal["done_criteria"].is_a?(Array) ? parent_goal["done_criteria"] : []
    criteria_status = status["done_criteria_status"].is_a?(Array) ? status["done_criteria_status"] : []
    evidenced = criteria_status.select { |cs| cs.is_a?(Hash) && cs["evidenced"] == true }.map { |cs| cs["criterion"] }
    unevidenced = pg_criteria.reject { |c| evidenced.include?(c) }
    unless unevidenced.empty?
      validation_error(result, "task_file.parent_goal_status.done_criteria_status",
        "parent_goal_status.state is parent_done but #{unevidenced.length} done criteria lack evidence.")
    end
  end

  user_next = status["user_next_action"]
  return unless user_next.is_a?(Hash)

  default_action = user_next["default"]
  if default_action.nil? || !default_action.is_a?(String) || default_action.strip.empty?
    validation_error(result, "task_file.parent_goal_status.user_next_action.default", "parent_goal_status.user_next_action.default must be a non-empty string.")
  end
end

# Slice 11: validate task_risk and project_profile fields.
def validate_task_risk_level(result, task)
  return unless task.key?("task_risk")

  risk = task["task_risk"]
  unless risk.is_a?(Hash)
    validation_error(result, "task_file.task_risk", "Task task_risk must be a mapping.")
    return
  end

  level = risk["level"]
  unless level.is_a?(String) && ALLOWED_RISK_LEVELS.include?(level)
    validation_error(result, "task_file.task_risk.level", "Task task_risk.level must be one of #{ALLOWED_RISK_LEVELS.join("|")}.")
    return
  end

  default_levels = DEFAULT_MIN_EVIDENCE_LEVELS_BY_RISK[level] || {}

  # Release risk requires release gate AND release readiness evidence fields or explicit gap.
  if level == "release"
    gates = task["gates"]
    has_release_gate = gates.is_a?(Array) && gates.any? { |g| g.is_a?(Hash) && g["kind"] == "release" }
    unless has_release_gate
      validation_error(result, "task_file.task_risk.level",
        "Release risk level requires a release gate with release_readiness evidence.")
    end
    # Fail closed: release readiness evidence fields must be present or explicit gap declared.
    unless task.key?("release_readiness")
      validation_error(result, "task_file.release_readiness",
        "Release risk level requires release_readiness evidence fields or an explicit release readiness gap declaration.")
    end
  end

  # Strict or release risk requires strict write_policy_enforcement.
  if %w[strict release].include?(level)
    wpe = task["write_policy_enforcement"].to_s
    unless wpe == "strict"
      validation_error(result, "task_file.write_policy_enforcement",
        "#{level} risk level requires write_policy_enforcement: strict; got #{wpe.inspect}.")
    end
  end

  # Check minimum_evidence_levels don't lower the bar below risk-derived defaults.
  min_levels = risk["minimum_evidence_levels"]
  if min_levels.is_a?(Hash)
    min_levels.each do |gate_kind, actual_min|
      next unless actual_min.is_a?(String)
      risk_default = default_levels[gate_kind.to_s]
      next unless risk_default
      # actual_min must satisfy (>=) risk_default; it can only raise the bar, not lower it.
      unless evidence_level_satisfies_minimum?(actual_min, risk_default)
        validation_error(result, "task_file.task_risk.minimum_evidence_levels.#{gate_kind}",
          "task_risk.minimum_evidence_levels.#{gate_kind} (#{actual_min}) cannot be lower than risk-derived default (#{risk_default}) for #{level} risk; record a waiver to lower.")
      end
    end
  end

  # Check review_strategy.minimum_evidence_level is not lowered below risk default.
  # Skip for design tasks: implementation_readiness is the correct design_readiness family level,
  # not a lowering of the review_quality family's outcome_quality.
  unless design_task?(task["task_type"])
    review_strategy = task["review_strategy"]
    if review_strategy.is_a?(Hash) && review_strategy.key?("minimum_evidence_level")
      actual_review_min = review_strategy["minimum_evidence_level"].to_s
      risk_review_default = default_levels["review"]
      if risk_review_default && !actual_review_min.empty? && !evidence_level_satisfies_minimum?(actual_review_min, risk_review_default)
        validation_error(result, "task_file.review_strategy.minimum_evidence_level",
          "review_strategy.minimum_evidence_level (#{actual_review_min}) cannot be lower than risk-derived default (#{risk_review_default}) for #{level} risk.")
      end
    end
  end

  # Check test_strategy.minimum_evidence_level is not lowered below risk default.
  test_strategy = task["test_strategy"]
  if test_strategy.is_a?(Hash) && test_strategy.key?("minimum_evidence_level")
    actual_test_min = test_strategy["minimum_evidence_level"].to_s
    risk_test_default = default_levels["test"]
    if risk_test_default && !actual_test_min.empty? && !evidence_level_satisfies_minimum?(actual_test_min, risk_test_default)
      validation_error(result, "task_file.test_strategy.minimum_evidence_level",
        "test_strategy.minimum_evidence_level (#{actual_test_min}) cannot be lower than risk-derived default (#{risk_test_default}) for #{level} risk.")
    end
  end
end

# Slice 11: validate project_profile structure when present.
def validate_project_profile(result, task)
  return unless task.key?("project_profile")

  profile = task["project_profile"]
  unless profile.is_a?(Hash)
    validation_error(result, "task_file.project_profile", "Task project_profile must be a mapping.")
    return
  end

  default_risk = profile["default_risk_level"]
  if default_risk && !(default_risk.is_a?(String) && ALLOWED_RISK_LEVELS.include?(default_risk))
    validation_error(result, "task_file.project_profile.default_risk_level",
      "project_profile.default_risk_level must be one of #{ALLOWED_RISK_LEVELS.join("|")} when present.")
  end

  traits = profile["workflow_traits"]
  if traits && !(traits.is_a?(Array) && traits.all? { |t| t.is_a?(String) && !t.strip.empty? })
    validation_error(result, "task_file.project_profile.workflow_traits",
      "project_profile.workflow_traits must be a list of non-empty strings when present.")
  end
end


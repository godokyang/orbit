# frozen_string_literal: true

def parse_new_task_args(args)
  options = {
    "project" => File.basename(Dir.pwd)
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--target-role"
      option_value(args, "--target-role")
      usage_error("orbit new-task --target-role was removed. Re-run orbit init with --operation-mode solo|team and use execution_contract defaults, or pass --implementation-authority/--assigned-instance.")
    when /\A--target-role=(.+)\z/
      usage_error("orbit new-task --target-role was removed. Re-run orbit init with --operation-mode solo|team and use execution_contract defaults, or pass --implementation-authority/--assigned-instance.")
    when "--task-type"
      options["task_type"] = option_value(args, "--task-type")
    when /\A--task-type=(.+)\z/
      options["task_type"] = Regexp.last_match(1)
    when "--operation-mode"
      options["operation_mode"] = option_value(args, "--operation-mode")
    when /\A--operation-mode=(.+)\z/
      options["operation_mode"] = Regexp.last_match(1)
    when "--implementation-authority"
      options["implementation_authority"] = option_value(args, "--implementation-authority")
    when /\A--implementation-authority=(.+)\z/
      options["implementation_authority"] = Regexp.last_match(1)
    when "--assigned-instance"
      options["assigned_instance"] = option_value(args, "--assigned-instance")
    when /\A--assigned-instance=(.+)\z/
      options["assigned_instance"] = Regexp.last_match(1)
    when "--owner-role"
      options["owner_role"] = option_value(args, "--owner-role")
    when /\A--owner-role=(.+)\z/
      options["owner_role"] = Regexp.last_match(1)
    when "--owner-instance"
      options["owner_instance"] = option_value(args, "--owner-instance")
    when /\A--owner-instance=(.+)\z/
      options["owner_instance"] = Regexp.last_match(1)
    when "--output"
      options["output"] = option_value(args, "--output")
    when /\A--output=(.+)\z/
      options["output"] = Regexp.last_match(1)
    when "--project"
      options["project"] = option_value(args, "--project")
    when /\A--project=(.+)\z/
      options["project"] = Regexp.last_match(1)
    else
      usage_error("Unknown new-task option: #{arg}")
    end
  end

  %w[task_type output].each do |name|
    usage_error("Missing required option: --#{name.tr("_", "-")}") if options[name].nil? || options[name].empty?
  end

  options
end

def default_gates_for_new_task(task_type, implementation_authority = nil)
  authority = implementation_authority.to_s
  type = task_type.to_s
  return [] if type.include?("review") || type.include?("test")
  return [] unless %w[lead coder].include?(authority) || type.include?("implementation") || type.include?("coding")

  [
    {
      "kind" => "review",
      "roles" => ["reviewer"],
      "required" => true,
      "pass_condition" => "latest review evidence status is pass and no high/medium findings remain"
    },
    {
      "kind" => "test",
      "roles" => ["tester"],
      "required" => true,
      "pass_condition" => "latest test evidence status is pass for required real behavior coverage"
    }
  ]
end

def quality_outcome_template(task_type)
  type = task_type.to_s.downcase
  if type.include?("refactor") || type.include?("split")
    {
      "user_problem" => "Current structure makes future changes risky or expensive because responsibilities are hard to isolate.",
      "desired_property" => "Responsibilities, dependency direction, and public entrypoints are clearer after the change.",
      "measurable_thresholds" => [
        "Reviewer can identify the new module boundaries and why they reduce future change cost.",
        "Tests or static checks cover the moved or rewritten behavior.",
        "Old paths no longer remain as a second authoritative implementation."
      ],
      "invalid_completions" => [
        "Only moving a small amount of code without reducing coupling or clarifying ownership.",
        "Adding a facade while the old implementation still writes authoritative state.",
        "Passing tests without evidence that maintainability improved."
      ]
    }
  elsif type.include?("doc")
    {
      "user_problem" => "Project documentation or runtime instructions are stale, incomplete, duplicated, or hard to act on.",
      "desired_property" => "The relevant audience can find the current rule, decision, or workflow without relying on chat history.",
      "measurable_thresholds" => [
        "Updated docs map each changed rule or plan item to the problem it closes.",
        "Stale or conflicting guidance is removed, marked deprecated, or linked to the new source of truth.",
        "Commands, paths, or examples in the changed docs are verifiable or explicitly scoped as illustrative."
      ],
      "invalid_completions" => [
        "Only adding prose without resolving the stale or conflicting guidance.",
        "Moving documentation while leaving broken references or duplicate sources of truth.",
        "Documenting a workflow that CLI/templates/tests do not support when the task requires hardening."
      ]
    }
  elsif type.include?("performance") || type.include?("speed") || type.include?("latency")
    {
      "user_problem" => "The current behavior is too slow, costly, or resource-heavy for the intended workflow.",
      "desired_property" => "The change improves speed, cost, or resource usage without hiding failures or moving cost elsewhere.",
      "measurable_thresholds" => [
        "Baseline and after evidence, benchmark, timing, or a clear waiver explains the performance claim.",
        "Failure rate, retries, output quality, and resource usage do not regress in the tested path.",
        "The metric can be re-run or audited by a tester."
      ],
      "invalid_completions" => [
        "Only making a code path faster by skipping required work or validation.",
        "Claiming speed improvement without baseline/after evidence or accepted waiver.",
        "Moving cost to retries, background work, or another role without measuring it."
      ]
    }
  elsif type.include?("ux") || type.include?("workflow")
    {
      "user_problem" => "The user-visible path is confusing, slow to recover from, or lacks actionable feedback.",
      "desired_property" => "The user path is clearer, more recoverable, and easier to verify from the interface or artifact.",
      "measurable_thresholds" => [
        "A real or representative user path demonstrates the improved state, error, or recovery behavior.",
        "Tester evidence includes user-visible output, screenshot, transcript, or artifact when applicable.",
        "Failure and loading states do not create ambiguous or contradictory UI."
      ],
      "invalid_completions" => [
        "Only changing layout or text without improving the user path.",
        "Only proving API success while the user-visible state remains ambiguous.",
        "Leaving stale, late, or failed states unrecoverable."
      ]
    }
  else
    {
      "user_problem" => "The current behavior, structure, or workflow creates a concrete maintenance, reliability, or user problem.",
      "desired_property" => "The completed task changes the system property that caused the problem, not only the surface action.",
      "measurable_thresholds" => [
        "Acceptance evidence demonstrates the desired property rather than only showing that code changed.",
        "Reviewer can explain why the original problem is reduced or closed.",
        "Known gaps are explicit and do not cover required acceptance."
      ],
      "invalid_completions" => [
        "Completing the requested action while the original problem remains.",
        "Only proving that existing tests pass without evidence for the quality outcome.",
        "Using a workaround, fallback, or manual artifact to mask an unclosed implementation path."
      ]
    }
  end
end

def improvement_task_type?(task_type)
  type = task_type.to_s.downcase
  %w[improvement refactor split docs documentation performance speed latency ux workflow reliability architecture].any? { |token| type.include?(token) }
end

def default_invalid_completion_guards(task_type)
  template = quality_outcome_template(task_type)
  completions = template["invalid_completions"] || []
  completions.each_with_index.map do |completion, index|
    {
      "id" => "guard_#{index + 1}",
      "description" => completion,
      "evidence_required" => "Reviewer must explicitly address whether this invalid completion pattern was avoided."
    }
  end
end

def default_review_strategy(task_type = nil)
  minimum = design_task?(task_type) ? "implementation_readiness" : "outcome_quality"
  {
    "required_questions" => %w[outcome counterexamples evidence_sufficiency residual_risk],
    "entrypoints" => ["quality_outcome", "acceptance", "changed_files", "evidence"],
    "minimum_evidence_level" => minimum,
    "suggested_checks" => [
      "Outcome: does the change satisfy the quality_outcome, not just the requested action?",
      "Behavior: are required user, CLI, or runtime behaviors correct and fail-closed?",
      "Structure: did the change reduce coupling, duplicate truth, or future change cost?",
      "Evidence: do tests, commands, artifacts, or reports prove the outcome?",
      "Residual risk: are untested paths explicit and acceptable?",
      "Evidence level: does the review/test report state mechanical_check, outcome_quality, or implementation_readiness?",
      "Rule application: does the report explain which runtime rules were applied, not only read?",
      "Evidence boundary: are confirmed, assumed, and missing evidence listed separately?"
    ],
    "runtime_checks" => [
      "Inspect latest structured review/test evidence before done.",
      "Check aggregate evidence verdict and required gates."
    ],
    "required_capabilities" => ["review.submit"],
    "failure_modes" => [
      "Review only checks that tests passed.",
      "Review ignores empty or action-only quality_outcome.",
      "Review accepts local pass while source contract or traceability remains uncovered.",
      "Mechanical checks are reported as outcome quality.",
      "Public rule files are read but not applied to this task's judgment."
    ]
  }
end

def default_test_strategy(task_type, implementation_authority = nil)
  return nil unless test_task?(task_type, implementation_authority)

  {
    "minimum_evidence_level" => "real_path_test",
    "required_capabilities" => ["test.submit"]
  }
end

def design_task?(task_type)
  type = task_type.to_s.downcase
  type.include?("design") || type.include?("analysis")
end

def coding_task?(task_type)
  task_type.to_s.downcase.include?("coding")
end

def decomposition_task?(task_type)
  type = task_type.to_s.downcase
  type.include?("decomposition") || type.include?("parent")
end

def test_task?(task_type, implementation_authority = nil)
  implementation_authority.to_s == "tester" || task_type.to_s.downcase.include?("test")
end

def quality_measurement_task?(task_type)
  type = task_type.to_s.downcase
  %w[performance speed latency ux workflow quality eval llm measurement].any? { |token| type.include?(token) }
end

def default_test_level(task_type, implementation_authority = nil)
  return "repo_regression" if test_task?(task_type, implementation_authority)
  return "repo_regression" unless default_gates_for_new_task(task_type, implementation_authority).none? { |gate| gate["kind"] == "test" }

  "not_applicable"
end

def default_design_lifecycle(task_type)
  {
    "enabled" => design_task?(task_type),
    "phases" => ["drafting", "review_requested", "changes_requested", "user_confirmed", "coding_ready"],
    "current_phase" => design_task?(task_type) ? "drafting" : "",
    "user_confirmation_required" => true,
    "coding_requires_confirmed_design" => true
  }
end

def default_design_reference(task_type)
  {
    "required_for_coding" => coding_task?(task_type),
    "artifact" => "",
    "confirmation_evidence" => "",
    "status" => coding_task?(task_type) ? "unconfirmed" : "not_applicable"
  }
end

def default_implementation_plan(task_type)
  {
    "required" => decomposition_task?(task_type),
    "path" => "",
    "summary" => ""
  }
end

def default_decomposition(task_type)
  {
    "parent_task" => "",
    "child_slices" => [],
    "aggregate_outcome_metrics" => [],
    "stop_conditions" => [],
    "replanning_path" => decomposition_task?(task_type) ? "Return to design review before continuing child slices when parent metrics change." : ""
  }
end

def default_final_aggregate_audit(task_type)
  {
    "required" => decomposition_task?(task_type),
    "checks" => decomposition_task?(task_type) ? [
      "Parent quality_outcome remains satisfied after child slices.",
      "Child slices cover the implementation_plan.",
      "Aggregate outcome metrics have evidence beyond individual child pass records."
    ] : []
  }
end

def default_test_environment(task_type, implementation_authority = nil)
  required = test_task?(task_type, implementation_authority)
  {
    "required" => required,
    "environment" => required ? "Record OS/runtime/service versions or CI/browser/device identity." : "",
    "test_tab_or_pane" => required ? "Record tester pane, browser tab, CI job, or not_applicable reason." : "",
    "server_owner" => required ? "Record owner of any server/process under test." : "",
    "browser_owner" => required ? "Record browser/session owner or not_applicable reason." : "",
    "cleanup_hook" => required ? "Record cleanup command/hook or not_applicable reason." : "",
    "artifact_cleanup" => required ? "Record artifact retention/cleanup path or policy." : "",
    "duration_budget" => required ? "Record expected max duration or not_applicable reason." : "",
    "resource_budget" => required ? "Record process/browser/resource budget or not_applicable reason." : ""
  }
end

def default_quality_measurement(task_type)
  required = quality_measurement_task?(task_type)
  {
    "required" => required,
    "baseline_required" => required,
    "after_required" => required,
    "metrics" => required ? ["baseline metric", "after metric", "quality or UX acceptance metric"] : [],
    "waiver_policy" => required ? "If baseline/after cannot be collected, record an explicit waiver with replacement evidence and risk." : ""
  }
end

def default_parent_goal(task_type)
  is_decomp = decomposition_task?(task_type)
  {
    "required" => is_decomp,
    "id" => "",
    "objective" => is_decomp ? "Describe the parent objective this decomposition serves." : "",
    "done_criteria" => is_decomp ? [
      "All child slices are done and pass their gates.",
      "Aggregate outcome evidence covers every done criterion."
    ] : [],
    "non_goals" => []
  }
end

def default_parent_goal_status(task_type)
  is_decomp = decomposition_task?(task_type)
  {
    "state" => is_decomp ? "parent_in_progress" : "not_applicable",
    "active_slice" => "",
    "done_criteria_status" => [],
    "remaining_blockers" => [],
    "required_gates" => {},
    "user_next_action" => {
      "default" => is_decomp ? "update_parent_goal_status" : "not_applicable",
      "options" => [],
      "waiting_on" => "",
      "blocked_by" => "",
      "do_not_do" => []
    }
  }
end

def role_for_instance(instances, roles, instance_key)
  role = role_for_instance_config(instances, roles, instance_key)
  usage_error("Unknown Orbit instance #{instance_key.inspect} or missing role_ref.") unless role
  role
end

def validate_execution_role_pair!(contract, roles, instances, role_field, instance_field)
  role = contract[role_field]
  instance_key = contract[instance_field]
  usage_error("execution_contract.#{role_field} must be a non-empty string.") unless role.is_a?(String) && !role.empty?
  usage_error("execution_contract.#{instance_field} must be a non-empty string.") unless instance_key.is_a?(String) && !instance_key.empty?

  actual_role = role_for_instance(instances, roles, instance_key)
  return if actual_role == role

  usage_error("execution_contract.#{instance_field} #{instance_key.inspect} resolves to role #{actual_role.inspect}, not #{role.inspect}.")
end

def build_task_execution_contract(options)
  roles_config = load_yaml(File.join(Dir.pwd, ".orbit", "roles.yaml"))
  instances_config = load_yaml(File.join(Dir.pwd, ".orbit", "instances.yaml"))
  roles = roles_config["roles"]
  instances = instances_config["instances"]
  usage_error(".orbit/roles.yaml must contain a roles mapping.") unless roles.is_a?(Hash)
  usage_error(".orbit/instances.yaml must contain an instances mapping.") unless instances.is_a?(Hash)

  defaults = if options["operation_mode"]
               operation_defaults_for_mode(options["operation_mode"].to_s)
             else
               roles_config["operation_defaults"]
             end
  usage_error(".orbit/roles.yaml must define operation_defaults; rerun orbit init with --operation-mode solo|team.") unless defaults.is_a?(Hash)

  contract = {
    "owner_role" => defaults["owner_role"],
    "owner_instance" => defaults["owner_instance"],
    "operation_mode" => defaults["operation_mode"],
    "implementation_authority" => defaults["implementation_authority"],
    "assigned_instance" => defaults["assigned_instance"],
    "source" => "project_defaults"
  }

  explicit = %w[operation_mode implementation_authority assigned_instance owner_role owner_instance].any? { |key| options.key?(key) }
  %w[owner_role owner_instance operation_mode implementation_authority assigned_instance].each do |key|
    contract[key] = options[key] if options.key?(key)
  end
  contract["source"] = "explicit_override" if explicit
  usage_error("execution_contract.operation_mode must be solo or team.") unless %w[solo team].include?(contract["operation_mode"].to_s)
  validate_execution_role_pair!(contract, roles, instances, "owner_role", "owner_instance")
  validate_execution_role_pair!(contract, roles, instances, "implementation_authority", "assigned_instance")
  contract
end

def new_task(args)
  options = parse_new_task_args(args)
  template_path = File.join(TEMPLATE_ROOT, "task.yaml")
  task = load_yaml(template_path)

  unless task.is_a?(Hash)
    warn "Task template must contain a mapping: #{template_path}"
    exit 66
  end

  output_path = File.expand_path(options["output"])
  if File.exist?(output_path)
    warn "Task file already exists: #{output_path}"
    warn "Choose a new --output path; new-task does not overwrite existing files."
    exit 73
  end

  task["project"] = options["project"]
  task.delete("target_role")
  task["task_type"] = options["task_type"]
  task["execution_contract"] = build_task_execution_contract(options)
  task["schema_semantics"] = {
    "feature_versions" => ORBIT_FEATURE_VERSIONS.reject { |_k, v| v.nil? }
  }
  implementation_authority = task.dig("execution_contract", "implementation_authority")
  # Slice 11: derive task_risk and project_profile.
  task_risk = derive_task_risk(options["task_type"])
  task["task_risk"] = task_risk
  task["project_profile"] = DEFAULT_PROJECT_PROFILE.dup
  risk_gates = default_gates_for_risk(task_risk["level"], options["task_type"])
  task["gates"] = risk_gates.any? ? risk_gates : default_gates_for_new_task(options["task_type"], implementation_authority)
  task["quality_outcome"] = quality_outcome_template(options["task_type"])
  task["invalid_completion_guards"] = default_invalid_completion_guards(options["task_type"]) if improvement_task_type?(options["task_type"])
  task["review_strategy"] = default_review_strategy(options["task_type"])
  # Apply risk-derived minimum evidence levels to review_strategy.
  risk_review_min = task_risk["minimum_evidence_levels"]["review"]
  task["review_strategy"]["minimum_evidence_level"] = risk_review_min if risk_review_min && !design_task?(options["task_type"])
  test_strat = default_test_strategy(options["task_type"], implementation_authority)
  if test_strat
    risk_test_min = task_risk["minimum_evidence_levels"]["test"]
    test_strat["minimum_evidence_level"] = risk_test_min if risk_test_min
    task["test_strategy"] = test_strat
  end
  task["design_lifecycle"] = default_design_lifecycle(options["task_type"])
  task["design_reference"] = default_design_reference(options["task_type"])
  task["implementation_plan"] = default_implementation_plan(options["task_type"])
  task["decomposition"] = default_decomposition(options["task_type"])
  task["final_aggregate_audit"] = default_final_aggregate_audit(options["task_type"])
  task["test_level"] = default_test_level(options["task_type"], implementation_authority)
  task["test_environment"] = default_test_environment(options["task_type"], implementation_authority)
  task["quality_measurement"] = default_quality_measurement(options["task_type"])
  task["parent_goal"] = default_parent_goal(options["task_type"])
  task["parent_goal_status"] = default_parent_goal_status(options["task_type"])
  task_rule_packs = rule_packs_for_context(implementation_authority, options["task_type"])
  task["rule_packs"] = task_rule_packs unless task_rule_packs.empty?
  task["write_policy_enforcement"] = DEFAULT_WRITE_POLICY_ENFORCEMENT_BY_RISK[task_risk["level"]] || "standard"
  # Slice 13: release risk tasks get a full release_readiness skeleton.
  task["release_readiness"] = default_release_readiness if task_risk["level"] == "release"
  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, YAML.dump(task))

  puts "Created Orbit task:"
  puts "- #{output_path}"
  puts
  puts "Next:"
  puts "- orbit validate --task #{output_path}"
end


require_relative "task_herdr_probe"
require_relative "task_herdr_exec"

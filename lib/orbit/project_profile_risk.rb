# frozen_string_literal: true

# Slice 11: Project profile and task risk level.
#
# Risk levels determine default gates, minimum evidence levels, and validation strictness.
# task_risk.minimum_evidence_levels can only raise the bar; lowering requires a waiver.

ALLOWED_RISK_LEVELS = %w[light standard strict release].freeze
RISK_LEVEL_ORDER = { "light" => 0, "standard" => 1, "strict" => 2, "release" => 3 }.freeze

DEFAULT_PROJECT_PROFILE = {
  "kind" => "unspecified",
  "workflow_traits" => [],
  "default_risk_level" => "standard"
}.freeze

# Default minimum evidence levels per risk level for review and test gates.
DEFAULT_MIN_EVIDENCE_LEVELS_BY_RISK = {
  "light" => { "review" => "mechanical_check", "test" => "mechanical_check" },
  "standard" => { "review" => "outcome_quality", "test" => "real_path_test" },
  "strict" => { "review" => "outcome_quality", "test" => "real_path_test" },
  "release" => { "review" => "outcome_quality", "test" => "real_path_test", "release" => "release_readiness" }
}.freeze

# Default required gates per risk level.
DEFAULT_GATES_BY_RISK = {
  "light" => [],
  "standard" => %w[review test],
  "strict" => %w[review test],
  "release" => %w[review test release]
}.freeze

# Default write_policy_enforcement per risk level.
DEFAULT_WRITE_POLICY_ENFORCEMENT_BY_RISK = {
  "light" => "standard",
  "standard" => "standard",
  "strict" => "strict",
  "release" => "strict"
}.freeze

# Infer a risk level from task type and target role.
def infer_task_risk_level(target_role, task_type)
  type = task_type.to_s.downcase
  return "release" if type.include?("release") || type.include?("deploy") || type.include?("publish")
  return "strict" if type.include?("security") || type.include?("migration") || type.include?("destructive")
  return "light" if type.include?("docs") && !type.include?("rule") && !type.include?("orbit")
  return "light" if %w[typos formatting spelling].any? { |t| type.include?(t) }

  "standard"
end

# Derive task_risk from target_role, task_type, and optional explicit risk level.
def derive_task_risk(target_role, task_type, explicit_level = nil)
  level = explicit_level || infer_task_risk_level(target_role, task_type)
  level = "standard" unless ALLOWED_RISK_LEVELS.include?(level)

  min_levels = DEFAULT_MIN_EVIDENCE_LEVELS_BY_RISK[level] || {}
  gates = DEFAULT_GATES_BY_RISK[level] || %w[review test]
  rationale = case level
              when "light"
                "Light task: docs/formatting change with no runtime behavior impact."
              when "standard"
                "Standard task: behavior change requires review and test gates."
              when "strict"
                "Strict task: high-risk change requires review/test gates and strict write policy."
              when "release"
                "Release task: requires release readiness evidence in addition to review/test gates."
              else
                "Standard risk level."
              end

  {
    "level" => level,
    "rationale" => rationale,
    "required_gates" => gates.each_with_object({}) { |g, memo| memo[g] = true },
    "minimum_evidence_levels" => min_levels
  }
end

# Derive default gates for a task based on risk level and target_role/task_type.
def default_gates_for_risk(risk_level, target_role, task_type)
  gate_kinds = DEFAULT_GATES_BY_RISK[risk_level] || DEFAULT_GATES_BY_RISK["standard"]
  # For reviewer/tester targets, don't add gates (they ARE the gate role).
  return [] if %w[reviewer tester].include?(target_role.to_s)
  return [] if gate_kinds.empty?

  gate_kinds.map do |kind|
    roles = case kind
            when "review", "design_readiness" then ["reviewer"]
            when "test", "release" then ["tester"]
            else ["reviewer"]
            end
    pass_condition = case kind
                     when "review" then "latest review evidence status is pass and no high/medium findings remain"
                     when "test" then "latest test evidence status is pass for required real behavior coverage"
                     when "release" then "release evidence confirms package/CI/remote state checked"
                     else "gate evidence status is pass"
                     end
    {
      "kind" => kind,
      "roles" => roles,
      "required" => true,
      "pass_condition" => pass_condition
    }
  end
end

# Determine if a task has a risk level that requires release readiness evidence.
def release_risk?(task)
  task.is_a?(Hash) && task.dig("task_risk", "level") == "release"
end

# Determine if a task has a risk level of strict or release (requires strict write policy).
def strict_or_higher?(task)
  task.is_a?(Hash) && %w[strict release].include?(task.dig("task_risk", "level"))
end

# Determine if a task is light risk (minimal gates required).
def light_risk?(task)
  task.is_a?(Hash) && task.dig("task_risk", "level") == "light"
end

# Generate risk level summary for audit/handoff output.
def task_risk_summary(task)
  return nil unless task.is_a?(Hash) && task["task_risk"].is_a?(Hash)

  risk = task["task_risk"]
  level = risk["level"] || "standard"
  {
    "level" => level,
    "rationale" => risk["rationale"],
    "required_gates" => risk["required_gates"],
    "minimum_evidence_levels" => risk["minimum_evidence_levels"],
    "write_policy_enforcement" => task["write_policy_enforcement"],
    "project_rules_are_supplement" => true
  }
end

# Check if an evidence level satisfies or exceeds the risk-derived minimum.
def evidence_level_meets_risk_minimum?(actual_level, gate_kind, risk_level)
  return true if risk_level.nil? || !ALLOWED_RISK_LEVELS.include?(risk_level)

  min_levels = DEFAULT_MIN_EVIDENCE_LEVELS_BY_RISK[risk_level] || {}
  minimum = min_levels[gate_kind.to_s]
  return true if minimum.nil?

  actual_level == minimum || evidence_level_satisfies_minimum?(actual_level, minimum)
end

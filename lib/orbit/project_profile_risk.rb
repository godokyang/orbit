# frozen_string_literal: true

# Slice 11: Project profile and task risk level.
#
# Risk levels determine default gates, minimum evidence levels, and validation strictness.
# task_risk.minimum_evidence_levels can only raise the bar; lowering requires a waiver.

ALLOWED_RISK_LEVELS = %w[light standard strict release].freeze
RISK_LEVEL_ORDER = { "light" => 0, "standard" => 1, "strict" => 2, "release" => 3 }.freeze
ALLOWED_CHANGE_SURFACES = %w[internal api user_flow data security release].freeze
ALLOWED_RISK_SINKS = %w[auth money privacy migration destructive concurrency].freeze

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

# Default write_policy_enforcement per risk level.
DEFAULT_WRITE_POLICY_ENFORCEMENT_BY_RISK = {
  "light" => "standard",
  "standard" => "standard",
  "strict" => "strict",
  "release" => "strict"
}.freeze

# Infer a risk level from task type.
def infer_task_risk_level(task_type)
  type = task_type.to_s.downcase
  return "release" if type.include?("release") || type.include?("deploy") || type.include?("publish")
  return "strict" if type.include?("security") || type.include?("migration") || type.include?("destructive")
  return "light" if type.include?("docs") && !type.include?("rule") && !type.include?("orbit")
  return "light" if %w[typos formatting spelling].any? { |t| type.include?(t) }

  "standard"
end

# Derive task_risk from task_type and optional explicit risk level.
def minimum_risk_level_for_contract(task_type, change_surface: "internal", risk_sinks: [])
  task_type_level = infer_task_risk_level(task_type)
  surface_level = case change_surface.to_s
                  when "release" then "release"
                  when "data", "security" then "strict"
                  else "light"
                  end
  sink_level = Array(risk_sinks).empty? ? "light" : "strict"

  [task_type_level, surface_level, sink_level].max_by { |level| RISK_LEVEL_ORDER.fetch(level, 0) }
end

def gate_kinds_for_risk(risk_level, task_type, change_surface: "internal")
  type = task_type.to_s.downcase
  return [] if type.include?("review") || type.include?("test")

  case risk_level
  when "light"
    []
  when "standard"
    %w[api user_flow].include?(change_surface.to_s) ? ["test"] : ["review"]
  when "strict"
    %w[review test]
  when "release"
    %w[review test release]
  else
    %w[review test]
  end
end

def derive_task_risk(task_type, explicit_level = nil, change_surface: "internal", risk_sinks: [])
  minimum_level = minimum_risk_level_for_contract(
    task_type,
    change_surface: change_surface,
    risk_sinks: risk_sinks
  )
  level = explicit_level || minimum_level
  level = "standard" unless ALLOWED_RISK_LEVELS.include?(level)
  level = minimum_level if RISK_LEVEL_ORDER.fetch(level, 0) < RISK_LEVEL_ORDER.fetch(minimum_level, 0)

  min_levels = DEFAULT_MIN_EVIDENCE_LEVELS_BY_RISK[level] || {}
  gates = gate_kinds_for_risk(level, task_type, change_surface: change_surface)
  rationale = case level
              when "light"
                "Light task: docs/formatting change with no runtime behavior impact."
              when "standard"
                gate = gates.first || "independent"
                "Standard task: behavior change requires one risk-matched #{gate} gate."
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

# Derive default gates for a task based on risk level and task_type.
def default_gates_for_risk(risk_level, task_type, change_surface: "internal")
  gate_kinds = gate_kinds_for_risk(risk_level, task_type, change_surface: change_surface)
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

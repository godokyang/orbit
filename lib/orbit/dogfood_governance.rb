# frozen_string_literal: true

require "json"
require "yaml"

# Slice 15: Orbit dogfood and governance.
#
# Provides dogfood case mapping, release readiness dogfood suite enforcement,
# and retrospective task validation. No dedicated CLI; integrated via
# validate/audit/release_readiness.

ALLOWED_DOGFOOD_SUITE_STATUSES = %w[passed failed pending skipped not_run].freeze

# Load the dogfood index from tests/fixtures or a provided path.
def load_dogfood_index(path = nil)
  root = defined?(ORBIT_ROOT) ? ORBIT_ROOT : Dir.pwd
  default_path = File.join(root, "tests", "fixtures", "dogfood-index.json")
  file_path = path || default_path
  return { "dogfood_cases" => [], "governance" => {} } unless File.file?(file_path)

  raw = File.read(file_path)
  begin
    data = file_path.end_with?(".json") ? JSON.parse(raw) : YAML.safe_load(raw)
  rescue JSON::ParserError, Psych::SyntaxError
    return { "dogfood_cases" => [], "governance" => {} }
  end
  return { "dogfood_cases" => [], "governance" => {} } unless data.is_a?(Hash)
  data
end

# Find a dogfood case by id from the index.
def find_dogfood_case(index, case_id)
  cases = index.is_a?(Hash) ? index["dogfood_cases"] : nil
  return nil unless cases.is_a?(Array)
  cases.find { |c| c.is_a?(Hash) && c["id"] == case_id }
end

# Map a failed dogfood case to its source_adjustment and expected behavior.
def map_dogfood_failure(index, case_id)
  dc = find_dogfood_case(index, case_id)
  return nil unless dc
  {
    "case_id" => dc["id"],
    "source_adjustment" => dc["source_adjustment"],
    "expected_outcome" => dc["expected_outcome"],
    "fixture" => dc["fixture"],
    "owner" => dc["owner"],
    "governance" => index.is_a?(Hash) ? index["governance"] : nil
  }.compact
end

# Check if all P0/P1 adjustments have at least one dogfood case.
def dogfood_coverage_complete?(index)
  required_adjustments = %w[P0.1 P0.2 P0.3 P0.4 P0.5 P1.1 P1.2 P1.3 P1.4 P1.5]
  cases = index.is_a?(Hash) ? index["dogfood_cases"] : []
  return false unless cases.is_a?(Array)
  covered = cases.map { |c| c["source_adjustment"] if c.is_a?(Hash) }.compact
  required_adjustments.all? { |adj| covered.include?(adj) }
end

# Validate dogfood_suite block on release_readiness for release-risk tasks.
# Returns blockers if dogfood suite status is missing or not passed (unless waived).
def dogfood_suite_blockers(rr)
  return [] unless rr.is_a?(Hash)
  suite = rr["dogfood_suite"]
  return [{ "source" => "task_file.release_readiness.dogfood_suite", "message" => "Protocol-changing release requires dogfood_suite status; missing." }] unless suite

  if suite.is_a?(Hash)
    status = suite["status"]
    if status.nil? || status.to_s.empty?
      return [{ "source" => "task_file.release_readiness.dogfood_suite.status", "message" => "dogfood_suite.status is missing; release requires dogfood suite verification." }]
    end
    # Validate status enum.
    unless ALLOWED_DOGFOOD_SUITE_STATUSES.include?(status)
      return [{ "source" => "task_file.release_readiness.dogfood_suite.status", "message" => "dogfood_suite.status #{status.inspect} is not one of #{ALLOWED_DOGFOOD_SUITE_STATUSES.join('|')}." }]
    end
    waiver = suite["waiver"]
    if status == "passed"
      return []
    elsif waiver.is_a?(String) && !waiver.strip.empty?
      return [] # Explicit waiver allows release with visible gap.
    else
      return [{ "source" => "task_file.release_readiness.dogfood_suite.status", "message" => "dogfood_suite.status is #{status.inspect}; release requires passed status or explicit waiver." }]
    end
  else
    return [{ "source" => "task_file.release_readiness.dogfood_suite", "message" => "dogfood_suite must be a mapping with status and case_ids." }]
  end
end

# Check if a task type requires done criteria (retrospective/postmortem/lesson).
def requires_done_criteria?(task)
  return false unless task.is_a?(Hash)
  task_type = task["task_type"].to_s.downcase
  %w[retrospective postmortem lesson].any? { |t| task_type.include?(t) }
end

# Summarize dogfood suite status for audit/handoff.
def dogfood_governance_summary(task)
  return nil unless task.is_a?(Hash)
  rr = task["release_readiness"]
  return nil unless rr.is_a?(Hash)
  suite = rr["dogfood_suite"]
  return nil unless suite
  {
    "dogfood_suite" => suite,
    "has_waiver" => suite.is_a?(Hash) && suite["waiver"].is_a?(String) && !suite["waiver"].strip.empty?
  }
end

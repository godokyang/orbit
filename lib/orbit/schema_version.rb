# frozen_string_literal: true

# Minimum scaffolding for protocol-schema-versioning (Slice 14, step 1 in Implementation Order).
#
# Scope: feature-version vocabulary, legacy-warning helpers, compatibility-state detection,
# and prose/structured-verdict conflict detection skeleton.
#
# NOT in scope here:
#   - Full governance (dogfood cases, calibration, multi-user ownership) – Phase 3 remainder.
#   - parent_goal_status, gate_lease feature versions – Phase 1 Slice 3 / Phase 2 Slice 9.
#   - Project-profile risk level – Phase 2 Slice 12.
#
# Global compatibility policy (from development contract):
#   - Old evidence/report lacking new fields → legacy_warning (not hard fail).
#   - Unknown future schema version → explicit compatibility_state output, not silent acceptance.
#   - Structured verdict always wins over prose summary. Summary must derive from structured fields.

# ---------------------------------------------------------------------------
# Current schema versions known to this build
# ---------------------------------------------------------------------------

ORBIT_CURRENT_SCHEMA_VERSIONS = {
  "task" => "orbit-task-v1",
  "evidence" => "orbit-evidence-v1",
  "loop_state" => "orbit-loop-state-v1",
  "audit" => "orbit-audit-v1",
  "validate" => "orbit-validate-v1",
  "tools" => "orbit-tools-v1",
  "tools_doctor" => "orbit-tools-doctor-v1"
}.freeze

# Feature versions track which feature semantics a record was created with.
# nil means the feature is not yet implemented in this build.
#
# evidence_level v1: per-gate-kind semantic families are fully implemented.
# Gate chains: review_quality (mechanical_check, outcome_quality),
# design_readiness (mechanical_check, implementation_readiness),
# test_quality (mechanical_check, real_path_test),
# release_quality (mechanical_check, release_readiness).
# Cross-family substitution is prohibited (Phase 1 Slice 1 complete).
ORBIT_FEATURE_VERSIONS = {
  "evidence_level" => "v1",            # per-gate-kind family chains; cross-family substitution blocked
  "quality_outcome" => "v1",           # quality_outcome_verdict, required review questions (Slice 2 foundation)
  "quality_outcome_guardrails" => "v1", # invalid_completion_guards, required_questions coverage (Slice 2)
  "schema_semantics" => "v1"           # this versioning scaffolding itself (Slice 14 step 1)
  # "parent_goal_status" => nil   # not yet implemented – Phase 1 Slice 3
  # "gate_lease" => nil           # not yet implemented – Phase 2 Slice 9
}.freeze

ORBIT_KNOWN_REPORT_TEMPLATE_VERSIONS = %w[review-report-v1 test-report-v1].freeze

# Expected template version per evidence kind.
# Used to detect kind/template mismatches (e.g. kind: test with review-report-v1).
EXPECTED_REPORT_TEMPLATE_VERSIONS = {
  "review" => "review-report-v1",
  "test" => "test-report-v1"
}.freeze

# ---------------------------------------------------------------------------
# Compatibility state helpers
# ---------------------------------------------------------------------------

# Returns one of: :current, :legacy, :unknown_future
def schema_version_compat(version, kind)
  known = ORBIT_CURRENT_SCHEMA_VERSIONS[kind]
  return :legacy if version.nil? || version.to_s.strip.empty?
  return :current if version == known

  :unknown_future
end

# Free-form version check against an explicit set (e.g. report template versions).
def schema_version_compat_set(version, known_set)
  return :legacy if version.nil? || version.to_s.strip.empty?
  return :current if known_set.include?(version.to_s)

  :unknown_future
end

# ---------------------------------------------------------------------------
# Structured warning/notice builders
# ---------------------------------------------------------------------------

# A legacy_warning indicates the record predates the field being checked.
# It is a warning (not an error) – historical records remain readable.
def schema_legacy_warning_entry(source, message, detail = nil)
  entry = {
    "kind" => "legacy_warning",
    "compatibility_state" => "legacy_missing_field",
    "source" => source,
    "message" => message,
    "action" => "New tasks and evidence should use current templates. Historical records remain readable."
  }
  entry["detail"] = detail if detail
  entry
end

# An unknown_future_version entry indicates a schema we cannot safely process.
# This should block trust – do not silently treat as current semantics.
def schema_unknown_version_entry(source, version_seen, kind_or_known_set)
  known = if kind_or_known_set.is_a?(Array)
            kind_or_known_set
          else
            [ORBIT_CURRENT_SCHEMA_VERSIONS[kind_or_known_set]].compact
          end
  {
    "kind" => "unknown_future_version",
    "compatibility_state" => "unknown_future_version",
    "source" => source,
    "version_seen" => version_seen.to_s,
    "known_versions" => known,
    "message" => "Schema version #{version_seen.to_s.inspect} is not recognized. " \
                 "Do not silently treat as current semantics.",
    "action" => "Upgrade orbit to support this schema version, or treat this record as opaque."
  }
end

# ---------------------------------------------------------------------------
# Prose / structured verdict conflict detection
# ---------------------------------------------------------------------------

# These patterns are intentionally conservative: only trigger on unambiguous signals
# in the first sentence / heading of the summary to avoid false positives.
PROSE_PASS_PATTERNS = /\A\s*(?:PASS(?:ED)?|APPROVED|LGTM|ALL\s+(?:CHECKS?\s+)?(?:PASS(?:ED)?|GREEN))\b/i.freeze
PROSE_FAIL_PATTERNS = /\A\s*(?:FAIL(?:ED)?|BLOCKED|REJECTED?|CANNOT\s+PASS|DOES\s+NOT\s+PASS)\b/i.freeze

# Detect a conflict between the structured verdict (status/verdict field) and the
# prose summary. Returns a conflict entry hash if a conflict is detected, nil otherwise.
# Per the global compatibility policy: structured_verdict_wins.
def detect_prose_structured_conflict(record_or_report)
  return nil unless record_or_report.is_a?(Hash)

  raw_status = record_or_report["status"] || record_or_report["verdict"]
  structured_verdict = case raw_status.to_s.strip.upcase
                       when "PASS", "APPROVED" then "pass"
                       when "FAIL", "CHANGES_REQUESTED" then "fail"
                       when "PARTIAL", "BLOCKED" then "partial"
                       else
                         nil
                       end
  return nil unless structured_verdict

  summary = record_or_report["summary"].to_s.strip
  return nil if summary.empty?

  prose_pass = PROSE_PASS_PATTERNS.match?(summary)
  prose_fail = PROSE_FAIL_PATTERNS.match?(summary)

  conflict_type = if structured_verdict == "fail" && prose_pass && !prose_fail
                    "prose_pass_structured_fail"
                  elsif structured_verdict == "pass" && prose_fail && !prose_pass
                    "prose_fail_structured_pass"
                  end

  return nil unless conflict_type

  {
    "conflict_type" => conflict_type,
    "structured_verdict" => structured_verdict,
    "prose_excerpt" => summary[0, 200],
    "resolution" => "structured_verdict_wins",
    "message" => "Report summary conflicts with structured verdict. " \
                 "Structured verdict (#{structured_verdict.inspect}) takes precedence over prose. " \
                 "Summary must derive from structured fields only."
  }
end

# ---------------------------------------------------------------------------
# Schema version summary (for audit / validate output)
# ---------------------------------------------------------------------------

# Produce a structured schema_version_summary for an evidence manifest.
# Does NOT mutate `result`; callers can add legacy_warnings to result["warnings"]
# and unknown_versions to result["errors"] separately.
def evidence_schema_version_summary(evidence, task = nil)
  return nil unless evidence.is_a?(Hash)

  schema_version = evidence["schema_version"]
  ev_compat = schema_version_compat(schema_version, "evidence")

  legacy_warnings = []
  unknown_versions = []
  prose_conflicts = []

  # Evidence manifest schema version
  case ev_compat
  when :legacy
    legacy_warnings << schema_legacy_warning_entry(
      "evidence_file.schema_version",
      "Evidence manifest is missing schema_version; treating as legacy.",
      "Expected: #{ORBIT_CURRENT_SCHEMA_VERSIONS["evidence"]}"
    )
  when :unknown_future
    unknown_versions << schema_unknown_version_entry("evidence_file.schema_version", schema_version, "evidence")
  end

  # schema_semantics field (introduced by this slice)
  schema_semantics = evidence["schema_semantics"]
  if schema_semantics.nil? && ev_compat == :current
    legacy_warnings << schema_legacy_warning_entry(
      "evidence_file.schema_semantics",
      "Evidence manifest lacks schema_semantics; feature version tracking unavailable. " \
      "This is expected for evidence created before orbit-schema-versioning-v1.",
      "New evidence created with 'orbit evidence init' will include schema_semantics."
    )
  end

  # Scan individual records for prose/structured conflicts
  records = evidence["records"]
  if records.is_a?(Array)
    records.each_with_index do |record, index|
      next unless record.is_a?(Hash)

      conflict = detect_prose_structured_conflict(record)
      next unless conflict

      prose_conflicts << conflict.merge(
        "record_index" => index,
        "source" => "evidence_file.records[#{index}]"
      )
    end
  end

  # Task schema checks (if task provided)
  if task.is_a?(Hash)
    task_schema_version = task["schema_version"]
    task_compat = schema_version_compat(task_schema_version, "task")
    case task_compat
    when :legacy
      legacy_warnings << schema_legacy_warning_entry(
        "task_file.schema_version",
        "Task file is missing schema_version; treating as legacy.",
        "Expected: #{ORBIT_CURRENT_SCHEMA_VERSIONS["task"]}"
      )
    when :unknown_future
      unknown_versions << schema_unknown_version_entry("task_file.schema_version", task_schema_version, "task")
    end

    if task["schema_semantics"].nil? && task_compat == :current
      legacy_warnings << schema_legacy_warning_entry(
        "task_file.schema_semantics",
        "Task file lacks schema_semantics; feature version tracking unavailable. " \
        "Expected for tasks created before orbit-schema-versioning-v1.",
        "New tasks created with 'orbit new-task' will include schema_semantics."
      )
    end
  end

  feature_versions_present = schema_semantics.is_a?(Hash) ? schema_semantics["feature_versions"] : nil

  {
    "schema_version" => schema_version,
    "compatibility_state" => ev_compat.to_s,
    "feature_versions_present" => feature_versions_present,
    "known_feature_versions" => ORBIT_FEATURE_VERSIONS.reject { |_k, v| v.nil? },
    "legacy_warnings" => legacy_warnings,
    "unknown_versions" => unknown_versions,
    "prose_conflicts" => prose_conflicts,
    "known_gaps" => [
      "parent_goal_status feature version not yet implemented (Phase 1 Slice 3).",
      "gate_lease feature version not yet implemented (Phase 2 Slice 9).",
      "Prose/structured conflict detection covers summary field prefix only; full field scan is a known gap."
    ]
  }
end

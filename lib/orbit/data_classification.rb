# frozen_string_literal: true

# Slice 12: Data classification and retention.
#
# Evidence artifacts may contain secrets, user content, prompts, screenshots, logs, or
# local paths. This module provides classification validation, retention enforcement,
# and trust repair summarization.

ALLOWED_DATA_CATEGORIES = %w[
  user_content screenshot prompt log local_path third_party secret
  code test_output config public internal
].freeze

ALLOWED_SENSITIVITY_LEVELS = %w[low medium high secret].freeze
ALLOWED_REDACTION_STATES = %w[none recommended required applied].freeze
ALLOWED_RETENTION_MODES = %w[raw_allowed redacted hash_only short_lived].freeze

# Validate a data_classification mapping on an evidence record.
# Returns normalized classification. Fails on non-Hash input (does not silently drop).
def normalize_data_classification(value, source, kind = nil)
  unless value.is_a?(Hash)
    submit_report_schema_error(
      "#{source}.data_classification",
      "data_classification must be a mapping.",
      expected: "mapping with categories, sensitivity, redaction",
      actual: evidence_value_type(value),
      kind: kind
    )
    return nil
  end
  result = {}
  categories = value["categories"]
  if categories.is_a?(Array)
    invalid = categories.reject { |c| c.is_a?(String) && ALLOWED_DATA_CATEGORIES.include?(c) }
    if invalid.any?
      submit_report_schema_error(
        "#{source}.data_classification.categories",
        "data_classification.categories contains invalid values: #{invalid.inspect}. Allowed: #{ALLOWED_DATA_CATEGORIES.join('|')}.",
        expected: ALLOWED_DATA_CATEGORIES.join("|"),
        actual: invalid.inspect,
        kind: kind
      )
    end
    result["categories"] = categories.select { |c| c.is_a?(String) && ALLOWED_DATA_CATEGORIES.include?(c) }
  end

  sensitivity = value["sensitivity"]
  if sensitivity.is_a?(String) && ALLOWED_SENSITIVITY_LEVELS.include?(sensitivity)
    result["sensitivity"] = sensitivity
  elsif !sensitivity.nil?
    submit_report_schema_error(
      "#{source}.data_classification.sensitivity",
      "data_classification.sensitivity must be one of #{ALLOWED_SENSITIVITY_LEVELS.join('|')}.",
      expected: ALLOWED_SENSITIVITY_LEVELS.join("|"),
      actual: evidence_value_type(sensitivity),
      kind: kind
    )
  end

  redaction = value["redaction"]
  if redaction.is_a?(String) && ALLOWED_REDACTION_STATES.include?(redaction)
    result["redaction"] = redaction
  elsif !redaction.nil?
    submit_report_schema_error(
      "#{source}.data_classification.redaction",
      "data_classification.redaction must be one of #{ALLOWED_REDACTION_STATES.join('|')}.",
      expected: ALLOWED_REDACTION_STATES.join("|"),
      actual: evidence_value_type(redaction),
      kind: kind
    )
  end

  result.empty? ? nil : result
end

# Validate a retention_policy mapping.
def normalize_retention_policy(value, source, kind = nil)
  unless value.is_a?(Hash)
    submit_report_schema_error(
      "#{source}.retention_policy",
      "retention_policy must be a mapping.",
      expected: "mapping with mode, expires_at, user_approved",
      actual: evidence_value_type(value),
      kind: kind
    )
    return nil
  end

  result = {}
  mode = value["mode"]
  if mode.is_a?(String) && ALLOWED_RETENTION_MODES.include?(mode)
    result["mode"] = mode
  elsif !mode.nil?
    submit_report_schema_error(
      "#{source}.retention_policy.mode",
      "retention_policy.mode must be one of #{ALLOWED_RETENTION_MODES.join('|')}.",
      expected: ALLOWED_RETENTION_MODES.join("|"),
      actual: evidence_value_type(mode),
      kind: kind
    )
  end

  expires_at = value["expires_at"]
  if expires_at.is_a?(String) && !expires_at.strip.empty?
    result["expires_at"] = expires_at.strip
  end

  user_approved = value["user_approved"]
  result["user_approved"] = user_approved if [true, false].include?(user_approved)

  result.empty? ? nil : result
end

def normalize_trust_repair(value, source, kind = nil)
  unless value.is_a?(Hash)
    submit_report_schema_error(
      "#{source}.trust_repair",
      "trust_repair must be a mapping.",
      expected: "mapping with incident_id, impact, recovery, prevention",
      actual: evidence_value_type(value),
      kind: kind
    )
    return nil
  end

  result = {}
  %w[incident_id impact recovery prevention follow_up_verification user_confirmation].each do |f|
    v = value[f]
    result[f] = v if v.is_a?(String) && !v.strip.empty?
  end

  result.empty? ? nil : result
end

# Check if a data_classification indicates secret-level content.
def secret_classification?(dc)
  dc.is_a?(Hash) && dc["sensitivity"] == "secret"
end

# Check if a data_classification indicates high or secret sensitivity.
def high_or_secret?(dc)
  dc.is_a?(Hash) && %w[high secret].include?(dc["sensitivity"])
end

# Check if retention mode allows raw content to be retained long-term.
def raw_retention?(rp)
  rp.is_a?(Hash) && rp["mode"] == "raw_allowed"
end

def sensitive_retention_record?(record)
  return false unless record.is_a?(Hash)

  dc = record["data_classification"]
  rp = record["retention_policy"]
  mode = rp.is_a?(Hash) ? rp["mode"] : nil
  secret_classification?(dc) ||
    mode == "hash_only" ||
    mode == "redacted" ||
    (high_or_secret?(dc) && mode != "raw_allowed")
end

def redact_sensitive_record(record, marker = "[redacted: sensitive data classification]")
  return record unless sensitive_retention_record?(record)

  redacted = record.dup
  %w[summary findings coverage artifacts source_report blocked].each do |field|
    redacted.delete(field) if redacted.key?(field)
  end
  redacted["summary"] = marker
  redacted["_redacted_for_retention"] = true
  redacted
end

def redact_aggregate_verdict_for_summary(verdict)
  return verdict unless verdict.is_a?(Hash)

  redacted = verdict.dup
  redacted["latest_record"] = redact_sensitive_record(redacted["latest_record"]) if redacted["latest_record"].is_a?(Hash)
  redacted
end

# Audit data classifications across evidence records.
# Returns findings: warnings for missing retention on sensitive data,
# blocking errors for secret + raw_allowed.
def data_classification_audit(evidence)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  findings = []
  unclassified_screenshots = []

  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)
    dc = record["data_classification"]
    rp = record["retention_policy"]
    source = "evidence_file.records[#{index}]"

    if dc.is_a?(Hash)
      # Secret + raw_allowed is a hard violation.
      if secret_classification?(dc) && (rp.nil? || raw_retention?(rp))
        findings << {
          "source" => "#{source}.retention_policy",
          "severity" => "high",
          "message" => "Secret-classified data with raw_allowed or missing retention_policy cannot retain raw content long-term."
        }
      end

      # High sensitivity without retention_policy is a warning.
      if high_or_secret?(dc) && rp.nil?
        findings << {
          "source" => "#{source}.retention_policy",
          "severity" => "medium",
          "message" => "High/secret sensitivity data lacks retention_policy; raw content may be retained unsafely."
        }
      end

      # Screenshot without classification categories is suspicious.
      cats = dc["categories"]
      if cats.is_a?(Array) && cats.include?("screenshot") && dc["sensitivity"].nil?
        unclassified_screenshots << index
      end
    elsif record["artifacts"].is_a?(Array) && record["artifacts"].any? { |a| a.to_s.match?(/screenshot|\.png|\.jpg|\.jpeg/i) }
      unclassified_screenshots << index unless dc
    end
  end

  unclassified_screenshots.each do |idx|
    findings << {
      "source" => "evidence_file.records[#{idx}].data_classification",
      "severity" => "medium",
      "message" => "Screenshot artifact lacks data_classification; sensitivity and retention may be needed."
    }
  end

  findings
end

# Summarize trust_repair records for handoff/audit output.
def trust_repair_summary(evidence)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  repairs = records.each_with_index.map do |record, index|
    next unless record.is_a?(Hash) && record["trust_repair"].is_a?(Hash)
    tr = record["trust_repair"]
    next unless tr["incident_id"].is_a?(String) && !tr["incident_id"].empty?

    {
      "record_index" => index,
      "incident_id" => tr["incident_id"],
      "impact" => tr["impact"],
      "recovery" => tr["recovery"],
      "prevention" => tr["prevention"],
      "follow_up_verification" => tr["follow_up_verification"],
      "user_confirmation" => tr["user_confirmation"]
    }.compact
  end.compact

  {
    "incidents" => repairs,
    "count" => repairs.length,
    "has_incidents" => !repairs.empty?
  }
end

# Summarize data classifications for audit output (without raw content).
def data_classification_summary(evidence)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  by_sensitivity = {}
  by_category = {}
  retention_modes = {}
  total_classified = 0

  records.each do |record|
    next unless record.is_a?(Hash) && record["data_classification"].is_a?(Hash)
    dc = record["data_classification"]
    total_classified += 1

    sens = dc["sensitivity"]
    by_sensitivity[sens] = (by_sensitivity[sens] || 0) + 1 if sens

    Array(dc["categories"]).each do |cat|
      by_category[cat] = (by_category[cat] || 0) + 1 if cat.is_a?(String) && !cat.empty?
    end

    rp = record["retention_policy"]
    mode = rp.is_a?(Hash) ? rp["mode"] : nil
    retention_modes[mode] = (retention_modes[mode] || 0) + 1 if mode
  end

  {
    "classified_records" => total_classified,
    "by_sensitivity" => by_sensitivity,
    "by_category" => by_category,
    "retention_modes" => retention_modes,
    "has_secret" => (by_sensitivity["secret"] || 0) > 0,
    "has_high_or_secret" => ((by_sensitivity["high"] || 0) + (by_sensitivity["secret"] || 0)) > 0
  }
end

# Filter evidence records for compact summary: omit raw content from
# secret/hash_only/redacted records.
def redact_for_compact(records)
  Array(records).map do |record|
    next record unless record.is_a?(Hash)

    dc = record["data_classification"]
    rp = record["retention_policy"]
    mode = rp.is_a?(Hash) ? rp["mode"] : nil

    redact_sensitive_record(record, "[redacted: data_classification requires hash_only/redacted retention]")
  end
end

def validate_string_array!(value, source, kind: nil)
  unless value.is_a?(Array)
    submit_report_schema_error(
      source,
      "#{source} must be a list.",
      expected: "list of non-empty strings",
      actual: evidence_value_type(value),
      kind: kind
    )
  end
  unless value.all? { |item| item.is_a?(String) && !item.strip.empty? }
    submit_report_schema_error(
      source,
      "#{source} must be a list of non-empty strings.",
      expected: "list of non-empty strings, for example: findings: [\"[medium][id] summary\"]",
      actual: evidence_value_type(value),
      kind: kind
    )
  end
  value
end

def finding_severity_from_string(value)
  match = value.to_s.downcase.match(/\[(high|medium|low|advisory)\]/)
  match ? match[1] : nil
end

def validate_structured_finding!(finding, source, kind: nil)
  unless finding.is_a?(Hash)
    submit_report_schema_error(
      source,
      "#{source} must be a string finding or a mapping finding.",
      expected: "non-empty string or mapping with severity and summary",
      actual: evidence_value_type(finding),
      kind: kind
    )
  end

  severity = finding["severity"]
  unless %w[high medium low advisory].include?(severity)
    submit_report_schema_error(
      "#{source}.severity",
      "#{source}.severity must be one of high|medium|low|advisory.",
      expected: "high|medium|low|advisory",
      actual: evidence_value_type(severity),
      kind: kind
    )
  end

  summary = finding["summary"]
  unless summary.is_a?(String) && !summary.strip.empty?
    submit_report_schema_error(
      "#{source}.summary",
      "#{source}.summary must be a non-empty string.",
      expected: "non-empty string",
      actual: evidence_value_type(summary),
      kind: kind
    )
  end

  return finding unless %w[high medium].include?(severity)

  REQUIRED_FINDING_DETAIL_FIELDS.each do |field|
    value = finding[field]
    next if value.is_a?(String) && !value.strip.empty?

    submit_report_schema_error(
      "#{source}.#{field}",
      "High/medium findings must include #{field}.",
      expected: "non-empty string",
      actual: evidence_value_type(value),
      kind: kind
    )
  end

  finding
end

def validate_findings_array!(value, source, kind: nil)
  unless value.is_a?(Array)
    submit_report_schema_error(
      source,
      "#{source} must be a list.",
      expected: "list of non-empty strings or finding mappings",
      actual: evidence_value_type(value),
      kind: kind
    )
  end

  value.each_with_index do |finding, index|
    item_source = "#{source}[#{index}]"
    if finding.is_a?(String)
      if finding.strip.empty?
        submit_report_schema_error(
          item_source,
          "#{item_source} must be non-empty.",
          expected: "non-empty string or finding mapping",
          actual: evidence_value_type(finding),
          kind: kind
        )
      end

      severity = finding_severity_from_string(finding)
      if %w[high medium].include?(severity)
        submit_report_schema_error(
          item_source,
          "High/medium findings must be mappings with symptom, source, consequence, and remedy.",
          expected: "mapping with severity, summary, symptom, source, consequence, remedy",
          actual: "string finding tagged #{severity}",
          kind: kind
        )
      end
    else
      validate_structured_finding!(finding, item_source, kind: kind)
    end
  end

  value
end

def validate_review_quality_outcome_verdict!(report, status, source, kind: nil)
  value = report["quality_outcome_verdict"]
  unless value.is_a?(String) && !value.strip.empty?
    submit_report_schema_error(
      "#{source}.quality_outcome_verdict",
      "#{source}.quality_outcome_verdict must be a non-empty string.",
      expected: ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS.join("|"),
      actual: evidence_value_type(value),
      kind: kind
    )
  end

  verdict = value.strip
  unless ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS.include?(verdict)
    submit_report_schema_error(
      "#{source}.quality_outcome_verdict",
      "#{source}.quality_outcome_verdict must be one of #{ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS.join("|")}.",
      expected: ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS.join("|"),
      actual: evidence_value_type(value),
      kind: kind
    )
  end

  if status == "pass" && verdict != "pass"
    submit_report_schema_error(
      "#{source}.quality_outcome_verdict",
      "Review PASS requires quality_outcome_verdict: pass.",
      expected: "pass",
      actual: verdict,
      kind: kind
    )
  end

  verdict
end

def validate_test_level!(value, source, kind: nil, pass_required: false)
  unless value.is_a?(String) && !value.strip.empty?
    submit_report_schema_error(
      source,
      "#{source} must be a non-empty string.",
      expected: ALLOWED_TEST_LEVELS.join("|"),
      actual: evidence_value_type(value),
      kind: kind
    )
  end

  level = value.strip
  unless ALLOWED_TEST_LEVELS.include?(level)
    submit_report_schema_error(
      source,
      "#{source} must be one of #{ALLOWED_TEST_LEVELS.join("|")}.",
      expected: ALLOWED_TEST_LEVELS.join("|"),
      actual: level,
      kind: kind
    )
  end

  if pass_required && level == "not_applicable"
    submit_report_schema_error(
      source,
      "Test PASS requires an executable test_level, not not_applicable.",
      expected: (ALLOWED_TEST_LEVELS - ["not_applicable"]).join("|"),
      actual: level,
      kind: kind
    )
  end

  level
end

def validate_evidence_level!(value, source, kind: nil, pass_required: false)
  unless value.is_a?(String) && !value.strip.empty?
    submit_report_schema_error(
      source,
      "#{source} must be a non-empty string.",
      expected: ALLOWED_EVIDENCE_LEVELS.join("|"),
      actual: evidence_value_type(value),
      kind: kind
    ) if pass_required
    return nil
  end

  level = value.strip
  unless ALLOWED_EVIDENCE_LEVELS.include?(level)
    submit_report_schema_error(
      source,
      "#{source} must be one of #{ALLOWED_EVIDENCE_LEVELS.join("|")}.",
      expected: ALLOWED_EVIDENCE_LEVELS.join("|"),
      actual: level,
      kind: kind
    )
  end
  level
end

def validate_rule_application!(value, source, kind: nil, pass_required: false)
  unless value.is_a?(Hash)
    submit_report_schema_error(
      source,
      "#{source} must be a mapping.",
      expected: "mapping with required_rule_files_read, applied_checks, not_applicable",
      actual: evidence_value_type(value),
      kind: kind
    ) if pass_required || !value.nil?
    return nil
  end

  required_files = validate_string_array!(value["required_rule_files_read"], "#{source}.required_rule_files_read", kind: kind)
  applied_checks = value["applied_checks"]
  unless applied_checks.is_a?(Array)
    submit_report_schema_error(
      "#{source}.applied_checks",
      "#{source}.applied_checks must be a list.",
      expected: "list of mappings with id, verdict, evidence",
      actual: evidence_value_type(applied_checks),
      kind: kind
    )
  end
  applied_checks.each_with_index do |check, index|
    item_source = "#{source}.applied_checks[#{index}]"
    unless check.is_a?(Hash)
      submit_report_schema_error(
        item_source,
        "#{item_source} must be a mapping.",
        expected: "mapping with id, verdict, evidence",
        actual: evidence_value_type(check),
        kind: kind
      )
    end
    report_string!(check, "id", item_source, kind: kind)
    verdict = report_string!(check, "verdict", item_source, kind: kind)
    unless ALLOWED_RULE_APPLICATION_VERDICTS.include?(verdict)
      submit_report_schema_error(
        "#{item_source}.verdict",
        "#{item_source}.verdict must be one of #{ALLOWED_RULE_APPLICATION_VERDICTS.join("|")}.",
        expected: ALLOWED_RULE_APPLICATION_VERDICTS.join("|"),
        actual: verdict,
        kind: kind
      )
    end
    report_string!(check, "evidence", item_source, kind: kind)
  end

  not_applicable = value["not_applicable"]
  unless not_applicable.is_a?(Array)
    submit_report_schema_error(
      "#{source}.not_applicable",
      "#{source}.not_applicable must be a list.",
      expected: "list of mappings with id and reason",
      actual: evidence_value_type(not_applicable),
      kind: kind
    )
  end
  not_applicable.each_with_index do |item, index|
    item_source = "#{source}.not_applicable[#{index}]"
    unless item.is_a?(Hash)
      submit_report_schema_error(
        item_source,
        "#{item_source} must be a mapping.",
        expected: "mapping with id and reason",
        actual: evidence_value_type(item),
        kind: kind
      )
    end
    report_string!(item, "id", item_source, kind: kind)
    report_string!(item, "reason", item_source, kind: kind)
  end

  if pass_required && applied_checks.empty? && not_applicable.empty?
    submit_report_schema_error(
      source,
      "PASS report rule_application must include at least one applied check or not_applicable entry.",
      expected: "non-empty applied_checks or not_applicable",
      actual: "empty applied_checks and empty not_applicable",
      kind: kind
    )
  end

  {
    "required_rule_files_read" => required_files,
    "applied_checks" => applied_checks,
    "not_applicable" => not_applicable
  }
end

def validate_quality_question_answers!(value, source, kind: nil, pass_required: false)
  unless value.is_a?(Array)
    submit_report_schema_error(
      source,
      "#{source} must be a list.",
      expected: "list of mappings with id, verdict, evidence",
      actual: evidence_value_type(value),
      kind: kind
    ) if pass_required || !value.nil?
    return nil
  end
  if pass_required && value.empty?
    submit_report_schema_error(
      source,
      "Review PASS requires at least one quality question answer.",
      expected: "non-empty list",
      actual: "empty list",
      kind: kind
    )
  end
  value.each_with_index do |answer, index|
    item_source = "#{source}[#{index}]"
    unless answer.is_a?(Hash)
      submit_report_schema_error(
        item_source,
        "#{item_source} must be a mapping.",
        expected: "mapping with id, verdict, evidence",
        actual: evidence_value_type(answer),
        kind: kind
      )
    end
    report_string!(answer, "id", item_source, kind: kind)
    verdict = report_string!(answer, "verdict", item_source, kind: kind)
    unless ALLOWED_QUALITY_QUESTION_VERDICTS.include?(verdict)
      submit_report_schema_error(
        "#{item_source}.verdict",
        "#{item_source}.verdict must be one of #{ALLOWED_QUALITY_QUESTION_VERDICTS.join("|")}.",
        expected: ALLOWED_QUALITY_QUESTION_VERDICTS.join("|"),
        actual: verdict,
        kind: kind
      )
    end
    report_string!(answer, "evidence", item_source, kind: kind)
  end
  value
end

def validate_string_list_field!(report, field, source, kind: nil, pass_required: false, non_empty: false)
  value = report[field]
  unless value.is_a?(Array)
    submit_report_schema_error(
      "#{source}.#{field}",
      "#{source}.#{field} must be a list.",
      expected: "list of non-empty strings",
      actual: evidence_value_type(value),
      kind: kind
    ) if pass_required || report.key?(field)
    return nil
  end
  if non_empty && value.empty?
    submit_report_schema_error(
      "#{source}.#{field}",
      "#{source}.#{field} must not be empty.",
      expected: "non-empty list of strings",
      actual: "empty list",
      kind: kind
    )
  end
  validate_string_array!(value, "#{source}.#{field}", kind: kind)
end

def validate_implementation_readiness_verdict!(value, source, evidence_level:, kind: nil, pass_required: false)
  unless value.is_a?(String) && !value.strip.empty?
    submit_report_schema_error(
      source,
      "#{source} must be a non-empty string.",
      expected: ALLOWED_IMPLEMENTATION_READINESS_VERDICTS.join("|"),
      actual: evidence_value_type(value),
      kind: kind
    ) if pass_required || evidence_level == "implementation_readiness"
    return nil
  end

  verdict = value.strip
  unless ALLOWED_IMPLEMENTATION_READINESS_VERDICTS.include?(verdict)
    submit_report_schema_error(
      source,
      "#{source} must be one of #{ALLOWED_IMPLEMENTATION_READINESS_VERDICTS.join("|")}.",
      expected: ALLOWED_IMPLEMENTATION_READINESS_VERDICTS.join("|"),
      actual: verdict,
      kind: kind
    )
  end
  if evidence_level == "implementation_readiness" && verdict != "pass"
    submit_report_schema_error(
      source,
      "Review PASS with evidence_level implementation_readiness requires implementation_readiness_verdict: pass.",
      expected: "pass",
      actual: verdict,
      kind: kind
    )
  end
  verdict
end

def validate_blocked_submit_detail!(value, source, kind: nil)
  unless value.is_a?(Hash)
    submit_report_schema_error(
      source,
      "#{source} must be a mapping.",
      expected: "mapping with reason, next_step, and owner",
      actual: evidence_value_type(value),
      kind: kind
    )
  end
  %w[reason next_step owner].each do |field|
    field_value = value[field]
    unless field_value.is_a?(String) && !field_value.strip.empty?
      submit_report_schema_error(
        "#{source}.#{field}",
        "#{source}.#{field} must be a non-empty string.",
        expected: "non-empty string",
        actual: evidence_value_type(field_value),
        kind: kind
      )
    end
  end
  value
end

def report_string!(report, field, source, kind: nil)
  value = report[field]
  unless value.is_a?(String) && !value.strip.empty?
    submit_report_schema_error(
      "#{source}.#{field}",
      "#{source}.#{field} must be a non-empty string.",
      expected: "non-empty string",
      actual: evidence_value_type(value),
      kind: kind
    )
  end
  value.strip
end

def structured_submit_kind(report_path, report)
  kind = report["kind"]
  kind = infer_report_kind(report_path, report) if kind.to_s.empty?
  unless STRUCTURED_SUBMIT_KINDS.include?(kind)
    submit_report_schema_error(
      "submit_report.kind",
      "Structured submit report kind must be one of #{STRUCTURED_SUBMIT_KINDS.join("|")}.",
      expected: STRUCTURED_SUBMIT_KINDS.join("|"),
      actual: evidence_value_type(kind),
      kind: kind
    )
  end
  kind
end

def structured_submit_status(report, kind)
  status = normalize_report_status(report["verdict"] || report["status"])
  unless ALLOWED_EVIDENCE_STATUSES.include?(status)
    submit_report_schema_error(
      "submit_report.verdict",
      "Structured submit report verdict must be one of #{ALLOWED_EVIDENCE_STATUSES.join("|")}.",
      expected: ALLOWED_EVIDENCE_STATUSES.join("|"),
      actual: evidence_value_type(report["verdict"] || report["status"]),
      kind: kind
    )
  end
  status
end

def validate_structured_submit_report!(report_path, report)
  unless report.is_a?(Hash)
    submit_report_schema_error(
      "submit_report",
      "Structured submit report must be a mapping.",
      expected: "mapping with kind, verdict, summary, source_message_id, findings, coverage, artifacts",
      actual: evidence_value_type(report),
      kind: nil
    )
  end
  kind = structured_submit_kind(report_path, report)
  status = structured_submit_status(report, kind)
  summary = report_string!(report, "summary", "submit_report", kind: kind)
  source_message_id = report_string!(report, "source_message_id", "submit_report", kind: kind)
  findings = validate_findings_array!(report["findings"] || [], "submit_report.findings", kind: kind)
  coverage = validate_string_array!(report["coverage"], "submit_report.coverage", kind: kind)
  artifacts = validate_string_array!(report["artifacts"], "submit_report.artifacts", kind: kind)
  validate_blocked_submit_detail!(report["blocked"], "submit_report.blocked", kind: kind) if report.key?("blocked")

  # Schema versioning: validate report_template_version.
  # - Missing (legacy report): non-blocking, record legacy_warning in source_report_semantics.
  # - Known but wrong kind (e.g. review-report-v1 for kind: test): blocking kind mismatch.
  # - Unknown future version: blocking – cannot safely assume current parsing semantics.
  report_template_version = report["report_template_version"]
  template_compat = schema_version_compat_set(report_template_version, ORBIT_KNOWN_REPORT_TEMPLATE_VERSIONS)
  if template_compat == :unknown_future
    submit_report_schema_error(
      "submit_report.report_template_version",
      "Report report_template_version #{report_template_version.inspect} is not recognized. " \
      "Unknown future template versions cannot be safely processed.",
      expected: ORBIT_KNOWN_REPORT_TEMPLATE_VERSIONS.join("|"),
      actual: report_template_version,
      kind: kind
    )
  end
  if template_compat == :current
    expected_for_kind = EXPECTED_REPORT_TEMPLATE_VERSIONS[kind]
    if expected_for_kind && report_template_version != expected_for_kind
      submit_report_schema_error(
        "submit_report.report_template_version",
        "Report report_template_version #{report_template_version.inspect} does not match " \
        "expected template for kind #{kind.inspect}.",
        expected: expected_for_kind,
        actual: report_template_version,
        kind: kind
      )
    end
  end
  source_report_semantics = { "compatibility_state" => template_compat.to_s }
  source_report_semantics["report_template_version"] = report_template_version if report_template_version
  if template_compat == :legacy
    source_report_semantics["legacy_warnings"] = [
      schema_legacy_warning_entry(
        "submit_report.report_template_version",
        "Report is missing report_template_version; treating as legacy report created before schema versioning.",
        "New reports from updated templates include report_template_version."
      )
    ]
  end
  report_schema_semantics = report["schema_semantics"]
  if report_schema_semantics.is_a?(Hash) && report_schema_semantics["feature_versions"].is_a?(Hash)
    source_report_semantics["feature_versions"] = report_schema_semantics["feature_versions"]
  elsif template_compat == :current
    # Report uses a known template version but is missing schema_semantics; feature_versions unverifiable.
    source_report_semantics["known_gaps"] = [
      "Report uses a known template version (#{report_template_version.inspect}) but is missing " \
      "schema_semantics; feature_versions cannot be verified from this report."
    ]
  end

  extra = {}
  extra["source_report_semantics"] = source_report_semantics
  pass_required = status == "pass"
  if pass_required || report.key?("evidence_level")
    extra["evidence_level"] = validate_evidence_level!(report["evidence_level"], "submit_report.evidence_level", kind: kind, pass_required: pass_required)
  end
  if pass_required || report.key?("rule_application")
    extra["rule_application"] = validate_rule_application!(report["rule_application"], "submit_report.rule_application", kind: kind, pass_required: pass_required)
  end
  %w[confirmed assumed missing].each do |field|
    if pass_required || report.key?(field)
      extra[field] = validate_string_list_field!(report, field, "submit_report", kind: kind, pass_required: pass_required, non_empty: field == "confirmed" && pass_required)
    end
  end
  if pass_required || report.key?("residual_risk")
    residual_risk = report["residual_risk"]
    if pass_required && (residual_risk.nil? || !residual_risk.is_a?(String) || residual_risk.strip.empty?)
      submit_report_schema_error(
        "submit_report.residual_risk",
        "Structured PASS evidence requires residual_risk: a non-empty string describing untested paths or acceptable residual risk.",
        expected: "non-empty string",
        actual: evidence_value_type(residual_risk),
        kind: kind
      )
    end
    extra["residual_risk"] = residual_risk.strip if residual_risk.is_a?(String) && !residual_risk.strip.empty?
  end
  if kind == "review"
    extra["quality_outcome_verdict"] = validate_review_quality_outcome_verdict!(report, status, "submit_report", kind: kind)
    if pass_required || report.key?("quality_outcome_reasoning")
      extra["quality_outcome_reasoning"] = report_string!(report, "quality_outcome_reasoning", "submit_report", kind: kind)
    end
    if pass_required || report.key?("quality_question_answers")
      extra["quality_question_answers"] = validate_quality_question_answers!(report["quality_question_answers"], "submit_report.quality_question_answers", kind: kind, pass_required: pass_required)
    end
    if pass_required || report.key?("counterexample_cases")
      extra["counterexample_cases"] = validate_string_list_field!(report, "counterexample_cases", "submit_report", kind: kind, pass_required: pass_required, non_empty: pass_required)
    end
    if pass_required || report.key?("implementation_readiness_verdict")
      extra["implementation_readiness_verdict"] = validate_implementation_readiness_verdict!(
        report["implementation_readiness_verdict"],
        "submit_report.implementation_readiness_verdict",
        evidence_level: extra["evidence_level"],
        kind: kind,
        pass_required: pass_required
      )
    end
  elsif kind == "test"
    if status == "pass"
      extra["test_level"] = validate_test_level!(report["test_level"], "submit_report.test_level", kind: kind, pass_required: true)
    elsif report.key?("test_level")
      extra["test_level"] = validate_test_level!(report["test_level"], "submit_report.test_level", kind: kind)
    end
  end

  [kind, status, summary, source_message_id, findings, coverage, artifacts, extra]
end

def evidence_submit(options)
  path = File.expand_path(options["file"])
  report_path, report = load_report_for_evidence(options["report"])

  kind, status, summary, source_message_id, findings, coverage, artifacts, extra = validate_structured_submit_report!(report_path, report)
  identity = require_evidence_submit_capability!(kind)
  record = {
    "kind" => kind,
    "status" => status,
    "summary" => summary,
    "created_at" => Time.now.utc.iso8601,
    "structured_submit" => true,
    "source_message_id" => source_message_id,
    "source_report" => report_path,
    "findings" => findings,
    "coverage" => coverage,
    "artifacts" => artifacts
  }
  extra.each { |field, value| record[field] = value unless value.nil? } if extra.is_a?(Hash)
  %w[test_environment quality_measurement duration resource_usage ux_quality artifact_quality cleanup_status].each do |field|
    record[field] = report[field] if report.key?(field)
  end
  record["blocked"] = report["blocked"] if report.key?("blocked")
  snapshot = evidence_identity_snapshot(identity)
  record["identity"] = snapshot if snapshot
  validate_evidence_record_shape!(record, "Evidence record")

  updated_manifest = update_evidence_manifest(path) do |manifest|
    records = ensure_evidence_records!(manifest)
    records << record
    recompute_evidence_verdict!(manifest)
    manifest
  end

  puts JSON.pretty_generate({
    "schema_version" => "orbit-evidence-submit-v1",
    "file" => path,
    "report" => report_path,
    "record" => record,
    "verdict" => updated_manifest["verdict"]
  })
end

def validate_waiver_report!(waiver)
  evidence_error("Waiver report must be a mapping.") unless waiver.is_a?(Hash)
  normalized = {
    "owner" => report_string!(waiver, "owner", "waiver"),
    "scope" => report_string!(waiver, "scope", "waiver"),
    "reason" => report_string!(waiver, "reason", "waiver"),
    "risk" => report_string!(waiver, "risk", "waiver"),
    "replacement_evidence" => report_string!(waiver, "replacement_evidence", "waiver"),
    "expiry" => report_string!(waiver, "expiry", "waiver"),
    "revoked_by_user_requirement" => waiver["revoked_by_user_requirement"]
  }
  unless [true, false].include?(normalized["revoked_by_user_requirement"])
    evidence_error("waiver.revoked_by_user_requirement must be true or false.")
  end
  normalized
end

def evidence_waive(options)
  path = File.expand_path(options["file"])
  waiver_path, waiver_report = load_report_for_evidence(options["waiver"])

  waiver = validate_waiver_report!(waiver_report)
  waiver["source_report"] = waiver_path
  waiver["created_at"] = Time.now.utc.iso8601

  waiver_record = {
    "kind" => "waiver",
    "status" => waiver["revoked_by_user_requirement"] ? "invalid" : "partial",
    "summary" => "Waiver recorded for #{waiver["scope"]}: #{waiver["risk"]}",
    "created_at" => waiver["created_at"],
    "source_report" => waiver_path
  }

  updated_manifest = update_evidence_manifest(path) do |manifest|
    waivers = ensure_evidence_waivers!(manifest)
    waivers << waiver
    records = ensure_evidence_records!(manifest)
    records << waiver_record
    recompute_evidence_verdict!(manifest)
    manifest
  end

  puts JSON.pretty_generate({
    "schema_version" => "orbit-evidence-waiver-v1",
    "file" => path,
    "waiver" => waiver,
    "verdict" => updated_manifest["verdict"]
  })
end

def evidence_show(options)
  path = File.expand_path(options["file"])
  manifest = load_evidence_manifest(path)
  ensure_evidence_records!(manifest) if manifest.key?("records")
  puts JSON.pretty_generate(manifest)
end

def load_rule_resolution_manifest(path)
  manifest = load_yaml(path)
  evidence_error("#{path} must contain a mapping.") unless manifest.is_a?(Hash)
  evidence_error("#{path} must be orbit-rule-resolution-v1.") unless manifest["schema_version"] == "orbit-rule-resolution-v1"
  manifest
rescue RuntimeError => e
  evidence_error(e.message)
end

def evidence_attach_rule(options)
  path = File.expand_path(options["file"])
  rule_resolution_path = File.expand_path(options["rule_resolution"])
  rule_resolution = load_rule_resolution_manifest(rule_resolution_path)

  unless rule_resolution["valid"] == true
    evidence_error("Rule resolution must be valid before attaching: #{rule_resolution_path}")
  end

  checks = rule_resolution["checks"].is_a?(Hash) ? rule_resolution["checks"] : {}
  rule_attachment = {
    "resolver" => "orbit rules resolve --json",
    "file" => rule_resolution_path,
    "valid" => true,
    "resolved_role" => rule_resolution["resolved_role"],
    "conflict_count" => rule_resolution["conflicts"].is_a?(Array) ? rule_resolution["conflicts"].length : 0,
    "missing_project_rule_files" => checks["missing_project_rule_files"].is_a?(Array) ? checks["missing_project_rule_files"] : []
  }

  update_evidence_manifest(path) do |manifest|
    manifest["rule_resolution"] = rule_attachment
    manifest
  end
  puts "Attached Orbit rule resolution:"
  puts "- #{rule_resolution_path}"
end

def evidence(args)
  options = parse_evidence_args(args)

  case options["subcommand"]
  when "init"
    evidence_init(options)
  when "add"
    evidence_add(options)
  when "from-report"
    evidence_from_report(options)
  when "submit"
    evidence_submit(options)
  when "waive"
    evidence_waive(options)
  when "attach-rule"
    evidence_attach_rule(options)
  when "show"
    evidence_show(options)
  else
    usage_error("Unknown evidence subcommand: #{options["subcommand"]}")
  end
end

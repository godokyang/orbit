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

  validate_structured_evidence_record(result, source, record) if record["structured_submit"] == true
  validate_destructive_action_plan_record(result, "#{source}.destructive_action_plan", record["destructive_action_plan"]) if record.key?("destructive_action_plan")
  validate_write_policy_record(result, "#{source}.write_policy", record["write_policy"]) if record.key?("write_policy")
  validate_role_execution_context_record(result, "#{source}.role_execution_context", record["role_execution_context"]) if record.key?("role_execution_context")
  validate_runtime_binding_record_field(result, source, record)
  validate_blocker_classification_record_field(result, source, record)
  validate_gate_lease_record_field(result, source, record)
end

def validate_role_execution_context_record(result, source, rec)
  unless rec.is_a?(Hash)
    validation_error(result, source, "#{source} must be a mapping.")
    return
  end

  # Validate known string identity fields
  %w[instance resolved_role role_ref].each do |field|
    next unless rec.key?(field)

    val = rec[field]
    next if val.is_a?(String) && !val.strip.empty?

    validation_error(result, "#{source}.#{field}", "role_execution_context.#{field} must be a non-empty string when present.")
  end

  # Validate hex SHA256 hash fields
  %w[role_config_sha256 rules_resolution_sha256 rules_context_sha256 task_sha256 evidence_manifest_sha256_before_submit].each do |field|
    next unless rec.key?(field)

    val = rec[field]
    next if val.is_a?(String) && val.match?(/\A[0-9a-f]{64}\z/)

    validation_error(result, "#{source}.#{field}", "role_execution_context.#{field} must be a 64-char lowercase hex string when present.")
  end

  # Validate worktree sub-mapping
  if rec.key?("worktree")
    wt = rec["worktree"]
    validation_error(result, "#{source}.worktree", "role_execution_context.worktree must be a mapping when present.") unless wt.is_a?(Hash)
    if wt.is_a?(Hash) && wt.key?("dirty_files_before")
      df = wt["dirty_files_before"]
      unless df.is_a?(Array) && df.all? { |f| f.is_a?(String) && !f.strip.empty? }
        validation_error(result, "#{source}.worktree.dirty_files_before", "role_execution_context.worktree.dirty_files_before must be a list of non-empty strings when present.")
      end
    end
  end

  # Validate permission_profile sub-mapping
  return unless rec.key?("permission_profile")

  pp = rec["permission_profile"]
  unless pp.is_a?(Hash)
    validation_error(result, "#{source}.permission_profile", "role_execution_context.permission_profile must be a mapping when present.")
    return
  end

  if pp.key?("mode") && !%w[audit_only enforced_sandbox].include?(pp["mode"])
    validation_error(result, "#{source}.permission_profile.mode", "role_execution_context.permission_profile.mode must be audit_only or enforced_sandbox.")
  end
end

def validate_write_policy_record(result, source, wp)
  return if wp.nil?

  unless wp.is_a?(Hash)
    validation_error(result, source, "Evidence record write_policy must be a mapping when present.")
    return
  end

  if wp.key?("expected")
    unless wp["expected"].is_a?(String) && !wp["expected"].to_s.strip.empty?
      validation_error(result, "#{source}.expected", "write_policy.expected must be a non-empty string when present.")
    end
  end

  %w[changed_files violations].each do |field|
    next unless wp.key?(field)

    value = wp[field]
    unless value.is_a?(Array)
      validation_error(result, "#{source}.#{field}", "write_policy.#{field} must be a list when present.")
      next
    end
    unless value.all? { |item| item.is_a?(String) && !item.strip.empty? }
      validation_error(result, "#{source}.#{field}", "write_policy.#{field} must be a list of non-empty strings.")
    end
  end
end

def validate_string_array_field(result, source, value, label)
  unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
    validation_error(result, source, "#{label} must be a list of non-empty strings.")
  end
end

def string_finding_severity(value)
  match = value.to_s.downcase.match(/\[(high|medium|low|advisory)\]/)
  match ? match[1] : nil
end

def validate_structured_finding_field(result, source, finding)
  if finding.is_a?(String)
    if finding.strip.empty?
      validation_error(result, source, "Structured submit finding must be non-empty.")
      return
    end

    severity = string_finding_severity(finding)
    if %w[high medium].include?(severity)
      validation_error(result, source, "High/medium findings must be mappings with symptom, source, consequence, and remedy.")
    end
    return
  end

  unless finding.is_a?(Hash)
    validation_error(result, source, "Structured submit finding must be a string or mapping.")
    return
  end

  severity = finding["severity"]
  unless %w[high medium low advisory].include?(severity)
    validation_error(result, "#{source}.severity", "Finding severity must be one of high|medium|low|advisory.")
  end
  validate_non_empty_string(result, "#{source}.summary", finding["summary"], "Finding summary")

  return unless %w[high medium].include?(severity)

  REQUIRED_FINDING_DETAIL_FIELDS.each do |field|
    validate_non_empty_string(result, "#{source}.#{field}", finding[field], "High/medium finding #{field}")
  end
end

def validate_findings_array_field(result, source, value, label)
  unless value.is_a?(Array)
    validation_error(result, source, "#{label} must be a list.")
    return
  end

  value.each_with_index do |finding, index|
    validate_structured_finding_field(result, "#{source}[#{index}]", finding)
  end
end

def validate_structured_review_quality_outcome(result, source, record)
  return unless record["kind"] == "review"

  value = record["quality_outcome_verdict"]
  unless value.is_a?(String) && !value.strip.empty?
    validation_error(result, "#{source}.quality_outcome_verdict", "Structured review evidence must define quality_outcome_verdict.")
    return
  end

  unless ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS.include?(value)
    validation_error(result, "#{source}.quality_outcome_verdict", "Review quality_outcome_verdict must be one of #{ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS.join("|")}.")
  end

  if record["status"] == "pass" && value != "pass"
    validation_error(result, "#{source}.quality_outcome_verdict", "Review PASS requires quality_outcome_verdict: pass.")
  end
end

def validate_structured_test_level(result, source, record)
  return unless record["kind"] == "test"
  return unless record["status"] == "pass" || record.key?("test_level")

  level = record["test_level"]
  unless level.is_a?(String) && !level.strip.empty?
    validation_error(result, "#{source}.test_level", "Structured test PASS evidence must define test_level.")
    return
  end

  unless ALLOWED_TEST_LEVELS.include?(level)
    validation_error(result, "#{source}.test_level", "Test evidence test_level must be one of #{ALLOWED_TEST_LEVELS.join("|")}.")
  end

  if record["status"] == "pass" && level == "not_applicable"
    validation_error(result, "#{source}.test_level", "Test PASS evidence test_level must not be not_applicable.")
  end
end

# Returns the semantic family of a non-universal evidence level (nil for mechanical_check).
def evidence_level_family(level)
  EVIDENCE_LEVEL_FAMILY_MAP[level]
end

# Returns true iff the evidence level belongs to a family accepted by the given gate kind.
# mechanical_check is universal and accepted by all gate kinds.
def evidence_level_valid_for_gate_kind?(level, gate_kind)
  return true if level.nil?
  return true if level == "mechanical_check"
  level_family = evidence_level_family(level)
  return true if level_family.nil?
  accepted = GATE_KIND_ACCEPTED_EVIDENCE_FAMILIES[gate_kind] || []
  accepted.include?(level_family)
end

# Kept for backward compatibility; delegates to family-based check within review_quality.
def evidence_level_rank(level)
  chain = EVIDENCE_LEVEL_FAMILIES["review_quality"] || []
  chain.index(level)
end

def task_minimum_evidence_level(task)
  strategy = task.is_a?(Hash) ? task["review_strategy"] : nil
  return nil unless strategy.is_a?(Hash)

  level = strategy["minimum_evidence_level"]
  return nil if level.nil? || level.to_s.strip.empty?

  level.to_s.strip
end

def task_minimum_evidence_level_for_gate(task, gate_kind)
  return nil unless task.is_a?(Hash)

  strategy_key = case gate_kind
                 when "review", "design_readiness" then "review_strategy"
                 when "test", "release" then "test_strategy"
                 end
  return nil unless strategy_key

  strategy = task[strategy_key]
  return nil unless strategy.is_a?(Hash)

  level = strategy["minimum_evidence_level"]
  return nil if level.nil? || level.to_s.strip.empty?

  level.to_s.strip
end

def task_requires_quality_evidence_fields?(task)
  return false unless task.is_a?(Hash)

  ALLOWED_GATE_KINDS.any? { |kind| !task_minimum_evidence_level_for_gate(task, kind).nil? }
end

def evidence_level_satisfies_minimum?(level, minimum)
  return true if minimum.nil? || minimum.empty?
  # Any level satisfies a mechanical_check minimum.
  return true if minimum == "mechanical_check"
  return false if level.nil?
  return true if level == minimum
  # mechanical_check only satisfies a mechanical_check minimum (already handled above).
  return false if level == "mechanical_check"
  # Cross-family substitution is prohibited: both level and minimum must be in the same family.
  level_family = evidence_level_family(level)
  min_family = evidence_level_family(minimum)
  return false if level_family != min_family
  # Same family: compare ranks within the chain.
  chain = EVIDENCE_LEVEL_FAMILIES[level_family] || []
  (chain.index(level) || -1) >= (chain.index(minimum) || -1)
end

def validate_evidence_level_record_field(result, source, record)
  return unless record.key?("evidence_level")

  level = record["evidence_level"]
  unless level.is_a?(String) && ALLOWED_EVIDENCE_LEVELS.include?(level)
    validation_error(result, "#{source}.evidence_level", "Evidence level must be one of #{ALLOWED_EVIDENCE_LEVELS.join("|")}.")
  end
end

# real_path_test PASS requires a runtime_binding with a server or browser owner (build/model_service alone are insufficient).
# This mirrors the submit-time check so that records mutated after submit (e.g. runtime_binding removed) are still caught by validate/audit.
def validate_runtime_binding_record_field(result, source, record)
  return unless record["kind"] == "test" && record["status"] == "pass" && record["evidence_level"] == "real_path_test"

  rb = record["runtime_binding"]
  owner_binding_present = rb.is_a?(Hash) && %w[server browser].any? do |k|
    b = rb[k]
    b.is_a?(Hash) && b["owner"].is_a?(String) && !b["owner"].strip.empty?
  end
  return if owner_binding_present

  validation_error(result, "#{source}.runtime_binding",
    "Test PASS with evidence_level real_path_test requires runtime_binding with a server or browser binding that includes owner (build/model_service alone are insufficient).")
end

# blocker_classification.kind must be a recognized failure class regardless of status.
# Catches records mutated after submit and directly-injected records with invented kinds.
def validate_blocker_classification_record_field(result, source, record)
  return unless record.key?("blocker_classification")

  bc = record["blocker_classification"]
  return unless bc.is_a?(Hash)

  kind = bc["kind"]
  unless kind.is_a?(String) && ALLOWED_FAILURE_CLASSES.include?(kind)
    validation_error(result, "#{source}.blocker_classification.kind",
      "Evidence blocker_classification.kind must be one of #{ALLOWED_FAILURE_CLASSES.join("|")}.")
    return
  end

  # A pass verdict cannot carry a non-code blocker_classification.kind: environment/service/model_drift/unknown
  # blockers mean the path did not pass.
  return unless record["status"] == "pass" && NON_CODE_PASS_BLOCKER_KINDS.include?(kind)

  validation_error(result, "#{source}.blocker_classification.kind",
    "Evidence status pass is incompatible with blocker_classification.kind #{kind}: environment/service/model_drift/unknown blockers do not count as a code pass.")
end

# Slice 9: validate gate_lease metadata on records. Catches malformed leases mutated after submit.
def validate_gate_lease_record_field(result, source, record)
  return unless record.key?("gate_lease")

  lease = record["gate_lease"]
  unless lease.is_a?(Hash)
    validation_error(result, "#{source}.gate_lease",
      "Evidence gate_lease must be a mapping.")
    return
  end

  gate = lease["gate"]
  unless gate.is_a?(String) && !gate.strip.empty?
    validation_error(result, "#{source}.gate_lease.gate",
      "Evidence gate_lease.gate must be a non-empty string identifying the gate kind.")
  end
  status = lease["status"]
  if !status.nil? && !(status.is_a?(String) && ALLOWED_GATE_LEASE_STATUSES.include?(status))
    validation_error(result, "#{source}.gate_lease.status",
      "Evidence gate_lease.status must be one of #{ALLOWED_GATE_LEASE_STATUSES.join("|")}.")
  end
  policy = lease["replacement_policy"]
  if !policy.nil? && !(policy.is_a?(String) && ALLOWED_GATE_LEASE_REPLACEMENT_POLICIES.include?(policy))
    validation_error(result, "#{source}.gate_lease.replacement_policy",
      "Evidence gate_lease.replacement_policy must be one of #{ALLOWED_GATE_LEASE_REPLACEMENT_POLICIES.join("|")}.")
  end
end

def validate_rule_application_record_field(result, source, record)
  return unless record.key?("rule_application")

  value = record["rule_application"]
  unless value.is_a?(Hash)
    validation_error(result, "#{source}.rule_application", "Rule application must be a mapping.")
    return
  end

  validate_string_array_field(result, "#{source}.rule_application.required_rule_files_read", value["required_rule_files_read"], "Rule application required_rule_files_read")
  applied_checks = value["applied_checks"]
  unless applied_checks.is_a?(Array)
    validation_error(result, "#{source}.rule_application.applied_checks", "Rule application applied_checks must be a list.")
  else
    applied_checks.each_with_index do |check, index|
      check_source = "#{source}.rule_application.applied_checks[#{index}]"
      unless check.is_a?(Hash)
        validation_error(result, check_source, "Rule application applied check must be a mapping.")
        next
      end
      validate_non_empty_string(result, "#{check_source}.id", check["id"], "Rule application applied check id")
      validate_non_empty_string(result, "#{check_source}.evidence", check["evidence"], "Rule application applied check evidence")
      unless ALLOWED_RULE_APPLICATION_VERDICTS.include?(check["verdict"])
        validation_error(result, "#{check_source}.verdict", "Rule application applied check verdict must be one of #{ALLOWED_RULE_APPLICATION_VERDICTS.join("|")}.")
      end
    end
  end

  not_applicable = value["not_applicable"]
  unless not_applicable.is_a?(Array)
    validation_error(result, "#{source}.rule_application.not_applicable", "Rule application not_applicable must be a list.")
  else
    not_applicable.each_with_index do |item, index|
      item_source = "#{source}.rule_application.not_applicable[#{index}]"
      unless item.is_a?(Hash)
        validation_error(result, item_source, "Rule application not_applicable item must be a mapping.")
        next
      end
      validate_non_empty_string(result, "#{item_source}.id", item["id"], "Rule application not_applicable id")
      validate_non_empty_string(result, "#{item_source}.reason", item["reason"], "Rule application not_applicable reason")
    end
  end
end

def validate_quality_question_answers_record_field(result, source, record)
  return unless record.key?("quality_question_answers")

  value = record["quality_question_answers"]
  unless value.is_a?(Array)
    validation_error(result, "#{source}.quality_question_answers", "Quality question answers must be a list.")
    return
  end

  value.each_with_index do |answer, index|
    answer_source = "#{source}.quality_question_answers[#{index}]"
    unless answer.is_a?(Hash)
      validation_error(result, answer_source, "Quality question answer must be a mapping.")
      next
    end
    validate_non_empty_string(result, "#{answer_source}.id", answer["id"], "Quality question answer id")
    validate_non_empty_string(result, "#{answer_source}.evidence", answer["evidence"], "Quality question answer evidence")
    unless ALLOWED_QUALITY_QUESTION_VERDICTS.include?(answer["verdict"])
      validation_error(result, "#{answer_source}.verdict", "Quality question answer verdict must be one of #{ALLOWED_QUALITY_QUESTION_VERDICTS.join("|")}.")
    end
  end
end

def validate_quality_boundary_record_fields(result, source, record)
  validate_evidence_level_record_field(result, source, record)
  validate_rule_application_record_field(result, source, record)
  validate_quality_question_answers_record_field(result, source, record)
  %w[confirmed assumed missing counterexample_cases].each do |field|
    validate_string_array_field(result, "#{source}.#{field}", record[field], "Structured submit #{field}") if record.key?(field)
  end
  if record.key?("residual_risk")
    unless record["residual_risk"].is_a?(String) && !record["residual_risk"].strip.empty?
      validation_error(result, "#{source}.residual_risk", "Evidence residual_risk must be a non-empty string when present.")
    end
  end
  return unless record.key?("implementation_readiness_verdict")

  unless ALLOWED_IMPLEMENTATION_READINESS_VERDICTS.include?(record["implementation_readiness_verdict"])
    validation_error(result, "#{source}.implementation_readiness_verdict", "Implementation readiness verdict must be one of #{ALLOWED_IMPLEMENTATION_READINESS_VERDICTS.join("|")}.")
  end
end

def validate_structured_evidence_record(result, source, record)
  unless STRUCTURED_SUBMIT_KINDS.include?(record["kind"])
    validation_error(result, "#{source}.structured_submit", "Structured submit is only valid for #{STRUCTURED_SUBMIT_KINDS.join("|")} evidence.")
  end
  validate_non_empty_string(result, "#{source}.source_message_id", record["source_message_id"], "Structured submit source_message_id")
  validate_findings_array_field(result, "#{source}.findings", record["findings"], "Structured submit findings")
  validate_string_array_field(result, "#{source}.coverage", record["coverage"], "Structured submit coverage")
  validate_string_array_field(result, "#{source}.artifacts", record["artifacts"], "Structured submit artifacts")
  validate_structured_review_quality_outcome(result, source, record)
  validate_structured_test_level(result, source, record)
  validate_quality_boundary_record_fields(result, source, record)
  validate_blocked_evidence_detail(result, "#{source}.blocked", record["blocked"]) if record.key?("blocked")
end

def validate_blocked_evidence_detail(result, source, blocked)
  unless blocked.is_a?(Hash)
    validation_error(result, source, "Blocked evidence detail must be a mapping.")
    return
  end

  %w[reason next_step owner].each do |field|
    validate_non_empty_string(result, "#{source}.#{field}", blocked[field], "Blocked evidence #{field}")
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

def latest_valid_gate_record(result, records, expected_kind, task_sha256 = nil)
  evidence_record_kind = GATE_KIND_EVIDENCE_RECORD_KIND[expected_kind] || expected_kind
  candidates = []

  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)
    next unless record["kind"] == evidence_record_kind
    next if record["status"] == "invalid"
    next unless ALLOWED_EVIDENCE_STATUSES.include?(record["status"])
    next if STRUCTURED_SUBMIT_KINDS.include?(evidence_record_kind) && record["structured_submit"] != true
    next unless gate_record_identity_valid?(record, expected_kind)

    created_at = parse_evidence_created_at(result, "evidence_file.records[#{index}].created_at", record["created_at"])
    next unless created_at

    candidates << [created_at, index, record]
  end

  raw_latest = candidates.max_by { |created_at, index, _record| [created_at, index] }&.last
  return raw_latest unless task_sha256

  # Slice 9: when a current task_sha256 is provided, arbitration is authoritative.
  # A stale (old task sha) verdict cannot be the accepted gate record.
  arbitration = verdict_arbitration_for_gate(records, expected_kind, task_sha256)
  accepted = arbitration["accepted_record"]
  # The accepted record must also pass identity validation (gate_record_identity_valid?)
  # since arbitration's candidate collection does not filter by role identity.
  if accepted && gate_record_identity_valid?(accepted, expected_kind)
    accepted
  elsif arbitration["has_stale"]
    nil
  else
    raw_latest
  end
end

def validate_gate_verdict(result, records, expected_kind, task = nil, task_sha256: nil)
  latest = latest_valid_gate_record(result, records, expected_kind, task_sha256)
  unless latest
    # Distinguish stale-verdict-only from truly missing.
    if task_sha256
      arbitration = verdict_arbitration_for_gate(records, expected_kind, task_sha256)
      if arbitration["has_stale"]
        validation_error(result, "evidence_file.records.#{expected_kind}",
          "Latest #{expected_kind} verdict is for an old task revision (stale) and cannot close the current gate.")
        return
      end
    end
    validation_error(result, "evidence_file.records", "Review/test task requires structured valid #{expected_kind.inspect} evidence with status pass.")
    return
  end

  case latest["status"]
  when "pass"
    actual_level = latest["evidence_level"]
    if task_requires_quality_evidence_fields?(task) && !ALLOWED_EVIDENCE_LEVELS.include?(actual_level.to_s)
      validation_error(result, "evidence_file.records.#{expected_kind}.evidence_level", "Latest #{expected_kind} PASS must include evidence_level because task declares minimum_evidence_level.")
    end
    if actual_level && !evidence_level_valid_for_gate_kind?(actual_level, expected_kind)
      accepted_levels = (GATE_KIND_ACCEPTED_EVIDENCE_FAMILIES[expected_kind] || []).flat_map { |f| EVIDENCE_LEVEL_FAMILIES[f] || [] }.uniq
      validation_error(result, "evidence_file.records.#{expected_kind}.evidence_level",
        "evidence_level_wrong_gate_kind: Evidence level #{actual_level.inspect} is not valid for #{expected_kind.inspect} gate. Accepted: #{accepted_levels.join("|")}.")
    end
    minimum = task_minimum_evidence_level_for_gate(task, expected_kind)
    unless evidence_level_satisfies_minimum?(actual_level, minimum)
      validation_error(result, "evidence_file.records.#{expected_kind}.evidence_level", "Latest #{expected_kind} evidence_level #{actual_level.inspect} does not satisfy minimum_evidence_level #{minimum.inspect}.")
    end
    validate_required_questions_coverage(result, latest, task) if (GATE_KIND_EVIDENCE_RECORD_KIND[expected_kind] || expected_kind) == "review"
  when "fail"
    validation_error(result, "evidence_file.records", "Latest #{expected_kind} verdict is fail.")
  when "partial"
    if latest["blocked"].is_a?(Hash)
      validation_error(result, "evidence_file.records", "Latest #{expected_kind} verdict is blocked: #{latest.dig("blocked", "reason")}.")
    else
      validation_error(result, "evidence_file.records", "Latest #{expected_kind} verdict is partial; task remains blocked.")
    end
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

def validate_non_empty_scalar(result, source, value, label)
  return if value.is_a?(String) && !value.strip.empty?
  return if value.is_a?(Numeric)

  validation_error(result, source, "#{label} must be a non-empty scalar.")
end

def record_field_or_nested(record, nested, field)
  nested[field].nil? ? record[field] : nested[field]
end

def validate_test_pass_environment_evidence(result, records, task)
  return unless task_requires_test_evidence?(task)

  latest = latest_record_for_kind(records, "test", structured_gate_only: true, gate_identity_required: true)
  return unless latest && latest["status"] == "pass"

  declared_level = task["test_level"]
  evidence_level = latest["test_level"]
  if !evidence_level.is_a?(String) || evidence_level.strip.empty?
    validation_error(result, "evidence_file.records.test.test_level", "Latest passing test evidence must include test_level.")
  elsif !ALLOWED_TEST_LEVELS.include?(evidence_level)
    validation_error(result, "evidence_file.records.test.test_level", "Latest passing test evidence test_level must be one of #{ALLOWED_TEST_LEVELS.join("|")}.")
  elsif evidence_level == "not_applicable"
    validation_error(result, "evidence_file.records.test.test_level", "Latest passing test evidence test_level must not be not_applicable.")
  elsif declared_level.is_a?(String) && !declared_level.empty? && declared_level != "not_applicable" && evidence_level != declared_level
    validation_error(result, "evidence_file.records.test.test_level", "Latest passing test evidence test_level #{evidence_level.inspect} must match task test_level #{declared_level.inspect}.")
  end

  environment = latest["test_environment"]
  unless environment.is_a?(Hash)
    validation_error(result, "evidence_file.records.test.test_environment", "Latest passing test evidence must include test_environment mapping.")
    return
  end

  %w[environment test_tab_or_pane server_owner browser_owner cleanup_hook artifact_cleanup].each do |field|
    validate_non_empty_string(result, "evidence_file.records.test.test_environment.#{field}", environment[field], "Test environment #{field}")
  end

  %w[duration resource_usage cleanup_status ux_quality artifact_quality].each do |field|
    value = record_field_or_nested(latest, environment, field)
    validate_non_empty_scalar(result, "evidence_file.records.test.test_environment.#{field}", value, "Test environment #{field}")
  end
end

def validate_quality_metric_evidence(result, source, metric)
  unless metric.is_a?(Hash)
    validation_error(result, source, "Quality measurement metric must be a mapping.")
    return
  end

  validate_non_empty_string(result, "#{source}.name", metric["name"], "Quality measurement metric name")
  validate_non_empty_scalar(result, "#{source}.baseline", metric["baseline"], "Quality measurement metric baseline")
  validate_non_empty_scalar(result, "#{source}.after", metric["after"], "Quality measurement metric after")
  validate_non_empty_string(result, "#{source}.evidence", metric["evidence"], "Quality measurement metric evidence")
end

def validate_quality_measurement_waiver_evidence(result, source, waiver)
  unless waiver.is_a?(Hash)
    validation_error(result, source, "Quality measurement waiver must be a mapping.")
    return
  end

  %w[reason risk replacement_evidence].each do |field|
    validate_non_empty_string(result, "#{source}.#{field}", waiver[field], "Quality measurement waiver #{field}")
  end
end

def validate_quality_measurement_evidence(result, records, task)
  return unless quality_measurement_task?(task)

  latest = latest_record_for_kind(records, "test", structured_gate_only: true, gate_identity_required: true)
  return unless latest && latest["status"] == "pass"

  measurement = latest["quality_measurement"]
  unless measurement.is_a?(Hash)
    validation_error(result, "evidence_file.records.test.quality_measurement", "Latest passing test evidence must include quality_measurement mapping for baseline/after evidence or an explicit waiver.")
    return
  end

  waiver = measurement["waiver"]
  if waiver.is_a?(Hash) && !waiver.empty?
    validate_quality_measurement_waiver_evidence(result, "evidence_file.records.test.quality_measurement.waiver", waiver)
    return
  end

  validate_non_empty_scalar(result, "evidence_file.records.test.quality_measurement.baseline", measurement["baseline"], "Quality measurement baseline")
  validate_non_empty_scalar(result, "evidence_file.records.test.quality_measurement.after", measurement["after"], "Quality measurement after")

  metrics = measurement["metrics"]
  unless metrics.is_a?(Array) && !metrics.empty?
    validation_error(result, "evidence_file.records.test.quality_measurement.metrics", "Quality measurement metrics must be a non-empty list.")
    return
  end

  metrics.each_with_index do |metric, index|
    validate_quality_metric_evidence(result, "evidence_file.records.test.quality_measurement.metrics[#{index}]", metric)
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
        REQUIRED_FINDING_DETAIL_FIELDS.each do |field|
          unless finding[field].is_a?(String) && !finding[field].strip.empty?
            validation_error(result, "#{source}.#{field}", "High/medium review findings must include #{field} for the finding quality gate.")
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

def validate_waiver(result, source, waiver)
  unless waiver.is_a?(Hash)
    validation_error(result, source, "Waiver must be a mapping.")
    return
  end

  %w[owner scope reason risk replacement_evidence expiry created_at].each do |field|
    validate_non_empty_string(result, "#{source}.#{field}", waiver[field], "Waiver #{field}")
  end

  unless [true, false].include?(waiver["revoked_by_user_requirement"])
    validation_error(result, "#{source}.revoked_by_user_requirement", "Waiver revoked_by_user_requirement must be true or false.")
  end
end

def validate_waivers(result, value)
  return if value.nil?

  unless value.is_a?(Array)
    validation_error(result, "evidence_file.waivers", "Evidence waivers must be a list.")
    return
  end

  value.each_with_index do |waiver, index|
    validate_waiver(result, "evidence_file.waivers[#{index}]", waiver)
  end
end


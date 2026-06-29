# frozen_string_literal: true

ALLOWED_EVIDENCE_STATUSES = %w[pass fail partial invalid].freeze
ALLOWED_EVIDENCE_VERDICT_STATUSES = (ALLOWED_EVIDENCE_STATUSES + %w[in_progress]).freeze
ALLOWED_EVIDENCE_KINDS = %w[review test command implementation waiver].freeze
STRUCTURED_SUBMIT_KINDS = %w[review test].freeze
ALLOWED_TEST_LEVELS = %w[unit integration repo_regression browser_e2e provider_e2e dogfood manual not_applicable].freeze
ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS = %w[pass fail partial blocked unknown not_applicable].freeze
# Scaffold includes real_path_test and release_readiness so reports using those values are not
# rejected at submit time. Per-gate-kind ranking semantics are not yet implemented (Phase 1 Slice 1).
# The first three values form the current ordered set; the last two are accepted but not ranked.
ALLOWED_EVIDENCE_LEVELS = %w[mechanical_check outcome_quality implementation_readiness real_path_test release_readiness].freeze
RANKED_EVIDENCE_LEVELS = %w[mechanical_check outcome_quality implementation_readiness].freeze
ALLOWED_RULE_APPLICATION_VERDICTS = %w[pass fail blocked not_applicable].freeze
ALLOWED_QUALITY_QUESTION_VERDICTS = %w[pass fail blocked not_applicable].freeze
ALLOWED_IMPLEMENTATION_READINESS_VERDICTS = %w[pass blocked not_checked].freeze
REQUIRED_FINDING_DETAIL_FIELDS = %w[symptom source consequence remedy].freeze
ALLOWED_FAILURE_CLASSES = %w[code_failure environment_failure service_failure model_drift expected_fail_closed unknown].freeze
# Blocker classifications that cannot coexist with a pass verdict: they describe a non-code
# blocker (environment/service/model_drift) or an unresolved unknown, so the path did not pass.
NON_CODE_PASS_BLOCKER_KINDS = %w[environment_failure service_failure model_drift unknown].freeze
# Slice 9: gate lease + stale verdict arbitration.
ALLOWED_GATE_LEASE_STATUSES = %w[claimed expired superseded released].freeze
ALLOWED_GATE_LEASE_REPLACEMENT_POLICIES = %w[allow_after_expiry deny owner_only].freeze
GATE_LEASE_DEFAULT_REPLACEMENT_POLICY = "allow_after_expiry"
VERDICT_ARBITRATION_CONFLICT_RESOLUTION = "latest_valid_for_task_revision"
# Slice 10: doc lifecycle and decision records.
ALLOWED_DOC_LIFECYCLE_STATUSES = %w[active_baseline open_design implemented_archive historical_reference lesson_candidate promoted_rule].freeze
ALLOWED_DECISION_KINDS = %w[user_confirmation scope_change risk_acceptance design_choice lesson_promotion].freeze
EVIDENCE_EXPECTED_GATE_ROLES = {
  "review" => "reviewer",
  "test" => "tester"
}.freeze

def parse_evidence_args(args)
  subcommand = args.shift
  usage_error("Missing evidence subcommand.") unless subcommand

  options = {
    "subcommand" => subcommand,
    "json" => false
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--output"
      options["output"] = option_value(args, "--output")
    when /\A--output=(.+)\z/
      options["output"] = Regexp.last_match(1)
    when "--file"
      options["file"] = option_value(args, "--file")
    when /\A--file=(.+)\z/
      options["file"] = Regexp.last_match(1)
    when "--kind"
      options["kind"] = option_value(args, "--kind")
    when /\A--kind=(.+)\z/
      options["kind"] = Regexp.last_match(1)
    when "--status"
      options["status"] = option_value(args, "--status")
    when /\A--status=(.+)\z/
      options["status"] = Regexp.last_match(1)
    when "--summary"
      options["summary"] = option_value(args, "--summary")
    when /\A--summary=(.+)\z/
      options["summary"] = Regexp.last_match(1)
    when "--rule-resolution"
      options["rule_resolution"] = option_value(args, "--rule-resolution")
    when /\A--rule-resolution=(.+)\z/
      options["rule_resolution"] = Regexp.last_match(1)
    when "--report"
      options["report"] = option_value(args, "--report")
    when /\A--report=(.+)\z/
      options["report"] = Regexp.last_match(1)
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--decision-record"
      options["decision_record"] = option_value(args, "--decision-record")
    when /\A--decision-record=(.+)\z/
      options["decision_record"] = Regexp.last_match(1)
    when "--waiver"
      options["waiver"] = option_value(args, "--waiver")
    when /\A--waiver=(.+)\z/
      options["waiver"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown evidence #{subcommand} option: #{arg}")
    end
  end

  case subcommand
  when "init"
    usage_error("Missing required option: --output") if options["output"].nil? || options["output"].empty?
  when "add"
    %w[file kind status summary].each do |name|
      usage_error("Missing required option: --#{name}") if options[name].nil? || options[name].empty?
    end
  when "from-report"
    usage_error("Missing required option: --file") if options["file"].nil? || options["file"].empty?
    usage_error("Missing required option: --report") if options["report"].nil? || options["report"].empty?
  when "submit"
    usage_error("Missing required option: --file") if options["file"].nil? || options["file"].empty?
    usage_error("Missing required option: --report") if options["report"].nil? || options["report"].empty?
  when "waive"
    usage_error("Missing required option: --file") if options["file"].nil? || options["file"].empty?
    usage_error("Missing required option: --waiver") if options["waiver"].nil? || options["waiver"].empty?
  when "attach-rule"
    usage_error("Missing required option: --file") if options["file"].nil? || options["file"].empty?
    usage_error("Missing required option: --rule-resolution") if options["rule_resolution"].nil? || options["rule_resolution"].empty?
  when "show"
    usage_error("Missing required option: --file") if options["file"].nil? || options["file"].empty?
    usage_error("evidence show currently requires --json") unless options["json"]
  else
    usage_error("Unknown evidence subcommand: #{subcommand}")
  end

  options
end

def evidence_error(message)
  warn message
  exit 1
end

def evidence_value_type(value)
  case value
  when nil
    "missing"
  when Array
    item_types = value.map { |item| evidence_value_type(item) }.uniq
    item_types.empty? ? "array" : "array<#{item_types.join("|")}>"
  when Hash
    "mapping"
  when String
    value.strip.empty? ? "empty string" : "string"
  else
    value.class.to_s.downcase
  end
end

def submit_report_template_hint(kind = nil)
  case kind
  when "review"
    "assets/templates/review-report.yaml"
  when "test"
    "assets/templates/test-report.yaml"
  else
    "assets/templates/review-report.yaml or assets/templates/test-report.yaml"
  end
end

def submit_report_schema_error(source, message, expected:, actual:, kind: nil)
  evidence_error([
    message,
    "field: #{source}",
    "expected: #{expected}",
    "actual: #{actual}",
    "template: #{submit_report_template_hint(kind)}"
  ].join("\n"))
end

def evidence_runtime_identity!
  result = {
    "project" => File.basename(Dir.pwd),
    "instance" => nil,
    "resolved_role" => nil,
    "role_sources" => {},
    "conflicts" => []
  }
  roles, instances = load_project_config(result)
  role_def = resolve_identity(result, roles, instances)
  unless result["conflicts"].empty?
    messages = result["conflicts"].map { |entry| "#{entry["source"]}: #{entry["message"]}" }
    evidence_error("Runtime identity conflict: #{messages.join("; ")}")
  end
  evidence_error("Runtime identity could not be resolved.") unless role_def

  result["capabilities"] = role_def["capabilities"] || []
  result["permissions"] = role_def["permissions"] || {}
  result
end

def required_evidence_submit_capability(kind)
  case kind
  when "review"
    ["reviewer", "review.submit"]
  when "test"
    ["tester", "test.submit"]
  else
    nil
  end
end

def require_evidence_submit_capability!(kind)
  requirement = required_evidence_submit_capability(kind)
  return nil unless requirement

  expected_role, capability = requirement
  identity = evidence_runtime_identity!
  capabilities = identity["capabilities"].is_a?(Array) ? identity["capabilities"] : []
  unless identity["resolved_role"] == expected_role || capabilities.include?(capability)
    evidence_error("#{kind} evidence requires #{expected_role} role or #{capability} capability; current role is #{identity["resolved_role"].inspect}.")
  end

  identity
end

def evidence_identity_snapshot(identity)
  return nil unless identity

  {
    "instance" => identity["instance"],
    "resolved_instance" => identity["resolved_instance"],
    "resolved_role" => identity["resolved_role"],
    "role_ref" => identity["role_ref"],
    "expected_command" => identity["expected_command"],
    "actual_client" => identity["actual_client"],
    "transport_binding" => identity["transport_binding"]
  }.compact
end

def apply_structured_gate_defaults!(record, source_message_id)
  return record unless STRUCTURED_SUBMIT_KINDS.include?(record["kind"])

  record["structured_submit"] = true
  record["source_message_id"] ||= source_message_id
  record["findings"] ||= []
  record["coverage"] ||= []
  record["artifacts"] ||= []
  if record["kind"] == "review"
    record["quality_outcome_verdict"] ||= case record["status"]
                                          when "pass" then "pass"
                                          when "fail" then "fail"
                                          when "partial" then "partial"
                                          else "unknown"
                                          end
  end
  record["test_level"] ||= "repo_regression" if record["kind"] == "test" && record["status"] == "pass"
  record
end

def default_evidence_manifest
  {
    "schema_version" => "orbit-evidence-v1",
    "schema_semantics" => {
      "feature_versions" => ORBIT_FEATURE_VERSIONS.reject { |_k, v| v.nil? }
    },
    "project" => File.basename(Dir.pwd),
    "records" => [],
    "verdict" => {
      "status" => "in_progress",
      "mode" => "aggregate",
      "summary" => "No evidence records yet.",
      "gates" => {},
      "waivers" => {
        "total" => 0,
        "open" => 0
      }
    },
    "waivers" => [],
    "worktree_safety" => {
      "status" => "not_applicable",
      "reason" => "",
      "status_before" => "",
      "head_before" => "",
      "status_after" => "",
      "head_after" => "",
      "unexpected_changes" => []
    },
    "regression_guard" => {
      "status" => "not_applicable",
      "evidence" => ""
    },
    "release_surface" => {
      "status" => "not_applicable",
      "checked" => [],
      "gaps" => []
    },
    "rule_resolution" => {
      "resolver" => "orbit rules resolve --json",
      "file" => "",
      "valid" => nil,
      "resolved_role" => "",
      "conflict_count" => nil,
      "missing_project_rule_files" => []
    },
    "tool_calls" => []
  }
end

def load_evidence_manifest(path)
  manifest = load_yaml(path)
  evidence_error("#{path} must contain a mapping.") unless manifest.is_a?(Hash)
  manifest
rescue RuntimeError => e
  evidence_error(e.message)
end

def write_evidence_manifest(path, manifest)
  write_file_atomically(path, "#{JSON.pretty_generate(manifest)}\n")
end

def update_evidence_manifest(path)
  update_json_file_atomically(path) do |manifest|
    evidence_error("#{path} must contain a mapping.") unless manifest.is_a?(Hash)
    unless manifest["schema_version"] == "orbit-evidence-v1"
      evidence_error("Evidence schema_version must be orbit-evidence-v1.")
    end

    updated = yield(manifest)
    updated || manifest
  end
rescue RuntimeError => e
  evidence_error(e.message)
end

def validate_evidence_record_shape!(record, source)
  evidence_error("#{source} must be a mapping.") unless record.is_a?(Hash)

  kind = record["kind"]
  status = record["status"]
  summary = record["summary"]
  created_at = record["created_at"]

  evidence_error("#{source}.kind must be one of #{ALLOWED_EVIDENCE_KINDS.join("|")}.") unless ALLOWED_EVIDENCE_KINDS.include?(kind)
  evidence_error("#{source}.status must be one of #{ALLOWED_EVIDENCE_STATUSES.join("|")}.") unless ALLOWED_EVIDENCE_STATUSES.include?(status)
  evidence_error("#{source}.summary must be a non-empty string.") unless summary.is_a?(String) && !summary.strip.empty?
  evidence_error("#{source}.created_at must be a non-empty string.") unless created_at.is_a?(String) && !created_at.empty?
end

def ensure_evidence_waivers!(manifest)
  manifest["waivers"] ||= []
  evidence_error("Evidence waivers must be a list.") unless manifest["waivers"].is_a?(Array)
  manifest["waivers"]
end

def latest_records_by_kind(records)
  latest = {}
  records.each_with_index do |record, index|
    next unless record.is_a?(Hash)
    next unless ALLOWED_EVIDENCE_KINDS.include?(record["kind"])
    next if record["status"] == "invalid"

    begin
      created_at = Time.iso8601(record["created_at"].to_s)
    rescue ArgumentError
      next
    end

    current = latest[record["kind"]]
    latest[record["kind"]] = [created_at, index, record] if current.nil? || (([created_at, index] <=> current[0, 2]) == 1)
  end
  latest.transform_values(&:last)
end

def aggregate_verdict_status(latest_by_kind, open_waiver_count)
  evidence_statuses = latest_by_kind.reject { |kind, _record| kind == "waiver" }.map do |kind, record|
    evidence_effective_verdict_status(kind, record)
  end
  gate_statuses = latest_by_kind.select { |kind, _record| %w[review test audit].include?(kind) }.map do |kind, record|
    evidence_effective_verdict_status(kind, record)
  end
  return "in_progress" if evidence_statuses.empty? && open_waiver_count.zero?
  return "fail" if evidence_statuses.include?("fail")
  return "partial" if evidence_statuses.any? { |status| %w[partial invalid].include?(status) }
  return "partial" if open_waiver_count.positive?
  return "pass" if gate_statuses.any? && evidence_statuses.all? { |status| status == "pass" }

  "in_progress"
end

def evidence_gate_identity_role(record)
  rec_ctx = record["role_execution_context"]
  return rec_ctx["resolved_role"] if rec_ctx.is_a?(Hash) && rec_ctx.key?("resolved_role")

  identity = record["identity"]
  identity.is_a?(Hash) ? identity["resolved_role"] : nil
end

def evidence_structured_gate_identity_valid?(kind, record)
  expected_role = EVIDENCE_EXPECTED_GATE_ROLES[kind]
  return true unless expected_role

  evidence_gate_identity_role(record) == expected_role
end

def evidence_effective_verdict_status(kind, record)
  if STRUCTURED_SUBMIT_KINDS.include?(kind) && !evidence_structured_gate_identity_valid?(kind, record)
    return "partial"
  end

  record["status"]
end

def rule_application_summary(rule_application)
  return nil unless rule_application.is_a?(Hash)

  applied_checks = rule_application["applied_checks"].is_a?(Array) ? rule_application["applied_checks"] : []
  not_applicable = rule_application["not_applicable"].is_a?(Array) ? rule_application["not_applicable"] : []
  required_files = rule_application["required_rule_files_read"].is_a?(Array) ? rule_application["required_rule_files_read"] : []
  {
    "required_rule_files_read_count" => required_files.length,
    "applied_checks_count" => applied_checks.length,
    "not_applicable_count" => not_applicable.length
  }
end

def evidence_boundary_summary(record)
  return nil unless record.is_a?(Hash)

  summary = {
    "confirmed_count" => record["confirmed"].is_a?(Array) ? record["confirmed"].length : nil,
    "assumed_count" => record["assumed"].is_a?(Array) ? record["assumed"].length : nil,
    "missing_count" => record["missing"].is_a?(Array) ? record["missing"].length : nil,
    "counterexample_cases_count" => record["counterexample_cases"].is_a?(Array) ? record["counterexample_cases"].length : nil,
    "rule_application" => rule_application_summary(record["rule_application"])
  }.compact
  summary.empty? ? nil : summary
end

def evidence_gate_verdict_entry(kind, record)
  expected_role = EVIDENCE_EXPECTED_GATE_ROLES[kind]
  {
    "status" => record["status"],
    "effective_status" => evidence_effective_verdict_status(kind, record),
    "summary" => record["summary"],
    "created_at" => record["created_at"],
    "structured" => record["structured_submit"] == true,
    "evidence_level" => record["evidence_level"],
    "quality_outcome_verdict" => record["quality_outcome_verdict"],
    "implementation_readiness_verdict" => record["implementation_readiness_verdict"],
    "test_level" => record["test_level"],
    "residual_risk" => record["residual_risk"],
    "rule_application_summary" => rule_application_summary(record["rule_application"]),
    "evidence_boundary_summary" => evidence_boundary_summary(record),
    "source_message_id" => record["source_message_id"],
    "identity_expected_role" => expected_role,
    "identity_resolved_role" => evidence_gate_identity_role(record),
    "identity_valid" => expected_role ? evidence_structured_gate_identity_valid?(kind, record) : nil,
    "blocked" => record["blocked"]
  }.compact
end

def recompute_evidence_verdict!(manifest)
  records = manifest["records"].is_a?(Array) ? manifest["records"] : []
  waivers = manifest["waivers"].is_a?(Array) ? manifest["waivers"] : []
  latest_by_kind = latest_records_by_kind(records)
  open_waivers = waivers.select { |waiver| waiver.is_a?(Hash) && waiver["revoked_by_user_requirement"] != true }
  gates = latest_by_kind.each_with_object({}) do |(kind, record), memo|
    memo[kind] = evidence_gate_verdict_entry(kind, record)
  end
  status = aggregate_verdict_status(latest_by_kind, open_waivers.length)

  manifest["verdict"] = {
    "status" => status,
    "mode" => "aggregate",
    "summary" => aggregate_verdict_summary(status, latest_by_kind, open_waivers.length),
    "gates" => gates,
    "waivers" => {
      "total" => waivers.length,
      "open" => open_waivers.length
    },
    "latest_record" => records.last
  }.compact
end

def aggregate_verdict_summary(status, latest_by_kind, open_waiver_count)
  return "No evidence records yet." if status == "in_progress" && latest_by_kind.empty?

  parts = latest_by_kind.sort.map do |kind, record|
    effective_status = evidence_effective_verdict_status(kind, record)
    effective_status == record["status"] ? "#{kind}=#{record["status"]}" : "#{kind}=#{record["status"]}/effective:#{effective_status}"
  end
  parts << "open_waivers=#{open_waiver_count}" if open_waiver_count.positive?
  "Aggregate evidence verdict: #{status} (#{parts.join(", ")})."
end

def manifest_with_recomputed_verdict(manifest)
  recompute_evidence_verdict!(manifest)
  manifest
end

def ensure_evidence_records!(manifest)
  manifest["records"] ||= []
  evidence_error("Evidence records must be a list.") unless manifest["records"].is_a?(Array)
  manifest["records"].each_with_index do |record, index|
    validate_evidence_record_shape!(record, "Evidence records[#{index}]")
  end
  manifest["records"]
end

def evidence_init(options)
  output_path = File.expand_path(options["output"])
  if File.exist?(output_path)
    evidence_error("Evidence file already exists: #{output_path}")
  end

  write_evidence_manifest(output_path, manifest_with_recomputed_verdict(default_evidence_manifest))
  puts "Created Orbit evidence manifest:"
  puts "- #{output_path}"
end

def evidence_add(options)
  path = File.expand_path(options["file"])
  if STRUCTURED_SUBMIT_KINDS.include?(options["kind"]) && options["status"] == "pass"
    evidence_error("#{options["kind"]} PASS evidence must be submitted with evidence submit --report <structured-yaml>.")
  end
  identity = require_evidence_submit_capability!(options["kind"])
  record = {
    "kind" => options["kind"],
    "status" => options["status"],
    "summary" => options["summary"].strip,
    "created_at" => Time.now.utc.iso8601
  }
  apply_structured_gate_defaults!(record, "manual:evidence-add:#{record["created_at"]}")
  snapshot = evidence_identity_snapshot(identity)
  record["identity"] = snapshot if snapshot
  # Slice 10: parse --decision-record (JSON/YAML string or @file) and attach to record.
  if options["decision_record"]
    dr_source = options["decision_record"]
    raw = if dr_source.start_with?("@")
            dr_path = File.expand_path(dr_source[1..])
            evidence_error("--decision-record file not found: #{dr_path}") unless File.file?(dr_path)
            File.read(dr_path)
          else
            dr_source
          end
    begin
      parsed = raw.strip.start_with?("{") ? JSON.parse(raw) : YAML.safe_load(raw)
    rescue JSON::ParserError, Psych::SyntaxError
      evidence_error("--decision-record must be valid JSON or YAML mapping.")
    end
    normalized = validate_decision_record!({ "decision_record" => parsed, "kind" => options["kind"] }, "evidence_add")
    evidence_error("--decision-record must be a mapping with id, kind, summary, source.") unless normalized.is_a?(Hash)
    record["decision_record"] = normalized
  end
  validate_evidence_record_shape!(record, "Evidence record")

  update_evidence_manifest(path) do |manifest|
    records = ensure_evidence_records!(manifest)
    records << record
    manifest["project"] = File.basename(Dir.pwd) if manifest["project"].to_s.empty?
    recompute_evidence_verdict!(manifest)
    manifest
  end

  puts "Appended Orbit evidence:"
  puts "- #{path}"
end

def infer_report_kind(report_path, report)
  explicit = report["kind"] if report.is_a?(Hash)
  return explicit if ALLOWED_EVIDENCE_KINDS.include?(explicit)

  name = File.basename(report_path).downcase
  return "review" if name.include?("review")
  return "test" if name.include?("test")
  return "implementation" if name.include?("implementation")
  return "command" if name.include?("command")

  nil
end

def normalize_report_status(value)
  token = value.to_s.strip.upcase
  return nil if token.empty?

  return "pass" if %w[PASS APPROVED].include?(token)
  return "fail" if %w[FAIL CHANGES_REQUESTED].include?(token)
  return "partial" if %w[BLOCKED PARTIAL].include?(token)

  nil
end

def status_from_report_line(line)
  stripped = line.to_s.strip.sub(/\A#+\s*/, "")
  return normalize_report_status(stripped) if normalize_report_status(stripped)

  match = stripped.match(/\A(?:VERDICT|STATUS|RESULT|DECISION)\s*:\s*([A-Za-z_]+)\z/i)
  match ? normalize_report_status(match[1]) : nil
end

def infer_report_status(report)
  if report.is_a?(Hash)
    %w[status verdict result decision].each do |field|
      status = normalize_report_status(report[field])
      return status if status
    end
  end

  first_line = report.to_s.lines.map(&:strip).find { |line| !line.empty? }
  return status_from_report_line(first_line) if first_line

  nil
end

def infer_report_summary(report_path, report)
  if report.is_a?(Hash)
    %w[summary title message].each do |field|
      value = report[field]
      return value.strip if value.is_a?(String) && !value.strip.empty?
    end
  end

  text = report.is_a?(Hash) ? YAML.dump(report) : report.to_s
  line = text.lines.map(&:strip).find { |item| !item.empty? }
  line ||= "Evidence imported from report"
  line.length > 240 ? "#{line[0, 237]}..." : line
end

def load_report_for_evidence(path)
  expanded = File.expand_path(path)
  content = File.read(expanded)
  parsed = YAML.safe_load(content, aliases: true, filename: expanded)
  parsed = content unless parsed.is_a?(Hash)
  [expanded, parsed]
rescue Errno::ENOENT
  evidence_error("Missing report file: #{expanded}")
rescue Psych::Exception
  [expanded, content]
end

def evidence_from_report(options)
  path = File.expand_path(options["file"])
  report_path, report = load_report_for_evidence(options["report"])

  kind = options["kind"] || infer_report_kind(report_path, report)
  evidence_error("Could not infer report kind; pass --kind #{ALLOWED_EVIDENCE_KINDS.join("|")}.") unless ALLOWED_EVIDENCE_KINDS.include?(kind)

  status = options["status"] || infer_report_status(report)
  evidence_error("Could not infer report status; pass --status #{ALLOWED_EVIDENCE_STATUSES.join("|")}.") unless ALLOWED_EVIDENCE_STATUSES.include?(status)

  if STRUCTURED_SUBMIT_KINDS.include?(kind) && status == "pass"
    unless report.is_a?(Hash)
      submit_report_schema_error(
        "submit_report",
        "review/test PASS from-report must be a YAML mapping and satisfy the structured submit schema.",
        expected: "YAML mapping with full structured PASS fields",
        actual: evidence_value_type(report),
        kind: kind
      )
    end
    submitted_kind, submitted_status, summary, source_message_id, findings, coverage, artifacts, extra = validate_structured_submit_report!(report_path, report)
    unless submitted_kind == kind
      submit_report_schema_error(
        "submit_report.kind",
        "from-report kind must match the structured report kind.",
        expected: kind,
        actual: submitted_kind,
        kind: kind
      )
    end
    unless submitted_status == status
      submit_report_schema_error(
        "submit_report.verdict",
        "from-report status must match the structured report verdict.",
        expected: status,
        actual: submitted_status,
        kind: kind
      )
    end
    identity = require_evidence_submit_capability!(kind)
    record = {
      "kind" => submitted_kind,
      "status" => submitted_status,
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
    if report.key?("decision_record")
      normalized_dr = validate_decision_record!({ "decision_record" => report["decision_record"], "kind" => kind }, "from_report")
      record["decision_record"] = normalized_dr if normalized_dr
    end
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
      "schema_version" => "orbit-evidence-import-v1",
      "file" => path,
      "report" => report_path,
      "record" => record,
      "verdict" => updated_manifest["verdict"]
    })
    return
  end

  summary = options["summary"] || infer_report_summary(report_path, report)
  identity = require_evidence_submit_capability!(kind)
  record = {
    "kind" => kind,
    "status" => status,
    "summary" => summary.strip,
    "created_at" => Time.now.utc.iso8601,
    "source_report" => report_path
  }
  apply_structured_gate_defaults!(record, "report:#{report_path}")
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
    "schema_version" => "orbit-evidence-import-v1",
    "file" => path,
    "report" => report_path,
    "record" => record,
    "verdict" => updated_manifest["verdict"]
  })
end


require_relative "evidence_submit_validate"

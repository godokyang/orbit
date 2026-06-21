# frozen_string_literal: true

ALLOWED_EVIDENCE_STATUSES = %w[pass fail partial invalid].freeze
ALLOWED_EVIDENCE_VERDICT_STATUSES = (ALLOWED_EVIDENCE_STATUSES + %w[in_progress]).freeze
ALLOWED_EVIDENCE_KINDS = %w[review test command implementation waiver].freeze
STRUCTURED_SUBMIT_KINDS = %w[review test].freeze
ALLOWED_TEST_LEVELS = %w[unit integration repo_regression browser_e2e provider_e2e dogfood manual not_applicable].freeze
ALLOWED_REVIEW_QUALITY_OUTCOME_VERDICTS = %w[pass fail partial blocked unknown not_applicable].freeze
ALLOWED_EVIDENCE_LEVELS = %w[mechanical_check outcome_quality implementation_readiness].freeze
ALLOWED_RULE_APPLICATION_VERDICTS = %w[pass fail blocked not_applicable].freeze
ALLOWED_QUALITY_QUESTION_VERDICTS = %w[pass fail blocked not_applicable].freeze
ALLOWED_IMPLEMENTATION_READINESS_VERDICTS = %w[pass blocked not_checked].freeze
REQUIRED_FINDING_DETAIL_FIELDS = %w[symptom source consequence remedy].freeze
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
  extra = {}
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

# frozen_string_literal: true

ALLOWED_EVIDENCE_STATUSES = %w[pass fail partial invalid].freeze
ALLOWED_EVIDENCE_VERDICT_STATUSES = (ALLOWED_EVIDENCE_STATUSES + %w[in_progress]).freeze
ALLOWED_EVIDENCE_KINDS = %w[review test command implementation implementation_instance_override waiver].freeze
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
# Slice 14: negative evidence statuses.
ALLOWED_NEGATIVE_EVIDENCE_STATUSES = %w[not_tested not_applicable waived unknown].freeze
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
    when "--data-classification"
      options["data_classification"] = option_value(args, "--data-classification")
    when /\A--data-classification=(.+)\z/
      options["data_classification"] = Regexp.last_match(1)
    when "--retention-policy"
      options["retention_policy"] = option_value(args, "--retention-policy")
    when /\A--retention-policy=(.+)\z/
      options["retention_policy"] = Regexp.last_match(1)
    when "--trust-repair"
      options["trust_repair"] = option_value(args, "--trust-repair")
    when /\A--trust-repair=(.+)\z/
      options["trust_repair"] = Regexp.last_match(1)
    when "--waiver"
      options["waiver"] = option_value(args, "--waiver")
    when /\A--waiver=(.+)\z/
      options["waiver"] = Regexp.last_match(1)
    when "--from-instance"
      options["from_instance"] = option_value(args, "--from-instance")
    when /\A--from-instance=(.+)\z/
      options["from_instance"] = Regexp.last_match(1)
    when "--to-instance"
      options["to_instance"] = option_value(args, "--to-instance")
    when /\A--to-instance=(.+)\z/
      options["to_instance"] = Regexp.last_match(1)
    when "--reason"
      options["reason"] = option_value(args, "--reason")
    when /\A--reason=(.+)\z/
      options["reason"] = Regexp.last_match(1)
    when "--expires-at"
      options["expires_at"] = option_value(args, "--expires-at")
    when /\A--expires-at=(.+)\z/
      options["expires_at"] = Regexp.last_match(1)
    when "--no-expiry"
      options["no_expiry"] = true
    when "--authorized-by-role", "--authorized-by-instance"
      option_value(args, arg)
      usage_error("#{arg} is derived from current identity and cannot be supplied.")
    when /\A--authorized-by-(?:role|instance)=/
      usage_error("#{arg.split("=").first} is derived from current identity and cannot be supplied.")
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
    %w[file kind].each do |name|
      usage_error("Missing required option: --#{name}") if options[name].nil? || options[name].empty?
    end
    unless options["kind"] == "implementation_instance_override"
      %w[status summary].each do |name|
        usage_error("Missing required option: --#{name}") if options[name].nil? || options[name].empty?
      end
    end
    if options["kind"] == "implementation" && options["task"].to_s.empty?
      usage_error("evidence add --kind implementation requires --task so Orbit can enforce execution_contract.")
    end
    if options["kind"] == "implementation_instance_override"
      %w[task from_instance to_instance reason].each do |name|
        usage_error("Missing required option: --#{name.tr("_", "-")}") if options[name].to_s.empty?
      end
      usage_error("implementation_instance_override requires --expires-at or --no-expiry.") if options["expires_at"].to_s.empty? && options["no_expiry"] != true
      usage_error("implementation_instance_override cannot use both --expires-at and --no-expiry.") if !options["expires_at"].to_s.empty? && options["no_expiry"] == true
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
    usage_error("Missing required option: --task") if options["task"].nil? || options["task"].empty?
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
    "skills/orbit/assets/templates/review-report.yaml"
  when "test"
    "skills/orbit/assets/templates/test-report.yaml"
  else
    "skills/orbit/assets/templates/review-report.yaml or skills/orbit/assets/templates/test-report.yaml"
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
    "actual_client" => identity["actual_client"]
  }.compact
end

def evidence_runtime_attribution(identity)
  return nil unless identity.is_a?(Hash)

  instance = (identity["resolved_instance"] || identity["instance"]).to_s
  return nil if instance.empty?

  runtime_current_process_session_attribution(identity)
end

def structured_role_execution_context(identity, evidence_path, task_path: nil, report: nil, rules_context_sha256: nil)
  return nil unless identity.is_a?(Hash)

  snapshot = evidence_identity_snapshot(identity)
  manifest_preview = load_evidence_manifest(evidence_path) rescue nil
  rule_res_file = manifest_preview.is_a?(Hash) && manifest_preview["rule_resolution"].is_a?(Hash) ? manifest_preview["rule_resolution"]["file"] : nil
  computed_rules_sha = (rule_res_file.is_a?(String) && !rule_res_file.empty?) ? sha256_file(rule_res_file) : nil
  effective_rules_sha = rules_context_sha256 || computed_rules_sha
  git_head = capture_git_head
  dirty = capture_git_dirty_files
  write_policy_expected = report.is_a?(Hash) && report["write_policy"].is_a?(Hash) ? report.dig("write_policy", "expected") : nil
  worktree = { "git_head" => git_head }.tap { |wt| wt["dirty_files_before"] = dirty unless dirty.empty? }.compact
  permission_profile = {
    "mode" => "audit_only",
    "write_policy" => write_policy_expected || "no_production_writes",
    "sandbox" => "none"
  }
  {
    "instance" => snapshot["instance"] || snapshot["resolved_instance"],
    "resolved_role" => snapshot["resolved_role"],
    "role_ref" => snapshot["role_ref"],
    "role_config_sha256" => sha256_file(File.join(Dir.pwd, ".orbit", "roles.yaml")),
    "rules_resolution_sha256" => effective_rules_sha,
    "rules_context_sha256" => effective_rules_sha,
    "task_sha256" => task_path ? sha256_file(File.expand_path(task_path)) : nil,
    "evidence_manifest_sha256_before_submit" => File.file?(evidence_path) ? sha256_file(evidence_path) : nil,
    "worktree" => worktree.empty? ? nil : worktree,
    "permission_profile" => permission_profile
  }.compact
end

def load_task_for_evidence!(task_path)
  task = load_yaml(File.expand_path(task_path))
  evidence_error("Task file must contain a mapping: #{task_path}") unless task.is_a?(Hash)
  task["__orbit_path"] = File.expand_path(task_path)
  evidence_error("Task must define execution_contract.") unless task["execution_contract"].is_a?(Hash)
  task
rescue RuntimeError => e
  evidence_error(e.message)
end

def implementation_role_execution_context!(task_path, evidence_path = nil)
  task = load_task_for_evidence!(task_path)
  identity = evidence_runtime_identity!
  contract = task_execution_contract(task)
  resolved_role = identity["resolved_role"]
  resolved_instance = identity["resolved_instance"] || identity["instance"]
  evidence = evidence_path && File.file?(evidence_path) ? load_evidence_manifest(evidence_path) : nil
  override = valid_implementation_override_for_identity(task, evidence, resolved_role, resolved_instance)
  unless (resolved_role == contract["implementation_authority"] && resolved_instance == contract["assigned_instance"]) || override
    evidence_error("implementation evidence requires #{contract["implementation_authority"].inspect}/#{contract["assigned_instance"].inspect}; current identity is #{resolved_role.inspect}/#{resolved_instance.inspect}.")
  end

  {
    "task" => File.expand_path(task_path),
    "task_sha256" => sha256_file(File.expand_path(task_path)),
    "instance" => identity["instance"],
    "resolved_instance" => resolved_instance,
    "resolved_role" => resolved_role,
    "role_ref" => identity["role_ref"],
    "owner_role" => contract["owner_role"],
    "owner_instance" => contract["owner_instance"],
    "operation_mode" => contract["operation_mode"],
    "implementation_authority" => contract["implementation_authority"],
    "assigned_instance" => contract["assigned_instance"],
    "execution_contract_source" => contract["source"],
    "override" => override ? {
      "from_instance" => override["from_instance"],
      "to_instance" => override["to_instance"],
      "authorized_by_role" => override["authorized_by_role"],
      "authorized_by_instance" => override["authorized_by_instance"],
      "created_at" => override["created_at"],
      "expires_at" => override["expires_at"],
      "no_expiry" => override["no_expiry"]
    }.compact : nil,
    "source" => "evidence_add"
  }.compact
end

def parse_override_expiry!(expires_at)
  return nil if expires_at.to_s.empty?

  Time.iso8601(expires_at)
rescue ArgumentError
  evidence_error("--expires-at must be ISO8601.")
end

def implementation_instance_override_record!(options)
  task_path = File.expand_path(options["task"])
  task = load_task_for_evidence!(task_path)
  identity = evidence_runtime_identity!
  contract = task_execution_contract(task)
  authorized_role = identity["resolved_role"]
  authorized_instance = identity["resolved_instance"] || identity["instance"]
  unless authorized_role == contract["owner_role"] && authorized_instance == contract["owner_instance"]
    evidence_error("implementation_instance_override requires owner identity #{contract["owner_role"].inspect}/#{contract["owner_instance"].inspect}; current identity is #{authorized_role.inspect}/#{authorized_instance.inspect}.")
  end

  from_instance = options["from_instance"].to_s
  to_instance = options["to_instance"].to_s
  evidence_error("--from-instance must equal task assigned_instance #{contract["assigned_instance"].inspect}.") unless from_instance == contract["assigned_instance"]

  roles, instances = load_project_instance_config_for_cli[0, 2]
  to_role = role_for_instance(instances, roles, to_instance)
  evidence_error("--to-instance #{to_instance.inspect} resolves to #{to_role.inspect}, not #{contract["implementation_authority"].inspect}.") unless to_role == contract["implementation_authority"]
  expiry = parse_override_expiry!(options["expires_at"])

  {
    "kind" => "implementation_instance_override",
    "status" => "pass",
    "summary" => options["summary"].to_s.empty? ? options["reason"].to_s : options["summary"].to_s,
    "task" => task_path,
    "task_sha256" => sha256_file(task_path),
    "from_role" => contract["implementation_authority"],
    "from_instance" => from_instance,
    "to_role" => to_role,
    "to_instance" => to_instance,
    "authorized_by_role" => authorized_role,
    "authorized_by_instance" => authorized_instance,
    "reason" => options["reason"].to_s,
    "created_at" => Time.now.utc.iso8601,
    "expires_at" => expiry&.utc&.iso8601,
    "no_expiry" => options["no_expiry"] == true
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

  nil
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
  if STRUCTURED_SUBMIT_KINDS.include?(options["kind"])
    evidence_error("#{options["kind"]} evidence must be submitted with evidence submit --report <structured-yaml>.")
  end
  identity = require_evidence_submit_capability!(options["kind"])
  record = if options["kind"] == "implementation_instance_override"
             implementation_instance_override_record!(options)
           else
             {
               "kind" => options["kind"],
               "status" => options["status"],
               "summary" => options["summary"].strip,
               "created_at" => Time.now.utc.iso8601
             }
           end
  apply_structured_gate_defaults!(record, "manual:evidence-add:#{record["created_at"]}")
  if options["kind"] == "implementation"
    record["role_execution_context"] = implementation_role_execution_context!(options["task"], path)
  elsif STRUCTURED_SUBMIT_KINDS.include?(options["kind"])
    rec_ctx = structured_role_execution_context(identity, path, task_path: options["task"])
    record["role_execution_context"] = rec_ctx if rec_ctx
  end
  if %w[implementation review test].include?(options["kind"])
    runtime_identity = evidence_runtime_attribution(identity || evidence_runtime_identity!)
    record["runtime_identity"] = runtime_identity if runtime_identity
  end
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
  # Slice 12: parse --data-classification, --retention-policy, --trust-repair (JSON/YAML string or @file).
  %w[data_classification retention_policy trust_repair].each do |field|
    next unless options[field]
    raw = if options[field].start_with?("@")
            fpath = File.expand_path(options[field][1..])
            evidence_error("--#{field.tr('_', '-')} file not found: #{fpath}") unless File.file?(fpath)
            File.read(fpath)
          else
            options[field]
          end
    begin
      parsed = raw.strip.start_with?("{") ? JSON.parse(raw) : YAML.safe_load(raw)
    rescue JSON::ParserError, Psych::SyntaxError
      evidence_error("--#{field.tr('_', '-')} must be valid JSON or YAML mapping.")
    end
    case field
    when "data_classification"
      dc = normalize_data_classification(parsed, "evidence_add", options["kind"])
      evidence_error("--data-classification must be a mapping with categories, sensitivity, or redaction.") unless dc.is_a?(Hash)
      record["data_classification"] = dc
    when "retention_policy"
      rp = normalize_retention_policy(parsed, "evidence_add", options["kind"])
      evidence_error("--retention-policy must be a mapping with mode, expires_at, or user_approved.") unless rp.is_a?(Hash)
      record["retention_policy"] = rp
    when "trust_repair"
      tr = normalize_trust_repair(parsed, "evidence_add", options["kind"])
      evidence_error("--trust-repair must be a mapping with incident_id, impact, recovery, or prevention.") unless tr.is_a?(Hash)
      record["trust_repair"] = tr
    end
  end
  apply_default_data_policy!(record)
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

  return "pass" if token == "PASS"
  return "fail" if token == "FAIL"
  return "partial" if %w[BLOCKED PARTIAL].include?(token)
  return "invalid" if token == "INVALID"

  nil
end

def status_from_report_line(line)
  stripped = line.to_s.strip.sub(/\A#+\s*/, "")
  match = stripped.match(/\AVERDICT\s*:\s*([A-Za-z_]+)\z/i)
  match ? normalize_report_status(match[1]) : nil
end

def infer_report_status(report)
  if report.is_a?(Hash)
    return normalize_report_status(report["verdict"])
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
  if STRUCTURED_SUBMIT_KINDS.include?(kind)
    evidence_error("#{kind} evidence must be submitted with evidence submit --report <structured-yaml>.")
  end
  if kind == "implementation"
    evidence_error("evidence from-report cannot create implementation evidence; use evidence add --kind implementation --task PATH so Orbit can enforce execution_contract.")
  end

  status = options["status"] || infer_report_status(report)
  evidence_error("Could not infer report status; pass --status #{ALLOWED_EVIDENCE_STATUSES.join("|")}.") unless ALLOWED_EVIDENCE_STATUSES.include?(status)

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
  apply_default_data_policy!(record)
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

# frozen_string_literal: true

TEST_HOOKS_SCHEMA_VERSION = "orbit-test-hooks-v1"
USER_JOURNEY_REQUIRED_FIELDS = %w[id actor surface required_evidence test_hook].freeze
USER_JOURNEY_ARTIFACT_FIELDS = %w[screenshots crash_logs network_requests media_state logs].freeze

def project_test_hooks_path
  File.join(Dir.pwd, ".orbit", "test-hooks.yaml")
end

def test_hook_command_valid?(command)
  command.is_a?(Array) && !command.empty? && command.all? { |part| part.is_a?(String) && !part.strip.empty? }
end

def load_project_test_hooks
  path = project_test_hooks_path
  return { "schema_version" => TEST_HOOKS_SCHEMA_VERSION, "hooks" => {} } unless File.file?(path)

  config = load_yaml(path)
  config.is_a?(Hash) ? config : {}
rescue RuntimeError
  {}
end

def validate_project_test_hooks_config(result)
  path = project_test_hooks_path
  unless File.file?(path)
    validation_warning(result, "project_config.test_hooks", ".orbit/test-hooks.yaml is missing; real-path tasks cannot become execution-ready until a project hook is configured.")
    return
  end

  config = load_validation_file(result, "project_config.test_hooks", path)
  return unless config

  unless config["schema_version"] == TEST_HOOKS_SCHEMA_VERSION
    validation_error(result, "project_config.test_hooks.schema_version", "test-hooks schema_version must be #{TEST_HOOKS_SCHEMA_VERSION}.")
  end
  hooks = config["hooks"]
  unless hooks.is_a?(Hash)
    validation_error(result, "project_config.test_hooks.hooks", "test-hooks hooks must be a mapping.")
    return
  end

  hooks.each do |id, hook|
    source = "project_config.test_hooks.hooks.#{id}"
    unless id.is_a?(String) && !id.strip.empty? && hook.is_a?(Hash)
      validation_error(result, source, "Each test hook must have a non-empty id and mapping definition.")
      next
    end
    validation_error(result, "#{source}.command", "Test hook command must be a non-empty argv list.") unless test_hook_command_valid?(hook["command"])
    surfaces = hook["surfaces"]
    unless surfaces.is_a?(Array) && !surfaces.empty? && surfaces.all? { |surface| surface.is_a?(String) && !surface.strip.empty? }
      validation_error(result, "#{source}.surfaces", "Test hook surfaces must be a non-empty list.")
    end
    provider = hook["evidence_provider"]
    unless provider.is_a?(String) && !provider.strip.empty?
      validation_error(result, "#{source}.evidence_provider", "Test hook evidence_provider must be a non-empty string.")
    end
  end
end

def task_user_journeys(task)
  task.is_a?(Hash) && task["user_journeys"].is_a?(Array) ? task["user_journeys"] : []
end

def validate_task_user_journeys(result, task)
  journeys = task["user_journeys"]
  if journeys.nil?
    validation_warning(result, "task_file.user_journeys", "Task should define user_journeys; use an empty list when no real user path applies.")
    return
  end
  unless journeys.is_a?(Array)
    validation_error(result, "task_file.user_journeys", "Task user_journeys must be a list.")
    return
  end

  seen = {}
  journeys.each_with_index do |journey, index|
    source = "task_file.user_journeys[#{index}]"
    unless journey.is_a?(Hash)
      validation_error(result, source, "User journey must be a mapping.")
      next
    end
    USER_JOURNEY_REQUIRED_FIELDS.each do |field|
      value = journey[field]
      unless value.is_a?(String) && !value.strip.empty?
        validation_error(result, "#{source}.#{field}", "User journey #{field} must be a non-empty string.")
      end
    end
    %w[steps expected_observables].each do |field|
      value = journey[field]
      unless value.is_a?(Array) && !value.empty? && value.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
        validation_error(result, "#{source}.#{field}", "User journey #{field} must be a non-empty list of strings.")
      end
    end
    id = journey["id"].to_s
    if !id.empty? && seen[id]
      validation_error(result, "#{source}.id", "User journey ids must be unique; duplicate #{id.inspect}.")
    end
    seen[id] = true unless id.empty?
    required_evidence = journey["required_evidence"].to_s
    unless required_evidence.empty? || ALLOWED_TEST_LEVELS.include?(required_evidence) || ALLOWED_EVIDENCE_LEVELS.include?(required_evidence)
      validation_error(result, "#{source}.required_evidence", "User journey required_evidence must be a known test_level or evidence_level.")
    end
  end
end

def configured_test_hook_for(journey)
  return nil unless journey.is_a?(Hash)

  config = load_project_test_hooks
  hooks = config["hooks"].is_a?(Hash) ? config["hooks"] : {}
  hook = hooks[journey["test_hook"]]
  return nil unless hook.is_a?(Hash) && hook["enabled"] != false && test_hook_command_valid?(hook["command"])

  surfaces = hook["surfaces"]
  return nil unless surfaces.is_a?(Array) && (surfaces.include?("*") || surfaces.include?(journey["surface"]))

  hook
end

def user_journey_execution_readiness_errors(task)
  return [] unless task.is_a?(Hash) && task["real_path_required"] == true

  journeys = task_user_journeys(task)
  return ["real_path_required tasks must define at least one user_journey"] if journeys.empty?

  journeys.each_with_object([]) do |journey, errors|
    id = journey.is_a?(Hash) ? journey["id"].to_s : "unknown"
    next if configured_test_hook_for(journey)

    errors << "user_journey #{id.inspect} must reference an enabled project test hook whose surfaces include #{journey.is_a?(Hash) ? journey["surface"].inspect : "the journey surface"}"
  end
end

def user_outcome_environment_present?(environment)
  return false unless environment.is_a?(Hash)

  %w[device browser services].any? do |field|
    value = environment[field]
    (value.is_a?(String) && !value.strip.empty?) || (value.is_a?(Hash) && !value.empty?) || (value.is_a?(Array) && !value.empty?)
  end
end

def user_outcome_artifact_references(outcome)
  artifacts = outcome.is_a?(Hash) ? outcome["artifacts"] : nil
  return [] unless artifacts.is_a?(Hash)

  USER_JOURNEY_ARTIFACT_FIELDS.flat_map do |field|
    value = artifacts[field]
    value.is_a?(Array) ? value.select { |entry| entry.is_a?(String) && !entry.strip.empty? } : []
  end
end

def valid_actual_steps?(value)
  value.is_a?(Array) && !value.empty? && value.all? do |entry|
    (entry.is_a?(String) && !entry.strip.empty?) ||
      (entry.is_a?(Hash) && entry["step"].is_a?(String) && !entry["step"].strip.empty? && entry["result"].is_a?(String) && !entry["result"].strip.empty?)
  end
end

def validate_user_outcomes_report!(value, kind: "test")
  unless value.is_a?(Array)
    submit_report_schema_error(
      "submit_report.user_outcomes",
      "user_outcomes must be a list.",
      expected: "list of journey outcome mappings",
      actual: evidence_value_type(value),
      kind: kind
    )
  end
  value.each_with_index do |outcome, index|
    source = "submit_report.user_outcomes[#{index}]"
    unless outcome.is_a?(Hash)
      submit_report_schema_error(source, "User outcome must be a mapping.", expected: "mapping", actual: evidence_value_type(outcome), kind: kind)
    end
    %w[journey_id verdict].each do |field|
      report_string!(outcome, field, source, kind: kind)
    end
    unless %w[pass fail partial blocked].include?(outcome["verdict"])
      submit_report_schema_error("#{source}.verdict", "User outcome verdict must be pass|fail|partial|blocked.", expected: "pass|fail|partial|blocked", actual: outcome["verdict"], kind: kind)
    end
    unless valid_actual_steps?(outcome["actual_steps"])
      submit_report_schema_error("#{source}.actual_steps", "actual_steps must record non-empty steps and results.", expected: "non-empty list of strings or {step,result}", actual: evidence_value_type(outcome["actual_steps"]), kind: kind)
    end
    validate_string_array!(outcome["observed_results"], "#{source}.observed_results", kind: kind)
    validate_string_array!(outcome["uncovered_paths"], "#{source}.uncovered_paths", kind: kind)
    artifacts = outcome["artifacts"]
    unless artifacts.is_a?(Hash)
      submit_report_schema_error("#{source}.artifacts", "User outcome artifacts must be a mapping.", expected: USER_JOURNEY_ARTIFACT_FIELDS.join("|"), actual: evidence_value_type(artifacts), kind: kind)
    end
    artifacts.each do |field, entries|
      next unless USER_JOURNEY_ARTIFACT_FIELDS.include?(field)
      validate_string_array!(entries, "#{source}.artifacts.#{field}", kind: kind)
    end
    unless user_outcome_environment_present?(outcome["environment"])
      submit_report_schema_error("#{source}.environment", "User outcome environment must identify device, browser, or service versions.", expected: "mapping with device|browser|services", actual: evidence_value_type(outcome["environment"]), kind: kind)
    end
    hook = outcome["test_hook"]
    unless hook.is_a?(Hash) && hook["id"].is_a?(String) && !hook["id"].strip.empty? && hook["status"] == "pass" && test_hook_command_valid?(hook["command"])
      submit_report_schema_error("#{source}.test_hook", "User outcome test_hook must record id, pass status, and command argv.", expected: "{id, status: pass, command: [...]}", actual: evidence_value_type(hook), kind: kind)
    end
  end
  value
end

def validate_user_outcomes_record(result, source, record)
  return unless record.key?("user_outcomes")

  outcomes = record["user_outcomes"]
  unless outcomes.is_a?(Array)
    validation_error(result, "#{source}.user_outcomes", "user_outcomes must be a list.")
    return
  end
  outcomes.each_with_index do |outcome, index|
    item_source = "#{source}.user_outcomes[#{index}]"
    unless outcome.is_a?(Hash)
      validation_error(result, item_source, "User outcome must be a mapping.")
      next
    end
    %w[journey_id verdict].each do |field|
      value = outcome[field]
      validation_error(result, "#{item_source}.#{field}", "User outcome #{field} must be a non-empty string.") unless value.is_a?(String) && !value.strip.empty?
    end
    validation_error(result, "#{item_source}.actual_steps", "User outcome actual_steps are invalid.") unless valid_actual_steps?(outcome["actual_steps"])
    unless outcome["observed_results"].is_a?(Array) && outcome["observed_results"].all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
      validation_error(result, "#{item_source}.observed_results", "User outcome observed_results must be a list of strings.")
    end
    validation_error(result, "#{item_source}.environment", "User outcome environment must identify device, browser, or services.") unless user_outcome_environment_present?(outcome["environment"])
  end
end

def journey_required_evidence_satisfied?(journey, record)
  required = journey["required_evidence"].to_s
  return record["test_level"] == required if ALLOWED_TEST_LEVELS.include?(required)
  return evidence_level_satisfies_minimum?(record["evidence_level"], required) if ALLOWED_EVIDENCE_LEVELS.include?(required)

  false
end

def user_journey_evidence_assessment(task, record)
  return { "required" => false, "valid" => true, "status" => "not_applicable" } unless task.is_a?(Hash) && task["real_path_required"] == true

  outcomes = record.is_a?(Hash) && record["user_outcomes"].is_a?(Array) ? record["user_outcomes"] : []
  failures = []
  journeys = task_user_journeys(task)
  failures << { "journey_id" => nil, "reason" => "missing_user_journey_contract" } if journeys.empty?
  journeys.each do |journey|
    id = journey["id"].to_s
    outcome = outcomes.reverse.find { |entry| entry.is_a?(Hash) && entry["journey_id"] == id }
    unless outcome
      failures << { "journey_id" => id, "reason" => "missing_user_journey_evidence" }
      next
    end
    failures << { "journey_id" => id, "reason" => "user_journey_not_passed" } unless outcome["verdict"] == "pass"
    failures << { "journey_id" => id, "reason" => "missing_actual_steps" } unless valid_actual_steps?(outcome["actual_steps"])
    observed = outcome["observed_results"]
    failures << { "journey_id" => id, "reason" => "missing_observed_results" } unless observed.is_a?(Array) && !observed.empty?
    failures << { "journey_id" => id, "reason" => "missing_real_path_artifact" } if user_outcome_artifact_references(outcome).empty?
    failures << { "journey_id" => id, "reason" => "missing_environment_versions" } unless user_outcome_environment_present?(outcome["environment"])
    uncovered = outcome["uncovered_paths"]
    failures << { "journey_id" => id, "reason" => "required_path_uncovered" } unless uncovered.is_a?(Array) && uncovered.empty?
    hook = outcome["test_hook"]
    expected_hook = journey["test_hook"]
    configured_hook = configured_test_hook_for(journey)
    unless configured_hook && hook.is_a?(Hash) && hook["id"] == expected_hook && hook["status"] == "pass" && hook["command"] == configured_hook["command"]
      failures << { "journey_id" => id, "reason" => "test_hook_not_passed" }
    end
    failures << { "journey_id" => id, "reason" => "insufficient_journey_evidence_level" } unless journey_required_evidence_satisfied?(journey, record)
  end
  first_reason = failures.first && failures.first["reason"]
  {
    "required" => true,
    "valid" => failures.empty?,
    "status" => failures.empty? ? "pass" : "partial",
    "blocking_reason" => first_reason,
    "failures" => failures,
    "journey_ids" => journeys.map { |journey| journey["id"] }
  }.compact
end

def parse_test_hook_args(args)
  subcommand = args.shift
  usage_error("test-hook requires run subcommand.") unless subcommand == "run"
  options = { "json" => false, "dry_run" => false }
  until args.empty?
    arg = args.shift
    case arg
    when "--task" then options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/ then options["task"] = Regexp.last_match(1)
    when "--journey" then options["journey"] = option_value(args, "--journey")
    when /\A--journey=(.+)\z/ then options["journey"] = Regexp.last_match(1)
    when "--dry-run" then options["dry_run"] = true
    when "--json" then options["json"] = true
    else usage_error("Unknown test-hook option: #{arg}")
    end
  end
  %w[task journey].each { |field| usage_error("test-hook run requires --#{field}.") if options[field].to_s.empty? }
  usage_error("test-hook run currently requires --json.") unless options["json"]
  options
end

def test_hook(args)
  options = parse_test_hook_args(args)
  task_path = File.expand_path(options["task"])
  task = load_yaml(task_path)
  journey = task_user_journeys(task).find { |entry| entry.is_a?(Hash) && entry["id"] == options["journey"] }
  usage_error("Unknown task user journey #{options["journey"].inspect}.") unless journey
  hook = configured_test_hook_for(journey)
  usage_error("Journey #{options["journey"].inspect} has no enabled compatible project test hook.") unless hook
  command = hook["command"]
  started = Time.now.utc
  stdout = ""
  stderr = ""
  success = true
  exit_status = nil
  unless options["dry_run"]
    env = {
      "ORBIT_TASK" => task_path,
      "ORBIT_JOURNEY_ID" => journey["id"],
      "ORBIT_JOURNEY_SURFACE" => journey["surface"]
    }
    stdout, stderr, status = Open3.capture3(env, *command, chdir: Dir.pwd)
    success = status.success?
    exit_status = status.exitstatus
  end
  packet = {
    "schema_version" => "orbit-test-hook-run-v1",
    "task" => task_path,
    "journey_id" => journey["id"],
    "surface" => journey["surface"],
    "hook_id" => journey["test_hook"],
    "evidence_provider" => hook["evidence_provider"],
    "command" => command,
    "dry_run" => options["dry_run"],
    "status" => options["dry_run"] ? "planned" : (success ? "pass" : "fail"),
    "exit_status" => exit_status,
    "stdout" => stdout,
    "stderr" => stderr,
    "duration_ms" => ((Time.now.utc - started) * 1000).round
  }.compact
  puts JSON.pretty_generate(packet)
  exit 1 unless success
end

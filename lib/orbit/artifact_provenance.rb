# frozen_string_literal: true

ARTIFACT_LIFECYCLES = %w[transient durable].freeze
ARTIFACT_REQUIRED_FIELDS = %w[id path sha256 producer_command created_at git_head task_id task_revision lifecycle].freeze

def artifact_provenance_required?(task)
  task.is_a?(Hash) && task.dig("artifact_provenance", "required") == true
end

def artifact_current_git_head
  stdout, _stderr, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: Dir.pwd)
  return "not_git" unless status.success?

  value = stdout.to_s.strip
  value.empty? ? "not_git" : value
rescue SystemCallError
  "not_git"
end

def artifact_task_revision(task, task_path = nil)
  return task["revision_id"] if task_revision_frozen?(task)

  path = task_path || (task.is_a?(Hash) ? task["__orbit_path"] : nil)
  path && File.file?(path) ? "sha256:#{sha256_file(path)}" : ""
end

def artifact_relative_path?(path)
  return false unless path.is_a?(String) && !path.strip.empty?
  return false if Pathname.new(path).absolute?
  return false if path.split(/[\\\/]/).include?("..")

  parts = Pathname.new(path).cleanpath.each_filename.to_a
  !parts.include?("..") && path != "."
rescue ArgumentError
  false
end

def artifact_producer_valid?(value)
  (value.is_a?(String) && !value.strip.empty?) ||
    (value.is_a?(Array) && !value.empty? && value.all? { |part| part.is_a?(String) && !part.strip.empty? })
end

def artifact_reference_shape_errors(ref)
  return ["artifact ref must be a mapping"] unless ref.is_a?(Hash)

  errors = []
  ARTIFACT_REQUIRED_FIELDS.each do |field|
    value = ref[field]
    valid = if field == "producer_command"
              artifact_producer_valid?(value)
            else
              value.is_a?(String) && !value.strip.empty?
            end
    errors << "#{field} is required" unless valid
  end
  errors << "path must be project-relative and cannot contain .." unless artifact_relative_path?(ref["path"])
  errors << "sha256 must be a 64-character lowercase hash" unless ref["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
  errors << "lifecycle must be transient or durable" unless ARTIFACT_LIFECYCLES.include?(ref["lifecycle"])
  begin
    Time.iso8601(ref["created_at"].to_s)
  rescue ArgumentError
    errors << "created_at must be ISO8601"
  end
  errors
end

def artifact_revision_eligible?(ref, task, evidence_kind)
  return false unless task_revision_frozen?(task)
  return false unless ref["task_id"] == task["task_id"]

  entry = Array(task["revision_history"]).find do |revision|
    revision.is_a?(Hash) && (
      revision["revision_id"] == ref["task_revision"] ||
      "sha256:#{revision["pre_freeze_task_sha256"]}" == ref["task_revision"]
    )
  end
  return false unless entry

  revision_entries_after(task, entry["number"]).none? do |later|
    Array(later["invalidated_evidence"]).include?(evidence_kind)
  end
end

def artifact_reference_fact_errors(ref, task, task_path = nil, evidence_kind: nil)
  errors = artifact_reference_shape_errors(ref)
  return errors unless ref.is_a?(Hash) && artifact_relative_path?(ref["path"])

  absolute = File.expand_path(ref["path"], Dir.pwd)
  root = File.realpath(Dir.pwd)
  real_artifact = File.realpath(absolute) rescue nil
  unless real_artifact && real_artifact.start_with?("#{root}/") && File.file?(real_artifact)
    errors << "artifact file does not exist inside the project"
    return errors
  end
  actual_hash = sha256_file(real_artifact)
  errors << "artifact sha256 does not match current file bytes" unless ref["sha256"] == actual_hash
  expected_git_head = artifact_current_git_head
  errors << "artifact git_head does not match current checkout" unless ref["git_head"] == expected_git_head
  expected_revision = artifact_task_revision(task, task_path)
  errors << "artifact task_id does not match the current task" unless task_id_valid?(task["task_id"]) && ref["task_id"] == task["task_id"]
  revision_matches = !expected_revision.empty? && ref["task_revision"] == expected_revision
  revision_matches ||= artifact_revision_eligible?(ref, task, evidence_kind) if evidence_kind
  errors << "artifact task_revision does not match the current task" unless revision_matches
  begin
    declared = Time.iso8601(ref["created_at"].to_s)
    file_time = File.mtime(real_artifact).utc
    errors << "artifact created_at predates the current file contents" if declared + 1 < file_time
    errors << "artifact created_at is in the future" if declared > Time.now.utc + 300
  rescue ArgumentError
    nil
  end
  errors
end

def validate_task_artifact_provenance(result, task)
  contract = task["artifact_provenance"]
  if contract.nil?
    validation_warning(result, "task_file.artifact_provenance", "Task should define artifact_provenance; new real-path tasks require structured artifact refs.")
    return
  end
  unless contract.is_a?(Hash)
    validation_error(result, "task_file.artifact_provenance", "artifact_provenance must be a mapping.")
    return
  end
  %w[required require_implementation_facts require_gate_cross_reference].each do |field|
    value = contract[field]
    validation_error(result, "task_file.artifact_provenance.#{field}", "artifact_provenance.#{field} must be true or false.") unless [true, false].include?(value)
  end
end

def validate_artifact_refs_report!(value, kind: nil)
  unless value.is_a?(Array)
    submit_report_schema_error("submit_report.artifact_refs", "artifact_refs must be a list.", expected: "list of artifact mappings", actual: evidence_value_type(value), kind: kind)
  end
  value.each_with_index do |ref, index|
    errors = artifact_reference_shape_errors(ref)
    next if errors.empty?

    submit_report_schema_error(
      "submit_report.artifact_refs[#{index}]",
      "Invalid artifact ref: #{errors.join("; ")}.",
      expected: ARTIFACT_REQUIRED_FIELDS.join("|"),
      actual: evidence_value_type(ref),
      kind: kind
    )
  end
  value
end

def validate_implementation_artifact_refs_report!(value, kind: nil)
  unless value.is_a?(Array) && value.all? { |id| id.is_a?(String) && !id.strip.empty? }
    submit_report_schema_error(
      "submit_report.implementation_artifact_refs",
      "implementation_artifact_refs must be a list of artifact ids.",
      expected: "list of non-empty strings",
      actual: evidence_value_type(value),
      kind: kind
    )
  end
  value
end

def validate_artifact_refs_record(result, source, record)
  refs = record["artifact_refs"]
  if refs
    unless refs.is_a?(Array)
      validation_error(result, "#{source}.artifact_refs", "artifact_refs must be a list.")
    else
      refs.each_with_index do |ref, index|
        artifact_reference_shape_errors(ref).each do |message|
          validation_error(result, "#{source}.artifact_refs[#{index}]", message)
        end
      end
    end
  end
  impl_refs = record["implementation_artifact_refs"]
  if impl_refs && !(impl_refs.is_a?(Array) && impl_refs.all? { |id| id.is_a?(String) && !id.strip.empty? })
    validation_error(result, "#{source}.implementation_artifact_refs", "implementation_artifact_refs must be a list of non-empty ids.")
  end
  facts = record["implementation_facts"]
  return unless facts

  unless facts.is_a?(Hash)
    validation_error(result, "#{source}.implementation_facts", "implementation_facts must be a mapping.")
    return
  end
  changed = facts["changed_files"]
  verification = facts["verification"]
  no_change = facts["no_change_reason"]
  unless changed.is_a?(Array) && changed.all? { |path| artifact_relative_path?(path) }
    validation_error(result, "#{source}.implementation_facts.changed_files", "changed_files must be a list of project-relative paths.")
  end
  unless verification.is_a?(Array) && verification.all? { |item| item.is_a?(String) && !item.strip.empty? }
    validation_error(result, "#{source}.implementation_facts.verification", "verification must be a list of non-empty strings.")
  end
  if changed.is_a?(Array) && changed.empty? && !(no_change.is_a?(String) && !no_change.strip.empty?)
    validation_error(result, "#{source}.implementation_facts.no_change_reason", "Implementation pass with no changed files requires no_change_reason.")
  end
end

def current_implementation_artifact_record(manifest, task, task_path = nil)
  records = manifest.is_a?(Hash) && manifest["records"].is_a?(Array) ? manifest["records"] : []
  task_revision = artifact_task_revision(task, task_path)
  records.reverse.find do |entry|
    next false unless entry.is_a?(Hash) && entry["kind"] == "implementation" && entry["status"] == "pass"

    if task_revision_frozen?(task)
      evidence_record_revision_eligible?(entry, task, "implementation")
    else
      task_revision.empty? || "sha256:#{entry.dig("role_execution_context", "task_sha256")}" == task_revision
    end
  end
end

def current_implementation_artifact_ids(manifest, task, task_path = nil)
  record = current_implementation_artifact_record(manifest, task, task_path)
  Array(record && record["artifact_refs"]).map { |ref| ref.is_a?(Hash) ? ref["id"] : nil }.compact
end

def artifact_provenance_assessment(task, record, manifest: nil, task_path: nil)
  required = artifact_provenance_required?(task)
  refs = record.is_a?(Hash) && record["artifact_refs"].is_a?(Array) ? record["artifact_refs"] : []
  failures = []
  refs.each do |ref|
    artifact_reference_fact_errors(ref, task, task_path, evidence_kind: record["kind"]).each do |message|
      failures << { "artifact_id" => ref.is_a?(Hash) ? ref["id"] : nil, "reason" => message }
    end
  end
  kind = record.is_a?(Hash) ? record["kind"] : nil
  if required && record["status"] == "pass" && %w[implementation review test].include?(kind)
    failures << { "reason" => "missing_structured_artifact_refs" } if refs.empty?
    if kind == "implementation" && task.dig("artifact_provenance", "require_implementation_facts") == true
      facts = record["implementation_facts"]
      changed = facts.is_a?(Hash) ? facts["changed_files"] : nil
      verification = facts.is_a?(Hash) ? facts["verification"] : nil
      no_change = facts.is_a?(Hash) ? facts["no_change_reason"] : nil
      facts_valid = changed.is_a?(Array) && verification.is_a?(Array) && !verification.empty? && (!changed.empty? || (no_change.is_a?(String) && !no_change.strip.empty?))
      failures << { "reason" => "missing_implementation_facts" } unless facts_valid
    end
    if %w[review test].include?(kind) && task.dig("artifact_provenance", "require_gate_cross_reference") == true
      referenced = Array(record["implementation_artifact_refs"])
      implementation_record = current_implementation_artifact_record(manifest, task, task_path)
      current_ids = current_implementation_artifact_ids(manifest, task, task_path)
      failures << { "reason" => "missing_implementation_artifact_reference" } if referenced.empty? || current_ids.empty? || (referenced & current_ids).empty?
      if implementation_record
        implementation_assessment = artifact_provenance_assessment(task, implementation_record, manifest: manifest, task_path: task_path)
        failures << { "reason" => "referenced_implementation_artifact_invalid" } unless implementation_assessment["valid"]
      end
    end
  end
  {
    "required" => required,
    "valid" => failures.empty?,
    "status" => failures.empty? ? "pass" : "partial",
    "blocking_reason" => failures.first && failures.first["reason"],
    "failures" => failures,
    "artifact_ids" => refs.map { |ref| ref.is_a?(Hash) ? ref["id"] : nil }.compact
  }.compact
end

def validate_current_artifact_provenance(result, records, task)
  return unless task.is_a?(Hash) && records.is_a?(Array)

  manifest = { "records" => records }
  task_path = task["__orbit_path"]
  task_sha256 = task_path && File.file?(task_path) ? sha256_file(task_path) : nil
  %w[implementation review test].each do |kind|
    record = if kind == "implementation"
               records.reverse.find do |entry|
                 entry.is_a?(Hash) && entry["kind"] == kind && entry["status"] == "pass"
               end
             else
               accepted_gate_record_for_evidence_kind(records, task, kind, task_sha256)
             end
    next unless record

    assessment = artifact_provenance_assessment(task, record, manifest: manifest, task_path: task_path)
    next if assessment["valid"]

    assessment["failures"].each_with_index do |failure, index|
      validation_error(
        result,
        "evidence_file.records.#{kind}.artifact_provenance[#{index}]",
        "Artifact provenance cannot support PASS: #{failure["reason"]}#{failure["artifact_id"] ? " (#{failure["artifact_id"]})" : ""}."
      )
    end
  end
end

def parse_artifact_args(args)
  subcommand = args.shift
  usage_error("artifact requires inspect subcommand.") unless subcommand == "inspect"
  options = { "json" => false, "lifecycle" => "transient" }
  until args.empty?
    arg = args.shift
    case arg
    when "--path" then options["path"] = option_value(args, "--path")
    when /\A--path=(.+)\z/ then options["path"] = Regexp.last_match(1)
    when "--task" then options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/ then options["task"] = Regexp.last_match(1)
    when "--id" then options["id"] = option_value(args, "--id")
    when /\A--id=(.+)\z/ then options["id"] = Regexp.last_match(1)
    when "--producer-command" then options["producer_command"] = option_value(args, "--producer-command")
    when /\A--producer-command=(.+)\z/ then options["producer_command"] = Regexp.last_match(1)
    when "--lifecycle" then options["lifecycle"] = option_value(args, "--lifecycle")
    when /\A--lifecycle=(.+)\z/ then options["lifecycle"] = Regexp.last_match(1)
    when "--json" then options["json"] = true
    else usage_error("Unknown artifact inspect option: #{arg}")
    end
  end
  %w[path task id producer_command].each { |field| usage_error("artifact inspect requires --#{field.tr("_", "-")}.") if options[field].to_s.empty? }
  usage_error("artifact inspect --lifecycle must be transient or durable.") unless ARTIFACT_LIFECYCLES.include?(options["lifecycle"])
  usage_error("artifact inspect currently requires --json.") unless options["json"]
  options
end

def artifact(args)
  options = parse_artifact_args(args)
  relative = options["path"]
  usage_error("artifact --path must be project-relative and cannot contain '..'.") unless artifact_relative_path?(relative)
  absolute = File.expand_path(relative, Dir.pwd)
  usage_error("artifact file does not exist: #{relative}") unless File.file?(absolute)
  root = File.realpath(Dir.pwd)
  real_artifact = File.realpath(absolute) rescue nil
  usage_error("artifact --path must resolve inside the project.") unless real_artifact && real_artifact.start_with?("#{root}/")
  task_path = File.expand_path(options["task"])
  task = load_yaml(task_path)
  ref = {
    "id" => options["id"],
    "path" => relative,
    "sha256" => sha256_file(real_artifact),
    "producer_command" => options["producer_command"],
    "created_at" => File.mtime(real_artifact).utc.iso8601,
    "git_head" => artifact_current_git_head,
    "task_id" => task["task_id"],
    "task_revision" => artifact_task_revision(task, task_path),
    "lifecycle" => options["lifecycle"]
  }
  puts JSON.pretty_generate({ "schema_version" => "orbit-artifact-ref-v1", "artifact" => ref })
end

def load_artifact_ref_option(value)
  raw = if value.to_s.start_with?("@")
          path = File.expand_path(value[1..])
          evidence_error("--artifact-ref file not found: #{path}") unless File.file?(path)
          File.read(path)
        else
          value.to_s
        end
  parsed = raw.strip.start_with?("{") ? JSON.parse(raw) : YAML.safe_load(raw)
  parsed = parsed["artifact"] if parsed.is_a?(Hash) && parsed["artifact"].is_a?(Hash)
  evidence_error("--artifact-ref must contain an artifact mapping.") unless parsed.is_a?(Hash)
  errors = artifact_reference_shape_errors(parsed)
  evidence_error("Invalid --artifact-ref: #{errors.join("; ")}") unless errors.empty?
  parsed
rescue JSON::ParserError, Psych::SyntaxError
  evidence_error("--artifact-ref must be valid JSON or YAML.")
end

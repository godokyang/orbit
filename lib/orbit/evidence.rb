# frozen_string_literal: true

ALLOWED_EVIDENCE_STATUSES = %w[pass fail partial invalid].freeze
ALLOWED_EVIDENCE_KINDS = %w[review test command implementation].freeze

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

def default_evidence_manifest
  {
    "schema_version" => "orbit-evidence-v1",
    "project" => File.basename(Dir.pwd),
    "records" => [],
    "verdict" => {
      "status" => "invalid",
      "high" => 0,
      "medium" => 0,
      "low" => 0
    },
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
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#{JSON.pretty_generate(manifest)}\n")
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

  write_evidence_manifest(output_path, default_evidence_manifest)
  puts "Created Orbit evidence manifest:"
  puts "- #{output_path}"
end

def evidence_add(options)
  path = File.expand_path(options["file"])
  manifest = load_evidence_manifest(path)
  unless manifest["schema_version"] == "orbit-evidence-v1"
    evidence_error("Evidence schema_version must be orbit-evidence-v1.")
  end

  records = ensure_evidence_records!(manifest)
  record = {
    "kind" => options["kind"],
    "status" => options["status"],
    "summary" => options["summary"].strip,
    "created_at" => Time.now.utc.iso8601
  }
  validate_evidence_record_shape!(record, "Evidence record")

  records << record
  manifest["project"] = File.basename(Dir.pwd) if manifest["project"].to_s.empty?
  manifest["verdict"] = {
    "status" => record["status"],
    "kind" => record["kind"],
    "summary" => record["summary"],
    "created_at" => record["created_at"]
  }
  write_evidence_manifest(path, manifest)

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
  manifest = load_evidence_manifest(path)
  unless manifest["schema_version"] == "orbit-evidence-v1"
    evidence_error("Evidence schema_version must be orbit-evidence-v1.")
  end

  kind = options["kind"] || infer_report_kind(report_path, report)
  evidence_error("Could not infer report kind; pass --kind #{ALLOWED_EVIDENCE_KINDS.join("|")}.") unless ALLOWED_EVIDENCE_KINDS.include?(kind)

  status = options["status"] || infer_report_status(report)
  evidence_error("Could not infer report status; pass --status #{ALLOWED_EVIDENCE_STATUSES.join("|")}.") unless ALLOWED_EVIDENCE_STATUSES.include?(status)

  summary = options["summary"] || infer_report_summary(report_path, report)
  record = {
    "kind" => kind,
    "status" => status,
    "summary" => summary.strip,
    "created_at" => Time.now.utc.iso8601,
    "source_report" => report_path
  }
  validate_evidence_record_shape!(record, "Evidence record")

  records = ensure_evidence_records!(manifest)
  records << record
  manifest["verdict"] = {
    "status" => record["status"],
    "kind" => record["kind"],
    "summary" => record["summary"],
    "created_at" => record["created_at"]
  }
  write_evidence_manifest(path, manifest)

  puts JSON.pretty_generate({
    "schema_version" => "orbit-evidence-import-v1",
    "file" => path,
    "report" => report_path,
    "record" => record
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
  manifest = load_evidence_manifest(path)
  rule_resolution = load_rule_resolution_manifest(rule_resolution_path)

  unless rule_resolution["valid"] == true
    evidence_error("Rule resolution must be valid before attaching: #{rule_resolution_path}")
  end

  checks = rule_resolution["checks"].is_a?(Hash) ? rule_resolution["checks"] : {}
  manifest["rule_resolution"] = {
    "resolver" => "orbit rules resolve --json",
    "file" => rule_resolution_path,
    "valid" => true,
    "resolved_role" => rule_resolution["resolved_role"],
    "conflict_count" => rule_resolution["conflicts"].is_a?(Array) ? rule_resolution["conflicts"].length : 0,
    "missing_project_rule_files" => checks["missing_project_rule_files"].is_a?(Array) ? checks["missing_project_rule_files"] : []
  }

  write_evidence_manifest(path, manifest)
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
  when "attach-rule"
    evidence_attach_rule(options)
  when "show"
    evidence_show(options)
  else
    usage_error("Unknown evidence subcommand: #{options["subcommand"]}")
  end
end


# frozen_string_literal: true

DEFAULT_DOCS_REGISTRY = File.join(".orbit", "docs-registry.json")

def docs_error(message)
  warn message
  exit 1
end

def path_inside_project(path)
  expanded = File.expand_path(path)
  root = "#{Dir.pwd}#{File::SEPARATOR}"
  expanded.start_with?(root) ? expanded.delete_prefix(root) : expanded
end

def file_sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def read_json_or_yaml_file(path)
  load_yaml(path)
rescue RuntimeError => e
  docs_error(e.message)
end

def evidence_record_summary(records)
  counts = {}
  latest = {}
  artifacts = []

  Array(records).each_with_index do |record, index|
    next unless record.is_a?(Hash)

    kind = record["kind"].to_s
    status = record["status"].to_s
    counts[kind] ||= {}
    counts[kind][status] ||= 0
    counts[kind][status] += 1
    latest[kind] = record

    Array(record["artifacts"]).each { |artifact| artifacts << artifact.to_s unless artifact.to_s.empty? }
    artifacts << record["source_report"].to_s if record["source_report"].is_a?(String) && !record["source_report"].empty?
  end

  {
    "count" => Array(records).length,
    "by_kind" => counts,
    "latest_by_kind" => latest.transform_values do |record|
      {
        "status" => record["status"],
        "summary" => record["summary"],
        "created_at" => record["created_at"],
        "structured" => record["structured_submit"] == true
      }
    end,
    "artifact_refs" => artifacts.uniq
  }
end

def compact_latest_gate_verdicts(record_summary, handoff)
  return handoff["latest_gate_verdicts"] if handoff.is_a?(Hash) && handoff["latest_gate_verdicts"].is_a?(Hash)

  latest = record_summary["latest_by_kind"].is_a?(Hash) ? record_summary["latest_by_kind"] : {}
  %w[review test].each_with_object({}) do |kind, memo|
    memo[kind] = latest[kind] || { "status" => "missing" }
  end
end

def parse_compact_evidence_args(args)
  options = {
    "json" => false
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--evidence"
      options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      options["evidence"] = Regexp.last_match(1)
    when "--handoff"
      options["handoff"] = option_value(args, "--handoff")
    when /\A--handoff=(.+)\z/
      options["handoff"] = Regexp.last_match(1)
    when "--output"
      options["output"] = option_value(args, "--output")
    when /\A--output=(.+)\z/
      options["output"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown compact-evidence option: #{arg}")
    end
  end

  %w[task evidence].each do |name|
    usage_error("Missing required option: --#{name}") if options[name].to_s.empty?
  end
  usage_error("compact-evidence currently requires --json") unless options["json"]
  options
end

def compact_file_ref(path)
  return nil if path.to_s.empty?

  expanded = File.expand_path(path)
  {
    "path" => path_inside_project(expanded),
    "absolute_path" => expanded,
    "exists" => File.file?(expanded),
    "sha256" => File.file?(expanded) ? file_sha256(expanded) : nil
  }
end

def compact_evidence(args)
  options = parse_compact_evidence_args(args)
  task_path = File.expand_path(options["task"])
  evidence_path = File.expand_path(options["evidence"])
  handoff_path = options["handoff"] ? File.expand_path(options["handoff"]) : nil
  task = read_json_or_yaml_file(task_path)
  evidence = read_json_or_yaml_file(evidence_path)
  handoff = handoff_path && File.file?(handoff_path) ? read_json_or_yaml_file(handoff_path) : nil
  docs = Array(task["source_documents"]).map do |path|
    doc_ref = compact_file_ref(path)
    doc_ref&.merge("doc_id" => nil, "reference_type" => "source_document")
  end.compact
  rule_ref = evidence["rule_resolution"].is_a?(Hash) ? compact_file_ref(evidence["rule_resolution"]["file"]) : nil
  record_summary = evidence_record_summary(evidence["records"])
  latest_gate_verdicts = compact_latest_gate_verdicts(record_summary, handoff)
  closure_checklist = handoff.is_a?(Hash) ? handoff["closure_checklist"] : nil
  known_gaps = handoff.is_a?(Hash) ? handoff["known_gaps"] : nil
  result = {
    "schema_version" => "orbit-durable-evidence-summary-v1",
    "project" => task["project"] || evidence["project"] || File.basename(Dir.pwd),
    "generated_at" => Time.now.utc.iso8601,
    "inputs" => {
      "task" => compact_file_ref(task_path),
      "evidence" => compact_file_ref(evidence_path),
      "handoff" => handoff_path ? compact_file_ref(handoff_path) : nil
    },
    "task_summary" => {
      "target_role" => task["target_role"],
      "task_type" => task["task_type"],
      "objective" => task["objective"],
      "quality_outcome" => task["quality_outcome"],
      "acceptance_count" => Array(task["acceptance"]).length,
      "source_documents" => docs
    },
    "evidence_summary" => {
      "records" => record_summary,
      "aggregate_verdict" => evidence["verdict"],
      "waiver_count" => Array(evidence["waivers"]).length,
      "rule_resolution" => rule_ref
    },
    "handoff_summary" => handoff ? {
      "current_phase" => handoff["current_phase"],
      "required_action" => handoff["required_action"],
      "audit_summary" => handoff["audit_summary"],
      "latest_gate_verdicts" => latest_gate_verdicts,
      "closure_checklist" => closure_checklist,
      "known_gaps" => known_gaps,
      "readable_summary" => handoff["readable_summary"]
    } : nil,
    "transient_artifacts" => {
      "policy" => "referenced_by_path_and_hash",
      "artifact_refs" => record_summary["artifact_refs"],
      "large_artifacts_not_embedded" => true
    }
  }

  json = "#{JSON.pretty_generate(result)}\n"
  if options["output"]
    output_path = File.expand_path(options["output"])
    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, json)
  end
  print json
end

def parse_docs_args(args)
  subcommand = args.shift
  usage_error("Missing docs subcommand.") unless subcommand
  options = {
    "subcommand" => subcommand,
    "registry" => DEFAULT_DOCS_REGISTRY,
    "json" => false
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--id"
      options["id"] = option_value(args, "--id")
    when /\A--id=(.+)\z/
      options["id"] = Regexp.last_match(1)
    when "--path"
      options["path"] = option_value(args, "--path")
    when /\A--path=(.+)\z/
      options["path"] = Regexp.last_match(1)
    when "--registry"
      options["registry"] = option_value(args, "--registry")
    when /\A--registry=(.+)\z/
      options["registry"] = Regexp.last_match(1)
    when "--open-dir"
      options["open_dir"] = option_value(args, "--open-dir")
    when /\A--open-dir=(.+)\z/
      options["open_dir"] = Regexp.last_match(1)
    when "--archive-dir"
      options["archive_dir"] = option_value(args, "--archive-dir")
    when /\A--archive-dir=(.+)\z/
      options["archive_dir"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown docs #{subcommand} option: #{arg}")
    end
  end

  usage_error("docs currently requires --json") unless options["json"]
  if subcommand == "alias"
    usage_error("Missing required option: --id") if options["id"].to_s.empty?
    usage_error("Missing required option: --path") if options["path"].to_s.empty?
  elsif subcommand != "check"
    usage_error("Unknown docs subcommand: #{subcommand}")
  end
  options
end

def load_docs_registry(path)
  return {
    "schema_version" => "orbit-docs-registry-v1",
    "project" => File.basename(Dir.pwd),
    "docs" => {}
  } unless File.file?(path)

  registry = read_json_or_yaml_file(path)
  docs_error("#{path} must contain a mapping.") unless registry.is_a?(Hash)
  registry["schema_version"] ||= "orbit-docs-registry-v1"
  registry["project"] ||= File.basename(Dir.pwd)
  registry["docs"] ||= {}
  docs_error("#{path}.docs must be a mapping.") unless registry["docs"].is_a?(Hash)
  registry
end

def write_docs_registry(path, registry)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#{JSON.pretty_generate(registry)}\n")
end

def docs_alias(options)
  registry_path = File.expand_path(options["registry"])
  doc_path = File.expand_path(options["path"])
  docs_error("docs alias path does not exist: #{options["path"]}") unless File.file?(doc_path)

  registry = load_docs_registry(registry_path)
  entry = {
    "id" => options["id"],
    "current_path" => path_inside_project(doc_path),
    "absolute_path" => doc_path,
    "content_hash" => "sha256:#{file_sha256(doc_path)}",
    "schema_version" => "orbit-doc-alias-v1",
    "updated_at" => Time.now.utc.iso8601
  }
  registry["docs"][options["id"]] = entry
  write_docs_registry(registry_path, registry)

  {
    "schema_version" => "orbit-docs-alias-v1",
    "project" => registry["project"],
    "registry" => path_inside_project(registry_path),
    "entry" => entry
  }
end

def registry_doc_entries(registry)
  docs = registry["docs"]
  return [] unless docs.is_a?(Hash)

  docs.map do |doc_id, entry|
    entry = {} unless entry.is_a?(Hash)
    [doc_id, entry]
  end
end

def check_registry_docs(registry)
  registry_doc_entries(registry).map do |doc_id, entry|
    path = entry["absolute_path"].to_s.empty? ? File.expand_path(entry["current_path"].to_s) : entry["absolute_path"]
    exists = File.file?(path)
    actual_hash = exists ? "sha256:#{file_sha256(path)}" : nil
    {
      "id" => doc_id,
      "current_path" => entry["current_path"],
      "exists" => exists,
      "hash_matches" => exists && entry["content_hash"].to_s == actual_hash,
      "expected_hash" => entry["content_hash"],
      "actual_hash" => actual_hash
    }
  end
end

def markdown_front_matter_value(text, key)
  text.each_line.first(40).each do |line|
    match = line.match(/\A#{Regexp.escape(key)}:\s*(.+?)\s*\z/i)
    return match[1].strip if match
  end
  nil
end

def check_open_docs(open_dir, registry)
  return [] if open_dir.to_s.empty? || !Dir.exist?(open_dir)

  indexed_paths = registry_doc_entries(registry).map { |_id, entry| File.expand_path(entry["absolute_path"].to_s.empty? ? entry["current_path"].to_s : entry["absolute_path"]) }.to_set
  Dir.glob(File.join(open_dir, "**", "*.md")).map do |path|
    text = File.read(path)
    status = markdown_front_matter_value(text, "status") || markdown_front_matter_value(text, "state")
    next nil unless status.to_s.downcase == "done"

    expanded = File.expand_path(path)
    {
      "path" => path_inside_project(expanded),
      "status" => status,
      "indexed" => indexed_paths.include?(expanded),
      "issue" => indexed_paths.include?(expanded) ? "closed_open_doc_indexed" : "closed_open_doc_not_archived_or_indexed"
    }
  end.compact
end

def docs_check(options)
  registry_path = File.expand_path(options["registry"])
  registry = load_docs_registry(registry_path)
  aliases = check_registry_docs(registry)
  open_dir = options["open_dir"] || (Dir.exist?(File.join("docs", "open")) ? File.join("docs", "open") : nil)
  archive_dir = options["archive_dir"] || (Dir.exist?(File.join("docs", "archive")) ? File.join("docs", "archive") : nil)
  open_docs = check_open_docs(open_dir, registry)
  archive_readme = archive_dir && Dir.exist?(archive_dir) ? File.file?(File.join(archive_dir, "README.md")) : nil
  issues = []
  aliases.each do |entry|
    issues << { "source" => "docs_registry.#{entry["id"]}.current_path", "message" => "Registered document path is missing." } unless entry["exists"]
    issues << { "source" => "docs_registry.#{entry["id"]}.content_hash", "message" => "Registered document content hash is stale." } if entry["exists"] && !entry["hash_matches"]
  end
  open_docs.each do |entry|
    next if entry["indexed"]

    issues << { "source" => "docs_open.#{entry["path"]}", "message" => "Closed open doc is not archived or indexed." }
  end
  if archive_readme == false
    issues << { "source" => "docs_archive.README.md", "message" => "Archive directory is missing README.md." }
  end

  {
    "schema_version" => "orbit-docs-check-v1",
    "project" => registry["project"],
    "registry" => path_inside_project(registry_path),
    "valid" => issues.empty?,
    "aliases" => aliases,
    "open_docs" => open_docs,
    "archive" => {
      "path" => archive_dir ? path_inside_project(File.expand_path(archive_dir)) : nil,
      "readme_present" => archive_readme
    },
    "issues" => issues
  }
end

def docs(args)
  options = parse_docs_args(args)
  result = options["subcommand"] == "alias" ? docs_alias(options) : docs_check(options)
  print "#{JSON.pretty_generate(result)}\n"
  exit(result["valid"] == false ? 1 : 0)
end

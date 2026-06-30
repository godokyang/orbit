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
  task_ref = compact_file_ref(task_path)
  evidence_ref = compact_file_ref(evidence_path)
  handoff_ref = handoff_path ? compact_file_ref(handoff_path) : nil
  task_sha256 = task_ref&.dig("sha256")
  unless task_sha256.is_a?(String) && task_sha256.match?(/\A[0-9a-f]{64}\z/)
    docs_error("compact-evidence: could not compute SHA256 for task file: #{task_path}")
  end
  docs = Array(task["source_documents"]).map do |path|
    doc_ref = compact_file_ref(path)
    doc_ref&.merge("doc_id" => nil, "reference_type" => "source_document")
  end.compact
  rule_ref = evidence["rule_resolution"].is_a?(Hash) ? compact_file_ref(evidence["rule_resolution"]["file"]) : nil
  record_summary = evidence_record_summary(redact_for_compact(evidence["records"]))
  latest_gate_verdicts = compact_latest_gate_verdicts(record_summary, handoff)
  closure_checklist = handoff.is_a?(Hash) ? handoff["closure_checklist"] : nil
  known_gaps = handoff.is_a?(Hash) ? handoff["known_gaps"] : nil
  result = {
    "schema_version" => "orbit-durable-evidence-summary-v1",
    "project" => task["project"] || evidence["project"] || File.basename(Dir.pwd),
    "generated_at" => Time.now.utc.iso8601,
    "compact_summary" => {
      "task_sha256" => task_sha256,
      "evidence_sha256" => evidence_ref&.dig("sha256"),
      "handoff_sha256" => handoff_ref&.dig("sha256"),
      "latest_verdicts" => latest_gate_verdicts,
      "artifact_refs" => record_summary["artifact_refs"],
      "known_gaps" => known_gaps || [],
      "closure_checklist" => closure_checklist || []
    }.compact,
    "inputs" => {
      "task" => task_ref,
      "evidence" => evidence_ref,
      "handoff" => handoff_ref
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
      "aggregate_verdict" => redact_aggregate_verdict_for_summary(evidence["verdict"]),
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
    when "--status"
      options["doc_lifecycle_status"] = option_value(args, "--status")
    when /\A--status=(.+)\z/
      options["doc_lifecycle_status"] = Regexp.last_match(1)
    when "--doc-lifecycle"
      options["doc_lifecycle"] = option_value(args, "--doc-lifecycle")
    when /\A--doc-lifecycle=(.+)\z/
      options["doc_lifecycle"] = Regexp.last_match(1)
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
  # Slice 10: carry doc_lifecycle metadata if provided via --doc-lifecycle or --status.
  dl_source = options["doc_lifecycle"]
  if dl_source
    begin
      dl_parsed = dl_source.strip.start_with?("{") ? JSON.parse(dl_source) : YAML.safe_load(dl_source)
    rescue JSON::ParserError, Psych::SyntaxError
      docs_error("--doc-lifecycle must be valid JSON or YAML mapping.")
    end
    unless dl_parsed.is_a?(Hash)
      docs_error("--doc-lifecycle must be a mapping; got #{dl_parsed.class}.")
    end
    unless dl_parsed["doc_id"].is_a?(String) && !dl_parsed["doc_id"].strip.empty?
      docs_error("--doc-lifecycle must include a non-empty doc_id.")
    end
    # doc_lifecycle.doc_id must match --id to preserve stable doc id semantics.
    if dl_parsed["doc_id"].strip != options["id"]
      docs_error("--doc-lifecycle doc_id (#{dl_parsed["doc_id"].strip.inspect}) must match --id (#{options["id"].inspect}).")
    end
    dl = normalize_doc_lifecycle(dl_parsed)
    entry["doc_lifecycle"] = dl if dl
  elsif options["doc_lifecycle_status"]
    status = options["doc_lifecycle_status"]
    unless ALLOWED_DOC_LIFECYCLE_STATUSES.include?(status)
      docs_error("--status must be one of #{ALLOWED_DOC_LIFECYCLE_STATUSES.join('|')}.")
    end
    entry["doc_lifecycle"] = { "doc_id" => options["id"], "status" => status, "path" => path_inside_project(doc_path), "content_sha256" => entry["content_hash"] }
  end
  # Slice 10: carry decision_record if the alias command includes one (rare; usually on evidence).
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
  warnings = []
  aliases.each do |entry|
    issues << { "source" => "docs_registry.#{entry["id"]}.current_path", "message" => "Registered document path is missing." } unless entry["exists"]
    issues << { "source" => "docs_registry.#{entry["id"]}.content_hash", "message" => "Registered document content hash is stale." } if entry["exists"] && !entry["hash_matches"]
  end
  # Slice 10: warn when a doc with doc_lifecycle.status=open_design has been marked done in its content.
  registry_doc_entries(registry).each do |doc_id, entry|
    next unless entry.is_a?(Hash) && entry["doc_lifecycle"].is_a?(Hash)
    dl = entry["doc_lifecycle"]
    next unless dl["status"] == "open_design"
    abs_path = entry["absolute_path"].to_s.empty? ? File.expand_path(entry["current_path"].to_s) : entry["absolute_path"]
    next unless File.file?(abs_path)
    content_status = markdown_front_matter_value(File.read(abs_path), "status") || markdown_front_matter_value(File.read(abs_path), "state")
    if content_status.to_s.downcase == "done" || content_status.to_s.downcase == "implemented"
      warnings << { "source" => "docs_registry.#{doc_id}.doc_lifecycle.status", "message" => "Document content indicates done/implemented but doc_lifecycle.status is still open_design; update to implemented_archive." }
    end
  end
  # Slice 10: warn when lesson_candidate is treated as promoted_rule without explicit status change.
  registry_doc_entries(registry).each do |doc_id, entry|
    next unless entry.is_a?(Hash) && entry["doc_lifecycle"].is_a?(Hash)
    dl = entry["doc_lifecycle"]
    next unless dl["status"] == "lesson_candidate"
    # Check if the doc content claims to be a rule but lifecycle hasn't been promoted.
    abs_path = entry["absolute_path"].to_s.empty? ? File.expand_path(entry["current_path"].to_s) : entry["absolute_path"]
    next unless File.file?(abs_path)
    content = File.read(abs_path)
    promoted = markdown_front_matter_value(content, "promoted") || markdown_front_matter_value(content, "rule_status")
    if promoted.to_s.downcase == "true" || promoted.to_s.downcase == "active"
      warnings << { "source" => "docs_registry.#{doc_id}.doc_lifecycle.status", "message" => "Document content claims promoted/active rule but doc_lifecycle.status is lesson_candidate; explicit status change to promoted_rule required." }
    end
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
    "doc_lifecycle_summary" => doc_lifecycle_summary(registry),
    "issues" => issues,
    "warnings" => warnings
  }
end

def docs(args)
  options = parse_docs_args(args)
  result = options["subcommand"] == "alias" ? docs_alias(options) : docs_check(options)
  print "#{JSON.pretty_generate(result)}\n"
  exit(result["valid"] == false ? 1 : 0)
end

# ---------------------------------------------------------------------------
# Slice 10: doc_lifecycle metadata + decision_record structured records
# ---------------------------------------------------------------------------

# Validates a doc_lifecycle mapping on a doc alias entry or evidence record.
# Returns the normalized lifecycle or nil when absent/malformed.
def normalize_doc_lifecycle(value)
  return nil unless value.is_a?(Hash)

  doc_id = value["doc_id"]
  path = value["path"]
  return nil unless doc_id.is_a?(String) && !doc_id.empty?

  result = { "doc_id" => doc_id }
  result["path"] = path if path.is_a?(String) && !path.empty?
  status = value["status"]
  if status.is_a?(String) && !status.empty?
    unless ALLOWED_DOC_LIFECYCLE_STATUSES.include?(status)
      docs_error("doc_lifecycle.status must be one of #{ALLOWED_DOC_LIFECYCLE_STATUSES.join('|')}; got #{status.inspect}.")
    end
    result["status"] = status
  else
    result["status"] = "active_baseline"
  end
  supersedes = value["supersedes"]
  result["supersedes"] = supersedes if supersedes.is_a?(Array) && supersedes.all? { |s| s.is_a?(String) && !s.empty? }
  superseded_by = value["superseded_by"]
  result["superseded_by"] = superseded_by if superseded_by.is_a?(String) && !superseded_by.empty?
  content_sha = value["content_sha256"]
  result["content_sha256"] = content_sha if content_sha.is_a?(String) && !content_sha.empty?
  result
end

# Validates a decision_record mapping attached to an evidence record.
def validate_decision_record!(record, source)
  dr = record["decision_record"]
  unless dr.is_a?(Hash)
    submit_report_schema_error(
      "#{source}.decision_record",
      "decision_record must be a mapping.",
      expected: "mapping with id, kind, summary, source",
      actual: evidence_value_type(dr),
      kind: record["kind"]
    )
    return nil
  end

  result = {}
  %w[id kind summary source].each do |f|
    v = dr[f]
    unless v.is_a?(String) && !v.strip.empty?
      submit_report_schema_error(
        "#{source}.decision_record.#{f}",
        "decision_record.#{f} must be a non-empty string.",
        expected: "non-empty string",
        actual: evidence_value_type(v),
        kind: record["kind"]
      )
      next
    end
    result[f] = v.strip
  end

  kind = result["kind"]
  if kind && !ALLOWED_DECISION_KINDS.include?(kind)
    submit_report_schema_error(
      "#{source}.decision_record.kind",
      "decision_record.kind must be one of #{ALLOWED_DECISION_KINDS.join('|')}.",
      expected: ALLOWED_DECISION_KINDS.join("|"),
      actual: evidence_value_type(kind),
      kind: record["kind"]
    )
  end

  applies_to = dr["applies_to"]
  if applies_to.is_a?(Hash)
    at = {}
    %w[task doc_id].each do |f|
      v = applies_to[f]
      at[f] = v if v.is_a?(String) && !v.empty?
    end
    result["applies_to"] = at unless at.empty?
  elsif !applies_to.nil?
    submit_report_schema_error(
      "#{source}.decision_record.applies_to",
      "decision_record.applies_to must be a mapping.",
      expected: "mapping with task and/or doc_id",
      actual: evidence_value_type(applies_to),
      kind: record["kind"]
    )
  end

  expires = dr["expires"]
  if expires.is_a?(String) && !expires.strip.empty?
    begin
      Time.iso8601(expires.strip)
      result["expires"] = expires.strip
    rescue ArgumentError
      submit_report_schema_error(
        "#{source}.decision_record.expires",
        "decision_record.expires must be a valid ISO8601 datetime string.",
        expected: "ISO8601 datetime string",
        actual: expires.inspect,
        kind: record["kind"]
      )
    end
  elsif !expires.nil?
    submit_report_schema_error(
      "#{source}.decision_record.expires",
      "decision_record.expires must be a non-empty ISO8601 string.",
      expected: "ISO8601 string",
      actual: evidence_value_type(expires),
      kind: record["kind"]
    )
  end

  result
end

# Aggregates decision records from evidence into active/expired for handoff and audit.
def decision_record_summary(evidence, now = Time.now.utc)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  active = []
  expired = []
  records.each do |record|
    next unless record.is_a?(Hash) && record["decision_record"].is_a?(Hash)
    dr = record["decision_record"]
    next unless dr["id"].is_a?(String) && !dr["id"].empty?

    entry = {
      "id" => dr["id"],
      "kind" => dr["kind"],
      "summary" => dr["summary"],
      "source" => dr["source"],
      "applies_to" => dr["applies_to"],
      "expires" => dr["expires"]
    }.compact

    expires = dr["expires"]
    if expires.is_a?(String) && !expires.empty?
      begin
        exp_time = Time.iso8601(expires)
        if exp_time < now
          expired << entry.merge("effective_status" => "expired")
        else
          active << entry.merge("effective_status" => "active")
        end
      rescue ArgumentError
        active << entry.merge("effective_status" => "active")
      end
    else
      active << entry.merge("effective_status" => "active")
    end
  end

  {
    "active_decisions" => active,
    "expired_decisions" => expired,
    "active_count" => active.length,
    "expired_count" => expired.length,
    "any_expired" => !expired.empty?
  }
end

# Summarizes doc_lifecycle metadata from doc alias entries for docs check.
def doc_lifecycle_summary(registry)
  entries = registry_doc_entries(registry)
  by_status = {}
  entries.each do |_id, entry|
    next unless entry.is_a?(Hash)
    dl = entry["doc_lifecycle"]
    next unless dl.is_a?(Hash)
    status = dl["status"].is_a?(String) ? dl["status"] : "active_baseline"
    by_status[status] = (by_status[status] || 0) + 1
  end
  {
    "doc_count" => entries.length,
    "statuses" => by_status,
    "has_open_design" => (by_status["open_design"] || 0) > 0,
    "has_lesson_candidate" => (by_status["lesson_candidate"] || 0) > 0,
    "has_promoted_rule" => (by_status["promoted_rule"] || 0) > 0
  }
end

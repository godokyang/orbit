def load_rule_pack_config
  path = File.join(Dir.pwd, ".orbit", "rule-packs.yaml")
  return {} unless File.file?(path)

  config = load_yaml(path)
  return {} unless config.is_a?(Hash)

  packs = config["rule_packs"]
  packs.is_a?(Hash) ? packs : {}
rescue RuntimeError
  {}
end

def normalize_rule_pack_entry(category, entry)
  case entry
  when String
    return nil if entry.empty?

    {
      "category" => category,
      "id" => entry
    }
  when Hash
    id = entry["id"] || entry["name"] || entry["path"]
    return nil unless id.is_a?(String) && !id.empty?

    normalized = entry.dup
    normalized["category"] = category
    normalized["id"] = id
    normalized
  else
    nil
  end
end

def rule_pack_categories(role, task_type = nil, include_audit: false)
  categories = ["common"]
  task_type_text = task_type.to_s

  if role == "reviewer" || task_type_text.include?("review")
    categories << "review"
  end

  if role == "tester" || task_type_text.include?("test")
    categories << "test"
  end

  categories << "audit" if include_audit || task_type_text.include?("audit")
  categories.uniq
end

def rule_packs_for_context(role, task_type = nil, include_audit: false)
  packs = load_rule_pack_config
  categories = rule_pack_categories(role, task_type, include_audit: include_audit)
  categories.flat_map do |category|
    entries = packs[category]
    next [] unless entries.is_a?(Array)

    entries.map { |entry| normalize_rule_pack_entry(category, entry) }.compact
  end
end

def default_rule_categories(role, task_type = nil)
  categories = ["common"]
  role_text = role.to_s
  task_type_text = task_type.to_s

  case role_text
  when "reviewer"
    categories << "reviewer"
  when "tester"
    categories << "tester"
  when "lead"
    categories << "lead"
  when "coder"
    categories << "coder"
  when "handoff_receiver"
    categories << "handoff_receiver"
  else
    categories << "reviewer" if task_type_text.include?("review")
    categories << "tester" if task_type_text.include?("test")
    categories << "lead" if task_type_text.include?("implementation") || task_type_text.include?("coding")
  end
  categories.uniq
end

def default_rule_entries(role, task_type = nil)
  default_rule_categories(role, task_type).flat_map do |category|
    DEFAULT_RULE_REFERENCES.fetch(category, []).map do |entry|
      absolute_path = File.join(SKILL_ROOT, entry["path"])
      entry.merge(
        "id" => entry["id"] || "orbit_default:#{category}:#{entry["path"]}",
        "relation" => entry["relation"] || "baseline",
        "category" => category,
        "source" => "orbit_default",
        "absolute_path" => absolute_path,
        "exists" => File.file?(absolute_path)
      )
    end
  end
end

def normalize_project_rule_entry(entry, index)
  case entry
  when String
    absolute_path = File.expand_path(entry, Dir.pwd)
    {
      "source" => "project_role_rules",
      "index" => index,
      "id" => "project_rule:#{entry}",
      "relation" => "supplements",
      "path" => entry,
      "absolute_path" => absolute_path,
      "exists" => File.file?(absolute_path)
    }
  when Hash
    path = entry["path"] || entry["file"]
    absolute_path = path ? File.expand_path(path, Dir.pwd) : nil
    normalized = entry.dup
    normalized["source"] = "project_role_rules"
    normalized["index"] = index
    normalized["id"] ||= path ? "project_rule:#{path}" : "project_rule:#{index}"
    normalized["relation"] ||= "supplements"
    normalized["path"] = path
    normalized["absolute_path"] = absolute_path
    normalized["exists"] = absolute_path ? File.file?(absolute_path) : false
    normalized
  else
    {
      "source" => "project_role_rules",
      "index" => index,
      "path" => nil,
      "absolute_path" => nil,
      "exists" => false,
      "invalid" => true
    }
  end
end

def project_rule_entries(role_def)
  rules = role_def.is_a?(Hash) ? role_def["rules"] : []
  return [] unless rules.is_a?(Array)

  rules.each_with_index.map { |entry, index| normalize_project_rule_entry(entry, index) }
end

def add_rule_resolution_checks(result)
  project_rules = result.dig("sources", "project_rules") || []
  missing = project_rules.select { |entry| !entry["exists"] }
  invalid = project_rules.select { |entry| entry["invalid"] || entry["path"].to_s.empty? }
  default_missing = (result.dig("sources", "orbit_default") || []).select { |entry| !entry["exists"] }

  result["checks"] = {
    "default_rules_always_loaded" => true,
    "project_rules_are_additive" => true,
    "missing_project_rule_files" => missing.map { |entry| entry["path"] },
    "missing_default_rule_files" => default_missing.map { |entry| entry["path"] },
    "invalid_project_rule_entries" => invalid.map { |entry| entry["index"] }
  }

  missing.each do |entry|
    conflict(result, "project_role_rules[#{entry["index"]}]", "Project rule file is missing: #{entry["path"].inspect}.")
  end

  invalid.each do |entry|
    conflict(result, "project_role_rules[#{entry["index"]}]", "Project rule entry must be a path string or mapping with path/file.")
  end

  default_missing.each do |entry|
    conflict(result, "orbit_default.#{entry["path"]}", "Orbit default rule reference is missing from the installed skill.")
  end
end

def task_rule_summary(task_path, task)
  return nil unless task

  {
    "path" => File.expand_path(task_path),
    "quality_rules" => task["quality_rules"].is_a?(Array) ? task["quality_rules"] : [],
    "acceptance" => task["acceptance"].is_a?(Array) ? task["acceptance"] : [],
    "evidence_requirements" => task["evidence_requirements"].is_a?(Array) ? task["evidence_requirements"] : [],
    "source_documents" => task["source_documents"].is_a?(Array) ? task["source_documents"] : [],
    "stop_policy" => task["stop_policy"].is_a?(Hash) ? task["stop_policy"] : nil,
    "final_audit" => task["final_audit"].is_a?(Hash) ? task["final_audit"] : nil
  }
end

def parse_rules_args(args)
  subcommand = args.shift
  usage_error("Missing rules subcommand.") unless subcommand

  options = {
    "subcommand" => subcommand,
    "json" => false
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--json"
      options["json"] = true
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--role"
      options["role"] = option_value(args, "--role")
    when /\A--role=(.+)\z/
      options["role"] = Regexp.last_match(1)
    when "--instance"
      options["instance"] = option_value(args, "--instance")
    when /\A--instance=(.+)\z/
      options["instance"] = Regexp.last_match(1)
    when "--output"
      options["output"] = option_value(args, "--output")
    when /\A--output=(.+)\z/
      options["output"] = Regexp.last_match(1)
    else
      usage_error("Unknown rules #{subcommand} option: #{arg}")
    end
  end

  usage_error("Unknown rules subcommand: #{subcommand}") unless %w[resolve print-context].include?(subcommand)
  usage_error("rules #{subcommand} currently requires --json") unless options["json"]
  usage_error("Use only one of --role or --instance.") if options["role"] && options["instance"]

  options
end

def with_rule_resolution_identity(options)
  previous_instance = ENV["ORBIT_INSTANCE"]
  previous_role = ENV["ORBIT_ROLE"]

  if options["instance"]
    ENV["ORBIT_INSTANCE"] = options["instance"]
    ENV.delete("ORBIT_ROLE")
  elsif options["role"]
    ENV.delete("ORBIT_INSTANCE")
    ENV["ORBIT_ROLE"] = options["role"]
  end

  yield
ensure
  if previous_instance.nil?
    ENV.delete("ORBIT_INSTANCE")
  else
    ENV["ORBIT_INSTANCE"] = previous_instance
  end

  if previous_role.nil?
    ENV.delete("ORBIT_ROLE")
  else
    ENV["ORBIT_ROLE"] = previous_role
  end
end

def rule_resolution(options)
  result = {
    "schema_version" => "orbit-rule-resolution-v1",
    "project" => File.basename(Dir.pwd),
    "instance" => nil,
    "resolved_role" => nil,
    "role_sources" => {},
    "sources" => {
      "orbit_default" => [],
      "project_rules" => [],
      "task_rules" => nil,
      "rule_packs" => []
    },
    "checks" => {},
    "conflicts" => [],
    "warnings" => [],
    "valid" => false
  }

  roles, instances = load_project_config(result)
  task = load_task(result, options["task"])

  with_rule_resolution_identity(options) do
    role_def = resolve_identity(result, roles, instances)
    apply_task_constraints(result, task)

    if role_def
      task_type = task ? task["task_type"] : nil
      result["sources"]["orbit_default"] = default_rule_entries(result["resolved_role"], task_type)
      result["sources"]["project_rules"] = project_rule_entries(role_def)
      result["sources"]["task_rules"] = task_rule_summary(options["task"], task)
      result["sources"]["rule_packs"] = rule_packs_for_context(result["resolved_role"], task_type)
      result["capabilities"] = role_def["capabilities"] || []
      result["permissions"] = role_def["permissions"] || {}
    end
  end

  add_rule_resolution_checks(result)
  result["valid"] = result["conflicts"].empty?
  result
end

def rule_context_entry(entry, source, required:, default_load_policy: "required", reason: nil)
  path = entry["path"]
  absolute_path = entry["absolute_path"] || (path ? File.expand_path(path, Dir.pwd) : nil)
  load_policy = entry["load_policy"] || default_load_policy
  context = {
    "source" => source,
    "category" => entry["category"],
    "id" => entry["id"],
    "rule_id" => entry["rule_id"] || entry["id"] || (path ? "#{source}:#{path}" : "#{source}:#{entry["index"]}"),
    "relation" => entry["relation"] || "supplements",
    "index" => entry["index"],
    "path" => path,
    "absolute_path" => absolute_path,
    "exists" => entry.key?("exists") ? entry["exists"] : (absolute_path ? File.file?(absolute_path) : nil),
    "load_policy" => load_policy,
    "required" => required,
    "reason" => entry["reason"] || reason
  }.compact
  context["metadata"] = entry.reject { |key, _value| context.key?(key) || %w[absolute_path exists load_policy reason source].include?(key) }
  context.delete("metadata") if context["metadata"].empty?
  context
end

def task_context_entry(task_rules)
  return nil unless task_rules.is_a?(Hash)

  path = task_rules["path"]
  {
    "source" => "task_rules",
    "rule_id" => "task_rules:#{path}",
    "relation" => "supplements",
    "path" => path,
    "absolute_path" => path,
    "exists" => path ? File.file?(path) : false,
    "load_policy" => "required",
    "required" => true,
    "reason" => "Current task contract fields: quality_rules, acceptance, evidence_requirements, source_documents, stop_policy, and final_audit.",
    "inline_sections" => {
      "quality_rules" => task_rules["quality_rules"] || [],
      "acceptance" => task_rules["acceptance"] || [],
      "evidence_requirements" => task_rules["evidence_requirements"] || [],
      "source_documents" => task_rules["source_documents"] || []
    }
  }
end

def rule_dedupe_key(entry)
  absolute_path = entry["absolute_path"].to_s
  return "path:#{absolute_path}" unless absolute_path.empty?

  rule_id = entry["rule_id"].to_s
  return "rule:#{rule_id}" unless rule_id.empty?

  "entry:#{entry["source"]}:#{entry["path"]}:#{entry["index"]}"
end

def annotate_rule_context_budget(load_order)
  seen = {}
  active = []
  deduped = []

  load_order.each do |entry|
    key = rule_dedupe_key(entry)
    if seen.key?(key)
      entry["dedupe_status"] = "deduped"
      entry["deduped_by"] = seen[key]["rule_id"] || seen[key]["path"]
      deduped << {
        "rule_id" => entry["rule_id"],
        "path" => entry["path"],
        "source" => entry["source"],
        "deduped_by" => entry["deduped_by"]
      }.compact
    else
      entry["dedupe_status"] = "active"
      seen[key] = entry
      active << entry
    end
  end

  {
    "active" => active.map { |entry| { "rule_id" => entry["rule_id"], "path" => entry["path"], "source" => entry["source"] }.compact },
    "deduped" => deduped,
    "shadowed" => [],
    "not_loaded_but_related" => []
  }
end

def rules_context_pack(resolution)
  sources = resolution["sources"] || {}
  load_order = []

  (sources["orbit_default"] || []).each do |entry|
    load_order << rule_context_entry(
      entry,
      "orbit_default",
      required: entry["load_policy"] == "required",
      default_load_policy: "required"
    )
  end

  (sources["project_rules"] || []).each do |entry|
    load_order << rule_context_entry(
      entry,
      "project_role_rules",
      required: true,
      default_load_policy: "required",
      reason: "Project/user rule configured in .orbit/roles.yaml for this role."
    )
  end

  task_entry = task_context_entry(sources["task_rules"])
  load_order << task_entry if task_entry

  (sources["rule_packs"] || []).each do |entry|
    load_order << rule_context_entry(
      entry,
      "rule_packs",
      required: false,
      default_load_policy: "conditional",
      reason: "Configured project rule pack reference for this role/task context."
    )
  end

  context_budget = annotate_rule_context_budget(load_order)
  required_files = load_order.select { |entry| entry["dedupe_status"] == "active" && entry["required"] && entry["absolute_path"] }
  # context_hash fingerprints the exact ordered rule set so evidence can reference it.
  context_hash_input = JSON.generate(load_order.map { |e| e["rule_id"] || e["path"] })
  context_hash = Digest::SHA256.hexdigest(context_hash_input)
  {
    "schema_version" => "orbit-rules-context-v1",
    "project" => resolution["project"],
    "instance" => resolution["instance"],
    "resolved_role" => resolution["resolved_role"],
    "role_sources" => resolution["role_sources"],
    "valid" => resolution["valid"],
    "conflicts" => resolution["conflicts"],
    "warnings" => resolution["warnings"],
    "load_model" => {
      "default_rules_always_loaded" => true,
      "project_rules_are_additive" => true,
      "task_rules_are_turn_scoped" => true,
      "semantic_merge" => "not_performed_by_cli"
    },
    "load_order" => load_order,
    "required_files" => required_files,
    "context_budget" => context_budget,
    "rule_packs" => sources["rule_packs"] || [],
    "context_hash" => context_hash,
    "resolution_summary" => {
      "default_rule_count" => (sources["orbit_default"] || []).length,
      "project_rule_count" => (sources["project_rules"] || []).length,
      "task_rule_present" => !!sources["task_rules"],
      "rule_pack_count" => (sources["rule_packs"] || []).length
    },
    "next_actions" => [
      "Read every required file in required_files before doing role work.",
      "Treat project rules as additive to Orbit defaults, not as replacements.",
      "If rules conflict, record the conflict or ask for a user waiver instead of silently overriding the default loop."
    ],
    "rule_resolution" => resolution
  }
end

def rules(args)
  options = parse_rules_args(args)
  result = rule_resolution(options)
  result = rules_context_pack(result) if options["subcommand"] == "print-context"
  json = "#{JSON.pretty_generate(result)}\n"

  if options["output"]
    output_path = File.expand_path(options["output"])
    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, json)
  end

  print json
  exit(result["valid"] ? 0 : 1)
end

def parse_classify_intent_args(args)
  options = {
    "json" => false,
    "text" => nil
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--json"
      options["json"] = true
    when "--text"
      options["text"] = option_value(args, "--text")
    when /\A--text=(.+)\z/
      options["text"] = Regexp.last_match(1)
    else
      usage_error("Unknown classify-intent option: #{arg}")
    end
  end

  usage_error("classify-intent requires --json") unless options["json"]
  usage_error("classify-intent requires --text TEXT") if options["text"].to_s.strip.empty?
  options
end

def explicit_orbit_workflow_request?(text)
  normalized = text.to_s.downcase
  normalized.match?(/((按|以|用|走|执行|继续|开始|启动|进入).{0,20}(orbit|流程|workflow))|((orbit|workflow).{0,12}(流程|执行|跑完|继续|闭环))|(正式.{0,8}(task|任务))/i)
end

def classify_intent_policy(intent, text)
  explicit_orbit = explicit_orbit_workflow_request?(text)
  docs_affects_orbit = text.match?(/\.orbit|evidence|handoff|archive|归档|路径|历史|规则|rule/i)

  policy = case intent
           when "discussion"
             {
               "formal_task" => false,
               "evidence" => false,
               "gates" => false,
               "default_task_type" => nil,
               "skip_task_reason_required" => true
             }
           when "design"
             {
               "formal_task" => true,
               "evidence" => true,
               "gates" => true,
               "default_task_type" => "design"
             }
           when "docs_maintenance"
             {
               "formal_task" => docs_affects_orbit,
               "evidence" => docs_affects_orbit,
               "gates" => docs_affects_orbit,
               "default_task_type" => "docs_maintenance",
               "skip_task_reason_required" => !docs_affects_orbit
             }
           when "review"
             {
               "formal_task" => true,
               "evidence" => true,
               "gates" => false,
               "default_task_type" => "review"
             }
           when "test"
             {
               "formal_task" => true,
               "evidence" => true,
               "gates" => false,
               "default_task_type" => "test"
             }
           when "handoff"
             {
               "formal_task" => true,
               "evidence" => true,
               "gates" => false,
               "default_task_type" => "handoff"
             }
           else
             {
               "formal_task" => true,
               "evidence" => true,
               "gates" => true,
               "default_task_type" => "coding"
             }
           end

  if explicit_orbit
    policy["formal_task"] = true
    policy["evidence"] = true
    policy["gates"] = true unless %w[review test handoff].include?(intent)
    policy.delete("skip_task_reason_required")
  end

  policy
end

def classify_intent_text(text)
  normalized = text.to_s.downcase
  checks = [
    ["handoff", /handoff|交接|接手/],
    ["test", /test|测试|e2e|qa|验证/],
    ["review", /review|评审|审查|reviewer/],
    ["discussion", /讨论|怎么看|觉得|建议|brainstorm|question|问题/],
    ["design", /design|设计|方案|analysis|分析|计划/],
    ["docs_maintenance", /docs|document|文档|归档|archive|readme/],
    ["coding", /fix|implement|coding|code|改代码|修复|实现|继续/]
  ]

  matched = checks.find { |_intent, pattern| normalized.match?(pattern) }
  intent = matched ? matched.first : "discussion"
  explicit_orbit = explicit_orbit_workflow_request?(normalized)
  intent = "coding" if explicit_orbit && intent == "discussion"

  {
    "intent" => intent,
    "confidence" => matched ? "medium" : "low",
    "reason" => matched ? "Matched #{intent} workflow keywords." : "No strong workflow keyword matched; defaulting to discussion.",
    "explicit_orbit_workflow" => explicit_orbit
  }
end

# Slice 11: recommend a risk level based on intent and text.
# Release and UI/behavior-changing signals are checked FIRST so they override
# discussion/docs fallbacks that would otherwise produce "light".
def intent_risk_recommendation(intent, text)
  normalized = text.to_s.downcase

  # Priority 1: release/deploy signals always yield release risk.
  is_release = normalized.match?(/release|deploy|publish|ship|发布|上线|部署/)
  return { "level" => "release", "rationale" => "Release/deploy intent requires release readiness evidence." } if is_release

  # Priority 2: UI/behavior-changing signals yield standard risk.
  is_ui_or_behavior = normalized.match?(/ui|ux|interface|button|form|page|screen|按钮|交互|页面|change|changing|修改|behavior/)
  return { "level" => "standard", "rationale" => "UI or behavior change requires review and test gates." } if is_ui_or_behavior

  # Priority 3: intent-based defaults.
  case intent
  when "discussion"
    { "level" => "light", "rationale" => "Discussion does not require formal gates." }
  when "docs_maintenance"
    affects_orbit = normalized.match?(/\.orbit|evidence|handoff|archive|rule/)
    { "level" => affects_orbit ? "standard" : "light", "rationale" => affects_orbit ? "Docs change affects Orbit runtime; use standard." : "Light docs edit; no formal gate required." }
  else
    { "level" => "standard", "rationale" => "Behavior-changing task; use standard risk level." }
  end
end

def classify_intent(args)
  options = parse_classify_intent_args(args)
  text = options["text"].to_s
  classification = classify_intent_text(text)
  result = {
    "schema_version" => "orbit-intent-classification-v1",
    "project" => File.basename(Dir.pwd),
    "input" => {
      "text" => text
    },
    "intent" => classification["intent"],
    "confidence" => classification["confidence"],
    "reason" => classification["reason"],
    "explicit_orbit_workflow" => classification["explicit_orbit_workflow"],
    "policy" => classify_intent_policy(classification["intent"], text),
    "risk_recommendation" => intent_risk_recommendation(classification["intent"], text),
    "allowed_intents" => %w[discussion design docs_maintenance coding review test handoff]
  }

  puts JSON.pretty_generate(result)
end

def whoami(args)
  task_path = parse_whoami_args(args)
  result = {
    "schema_version" => "orbit-whoami-v1",
    "project" => File.basename(Dir.pwd),
    "instance" => nil,
    "resolved_role" => nil,
    "role_sources" => {},
    "rules" => [],
    "rule_packs" => [],
    "capabilities" => [],
    "permissions" => {},
    "conflicts" => []
  }

  roles, instances = load_project_config(result)
  task = load_task(result, task_path)
  role_def = resolve_identity(result, roles, instances)

  if role_def
    result["rules"] = role_def["rules"] || []
    result["rule_packs"] = rule_packs_for_context(result["resolved_role"], task ? task["task_type"] : nil)
    result["capabilities"] = role_def["capabilities"] || []
    result["permissions"] = role_def["permissions"] || {}
  end

  apply_task_constraints(result, task)

  result["role_config_sha256"] = sha256_file(File.join(Dir.pwd, ".orbit", "roles.yaml"))

  puts JSON.pretty_generate(result)
  exit(result["conflicts"].empty? ? 0 : 1)
end

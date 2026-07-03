# frozen_string_literal: true

def parse_hook_args(args)
  subcommand = args.shift
  usage_error("Missing hook subcommand.") unless subcommand
  options = { "subcommand" => subcommand, "json" => false }
  until args.empty?
    arg = args.shift
    case arg
    when "--intent-json" then options["intent_json"] = option_value(args, "--intent-json")
    when /\A--intent-json=(.+)\z/ then options["intent_json"] = Regexp.last_match(1)
    when "--json" then options["json"] = true
    else usage_error("Unknown hook #{subcommand} option: #{arg}")
    end
  end
  usage_error("hook #{subcommand} requires --intent-json PATH|-") if options["intent_json"].to_s.empty?
  usage_error("hook #{subcommand} requires --json") unless options["json"]
  options
end

def load_hook_intent(source)
  raw = source == "-" ? $stdin.read : File.read(File.expand_path(source))
  JSON.parse(raw)
rescue Errno::ENOENT
  usage_error("Missing intent-json file: #{source}")
rescue JSON::ParserError
  usage_error("hook --intent-json must be JSON.")
end

def hook_identity_for_task(task_path, evidence_path = nil)
  result = {
    "project" => File.basename(Dir.pwd),
    "instance" => nil,
    "resolved_role" => nil,
    "role_sources" => {},
    "conflicts" => []
  }
  roles, instances = load_project_config(result)
  task = load_task(result, task_path)
  evidence = evidence_path ? hook_load_evidence(evidence_path) : nil
  resolve_identity(result, roles, instances)
  apply_task_constraints(result, task, evidence)
  result
end

def hook_load_evidence(path)
  return nil if path.to_s.empty?

  load_evidence_manifest(File.expand_path(path))
rescue SystemExit
  raise
rescue StandardError
  nil
end

def hook_command_tokens(intent)
  command = intent["command"] || intent["argv"]
  case command
  when Array then command.map(&:to_s)
  when String then Shellwords.split(command)
  else []
  end
rescue ArgumentError
  Array(command).map(&:to_s)
end

def hook_start_force_request(intent)
  instance = hook_start_instance(intent)
  force = intent["force"] == true || intent["force"].to_s == "true"
  tokens = hook_command_tokens(intent)
  if tokens.include?("--force") && (idx = tokens.index("start"))
    instance ||= tokens[idx + 1]
    force = true
  end
  return nil unless force && !instance.to_s.empty?

  instance.to_s
end

def hook_start_instance(intent)
  instance = intent["instance"] || intent["target_instance"]
  tokens = hook_command_tokens(intent)
  if instance.to_s.empty? && (idx = tokens.index("start"))
    instance = tokens[idx + 1]
  end
  instance.to_s
end

def hook_instance_status(instance_key)
  return nil if instance_key.to_s.empty?

  result = { "role_sources" => {}, "conflicts" => [] }
  roles, instances = load_project_config(result)
  resolved_key, = find_instance(instances, roles, instance_key)
  instance = resolved_key ? instances[resolved_key] : nil
  return nil unless resolved_key && instance.is_a?(Hash)

  role_ref = instance["role_ref"]
  role_def = roles[role_ref]
  return nil unless role_def.is_a?(Hash)

  instance_status_entry(resolved_key, instance, role_ref, role_def)
rescue StandardError
  nil
end

def hook_force_cooldown_seconds
  value = ENV["ORBIT_START_FORCE_COOLDOWN_SECONDS"].to_s
  value.empty? ? 120 : value.to_i
end

def hook_recent_force_replacement(instance)
  cooldown = hook_force_cooldown_seconds
  return nil unless cooldown.positive?

  path = start_instance_runtime_path(instance)
  return nil unless File.file?(path)

  data = JSON.parse(File.read(path))
  return nil unless data["schema_version"] == "orbit-start-replacement-v1"

  replaced_at = Time.iso8601(data["replaced_at"].to_s)
  age = Time.now.utc - replaced_at
  return nil if age.negative? || age > cooldown

  {
    "instance" => instance,
    "replacement" => path.sub("#{Dir.pwd}/", ""),
    "age_seconds" => age.round(3),
    "cooldown_seconds" => cooldown
  }
rescue JSON::ParserError, ArgumentError
  nil
end

def hook_completion_notice_summary(task, evidence, evidence_path)
  completion_notice_summary(task, evidence, evidence_path: evidence_path)
end

def hook_intent_paths(intent)
  Array(intent["paths"] || intent["path"]).map(&:to_s)
end

def hook_production_path?(path)
  value = path.to_s
  return false if value.empty?
  return false if value.start_with?(".orbit/")
  return false if value.start_with?("docs/", "references/")
  return false if %w[README.md CHANGELOG.md].include?(value)

  true
end

def hook_result(subcommand, intent)
  task_path = intent["task"]
  evidence_path = intent["evidence"]
  identity = task_path ? hook_identity_for_task(task_path, evidence_path) : nil
  task = task_path ? load_task({ "role_sources" => {}, "conflicts" => [] }, task_path) : nil
  evidence = hook_load_evidence(evidence_path)
  paths = hook_intent_paths(intent)
  blocked = []
  warnings = []
  recommended_action = "allow"

  if intent.key?("live_probe") || intent.key?("transport_binding") || intent.key?("manual_payload") || intent.key?("explicit_pane") || intent.key?("observed_geometry") || intent.key?("view")
    warnings << "caller_supplied_liveness_ignored"
  end

  if subcommand == "pre-command"
    tokens = hook_command_tokens(intent)
    if tokens.first == "rm" && tokens.any? { |token| token.include?(".orbit/runtime") || token.include?(".orbit/instances.yaml") }
      blocked << "direct_orbit_runtime_delete"
    end
  end

  if %w[pre-command pre-start].include?(subcommand)
    force_instance = hook_start_force_request(intent)
    if force_instance && (recent = hook_recent_force_replacement(force_instance))
      blocked << "start_force_cooldown"
      warnings << "recent_force_replacement"
      recommended_action = "wait_or_reuse_existing_replacement"
      intent["force_cooldown"] = recent
    end
  end

  if %w[pre-command pre-edit pre-evidence].include?(subcommand)
    if identity && identity.dig("execution_context", "allowed") == false
      blocked << "role_boundary"
    end
  end

  if subcommand == "pre-edit" &&
     identity &&
     identity.dig("execution_context", "mode") == "owner" &&
     identity.dig("execution_contract", "operation_mode") == "team" &&
     paths.any? { |path| hook_production_path?(path) }
    blocked << "owner_cannot_edit_production"
    recommended_action = "delegate_to_assigned_instance"
  end

  if %w[pre-edit pre-evidence].include?(subcommand)
    blocked << "direct_orbit_evidence_edit" if paths.any? { |p| p.include?(".orbit/") && p.match?(/evidence.*\.json|runtime/) }
  end

  if subcommand == "pre-start"
    status = hook_instance_status(hook_start_instance(intent))
    if status&.dig("view_status", "too_narrow") == true
      recommended_action = "resize_or_recreate_view"
      warnings << "pane_too_narrow"
    end
  end

  if subcommand == "pre-idle"
    notice_summary = hook_completion_notice_summary(task, evidence, evidence_path)
    if notice_summary["missing_events"].any?
      warnings << "missing_completion_notice"
      recommended_action = "write_completion_notice"
    elsif notice_summary["unacked_events"].any?
      warnings << "unacked_completion_notice"
      recommended_action = "ack_completion_notice"
    end
  end

  {
    "schema_version" => "orbit-hook-v1",
    "hook" => subcommand,
    "allowed" => blocked.empty?,
    "blocked_reasons" => blocked,
    "warnings" => warnings,
    "recommended_action" => recommended_action,
    "force_cooldown" => intent["force_cooldown"],
    "target_instance_status" => subcommand == "pre-start" ? hook_instance_status(hook_start_instance(intent)) : nil,
    "identity" => identity&.slice("resolved_role", "resolved_instance", "execution_contract", "execution_context", "conflicts"),
    "herdr_context_summary" => {
      "current_pane_env_present" => !ENV["HERDR_PANE_ID"].to_s.empty?,
      "caller_liveness_ignored" => warnings.include?("caller_supplied_liveness_ignored")
    }
  }.compact
end

def hook(args)
  options = parse_hook_args(args)
  allowed = %w[pre-command pre-edit pre-evidence pre-start pre-idle]
  usage_error("Unknown hook subcommand: #{options["subcommand"]}") unless allowed.include?(options["subcommand"])
  intent = load_hook_intent(options["intent_json"])
  puts JSON.pretty_generate(hook_result(options["subcommand"], intent))
end

def parse_start_args(args)
  instance = args.shift
  usage_error("Missing start instance.") if instance.nil? || instance.start_with?("--")

  options = {
    "instance" => instance,
    "transport" => "local",
    "cwd" => Dir.pwd,
    "allow_create" => false,
    "dry_run" => false,
    "json" => false
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--transport"
      options["transport"] = option_value(args, "--transport")
    when /\A--transport=(.+)\z/
      options["transport"] = Regexp.last_match(1)
    when "--cwd"
      options["cwd"] = option_value(args, "--cwd")
    when /\A--cwd=(.+)\z/
      options["cwd"] = Regexp.last_match(1)
    when "--dry-run"
      options["dry_run"] = true
    when "--allow-create"
      options["allow_create"] = true
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown start option: #{arg}")
    end
  end

  usage_error("start --transport must be local or herdr") unless %w[local herdr].include?(options["transport"])
  options
end

def start_plan(options)
  instance_key, instance_alias, instance, role_ref, role_def = load_instance_for_launch(options["instance"])
  argv = normalize_command_argv(instance["command"], "Instance #{instance_key.inspect}")
  cwd = File.expand_path(options["cwd"])
  usage_error("Start cwd does not exist: #{cwd}") unless Dir.exist?(cwd)
  status = instance_status_entry(instance_key, instance, role_ref, role_def)
  creation_policy = role_creation_policy(options["transport"])

  {
    "schema_version" => "orbit-start-plan-v1",
    "project" => File.basename(Dir.pwd),
    "instance" => instance_key,
    "requested_instance" => options["instance"],
    "instance_alias" => instance_alias,
    "role_ref" => role_ref,
    "resolved_role" => role_def["role"] || role_ref,
    "transport" => options["transport"],
    "cwd" => cwd,
    "argv" => argv,
    "client" => start_client_metadata(argv),
    "env" => instance_launch_env(instance_key, instance, role_def, role_ref),
    "context_preflight" => context_preflight_for(instance_key),
    "instance_status" => status,
    "creation_policy" => creation_policy,
    "dry_run" => options["dry_run"]
  }.compact
end

def context_preflight_for(instance_key, task_path: nil)
  options = { "instance" => instance_key }
  options["task"] = task_path if task_path
  context = rules_context_pack(rule_resolution(options))
  rule_task_args = task_path ? ["--task", File.expand_path(task_path)] : []
  {
    "schema_version" => "orbit-context-preflight-v1",
    "instance" => instance_key,
    "resolved_role" => context["resolved_role"],
    "valid" => context["valid"],
    "conflicts" => context["conflicts"] || [],
    "warnings" => context["warnings"] || [],
    "required_files" => (context["required_files"] || []).map do |entry|
      {
        "source" => entry["source"],
        "category" => entry["category"],
        "rule_id" => entry["rule_id"],
        "path" => entry["path"],
        "absolute_path" => entry["absolute_path"],
        "load_policy" => entry["load_policy"],
        "reason" => entry["reason"]
      }.compact
    end,
    "commands" => [
      ["orbit", "whoami", "--json"],
      ["orbit", "rules", "resolve", *rule_task_args, "--instance", instance_key, "--json"],
      ["orbit", "rules", "print-context", *rule_task_args, "--instance", instance_key, "--json"]
    ],
    "next_actions" => context["next_actions"] || []
  }
rescue RuntimeError => e
  {
    "schema_version" => "orbit-context-preflight-v1",
    "instance" => instance_key,
    "valid" => false,
    "conflicts" => [{ "source" => "context_preflight", "message" => e.message }],
    "warnings" => [],
    "required_files" => [],
    "commands" => []
  }
end

def non_empty_env(*names)
  names.each do |name|
    value = ENV[name].to_s.strip
    return value unless value.empty?
  end
  ""
end

def lead_transport_binding
  roles, instances = load_project_instance_config_for_cli[0, 2]
  lead_key = find_instance(instances, roles, "lead").first || infer_instance_from_role(instances, roles, "lead")
  return {} unless lead_key && instances[lead_key].is_a?(Hash)

  normalize_instance_transport(lead_key, instances[lead_key])["binding"] || {}
rescue RuntimeError
  {}
end

def herdr_same_level_view
  lead_binding = lead_transport_binding
  source_pane = non_empty_env("HERDR_PANE_ID")
  source_pane = lead_binding["pane"].to_s if source_pane.empty?

  tab = non_empty_env("HERDR_TAB_ID", "HERDR_TAB")
  tab = lead_binding["tab"].to_s if tab.empty?

  workspace = non_empty_env("HERDR_WORKSPACE_ID", "HERDR_WORKSPACE", "HERDR_SPACE_ID", "HERDR_SPACE")
  workspace = lead_binding["space"].to_s if workspace.empty?

  strategy = if !tab.empty?
               "same_tab"
             elsif !workspace.empty?
               "same_workspace"
             elsif !source_pane.empty?
               "source_pane_recorded"
             else
               "fallback_default_view"
             end

  {
    "strategy" => strategy,
    "source_pane" => source_pane,
    "tab" => tab,
    "workspace" => workspace,
    "source" => "HERDR_* env or lead transport binding",
    "fallback" => strategy == "fallback_default_view" || strategy == "source_pane_recorded"
  }
end

def role_creation_policy(transport)
  policy = {
    "reuse_first" => true,
    "user_managed_requires_allow_create" => true,
    "permission_setup" => {
      "required" => true,
      "mode" => "operator_or_client_specific",
      "summary" => "Before assigning tool work to a newly-created role, ensure the agent client has the required permissions or approval mode. Orbit records this requirement but does not silently bypass user approval."
    }
  }
  policy["same_level_view"] = herdr_same_level_view if transport == "herdr"
  policy
end

def start_client_metadata(argv)
  executable = File.basename(argv.first.to_s)
  full_permission_flags = {
    "codex" => ["--dangerously-bypass-approvals-and-sandbox"],
    "claude" => ["--dangerously-skip-permissions"],
    "opencode" => ["--dangerously-skip-permissions"]
  }
  required_flags = full_permission_flags.fetch(executable, [])
  present_flags = required_flags.select { |flag| argv.include?(flag) }
  {
    "expected_client" => executable,
    "argv" => argv,
    "full_permission" => {
      "known_client" => full_permission_flags.key?(executable),
      "required_flags" => required_flags,
      "present_flags" => present_flags,
      "configured" => !required_flags.empty? && (required_flags - present_flags).empty?,
      "mode" => required_flags.empty? ? "unknown_client" : "argv_flag",
      "note" => "Full-permission flags are audited in the start plan; the client may still require runtime approval, so completion must be verified through evidence and wait-gate."
    }
  }
end

def start_requires_reuse?(plan)
  plan.dig("instance_status", "recommended_action") == "reuse"
end

def herdr_bound_pane(plan)
  transport = plan.dig("instance_status", "transport") || {}
  return "" unless transport["kind"] == "herdr"

  transport.dig("binding", "pane").to_s
end

def herdr_agent_list_for_pane(herdr_path, pane)
  stdout, stderr, status = Open3.capture3(herdr_path, "agent", "list")
  return [nil, { "success" => false, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }] unless status.success?

  parsed = JSON.parse(stdout)
  agents = parsed.dig("result", "agents") || parsed["agents"] || []
  pane_ids = Array(pane).map(&:to_s)
  agent = agents.find do |entry|
    entry.is_a?(Hash) &&
      pane_ids.include?(entry["pane_id"].to_s) &&
      !entry["agent"].to_s.strip.empty?
  end
  [agent, { "success" => true, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }]
rescue JSON::ParserError => e
  [nil, { "success" => false, "stdout" => stdout.to_s, "stderr" => e.message, "exit_status" => status&.exitstatus }]
end

def herdr_pane_info(herdr_path, pane)
  return [nil, { "success" => false, "reason" => "empty pane id" }] if pane.to_s.empty?

  stdout, stderr, status = Open3.capture3(herdr_path, "pane", "get", pane.to_s)
  return [nil, { "success" => false, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }] unless status.success?

  parsed = JSON.parse(stdout)
  info = parsed.dig("result", "pane") || parsed["pane"] || parsed.dig("result") || parsed
  [info, { "success" => true, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }]
rescue JSON::ParserError => e
  [nil, { "success" => false, "stdout" => stdout.to_s, "stderr" => e.message, "exit_status" => status&.exitstatus }]
end

def current_herdr_pane_info(herdr_path)
  current_pane = ENV["HERDR_PANE_ID"].to_s
  return [nil, { "success" => false, "reason" => "HERDR_PANE_ID is not set" }] if current_pane.empty?

  herdr_pane_info(herdr_path, current_pane)
end

def pane_output_safe_to_wake?(output)
  text = output.to_s
  return true if text.strip.empty?
  return false if text.match?(/OpenAI Codex|Claude Code|opencode|esc to interrupt|bypass permissions/i)

  last_line = text.lines.map(&:strip).reject(&:empty?).last.to_s
  last_line.match?(/[#$%>❯›]\s*\z/)
end

def herdr_reuse_probe(plan, herdr_path = nil)
  pane = herdr_bound_pane(plan)
  return nil if pane.empty?

  herdr_path ||= command_path("herdr")
  return {
    "schema_version" => "orbit-herdr-reuse-probe-v1",
    "pane" => pane,
    "agent_detected" => false,
    "safe_to_wake" => false,
    "decision" => "needs_attention",
    "reason" => "herdr command not found"
  } unless herdr_path

  bound_pane_info, pane_get_result = herdr_pane_info(herdr_path, pane)
  canonical_pane = bound_pane_info["pane_id"].to_s unless bound_pane_info.nil?
  canonical_pane = pane if canonical_pane.to_s.empty?
  current_pane_info, current_pane_result = current_herdr_pane_info(herdr_path)
  current_pane = current_pane_info["pane_id"].to_s unless current_pane_info.nil?
  current_pane = ENV["HERDR_PANE_ID"].to_s if current_pane.to_s.empty?
  self_pane = !current_pane.to_s.empty? && [pane.to_s, canonical_pane.to_s].include?(current_pane.to_s)
  agent, list_result = herdr_agent_list_for_pane(herdr_path, [pane, canonical_pane])
  probe = {
    "schema_version" => "orbit-herdr-reuse-probe-v1",
    "pane" => pane,
    "canonical_pane" => canonical_pane,
    "current_pane" => current_pane,
    "self_pane" => self_pane,
    "pane_get" => pane_get_result,
    "current_pane_get" => current_pane_result,
    "agent_list" => list_result
  }
  if agent
    return probe.merge(
      "agent_detected" => true,
      "agent" => agent["agent"],
      "agent_status" => agent["agent_status"],
      "safe_to_wake" => false,
      "decision" => "reuse",
      "reason" => "bound pane already has a detected agent"
    )
  end
  return probe.merge(
    "agent_detected" => false,
    "safe_to_wake" => false,
    "decision" => "needs_attention",
    "reason" => "could not inspect Herdr agents"
  ) unless list_result["success"]
  if self_pane
    return probe.merge(
      "agent_detected" => false,
      "safe_to_wake" => true,
      "decision" => "self_wake",
      "reason" => "bound pane is the current Herdr pane; start can exec the agent command directly"
    )
  end

  read_stdout, read_stderr, read_status = Open3.capture3(
    herdr_path,
    "pane",
    "read",
    canonical_pane,
    "--source",
    "recent-unwrapped",
    "--lines",
    "40"
  )
  safe_to_wake = read_status.success? && pane_output_safe_to_wake?(read_stdout)
  probe.merge(
    "agent_detected" => false,
    "safe_to_wake" => safe_to_wake,
    "decision" => safe_to_wake ? "wake" : "needs_attention",
    "reason" => safe_to_wake ? "bound pane exists and looks like an idle shell prompt" : "bound pane has no detected agent but is not safe to wake automatically",
    "pane_read" => {
      "success" => read_status.success?,
      "exit_status" => read_status.exitstatus,
      "stdout" => read_stdout,
      "stderr" => read_stderr
    }
  )
end

def wake_command_text(plan)
  env_pairs = (plan["env"] || {}).sort.map { |key, value| "#{key}=#{value}" }
  argv = plan["argv"] || []
  return Shellwords.join(argv) if env_pairs.empty?

  Shellwords.join(["env", *env_pairs, *argv])
end

def herdr_wake_adapter(plan, probe, executable = "herdr")
  pane = probe["canonical_pane"].to_s.empty? ? probe["pane"] : probe["canonical_pane"]
  ready_wait = herdr_start_ready_wait(plan)
  {
    "schema_version" => "orbit-herdr-wake-v1",
    "transport" => "herdr",
    "pane" => pane,
    "command" => [executable, "pane", "run", pane, wake_command_text(plan)],
    "ready_wait" => ready_wait
  }.compact
end

def self_wake_plan(plan, probe)
  {
    "schema_version" => "orbit-herdr-self-wake-v1",
    "transport" => "herdr",
    "pane" => probe["canonical_pane"] || probe["pane"],
    "command" => wake_command_text(plan),
    "mode" => "exec_current_process"
  }
end

def start_create_blocked?(plan, options)
  status = plan["instance_status"] || {}
  status["management"] == "user_managed" &&
    status["recommended_action"] == "ask_user_or_bind" &&
    !options["allow_create"]
end

def print_start_blocked(plan)
  warn "Orbit start blocked:"
  warn "- instance: #{plan["instance"]}"
  warn "- role: #{plan["resolved_role"]}"
  warn "- management: #{plan.dig("instance_status", "management")}"
  warn "- binding_status: #{plan.dig("instance_status", "binding_status")}"
  warn "- reason: user_managed instances require an existing healthy binding or --allow-create"
end

def print_start_reuse(plan)
  puts "Orbit instance already bound:"
  puts "- instance: #{plan["instance"]}"
  puts "- role: #{plan["resolved_role"]}"
  puts "- action: reuse"
  binding = plan.dig("instance_status", "transport", "binding") || {}
  puts "- pane: #{binding["pane"]}" unless binding["pane"].to_s.empty?
  probe = plan["reuse_probe"] || {}
  puts "- agent: #{probe["agent"]}" if probe["agent"]
end

def print_start_needs_attention(plan)
  warn "Orbit start needs attention:"
  warn "- instance: #{plan["instance"]}"
  warn "- role: #{plan["resolved_role"]}"
  warn "- action: needs_attention"
  warn "- pane: #{plan.dig("reuse_probe", "pane")}" if plan.dig("reuse_probe", "pane")
  warn "- reason: #{plan.dig("reuse_probe", "reason") || plan["reason"]}"
end

def print_start_wake_dry_run(plan)
  puts "Orbit wake plan:"
  puts "- instance: #{plan["instance"]}"
  puts "- role: #{plan["resolved_role"]}"
  puts "- action: wake_dry_run"
  puts "- pane: #{plan.dig("reuse_probe", "pane")}"
  puts "- command: #{plan.dig("wake_adapter", "command", 4)}"
end

def print_start_self_wake_dry_run(plan)
  puts "Orbit self-wake plan:"
  puts "- instance: #{plan["instance"]}"
  puts "- role: #{plan["resolved_role"]}"
  puts "- action: self_wake_dry_run"
  puts "- pane: #{plan.dig("reuse_probe", "canonical_pane") || plan.dig("reuse_probe", "pane")}"
  puts "- command: #{plan.dig("self_wake", "command")}"
end

def herdr_start_argv(plan, executable = "herdr", label = nil)
  argv = [
    executable,
    "agent",
    "start",
    label || plan["instance"],
    "--cwd",
    plan["cwd"]
  ]

  view = plan.dig("creation_policy", "same_level_view") || {}
  if !view["tab"].to_s.empty?
    argv += ["--tab", view["tab"]]
  elsif !view["workspace"].to_s.empty?
    argv += ["--workspace", view["workspace"]]
  end

  argv + [
    "--split",
    "right",
    "--no-focus",
    "--",
    *plan["argv"]
  ]
end

def herdr_agent_name_taken?(stderr)
  parsed = JSON.parse(stderr.to_s)
  parsed.dig("error", "code") == "agent_name_taken"
rescue JSON::ParserError
  stderr.to_s.include?("agent_name_taken")
end

def herdr_retry_label(plan)
  project = plan["project"].to_s
  instance = plan["instance"].to_s
  base = "#{project}-#{instance}".gsub(/[^A-Za-z0-9_.-]+/, "-").gsub(/\A-+|-+\z/, "")
  base = instance.empty? ? "orbit-agent" : instance if base.empty?
  suffix = "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{$$}"
  "#{base[0, 48]}-#{suffix}"
end

def herdr_start_ready_wait(plan)
  return nil unless plan["argv"].first == "codex"

  {
    "mode" => "output_match",
    "match" => "OpenAI Codex|›",
    "timeout_ms" => 10_000
  }
end

def attach_start_adapter_plan(plan)
  return plan unless plan["transport"] == "herdr"

  ready_wait = herdr_start_ready_wait(plan)
  plan.merge(
    "adapter" => {
      "schema_version" => "orbit-herdr-start-v1",
      "transport" => "herdr",
      "command" => herdr_start_argv(plan),
      "label" => plan["instance"],
      "env" => plan["env"],
      "ready_wait" => ready_wait
    }.compact
  )
end

def print_start_human_plan(plan)
  puts "Orbit start plan:"
  puts "- instance: #{plan["instance"]}"
  puts "- role: #{plan["resolved_role"]}"
  puts "- transport: #{plan["transport"]}"
  puts "- cwd: #{plan["cwd"]}"
  puts "- command: #{plan["argv"].join(" ")}"
  unless plan["env"].empty?
    puts "- env:"
    plan["env"].sort.each do |key, value|
      puts "  - #{key}=#{value}"
    end
  end
  if plan["creation_policy"]
    view = plan.dig("creation_policy", "same_level_view")
    puts "- create policy:"
    puts "  - reuse_first: #{plan["creation_policy"]["reuse_first"]}"
    if view
      puts "  - same_level_view: #{view["strategy"]}"
      puts "  - source_pane: #{view["source_pane"]}" unless view["source_pane"].to_s.empty?
      puts "  - tab: #{view["tab"]}" unless view["tab"].to_s.empty?
      puts "  - workspace: #{view["workspace"]}" unless view["workspace"].to_s.empty?
    end
    permission_setup = plan.dig("creation_policy", "permission_setup")
    puts "  - permission_setup: #{permission_setup["summary"]}" if permission_setup
  end
  puts "- action: dry-run" if plan["dry_run"]
end

def print_herdr_start_human_result(result)
  adapter_result = result["adapter_result"] || {}
  if adapter_result["success"]
    puts "Started Orbit instance:"
    puts "- instance: #{result["instance"]}"
    puts "- role: #{result["resolved_role"]}"
    puts "- transport: #{result["transport"]}"
    puts "- cwd: #{result["cwd"]}"
    puts "- pane: #{adapter_result["pane_id"] || "unknown"}"
    if adapter_result["ready_wait"]
      puts "- ready: #{adapter_result["ready_wait"]["success"] ? "pass" : "fail"}"
    end
  else
    warn "Orbit start failed:"
    warn "- instance: #{result["instance"]}"
    warn "- transport: #{result["transport"]}"
    warn "- stderr: #{adapter_result["stderr"]}" if adapter_result["stderr"] && !adapter_result["stderr"].empty?
    if adapter_result["ready_wait"] && !adapter_result["ready_wait"]["success"]
      warn "- ready wait stderr: #{adapter_result["ready_wait"]["stderr"]}"
    end
  end
end

def herdr_start_pane_id(stdout)
  parsed = JSON.parse(stdout)
  if parsed.is_a?(Hash)
    return parsed.dig("result", "agent", "pane_id") if parsed.dig("result", "agent", "pane_id")
    return parsed["pane_id"] if parsed["pane_id"]
  end

  nil
rescue JSON::ParserError
  nil
end

def herdr_start_agent_client(stdout)
  parsed = JSON.parse(stdout)
  return parsed.dig("result", "agent", "agent") if parsed.dig("result", "agent", "agent")
  return parsed.dig("result", "agent") if parsed.dig("result", "agent").is_a?(String)
  return parsed["agent"] if parsed["agent"].is_a?(String)

  nil
rescue JSON::ParserError
  nil
end

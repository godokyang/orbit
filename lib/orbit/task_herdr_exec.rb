def start_pending_next_steps(pane)
  [
    { "inspect_pane" => "herdr pane read #{pane}" },
    { "request_agent" => "请在目标 agent pane 内运行 orbit runtime register --json" }
  ]
end

def start_provisional_session!(plan, pane)
  hashes = runtime_config_hashes(plan["instance"])
  herdr = herdr_current_context
  session = {
    "schema_version" => RUNTIME_SESSION_SCHEMA,
    "session_id" => plan["session_id"],
    "launch_id" => plan["launch_id"],
    "state" => "pending",
    "project_root" => plan["cwd"],
    "project_root_sha256" => runtime_project_root_sha256(plan["cwd"]),
    "project_id" => plan["project"],
    "host_id" => runtime_host_id,
    "user" => runtime_user,
    "instance" => plan["instance"],
    "role" => plan["resolved_role"],
    "role_ref" => plan["role_ref"],
    "role_config_sha256" => hashes["role_config_sha256"],
    "instance_config_sha256" => hashes["instance_config_sha256"],
    "client" => plan.dig("client", "expected_client").to_s,
    "command" => (plan["argv"] || []).join(" "),
    "herdr" => {
      "session" => herdr["session"],
      "workspace" => herdr["workspace"],
      "tab" => herdr["tab"],
      "pane" => pane.to_s,
      "canonical_pane" => pane.to_s
    },
    "identity" => {
      "verification" => "identity_pending",
      "whoami_valid" => nil,
      "conflicts" => []
    }
  }
  runtime_write_session!(session)
  runtime_set_current_session!(plan["instance"], plan["session_id"], "pending")
  session
end

def run_herdr_start(plan, json:)
  herdr_path = command_path("herdr")
  usage_error("herdr command not found. Automatic start/wake requires Herdr. Run `orbit tools doctor --json`, or start the agent manually with ORBIT_INSTANCE and ORBIT_ROLE set.") unless herdr_path

  argv = herdr_start_argv(plan, herdr_path)
  exec_env = ENV.to_hash.merge(plan["env"])
  stdout, stderr, status = Open3.capture3(exec_env, *argv, chdir: plan["cwd"])
  retry_info = nil
  if !status.success? && herdr_agent_name_taken?(stderr)
    retry_label = herdr_retry_label(plan)
    retry_argv = herdr_start_argv(plan, herdr_path, retry_label)
    retry_stdout, retry_stderr, retry_status = Open3.capture3(exec_env, *retry_argv, chdir: plan["cwd"])
    retry_info = {
      "reason" => "agent_name_taken",
      "label" => retry_label,
      "command" => ["herdr", *retry_argv.drop(1)],
      "initial" => {
        "exit_status" => status.exitstatus,
        "stdout" => stdout,
        "stderr" => stderr
      }
    }
    stdout = retry_stdout
    stderr = retry_stderr
    status = retry_status
  end
  adapter = attach_start_adapter_plan(plan)["herdr_start"]
  pane_id = status.success? ? herdr_start_pane_id(stdout) : nil
  actual_client = status.success? ? herdr_start_agent_client(stdout) : nil
  actual_client = plan.dig("client", "expected_client") if actual_client.to_s.empty?
  ready_wait = nil

  if status.success? && pane_id && adapter["ready_wait"]
    wait = adapter["ready_wait"]
    wait_argv = [
      herdr_path,
      "wait",
      "output",
      pane_id,
      "--match",
      wait["match"],
      "--regex",
      "--source",
      "recent-unwrapped",
      "--lines",
      "80",
      "--timeout",
      wait["timeout_ms"].to_s
    ]
    wait_stdout, wait_stderr, wait_status = Open3.capture3(*wait_argv)
    ready_wait = {
      "command" => ["herdr", *wait_argv.drop(1)],
      "exit_status" => wait_status.exitstatus,
      "success" => wait_status.success?,
      "stdout" => wait_stdout,
      "stderr" => wait_stderr
    }
  elsif status.success? && adapter["ready_wait"]
    ready_wait = {
      "success" => false,
      "stdout" => "",
      "stderr" => "Could not parse Herdr pane id from agent start output."
    }
  elsif status.success?
    ready_wait = {
      "success" => nil,
      "status" => "started_unverified",
      "reason" => "no ready marker is configured for this client"
    }
  end

  success = status.success? && (ready_wait.nil? || ready_wait["success"] != false)
  status_after_start = nil
  runtime_session = nil
  if success && pane_id
    runtime_session = start_provisional_session!(plan, pane_id)
    view = plan.dig("creation_policy", "same_level_view") || {}
    status_after_start = write_instance_binding!(
      plan["instance"],
      pane: pane_id,
      tab: view["tab"].to_s,
      workspace: view["workspace"].to_s,
      actual_client: actual_client
    )
  end
  replacement = write_start_replacement_diagnostic!(plan, status_after_start) if success && status_after_start
  result = attach_start_adapter_plan(plan).merge(
    "action" => success ? "started_identity_pending" : "start_failed",
    "dispatch_ready" => false,
    "next" => (success && pane_id ? start_pending_next_steps(pane_id) : nil),
    "runtime_session" => runtime_session,
    "instance_status_after_start" => status_after_start,
    "replacement" => replacement,
    "adapter_result" => {
      "exit_status" => status.exitstatus,
      "success" => success,
      "stdout" => stdout,
      "stderr" => stderr,
      "pane_id" => pane_id,
      "retry" => retry_info,
      "ready_wait" => ready_wait
    }.compact
  ).compact

  if json
    puts JSON.pretty_generate(result)
  else
    print_herdr_start_human_result(result)
  end
  unless success
    failed_exit_status = ready_wait && !ready_wait["success"] ? ready_wait["exit_status"] : status.exitstatus
    exit(failed_exit_status || 1)
  end
end

def run_herdr_wake(plan, probe, json:)
  herdr_path = command_path("herdr")
  usage_error("herdr command not found. Automatic start/wake requires Herdr. Run `orbit tools doctor --json`, or start the agent manually with ORBIT_INSTANCE and ORBIT_ROLE set.") unless herdr_path

  adapter = herdr_wake_adapter(plan, probe, herdr_path)
  stdout, stderr, status = Open3.capture3(*adapter["command"])
  pane = adapter["pane"]
  ready_wait = nil
  if status.success? && adapter["ready_wait"]
    wait = adapter["ready_wait"]
    wait_argv = [
      herdr_path,
      "wait",
      "output",
      pane,
      "--match",
      wait["match"],
      "--regex",
      "--source",
      "recent-unwrapped",
      "--lines",
      "80",
      "--timeout",
      wait["timeout_ms"].to_s
    ]
    wait_stdout, wait_stderr, wait_status = Open3.capture3(*wait_argv)
    ready_wait = {
      "command" => ["herdr", *wait_argv.drop(1)],
      "exit_status" => wait_status.exitstatus,
      "success" => wait_status.success?,
      "stdout" => wait_stdout,
      "stderr" => wait_stderr
    }
  elsif status.success?
    ready_wait = {
      "success" => nil,
      "status" => "started_unverified",
      "reason" => "no ready marker is configured for this client"
    }
  end

  success = status.success? && (ready_wait.nil? || ready_wait["success"] != false)
  binding = plan.dig("instance_status", "herdr") || {}
  status_after_start = nil
  runtime_session = nil
  if success
    runtime_session = start_provisional_session!(plan, pane)
    status_after_start = write_instance_binding!(
      plan["instance"],
      pane: pane,
      tab: binding["tab"].to_s,
      workspace: binding["workspace"].to_s,
      canonical_pane: pane,
      actual_client: plan.dig("client", "expected_client")
    )
  end
  replacement = write_start_replacement_diagnostic!(plan, status_after_start) if success && status_after_start
  result = plan.merge(
    "action" => success ? "started_identity_pending" : "wake_failed",
    "dispatch_ready" => false,
    "next" => (success ? start_pending_next_steps(pane) : nil),
    "runtime_session" => runtime_session,
    "reuse_probe" => probe,
    "wake_adapter" => herdr_wake_adapter(plan, probe),
    "instance_status_after_start" => status_after_start,
    "replacement" => replacement,
    "adapter_result" => {
      "exit_status" => status.exitstatus,
      "success" => success,
      "stdout" => stdout,
      "stderr" => stderr,
      "ready_wait" => ready_wait
    }.compact
  ).compact

  if json
    puts JSON.pretty_generate(result)
  else
    print_herdr_start_human_result(result.merge("adapter_result" => result["adapter_result"].merge("pane_id" => pane)))
  end
  exit(status.exitstatus || 1) unless success
end

def run_herdr_self_wake(plan, probe, json:)
  binding = plan.dig("instance_status", "herdr") || {}
  pane = probe["canonical_pane"] || probe["pane"]
  runtime_session = start_provisional_session!(plan, pane)
  status_after_start = write_instance_binding!(
    plan["instance"],
    pane: pane,
    tab: binding["tab"].to_s,
    workspace: binding["workspace"].to_s,
    canonical_pane: pane,
    actual_client: plan.dig("client", "expected_client")
  )
  replacement = write_start_replacement_diagnostic!(plan, status_after_start)
  result = plan.merge(
    "action" => "started_identity_pending",
    "dispatch_ready" => false,
    "next" => start_pending_next_steps(pane),
    "runtime_session" => runtime_session,
    "reuse_probe" => probe,
    "self_wake" => self_wake_plan(plan, probe),
    "instance_status_after_start" => status_after_start,
    "replacement" => replacement
  ).compact

  if json
    puts JSON.pretty_generate(result)
  else
    puts "Starting Orbit instance in current Herdr pane:"
    puts "- instance: #{plan["instance"]}"
    puts "- role: #{plan["resolved_role"]}"
    puts "- pane: #{pane}"
  end
  $stdout.flush
  $stderr.flush
  Dir.chdir(plan["cwd"]) do
    Process.exec(ENV.to_hash.merge(plan["env"]), *plan["argv"])
  end
rescue SystemCallError => e
  warn "Orbit self-wake failed: #{e.message}"
  exit 1
end

def start(args)
  options = parse_start_args(args)
  plan = attach_start_adapter_plan(start_plan(options))

  if !start_requires_reuse?(plan) && !options["force"]
    candidates = runtime_verified_session_candidates(plan["instance"])
    if candidates.length == 1
      session = candidates.first
      runtime_set_current_session!(plan["instance"], session["session_id"], session["state"])
      result = plan.merge(
        "action" => "reuse_discovered",
        "dispatch_ready" => true,
        "runtime_session" => session,
        "reuse_probe" => {
          "decision" => "reuse_discovered",
          "pane" => session.dig("herdr", "pane"),
          "canonical_pane" => session.dig("herdr", "canonical_pane"),
          "source" => ".orbit/runtime/sessions"
        }
      )
      if options["json"]
        puts JSON.pretty_generate(result)
      else
        print_start_reuse(result)
      end
      return
    elsif candidates.length > 1
      result = plan.merge(
        "action" => "needs_attention",
        "reason" => "ambiguous_verified_runtime_sessions",
        "dispatch_ready" => false,
        "candidates" => candidates.map { |session| session.slice("session_id", "instance", "role", "herdr", "updated_at") }
      )
      if options["json"]
        puts JSON.pretty_generate(result)
      else
        print_start_needs_attention(result)
      end
      exit 1
    end
  end

  if start_requires_reuse?(plan)
    probe = herdr_reuse_probe(plan)
    if !options["force"] && plan.dig("instance_status", "view_status", "too_narrow") == true
      result = plan.merge(
        "action" => "needs_attention",
        "reason" => "pane_too_narrow",
        "recommended_action" => "resize_or_recreate_view",
        "reuse_probe" => probe
      )
      if options["json"]
        puts JSON.pretty_generate(result)
      else
        print_start_needs_attention(result)
      end
      exit 1
    end

    if !options["force"] && probe && probe["decision"] == "reuse"
      runtime_resolution = runtime_resolve_instance(plan["instance"])
      if runtime_resolution["dispatch_ready"]
        result = plan.merge(
          "action" => "reuse_verified",
          "dispatch_ready" => true,
          "reuse_probe" => probe,
          "runtime_resolution" => runtime_resolution.reject { |key, _| %w[runtime_instance runtime_session].include?(key) }
        )
      else
        result = plan.merge(
          "action" => "started_identity_pending",
          "reason" => "binding_agent_found_but_runtime_identity_unverified",
          "dispatch_ready" => false,
          "reuse_probe" => probe,
          "runtime_resolution" => runtime_resolution.reject { |key, _| %w[runtime_instance runtime_session].include?(key) },
          "next" => start_pending_next_steps(probe["canonical_pane"] || probe["pane"])
        )
      end
      if options["json"]
        puts JSON.pretty_generate(result)
      else
        result["dispatch_ready"] ? print_start_reuse(result) : print_start_needs_attention(result)
      end
      return
    end

    if !options["force"]
      result = start_needs_force_result(plan, probe)
      if options["json"]
        puts JSON.pretty_generate(result)
      else
        print_start_needs_force(result)
      end
      exit 1
    end

    if probe && probe["decision"] == "self_wake"
      result = plan.merge(
        "action" => "self_wake_dry_run",
        "reuse_probe" => probe,
        "self_wake" => self_wake_plan(plan, probe)
      ).merge(start_force_metadata(plan))
      if options["dry_run"]
        if options["json"]
          puts JSON.pretty_generate(result)
        else
          print_start_self_wake_dry_run(result)
        end
        return
      end

      locked = try_with_start_instance_lock(plan["instance"]) do
        run_herdr_self_wake(plan, probe, json: options["json"])
      end
      unless locked
        result = start_in_progress_result(plan)
        if options["json"]
          puts JSON.pretty_generate(result)
        else
          print_start_needs_attention(result)
        end
        exit 1
      end
      return
    elsif probe && probe["decision"] == "wake"
      result = plan.merge(
        "action" => "wake_dry_run",
        "reuse_probe" => probe,
        "wake_adapter" => herdr_wake_adapter(plan, probe)
      ).merge(start_force_metadata(plan))
      if options["dry_run"]
        if options["json"]
          puts JSON.pretty_generate(result)
        else
          print_start_wake_dry_run(result)
        end
        return
      end

      locked = try_with_start_instance_lock(plan["instance"]) do
        run_herdr_wake(plan, probe, json: options["json"])
      end
      unless locked
        result = start_in_progress_result(plan)
        if options["json"]
          puts JSON.pretty_generate(result)
        else
          print_start_needs_attention(result)
        end
        exit 1
      end
      return
    end
  end

  if start_create_blocked?(plan, options)
    result = plan.merge(
      "action" => "blocked",
      "reason" => "start could not create or wake a Herdr agent automatically"
    )
    if options["json"]
      puts JSON.pretty_generate(result)
    else
      print_start_blocked(result)
    end
    exit 1
  end

  if options["dry_run"]
    dry_run_result = plan.merge("action" => "dry_run")
    dry_run_result = dry_run_result.merge(start_force_metadata(plan)) if options["force"]
    if options["json"]
      puts JSON.pretty_generate(dry_run_result)
    else
      print_start_human_plan(dry_run_result)
    end
    return
  end

  if options["force"]
    locked = try_with_start_instance_lock(plan["instance"]) do
      run_herdr_start(plan, json: options["json"])
    end
    unless locked
      result = start_in_progress_result(plan)
      if options["json"]
        puts JSON.pretty_generate(result)
      else
        print_start_needs_attention(result)
      end
      exit 1
    end
  else
    run_herdr_start(plan, json: options["json"])
  end
end

def parse_dispatch_args(args)
  options = {
    "dry_run" => false,
    "manual_payload" => false,
    "json" => false
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--to"
      options["to"] = option_value(args, "--to")
    when /\A--to=(.+)\z/
      options["to"] = Regexp.last_match(1)
    when "--transport"
      option_value(args, "--transport")
      usage_error("dispatch --transport was removed. Direct delivery uses the target instance's live Herdr binding. Use --dry-run or --manual-payload for manual delivery artifacts.")
    when /\A--transport=(.+)\z/
      usage_error("dispatch --transport was removed. Direct delivery uses the target instance's live Herdr binding. Use --dry-run or --manual-payload for manual delivery artifacts.")
    when "--pane"
      options["pane"] = option_value(args, "--pane")
    when /\A--pane=(.+)\z/
      options["pane"] = Regexp.last_match(1)
    when "--reply-to"
      options["reply_to"] = option_value(args, "--reply-to")
    when /\A--reply-to=(.+)\z/
      options["reply_to"] = Regexp.last_match(1)
    when "--dry-run"
      options["dry_run"] = true
    when "--manual-payload"
      options["manual_payload"] = true
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown dispatch option: #{arg}")
    end
  end

  usage_error("Missing required option: --task") if options["task"].nil? || options["task"].empty?
  usage_error("Missing required option: --to") if options["to"].nil? || options["to"].empty?
  usage_error("dispatch currently requires --json") unless options["json"]

  options
end

def load_dispatch_task(path)
  expanded = File.expand_path(path)
  task = load_yaml(expanded)
  usage_error("Task file must contain a mapping.") unless task.is_a?(Hash)
  usage_error("Task schema_version must be orbit-task-v1.") unless task["schema_version"] == "orbit-task-v1"

  [expanded, task]
rescue RuntimeError => e
  usage_error(e.message)
end

def dispatch_task_label(task_path)
  File.basename(task_path, File.extname(task_path)).gsub(/[^A-Za-z0-9_.-]/, "-")
end

def dispatch_reply_to(explicit_reply_to = nil)
  explicit = explicit_reply_to.to_s.strip
  return [explicit, "explicit_option"] unless explicit.empty?

  env_pane = ENV["HERDR_PANE_ID"].to_s.strip
  return [env_pane, "HERDR_PANE_ID"] unless env_pane.empty?

  lead_binding = lead_herdr_binding
  lead_pane = lead_binding["pane"].to_s.strip
  return [lead_pane, "lead_binding"] unless lead_pane.empty?

  ["manual", "manual_fallback"]
end

def dispatch_availability(agent_status)
  case agent_status.to_s
  when "idle"
    ["available", nil]
  when "done"
    ["available_needs_seen", "target_done_needs_inspection"]
  when "working"
    ["busy", "target_busy"]
  when "blocked"
    ["needs_user_or_owner_attention", "target_blocked"]
  else
    ["unknown", "target_state_unknown"]
  end
end

def dispatch_message(packet)
  reply_to = packet["reply_to"]
  sender_pane = reply_to == "manual" ? "unknown" : reply_to
  header = "[herdr-msg from:orbit pane:#{sender_pane} reply-to:#{reply_to} at:current kind:request task:#{packet["task_id"]}]"
  [
    header,
    "请接收 Orbit task。",
    "- task: #{packet["task"]}",
    "- operation_mode: #{packet.dig("execution_contract", "operation_mode")}",
    "- implementation_authority: #{packet.dig("execution_contract", "implementation_authority")}",
    "- assigned_instance: #{packet.dig("execution_contract", "assigned_instance")}",
    "- instance: #{packet["to_instance"]}",
    "- resolved_role: #{packet["resolved_role"]}",
    "",
    "开始前请运行：",
    "orbit whoami --json",
    "orbit rules resolve --task #{packet["task"]} --instance #{packet["to_instance"]} --json",
    "orbit rules print-context --task #{packet["task"]} --instance #{packet["to_instance"]} --json",
    "然后读取 context_preflight.required_files 中的每个 required 文件，再开始角色工作。",
    "",
    "完成后请把结果写入约定 evidence/report，并用同一个 task id 回复 DONE、BLOCKED 或 CHANGES_REQUESTED。"
  ].join("\n")
end

def dispatch_packet(options)
  task_path, task = load_dispatch_task(options["task"])
  instance_key, instance_alias, instance, role_ref, role_def = load_instance_for_launch(options["to"])
  resolved_role = role_def["role"] || role_ref
  instance_status = instance_status_entry(instance_key, instance, role_ref, role_def)
  execution_contract = task_execution_contract(task)
  target_allowed = task_allows_instance_role?(task, instance_key, resolved_role)
  unless target_allowed
    usage_error("dispatch target mismatch: instance #{instance_key.inspect} role #{resolved_role.inspect} is not task assigned_instance, owner_instance, or gate role.")
  end

  reply_to, reply_to_source = dispatch_reply_to(options["reply_to"])
  explicit_override = !options["pane"].to_s.empty?
  live_probe = nil
  runtime_resolution = nil
  availability = nil
  availability_reason = nil
  override_risks = []
  if explicit_override
    runtime_resolution = {
      "schema_version" => "orbit-runtime-resolution-v1",
      "instance" => instance_key,
      "identity_verification" => "override",
      "herdr_liveness" => "unknown",
      "availability" => "unknown",
      "binding_resolution" => "manual_override",
      "canonical_pane" => options["pane"],
      "dispatch_ready" => false,
      "reason" => "explicit_pane_override_not_live_verified"
    }
    override_risks = [
      "explicit_pane_override_not_herdr_verified",
      "do_not_use_as_evidence_runtime_identity",
      "target_agent_identity_not_confirmed"
    ]
  end
  unless explicit_override || options["manual_payload"]
    runtime_resolution = runtime_resolve_instance(instance_key)
    unless runtime_resolution["identity_verification"] == "verified" && runtime_resolution["herdr_liveness"] == "alive"
      usage_error("dispatch target #{instance_key.inspect} does not have a verified live Orbit runtime session; run `orbit start #{instance_key}` and wait for `orbit runtime register --json`, or use --manual-payload.")
    end
    availability = runtime_resolution["availability"]
    availability_reason = runtime_resolution["availability_reason"] || runtime_resolution["liveness_reason"]
    unless availability == "available"
      usage_error("dispatch target #{instance_key.inspect} is not available: #{availability_reason || availability}. Inspect the Herdr pane before sending new work.")
    end
    unless runtime_resolution["dispatch_ready"]
      usage_error("dispatch target #{instance_key.inspect} is not dispatch-ready: canonical pane mismatch or runtime policy blocked delivery.")
    end
    options["pane"] = runtime_resolution["canonical_pane"]
  end

  task_id = dispatch_task_label(task_path)
  live_binding_confirmed = runtime_resolution && runtime_resolution["dispatch_ready"] ? true : false
  manual_artifact = options["manual_payload"] == true
  delivery_precondition_met = target_allowed && (manual_artifact || explicit_override || live_binding_confirmed)
  packet = {
    "schema_version" => "orbit-dispatch-v1",
    "project" => task["project"] || File.basename(Dir.pwd),
    "task" => task_path,
    "task_id" => task_id,
    "task_type" => task["task_type"],
    "execution_contract" => execution_contract,
    "to_instance" => instance_key,
    "requested_instance" => options["to"],
    "instance_alias" => instance_alias,
    "role_ref" => role_ref,
    "resolved_role" => resolved_role,
    "delivery" => {
      "mode" => options["manual_payload"] ? "manual_artifact" : "herdr_direct",
      "runtime_adapter" => options["manual_payload"] ? "none" : "herdr",
      "explicit_override" => explicit_override
    },
    "target_instance_status" => instance_status,
    "target_liveness_probe" => live_probe,
    "target_runtime_resolution" => runtime_resolution&.reject { |key, _| %w[runtime_instance runtime_session].include?(key) },
    "target_availability" => availability,
    "context_preflight" => context_preflight_for(instance_key, task_path: task_path),
    "reply_to" => reply_to,
    "reply_to_source" => reply_to_source,
    "dry_run" => options["dry_run"],
    "message" => nil,
    "checks" => {
      "target_allowed_by_execution_contract" => target_allowed,
      "delivery_precondition_met" => delivery_precondition_met,
      "live_binding_confirmed" => live_binding_confirmed,
      "live_confirmed_for_delivery" => live_binding_confirmed,
      "explicit_override" => explicit_override,
      "manual_artifact" => manual_artifact
    },
    "risk" => override_risks
  }.compact

  packet["message"] = dispatch_message(packet)
  unless options["manual_payload"]
    usage_error("dispatch requires a Herdr pane from live binding or explicit --pane override.") if options["pane"].to_s.empty?
    packet["adapter"] = {
      "schema_version" => "orbit-herdr-dispatch-v1",
      "adapter" => "herdr",
      "pane" => options["pane"],
      "commands" => [
        ["herdr", "pane", "run", options["pane"], packet["message"]]
      ]
    }
  end

  packet
end

def run_herdr_dispatch(packet)
  herdr_path = command_path("herdr")
  usage_error("herdr command not found. Direct dispatch requires Herdr. Use --manual-payload for manual delivery artifacts.") unless herdr_path

  adapter = packet["adapter"]
  submit_delay_seconds = adapter.fetch("submit_delay_seconds", 0).to_f
  results = adapter["commands"].each_with_index.map do |command, index|
    argv = [herdr_path, *command[1..]]
    stdout, stderr, status = Open3.capture3(*argv)
    entry = {
      "command" => command,
      "exit_status" => status.exitstatus,
      "success" => status.success?,
      "stdout" => stdout,
      "stderr" => stderr
    }
    sleep(submit_delay_seconds) if status.success? && index < adapter["commands"].length - 1 && submit_delay_seconds.positive?
    entry
  end
  success = results.all? { |result| result["success"] }
  result = packet.merge(
    "action" => success ? "sent" : "failed",
    "adapter_result" => {
      "success" => success,
      "commands" => results
    }
  )
  unless success
    result["fallback"] = {
      "delivery" => "manual_artifact",
      "action" => "manual_delivery_required",
      "reason" => "Herdr dispatch failed before Orbit could confirm delivery.",
      "message" => packet["message"]
    }
  end

  puts JSON.pretty_generate(result)
  unless success
    failed = results.find { |entry| !entry["success"] }
    exit(failed && failed["exit_status"] ? failed["exit_status"] : 1)
  end
end

def dispatch(args)
  options = parse_dispatch_args(args)
  packet = dispatch_packet(options)

  if options["dry_run"] || options["manual_payload"]
    action = options["dry_run"] ? "dry_run" : "manual_delivery_required"
    puts JSON.pretty_generate(packet.merge("action" => action))
    return
  end

  run_herdr_dispatch(packet)
end

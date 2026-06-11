# frozen_string_literal: true

def parse_new_task_args(args)
  options = {
    "project" => File.basename(Dir.pwd)
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--target-role"
      options["target_role"] = option_value(args, "--target-role")
    when /\A--target-role=(.+)\z/
      options["target_role"] = Regexp.last_match(1)
    when "--task-type"
      options["task_type"] = option_value(args, "--task-type")
    when /\A--task-type=(.+)\z/
      options["task_type"] = Regexp.last_match(1)
    when "--output"
      options["output"] = option_value(args, "--output")
    when /\A--output=(.+)\z/
      options["output"] = Regexp.last_match(1)
    when "--project"
      options["project"] = option_value(args, "--project")
    when /\A--project=(.+)\z/
      options["project"] = Regexp.last_match(1)
    else
      usage_error("Unknown new-task option: #{arg}")
    end
  end

  %w[target_role task_type output].each do |name|
    usage_error("Missing required option: --#{name.tr("_", "-")}") if options[name].nil? || options[name].empty?
  end

  options
end

def default_gates_for_new_task(target_role, task_type)
  target = target_role.to_s
  type = task_type.to_s
  return [] if %w[reviewer tester].include?(target)
  return [] if type.include?("review") || type.include?("test")
  return [] unless %w[lead coder].include?(target) || type.include?("implementation") || type.include?("coding")

  [
    {
      "kind" => "review",
      "roles" => ["reviewer"],
      "required" => true,
      "pass_condition" => "latest review evidence status is pass and no high/medium findings remain"
    },
    {
      "kind" => "test",
      "roles" => ["tester"],
      "required" => true,
      "pass_condition" => "latest test evidence status is pass for required real behavior coverage"
    }
  ]
end

def new_task(args)
  options = parse_new_task_args(args)
  template_path = File.join(TEMPLATE_ROOT, "task.yaml")
  task = load_yaml(template_path)

  unless task.is_a?(Hash)
    warn "Task template must contain a mapping: #{template_path}"
    exit 66
  end

  output_path = File.expand_path(options["output"])
  if File.exist?(output_path)
    warn "Task file already exists: #{output_path}"
    warn "Choose a new --output path; new-task does not overwrite existing files."
    exit 73
  end

  task["project"] = options["project"]
  task["target_role"] = options["target_role"]
  task["task_type"] = options["task_type"]
  task["gates"] = default_gates_for_new_task(options["target_role"], options["task_type"])
  task_rule_packs = rule_packs_for_context(options["target_role"], options["task_type"])
  task["rule_packs"] = task_rule_packs unless task_rule_packs.empty?

  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, YAML.dump(task))

  puts "Created Orbit task:"
  puts "- #{output_path}"
  puts
  puts "Next:"
  puts "- orbit validate --task #{output_path}"
end

def parse_start_args(args)
  instance = args.shift
  usage_error("Missing start instance.") if instance.nil? || instance.start_with?("--")

  options = {
    "instance" => instance,
    "transport" => "local",
    "cwd" => Dir.pwd,
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
    "env" => instance_launch_env(instance_key, instance, role_def, role_ref),
    "dry_run" => options["dry_run"]
  }.compact
end

def herdr_start_argv(plan, executable = "herdr")
  [
    executable,
    "agent",
    "start",
    plan["instance"],
    "--cwd",
    plan["cwd"],
    "--split",
    "right",
    "--no-focus",
    "--",
    *plan["argv"]
  ]
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

def run_herdr_start(plan, json:)
  herdr_path = command_path("herdr")
  usage_error("herdr command not found; run `orbit tools doctor --json` or use --transport local.") unless herdr_path

  argv = herdr_start_argv(plan, herdr_path)
  exec_env = ENV.to_hash.merge(plan["env"])
  stdout, stderr, status = Open3.capture3(exec_env, *argv, chdir: plan["cwd"])
  adapter = attach_start_adapter_plan(plan)["adapter"]
  pane_id = status.success? ? herdr_start_pane_id(stdout) : nil
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
  end

  success = status.success? && (ready_wait.nil? || ready_wait["success"])
  result = attach_start_adapter_plan(plan).merge(
    "action" => "started",
    "adapter_result" => {
      "exit_status" => status.exitstatus,
      "success" => success,
      "stdout" => stdout,
      "stderr" => stderr,
      "pane_id" => pane_id,
      "ready_wait" => ready_wait
    }.compact
  )

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

def start(args)
  options = parse_start_args(args)
  plan = attach_start_adapter_plan(start_plan(options))

  if options["dry_run"]
    if options["json"]
      puts JSON.pretty_generate(plan.merge("action" => "dry_run"))
    else
      print_start_human_plan(plan.merge("action" => "dry_run"))
    end
    return
  end

  if plan["transport"] == "herdr"
    run_herdr_start(plan, json: options["json"])
    return
  end

  exec_env = ENV.to_hash.merge(plan["env"])
  argv = plan["argv"]
  Dir.chdir(plan["cwd"]) do
    exec(exec_env, [argv.first, argv.first], *argv.drop(1))
  end
end

def parse_dispatch_args(args)
  options = {
    "transport" => "generic",
    "dry_run" => false,
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
      options["transport"] = option_value(args, "--transport")
    when /\A--transport=(.+)\z/
      options["transport"] = Regexp.last_match(1)
    when "--pane"
      options["pane"] = option_value(args, "--pane")
    when /\A--pane=(.+)\z/
      options["pane"] = Regexp.last_match(1)
    when "--dry-run"
      options["dry_run"] = true
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown dispatch option: #{arg}")
    end
  end

  usage_error("Missing required option: --task") if options["task"].nil? || options["task"].empty?
  usage_error("Missing required option: --to") if options["to"].nil? || options["to"].empty?
  usage_error("dispatch currently requires --json") unless options["json"]
  usage_error("dispatch --transport must be generic or herdr") unless %w[generic herdr].include?(options["transport"])
  if options["transport"] == "herdr" && (options["pane"].nil? || options["pane"].empty?)
    usage_error("dispatch --transport herdr requires --pane because pane ids are live transport handles.")
  end

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

def dispatch_message(packet)
  reply_to = ENV["HERDR_PANE_ID"]
  header = "[herdr-msg from:orbit pane:#{reply_to || "unknown"} reply-to:#{reply_to || "manual"} at:current kind:request task:#{packet["task_id"]}]"
  [
    header,
    "请接收 Orbit task。",
    "- task: #{packet["task"]}",
    "- target_role: #{packet["task_target_role"]}",
    "- instance: #{packet["to_instance"]}",
    "- resolved_role: #{packet["resolved_role"]}",
    "",
    "开始前请运行：",
    "orbit whoami --task #{packet["task"]} --json",
    "orbit rules resolve --task #{packet["task"]} --instance #{packet["to_instance"]} --json",
    "orbit rules print-context --task #{packet["task"]} --instance #{packet["to_instance"]} --json",
    "",
    "完成后请把结果写入约定 evidence/report，并用同一个 task id 回复 DONE、BLOCKED 或 CHANGES_REQUESTED。"
  ].join("\n")
end

def dispatch_packet(options)
  task_path, task = load_dispatch_task(options["task"])
  instance_key, instance_alias, instance, role_ref, role_def = load_instance_for_launch(options["to"])
  resolved_role = role_def["role"] || role_ref
  task_id = dispatch_task_label(task_path)
  packet = {
    "schema_version" => "orbit-dispatch-v1",
    "project" => task["project"] || File.basename(Dir.pwd),
    "task" => task_path,
    "task_id" => task_id,
    "task_type" => task["task_type"],
    "task_target_role" => task["target_role"],
    "to_instance" => instance_key,
    "requested_instance" => options["to"],
    "instance_alias" => instance_alias,
    "role_ref" => role_ref,
    "resolved_role" => resolved_role,
    "transport" => options["transport"],
    "dry_run" => options["dry_run"],
    "message" => nil,
    "checks" => {
      "target_role_matches" => task_gate_role?(task, resolved_role) || task["target_role"].nil? || task["target_role"] == resolved_role,
      "pane_required_for_herdr" => options["transport"] == "herdr"
    }
  }.compact

  packet["message"] = dispatch_message(packet)
  if options["transport"] == "herdr"
    packet["adapter"] = {
      "schema_version" => "orbit-herdr-dispatch-v1",
      "transport" => "herdr",
      "pane" => options["pane"],
      "submit_delay_seconds" => 0.35,
      "commands" => [
        ["herdr", "pane", "send-text", options["pane"], packet["message"]],
        ["herdr", "pane", "send-keys", options["pane"], "Enter"]
      ]
    }
  end

  packet
end

def run_herdr_dispatch(packet)
  herdr_path = command_path("herdr")
  usage_error("herdr command not found; run `orbit tools doctor --json` or use --transport generic.") unless herdr_path

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
    "action" => "sent",
    "adapter_result" => {
      "success" => success,
      "commands" => results
    }
  )

  puts JSON.pretty_generate(result)
  unless success
    failed = results.find { |entry| !entry["success"] }
    exit(failed && failed["exit_status"] ? failed["exit_status"] : 1)
  end
end

def dispatch(args)
  options = parse_dispatch_args(args)
  packet = dispatch_packet(options)

  if options["dry_run"] || options["transport"] == "generic"
    action = options["dry_run"] ? "dry_run" : "manual_delivery_required"
    puts JSON.pretty_generate(packet.merge("action" => action))
    return
  end

  run_herdr_dispatch(packet)
end


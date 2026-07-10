# frozen_string_literal: true

def parse_task_workflow_args(args)
  subcommand = args.shift
  usage_error("task requires draft or start subcommand.") unless %w[draft start].include?(subcommand)
  if subcommand == "draft"
    json = args.delete("--json")
    verbose = args.delete("--verbose")
    return { "subcommand" => subcommand, "new_task_args" => args, "json" => !!json, "verbose" => !!verbose }
  end

  options = {
    "subcommand" => subcommand,
    "state" => File.join(".orbit", "loop-state.yaml"),
    "json" => false,
    "verbose" => false
  }
  until args.empty?
    arg = args.shift
    case arg
    when "--task" then options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/ then options["task"] = Regexp.last_match(1)
    when "--evidence" then options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/ then options["evidence"] = Regexp.last_match(1)
    when "--state" then options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/ then options["state"] = Regexp.last_match(1)
    when "--json" then options["json"] = true
    when "--verbose" then options["verbose"] = true
    else usage_error("Unknown task start option: #{arg}")
    end
  end
  usage_error("task start requires --task.") if options["task"].to_s.empty?
  options
end

def task_workflow_validation!(task_path)
  result = { "errors" => [], "warnings" => [] }
  validate_project_config(result)
  task = validate_task(result, task_path)
  validate_task_execution_readiness(result, task) if task
  unless result["errors"].empty?
    details = result["errors"].map { |error| "#{error["source"]}: #{error["message"]}" }
    usage_error("Task is not execution-ready:\n- #{details.join("\n- ")}")
  end
  task
end

def task_rules_resolution!(task_path, evidence_path, task)
  instance = task_assigned_instance(task)
  role = task_implementation_authority(task)
  options = {
    "subcommand" => "resolve",
    "task" => task_path,
    "evidence" => evidence_path,
    "instance" => instance,
    "json" => true
  }
  result = cached_rule_resolution(rule_resolution(options))
  usage_error("Task rules resolution failed: #{Array(result["conflicts"]).map { |entry| entry["message"] }.join('; ')}") unless result["valid"] == true

  relative = File.join(".orbit", "rules", "#{durable_task_slug(task_path)}-#{task["revision_id"]}-#{role}.json")
  output_path = File.expand_path(relative)
  write_file_atomically(output_path, "#{JSON.pretty_generate(result)}\n")
  evidence_attach_rule(
    {
      "file" => evidence_path,
      "task" => task_path,
      "rule_resolution" => output_path
    },
    quiet: true
  )
  [relative, result]
end

def task_draft(options)
  created = new_task(options["new_task_args"], quiet: true)
  task = created["task"]
  packet = {
    "schema_version" => "orbit-task-draft-v1",
    "task" => project_relative_persisted_path(created["path"], field: "task"),
    "task_id" => task["task_id"],
    "risk_level" => task.dig("task_risk", "level"),
    "required_gates" => required_evidence_kinds(task),
    "revision_id" => task["revision_id"],
    "next" => "Fill concrete outcomes, acceptance, evidence requirements, and traceability; then run orbit task start --task #{project_relative_persisted_path(created["path"], field: "task")}"
  }
  if options["json"] || options["verbose"]
    puts JSON.pretty_generate(packet)
  else
    gate_label = packet["required_gates"].empty? ? "none" : packet["required_gates"].join(",")
    puts "Drafted #{packet["task"]} (risk=#{packet["risk_level"]}, gates=#{gate_label})"
    puts "Next: #{packet["next"]}"
  end
end

def task_start_workflow(options)
  task_path = File.expand_path(options["task"])
  task = task_workflow_validation!(task_path)
  owner_role = resolve_owner_role(task_owner_role(task))
  evidence_path = File.expand_path(options["evidence"] || File.join(".orbit", "evidence", "#{durable_task_slug(task_path)}.json"))
  if File.file?(evidence_path)
    assert_evidence_manifest_bindable_to_task!(load_evidence_manifest(evidence_path), task, source: evidence_path)
  end

  task = freeze_task_revision!(task_path)
  task["__orbit_path"] = task_path
  evidence_created = false
  unless File.file?(evidence_path)
    manifest = bind_evidence_manifest_to_task!(default_evidence_manifest, task, source: evidence_path)
    write_evidence_manifest(evidence_path, manifest_with_recomputed_verdict(manifest))
    evidence_created = true
  else
    bind_evidence_file_to_task!(evidence_path, task)
  end
  rules_path, rules_result = task_rules_resolution!(task_path, evidence_path, task)
  state_start(
    {
      "task" => task_path,
      "state" => options["state"],
      "owner_role" => owner_role
    },
    quiet: true
  )

  packet = {
    "schema_version" => "orbit-task-start-v1",
    "task" => project_relative_persisted_path(task_path, field: "task"),
    "task_id" => task["task_id"],
    "revision_id" => task["revision_id"],
    "revision_number" => task["revision_number"],
    "state" => project_relative_persisted_path(options["state"], field: "state"),
    "evidence" => project_relative_persisted_path(evidence_path, field: "evidence"),
    "evidence_created" => evidence_created,
    "rules_resolution" => rules_path,
    "rules_cache" => rules_result["cache"],
    "phase" => design_task?(task) ? "drafting" : "working",
    "next" => "orbit status --task #{project_relative_persisted_path(task_path, field: "task")} --evidence #{project_relative_persisted_path(evidence_path, field: "evidence")}",
    "commands_required" => 1,
    "workflow_commands_from_init" => 3
  }
  if options["json"] || options["verbose"]
    puts JSON.pretty_generate(packet)
  else
    puts "Started #{packet["task"]} revision=#{packet["revision_id"]} phase=#{packet["phase"]}"
    puts "Evidence: #{packet["evidence"]} | Rules: #{packet["rules_resolution"]}"
    puts "Next: #{packet["next"]}"
  end
end

def task_workflow(args)
  options = parse_task_workflow_args(args)
  options["subcommand"] == "draft" ? task_draft(options) : task_start_workflow(options)
end

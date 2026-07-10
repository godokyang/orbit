# frozen_string_literal: true

def parse_status_args(args)
  options = {
    "state" => File.join(Dir.pwd, ".orbit", "loop-state.yaml"),
    "json" => false
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--state"
      options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/
      options["state"] = Regexp.last_match(1)
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--evidence"
      options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      options["evidence"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown status option: #{arg}")
    end
  end

  options
end

def status_existing_file(path)
  return nil if path.to_s.empty?

  expanded = File.expand_path(path)
  File.file?(expanded) ? expanded : nil
end

def status_evidence_candidates(task_path)
  return [] if task_path.to_s.empty?

  basename = File.basename(task_path, File.extname(task_path))
  root = File.join(Dir.pwd, ".orbit")
  [
    File.join(root, "evidence", "#{basename}.json"),
    File.join(root, "evidence", "#{basename}.yaml"),
    File.join(root, "evidence", "#{basename}-evidence.json"),
    File.join(root, "evidence", "#{basename}-evidence.yaml"),
    File.join(root, "evidence.json")
  ]
end

def resolve_status_evidence_path(options, state, task_path)
  explicit = status_existing_file(options["evidence"])
  return explicit if explicit

  state_ref = state.is_a?(Hash) ? state.dig("artifacts", "evidence_file") : nil
  from_state = status_existing_file(state_ref)
  return from_state if from_state

  status_evidence_candidates(task_path).find { |path| File.file?(path) }
end

def status_identity_summary
  identity = runtime_identity_snapshot
  unless identity["valid"]
    return {
      "role" => identity["resolved_role"],
      "instance" => identity["resolved_instance"] || identity["instance"],
      "verification" => "pending",
      "conflicts" => identity["conflicts"] || []
    }.compact
  end

  attribution = runtime_current_process_session_attribution(identity) || {}
  raw = attribution["verification"].to_s
  verification = if %w[herdr_verified verified].include?(raw)
                   "verified"
                 elsif raw == "manual_runtime"
                   "manual"
                 else
                   "pending"
                 end
  {
    "role" => identity["resolved_role"],
    "instance" => identity["resolved_instance"] || identity["instance"],
    "verification" => verification,
    "reason" => attribution["reason"]
  }.compact
rescue SystemExit
  { "verification" => "pending", "reason" => "identity_unavailable" }
end

def status_record_summary(record, current_task_sha256 = nil, task: nil, evidence_kind: nil)
  return { "status" => "missing" } unless record.is_a?(Hash)

  record_task_sha = record.dig("role_execution_context", "task_sha256").to_s
  current_revision = if task_revision_frozen?(task) && evidence_kind
                       evidence_record_revision_eligible?(record, task, evidence_kind, current_task_sha256)
                     else
                       current_task_sha256.to_s.empty? || record_task_sha.empty? || record_task_sha == current_task_sha256
                     end
  {
    "status" => current_revision ? record["status"] : "stale",
    "record_status" => record["status"],
    "summary" => record["summary"],
    "created_at" => record["created_at"],
    "runtime_identity" => record.dig("runtime_identity", "verification"),
    "role" => record.dig("role_execution_context", "resolved_role") || record.dig("identity", "resolved_role"),
    "instance" => record.dig("role_execution_context", "instance") || record.dig("identity", "resolved_instance"),
    "current_task_revision" => current_revision
  }.compact
end

def status_activity_summary(task, evidence, task_sha256)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  implementation = records.reverse.find { |record| record.is_a?(Hash) && record["kind"] == "implementation" }
  activity = { "implementation" => status_record_summary(implementation, task_sha256, task: task, evidence_kind: "implementation") }

  %w[review test].each do |kind|
    gate = gate_status(records, kind, task, task_sha256: task_sha256, evidence: evidence || {})
    summary = status_record_summary(gate["latest"], task_sha256, task: task, evidence_kind: kind)
    summary["status"] = gate["passed"] ? "pass" : summary["status"]
    summary["blocking_reason"] = gate["blocking_reason"] unless gate["passed"]
    activity[kind] = summary.compact
  end
  activity
end

def status_finding_severity(finding)
  return finding["severity"].to_s.downcase if finding.is_a?(Hash)
  return string_finding_severity(finding) if finding.is_a?(String)

  nil
end

def status_finding_open?(finding)
  return true unless finding.is_a?(Hash)

  !%w[closed resolved fixed accepted].include?(finding["status"].to_s.downcase)
end

def status_open_findings(activity, evidence)
  records = evidence.is_a?(Hash) && evidence["records"].is_a?(Array) ? evidence["records"] : []
  latest_records = %w[review test].map do |kind|
    summary_time = activity.dig(kind, "created_at")
    records.reverse.find { |record| record.is_a?(Hash) && record["kind"] == kind && record["created_at"] == summary_time }
  end.compact

  latest_records.flat_map { |record| Array(record["findings"]) }.map do |finding|
    severity = status_finding_severity(finding)
    next unless %w[high medium].include?(severity) && status_finding_open?(finding)

    if finding.is_a?(Hash)
      {
        "severity" => severity,
        "summary" => finding["summary"],
        "source" => finding["source"]
      }.compact
    else
      { "severity" => severity, "summary" => finding }
    end
  end.compact
end

def status_gate_roles(task, kind)
  gate = Array(task.is_a?(Hash) ? task["gates"] : nil).find do |entry|
    entry.is_a?(Hash) && entry["kind"].to_s == kind.to_s
  end
  declared_roles = Array(gate && gate["roles"]).select { |role| role.is_a?(String) && !role.empty? }
  return declared_roles.uniq unless declared_roles.empty?

  fallback = expected_gate_role(kind)
  fallback ? [fallback] : []
end

def status_gate_target(task, kind)
  roles, instances, = load_project_instance_config_for_cli
  gate_roles = status_gate_roles(task, kind)
  inferred = gate_roles.map { |role| infer_instance_from_role(instances, roles, role) }.compact
  candidates = instances.each_with_object([]) do |(instance_name, _instance), names|
    names << instance_name if gate_roles.include?(role_for_instance_config(instances, roles, instance_name))
  end.sort

  if candidates.length == 1 && inferred.include?(candidates.first)
    {
      "status" => "resolved",
      "roles" => gate_roles,
      "instance" => candidates.first,
      "candidates" => candidates
    }
  elsif candidates.empty?
    {
      "status" => "missing",
      "roles" => gate_roles,
      "candidates" => []
    }
  else
    {
      "status" => "ambiguous",
      "roles" => gate_roles,
      "candidates" => candidates
    }
  end
end

def status_gate_dispatch_action(task, task_path, gate_kind, reason)
  target = status_gate_target(task, gate_kind)
  if target["status"] == "resolved"
    return {
      "command" => "orbit dispatch --task #{task_path} --to #{target["instance"]} --manual-payload --json",
      "reason" => reason,
      "gate" => gate_kind,
      "roles" => target["roles"],
      "target_instance" => target["instance"]
    }
  end

  selection_reason = if target["status"] == "ambiguous"
                       "#{reason}; choose one configured instance for #{target["roles"].join("/")}: #{target["candidates"].join(", ")}"
                     else
                       "#{reason}; no configured instance resolves the gate roles #{target["roles"].join("/")}"
                     end
  {
    "command" => "orbit instances status --json",
    "reason" => selection_reason,
    "gate" => gate_kind,
    "roles" => target["roles"],
    "requires_instance_selection" => true,
    "candidate_instances" => target["candidates"]
  }
end

def status_next_action(state, task, evidence_path, activity, gate_summary, blockers)
  phase = state["phase"]
  task_path = state["current_task"]
  missing_gate = Array(gate_summary["not_ready"]).first

  return { "command" => "orbit new-task --task-type TYPE --output PATH", "reason" => "no current task" } if task.nil?
  if phase == "idle"
    return { "command" => "orbit state start --task #{task_path}", "reason" => "task has not started" }
  end
  if phase == "blocked"
    return { "command" => "orbit state show --json", "reason" => state["status"] }
  end
  if phase == "implemented_not_independently_accepted"
    gate = missing_gate && missing_gate["kind"]
    return status_gate_dispatch_action(
      task,
      task_path,
      gate,
      "implementation is ready, but independent #{gate || "review/test"} acceptance is missing"
    )
  end
  if activity.dig("implementation", "status") != "pass"
    return { "command" => "continue implementation", "reason" => "no current implementation pass evidence" }
  end
  if missing_gate
    return status_gate_dispatch_action(
      task,
      task_path,
      missing_gate["kind"],
      "required #{missing_gate["kind"]} gate is not ready"
    )
  end
  unless phase == "done"
    return {
      "command" => "orbit state transition --to done --evidence #{evidence_path || "PATH"}",
      "reason" => "required evidence and gates are ready"
    }
  end

  { "command" => "none", "reason" => blockers.empty? ? "task is done" : "inspect blockers" }
end

def build_status_packet(options)
  state_path = File.expand_path(options["state"])
  state = load_loop_state(state_path)
  task_path = status_existing_file(options["task"]) || status_existing_file(state["current_task"])
  task = task_path ? load_state_task(task_path) : nil
  evidence_path = resolve_status_evidence_path(options, state, task_path)
  evidence = evidence_path ? load_evidence_manifest(evidence_path) : { "records" => [], "verdict" => { "status" => "in_progress" } }
  task_sha256 = task_path ? sha256_file(task_path) : nil
  activity = task ? status_activity_summary(task, evidence, task_sha256) : {}
  gate_summary = task ? required_gate_summary(task, evidence, task_sha256: task_sha256) : { "ready" => false, "required" => [], "passed" => [], "not_ready" => [] }
  findings = status_open_findings(activity, evidence)
  blockers = []
  blockers << { "kind" => "state", "summary" => state["status"] } if state["phase"] == "blocked"
  Array(gate_summary["not_ready"]).each do |gate|
    blockers << {
      "kind" => "gate",
      "gate" => gate["kind"],
      "summary" => "#{gate["kind"]} gate: #{gate["blocking_reason"] || "not ready"}"
    }
  end
  findings.each { |finding| blockers << { "kind" => "finding", "summary" => finding["summary"], "severity" => finding["severity"] } }
  if state["phase"] == "implemented_not_independently_accepted"
    blockers << { "kind" => "independent_acceptance", "summary" => "Implementation is not independently accepted." }
  end

  completion = if state["phase"] == "done" && gate_summary["ready"] && findings.empty?
                 "done"
               elsif state["phase"] == "implemented_not_independently_accepted"
                 "implemented_not_independently_accepted"
               else
                 "in_progress"
               end
  next_action = status_next_action(state, task, evidence_path, activity, gate_summary, blockers)
  {
    "schema_version" => "orbit-status-v1",
    "project" => state["project"] || File.basename(Dir.pwd),
    "task" => task && {
      "path" => task_path,
      "task_type" => task["task_type"],
      "risk_level" => task.dig("task_risk", "level"),
      "change_surface" => task["change_surface"],
      "operation_mode" => task.dig("execution_contract", "operation_mode"),
      "owner_role" => task.dig("execution_contract", "owner_role"),
      "owner_instance" => task.dig("execution_contract", "owner_instance"),
      "assigned_instance" => task.dig("execution_contract", "assigned_instance")
    },
    "state" => {
      "path" => state_path,
      "phase" => state["phase"],
      "status" => state["status"]
    },
    "runtime" => status_identity_summary,
    "evidence" => { "path" => evidence_path, "verdict" => evidence.dig("verdict", "status") },
    "activity" => activity,
    "gate_summary" => gate_summary,
    "open_findings" => findings,
    "blockers" => blockers,
    "completion" => {
      "status" => completion,
      "independently_accepted" => completion == "done" && gate_summary["ready"]
    },
    "next" => next_action
  }.compact
end

def print_status_human(packet)
  task = packet["task"] || {}
  runtime = packet["runtime"] || {}
  activity = packet["activity"] || {}
  puts "Orbit status"
  puts "- task: #{task["path"] || "none"}"
  puts "- phase: #{packet.dig("state", "phase")} (#{packet.dig("completion", "status")})"
  puts "- risk/mode: #{task["risk_level"] || "n/a"} / #{task["operation_mode"] || "n/a"}"
  puts "- owner/assignee: #{task["owner_role"] || "unknown"}/#{task["owner_instance"] || "unknown"} → #{task["assigned_instance"] || "unknown"}"
  puts "- identity: #{runtime["role"] || "unknown"}/#{runtime["instance"] || "unknown"} (#{runtime["verification"]})"
  %w[implementation review test].each do |kind|
    summary = activity[kind] || { "status" => "missing" }
    puts "- #{kind}: #{summary["status"] || "missing"}#{summary["summary"] ? " — #{summary["summary"]}" : ""}"
  end
  puts "- open High/Medium findings: #{packet["open_findings"].length}"
  blocker = packet["blockers"].first
  puts "- blocker: #{blocker ? blocker["summary"] : "none"}"
  puts "- next: #{packet.dig("next", "command")}"
end

def status_command(args, next_only: false)
  options = parse_status_args(args)
  packet = build_status_packet(options)
  if options["json"]
    puts JSON.pretty_generate(next_only ? { "schema_version" => "orbit-next-v1", "next" => packet["next"], "status" => packet } : packet)
  elsif next_only
    puts packet.dig("next", "command")
    puts "Reason: #{packet.dig("next", "reason")}"
  else
    print_status_human(packet)
  end
end

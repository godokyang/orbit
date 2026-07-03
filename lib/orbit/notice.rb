# frozen_string_literal: true

COMPLETION_NOTICE_EVENTS_BY_KIND = {
  "implementation" => "implementation_complete",
  "review" => "review_complete",
  "test" => "test_complete"
}.freeze

def parse_notice_args(args)
  subcommand = args.shift
  usage_error("Missing notice subcommand.") unless subcommand
  options = { "subcommand" => subcommand, "json" => false }
  until args.empty?
    arg = args.shift
    case arg
    when "--task" then options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/ then options["task"] = Regexp.last_match(1)
    when "--evidence" then options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/ then options["evidence"] = Regexp.last_match(1)
    when "--event" then options["event"] = option_value(args, "--event")
    when /\A--event=(.+)\z/ then options["event"] = Regexp.last_match(1)
    when "--role" then options["role"] = option_value(args, "--role")
    when /\A--role=(.+)\z/ then options["role"] = Regexp.last_match(1)
    when "--to-instance" then options["to_instance"] = option_value(args, "--to-instance")
    when /\A--to-instance=(.+)\z/ then options["to_instance"] = Regexp.last_match(1)
    when "--id" then options["id"] = option_value(args, "--id")
    when /\A--id=(.+)\z/ then options["id"] = Regexp.last_match(1)
    when "--json" then options["json"] = true
    else usage_error("Unknown notice #{subcommand} option: #{arg}")
    end
  end
  usage_error("notice #{subcommand} requires --json") unless options["json"]
  options
end

def notice_dir(role)
  File.join(Dir.pwd, ".orbit", "runtime", "notices", role.to_s)
end

def notice_event_source_allowed?(event, task, identity, evidence = nil)
  role = identity["resolved_role"]
  instance = identity["resolved_instance"] || identity["instance"]
  case event
  when "implementation_complete"
    (role == task_implementation_authority(task) && instance == task_assigned_instance(task)) ||
      !!valid_implementation_override_for_identity(task, evidence, role, instance)
  when "review_complete"
    role == "reviewer"
  when "test_complete"
    role == "tester"
  when "handoff_ready", "blocked_needs_owner"
    role == task_owner_role(task) || role == task_implementation_authority(task) || task_gate_role?(task, role)
  else
    false
  end
end

def notice_add(options)
  usage_error("notice add requires --task") if options["task"].to_s.empty?
  usage_error("notice add requires --event") if options["event"].to_s.empty?
  task_path = File.expand_path(options["task"])
  task = load_task_for_evidence!(task_path)
  identity = evidence_runtime_identity!
  evidence = options["evidence"].to_s.empty? ? nil : load_evidence_manifest(File.expand_path(options["evidence"]))
  unless notice_event_source_allowed?(options["event"], task, identity, evidence)
    usage_error("notice #{options["event"]} is not allowed from #{identity["resolved_role"].inspect}/#{identity["resolved_instance"].inspect}.")
  end
  to_role = task_owner_role(task)
  to_instance = task_owner_instance(task)
  usage_error("--to-instance must match task owner_instance #{to_instance.inspect}.") if !options["to_instance"].to_s.empty? && options["to_instance"] != to_instance
  id = "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{options["event"]}-#{SecureRandom.hex(4)}"
  record = {
    "schema_version" => "orbit-notice-v1",
    "id" => id,
    "task" => task_path,
    "task_sha256" => sha256_file(task_path),
    "evidence" => options["evidence"] ? File.expand_path(options["evidence"]) : nil,
    "evidence_sha256" => options["evidence"] ? sha256_file(File.expand_path(options["evidence"])) : nil,
    "event" => options["event"],
    "status" => "open",
    "from_role" => identity["resolved_role"],
    "from_instance" => identity["resolved_instance"] || identity["instance"],
    "to_role" => to_role,
    "to_instance" => to_instance,
    "created_at" => Time.now.utc.iso8601
  }.compact
  FileUtils.mkdir_p(notice_dir(to_role))
  File.write(File.join(notice_dir(to_role), "#{id}.json"), JSON.pretty_generate(record))
  puts JSON.pretty_generate(record)
end

def notice_records(role)
  Dir.glob(File.join(notice_dir(role), "*.json")).each_with_object([]) do |path, records|
    records << JSON.parse(File.read(path)).merge("__path" => path)
  rescue JSON::ParserError
    records
  end
end

def completion_notice_policy_required?(task)
  policy = task.is_a?(Hash) ? task["completion_notice_policy"] : nil
  return true if policy == "required"
  return true if policy.is_a?(Hash) && policy["required"] == true

  false
end

def completion_notice_required_events(task, evidence)
  return [] unless task.is_a?(Hash) && evidence.is_a?(Hash)

  task_hash = task["__orbit_path"] ? sha256_file(task["__orbit_path"]) : nil
  Array(evidence["records"]).each_with_object([]) do |record, events|
    next unless record.is_a?(Hash) && record["status"] == "pass"
    next if record["role_execution_context"].is_a?(Hash) &&
            task_hash &&
            record["role_execution_context"]["task_sha256"].is_a?(String) &&
            record["role_execution_context"]["task_sha256"] != task_hash

    event = COMPLETION_NOTICE_EVENTS_BY_KIND[record["kind"]]
    events << event if event && !events.include?(event)
  end
end

def completion_notice_summary(task, evidence)
  owner_role = task_owner_role(task)
  task_hash = task.is_a?(Hash) && task["__orbit_path"] ? sha256_file(task["__orbit_path"]) : nil
  required_events = completion_notice_required_events(task, evidence)
  notices = notice_records(owner_role).select { |notice| notice["task_sha256"] == task_hash }
  present_events = notices.map { |notice| notice["event"] }.compact.uniq
  missing_events = required_events - present_events
  {
    "required" => completion_notice_policy_required?(task),
    "owner_role" => owner_role,
    "owner_instance" => task_owner_instance(task),
    "required_events" => required_events,
    "present_events" => present_events,
    "missing_events" => missing_events,
    "notices" => notices.map { |notice| notice.reject { |key, _| key == "__path" } }
  }
end

def notice_list(options)
  role = options["role"] || ENV["ORBIT_ROLE"] || "lead"
  records = notice_records(role)
  puts JSON.pretty_generate({ "schema_version" => "orbit-notice-list-v1", "role" => role, "notices" => records.map { |r| r.reject { |k, _| k == "__path" } } })
end

def notice_ack(options)
  usage_error("notice ack requires --role") if options["role"].to_s.empty?
  usage_error("notice ack requires --id") if options["id"].to_s.empty?
  record = notice_records(options["role"]).find { |r| r["id"] == options["id"] }
  usage_error("Unknown notice #{options["id"].inspect} for role #{options["role"].inspect}.") unless record
  identity = evidence_runtime_identity!
  ack_role = identity["resolved_role"]
  ack_instance = identity["resolved_instance"] || identity["instance"]
  unless ack_role == record["to_role"] && ack_instance == record["to_instance"]
    usage_error("notice ack requires recipient identity #{record["to_role"].inspect}/#{record["to_instance"].inspect}; current identity is #{ack_role.inspect}/#{ack_instance.inspect}.")
  end
  record["status"] = "acked"
  record["acked_at"] = Time.now.utc.iso8601
  record["acked_by_role"] = ack_role
  record["acked_by_instance"] = ack_instance
  File.write(record["__path"], JSON.pretty_generate(record.reject { |k, _| k == "__path" }))
  puts JSON.pretty_generate(record.reject { |k, _| k == "__path" })
end

def notice(args)
  options = parse_notice_args(args)
  case options["subcommand"]
  when "add" then notice_add(options)
  when "list" then notice_list(options)
  when "ack" then notice_ack(options)
  else usage_error("Unknown notice subcommand: #{options["subcommand"]}")
  end
end

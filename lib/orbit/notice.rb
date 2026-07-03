# frozen_string_literal: true

COMPLETION_NOTICE_EVENTS_BY_KIND = {
  "implementation" => "implementation_complete",
  "review" => "review_complete",
  "test" => "test_complete"
}.freeze

def completion_notice_event?(event)
  COMPLETION_NOTICE_EVENTS_BY_KIND.value?(event)
end

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

def canonical_json_data(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) { |key, memo| memo[key] = canonical_json_data(value[key]) }
  when Array
    value.map { |entry| canonical_json_data(entry) }
  else
    value
  end
end

def stable_record_sha256(record)
  Digest::SHA256.hexdigest(JSON.generate(canonical_json_data(record)))
end

def notice_identity_matches_item?(item, identity)
  role = identity["resolved_role"]
  instance = identity["resolved_instance"] || identity["instance"]
  return false if item["resolved_role"].is_a?(String) && !item["resolved_role"].empty? && item["resolved_role"] != role
  return false if item["resolved_instance"].is_a?(String) && !item["resolved_instance"].empty? && item["resolved_instance"] != instance

  true
end

def notice_item_for_add(event, task, evidence, identity)
  completion_notice_required_items(task, evidence).find do |item|
    item["event"] == event && notice_identity_matches_item?(item, identity)
  end
end

def notice_add(options)
  usage_error("notice add requires --task") if options["task"].to_s.empty?
  usage_error("notice add requires --event") if options["event"].to_s.empty?
  if completion_notice_event?(options["event"]) && options["evidence"].to_s.empty?
    usage_error("notice #{options["event"]} requires --evidence so Orbit can bind the notice to a stable evidence record.")
  end
  task_path = File.expand_path(options["task"])
  task = load_task_for_evidence!(task_path)
  identity = evidence_runtime_identity!
  evidence = options["evidence"].to_s.empty? ? nil : load_evidence_manifest(File.expand_path(options["evidence"]))
  unless notice_event_source_allowed?(options["event"], task, identity, evidence)
    usage_error("notice #{options["event"]} is not allowed from #{identity["resolved_role"].inspect}/#{identity["resolved_instance"].inspect}.")
  end
  evidence_item = completion_notice_event?(options["event"]) ? notice_item_for_add(options["event"], task, evidence, identity) : nil
  if completion_notice_event?(options["event"]) && evidence_item.nil?
    usage_error("notice #{options["event"]} requires a matching passing evidence record from the current identity.")
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
    "evidence_ref" => options["evidence"] ? File.expand_path(options["evidence"]) : nil,
    "evidence_record" => evidence_item && {
      "kind" => evidence_item["kind"],
      "record_index" => evidence_item["record_index"],
      "record_created_at" => evidence_item["record_created_at"],
      "source_message_id" => evidence_item["source_message_id"],
      "record_sha256" => evidence_item["record_sha256"]
    },
    "event" => options["event"],
    "status" => "open",
    "from_role" => identity["resolved_role"],
    "from_instance" => identity["resolved_instance"] || identity["instance"],
    "to_role" => to_role,
    "to_instance" => to_instance,
    "created_at" => Time.now.utc.iso8601
  }.compact
  path = File.join(notice_dir(to_role), "#{id}.json")
  with_orbit_file_lock(path) do |expanded|
    atomic_replace_file(expanded, "#{JSON.pretty_generate(record)}\n")
  end
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

def completion_notice_policy_ack_required?(task)
  policy = task.is_a?(Hash) ? task["completion_notice_policy"] : nil
  policy.is_a?(Hash) && policy["ack_required"] == true
end

def completion_notice_required_events(task, evidence)
  completion_notice_required_items(task, evidence).map { |item| item["event"] }
end

def parse_notice_time(value)
  return nil if value.to_s.empty?

  Time.iso8601(value.to_s)
rescue ArgumentError
  nil
end

def evidence_record_context(record)
  record["role_execution_context"].is_a?(Hash) ? record["role_execution_context"] : {}
end

def evidence_record_matches_task?(record, task_hash)
  return true unless task_hash

  ctx = evidence_record_context(record)
  return true unless ctx["task_sha256"].is_a?(String)

  ctx["task_sha256"] == task_hash
end

def completion_notice_required_items(task, evidence)
  return [] unless task.is_a?(Hash) && evidence.is_a?(Hash)

  task_hash = task["__orbit_path"] ? sha256_file(task["__orbit_path"]) : nil
  latest_by_event = {}
  Array(evidence["records"]).each_with_index do |record, index|
    next unless record.is_a?(Hash) && record["status"] == "pass"
    next unless evidence_record_matches_task?(record, task_hash)

    event = COMPLETION_NOTICE_EVENTS_BY_KIND[record["kind"]]
    next unless event

    ctx = evidence_record_context(record)
    item = {
      "event" => event,
      "kind" => record["kind"],
      "record_index" => index,
      "record_created_at" => record["created_at"],
      "record_created_time" => parse_notice_time(record["created_at"]),
      "source_message_id" => record["source_message_id"],
      "record_sha256" => stable_record_sha256(record),
      "resolved_role" => ctx["resolved_role"],
      "resolved_instance" => ctx["resolved_instance"] || ctx["instance"]
    }
    existing = latest_by_event[event]
    item_sort_key = [item["record_created_time"] || Time.at(0), index]
    existing_sort_key = existing ? [existing["record_created_time"] || Time.at(0), existing["record_index"]] : nil
    if existing.nil? || ((item_sort_key <=> existing_sort_key) || 0).positive?
      latest_by_event[event] = item
    end
  end
  latest_by_event.values.sort_by { |item| item["record_index"] }.map do |item|
    item.reject { |key, _| key == "record_created_time" }
  end
end

def notice_source_valid_for_completion?(notice, item, task, evidence)
  case item["event"]
  when "implementation_complete"
    notice["from_role"] == task_implementation_authority(task) &&
      (notice["from_instance"] == task_assigned_instance(task) ||
        !!valid_implementation_override_for_identity(task, evidence, notice["from_role"], notice["from_instance"]))
  when "review_complete"
    notice["from_role"] == "reviewer"
  when "test_complete"
    notice["from_role"] == "tester"
  else
    false
  end
end

def completion_notice_validation_errors(notice, item, task, evidence, task_hash, evidence_path)
  errors = []
  errors << "schema_version_mismatch" unless notice["schema_version"] == "orbit-notice-v1"
  errors << "status_not_open_or_acked" unless %w[open acked].include?(notice["status"])
  errors << "task_sha256_mismatch" unless task_hash && notice["task_sha256"] == task_hash
  if evidence_path
    expected_evidence_ref = File.expand_path(evidence_path)
    actual_evidence_ref = notice["evidence_ref"].to_s.empty? ? nil : File.expand_path(notice["evidence_ref"])
    errors << "evidence_ref_mismatch" unless actual_evidence_ref == expected_evidence_ref
  end
  record_ref = notice["evidence_record"]
  unless record_ref.is_a?(Hash)
    errors << "evidence_record_missing"
  else
    errors << "evidence_record_kind_mismatch" unless record_ref["kind"] == item["kind"]
    errors << "evidence_record_sha256_mismatch" unless record_ref["record_sha256"] == item["record_sha256"]
    errors << "evidence_record_created_at_mismatch" unless record_ref["record_created_at"] == item["record_created_at"]
  end
  errors << "event_mismatch" unless notice["event"] == item["event"]
  errors << "recipient_role_mismatch" unless notice["to_role"] == task_owner_role(task)
  errors << "recipient_instance_mismatch" unless notice["to_instance"] == task_owner_instance(task)
  errors << "source_not_allowed" unless notice_source_valid_for_completion?(notice, item, task, evidence)

  notice_time = parse_notice_time(notice["created_at"])
  required_time = parse_notice_time(item["record_created_at"])
  if notice_time.nil?
    errors << "created_at_invalid"
  elsif required_time && notice_time < required_time
    errors << "created_at_before_required_record"
  end

  errors
end

def completion_notice_valid_for_item?(notice, item, task, evidence, task_hash, evidence_path)
  completion_notice_validation_errors(notice, item, task, evidence, task_hash, evidence_path).empty?
end

def completion_notice_summary(task, evidence, evidence_path: nil)
  owner_role = task_owner_role(task)
  task_hash = task.is_a?(Hash) && task["__orbit_path"] ? sha256_file(task["__orbit_path"]) : nil
  required_items = completion_notice_required_items(task, evidence)
  required_events = required_items.map { |item| item["event"] }
  notices = notice_records(owner_role).select { |notice| notice["task_sha256"] == task_hash }
  valid_notices = []
  invalid_notices = []
  notices.each do |notice|
    matching_items = required_items.select { |item| item["event"] == notice["event"] }
    if matching_items.any? { |item| completion_notice_valid_for_item?(notice, item, task, evidence, task_hash, evidence_path) }
      valid_notices << notice
    else
      errors = matching_items.empty? ? ["event_not_required"] : matching_items.flat_map { |item| completion_notice_validation_errors(notice, item, task, evidence, task_hash, evidence_path) }.uniq
      invalid_notices << notice.merge("invalid_reasons" => errors)
    end
  end
  present_events = valid_notices.map { |notice| notice["event"] }.compact.uniq
  acked_events = valid_notices.select { |notice| notice["status"] == "acked" }.map { |notice| notice["event"] }.compact.uniq
  missing_events = required_events - present_events
  ack_required = completion_notice_policy_ack_required?(task)
  unacked_events = ack_required ? (present_events - acked_events) : []
  {
    "required" => completion_notice_policy_required?(task),
    "ack_required" => ack_required,
    "owner_role" => owner_role,
    "owner_instance" => task_owner_instance(task),
    "required_items" => required_items,
    "required_events" => required_events,
    "present_events" => present_events,
    "acked_events" => acked_events,
    "missing_events" => missing_events,
    "unacked_events" => unacked_events,
    "notices" => notices.map { |notice| notice.reject { |key, _| key == "__path" } },
    "valid_notices" => valid_notices.map { |notice| notice.reject { |key, _| key == "__path" } },
    "invalid_notices" => invalid_notices.map { |notice| notice.reject { |key, _| key == "__path" } }
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
  with_orbit_file_lock(record["__path"]) do |expanded|
    atomic_replace_file(expanded, "#{JSON.pretty_generate(record.reject { |k, _| k == "__path" })}\n")
  end
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

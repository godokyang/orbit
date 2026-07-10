# frozen_string_literal: true

REVISION_CHANGE_TYPES = %w[
  scope acceptance quality_outcome implementation review_contract test_contract
  release_contract risk rules runtime documentation
].freeze

TASK_ID_PATTERN = /\Aotask_[0-9a-f]{24}\z/

def generate_task_id
  "otask_#{SecureRandom.hex(12)}"
end

def task_id_valid?(value)
  value.is_a?(String) && value.match?(TASK_ID_PATTERN)
end

def ensure_task_id!(task)
  state_error("Task file must contain a mapping before assigning task_id.") unless task.is_a?(Hash)

  current = task["task_id"]
  if current.nil? || current.to_s.empty? || current == "draft"
    task["task_id"] = generate_task_id
  elsif !task_id_valid?(current)
    state_error("Task task_id must use otask_<24 lowercase hex>.")
  end
  task["task_id"]
end

REVISION_FIELD_CHANGE_TYPES = {
  "task_id" => "identity",
  "schema_version" => "runtime",
  "schema_semantics" => "runtime",
  "project" => "scope",
  "task_type" => "scope",
  "change_surface" => "risk",
  "risk_sinks" => "risk",
  "real_path_required" => "test_contract",
  "user_journeys" => "test_contract",
  "execution_contract" => "runtime",
  "gates" => "risk",
  "source_documents" => "documentation",
  "scope" => "scope",
  "source_contract" => "scope",
  "traceability" => "scope",
  "plan" => "documentation",
  "slice" => "implementation",
  "acceptance" => "acceptance",
  "quality_outcome" => "quality_outcome",
  "invalid_completion_guards" => "quality_outcome",
  "quality_rules" => "rules",
  "artifact_policy" => "risk",
  "artifact_provenance" => "risk",
  "destructive_actions" => "risk",
  "write_policy_enforcement" => "risk",
  "implementation_plan" => "implementation",
  "decomposition" => "implementation",
  "design_lifecycle" => "implementation",
  "design_reference" => "implementation",
  "review_strategy" => "review_contract",
  "test_strategy" => "test_contract",
  "test_level" => "test_contract",
  "test_environment" => "test_contract",
  "quality_measurement" => "test_contract",
  "evidence_requirements" => "acceptance",
  "release_readiness" => "release_contract",
  "release_surface" => "release_contract",
  "supply_chain" => "release_contract",
  "final_aggregate_audit" => "release_contract",
  "final_audit" => "release_contract",
  "must_answer" => "review_contract",
  "stop_policy" => "release_contract",
  "tool_requirements" => "runtime",
  "worktree_safety" => "runtime",
  "runtime_identity_policy" => "runtime",
  "runtime_policy" => "runtime",
  "completion_notice_policy" => "release_contract",
  "protocol_changed" => "release_contract",
  "quality_calibration" => "review_contract",
  "objective" => "scope",
  "task_risk" => "risk",
  "project_profile" => "risk",
  "parent_goal" => "scope",
  "parent_goal_status" => "documentation",
  "rule_packs" => "rules",
  "compatibility_policy" => "risk",
  "multi_user_ownership" => "risk",
  "self_review_guard" => "review_contract",
  "backup_migration" => "risk"
}.freeze

REVISION_TRACKED_FIELDS = REVISION_FIELD_CHANGE_TYPES.keys.freeze
REVISION_METADATA_FIELDS = %w[
  __orbit_path revision_id revision_number revision_signature revision_snapshot revision_history
].freeze

REVISION_INVALIDATION = {
  "scope" => %w[implementation review test design_readiness release rules],
  "acceptance" => %w[implementation review test design_readiness release rules],
  "quality_outcome" => %w[implementation review test design_readiness release rules],
  "implementation" => %w[implementation review test release],
  "review_contract" => %w[review design_readiness rules],
  "test_contract" => %w[test release rules],
  "release_contract" => %w[release rules],
  "risk" => %w[implementation review test design_readiness release rules],
  "rules" => %w[review test design_readiness release rules],
  "runtime" => %w[implementation review test release rules],
  "documentation" => []
}.freeze

DEFAULT_DURABLE_SUMMARY_DIR = "orbit-summaries"
DEFAULT_HANDOFF_DIR = File.join(".orbit", "handoffs")

def project_relative_persisted_path(path, field: "path", strict: false)
  expanded = File.expand_path(path)
  root = File.realpath(Dir.pwd)
  real_parent = File.realpath(File.dirname(expanded)) rescue File.expand_path(File.dirname(expanded))
  unless expanded == root || expanded.start_with?("#{root}/")
    usage_error("#{field} must be inside the current project so persisted paths remain portable.") if strict
    return expanded
  end
  unless real_parent == root || real_parent.start_with?("#{root}/")
    usage_error("#{field} resolves outside the current project.") if strict
    return expanded
  end

  expanded.delete_prefix("#{root}/")
end

def revision_canonical_data(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) { |key, memo| memo[key] = revision_canonical_data(value[key]) }
  when Array
    value.map { |item| revision_canonical_data(item) }
  else
    value
  end
end

def revision_value_digest(value)
  Digest::SHA256.hexdigest(JSON.generate(revision_canonical_data(value)))
end

def task_revision_snapshot(task)
  task.each_with_object({}) do |(field, value), snapshot|
    next if REVISION_METADATA_FIELDS.include?(field)

    snapshot[field] = revision_value_digest(value)
  end
end

def task_revision_signature(task)
  Digest::SHA256.hexdigest(JSON.generate(task_revision_snapshot(task).sort.to_h))
end

def task_revision_frozen?(task)
  task.is_a?(Hash) && task["revision_number"].to_i.positive? && task["revision_id"].to_s.match?(/\Ar\d+-[0-9a-f]{12}\z/)
end

def task_revision_id(task, task_path = nil)
  return task["revision_id"] if task_revision_frozen?(task)

  path = task_path || (task.is_a?(Hash) ? task["__orbit_path"] : nil)
  path && File.file?(path) ? "sha256:#{sha256_file(path)}" : ""
end

def task_revision_number(task)
  task_revision_frozen?(task) ? task["revision_number"].to_i : nil
end

def revision_id_for(number, signature)
  "r#{number}-#{signature[0, 12]}"
end

def changed_revision_fields(task)
  previous = task["revision_snapshot"]
  return [] unless previous.is_a?(Hash)

  current = task_revision_snapshot(task)
  (previous.keys | current.keys).select { |field| previous[field] != current[field] }.sort
end

def invalidated_evidence_for_change_types(change_types)
  Array(change_types).flat_map { |type| REVISION_INVALIDATION.fetch(type, []) }.uniq
end

def freeze_task_revision!(task_path)
  updated = nil
  with_orbit_file_lock(task_path) do |expanded|
    task = load_yaml(expanded)
    state_error("Task file must contain a mapping before revision freeze.") unless task.is_a?(Hash)
    ensure_task_id!(task)
    if task_revision_frozen?(task)
      updated = task
      next
    end

    now = Time.now.utc.iso8601
    pre_freeze_task_sha256 = sha256_file(expanded)
    signature = task_revision_signature(task)
    revision_id = revision_id_for(1, signature)
    task["revision_number"] = 1
    task["revision_id"] = revision_id
    task["revision_signature"] = signature
    task["revision_snapshot"] = task_revision_snapshot(task)
    task["revision_history"] = [{
      "number" => 1,
      "revision_id" => revision_id,
      "parent_revision_id" => nil,
      "reason" => "execution_start",
      "change_types" => ["implementation"],
      "changed_fields" => [],
      "invalidated_evidence" => [],
      "pre_freeze_task_sha256" => pre_freeze_task_sha256,
      "created_at" => now
    }]
    atomic_replace_file(expanded, YAML.dump(task))
    updated = task
  end
  updated
end

def validate_task_revision_contract(result, task)
  unless task_id_valid?(task["task_id"])
    if !task_revision_frozen?(task) && task["task_id"].to_s.empty?
      validation_warning(result, "task_file.task_id", "Legacy draft task has no task_id; Orbit will assign one when the revision is first frozen.")
    else
      validation_error(result, "task_file.task_id", "Task must define an immutable task_id using otask_<24 lowercase hex>.")
    end
  end
  revision_id = task["revision_id"]
  revision_number = task["revision_number"]
  history = task["revision_history"]
  snapshot = task["revision_snapshot"]
  signature = task["revision_signature"]

  if revision_id.nil?
    validation_warning(result, "task_file.revision_id", "Task should define revision_id; recreate with current Orbit before relying on selective gate invalidation.")
    return
  end

  if revision_id == "draft"
    validation_error(result, "task_file.revision_number", "Draft task revision_number must be 0.") unless revision_number.to_i.zero?
    return
  end
  unless task_revision_frozen?(task)
    validation_error(result, "task_file.revision_id", "Frozen revision_id must use r<number>-<12 hex> and revision_number must be positive.")
    return
  end
  unless signature.is_a?(String) && signature.match?(/\A[0-9a-f]{64}\z/)
    validation_error(result, "task_file.revision_signature", "Frozen task must define a 64-character revision_signature.")
  end
  validation_error(result, "task_file.revision_snapshot", "Frozen task must define revision_snapshot.") unless snapshot.is_a?(Hash)
  unless history.is_a?(Array) && !history.empty? && history.last.is_a?(Hash) && history.last["revision_id"] == revision_id
    validation_error(result, "task_file.revision_history", "revision_history must end at the current revision_id.")
  end
  drift = changed_revision_fields(task)
  unless drift.empty?
    validation_error(
      result,
      "task_file.revision_signature",
      "Frozen task fields changed without a new revision: #{drift.join(', ')}. Run orbit revision create --reason ... --change-type ...."
    )
  end
end

def revision_entries_after(task, record_revision_number)
  return [] unless task_revision_frozen?(task) && record_revision_number.to_i.positive?

  Array(task["revision_history"]).select do |entry|
    entry.is_a?(Hash) && entry["number"].to_i > record_revision_number.to_i
  end
end

def evidence_record_revision_eligible?(record, task, evidence_kind, current_task_sha256 = nil)
  return false unless record.is_a?(Hash)
  return false if task_id_valid?(task["task_id"]) && record["task_id"] != task["task_id"]
  unless task_revision_frozen?(task)
    stored = record.dig("role_execution_context", "task_sha256")
    return true if current_task_sha256.to_s.empty?
    return stored == current_task_sha256
  end

  record_number = record["task_revision_number"]
  record_id = record["task_revision_id"]
  if record_number.nil? && record_id.nil?
    stored_task_sha = record.dig("role_execution_context", "task_sha256") || record["task_sha256"]
    return true if !current_task_sha256.to_s.empty? && stored_task_sha == current_task_sha256

    pre_freeze_sha = Array(task["revision_history"]).first&.dig("pre_freeze_task_sha256")
    if !pre_freeze_sha.to_s.empty? && stored_task_sha == pre_freeze_sha
      record_number = 1
      record_id = task["revision_history"].first["revision_id"]
    end
  end
  if record_number.to_i == task["revision_number"].to_i && record_id == task["revision_id"]
    return true
  end
  return false unless record_number.to_i.positive? && record_id.to_s.match?(/\Ar\d+-[0-9a-f]{12}\z/)

  revision_entries_after(task, record_number).none? do |entry|
    Array(entry["invalidated_evidence"]).include?(evidence_kind)
  end
end

def parse_revision_args(args)
  subcommand = args.shift
  usage_error("revision requires create subcommand.") unless subcommand == "create"
  options = { "change_types" => [], "state" => File.join(".orbit", "loop-state.yaml"), "json" => false }
  until args.empty?
    arg = args.shift
    case arg
    when "--task" then options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/ then options["task"] = Regexp.last_match(1)
    when "--reason" then options["reason"] = option_value(args, "--reason")
    when /\A--reason=(.+)\z/ then options["reason"] = Regexp.last_match(1)
    when "--change-type" then options["change_types"].concat(option_value(args, "--change-type").split(","))
    when /\A--change-type=(.+)\z/ then options["change_types"].concat(Regexp.last_match(1).split(","))
    when "--state" then options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/ then options["state"] = Regexp.last_match(1)
    when "--json" then options["json"] = true
    else usage_error("Unknown revision create option: #{arg}")
    end
  end
  %w[task reason].each { |field| usage_error("revision create requires --#{field}.") if options[field].to_s.strip.empty? }
  options["change_types"] = options["change_types"].map(&:strip).reject(&:empty?).uniq
  usage_error("revision create requires at least one --change-type.") if options["change_types"].empty?
  invalid = options["change_types"] - REVISION_CHANGE_TYPES
  usage_error("Unsupported revision change type(s): #{invalid.join(', ')}.") unless invalid.empty?
  usage_error("revision create currently requires --json.") unless options["json"]
  options
end

def revision(args)
  options = parse_revision_args(args)
  task_path = File.expand_path(options["task"])
  packet = nil
  with_orbit_file_lock(task_path) do |expanded|
    task = load_yaml(expanded)
    usage_error("Task file must contain a mapping.") unless task.is_a?(Hash)
    usage_error("Task revision is not frozen; run orbit state start first.") unless task_revision_frozen?(task)
    changed_fields = changed_revision_fields(task)
    usage_error("No revision-tracked task fields changed.") if changed_fields.empty?
    if changed_fields.include?("task_id")
      usage_error("task_id is immutable and cannot be changed by a revision.")
    end
    unmapped_fields = changed_fields.reject { |field| REVISION_FIELD_CHANGE_TYPES.key?(field) }
    unless unmapped_fields.empty?
      usage_error("Changed task fields have no revision change-type mapping and cannot be accepted: #{unmapped_fields.join(', ')}.")
    end
    required_types = changed_fields.map { |field| REVISION_FIELD_CHANGE_TYPES.fetch(field) }.uniq
    missing_types = required_types - options["change_types"]
    unless missing_types.empty?
      usage_error("Declared change types do not cover changed fields; add: #{missing_types.join(', ')}.")
    end

    previous_id = task["revision_id"]
    number = task["revision_number"].to_i + 1
    signature = task_revision_signature(task)
    revision_id = revision_id_for(number, signature)
    invalidated = invalidated_evidence_for_change_types(options["change_types"])
    entry = {
      "number" => number,
      "revision_id" => revision_id,
      "parent_revision_id" => previous_id,
      "reason" => options["reason"].strip,
      "change_types" => options["change_types"],
      "changed_fields" => changed_fields,
      "invalidated_evidence" => invalidated,
      "created_at" => Time.now.utc.iso8601
    }
    task["revision_number"] = number
    task["revision_id"] = revision_id
    task["revision_signature"] = signature
    task["revision_snapshot"] = task_revision_snapshot(task)
    task["revision_history"] ||= []
    task["revision_history"] << entry
    atomic_replace_file(expanded, YAML.dump(task))
    packet = {
      "schema_version" => "orbit-task-revision-v1",
      "task" => project_relative_persisted_path(expanded, field: "task"),
      "task_id" => task["task_id"],
      "revision" => entry,
      "previous_revision_id" => previous_id
    }
  end
  state_path = File.expand_path(options["state"])
  if File.file?(state_path)
    state = load_yaml(state_path) rescue nil
    if state.is_a?(Hash) && !state["current_task"].to_s.empty? && File.expand_path(state["current_task"]) == task_path
      update_loop_state(state_path) do |current|
        current["task_id"] = packet["task_id"]
        current["task_revision_id"] = packet.dig("revision", "revision_id")
        current["task_revision_number"] = packet.dig("revision", "number")
        current["updated_at"] = packet.dig("revision", "created_at")
        append_state_history(current, {
          "event" => "revision",
          "task_id" => packet["task_id"],
          "task_revision_id" => packet.dig("revision", "revision_id"),
          "task_revision_number" => packet.dig("revision", "number"),
          "reason" => packet.dig("revision", "reason"),
          "invalidated_evidence" => packet.dig("revision", "invalidated_evidence"),
          "created_at" => packet.dig("revision", "created_at")
        })
        current
      end
      packet["state"] = project_relative_persisted_path(state_path, field: "state")
    end
  end
  puts JSON.pretty_generate(packet)
end

def durable_summary_directory
  roles_path = File.join(Dir.pwd, ".orbit", "roles.yaml")
  config = File.file?(roles_path) ? load_yaml(roles_path) : {}
  configured = config.is_a?(Hash) ? config.dig("knowledge", "durable_summary_dir") : nil
  value = configured.is_a?(String) && !configured.strip.empty? ? configured : DEFAULT_DURABLE_SUMMARY_DIR
  project_relative_persisted_path(value, field: "knowledge.durable_summary_dir", strict: true)
end

def durable_task_slug(task_path)
  File.basename(task_path, File.extname(task_path)).gsub(/[^A-Za-z0-9_.-]/, "-")
end

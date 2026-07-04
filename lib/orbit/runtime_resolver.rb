# frozen_string_literal: true

def runtime_now
  Time.now.utc
end

def runtime_time(value)
  Time.parse(value.to_s)
rescue ArgumentError
  nil
end

def runtime_session_expired?(session)
  heartbeat = session["heartbeat"] || {}
  ttl = heartbeat["ttl_seconds"].to_i
  ttl = DEFAULT_RUNTIME_HEARTBEAT_TTL_SECONDS unless ttl.positive?
  seen = runtime_time(heartbeat["last_seen_at"] || session["updated_at"])
  return true unless seen

  runtime_now - seen > ttl
end

def runtime_current_session_for_instance(instance)
  record = runtime_read_instance(instance)
  session_id = record["current_session_id"].to_s
  session = session_id.empty? ? nil : runtime_read_session(session_id)
  [record, session]
end

def runtime_verification_to_status(session)
  return "absent" unless session.is_a?(Hash)
  return "replaced" if session["state"].to_s == "replaced"
  return "stale" if runtime_session_expired?(session)

  case session.dig("identity", "verification").to_s
  when "herdr_verified"
    session["state"].to_s == "active" ? "verified" : "pending"
  when "identity_pending"
    "pending"
  when "manual_runtime"
    "manual_runtime"
  else
    session["state"].to_s == "replaced" ? "stale" : "mismatch"
  end
end

def runtime_liveness_for_session(session)
  return ["not_alive", "no_runtime_session"] unless session.is_a?(Hash)
  return ["not_alive", "runtime_session_replaced"] if session["state"].to_s == "replaced"
  return ["not_alive", "runtime_session_expired"] if runtime_session_expired?(session)
  return ["unknown", "runtime_session_not_herdr_verified"] unless session.dig("identity", "verification") == "herdr_verified"

  canonical = session.dig("herdr", "canonical_pane").to_s
  pane = session.dig("herdr", "pane").to_s
  probe = herdr_probe_agents_for_panes([canonical, pane])
  return ["unknown", "herdr_probe_failed"] unless probe["success"]
  return ["not_alive", "herdr_agent_missing"] if probe["candidate_count"].to_i.zero?

  matching = probe["candidates"].find { |candidate| herdr_agent_matches_session?(candidate, session) }
  return ["not_alive", "herdr_agent_identity_mismatch"] unless matching

  ["alive", "herdr_verified_session", matching]
end

def runtime_availability_from_agent_status(agent_status)
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

def runtime_ack_valid_for_session?(record, session)
  return false unless record.is_a?(Hash) && session.is_a?(Hash)

  ack = record["ack"]
  return false unless ack.is_a?(Hash)
  return false unless ack["target_session_id"].to_s == session["session_id"].to_s
  return false unless ack["target_pane"].to_s == session.dig("herdr", "canonical_pane").to_s

  acknowledged_at = runtime_time(ack["acknowledged_at"])
  return false unless acknowledged_at

  ttl = ack["ttl_seconds"].to_i
  ttl = DEFAULT_RUNTIME_HEARTBEAT_TTL_SECONDS unless ttl.positive?
  runtime_now - acknowledged_at <= ttl
end

def runtime_availability_for_session(session, liveness, agent = nil, record = nil)
  return "manual_runtime" if session&.dig("identity", "verification") == "manual_runtime"
  if liveness == "alive" && agent.is_a?(Hash)
    availability = runtime_availability_from_agent_status(agent["agent_status"]).first
    return "available" if availability == "available_needs_seen" && runtime_ack_valid_for_session?(record, session)

    return availability
  end
  return "missing" if liveness == "not_alive"

  "unknown"
end

def runtime_config_binding_for_instance(instance)
  _roles, instances = load_project_instance_config_for_cli[0, 2]
  config = instances[instance] || {}
  normalize_instance_binding(instance, config)
rescue SystemExit
  {}
end

def runtime_binding_matches_session?(binding, session)
  return false unless binding.is_a?(Hash) && session.is_a?(Hash)

  expected = session.dig("herdr", "canonical_pane").to_s
  return false if expected.empty?

  [binding["canonical_pane"], binding["pane"]].map(&:to_s).include?(expected)
end

def runtime_session_config_mismatch_reason(session, instance)
  return "missing_runtime_session" unless session.is_a?(Hash)
  return "schema_version_mismatch" unless session["schema_version"].to_s == RUNTIME_SESSION_SCHEMA
  return "instance_mismatch" unless session["instance"].to_s == instance.to_s

  required = %w[
    session_id
    project_root_sha256
    role_config_sha256
    instance_config_sha256
  ]
  required << "launch_id" unless session.dig("identity", "verification").to_s == "manual_runtime"
  missing = required.find { |key| session[key].to_s.empty? }
  return "missing_#{missing}" if missing

  return "project_root_hash_mismatch" unless session["project_root_sha256"].to_s == runtime_project_root_sha256(Dir.pwd)

  hashes = runtime_config_hashes(instance)
  return "role_config_hash_mismatch" unless session["role_config_sha256"].to_s == hashes["role_config_sha256"].to_s
  return "instance_config_hash_mismatch" unless session["instance_config_sha256"].to_s == hashes["instance_config_sha256"].to_s

  nil
end

def runtime_resolve_instance(instance, explicit_pane: nil)
  record, session = runtime_current_session_for_instance(instance)
  discovered = false
  if !session.is_a?(Hash) || runtime_session_expired?(session)
    candidates = runtime_verified_session_candidates(instance)
    if candidates.length == 1
      session = candidates.first
      discovered = true
    elsif candidates.length > 1
      return {
        "schema_version" => "orbit-runtime-resolution-v1",
        "instance" => instance,
        "state" => record["current_state"],
        "herdr_liveness" => "unknown",
        "liveness_reason" => "multiple_verified_runtime_sessions",
        "identity_verification" => "mismatch",
        "availability" => "unknown",
        "binding_resolution" => "ambiguous",
        "dispatch_ready" => false,
        "candidates" => candidates.map do |candidate|
          {
            "session_id" => candidate["session_id"],
            "canonical_pane" => candidate.dig("herdr", "canonical_pane"),
            "updated_at" => candidate["updated_at"]
          }
        end,
        "runtime_instance" => record
      }.compact
    end
  end

  config_mismatch_reason = runtime_session_config_mismatch_reason(session, instance) if session.is_a?(Hash)
  if config_mismatch_reason
    return {
      "schema_version" => "orbit-runtime-resolution-v1",
      "instance" => instance,
      "session_id" => session["session_id"],
      "state" => session["state"] || record["current_state"],
      "herdr_liveness" => "not_alive",
      "liveness_reason" => config_mismatch_reason,
      "identity_verification" => "mismatch",
      "availability" => "unknown",
      "binding_resolution" => "stale",
      "canonical_pane" => session.dig("herdr", "canonical_pane"),
      "dispatch_ready" => false,
      "runtime_instance" => record,
      "runtime_session" => session
    }.compact
  end

  identity_verification = runtime_verification_to_status(session)
  liveness, liveness_reason, agent = runtime_liveness_for_session(session)
  availability = runtime_availability_for_session(session, liveness, agent, record)
  _agent_availability, agent_availability_reason = runtime_availability_from_agent_status(agent["agent_status"]) if agent.is_a?(Hash)
  canonical_pane = session&.dig("herdr", "canonical_pane").to_s
  binding = runtime_config_binding_for_instance(instance)
  binding_resolution = if discovered
                         "repaired"
                       elsif record["current_session_id"].to_s.empty?
                         "missing"
                       elsif liveness == "alive" && identity_verification == "verified" && !runtime_binding_matches_session?(binding, session)
                         "repaired"
                       elsif liveness == "not_alive"
                         "stale"
                       else
                         "current"
                       end
  dispatch_ready = liveness == "alive" &&
                   identity_verification == "verified" &&
                   availability == "available" &&
                   (explicit_pane.to_s.empty? || explicit_pane.to_s == canonical_pane)
  identity_verification = "override" if !explicit_pane.to_s.empty? && !dispatch_ready

  {
    "schema_version" => "orbit-runtime-resolution-v1",
    "instance" => instance,
    "session_id" => session&.dig("session_id"),
    "state" => session&.dig("state") || record["current_state"],
    "herdr_liveness" => liveness,
    "liveness_reason" => liveness_reason,
    "identity_verification" => identity_verification,
    "availability" => availability,
    "availability_reason" => agent_availability_reason,
    "agent_status" => agent&.dig("agent_status"),
    "binding_resolution" => binding_resolution,
    "canonical_pane" => canonical_pane,
    "dispatch_ready" => dispatch_ready,
    "runtime_instance" => record,
    "runtime_session" => session
  }.compact
end

def runtime_verified_session_candidates(instance)
  hashes = runtime_config_hashes(instance)
  project_hash = runtime_project_root_sha256(Dir.pwd)
  pattern = File.join(orbit_runtime_sessions_dir, "*.json")
  Dir.glob(pattern).each_with_object([]) do |path, sessions|
    session = runtime_load_json_file(path)
    next unless session.is_a?(Hash)
    next unless session["instance"].to_s == instance.to_s
    next unless session["project_root_sha256"].to_s == project_hash
    next unless session["role_config_sha256"].to_s == hashes["role_config_sha256"].to_s
    next unless session["instance_config_sha256"].to_s == hashes["instance_config_sha256"].to_s
    next unless session["state"].to_s == "active"
    next unless session.dig("identity", "verification") == "herdr_verified"
    next if runtime_session_expired?(session)

    liveness, = runtime_liveness_for_session(session)
    next unless liveness == "alive"

    sessions << session
  end
end

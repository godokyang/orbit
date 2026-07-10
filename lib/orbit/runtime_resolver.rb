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

def runtime_trusted_caller_proof_provider_available?
  runtime_proof_provider_status["available"] == true
end

def runtime_automatic_provider_e2e_available?
  runtime_proof_provider_e2e_pass?
end

def runtime_capability_profile(herdr_available: herdr_available?)
  provider_status = runtime_proof_provider_status
  trusted_proof = provider_status["available"] == true
  provider_e2e = runtime_proof_provider_e2e_pass?(provider_status)
  mode = if !herdr_available
           "manual"
         elsif trusted_proof && provider_e2e
           "automatic"
         else
           "automatic-preview"
         end
  direct_dispatch = mode == "automatic"
  reason = case mode
           when "manual"
             "Herdr is unavailable; stable manual file/JSON protocol remains available."
           when "automatic-preview"
             "Herdr can start or inspect panes, but trusted caller proof and provider E2E are unavailable; verified identity and direct dispatch are disabled."
           else
             "Trusted runtime proof and provider E2E are available."
           end

  {
    "mode" => mode,
    "manual_protocol" => "available",
    "automatic_start" => herdr_available ? (direct_dispatch ? "available" : "preview") : "unavailable",
    "verified_identity" => direct_dispatch ? "available" : "unavailable",
    "direct_dispatch" => direct_dispatch ? "available" : "unavailable",
    "trusted_proof_provider" => trusted_proof ? "available" : "unavailable",
    "provider_e2e" => provider_e2e ? "pass" : "unavailable",
    "proof_provider" => provider_status.reject { |key, _value| key == "command" },
    "reason" => reason,
    "recommended_action" => direct_dispatch ? "use_resolver_before_dispatch" : "use_manual_payload"
  }
end

def runtime_session_trusted_caller_proof?(session)
  return false unless session.is_a?(Hash)
  return false unless runtime_trusted_caller_proof_provider_available?
  return false unless session["state"].to_s == "active"
  proof_record = session.dig("identity", "trusted_caller_proof")
  return false unless proof_record.is_a?(Hash) && proof_record["verified"] == true
  proof = proof_record["proof"]
  return false unless proof.is_a?(Hash)
  expected = {
    "session_id" => session["session_id"],
    "launch_id" => session["launch_id"],
    "project_root_sha256" => session["project_root_sha256"],
    "role_config_sha256" => session["role_config_sha256"],
    "instance_config_sha256" => session["instance_config_sha256"],
    "instance" => session["instance"],
    "role" => session["role"],
    "canonical_pane" => session.dig("herdr", "canonical_pane")
  }
  return false unless expected.all? { |field, value| proof[field].to_s == value.to_s }

  challenge = session.dig("identity", "proof_challenge")
  return false unless challenge.is_a?(Hash)
  return false unless challenge["used_proof_id"].to_s == proof["proof_id"].to_s
  return false if challenge["used_at"].to_s.empty?

  runtime_verify_stored_provider_proof(proof_record)
end

def runtime_verification_to_status(session)
  return "absent" unless session.is_a?(Hash)
  return "replaced" if session["state"].to_s == "replaced"
  return "stale" if runtime_session_expired?(session)

  case session.dig("identity", "verification").to_s
  when "herdr_verified"
    return "mismatch" unless runtime_session_trusted_caller_proof?(session)

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
  return ["unknown", "trusted_caller_proof_unavailable"] unless runtime_session_trusted_caller_proof?(session)

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

def runtime_ack_identity_trusted?(runtime_identity)
  return false unless runtime_identity.is_a?(Hash)
  return false unless runtime_identity["verification"] == "herdr_verified"

  session = runtime_read_session(runtime_identity["session_id"])
  return false unless session.is_a?(Hash)
  return false unless session.dig("identity", "trusted_caller_proof", "proof_id").to_s == runtime_identity["proof_id"].to_s

  runtime_session_trusted_caller_proof?(session)
end

def runtime_ack_valid_for_session?(record, session)
  return false unless record.is_a?(Hash) && session.is_a?(Hash)

  ack = record["ack"]
  return false unless ack.is_a?(Hash)
  return false unless ack["verification"].to_s == "herdr_verified"
  return false unless ack["target_session_id"].to_s == session["session_id"].to_s
  return false unless ack["target_pane"].to_s == session.dig("herdr", "canonical_pane").to_s
  return false unless runtime_ack_identity_trusted?(ack["runtime_identity"])

  acknowledged_at = runtime_time(ack["acknowledged_at"])
  return false unless acknowledged_at

  ttl = ack["ttl_seconds"].to_i
  ttl = DEFAULT_RUNTIME_HEARTBEAT_TTL_SECONDS unless ttl.positive?
  runtime_now - acknowledged_at <= ttl
end

def runtime_current_process_session_attribution(identity)
  return nil unless identity.is_a?(Hash)

  instance = identity["resolved_instance"].to_s
  role = identity["resolved_role"].to_s
  session_id = runtime_env_session_id
  herdr = herdr_current_context
  if session_id.empty?
    if herdr["pane"].to_s.empty?
      return {
        "verification" => "manual_runtime",
        "source" => "current_process",
        "reason" => "missing_orbit_session_id"
      }
    end

    return {
      "verification" => "identity_pending",
      "source" => "current_process",
      "reason" => "unbound_herdr_session",
      "herdr_pane" => herdr["pane"].to_s
    }
  end

  session = runtime_read_session(session_id)
  return { "verification" => "absent", "session_id" => session_id, "source" => "current_process", "reason" => "runtime_session_missing" } unless session.is_a?(Hash)
  return { "verification" => "mismatch", "session_id" => session_id, "source" => "current_process", "reason" => "instance_mismatch" } unless session["instance"].to_s == instance
  return { "verification" => "mismatch", "session_id" => session_id, "source" => "current_process", "reason" => "role_mismatch" } unless session["role"].to_s == role

  launch_id = runtime_env_launch_id
  if !launch_id.empty? && session["launch_id"].to_s != launch_id
    return { "verification" => "mismatch", "session_id" => session_id, "source" => "current_process", "reason" => "launch_id_mismatch" }
  end

  config_mismatch = runtime_session_config_mismatch_reason(session, instance)
  if config_mismatch
    return { "verification" => "mismatch", "session_id" => session_id, "source" => "current_process", "reason" => config_mismatch }
  end

  session_status = runtime_verification_to_status(session)
  unless session["state"].to_s == "active" && session.dig("identity", "verification") == "herdr_verified" && session_status == "verified"
    verification = session_status == "verified" ? "mismatch" : session_status
    return { "verification" => verification, "session_id" => session_id, "source" => "current_process", "reason" => "session_not_active_herdr_verified" }
  end

  expected_panes = [session.dig("herdr", "canonical_pane"), session.dig("herdr", "pane")].map(&:to_s).reject(&:empty?)
  current_pane = herdr["pane"].to_s
  return { "verification" => "mismatch", "session_id" => session_id, "source" => "current_process", "reason" => "herdr_pane_missing" } if current_pane.empty?
  unless expected_panes.include?(current_pane)
    return { "verification" => "mismatch", "session_id" => session_id, "source" => "current_process", "reason" => "herdr_pane_mismatch", "herdr_pane" => current_pane }
  end

  expected_herdr_session = session.dig("herdr", "session").to_s
  current_herdr_session = herdr["session"].to_s
  if !expected_herdr_session.empty? && expected_herdr_session != current_herdr_session
    return { "verification" => "mismatch", "session_id" => session_id, "source" => "current_process", "reason" => "herdr_session_mismatch" }
  end

  {
    "verification" => "herdr_verified",
    "session_id" => session_id,
    "herdr_pane" => session.dig("herdr", "canonical_pane"),
    "instance" => session["instance"],
    "role" => session["role"],
    "provider" => session.dig("identity", "trusted_caller_proof", "provider"),
    "proof_id" => session.dig("identity", "trusted_caller_proof", "proof_id"),
    "proof_verified_at" => session.dig("identity", "trusted_caller_proof", "verified_at"),
    "source" => "current_process",
    "reason" => "trusted_provider_proof_verified"
  }.compact
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
  return [] unless runtime_trusted_caller_proof_provider_available?

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
    next unless runtime_session_trusted_caller_proof?(session)
    next if runtime_session_expired?(session)

    liveness, = runtime_liveness_for_session(session)
    next unless liveness == "alive"

    sessions << session
  end
end

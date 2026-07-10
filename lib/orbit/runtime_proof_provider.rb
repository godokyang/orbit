# frozen_string_literal: true

RUNTIME_PROOF_PROVIDER_STATUS_SCHEMA = "orbit-runtime-proof-provider-status-v1"
RUNTIME_PROOF_CHALLENGE_SCHEMA = "orbit-runtime-proof-challenge-v1"
RUNTIME_PROOF_SCHEMA = "orbit-runtime-proof-v1"
RUNTIME_PROOF_TTL_SECONDS = 60
RUNTIME_PROOF_CLOCK_SKEW_SECONDS = 5
RUNTIME_PROVIDER_E2E_FLOW = %w[
  start
  verified_identity
  dispatch_ready
  direct_dispatch
  evidence_submit
  wait_gate_ready
].freeze

def runtime_proof_provider_unavailable(reason = "herdr_caller_pane_proof_unavailable", detail = nil)
  {
    "available" => false,
    "provider" => "herdr",
    "reason" => reason,
    "detail" => detail || "Herdr did not expose a valid controlled orbit-proof provider."
  }
end

def runtime_proof_provider_status(refresh: false)
  path = herdr_command_path
  return runtime_proof_provider_unavailable("herdr_not_found") unless path

  cache_key = [path, (File.mtime(path).to_f rescue nil)]
  if !refresh && defined?(@runtime_proof_provider_status_cache) && @runtime_proof_provider_status_cache_key == cache_key
    return JSON.parse(JSON.generate(@runtime_proof_provider_status_cache))
  end

  stdout, stderr, status = Open3.capture3(path, "orbit-proof", "status", "--json")
  unless status.success?
    result = runtime_proof_provider_unavailable("provider_status_failed", stderr.to_s.strip)
    @runtime_proof_provider_status_cache_key = cache_key
    @runtime_proof_provider_status_cache = result
    return JSON.parse(JSON.generate(result))
  end

  packet = JSON.parse(stdout)
  valid = packet.is_a?(Hash) &&
          packet["schema_version"] == RUNTIME_PROOF_PROVIDER_STATUS_SCHEMA &&
          packet["provider"] == "herdr" &&
          packet["protocol"] == RUNTIME_PROOF_SCHEMA &&
          packet["controlled_issuance"] == true
  result = if valid
             {
               "available" => true,
               "provider" => "herdr",
               "protocol" => packet["protocol"],
               "controlled_issuance" => true,
               "provider_version" => packet["provider_version"],
               "e2e" => packet["e2e"],
               "command" => path
             }.compact
           else
             runtime_proof_provider_unavailable("provider_status_invalid", "Provider status did not satisfy the controlled issuance contract.")
           end
  @runtime_proof_provider_status_cache_key = cache_key
  @runtime_proof_provider_status_cache = result
  JSON.parse(JSON.generate(result))
rescue JSON::ParserError => e
  runtime_proof_provider_unavailable("provider_status_invalid_json", e.message)
end

def runtime_proof_provider_e2e_pass?(status = runtime_proof_provider_status)
  return false unless status.is_a?(Hash) && status["available"] == true

  e2e = status["e2e"]
  e2e.is_a?(Hash) && e2e["status"] == "pass" && Array(e2e["flow"]) == RUNTIME_PROVIDER_E2E_FLOW
end

def runtime_issue_proof_challenge(session)
  status = runtime_proof_provider_status
  return nil unless status["available"] == true && runtime_proof_provider_e2e_pass?(status)

  now = Time.now.utc
  {
    "schema_version" => RUNTIME_PROOF_CHALLENGE_SCHEMA,
    "provider" => status["provider"],
    "protocol" => status["protocol"],
    "nonce" => SecureRandom.hex(24),
    "session_id" => session["session_id"],
    "launch_id" => session["launch_id"],
    "project_root_sha256" => session["project_root_sha256"],
    "role_config_sha256" => session["role_config_sha256"],
    "instance_config_sha256" => session["instance_config_sha256"],
    "instance" => session["instance"],
    "role" => session["role"],
    "canonical_pane" => session.dig("herdr", "canonical_pane"),
    "issued_at" => now.iso8601,
    "expires_at" => (now + RUNTIME_PROOF_TTL_SECONDS).iso8601,
    "ttl_seconds" => RUNTIME_PROOF_TTL_SECONDS,
    "used_at" => nil,
    "used_proof_id" => nil
  }
end

def runtime_proof_challenge_error(challenge, session)
  return "proof_challenge_missing" unless challenge.is_a?(Hash)
  return "proof_challenge_schema_mismatch" unless challenge["schema_version"] == RUNTIME_PROOF_CHALLENGE_SCHEMA
  return "proof_challenge_already_used" unless challenge["used_at"].to_s.empty? && challenge["used_proof_id"].to_s.empty?
  %w[session_id launch_id project_root_sha256 role_config_sha256 instance_config_sha256 instance role].each do |field|
    return "proof_challenge_#{field}_mismatch" unless challenge[field].to_s == session[field].to_s
  end
  return "proof_challenge_pane_mismatch" unless challenge["canonical_pane"].to_s == session.dig("herdr", "canonical_pane").to_s
  issued_at = runtime_time(challenge["issued_at"])
  expires_at = runtime_time(challenge["expires_at"])
  return "proof_challenge_time_invalid" unless issued_at && expires_at
  return "proof_challenge_ttl_invalid" unless expires_at > issued_at && expires_at - issued_at <= RUNTIME_PROOF_TTL_SECONDS
  return "proof_challenge_issued_in_future" if issued_at - runtime_now > RUNTIME_PROOF_CLOCK_SKEW_SECONDS
  return "proof_challenge_expired" if runtime_now >= expires_at

  nil
end

def runtime_provider_command(action, option, payload)
  path = herdr_command_path
  return [nil, "herdr_not_found"] unless path

  stdout, stderr, status = Open3.capture3(path, "orbit-proof", action, option, JSON.generate(payload), "--json")
  return [nil, "provider_#{action}_failed:#{stderr.to_s.strip}"] unless status.success?

  [JSON.parse(stdout), nil]
rescue JSON::ParserError => e
  [nil, "provider_#{action}_invalid_json:#{e.message}"]
end

def runtime_proof_validation_error(proof, challenge)
  return "proof_missing" unless proof.is_a?(Hash)
  return "proof_schema_mismatch" unless proof["schema_version"] == RUNTIME_PROOF_SCHEMA
  return "proof_provider_mismatch" unless proof["provider"] == "herdr"
  return "proof_id_missing" if proof["proof_id"].to_s.empty?
  %w[nonce session_id launch_id project_root_sha256 role_config_sha256 instance_config_sha256 instance role canonical_pane].each do |field|
    return "proof_#{field}_mismatch" unless proof[field].to_s == challenge[field].to_s
  end
  issued_at = runtime_time(proof["issued_at"])
  expires_at = runtime_time(proof["expires_at"])
  challenge_expiry = runtime_time(challenge["expires_at"])
  return "proof_time_invalid" unless issued_at && expires_at && challenge_expiry
  return "proof_ttl_invalid" unless expires_at > issued_at && expires_at - issued_at <= RUNTIME_PROOF_TTL_SECONDS
  return "proof_expiry_exceeds_challenge" if expires_at > challenge_expiry
  return "proof_issued_in_future" if issued_at - runtime_now > RUNTIME_PROOF_CLOCK_SKEW_SECONDS
  return "proof_expired" if runtime_now >= expires_at

  nil
end

def runtime_request_trusted_caller_proof(session)
  status = runtime_proof_provider_status
  return status unless status["available"] == true
  return runtime_proof_provider_unavailable("provider_e2e_unavailable") unless runtime_proof_provider_e2e_pass?(status)

  challenge = session.dig("identity", "proof_challenge")
  challenge_error = runtime_proof_challenge_error(challenge, session)
  return status.merge("verified" => false, "reason" => challenge_error) if challenge_error

  proof, provider_error = runtime_provider_command("prove", "--challenge-json", challenge)
  return status.merge("verified" => false, "reason" => provider_error) if provider_error

  validation_error = runtime_proof_validation_error(proof, challenge)
  return status.merge("verified" => false, "reason" => validation_error) if validation_error

  {
    "available" => true,
    "verified" => true,
    "provider" => status["provider"],
    "protocol" => status["protocol"],
    "proof_id" => proof["proof_id"],
    "verified_at" => Time.now.utc.iso8601,
    "proof" => proof
  }
end

def runtime_verify_stored_provider_proof(proof_record)
  return false unless proof_record.is_a?(Hash) && proof_record["verified"] == true
  proof = proof_record["proof"]
  return false unless proof.is_a?(Hash) && proof_record["proof_id"].to_s == proof["proof_id"].to_s
  status = runtime_proof_provider_status
  return false unless status["available"] == true && runtime_proof_provider_e2e_pass?(status)

  result, error = runtime_provider_command("verify", "--proof-json", proof)
  error.nil? && result.is_a?(Hash) && result["valid"] == true &&
    result["provider"] == "herdr" && result["proof_id"].to_s == proof["proof_id"].to_s
end

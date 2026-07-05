# frozen_string_literal: true

def runtime_usage_error(message)
  usage_error("runtime: #{message}")
end

def parse_runtime_args(args)
  subcommand = args.shift
  return { "subcommand" => "help" } if subcommand.nil? || %w[-h --help help].include?(subcommand)

  options = {
    "subcommand" => subcommand,
    "json" => false,
    "instance" => nil
  }
  options["instance"] = args.shift if subcommand == "ack-session" && args.first && !args.first.start_with?("--")

  until args.empty?
    arg = args.shift
    case arg
    when "--json"
      options["json"] = true
    else
      runtime_usage_error("Unknown runtime #{subcommand} option: #{arg}")
    end
  end

  options
end

def print_runtime_help
  puts <<~HELP
    Usage:
      orbit runtime register --json
      orbit runtime ack-session INSTANCE --json

    Runtime register records Orbit session diagnostics. In the current Herdr
    adapter, Herdr pane identity is exposed only through process environment,
    so CLI register cannot promote a session to herdr_verified.
  HELP
end

def runtime_identity_snapshot
  result = {
    "schema_version" => "orbit-whoami-v1",
    "project" => File.basename(Dir.pwd),
    "instance" => nil,
    "resolved_role" => nil,
    "role_sources" => {},
    "rules" => [],
    "rule_packs" => [],
    "capabilities" => [],
    "permissions" => {},
    "conflicts" => []
  }
  roles, instances = load_project_config(result)
  role_def = resolve_identity(result, roles, instances)
  if role_def
    result["rules"] = role_def["rules"] || []
    result["capabilities"] = role_def["capabilities"] || []
    result["permissions"] = role_def["permissions"] || {}
  end
  result["valid"] = result["conflicts"].empty?
  result
end

def deep_dup_data(value)
  JSON.parse(JSON.generate(value))
end

def runtime_config_hashes(instance_key)
  roles_config = load_yaml(File.join(Dir.pwd, ".orbit", "roles.yaml"))
  instances_config = load_yaml(File.join(Dir.pwd, ".orbit", "instances.yaml"))
  roles = roles_config["roles"] || {}
  instances = instances_config["instances"] || {}
  instance = instances[instance_key] || {}
  role_ref = instance["role_ref"].to_s
  {
    "role_config_sha256" => runtime_sha256_for_value(roles[role_ref] || {}),
    "instance_config_sha256" => runtime_sha256_for_value(runtime_stable_instance_config(instance))
  }
end

def runtime_stable_instance_config(instance)
  return {} unless instance.is_a?(Hash)

  stable = deep_dup_data(instance)
  stable.delete("binding")
  stable.delete("herdr")
  stable.delete("view")
  stable
end

def runtime_env_session_id
  ENV["ORBIT_SESSION_ID"].to_s.strip
end

def runtime_env_launch_id
  ENV["ORBIT_LAUNCH_ID"].to_s.strip
end

def runtime_generated_session_id(prefix)
  "#{prefix}_#{SecureRandom.hex(12)}"
end

def runtime_base_session(identity, session_id:, launch_id:, state:, verification:)
  instance = identity["resolved_instance"].to_s
  hashes = runtime_config_hashes(instance)
  herdr = herdr_current_context
  {
    "schema_version" => RUNTIME_SESSION_SCHEMA,
    "session_id" => session_id,
    "launch_id" => launch_id,
    "state" => state,
    "project_root" => File.expand_path(Dir.pwd),
    "project_root_sha256" => runtime_project_root_sha256(Dir.pwd),
    "project_id" => File.basename(Dir.pwd),
    "host_id" => runtime_host_id,
    "user" => runtime_user,
    "instance" => instance,
    "role" => identity["resolved_role"].to_s,
    "role_ref" => identity["role_ref"].to_s,
    "role_config_sha256" => hashes["role_config_sha256"],
    "instance_config_sha256" => hashes["instance_config_sha256"],
    "client" => expected_client_name((load_project_instance_config_for_cli[1][instance] || {})["command"]).to_s,
    "command" => command_expected_string((load_project_instance_config_for_cli[1][instance] || {})["command"]),
    "herdr" => {
      "session" => herdr["session"],
      "workspace" => herdr["workspace"],
      "tab" => herdr["tab"],
      "pane" => herdr["pane"],
      "canonical_pane" => herdr["pane"]
    },
    "identity" => {
      "verification" => verification,
      "whoami_valid" => identity["valid"],
      "conflicts" => identity["conflicts"] || []
    }
  }
end

def runtime_pending_session_mismatch_reason(pending, identity)
  return "missing_pending_session" unless pending.is_a?(Hash)
  return "session_not_pending" unless pending["state"].to_s == "pending"
  return "identity_not_pending" unless pending.dig("identity", "verification").to_s == "identity_pending"
  return "session_id_mismatch" unless pending["session_id"].to_s == runtime_env_session_id
  return "launch_id_mismatch" unless pending["launch_id"].to_s == runtime_env_launch_id
  return "identity_invalid" unless identity["valid"]
  return "instance_mismatch" unless pending["instance"].to_s == identity["resolved_instance"].to_s
  return "role_mismatch" unless pending["role"].to_s == identity["resolved_role"].to_s
  return "project_root_hash_mismatch" unless pending["project_root_sha256"].to_s == runtime_project_root_sha256(Dir.pwd)
  hashes = runtime_config_hashes(identity["resolved_instance"])
  return "role_config_hash_mismatch" unless pending["role_config_sha256"].to_s == hashes["role_config_sha256"].to_s
  return "instance_config_hash_mismatch" unless pending["instance_config_sha256"].to_s == hashes["instance_config_sha256"].to_s

  herdr = herdr_current_context
  return "herdr_session_mismatch" unless pending.dig("herdr", "session").to_s == herdr["session"].to_s

  nil
end

def runtime_register_verified?(pending, identity)
  runtime_pending_session_mismatch_reason(pending, identity).nil? && runtime_trusted_caller_proof["available"] == true
end

def runtime_trusted_caller_proof
  {
    "available" => false,
    "provider" => "herdr",
    "reason" => "herdr_caller_pane_proof_unavailable",
    "detail" => "HERDR_PANE_ID is process environment, not proof that the caller belongs to that pane."
  }
end

def runtime_register(_options)
  identity = runtime_identity_snapshot
  runtime_usage_error("register requires valid .orbit identity") unless identity["valid"]

  env_session_id = runtime_env_session_id
  if !env_session_id.empty?
    pending = runtime_read_session(env_session_id)
    mismatch = runtime_pending_session_mismatch_reason(pending, identity)
    runtime_usage_error("register session is not pending identity verification: #{mismatch}") if mismatch
  else
    pending = nil
  end
  session_id = env_session_id.empty? ? runtime_generated_session_id("orm") : env_session_id
  launch_id = runtime_env_launch_id
  session = nil
  if !env_session_id.empty?
    runtime_update_session!(session_id) do |current|
      mismatch = runtime_pending_session_mismatch_reason(current, identity)
      runtime_usage_error("register session is not pending identity verification: #{mismatch}") if mismatch

      proof = runtime_trusted_caller_proof
      verified = runtime_register_verified?(current, identity)
      verification = verified ? "herdr_verified" : "identity_pending"
      state = verified ? "active" : "pending"
      session = runtime_base_session(identity, session_id: session_id, launch_id: launch_id, state: state, verification: verification)
      session["herdr"] = current["herdr"] if current["herdr"].is_a?(Hash)
      session["identity"]["verification_reason"] = proof["reason"] unless verified
      session["identity"]["trusted_caller_proof"] = proof
      session
    end
  else
    verification = herdr_current_context["pane"].to_s.empty? ? "manual_runtime" : "identity_pending"
    state = verification == "identity_pending" ? "pending" : "active"
    session = runtime_base_session(identity, session_id: session_id, launch_id: launch_id, state: state, verification: verification)
    proof = runtime_trusted_caller_proof
    session["identity"]["verification_reason"] = verification == "identity_pending" ? proof["reason"] : "manual_runtime_no_herdr_session"
    session["identity"]["trusted_caller_proof"] = proof if verification == "identity_pending"
    session["diagnostic_only"] = true
    session["persistence"] = "not_written"
  end
  runtime_set_current_session!(identity["resolved_instance"], session_id, state) unless env_session_id.empty?
  resolution = env_session_id.empty? ? nil : runtime_resolve_instance(identity["resolved_instance"])
  identity_verification = if resolution
                            resolution["identity_verification"]
                          elsif verification == "identity_pending"
                            "identity_pending_unbound"
                          else
                            verification
                          end
  {
    "schema_version" => "orbit-runtime-register-v1",
    "instance" => identity["resolved_instance"],
    "role" => identity["resolved_role"],
    "session_id" => session_id,
    "identity_verification" => identity_verification,
    "dispatch_ready" => resolution ? resolution["dispatch_ready"] : false,
    "trusted_caller_proof" => runtime_trusted_caller_proof,
    "runtime_session" => session
  }
end

def runtime_ack_owner_roles
  roles_config = load_yaml(File.join(Dir.pwd, ".orbit", "roles.yaml"))
  policy = roles_config["runtime_policy"]
  roles = policy.is_a?(Hash) ? Array(policy["runtime_ack_owner_roles"]) : []
  (["lead"] + roles).map(&:to_s).reject(&:empty?).uniq
rescue StandardError
  ["lead"]
end

def runtime_instance_owner_role(instance)
  _roles, instances = load_project_instance_config_for_cli[0, 2]
  config = instances[instance] || {}
  config["owner_role"].to_s
rescue SystemExit
  ""
end

def runtime_ack_session(options)
  instance = options["instance"].to_s
  runtime_usage_error("ack-session requires INSTANCE") if instance.empty?
  identity = runtime_identity_snapshot
  runtime_usage_error("ack-session requires valid .orbit identity") unless identity["valid"]
  role = identity["resolved_role"].to_s
  allowed_roles = runtime_ack_owner_roles
  instance_owner = runtime_instance_owner_role(instance)
  allowed_roles << instance_owner unless instance_owner.empty?
  allowed = allowed_roles.uniq.include?(role)
  runtime_usage_error("ack-session requires lead or project runtime owner role") unless allowed
  resolution = runtime_resolve_instance(instance)
  runtime_usage_error("ack-session target has no current session") if resolution["session_id"].to_s.empty?
  owner_runtime_identity = runtime_current_process_session_attribution(identity) || { "verification" => "absent" }

  {
    "schema_version" => "orbit-runtime-ack-session-v1",
    "instance" => instance,
    "action" => "unsupported",
    "reason" => "trusted_owner_ack_unavailable",
    "detail" => "ack-session cannot mark done Herdr targets available until trusted caller-pane proof exists.",
    "ack_written" => false,
    "acknowledged_by" => {
      "role" => identity["resolved_role"],
      "instance" => identity["resolved_instance"],
      "session_id" => runtime_env_session_id,
      "pane" => ENV["HERDR_PANE_ID"].to_s,
      "runtime_identity" => owner_runtime_identity
    },
    "dispatch_ready" => false,
    "runtime_resolution" => resolution.reject { |key, _| %w[runtime_instance runtime_session].include?(key) }
  }
end

def runtime(args)
  options = parse_runtime_args(args)
  if options["subcommand"] == "help"
    print_runtime_help
    return
  end
  runtime_usage_error("runtime #{options["subcommand"]} currently requires --json") unless options["json"]

  result = case options["subcommand"]
           when "register"
             runtime_register(options)
           when "ack-session"
             runtime_ack_session(options)
           else
             runtime_usage_error("Unknown runtime subcommand: #{options["subcommand"]}")
           end
  puts JSON.pretty_generate(result)
end

def runtime_piggyback_skip_command?(command, argv)
  return true if command.nil?
  return true if %w[-h --help help version --version -v init runtime].include?(command)
  return true if argv.length == 1 && %w[-h --help help].include?(argv.first)

  false
end

def runtime_herdr_env_present?
  %w[HERDR_ENV HERDR_PANE_ID HERDR_SESSION_ID HERDR_TAB_ID HERDR_WORKSPACE_ID].any? { |name| !ENV[name].to_s.empty? }
end

def runtime_maybe_piggyback!(command, argv)
  return if ENV["ORBIT_RUNTIME_REFRESHING"].to_s == "1"
  return unless runtime_project_config_present?
  return unless runtime_herdr_env_present?
  return if runtime_piggyback_skip_command?(command, argv)
  return if ENV["ORBIT_SESSION_ID"].to_s.empty?

  ENV["ORBIT_RUNTIME_REFRESHING"] = "1"
  identity = runtime_identity_snapshot
  return unless identity["valid"]

  session = ENV["ORBIT_SESSION_ID"].to_s.empty? ? nil : runtime_read_session(ENV["ORBIT_SESSION_ID"])
  return if session && session.dig("identity", "verification") == "herdr_verified"

  runtime_register("json" => true)
rescue SystemExit
  nil
ensure
  ENV.delete("ORBIT_RUNTIME_REFRESHING")
end

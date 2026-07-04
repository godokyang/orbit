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
      orbit runtime ping --json
      orbit runtime ack-session INSTANCE --json

    Runtime registration is the Orbit-Herdr identity protocol. Herdr env is
    probe input only; verified identity requires Orbit runtime session state
    and a live Herdr probe.
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

def runtime_config_hashes(instance_key)
  roles_config = load_yaml(File.join(Dir.pwd, ".orbit", "roles.yaml"))
  instances_config = load_yaml(File.join(Dir.pwd, ".orbit", "instances.yaml"))
  roles = roles_config["roles"] || {}
  instances = instances_config["instances"] || {}
  instance = instances[instance_key] || {}
  role_ref = instance["role_ref"].to_s
  {
    "role_config_sha256" => runtime_sha256_for_value(roles[role_ref] || {}),
    "instance_config_sha256" => runtime_sha256_for_value(instance)
  }
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

def runtime_register_verified?(pending, identity)
  return false unless pending.is_a?(Hash)
  return false unless pending["state"].to_s == "pending"
  return false unless pending.dig("identity", "verification").to_s == "identity_pending"
  return false unless pending["session_id"].to_s == runtime_env_session_id
  return false unless pending["launch_id"].to_s == runtime_env_launch_id
  return false unless identity["valid"]
  return false unless pending["instance"].to_s == identity["resolved_instance"].to_s
  return false unless pending["role"].to_s == identity["resolved_role"].to_s
  return false unless pending["project_root_sha256"].to_s == runtime_project_root_sha256(Dir.pwd)
  hashes = runtime_config_hashes(identity["resolved_instance"])
  return false unless pending["role_config_sha256"].to_s == hashes["role_config_sha256"].to_s
  return false unless pending["instance_config_sha256"].to_s == hashes["instance_config_sha256"].to_s

  herdr = herdr_current_context
  return false if herdr["pane"].to_s.empty?
  return false unless pending.dig("herdr", "session").to_s == herdr["session"].to_s
  pane_ids = [herdr["pane"], pending.dig("herdr", "canonical_pane"), pending.dig("herdr", "pane")]
  probe = herdr_probe_agents_for_panes(pane_ids)
  return false unless probe["success"]
  return false unless probe["candidate_count"].to_i == 1

  agent = probe["candidates"].first || {}
  return false unless herdr_agent_matches_session?(agent, pending)

  true
end

def runtime_register(_options)
  identity = runtime_identity_snapshot
  runtime_usage_error("register requires valid .orbit identity") unless identity["valid"]

  env_session_id = runtime_env_session_id
  if !env_session_id.empty?
    pending = runtime_read_session(env_session_id)
    runtime_usage_error("register session is not pending identity verification") unless pending.is_a?(Hash) && pending["state"].to_s == "pending" && pending.dig("identity", "verification").to_s == "identity_pending"
  else
    pending = nil
  end
  verified = runtime_register_verified?(pending, identity)
  session_id = env_session_id.empty? ? runtime_generated_session_id("orm") : env_session_id
  launch_id = runtime_env_launch_id
  verification = verified ? "herdr_verified" : (herdr_current_context["pane"].to_s.empty? ? "manual_runtime" : "identity_pending")
  state = verification == "identity_pending" ? "pending" : "active"
  session = runtime_base_session(identity, session_id: session_id, launch_id: launch_id, state: state, verification: verification)
  session["herdr"] = pending["herdr"] if verified && pending&.dig("herdr").is_a?(Hash)
  if !env_session_id.empty?
    runtime_update_session!(session_id) do |current|
      runtime_usage_error("register session is not pending identity verification") unless runtime_register_verified?(current, identity)

      session["herdr"] = current["herdr"] if current["herdr"].is_a?(Hash)
      session
    end
  else
    runtime_write_session!(session)
  end
  runtime_set_current_session!(identity["resolved_instance"], session_id, state)
  resolution = runtime_resolve_instance(identity["resolved_instance"])
  {
    "schema_version" => "orbit-runtime-register-v1",
    "instance" => identity["resolved_instance"],
    "role" => identity["resolved_role"],
    "session_id" => session_id,
    "identity_verification" => resolution["identity_verification"],
    "dispatch_ready" => resolution["dispatch_ready"],
    "runtime_session" => session
  }
end

def runtime_ping(_options)
  identity = runtime_identity_snapshot
  runtime_usage_error("ping requires valid .orbit identity") unless identity["valid"]
  session_id = runtime_env_session_id
  runtime_usage_error("ping requires ORBIT_SESSION_ID") if session_id.empty?
  session = nil
  runtime_update_session!(session_id) do |current|
    runtime_usage_error("unknown runtime session #{session_id.inspect}") unless current
    runtime_usage_error("ping session instance mismatch") unless current["instance"].to_s == identity["resolved_instance"].to_s
    runtime_usage_error("ping session role mismatch") unless current["role"].to_s == identity["resolved_role"].to_s
    runtime_usage_error("ping requires active Herdr-verified session") unless current["state"].to_s == "active" && current.dig("identity", "verification") == "herdr_verified"
    mismatch = runtime_session_config_mismatch_reason(current, identity["resolved_instance"])
    runtime_usage_error("ping session is not current for this checkout: #{mismatch}") if mismatch

    now = Time.now.utc.iso8601
    current["heartbeat"] ||= {}
    current["heartbeat"]["last_seen_at"] = now
    current["updated_at"] = now
    session = current
    current
  end
  runtime_set_current_session!(identity["resolved_instance"], session_id, session["state"])
  {
    "schema_version" => "orbit-runtime-ping-v1",
    "instance" => identity["resolved_instance"],
    "session_id" => session_id,
    "heartbeat" => session["heartbeat"],
    "identity_verification" => runtime_resolve_instance(identity["resolved_instance"])["identity_verification"]
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

  ack = {
    "acknowledged_at" => Time.now.utc.iso8601,
    "ttl_seconds" => DEFAULT_RUNTIME_HEARTBEAT_TTL_SECONDS,
    "acknowledged_by" => {
      "role" => identity["resolved_role"],
      "instance" => identity["resolved_instance"],
      "session_id" => runtime_env_session_id,
      "pane" => ENV["HERDR_PANE_ID"].to_s
    },
    "target_session_id" => resolution["session_id"],
    "target_pane" => resolution["canonical_pane"]
  }
  runtime_update_instance!(instance) do |record|
    record["ack"] = ack
    record
  end
  after_ack = runtime_resolve_instance(instance)
  {
    "schema_version" => "orbit-runtime-ack-session-v1",
    "instance" => instance,
    "ack" => ack,
    "dispatch_ready" => after_ack["dispatch_ready"],
    "runtime_resolution" => after_ack.reject { |key, _| %w[runtime_instance runtime_session].include?(key) }
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
           when "ping"
             runtime_ping(options)
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
  if session && session.dig("identity", "verification") == "herdr_verified"
    runtime_ping("json" => true)
  else
    runtime_register("json" => true)
  end
rescue SystemExit
  nil
ensure
  ENV.delete("ORBIT_RUNTIME_REFRESHING")
end

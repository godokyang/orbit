# frozen_string_literal: true

def init_config(args)
  force = false

  args.each do |arg|
    case arg
    when "--force"
      force = true
    else
      usage_error("Unknown init option: #{arg}")
    end
  end

  target_dir = File.join(Dir.pwd, ".orbit")
  files = {
    "roles.yaml" => File.join(TEMPLATE_ROOT, "roles.yaml"),
    "instances.yaml" => File.join(TEMPLATE_ROOT, "instances.yaml"),
    "loop-state.yaml" => File.join(TEMPLATE_ROOT, "loop-state.yaml")
  }

  missing_templates = files.values.reject { |path| File.file?(path) }
  unless missing_templates.empty?
    warn "Missing Orbit template(s):"
    missing_templates.each { |path| warn "- #{path}" }
    exit 66
  end

  existing_targets = files.keys
                          .map { |name| File.join(target_dir, name) }
                          .select { |path| File.exist?(path) }

  if !force && !existing_targets.empty?
    warn "Orbit config already exists:"
    existing_targets.each { |path| warn "- #{path}" }
    warn "Use `orbit init --force` to overwrite existing files."
    exit 73
  end

  FileUtils.mkdir_p(target_dir)
  files.each do |name, template_path|
    target_path = File.join(target_dir, name)
    if name == "loop-state.yaml"
      state = load_yaml(template_path)
      state["project"] = File.basename(Dir.pwd)
      state["updated_at"] = Time.now.utc.iso8601
      write_file_atomically(target_path, YAML.dump(state))
    else
      write_file_atomically(target_path, File.read(template_path))
    end
  end

  puts "Initialized Orbit config:"
  files.keys.each { |name| puts "- .orbit/#{name}" }
  puts
  puts "Next:"
  puts "- ORBIT_INSTANCE=reviewer orbit whoami --json"
end

def load_yaml(path)
  if File.directory?(path)
    raise "Expected a YAML/JSON file but got directory: #{path}. If this is evidence, run `orbit evidence init --output PATH` and pass that manifest file; do not pass an evidence directory."
  end

  YAML.safe_load(File.read(path), aliases: true, filename: path) || {}
rescue Errno::ENOENT
  raise "Missing file: #{path}"
rescue Errno::EISDIR
  raise "Expected a YAML/JSON file but got directory: #{path}. If this is evidence, run `orbit evidence init --output PATH` and pass that manifest file; do not pass an evidence directory."
rescue Psych::Exception => e
  raise "Invalid YAML in #{path}: #{e.message}"
end

def with_orbit_file_lock(path)
  expanded = File.expand_path(path)
  FileUtils.mkdir_p(File.dirname(expanded))
  lock_path = "#{expanded}.lock"

  File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
    lock.flock(File::LOCK_EX)
    yield expanded
  ensure
    lock.flock(File::LOCK_UN) if lock
  end
end

def fsync_directory(path)
  Dir.open(path) do |dir|
    dir.fsync if dir.respond_to?(:fsync)
  end
rescue Errno::EINVAL, Errno::ENOTSUP, NotImplementedError
  nil
end

def atomic_replace_file(path, content)
  expanded = File.expand_path(path)
  dir = File.dirname(expanded)
  FileUtils.mkdir_p(dir)
  tmp = File.join(dir, ".#{File.basename(expanded)}.tmp.#{$$}.#{Thread.current.object_id}")

  File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write(content)
    file.flush
    begin
      file.fsync
    rescue Errno::EINVAL, Errno::ENOTSUP, NotImplementedError
      nil
    end
  end
  File.rename(tmp, expanded)
  fsync_directory(dir)
ensure
  FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
end

def write_file_atomically(path, content)
  with_orbit_file_lock(path) do |expanded|
    atomic_replace_file(expanded, content)
  end
end

def update_yaml_file_atomically(path)
  with_orbit_file_lock(path) do |expanded|
    data = load_yaml(expanded)
    updated = yield(data)
    updated = data if updated.nil?
    atomic_replace_file(expanded, YAML.dump(updated))
    updated
  end
end

def update_json_file_atomically(path)
  with_orbit_file_lock(path) do |expanded|
    data = load_yaml(expanded)
    updated = yield(data)
    updated = data if updated.nil?
    atomic_replace_file(expanded, "#{JSON.pretty_generate(updated)}\n")
    updated
  end
end

def conflict(result, source, message)
  result["conflicts"] << {
    "source" => source,
    "message" => message
  }
end

def find_instance(instances, roles, instance_name)
  return [nil, nil] unless instance_name
  return [instance_name, nil] if instances.key?(instance_name)

  if instance_name.end_with?("-main")
    alias_name = instance_name.delete_suffix("-main")
    return [alias_name, alias_name] if instances.key?(alias_name)
  end

  [nil, nil]
end

def infer_instance_from_role(instances, roles, role_name)
  matches = instances.select do |_name, instance|
    role_ref = instance["role_ref"]
    role_def = roles[role_ref]
    role_def && role_def["role"] == role_name
  end

  return matches.keys.first if matches.length == 1

  nil
end

ALLOWED_INSTANCE_MANAGEMENT = %w[user_managed orbit_managed].freeze
ALLOWED_INSTANCE_TRANSPORTS = %w[generic herdr local].freeze

def instance_management(instance)
  value = instance["management"].to_s.strip
  value.empty? ? "user_managed" : value
end

def validate_instance_management!(instance_name, instance)
  management = instance_management(instance)
  usage_error("Instance #{instance_name.inspect} management must be one of #{ALLOWED_INSTANCE_MANAGEMENT.join("|")}.") unless ALLOWED_INSTANCE_MANAGEMENT.include?(management)
  management
end

def normalize_instance_transport(instance_name, instance)
  transport = instance["transport"] || {}
  usage_error("Instance #{instance_name.inspect} transport must be a mapping when present.") unless transport.is_a?(Hash)

  kind = transport["kind"].to_s.strip
  kind = "local" if kind.empty?
  usage_error("Instance #{instance_name.inspect} transport.kind must be one of #{ALLOWED_INSTANCE_TRANSPORTS.join("|")}.") unless ALLOWED_INSTANCE_TRANSPORTS.include?(kind)

  binding = transport["binding"] || {}
  health = transport["health"] || {}
  usage_error("Instance #{instance_name.inspect} transport.binding must be a mapping when present.") unless binding.is_a?(Hash)
  usage_error("Instance #{instance_name.inspect} transport.health must be a mapping when present.") unless health.is_a?(Hash)

  {
    "kind" => kind,
    "binding" => {
      "pane" => binding["pane"].to_s,
      "tab" => binding["tab"].to_s,
      "space" => binding["space"].to_s
    },
    "health" => {
      "last_heartbeat" => health["last_heartbeat"].to_s,
      "cwd" => health["cwd"].to_s,
      "git_head" => health["git_head"].to_s,
      "actual_client" => health["actual_client"].to_s
    }
  }
end

def transport_binding_present?(transport)
  binding = transport["binding"] || {}
  %w[pane tab space].any? { |field| !binding[field].to_s.empty? }
end

def instance_binding_status(transport)
  transport_binding_present?(transport) ? "healthy" : "unbound"
end

def recommended_instance_action(management, binding_status)
  return "reuse" if binding_status == "healthy"
  return "start_missing_instance" if management == "orbit_managed"

  "ask_user_or_bind"
end

def command_expected_string(command)
  normalize_command_argv(command, "instance").join(" ")
rescue SystemExit
  command.is_a?(Array) ? command.join(" ") : command.to_s
end

def expected_client_name(command)
  argv = normalize_command_argv(command, "instance")
  File.basename(argv.first.to_s)
rescue SystemExit
  nil
end

def runtime_actual_client
  value = ENV["ORBIT_CLIENT"].to_s.strip
  return value unless value.empty?

  "unknown"
end

def instance_status_entry(name, instance, role_ref, role_def)
  management = validate_instance_management!(name, instance)
  transport = normalize_instance_transport(name, instance)
  binding_status = instance_binding_status(transport)
  {
    "instance" => name,
    "role_ref" => role_ref,
    "resolved_role" => role_def["role"] || role_ref,
    "management" => management,
    "expected_command" => command_expected_string(instance["command"]),
    "transport" => transport,
    "binding_status" => binding_status,
    "recommended_action" => recommended_instance_action(management, binding_status)
  }
end

def load_project_instance_config_for_cli
  config_dir = File.join(Dir.pwd, ".orbit")
  roles_config = load_yaml(File.join(config_dir, "roles.yaml"))
  instances_config = load_yaml(File.join(config_dir, "instances.yaml"))
  roles = roles_config["roles"]
  instances = instances_config["instances"]
  usage_error(".orbit/roles.yaml must contain a roles mapping.") unless roles.is_a?(Hash)
  usage_error(".orbit/instances.yaml must contain an instances mapping.") unless instances.is_a?(Hash)

  [roles, instances, File.join(config_dir, "instances.yaml"), instances_config]
end

def parse_instances_args(args)
  subcommand = args.shift
  usage_error("Missing instances subcommand.") unless subcommand
  usage_error("Unknown instances subcommand: #{subcommand}") unless subcommand == "status"

  json = false
  until args.empty?
    arg = args.shift
    case arg
    when "--json"
      json = true
    else
      usage_error("Unknown instances #{subcommand} option: #{arg}")
    end
  end

  usage_error("instances status currently requires --json") unless json
  { "subcommand" => subcommand, "json" => json }
end

def instances_status_result
  roles, instances = load_project_instance_config_for_cli[0, 2]
  entries = instances.map do |name, instance|
    usage_error("Instance #{name.inspect} must be a mapping.") unless instance.is_a?(Hash)
    role_ref = instance["role_ref"]
    usage_error("Instance #{name.inspect} must define role_ref.") unless role_ref.is_a?(String) && !role_ref.empty?
    role_def = roles[role_ref]
    usage_error("Instance #{name.inspect} references missing role #{role_ref.inspect}.") unless role_def.is_a?(Hash)

    instance_status_entry(name, instance, role_ref, role_def)
  end

  {
    "schema_version" => "orbit-instances-status-v1",
    "project" => File.basename(Dir.pwd),
    "instances" => entries
  }
end

def instances(args)
  options = parse_instances_args(args)
  case options["subcommand"]
  when "status"
    puts JSON.pretty_generate(instances_status_result)
  else
    usage_error("Unknown instances subcommand: #{options["subcommand"]}")
  end
end

def parse_bind_pane_args(args)
  options = {
    "transport" => "herdr",
    "json" => false
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--instance"
      options["instance"] = option_value(args, "--instance")
    when /\A--instance=(.+)\z/
      options["instance"] = Regexp.last_match(1)
    when "--pane"
      options["pane"] = option_value(args, "--pane")
    when /\A--pane=(.+)\z/
      options["pane"] = Regexp.last_match(1)
    when "--transport"
      options["transport"] = option_value(args, "--transport")
    when /\A--transport=(.+)\z/
      options["transport"] = Regexp.last_match(1)
    when "--tab"
      options["tab"] = option_value(args, "--tab")
    when /\A--tab=(.+)\z/
      options["tab"] = Regexp.last_match(1)
    when "--space"
      options["space"] = option_value(args, "--space")
    when /\A--space=(.+)\z/
      options["space"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown bind-pane option: #{arg}")
    end
  end

  usage_error("Missing required option: --instance") if options["instance"].to_s.empty?
  usage_error("Missing required option: --pane") if options["pane"].to_s.empty?
  usage_error("bind-pane currently requires --json") unless options["json"]
  usage_error("bind-pane --transport must be one of #{ALLOWED_INSTANCE_TRANSPORTS.join("|")}") unless ALLOWED_INSTANCE_TRANSPORTS.include?(options["transport"])
  options
end

def bind_pane(args)
  options = parse_bind_pane_args(args)
  roles, _instances, instances_path = load_project_instance_config_for_cli
  instance_key = nil
  instance_alias = nil
  instance = nil
  role_ref = nil
  role_def = nil

  update_yaml_file_atomically(instances_path) do |instances_config|
    instances = instances_config["instances"]
    usage_error(".orbit/instances.yaml must contain an instances mapping.") unless instances.is_a?(Hash)
    instance_key, instance_alias = find_instance(instances, roles, options["instance"])
    usage_error("Unknown Orbit instance #{options["instance"].inspect}.") unless instance_key

    instance = instances[instance_key]
    usage_error("Instance #{instance_key.inspect} must be a mapping.") unless instance.is_a?(Hash)

    role_ref = instance["role_ref"]
    role_def = roles[role_ref]
    usage_error("Instance #{instance_key.inspect} references missing role #{role_ref.inspect}.") unless role_def.is_a?(Hash)
    validate_instance_management!(instance_key, instance)

    transport = normalize_instance_transport(instance_key, instance)
    transport["kind"] = options["transport"]
    transport["binding"]["pane"] = options["pane"]
    transport["binding"]["tab"] = options["tab"].to_s
    transport["binding"]["space"] = options["space"].to_s
    transport["health"]["last_heartbeat"] = Time.now.utc.iso8601
    transport["health"]["cwd"] = Dir.pwd
    transport["health"]["actual_client"] = runtime_actual_client

    instance["transport"] = transport
    instances_config
  end

  entry = instance_status_entry(instance_key, instance, role_ref, role_def)
  puts JSON.pretty_generate({
    "schema_version" => "orbit-bind-pane-v1",
    "project" => File.basename(Dir.pwd),
    "instance" => instance_key,
    "requested_instance" => options["instance"],
    "instance_alias" => instance_alias,
    "status" => entry
  }.compact)
end

def write_instance_binding!(instance_name, transport_kind:, pane:, tab: "", space: "", actual_client: nil)
  roles, _instances, instances_path = load_project_instance_config_for_cli
  instance_key = nil
  instance = nil
  role_ref = nil
  role_def = nil

  update_yaml_file_atomically(instances_path) do |instances_config|
    instances = instances_config["instances"]
    usage_error(".orbit/instances.yaml must contain an instances mapping.") unless instances.is_a?(Hash)
    instance_key, = find_instance(instances, roles, instance_name)
    usage_error("Unknown Orbit instance #{instance_name.inspect}.") unless instance_key
    instance = instances[instance_key]
    role_ref = instance["role_ref"]
    role_def = roles[role_ref]
    usage_error("Instance #{instance_key.inspect} references missing role #{role_ref.inspect}.") unless role_def.is_a?(Hash)

    transport = normalize_instance_transport(instance_key, instance)
    transport["kind"] = transport_kind
    transport["binding"]["pane"] = pane.to_s
    transport["binding"]["tab"] = tab.to_s
    transport["binding"]["space"] = space.to_s
    transport["health"]["last_heartbeat"] = Time.now.utc.iso8601
    transport["health"]["cwd"] = Dir.pwd
    transport["health"]["actual_client"] = actual_client.to_s.empty? ? runtime_actual_client : actual_client.to_s
    instance["transport"] = transport
    instances_config
  end

  instance_status_entry(instance_key, instance, role_ref, role_def)
end

def parse_whoami_args(args)
  json = false
  task_path = nil

  until args.empty?
    arg = args.shift

    case arg
    when "--json"
      json = true
    when "--task"
      task_path = option_value(args, "--task")
    when /\A--task=(.+)\z/
      task_path = Regexp.last_match(1)
    else
      usage_error("Unknown whoami option: #{arg}")
    end
  end

  usage_error("whoami currently requires --json") unless json

  task_path
end

def load_project_config(result)
  config_dir = File.join(Dir.pwd, ".orbit")
  roles_path = File.join(config_dir, "roles.yaml")
  instances_path = File.join(config_dir, "instances.yaml")

  roles_config = load_yaml(roles_path)
  instances_config = load_yaml(instances_path)

  roles = roles_config["roles"]
  instances = instances_config["instances"]

  unless roles.is_a?(Hash)
    conflict(result, "project_config.roles", ".orbit/roles.yaml must contain a roles mapping.")
    roles = {}
  end

  unless instances.is_a?(Hash)
    conflict(result, "project_config.instances", ".orbit/instances.yaml must contain an instances mapping.")
    instances = {}
  end

  [roles, instances]
rescue RuntimeError => e
  conflict(result, "project_config", e.message)
  [{}, {}]
end

def load_task(result, task_path)
  return nil unless task_path

  task = load_yaml(task_path)
  unless task.is_a?(Hash)
    conflict(result, "task_file", "Task file must contain a mapping.")
    return nil
  end

  task
rescue RuntimeError => e
  conflict(result, "task_file", e.message)
  nil
end

def resolve_identity(result, roles, instances)
  env_instance = ENV["ORBIT_INSTANCE"]
  env_role = ENV["ORBIT_ROLE"]

  result["role_sources"]["env.ORBIT_INSTANCE"] = env_instance if env_instance && !env_instance.empty?
  result["role_sources"]["env.ORBIT_ROLE"] = env_role if env_role && !env_role.empty?

  instance_key = nil
  instance_alias = nil

  if env_instance && !env_instance.empty?
    instance_key, instance_alias = find_instance(instances, roles, env_instance)
    unless instance_key
      conflict(result, "env.ORBIT_INSTANCE", "Unknown ORBIT_INSTANCE #{env_instance.inspect}; run `orbit init` or add the instance to .orbit/instances.yaml.")
      return nil
    end
  elsif env_role && !env_role.empty?
    instance_key = infer_instance_from_role(instances, roles, env_role)
    unless instance_key
      conflict(result, "env.ORBIT_ROLE", "Could not infer a unique instance for ORBIT_ROLE #{env_role.inspect}; set ORBIT_INSTANCE.")
      return nil
    end
  else
    conflict(result, "runtime_identity", "Missing runtime identity; set ORBIT_INSTANCE or ORBIT_ROLE.")
    return nil
  end

  instance = instances[instance_key]
  unless instance.is_a?(Hash)
    conflict(result, "project_config.instances.#{instance_key}", "Instance must be a mapping.")
    return nil
  end

  role_ref = instance["role_ref"]
  result["instance"] = env_instance && !env_instance.empty? ? env_instance : instance_key
  result["resolved_instance"] = instance_key
  result["role_sources"]["project_config.instance_alias"] = instance_alias if instance_alias
  result["role_sources"]["project_config.instances.#{instance_key}.role_ref"] = role_ref if role_ref

  role_def = roles[role_ref]
  unless role_def.is_a?(Hash)
    conflict(result, "project_config.roles.#{role_ref}", "Instance #{instance_key.inspect} references missing role #{role_ref.inspect}.")
    return nil
  end

  resolved_role = role_def["role"] || role_ref
  result["resolved_role"] = resolved_role
  result["role_ref"] = role_ref
  result["role_sources"]["project_config.roles.#{role_ref}.role"] = resolved_role

  management = instance_management(instance)
  if ALLOWED_INSTANCE_MANAGEMENT.include?(management)
    transport = normalize_instance_transport(instance_key, instance)
    result["management"] = management
    expected_client = expected_client_name(instance["command"])
    actual_client = runtime_actual_client
    result["expected_command"] = command_expected_string(instance["command"])
    result["actual_client"] = actual_client
    result["transport_binding"] = transport["binding"]
    result["binding_status"] = instance_binding_status(transport)
    if actual_client != "unknown" && expected_client && actual_client != expected_client
      conflict(result, "env.ORBIT_CLIENT", "ORBIT_CLIENT #{actual_client.inspect} conflicts with configured command #{expected_client.inspect} for instance #{instance_key.inspect}.")
    end
  else
    conflict(result, "project_config.instances.#{instance_key}.management", "Instance management must be one of #{ALLOWED_INSTANCE_MANAGEMENT.join("|")}.")
  end

  if env_role && !env_role.empty? && env_role != resolved_role
    conflict(result, "env.ORBIT_ROLE", "ORBIT_ROLE #{env_role.inspect} conflicts with config role #{resolved_role.inspect}.")
  end

  role_def
end

def apply_task_constraints(result, task)
  return unless task

  result["project"] = task["project"] if task["project"]

  target_role = task["target_role"]
  result["role_sources"]["task_file.target_role"] = target_role if target_role

  return unless target_role && result["resolved_role"] && target_role != result["resolved_role"]
  return if task_gate_role?(task, result["resolved_role"])

  conflict(result, "task_file.target_role", "Task target_role #{target_role.inspect} does not match resolved_role #{result["resolved_role"].inspect}.")
end

SAFE_COMMAND_TOKEN_PATTERN = /\A[A-Za-z0-9_+@%.,:\/=-]+\z/.freeze

def command_config_error(command, source)
  case command
  when String
    value = command.strip
    return "#{source} command must be non-empty." if value.empty?
    return "#{source} command string must be a single executable token; use a list for arguments." if value.match?(/\s/)
    return "#{source} command string contains shell metacharacters; use a safe executable token or argv list." unless value.match?(SAFE_COMMAND_TOKEN_PATTERN)

    nil
  when Array
    return "#{source} command list must not be empty." if command.empty?

    command.each_with_index do |part, index|
      return "#{source} command[#{index}] must be a non-empty string." unless part.is_a?(String) && !part.strip.empty?
    end

    nil
  else
    "#{source} command must be a string or a list of strings."
  end
end

def normalize_command_argv(command, source)
  error = command_config_error(command, source)
  usage_error(error) if error

  command.is_a?(Array) ? command : [command.strip]
end

def instance_launch_env(instance_name, instance, role_def, role_ref)
  env = instance["env"]
  usage_error("Instance #{instance_name.inspect} env must be a mapping when present.") unless env.nil? || env.is_a?(Hash)

  resolved_role = role_def["role"] || role_ref
  {
    "ORBIT_INSTANCE" => instance_name,
    "ORBIT_ROLE" => resolved_role
  }.merge((env || {}).transform_keys(&:to_s).transform_values(&:to_s))
end

def load_instance_for_launch(instance_name)
  config_dir = File.join(Dir.pwd, ".orbit")
  roles_config = load_yaml(File.join(config_dir, "roles.yaml"))
  instances_config = load_yaml(File.join(config_dir, "instances.yaml"))
  roles = roles_config["roles"]
  instances = instances_config["instances"]
  usage_error(".orbit/roles.yaml must contain a roles mapping.") unless roles.is_a?(Hash)
  usage_error(".orbit/instances.yaml must contain an instances mapping.") unless instances.is_a?(Hash)

  instance_key, instance_alias = find_instance(instances, roles, instance_name)
  usage_error("Unknown Orbit instance #{instance_name.inspect}.") unless instance_key

  instance = instances[instance_key]
  usage_error("Instance #{instance_key.inspect} must be a mapping.") unless instance.is_a?(Hash)

  role_ref = instance["role_ref"]
  usage_error("Instance #{instance_key.inspect} must define role_ref.") unless role_ref.is_a?(String) && !role_ref.empty?

  role_def = roles[role_ref]
  usage_error("Instance #{instance_key.inspect} references missing role #{role_ref.inspect}.") unless role_def.is_a?(Hash)
  validate_instance_management!(instance_key, instance)
  normalize_instance_transport(instance_key, instance)

  [instance_key, instance_alias, instance, role_ref, role_def]
end


require_relative "identity_rules_context"

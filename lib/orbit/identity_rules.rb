# frozen_string_literal: true

def init_config(args)
  force = false
  operation_mode = nil

  until args.empty?
    arg = args.shift
    case arg
    when "--force"
      force = true
    when "--operation-mode"
      operation_mode = option_value(args, "--operation-mode")
    when /\A--operation-mode=(.+)\z/
      operation_mode = Regexp.last_match(1)
    else
      usage_error("Unknown init option: #{arg}")
    end
  end
  operation_mode = operation_mode.to_s.strip
  if operation_mode.empty?
    if $stdin.tty? && $stdout.tty?
      puts "Choose Orbit operation mode:"
      puts "1. solo - lead owns and implements tasks"
      puts "2. team - lead owns tasks; coder implements"
      print "Operation mode [solo/team]: "
      answer = $stdin.gets.to_s.strip.downcase
      operation_mode = case answer
                       when "1", "solo" then "solo"
                       when "2", "team" then "team"
                       else
                         usage_error("Invalid operation mode: #{answer.inspect}. Use solo or team.")
                       end
    else
      usage_error("orbit init requires --operation-mode solo|team when not running interactively.")
    end
  end
  usage_error("orbit init --operation-mode must be solo or team.") unless %w[solo team].include?(operation_mode)

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
    elsif name == "roles.yaml"
      roles_config = load_yaml(template_path)
      roles_config["operation_defaults"] = operation_defaults_for_mode(operation_mode)
      if operation_mode == "team"
        roles_config["capability_registry"] ||= {}
        roles_config["capability_registry"]["code.implement"] ||= {
          "kind" => "agent_action",
          "description" => "实施 production code changes for team-mode tasks."
        }
        roles_config["roles"] ||= {}
        roles_config["roles"]["coder"] ||= {
          "role" => "coder",
          "capabilities" => ["code.edit", "code.implement"],
          "rules" => [],
          "permissions" => {
            "can_edit_production_code" => true
          }
        }
      end
      write_file_atomically(target_path, YAML.dump(roles_config))
    elsif name == "instances.yaml"
      instances_config = load_yaml(template_path)
      if operation_mode == "team"
        instances_config["instances"] ||= {}
        instances_config["instances"]["coder-main"] ||= default_instance_config("coder", "coder-main")
      end
      write_file_atomically(target_path, YAML.dump(instances_config))
    else
      write_file_atomically(target_path, File.read(template_path))
    end
  end

  puts "Initialized Orbit config:"
  files.keys.each { |name| puts "- .orbit/#{name}" }
  puts
  puts "Next:"
  puts "- ORBIT_INSTANCE=#{operation_mode == "team" ? "coder-main" : "lead-main"} orbit whoami --json"
end

def operation_defaults_for_mode(operation_mode)
  case operation_mode
  when "team"
    {
      "owner_role" => "lead",
      "owner_instance" => "lead-main",
      "operation_mode" => "team",
      "implementation_authority" => "coder",
      "assigned_instance" => "coder-main"
    }
  else
    {
      "owner_role" => "lead",
      "owner_instance" => "lead-main",
      "operation_mode" => "solo",
      "implementation_authority" => "lead",
      "assigned_instance" => "lead-main"
    }
  end
end

def default_instance_config(role_ref, instance_key)
  {
    "role_ref" => role_ref,
    "command" => "codex",
    "management" => "user_managed",
    "binding" => {
      "adapter" => "herdr",
      "workspace" => "",
      "tab" => "",
      "pane" => "",
      "canonical_pane" => ""
    },
    "view" => {
      "min_columns" => 120,
      "min_rows" => 36
    },
    "env" => {
      "ORBIT_INSTANCE" => instance_key,
      "ORBIT_ROLE" => role_ref
    }
  }
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

def find_instance(instances, _roles, instance_name)
  return [nil, nil] unless instance_name
  return [instance_name, nil] if instances.key?(instance_name)

  [nil, nil]
end

def role_for_instance_config(instances, roles, instance_key)
  return nil unless instances.is_a?(Hash) && roles.is_a?(Hash)

  resolved_key, = find_instance(instances, roles, instance_key.to_s)
  instance = resolved_key ? instances[resolved_key] : nil
  return nil unless instance.is_a?(Hash)

  role_ref = instance["role_ref"]
  return nil unless role_ref.is_a?(String) && !role_ref.empty?

  role_def = roles[role_ref]
  return nil unless role_def.is_a?(Hash)

  role_def["role"] || role_ref
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

def instance_management(instance)
  value = instance["management"].to_s.strip
  value.empty? ? "user_managed" : value
end

def validate_instance_management!(instance_name, instance)
  management = instance_management(instance)
  usage_error("Instance #{instance_name.inspect} management must be one of #{ALLOWED_INSTANCE_MANAGEMENT.join("|")}.") unless ALLOWED_INSTANCE_MANAGEMENT.include?(management)
  management
end

def normalize_instance_binding(instance_name, instance)
  binding = instance["binding"]
  usage_error("Instance #{instance_name.inspect} binding must be present with adapter herdr.") if binding.nil?
  usage_error("Instance #{instance_name.inspect} binding must be a mapping when present.") unless binding.is_a?(Hash)
  usage_error("Instance #{instance_name.inspect} view must be a sibling of binding, not binding.view.") if binding.key?("view")

  adapter = binding["adapter"].to_s.strip
  usage_error("Instance #{instance_name.inspect} binding.adapter must be herdr.") unless adapter == "herdr"

  pane = binding["pane"].to_s
  canonical_pane = binding["canonical_pane"].to_s
  canonical_pane = pane if canonical_pane.empty?
  {
    "adapter" => adapter,
    "workspace" => binding["workspace"].to_s,
    "tab" => binding["tab"].to_s,
    "pane" => pane,
    "canonical_pane" => canonical_pane
  }
end

def normalize_instance_view(instance_name, instance)
  view = instance["view"] || {}
  usage_error("Instance #{instance_name.inspect} view must be a mapping when present.") unless view.is_a?(Hash)
  usage_error("Instance #{instance_name.inspect} view.min_cols was removed; use view.min_columns.") if view.key?("min_cols")
  min_columns = view["min_columns"] || 120
  min_rows = view["min_rows"] || 36
  min_columns = min_columns.to_i
  min_rows = min_rows.to_i
  usage_error("Instance #{instance_name.inspect} view.min_columns must be positive.") unless min_columns.positive?
  usage_error("Instance #{instance_name.inspect} view.min_rows must be positive.") unless min_rows.positive?
  {
    "min_columns" => min_columns,
    "min_rows" => min_rows
  }
end

def binding_present?(binding)
  %w[pane canonical_pane].any? { |field| !binding[field].to_s.empty? }
end

def instance_binding_state(binding)
  binding_present?(binding) ? "bound" : "unbound"
end

def instance_liveness_for_binding(binding)
  return ["not_alive", "no_binding"] unless binding_present?(binding)

  ["unknown", "unverified_binding"]
end

def instance_availability_for_liveness(liveness)
  case liveness
  when "alive"
    "available"
  when "not_alive"
    "missing"
  else
    "unknown"
  end
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

def view_observed_geometry_from_entry(entry)
  return nil unless entry.is_a?(Hash)

  cols = entry["cols"] || entry["columns"] || entry["width"] || entry.dig("geometry", "cols") || entry.dig("geometry", "columns") || entry.dig("geometry", "width")
  rows = entry["rows"] || entry["height"] || entry.dig("geometry", "rows") || entry.dig("geometry", "height")
  cols = cols.to_i
  rows = rows.to_i
  return nil unless cols.positive? && rows.positive?

  {
    "cols" => cols,
    "rows" => rows
  }
end

def observed_herdr_geometry(binding)
  return nil unless binding.is_a?(Hash) && binding["adapter"] == "herdr"

  pane_ids = [binding["canonical_pane"], binding["pane"]].map(&:to_s).reject(&:empty?)
  return nil if pane_ids.empty?

  herdr_path = command_path("herdr")
  return nil unless herdr_path

  stdout, _stderr, status = Open3.capture3(herdr_path, "agent", "list")
  return nil unless status.success?

  parsed = JSON.parse(stdout)
  agents = parsed.dig("result", "agents") || parsed["agents"] || []
  entry = agents.find { |candidate| candidate.is_a?(Hash) && pane_ids.include?(candidate["pane_id"].to_s) }
  view_observed_geometry_from_entry(entry)
rescue JSON::ParserError
  nil
end

def instance_view_status(view, binding)
  observed = observed_herdr_geometry(binding)
  too_narrow = nil
  remediation = nil
  if observed
    too_narrow = observed["cols"].to_i < view["min_columns"].to_i ||
                 observed["rows"].to_i < view["min_rows"].to_i
    remediation = "resize_or_recreate_view" if too_narrow
  end
  {
    "policy" => view,
    "observed_geometry" => observed,
    "too_narrow" => too_narrow,
    "remediation" => remediation
  }
end

def instance_status_entry(name, instance, role_ref, role_def)
  management = validate_instance_management!(name, instance)
  binding = normalize_instance_binding(name, instance)
  view = normalize_instance_view(name, instance)
  binding_state = instance_binding_state(binding)
  liveness, liveness_reason = instance_liveness_for_binding(binding)
  view_status = instance_view_status(view, binding)
  runtime_resolution = runtime_resolve_instance(name)
  entry = {
    "instance" => name,
    "role_ref" => role_ref,
    "resolved_role" => role_def["role"] || role_ref,
    "management" => management,
    "expected_command" => command_expected_string(instance["command"]),
    "binding" => binding_state,
    "liveness" => liveness,
    "liveness_reason" => liveness_reason,
    "availability" => instance_availability_for_liveness(liveness),
    "identity_verification" => runtime_resolution["identity_verification"],
    "dispatch_ready" => runtime_resolution["dispatch_ready"],
    "canonical_pane" => runtime_resolution["canonical_pane"],
    "runtime_resolution" => runtime_resolution.reject { |key, _| %w[runtime_instance runtime_session].include?(key) },
    "herdr" => binding,
    "view" => view,
    "view_status" => view_status
  }
  if runtime_resolution["binding_resolution"] == "repaired"
    entry["config_write"] = "not_written"
    entry["repair_binding_command"] = ["orbit", "instances", "status", "--repair-binding", "--json"]
    entry["diagnostics"] = [
      "Stored Herdr binding is stale or missing. Runtime session is verified; pass --repair-binding to update .orbit/instances.yaml."
    ]
  end
  entry
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
  repair_binding = false
  until args.empty?
    arg = args.shift
    case arg
    when "--json"
      json = true
    when "--repair-binding"
      repair_binding = true
    else
      usage_error("Unknown instances #{subcommand} option: #{arg}")
    end
  end

  usage_error("instances status currently requires --json") unless json
  { "subcommand" => subcommand, "json" => json, "repair_binding" => repair_binding }
end

def repair_instance_binding_from_runtime!(instance_name)
  resolution = runtime_resolve_instance(instance_name)
  return nil unless resolution["binding_resolution"] == "repaired"
  return nil unless resolution["identity_verification"] == "verified"
  return nil unless resolution["herdr_liveness"] == "alive"

  session = resolution["runtime_session"]
  herdr = session.is_a?(Hash) ? (session["herdr"] || {}) : {}
  canonical = herdr["canonical_pane"].to_s
  canonical = resolution["canonical_pane"].to_s if canonical.empty?
  return nil if canonical.empty?

  write_instance_binding!(
    instance_name,
    pane: canonical,
    tab: herdr["tab"].to_s,
    workspace: herdr["workspace"].to_s,
    canonical_pane: canonical
  )
  {
    "instance" => instance_name,
    "session_id" => resolution["session_id"],
    "canonical_pane" => canonical,
    "config_write" => "written"
  }
end

def instances_status_result(repair_binding: false)
  roles, instances = load_project_instance_config_for_cli[0, 2]
  repairs = []
  if repair_binding
    instances.keys.each do |name|
      repair = repair_instance_binding_from_runtime!(name)
      repairs << repair if repair
    end
    roles, instances = load_project_instance_config_for_cli[0, 2]
  end
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
    "config_write" => repair_binding ? "requested" : "not_written",
    "config_repairs" => repairs,
    "instances" => entries
  }
end

def instances(args)
  options = parse_instances_args(args)
  case options["subcommand"]
  when "status"
    puts JSON.pretty_generate(instances_status_result(repair_binding: options["repair_binding"]))
  else
    usage_error("Unknown instances subcommand: #{options["subcommand"]}")
  end
end

def parse_bind_pane_args(args)
  options = {
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
    when "--tab"
      options["tab"] = option_value(args, "--tab")
    when /\A--tab=(.+)\z/
      options["tab"] = Regexp.last_match(1)
    when "--workspace"
      options["workspace"] = option_value(args, "--workspace")
    when /\A--workspace=(.+)\z/
      options["workspace"] = Regexp.last_match(1)
    when "--canonical-pane"
      options["canonical_pane"] = option_value(args, "--canonical-pane")
    when /\A--canonical-pane=(.+)\z/
      options["canonical_pane"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown bind-pane option: #{arg}")
    end
  end

  usage_error("Missing required option: --instance") if options["instance"].to_s.empty?
  usage_error("Missing required option: --pane") if options["pane"].to_s.empty?
  usage_error("bind-pane currently requires --json") unless options["json"]
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

    normalize_instance_binding(instance_key, instance)
    instance["binding"] = {
      "adapter" => "herdr",
      "workspace" => options["workspace"].to_s,
      "tab" => options["tab"].to_s,
      "pane" => options["pane"].to_s,
      "canonical_pane" => options["canonical_pane"].to_s.empty? ? options["pane"].to_s : options["canonical_pane"].to_s
    }
    instances_config
  end

  entry = instance_status_entry(instance_key, instance, role_ref, role_def)
  entry["identity_verification"] = "absent"
  entry["dispatch_ready"] = false
  entry["runtime_resolution"] = {
    "identity_verification" => "absent",
    "dispatch_ready" => false,
    "binding_resolution" => "manual_hint",
    "reason" => "bind-pane writes a manual Herdr hint only; Herdr verified runtime is unavailable until trusted caller-pane proof exists."
  }
  puts JSON.pretty_generate({
    "schema_version" => "orbit-bind-pane-v1",
    "project" => File.basename(Dir.pwd),
    "instance" => instance_key,
    "requested_instance" => options["instance"],
    "instance_alias" => instance_alias,
    "status" => entry,
    "identity_verification" => "absent",
    "dispatch_ready" => false,
    "next" => [
      "Herdr verified runtime is unavailable until trusted caller-pane proof exists; use manual dispatch when needed."
    ]
  }.compact)
end

def write_instance_binding!(instance_name, adapter: "herdr", pane:, tab: "", workspace: "", canonical_pane: nil, actual_client: nil)
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

    normalize_instance_binding(instance_key, instance)
    usage_error("Instance binding adapter must be herdr.") unless adapter == "herdr"
    instance["binding"] = {
      "adapter" => "herdr",
      "workspace" => workspace.to_s,
      "tab" => tab.to_s,
      "pane" => pane.to_s,
      "canonical_pane" => canonical_pane.to_s.empty? ? pane.to_s : canonical_pane.to_s
    }
    instances_config
  end

  instance_status_entry(instance_key, instance, role_ref, role_def)
end

def parse_whoami_args(args)
  json = false
  task_path = nil
  evidence_path = nil

  until args.empty?
    arg = args.shift

    case arg
    when "--json"
      json = true
    when "--task"
      task_path = option_value(args, "--task")
    when /\A--task=(.+)\z/
      task_path = Regexp.last_match(1)
    when "--evidence"
      evidence_path = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      evidence_path = Regexp.last_match(1)
    else
      usage_error("Unknown whoami option: #{arg}")
    end
  end

  usage_error("whoami currently requires --json") unless json

  { "task" => task_path, "evidence" => evidence_path }
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

  task["__orbit_path"] = File.expand_path(task_path)
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
    binding = normalize_instance_binding(instance_key, instance)
    result["management"] = management
    expected_client = expected_client_name(instance["command"])
    actual_client = runtime_actual_client
    result["expected_command"] = command_expected_string(instance["command"])
    result["actual_client"] = actual_client
    result["binding"] = instance_binding_state(binding)
    result["herdr"] = binding
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

def apply_task_constraints(result, task, evidence = nil)
  return unless task

  result["project"] = task["project"] if task["project"]

  contract = task["execution_contract"]
  unless contract.is_a?(Hash)
    conflict(result, "task_file.execution_contract", "Task must define execution_contract; recreate the task with orbit new-task.")
    return
  end

  required = %w[owner_role owner_instance operation_mode implementation_authority assigned_instance source]
  missing = required.select { |field| contract[field].to_s.empty? }
  unless missing.empty?
    conflict(result, "task_file.execution_contract", "Task execution_contract missing required fields: #{missing.join(", ")}.")
    return
  end

  result["execution_contract"] = contract.slice(
    "owner_role",
    "owner_instance",
    "operation_mode",
    "implementation_authority",
    "assigned_instance",
    "source"
  )

  resolved_role = result["resolved_role"]
  resolved_instance = result["resolved_instance"]
  return unless resolved_role && resolved_instance

  if task_gate_role?(task, resolved_role)
    result["execution_context"] = {
      "allowed" => true,
      "mode" => "gate",
      "reason" => "resolved_role is listed on a task gate"
    }
    return
  end

  if resolved_role == contract["implementation_authority"]
    if resolved_instance == contract["assigned_instance"]
      result["execution_context"] = {
        "allowed" => true,
        "mode" => "implementation",
        "reason" => "resolved instance matches execution_contract.assigned_instance"
      }
    elsif (override = valid_implementation_override_for_identity(task, evidence, resolved_role, resolved_instance))
      result["execution_context"] = {
        "allowed" => true,
        "mode" => "implementation_override",
        "reason" => "valid implementation_instance_override evidence authorizes this instance",
        "override" => override
      }
    else
      result["execution_context"] = {
        "allowed" => false,
        "mode" => "implementation",
        "reason" => "resolved instance does not match execution_contract.assigned_instance"
      }
      conflict(result, "task_file.execution_contract.assigned_instance", "Task assigned_instance #{contract["assigned_instance"].inspect} does not match resolved_instance #{resolved_instance.inspect}.")
    end
    return
  end

  if resolved_role == contract["owner_role"] && resolved_instance == contract["owner_instance"]
    result["execution_context"] = {
      "allowed" => true,
      "mode" => "owner",
      "reason" => "resolved identity matches execution_contract owner"
    }
    return
  end

  result["execution_context"] = {
    "allowed" => false,
    "mode" => "unauthorized",
    "reason" => "resolved role is not implementation_authority, owner_role, or gate role"
  }
  conflict(result, "task_file.execution_contract.implementation_authority", "Task implementation_authority #{contract["implementation_authority"].inspect} does not match resolved_role #{resolved_role.inspect}.")
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
  normalize_instance_binding(instance_key, instance)

  [instance_key, instance_alias, instance, role_ref, role_def]
end


require_relative "identity_rules_context"

def parse_start_args(args)
  instance = args.shift
  usage_error("Missing start instance.") if instance.nil? || instance.start_with?("--")

  options = {
    "instance" => instance,
    "adapter" => "herdr",
    "cwd" => Dir.pwd,
    "force" => false,
    "dry_run" => false,
    "json" => false,
    "layout" => "auto",
    "min_cols" => nil,
    "min_rows" => nil
  }

  until args.empty?
    arg = args.shift
    case arg
    when "--cwd"
      options["cwd"] = option_value(args, "--cwd")
    when /\A--cwd=(.+)\z/
      options["cwd"] = Regexp.last_match(1)
    when "--dry-run"
      options["dry_run"] = true
    when "--layout"
      options["layout"] = option_value(args, "--layout")
    when /\A--layout=(.+)\z/
      options["layout"] = Regexp.last_match(1)
    when "--min-cols"
      options["min_cols"] = option_value(args, "--min-cols").to_i
    when /\A--min-cols=(.+)\z/
      options["min_cols"] = Regexp.last_match(1).to_i
    when "--min-rows"
      options["min_rows"] = option_value(args, "--min-rows").to_i
    when /\A--min-rows=(.+)\z/
      options["min_rows"] = Regexp.last_match(1).to_i
    when "--force"
      options["force"] = true
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown start option: #{arg}")
    end
  end

  usage_error("start --layout must be auto, same-tab, or new-tab") unless %w[auto same-tab new-tab].include?(options["layout"])
  usage_error("start --min-cols must be positive") unless options["min_cols"].nil? || options["min_cols"].positive?
  usage_error("start --min-rows must be positive") unless options["min_rows"].nil? || options["min_rows"].positive?
  options
end

def start_plan(options)
  instance_key, instance_alias, instance, role_ref, role_def = load_instance_for_launch(options["instance"])
  argv = normalize_command_argv(instance["command"], "Instance #{instance_key.inspect}")
  cwd = File.expand_path(options["cwd"])
  usage_error("Start cwd does not exist: #{cwd}") unless Dir.exist?(cwd)
  project_root = Dir.pwd
  if File.realpath(cwd) != File.realpath(project_root)
    usage_error("start --cwd must be the Orbit project root #{project_root.inspect}; start from the target project root instead of launching agents in a subdirectory or another checkout.")
  end
  status = instance_status_entry(instance_key, instance, role_ref, role_def)
  view_policy = normalize_instance_view(instance_key, instance)
  options = options.merge(
    "min_cols" => options["min_cols"] || view_policy["min_columns"],
    "min_rows" => options["min_rows"] || view_policy["min_rows"],
    "view_policy" => view_policy,
    "resolved_role" => role_def["role"] || role_ref
  )
  creation_policy = role_creation_policy(options)
  session_id = "ors_#{SecureRandom.hex(12)}"
  launch_id = "orl_#{SecureRandom.hex(12)}"
  launch_env = instance_launch_env(instance_key, instance, role_def, role_ref).merge(
    "ORBIT_PROJECT_ROOT" => cwd,
    "ORBIT_PROJECT_ID" => File.basename(Dir.pwd),
    "ORBIT_SESSION_ID" => session_id,
    "ORBIT_LAUNCH_ID" => launch_id
  )

  context_preflight = context_preflight_for(instance_key)
  assert_context_preflight_ready!(context_preflight, "start")

  {
    "schema_version" => "orbit-start-plan-v1",
    "adapter" => "herdr",
    "runtime_capabilities" => runtime_capability_profile(herdr_available: !command_path("herdr").nil?),
    "project" => File.basename(Dir.pwd),
    "instance" => instance_key,
    "requested_instance" => options["instance"],
    "instance_alias" => instance_alias,
    "role_ref" => role_ref,
    "resolved_role" => role_def["role"] || role_ref,
    "session_id" => session_id,
    "launch_id" => launch_id,
    "cwd" => cwd,
    "argv" => argv,
    "client" => start_client_metadata(argv),
    "env" => launch_env,
    "context_preflight" => context_preflight,
    "instance_status" => status,
    "view" => view_policy,
    "creation_policy" => creation_policy,
    "layout" => creation_policy["layout"],
    "force" => options["force"],
    "dry_run" => options["dry_run"]
  }.compact
end

def context_preflight_for(instance_key, task_path: nil)
  options = { "instance" => instance_key }
  options["task"] = task_path if task_path
  context = rules_context_pack(rule_resolution(options))
  rule_task_args = task_path ? ["--task", File.expand_path(task_path)] : []
  {
    "schema_version" => "orbit-context-preflight-v1",
    "instance" => instance_key,
    "resolved_role" => context["resolved_role"],
    "valid" => context["valid"],
    "conflicts" => context["conflicts"] || [],
    "warnings" => context["warnings"] || [],
    "required_files" => (context["required_files"] || []).map do |entry|
      {
        "source" => entry["source"],
        "category" => entry["category"],
        "rule_id" => entry["rule_id"],
        "path" => entry["path"],
        "absolute_path" => entry["absolute_path"],
        "load_policy" => entry["load_policy"],
        "reason" => entry["reason"]
      }.compact
    end,
    "commands" => [
      ["orbit", "whoami", "--json"],
      ["orbit", "rules", "resolve", *rule_task_args, "--instance", instance_key, "--json"],
      ["orbit", "rules", "print-context", *rule_task_args, "--instance", instance_key, "--json"]
    ],
    "next_actions" => context["next_actions"] || []
  }
rescue RuntimeError => e
  {
    "schema_version" => "orbit-context-preflight-v1",
    "instance" => instance_key,
    "valid" => false,
    "conflicts" => [{ "source" => "context_preflight", "message" => e.message }],
    "warnings" => [],
    "required_files" => [],
    "commands" => []
  }
end

def context_preflight_ready?(context)
  context.is_a?(Hash) && context["valid"] == true && Array(context["conflicts"]).empty?
end

def context_preflight_failure_summary(context)
  conflicts = Array(context && context["conflicts"]).map do |entry|
    next entry.to_s unless entry.is_a?(Hash)

    [entry["source"], entry["message"]].compact.join(": ")
  end.compact
  conflicts.reject!(&:empty?)
  return "context_preflight.valid=false" if conflicts.empty?

  conflicts.join("; ")
end

def assert_context_preflight_ready!(context, action)
  return if context_preflight_ready?(context)

  usage_error("Orbit #{action} blocked: context_preflight is invalid. Resolve rule conflicts first. #{context_preflight_failure_summary(context)}")
end

def non_empty_env(*names)
  names.each do |name|
    value = ENV[name].to_s.strip
    return value unless value.empty?
  end
  ""
end

def lead_herdr_binding
  roles, instances = load_project_instance_config_for_cli[0, 2]
  lead_key = find_instance(instances, roles, "lead").first || infer_instance_from_role(instances, roles, "lead")
  return {} unless lead_key && instances[lead_key].is_a?(Hash)

  normalize_instance_binding(lead_key, instances[lead_key])
rescue RuntimeError
  {}
end

def herdr_same_level_view
  lead_binding = lead_herdr_binding
  source_pane = non_empty_env("HERDR_PANE_ID")
  source_pane = lead_binding["pane"].to_s if source_pane.empty?

  tab = non_empty_env("HERDR_TAB_ID", "HERDR_TAB")
  tab = lead_binding["tab"].to_s if tab.empty?

  workspace = non_empty_env("HERDR_WORKSPACE_ID", "HERDR_WORKSPACE")
  workspace = lead_binding["workspace"].to_s if workspace.empty?

  strategy = if !tab.empty?
               "same_tab"
             elsif !workspace.empty?
               "same_workspace"
	             elsif !source_pane.empty?
	               "source_pane_recorded"
	             else
	               "default_view"
             end

  {
    "strategy" => strategy,
    "source_pane" => source_pane,
    "tab" => tab,
    "workspace" => workspace,
	    "source" => "HERDR_* env or lead Herdr binding",
	    "layout_context_incomplete" => strategy == "default_view" || strategy == "source_pane_recorded"
  }
end

def numeric_field(hash, *keys)
  keys.each do |key|
    value = hash[key] if hash.is_a?(Hash)
    return value.to_i if value.respond_to?(:to_i) && value.to_i.positive?
  end
  nil
end

def rect_dimensions(rect)
  return nil unless rect.is_a?(Hash)

  cols = numeric_field(rect, "cols", "columns", "width")
  rows = numeric_field(rect, "rows", "height")
  return nil unless cols && rows

  { "cols" => cols, "rows" => rows }
end

HUMAN_VIEW_ROLE_WEIGHTS = {
  "lead" => 4.0,
  "reviewer" => 2.0,
  "coder" => 2.0,
  "tester" => 1.0
}.freeze

def human_view_role_weight(role)
  HUMAN_VIEW_ROLE_WEIGHTS.fetch(role.to_s, 1.0)
end

def herdr_roles_by_pane(agents, source_pane: nil)
  roles, instances = load_project_instance_config_for_cli[0, 2]
  result = instances.each_with_object({}) do |(instance_key, instance), mapped|
    next unless instance.is_a?(Hash)

    pane = normalize_instance_binding(instance_key, instance)["pane"].to_s
    role = role_for_instance_config(instances, roles, instance_key)
    mapped[pane] = role unless pane.empty? || role.to_s.empty?
  end
  source_role = ENV["ORBIT_ROLE"].to_s.strip
  source_role = "lead" if source_role.empty?
  result[source_pane.to_s] ||= source_role unless source_pane.to_s.empty?
  Array(agents).each_with_object(result) do |entry, mapped|
    next unless entry.is_a?(Hash)

    pane = entry["pane_id"].to_s
    instance = entry["name"] || entry["label"] || entry["instance"]
    next if pane.empty? || instance.to_s.empty?

    mapped[pane] = role_for_instance_config(instances, roles, instance.to_s) || mapped[pane] || "other"
  end
rescue SystemExit, RuntimeError
  {}
end

def weighted_split_projection(size, direction, ratio)
  if direction == "right"
    retained_cols = (size["cols"] * ratio).round
    {
      "retained" => { "cols" => retained_cols, "rows" => size["rows"] },
      "new" => { "cols" => size["cols"] - retained_cols, "rows" => size["rows"] }
    }
  else
    retained_rows = (size["rows"] * ratio).round
    {
      "retained" => { "cols" => size["cols"], "rows" => retained_rows },
      "new" => { "cols" => size["cols"], "rows" => size["rows"] - retained_rows }
    }
  end
end

def weighted_same_tab_placement(panes, agents, new_role, minimum, source_pane: nil)
  roles_by_pane = herdr_roles_by_pane(agents, source_pane: source_pane)
  candidates = Array(panes).each_with_object([]) do |entry, collected|
    next unless entry.is_a?(Hash)

    pane = entry["pane_id"].to_s
    size = rect_dimensions(entry["rect"] || entry["area"] || entry)
    next if pane.empty? || size.nil?

    role = roles_by_pane[pane] || "other"
    collected << {
      "pane" => pane,
      "role" => role,
      "weight" => human_view_role_weight(role),
      "size" => size,
      "area" => size["cols"] * size["rows"]
    }
  end
  return nil if candidates.empty?

  new_weight = human_view_role_weight(new_role)
  highest_existing_weight = candidates.map { |entry| entry["weight"] }.max
  ordered = if new_weight > highest_existing_weight
              candidates.sort_by { |entry| [-entry["area"], entry["weight"], entry["pane"]] }
            else
              candidates.sort_by { |entry| [entry["weight"], -entry["area"], entry["pane"]] }
            end
  soft_minimum = {
    "cols" => [minimum["cols"].to_i / 2, 40].max,
    "rows" => [minimum["rows"].to_i / 2, 12].max
  }
  all_options = []
  ordered.each_with_index do |candidate, order_index|
    ratio = candidate["weight"] / (candidate["weight"] + new_weight)
    ratio = [[ratio, 0.20].max, 0.80].min
    options = %w[right down].map do |direction|
      projection = weighted_split_projection(candidate["size"], direction, ratio)
      dimensions = [projection["retained"], projection["new"]]
      fit = dimensions.map do |size|
        [size["cols"].to_f / soft_minimum["cols"], size["rows"].to_f / soft_minimum["rows"]].min
      end.min
      {
        "target_pane" => candidate["pane"],
        "target_role" => candidate["role"],
        "target_weight" => candidate["weight"],
        "new_role" => new_role,
        "new_weight" => new_weight,
        "direction" => direction,
        "ratio" => ratio.round(3),
        "target_size" => candidate["size"],
        "projected_target_size" => projection["retained"],
        "projected_new_size" => projection["new"],
        "soft_minimum" => soft_minimum,
        "readable" => fit >= 1.0,
        "fit_score" => fit,
        "candidate_order" => order_index
      }
    end
    readable = options.select { |entry| entry["readable"] }
    unless readable.empty?
      return readable.max_by do |entry|
        [entry["fit_score"], entry["projected_new_size"]["cols"] * entry["projected_new_size"]["rows"]]
      end
    end

    all_options.concat(options)
  end

  all_options.max_by do |entry|
    [-entry["candidate_order"], entry["fit_score"], entry["projected_new_size"]["cols"] * entry["projected_new_size"]["rows"]]
  end
end

def herdr_layout_probe(view, options)
  minimum = {
    "cols" => options["min_cols"],
    "rows" => options["min_rows"]
  }
  probe = {
    "source" => "herdr pane layout",
    "minimum" => minimum,
    "source_pane" => view["source_pane"],
    "tab" => view["tab"],
    "workspace" => view["workspace"],
    "source_pane_size" => nil,
    "projected_same_tab_size" => nil,
    "existing_agent_panes_in_tab" => nil,
    "inspectable" => false,
    "same_tab_readable" => false
  }

  herdr_path = command_path("herdr")
  return probe.merge("reason" => "herdr command not found") unless herdr_path

  layout_command = [herdr_path, "pane", "layout"]
  source_pane = view["source_pane"].to_s
  layout_command.concat(["--pane", source_pane]) unless source_pane.empty?
  layout_stdout, layout_stderr, layout_status = Open3.capture3(*layout_command)
  unless layout_status.success?
    return probe.merge(
      "reason" => "herdr pane layout failed",
      "layout_result" => {
        "success" => false,
        "exit_status" => layout_status.exitstatus,
        "stdout" => layout_stdout,
        "stderr" => layout_stderr
      }
    )
  end

  parsed = JSON.parse(layout_stdout)
  layout = parsed.dig("result", "layout") || parsed["layout"] || parsed.dig("result") || parsed
  panes = Array(layout["panes"]).select { |entry| entry.is_a?(Hash) }
  pane_entry = panes.find { |entry| !source_pane.empty? && entry["pane_id"].to_s == source_pane }
  pane_entry ||= panes.find { |entry| entry["focused"] == true }
  pane_entry ||= panes.first
  source_size = rect_dimensions(pane_entry && (pane_entry["rect"] || pane_entry["area"] || pane_entry))
  source_size ||= rect_dimensions(layout["area"])
  return probe.merge("reason" => "herdr pane layout did not include pane dimensions") unless source_size

  layout_tab = layout["tab_id"].to_s
  layout_workspace = layout["workspace_id"].to_s
  tab = layout_tab.empty? ? view["tab"].to_s : layout_tab
  workspace = layout_workspace.empty? ? view["workspace"].to_s : layout_workspace
  probe["tab"] = tab unless tab.empty?
  probe["workspace"] = workspace unless workspace.empty?

  agent_count = nil
  agents = []
  agent_stdout, _agent_stderr, agent_status = Open3.capture3(herdr_path, "agent", "list")
  if agent_status.success?
    agents_parsed = JSON.parse(agent_stdout)
    agents = agents_parsed.dig("result", "agents") || agents_parsed["agents"] || []
    agent_count = Array(agents).count do |entry|
      entry.is_a?(Hash) &&
        !entry["agent"].to_s.strip.empty? &&
        (tab.empty? || entry["tab_id"].to_s == tab)
    end
  end

  placement = weighted_same_tab_placement(panes, agents, options["resolved_role"], minimum, source_pane: source_pane)
  projected = placement && placement["projected_new_size"]
  same_tab_readable = placement && placement["readable"] == true
  probe.merge(
    "source_pane_size" => source_size,
    "projected_same_tab_size" => projected,
    "existing_agent_panes_in_tab" => agent_count,
    "placement" => placement,
    "inspectable" => true,
    "same_tab_readable" => same_tab_readable,
    "reason" => placement ? "weighted current-tab placement is available" : "no current-tab pane is available for weighted placement"
  )
rescue JSON::ParserError => e
  probe.merge("reason" => "could not parse Herdr layout JSON", "error" => e.message)
end

def role_creation_policy(options)
  view = herdr_same_level_view
  layout_mode = options["layout"] || "auto"
  layout_probe = herdr_layout_probe(view, options)
  unless view["layout_context_incomplete"]
    view = view.merge(
      "tab" => layout_probe["tab"].to_s.empty? ? view["tab"] : layout_probe["tab"],
      "workspace" => layout_probe["workspace"].to_s.empty? ? view["workspace"] : layout_probe["workspace"]
    )
  end
  requested_same_tab = layout_mode == "same-tab"
  placement = layout_probe["placement"]
  auto_same_tab = layout_mode == "auto" && !view["tab"].to_s.empty? && placement.is_a?(Hash)
  selected_layout = requested_same_tab || auto_same_tab ? "same_tab" : "new_tab"
  blocked = requested_same_tab && !placement.is_a?(Hash)
  reason = if layout_mode == "new-tab"
             "new-tab layout was requested"
           elsif selected_layout == "same_tab"
             "weighted current-tab placement: #{placement["new_role"]} splits #{placement["target_role"]} pane #{placement["target_pane"]} #{placement["direction"]} at retained ratio #{placement["ratio"]}"
           elsif layout_mode == "same-tab"
             layout_probe["reason"]
           elsif view["tab"].to_s.empty?
             "no Herdr tab was available; using a new tab"
           else
             "#{layout_probe["reason"]}; using a new tab"
           end
  policy = {
    "reuse_first" => true,
    "user_managed_requires_allow_create" => false,
    "same_level_view" => view,
    "layout" => {
      "mode" => layout_mode,
      "selected" => selected_layout,
      "reason" => reason,
      "minimum" => {
        "cols" => options["min_cols"],
        "rows" => options["min_rows"]
      },
      "source_pane_size" => layout_probe["source_pane_size"],
      "projected_same_tab_size" => layout_probe["projected_same_tab_size"],
      "existing_agent_panes_in_tab" => layout_probe["existing_agent_panes_in_tab"],
      "placement" => placement,
      "same_tab_readable" => layout_probe["same_tab_readable"],
      "workspace" => view["workspace"],
      "tab" => view["tab"],
      "inspectable" => layout_probe["inspectable"],
      "blocked" => blocked
    },
    "permission_setup" => {
      "required" => true,
      "mode" => "operator_or_client_specific",
      "summary" => "Before assigning tool work to a newly-created role, ensure the agent client has the required permissions or approval mode. Orbit records this requirement but does not silently bypass user approval."
    }
  }
  policy
end

def start_client_metadata(argv)
  executable = File.basename(argv.first.to_s)
  full_permission_flag_sets = {
    "codex" => [["--dangerously-bypass-approvals-and-sandbox"]],
    "claude" => [["--dangerously-skip-permissions"]],
    "opencode" => [["--auto"], ["--dangerously-skip-permissions"]],
    "omp" => [["--auto-approve"], ["--approval-mode=yolo"], ["--approval-mode", "yolo"]]
  }
  flag_sets = full_permission_flag_sets.fetch(executable, [])
  matched = flag_sets.find do |required|
    required.each_cons(2).any? { |a, b| argv.each_cons(2).any? { |x, y| x == a && y == b } } ||
      required.all? { |flag| argv.include?(flag) }
  end
  required_flags = matched || flag_sets.first || []
  present_flags = required_flags.select { |flag| argv.include?(flag) }
  {
    "expected_client" => executable,
    "argv" => argv,
    "full_permission" => {
      "known_client" => full_permission_flag_sets.key?(executable),
      "required_flags" => required_flags,
      "accepted_flag_sets" => flag_sets,
      "present_flags" => present_flags,
      "configured" => !matched.nil?,
      "mode" => flag_sets.empty? ? "unknown_client" : "argv_flag",
      "note" => "Full-permission flags are audited in the start plan; the client may still require runtime approval, so completion must be verified through evidence and wait-gate."
    }
  }
end

def start_requires_reuse?(plan)
  plan.dig("instance_status", "binding") == "bound"
end

def herdr_bound_pane(plan)
  binding = plan.dig("instance_status", "herdr") || {}
  return "" unless binding["adapter"] == "herdr"

  binding["canonical_pane"].to_s.empty? ? binding["pane"].to_s : binding["canonical_pane"].to_s
end

START_FORCE_RISKS = [
  {
    "code" => "old_external_process_may_still_exist",
    "message" => "Force does not kill the old external process; stop it manually if it is still running."
  },
  {
    "code" => "duplicate_instance_agents_may_run_concurrently",
    "message" => "Old and new agents with the same instance and role may run concurrently."
  },
  {
    "code" => "old_and_new_agents_may_compete_for_orbit_state",
    "message" => "Old and new agents may compete for evidence, gate leases, and loop state writes."
  },
  {
    "code" => "orbit_binding_will_be_replaced",
    "message" => "The new start replaces Orbit's current binding for this instance."
  }
].freeze

def start_force_command(plan)
  ["orbit", "start", plan["requested_instance"] || plan["instance"], "--force"]
end

def start_force_metadata(plan)
  {
    "force_command" => start_force_command(plan),
    "risk" => START_FORCE_RISKS
  }
end

def start_liveness_reason(probe)
  return "binding_cache_unverified" unless probe
  return "live_agent_detected" if probe["decision"] == "reuse"

  probe["reason"].to_s.empty? ? "binding_cache_unverified" : probe["reason"]
end

def start_needs_force_result(plan, probe)
  plan.merge(
    "action" => "needs_force",
    "binding" => "bound",
    "liveness" => "not_alive",
    "liveness_source" => probe ? "herdr_probe" : "static_binding_cache",
    "liveness_reason" => start_liveness_reason(probe),
    "reuse_probe" => probe
  ).compact.merge(start_force_metadata(plan))
end

def start_instance_runtime_path(instance)
  runtime_replacement_path(instance)
end

def start_instance_lock_path(instance)
  safe = instance.to_s.gsub(/[^A-Za-z0-9_.-]+/, "_")
  File.join(Dir.pwd, ".orbit", "runtime", "locks", "start-#{safe}")
end

def try_with_start_instance_lock(instance)
  expanded = File.expand_path(start_instance_lock_path(instance))
  FileUtils.mkdir_p(File.dirname(expanded))
  lock_path = "#{expanded}.lock"

  File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
    return false unless lock.flock(File::LOCK_EX | File::LOCK_NB)

    yield
    true
  ensure
    lock.flock(File::LOCK_UN) if lock
  end
end

def start_in_progress_result(plan)
  plan.merge(
    "action" => "needs_attention",
    "reason" => "start_in_progress",
    "liveness_reason" => "another forced start is already replacing this instance"
  )
end

def compact_instance_binding(binding)
  {
    "pane" => binding["pane"],
    "tab" => binding["tab"],
    "workspace" => binding["workspace"],
    "canonical_pane" => binding["canonical_pane"],
    "adapter" => binding["adapter"]
  }.compact
end

def write_start_replacement_diagnostic!(plan, status_after_start)
  return nil unless plan["force"]

  previous_binding = plan.dig("instance_status", "herdr") || {}
  new_binding = status_after_start&.dig("herdr") || {}
  path = start_instance_runtime_path(plan["instance"])
  payload = {
    "schema_version" => "orbit-start-replacement-v1",
    "instance" => plan["instance"],
    "role" => plan["resolved_role"],
    "new_session_id" => plan["session_id"],
    "replaced_at" => Time.now.utc.iso8601,
    "reason" => "user_forced_start_replace",
    "previous_binding" => compact_instance_binding(previous_binding),
    "new_binding" => compact_instance_binding(new_binding),
    "risk" => START_FORCE_RISKS
  }
  runtime_record_replacement!(plan["instance"], payload)
  path.sub("#{Dir.pwd}/", "")
end

def herdr_agent_list_for_pane(herdr_path, pane)
  stdout, stderr, status = Open3.capture3(herdr_path, "agent", "list")
  return [nil, { "success" => false, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }] unless status.success?

  parsed = JSON.parse(stdout)
  agents = parsed.dig("result", "agents") || parsed["agents"] || []
  pane_ids = Array(pane).map(&:to_s).reject(&:empty?)
  candidates = agents.select do |entry|
    entry.is_a?(Hash) &&
      pane_ids.include?(entry["pane_id"].to_s) &&
      !entry["agent"].to_s.strip.empty?
  end
  candidates = candidates.uniq do |entry|
    [
      entry["pane_id"].to_s,
      entry["agent"].to_s,
      entry["agent_status"].to_s,
      entry["cwd"].to_s,
      entry["foreground_cwd"].to_s,
      entry["project_root"].to_s
    ]
  end
  result = {
    "success" => true,
    "stdout" => stdout,
    "stderr" => stderr,
    "exit_status" => status.exitstatus,
    "candidate_count" => candidates.length,
    "candidates" => candidates.map { |entry| compact_herdr_agent_entry(entry) }
  }
  [candidates.first, result]
rescue JSON::ParserError => e
  [nil, { "success" => false, "stdout" => stdout.to_s, "stderr" => e.message, "exit_status" => status&.exitstatus }]
end

def compact_herdr_agent_entry(entry)
  return {} unless entry.is_a?(Hash)

  %w[agent agent_status pane_id tab_id workspace_id cwd foreground_cwd project_root].each_with_object({}) do |key, compact|
    value = entry[key]
    compact[key] = value unless value.nil? || value.to_s.empty?
  end
end

def expanded_path_for_compare(path)
  value = path.to_s.strip
  return "" if value.empty?

  expanded = File.expand_path(value)
  File.exist?(expanded) ? File.realpath(expanded) : expanded
rescue StandardError
  value
end

def herdr_agent_identity_checks(agent, plan)
  checks = []
  conflicts = []

  expected_client = plan.dig("client", "expected_client").to_s.strip
  actual_client = agent["agent"].to_s.strip
  if expected_client.empty?
    checks << { "check" => "client", "status" => "unavailable", "reason" => "expected_client_missing" }
  elsif actual_client.empty?
    checks << { "check" => "client", "status" => "unavailable", "expected" => expected_client, "reason" => "herdr_agent_missing" }
  elsif actual_client == expected_client
    checks << { "check" => "client", "status" => "pass", "expected" => expected_client, "actual" => actual_client }
  else
    conflicts << "client_mismatch"
    checks << { "check" => "client", "status" => "fail", "expected" => expected_client, "actual" => actual_client, "reason" => "client_mismatch" }
  end

  expected_cwd = expanded_path_for_compare(plan["cwd"])
  cwd_fields = %w[cwd foreground_cwd project_root].each_with_object([]) do |field, fields|
    value = expanded_path_for_compare(agent[field])
    fields << [field, value] unless value.empty?
  end
  if expected_cwd.empty?
    checks << { "check" => "cwd", "status" => "unavailable", "reason" => "expected_cwd_missing" }
  elsif cwd_fields.empty?
    checks << { "check" => "cwd", "status" => "unavailable", "expected" => expected_cwd, "reason" => "herdr_cwd_missing" }
  elsif cwd_fields.any? { |_field, value| value == expected_cwd }
    checks << {
      "check" => "cwd",
      "status" => "pass",
      "expected" => expected_cwd,
      "actual" => cwd_fields.to_h
    }
  else
    conflicts << "cwd_mismatch"
    checks << {
      "check" => "cwd",
      "status" => "fail",
      "expected" => expected_cwd,
      "actual" => cwd_fields.to_h,
      "reason" => "cwd_mismatch"
    }
  end

  [conflicts.empty?, checks, conflicts]
end

def herdr_pane_info(herdr_path, pane)
  return [nil, { "success" => false, "reason" => "empty pane id" }] if pane.to_s.empty?

  stdout, stderr, status = Open3.capture3(herdr_path, "pane", "get", pane.to_s)
  return [nil, { "success" => false, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }] unless status.success?

  parsed = JSON.parse(stdout)
  info = parsed.dig("result", "pane") || parsed["pane"] || parsed.dig("result") || parsed
  [info, { "success" => true, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }]
rescue JSON::ParserError => e
  [nil, { "success" => false, "stdout" => stdout.to_s, "stderr" => e.message, "exit_status" => status&.exitstatus }]
end

def current_herdr_pane_info(herdr_path)
  current_pane = ENV["HERDR_PANE_ID"].to_s
  return [nil, { "success" => false, "reason" => "HERDR_PANE_ID is not set" }] if current_pane.empty?

  herdr_pane_info(herdr_path, current_pane)
end

def herdr_pane_process_info(herdr_path, pane)
  return [nil, { "success" => false, "reason" => "empty pane id" }] if pane.to_s.empty?

  stdout, stderr, status = Open3.capture3(herdr_path, "pane", "process-info", "--pane", pane.to_s)
  return [nil, { "success" => false, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }] unless status.success?

  parsed = JSON.parse(stdout)
  info = parsed.dig("result", "process_info") || parsed["process_info"] || parsed.dig("result") || parsed
  [info, { "success" => true, "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }]
rescue JSON::ParserError => e
  [nil, { "success" => false, "stdout" => stdout.to_s, "stderr" => e.message, "exit_status" => status&.exitstatus }]
end

def shell_process_info_safe_to_wake?(info)
  return false unless info.is_a?(Hash)

  processes = Array(info["foreground_processes"]).select { |entry| entry.is_a?(Hash) }
  return false unless processes.length == 1

  process = processes.first
  name = File.basename(process["name"].to_s)
  argv0 = File.basename(process["argv0"].to_s)
  shell_names = %w[sh bash zsh fish dash ksh mksh tcsh csh]
  shell_names.include?(name) || shell_names.include?(argv0.delete_prefix("-"))
end

def pane_output_safe_to_wake?(output)
  text = output.to_s
  return true if text.strip.empty?
  return false if text.match?(/OpenAI Codex|Claude Code|opencode|esc to interrupt|bypass permissions/i)

  last_line = text.lines.map(&:strip).reject(&:empty?).last.to_s
  last_line.match?(/[#$%>❯›]\s*\z/)
end

def herdr_reuse_probe(plan, herdr_path = nil)
  pane = herdr_bound_pane(plan)
  return nil if pane.empty?

  herdr_path ||= command_path("herdr")
  return {
    "schema_version" => "orbit-herdr-reuse-probe-v1",
    "pane" => pane,
    "agent_detected" => false,
    "safe_to_wake" => false,
    "decision" => "needs_attention",
    "reason" => "herdr command not found"
  } unless herdr_path

  bound_pane_info, pane_get_result = herdr_pane_info(herdr_path, pane)
  canonical_pane = bound_pane_info["pane_id"].to_s unless bound_pane_info.nil?
  canonical_pane = pane if canonical_pane.to_s.empty?
  current_pane_info, current_pane_result = current_herdr_pane_info(herdr_path)
  current_pane = current_pane_info["pane_id"].to_s unless current_pane_info.nil?
  current_pane = ENV["HERDR_PANE_ID"].to_s if current_pane.to_s.empty?
  self_pane = !current_pane.to_s.empty? && [pane.to_s, canonical_pane.to_s].include?(current_pane.to_s)
  agent, list_result = herdr_agent_list_for_pane(herdr_path, [pane, canonical_pane])
  probe = {
    "schema_version" => "orbit-herdr-reuse-probe-v1",
    "pane" => pane,
    "canonical_pane" => canonical_pane,
    "current_pane" => current_pane,
    "self_pane" => self_pane,
    "pane_get" => pane_get_result,
    "current_pane_get" => current_pane_result,
    "agent_list" => list_result
  }
  if list_result["candidate_count"].to_i > 1
    return probe.merge(
      "agent_detected" => true,
      "safe_to_wake" => false,
      "decision" => "needs_attention",
      "reason" => "duplicate_live_candidates",
      "identity_checks" => [],
      "identity_conflicts" => ["duplicate_live_candidates"]
    )
  end
  if agent
    identity_ok, identity_checks, identity_conflicts = herdr_agent_identity_checks(agent, plan)
    unless identity_ok
      return probe.merge(
        "agent_detected" => true,
        "agent" => agent["agent"],
        "agent_status" => agent["agent_status"],
        "safe_to_wake" => false,
        "decision" => "needs_attention",
        "reason" => identity_conflicts.join(","),
        "identity_checks" => identity_checks,
        "identity_conflicts" => identity_conflicts
      )
    end
    return probe.merge(
      "agent_detected" => true,
      "agent" => agent["agent"],
      "agent_status" => agent["agent_status"],
      "safe_to_wake" => false,
      "decision" => "reuse",
      "reason" => "bound pane already has a detected agent",
      "identity_checks" => identity_checks,
      "identity_conflicts" => []
    )
  end
  return probe.merge(
    "agent_detected" => false,
    "safe_to_wake" => false,
    "decision" => "needs_attention",
    "reason" => "could not inspect Herdr agents"
  ) unless list_result["success"]
  if self_pane
    return probe.merge(
      "agent_detected" => false,
      "safe_to_wake" => true,
      "decision" => "self_wake",
      "reason" => "bound pane is the current Herdr pane; start can exec the agent command directly"
    )
  end

  process_info, process_result = herdr_pane_process_info(herdr_path, canonical_pane)
  read_stdout, read_stderr, read_status = Open3.capture3(
    herdr_path,
    "pane",
    "read",
    canonical_pane,
    "--source",
    "recent-unwrapped",
    "--lines",
    "40"
  )
  process_safe_to_wake = shell_process_info_safe_to_wake?(process_info)
  output_safe_to_wake = read_status.success? && pane_output_safe_to_wake?(read_stdout)
  safe_to_wake = process_safe_to_wake || output_safe_to_wake
  probe.merge(
    "agent_detected" => false,
    "safe_to_wake" => safe_to_wake,
    "decision" => safe_to_wake ? "wake" : "needs_attention",
    "reason" => safe_to_wake ? "bound pane exists and looks like an idle shell" : "bound pane has no detected agent but is not safe to wake automatically",
    "pane_process_info" => process_result.merge("safe_to_wake" => process_safe_to_wake),
    "pane_read" => {
      "success" => read_status.success?,
      "exit_status" => read_status.exitstatus,
      "stdout" => read_stdout,
      "stderr" => read_stderr,
      "safe_to_wake" => output_safe_to_wake
    }
  )
end

def wake_command_text(plan)
  env_pairs = (plan["env"] || {}).sort.map { |key, value| "#{key}=#{value}" }
  argv = plan["argv"] || []
  return Shellwords.join(argv) if env_pairs.empty?

  Shellwords.join(["env", *env_pairs, *argv])
end

def herdr_wake_adapter(plan, probe, executable = "herdr")
  pane = probe["canonical_pane"].to_s.empty? ? probe["pane"] : probe["canonical_pane"]
  ready_wait = herdr_start_ready_wait(plan)
  {
    "schema_version" => "orbit-herdr-wake-v1",
    "adapter" => "herdr",
    "pane" => pane,
    "command" => [executable, "pane", "run", pane, wake_command_text(plan)],
    "ready_wait" => ready_wait
  }.compact
end

def self_wake_plan(plan, probe)
  {
    "schema_version" => "orbit-herdr-self-wake-v1",
    "adapter" => "herdr",
    "pane" => probe["canonical_pane"] || probe["pane"],
    "command" => wake_command_text(plan),
    "mode" => "exec_current_process"
  }
end

def start_create_blocked?(plan, options)
  plan.dig("layout", "blocked") == true
end

def print_start_capability_summary(plan, stream = $stdout)
  capabilities = plan["runtime_capabilities"] || {}
  stream.puts "- runtime mode: #{capabilities["mode"]}" unless capabilities["mode"].to_s.empty?
  return if capabilities["direct_dispatch"] == "available"

  stream.puts "- direct dispatch: unavailable"
  stream.puts "- capability degradation: #{capabilities["reason"]}" unless capabilities["reason"].to_s.empty?
  stream.puts "- next: orbit dispatch --manual-payload"
end

def print_start_blocked(plan)
  warn "Orbit start blocked:"
  warn "- instance: #{plan["instance"]}"
  warn "- role: #{plan["resolved_role"]}"
  warn "- management: #{plan.dig("instance_status", "management")}"
  warn "- binding: #{plan.dig("instance_status", "binding")}"
  warn "- layout: #{plan.dig("layout", "selected")}" if plan.dig("layout", "selected")
  warn "- reason: #{plan.dig("layout", "reason") || "start could not create or wake a Herdr agent automatically"}"
  print_start_capability_summary(plan, $stderr)
end

def print_start_needs_attention(plan)
  warn "Orbit start needs attention:"
  warn "- instance: #{plan["instance"]}"
  warn "- role: #{plan["resolved_role"]}"
  warn "- action: needs_attention"
  warn "- pane: #{plan.dig("reuse_probe", "pane")}" if plan.dig("reuse_probe", "pane")
  warn "- reason: #{plan["reason"] || plan.dig("reuse_probe", "reason")}"
  print_start_capability_summary(plan, $stderr)
end

def print_start_needs_force(plan)
  warn "Orbit start found an existing binding, but it cannot prove the agent is alive:"
  warn "- instance: #{plan["instance"]}"
  warn "- role: #{plan["resolved_role"]}"
  warn "- action: needs_force"
  warn "- liveness_source: #{plan["liveness_source"]}"
  warn "- reason: #{plan["liveness_reason"]}"
  warn "Force does not kill the old external process; stop it manually if it is still running."
  warn "Old and new agents with the same instance and role may run concurrently and compete for evidence, gate leases, and loop state writes."
  warn "- next: #{Shellwords.join(plan["force_command"])}"
  print_start_capability_summary(plan, $stderr)
end

def print_start_wake_dry_run(plan)
  puts "Orbit wake plan:"
  puts "- instance: #{plan["instance"]}"
  puts "- role: #{plan["resolved_role"]}"
  puts "- action: wake_dry_run"
  puts "- pane: #{plan.dig("reuse_probe", "pane")}"
  puts "- command: #{plan.dig("wake_adapter", "command", 4)}"
  print_start_capability_summary(plan)
end

def print_start_self_wake_dry_run(plan)
  puts "Orbit self-wake plan:"
  puts "- instance: #{plan["instance"]}"
  puts "- role: #{plan["resolved_role"]}"
  puts "- action: self_wake_dry_run"
  puts "- pane: #{plan.dig("reuse_probe", "canonical_pane") || plan.dig("reuse_probe", "pane")}"
  puts "- command: #{plan.dig("self_wake", "command")}"
  print_start_capability_summary(plan)
end

def herdr_start_argv(plan, executable = "herdr", label = nil)
  command_argv = plan["argv"] || []
  env_pairs = (plan["env"] || {}).sort.map { |key, value| "#{key}=#{value}" }
  command_argv = ["env", *env_pairs, *command_argv] unless env_pairs.empty?
  argv = [
    executable,
    "agent",
    "start",
    label || plan["instance"],
    "--cwd",
    plan["cwd"]
  ]

  view = plan.dig("creation_policy", "same_level_view") || {}
  selected_layout = plan.dig("layout", "selected")
  if selected_layout == "same_tab" && !view["tab"].to_s.empty?
    argv += ["--tab", view["tab"]]
  elsif !view["workspace"].to_s.empty?
    argv += ["--workspace", view["workspace"]]
  end

  argv += ["--split", "right"] if selected_layout == "same_tab"
  argv + ["--no-focus", "--", *command_argv]
end

def herdr_weighted_start_commands(plan, executable = "herdr", pane = "<new-pane>", label = nil)
  placement = plan.dig("layout", "placement") || {}
  [
    [
      executable,
      "pane",
      "split",
      placement["target_pane"],
      "--direction",
      placement["direction"],
      "--ratio",
      placement["ratio"].to_s,
      "--cwd",
      plan["cwd"],
      "--no-focus"
    ],
    [executable, "agent", "rename", pane, label || plan["instance"]],
    [executable, "pane", "run", pane, wake_command_text(plan)]
  ]
end

def herdr_weighted_same_tab_start?(plan)
  plan.dig("layout", "selected") == "same_tab" && plan.dig("layout", "placement").is_a?(Hash)
end

def herdr_agent_name_taken?(stderr)
  parsed = JSON.parse(stderr.to_s)
  parsed.dig("error", "code") == "agent_name_taken"
rescue JSON::ParserError
  stderr.to_s.include?("agent_name_taken")
end

def herdr_retry_label(plan)
  project = plan["project"].to_s
  instance = plan["instance"].to_s
  base = "#{project}-#{instance}".gsub(/[^A-Za-z0-9_.-]+/, "-").gsub(/\A-+|-+\z/, "")
  base = instance.empty? ? "orbit-agent" : instance if base.empty?
  suffix = "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{$$}"
  "#{base[0, 48]}-#{suffix}"
end

def herdr_start_ready_wait(plan)
  matches = {
    "codex" => "OpenAI Codex \\(v",
    "claude" => "Claude Code",
    "opencode" => "OpenCode|Ask anything"
  }
  client = plan.dig("client", "expected_client").to_s
  client = File.basename(plan["argv"].first.to_s) if client.empty?
  match = matches[client]
  return nil unless match

  {
    "mode" => "output_match",
    "client" => client,
    "match" => match,
    "timeout_ms" => 10_000
  }
end

def attach_start_adapter_plan(plan)
  ready_wait = herdr_start_ready_wait(plan)
  weighted_commands = herdr_weighted_start_commands(plan) if herdr_weighted_same_tab_start?(plan)
  plan.merge(
    "herdr_start" => {
      "schema_version" => "orbit-herdr-start-v1",
      "adapter" => "herdr",
      "placement_mode" => weighted_commands ? "weighted_same_tab" : "agent_start",
      "command" => weighted_commands ? weighted_commands.first : herdr_start_argv(plan),
      "commands" => weighted_commands,
      "placement" => plan.dig("layout", "placement"),
      "label" => plan["instance"],
      "env" => plan["env"],
      "ready_wait" => ready_wait
    }.compact
  )
end

def print_start_human_plan(plan)
  puts "Orbit start plan:"
  puts "- instance: #{plan["instance"]}"
  puts "- role: #{plan["resolved_role"]}"
  puts "- adapter: herdr"
  print_start_capability_summary(plan)
  puts "- cwd: #{plan["cwd"]}"
  puts "- command: #{plan["argv"].join(" ")}"
  unless plan["env"].empty?
    puts "- env:"
    plan["env"].sort.each do |key, value|
      puts "  - #{key}=#{value}"
    end
  end
  if plan["creation_policy"]
    view = plan.dig("creation_policy", "same_level_view")
    puts "- create policy:"
    puts "  - reuse_first: #{plan["creation_policy"]["reuse_first"]}"
    if view
      puts "  - same_level_view: #{view["strategy"]}"
      puts "  - source_pane: #{view["source_pane"]}" unless view["source_pane"].to_s.empty?
      puts "  - tab: #{view["tab"]}" unless view["tab"].to_s.empty?
      puts "  - workspace: #{view["workspace"]}" unless view["workspace"].to_s.empty?
    end
    permission_setup = plan.dig("creation_policy", "permission_setup")
    puts "  - permission_setup: #{permission_setup["summary"]}" if permission_setup
  end
  layout = plan["layout"] || {}
  puts "- layout: #{layout["selected"]}" if layout["selected"]
  if layout["placement"]
    placement = layout["placement"]
    puts "  - role priority: lead > reviewer/coder > tester"
    puts "  - split target: #{placement["target_role"]} (#{placement["target_pane"]})"
    puts "  - split: #{placement["direction"]}, retained ratio #{placement["ratio"]}"
  end
  puts "- action: dry-run" if plan["dry_run"]
end

def print_herdr_start_human_result(result)
  adapter_result = result["adapter_result"] || {}
  if result["action"].to_s.end_with?("needs_attention")
    ready = adapter_result["ready_wait"] || {}
    warn "Orbit started the instance, but it needs attention:"
    warn "- instance: #{result["instance"]}"
    warn "- role: #{result["resolved_role"]}"
    warn "- pane: #{adapter_result["pane_id"] || result.dig("wake_adapter", "pane") || "unknown"}"
    warn "- reason: #{ready.dig("detected_prompt", "summary") || ready["blocking_reason"] || "client did not reach its main interface"}"
    warn "- next: #{result.dig("next", 0, "inspect_pane")}" if result.dig("next", 0, "inspect_pane")
  elsif adapter_result["success"]
    puts "Started Orbit instance:"
    puts "- instance: #{result["instance"]}"
    puts "- role: #{result["resolved_role"]}"
    puts "- adapter: herdr"
    puts "- cwd: #{result["cwd"]}"
    puts "- pane: #{adapter_result["pane_id"] || "unknown"}"
    print_start_capability_summary(result)
    if adapter_result["ready_wait"]
      ready = adapter_result["ready_wait"]
      ready_status = if ready["success"] == true
                       "pass"
                     elsif ready["success"] == false
                       "fail"
                     else
                       ready["status"] || "unverified"
                     end
      puts "- ready: #{ready_status}"
    end
  else
    warn "Orbit start failed:"
    warn "- instance: #{result["instance"]}"
    warn "- adapter: herdr"
    print_start_capability_summary(result, $stderr)
    warn "- stderr: #{adapter_result["stderr"]}" if adapter_result["stderr"] && !adapter_result["stderr"].empty?
    if adapter_result["ready_wait"] && !adapter_result["ready_wait"]["success"]
      warn "- ready wait stderr: #{adapter_result["ready_wait"]["stderr"]}"
    end
  end
end

def herdr_start_pane_id(stdout)
  parsed = JSON.parse(stdout)
  if parsed.is_a?(Hash)
    return parsed.dig("result", "agent", "pane_id") if parsed.dig("result", "agent", "pane_id")
    return parsed.dig("result", "pane", "pane_id") if parsed.dig("result", "pane", "pane_id")
    return parsed["pane_id"] if parsed["pane_id"]
  end

  nil
rescue JSON::ParserError
  nil
end

def herdr_start_agent_client(stdout)
  parsed = JSON.parse(stdout)
  return parsed.dig("result", "agent", "agent") if parsed.dig("result", "agent", "agent")
  return parsed.dig("result", "agent") if parsed.dig("result", "agent").is_a?(String)
  return parsed["agent"] if parsed["agent"].is_a?(String)

  nil
rescue JSON::ParserError
  nil
end

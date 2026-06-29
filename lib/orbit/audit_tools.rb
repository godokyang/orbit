# frozen_string_literal: true

def parse_audit_args(args)
  options = {
    "json" => false
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--task"
      options["task"] = option_value(args, "--task")
    when /\A--task=(.+)\z/
      options["task"] = Regexp.last_match(1)
    when "--state"
      options["state"] = option_value(args, "--state")
    when /\A--state=(.+)\z/
      options["state"] = Regexp.last_match(1)
    when "--evidence"
      options["evidence"] = option_value(args, "--evidence")
    when /\A--evidence=(.+)\z/
      options["evidence"] = Regexp.last_match(1)
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown audit option: #{arg}")
    end
  end

  %w[task state evidence].each do |name|
    usage_error("Missing required option: --#{name}") if options[name].nil? || options[name].empty?
  end
  usage_error("audit currently requires --json") unless options["json"]

  options
end

def audit_validation_result(task_path, evidence_path, state_path)
  result = {
    "schema_version" => "orbit-validate-v1",
    "project" => File.basename(Dir.pwd),
    "checked" => [],
    "valid" => false,
    "errors" => [],
    "warnings" => []
  }

  validate_project_config(result)
  result["checked"] << "project_config"
  task = validate_task(result, task_path)
  result["checked"] << "task"
  evidence = validate_evidence(result, evidence_path, task)
  result["checked"] << "evidence"
  state = validate_state_file(result, state_path)
  result["checked"] << "state"
  result["valid"] = result["errors"].empty?

  [result, task, evidence, state]
end

def audit_remediation(source)
  case source
  when /\Astate_file\.current_task/
    "重新执行 `orbit state start --task ...` 或修正 loop state，让 current_task 指向本次审计的 task。"
  when /\Astate_file\.artifacts\.evidence_file/
    "重新执行 `orbit state transition --to done --evidence ...`，或修正 loop state 的 evidence_file 指向本次审计的 evidence。"
  when /\Astate_file\.artifacts\.handoff_packet/
    "运行 `orbit handoff --task ... --state ... --evidence ... --json` 并在发布前记录 handoff artifact。"
  when /\Aevidence_file/
    "补充或修正 evidence manifest，确保至少有一个可支持当前 gate 的 pass evidence。"
  when /\Atask_file/
    "修正 task contract 的必填字段后重新运行 validate/audit。"
  when /\Aproject_config/
    "修正 .orbit 项目配置后重新运行 validate/audit。"
  else
    "补齐对应协议文件或重新运行相关 Orbit 命令后再审计。"
  end
end

def audit_finding(source, message, severity = "high", remediation = nil)
  {
    "source" => source,
    "message" => message,
    "severity" => severity,
    "summary" => message,
    "remediation" => remediation || audit_remediation(source)
  }
end

def audit_trust_level
  {
    "mode" => "audit_only",
    "meaning" => "Orbit reports whether files are consistent and evidence-backed; it does not prevent users from editing files.",
    "known_bypasses" => [
      "Users or agents with filesystem access can manually edit task, evidence, or loop state files.",
      "Audit can report drift, but local files remain the source being inspected."
    ],
    "required_before_done" => [
      "orbit validate passes for project config, task, evidence, and state.",
      "Loop state points at the audited task and evidence files.",
      "Evidence contains a pass signal for done state."
    ]
  }
end

def audit_state_consistency(task_path, evidence_path, state, evidence, task = nil)
  blocking_findings = []
  warnings = []
  phase = state.is_a?(Hash) ? state["phase"] : nil

  if state.is_a?(Hash)
    current_task = state["current_task"]
    if current_task.nil? || current_task.empty?
      blocking_findings << audit_finding("state_file.current_task", "Loop state must reference the audited task.")
    elsif File.expand_path(current_task) != task_path
      blocking_findings << audit_finding("state_file.current_task", "Loop state current_task does not match audited task.")
    end

    artifacts = state["artifacts"]
    evidence_ref = artifacts.is_a?(Hash) ? artifacts["evidence_file"] : nil
    if evidence_ref.nil? || evidence_ref.empty?
      finding = audit_finding("state_file.artifacts.evidence_file", "Loop state does not reference the audited evidence file.")
      if phase == "done"
        blocking_findings << finding
      else
        warnings << audit_finding(
          "state_file.artifacts.evidence_file",
          "Loop state does not reference the audited evidence file.",
          "medium"
        )
      end
    elsif File.expand_path(evidence_ref) != evidence_path
      blocking_findings << audit_finding("state_file.artifacts.evidence_file", "Loop state evidence_file does not match audited evidence.")
    end

    handoff_ref = artifacts.is_a?(Hash) ? artifacts["handoff_packet"] : nil
    if phase == "done" && (handoff_ref.nil? || handoff_ref.empty?)
      warnings << audit_finding(
        "state_file.artifacts.handoff_packet",
        "Done state does not reference a handoff packet; release trust remains incomplete.",
        "medium"
      )
    end
  end

  if phase == "done" && !evidence_has_done_signal?(evidence)
    blocking_findings << audit_finding("evidence_file", "Done state requires at least one pass evidence signal.")
  end

  if phase == "done" && task.is_a?(Hash)
    records = evidence.is_a?(Hash) ? evidence["records"] : []
    required_evidence_kinds(task).each do |kind|
      next if gate_passed?(records, kind)

      blocking_findings << audit_finding(
        "evidence_file.records.#{kind}",
        "Done state requires latest #{kind} gate evidence to be pass.",
        "high",
        "让 #{kind == "review" ? "reviewer" : "tester"} 提交 pass evidence，或显式记录 waiver/residual risk 后重新审计。"
      )
    end
  end

  [blocking_findings, warnings]
end

def audit_trust_flags(phase, blocking_findings, warnings)
  trusted_for_handoff = blocking_findings.empty?
  trusted_for_done = phase == "done" && trusted_for_handoff
  trusted_for_release = trusted_for_done && warnings.empty?
  {
    "trusted_for_handoff" => trusted_for_handoff,
    "trusted_for_done" => trusted_for_done,
    "trusted_for_release" => trusted_for_release
  }
end

def audit(args)
  options = parse_audit_args(args)
  task_path = File.expand_path(options["task"])
  evidence_path = File.expand_path(options["evidence"])
  state_path = File.expand_path(options["state"])
  validation, task, evidence, state = audit_validation_result(task_path, evidence_path, state_path)
  blocking_findings = validation["errors"].map { |error| audit_finding(error["source"], error["message"], "high") }
  warnings = validation["warnings"].map { |warning| audit_finding(warning["source"], warning["message"], "medium") }
  state_blocking, state_warnings = audit_state_consistency(task_path, evidence_path, state, evidence, task)
  blocking_findings.concat(state_blocking)
  warnings.concat(state_warnings)

  phase = state.is_a?(Hash) ? state["phase"] : nil
  trust_flags = audit_trust_flags(phase, blocking_findings, warnings)
  issues = blocking_findings + warnings

  schema_summary = evidence_schema_version_summary(evidence, task)
  if schema_summary
    # Prose/structured conflicts are blocking: structured verdict wins per global compatibility policy.
    schema_summary["prose_conflicts"].each do |conflict|
      blocking_findings << audit_finding(
        conflict["source"] || "evidence_file.records",
        conflict["message"],
        "high",
        "Correct the report so the summary derives from the structured verdict field. Structured verdict takes precedence."
      )
    end
    # Unknown future versions are blocking: do not silently treat as current semantics.
    schema_summary["unknown_versions"].each do |uv|
      blocking_findings << audit_finding(
        uv["source"],
        uv["message"],
        "high",
        uv["action"]
      )
    end
    # Re-derive issues list with any newly added blocking_findings.
    issues = blocking_findings + warnings
  end

  trust_flags = audit_trust_flags(phase, blocking_findings, warnings)

  packet = {
    "schema_version" => "orbit-audit-v1",
    "project" => task.is_a?(Hash) && task["project"] ? task["project"] : File.basename(Dir.pwd),
    "inputs" => {
      "task" => task_path,
      "evidence" => evidence_path,
      "state" => state_path
    },
    "trust_level" => audit_trust_level,
    "validation" => validation,
    "state_phase" => phase,
    "trusted_for_handoff" => trust_flags["trusted_for_handoff"],
    "trusted_for_done" => trust_flags["trusted_for_done"],
    "trusted_for_release" => trust_flags["trusted_for_release"],
    "done_ready" => trust_flags["trusted_for_done"],
    "evidence_summary" => evidence_summary(evidence),
    "worktree_safety_summary" => worktree_safety_summary(evidence),
    "rule_resolution_summary" => rule_resolution_summary(evidence, evidence_path),
    "schema_version_summary" => schema_summary,
    "issues" => issues,
    "blocking_findings" => blocking_findings,
    "warnings" => warnings
  }

  puts JSON.pretty_generate(packet)
  exit(blocking_findings.empty? ? 0 : 1)
end

def parse_tools_args(args)
  subcommand = args.shift
  usage_error("Missing tools subcommand.") unless subcommand

  options = {
    "subcommand" => subcommand,
    "json" => false
  }

  until args.empty?
    arg = args.shift

    case arg
    when "--json"
      options["json"] = true
    else
      usage_error("Unknown tools #{subcommand} option: #{arg}")
    end
  end

  case subcommand
  when "detect", "doctor"
    usage_error("tools #{subcommand} currently requires --json") unless options["json"]
  else
    usage_error("Unknown tools subcommand: #{subcommand}")
  end

  options
end

def command_path(command)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    next if dir.empty?

    candidate = File.join(dir, command)
    return candidate if File.file?(candidate) && File.executable?(candidate)
  end

  nil
end

def ci_environment
  {
    "CI" => ENV["CI"],
    "GITHUB_ACTIONS" => ENV["GITHUB_ACTIONS"],
    "GITLAB_CI" => ENV["GITLAB_CI"],
    "BUILDKITE" => ENV["BUILDKITE"],
    "CIRCLECI" => ENV["CIRCLECI"],
    "JENKINS_URL" => ENV["JENKINS_URL"]
  }.select { |_name, value| value && !value.empty? }
end

def detected_tool(name, available, capabilities, reason = nil, metadata = {})
  tool = {
    "name" => name,
    "available" => available,
    "capabilities" => available ? capabilities : []
  }
  tool["reason"] = reason if reason
  metadata.each { |key, value| tool[key] = value unless value.nil? }
  tool
end

def detect_tools
  shell = ENV["SHELL"]
  shell_path = shell && !shell.empty? && File.executable?(shell) ? shell : nil
  shell_path ||= "/bin/sh" if File.executable?("/bin/sh")
  herdr_path = command_path("herdr")
  tmux_path = command_path("tmux")
  git_path = command_path("git")
  ci_env = ci_environment

  [
    detected_tool(
      "local_shell",
      !shell_path.nil?,
      %w[command.run file.read file.write],
      shell_path ? nil : "no executable shell found",
      "path" => shell_path
    ),
    detected_tool(
      "herdr",
      !herdr_path.nil?,
      %w[agent.start pane.message pane.capture review.request],
      herdr_path ? nil : "command not found",
      "path" => herdr_path
    ),
    detected_tool(
      "tmux",
      !tmux_path.nil?,
      %w[pane.message pane.capture session.manage],
      tmux_path ? nil : "command not found",
      "path" => tmux_path
    ),
    detected_tool(
      "ci",
      !ci_env.empty?,
      %w[command.run gate.report artifact.collect],
      ci_env.empty? ? "CI environment variables not set" : nil,
      "env" => ci_env.keys
    ),
    detected_tool(
      "git",
      !git_path.nil?,
      %w[status.read diff.inspect commit.read],
      git_path ? nil : "command not found",
      "path" => git_path
    )
  ]
end

def tools_detect_packet
  {
    "schema_version" => "orbit-tools-v1",
    "project" => File.basename(Dir.pwd),
    "generated_at" => Time.now.utc.iso8601,
    "detected" => detect_tools
  }
end

def tools_doctor_packet
  detected = detect_tools
  by_name = detected.to_h { |tool| [tool["name"], tool] }
  findings = []

  unless by_name.fetch("local_shell")["available"]
    findings << {
      "severity" => "error",
      "source" => "tools.local_shell",
      "message" => "No executable shell was found; local command execution is unavailable."
    }
  end

  %w[herdr tmux ci].each do |name|
    next if by_name.fetch(name)["available"]

    findings << {
      "severity" => "warning",
      "source" => "tools.#{name}",
      "message" => "#{name} is unavailable; generic JSON/file handoff remains valid."
    }
  end

  unless by_name.fetch("git")["available"]
    findings << {
      "severity" => "warning",
      "source" => "tools.git",
      "message" => "git is unavailable; audit cannot rely on git status or diff evidence."
    }
  end

  health = if findings.any? { |finding| finding["severity"] == "error" }
             "fail"
           elsif findings.any? { |finding| finding["severity"] == "warning" }
             "warn"
           else
             "pass"
           end

  preferred_transport = if by_name.fetch("herdr")["available"]
                          "herdr"
                        elsif by_name.fetch("tmux")["available"]
                          "tmux"
                        else
                          "generic"
                        end

  {
    "schema_version" => "orbit-tools-doctor-v1",
    "project" => File.basename(Dir.pwd),
    "generated_at" => Time.now.utc.iso8601,
    "health" => health,
    "preferred_transport" => preferred_transport,
    "detected" => detected,
    "findings" => findings
  }
end

def tools(args)
  options = parse_tools_args(args)
  packet = case options["subcommand"]
           when "detect"
             tools_detect_packet
           when "doctor"
             tools_doctor_packet
           end

  puts JSON.pretty_generate(packet)
  if options["subcommand"] == "doctor" && packet["health"] == "fail"
    exit 1
  end
end


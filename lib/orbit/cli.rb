# frozen_string_literal: true

require_relative "core"
require_relative "identity_rules"
require_relative "runtime_store"
require_relative "herdr_probe"
require_relative "runtime_resolver"
require_relative "runtime_commands"
require_relative "schema_version"
require_relative "project_profile_risk"
require_relative "revision_knowledge"
require_relative "user_journey"
require_relative "artifact_provenance"
require_relative "task_launch_dispatch"
require_relative "evidence"
require_relative "state_validate_gate"
require_relative "audit_tools"
require_relative "gate_lease"
require_relative "handoff"
require_relative "status"
require_relative "notice"
require_relative "hook"
require_relative "docs_lifecycle"
require_relative "data_classification"
require_relative "release_readiness"
require_relative "dogfood_governance"
require_relative "landing_governance"
require_relative "task_workflow"

def run_orbit_cli(argv)
  command = argv.shift
  runtime_maybe_piggyback!(command, argv)

  case command
  when nil, "-h", "--help", "help"
    print_help
  when "audit"
    if help_requested?(argv)
      print_command_help("audit")
      exit 0
    end
    audit(argv)
  when "artifact"
    if help_requested?(argv) || (argv.first == "inspect" && help_requested?(argv[1..] || []))
      print_command_help("artifact")
      exit 0
    end
    artifact(argv)
  when "bind-pane"
    if help_requested?(argv)
      print_command_help("bind-pane")
      exit 0
    end
    bind_pane(argv)
  when "classify-intent"
    if help_requested?(argv)
      print_command_help("classify-intent")
      exit 0
    end
    classify_intent(argv)
  when "compact-evidence"
    if help_requested?(argv)
      print_command_help("compact-evidence")
      exit 0
    end
    compact_evidence(argv)
  when "dispatch"
    if help_requested?(argv)
      print_command_help("dispatch")
      exit 0
    end
    dispatch(argv)
  when "docs"
    if help_requested?(argv)
      print_command_help("docs")
      exit 0
    end
    docs(argv)
  when "evidence"
    if help_requested?(argv) || (argv.first == "submit" && help_requested?(argv[1..] || []))
      print_command_help("evidence")
      exit 0
    end
    evidence(argv)
  when "handoff"
    if help_requested?(argv)
      print_command_help("handoff")
      exit 0
    end
    handoff(argv)
  when "hook"
    if help_requested?(argv)
      print_command_help("hook")
      exit 0
    end
    hook(argv)
  when "init"
    if help_requested?(argv)
      print_command_help("init")
      exit 0
    end
    init_config(argv)
  when "instances"
    if help_requested?(argv)
      print_command_help("instances")
      exit 0
    end
    instances(argv)
  when "new-task"
    if help_requested?(argv)
      print_command_help("new-task")
      exit 0
    end
    new_task(argv)
  when "notice"
    if help_requested?(argv)
      print_command_help("notice")
      exit 0
    end
    notice(argv)
  when "next"
    if help_requested?(argv)
      print_command_help("status")
      exit 0
    end
    status_command(argv, next_only: true)
  when "rules"
    if help_requested?(argv)
      print_command_help("rules")
      exit 0
    end
    if argv.first == "print-context" && help_requested?(argv[1..] || [])
      print_command_help("rules print-context")
      exit 0
    end
    if argv.first == "resolve" && help_requested?(argv[1..] || [])
      print_command_help("rules resolve")
      exit 0
    end
    rules(argv)
  when "revision"
    if help_requested?(argv) || (argv.first == "create" && help_requested?(argv[1..] || []))
      print_command_help("revision")
      exit 0
    end
    revision(argv)
  when "runtime"
    if help_requested?(argv)
      print_command_help("runtime")
      exit 0
    end
    runtime(argv)
  when "start"
    if help_requested?(argv)
      print_command_help("start")
      exit 0
    end
    start(argv)
  when "status"
    if help_requested?(argv)
      print_command_help("status")
      exit 0
    end
    status_command(argv)
  when "state"
    if help_requested?(argv)
      print_command_help("state")
      exit 0
    end
    state(argv)
  when "tools"
    if help_requested?(argv)
      print_command_help("tools")
      exit 0
    end
    tools(argv)
  when "test-hook"
    if help_requested?(argv) || (argv.first == "run" && help_requested?(argv[1..] || []))
      print_command_help("test-hook")
      exit 0
    end
    test_hook(argv)
  when "task"
    if help_requested?(argv) || (%w[draft start].include?(argv.first) && help_requested?(argv[1..] || []))
      print_command_help("task")
      exit 0
    end
    task_workflow(argv)
  when "validate"
    if help_requested?(argv)
      print_command_help("validate")
      exit 0
    end
    validate(argv)
  when "wait-gate"
    if help_requested?(argv)
      print_command_help("wait-gate")
      exit 0
    end
    wait_gate(argv)
  when "whoami"
    if help_requested?(argv)
      print_command_help("whoami")
      exit 0
    end
    whoami(argv)
  when "version", "--version", "-v"
    puts VERSION
  else
    usage_error("Unknown command: #{command}")
  end
end

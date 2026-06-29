# frozen_string_literal: true

require_relative "core"
require_relative "identity_rules"
require_relative "schema_version"
require_relative "project_profile_risk"
require_relative "task_launch_dispatch"
require_relative "evidence"
require_relative "state_validate_gate"
require_relative "audit_tools"
require_relative "gate_lease"
require_relative "handoff"
require_relative "docs_lifecycle"
require_relative "data_classification"
require_relative "release_readiness"
require_relative "dogfood_governance"

def run_orbit_cli(argv)
  command = argv.shift

  case command
  when nil, "-h", "--help", "help"
    print_help
  when "audit"
    if help_requested?(argv)
      print_command_help("audit")
      exit 0
    end
    audit(argv)
  when "bind-pane"
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
  when "init"
    init_config(argv)
  when "instances"
    instances(argv)
  when "new-task"
    new_task(argv)
  when "rules"
    if argv.first == "print-context" && help_requested?(argv[1..] || [])
      print_command_help("rules print-context")
      exit 0
    end
    if argv.first == "resolve" && help_requested?(argv[1..] || [])
      print_command_help("rules resolve")
      exit 0
    end
    rules(argv)
  when "start"
    if help_requested?(argv)
      print_command_help("start")
      exit 0
    end
    start(argv)
  when "state"
    state(argv)
  when "tools"
    tools(argv)
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
    whoami(argv)
  when "version", "--version", "-v"
    puts VERSION
  else
    usage_error("Unknown command: #{command}")
  end
end

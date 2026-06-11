# frozen_string_literal: true

require_relative "core"
require_relative "identity_rules"
require_relative "task_launch_dispatch"
require_relative "evidence"
require_relative "state_validate_gate"
require_relative "audit_tools"
require_relative "handoff"

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
  when "dispatch"
    if help_requested?(argv)
      print_command_help("dispatch")
      exit 0
    end
    dispatch(argv)
  when "evidence"
    evidence(argv)
  when "handoff"
    if help_requested?(argv)
      print_command_help("handoff")
      exit 0
    end
    handoff(argv)
  when "init"
    init_config(argv)
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

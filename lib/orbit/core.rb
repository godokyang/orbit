# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "set"
require "securerandom"
require "shellwords"
require "time"
require "yaml"

SCRIPT_PATH = defined?(ORBIT_SCRIPT_PATH) ? ORBIT_SCRIPT_PATH : File.expand_path($PROGRAM_NAME)
SKILL_ROOT = defined?(ORBIT_ROOT) ? ORBIT_ROOT : File.expand_path("..", File.dirname(SCRIPT_PATH))
TEMPLATE_ROOT = File.join(SKILL_ROOT, "assets", "templates")

def orbit_version_from_package
  package_path = File.join(SKILL_ROOT, "package.json")
  version = JSON.parse(File.read(package_path))["version"].to_s.strip
  raise "package.json version is empty" if version.empty?

  version
rescue StandardError => e
  abort "orbit: failed to load version from #{package_path}: #{e.message}"
end

VERSION = orbit_version_from_package.freeze

DEFAULT_RULE_REFERENCES = {
  "common" => [
    {
      "path" => "SKILL.md",
      "load_policy" => "required",
      "reason" => "Orbit skill trigger boundary, runtime workflow, role behavior, and reporting contract."
    },
    {
      "path" => "references/runtime/guide.md",
      "load_policy" => "required",
      "reason" => "Runtime operating rules for task, evidence, gate, audit, and handoff."
    },
    {
      "path" => "references/runtime/core-operating-model.md",
      "load_policy" => "conditional",
      "reason" => "Protocol field details; read when task, evidence, state, or identity semantics are unclear."
    }
  ],
  "lead" => [
    {
      "path" => "references/runtime/coding-guideline.md",
      "load_policy" => "required",
      "reason" => "Lead/coder implementation closure and coding evidence rules."
    }
  ],
  "coder" => [
    {
      "path" => "references/runtime/coding-guideline.md",
      "load_policy" => "required",
      "reason" => "Implementation closure and coding evidence rules."
    }
  ],
  "reviewer" => [
    {
      "path" => "references/runtime/quality-outcome-and-review.md",
      "load_policy" => "required",
      "reason" => "Independent review and quality outcome judgment rules."
    }
  ],
  "tester" => [
    {
      "path" => "references/runtime/testing-guideline.md",
      "load_policy" => "required",
      "reason" => "Real behavior testing, coverage, and test evidence rules."
    }
  ],
  "handoff_receiver" => []
}.freeze

HELP = <<~HELP
  orbit #{VERSION}

  Usage:
    orbit --help
    orbit version
    orbit audit --task PATH --state PATH --evidence PATH [--handoff PATH] [--compact-summary PATH] --json
    orbit init --operation-mode solo|team [--force]
    orbit instances status --json
    orbit bind-pane --instance NAME --pane PANE [--tab TAB] [--workspace WORKSPACE] [--canonical-pane PANE] --json
    orbit classify-intent --text TEXT --json
    orbit compact-evidence --task PATH --evidence PATH [--handoff PATH] [--output PATH] --json
    orbit docs alias --id ID --path PATH [--registry PATH] --json
    orbit docs check [--registry PATH] [--open-dir PATH] [--archive-dir PATH] --json
    orbit evidence init --output PATH
    orbit evidence add --file PATH --kind KIND --status STATUS --summary SUMMARY [--task PATH] [--decision-record JSON] [--data-classification JSON] [--retention-policy JSON] [--trust-repair JSON]
    orbit evidence from-report --file PATH --report PATH [--kind KIND] [--status STATUS] [--summary SUMMARY]
    orbit evidence submit --file PATH --report PATH [--task PATH] --json
    orbit evidence waive --file PATH --waiver PATH --json
    orbit evidence attach-rule --file PATH --rule-resolution PATH --task PATH
    orbit evidence show --file PATH --json
    orbit handoff --task PATH --state PATH --evidence PATH [--output PATH] [--record-state] --json
    orbit hook pre-command|pre-edit|pre-evidence|pre-start|pre-idle --intent-json PATH|- --json
    orbit notice add --task PATH --event EVENT --evidence PATH [--to-instance INSTANCE] --json
    orbit notice list --role ROLE --json
    orbit notice ack --role ROLE --id ID --json
    orbit runtime register|ack-session [INSTANCE] --json
    orbit dispatch --task PATH --to INSTANCE [--pane PANE] [--reply-to PANE] [--manual-payload] [--dry-run] --json
    orbit rules resolve --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]
    orbit rules print-context --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]
    orbit start INSTANCE [--cwd PROJECT_ROOT] [--layout auto|same-tab|new-tab] [--force] [--dry-run] [--json]
    orbit state progress --message TEXT [--evidence PATH] [--state PATH]
    orbit state start --task PATH [--owner-role ROLE] [--state PATH]
    orbit state transition --to PHASE [--evidence PATH] [--reason TEXT] [--state PATH]
    orbit state show --json [--state PATH]
    orbit tools detect --json
    orbit tools doctor --json
    orbit wait-gate --task PATH --evidence PATH --json
    orbit whoami --json [--task PATH]
    orbit new-task --task-type TYPE --output PATH [--operation-mode solo|team] [--implementation-authority ROLE --assigned-instance INSTANCE]
    orbit validate [--task PATH] [--evidence PATH] [--state PATH] [--changed-files FILE[,FILE...]] [--json]

  Commands:
    audit       审计 task、evidence 和 loop state 的一致性。
    bind-pane   绑定 Herdr pane 到 Orbit instance。
    classify-intent  根据用户请求输出 Orbit workflow 默认策略。
    compact-evidence  生成 durable evidence summary，不复制 transient runtime artifacts。
    dispatch    生成或投递 task 给指定 agent instance。
    docs        管理 stable docs registry 并检查 docs lifecycle。
    evidence    初始化、追加、挂载规则解析和读取 evidence manifest。
    handoff     输出机器可读的 handoff packet。
    hook         运行 Herdr-aware preflight guardrail。
    init         初始化 .orbit 项目配置。
    instances    读取 Orbit instance binding 和 health 状态。
    new-task    根据模板创建 task contract。
    notice      管理 owner completion notice runtime inbox。
    runtime     注册、刷新或确认 Orbit-Herdr runtime session。
    rules       解析本轮默认规则、项目规则、task 规则和 rule packs。
    start        根据 instances.yaml 启动或预览 agent instance。
    state        读取或管理 Orbit loop state。
    tools        检测 Herdr runtime adapter、手动 artifact 和执行工具。
    validate    校验 Orbit config、task、evidence 和 state 文件。
    wait-gate   检查 task required gates 当前是否满足。
    whoami      解析运行时 role identity。
    version      输出 CLI 版本。

  Subcommand help:
    orbit audit --help
    orbit compact-evidence --help
    orbit evidence --help
    orbit dispatch --help
    orbit docs --help
    orbit handoff --help
    orbit hook --help
    orbit notice --help
    orbit runtime --help
    orbit rules print-context --help
    orbit rules resolve --help
    orbit validate --help
    orbit wait-gate --help
HELP

COMMAND_HELP = {
  "audit" => <<~HELP,
    Usage:
      orbit audit --task PATH --state PATH --evidence PATH [--handoff PATH] [--compact-summary PATH] --json

    Audits task, loop state, and evidence consistency before done/handoff.

    Required:
      --task PATH      Structured orbit-task-v1 YAML file.
      --state PATH     orbit-loop-state-v1 YAML file.
      --evidence PATH  orbit-evidence-v1 JSON/YAML manifest file.
      --json           Emit machine-readable audit result.

    Optional:
      --handoff PATH           Handoff packet to compare against current evidence
                               (reports drift in retention_drift_summary).
      --compact-summary PATH   Durable evidence summary to validate and reference
                               (validates compact_summary schema; reports
                               retention_summary.compact_summary_present).

    Notes:
      --evidence expects a manifest file, not an evidence directory.
      Create one with: orbit evidence init --output .orbit/evidence.json
  HELP
  "dispatch" => <<~HELP,
    Usage:
      orbit dispatch --task PATH --to INSTANCE [--pane PANE] [--reply-to PANE] [--manual-payload] [--dry-run] --json

    Builds a machine-readable task dispatch packet for an agent instance.

    Required:
      --task PATH       Orbit task contract to send.
      --to INSTANCE     Target instance from .orbit/instances.yaml.
      --json            Emit the dispatch packet/result as JSON.

    Options:
      --pane PANE       Repair/override Herdr pane id. Normal delivery uses the target instance binding.
      --reply-to PANE   Pane id to place in the herdr-msg reply-to header.
      --manual-payload  Emit a manual delivery artifact instead of sending through Herdr.
      --dry-run         Print the dispatch plan without sending.

    Notes:
      Herdr is the only official direct delivery adapter.
      Manual payloads are artifacts; they do not prove delivery.
      Completion should be collected from structured evidence and wait-gate;
      Herdr agent-status is only runtime availability context.
  HELP
  "classify-intent" => <<~HELP,
    Usage:
      orbit classify-intent --text TEXT --json

    Classifies a user request into an Orbit workflow intent and returns the
    default task/evidence/gate policy. This is deterministic keyword routing,
    not semantic LLM classification.

    Required:
      --text TEXT  User request or summarized request.
      --json       Emit machine-readable classification.
  HELP
  "runtime" => <<~HELP,
    Usage:
      orbit runtime register --json
      orbit runtime ack-session INSTANCE --json

    Manages Orbit-Herdr runtime session diagnostics. Herdr-verified runtime
    identity is unavailable until Herdr exposes trusted caller-pane proof.

    Notes:
      Herdr environment variables are probe input only. A session is
      dispatch-ready only after Orbit can match runtime state with a live Herdr
      pane/agent probe.
  HELP
  "compact-evidence" => <<~HELP,
    Usage:
      orbit compact-evidence --task PATH --evidence PATH [--handoff PATH] [--output PATH] --json

    Builds a durable evidence summary from task/evidence/handoff inputs. The
    summary keeps counts, latest verdicts, content hashes, rule references, and
    artifact references; it does not copy full transient logs or rule context.

    Required:
      --task PATH      Structured orbit-task-v1 YAML file.
      --evidence PATH  orbit-evidence-v1 JSON/YAML manifest file.
      --json           Emit machine-readable durable summary.

    Options:
      --handoff PATH   Handoff packet to summarize and hash.
      --output PATH    Write the durable summary to PATH.
  HELP
  "docs" => <<~HELP,
    Usage:
      orbit docs alias --id ID --path PATH [--registry PATH] --json
      orbit docs check [--registry PATH] [--open-dir PATH] [--archive-dir PATH] --json

    Maintains a stable docs registry so evidence can reference durable doc ids
    instead of rewriting historical paths after docs move.

    Subcommands:
      alias   Create or update a stable doc id with current path and content hash.
      check   Validate alias targets and report open/archive lifecycle issues.

    Options:
      --registry PATH  Defaults to .orbit/docs-registry.json.
      --open-dir PATH  Defaults to docs/open when present.
      --archive-dir PATH  Defaults to docs/archive when present.
  HELP
  "handoff" => <<~HELP,
    Usage:
      orbit handoff --task PATH --state PATH --evidence PATH [--output PATH] [--record-state] --json

    Builds a machine-readable handoff packet from task, state, evidence, audit,
    tool discovery, and rule-pack context.

    Required:
      --task PATH      Structured orbit-task-v1 YAML file.
      --state PATH     orbit-loop-state-v1 YAML file.
      --evidence PATH  orbit-evidence-v1 JSON/YAML manifest file.
      --json           Emit machine-readable handoff packet.

    Options:
      --output PATH     Write the handoff packet to PATH.
      --record-state    Record --output path into loop state artifacts.

    Notes:
      --evidence expects a manifest file, not an evidence directory.
      Create one with: orbit evidence init --output .orbit/evidence.json
  HELP
  "hook" => <<~HELP,
    Usage:
      orbit hook pre-command --intent-json PATH|- --json
      orbit hook pre-edit --intent-json PATH|- --json
      orbit hook pre-evidence --intent-json PATH|- --json
      orbit hook pre-start --intent-json PATH|- --json
      orbit hook pre-idle --intent-json PATH|- --json

    Runs a low-latency Orbit guardrail for Herdr-integrated agent clients.
    Hooks are advisory preflight checks; authoritative enforcement remains in
    task, evidence, validate, audit, and wait-gate commands.

    Required:
      --intent-json PATH|-  JSON intent from the caller. Missing intent fails closed.
      --json               Emit machine-readable hook output.

    Notes:
      Caller-supplied liveness, manual payload, transport binding, or explicit
      pane claims are ignored as live proof. Orbit derives identity and task
      authority from project config, task contracts, evidence, and Herdr probes.
  HELP
  "notice" => <<~HELP,
    Usage:
      orbit notice add --task PATH --event EVENT --evidence PATH [--to-instance INSTANCE] --json
      orbit notice list --role ROLE --json
      orbit notice ack --role ROLE --id ID --json

    Manages the Phase A completion notice inbox under .orbit/runtime/notices.
    Notice records are protocol state; this command does not claim Herdr pane
    delivery capability.

    Events:
      implementation_complete   From task implementation authority/assigned instance,
                                or a valid implementation_instance_override.
      review_complete           From reviewer role.
      test_complete             From tester role.
      handoff_ready             From owner, implementation authority, or gate role.
      blocked_needs_owner       From owner, implementation authority, or gate role.

    Required:
      --json  Emit machine-readable notice output.
  HELP
  "rules resolve" => <<~HELP,
    Usage:
      orbit rules resolve --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]

    Resolves the rule inputs a role must load for the current Orbit task.
    This is deterministic code, not an LLM merge.

    Required:
      --json           Emit machine-readable rule resolution.

    Options:
      --task PATH      Structured orbit-task-v1 YAML file.
      --evidence PATH  Evidence manifest used only for override-backed identity checks.
      --role ROLE      Resolve as ROLE when ORBIT_INSTANCE is not set.
      --instance NAME  Resolve as configured instance NAME.
      --output PATH    Write the JSON resolution artifact to PATH.

    Notes:
      Orbit default rules are always included. Project rules from
      .orbit/roles.yaml only add project-specific rules and never replace
      the default Orbit runtime rules.
  HELP
  "rules print-context" => <<~HELP,
    Usage:
      orbit rules print-context --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]

    Prints the ordered rule context an agent should load for this turn.
    This is deterministic code, not an LLM merge.

    Required:
      --json           Emit machine-readable context instructions.

    Options:
      --task PATH      Structured orbit-task-v1 YAML file.
      --evidence PATH  Evidence manifest used only for override-backed identity checks.
      --role ROLE      Resolve as ROLE when ORBIT_INSTANCE is not set.
      --instance NAME  Resolve as configured instance NAME.
      --output PATH    Write the JSON context artifact to PATH.

    Notes:
      Orbit default rules, project rules, task rules, and configured rule
      packs are all listed separately. Project rules are additive and never
      suppress the default Orbit runtime rules.
  HELP
  "start" => <<~HELP,
    Usage:
      orbit start INSTANCE [--cwd PROJECT_ROOT] [--layout auto|same-tab|new-tab] [--force] [--dry-run] [--json]

    Starts or previews an agent instance from .orbit/instances.yaml.

    Required:
      INSTANCE         Instance name from .orbit/instances.yaml.

    Options:
      --cwd PROJECT_ROOT  Orbit project root for the agent. Defaults to current directory.
      --layout MODE     auto, same-tab, or new-tab. Defaults to auto.
      --force           Start anyway when an existing binding cannot be proven alive.
      --dry-run         Print the command/env/cwd plan without starting the agent.
      --json            Emit the launch plan or launch result as JSON.

    Notes:
      command is executed as argv, not through a shell string.
      Dry-run is the recommended way to audit instance command/env wiring.
      --cwd must be the same Orbit project root that owns .orbit config.
      Herdr is required for automatic create/wake/reuse.
      When an instance already has a binding, start only reuses a live-detected
      agent. If the binding cannot be proven alive, it exits with needs_force.
      --force replaces Orbit's current binding but does not kill old processes.
  HELP
  "validate" => <<~HELP,
    Usage:
      orbit validate [--task PATH] [--evidence PATH] [--state PATH]
                     [--changed-files FILE[,FILE...]] [--json]

    Validates project config plus optional structured task, evidence manifest,
    and loop-state files.

    Options:
      --task PATH                Structured orbit-task-v1 YAML file.
      --evidence PATH            orbit-evidence-v1 JSON/YAML manifest file.
      --state PATH               orbit-loop-state-v1 YAML file.
      --changed-files FILE,...   Comma-separated list of changed file paths to
                                 check against task scope.include / scope.exclude
                                 patterns. Can be repeated to add more files.
      --json                     Emit machine-readable validation result.

    Notes:
      --evidence expects a manifest file, not an evidence directory.
      Create one with: orbit evidence init --output .orbit/evidence.json
      --changed-files is typically sourced from `git diff --name-only`.
  HELP
  "evidence" => <<~HELP,
    Usage:
      orbit evidence init --output PATH
      orbit evidence add --file PATH --kind KIND --status STATUS --summary SUMMARY [--task PATH] [--decision-record JSON] [--data-classification JSON] [--retention-policy JSON] [--trust-repair JSON]
      orbit evidence from-report --file PATH --report PATH [--kind KIND] [--status STATUS] [--summary SUMMARY]
      orbit evidence submit --file PATH --report PATH [--task PATH] --json
      orbit evidence waive --file PATH --waiver PATH --json
      orbit evidence attach-rule --file PATH --rule-resolution PATH --task PATH
      orbit evidence show --file PATH --json

    Initializes, appends to, and reads an evidence manifest.

    Subcommands:
      init          Initialize a new evidence manifest file.
      add           Append a free-form evidence record.
      from-report   Append an evidence record from a structured report.
      submit        Validate and append a structured gate record from a report.
      waive         Append a waiver record to the evidence manifest.
      attach-rule   Attach a rule resolution artifact to the manifest.
      show          Print the evidence manifest as JSON.

    Key options for submit:
      --file PATH    Evidence manifest file to append to.
      --report PATH  Structured review or test report (YAML).
      --task PATH    Task contract for role_execution_context hashing
                     (task_sha256 + role_config_sha256).
      --json         Emit machine-readable submit result.

    Notes:
      --task PATH is required for strict write_policy_enforcement.
      Without --task, role_execution_context.task_sha256 will be absent and
      strict gates will remain blocked.
      Review/test pass records must use current role_execution_context fields.
  HELP
  "wait-gate" => <<~HELP
    Usage:
      orbit wait-gate --task PATH --evidence PATH --json

    Checks whether the task's required review/test gates currently pass.

    Required:
      --task PATH      Structured orbit-task-v1 YAML file.
      --evidence PATH  orbit-evidence-v1 JSON/YAML manifest file.
      --json           Emit machine-readable gate status.

    Notes:
      This command does not replace reviewer/tester judgment. It only reads
      evidence records and reports whether the latest required gate records pass.
  HELP
}.freeze

def print_help
  puts HELP
end

def print_command_help(command)
  puts(COMMAND_HELP.fetch(command))
end

def help_requested?(args)
  args.length == 1 && ["-h", "--help", "help"].include?(args.first)
end

def usage_error(message)
  warn message
  warn "Run `orbit --help` for usage."
  exit 64
end

def sha256_file(path)
  return nil unless path && File.file?(path)

  Digest::SHA256.file(path).hexdigest
rescue StandardError
  nil
end

def option_value(args, option)
  value = args.shift
  usage_error("Missing value for #{option}") if value.nil? || value.start_with?("--")

  value
end

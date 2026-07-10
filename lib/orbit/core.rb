# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "pathname"
require "set"
require "securerandom"
require "shellwords"
require "time"
require "yaml"

SCRIPT_PATH = defined?(ORBIT_SCRIPT_PATH) ? ORBIT_SCRIPT_PATH : File.expand_path($PROGRAM_NAME)
SKILL_ROOT = defined?(ORBIT_ROOT) ? ORBIT_ROOT : File.expand_path("..", File.dirname(SCRIPT_PATH))
ORBIT_SKILL_DIR = File.join(SKILL_ROOT, "skills", "orbit")
TEMPLATE_ROOT = File.join(ORBIT_SKILL_DIR, "assets", "templates")

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
      "path" => "skills/orbit/SKILL.md",
      "load_policy" => "required",
      "reason" => "Orbit skill trigger boundary, runtime workflow, role behavior, and reporting contract."
    },
    {
      "path" => "skills/orbit/references/runtime/guide.md",
      "load_policy" => "required",
      "reason" => "Runtime operating rules for task, evidence, gate, audit, and handoff."
    },
    {
      "path" => "skills/orbit/references/runtime/core-operating-model.md",
      "load_policy" => "conditional",
      "reason" => "Protocol field details; read when task, evidence, state, or identity semantics are unclear."
    }
  ],
  "lead" => [
    {
      "path" => "skills/orbit/references/runtime/coding-guideline.md",
      "load_policy" => "required",
      "reason" => "Lead/coder implementation closure and coding evidence rules."
    }
  ],
  "coder" => [
    {
      "path" => "skills/orbit/references/runtime/coding-guideline.md",
      "load_policy" => "required",
      "reason" => "Implementation closure and coding evidence rules."
    }
  ],
  "reviewer" => [
    {
      "path" => "skills/orbit/references/runtime/quality-outcome-and-review.md",
      "load_policy" => "required",
      "reason" => "Independent review and quality outcome judgment rules."
    }
  ],
  "tester" => [
    {
      "path" => "skills/orbit/references/runtime/testing-guideline.md",
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
    orbit artifact inspect --path PATH --task PATH --id ID --producer-command TEXT [--lifecycle transient|durable] --json
    orbit init --operation-mode solo|team [--force]
    orbit instances status --json
    orbit bind-pane --instance NAME --pane PANE [--tab TAB] [--workspace WORKSPACE] [--canonical-pane PANE] --json
    orbit classify-intent --text TEXT --json
    orbit classify-intent --text TEXT --intent INTENT --reason TEXT [--task PATH] --json
    orbit compact-evidence --task PATH --evidence PATH [--handoff PATH] [--output PATH] --json
    orbit docs alias --id ID --path PATH [--registry PATH] --json
    orbit docs check [--registry PATH] [--open-dir PATH] [--archive-dir PATH] --json
    orbit evidence init --output PATH [--task PATH]
    orbit evidence add --file PATH --kind KIND --status STATUS --summary SUMMARY [--task PATH] [--changed-file PATH] [--verification TEXT] [--no-change-reason TEXT] [--artifact-ref JSON|@FILE]
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
    orbit metrics capture --task PATH --evidence PATH [--stage baseline|after] [--duration-seconds N] [--tokens N] --json
    orbit metrics record --metric NAME [--task PATH] [metric dimensions] --json
    orbit metrics report [--window-days 30] --json
    orbit runtime register|refresh-session|ack-session [INSTANCE] --json
    orbit dispatch --task PATH --to INSTANCE [--pane PANE] [--reply-to PANE] [--manual-payload] [--dry-run] --json
    orbit rules resolve --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]
    orbit rules print-context --json [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]
    orbit revision create --task PATH --reason TEXT --change-type TYPE[,TYPE...] --json
    orbit task draft --task-type TYPE --output PATH [new-task options] [--json|--verbose]
    orbit task start --task PATH [--evidence PATH] [--state PATH] [--json|--verbose]
    orbit start INSTANCE [--cwd PROJECT_ROOT] [--layout auto|same-tab|new-tab] [--force] [--dry-run] [--json]
    orbit status [--task PATH] [--state PATH] [--evidence PATH] [--json]
    orbit next [--task PATH] [--state PATH] [--evidence PATH] [--json]
    orbit state progress --message TEXT [--evidence PATH] [--state PATH]
    orbit state start --task PATH [--owner-role ROLE] [--state PATH]
    orbit state transition --to PHASE [--evidence PATH] [--reason TEXT] [--state PATH]
    orbit state show --json [--state PATH]
    orbit tools detect --json
    orbit tools doctor --json
    orbit test-hook run --task PATH --journey ID [--dry-run] --json
    orbit wait-gate --task PATH --evidence PATH --json
    orbit whoami --json [--task PATH]
    orbit new-task --task-type TYPE --output PATH [--operation-mode solo|team] [--implementation-authority ROLE --assigned-instance INSTANCE] [--risk-level LEVEL] [--change-surface SURFACE] [--risk-sink SINK] [--real-path-required] [--artifact-provenance-required]
    orbit validate [--task PATH] [--evidence PATH] [--state PATH] [--stage draft|execution-ready] [--changed-files FILE[,FILE...]] [--json]

  Commands:
    audit       审计 task、evidence 和 loop state 的一致性。
    artifact    为当前 task 生成可验证的结构化 artifact reference。
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
    metrics      记录并汇总本地 30 天试用指标，不保存 prompt 内容。
    new-task    根据模板创建 task contract。
    notice      管理 owner completion notice runtime inbox。
    next        输出当前 Orbit 状态派生出的下一条建议命令。
    runtime     注册、刷新或确认 Orbit-Herdr runtime session。
    rules       解析本轮默认规则、项目规则、task 规则和 rule packs。
    revision    为已启动 task 创建显式 revision 并精确失效相关 evidence。
    start        根据 instances.yaml 启动或预览 agent instance。
    status       从 task/state/evidence/runtime 派生一屏只读状态摘要。
    state        读取或管理 Orbit loop state。
    task         用一条高层命令创建草稿或启动完整执行闭环。
    tools        检测 Herdr runtime adapter、手动 artifact 和执行工具。
    test-hook    运行 task journey 引用的项目级真实路径测试 hook。
    validate    校验 Orbit config、task、evidence 和 state 文件。
    wait-gate   检查 task required gates 当前是否满足。
    whoami      解析运行时 role identity。
    version      输出 CLI 版本。

  Subcommand help:
    orbit audit --help
    orbit artifact --help
    orbit compact-evidence --help
    orbit evidence --help
    orbit dispatch --help
    orbit docs --help
    orbit handoff --help
    orbit hook --help
    orbit notice --help
    orbit metrics --help
    orbit status --help
    orbit test-hook --help
    orbit runtime --help
    orbit task --help
    orbit rules print-context --help
    orbit rules resolve --help
    orbit revision --help
    orbit validate --help
    orbit wait-gate --help
HELP

COMMAND_HELP = {
  "bind-pane" => <<~HELP,
    Usage:
      orbit bind-pane --instance NAME --pane PANE [--tab TAB]
                      [--workspace WORKSPACE] [--canonical-pane PANE] --json

    Records a Herdr pane binding hint for an Orbit instance. A binding is not
    trusted runtime identity or proof that the target is alive.
  HELP
  "init" => <<~HELP,
    Usage:
      orbit init --operation-mode solo|team [--force]

    Creates the starter .orbit configuration for the current project.
    Existing files are preserved unless --force is explicitly supplied.
  HELP
  "instances" => <<~HELP,
    Usage:
      orbit instances status [--repair-binding] --json

    Reports configured agent instances and resolver health. Status is read-only
    unless --repair-binding is explicitly supplied.
  HELP
  "new-task" => <<~HELP,
    Usage:
      orbit new-task --task-type TYPE --output PATH
                     [--operation-mode solo|team]
                     [--implementation-authority ROLE --assigned-instance NAME]
                     [--risk-level light|standard|strict|release]
                     [--change-surface SURFACE] [--risk-sink SINK]
                     [--real-path-required] [--artifact-provenance-required]

    Creates a draft task contract. Prefer `orbit task draft` for concise output
    and `orbit task start` after filling the concrete execution contract.
  HELP
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
  "artifact" => <<~HELP,
    Usage:
      orbit artifact inspect --path PATH --task PATH --id ID
                             --producer-command TEXT
                             [--lifecycle transient|durable] --json

    Builds a structured artifact reference for an existing project-relative
    file. The reference binds file bytes to the current git HEAD and task
    revision; validators recheck these facts whenever the gate is evaluated.

    Required:
      --path PATH              Existing project-relative artifact path.
      --task PATH              Task contract that produced the artifact.
      --id ID                  Stable artifact id referenced by later gates.
      --producer-command TEXT  Exact command or action that produced it.
      --json                   Emit orbit-artifact-ref-v1 JSON.

    Options:
      --lifecycle VALUE        transient (default) or durable.
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
      orbit classify-intent --text TEXT --intent INTENT --reason TEXT
                            [--task PATH] --json

    Reports every matched workflow signal, candidate conflict, and the selected
    advisory workflow intent. Generic words such as 问题 are not discussion signals.

    Required:
      --text TEXT  User request or summarized request.
      --json       Emit machine-readable classification.

    Options:
      --intent VALUE  Explicitly override the selected intent.
      --reason TEXT   Required audit reason whenever --intent is supplied.
      --task PATH     Read the authoritative structured risk from an Orbit task.

    Notes:
      Natural-language intent and risk are recommendations only. They cannot
      lower task_risk, change structured surfaces/sinks, or skip required gates.
  HELP
  "runtime" => <<~HELP,
    Usage:
      orbit runtime register --json
      orbit runtime refresh-session --json
      orbit runtime ack-session INSTANCE --json

    Manages Orbit-Herdr runtime sessions. With a controlled orbit-proof provider,
    register redeems a one-time nonce/project/instance-bound challenge; without
    that provider it remains diagnostic and cannot produce verified identity.

    Notes:
      Herdr environment variables are probe input only. A session is
      dispatch-ready only after Orbit can match runtime state with a live Herdr
      pane/agent probe.
  HELP
  "rules" => <<~HELP,
    Usage:
      orbit rules resolve --json [options]
      orbit rules print-context [--json|--verbose] [options]

    Resolves additive Orbit, project, task, and role-pack rules. Use
    `orbit rules print-context` for a concise list of active required files;
    use --json or --verbose for the full protocol record.
  HELP
  "revision" => <<~HELP,
    Usage:
      orbit revision create --task PATH --reason TEXT
                            --change-type TYPE[,TYPE...] [--state PATH] --json

    Freezes task semantics into explicit revisions. Edit the intended task
    fields, then create a revision with a reason and all applicable change
    types. Orbit records changed fields and invalidates only affected evidence.

    Change types:
      scope, acceptance, quality_outcome, implementation, review_contract,
      test_contract, release_contract, risk, rules, runtime, documentation.
  HELP
  "compact-evidence" => <<~HELP,
    Usage:
      orbit compact-evidence --task PATH --evidence PATH [--handoff PATH] [--output PATH] --json
      orbit compact-evidence --task PATH --evidence PATH [--output PATH]
                             [--cleanup-transient|--dry-run-cleanup] --json

    Builds a durable evidence summary from task/evidence/handoff inputs. The
    summary keeps counts, latest verdicts, content hashes, rule references, and
    artifact references; it does not copy full transient logs or rule context.

    Required:
      --task PATH      Structured orbit-task-v1 YAML file.
      --evidence PATH  orbit-evidence-v1 JSON/YAML manifest file.
      --json           Emit machine-readable durable summary.

    Options:
      --handoff PATH   Handoff packet to summarize and hash.
      --output PATH    Write the one-per-task durable summary to PATH. Defaults
                       to knowledge.durable_summary_dir/<task>.json.
      --cleanup-transient  After summarizing, remove only structured transient
                           refs under Orbit runtime directories.
      --dry-run-cleanup    Show the same cleanup set without deleting files.
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
      --output PATH     Write the handoff packet to PATH. Defaults to the single
                        canonical .orbit/handoffs/<task>.json path.
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
  "metrics" => <<~HELP,
    Usage:
      orbit metrics capture --task PATH --evidence PATH
                            [--stage baseline|after]
                            [--duration-seconds N] [--tokens N] --json
      orbit metrics record --task PATH --metric workflow_failure --failure-kind identity|schema|revision --json
      orbit metrics record --task PATH --metric independent_defect --source reviewer|tester --severity high|medium|low --json
      orbit metrics record --task PATH --metric post_gate_defect --severity P0|P1|P2 --json
      orbit metrics record --task PATH --metric status_question --topic status|next|who --json
      orbit metrics record --metric automatic_session --outcome verified|pending|manual --json
      orbit metrics report [--window-days N] --json

    Stores local structured trial events in .orbit/metrics/trial-events.jsonl.
    Capture derives artifact footprint and implementation-to-gate wait from the
    current task/evidence. Task-scoped count metrics require --task and bind its
    immutable task_id. Record accepts enum/count fields only: no prompt, report
    prose, or user content is persisted.
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
      orbit rules print-context [--verbose] [--task PATH] [--evidence PATH] [--role ROLE] [--instance NAME] [--output PATH]

    Prints the ordered rule context an agent should load for this turn.
    This is deterministic code, not an LLM merge.

    Options:
      --task PATH      Structured orbit-task-v1 YAML file.
      --evidence PATH  Evidence manifest used only for override-backed identity checks.
      --role ROLE      Resolve as ROLE when ORBIT_INSTANCE is not set.
      --instance NAME  Resolve as configured instance NAME.
      --output PATH    Write the JSON context artifact to PATH.
      --json           Emit the complete machine-readable context.
      --verbose        Alias for the complete protocol output.

    Notes:
      Orbit default rules, project rules, task rules, and configured rule
      packs are all listed separately. Project rules are additive and never
      suppress the default Orbit runtime rules.
  HELP
  "state" => <<~HELP,
    Usage:
      orbit state show --json [--state PATH]
      orbit state start --task PATH [--owner-role ROLE] [--state PATH]
      orbit state progress --message TEXT [--evidence PATH] [--state PATH]
      orbit state transition --to PHASE [--evidence PATH] [--reason TEXT] [--state PATH]

    Reads or advances the durable Orbit loop state. `task start` is the shorter
    high-level entry point for validating and starting a new task.
  HELP
  "task" => <<~HELP,
    Usage:
      orbit task draft --task-type TYPE --output PATH [new-task options] [--json|--verbose]
      orbit task start --task PATH [--evidence PATH] [--state PATH] [--json|--verbose]

    High-level workflow:
      draft  Create a risk-aware task draft with concise next steps.
      start  Validate execution readiness, freeze the revision, initialize and
             attach evidence/rules, then start loop state in order.

    Human output is concise by default. Use --json or --verbose for the full
    protocol packet.
  HELP
  "tools" => <<~HELP,
    Usage:
      orbit tools detect --json
      orbit tools doctor --json

    Reports execution and transport capabilities without upgrading preview or
    manual signals into trusted automatic capability.
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
  "status" => <<~HELP,
    Usage:
      orbit status [--task PATH] [--state PATH] [--evidence PATH] [--json]
      orbit next [--task PATH] [--state PATH] [--evidence PATH] [--json]

    Derives the current task, risk, runtime identity, implementation/gate
    activity, blockers, completion meaning, and next command from existing
    task, loop-state, evidence, and runtime files. It never writes state.

    Options:
      --task PATH      Override the task referenced by loop state.
      --state PATH     Loop state; defaults to .orbit/loop-state.yaml.
      --evidence PATH  Override evidence discovery from loop state/task name.
      --json           Emit the complete derived read model.

    Completion:
      implemented_not_independently_accepted means implementation evidence
      exists but required fresh-context review/test acceptance is still missing.
  HELP
  "test-hook" => <<~HELP,
    Usage:
      orbit test-hook run --task PATH --journey ID [--dry-run] --json

    Runs the argv command configured in .orbit/test-hooks.yaml for one task
    user journey. Orbit captures the provider result but does not implement
    Android, browser, or cross-system runners itself.

    Required:
      --task PATH       Task containing the user_journeys contract.
      --journey ID      Journey id whose configured test_hook should run.
      --json            Emit command, provider, status, output, and duration.

    Options:
      --dry-run         Resolve and print the hook without executing it.
  HELP
  "validate" => <<~HELP,
    Usage:
      orbit validate [--task PATH] [--evidence PATH] [--state PATH]
                     [--stage draft|execution-ready]
                     [--changed-files FILE[,FILE...]] [--json]

    Validates project config plus optional structured task, evidence manifest,
    and loop-state files.

    Options:
      --task PATH                Structured orbit-task-v1 YAML file.
      --evidence PATH            orbit-evidence-v1 JSON/YAML manifest file.
      --state PATH               orbit-loop-state-v1 YAML file.
      --stage STAGE              draft (default) or execution-ready.
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
      orbit evidence add --file PATH --kind KIND --status STATUS --summary SUMMARY [--task PATH] [--changed-file PATH] [--verification TEXT] [--no-change-reason TEXT] [--artifact-ref JSON|@FILE]
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

    Implementation PASS:
      --changed-file PATH       Repeatable project-relative changed file.
      --verification TEXT       Repeatable verification result.
      --no-change-reason TEXT   Required instead of changed files for a valid
                                no-change implementation.
      --artifact-ref JSON|@FILE Repeatable orbit-artifact-ref-v1 reference.

    Notes:
      --task PATH is required for strict write_policy_enforcement.
      Without --task, role_execution_context.task_sha256 will be absent and
      strict gates will remain blocked.
      Review/test pass records must use current role_execution_context fields.
  HELP
  "wait-gate" => <<~HELP,
    Usage:
      orbit wait-gate --task PATH --evidence PATH [--state PATH] --json

    Checks whether the task's required review/test gates currently pass.

    Required:
      --task PATH      Structured orbit-task-v1 YAML file.
      --evidence PATH  orbit-evidence-v1 JSON/YAML manifest file.
      --state PATH     Optional loop state for dynamic parent_goal_status output.
      --json           Emit machine-readable gate status.

    Notes:
      This command does not replace reviewer/tester judgment. It only reads
      evidence records and reports whether the latest required gate records pass.
  HELP
  "whoami" => <<~HELP
    Usage:
      orbit whoami --json [--task PATH]

    Resolves the current configured role and instance, including conflicts and
    permission context. Environment or pane names alone are not trusted proof.
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

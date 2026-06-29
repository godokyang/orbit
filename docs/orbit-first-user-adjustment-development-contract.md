# Orbit 第一用户体验调整实施依据

本文基于 [Orbit 第一用户长期使用复盘](orbit-first-user-experience.md) 和 [Orbit 第一用户体验调整方案](orbit-first-user-adjustment-plan.md) 制定完整开发 contract。它不是新的问题复盘，也不是只覆盖第一阶段的草案；它把三阶段所有调整项落成可拆 task、可改 schema、可改 CLI、可测试、可兼容的开发依据。

## 文档边界

- `orbit-first-user-experience.md`：源复盘，记录长期使用体验、收益和问题域。
- `orbit-first-user-adjustment-plan.md`：调整方案，定义 P0/P1/P2 优先级、覆盖矩阵和 slice 路线。
- `orbit-first-user-adjustment-development-contract.md`：实施依据，定义每个 slice 的用户问题、目标行为、字段草案、CLI 行为、兼容策略、验收标准和测试矩阵。

开发时应以本文为 task 拆分输入；如果本文和调整方案冲突，以调整方案的优先级为准，以本文的字段和测试为实现细化依据。

## 全阶段 Slice 清单

| Phase | Slice | Source |
| --- | --- | --- |
| 1 | `verdict-evidence-level-schema` | P0.3 |
| 1 | `quality-outcome-guardrails` | P0.2 |
| 1 | `parent-goal-status-and-user-next-action` | P0.1、P1.5 |
| 1 | `destructive-action-and-scope-guard` | P0.5 |
| 1 | `role-identity-and-write-policy-minimum` | P0.4 (minimum) |
| 2 | `role-identity-and-write-policy-full` | P0.4 (full) |
| 2 | `evidence-retention-and-compact-defaults` | P1.1 |
| 2 | `runtime-reconcile-and-env-fingerprint` | P1.2 |
| 2 | `gate-lease-and-stale-verdict` | P1.3 |
| 2 | `doc-lifecycle-and-decision-record` | P1.4 |
| 3 | `project-profile-risk-level` | P2.1 |
| 3 | `data-classification-and-retention` | P2.2 |
| 3 | `ci-release-readiness` | P2.3 |
| 3 | `protocol-schema-versioning` | P2.4 |
| 3 | `orbit-dogfood-and-governance` | P2.5 |
| 3 | `landing-governance-and-calibration` | P2.6 |

## 全局兼容策略

第一原则：新规则不能静默改写旧 evidence 的历史含义，但新 task 必须能 fail closed。

- 旧 evidence/report 缺少新字段时，`audit` 输出 `legacy_warning`，不直接让历史 handoff 失效。
- 新 task 一旦声明新能力字段，`validate`、`wait-gate`、`audit` 必须按新规则检查。
- `new-task` 生成的新模板必须包含对应字段骨架；旧 task 不自动迁移。
- `evidence submit` 对新结构严格校验；`evidence add/from-report` 只能生成兼容 record，不能伪造成高 evidence level。
- schema 或 feature version 必须记录在 task、report 或 evidence record 中，避免旧报告被新语义误读。
- 新增 CLI 输出字段必须保持机器可读稳定；人读 summary 只能派生自结构化字段。
- 任何 fail closed 升级都必须有迁移或 opt-in 策略，不能让历史 `.orbit` 目录无法 audit。

## Phase 1：收口语义和用户状态

第一阶段优先处理错误完成、错误放行、误删产物和用户不知道下一步的问题。它的结果应先让 Orbit 的完成语义可靠，再进入规模化治理。

### Slice 1：Verdict Evidence Level Schema

User problem：`PASS` 同时可能表示机械检查、文档可读、质量达标、真实路径通过或 blocker 被诚实记录。用户和 lead 无法仅凭 pass 判断 gate 是否真的满足 task。

Desired behavior：review/test evidence 同时表达 verdict 状态和证据层级。`wait-gate` 按 task 所需最低层级判断 gate ready。

Fields:

```yaml
review_strategy:
  minimum_evidence_level: outcome_quality

test_strategy:
  minimum_evidence_level: real_path_test

evidence_record:
  status: pass
  evidence_level: outcome_quality
  confirmed: []
  assumed: []
  missing: []
  rule_application:
    required_files: []
    applied_rules: []
  residual_risk:
    level: low
    summary: ""
```

Allowed evidence levels:

| Value | Meaning | Gate Use |
| --- | --- | --- |
| `mechanical_check` | File exists, command passed, schema parses, or checklist was mechanically satisfied. | Not enough for quality review by itself. |
| `outcome_quality` | Reviewer judged quality outcome, invalid completions, evidence and residual risk. | Default review minimum for improvement/docs/UX/reliability tasks. |
| `implementation_readiness` | Design or plan is specific enough to authorize implementation. | Design/analysis to coding transition. |
| `real_path_test` | Tester executed representative real user/runtime path with environment recorded. | Required test gate for behavior-changing tasks. |
| `release_readiness` | Release/package/CI/remote state was checked. | Release tasks only. |

Evidence levels are ordered per gate kind, not as one global ladder. `wait-gate` compares a record's `evidence_level` against the minimum **only within the same gate kind**:

- Review gate: `mechanical_check` < `outcome_quality`.
- Design readiness gate: `mechanical_check` < `implementation_readiness`.
- Test gate: `mechanical_check` < `real_path_test`.
- Release gate: `mechanical_check` < `release_readiness`.

`mechanical_check` is the shared floor (“only mechanically satisfied”). A minimum from one gate kind is never satisfied by a level from another kind: a test gate requiring `real_path_test` is not satisfied by a review `outcome_quality` record, a quality review gate requiring `outcome_quality` is not satisfied by `implementation_readiness`, and a design readiness gate requiring `implementation_readiness` is not satisfied by `outcome_quality`.

CLI behavior:

- `new-task` writes minimum evidence level defaults by task type.
- `evidence submit` requires `evidence_level`, `confirmed`, `assumed`, `missing`, `rule_application` and `residual_risk` for review/test pass.
- `wait-gate` rejects pass records below task minimum.
- `validate` reports exact missing field paths.
- `audit` summarizes gate as `status + evidence_level + residual_risk`.
- `handoff` includes latest accepted evidence level for each required gate.

Acceptance:

- Review pass without `evidence_level` cannot satisfy new task gate.
- `mechanical_check` cannot satisfy `outcome_quality` minimum.
- Historical evidence without `evidence_level` audits with legacy warning.
- Handoff shows whether each gate is mechanical, quality, real-path or release-level evidence.

Tests:

- New docs-maintenance task requires `outcome_quality`; review pass without `evidence_level` fails.
- Review pass with `mechanical_check` fails when minimum is `outcome_quality`.
- Design readiness pass with `implementation_readiness` does not satisfy a quality review gate requiring `outcome_quality`.
- Old manifest without `evidence_level` audits with legacy warning.
- Test pass with `real_path_test` satisfies behavior task requiring that level.

### Slice 2：Quality Outcome Guardrails

User problem：改善类任务容易把“动作完成”误当成“质量改善”。Reviewer 可能只检查文档存在、命令通过或 checklist 完成，没有判断用户问题是否被解决。

Desired behavior：改善类、docs maintenance、UX、reliability、architecture、testing improvement task 必须有可审查的 quality outcome 和 invalid completion guards。Review pass 必须证明 outcome 被满足或明确阻塞。

Fields:

```yaml
quality_outcome:
  user_problem: ""
  desired_property: ""
  measurable_thresholds: []
  invalid_completions: []
invalid_completion_guards:
  - id: no_action_only_completion
    description: ""
    evidence_required: ""
review_strategy:
  required_questions:
    - outcome
    - counterexamples
    - evidence_sufficiency
    - residual_risk

review_report:
  quality_outcome_verdict: pass
  quality_question_answers:
    outcome: ""
    counterexamples: ""
    evidence_sufficiency: ""
    residual_risk: ""
  counterexample_cases: []
```

CLI behavior:

- `new-task` seeds quality outcome templates for improvement-like task types.
- `validate` fails new improvement-like tasks with empty quality outcome fields.
- `evidence submit --kind review` requires `quality_outcome_verdict` and required question answers when task requires quality review.
- `wait-gate` refuses review pass if `quality_outcome_verdict` is not `pass`.
- `audit` lists invalid completion guards and whether latest review addressed them.

Acceptance:

- New docs-maintenance task cannot validate with empty `quality_outcome`.
- Review pass that omits counterexample discussion cannot close review gate.
- Partial/fail review remains partial/fail and is not normalized into pass.
- Audit says whether quality outcome is satisfied, not just whether a review exists.

Tests:

- Blank `quality_outcome.user_problem` fails validation.
- Review report says pass but lacks `quality_outcome_verdict`; submit fails.
- `quality_outcome_verdict: fail` blocks wait-gate.
- Valid review answers required questions and passes wait-gate.

### Slice 3：Parent Goal Status And User Next Action

User problem：长任务被切成 slice 后，用户只能看到局部 pass，不知道整体是否完成、谁在等待谁、下一步该做什么。

Desired behavior：Orbit 输出单一 parent goal 视图，包含 objective、done criteria、active slice、remaining blockers、required gates 和 user next action。

Fields:

```yaml
parent_goal:
  id: ""
  objective: ""
  done_criteria: []
  non_goals: []
  required: false

parent_goal_status:
  state: parent_in_progress
  active_slice: ""
  done_criteria_status: []
  remaining_blockers: []
  required_gates: {}
  user_next_action:
    default: wait
    options: []
    waiting_on: ""
    blocked_by: ""
    do_not_do: []
```

Allowed parent states:

- `not_applicable`
- `parent_in_progress`
- `slice_ready`
- `parent_blocked`
- `parent_done_ready`
- `parent_done`

CLI behavior:

- `new-task` includes `parent_goal` for parent/decomposition tasks.
- `state progress` updates active slice and blockers without claiming done.
- `wait-gate` shows gate readiness plus parent state.
- `validate` rejects parent done if criteria are missing or unevidenced.
- `audit` checks child slice pass does not imply parent done.
- `handoff` includes `parent_goal_status`.

Acceptance:

- Child slice pass with remaining criteria reports `parent_in_progress`, not done.
- User next action appears in handoff and user-facing summary.
- Parent done requires evidence for every done criterion.
- Simple non-parent tasks can set `parent_goal.required: false`.

Tests:

- Child slice review pass exists, parent criteria incomplete; audit blocks parent done.
- Parent task lacks `done_criteria`; validate fails.
- Handoff for parent task includes `user_next_action`.
- One-file docs task with `parent_goal.required: false` validates without parent ceremony.

### Slice 4：Destructive Action And Scope Guard

User problem：混合 worktree 中同时有用户改动、runtime artifacts、build outputs 和 Orbit runtime。删除、清理、回退或提交错误路径会破坏 evidence 或用户工作。

Desired behavior：破坏性和 scope-sensitive 操作必须有 dry-run、target list、owner、recoverability、evidence impact 和必要用户确认。

Fields:

```yaml
scope:
  include: []
  exclude: []
artifact_policy:
  generated: exclude_by_default
  build_outputs: exclude_by_default
  orbit_runtime: exclude_by_default
  runtime_artifacts: preserve_or_hash_before_delete
destructive_actions:
  required_protocol: true
  require_user_confirmation: true

destructive_action_plan:
  action: delete
  targets:
    - path: ""
      tracked: false
      owner: agent
      recoverability: hash_only
      evidence_impact: none
  dry_run: true
  user_confirmation:
    required: true
    received: false
```

CLI behavior:

- `validate` checks changed files against scope for new scoped tasks.
- `audit` warns or fails when generated/build/runtime artifacts appear without policy.
- `evidence add` can attach destructive action plan metadata.
- `handoff` lists destructive actions and recovery gaps.
- A later dedicated command can be added, but first implementation can validate plan files attached to evidence.

Acceptance:

- Scope excluding `.orbit/**` fails if `.orbit` runtime files enter implementation changes without waiver.
- Destructive action without dry-run targets and recoverability is rejected or audited as fail.
- Evidence-affecting artifact deletion requires hash or durable summary.
- User-owned or unknown-owned files require explicit confirmation.

Tests:

- Changed file outside `scope.include` causes validate failure.
- Destructive plan missing `recoverability` fails.
- Evidence-affecting artifact deletion with no hash fails.
- Generated build artifact with no policy produces warning or fail by task risk.

### Slice 5：Role Identity And Write Policy Minimum

User problem：identity currently proves only declared role, not which role rules were loaded or whether gate roles avoided mutating implementation files.

Desired behavior：第一阶段记录 enough identity and write-scope data to detect obvious review/test contamination before full sandbox support.

Fields:

```yaml
identity:
  resolved_instance: reviewer
  resolved_role: reviewer
  role_ref: reviewer
  task_sha256: ""
  rules_context_sha256: ""
  role_config_sha256: ""
write_policy:
  expected: no_production_writes
  changed_files: []
  violations: []
```

CLI behavior:

- `evidence submit` records task hash and rules context hash when available.
- `evidence submit` records changed files snapshot or accepts report-provided `changed_files`.
- `wait-gate` warns or blocks when reviewer/tester record has write violations.
- `audit` separates gate role writes from lead/coder implementation writes.

Acceptance:

- New review/test evidence includes task hash and rules context hash.
- Reviewer/tester changed files are visible in audit.
- Strict tasks block gate role production writes unless waived.
- Historical records without hashes remain readable with warning.

Tests:

- Reviewer evidence missing task hash for new strict task fails or warns by policy.
- Tester report lists changed production file; strict wait-gate blocks.
- Historical reviewer evidence without hash audits as legacy.

## Phase 2：证据生命周期和多 Agent 可靠性

第二阶段处理长期运行、跨 pane、跨天、跨环境时的 drift、stale verdict、artifact retention 和 runtime mismatch。

### Slice 6：Role Identity And Write Policy Full

User problem：最小身份记录只能发现明显越权，不能解决 role docs 是否加载、session 是否一致、工作树是否污染和权限是否被绕过的问题。

Desired behavior：gate role verdict 能证明 role config、rules context、task revision、workspace state 和 write policy；高风险任务可启用只读或临时 worktree profile。

Fields:

```yaml
role_execution_context:
  instance: reviewer
  role_ref: reviewer
  role_config_sha256: ""
  rules_resolution_sha256: ""
  rules_context_sha256: ""
  task_sha256: ""
  evidence_manifest_sha256_before_submit: ""
  worktree:
    git_head: ""
    dirty_files_before: []
    dirty_files_after: []
    reviewed_diff_base: ""
  permission_profile:
    mode: audit_only
    write_policy: no_production_writes
    sandbox: none
```

Migration from the minimum slice: `role_execution_context` supersedes Slice 5's flat `identity` block. Slice 5's `task_sha256` / `rules_context_sha256` / `role_config_sha256` are the forward-compatible subset of these fields. Once this slice ships, implementations may read either location but write only `role_execution_context`, so the same hash never lives in two places.

CLI behavior:

- `whoami` exposes role/rules hashes when available.
- `rules print-context` writes context hash in output.
- `evidence submit` attaches role execution context.
- `wait-gate` rejects identity mismatch and can block write policy violations by risk level.
- `audit` reports gate role write contamination and stale task/evidence hash.

Acceptance:

- Gate evidence can be traced to role config, rules context and task revision.
- Review/test pass against stale task hash is marked stale.
- Strict profile blocks production writes by reviewer/tester.
- Audit distinguishes audit-only permission from enforced sandbox.

Tests:

- Review submitted against old task sha is stale.
- Reviewer changed production file under strict profile blocks gate.
- Missing rules context hash warns in standard profile and fails in strict profile.

### Slice 7：Evidence Retention And Compact Defaults

User problem：`.orbit` can grow into a second repository. Raw artifacts are either kept forever or deleted without enough proof to verify conclusions.

Desired behavior：Evidence has retention profiles and compact summaries so long tasks stay auditable without preserving every transient artifact.

Fields:

```yaml
artifact_retention:
  profile: durable_summary
  raw_artifacts: []
  derived_summary: ""
  hashes: []
  index: []
  expiry: ""
  deletion_policy: preserve_hash

compact_summary:
  task_sha256: ""
  evidence_sha256: ""
  handoff_sha256: ""
  latest_verdicts: {}
  artifact_refs: []
  known_gaps: []
  closure_checklist: []
```

CLI behavior:

- `compact-evidence` becomes recommended default for long tasks and docs lifecycle tasks.
- `audit` detects manifest/report/loop-state/handoff latest-record drift.
- `docs check` or audit warns about oversized `.orbit` directories and missing summaries.
- `handoff` references compact summary when present.

Acceptance:

- Compact summary preserves task/evidence/handoff hashes, latest verdicts, artifact refs and known gaps.
- Deleting transient artifacts after compaction does not erase the proof chain.
- Drift between manifest latest record and handoff is reported.
- Large `.orbit` surfaces retention recommendations.

Tests:

- Evidence with deleted raw artifact but valid hash/summary audits pass with retained proof.
- Manifest/handoff latest verdict mismatch audits fail or warn by severity.
- Compact summary missing task hash fails schema validation.

### Slice 8：Runtime Reconcile And Env Fingerprint

User problem：Orbit task state, server state, browser session, external operation, model behavior and build output can diverge. Reports often cannot distinguish code failure from environment failure.

Desired behavior：Evidence can bind to runtime resources and audit can reconcile Orbit records with external/runtime state fingerprints.

Fields:

```yaml
runtime_binding:
  server:
    owner: ""
    port: ""
    pid: ""
    started_at: ""
  browser:
    owner: ""
    session_id: ""
  external_operation:
    id: ""
    state: ""
  product_runtime_task:
    id: ""
    state: ""
  build:
    git_head: ""
    artifact_hash: ""
  model_service:
    family: ""
    alias: ""
    behavior_fingerprint: ""

blocker_classification:
  kind: code_failure
  confidence: medium
  evidence: []
```

Allowed blocker kinds:

- `code_failure`
- `environment_failure`
- `service_failure`
- `model_drift`
- `expected_fail_closed`
- `unknown`

CLI behavior:

- `evidence submit --kind test` accepts runtime binding and redacted environment fingerprint.
- `audit` outputs reconcile summary.
- `handoff` includes runtime binding and cleanup status.
- `validate` requires runtime binding for `real_path_test` when task changes runtime behavior.

Acceptance:

- Real-path test records server/browser/build/service identity without secrets.
- Audit can identify stale build artifact or missing runtime artifact.
- Blocker classification is explicit and not hidden inside prose.
- Handoff states cleanup status and reproducibility gaps.

Tests:

- `real_path_test` without server/browser owner fails new behavior task.
- Build hash mismatch is reported by audit.
- Service failure classified as environment/service blocker does not count as code pass.

### Slice 9：Gate Lease And Stale Verdict

User problem：Reviewer/tester output can arrive late, conflict, or belong to an old task revision. Lead and user cannot know who owns a gate or whether replacement is allowed.

Desired behavior：Gate work has lease metadata and stale verdict arbitration based on task hash, evidence revision, source message and role identity.

Fields:

```yaml
gate_lease:
  gate: review
  owner_instance: reviewer
  task_sha256: ""
  evidence_revision: 3
  status: claimed
  claimed_at: ""
  expires_at: ""
  replacement_policy: allow_after_expiry

verdict_arbitration:
  accepted_record_id: ""
  superseded_records: []
  stale_records: []
  conflict_resolution: latest_valid_for_task_revision
```

CLI behavior:

- `dispatch` or future gate command can create lease metadata.
- `wait-gate` ignores stale verdicts and reports superseded/conflicting records.
- `audit` lists active leases, expired leases and accepted verdict.
- `handoff` states who owns remaining gates and whether replacement is allowed.

Acceptance:

- Late verdict for old task hash does not close current gate.
- Two conflicting reviewer pass/fail records surface an arbitration result.
- Expired lease lets lead replace gate owner according to policy.
- User can see whether to wait, replace reviewer/tester or continue.

Tests:

- Review pass for old task sha is stale and ignored.
- New fail supersedes old pass for same gate revision.
- Expired lease changes waiting status to replaceable.

### Slice 10：Doc Lifecycle And Decision Record

User problem：Conversation memory, project rules, lessons, active designs and old docs blur together. User decisions can exist only in chat.

Desired behavior：Docs have stable lifecycle and user decisions are structured records that can be referenced by task/evidence/handoff.

Fields:

```yaml
doc_lifecycle:
  doc_id: ""
  path: ""
  status: active_baseline
  supersedes: []
  superseded_by: ""
  content_sha256: ""

decision_record:
  id: ""
  kind: user_confirmation
  summary: ""
  source: ""
  applies_to:
    task: ""
    doc_id: ""
  expires: ""
```

Allowed doc statuses:

- `active_baseline`
- `open_design`
- `implemented_archive`
- `historical_reference`
- `lesson_candidate`
- `promoted_rule`

CLI behavior:

- `docs alias` maintains doc id and content hash.
- `docs check` detects closed-but-unarchived docs, broken aliases and stale active design.
- `evidence add` can attach decision record.
- `handoff` lists active decisions and expired constraints.

Acceptance:

- Important docs can move without breaking historical references.
- User confirmation is not only in chat.
- Old design docs do not remain active after implementation.
- Lesson promotion to runtime rules requires explicit status change.

Tests:

- Missing alias target fails docs check.
- Implemented doc still marked open triggers warning.
- Handoff includes active user confirmation decision.

## Phase 3：组织采用、合规、发布和长期治理

第三阶段让 Orbit 从单项目重流程经验变成可适配、可发布、可迁移、可校准的协作系统。

### Slice 11：Project Profile Risk Level

User problem：One heavy project can overfit Orbit defaults. Small tasks become over-processed while risky tasks still need stronger gates.

Desired behavior：Project profile and task risk level determine default gates, evidence level and strictness.

Fields:

```yaml
project_profile:
  kind: web_ui
  workflow_traits:
    - llm_heavy
    - runtime_artifacts
  default_risk_level: standard

task_risk:
  level: strict
  rationale: ""
  required_gates:
    review: true
    test: true
  minimum_evidence_levels:
    review: outcome_quality
    test: real_path_test
```

Allowed risk levels:

- `light`
- `standard`
- `strict`
- `release`

Precedence: `task_risk.minimum_evidence_levels` derives from project profile and risk level and seeds `review_strategy` / `test_strategy.minimum_evidence_level` (Slice 1). An explicit task-level minimum may only raise the bar; lowering it below the risk-level default requires a recorded waiver.

The `review` / `test` keys above are the common case; the other two Slice 1 gate kinds are derived rather than listed: a design/analysis task raises the review gate's minimum to `implementation_readiness`, and a `release` risk level requires `release_readiness` (Slice 13). `minimum_evidence_levels` may carry explicit `design_readiness` / `release` keys when a task uses those gate kinds.

CLI behavior:

- `new-task` derives defaults from profile and risk level.
- `classify-intent` can recommend formal task/evidence/gates from risk.
- `validate` applies stricter checks by risk level.
- `audit` states why a task used light/standard/strict/release.

Acceptance:

- One-line docs edit can be light without formal gates.
- Behavior-changing UI task defaults to standard or strict.
- Release task requires release readiness evidence.
- Project rules remain supplements, not replacement for Orbit core.

Tests:

- Light task validates without parent goal and required review.
- Strict task requires review/test gates and write policy checks.
- Release task requires release evidence fields.

### Slice 12：Data Classification And Retention

User problem：Evidence can include secrets, user content, third-party material, prompts, screenshots, logs and local paths. Keeping too much creates risk; keeping too little breaks audit.

Desired behavior：Artifacts have data classification and retention policy. Trust repair process exists for mistakes.

Fields:

```yaml
data_classification:
  categories:
    - user_content
    - screenshot
  sensitivity: medium
  redaction: required

retention_policy:
  mode: hash_only
  expires_at: ""
  user_approved: false

trust_repair:
  incident_id: ""
  impact: ""
  recovery: ""
  prevention: ""
  follow_up_verification: ""
  user_confirmation: ""
```

CLI behavior:

- `evidence add/submit` accepts artifact classification.
- `audit` warns on sensitive artifacts without retention policy.
- `compact-evidence` respects hash-only/redact/short-lived policies.
- `handoff` omits sensitive raw content and references redacted summaries.

Acceptance:

- Sensitive artifact cannot be retained long-term without policy.
- Hash-only retention preserves proof without copying raw content.
- Incident/trust repair record is visible in handoff.
- Secret-like content never appears in compact summary.

Tests:

- Artifact marked `secret` with long-lived raw retention fails.
- Screenshot without classification warns or fails by risk.
- Compact summary excludes raw sensitive content.

### Slice 13：CI Release Readiness

User problem：Local gate pass does not prove release readiness. CI, package contents, generated artifacts, version fields and remote state may diverge.

Desired behavior：Release tasks layer local confidence, CI, package/archive, generated artifacts, version metadata, release assets and remote state.

Fields:

```yaml
release_readiness:
  source:
    git_head: ""
    reviewed_diff_base: ""
  ci:
    provider: ""
    run_id: ""
    status: ""
  package:
    artifact_path: ""
    artifact_sha256: ""
    contents_checked: false
  version_fields: []
  generated_artifacts: []
  remote_state:
    branch: ""
    ahead_behind: ""
```

CLI behavior:

- `new-task --task-type release` seeds release readiness fields.
- `validate` requires release readiness for release risk tasks.
- `audit` distinguishes local confidence from release readiness.
- `handoff` lists release blockers separately from implementation blockers.

Acceptance:

- Release task cannot be done with only local tests.
- Package/archive hash and contents are recorded.
- CI/remote missing state is explicit gap.
- Generated artifacts are checked or waived.

Tests:

- Release task with local review/test pass but no CI status fails release audit.
- Package hash missing fails release readiness.
- Remote branch mismatch reported.

### Slice 14：Protocol Schema Versioning

User problem：Natural language report and structured fields can disagree. Template drift and field semantic changes can make old evidence look stronger than it is.

Desired behavior：Task/report/evidence fields have versioned semantics, consistency checks and negative evidence representation.

Fields:

```yaml
schema_semantics:
  task_schema_version: orbit-task-v2
  evidence_schema_version: orbit-evidence-v2
  report_template_version: review-report-v2
  feature_versions:
    evidence_level: v1
    parent_goal_status: v1

consistency_check:
  structured_verdict: pass
  summary_verdict_detected: pass
  conflicts: []

negative_evidence:
  - claim: "browser E2E passed"
    status: not_tested
    reason: "docs-only task"
```

CLI behavior:

- `evidence submit` validates report template version.
- `audit` detects summary/structured verdict conflicts.
- `validate` treats unknown future schema versions as explicit compatibility state.
- `handoff` includes schema version summary.

Acceptance:

- Structured verdict wins over prose summary.
- Summary says PASS but structured verdict fail/partial triggers conflict.
- Unknown schema version is not silently accepted as current semantics.
- Negative evidence can express “not tested” without implying failure.

Tests:

- Prose says PASS, structured verdict fail; audit fails or flags conflict.
- Old template missing feature version audits as legacy.
- Unknown future schema version requires compatibility handling.

### Slice 15：Orbit Dogfood And Governance

User problem：Orbit cannot rely on accidental project failures to test itself. Lessons can grow forever without done criteria.

Desired behavior：Every critical protocol risk has dogfood cases, owner, SLO, route to roadmap and stopping criteria.

Fields:

```yaml
dogfood_case:
  id: stale-gate-detection
  source_adjustment: P1.3
  scenario: ""
  expected_outcome: ""
  fixture: ""
  owner: ""
  cadence: ""

governance:
  owner: ""
  slo: ""
  roadmap_item: ""
  failure_review_required: true
  exit_criteria: []
```

CLI behavior:

- Dogfood can initially live as tests/fixtures plus docs index; no dedicated CLI required in first implementation.
- `audit` or test tooling should map failed dogfood case to source adjustment.
- Release checklist includes dogfood suite status when protocol semantics change.

Acceptance:

- P0/P1 adjustments each have at least one dogfood case.
- Failing dogfood case maps to source adjustment and expected behavior.
- Protocol-changing release cannot skip dogfood without waiver.
- Retrospective tasks have done criteria and do not become infinite backlog.

Tests:

- Stale gate fixture fails before fix and passes after fix.
- Transport-only DONE fixture cannot satisfy gate.
- Destructive dry-run fixture blocks unsafe deletion.

### Slice 16：Landing Governance And Calibration

User problem：Compatibility policy, multi-user sharing, quality calibration, self-review contamination, speed/rigor tradeoff and evidence backup/migration are not explicit enough for adoption.

Desired behavior：Orbit has operational adoption rules that explain how strictness is chosen, how quality is calibrated, how multi-user ownership works and how evidence can be backed up or migrated.

Fields:

```yaml
compatibility_policy:
  mode: warn_legacy
  applies_to: []
  breaking_change: false
  migration_path: ""

multi_user_ownership:
  file_owner: ""
  artifact_owner: ""
  pane_owner: ""
  evidence_access: ""

quality_calibration:
  sample_rate: ""
  metrics:
    false_pass: 0
    false_block: 0
    user_corrections: 0
    median_gate_wait: ""

self_review_guard:
  protocol_changed: true
  independent_check_required: true
  same_system_self_approval_allowed: false

backup_migration:
  export_format: ""
  restore_check: ""
  evidence_index: ""
```

CLI behavior:

- `audit` reports compatibility mode and known legacy gaps.
- `handoff` states ownership assumptions in multi-user contexts.
- Migration/export may start as documented workflow before becoming CLI.
- Quality calibration can initially be report data aggregated by scripts/tests.

Acceptance:

- Breaking schema or gate changes have compatibility policy.
- Multi-user workspace can identify owner for files, panes, artifacts and evidence.
- Orbit protocol self-change requires independent check or explicit waiver.
- Evidence backup/migration path has restore check.
- Risk-level choice explains speed/rigor tradeoff.

Tests:

- New strict rule against legacy evidence reports warning, not hard failure, when policy says `warn_legacy`.
- Self-review-only protocol change is blocked in strict/release profile.
- Backup export missing restore check fails governance audit.

## Cross-Phase Dependencies

- `verdict-evidence-level-schema` is the foundation for quality review, stale verdict, retention summaries, runtime reconcile and release readiness.
- `protocol-schema-versioning` should start early as feature-version scaffolding, even though full governance lands in Phase 3.
- `role-identity-and-write-policy-minimum` protects Phase 1 gates; the full version completes Phase 2 multi-agent reliability.
- `project-profile-risk-level` controls how strict later checks are; early implementations may hardcode standard/strict defaults but must not block future profile support.
- `landing-governance-and-calibration` depends on evidence, profile and dogfood data, but minimum compatibility policy must be decided before breaking validation changes ship.

## Full Test Matrix

| Failure mode guarded | Required test |
| --- | --- |
| PASS without evidence level closes gate | Review pass without `evidence_level` fails new task gate. |
| Mechanical check passes quality task | `mechanical_check` fails when task requires `outcome_quality`. |
| Review ignores quality outcome | Review pass without `quality_outcome_verdict` or counterexample answers is rejected. |
| Slice pass becomes parent done | Parent task with incomplete done criteria cannot audit as done. |
| User next action missing | Handoff for parent task without `user_next_action` fails validation or audit. |
| Pane DONE treated as evidence | Transport-only message without structured evidence cannot satisfy gate. |
| Out-of-scope file hidden in pass | Changed file outside `scope.include` causes validate failure. |
| Artifact deletion destroys proof | Destructive plan affecting evidence without hash or summary fails. |
| Reviewer/tester writes production files | Strict task gate blocks or flags gate role write policy violation. |
| Old evidence becomes unusable | Historical manifest without new fields audits with legacy warning. |
| Gate verdict stale | Review for old task hash cannot close current gate. |
| Evidence drift | Manifest/handoff/latest-record mismatch is reported. |
| Runtime mismatch | Real-path test with stale build hash or missing server owner fails required evidence. |
| Old design remains active | Docs check warns when implemented design is still active/open. |
| Sensitive data retained | Secret or user content artifact without retention policy fails audit. |
| Release falsely ready | Release task with local pass but no CI/package/remote evidence fails release readiness. |
| Prose conflicts with structured verdict | Structured/prose verdict conflict fails or flags audit. |
| Dogfood missing | Protocol-changing release without dogfood coverage is blocked or waived explicitly. |
| Self-review contamination | Orbit protocol change approved only by same system fails strict governance. |
| Backup unverified | Evidence migration/export without restore check fails governance audit. |

## Implementation Order

Recommended order:

1. `protocol-schema-versioning` minimum scaffolding: feature versions and legacy warning vocabulary.
2. `verdict-evidence-level-schema`.
3. `quality-outcome-guardrails`.
4. `parent-goal-status-and-user-next-action`.
5. `destructive-action-and-scope-guard`.
6. `role-identity-and-write-policy-minimum`.
7. `role-identity-and-write-policy-full`.
8. `evidence-retention-and-compact-defaults`.
9. `runtime-reconcile-and-env-fingerprint`.
10. `gate-lease-and-stale-verdict`.
11. `doc-lifecycle-and-decision-record`.
12. `project-profile-risk-level`.
13. `data-classification-and-retention`.
14. `ci-release-readiness`.
15. `orbit-dogfood-and-governance`.
16. `landing-governance-and-calibration`.

This order separates field semantics first, then gate behavior, then long-running reliability, then organization and release governance. `protocol-schema-versioning` appears here only as step 1 (feature-version scaffolding and legacy-warning vocabulary); its full governance scope is completed in Phase 3 (Slice 14).

## Non-Goals

- This document does not decide exact Ruby class/module boundaries.
- This document does not require all features to ship in one PR.
- This document does not require a dedicated CLI command where evidence metadata validation is enough for the first implementation.
- This document does not turn project-specific autoNovel behavior into Orbit defaults.
- This document does not require strict workflow for light tasks.

## Open Decisions Before Coding

- Whether schema versions increment globally or per feature section.
- Whether insufficient evidence level is always a `validate` failure or only a `wait-gate` blocker for new tasks.
- Whether changed-file detection is computed from git, supplied by report, or both.
- Whether destructive action support starts as metadata validation or a dedicated CLI command.
- Which task types default to `parent_goal.required: true`.
- Which project profiles ship first and whether profile lives in `.orbit/roles.yaml`, a new config file, or task defaults.
- Whether gate leases are stored in evidence manifest, loop state or a separate runtime file.
- How much runtime reconcile should be deterministic CLI inspection versus user/tester-provided metadata.
- Whether quality calibration starts as manual audit samples or a first-class command.
- What export/restore format is acceptable for evidence migration.

# Orbit 第一用户体验调整实施依据

本文基于 [Orbit 第一用户长期使用复盘](orbit-first-user-experience.md) 和 [Orbit 第一用户体验调整方案](orbit-first-user-adjustment-plan.md) 制定完整开发 contract。它不是新的问题复盘，也不是只覆盖第一阶段的草案；它把三阶段所有调整项落成可拆 task、可改 schema、可改 CLI、可测试、可兼容的开发依据。

## 文档边界

- `orbit-first-user-experience.md`：源复盘，记录长期使用体验、收益和问题域。
- `orbit-first-user-adjustment-plan.md`：调整方案，定义 P0/P1/P2 优先级、覆盖矩阵和 slice 路线。
- `orbit-first-user-adjustment-development-contract.md`：实施依据，定义每个 slice 的用户问题、目标行为、字段草案、CLI 行为、兼容策略、验收标准和测试矩阵。

开发时应以本文为 task 拆分输入；如果本文和调整方案冲突，以调整方案的优先级为准，以本文的字段和测试为实现细化依据。

阅读约定：本文面向用户理解的说明统一使用中文；字段名、CLI 命令、枚举值、schema 名和 slice id 保留英文，因为它们需要和代码、测试、JSON/YAML 字段精确对应。

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

第一原则：新规则不能静默改写旧 evidence 的历史含义，但新 task 必须能失败关闭（fail closed）。

- 旧 evidence/report 缺少新字段时，`audit` 输出 `legacy_warning`，不直接让历史 handoff 失效。
- 新 task 一旦声明新能力字段，`validate`、`wait-gate`、`audit` 必须按新规则检查。
- `new-task` 生成的新模板必须包含对应字段骨架；旧 task 不自动迁移。
- `evidence submit` 对新结构严格校验；`evidence add/from-report` 只能生成兼容 record，不能伪造成高 evidence level。
- schema 或 feature version 必须记录在 task、report 或 evidence record 中，避免旧报告被新语义误读。
- 新增 CLI 输出字段必须保持机器可读稳定；人读 summary 只能派生自结构化字段。
- 任何失败关闭升级都必须有迁移或 opt-in 策略，不能让历史 `.orbit` 目录无法 audit。

## Phase 1：收口语义和用户状态

第一阶段优先处理错误完成、错误放行、误删产物和用户不知道下一步的问题。它的结果应先让 Orbit 的完成语义可靠，再进入规模化治理。

### Slice 1：Verdict Evidence Level Schema（判定证据层级）

用户问题：`PASS` 同时可能表示机械检查、文档可读、质量达标、真实路径通过或 blocker 被诚实记录。用户和 lead 无法仅凭 pass 判断 gate 是否真的满足 task。

目标行为：review/test evidence 同时表达 verdict 状态和证据层级。`wait-gate` 按 task 所需最低层级判断 gate ready。

字段:

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
  residual_risk: "非空字符串：描述未覆盖路径，或说明为什么剩余风险可以接受。"
```

可选证据层级:

| 取值 | 含义 | Gate 用途 |
| --- | --- | --- |
| `mechanical_check` | 文件存在、命令通过、schema 可解析，或 checklist 被机械满足。 | 单独不足以通过质量评审。 |
| `outcome_quality` | reviewer 已判断质量目标、无效完成方式、证据和剩余风险。 | 改善、文档、UX、可靠性任务的默认 review 最低要求。 |
| `implementation_readiness` | 设计或方案已经具体到可以授权实现。 | 从设计/分析进入编码前使用。 |
| `real_path_test` | tester 执行了有代表性的真实用户路径或运行时路径，并记录环境。 | 行为变更任务的 test gate 要求。 |
| `release_readiness` | 已检查发布包、CI、远端状态或 release 相关信息。 | 仅用于发布任务。 |

证据层级按 gate 类型分别排序，不是一条全局等级链。`wait-gate` 只会在同一 gate 类型内比较 record 的 `evidence_level` 和最低要求：

- Review gate（评审 gate）：`mechanical_check` < `outcome_quality`。
- Design readiness gate（设计就绪 gate）：`mechanical_check` < `implementation_readiness`。
- Test gate（测试 gate）：`mechanical_check` < `real_path_test`。
- Release gate（发布 gate）：`mechanical_check` < `release_readiness`。

`mechanical_check` 是共同最低层级，意思是“只是机械满足”。不同 gate 类型的最低要求不能互相替代：test gate 要求 `real_path_test` 时，review 的 `outcome_quality` 不能满足；quality review gate 要求 `outcome_quality` 时，`implementation_readiness` 不能满足；design readiness gate 要求 `implementation_readiness` 时，`outcome_quality` 也不能满足。

CLI 行为:

- `new-task` 按 task 类型写入默认最低证据层级。
- `evidence submit` 在提交 review/test pass 时必须包含 `evidence_level`、`confirmed`、`assumed`、`missing`、`rule_application` 和 `residual_risk`。
- `wait-gate` 拒绝低于 task 最低要求的 pass record。
- `validate` 报告精确缺失字段路径。
- `audit` 用 `status + evidence_level + residual_risk` 汇总 gate。
- `handoff` 为每个必需 gate 输出最新被接受的证据层级。

验收标准:

- 没有 `evidence_level` 的 review pass 不能满足新 task gate。
- `mechanical_check` 不能满足 `outcome_quality` 的最低要求。
- 历史 evidence 缺少 `evidence_level` 时，audit 给出 legacy warning，而不是直接改写历史含义。
- Handoff 能显示每个 gate 当前是机械检查、质量证据、真实路径证据还是发布证据。

测试:

- 新 docs-maintenance task 要求 `outcome_quality`；缺少 `evidence_level` 的 review pass 失败。
- 最低要求是 `outcome_quality` 时，`mechanical_check` 的 review pass 失败。
- `implementation_readiness` 的设计就绪 pass 不能满足要求 `outcome_quality` 的质量 review gate。
- 缺少 `evidence_level` 的旧 manifest 在 audit 中显示 legacy warning。
- 带 `real_path_test` 的 test pass 能满足要求该层级的行为任务。

### Slice 2：Quality Outcome Guardrails（质量结果护栏）

用户问题：改善类任务容易把“动作完成”误当成“质量改善”。Reviewer 可能只检查文档存在、命令通过或 checklist 完成，没有判断用户问题是否被解决。

目标行为：改善类、文档维护、UX、可靠性、架构、测试改进任务必须有可审查的质量结果和无效完成护栏。Review pass 必须证明目标结果已满足，或明确说明被什么阻塞。

字段:

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

CLI 行为:

- `new-task` 为改善类 task 类型填入质量结果模板。
- `validate` 对质量结果字段为空的新改善类 task 报错。
- 当 task 需要质量 review 时，`evidence submit --kind review` 必须包含 `quality_outcome_verdict` 和必答问题。
- 如果 `quality_outcome_verdict` 不是 `pass`，`wait-gate` 不接受 review pass。
- `audit` 列出无效完成护栏，以及最新 review 是否处理了这些护栏。

验收标准:

- 新 docs-maintenance task 的 `quality_outcome` 为空时不能通过 validate。
- 缺少反例讨论的 review pass 不能关闭 review gate。
- partial/fail review 保持 partial/fail，不能被规范化成 pass。
- Audit 要说明质量结果是否满足，而不只是说明 review 是否存在。

测试:

- `quality_outcome.user_problem` 为空时 validate 失败。
- Review report 文本说 pass，但缺少 `quality_outcome_verdict` 时 submit 失败。
- `quality_outcome_verdict: fail` 会阻塞 wait-gate。
- 合法 review 回答所有必答问题后可以通过 wait-gate。

### Slice 3：Parent Goal Status And User Next Action（父目标状态和用户下一步）

用户问题：长任务被切成 slice 后，用户只能看到局部 pass，不知道整体是否完成、谁在等待谁、下一步该做什么。

目标行为：Orbit 输出单一父目标视图，包含目标、完成标准、当前 slice、剩余阻塞、必需 gate 和用户下一步动作。

字段:

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

可选父目标状态:

- `not_applicable`
- `parent_in_progress`
- `slice_ready`
- `parent_blocked`
- `parent_done_ready`
- `parent_done`

CLI 行为:

- `new-task` 为父任务/拆分任务包含 `parent_goal`。
- `state progress` 更新当前 slice 和 blocker，但不声称整体完成。
- `wait-gate` 同时显示 gate 就绪状态和父目标状态。
- 如果完成标准缺失或没有 evidence，`validate` 拒绝 parent done。
- `audit` 检查 child slice pass 是否被错误当成 parent done。
- `handoff` 包含 `parent_goal_status`。

验收标准:

- 子 slice pass 但仍有未完成标准时，状态应是 `parent_in_progress`，不是 done。
- 用户下一步动作出现在 handoff 和用户可读 summary 中。
- Parent done 必须为每一条完成标准提供 evidence。
- 简单非父任务可以设置 `parent_goal.required: false`。

测试:

- 子 slice review pass 已存在，但父目标标准未完成时，audit 阻止 parent done。
- Parent task 缺少 `done_criteria` 时 validate 失败。
- 父任务 handoff 包含 `user_next_action`。
- 单文件文档任务设置 `parent_goal.required: false` 后，不需要父目标流程也能 validate。

### Slice 4：Destructive Action And Scope Guard（破坏性操作和范围护栏）

用户问题：混合 worktree 中同时有用户改动、运行时产物、构建输出和 Orbit runtime。删除、清理、回退或提交错误路径会破坏 evidence 或用户工作。

目标行为：破坏性和范围敏感操作必须有 dry-run、目标列表、owner、可恢复性、evidence 影响和必要用户确认。

字段:

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

CLI 行为:

- `validate` 对新 scoped task 检查 changed files 是否落在 scope 内。
- 当生成文件、构建输出或运行时产物出现但没有 policy 时，`audit` 给出 warning 或 fail。
- `evidence add` 可以附加破坏性操作计划元数据。
- `handoff` 列出破坏性操作和恢复缺口。
- 后续可以增加专用命令；第一版可以先校验挂在 evidence 上的 plan 文件。

验收标准:

- 如果 scope 排除了 `.orbit/**`，但实现改动里包含 `.orbit` runtime 文件且没有 waiver，则失败。
- 破坏性操作缺少 dry-run、目标和可恢复性时，应被拒绝或 audit 为 fail。
- 删除会影响 evidence 的 artifact 时，必须保留 hash 或 durable summary。
- 用户拥有或 owner 未知的文件必须有明确确认。

测试:

- `scope.include` 之外的 changed file 导致 validate 失败。
- 破坏性计划缺少 `recoverability` 时失败。
- 删除影响 evidence 的 artifact 且没有 hash 时失败。
- 没有 policy 的构建生成物按 task risk 给出 warning 或 fail。

### Slice 5：Role Identity And Write Policy Minimum（最小角色身份和写入策略）

用户问题：当前 identity 只能证明声明的 role，不能证明加载了哪些 role rules，也不能证明 gate 角色是否避免修改实现文件。

目标行为：第一阶段先记录足够的身份和写入范围数据，在完整 sandbox 支持之前也能发现明显的 review/test 污染。

字段:

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

CLI 行为:

- `evidence submit` 在可用时记录 task hash 和 rules context hash。
- `evidence submit` 记录 changed files 快照，或接受 report 提供的 `changed_files`。
- reviewer/tester record 存在写入违规时，`wait-gate` 给出 warning 或阻塞。
- `audit` 区分 gate 角色写入和 lead/coder 的实现写入。

验收标准:

- 新 review/test evidence 包含 task hash 和 rules context hash。
- Reviewer/tester 的 changed files 在 audit 中可见。
- strict task 阻止 gate 角色写 production files，除非有 waiver。
- 缺少 hash 的历史 record 仍可读取，但带 warning。

测试:

- 新 strict task 的 reviewer evidence 缺少 task hash 时，按 policy 失败或 warning。
- Tester report 列出 production file 改动时，strict wait-gate 阻塞。
- 缺少 hash 的历史 reviewer evidence 在 audit 中作为 legacy 处理。

## Phase 2：证据生命周期和多 Agent 可靠性

第二阶段处理长期运行、跨 pane、跨天、跨环境时的漂移、过期 verdict、artifact 留存和运行时不一致。

### Slice 6：Role Identity And Write Policy Full（完整角色身份和写入策略）

用户问题：最小身份记录只能发现明显越权，不能解决 role docs 是否加载、session 是否一致、工作树是否污染和权限是否被绕过的问题。

目标行为：gate 角色的 verdict 能证明 role config、rules context、task revision、workspace state 和 write policy；高风险任务可启用只读或临时 worktree profile。

字段:

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

从最小版本迁移：`role_execution_context` 取代 Slice 5 的扁平 `identity` block。Slice 5 的 `task_sha256` / `rules_context_sha256` / `role_config_sha256` 是这些字段的前向兼容子集。该 slice 发布后，实现可以读取两个位置，但只写入 `role_execution_context`，避免同一个 hash 同时存在两个地方。

CLI 行为:

- `whoami` 在可用时输出 role/rules hash。
- `rules print-context` 在输出中写入 context hash。
- `evidence submit` 附加 role execution context。
- `wait-gate` 拒绝 identity mismatch，并可按 risk level 阻止 write policy violation。
- `audit` 报告 gate 角色写入污染和 stale task/evidence hash。

验收标准:

- Gate evidence 可以追溯到 role config、rules context 和 task revision。
- 针对旧 task hash 的 review/test pass 会被标记为 stale。
- Strict profile 阻止 reviewer/tester 写 production files。
- Audit 区分 audit-only permission 和强制 sandbox。

测试:

- 针对旧 task sha 提交的 review 被判定为 stale。
- Strict profile 下 reviewer 修改 production file 会阻塞 gate。
- 缺少 rules context hash 时，standard profile warning，strict profile fail。

### Slice 7：Evidence Retention And Compact Defaults（证据留存和压缩摘要默认值）

用户问题：`.orbit` 可能膨胀成第二个仓库。原始 artifact 要么永远保留，要么在没有足够证明链的情况下被删除。

目标行为：Evidence 有留存 profile 和 compact summary，让长任务在不保留每个临时 artifact 的情况下仍可被 audit。

字段:

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

CLI 行为:

- `compact-evidence` 成为长任务和文档生命周期任务的推荐默认动作。
- `audit` 检测 manifest/report/loop-state/handoff 的 latest-record drift。
- `docs check` 或 audit 对过大的 `.orbit` 目录和缺失 summary 给出 warning。
- `handoff` 在存在 compact summary 时引用它。

验收标准:

- Compact summary 保留 task/evidence/handoff hash、latest verdict、artifact ref 和 known gap。
- 压缩后删除临时 artifact 不会抹掉证明链。
- Manifest latest record 和 handoff 之间的 drift 会被报告。
- 大型 `.orbit` 目录会输出留存建议。

测试:

- 原始 artifact 已删除但 hash/summary 有效的 evidence，可以在保留证明链的情况下通过 audit。
- Manifest/handoff latest verdict 不一致时，按严重程度 audit fail 或 warning。
- Compact summary 缺少 task hash 时 schema validation 失败。

### Slice 8：Runtime Reconcile And Env Fingerprint（运行时对账和环境指纹）

用户问题：Orbit task state、server state、browser session、外部操作、模型行为和 build output 可能彼此不一致。Report 经常无法区分代码失败和环境失败。

目标行为：Evidence 可以绑定运行时资源，audit 可以用外部/运行时状态指纹对 Orbit record 做对账。

字段:

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

可选阻塞类型:

- `code_failure`
- `environment_failure`
- `service_failure`
- `model_drift`
- `expected_fail_closed`
- `unknown`

CLI 行为:

- `evidence submit --kind test` 接受 runtime binding 和脱敏后的环境指纹。
- `audit` 输出 reconcile summary。
- `handoff` 包含 runtime binding 和 cleanup status。
- 当 task 改变运行时行为且要求 `real_path_test` 时，`validate` 要求 runtime binding。

验收标准:

- Real-path test 记录 server/browser/build/service identity，但不能包含 secret。
- Audit 能识别 stale build artifact 或缺失 runtime artifact。
- Blocker classification 必须结构化表达，不能藏在 prose 里。
- Handoff 说明 cleanup status 和 reproducibility gap。

测试:

- 新行为任务的 `real_path_test` 缺少 server/browser owner 时失败。
- Build hash mismatch 会被 audit 报告。
- 被归类为 environment/service blocker 的 service failure 不能算作代码 pass。

### Slice 9：Gate Lease And Stale Verdict（Gate 租约和过期判定）

用户问题：Reviewer/tester 输出可能迟到、互相冲突，或属于旧 task revision。Lead 和用户无法判断谁拥有 gate，也不知道能否替换。

目标行为：Gate work 有 lease metadata，并基于 task hash、evidence revision、source message 和 role identity 做 stale verdict arbitration。

字段:

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

CLI 行为:

- `dispatch` 或未来 gate command 可以创建 lease metadata。
- `wait-gate` 忽略 stale verdict，并报告 superseded/conflicting records。
- `audit` 列出 active leases、expired leases 和 accepted verdict。
- `handoff` 说明剩余 gate 由谁拥有，以及是否允许替换。

验收标准:

- 旧 task hash 的迟到 verdict 不能关闭当前 gate。
- 两条冲突的 reviewer pass/fail record 会输出 arbitration result。
- Expired lease 允许 lead 按 policy 替换 gate owner。
- 用户能看到应该等待、替换 reviewer/tester，还是继续推进。

测试:

- 旧 task sha 的 review pass 被判定为 stale 并忽略。
- 同一 gate revision 下，新 fail 会 supersede 旧 pass。
- Expired lease 会把等待状态变成 replaceable。

### Slice 10：Doc Lifecycle And Decision Record（文档生命周期和决策记录）

用户问题：对话记忆、项目规则、经验教训、活跃设计和旧文档混在一起。用户决策可能只存在于聊天里。

目标行为：文档有稳定生命周期，用户决策成为结构化 record，可被 task/evidence/handoff 引用。

字段:

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

可选文档状态:

- `active_baseline`
- `open_design`
- `implemented_archive`
- `historical_reference`
- `lesson_candidate`
- `promoted_rule`

CLI 行为:

- `docs alias` 维护 doc id 和 content hash。
- `docs check` 检测已关闭但未归档的文档、损坏 alias 和 stale active design。
- `evidence add` 可以附加 decision record。
- `handoff` 列出 active decisions 和 expired constraints。

验收标准:

- 重要文档移动路径后，历史引用不会失效。
- 用户确认不只停留在聊天里。
- 旧设计文档在实现后不会继续保持 active。
- Lesson 提升为 runtime rules 必须有明确 status change。

测试:

- Alias 目标缺失时 docs check 失败。
- 已实现文档仍标记为 open 时触发 warning。
- Handoff 包含 active user confirmation decision。

## Phase 3：组织采用、合规、发布和长期治理

第三阶段让 Orbit 从单项目重流程经验变成可适配、可发布、可迁移、可校准的协作系统。

### Slice 11：Project Profile Risk Level（项目画像和风险等级）

用户问题：一个重流程项目可能让 Orbit 默认值过拟合。小任务会被过度处理，而真正高风险的任务仍然需要更强 gate。

目标行为：由项目画像和 task 风险等级决定默认 gate、证据层级和严格程度。

字段:

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

可选风险级别:

- `light`
- `standard`
- `strict`
- `release`

优先级：`task_risk.minimum_evidence_levels` 从项目画像和风险等级派生，并填充 `review_strategy` / `test_strategy.minimum_evidence_level`（Slice 1）。task 级别的显式最低要求只能提高门槛；如果要低于风险等级默认值，必须记录 waiver。

上面的 `review` / `test` 是常见情况；Slice 1 里的另外两类 gate 通常由 task 类型派生，不必总是显式列出：设计/分析任务会把 review gate 的最低要求提高到 `implementation_readiness`，`release` 风险等级要求 `release_readiness`（Slice 13）。当 task 使用这些 gate 类型时，`minimum_evidence_levels` 也可以显式携带 `design_readiness` / `release` key。

CLI 行为:

- `new-task` 根据 profile 和 risk level 派生默认值。
- `classify-intent` 可以根据风险建议是否需要正式 task/evidence/gates。
- `validate` 按 risk level 应用更严格检查。
- `audit` 说明 task 为什么使用 light/standard/strict/release。

验收标准:

- 一行文档修改可以是 light，不需要正式 gate。
- 改变行为的 UI task 默认是 standard 或 strict。
- Release task 必须要求 release readiness evidence。
- 项目规则仍是补充，不能替代 Orbit core。

测试:

- Light task 不需要 parent goal 和必需 review 也能 validate。
- Strict task 要求 review/test gates 和 write policy checks。
- Release task 要求 release evidence fields。

### Slice 12：Data Classification And Retention（数据分类和留存）

用户问题：Evidence 可能包含 secrets、用户内容、第三方材料、prompts、截图、日志和本地路径。保留太多会产生风险，保留太少会破坏 audit。

目标行为：Artifact 有数据分类和留存策略。出错时有 trust repair 流程。

字段:

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

CLI 行为:

- `evidence add/submit` 接受 artifact classification。
- 敏感 artifact 缺少 retention policy 时，`audit` 给出 warning。
- `compact-evidence` 遵守 hash-only、redact、short-lived policy。
- `handoff` 省略敏感原始内容，只引用脱敏 summary。

验收标准:

- 敏感 artifact 没有 policy 时不能长期保留。
- Hash-only retention 在不复制原始内容的情况下保留证明。
- Incident/trust repair record 在 handoff 中可见。
- 类 secret 内容不能出现在 compact summary 中。

测试:

- 标记为 `secret` 但长期保留原始内容的 artifact 失败。
- 未分类截图按 risk 给出 warning 或 fail。
- Compact summary 排除原始敏感内容。

### Slice 13：CI Release Readiness（CI 和发布就绪）

用户问题：本地 gate pass 不能证明已经可以发布。CI、包内容、生成物、版本字段和远端状态可能不一致。

目标行为：Release task 要把本地信心、CI、包/archive、生成物、版本元数据、release assets 和远端状态分层记录。

字段:

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

CLI 行为:

- `new-task --task-type release` 填入 release readiness 字段骨架。
- `validate` 对 release risk task 要求 release readiness。
- `audit` 区分本地信心和发布就绪。
- `handoff` 单独列出 release blocker，不和 implementation blocker 混在一起。

验收标准:

- Release task 不能只靠本地测试就算 done。
- Package/archive 的 hash 和内容检查被记录。
- CI/remote state 缺失会成为显式 gap。
- Generated artifacts 必须被检查或 waiver。

测试:

- Release task 有本地 review/test pass 但没有 CI status 时，release audit 失败。
- Package hash 缺失时 release readiness 失败。
- Remote branch mismatch 会被报告。

### Slice 14：Protocol Schema Versioning（协议 Schema 版本化）

用户问题：自然语言 report 和结构化字段可能互相矛盾。模板漂移和字段语义变化可能让旧 evidence 看起来比实际更强。

目标行为：Task/report/evidence 字段有版本化语义、一致性检查和 negative evidence 表达。

字段:

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

CLI 行为:

- `evidence submit` 校验 report template version。
- `audit` 检测 summary 和 structured verdict 的冲突。
- `validate` 把未知未来 schema version 当作显式兼容状态处理，而不是静默接受。
- `handoff` 包含 schema version summary。

验收标准:

- Structured verdict（结构化判定）优先于 prose summary（自然语言摘要）。
- Summary 写 PASS 但 structured verdict 是 fail/partial 时触发 conflict。
- 未知 schema version 不能被静默当作当前语义接受。
- Negative evidence（负向证据）可以表达“未测试”，但不等同于失败。

测试:

- Prose 写 PASS、structured verdict 是 fail 时，audit 失败或标记 conflict。
- 旧 template 缺少 feature version 时，audit 标记为 legacy。
- 未知 future schema version 必须进入 compatibility handling。

### Slice 15：Orbit Dogfood And Governance（Orbit 自测和治理）

用户问题：Orbit 不能依赖项目里偶然发生的失败来测试自己。Lessons 如果没有完成标准，会无限增长。

目标行为：每个关键协议风险都有 dogfood case、owner、SLO、进入 roadmap 的路径和停止标准。

字段:

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

CLI 行为:

- Dogfood 第一版可以先放在 tests/fixtures 和 docs index 中，不必马上做专用 CLI。
- `audit` 或测试工具应能把失败的 dogfood case 映射到对应 source adjustment。
- 当协议语义变化时，release checklist 必须包含 dogfood suite status。

验收标准:

- 每个 P0/P1 adjustment 至少有一个 dogfood case。
- 失败 dogfood case 能映射到 source adjustment 和 expected behavior。
- 改变协议的 release 不能跳过 dogfood，除非有 waiver。
- 复盘类 task 必须有 done criteria，不能变成无限 backlog。

测试:

- Stale gate fixture 在修复前失败，修复后通过。
- 只有 transport DONE 的 fixture 不能满足 gate。
- Destructive dry-run fixture 阻止不安全删除。

### Slice 16：Landing Governance And Calibration（落地治理和校准）

用户问题：Compatibility policy、多用户共享、质量校准、自审污染、速度/严谨度取舍、evidence 备份/迁移都不够明确，影响采用。

目标行为：Orbit 有可执行的采用规则，说明如何选择严格程度、如何校准质量、多用户 ownership 如何运作，以及 evidence 如何备份或迁移。

字段:

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

CLI 行为:

- `audit` 报告 compatibility mode 和已知 legacy gap。
- `handoff` 在多用户上下文中说明 ownership assumptions。
- Migration/export 可以先作为文档化流程存在，再演进为 CLI。
- Quality calibration 第一版可以由 scripts/tests 汇总 report data。

验收标准:

- 破坏性 schema 或 gate 变更必须有 compatibility policy。
- 多用户 workspace 能识别 files、panes、artifacts 和 evidence 的 owner。
- Orbit protocol 自身变更必须有 independent check 或 explicit waiver。
- Evidence backup/migration path 必须有 restore check。
- Risk-level 选择要解释速度/严谨度取舍。

测试:

- 当 policy 是 `warn_legacy` 时，针对 legacy evidence 的新 strict rule 应报告 warning，而不是 hard failure。
- 只靠 self-review 的 protocol change 在 strict/release profile 下被阻塞。
- Backup export 缺少 restore check 时 governance audit 失败。

## 跨阶段依赖

- `verdict-evidence-level-schema` 是质量 review、stale verdict、retention summary、runtime reconcile 和 release readiness 的基础。
- `protocol-schema-versioning` 应先做 feature-version scaffolding；完整治理虽然落在 Phase 3，但底座要提前开始。
- `role-identity-and-write-policy-minimum` 保护 Phase 1 gates；full version 完成 Phase 2 的多 agent 可靠性。
- `project-profile-risk-level` 控制后续检查有多严格；早期实现可以 hardcode standard/strict 默认值，但不能阻断未来 profile 支持。
- `landing-governance-and-calibration` 依赖 evidence、profile 和 dogfood data；但最小 compatibility policy 必须在破坏性 validation 变更发布前确定。

## 完整测试矩阵

| 防护的失败模式 | 必需测试 |
| --- | --- |
| 没有证据层级的 PASS 关闭 gate | 缺少 `evidence_level` 的 review pass 不能满足新 task gate。 |
| 机械检查通过了质量任务 | task 要求 `outcome_quality` 时，`mechanical_check` 失败。 |
| Review 忽略质量结果 | 缺少 `quality_outcome_verdict` 或反例回答的 review pass 被拒绝。 |
| Slice pass 被当成 parent done | 父任务完成标准不完整时，不能 audit 为 done。 |
| 用户下一步缺失 | 父任务 handoff 缺少 `user_next_action` 时 validate 或 audit 失败。 |
| Pane DONE 被当成 evidence | 只有 transport message、没有结构化 evidence 时不能满足 gate。 |
| Scope 外文件藏在 pass 里 | `scope.include` 外的 changed file 导致 validate 失败。 |
| Artifact 删除破坏证明链 | 影响 evidence 的 destructive plan 缺少 hash 或 summary 时失败。 |
| Reviewer/tester 写 production files | Strict task gate 阻止或标记 gate 角色 write policy violation。 |
| 旧 evidence 无法使用 | 缺少新字段的历史 manifest audit 为 legacy warning。 |
| Gate verdict 过期 | 旧 task hash 的 review 不能关闭当前 gate。 |
| Evidence 漂移 | Manifest/handoff/latest-record mismatch 被报告。 |
| 运行时不一致 | Real-path test 的 build hash 过期或缺少 server owner 时，必需 evidence 失败。 |
| 旧设计仍保持 active | 已实现设计仍 active/open 时，docs check warning。 |
| 敏感数据被保留 | Secret 或用户内容 artifact 缺少 retention policy 时 audit 失败。 |
| Release 被错误判定 ready | Release task 只有本地 pass、缺少 CI/package/remote evidence 时 release readiness 失败。 |
| Prose 和 structured verdict 冲突 | Structured/prose verdict conflict 导致 audit fail 或标记。 |
| Dogfood 缺失 | Protocol-changing release 没有 dogfood coverage 时被阻塞，或必须显式 waiver。 |
| Self-review 污染 | Orbit protocol change 只由同一系统自审通过时，strict governance 失败。 |
| Backup 未验证 | Evidence migration/export 缺少 restore check 时 governance audit 失败。 |

## 实施顺序

推荐顺序：

1. `protocol-schema-versioning` 最小脚手架：feature versions 和 legacy warning 词汇。
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

这个顺序先处理字段语义，再处理 gate 行为，然后处理长期运行可靠性，最后处理组织采用和发布治理。`protocol-schema-versioning` 在这里的第 1 步只表示 feature-version scaffolding 和 legacy-warning 词汇；它的完整治理范围在 Phase 3 的 Slice 14 完成。

## 非目标

- 本文不决定具体 Ruby class/module 边界。
- 本文不要求所有功能在一个 PR 中发布。
- 当 evidence metadata validation 足以支撑第一版时，本文不强制要求专用 CLI command。
- 本文不把项目特定的 autoNovel 行为变成 Orbit 默认行为。
- 本文不要求 light task 使用 strict workflow。

## 编码前待定决策

- Schema version 是全局递增，还是按 feature section 分别递增。
- Evidence level 不足时，是始终作为 `validate` failure，还是只作为新 task 的 `wait-gate` blocker。
- Changed-file detection 由 git 计算、由 report 提供，还是两者都支持。
- Destructive action 支持从 metadata validation 开始，还是从专用 CLI command 开始。
- 哪些 task type 默认 `parent_goal.required: true`。
- 第一批发布哪些 project profile；profile 放在 `.orbit/roles.yaml`、新 config 文件，还是 task defaults 中。
- Gate lease 存在 evidence manifest、loop state，还是单独 runtime 文件中。
- Runtime reconcile 中多少由 CLI 确定性检查，多少由 user/tester-provided metadata 提供。
- Quality calibration 从人工 audit sample 开始，还是作为 first-class command 开始。
- Evidence migration 接受什么 export/restore format。

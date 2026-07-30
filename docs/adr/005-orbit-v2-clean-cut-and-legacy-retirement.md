# ADR-005：Orbit v2 一次性切换与旧协议退役

- 状态：Accepted
- 日期：2026-07-30
- 范围：Orbit v2 schema、CLI、runtime、evidence、gate、模板、文档和旧协议退役
- 关联：[ADR-003](./003-lead-orchestrated-dynamic-agent-team.md)、[ADR-004](./004-role-rule-context-evidence-binding.md)
- 当前实现状态：仅为切换决策，当前 CLI 和 runtime 仍是 v1

## 背景

ADR-003 将 Orbit 的目标架构改为 Logical Lead 编排的动态 agent team，以 `TaskRevision`、bounded `WorkUnit` 和 append-only `WorkUnitAttempt` 分别管理全局合同、稳定局部 scope、assignment 与执行历史。ADR-004 要求 attempt 绑定 assigned rule resolution，每条 implementation/review/test `EvidenceRecord` 绑定 attempt 和 submitted rule resolution。

这些变化不是向当前字段增加少量可选 metadata。它们改变了：

- task 与局部工作单元的事实边界；
- 静态 role policy 与动态 team state 的边界；
- agent instance、lead session、work unit attempt 和 context generation 的 lifecycle；
- evidence 的生成身份和规则依据；
- gate verdict、finding resolution 和 evaluator replacement 的 arbitration；
- relationship view 可以从哪些权威事实派生。

如果 v2 同时兼容 v1，就必须长期保留两种 task 分解、两种 team truth、两种 rule binding 和两种 gate arbitration。兼容层会把重构要消除的双事实源、隐式 fallback 和错误归因重新引入目标架构。

项目 owner 已明确决定：Orbit v2 不承担 v1 runtime artifact 或协议语义的兼容责任。

## 决策

Orbit v2 采用一次性 clean cut：

1. 不提供 v1/v2 双写。
2. 不提供 v1 artifact 的 runtime reader compatibility。
3. 不根据旧字段、文件时间、角色名称、当前 manifest 指针或自由文本推断 v2 事实。
4. 不自动 backfill `work_unit_id`、agent instance、rule context、acceptance ID 或 finding resolution。
5. 不保留“新字段缺失时回退旧字段”的 validator、gate 或 handoff 路径。
6. v1 task/evidence/state/handoff 输入 v2 CLI 时返回明确的 `unsupported_schema_version`。
7. 需要在 v2 中继续的工作必须按 v2 contract 重新初始化；CLI 不自动删除旧 artifact。
8. v2 writer、reader、validator、gate、模板、测试和 runtime documentation 必须在同一 cutover 中切换。
9. v2 项目必须具有 create-only protocol root marker，声明 `protocol_epoch: orbit-v2`；所有 project-scoped 命令在读取或写入其他 artifact 前验证 marker 和输入 epoch。
10. marker 缺失、epoch 不匹配，或 active protocol root 中同时出现 v1/v2 权威 artifact 时 fail closed；不通过“优先读新版”容忍混合状态。

不考虑兼容不等于允许静默破坏。CLI 必须在任何会重建或删除用户本地状态的动作前明确列出目标并要求显式授权；默认行为是拒绝旧 schema，而不是自动覆盖。

## v2 权威对象

| 对象 | 唯一权威职责 |
| --- | --- |
| `ProtocolRoot` | project identity、`protocol_epoch: orbit-v2`、immutable `project_policy_genesis_ref`；marker 所在目录定义 active artifact root，不承载 task 业务事实 |
| `ProjectPolicyRevision` | create-only bootstrap/rotation lineage：protected gate minimum、waiver/risk-owner/adjudicator/update authority 与 user/control-plane authorization provenance |
| `TaskRevision` | `goal`、non-goals、quality outcome、带稳定 ID 的 acceptance/source/evidence requirements、task questions、`GateRequirement`、exact `project_policy_revision_ref` |
| `WorkUnit` | 稳定局部 objective、authority scope、input/output refs、stop conditions、TaskRevision requirement refs 和 immutable initial ChangeThesis ref |
| `ChangeThesis` revision | work-unit-scoped、create-only 的可证伪主张；稳定 `change_thesis_id + revision + digest` |
| `WorkUnitAttempt` | append-only assignment/execution history：agent instance、context generation、authority snapshot、ChangeThesis ref、assigned rule resolution、start/end/status events |
| `LogicalLead` / `LeadSession` | 编排身份、session generation、durable recovery continuity |
| `AgentInstance` | runtime identity、capability/permission profile 和 instance lifecycle；当前 roster 从 AgentInstance/Attempt 派生 |
| `RuleResolutionArtifact` | content-addressed、create-only 的 assigned/submitted required rule 集合及内容摘要 |
| `EvidenceRecord` | create-only：`attempt_id`、submitted rule resolution、artifact、observation/requirement result 和可复核 provenance；不拥有 evaluator verdict/finding |
| `GateRequirement` | TaskRevision 声明的 gate kind、independence、question/acceptance refs、evidence level、waiver policy 和 canonical subject selector/freshness policy |
| `GateEvaluation` | create-only：唯一 evaluator verdict/answers、`evaluator_attempt_id`/submission record 和 immutable canonical subject manifest/digest |
| `Finding` | create-only：GateEvaluation 产生的唯一稳定问题 body/identity、severity、blocking 属性和原始证据 |
| `FindingResolution` | append-only Finding `addressed|disproved|waived` event、不可变 issuer authority provenance 和依据 |
| `CodeSurface` / `RelationshipView` / `AggregateOutcome` | 从上述对象、artifact refs 和 repository snapshot 确定性派生；不是独立写入事实源 |

每项权威事实只属于一个对象。其他对象只能引用稳定 ID，不复制一份可独立修改的同义合同。

`WorkUnitAttempt` 是 assignment 的唯一权威对象：预分配 `attempt_id` 后先 create/reuse assigned RuleResolutionArtifact，再一次性追加包含该 ID 的 immutable `AttemptCreated` payload；禁止 post-create patch。该 event timestamp 是唯一 `started_at` 来源并建立 initial active status，end/status 由后续 append-only events 派生。v2 不另建可覆盖的 assignment/current-worker 事实源。每条正式 EvidenceRecord 必须引用 `attempt_id`，active roster 只能由 open attempts 与 AgentInstance lifecycle 派生。

WorkUnit 只有 immutable `initial_change_thesis_ref`。每个 Attempt pin 确切 `ChangeThesis revision + digest`；thesis 改变必须创建 successor attempt，不能覆盖 WorkUnit pointer。current/active thesis 只能从 active attempts 确定性派生；并发 refs 不同必须显示集合/冲突，不能 latest-wins。

GateEvaluation 是 evaluator verdict/answers 的唯一事实源，Finding 是 finding body/identity 的唯一事实源。review/test EvidenceRecord 只保存 submission provenance。每个 GateEvaluation 必须直接绑定 `evaluator_attempt_id` 和同 attempt submission EvidenceRecord，同时 pin subject TaskRevision、一个或多个 subject WorkUnit、全部 subject implementation Attempt/EvidenceRecord refs，以及 GateRequirement 要求的 repository snapshot/derived CodeSurface digest；不得重载一个 `work_unit_id` 同时表达 evaluator 与 subject。

GateRequirement 冻结 task-wide/selected-work-unit selector、subject inclusion 和 freshness policy；GateEvaluation 冻结 selector 解析出的 canonical subject digest。Gate Engine 对全部 subject producer agents 计算 independence，并拒绝 missing/non-accepted/stale ref、漏 subject、snapshot/surface drift。subject 变化后旧 GateEvaluation 仍保留，但不能关闭新结果。

EvidenceRecord、GateEvaluation 和 Finding 均 create-only/immutable，并保存 canonical content digest；`accepted` 表示 controlled writer 在创建时接纳，后续 stale/closure validity 只派生、不回写。纠错或重评只能新建 ID 并使用受校验的 supersedes/related refs。同 ID 异内容、原地覆盖或删除 fail closed，supersedes 不自动关闭旧 blocking Finding。

`AggregateOutcome` 只能由 Gate Engine 根据 active ProjectPolicyRevision/TaskRevision、GateRequirement current subject selector、subject digest 完全匹配且未 stale 的 GateEvaluation、acceptance results、Finding/FindingResolution 和 residual risk 确定性派生。持久化时只能作为带 source IDs/digests 的可删除 cache，不能由 agent/Lead 直接写入推进状态。

`FindingResolution` authority 固定为：

- implementation EvidenceRecord 只能提出 `addressed`；confirmation 必须绑定 authorized evaluator attempt、同 attempt submission/rule context 和 supporting refs；
- `disproved` 必须绑定 authorized evaluator/adjudicator attempt、同 attempt submission/rule context 和反证 refs；
- `waived` 必须绑定 active ProjectPolicyRevision 或由其授权的 TaskRevision authorization record；自由文本 issuer 无效；
- Gate Engine 只校验 issuer、引用和完整性并派生 closure；
- Logical Lead 默认不能单方面 waive required independent gate。

FindingResolution event 本身也不可覆盖或删除；issuer/authority/supporting refs 一经追加不可修改。任一被引用 EvidenceRecord/GateEvaluation/Finding 缺失或 digest 不符时 closure fail closed。

Initial TaskRevision 不存在 parent authority fallback。ProtocolRoot 必须锚定由 user-controlled bootstrap path 创建的 ProjectPolicyRevision genesis；该 policy 的 external user/control-plane authorization source、project binding 和 content digest 必须可复核，Lead/task writer/candidate 中的名字不能成为信任根。缺 genesis/authorization、伪 ref/digest 或 initial contract 弱于 policy minimum 时 fail closed。

Initial TaskRevision 可增加更严格 GateRequirement，但 protected minimum、waiver policy 和 risk-owner/adjudicator authority 必须引用或收窄 active policy grants；task-specific authority 必须绑定 policy-authorized immutable authorization record，不能由 initial candidate 新建信任根。

每个 ProjectPolicyRevision 至少包含 stable `policy_revision_id`、`project_id`、可空 genesis `parent_policy_revision_id`、`authorization_source_ref + assertion_digest`、protected policy body 和 `content_digest`。authority verifier 必须通过配置的 trusted user/control-plane provider 解析 authorization source；无法解析的 opaque string 或 agent 自填 assertion 不是授权。

Bootstrap 顺序固定为：user authority writer create genesis policy → verifier 复核 policy identity/digest/authorization → `init` create ProtocolRoot 并写 immutable genesis ref。ProtocolRoot 不得先以空 ref 激活再回填；root 创建失败时未引用 policy 不是 active trust root。

TaskRevision revision 也不能绕过该 authority。child revision 必须继承 protected GateRequirement lineage、最低强度、waiver/adjudication authority provenance 和 unresolved blocking Finding。删除/降级 gate、放宽 independence/evidence/waiver policy 或重设 risk owner/adjudicator，只能由当前/父 revision 已授权的 user/risk authority 或更高门槛的 active ProjectPolicyRevision 批准；validator 使用变更前 authority，不使用 candidate revision 新声明的 authority。candidate revision envelope 必须保存 parent revision、canonical protected-change digest、authority-source revision、issuer、policy ref 和 issued-at provenance。Lead 不能通过 revision-hop 自授 risk-owner/adjudicator authority，unresolved Finding 在 authorized resolution 前持续阻塞。

ProjectPolicyRevision 的 active policy 确定性定义为受控 create-only store 中从 ProtocolRoot genesis 出发的唯一有效 lineage tip，不另设可覆盖 pointer。rotation 只能创建引用该 tip 的 successor，由 parent 已授权 update authority 签发，并与当前 tip 原子 compare-and-append。禁止原地覆盖、按时间 latest-wins 或 successor 自授更新权；lineage fork 或多个有效 tip 时 fail closed。rotation 不改写旧 TaskRevision，但使其 closure stale；继续执行必须创建绑定 active policy successor 的新 TaskRevision。

## Protocol root 与 epoch

每个 v2 项目根必须存在 create-only marker，例如：

```yaml
# .orbit/protocol.yaml
schema_version: orbit-protocol-root-v1
protocol_epoch: orbit-v2
project_id: orbit-project-...
project_policy_genesis_ref:
  policy_revision_id: policy-genesis-...
  digest: sha256:...
created_at: ...
```

active artifact root 由 marker 文件的 canonical parent directory 唯一确定；在上述布局中就是 `.orbit/`。不再从配置、cwd、manifest pointer 或另一个可写字段选择 root，marker 示例因此无需第二个 `artifact_root` 字段。

约束如下：

1. `protocol_epoch` 一经创建不得原地改写；marker parent 必须位于 project root 内且通过 symlink/containment 校验。切换 epoch 必须使用显式的新 root/reinitialize 流程。
2. 所有 project-scoped 命令先定位并验证 marker，再解析 task、attempt、evidence、state、gate、rules 或 handoff。`help`/`version` 等不读取项目状态的命令除外；`init` 只能在无 active root 时创建 marker，遇到 v1 `.orbit` 不得覆盖。
3. `project_policy_genesis_ref` 在 ProtocolRoot 创建后不可替换，只引用 immutable policy ID/digest，不复制 protected gate 或 authority body。Task/policy 命令必须从该 ref 验证线性 active policy lineage。
4. 每个 v2 权威 artifact 都携带 `protocol_epoch: orbit-v2` 和 `project_id`。输入缺失、不同 epoch 或不同 project 时返回结构化错误。
5. preflight 检查 active protocol root 中已知权威 artifact 目录；发现 v1/v2 混合时，任何读取、写入、validate、gate、audit、handoff 或 cleanup 命令都 fail closed。
6. v1 archive 只能位于 active protocol root 之外，且不能被 v2 reader 用于 closure。
7. 不提供自动迁移、自动 backfill、marker 就地升级或“忽略旧文件继续运行”选项。

## v2 必须关闭的旧路径

Cutover 必须删除或使下列路径无法继续写入、读取或关闭权威状态：

- 没有 WorkUnit 的正式 implementation/review/test evidence；
- 没有 `WorkUnitAttempt` / `attempt_id` 的正式 EvidenceRecord；
- 先创建 WorkUnitAttempt、再 patch `assigned_rule_resolution_id`，或从 snapshot 字段和 lifecycle event 双写 start/status；
- 把 agent、assignment、context generation、authority 或 status 原地覆盖到稳定 WorkUnit；
- 把可覆盖 current ChangeThesis ref 写入 WorkUnit，或用 latest attempt 静默覆盖并发 thesis；
- 用可覆盖 roster/current-worker 列表替代 append-only attempt history；
- `decomposition.child_slices` 与 WorkUnit 并行表达运行时工作分解；
- `parent_goal` 与 root WorkUnit 并行表达目标恢复；
- `.orbit/instances.yaml` 或静态配置作为 live team roster；
- manifest 顶层单一、可覆盖的 `rule_resolution`；
- 可覆盖的 `current-resolution.json` 或同路径重写的 rule resolution；
- record 只保存任意 64 位 rules context hash，而不复核 resolution 内容和 role；
- rule resolution hash domain 包含 `resolution_id`/自身 digest/`created_at`，或相同 identity 重复解析得到不同 ID；
- `required_rule_files_read` 作为 gate 读取证明；
- 没有明确稳定 rule-ID 消费者的 `applied_checks`；
- acceptance 只有无稳定 ID 的自由字符串，却被 record 当作可寻址 requirement；
- `quality_question_answers` 不绑定 TaskRevision question IDs，或 `acceptance_results` 不绑定 acceptance IDs；
- `implementation_check` 不绑定具体 ChangeThesis revision/digest；
- review/test EvidenceRecord 保存 evaluator verdict/answers/finding，并与 GateEvaluation 形成双事实源；
- GateEvaluation 缺 `evaluator_attempt_id`，或其 submission record 不属于同一 attempt/规则上下文；
- GateEvaluation 没有 canonical subject manifest，重载 evaluator `work_unit_id` 作为 subject，漏掉 task-wide WorkUnit/Attempt/EvidenceRecord，或复用旧 pass 到新 subject/snapshot；
- independence 只比较一个 implementation author，而不是全部 subject producer agents；
- EvidenceRecord、GateEvaluation、Finding 原地覆盖/删除，或用 supersedes 隐藏旧 blocking Finding；
- FindingResolution event 覆盖/删除，或修改既有 issuer/authority/supporting refs；
- FindingResolution 使用自由文本 issuer，或 addressed/disproved 不绑定 issuer attempt/submission/rule context，waived 不绑定 policy/authorization record；
- `latest_valid_for_task_revision` 仅按时间覆盖同 revision 的旧 fail；
- evaluator replacement 导致旧 blocking finding 消失；
- Lead 通过新 TaskRevision 删除/降级 protected gate、改变 waiver/adjudication authority/risk owner 或清除 unresolved Finding；
- initial TaskRevision 自报 genesis authority、ProtocolRoot 缺/伪造 policy genesis ref，或 ProjectPolicyRevision 原地更新/latest-wins/fork；
- 含混的 `Goal`、`Evidence`、`Gate` 权威节点，而不是 `TaskRevision.goal`、`EvidenceRecord`、`GateRequirement`/`GateEvaluation`；
- 把派生 `CodeSurface` 或 `RelationshipView` 当作可写事实源；
- 把派生 `AggregateOutcome` 当作 agent/Lead 可写 verdict 或状态推进事实源；
- 缺失 protocol root marker、epoch 不匹配或 active root 内 v1/v2 混合时继续运行；
- v1 schema/version fallback、guess、backfill 或 compatibility branch。

删除字段名称本身不是 closure proof。必须证明旧 writer 不能继续生成权威 artifact，旧 reader/gate 不能继续接受旧语义，旧模板和 runtime guide 也不再指导用户走旧路径。

## Cutover 行为

v2 CLI 遇到 v1 artifact 时返回结构化错误，例如：

```yaml
error: unsupported_schema_version
actual: orbit-evidence-v1
expected: orbit-evidence-v2
protocol_epoch: orbit-v2
next_action: reinitialize_under_orbit_v2
```

`reinitialize_under_orbit_v2` 是显式的新建流程，不是自动迁移：

- 不覆盖原文件；
- 不声称旧 evidence 已在新规则或 work unit 下产生；
- 不把旧 gate verdict 复制成 v2 accepted verdict；
- 用户可以自行保留旧目录作为非运行时 archive；
- v2 runtime 不读取 archive 关闭当前 gate。

缺失或混合 epoch 使用独立错误，不伪装成普通 schema validation：

```yaml
error: protocol_epoch_mismatch
expected: orbit-v2
actual:
  - orbit-v1
  - orbit-v2
next_action: choose_clean_orbit_v2_root
```

## 实施和发布约束

代码可以按内部 slice 开发，但正式 cutover 必须满足：

1. v2 schema、protocol epoch、ProjectPolicyRevision bootstrap/rotation 和 object authority 已冻结。
2. 所有 CLI writer 只在通过 root/epoch preflight 后生成 v2。
3. 所有 reader、validator、audit、handoff 和 gate 先验证 root/epoch，只接受 v2。
4. WorkUnitAttempt atomic create/history、派生 dynamic roster、deterministic content-addressed rule resolution、create-only EvidenceRecord/GateEvaluation/Finding 与 append-only FindingResolution 已连通。
5. 完整 `ProtocolRoot → ProjectPolicyRevision → TaskRevision → WorkUnit → implementation subject → evaluator Attempt/EvidenceRecord → subject-pinned GateEvaluation → FindingResolution → derived AggregateOutcome` E2E 通过。
6. v1 fallback 和兼容测试已删除，替换为 unsupported-schema 负向测试。
7. `skills/orbit/references/runtime/`、templates、help 和 examples 与 v2 实现原子更新。
8. repository-wide closure audit 证明旧路径不能再写权威 artifact，混合 epoch 不能继续运行。
9. validator 证明 protected gate lineage、parent-authority approval 和 unresolved Finding 不能被 revision-hop 绕过。
10. GateRequirement subject selector、GateEvaluation canonical subject/freshness/producer independence 和 immutable record lifecycle 具有正负向测试。

在完成这些条件前，不能把部分 v2 字段加入 v1 正式 API，也不能提前修改 runtime reference 声称 v2 已生效。

## 不采用的方案

- v1/v2 长期双写；
- reader 接受两套 schema、writer 只写新 schema；
- 启动时自动升级本地 `.orbit`；
- 根据旧 task/evidence 推断 WorkUnit、rule context 或 finding resolution；
- 在现有 v1 `.orbit` 中就地写入 `protocol_epoch: orbit-v2`；
- marker 缺失或混合 epoch 时选择“最新”artifact 继续运行；
- 保留旧 gate 作为 fallback；
- 让 Lead 通过 child revision 重置 protected gate/finding authority；
- 让 initial TaskRevision 或 Lead 自报 ProjectPolicy genesis authority；
- 让 review EvidenceRecord 与 GateEvaluation 同时拥有 verdict；
- 让 subject-less/stale GateEvaluation 关闭后来实现，或原地改 verdict/finding；
- 让 AggregateOutcome 成为可直接写入的状态；
- 以“deprecated”名义继续让旧路径写权威状态；
- 为减少一次性改动而让新旧事实源长期并存。

## 后果

- Orbit v2 可以围绕单一目标模型设计，不承担旧协议形状带来的永久复杂度。
- v1 task、evidence、state 和 handoff 不能直接用于 v2 gate closure。
- 使用者需要显式重新初始化仍要继续的工作。
- 使用者必须在 clean v2 protocol root 中运行；v1 archive 不得留在 active root。
- cutover 的单次改动面和验收面较大，必须用完整 E2E、closure audit 和删除检查控制风险。
- 当前 v1 runtime 不因本 ADR 自动变化；只有实现、模板、测试和 runtime 文档完成原子切换后，v2 才成为生效协议。

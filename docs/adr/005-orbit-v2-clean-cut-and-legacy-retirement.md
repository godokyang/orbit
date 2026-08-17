# ADR-005：Orbit v2 一次性切换与旧协议退役

- 状态：Accepted；2026-08-17 部分修订——并行边界与 cross-control cutover 条款被文末修订记录取代
- 日期：2026-07-30
- 范围：Orbit v2 schema、CLI、runtime、evidence、gate、模板、文档和旧协议退役
- 关联：[ADR-003](./003-lead-orchestrated-dynamic-agent-team.md)、[ADR-004](./004-role-rule-context-evidence-binding.md)、[ADR-006](./006-serialized-lead-orchestration-control-loop.md)
- 当前实现状态：仅为切换决策，当前 CLI 和 runtime 仍是 v1

## 背景

ADR-003 将 Orbit 的目标架构改为 Logical Lead 编排的动态 agent team，以 `TaskRevision`、bounded `WorkUnit` 和 append-only `WorkUnitAttempt` 分别管理全局合同、稳定局部 scope、assignment 与执行历史。ADR-004 要求 attempt 绑定 assigned rule resolution，每条 implementation/review/test `EvidenceRecord` 绑定 attempt 和 submitted rule resolution。

ADR-006 将该编排进一步冻结为 project-scoped stable `lead_control_id` 下严格串行：多 Task queue 中最多一个 active LeadSession、一个 active Task、一个 selected WorkUnit 和一个 non-terminal WorkUnitAttempt；terminal Attempt 与下一次 dispatch 之间必须存在受控、线性的 accepted LeadCheckpoint。Lead runtime、AgentInstance/LeadSession/context 是可替换执行载体，不是 control identity。不同 control lineage 只有 Task ownership sets 与 provider-verified active runtime subject sets 都不相交时才可并行；AgentInstance 别名不能绕过 executor 唯一性。

> **已取代（2026-08-17）**：本段中「不同 control lineage 只有 Task ownership sets 与 provider-verified active runtime subject sets 都不相交时才可并行」的并行边界已按 task-centric 模型取代，见文末修订记录。

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
11. v2 激活前必须同时闭合 ADR-006 的 provider-subject/session/control/genesis atomic create、stable control identity、cross-lineage Task ownership/transfer、provider-verified runtime-subject active-session uniqueness/transfer、controlled fingerprint identity/provenance separation 与 prior-chain、single-active LeadSession/Task/WorkUnit/Attempt、project-wide Task/WorkUnit Attempt backstop、unique-root/reachability、checkpoint-before-dispatch 和 no-parallel-legacy-path 条件；任一条件未证明时不得 cutover。
   > **已取代（2026-08-17）**：本条中 cross-lineage Task ownership/transfer、provider-verified runtime-subject active-session uniqueness/transfer、project-wide backstop 等 project-wide 多 control 闭合条件已按 task-centric 模型取代；genesis atomic create、Task 内 single-active、unique-root/reachability、checkpoint-before-dispatch 与 no-parallel-legacy-path 保留，见文末修订记录。

不考虑兼容不等于允许静默破坏。CLI 必须在任何会重建或删除用户本地状态的动作前明确列出目标并要求显式授权；默认行为是拒绝旧 schema，而不是自动覆盖。

## v2 权威对象

| 对象 | 唯一权威职责 |
| --- | --- |
| `ProtocolRoot` | project identity、`protocol_epoch: orbit-v2`、immutable `project_policy_genesis_ref`；marker 所在目录定义 active artifact root，不承载 task 业务事实 |
| `ProjectPolicyRevision` | create-only bootstrap/rotation lineage：protected gate minimum、waiver/risk-owner/adjudicator/update authority 与 user/control-plane authorization provenance |
| `TaskRevision` | `goal`、non-goals、quality outcome、带稳定 ID 的 acceptance/source/evidence requirements、task questions、`GateRequirement`、exact `project_policy_revision_ref` |
| `WorkUnit` | 稳定局部 objective、authority scope、input/output refs、stop conditions、TaskRevision requirement refs、exact parent/dependency refs、唯一 root reachability 和 immutable initial ChangeThesis ref |
| `ChangeThesis` revision | work-unit-scoped、create-only 的可证伪主张；稳定 `change_thesis_id + revision + digest` |
| `WorkUnitAttempt` | append-only assignment/execution history：exact predecessor/dispatch checkpoint refs、agent instance、context generation、authority snapshot、ChangeThesis ref、assigned rule resolution、start/end/status events |
| `LogicalLead` / `LeadSession` | per-task continuity、session generation、provider-verified canonical runtime subject binding、durable recovery continuity；每个 control 最多一个 active session且每个 project/runtime subject 最多绑定一个 active session |
| `lead_control_id` / control registry | project-scoped stable control identity、唯一 genesis、受控 writer authority、跨 lineage Task ownership/transfer、canonical runtime-subject active-session binding 和 global Attempt backstop |
| `LeadCheckpoint` | create-only、append-only linear accepted lineage：exact `lead_control_id`/active session/runtime subject、有序 task queue、唯一 selection、四层 assessment、controlled/versioned fingerprint identity/hash、separate supporting provenance/prior chain、progress delta、LeadDecision 与 next trigger 的 exact refs/provenance |
| `AgentInstance` | 本地 runtime instance、capability/permission profile 和 lifecycle；不能代替 provider-verified canonical runtime subject，当前 roster 从 AgentInstance/Attempt 派生 |
| `RuleResolutionArtifact` | content-addressed、create-only 的 assigned/submitted required rule 集合及内容摘要 |
| `EvidenceRecord` | create-only：`attempt_id`、submitted rule resolution、artifact、observation/requirement result 和可复核 provenance；不拥有 evaluator verdict/finding |
| `GateRequirement` | TaskRevision 声明的 gate kind、independence、question/acceptance refs、evidence level、waiver policy 和 canonical subject selector/freshness policy |
| `GateEvaluation` | create-only：唯一 evaluator verdict/answers、`evaluator_attempt_id`/submission record 和 immutable canonical subject manifest/digest |
| `Finding` | create-only：GateEvaluation 产生的唯一稳定问题 body/identity、severity、blocking 属性和原始证据 |
| `FindingResolution` | append-only Finding `addressed|disproved|waived` event、不可变 issuer authority provenance 和依据 |
| `CodeSurface` / `RelationshipView` / `AggregateOutcome` | 从上述对象、artifact refs 和 repository snapshot 确定性派生；不是独立写入事实源 |

> **已取代（2026-08-17）**：上表中 `lead_control_id` / control registry 行的「project-scoped」定性、跨 lineage Task ownership/transfer、canonical runtime-subject active-session binding 和 global Attempt backstop 职责已按 task-centric 模型取代——control identity 收窄为 Task-scoped，不存在 cross-control transfer 与 project-wide registry，见文末修订记录。

每项权威事实只属于一个对象。其他对象只能引用稳定 ID，不复制一份可独立修改的同义合同。

`WorkUnitAttempt` 是 assignment 的唯一权威对象：预分配 `attempt_id` 后先 create/reuse assigned RuleResolutionArtifact，再一次性追加包含该 ID 的 immutable `AttemptCreated` payload；禁止 post-create patch。该 event timestamp 是唯一 `started_at` 来源并建立 initial active status，end/status 由后续 append-only events 派生。v2 不另建可覆盖的 assignment/current-worker 事实源。每条正式 EvidenceRecord 必须引用 `attempt_id`，active roster 只能由 open attempts 与 AgentInstance lifecycle 派生。同一 `lead_control_id` 的 open Attempt cardinality 必须小于等于一；project-wide 每个 Task 和每个 WorkUnit 的 non-terminal Attempt cardinality 也必须小于等于一。successor 还必须 pin control identity，并引用 terminal predecessor 和授权 dispatch 的当前 accepted LeadCheckpoint。

> **已取代（2026-08-17）**：本段中 per-Task/per-WorkUnit backstop 的 project-wide 定性已按 task-centric 模型收窄为 Task-local（存储按 task_id 隔离后天然成立）；单 active Attempt 与 successor pin control identity 语义保留，control scope 收窄为 Task，见文末修订记录。

WorkUnit 只有 immutable `initial_change_thesis_ref`。每个 Attempt pin 确切 `ChangeThesis revision + digest`；thesis 改变必须在旧 Attempt terminal 和 LeadCheckpoint 接受后创建 successor，不能覆盖 WorkUnit pointer。current/active thesis 只能从零或一个 active Attempt 确定性派生；历史 refs 不同必须保留 provenance，不能 latest-wins。

LeadCheckpoint 不复制 TaskRevision、EvidenceRecord、GateEvaluation、Finding 或 AggregateOutcome truth。它只通过 exact refs 保存 coordinator selection、分层 assessment、Delivery/Assurance delta、decision 和 next trigger，并以原子 compare-and-append 维持唯一 lineage tip；fork 或多个 tip fail closed。LeadControl 只在这些权威 facts 上执行 `reconcile(authoritative_facts, trigger) -> LeadDecision`，不成为新的 goal/evidence/gate 事实源。

`lead_control_id` 不等同 AgentInstance/LeadSession/runtime。每条 lineage 只有 project/policy/writer-bound 的唯一 accepted genesis；每个 checkpoint/dispatch/Attempt pin exact control ID。每个 LogicalLead/Task 任一时刻最多属于一个 open lineage queue，且最多由一个 tip active-selected。每个 active LeadSession 还必须 pin 由 trusted runtime identity provider 解析的 canonical `lead_runtime_subject_ref + assertion_digest`；同一 project/runtime subject 最多绑定一个 active session，即使使用不同 AgentInstance ID/别名也视为同一 executor。

genesis 顺序固定为：trusted provider 先解析 canonical runtime subject；受控 writer 随后在一个原子操作中 claim `lead_control_id`、绑定唯一 active LeadSession/runtime subject，并创建 accepted genesis LeadCheckpoint。genesis 必须保存 active session generation 与 subject assertion；不得接受 session-less/subject-less genesis 再回填，也不得在原子操作失败后留下 claimed ID、active session、accepted checkpoint 或可 dispatch 半状态。

controlled writer 必须跨 project 内所有 open lineages 原子校验 Task ownership 与 runtime-subject binding，并在 checkpoint acceptance、session activate/replace 和 dispatch 前执行。Task transfer 必须由旧 checkpoint release/relinquishing-suspend 后，新 checkpoint 以 exact provenance acquire；executor transfer 必须 old session terminal/release 后 new successor/bind，或以受控原子 transfer 同时完成。重复 genesis、双 ownership、同 runtime subject 双 control active binding、双 active LeadSession 或非当前 session dispatch fail closed。

> **已取代（2026-08-17）**：本段中跨全部 open lineages 的原子 Task ownership 校验与 Task/executor transfer 协议已按 task-centric 模型取代——不存在 cross-control Task transfer；Task 内的 session replacement、dispatch 前校验与 fail-closed 语义保留，见文末修订记录。

每个需要 work 的 TaskRevision 恰好一个 root WorkUnit，其他 WorkUnit 通过 parent tree 从 root 可达；dependency refs 只是同 revision 内的额外 DAG ordering。multiple root、orphan、cycle 或 cross-revision edge 无效。

failure/finding fingerprint 只能由 LeadControl/受控 writer 在 Attempt terminal 后产生并写入 accepted LeadCheckpoint。`fingerprint_identity_basis` 是唯一 hash 输入：canonicalization version、TaskRevision/WorkUnit scope、typed category/code、stable Finding identity，或非 Finding failure 的 stable test/rule/check identity + stable signal subject identity + normalized failure code。

每轮变化的 terminal Attempt、当前 Finding/GateEvaluation/test/validator outcome refs+digests、authoring checkpoint 和 ordered prior Attempt chain 只属于 `fingerprint_supporting_provenance`，不参与 fingerprint hash。Finding message、free text、path/order、`lead_control_id`、Attempt/checkpoint/session/AgentInstance 和 outcome record identity/digest 也不进入 hash。writer 必须验证 supporting provenance 支持 identity basis，并跨 checkpoints 与 Task transfer provenance 检查 prior chain；chain 只用于计数和 retry authorization scope。相同 stable test/check signal 即使 Attempt/outcome record 不同也必须得到同一 fingerprint；stable Finding identity 相同而 GateEvaluation 更新也必须相同；typed code 或 stable signal identity 不同则 fingerprint 不同。identity/provenance/chain 无法证明时 freeze，不得自动视作新 failure。

第三次相同 failure/finding fingerprint retry 只能使用 provider-verified、create-only immutable `AuthorizationRecord`，semantic action 为 `task.retry.override`，scope digest exact bind project/TaskRevision/WorkUnit/fingerprint/prior Attempt chain/authorizing checkpoint/`lead_control_id`；Lead/agent 自报、opaque ref 和 replay 无效。wall-clock fallback 只能来自 exact active ProjectPolicyRevision orchestration policy 或其授权的 immutable record，LeadCheckpoint pin exact ID/digest；mutable config 或 stale digest fail closed。

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
- 把可覆盖 current ChangeThesis ref 写入 WorkUnit，或用 latest attempt 静默覆盖历史 thesis refs；
- 用可覆盖 roster/current-worker 列表替代 append-only attempt history；
- 同一 `lead_control_id` 同时存在多个 non-terminal WorkUnitAttempt，或让 implementation、review、test、research、release 并行；
- > **已取代（2026-08-17）**：本条中 control identity 的 scope 已从 project 收窄为 Task；Task 内单 non-terminal Attempt 与串行约束保留，见文末修订记录。
- 把 AgentInstance/LeadSession/runtime identity 当成 control identity、为同一 Task 创建第二 `lead_control_id`/genesis，或接受未经受控 writer 原子写入的 checkpoint；
- 在 trusted provider 解析 runtime subject/绑定 active LeadSession 前接受 genesis，或原子创建失败后留下 claimed control/session/checkpoint 半状态；
- 同一 LogicalLead/Task 同时属于多个 open control queues，transfer 缺 old release/suspend → new acquire provenance，或不同 control lineages 以重叠 task sets 并行；
- > **已取代（2026-08-17）**：本条以「同项目多 control lineage」为前提（多 queue 归属、transfer provenance、重叠 task sets 并行），已按 task-centric 模型取代——一个 Task 只允许一条 accepted control lineage，不存在 cross-control transfer，见文末修订记录。
- 同一 `lead_control_id` 有两个 active LeadSession，replacement 不 terminal old/原子 successor，或非当前 session dispatch；
- 同一 provider-verified runtime subject 以相同或不同 AgentInstance ID 同时绑定两个 control IDs，或仅比较 AgentInstance 字符串而接受第二个 session activation/dispatch；
- > **已取代（2026-08-17）**：本条以同项目多 control lineage 为前提，已按 task-centric 模型取代——不存在同项目多 control 之间的 runtime-subject/session transfer，见文末修订记录。
- coordinator facts 损坏时仍允许同一 Task/WorkUnit 出现第二个 non-terminal Attempt；
- TaskRevision 有 multiple root/orphan WorkUnit，或 parent/dependency cross-revision/cycle；
- 第三次同 fingerprint retry 接受 Lead/agent 自填、opaque、scope 不完整或可 replay 的 authorization ref；
- fingerprint 把 Attempt/checkpoint/GateEvaluation/test/validator outcome record ID/ref/digest 混入 identity hash，接受 agent/free-text/message wording，因 rename/reorder/AgentInstance alias 改变 identity，遗漏跨 checkpoint/transfer prior chain，或稳定 signal identity/provenance 不可证明时自动当作新 failure；
- > **已取代（2026-08-17）**：本条中「跨 Task transfer」prior-chain 语义已移除，Task 内跨 checkpoint prior chain 保留，见文末修订记录。
- wall-clock fallback 从 mutable project config/环境值读取，或 checkpoint 不 pin active policy/authorized record exact ID/digest；
- active Attempt 未 terminal 时切换 Task，或没有当前 LeadCheckpoint/predecessor binding 就创建、dispatch successor；
- LeadCheckpoint 原地覆盖、按时间 latest-wins、lineage fork 后继续运行，或复制 task/evidence/gate truth；
- Work Agent 自行创建/dispatch child work，或修改 task queue、priority、active Task、selected WorkUnit；
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
11. ADR-006 的 provider-subject/session/control/genesis atomic create、stable `lead_control_id`/unique genesis、provider-verified runtime-subject project-wide active-session uniqueness/transfer、strict single-active LeadSession/Task/WorkUnit/Attempt validator、unique-root/reachability、checkpoint-before-dispatch、terminal-predecessor binding、single-writer control 和 checkpoint fork recovery 已闭合。
   > **已取代（2026-08-17）**：本条中 provider-verified runtime-subject project-wide active-session uniqueness/transfer 与多 control 前提的 single-writer control 表述已按 task-centric 模型取代；genesis atomic create、Task 内 single-active 与 checkpoint fork recovery 保留，见文末修订记录。
12. project-wide writer/validator 已在 checkpoint acceptance、session activate/replace 和 dispatch 前闭合 cross-lineage Task ownership/transfer、canonical executor subject binding、task+executor disjoint parallelism 与 per-Task/per-WorkUnit non-terminal Attempt backstop。
   > **已取代（2026-08-17）**：本条整条为 cross-lineage 闭合条件，已按 task-centric 模型取代为 Task 内闭合（单 lineage、单 active、Task-local backstop），见文末修订记录。
13. `fingerprint_identity_basis`/`fingerprint_supporting_provenance` hash-domain separation、stable-signal equivalence/difference、跨 checkpoint/transfer prior-chain、unknown-identity freeze、provider-verified `task.retry.override` exact scope/replay guard 与 active-policy-pinned wall-clock fallback 具有正负向测试。
   > **已取代（2026-08-17）**：本条中「跨 Task transfer」的 prior-chain 语义已移除；Task 内跨 checkpoint prior chain 及其余条款保留，见文末修订记录。
14. repository-wide closure audit 证明不存在绕过 LeadControl/LeadCheckpoint/control registry 的 legacy parallel dispatch、duplicate genesis、task switch、Task double ownership 或 current-worker 路径。
15. agent-independent control 条款已闭合（语义合同引用：ADR-003 决策九、ADR-004 决策七、ADR-006 Amendment 节）——`closure_basis_digest` 冻结与完成标准变化分级、`budget_adjustment_digest`/`effective_verification_plan_digest`/`closure_basis_digest` 单向派生链（checkpoint 自身不进入任何上游派生预像、plan/basis digest 始终被 checkpoint identity/content digest 覆盖且 `budget_adjustment_digest` iff present、plan digest 只消费完整 ordered `effective_budget_bindings`、无 plan truth 对象、override AuthorizationRecord 预先存在）、canonical `measurements.test_count`/`test_code_lines` verified|unverified 表示（观测只属于 binding 当前观测，授权不携带 measurement，adjust/override 只引用 predecessor binding digest）与 typed `unverified_assessment`（disposition/review_status exact mapping、pending/accepted/rejected 准入与 Slice 4 GateEvaluation 依赖——accepted/rejected 必须 exact independent GateEvaluation 且携带 `budget_assessment_result` 绑定被评 binding 所在的前序 accepted checkpoint（`C_pending`，构造顺序单向无自引用；stale 判定用 `budget_review_subject_projection` byte-identical，不得要求完整 binding digest 相等）、user_override mode=consume|inherit）、Finding typed basis 与 policy 派生 blocking、`EvidenceRequirement.verification_class`（三类互斥）与 `implementation_check.evidence_requirement_results[].verification_use` 结构化配对（含 `ArtifactClaim.kind` 兼容校验）、ProjectPolicy delegation envelope 与 `test.budget.adjust` typed payload/`test.budget.override`（`budget_scope_type` 两层分别校验）、WorkUnit-lineage 与 task-lineage 两层累计预算记账、bounded runner 互斥停止状态（completed/blocked/frozen/needs_user；超 ceiling/第三次同 fingerprint 无 override 唯一进入 needs_user）、continuation envelope、recovery trigger/provenance/idempotency 与禁补造，均有 writer/validator 与正负向测试。
16. legacy rejection 扩展：客户端提示（AGENTS.md）在任何路径下都不得成为产品 authority 或 gate 依据；`verification_class` 只做结构化 class/use 配对与 claim kind 兼容校验（validator 不判断自由文本的动态数据/稳定 signal，分类由 Lead/reviewer 留 provenance）；`release_audit`/`acceptance_evidence` 证据不得固化为永久测试或回归证据；缺失权威正文/证据时 recovery 不得补造。
17. 并行边界保持原决议：不同 project 独立并行；同一 project 内 strict serial 与 task-set/runtime-subject-set disjoint 并行规则不变，agent-independent control 条款不改变该边界。
   > **已取代（2026-08-17）**：本条的并行边界已修订——同一 project 内并行改由不同 Task 各自 Git branch/worktree 提供；同一 Task 内 strict serial 不变，见文末修订记录。

> provenance only：上述 agent-independent control 条款的设计来源为 [orbit-v2-agent-independent-control-amendments](../history/agent-independent-control-amendments.md)（owner approved 2026-08-11，Integrated / historical design source）；仅供追溯，不作为本 cutover 条件来源。

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
- 允许同一 control lineage 的并行 active Attempt、同一 Task 被多 lineage 持有、同一 runtime subject 以 AgentInstance 别名跨 lineage 同时 active，或保留绕过 LeadCheckpoint/control registry 的 legacy dispatch path；
- > **已取代（2026-08-17）**：本条以同项目多 control lineage 为参照的部分已按 task-centric 模型取代；「同一 Task 只允许一条 accepted control lineage」与 Task 内禁止并行 active Attempt 仍保留，见文末修订记录。
- 以“deprecated”名义继续让旧路径写权威状态；
- 为减少一次性改动而让新旧事实源长期并存。

## 后果

- Orbit v2 可以围绕单一目标模型设计，不承担旧协议形状带来的永久复杂度。
- v1 task、evidence、state 和 handoff 不能直接用于 v2 gate closure。
- 使用者需要显式重新初始化仍要继续的工作。
- 使用者必须在 clean v2 protocol root 中运行；v1 archive 不得留在 active root。
- cutover 的单次改动面和验收面较大，必须用完整 E2E、closure audit 和删除检查控制风险。
- 当前 v1 runtime 不因本 ADR 自动变化；只有实现、模板、测试和 runtime 文档完成原子切换后，v2 才成为生效协议。

---

## 修订记录（2026-08-17）：cutover 前置条件按 task-centric 并行边界修订

**这是产品范围修订，不是本 ADR 原目标的全部达成。** 缩减后的 cutover 条件不得被描述为原 ADR 完整交付。

### 被取代的条款

以下原文保留在上文，但自 2026-08-17 起不再作为 v2 cutover 前置或实现权威：

1. 背景段中「不同 control lineage 只有 Task ownership sets 与 provider-verified active runtime subject sets 都不相交时才可并行」的并行边界；
2. 决策条款 11 中 cross-lineage Task ownership/transfer、provider-verified runtime-subject active-session uniqueness/transfer、project-wide Task/WorkUnit Attempt backstop 等 project-wide 多 control 闭合条件；
3. 权威对象表中 `lead_control_id` / control registry 行的「project-scoped」定性、跨 lineage Task ownership/transfer、canonical runtime-subject active-session binding 和 global Attempt backstop 职责；
4. WorkUnitAttempt 段中 per-Task/per-WorkUnit backstop 的 project-wide 定性；
5. controlled writer 段中跨全部 open lineages 的原子 Task ownership 校验与 Task/executor transfer 协议；
6. 旧路径关闭清单中以「同项目多 control lineage」为前提的条目（多 queue 归属、transfer provenance、重叠 task sets 并行、跨 lineage runtime-subject 双绑定）；
7. fingerprint 段中跨 Task transfer 的 prior-chain 语义；
8. 实施和发布约束条款 11-13 中 cross-lineage ownership/transfer、disjoint parallelism、project-wide uniqueness 相关闭合条件；
9. 实施和发布约束条款 17「同一 project 内 strict serial 与 task-set/runtime-subject-set disjoint 并行规则」；
10. 「不采用的方案」清单中以同项目多 control lineage 为参照的条目。

### 取代后的新语义（冻结）

```text
.orbit/
├── protocol.yaml          # project-level，低频全局事实
├── policy/                # project-level authority lineage
└── task-scopes/
    └── <task_id>/         # task-definitions.json control-transactions.json evidence-transactions.json gate-facts.json
```

1. `task_id` 是协作、存储和冲突隔离的单位。
2. 一个 Task 通常对应一个 Git branch/worktree。
3. 一个 Task 只允许一条 accepted control lineage。
4. 不同 Task 路径不重叠，天然并行。
5. 项目级 task/status/index 是派生视图，不是共享可写权威。
6. 同一 Task 的并行修改是真实冲突，由 Git merge 和 Task lineage 校验发现。
7. Lead/agent 更换走 Task 内 session replacement 或 handoff。
8. 不存在 cross-control Task transfer。
9. 不存在 project-wide Task ownership registry。
10. 不存在同项目多 control 之间的 runtime-subject/session transfer。

cutover 前置相应修订：原条款 11/12/17 中的 cross-control 闭合条件从 cutover 前置中移除；替换为——每个 Task 一条 accepted control lineage、Task 内串行与单 active 约束、Task-local non-terminal Attempt backstop、checkpoint-before-dispatch 在 Task 内闭合。条款 17 改为：不同 project 独立并行；同一 project 内不同 Task 通过 Git branch/worktree 隔离并行；同一 Task 内 strict serial。control identity 的 scope 从 project 收窄为 Task。

本 ADR 其余核心内容不受影响：clean cut、no dual-write、no fallback、epoch preflight、create-only 权威对象、evidence/gate authority 分离、Task 内 atomic create 与 single-active 约束、Task 内跨 checkpoint fingerprint prior chain。

### 项目级例外（有意接受）

`protocol.yaml` 与 `policy/` 保留在项目级，因此保留 Git 合并冲突风险。这是有意接受的：policy rotation 低频，且两个分支同时轮换 policy 本来就是真实冲突，应该冲突。

### 修订原因

用户已否定「同项目多个长期 Lead control 并行 + Task 在 control 之间转移」这一前提：真实协作边界是「一个 Task = 一个 task_id = 一个 Git branch/worktree」。项目级多 control 调度、cross-control transfer 与 project-wide ownership registry 不是 Orbit MVP 必要能力。背景与完整路线见 `docs/history/slice6-handoff.md`；ADR-003/ADR-006 同日修订与本文一致。

---

## 修订记录（2026-08-17，阶段 F）：v1 代码已删除——这不是 cutover 完成

**事实**：本仓库已删除 v1 production 代码（`lib/orbit/*.rb` 36 文件）、`tests/orbit_test.sh`（v1 测试面）与 `contracts/orbit-v2/legacy-v1-writer-reader-inventory.yaml`（v1 迁移清单）；`scripts/orbit` 入口直接进入 v2 CLI（历史 `orbit v2 <cmd>` 命名空间与裸 `<cmd>` 等价）。决策依据（无用户、v2 对 v1 零依赖、v1 停用 17 天、本 ADR 本就以删除为终点）见 `docs/history/slice6-workorder.md` 第 6 节；删除是可逆的（git 历史）。

**纪律声明：v1 代码删除 ≠ cutover 完成。** 「v2 必须关闭的旧路径」清单的删除字段要求与「实施和发布约束」17 条编号条件中，本增量只满足一部分。**仍未满足的（至少）**：

- 第 7 条：`skills/orbit/references/runtime/`、templates、help 与 examples 尚未与 v2 原子更新——v1 命令教学仍在（阶段 F Gate 6b 处理停用标注；完整 v2 文档重写未完成）。
- 第 6 条：v1 fallback 与兼容测试已删除，但「替换为 unsupported-schema 负向测试」的完整负向面尚未按 cutover 规模重建（现有 v2 合同测试含部分负向，未宣称覆盖本条全量）。
- 第 10 条：GateRequirement subject selector、GateEvaluation canonical subject/freshness/producer independence 的正负向测试面未做 cutover 级审计确认。
- 第 5 条：完整 E2E 已有一条真实 CLI 路径（阶段 D），但 handoff/recovery/clean-install dogfood 未跑。
- 第 8/14 条：repository-wide closure audit 未执行（v1 代码删除本身不是 closure proof——本 ADR 明文「删除字段名称本身不是 closure proof」）。
- 第 11/13 条及「Cutover 行为」节的 dogfood 验收未发生；`tests/orbit_test.sh` 的全仓绿色标记随 v1 删除一并移除，v2 收口以 `contract_test.rb` 为准。

**其他有意保留**：`reject_mixed_epoch!` 与 `KNOWN_V1_AUTHORITY_PATHS` 保留（防 v2 在残留 v1 数据上初始化，其他项目仍可能有）；`task-scopes` 存储段名不改（删除与布局变更不在同一增量）；本仓库 `.orbit/` 的 130 个 v1 数据文件移除是独立的不可逆步骤（阶段 F Gate 6c，先备份）。

**命令面未决项（2026-08-17 审核方裁定记录）**：v1 删除后入口实现了双拼法——
`orbit v2 <cmd>` 命名空间与裸 `orbit <cmd>` 等价（`lib/orbit/v2/cli.rb` 对
`v2` 前缀做可选剥离）。这是一次**加法**（新增裸命令面），不是工单原定的
「只做减法」；改动本身被接受，但**最终命令面（保留前缀 / 彻底去前缀 / 长期
并存）是尚未做出的决定**，不得因「现在都能跑」而固化为默认。本条为待决欠账，
决策前双拼法维持现状。

在上述条件逐条满足前，不得宣称 cutover 完成、v2 激活或 clean-install ready。

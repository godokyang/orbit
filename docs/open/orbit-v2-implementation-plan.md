# Orbit v2 Implementation Plan

- 状态：Open
- 日期：2026-07-30
- 父架构：[ADR-003](../adr/003-lead-orchestrated-dynamic-agent-team.md)
- EvidenceRecord 子协议：[ADR-004](../adr/004-role-rule-context-evidence-binding.md)
- Cutover 决策：[ADR-005](../adr/005-orbit-v2-clean-cut-and-legacy-retirement.md)
- 串行控制合同：[ADR-006](../adr/006-serialized-lead-orchestration-control-loop.md)
- 当前 runtime：v1；本计划尚未生效

## 目标

一次性建立并切换到以下闭环：

```text
ProtocolRoot(orbit-v2)
  -> ProjectPolicyRevision genesis / active lineage
  -> trusted provider resolves canonical Lead runtime subject
  -> atomic lead_control_id claim + one active LeadSession/subject binding + accepted genesis checkpoint
  -> ordered TaskRevision queue / one active Task
  -> WorkUnit parent/dependency graph / one selected WorkUnit
  -> LeadCheckpoint selection
  -> ChangeThesis revision/digest
  -> one non-terminal WorkUnitAttempt / AgentInstance / LeadSession
  -> assigned RuleResolutionArtifact
  -> EvidenceRecord
  -> submitted RuleResolutionArtifact
  -> GateRequirement subject selector
  -> evaluator Attempt / EvidenceRecord
  -> subject-pinned GateEvaluation
  -> Finding / FindingResolution
  -> derived AggregateOutcome
  -> terminal Attempt / next LeadCheckpoint / next dispatch
```

完成后，Orbit 只有一套 control/task/work-unit/team/evidence/gate 权威语义，不保留 v1 compatibility、双写或 fallback。

## 非目标

- 不把 v1 artifact 自动迁移成 v2。
- 不在 v1 正式 API 中零散增加 v2 字段。
- 不引入图数据库或允许 agent 任意写关系。
- 不把 context delivery、文件读取或 hash 存在解释成模型理解证明。
- 不用固定 token、轮数或 diff 行数替代上下文与 review 判断。
- 初版不支持 Task-internal parallelism，不建设 broad Portfolio platform 或通用 scheduler 产品。
- 不用更多 Evidence/Validator 字段替代 LeadControl、LeadCheckpoint、single-active 和 progress/stop-loss 合同。

### 实施顺序冻结

ADR-006 control contract、Slice 1 exact refs/single-active validator 和 Slice 2 `lead_control_id`/registry/LeadCheckpoint/LeadControl design 未冻结前，不继续扩大 Evidence/Validator substrate，也不进入 runtime 实现。当前状态（Slice 1 于 76badb3 contract-only 落地）：WorkUnit exact parent/dependency refs、Attempt exact `lead_control_id`/terminal predecessor/`dispatch_lead_checkpoint_ref`（格式/链内一致性）与 strict single-active 已实现；Slice 2 的 control registry、LeadCheckpoint、LeadControl 尚未实现，不得把它们描述为既有能力。

### Slice 2 增量化交付（docs-only plan amendment，2026-08-11）

状态：本 amendment 仅改变 Slice 2 的**交付顺序与验收归属**，不修改任何 ADR 语义合同（ADR-003 决策九、ADR-004 决策七、ADR-005 实施约束 15-17、ADR-006 含 Amendment 节逐条保持有效）。Owner 已批准推进至 Slice 2 完成；本 amendment 经审核生效前不实施代码。

#### 增量序列与依赖顺序

| 增量 | 范围 | 依赖 |
| --- | --- | --- |
| 1 控制身份锚 | registry claim + model-level accepted genesis final-state closure + LeadSession required pins + 单 lineage checkpoint 血缘/pins/writer provenance/初始 task ownership/queue | 仅 Slice 0/1 事实 |
| 2 最小可恢复闭环 | store-backed dispatch（existence/tip/selection）；active selection/current attempt/四层 assessment/progress 字段；最小 typed `lead_decision`/`next_trigger`（与 `reconcile`/event trigger 同增量落地）；recovery（唯一 tip 重建、连续性 fail-closed、三态互斥归位、禁补造、幂等）；`reconcile` 核心 + 基础止损；同 lineage session 替换；event trigger 全量 | 增量 1 |
| 3 跨 lineage 与 transfer | task ownership disjoint、subject 跨 lineage active 唯一（含别名）、Task release/acquire、executor 跨 lineage transfer；移除 `unsupported_multi_lineage` 临时拒绝 | 增量 1-2 |
| 4 anomaly/fuse/预算机制（完成 Slice 2） | fingerprint（含 Finding 分支，复用现有 stable Finding identity；typed blocking 分类属 Slice 4，不阻塞 fingerprint）、prior chain、`task.retry.override`、policy-pinned fallback + `checkpoint_due`、delegation envelope、budget 派生链、两层累计/measurements（`unverified_assessment` pending 为默认 forward 状态，未 review 时 adjust/closure fail closed）、bounded runner、`closure_basis_digest` 冻结与重算 | 增量 1-3 |

**Slice 2 = 增量 1 → 2 → 3 → 4，完成于增量 4**（不要求 Slice 3/4 先行）。其后：Slice 3 → Slice 4（含「control consumer closure」小节，消费增量 4 字段与 `budget_assessment_result`）→ Slice 5 → Slice 6。Slice 3 不消费 control 增量；`unverified_assessment` 独立评审准入条款（原拆分草案，后文统一称「control consumer closure」）归入 Slice 4，不构成 Slice 2 完成前置；不存在任何要求 Slice 3/4 先行的倒置依赖。

#### Pre-activation 合同演进（intermediate shapes 非 adopted runtime contract）

- 增量 1-4 对 registry/LeadCheckpoint schema 的演进属 **pre-activation 合同演进中间形态**，不是 adopted runtime contract；最终激活（Slice 6）只接受**最终 exact schema 版本**。
- **无 backfill、无双读、无旧版本有效路径、无兼容层**；中间形态字段变化以最终 schema 为准。
- **字段与消费者同增量落地**；增量 1 不落地 active selection/current attempt（消费者在增量 2 dispatch/recovery），不以"形状校验"冒充消费者。
- **LeadSession required pins**：自增量 1 起所有 LeadSession 必须 required pin `lead_control_id` + canonical `lead_runtime_subject_ref` + `lead_runtime_subject_assertion_digest`，不做 nullable/未绑定 session 兼容；v2 尚未激活，更新既有 fixture 属正常 clean cut（不属兼容路径）。

#### 原子性证明边界

- 本阶段（contract-only，Slice 6 前）只宣称：**无效 bundle 不 accepted；accepted 最终状态的 invariant 闭合**（create-only 幂等、lineage 线性、exact refs）。不设计假事务，不测试"输入 bundle 无半状态"。
- 真实 **compare-and-append 原子执行、崩溃回滚、并发竞争**由受控 store/runtime 在 Slice 6 activation 关闭；本阶段不得宣称已闭合。

#### Fingerprint 未落地时的止损规则

- fingerprint 尚不可证明时（增量 4 前），凡依赖 fingerprint 判定的决策一律 **frozen/escalate**（ADR-006：identity 不可证明即 freeze）。
- **禁止**以 predecessor chain 计数冒充"相同 fingerprint"进入 `needs_user`；`needs_user` 仅在 fingerprint **已证明相同**且第三次 Attempt 缺 `task.retry.override` 时出现（增量 4 起）。

#### 测试预算规则（每增量）

- 每增量**最多 9 个手工语义场景**（一行为一场景，只选真实高风险语义）+ **既有自动 schema parity** 覆盖结构性 missing/type/null/unknown 与禁字段（如 checkpoint 复制 task/evidence/gate truth 由 additionalProperties/schema parity 自动覆盖，不另写用例）。
- `tests/**` 每增量新增 **≤300 行**；超出必须先说明。
- 增量 1 的 9 个场景冻结于 Slice 2 段增量 1 小节。

### Agent-independent control amendments（owner approved 2026-08-11）

设计来源：[orbit-v2-agent-independent-control-amendments](./orbit-v2-agent-independent-control-amendments.md)（Integrated / historical design source；runtime 未实现）。**规范以 ADR-003（决策九）、ADR-004（决策七）、ADR-005（实施约束 15-17）、ADR-006（Amendment 节）为语义合同**；本 plan 各 slice 段只列交付物/验收并引用 ADR，历史设计稿仅作 provenance，实现者无需穿越。交付物、完成条件与负向/E2E 验收已分别落地到本 plan 的 Slice 2/3/4/5/6 段（各段"Agent-independent amendment 增量"小节）：

- **pre-Slice docs freeze**：实现不得偏离上述 ADR 条款，也不得把 amendment 条款回填为"Slice 0 schema 已具备"。
- **Slice 1（保持原设计，不变）**：WorkUnit exact parent/dependency refs、唯一 root、parent tree 可达、dependency DAG/readiness；WorkUnitAttempt exact `lead_control_id`、terminal predecessor、dispatch LeadCheckpoint ref；single-active。**不加无消费者 placeholder**：`dispatch_lead_checkpoint_ref` 只做格式/链内一致性校验，store-backed 存在性/tip/selection 校验随 Slice 2；不建 LeadCheckpoint schema/collection。Slice 1 proposal 的 schema 版本、error code、测试计划不受本 amendment 影响。
- **Slice 2**：delegation envelope、`closure_basis_digest`、`budget_adjustment_digest`/`effective_verification_plan_digest` 派生链、两层 test budget、bounded runner、continuation envelope、recovery —— 详见 Slice 2 增量 4 段（依赖顺序见「Slice 2 增量化交付」节）。
- **Slice 3**：`verification_class` 与 `verification_use` 结构化配对 —— 详见 Slice 3 段。
- **Slice 4**：Finding typed basis 与 blocking 派生、`unverified_assessment` 独立评审准入（control consumer closure）—— 详见 Slice 4 段；`budget_assessment_result` 消费 Slice 2 增量 4 的 checkpoint binding/派生字段（依赖顺序见 Slice 4 段注）。
- **Slice 5**：只投影（digest 视图、budget 两层 projection）—— 详见 Slice 5 段。
- **Slice 6**：E2E/cutover 覆盖 amendment 条款 —— 详见 Slice 6 段。

## 权威边界

| 事实 | Writer / Owner | 消费者 |
| --- | --- | --- |
| project identity、active protocol epoch、immutable policy genesis ref；marker parent 定义 active root | `ProtocolRoot` | 所有 project-scoped commands |
| protected gate minimum、waiver/risk-owner/adjudicator/update authority、bootstrap/rotation provenance | create-only `ProjectPolicyRevision` lineage | TaskRevision、Gate Engine、policy validator |
| `goal`、全局 requirement/question IDs、GateRequirements、exact policy revision ref | `TaskRevision` | Lead、WorkUnit、Gate Engine |
| 稳定局部目标、授权范围、requirement refs、stop conditions、exact parent/dependency refs、唯一 root reachability、immutable initial thesis ref | `WorkUnit` | Lead、Attempt creator、projection |
| 可证伪方案主张 | create-only `ChangeThesis` revision/digest | WorkUnitAttempt、EvidenceRecord、GateEvaluation |
| assignment、exact predecessor/dispatch checkpoint refs、agent、context generation、authority snapshot；start/end/status events | append-only `WorkUnitAttempt` | Agent、Lead、`EvidenceRecord`、roster projector |
| local runtime instance/lifecycle 与 provider-verified canonical `lead_runtime_subject_ref + assertion_digest`；每个 control 最多一个 active session、每个 project/runtime subject 最多一个 active binding | `AgentInstance` / LeadSession lifecycle + trusted runtime identity provider | control registry、Attempt、dispatch、audit |
| stable `lead_control_id`、唯一 genesis、受控 writer authority、跨 lineage Task ownership/transfer、canonical runtime-subject active-session binding、per-Task/per-WorkUnit Attempt backstop | project-scoped create-only control registry | LeadControl、checkpoint/session/Attempt writer、recovery、audit |
| ordered task queue、唯一 selection、四层 assessment、Delivery/Assurance delta、`fingerprint_identity_basis`/hash、separate `fingerprint_supporting_provenance`/prior chain、LeadDecision、next trigger | create-only append-only linear accepted `LeadCheckpoint` lineage，pin exact `lead_control_id`/active session/runtime subject | LeadControl、dispatch、recovery、audit |
| retry override 与 fallback policy authorization | active ProjectPolicyRevision orchestration policy 或其授权、provider-verified、create-only immutable `AuthorizationRecord` | LeadControl、checkpoint/Attempt writer、validator、audit |
| assigned/submitted required rules | content-addressed `RuleResolutionArtifact` | Attempt、EvidenceRecord、validator、gate |
| artifact、observation/requirement result 与 submission provenance | create-only `EvidenceRecord`，通过 `attempt_id` 归因 | GateEvaluation、FindingResolution、audit |
| gate contract 与 subject selector/freshness policy | `GateRequirement`（由 TaskRevision 拥有） | evaluator、Gate Engine |
| evaluator verdict/answers、evaluator provenance、canonical subject manifest/digest | create-only subject-pinned `GateEvaluation` | Gate Engine、Lead、adjudicator |
| finding body/identity | create-only `Finding`，由 GateEvaluation 引用 | Gate Engine、Lead、FindingResolution |
| finding closure 与 issuer provenance | append-only authorized `FindingResolution` | Gate Engine、wait-gate、audit、handoff |
| active roster、active thesis view、CodeSurface、typed relationships | deterministic projector | context projection、audit |
| AggregateOutcome | Gate Engine deterministic projector | state、audit、handoff |

Initial TaskRevision 必须由 ProtocolRoot 锚定、user-controlled bootstrap 创建的 ProjectPolicyRevision genesis 授权；candidate/Lead 名称不是信任根。Active policy 是受控 create-only store 中从 genesis 出发的唯一有效 lineage tip，不另设可覆盖 pointer；successor 只能由该 tip authority 以原子 compare-and-append 线性轮换，缺失、伪 ref/digest、多个有效 tip 或 fork fail closed。

Gate Engine 只消费与 GateRequirement current canonical subject digest 完全匹配、refs immutable/accepted/not stale，且 evaluator 对全部 subject producer agents 独立的 GateEvaluation。`addressed/disproved` resolution 必须绑定 authorized issuer attempt/submission/rule context/supporting refs；`waived` 必须绑定 active policy/TaskRevision authorization record。EvidenceRecord/GateEvaluation/Finding create-only，FindingResolution append-only。Lead 不能 revision-hop、自授 authority，或直接写 AggregateOutcome。

LeadControl 只消费上述 authoritative facts，并通过 `reconcile(authoritative_facts, trigger) -> LeadDecision` 产生 coordinator decision；受控 writer 将 decision 写入 exact `lead_control_id` 的唯一 accepted LeadCheckpoint lineage，并与 project control registry 原子复核 Task ownership。scheduler/anomaly/self-check/task-queue projection 是其内部 seam，不拥有 goal/evidence/GateEvaluation/Finding closure/AggregateOutcome。Work Agent 不得创建/dispatch child work 或修改 queue/priority/selection。

## Slice 0：冻结 v2 合同

本 Slice 记录此前已冻结的 task/evidence/gate/cutover 合同。ADR-006 新增的 WorkUnit/Attempt exact refs、strict single-active validator 与 LeadCheckpoint/LeadControl 不回填为“Slice 0 schema 已具备”；它们分别在 Slice 1/2 交付。

交付物：

- `orbit-project-policy-v1`、`orbit-task-v2`、`orbit-work-unit-v1`、`orbit-agent-runtime-v1`、`orbit-evidence-v2` 和 gate/finding schema；
- `.orbit/protocol.yaml` 的 `orbit-protocol-root-v1`、`protocol_epoch: orbit-v2`、immutable policy genesis ref 与 marker-parent root identity；
- Authority Matrix；
- 统一 vocabulary：`TaskRevision.goal`、`GateRequirement`/`GateEvaluation`、`Finding`/`FindingResolution`、`EvidenceRecord`；
- 单一 verdict/finding authority：GateEvaluation 唯一拥有 evaluator verdict/answers，Finding 唯一拥有 finding body，EvidenceRecord 只保存 submission provenance；
- EvidenceRecord/GateEvaluation/Finding create-only lifecycle、supersedes/related lineage 与 append-only FindingResolution issuer provenance；
- GateRequirement subject selector/freshness policy 与 GateEvaluation evaluator-provenance/canonical-subject 分离合同；
- ProjectPolicyRevision stable ID/parent/content digest、trusted user/control-plane `authorization_source_ref + assertion_digest`、非自授权 genesis、线性 rotation 与 fail-closed policy resolution；
- protected gate lineage、parent-authority approval 和跨 revision unresolved Finding 合同；
- stable policy/task/revision/work-unit/attempt/agent/evidence/gate-evaluation/finding/resolution/change-thesis IDs 与 content digests；
- acceptance/source/evidence requirement 和 task question 的稳定 ID 模型；
- `ChangeThesis` canonical revision/digest；
- `CodeSurface`/`RelationshipView`/`AggregateOutcome` 的纯派生合同；
- schema version dispatch 和 `unsupported_schema_version` 错误；
- protocol root/epoch preflight、`protocol_epoch_mismatch` 和 mixed-epoch detection；
- repository-wide legacy writer/reader inventory。

完成条件：

- 每个事实有且只有一个权威 owner；
- 每个 project-scoped command 在其他读写前经过 protocol root/epoch preflight；
- 没有“字段缺失时读取 v1”的设计；
- WorkUnit 不复制 task-level contract；
- WorkUnitAttempt 保存 assignment/history，WorkUnit 不保存可覆盖 agent/status；
- candidate TaskRevision 不能用自己新声明的 authority 批准 protected gate change；
- initial TaskRevision 不能自报 bootstrap authority；ProtocolRoot policy genesis ref 缺失/伪造或 policy lineage fork 时不能启动；
- subject-less/stale evaluation 和可变 evidence/evaluation/finding 不是合法设计；
- gate arbitration 不使用纯 latest-wins。

## Slice 1：TaskRevision、WorkUnit、ChangeThesis 与 WorkUnitAttempt

交付物：

- TaskRevision 的 goal、stable requirement/question IDs、GateRequirements 和 exact `project_policy_revision_ref`；
- root/child WorkUnit create、return、block、close；
- exact `parent_work_unit_ref`、`depends_on_work_unit_refs`；每个需要 work 的 TaskRevision 恰好一个 root，其他 WorkUnit 沿 parent tree 从 root 可达；parent/dependency/task revision/authority scope、multiple-root/orphan/cycle/readiness 校验；
- WorkUnit 只保存 `acceptance_refs`、`evidence_requirement_refs`、`source_requirement_refs` 和 immutable `initial_change_thesis_ref`；
- create-only ChangeThesis revisions 与 canonical digest；
- append-only WorkUnitAttempt：预分配 ID、exact `lead_control_id`、exact `predecessor_work_unit_attempt_ref`、exact `dispatch_lead_checkpoint_ref`、create/reuse assigned artifact、单次 `AttemptCreated` immutable Assignment snapshot、agent instance、context generation、authority snapshot、thesis ref、start/end/status events；
- strict single-active validator：每个 `lead_control_id` 最多一个 active Task、一个 selected WorkUnit、一个 non-terminal WorkUnitAttempt，覆盖 implementation/review/test/research/release；另以 project-wide authoritative Attempt index/backstop 强制每个 Task、每个 WorkUnit 最多一个 non-terminal Attempt；
- TaskRevision protected change diff/digest、parent revision、authority-source revision、issuer/policy/issued-at provenance 和 unresolved Finding inheritance validator；
- 所有正式 EvidenceRecord 强制要求 `attempt_id`，且 create-only/immutable；
- 删除运行时 `child_slices`、`parent_goal` 和隐式派单读取路径。

完成条件：

- work agent 不能修改 `TaskRevision.goal`；
- scope escalation 只能由 Logical Lead 产生新 revision 或新 WorkUnit；
- agent replacement/retry/context rebuild 产生 successor attempt，不覆盖 WorkUnit 或旧 attempt；
- mainline/branch/critical path/runnable set 只从 parent/dependency 与权威 lifecycle/gate facts 派生，不固化阶段标签；
- multiple root、orphan、parent/dependency cycle 或 cross-revision edge fail closed；
- thesis revision 变化产生 pin 新 digest 的 successor attempt，WorkUnit 不存在可覆盖 current thesis pointer；
- successor 的 predecessor 必须 terminal，dispatch checkpoint 必须是当前唯一 tip且 exact selection 匹配；存在其他 non-terminal Attempt 时创建/dispatch fail closed；
- `AttemptCreated` 前不得 dispatch，创建后不得 patch assigned resolution；started_at/initial status 只来自 creation event；
- 没有 WorkUnitAttempt 的 EvidenceRecord 无法写入；
- task-level acceptance 通过稳定 ID 被引用，不被复制；
- EvidenceRecord 的 thesis ref 必须等于 Attempt 的 `change_thesis_id + revision + digest`；
- child revision 未经 inherited authority 批准不能删除/降级 protected gate、放宽 waiver policy、重设 risk owner/adjudicator 或清除 Finding。
- initial TaskRevision 的 protected contract 不弱于 active ProjectPolicyRevision minimum，waiver/risk-owner/adjudicator 只能引用/收窄 policy grants 或 policy-authorized immutable record；policy rotation 不改写旧 provenance，但旧 TaskRevision closure stale，继续执行必须新 revision rebind active policy。

## Slice 2：Dynamic Team、Logical Lead Continuity 与 Lead Control

### 增量结构

按「Slice 2 增量化交付」节，本 slice 拆为增量 1→4。下方「原 Slice 2 规范条目」保留全部原交付物/完成条件/负向验收文本作为规范正文，归属映射如下（增量 1 立即实施，其余按依赖顺序）：

- **增量 1（控制身份锚）**：live roster 与静态配置分离复核；provider 先解析 canonical runtime subject + model-level accepted genesis final-state closure（真实事务原子性证明边界见增量化交付节，Slice 6 闭合）；provider-verified subject resolution；每 `lead_control_id` 最多一个 active LeadSession；checkpoint 身份/血缘/pins/writer provenance/单一 Task 绑定字段（2026-08-17 task-centric 修订：control 不持有 Task 集合，无初始 task ownership/queue，见 ADR-006 修订记录）；duplicate genesis、自报 writer、缺 provider subject/session binding、非原子 create 均不 accepted；checkpoint 不复制 task/evidence/gate truth（schema 禁字段）。
- **增量 2（最小可恢复闭环）**：AgentInstance/LeadSession 替换语义；roster/assignment/replacement history 派生复核；coordinator-level ordered task queue projection；`LeadControl.reconcile` 深模块核心；最小 typed `lead_decision`/`next_trigger`（与 `reconcile`/event trigger 同增量落地）；event triggers；四层自检 seam；Delivery/Assurance 分离、assurance-only freeze、non-preempting hardening；首轮/两轮零 Delivery delta fuse 与立即 freeze（基础规则）；durable lead context/handoff/recovery 与 fork fail-closed；session 连续性 fail-closed；Work Agent single-writer；Task switch 边界；recovery 三态互斥归位/幂等/禁补造。
- **增量 3（跨 lineage 与 transfer）**：跨 lineage Task ownership 与 runtime-subject active binding 原子复核（别名同 executor）；release/suspend → acquire、terminal/release → successor/bind exact transfer provenance；双 active/双 queue/双 tip/重叠并行 fail-closed；移除 `unsupported_multi_lineage` 临时拒绝。
- **增量 4（anomaly/fuse/预算机制，完成 Slice 2，Slice 3 前）**：wall-clock fallback（policy-pinned，只产生 `checkpoint_due`）；fingerprint identity basis/supporting provenance/prior chain（含 Finding 分支——复用现有 stable Finding identity；typed blocking 分类属 Slice 4，不阻塞 fingerprint）；`task.retry.override`；round fuse 完整化；delegation envelope；`closure_basis_digest` 冻结与派生链（`budget_adjustment_digest`→`effective_budget_bindings`→`effective_verification_plan_digest`→`closure_basis_digest`）；两层 budget 累计/measurements（`unverified_assessment` pending 为默认 forward 状态，未 review 时 adjust/closure fail closed）；bounded runner 与 continuation envelope。`unverified_assessment` 独立评审准入（review_status=accepted/rejected 消费 `budget_assessment_result`）归入 Slice 4「control consumer closure」，不构成 Slice 2 完成前置。
- **Slice 0/1 已闭（本 slice 复核，不新增）**：静态配置非 live team；roster 从 attempts 重建；project-wide Attempt backstop；review/test 与 implementation 串行。

### 增量 1：控制身份锚（立即实施）

字段范围（只落地消费者在场的字段）：

- LeadSession：required `lead_control_id` + canonical `lead_runtime_subject_ref` + `lead_runtime_subject_assertion_digest`（provider-verified）；不做 nullable/未绑定 session 兼容；既有 fixture 更新属 clean cut。
- LeadControlRegistry：claim、`genesis_checkpoint_ref+digest`、writer authority provenance（active policy `control.genesis`/`control.checkpoint` grant 或 policy 授权 immutable record）、初始 task ownership/queue。
- **queue 单一事实源**：registry `owned_task_refs` 是 project-scoped Task ownership 权威；checkpoint 初始 task ownership/queue 必须 exact match registry claim，后续 queue 仅为该权威下的可恢复 projection（随 release/acquire transfer provenance 演化，增量 3）；registry 与 checkpoint 不得各自拥有 queue truth。
- LeadCheckpoint（genesis/lineage 形态）：身份/血缘（`is_genesis`、`predecessor_lead_checkpoint_ref`、`content_digest`）、policy/session/subject pins、writer provenance、初始 task ownership/queue。`lead_decision`/`next_trigger` 不落地（消费者在增量 2 `reconcile`/event trigger）。
- **不落地**：active selection/current attempt、四层 assessment、progress、`lead_decision`/`next_trigger`、fingerprint、budget、`checkpoint_due` —— 消费者分别在增量 2/4，随消费方落地（不以"形状校验"冒充消费者）。

手工语义场景（最多 9 个，一行为一场景；结构性 missing/type/null/unknown 与禁字段由既有 schema parity 自动覆盖，不重复计）：

1. valid genesis + linear successor —— 接受（happy path）；
2. duplicate genesis（同 `lead_control_id` 第二次 genesis）—— 拒绝（`control_genesis_duplicate`）；
3. provider assertion invalid（subject assertion 无法验证；required 字段缺失交 schema parity）—— 拒绝；
4. writer authority invalid（自报/无 `control.genesis` grant）—— 拒绝（`control_writer_authority_invalid`）；
5. queue ownership 按 task identity 唯一（同 task 不同 revision 的重复 owned ref）—— 拒绝（`control_task_ownership_invalid`）；unresolved exact refs 由既有 exact-ref/schema/invariant 覆盖，不另列手写场景；
6. late Agent context / session chronology（exact generation context 事件晚于 `LeadSessionStarted`）—— 拒绝（`lead_session_invalid`）；cross-control predecessor 由 lineage invariant（same-control exact predecessor + fork/cycle）覆盖，不另列手写场景；
7. lineage fork / multiple tip —— 拒绝（fork 为代表场景；non-tip 由同一 lineage invariant 实现，不另加低价值 case）；
8. checkpoint session/control/subject pin mismatch —— 拒绝（`checkpoint_pin_invalid`）；
9. active policy pin/digest mismatch —— 拒绝（`checkpoint_pin_invalid`）。

完成条件（增量 1）：唯一 genesis；无 session-less/subject-less、伪 writer 或 pin 不一致的 accepted genesis/checkpoint；predecessor/fork/tip 由 lineage invariant 闭合；`tests/**` 新增 ≤300 行；既有 Slice 0/1 测试不回归（fixture 仅补 required pin 字段）。

### 增量 2/3/4：范围与顺序

- 增量 2：store-backed dispatch（existence/tip/selection）、active selection/current attempt/四层 assessment/progress 字段（随 dispatch/recovery 消费者落地）、最小 typed `lead_decision`/`next_trigger`（随 `reconcile` 落地）、recovery、`reconcile` 核心 + 基础止损、同 lineage session 替换、event trigger 全量。fingerprint 未落地前，凡依赖 fingerprint 判定的决策一律 frozen/escalate（ADR-006），禁止以 predecessor 计数冒充相同 fingerprint 进入 `needs_user`。
- 增量 3：跨 lineage 原子复核与 transfer（见归属映射）。
- 增量 4：完成 Slice 2（Slice 3 前落地）；`unverified_assessment` 独立评审准入归入 Slice 4「control consumer closure」（见 Slice 4 段）。

### 原 Slice 2 规范条目（按归属映射交付）

交付物：

- policy/capability profile 与 live roster 分离；
- trusted provider 先解析 canonical runtime subject；受控 writer 在一个原子操作中 claim project-scoped stable `lead_control_id`、bind unique active LeadSession/runtime subject 并创建 project/policy/writer-bound accepted genesis checkpoint；失败不留半状态；
- AgentInstance create/replace/terminate lifecycle；
- LogicalLead 与 LeadSession generation；
- provider-verified canonical `lead_runtime_subject_ref + assertion_digest` resolution；AgentInstance 别名/不同 ID 映射到同一 subject 时按同一 executor 处理；
- 每个 `lead_control_id` 最多一个 active LeadSession，且同一 project 的所有 open lineages 中每个 runtime subject 最多绑定一个 active LeadSession；replacement/executor transfer 使用 terminal/release-old-then-successor/bind-new 或受控 atomic compare-and-successor/transfer，并保存 predecessor/control provenance；
- active roster、current assignment 和 replacement history 从 AgentInstance/WorkUnitAttempt lifecycle 派生；
- coordinator-level ordered task queue projection：同一 AgentInstance 可执行多个 per-task LogicalLead；每个 LogicalLead/Task 最多属于一个 open `lead_control_id` queue，并最多被一个 tip active-selected；
- 跨 lineage Task ownership 与 runtime-subject active binding 的 project-scoped atomic check，及 old release/relinquishing-suspend checkpoint → new acquire checkpoint、old session terminal/release → new successor/bind 的 exact transfer provenance；不同 control lineages 仅在 task sets 与 active executor subjects 都 disjoint 时并行；
- create-only append-only linear LeadCheckpoint：exact `lead_control_id`、predecessor/TaskRevision/WorkUnit/Attempt/session/policy refs、四层 assessment、Delivery/Assurance delta、LeadDecision 与 next trigger；
- `LeadControl.reconcile(authoritative_facts, trigger) -> LeadDecision` 深模块，scheduler/anomaly/self-check/wall-clock fallback/task-queue projection 只作为内部 seam；
- dispatch 前、Attempt terminal 后、successor 前以及 thesis/scope/finding/gate/session/context/authority/dependency change 的 event triggers；
- 从 exact active ProjectPolicyRevision orchestration policy 或其授权的 immutable record 解析有限非零 wall-clock fallback，checkpoint pin exact ID/digest；只产生 `checkpoint_due`，不直接修改状态；
- task queue/active mainline/work graph branches/current attempt 四层自检；
- Delivery Progress 与 Assurance Progress 分离、assurance-only freeze、non-preempting hardening WorkUnit；
- 首轮零 Delivery delta 的实质变化条件、连续两轮零 Delivery delta fuse、第三次相同 failure/finding fingerprint 的 provider-verified `task.retry.override` AuthorizationRecord exact scope/replay guard、立即 freeze 条件；
- LeadControl/受控 writer 从 `fingerprint_identity_basis` 产生 fingerprint：canonicalization version、TaskRevision/WorkUnit scope、typed category/code、stable Finding identity，或 stable test/rule/check identity + stable signal subject identity + normalized failure code；
- separate `fingerprint_supporting_provenance` 保存 terminal Attempt、当前 Finding/GateEvaluation/test/validator outcome refs+digests、authoring checkpoint 与 ordered prior Attempt chain，验证其支持 identity basis 但不进入 hash；跨 checkpoint/Task transfer 连续计数；unknown identity/provenance freeze；
- durable lead context、handoff、checkpoint recovery continuity 和 fork fail-closed；
- lead session 无法证明连续性时 fail closed。

完成条件：

- 静态配置不能被解释为当前 live team；
- duplicate control genesis、self-reported writer authority、provider subject/session binding 缺失、checkpoint 未经 atomic create/compare-and-append 均不 accepted；genesis acceptance、session/subject binding 和 control claim 必须同属一个原子结果，失败不得遗留 claimed ID/active session/checkpoint 半状态；
- roster projection 删除后可从 attempts 重建；
- agent replacement 不改变 WorkUnit、旧 Attempt 或 EvidenceRecord identity；
- LeadCheckpoint 不复制 task/evidence/gate truth，删除 projection 后可从 authoritative facts 与唯一 tip 重建；lineage fork/多个 tip fail closed；
- Lead replacement 后保持同一 `lead_control_id`，且能恢复 ordered task queue、唯一 selection、同一 `TaskRevision`、open `WorkUnit`/`WorkUnitAttempt`、`Finding` 和未满足的 `GateRequirement`；
- 双 active LeadSession、同一 Task 双 queue ownership/双 tip selection、同一 provider/runtime subject 以相同/不同 AgentInstance ID 跨 control active、无 release/acquire 的 Task/executor transfer，以及 task-set/runtime-subject-set 任一重叠的 parallelism fail closed；
- project registry/coordinator writer 在 checkpoint acceptance、session activate/replace 和 dispatch 前跨全部 open lineages 原子复核 canonical runtime subject；只按 AgentInstance 字符串比较不合格；
- 即使 control registry/checkpoint facts 损坏，同一 Task/WorkUnit 的第二个 non-terminal Attempt 仍由 project-wide backstop 拒绝；
- retry override 缺 trusted provider issuer、semantic action/exact scope digest，或跨 fingerprint/task replay 时 fail closed；
- fingerprint identity hash 包含 `lead_control_id`、Attempt/checkpoint/session/AgentInstance 或 Finding/GateEvaluation/test/validator outcome record ID/ref/digest 时 fail closed；agent/free text/message wording、rename/reorder/AgentInstance alias 不得改变 identity；Finding stable identity 必须复用，非 Finding failure 必须有 stable test/rule/check identity + stable signal subject identity，supporting provenance/prior chain 有缺口或 identity 不可证明时 freeze；
- fallback 缺 active policy/authorized immutable record exact ref+digest、读取 mutable config 或 policy rotation 后 stale 时 fail closed；
- Work Agent 不能创建/dispatch child WorkUnitAttempt 或修改 task queue、priority、active Task、selected WorkUnit；
- Task switch 只发生在 active Attempt terminal 且新 checkpoint 接受之后；
- review/test 与 implementation 串行，但 Gate authority 与 evaluator independence 不降低；
- round threshold 只作为 safety fuse；scope/blast radius/review surface/goal relation 失控时不等 round 计数即 freeze。

### Agent-independent amendment 增量（Slice 2）

引用 ADR-004 决策七、ADR-006 Amendment 节；不重复整段规范，只列本 Slice 可验收条款。

交付物：

- ProjectPolicy delegation envelope：policy 定义 budget default/ceiling，Lead 在 envelope 内自治（ceiling 内 `test.budget.adjust`、agent/context 选择、继续/暂停），决策写入 accepted checkpoint，不问用户；
- `closure_basis_digest`：dispatch 时冻结，完成标准变化分级——acceptance/evidence/gate 变化必须 authorized `TaskRevision`/`GateRequirement` revision；thesis/scope/verification-plan 变化只产生 successor basis，不得改写 TaskRevision 完成标准；
- 派生链：`test.budget.adjust` typed payload → `budget_adjustment_digest` → 进入对应 binding 的 `lead_adjustment` source（optional，仅当前 adjustment 存在时；无则明确 absent）→ 完整 ordered `effective_budget_bindings` → `effective_verification_plan_digest` → 纳入 `closure_basis_digest`（adjustment digest 不直接进入 plan digest）；checkpoint 自身不进入任何上游派生预像；**plan/basis digest 始终被 checkpoint identity/content digest 覆盖，`budget_adjustment_digest` iff present 时同为正文字段并受覆盖**；checkpoint 始终 pin plan/basis digest，`budget_adjustment_digest` 仅当前 adjustment 存在时 pin；预像/hash domain 规范见 ADR-004 决策七；checkpoint pin source refs+digests；context projection 重算/下发；capability 匹配（test-write/verification-submit/gate-close）；
- test budget：canonical `effective_budget_bindings`（恰好两项、固定顺序 `work_unit_lineage`/`task_lineage`、各 scope 唯一；语义见 ADR-004 决策七，authority 见 ADR-006 Amendment 节）与 `test.budget.override`（provider-verified AuthorizationRecord 预先存在，consuming checkpoint 只引用）；两层分别校验；
- bounded runner：同一公开命令串行驱动，四互斥停止状态（completed/blocked/frozen/needs_user），每次 reconcile 恰一态、无隐式转换；
- automatic continuation envelope：round 是 safety fuse，Lead ceiling 内自主调整，超限分类互斥（需 user authority → needs_user；可自动 replan 控制异常 → frozen）；
- recovery：trigger/provenance/idempotency、缺资料三态互斥归位、禁补造、不重复副作用、不绕预算/gate。

完成条件：

- Lead 在 ceiling 内 adjust 产生 checkpoint 内 typed payload（`budget_adjustment_digest` 独立 canonicalize 且预像排除 checkpoint 自身）且不触发 needs_user；
- 超 ceiling 无 override、第三次同 fingerprint 无 retry override 唯一进入 needs_user（不进入 frozen）；frozen 仅限 Lead 可自动 replan 的控制异常；
- 同一 Attempt 完成标准不可移动：完成标准变化只能经 authorized revision；successor basis 不改变 TaskRevision 完成标准引用；
- optional adjustment payload → `budget_adjustment_digest` → 对应 binding（仅当前 adjustment 存在时）→ 完整 ordered `effective_budget_bindings` → `effective_verification_plan_digest` → `closure_basis_digest` 单向派生且任一级重算 byte-identical；checkpoint ID/content digest 不进入任何上游派生预像；**plan/basis digest 始终被 checkpoint identity/content digest 覆盖，`budget_adjustment_digest` iff present**；override AuthorizationRecord 预先存在且被消费 checkpoint 引用；不存在可写的 plan truth 对象；
- 两层预算在 retry/换 agent/session/control/对话后连续累计；拆 WorkUnit 不清零；override 缺 provider issuer/scope 不匹配/跨层或跨 scope 重放时 fail closed；
- `effective_budget_bindings` 恰好两项、固定顺序、各 scope 唯一：default-only dispatch 与两 scope 同时有效的 dispatch 均可 byte-identical 重算；old/new 校验只适用于 current adjustment 的 authoring checkpoint（`adjust.old_effective_budget` 等于该 scope 在 authoring checkpoint 时的前一 binding 且 `new` 在 policy ceiling 内），inherited adjustment 验证 origin payload 在 origin 当时与其 predecessor 匹配、当前 effective ceiling 等于 origin 的 `new`、accepted lineage 连续且无 superseding source；无 adjustment 时 `budget_adjustment_digest` 明确 absent；旧有效调整/override 沿 accepted lineage 精确引用，不 latest-wins；
- 每个 binding 的 `measurements.test_count`/`measurements.test_code_lines`（固定键序）各自 `status=verified|unverified`：verified 必须 `usage>=0` + exact provider/snapshot ref+digest；unverified 必须 usage/ref/digest 为 canonical null + typed `unverified_assessment`（固定字段顺序 `lead_disposition`/`lead_reason_code`/`lead_supporting_refs`/`review_status`/`review_gate_evaluation_ref`；disposition 与 review_status exact mapping：pending→`proceed_pending_independent_review`、accepted→`proceed_after_independent_review`、rejected→`replan_after_independent_rejection`，unknown/mismatch fail closed；`lead_supporting_refs` sorted unique exact ref+digest；`review_status=pending|accepted|rejected`，pending 时 review ref canonical null、accepted/rejected 时必须 exact independent GateEvaluation ref+digest 且该 GateEvaluation 携带 `budget_assessment_result` 绑定被评 binding 所在的前序 accepted checkpoint（`assessed_checkpoint_ref+digest=C_pending`、`assessed_effective_budget_binding_digest`；outcome 与 review_status/lead_disposition exact mapping；纳入 canonical subject manifest；GateRequirement selector 明确要求 budget assessment；构造顺序单向——`C_pending` → 独立评审 → successor 消费，不得绑定消费 checkpoint 自身；**stale 判定用 `budget_review_subject_projection` byte-identical（仅三 review-result 字段按 outcome 映射），不得要求完整 binding digest 相等**）且 independence 成立、same-checkpoint circular ref/跨 checkpoint/无关 evaluation fail closed）；**数值预算机械 pass/overrun 只对 verified metric 派生**；default dispatch 可 `unverified_pending_review`（绝不派生 within/over budget），accepted 后仍是 unverified（仅比例性审查通过），rejected → frozen/replan；**授权（adjust/override）不携带 measurement**：只绑定 predecessor checkpoint ref+digest 与该 scope 的 predecessor binding digest 间接冻结观测，writer 对新 checkpoint 的 current measurements 单独派生并以新 ceiling 判定；user override source 用 `mode=consume|inherit`（consume 首次消费并成为 origin_consuming_checkpoint；inherit 绑定 origin + 原 record 沿同 project/policy/TaskRevision/scope/`lead_control_id` 连续 accepted lineage、ceiling 不变且无 superseding source）；lead_adjustment 保持 current/inherited 精确区分；依赖独立 review 的 unverified budget adjust 与 closure 在 Slice 4 GateEvaluation 落地前 fail closed，最终 cutover 时 unverified adjust 与 closure 前必须 `review_status=accepted`；
- recovery 缺资料时按三态互斥归位（blocked/frozen/needs_user），无双状态表述；不补造正文。

负向验收（至少）：

- 缺 `test.budget.override`、scope 不匹配（含 budget_scope_type 不符、WorkUnit override 放宽 task 总预算）或跨层重放的越 ceiling dispatch 被拒；
- `budget_adjustment_digest` 预像含 enclosing checkpoint ID/content digest（自引用）时 fail closed；
- `effective_budget_bindings` 漏任一 scope、重复 scope、乱序、错误 null、非法 source 组合、混用 source fields，或缺任一 scope 的预算事实时 fail closed；无 adjustment 却伪造空 `budget_adjustment_digest` 时 fail closed；
- measurement 字段缺/混合、unverified 带数值、verified 缺 ref/digest、把 unknown 当 0 时 fail closed；`unverified_assessment` 缺字段/顺序错、disposition/review_status mismatch 或 unknown、pending 带 review ref、accepted/rejected 缺 ref、非独立 evaluator、把 pending 当 within-budget、未 review 就 unverified adjust/closure 时 fail closed；
- override 第二次 consume、跨 lineage/task/policy/scope inherit、跳过 origin consuming checkpoint、inherit 改变 ceiling 或存在 superseding source 时 fail closed；adjust/override 携带 measurement tuple（把观测当授权事实）时 fail closed；inherited adjustment 当前 effective ceiling ≠ origin `new`、origin payload 与 origin 当时 predecessor 不匹配或 lineage 不连续时 fail closed；
- 同一 checkpoint 派生 digest 在不同 Attempt context projection 中不一致时 evidence 不能关闭 requirement；
- 缺权威正文时 recovery 拒绝继续且状态为 blocked/frozen/needs_user 之一，不得合成正文；
- 完成标准变化绕过 authorized revision 时 fail closed。

## Slice 3：Content-addressed Rules 与逐记录 EvidenceRecord

交付物：

- RFC 8785 canonical identity block、deterministic rule ordering/path normalization、明确 hash domain 与 content-derived resolution ID；
- create-only assigned/submitted RuleResolutionArtifact store，不允许同路径覆盖或 current artifact；
- WorkUnitAttempt 的 `assigned_rule_resolution_id`；
- EvidenceRecord 的 `attempt_id`、`submitted_rule_resolution_id` 和 assigned/submitted comparison；
- EvidenceRecord canonical content digest、create-only persistence 和 supersedes/related refs；
- rule content、role、instance、context generation、task revision、work unit、attempt 的完整复核；
- implementation_check 绑定具体 ChangeThesis revision/digest；
- `EvidenceRecord.implementation_check.acceptance_results` 只引用 TaskRevision acceptance IDs；
- 删除 manifest `rule_resolution`、arbitrary hash acceptance、`required_rule_files_read` 和无消费者 `applied_checks`。

完成条件：

- reviewer/tester 不能复用 implementation resolution；
- assigned/submitted rules 不一致时不能产生 accepted evidence；
- required rules 只存在于对应 resolution artifact，Attempt/Record 不复制列表；
- 相同 resolution ID 只能对应相同 canonical bytes，artifact 不能原地覆盖；
- `resolution_id`/digest 自身、`created_at` 和 envelope metadata 不进入 hash domain，避免自引用与时间破坏幂等；
- 相同 attempt/rules 的重复解析以及 assigned/submitted 两阶段解析必须得到 byte-identical identity 与同一 ID；已存在 artifact 只在 exact identity 复核后复用；
- EvidenceRecord 的 task/work-unit/agent/thesis/rules 冗余快照与 Attempt 不一致时 fail closed；
- EvidenceRecord 同 ID 异内容、覆盖或删除时 fail closed；supersedes 不能让旧 referenced record 消失；
- 同文件权限篡改仍按 audit-only 诚实报告，不声称不可伪造。

### Agent-independent amendment 增量（Slice 3）

引用 ADR-004 决策七（字段/hash/state 规范定义以 ADR 为准，本节省略）。

交付物：

- `EvidenceRequirement.verification_class`（`regression` / `release_audit` / `acceptance_evidence`，三类互斥），dispatch 时随 closure basis 冻结；
- `EvidenceRecord.implementation_check.evidence_requirement_results[].verification_use` 结构化字段（固定设计，非顶层）：`permanent_test_evidence` / `audit_record_evidence` / `acceptance_proof_evidence`；单个 record 可按不同 result 同时满足不同 verification_class。

完成条件：

- validator 只校验结构化兼容：按 result 的 `evidence_requirement_id` 解析 requirement class → exact class/use 配对 → result 的 evidence_refs 解析到兼容 `ArtifactClaim.kind`（permanent→verification；audit/acceptance→report）；**不解析、不判断自由文本里的动态数据或稳定 signal**；
- 缺 use、未知 use、错配、引用不兼容 claim kind 全部 fail closed；
- 事实分类（稳定规则 vs 数据快照 vs 一次性复现）由 Lead/reviewer 语义判断并留 provenance。

负向验收（至少，全部为纯结构化不兼容）：

- `verification_class=regression` 的 requirement 被 `verification_use=acceptance_proof_evidence` 的 result 关闭时被拒；
- `verification_class=acceptance_evidence` 的 requirement 被 `verification_use=permanent_test_evidence` 的 result 关闭时被拒；
- `verification_use=audit_record_evidence` 的 result 被计入永久测试或回归证据时被拒；
- result 的 evidence_refs 解析到不兼容 `ArtifactClaim.kind`（如 permanent 指向 report claim）时被拒。

## Slice 4：GateRequirement、GateEvaluation 与 Finding Resolution

交付物：

- TaskRevision-owned GateRequirements：kind、independence、question/acceptance refs、evidence level、waiver policy、task-wide/selected-work-unit subject selector 和 freshness policy；
- GateEvaluation 唯一拥有 evaluator verdict/answers，Finding 唯一拥有 finding body/identity；
- GateEvaluation `evaluator_attempt_id`、同-attempt submission record 与 canonical subject task revision/WorkUnit/implementation Attempt/EvidenceRecord refs；
- repository snapshot artifact/digest、derived CodeSurface derivation version/digest 与 canonical subject digest；
- subject completeness/accepted/not-stale validator，以及对全部 subject producer agents 的 independence 计算；
- review/test EvidenceRecord 只保存 submission provenance，删除 verdict/answers/finding 同义字段；
- GateEvaluation/Finding create-only digest、supersedes/related lineage；
- append-only FindingResolution 受控写入与 evaluator/adjudicator/policy authorization provenance；
- `GateEvaluation.quality_question_answers` 只接受 TaskRevision question IDs；
- `GateEvaluation.acceptance_results` 只接受稳定 acceptance IDs；
- evaluator replacement/adjudication audit；
- protected gate lineage 与 unresolved Finding 跨 revision carry-forward；
- 删除 latest-wins 和含混 `Gate`/`Evidence` 权威节点。

完成条件：

- 新 evaluator pass 不能覆盖未解决的旧 blocking Finding；
- GateEvaluation 缺 evaluator attempt、submission record attempt 不一致、规则无效时不能关闭 gate；
- subject refs 不完整/未 accepted/stale、subject digest/snapshot/surface 不匹配，或 evaluator 对任一 producer 不独立时不能关闭 gate；
- subject implementation/evidence/snapshot 改变后旧 pass 不能关闭新结果；
- EvidenceRecord 中的 reviewer/tester verdict/finding 不得被提升或与 GateEvaluation 双写；
- `budget_assessment_result`：评审 unverified measurement 的 GateEvaluation 绑定被评 binding 所在的前序 accepted checkpoint（`assessed_checkpoint_ref+digest=C_pending`、`assessed_effective_budget_binding_digest`、scope/control/metric statuses），`outcome=accepted|rejected` 与 `review_status`/`lead_disposition` exact mapping，subject/result 纳入 canonical subject manifest/digest，GateRequirement selector 明确要求 budget assessment；构造顺序单向（`C_pending` → 独立评审 → successor `C_reviewed` 消费，不得绑定自身）；`review_gate_evaluation_ref` 仅在 exact subject/result match、not stale（`budget_review_subject_projection` byte-identical：仅三 review-result 字段按 outcome 映射，其他字段变化即 stale；不得以完整 binding digest 相等为 fresh 依据）、evaluator independent 时有效；
- `addressed` 必须有 implementation proposal、authorized evaluator attempt/submission/rule context 和 supporting refs；
- `disproved` 必须绑定 authorized evaluator/adjudicator attempt/submission/rule context/反证；`waived` 必须绑定 active policy/TaskRevision authorization record；
- overwrite/delete/same-ID-different-content 无效，supersedes 不关闭旧 blocking Finding；
- Lead 默认不能单方面 waive required independent gate；
- Lead 不能用 revision-hop 降级 gate、自授 authority 或清除 Finding；
- Gate Engine 只验证 authority、requirements 和 resolutions，并派生 closure；
- question/acceptance 字段存在或数量不能单独关闭 gate。

负向验收（至少）：

- 引用普通无关 GateEvaluation（无 `budget_assessment_result` 或 subject 不匹配）作为 unverified adjust/closure 的 review 依据时被拒；
- same-checkpoint circular ref（evaluation 绑定消费它的 checkpoint 自身）、跨 checkpoint/跨 binding 引用、successor 引用非 predecessor 的 assessment 时被拒；
- **以完整 binding digest 相等作为 fresh 依据（把合法 successor 判 stale）时被拒**；除三 review-result 字段（review_status/lead_disposition/review_gate_evaluation_ref）外任一字段变化却复用评审（projection 不 byte-identical）时被拒；
- `budget_assessment_result` 的 assessed checkpoint/scope/control/outcome 与 `unverified_assessment` 不一致、subject 已 stale、evaluator 非独立，或 GateRequirement selector 未明确要求 budget assessment 时被拒。

### Agent-independent amendment 增量（Slice 4）

引用 ADR-004 决策七。

依赖顺序（见「Slice 2 增量化交付」节）：本增量在 Slice 2（完成于增量 4）之后落地。本节含 **control consumer closure**（该条款原属 Slice 2 拆分草案，已移出并入本节，不构成 Slice 2 完成前置）：`unverified_assessment` 独立评审准入（review_status=accepted|rejected 消费 `budget_assessment_result`）；`budget_assessment_result` 消费 Slice 2 增量 4 的 checkpoint binding/派生字段（`assessed_checkpoint_ref+digest`、`assessed_effective_budget_binding_digest`）。

交付物：

- Finding typed basis：`contract_violation` / `regression` / `newly_discovered_risk` / `hardening_opportunity`；
- Gate Engine 按 active policy 映射派生 blocking：`contract_violation`/`regression` 默认 blocking；`newly_discovered_risk` 需 risk-owner/user 裁决（否则 needs_user）；`hardening_opportunity` 默认非阻塞，进非抢占 WorkUnit；
- **unverified measurement 的独立 review 落地（非循环构造顺序）**：`unverified_assessment.review_status=accepted|rejected` 依赖 exact independent `GateEvaluation` ref+digest（ADR-006 Amendment 节准入），且该 GateEvaluation 携带 `budget_assessment_result` 绑定**被评 binding 所在的前序 accepted checkpoint**（`assessed_checkpoint_ref+digest=C_pending`、`assessed_effective_budget_binding_digest`、scope/control/metric statuses、typed `outcome=accepted|rejected`；纳入 canonical subject manifest/digest；GateRequirement selector 必须明确要求 budget assessment，不得复用普通 implementation gate）；顺序：先接受 `C_pending`（pending、review ref null）→ 独立评审 `C_pending` 的 exact binding → successor `C_reviewed` 消费该 evaluation（不得绑定 `C_reviewed` 自身）；**stale 判定用 `budget_review_subject_projection`（排除 review_status/lead_disposition/review_gate_evaluation_ref 三字段外的全部字段）byte-identical，只允许三字段按 outcome 从 pending/null 映射，其他字段变化即 stale 需重新 pending→review；不得要求 `C_reviewed` 完整 binding digest 等于 `C_pending`**；Slice 2 至本 Slice 落地前，依赖独立 review 的 unverified budget adjust 与 closure fail closed；

完成条件：

- blocking 与 basis/policy 一致，agent 自由文本不能自称/否认 blocking；
- EvidenceRecord 不复制 verdict/finding（ADR-004 保持）；`FindingResolution` authority 不变。

负向验收（至少）：

- `hardening_opportunity` Finding 被当作 blocking 阻塞 gate 时被拒；
- `newly_discovered_risk` 在无 risk-owner/user 裁决时自动阻塞被拒（应转为 needs_user）。

## Slice 5：上下文投影与 Typed Relationship View

交付物：

- Lead、Work Agent、Independent Evaluator 三类 context projection；
- 从 `ProjectPolicyRevision → TaskRevision → WorkUnit → WorkUnitAttempt → EvidenceRecord` 与 `GateEvaluation → evaluator Attempt/submission + subject revision/WorkUnit/implementation Attempt/EvidenceRecord/snapshot/CodeSurface → Finding/Resolution` 派生的 typed edges；
- derived CodeSurface；
- Gate Engine deterministic AggregateOutcome projection 与 source-digest cache invalidation；
- candidate relation 与 authoritative/derived relation 分离；
- relationship invalidation 和 recomputation；
- drift、orphan surface、stale evidence、unresolved finding audit。

完成条件：

- projection 可以从权威对象完全重建；
- 删除 view 不会丢失 task/runtime/evidence/gate 事实；
- candidate relation 不能修改 scope、permission、state 或 gate；
- AggregateOutcome cache 删除后可重算，且 agent/Lead 不能直接写 aggregate verdict；
- AggregateOutcome 只消费 current subject digest 精确匹配且未 stale 的 GateEvaluation；漏 subject 或旧 pass 一律不参与 closure；
- 不引入第二套事实源。

### Agent-independent amendment 增量（Slice 5）

引用 ADR-004 决策七（digest 派生）与 ADR-006 Amendment 节（budget 两层累计）。

交付物（只投影，不新增事实源）：

- `budget_adjustment_digest` / `effective_verification_plan_digest` / `closure_basis_digest` 视图；
- budget 两层累计 projection（WorkUnit-lineage 与 task-lineage）；
- 关系视图纳入 digest 引用（source refs+digests）。

完成条件：

- projection 从权威对象重算得到 byte-identical digest；删除视图不丢失任务/运行时/evidence/gate 事实；
- 不新增 plan truth 对象或预算事实源。

## Slice 6：Protocol Epoch、原子 Cutover 与旧路径关闭

交付物：

- user-controlled ProjectPolicyRevision genesis、linear rotation 与 create-only `.orbit/protocol.yaml` immutable genesis ref；marker canonical parent 唯一定义 active artifact root；
- 所有 project-scoped commands 的 root/epoch preflight；
- mixed v1/v2 epoch fail-closed 检查；
- 全部 v2 CLI writer/reader/validator；
- v2 templates、help、examples 和 runtime references；
- v1 schema rejection；
- 激活仅接受最终 exact checkpoint/registry schema：Slice 2 增量 1-4 中间形态非 adopted runtime contract，无读兼容/backfill/双读；
- legacy code、fallback、fixtures 和 compatibility tests 删除；
- clean repository 安装后 E2E；
- closure audit 和真实 dogfood。

必须覆盖的 E2E：

```text
create ProjectPolicyRevision genesis from user authority source
  -> verify authorization/project/digest
  -> create orbit-v2 protocol root with immutable genesis ref
  -> trusted provider resolves canonical lead_runtime_subject_ref + assertion_digest
  -> controlled writer atomically claims lead_control_id + binds one active LeadSession/runtime subject + creates accepted genesis checkpoint
  -> create multiple Task/TaskRevision refs with stable requirements/GateRequirements
  -> create exactly one root and reachable child work units with parent/dependency refs
  -> optionally repeat provider-resolve + atomic control/session/genesis create for a second Task in a separate Git branch/worktree（task-centric：路径不重叠即天然并行，无 Orbit 层 disjointness 协调）
  -> create ChangeThesis revision/digest
  -> LeadControl appends selection/dispatch LeadCheckpoint binding the single Task
  -> preallocate attempt_id and create/reuse assigned rules
  -> append AttemptCreated exactly once with checkpoint binding and no other active Attempt
  -> submit EvidenceRecord with submitted rules
  -> terminate attempt
  -> LeadControl/writer derives fingerprint only from stable semantic identity basis
  -> append successor LeadCheckpoint with separate per-occurrence supporting provenance + prior chain
  -> replace a work agent with terminal-predecessor/checkpoint-bound successor attempt
  -> replace LeadSession via terminal/release-old-then-successor/bind-new or atomic compare-and-successor without changing lead_control_id
  -> recover queue/selection from the unique accepted checkpoint tip
  -> resolve task-wide/selected canonical subject manifest
  -> after implementation terminal/checkpoint, serially submit evaluator EvidenceRecord and subject-pinned independent GateEvaluation
  -> retain Findings and resolve them through authorized FindingResolutions
  -> derive GateRequirement closure
  -> Gate Engine derives AggregateOutcome
  -> terminal evaluator Attempt / checkpoint before test, next implementation, or Task switch
  -> handoff/complete the Task；executor 更换只走 Task 内 session replacement（同 lead_control_id，terminal old -> successor new），不存在 cross-control transfer
```

负向测试至少覆盖：

- v1 task/evidence/state 被明确拒绝；
- marker missing、wrong project/epoch 和 active root 混合 v1/v2 被明确拒绝；
- missing/forged ProjectPolicyRevision genesis/authorization/ref/digest、initial TaskRevision self-grant、unauthorized rotation 或 policy lineage fork 被拒绝；
- policy rotation 后仍用旧 TaskRevision/policy ref 关闭 gate 被拒绝；
- duplicate `lead_control_id`/second genesis、same Task 上另建 control lineage、伪造 writer authority、未 atomic append 却自称 accepted 的 checkpoint 被拒绝；AgentInstance/LeadSession replacement 不得改变 control ID；
- trusted provider 尚未解析 canonical runtime subject、active LeadSession 未绑定时接受 genesis，或 atomic create 失败后残留 claimed ID/session/checkpoint/dispatchable 半状态被拒绝；
- 同一 `lead_control_id` 出现多个 active LeadSession、active Task、selected WorkUnit 或 non-terminal Attempt 被拒绝；非当前 session dispatch、replacement 缺 terminal/atomic successor provenance 被拒绝；
- 同一 provider-verified runtime subject 以相同或不同 AgentInstance ID/别名同时绑定两个 control IDs 时，第二个 session activation/checkpoint acceptance/dispatch 被拒绝；self-reported subject 或只比较 AgentInstance 字符串的实现不合格；
- 同一 Task 的第二条 control lineage（fork/reuse/双 tip selection）被拒绝；不同 Task 在各自 Git branch/worktree 下并行不需要 Orbit 层 disjointness 协调，也不得因缺 project-wide registry 被误拦截；不同 project 独立并行不受影响（2026-08-17 task-centric 修订）；
- 即使 checkpoint/queue facts 损坏，同一 Task 或 WorkUnit 的第二个 non-terminal Attempt 仍被 task-local backstop 拒绝；
- WorkUnit multiple root/orphan、parent/dependency ref missing/cross-task/cross-revision/cyclic/not-ready 时被拒绝；唯一 root reachability/runnable set 不得由阶段标签覆写；
- active Attempt 存在时 Task switch 被拒绝；
- successor 缺 terminal predecessor、缺 current dispatch LeadCheckpoint、checkpoint selection 不匹配或 checkpoint lineage fork 时被拒绝；
- implementation non-terminal 时并行 dispatch review/test，或 review non-terminal 时并行 dispatch test/implementation 被拒绝；
- Work Agent 直接创建/dispatch child work 或修改 queue/priority/selection 被拒绝；
- 首轮无 Delivery delta 且 thesis/agent-context/scope/verification plan 均无实质变化时 successor 被拒绝；连续两轮无 Delivery delta 时 automatic continue 被拒绝；
- 相同 failure/finding fingerprint 的第三次 Attempt 缺 provider-verified `task.retry.override` AuthorizationRecord，或 scope digest 未 exact bind project/TaskRevision/WorkUnit/fingerprint/prior Attempt chain/authorizing checkpoint/`lead_control_id`、issuer 非 user/control-plane、opaque/self-reported/cross-task/fingerprint replay 时被拒绝；
- fingerprint 由 Lead/Work Agent 自报、free text/message wording 生成，或把 `lead_control_id`、Attempt/checkpoint/session/AgentInstance、Finding/GateEvaluation/test/validator outcome record ID/ref/digest 混入 identity hash 时被拒绝；rename/reorder/AgentInstance alias 不得改变 identity；
- 两个不同 Attempt、不同 outcome record ID/digest 但相同 stable test/check identity + signal subject + normalized failure code 必须得到同一 fingerprint；stable Finding identity 相同但 GateEvaluation ref 更新时也必须相同；typed code、stable Finding identity、stable test/check identity 或 signal subject identity 不同则 fingerprint 必须不同；
- 已有 Finding 未复用 stable identity、非 Finding failure 缺 stable test/rule/check/signal subject identity、supporting provenance 无法支持 basis，或跨 checkpoint/transfer prior chain 有缺口时必须 freeze，不得自动计为新 failure；
- Assurance 持续增长而 Delivery 不动时继续自动 hardening 被拒绝；额外 hardening 不得抢占 active mainline；
- scope/blast radius/review surface/goal relation 失控时不得等待 round fuse 才 freeze；
- wall-clock fallback 缺 active ProjectPolicyRevision orchestration policy/authorized immutable record、checkpoint 未 pin exact ID/digest、读取 mutable config 或 stale digest 时被拒绝；timer 只能产生 `checkpoint_due`，用 timer 直接切换 Task、改 priority、终结 Attempt 或 dispatch 被拒绝；
- LeadCheckpoint 同 ID 异内容、原地覆盖、non-tip append、fork/latest-wins、缺 exact refs 或复制 task/evidence/gate truth 被拒绝；
- 把 scheduler/anomaly/self-check/task-queue projection 拆成第二 control/fact source，或为本控制循环引入 graph DB/broad Portfolio platform 的设计不通过 closure review；
- 没有 WorkUnitAttempt/attempt_id 的 EvidenceRecord 被拒绝；
- WorkUnitAttempt 创建后 patch assigned rules、从非 creation event 提供 started_at/initial status，或 AttemptCreated 失败后 dispatch 被拒绝；
- wrong-role、wrong-instance、wrong-context-generation、wrong-revision、wrong-work-unit、wrong-attempt rule resolution 被拒绝；
- rules 在 assignment/submit 之间变化时被阻塞；
- rule artifact 同 ID 异内容、同路径覆盖或 required rules 复制漂移被拒绝；
- 相同 identity 重复解析不产生同一 ID、assigned/submitted 相同输入得出不同 ID、hash 自引用或 `created_at` 进入 identity 的实现被 deterministic repeat test 拒绝；
- stale/unknown ChangeThesis revision/digest 被拒绝；
- WorkUnit current thesis 指针覆盖或 latest-wins 改写历史 thesis refs 被拒绝；
- unknown/duplicate/missing task question 或 acceptance ID 被拒绝；
- GateEvaluation 缺 evaluator attempt、submission EvidenceRecord 属于不同 attempt、assigned/submitted rules 不一致或 independence 不成立被拒绝；
- GateEvaluation 缺 subject revision/WorkUnit/implementation Attempt/EvidenceRecord refs、task-wide 漏 subject、subject ref 未 accepted/stale 或 snapshot/CodeSurface digest 不匹配被拒绝；
- evaluator 与任一 subject producer agent 相同、自审被拆成多 subject 后漏算，或旧 pass 复用到新 implementation/evidence/snapshot 被拒绝；
- review/test EvidenceRecord 携带可独立解释的 gate verdict/answers/finding 被拒绝；
- EvidenceRecord/GateEvaluation/Finding overwrite、delete、same-ID-different-content、不兼容 supersedes/reuse，以及 FindingResolution overwrite/delete/issuer mutation 被拒绝；
- evaluator replacement 不能清除 Finding；
- child TaskRevision 未经父/当前 authority 批准而删除/降级 protected gate、放宽 waiver policy、重设 risk owner/adjudicator、自授 authority，或清除 unresolved Finding 被拒绝；
- unauthorized addressed/disproved/waived resolution 被拒绝；
- addressed/disproved 缺 issuer attempt/submission/rule context/supporting refs，或 waived 使用自由文本 issuer/伪 policy authorization ref 被拒绝；
- agent/Lead 直接写 AggregateOutcome 或使用 stale source-digest cache 推进状态被拒绝；
- candidate relationship 不能推进 state 或 gate；
- 旧 writer 不能再生成可被 v2 接受的 artifact。

### Agent-independent amendment 增量（Slice 6）

引用 ADR-005 实施约束 15-17、ADR-006 Amendment 节、ADR-004 决策七。

E2E/cutover 必须覆盖：

- 完整链路：policy genesis → protocol root → control genesis → TaskRevision/WorkUnit 图 → dispatch checkpoint 冻结 `budget_adjustment_digest`/`effective_verification_plan_digest`/`closure_basis_digest`（source refs+digests，单向派生）→ AttemptCreated pin refs → evidence/gate 相对 basis 解释 → Finding basis/blocking → budget 两层累计 → terminal/checkpoint/next dispatch → recovery 沿唯一 tip 重建；
- amendment 条款负向路径并入既有负向测试清单：缺 override/scope（含 `budget_scope_type`）不匹配、digest 自引用/不一致、禁补造、完成标准绕 authorized revision、`verification_class`/`verification_use` 配对不符、hardening 误阻塞、超 ceiling 无 override 唯一进入 needs_user、recovery 三态互斥归位；
- 文档治理：AGENTS.md 定位为客户端提示（非产品 authority）、boom/alpha 文档治理落地。

### Slice 6 验收预算（2026-08-17 task-centric 修订）

本节为产品范围修订后的 Slice 6 验收预算；上文 cross-control E2E/负向条目按本节与各 ADR 修订记录执行。首个 task-centric MVP 只保留约 6 个高价值场景：

1. 单 Task 完整 happy path：init v2 → create/start one Task → dispatch one Attempt → submit Evidence → independent review/test GateEvaluation → resolve Finding if present → derive outcome → handoff/complete；
2. 两个 Task 的路径/分支隔离：不同 Git branch/worktree，无 Orbit 路径冲突；
3. 同一 Task fork/reuse（第二条 control lineage）冲突拒绝；
4. Evidence 与 Attempt/Task exact binding；
5. unresolved Finding 阻止完成，合法 resolution 后通过；
6. wrong/mixed protocol epoch 拒绝。

纪律：测试方法 ≤10、新增测试代码 ≤300 行；语义稳定前只跑静态检查和精确单方法；focused 在增量收口后跑一次；`tests/orbit_test.sh` 在 focused 通过后跑一次；同一区域连续失败并引发新业务分支时停止重估，不继续堆 patch。

本修订不改变项目级例外：`.orbit/protocol.yaml` 与 `policy/` 保留在项目级，有意接受其 Git 合并冲突风险（policy rotation 低频，同时轮换本来就是真实冲突）。

### 已知分歧（待阶段 C 收口）

`contracts/orbit-v2/schemas/lead-control.schema.json` 尚未与 2026-08-17 已修订的
`contract.yaml` enum 对齐，仍含：L127 `task_transfer_acquire` 定义、L301-310
`TaskAcquire`（L303 `released_*` required 块）、L726 action enum 的
`release/suspend/acquire`、L753-754 event enum 的 `task_suspend/task_acquire`。

这是有意推迟而非遗漏：与 `contracts/orbit-v2/contract.yaml`（仅被 tests 读取的
规格文件）不同，`schemas/*.json` 经 `schema_catalog.rb` 被 lib 运行时加载
（control_store、evidence_store、gate_fact_store、policy_store、protocol_root、
rule_resolution），修改属 production 变更——删 enum 值会使既有合法文档立即失效，
冲击面直达 contract_test fixture。该 schema 须与 store 路径改造同批进行，届时
才有测试兜底（归阶段 C）。

## Cutover Done Criteria

- ADR-003/005/006 的 accepted invariant 与最终确认的 ADR-004 contract 均有 writer、reader、validator 和测试。
- `skills/orbit/references/runtime/` 只描述已经实现的 v2。
- 全仓搜索和行为测试均证明 v1 fallback 已关闭。
- pre-activation 中间 schema 形态（Slice 2 增量 1-4）无 adopted runtime contract、无读兼容；store-level compare-and-append/崩溃/并发原子性已由受控 store 闭合。
- 所有 project-scoped commands 在其他读写前验证 `protocol_epoch: orbit-v2`，混合 epoch fail closed。
- ProtocolRoot marker parent 是唯一 active root，不存在 cwd/config/manifest root override。
- ProtocolRoot 只保存 immutable policy genesis ref，policy/task body 不复制进 marker。
- provider-subject/session/control/genesis atomic create、stable Task-scoped control identity/unique genesis、provider-verified runtime-subject session binding、single-active LeadSession/selected WorkUnit/non-terminal Attempt（Task 内）、task-local Attempt backstop、unique-root/reachability、terminal-attempt-to-checkpoint-to-dispatch、fingerprint identity/provenance hash-domain separation + stable-signal equivalence/difference + cross-checkpoint prior chain、retry override、policy-pinned fallback、checkpoint linearity/recovery 和 Work Agent single-writer guard 全部闭合；Task 内 work-unit 切换仍受 terminal→checkpoint→dispatch 边界约束；不存在 parallel legacy path；跨 Task 并行由 Git branch/worktree 隔离提供，不要求 cross-lineage ownership/transfer、disjoint parallelism 或 project-wide backstop（2026-08-17 task-centric 修订，见 ADR-005/006 修订记录）。
- v2 E2E、negative paths、recovery、audit、handoff 和 clean-install dogfood 通过。
- 没有 compatibility branch、自动 backfill、dual-write 或 hidden fallback。
- 未覆盖风险和无法证明的 runtime delivery 明确报告，不用字段数量代替质量证据。

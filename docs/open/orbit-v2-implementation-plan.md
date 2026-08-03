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

ADR-006 control contract、Slice 1 exact refs/single-active validator 和 Slice 2 `lead_control_id`/registry/LeadCheckpoint/LeadControl design 未冻结前，不继续扩大 Evidence/Validator substrate，也不进入 runtime 实现。当前 Slice 0 schema 不具备 WorkUnit parent/dependency refs、Attempt predecessor/dispatch checkpoint binding、stable control identity/ownership、LeadCheckpoint 或 LeadControl；本计划不得把它们描述为既有能力。

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
- `addressed` 必须有 implementation proposal、authorized evaluator attempt/submission/rule context 和 supporting refs；
- `disproved` 必须绑定 authorized evaluator/adjudicator attempt/submission/rule context/反证；`waived` 必须绑定 active policy/TaskRevision authorization record；
- overwrite/delete/same-ID-different-content 无效，supersedes 不关闭旧 blocking Finding；
- Lead 默认不能单方面 waive required independent gate；
- Lead 不能用 revision-hop 降级 gate、自授 authority 或清除 Finding；
- Gate Engine 只验证 authority、requirements 和 resolutions，并派生 closure；
- question/acceptance 字段存在或数量不能单独关闭 gate。

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

## Slice 6：Protocol Epoch、原子 Cutover 与旧路径关闭

交付物：

- user-controlled ProjectPolicyRevision genesis、linear rotation 与 create-only `.orbit/protocol.yaml` immutable genesis ref；marker canonical parent 唯一定义 active artifact root；
- 所有 project-scoped commands 的 root/epoch preflight；
- mixed v1/v2 epoch fail-closed 检查；
- 全部 v2 CLI writer/reader/validator；
- v2 templates、help、examples 和 runtime references；
- v1 schema rejection；
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
  -> optionally repeat provider-resolve + atomic control/session/genesis create for a disjoint Task set and distinct runtime subject
  -> create ChangeThesis revision/digest
  -> LeadControl atomically acquires disjoint Task ownership and appends selection/dispatch LeadCheckpoint
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
  -> old lineage checkpoint releases/suspends Task ownership
  -> old LeadSession terminals/releases its runtime-subject binding
  -> new lineage checkpoint/session acquires Task + executor with exact transfer provenance
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
- 同一 LogicalLead/Task 的双 open-queue ownership/双 tip selection、new acquire 早于 old release/relinquishing-suspend、executor bind 早于 old session terminal/release、transfer refs 不匹配，或 task sets/runtime subject sets 任一重叠的 control lineages 并行被拒绝；不同 project 独立、同 project 两组集合均 disjoint 的并行不被误拦截；
- 即使 registry/checkpoint/queue facts 损坏，同一 Task 或 WorkUnit 的第二个 non-terminal Attempt 仍被 project-wide backstop 拒绝；
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

## Cutover Done Criteria

- ADR-003/005/006 的 accepted invariant 与最终确认的 ADR-004 contract 均有 writer、reader、validator 和测试。
- `skills/orbit/references/runtime/` 只描述已经实现的 v2。
- 全仓搜索和行为测试均证明 v1 fallback 已关闭。
- 所有 project-scoped commands 在其他读写前验证 `protocol_epoch: orbit-v2`，混合 epoch fail closed。
- ProtocolRoot marker parent 是唯一 active root，不存在 cwd/config/manifest root override。
- ProtocolRoot 只保存 immutable policy genesis ref，policy/task body 不复制进 marker。
- provider-subject/session/control/genesis atomic create、stable control identity/unique genesis、provider-verified runtime-subject project-wide active-session uniqueness/transfer、single-active LeadSession/Task/WorkUnit/Attempt、cross-lineage Task ownership/transfer、task+executor disjoint parallelism、project-wide Attempt backstop、unique-root/reachability、terminal-attempt-to-checkpoint-to-dispatch、fingerprint identity/provenance hash-domain separation + stable-signal equivalence/difference + cross-checkpoint prior chain、retry override、policy-pinned fallback、task-switch、checkpoint linearity/recovery 和 Work Agent single-writer guard 全部闭合；不存在 parallel legacy path。
- v2 E2E、negative paths、recovery、audit、handoff 和 clean-install dogfood 通过。
- 没有 compatibility branch、自动 backfill、dual-write 或 hidden fallback。
- 未覆盖风险和无法证明的 runtime delivery 明确报告，不用字段数量代替质量证据。

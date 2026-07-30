# Orbit v2 Implementation Plan

- 状态：Open
- 日期：2026-07-30
- 父架构：[ADR-003](../adr/003-lead-orchestrated-dynamic-agent-team.md)
- EvidenceRecord 子协议：[ADR-004](../adr/004-role-rule-context-evidence-binding.md)
- Cutover 决策：[ADR-005](../adr/005-orbit-v2-clean-cut-and-legacy-retirement.md)
- 当前 runtime：v1；本计划尚未生效

## 目标

一次性建立并切换到以下闭环：

```text
ProtocolRoot(orbit-v2)
  -> ProjectPolicyRevision genesis / active lineage
  -> TaskRevision.goal / requirements
  -> WorkUnit
  -> ChangeThesis revision/digest
  -> WorkUnitAttempt / AgentInstance / LeadSession
  -> assigned RuleResolutionArtifact
  -> EvidenceRecord
  -> submitted RuleResolutionArtifact
  -> GateRequirement subject selector
  -> evaluator Attempt / EvidenceRecord
  -> subject-pinned GateEvaluation
  -> Finding / FindingResolution
  -> derived AggregateOutcome
```

完成后，Orbit 只有一套 task/work-unit/team/evidence/gate 权威语义，不保留 v1 compatibility、双写或 fallback。

## 非目标

- 不把 v1 artifact 自动迁移成 v2。
- 不在 v1 正式 API 中零散增加 v2 字段。
- 不引入图数据库或允许 agent 任意写关系。
- 不把 context delivery、文件读取或 hash 存在解释成模型理解证明。
- 不用固定 token、轮数或 diff 行数替代上下文与 review 判断。

## 权威边界

| 事实 | Writer / Owner | 消费者 |
| --- | --- | --- |
| project identity、active protocol epoch、immutable policy genesis ref；marker parent 定义 active root | `ProtocolRoot` | 所有 project-scoped commands |
| protected gate minimum、waiver/risk-owner/adjudicator/update authority、bootstrap/rotation provenance | create-only `ProjectPolicyRevision` lineage | TaskRevision、Gate Engine、policy validator |
| `goal`、全局 requirement/question IDs、GateRequirements、exact policy revision ref | `TaskRevision` | Lead、WorkUnit、Gate Engine |
| 稳定局部目标、授权范围、requirement refs、stop conditions、immutable initial thesis ref | `WorkUnit` | Lead、Attempt creator、projection |
| 可证伪方案主张 | create-only `ChangeThesis` revision/digest | WorkUnitAttempt、EvidenceRecord、GateEvaluation |
| assignment、agent、context generation、authority snapshot；start/end/status events | append-only `WorkUnitAttempt` | Agent、Lead、`EvidenceRecord`、roster projector |
| runtime identity 和 instance lifecycle | `AgentInstance` / LeadSession lifecycle | Attempt、dispatch、audit |
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

## Slice 0：冻结 v2 合同

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
- parent/child、task revision 和 authority scope 校验；
- WorkUnit 只保存 `acceptance_refs`、`evidence_requirement_refs`、`source_requirement_refs` 和 immutable `initial_change_thesis_ref`；
- create-only ChangeThesis revisions 与 canonical digest；
- append-only WorkUnitAttempt：预分配 ID、create/reuse assigned artifact、单次 `AttemptCreated` immutable Assignment snapshot、agent instance、context generation、authority snapshot、thesis ref、start/end/status events；
- TaskRevision protected change diff/digest、parent revision、authority-source revision、issuer/policy/issued-at provenance 和 unresolved Finding inheritance validator；
- 所有正式 EvidenceRecord 强制要求 `attempt_id`，且 create-only/immutable；
- 删除运行时 `child_slices`、`parent_goal` 和隐式派单读取路径。

完成条件：

- work agent 不能修改 `TaskRevision.goal`；
- scope escalation 只能由 Logical Lead 产生新 revision 或新 WorkUnit；
- agent replacement/retry/context rebuild 产生 successor attempt，不覆盖 WorkUnit 或旧 attempt；
- thesis revision 变化产生 pin 新 digest 的 successor attempt，WorkUnit 不存在可覆盖 current thesis pointer；
- `AttemptCreated` 前不得 dispatch，创建后不得 patch assigned resolution；started_at/initial status 只来自 creation event；
- 没有 WorkUnitAttempt 的 EvidenceRecord 无法写入；
- task-level acceptance 通过稳定 ID 被引用，不被复制；
- EvidenceRecord 的 thesis ref 必须等于 Attempt 的 `change_thesis_id + revision + digest`；
- child revision 未经 inherited authority 批准不能删除/降级 protected gate、放宽 waiver policy、重设 risk owner/adjudicator 或清除 Finding。
- initial TaskRevision 的 protected contract 不弱于 active ProjectPolicyRevision minimum，waiver/risk-owner/adjudicator 只能引用/收窄 policy grants 或 policy-authorized immutable record；policy rotation 不改写旧 provenance，但旧 TaskRevision closure stale，继续执行必须新 revision rebind active policy。

## Slice 2：Dynamic Team 与 Logical Lead Continuity

交付物：

- policy/capability profile 与 live roster 分离；
- AgentInstance create/replace/terminate lifecycle；
- LogicalLead 与 LeadSession generation；
- active roster、current assignment 和 replacement history 从 AgentInstance/WorkUnitAttempt lifecycle 派生；
- durable lead context、handoff 和 recovery continuity；
- lead session 无法证明连续性时 fail closed。

完成条件：

- 静态配置不能被解释为当前 live team；
- roster projection 删除后可从 attempts 重建；
- agent replacement 不改变 WorkUnit、旧 Attempt 或 EvidenceRecord identity；
- lead replacement 后能恢复同一 `TaskRevision`、open `WorkUnit`/`WorkUnitAttempt`、`Finding` 和未满足的 `GateRequirement`。

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
  -> create TaskRevision with stable requirements/GateRequirements
  -> create root and child work units
  -> create ChangeThesis revision/digest
  -> preallocate attempt_id and create/reuse assigned rules
  -> append AttemptCreated exactly once
  -> submit EvidenceRecord with submitted rules
  -> terminate attempt and replace a work agent with successor attempt
  -> replace a lead session and recover
  -> resolve task-wide/selected canonical subject manifest
  -> submit evaluator EvidenceRecord and subject-pinned independent GateEvaluation
  -> retain Findings and resolve them through authorized FindingResolutions
  -> derive GateRequirement closure
  -> Gate Engine derives AggregateOutcome
```

负向测试至少覆盖：

- v1 task/evidence/state 被明确拒绝；
- marker missing、wrong project/epoch 和 active root 混合 v1/v2 被明确拒绝；
- missing/forged ProjectPolicyRevision genesis/authorization/ref/digest、initial TaskRevision self-grant、unauthorized rotation 或 policy lineage fork 被拒绝；
- policy rotation 后仍用旧 TaskRevision/policy ref 关闭 gate 被拒绝；
- 没有 WorkUnitAttempt/attempt_id 的 EvidenceRecord 被拒绝；
- WorkUnitAttempt 创建后 patch assigned rules、从非 creation event 提供 started_at/initial status，或 AttemptCreated 失败后 dispatch 被拒绝；
- wrong-role、wrong-instance、wrong-context-generation、wrong-revision、wrong-work-unit、wrong-attempt rule resolution 被拒绝；
- rules 在 assignment/submit 之间变化时被阻塞；
- rule artifact 同 ID 异内容、同路径覆盖或 required rules 复制漂移被拒绝；
- 相同 identity 重复解析不产生同一 ID、assigned/submitted 相同输入得出不同 ID、hash 自引用或 `created_at` 进入 identity 的实现被 deterministic repeat test 拒绝；
- stale/unknown ChangeThesis revision/digest 被拒绝；
- WorkUnit current thesis 指针覆盖或 latest-wins 隐藏并发 thesis refs 被拒绝；
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

- ADR-003/005 的 accepted invariant 与最终确认的 ADR-004 contract 均有 writer、reader、validator 和测试。
- `skills/orbit/references/runtime/` 只描述已经实现的 v2。
- 全仓搜索和行为测试均证明 v1 fallback 已关闭。
- 所有 project-scoped commands 在其他读写前验证 `protocol_epoch: orbit-v2`，混合 epoch fail closed。
- ProtocolRoot marker parent 是唯一 active root，不存在 cwd/config/manifest root override。
- ProtocolRoot 只保存 immutable policy genesis ref，policy/task body 不复制进 marker。
- v2 E2E、negative paths、recovery、audit、handoff 和 clean-install dogfood 通过。
- 没有 compatibility branch、自动 backfill、dual-write 或 hidden fallback。
- 未覆盖风险和无法证明的 runtime delivery 明确报告，不用字段数量代替质量证据。

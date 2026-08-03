# ADR-006：串行 Lead 编排与控制循环

- 状态：Accepted
- 日期：2026-08-03
- Owner 批准：2026-08-03
- 范围：Lead control lineage 的身份、任务选择、WorkUnit 调度、Attempt 继任、检查点、自检、进度判断与止损
- 修订：[ADR-003：Lead 编排的动态 Agent Team 与上下文治理](./003-lead-orchestrated-dynamic-agent-team.md)
- 切换约束：[ADR-005：Orbit v2 一次性切换与旧协议退役](./005-orbit-v2-clean-cut-and-legacy-retirement.md)
- 当前实现状态：仅为已接受的设计合同；当前 schema、validator、CLI 和 runtime 尚不具备本文能力

## 决策定位

项目 owner 于 2026-08-03 批准 Orbit v2 采用串行 Lead 编排与控制循环。本 ADR 是 ADR-003 的显式 amendment：ADR-003 的 dynamic team、可替换 session、bounded WorkUnit 和独立 gate 继续成立；任何把可替换 Lead runtime 当成串行 identity，或允许同一 control lineage 同时执行多个 active WorkUnitAttempt 的旧表述，均由本 ADR 取代。

本文使用 `MUST`、`MUST NOT` 和“不得”表达规范约束。示例 assessment、progress signal 和异常判据是控制器需要解释的语义，不是把自由文本 checklist、固定行数或固定轮数伪装成 validator。可机械验证的引用、lineage、唯一性和 lifecycle 条件必须由受控 writer/validator 验证；需要产品判断的 thesis、scope、收益和风险仍由 Lead 或独立 gate authority 作出并留下 provenance。

## 稳定 control lineage identity

每条控制 lineage 必须具有 project-scoped、stable、immutable 的 `lead_control_id`。它是 LeadCheckpoint lineage、task ownership、selection 和 dispatch authority 的 identity，不等同于 `AgentInstance`、`LeadSession`、context generation、进程、pane 或对话。Lead runtime 仅指当前执行这条 control lineage 的可替换载体；替换 executor 不得改变 `lead_control_id`，也不得创建新的 control lineage 来绕过既有 single-active 或止损状态。

所有 LeadCheckpoint、LeadDecision、dispatch authorization 和 WorkUnitAttempt 必须 pin exact `lead_control_id`。引用缺失、project 不一致，或通过 AgentInstance/LeadSession 名称反推 control identity 时 fail closed。

### Genesis、writer authority 与 accepted

一个 `lead_control_id` 必须恰好有一个 genesis LeadCheckpoint。未来受控 writer 必须在 project-scoped control registry/create-only store 中原子验证：

- `lead_control_id` 尚未使用，且不存在第二个 genesis；
- trusted runtime identity provider 已先解析 canonical `lead_runtime_subject_ref + assertion_digest`，且 subject assertion 对 project/provider/current executor 有效；
- genesis exact bind `project_id`、active `ProjectPolicyRevision` ref/digest、受控 writer authority provenance、初始 task ownership/queue、Lead AgentInstance、active LeadSession generation 与上述 canonical runtime subject assertion；
- writer authority 来自 active ProjectPolicyRevision 的 orchestration policy 或其授权的 immutable control-plane record，不能由 Lead、AgentInstance、LeadSession 或 genesis payload 自报；
- `lead_control_id` registry claim、project-wide runtime-subject unique active binding、active LeadSession creation 和 accepted genesis LeadCheckpoint 在同一原子 create 中成功。

LeadCheckpoint 只有经过该 writer 完成 authority、identity、exact refs、lineage tip、task ownership、runtime-subject/session binding 和 invariant 校验，并原子 create/compare-and-append 成功后才是 `accepted`。不得先接受 session-less/subject-less genesis 再回填 executor；原子操作任一部分失败都不得留下 accepted checkpoint、active session、claimed control ID 或任何可 dispatch 半状态。磁盘上存在一个文件、agent 声称写入成功、时间更新或可解析 YAML/JSON 都不构成 accepted。重复 genesis、伪 writer authority、同 ID 异内容、缺 active session/subject 或未被 registry 接纳的 checkpoint 全部 fail closed。

当前 Lead AgentInstance 与 LeadSession 只是 `lead_control_id` 的 executor。每个 active LeadSession 必须 pin provider-verified canonical `lead_runtime_subject_ref + assertion_digest`；该 subject 由 active ProjectPolicyRevision 信任的 runtime identity provider 从实际 provider/runtime identity 解析，不能由 Lead、AgentInstance ID、session payload、pane 名或环境变量自报。不同 AgentInstance ID/别名若解析到同一 canonical runtime subject，必须视为同一个 executor。

每个 `lead_control_id` 任一时刻最多一个 active LeadSession；同时，同一 project 的全部 open control lineages 中，每个 provider-verified runtime subject 任一时刻也最多绑定一个 active LeadSession。project-scoped control registry/coordinator writer 必须在 accepted checkpoint、session activate/replace 和 dispatch 前对 canonical runtime subject binding 做跨 lineage 原子 compare-and-bind/check，不能只检查当前 control 或 AgentInstance 字符串。

session replacement 或 executor/control-lineage transfer 必须先追加旧 session terminal/release event，再创建 successor；若运行时要求无间隙切换，只能使用受控 writer 的原子 compare-and-successor/transfer 操作，在同一事务中 terminal old、release old subject binding、activate/bind new session，并保存 predecessor/session/control transfer provenance。两个 active LeadSession、同一 runtime subject 同时绑定两个 control IDs、缺 predecessor/release 或非当前 session 发出的 dispatch 全部 fail closed。同一 runtime subject 可以在一个 lineage 内串行执行多个 LogicalLead，或在受控 terminal/release → successor/transfer 完成后进入另一 lineage，但不得同时 active。

## 顶层 serialized orchestration invariant

同一 `lead_control_id` 的 queue 可以持有多个 Task，但在任一时刻：

1. 最多一个 LeadSession 是 active LeadSession；
2. 该 active LeadSession 的 provider-verified runtime subject 在同一 project 的其他 open control lineages 中不得 active；
3. 最多一个 Task 是 active Task；
4. 最多一个 WorkUnit 被 selected；
5. 最多一个 `WorkUnitAttempt` 处于 non-terminal 状态；
6. implementation、review、test、research 和 release Attempt 全部共享这一限制，不得在同一 control lineage 内并行；
7. active Attempt terminal 后，必须先创建并接受一个 `LeadCheckpoint`，再选择或 dispatch 下一个 WorkUnitAttempt；
8. Task 切换也必须发生在前一 Attempt terminal 且 checkpoint 已接受之后。

因此，调度顺序是：

```text
select Task + WorkUnit in LeadCheckpoint
  -> dispatch exactly one WorkUnitAttempt
  -> append terminal Attempt event
  -> append next LeadCheckpoint
  -> select/dispatch next work
```

串行不等于由同一个 agent 或同一段对话持续执行。`AgentInstance`、`LeadSession` 和 context generation 可以按能力、独立性或上下文健康替换；保持稳定的是 `lead_control_id`，保持单线的是 authority、selection 和 decision stream。不同 `lead_control_id` 只有在 task ownership sets 不相交且 active `lead_runtime_subject_ref` sets 也不相交时才可并行；不同 project 可以独立并行。本文不施加跨 project 的全局单线程限制。

独立 review/test 的 authority 与上下文隔离仍按 ADR-003/004/005 执行。串行只规定执行顺序，不允许 implementation agent 自审，也不允许 Lead 改写 `GateEvaluation`、关闭 `Finding` 或直接写 `AggregateOutcome`。

## Task、WorkUnit 与 work graph

### Task 与 WorkUnit 的边界

一个可独立验收、可以单独关闭并对用户或产品形成完整结果的目标是 Task。同一验收目标下的主线、支线、探索、修复、独立审查、测试或 hardening 是 WorkUnit，不应为了调度便利被提升为新的 Task。

WorkUnit 的未来合同必须增加两个 exact、稳定引用：

- `parent_work_unit_ref`：引用同一 TaskRevision 下的直接父 WorkUnit；仅 root WorkUnit 可以为空；
- `depends_on_work_unit_refs`：引用必须先满足 readiness 条件的 WorkUnit 集合；root 或无依赖 WorkUnit 可以为空集合。

每个需要执行 work 的 TaskRevision 必须恰好有一个 root WorkUnit，其 `parent_work_unit_ref` 为空；其他 WorkUnit 必须沿唯一 parent chain 从该 root 可达。parent ref 表达 tree ownership；`depends_on_work_unit_refs` 只表达额外 DAG ordering，不得替代 parent 或制造第二个 root。

writer/validator 必须验证引用存在、project/task/revision 一致、root 唯一、非 root 可达、parent 无环、dependency 无环且不跨 revision，并且 dependency readiness 可由权威 lifecycle/gate facts 确定性派生。multiple root、orphan、parent/dependency cycle 或 cross-revision edge 全部 fail closed。引用不得使用自由文本名称、时间顺序或“latest”猜测。

`mainline`、`branch`、`critical path` 和 `runnable set` 都是从 TaskRevision、WorkUnit parent/dependency refs、acceptance coverage、terminal Attempt 与 gate facts 派生的 projection。它们不得作为可独立修改的阶段标签写回 WorkUnit；Orbit 不固化 `phase`、`slice`、`implementation/review/test stage` 一类调度状态来表达同一关系。

### LogicalLead 与多任务协调

现有 `LogicalLead` 继续表达 per-task continuity：一个 LogicalLead 只恢复一个 Task 的 TaskRevision、WorkUnit graph、Attempt history、Finding 与 gate 状态。同一个 Lead `AgentInstance` 可以执行多个 LogicalLead，但每个 LogicalLead/Task 在任一时刻最多属于一个 open `lead_control_id` queue，并最多被一个 accepted tip active-selected。

多任务顺序由 coordinator-level `LeadCheckpoint` 保存有序 task queue 和唯一 selection。controlled writer 必须在同一 project 的所有 open control lineages 上原子验证 Task/LogicalLead ownership disjointness 与 active runtime subject disjointness；不能只检查当前 lineage。不同 `lead_control_id` 只有在其 owned task sets 与 active executor subject sets 都 disjoint 时才可并行。

Task transfer 必须形成有序的 release/acquire provenance：旧 lineage 的 accepted checkpoint 先以 `release` 或 relinquishing `suspend` decision 移除 queue ownership 和 active selection，并确认该 Task/WorkUnit 没有 non-terminal Attempt；新 lineage 的后续 accepted checkpoint 才能以 exact old checkpoint ref、old/new `lead_control_id` 和 Task/TaskRevision refs acquire。`suspend` 在这里保留旧 lineage 历史和恢复位置，但明确 relinquish ownership；它不是让两个 queue 共同持有 Task。缺 release/suspend、acquire 抢先、引用不匹配或重复 ownership 全部 fail closed。

初版不创建宽泛的 Portfolio 平台、跨项目资源市场或新的 task 事实源；project-scoped registry 只承担 control genesis 唯一性、Task ownership 与 transfer 的最小协调约束。

## LeadCheckpoint

`LeadCheckpoint` 是 create-only、immutable record，所有记录按 `lead_control_id` 形成 append-only、线性 lineage。每个 checkpoint 必须引用 exact `predecessor_lead_checkpoint_ref`；genesis checkpoint 之外不得为空。writer 必须对该 `lead_control_id` 的当前唯一 lineage tip 执行原子 compare-and-append，并同时复核 project-scoped Task ownership。缺 predecessor、引用非 tip、出现 fork 或多个有效 tip 时全部 fail closed，不得按时间或文件名选择“最新”分支。

每个 LeadCheckpoint 至少保存：

- exact `project_id`、`lead_control_id`、active ProjectPolicyRevision/orchestration policy ref+digest、Lead AgentInstance、唯一 active LeadSession generation、provider-verified canonical `lead_runtime_subject_ref + assertion_digest` 与相关 LogicalLead refs；
- 有序 task queue 中每个 Task/TaskRevision 的 exact refs；
- 唯一 active Task、selected WorkUnit 和当前/刚 terminal WorkUnitAttempt 的 exact refs，允许的空值必须与 lifecycle 一致；
- task queue、active mainline、work graph branches、current attempt 四层 assessment；
- LeadControl/受控 writer 产生的 versioned failure/finding fingerprint、`fingerprint_identity_basis`/digest，以及与 hash domain 分离的 `fingerprint_supporting_provenance`/ordered prior Attempt chain；
- Delivery Progress 与 Assurance Progress 的前值、当前值、delta、依据 refs 和判断 provenance；
- 本轮 `LeadDecision`、理由、授权来源与是否需要 user authorization；
- next trigger，包括 event trigger 或 `checkpoint_due` 的原因、有限 fallback deadline 与其 exact policy/authorization record ID+digest。

LeadCheckpoint 只保存选择、assessment、delta、decision 和用于恢复的 exact refs。它不得复制 `TaskRevision.goal`、WorkUnit body、EvidenceRecord 内容、GateEvaluation verdict、Finding closure 或 AggregateOutcome；这些事实仍由原权威对象拥有。projection 可以从 checkpoint 和权威 facts 重建，但 checkpoint 不能成为 task/evidence/gate truth 的第二来源。

## WorkUnitAttempt 继任与 dispatch 绑定

`WorkUnitAttempt` 的未来合同必须增加：

- exact `predecessor_work_unit_attempt_ref`；仅 WorkUnit 的第一个 Attempt 可以为空；
- exact `dispatch_lead_checkpoint_ref`，引用授权本次 Task/WorkUnit selection 和 dispatch 的已接受 LeadCheckpoint。

successor Attempt 只有在 predecessor 已 terminal、dispatch checkpoint 是该 `lead_control_id` 的当前唯一 accepted tip、checkpoint 选择的 Task/WorkUnit 与 Attempt 完全一致、依赖已 ready，且该 control lineage 没有其他 non-terminal Attempt 时才可创建和 dispatch。Attempt 还必须 pin 与 checkpoint 相同的 exact `lead_control_id`。predecessor、checkpoint、control identity 或 selection 任一缺失/不一致都必须 fail closed。

作为 coordinator/ownership facts 损坏时的 fail-closed backstop，authoritative Attempt writer/validator 还必须跨同一 project 的全部 control lineages 强制：每个 Task 任一时刻最多一个 non-terminal WorkUnitAttempt，每个 WorkUnit 任一时刻最多一个 non-terminal WorkUnitAttempt。该全局 cardinality 不依赖 queue projection、checkpoint tip 或 `lead_control_id` 声明是否健康；冲突时不得接受任何新 Attempt 或 dispatch。

Attempt 的 terminal event 不自动授权 successor。`terminal Attempt -> LeadCheckpoint -> successor dispatch` 是不可跳过的控制边界。replacement、retry、context rebuild、thesis revision change、review 和 test 都适用同一规则。

## LeadControl 深模块

`LeadControl` 是围绕权威 facts 的单一深模块。其核心 interface 固定为：

```text
reconcile(authoritative_facts, trigger) -> LeadDecision
```

调用方提供已验证、带 exact refs 的 authoritative facts 和一个 trigger；LeadControl 返回确定的 `LeadDecision`，由受控 writer 将其记录到 LeadCheckpoint 并据此执行一个允许的控制动作。输入不完整、lineage fork、事实相互矛盾或无法证明唯一 selection 时，结果必须是 freeze/fail-closed decision，而不是猜测。

scheduler、anomaly detection、self-check、wall-clock fallback 和 portfolio/task-queue projection 只能作为 LeadControl 内部 seam。不得把它们拆成各自拥有 selection、priority、progress 或 lifecycle truth 的平级平台。

LeadControl 不拥有也不改写：

- `TaskRevision.goal` 或 acceptance contract；
- EvidenceRecord 或 evidence truth；
- `GateEvaluation` verdict；
- `Finding` closure / `FindingResolution` authority；
- Gate Engine 派生的 `AggregateOutcome`。

LeadDecision 只能在这些事实之上决定 queue、selection、dispatch、replan、split、switch、freeze 或 escalation，不能代替原 authority 产生事实。

## 四层自检与触发

每次 reconcile 必须分别评估：

1. **task queue**：优先级、active Task 唯一性、等待原因和切换资格；
2. **active mainline**：当前用户路径/acceptance、主阻塞点、Delivery Progress 与偏离风险；
3. **work graph branches**：parent/dependency readiness、支线收益、critical path、未闭合 branch 与 hardening 是否抢占主线；
4. **current attempt**：agent/context/thesis/scope/verification plan、failure/finding fingerprint、Assurance Progress、blast radius 和 review surface。

自检由事件驱动，至少在以下时点运行：dispatch 前、Attempt terminal 后、successor 创建前、ChangeThesis 变化、scope 变化、Finding/GateEvaluation/FindingResolution 变化、TaskRevision 变化、LeadSession/context generation 变化，以及 authority 或 dependency readiness 变化。

未来合同必须从 exact active ProjectPolicyRevision 的 orchestration policy，或由该 policy 授权的 create-only immutable `AuthorizationRecord`，解析有限、非零的 wall-clock fallback interval 与上界。LeadCheckpoint 必须 pin 实际使用的 policy/record stable ID 与 content digest。普通可覆盖 project config、Lead/agent 自填 interval 或未绑定 policy 的环境值没有 authority；policy rotation、record supersession 或 digest drift 后，旧 fallback 立即 stale，reconcile 必须 fail closed/要求新 checkpoint，不得继续沿用旧 timer。

wall-clock fallback 用于处理没有预期事件或外部状态长期不返回的情形。timer 到期只能产生 `checkpoint_due` trigger；timer 不得直接选择 Task、改 priority、终结 Attempt、创建 successor 或改变 gate/task 状态。具体时长是 policy，不是通用 correctness 常量。本文只冻结 authority seam 与验证语义，不提前修改 schema。

## Delivery Progress 与 Assurance Progress

LeadCheckpoint 必须区分两类进度：

- **Delivery Progress**：acceptance 达成、用户路径前进、核心 blocker 消除、可交付 output 形成；
- **Assurance Progress**：test/validator 覆盖、evidence 完整性、invariant 验证、风险认识与审查确信增加。

两者都需要 exact supporting refs 与分层 assessment，但不得用 test 数、字段数、validator 分支、diff 行数或轮数本身替代语义判断。Assurance Progress 可以提高交付可信度，却不能冒充 Delivery Progress。

当 Assurance 持续增长而 Delivery 不动时，LeadControl 必须 freeze automatic continuation 并重新判断目标、主阻塞点和最小充分机制。额外 hardening 应创建不抢占主线的新 WorkUnit，受 parent/dependency 与 queue selection 控制；除非它成为已证明的 acceptance/core blocker，否则不得自动成为 active mainline。

## 止损与异常控制

round/attempt count 是 safety fuse，不是唯一异常判据，也不是 correctness 证明：

1. 首轮无 Delivery delta 时，只有 ChangeThesis、agent/context、scope 或 verification plan 至少一项发生有证据的实质变化，LeadControl 才可以授权 successor；否则必须 replan、split、switch、freeze 或 escalate。
2. 连续两轮无 Delivery delta 后，automatic continue 必须被禁止。下一决策只能是 replan、split、switch、freeze 或 escalate，不能以更多 Assurance work、同方案小改或新对话包装成自动继续。
3. 同一 failure/finding fingerprint 的第三次 Attempt 必须绑定 provider-verified、create-only immutable `AuthorizationRecord`。其 semantic action 固定为 `task.retry.override`，`scope_digest` 必须 canonical exact bind `project_id`、TaskRevision ref、WorkUnit ref、规范化 failure/finding fingerprint、ordered prior Attempt ref+digest chain、authorizing LeadCheckpoint ref 和 `lead_control_id`。issuer 必须来自 active ProjectPolicyRevision 信任的 user/control-plane provider；Lead/agent 自报、自由文本/opaque ref、跨 fingerprint/Task/WorkUnit replay、已消费 record 重放或 scope/digest 不匹配均无效。没有该授权不得 dispatch 第三次 Attempt。

### Failure/finding fingerprint authority

agent-submitted string 不具有 failure/finding fingerprint authority。WorkUnitAttempt terminal 后，LeadControl/受控 writer 只能从稳定语义 identity 确定性计算 fingerprint，并以权威 supporting provenance 验证该 identity；两者记录在下一个 accepted LeadCheckpoint，但必须属于以下两个互不混入的集合。

`fingerprint_identity_basis` 是唯一进入 fingerprint hash domain 的输入，只能包含：

- stable `fingerprint_canonicalization_version`；
- TaskRevision/WorkUnit stable scope identity；
- typed failure category/code；
- Finding failure 的 stable Finding identity；或
- 非 Finding failure 的 stable test/rule/check identity、stable signal subject identity 与 normalized failure code。

`fingerprint_canonicalization_version` 必须冻结 identity input domain、typed category/code encoding、stable identity representation、set/list 的 deterministic ordering/deduplication 和 fingerprint hash domain；unknown version fail closed。Finding 存在时必须复用其 stable identity，不能把新的 GateEvaluation 当成新的 failure identity。非 Finding failure 的 test/rule/check ID 与 signal subject ID 必须来自稳定合同/权威定义，不能使用某次 outcome record 的 identity。

`lead_control_id`、WorkUnitAttempt ID/ref/digest、LeadCheckpoint ID、LeadSession、AgentInstance、Finding/GateEvaluation/test/validator outcome record ID/ref/digest、日志或异常 message wording、path/文件名及呈现顺序都不得进入 fingerprint identity hash。相同 `fingerprint_identity_basis` 在任何 retry、checkpoint、session、AgentInstance 或 control transfer 后必须得到相同 fingerprint；typed category/code、stable Finding identity、stable test/rule/check identity 或 stable signal subject identity 任一不同则必须得到不同 fingerprint。

`fingerprint_supporting_provenance` 只证明当前 occurrence 支持上述 identity basis，不参与 fingerprint hash。它必须保存 exact terminal WorkUnitAttempt ref+digest、当前 Finding/GateEvaluation/test/validator outcome refs+digests、authoring LeadCheckpoint ref，以及该 fingerprint 的 ordered prior Attempt ref+digest chain 和跨 checkpoint/Task transfer lineage continuity。controlled writer 必须验证 provenance 中的 typed result、stable signal/Finding identity、scope 和 digests 与 `fingerprint_identity_basis` 一致。

controlled writer 必须跨 accepted checkpoints 检查 prior chain；Task 在 control lineage 间 transfer 时还必须沿 release/acquire provenance 连续计数。prior chain 用于 occurrence 计数并进入 `task.retry.override` AuthorizationRecord scope，但不改变 fingerprint 本身。不能通过新 Attempt/outcome record/checkpoint、不同 outcome digest、新 `lead_control_id`、session/context/AgentInstance replacement 或重排 provenance refs 重置相同 failure。若缺稳定 Finding/test/rule/check/signal subject identity、权威 supporting ref/digest、canonicalization version 未知、identity basis 不可复算、provenance 不支持 basis、prior chain 有缺口或不能证明新旧 failure identity 是否相同，LeadControl 必须 freeze/escalate，不能自动把它当成一个新的 fingerprint。

即使尚未达到上述 fuse，以下情况也必须立即 freeze：scope 或 blast radius 超出当前 authority/已证明问题面；review surface 已无法完整覆盖；局部工作与 `TaskRevision.goal`/acceptance 的关系无法证明；权威 facts、checkpoint lineage、selection 或 dependency readiness 出现矛盾；Work Agent 试图建立未授权控制路径。

## 单一 writer 与 control authority

LeadControl/受控 coordinator writer 是每个 `lead_control_id` 中 task queue、priority、active Task、selected WorkUnit、checkpoint lineage 和 dispatch decision 的唯一写入路径；project-scoped registry writer 是 genesis 唯一性、跨 lineage Task ownership/transfer、canonical runtime subject active-session binding 与全局 Attempt backstop 的受控写入边界。checkpoint acceptance、session activate/replace 和 dispatch 必须经过同一 registry 的原子跨 lineage subject check。

Work Agent 可以报告 Finding、提出 WorkUnit/scope/replan 请求并提交本 Attempt 的授权输出，但不得：

- 自行创建或 dispatch child WorkUnit/WorkUnitAttempt；
- 修改 task queue、priority、active Task 或 selected WorkUnit；
- 终结其他 Attempt、授权 successor 或绕过 LeadCheckpoint；
- 因局部失败扩大 `TaskRevision.goal` 或改写 gate authority。

Task switch 只能在当前 Attempt terminal 且新 LeadCheckpoint 已接受后发生。Gate authority、evaluator independence、FindingResolution authority 与 AggregateOutcome ownership 保持 ADR-003/004/005 的既有边界。

## Normative acceptance 与 negative scenarios

实现至少必须以 writer、validator、projection 和 E2E/negative test 证明以下场景：

1. **control identity/genesis**：trusted provider 先解析 canonical runtime subject；受控 writer 再以一个原子操作 claim `lead_control_id`、bind unique active LeadSession/runtime subject 并创建 project/policy/writer-bound accepted genesis。第二 genesis、伪 writer、session-less/subject-less accepted genesis、半状态或 AgentInstance/LeadSession replacement 后换 control ID 绕过 fuse 均被拒绝。
2. **multi-task single-active**：一个 control lineage 持有多个 Task 时，只有一个 active LeadSession、一个 active Task、一个 selected WorkUnit 和最多一个 non-terminal Attempt。
3. **disjoint parallelism/transfer**：不同 `lead_control_id` 只有 task sets 与 active provider-verified runtime subject sets 都 disjoint 时可并行；同一 Task/LogicalLead 双 queue ownership/双 tip selection 或同一 runtime subject 双 control binding 被拒绝。Task transfer 必须 old release/suspend checkpoint 在先、new acquire checkpoint 在后；executor transfer 必须 old session terminal/release 在先、new session successor/bind 在后，并保留 exact provenance；不同 project 独立。
4. **global Attempt backstop**：即使 registry/checkpoint/queue facts 损坏，同一 Task 或同一 WorkUnit 的第二个 non-terminal Attempt 仍被全局 writer/validator 拒绝。
5. **single active LeadSession/executor**：同一 `lead_control_id` 双 active session、同一 provider/runtime subject 以相同或不同 AgentInstance ID 同时绑定两个 control IDs、别名 subject 绕过、非当前 session dispatch、无 terminal/release predecessor 的 replacement/transfer 均被拒绝；受控 atomic session successor/transfer 可在不并发 active 的前提下复用 executor。
6. **work graph root/readiness**：multiple root、orphan、parent/dependency cross-revision/cycle 或 dependency 未 ready 时不得选择/dispatch WorkUnit；唯一 root reachability 与 runnable set 可重建。
7. **no switch with active attempt**：任一 Attempt non-terminal 时不得切换 Task。
8. **checkpoint-before-successor**：没有 terminal predecessor 或没有同 `lead_control_id` 授权 dispatch 的当前 accepted LeadCheckpoint，不得创建/dispatch successor。
9. **two zero-delivery attempts**：连续两轮 Delivery delta 为零时 automatic continue 被阻塞。
10. **third same fingerprint**：fingerprint 必须由 LeadControl/受控 writer 按 canonical version 从 `fingerprint_identity_basis` 产生，并把 per-occurrence refs/digests 另存为不参与 hash 的 `fingerprint_supporting_provenance`。不同 Attempt、checkpoint、outcome record ID/digest 但相同 stable test/check signal 必须得到同一 fingerprint；stable Finding identity 相同而 GateEvaluation ref 更新时也必须相同；typed code 或 stable Finding/test/check/signal subject identity 不同则必须不同。rename/reorder/message wording/AgentInstance alias 不改变 identity；跨 checkpoint/transfer prior chain 必须连续且只用于计数/authorization scope。缺稳定 signal identity 或 provenance 不能支持 basis 时 freeze。第三次相同 fingerprint 缺 provider-verified `task.retry.override` AuthorizationRecord、exact scope binding、user/control-plane issuer 或尝试 replay 时被拒绝。
11. **assurance-only freeze**：Assurance 持续增长、Delivery 不动时进入 freeze/replan，而不是继续堆 test/validator/evidence。
12. **hardening does not preempt**：非 acceptance/core blocker 的 hardening 进入新 WorkUnit，不能自动抢占 active mainline。
13. **checkpoint recovery**：LeadSession/AgentInstance 替换后，可沿同一 `lead_control_id` 从 authoritative facts 和唯一 checkpoint tip 恢复 queue/selection/decision；缺 runtime subject assertion、同 subject 跨 lineage 双 active、双 active session 或 lineage fork 时 fail closed。
14. **policy-bound fallback**：fallback 缺 active policy/immutable authorized record、checkpoint 未 pin exact ID/digest、mutable config drift 或 stale digest 时 fail closed；timer 仍只能产生 `checkpoint_due`。
15. **review/test serialized**：同一 control lineage 的 implementation non-terminal 时不得并行启动 review/test；review terminal + checkpoint 后才能 dispatch test 或下一 implementation，同时 evaluator independence 仍满足。
16. **single writer**：Work Agent 直接创建 child Attempt、改 queue/priority/selection 或绕过 checkpoint 的写入被拒绝。
17. **immediate anomaly freeze**：scope、blast radius、review surface 或 goal relation 失控时，即使未达到 round fuse 也立即 freeze。

验收不能只搜索字段是否存在。必须验证并发竞争、compare-and-append、fork、恢复、stale refs、越权 writer 和事件顺序；需要判断 Delivery/Assurance、thesis 或 proportionality 的场景则必须保留 decision rationale 与 supporting refs，不能声称 schema validator 已证明其语义正确。

## Non-goals

初版明确不包含：

- Task 内部并行或同一 `lead_control_id` 的并行 WorkUnitAttempt；
- graph database、GraphRAG 或新的 relationship 事实源；
- task/evidence/gate/checkpoint 之外的第二事实源；
- 宽泛 Portfolio 平台、跨项目资源优化或通用 scheduler 产品；
- 继续扩大 Evidence/Validator substrate 来代替控制合同；
- 用固定 line count、token count、round count 或自由文本 checklist 充当 correctness；
- 改变 ADR-003/004/005 已冻结的 gate authority、independence、Finding closure 或 AggregateOutcome ownership。

在本文控制合同及其 Slice 1/2 implementation design 冻结前，Orbit v2 不继续扩大 Evidence/Validator substrate，也不进入 runtime 实现。下一步只允许补齐本 ADR 所要求的 exact refs、single-active validator、LeadCheckpoint/LeadControl 合同与对应验收设计。

## 后果

- `lead_control_id` 让 authority/decision stream 可跨 AgentInstance、LeadSession 和 context replacement 恢复，同时保持单线、可审计。
- 串行执行降低吞吐上限，但消除同一 control lineage 内 selection、thesis、review surface 和 task switching 的竞态；需要并行时必须使用 task sets 与 active provider-verified runtime subjects 都 disjoint 的独立 `lead_control_id`，或使用独立 project，而不是复制 Task ownership 或给同一 executor 起别名绕过本 invariant。
- WorkUnit graph 能表达主线/支线/依赖而不固化阶段标签，也不要求图数据库。
- checkpoint 增加了持久化和 validator 成本，但为 terminal-to-dispatch、异常止损和恢复连续性提供单一控制证据。
- round fuse 提供保守止损，不替代 goal relation、scope、blast radius、review surface 和 progress 的持续判断。

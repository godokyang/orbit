# Orbit v2 Agent-Independent Control Amendments

- 状态：**Integrated / historical design source**（owner 于 2026-08-11 批准并完成 docs-only normative integration）
- 日期：2026-08-11
- 性质：本文是设计来源与历史记录。**只有 [ADR-003](../adr/003-lead-orchestrated-dynamic-agent-team.md)、[ADR-004](../adr/004-role-rule-context-evidence-binding.md)、[ADR-005](../adr/005-orbit-v2-clean-cut-and-legacy-retirement.md)、[ADR-006](../adr/006-serialized-lead-orchestration-control-loop.md) 是 normative semantic source**（本稿条款已整合进上述 ADR）；[v2 交付记录](./v2-delivery-record.md) 是 **non-normative implementation/delivery/acceptance mapping，不得覆盖 ADR**；本文仅 provenance。**明确尚未实现**——不授权任何实现，schema/lib/tests/runtime 修改仍须按 plan 切片逐一批准。
- 关联文档：[ADR-003](../adr/003-lead-orchestrated-dynamic-agent-team.md)、[ADR-004](../adr/004-role-rule-context-evidence-binding.md)、[ADR-005](../adr/005-orbit-v2-clean-cut-and-legacy-retirement.md)、[ADR-006](../adr/006-serialized-lead-orchestration-control-loop.md)、[v2 交付记录](./v2-delivery-record.md)、[alpha 测试发现](../reference/alpha-test-findings.md)、[测试爆炸事故](../reference/test-explosion-case.md)、[AGENTS.md](../../AGENTS.md)（仓库根）
- 背景：Slice 1 implementation design proposal（WorkUnit parent/dependency refs、Attempt lineage、single-active validator；待 owner 审核，本文不改变其范围）

> **修订提示（2026-08-17）**：本文引用的 ADR-003/005/006 并行边界条款已按 task-centric 模型修订（一个 Task = 一个 task_id = 一个 Git branch/worktree；串行边界收窄为 per Task；不存在 cross-control transfer 与 project-wide Task ownership registry）。详见各 ADR 文末修订记录。本文其余内容为历史设计记录，不因本提示修改。

## 0. 本稿解决的问题与术语约定

Alpha 测试（[alpha 测试发现](../reference/alpha-test-findings.md)十项）暴露的核心模式：**控制循环依赖 agent 自报与对话上下文，缺少与具体 agent 无关的权威边界**。本稿把"审核标准移动、测试数量爆炸、补丁链失控、软判断冒充正确性"等现象归因于同一缺口，并给出最小 amendment 设计。

术语与既有文档一致：

- `closure_basis_digest`（新）：一次 dispatch 时冻结的完成标准摘要（§4）；
- `effective_verification_plan_digest`（新）：从 policy + TaskRevision/EvidenceRequirements + RuleResolution + 完整 ordered `effective_budget_bindings` + 预先存在的 override AuthorizationRecord 确定性派生的验证计划摘要（§8）；先派生本 digest，再纳入 `closure_basis_digest`——单向依赖链，无 digest 循环；plan/basis digest 始终是 checkpoint 正文字段并被最终 checkpoint identity/content digest 覆盖，`budget_adjustment_digest` iff present 同为正文字段并受覆盖；
- `budget_adjustment_digest`（新）：`test.budget.adjust` typed payload 的独立 canonical digest，预像排除 enclosing checkpoint ID/content digest（§7-2、§8-2）；
- `effective_budget_bindings`（新）：每个 dispatch checkpoint 固定保存的两项 canonical 预算绑定（`work_unit_lineage`/`task_lineage` 各一项，固定顺序；§7-5、§8）；
- `verification_class`（新）：EvidenceRequirement 的验证类型（§6，regression/release_audit/acceptance_evidence 互斥）；
- `test.budget.adjust` / `test.budget.override`（新）：预算调整的两种受控动作（§7）；
- `needs_user`（新）：bounded runner 的一个停止状态（§10）；
- Finding basis（新）：Finding 的类型化基础（§5）；
- 其余对象（`TaskRevision`、`WorkUnit`、`WorkUnitAttempt`、`LeadCheckpoint`、`LeadControl`、`GateRequirement`/`GateEvaluation`、`Finding`/`FindingResolution`、`ProjectPolicyRevision`、`AuthorizationRecord`、`RuleResolutionArtifact`、`lead_control_id`）沿用 ADR-003/004/005/006 定义。

## 1. 现有十项问题状态矩阵

列含义：**设计覆盖** = 已接受 ADR/plan 是否提出机制；**runtime 实现** = HEAD 74eae48 的代码是否已实现（v2 未 cutover，Slice 0 合同/validator 已冻结，Slice 1 待批）。

| # | 问题（alpha） | 设计覆盖 | runtime 实现 | 本 amendment 增量 | 落地 slice |
|---|-------------|---------|-------------|------------------|-----------|
| 1 | 修复链路跑偏 | ADR-003 决策三/六（LogicalLead、bounded WorkUnit）、ADR-006（goal relation freeze、checkpoint-before-dispatch） | 未实现（Slice 1/2 未落地） | `closure_basis_digest` + Finding basis：局部问题只能成为 Finding，不能移动本 Attempt 完成标准 | 2、4 |
| 2 | 过程命名代码入正式目录 | ADR-003 决策一（无词表，上下文代码健康判断）、决策八（production change surface 完整性审查） | 仅 v1 文档规则，无 v2 机制 | §9 治理分层：语义审查归 independent reviewer，机械部分归 validator；不建 style judge | 4、5 |
| 3 | 多任务编排 | ADR-006 task queue / unique selection / single-active | 未实现（Slice 2） | bounded runner 停止状态、每 dispatch 冻结独立 `closure_basis_digest` | 2 |
| 4 | 任务异常评判 | ADR-006 止损（round fuse、零 Delivery delta、fingerprint、retry override、立即 freeze） | 未实现（Slice 2） | §11 continuation envelope：把"何时换策略"的判据机制化，软调整不打扰用户 | 2 |
| 5 | 过度设计/底座膨胀 | ADR-006 non-goals（不扩大 Evidence/Validator substrate）、plan 切片冻结 | Slice 0 已冻结；Slice 1 proposal 已声明不扩底座 | §7 预算 ceiling + override 封顶；超 ceiling 无 override → needs_user（不冻结） | 2 |
| 6 | Lead 自检 | ADR-006 四层自检 + event triggers | 未实现（Slice 2） | runner 每步 `reconcile` 强制四层评估写入 checkpoint | 2 |
| 7 | 拖轮次/审核标准移动 | plan 与 AGENTS.md 的"验收标准冻结"是客户端纪律，无产品机制 | 无产品机制 | `closure_basis_digest` 冻结完成标准；Finding 只能引用 basis；新标准 = 新 TaskRevision + 新 dispatch | 2、4 |
| 8 | 审核边界失误（动态数据/验收证据/永久测试混同） | ADR-004（evidence 与 gate 分离）、AGENTS.md 动态数据规则 | Slice 0 有 `record_kind`，无验证类型分类 | §6 `verification_class`：regression / release_audit / acceptance_evidence | 3 |
| 9 | 补丁链失控/复审范围扩大 | ADR-006（scope/blast radius freeze、连续零 Delivery、checkpoint-before-successor）、AGENTS.md 防循环修复 | 未实现 | §12 recovery 不补造正文/证据；§10 runner 停止状态；复审范围受 budget 与 closure basis 约束 | 2 |
| 10 | 测试数量爆炸 | AGENTS.md 硬限制（客户端提示，非产品 authority） | 无产品强制 | §7 跨 Agent test budget：policy default / Lead ceiling / user override，按 lineage 累计，trusted 计数 | 2 |

结论：十项问题全部有设计方向，但除 Slice 0 合同外**没有任何一项被 runtime 强制**；本 amendment 是把 alpha 归纳的边界纪律产品化为 agent-independent 控制契约。

## 2. 设计原则

1. **strict serial 不变**：ADR-006 的 single-active（每 `lead_control_id` 最多一个 active Task/selected WorkUnit/non-terminal Attempt）、terminal → accepted LeadCheckpoint → successor dispatch、project-wide Attempt backstop 全部保留，本 amendment 不放松、不并行化。
   > **已取代（2026-08-17）**：本条中「每 `lead_control_id` 最多一个 active Task」的多 Task 前提与「project-wide Attempt backstop」的 project-wide 定性已按 task-centric 模型修订——control 收窄为 Task-scoped，backstop 收窄为 Task-local；single-active 与 checkpoint-before-dispatch 语义保留（见 ADR-006 修订记录）。
2. **agent-independent**：控制事实（selection、budget、closure basis、fingerprint、continuation 授权）只从权威记录（TaskRevision、WorkUnitAttempt、LeadCheckpoint、Finding、AuthorizationRecord、RuleResolutionArtifact）派生；agent 自报、对话内容、pane/进程身份不产生控制事实。
3. **用户定义边界**：goal、non-goals、risk acceptance、policy（含预算 default/ceiling）与 override 由 user/control-plane 定义；Lead 在边界内自治。
4. **Lead 在 delegation envelope 内自主判断**：envelope = active ProjectPolicyRevision + closure basis + budget ceiling + authority scope。envelope 内的一切决策（agent 选择、budget adjust、继续/暂停、attempt 顺序）由 Lead 判断并写入 checkpoint，不询问用户。
5. **只有硬越界/目标变化/风险接受才 needs_user**：软判断（ceiling 内收紧预算、换 agent、replan 提议）不触发用户；只有超出 ceiling、改变 goal、接受未授权风险、protected 变更需要 user/control-plane。
6. **软判断不能伪装成 validator correctness**：validator 只机械证明 refs/digest/cardinality/provenance 成立；proportionality、quality、thesis 可信度、budget 合理性由 Lead/reviewer/user 判断并留 provenance。"validator 通过"不等于"方案正确"。

## 3. Lead delegation 权限矩阵

依据 ADR-003 权威表与 ADR-006 单一 writer；"能决定"仅指可留 provenance 的受控动作。

| 主体 | 知道什么（可读输入） | 能决定什么（受控动作） | 不能决定什么（硬边界） |
|------|--------------------|----------------------|----------------------|
| Logical Lead | 全部权威事实与 projection：goal、work graph、attempt history、checkpoint lineage、Finding/gate 状态、剩余风险 | 在 envelope 内：task queue 提议、WorkUnit 创建/拆解、agent 创建/替换/终止、budget adjust（ceiling 内）、closure basis 组成、replan/split/switch/freeze/escalate 决策；提议 TaskRevision（受 protected lineage 约束） | 改写 `TaskRevision.goal`、签发 evaluator verdict、确认/反驳 Finding、关闭独立 gate、单方 waive required gate、写 AggregateOutcome、越 ceiling 预算、无授权改变控制身份 |
| implementation agent | 当前 Attempt 的 closure basis、authority scope、assigned rules、change thesis、输入 refs | 当前 WorkUnit 授权快照内的执行；提交 implementation EvidenceRecord（只能提出 `addressed`） | 修改 goal/acceptance；创建/dispatch child attempt；改 queue/priority/selection；扩大 scope；决定 blocking 语义 |
| test agent | 同 implementation + `effective_verification_plan_digest` 及其 source refs（§8） | 当前 test Attempt 内执行；提交 test evidence（submission provenance） | 把动态数据固化为永久测试（§6）；自报预算计数；签发 verdict |
| reviewer（independent） | task contract、closure basis、被审 surface、相关 evidence、产品上下文（不继承作者 transcript） | 独立 GateEvaluation verdict/answers、Finding（含 basis）、`disproved` 提议 | 改写 goal；替代实现者改生产代码；移动本 Attempt 的 closure basis；自评或评自己参与的工作 |
| release agent | closure basis、gate/finding 状态、发布范围 | 当前 release Attempt 内执行；release evidence | 关闭未满足的 gate；绕过 Finding |
| writer（受控） | 被授权写入的权威对象 schema | 原子 append checkpoint、create attempt/evidence/finding、更新 policy lineage（policy authority 授权时） | 创造语义结论（budget 合理性、verdict、finding 语义）；跳过校验 |
| validator | bundle 内全部权威对象 | 机械校验并 fail closed；派生 closure/stale/roster/budget 记账 projection | 判断方案好坏、预算是否"合理"、风险是否可接受 |
| user / control-plane | 全局目标、policy、风险全貌 | 定义 policy（budget default/ceiling、blocking 派生规则）；签发 override（budget/retry）；risk acceptance；goal 变更；protected 变更批准 | 不需要也不能代替 reviewer 的独立证据采集 |

## 4. closure_basis_digest：dispatch 时冻结完成标准

**问题**：alpha #7——审核标准不断移动，每轮追加证明要求，十几轮不闭合。

**设计**：每次 dispatch 授权时（accepted LeadCheckpoint，Slice 2 交付），受控 writer 计算并保存 `closure_basis_digest`，其 hash domain 只包含 dispatch 时点的 exact refs + digests：

- `TaskRevision` ref+digest（goal、non_goals、quality outcome、acceptance、evidence_requirements、GateRequirements、task questions）；
- `WorkUnit` ref+digest（objective、scope、authority_scope、stop_conditions、acceptance_refs）；
- 本 Attempt 的 `change_thesis_ref`（id + revision + digest）；
- 本 Attempt 的 assigned `RuleResolutionArtifact` ref；
- `effective_verification_plan_digest`（派生值，§8 派生链：adjust payload digest → plan digest → 本 digest，单向无循环；本 digest 不进入 `effective_verification_plan_digest` 的 hash domain）；
- 排除：attempt/agent/session 身份、时间、对话内容（与 ADR-006 fingerprint hash domain 分离原则一致）。

**语义**：

- 同一 Attempt 的完成标准 = 其 dispatch checkpoint 冻结的 basis；reviewer 发现真问题只能走 Finding（§5），**不能移动同一 Attempt 的完成标准**。
- **完成标准变化分级**：acceptance/evidence/gate 完成标准变化**必须**是 authorized `TaskRevision`/`GateRequirement` revision（protected lineage 校验，ADR-003/005）；仅 thesis revision、scope 或 verification-plan 变化可产生 successor basis（旧 Attempt terminal → 新 accepted LeadCheckpoint → 新 basis 的 successor dispatch），但**不得借此改写 TaskRevision 完成标准**——acceptance/evidence requirement/GateRequirement 集合不变时，新 basis 必须与旧 basis 共享同一 TaskRevision 完成标准引用。
- 旧 Attempt 的 evidence 与 verdict 按原 basis 解释，不 latest-wins。
- `closure_basis_digest` 是 checkpoint 字段（引用 TaskRevision/WorkUnit 等权威 refs），不复制 task/evidence/gate truth（ADR-006 checkpoint 约束），不成为第二事实源。

## 5. Finding basis 与 blocking 派生

**问题**：alpha #1/#9——局部发现被当成主线目标，或复审范围无限扩大；同时"是否阻塞"依赖对话判断。

**设计**：Finding 增加类型化 basis（create-only，随 Finding 写入），枚举：

- `contract_violation`：偏离 dispatch 时冻结的 `closure_basis_digest`（acceptance/requirement/gate 未满足）；
- `regression`：稳定程序规则被破坏（对应 §6 `verification_class: regression` 的反例）；
- `newly_discovered_risk`：basis 之外新发现、真实影响用户/业务/系统稳定性的风险；
- `hardening_opportunity`：非 acceptance/core blocker 的加固机会。

**blocking 派生**（机械，与 basis/policy 一致，agent 自由文本无效）：

- `contract_violation`、`regression`：默认 blocking（policy 可规定最低强度，不得低于 active ProjectPolicyRevision 的 GateRequirement minimum）；
- `newly_discovered_risk`：blocking 与否由 policy/risk owner 裁决；Lead 默认不能单方 waive required independent gate（ADR-003），若裁决 blocking 且无法 `addressed/disproved` → `needs_user`（risk acceptance）；
- `hardening_opportunity`：默认**不阻塞**；进入新 WorkUnit，受 parent/dependency 与 queue selection 控制，不得抢占 active mainline（ADR-006 hardening 规则）。

Gate Engine 只按 policy 映射派生 blocking 并聚合 closure；`FindingResolution` authority（addressed/disproved/waived）不变。

## 6. EvidenceRequirement verification_class

**问题**：alpha #8——把一次性验收扩成永久测试、把动态数据当稳定契约、把截图当门禁。

**设计**：`EvidenceRequirement`（TaskRevision 拥有）增加 `verification_class` 枚举，dispatch 时随 closure basis 冻结。三类**互斥**：

- `regression`：稳定程序规则（合成 fixture 可复现）→ 永久自动化测试，进测试套件；
- `release_audit`：**动态/时效性数据与发布时检查**（当前数据质量、本轮价格/公司清单、动态快照）→ 发布审计记录，**不成为永久测试**（换一轮数据即失效的事实不能固化断言）；
- `acceptance_evidence`：**本任务一次性 URL/截图/人工复验**（"这次修好了"的证据）→ 绑定 Attempt 的 EvidenceRecord，证明本次交付，不承担未来防回归。

边界规则（机械 + Lead/reviewer 判断分层）：

- **validator 只校验结构化 class 与证据用途兼容性**：机械兼容依据固定的最小结构化字段——`EvidenceRecord.implementation_check.evidence_requirement_results[].verification_use`（docs 设计，Slice 3 实现；**非 EvidenceRecord 顶层**），枚举 `permanent_test_evidence`（配 `regression`）、`audit_record_evidence`（配 `release_audit`）、`acceptance_proof_evidence`（配 `acceptance_evidence`）。validator 按该 result 的 `evidence_requirement_id` 解析 TaskRevision requirement 的 `verification_class`，校验 **exact class/use 配对**，并校验该 result 的 evidence_refs 解析到**兼容的 ArtifactClaim.kind**（`permanent_test_evidence` → `verification`；`audit_record_evidence`/`acceptance_proof_evidence` → `report`）。**不解析、不判断自由文本里的动态数据或稳定 signal**——文本语义不进入机械校验。单个 record 可按不同 result 同时满足不同 verification_class。缺 use、未知 use、错配、引用不兼容 claim kind 全部 fail closed；
- Lead/reviewer 语义判断：某事实属于哪一类（稳定规则 vs 数据快照 vs 一次性复现），**分类语义由 Lead/reviewer 留 provenance**（AGENTS.md"加测试前三问"产品化：稳定规则？换轮数据仍成立？由测试/审计/人工承担？），validator 不替它们做分类。

## 7. 跨 Agent test budget

**问题**：alpha #5/#10——测试数量爆炸、换 agent/对话即重置、自报计数不可信。

**设计**：

1. **ProjectPolicyRevision default**：active policy 定义预算（repo default：每 (TaskRevision, WorkUnit) lineage 累计新增测试 ≤ 10 个、新增测试代码 ≤ 300 行；policy 可配置）。default 是政策，不是 schema correctness 常量（§16）。
2. **Lead adjustment（`test.budget.adjust` typed payload）**：policy 定义 ceiling（如 default 的固定倍数或绝对值）。Lead 可在 default 与 ceiling 之间调整——adjustment 是 **enclosing checkpoint 内可独立 canonicalize 的 typed payload**，其独立 digest 为 `budget_adjustment_digest`。payload 预像（preimage）绑定：active policy ref+digest、`budget_scope_type`（`work_unit_lineage` | `task_lineage`，明确作用层级）、**exact predecessor checkpoint ref+digest、该 scope 的 predecessor effective-budget-binding digest、absolute requested effective count/LOC ceilings**、supporting refs；**明确排除 enclosing checkpoint ID/content digest，且不携带 measurement tuple（当前观测只属于 binding，不属于授权事实）**（以及自身 digest、时间）。adjust 不需用户。
3. **Hard override（`test.budget.override`）**：超过 ceiling 必须 provider-verified、create-only immutable `AuthorizationRecord`（**预先存在**，consuming checkpoint 只引用其 ref+digest，不参与派生循环）。scope 绑定：`budget_scope_type=work_unit_lineage|task_lineage` + active policy ref+digest + project + TaskRevision + （按 scope）exact WorkUnit + **exact authorizing predecessor checkpoint ref+digest 与该 scope 的 predecessor effective-budget-binding digest + absolute requested effective count/LOC ceilings** + `lead_control_id`；**不携带 measurement tuple**；issuer 只能是 user/control-plane，Lead/agent 自报、opaque ref、replay 无效。**source `mode=consume|inherit`**：`consume` 仅首次消费 checkpoint 可用（绑定预先存在 AuthorizationRecord ref+digest，authorizing predecessor/binding 匹配，record 从未消费，该 checkpoint 成为 `origin_consuming_checkpoint`）；`inherit` 必须绑定 origin consuming checkpoint ref+digest + 原 AuthorizationRecord ref+digest，沿同 project/policy/TaskRevision/scope/`lead_control_id` 连续 accepted lineage，effective ceiling 不变且无 superseding source（继承不是 replay）；第二次 consume、跨 lineage/task/policy/scope inherit、跳 origin、inherit 改 ceiling 均 fail closed。**WorkUnit 级 override 不得放宽 task 级总预算；task 级 override 不得暗含全部 WorkUnit override**——两层分别校验，跨层/跨 scope 重放拒绝。
4. **`test.budget.adjust` vs `test.budget.override`**：adjust = Lead 在 policy ceiling 内、作用层级明确的自主授权（checkpoint 内 typed payload，可审计、不打扰用户）；override = user/control-plane 越 ceiling 授权记录；二者都是权威事实，后者不可由前者冒充。
5. **累计口径（两层，都受 ceiling/override 控制）**：第一层按 TaskRevision+WorkUnit 全 lineage 累计（`budget_scope_type=work_unit_lineage`）；第二层为 TaskRevision 级总预算（policy 定义，覆盖该 TaskRevision 全部 WorkUnit lineage 之和，`budget_scope_type=task_lineage`）。retry、换 agent、换 session、换 control、新对话**均不清零**（与 fingerprint prior chain 跨 checkpoint 连续计数同构）；**拆 WorkUnit 不能重置任何一层保险丝**——两层的任何一层超限且无 override 时 runner 进入 `needs_user`（§10）。**每个 dispatch checkpoint 固定保存 canonical `effective_budget_bindings`**：恰好两项、按固定顺序 `work_unit_lineage`、`task_lineage`、各 scope 唯一一项；每项含 scope、exact policy ref+digest、effective count/LOC limits、canonical `measurements`（`test_count`/`test_code_lines` 各自 verified|unverified，见第 6 条）、`source_kind=policy_default|lead_adjustment|user_override` 及对应 source（default=canonical null/no-adjust；adjust=当前可独立求 digest 的 payload 或前序 accepted checkpoint ref+digest+其 `budget_adjustment_digest`；override=预先存在 AuthorizationRecord ref+digest）。不得漏任一 scope、重复、乱序或混用 source fields；旧有效调整/override 沿 accepted checkpoint lineage 精确引用，不 latest-wins；**old/new 校验只适用于 current adjustment 的 authoring checkpoint**：`adjust.old_effective_budget` 必须等于该 scope 在 authoring checkpoint 时的前一 binding，`new` 在 policy ceiling 内；inherited adjustment 必须验证 origin payload 在 origin 当时与其 predecessor 匹配、当前 effective ceiling 等于 origin 的 `new`、accepted lineage 连续且无 superseding source；两层同时生效由两项 bindings 表达；无 adjustment 时 `budget_adjustment_digest` 明确 absent，不伪造空 digest。
6. **可信计数（canonical measurement 状态）**：预算只从真实 change surface 与 trusted provider 计算（CI/test-runner 的 provider-verified 计数、repository 权威扫描），**不信 agent 自报**。每项 binding 固定含 `measurements.test_count` 与 `measurements.test_code_lines`（固定键序），各自 `status=verified|unverified`：verified 必须 `usage>=0` + exact provider/snapshot ref+digest；unverified 必须 usage/ref/digest 为 canonical null，并绑定 **typed `unverified_assessment`（固定字段顺序 `lead_disposition`、`lead_reason_code`、`lead_supporting_refs`、`review_status`、`review_gate_evaluation_ref`；`lead_disposition` 与 `review_status` exact mapping——pending→`proceed_pending_independent_review`、accepted→`proceed_after_independent_review`、rejected→`replan_after_independent_rejection`，unknown/mismatch fail closed；`lead_supporting_refs` 为 sorted unique exact ref+digest，`review_status=pending|accepted|rejected`——pending 时 review ref canonical null，accepted/rejected 时必须 exact independent `GateEvaluation` ref+digest **且该 GateEvaluation 携带 `budget_assessment_result` 绑定被评 binding 所在的前序 accepted checkpoint（`assessed_checkpoint_ref+digest=C_pending`、`assessed_effective_budget_binding_digest`、scope/control/metric statuses；outcome 与 review_status/lead_disposition exact mapping；纳入 canonical subject manifest；GateRequirement selector 明确要求 budget assessment；构造顺序：`C_pending` → 独立评审 → successor 消费，不得绑定消费 checkpoint 自身；**stale 判定用 `budget_review_subject_projection`（排除 review_status/lead_disposition/review_gate_evaluation_ref 三字段外的全部字段）byte-identical——只允许三字段按 outcome 从 pending/null 映射，其他字段变化即 stale 需重新 pending→review；不得要求 `C_reviewed` 完整 binding digest 等于 `C_pending`**）**，same-checkpoint circular ref/跨 checkpoint/无关 evaluation fail closed）**；禁止 null 当 0 或宣称 within-budget；数值预算机械 pass/overrun 只对 verified metric 派生；无 adapter 的 default dispatch 允许 `unverified_pending_review` binding（绝不派生 within/over budget），accepted 后仍是 unverified（仅比例性审查通过，`proceed_after_independent_review`），rejected → frozen/replan（`replan_after_independent_rejection`）；**授权不携带 measurement**：adjust/override 只引用 predecessor binding digest 间接冻结观测，writer 对新 checkpoint 的 current measurements 单独按 canonical verified/unverified 规则派生并以新 ceiling 判定；user override 用 `mode=consume|inherit`（§7-3），lead_adjustment 保持 current/inherited 精确区分；依赖独立 review 的 unverified budget adjust 与 closure 在 Slice 4 GateEvaluation 落地前 fail closed，最终 cutover 时 unverified adjust 与 closure 前必须 `review_status=accepted`；缺/混合字段、unverified 带数值、verified 缺 ref/digest、unknown 当 0、pending 带 ref、accepted/rejected 缺 ref、非独立 evaluator、disposition/review_status mismatch 均 fail closed。不得伪装成 validator correctness（§2-6）。
7. **机械保障**：validator 派生两层累计记账 projection；`test.budget.override` 缺失、scope 不匹配、跨层/重放时 fail closed；任一超限且无 override 时 runner 进入 `needs_user`（§10），不进入 frozen。

## 8. effective_verification_plan_digest：规则如何传给所有相关角色

**设计**：不存在可写的 "effective verification plan" 对象（无 plan truth 对象、无第二事实源）。只有一个**确定性派生的 digest**——`effective_verification_plan_digest`：

1. **唯一权威输入**：active `ProjectPolicyRevision`（budget default/ceiling、verification policy）+ `TaskRevision`/`EvidenceRequirements`（acceptance、`verification_class` 集合、GateRequirements）+ assigned `RuleResolutionArtifact` ref + canonical `effective_budget_bindings`（§7-5，含 `test.budget.adjust` typed payload 与**预先存在的** `test.budget.override` `AuthorizationRecord`，create-only，独立于 checkpoint，consuming checkpoint 只引用其 ref+digest）。
2. **确定性派生顺序（单向，无循环）**：受控 resolver 按固定顺序：先独立 canonicalize `test.budget.adjust` payload 得 `budget_adjustment_digest`（预像绑定 policy ref+digest、`budget_scope_type`、**exact predecessor checkpoint ref+digest、该 scope 的 predecessor effective-budget-binding digest、absolute requested effective count/LOC ceilings**、supporting refs；**排除 enclosing checkpoint ID/content digest，且不携带 measurement tuple**）——**该 digest 进入对应 binding 的 `lead_adjustment` source，仅当当前 checkpoint 存在 adjustment 时；无 adjustment 时明确 absent，不伪造空 digest**——→ 再以**完整 ordered `effective_budget_bindings` + 其余权威输入**（不含 bindings 之外的任何 adjustment digest）计算 `effective_verification_plan_digest`（RFC 8785 canonical JSON + SHA-256，规则同 ADR-004 resolution identity）→ 再将其作为派生输入纳入 `closure_basis_digest`（§4）。**覆盖规则**：enclosing checkpoint ID/content digest 不进入 `budget_adjustment_digest` 或任何上游派生预像；`effective_verification_plan_digest` 与 `closure_basis_digest` 始终是 checkpoint 正文字段并被最终 checkpoint identity/content digest 覆盖，`budget_adjustment_digest` 仅在当前 adjustment 存在时（iff present）同为正文字段并受覆盖——链上每一级只引用前级 digest、从不引用后级，`closure_basis_digest` 不进入 `effective_verification_plan_digest` 的 hash domain——无 digest 循环、无自引用。
3. **checkpoint pin source refs+digests**：accepted LeadCheckpoint 只保存上述权威输入的 exact refs+digests（policy ref、TaskRevision ref、RuleResolution ref、override 授权 ref、adjust payload），且**始终 pin `effective_verification_plan_digest` 与 `closure_basis_digest`；`budget_adjustment_digest` 仅当当前 adjustment 存在时 pin，无则明确 absent**；不复制任何规则正文或 plan 内容。
4. **context projection 只能重算/下发**：任何 Attempt 若其 permission/capability profile 包含 test-write、verification-submit 或 gate-close 能力，其 context projection 必须**重算或从 checkpoint 下发**同一 `effective_verification_plan_digest` 及其 source refs；缺失/不一致则该 Attempt 的 evidence 不能关闭对应 requirement。
5. **AttemptCreated pin exact ref+digest**：Attempt 的 assignment 绑定 assigned `RuleResolutionArtifact`（ADR-004）、`change_thesis_ref`、dispatch checkpoint ref（Slice 1 合同）；`effective_verification_plan_digest` 经 dispatch checkpoint ref 可达。
6. **writer 最终机械保障**：受控 writer 在 AttemptCreated 前校验 assigned resolution 存在、dispatch checkpoint 已 accepted、source refs 齐全、override 授权记录已预先存在且被引用、plan/basis digest 可复算（`budget_adjustment_digest` iff present 时同校验）；validator 复核 refs 一致。规则正文不复制进 Attempt（只引用 resolution ID，ADR-004）。
7. **AGENTS.md 只是客户端提示，不是产品 authority**：仓库根 AGENTS.md 的 10/300 等纪律是 prompt 层默认值，权威在 ProjectPolicyRevision/TaskRevision；两者冲突时以 policy 为准（文档治理见 §18）。

## 9. 代码规范治理分层

- **机械规则（validator，fail closed）**：identifier/digest/lineage/cardinality/single-active/work-graph/refs 一致性、budget 记账、blocking 派生映射。确定性、可复算、无语义。
- **Lead 语义判断（checkpoint provenance）**：goal 关系、方案比例性、thesis 取舍、ceiling 内 budget adjust、closure basis 组成、replan/split/switch/freeze/escalate 理由。
- **independent reviewer（GateEvaluation/Finding）**：结构/价值/风险/完整性审查（ADR-003 决策八）、production change surface 完整性、Finding basis 判定。
- **user escalation（policy/AuthorizationRecord）**：goal 变更、risk acceptance、hard override、protected 变更批准（ADR-003 policy authority）。
- **反模式**：词表/naming lint 不能单独判 pass（ADR-003 决策一）；"validator 通过"不能替代语义审查（§2-6）；Lead 不能自审（ADR-003/006）。

## 10. bounded runner

- 保留 ADR-006 的深模块：`LeadControl.reconcile(authoritative_facts, trigger) -> LeadDecision` 单步、确定、fail-closed。
- 外层：**同一公开命令**串行驱动循环：collect authoritative facts → reconcile → 受控 writer 原子 compare-and-append accepted LeadCheckpoint → 执行恰好一个允许动作（dispatch 一个 Attempt / terminal 事件 / session 操作）→ 下一轮。无并行 dispatch，无通用 scheduler。
- 停止状态（四种，**互斥**：每次 reconcile 恰好给出一个当前状态，不写双态、无隐式转换；新增授权事实后下一次 reconcile 再恢复）：
  - `completed`：Gate Engine 派生 closure（AggregateOutcome）达成；
  - `blocked`：外部依赖/authority 缺失且非用户事实（如 trusted provider 暂不可用、服务未就绪），等待外部事实恢复；
  - `frozen`：**仅** Lead 可在 delegation envelope 内自动 replan/split/switch 的控制异常——assurance-only、连续两轮零 Delivery、scope/blast/review-surface/goal relation 失控、fingerprint identity 不可证明；自动继续被禁止，但无需用户介入；
  - `needs_user`：**需要 user authority 的硬越界与风险接受**——超 policy ceiling 且无 `test.budget.override`、第三次同 fingerprint 且无 `task.retry.override`、goal 变化、risk acceptance、protected 变更、确需用户提供/授权/接受风险。
- 不新增事实源：facts 仍在权威对象，checkpoint 只存 selection/assessment/delta/decision 的 exact refs（ADR-006）；runner 不拥有 queue/priority/progress 之外的任何 truth。

## 11. automatic continuation envelope

- **round 是 safety fuse，不是 correctness**：轮数只触发检查，不证明正确（ADR-006）。
- Lead 可在 ceiling 内收紧/调整（budget adjust、agent/context 替换、`effective_verification_plan_digest` 派生输入细化），每次调整入 checkpoint，**不问用户**（§2-4）。
- 超限分类（互斥）：**需要 user authority 的硬越界**（预算超 ceiling 无 override、第三次同 fingerprint 无 retry override）→ `needs_user`；**Lead 可自动 replan 的控制异常**（连续两轮零 Delivery delta、immediate freeze 条件如 assurance-only/scope/goal relation 失控）→ `frozen`；继续均需 replan/split/switch/escalate 或对应 user authority。
- 首轮零 Delivery delta：仅当 thesis/agent-context/scope/verification plan 至少一项有证据的实质变化才可授权 successor（ADR-006）。
- 软调整不询问用户（§16 non-goal：不要求每次软调整 needs_user）。

## 12. recovery

- **exact trigger/provenance**：恢复沿同一 `lead_control_id` 从权威 facts + 唯一 accepted checkpoint tip 重建 queue/selection/decision（ADR-006 场景 13）；缺 runtime subject assertion、fork、双 active 时 fail closed。
- **idempotency**：attempt_id 预分配 + 单次 AttemptCreated（ADR-004）；checkpoint 原子 compare-and-append；create-only 对象同 ID 同内容幂等复用；replay 要么得到同一对象要么失败，不产生双写。
- **缺权威正文/证据不得补造，且按互斥三态归位**：recovery 需要任何正文、artifact、resolution、checkpoint 或 evidence 而权威源缺失时：若缺失的是外部权威事实/服务且可恢复 → `blocked`；若属可自动 replan 的控制异常（如 checkpoint 投影可重建）→ `frozen`；**只有确需用户提供、授权或接受风险才进入 `needs_user`**。任何情况下**禁止从对话/缓存/候选关系合成缺失正文**（alpha #9 CandidateTree 补造缺失正文的反模式显式禁止；ADR-003 候选关系不能推进 state）。
- **不重复副作用**：dispatch 只从已 accepted checkpoint 发生；已 dispatch 的 attempt 不得被 recovery 重复 dispatch；session/executor 操作走 terminal/release → successor/bind 或受控原子 transfer。
- > **已取代（2026-08-17）**：本条中「受控原子 transfer」已移除；terminal/release → successor/bind 保留（见 ADR-006 修订记录）。
- **不绕预算/gate**：budget 累计跨 recovery 连续（§7-5）；recovery 后 dispatch 仍须满足 predecessor terminal、依赖 ready、gate 要求。

## 13. 对象/authority 最小变更表

| 对象 | owner / writer | amendment 增量 | 引用 / 派生 | 防第二事实源 |
|------|---------------|---------------|------------|-------------|
| ProjectPolicyRevision | 受控 policy writer（user authority） | 新增 policy 字段：test budget default/ceiling、blocking 派生映射、verification_class 默认 | TaskRevision/checkpoint/AuthorizationRecord 引用 exact id+digest | 预算累计状态不得写回 policy |
| TaskRevision / EvidenceRequirement | Lead 提议、policy authority 批准 | EvidenceRequirement 新增 `verification_class`；acceptance/requirement 稳定 ID 不变 | WorkUnit 只引用 refs | 不复制进 WorkUnit（ADR-003） |
| LeadCheckpoint | 受控 writer（原子 compare-and-append） | 新增 `closure_basis_digest`、`effective_verification_plan_digest`、`budget_adjustment_digest` 与 source refs+digests、`test.budget.adjust` typed payload、continuation decision | 只存 exact refs 与派生 digest，不复制 task/evidence/gate truth；`effective_verification_plan_digest`/`closure_basis_digest` 始终是正文字段并被最终 checkpoint identity/content digest 覆盖，`budget_adjustment_digest` iff present 同为正文字段并受覆盖（checkpoint 自身 ID/digest 不进入任何上游派生预像） | 不成为 selection/预算/plan truth 的第二事实源 |
| WorkUnitAttempt | append-only attempt writer | Slice 1 已设计：`lead_control_id`/`predecessor_work_unit_attempt_ref`/`dispatch_lead_checkpoint_ref`；assignment pin rules/thesis | status/time 只从事件派生 | 不保存可覆盖 assignment/status |
| Finding | create-only（经 GateEvaluation） | 新增 typed `basis`；blocking 由 Gate Engine 按 policy 派生 | EvidenceRecord 不复制 verdict/finding（ADR-004） | agent 自由文本不能自称/否认 blocking |
| AuthorizationRecord | user/control-plane provider | 新增 semantic action `test.budget.override`（与 `task.retry.override` 同构），scope 含 `budget_scope_type=work_unit_lineage|task_lineage`、exact authorizing predecessor checkpoint ref+digest + 该 scope 的 predecessor effective-budget-binding digest、absolute requested ceilings、`lead_control_id`；source `mode=consume|inherit`（consume 首次消费并成为 origin_consuming_checkpoint；inherit 绑定 origin + 原 record 沿同 scope 连续 accepted lineage，不改变 ceiling） | **预先存在**，consuming checkpoint 只引用 ref+digest；不携带 measurement tuple | Lead/agent 自报无效；第二次 consume、跨 lineage/task/policy/scope inherit、跳 origin、inherit 改 ceiling、WorkUnit override 放宽 task 总预算均 fail closed |
| RuleResolution / context projection | 受控 resolver | `effective_verification_plan_digest` 从权威输入派生并进入 context projection（§8） | 从权威对象重算/下发 | 不成为规则正文或 plan truth 的第二副本 |

## 14. 精确切入当前计划（历史记录）

**本文为历史设计来源**：其条款已整合进 ADR-003（决策九）、ADR-004（决策七）、ADR-005（实施约束 15-17）、ADR-006（Amendment 节）；**当前只有 ADR-003/004/005/006 是 normative semantic source；plan 是 non-normative implementation/delivery/acceptance mapping，不得覆盖 ADR**，不再以本文为规范权威。切片分工如下：

**Slice 1（不变，待批）**：WorkUnit exact parent/dependency refs、唯一 root、parent tree 可达、dependency DAG/readiness；WorkUnitAttempt exact `lead_control_id`、terminal predecessor、dispatch `LeadCheckpoint` ref；single-active（per-control/per-task/per-WorkUnit）。**不加无消费者 placeholder**：`dispatch_lead_checkpoint_ref` 只做格式/链内一致性校验，store-backed 存在性/tip/selection 校验随 Slice 2；不建 LeadCheckpoint schema/collection。本 amendment 不改变 Slice 1 proposal 的 schema 版本、error code 与测试计划。

**Slice 2**：+ delegation envelope（§3）、`closure_basis_digest`（§4）、`effective_verification_plan_digest` 派生与下发（§8）、test budget 两层累计/ceiling/override（§7）、bounded runner 与互斥停止状态（§10）、continuation envelope（§11）、recovery 三态归位（§12）。

**Slice 3**：+ `verification_class`（§6，三类互斥）。

**Slice 4**：+ Finding basis/blocking 派生（§5）。

**Slice 5**：只投影——`effective_verification_plan_digest`/`closure_basis_digest` 视图、budget 两层累计 projection、关系视图纳入 digest 引用；不新增事实源。

**Slice 6**：E2E/cutover（ADR-005 约束 15-17）+ 文档治理（§18）。

## 15. 每 Slice 最小验收与测试预算

- 每 Slice：新增测试 ≤ 10 个、新增测试代码 ≤ 300 行（超限先说明业务风险、等确认）；复用现有 `tests/fixtures/orbit-v2/` fixture（扩展 `fixture_factory.rb`，不新建 harness）；不建新 mutation matrix（`validator-invariants.md` 维持 Slice 0 矩阵，仅按需追加行）。
- 优先覆盖（Given/When/Then）：
  1. Lead 在 ceiling 内自主 adjust 不问用户 → checkpoint 内 typed payload（`budget_adjustment_digest` 独立 canonicalize）、无 needs_user；
  2. 硬越界（超 ceiling 无 override、第三次同 fingerprint 无 retry override、goal 变化、risk acceptance）才 `needs_user`，且缺 override fail closed；
  3. 跨 Agent 获取同一政策：不同 Attempt 从同一 checkpoint/policy 解析出 byte-identical `effective_verification_plan_digest`/basis；
  4. 预算不随 lineage reset：换 agent/session/control/对话后两层累计连续，任一层超限无 override → needs_user（不冻结）；
  5. 动态 audit 不成永久测试：`release_audit`/`acceptance_evidence` 与 `verification_use` 配对不符的 evidence 被结构化拒绝（不判自由文本）；
  6. hardening 不阻塞：`hardening_opportunity` Finding 默认非 blocking，进非抢占 WorkUnit；
  7. runner/recovery fail closed：缺权威正文不补造、recovery 不重复 dispatch、不绕预算/gate、每次 reconcile 恰一个停止状态（授权事实到达后下一 reconcile 恢复）。

## 16. Non-goals

- 不把 10/300 写死为通用 schema correctness 常量（是 repo default 政策，policy 可配置）。
- 不建通用 style AI judge、通用 test parser、Portfolio 平台或并发 scheduler。
- 不要求每次软调整询问用户（ceiling 内 Lead 自治是原则，不是例外）。
- 不重开 Evidence/Validator 底座（ADR-006 non-goal 保持；本 amendment 只加上述最小 seam）。
- 不把 AGENTS.md/boom 文档当产品 authority；不复制规则正文进合同。
- 不因 budget 机制引入 agent 自报计数或不可验证的"测试复杂度"指标。

## 17. Owner 决策记录（2026-08-11 批准，推荐项全部采纳）

| # | 决策点 | 决议 |
|---|--------|------|
| 1 | 初始 10/300 定位 | 作为 ProjectPolicyRevision 默认模板的 repo default（可 per-project 配置），不是 schema correctness 常量 |
| 2 | Lead ceiling 配置源 | 由 active ProjectPolicyRevision 定义（倍数或绝对值），checkpoint pin exact id+digest |
| 3 | 无 trusted test-count adapter 时的行为 | 诚实标 `unverified`（canonical：`measurements.test_count`/`test_code_lines` 各自 `status=verified|unverified`；unverified = usage/ref/digest canonical null + typed `unverified_assessment`——固定字段顺序 `lead_disposition`/`lead_reason_code`/`lead_supporting_refs`/`review_status`/`review_gate_evaluation_ref`，disposition 与 review_status exact mapping（pending→proceed_pending_independent_review、accepted→proceed_after_independent_review、rejected→replan_after_independent_rejection），pending 时 review ref null、accepted/rejected 时必须 exact independent GateEvaluation ref+digest 且携带 `budget_assessment_result` 绑定被评 binding 所在的前序 accepted checkpoint（`assessed_checkpoint_ref+digest=C_pending`；构造顺序 `C_pending` → 独立评审 → successor 消费，不得绑定消费 checkpoint 自身；stale 判定用 `budget_review_subject_projection` byte-identical，不得要求完整 binding digest 相等；纳入 canonical subject manifest，GateRequirement selector 明确要求 budget assessment），禁止 null 当 0）；数值 pass/overrun 只对 verified metric 派生；default dispatch 可 `unverified_pending_review` 但绝不派生 within/over budget；授权（adjust/override）不携带 measurement，只引用 predecessor binding digest，writer 对新 checkpoint 单独派生观测；override source 用 mode=consume|inherit；unverified adjust 与 closure 在 Slice 4 前 fail closed、cutover 时必须 review_status=accepted |
| 4 | Finding blocking 派生 | policy 映射：contract_violation/regression 默认 blocking；newly_discovered_risk 需 risk-owner/user（否则 needs_user）；hardening 默认非 blocking |
| 5 | runner 停止状态集 | completed / blocked / frozen / needs_user 四态互斥：每次 reconcile 恰一态；超 ceiling 无 override、第三次同 fingerprint 无 retry override 唯一进入 needs_user；frozen 仅限 Lead 可自动 replan 的控制异常（§10） |
| 6 | 预算记账单元 | **WorkUnit-lineage 与 task-lineage 两层累计（`budget_scope_type`），两层都受 ceiling/override 控制**（§7-5）；WorkUnit override 不放宽 task 总预算、task override 不暗含全部 WorkUnit override；拆 WorkUnit 不得重置保险丝 |
| 7 | closure_basis_digest 冻结时点 | dispatch 时（accepted LeadCheckpoint 内冻结） |
| 8 | verification_class 强制点 | EvidenceRequirement 声明 + dispatch 冻结 + validator 结构化兼容校验（不判自由文本） |

## 18. 文档治理（已执行记录）

- **AGENTS.md（根 + `~/.omp/agent/`）**：已作为客户端提示单独维护，头部已加"客户端纪律、非产品 authority"声明；其"10/300、前三问、防循环修复"是 prompt 层纪律，v2 合同只把 default 值引用为 repo default，authority 在 policy（§8-7）。
- **boom_of_test_case.md**：已治理为事故背景 + 跨 Agent 结论 + 正式落点索引（指向 alpha_test_result、ADR-003/006/004、AGENTS.md），AGENTS 全文复制已删除，避免双源漂移。
- **alpha_test_result.md**：已更新为设计状态矩阵——每项标注 design accepted / runtime not implemented，链接对应 ADR/plan 条款并标注落地 slice。

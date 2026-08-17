# Codex 跑偏 Alpha 测试结果

> Codex 使用过程中的跑偏问题归纳，每节一个 issue。
>
> 2026-08-11 更新：本节已矩阵化为"设计状态"，**正式落点链接当前 ADR（normative semantic source）与 implementation plan（non-normative delivery/acceptance mapping，不得覆盖 ADR）**（设计来源：[orbit-v2-agent-independent-control-amendments](../history/agent-independent-control-amendments.md)，仅 provenance）。**所有条目均为 design accepted、runtime not implemented**，对应机制按 [v2 交付记录](../history/v2-delivery-record.md) 的 slice 落地；本文不构成任何已实现能力的声明。
>
> 2026-08-17 更新：v1 已删除，v2 是唯一 runtime，最小 CLI 路径已交付。但**本表十项的 runtime 状态不变**——它们依赖的 bounded runner 与执行层仍未接通，见 [愿景达成计划](../plan/vision-completion-plan.md)。

## 摘要

| # | 问题 | 核心 | 设计状态（2026-08-11） | 落地 slice |
|---|------|------|------------------------|-----------|
| 1 | 修复链路跑偏 | 修复链路过长时，agent 把修复任务当主线需求 | design accepted：[ADR-003 决策三/六](../adr/003-lead-orchestrated-dynamic-agent-team.md)、[ADR-006](../adr/006-serialized-lead-orchestration-control-loop.md)；runtime not implemented | 1/2 |
| 2 | 过程命名代码入正式目录 | 阶段标签（P6/slice1）被写进正式代码，主 agent 未审查到 | design accepted：[ADR-003 决策一/八](../adr/003-lead-orchestrated-dynamic-agent-team.md)、[决策九 治理分层](../adr/003-lead-orchestrated-dynamic-agent-team.md)；runtime not implemented | 4/5 |
| 3 | 多任务编排 | 1 主线 + N 支线的编排方式缺失 | design accepted：[ADR-006 task queue/unique selection/single-active](../adr/006-serialized-lead-orchestration-control-loop.md)；runtime not implemented | 2 |
| 4 | 任务异常评判 | 无"何时换策略"标准，单测重来九轮才人工介入 | design accepted：[ADR-006 Amendment 节：continuation envelope/bounded runner](../adr/006-serialized-lead-orchestration-control-loop.md)、[plan Slice 2](../history/v2-delivery-record.md)；runtime not implemented | 2 |
| 5 | 过度设计 | 证据链加固过深、核心未完成；应切片冻结 | design accepted：[ADR-006 non-goals](../adr/006-serialized-lead-orchestration-control-loop.md)、[ADR-006 Amendment 节：跨 Agent test budget](../adr/006-serialized-lead-orchestration-control-loop.md)、[plan Slice 2](../history/v2-delivery-record.md)；runtime not implemented | 2 |
| 6 | Lead 自检 | 需定时自检主线/支线/子任务/当前任务 | design accepted：[ADR-006 四层自检](../adr/006-serialized-lead-orchestration-control-loop.md)、[ADR-006 Amendment 节：bounded runner](../adr/006-serialized-lead-orchestration-control-loop.md)、[plan Slice 2](../history/v2-delivery-record.md)；runtime not implemented | 2 |
| 7 | 拖轮次根因 | 审核标准不断移动 + 未冻结验收清单 | design accepted：[ADR-004 决策七：closure_basis_digest](../adr/004-role-rule-context-evidence-binding.md)、[plan Slice 2/4](../history/v2-delivery-record.md)；runtime not implemented | 2/4 |
| 8 | 审核边界失误 | 动态数据当稳定契约、验收证据当永久测试 | design accepted：[ADR-004 决策七：verification_class/verification_use](../adr/004-role-rule-context-evidence-binding.md)、[plan Slice 3](../history/v2-delivery-record.md)；runtime not implemented | 3 |
| 9 | 补丁链失控 | 复审范围无限扩大，应回退并封顶小任务 | design accepted：[ADR-006 Amendment 节：bounded runner/recovery](../adr/006-serialized-lead-orchestration-control-loop.md)、[plan Slice 2](../history/v2-delivery-record.md)；runtime not implemented | 2 |
| 10 | 测试数量爆炸 | 无限扩测试弃主线；需数量上限与优先级约束 | design accepted：[ADR-006 Amendment 节：跨 Agent test budget](../adr/006-serialized-lead-orchestration-control-loop.md)、[plan Slice 2](../history/v2-delivery-record.md)；runtime not implemented | 2 |

## 1. 修复链路跑偏

- [ ] 同一对话内让 agent 修复问题时，修复链路过长会导致 agent 把修复当成主线需求，直接跑偏。

**设计状态（2026-08-11）**：design accepted——ADR-003 决策三/六（LogicalLead 与 bounded WorkUnit 恢复主目标）、ADR-006（checkpoint-before-dispatch、goal relation freeze）；runtime not implemented（Slice 1/2）。

## 2. 过程命名代码进入正式目录

- [ ] 生成了 `xxx-P6-xx.ts`、`xxx-slice1-xxx.ts` 等带开发过程命名的代码并落入正式目录，主 agent 未审查到。

**根因**

- 任务指令自带阶段标签（"P6 ..."），执行者把验收流程整体产品化、原样带入任务语言（`FreshP6Initialization` 等），未先抽象稳定产品能力、把 P6 协议留在 scripts。
- `candidate-review-slice1-handler.ts` 为历史命名，本轮仅改接线；把"与现有命名一致"误判为"合理"，未重新审视阶段结束后命名是否成立。

**审查盲区**

- 只按数据流/危险边界抽查（调用次数、预算、权限、恢复等），未做新增 symbol 词汇审计。
- 5000 行改动仅抽查核心文件，未系统检查新增文件名、导出类型、public API 语义。
- 任务拆法本身鼓励阶段标签进正式代码（"正式 P6 initializer/host"）。

**设计状态（2026-08-11）**：design accepted——ADR-003 决策一（不建词表，上下文代码健康判断）、决策八（production change surface 完整性）、决策九（机械规则/Lead/reviewer/user 分层）；runtime not implemented（Slice 4/5）。

## 3. 多任务编排

- [ ] Lead 同时持有 1 个主线 + N 个支线，缺编排方案。

**设计状态（2026-08-11）**：design accepted——ADR-006 有序 task queue、唯一 selection、single-active、Task transfer release/acquire provenance；runtime not implemented（Slice 2）。

## 4. 任务异常评判标准

- [ ] 无"任务何时异常、何时换策略"的判定标准：orbit 重构的单测重来九轮，人工介入才换策略。

**设计状态（2026-08-11）**：design accepted——ADR-006 止损（round fuse、零 Delivery delta、fingerprint、retry override、立即 freeze）+ ADR-006 Amendment 节 automatic continuation envelope（软调整不问用户；超 ceiling 无 override → needs_user；frozen 仅用于 Lead 可自动 replan 的控制异常）+ plan Slice 2；runtime not implemented（Slice 2）。

## 5. 过度设计（尤其单测）

- [ ] 方向没错但顺序失衡：先把证据链加固到很深，核心循环后半段未接上。约 5000 行工作区应在完整性漏洞关闭后切片冻结，不再无限扩底座。

**设计状态（2026-08-11）**：design accepted——ADR-006 non-goals（不扩大 Evidence/Validator substrate）+ ADR-006 Amendment 节跨 Agent test budget 封顶（`effective_budget_bindings` 两层累计、超 ceiling 无 override 唯一进入 needs_user）+ plan Slice 2；runtime not implemented（Slice 2）。

## 6. Lead 定时自检

- [ ] 定时自检四个维度：主线任务 / 支线任务 / 子任务 / 当前任务。

**设计状态（2026-08-11）**：design accepted——ADR-006 四层自检（task queue / active mainline / work graph branches / current attempt）+ event triggers + ADR-006 Amendment 节 bounded runner 每步 reconcile 强制评估入 checkpoint + plan Slice 2；runtime not implemented（Slice 2）。

## 7. 拖十几轮的根因

- [ ] 前几轮确有真 bug（helper 锁竞态、fd 锁可伪造、writer 未加锁）；后几轮"证据还能更强"的审核标准不断移动；未提前冻结验收清单，导致每轮审查追加更细的证明要求。

**设计状态（2026-08-11）**：design accepted——ADR-004 决策七 `closure_basis_digest`（dispatch 时冻结完成标准，reviewer 只能走 Finding 不能移标准）与 Finding basis（blocking 与 basis/policy 一致）+ plan Slice 2/4；runtime not implemented（Slice 2/4）。

## 8. 审核边界判断失误

- [ ] 把一次性验收扩成了永久测试，任务膨胀。

**五个根因**

1. 混淆验证类型：稳定程序规则（未知值显示 —、内容不溢出）适合长期 UI 测试；当前数据质量（本轮价格有无单位）应做发布审计；一次性缺陷复现（8 家 URL）只需人工复验。
2. 动态数据当稳定契约：固定断言"帕西尼必须是 5、7、9 元""必须含 8 家公司"，测的是数据库快照而非程序行为。
3. 过度防回归：把每个肉眼问题固化成浏览器门禁，抽象层级错误。应改为：合成 fixture 测展示、几何断言测溢出、发布审计查数据、具体 URL 人工复验。
4. 主线失控：P0 被扩成特定公司/特定值/双端截图/Detail 全链路测试，延迟 P1。
5. 验收证据与测试混同：截图证明"这次修好了"，测试证明"规则以后不坏"，用途不同。

**影响**：两次低价值测试提交（e4195bd、efce78f）；浏览器套件被临时数据污染；引入错误选择器红灯；挤占 P1 时间。生产修复未破坏，数据库无写入。

**纠正**：删固定断言；单元格语义改用合成数据；浏览器只测通用溢出/滚动/交互；具体 URL 仅人工验收；动态事实进发布审计。

**加测试前三问**：① 稳定规则还是数据快照？② 换一轮数据仍成立吗？③ 该由单测、发布审计还是人工验收承担？

**设计状态（2026-08-11）**：design accepted——ADR-004 决策七 `EvidenceRequirement.verification_class` 将"前三问"产品化：`regression`（稳定规则→永久测试）/ `release_audit`（动态/时效性数据与发布时检查→发布审计）/ `acceptance_evidence`（本任务一次性 URL/截图/人工复验→EvidenceRecord）**三类互斥**，配 `implementation_check.evidence_requirement_results[].verification_use` 结构化配对与 `ArtifactClaim.kind` 兼容校验；validator 不判断自由文本里的动态数据/稳定 signal，分类语义由 Lead/reviewer 留 provenance + plan Slice 3。runtime not implemented（Slice 3）。

## 9. 几十轮补丁链失控

- [ ] 任务几十轮未闭环，agent 自认失控。

**缺失的产品能力**：同一次有界流程内自动执行"定向修复 → 独立复审 → AB/BA"，无需再发命令。

**反复修改暴露的三个问题**：续修需额外调公开命令，非真正自动循环；CandidateTree 错误补造缺失正文；修复触发证据未在恢复/发布阶段完整重放。

**失控点**：这些确为真 bug，但复审范围不断扩大到相邻恢复机制，偏离"跑完真实稿件流程"主线；WIP 未提交、未验证，不能用于真实项目。

**对策**

1. 回退未提交 WIP 至安全 checkpoint d1a6a0e；
2. 只开一个严格封顶的小任务，实现"结构失败同命令内续修"一条能力，固定两个公开验收场景；
3. 一轮不闭合即判设计阻塞，不再追加锁、迁移、恢复框架或动态门禁。

**设计状态（2026-08-11）**：design accepted——ADR-006 Amendment 节 bounded runner（同一公开命令串行驱动、四互斥停止状态）与 recovery（exact provenance、idempotency、**缺权威正文/证据不得补造**，显式禁止 CandidateTree 式补造）+ plan Slice 2；runtime not implemented（Slice 2）。

## 10. 测试数量爆炸

- [ ] 为了覆盖用例无限扩测试，甚至弃主线任务不管——本质是优先级排序错误，不是测试能力不足。

**默认硬限制**

- 新增测试 ≤ 10 个、新增测试代码 ≤ 300 行；超出须先说明覆盖的业务风险，确认后扩大。

**测试取舍**

- 只测核心流程、重要分支、历史 bug 场景；不测框架行为、无价值边界、实现细节、假设性风险。
- 判断标准：删除该测试后，发现真实问题的能力会下降吗？不会 → 不保留。

**优先级**

- 需求与测试冲突时，优先完成需求主线；测试只是辅助验证，不能阻塞核心功能。
- 已固化为仓库根目录 `AGENTS.md` 的约束。

**设计状态（2026-08-11）**：design accepted——ADR-006 Amendment 节跨 Agent test budget（policy default + Lead ceiling `test.budget.adjust` typed payload + user `test.budget.override`，`effective_budget_bindings` 两层累计不清零，trusted 计数）+ plan Slice 2；10/300 定位为仓库初始客户端/default policy 建议，**不是通用 schema correctness 常量**；AGENTS.md 只是客户端提示，不是 Orbit 产品 authority。runtime not implemented（Slice 2）。

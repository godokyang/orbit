# Orbit 文档索引

按**体裁**分目录，每类内容只有一个出处。找东西先看这张表。

> 当前入口：[任务运行重构交接](plan/handoff.md)。现行语义是 ADR-007 与 `contracts/task-runtime.md`。Zeen 交接包与旧阶段保留供溯源，不是前置工作流或待执行队列。

| 我想知道… | 去哪 |
| --- | --- |
| 开发 Orbit 时如何评估、分工、验证与收尾 | [`agents/development-workflow.md`](agents/development-workflow.md) —— 开发协作规范，根 `AGENTS.md` 为加载入口；不属于产品合同 |
| 为什么这么设计 | [`adr/`](./adr/) —— 架构决策记录，现行 ADR-007 与 `contracts/task-runtime.md`；ADR-001–006 保留为历史 |
| 刚接手、下一步是什么 | [`plan/handoff.md`](./plan/handoff.md) —— 阶段交接 |
| 接下来做什么、裁决是什么 | [`plan/vision-completion-plan.md`](./plan/vision-completion-plan.md) —— 唯一前瞻计划 |
| 欠了什么、能不能动这块代码 | [`plan/debt-ledger.md`](./plan/debt-ledger.md) —— 唯一欠账出处 |
| 判据、外部规范、事故发现 | [`reference/`](./reference/) —— 参考资料，会被反复查阅 |
| 之前发生过什么 | [`history/`](./history/) —— 已完成工作的记录，不作现在时指令阅读 |

docs/plan/handoff.md 下次从这里继续

## 目录

### `agents/` —— 开发协作规范

| 文件 | 说明 |
| --- | --- |
| [development-workflow.md](agents/development-workflow.md) | Root 直接评估、按收益协作、规则派发、途中纠偏、验证与资源收尾；约束开发者，不产生 Orbit 产品事实 |

### `adr/` —— 架构决策

| 文件 | 主题 |
| --- | --- |
| `001-task-evidence-trust-boundaries.md` | Task/Evidence 信任边界 |
| `002-herdr-runtime-identity-boundary.md` | Herdr 运行时身份边界（推翻了 ADR-001 的 automatic session refresh） |
| `003-lead-orchestrated-dynamic-agent-team.md` | Lead 编排的动态 Agent 团队 |
| `004-role-rule-context-evidence-binding.md` | 角色/规则/上下文/证据绑定 |
| `005-orbit-v2-clean-cut-and-legacy-retirement.md` | v2 一刀切与 v1 退役 |
| `006-serialized-lead-orchestration-control-loop.md` | 串行 Lead 编排控制循环（已退役） |
| `007-task-runtime-refactor.md` | 当前：独立任务进程、已有 Root、原文与实际产物、纠偏与停止 |

ADR 用**修订记录**方式演进：原文不删，就近加已取代标注，文末追加修订节。

### `plan/` —— 活跃计划

| 文件 | 说明 |
| --- | --- |
| `handoff.md` | 当前交接：任务运行重构、真实验收与收尾状态 |
| `vision-completion-plan.md` | 唯一当前总 TODO、冻结验收、实现边界与资源记录 |
| `debt-ledger.md` | 有意推迟的项目，含推迟理由与解除条件 |
| `*-workorder.md` | 派给执行方的工单。**执行中**留在 `plan/`，完成后移入 `history/`。当前 `plan/` 无执行中工单 |

**工单不拥有裁决。** 它只做派发，与计划冲突时以计划为准。任何规格写进工单都会随工单进入 `history/`（无裁定权层）而失效——规格必须留在计划里。

### `reference/` —— 参考资料

| 文件 | 说明 |
| --- | --- |
| `codex-agents-md-loading.md` | Codex 的 `AGENTS.md` 发现/合并规则与编写方法；规则库设计依据 |
| `alpha-test-findings.md` | Alpha 测试十项病例与设计状态矩阵；规则库的病例来源 |
| `test-explosion-case.md` | 测试爆炸事故与跨 Agent 结论 |
| [zeen-orbit-handoff-20260913/](reference/zeen-orbit-handoff-20260913/README.md) | 原始重构讨论、用户边界、Zeen 参考副本与代码阅读索引；保留供溯源 |
| [orbit-runtime-acceptance-20260914.md](reference/orbit-runtime-acceptance-20260914.md) | 当前实现的两条真实验收、消耗与能力限制 |

### `history/` —— 交付历史

| 文件 | 说明 |
| --- | --- |
| `task-runtime-design-baseline-20260914.md` | 重构前完整计划与讨论确认快照；D1–D11/旧 H–K 不再是执行队列 |
| `pre-task-runtime-handoff-20260914.md` | `e578365` 的交接原文快照 |
| `v2-delivery-record.md` | Slice 0–6 的交付编排与验收条目（原 Orbit v2 Implementation Plan） |
| `agent-independent-control-amendments.md` | agent-independent control 的设计来源，条款已整合进 ADR-003/004/005/006 |
| `slice6-handoff.md` | Slice 6 暂停时的状态与纠偏路线，ADR-003/005/006 引用其为 task-centric 转向背景 |
| `slice6-workorder.md` | Slice 6 纠偏工单，ADR-005 引用其第 6 节为 v1 删除的决策依据 |
| `slice6-task-local-storage-design.md` | Task 本地存储布局设计 |
| `slice6-minimal-cli-path-design.md` | 最小真实 CLI 路径设计 |
| `g1-rule-library-design.md` | 阶段 G 规则库切分设计（已落地） |
| `g1-workorder.md` / `g2a`–`g2e-workorder.md` | 阶段 G 工单（无独立 g2c 文件） |
| `v1-runtime/` | v1 `guide.md` 与 `core-operating-model.md`，不是现行操作指引 |

`history/` 中的文档保留写作当时的原文与路径。**其状态描述反映当时事实**，与今日现状的差异在各文件头部说明。

## SSOT 约定

同一事实只有一个权威出处；其他地方只能引用，不能复制。

| 事实 | 权威出处 |
| --- | --- |
| 本仓开发 Agent 的协作与工程纪律 | 根 `AGENTS.md` 与 `docs/agents/development-workflow.md`；不是产品 authority |
| 任务运行语义与职责 | `contracts/task-runtime.md` 与 ADR-007 |
| 独立检查输出 | `contracts/check-result.schema.json`，由检查调用与结果校验使用 |
| 真实验收事实 | `reference/orbit-runtime-acceptance-20260914.md`（事实记录，无裁定权） |
| 架构决策 | `docs/adr/` |
| 前瞻计划 | `docs/plan/vision-completion-plan.md` |
| 欠账 | `docs/plan/debt-ledger.md` |

`docs/` 下的散文描述若与 `contracts/` 或 ADR 冲突，以后者为准。仓库根 `AGENTS.md` 是**开发 Agent 的客户端纪律**，不是产品 authority。

## 无裁定权的层

`history/` 与 `reference/` **没有裁定权**。可以链接它们说明来源，但：

- 不得从它们开始改动——先改有权威的那层，再让它们跟进。
- 不得让现行结论**只**指向它们；必须同时指向 `contracts/` 或 ADR 的权威正文。
- `history/` 里的状态描述是**写作当时**的事实，不是现在时断言。

ADR 引用 `history/slice6-handoff.md` 与 `slice6-workorder.md` 属**溯源引用**，合规；但任何"现在应该怎么做"的结论都不能只以它们为据。

# 测试爆炸与工程纪律事故背景（Boom of Test Case）

> 2026-08-11 治理更新：本文此前是 AGENTS.md（工程与测试规范）的全文复制，已删除以避免双源漂移。现在本文只保留事故背景、跨 Agent 结论与正式落点索引；具体规则正文见对应 ADR/contract 与 [AGENTS.md](../../AGENTS.md)（客户端提示）。

## 事故背景

实际项目执行中出现"为覆盖用例无限扩测试、弃主线任务不管"的失控模式，伴随：

- 审核标准不断移动（每轮追加证明要求，十几轮不闭合）；
- 一次性验收被扩成永久测试、动态数据被固化为稳定断言（数据库快照当程序契约）；
- 补丁链几十轮失控、复审范围无限扩大、恢复路径补造缺失正文；
- 换 agent/对话后预算与止损状态丢失，重复同一方向。

## 跨 Agent 结论

这些现象不是单次执行失误，而是**控制循环缺少与具体 agent 无关的权威边界**：测试预算、完成标准、止损判据依赖对话上下文与 agent 自报，任何新 agent/新对话都可重置。因此产品化方向是 agent-independent control（详见 [alpha_test_result.md](./alpha_test_result.md) 十项状态矩阵与 [orbit-v2-agent-independent-control-amendments.md](./orbit-v2-agent-independent-control-amendments.md)）。

## 正式落点（design accepted，runtime not implemented）

设计来源：[orbit-v2-agent-independent-control-amendments.md](./orbit-v2-agent-independent-control-amendments.md)（仅 provenance；正式落点以 ADR 为语义合同，plan 为 delivery/acceptance mapping，不得覆盖 ADR）。

| 结论 | 正式落点 |
|------|---------|
| 测试数量上限与优先级 | [AGENTS.md](../../AGENTS.md)（客户端纪律，10/300 为仓库初始 default）→ [ADR-006 Amendment 节：跨 Agent test budget](../adr/006-serialized-lead-orchestration-control-loop.md) + [plan Slice 2](./orbit-v2-implementation-plan.md) |
| 动态数据不固化为断言、验收证据与测试分离 | [ADR-004 决策七：verification_class/verification_use](../adr/004-role-rule-context-evidence-binding.md) + [plan Slice 3](./orbit-v2-implementation-plan.md) |
| 完成标准冻结、审核标准不得移动 | [ADR-004 决策七：closure_basis_digest](../adr/004-role-rule-context-evidence-binding.md) + [plan Slice 2](./orbit-v2-implementation-plan.md) |
| 防循环修复、止损、补丁链封顶 | [ADR-006 止损条款](../adr/006-serialized-lead-orchestration-control-loop.md) + [ADR-006 Amendment 节：continuation envelope/bounded runner](../adr/006-serialized-lead-orchestration-control-loop.md) + [plan Slice 2](./orbit-v2-implementation-plan.md) |
| 恢复不得补造缺失正文 | [ADR-006 Amendment 节：recovery](../adr/006-serialized-lead-orchestration-control-loop.md) + [plan Slice 2](./orbit-v2-implementation-plan.md) |
| 测试只是辅助验证、不能阻塞主线 | [AGENTS.md](../../AGENTS.md)（客户端纪律）；产品 authority 在 [ProjectPolicyRevision/TaskRevision contract](../../contracts/orbit-v2/contract.yaml) |

## AGENTS.md 定位

仓库根 [AGENTS.md](../../AGENTS.md) 是**支持读取该文件的开发 Agent 的客户端纪律**，不是 Orbit 产品 authority；其规则约束读取它的 agent 行为，不产生任何 gate/evidence/state 事实。产品 authority 是 active `ProjectPolicyRevision` / `TaskRevision` 与受控 writer/validator；两者冲突时以产品 authority 为准。

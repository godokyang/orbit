# Orbit 文档入口

文档分清两件事：当前产品行为（以[任务运行合同](../contracts/task-runtime.md)为权威）与设计决定/证据边界。源码版本从 `package.json` 读取；用户安装版须核对 `orbit version --json`，不能由源码或旧验收报告推断。

## 当前阅读入口

| 需要了解什么 | 权威入口与边界 |
| --- | --- |
| 安装和使用 | [README](../README.md)、[进阶使用参考](reference/usage-reference.md)；只说明已接线行为 |
| 当前任务、模型、检查、完成与停止语义 | [任务运行合同](../contracts/task-runtime.md)、[检查结果 schema](../contracts/check-result.schema.json) |
| OMP 单宿主协作决定 | [ADR-008](adr/008-omp-native-collaboration-base.md) |
| 用户自选模型池决定 | [ADR-009](adr/009-user-selected-model-pool.md) |
| 开发纪律、范围与验证方式 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md)；这些文件不产生产品运行事实 |
| 当前交接与现场 | [交接](plan/handoff.md) |
| 当前仍生效的限制与未测范围 | [当前限制](plan/debt-ledger.md) |
| 产品方向与设计理由 | [混合模型交付主方案](plan/mixed-model-delivery-proposal.md)（同次交付已结束，效果有范围） |
| 普通任务推荐、权限与监督修复的真实验收 | [验收记录](reference/ordinary-task-repair-acceptance-20261002.md)（0.8.1，有界范围） |
| Beacon／Zeen 长任务使用中的问题与原件证据 | [现场观察](reference/beacon-orbit-observation-20261008.md)（含 2026-10-09 Zeen 补录；问题记录，不是成功验收） |
| 长任务问题的优化顺序、责任与验收条件 | [优化实施](plan/orbit-long-task-optimization.md)（T01—T13，授权、冻结条件及分批结果） |
| 长任务优化的确定性与真实验收 | [验收记录](reference/long-task-optimization-acceptance-20261009.md)（构建、逐项范围、失败和收尾） |
| 混合模型交付逐项收口（54 项＋W1–W10） | [完成记录](reference/mixed-model-delivery-completion-20261001.md) |
| OpenRouter 映射来源与理由 | [映射来源审计](reference/openrouter-model-mapping-audit.md) |
| 工程经验 | [工程教训](reference/engineering-lessons.md) |

## 历史查阅

历史报告、各代验收与旧版本文档不再保留在当前树：用 `git show 3865b76:PATH` 查阅基线，或沿 Git 历史检索。旧报告不描述当前能力。

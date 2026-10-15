# Orbit 文档入口

产品规则以[任务运行合同](../contracts/task-runtime.md)为权威，设计理由由 ADR 记录，代码与验证进度由[交接](plan/handoff.md)记录。合同内标为“待实现”的已确认规则指导后续修改，不证明当前能力。源码版本从 `package.json` 读取；用户安装版须核对 `orbit version --json`，不能由源码、目标规则或旧报告推断。

## 当前文档

| 需要了解什么 | 权威入口与边界 |
| --- | --- |
| 安装和使用 | [README](../README.md)、[进阶使用参考](reference/usage-reference.md)；README 的目标职责单独标明待实现，操作说明不预告未接线接口 |
| 任务、模型、检查、完成与停止语义 | [任务运行合同](../contracts/task-runtime.md)、[检查结果 schema](../contracts/check-result.schema.json) |
| 面向集成方（如 Loom）的命令、字段、能力与合同版本 | [集成合同](../contracts/integration.md)（机器可读版 `contracts/integration.json`）、[ADR-010](adr/010-integration-contract.md)、[实施计划与提案评估](plan/loom-integration-contract.md)；合同版本与软件版本独立 |
| OMP 单宿主协作决定 | [ADR-008](adr/008-omp-native-collaboration-base.md) |
| 用户自选模型池决定 | [ADR-009](adr/009-user-selected-model-pool.md) |
| Agent 自主判断与程序职责调整 | [ADR-011](adr/011-agent-autonomy-and-runtime-responsibility.md)；已确认、待实现，部分替代 ADR-008/009 的旧限制 |
| 开发纪律、范围与验证方式 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md)；这些文件不产生产品运行事实 |
| 当前交接与现场 | [交接](plan/handoff.md) |
| 当前仍生效的限制与未测范围 | [当前限制](plan/debt-ledger.md) |
| 工程经验 | [工程教训](reference/engineering-lessons.md) |
| Zeen／Loom 使用体验与后续讨论 | [2026-10-15 使用体验复核入口](reference/orbit-experience-review-20261015/README.md)；汇集原始反馈、证据复核与待讨论议题，不替代产品合同 |
| OpenRouter 映射来源与理由 | [映射来源审计](reference/openrouter-model-mapping-audit.md)（随包映射数据在 `lib/orbit/data/openrouter-model-map.json`） |

## 历史查阅

历史方案、各阶段计划、验收记录、证据原件和研究报告不再保留在当前树，以免干扰后续开发。需要时用 `git show aa089bb:<原路径>` 查阅（`aa089bb` 是整理前的基线提交，位于 `main`），例如 `git show aa089bb:docs/reference/mixed-model-delivery-completion-20261001.md`；`git ls-tree -r --name-only aa089bb docs` 列出当时的全部文档，也可用 `git log --diff-filter=D -- docs` 沿历史检索。更早的历史基线是 `3865b76`。旧报告不描述当前能力；产品规则按合同与 ADR 中的实施标记区分，实际进度查交接，未测范围以[当前限制](plan/debt-ledger.md)为准。

# Orbit 文档入口

产品规则以[任务运行合同](../contracts/task-runtime.md)为权威，设计理由由 ADR 记录。当前进度见[唯一总待办](plan/agent-autonomy-implementation.md)、[交接](plan/handoff.md)和[未完成事项](plan/debt-ledger.md)。源码版本从 `package.json` 读取；用户安装版须核对 `orbit version --json`。

## 当前文档

| 需要了解什么 | 权威入口与边界 |
| --- | --- |
| 安装和使用 | [README](../README.md)、[进阶使用参考](reference/usage-reference.md) |
| 任务、模型、检查、完成与停止语义 | [任务运行合同](../contracts/task-runtime.md)、[检查结果 schema](../contracts/check-result.schema.json) |
| 面向集成方的命令、字段、能力与合同版本 | [集成合同](../contracts/integration.md)、机器可读版 `contracts/integration.json`、[ADR-010](adr/010-integration-contract.md) |
| OMP 单宿主协作决定 | [ADR-008](adr/008-omp-native-collaboration-base.md) |
| 用户自选模型池决定 | [ADR-009](adr/009-user-selected-model-pool.md) |
| Agent 自主判断与程序职责 | [ADR-011](adr/011-agent-autonomy-and-runtime-responsibility.md)；阶段一与 Loom 协同的当前验证边界见交接 |
| JEV 输入、观察节奏与按需压缩的决定 | [ADR-012](adr/012-jev-purpose-specific-input-and-compaction.md)；行为规则见任务运行合同，实现和验证见交接 |
| 终检范围、结论沿用与续查职责 | [ADR-013](adr/013-final-review-scope-and-continuation.md)；实施状态见总待办 |
| 宿主接口与适配层（提议，未采纳） | [ADR-014](adr/014-host-port-interface.md)、[宿主接口合同](../contracts/host-port.md)（`host-port.json`）、[一致性测试方案](plan/host-conformance.md)；采纳前不改变现行规则 |
| 当前阶段与待办 | [唯一总待办](plan/agent-autonomy-implementation.md) |
| 当前交接 | [交接](plan/handoff.md) |
| 当前限制与未测范围 | [未完成事项](plan/debt-ledger.md) |
| 开发纪律与验证方法 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md)；这些文件不产生产品运行事实 |
| 工程经验 | [工程教训](reference/engineering-lessons.md) |
| OpenRouter 映射来源与理由 | [映射来源审计](reference/openrouter-model-mapping-audit.md)及随包数据 `lib/orbit/data/openrouter-model-map.json` |

## 历史查阅

已结束的方案、验收记录、研究报告和原始证据不保留在当前树。使用 `git log --all --diff-filter=D --name-status -- docs` 查找删除提交，再用 `git show <删除前提交>:<原路径>` 取回。历史材料不描述当前能力；当前规则以合同和 ADR 为准，未完成事项见[清单](plan/debt-ledger.md)。

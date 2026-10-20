# Orbit 文档入口

产品规则以[任务运行合同](../contracts/task-runtime.md)为权威，设计理由由 ADR 记录。当前进度见[唯一总待办](plan/agent-autonomy-implementation.md)、[交接](plan/handoff.md)和[未完成事项](plan/debt-ledger.md)。源码版本从 `package.json` 读取；用户安装版须核对 `orbit version --json`。

## 当前文档

| 需要了解什么 | 权威入口与边界 |
| --- | --- |
| 安装和使用 | [README](../README.md)、[进阶使用参考](reference/usage-reference.md) |
| 任务、模型、检查、完成与停止语义 | [任务运行合同](../contracts/task-runtime.md)、[检查结果 schema](../contracts/check-result.schema.json) |
| 面向集成方的命令、字段、能力与合同版本 | [集成合同](../contracts/integration.md)、机器可读版 `contracts/integration.json`、[ADR-010](adr/010-integration-contract.md) |
| OMP 单宿主协作决定 | [ADR-008](adr/008-omp-native-collaboration-base.md)；当前实现依据，未来迁移目标见 ADR-015 |
| 用户自选模型池决定 | [ADR-009](adr/009-user-selected-model-pool.md) |
| Agent 自主判断与程序职责 | [ADR-011](adr/011-agent-autonomy-and-runtime-responsibility.md)；阶段一与 Loom 协同的当前验证边界见交接 |
| JEV 输入、观察节奏与按需压缩的决定 | [ADR-012](adr/012-jev-purpose-specific-input-and-compaction.md)；行为规则见任务运行合同，实现和验证见交接 |
| 终检范围、结论沿用与续查职责 | [ADR-013](adr/013-final-review-scope-and-continuation.md)；实施状态见总待办 |
| 本次迁移统一 TypeScript Core 与 DSH | [ADR-015](adr/015-typescript-core-and-dsh-migration.md)；2026-10-20 修订确认 Core 同进程、受控 profile、不钉版、单包分发、凭据机制、采纳 ADR-014 义务清单、工具链七项；重写未开始 |
| TypeScript Core 与 DSH 实施计划 | [实施计划](plan/dsh-implementation-plan.md)；结构、受控 profile、义务到接缝、停止与日志设计、Loom 能力、阶段顺序 |
| JEV 观察输入在 DSH 上的投影 | [观察投影设计](plan/jev-observation-projection.md)；操作记录字段、窗口与游标、去重键、校准影响 |
| 整次迁移执行指令 | [Goal 提示](plan/ts-dsh-migration-goal.md)；交给实施 Agent 的完整指令：B/C/D 三个阶段的范围、工作区规则、顺序、用户检查点、验收、纪律 |
| DSH 宿主接缝探针结果 | [探针记录](plan/dsh-host-probes.md)；九项探针与组合断言在桌面版 0.2.1-rc.2 上的结果与实现约束；复跑方法见 `tests/host_conformance/dsh-probe/` |
| OMP 适配细节 | [OMP 适配说明](../contracts/host-omp.md)；入口、注入位置与宿主观察窗口，不改变产品规则 |
| 宿主接口与事件通路实施方案 | [实施方案](plan/host-port-and-events.md)；P0/P1/P2 原阶段依据，P3 仅为宿主接缝试验，不覆盖完整重写 |
| P2 设计与实施状态 | [P2 设计](plan/p2-design.md)；能力、进程归属与受阻项 |
| 文档对齐清单 | [文档对齐清单](plan/doc-march.md) |
| DSH 迁移讨论记录 | [DSH 迁移讨论稿](plan/dsh-migration.md)；历史讨论，当前目标见 [ADR-015](adr/015-typescript-core-and-dsh-migration.md)，重写范围见能力整合专题 |
| DSH 迁移准备与多 Agent 整合 | [工作区交接](plan/handoff.md#dsh-迁移工作区)、[多 Agent 专题](plan/dsh-collaboration.md)；调研与候选流程，不代表 P3 已开工或宿主能力已验证 |
| DSH 能力合并、重写范围与退场复核 | [能力整合与源码复核](plan/dsh-capability-consolidation.md)；保留 R1 历史及已确认产品目标，语言选择以 ADR-015 为准；不授权开始重写、删除或 P3 |
| 任务运行合同拆分计划（P1 最后一步） | [拆分清单](plan/task-runtime-split.md)；只规划，不改语义 |
| 宿主接口与适配层（提议，未采纳） | [ADR-014](adr/014-host-port-interface.md)、[宿主接口合同](../contracts/host-port.md)（`host-port.json`）、[一致性测试方案](plan/host-conformance.md)；采纳前不改变现行规则 |
| 当前阶段与待办 | [唯一总待办](plan/agent-autonomy-implementation.md) |
| 当前交接 | [交接](plan/handoff.md) |
| 当前限制与未测范围 | [未完成事项](plan/debt-ledger.md) |
| 开发纪律与验证方法 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md)；这些文件不产生产品运行事实 |
| 工程经验 | [工程教训](reference/engineering-lessons.md) |
| OpenRouter 映射来源与理由 | [映射来源审计](reference/openrouter-model-mapping-audit.md)及随包数据 `lib/orbit/data/openrouter-model-map.json` |

## 历史查阅

已结束的方案、验收记录、研究报告和原始证据不保留在当前树。使用 `git log --all --diff-filter=D --name-status -- docs` 查找删除提交，再用 `git show <删除前提交>:<原路径>` 取回。历史材料不描述当前能力；当前规则以合同和 ADR 为准，未完成事项见[清单](plan/debt-ledger.md)。

# 文档对齐清单（P0–P2）

状态：草案，2026-10-19，**未确认实施**。本文只定义代码合入后要改哪些文档，不代替各仓的文档权威。

关联：[宿主接口与事件通路实施方案](host-port-and-events.md)、[P2 设计](p2-design.md)、[活动数据路径](https://github.com/zeen-chat/loom/blob/main/docs/plan/activity-data-path.md)。

## 原则

- 一个事实一个权威：规则写在所属仓，本仓只放跨仓方案。
- 按阶段更新，不等到最后一次性补。
- 先改代码对应的合同，再改入口与索引，最后做一致性检查。
- 历史讨论保留在 Git，不用新文档覆盖旧结论。

## Orbit 仓（godokyang/orbit）

| 文件 | 改什么 | 触发 |
| --- | --- | --- |
| `docs/adr/008-omp-native-collaboration-base.md` | 补一句：单宿主不变，宿主细节收在适配层；引用 ADR-014 | P1 |
| `docs/adr/010-integration-contract.md` | 记录合同 1.8 与后续能力增项 | P0 / P2 |
| `docs/adr/014-host-port-interface.md` | 从“提议”改为“采纳”；补最终方法名与测试结果 | P1 |
| `contracts/host-port.md`、`.json` | 与实现一致；补变更记录 | P1 |
| `docs/plan/host-conformance.md` | 记录宿主版本与通过项 | P1 |
| `contracts/integration.md`、`.json` | 4.2 `events_read`；P2 能力；版本号 | P0 / P2 |
| `contracts/task-runtime.md` | 拆出 OMP 适配说明，保留宿主无关不变量 | P1 |
| `README.md`、`docs/README.md` | 入口加 ADR-014、宿主接口合同、一致性测试 | P1 |
| `AGENTS.md` | 按需加载路径补 ADR-014 与合同 | P1 |
| `docs/plan/handoff.md`、`agent-autonomy-implementation.md`、`debt-ledger.md` | 指向新阶段；更新未完成项 | 各阶段 |

## Loom 仓（zeen-chat/loom）

| 文件 | 改什么 | 触发 |
| --- | --- | --- |
| `docs/execution.md` §2 | 运行事件的两类来源；活动的性质（只展示，不产生业务事实） | P0-L |
| `docs/execution.md` §6 | 节点依赖的公开行为加 `events_read`；P2 完成后改为只依赖 Orbit 合同 | P0-L / P2 |
| `docs/integration-readiness.md` | 更新“实时对话/流式事件”一行；P2 能力状态 | P0-L / P2 |
| `docs/requirements.md` R10 | 仅在用户决定修改时：改为只依赖 Orbit 集成合同 | P2 |
| `docs/implementation.md` | 节点合同、活动字段、迁移号 | P0-L |
| `docs/workflows.md` §5 | 仅在活动接入 30 分钟规则时更新输入 | 后续 |
| `AGENTS.md` | 读取路线补新文档 | 各阶段 |

## 本仓（godokyang/orbit）

| 文件 | 改什么 | 触发 |
| --- | --- | --- |
| `docs/plan/host-port-and-events.md` | 状态从“讨论稿”改为执行记录；逐阶段勾完成项 | 各阶段 |
| `docs/plan/dsh-migration.md` | 已修正；保留为讨论记录，实施以实施方案为准 | 阶段 0 |
| `docs/plan/p2-design.md` | 三个未决问题落定后更新结论 | P2 |
| `docs/plan/activity-data-path.md` | 迁移号与最终列名 | P0-L |
| `README.md` | 指向实施方案、P2 设计、活动数据路径 | 各阶段 |

## 完成条件

- 两仓入口文档都能在一个跳转内找到新合同；
- 没有第二份规则副本；
- 旧路径删除后，没有文档仍描述旧行为；
- 文档里的版本号与 `package.json`、迁移号一致。

## 检查方式

1. **链接**：所有相对链接目标存在。
2. **关键词**：旧协议名不再出现在核心文档（历史 ADR 的对比说明除外）。
3. **对读**：合同字段与代码字段逐项一致。
4. **反查**：从 Loom 的 `execution.md` 出发，能否只经 Orbit 集成合同找到实现，不需要知道宿主。

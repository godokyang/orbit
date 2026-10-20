# Orbit 当前交接

本迁移分支的源码基线为 **0.8.22**，集成合同为 **1.8**。源码交付不代表发布或更新用户全局安装；实际安装版本须单独核对。

## DSH 迁移工作区

2026-10-20 用户授权迁移前期准备，**暂不开始 P3**。完成多 Agent/能力复核及产品定位讨论后，用户选择本次迁移重写 TypeScript/Node.js Core，并明确“先继续完善文档”。联合复核后，用户另行授权将这批文档提交并推送到新分支；当前仍不实施重写或 DSH 适配，不安装或发布。

| 项目 | 当前事实 |
| --- | --- |
| 工作区 | `/Users/yangke/Personal/workspace/ai-tools/orbit-dsh`，与原仓同级的独立 Git worktree |
| 分支 | `docs/dsh-typescript-migration-plan`，从准备分支 `feat/dsh-migration` 新建，用于提交和推送已复核文档 |
| 创建基线 | 本地 `origin/main` 的 `2c6c3a1d6013d447cdae18020bb934b2c0de7258`，创建时与本地 `main` 一致；未 fetch，不宣称远端此刻无更新 |
| 原工作区 | `/Users/yangke/Personal/workspace/ai-tools/orbit`，仍在 `main`；不在该目录写本轮文档成果 |
| 环境边界 | 本轮未安装 DSH、未配置模型或凭据；新工作区不继承原仓的 `.env` 和 `.orbit` 运行记录 |
| 研究来源 | DSH `0.2.1-rc.2`，官方提交 `687f282e8625c6b8d11ff58211a90524be2e4317`；仅静态资料与局部源码核对，未跑 DSH 探针 |
| 文档入口 | [能力整合与源码复核](dsh-capability-consolidation.md)；[多 Agent 调研与整合方案](dsh-collaboration.md)；[分阶段实施方案](host-port-and-events.md) |

后续会话以该工作区为项目目录，先读本文、[文档入口](../README.md)与[总待办](agent-autonomy-implementation.md)。本次只准备源码工作树与文档，不把它宣称为已安装、可运行的 DSH 环境。

P1 已有协议改名、适配目录迁移和合同拆分；P2 的 Orbit 侧公开能力已落地。原方案中的真实一致性探针、核心收口和 Loom 整链验收不能只凭“已实现”标签认定完成。相关历史文档存在草案标题与后来实施记录并存的情况；本轮不重新验收 P1/P2，也不把这些缺口变成本次准备工作的阻断。

后续迁移目标为 TypeScript Core + DSH，决定见 [ADR-015](../adr/015-typescript-core-and-dsh-migration.md)；[重写范围与切换条件](dsh-capability-consolidation.md#typescript-重写与切换条件)已记录。原 P3 保留为宿主接缝试验，不能把其“写适配层”范围或时限当作完整重写承诺。当前可运行实现仍为 Ruby/OMP，集成合同、完成与停止语义不变。

用户随后确认迁移后保留独立 Coding Agent 使用、在 DSH 应用内提供受控入口、延续 Orbit 证据反馈闭环。目标与验收条件已写入[总待办](agent-autonomy-implementation.md#已确认的迁移产品目标)，理由与边界见[产品定位补充](dsh-capability-consolidation.md#用户确认补充独立使用应用入口与证据反馈)。该补充晚于 R1 联合复核，未冒用其确认记录；目前仅完成文档，不代表 DSH 应用接入或数据闭环已实现，P3 仍未开始。

### 本轮验证边界

- 已在迁移 worktree 运行源码 `scripts/orbit version --json`，返回 `0.8.22`；运行 `launch --socket … --resume … --json` 正常返回 OMP 启动规格，没有创建会话或调用模型。
- 上述冒烟只证明当前 Orbit 源码入口可从新工作区使用，不证明 DSH 已安装、可启动或通过迁移验收。
- 本次 TypeScript 重写文档修订后，重新运行迁移工作区的文档链接检查，仍为既有 3 处断链，未新增；原项目此前报告相同结果。既有问题位于 `contracts/task-runtime.md`、ADR-011 和 `docs/plan/task-runtime-split.md`，不在本次修复范围。
- 后续源码复核实际运行 `capabilities --json`（0.8.22／合同 1.8）并执行无文件的协议样例：旧 Orbit 投影可读 OMP 样例，却不能读 DSH 格式样例。该结果只证明迁移接缝，不是 DSH 真会话测试。
- R1/C1–C15 保存此前联合复核的功能处置、双方差异、兼容路线与固定来源；R1 的“保留 Ruby”已由后续用户决定替代，其确认记录不覆盖 TypeScript 重写。此前 9 个本地和 31 个固定上游引用核验通过，临时 checkout 已清理；该证据不证明新核心或 DSH 真实运行。
- 本次新文档由用户指定的相邻 OMP `w28:p2`（会话 `01a1585f-0096-70e9-bac5-1bd1e81ff2cf`）独立复核。对方提出 3 项阻断及 8 项建议；双方核对反例、收紧过强论断并修订后，对方再次读取修订段、核对版本，明确确认“同意此版本TypeScript重写+DSH文档方案；当前无未解决分歧”。这次确认与原 R1 分开，只证明文档方案已联合复核，不代表 P3、重写、安装或真实运行验收完成。
  - 确认版本 SHA256：`docs/adr/015-typescript-core-and-dsh-migration.md` 为 `7d37099f9815f706ffa772839a357ddbaebb5a8c818cca25f18141485b2452ff`；`docs/plan/dsh-capability-consolidation.md` 为 `a1cf752af22306745e284693705979baf5d7a2fd74290742f51d14ee5c62fbcc`。关联索引、总待办及阶段/一致性方案的修订同步复核；后续只追加交接结果，并按用户新授权更新分支和提交推送边界，未改上述两份确认稿。

### 2026-10-20 审计、决定与宿主探针

- 本机工作区为 `/Users/dy/Workspace/orbit`（分支同上）；上文的 `/Users/yangke/...` 路径是另一台机器的。
- 对迁移方案做了审计并与用户讨论，用户确认七项决定，已写入 [ADR-015 修订](../adr/015-typescript-core-and-dsh-migration.md#2026-10-20-修订)；实施依据见[实施计划](dsh-implementation-plan.md)。
- 在隔离的 `DSH_HOME` 下用桌面版 0.2.1-rc.2 的 `dsh` 跑了九项宿主探针与组合断言，全部通过，结论与实现约束见[探针记录](dsh-host-probes.md)，脚本在 `tests/host_conformance/dsh-probe/`。探针用假模型驱动真实 agent 循环，不是真实模型验收，也未接 Loom。
- 本机 `~/Workspace/deepseek-harness` 已更新到 687f282e。未改产品代码，未安装 Orbit，未提交。
- 上文"本轮验证边界"记录的 ADR-015 确认版 SHA256 对应修订前的文件；今日追加的"2026-10-20 修订"节按用户授权写入，**不在相邻 OMP 的联合复核范围内**，尚未经第二方复核。

## 当前实现

已确认需求见[总待办](agent-autonomy-implementation.md)，运行规则见[任务运行合同](../../contracts/task-runtime.md)。JEV 输入与按需压缩、终检范围与续查均已实现。Root 决定何时交卷，检查者判断成果，程序记录版本、完成与停止事实。

## 原有功能的验证边界与待办

相关自动化回归及独立复核通过。隔离真实运行验证了普通交付、明确过程审计中的纠偏和实际停止；自动续查与模型阻塞恢复目前仅有确定性回归，未在真实模型中自然触发。JEV 检查者选型的正向校准样本有限，既有真实完整路径使用启动事实降级，不能据此宣称所有选型分支均已真实贯通。

原有功能的未完成验证及收口条件见[缺口清单](debt-ledger.md)。此前功能交付的测试进程、临时项目、隔离安装、测试会话和中间证据已有清理记录；该历史说明不覆盖本轮迁移工作区。本轮工作区与迁移文档保留用于后续准备，其他任务的 Loom 资源不属于本次范围。

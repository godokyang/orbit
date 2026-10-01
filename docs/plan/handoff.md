# Orbit 当前交接

最后核对：2026-10-01（installed 0.7.37 / commit `4cc957e374300b9598f4e02bce5c3920f9bc97dc` / digest `9662512a…` / full 197.31956s exit 0 / 83 pack 逐字一致）。

## 目标与既有授权（不变）

- 完整实现并真实验收[混合模型交付主方案](mixed-model-delivery-proposal.md)：原 54 项（A01–F10）＋W1–W10，逐项判定见[完成记录](../reference/mixed-model-delivery-completion-20261001.md)。
- 有限顶级模型资源；不设硬预算；选型无时间信号；本地 commit／install 已授权，不推送／发布／tag／升级 SDK／购买额度；未知费用／用量／额度归属保持未知，不当免费。
- Codex 编排审核＋Q（Herdr OMP）执行；源码／合同语义改动同步权威文件；失败证据不改判。

## 当前状态（唯一生效安装）

- **installed 0.7.37**＝commit `4cc957e`（release `29fba720cde2c6cd01c5e019`）；full 197.31956s exit 0；83 pack 与安装逐字一致。
- **最终文档票 diff 已备**（完成记录＋合同/ADR/plan 状态同步），待 Root 复核后执行 W10 本地交付（doc-only commit＋安装核对）。
- 历史各代版本流水、失败与中间状态**不在本页复制**：Git（`451bff2` 及以前）、[2026-09-29 验收记录](../reference/mixed-model-real-acceptance-20260929.md)、`/private/tmp/orbit-*` 原件。

## 有效核心证据（原件绝对路径）

| 事实 | 原件 |
| --- | --- |
| 自主成员真实完整链（hint→派发→注册→accepted→集成→manual 终检→confirmed stop）＋旗舰 +134.665% 负例（0.7.25 构建） | `/private/tmp/orbit-reconcile-pair4-iW4p7Z/` |
| 强 checker 真实发现→Root 纠正→resolved→confirmed stop（0.7.33） | `/private/tmp/orbit-stuck-immutable-qldLdA/` |
| 35 失败原件（fallback 丢 kind→36 修复成因；stop_unconfirmed→37 修复成因）——**失败不改判** | `/private/tmp/orbit-blocked-write-fixture-0M7g/` |
| 过程 fallback 保通道＋非 stale 合法阻断 confirmed stop（0.7.36/37 live） | `/private/tmp/orbit-regress-fixture-BuEx/` |
| W9 同质量配对（两臂 6/6＋20/20；旗舰 observed 0 vs 7；分类 unknown 保留） | `/private/tmp/orbit-w9-pair-LUKH/controller-records/`（`ROOT-W9-RESULT-REVIEW.json`） |
| 单文件负例（真实普通 entry 不启动；entry 原件 819/63） | `/private/tmp/orbit-entry-negative-wvKE/controller-records/`（`ROOT-NEGATIVE-REVIEW.json`） |
| Root 54 项逐项完成审计 | `/private/tmp/orbit-stop-guard-037/ROOT-54-CURRENT-COMPLETION-AUDIT.json`（同目录 CORE/D07/最终文档 diff 原件） |

未测自然分支（Root-stage switch live、非 stale process finding 恢复、37 marker 精确复现、failed-unit 释放）清单见[完成记录](../reference/mixed-model-delivery-completion-20261001.md)与[当前限制](debt-ledger.md)——不是完工门，不新造证明。

## 现场资源

- Q 可用、idle；S 额度不支持（不重试）；R 无工具已停。
- `w1Y:p26` 仅剩 shell 33047；全部 SUT/checker/MCP 进程已退出。
- `/private/tmp` 全部证据与原件保留、未覆盖；归属不清的历史 worktree 保留不删。

## 剩余动作（唯一路径）

1. Root 复核最终文档 diff → 授权本地 commit（doc-only）＋安装核对 → W10 勾选、Goal 完成。
2. 不重开 W9／派发／负例等已完成项；自然未测分支随未来普通运行累积。

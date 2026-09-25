# Orbit 当前计划

当前状态（源码 0.7.1、本机无安装，2026-09-25）：单一 OMP 宿主的 M0–M3 已实现并通过确定性测试与本机安装切换；历史验收安装是 0.6.18（digest `06dba0f1db005f82…`，installed_at `2026-09-24T21:55:54Z`；本机当前无该安装）。**冻结 #9 已 PASS**（staged `0bc4ec93`：成员独立面→中期 fresh finding F1→`correction_sent`→同 Root 修复→终检 `resolved_ids=['F1']`→显式 stop）；**0.6.18 live JEV 费用门事实**：`subscription_quota` typed 证据请求/提交/缓存新增/三问（0.54/0.30/0.57）declined 全链留证（`249935cc`）；L1（`42d1977e`）无 hint、无成员；stale finding 经复核 resolved，无 `correction_sent`。K3 只证明无成员 finding 纠偏收敛；GLM 中文与英文同模型对照都 stage2 declined，不算成员正样本，也不认定语言是原因。J 的 member-v2 终态仍是 `failed`。**M4 整体闭合——冻结 #1–#9 全部通过**（#5 为用户批准的组合证据 PASS：同版本重复纠正确定性回归证明、纠偏收敛与过期拦截真实任务证明；`finding_repeat_ignored` 未真实触发已注明；hint 正样本为后加跟踪项；`61bbd66d` 只是显式派发的机械路径正样本；`c8d89ea6` 只证明有成员在途时的异常停止确认，不计完成）。**唯一执行队列是[单一 OMP 改版总 TODO](omp-native-migration.md)**，本文件不再维护第二份待办。历史上曾重新安装 0.6.18 并通过门禁（该安装本机现已不存在）；模型侧 typed 费用路由与三问 declined 已 live 实测（0.6.18 `249935cc`）；缺的正样本 hint 为可选跟进、非阻塞。运行语义以[任务运行合同](../../contracts/task-runtime.md)与 [ADR-008](../adr/008-omp-native-collaboration-base.md)为准。

## 历史阶段（已结束，保留结论与链接）

- **独立任务运行与真实验收（2026-09-14）**：独立任务进程、原文与指定依据留存、固定内容快照、约定时间检查、向已有 Root 投递纠正、按需独立裁定与原生停止确认；旧运行架构已整体删除，无兼容层。见[底层真实验收](../reference/orbit-runtime-acceptance-20260914.md)。
- **日常流程交付**：Codex 原生 TUI 入口、MCP、受控执行成员、结果回收与整项停止；见[日常使用交付计划](user-experience-plan.md)与[用户流程验收](../reference/user-flow-acceptance-20260914.json)。
- **安装、更新与版本管理**：远程固定提交、失败保留旧版、按 lease 保留旧 release、skill 由 npx skills 独立管理；见[进阶使用参考](../reference/usage-reference.md)。
- **OpenCode 与 OMP 正式接入（历史路径，已由 ADR-008 取代）**：见 [OpenCode 验收](../reference/opencode-runtime-acceptance-20260914.json)、[OMP 验收](../reference/omp-runtime-acceptance-20260914.json)。
- **执行协作与检查回路调优、JEV 委派判断、用户结果补齐**：见[总调优计划](orbit-execution-review-optimization.md)、[JEV 委派判断专项计划](jev-delegation-optimization.md)、[用户结果补齐计划](user-outcome-completion-plan.md)。
- **历史多宿主接入顺序**（pi、Kimi Code、Grok、dsh、Cursor Agent）已取消；目标改为 ADR-008 的单一 OMP 路径，其他宿主不再是待办。

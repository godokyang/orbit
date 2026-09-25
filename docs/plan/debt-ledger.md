# Orbit 当前限制

最后核对：2026-09-25（OMP 单宿主改版；冻结 #1–#9 全部通过，#5 为用户批准的组合证据，M4 整体闭合）。这里只保留影响当前使用的缺口；已删除架构（Codex／OpenCode 宿主与旧 SDK 成员）的欠账不再构成待办，其历史验收证据保留在 `docs/reference/`。当前语义见 [ADR-008](../adr/008-omp-native-collaboration-base.md) 与[任务运行合同](../../contracts/task-runtime.md)；未验收项见[迁移总 TODO](../plan/omp-native-migration.md)。

| 限制 | 当前影响 | 继续处理的条件 |
| --- | --- | --- |
| 目标路径端到端真实验收（冻结 #9）已通过，M4 已整体闭合 | 冻结 #9 端到端已于 0.6.17 取得 PASS 真实样本（staged `0bc4ec93`：原生成员独立面+独立检查发现 finding F1+`correction_sent`+同一 Root 修复+终检 `resolved_ids`+显式 stop）；**M4 整体闭合：冻结 #1–#9 全部通过**（#5 为用户批准的组合证据 PASS——同版本重复纠正由确定性回归证明、纠偏收敛与过期拦截有真实任务证据，`finding_repeat_ignored` 未真实触发已注明；旧'全真实证据'冻结头句对 #5 此项经用户批准例外），#6 机械回路已 PASS（活 adjudicator 只读/指纹证据），矛盾夹具（W38/W39）的裁定内容不计 | 例外与限制已注明；hint 正样本为后加跟踪项 |
| 已 park/dispose 成员的后台退出不可证实 | 默认路径可证实：`orbit omp` 进程叠加 `task.agentIdleTtlMs=0`（`plugins/omp-idle-parking.yml`，用户显式 `--config` 仍可覆盖），已完成成员的 session 保持 attached，桥可核对其 turn、挂接进程与 owner-scoped 作业并给出 `confirmed=true`（实测：`0bc4ec93`、B3 `122167ec`）。**残余限制**：仅当用户显式覆盖使成员 park，或异常 park 后 session 已不在时，OMP 18.2.8 的 park/release 先 detach 再异步 dispose、无公开完成信号，桥只能给出结构化证据并保持 `stop_unconfirmed`，不能把"已完成"或注册表 idle 当退出证据 | 上游提供 dispose 完成信号（如导出 AgentLifecycleManager 或 park/release 完成回调）后残余路径改为可确认；参见 M0.3；冻结 #7 结论不变 |
| 协作观察缓冲易失 | hub/task 观察是进程内按任务隔离的有界缓冲（500 条，超出丢最旧）；TaskRuntime 已消费并把关键事实（成员登记/拒绝、结果回收、投递）持久记录到任务目录，真正缺口是 OMP 进程退出后未消费的缓冲事件丢失，无法找回 | 消费方及时轮询即可覆盖关键事实；全量事件持久化需上游事件流接口或后续接线，当前不声称完整持久观察 |
| `devin-agent` 类模型 | 不触发 `before_provider_request`；登记强门在 `tool_call`（provider 无关）不受影响，但该 provider 的成员缺少钩子层核对记录 | 成员模型策略拒绝此类模型，或上游补等价接缝 |
| 上游 OMP 接口缺口 | 单成员编程 kill 需 `AgentLifecycleManager`（未从 SDK 导出）；`before_provider_request` 异常被吞、不能 fail-close；分配器对保留前缀应拒绝重复而非加后缀 | 按 ADR-008 决定 7 跟进上游；出现实证阻断时评估最小补丁，不预维护 fork |
| 历史读取有前置条件 | 只接入已加载、具备历史读取能力的持久会话；ephemeral 或尚未物化的会话不可用 | 原生接口提供相应能力且有明确使用需求后再适配 |
| 整次任务费用可能未知 | 检查 tokens 可记录，Root 会话累计量可能混入先前工作，尚无跨供应商费用总计和 token 硬上限 | 有真实用量来源与任务归属后轻量补齐；不阻塞主线或从耗时推算费用 |
| 自动检查者选模的 JEV 消耗不在任务用量汇总内 | `orbit start` 在创建任务记录前调用 JEV 判定池内检查候选的质量，其 usage 与 monotonic 耗时记录在 `review.selection`（`usage`、`quality_elapsed_seconds`），但不进入 `state.usage` 的 `jev_stage1`/`jev_stage2`/`check_tokens`/`root_session_cumulative` 汇总；任务级 token 总数不含这部分 | 将选模消耗接入运行时用量汇总（TaskRuntime 侧）后移除该限制；在那之前，任务级 token 总数不声称覆盖自动选模调用 |
| 真实路径验收仍有未覆盖分支 | finding 同版本 repeat/reopen 分支仍只有确定性回归（Pi 审计论证活回路结构性难触发，记为结构性未触发、不再排期）；observation 去重与目标路径检查回路（含成员+纠偏）已有端到端真实样本（#9 staged） | 不重复已跑路径；同版本重复分支维持确定性回归覆盖 |
| 独立检查真实 token 成本仍高 | 历史复验已把重复检查明显收敛，但单次检查 input 仍在数万到数十万量级 | 继续采集 prompt 构成与供应商计费口径；任何压缩都须同时核对缺陷发现率、完整要求覆盖和 stale 行为 |
| 工作区冲突不会自动暂停检查 | 程序不检测 Root 声明的产物位置是否与绑定冲突，也不因此暂停自动完整检查 | 有单独的检测与暂停设计并完成真实路径验收后，再从限制中移除 |
| 语义同义 finding 不自动合并 | 程序不做语义猜测，只能靠检查者 prompt 复用已有 finding id | 若真实验收显示检查者经常换 id 重开，再决定是否增加显式对照 |
| 效果验证仍有限 | 既有样本未观察到 Jev 过程检查增益或完整检查减少，也未证明复杂日常任务普遍省额度 | 继续在真实任务中记录结果、检查成本与人工纠偏；若默认启用显示明显损害，报告并重新讨论 |

Root 运行故障仅记录，不建设自动替换或恢复。新供应商、全局调度、需求讨论管理和复杂统计平台不因列在限制中自动获得实现授权。

历史已修复记录（2026-09-14 至 2026-09-22，含停止队列、过期检查原因、lease 保留、Codex 权限单一权威、JEV 两阶段与模型证据、worktree rebind、observation 去重等）见 Git 历史与 `docs/reference/` 下对应验收记录；这些修复属于已退役的 Codex／OpenCode 入口或其宿主无关部分，不再作为当前入口的现行事实重复列举。

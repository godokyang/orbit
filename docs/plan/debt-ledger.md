# Orbit 当前限制

最后核对：2026-09-22。这里只保留影响当前使用的缺口；已删除架构的欠账不再构成待办。当前语义见 [ADR-007](../adr/007-task-runtime-refactor.md) 与 [任务运行合同](../../contracts/task-runtime.md)。文档口径版本 0.6.12。

| 限制 | 当前影响 | 继续处理的条件 |
| --- | --- | --- |
| Codex TUI 的权限边界与 profile | `orbit codex` 已改为“单一策略 + TUI 专用透明代理”：界面内 `/new`、`/resume`、`/fork` 与首次启动得到同一权限，Orbit 控制仍直连 `control.sock`。剩余边界：`-p/--profile` 首版明确拒绝（未新增 TOML 解析）；`sandbox_workspace_write` 等未纳入改写的权限形态仍可能被 Codex 原生拒绝远端恢复；其他直接 `codex --remote … resume` 与本入口无关 | 出现真实 profile 需求时再评估配置解析或等待 Codex 原生支持；不扩大代理改写字段 |
| 旧 release 清理时机 | 仍有存活 lease 的旧 release 保留到持有进程退出后的下一次安装；长期不更新的安装可能多保留一份 release 的磁盘占用 | 出现实际磁盘或发布需求时再做后台清理或显式清理入口 |
| 现有 Codex 嵌入式会话不能热接入 | orbit codex 已跑通日常入口和显式恢复原会话；普通已打开的 embedded TUI 仍缺少原生端点 | 用户明确停止当前工作后，从 orbit codex resume 恢复原会话；没有已验证接口时不自动迁移 |
| 历史读取有前置条件 | 只接入已加载、具备历史读取能力的持久会话；ephemeral 或尚未物化的会话不可用 | 原生接口提供相应能力且有明确使用需求后再适配 |
| 停止确认范围有限 | 确认 Root、本任务登记成员、各自原生后台命令和自有检查进程；OpenCode 已覆盖原生会话及其 shell 附属进程树，OMP 覆盖各会话 owner 的原生后台任务并等待实际结束；OpenCode Root 的 `kind: codex` 跨宿主成员另覆盖成员 turn、宿主登记后台终端和成员 app-server 进程组退出 | 只声明已验证的 kind 与路径；其他 kind、其他宿主、未登记 Agent、脱管进程或任意外部副作用仍需分别验证，不凭单一回包扩张能力声明 |
| 整次任务费用可能未知 | 检查 tokens 可记录，Root 会话累计量可能混入先前工作，尚无跨供应商费用总计和 token 硬上限 | 有真实用量来源与任务归属后轻量补齐；不阻塞主线或从耗时推算费用 |
| 真实路径验收仍有未覆盖分支 | 隔离临时项目已真实跑通小任务负样本、JEV 两阶段提示、显式 Codex 成员、成员结果回收、真实 finding 修复、worktree rebind 与 workspace stale。finding 同版本 repeat/reopen 及 observation 去重的每个分支仍只有确定性回归 | 按 [优化真实验收记录](../reference/orbit-optimization-acceptance-plan-20260922.md) 补真实分支；已跑路径不再重复冒充待验收 |
| Codex Root 尚不能把 Herdr 中任意快模型作为 Orbit 成员 | 本次 Codex Root 的实际 callable 成员是同模型 Codex；Herdr 能看到 OMP、OpenCode、Cursor pane 不等于 Orbit 拥有其任务级投递、结果回收和停止适配。因此 JEV 当前不能把网上的 Flash 速度优势变成这条链路的并行收益 | 用户明确选择下一条跨宿主组合，且能沿原生控制面实现任务归属、结果回收和停止确认后单独建设与验收；不以 pane 按键模拟产品能力 |
| 独立检查真实 token 成本仍高 | 0.6.12 严格复验已把小任务和双工作面终检收敛为各一次 fresh reviewer，input 分别为 `76,393` 与 `75,585`；in-flight rebind 从旧样本四次 `531,726` input 降为两次 `284,580`。重复检查明显减少，但单次仍约 7.6 万到 19 万 input，`review_focus` 的真实存在不等于已证明显著单次压缩 | 继续采集 prompt 构成与供应商计费口径，减少重复上下文；任何压缩都须同时核对缺陷发现率、完整要求覆盖和 stale 行为，不能只看 token |
| 工作区冲突不会自动暂停检查 | 显式 rebind 与 workspace stale 已进入合同。程序不检测 Root 声明的产物位置是否与绑定冲突，也不因此暂停自动完整检查 | 有单独的检测与暂停设计并完成真实路径验收后，再从限制中移除 |
| 语义同义 finding 不自动合并 | 同一 finding id 已 open 且输入、产物目录、产物摘要、requirement、evidence、action 都未变化时，重复报告记 `finding_repeat_ignored`，不再次纠正 Root；任一维度变化才重新投递。已 resolve 的同一 id 在这些证据都未变化时不重开。换一个新 id 描述同一问题，程序不做语义猜测，只能靠检查者 prompt 复用原 id | 若真实验收显示检查者经常换 id 重开，再决定是否增加显式对照，而不是在程序里猜测语义 |
| 效果验证仍有限 | 已用受控真实缺陷、持续编辑任务和 0.6.2 新宿主会话核对过期重核、自动投递、Jev 记录与用量；既有样本未观察到 Jev 过程检查增益或完整检查减少，也未证明复杂日常任务普遍省额度 | 继续在真实任务中记录结果、检查成本与人工纠偏；若默认启用显示明显损害，报告并重新讨论，不设单样本硬阈值 |

Root 运行故障仅记录，不建设自动替换或恢复。新供应商、全局调度、需求讨论管理和复杂统计平台不因列在限制中自动获得实现授权。

2026-09-14 本轮已修复：停止后的队列不再投递，已收到停止信号／到达硬截止时先停止再处理队列；无 Git 快照排除 node_modules、.venv、__pycache__。相关确定性测试通过。日常自然触发、原 Root 纠偏、成员回传及统一停止另有真实验收，见本轮用户流程数据。

2026-09-18 本轮已修复：过期检查按产物/输入/宿主/争议记录原因；Root 执行时完整检查不早于约定间隔；过期 `correct`/`continue` 线索传给下一次审查者检查，确认后自动投递、未核对不得完成；Jev 输入超出预算时标注省略范围。真实受控路径与持续编辑任务验证通过，见 [检查回路与 Jev 实际验证](../reference/check-loop-acceptance-20260918.md)。新增 OpenCode Root → Codex 跨宿主成员路径：任务自有 app-server、先持久登记再 `turn/start`、原生停止与运行进程异常退出后的显式停止重试，见 [跨宿主成员验收](../reference/cross-host-member-acceptance-20260918.md)。

2026-09-18 新版本安装不再删除由存活 lease 引用的旧 release：任务运行进程、`orbit codex` 会话和已加载的宿主扩展登记 pid lease；`orbit update` 保留这些 release，持有者退出后的下一次安装清理。卸载若发现存活 lease，会先拒绝并保留完整安装，避免留下无安装记录的 release；回归覆盖拒绝后正常卸载。首次从没有 lease 的旧版升级前须结束旧任务和会话，本轮不做旧版兼容。本机未重新安装，真实升级路径留待下次安装核对。同轮 CLI 修正：`failed` 任务在 `stop_confirmation.confirmed=true` 时显示“运行失败，停止已确认”，未确认时仍显示需核实。

观察程序报错会尝试收尾并如实记录；退出后仍可显式 stop 重试。不恢复模型执行。检查进程停止曾未确认时，必须核实登记进程组已不存在才能清除旧错误，证据不足继续保持未确认。

OpenCode 1.18.30 的无端口正式接入、同一 Root 纠偏、成员集成、原生中断和正常退出收尾已验证，见 [验收记录](../reference/opencode-runtime-acceptance-20260914.json)。插件需在启动时加载；检查者仍使用 Codex，OpenCode 默认检查模型仅读取 Codex 顶层配置，使用 profile 的用户应显式指定 ORBIT_REVIEW_MODEL。OpenCode Root → Codex 成员已接入并单独验收，其他跨宿主组合尚未接入；强杀宿主后不自动恢复。

OMP 18.1.16 的普通入口、同一 Root 纠偏、成员集成、原生 Esc、恢复后正常退出已验证，见 [运行数据](../reference/omp-runtime-acceptance-20260914.json)。安装应用到所选 OMP agent/profile 目录；不会跨所有 profile 自动加载。成员只开放 Root 已启用的基础编码工具，不复制扩展、MCP 或再次委派。一次开发验收取消 Codex 检查进程组时收到 EPERM，任务如实保留 stop_unconfirmed；后续核对登记进程组已不存在，没有把失败记录改写成通过。

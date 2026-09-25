# OpenCode v2 与 OMP 作为 Orbit 多 Agent 基座的调研

日期：2026-09-24。范围：本机 `opencode v2.0.12`、`omp/18.2.8`；只读上游资料与现行 Orbit 合同，不包含模型任务实测、实现或产品决定。下文“已确认”指官方文档／上游源码或本机版本输出；“推断”指适配 Orbit 的判断；“待验证”不可当作现有能力。

## 结论摘要

| 问题 | OpenCode v2 | OMP 18.2.8 |
| --- | --- | --- |
| 原生多 Agent 形态 | `subagent` 工具创建前台或后台子会话；后台完成通知父会话，返回 `sessionID` 可继续同一子会话，默认仅一层嵌套。**这是父子任务，不是已发布的任意成员互发消息的 team。** [v2 工具文档](https://opencode.ai/v2/docs/tools/) | `task` 可批量、异步创建有名称的子 Agent；结果注入父会话；`hub` 提供成员名单、点对点／广播、等待、取消、idle/parked 成员唤醒。**这是同一 OMP 进程内的原生 task/hub，并非 Orbit 当前自己通过 OMP `AgentRegistry` 创建的成员。** [v18.2.8 task](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md)、[v18.2.8 hub](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/hub.md)、[Orbit 合同](../../contracts/task-runtime.md) |
| 通信缺口 | 官方 v2 子 Agent 说明只有父会话完成通知／按 ID 继续；未见已发布的 peer mailbox/team。插件／客户端可操作特定 session，若由 Orbit 组织消息路由，那仍是 Orbit 自己的协调层。[v2 工具文档](https://opencode.ai/v2/docs/tools/)、[v2 插件 API](https://opencode.ai/v2/docs/build/plugins/) | `hub` 消息收据可区分 `injected/woken/revived/failed`；但 `IrcBus` 与 registry 是 **process-global**，不能据此推断不同 OMP 进程、其他宿主 Root 互为原生 peer。[v18.2.8 hub](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/hub.md)、[跨进程诉求](https://github.com/can1357/oh-my-pi/issues/10229) |
| 唤起判断 | 插件 `prompt`、`context`、工具前后 hook 与事件流可提供观察点；`session.prompt`／`synthetic`／`interrupt` 是执行通道，**不内含“何时值得唤起成员”的业务判断**。[v2 插件 API](https://opencode.ai/v2/docs/build/plugins/) | `advisor` 可持续审阅主 Agent transcript 增量，以 `nit/concern/blocker` 向主会话注入建议；适合候选异常／审查信号，但其判断与 Orbit 的检查、委派合同并不等价。`task` 的实际派发仍由调用 Agent 选择。[v18.2.8 advisor](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/advisor-watchdog.md)、[v18.2.8 task](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md) |

### 单一推荐

**推荐 OMP 18.2.8 的原生 `task/hub` 作为 Orbit「同一 OMP Root 进程内 Root + 子成员协作」的优先基座。** 依据是其现成的点对点消息、运行中投递、idle/parked 唤醒、异步结果、成员可见性和取消路径，比 OpenCode v2 已发布的父子 `subagent` 接口更贴近 Orbit 当前的通信痛点。[v18.2.8 task](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md)、[v18.2.8 hub](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/hub.md)、[OpenCode v2 工具](https://opencode.ai/v2/docs/tools/)

| 选择标准 | 判断 |
| --- | --- |
| 成员互相通信与唤醒 | OMP 原生 `hub` 明确覆盖；OpenCode v2 的已发布子 Agent 主要通过父会话交付结果。 |
| Orbit 程序接线 | OMP 内置能力更强，但扩展缺少官方程序化、Hub 可见的 spawn 句柄（#2574）；需先证明 Root 显式调用内置 `task` 后，Orbit 能可靠登记与控制。 |
| 跨进程／跨宿主 | OMP `hub` 是进程内通信；OpenCode v2 也没有已发布的跨宿主团队协议。两者均不能直接替代 Orbit 当前跨宿主控制。 |
| 何时唤起 | 两者提供观察和投递机制；OMP advisor 可提供额外候选信号，但最终委派／检查判断仍需 Orbit 按现行合同处理。 |

因此这是**有条件的同宿主技术选型**，不是立即整体迁移 Orbit 的决定，也不表示 OMP 已解决跨宿主协作。[程序化派发提案 #2574](https://github.com/can1357/oh-my-pi/issues/2574)、[多顶层路由报告 #10229](https://github.com/can1357/oh-my-pi/issues/10229)、[Orbit 合同](../../contracts/task-runtime.md)

## OpenCode v2：已发布能力与边界

1. **子会话。** `subagent` 接受 Agent ID、描述和完整 prompt；前台等待，后台立即返回并在结束时通知父会话，`sessionID` 用于继续。子 Agent 有自己的权限，`general` 禁止继续派发；当前官方文档写明默认嵌套深度为一。父子导航出现在 TUI。这里没有证据表明任意两个子 Agent 可彼此直接 DM。[v2 工具](https://opencode.ai/v2/docs/tools/)、[v2 Agent](https://opencode.ai/v2/docs/agents)、[v2 TUI 快捷键](https://opencode.ai/v2/docs/cli/keybinds/)
2. **可控会话接口。** v2 插件 `ctx.session` 可创建／读取会话、读取上下文、切换 Agent／模型、发送 prompt／synthetic、interrupt、wait；插件 `ctx.event.subscribe()` 与客户端事件流能观察运行变化。插件提供 RPC，可供其他插件或客户端调用自定义方法。事件订阅只提供**实时流，无重放／自动重连**，所以 Orbit 若据此驱动持久判断，恢复时需从持久会话／自身记录重建状态。[插件 API](https://opencode.ai/v2/docs/build/plugins/)、[JS 客户端](https://opencode.ai/v2/docs/build/client/)、[插件 RPC](https://opencode.ai/v2/docs/build/plugins/rpc/)
3. **判断接入点。** `prompt` hook 在用户 prompt 入库前执行一次，可改内容和 `steer/queue`；不覆盖 synthetic、shell、compaction 等消息，也不是 exactly-once 副作用边界。`context` 在 agent loop 的每次模型调用前执行，可观察 transcript 和可用工具。`tool.execute.before/after` 可观察工具动作。若做 Orbit 的独立检查触发，应按事件、会话版本和产物版本去重，不能把 hook 触发等同于需要唤起检查者。[插件 hook](https://opencode.ai/v2/docs/build/plugins/)
4. **Agent Teams 状态。** 上游有平面 Team、命名消息、自动唤醒的[设计提案 #12711](https://github.com/anomalyco/opencode/issues/12711)及 PR；截至 2026-09-24，提案仍 open，[核心 PR #12730](https://github.com/anomalyco/opencode/pull/12730) 未合并，[工具路由 PR #12731](https://github.com/anomalyco/opencode/pull/12731) 已关闭且未合并，[TUI PR #12732](https://github.com/anomalyco/opencode/pull/12732) 未合并（GitHub 上游 API 状态核对）。因此不能把该设计当作 v2.0.12 现成基座。设计文中的“现有 task 均顺序执行”描述也不能覆盖 v2 文档已写明的后台 `subagent`；应以当前已发布文档为准。[v2 工具](https://opencode.ai/v2/docs/tools/)
5. **迁移门槛。** v1 插件实现不在 v2 运行；v2 改为 `Plugin.define({id, setup(ctx)})`、`@opencode/plugin`、`plugins` 配置和域 hook。官方允许同包双入口，但两套 hook 不自动互译。Orbit 当前 OpenCode 插件基于 v1 正式接入，迁移应先保证绑定现有 Root、原文读取、纠正投递和停止，再谈原生子 Agent 接管。[官方 v1→v2 插件迁移](https://opencode.ai/v2/docs/build/plugins/migrate-v1)、[Orbit ADR](../adr/007-task-runtime-refactor.md)

## OMP 18.2.8：已发布能力与边界

1. **原生成员。** `task.batch` 默认开，可用共同 `context` 与多项 `tasks[]` 派发；`async.enabled=true` 时普通成员成为独立后台 job，受 session 范围并发信号量约束，完成结果注入父会话。成员记录独立 JSONL，`history://` 可读；非隔离成员完成后 idle，TTL 后 parked，可被 direct message 复活；隔离工作区成员完成后不能复活。[v18.2.8 task](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md)
2. **消息与控制。** `hub send` 支持点对点、广播、`replyTo`、可选等回复；`inbox/list/wait` 查询或等待消息；`jobs/cancel` 负责后台 job。运行中的收件 Agent 收到非中断 aside，idle／parked Agent 可唤醒或复活。`wait` 统一等待 job 或消息；投递收据与 job 状态必须分开看，投递成功不等于模型已读取或任务已完成。[v18.2.8 hub](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/hub.md)
3. **远程控制面。** OMP RPC 有 `steer/follow_up/abort`、`get_subagents/get_subagent_messages` 和 subagent 事件订阅；但 RPC 是 `omp --mode rpc` 启动的独立宿主，不能将“RPC 可控制新会话”直接等同于“可热接管用户正在用的普通 OMP TUI”。当前 Orbit 的原生扩展已经绑定普通入口，停机证据也依赖其登记的成员。[v18.2.8 RPC](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/rpc.md)、[Orbit ADR](../adr/007-task-runtime-refactor.md)
4. **Advisor/WATCHDOG。** 开启后 reviewer 看主 Agent transcript 增量，默认只给读／搜工具，可注入 `nit`（不打断）、`concern/blocker`（符合约束时 steer）。`WATCHDOG.yml` 可定义多个 reviewer 与模型；子 Agent 默认不启用 advisor，需按 agent 选择。advisor 不能直接裁决或改主会话状态，也不是 `hub` peer；它的调用会产生独立模型用量。推断：可作为 Orbit `JEV` 之外的候选观察器或对照实验，不宜在未比较误报、时延、成本、证据版本前替代现行检查裁决。[v18.2.8 advisor](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/advisor-watchdog.md)
5. **扩展事件。** 扩展可监听 `input`、`before_agent_start`、`context`、`tool_call/result`、`session_stop`；`sendMessage` 有 `steer/followUp/nextTurn/aside`，`triggerTurn` 可唤醒 idle 会话。`session_stop` 仅主会话且在自有后台工作空闲后才触发，不能据其替代运行时任务停止确认。[v18.2.8 扩展](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/extensions.md)
6. **程序化派发接口缺口。** 上游[提案 #2574](https://github.com/can1357/oh-my-pi/issues/2574)仍 open，明确提出扩展缺少等同内置 `task` 的、可在 Agent Hub 中显示且可 steer/abort 的 `ctx.agents.spawn` 句柄。因而“让 Root 调用内置 `task`”与“Orbit 扩展直接程序化创建原生 task 成员”不是同一实施难度。该 issue 是上游报告，尚未在本机 18.2.8 做运行验证。
7. **多顶层会话风险。** 上游[issue #10229](https://github.com/can1357/oh-my-pi/issues/10229)报告同一进程存在多个顶层 session 时，`hub` 的进程级 registry／路由可能错投或不投；截至本次查询仍 open。不能把单 Root + 子 Agent 的 hub 可用性外推为多 Root 正确隔离。该 issue 同样未在本机 18.2.8 复现。

## 与 Orbit 现行语义的接缝

- Orbit 当前同宿主成员由自身显式 `delegate` 登记、通过宿主原生接口启动、同步有效修改、收回结果；OMP 路径使用原生 `AgentRegistry` 自建身份，**未等于改用 OMP model-facing `task/hub`**。未经接线，Agent 自行调用 `task` 派出的成员仍是外部成员，Orbit 不能声称已登记并统一停止。[Orbit 合同](../../contracts/task-runtime.md)、[Orbit ADR](../adr/007-task-runtime-refactor.md)
- Orbit 的 Jev 两阶段委派建议仅提示，Root 必须显式 `delegate`；检查结果要按产物／观察版本判 stale，stop 要覆盖登记成员和其后台工作。OpenCode／OMP 的原生派发工具和 advisor 均不提供这些 Orbit 特定裁决。若改由宿主原生 subagent 承载执行，必须定义派发前如何登记 ID、有效修改如何送达、结果如何去重回 Root、哪些原生 job／shell 可停止且如何确认。[Orbit 合同](../../contracts/task-runtime.md)
- OMP `hub` 的进程内边界意味着跨宿主或两个独立 OMP Root 仍需要 Orbit 的路由／控制通道。OMP 的 [`collab` 控制](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/collab.md)是访客控制一个宿主会话，不等于两个独立 Agent Root 自动互为 `hub` peer。[v18.2.8 hub](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/hub.md)

## 建议的下一步验证（未执行）

1. **OMP 窄实验：** 在隔离项目的普通入口，让 Root 按明确任务票调用内置 `task`，验证 Orbit 能否在派发前／立即返回时登记 ID，再验证 Root/子成员互发、工作中修改、异步结果集成、parked 复活、中断及后台进程实退；对比当前自建 AgentRegistry 路径。单独核查扩展能否取得与内置 `task` 等价的程序化派发句柄，不能预设 #2574 已解决；多顶层 session 再单独核查 #10229。此实验可回答 OMP 是否实际减少通信层，且不先改变跨宿主设计。
2. **OpenCode v2 迁移实验：** 先让当前 Orbit v1 插件以 v2 API 绑定同一个现有 TUI Root，验证原文、内部消息、停止和事件恢复；再验证后台 subagent 的 ID、结果、继续与取消。不要依赖尚未合并的 Agent Teams PR。
3. **唤起策略对照：** 在相同任务记录上对比现行 Jev 触发、OMP advisor 建议、OpenCode hook 观察，记录“值得独立检查／值得委派”的命中、误报、额外模型用量和时延。判断仍须回到 Orbit 的授权、可调用性、产物版本与显式派发合同。

## OMP 代码复用、Fork 与上游跟进

**已确认：许可证允许两条路。** OMP v18.2.8 的根许可证和 `@oh-my-pi/pi-coding-agent` 包均标为 MIT；许可证允许复制、修改、分发，条件是复制或实质性使用时保留原版权与许可声明。因此 Fork OMP 或在 Orbit 中复用其代码在许可证层面可行。若实际打包或复制更多包及第三方依赖，还需按纳入范围核对各自声明；这不是运行架构已经适合的证明。[根 LICENSE](https://github.com/can1357/oh-my-pi/blob/v18.2.8/LICENSE)、[coding-agent package.json](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/package.json)

**已确认：它有包边界，但 `task/hub` 不是独立通信库。** 上游 monorepo 分为 `pi-ai`、`pi-catalog`、`pi-agent-core`、`pi-coding-agent` 等包；`pi-coding-agent` 的 `exports` 包含 `./task/*`、`./tools/hub/*`，主入口还导出 `task/executor`。这说明代码能按包路径引用，**不说明子路径是长期兼容的独立 API**：`task` 创建子会话时联动 AgentSession、发现与配置、进程内 AgentRegistry、生命周期、异步 JobManager、工作区隔离和输出存储；`hub` 消息依赖全局 IrcBus、registry 及收件会话注入。单拷 `task/` 或 `hub/` 到 Orbit 将同时搬入这些生命周期责任，升级时需逐个追接口变化。[包导出](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/package.json)、[task 源码关系](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md)、[hub 源码关系](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/hub.md)、[AgentRegistry](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/registry/agent-registry.ts)、[IrcBus](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/irc/bus.ts)

| 路径 | 可行性和更新代价（推断） |
| --- | --- |
| **以原版 OMP 为运行宿主，Orbit 保持扩展／外部监督层** | 优先验证。直接使用原生 `task/hub`，OMP 版本可独立更新；Orbit 只维护受控接缝及版本兼容测试。当前缺口是扩展没有已确认的、等价于内置 `task` 的 Hub 可见程序化 spawn 接口；先用 Root 显式调用内置 `task` 的窄实验核实登记和停止，不能宣称已接通。[接口提案 #2574](https://github.com/can1357/oh-my-pi/issues/2574) |
| **维护最小 OMP Fork** | 技术上可行，适用于上游接口缺口确实挡住核心路径且扩展／贡献上游不能及时解决时。只给 `coding-agent` 增加窄的 spawn／生命周期接口，保持 Orbit 的裁决与记录在 Orbit；每次合并上游 tag 都要复核接口、会话隔离、消息、模型、权限、停止。Fork 不是“自动跟随上游”，补丁越大，合并成本越高。[task 源码关系](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md)、[接口提案 #2574](https://github.com/can1357/oh-my-pi/issues/2574) |
| **复制 OMP 模块到 Orbit** | 不建议作为首选：`task/hub` 与同进程会话状态紧耦合；抽出后需要自己维持 OMP 生命周期、模型、UI 与消息接线，上游更新无法直接合并。只有经原生接线实验明确抽取边界足够小，才值得重新估算。[task 源码关系](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md)、[hub 源码关系](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/hub.md) |

**已确认：多模型无需 Fork 模型目录。** OMP 的 `task` wire item 是 `{name?, agent?, task, effort?, outputSchema?, schemaMode?, isolated?}`，**没有每次调用的 `model` 字段**。模型选择顺序是 `task.agentModelOverrides[agentName]` → Agent 定义 frontmatter 的 `model` → 父会话模型／默认回退；`modelRoles` 能把 Agent 使用的别名映射到具体 `provider/modelId`。用户在消息中显式标注模型时，还可生成会话内 `m1` 等临时 Agent 名，但这不是 Orbit 持久配置或任意程序化派发接口。因此可为不同工作角色配置 GPT、DeepSeek、GLM、Kimi 等不同供应商模型，并让 Orbit 保存实际解析后的 provider/model 和可用性证据；不要按模型显示名硬编码，也不能仅凭 catalog 中存在模型就认定凭据、额度和该次任务工具调用可用。[task 输入与模型优先级](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/tools/task.md)、[Agent 发现与角色别名](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/task-agent-discovery.md)、[模型身份和可用性](https://github.com/can1357/oh-my-pi/blob/v18.2.8/docs/models.md)

**推断的上游跟进办法。** 若选择原版扩展路径，固定已验收的 OMP tag／npm 包版本，更新时先看 upstream release 与 `task/hub`、扩展事件、SDK／RPC、模型解析的变更，再在隔离项目做一条跨模型派发、成员互发／唤醒、结果回收与中断后停止的真实链路；通过后更新兼容版本。若最终必须 Fork，保留 `upstream` remote、把 Orbit 补丁压在少数独立提交里，逐 tag 合并并跑同一链路，优先把通用 spawn 接口贡献回上游。版本跟进机制可降低滞后，但不能保证新版本无缝兼容。[OMP package 构建与版本](https://github.com/can1357/oh-my-pi/blob/v18.2.8/package.json)、[coding-agent package 导出](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/package.json)

**仍未知。** v18.2.8 原版普通 TUI 下，Orbit 是否能在 Root 调用内置 `task` 时取得足够早且稳定的成员身份、同步有效修改、读取真实使用的 provider/model，并确认 `hub` 的取消覆盖所有实际后台工作；上述均需最小真实接线实验。若不能，最小 Fork 接口的具体范围和长期合并成本才能定量判断。[Orbit 合同](../../contracts/task-runtime.md)、[接口提案 #2574](https://github.com/can1357/oh-my-pi/issues/2574)

以上是可行性判断，不是已运行的模型／进程验收，也不授权修改现行产品语义。

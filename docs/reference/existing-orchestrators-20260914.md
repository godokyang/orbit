# 现成 Agent 协作方案调研（2026-09-14）

状态：候选技术调研，不是已生效的产品决定。最初查阅官方文档与源码；用户随后同意验证 hcom，实测结果见文末，取代下文初步优先级判断。Root 汇总 hcom、acpx、Agent Relay 的核查及既有协作者对 CAO、Orchestrator 的独立核查。本文不代表 Orbit 已具备相应能力。

## 要解决的用户问题

用户在任意项目、普通终端或自己习惯的多路终端中使用 Coding Agent。当前 Agent 继续负责交付；Orbit 能按需加入观察、反馈和必要协作。不能因为没有 Herdr 就无法工作，也不能要求用户日常手填内部会话 ID。项目独立性不意味着自动支持所有 Coding Agent。

本轮重点区分：加入当前会话的通信、创建执行成员、取得结果、实际中断工作。这四件事不能互相替代；恢复一段历史也不等于连接当前正在运行的进程。

## 候选概览

| 项目 | 已有能力 | 运行前提与主要限制 | 对 Orbit 的价值判断 |
| --- | --- | --- | --- |
| [hcom](https://github.com/aannoo/hcom) | Agent 间消息、状态观察、启动成员；支持在部分已运行 Agent 内执行 `hcom start` 加入通信 | Rust 二进制、SQLite、Agent hooks；可用后台 PTY，无需 tmux／Herdr；现有会话自动收信受 hooks 配置影响 | 最贴近“保留当前 Agent，按需加入协作”，建议第一顺位验证 |
| [acpx](https://github.com/openclaw/acpx) | 基于 ACP 的持久会话、后台执行、结构化事件、排队与取消；提供 `acpx/runtime` | Node ≥22.13、对应 Agent／适配器及账号；不依赖终端分屏；主要管理自己创建或记录的会话 | 执行成员后端候选，不能直接当成现有 Root 的连接方案 |
| [CAO](https://github.com/awslabs/cli-agent-orchestrator) | 多 Agent 分工、消息、会话控制、CLI／MCP／Web UI | Python、服务进程、默认 tmux 后端；可选实验性 Herdr 后端 | 可借鉴终端后端分离与停止确认，整套采用会增加运行前提 |
| [Agent Relay](https://github.com/AgentWorkforce/relay) | 通信、Agent 注册与创建、不同 Agent 的 harness 接口、Codex skill 集成 | 需配置通信工作区和相关集成；注册身份不等于控制运行中的模型进程 | 可借鉴当前 Agent 加入通信及优先使用原生子 Agent 的方式 |
| [Orchestrator](https://github.com/ryderderder/orchestrator) | 创建 pane、派发任务、收集结果、续聊与进程清理 | Python、tmux、Agent CLI；主要操作自己创建的执行会话 | 结果回收和成员清理参考，无法覆盖无 tmux 的入口 |

表中价值判断是针对 Orbit 当前目标的推断，不是性能、稳定性或供应商额度实测排名。对应 Agent 的安装、登录与工具权限仍然需要具备。

## 优先候选的证据与边界

### hcom：现有会话加入通信确实有实现

`start.rs` 读取 Claude／Codex 的会话环境信息，存在从已运行 Agent 加入通信的路径。但此前没有相应 hooks 时，它会尝试配置并提示重启 Agent，再运行 `hcom start`。因此不能宣传成“任意正在运行的会话都能零配置接入”。[接入源码](https://github.com/aannoo/hcom/blob/fabb309b57cb33b39c69b773cd759723a10e94b5/src/commands/start.rs)

官方 README 提供后台 PTY 运行方式，以及多种终端集成。Herdr、tmux 是可选运行方式，不是唯一入口。它覆盖通信与成员启动，尚不能由此推出 Orbit 的检查反馈和任务完成判断已经解决。[README](https://github.com/aannoo/hcom)

停止仍需单独核验：`stop` 对不同运行形态有不同处理；`kill` 有进程组终止路径，但单成员无可跟踪 PID 时会拒绝 kill 并建议 stop。发送终止信号、退出通信、保留当前 Root 上下文且暂停工作，并非同一种行为。[stop 源码](https://github.com/aannoo/hcom/blob/fabb309b57cb33b39c69b773cd759723a10e94b5/src/commands/stop.rs)、[kill 源码](https://github.com/aannoo/hcom/blob/fabb309b57cb33b39c69b773cd759723a10e94b5/src/commands/kill.rs)

### acpx：程序化执行成员很合适，但默认恢复行为需审查

会话按 Agent 命令、目录和名称寻址，由持有 ACP 连接的进程处理请求；支持恢复已记录的会话。文档还说明：恢复失败时可能创建新会话并更新记录。这不能直接套到 Orbit“保留当前 Root，不自动替换”的决定上。[会话文档](https://github.com/openclaw/acpx/blob/7aed9b289459ca2f0d28ac215a052fbacafde03b/docs/sessions.md)

它提供当前 turn 的协作式取消，以及进程生命周期回调；文档明确回调不负责终止任意后代进程，也不保证宿主突然退出后的清理。Orbit 若采用它，仍须落实自己创建成员的归属与停止确认。[会话控制](https://github.com/openclaw/acpx/blob/7aed9b289459ca2f0d28ac215a052fbacafde03b/docs/session-control.md)、[进程生命周期边界](https://github.com/openclaw/acpx/blob/7aed9b289459ca2f0d28ac215a052fbacafde03b/docs/runtime-process-lifecycle.md)

ACP 的新建、加载、恢复是协议能力，加载／恢复还依赖 Agent 宣告支持。该协议本身没有承诺接管任意已打开的 TUI 进程。[ACP 会话协议](https://agentclientprotocol.com/protocol/v1/session-setup)

### 另外三项：取其具体能力，不直接引入整套平台

CAO 默认使用 tmux，也提供实验性 Herdr 后端，不能笼统说它必须使用 tmux。它仍需要终端后端和 `cao-server`；已核查入口以创建提供者进程为主，Claude 的 resume 参数表示延续历史，不是连接任意已打开的进程。[README](https://github.com/awslabs/cli-agent-orchestrator)、[Herdr 后端](https://github.com/awslabs/cli-agent-orchestrator/blob/main/docs/herdr.md)、[启动源码](https://github.com/awslabs/cli-agent-orchestrator/blob/main/src/cli_agent_orchestrator/cli/commands/launch.py)

CAO 的删除逻辑要求确认后再移除状态；源码同时注明 tmux 后端会检查会话消失，Herdr 后端尚缺同等存活确认。这是值得借鉴的实现原则，也说明不能仅凭接口叫 shutdown 就认定停止闭环完成。[会话服务源码](https://github.com/awslabs/cli-agent-orchestrator/blob/main/src/cli_agent_orchestrator/services/session_service.py)

Agent Relay 的 Codex skill 区分注册当前 Agent 与创建执行 Agent，优先使用可用的原生子 Agent，否则走 Relay 创建。这能参考；但 harness 文档中的 `release` 可表示终止、断开或归档，不能统一当成实际停止。[Codex skill](https://github.com/AgentWorkforce/relay/blob/df3e0b2bc28131d83ed4f7d1de5c55ba2609d3bf/plugins/codex-relay-skill/SKILL.md)、[harness 文档](https://agentrelay.com/docs/harnesses)

Orchestrator 以 tmux 为基础，提供 dispatch 后的结果读取、状态区分和成员关闭。已查看的路径不能证明其能接管任意现有交互会话；适合作为成员结果回收与清理的参考。[使用指南](https://github.com/ryderderder/orchestrator/blob/main/docs/GUIDE.md)、[Agent 接口指南](https://github.com/ryderderder/orchestrator/blob/main/docs/AGENT_GUIDE.md)

## 建议与最小验证路径

建议先验证 hcom 是否能覆盖 Orbit 需要的通信与成员生命周期，再决定是否需要 acpx 这样的程序化执行后端。当前证据不足以决定同时引入两套工具，更不足以把任一项目直接包装成完整 Orbit。

只验证会改变选型的三个问题，先用一个已授权 Agent 和一个小任务：

1. 当前主执行 Agent 能否加入通信，继续原会话；空闲时与执行中分别怎样收到反馈。明确首次 hooks 配置是否需要重启，不能用新建 Root 冒充接入成功。
2. 没有 Herdr／tmux 时，能否启动一个必要的后台执行成员、回收真实结果，并把用户的中途修改传回负责执行的 Agent。
3. 用户停止任务时，主执行 Agent 和本任务成员是否实际停止工作，原会话与成果是否保留。注销通信、收到取消请求、关闭窗口不能单独作为成功证据。

若采用 acpx，再针对其恢复失败新建会话的行为确认可控性；不扩大成全供应商测试矩阵。普通终端链路成立后，Herdr／tmux 只补必要的终端集成核对。

以上为实测前的调研结论。其后的授权验证范围与结果如下。

## hcom 最小实测：通信可用，停止闭环未通过

2026-09-14 用户同意上述最小验证。使用官方发布的 hcom 0.7.25（校验 SHA-256）及本机 Codex 0.154.0，在临时目录运行一个真实执行成员；继承现有 gpt-6-astra／high 配置，没有切换供应商、替换当前 Root 或修改 Orbit 运行实现。[原始结果选段与清理核对](hcom-probe-20260914.json)

| 冻结问题 | 实际结果 | 判断 |
| --- | --- | --- |
| 当前 Root 直接加入 | 首次 `hcom start` 安装 hooks 后退出 1，要求重启；第二次注册成功，但 `hooks_bound=false`、`process_bound=false`、会话 ID 为空；终端投递返回没有 inject port | 未通过真实连接验收；本次未重启 Root。临时二进制也未进入宿主已有 PATH，不能据此断言完成首次安装并重启后仍不支持 |
| 无 Herdr／tmux 的后台成员与反馈 | 清除相应环境变量后，以 `--headless` 启动成员，生成 `alpha` 文件；从空闲状态收到 hcom 反馈，在同一会话改为 `beta` | 后台执行、空闲唤醒及反馈修正通过。结果通过文件和 transcript 核验；未证明结构化结果自动回到当前 Root |
| 中断及停止是否真正结束工作 | 运行持续写入的前台 Python 命令；通过 `hcom term inject` 发送 Escape 后，Codex 显示对话中断，但命令继续写入。随后 `hcom stop` 返回 0、列表为空、启动进程消失，写入命令仍存活 | 该路径停止闭环失败；最终由实验控制程序按已记录 PID 终止残留命令 |

停止证据：Escape 后文件先后为 260、443 字节，PID 仍存活；随后 hcom stop 时为 2661 字节，三秒后为 2934 字节，PID 仍存活。该结论限于本次 Codex 组合及“中断后再 stop”路径；没有扩大为所有提供者或所有停止方式的断言。文件 `beta` 和会话记录保留，但 stop 已结束成员进程，未验证恢复会话。

另有两个直接影响接入的发现：启动器未能记录精确 hook trust 时，自动加入了 `--dangerously-bypass-hook-trust`；虽然本次配置隔离且仅含 hcom hooks，也不能将该默认行为不经审查带入 Orbit。实验控制端使用未注册的外部发送者名称，消息可送达，但成员向该名称回复 ACK 失败；正式接入必须建立可回信的控制端身份。

最后可读的成员用量为 input 78,464（其中 cached 52,992）、output 295、total 78,759 tokens。这是该成员中断前最后上报的计数，包含 CLI 上下文，不是 hcom 独有开销，也不包含 Root 或整次调研费用。未取得完整账单，不能声称已经节约额度。

结论：保留 hcom 为通信候选，不把它直接作为 Orbit 的完整运行控制层。当前 Root 的首次接入仍未闭合；后台成员可执行和纠偏，但发送中断、成员从列表消失都不足以证明任务停止。下一项有价值的调查是原生会话接口／acpx 能否控制实际执行及派生进程；这不是自动授权继续安装另一套方案或进入实现。

收尾：实验涉及的全局 Codex 配置已按原内容恢复；已记录的启动进程、残留命令均不存在，两处实验端口关闭。保留上述精简证据，临时二进制、源码、隔离配置与日志在证据保存后清理；未提交推送。

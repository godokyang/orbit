# Orbit 的运行主体：同类项目参考

2026-09-13，Root 按用户要求查阅官方文档和源码。本轮只回答“谁持续运行，负责启动、观察和停止”，不扩展到完整框架选型。未安装或运行这些项目，也未验证本地供应商接入。以下外部事实与 Orbit 候选建议分开记录；不改变现行合同或已确认方向。

后续决定：用户已同意下文提出的任务运行进程形态，结论记录在[愿景计划「运行方式」](../plan/vision-completion-plan.md#运行方式已确认)。下文候选与待定措辞保留调研当时的状态，不作为重复确认或直接开工依据。

## 一手来源核查

| 项目 | 已查到的做法 | 对本问题的启发 |
| --- | --- | --- |
| mini-SWE-agent | `DefaultAgent.run()` 在调用它的进程中循环执行步骤，保存轨迹，遇到退出消息结束；查询模型前检查配置的调用、费用或时间限制。[官方源码](https://github.com/SWE-agent/mini-swe-agent/blob/main/src/minisweagent/agents/default.py)、[源码参考页](https://mini-swe-agent.com/latest/reference/agents/default/) | 一次任务可以由一个持续运行的程序驱动，不要求先建全局服务 |
| OpenHands SDK | `LocalConversation` 在本进程运行，`RemoteConversation` 将执行交给 agent-server；Conversation 管理执行状态和事件。[官方架构说明](https://docs.openhands.dev/sdk/arch/conversation) | 本地执行与服务接入可以围绕同一套运行职责组织 |
| OpenCode | 默认终端界面连接 server，也能单独启动无界面的 `opencode serve`；接口包括会话创建、异步消息、事件流和 abort。[官方 Server 文档](https://opencode.ai/docs/server/) | 人机界面与真实执行可以分离，外部程序可通过结构化接口接入 |

这些项目的运行机制不等于已经实现 Orbit 所需的独立检查和裁定。mini-SWE-agent 展示的是直接驱动模型的内部循环，不据此替换用户已有 Coding Agent 或供应商套餐入口；OpenCode 的接口也不能推定其他工具都支持。

停止语义必须单独核实：OpenHands 的 `pause()` 在步骤之间生效，正在进行的模型调用可能要等完成；它不是立即中断所有工具的证明。[官方 API 说明](https://docs.openhands.dev/sdk/api-reference/openhands.sdk.conversation#pause-2) mini-SWE-agent 的限制检查位于下一次模型查询前，也不能当成正在运行的动作到时必停。[官方源码参考](https://mini-swe-agent.com/latest/reference/agents/default/#minisweagent.agents.default.DefaultAgent.query) OpenCode 文档列出 abort 接口，但仅凭该接口存在，不能证明其所有派生进程都已退出。[官方会话接口](https://opencode.ai/docs/server/#sessions)

## Root 的候选建议（待用户决定）

**每次受控任务启动一个独立的 Orbit 运行进程，任务结束并完成必要收尾后退出。** 程序在任务期间持续存在，不等于模型持续思考；等待事件和时间本身不调用模型，约定的独立检查仍照常触发。

从用户角度：启动任务 → Orbit 启动并协调 Root／执行者 → 首个结果或约定时间到达时启动检查 → 将问题交 Root 修正 → 完成或停止并交出结果。Root 忙于执行时，外层程序仍能接收事件和到期信号；实现不能被一次同步模型调用堵住整个控制循环。

这个进程拥有任务执行状态、检查安排与受控动作；Agent 接入部分负责实际启动、投递、观察和停止，不另作一套任务调度。具体采用哪个成熟接入能力仍需定向核查，不在本轮签发依赖或重写语言的决定。

独立使用时，用户直接从 Orbit 入口启动任务；Feedback 接入时，由适配层调用同一执行入口并映射结果。运行本身不需要 Feedback 字段或业务前后置流程。入口形态和参数尚未冻结，当前不承诺接管已经打开的任意 Agent 会话。

第一版不因此建设开机常驻、多机调度或自动故障恢复。由任务启动的进程也可以在本地普通终端或 Herdr 专用 tab 运行，界面不拥有执行状态。运行进程的具体停止粒度、真实工具退出确认仍属于下一项设计；本建议不能替代那些验证。

## 本轮待定的一项

是否采用“从 Orbit 启动受控任务，Orbit 运行进程陪同整个任务”的形态？这比依赖 Root 定期调用 CLI 多了一个实际运行主体，但无需用户预先部署另一个业务系统，也不新增常驻监督模型。

同类项目证明这类运行形态有实际先例，不证明它对 Orbit 必然最优或一定省额度。若方向确认，再映射现有代码与最小接入，不先扩展调研范围。

## 现有 Root 的通信与控制接口核查

2026-09-13 继续按已确认的“调用 skill 的当前 Agent 保持 Root”方向核查。只读取本机 CLI 帮助与官方文档；未连接或改动活跃会话，未发送消息、中断 Agent、启动服务或运行模型实验。

本机 Codex 的 `codex queue --help` 明确支持按 session UUID 或精确名称给已有会话排消息；`codex agents --help` 描述共享本地 app-server daemon；`codex app-server --help` 提供连接运行中控制 socket 的 `proxy` 入口。它们说明已有原生接入入口，不能据此推定 queue 会立即打断执行，也尚未证明本轮 Root 已完成接入。

[Codex 官方 App Server 文档](https://developers.openai.com/codex/app-server/)（正文通过同站 `.md` 版本读取）给出以下接口：

| 所需能力 | 文档依据 | 尚未证明的部分 |
| --- | --- | --- |
| 工作途中传入纠正 | `turn/steer` 向活跃轮次追加输入，要求匹配 `expectedTurnId` | 接受输入不等于 Root 已落实纠正；本机 queue 的具体投递时机未实测 |
| 观察状态与结果 | `thread/read` 可读状态与历史而不恢复会话；另有状态、轮次和工具事件 | 当前会话的连接、订阅与实际产物关联尚未验证 |
| 暂停当前执行 | `turn/interrupt` 请求取消轮次，结束状态为 `interrupted`；另列后台终端的查询和终止接口，后者为实验接口 | 轮次结束不证明后台命令、外部 MCP 动作及所有成员均已停止；不能据此声称硬预算已受控 |

Root 判断：原生接口足以支持继续设计“保留当前 Root”的路径，不需要因现有 Zeen 代码只演示新建会话而强制更换 Root。各 Coding Agent 的具体接入能力仍分别核实；不将 Codex 接口当成跨供应商合同。

后续决定：用户已同意暂停粒度建议，当前结论见[愿景计划「暂停粒度」](../plan/vision-completion-plan.md#暂停粒度已确认)。接口核查不替代最小验收的实际停止要求。

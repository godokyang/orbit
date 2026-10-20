# C1 对话事件行调查

目标：在对话流里显示独立的 Orbit 任务事件行（started/checked/stopped），而不只是工具卡片。

## 已尝试

1. **匹配 `tool/call` + 自定义 chat node**
   - 注册 `ConversationNodeDefinition`（kind `orbit-event`）与 `conversation.chat.node` 渲染器；
   - 客户端可加载，但事件行不出现：工具调用由通用 tool 渲染器接管，custom node 未获得位置。

2. **宿主 append `plugin:zeen/orbit/task` session record + 客户端匹配**
   - 宿主在 start/check/stop 后写 plugin record；
   - 客户端定义匹配 `plugin:` 事件；插件加载无报错，但行仍不出现；
   - 结论：当前 client 会话历史不把 ignorable plugin record 暴露给 conversation node 匹配。

## 可用替代

- **标准 session 事件**：可 append 一个已被 client 识别的事件类型（如 `command/run`），但会伪造命令语义，不可取。
- **Session projection**：可注册 Orbit 投影，但投影只能由 panel/组件读取，不能直接生成 conversation 行。
- **工具卡片**：当前 `orbit`/`orbit_ask` 的 presenters 已在对话流显示卡片，是 DSH 公开支持的事件行形态。
- **上游扩展**：需要 DSH 暴露 plugin record 到 client history，或提供 conversation 自定义事件注册接缝。

## 待决策

- 接受工具卡片作为“对话流 Orbit 事件行”，或
- 等 DSH 提供公开接缝后再做独立行，或
- 用标准事件类型的合法子集（需要产品语义确认）。

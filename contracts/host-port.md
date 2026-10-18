# Orbit 宿主接口合同（1.0）

状态：草案，2026-10-19，**未生效**。本文件是[ADR-014](../docs/adr/014-host-port-interface.md) 的配套合同，尚未采纳；采纳前现行规则仍以[任务运行合同](task-runtime.md)与[集成合同](integration.md)为准。

本文件只约束 Orbit 核心与宿主适配层，不是 Loom 的依赖面。Loom 只依赖集成合同。

## 1. 版本与兼容

- 合同版本独立于软件版本；当前 `1.0`。
- 同一主版本只加方法或可选字段，不改、不删。
- 方法改名是一次性的内部变更（Ruby 与扩展同包发布），不保留兼容别名。
- 适配层必须声明它实现的合同版本；核心只与声明过的版本通信。

## 2. 传输

- Unix domain socket，私有路径，仅属主可读写。
- 一行一个 JSON 请求，一行一个 JSON 响应。
- 请求：`{"method": string, "session": string, ...params}`。
- 成功：`{"result": any}`；失败：`{"error": string}`。
- 超时由调用方控制（默认 15 秒）。失败不自动重试；是否重试由运行时决定。
- 不推送、不订阅。运行时轮询；事件通路走集成合同 `events_read`，不走本协议。

## 3. 方法

| 方法 | 请求 | 返回 | 必填字段 | 说明 |
| --- | --- | --- | --- | --- |
| `host_port` | `{}` | 对象 | `version` | 适配层声明实现的合同版本 |
| `session_state` | `{}` | 对象 | `cwd` | 会话身份与状态。`cwd` 必须是绝对路径。其余字段适配层私有 |
| `current_model` | `{}` | 字符串 | — | 当前写模型，`provider/id` |
| `model_catalog` | `{}` | 对象 | `current`、`available` | 见 §3.1 |
| `default_member_route` | `{}` | 对象 | `provider`、`id` | 默认成员路由；可选 `billing_route`（`direct_api` / `subscription_quota` / `unknown`） |
| `messages` | `{}` | 数组 | 每项 `id` | 原生消息。`id` 稳定；可选 `item_id`、`internal`。其余字段适配层私有 |
| `send_message` | `{text}` | 对象 | `id` | 以程序来源送一条消息，不冒充用户；返回原生消息 id |
| `ask_requests` | `{}` | 对象 | `asks` 数组 | 待答问题：`id`、`questions`、`at` |
| `answer_ask` | `{id, answers}` | 对象 | `accepted` | 递送答复；未知 id 或非法答案失败 |
| `session_prompt` | `{text}` | 对象 | `accepted` | 注入真实用户消息（`attribution=user`）；`message_id` 可得时为原生 id，否则 null |
| `session_abort` | `{}` | 对象 | `confirmed`、`scope` | 中止会话；`scope=session` 只表示会话已中止，不等于任务停止 |
| `stop_root` | `{}` | 对象 | `confirmed` | 停止 Root 并确认。`confirmed` 只在真实停止后为 `true` |
| `member_roster` | `{}` | 数组 | 每项 `thread_id` | 当前成员。其余字段适配层私有 |
| `member_state` | `{id}` | 对象 | — | 可选 `model`、`registry_status`；其余适配层私有 |
| `member_result` | `{id}` | 对象或 `null` | — | 成员成果；`null` 表示尚无结果 |
| `send_member` | `{id, text}` | 对象 | — | 向成员送达消息；回执字段适配层私有 |
| `stop_member` | `{id}` | 对象 | — | 停止成员；回执字段适配层私有 |
| `collaboration_events` | `{}` | 对象 | `events` 数组 | 每项至少 `id`、`kind`；`seq` 可选。其余字段按 `kind` 由适配层定义 |
| `bind_task` | `{task_directory}` | 对象 | `task_directory` | 把会话绑定到任务目录 |

### 3.1 `model_catalog`

必填：

- `current`：当前模型的 `provider/id`；
- `available`：当前会话可选的模型 id 数组。

可选：

- `allowed_models`：授权名单；
- `authorization_guard`：布尔；
- `families`：模型家族映射；
- `routes`：计费路由映射；
- `limits`：上下文窗口、模态、工具支持。

适配层私有（不进入核心）：

- `agents`：宿主原生 Agent 名映射；
- `agent_dir`：宿主 Agent 目录。

未知字段一律忽略。核心不得依赖适配层私有字段。

## 4. 宿主内义务

义务不是方法调用，而是宿主必须提供的拦截、登记、回执、停止与隔离能力。

### 4.1 必需

| 编号 | 义务 | 不满足时 |
| --- | --- | --- |
| H2 | 每次请求投影有效要求；每轮注入状态摘要 | 不能承载受控任务 |
| H3 | 工具调用前拦截：成员不能派成员、路径与命令范围、模型授权 | 不能承载受控任务 |
| H4 | 成员首次模型调用前同步登记，失败即中止 | 不能承载受控任务 |
| H5 | 停止并确认：空闲、无在途工具、名下后台任务结束、本任务消息清出队列 | 不能承载受控任务 |
| H6 | 每次模型与工具调用的回执：实际型号、用量、时间 | 严格模型授权与账本失效 |
| H7 | 隔离只读检查者会话：独立进程、只读工具、固定快照 | 不能承载受控任务 |

### 4.2 可选

| 编号 | 义务 | 不满足时 |
| --- | --- | --- |
| H1 | 首个模型请求前看到用户消息和稳定 id，可附提示或中止 | 关闭自动入口，只保留显式 start |
| O1 | 成员之间互发消息 | 关闭对应协作，只走 Root |
| O2 | 向活动成员转发用户修订 | 修订只送 Root，记“未送达” |
| O3 | 原生提问的跳过追踪与补问提醒 | 不做补问提醒 |
| O4 | 与系统指令同层的合作政策注入 | 改由 H2 投影承载 |

## 5. 一致性测试

宿主必须通过 `tests/host_conformance/` 才能承载受控任务。测试分两组：

- **零模型探针**：状态、目录、绑定、空闲时停止。
- **真实模型探针**：登记失败时成员第一步被拦住；带运行中成员和后台任务时的停止确认；只读检查者的写入被拒绝。

真实部分按 `.agents/skills/orbit-real-acceptance` 执行。宿主版本升级时重跑这套测试，替代逐版本的手工复核。

## 6. 变更记录

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| 1.0 | 2026-10-19 | 首次草案：控制协议改为中性命名、H1–H7/O1–O4 分级、一致性测试入口 |

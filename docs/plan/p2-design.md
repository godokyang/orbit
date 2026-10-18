# P2 设计：Loom 节点改用 Orbit 合同（草案）

状态：设计草案，2026-10-19，**未确认实施**。本文只解决“怎么设计”，不改变现行规则；R10 与合同版本须用户决定。

关联：[宿主接口与事件通路实施方案](host-port-and-events.md)（第 8 节）、Loom [执行合同](https://github.com/zeen-chat/loom/blob/main/docs/execution.md)。

## 1. 目标

Loom 节点不再直接说 OMP：RPC 帧类型、会话文件格式、`orbit omp` 启动命令只出现在一个适配模块里，或完全移除。

节点只依赖 Orbit 集成合同。Orbit 决定用哪个宿主；换宿主时 Loom 不改代码。

## 2. 现状依赖

| 类别 | 内容 | 主要位置 |
| --- | --- | --- |
| RPC | `get_state`、`prompt`、`abort`、`set_ask_dialog`、`get_entries`、`negotiate_protocol`、`extension_ui_request/response` | `orbit/session.py`、`rpc/transport.py`、`rpc/probe.py`、`execution/executor.py` |
| 会话文件 | 解析原生会话文件取可见消息 | `rpc/session_file.py` 及 `discovery/runner.py`、`verification/self_check.py`、`execution/question_flow.py`、`execution/questions.py`、`ai/orbit_task.py`、`orbit/adapter.py`、`execution/executor.py` |
| 启动 | `orbit omp --mode rpc-ui [--resume\|--model]`、探针 `orbit omp --mode rpc` | `orbit/session.py:133` |

## 3. Orbit 侧能力（按代价从低到高）

2026-10-19 实施状态：

| 能力 | 状态 | 依据 |
| --- | --- | --- |
| `native_user_messages` | 已实现（合同 1.8） | `orbit messages`；节点续接优先使用 |
| `session_state` / `session_abort` | 已实现（合同 1.8） | 扩展 `session.abort`；`scope=session` 不等于任务停止 |
| `session_launch` | 已实现（合同 1.8） | `orbit launch` 返回中性 argv；节点在能力存在时使用，进程仍由节点拉起 |
| `session_prompt` | 已实现（合同 1.8） | 扩展 `pi.sendUserMessage`（`attribution=user`）；`orbit prompt` 实测返回原生 message_id |
| `question_relay` | 已实现（合同 1.8） | 扩展在外部模式 shadow `ask` 工具，经 socket 转发；`orbit questions` / `orbit answer` 实测问答闭环 |

实测（2026-10-19，源 CLI）：

- `orbit prompt` 返回 `{"accepted":true,"message_id":"4804d6d2"}`，任务继续执行。
- shadow `ask` 捕获问题 `choice`/A/B；`orbit questions` 列出；`orbit answer` 递送 A；`tool_execution_end` 的原生结果 `content=[{"text":"A"}]`、`selectedOptions=["A"]`，任务继续。
- shadow 只在 `ORBIT_EXTERNAL_INTEGRATION=1` 时注册，独立使用 OMP 时保留原生 ask。

剩余：Loom 节点尚未切换到 `question_relay` / `session_prompt` 合同（仍保留直连路径）；完整 Loom 整链未跑。

## 3. Orbit 侧能力（按代价从低到高）

2026-10-19 实施状态：

| 能力 | 状态 | 依据 |
| --- | --- | --- |
| `native_user_messages` | 已实现（合同 1.8） | `orbit messages`；节点续接优先使用 |
| `session_state` / `session_abort` | `session_abort` 已实现（合同 1.8） | 扩展 `session.abort`；`scope=session` 不等于任务停止 |
| `session_launch` | 已实现（合同 1.8） | `orbit launch` 返回中性 argv；节点在能力存在时使用，进程仍由节点拉起 |
| `session_prompt` | **受阻** | OMP 扩展的 `session`/`sessionManager` 没有 prompt/send；只有 abort、state、model、branch |
| `question_relay` | **受阻** | 原生 ask 由 RPC 客户端处理，扩展层没有 ask/dialog 捕获接口 |

受阻项不是设计问题，是宿主接口缺口：要搬进 Orbit，必须先有一个宿主义务（捕获提问、注入用户消息）或上游 API；当前 OMP 18.11.3 不提供。

### 3.1 `native_user_messages`

- **替换**：会话文件解析里的“用户消息”部分。
- **接口草案**：`orbit messages TASK --after ID --json` 或集成合同方法；返回稳定 id、文本、是否内部。
- **要求**：id 稳定；分页按 id；不返回推理与工具输出。
- **验收**：同一会话两次读取 id 一致；节点不再打开会话文件即可取得用户消息。

### 3.2 `question_relay`

- **替换**：`get_entries` 扫描 + `set_ask_dialog` 递送答复。
- **接口草案**：列出待答问题（问题 id、文本、选项、时间）；按问题 id 递送答复；返回原生回执。
- **要求**：问题 id 稳定；答复幂等；重复递送返回同一回执，不重复消费。
- **验收**：discovery 三轮问答真实路径通过；暂停/恢复后未答问题仍可列出。

### 3.3 `session_prompt`

- **替换**：`prompt` + 扫描 `get_entries` 取原生消息 id。
- **接口草案**：送入一条用户消息，返回真实原生消息 id 与接受时间。
- **要求**：返回的是原生消息 id，不是节点自造 id；失败必须有结构化原因。
- **验收**：送入后按返回 id 能读回同一条消息。

### 3.4 `session_state` / `session_abort`

- **替换**：`get_state`、`abort`。
- **接口草案**：会话身份、是否空闲、当前型号；中止并给回执。
- **要求**：中止回执必须区分“任务已停止”和“进程已停止”（见 4.2）。
- **验收**：空闲中止与运行中止各一次真实验证。

### 3.5 `session_launch`

- **替换**：`orbit omp --mode rpc-ui` 启动命令。
- **接口草案**：返回启动规格（argv、环境、socket 路径、会话身份），由节点拉起；或由 Orbit 拉起并返回连接句柄。
- **要求**：启动语义归 Orbit；进程归属须先决定（见 4.1）。
- **验收**：节点不再拼 OMP 命令；重启节点后能按记录的身份接回。

## 4. 决定与未决

### 4.1 进程归属

| 方案 | 做法 | 代价 | 风险 |
| --- | --- | --- | --- |
| A | 节点继续拉起 `orbit omp` | 最低 | 节点仍认识宿主命令，P2 目标未达成 |
| B | Orbit 返回启动规格，节点拉起 | 中 | 需要定义“接手证据”，不能只看 PID |
| C | Orbit 拉起并返回句柄 | 高 | 改变进程模型与节点监督方式 |

**已定 B（2026-10-19）**：节点仍是进程所有者，Orbit 拥有启动语义。

双用途下 B 同样成立：Orbit 作为独立 coding agent 时，调用方是终端；作为 Loom 执行体时，调用方是节点。B 只有一套模型——**调用方拥有进程，Orbit 拥有会话语义**。C 只有在 Orbit 常驻、多个前端共享会话时才有收益，现在不做。

B 必须满足三件事：

1. 启动合同与调用方无关：终端和节点走同一条创建会话的路径，Orbit 不假设调用方是 Loom；
2. 会话与证据落盘，`orbit status` 和 Loom 读同一份；
3. Loom 的 external refs、心跳、尝试编号由节点附加，不进入 Orbit 核心。

**接手证据**建议由三件事组成，缺一不认：

1. Orbit 返回的会话身份（不是节点自造）；
2. 首次握手拿到的会话状态（`cwd`、空闲状态、当前型号）；
3. 第一条真实原生消息 id 与回执。

PID 存在、进程在跑、发出过 prompt，都不算接手。

### 4.2 无任务时的中止回执

场景：会话已建立但尚未绑定 Orbit 任务，用户要求停止。

| 方案 | 回执 | 问题 |
| --- | --- | --- |
| A | `{confirmed:false, reason:"no_task"}` | 诚实，但没有停掉任何东西 |
| B | `{confirmed:true, scope:"process"}` | 停的是进程，不能冒充任务停止 |
| C | 先尝试任务停止，无任务再停进程，返回合并回执 | 需要清晰的作用域字段 |

**建议 C**，回执至少包含：

```json
{ "confirmed": true, "scope": "process", "task": null,
  "evidence": { "process_exited": true, "at": "…" } }
```

**字段命名由实现决定**，不需要产品确认：用 `scope`，取值 `task | process | none`；`task` 才算任务停止，`process` 只算进程停止，两者都不等于业务完成。

### 4.3 R10：已修订

2026-10-19 用户确认修改。新措辞已写入 Loom `docs/requirements.md`：

> Orbit 是最终 AI 执行主体，Loom 经可信节点薄适配只依赖 Orbit 声明的集成合同，不直接依赖 Orbit 选用的宿主。……

影响：

- 节点不再以“接原生 OMP 受控会话”为需求依据；
- P2 的收尾（删除旧直接调用）以新措辞为前提；
- Loom 的 `execution.md` 已同步宿主表述，具体操作步骤随 P2 更新。

## 5. 迁移方式

1. 先在 Orbit 写 ADR 与集成合同增项（能力名、请求/返回、失败语义、版本号）。
2. 节点按能力是否存在选择新路径；能力缺失时保留旧路径。
3. 每项真实验证通过后，才删除对应的旧直接调用。
4. 不在一个提交里同时替换多项；每项可单独停下。
5. 全部完成后才做“OMP 专有名词只出现在一个模块”的检查。

## 6. 完成条件

- 节点源码中，OMP RPC 帧类型与会话文件格式只出现在一个适配模块里，或已完全移除；
- Zeen 样本的提问 → 答复 → 续接 → 停止真实路径通过；
- discovery 三轮问答不退化；
- 旧路径删除前，新路径各有一次真实回执。

## 7. 风险

1. **discovery 多轮依赖原生 ask**：`question_relay` 必须保留问题身份与幂等，否则会出现重复提问或丢答。
2. **可见 assistant 文本**：现在从宿主报告的会话文件读取；换合同后要有对应投影（可复用 `conversation_read`），否则展示退化。
3. **接手证据**：只看 PID 会重演“进程在跑但没人接手”的旧问题。
4. **R10 已改，但节点旧路径仍在**：收尾以 P2 各项真实验证通过为前提。
5. **合同版本**：多项能力可能分属不同次版本，节点要按能力而不是按版本号判断。

## 8. 待决

- 五项能力是一次进合同，还是分批。

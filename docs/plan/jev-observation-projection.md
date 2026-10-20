# JEV 观察输入投影（DSH 版短设计）

状态：2026-10-20 设计稿，切片 B 开工前唯一要先定的设计。规则来源是[任务运行合同](../../contracts/task-runtime.md)"JEV 按用途组织输入与按需压缩"一节与 [ADR-012](../adr/012-jev-purpose-specific-input-and-compaction.md)；本文只定这些规则在 DSH 事件下的形状，不改规则。

## 它是什么

JEV 每隔一段时间问两个问题：卡住了吗、偏题了吗。合同规定它看的材料是"上次实际检查节点之后的操作，超过 20 条取最近 20 条完整记录"，每条只有操作目的、工具名、直接可得的对象、状态和时间，不带工具输入输出、长回复和日志。

这份材料今天由 OMP 扩展在 `before_provider_request` 等钩子里逐条记进 `host.observations`，Ruby 端再裁成窗口。换到 DSH 后，没有这些钩子，有的是会话日志里的 `tool/call`、`tool/result`、`turn/*`、`step/*`、`job/*` 事件。"观察投影"就是把这些事件折叠成合同要的那张操作表的那个函数，按 DSH 的惯例做成一个 `ctx.sessionProjections` 单元：纯函数 `apply(state, event)`，状态是普通 JSON，Orbit 用 `stateOf(session, 'orbitObservation')` 读。

它决定两件会影响校准的事：窗口里每条记录长什么样，以及去重键用什么算。这两样一变，旧的 JEV 校准样本就不再适用，所以要先定下来再写代码。

## 一条操作记录

| 字段 | DSH 来源 | 说明 |
| --- | --- | --- |
| `id` | `tool/call` 的 `block.id` | 稳定的 tool call id |
| `seq` | `tool/call` 事件的 `seq` | 游标依据 |
| `turn`、`step` | 最近的 `turn/start`、`step/start` | 替代 OMP 的 `turn_id`/`message_id` |
| `name` | `block.name` | 工具名 |
| `declared_intent` | bash/pwsh 的 `arguments.description`；其他工具无 | DSH 的 bash 工具要求 `description`（探针已证实），这是模型声明的目的；缺省 `unknown`。合同：声明的目的不是完成证据 |
| `target` | read/write/edit 的 `arguments.file_path`（read 已验证字段名，edit/write 以工具 schema 为准） | 产物根内给相对路径，根外给 `outside-workspace`，不给内容和 diff；其他工具 `unknown` |
| `status` | 配对的 `tool/result` | `ok`、`error`（`isError`）、`aborted`（错误文本为 tool call aborted）、`interrupted`（宿主崩溃后 DSH 补写的"outcome is unknown"）、`not_observed`（尚无结果） |
| `started_at`、`finished_at`、`duration_ms` | 两个事件的 `time` | 毫秒 |

不进记录的：工具参数全文、输出、assistant 文本、推理。与今天一致。

## 窗口与游标

- 窗口按合同取上次检查节点之后的记录，最多最近 20 条；更早的条数以 `omitted_older_operations` 计数给出。
- 游标从"上次检查的 tool_call_id"改为 `(sessionId, seq)`。DSH 的 `seq` 单调且稳定，比 OMP 的 id 查找简单；游标指向的 seq 不在可读范围时给 `history_gap`。
- 宿主崩溃后日志带 `turn/end {kind: interrupted}`，窗口里加一条 `crash_gap`，带崩溃前最后的 seq；对应的未完成操作状态为 `interrupted`。
- 投影自己保留最近 50 条操作加总计数，足够切出 20 条窗口并定位游标；再早的只剩计数。

## 宿主状态字段

| 合同里的 host 字段 | DSH 来源 |
| --- | --- |
| `status` | `agent.status`：`idle`/`running` |
| `turn_id`、`last_turn_id` | 当前与上一个 `turn/start` 的 `turn` |
| `last_turn_status` | 最近 `turn/end` 的 `reason.kind`，turn 未结束为 `open` |
| `active_tools` | 当前 step 内有 `tool/call` 无 `tool/result` 的数量 |
| `async_jobs` | `ctx.jobs.list(owner)` 中 `running`/`stopping` 的数量 |

## 成员

每个成员是独立会话，同一个投影单元对每个会话各自折叠。观察输入里成员一节沿用今天的形状：状态、派发身份、模型、最近一次操作的 `name`/`status`/`finished_at`、本任务 job 数。成员的完整 20 条窗口不进观察输入，与今天一致；要不要加是校准后的事。

## 去重键

沿用 `ObservationKey` 的结构，只换宿主材料：

- `status`、`last_turn_id`、`last_turn_status` 按上表；
- `observations` 取窗口里最近 10 条操作记录逐条哈希；
- 输入摘要、产物根、产物摘要、开放 finding、争议、触发原因不变。

时间戳在记录里，所以每条新操作都会换键；没有新操作、turn 未变时键不变，但合同规定相同情况也不永久跳过，由 Core 的 5 分钟节奏保证。

## 节奏与跳过

不变：首次约 5 秒，之后每 5 分钟；独立检查在途时跳过且不补发；结束、停止或禁用 JEV 时不调用。节奏由 Core 的一个定时器驱动，不用 DSH schedule。

## 校准

问题集版本保持 `jev-observation-4`。输入版本必须升一位，因为记录字段的来源与状态词汇变了。升版后旧校准样本只作参照，不自动放行；按 ADR-009 的规则，没有质量证据时明确降级，用观察结果安排过程检查的策略不变。校准样本在切片 B 真实模型跑通后重新采集。

## 验证

在现有探针基础上加一项：对 S1、S2、S6 留下的会话日志跑投影，断言窗口形状、`aborted` 与 `interrupted` 状态、游标越界的 `history_gap`、崩溃后的 `crash_gap`；再用一份固定的事件样例做黄金测试。

## 实施位置

`@orbit/dsh-host` 注册投影单元 `orbitObservation`，`stateVersion` 从 1 起；Core 的 JEV 客户端只接收单元输出，不直接碰会话事件。

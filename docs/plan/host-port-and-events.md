# 宿主接口与事件通路实施方案（讨论稿）

状态：讨论稿，2026-10-18。**未确认实施**，不改变现行规则。任务、检查、完成、停止与授权语义仍以 [godokyang/orbit](https://github.com/godokyang/orbit) 的[任务运行合同](https://github.com/godokyang/orbit/blob/main/contracts/task-runtime.md)、[集成合同](https://github.com/godokyang/orbit/blob/main/contracts/integration.md)和 ADR 为准；Loom 行为以 [zeen-chat/loom](https://github.com/zeen-chat/loom) 的[执行合同](https://github.com/zeen-chat/loom/blob/main/docs/execution.md)为准。

关联：[DSH 迁移讨论稿](dsh-migration.md)（结论待按本文修正）、Loom [通信核对草案](https://github.com/zeen-chat/loom/blob/main/docs/integration-readiness.md)（其“实时对话/流式事件”一行已把缺口归给 Orbit 公开事件/消息能力）。

2026-10-20 后续决定：[ADR-015](../adr/015-typescript-core-and-dsh-migration.md)已确认本次迁移统一 TypeScript Core 与 DSH，当前仍只完善文档。本文 P0–P2 的 Ruby 路径保留为原阶段依据；P3 是宿主接缝试验，不再代表完整迁移只需写适配层。完整重写与切换边界见[能力整合专题](dsh-capability-consolidation.md#typescript-重写与切换条件)。

---

## 1. 目标与原则

目标是把三层隔开：

```text
Loom ──只依赖──> Orbit 集成合同
Orbit 核心 ──只依赖──> 宿主接口
宿主细节（OMP / 将来其他）──只出现在──> 适配层
```

原则：

1. **可丢的走流，不可丢的走文件 + 游标。** RPC 事件随管道断开而丢失；`events.jsonl` 与宿主会话文件不丢。展示用前者，业务事实只用后者。
2. **一个事实一个权威。** 规则写进所属仓；本仓只放跨仓方案与 DSH 评估，不放现行规则。
3. **能换，不同时养多个宿主。** 宿主接口让更换可行，不改变 [ADR-008](https://github.com/godokyang/orbit/blob/main/docs/adr/008-omp-native-collaboration-base.md) 的单宿主决定。更换时短期并行做差分对比，验收后退役旧适配层。
4. **不改现行语义。** 完成门、停止确认、模型授权、独立检查和成员登记硬门全部保持；本方案只改变事实的暴露方式和代码边界。

## 2. 文档放在哪

按所有权分，方案放本仓：

| 内容 | 放在 | 理由 |
| --- | --- | --- |
| 集成合同 1.8 `events_read`；后续会话控制能力 | godokyang/orbit：`contracts/integration.md/.json`、ADR-010 变更记录 | 集成能力由 Orbit 仓提供（Loom R10） |
| 宿主接口、能力分级、一致性测试 | godokyang/orbit：新 ADR-014、`contracts/host-port.md/.json` | Orbit 内部架构 |
| 拆分 `task-runtime.md` | godokyang/orbit | 同上 |
| 节点持续读取、活动投影、事件映射、改用 Orbit 合同 | zeen-chat/loom：`docs/execution.md` §2、§6，节点代码 | 节点与运行事件归 Loom |
| R10 修订（P2） | zeen-chat/loom：`docs/requirements.md` | 已确认需求，须用户决定 |
| “实时对话/流式事件”缺口状态 | zeen-chat/loom：`docs/integration-readiness.md` | Loom 已登记该缺口 |
| 跨仓实施方案、DSH 评估 | 本仓（godokyang/orbit/docs/plan） | 两个产品仓都不应持有对方的任务清单；Orbit 要求“讨论中的候选方案留在方案材料中”，Loom 要求“同一规则只在所属文件修改” |

某阶段开工时，Orbit 的[唯一总待办](https://github.com/godokyang/orbit/blob/main/docs/plan/agent-autonomy-implementation.md)和 Loom 的通信核对文档各加一行指回本文。这些都是跨仓修改，逐次取得授权后再做（Loom AGENTS：“跨仓修改按当次授权处理”）。Orbit 工作从 `origin/main` 拉分支；本机 `/Users/dy/Workspace/orbit` 当前停在 `feat/integration-contract`。

## 3. 现状核对（本方案依据）

均为 2026-10-18 对两仓 `origin/main` 的静态阅读，未真跑。

- **Orbit 已有宿主控制协议，但未命名。** `lib/orbit/plugin_connection.rb` 经私有 socket 调用扩展：`state`、`messages`、`user_message(s)`、`model`、`member_model`、`model_catalog`、`send`、`stop`、`members`、`hub_events`、`member_state`/`member_result`/`send_member`/`stop_member`、`bind_task`。
- **宿主内的门集中在扩展。** `plugins/omp-host.mjs`（4,450 行）注册 `tool_call`（3289）、`before_agent_start`（3604）、`before_provider_request`（3674）、`context`（3962）、`tool_result`（4083）、`session_start`（4387）、`session_shutdown`（4426）；`plugins/*.mjs` 合计约 6.4k 行；另有 `runners/omp-reviewer`。
- **Ruby 核心对 OMP 的耦合集中在少数文件。** 按 OMP 相关词计数：`task_runtime.rb` 46、`diagnostics.rb` 43、`cli.rb` 40、`omp_entry.rb` 32、`omp_check_runner.rb` 29、`checker_model_selector.rb` 13，其余多为个位数。
- **`events.jsonl` 不适合直接开放。** 共 126 种内部类型，未冻结；所有追加都经 `TaskRecord.event`，但来自多个 Ruby 进程（运行时、CLI 脚本）；行内只有 `at`、`type` 与细节，不带 `revision`（revision 在状态保存路径单独分配）。扩展自己写 `collaboration.jsonl`，避免两个写者写同一文件。
- **`conversation_read`（1.7）是可照搬的模式。** `lib/orbit/conversation.rb`：字节偏移、只解析完整行、有界、越界失败、不合成。
- **Loom 节点只在 `call()` 里读 OMP 输出。** `orbit/session.py` 用 selector 带截止时间读取，没有常驻读取线程；非应答帧顺手放进 `_events`。
- **节点从 `status` 前后两次的差异推出 `phase_changed`。** `execution/executor.py` 用 `(revision, phase)` 比较；两次轮询之间的检查开始、结束会丢。`check_completed` 的观察键是 `attempt_id:check_number`（`executor.py:125`）。
- **后台按运行事件时间判卡住，长实现期可能误报。** 三点合起来看：
  - `api/workbench.py:495` 取已投影事件的 `occurred_at` 作最近活动，30 分钟无活动判“长时间无进展”；
  - 运行中节点唯一的周期性持久事件是 `phase_changed`，只在 `(revision, phase)` 变化时产生；
  - Loom 严格路径关闭 JEV，没有每 5 分钟的观察去触发过程检查。

  所以一个超过 30 分钟、阶段不变的实现期可能不产生任何持久事件，被误报为卡住。尚未在真实运行中核实。`workflows.md` §5 已把“OMP 原生活动”列为该规则的输入之一。
- **Loom 节点直接依赖 OMP。** 涉及三类：RPC（`get_state`、`prompt`、`abort`、`set_ask_dialog`、`get_entries`、`negotiate_protocol`、`extension_ui_request/response`）、会话文件解析（`rpc/session_file.py` 及其调用方），以及启动命令 `orbit omp --mode rpc-ui`（`orbit/session.py:133`）。
- **安装版落后于源码。** Loom 通信核对记录本机安装为 Orbit 0.8.18、合同 1.6；`origin/main` 已是 1.7。

## 4. 阶段总览

| 阶段 | 内容 | 所在仓 | 依赖 | 规模（粗估） |
| --- | --- | --- | --- | --- |
| 0 | 修正迁移讨论稿；核实管道积压；准备分支与安装 | 本仓 / 本机 | 无 | 1 天 |
| P0-O | Orbit `events_read`（合同 1.8） | orbit | 0 | 2–3 天 |
| P0-L | 节点持续读取、活动投影、消费 `events_read` | loom | P0-O 的安装版 | 约 1 周 |
| P1 | 宿主接口 ADR、协议改名、义务清单、一致性测试、核心收口、拆合同 | orbit | P0-O | 2–3 周 |
| P2 | Loom 节点改用 Orbit 合同（会话控制） | orbit + loom | P1；R10 决定 | 2–4 周，设计先行 |
| P3 | DSH 适配试验 | 本仓 | P1 | 限时 2 周 |
| 并行 | Orbit 未完成事项三项（EXP-11、rebind 真实验收、续查与模型阻塞恢复） | orbit | 无 | 按事项 |

规模只供排期参考。AI 实施能压缩编码时间，压缩不了真实验收。

## 5. 阶段 0：准备

1. **修正 [DSH 迁移讨论稿](dsh-migration.md)**（须用户确认后改正文）：
   - 规模数据：main 为 84 个 Ruby 文件、43,150 行；163 是全部文件数。
   - 入口钩子：DSH 有 `agent/pre-step`。
   - 事件流前提：OMP RPC 本来就推送事件。
   - 多模型对比的对象不对等。
   - L0/L1 阶梯违反 2026-10-16 裁决。
   - JEV 不在 M1–M4 里。
   - 目标形态缺可信节点。
   - 未提 `dsh-goal`。
2. **核实 OMP 输出管道积压（2026-10-19 已实测）。** 用 `omp --mode rpc` 跑一个持续出事件的任务，150 秒不读 stdout：RSS 从约 238 MB 升到约 428 MB 后保持平稳，期间 `get_state` 写入 0.0 秒成功；恢复读取 10 秒取回约 1.1 MB。结论：OMP 不做无界缓冲，表现为有界缓冲/背压，不会因不读而持续涨内存。P0-L 的常驻读取线程因此是“消除停顿与事件延迟”，不是“防止 OOM”；管道积压不是阻断风险。
3. **Orbit 分支。** 从 `origin/main` 新建分支，不在 `feat/integration-contract` 上做。
4. **安装前置。** P0-L 的真实验收需要声明 1.8 的安装版。发布与安装须用户单独授权（Orbit 版本号默认只升 patch）。

## 6. 阶段 P0：事件通路

### 6.1 Orbit：`events_read`（集成合同 1.8）

```text
orbit events TASK --after CURSOR --json
```

```json
{ "cursor": "…", "next_cursor": "…",
  "events": [
    { "kind": "check_finished", "at": "2026-10-18T08:00:00Z",
      "number": 3, "stale": false, "stale_reasons": [], "verdict": "correct",
      "finding_ids": ["F2"], "resolved_ids": [], "artifact_digest": "…" } ],
  "skipped": 7, "unreadable": 0, "truncated": false, "dropped": 0, "read_at": "…" }
```

**公开类型 v1。** 沿用内部类型名，只做白名单和字段裁剪：

| kind | 保留字段 | 不含 |
| --- | --- | --- |
| `check_started` | number、role、kind、trigger、manual、model、input_digest、artifact_digest | artifact_root（路径） |
| `check_finished` | number、stale、stale_reasons、verdict、finding_ids、resolved_ids、artifact_digest | reason 文本 |
| `check_failed` | number、failure_kind | error 文本 |
| `finding_recorded` | check、finding 的 id | 问题正文 |
| `finding_resolved` | id、check | — |
| `instruction_amended` | source | 修订正文 |
| `correction_sent` | id、版本摘要 | 纠正正文 |
| `finalization_notice` | check、version | — |
| `completion_stop_queued` | 仅 kind 与 at | reason |
| `stopped` | confirmation.confirmed | 其余诊断 |
| `stop_unconfirmed` | 仅 kind 与 at | reason、error |
| `member_settled` | thread_id、status | — |

字段取舍沿用 1.3 `latest_check` 的先例：不含结论、错误、问题文本和工作区路径。

**规则：**

- **游标对调用方不透明。** v1 只编码 `events.jsonl` 的字节位置；以后加入 `collaboration.jsonl` 不破坏调用方。调用方保存并回传，不解析。
- **只解析完整行**，半行留待下次。不在白名单的内部事件计入 `skipped`，非 JSON 行计入 `unreadable`，都不猜。单次上限 1 MB 或 200 条，超出时置 `truncated` / `dropped`。
- **失败语义。** 游标非法或越界、任务不存在时失败，不合成；任务存在但日志尚未创建时，返回空列表并原样返回游标。
- **v1 不带 `revision`。** `TaskRecord.event` 追加时不读状态，revision 在保存路径单独分配，又是多进程追加；追加时盖上的 revision 与事件不是同一次原子写入，写进合同会暗示一个并不存在的原子性。Loom 现有观察键也不需要它。
- **消费规则写进合同：**
  - 事件是按追加顺序的观察；`at` 精度到秒，可能相同。
  - 当前状态以 `status` 为准，停止只看 `stop_confirmation.confirmed`。
  - `check_finished` 不含 role/kind，按 `number` 与 `check_started` 或 `latest_check` 对应。
  - 未知 kind 忽略；新类型只在次版本增加。
- **只读。** 不连会话、不调用模型、不写任务，与其他合同命令一致。不做推送；不丢事件靠游标。

**实现：**

- 新增 `lib/orbit/task_events.rb`，结构照 `conversation.rb`。
- `cli.rb` 增加 `events` 命令，已核对与现有命令不冲突。
- `contracts/integration.md` 增 §4.2；`integration.json` 增 `events_read`（since 1.8，含 kinds 列表与上限）；`capabilities --json` 自动带出。
- 测试：新增 `tests/task_events_test.rb`，并更新 `integration_contract_test.rb`，控制在 10 个测试、300 行以内。至少覆盖：白名单与字段裁剪、未知类型计数、半行、越界失败、坏行计数、截断。
- 版本：软件 patch 加一；合同 1.7 → 1.8。

### 6.2 Loom 节点

1. **持续读取（`orbit/session.py`）。** 加一个常驻线程读取 OMP 输出：
   - 应答按请求 id 交给等待中的 `call()`；
   - 提问帧交给提问处理；
   - 其余帧进有界环形缓冲和活动聚合。

   `call()` 对外接口不变。

   **这是 P0-L 风险最高的部分。** 现在的 `_ingest_ui_request` 在 `call()` 的读取循环里同步执行；改为读取线程后，提问会在调用方阻塞时从另一个线程进入，提问与答复路径要按线程重新设计（见第 11 节第 1 项）。`tests/test_ask_dialog.py` 和 `tests/test_question_adoption.py` 必须保持通过，并重跑 discovery 三轮真实路径。
2. **活动适配。** 只有这一个模块认识 OMP 事件名，其余代码只见中性结构：

   ```text
   activity = { state: busy|idle|unknown, tool, target, since,
                last_native_activity_at, members_running, retrying, source: "omp_rpc" }
   ```

   来源事件：`agent_start/end`、`tool_execution_start/end`、`message_end`、`subagent_lifecycle`、`auto_retry_start`。`target` 只给工作区内的相对路径，工作区外留空；不带参数、输出或推理。
3. **随心跳上报。**
   - 挂在运行尝试心跳 `/api/node/runs/{run_id}/attempts/heartbeat` 上（`RunAttemptIn` 目前只有 `attempt_no`），不挂节点心跳；
   - 后台只存最新一份，不存历史；
   - Web 在技术视图显示“AI 正在：读取 src/…”。
4. **消费 `events_read`。**
   - 能力存在时，节点按游标读取，游标存进 bridge 状态，与 `next_offset` 同处。
   - `check_finished`、`check_failed` 映射为 `check_completed`，观察键 `attempt_id:check_number` 不变。
   - `phase_changed` 与 `stop_receipt` 仍从 `status` 得出。
   - 其他类型先只进节点日志，供时间线使用。
   - 能力缺失时退回现有的 `status` 差分路径。
5. **文档。**
   - `execution.md` §2 写明运行事件的两类来源和活动的性质；
   - §6 “节点依赖的公开行为”增加 `events_read`；
   - 通信核对文档更新“实时对话/流式事件”一行。

**活动与“卡住”。** v1 的 `activity` 只用于展示，不进入任何业务状态，不产生完成、验收或停止事实。之后可以把它作为 `workflows.md` §5 已列出的“OMP 原生活动”输入接进 30 分钟无进展规则。这个方向只会消除误报，不会制造业务事实，但它改变一条已确认的运行参数，须单独决定。

### 6.3 完成条件

- **Orbit：** 确定性测试通过；在一次真实任务中边运行边读取 `orbit events`，`check_started`/`check_finished` 的顺序和编号与 `status.latest_check` 一致。

2026-10-19 源 CLI 真实任务（临时 git 仓库，`scripts/orbit omp --mode rpc` + `scripts/orbit start`）：任务从 `starting` 进入 `running`，完成 3 次检查；`orbit events` 按顺序返回 `check_started`/`check_finished` ×3、`finalization_notice`、`completion_stop_queued`，`truncated=false`；`stop` 受理。事件编号与 `status.latest_check` 一致（上一轮同任务 3 页对比：最后 check 15 == status 15）。
- **Loom：** 在 Zeen 样本的一次含两次以上检查的 run 中，每次检查都出现 `check_completed`，没有因轮询间隔丢失；活动在 15 秒内更新；运行中重启节点后，事件从游标续读，不重复（按观察键去重）、不缺失。discovery 三轮问答的现有真实路径不退化。

2026-10-19 组件级实测：用节点自己的 `OrbitSession` 在临时 git 仓库启动真实 `orbit omp --mode rpc-ui`。`get_state` 成功；`prompt` 受理；活动从 `unknown` 进入 `busy` 再回 `idle`；捕获 `message_update` 与 `tool_execution_start` 帧；`kill` 正常停止进程组。工具活动是亚秒级，轮询可能采不到，但帧已进入有界缓冲；活动只作展示，不产生业务事实。

## 7. 阶段 P1：宿主接口

### 7.1 ADR-014 要点

- Orbit 核心只经宿主接口访问宿主；宿主细节只在适配层。
- 当前仍只有 OMP 一个宿主，ADR-008 不变。
- 任何宿主须通过一致性测试才能承载受控任务；不满足的义务按分级关闭功能，并如实报告。

### 7.2 控制协议（运行时调宿主的一半）

socket 协议是内部协议，Ruby 和扩展同包发布，改名一次完成，不需要兼容别名。写成 `contracts/host-port.json`，像 `integration.json` 一样有版本号和请求/返回 schema，并配合同测试。

| 现名 | 中性名 | 说明 |
| --- | --- | --- |
| `state` | `session_state` | 身份、cwd、空闲状态 |
| `messages`、`user_message(s)` | 不变 | 原生消息与稳定 id |
| `model` | `current_model` | |
| `member_model` | `default_member_route` | 去掉 OMP `@task` 概念 |
| `model_catalog` | 不变 | `agents`（OMP Agent 名）移为适配层私有字段 |
| `send` | `send_message` | 程序来源消息，不冒充用户 |
| `stop` | `stop_root` | |
| `members` | `member_roster` | |
| `hub_events` | `collaboration_events` | |
| `member_state` / `member_result` / `send_member` / `stop_member` | 不变 | |
| `bind_task` | 不变 | |

### 7.3 宿主内义务与能力分级

| 编号 | 义务 | 级别 | OMP 现在在哪 | 不满足时 |
| --- | --- | --- | --- | --- |
| H1 | 首个模型请求前看到用户消息和稳定 id，可附提示或中止 | 可选（外部集成模式本就关闭） | `before_provider_request` | 关闭自动入口，只保留显式 start |
| H2 | 每次请求投影有效要求；每轮注入状态摘要 | 必需 | `context`、`before_agent_start` | 不能承载受控任务 |
| H3 | 工具调用前拦截：成员不能派成员、路径与命令范围、模型授权 | 必需 | `tool_call`、`work-unit-scope.mjs`、`model-authorization.mjs` | 同上 |
| H4 | 成员首次模型调用前同步登记，失败即中止 | 必需 | AgentRegistry `registered` → `scripts/orbit-register-member` | 同上 |
| H5 | 停止并确认：空闲、无在途工具、名下后台任务结束、本任务消息清出队列 | 必需 | 停止路径、`session_shutdown` | 同上 |
| H6 | 每次模型与工具调用的回执：实际型号、用量、时间 | 必需 | `model-call-receipts.mjs`、`native-call-recorder.mjs`、`tool_result` | 严格模型授权与账本失效，同上 |
| H7 | 隔离只读检查者会话：独立进程、只读工具、固定快照 | 必需 | `runners/omp-reviewer`、`omp_check_runner.rb` | 同上 |
| O1 | 成员之间互发消息 | 可选 | 原生 `hub`、`write agent://` | 关闭对应协作，只走 Root |
| O2 | 向活动成员转发用户修订 | 可选 | `send_member` | 修订只送 Root，记“未送达” |
| O3 | 原生提问的跳过追踪与补问提醒 | 可选 | `interrupt_skipped` 记录 | 不做补问提醒 |
| O4 | 与系统指令同层的合作政策注入 | 可选 | `before_provider_request` 载荷 | 改由 H2 投影承载 |

### 7.4 一致性测试

把现有探针扩成 `tests/host_conformance/`，来源有三：

- 安装器的可信扩展能力探针；
- `tests/omp_*_test.mjs`；
- Loom 的 `rpc/probe.py` 和 `orbit/probe.py`。

测试分两组：

- **零模型探针：** 状态、目录、绑定、空闲时停止。
- **真实模型探针：** 登记失败时成员第一步被拦住；带运行中成员和后台任务时的停止确认；只读检查者的写入被拒绝。

真实部分按 `.agents/skills/orbit-real-acceptance` 执行。宿主版本升级时重跑这套测试，替代逐版本的手工复核。

### 7.5 Ruby 核心收口

- 把 `omp_entry.rb`、`omp_check_runner.rb`、`plugin_connection.rb` 移到 `lib/orbit/hosts/omp/`。
- 清理 `task_runtime.rb`、`cli.rb`、`diagnostics.rb` 中的 OMP 专属逻辑，改为经宿主接口调用。
- 用 grep 作检查：核心目录不再出现 OMP 专属名称。

### 7.6 拆分 `task-runtime.md`（P1 最后一步）

- 拆为两份：宿主无关的产品不变量（留在 `contracts/task-runtime.md`），以及 OMP 适配说明（钩子名、SDK 接口名、特定版本行为，例如 18.8.0 的成员回收顺序）。
- 在 P0 合入之后做，1.8 的文字只写一次。
- 逐节进行，每条规则只出现一次，不改语义，按差异逐节审阅。

这是风险最高的文档任务。

### 7.7 完成条件

- 现有测试全部通过；
- 一致性测试在 OMP 18.10.1 上通过；
- 因 H4、H5 相关代码被改动，重跑冻结验收 #1（独立检查纠偏）和 #2（真实停止）各一次。

## 8. 阶段 P2：Loom 改用 Orbit 合同

**现有直接依赖：**

- RPC：见第 3 节。主要在 `orbit/session.py`、`rpc/transport.py`、`rpc/probe.py`、`execution/executor.py`。
- 会话文件解析：`rpc/session_file.py`。调用方包括 `discovery/runner.py`、`verification/self_check.py`、`execution/question_flow.py`、`execution/questions.py`、`ai/orbit_task.py`、`orbit/adapter.py`、`execution/executor.py`。
- 启动：`orbit omp --mode rpc-ui [--resume|--model]`、探针 `orbit omp --mode rpc`。

**Orbit 侧候选能力**，按代价从低到高：

1. `native_user_messages`：`PluginConnection` 已有 `user_message(s)`，可替换节点的会话文件解析。这是最便宜的第一步。
2. `question_relay`：列出待答问题，按问题 id 递送答复，返回原生回执。
3. `session_prompt`：送入一条用户消息，返回真实原生消息 id，替换节点扫描 `get_entries`。
4. `session_state`、`session_abort`：会话身份、是否空闲、当前型号；中止并给回执。
5. `session_launch`：与宿主无关的启动入口。

**未决问题与 2026-10-19 的决定：**

- **进程归属：已定 B。** 节点仍是进程所有者，Orbit 返回启动描述、节点负责 spawn 与 reap。接手证据按三件事认定：Orbit 返回的会话身份、首次握手的会话状态、第一条真实原生消息 id；PID 存在不算接手。详见 [P2 设计](p2-design.md)。
- **无任务时的中止：已定。** 先尝试任务停止，无任务再停进程，回执带 `scope`（`task | process | none`），`task` 才等于任务停止。
- **R10：已修订（2026-10-19）。** 改为“Loom 只依赖 Orbit 声明的集成合同，不直接依赖 Orbit 选用的宿主”。已写入 Loom `docs/requirements.md`。

**迁移方式：** 先在 Orbit 写 ADR 和合同，再逐项迁移。节点按能力是否存在选择新路径；每项真实验证通过后，才删除旧的直接调用。

**完成条件：** 节点源码中，OMP RPC 帧类型和会话文件格式只出现在一个适配模块里，或已完全移除；Zeen 样本的提问→答复→续接→停止真实路径通过。

## 9. 阶段 P3：DSH 适配试验

2026-10-20：用户已选择同次迁移重写 TypeScript Core，但明确**先继续完善文档，不开始重写或 P3**。工作区见[交接](handoff.md#dsh-迁移工作区)，完整目标见 [ADR-015](../adr/015-typescript-core-and-dsh-migration.md)。下列仍是宿主接缝试验范围，不是本次执行清单；“2 周”不作为完整重写估计，试验通过不等于新核心或正式切换通过。

- **原 P3 前提：** P1 完成，一致性测试存在。新路线启动接缝试验前须冻结实际宿主支持集合与探针，不将 Ruby 阶段的完成标签等同于 TypeScript 接入就绪。
- **范围：** 写一个 DSH host 插件，实现控制协议和 H2–H7，先做必需项，再跑一致性测试。
- **产出：** 逐项通过或不通过的结论；需要上游补的接口清单；是否继续的建议。
- **原 P3 限时：** 2 周，只指原宿主探针口径，不是完整重写估计。不进入生产，不接 Loom。
- **重点关注：** H4（观察型生命周期事件不等于首个模型请求前的同步登记门）和 H5（任务级资源与迟到消息能否全部收束）。DSH `0.2.1-rc.2` 的 SDK 后端已有 `dispose()` 与 shutdown／进程回收路径；没有 wire-level prompt cancel 不等于不能取消。`interrupt_agent` 只返回中断受理，不证明空闲或停止全部后代。来源及真实探针边界见[多 Agent 专题](dsh-collaboration.md)。

## 10. 换底座清单

| 保留的语义与依据 | 需要重做与验证 |
| --- | --- |
| Orbit 任务、要求版本、快照、检查调度、完成门、覆盖、账本、JEV 与选型规则 | Ruby 实现不直接复用为运行核心；按 ADR-015 在 TypeScript 中重写完整行为，同时实现 DSH 接线、事实映射与调用前控制，逐项验证，不靠 TS 包装旧 Ruby |
| 集成合同的任务语义与能力协商边界 | 真实验收：冻结验收 #1、#2 在新宿主上重跑；原生日志、来源、游标与错误语义不得原样套用 OMP 假设 |
| Loom 对 Orbit 的任务接口（P2 完成后） | Loom 消息读取仍须按新增中性能力协商迁移，不承诺零改动；兼容未闭合不正式切换。见[联合方案](dsh-capability-consolidation.md)。JEV 观察输入、问题集及实际模型不一致时重新校准 |
| | 模型质量证据：按四字段路由身份记录，新宿主路由不同则不自动沿用 |
| | 旧任务：可读、可导出，不能跨宿主 `resume_from`（要求同一 Root 会话） |

接口解决不了的事：宿主做不到的必需义务，适配层补不上，只能等上游或降级为如实报告。

## 11. 风险

1. **节点读取线程引入并发。** 提问与答复路径已有真实验证。保持 `call()` 接口不变，补应答匹配、提问递送、截止时间的测试，并重跑 discovery 三轮真实路径。
2. **事件顺序的假设。** 只保证文件追加顺序；`at` 精度到秒；多进程追加可能出现坏行。合同明说这些，不承诺更多。
3. **P1 动到停止与登记路径。** 冻结验收必须重跑，确定性测试不能代替。
4. **拆合同可能改变语义。** 放到 P1 最后，逐节审差异。
5. **P2 范围膨胀。** 先设计，再逐项迁移；每项都可单独停下。
6. **发布与安装依赖。** P0-L 和 P2 的真实验收都依赖新安装版，发布须授权。

## 12. 需要你决定的事

1. 第 2 节的文档放置方式。
2. P0 公开类型 v1，以及 v1 不带 `revision`。
3. 活动是否在 v1 之后接进 30 分钟无进展规则（6.2 末段）。
4. P2 是否修订 Loom R10。
5. Orbit 发布与安装、Loom 部署的授权时机。
6. 授权修正 [DSH 迁移讨论稿](dsh-migration.md)正文（阶段 0 第 1 项）。

## 13. 非目标

- 本文的 P3 探针不切换生产宿主；正式宿主迁移与完整重写目标由 [ADR-015](../adr/015-typescript-core-and-dsh-migration.md)确定，不能据此条否定迁移目标。
- 不改变完成、停止、授权、检查与成员登记语义。
- 不做推送或逐字流式；v1 只做游标拉取。
- 不让 Loom 直连宿主或 Orbit 会话。
- 不改 Loom 现有 11 类运行事件的含义；新增类型另行决定。

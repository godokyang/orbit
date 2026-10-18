# Orbit 集成合同

合同版本：1.8

面向把 Orbit 当作外部执行与检查服务的集成方（例如 Loom）。本合同只冻结下面列出的命令、返回字段与结果 schema；这些之外的一切（包括 `status --json` 里的其他字段）都是 Orbit 内部实现，随时可变。产品语义以 [任务运行合同](task-runtime.md) 和 [检查结果 schema](check-result.schema.json) 为准，本文件与它们冲突时以它们为准并修正本文件。机器可读形式见 [integration.json](integration.json)，`orbit capabilities --json` 与契约测试都读取它，决定理由见 [ADR-010](../docs/adr/010-integration-contract.md)。

## 1. 合同版本与兼容规则

- 合同版本是 `主版本.次版本`，与软件版本（`orbit version`、`package.json`）**相互独立**。集成方不应比较软件版本号判断可用，只看合同主版本与能力清单。
- **同一主版本内只加不改不删**：可以新增命令、返回字段、能力、检查结果的可选字段（次版本加一）；不得改变既有字段的含义、类型、取值范围，不得删除或改名。`status` 的取值集合也在主版本内冻结，新增取值按破坏性改动处理。
- 破坏性改动必须升主版本，并在发布说明中写明对应变化；同一发布可以先并存新旧能力，由能力清单区分。
- 集成方对未声明的字段保持容忍：读到合同未列出的字段忽略，不依赖其存在或形状。

## 2. 能力协商

`orbit capabilities --json` 只读、不连接会话、不调用模型、不读任务，返回：

```json
{ "integration_contract": { "name": "orbit-integration", "version": "1.6", "major": 1 },
  "orbit": { "version": "<软件版本，仅供显示>" },
  "capabilities": { "<能力名>": { "since": "<引入该能力的合同版本>", "...": "该能力的限制" } } }
```

集成方在启动与每次运行前检查自己需要的能力名及其限制；不满足就按自己的规则阻断，不猜测。能力只在 Orbit 已实际接线时才出现。1.0 起的能力（后续次版本只在能力下增加字段）：

| 能力 | 含义与限制 |
| --- | --- |
| `status_json` | `orbit status TASK --json` 返回 §4 的冻结字段 |
| `export` | `orbit export TASK --output FILE` 返回 §3 的字段；归档内 `task/state.json` 带有 1.0 的持久冻结字段与已记录的 revision/updated_at；1.3 的 attention/latest_check 为 status 只读投影 |
| `stop_receipt` | 停止回执：`stop --json` 只表示入队，已确认停止只看 `stop_confirmation.confirmed` |
| `start_external_refs` | `start` 可带 `--external-ref`；`max_refs`、`max_length` 为强制上限；`inherited_on_resume=false` |
| `check_coverage_continuation` | 1.6 起：未核实项可选 `gap_kind` 区分尚未检查、缺少必要证据及缺陷；已核实项可选 `verified_by_check` 标注来源检查号；跨版本不自动继承资格 |
| `check_coverage_ref` | 检查结果的每个覆盖项可带 `ref`；`max_length` 为 schema 上限；`blank_is_omitted=true`（1.1 起）表示空串或纯空白按未提供处理 |
| `resume_from` | `start --resume-from`；`from_status` 列出可接续的旧任务终态（`paused` 与 `needs_user`）；`requires=native_user_message` |

| `external_session_mode` | 1.2 起：`ORBIT_EXTERNAL_INTEGRATION=1` 关闭自动入口，Root 显式 start 保留 |
| `control_socket_env` | 1.2 起：指定私有父目录中的绝对路径，session_start 提前监听，关闭只释放自有 socket |
| `status_by_external_ref` | 1.2 起：精确引用查询，包括终态；成功总是 tasks 数组，无匹配退出 0 |

| `status_revision` | 1.3 起：revision/updated_at 与持久状态原子写入，读/无变化 tick 不递增；读时覆盖与用量不计 |
| `status_attention` | 1.3 起：粗粒度 phase＋needs_user，码表冻结；needs_user 为已停止终态 |
| `model_authorization` | 1.4 起：精确型号硬名单，任务内冻结、接续继承；调用前校验，池耗尽阻断，可选辅助判断关闭 |
| `status_latest_check` | 1.3 起：最后完成检查，含失败/陈旧；白名单字段、模型回执去重数组与输入一致性 |
| `session_binding` | 1.5 起：status 只读投影 `session_binding`——provider 会话身份、宿主报告的会话文件路径与稳定启动消息边界；未知为 null，不猜路径、不臆造旧记录启动边界（见 §4） |
| `resume_wake` | 1.5 起：可选 `start --resume-wake`，须与 `--resume-from` 同用；绑定后投递程序来源的原生续接消息，回执见 §4 |
| `conversation_read` | 1.7 起：`orbit conversation TASK --after OFFSET --json` 只读增量投影宿主报告的会话文件中的可见助手消息；返回 `next_offset`，不写任务、不调用模型、不重放对话 |
| `events_read` | 1.8 起：`orbit events TASK --after CURSOR --json` 只读增量投影任务事件；游标不透明，白名单类型与字段裁剪，缺失日志返回空列表并原样返回游标 |

## 3. 命令与返回

调用方只通过这些命令和 stdout JSON 与 Orbit 交互，不读写 `.orbit` 内部文件，不猜 socket。命令清单与返回字段以 integration.json 的 `commands` 为准。

- `orbit start ...`：返回 `task_directory`、`status`。`status=starting` 只表示任务记录已建立；调用方需要真实宿主会话（`--thread`、`--socket`），Orbit 不创建 Root 会话。 运行时完成宿主归属校验与任务绑定后才进入 `running`；调用方应回读状态确认，绑定拒绝沿既有 `failed` 错误路径记录，不把启动返回当作已经执行。
- `orbit check TASK_DIRECTORY`、`orbit stop TASK --json`：返回 `task_directory`、`command_id`、`status`。`queued` 只是请求入队，不是检查结果，也不是已停止。`check` 也可返回 `rejected` 及原因。
- `orbit status TASK --json`、`orbit export TASK --output FILE`、`orbit doctor --json`、`orbit version --json`、`orbit capabilities --json`：见 integration.json。
- `orbit conversation TASK --after OFFSET --json`：见 §4.1。

### 按外部引用查询（1.2）

`orbit status --external-ref REF [--project DIR] --json` 与位置参数 `TASK` 互斥。REF 校验沿用 `start --external-ref`，逐字精确全等匹配，不按前缀/大小写折叠；包括终态与重复引用的全部任务，按创建时间（同时间按 id）新到旧返回。成功**恒为** `{ "tasks": [...] }`，元素与单任务 status 同形；无匹配退出码 0 且 `{ "tasks": [] }`。无 `external_refs` 的旧记录不匹配；start 不按引用去重。

省略 `--project` 时从当前目录定位项目；提供时使用该项目根，可在项目外查询。扫描/读取/解析或参数校验失败仍是非零退出码与原有错误语义，不把失败伪装为空数组。一条本项目坏记录也可使查询失败，调用方不能把它判成“任务不存在”。查询只读、不连接会话、不改变任务。

## 4. `status --json` 冻结字段

出现条件：`always` 总是存在（值本身可为 null 的字段在正文说明）；`when_provided` 仅在启动时提供过；`after_check` 在首个有效检查记录覆盖后出现；`when_reported` 仅当检查者为该项给出；`after_stop` 在停止流程开始并产生记录后出现；`when_resumed` 仅由 `--resume-from` 建立的任务。
`when_wake_requested` 表示仅在接续启动时显式提供 `--resume-wake`。

| 字段 | 出现 |
| --- | --- |
| `id`、`status`、`project_root`、`created_at` | always |
| `stop_reason`、`stop_confirmation.confirmed` | after_stop |
| `requirement_coverage.current`、`.complete`、`.ready`、`.gap` | after_check |
| `requirement_coverage.items[].requirement/status/evidence/scope` | after_check |
| `requirement_coverage.items[].ref` | when_reported |
| `requirement_coverage.items[].gap_kind`、`.verified_by_check` | when_reported（1.6 起） |
| `external_refs` | when_provided |
| `continuation.previous_task` | when_resumed |
| `continuation.wake.status`、`continuation.wake.message_id` | when_wake_requested |
| `session_binding.provider`、`.session_id`、`.session_file`、`.launch_message_id`、`.launch_message_source` | always（未知值为 null，见下） |

`status` 取值：`starting`、`running`、`complete`、`paused`、`needs_user`、`failed`、`stop_unconfirmed`；终态为除前两项外的其余五个。`complete` 的含义见任务运行合同（独立检查与实际收尾均通过），不等于集成方自己的业务完成。已确认停止只看 `stop_confirmation.confirmed == true`；`stop_unconfirmed` 与 `failed` 不保证资源已停止，调用方不得据此放行第二写者。

`requirement_coverage.items` 是检查者逐要求的枚举与证据，`ready=false` 时 `gap` 说明原因；缺失、重复或对不上的项由调用方按自己的规则判未验证，Orbit 不替调用方匹配。

`gap_kind` 仅用于 unverified，取值为 `not_checked`（检查者尚未核查）、`evidence_missing`（缺少必要证据）、`defect`（发现缺陷）。未提供时原因未知，不能从 evidence 自由文本推导。`verified_by_check` 是已核实结论的来源检查号字符串，不改变当前覆盖的版本门；同版本尚未检查项可沿用未被撤销的有效结论，新缺证或反证可以撤销。输入、产物或工作区变化后不能直接沿用完成资格。原 status、scope、任务状态和 attention 枚举保持不变。

### 持久变更标记（1.3）

`revision` 为从 1 起的任务内整数，`updated_at` 为 UTC ISO-8601 最后一次持久语义变化时间；同一秒的变化可有相同时间戳。以 `(id, revision)` 作为键，新任务（含接续任务）重新起算。二者与 state 同一次原子写入，读命令/无变化保存或 tick 不改变；重启继续使用已落盘计数，调用方携带的旧元数据不具有裁定权。

计数比较已落盘状态的语义投影，排除 revision/updated_at 自身、各层 usage（含检查/判断回执）、纯时间调度 next_check_at 与 requirement_coverage.current/ready/gap；状态、检查登记、finding 开闭、覆盖登记、停止确认/诊断、外部引用及人工排队/检查触发等持久变化计入。它不标识整份 status JSON：覆盖的现算 current/ready/gap、用量和只读投影可能变化而计数不变。无字段的旧任务读取保持未知，不合成；第一次实际保存才初始化。读或写失败原样失败，不覆盖坏旧状态重新起算。

### 关注状态（1.3）

`attention` 只含 phase（字符串）与 needs_user（布尔）；仅 status 返回（单任务或 tasks 元素），不持久化，不新增 reason_code/next_action_code。遇未知 phase 按未知处理；needs_user=true 仅表示 status=needs_user 的已停止终态，不表示等待原生答复，也不承诺答复后恢复。

| phase | 现有谓词与优先级 |
| --- | --- |
| needs_user | needs_user 终态，布尔 true |
| failed | failed，无论停止是否确认，仍需读 stop_confirmation |
| stopping | stop_unconfirmed，或运行中 completion_stop_pending |
| stopped | complete/paused；不能只凭此码替代停止回执 |
| starting | starting |
| checking | 运行中检查 in-flight 或人工终检已排队 |
| reworking | 运行中既有 rebind、开放 finding 或 recheck 线索 |
| implementing | 运行中其余情况；普通未来定时检查不算 checking |
| unknown | 未识别 status |

状态分支优先，运行中依次 stopping→checking→reworking→implementing。人工 stop 仅存在 inbox 尚未落盘时，不据此伪造 stopping。

### 最近完成检查（1.3）

`latest_check` 为 checks 中最后一条 finished_at 非空的已完成记录，含失败/陈旧，不取“最后可采纳结果”，不含进行中记录；无完成检查时省略。它仅是 status 只读投影，export 保留原始状态/检查材料。

冻结字段：number、role、kind、finished_at、input_digest、artifact_digest、stale、stale_reasons、terminal、failure_kind、models、input_current。身份缺失从该检查 scope.json 回退，仍缺为 null，不编造。stale_reasons 为已记录的 workspace/artifact/input/host/dispute 数组，缺记录为空；stale 保留旧记录 null。terminal 优先 failed→stale→原 verdict（continue/correct/pause/complete/needs_user），旧缺结果为 null；failure_kind 为已记录 auth_or_quota/unavailable/invalid_result，缺时 null。role 是 reviewer/process_reviewer/adjudicator 等实际检查种类，不是模型身份，旧缺字段 null。

models 从该检查 usage.calls 的 model（缺时仅用该回执 requested_model）及 provider 得到完整 provider/model，去重保序数组，可空；不借任务选择补造模型。input_current 只比较检查输入摘要与当前输入摘要，缺任一摘要为 null；不说明产物有效性，当前成果是否仍对应检查应读 requirement_coverage.current。

该投影不包含结论/错误/finding 文本、工作区路径、供应商响应或用量明细；已有 status 的内部字段仍不在本合同冻结范围内。

### 会话绑定投影（1.5）

`session_binding` 是 status 只读投影（单任务或 `tasks` 元素），不持久化；export 保留原始状态，不含该对象。五个键总是存在，未知值明确为 `null`，不猜路径、不臆造启动证据。

- `provider`、`session_id`：任务建立时冻结的连接记录（`session_id` 是真实 OMP 会话 id，见 §9）；记录缺失时为 `null`。
- `session_file`：宿主实际报告的 Root 会话转录文件路径——attach 时记录、之后 tick 补取，会话文件变化时更新为最新观测值；宿主未报告或旧记录缺失时为 `null`。Orbit 不定位、不猜测路径。
- `launch_message_id` 与 `launch_message_source`：本任务监督起点的**稳定启动边界**，不随后续纠正、提醒或新的用户消息推进。取值优先级：程序投递的初始指令（`--prompt-file` 启动，attach 投递成功时由运行程序持久记录，来源 `orbit_instruction`）；接续任务的真实原生接续消息（§7）；否则创建时记录的原生启动消息；后两者来源为 `native_user_message`。全部缺失时二者为 `null`。旧版 `--prompt-file` 记录没有持久投递标记，launch 保持 `null`，不借 `sent_message_ids[0]` 等内部字段回填；旧版原生/接续任务按创建时记录的来源回读。
- `launch_message_source` 只有 `native_user_message`（宿主会话中的真实原生用户消息）与 `orbit_instruction`（运行程序投递的初始指令消息）两个取值；未知为 `null`。
- 内部字段 `last_user_message_id`（随后续真实用户消息推进）、`sent_message_ids`、`root_session_file` 含义不变；调用方需要稳定启动边界时必须使用 `launch_message_id`，不得用 `sent_message_ids[0]`（原生消息启动的任务上它是第一条纠正消息）或 `last_user_message_id`（它不是启动边界）。

### 接续唤醒回执（1.5）

`continuation.wake` 是可选 `--resume-wake` 的持久回执，export 原样保留；默认接续没有该键。`status` 为 `requested`（意图已记录，尚未尝试）、`unconfirmed`（投递已尝试，结果未知）或 `sent`（实际原生 custom message ACK）；`message_id` 仅在取得 ACK 后记录，否则为 `null`。

运行时完成精确宿主绑定后，经既有 send_message 通道投递一次明确程序来源的续接消息，不冒充用户、不新增范围或型号授权。尝试先于发送持久化；状态离开 `requested` 后不自动重发。`sent` 不证明执行、采用或完成；失败不改变既有停止门。启动边界仍是 `session_binding` 中的真实原生接续用户消息，不是唤醒消息。


### 4.1 可见助手消息（1.7）

`orbit conversation TASK --after OFFSET --json` 是只读增量投影，供集成方显示助手的可见回复，不是新的 AI 运行时或对话记忆。它只读取任务 `session_binding.session_file` 中**宿主报告**的会话文件；不定位、不猜测其它路径，不写任务状态，不启动会话，不调用模型。

返回字段固定为：`session_file`（真实路径）、`offset`（本次起点）、`next_offset`（下次起点，字节偏移）、`messages`（最多 100 条，每条 `id`/`role`/`text`/`created_at`，只含可见 assistant 文本）、`truncated`（本次读取触及 1 MB 上限）、`dropped`（超过 100 条未返回的条数）、`read_at`。`--after` 缺省为 0，必须是非负整数。只解析完整的 JSONL 行；半行留待下次。偏移越界、文件缺失、符号链接或不可读一律失败，不合成空消息；`messages` 为空表示这段没有新的可见助手文本，不代表任务完成或没有回复。

该命令不改变既有 `status`/`stop`/`resume` 语义，也不提供流式推送；集成方按自己的间隔轮询，并保存 `next_offset`。

### 4.2 任务事件游标（1.8）

`orbit events TASK --after CURSOR --json` 只读增量投影任务自己的 `events.jsonl`，供集成方跟随检查、发现、纠正与停止事实，不需要轮询 `status` 差分。不写任务、不启动会话、不调用模型、不合成事件。

返回字段固定为：`cursor`（本次起点）、`next_cursor`（下次起点）、`events`、`truncated`、`skipped`、`unreadable`、`dropped`、`read_at`。

- `CURSOR` 对调用方不透明；v1 编码字节位置，调用方原样保存与回传，不解析。
- 只解析完整行；半行留待下次。
- 白名单外的事件计入 `skipped`，非 JSON 行计入 `unreadable`，都不猜。
- 单次上限 1 MB 或 200 条；超出时 `truncated=true`，多出的白名单事件计入 `dropped`。
- 任务存在但日志尚未创建时返回空列表并原样返回游标；游标非法或越界、任务不存在时失败。
- v1 不带 `revision`：追加事件与状态 revision 不是同一次原子写入。
- 事件是追加顺序的观察；`at` 精度到秒，可能相同。当前状态仍以 `status` 为准，停止只看 `stop_confirmation.confirmed`。

公开类型与保留字段（其余字段一律丢弃，包括工作区路径、自由文本原因、错误文本与问题正文）：

| kind | 保留字段 |
| --- | --- |
| `check_started` | `number`、`role`、`check_kind`、`trigger`、`manual`、`model`、`input_digest`、`artifact_digest` |
| `check_finished` | `number`、`stale`、`stale_reasons`、`verdict`、`finding_ids`、`resolved_ids`、`artifact_digest` |
| `check_failed` | `number`、`failure_kind` |
| `finding_recorded` | `check`、`finding_id` |
| `finding_resolved` | `id`、`check` |
| `instruction_amended` | `source`（仅 `kind` 与 `id`） |
| `correction_sent` | `id`、`artifact_digest`、`input_digest` |
| `finalization_notice` | `check`、`version` |
| `completion_stop_queued` | 仅 `kind` 与 `at` |
| `stopped` | `confirmed` |
| `stop_unconfirmed` | 仅 `kind` 与 `at` |
| `member_settled` | `thread_id`、`status` |

事件类型放在 `kind`；`check_started` 自己的检查类型放在 `check_kind`，避免与信封字段冲突。未知 `kind` 由调用方忽略；新类型只在次版本增加。

## 5. 引用字段（不透明，通用）

**检查项引用 `ref`**：检查结果 schema 的每个覆盖项可带可选 `ref`（最多 200 字符，不含控制字符；空串或纯空白按未提供处理，不保存，`status` 中该项没有 `ref`）。检查者只在原要求、修订或依据本来就给该要求标了编号时逐字抄录，不得自编、规范化或推断；没有就省略。Orbit 原样保存并在 `requirement_coverage.items[].ref` 返回，不解释、不要求唯一、不要求与任何东西匹配（同一编号可对应多个覆盖项，也可没有）。其余不合规（超长、含控制字符、非字符串）与其他字段一样属于结果契约违规，检查结果被拒绝并走既有的检查失败路径；因此检查者不确定时应省略而不是猜写。

**任务外部引用 `external_refs`**：`orbit start` 可重复带 `--external-ref REF`（扩展的 `orbit` 工具 `start` 动作对应参数 `external_refs`）。每个为 1–256 字符、非空白、无控制字符、互不相同的字符串，最多 16 个；非法值在建立任何会话或任务前被拒绝。Orbit 原样保存为 `external_refs`（保持顺序），在 `status --json`、详细状态与 `export` 中原样输出；不解析前缀、不据此授权、不改变任何行为。`--resume-from` 建立的新任务**不继承**旧任务的引用，需要时重新传入；旧任务可经 `continuation.previous_task` 反查。自动入口（未经显式 `start` 参数）建立的任务没有外部引用。

## 6. 停止回执

`stop --json` 的 `queued` 只表示请求入队。是否真实停止只看 `status` 与 `stop_confirmation.confirmed`；任务可能因停止失败停在 `stop_unconfirmed`，此时必须继续按未知处理。Temporal 取消、杀进程或入队本身都不是停止证据。

## 7. `resume_from` 的范围与前提

- 只接续同一 Root 会话、同一项目、已确认停止的 `paused` 或 `needs_user` 任务；两者的旧终态含义保持不变，由 `from_status` 明确声明。
- 需要一条**真实的原生用户消息**（`--message-id`），来源于同一 Root 会话；调用方无法用外部文本伪造。外部系统收到的用户答复要接续，必须先以原生用户消息进入同一 Root 会话。
- 复制原要求与有效修订，建立新的监督边界；旧任务终态、成员、检查与用量不迁入，监督空档不被追认。
- 可选 `--resume-wake` 在新任务绑定后投递程序唤醒，默认关闭；不改变上述续接前提，回执见 §4。

## 8. 契约测试

`tests/integration_contract_test.rb` 用一个只使用上述公开命令和字段的假调用方，对真实 CLI、任务记录、命令队列、运行时 tick、覆盖存储、停止与导出路径依次跑：能力清单、启动（带外部引用）、检查、覆盖回传（带 `ref`）、状态、停止回执、接回、导出。OMP Root 会话与检查模型是边界上的两个替身，所以它证明合同面与字段形状，**不证明**模型行为或真实宿主会话。它由 `npm test` 运行，发布前必须通过；真实会话下的验收另按任务运行合同与验收记录进行。合同字段清单读取 integration.json，不在测试里另写一份。

## 9. 外部集成会话与调用方控制通道（1.2）

启动 `orbit omp` 时可选择以下进程环境变量；未设时保持普通交互入口与懒建通道行为。它们不写全局设置、不登记会话，不改变任务建立后的检查、监督或停止。

- `ORBIT_EXTERNAL_INTEGRATION=1`：关闭该会话的自动入口判定；不因用户首条“请用 Orbit 受控执行…”自动连接/调用 `entry`、建立任务、写入口判定或注入入口提示。Root 的显式 `start` 工具仍可用，集成方节点必须核对任务的 `external_refs`，不能把开启此模式解释为只有集成方能建任务。
- `ORBIT_CONTROL_SOCKET=/absolute/private-dir/control.sock`：调用方指定路径，扩展在主会话 `session_start` 就监听，首条消息之前即可用于 `start --socket`。此变量可单独使用；仅启用外部模式但未指定路径时也提前建立默认私有通道，但本能力不提供默认路径发现接口。
- 指定路径须是已经规范的绝对路径（没有 `.`、`..` 或多余分隔符），OMP 环境变量与 `start --socket` 使用**逐字相同**字符串；不做 `realpath`，不要将 `/tmp/...` 改写为 `/private/tmp/...`。Unix 路径长度包括结尾 NUL：macOS 路径本身最多 103 字节，Linux 最多 107 字节。
- 调用方先建立同一 uid 所有、无组/其他用户权限的私有父目录（建议 0700）；Orbit 不更改父目录权限、不删除该目录或其其他文件。非法路径/权限、非 socket 文件、其他 uid 的 socket、活监听或无法确认已死的通道均拒绝，不覆盖。只有私有目录中的同 uid 死 socket，且探测后身份未换，才可清理重用；退出仅释放本进程绑定的自有 socket。
- 为避免 Node 关闭监听时删除调用方替换文件，Orbit 在自有私有临时目录监听，以硬链接暴露指定路径；调用方目录须与私有临时目录同文件系统且支持 Unix socket 硬链接，失败时拒绝启动通道，不覆盖调用方文件。
- 会话切换/分支/树切换关闭原通道；随后的 `session_start` 在同一指定字符串路径重新监听。进程崩溃的遗留由调用方管理，不扫描其他目录。
- `start` 仍要 `--thread`；会话 id 来自 OMP 自身的 RPC `get_state.sessionId`。首条消息前可得性只在 OMP 18.9.0 上验证，不承诺所有版本，也不新增 `status --session` 或会话登记。详细历史记录可从 Git 历史取回。

## 10. 严格模型授权（1.4）

普通任务按角色候选池选型。执行者角色未单独配置时，继续使用旧共享池迁移值；无旧候选时沿用当前 `@task` 解析。显式配置后（包括空池），执行者自动选型仅使用执行者池中当前 OMP 会话可用的型号；空池或无可用候选不回退到 `@task`，也不跨角色借候选。检查者池遵循同样的未配置兼容规则；显式配置后检查者自动选型仅使用检查者池与当前会话目录的交集，空池或无可用候选不跨池或回退全目录。既有显式 `review-model` 可继续指定任一可解析且可运行的型号。Root 仍使用当前 OMP 会话模型。需要硬授权时，显式 `start` 可重复传 `--allowed-model provider/model`（原生工具对应 `allowed_models` 数组）；只接受 1–64 个互不重复、无空白的完整精确身份，不支持别名/通配符/供应商前缀。名单不是候选池，不修改用户全局池、模型配置或凭据。未指定时普通任务不增加限制。

调用方还可在该次 `orbit omp` 启动时设置 `ORBIT_ALLOWED_MODELS='["provider/model"]'`，作为会话的授权上限（该进程启动时关闭可选 memory/advisor/autolearn/STT AI 服务，保持调用前约束）：首条消息及建任务之前的原生请求也受限，显式 start 默认把它冻结进新任务；任务参数只能取其子集。严格会话跳过自动入口判定，使用显式 start。**需要限制首条消息或任务绑定之前的调用，必须设置此环境变量**；仅 CLI 参数不追认建任务前的调用。空/坏 JSON、未知型号身份或缺必要宿主接口拒绝，不默默降级。RPC 的 get_available_models 仍是可用性目录，不能替代授权名单。

`status --json`/按引用查询/导出保留 `model_authorization.allowed_models`（数组）与 `.auxiliary_judgments="disabled"`。任务名单创建后不可由 review-model、OMP 原生模型切换、输入/产物变化或失败回退扩大；接续 paused 时默认继承，可显式缩小，不能扩大。新的独立普通任务不继承旧任务名单；只有已确认停止后才释放旧任务对宿主请求的限制，未知停止仍保持边界。会话环境上限持续至该 OMP 进程结束，其他普通会话不受影响。

Root 原生调用、原生成员派发/实际请求、检查者/复核者在调用前校验精确型号；所有重选与失败回退只在名单内，全部不可用或已排除时沿现有检查阻断状态报告，不更换供应商、不把失败作通过。Root 当前型号或显式检查型号不在名单内时 start 拒绝。严格模式下原生型号循环选择拒绝，使用精确授权型号选模；普通会话循环保持。可选 JEV 入口/选型/过程与成员适配判断在严格任务关闭，不调用其独立模型；成员保留事实与 Root 决策，检查/完成/停止硬门保持。

宿主须提供公开 `Agent.streamFn` 与 `ModelRegistry.resolver/getApiKey` 接缝；安装前核验，缺失时严格任务拒绝。守卫在原生 stream 与凭据 resolver（含已缓存 resolver 的实际解析）之前执行，不靠 prompt、检查后拒收或扩展钩子抛错。授权是对配置的 provider/model 精确身份的限制，不是上游实际路由型号认证；实际身份与未知字段继续按回执记录。真实停止/恢复仍使用 §6/§7，名单不授予释放 writer 或伪造确认的权限。

## 11. 变更记录

- 1.0（本合同首版）：命令与冻结字段、能力清单、覆盖项 `ref`、任务 `external_refs`、`resume_from` 范围声明。
- 1.1：覆盖项 `ref` 的空串或纯空白按未提供处理（原先整次检查被拒绝）；`check_coverage_ref` 增加 `blank_is_omitted`。只放宽检查者输出，不改变任何已有返回字段；依据是对真实检查者的试验中 7 次有 1 次写了 `"ref": ""`。

- 1.2：外部会话模式、调用方指定控制通道与按外部引用查询；均为默认关闭的可选启动模式或只读新增命令面。

- 1.3：持久 revision/updated_at、粗粒度 attention 与最近完成检查 latest_check；旧字段及 status 取值不变。

- 1.4：可选严格模型名单、会话调用前授权上限与冻结任务字段；普通偏好池及既有 status 取值不变。
- 1.4（追加能力）：`resume_from.from_status` 增加已确认停止的 `needs_user`；旧记录仍是已停止终态，续接建立新任务边界且不恢复旧成员、检查或用量。
- 1.5：只读 `session_binding` 投影（provider/session_id/session_file/launch_message_id/launch_message_source）：稳定启动边界与宿主报告的会话文件路径，缺失为 null；prompt-file 启动的投递边界由运行程序在 attach 投递成功时持久记录，旧记录不借内部字段回填；既有内部字段含义与 status 取值不变。
- 1.5（追加）：可选 `resume_wake` 与 `continuation.wake` 回执，绑定后投递一次程序来源续接消息；默认行为、启动边界及既有状态取值不变。

- 1.6：新增检查覆盖缺口分类与来源检查号；未检查项由检查流程续查，保留当前版本独立终检及实际停止门。

- 1.7：新增只读 `conversation_read`：按字节偏移读取宿主报告的会话文件中可见的助手消息，返回 `next_offset`。不写任务、不调用模型、不重放对话；缺失/越界失败而不是合成消息。
- 1.8：新增只读 `events_read`：按不透明游标读取任务事件，固定白名单与字段裁剪；单次 1 MB 或 200 条上限，缺失日志返回空列表并原样返回游标。不写任务、不调用模型、不合成事件；v1 不带 revision。

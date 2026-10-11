# Orbit 集成合同

合同版本：1.0

面向把 Orbit 当作外部执行与检查服务的集成方（例如 Loom）。本合同只冻结下面列出的命令、返回字段与结果 schema；这些之外的一切（包括 `status --json` 里的其他字段）都是 Orbit 内部实现，随时可变。产品语义以 [任务运行合同](task-runtime.md) 和 [检查结果 schema](check-result.schema.json) 为准，本文件与它们冲突时以它们为准并修正本文件。机器可读形式见 [integration.json](integration.json)，`orbit capabilities --json` 与契约测试都读取它，决定理由见 [ADR-010](../docs/adr/010-integration-contract.md)。

## 1. 合同版本与兼容规则

- 合同版本是 `主版本.次版本`，与软件版本（`orbit version`、`package.json`）**相互独立**。集成方不应比较软件版本号判断可用，只看合同主版本与能力清单。
- **同一主版本内只加不改不删**：可以新增命令、返回字段、能力、检查结果的可选字段（次版本加一）；不得改变既有字段的含义、类型、取值范围，不得删除或改名。`status` 的取值集合也在主版本内冻结，新增取值按破坏性改动处理。
- 破坏性改动必须升主版本，并在发布说明中写明对应变化；同一发布可以先并存新旧能力，由能力清单区分。
- 集成方对未声明的字段保持容忍：读到合同未列出的字段忽略，不依赖其存在或形状。

## 2. 能力协商

`orbit capabilities --json` 只读、不连接会话、不调用模型、不读任务，返回：

```json
{ "integration_contract": { "name": "orbit-integration", "version": "1.0", "major": 1 },
  "orbit": { "version": "<软件版本，仅供显示>" },
  "capabilities": { "<能力名>": { "since": "<引入该能力的合同版本>", "...": "该能力的限制" } } }
```

集成方在启动与每次运行前检查自己需要的能力名及其限制；不满足就按自己的规则阻断，不猜测。能力只在 Orbit 已实际接线时才出现。1.0 的能力：

| 能力 | 含义与限制 |
| --- | --- |
| `status_json` | `orbit status TASK --json` 返回 §4 的冻结字段 |
| `export` | `orbit export TASK --output FILE` 返回 §3 的字段；归档内 `task/state.json` 带有同一份冻结字段 |
| `stop_receipt` | 停止回执：`stop --json` 只表示入队，已确认停止只看 `stop_confirmation.confirmed` |
| `start_external_refs` | `start` 可带 `--external-ref`；`max_refs`、`max_length` 为强制上限；`inherited_on_resume=false` |
| `check_coverage_ref` | 检查结果的每个覆盖项可带 `ref`；`max_length` 为 schema 上限 |
| `resume_from` | `start --resume-from`；`from_status` 列出可接续的旧任务终态（当前仅 `paused`）；`requires=native_user_message` |

## 3. 命令与返回

调用方只通过这些命令和 stdout JSON 与 Orbit 交互，不读写 `.orbit` 内部文件，不猜 socket。命令清单与返回字段以 integration.json 的 `commands` 为准。

- `orbit start ...`：返回 `task_directory`、`status`。`status=starting` 只表示任务记录已建立；调用方需要真实宿主会话（`--thread`、`--socket`），Orbit 不创建 Root 会话。
- `orbit check TASK_DIRECTORY`、`orbit stop TASK --json`：返回 `task_directory`、`command_id`、`status`。`queued` 只是请求入队，不是检查结果，也不是已停止。`check` 也可返回 `rejected` 及原因。
- `orbit status TASK --json`、`orbit export TASK --output FILE`、`orbit doctor --json`、`orbit version --json`、`orbit capabilities --json`：见 integration.json。

## 4. `status --json` 冻结字段

出现条件：`always` 总是存在；`when_provided` 仅在启动时提供过；`after_check` 在首个有效检查记录覆盖后出现；`when_reported` 仅当检查者为该项给出；`after_stop` 在停止流程开始并产生记录后出现；`when_resumed` 仅由 `--resume-from` 建立的任务。

| 字段 | 出现 |
| --- | --- |
| `id`、`status`、`project_root`、`created_at` | always |
| `stop_reason`、`stop_confirmation.confirmed` | after_stop |
| `requirement_coverage.current`、`.complete`、`.ready`、`.gap` | after_check |
| `requirement_coverage.items[].requirement/status/evidence/scope` | after_check |
| `requirement_coverage.items[].ref` | when_reported |
| `external_refs` | when_provided |
| `continuation.previous_task` | when_resumed |

`status` 取值：`starting`、`running`、`complete`、`paused`、`needs_user`、`failed`、`stop_unconfirmed`；终态为除前两项外的其余五个。`complete` 的含义见任务运行合同（独立检查与实际收尾均通过），不等于集成方自己的业务完成。已确认停止只看 `stop_confirmation.confirmed == true`；`stop_unconfirmed` 与 `failed` 不保证资源已停止，调用方不得据此放行第二写者。

`requirement_coverage.items` 是检查者逐要求的枚举与证据，`ready=false` 时 `gap` 说明原因；缺失、重复或对不上的项由调用方按自己的规则判未验证，Orbit 不替调用方匹配。

## 5. 引用字段（不透明，通用）

**检查项引用 `ref`**：检查结果 schema 的每个覆盖项可带可选 `ref`（1–200 字符，去掉首尾空白后非空，不含控制字符）。检查者只在原要求、修订或依据本来就给该要求标了编号时逐字抄录，不得自编、规范化或推断；没有就省略。Orbit 原样保存并在 `requirement_coverage.items[].ref` 返回，不解释、不要求唯一、不要求与任何东西匹配（同一编号可对应多个覆盖项，也可没有）。格式不合规（超长、空白、含控制字符、非字符串）与其他字段一样属于结果契约违规，检查结果被拒绝并走既有的检查失败路径；因此检查者不确定时应省略而不是猜写。

**任务外部引用 `external_refs`**：`orbit start` 可重复带 `--external-ref REF`（扩展的 `orbit` 工具 `start` 动作对应参数 `external_refs`）。每个为 1–256 字符、非空白、无控制字符、互不相同的字符串，最多 16 个；非法值在建立任何会话或任务前被拒绝。Orbit 原样保存为 `external_refs`（保持顺序），在 `status --json`、详细状态与 `export` 中原样输出；不解析前缀、不据此授权、不改变任何行为。`--resume-from` 建立的新任务**不继承**旧任务的引用，需要时重新传入；旧任务可经 `continuation.previous_task` 反查。自动入口（未经显式 `start` 参数）建立的任务没有外部引用。

## 6. 停止回执

`stop --json` 的 `queued` 只表示请求入队。是否真实停止只看 `status` 与 `stop_confirmation.confirmed`；任务可能因停止失败停在 `stop_unconfirmed`，此时必须继续按未知处理。Temporal 取消、杀进程或入队本身都不是停止证据。

## 7. `resume_from` 的范围与前提

- 只接续同一 Root 会话、同一项目、已确认停止的 `paused` 任务（`status=needs_user` 等其他终态当前**不被接受**，由 `from_status` 声明）。
- 需要一条**真实的原生用户消息**（`--message-id`），来源于同一 Root 会话；调用方无法用外部文本伪造。外部系统收到的用户答复要接续，必须先以原生用户消息进入同一 Root 会话。
- 复制原要求与有效修订，建立新的监督边界；旧任务终态、成员、检查与用量不迁入，监督空档不被追认。

## 8. 契约测试

`tests/integration_contract_test.rb` 用一个只使用上述公开命令和字段的假调用方，对真实 CLI、任务记录、命令队列、运行时 tick、覆盖存储、停止与导出路径依次跑：能力清单、启动（带外部引用）、检查、覆盖回传（带 `ref`）、状态、停止回执、接回、导出。OMP Root 会话与检查模型是边界上的两个替身，所以它证明合同面与字段形状，**不证明**模型行为或真实宿主会话。它由 `npm test` 运行，发布前必须通过；真实会话下的验收另按任务运行合同与验收记录进行。合同字段清单读取 integration.json，不在测试里另写一份。

## 9. 变更记录

- 1.0（本合同首版）：命令与冻结字段、能力清单、覆盖项 `ref`、任务 `external_refs`、`resume_from` 范围声明。

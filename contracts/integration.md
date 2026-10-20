# Orbit 集成合同 2.0

合同版本：2.0.0

面向把 Orbit 当作 DSH 外部执行与检查服务的集成方（Loom）。本合同只冻结下列命令、返回字段与语义；其余 `.orbit` 内部文件、进程实现与未列出的字段随时可变。任务语义以 [任务运行合同](task-runtime.md)、检查结果以 [check-result.schema.json](check-result.schema.json) 为准，冲突时以它们为准并修正本文件。机器可读形式见 [integration.json](integration.json)，`orbit capabilities --json` 提供能力清单。

2.0 是破坏性主版本：**不保留 1.x 命令、字段、`provider=omp`、`session_file`、字节偏移或兼容读取路径**。迁移方必须按 2.0 重写调用点。

## 1. 版本与兼容

- 合同版本 `主版本.次版本.修订`，与软件版本独立。集成方只比较主版本与能力清单，不比较软件版本。
- 同一主版本内只加不改不删；新增能力升次版本，破坏性改动升主版本。
- 未声明字段必须忽略；未声明能力必须视为不可用，不得猜测。

## 2. 能力协商

`orbit capabilities --json` 只读、不连接会话、不调用模型、不读任务：

```json
{
  "integration_contract": { "name": "orbit-integration", "version": "2.0.0", "major": 2 },
  "orbit": { "version": "<软件版本，仅供显示>" },
  "capabilities": {
    "launch": { "since": "2.0.0", "stdin": "keep-open", "process_owner": "caller" },
    "headless": { "since": "2.0.0", "spec_version": 1, "env": ["ORBIT_BOOTSTRAP", "ORBIT_BOOTSTRAP_RESULT"] },
    "status": { "since": "2.0.0" },
    "status_by_external_ref": { "since": "2.0.0", "max_refs": 8, "max_length": 256 },
    "events": { "since": "2.0.0", "cursor": "opaque" },
    "sessions": { "since": "2.0.0", "visible_text": true, "user_messages": true, "activities": true, "questions": true, "deliveries": true },
    "questions": { "since": "2.0.0" },
    "answer": { "since": "2.0.0" },
    "prompt": { "since": "2.0.0" },
    "abort": { "since": "2.0.0", "scope": "session" },
    "stop": { "since": "2.0.0", "receipt": "evidence" },
    "export": { "since": "2.0.0", "self_contained": true }
  }
}
```

未实现的能力不得出现在清单里；本版没有 `models`、`launch ready event` 或 1.x 兼容能力。

## 3. 命令

所有命令输出单个 JSON 文档到 stdout；失败时非零退出并输出可读错误到 stderr。调用方不读写 `.orbit` 内部文件，不猜 socket 路径。

| 命令 | 用途 |
| --- | --- |
| `orbit capabilities --json` | 能力协商；只读 |
| `orbit launch --json [--profile P] [--home DIR] [--project DIR]` | 返回 DSH 启动参数；不启动进程 |
| `orbit status [TASK] --json [--project DIR]` | 任务事实与阻塞原因；只读 |
| `orbit status --external-ref REF --json [--project DIR]` | 精确引用查询；成功恒返回 `{tasks:[]}` |
| `orbit events [TASK] --after CURSOR [--json] [--project DIR]` | 增量任务事件；只读 |
| `orbit sessions [TASK] --json [--project DIR]` | Root/成员会话投影；只读 |
| `orbit questions [TASK] --json [--project DIR]` | 问题记录；只读 |
| `orbit answer [TASK] --question ID --selected A,B [--custom TEXT] --json` | 答复待答问题；需要活宿主 |
| `orbit prompt [TASK] --message TEXT --json` | 向绑定 Root 注入原生用户消息；需要活宿主 |
| `orbit abort [TASK] --json` | 中止绑定会话；不等于任务停止 |
| `orbit stop [TASK] --json [--project DIR]` | 请求停止；返回不表示已确认 |
| `orbit export [TASK] --output FILE --json [--project DIR]` | 自包含证据包 |

`--project` 省略时从当前目录定位项目。`TASK` 省略时取最新任务；有多个历史任务时优先 running。

## 4. `launch`

```json
{
  "kind": "dsh",
  "contract": "2.0.0",
  "profile": "orbit-node",
  "cwd": "/abs/project",
  "argv": ["--profile", "orbit-node"],
  "env": { "DSH_HOME": "/abs/isolated-home" },
  "stdin": "keep-open",
  "control_socket": "/abs/project/.orbit/orbit.sock",
  "ready": { "kind": "socket", "timeout_ms": 30000 }
}
```

- 进程所有权属于调用方（Loom）；Orbit 不启动、不托管进程。
- `env` 只列必须覆盖的变量；调用方合并自己的环境。
- `--bootstrap FILE` 时 spec 额外带 `bootstrap {path,result,sha256}`，env 带 `ORBIT_BOOTSTRAP`/`ORBIT_BOOTSTRAP_RESULT`；宿主读取冻结 spec 后自行创建 Root、start 任务并发送首条指令，成功后写 result `{ok:true,taskId,sessionId,project}`，失败写 `{ok:false,error}`。
- 非 headless 调用方拉起进程后调用 `orbit start`，再轮询 `control_socket` 出现；socket 由任务接纳后创建。
- headless spec v1：`{version:1,instruction,project,externalRefs?,allowedModels?,model:{provider,model}}`。

## 5. `status`

`status` 只读、不触发检查、不调用模型。字段：

```json
{
  "ok": true,
  "taskId": "task-...",
  "status": "running",
  "inputVersion": 2,
  "artifactRoot": "/abs/project",
  "externalRefs": ["loom:run-1"],
  "modelAuthorization": { "allowedModels": ["deepseek-account/deepseek-flash"] },
  "checksInFlight": null,
  "stop": "user",
  "stopConfirmation": {
    "confirmed": true,
    "at": "2026-10-20T...",
    "evidence": { "fence_persisted": true, "root_idle": true, "members_stopped": true, "checks_settled": true },
    "missing": []
  },
  "completionInvalidation": null,
  "members": [{ "id": "...", "status": "registered", "workUnitId": "wu-..." }],
  "workUnits": [{ "id": "wu-...", "status": "declared", "goal": "..." }],
  "checks": [{ "number": 1, "status": "completed", "verdict": "continue" }],
  "openFindings": ["finding-id"],
  "openDisputes": []
}
```

- `status` 取值：`starting | running | complete | paused | needs_user | failed | stop_unconfirmed`。
- `stop` 仅为最近停止原因；是否已确认只看 `stopConfirmation.confirmed`。
- 字段缺省表示尚未产生/未知，不伪造。
- `members`、`workUnits` 中的额外字段可由 Orbit 增加；集成方只依赖上述字段。

## 6. `events`

```json
{ "taskId": "task-...",
  "events": [{ "seq": 12, "at": "...", "type": "check/completed", "data": { } }],
  "next_cursor": "eyJzZXEiOjEyfQ" }
```

- `next_cursor` 不透明 base64url；原样传回 `--after`，不得解析。
- 只返回 `seq` 大于游标的事件；无匹配返回空数组与相同/新的游标。
- 事件类型与字段可按版本增加；未知类型容忍，未知字段忽略。
- 无活宿主时 CLI 从任务事件日志读取；游标仍按 `seq` 过滤。

## 7. `sessions`

```json
{
  "as_of_seq": 42,
  "root": {
    "session_id": "...",
    "state": "available",
    "as_of_seq": 42,
    "visible_text": [{ "seq": 1, "text": "..." }],
    "user_messages": [{ "id": "...", "seq": 2, "text": "..." }],
    "activities": [{ "seq": 3, "name": "bash", "status": "ok", "target": "unknown", "declared_intent": "unknown" }],
    "questions": [{ "id": "...", "question": "..." }],
    "deliveries": [{ "seq": 5, "kind": "turn_completed" }],
    "gaps": [{ "from": 4, "to": 4 }],
    "archive_segments": 2
  },
  "members": []
}
```

- `state`：`available | unavailable`；不可读时数组为空，不伪造在线状态。
- `user_messages` 只含 `source.kind=user` 的原生用户消息。
- `gaps`、`archive_segments` 在离线归档投影时出现；活宿主可省略。
- 投影只读，不重放对话、不写会话。

## 8. 问题与答复

`questions` 返回 `{ "questions": [...] }`，每条：

```json
{ "id": "question-...", "memberId": "...", "externalId": "q1", "question": "Which?",
  "header": "Option", "options": [{ "label": "alpha" }], "multiSelect": false,
  "status": "pending", "askedAt": "...", "source": "member",
  "answer": { "selected": ["alpha"], "custom": null } }
```

- 只有 `status=pending` 的问题可答复；`answer` 校验选项、记录时间。
- `orbit answer` 返回 `{ "question": { ... } }`；需要活宿主，否则失败。
- 成员通过 `orbit_ask` 工具提问；Root/用户答复。`accepted` 不表示模型已采用答案。
- `prompt` 返回 `accepted` 与 `messageId`；不写任务、不直接调用模型。
- `abort` 的 `scope=session` 只表示会话已中止，不等于任务停止或业务完成。
- 停止时 pending 问题取消，等待中的调用失败；迟到答复不得绕过停止围栏。

## 9. `stop`

`orbit stop` 返回请求回执：

```json
{ "ok": true, "taskId": "...", "status": "running", "fence": "armed",
  "stop": "user", "stopConfirmation": { "confirmed": false, "missing": ["root_idle"] } }
```

- `fence=armed` 只表示围栏已落盘；`status` 仍可能是 `running`。
- 已确认停止只由 `stopConfirmation.confirmed=true` 表示；`missing` 列出未满足证据。
- 有界时间内无法确认时任务进入 `stop_unconfirmed`，集成方必须展示并阻止误判完成。
- 停止后不接受迟到检查结果或新派发。

## 10. `export`

返回 `{ "taskId": "...", "bytes": 1234, "output": "/abs/file.json", "files": 14 }`；归档是自包含证据包，包含任务记录、检查、快照与会话归档。导出不改变任务。

## 11. 错误

失败时非零退出；JSON 命令的错误对象：

```json
{ "error": { "code": "task_not_found|invalid_state|stop_fenced|invalid_input|unauthorized|internal",
             "message": "..." } }
```

调用方不得把错误 JSON 当成成功结果；重试语义由调用方决定，Orbit 不自动重试。

## 12. 与 1.x 的差异

- 删除 `provider=omp`、`session_file`、字节偏移、OMP 线程/会话文件解析。
- 删除 `conversation`/`messages` 命令；并入 `sessions`。
- `events` 改为 `{taskId, events, next_cursor}`，游标不透明。
- 新增 `launch`、`sessions`、`questions`、`answer`。
- `status` 改为本文件第 5 节的 camelCase 字段，不再提供 1.x 冻结字段。

## 13. 变更记录

- 2.0.0（2026-10-20）：DSH 单包 `@zeen/orbit` 的集成合同；删除 1.x 兼容，新增 launch/sessions/questions/answer/events 游标。

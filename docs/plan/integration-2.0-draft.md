# Orbit 集成合同 2.0 草案（DSH）

状态：**草案，未生效**。需用户确认后才能替换 `contracts/integration.md`/`integration.json` 并修改 Loom。1.x 合同在 2.0 生效前仍然有效。

## 1. 版本与兼容

- 合同版本 `2.0.0`，主版本变更，不保留 1.x 兼容字段与读取路径。
- 集成方只依赖本文件与 `integration.json`；未声明字段忽略。
- 破坏性规则沿用 ADR-010：升主版本、变更记录、能力协商。

## 2. 能力（`orbit capabilities --json`）

```json
{
  "integration_contract": { "name": "orbit-integration", "version": "2.0.0", "major": 2 },
  "orbit": { "version": "<software version>" },
  "capabilities": {
    "launch": { "since": "2.0.0", "stdin": "keep-open", "process_owner": "caller" },
    "status": { "since": "2.0.0" },
    "events": { "since": "2.0.0", "cursor": "opaque", "types": ["task", "work-unit", "member", "check", "stop", "jev"] },
    "sessions": { "since": "2.0.0", "visible_text": true, "user_messages": true, "activities": true, "questions": true, "deliveries": true },
    "questions": { "since": "2.0.0", "answer_format": "native-ask" },
    "stop": { "since": "2.0.0", "receipt": "evidence" },
    "export": { "since": "2.0.0", "self_contained": true },
    "models": { "since": "2.0.0", "strict_authorization": true }
  }
}
```

## 3. 命令

| 命令 | 返回 | 说明 |
| --- | --- | --- |
| `orbit launch --json` | `launch_spec` | 只返回启动参数，不启动进程 |
| `orbit status [TASK] --json` | `status` | 任务事实与投影 |
| `orbit events [TASK] --after CURSOR --json` | `events_page` | 增量事件 |
| `orbit sessions [TASK] --json` | `sessions` | Root/成员会话投影 |
| `orbit questions [TASK] --json` | `questions` | 待答问题 |
| `orbit answer [TASK] --question ID --answers JSON --json` | `answer_receipt` | 递送答复 |
| `orbit stop [TASK] --json` | `stop_receipt` | 请求停止，确认另查 |
| `orbit export [TASK] --output FILE --json` | `export_receipt` | 自包含证据包 |
| `orbit models [TASK] --json` | `model_authorization` | 冻结名单与实际路由 |

## 4. `launch_spec`

```json
{
  "kind": "dsh",
  "contract": "2.0.0",
  "profile": "orbit-node",
  "cwd": "/abs/project",
  "argv": ["--profile", "orbit-node", "--patch", "/abs/profile/cordis.patch.yml"],
  "env": { "DSH_HOME": "/abs/isolated-home" },
  "stdin": "keep-open",
  "control_socket": "/abs/project/.orbit/orbit.sock",
  "ready": { "kind": "socket", "timeout_ms": 30000 }
}
```

- 不包含 Orbit 可执行文件、socket 路径参数以外的启动逻辑。
- 进程所有权属于调用方（Loom）；stdin EOF 表示有界关闭。
- `ready.kind=socket`：Loom 拉起进程后调用 `orbit start`，再轮询 `control_socket` 出现；socket 在任务接纳后由宿主创建。

## 5. `status`

```json
{
  "task_id": "task-...",
  "status": "running|paused|needs_user|complete|failed|stop_unconfirmed",
  "project_root": "/abs",
  "workspace": { "artifact_root": "/abs", "real_path": "/abs", "bound_at": "..." },
  "input": { "version": 2, "digest": "sha256" },
  "root": { "session_id": "...", "provider": "deepseek-account", "model": "deepseek-flash" },
  "members": [{ "id": "...", "status": "registered|completed|...", "work_unit_id": "wu-...", "model": {...} }],
  "work_units": [{ "id": "wu-...", "status": "...", "goal": "..." }],
  "checks": { "in_flight": null, "latest": { "number": 2, "kind": "artifact", "verdict": "complete", "ready": true } },
  "completion": { "check_number": 2, "artifact_digest": "..." },
  "stop": { "reason": "user|complete", "confirmed": true, "evidence": {...}, "missing": [] }
}
```

- `status` 只读；不触发检查、不调用模型。
- 未经检查的字段保持 `null`/缺省，不伪造。

## 6. `events_page`

```json
{ "events": [{ "seq": 12, "at": "...", "type": "check/completed", "data": {...} }],
  "next_cursor": "eyJzZXEiOjEyfQ==",
  "has_more": false,
  "gap": { "from": 5, "to": 7 } }
```

- 游标不透明；越界或不可读时返回 `gap` 与最近可读段，不重放、不猜测。
- 事件类型白名单与裁剪字段在 `integration.json` 冻结。

## 7. `sessions`

```json
{
  "root": { "session_id": "...", "state": "running|idle|stopped",
            "visible_text": [{"seq": 1, "text": "..."}],
            "user_messages": [{"id": "...", "seq": 2, "text": "..."}],
            "activities": [{"seq": 3, "name": "bash", "status": "ok", "target": "..."}],
            "questions": [{"id": "...", "seq": 4, "question": "..."}],
            "deliveries": [{"seq": 5, "kind": "final|notice"}] },
  "members": [ ... same shape ... ],
  "as_of_seq": 42
}
```

- 来自 DSH session projections/`readSurface`；不重扫原始事件。
- 宿主已退出时返回最后归档与 gap，不伪造在线状态。

## 8. `stop_receipt`

```json
{ "task_id": "...", "requested": true, "status": "running|paused|complete|stop_unconfirmed",
  "confirmed": false, "evidence": { "fence_persisted": true, "root_idle": false, "members_stopped": false, "checks_settled": true },
  "missing": ["root_idle", "members_stopped"] }
```

- `requested` 只表示围栏已落盘；`confirmed` 只看证据齐全。
- 确认后可轮询 status 或事件；不得把 HTTP/CLI 成功当停止确认。

## 9. `questions` / `answer`

```json
{ "questions": [{ "id": "...", "member_id": "...", "question": "...", "options": null, "asked_at": "..." }] }
```
```json
{ "accepted": true, "question_id": "...", "message_id": "..." }
```

- 问题 id 稳定；`accepted` 不表示模型已采用答案。
- 答案格式与原生 ask 一致；不代填、不重发。

## 10. `model_authorization`

```json
{ "allowed_models": ["deepseek-account/deepseek-flash"], "root": {...}, "members": [...], "checker": {...}, "violations": [] }
```

- 严格任务冻结名单；漂移记 `model/violation`，不静默换模。

## 11. 错误

```json
{ "error": { "code": "task_not_found|invalid_state|stop_unconfirmed|unauthorized|internal",
             "message": "...", "next_action": "..." } }
```

## 12. 移除的 1.x 概念

- `session_file`、字节偏移、`provider="omp"`、OMP 线程号、OMP 专用会话文件解析。
- 1.x 的 `conversation`/`messages` 命令并入 `sessions`。

## 13. 待用户确认

1. `sessions` 的字段粒度是否够 Loom 使用（可见文本、用户消息、活动、问题、送达）。
2. `launch_spec` 是否由 Loom 直接 spawn `dsh`，Orbit 只返回参数。
3. 事件游标是否接受不透明 base64。
4. 2.0 是否完全删除 1.x 兼容路径（ADR-015 已决定一次改到 2.0）。

# Codex 审批与 MCP 调用验收（2026-09-18）

本文记录修复 “`approval_policy=never` 的 Codex 会话无法调用 Orbit MCP” 的实际证据、根因与边界。源码基线为提交 `fa2f76d`；本机最终安装 0.6.4（`content_digest b9c129c0…`、`installed_at 2026-09-18T06:57:02Z`），Codex `0.155.0`。

## 根因

1. **审批覆盖写错了键**：`lib/orbit/session_entry.rb` 原先把 per-tool 覆盖写成 `mcp_servers.orbit.tools.orbit.approval_mode="approve"`，而 `scripts/orbit-mcp.cjs` 注册的工具名是 `task`。Codex（`codex-rs/core/src/mcp_tool_call.rs` 的 `custom_mcp_tool_approval_mode`）按真实工具名查表，未命中时回退默认 `auto`；`auto` 对没有只读标注的自定义工具判为需要审批（`requires_mcp_tool_approval_for_mode`），而 `request_mcp_tool_user_approval` 在 `approval_policy=never` 时直接拒绝，返回 “MCP tool call requires approval, but approval policy is never”。`approve` 模式在该表中表示无需审批（预批准），正是入口最初想要的语义。
2. **会话身份键未适配**：Codex 0.155 在 MCP 调用 `_meta` 中使用 `threadId`（`MCP_TOOL_THREAD_ID_META_KEY`），桥接只读取 `codex/thread-id`／`codex/threadId`，导致审批修好后 `start` 仍报 “Provide your current CODEX_THREAD_ID as thread_id”。

## 修改

- `lib/orbit/session_entry.rb`：抽出 `codex_configuration(mcp:, socket:)`，按真实工具名设置 `tools={task={approval_mode="approve"}}`。
- `scripts/orbit-mcp.cjs`：调用身份同时接受 `metadata.threadId` 与旧的前缀键。
- `tests/cli_test.rb`：新增用例，断言启动配置的覆盖键与该脚本注册的工具名一致（防止再次写错键），且不包含旧的 `tools={orbit=`。
- `tests/mcp_test.cjs`：`check` 调用改用 `_meta: { threadId: … }`，同时保留 `status`/`stop` 的旧前缀键，覆盖两种身份来源。
- README 与 ADR-007 补充审批范围说明。

## 验证

- 非交互复现（真实模型、真实 MCP）：旧配置 `tools={orbit=…}` + `approval_policy=never` 的 `codex exec` 会话返回完全相同的拒绝消息；改用 `tools={task=…}` 后同一会话成功执行工具并返回 `orbit doctor` 的真实 JSON。
- 交互会话（`orbit codex -a never`，Herdr pane，新会话加载安装后的 0.6.4）：`orbit.task` 依次执行
  - `context` → `ready: true`；
  - `start`（`project` 指定会话目录）→ 任务 `8019cb9f-b0ad-4a23-a2b3-e393d07b44ca`，`status: starting`；
  - `status` → `running`；
  - `stop` → 命令入队后运行进程确认 Root 停止，任务记录 `paused`、`stop_confirmation.confirmed=true`（turn 已中断、无剩余后台终端）。全程没有审批提示。
- 普通审批策略（默认 `on-request`）的新会话同样直接调用 `context` 成功（`ready: true`、原生接口读回会话），未出现审批提示；配置只覆盖 `mcp_servers.orbit.tools.task` 一项，其余工具、shell 沙箱、成员边界与全局配置未改。
- `npm test` 19 项通过（含上述两条新增/扩展用例）。

## 未覆盖与边界

- `orbit codex resume --last --dangerously-bypass-approvals-and-sandbox` 的权限覆盖错误未修改，也未静默丢弃用户参数；本任务不涉及。
- 从 Codex 受限 shell 直接运行 `orbit doctor` 访问控制 socket 的 EPERM 是沙箱边界，未放宽；会话内仍通过原生 MCP 验证。
- 审批行为变化仅限 `orbit codex` 启动的会话中的 `orbit.task`：此前它需要审批（在 `never` 下被拒绝），现在按文档语义预批准；其他调用方与其他工具不受影响。
- 验收时源码修正未提交、未推送、未发布；后续提交状态以 Git 为准。

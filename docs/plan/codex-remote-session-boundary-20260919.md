# Codex 远端会话入口的权限边界问题

状态：2026-09-19 用户认可“权限只有一个权威、不能逐条修命令”的根治原则；同日隔离实测否定了“发现线程后调用一次 `thread/settings/update`”，并验证了在 TUI 与 app-server 之间原子改写线程生命周期请求的可行性。双 socket + 生命周期代理已实现，并完成隔离真实 TUI 验收；`-p/--profile` 首版明确拒绝。

## 用户实际遇到的问题

用户在 `zeen` 项目运行 `orbit codex --dangerously-bypass-approvals-and-sandbox`，进入显示 `YOLO mode` 的 Codex 界面，再使用界面内的 `/resume` 打开旧会话，得到：

```text
Permission overrides are not supported when resuming a remote task.
```

这不是在终端直接运行 `orbit codex resume ...`。上一版修复只识别启动 Orbit 时的 `resume` 子命令，因而没有覆盖这条复现路径。用户进一步指出：即便单独修好 `/resume`，其他 Codex 原生命令也可能经过同一边界，不能据此保证日常使用可靠。

## 当前入口实际做了什么

`orbit codex` 为本次启动创建一个 Codex app-server，再启动带 `--remote unix://...` 的 Codex TUI 连接它。app-server 是 Codex 的会话与执行后端；Orbit 借其原生接口观察、投递和停止任务。用户在 TUI 中输入的内容不是先交给 Orbit 逐条转发。[Codex 官方 app-server 文档](https://developers.openai.com/codex/app-server)描述了这一客户端与服务端关系。

当前代码在新会话入口将权限配置传给 app-server，同时仍把原始权限参数传给远端 TUI（`lib/orbit/session_entry.rb` 的 `launch`）。只有当**启动命令**包含 `resume` 时，Orbit 才移除给 TUI 的权限覆盖参数，并在启动前处理目标会话。进入 TUI 后执行的 `/resume` 不会重新经过这段 Orbit 命令行判断。2026-09-19 本机运行中的 `zeen` 进程参数也同时显示：app-server 带 `sandbox_mode="danger-full-access"`、`approval_policy="never"`，TUI 带 `--dangerously-bypass-approvals-and-sandbox`。

因此，本次错误与“远端 TUI 在恢复旧会话时仍携带权限覆盖参数”一致；但尚未截取该次 `/resume` 的协议请求，不能把内部调用细节写成已证实事实。隔离目录中使用同一启动参数创建新会话并完成首轮简短对话，没有遇到此错误；它只证明新会话路径可用，不能证明界面内恢复路径可用。

## 比单个报错更根本的缺口

Orbit 目前同时涉及四处状态：启动命令的权限参数、app-server 启动配置、TUI 自己的运行参数，以及旧会话保存的权限。它们分别在不同时间生效。Orbit 只在启动前解析一次命令行，却允许用户之后继续使用 Codex 原生界面改变会话。现有实现没有一条统一规则说明：会话在 TUI 内切换后，谁拥有最终权限决定权，Orbit 又如何知道并保持实际生效值。

这使得“启动时显示 YOLO mode”“app-server 以 full access 启动”和“恢复后的旧会话实际以 full access 执行”成为三件不同的事。上一版针对 `orbit codex resume` 的处理不能推出 `/resume` 或其他原生会话操作也正确。当前不声称其他命令已经失效，也不声称它们安全；尚无相应验证。

需要先明确的产品边界是：Orbit 在接入 Codex 后，哪些会话与权限行为仍交给 Codex 原生控制；Orbit 对用户选择的权限究竟承诺到启动、当前会话，还是后续切换到的旧会话。只有这个边界确定，才能判断 `--remote` 入口是否适合承载所承诺的日常 Codex 体验，并设计有代表性的验证。现在不继续为单个命令添加特殊分支。

## 候选方案与验证结论（2026-09-19）

Cursor 提出的候选方案是：远端 TUI 不再携带权限参数；入口发现该 app-server 上激活的线程后，对每个线程调用一次 `thread/settings/update`，以 app-server 的线程设置作为唯一权威。单一权威的产品原则成立，但该候选机制没有通过隔离验证。

**Codex 0.155 已核实的事实**（源码：`codex-rs/tui/src/app_server_session.rs`、`tui/src/app/config_persistence.rs`、`tui/src/app/thread_routing.rs`、`tui/src/chatwidget/settings.rs`、`app-server/src/request_processors/thread_processor.rs`、`persisted_resume_settings.rs`、`app-server-protocol/src/protocol/v2/thread.rs`）：

- 远端 TUI 带 CLI 权限标志，或 `-p` 选中的 profile 含审批／沙箱字段时，恢复远端线程会被拒绝；远端 `thread/resume` 本身不发送权限，由 server 恢复保存值。隔离实测中，用户通过 `/permissions` 在运行期改动权限后再使用界面内 `/resume` 没有被拒绝，因此不能把运行期改动列为同一已证实根因。
- 远端 TUI 的 `thread/start` 会发送自身配置的审批策略和沙箱，盖过 app-server 的 `-c` 配置。
- server 恢复时只回填审批策略、审批路由和命名 permission profile，不回填 legacy 沙箱。
- `thread/settings/update` 可对任意已加载线程设置 `approvalPolicy`／`sandboxPolicy`／`permissions`，写入会话记录并广播 `thread/settings/updated`；TUI 据此更新配置与状态栏，后续 `turn/start` 发送更新后的审批策略，沙箱跟随 server。

### 隔离验证

验证使用本机 Codex `0.155.0`、独立 `CODEX_HOME`、独立 Unix socket 与临时项目，不读取或修改用户真实会话。app-server 默认设为 `approval_policy=never` 与 `sandbox_mode=danger-full-access`；远端 TUI 不带权限参数。

| 验证项 | 结果 | 结论 |
| --- | --- | --- |
| 第二控制连接等待 TUI 新线程通知 | 没有收到 `thread/started`；约 30ms 轮询 `thread/loaded/list` 才发现线程 | 通知不能作为当前实现依据，轮询是事后发现 |
| 发现新线程后立即调用 `thread/settings/update`，同时让 TUI 带初始提示启动 | update 已成功返回，首轮实际 `turn_context` 仍为 `approval_policy=on-request`、`sandbox_policy=danger-full-access` | TUI 的首轮 `turn/start` 覆盖了先前更新；候选方案不能保证第一轮权限 |
| 首轮结束后再次更新，再发送第二轮 | 第二轮 `turn_context` 为 `approval_policy=never`、`sandbox_policy=danger-full-access` | 该接口可控制后续轮次，但不能消除创建与首轮竞态 |
| app-server 先以目标权限创建空线程，再让 TUI `resume <uuid>` | TUI 失败：`no rollout found for thread id ...` | “先建空线程再恢复”的候选堵法不可用 |
| TUI 使用 `-p restricted`，profile 文件含 `workspace-write` 与 `never`，再恢复远端线程 | 复现 `Permission overrides are not supported when resuming a remote task` | 必须识别 profile 内的权限；只剥离显式 `-s`／`-a`／danger 标志不完整 |
| 在无权限启动参数的远端 TUI 中用 `/permissions` 改为 Ask for approval，再执行界面内 `/resume` | picker 正常打开并成功回到同一线程，没有权限覆盖错误 | 当前证据不支持“运行期手改权限必然导致远端 resume 被拒绝” |

首轮记录中先出现服务端 `thread_settings_applied(never)`，随后首个 `turn_context` 仍记录 `on-request`；第二次更新后的下一轮才记录 `never`。这排除了“只是界面显示延迟”的解释。

### 当前裁决

1. 不实现“轮询发现线程后更新一次”的方案，也不据此删除现有恢复保护逻辑。
2. 保留产品原则：同一次 `orbit codex` 启动选择的权限必须与用户看到和实际执行的一致；不能靠为 `/resume`、`--last`、fork 等命令逐条增加例外维持。
3. 下一版方案必须在 `thread/start`／`thread/resume`／`thread/fork` 的生命周期边界内原子确定权限，并在首个 `turn/start` 前完成。事后轮询不满足这个条件。
4. 生命周期协议代理已经通过隔离原型：不等待响应、不调用 `thread/settings/update`，直接在请求进入 app-server 前改写 `thread/start`、`thread/resume`、`thread/fork` 自带的 `approvalPolicy` 与 `sandbox` 字段。server 接受这三类原生参数，TUI 状态栏和首轮记录一致。
5. 生产实现采用双 socket：app-server 的 `control.sock` 继续直接提供给 Orbit 原生控制；仅 TUI 连接入口代理 `tui.sock`。这样代理不会改写检查者、成员或其他 Orbit 控制连接。
6. 用户可见的新建／派生只处理 `threadSource: "user"` 且非 ephemeral 的请求；TUI 专用连接上的 resume 处理为用户切换会话。`threadSource: "system"`、`ephemeral: true` 的标题生成等内部线程保持原权限。
7. `-p/--profile` 若选中的 profile 本身含权限字段，Codex TUI 会在发出 resume/fork 请求前拒绝。该输入不能靠协议代理修复；生产实现不得静默丢掉 profile。首版应在启动前给出明确不支持说明，后续只有出现真实 profile 使用需求时才增加配置解析或等待 Codex 原生支持。

### 生命周期代理原型结果

原型仍使用 Codex `0.155.0`、独立 `CODEX_HOME`、独立 app-server 与临时项目。TUI 自己加载的默认值为 `on-request + workspace-write`，代理目标为 `never + danger-full-access`。

| 用户路径 | 实际协议 | 结果 |
| --- | --- | --- |
| 带初始提示的新会话 | `thread/start` 后立即 `turn/start` | 请求进入 server 前完成改写；状态栏显示 YOLO，首轮 `turn_context` 为 `never + danger-full-access` |
| 终端 `resume UUID` | `thread/resume` | 不向 TUI 传权限标志也能恢复；代理原子施加目标权限，恢复后的下一轮为 full access |
| 界面内 `/resume` picker | `thread/resume` | 成功切换另一线程，无 permission override 错误，状态栏显示 YOLO |
| 界面内 `/fork` | `thread/fork` | 成功派生并切换，新线程首轮为 `never + danger-full-access` |
| 界面内 `/new` | `thread/start` | 复用相同规则，新线程状态栏显示 YOLO |
| 标题生成等内部任务 | `thread/start`，`threadSource: "system"`，`ephemeral: true` | 过滤后没有改写，保持 `never + read-only` |

原型同时证明：`thread/start` 的用户请求带 `threadSource: "user"`、`ephemeral: false`；普通 `/fork` 也带 `threadSource: "user"`。这两个协议字段足以隔离本次需要控制的用户线程。`thread/resume` 不带 `threadSource`，因此只允许在 TUI 专用代理 socket 上统一改写。

### 最小生产改动

1. 新增一个只服务 TUI 的透明 Unix WebSocket 代理；除三类用户线程生命周期请求外，所有 JSON-RPC 消息和通知原样双向转发。
2. `SessionEntry` 把用户的直接权限参数解析为一次启动策略，并从 TUI argv 移除；app-server 可继续接收同一策略作为默认兜底。
3. app-server 监听 `control.sock`，Orbit MCP、停止与任务连接继续使用它；TUI 只连接 `tui.sock`。
4. 代理与 app-server 都归入口进程持有。启动顺序为 app-server ready → proxy ready → TUI；退出顺序为 TUI 结束 → 通过 `control.sock` 完成现有停止确认 → 关闭代理与 app-server。
5. 删除现有只覆盖启动命令 resume 的目标预测、`--last` 替换、picker 拒绝和保存沙箱推断；`--last` 与 picker 交回 Codex 原生实现。
6. 只保留少量高价值测试：三类请求改写、内部线程不改写、权限参数不进入 TUI、双进程失败与退出收尾；再跑一条真实带初始提示和一条界面内切换验证。

不使用轮询和实验性的 `thread/settings/update`，因此没有首轮时间窗口，也不需要维护每线程“是否已经更新”的内存状态。

## 落地与验证（2026-09-19）

实现：

- 新增 `scripts/codex-tui-proxy.cjs`：透明 Unix WebSocket 代理。只改写 `thread/start`、`thread/fork`（`threadSource=user` 且非 ephemeral）与 `thread/resume` 请求中的 approvalPolicy／sandbox（策略含 approvalsReviewer 时一并改写）；其他方法与通知、双向二进制帧原样转发。
- `lib/orbit/session_entry.rb`：启动命令的权限参数解析成一份策略并从 TUI argv 移除；启动顺序为 app-server（`control.sock`）ready → 代理（`tui.sock`）ready → TUI（`--remote unix://…/tui.sock`）；`ORBIT_CODEX_SOCKET` 仍指 `control.sock`。退出时先经 `control.sock` 完成停止确认，再终止代理与应用 server 并清理目录。`-p/--profile` 在启动前明确拒绝。
- 删除按目标 UUID 预测恢复、项目内替换 `--last`、picker 拒绝与保存沙箱推断；`--last`／picker 交回 Codex 原生并经代理统一施加策略。

隔离真实验证（独立 `CODEX_HOME`、临时项目、pty 驱动，未使用 Herdr，也未触碰用户现有会话）：

| 项目 | 结果 |
| --- | --- |
| 首轮 `turn_context` | `approval_policy=never`、`sandbox_policy=danger-full-access` |
| 界面内 `/new` 新线程首轮 | 同上；loaded 列表新增独立线程 |
| 界面内 `/fork` 新线程首轮 | 同上；loaded 列表再新增独立线程 |
| 界面内 `/resume` 恢复后下一轮 | 同上；全程无 “Permission overrides are not supported” |
| 控制链 | TUI 运行期间从 `control.sock` 读回 loaded 线程正常 |
| TUI argv | `--remote unix://…/tui.sock`，无任何权限覆盖参数 |
| 退出收尾 | launcher 返回 0；无遗留 host 目录或代理进程 |

仍存在的边界：`-p/--profile` 明确不支持；`sandbox_workspace_write` 等其他权限形态不纳入改写，可能仍被 Codex 原生远端恢复拒绝；系统／ephemeral 线程不改写由代理单测覆盖。

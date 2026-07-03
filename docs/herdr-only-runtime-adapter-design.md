# Herdr-only runtime adapter design

本文记录 Orbit 收窄 runtime adapter 支持面的设计决定：官方自动 runtime adapter 只支持 Herdr。其它终端工具仍然可以手动运行 Orbit protocol，但 Orbit 不再承诺为它们提供自动 wake/create、direct dispatch 或 notice delivery。

## Decision

Orbit 分成两层：

1. Orbit protocol：`.orbit/` 里的 task、evidence、state、handoff、notice 和 gate 语义。
2. Runtime adapter：自动创建/唤醒承载环境、投递消息、读取 pane 状态的外部工具集成。

官方 runtime adapter 只支持 Herdr。

这意味着：

- `orbit start` 的自动外部 pane create/wake 只面向 Herdr。
- `orbit dispatch` 的 direct pane delivery 只面向 Herdr。
- `orbit notice` 的 Herdr delivery 只面向 Herdr，且是 best-effort。
- `tools detect` / `tools doctor` 只把 Herdr 视为 runtime adapter。
- `generic` handoff/payload 继续保留为手动 artifact 格式，但不再叫 transport，也不用于 runtime dispatch/handoff routing。
- tmux、zellij、wezterm、CI、远端 shell 和普通终端可以继续手动运行 Orbit protocol，但不提供官方 adapter，也不承诺未来补齐。

这是 breaking change，不设计兼容期。实现 PR 必须一次性更新 CLI、help、README、runtime guide、tests 和 starter templates；不要保留“旧模式还能用但不推荐”的半状态。

当前实现已按本文核心方向切到 Herdr-only：旧 `--transport` / `--allow-create` 路径只保留为迁移错误提示，starter schema 写入 `binding.adapter: herdr`，direct dispatch 需要 live-confirmed Herdr binding，handoff 使用 delivery/manual artifact 语义。本文后面的清单保留目标契约和后续增强项。

## Why

之前的多 adapter 方向会把最复杂的部分放在兼容层：

- 每个工具的 pane/session/job 模型不同。
- agent 检测、pane 输出读取、wake 安全判断、消息投递语义不同。
- start 的 liveness 判断容易退回到不可靠的静态 binding/cache。
- 用户以为“支持 tmux/zellij/wezterm”就等于自动 start/dispatch 都可用，实际体验会碎。

收窄到 Herdr 后，Orbit 可以把体验做深：

- start 输出 Herdr pane、进程、agent detection、wake 安全判断，而不是泛 transport 字段。
- force replacement 可以围绕 Herdr pane 做更明确的风险提示和诊断。
- lead/coder/reviewer/tester pane 可以有稳定布局和标题。
- notice 可以保留 protocol inbox，同时 best-effort 投递到 Herdr owner pane。
- doctor 可以检查真正影响体验的 Herdr integration、session、pane binding 和 agent readiness。

## Herdr docs alignment

This design follows the current Herdr model:

- `herdr` starts or attaches to a persistent background session; users do not manage sockets.
- A workspace is the project-level container. It owns tabs and panes, and sidebar state rolls up from agents inside it.
- A tab is a layout inside a workspace; it should separate views such as agents, logs, server, or review.
- A pane is a real terminal that persists across detach.
- An agent is a process Herdr recognizes inside a pane.
- Herdr agent states are `blocked`, `working`, `done`, `idle`, and `unknown`.
- Herdr can detect common coding agents automatically; integrations improve either lifecycle authority, native session identity, or both.
- Some integrations are not lifecycle authorities. For example, Claude Code and Codex session identity integrations do not author the full state lifecycle; Herdr still uses screen manifest detection for state.
- Herdr `done` means "finished and not yet seen" in the UI, not Orbit task completion.

Local CLI help in the current worktree confirms the relevant surfaces: `herdr` launches or attaches to a persistent session, supports `--remote`, exposes `workspace`, `tab`, `pane`, `agent`, `wait`, and `integration` subcommands, supports `herdr agent start ... --workspace/--tab/--split`, exposes pane inspection/control through `herdr pane get|layout|process-info|read|run`, and exposes `herdr wait agent-status ... --status idle|working|blocked|done|unknown`.

Orbit should therefore use Herdr for runtime observation and delivery, but keep Orbit protocol as the authority for role identity, evidence, gate, task completion, and handoff.

## Non-goals

- 不实现 tmux/zellij/wezterm/CI runtime adapter。
- 不从 pane id 形状推断 transport。
- 不把缺少 Herdr 当作 Orbit protocol 不可用。
- 不让 Herdr delivery 成为 gate 的权威证据。
- 不自动 kill 旧 agent；`start --force` 只替换 Orbit 对当前 binding 的信任。

## User-facing behavior

### With Herdr

Herdr 是推荐体验。用户不应该需要理解 transport registry、pane id 生命周期或 adapter fallback；常见路径应是：

```bash
herdr
orbit start lead
orbit start coder
orbit start reviewer
orbit start tester
```

`orbit start INSTANCE` 默认使用 Herdr adapter。不保留 `--transport herdr` 作为日常参数，也不保留 `--transport local` 作为同级模式。user-managed instance 无 binding 时默认创建；已有 binding 但 liveness 不可信时要求用户显式 `--force`。

- 查找当前项目 Herdr session。
- 查找或创建对应 role/instance pane。
- 写入稳定 binding。
- 复用明确检测到的 live agent。
- 缺失 binding 或安全可 wake 的 Herdr shell pane，直接创建/唤醒。
- 只有在替换/接管有冲突的现有 binding 时才要求 `--force`。

推荐交互输出应直接回答用户关心的问题：

```text
Orbit start: coder
- Herdr session: orbit
- pane: w3:p4
- current process: zsh
- detected agent: none
- action: wake
- why: pane is an idle shell and no Herdr agent is detected
```

成功启动时应输出下一步：

```text
Started Orbit instance:
- instance: coder
- role: coder
- pane: w3:p4
- ready: pass
- next: orbit dispatch --task .orbit/tasks/current-task.yaml --to coder-main --json
```

### Without Herdr

没有 Herdr 时，用户仍然可以手动运行 Orbit protocol。这里的 `local`/当前 shell 路径不是 runtime adapter，只是“在当前进程里运行配置的 agent 命令”：

```bash
cd /path/to/project
ORBIT_INSTANCE=coder-main ORBIT_ROLE=coder codex
orbit whoami --json
orbit rules resolve --json
orbit evidence ...
orbit wait-gate ...
orbit audit ...
```

但 Orbit 不会承诺：

- 自动创建 tmux/zellij/wezterm pane。
- 自动把命令打进任意终端。
- 自动 direct dispatch 到非 Herdr pane。
- 自动 notice delivery 到非 Herdr 环境。

错误提示应避免说“use another adapter”。建议使用：

```text
Herdr is not available.
- Automatic start/wake/dispatch requires Herdr.
- Manual protocol usage still works.
- Next: open a terminal, set ORBIT_INSTANCE/ORBIT_ROLE, and run the configured command.
```

如果需要手动运行 agent，使用明确的 manual/current-shell 命令或文档步骤，不通过 `--transport local` 表达。`local` 不再是 `start` 的 transport mode。

## Authority model

Herdr-only 后，role、liveness、binding 都应有单一权威来源。

### Role identity

身份解析以 instance 为入口：

1. 当前进程的 `ORBIT_INSTANCE` 指向 instance name。
2. `.orbit/instances.yaml` 中的 `instances.<name>.role_ref` 指向 role ref。
3. `.orbit/roles.yaml` 中的 `roles.<role_ref>.role` 给出 resolved role。
4. task 的 `execution_contract` / gate roles 决定该 role 是否允许执行当前动作。

`ORBIT_ROLE` 可以作为启动时写入的冗余诊断字段，但不能覆盖配置解析结果。若 `ORBIT_ROLE` 与 config resolved role 不一致，`whoami` 必须报 conflict。

`whoami --json` 是当前 agent 自身身份的权威输出。其它命令不应自己重新猜 role；它们应复用同一套 identity resolver。

### Peer identity

判断“别人是什么 role”不靠 pane 标题、agent 名字或 prompt 文案，而靠 instance config：

1. `--to reviewer` 先解析为 instance。
2. instance 的 `role_ref` 决定目标 role。
3. Herdr live probe 只证明这个 instance 当前绑定的 pane 是否有活 agent，不定义 role。
4. dispatch/notice/start 输出必须同时给出 `target_instance`、`target_resolved_role`、`pane`、`tab`、`workspace`。

如果用户传入的目标 role 和 instance role 不一致，fail closed，不要自动找“看起来像 reviewer 的 pane”。

### Liveness

“role 是否正常活着”只由 Herdr live probe 判断：

- `herdr agent list` 中存在匹配 canonical pane 的 detected agent。
- detected agent 的 client 与 instance expected command / client mapping 一致，或能被明确归一化。
- pane cwd / project root 与当前 checkout 匹配。
- pane binding 指向 canonical Herdr pane，并且 pane 仍存在。

静态 binding、历史 `transport.health`、last heartbeat、pane id 字符串格式都不能证明 alive。

建议 liveness 状态收敛为：

```text
alive
not_alive: no_binding | pane_missing | no_agent_detected | client_mismatch | cwd_mismatch | stale_binding | probe_failed
unknown: herdr_unavailable | permission_denied | malformed_state
```

日常命令只应自动使用 `alive`。`not_alive` 走 start/create/force 出口；`unknown` 走 doctor/repair 出口。

`not_alive` 不等于必须 `--force`：

- `no_binding`：`orbit start INSTANCE` 直接创建 Herdr pane。
- `pane_missing`：`orbit start INSTANCE` 直接创建新 Herdr pane，并把旧 binding 诊断写入 runtime。
- `no_agent_detected` 且 pane 是安全 idle shell：`orbit start INSTANCE` 直接 wake。
- `client_mismatch` / `cwd_mismatch` / live conflict：需要 `--force` 或人工修复。
- `probe_failed`：走 `orbit doctor herdr`，不要盲目创建。

### Availability

Herdr liveness and Herdr state are related but separate:

- liveness answers: "is there a live Herdr agent process for this instance?"
- availability answers: "is it appropriate to send work to that agent right now?"

Map Herdr states into Orbit availability:

```text
idle     -> available
done     -> available_needs_seen
working  -> busy
blocked  -> needs_user_or_owner_attention
unknown  -> unknown
```

Rules:

- `alive + idle` can receive dispatch.
- `alive + done` can receive dispatch only after Orbit records that the previous result was inspected, or with an explicit `--queue`/future queue mechanism.
- `alive + working` should not receive a new task by default; return `target_busy` and include the pane/status.
- `alive + blocked` should not receive a new task by default; return `target_blocked` and tell the owner to inspect the pane.
- `alive + unknown` should return `needs_attention`; do not infer readiness from unknown state.

Herdr `done` is never Orbit done. Orbit done still requires evidence, wait-gate, validate, audit, and handoff checks.

Blocked detection is intentionally conservative in Herdr screen-manifest mode. If Herdr reports `idle` for a known agent but Orbit is about to send an important or destructive request, Orbit should still read recent pane output first and include that probe in JSON diagnostics.

### Binding

binding 是 instance 到 Herdr canonical location 的映射：

```yaml
instances:
  coder:
    role_ref: coder
    command: codex
    binding:
      adapter: herdr
      workspace: w3
      tab: t1
      pane: p4
      canonical_pane: p4
```

最终 schema 不再使用泛 `transport.kind` 表达 Herdr binding。`instances.yaml` 只保留当前稳定 binding；replacement history、probe result、old pane 和风险诊断写入 `.orbit/runtime/instances/<instance>.json`。

所有写 binding 的路径必须：

- canonicalize pane。
- 写 workspace/tab/pane。
- 用 per-instance lock 保护读改写。
- atomic write。
- 不把 runtime replacement metadata 写进版本化配置。

### Status command

`orbit instances status --json` 应收敛为 Herdr-aware status，不再输出泛 `binding_status/recommended_action` 作为主要决策字段。

推荐输出：

```json
{
  "instance": "coder",
  "role": "coder",
  "binding": "bound",
  "liveness": "alive",
  "liveness_reason": "herdr_agent_detected",
  "herdr": {
    "workspace": "w3",
    "tab": "t1",
    "pane": "p4",
    "canonical_pane": "p4",
    "agent": "codex",
    "agent_status": "idle",
    "cwd_matches": true
  },
  "actions": ["reuse", "dispatch"]
}
```

Human output should answer:

- 这个 instance 是什么 role。
- 绑定在哪个 workspace/tab/pane。
- Herdr 是否能看到活 agent。
- 如果不能，下一步是 `orbit start INSTANCE`、`orbit start INSTANCE --force` 还是 `orbit doctor herdr`。

### Labels and identity

Herdr agent labels and pane titles are presentation. Orbit can use them to improve the sidebar, but never to resolve role identity.

Recommended labels:

- Herdr agent start label: `orbit:<project>:<instance>` when supported without making targets too noisy; otherwise `<instance>`.
- Pane title/display label: `<role> · <project>`.
- Optional Herdr metadata can show current task id or custom status, but semantic state remains Herdr's state and role identity remains Orbit config.

If a user manually renames an agent, Orbit must not treat that label as proof of instance or role. It can report `label_mismatch` as a diagnostic only.

## Better Herdr UX goals

Herdr-only 的收益不只是删 adapter，而是把体验做成项目工作区编排。

### Project workspace

Orbit 应该把 project root 作为 Herdr 工作区身份的一部分：

- workspace label 使用项目名和 git root hash，避免多个 checkout 同名冲突。
- Use Herdr workspaces first. Do not create named sessions per project unless the user explicitly configured a separate session namespace.
- Do not manage Herdr sockets directly; `herdr` attaches to the appropriate background server.
- pane binding 写入 canonical Herdr pane id，不写 alias。
- runtime diagnostic 写入 `.orbit/runtime/instances/<instance>.json`，包含 workspace、tab、pane、agent client、cwd、git root。
- `instances.yaml` 只保留稳定配置和当前 binding，不写 replacement history。

Remote workflows:

- If the user is already in SSH and runs `herdr` remotely, Orbit sees a normal Herdr runtime on that host.
- If the user uses `herdr --remote`, Orbit must still bind to the remote Herdr server's workspace/tab/pane handles, not local terminal assumptions.
- Binding diagnostics should include `host` or `runtime_host` so stale bindings across local/remote checkouts are distinguishable.

### Layout policy

Team mode 默认布局应可预测：

- lead 在主 pane。
- coder 默认优先放在 lead 旁边，但不能牺牲可读性。
- reviewer/tester 默认和 lead 同 workspace，只有在空间足够时才同 tab；否则新 tab。
- pane title/label 使用 `orbit:<project>:<instance>` 或 `orbit:<instance>`。
- 创建后不抢焦点，除非用户显式要求。
- `orbit start --all` 可以按 lead -> coder -> reviewer -> tester 顺序启动缺失实例。

Same-level view 的语义应该是“同一工作上下文”，不是“无条件切碎当前 tab”。自动创建 role pane 前必须做视图预算：

- preferred agent pane: 120 cols x 30 rows。
- minimum readable agent pane: 100 cols x 24 rows。
- 如果 right split 后任一 pane 会小于 minimum cols，不 split，改为同 workspace 新 tab。
- 如果 down split 后任一 pane 会小于 minimum rows，不 split，改为同 workspace 新 tab。
- 如果 Herdr 无法返回尺寸信息，默认新 tab，不创建可能窄到不可用的 pane。
- 一个 tab 中已经有 2 个以上 agent pane 时，默认新 tab，避免继续压窄。
- review/tester 这类需要读报告和长输出的 role，比短命令 pane 更应该偏向新 tab。

建议提供显式覆盖：

```bash
orbit start coder --layout auto
orbit start coder --layout same-tab
orbit start coder --layout new-tab
orbit start coder --min-cols 120 --min-rows 30
```

`auto` 是默认值。`same-tab` 如果会低于 hard minimum，应 fail closed 或要求 `--force-layout`，不要静默创建不可读 pane。

start plan 应输出布局决策，便于排障：

```json
{
  "layout": {
    "mode": "auto",
    "selected": "new_tab",
    "reason": "right split would produce panes below minimum readable width",
    "source_pane": "w3:p1",
    "source_size": { "cols": 154, "rows": 42 },
    "minimum": { "cols": 100, "rows": 24 },
    "preferred": { "cols": 120, "rows": 30 },
    "existing_agent_panes_in_tab": 2
  }
}
```

人类输出也要把这个决定说清楚：

```text
Orbit start: reviewer
- layout: new tab
- why: current tab is too narrow for another agent pane
- source pane: w3:p1 154x42
- minimum readable pane: 100x24
```

### Agent readiness

start 成功不应只代表 Herdr 创建了 pane；至少要区分：

- `started`: pane 创建成功，但尚未确认 agent ready。
- `ready`: 看到对应 agent ready marker。
- `needs_attention`: pane 有输出但无法判断是否安全继续。
- `failed`: Herdr 命令或 ready wait 失败。

ready marker 应按 client 配置：

```yaml
clients:
  codex:
    ready_match: "OpenAI Codex|›"
  claude:
    ready_match: "Claude Code|>"
  opencode:
    ready_match: "opencode|>"
```

没有 ready marker 时，不要假装 ready；输出 `started_unverified`，并给出 `herdr pane read ...` 的诊断命令。

Integration-aware readiness:

- Automatic process/screen detection is enough to prove that an agent exists.
- Lifecycle-authority integrations can improve `idle/working/blocked` confidence.
- Session-identity integrations can improve restore and resume, but must not be treated as lifecycle authority.
- `orbit doctor herdr` should report integration type per configured client: `lifecycle_authority`, `session_identity`, `screen_manifest`, or `missing`.
- Missing integrations should warn with install commands, but should not block basic Herdr operation when screen manifest detection is available.

### Safer force

`--force` 应继续是显式动作，但它不再是普通创建或安全 wake 的入口。它只表示“用户明确要求替换 Orbit 当前对这个 instance 的 binding，接受旧 agent 可能仍存在的风险”。

- force 前显示 old pane、old detected process、old detected agent。
- 如果 old pane 里仍是 agent，默认拒绝 wake，除非 `--force --replace-live` 这类未来显式破坏性参数存在。
- force 后写 replacement diagnostic，并提示用户如何查看旧 pane。
- 对同一 instance 的重复 force 加 cooldown，避免 lead 等不及就连续重建。

需要 `--force` 的情况：

- bound pane 上有 live agent，但 client/cwd/project root 与 instance 不匹配。
- runtime 发现同一 instance 有多个 candidate live panes。
- 用户显式指定 `--pane` 覆盖当前 binding。
- replacement diagnostic 表明最近短时间内刚替换过同一 instance。

不需要 `--force` 的情况：

- instance 已配置但没有 binding。
- bound pane 不存在。
- bound pane 是当前 Herdr pane，且将执行 self-wake。
- bound pane 是安全 idle shell，且 Herdr 没检测到 agent。

`--allow-create` 没有必要保留。Herdr-only 后，`orbit start INSTANCE` 的语义就是“确保这个已配置 instance 有可用 Herdr agent”。如果 instance 存在且没有 live binding，创建是默认动作。是否允许某个 instance 被自动启动，应由配置中的 instance 是否存在、operation mode、以及未来的 explicit `launch_policy: manual|auto` 决定，而不是每次命令加 `--allow-create`。

### Dispatch and reply-to

`dispatch` 应默认使用 bound Herdr pane，不要求用户手填 pane：

```bash
orbit dispatch --task .orbit/tasks/current-task.yaml --to reviewer --json
```

消息体应包含 Herdr structured header：

```text
[herdr-msg from:lead pane:w3:p1 reply-to:w3:p1 at:w3/t1 kind:request task:current-task]
```

如果当前 pane 有 `HERDR_PANE_ID`，默认 `reply-to` 用当前 pane；否则用 lead binding。dispatch 结果要输出：

- selected pane
- reply-to pane
- delivery success
- exact message id / header
- manual artifact path when `--manual-payload` / `--dry-run` is explicitly requested

Dispatch should use Herdr agent targets when a live target is detected. For plain panes or repair overrides, use `herdr pane run` and record that the target was not a confirmed agent target.

Do not use Herdr agent status waits as Orbit gate waits:

- wait for concrete reply text only when synchronizing transport.
- Orbit gate readiness still comes from evidence and `wait-gate`.
- On timeout, read the pane and report observed output; do not keep extending waits.

### Notice inbox plus Herdr delivery

`orbit notice` 的权威记录仍在 `.orbit/runtime/notices/`，但 Herdr delivery 应让 lead 不用轮询：

- implementation/review/test complete 后写 notice。
- best-effort 把 notice summary 发送到 owner pane。
- owner pane 收到短消息，包含 event、from instance、task、evidence、next command。
- delivery 失败只影响 notice `delivery` 诊断字段，不影响 notice protocol。

### Doctor and repair

`orbit tools doctor --json` 可以升级为 `orbit doctor herdr --json` 或在现有 doctor 里给出 Herdr repair plan：

- Herdr 是否安装。
- 是否在 Herdr 环境中运行。
- `HERDR_PANE_ID` 是否存在。
- Codex/Claude/OpenCode integration 是否安装。
- configured command 是否存在。
- bound pane 是否存在。
- bound pane 是否 canonical。
- bound pane 是否有 detected agent。
- ready wait 是否可配置。
- Herdr agent state authority for each configured client.
- Whether the bound pane is a real agent target or only a plain pane.
- Whether the agent state is `blocked`, `working`, `done`, `idle`, or `unknown`.
- Whether the agent is running inside an inner tmux process that hides the real agent from Herdr.
- 推荐修复命令。

人类输出示例：

```text
Orbit Herdr doctor:
- herdr: installed
- current pane: w3:p1
- codex integration: installed
- coder binding: stale, pane w3:p4 not found
- next: orbit start coder --force
```

## Command contracts

### `orbit start`

Herdr-only 后，`start` 的外部自动路径应输出 Herdr 语义字段。`adapter` 应是顶层稳定字段；具体诊断放在 `herdr` 对象里：

```json
{
  "schema_version": "orbit-start-plan-v1",
  "adapter": "herdr",
  "instance": "coder",
  "role": "coder",
  "action": "wake",
  "herdr": {
    "session": "project",
    "configured_pane": "w3:p4",
    "canonical_pane": "w3:p4",
    "pane_exists": true,
    "foreground_process": "zsh",
    "detected_agent": null,
    "safe_to_wake": true,
    "ready": "unverified",
    "diagnostic_commands": [
      ["herdr", "pane", "read", "w3:p4", "--source", "recent-unwrapped", "--lines", "80"]
    ]
  }
}
```

Force replacement output should only appear for conflict/override cases:

```json
{
  "schema_version": "orbit-start-plan-v1",
  "adapter": "herdr",
  "instance": "coder",
  "role": "coder",
  "action": "needs_force",
  "herdr": {
    "session": "project",
    "configured_pane": "w3:p4",
    "canonical_pane": "w3:p4",
    "pane_exists": true,
    "detected_agent": "codex",
    "agent_cwd": "/other/checkout",
    "cwd_matches": false,
    "safe_to_replace": false
  },
  "force_command": ["orbit", "start", "coder", "--force"],
  "risk": [
    {
      "code": "duplicate_instance_agents_may_run_concurrently",
      "message": "Old and new agents with the same instance and role may run concurrently."
    },
    {
      "code": "old_and_new_agents_may_compete_for_orbit_state",
      "message": "Old and new agents may compete for evidence, gate leases, and loop state writes."
    }
  ]
}
```

Target default behavior after the breaking cleanup:

- Live Herdr agent detected for the instance: `reuse`.
- No binding: create through Herdr.
- Bound pane missing: create through Herdr and record stale binding diagnostic.
- Bound pane is safe idle shell but liveness is not proven: return `needs_force`; with `--force`, wake through Herdr.
- Bound pane has live conflict or ambiguous duplicate live candidates: `needs_force`.
- Probe failed or Herdr unavailable: `needs_attention` / `doctor_required`.
- `--force`: replace Orbit binding under per-instance lock, write previous binding only to `.orbit/runtime/instances/<instance>.json`.
- `--all`: future convenience command that starts missing instances in dependency order and reports a table.

Implemented behavior and remaining limits:

- `herdr_reuse_probe` classifies live reuse, self-wake, safe idle shell wake, and unsafe/unknown panes.
- Static binding is no longer a live-health proof in `start` or `instances status`; primary status fields are `binding`, `liveness`, `availability`, and `herdr`.
- Safe idle shell wake and self-wake still require `--force`, by design, because a cached binding without a live agent can otherwise create duplicate same-role agents that race on evidence/gate/state.
- Herdr reuse checks `herdr agent list` for a detected agent on the pane, but does not yet verify expected client, cwd, project root, runtime host, or duplicate live candidates as first-class conflict reasons.

Human output should avoid generic transport words when `adapter=herdr`; use `Herdr pane`, `Herdr session`, `detected agent`, and `ready wait`.

No compatibility transition:

- Remove `--transport local|herdr` from `orbit start`.
- Remove `--allow-create` from `orbit start`; configured instances can be created by default.
- Remove `--transport herdr` from normal `orbit dispatch`; Herdr is the only direct delivery adapter.
- Remove `--transport generic` from `dispatch` and `handoff`; manual artifacts should use explicit artifact/delivery naming instead of transport naming.
- Update README examples in the same implementation PR; do not leave old examples as temporary docs.
- Tests must assert removed modes fail with clear remediation, not silently alias to new behavior.

### `orbit dispatch`

Direct delivery is Herdr-only:

- `dispatch --to INSTANCE` uses the instance's bound Herdr pane when it is live-confirmed.
- `dispatch --pane PANE` is a repair/override path, not the normal route; it must still resolve the target instance role and record the explicit override.
- Dispatch to an instance with stale/unverified binding must not claim delivered.
- Dispatch must not auto-start missing instances.
- Non-Herdr use should fail with manual instructions; it should not silently become a fake dispatch.
- If a manual artifact is needed, use a distinct `--manual-payload` / `--dry-run` output shape, not `--transport generic`.
- Dispatch should include a reply-to pane by default, using `HERDR_PANE_ID` first and lead binding second.
- Dispatch should print/read back enough Herdr result metadata to prove the message was submitted, but gate still depends on evidence.

Current implementation follows the fail-closed shape: removed `--transport` flags produce migration guidance, normal direct delivery requires a live-confirmed Herdr binding, explicit `--pane` is recorded as an override, and `--manual-payload` is the non-Herdr artifact path.

### `orbit notice`

Notice has two layers:

- Protocol record: `.orbit/runtime/notices/<role>/<notice-id>.json`.
- Herdr delivery: best-effort copy/summary to owner pane.

Gate/audit checks the protocol record, not Herdr delivery success.

### `orbit handoff`

Handoff is protocol output, not runtime delivery:

- Default output is the Orbit handoff packet.
- Manual delivery artifact can be included with `--manual-payload` or a similarly explicit artifact flag.
- No `--transport NAME` option should remain.
- No handoff path should call Herdr, tmux, CI, or any terminal tool.
- Delivery instructions should be data in the packet, not proof that delivery happened.

Current implementation does not call Herdr during handoff. Removed `--transport` flags produce migration guidance, `.orbit/tools.yaml` uses `delivery_profiles`, and output uses `delivery` / `manual_artifact` terminology.

Recommended output shape:

```json
{
  "schema_version": "orbit-handoff-v1",
  "delivery": {
    "mode": "manual_artifact",
    "runtime_adapter": "none",
    "payload_format": "json",
    "instructions": "Send this file/path to the receiving instance if automatic Herdr dispatch is not used."
  }
}
```

### `orbit tools detect|doctor`

`tools detect` should report:

- `local_shell`
- `herdr`
- `ci`
- `git`

It should not report `tmux`, `zellij`, or `wezterm` as runtime adapters.
Herdr capabilities must only name implemented behavior: `agent.start`, `pane.message`, `pane.capture`, and `direct.dispatch`. `notice.delivery` remains out of scope until a notice backend is implemented.

`tools doctor` should stop reporting a generic "preferred transport". It should report runtime adapter readiness explicitly:

- `runtime_adapter: herdr` when Herdr is available and usable.
- `runtime_adapter: unavailable` when Herdr is missing or not reachable.
- `manual_payload_available: true` because handoff/manual artifact generation does not depend on Herdr.
- `agent_state_authority` per configured client: `lifecycle_integration`, `screen_manifest`, `session_identity_only`, or `unknown`.
- `herdr_diagnostics.current_pane`, `configured_bindings`, `client_integration_authority`, and `inner_tmux` so users can see which pane is current, whether configured panes still exist, how panes canonicalize, and whether nested tmux/screen may interfere.
- Herdr-specific warnings should name concrete repairs, not just "command not found".

Current `tools detect` matches the Herdr-only adapter direction by reporting `local_shell`, `herdr`, `ci`, and `git` and not reporting `tmux`. `tools doctor` reports `runtime_adapter`, `manual_payload_available`, agent state authority, and Herdr diagnostics rather than `preferred_transport`.

## README and init impact

README should say:

- Herdr is optional for Orbit protocol.
- Herdr is required for official automatic runtime adapter behavior.
- Other terminal managers are manual protocol environments only.

`orbit init` should eventually become Herdr-friendly:

- `team` mode generates lead/coder/reviewer/tester instances.
- generated examples prefer Herdr usage.
- docs instruct users to install Herdr integrations for Codex/Claude/OpenCode when using multi-agent mode.
- no generated template should imply tmux/zellij/wezterm automatic support.
- interactive init can ask whether to create a team workspace plan.
- `orbit init --operation-mode team` can write comments showing `orbit start --all` and per-role commands. No `--herdr` init flag is needed because Herdr is the only official runtime adapter.

## Code cleanup list

Remove or keep disabled:

- tmux detection in `tools detect`.
- tmux as `preferred_transport` in `tools doctor`.
- generic “future adapter” promises in docs.
- direct dispatch branches for non-Herdr runtime adapters.
- transport liveness inferred from static `binding` or `health`.
- `start --transport local|herdr`.
- `start --allow-create`.
- `dispatch --transport herdr` and `dispatch --transport generic` as user-facing normal modes.
- `handoff --transport NAME`; handoff should produce a protocol handoff packet plus optional manual delivery artifact without transport terminology.
- `bind-pane --transport NAME`; binding is Herdr-only and should not ask for transport.
- `transport.kind` schema in new `instances.yaml`.
- `.orbit/tools.yaml transport_profiles`; rename to `delivery_profiles` or remove if manual artifact defaults are enough.
- user-facing `binding_status/recommended_action` as primary status fields.
- `preferred_transport` in `tools doctor`; replace it with Herdr adapter readiness plus manual artifact availability.

Keep:

- `generic` handoff/manual artifact generation where it is explicitly a file/payload format and not exposed as a transport.
- manual/current-shell protocol usage.
- `.orbit/tools.yaml` delivery profile payload generation, if still needed, as long as it only describes manual delivery and does not imply official runtime control.
- Herdr diagnostics used by `start`, `dispatch`, `doctor`, and future notice delivery.

## Current implementation gaps

Current implementation has these Herdr-specific pieces:

- resolves Herdr pane aliases to canonical panes before reuse/wake.
- checks `herdr agent list` before treating a binding as live.
- checks current `HERDR_PANE_ID` for self-wake.
- reads `pane process-info` and recent output before deciding safe wake.
- retries `agent_name_taken` with a generated label.
- waits for Codex, Claude, and OpenCode readiness markers when configured.
- writes forced replacement diagnostics outside `instances.yaml`.
- uses per-instance lock files for forced start/wake replacement paths.
- dispatch reply-to defaults already prefer explicit `--reply-to`, then `HERDR_PANE_ID`, then lead binding.
- `tools detect` no longer reports tmux/zellij/wezterm as detected tools.

Remaining gaps to make Herdr-only feel first-class:

- start JSON still spreads some Herdr data across `reuse_probe`, `wake_adapter`, `herdr_start`, and `adapter_result`; a future cleanup can add a normalized `herdr` summary without changing decisions.
- liveness does not yet check expected client, cwd/project root, runtime host, duplicate live candidates, or stale local-vs-remote binding context.
- Herdr integration type is only lightly modeled; future doctor output can distinguish lifecycle authority from session identity from screen manifest detection more deeply.
- no notice command or Herdr delivery yet.
- doctor does not yet inspect every bound pane/process and integration repair path.

## Test plan

Required regressions:

1. `tools detect --json` includes `herdr` and does not include `tmux`.
2. `tools doctor --json` reports `runtime_adapter: herdr|unavailable` and does not report `preferred_transport`.
3. README support table says Herdr-only for wake/create and direct delivery.
4. `start` creates a configured instance with no binding without `--allow-create`.
5. `start` wakes a safe idle Herdr pane without `--force`.
6. `start --force` writes previous binding diagnostics to `.orbit/runtime/instances/<instance>.json`, not `instances.yaml`.
7. Herdr live agent detection can still return `reuse`.
8. Herdr safe wake/create path still works.
9. Generic handoff/manual artifact generation still works without Herdr and is not exposed as `--transport generic`.
10. Notice protocol remains valid even when Herdr delivery fails.
11. `dispatch --to INSTANCE` refuses stale Herdr binding unless explicit pane is supplied.
12. `start` JSON includes normalized `herdr` summary fields.
13. Human start output includes pane, detected agent, readiness, and next command.
14. Client ready markers are configurable for Codex, Claude, and OpenCode.
15. `doctor` reports missing Herdr integration with a concrete install command.
16. Status output separates `liveness` from `availability`.
17. Dispatch refuses `working`, `blocked`, and `unknown` Herdr states by default.
18. Herdr `done` does not satisfy Orbit gate/done.
19. Doctor reports integration authority type for Codex/Claude/OpenCode and warns only at the right severity.
20. Binding diagnostics include runtime host/local-vs-remote context.
21. Labels/titles are verified as presentation-only and never used for role resolution.
22. Auto-create chooses new tab instead of same-tab split when pane width/height would fall below minimum readable size.
23. Auto-create fails closed when `--layout same-tab` would create an unreadable pane without explicit override.
24. Start JSON includes `layout.selected`, `layout.reason`, source size, minimum size, and existing agent pane count.
25. `start --transport local`, `start --transport herdr`, and `start --allow-create` fail with migration guidance.
26. `dispatch --transport herdr`, `dispatch --transport generic`, and `handoff --transport NAME` are removed from normal help and tests.
27. `.orbit/tools.yaml transport_profiles` is removed or renamed to delivery terminology.
28. `bind-pane` writes Herdr canonical workspace/tab/pane without a transport argument.
29. Status output uses `binding` + `liveness` + `availability` + `herdr`, not `binding_status/recommended_action` as primary fields.
30. Peer dispatch refuses role/instance mismatch before touching Herdr.

## Implementation order

1. Align README, runtime guide, and start liveness design with Herdr-only adapter language.
2. Remove tmux from `tools detect` and `tools doctor` adapter output.
3. Introduce the new authority model: instance-derived role, Herdr-only liveness, canonical workspace/tab/pane binding.
4. Remove `start --transport`, `start --allow-create`, generic start transport schema, and local transport mode in one breaking change.
5. Keep `generic` payload only for manual handoff/artifact generation, not runtime start/dispatch/handoff transport routing.
6. Improve `orbit start` Herdr status output: session, pane, process, detected agent, safe wake reason.
7. Add liveness/availability separation from Herdr states.
8. Add integration authority modeling and doctor checks.
9. Add runtime host/local-vs-remote binding diagnostics.
10. Add Herdr layout budget: pane dimensions, same-tab/new-tab decision, and `--layout` override.
11. Add live-confirmed `dispatch --to INSTANCE` behavior and structured reply-to defaults.
12. Remove `dispatch --transport herdr|generic` and `handoff --transport NAME`; Herdr is implicit and manual payload is a separate artifact/delivery mode.
13. Add `orbit notice` protocol storage.
14. Add Herdr best-effort notice delivery.
15. Add Herdr doctor repair output and client ready marker configuration.
16. Remove remaining non-Herdr direct dispatch assumptions and tests.

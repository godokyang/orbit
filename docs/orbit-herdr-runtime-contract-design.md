# Orbit-Herdr runtime contract 设计

本文记录 Orbit 与 Herdr 深度整合的下一步设计。目标是让用户运行 `orbit start reviewer-main`、`orbit instances status --json` 或 `orbit dispatch --to reviewer-main` 时，Orbit 能清楚回答“目标 agent 是否真的活着、是否就是这个 Orbit instance、现在能不能投递、不能投递时下一步做什么”。实现层面不再继续扩展 runtime adapter，而是把 Herdr-only 从“用 Herdr 启动/投递 pane”升级为可验证的 runtime session contract。

## 状态

- Status: proposed
- Scope: `start` / `instances status` / `dispatch` / runtime registration / Herdr probe
- Compatibility: breaking change；不保留旧 transport schema 或静态 binding 假复用语义。
- Baseline: Herdr 是唯一官方 automatic runtime adapter；普通安装必须检测 Herdr 是否可用。没有 Herdr 时，默认安装应停止并提示安装 Herdr；manual-only protocol 只能作为显式模式，不能让用户误以为 `start` / direct `dispatch` 可用。
- Sources: Herdr docs [Quick start](https://herdr.dev/docs/quick-start/), [Concepts](https://herdr.dev/docs/concepts/), [How to work with Herdr](https://herdr.dev/docs/how-to-work/), [Agents](https://herdr.dev/docs/agents/), [Session state and restore](https://herdr.dev/docs/session-state/), [CLI reference](https://herdr.dev/docs/cli-reference/), [Integrations](https://herdr.dev/docs/integrations/), [Agent skill file](https://herdr.dev/docs/agent-skill/)。

## 用户可见目标

改完后，Orbit 不只是知道 `reviewer-main` / `coder-main` 配置里应该存在，也能在每次使用前回答：

- 这个 instance 当前有没有活着的 Herdr agent。
- 这个 Herdr agent 是否真的声明并验证为目标 Orbit instance/role。
- 当前能不能 direct dispatch。
- 不能 dispatch 时，用户下一步应该运行哪条命令。

安装体验也必须前置这个事实：Herdr 是 Orbit automatic runtime 的必需依赖。安装脚本应先检查 `herdr` 是否在 `PATH` 中且 `herdr --version` 可执行；缺失时不要继续假装安装成功，而是输出明确 remediation：

```text
Herdr is required for Orbit automatic runtime.
Install Herdr first:
  curl -fsSL https://herdr.dev/install.sh | sh
  herdr --version
Then rerun the Orbit installer.
```

如果未来保留 manual-only 安装，它必须使用显式选项，例如 `--manual-only` 或 `ORBIT_MANUAL_ONLY=1`，并在安装结果里写清楚：`orbit start` 自动创建/唤醒、Herdr direct dispatch、Herdr notice surfacing 都不可用。

典型体验应是：

```bash
orbit start reviewer-main
```

可能返回：

```text
action: reuse
identity_verification: verified
dispatch_ready: true
pane: w1:p2
```

也可能返回：

```text
action: started_identity_pending
identity_verification: pending
dispatch_ready: false
next:
  - inspect_pane: herdr pane read w1:p2
  - request_agent: "请在这个 agent pane 内运行 orbit runtime register --json"
```

`started_identity_pending` 不是启动失败。它表示 Herdr agent 已经启动，但 Orbit 还没有从 agent 自身拿到可验证的 runtime registration。用户不应该在 lead pane 里运行 `orbit runtime register --json`；正确动作是检查目标 pane，然后让目标 agent 自己运行这条命令，或等该 agent 第一次运行任意 Orbit CLI 命令触发 piggyback register 后，session 变成 `verified`。

```bash
orbit dispatch --task task.yaml --to reviewer-main --json
```

只有在目标同时满足 `Herdr alive + Orbit identity verified + availability available` 时才会 direct delivery。否则输出 `dispatch_ready: false` 和明确 remediation，而不是把消息盲投到一个看起来像 agent 的 pane。

## 核心模型

这个设计用三层事实替代“binding 存在即复用”的旧心智：

```text
.orbit/instances.yaml = 期望配置和上次已知 Herdr handle hint
.orbit/runtime/      = 当前运行态、session identity 和 replacement/ack 记录
Herdr query           = 当前现场事实：pane、agent、cwd、client、status、layout
```

三层必须一起成立，才能证明一个 instance 是 live participant：

```text
config expected identity
  + runtime session self-registration
  + on-demand Herdr live probe
  = verified Orbit runtime participant
```

关键含义：

- `instances.yaml` 是配置，不是 alive proof。
- `.orbit/runtime` 是 per-checkout runtime 状态，必须 gitignored，不进入 task/evidence 历史。
- Herdr query 是现场事实，但 Herdr `agent_status` 不是 Orbit task/gate 完成语义。
- env 只作为 probe 输入，不是 identity proof。
- manual Orbit protocol 仍可用：`manual_runtime` 可以提交 evidence、参与 gate，但不能用于 Herdr direct dispatch，audit/handoff 必须标注它不是 Herdr-verified。

### 写入位置规则

为了避免 `orbit status` 造成 git diff，版本化配置和运行态写入分开处理：

| 命令/场景 | 可以写 `.orbit/instances.yaml` | 可以写 `.orbit/runtime` | 说明 |
| --- | --- | --- | --- |
| `orbit start INSTANCE` 新建 agent | 是 | 是 | 新建 instance 的 stable Herdr handle 可以进入 config，同时写 provisional session |
| `orbit start INSTANCE --force` 替换 agent | 是 | 是 | 写新 binding，并把旧 session 标记为 replaced |
| `orbit start INSTANCE` 发现 stale 但未启动新 agent | 否 | 是 | 只写 runtime repair pointer / diagnostics，避免 status-like repair 产生 git diff |
| `orbit instances status --json` | 否 | 是 | 默认只诊断和刷新 runtime |
| `orbit instances status --repair-binding --json` | 是 | 是 | 用户显式要求把 repaired binding 写回 config |
| `orbit bind-pane` | 是 | 是 | 只写 manual hint，不能标记 verified |

## 常用命令流程

### `orbit start INSTANCE`

1. 读取 `instances.yaml` 的期望 role、command、layout hint。
2. 查询 `.orbit/runtime/instances/<instance>.json` 和 session record。
3. 现场 probe Herdr。
4. 当前版本没有 trusted caller-pane proof provider，因此不会把任何 session 判定为 live + verified，也不会返回 verified reuse。
5. 如果启动成功但无法建立 verified runtime identity，返回 `action: started_identity_pending`、`dispatch_ready: false` 和 pane-aware `next` remediation。
6. 如果 binding stale，当前版本只输出诊断；只有显式 `--repair-binding` 才允许写回版本化 config，且不能把未验证 session 写成 repaired binding。
7. 未来接入 trusted proof provider 后，多个 verified 候选才应返回 `needs_attention`，要求用户人工检查 pane。

`started_identity_pending` 的 `next` 必须给出 pane-aware remediation：

```yaml
next:
  - inspect_pane: herdr pane read <pane>
  - manual_payload: "Herdr verified runtime is unavailable until trusted caller-pane proof exists; use orbit dispatch --manual-payload for task delivery."
```

如果实现了 Herdr notification/request delivery，Orbit 可以 best-effort 向目标 pane 投递 registration request；失败时仍必须把上面的人工操作显示给用户。这个 request 只是提示，不改变 `identity_pending` 状态，也不算 registration 成功。当前版本没有 trusted caller-pane proof provider，所以 `orbit runtime register --json` 不能把 session promotion 成 `verified`。

### `orbit runtime register --json`

在 agent pane 内运行。它读取当前 Orbit identity、Herdr env 和 session env，但这些只是输入；Orbit 必须有不可伪造的 caller-pane proof provider，才能把 session 写成 `identity.verification: herdr_verified`。当前 Herdr 只暴露可由进程环境伪造的 pane/session 信息，因此当前实现只会写 `identity_pending` 或 `manual_runtime` diagnostics，不会 promotion 到 `herdr_verified`。

### `orbit instances status --json`

展示每个 instance 的配置状态、runtime session 状态和现场 Herdr 事实。默认只诊断和更新 `.orbit/runtime`，不改 `.orbit/instances.yaml`。需要把 repaired binding 写回配置时，用户显式运行：

```bash
orbit instances status --repair-binding --json
```

### `orbit dispatch --to INSTANCE`

每次投递前重新 resolve target。direct delivery 要求：

- task contract 允许目标 instance/role。
- Herdr liveness 是 `alive`。
- Orbit identity verification 是 `verified`。
- availability 是 `available`。

不满足时走 `--manual-payload` 或按 remediation 处理；`--pane` 只是人工覆盖投递目标，不是 identity verified。

### `orbit runtime ack-session INSTANCE --json`

当 Herdr 报告目标是 `done` 时，Orbit 将其映射成 `available_needs_seen`，默认不继续投递，避免覆盖还没被 owner 读过的结果。owner 检查目标 pane 后运行：

```bash
orbit runtime ack-session reviewer-main --json
```

ack 只对当前 session/pane 生效，并应有短 TTL；session 变化或 TTL 过期后需要重新检查。

## 状态和用户动作

| 状态 | 含义 | 用户下一步 |
| --- | --- | --- |
| `verified` + `dispatch_ready: true` | Herdr live + Orbit session identity 匹配 | 可以 `dispatch` |
| `started_identity_pending` / `pending` | agent 已启动，但 Orbit 还没拿到可验证 registration | 在目标 pane 跑 `orbit runtime register --json`，或让 agent 先运行任意 Orbit CLI 命令 |
| `needs_attention` | Orbit 不敢自动选择或修复目标，通常因为候选 pane 多个、身份冲突或 unsafe wake | 人工检查候选 pane；确认后 `orbit start INSTANCE --force` 替换，或用 `--manual-payload` 手动投递 |
| `identity_verification: absent` | Herdr 看见 agent，但没有 Orbit runtime session | 跑 `orbit runtime register --json`；如果不是 Orbit agent，重新 `orbit start INSTANCE --force` |
| `binding_resolution: stale` | 配置里的 pane/hint 已不指向 live verified session | 运行 `orbit start INSTANCE` 重新解析或启动；如已修复，运行 `orbit instances status --repair-binding --json` 写回 config |
| `binding_resolution: repaired` | `.orbit/runtime` 找回了同一 verified session，但配置 hint 仍旧 | 可以继续使用；需要稳定化时运行 `orbit instances status --repair-binding --json` |
| `binding_resolution: ambiguous` | 找到多个 verified/live 候选 | 人工检查候选 pane；必要时 `orbit start INSTANCE --force` 替换信任关系 |
| `availability: available_needs_seen` | Herdr 认为目标 done，可能有未读结果 | owner 检查 pane 后运行 `orbit runtime ack-session INSTANCE --json` |
| `availability: busy` | 目标正在工作 | 等待或改用 manual payload，不要 direct dispatch |
| `availability: needs_user_or_owner_attention` | 目标 blocked 或需要人处理 | owner 检查 pane / notice / evidence，再决定继续或 force |
| `identity_verification: manual_runtime` | 非 Herdr verified，但 Orbit protocol 可手动执行 | 可以提交 evidence；不能 direct dispatch；audit/handoff 标注 manual runtime |
| `identity_verification: override` | 用户显式 `--pane` 绕过 identity proof | 只表示人工投递；不能写 active session 或 gate-closing identity |

## 关键边界

- Binding 不是 alive proof。它只是 launch hint 和最近可信 handle。
- Env 不是 identity proof。`HERDR_ENV` / `HERDR_PANE_ID` 只能证明进程在 Herdr-managed pane 内，不能证明它是目标 Orbit role。
- `--pane` override 不是 verified。它不得写 active session，不得让 evidence gate 继承身份。
- Herdr `done` 不是 Orbit task done。Orbit done 仍由 evidence、wait-gate、validate、audit 决定。
- Manual runtime 仍是合法 protocol path。默认策略允许 `manual_runtime` evidence 参与 gate，但不能使用 Herdr direct dispatch，audit/handoff 要暴露 runtime verification gap。项目可以选择更严格策略：如果项目要求 Herdr-verified gate，`manual_runtime` 只能作为补充证据，必须有 waiver 或项目策略显式允许才能关闭 gate。

## 用户流程摘要

1. 运行 `orbit start INSTANCE`。
2. 如果 `dispatch_ready: true`，可以直接 `orbit dispatch --to INSTANCE`。
3. 如果 `started_identity_pending`，检查输出里的 pane，并让目标 agent 运行 `orbit runtime register --json`。
4. 如果 `stale` / `repaired`，默认继续使用 `.orbit/runtime` 的 repair 结果；需要更新配置时运行 `orbit instances status --repair-binding --json`。
5. 如果 `available_needs_seen`，owner 先读目标 pane，再运行 `orbit runtime ack-session INSTANCE --json`。
6. 如果 `needs_attention` / `ambiguous`，Orbit 不会自动选择 pane；用户人工确认后 force replace 或改用 manual payload。

## 问题

当前 Orbit 已经收窄到 Herdr-only，但 Orbit 与 Herdr 的结合仍停留在外部 adapter 层：

- `.orbit/instances.yaml` 记录 Herdr workspace/tab/pane binding。
- `orbit start` 用 `herdr agent start` 创建 agent，或用 Herdr probe 复用已有 binding。
- `orbit dispatch` 用 Herdr pane delivery 发送消息。
- `orbit instances status` 展示 binding、liveness 和 Herdr handle。

这个模型能证明“某个 Herdr pane 上有一个 agent”，但不能严格证明“这个 agent 就是某个 Orbit instance/role”。

当前实现的关键缺口：

1. Herdr `agent list` 只提供 runtime/container 事实，例如 pane、agent label、agent status、cwd。
2. Orbit role identity 来自 `.orbit/instances.yaml` 和当前进程环境变量。
3. `start` 复用已有 binding 时只校验 client/cwd，没有校验运行中 agent 自己声明的 `ORBIT_INSTANCE` / `ORBIT_ROLE`。
4. 没有 binding 时，`start reviewer-main` 无法从 Herdr 全局 agents 里可靠发现一个已经启动的 `reviewer-main`。
5. `bind-pane` 只写入 handle，后续如果不做更强验证，容易把“绑定存在”误当成“身份可信”。

一句话概括：

```text
Herdr 证明 runtime container 活着；Orbit 需要证明 protocol participant 活着。
```

两者之间需要一个共享的 runtime identity/session layer。

还有一个更底层的约束：Orbit 不应依赖常驻进程或 Herdr-side hook 来维护正确性。用户可以手动移动、重命名或删除 Herdr pane/tab/workspace，Orbit 不能设计成“配置实时同步 Herdr UI 状态”。正确模型必须是：

```text
Orbit 不接收实时变更；Orbit 在每次需要使用 instance 前，现场向 Herdr 查询并重新解析。
```

这意味着 `.orbit/instances.yaml` 中的 binding 不能被设计成实时同步状态，只能是 last-known launch hint。任何会投递消息、复用 agent 或关闭 gate 的命令，都必须先执行 runtime resolution。

## Herdr 能力基线

Herdr 当前模型对 Orbit 很有价值：

- Herdr 有持久 server session；用户 detach 后 panes 和 agents 继续运行。
- Workspace 是项目级容器，拥有 tabs、panes 和 agents。
- Pane 是真实终端，Herdr 可以读输出、发输入、检查布局和进程信息。
- Agent 是 Herdr 在 pane 中识别出的进程，状态包括 `blocked`、`working`、`done`、`idle`、`unknown`。
- Herdr 可以自动检测常见 coding agent；安装 integration 后，部分 agent 可以获得更准确的 lifecycle 或 session identity。
- `herdr agent start <name> --cwd PATH --env KEY=VALUE -- <argv...>` 可以从 CLI 启动带环境变量的 agent。
- `herdr pane report-metadata` 可以报告只用于展示的 metadata，不接管 semantic state。
- `herdr pane list/get/read/process-info/layout` 和 `herdr agent list/get/read/explain` 可以作为 runtime probe 输入。

因此 Orbit 不应该再把 Herdr 当作“可替换终端工具”。Herdr 应成为 Orbit 官方 runtime layer，承载 pane/process/status/session facts；Orbit 继续作为 protocol layer，承载 role/task/evidence/gate/handoff facts。

## 额外整合面

Herdr 文档暴露了多个值得成为 Orbit 一等设计输入的能力，不应只停留在最初的 `start` / `dispatch` binding。

### Workspace 和 named session 映射

Herdr 推荐一个 repo、task 或 investigation 对应一个 workspace；当 panes、sockets 和 runtime state 需要完全隔离时使用 named session。因此 Orbit 应在 runtime diagnostics 中同时记录 workspace identity 和 Herdr named session identity：

```yaml
binding:
  adapter: herdr
  session: default
  workspace: ""
  tab: ""
  pane: ""
  canonical_pane: ""
```

`session` 应该是 runtime adapter 字段，不是 role 字段。同一个 Orbit project 可以出现在本地默认 Herdr session 或某个本地 named Herdr session 中；这些是不同 runtime namespace。`orbit instances status` 和 replacement diagnostics 应输出 session namespace，避免把另一个本地 Herdr session 里的旧 pane id 当成可信对象。

### Binding 层语义

`instances.yaml` 中的 binding 不负责实时同步 Herdr 状态。它只保存上一次 Orbit 成功启动或成功验证后的 hint：

```yaml
binding:
  adapter: herdr
  session: default
  workspace: ""
  tab: ""
  pane: ""
  canonical_pane: ""
```

这些字段的含义：

- `session`: 本地 Herdr session namespace。不同 session 中的 pane id 不能混用。
- `workspace` / `tab`: 布局和诊断 hint。用户改名、移动或删除后可以 stale。
- `pane` / `canonical_pane`: 上一次 verified session 所在 pane。它是定位入口，不是身份权威。

真正的身份权威在 `.orbit/runtime/sessions/<session_id>.json`：

```text
instance + role + session_id + launch_id + Herdr observed pane/client/cwd
```

因此 binding 写入规则应是：

1. `orbit start` 新建或 `--force` 替换 agent，并成功拿到 Herdr pane id 后，可以写 `.orbit/instances.yaml` binding。
2. `orbit start` 只是在现场 resolve 到已有 session，或发现 stale binding 但未启动新 agent 时，不写 `.orbit/instances.yaml`；只写 `.orbit/runtime` repair pointer / diagnostics。
3. 当前版本的 `orbit runtime register` 只能写 `.orbit/runtime` diagnostics；没有 trusted caller-pane proof provider 时不能写 verified session，也不应单独改版本化 config。
4. `orbit instances status` 默认不写 `.orbit/instances.yaml`，只输出 repair 诊断，并可写 `.orbit/runtime/...` repair pointer。
5. 用户显式传 `orbit instances status --repair-binding --json` 时，才允许把 repaired binding 写回版本化 config。
6. 如果 Herdr 中找不到对应 live session，不删除 binding，只输出 `stale` / `not_alive`，避免丢失诊断线索。
7. 如果发现多个候选，不写 binding，返回 `needs_attention`。
8. `orbit bind-pane` 只写 manual hint，不能设置 `identity_verification: verified`。

这层设计的关键点是：Orbit 不需要“收到用户改了 Herdr 设置”的事件。Orbit 只需要在下一次使用该 instance 前，发现缓存 binding 已经 stale，然后通过 runtime session 和 Herdr query 尝试重新 resolve。不能可靠重新定位时必须保持 stale，而不是用 cwd/client 猜一个 role。

### 按需 resolution，而不是实时同步

Orbit 不依赖常驻 watcher，也不假设用户手动修改 Herdr UI 时 Orbit 会立刻收到消息。Orbit 只在命令执行时做按需 resolution：

- `orbit instances status`：查询 Herdr 当前事实，输出 binding 是否 stale、是否可修复。
- `orbit start INSTANCE`：当前版本不做 verified reuse；只使用 Herdr/binding 作为启动或 pending diagnostics 输入。
- `orbit dispatch --to INSTANCE`：每次投递前重新 resolve，不能直接相信缓存 binding。
- `orbit evidence submit`：提交 gate-closing evidence 前记录当前进程 runtime attribution；当前版本不能产出 Herdr-verified attribution，手写 `herdr_verified` 也不能关闭 gate。

正确性必须来自每次命令执行时的现场 Herdr query + Orbit runtime session 校验。

### Agent explain 和 manifest diagnostics

Herdr 的 `agent explain` 和 `server agent-manifests` 应进入 `orbit tools doctor --json`：

- 如果 liveness 是 `unknown`，对目标 pane 附带 `agent explain --json`。
- 如果已知 agent 被分类为 idle，但输出看起来像 blocked，报告 manifest source 和 fallback reason。
- 在把 detection 判为损坏前，建议运行 `herdr server update-agent-manifests --json`。

这样 Orbit 不需要自己实现脆弱的 screen parser。

### Notifications 和 attention routing

Herdr 可以显示 notifications，也有 sidebar rollups。Orbit 应为 Herdr 暴露 protocol-level `notice` delivery policy：

- review/test gate ready
- agent blocked 或 needs owner attention
- implementation evidence submitted
- stale/replaced duplicate session detected

Notification delivery 只是 best-effort UI attention，不是 evidence。`notice` records 仍是 Orbit protocol artifacts；Herdr notifications 只是 presentation channel。

### Herdr agent skill 和 in-pane guard

Herdr agent skill 的核心规则很简单：只有设置了 `HERDR_ENV=1` 时，agent 才应该控制 Herdr。Orbit runtime commands 应采用同样 guard，但这个 guard 不是身份认证：

- `HERDR_ENV=1` 和 `HERDR_PANE_ID` 只能证明当前进程处在 Herdr-managed pane 内，且可以使用本地 Herdr socket。
- 它们都是进程 env 输入，不能单独证明 Orbit identity。
- `orbit runtime register` 只有在 Orbit 自己调用 Herdr probe 校验当前 pane、agent、cwd、client、session metadata 后，才能产出 `herdr_verified` registration。
- 验证不了 Herdr runtime 事实时，registration 只能是 `manual_runtime` 或 `identity_pending`，不能解锁 direct Herdr dispatch。
- 当 task 预期使用 Herdr delivery 时，`context_preflight` 应包含对 `HERDR_ENV=1` 的显式检查。

## 目标不变量

Orbit 与 Herdr 整合后必须满足这些不变量：

1. `ORBIT_INSTANCE` 是 concrete instance key，不接受 role alias。
2. `ORBIT_ROLE` 是冗余校验字段，不能覆盖 instance config 解析结果。
3. `.orbit/instances.yaml` 中的 binding 是 launch hint 和最近可信 handle，不是 alive 证明。
4. Herdr `agent_status` 只表示 runtime 可用性，不表示 Orbit task/gate 完成。
5. Orbit 不能假设用户对 Herdr pane/tab/workspace 的手动修改会实时同步到 `.orbit/instances.yaml`。
6. 所有使用其他 instance 的命令都必须先按需 resolve runtime identity，不能直接使用缓存 binding。
7. 一个 agent 被视为 Orbit-live，必须同时满足：
   - Herdr 能看到 live agent 或可检查的 live pane。
   - client 与 instance command 匹配。
   - cwd/project root 与当前 checkout 匹配。
   - Orbit runtime registration 中的 instance/role/session 与 Herdr pane 匹配。
   - registration heartbeat 未过期，或能被当前 probe 刷新。
8. `dispatch` direct delivery 只允许投递到 identity-verified live session。
9. 没有 identity-verified session 时，必须走 `start`、`--manual-payload` 或显式人工 override，不能静默复用。

## Launch flow

`orbit start INSTANCE` 应生成：

- `ORBIT_INSTANCE`
- `ORBIT_ROLE`
- `ORBIT_PROJECT_ROOT`
- `ORBIT_PROJECT_ID`
- `ORBIT_SESSION_ID`
- `ORBIT_LAUNCH_ID`

然后通过 Herdr 启动：

```bash
herdr agent start reviewer-main \
  --cwd /repo \
  --env ORBIT_INSTANCE=reviewer-main \
  --env ORBIT_ROLE=reviewer \
  --env ORBIT_PROJECT_ROOT=/repo \
  --env ORBIT_SESSION_ID=ors_... \
  --env ORBIT_LAUNCH_ID=orl_... \
  --split right \
  -- codex
```

启动后，Orbit 应：

1. 从 start output 解析 Herdr pane id。
2. 写入 provisional runtime session record。
3. 如果配置了 client-specific ready marker，则等待 ready marker。
4. 返回包含 `context_preflight.commands` 的 start result；当前版本不把 `orbit runtime register --json` 当成自动 promotion 步骤。
5. 所有 Orbit CLI 命令在 Herdr 环境内运行时可以 piggyback `runtime register` 记录 diagnostics，但没有独立 heartbeat 子命令。
6. 只有接入不可伪造的 trusted caller-pane proof provider 后，Orbit 才能把 session 标记为 `identity.verification=herdr_verified`。当前 Herdr env / probe 不足以构成 proof。

如果 agent client 无法运行自动 post-start hook，`orbit start` 仍可以成功启动，但必须返回：

```text
action: started_identity_pending
dispatch_ready: false
next: use orbit dispatch --manual-payload
```

这样用户能看到 agent 已启动，但不能立即 direct dispatch。当前版本不会完成 pending -> verified 转换；后续任意 Orbit CLI 命令最多刷新 pending/manual diagnostics。

## Agent registration

新增 CLI 命令：

```bash
orbit runtime register --json
```

该命令运行在 agent process 或 pane 内。它应：

1. 运行与 `whoami --json` 相同的 identity resolver。
2. 读取存在的 Herdr env 字段，但只把它们作为 probe 输入：
   - `HERDR_ENV`
   - `HERDR_PANE_ID`
   - `HERDR_TAB_ID`
   - `HERDR_WORKSPACE_ID`
3. 如果设置了 `ORBIT_SESSION_ID` / `ORBIT_LAUNCH_ID`，则进行校验。
4. 调用 Herdr probe 采集当前 pane、agent、client/cwd、Herdr session namespace、session metadata 诊断。
5. 当前版本即使 probe 看起来匹配，也不能写 `identity.verification=herdr_verified`，因为 caller pane proof 不可信。
6. 只允许写 `manual_runtime` 或 `identity_pending`，且 `dispatch_ready=false`。
7. 更新 `.orbit/runtime/instances/<instance>.json`。
8. 向 Herdr 报告 metadata：

```bash
herdr pane report-metadata "$HERDR_PANE_ID" \
  --source orbit \
  --display-agent reviewer-main \
  --custom-status "orbit:reviewer"
```

Orbit 不使用 `herdr pane report-agent --source orbit` 接管 Herdr semantic state。Herdr agent status 仍由 Herdr 自己的 detection / integration 负责；Orbit identity 以 `.orbit/runtime/sessions/<session_id>.json` 为准。

## Heartbeat

当前版本没有独立 heartbeat 子命令。refresh 语义仅限 `runtime register` 对 pending/manual diagnostics 的 best-effort 更新，不产生 Herdr verified identity。

不要在测试脚本或用户文档中要求第一版独立 heartbeat 命令。未来只有在 trusted caller-pane proof provider 可用后，才应重新设计 active verified session 的刷新命令。届时它应刷新当前 session：

- `last_seen_at`
- 来自 env 或 probe 的 Herdr pane/tab/workspace
- 可用时来自 `herdr agent get/list` 的 agent status
- 如果当前 env 不再匹配已注册 instance，则记录 identity conflicts

Heartbeat 应轻量且安全，可在这些时机运行：

- `evidence submit` 前
- `dispatch` 收到 reply 前
- agent shell hooks 可用时
- `start` / `instances status` 作为 passive refresh

不要求持续运行的后台 daemon。heartbeat 过期表示 `identity_stale`，不等于进程立刻死亡。

## Liveness algorithm

用分层 probe 替代当前静态状态：

```text
load instance config
load runtime instance pointer
load current runtime session
probe Herdr by last-known pane/canonical_pane/session metadata
if last-known binding is stale, try stable Herdr pane/session metadata first
if metadata lookup is unavailable, do not infer role from cwd/client alone
probe Herdr agent list for client/cwd/status
compare Orbit session instance/role with config
return liveness + identity_verification + availability
```

建议状态：

```text
liveness:
  alive
  not_alive
  unknown

identity_verification:
  verified
  pending
  stale
  mismatch
  absent

availability:
  available
  available_needs_seen
  busy
  needs_user_or_owner_attention
  unknown

binding_resolution:
  current
  repaired
  stale
  missing
  ambiguous
```

`alive` 需要 Herdr live signal。`verified` 需要 Orbit runtime session 匹配。`dispatch` 必须同时要求 `alive` 和 `verified`。

示例：

```text
Herdr agent exists, client/cwd match, session instance/role match -> alive + verified
Herdr agent exists, no runtime session -> alive + absent
Binding exists, Herdr pane missing -> not_alive + absent
Runtime session says reviewer-main, Herdr pane has coder-main metadata -> alive + mismatch
Herdr unavailable -> unknown + stale/absent
```

`binding_resolution` 只描述缓存 binding 和当前 Herdr 事实的关系：

- `current`: 缓存 binding 仍指向当前 session hint；当前版本不把它解释为 verified proof。
- `repaired`: 预留给未来 trusted proof provider。当前版本不能通过 stable Herdr pane、Orbit session metadata 或 runtime registration 自动写 repaired verified binding。
- `stale`: 缓存 binding 指向的 pane 不存在或不匹配，且找不到同一 session。
- `missing`: instance 没有 binding，也没有可用的 trusted verified session。
- `ambiguous`: 预留给未来 trusted proof provider；找到多个 verified 候选时必须人工处理。

## 无 binding 时的 discovery

当 `.orbit/instances.yaml` 没有 `reviewer-main` 的 binding 时，第一版目标是先扫描可验证来源，避免重复 agent：

- `instance=reviewer-main` 的 runtime sessions
- 与注册 pane 匹配的 Herdr `agent list` entries
- 可用时带 Orbit source 的 Herdr metadata
- client/cwd match 只能作为辅助检查，不能单独证明 role

当前实现没有 trusted caller-pane proof provider，因此不能把这些来源提升为 verified reuse。即使存在手写 `herdr_verified` session 文件，也必须忽略，不能返回 `dispatch_ready: true`。

未来如果发现唯一一个 trusted verified live session：

1. 复用它。
2. 更新 `.orbit/runtime` current session / repair pointer。
3. 返回 `action: reuse_discovered`。
4. 如果用户希望把 repaired binding 稳定写回配置，提示运行 `orbit instances status --repair-binding --json`。

未来如果发现多个 trusted live candidates：

```text
action: needs_attention
reason: duplicate_verified_sessions
```

如果没有 verified candidate，则启动新的 Herdr agent。不要因为某个 Herdr agent 的 client/cwd 看起来匹配，就把它当作该 instance 复用。

## Dispatch precondition

`orbit dispatch --to INSTANCE` 应要求：

- task contract 允许目标 instance/role。
- Herdr liveness 是 `alive`。
- Orbit identity verification 是 `verified`。
- availability 是 `available`。
- target pane 是 canonical pane，且属于 verified session。

`done` 不应被当成 Orbit work completed。Herdr states 只映射为 delivery availability：

```text
idle     -> available
done     -> available_needs_seen
working  -> busy
blocked  -> needs_user_or_owner_attention
unknown  -> unknown
```

如果目标是 `available_needs_seen`，默认 fail closed，并要求 owner 先检查或 acknowledge 该 pane，再发送新工作。这样可以避免覆盖“已经完成但还没被读”的回复。

### available_needs_seen acknowledge

新增：

```bash
orbit runtime ack-session INSTANCE --json
```

该命令用于 owner 明确确认已经看过 target pane 的 `done` / unread state。它应写入 `.orbit/runtime/instances/<instance>.json`：

```json
{
  "ack": {
    "session_id": "ors_...",
    "pane": "w1:p2",
    "acknowledged_at": "2026-07-04T10:20:00Z",
    "acknowledged_by": {
      "instance": "lead-main",
      "role": "lead"
    },
    "reason": "owner_inspected_done_state"
  }
}
```

`dispatch` 遇到 `available_needs_seen` 时，只有在 ack 的 `session_id` 和当前 target session 匹配，且未过期时，才允许继续。ack TTL 应作为 project setting 或固定短 TTL；过期后需要重新检查 pane。

## bind-pane 语义

`orbit bind-pane` 应保留为 manual escape hatch，但输出必须明确：

```json
{
  "action": "bound",
  "identity_verification": "absent",
  "liveness": "unknown",
  "dispatch_ready": false,
  "next": [
    ["orbit", "runtime", "register", "--json"],
    ["orbit", "instances", "status", "--json"]
  ]
}
```

绑定 pane 绝不意味着：

- 这个 pane 里有 agent
- 这个 agent 拥有正确 Orbit instance
- 允许 direct dispatch delivery

### --pane explicit override

`dispatch --pane` 是人工绕过 live identity proof 的 escape hatch。它可以用于手动投递，但语义必须明确：

- `identity_verification: override` 不是 `verified`。
- 不得写 active runtime session。
- 不得写 evidence author identity。
- 不得让 review/test gate 继承该身份。
- JSON 和 TTY 输出都必须包含 risk，说明这是人工指定 pane，Orbit 没有证明该 pane 上的 agent 是目标 instance/role。

示例：

```json
{
  "delivery": {
    "mode": "herdr_direct",
    "explicit_override": true,
    "identity_verification": "override"
  },
  "risk": [
    {
      "code": "manual_pane_override_not_identity_verified",
      "message": "The explicit pane was not proven to host the target Orbit instance. Delivery may reach the wrong agent."
    }
  ]
}
```

## instances status output

`orbit instances status --json` 应区分四个概念：

```json
{
  "instance": "reviewer-main",
  "resolved_role": "reviewer",
  "binding": "bound",
  "binding_resolution": "current",
  "herdr_liveness": "alive",
  "identity_verification": "verified",
  "availability": "available",
  "dispatch_ready": true,
  "runtime_session": {
    "session_id": "ors_...",
    "last_seen_at": "2026-07-04T10:00:05Z",
    "ttl_seconds": 30
  },
  "diagnostics": []
}
```

针对当前实现缺口，status 应明确表达：

```json
{
  "herdr_liveness": "alive",
  "identity_verification": "absent",
  "binding_resolution": "current",
  "dispatch_ready": false,
  "diagnostics": [
    "Herdr can see an agent, but Orbit runtime identity has not been registered."
  ]
}
```

当用户手动移动或删除 Herdr pane 后，status 应显式输出：

```json
{
  "binding": "bound",
  "binding_resolution": "stale",
  "herdr_liveness": "not_alive",
  "identity_verification": "stale",
  "dispatch_ready": false,
  "diagnostics": [
    "Stored Herdr binding no longer points to a live verified Orbit session."
  ]
}
```

如果能通过 `session_id` 找回同一 agent，则输出：

```json
{
  "binding": "bound",
  "binding_resolution": "repaired",
  "herdr_liveness": "alive",
  "identity_verification": "verified",
  "dispatch_ready": true,
  "config_write": "not_written",
  "repair_binding_command": ["orbit", "instances", "status", "--repair-binding", "--json"],
  "diagnostics": [
    "Stored Herdr binding is stale. Runtime session was repaired in .orbit/runtime; pass --repair-binding to update .orbit/instances.yaml."
  ]
}
```

## Force replacement

`orbit start INSTANCE --force` 应替换信任关系，而不是静默 kill 进程。

Force flow：

1. 获取 per-instance start lock。
2. 记录 previous binding 和 runtime session pointer。
3. 用新的 `ORBIT_SESSION_ID` 启动一个新的 Herdr agent。
4. 在 runtime state 中把 previous session 标记为 `replaced`。
5. 只有拿到 Herdr pane id 后才写入 new binding。
6. 只有 runtime registration 验证身份后才标记 dispatch ready。

如果旧进程仍在运行，除非它还能证明自己拥有 active session，否则后续写操作应失败。Evidence writes 应包含 runtime session id，因此 replaced sessions 不能悄悄为 active instance 提交新的 implementation/review/test records。

## Evidence identity hook

会关闭 gate 的 evidence commands 应捕获 runtime identity：

```json
{
  "author": {
    "instance": "reviewer-main",
    "role": "reviewer"
  },
  "runtime_identity": {
    "verification": "herdr_verified",
    "session_id": "ors_...",
    "herdr_pane": "w1:p2"
  }
}
```

Evidence runtime identity 分为：

```text
herdr_verified
manual_runtime
explicit_waiver
stale
replaced
```

`dispatch` direct delivery 必须要求 `herdr_verified`。手动运行 Orbit protocol 时可以提交 `manual_runtime` evidence；如果 manual runtime 写入 session file，它必须使用 `state: "active"` + `identity.verification: "manual_runtime"`，表示协议 session 活跃但没有 Herdr proof。它可以参与 gate，但 audit/handoff 必须明确标注不是 Herdr-verified。`stale` / `replaced` 不能关闭 gate。`explicit_waiver` 必须记录 owner、reason、risk、replacement_evidence 和 expiry。

这能弥补“role 可以从 config 推断，但运行进程从未绑定到 Herdr role participant”的漏洞，同时不破坏没有 Herdr 时的 manual Orbit protocol。

## 实现 schema

本节是实现细节，普通用户不需要阅读。用户只需要理解前面的命令流程、状态表和写入位置规则。

新增 Orbit runtime session contract：

```json
{
  "schema_version": "orbit-runtime-session-v1",
  "project_root": "/repo",
  "project_root_sha256": "sha256:...",
  "project_id": "orbit",
  "host_id": "local-host-id",
  "user": "yangke",
  "instance": "reviewer-main",
  "role": "reviewer",
  "role_ref": "reviewer",
  "role_config_sha256": "sha256:...",
  "instance_config_sha256": "sha256:...",
  "session_id": "ors_20260704_abc123",
  "launch_id": "orl_20260704_def456",
  "state": "active",
  "created_at": "2026-07-04T10:00:00Z",
  "updated_at": "2026-07-04T10:00:05Z",
  "client": "codex",
  "command": ["codex"],
  "herdr": {
    "workspace": "w1",
    "tab": "w1:t1",
    "pane": "w1:p2",
    "canonical_pane": "w1:p2",
    "agent_label": "reviewer-main",
    "agent_status": "idle"
  },
  "identity": {
    "source": "orbit_start_env",
    "verification": "identity_pending",
    "verification_reason": "herdr_caller_pane_proof_unavailable",
    "trusted_caller_proof": {
      "available": false,
      "provider": "herdr",
      "reason": "herdr_caller_pane_proof_unavailable"
    },
    "whoami_valid": true,
    "whoami_checked_at": "2026-07-04T10:00:00Z",
    "conflicts": []
  },
  "heartbeat": {
    "last_seen_at": "2026-07-04T10:00:05Z",
    "ttl_seconds": 30,
    "source": "orbit_runtime_register"
  }
}
```

持久化副本：

```text
.orbit/runtime/sessions/<session_id>.json
.orbit/runtime/instances/<instance>.json
```

`.orbit/runtime/instances/<instance>.json` 应指向该 instance 当前可信 session，并保存 replacement diagnostics。它不是 evidence，也不能进入版本化 task/gate history。

`state` 取值：

```text
pending
active
replaced
stale
conflict
```

`identity.verification` 取值：

```text
herdr_verified
manual_runtime
explicit_waiver
identity_pending
stale
replaced
```

`herdr_verified` 只能由 Orbit 通过不可伪造的 trusted caller-pane proof provider 产生；当前版本没有这个 provider，所以任何手写或旧 session file 中的 `herdr_verified` 都不能关闭 gate 或触发 direct dispatch。`manual_runtime` 可以保留手动 protocol 可用性，但不能用于 direct dispatch。`explicit_waiver` 只能由用户或 owner 显式接受风险后写入 evidence，不应伪装成 Herdr verified identity。

### Runtime instance file schema

`.orbit/runtime/instances/<instance>.json` 使用统一 schema，不直接写裸 replacement diagnostic，避免和 current session pointer 冲突：

```json
{
  "schema_version": "orbit-runtime-instance-v1",
  "instance": "reviewer-main",
  "role": "reviewer",
  "current_session_id": "ors_20260704_abc123",
  "current_state": "active",
  "updated_at": "2026-07-04T10:00:05Z",
  "previous_sessions": [
    {
      "session_id": "ors_old",
      "state": "replaced",
      "replaced_at": "2026-07-04T10:00:00Z",
      "reason": "user_forced_start_replace"
    }
  ],
  "ack": {
    "session_id": "ors_20260704_abc123",
    "pane": "w1:p2",
    "acknowledged_at": "2026-07-04T10:20:00Z",
    "acknowledged_by": {
      "instance": "lead-main",
      "role": "lead"
    },
    "reason": "owner_inspected_done_state"
  },
  "replacement_diagnostics": [
    {
      "schema_version": "orbit-start-replacement-v1",
      "replaced_at": "2026-07-04T10:00:00Z",
      "previous_binding": {
        "adapter": "herdr",
        "pane": "old-pane"
      },
      "new_binding": {
        "adapter": "herdr",
        "pane": "new-pane"
      },
      "risk": []
    }
  ]
}
```

现有 `orbit-start-replacement-v1` 内容应迁移为 `replacement_diagnostics[]` 条目。`--force` 保护逻辑必须读写这个统一文件，不能覆盖 current session pointer。

## 实施切片

### Slice 0: installer prerequisite

- Orbit installer 在报告安装成功前必须检查 `herdr`。
- 检查必须同时覆盖 `command -v herdr` 和 `herdr --version`。
- 缺少 Herdr 时安装应失败，并输出明确 remediation 和 Herdr 安装命令。
- README 安装流程必须把 Herdr 写成普通 Orbit runtime 使用的必需依赖，而不是“可选但推荐”。
- 如果保留 manual-only 安装模式，它必须显式开启，例如 `--manual-only` 或 `ORBIT_MANUAL_ONLY=1`，并在安装结果里说明 `orbit start` 自动 create/wake、Herdr direct dispatch 和 Herdr notice surfacing 都不可用。
- 增加 installer 测试：缺少 Herdr、Herdr 已安装、以及 manual-only 模式如果实现时的显式降级输出。

### Slice 1: runtime session files

- 新增 `.orbit/runtime/sessions/` schema helpers。
- 新增统一 `.orbit/runtime/instances/<instance>.json` schema：`orbit-runtime-instance-v1`。
- schema 必须同时容纳 `current_session_id`、`previous_sessions[]`、`replacement_diagnostics[]` 和 ack 状态。
- 将现有 `orbit-start-replacement-v1` 文件内容迁移到 `replacement_diagnostics[]`，不能覆盖 current session pointer。
- 新增 `orbit runtime register --json`。
- 当前版本不提供独立 heartbeat 子命令；不要在测试或用户文档中要求第一版历史命令。
- 新增 `orbit runtime ack-session INSTANCE --json`。
- 确保 `.orbit/runtime/` 被 ignore，且永远不被当成 evidence。

### Slice 2: start registration

- 生成 `ORBIT_SESSION_ID` / `ORBIT_LAUNCH_ID`。
- 通过 `herdr agent start --env` 传入 Orbit env。
- 写入 provisional session。
- `context_preflight.commands` 不应要求 `orbit runtime register --json` 作为 verified promotion 步骤。
- 所有 Orbit CLI 命令在 Herdr 环境内运行时最多 piggyback register diagnostics；没有独立 heartbeat 子命令。
- registration 成功前返回 `action: started_identity_pending` 和 `identity_verification: pending`。
- 拒绝 direct dispatch 到 pending sessions。

### Slice 3: liveness probe

- 合并 Herdr probe 和 runtime session verification。
- 明确 `HERDR_ENV` / `HERDR_PANE_ID` 只是 probe 输入，不是 verified proof。
- register diagnostics 必须由 Orbit 自己调用 Herdr probe 采集 pane、agent、cwd、client、session metadata；这些 probe 结果不是 trusted identity proof。
- 实现统一 on-demand resolver，供 `instances status`、`start`、`dispatch`、`evidence submit` 复用。
- 每次 resolver 都重新查询 Herdr 当前事实，不直接信任缓存 binding。
- 输出 `binding_resolution: current|repaired|stale|missing|ambiguous`。
- 添加无 binding 时的 discovery。
- 让 `instances status` 输出 `herdr_liveness`、`identity_verification`、`dispatch_ready`。
- `instances status` 默认不写 `.orbit/instances.yaml`；只有 `--repair-binding` 才写版本化 config。
- 保留当前 client/cwd checks 作为辅助证据，而不是 identity proof。

### Slice 4: dispatch gate

- 要求 live + verified + available。
- `available_needs_seen` 必须通过 `orbit runtime ack-session INSTANCE --json` ack 后才可继续。
- 让 `--pane` 显式 override 设置 `identity_verification: override`，但不得写 active session、evidence author identity 或 gate-closing identity。
- `--pane` JSON/TTY 输出必须包含 manual override risk。
- 保留 `--manual-payload` 作为 protocol-safe fallback。

### Slice 5: evidence session attribution

- 为 evidence submit/add 路径添加 runtime session attribution。
- 拒绝来自 stale/replaced/mismatched sessions 的 gate-closing review/test records。
- 支持 `manual_runtime` / `explicit_waiver` / `stale` / `replaced` 分类；`herdr_verified` 是未来 trusted proof provider 接入后的分类，当前版本必须 fail closed。
- manual Orbit protocol 的 `manual_runtime` evidence 可以参与 gate，但 audit/handoff 必须明确标注不是 Herdr-verified。
- 在 audit/handoff summaries 中暴露 session identity。

### Slice 6: Herdr workspace/session diagnostics

- 为 binding/status output 添加 Herdr named session 字段。
- 如果存储的 pane id 属于另一个 Herdr session namespace，fail closed。
- 让 `tools doctor` 输出当前本地 Herdr session、workspace、tab、pane 诊断。

### Slice 7: doctor and presentation integration

- 将 `herdr agent explain --json` 和 manifest status 加入 `orbit tools doctor --json`。
- 为 Orbit notice records 添加 best-effort Herdr notification delivery。

## 非目标

- 不重新引入 tmux/zellij/wezterm adapters。
- 不把 Herdr `done` 当成 Orbit task completion。
- 不从 pane title、Herdr display label、agent name 或自然语言 prompt 推断 role。
- 不要求 long-running Orbit daemon。
- 不让 Herdr 成为 task/evidence/gate semantics 的权威。
- 不默认安装成“没有 Herdr 但看起来可用”的半功能状态；manual-only 必须显式选择并清楚降级能力。

## 待定问题

1. stale session ttl 应按 client 定制，还是使用单一 project setting？
2. `ack-session` TTL 应按 project setting 配置，还是使用固定短 TTL？

## 决策摘要

当前 Herdr-only 方向是正确的，但结构上还不完整。缺失的不是另一个 adapter，而是一个 runtime contract，用来绑定：

```text
Orbit instance/role/session <-> Herdr workspace/tab/pane/agent <-> task/evidence authority
```

在这个 contract 建立之前，Orbit 只能证明某个 pane 里有 compatible coding agent，且 cwd 正确。它还不能证明该 agent 就是预期的 Orbit role participant。

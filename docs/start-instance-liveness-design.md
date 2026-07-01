# Orbit start force replacement design

本文记录 `orbit start` 的简化修复方案。目标不是引入复杂 heartbeat/lease 系统，而是让 `start` 在绑定状态不可信时停止假复用，并提示用户显式使用 `--force` 重新启动该 instance。

## Scope

这是 `start` 专项生命周期问题，不是整个 Orbit protocol 的 transport 问题。

不需要 runtime adapter 的命令：

- `whoami`
- `rules`
- `new-task`
- `evidence`
- `state`
- `wait-gate`
- `validate`
- `audit`
- 当前 `handoff`

需要 runtime adapter 的情况：

- `start` 要自动 wake/create 外部承载环境。
- `dispatch` 要把消息直接投递到某个 transport pane/session/job。

没有 adapter 的运行环境仍然可以手动运行 Orbit protocol。

## Problem

`orbit start INSTANCE` 现在会把 `.orbit/instances.yaml` 里的静态 binding/cache 当成实时状态。

问题配置形态：

```yaml
instances:
  coder:
    role_ref: coder
    command: omp
    transport:
      kind: local
      binding:
        pane: w3:p4
      health:
        last_heartbeat: "2026-06-30T11:53:13Z"
        actual_client: unknown
```

`transport.binding` 和 `transport.health` 只能说明上次记录过什么，不能证明当前 agent 还活着。`start` 不能因为它们存在就输出 `reuse`。

## Design

`start` 的默认行为：

1. 如果 Orbit 能明确确认当前 instance 已经有活的 agent，则 `reuse`。
2. 如果只有静态 binding/cache，或状态不可信，则不要自动 `reuse`。
3. 输出风险提示和下一步命令：`orbit start INSTANCE --force`。
4. 用户显式使用 `--force` 时，以这次新启动的 instance 为准，旧 binding/cache 在 Orbit 层标记为 replaced/stale。
5. 默认不 kill 旧外部进程；“断掉”指断开 Orbit 对旧 binding 的信任。杀进程必须是未来单独的显式破坏性操作。

This keeps the CLI simple: no interactive menu, no hidden default choice, no blocking prompt in CI.

## Warning output

当 `start` 发现不可信绑定且没有 `--force` 时，输出类似：

```text
Orbit instance has an unverified binding:
- instance: coder
- role: coder
- configured transport: local
- bound pane: w3:p4
- last health: 2026-06-30T11:53:13Z
- reason: binding/cache is not proof that the agent is still alive

No new agent was started.

To replace Orbit's binding and start a new coder, run:
  orbit start coder --force

Risk:
- The old external process may still exist.
- Orbit will trust the newly started coder as the current instance.
- This does not kill or clean up the old process.
- You may temporarily have two agents with the same Orbit instance/role.
- The old and new agents may both write evidence, gate leases, or loop state if the old one keeps running.
```

`--json` / non-TTY / CI 返回同样语义：

```json
{
  "action": "needs_force",
  "instance": "coder",
  "binding": "bound",
  "liveness": "not_alive",
  "liveness_source": "static_binding_cache",
  "liveness_reason": "binding_cache_unverified",
  "force_command": ["orbit", "start", "coder", "--force"],
  "risk": [
    {
      "code": "old_external_process_may_still_exist",
      "message": "Force does not kill the old external process; stop it manually if it is still running."
    },
    {
      "code": "duplicate_instance_agents_may_run_concurrently",
      "message": "Old and new agents with the same instance and role may run concurrently."
    },
    {
      "code": "old_and_new_agents_may_compete_for_orbit_state",
      "message": "Old and new agents may compete for evidence, gate leases, and loop state writes."
    },
    {
      "code": "orbit_binding_will_be_replaced",
      "message": "The new start replaces Orbit's current binding for this instance."
    }
  ]
}
```

## Force semantics

用户运行 `orbit start INSTANCE --force` 后：

- 这次启动的新 instance 成为 Orbit 当前可信 instance。
- 旧 `transport.binding` 不再用于 `reuse`。
- 旧 `transport.health` 可保留为 last-known diagnostic，但 replacement metadata 不写入 `instances.yaml`。
- 新启动成功后，写回新的 binding/health。
- 如果新启动失败，不要删除旧 binding；输出失败诊断和手动启动说明。

`instances.yaml` 只保留稳定配置和当前 binding：

```yaml
transport:
  kind: herdr
  binding:
    pane: new-pane
  health:
    last_heartbeat: "2026-07-01T02:10:00Z"
    actual_client: codex
```

Replacement history is runtime state and must be written outside versioned config:

```text
.orbit/runtime/instances/coder.json
```

Example runtime diagnostic:

```json
{
  "schema_version": "orbit-start-replacement-v1",
  "instance": "coder",
  "role": "coder",
  "replaced_at": "2026-07-01T02:10:00Z",
  "reason": "user_forced_start_replace",
  "previous_binding": {
    "kind": "local",
    "pane": "w3:p4",
    "last_heartbeat": "2026-06-30T11:53:13Z"
  },
  "new_binding": {
    "kind": "herdr",
    "pane": "new-pane"
  },
  "risk": [
    {
      "code": "duplicate_instance_agents_may_run_concurrently",
      "message": "Old and new agents with the same instance and role may run concurrently."
    }
  ]
}
```

`.orbit/runtime/` is per-checkout state and must be gitignored. Runtime replacement diagnostics are not evidence and must not be used to close gates.

## Start decision

目标控制流：

```text
load instance config
if no binding -> normal create/block policy
if binding is live-confirmed -> reuse
if binding is unverified/stale and !force -> needs_force
if binding is unverified/stale and force -> wake safe target, create external target, or local exec; write replacement diagnostic and new binding when available
```

当前可以 live-confirm 的范围很窄：

- Herdr transport 且 Herdr 能检测到目标 pane 上有 agent。
- 当前进程/环境能明确证明 identity 匹配。

不能 live-confirm 的状态都要求 `--force`，而不是走 `reuse`。

## Manual fallback

如果 `start` 不能自动启动目标 agent：

1. 打开你想承载 agent 的终端、tmux pane、zellij pane、wezterm pane、CI shell、远端 shell 或普通 shell。
2. 进入项目目录。
3. 运行：

   ```bash
   orbit start INSTANCE
   ```

   这会在当前 shell 里 local exec。Orbit 不会创建或管理外层终端环境。

4. 如果不使用 `orbit start`，就按 `.orbit/instances.yaml` 里的 command 手动启动，并设置身份：

   ```bash
   ORBIT_INSTANCE=lead ORBIT_ROLE=lead <command-from-.orbit/instances.yaml>
   ```

5. agent 启动后继续正常使用 Orbit protocol：`orbit whoami --json`、`orbit rules ...`、`orbit evidence ...`、`orbit validate`、`orbit audit`。

## User-managed policy

`management: user_managed` 仍然表示 Orbit 不能擅自创建缺失 instance。

`--force` is explicit user authorization for this one start:

- `--force` allows this start to replace Orbit's binding for the instance.
- `--force` does not grant permission to kill old processes.
- `--force` does not change future `management` policy.
- Without `--force`, non-live-confirmed bindings must stop with `needs_force`.
- `--force` accepts the risk that two agents with the same instance/role may run concurrently until the user stops the old one.
- `--force` does not make old evidence/gate/state writes invalid automatically; later validation/audit must still catch conflicting or stale writes.

## Force concurrency and writes

Forced replacement must be serialized per instance. Without this, two concurrent `orbit start coder --force` calls can both launch agents and race to write `instances.yaml`.

Required behavior:

- Use a per-instance lock, for example `.orbit/runtime/locks/start-coder.lock`.
- Hold the lock across: read current binding, launch replacement, write new binding, write runtime replacement diagnostic.
- Acquire the lock non-blocking. If it is already held, return `needs_attention` / `start_in_progress`; do not queue and launch a second replacement later.
- Write `instances.yaml` with existing Orbit atomic write helpers: temp file, fsync, rename, fsync directory.
- Do not write replacement history into `instances.yaml`; only write current stable binding/health.

The lock is not a long-term lease; it only protects the forced replacement critical section.

## Transport boundaries

不要从 handle 形状推断 transport：

```text
binding.pane == w3:p4 -> assume Herdr
```

transport 必须来自显式配置或 CLI option：

```yaml
transport:
  kind: herdr
```

没有 adapter 的运行环境只支持手动/当前 shell 路径。`orbit start lead` 如果运行在 tmux/zellij/wezterm pane 里，只是在当前 pane local exec，不代表 Orbit 管理该 runtime。

## Dispatch behavior

`dispatch` 是消息投递，不是 liveness 证明。

短期规则：

- `dispatch --transport herdr --pane PANE` 仍然按显式 pane 投递。
- 如果 dispatch 目标是 instance，且只有 stale/unverified binding，应返回 `manual_delivery_required` 或要求显式 pane，不能说已投递给活 agent。
- 不要让 dispatch 自动启动目标 instance。启动/替换属于 `start --force` 的职责。

## Code cleanup

要删掉或停用的 reuse 依据：

- `start_requires_reuse?` 只看 `instance_status.recommended_action == "reuse"`。
- 因为 `.orbit/instances.yaml transport.binding` 存在就返回 `reuse`。
- 因为 `.orbit/instances.yaml transport.health.last_heartbeat` 存在就返回 `reuse`。
- `binding_status: healthy` 作为 live-health 概念。

可以保留：

- Herdr `agent list`，只用于 Herdr live-confirm 或 wake/create diagnostics。
- Herdr `pane process-info` / `pane read`，只用于判断能否安全 wake。
- `run_herdr_start` / `run_herdr_wake` / `run_herdr_self_wake`，作为 Herdr start adapter。
- `dispatch --transport herdr`，作为显式消息投递。
- `tools detect/doctor` 的 Herdr 检查。

## Output contract

`orbit start --json` 在不可信绑定时应输出可测试字段：

```json
{
  "action": "needs_force",
  "instance": "coder",
  "binding": "bound",
  "liveness": "not_alive",
  "liveness_source": "static_binding_cache",
  "liveness_reason": "binding_cache_unverified",
  "force_command": ["orbit", "start", "coder", "--force"],
  "risk": [
    {
      "code": "duplicate_instance_agents_may_run_concurrently",
      "message": "Old and new agents with the same instance and role may run concurrently."
    }
  ]
}
```

强制启动并替换成功：

```json
{
  "action": "started",
  "replacement": ".orbit/runtime/instances/coder.json"
}
```

如果另一个 forced start 正在替换同一个 instance：

```json
{
  "action": "needs_attention",
  "reason": "start_in_progress",
  "liveness_reason": "another forced start is already replacing this instance"
}
```

## Implementation order

1. Add `--force` to `orbit start` args.
2. Stop static binding/cache from returning `reuse`.
3. When binding is unverified and `--force` is absent, return/print `needs_force` with risk text.
4. Add `.orbit/runtime/` gitignore/template handling for replacement diagnostics and locks.
5. Implement forced replacement path under non-blocking per-instance lock.
6. Write `instances.yaml` atomically and write previous binding only to `.orbit/runtime/instances/<name>.json`.
7. Add manual-start instructions.
8. Keep Herdr wake/create, but only for live-confirmed wake paths or forced replacement.
9. Update tests and README/help.

## Test plan

Required regressions:

1. `local` transport with `binding.pane` does not return `reuse`.
2. Stale `transport.health` does not return `reuse`.
3. TTY path prints `--force` instruction and risk warning.
4. Non-TTY/`--json` path returns `needs_force`.
5. Without `--force`, `.orbit/instances.yaml` is not modified.
6. `--force` starts a new instance and writes new binding.
7. `--force` writes previous binding diagnostics to `.orbit/runtime/instances/<name>.json`, not `instances.yaml`.
8. Failed forced replacement preserves previous binding.
9. Concurrent `--force` calls do not double-launch; one gets lock/start-in-progress.
10. `instances.yaml` writes use atomic write and never leave a partial YAML file.
11. TTY and JSON risk output include duplicate-agent and evidence/gate/state competition warnings.
12. Herdr detected live agent can still return `reuse`.
13. Herdr idle pane wake/replacement of unverified binding requires `--force`.
14. `dispatch --transport herdr --pane PANE` still works as explicit pane delivery.

## Non-goals

- No heartbeat/lease registry in the first fix.
- No daemon or background watcher.
- No automatic killing of old external processes.
- No interactive menu.
- No transport inference from pane id format.
- No claim that lack of a runtime adapter prevents normal Orbit protocol usage.

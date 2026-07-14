# Orbit × Herdr 真实 runtime 能力审计

- 审计日期：2026-07-14
- Orbit：0.1.11
- 本机 Herdr：0.7.1
- 上游参考：`upstream/herdr` 跟踪 `master`
- 结论：只能支持 `manual` 与 `automatic-preview`；production `automatic` 不成立

## 结论

Orbit 原先对 `herdr orbit-proof` 的依赖不是 Herdr 已公开能力，而是 Orbit 测试 fixture 自行实现的假想协议。更新 Orbit 或安装 agent skill 都不会让该 Herdr 命令出现。

真实 Herdr 可以可靠提供 pane start、list、read、process/state observation 和输入投递，但其公开接口没有认证“当前调用进程属于哪个 pane”的信任原语。Orbit 若仅凭环境变量、调用方传入的 pane id、agent 状态或 plugin context 签发 proof，同一用户下的其他进程也能伪造，因此不能把它们升级为 `herdr_verified`。

## 审计证据

| Surface | 已确认能力 | 身份限制 | Orbit 结论 |
| --- | --- | --- | --- |
| Herdr CLI | workspace/tab/pane/agent start、inspect、send、wait | `orbit-proof` 不存在 | 可作 preview adapter |
| Socket API | 0600 本地 socket；读写 pane/agent/server 状态 | 只隔离其他 OS 用户，不认证请求进程到 pane | 不能签发 caller identity |
| `pane.current` | 返回指定或当前活动 pane | `caller_pane_id`/`HERDR_PANE_ID` 由客户端提供 | 只能作观察 hint |
| Agent integrations | 上报 agent state 和原生 session reference | hook 使用环境中的 socket/pane id | 不能证明 Orbit role 授权 |
| Plugins | server 执行动作、事件 hook、提供 invocation context | context 表示选择/事件目标，不认证 Orbit CLI caller | 不能作为 proof provider |
| Pane process info | 服务端观察 shell/foreground process | 能证明 pane 中有什么，不能证明某次独立 socket 请求来自那里 | 可作 liveness/诊断输入 |

本机真实命令基线：

```text
$ orbit version
0.1.11

$ herdr --version
herdr 0.7.1

$ herdr orbit-proof status --json
unknown command: orbit-proof
```

源码核对重点：

- `upstream/herdr/src/api/server.rs`：API socket 使用用户级权限，但 request dispatch 不携带 caller-pane authentication。
- `upstream/herdr/src/cli/pane.rs`：`pane current` 从环境或 `--pane` 取得 caller pane。
- `upstream/herdr/src/app/api/panes.rs`：server 按请求里的 `caller_pane_id` 返回 pane。
- `upstream/herdr/src/integration/assets/`：integrations 使用环境变量上报 pane/session。
- `upstream/herdr/src/app/api/plugins/context.rs`：plugin context 来自活动/选择/event context，可合并调用方提供字段。

## 已实施修正

- production runtime 不再执行 `herdr orbit-proof ...`。
- capability truth source 在检测到 Herdr 时固定报告 `automatic-preview`。
- `verified_identity`、`direct_dispatch`、`trusted_proof_provider` 均报告 unavailable。
- runtime register 保持 pending/diagnostic，并附带明确的 `identity_boundary`。
- 删除 provider challenge、renewable attestation 和 `runtime refresh-session` 成功路径。
- 测试 fixture 即使伪造完整 `orbit-proof` 响应，也不能让 Orbit 进入 automatic。
- 旧 proof/session 不能恢复为可信状态。

## 测试分层

| 类型 | 允许证明什么 | 禁止声称什么 |
| --- | --- | --- |
| Fake Herdr unit/contract test | 参数解析、fail-closed、状态转换、不会误报能力 | 真实 Herdr integration、production automatic |
| Real Herdr preview dogfood | start/list/read、pending identity、manual payload、生命周期诊断 | verified identity、dispatch-ready、可信 direct dispatch |
| Future real automatic E2E | 仅在上游出现 authenticated caller assertion 后定义 | 在前置能力缺失时不得创建绿色替身 |

## 真实 dogfood 的预期 verdict

本轮真实测试不以“automatic 必须成功”为预设。正确预期是：

- manual workflow 可以完成 task/evidence/gate/audit/handoff；
- Herdr 可以启动和观察独立 coder/reviewer/tester pane；
- runtime identity 保持 pending，`dispatch_ready` 保持 false；
- manual payload 是权威投递路径；
- automatic 的最终 verdict 为 `BLOCKED_BY_UPSTREAM_CAPABILITY`，而不是产品 PASS。

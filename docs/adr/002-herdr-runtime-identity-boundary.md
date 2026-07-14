# ADR-002：Herdr runtime identity 能力边界

- 状态：Accepted
- 日期：2026-07-14
- 决策范围：Orbit runtime identity、capability reporting、direct dispatch
- 取代：ADR-001 中关于 provider proof refresh 的结论

## 背景

Orbit 曾在自身代码和测试 fixture 中定义 `herdr orbit-proof status/prove/verify`，并据此实现 nonce、短 TTL、attestation、refresh 和 `dispatch_ready`。Herdr 是独立项目，Orbit 只能消费 Herdr 已公开的能力，不能把 Orbit 私有协议当作 Herdr 的既有接口。

真实环境使用 Herdr 0.7.1。仓库同时通过 `upstream/herdr` submodule 跟踪上游 `master`，用于核对最新公开实现。

## 已确认事实

- Herdr 0.7.1 对 `herdr orbit-proof status --json` 返回 `unknown command`。
- Herdr 公开 CLI/socket API 可以创建、观察和控制 workspace、tab、pane、agent。
- socket 文件权限限制为当前 OS 用户，但请求没有把连接进程认证并绑定到某个 pane。
- `pane.current` 的 `caller_pane_id` 来自调用方参数或 `HERDR_PANE_ID`，调用方可以自行指定。
- agent integrations 使用 `HERDR_SOCKET_PATH` 和 `HERDR_PANE_ID` 上报状态/session，属于状态观测，不是不可伪造的 Orbit role identity。
- plugin invocation context 表示活动、选择或事件关联 pane，不证明发起 Orbit CLI 的进程属于该 pane。

因此，Herdr 可以证明“服务端存在这个 pane，并观察到某些进程/状态”，但不能证明“这次 Orbit 命令由这个 pane 内受授权的 role 发起”。

## 决策

1. Orbit 不再调用或探测任何 Herdr 专用 `orbit-proof` 命令。
2. 有 Herdr 时 runtime mode 固定为 `automatic-preview`；无 Herdr 时为 `manual`。
3. `automatic-preview` 只允许 pane start/inspect，不产生 `herdr_verified`、`dispatch_ready: true` 或可信 direct dispatch。
4. `orbit runtime register` 只记录 diagnostic/pending identity；删除 provider challenge 和 `refresh-session` 成功路径。
5. 旧 `herdr_verified`、proof 或 attestation 文件一律 fail closed，不能恢复可信状态。
6. 模拟 Herdr/provider 只能做内部合约或负向测试，不得命名为真实 provider E2E，也不得作为 production automatic 证据。
7. 权威任务投递使用 manual payload；pane id、环境变量、agent 状态和 plugin context 都不能替代身份信任根。

## 未来重新启用 automatic 的必要条件

Herdr 必须先独立公开一种 server-owned assertion，至少满足：

- 由 Herdr server 认证发起请求的进程，而不是信任调用方填写 pane id；
- 绑定 live pane、session 和调用进程生命周期；
- assertion 不可由同用户下任意普通进程自行签发或重放；
- Orbit 可以独立向 Herdr server 复核 assertion；
- 在真实 Herdr binary 上完成 `start → identity → dispatch → evidence → gate` E2E。

在这些条件发生前，Orbit 不保留隐藏或测试开关来升级到 `automatic`。

## 后果

- 产品能力声明与真实 Herdr 保持一致，不再要求用户寻找不存在的命令。
- direct dispatch 和 verified runtime identity 暂不可用；manual protocol 是稳定权威路径。
- automatic fixture 原有的绿色结果失去“集成已完成”的含义，相关文档和指标必须纠正。
- Herdr submodule 仅供对比和参考，不是 Orbit 发布包的运行依赖，也不授权修改 Herdr。

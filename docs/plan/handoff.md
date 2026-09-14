# Orbit 当前交接

2026-09-14 用户同意先提交推送 OpenCode 0.3.0，再完成 OMP 接入。0.3.0 已以 `8b5de29` 推送 main；OMP 已完成，当前源码与本机安装均为 **0.4.0**，用户已要求提交并推送本轮 OMP 成果，提交及远端同步状态以 Git 为准。不启动新 Goal，不打标签、不发布，不自动扩展 pi／Kimi；被忽略的外部交接包仍留在本地。

## 当前怎么用

- **OMP**：项目目录直接运行 `omp`。可继续使用原生 `--resume SESSION_ID`、`--model provider/id`、`--approval-mode` 和 profile。安装后的扩展通过原生 `xd://orbit` 提供工具；Agent 读取设备说明后按原生协议调用，无需用户填写内部 ID 或端口。
- **OpenCode**：直接运行 `opencode`，保留原生恢复、模型和权限参数。
- **Codex**：运行 `orbit codex` 或 `orbit codex resume SESSION_ID`；普通 embedded Codex 仍不自动热接入。
- Root 就是当前负责用户整项任务的 Agent，不另建、不替换。需要成员的执行任务先接入再 delegate；其他合适的多步骤工作由共用 skill 主动判断，讨论和简单独立修改通常不启动。
- 成员与 Root 同宿主。OMP 沿用 Root 模型、thinking、项目及有效权限，只开放 Root 当前启用的基础编码工具，不复制扩展、MCP 或再次派发。OpenCode 沿用 Root 模型、variant、Agent 和权限；Codex 默认沿用检查模型与工作区写入沙箱。均由 Root 核验集成结果。
- **检查者仍需要 Codex**。检查模型优先 `ORBIT_REVIEW_MODEL`；OMP／OpenCode 默认从 Codex config.toml 顶层读取，使用 Codex profile 时显式指定。已实测的执行模型为 `opencode-go/deepseek-v4.1-flash`，不要与 V4、Zen 或直連混用。

本机安装目录 `~/.local/share/orbit/orbit`，CLI `~/.local/bin/orbit`。安装器统一管理 Codex skill、OpenCode 插件和 skill、OMP 扩展和 skill。OMP 采用 `PI_CODING_AGENT_DIR`、其次 `OMP_PROFILE` 对应的 agent 目录，默认 `~/.omp/agent`；只对所选 profile 生效。OpenCode 遵循 `OPENCODE_CONFIG_DIR`。模型、权限配置未被改写。安装前已经打开的会话须按原生方式退出并恢复以加载新版，安装不是运行中热更新。

## 本轮验证

完整数据见 [OMP 运行验收](../reference/omp-runtime-acceptance-20260914.json)，保留真实失败与修正，不以接线测试代替实际运行。

- 普通 OMP 18.1.16 中，用户要求未点名 Orbit，Agent 自主启动并保存原文和 requirements.md；一个已登记的 Go／V4.1 成员完成验证，结果回到原 Root 并被集成。
- Root 与成员完成后受控移除 USAGE.md，独立 Codex 检查发现遗漏，同一 Root 补回；5 次检查中 3 次过期弃用，最终 complete。内部纠正与回报未混入用户补充要求。
- 原生 Esc 中断，Root／成员及各自子进程共 4 个 PID 全部退出，心跳停止，任务 paused。
- 原生 --resume 恢复同一会话，再运行两支原生后台任务；正常退出界面后 4 个 PID、任务进程和私有 socket 全部收尾，任务 paused。两条停止验收均未调用检查模型。
- 既有全套回归、OMP 接线与实际后台任务结算／切换失败重试测试、四条安装更新卸载路径、skill／版本校验通过。独立只读核查与针对性复核完成，无剩余已识别阻断。
- 本机更新到 0.4.0；在没有项目扩展的普通 OMP 中观察到全局 Orbit 扩展与新版 skill，CLI／三个宿主的入口同版。原生模型和权限配置内容保持一致。

实际运行发现并修正两处：小任务需要成员时也应先接入；followUp 被 hub wait 挡住，改用原生 steer，避免回报延迟。独立核查补齐切换前停止确认：未确认则取消切换，保留原连接供重试。

首次未成功闭环的任务在取消一个正在执行的 Codex 检查进程组时收到 EPERM，记录保留 stop_unconfirmed；其 Root／成员停止已确认，事后核对登记检查 PID 和进程组均不存在。未把这一失败改写成通过。后续完整流程和两条停止验收分别保留自己的结果。

本轮自有宿主、执行及检查进程已结束，临时控制 socket 已关闭。隔离夹具、原生历史、检查副本及评审日志保留，位置见验收数据。初估 2–4 小时，未连续记录整次实施时长和套餐扣量。成功纠偏任务记录 466223 检查 tokens（包含缓存口径）；说明几次过期检查的成本，不据最小验收宣称普遍节省额度。

## 后续边界

下一种宿主为 pi，随后 Kimi Code；Grok、dsh、Cursor Agent 低优先级，仅在官方方案合适时推进。本轮完成不自动授权下一宿主，不扩展混合宿主成员、自动恢复、Root 替换或需求讨论管理。

[OpenCode 正式验收](../reference/opencode-runtime-acceptance-20260914.json)、[Codex 日常验收](../reference/user-flow-acceptance-20260914.json) 与 [底层验收](../reference/orbit-runtime-acceptance-20260914.md) 保留为既有证据。当前语义见 [运行合同](../../contracts/task-runtime.md) 与 [ADR-007](../adr/007-task-runtime-refactor.md)，进度见 [当前计划](vision-completion-plan.md)。旧阶段和 upstream 不再是待办；旧 0.1.15 资料仍在 `~/.local/share/orbit/retired-0.1.15-20260914`，没有兼容执行路径。

# Orbit 当前交接

2026-09-14 用户要求“继续，完成这个需求，不要我继续追问”，本轮交付 OpenCode 正式接入及日常完整流程。当前源码版本 **0.3.0**。本轮未启动新 Goal。用户随后同意先提交推送 0.3.0，再完成 OMP 接入；不打标签、不发布，保留被忽略的本地外部交接包。

## 当前怎么用

- **OpenCode**：安装后在项目目录直接运行 `opencode`，继续使用原生模型、权限和恢复参数。插件自动提供当前会话的 Orbit 工具，无需用户填写端口或内部 ID。安装前已经打开的会话需按原生方式退出并恢复，才能加载插件。
- **Codex**：继续运行 `orbit codex`，也可 `orbit codex resume SESSION_ID`，模型与权限参数沿用原生入口。普通 embedded Codex 不自动热接入。
- 对合适的多步骤执行要求，Agent 根据共用 skill 主动调用；讨论、解释和简单局部修改通常不启动。Root 就是当前负责整项任务的 Agent，不另建、不自动替换。
- `delegate` 创建同宿主成员。OpenCode 成员默认沿用 Root 的 provider/model、variant、原生 Agent 与权限；Codex 成员默认使用检查模型和工作区写入沙箱。尚不支持混合宿主成员。
- 检查者与裁定者当前仍走 Codex。OpenCode 执行已实测 `opencode-go/deepseek-v4.1-flash`；检查模型为 `ORBIT_REVIEW_MODEL` 或本机 Codex config.toml 顶层模型。不要把 V4 与 V4.1、Go 与 Zen／直连混用，也不要求用户修改当前可用账户设置。

本机已更新至 **0.3.0**，用 `~/.local/share/orbit/orbit` 管理，CLI 为 `~/.local/bin/orbit`。安装器同时管理 Codex skill、OpenCode 插件和 skill，使用同一个版本链接；尊重原生 OPENCODE_CONFIG_DIR，默认 `~/.config/opencode`，不改写模型或凭据。安装状态与源码来源用 `orbit version --json` 核对。旧 0.1.15 资料仍保留在 `~/.local/share/orbit/retired-0.1.15-20260914`，没有兼容执行路径。

## 本轮实际验证

正式运行事实见 [OpenCode 验收数据](../reference/opencode-runtime-acceptance-20260914.json)。这是安装后的原生插件与 TaskRuntime，不再是实验控制脚本。

- 普通无端口 OpenCode 中，用户未点名 Orbit，Agent 主动启动；原文和 requirements.md 依据保存，登记一个 Go／V4.1 成员，回传结果并由同一 Root 集成。
- Root 与成员完成后受控删除 USAGE.md，独立 Codex 检查发现遗漏，原 Root 收到纠正后补齐；4 次检查中 2 次过期并正确弃用，最终 complete。内部回报与纠正未被误存为用户新要求。
- 普通 TUI 两次物理 Esc 中断后，Root、成员及各自子进程共 4 个 PID 全部退出，心跳停止；原文、会话与产物保留。
- 原生 `--session` 恢复同一会话后再次运行两支心跳，正常退出界面也收尾全部 4 个 PID、任务进程与私有 socket。
- 既有快照、运行、Codex、MCP 回归，新 OpenCode 原文／归属／模型／用户修改／成员／中断接线测试，以及四条安装更新卸载路径通过；skill 和包内容检查通过。
- 真实入口发现并修正了 `.mjs` 不被自动发现的问题，安装链接采用 `.js`；工具回包补充结束当前轮次的指引，减少为等待检查而反复查询。独立核查提出的中断竞态和自定义配置目录问题已修正，针对性复核确认无剩余阻断；最后改动后全套既有回归再次通过。

测试宿主和执行进程已结束。隔离夹具、原生会话、检查副本和只读评审日志保留，路径见验收数据。最初估计 2–4 小时仅作参考，整次实现未连续计时；可得检查与原生用量分别记录，整次账单／套餐扣量未知，不据最小验收宣称普遍节约额度。

## 后续边界

本轮只接 OpenCode Root 与成员，检查者仍为 Codex；不扩展供应商组合矩阵、自动恢复、Root 替换或需求讨论管理。下一顺序仍是 OMP、pi、Kimi Code；Grok、dsh、Cursor Agent 低优先级，只在官方方案合适时推进。本轮完成不自动授权下一种宿主。

更早的 [Codex 日常验收](../reference/user-flow-acceptance-20260914.json)、[底层验收](../reference/orbit-runtime-acceptance-20260914.md) 和 [OpenCode 最小实验](../reference/opencode-probe-20260914.json) 保留为历史证据，不机械重做。旧协议、upstream 子模块与旧阶段均不再是待办。语义见 [运行合同](../../contracts/task-runtime.md) 与 [ADR-007](../adr/007-task-runtime-refactor.md)，进度见 [当前计划](vision-completion-plan.md)。

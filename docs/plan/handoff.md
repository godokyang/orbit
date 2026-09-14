# Orbit 当前交接

2026-09-14 最新授权“列计划，把整个流程跑通”已完成日常入口、协作控制与固定验收。计划见 [日常使用交付计划](user-experience-plan.md)，语义见 [ADR-007](../adr/007-task-runtime-refactor.md) 和 [任务运行合同](../../contracts/task-runtime.md)。未启动新 Goal，未发布；用户随后明确授权提交并推送本轮成果。被忽略的本地外部资料继续保留，不进入提交。

## 当前怎么用

本机 `~/.local/bin/orbit` 已切换至 0.2.0，CLI 和 `~/.codex/skills/orbit` 指向同一受管理安装，运行目录为 `~/.local/share/orbit/orbit`。旧 0.1.15 文件及旧命令包装归档在 `~/.local/share/orbit/retired-0.1.15-20260914`，退出 PATH，无兼容执行路径。更新用本仓 `sh install.sh`；版本来源用 `orbit version --json` 核对，当前为本地 dirty 工作树而非已发布提交。

用户在目标项目终端运行 `orbit codex`，正常给出要求；合适任务由 skill 主动接入。普通终端、tmux、Herdr 使用同一入口。既有 Codex 模型配置继续使用，可另设 ORBIT_REVIEW_MODEL。入口只给自身 MCP 工具配置批准，不修改全局 Codex 配置或扩大 shell 沙箱。

当前开发 Root 未迁移，也没有被替换。已经打开的普通嵌入式会话不能假装热接入；用户明确停止工作后可以 `orbit codex resume SESSION_ID`，本轮用同一夹具会话验证了恢复和原文保留。其他供应商和未登记外部 Agent 不属于已控制范围。

## 本轮完成与验证

- 用户只说按 requirements.md 实现：新项目中的 Agent 主动发现 skill，真实连接、保存原文和依据、继续实现。
- 受控移除要求中的 USAGE.md 后，独立检查指出缺失，原 Root 补回并最终 complete；4 次检查中 2 次过期。无 Git 项目不采集常见依赖目录。
- 一个受控成员完成结果回传与 Root 集成，再复用执行后台任务；用户新要求同步至成员。原生 ESC 后 Root 与成员的两个 OS 心跳 PID 均退出，原生后台列表为空，状态 paused，原文、会话和产物保留。
- tmux 与 Herdr 恢复同一个夹具会话，未启动新的模型轮次；入口与归属核对通过。自建 Herdr pane 和 tmux 测试服务已移除。
- 修复停止队列重新唤起、停止信号优先级、观察错误后遗留成员、退出任务拒绝显式停止、旧检查停止错误无法重新核实等问题。未绑定成功的会话不会被错误清理路径停止。
- 复用本项目已有 OpenCode / DeepSeek V4.1 Flash 做只读独立核查，发现的停止路径问题已修复并针对性复核；没有扩大成异常矩阵或再启动团队。
- 相关回归、官方 MCP SDK 的实际 CLI 投递与归属测试、四条隔离安装路径、skill 校验通过。原始事实与用量在 [本轮验收数据](../reference/user-flow-acceptance-20260914.json)，更早的底层验收保留于 [原记录](../reference/orbit-runtime-acceptance-20260914.md)。

## 后续边界

本轮估计 3–6 小时仅作参考；完整任务费用未知，验收数据分别保留输入、缓存、输出计数。没有以一次实验证明普遍省额度。新功能按真实使用需要再定，不机械续做旧阶段、不建设 Root 自动替换／恢复、不扩成多供应商平台。

首次源码重构、历史文档清理、安装更新与版本控制已完成；旧协议和 upstream 子模块不再是待办。用户已明确授权本轮提交与推送，执行结果以 Git 为准；npm 发布、标签和外部项目修改不在本轮范围内。

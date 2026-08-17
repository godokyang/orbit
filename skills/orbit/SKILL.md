---
name: orbit
description: 用于 AI agent 在项目中感知或执行 Orbit v2 工作流：发现 .orbit/protocol.yaml（orbit-v2 epoch marker）后进入 Orbit-aware 模式；当目标明确且进入实现、评审、测试、验收或交接时，再调用 orbit v2 CLI 建立受控的 task/evidence/gate 闭环。v1 runtime 已删除；本 skill 当前只覆盖 v2 最小 CLI 路径，完整 v2 运行时文档重写进行中。
metadata:
  short-description: Orbit v2 受控任务闭环
---

# Orbit（v2）

Orbit 是面向 AI agent 的任务闭环协议。它把「做过动作」和「结果已被证明」分开：每个受控步骤是一条 provider-verified 的持久事务，完成判定来自派生的 AggregateOutcome，而不是 agent 的自我报告。

> **状态（2026-08-17）**：v1 runtime 已删除。当前唯一入口是 v2 CLI。v1 长文档已归档到 `docs/history/v1-runtime/`。阶段 G（规则库）已交付；下一阶段见 `docs/plan/handoff.md`。以本文与 `orbit v2 --help` 为准。

## 触发边界

发现 `.orbit/protocol.yaml`（v2 epoch marker）、用户明确提到 Orbit，或当前任务进入非平凡的实现、评审、测试、验收时，进入 Orbit-aware 模式。

只有目标、范围和验收标准已经足够明确，且工作正式进入执行或独立验证时，才启动正式闭环。需求澄清、方案讨论和探索性结对只保持 aware：不 init、不建 task、不推进 gate。

仓库没有 v2 marker 且用户未要求 Orbit 时不自动启用。**注意**：`.orbit/` 目录存在 ≠ v2 项目——v1 数据目录（`.orbit/tasks/`、`.orbit/evidence/` 等）在 v2 下是 mixed-epoch 状态，`orbit v2 init` 会正确拒绝。

## v2 最短闭环

CLI 可用时由 agent 自己执行：

1. `orbit v2 init <project_id>`——一次性建立 protocol root + genesis policy + 本地 provider 密钥（`.orbit/local-provider.json`，丢失即项目不可验证，须自行备份）。
2. 写 task 定义 YAML（goal + units），`orbit v2 task start <task_id> --def FILE` 创建 TaskRevision 与 lead control。
3. `orbit v2 dispatch --task ID --role implementer` 派发实现 attempt（默认钉四条任务规则 + 共享升格格式；显式 `--rule` 仍优先）；完成后 `orbit v2 evidence submit --task ID --proposal FILE` 提交 evidence。
4. `orbit v2 dispatch --task ID --role reviewer` 派发独立评审 attempt（继承 subject 已记录的规则字节，再叠 `rules/review.md`；独立性由 runtime identity 机械保证），评审先 `evidence submit` 提交 evaluator submission。
5. `orbit v2 gate submit --task ID --def FILE` 提交 GateEvaluation；verdict fail 可携带 Finding。
6. 有 Finding 时：提交 follow-up evaluation（`gate submit` 第二次，自动 supersede）后 `orbit v2 finding resolve --task ID --def FILE`。
7. `orbit v2 complete --task ID` 派生 AggregateOutcome：全部 gate 通过且无未决 blocking finding 时 `closed: true`（退出码 0）；否则显式列出未满足项（退出码 1）。
8. `orbit v2 status [--task ID]` 只读查看。

命名空间前缀 `v2` 可省略（`orbit init` 与 `orbit v2 init` 等价；该双拼法是未决项，最终命令面待定）。

## v2 语义要点

- **task 是协作单位**：一个 task 一个 `task_id`，对应一个 Git branch/worktree；存储在 `.orbit/task-scopes/<task_id>/` 下，不同 task 路径天然隔离。
- **一切受控写入需要 provider receipt**：本地 provider 是一致性机制而非安全边界（信任根 = 本地机器用户）。
- **完成不可自宣**：`complete` 是只读派生；未决 finding、stale evaluation、缺 evidence 都会让 gate 保持 open 并 fail closed。
- **review/test 独立性是结构约束**：GateEvaluation 必须引用独立评估者 attempt，实现者不能自评通过。

## 停止与升级

marker 缺失/epoch 不匹配、密钥文件丢失、规则文件 digest 不匹配（说明规则被改动过）、未决 blocking finding 需要 adjudication 时停止并请求用户决策。缺 verdict 或真实路径未覆盖时默认 fail。

初始化模板：`assets/templates/` 下的模板均为 v1 schema（已停用，文件名带 `.v1-deprecated`），v2 输入文件格式见各命令 `--help` 与本文示例。

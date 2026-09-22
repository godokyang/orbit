# Orbit 文档入口

当前源码版本文字：**0.6.12**。本文说明怎么用、为什么这样设计、怎么开发，以及实际验证到哪里。已结束的工单、旧协议和重复快照通过 Git 查阅，不再作为执行队列。

| 要解决的问题 | 阅读入口 |
| --- | --- |
| 怎么安装和开始任务 | [仓库 README](../README.md) |
| 自定义安装、skill 管理和 CLI 参数 | [进阶使用参考](reference/usage-reference.md) |
| Agent 何时自行调用 Orbit | [Orbit skill](../skills/orbit/SKILL.md) |
| 如何在隔离项目真实验收 Orbit | [Orbit 开发专用真实验收 skill](../.agents/skills/orbit-real-acceptance/SKILL.md)、[真实验收记录](reference/orbit-optimization-acceptance-plan-20260922.md) |
| Root 如何创建成员、使用 Herdr 和收尾 | [执行 Agent 协作说明](../skills/orbit/references/agent-collaboration.md) |
| 各角色怎么选模型 | [模型建议](../skills/orbit/references/model-selection.md) |
| 为什么采用当前设计 | [ADR-007](adr/007-task-runtime-refactor.md) |
| 程序和模型各负责什么、何时完成或停止 | [任务运行合同](../contracts/task-runtime.md) |
| 独立检查返回什么 | [检查结果 schema](../contracts/check-result.schema.json) |
| 开发本仓要遵守什么 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md) |
| 当前做到哪里、还有什么工作 | [交接](plan/handoff.md)、[执行协作与检查回路整体调优计划](plan/orbit-execution-review-optimization.md)、[JEV 委派判断专项计划](plan/jev-delegation-optimization.md)、[用户结果补齐计划](plan/user-outcome-completion-plan.md)、[当前计划](plan/vision-completion-plan.md) |
| 哪些能力尚不具备 | [当前限制](plan/debt-ledger.md) |
| 最新项目检查发现什么 | [用户结果独立审查及复核](reference/project-review-20260918.md)、[角色、协作与运行边界检查](reference/project-review-20260914.md) |
| 真实任务中的 Orbit 与 JEV 表现 | [Zeen Login 使用复盘与 JEV 证据](reference/zeen-login-orbit-experience-20260922.md) |
| 普通终端和现有会话如何落地、有哪些现成方案 | [用户流程交付计划](plan/user-experience-plan.md)、[现成方案调研](reference/existing-orchestrators-20260914.md) |
| 实际验收证明了什么 | [检查回路与 Jev 实际验证](reference/check-loop-acceptance-20260918.md)、[跨宿主成员验收](reference/cross-host-member-acceptance-20260918.md)、[Jev 调度运行验收](reference/jev-runtime-acceptance-20260918.md)、[底层真实验收](reference/orbit-runtime-acceptance-20260914.md)、[Codex 日常流程验收](reference/user-flow-acceptance-20260914.json)、[OpenCode 正式验收](reference/opencode-runtime-acceptance-20260914.json)、[OMP 正式验收](reference/omp-runtime-acceptance-20260914.json) |
| 优化后的真实路径怎么验收、已经跑到哪里 | [优化真实验收记录](reference/orbit-optimization-acceptance-plan-20260922.md) |
| 过去哪些失误值得记住 | [工程经验](reference/engineering-lessons.md) |
| Codex 如何加载项目规范 | [按需阅读的说明](reference/codex-agents-md-loading.md) |

## 各类文档的职责

- `contracts/` 与 ADR 定义当前产品语义；修改设计先改这里，不通过开发规范绕过产品行为。工作区绑定、Codex 启动时的 `TYPESAFE_API_KEY` 名称传递、JEV 候选分／最终 decision／持久 hint、委派 basis、产物与过程检查分开的 freshness、observation 去重、finding 绑定、终检收尾和 status 分层已写入合同。绑定冲突的自动检测与暂停、用新 finding id 表达的语义同义问题仍未具备；真实路径按验收记录区分已跑与未跑。
- 根 `AGENTS.md` 与 `docs/agents/` 约束开发 Orbit 的 Agent，不产生产品运行事实。
- `docs/plan/` 保存当前状态、范围与已知限制；已完成的工作不保留为待办，不复制合同正文。
- `docs/reference/` 保存验证事实、经验与参考资料，不独立增加验收或授权要求。

专项角色规则在 `skills/orbit/assets/rule-library/` 维护，按当前动作加载，不复制到本目录。使用和开发 Orbit 所需的说明均在本仓；外部参考资料按需读取，外部项目规范不全局安装。

## 历史怎么查

需要溯源时使用 `git log --all -- <路径>`，再用 `git show <提交>:<路径>` 读取当时正文。历史描述不作为现在时指令。失效文档在结论已归入现行正文后可删除，并同步清理引用；不为了归档再复制一份。

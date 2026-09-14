# Orbit 文档入口

当前文档只说明怎么用、为什么这样设计、怎么开发，以及实际验证到哪里。已结束的工单、旧协议和重复快照通过 Git 查阅，不再作为执行队列。

| 要解决的问题 | 阅读入口 |
| --- | --- |
| 怎么安装和开始任务 | [仓库 README](../README.md) |
| Agent 何时自行调用 Orbit | [Orbit skill](../skills/orbit/SKILL.md) |
| Root 如何创建成员、使用 Herdr 和收尾 | [执行 Agent 协作说明](../skills/orbit/references/agent-collaboration.md) |
| 各角色怎么选模型 | [模型建议](../skills/orbit/references/model-selection.md) |
| 为什么采用当前设计 | [ADR-007](adr/007-task-runtime-refactor.md) |
| 程序和模型各负责什么、何时完成或停止 | [任务运行合同](../contracts/task-runtime.md) |
| 独立检查返回什么 | [检查结果 schema](../contracts/check-result.schema.json) |
| 开发本仓要遵守什么 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md) |
| 当前做到哪里、还有什么工作 | [交接](plan/handoff.md)、[当前计划](plan/vision-completion-plan.md) |
| 哪些能力尚不具备 | [当前限制](plan/debt-ledger.md) |
| 最新项目检查发现什么 | [角色、协作与运行边界检查](reference/project-review-20260914.md) |
| 普通终端和现有会话如何落地、有哪些现成方案 | [用户流程交付计划](plan/user-experience-plan.md)、[现成方案调研](reference/existing-orchestrators-20260914.md) |
| 实际验收证明了什么 | [底层真实验收](reference/orbit-runtime-acceptance-20260914.md)、[日常流程验收数据](reference/user-flow-acceptance-20260914.json) |
| 过去哪些失误值得记住 | [工程经验](reference/engineering-lessons.md) |
| Codex 如何加载项目规范 | [按需阅读的说明](reference/codex-agents-md-loading.md) |

## 各类文档的职责

- `contracts/` 与 ADR 定义当前产品语义；修改设计先改这里，不通过开发规范绕过产品行为。
- 根 `AGENTS.md` 与 `docs/agents/` 约束开发 Orbit 的 Agent，不产生产品运行事实。
- `docs/plan/` 保存当前状态、范围与已知限制；已完成的工作不保留为待办，不复制合同正文。
- `docs/reference/` 保存验证事实、经验与参考资料，不独立增加验收或授权要求。

专项角色规则在 `skills/orbit/assets/rule-library/` 维护，按当前动作加载，不复制到本目录。使用和开发 Orbit 所需的说明均在本仓；外部参考资料按需读取，外部项目规范不全局安装。

## 历史怎么查

需要溯源时使用 `git log --all -- <路径>`，再用 `git show <提交>:<路径>` 读取当时正文。历史描述不作为现在时指令。失效文档在结论已归入现行正文后可删除，并同步清理引用；不为了归档再复制一份。

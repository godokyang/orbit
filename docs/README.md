# Orbit 文档入口

文档分清三件事：当前产品行为、认可但尚未实现的目标、特定构建的历史证据。源码版本从 `package.json` 读取；用户安装版须核对 `orbit version --json`，不能由源码或旧验收报告推断。

## 当前阅读入口

| 需要了解什么 | 权威入口与边界 |
| --- | --- |
| 安装和使用 | [README](../README.md)、[进阶使用参考](reference/usage-reference.md)；只说明已接线行为 |
| 当前任务、模型、检查、完成与停止语义 | [任务运行合同](../contracts/task-runtime.md)、[检查结果 schema](../contracts/check-result.schema.json)、[ADR-008](adr/008-omp-native-collaboration-base.md)、[ADR-009](adr/009-user-selected-model-pool.md) |
| 开发纪律、范围与验证方式 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md)；这些文件不产生产品运行事实 |
| 当前源码交付状态和证据边界 | [交接](plan/handoff.md)、[当前限制](plan/debt-ledger.md) |
| 原混合模型交付目标（54 项＋W1–W10）当前收口 | [完成记录](reference/mixed-model-delivery-completion-20261001.md)；逐项判定沿 Root 审计，历史正文不重写 |
| 有限顶级模型资源下的产品方向 | 用户认可的[混合模型交付主方案](plan/mixed-model-delivery-proposal.md)；其中目标不等于当前能力 |
| 已实现、需要调整和需要删除的内容 | [逐项代码审计](plan/mixed-model-delivery-code-audit.md)；每项对应主方案条款 |
| 推进顺序 | [当前计划](plan/vision-completion-plan.md)；引用主方案和审计，不再复制旧实施队列 |
| 可选 OpenRouter 设置与覆盖 | [使用说明](reference/usage-reference.md#openrouter-模型概述自愿启用)、[映射来源审计](reference/openrouter-model-mapping-audit.md)；模型版本对应不证明实际 OMP 计费路由 |
| 如何做真实模型验收 | [专用验收 skill](../.agents/skills/orbit-real-acceptance/SKILL.md)；确定性测试不能替代真实闭环 |

## 历史证据与研究

`reference/` 中带日期的报告与 JSON 是特定构建、配置或调查的记录。正文中的“当前”“本轮”和授权规则均按记录日期理解，不指导现行执行；失败、未测分支及组合证据例外继续保留。无日期的使用参考和工程经验各有其明确用途，不作为额外产品合同。

| 记录 | 可以证明的范围 |
| --- | --- |
| [Zeen 体验验收](reference/zeen-orbit-experience-acceptance-20260928.md)及[用户反馈](reference/zeen-mobile-ui-orbit-user-feedback-20260928.md) | 各冻结构建的入口、成员、检查、状态结果；不将 R25/R28 倒推为 0.7.10 新方向的验收 |
| [会话与源码审计](reference/orbit-session-audit-20260927.md) | 当时的池外默认派发、检查失败和降级闭环，保留版本及夹具区别 |
| [候选池验收](reference/model-pool-acceptance-20260925.md)、[OMP 接入验收](reference/orbit-omp-access-acceptance-20260925.md) | 早期版本的选模、漂移、纠偏和完成；旧门控结论已不等于现行规则 |
| [OMP 原生迁移验收](reference/omp-native-m4-acceptance-20260924.md) | 已结束 M4 的九项判定、冻结定义及例外；不重开迁移票 |
| [执行检查优化验收](reference/orbit-optimization-acceptance-20260922.md) | 多宿主时代的实验及失败边界 |
| [ADR-007](adr/007-task-runtime-refactor.md) | 已退役多宿主架构的理由与历史决定；现行裁决见 ADR-008/009 |

其余历史研究与验收按日期在 `reference/` 查阅。已被合同、决策或证据报告吸收的实施票不保留为另一套现行规则；旧正文从 Git 历史查阅。新方向写主方案，实现差距写审计，当前行为改合同及对应 ADR，验收结果写带构建身份的证据报告。

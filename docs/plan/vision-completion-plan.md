# Orbit 当前执行计划

最后核对：2026-10-01（installed 0.7.37；原 54/W1–W10 收口＝[完成记录](../reference/mixed-model-delivery-completion-20261001.md)：W1–W9 完成依据在册，W10 待 Root 核验本最终文档 diff 后执行既有本地交付；未测限制清单在完成记录，不作完工门）。方向以[主方案](mixed-model-delivery-proposal.md)为准，每项实现／调整／删除对应[代码审计](mixed-model-delivery-code-audit.md)。精确版本、当前 diff、执行者、原始证据和现场资源统一见[当前交接](handoff.md)，不在本页复制另一份状态快照。

## 同次完整交付

用户已授权以 Goal 模式完整实现及真实验收，不设硬预算，不推送或发布。Codex 编排与审核，复用用户授权的 Herdr OMP 执行者。当前 Goal **未完成**；迁移会话不清零进度、负例或剩余要求。

`orbit omp` 是启动方式。普通业务请求的自主协作是核心要求；内部 `explicit_orbit` 分类不是用户另需执行的启动步骤。不得把明确要求交接的测试说成普通需求自主派发。

## 冻结完成条件

- [x] W1：入口以执行授权及委派／监督任一路径判断；审计交付、续办归属、拒绝和失败恢复有据，题义与放行记录版本一致。
- [x] W2：成员与检查者消费任务相关、无时间信号的能力事实；agentic-only、intelligence、上下文／模态、真实路由、冲突和日期未知资格明确。
- [x] W3：池内、旧无目录、检查者、补证、状态／CLI 和文档全部退出旧时间与粗档费用选型；运行计时、缓存与停止控制保留。
- [x] W4：明确工作单元与实际派发绑定，原始要求、范围、依赖、验证及升级条件可追溯；串行与自主派发路径不增加用户逐次确认。
- [x] W5：真实路由价格／额度规则与可得用量按调用、任务、角色及实际身份关联；缺失保持未知，失败和判断用量不漏计，不新增硬预算门。
- [x] W6：新判断经过代表性真实任务、失败和缺证样本校准，实际型号与问题／输入／决策版本绑定；历史分数不迁成新判断。
- [x] W7：分层检查与当前要求覆盖闭合，实际工具范围与独立只读生效，必要升级保留此前结果与消耗；最终门及停止不退化。
- [x] W8：冻结安装构建的真实自主派发、回收、集成、finding 纠偏、手动终检与停止完成；开发者辅助动作不冒充被测 Root 行为。
- [x] W9：同等验收下比较交付、顶级资源、其他消耗、缺陷与介入；有范围地报告效果，不能以推荐次数或历史不同任务宣称节省。
- [ ] W10：相关检查、完整回归、打包和证据核对完成；文档同步、必要收尾及本地提交完成；不推送或发布后才更新 Goal complete。
（W1–W9 勾选依据＝Root 逐项有限审核（`ROOT-54-CURRENT-COMPLETION-AUDIT.json`、`ROOT-W9-RESULT-REVIEW.json`、`ROOT-NEGATIVE-REVIEW.json`）；验收原文未改，未测自然分支见[完成记录](../reference/mixed-model-delivery-completion-20261001.md)。）

## 当前关键状态

- 当前安装 0.7.37（commit `4cc957e`）；原 54/W1–W10 逐项判定与证据＝[完成记录](../reference/mixed-model-delivery-completion-20261001.md)（52 项有限范围 verified；C07/F10＝最终文档票）。
- W1–W9 完成依据在完成记录（W9＝`orbit-w9-pair-LUKH` 原冻结配对，Root `ROOT-W9-RESULT-REVIEW.json` 通过）；**W10 待交付**＝Root 核验最终文档 diff 后执行既有本地 commit＋install 核验。
- 早期版本流水、pair1–pair4 细节、0.7.20–0.7.31 各代状态**不在本页复制**：见 Git（`451bff2` 及以前）与[2026-09-29 验收记录](../reference/mixed-model-real-acceptance-20260929.md)及 `/private/tmp/orbit-*` 原件；历史失败不改判（pair4 负例、35 stop_unconfirmed 原样）。


## 下一动作

1. Root 复核最终文档 diff（完成记录＋状态同步）后授权 W10 既有本地交付（commit＋install 核验，不推送/发布）。
2. 未测自然分支（Root-stage switch live、非 stale process finding 恢复、37 marker 精确复现、failed-unit 释放）随未来普通运行累积，不是完工门（清单见完成记录）。


更早版本与运行的事实按[本次验收](../reference/mixed-model-real-acceptance-20260929.md)、交接中的原始目录及 Git 查阅。历史失败不改标，未校准正向推荐不放行，未知成本不伪装为零，不新增时间选型、硬预算或全型号可靠性证明要求。

# Orbit 当前执行计划

最后核对：2026-10-01（installed 0.7.37；原 54/W1–W10 交付核验完成＝[完成记录](../reference/mixed-model-delivery-completion-20261001.md)；未测限制清单在完成记录，不作完工门）。交付与必要收尾已完成；Goal 实际状态以 Root 工具为准。方向以[主方案](mixed-model-delivery-proposal.md)为准，每项实现／调整／删除对应[代码审计](mixed-model-delivery-code-audit.md)。精确版本、当前 diff、执行者、原始证据和现场资源统一见[当前交接](handoff.md)，不在本页复制另一份状态快照。

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
- [x] W10：相关检查、完整回归、打包和证据核对完成；文档同步、必要收尾及本地提交完成；不推送或发布后才更新 Goal complete。
（W1–W9 勾选依据＝Root 逐项有限审核（`ROOT-54-CURRENT-COMPLETION-AUDIT.json`、`ROOT-W9-RESULT-REVIEW.json`、`ROOT-NEGATIVE-REVIEW.json`）；验收原文未改，未测自然分支见[完成记录](../reference/mixed-model-delivery-completion-20261001.md)。）

## 当前关键状态

- 当前安装 0.7.37：**最终文档/本地交付身份**＝source commit `b705344b8ca24ce523922a2da78c988f67559bd8`／digest `49cf34bc27417cbcf699a08d8d2b82986b03dc43f43ac5029c36ecde9953640d`／release `5828b3c1e29432e8a00ba08a`／install exit 0（Root 已实际核对：83 pack source/release 一致，仅合同文档较 full baseline 改变）；**运行代码与 full/真实验收 baseline 仍为 `4cc957e`**，旧历史身份不改标。
- 原 54 项与 W1–W10 逐项判定与证据＝[完成记录](../reference/mixed-model-delivery-completion-20261001.md)；C07/F10 的最终文档与本地交付事实已 verified（W10 勾选依据）。
- 早期版本流水、pair1–pair4 细节、0.7.20–0.7.31 各代状态**不在本页复制**：见 Git（`451bff2` 及以前）与[2026-09-29 验收记录](../reference/mixed-model-real-acceptance-20260929.md)及 `/private/tmp/orbit-*` 原件；历史失败不改判（pair4 负例、35 stop_unconfirmed 原样）。


## 下一动作

1. 交付与必要收尾已完成；Goal 实际状态以 Root 工具为准。
2. 未测自然分支随未来普通运行累积，不是完工门（清单见完成记录）。


更早版本与运行的事实按[本次验收](../reference/mixed-model-real-acceptance-20260929.md)、交接中的原始目录及 Git 查阅。历史失败不改标，未校准正向推荐不放行，未知成本不伪装为零，不新增时间选型、硬预算或全型号可靠性证明要求。

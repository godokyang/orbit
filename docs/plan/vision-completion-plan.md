# Orbit 当前执行计划

最后核对：2026-09-30，bootstrap 修复复核与选型实现推进后更新。方向以[主方案](mixed-model-delivery-proposal.md)为准，每项实现／调整／删除对应[代码审计](mixed-model-delivery-code-audit.md)。精确版本、当前 diff、执行者、原始证据和现场资源统一见[当前交接](handoff.md)，不在本页复制另一份状态快照。

## 同次完整交付

用户已授权以 Goal 模式完整实现及真实验收，不设硬预算，不推送或发布。Codex 编排与审核，复用用户授权的 Herdr OMP 执行者。当前 Goal **未完成**；迁移会话不清零进度、负例或剩余要求。

`orbit omp` 是启动方式。普通业务请求的自主协作是核心要求；内部 `explicit_orbit` 分类不是用户另需执行的启动步骤。不得把明确要求交接的测试说成普通需求自主派发。

## 冻结完成条件

- [ ] W1：入口以执行授权及委派／监督任一路径判断；审计交付、续办归属、拒绝和失败恢复有据，题义与放行记录版本一致。
- [ ] W2：成员与检查者消费任务相关、无时间信号的能力事实；agentic-only、intelligence、上下文／模态、真实路由、冲突和日期未知资格明确。
- [ ] W3：池内、旧无目录、检查者、补证、状态／CLI 和文档全部退出旧时间与粗档费用选型；运行计时、缓存与停止控制保留。
- [ ] W4：明确工作单元与实际派发绑定，原始要求、范围、依赖、验证及升级条件可追溯；串行与自主派发路径不增加用户逐次确认。
- [ ] W5：真实路由价格／额度规则与可得用量按调用、任务、角色及实际身份关联；缺失保持未知，失败和判断用量不漏计，不新增硬预算门。
- [ ] W6：新判断经过代表性真实任务、失败和缺证样本校准，实际型号与问题／输入／决策版本绑定；历史分数不迁成新判断。
- [ ] W7：分层检查与当前要求覆盖闭合，实际工具范围与独立只读生效，必要升级保留此前结果与消耗；最终门及停止不退化。
- [ ] W8：冻结安装构建的真实自主派发、回收、集成、finding 纠偏、手动终检与停止完成；开发者辅助动作不冒充被测 Root 行为。
- [ ] W9：同等验收下比较交付、顶级资源、其他消耗、缺陷与介入；有范围地报告效果，不能以推荐次数或历史不同任务宣称节省。
- [ ] W10：相关检查、完整回归、打包和证据核对完成；文档同步、必要收尾及本地提交完成；不推送或发布后才更新 Goal complete。

## 当前关键状态

- **安装 0.7.23 生效**（commit `5d5a497`、dirty false、digest `919d5f87…`、2026-09-30T14:17:32Z 安装，`sh install.sh` exit 0，安装当时的 `git status` 为空；原件 `/private/tmp/orbit-release-0.7.23-delivery/`）。提交前组合验证全绿：full／pack／validator／version／diff-check exit 0、129 文件逐文件 SHA 一致（证据 `/private/tmp/orbit-regression-0.7.23-gu0Ouq/`；其中 `run.out` 是宿主 setsid 启动失败记录，不是测试失败）。含 bootstrap 修复＋选型 decision-3（实现者 Q；Root 2026-09-30T13:57:50Z 独立审核后重签，17 真实样本逐字保留、samples SHA `5a30130a…` 不变，结构 load 通过、旧 -2 副本不匹配）。上一版 installed 0.7.21／HEAD 0.7.22 只作历史。
- 最小真实 Jev API HTTP 200。随后 installed21 明确交接任务 `26935a3e` 的实际成员实现、Root 固定测试、独立终检和停止确认已闭合。隔离单候选池、明确交接，**普通自主派发与资源收益仍未验收**。
- 启动接缝修复已在 installed 0.7.23 生效并有普通请求实测：任务 `01f4925b-84e2-4560-9a26-20cf1bb5294b`（fixture `/private/tmp/orbit-ordinary-phone-1XOIXp`，seed `f59f7d0b…`，请求原文不提 Orbit，真实全池）入口 `uncertain → start`（jev-1.13.0）、首个载荷带 bootstrap、首次编辑前单元 `none`、Root 自行实施、检查 3 次（1 次 Go 429 失败／2、3 由 k3 完成、findings 0）、外部 copy 固定 9 例 exit 0、`complete`＋`confirmed stop`。**成员=0：只证明入口与自行实施路径，不证明自主委派。**
- 未知／不可比成本下最大质量概率优先的推强模型风险已按决策消除并随 installed 0.7.23 生效：过门后无可比资源证据时保留稳定池序（不称便宜／可靠），decision-3 放行已重签。普通任务 `01f4925b` **有匹配放行与真实付费判断**（2 次 `jev_checker_selection` `answered`，`judgment_model jev-1.13.0`），但**无候选过 0.6 门**（唯一有分候选 0.55），故降级池序；**“过门后稳定池序”的正向排序仍未被真实样本触发**。最小链资源后验（36 调用全 reported、billing／account unknown）只汇总账本、不证明收益。
- **pair2 mixed 臂该轮已完成**（`w1Y:p26`，installed 0.7.23；任务 `d623e8b1` `created_at 14:35:19Z`、终态 `complete`＋`stop_confirmation.confirmed`，终态链 `finalization_notice`→`completed_via_finalized_stop`→`stopped`；原生 `/exit` 已执行，pid 27206／27262／27322 实测消失，pane 回 shell）。入口 delegation 0.83 支持 start、bootstrap `via: provider_payload` 已记录；但 `members=0`、无工作单元/派发，**不构成自主派发证明，也不作收益结论**（账本 judgment 10／root 19／checker k3 6／checker Go 1 unknown）。baseline 臂未启动、资源对照未做；Q 外部副本验证已完成（固定 8 tests 8/8、冻结 6 probes 6/6，各一次 exit 0，评估记录 14:59:13Z），**不改 `members=0` 负例**。
- 0.7.20 配对 mixed members=0、Top 总量约 +30%，负例保留；不因源代码已修或新最小链成功改判。

## 下一动作

1. 新 Root 核对交接、live diff／installed identity／Herdr；保留成功、失败及未完成证据。minchain21 当前 PID 已不存在，本轮未执行 kill（进程表不证明退出原因），无空闲自有测试进程需收尾。
2. 安装与组合验证已完成（installed 0.7.23，`sh install.sh` exit 0，证据 `/private/tmp/orbit-release-0.7.23-delivery/`）；不再重复安装、不重跑组合验证、不升级 OMP。安装成功不称完整验收。
3. 自主委派仍是唯一未闭合核心：先做**只读调查 native 委派规则的生效分支**（有交接入口信号时 Root 为何选择直接实施），**尚未证实根因**；有效原因明确后再做针对性修复与重验，不启动 baseline、不重复同类大任务、不诱导派发。`01f4925b` 与 `d623e8b1` 均 `members=0`，只到自行实施＋检查＋complete＋confirmed stop。
4. 完整闭合质量充分后分派、旗舰必要升级、路由成本／用量、错误控制、独立纠正、手动终检和实际停止；普通监督价值任务与其他主方案必要分支不丢弃。
5. 核心通过后作冻结同质量 Top／混合对照，统计全部角色和实际未知量，按主方案 §11.3 调整负收益路径；逐项闭合 W1—W10 后才 complete。

更早版本与运行的事实按[本次验收](../reference/mixed-model-real-acceptance-20260929.md)、交接中的原始目录及 Git 查阅。历史失败不改标，未校准正向推荐不放行，未知成本不伪装为零，不新增时间选型、硬预算或全型号可靠性证明要求。

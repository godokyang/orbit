# Orbit 当前交接

最后核对：2026-09-30。**当前支持安装 0.7.21**（clean commit `fffabf801b430b61aa11d58f86f99960bdd9c8aa`，content digest `ae9ce431ead61d3bb61eb04c5050a7408ef2faf0cdbd42d02e5127512cd7d4fd`，2026-09-30T11:21:07Z 安装，`orbit version --json` 一致；未发布；OMP 与 reviewer 18.3.4 未升级）。唯一组合回归 run2 `npm test` exit 0（`/private/tmp/orbit-regression-0.7.21/report.json`）。**源码已提交并安装，业务闭环尚未验收**：普通阶段已结束，仅修改解析模块且未建任务；请求 02 已提交，任务 `8e411be9` 于 11:27:42Z 保存接管边界，六文件与普通阶段结束时一致（Controller 记录 `takeover-boundary-observation.json`），接管验收**进行中、尚无结论**。此前支持安装依次为 0.7.20（clean `1618b81`，digest `08472661…`，08:58:27Z）、0.7.19（`0faf1ce8…`）、0.7.18、0.7.17 与 0.7.12／`a1f9291`；原始身份记录见 `/private/tmp/orbit-takeover-fixture-1D6DEl/controller-records/installed-version-0.7.21.json`。

## 0.7.20 已交付（本版组合，未发布）

- 成员结算修订（[合同](../../contracts/task-runtime.md)“成员结算（2026-09-30 修订）”：原生本派发结果含真实 error、精确 work-unit 核验、`acceptedAt` 不伪盖、缺证一次通知 Root）；自选成员 `work_unit_id` 归属接缝经 Q 独立复核 PASS（`resolve_member_unit_id` 按精确 thread_id＋tool_call_id 取该单元最新派发）。
- history-gap 检查历史（S 定版，Q 静态审 PASS；其回放是**控制器确定性重放**，不是新 Orbit 实测）、root_without_hint 恢复、未知生效日成本存档（显式 `unknown`：archive／list／report）。
- 组合验证：唯一一次组合 full npm test exit 0（123 PASS，`/private/tmp/orbit-regression-0.7.20/npm-test.log`），pack dry-run 83 files，逐文件 hash 运行前后一致。
- 本版内容**不等于**完整目标验收：见下节与 W1—W10。

## 0.7.20 安装后已实测

- **provider 错误分类**：真实 Go 429／K3 403／FlashX 403 的分类与 reviewer 会话原件一致（`auth_or_quota`）；Go 429 不再记为无效 JSON，errored turn 即使 final message 合法也不授结果。
- **paired 对照**（baseline＝plain OMP 18.3.4，mixed＝installed orbit omp 0.7.20；冻结 8 项测试与 6 项探针**每臂只跑一次**）：两臂 **8/8 与 6/6 全通过**，按冻结外部标准质量无可检出差异；混合臂 **members=0**，未 exercise 成员替代路径；顶级模型 GPT-6-sol 总量 mixed 376410 vs baseline 289685（**约 +30%**，root 单侧约 +7.9%，其余来自独立检查链）；用户介入两臂均为 0。自动检查 1—6 共用**同一 observation**，2—5 是同一观察上的**有界失败重选**而非重复观察；check5 的 126455 token 为真实消耗、零接受产出（其完整结论因单条需求文本超 300 字符被 schema 拒绝）。证据 `/private/tmp/orbit-reconcile-acceptance-ucWZ9UmM/controller-records/paired-comparison.json`。
- **成本事实**：隔离项目内 `route-resources import` exit 0（显式未知生效日事实存档）、缺标记的缺生效日导入 exit 1、`list` 显示 `effective.unknown=true`、两份真实台账副本 `report` exit 0 且 `cash []`／`cost_complete=false`（107／111 次调用）。**未知生效日永不覆盖调用、永不参与定价或自动排序**；`cash` 空只表示未知，不是 0 成本。证据 `/private/tmp/orbit-resource-unknown-final-akE3Nz/controller-records/live-cli-verification.json`。

## 未闭合与下一版

- **0.7.20 成员复测已结束为 paused，停止确认通过，非业务完成**：任务 `1d977642` 首成员真实 Go 429，替补成员获原生接受，Root 的 `node --test` 原生回执为 8/8；Root 用 `amend` 补验证文字后，旧失败成员因输入版本变化被撤销结算，阻止最终完成。另查明检查上下文压缩只留下最近控制 URI 写入，遗漏同版本测试回执。Controller 原生退出后 Root／成员／后台工作确认结束；原件未改，后验见 `/private/tmp/orbit-member-settlement-live-6tGQlP/controller-records/postmortem.json` 与补充调查。
- **0.7.21 源码已提交并安装（`fffabf80`／`ae9ce431…`／11:21:07Z），唯一组合回归 run2 exit 0；业务闭环尚未验收**：接管与入口提示已并入主仓并通过相关测试与独立审查；需求文本容量 300→1000 通过相关验证与独立审；执行终结与新版本证据资格分离、修改通知来源及验证回执压缩选择修复均已完成并通过相关验证与 Q 审。回归证据 `/private/tmp/orbit-regression-0.7.21/report.json`：run2 exit 0（末尾 `INSTALL_TEST_PASS shell_configuration`；126 只是 PASS 标记行数，不是测试数量）、pack dry-run 83 files／422028 B、`check:version` 与 skill validator exit 0、**129 个源/测试/打包文件 run2 前后 SHA 相同**；首次 full 的 exit 1 与中间 fixture 失败日志保留，**只修既有 `judgment_usage_test` 夹具到生产校准形状，未放宽生产门**。源码与脚本结果不能改写上述真实失败为通过。
- 账户范围与实际扣减桶、本路由现金成本、同质量对照中的成员路径与效果仍未闭合；W1—W10 全部未勾选、Goal 保持 active、经济收益尚未证明。
- 历史失败保留、不改判：0.7.18 任务 `02a5eda7` 仍为 **partial／paused**（两成员 `registered`／idle、无 `accepted_at`、`pending_finalization` 未通知，**非业务完成**；停时 registry ref 移除导致的 bridge 读失败是次生症状），根因原件 `/private/tmp/orbit-member-positive-N0ghF3bI/controller-records/finalization-gap-analysis.json`；0.7.18 首轮 `1216aeef` 完成但 `findings={}`（结构化 finding 生命周期未 exercise、members=0、账本 36 次含两次显式 unknown）；0.7.17 起后台任务三因（hashline `edit` 方言被键白名单拒绝、首个成员真实 Go 429、hint 归因缺陷）源码已修，**其路径的 p26 实机复测已完成并保留为负例**：替补成员真实 native accepted、Root 集成后 `node --test` 8/8（交付证据），但失败首派被 `10:00:33` 修订撤销后该成员停在 `registered`（未结算、`pending_finalization` 未送达），任务终态 **paused ＋ confirmed stop**；**不记完整闭环通过**，也不把这次明确 fixture 派发当作普通自主或经济证据；0.7.11 两轮暴露的 native yield／成员退出与测试证据缺口不按源码修复重标通过。

## 0.7.10 已交付基线

- `orbit omp` 是唯一受控宿主入口，使用原版 OMP 的一层 `task/hub` 团队；Root 可自主调用原生工具派发，无需用户逐次安排；当前 Orbit 程序不直接发起 task 或替换 Root。普通 `omp` 不接入。
- 保存原始要求和显式修订、工作区绑定与固定快照；登记成员实际身份并拦截可观测漂移；独立只读检查、finding 纠正、当前版本手动终检与完成停止核对已存在。`stop_unconfirmed` 继续表示停止不可确认。
- 候选池持久保存型号，与当前会话目录取交集。有可用池内成员 Agent 的受控任务，不能用通用 `@task` 静默绕到池外默认型号；Root 可自主选池内 Agent。逐型号原生消息授权门与旧会话型号授权记忆已撤销。
- 检查者先取可运行池内候选，池空或池内都不可运行时可用 OMP 目录；隔离目录及凭据解析只证明可尝试。精确事实缺失或 Jev 低分允许明确降级，实际检查失败留证并在未尝试的可运行候选中有界重试，全部失败才阻塞。
- 可选 OpenRouter setup、0600 私有凭据、72 小时目录快照、经来源审计的模型版本映射、检查者弱质量先验及降级已接线。无 key 或项目禁用不外发也不消费旧概述缓存；独立检查安全门仍在。映射不证明 reasoning 与实际 billing route 已核实。
- 任务证据本地落盘及导出、会话汇总、用户状态提示、已归属交付回复的有界保留已存在；日志或用量不完整时如实记录未知。

运行语义以[合同](../../contracts/task-runtime.md)、[ADR-008](../adr/008-omp-native-collaboration-base.md)及[ADR-009](../adr/009-user-selected-model-pool.md)为准。该已交付基线包含旧时间／粗费用选型；不将历史分数用于新版放行。

## 已认可方向与未完成工作

用户认可[混合模型交付主方案](mixed-model-delivery-proposal.md)，并要求[逐项代码审计](mixed-model-delivery-code-audit.md)。用户补充要求完整目标一次交付，不需要硬预算；现有 Root 自主派发须保留并完善。当前目标是有限顶级模型资源下的同质量交付和更少用户介入；以下差距仍未闭合：

- 新入口“执行授权且具备委派价值或监督价值”已有有限校准放行，仍需补齐当前构建的入口与派发验收；适用域外保持未验证（有限 Git 放行见[有限校准](../reference/mixed-model-calibration-20260929.md)）。
- 成员与检查者消费任务相关、无时间信号的能力事实；agentic-only 资格、intelligence 覆盖、真实路由与冲突呈现、测量日期资格。
- 所有选型路径、检查者排序、补证、CLI 与说明中时间评分已退出新路径；状态／说明的历史显示按旧版本解释。
- 实际 OMP 路由价格与额度规则、币种与单位、Root／成员／检查者可归属 token 用量；账户范围与实际扣减桶仍未知。
- 新质量问题的代表性真实样本、失败与缺证样本，以及自动正向推荐的放行依据；旧 0.55／0.50 不能直接移用。
- 接管（takeover）与 entry advisory 已合入工作区，仍需新版安装后的真实验收；串行交接、分层核验和必要旗舰升级的真实效果验收，同次闭合完整目标。

当前执行者：Q（`p1Q` 只读审查，含 takeover delta 局部 PASS）、R（`p1R` 源码／回归／安装）、S（`p1S` 事实／fixture／docs），Codex 负责编排与审核；p26 的 Controller 实机观察**已完成并保留负例**，被测 Root 自行执行任务。旧 B／C／D／E 已结束，其独有事实归入既有 reference 与 Git 历史。已结束的实施票不留在计划目录；旧正文通过 Git 查阅。[限制清单](debt-ledger.md)只保留现存缺口。

## 验收边界

- OMP 原生迁移 M4 已结束；九项判定、#5 用户批准的组合证据例外，以及停止/裁定内容的限制见[历史报告](../reference/omp-native-m4-acceptance-20260924.md)。它不是新方向的验收。
- Zeen 0.7.9 冻结构建的 R25/R28 等真实样本见[体验验收](../reference/zeen-orbit-experience-acceptance-20260928.md)。入口自动启动、成员实际运行、Jev 推荐到成员交付分别判定，不能互相替代。
- 缺证据池内检查者降级的独立真实闭环，以及 `absent→valid` 后 Jev 0.54 仍降级的样本见[会话审计](../reference/orbit-session-audit-20260927.md)。当时任务内补证的误归因后续源码有确定性修正，未另作该修正后的实机复验。
- OpenRouter 映射来源审计和少量真实 Jev 请求不等于成员选型、去时间门、本路由成本或新题义通过验收；不能由旧报告推断当前安装的能力。
- 测试不能替代新安装实机闭环；0.7.20 的组合回归与 hash 稳定性只证明该构建的确定性行为，当前实际范围见[当前计划](vision-completion-plan.md)。
- 正式基准 API 匿名实测 401 的历史保留、不重标；基准语义测量日期仍 unknown（只有快照级 as_of），与账户凭据／实际扣减归属分列，不合并。

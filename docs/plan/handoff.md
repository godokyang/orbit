# Orbit 当前交接

最后核对：2026-09-30。源码 package 标记为 **0.7.20（待安装、未发布）**；**支持安装仍为 0.7.19**（源码 clean `0faf1ce8f723f89059cc01054bd7ce5014a5587c`，content digest `80b33374dbdad0154eb61fca0401414d77ba734b0b39ad70a14c09be88d74844`，2026-09-30T06:14:55Z 安装；OMP 18.3.4 未升级）。包内版本号不代表已安装行为，实际安装元数据待真实安装后另写一次，工作区在实施完整混合模型 Goal；此前支持安装依次为 0.7.18（clean `90433694…`，digest `231102cb…`，05:02:32Z）、0.7.17（clean `4a00ba70…`）与 `a1f9291`／0.7.12。0.7.19 修复真实 provider 错误分类：Go 429 不再记为无效 JSON，401／403 归 auth（auth_or_quota），瞬态 429／500 归 unavailable；**errored turn 即使 final message 是合法 JSON 也不授结果**。R 相关 tests 与同运行源码版本元数据在装入前 full npm test exit 0（日志 /private/tmp/orbit-reviewer-429-fix/npm-test.log）；Root 最终 version／pack 83 files／diff 均 0；Q 复核 /private/tmp/orbit-reviewer-429-fix/review-q.json 逻辑 PASS（runner lock 一行同步、frozen 真实安装 exit 0）。**不声称 0.7.19 新 runtime 已通过实测**。此前 0.7.18 全量 npm test exit 0（日志 /private/tmp/orbit-regression-0.7.18）。0.7.13 源码移除可运行检查者选择后对缺证候选的自动首轮催补，并修正 CLI 提示中把实际订阅路由误写为 unknown 的问题。0.7.14 源码又将无可归属样本的 Root 声明用量保留为条件性估计，但不再据此自动排序费用。0.7.15 源码将每次工作单元结果／核验保存在对应派发记录，重派不再清除失败交接依据。0.7.16 源码再核对历史成本样本的实际成员和型号，防止后续接受替换结果时追认此前失败。执行环境权限已恢复，0.7.16 完整 npm test exit 0、打包 dry-run 与 diff 检查通过，原始日志在 /private/tmp/orbit-regression-0.7.16。0.7.17 源码修正 similar_unit 引用核验对原生 record_check 回执未报告 reasoning（账本存 nil）与预测路由类型化 unknown 的表示一致性——仅在比较处对齐，不回写账本，已报告具体档位仍精确匹配；并将 prior_sources 截断改为优先保留基准实测站点与专用端点。新安装实机验收尚未完成。此前 0.7.11 两轮真实运行暴露 native yield／成员退出及测试证据缺口，不能按源码修复重标通过。以下交付基线与本次变更分开说明；版本号不证明已发布或全部验收。安装事实以 `orbit version --json` 的版本、commit、dirty 和 content digest 为准。

## 0.7.10 已交付基线

- `orbit omp` 是唯一受控宿主入口，使用原版 OMP 的一层 `task/hub` 团队；Root 可自主调用原生工具派发，无需用户逐次安排；当前 Orbit 程序不直接发起 task 或替换 Root。普通 `omp` 不接入。
- 保存原始要求和显式修订、工作区绑定与固定快照；登记成员实际身份并拦截可观测漂移；独立只读检查、finding 纠正、当前版本手动终检与完成停止核对已存在。`stop_unconfirmed` 继续表示停止不可确认。
- 候选池持久保存型号，与当前会话目录取交集。有可用池内成员 Agent 的受控任务，不能用通用 `@task` 静默绕到池外默认型号；Root 可自主选池内 Agent。逐型号原生消息授权门与旧会话型号授权记忆已撤销。
- 检查者先取可运行池内候选，池空或池内都不可运行时可用 OMP 目录；隔离目录及凭据解析只证明可尝试。精确事实缺失或 Jev 低分允许明确降级，实际检查失败留证并在未尝试的可运行候选中有界重试，全部失败才阻塞。
- 可选 OpenRouter setup、0600 私有凭据、72 小时目录快照、四条经来源审计的模型版本映射、检查者弱质量先验及降级已接线。无 key 或项目禁用不外发也不消费旧概述缓存；独立检查安全门仍在。四条映射不代表 reasoning 和实际 billing route 已核实，K3 当前 `unknown` 路由须逐候选复核。
- 任务证据本地落盘及导出、会话汇总、用户状态提示、已归属交付回复的有界保留已存在；日志或用量不完整时如实记录未知。

运行语义以[合同](../../contracts/task-runtime.md)、[ADR-008](../adr/008-omp-native-collaboration-base.md)及[ADR-009](../adr/009-user-selected-model-pool.md)为准。该已交付基线包含旧时间／粗费用选型；本次替换的目标及工作区进度见下文，不将历史分数用于新版放行。

## 已认可方向与未完成工作

用户认可[混合模型交付主方案](mixed-model-delivery-proposal.md)，并要求[逐项代码审计](mixed-model-delivery-code-audit.md)。用户补充要求完整目标一次交付，不需要硬预算；现有 Root 自主派发须保留并完善。当前目标是有限顶级模型资源下的同质量交付和更少用户介入；代码尚未闭合下列差距：

- 新入口“执行授权且具备委派价值或监督价值”的题义、版本与校准。
- 池内成员消费任务相关 OpenRouter 能力先验，agentic-only 的资格、intelligence 缓存 schema 及覆盖审计；完整身份映射、冲突呈现与测量日期资格。
- 所有选型路径、检查者排序、补证、CLI 和说明中删除时间评分；运行超时、TTL 和停止控制保留。
- 实际 OMP 路由价格及额度规则、币种和单位、Root/成员/检查者可归属 token 用量与成本未知退化。
- 新质量问题的真实任务校准、失败样本与自动正向推荐的放行依据；旧 0.55/0.50 不能直接移用。
- **0.7.17 新开放问题**：后台任务三因已确认：① K3 成员的 `edit` 走 hashline `{i,input}` 方言，被 `work-unit-scope.mjs` 的键白名单投影拒绝（**源码已修（715e579），当前实机待验收**）；② 首个成员收到 provider HTTP 429 `Go usage limit exceeded` 被判 rejected（provider 额度，非 Orbit 缺陷）；③ **hint 采纳归因根因已确认、源码已修（715e579）、当前实机待验收**：`task_runtime.rb` 的 `collect_amendments` 将本任务 `sent_message_ids` 中的内部提示推进 `last_user_message_id`，使自身提示的 `user_boundary` 失效（宿主门与 `current_delegation_hint` 都要求两者相等）；03:43:28Z 首次 hint 本可匹配（模型／单元／输入／产物均对）却未绑定；该缺陷已在 0.7.18 源码修复（715e579），当前实机待验收。work-unit dispatch bind 记录真实存在（不是未绑定派发）。W1—W10 仍未勾选、Goal 保持 active、经济收益尚未证明。
- **0.7.18 首轮实机（任务 `1216aeef`）**：首个有效程序独立检查（k3-256k）严格早于任何产品编辑，`delivery.ready=false` 且**未诊断出金额缺陷**；缺陷由 Root 自测 `node test.js` 失败暴露；终检 `ready=true`、1 次终检通知、1 次完成停止 confirmed。**`findings={}`，结构化 finding 生命周期未 exercise**；members=0、无 hint；账本 36 次（Root 22／checker 5／Jev 9，两次失败检查者调用显式 unknown）。不作成员交付、质量诊断或节省结论；W1—W10 仍未勾选、Goal 保持 active。
- **0.7.18 两轮终态**：rebind 任务 `35f925ba` 最终 complete／confirmed，旧检查 1 `stale=[workspace,artifact,input]`、findings 未迁移；类型化 finding `preimplementation-check-evidence` 闭环真实跑通，但检查者历史证据可见性缺口迫使 Root 自造证明文件并多轮争议（不因此否认 bug 存在）。member-positive 任务 `02a5eda7` 为 **partial**：`orbit_hint` 真实采纳→Go 429→Zenmux 替换→8 项通过，手动 check2 `ready=true`，但两成员 registered／registry idle、无 accepted_at、`pending_finalization` 未通知，`/exit` 后 paused（Root 与两成员 confirmed），**非业务完成**。根因**已定位**（R 只读原件 `/private/tmp/orbit-member-positive-N0ghF3bI/controller-records/finalization-gap-analysis.json`）：两成员的原生正常返回与真实 Go 429 都停在 `status=registered`／`registry_status=idle`（无 `accepted_at`）；Root 对工作单元的 accept／reject 裁决**不驱动** runtime 的成员结算，故 `members_settled?` 恒 false，06:03:25Z 起的 `pending_finalization` 通知被永久阻断且无超时出口；停止时 registry ref 移除造成的 bridge 读失败是**次生**症状，**不是 06:03 起停滞的原因**。修复**尚未落地**：R 实施、Q 独立审核。该轮**仍为 0.7.18 partial／paused，不因定位改为通过**；0.7.19 的分类源码与安装**不等于**新实测。
- **S／R／reconcile／成本报告现状（2026-09-30 记录）**：S 的路由资源事实报告经 Root 复核发现两处不成立推断（把页面“最后更新”日期当成 Go 事实的生效日；把被账户范围门拦下的行当成日期门证据），**已撤回该导入资格与日期结论并重做报告**（`/private/tmp/orbit-route-facts-verify/controller-records/REPORT.md`）：0 条事实可导入、10 条字段级阻塞、三份真实台账证据；该报告**没有**独立 PASS，取得独立 PASS 的是 S 的 history-gap 源码定版（Q 的 `independent-review-s-fixed.json`），两者不可混淆。S 的 history-gap 定版经 Q 静态审后处于冻结待并入，组合 9 文件在先前定版上 8 条相关套件 exit 0；随后 Root 与 Q 发现自选成员的 `work_unit_id` 关联缺失，该接缝（自选成员 `work_unit_id` 关联）已由 R 精确恢复并经 **Q 独立复核 PASS**（`task_runtime.rb` sha256 `c01a2df3…`、`task_runtime_test.rb` `b1c957b7…`、合同 `568edd7e…`、`final-integrated.patch` `8347fa0b…`；`resolve_member_unit_id` 按精确 thread_id＋tool_call_id 取该单元最新派发，要求 input_digest 与 artifact_root 均为当前，模型不符即漂移不匹配、歧义为 nil，绝不按相似型号或时间接近归属），**未安装、未实测**；成员修复整体处于冻结待并入＋补丁号提升，随后一次性跑合并后的 full npm。S 的成本表示补丁已由 R 集成进主仓源码（4 个成本文件与 S frozen SHA 一致，合同保留两轮逻辑）：显式未知生效日 archive／list，不覆盖、不定价、不自动排序；**仍未安装**。当前执行者状态：R 跑唯一组合 full npm、Q 只读审剩余缺口、S 做七份文档同步。**未安装 0.7.20、未做实机验收**。reconcile 夹具（`/private/tmp/orbit-reconcile-acceptance-ucWZ9UmM`）的 baseline 臂是 plain OMP 18.3.4、非 Orbit 验收，有效轮真实 8/8；mixed 臂已备未跑（`controller-records/mixed-launch-plan.json` 记 prepared, NOT launched，等待合并修复复核、全量回归、clean commit 与新安装构建）。真实台账 `route-resources report`（空 store）在 `02a5eda7`／`35f925ba`／`cfe88a93` 上分别 107／111／41 次调用全部 unknown、cash 为空；缺已核实事实、缺账户范围、缺开始时间三类原因分别记录，未用目录价或推断日期补账。
- 串行交接、分层核验和必要旗舰升级的真实效果验收，同次闭合完整目标。程序直接编排、Root 阶段选择与宿主调整按关键接缝和效果选择，不将已有自主派发误列为待新增功能。

文档整理已结束，完整实现 Goal 保持 active；授权同次闭合全部目标，不推送或发布。采用 [ADR-009 §6](../adr/009-user-selected-model-pool.md#6-已采纳的替换决定与实现接缝实施中) 的替换语义，当前执行者仅 Q（p1Q 只读审查）、R（p1R 源码／回归／安装）、S（p1S 事实／fixture／docs），Codex 负责编排与审核；旧 B／C／D／E 已结束，其独有事实归入既有 reference 与 Git 历史。当前工作区已接新版入口与目录事实、成员／检查者质量政策、真实 SDK 路由限制、工作单元耐久存储及工具入口、逐调用判断／检查回执账本；runtime 的旧成员时间双门、整组补证门已删除。检查者验收来自实际 instruction 或当前有效单元。

工作单元 v2 绑定实际要求版本和产物根，修订／重绑定后的旧产物不能 accepted。宿主 task 预检、实际模型 bind、当前单元工具范围和 macOS 命令沙盒已接线并有脚本／本机核验；推荐归因核对实际单元、成员、调用、型号及派发尝试，不由同模型或相邻时间推断。Root／成员 SDK 边界回执、实际 credential 精确归属、资源事实／预测 CLI 及选择成本消费者已接，pending 不封账，停止后晚到 final 用量保留。有效 AGENTS 重绑定、真实成本来源、新安装构建自主派发和同质量比较仍未闭合。计划的 W1—W10 未勾选，不能将中间态写成已上线。

TypeSafe 曾解析失败的环境现已恢复；入口与成员／检查者选型的有限默认放行均已进入源码。固定 `jev-1.13.0`、当前问题／输入／决策版本、调用前标签、失败与 holdout、独立复核见[有限校准记录](../reference/mixed-model-calibration-20260929.md)。仅适用于声明的 Git／有界交付范围，不证明模型未来可靠或安装构建完整验收。OpenRouter 双接口和变体事实已有确定性验证；正式基准 API 匿名实测 401 的历史保留、不重标。项目 `.env` 现已提供 `OPENROUTER_API_KEY`，经源码双接口实测 HTTP 200、刷新 446 个非 alias 行，key-free 证据在 /private/tmp/orbit-or-verify/verification.json；checker 与 member 两侧 facts 消费各有实证（member 侧目录事实消费已有实证（后台任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07` 成员选择阶段，4/6 候选随真实 Jev 输入送达；详情见验收报告与 JSON）；member 推荐采纳与成功交付、完整真实身份与覆盖仍待证）；新安装构建的真实闭环仍未完成。基准语义测量日期单独一项仍 unknown（无逐模型测量日期，只有快照级 as_of）；第一方价格／计划事实已按适用条件留证，但账户凭据与实际扣减归属是另一项未知，两者不合并。此前支持安装依次为 0.7.18（clean `90433694…`，2026-09-30T05:02:32Z）、0.7.17（clean `4a00ba70…`，digest `4b3e6f40b0186f40fe5aa1dfc9418eeb1a15086966a434cb5c57c970a6d46e3c`）与 0.7.12／`a1f9291`（该版 digest 见 0.7.12 记录，不在本行）；当前支持安装为 0.7.19（commit `0faf1ce8…`，digest `80b33374…`，2026-09-30T06:14:55Z，见本节开头）；详细当前证据与下一接缝只维护于[当前计划](vision-completion-plan.md)，每项主方案对应关系维护于[代码审计](mixed-model-delivery-code-audit.md)。

## 验收边界

- OMP 原生迁移 M4 已结束；九项判定、#5 用户批准的组合证据例外，以及停止/裁定内容的限制见[历史报告](../reference/omp-native-m4-acceptance-20260924.md)。它不是新方向的验收。
- Zeen 0.7.9 冻结构建的 R25/R28 等真实样本见[体验验收](../reference/zeen-orbit-experience-acceptance-20260928.md)。入口自动启动、成员实际运行、Jev 推荐到成员交付分别判定，不能互相替代。
- 缺证据池内检查者降级的独立真实闭环，以及 `absent→valid` 后 Jev 0.54 仍降级的样本见[会话审计](../reference/orbit-session-audit-20260927.md)。当时任务内补证的误归因后续源码有确定性修正，未另作该修正后的实机复验。
- OpenRouter 映射来源审计和少量真实 Jev 请求不等于成员选型、去时间门、本路由成本或新题义通过验收；不能由旧报告推断当前安装的能力。
- 检查点 `27f4ee1` 的完整回归通过。其后逐要求覆盖接线的完整回归通过；随后近期保留修复及新版检查启用 flag 的相关测试、独立精确复核通过。测试不能替代新安装实机闭环，当前实际范围见[当前计划](vision-completion-plan.md)。

已结束的实施票已从计划目录移除，独有冻结编号和验收事实归入相应报告；旧正文通过 Git 查阅。[限制清单](debt-ledger.md)只保留现存缺口，不再把已撤销授权门当成待验任务。

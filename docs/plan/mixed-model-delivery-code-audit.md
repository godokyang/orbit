# 混合模型交付方案：代码现状与调整清单

主文档：[混合模型交付方案](mixed-model-delivery-proposal.md)。本文所有“§”均指主文档条款；编号 A01—F10 用于追踪本次审视结果。

审视日期：2026-09-29。原审视基线为当时工作区源码，`package.json` 标记 `0.7.10`，Git HEAD 为 `323408bbeec22cd4a0afd9c0a5efbffc07d44c16`。工作区已有大量未提交修改及新增文件，因此这些结论不能仅由该 HEAD 复现，也不表示已发布或用户安装版具备相同行为。

用户已认可主文档；形成本文时的授权是审视代码并新增附属文档。本文记录该次审视的现状和后续建议，不替代产品语义文件。后续文档整理只修正阅读入口与引用，不把这些建议写成已实施。后续用户补充明确完整目标一次交付、不设硬预算；实施步骤按依赖拆分，不将关键目标另推下一期，也不把“可以调整架构”解释为必须重写底层。

**阅读口径**：A01—F10 各表的状态标签是 2026-09-29 在原审视基线（`0.7.10`／`323408b` 工作区）上的初审判定，属历史快照，保留原样、不按今天重写。判断现行行为以下方“当前实现对应表”（按 **installed `0.7.24`／`59eb7e7`** 复核，2026-09-30）与[合同](../../contracts/task-runtime.md)、ADR-008/009 为准；例如 F01、F03、F04 的“未实现／新增”不代表今天没有成本数据流，W1—W10 也不能因某条接线完成就机械勾选。历史实机轮次（0.7.20／0.7.21 的负例与最小链）仍按各自构建解释，不因本版已安装而改判。

本次 Goal 已获实现授权。下表保留原审计基线；以下实施进度单列，不能把一处修复当整项验收通过。已采纳的替换语义见 [ADR-009 §6](../adr/009-user-selected-model-pool.md#6-已采纳的替换决定与实现接缝实施中)。

| 项目 | 本次工作区进度 | 尚未闭合 |
| --- | --- | --- |
| A02—A05、C05—C06（§2.4、§3.2—§3.4、§10） | 入口问题为 `orbit-entry-3`，执行授权且交接／监督任一价值过门；支持串行和审计交付，引文隔离、裸继续不猜目标。当前实际 `jev-1.13.0` 八例预标注／失败／holdout 经独立复核，源码默认有限放行绑定 Git 未截断 profile 与 decision-2；新安装 `orbit omp` 已在本轮 CSV 任务真实启动和完成。 | 前序要求接管、域外入口泛化及普通需求会自行选择有效交接仍未验收；有限校准不证明模型未来成功。 |
| B02、B05—B11、C04—C07（§6、§8、§10） | overview-v3 分开模型与认证基准接口，保存 intelligence、ID、上下文、模态、参数及多个实际变体；agentic-only 无 coding 通用门。SDK limits 与精确证据／目录先验分别呈现，冲突／限制不满足交 Root。旧时间、粗费用和 local_samples 退出新路径；delegation-4／candidates-4／checker-task-fit-5 有限默认放行已装入源码。官方目录现部分行内嵌 `artificial_analysis` 指数（2026-09 实测），源码注释已纠正，抓取仍只消费专用基准端点。 | 正式基准匿名实测 401 的历史保留；本机 key 已提供，经源码双接口实测 HTTP 200、刷新 446 个非 alias 行（key-free 证据 /private/tmp/orbit-or-verify/verification.json）。checker 与 member 两侧 facts 消费各有实证（member 侧目录事实消费已有实证（后台任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07` 成员选择阶段，4/6 候选随真实 Jev 输入送达；详情见验收报告与 JSON）；member 推荐采纳与成功交付、完整真实身份与覆盖仍待证）；实时覆盖、完整实际身份、冲突处理与自主派发仍需实机。K3 quota 结构映射不代表额度可用。 |
| D01—D04、E01—E03（§5.2、§6.1、§10） | 工作单元耐久记录、Root 入口、原生 task 批量预检及实际模型 bind 已接；实际工具入口校验路径／身份，命令经 macOS 内核沙盒，越界与网络拒绝已有本机测试。推荐与实际 unit／member／tool call／model 和送达提示匹配才计采纳。检查验收可来自真实 instruction，scope-2 要求覆盖已在 0.7.12 新任务实测。 | 在途工作区重绑定、保留上下文的升级、普通需求自主交接及真实 finding 纠偏仍未验收；0.7.17 已实测真在途旧根切换与新根检查，但旧检查自行失败使 workspace-stale-on-completion 语义未验证；同版本后台任务问题已定位（Q）：后台任务三因已确认：① K3 成员的 `edit` 走 hashline `{i,input}` 方言，被 `work-unit-scope.mjs` 的键白名单投影拒绝（**0.7.18 源码已修（715e579），当前实机成员闭环待验收**）；② 首个成员收到 provider HTTP 429 `Go usage limit exceeded` 被判 rejected（provider 额度，非 Orbit 缺陷）；③ **hint 采纳归因根因已确认**：`task_runtime.rb` 的 `collect_amendments` 将本任务 `sent_message_ids` 中的内部提示推进 `last_user_message_id`，使自身提示的 `user_boundary` 失效（宿主门与 `current_delegation_hint` 都要求两者相等）；03:43:28Z 首次 hint 本可匹配（模型／单元／输入／产物均对）却未绑定；该缺陷已在 0.7.18 源码修复（715e579），当前实机成员闭环待验收；0.7.19 已修复该项的**错误分类**（Go 429 不再记为无效 JSON，401／403 归 auth，瞬态 429／500 归 unavailable，errored turn 即使合法 JSON 也不授结果），装入前 full npm test exit 0（`/private/tmp/orbit-reviewer-429-fix/npm-test.log`）、Q 逻辑 PASS（`review-q.json`，runner lock 一行同步、frozen 真实安装 exit 0）；**0.7.19 新 runtime 尚未实测**。work-unit dispatch bind 记录真实存在（不是未绑定派发）。0.7.18 任务 `35f925ba` 已实测 workspace-stale 语义 VERIFIED（旧检查 1 `stale_reasons=[workspace,artifact,input]`、findings 未迁移），但检查者历史证据可见性缺口使该 finding 多轮争议（最小修复已 parked）；0.7.18 positive 任务 `02a5eda7` 的成员／finalization 生命周期仍 partial（registered／idle、无 accepted_at、`pending_finalization` 未通知）；根因**已定位**（成员结算当前不由工作单元终裁驱动、`members_settled?` 阻断 pending 通知且无超时出口；停止时 bridge 读失败属次生）；方向为**多事实结算**（原生本派发结果／真实 error＋精确 work-unit 核验＋真实执行就绪，`acceptedAt` 不伪盖，缺证一次通知 Root）；该修订已随 **0.7.20** 装入（合同“成员结算（2026-09-30 修订）”，自选成员 unit 归属接缝经 Q 独立复核 PASS），但**正常成员结算路径无实机验收**（p26 实机已完成并保留为负例：paused＋confirmed stop）。确定性权限验证不等于全部真实成员边界通过。 |
| F01、F03、F05、F07（§9、§11.2） | 判断／检查及 Root／成员 SDK 回执接入私有账本，失败部分用量保留，重放不重复，pending 不封账，终态晚到 final 仍可见。实际 credential 精确归属、可信路由事实、当前单元／检查预测生产入口及两类选择成本消费者已接；原始价格快照与预测依据留证，未知保持未知，订阅不折算。同一 CSV 产品要求的部分分类资源对照已记录。 | 真实价格／计划来源、不同任务的完整效果比较仍未完成；脚本接线和 SDK 用量不证明实际结算或省旗舰额度。 |

E04（§7、§11.2）覆盖接线随 `1ffec49`／0.7.11 与 `a1f9291`／0.7.12 安装并实测：0.7.12 增加 scope-2 交付／生命周期区分与真实 Root 原生工具回执，并把 native yield 被拦、成员登记先移除造成的 `stop_unconfirmed` 修为生命周期入口、合格终检等待实际接受与精确 retained session 停止屏障（未放宽完成门）；检查者副本消息回执关联与目录单候选错误隔离同步修复。测试仍须真实证据，过程／裁定／过期不授交付资格，版本不重标。逐轮流水见[本次验收](../reference/mixed-model-real-acceptance-20260929.md)。

0.7.13—0.7.21 的版本级修复均已装入**当前安装 0.7.21**（此前 0.7.20）：0.7.13 停止自动注入缺证清单并修正 CLI 路由文案；0.7.14 收紧无样本预测（`declared_workload` 不自动排序、`similar_unit` 构成须等于可归属回执均值）；0.7.15 工作单元每次 finish 的结果与核验绑定对应派发记录；0.7.16 成本引用须匹配实际被接受的成员与型号；0.7.17 对齐 `reasoning` 缺失的表示并优先保留基准站点；0.7.20 含成员结算修订、history-gap、`root_without_hint` 恢复、provider 错误分类与未知生效日成本存档。逐条说明、原始日志与失败样本见[本次验收](../reference/mixed-model-real-acceptance-20260929.md)、[交接](handoff.md)与本页“当前实现对应表”，此处不复制作业流水。

## 1. 审视结论与状态口径

0.7.15 源码修正 D02／D06／D09（§5.2—§5.3、§6、§9）：旧实现重派会清空上次结果，派发历史和事件又不保存结果正文，后续交接只能看到身份。现将每次状态／结果／核验保存在对应派发记录，重派和切换型号仍保留；选择的两次判断及原生成员交接沿现有字段接收该历史，调用 ID 继续用于资源归属。旧 v2 仅保留仍可核实的最近结果，不补造此前缺失历史。工作单元、选择输入和资源相关定向测试通过；失败分类、升级决策及真实自主派发仍未验收，未安装、未发布。

现有实现已经提供受控任务的主要骨架：原始要求与修订留存、工作区绑定、原生成员登记和身份漂移处理、独立只读检查、纠正投递、当前版本完成门及实际停止核对。这些可以保留。

原审视基线中的新目标尚未闭合，当时最直接的差距是：入口只问独立检查收益；成员尚不消费 OpenRouter 先验；成员与检查者仍使用时间信号；本路由价格与 Root／成员用量没有形成可结算数据流；新题义没有对应放行依据。现有代码能组织和检查任务，但不能据此证明已经用有限顶级模型资源完成更多同质量工作。

| 状态 | 含义 |
| --- | --- |
| 已实现／保留 | 找到当前源码中的实际调用链，可作为后续基础；不代表本轮完成了真实模型验收 |
| 部分实现／调整 | 已有机制，但输入、语义、消费者或可核验范围未满足主文档 |
| 未实现／新增 | 在相关生产调用链未找到所需行为；需要补能力而非仅改说明 |
| 旧规则／删除或替换 | 当前行为与新方向冲突；后续应移出新决策路径，保留必要历史解释 |
| 架构选项／待验证 | 主文档允许探索，但收益或宿主能力尚未证明；不是立即重构任务 |

“删除”主要指删除旧选择规则、问题及其活跃消费者，不是删除所有包含时间的代码，也不是抹除旧判断记录。

### 当前实现对应表（按 installed `0.7.24`／`59eb7e7` 复核，2026-09-30）

本表只说明**源码接线现状**，不是完成条件已证明。原 2026-09-29 初审表与上表保留历史口径；未列出的验收仍以[当前计划](vision-completion-plan.md)为准，W1—W10 保持未勾选。

| 审计项 | 快照状态（2026-09-29） | installed `0.7.24` 源码现状（2026-09-30 复核） | 源码证据 | 仍未闭合 |
| --- | --- | --- | --- | --- |
| A02—A05、C05—C06 | 旧规则／部分实现 | 入口改为 `execution_authorized` ＋ `delegation_value`／`supervision_value` 两条收益路径，任一过门；引文、裸继续不猜目标；题义版本 `orbit-entry-3`，有限默认放行限声明的 Git／有界交付域 | [prestart.rb](../../lib/orbit/prestart.rb) 入口问题与判门（第 42 行起、332 行） | 域外泛化未证明；installed 0.7.23 普通请求任务 `01f4925b` 已走 `uncertain → start`（jev-1.13.0）并完成，但 `members=0`，不构成自主委派证据 |
| B02 | 未实现／新增 | 成员链已消费目录先验（与检查者同一 overview 实例） | [member_model_selector.rb](../../lib/orbit/member_model_selector.rb)（`@overview`、`model_overview_prior`） | 真实采纳、交付归属与完整身份未验收 |
| B05、B06 | 部分实现／调整 | 检查者身份按宿主已解析路由推导：`identity_for(catalog, model)` 取 `catalog["routes"][model]`，缺失或非枚举值才回落 `unknown`，`reasoning` 暂无声明时保持 `unknown`；`lookup` 仍按四字段精确匹配（不是固定查 `unknown/unknown`） | [checker_model_selector.rb](../../lib/orbit/checker_model_selector.rb) `identity_for`（第 323 行起）／`lookup`、[openrouter-model-map.json](../../lib/orbit/data/openrouter-model-map.json)（6 条路由条目、覆盖 4 个模型身份） | 缺口在映射覆盖率与逐调用真实计费桶，不在查询方式 |
| B07、B09 | 旧规则／未实现 | 三个指数（coding／agentic／intelligence）都可作为任务相关事实，无 coding 通用准入门；缺失指标如实缺口 | [openrouter_model_overview.rb](../../lib/orbit/openrouter_model_overview.rb)（`BENCHMARK_KEYS`、`lookup(indices:)`） | 只有快照级 `as_of`，无逐模型测量日期 |
| B10、B11 | 部分实现／未实现 | 先验携带 `measurement_date(_status)`、`benchmark_as_of`、`conflicts`／`hold_reason`，日期未知与潜在冲突分别标注 | overview `PRIOR_KEYS`；[model_capability_facts.rb](../../lib/orbit/model_capability_facts.rb) `evidence_relations` | 冲突的真实呈现与放行资格待实机 |
| C01、C02、C04 | 旧规则／删除 | 时间与粗费用问题、排序键退出新路径；旧键只出现在排除表和历史显示分支 | [model_quality_policy.rb](../../lib/orbit/model_quality_policy.rb)（已删 score keys、`OMITTED_STATE_KEYS`）、[model_evidence_cache.rb](../../lib/orbit/model_evidence_cache.rb)（`LEGACY_SELECTION_METRIC`）、`cli.rb` 补证文案；[task_view.rb](../../lib/orbit/task_view.rb) 旧版本分支显式标注“不用于新版自动推荐” | 说明／状态的历史显示仍需按旧版本解释 |
| C03 | 旧规则／删除 | 生产链未见无目录整组 fallback 的调用方 | `connection.rb`／`member_model_selector.rb` 检索无命中 | 宿主升级时复核 |
| D02、D03 | 部分实现／旧规则 | 工作单元记录与串行交接进入选择输入；不再要求并行另一工作面 | [work_unit.rb](../../lib/orbit/work_unit.rb)、`model_quality_policy.rb` 的交接题义 | 真实失败升级未验收 |
| E04 | 未实现／新增 | 覆盖门已接线：`coverage_required` 与逐项 requirement 状态参与终检资格 | [task_runtime.rb](../../lib/orbit/task_runtime.rb)（`requirement_coverage_status`）、[requirement_coverage.rb](../../lib/orbit/requirement_coverage.rb) | 真实任务的覆盖质量待验 |
| E06 | 已实现／保留 | 完成门仍要求成员 settled；`members_settled?` 对 `02a5eda7`（两名成员 registered／idle、无 `accepted_at`）为 false（**该样本缺口，非全局恒 false**；无成员任务 `1216aeef` 正常完成并有 confirmed stop） | `task_runtime.rb` `members_settled?`／`completion_gate` | 成员结算机械路径已由 installed 0.7.21 明确交接任务 `26935a3e` 的 accepted＋hint 采纳＋complete＋confirmed stop 证明；**普通全池自主委派仍未验**，p26 等负例按原记录保留不改判 |
| F01、F03、F07 | 未实现／新增 | 路由资源事实结构、预测生产者与消费者、诚实 unknown 与缺证记录；**安装 0.7.20 已实测**显式未知生效日的 archive／list／report（隔离 CLI：import exit 0、缺标记 exit 1、report exit 0 且 `cash []`） | [route_resource_facts.rb](../../lib/orbit/route_resource_facts.rb)、[route_resource_store.rb](../../lib/orbit/route_resource_store.rb)、[route_cost_inputs.rb](../../lib/orbit/route_cost_inputs.rb) | 未知生效日的事实永不覆盖／定价／自动排序；账户范围与实际扣减桶仍未知，本路由现金成本仍不可判 |
| F04、F05、F06 | 未实现／部分实现 | 逐调用账本已接，pending 不封账、失败与晚到用量尽量保留 | [resource_call_ledger.rb](../../lib/orbit/resource_call_ledger.rb)、`task_runtime.rb` 的 `accumulate_jev_usage` 与回执路径 | 真实失败链用量仍可能未知 |
| F08 | 范围已明确 | 不新增硬预算或费用停止门（用户已明确不需要） | — | 保持 |
| F09、F10 | 未实现／源码可确认 | installed 0.7.20 paired 对照已跑：冻结 8 项测试与 6 项探针两臂各 8/8、6/6 通过，质量无可检出差异；顶级模型总量约 +30%、用户介入两臂均 0；混合臂 members=0 | [当前计划](vision-completion-plan.md) 真实验收段 | 单任务对、未 exercise 成员替代路径，不证明节省；0.7.10 仍不得描述成已上线全部新行为 |

**2026-09-30 复核补充（installed `0.7.23`→`0.7.24`，只补有限事实，不改上表历史口径）**

- 安装身份：**当前 0.7.24**，commit `59eb7e777fd521e9db138e9953ff0adc277538e2`、dirty false、digest `02067f5813489335dfe85a086bc9c791b0eff8b31c309ede950935a18bd1e994`、installed_at `2026-09-30T15:32:10Z`（安装窗口 `15:31:55Z→15:32:12Z`、exit 0；原件 `/private/tmp/orbit-release-0.7.24-delivery/`）；提交前组合验证 full／pack／validator／version／diff-check 全 exit 0、129 文件 pre/post/final **逐文件**一致（`/private/tmp/orbit-regression-0.7.24-fqtEee/report.json`）。上一版 0.7.23（`5d5a497`、digest `919d5f87…`、14:17:32Z）作历史。
- 受控串行交接合作政策（0.7.24 新接缝）：原生 restrained 系统文案（inline-first／「NEVER delegate one slice」）与主方案 §5.2 串行接力冲突**已确认**（源码规则分支＋shape／config 探针）（`pi-catalog` `classes/openai.kdl` `revision >= 6` → `restrained`；`system-prompt.ts` 该分支渲染 inline-first；实际 wire 未落盘，不宣称服务器收到或模型遵循）；程序在实际 owned＋活动＋runtime alive 的受控 Main 的**每个可达 provider 请求**于同层（`instructions`／Anthropic `system`／messages 既有 `system`、`developer` 文本末尾／Responses `input` developer 块之后）注入条件式政策，不可识别形状静默跳过、不落用户消息尾；不 force 派发、不代替 Root native `task`，不改 Jev 题义／阈值／decision-3／17 样本。Q 预部署审 PASS＋F-1（developer 角色 messages 渠道）增量复核 PASS，`metadata-correction.json` 仅勘正记录誊写。
- 版本标签（未变）：selection 决策 `orbit-quality-decision-3`、member `orbit-member-selection-v2`、checker `orbit-checker-selection-v7`、checker signature `v8`；旧 `-2`／`v1`／`v6` 记录按旧版本解释、不改写。
- **pair3 mixed 臂已启动（截至本次读取 2026-09-30T15:49:00Z，running／partial）**：`/private/tmp/orbit-reconcile-pair3-NXisvi`，`launch-current.json` 记 pid 19954／release `c57f2888e80281027ffc166d`（0.7.24）；任务 `b91fe4de-9927-4aaf-883a-e59423845e4c` 15:42:28Z 建立、现 `running`、checks=0、无 stop；policy1 `instructions` 首层事实已记，15:44:12Z Root 自主声明 `wu-56f0622023bf4fa6`，首次 selection 因 `Net::OpenTimeout` `not_recommended`，15:45:19Z 无 hint 自主首派注册后 provider 429 真实失败（工作单元 `failed`），15:46:30Z 新 selection `recommended`（K3 首选／Zen 备选）且 hint 已送达；**尚无已接受成员交付、无 checks、无停止；baseline 未授权。**
- 普通请求实测：任务 `01f4925b` 走入口 `uncertain → start`、首个载荷带 bootstrap、首次编辑前单元 `none`、Root 自行实施、检查 3 次（1 次 provider 失败／2、3 完成、findings 0）、外部 copy 固定 9 例 exit 0、`complete`＋`confirmed stop`；`members=0`，**不证明自主委派**。选择 basis `pool_order_unreleased`：**任务在放行 profile 内且有真实付费判断**（2 次 `jev_checker_selection` `answered`，`judgment_model jev-1.13.0`、decision-3），但**无候选过 0.6 门**（唯一有分候选 0.55），故当时降级池序——**那次只证明降级；也不是域外任务**。**pair3 本次 selection 已触发该正向排序并直接核对**（state `member_selections[wu-56f0622023bf4fa6]`：released `orbit-quality-decision-3`、门 0.65；index1 K3 0.66 与 index4 Zen 0.70 过门，`first` 仍 K3／backup Zen，`cost_comparison: unknown`、basis `released_task_fit`）；**phone／pair2 未触发**；真实 hint 采纳与成员交付仍未证。
- pair2 mixed 臂该轮已完成：`w1Y:p26`（pid 27206，installed 0.7.23），任务 `d623e8b1`，`created_at 2026-09-30T14:35:19Z`，终态 `complete`＋`stop_confirmation.confirmed`（`finalization_notice`→`completed_via_finalized_stop`→`stopped`）；原生消息 `8eec046e`、入口 delegation 0.83、bootstrap `via: provider_payload`、首次编辑前单元 `none`；`members=0`、无工作单元与派发，**不构成自主派发证明、不作收益结论**（账本 judgment 10／root 19／checker k3 6／checker Go 1 usage unknown）；原生 `/exit` 已执行、pid 27206／27262／27322 实测消失。已确认原生指令存在冲突（源码规则分支＋shape／config 探针，实际 wire 未落盘）并随 0.7.24 交付同层政策修复（见下复核补充）；**旧两轮 `members=0` 的因果不能由静态推定，真实自主验收仍待**。Q 外部副本验证已完成（固定 8 tests 8/8、冻结 6 probes 6/6，各一次 exit 0，评估记录 14:59:13Z），**不改 `members=0` 负例**。
- 最小链资源后验：36 调用全 reported、call_id 唯一、checker 两账本 id 集与用量一致、reasoningTokens 子集未另加；billing／account 仍未知。该摘要文件的 `recorded_at_utc_machine_clock` 为手写估计、**时间未核实**（纠正记录 `/private/tmp/orbit-quality-decision-3-impl/install-preflight-timestamp-correction.json`），不重标原事件、不改账本；该轮同时是 native hint 采纳与成员结算的有限证明，旧负例（p26、`02a5eda7`、`1d977642` 等）原样保留。
- **F09 的范围**：需要的是同等验收对照与报告，**不要求产品内新增对照编排模块**；缺该模块不算源码未实现。**A08／B12 同理**：不要求五阶段聚合组件或永久先验自更新框架，按用户可区分事实与既有函数输入说明核对即可。

## 2. 什么时候唤起 Orbit

| 编号 | 对应主文档 | 当前状态与源码证据 | 建议处理 |
| --- | --- | --- | --- |
| A01 | §3.1、§12 | **已实现／保留。** [omp_entry.rb](../../lib/orbit/omp_entry.rb) 的 `launch` 提供会话接入；[omp-host.mjs](../../plugins/omp-host.mjs) 的入口钩子（1978 行起）在原生用户请求到来后才判定并建任务。打开会话与建立受控任务是不同动作。 | 保留这层分离。不能因工具已加载就显示当前工作已受监督。 |
| A02 | §3.2、§3.4 | **已实现／保留，边界见 A03。** [prestart.rb](../../lib/orbit/prestart.rb) 的 `classify` 先处理 opt-out 与明确请求；[cli.rb](../../lib/orbit/cli.rb) 的 `entry` 按原生消息 ID 查账本；宿主按 session/message 去重并跳过已绑定活动任务。 | 保留规则优先和幂等。明确受控请求仍需经过真实启动条件，不能由收益低分否定用户选择。 |
| A03 | §3.2 | **部分实现／调整。** `PrestartClassifier#classify`（128 行起）与 `explicit_request?` 在原消息文本上匹配正则；未看到先区分引用、代码块与用户当前指令的处理。本轮直接调用本地 `classify` 核实：“解释这句：用 Orbit 启动任务”返回 `explicit_orbit`。文件名和单独提及 Orbit 的部分规避不能证明引文安全。 | 在明确请求路径补指令归属判断，避免引用中的命令直接建任务。此项是实际启动语义，不只是提示措辞；本轮只调用分类函数，没有执行入口或启动任务。 |
| A04 | §3.2、§3.3、§3.6、§11.1 | **旧规则／替换。** [prestart.rb](../../lib/orbit/prestart.rb) 的 `ENTRY_QUESTIONS` 只有 `execution_authorized` 与 `independent_check_benefit`，后者把只读请求视为无收益；`decide_uncertain` 要求两个分数都过线。[cli.rb](../../lib/orbit/cli.rb) 477 行的 Root 提示也只问是否值得独立检查。 | 改为执行／可核验交付要求，加上“实质交接价值或监督价值”两条收益路径。支持串行交接、单工作面监督及有成果要求的独立审计；保持概念讨论和低风险短改可走普通执行。同步改 Root 决策提示。 |
| A05 | §3.4、§3.3 | **未实现／新增。** [prestart.rb](../../lib/orbit/prestart.rb) 的 `entry_state` 只传当前消息的有界文本及 Git 变化；无活动任务时没有可追溯前序要求输入。“继续”不能仅凭这份输入恢复原任务。 | 需要接管时由 Root 选取可核验的原始要求、当前版本和接管点；未找到依据保持未知，不从 Git 变化猜用户目标，也不追认早前工作已受监督。 |
| A06 | §3.4、§6 | **已实现／保留。** [task_runtime.rb](../../lib/orbit/task_runtime.rb) 的 `collect_amendments`（2412 行）把新问题留为 unassigned，只有显式 `amend` 改输入；`task_turn_attributed?` 核对答复来源，防止独立问题被当成本任务交付。 | 保留显式修订和答复归属。已有任务跳过入口评分，不等于每条后续消息都自动成为修订。 |
| A07 | §3.3、§3.4 | **部分实现／调整。** `start` 可在当前会话中建立任务，`TaskRecord.create` 保存建任务时的工作区与要求；但未找到“普通执行途中升级”为受控任务的专门接管记录。 | 复用现有启动能力，补接管原因、要求来源和接管时产物版本即可；不必另建宿主。清楚记录监督开始的位置及既有产物的核验范围。 |
| A08 | §3.1、§3.5 | **部分实现／调整。** [task_view.rb](../../lib/orbit/task_view.rb) 与宿主状态展示已有任务、委派结果、成员执行和检查活动信息；未具备新入口两类价值与阶段资源信息。 | 新状态应区分已接入、任务已激活、已建议、实际派发及实际检查。保留现有事实投影，不把第一阶段高分或准备中的 hint 显示为已派发。 |

## 3. 权威能力数据、成员接线与身份

| 编号 | 对应主文档 | 当前状态与源码证据 | 建议处理 |
| --- | --- | --- | --- |
| B01 | §2.3、§5.3、§8.1 | **已实现／保留。** [task_runtime.rb](../../lib/orbit/task_runtime.rb) 的 `member_candidates`（1200 行）取用户池、会话可选型号与原生 Agent 的交集；宿主生成固定型号 Agent。推荐不派发，Root 使用原生 `task` 派发。 | 保留真实可调用候选和 Root 决策。当前受控通用 `@task` 在有可用池而默认型号在池外时会被拒绝（宿主 1850 行；合同第 79 行），不能把“Root 可自选”描述成可绕过现行池边界。未来是否扩展另作决定。 |
| B02 | §1.1、§2.3、§8.1、§11.1、§12 | **未实现／新增。** `pool_evidence_view`（1171 行）只查 [model_evidence_cache.rb](../../lib/orbit/model_evidence_cache.rb)；`run_candidate_assessment` 只把这些精确缓存事实传 Jev。OpenRouter 当前接在 [checker_model_selector.rb](../../lib/orbit/checker_model_selector.rb)，未接成员选择链。 | 成员链增加经核实映射的模型级先验输入，优先满足成员选择用途。先验与本路由事实分开标注；在新机制校准前展示事实供 Root 选择，不直接开放自动正向推荐。 |
| B03 | §2.1、§8.1 | **已实现／保留。** 池内各候选独立处理，有效候选不被其他缺证／`unavailable` 候选阻断；Root 精确资料不再是池内评分前提。未发现强制每个池内型号必须先有本地成功样本的程序门。 | 保留逐候选处理。移除补证文案里让人误解必须先准备本地样本的要求，允许相关权威先验作为起点；不把未知解释为不胜任。旧无目录整组路径另见 C03。 |
| B04 | §2.3、§8.2 | **已实现／保留。** [jev_advisor.rb](../../lib/orbit/jev_advisor.rb) 通过 typed judgment 返回分数和实际判断元数据；目前未找到将 OpenRouter 指数与 Jev 输出数值相加的代码。缓存事实结构校验也明确不验证网页内容真伪。 | 延续“事实输入→具体问题→启发式判断”，不要新增加权总分重复计算先验。来源 URL 和结构合法不等于能力已认证；Noul 不能宣称为当前任务实测成功率。 |
| B05 | §8.3、§10“真实路由与映射” | **部分实现／调整。** 精确缓存按 provider/model/reasoning/billing_route 查找；宿主依据解析端点给成员推导路由，[plugin_connection.rb](../../lib/orbit/plugin_connection.rb) 保留 routes。检查者 lookup 却固定 `reasoning=unknown,billing_route=unknown`，隔离探针只证明型号与凭据可解析。 | 保留精确匹配，分别核对成员和检查者实际执行配置。不能把成员目录路由直接当隔离检查者的真实路由。补可核验端点／配置与计费关系、变更失效签名；账户与计划只记必要非秘密标识。 |
| B06 | §8.3、§10“真实路由与映射” | **部分实现／调整。** [openrouter-model-map.json](../../lib/orbit/data/openrouter-model-map.json) 四条映射均为 unknown route；K3 是 `kimi-code/k3-256k`。宿主 `billingRoute`（1674 行）对 HTTPS `api.kimi.com/coding/` 可给 subscription_quota；overview 的 `mapping_for` 精确匹配 route。 | 这是可由源码确认的条件性不匹配，不代表已读取用户当前端点。逐候选审计真实路由并补映射关系；不得为了命中现有条目把 subscription_quota 改成 unknown。四条映射存在不等于四个真实候选都可命中或都有指标。 |
| B07 | §8.1、§10“指标接入” | **旧规则／删除。** [openrouter_model_overview.rb](../../lib/orbit/openrouter_model_overview.rb) 的 `lookup`（218 行）要求 coding 数值，否则 `no_benchmark`，即使 agentic 存在也不给先验。 | 删除 coding 非空这个通用准入门；按任务相关指标提供事实。缺 coding 的编码任务仍显示该缺口，不能用其他指数冒充。 |
| B08 | §8.1、§8.3、§10“指标接入” | **部分实现／调整。** `store_model` 存了 context_length 和 architecture，但 `PRIOR_KEYS`／lookup 输出只有 canonical_slug、coding、agentic、fetched_at、sources、reasoning_note；真实目录 id、上下文、模态没有进入先验输出。 | 把必要能力事实传到选择输入，同时保留“目录能力”与“本执行路由限制”的区别。K3 本体上下文不能覆盖 k3-256k 的实际限制；工具支持也须核对实际宿主。 |
| B09 | §8.1、§10“指标接入” | **未实现／新增。** `store_model` 只提取 coding_index、agentic_index；当前 overview-v1 不保存 intelligence_index。 | 扩展并版本化缓存 schema、清洗和先验投影，审计实际覆盖。一般分析可以消费适用范围明确的 intelligence，不把它当编码质量补值或所有语言／模态能力。不能只扩提示而忽略抓取清洗。 |
| B10 | §2.2、§10“冲突与时效” | **部分实现／调整。** overview 72 小时 TTL 与 key digest 控制快照有效性；精确缓存也有 retrieved_at/valid_until。但未保存基准测量日期、方法版本及未知日期的资格规则。 | 区分抓取日期、映射核实日期、实际测量日期和本地观察日期。测量未知可以作为带局限的事实展示；是否可进入某版自动建议须由校准后的策略明确，不能因刚抓取就当近期测量。 |
| B11 | §2.2、§5.3、§10“冲突与时效” | **未实现／新增。** 检查者 `prepare`（190 行）仅在没有精确 evidence 时保存可用 prior，`judgment_candidate` 以 if/else 二选一；成员链也无目录输入。没有同时呈现与分类冲突的链路。 | 同时保存两类证据的来源、任务范围、版本和执行配置；区分不可比与实质冲突。具体任务失败不能被目录高分覆盖；无法解决时交 Root 复核，必要时请求顶级模型判断，而非按来源名称机械择一。 |
| B12 | §2.2、§8.1、§11.2 | **部分实现／调整。** 已有 member_result、finding、纠正、实际型号和 check 记录；没有把这些结果关联到工作单元和被评价选择策略，作为有界运行反馈的输入。 | 关联任务／工作单元、选择问题版本与实际结果，记录失败原因和适用范围。反馈逐步修正先验，不形成永久品牌排名，也不要求全池先积累样本。 |
| B13 | §1.1、§12 | **已实现／保留。** [openrouter_setup.rb](../../lib/orbit/openrouter_setup.rb) 原子写私有凭据文件（0600）；overview 有可选配置、72 小时缓存、刷新锁、失败退避和无 key／禁用退化；lookup 是本地只读。 | 复用现有接入，不另造一套秘密管理和抓取器。扩展 schema 时保留有界输入、key-free 状态、canonical 漂移失效以及禁用不出站行为。 |

## 4. 需要删除或替换的选型规则

| 编号 | 对应主文档 | 当前状态与源码证据 | 建议处理 |
| --- | --- | --- | --- |
| C01 | §1.1、§2.4、§10“去时间信号”、§12 | **旧规则／删除或替换。** 池内 `run_candidate_assessment` 使用 quality≥0.55、time≥0.50 双门，随后按 time 降序、coarse cost 排序（1312—1325 行）；`JevAdvisor#assess_candidates` 每候选询问 quality/time。 | 删除 time 问题、declined_time 分支、耗时排序及提示里的时间理由。质量改为指向工作单元的正向适配信号，新题义独立校准，不直接继承 0.55。成本按 F01—F03 的可信数据和未知规则处理。 |
| C02 | §1.1、§8.2、§10“去时间信号” | **旧规则／删除或替换。** 检查者对有精确证据的候选仍问 time，[checker_model_selector.rb](../../lib/orbit/checker_model_selector.rb) 构造 time_tier/cost_tier；[checker_model_selection.rb](../../lib/orbit/checker_model_selection.rb) 的 `order_by_time_cost` 先时间后粗成本。 | 删除检查者时间问题、TIME_RANK、time_tier、time_cost_gap 及旧理由。保留可运行性预检、明确降级与 Root 重选；替换为任务适配和可信本路由成本判断。异家族只能是可说明的偏好，不能证明独立性或质量。 |
| C03 | §2.1、§5.2、§10“去时间信号” | **旧规则／建议删除活跃分支。** `member_candidates=nil` 时仍运行旧整组比较，要求 Root 和全部身份有精确证据，并用 member_fit/parallel_gain/cost_appropriate。[connection.rb](../../lib/orbit/connection.rb) 当前只创建具备 model_catalog 的 PluginConnection；目录出错返回 []，不是 nil。 | 当前生产 OMP 链未找到需要这条无目录 fallback 的调用方。后续统一到逐候选链，移除旧整组门及调用它的恢复／提示分支；测试替身改为模拟真实目录能力。删除前核对当时支持的宿主版本与实际调用方；保留“池空无自动建议、Root 按现行门显式派发”的路径。 |
| C04 | §1.1、§2.1、§8.2、§10“去时间信号” | **旧规则／删除或替换。** `EVIDENCE_NEEDED_FIELDS` 是 speed/quality/cost/local_samples，`send_evidence_request`（2065 行）请求端到端时间和速度。成员候选沿用含 elapsed_seconds 的公共 observation，精确 metrics 可继续把性能事实传给 Jev。 | 新选择输入按职责投影，只消费任务能力、执行资格和可信路由成本；不再为建议索取 speed、耗时或本地成功证明。存档旧 metrics 可读，但不能因删除显式问题仍把速度事实喂入新问题变相排序。运行诊断的 elapsed 字段不需全局删除。 |
| C05 | §2.4、§3.6、§10“新判断放行”、§11.1 | **部分实现／调整。** 入口有 EntryCalibration，内置六个旧样本、0.80/0.80；源码注明 orbit-entry-2 修订后仍待真实复评。成员／检查者未见新题义放行机制，使用静态阈值；日常 Jev 默认还是 jev-latest。 | 校准记录应绑定实际 Jev 版本、问题版本、输入构造版本和适用任务范围，包含失败／缺证样本与放行理由。新语义未放行只显示事实供 Root 自选；旧校准不能覆盖新入口、新先验和新候选问题。无需给每个型号做可靠性认证。 |
| C06 | §2.3、§2.4、§10“去时间信号”、§12 | **部分实现／调整。** 已有 orbit-entry-2、jev-observation-1、jev-delegation-1、jev-candidates-1、jev-checker-task-fit-2 及 checker selection-v5 记录；但多数阈值与解释不随策略版本分开。 | 修改题义要升对应问题版本、决策版本和缓存重用签名；记录实际判断型号。旧记录按旧版本解释，不改写 time 成新质量，也不把旧高分追认为新推荐。版本升级不等于默认自动放行。 |
| C07 | §3.1、§10“去时间信号”、§11.1 | **部分实现／调整。** `TaskView#delegation_outcome` 仍显示“质量与整体耗时门槛”，`delegation_score_text` 仍展示 parallel_gain；runtime 的推荐／补证提示、CLI 示例、README、[使用参考](../reference/usage-reference.md)、当前合同与 ADR-009 仍解释旧规则；现有 Jev/成员/检查者测试也冻结这些行为。 | 实施时同步所有活跃消费者和权威语义正文。新界面显示来源、适配信号、未知成本和实际派发归因；旧界面按历史版本解释。改对应高价值测试，不为凑覆盖率扩测试体系。本轮不改这些文件。 |

删除范围必须沿调用链完成：问题文本 → 输入投影 → 分数解析 → 判门／排序 → 持久字段与重用 → hint／补证 → CLI／状态 → 文档／测试。只删“time”问题会留下旧读取器，或从原始 metrics 把时间重新带回来。

以下时间事实应保留，对应主文档 §1.1、§3.5、§9：运行超时与 hard_deadline、RPC／停止等待上限、检查调度兜底与冷却、抓取时效、凭据／价格有效期、额度重置日期和审计事件时间戳。结束时的 elapsed_seconds、time_variance_seconds 可作为历史运行事实；只要不回流型号适配、排行或推荐依据，就不违反去时间选型。

## 5. 交接、错误控制与架构选项

| 编号 | 对应主文档 | 当前状态与源码证据 | 建议处理 |
| --- | --- | --- | --- |
| D01 | §5.1、§6、§11.2 | **已实现／保留。** [task_record.rb](../../lib/orbit/task_record.rb) 留存 instruction、basis 原文及 sha256、修订、工作区、检查和决策；runtime 使用输入 digest，不只依靠聊天记忆。 | 保留原文、来源和版本。这是责任连续的基础，不等于已建立完整工作单元状态或可靠语义记忆。 |
| D02 | §5.2、§8.2、§11.2 | **部分实现／调整。** 宿主记录原生 task/context/rationale（1867 行）；成员登记有 id/model/tool_call_id，但没有结构化要求关联、验收、允许范围、依赖及升级条件。Jev 判断的是“best bounded subtask”，缺一个与后续派发绑定的明确对象。 | 先增加最小可追溯工作单元记录，供选择、派发、结果和核验共用；必要内容按主文档 §5.2 保存。不能对抽象最佳子任务评分后，把任意实际派发都视为已评估。无需先建设通用工作流平台。 |
| D03 | §3.2、§5.2、§11.3 | **旧规则／删除或替换。** observation 的 delegatable 问题要求成员执行时主 Agent 继续；`candidate_recommendation_text`（1438 行）强制 Root 继续另一工作面，无独立面则 decline；旧 parallel_gain 同样围绕缩短关键路径。 | 去掉必须同时执行两块工作的要求，允许有明确依赖的串行交接和 Root 等待成员后集成。保留有界成果、依赖可满足和避免重复劳动的条件；串行方案是否省顶级额度要按 F09 比较。 |
| D04 | §5.3、§6、§8.3 | **已实现／保留。** 宿主注册前核对调用者、实际成员 id 与预期模型，注册时及 before_provider_request 处理型号漂移；`members.json` 持久登记，runtime 拒收漂移结果、失效旧 hint 并尝试停止。 | 保留真实登记、漂移处理和 hint／Root 自派归因。不因加入 OpenRouter 先验就跳过实际模型核对。当前记录主要是 provider/id，推理、路由与调用用量的完整关联另见 B05、F04。 |
| D05 | §5.2、§6 | **部分实现／调整。** 检查者有工具限制；生成成员 Agent 只固定 model 和禁止再派发，任务工具入口核对 Root 身份与注册，未见按工作单元对成员写入路径、命令和外部操作的 Orbit 执行限制。OMP 自身权限不等于该工作单元权限。 | 按真实需求把必要范围约束落到可执行工具入口，核对宿主是否支持；提示“仅改这些文件”不能冒充强制限制。允许范围内但目标外的动作仍由事实和语义检查发现。不要为了形式完整新增无需求的权限框架。 |
| D06 | §5.1、§6、§11.2 | **部分实现／调整。** 已有 findings、decisions、输入原文及 bounded observation；Jev 会截断 instruction/basis/amendments并标示部分缺口。没有按工作单元整理的当前已确认事实、开放问题与决定来源视图。 | 在现有记录上生成简明可追溯当前状态；保留省略范围与按需回到原文的能力。推断不升级为用户要求，摘要不覆盖原始依据。优先解决实际交接遗漏，而非构造知识图谱。 |
| D07 | §5.3、§6、§8.2 | **部分实现／调整。** off_track/stuck 判断、过程检查、finding 纠正和 dispute／adjudicator 已有；stuck 指令明确禁止仅凭 elapsed 判卡住。独立检查提示要求核对实际材料，但没有通用事实真伪保证。 | 保留现有纠偏与具体证据复核。幻觉用来源核验，偏移用有效要求，遗忘用版本状态，越界用工具限制，各自落到对应证据；不能把一个无 finding 结果当四类问题都已解决。 |
| D08 | §5.1、§5.3、§11.3 | **架构选项／待验证。** Root 仍是既有 OMP 会话；程序记录 Root 型号，并给成员／检查者建议，没有按任务阶段调度顶级模型、切换 Root 或由程序直接编排原生 task 的控制器；Root 自主原生派发已经存在。 | 保留现有 Root 自主原生派发，无需用户逐次安排；在同次交付中闭合必要顶级模型判断、串行接力及实际效果。程序直接编排、专门调用或 Root 阶段选择按宿主和收益证据选定，涉及语义时同步合同／ADR，不以“另一期”推迟目标，不能把自然型号变化冒称已自动切换。 |
| D09 | §5.3、§9、§11.3 | **部分实现／调整。** 检查失败会换下一个未用过且可运行的 OMP 型号；重复 finding 提醒 Root 修复／提出证据争议／交用户决定（3674 行）。这不是执行成员的更强模型升级，也没有资源累计约束。 | 区分凭据／服务失败、输入不足和能力失败。能补事实或由合适模型修正的先内部处理；无新证据重复失败应升级或结束该路径，保留此前消耗。业务偏好、权限和无法内部解决的真实阻断仍可交用户，不把“少介入”变成无限自动重试。 |
| D10 | §5.4、§11.3 | **架构选项／待验证。** OMP 已提供 task/hub、目录、注册、只读 reviewer 和停止桥接；完整配置、usage、工作单元工具权限及部分 hook 覆盖仍有缺口。 | 暂无静态证据证明必须换宿主。先以实际缺口核对宿主 API，能补则补；若无法提供关键身份、资源、权限或停止证据，再比较替代方案。不给“从零设计”附加一次宿主重写。 |

## 6. 分层核验、完成与停止

| 编号 | 对应主文档 | 当前状态与源码证据 | 建议处理 |
| --- | --- | --- | --- |
| E01 | §6、§7、§12 | **已实现／保留。** [reviewer.ts](../../runners/omp-reviewer/reviewer.ts) 创建独立检查会话，只允许 read/grep/glob，核对禁用工具、实际模型与前后指纹；[confined-tools.ts](../../runners/omp-reviewer/confined-tools.ts) 拒绝路径逃逸、越界 symlink 和 URL／内部 URI。 | 复用这条实际只读链。模型请求网络本身仍需要，不把工具无 web/browser 夸称为整个进程无网络。新增候选也必须走同一安全门。 |
| E02 | §3.5、§7 | **已实现／保留。** runtime 的 `assess_jev` 按状态、产物、输入和成员变化签名去重；`start_check` 使用 observation key；在途检查只 poll。Root 工作中纯定时全量检查延后，手动终检等实际交付。 | 保留事件、有界冷却、定时兜底和不重复并发。成员结果／新事实应触发相关评估，不默认每个工具动作都做完整检查。 |
| E03 | §7、§11.2、§11.3 | **部分实现／调整。** 已区分 process/artifact 角色，也有程序身份、版本、指纹核对；但两类模型检查仍以固定工作区快照和任务上下文为中心，未形成可复用的“局部程序证据→相关语义检查→全局覆盖”分层链。 | 复用现有 runner，按明确检查范围组织局部证据和必要上下文，减少重复全量读取。最终仍核对整体要求与集成，不能用局部通过代替终检。分层收益需真实任务验证。 |
| E04 | §6、§7、§11.2 | **未实现／新增。** 检查 prompt 要求逐项核对原始要求，结果记录 delivery/findings，但未找到持久的要求 ID→证据→产物／输入版本→覆盖范围关系。 | 增加最小覆盖记录，区分程序可核对、模型已核对和未核验范围。验证回执必须关联具体要求与当前版本；没有 finding 不能填补未检查的要求。 |
| E05 | §3.5、§7 | **已实现／保留。** runtime 的 `finish_check` 核对输入／工作区／产物是否 stale，旧结果不获得当前完成资格；产物检查不因无关宿主变化作废，过程检查保留宿主版本约束。纠正和最终通知同样绑定版本。 | 扩展覆盖记录时沿用版本失效逻辑，增加相关依赖变更核对。历史有效检查是有范围的证据，不是新版本的永久通行证。 |
| E06 | §5.3、§7、§12 | **已实现／保留。** `completion_gate`（214 行）要求当前最终通知、无开放 finding／待核对线索、成员 settled 和清理可核验；`stop`（3279 行）在拆除前后核对，成员停止要求实际 idle tools 与 async jobs settled。 | 保留独立终检、Root 完成意图及真实停止门。低成本模型、无 finding、成员 status=done 或只发送 stop 指令，均不能替代实际证据；无法证明停止仍须如实显示。 |

## 7. 本路由成本、用量归属与效果验证

| 编号 | 对应主文档 | 当前状态与源码证据 | 建议处理 |
| --- | --- | --- | --- |
| F01 | §1.2、§9、§10“成本与未知退化” | **未实现／新增。** 精确缓存的 metrics 只有通用 value/unit/basis，cost_tier 是粗档。`numeric_metric?` 明确仅检查 cost.／quota. 前缀和数值形状，没有可信价格来源核对、币种、输入／输出分类、适用账户计划及可比条件的数据流。 | 增加最小本路由资源事实结构：来源、适用路由／计划、币种或额度原单位、分类规则、有效期及限制。官方规则、runtime usage 和账单观察分别存，不用 OpenRouter 报价补 OMP 实价，也不假设有 URL 就是真实成本。 |
| F02 | §1.1、§8.2、§9 | **旧规则／删除或替换。** 成员与检查者以 low/medium/high 粗成本排序；旧 `cost_appropriate` 允许按厂商定位作低置信估计。这个模型判断同时承接了资源比例适当性。 | 从新自动选择依据中移除无可信本路由支持的定位估价与粗档排行。历史粗档可保留解释，不能迁移成精确 token 价格。计算、换算与资源记录交程序；缺成本时明确条件性建议，不自动否决有质量依据的候选。 |
| F03 | §9 | **未实现／新增。** 当前没有根据可归属输入／输出／缓存／推理构成及真实价格计算工作单元成本、预测范围与实际结算的路径。 | 区分单价事实、可比较的用量假设、预测和实耗。输入／输出单价交叉且缺可信构成时标记总成本不可判定；有界历史同类用量可预测但须标不确定，不能由 Jev 编 token 或承诺预算内。 |
| F04 | §1.2、§8.3、§9、§11.2 | **未实现／新增。** [plugin_connection.rb](../../lib/orbit/plugin_connection.rb) 的 `events=[]`；runtime 仍监听 `thread/tokenUsage/updated` 写 Root 会话累计值（351 行），在当前 OMP 连接不会收到事件。宿主保存实际型号和原生会话文件，但没接 Root／成员逐调用 usage。 | 以宿主真实 usage 事件或可信调用回执接线，关联任务、工作单元、角色、成员与实际模型／路由。旧会话总数不能当任务消费；先建立调用归属再计算资源账本。跨型号 token 合计不得作为唯一优化目标。 |
| F05 | §9、§11.2 | **部分实现／调整，存在明确漏计分支。** Jev 有 provider/model/问题版本/usage 原始记录及分桶累计；但池内 `pending_candidates` 在 1340 行 return，1357 行 `accumulate_jev_usage` 只覆盖产生推荐的结果。入口和检查者选型的用量也没有汇入完整任务资源账本。 | 所有已发生判断均计入资源观察，包括未推荐、不可用且可能已计费的调用。对 pending 的现存 raw usage 可有据恢复，不能直接用当前分桶当完整消耗；去重避免恢复后重计。 |
| F06 | §9、§11.2 | **部分实现／调整，失败用量不闭合。** reviewer 采集 message_end usage，但到 `await session.prompt` 成功返回后才写 evidence.usage。OmpCheckRunner#poll 在失败时先 raise，usage normalization 在成功尾部（387 行）。runtime 虽保存失败 check 的可得 usage，实际失败链可能只得到 nil。 | 在请求异常、解析不合格及实际重试路径保留可得 usage 和调用身份；取不到标未知。失败不等于零消耗，不因没产生有效检查结果就排除计费，也不为获取账本而吞掉原失败。 |
| F07 | §6、§9、§11.2 | **部分实现／调整。** [session_summary.rb](../../lib/orbit/session_summary.rb) 明确 Root/member/task_total/currency_cost 为 nil，检查用量是可观察计数；[task_evidence.rb](../../lib/orbit/task_evidence.rb) 有任务证据与原生会话导出，但 Root 片段按创建／结束时间窗裁切，不是逐调用计费归属。 | 保留诚实 unknown 与缺证记录，扩展按真实调用 ID／任务归属的汇总和导出。检查完整性与全部任务资源完整性分开；不能仅按时间窗扣整段对话 token，独立问题可能落在同一窗口。 |
| F08 | §1.3、§9 | **范围已明确／调整。** runtime 有 hard_deadline，尚无货币／订阅硬预算；该事实保留。用户现明确不需要硬预算，因此其缺失不再是待实现能力；必要核验／升级的资源观察仍不完整。 | 不新增硬预算配置或准入／停止门。保留 deadline 等运行控制；核验与升级计入实际资源消耗，避免重复失败和无收益调用。成本未知允许明确条件性判断，不自动视为免费，也不预设无依据的额度保留百分比。 |
| F09 | §1、§1.2、§4、§11.3、§11.4 | **未实现／新增。** 当前报表能数检查、finding、纠正和成员，但没有同类交付下“顶级模型单独执行／当前 Orbit／新方案”的一致对照，亦无完整顶级资源与用户介入归属。 | 用同等验收要求比较有效工作量、实际顶级消耗、其他额度／现金、缺陷严重度、返工／升级及用户介入。校准样本与评价样本分开，评价标签不能仅来自系统自己的通过结果。先证明收益，再扩自动化。 |
| F10 | §11.4、§12 | **源码状态可确认；新方向未验收。** 当前版本、四条映射与旧门均可静态核对；[handoff.md](handoff.md) 的历史真实任务可证明特定旧路径。此次未运行模型、重跑测试或操作排队中的独立终检。 | 状态报告严格分开源码接线、确定性验证、动态目录审计、真实任务验收及发布／安装事实。0.7.10 不应被描述成已上线主文档全部行为，历史通过也不能证明新策略省额度或减少漏检。 |

## 8. 按依赖推进，而非一次重写

下面是同一次完整交付的实现与验证依赖，对应主文档 §1.3／§11；各步不是独立缩减交付，未闭合完整目标不能宣布完成。每步引用前述项目，不新增主文档外的实施义务。

| 顺序 | 对应主文档与项目 | 可审查的阶段结果 |
| --- | --- | --- |
| 1. 冻结新语义与事实资格 | §2.4、§3.6、§10、§11.1；A04、B05—B11、C05—C07 | 明确入口两类价值、任务指标、映射、证据冲突／日期未知、成本未知及放行范围；拟定问题与决策新版本。实施时先同步相关合同／ADR，不能用本文改变运行规则。 |
| 2. 接通候选事实并退出旧门 | §8、§10、§11.1；B02、B07—B09、C01—C04、F01—F03 | 成员和检查者能消费相关、可追溯事实；所有新选型路径不消费时间；无来源、无校准或成本不可判定的行为明确。未放行阶段事实展示与 Root 自选可先使用。 |
| 3. 闭合交接与资源观察 | §5.2、§9、§11.2；D02、D05—D06、E04、F04—F08 | 工作单元、要求、实际调用和结果可关联；已知消耗和未知范围可列出。已有登记、只读检查、修订、版本与停止门继续工作。 |
| 4. 真实校准与同质量对照 | §2.4、§11.4；C05、F09—F10 | 新题义有代表性真实样本、失败／缺证样本及范围明确的放行依据；同类交付能比较顶级资源与缺陷，不要求每个候选先拿成功证书。 |
| 5. 验证候选架构收益 | §5、§7、§11.3；D03、D08—D10、E03 | 在同次交付中验证串行、分层和必要顶级模型判断。保留 Root 自主派发；程序直接编排、Root 阶段选择或宿主调整按关键接缝与收益证据决定，先同步对应运行语义，不另推下一期。 |

资源观察不能无限推迟到“推荐能跑”之后，否则策略即使产生更多建议，也无法检验是否符合初衷。反过来，不必先做完所有预测、架构切换或全面评测平台，才能提供可信事实和有限范围的启发式建议。

## 9. 后续核验应回答什么

这些是上述变更的核验重点，对应主文档 §10、§11.4；本轮没有把它们写成已通过。

| 核验范围 | 对应清单 | 重点行为 |
| --- | --- | --- |
| 入口与消息归属 | A02—A07、C05—C06 | 明确请求、禁止、引用、低风险短改、审计交付、监督独立收益与串行交接；活动继续不重建任务，独立问题不改要求，无绑定继续不猜要求；新题义校准与动态能力审计分开。 |
| 指标和身份 | B02—B11 | agentic-only 可作为相关任务事实；intelligence 经清洗保存；成员真实 route 精确映射；检查者配置单独核对；目录上限不覆盖路由限制；冲突同时可见，测量日期未知不冒充新测量。 |
| 去时间与历史解释 | C01—C07、D03 | 分别覆盖池内、旧无目录、检查者、补证、状态及重用路径；性能数据不隐式进入新选择输入；旧字段按旧版本显示，运行超时／停止／缓存时效仍正常。 |
| 成本与失败观察 | F01—F08 | 跨输入／输出单价无构成时不判总成本；订阅保持原单位；Root／成员／选择／检查及失败重试均有归属或明确未知；pending Jev 不漏计；未知保持未知，不新增硬预算门。 |
| 交接和安全闭环 | D02、D04—D09、E01—E06 | 选择对应实际工作单元；修订和依赖使相关证据失效；成员结果与实际身份相符；工具限制真实生效；局部检查不替代整体覆盖，升级不清零消耗，完成仍核对真实停止。 |
| 实际效果 | F09—F10 | 同等验收、独立一致评价和实际消耗；观察四类问题的误报／漏检、顶级额度与用户介入变化。不同项目历史 token 数不直接作省成本结论。 |

现有 [prestart_test.rb](../../tests/prestart_test.rb)、[jev_advisor_test.rb](../../tests/jev_advisor_test.rb)、[task_runtime_test.rb](../../tests/task_runtime_test.rb)、[checker_model_selector_test.rb](../../tests/checker_model_selector_test.rb)、[checker_model_selection_test.rb](../../tests/checker_model_selection_test.rb) 及原生 gate／reviewer 测试可复用为确定性接线验证。它们目前包含旧题义、时间门和旧排序断言，不能当成新方案验收。只修改相关高价值断言；实时目录数值与价格做当次审计，不固化成稳定单测。

## 10. 主文档覆盖索引与审视限制

| 主文档条款 | 附属清单对应项 |
| --- | --- |
| §1、§1.1、§1.2：用户目标、去时间、分资源核算 | B02、B13、C01—C04、F01—F04、F08—F10 |
| §2.1—§2.4：先验、启发式判断与机制校准 | B02—B04、B10—B12、C03、C05—C06、F09 |
| §3.1—§3.6：三种唤起、入口、继续与任务内调用 | A01—A08、C05—C07、D03、E02、E05 |
| §4：能运行不等于有效节省 | F04—F09 |
| §5.1—§5.4：责任、工作单元、闭环和宿主选择 | B01、B11、D01—D10、E06 |
| §6：幻觉、偏移、越界、遗忘 | A06、D01—D07、D09、E01、E04、F07 |
| §7：分层检查、范围与最终覆盖 | E01—E06、F09 |
| §8.1—§8.3：指标、具体问题、分层身份 | B01—B12、C02、C04、D02、D04、D07、F01—F04 |
| §9：成本、预测、未知退化与资源预留 | D09、F01—F08 |
| §10：原六项审查要求 | B05—B11、C01—C07、F01、F04、F08；详见下表 |
| §11.1—§11.4：实施次序与真实效果 | A04、B02、B12、C05—C07、D01—D03、D06、D08—D10、E03—E04、F04—F10 |
| §12：0.7.10 已有与未完成 | A01、B02、B13、C01、E01、E06、F10 |

| 原六项 | 当前结论与清单 |
| --- | --- |
| 真实路由与映射 | 尚未闭合；B05、B06 |
| 成本与预算 | 尚未闭合；F01—F08 |
| 指标接入 | 部分存储、未完成任务相关输入；B02、B07—B09 |
| 去时间信号 | 未完成，成员与检查者活跃路径均仍有；C01—C07、D03 |
| 冲突与时效 | 抓取 TTL 已有，测量资格与冲突复核未闭合；B10、B11 |
| 新判断放行 | 有旧入口校准，不是新题义依据；C05、C06、F09、F10 |

本次读取范围覆盖入口、Jev、候选池与证据缓存、OpenRouter、成员宿主与连接、任务记录／运行控制、独立 reviewer、状态／报表／导出，以及相关合同、说明和测试源码。对其中 83 个基线文件保存并复核了内容摘要，写入本文前未发现审视过程中发生变化；源码位置仅对本次工作区有效。

这是静态调用链审视，并补做了 A03 的本地分类函数核对，不是一次新的 Orbit 独立终检或真实模型验收。未重新访问供应商确认动态价格／指标，未读取私有凭据，未运行模型或重跑现有测试，未操作当前排队的独立终检。“未实现”指在上述相关生产链中未找到行为，不据此宣布宿主底层永远不可能支持。

本轮交付只有本附属文档；代码、主文档、合同、ADR、产品版本与既有工作区修改均不由本轮改变。

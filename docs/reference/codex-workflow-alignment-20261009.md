# Codex 工作机制与 Orbit 防偏航对照

2026-10-10 补注：最新候选充分性与既有取舍沿[全部决定重评](codex-decisions-reevaluation-20261010.md)。本页已经覆盖 Goal runtime／模板等源码事实，重评不将其误称为此前未读；修正的是实施取舍与实际交付证据之间的差距。

前轮状态更新（历史）：用户随后正式授权前轮实施，前轮实际 Goal complete、其交付条件已完成；C01及全部采用项的实施／验收沿[唯一总清单](../plan/codex-lessons-implementation.md)，证据沿[本轮验收](codex-lessons-acceptance-20261009.md)。2026-10-10 新轮 Goal 已实际启动并最终complete；剩余能力按唯一总清单 §9 接续。下文“先落文档／未实施”保留研究阶段事实，不覆盖本轮状态；未宣称经济收益。

研究日期：2026-10-09。用户指出 Codex 的多种工作模式值得借鉴，Goal 只是例子；本页按完整工作流程评估规划、执行、目标续跑、修订、中断、评审、工具授权和上下文恢复。后续按 Orbit 核心诉求再审，补充实质工作交接、监督开销及纠正落实，避免将防偏航收窄为更多状态门。

证据为 Codex 固定提交 [`36ae1561b9324c93d5638b45eb19fe2cc070a581`](https://github.com/openai/codex/commit/36ae1561b9324c93d5638b45eb19fe2cc070a581)、[官方 Goals 指南](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)及 Orbit 0.8.3 当前合同/相关实现。源码副本只读，没有运行 Codex 或模型验收；以下建议尚未采纳为产品决定，也没有启动实现 Goal。此前确认的[上下文文档范围](../plan/context-compression-proposal.md)继续独立有效。

## 从交付目标理解防偏航

Orbit 的完整诉求及这组材料的筛选依据统一放在[源码研究：从 Orbit 的诉求筛选](codex-source-lessons-20261009.md#从-orbit-的诉求筛选而不是从-codex-的功能清单排期)，来源为已认可的产品主方案。防偏航服务于可靠交付、有限顶级模型资源和减少用户介入：既要避免错误方向，也要在未完成且具备继续条件时推进，纠正后落实到真实成果。[任务合同](../../contracts/task-runtime.md#程序与模型)定义程序控制与模型判断的分工。

现有 [JevAdvisor](../../lib/orbit/jev_advisor.rb) 的 `off_track` 判断近期工作是否偏离最新有效要求，`stuck` 判断是否缺乏有用进展；这些是有界语义信号。过程检查不能完成任务；独立产物检查、逐项要求覆盖、有效手动终检和实际停止仍各有门。[检查规则](../../lib/orbit/omp_check_runner.rb)、[要求覆盖](../../lib/orbit/requirement_coverage.rb)与[合同](../../contracts/task-runtime.md#观察与完成)是对应来源。

程序可约束身份、版本、工具权限和状态转换；工作是否真实推进目标、产物是否满足要求仍需要证据与语义核验。两个方向都要考察：错误完成是否被阻止，以及合法执行是否被误阻断或需要用户催促。模型、提示和独立检查都不提供绝对正确保证。

## Codex 的各机制怎样配合

固定提交中，内置 collaboration mode 预设是 Plan 与 Default；Goal 是持久目标扩展，Review 是任务类型，Guardian 是动作授权审核，update_plan 是进度工具。它们位于不同层，不应为 Orbit 机械增加同名的一组互斥模式。[预设源码](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/models-manager/src/collaboration_mode_presets.rs)、[任务类型](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/state/turn.rs)

| 机制 | 主要防止的问题 | 对 Orbit 的借鉴位置 |
| --- | --- | --- |
| Plan / Default | 把方案讨论当成执行，或执行阶段持续停在规划 | 明确当前授权阶段；阶段切换与权限分开核对 |
| Goal 与续跑提示 | 回合结束后丢失目标、擅自缩小完成范围 | 在现有任务状态注入中核对有效目标、未完成要求及下一动作 |
| 原生成员与配置/上下文继承 | Root 重复执行全部工作，交接后丢失约束 | 成员承接实质工作，Root 保留集成责任；沿现有工作单元与模型适配，见 §7 |
| 用户输入与目标修改 | 自动续跑抢在纠正前执行、旧回合继续追旧目标 | 复用原生消息来源、amend、版本失效及安全投递门 |
| update_plan | 用户看不到步骤进展，或把勾选步骤当已交付 | 步骤状态服务可见性，完成依据继续来自实际产物与验证 |
| Review | 执行者的自述主导核验，检查对象与执行对象混杂 | 继续保持独立会话、固定快照及只读工具，明确检查结果范围 |
| Guardian 与工具权限 | 自主执行把任务范围或授权理解过宽 | 程序可计算约束先强制；复杂动作政策与交付质量分别判断 |
| Compact / resume / subagent | 历史摘要、旧阶段或父会话授权污染当前执行 | 保留来源、当前状态和继承边界，恢复时重投影必要事实 |

## 1. 阶段边界：规划和执行不能由模型自行混淆

Codex 的 Plan/Default 模板明确各自行为和退出条件，Plan 要求非实现性探索、澄清和产出方案。`update_plan` 不负责进入/退出 Plan；其 handler 在 Plan 模式拒绝调用。自动发起回合的 Core 准入也拒绝在 Plan 下执行或自行切出 Plan。[Plan 模板](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/collaboration-mode-templates/templates/plan.md)、[Default 模板](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/collaboration-mode-templates/templates/default.md)、[进度工具 handler](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tools/handlers/plan.rs#L86)、[自动回合准入](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/session/turn_input.rs#L70)

模板对不写文件的要求属于模型指令，其自身不等于所有工具已在执行层强制只读。可计算的自动回合准入才是已读源码中的程序约束。

对 Orbit，应先对照“先讨论”“先落文档”“已经授权实施”等真实输入怎样进入有效要求和下一动作，而不是直接照搬 Codex 必须由 developer message 切换的客户端协议。Orbit 用户明确指令及 OMP 实际权限仍优先；实现阶段合法的调研、测试和诊断也不能机械判为偏航。当前仓库开发流程中的阶段纪律不证明 Orbit 产品已具备一个正式阶段状态机。

授权阶段与模型阶段选择也要分开：规划/执行回答“当前允许做什么”，现有 Root 的 execution/integration/diagnosis 型号选择回答“由什么能力承担当前工作”。不能用模式名称替代真实授权，也不能因为进入规划就强制调用顶级模型或增加一次用户确认。

## 2. 持久目标：保持完成标准，并要求对证据逐项核对

Codex 的 Goal 状态存储 objective、身份、状态和用量；续跑模板再次提供目标，要求保持完整范围，把上一轮分为有进展、确实等待或无进展，并在结束前对目标逐项找当前证据。目标不能为了让已有测试通过而缩水；剩余困难不能由一份漂亮答复冒充完成。[状态模型](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/state/src/model/thread_goal.rs)、[续跑模板](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/templates/goals/continuation.md)

**关键限制：**已读 `update_goal` 路径校验可接受状态、结算用量并更新持久状态，调用参数没有逐项产物证明，处理器没有调用 Orbit 式独立交付检查。完成审计要求主要由模板和工具描述约束模型，不能将 Goal complete 等同于独立验收通过。[tool.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/tool.rs#L247)

对 Orbit，值得借鉴的是简洁、明确的目标重锚与证据审计要求。现有 [statusBlock](../../plugins/omp-host.mjs) 已提供阶段、问题、下一动作和修订纪律，独立终检已有覆盖门；先核对该注入在长回合、压缩、续接时是否仍足以让 Root 看到完整有效目标。摘要必须由任务记录派生并可追溯，不另建会与原文/amend 竞争的目标权威，不增加一套 Goal 状态替代现有完成门。

目标重锚应同时说明整体要求与当前有界交付的关系。任务相关进度追问、暂停后的新边界或成员回报，不能把“回答这条消息”“这单已完成”替换为原始整体目标已交付；当前任务确实通过时也不因此否定其有界完成。原文覆盖与可追溯归属负责区分两者，详见[现场观察的多任务归属问题](beacon-orbit-observation-20261008.md)。这属于现有语义的核对点，不新增跨任务 Goal 数据库。

## 3. 自动推进：有准入条件，用户修订优先

Goal runtime 在持有目标状态 permit 时读取持久目标并申请 `start_turn_if_idle`，限制目标修改与自动启动之间的竞态。Core 检查活动回合、待处理触发消息、Plan 状态和服务准入；目标编辑另有新的 steering 提示。源码还处理连续空回复与真实执行失败，避免某些失败自动循环。[runtime.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/runtime.rs#L425)、[turn_input.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/session/turn_input.rs#L471)、[更新目标模板](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/templates/goals/objective_updated.md)、[accounting.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/accounting.rs)

有工具调用不证明目标推进，单轮没有写文件也不证明无进展；调研获得改变下一动作的证据、轮询已证实活跃的工作也可能是有效推进。Codex 的具体空回复/执行失败计数不应变成 Orbit 对所有阻断的统一次数门，Goal 的预算控制也不产生 Orbit 新的预算授权。

对 Orbit，优先核对纠正已经输入但尚未提交 amend、检查在途、Root 空闲、停止与续接等边界的次序。现行合同已经要求有效修订版本化、独立问题保留归属、Esc 当下停止、后续任务相关输入以新边界续接；不照搬 Codex 的暂停/恢复方式改变 D1。未来有真实空转证据时，先改进事实投影与对应恢复动作，再考虑增加规则。

**评估自动推进应沿完整反馈链。** 当前版本/授权/停止事实 → 选择可执行下一动作或明确等待对象 → 原生通知实际接受 → Root/成员下一次相关动作 → 新结果重新核对。每个环节复用现有记录；消息已发、模型说理解或检查拒绝完成，都不等于纠正已经落实。已有长任务修复的通过范围沿[验收记录](long-task-optimization-acceptance-20261009.md)，不重复列成新缺陷。新增问题应指出链上实际断点，无须另建调度器或高频检查来证明系统在工作。

## 4. 进度与评审：步骤完成和任务通过分别有依据

Codex 的 update_plan 提交步骤和状态并发出 PlanUpdate 事件；已读 handler 不核查步骤对应产物。Review 则启动单独委托会话，设置 review rubric、选定 review model，并关闭部分协作/搜索功能。[plan.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tools/handlers/plan.rs)、[review.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tasks/review.rs)

这说明进度可见性与专项检查可以分别组织，不能据 Review 名称就推断它具备 Orbit 的固定快照或同等只读边界。对 Orbit，Root 的 TODO 服务执行组织；成员 accepted、检查无 finding、交付 ready、终检通过和实际停止分别保留语义。现有整体要求覆盖不能降为只看 diff，也不能只核对当前计划里剩下的步骤而漏掉原要求。

## 5. 动作授权：与交付质量分开处理

Guardian 的决策路径将具体动作、政策、执行上下文和审核原因传入决策扩展；回调结束后再次核对取消状态，即使缓存结果返回也不能忽略已发生的取消。审核范围分别覆盖 shell、文件修改、MCP、网络与权限。[decision.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/guardian/decision.rs)、[coverage.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/guardian/coverage.rs)

对 Orbit，工作单元工具/路径/命令门继续负责可计算范围；独立检查负责交付正确性和多做。动作获准不说明任务完成，检查者指出问题不扩大执行权限。可借鉴异步审核结果应用前重读有效授权/停止状态的做法；当前没有依据为每次工具调用再增加一个付费审核模型或用户批准环节。

## 6. 恢复上下文：当前事实有来源，旧历史保持历史性质

Codex 的模式上下文使用带 hash 的 snapshot 比较，只在有效内容改变时渲染更新。用户 Goal 修改片段需要宿主 provenance 标记，匹配文本外壳本身不能成为真实用户修改；超长目标在该有界证据片段中整体省略并标记，而不截成可能改变授权含义的片段。[collaboration_mode.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/context/world_state/collaboration_mode.rs)、[user_goal.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/context/user_goal.rs)

对子成员继承、compaction 与恢复的既有对照见[源码研究 §6/§8](codex-source-lessons-20261009.md)。Orbit 的完整要求仍另行提供，不能因 Codex 此证据片段的局部容量限制就截掉 Orbit 原文。增量重点是来源标记、失效处理和恢复后重投影当前目标/阶段；提示去重是否可用需沿 OMP 真实请求路径核对，不假设 Codex 的 world-state 接缝可直接移植。

## 7. 模型分工：责任连续，能力按需要投入

Codex 的成员配置、历史继承、创建失败清理与结果归属已在[源码研究 §8](codex-source-lessons-20261009.md#8-subagent-派发配置上下文创建失败与回报归属)列出。它们可改善派发可靠性，但该源码证据不足以证明 Orbit 的异构模型经济收益。

Orbit 的核心增量仍沿[主方案 §4/§5](../plan/mixed-model-delivery-proposal.md)和[ADR-009](../adr/009-user-selected-model-pool.md)：根据任务适配、真实可运行资源和用户偏好选成员；可串行交接；Root 持续负责整项集成与交付。成员应承接实质工作，Root 做必要核验，避免亲自完整执行后再派发同一工作，或把任务拆得过细造成交接开销。强模型按需求用于困难诊断、低可验证性成果和必要整合，不强制常驻所有步骤。

现有 Root 阶段型号选择已接线，真实效果与未测边界按 ADR/交接记录解释；这次研究不把它重新列作待建能力。父型号默认、角色名称、完整历史 fork 都不替代实际型号和资源核对。实际失败先区分输入、权限、环境、账户或质量问题，再采取对应恢复或升级动作，换强模型不能解决所有阻断。

## 8. 监督投入：在相关变化处判断，保留仍有效证据

Codex 的安全续跑准入、带版本的上下文更新、确定性工具控制值得借鉴；对 Orbit 的推论是让程序规则和有界事实投影承担能确定的工作，把模型判断用于可能改变下一动作的节点。该推论来自 Orbit 的产品目标，不是 Codex 已证明的省钱效果。

现有去重、在途检查门、过程检查、独立产物检查和最终要求覆盖继续各司其职。相关修订、代表性成果、重复失败或证据冲突可以触发判断；用户轮询和时间流逝本身不增加模型调用。过程判断不是对每次动作再审一次，最终整体覆盖也不意味着每轮重读全部历史。复用有效证据须保留其适用版本与范围，相关变化才失效，不能借增量省掉终检中的原要求。

收益观察包含：用户是否仍需催办/纠偏、纠正是否落实、遗漏与误报是否改善、成员是否替代 Root 工作，以及实际调用、失败/过期和可得资源。无 finding 不证明无价值，调用更多也不证明监督更有效。不同角色/模型的 token、套餐单位和现金分别记录，未知保持未知；完整交付耗时可作体验事实，不恢复已撤销的型号速度评分。局部改动只验证对应行为，不追加整套通用评测或资源硬预算。

## 建议按实际缺口评估的接缝

1. **目标、阶段与下一动作的一致性。** 对照现有状态注入、有效要求及工作单元，在真实入口核对“先文档”与“已授权实施”等差别；复用已有状态，不先新增模式平台。
2. **修订与异步动作的次序。** 投递、续跑或应用审核结果前核对最新版本与停止事实，依赖宿主原子接收能力的部分明确列出接口缺口。
3. **完成审计保持独立。** 借鉴明确逐项证据要求，继续沿原文覆盖与现有终检门；不以 Goal 状态、TODO、成员自报或绿色测试替代整项交付。
4. **压缩/续接/成员交接都保留来源。** 使用已确认上下文方案和既有归属规则；先修真实丢失点，不重复存一套目标或用模型摘要取得授权。
5. **交接和监督确实帮助交付。** 核对成员实质工作替代与必要复核、通知后的真实动作，以及重复判断/误阻断成本；复用现有模型阶段与观察接缝，不先建更多模式。

后续若进入实施，验证应围绕具体用户行为：只授权讨论/文档时是否进入实现；中途纠正是否让旧动作失效；压缩或续接后原范围是否仍完整；部分测试通过但原要求未齐时是否继续保持未完成。选择范围后冻结验收，不因上述研究额外重开已完成 T01—T13 或全部历史未测分支。

用户后续要求补齐实施依据，已将这些核对点接入[总实施清单](../plan/codex-lessons-implementation.md)：逐项现状与处置、采用条件、宿主信号、依赖、协作热点和真实验收范围在该处维护。本页继续保留研究事实与设计理由，不成为第二份执行 TODO。

本轮仅补充源码研究和索引，没有改产品合同、运行代码、版本或安装，没有提交推送，也没有启动 Goal 或真实模型任务。

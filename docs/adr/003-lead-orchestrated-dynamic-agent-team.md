# ADR-003：Lead 编排的动态 Agent Team 与上下文治理

- 状态：Accepted（Orbit v2 目标架构；尚未实现）
- 日期：2026-07-28
- 决策确认：2026-07-30
- 范围：Agent team 拓扑、上下文生命周期、任务偏移、代码健康与结构质量审查
- 当前实现状态：仅为设计结论，尚未修改 Orbit CLI、schema、配置或运行时
- 切换约束：[ADR-005：Orbit v2 一次性切换与旧协议退役](./005-orbit-v2-clean-cut-and-legacy-retirement.md)
- 编排控制 amendment：[ADR-006：串行 Lead 编排与控制循环](./006-serialized-lead-orchestration-control-loop.md)；如本文旧表述与 ADR-006 冲突，以 ADR-006 为准
- Agent-independent control amendment：[orbit-v2-agent-independent-control-amendments](../open/orbit-v2-agent-independent-control-amendments.md)（owner approved 2026-08-11）；决策九与 ADR-004/006 中对应条款由此引入

## 决策定位与验证边界

本 ADR 是 Orbit v2 重构的父架构决策，不是可选实验插件。项目 owner 已确认：Lead 编排动态团队、bounded work unit、可替换 session、分层上下文和独立 gate 的组合已经在实际项目中验证，因而本 ADR 接受这些方向作为 Orbit v2 的设计底座。

实际项目材料和量化数据不在本仓库中，本 ADR 不据此虚构项目名称、样本量或收益数字。已有验证支持的是架构方向，不自动证明任意字段设计、固定阈值、存储技术或 Orbit 当前实现细节。Orbit 自身仍需通过 dogfood 验证具体 schema、CLI、投影和运行成本。

Accepted 表示目标架构已经确定，不表示当前 v1 runtime 已经具备这些能力。在 v2 完成一次性切换前，现有 CLI、schema 和 runtime reference 仍按当前实现解释。

### 2026-08-03 amendment：dynamic team 不表示并发执行

项目 owner 于 2026-08-03 进一步批准 ADR-006。本文的 dynamic team 只表示 AgentInstance 可按需创建、替换或终止，LeadSession/context 可重建，capability profile 可随 WorkUnit 选择。稳定串行 identity 是 ADR-006 的 project-scoped `lead_control_id`；Lead runtime 只是其当前可替换执行载体。

同一 `lead_control_id` 可以持有多个 Task，但任一时刻最多一个 active LeadSession、一个 active Task、一个 selected WorkUnit 和一个 non-terminal WorkUnitAttempt。implementation、review、test、research 和 release 全部串行；Attempt terminal 后必须先产生 accepted LeadCheckpoint，才可 dispatch 下一 Attempt。不同 `lead_control_id` 只有 task ownership sets 与 provider-verified active runtime subject sets 都 disjoint 时才可并行，不同 project 可独立并行。本文涉及 control genesis、Task/executor ownership/transfer、LeadSession lifecycle、自检、proportionality、successor 或 task switching 的细节均由 ADR-006 统一规范，避免本文成为第二套控制权威。

## 背景

实际使用中观察到两类问题。

第一类是任务偏移。执行 agent 在开发、分析或修复过程中发现局部问题，经过多轮处理后，逐渐把局部问题当成主任务，原始目标、非目标和剩余验收项被弱化。

第二类是过程产物进入正式产物。例如正式源码出现 `xxx-P6-xx.ts`、`xxx-slice1-xxx.ts`，或验收、审查、阶段性编排代码被提升到正式目录，同时保留了设计阶段、路线图阶段或开发过程中的命名。已有案例表明：

- `P6` 由本轮任务语言直接引入。任务持续使用 “P6 fresh root”“P6 host”“P6 evidence”等表达，执行者在把验收流程提升为正式实现时，也把这些阶段词汇带入了正式类型和 API。
- `Slice1` 属于既有技术债。本轮没有创建该命名，但执行者受现有代码影响，把“一致”误判成“长期合理”。
- 主 agent 的审查重心集中在调用次数、预算、恢复、权限、隐私和 provider 边界，没有完整检查新增文件、导出符号和 public API 的长期语义。
- 约 5000 行的变更按数据流和风险边界进行抽查，没有形成对整个新增生产表面的完整审查。

命名错误只是这一问题最容易观察的表现。相同的偏移还可能作用于：

- 模块分类：为了关闭当前问题，把代码放入不符合长期职责的正式模块或层级；
- 抽象设计：把单个案例、临时协议或当前修复路径提升为通用 abstraction；
- 代码整洁：不断叠加分支、wrapper、fallback、状态和配置，使局部问题转化为长期复杂度；
- 限制范围：因为一个局部失败而引入全局限制、名单、过滤器或拦截层，但没有证明收益与影响面相称；
- 依赖方向：为了让当前链路快速通过，建立不应长期存在的跨层依赖或新的事实源；
- 维护成本：为收益较小、证据不足的方向投入大量代码和审查成本，并因沉没成本继续强化该方向。

因此，不能把该问题缩减为 naming lint 或“正式源码词汇审计”。真正需要审查的是：当前方案是否仍然服务原始目标，结构选择是否正确，新增复杂度和限制范围是否与被证明的收益相称。

这些问题最初被概括为 coding agent 的长上下文问题。进一步讨论后的结论是：长上下文是重要放大器，但问题范围不能只覆盖 coding，也不能只靠缩短对话解决。

## 外部证据与适用边界

长上下文和多轮交互风险具有外部实证支持：

- Microsoft Research 的 ICLR 2026 Best Paper 对超过 20 万次模拟对话进行分析，被测模型在多轮任务中相对单轮完整指令平均下降 39%。主要退化表现为早期形成错误假设、过早生成方案，并在后续对话中过度依赖已经走偏的方向。公开任务包含 Python 编程。该研究使用模拟对话，不能直接证明真实仓库 agent 应在固定轮数后重启，但足以否定“只要上下文窗口装得下就可以可靠使用”的假设。[论文说明](https://www.microsoft.com/en-us/research/publication/llms-get-lost-in-multi-turn-conversation/)，[实验仓库与限制](https://github.com/microsoft/lost_in_conversation)
- TACL 2024 的 “Lost in the Middle” 发现，模型对长上下文中信息的利用受位置影响，关键信息位于中部时性能可能显著下降，即使模型名义上支持长上下文。[论文](https://aclanthology.org/2024.tacl-1.9/)
- Anthropic 的工程实践把 compaction、结构化笔记和 sub-agent 作为不同场景下的上下文治理手段，而不是给出“一律保留对话”或“一律重启 agent”的单一答案。这是供应商工程经验，不是独立对照实验。[工程实践](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)

大变更审查风险也有软件工程证据：

- Google 对 900 万次 code review 的研究指出，变更规模增加时，有用评论数量下降，review latency 上升；其数据中的变更中位数为 24 行。[ICSE 研究](https://research.google/pubs/modern-code-review-a-case-study-at-google/)
- Google 的 code review 实践认为 100 行通常是合理规模、1000 行通常已经过大，同时明确反对把行数当成唯一机械阈值；删除、生成代码和自动重构需要区别判断。[Small CLs](https://google.github.io/eng-practices/review/developer/small-cls.html)

这些资料能证明风险存在，不能证明 Orbit 应采用某个固定 token、轮数、修复次数或 diff 行数。具体阈值必须通过 Orbit 自己的可复现实验和运行数据确定。

关系化检索和图式工作流提供了另一类设计启发，但现有材料不支持“Graph Engineering 已经替代 RAG”这一宽泛结论：

- Microsoft GraphRAG 仍然是一种 RAG。它针对传统向量检索难以回答的全局语料 sensemaking 问题，先构建实体关系图和社区摘要，再用于查询；论文没有证明所有检索、agent 记忆或任务编排都应迁移到知识图谱。[Microsoft GraphRAG 论文](https://www.microsoft.com/en-us/research/publication/from-local-to-global-a-graph-rag-approach-to-query-focused-summarization/)
- ChatP&ID 报告的 18% 准确率提升来自与原始图片输入的比较，85% token 降低来自与直接摄取智能 P&ID 文件的比较，适用对象是工程流程图，不是通用 agent 工作流或普通 RAG。[ChatP&ID 论文](https://arxiv.org/abs/2603.22528)
- DSPy 把 LM pipeline 表达为可优化的计算程序，STORM 把研究过程拆成有来源约束的多阶段工作流；它们支持“模型只是受控流程中的节点”，但不是知识图谱优于其他存储或检索方式的证据。[DSPy 论文](https://arxiv.org/abs/2310.03714)，[STORM 论文](https://arxiv.org/abs/2402.14207)
- 一项知识图谱工程 scaling law 研究总体上仍观察到模型规模效应，同时发现部分任务存在平台期和局部反常；它不支持“正确的图每次都胜过更大的模型”这一绝对判断。[KGE scaling law 论文](https://arxiv.org/abs/2505.16276)
- Anthropic 的 LaunchNotes 案例报告了 5 倍 incident identification 和 50% meeting time reduction，但这是单个客户的自报结果，而且其中的 `Graph` 是连接 GitHub、Jira、Linear 等工程数据的产品名，不能当作 GraphRAG 或知识图谱的对照实验。[Anthropic 客户案例](https://www.anthropic.com/customers/graph)
- LLM 可以辅助关系抽取，但现有 benchmark 明确指出零样本知识图谱生成仍不适合作为无人审查的生产事实源。[LLM-KG Benchmark](https://arxiv.org/abs/2308.16622)

触发本次讨论的[二手文章](https://glean.smartcoder.ai/a/graph-engineering-replaces-rag-insights-from-microsoft-stanf-87sb2s#row-1)把知识图谱、计算图、研究工作流图和名为 Graph 的工程产品合并成同一个趋势，且改变了部分实验的比较基线。它可以作为发现资料的线索，不能作为 Orbit 选型或收益估算的权威证据。

这些资料对 Orbit 的有效启发是：线性对话和孤立文档之外，可以建立带来源的显式关系，用于恢复目标、裁剪上下文和审计因果链。它们不能证明 Orbit 需要图数据库，也不能证明图中的关系天然正确或天然代表因果。

## 问题判断

### 长上下文不是唯一根因

两个案例属于同一个架构问题族，但直接机制不同：

| 问题 | 直接机制 | 长上下文的作用 |
| --- | --- | --- |
| 局部修复取代主任务 | 子问题缺少结构化父子关系、退出条件和返回点 | 放大近期问题的显著性，使 agent 更难恢复到主目标 |
| `P6` 进入正式命名 | 过程语言被直接当成产品语言，验收任务被产品化 | 不是必要条件，第一轮实现也可能发生 |
| `Slice1` 被继续沿用 | 既有实现产生锚定，“已有且一致”被误判为“长期合理” | 关系较弱 |
| 局部失败触发全局限制 | 当前失败样例被误当成稳定问题全集，修复范围超过已证明的风险面 | 修复轮次越长，越容易把当前路径合理化 |
| 模块或抽象被错误提升 | 临时实现因“已经写完”或“需要正式落点”获得长期架构地位 | 历史实现和沉没成本持续强化原选择 |
| 低收益方向产生大量代码 | 缺少收益、复杂度和 blast radius 的比例性复核 | 长链路让 agent 更关注如何完成方案，而不是方案是否仍值得完成 |
| 5000 行变更漏审 | review surface 不完整，审查按高风险路径抽查 | 增加认知负担，但不能单独解释审查策略缺口 |

共同根因是：

> 对话、局部问题、阶段计划和现有代码影响了当前决策，但 Orbit 没有把主目标权威、工作单元边界、动态团队责任和完整审查表面做成可恢复、可验证的控制结构。

### 问题范围不限于 coding

任何持续持有局部上下文并产生权威输出的 agent 都可能发生类似偏移，包括：

- researcher 把某条证据线索扩展为研究目标；
- designer 把临时探索方案固化为产品概念；
- planner 把某个拆分阶段误当成最终架构；
- coder 把修复链路或验收任务产品化；
- reviewer 受作者叙事和既有命名锚定，漏掉语义问题；
- tester 反复围绕当前失败样例优化，而忽略原始用户路径；
- release 或 operations agent 把临时发布步骤固化为长期运行机制。

因此，后续设计对象应从 `coding agent` 改为所有由 lead 委派的 `work agent`。

## 决策一：不建立“控制面词汇防火墙”

Orbit 不使用过程词汇枚举、黑名单、白名单或正则命中作为命名正确性的主要边界。

原因包括：

1. 无法枚举所有错误命名。错误可能来自路线图编号、任务昵称、实验代号、临时目录、审查术语、测试 fixture、聊天措辞或既有技术债。
2. 同一个名称在不同上下文中的合法性不同。例如 `phase` 可能是稳定业务状态，也可能只是开发阶段；`P6` 可能是正式外部协议版本，也可能只是本轮路线图编号。
3. 词法命中无法判断抽象是否稳定、职责是否属于正式产品、阶段结束后名称是否仍然成立。
4. 词表会随发现的问题持续增长，最终形成只能修已知案例、无法覆盖同形态错误的补丁系统。

静态扫描可以用于发现候选项，但只能提供审查线索，不能单独产生 pass 或 fail verdict。

### 替代方案：上下文相关的代码健康判断

命名判断只是代码健康判断的一部分。正式产物的审查对象不是某个词，而是整个方案在当前产品和架构上下文中表达了什么长期责任、引入了什么成本、改变了多大范围。

对新增或被提升为正式产物的文件、模块、公开类型、API、配置键、持久化字段、限制策略和 abstraction，reviewer 应结合以下上下文判断：

- 它表达的是用户、业务或稳定技术协议中的长期概念，还是当前任务的执行过程？
- 路线图阶段、实验或验收结束后，这个名称和职责是否仍然成立？
- 如果维护者没有读过当前 task、聊天和实施计划，能否仅通过产品语境理解它？
- 它是否因为被放入正式目录而获得了不应有的产品权威？
- 相邻代码的同类命名是稳定领域语言，还是尚未偿还的既有技术债？
- 当前抽象是从产品能力推导出来的，还是把验收脚本、审查流程或任务拆分直接产品化？
- 当前模块是否是该责任的长期归属，还是仅因为调用方便或原目录“不够正式”而被选择？
- 新 abstraction 是否覆盖了多个已证明的稳定变化点，还是只把一个当前 case 包装成通用接口？
- 新增分支、状态、配置、fallback 和依赖是否改变了系统性质，还是只转移或隐藏了当前问题？
- 限制的 blast radius 是否与已证明的问题集合一致；局部失败为什么需要全局策略？
- 如果不考虑已经投入的实现成本，当前方案是否仍然是解决原问题的最小充分机制？
- 预期收益、兼容性损失、误拦截风险、维护成本和验证成本是否有对应证据？

审查结论必须引用当前产品上下文、源码边界、长期职责和可验证的收益。不能仅以“仓库里已经有类似结构”“保持一致”“测试全绿”“架构门通过”或“没有命中禁用词”作为充分证据。

这里仍然可以生成完整的 production change surface，帮助 reviewer 确认没有漏看新增、重命名、移动和职责提升；但完整 surface 只解决覆盖问题，模块、抽象、复杂度和限制范围是否合理，仍然需要上下文相关判断。

上述问题不是一个封闭检查项枚举。它们是 reviewer 构造反例和追问因果关系的入口，不能演变成另一套声称穷尽所有错误的 checklist。

## 决策二：Agent Team 改为 Lead 统领的动态层级

当前 role 是可扩展 archetype，coder 也可以由 lead 兼任；真正的限制是 role/instance 主要来自静态配置，缺少 task 级动态 roster、agent lifecycle 和 work unit assignment。这个静态执行拓扑不再作为目标形态。

目标形态是：

```text
logical lead
├── work agent: research / exploration
├── work agent: design / planning
├── work agent: implementation / diagnosis
├── gate agent: review / security review
├── gate agent: test / user journey validation
└── work agent: release / migration / operations
```

Lead 是最高层的目标与编排权威，负责：

- 持有产品目标、设计决策、非目标、任务 revision 和总体进度；
- 将任务拆成有边界的 work unit；
- 根据实际需要创建、复用、替换或终止 agent；
- 决定每个 agent 的能力、权限、上下文范围、交付物和停止条件；
- 聚合工作结果和 evidence；
- 在局部工作结束后恢复父目标，决定下一步；
- 确保 required independent gate 被正确创建和满足。

其他 agent 不再是永久存在的同级团队成员，而是 lead 针对当前 work unit 创建的动态执行实例。

### Lead 的最高层级不等于可以自我验收

Lead 对目标、分解、调度和资源拥有最高控制权，但不能把这种层级解释为：

- 可以替代独立 reviewer/tester 给自己的实现签发 pass；
- 可以删除不利的 finding 或 evidence；
- 可以因为总体判断乐观而绕过 required gate；
- 可以让负责实现的同一工作上下文同时充当独立审查证据。

独立 reviewer/tester 是由 lead 创建和终止的动态 agent，但其 verdict 必须通过受控 evidence 接口提交。Lead 可以质疑 verdict、要求补充证据或创建另一名 evaluator，不能直接改写 verdict。

因此，团队拓扑是层级化的，证据权威仍然是隔离的。

### Authority 必须按职责分离

Orbit v2 不使用一个含义宽泛的“最高权威”覆盖全部决策。权威至少分为五类：

| 主体 | 权威范围 | 明确不拥有 |
| --- | --- | --- |
| Logical Lead | 提议 `TaskRevision`、work unit 分解、资源、agent lifecycle、scope escalation | 独立 `GateEvaluation` verdict；弱化 protected gate；自授 risk-owner/adjudicator authority；默认无权 waive required independent gate |
| Work Agent | 当前 `WorkUnitAttempt` 授权快照内的执行、implementation finding proposal 和交付物 | 修改 `TaskRevision.goal`、签发 evaluator `Finding`、确认 finding closure、关闭独立 gate |
| Gate Agent / Adjudicator | 独立 `GateEvaluation`、`Finding`、反例、证据充分性、`addressed/disproved` 确认 | 改写 task goal、替代实现者修改生产代码 |
| 当前/父 TaskRevision 已指定的 Risk Owner / User Authority | 在明确 waiver policy 范围内签发 `waived` resolution，并批准 protected gate/waiver/adjudication authority 变更 | 通过待批准 revision 新增的 authority 自我授权；自动替代未满足的独立评估 |
| Gate Engine | 验证 author authority、聚合 `GateEvaluation` 与 `FindingResolution`、派生 closure/`AggregateOutcome` | 业务目标取舍、finding 语义裁决、用时间顺序替代判断 |

Lead 可以因能力不匹配、上下文失效或证据不足替换 evaluator，但新 evaluator 的 `pass` 不能仅凭时间更新覆盖已有 `fail`。每个 blocking `Finding` 必须具有稳定 identity，并在 gate 关闭前具有有效 `FindingResolution`；旧 finding 不得因 evaluator 被终止或替换而消失。

`FindingResolution` 的 authority 固定如下：

- `addressed`：implementation `EvidenceRecord` 只能提出 addressed；必须由满足对应 `GateRequirement` 独立性条件的 evaluator 确认；
- `disproved`：只能由独立 evaluator，或当前/父 TaskRevision 已经生效的 adjudicator 基于反证签发；
- `waived`：只能由当前或父 `TaskRevision` 已经生效的 risk owner/user authority 按 waiver policy 签发；
- Gate Engine 只校验 resolution issuer、引用和完整性并派生 closure，不创造上述语义结论；
- Lead 只有在当前或父 `TaskRevision` 已经生效的 authority 明确授予其 risk-owner authority 时才能签发允许的 finding waiver；candidate revision 不能自授该权限，且 Lead 默认不能单方面 waive required independent gate。

`FindingResolution` 是 append-only event，issuer 不能只是自由文本名称。`addressed` confirmation 与 `disproved` 必须绑定 authorized evaluator/adjudicator `WorkUnitAttempt`、同 attempt submission `EvidenceRecord`、assigned/submitted rule resolution 和支持记录；`waived` 必须绑定当前有效 `ProjectPolicyRevision` 或由其授权的 TaskRevision authority authorization record。Gate Engine 根据这些稳定引用复核 issuer provenance。

### TaskRevision 不得成为 gate 逃逸通道

TaskRevision 可以修订目标与范围，但不能靠创建新 revision 删除或降级 required independent gate、放宽 independence/evidence level/waiver policy、替换 risk owner/adjudicator，或让 unresolved blocking Finding 消失。v2 对这类字段建立 protected gate lineage：

- child revision 默认继承父 revision 的 protected `GateRequirement` identity、最低强度、waiver policy、authority provenance 和全部 unresolved blocking Finding；
- Lead 可以提出 protected contract change，但不能批准自己的提议，也不能把自己或其新建 agent 写入 candidate revision 后据此获得审批权；
- 删除、降级或放宽 protected gate，改变 waiver policy/risk owner/adjudicator authority，必须由当前或父 revision 已经授权的 user/risk authority 签发；若 active ProjectPolicyRevision 规定更高门槛，则以 policy 为准；
- TaskRevision 必须保存 parent revision、逐项 protected change diff、批准主体和不可变 provenance；validator 根据父/当前已生效 authority 校验，不能根据 candidate revision 新声明的 authority 校验；
- blocking Finding 使用稳定 identity 跨 revision 继承。代码或 scope 变化可以使其进入重新评估，但在有效 `addressed`、`disproved` 或 `waived` resolution 产生前仍然阻塞；不能用新 revision、evaluator replacement 或 gate ID 重建清除；
- 若目标变化大到原 protected lineage 不再适用，应创建新的 task，并显式处理原 task 的 unresolved risk；不得在原 task 内用 revision-hop 假装风险已经消失。

protected change authorization 保存在 candidate TaskRevision 的 immutable revision envelope 中，至少记录 `parent_task_revision_id`、canonical `protected_change_digest`、`authority_source_revision_id`、`issuer_authority_ref`、可选 `project_policy_ref`、decision 和 issued-at provenance。它不是 candidate revision 中一个可自由填写的 risk-owner 名称；只能由受控 authority path 生成，并在 revision activation 前复核。

### Initial TaskRevision 使用非自授权的 ProjectPolicyRevision

首个 TaskRevision 没有 parent，不能从 candidate 自己声明的 risk owner/adjudicator 建立信任根。每个 Orbit v2 project 必须先通过 user-controlled bootstrap 创建 create-only `ProjectPolicyRevision` genesis，由可复核的 external user/control-plane authorization source 签发；Lead、task writer 和普通 agent 无权调用该 authority writer。

Genesis policy 至少冻结 stable policy revision ID、project identity、trusted `authorization_source_ref + assertion_digest`、protected GateRequirement minimum、waiver policy、risk-owner/adjudicator grants、policy update/rotation authority 和 content digest。authority verifier 必须从配置的 user/control-plane provider 解析 authorization source；agent 自填或无法解析的 opaque ref 无效。ProtocolRoot 只保存 immutable `project_policy_genesis_ref`；TaskRevision 保存它实际受约束的 exact `project_policy_revision_ref`，不把 policy body 复制进 ProtocolRoot 或 task。

Initial TaskRevision 的 protected gate minimum、waiver policy、risk-owner/adjudicator authority 必须引用或收窄 active policy grants；可以增加更严格 gate，但不能创建 policy 未授权的新 authority。需要 task-specific authority 时，必须在 TaskRevision activation 前取得 active policy 授权的 immutable authorization record。

后续 ProjectPolicyRevision 只能通过 append-only、线性的 successor revision 更新：active policy 确定性定义为受控 create-only store 中从 ProtocolRoot genesis 出发的唯一有效 lineage tip；successor 引用该 tip，使用 parent 已授权的 user/policy authority 签发，并与 tip 原子 compare-and-append。不得另设可覆盖的 active-policy 指针、原地覆盖、按时间 latest-wins 或由 successor 自授更新权；出现分叉或多个有效 tip 时 fail closed。rotation 不改写旧 TaskRevision provenance，但会使其 closure stale；继续执行必须创建绑定 active policy successor 的新 TaskRevision 并重新验证 protected contract。缺 genesis、authorization source 不可复核、policy ref/digest 不匹配、lineage fork，或 initial TaskRevision 比 policy minimum 更弱时全部 fail closed。

## 决策三：区分 Logical Lead 与 Lead Session

Lead 应保留最广、最完整的任务视角，但不能把“完整上下文”实现为无限增长的单一聊天记录。

需要区分：

- `LogicalLead`：跨一个 Task 持续存在的编排身份和权威；
- `LeadSession`：某一次实际模型会话，可以压缩、重启或被接替；
- `durable lead context`：由 task contract、设计决策、状态、evidence、handoff 和索引组成的可恢复事实。

这一区分很重要：如果只有 worker 会发生上下文退化，而 lead 被允许无限持有同一对话，那么相同的问题最终会转移到 lead。

Lead 的“最全上下文”应理解为：

- 覆盖面最广；
- 能定位全部权威事实；
- 保留关键决策及其理由；
- 知道每个 work unit 的状态和剩余风险；
- 可以按需读取细节。

它不意味着把所有 worker transcript、工具输出、测试日志和历史推理永久放在当前模型窗口中。

LogicalLead 即使更换 LeadSession，也必须能从 durable context 恢复同一个 TaskRevision 和总体决策状态。若恢复后不能证明上下文连续性，应进入 handoff/recovery 状态，而不是假装仍是原会话。

LogicalLead continuity 仍然是 per-task；同一个 Lead AgentInstance/provider-verified runtime subject 可以在一条 lineage 内串行执行多个 LogicalLead，或在旧 session terminal/release 后受控 transfer 到另一 lineage，但不得跨 control lineages 同时 active。每个 LogicalLead/Task 任一时刻只能归属一个 open `lead_control_id` queue，且每个 control lineage 只有一个 Task 可被 selection 激活。多 Task 的有序 queue、跨 lineage Task/executor release/acquire、唯一 active LeadSession/selection 与跨 session 恢复由 ADR-006 的 project-scoped control registry 和 LeadCheckpoint 管理，不在本文扩展成 Portfolio 平台。

## 决策四：建立可追溯的关系视图，不新增图数据库事实源

Orbit 应把任务闭环中的稳定对象及其关系显式化，使 logical lead、临时 work agent 和 independent evaluator 能从同一组权威事实中获得不同的上下文投影。

建议关系视图至少能表达以下权威对象：

- `ProtocolRoot`，只锚定 project/epoch/root identity 与 immutable policy genesis ref；
- `TaskRevision`，其中 `goal` 是字段，不另建可独立修改的 `Goal` 对象；
- create-only `ProjectPolicyRevision` lineage，作为 initial/child TaskRevision protected authority 的非自授权信任根；
- `WorkUnit`、append-only `WorkUnitAttempt` 和版本化 `ChangeThesis`；
- `LogicalLead`、`LeadSession`、`AgentInstance` 和 `CapabilityProfile`；
- ADR-006 的 project-scoped `lead_control_id`/control registry 与 create-only、append-only linear `LeadCheckpoint` lineage；
- `EvidenceRecord`、`GateRequirement`、`GateEvaluation`、`Finding` 和 `FindingResolution`；
- content-addressed `RuleResolutionArtifact` 和持久 artifact reference。

`CodeSurface`、`RelationshipView` 和 `AggregateOutcome` 都是从上述权威对象、repository snapshot 与 artifact reference 确定性派生的对象；它们不是可独立写入的事实源。

关系需要使用有具体语义的类型，而不是一个含义不明的通用 link：

```text
ProtocolRoot        --anchors_policy-------> ProjectPolicyRevision genesis
LeadCheckpoint      --belongs_to_control---> lead_control_id
LeadCheckpoint      --queues/selects-------> TaskRevision/WorkUnit
LeadSession         --executes_control-----> lead_control_id
LeadSession         --bound_to_subject-----> provider-verified runtime subject
TaskRevision        --authorizes------------> WorkUnit
TaskRevision        --requires--------------> GateRequirement
TaskRevision        --governed_by-----------> ProjectPolicyRevision
GateRequirement     --selects_subject-------> TaskRevision/WorkUnit set
WorkUnit            --has_attempt-----------> WorkUnitAttempt
WorkUnit            --starts_with-----------> ChangeThesis revision/digest
WorkUnitAttempt     --assigned_to-----------> AgentInstance
WorkUnitAttempt     --dispatched_by---------> LeadCheckpoint
WorkUnitAttempt     --belongs_to_control----> lead_control_id
WorkUnitAttempt     --uses_thesis-----------> ChangeThesis revision/digest
WorkUnitAttempt     --assigned_rules--------> RuleResolutionArtifact
EvidenceRecord      --produced_in-----------> WorkUnitAttempt
EvidenceRecord      --submitted_rules-------> RuleResolutionArtifact
EvidenceRecord      --supports/contradicts--> ChangeThesis revision/digest
GateEvaluation      --evaluates-------------> GateRequirement
GateEvaluation      --performed_in----------> WorkUnitAttempt
GateEvaluation      --submitted_via---------> EvidenceRecord
GateEvaluation      --subjects_revision-----> TaskRevision
GateEvaluation      --subjects_unit---------> WorkUnit
GateEvaluation      --subjects_attempt------> WorkUnitAttempt
GateEvaluation      --subjects_evidence-----> EvidenceRecord
GateEvaluation      --pins_snapshot---------> artifact reference/digest
GateEvaluation      --pins_surface----------> derived CodeSurface digest
GateEvaluation      --reports---------------> Finding
Finding             --reported_by-----------> GateEvaluation
FindingResolution   --resolves--------------> Finding
FindingResolution   --supported_by----------> EvidenceRecord
```

`GateEvaluation` 是 evaluator gate verdict、question/acceptance answers、coverage、counterexamples 和 residual risk 的唯一事实源；`Finding` 是问题内容与 blocking identity 的唯一事实源。review/test `EvidenceRecord` 只保存 evaluator submission 的 artifact/observation provenance，并由 `GateEvaluation.submitted_via` 稳定引用，不复制一份可独立修改的 verdict、answers 或 finding body。

Evaluator provenance 与 evaluation subject 必须分离。每个 GateEvaluation 使用 `evaluator_attempt_id` 和同 attempt submission EvidenceRecord 证明“谁评”；另用 immutable subject manifest 证明“评了什么”。subject 至少 pin subject TaskRevision、一个或多个 WorkUnit、全部被评 implementation Attempt/EvidenceRecord refs，以及 GateRequirement 要求的 repository snapshot artifact/digest 与 derived CodeSurface derivation version/digest。不得用 evaluator WorkUnit 或一个含混 `work_unit_id` 代替 subject。

GateRequirement 冻结 task-wide/selected-work-unit subject selector、implementation evidence inclusion、snapshot/surface 要求与 freshness policy；GateEvaluation 冻结 selector 解析出的 canonical subject set/digest。validator 必须证明 refs 存在、immutable、accepted、属于 subject revision 且未 stale，并用全部 subject producer agents 与 evaluator agent 计算 independence。subject attempts/evidence/snapshot/surface 发生变化后，旧 GateEvaluation 保留为历史但不能关闭新结果。

`EvidenceRecord`、`GateEvaluation` 和 `Finding` 都是 create-only、immutable。accepted 是创建时 controlled validation 的事实，后续 stale/closure validity 只派生、不回写。重提、纠错或重评必须创建新 ID，并使用受校验的 `supersedes_*`/`related_*` refs；同 ID 异内容、原地覆盖或删除均无效。supersedes 只表达 lineage，不自动关闭旧 blocking Finding；旧 Finding 仍需 authorized FindingResolution。

这组关系首先服务于三个目标：

1. **目标恢复**：局部 `Finding` 只能提出从属于当前 `TaskRevision.goal` 的 work unit 或 revision change request，不能因为在对话中被反复讨论就自动升级为新 goal。改变 goal 必须产生显式 `TaskRevision`。
2. **上下文投影**：Lead 获得覆盖全部 work unit/attempt、gate requirement/evaluation、finding/resolution 和剩余风险的宽视图；worker 只获得当前 attempt 周围的必要子图；independent evaluator 获得 task contract、被审 surface、相关 evidence 和产品上下文，但不默认继承作者完整 transcript。
3. **完整性与偏移审计**：系统可以发现没有 attempt 或 thesis revision 的孤儿 evidence、没有证据的方案主张、被新 revision 失效的旧证据、超出 authority snapshot 的修改，以及局部 finding 对 `TaskRevision.goal` 的事实性替换。

### 关系不等于事实或因果

图结构只会让关系更容易查询，不会自动提高关系的真实性。Orbit 必须区分：

- **权威事实**：来自服务控制的 `ProjectPolicyRevision`、`TaskRevision`、ADR-006 project-scoped `lead_control_id` registry/create-only LeadCheckpoint lineage、append-only `WorkUnitAttempt` lifecycle、create-only `EvidenceRecord`/`GateEvaluation`/`Finding` 与 append-only `FindingResolution`；
- **可复算关系**：从权威事实确定性派生的索引或视图；
- **候选关系**：由 agent 从聊天、源码或日志中推断，必须带来源并经过确认，不能直接改变 scope、权限、state 或 gate。

关系也不能使用一个宽泛的 `caused_by` 把时间顺序、相关性、假设和已确认根因混为一谈。至少需要区分：

- `observed_after`：只表达观测顺序；
- `hypothesized_cause`：表达尚待证伪的原因假设；
- `supported_by` / `contradicted_by`：表达证据方向；
- `confirmed_root_cause`：只有满足明确确认标准后才能建立。

任何会影响授权、任务 revision、evidence 有效性或 gate 的关系，都必须由 Orbit 受控写入路径产生并由 validator 复核，不能接受 agent 任意写图。当前 audit-only 信任边界不因此升级为防同权限文件篡改的安全边界。

### 先建立派生视图，不决定存储技术

v2 的 `ProjectPolicyRevision`、`TaskRevision`、`WorkUnit`、`WorkUnitAttempt`、版本化 `ChangeThesis`、`LogicalLead`/`LeadSession`、`AgentInstance`、ADR-006 的 `lead_control_id` control registry/`LeadCheckpoint`、`RuleResolutionArtifact`、`EvidenceRecord`、`GateRequirement`、`GateEvaluation`、`Finding` 和 `FindingResolution` 是事实源。`CodeSurface`、typed `RelationshipView` 与 `AggregateOutcome` 只在这些数据和 repository snapshot 之上生成只读、可复算的派生对象，不把同一事实复制进新的图存储，也不要求 Neo4j、GraphRAG 或图向量检索。

`AggregateOutcome` 只能由 Gate Engine 根据 active ProjectPolicyRevision/TaskRevision、GateRequirement 当前 subject selector、与当前 canonical subject digest 完全匹配且未 stale 的 GateEvaluation、acceptance results、unresolved Finding/FindingResolution 和 residual risk 确定性派生。subject 缺失、漏掉 required WorkUnit/Attempt/EvidenceRecord、repository snapshot/CodeSurface digest 变化，或 producer independence 不成立时，该 evaluation 不参与 closure。若为了性能持久化，只能保存带完整 source IDs/digests 的可删除 cache；任何 agent、Lead 或外部 writer 都不能直接写一个 aggregate verdict 推进状态。

只有在真实试验中证明下列条件成立后，才重新评估专用图存储：

- 多跳关系查询已经成为高频核心路径；
- 现有索引或关系型存储无法在可接受复杂度和性能下满足需求；
- 关系规模、更新方式和并发需求足以抵消新的运维、迁移和一致性成本；
- 图存储不会成为 task/evidence/state 之外的第二事实源。

这条渐进路径是必要约束：为了防止 agent 过度抽象而立即建设一套通用图平台，本身就是本 ADR 所描述的“低证据收益驱动大范围实现”。

## 决策五：配置保存策略，运行状态保存动态团队

需要调整配置结构，但不能把不断变化的 agent 名单直接混入静态配置事实源。

建议区分两类数据。

### 静态策略配置

静态配置描述 lead 可以如何组建团队，而不是声明永远存在固定的 coder/reviewer/tester：

```yaml
# Proposed，仅表示设计方向，不是当前 schema。
lead:
  role: lead
  authority:
    - task.define
    - work_unit.create
    - agent.create
    - agent.terminate
    - team.reconfigure
    - state.aggregate

agent_profiles:
  implementation:
    capabilities:
      - source.read
      - code.edit
      - test.run
  independent_review:
    capabilities:
      - source.read
      - evidence.read
      - review.submit
    constraints:
      - cannot_edit_production
      - cannot_review_own_work
  user_journey_test:
    capabilities:
      - runtime.run
      - test.submit

team_policy:
  dynamic_workers: true
  lead_may_create: true
  lead_may_terminate: true
  independent_gate_required_by_risk: true
```

`agent_profiles` 是可复用的能力模板，不是固定组织架构。项目可以定义 researcher、designer、security reviewer、migration operator 等任意 profile。

### 动态运行事实与派生 roster

某一时刻实际存在的 agent 组不能由一个可覆盖的 `team_runtime.workers` 列表充当事实源。v2 使用 `AgentInstance` lifecycle、`LeadSession` generation 和 append-only `WorkUnitAttempt` 记录运行事实，active roster 是确定性派生 projection：

```yaml
# Proposed，仅表示设计方向，不是当前 schema。
team_runtime_projection:
  lead_control_id: lcontrol-main
  logical_lead_id: lead-main
  lead_session_generation: 3
  lead_runtime_subject_ref: provider-runtime-subject-...
  lead_runtime_subject_assertion_digest: sha256:...
  active_attempts:
    - attempt_id: wattempt-17
      work_unit_id: wu-fix-recovery
      agent_instance_id: agent-implementation-7
      profile: implementation
      context_generation: 1
      status: active
```

`active_attempts` 保留为 projection collection shape 以便表达零或一个 active Attempt；同一 `lead_control_id` 中其 cardinality MUST 小于等于一，active LeadSession cardinality 也 MUST 小于等于一。Task/WorkUnit 还受跨 lineage ownership 和 project-wide non-terminal Attempt backstop 约束；provider-verified canonical Lead runtime subject 还受 project-wide active-session binding 唯一性约束，不能通过不同 AgentInstance ID/别名绕过。review/test 必须等待 implementation terminal 和 accepted LeadCheckpoint 后再 dispatch，不能与 implementation 并行。

这意味着现有配置至少需要重新审视：

- `.orbit/roles.yaml`：从固定角色清单转向 lead authority、agent profile、capability 和 independence policy；
- `.orbit/instances.yaml`：不再承担完整团队事实源，可保留 launcher/runtime adapter 模板和已配置的常驻实例；
- append-only lifecycle store：保存 `AgentInstance`、`LeadSession` 和 `WorkUnitAttempt` 的创建与终结事实；
- loop/runtime state：只保存或缓存从 lifecycle facts 派生的 active roster、open attempt 和 context generation projection；
- task contract：声明当前任务需要哪些独立能力和 gate，而不是预先固定具体 agent 名；
- evidence：通过 `attempt_id` 绑定实际执行 agent、task revision、work unit、authority snapshot、规则上下文和独立性关系。

动态 roster 是派生状态，不应反向污染静态配置，也不能成为 attempt history 之外的第二事实源；否则频繁创建、替换和终止 agent 会丢失历史 assignment，并让配置文件或 projection 同时承担 policy 与 live truth。

## 决策六：所有委派工作都使用有边界的 Work Unit

Work unit 是 lead 与其他 agent 之间的最小授权单元，适用于研究、设计、计划、编码、诊断、审查、测试和发布操作。

建议至少包含：

```yaml
# Proposed，仅表示设计方向，不是当前 schema。
work_unit:
  work_unit_id: wu-...
  task_id: otask_...
  task_revision_id: r4-...
  parent_work_unit_ref: wu-parent-or-null
  depends_on_work_unit_refs: []
  objective: ...
  authority_scope: []
  input_refs: []
  expected_outputs: []
  acceptance_refs: []
  evidence_requirement_refs: []
  source_requirement_refs: []
  stop_conditions: []
  return_to_lead: true
  initial_change_thesis_ref:
    change_thesis_id: thesis-...
    revision: 2
    digest: sha256:...
```

Work agent 只拥有本 work unit 的执行权，不拥有修改 `TaskRevision.goal` 的权力。

`parent_work_unit_ref` 与 `depends_on_work_unit_refs` 是 ADR-006 冻结的未来 exact refs；mainline、branch、critical path 与 runnable set 从它们和权威 lifecycle/gate facts 派生，不作为阶段标签写回 WorkUnit。Task/WorkUnit 的验收边界、dependency readiness 与 single-writer 规则以 ADR-006 为准。

执行过程中发现新问题时，agent 可以：

- 报告 finding；
- 提出新的 work unit；
- 请求扩大 scope；
- 在当前授权范围内处理明确属于本 work unit 的问题。

agent 不能因为局部问题连续出现，就静默把 `TaskRevision.goal` 改写成“解决当前修复链路的全部问题”。

是否继续当前 agent、创建新的专业 agent、重启上下文或返回设计阶段，由 lead 根据证据决定。

`ChangeThesis` 是 work-unit-scoped、create-only 的版本化主张。每个 revision 具有稳定 `change_thesis_id + revision + digest`，包含 observed problem、root-cause status、system property、smallest sufficient mechanism、expected benefit、introduced cost、blast radius 和 disconfirming evidence。WorkUnit 只保存不可变 `initial_change_thesis_ref`，每个 Attempt 则 pin 一个明确 thesis revision/digest；不能原地改写任何引用后让旧 evidence 看起来支持新 thesis。

`ChangeThesis` 的作用不是要求 agent 写一段自我辩护，而是给 lead 和 independent evaluator 一个可证伪的方案主张。若 root cause 仍是推测、收益无法验证、全局影响面大于已证明的问题面，lead 应创建新 thesis revision、拆分探索、要求补证据或停止实现，而不是让代码规模替代论证。

### Work Unit 是 v2 的唯一运行时授权单元

`TaskRevision` 继续拥有 `goal`、全局 non-goals、quality outcome、带稳定 ID 的 acceptance/source/evidence requirements、review questions 和 `GateRequirement`。`WorkUnit` 只拥有局部 objective、authority scope、input/output refs、stop conditions、task-level requirement refs 和不可变 initial `ChangeThesis` revision/digest。

v2 不同时保留另一套 `child_slices`、`parent_goal` 或隐式派单结构表达相同事实。WorkUnit 只能通过 `acceptance_refs`、`evidence_requirement_refs` 和 `source_requirement_refs` 引用 TaskRevision 合同，不得复制并独立修改这些上层合同；`GateRequirement` 仍由 TaskRevision 直接拥有。所有会修改产物、产生权威 evidence 或关闭 gate 的工作都必须绑定明确 WorkUnitAttempt；不存在“没有 attempt 但仍可提交正式 evidence”的兼容路径。

### WorkUnitAttempt 是 append-only 的 assignment 与执行权威

WorkUnit 保持稳定 scope，不直接拥有可覆盖的 `assignment`、agent、context generation、start/end 或 status。每次首次执行、重试、agent replacement、context rebuild 或独立 evaluation 都创建新的 `WorkUnitAttempt`。

`WorkUnitAttempt` 的 `AttemptCreated` event payload 同时是不可变 Assignment snapshot，不另建一套可独立修改的 Assignment 事实源：

```yaml
# Proposed，仅表示设计方向，不是当前 schema。
work_unit_attempt:
  attempt_id: wattempt-...
  lead_control_id: lcontrol-main
  work_unit_id: wu-...
  task_id: otask_...
  task_revision_id: r4-...
  predecessor_work_unit_attempt_ref: wattempt-previous
  dispatch_lead_checkpoint_ref: lcheckpoint-...
  purpose: implementation | review | test | research | release
  agent_instance_id: agent-...
  context_generation: 2
  authority_snapshot:
    capability_profile_ref: implementation-v2
    authority_scope_digest: sha256:...
    permission_digest: sha256:...
  change_thesis_ref:
    change_thesis_id: thesis-...
    revision: 2
    digest: sha256:...
  assigned_rule_resolution_id: rr-sha256-...
```

Attempt 创建使用无循环的原子流程：先预分配尚无运行权威的 `attempt_id`，再用该 identity 解析并 create/reuse content-addressed assigned RuleResolutionArtifact，最后一次性追加包含 `assigned_rule_resolution_id` 的 `AttemptCreated` event。只有该 event 成功后 Attempt 才存在并可 dispatch；禁止创建后 patch Assignment snapshot。若 artifact 已创建而 `AttemptCreated` 失败，该 artifact 只是未引用的 immutable content，可由审计后 GC，不构成 active assignment。

`AttemptCreated` event 的服务端 event timestamp 是 `started_at` 的唯一来源，并确定初始 `active` status；后续 terminal lifecycle events 提供 `ended_at` 和 `completed|failed|blocked|cancelled|superseded`。projection 只从这些 append-only events 派生时间与 status。禁止原地覆盖旧 attempt 的 agent、authority、rules、context generation 或 terminal status。一个 WorkUnit 可以有多个历史 attempts，但同一 `lead_control_id` 最多一个 non-terminal Attempt，且 project-wide 每个 Task/WorkUnit 也最多一个 non-terminal Attempt；replacement 不得让旧 attempt 和 evidence 消失。successor 必须 pin stable control identity，并引用 terminal predecessor 和授权 dispatch 的当前 accepted LeadCheckpoint，完整规则由 ADR-006 冻结。

WorkUnit 没有可覆盖的“current thesis”指针。创建新 ChangeThesis revision 后必须在旧 Attempt terminal、LeadCheckpoint 接受后创建 pin 该 revision/digest 的 successor Attempt；派生视图可以报告零或一个 `active_thesis_ref`。历史 attempts 可以 pin 不同 revision，但不能用 latest-wins 改写其 provenance。

每条正式 `EvidenceRecord` 必须绑定 `attempt_id`。task/work-unit/agent/authority/thesis 等冗余 snapshot 如为审计而保存，validator 必须证明与 attempt 一致；`attempt_id` 和 append-only attempt history 才是 assignment 的权威来源。active roster、agent 当前工作和 replacement history 都从 open/terminal attempts 与 AgentInstance lifecycle 派生。

## 决策七：上下文按责任分层

建议把上下文分为三层：

### Lead context

包含总体目标、设计、任务 revision、work unit 图、关键决策、动态 team 状态、gate 和剩余风险。它拥有最广覆盖，但过程细节通过路径和索引按需读取。

### Work agent context

只包含当前 work unit 所需的最小高信号事实、必要源码入口、适用规则和返回条件。不默认继承完整 lead 对话或其他 worker transcript。

### Independent evaluator context

包含 task contract、被审对象、必要产品上下文、diff/evidence 和审查标准。默认不继承作者完整推理过程，降低被作者叙事和修复路径锚定的风险；同时必须读取足够的代码库上下文，不能把 fresh context 误解成无背景审查。

上下文重启只是风险控制手段，不是完成证明。一个 fresh agent 如果收到同样错误的任务抽象，仍然会重复错误。

Orbit 不应在 runtime 无法证明时声称 agent 具有 fresh context。新 pane、client 名、环境变量或手工消息都不足以证明模型上下文已经重置。当前 Herdr 能力边界仍以 [ADR-002](./002-herdr-runtime-identity-boundary.md) 为准。

## 动态 Agent 生命周期

建议的生命周期是：

```text
lead identifies work
  -> creates bounded work unit
  -> selects capability profile
  -> creates or selects AgentInstance
  -> LeadControl reconciles four-layer assessment and appends LeadCheckpoint selection
  -> preallocates attempt_id and resolves assigned RuleResolutionArtifact
  -> atomically appends AttemptCreated with immutable assignment snapshot
  -> agent executes and submits EvidenceRecord bound to attempt_id
  -> lead evaluates return condition
     -> append terminal attempt event and terminate/release agent
  -> LeadControl appends the next linear LeadCheckpoint
     -> select a successor attempt for the same work unit
     -> replace agent/context by selecting a new attempt
     -> propose a child work unit for controlled creation/selection
     -> propose TaskRevision; protected changes require inherited authority
  -> resolve canonical evaluation subject from GateRequirement
  -> evaluate pinned subject through attempt-bound independent GateEvaluations
  -> create stable Findings from GateEvaluation without copying them into EvidenceRecord
  -> resolve every blocking Finding through authorized FindingResolution
  -> Gate Engine deterministically derives AggregateOutcome
```

触发 agent 替换或上下文重建的条件不应只依赖 token 数，可以包括：

- 相同失败或假设反复出现；
- agent 无法重新陈述 `TaskRevision.goal` 与当前 work unit 的关系；
- scope 扩展到新的专业能力或权限边界；
- task revision 已变化；
- agent 的局部上下文开始影响不属于其授权范围的决策；
- 输出规模已经超过当前 review 策略能够完整覆盖的范围；
- 从执行阶段进入需要独立判断的 gate 阶段。

这些风险信号不是穷尽 checklist。ADR-006 进一步冻结事件触发、active ProjectPolicyRevision/authorized immutable record 绑定的有限非零 wall-clock fallback、Delivery/Assurance Progress、连续零 Delivery delta fuse、相同 fingerprint 第三次 Attempt 的 provider-verified `task.retry.override` AuthorizationRecord，以及 scope/blast-radius/review-surface/goal-relation 失控时的立即 freeze。fingerprint 只能由 LeadControl/受控 writer 从 versioned `fingerprint_identity_basis` 产生：TaskRevision/WorkUnit scope、typed category/code、stable Finding identity，或非 Finding failure 的 stable test/rule/check identity + stable signal subject identity + normalized failure code。terminal Attempt 与 Finding/GateEvaluation/test/validator outcome refs+digests 只进入不参与 hash 的 `fingerprint_supporting_provenance`，用于证明 occurrence 和跨 checkpoint prior-chain 计数。agent message、自报标签、排序、AgentInstance 别名或每轮新建 record identity 不能改变 fingerprint，无法证明稳定 signal identity 或 provenance 时必须 freeze。Orbit 不使用通用固定行数、token 或 round threshold 作为 correctness。

## 决策八：Review 必须审查方案比例性和结构质量

本节保留 review 的语义判断与独立 authority；何时触发自检、如何区分 Delivery/Assurance Progress、何时停止自动继续或将 hardening 放入非抢占 WorkUnit，由 ADR-006 统一规范。

Review 不能只回答“实现是否正确执行了当前方案”，还必须先回答“当前方案是否仍值得以这个范围和复杂度执行”。

这里需要避免另一个机械结论：大量代码或全局限制不必然错误。高风险且跨入口的根因可能确实需要系统性机制。阻塞条件不是“代码多”，而是以下因果链缺失或不成立：

```text
observed problem
  -> confirmed root cause
  -> system property that must change
  -> smallest sufficient mechanism
  -> justified blast radius
  -> measured or observable benefit
  -> acceptable introduced cost
```

当 agent 为局部问题提出全量限制时，reviewer 至少需要查明：

- 当前证据证明的是一个案例、一个入口、一类结构化失败，还是系统级 invariant 失效；
- 为什么限制必须覆盖所有调用方、模块、输入或 provider；
- 是否存在更小、可组合、可回滚的机制；
- 全局限制会产生哪些 false positive、false negative、兼容性和扩展性成本；
- 新增代码是否主要服务真实产品能力，还是服务当前修复方案自身的复杂度；
- 如果收益较小或不可测，为什么值得增加长期维护面；
- 哪类反例会推翻当前方案，agent 是否主动寻找过这些反例。

模块分类审查需要判断职责、依赖方向和变更原因，而不只是目录是否符合现有模式。抽象审查需要判断稳定变化点和真实复用，而不只是 interface 是否整洁。代码整洁审查需要判断新增复杂度是否被删除、收敛或隔离，而不只是 formatter、lint 和单测是否通过。

## Review 需要同时解决价值、风险和完整性

只按风险路径抽查，适合发现高影响缺陷，但不能证明方案方向、结构质量和所有新增正式产物都经过审查。

后续 review 模型应区分：

1. 目标与价值审查：原始问题是否仍成立，当前方案的收益是否值得继续投入。
2. 因果与比例性审查：root cause、机制、blast radius 和收益/成本链路是否成立。
3. 风险审查：行为、权限、恢复、数据、隐私、provider、发布和真实用户路径。
4. 结构质量审查：模块归属、依赖方向、抽象、复杂度、限制范围、命名和长期维护成本是否合理。
5. 完整性审查：本轮新增、重命名、移动或提升为正式产物的 surface 是否全部被看到。
6. 证据审查：测试、运行结果和 artifact 是否能证明上述判断，而不只是证明代码执行成功。

完整性可以由工具帮助枚举“需要看什么”，价值、结构和语义正确性不能由词表、行数、lint、架构测试或文件名规则替代。

review 应先检查 change thesis 和主要结构方向，再进入逐文件检查。如果方案方向本身缺乏收益或比例性，继续逐行审完数千行代码并不能提高结论质量，只会增加沉没成本。

对于大变更，优先按自包含能力、架构边界或可独立验证的行为拆分 review。不能拆分时，必须显式说明：

- 哪些部分是生成或机械变更；
- 哪些部分需要逐项结构和语义判断；
- reviewer 如何证明完整 surface 已覆盖；
- 哪些部分尚未检查并构成 residual risk。

## 当前状态与目标状态

| 方面 | 当前 Orbit | 本 ADR 提议 |
| --- | --- | --- |
| 团队拓扑 | role archetype 可扩展，但 instance/assignment 主要来自静态配置 | LogicalLead 统领动态、可替换的任务级 agent group；stable `lead_control_id` 严格串行，跨 lineage Task ownership 与 active runtime subjects 均不相交 |
| 角色定义 | 可扩展 role policy + 基本静态的 instance 配置 | 可复用 capability profile + 运行时动态实例 |
| Lead | 角色之一，可在小项目兼任 coder | 最高目标与编排权威，但不覆盖独立 verdict |
| 上下文 | 规则、task、evidence、handoff；fresh evaluator 主要用于 gate | lead/work agent/evaluator 分层，所有 work agent 使用 bounded work unit |
| 关系与恢复 | 事实分散在 task、evidence、state、handoff 和线性对话中 | 从 v2 权威对象派生 typed relationship view，为不同责任投影有边界的子图 |
| 问题范围 | 主要围绕 coding、review、test 流程 | 覆盖研究、设计、计划、实现、诊断、审查、测试、发布 |
| 代码健康治理 | coding/review 规则已覆盖 domain distortion、结构、scope 和 outcome，但未绑定动态 work unit 与完整 surface closure | 审查 change thesis、比例性、模块、抽象、复杂度、限制范围、命名和完整 surface，并绑定 work unit evidence |
| 动态团队状态 | instances 基本静态 | append-only WorkUnitAttempt/AgentInstance lifecycle 保存历史，active roster 为派生 projection |
| Lead 控制 | 缺少多 Task 唯一 selection、checkpoint 与统一自检 | ADR-006 的 single-active invariant、LeadCheckpoint 与 LeadControl |

本表右侧是本 ADR 已接受的 v2 目标架构，不表示现有 CLI 或 schema 已经支持；具体字段、命令和存储合同仍由后续实现设计冻结。

## v2 切换与兼容性约束

本 ADR 按 [ADR-005](./005-orbit-v2-clean-cut-and-legacy-retirement.md) 一次性切换，不要求 v2 同时表达或继续读取 v1 语义：

- 每个 active project root 必须先通过 `protocol_epoch: orbit-v2` marker 校验；marker 的 canonical parent 唯一定义 active artifact root，混合 v1/v2 fail closed；
- ProtocolRoot 必须锚定 valid ProjectPolicyRevision genesis；initial TaskRevision 不能从 candidate/Lead 自报 authority bootstrap；
- 不双写 v1/v2 task、state、evidence 或 gate；
- 不为缺少 WorkUnitAttempt、agent instance、record-level rule resolution 或 FindingResolution 的旧 artifact 猜测新字段；
- 不保留静态 team 与动态 roster、`child_slices` 与 WorkUnit、manifest rule resolution 与 record rule context 的双事实源；
- 不接受缺 canonical subject/stale subject 的 GateEvaluation，也不原地修改 EvidenceRecord/GateEvaluation/Finding/FindingResolution；
- v1 artifact 不自动升级为 v2；需要继续工作的任务必须按 v2 contract 重新初始化；
- 当前 runtime reference 只在 v2 writer、reader、validator、gate、模板和测试一起切换时更新。

这项约束不否定代码实现可以分 slice 完成，但任何中间 slice 都不能作为同时支持两套权威协议的正式发布状态。

## 不能接受的简化

以下方案不能视为本问题的完整解决：

- 只规定每 N 轮或 N tokens 强制重启 agent；
- 建立 `P6`、`Slice1`、`phase` 等禁用词表；
- 只增加 naming review，而不审查模块、抽象、复杂度和限制范围；
- 用“代码多”直接判错，或反过来用“已经写了很多”证明方案重要；
- 对一个局部案例引入全局限制，却没有证明系统级 root cause 和 blast radius；
- 只证明测试、lint 和架构门全绿，不判断新增结构的收益与长期成本；
- 只把静态 coder/reviewer/tester 改成更多静态角色；
- 让 lead 因为层级最高而自行关闭独立 review/test gate；
- 让 lead 永久保留未经压缩和索引的完整聊天，把同样的上下文退化风险集中到 lead；
- 把 dynamic team 解释为同一 `lead_control_id` 内并行执行 implementation/review/test/research/release、给同一 Task 新建第二 control lineage，或让同一 provider/runtime subject 以相同/不同 AgentInstance ID 同时执行两个 control lineages；
- 先接受缺 active LeadSession/provider-verified runtime subject 的 genesis checkpoint，再回填 executor；
- 让 Lead/Work Agent 用新的 message wording、排序、自报 fingerprint、AgentInstance 别名或每轮新建 Attempt/outcome record ID/digest 重置相同 failure 的 retry chain；
- 在 active Attempt 未 terminal 或没有 LeadCheckpoint 时切换 Task、创建 successor 或 dispatch 下一工作；
- 把动态 agent roster 写回静态配置，使 policy 和 live state 混为一个事实源；
- 把 assignment、agent 或 status 原地写回稳定 WorkUnit，覆盖历史 attempt；
- 原地覆盖 WorkUnit 的 current ChangeThesis 指针，让旧 attempt/evidence 失去历史 thesis；
- 让 active roster 成为 WorkUnitAttempt 之外的另一套 live assignment 事实源；
- 让 review/test EvidenceRecord 与 GateEvaluation 各保存一份可独立修改的 verdict 或 finding；
- 让 GateEvaluation 只绑定 evaluator、不冻结 task-wide subject，或把旧 pass 复用到新 implementation/snapshot；
- 只对一个 author 计算 independence，漏掉其他 subject producer agents；
- 让 initial TaskRevision/Lead 自报 genesis risk owner/adjudicator，或缺 policy authority 时继续运行；
- 原地覆盖/删除 EvidenceRecord、GateEvaluation、Finding/FindingResolution，或用 supersedes 隐藏旧 blocking Finding；
- 让 Lead 用新 TaskRevision 删除/降级 protected gate、重设 risk owner/adjudicator 或清除 unresolved Finding；
- 允许 agent 或 Lead 直接写 AggregateOutcome 推进状态；
- 只要求 reviewer 检查核心文件，不说明未覆盖的 production surface；
- 因为关系化上下文有价值，就直接引入图数据库、GraphRAG 或第二套任务事实源；
- 把 agent 从对话、代码或日志中抽取的关系直接当成 scope、权限、因果或 gate 事实；
- 用一个通用 `caused_by` 边隐藏原因仍是推测、证据相互矛盾或只有时间相关性；
- 用“图比 RAG 更先进”代替 Orbit 自身查询需求、成本和对照实验。

## Orbit 落地仍需验证的问题

实际项目已经验证本 ADR 的核心架构方向；以下仍是 Orbit 具体实现必须用自身数据回答的问题：

- bounded work unit 是否显著降低 `TaskRevision.goal` drift；
- worker context 重建是否降低反复修复后的方向偏移；
- logical lead + replaceable lead session 是否能在保持设计连续性的同时减少上下文退化；
- ADR-006 的串行 LeadControl 是否能以可接受的吞吐成本降低 task switching、支线抢占与连续零 Delivery delta；
- typed `RelationshipView` 是否比线性摘要更准确地恢复 `TaskRevision.goal`、未完成 `WorkUnit`/`WorkUnitAttempt`、失效 `EvidenceRecord` 和未满足的 `GateRequirement`；
- bounded relationship projection 是否在减少 token 的同时保留 worker/evaluator 完成任务所需的关键信息；
- agent 提议的候选关系有多少被确认、驳回或修正，错误关系是否曾尝试改变 scope、权限或 gate；
- 动态专业 agent 是否比当前静态执行拓扑获得更好的缺陷发现率和更低的协调成本；
- 上下文相关的结构质量审查是否能降低错误模块归属、过度抽象、复杂度膨胀、不成比例的全局限制和阶段命名进入正式源码的比例；
- 完整 production surface 审查会增加多少时间和 token 成本；
- 哪些 agent 替换信号最有效，是否存在项目或模型相关差异。

建议后续试验至少记录：

- `TaskRevision.goal` drift 发生率；
- 修复问题被提升为主目标的次数；
- 经人工复核确认的模块归属、抽象、复杂度、限制范围和命名问题；
- 被停止或缩小的低收益高成本方案数量，以及 reviewer 给出的证据；
- 全局限制的 false positive、false negative、兼容性和维护成本；
- reviewer 首轮发现率和 escaped finding；
- work unit 数、agent 创建/替换次数；
- lead 与 worker 的 token、耗时和 handoff 失败率；
- 关系投影相对线性摘要的事实遗漏率、错误关系率、恢复耗时和 token 成本；
- 孤儿 CodeSurface、无证据 ChangeThesis、失效 evidence 和越权修改的检出率；
- 大 diff 拆分前后的 review coverage；
- independent gate 被 lead 绕过或错误归因的次数。

试验应采用同任务、同代码基线、同模型或配对模型的对照设计。样本量和阈值通过预实验与统计功效分析确定，不在本 ADR 中臆造。

## 决策九：Agent-independent 规则交付与质量治理分层

本决策由 [orbit-v2-agent-independent-control-amendments](../open/orbit-v2-agent-independent-control-amendments.md)（owner approved 2026-08-11）引入；ADR-004/006 承载其 evidence/gate 与控制条款。

### Agent-independent rule delivery

规则与 `effective_verification_plan_digest` 的交付不依赖具体 agent 的身份、自报或对话：

- 任何持有 test-write、verification-submit 或 gate-close capability 的 `WorkUnitAttempt`，其 context projection 必须重算或从 accepted `LeadCheckpoint` 下发同一 `effective_verification_plan_digest` 及其 source refs+digests（派生规则见 ADR-004 决策七；checkpoint 只 pin 权威输入 refs，不复制规则正文）；缺失或不一致则该 Attempt 的 evidence 不能关闭对应 requirement。
- 仓库根 `AGENTS.md` 等客户端提示只是开发 Agent 的客户端纪律，不是 Orbit 产品 authority；两者冲突时以 active `ProjectPolicyRevision`/`TaskRevision` 为准。
- 控制事实（selection、budget、closure basis、continuation）只从权威记录派生；agent 自报不产生控制事实。

### Lead soft-quality delegation

Lead 在 delegation envelope 内自主做软质量判断，不询问用户：

- envelope = active `ProjectPolicyRevision` + closure basis + budget ceiling + authority scope（ADR-006 delegation envelope 条款）；
- 软判断（ceiling 内 `test.budget.adjust`、agent/context 选择、继续/暂停、attempt 顺序）由 Lead 判断并写入 accepted LeadCheckpoint；
- 只有硬越界、目标变化、风险接受需要 user/control-plane（`needs_user`，ADR-006 bounded runner 条款）。

### 质量治理分层

| 层 | 主体 | 范围 | 证明方式 |
|---|------|------|---------|
| 机械规则 | writer/validator | refs、digest、lineage、cardinality、single-active、budget 记账、blocking 派生 | fail closed、确定性、可复算 |
| Lead 语义判断 | Logical Lead | goal 关系、比例性、thesis 取舍、ceiling 内 budget adjust、replan/split/switch/freeze/escalate | checkpoint provenance |
| Independent review | reviewer/test gate | verdict、Finding basis、结构/价值/风险/完整性审查、production change surface | `GateEvaluation`/`Finding` |
| User escalation | user/control-plane | goal 变更、risk acceptance、hard override、protected 变更批准 | policy/`AuthorizationRecord` |

软判断不得伪装成 validator correctness："validator 通过"不等于"方案正确"；词表/naming lint 不能单独判 pass（决策一）；Lead 不能自审（ADR-006）。

## 后续设计工作

实现本 ADR 时，分别完成以下实现合同：

1. logical lead、agent profile、带 immutable initial thesis ref 的 WorkUnit、append-only WorkUnitAttempt/Assignment snapshot 和派生 roster 的 schema；
2. 从现有 task/evidence/state/handoff 派生 typed relationship view 的对象、边类型、来源和失效语义；
3. lead、worker、independent evaluator 的关系子图投影及最小充分上下文；
4. 候选关系的确认流程，以及禁止其直接改变 scope、权限、state 和 gate 的受控写入与 validator 边界；
5. `roles.yaml`、`instances.yaml` 与 runtime state 在 v2 中的最终职责，以及旧 writer/reader 的删除清单；
6. lead 创建、终止、替换 agent/attempt 的权限和审计协议；
7. evaluator-attempt-bound、canonical-subject-pinned `GateEvaluation`、submission EvidenceRecord、`Finding`、`FindingResolution` 的单一 authority、create-only lifecycle 与 issuer provenance；
8. lead session 恢复和 context generation 的真实性边界；
9. versioned ChangeThesis、方案比例性、结构质量和 production surface 完整性 review report；
10. ProjectPolicyRevision 非自授权 genesis、linear rotation、ProtocolRoot genesis ref 和 initial TaskRevision bootstrap validator；
11. protected gate lineage、跨 revision unresolved Finding 和 parent-authority approval validator；
12. GateRequirement subject selector、canonical subject digest、freshness 与 producer-set independence validator；
13. Gate Engine 的 deterministic AggregateOutcome projection 与 cache invalidation；
14. 从现有静态角色运行模型一次性切换到动态 team 的 cutover 与 closure guard；
15. Orbit dogfood 对照实验和验收指标。

ADR-006 已将 task queue、WorkUnit parent/dependency、Attempt predecessor/checkpoint binding、LeadCheckpoint/LeadControl、四层自检和止损另立为控制合同；这些内容不由上列 evidence/gate 实现合同隐式替代。

在这些实现合同完成前，不把本 ADR 的局部示例字段零散加入 v1 正式 API。v2 必须按 ADR-005 完成全链路切换和旧路径关闭；typed RelationshipView 与 AggregateOutcome 仍不得成为 task/work-unit/evidence/state/gate 之外的第二套事实源。

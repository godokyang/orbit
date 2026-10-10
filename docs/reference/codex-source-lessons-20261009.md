# Codex 源码中值得 Orbit 借鉴的机制

2026-10-10 补注：全部候选及既有采用原则已重新核对，最新充分性判断沿[重评记录](codex-decisions-reevaluation-20261010.md)。本页保留固定提交研究事实，不以旧“已有能力”标签取代实际交付与失败恢复的核对。

前轮状态更新（历史）：用户随后正式授权前轮实施，前轮实际 Goal complete、其交付条件已完成；C01及全部采用项的实施／验收沿[唯一总清单](../plan/codex-lessons-implementation.md)，证据沿[本轮验收](codex-lessons-acceptance-20261009.md)。2026-10-10 新轮 Goal 已实际启动并最终complete；剩余能力按唯一总清单 §9 接续。下文“先落文档／未实施”保留研究阶段事实，不覆盖本轮状态；未宣称经济收益。

研究日期：2026-10-09。范围：用户请求的 `openai/codex` 开源仓库与 Orbit 当前实现的对照；本页为源码研究，不产生产品运行事实。后续用户确认先记录上下文压缩增量方向，范围与验收条件见[上下文方案](../plan/context-compression-proposal.md)；其余项仍为研究建议。

## 基线与证据范围

- Codex：本次从 GitHub 获取的 main 快照，commit [`36ae1561b9324c93d5638b45eb19fe2cc070a581`](https://github.com/openai/codex/commit/36ae1561b9324c93d5638b45eb19fe2cc070a581)。下文源码链接固定到该提交，不依赖浮动 main。
- Orbit：源码 0.8.3，研究开始时 HEAD `9f5e66db681ac312d12f2f1f1c70cc804bcaad38`，工作树干净。已读文档入口、开发流程、交接、欠账、任务合同与 ADR-008/009，并核对相关 Ruby/JS/TS 实现。
- 方法：获取源码后按符号和调用路径阅读；另核对 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。没有构建、运行或实测 Codex，也没有运行 Orbit 模型任务；源码及源码中的测试只能说明设计与验证意图。

## 从 Orbit 的诉求筛选，而不是从 Codex 的功能清单排期

2026-10-09 再审：用户要求从第一性原理重看这组借鉴材料。依据是已认可的[产品主方案 §1/§4/§5](../plan/mixed-model-delivery-proposal.md)、[任务合同](../../contracts/task-runtime.md)和 ADR-008/009，以下是对既有诉求的还原，不新增产品决定。

**Orbit 的核心诉求是在任务质量、权限边界和可接受错误风险下，用有限的顶级模型资源完成更多有价值的工作，并减少用户监督、转述、催办和纠偏。** 防偏航、持续推进、模型分工、独立核验和如实停止共同服务于这个诉求。

从这个目标可以推出四个必要条件：

1. **任务责任持续，工作可以交接。** 原要求、有效修订和整项交付责任不能随回合、成员或型号切换丢失；有界工作可由合适模型串行或并行承接。需要核对成员是否替代了 Root 的实质执行，而非 Root 做完再多派一层。
2. **未完成且具备继续条件时主动推进。** 偏航和遗漏要被发现，纠正要送达并落实；只有完成门能拒绝错误收尾，还不足以减少用户催办。
3. **完成依据来自符合当前要求的真实成果。** 正常探索和必要验证属于任务推进，绿色测试、计划勾选、成员终态、无 finding 都不能单独代表整项完成；独立检查也可能漏检或误报，需要保留证据与纠正路径。
4. **监督开销必须与其作用相称。** 程序处理可计算规则，模型处理需要语义判断的部分；复用仍有效的事实，在相关变化处核验。顶级模型额度、其他模型额度和现金支出分别看，不以跨型号总 token 最少、成员最多或检查最多衡量收益。

因此，每个候选先回答：解决 Orbit 哪个实际交付问题；现有能力还缺什么；怎样改变下一动作或结果；增加哪些交接、模型与维护开销。可先进行小范围验证，不要求事前证明普遍可靠或普遍节省。没有明确缺口的能力保留作参考，不自动成为待办；检查收益未知时如实记录，也不因此停止已有授权工作。

原文把关键日志确认和协议共享列为“第一批”，主要依据它们容易在自有代码内修改，**不足以决定产品优先级，现撤去该排期建议**。现有原始要求、固定快照、独立只读检查、先登记后执行、身份与用量账本、完成复核和停止确认应复用；新增项沿 OMP 单宿主与 native task/hub 接入，避免重复建设宿主执行器。

| 方向 | 对 Orbit 的主要收益 | 采用条件与责任边界 |
| --- | --- | --- |
| 目标、修订、续跑与评审衔接 | 减少目标缩水、无人推进和用户反复纠偏 | 按现有状态注入、amend、唤醒及检查路径核对；详见[工作机制研究](codex-workflow-alignment-20261009.md) |
| 有界成员交接与配置继承 | 用合适模型承接实质工作，保留集成责任 | 复用原生 task/hub 和已有适配建议；同时核对交接与返工开销，见 §8 |
| 长日志首尾保留 | 在现有容量内保留失败结尾，支持正确核验 | 已确认先落局部方案文档；尚未实施，质量与资源收益待观察 |
| 带目标回合条件的修订投递 | 防止纠正进入错误回合或任务 | 先定位现有版本门未覆盖的具体竞态；接收处原子核对依赖 OMP |
| 停止准入与清理完成屏障 | 避免取消后新工作继续或错误报告停止 | 对照当前实际停止证据缺口；关键部分依赖 OMP 原生接口 |
| 权限在工具执行层统一落实 | 降低误阻断、越界风险与参数解析维护成本 | 保留现有 guard，优先核对 OMP 解析后目标和执行政策接口 |
| 关键事件写入确认 | 导出和异常收尾能区分排队、写入与失败 | 仅对影响恢复、归属或诊断的关键事实做窄验证；不阻塞取消 |
| 跨语言协议共享结构 | 减少真实字段分歧及重复维护 | 发生协议漂移或有明确重复成本时采用；无需先统一全仓协议 |
| 结构化故障与重试建议 | 避免重复失败调用，让恢复动作更准确 | 仅补实际丢失的诊断信息；现有分类与跨版本排除继续复用 |
| 模型容量感知 | 避免完整请求溢出或不必要裁剪 | 先核对实际路由与完整请求；属于后续评估，不随日志方案实施 |

## 1. 事件写入要有可等待、可失败的确认

**Codex 源码事实。** `RolloutRecorder` 将追加、持久化、flush、shutdown 分成命令。追加进入队列不等于 flush 成功；后者通过独立确认通道返回 I/O 结果。writer 保留待写项、在失败后重新打开文件有界重试；shutdown 排空失败时不直接结束 writer，调用者可继续处理失败。[recorder.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/rollout/src/recorder.rs#L1048)

这里值得学的是确认边界和错误传播。该文件的写入路径调用 `flush()`，不能据此声称所有数据经 fsync 持久到磁盘，也不能推断断电或硬崩溃不丢数据。

**Orbit 已有能力。** [TaskRecord](../../lib/orbit/task_record.rb) 的成员权威记录已有原子写入与 fsync；[native-call-recorder](../../plugins/native-call-recorder.mjs) 已有串行队列、原子替换、文件/目录 sync 与 flush。不能把建议写成“Orbit 还没有可靠落盘”。

**具体增量。** [omp-host](../../plugins/omp-host.mjs) 的协作日志有序号、恢复和显式 persistence_gap，但追加为 fire-and-forget，队列吞掉失败，进程 shutdown 才排空；[欠账](../plan/debt-ledger.md) 也保留异常退出日志缺失。可先为关键事件和主动导出提供一次可等待的写入确认，返回已写范围与真实失败；普通观察仍异步，不对每条日志做同步写，不改造成全量事件溯源数据库。证据完整性和实际停止应分别报告，日志写失败不能阻止取消，也不能伪造停止失败或成功。

## 2. 跨语言边界由一份结构定义约束

**Codex 源码事实。** App Server 协议类型带序列化、JSON Schema 和 TypeScript 导出定义；仓库有生成代码与 schema 固定产物。当前发布导出读取预生成 stable/experimental 资源，生成器和导出校验在测试路径维护，避免客户端各写一份类型。[turn.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L31)、[export.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/export.rs)、[precomputed_exports.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/precomputed_exports.rs)

**Orbit 已有能力。** [检查结果 schema](../../contracts/check-result.schema.json) 已是权威入口，Ruby [CheckRunner](../../lib/orbit/check_runner.rb)、TS [check-result](../../runners/omp-reviewer/check-result.ts) 也做实际结果校验；[model-call-receipts 声明](../../plugins/model-call-receipts.d.mts) 已有局部类型描述。

**具体增量。** 在 work-unit 派发、模型选择/hint 版本绑定或停止诊断中出现真实字段分歧、重复维护时，针对该载荷复用现有 schema 和协议样例，核对必需字段、unknown/null、版本和身份匹配；是否生成类型按实际收益决定。类型检查不能代替运行时校验，结构正确也不代表原生事实真实。不需要为了这件事引入 Rust、另建 App Server，或一次生成全仓代码。

## 3. 停止先封住准入，再等清理完成

**Codex 源码事实。** Agent runtime 的 shutdown 会关闭工作跟踪器、取消 token、关闭邮箱；start 的准入在取得 membership 前后核对关闭状态，处理 start 与 shutdown 的竞态。清理 membership 保持到结果记录完成，wait 排空后返回结构化失败报告；teardown guard 意外离开也留下失败。[runtime.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/runtime.rs#L37)、[mailbox.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/mailbox.rs)

任务中断路径等待 lifecycle callback 后才构造终态事件；对应测试故意挂住 callback，确认终态没有提前出现。派发尚未接受初始输入时另有 PendingSpawn guard，取消后清理已创建的 child。[tasks/mod.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tasks/mod.rs#L824)、[abort_lifecycle.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/tests/suite/abort_lifecycle.rs)、[spawn_guard.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/spawn_guard.rs)

**Orbit 已有能力。** [停止合同](../../contracts/task-runtime.md#当前停止与资源规则) 已要求取消、abort、reap、工具归零、抑制 owner 后台投递、精确清理任务 marker、重读成员名单与 stop_unconfirmed。这一方向与 Orbit 现行目标一致，不能用 Codex 某个终态标签降低这些要求。

**具体增量。** 按 ADR-008 向 OMP 确定最小原生接口需求：停止期间原子拒绝新的所属工作；可等待的成员 dispose/后台清理完成结果；带阶段的失败报告。Orbit 只能包装可观察的现有信号，不能通过自己的 Promise 伪造宿主内部已停止。Codex 的 `interrupt_spawned_agent` 在 runtime 未加载时也可能返回成功，所以“interrupt 成功”本身同样不是进程退出证明。[interrupt.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/interrupt.rs)

## 4. 异步纠正携带目标回合的前置条件

**Codex 源码事实。** `turn/steer` 必须提供 `expectedTurnId`；runtime 在持有 active-turn 锁时核对目标，不匹配则拒绝。`turn/interrupt` 也携带 thread/turn 身份。Thread 状态和 Turn 状态分别定义，回合完成并不直接表达整个用户任务已完成。[turn.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L308)、[turn_input.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/session/turn_input.rs#L794)、[thread.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1683)

**Orbit 已有能力。** 原生 message_id、显式 amend、输入/产物摘要、工作区和检查编号已约束任务归属；Esc 后以新任务边界续接，旧终态不复活。这些属于现行合同，不应改成“新消息自动修订任务”。

**具体增量。** 对真正依赖当前回合的纠正与控制请求，核对能否在宿主接受处原子校验预期回合及任务绑定。投递前由插件读取一次状态，只能缩小竞态，不能代替宿主接收处的条件检查。跨回合持续有效的 finding 不应机械绑定一个会过期的 turn_id；它应继续使用要求/产物版本，在进入新回合时重新投影。这项先做接口对照，不能仅凭 Codex 的命名新增 Orbit 状态。

## 5. 让权限约束作用于实际执行目标

**Codex 源码事实。** ToolOrchestrator 集中组织工具许可、sandbox 和尝试/失败流程，ToolRuntime 共享执行上下文；apply_patch runtime 使用明确的文件系统 sandbox 上下文和已解析补丁动作。[orchestrator.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tools/orchestrator.rs)、[sandboxing.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tools/sandboxing.rs)、[apply_patch.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tools/runtimes/apply_patch.rs)

**Orbit 已有能力与成本。** [work-unit-scope](../../plugins/work-unit-scope.mjs) 已在成员工具入口落实路径/工具/命令限制，[confined-tools](../../runners/omp-reviewer/confined-tools.ts) 已替换检查者的读工具并限制快照。成员门为正确理解宿主参数，明确复制了 OMP 的行选择器、多路径、glob 和 literal-path 优先语法；维护成本来自和上游解析保持一致。

**具体增量。** 优先推动 OMP 暴露实际解析后的目标和统一执行政策接缝，再让 Orbit 的工作单元约束与宿主权限取交集。读取目标、修改目标和命令进程的约束要落实在各自实际执行处；解析后的路径也不能消除所有文件系统竞态。借鉴这一组织方式，不照搬 Codex 的自动升级 sandbox 策略，不扩大权限，也不取消现有只读限制。

## 6. 上下文按模型容量裁剪，长日志保留首尾

**Codex 源码事实。** 工具输出有保留固定前缀、最新后缀及真实省略字节数的 HeadTailBuffer；历史裁剪使用模型 context window 和 token 估算，并保留调用输出的关联字段。compact 路径区分真实用户消息与 compaction summary，并维护初始上下文的插入位置。[head_tail_buffer.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/unified_exec/head_tail_buffer.rs)、[compact_remote_history.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/compact_remote_history.rs)、[compact.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/compact.rs#L567)

**Orbit 已有能力。** [CheckRunner](../../lib/orbit/check_runner.rb) 已把程序上下文限制在 64 KiB，按确定性顺序降级、明确省略和摘要，保留原始要求/修订/依据，并使用 review_focus 引导读固定快照；不是每轮无限复制全部历史。

**具体增量。** 首尾保留针对测试输出和故障日志，避免只留前缀丢失失败总结；结构化退出码须单独保留。容量感知另需核实完整请求是否存在实际问题，才决定是否利用真实路由 context window 调整输入预算，计入原文、工具定义和输出预留；目录容量不能冒充实际路由限制。原始要求超容量时报告真实缺口，不静默用生成摘要替代。最终独立检查仍覆盖整体要求，review_focus 只是读取线索，不变成只看增量的完成门。程序上下文压缩、OMP 会话历史压缩和成员交接材料属于不同路径，详见[上下文方案](../plan/context-compression-proposal.md#上下文的三条路径)。

这可能降低输入重复和上下文溢出，但没有本次真实数据证明 token、费用或质量改善；应在同一代表任务和同一检查范围比较实际用量与漏检结果后再决定。

**后续确认（2026-10-09）：**用户确认“可以，先落文档”。已将优先长日志首尾保留、限定字段与原始证据边界、验收条件及容量感知的后续评估写入[上下文压缩增量方案](../plan/context-compression-proposal.md)。当前仅文档授权，未实施；这不构成其余借鉴项的实施授权。

## 7. 故障事实与重试策略分开

**Codex 源码事实。** CodexErr 保存语义错误类别与可选 RetryAfter，并按类别返回重试延迟或不重试；调用方另行控制重试预算。用量耗尽、请求无效与瞬时连接/流/限流故障有不同路径。[error.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/protocol/src/error.rs#L393)

**Orbit 已有能力。** [provider-error](../../runners/omp-reviewer/provider-error.ts) 已读取 SDK 公共分类信息，区分 auth_or_quota 与 unavailable，且不把普通 429 都当额度耗尽。最近余额失败跨产物保持排除和显式恢复证据已有接线，不能把已修复问题列为新待办。

**具体增量。** 上游可得结构化类别、状态和 retry-after 时原样保留，再由现有 Orbit 选型/恢复规则决定是否重试、何时重试、是否换型；模型输出 JSON 不合规继续属于独立结果问题。先补实际丢失的诊断字段，不为更漂亮的 taxonomy 重写现有失败体系，不增加默认预算硬门，不自动重新启用账户失败目标。

## 8. Subagent 派发：配置、上下文、创建失败与回报归属

2026-10-09 用户后续询问 Codex 的 subagent 派发机制是否值得借鉴。本节是补充研究，不构成实现或切换宿主的决定。

**上下文继承要区分历史与授权。** Codex 的派发配置区分完整历史 fork；fork 路径标记继承消息，剥离父会话本地授权相关元数据，且不继承父会话累计 token 用量。源码提示还明确，历史工具调用不意味着成员继承了活跃工具会话或进程句柄。[child_config.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/child_config.rs)、[spawn.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/spawn.rs#L1129)

Orbit 已通过工作单元提供目标、版本、上下文、实际工作区与权限，并记录实际成员/调用用量。可以借鉴“按任务需要选择上下文来源”的原则：有界独立单元使用明确交接材料，需要大量共同背景的工作再评估宿主支持的历史继承方式。完整 fork 也可能重复发送无关历史，不能默认更省。无论哪种方式，继承历史都不能扩大工作单元权限、迁入 Root 用量或让旧检查成为当前成员通过依据；不要把 Codex 的 fork 开关直接当成 OMP 已有接口或已证明省 token。

**成员配置从当前执行设置派生。** Codex 构造 child config 时使用调用步骤的模型/推理设置，并应用当前回合的 cwd、审批和权限快照；角色设置之后再次落实运行时约束，以避免只复制旧配置导致身份与权限漂移。[child_config.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/child_config.rs#L102)

Orbit 已校验实际候选身份、工作区和受控范围，也会重建成员当前项目规则。增量价值在于核对宿主实际解析后的配置、工作单元声明和首次真实请求是否一致；这不能代替 Jev 适配或用户模型池决定，也不能把角色名当成实际模型。当前 Root 型号不能自动成为所有成员型号：成员按任务适配与有效选择运行，显式选择优先，权限继承与型号选择分开核对。

**派发收益要回到实质工作替代。** [产品主方案 §4/§5](../plan/mixed-model-delivery-proposal.md)已明确：串行接力也可以有价值；Root 保留规划、集成与必要核验，成员承接完整有界工作，避免重复实现和过细拆票。此次 Codex 阅读证明了派发控制做法，没有证明异构模型选择、顶级额度节省或最佳成员数量。评估应包含必要交接、Root 复核、成员失败和升级开销；短小低收益任务可直接执行，不把派发本身当成成果。

**创建成功、初始输入接受与失败清理分开。** Codex 的 PendingSpawn 持有已创建的 child，直到派发后续步骤成功解除 guard；中途失败或取消会清理 child，等待 shutdown，并记录清理失败。runtime 准入与停止共用所有权跟踪。[spawn_guard.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/spawn_guard.rs)、[spawn.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/spawn.rs#L847)

Orbit 已有首个模型工作前持久登记、派发调用与成员绑定及失败结算。最值得继续对照的是“原生成员已创建但派发未完全成功”与“停止时派发尚在途”的收尾证据；需要 OMP 原生完成信号的部分优先确定最小上游接口，继续诚实保留 stop_unconfirmed，不另造执行成员。

**回报绑定实际成员与发起回合。** Codex 的完成通知携带 child thread、agent path 与父回合等身份，并将结果投递成功与否单独观测；成员终态只是执行结果。[completion.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/completion.rs)

Orbit 已有更具体的工作单元、实际派发调用、结果接收/核验和独立终检门。应核对回报链是否沿这些真实身份闭合，不把成员自报完成或父会话收到消息当成整体交付通过。该研究不建议开放多层成员派发；当前一层 OMP native task/hub 与 Root 集成责任保持。

## 如何验证这些借鉴，而不过度建设测试

用户后续要求从 Codex 整体工作机制评估防偏航，Goal 只是例子。规划/执行、Goal、用户修订、进度、Review、Guardian 和恢复上下文的补充对照见[工作机制与防偏航研究](codex-workflow-alignment-20261009.md)；程序约束、模型提示和独立验收分开说明，尚未进入实施。

Codex 的 abort_lifecycle 测试用可控异步 gate 和模拟模型事件检查真实时序，挂住清理后确认终态尚未发布；比单纯检查函数调用次数更接近用户风险。pending_input_persistence 也沿准备/执行 checkpoint 构造受控输入和事件。[生命周期测试](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/tests/suite/abort_lifecycle.rs)、[输入持久化测试](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/tests/suite/pending_input_persistence.rs)

Orbit 已有确定性 gate/fixture 与真实 OMP 验收。后续只为本次选中的真实风险补少量场景，例如停止与派发竞态、写入失败时导出显式缺口、修订目标回合已改变；复用现有测试入口。模拟通过不证明模型自然遵循或宿主实际退出，实际接口接缝仍按仓库真实验收要求验证。质量与资源效果应分别观察交付遗漏/误报、人工催办/纠偏、实际工作替代、调用失败/过期及可归属资源；不为一个确定性日志裁剪改动强制建立完整经济对照或常驻统计平台。

## 当前不建议移植的部分

- 不因 Codex 有 App Server 就恢复 Codex 宿主或替换 OMP；这会改变 ADR-008，研究没有产生该授权。可借鉴结构化控制协议，不需要增加一种宿主。
- 不扩展为多层 Agent 树。上述 shutdown ownership 可用于 Root、单层成员与后台工作的归属，不必照搬 Codex 的整套树/驻留/邮箱存储。
- 不让模型摘要成为任务或停止事实来源，也不把 turn completed 当 Orbit task complete；原文、固定产物、独立终检和停止证据继续有各自权威。
- 不从这些源码推断 Jev 校准、异构模型适配或整项费用收益已有替代方案。本次阅读的运行控制代码不足以证明这些产品效果。

## 建议的下一步

当前具体产出包括[上下文压缩局部方案](../plan/context-compression-proposal.md)、[工作机制研究](codex-workflow-alignment-20261009.md)与[实施依据及总清单](../plan/codex-lessons-implementation.md)。用户已确认先落文档，后续授权审视和补齐实施准备；本对话仍未启动实施。新 Root 沿总清单的 C01—C10、采用条件、宿主依赖与验收推进，先核对实际基线，不再另建同内容总体方案。协议共享和日志确认不预先占据第一批；需要宿主能力时以最小真实接口为依据。

原研究阶段新增本页与索引；后续按用户要求补上下文方案、交接、subagent 与工作机制研究，本次按核心诉求重排评估依据。没有修改运行代码、合同、版本或安装，没有提交或推送。临时 Codex 源码副本已删除，复核依据保留为固定提交链接；后续核对直接读取同一固定提交源码。

# Codex 借鉴项：Orbit 实施依据与总清单

**当前交付（2026-10-10）**：剩余问题交付 Goal 已实际工具启动并最终 `complete`（06:10:16Z），无资源硬预算。本轮冻结验收、全部采用验证与资源收尾沿 §9；下方旧轮次历史保留，当前完成由本轮实际原件证明。

更新：2026-10-10。前轮实施、验证及资源收口已结束，实际 Goal complete，无 token 硬预算；其具体改动与受测范围保留。用户随后要求重新评估全部决定，最新判断沿[重评记录](../reference/codex-decisions-reevaluation-20261010.md)：撤回 C02/C04/C06 的充分满足结论，C08 改为局部共享且仍有重复维护；C01/C05/C07/C09 保留，C03/C10 不立即扩大实现。重评是评估交付，不将建议伪装成已实现能力或重写旧 Goal 回执。本文件仍为唯一实施总 TODO；未授权发布、推送或全局安装更新。

基线：源码 0.8.3，HEAD `9f5e66db681ac312d12f2f1f1c70cc804bcaad38`，另有本次文档修改及未跟踪文档。开工已核对三个 OMP 的 live 身份、型号及可接任务状态（见§7）；共享工作区带入了全部必要未提交文档。

## 1. 目标、依据与范围

目标沿[产品主方案](mixed-model-delivery-proposal.md)：在质量、权限和可接受错误风险下，用有限顶级模型资源完成更多有价值工作，减少用户监督、催办与纠偏。借鉴项要帮助真实交付、实质工作替代或降低有效监督的开销。

权威语义仍是[任务合同](../../contracts/task-runtime.md)、[ADR-008](../adr/008-omp-native-collaboration-base.md)、[ADR-009](../adr/009-user-selected-model-pool.md)。研究依据为[源码研究](../reference/codex-source-lessons-20261009.md)、[工作机制研究](../reference/codex-workflow-alignment-20261009.md)；C01 的具体设计沿[上下文局部方案](context-compression-proposal.md)。开发遵守 [AGENTS.md](../../AGENTS.md)与[开发流程](../agents/development-workflow.md)。历史完成与未测边界沿[交接](handoff.md)、[当前限制](debt-ledger.md)和[长任务验收](../reference/long-task-optimization-acceptance-20261009.md)。

本轮已交付两部分：**C01 长日志首尾保留的实现与验证；C02—C10 的逐项处置，以及其中经核实、符合现行边界的采用项的实施与验证。** 后者不要求全部改代码，也不允许全部以“以后再看”收口。每项都须有现状、证据、处置与理由，完成范围在代码修改前记录清楚。

采用条件：存在具体未被当前机制覆盖的问题、已知结构缺口或明确重复维护成本；有可验证的最小改动；收益与交接/模型/维护开销相称；遵守现行合同与宿主边界。已有能力按证据覆盖范围复用，不能仅凭相关代码存在或未发现新 incident 判定完整目标已满足。条件不成立的项保留研究结论。存在必要前置但不可用的项记录具体阻断，不伪造接口或通过。

新增产品语义、权限扩大、宿主替换、Fork 或新外部资源由用户决定；普通工程选择由 Root 处理。已完成 T01—T13、所有型号认证、全域收益证明、通用模式平台、独立 Goal 数据库、统计平台和资源硬预算不纳入本轮。当前研究不授权全局安装更新、发布、推送或升版。

2026-10-10 文档补充：用户要求先记录 C08 单一协议定义方向。下一轮局部采用方案以现有 check-result.schema.json 为共有结构源，减少 TS/Ruby 手写结构重复，保留必要语义校验并以少量共享样例核对一致性；不换语言、不建全仓生成平台，当前未实施。C01/C05/C07/C09 保留已验证局部实现，不能统称完整机制已经足够或获得 Codex 大型项目验证；尤其 C05 的宿主原子关闭准入／失去session退出信号仍未解除。具体来源、差异与充分性沿[重评补充](../reference/codex-decisions-reevaluation-20261010.md)。该记录不另建总 TODO、不改变前轮实际 Goal 与测试结果。

## 2. 候选逐项处置表

下表保留 2026-10-09 前轮处置和实施事实，**不是最新充分性裁决**。C02/C04/C06/C08 的旧“满足”标签已由[逐项重评表](../reference/codex-decisions-reevaluation-20261010.md)修正；后续不能沿旧标签免除实际交付缺口。前轮采用项均已完成；完整构建、代码／确定性／真实验证及限制沿[验收记录](../reference/codex-lessons-acceptance-20261009.md)，候选评估不替代运行结论。

| ID／方向 | 前轮源码入口与事实 | 前轮核对与最小采用边界 | 前轮处置（最新判断见重评） |
| --- | --- | --- | --- |
| C01 长日志首尾保留 | [回执采集](../../plugins/root-verifications.mjs)先裁剪 output；[检查输入](../../lib/orbit/check_runner.rb)再次裁剪，均只留前缀 | 按 §3 和上下文方案实施输出专用策略，联通两处投影 | 采用／完成；K3主写两层策略，Root核查；真实125字符降级发现marker-only失败，Root补日志最低500字符预算，GLM独立核查及回归通过；新构建真实两层链通过：125普通预算下日志500字符首尾保留，最终51465bytes；失败原件保留。 |
| C02 目标、授权阶段、下一动作与恢复 | [statusBlock/continuationBlock](../../plugins/omp-host.mjs)已有阶段、下一动作、原要求来源、amend 和续接纪律 | 对照原要求→有效修订→请求注入→下一动作；仅修实际丢失点。核对当前交付与整体目标的归属，保留 D1，不另建模式状态机 | 已有能力满足：原文／amend／continuation来源及状态下一动作已接线；本轮未定位新的丢失点。复用T03/T04有界证据，整体目标不另存权威。 |
| C03 异步修订与目标回合条件 | [宿主桥](../../plugins/omp-host.mjs)、[运行时](../../lib/orbit/task_runtime.rb)已有任务/版本门、消息身份和送达观测 | 只对依赖当前回合的控制核对接收处条件；跨回合 finding 沿输入/产物版本。插件投递前读取不能冒充原子接收 | 条件未成立：现有输入／产物版本和真实消息身份门复用；接收处原子expected-turn接口未核实可得，不将发送前读取称原子。上游建议保留，不采用新回合状态机。 |
| C04 成员交接、配置、失败收尾与结果归属 | [工作单元](../../lib/orbit/work_unit.rb)、[宿主门](../../plugins/omp-host.mjs)、[调用记录](../../plugins/native-call-recorder.mjs)已有实际身份、显式型号优先、先登记与结果绑定 | 核对已创建但派发未成功、取消时派发在途、当前配置与回报归属；材料按需交接，Root 做必要集成，保留已有模型适配/阶段选型 | 已有能力满足（原生task/hub路径）：真实注册前登记、当前显式型号、派发绑定与失败结算已覆盖；在途/park缺证仍保持stop_unconfirmed。新正例eval agent非该受控接缝，未登记作业不计成员；用户纠正后原生路径真实登记和接受交付，不新建执行器或将eval agent扩为新受控接口。 |
| C05 停止准入与清理完成 | [宿主 stop_member/保留会话](../../plugins/omp-host.mjs)、[运行时停止门](../../lib/orbit/task_runtime.rb)已有 dispose 等待、后台收尾与名单复核；失去 session 后仍有上游限制 | 核对停止期间新工作准入与清理结果；已有可等待路径复用，缺信号保留 stop_unconfirmed | 采用／完成；实现／runtime回归／GLM独立核查通过：只在完成交接执行停止后名单复核是实际缺口；复用同一复核于普通／失败停止，晚登记或不可读名单保持stop_unconfirmed和已验证执行范围。宿主原子准入关闭／失去session退出证据仍为限制。 |
| C06 工具执行目标与权限 | [成员范围门](../../plugins/work-unit-scope.mjs)、[检查者工具](../../runners/omp-reviewer/confined-tools.ts)已有实际限制；成员解析需跟进 OMP 语法 | 只有具体语法漂移/误阻断/越界证据才修；核对宿主解析后目标接口。保持当前 guard 和只读，测试正常合法工作与拒绝越界两侧 | 已有能力满足（当前语法）：保留raw-input范围门和独立只读工具；实际pi-natives顶层18.3.4／宿主18.8.0版本错配但行为差异未知，未定位具体语法漂移。真实成员声明npm test进入沙箱后因NVM npm-cli.js位于workspace和现有系统库例外之外而EPERM；固定GLM核实属既有读权限限制，非范围门误阻断。放开NVM依赖涉及新增workspace外读权限，本轮不采用；Root承担验证。声明的node placeholder不是实际命令，不扩字面匹配。解析后统一目标接缝尚不可用，保留上游建议。 |
| C07 关键事件写入确认 | [协作 writer](../../plugins/omp-host.mjs)异步追加，失败保留 gap，进程 shutdown 排空；[证据导出](../../lib/orbit/task_evidence.rb)已做缺失核对 | 定位需要确认的关键消费者和切点，返回真实成功范围/失败；不将所有日志同步化，不以日志失败阻塞取消。导出的现行只读截取语义保持 | 采用／完成；实现／真实I/O回归／GLM独立核查通过：真实Root停止已取消/abort/reap后返回当前任务writer队列cutoff的append确认、seq、gap/失败范围。日志失败不改变停止confirmed；不改export只读截取。 |
| C08 跨语言协议共享 | [检查结果 schema](../../contracts/check-result.schema.json)、[TS 校验](../../runners/omp-reviewer/check-result.ts)及 Ruby 已有局部共享与运行时校验 | 有真实字段分歧或重复维护时，只对对应载荷复用 schema/样例；先查现有校验，不做全仓生成平台 | 已有能力满足：检查schema、TS/Ruby运行校验复用；两侧语义校验严格于生成schema是已有合同要求，未定位实际互相分歧，不建生成平台。 |
| C09 结构化故障与恢复 | [provider-error](../../runners/omp-reviewer/provider-error.ts)、[运行时](../../lib/orbit/task_runtime.rb)已有账户/瞬时/格式分类、排除和恢复规则 | 查实际可得但丢失的类别/状态/retry-after；仅补诊断传递，保留账户失败跨版本排除，不重建 taxonomy 或恢复旧失败目标 | 采用／完成；实现／provider回放／GLM独立核查通过：SDK-public errorStatus/errorId此前未结构化传递，现保留为evidence.error.status/error_id，缺失null；kind/detail和账户排除/恢复保持，retry-after不可得不造。 |
| C10 完整请求容量感知 | [CheckRunner](../../lib/orbit/check_runner.rb)已有程序上下文 64 KiB 上限，原要求另行提供；目录容量不等于路由限制 | 有实际完整请求容量问题且路由限制可核实时才调整；计入原文、工具与输出/读取压力。容量未知沿现有规则 | 条件未成立：有实际OMP目录路由限制投影，但本轮没有完整请求溢出的事实；保留64KiB程序上下文边界，原文/工具/后续读取不冒称已纳总token预算。 |

独立验收、授权与交付质量分离、有效事实复用、监督开销，以及压缩/交接的来源保护是各项共同约束，不能因未另列一个编号而省略。候选表没有声称现有机制在所有模型、所有回合自然生效。

## 3. C01 可直接实施的接缝与验收

实施前源码定位：

- [root-verifications.mjs](../../plugins/root-verifications.mjs) 的 `TEXT_CAP=4000`、`boundedText` 按 JS 字符串长度保留前缀，`buildReceipt` 对 bash/eval 的 output 使用它；command/script 同时使用此 helper，文件工具不保存正文。
- [CheckRunner](../../lib/orbit/check_runner.rb) 的 `build_compressed_context` 对回执调用通用 `bound_value`，后者经 `bound_string` 再留前缀，并设置 output_truncated。仅改 Ruby 会看不到 JS 已丢掉的尾部。

最小改动候选文件为这两个投影模块及对应既有测试；沿真实结果路径确有更早可控裁剪点时才扩展。bash/eval **输出**使用专用首尾策略，command/script 与其他字符串保持现有语义；不为日志建立通用摘要系统。每层沿既有限额为标记留空间；Ruby普通字段降级时日志至少保留500字符（原最高2000不增），最终64KiB硬门仍优先。Unicode 裁剪保持有效文本，最终程序上下文不超过 65,536 bytes。

省略标记包含该层可见输入的原始长度、明确单位及 SHA-256，既有 output_truncated 和上游截断事实保持真实。二次裁剪后仍保留可见两端与已有来源/省略事实，避免把旧标记重复包装到无法判断范围；实施者可选最小字段或标记表达，不改变裁决含义。历史前缀日志不恢复不存在的尾部，也不重写历史。

| 条件 | 冻结的可观察结果 |
| --- | --- |
| 原生 bash/eval 可见输出超过 JS 限额，开头与尾部有不同有用事实 | 当前持久回执保留两端和省略事实；身份、状态及执行结果来源不变 |
| 回执再进入 Ruby 字符限额/多日志压力降级 | 最终检查输入仍保留选定日志的可见两端，JSON 可解析且不超过 64 KiB；必要裁决事实按原规则保留或明确未送达 |
| 短日志及 command/script、文件工具回执 | 短输出保持原文；非日志字段策略不被顺手修改，文件工具仍不保存内容/patch |
| 上游已截断、旧版本、失败、unknown 或后台启动回执 | 截断与版本/结果局限保留；尾部文字不成为成功、当前覆盖或完成的证明 |
| 真实安装路径 | 原生工具输出→持久回执→当前检查实际输入的链路可追溯；独立检查来源、固定快照和实际停止有记录 |

相关既有入口：`node tests/root_verifications_test.mjs`、`node tests/root_verifications_file_tools_test.mjs`、`ruby --disable-gems tests/check_runner_context_test.rb`。补少量两层裁剪、Unicode/大小和证据资格场景，遵守测试规模纪律；不为每种字符或任意字段排列造用例。该项落地时同步合同中长文本裁剪描述的局部例外与实际限制，不借此改变完成资格。

## 4. 宿主依赖及核对结果的表达

以下描述的是所需能力，**不是声称 OMP 已有同名 API**。Root 从实际版本、源码/官方接口和隔离接缝核对，记录可得、缺失或未知；不凭字段名称或 UI 状态认定支持。

| 涉及项 | 所需最小信号 | 接缝不成立时的结果 |
| --- | --- | --- |
| C03 回合纠正 | 接收处在同一有效状态下核对所属会话/任务及预期回合；不匹配明确拒绝或重新归属 | 沿现有版本门如实说明竞态边界，不把发送前检查称原子保证 |
| C04/C05 创建与停止 | 模型工作前的真实 child 身份；在途创建归属；关闭后拒绝新所属工作；可等待 dispose/后台收尾及失败结果 | 已有保留会话路径继续；失去执行证据保持 stop_unconfirmed，列最小上游需求 |
| C06 权限 | 实际执行前可取得解析后的各读取/修改目标与命令约束，能与工作单元范围取交集 | 保留当前范围门，只修已定位兼容问题，不绕过限制 |
| C07 写入确认 | 指定任务与截至切点的队列排空结果，已写范围、未写/gap 与真实 I/O 失败各有表达 | 导出继续按实际读到内容及缺失清单报告；不声称 flush 即断电持久化 |

宿主必要缺口不能通过 Orbit 的 Promise、模型说明或伪回执消除。采用项若必须依赖缺失能力，应标阻断并报告影响，不在临近结束时改成“条件未成立”消掉完成要求。未采用的上游增强可以形成明确接口建议而不阻塞独立的 C01。

### 本轮采用范围与验收冻结（2026-10-09）

C05新增事实（Grok只读审计、Root源码核实）：`TaskRuntime#stop`原来仅在completion notice路径复核停止后名单，普通／失败停止遗漏。采用范围限task_runtime.rb既有复核外移及task_runtime_test.rb少量回归；冻结验收为普通／失败／完成停止都不能确认未处理新成员或不可读名单，已验证Root/member范围独立保留，不新增停止状态或假原子准入。已有task_runtime测试修改前通过。

C01沿§3。C07限定 `plugins/omp-host.mjs` writer与stop回执、既有collab测试：停止前的取消／abort／reap优先完成，随后捕获队列cutoff；截至该cutoff的append完成、已写seq、当前进程的失败观察／gap和真实错误有范围记录，恢复不抹失败；日志失败或诊断等待未确认不改变实际停止裁决，不改现行export只读语义，不声称fsync／断电持久化。TaskRuntime既有原始stop_confirmation保存就是消费者，无须新CLI或全量同步。C09限定 `provider-error.ts`、`reviewer.ts`及既有provider-error断言：SDK实际HTTP status与errorId安全数值作为诊断原值保留、缺失null，不扩充taxonomy、不解析自由文本RetryAfter、不改变账户失败跨版本排除。真实故障不人为制造，确定性错误回放与正常独立检查路径分开记。

采用前已有相关测试：C07 `omp_collab_evidence_test.mjs`通过；C09 provider-error 4/4通过。C01由主要执行者先跑§3已有入口。独立核查不得由写者自评；真实验收冻结为§6。

## 5. 顺序、协作与热点

1. Root 核对基线与现有证据，逐项填写 C02—C10 处置，冻结实际采用项的缺口、文件范围、依赖和验收；C01 沿 §3。新增事实可调整实现路线，不能静默降低完成条件。
2. C01 两处裁剪作为一条完整行为交给一个主要执行者，避免 JS/Ruby 分头定义不同省略语义。独立采用项在前置就绪后并行，涉及同一宿主文件的修改串行集成。
3. Root 集成、相关验证、适当独立核查、针对性真实验收、文档与资源收尾；有效已有结论复用，修复后核对原问题与直接影响。

已有三个 OMP 的用途在开工时通过 [Herdr skill](/Users/yangke/.agents/skills/herdr/SKILL.md)及 live 状态确定，不预设 pane ID、型号或可用额度。只有确认可接任务且在用户指定范围内的成员承接工作。可安排一个主要实现者、一个确有独立工作面的执行者，以及一个未参与对应实现的核查者；这是可选分工，不要求三席始终满负荷。

并发 worktree 带入必要的未提交/未跟踪文档及规则，不丢当前成果。`plugins/omp-host.mjs` 是 C02—C07 的共享热点；`check_runner.rb` 与检查 schema/合同由明确 owner 集成。每条完整行为一个主要写者；评审者先读原要求与产物，再看作者说明。成员按开发流程接收八项派发信息，不维护总 TODO、不提交推送、不二次派发。

这三个 OMP 是**开发 Orbit 的执行者**。真实验收中的执行成员另由新安装 `orbit omp` Root 通过 native task/hub 实际派发；不能把开发协作回报当作产品运行证据。

## 6. 验证范围与证据

开始真实验收前完整读取 [orbit-real-acceptance](../../.agents/skills/orbit-real-acceptance/SKILL.md)及其 scenarios，在隔离 Git 项目和临时安装按实际受测构建冻结路径。最小矩阵沿该 skill：一文件负例、有界交接正例、独立 OMP 固定快照只读来源、原生中断与正常退出/停止；未改变 rebind 语义时不新增 rebind 路径。C01 的真实长输出在正例的正常工具执行与验证中观察，控制者不注入假的工具回执或替 Root 实现。

采用项再增加与缺口直接相关的路径：C02/C03 看纠正后的实际下一动作和归属；C04/C05 看派发在途与停止证据；C06 同时看合法操作与越界；C07 看真实失败/gap 与消费切点。可确定的竞态或 I/O 故障用可控确定性场景，真实模型行为另行取证；不要求每种危险故障在活会话强制制造。未采用项不新增模型证明门，历史自然分支未测标签保留。

实施后先相关测试，再按 skill 完成仓库全套测试、打包 dry-run、skill 校验与差异检查。一次验证结果覆盖对应有效版本；后续仅在代码、失败或未解除疑点变化时重跑必要部分。性能/资源收益不作未经基线支持的硬完成门。

本文件同时作为总 TODO，Root 在此记录各采用项实现/验证状态及简短证据链接；详细真实证据按仓库惯例进入本轮 `docs/reference/` 验收记录，避免复制全部日志。记录构建/安装摘要、原要求、输入/产物版本、实际调用/成员/型号、独立检查范围和停止结果，失败与未跑保留原标签。用量按角色/型号及实际单位记录，未知现金/套餐扣减保持未知；不宣称普遍节省。

## 7. Goal 的完成标准与当前 TODO

新 Root 收到实施指令后使用实际可用 Goal 能力，目标为 §1 的完整交付，恢复时沿本文件保留未完成与阻断事实。Goal 状态是开发执行记录，不替代 Orbit 产品的终检与停止门。

- [x] 核对基线、三个 OMP live 状态与实际可用资源，保留当前文档和改动。HEAD 9f5e66d／源码0.8.3；固定 pane w23:p1/pH/pJ/pK，OMP PID12801/12883/12966；三者本仓 idle、18.8.0，型号分别 K3-256k／cursor/grok-4.7-500k-fast／zhipu-coding-plan/glm-5.3-flash。本轮未提交文档均在共享执行仓可读，未另建执行 worktree。
- [x] C02—C10 全部有最终处置、依据和必要接口结论；采用C05/C07/C09，实际采用范围与验收已冻结。
- [x] C01 与全部采用项已实施、集成，相关验证和适当独立核查通过。C01主写K3／Root核查，真实降级修复主写Root／GLM核查；C05/C07/C09主写Root／GLM核查；相关回归及修复后全仓npm test通过。
- [x] 所选构建的必要真实路径已通过；失败、未执行或必要阻断未被改写成通过。负例／原生Esc／正常退出、推荐native task／显式hub／finding纠正及独立停止有界实证；Ruby日志补修后新3ea4a306构建真实C01链和独立终检／Root成员stop通过，其他未变宿主路径沿实际原构建复用，不重标版本。
- [x] 合同局部描述、研究当前状态、索引、交接与限制已同步，未测范围准确。四个采用项、C06 NVM及非受控eval agent边界均沿实际证据，不重开T01—T13。
- [x] 本轮自建进程/后台工作、隔离安装与无用临时资源已收尾，原有三个 OMP 保留。七个pane和所有已登记测试PID／shell均退出并删除；临时安装支持路径卸载、夹具／会话／独有overlay／临时根及本轮/tmp文件清理，必要证据归档。固定Root／三个OMP／所属MCP／主Herdr均在，日常安装摘要未变。

以上全部成立才标 Goal complete。采用项尚受必要上游/环境/验收阻断时保持未完成，继续独立可执行工作，并按真实 Goal 工具规则报告阻断；不能为了 complete 事后删掉采用项、弱化验收或重开一个 Goal 清除失败历史。新产品决定与无法替代的输入缺失才需要用户介入，普通工程选择继续推进。

当前结果：实际 Goal complete，代码、候选处置、相关及全仓验证、独立核查、必要真实验收均完成，文档和资源也已收口，全部冻结完成条件真实成立。C01真实125预算失败原件保留；Root500字符修复在新安装3ea4a306…真实JS4000→Ruby500链通过，程序上下文51465bytes，独立有效终检complete、Root／登记成员confirmed stop。推荐／显式hub／finding纠正、负例与原生中断／退出沿实际各受测构建有界证据，不重标旧构建。七个新pane与已知归属进程均退出／删除，夹具与overlay清理、临时安装已卸载；资源最终归档与临时根清理完成。日常安装与固定OMP不改，用户额度／现金扣减未知，不宣称节省。


## 8. 新对话可使用的启动指令

```text
项目：/Users/yangke/Personal/omen/orbit。
请启动当前实际可用的 Goal，按 docs/plan/codex-lessons-implementation.md 完成整轮交付。
本条指令授权评估、实施、必要验证和文档/资源收口；此前仅文档授权现扩展至这些阶段。先读该清单及其权威依据，直接沿其维护总 TODO，不停在重复规划或另建同内容计划。
实现 C01；逐项核实 C02—C10，依据采用条件决定处置，实施全部符合条件的本轮采用项。普通工程选择自主处理，实际缺口和采用条件未核实时不凭研究建议改代码。新产品语义、扩大权限、宿主替换/Fork 或新资源需求报告给我，不用伪接口替代。
同组已有三个 OMP 可作开发执行者。按 Herdr skill 与 live 身份/状态复用，Root 负责整体目标、集成和验收，合理安排实质工作与独立核查，保留原有会话。当前未提交和未跟踪文档也属于执行依据，要带入所需工作区。
按清单冻结验收，使用 orbit-real-acceptance skill 在隔离项目和临时安装验证真实路径，开发 OMP 回报不冒充产品证据。所有采用项完成且必要验证/收尾通过后才将 Goal complete；必要验收失败或未跑保持未完成，继续有用工作并报告具体阻断。
不新增资源硬预算，不发布、不推送、不升级全局安装、不把升版当完工门。过程中简短报告实际进展，状态追问及时回答后继续主线。最终说明各候选处置、实际改动、验证范围、限制和资源收尾。
```


## 9. 剩余问题交付（2026-10-10，当前执行）

授权：用户本轮原始要求；评估、实施、必要验证、独立核查、文档与资源收口已授权。C02/C04/C06/C08 是必交付能力，不能沿旧“已有满足”免除。保留 C01/C05/C07/C09 实际修改及旧 Goal、T01—T13 验证边界。新增产品语义、具体项目外权限、宿主替换/Fork、新外部资源须报告决策；普通工程选择自主推进。不提交、推送、发布、升版或更新日常安装。

基线：HEAD 9f5e66db681ac312d12f2f1f1c70cc804bcaad38，源码0.8.3，全部既有 dirty/untracked 工作原地保留。临时根由 `/tmp/orbit-codex-delivery-current` 指向；baseline 保存工作差异、固定pane/进程、历史屏幕与日常安装。旧运行原件已在 docs/reference/evidence 留存。三个固定 OMP cwd 均为本仓、idle，18.8.0；原 pane `/new` 成功、PID 不重建：pH12801 K3-256k（路线精确身份待本轮回执核对）、pJ12883 Grok4.7 Fast、pK12966 GLM5.3Flash。Root p1 wrapper38007/codex38008，主 Herdr2145/客户端2144，固定 shell/MCP 保留。 Root实际新Codex session `01a123d6-9986-7d12-b447-f6ebcffb40e9`，session_meta为2026-10-10T03:23:49.034Z、forked_from_id=null，原进程不重建；与本轮Goal thread一致。

依赖与所有权：K3 主写 C02（omp-host/task_runtime 及相关测试）；GLM 主写 C08（schema结构派生、check-result/check_runner 及相关测试）；Grok 先只读核实 C04/C06/C05，随后主写 C06 初版；两次模型回合仍反复展开环境研究，Root 保留其实际改动并以原生 Esc 暂停回合（固定 PID12883 不变），接管 work-unit-scope 的窄修正与集成；Grok 转为 C08 独立只读核查。热点 omp-host 先归 C02，C04 集成待释放；合同与总 TODO 仅 Root 修改。每个主要写者直接读固定 Codex commit 36ae1561b9324c93d5638b45eb19fe2cc070a581 对应调用链与测试，不读取其工程指令；成员不二次派发、不提交、不修改总 TODO。独立核查交叉安排。

### 实现前冻结验收

| 能力 | 必要可观察结果 |
| --- | --- |
| C02 | 普通请求、amend、自定义唤醒、压缩/恢复后的实际 provider 请求包含当前 task 原要求/有效修订及授权约束，来源与版本可追溯；复用现有生命周期，真实在途等待、重复失败恢复、终检、暂停和停止互不冒充。工具/消息/TODO数量不证明有价值进展。至少一条无 Controller 催办或代写的实际主线自行推进到必要检查和收口。 |
| C04 | 原生 task/hub 的当前工具参数、材料/范围、真实身份/型号、首模型工作前登记、结果归属和Root集成实际成立；针对已发生的接口/环境失败，诊断改变下一次真实调用，或有证据说明Root接管。后者不计委派成功。禁止未登记 eval 绕行。 |
| C06 | 派前只读识别实际工具/路径/材料/依赖缺口，合法路径能实际执行，越界仍拒绝；NVM/npm 缺口有具体责任与可用恢复，不能仅Root绕行记解决，不执行有副作用命令冒充预检，不默认扩大读取权限。 |
| C08 | check-result.schema.json 成为共有结构单一来源，实际减少TS/Ruby字段、枚举、额外键规则重复；两侧实际运行结构一致，非空/长度单位/覆盖/版本/身份等业务语义保留。fixtures只辅助验证。 |
| C05 | 直接核实当前 SDK 原子关闭准入、等待已有成员清理及丢失session可靠状态信号；可用则接入实测，不可用则记录准确接口缺口/方案/影响，保留stop_unconfirmed。若阻断必要验收/采用承诺，Goal不完成。 |
| C01/C03/C07/C09/C10 | 各项五维处置可追溯：当前问题、固定源码/前提、宿主语言权限生命周期差异、理由、证据边界/剩余缺口。C03预检不冒原子提交，C10核对完整请求组成，64KiB不冒完整容量。旧有效局部能力保留。 |
| 真实验收 | 隔离临时Git项目+临时安装+Herdr启动 fresh orbit omp；必要负例、有界推荐/native task/hub正例、独立OMP只读固定快照、原生Esc与正常退出；未改变rebind语义不重开其路径。本轮关键投影/恢复/安全/协议路径有对应真实证据；修复用新构建复验。受测源码摘要/安装/调用/成员/失败/检查/纠正/停止可追溯。 |
| 收口 | 相关已有测试先跑，少量真实风险回归、全仓测试/pack dry-run/skill校验/diff检查；适当独立核查通过，合同/索引/交接/债务同步；测试进程和所属后台退出后删除自建pane，保存证据后清理本轮临时安装/目录，固定Root/三OMP/MCP/Herdr保留。资源按角色/精确型号/回执原单位，未知费用/额度保持未知。 |

### 当前总 TODO

- [x] 实际启动 Goal；固定基线与 `/new` 核对，保留现有工作。
- [x] 本轮范围、依赖、所有权与必要验收冻结。
- [x] C02 实现、相关验证、实际请求/自主推进证据、独立核查。每请求context投影沿普通/amend/custom wake/compact/resume实测；v7没有Controller中途催办/代写而推进到终检/confirmed stop；30s hook、未自然触发的特定idle分支及完整容量边界保留。
- [x] C04 原生交接与具体失败恢复闭环、真实验证、独立核查。8906 v7推荐/先登记/实质实现/Main peer/Root核验/两个实际单位accepted/独立终检/confirmed stop；pK原件独立复核通过，空便捷字段与未派发记录如实保留。
- [x] C06 有界安全可行性诊断与合法执行闭环、越界验证、独立核查。5627正例v4与8906正例v6原生成员实际通过npm127；完整项目npm包/TMPDIR材料范围有效，失败调用实际修正，NVM与项目外写权限未扩大；整体C04收集/终检仍分别验收。
- [x] C08 单一结构来源落地、TS/Ruby结构与语义验证、独立核查。实际独立 OMP 检查在123f／b408构建走TS→Ruby并被运行时接受；结构与Unicode回归、Grok独立复核通过，仍非所有理论语义分支认证。
- [x] C05 当前SDK接口核实及可用接线，诚实记录必要阻断。SDK18.8 admitted忙态已接；活动成员Esc/活动正常退出及v7两个成员停后PID退出通过，团队原子准入/丢全部引用信号仍缺，未采用Fork或永久暂停。
- [x] C01—C10 当前五维处置与本轮采用范围全部有据。源码参照/实现/静态验证/真实运行/未测成熟度分开记录。
- [x] 必要真实矩阵通过；失败/人工干预/未跑保留。负例、v7完整正例、独立固定只读、Esc/活动正常退出分别有原件；不把v3/v5取消、v6无hub等改判。
- [x] 全仓检查与文档同步完成。最新operation修复后完整npm test/pack/skill/diff均exit0；合同局部说明、索引、交接和债务同步。
- [x] 自建测试资源清理完成，固定资源核对保留；交付条件已满足，实际Goal工具已complete。11个测试pane与所属进程/检查者/owner后台退出；支持临时卸载exit0，临时根、指针和独立SDK目录已删，17个固定PID/4pane及日常安装摘要不变。

### 定点核实过程（按发生顺序保留；最终状态以总 TODO 和当前验收为准）

- 本轮原生回执确认固定 K3=`kimi-code/k3-256k`、GLM=`zhipu-coding-plan/glm-5.3-flash`；Grok 本轮原生回执精确身份为 `cursor/grok-4.7-500k-fast`。固定进程没有重建。
- C04：旧正例原件 `call_44f1c28beab9424ea5fdb7bd` 把 read/edit/write/glob/grep 交给 `task.tools`，真实 SDK 报 Unknown eval tool(s)。18.8.0 task/eval-tools.ts 的挂载名称属于 eval kernel；Orbit 正在做窄调用前诊断及工具说明，阻断不记成派发。后续原生调用成功、错误调用、Controller干预及Root接管分别记，不互相替代。
- C05：本仓 reviewer node_modules 实际18.3.4（不是18.8.0），本轮已用支持安装路径建立隔离安装，pi-coding-agent实际18.8.0、pi-ai仍18.3.4；不能说整个依赖树已对齐。公开 beginDispose() 同步关闭的是单 session，并永久标为 disposing；不能未经决定替代保留会话上下文的最小暂停。dispose() 是共享可等待Promise但内部若干清理失败只告警；registry.release() 先detach/tombstone且吞dispose异常，返回true不证明清理。isParking=false不能区分成功或取消。当前未找到整个团队原子关闭接纳或丢失所有session引用后的可靠清理结果接口。Root继续核实实际 admitted-submission 状态对既有停止观察的影响；不把名单复读说成原子关闭。
- C06：静态元数据诊断可以指出NVM npm-cli不在member沙箱读集，不授予外部读取。隔离项目准备现有Node/npm副本到项目.runtime，完整祖先目录的只读沙箱材料探测能查询npm版本；第一次手写探测漏cwd祖先而失败，失败原件保留。这只是Controller环境准备，不计原生成员执行验证。必须在新构建实际派发中验证诊断/恢复和合法测试执行。
- C10：Root直接读固定Codex session/context_window.rs、session/turn.rs、session/tests.rs及guardian/request_budget.rs：active context、自动压缩范围、完整窗口、已组装输入及tools/text元数据分开核对。当前OMP18.8.0自身按pending messages与nonMessageTokens估计，但Orbit provider hook新增投影发生在另一层；本轮实际最终请求的组成/大小/已知与未知边界还要随C02实测，不将64KiB compressed-context或4Mi字符桥接上限当整体模型容量。无溢出原件，不预设资源硬预算或自动缩减验收输入。

- C02 当前适配核实：18.8.0 Cursor 的 pi-ai/providers/cursor.ts:5484 确实调用onPayload，但参数是已组装的runRequest/blob，不是messages/input。将已知JSON形状的provider append外推给它不成立。正在沿SDK sdk.ts:4113→ExtensionRunner.emitContext:1969 这个现有每请求消息转换接缝修正目标投影；不修改protobuf或宿主执行器。Root另定位appendToMessagesPayload在非user尾部替换末条工具结果的缺陷，主写者已修为保留原消息再追加，相关回归通过后再实跑。

- C06 当前实现／定点回归：Root直接读固定Codex tools/orchestrator.rs→sandboxing.rs及exec_policy.rs拒绝测试。复用既有member gate和内核沙箱，新增只读首执行程序定位、X_OK和两字节shebang判定；不可读npm脚本给项目.runtime实际副本方案，不扩大NVM读取。裸二进制不因缺数据读取许可一律拒绝，复杂shell/解释器参数/包脚本依赖仍unknown并由内核强制。scope既有合法工具、实际写范围／network拒绝及脚本修复／外部binary案例通过；尚不是真实原生派发验收。

- C08 当前补修：结构源仍为既有schema，Root独立核对了enum／required／additionalProperties派生与Unicode code-point长度；Grok进一步发现coverage的TS.trim与Ruby.strip在NBSP／全角空白上分歧。Root已统一Ruby覆盖文本首尾空白语义，两条共享样例保护空证据和重复要求；当前TS 7项及Ruby context回归均exit0，真实独立检查与补修独立复核仍待完成。

- 首次整仓测试未通过：native-gate transport fixture 把 inbox atomic writer 的 .tmp 当提交读取并删除，导致真实 rename ENOENT；业务未改。Root已使测试消费者只处理 .json，失败日志保留，当前重验。新真实正例123f8e83构建先出现candidate agent名称误填task.model导致错误接管，随后独立检查指出未覆盖项，Root自主声明工作单元并成功进入原生派发（尚待收口）；不把之前接管冒充委派。源码已补更具体agent/model参数诊断；相对首执行路径按实际bash cwd解析，派前未获cwd的相对命令明确unknown，相关scope回归通过。新改动将另安装受测构建，不改写旧构建证据。

- 独立核查：GLM直接核对固定Codex user_goal／retained_context持久屏障及tests和当前SDK context/steering链，修复暂停前缀、basis来源及wake重复后无现行阻断缺陷；30s hook异常／超时、完整投影没有全请求容量保证留边界。Grok复核coverage两类Unicode空白、当前C06首跳与内核边界无剩余分歧。K3复核C04/C05/C06，Root修正实际cwd误判及新agent/model诊断后再次通过；retained owner方法缺失是当前SDK不可触发理论兼容分支，按AGENTS不扩大修复。当前scope及最新native-gate均exit0；真实正例原生核查成员存在多次权限/命令拒绝、Jev真实OpenTimeout、没有有效推荐，尚不能记必要正例通过。

- 全仓首次失败原件保留，消费者修复后完整 `npm test` exit0；pack dry-run、skill validator及diff检查通过。b408新正例成员实际实现importer，SDK Missing context诊断促成下一次正确派发，但错把model_requirements放spec外被静默忽略，推荐仍facts_only；成员npm因只获入口文件读集而重复EPERM，不能将Root全测试通过记为成员环境恢复。Root追加声明层级拒绝及已知node→npm包根范围诊断，交K3独立复核并用更新构建另测。首次scope增补在含单引号的测试路径上按保守规则unknown，修正测试为真实成员cwd下相对入口，不放宽shell解析。
- C02真实生命周期：b408原要求→实际amend（README空CSV/退出码）→活动原生成员→native Esc确认暂停；明确“只解释、不执行”后文件hash不变，原生/compact生成compaction记录；保留同一native session正常退出后重新打开，继续验证恢复请求与正常退出路径。该运行包含Controller修订/中断，不能作为自主推进证明。首轮正例在没有Controller催办/代写下自行处理独立检查反馈并确认停止，但推荐／实现委派／成员npm等必要正例资格分别保留失败边界。

### C01—C10 当前五维处置

固定源码统一为 `36ae1561b9324c93d5638b45eb19fe2cc070a581`；以下位置均是主要执行者直接读取的源码及相关测试依据，不宣称运行了Codex测试或继承其生产成熟度。源码参照、Orbit实现、确定性验证与真实运行分别取证。当前真实细节沿[本轮验收](../reference/codex-lessons-acceptance-20261010.md)。

| 项 | 当前具体问题／影响 | Codex机制、位置与前提 | Orbit适配差异 | 当前处置及理由 | 证据边界／剩余缺口 |
| --- | --- | --- | --- | --- | --- |
| C01 | 长日志中段丢失仍可能影响裁决；原前缀裁剪已实际补首尾 | unified_exec/head_tail_buffer.rs 按bytes增量保留两端，前提是完整流进入该缓冲 | JS回执UTF-16单位、Ruby字符预算和64KiB投影；非流式Rust缓冲 | 复用已有两处局部实现；暂无相关新缺陷，不为借鉴名义重写 | 旧真实JS4000→Ruby500和51465bytes有效；本轮相关全仓回归保持。不能恢复SDK先丢内容或保证中部无重要事实 |
| C02 | system-only提示不覆盖custom wake；Cursor blob不支持旧JSON追加；非user尾部旧追加会丢工具结果 | context/user_goal.rs、session/retained_context.rs、ext/goal/src/runtime.rs、user_goal/retained_context tests：持久原目标和空闲生命周期接线，以宿主真实turn状态为前提 | OMP extension `context` 在每次messages转换前读取现有task原件；SDK仍负责调用/压缩/队列，不建Goal库 | 局部采用：原文/amend/basis/continuation全读、缺件明确；普通与程序唤醒共用接缝。既有reviewed-version一次续跑保留，区分活句柄等待与无价值输出 | K3实现、GLM独立核查、native-gate/runtime回归。真实自主正例已到终检/stop；amend/Esc/讨论/compact/resume另测。30s hook异常与完整请求容量仍有边界，本地append事实不等于服务端回执或模型遵守 |
| C03 | 插件发前所有权/版本核对与宿主接收存在竞态 | session/turn_input.rs steer_input 在active-turn锁内核对expected_turn_id，v2/turn.rs协议携带目标 | 当前SDK generation guard限制排队/失效，但公开sendCustomMessage无expected-turn原子提交参数；finding跨回合持续有效 | 暂缓额外状态机，复用原生身份及输入/产物版本。只读预检不冒原子提交；未发现本轮新误归属incident | 本轮SDK实际入口与固定源码直接核实；v7还显示declare持久化与后续评估是分步，dependencies_unmet仍留declare记录，不能当原子提交。无过期steer/interrupt incident，不为此新增状态机；该误作用或上游原子接口出现再评估，完整容量未因此保证 |
| C04 | 已发生task.tools误用、agent名称误填model、缺context、spec外选型要求被忽略及finish操作嵌套造成未收集，导致失败或退化 | agent/child_config.rs、control/spawn_guard.rs/completion.rs及control_tests：宿主派生cwd/model/策略，创建失败负责清理，结果绑定父/成员 | 异构OMP候选与生成agent名；native task工具形状、ticket和hub生命周期有现成底座 | 复用底座并局部采用具体调用诊断：native tools误挂载/agent-model误用预先拒绝；错误spec/operation层级在声明前明确修复，不自动改参数或支持未登记eval | 本轮预注册/真实member首调用/结果Root集成已有实证；b408实质编码成员仍facts_only且npm失败，不算推荐/环境闭环。8906正例v6实际推荐/派发已进入成员测试，Root收集仍待验收；Root接管与委派分别记录 |
| C05 | 旧晚到roster防误确认有效；pre-stream admitted工作会漏于isStreaming；丢session无法证明结束 | agent/control/runtime.rs admit_start/request_shutdown 与membership清理，前提是宿主掌握完整成员生命周期 | SDK18.8.0单session beginDispose同步但永久终止；dispose Promise内部可吞清理错误，registry release先detach，isParking非成功证明 | 保留晚到名单补丁，接入实际hasAdmittedSubmission忙态；保留retained dispose/owner jobs/工具收尾。普通暂停不改为永久dispose | 本轮活动member Esc confirmed，旧session正常退出实际PID结束；整体原子关闭接纳和丢全部引用的可靠信号不可得，仍stop_unconfirmed。新增宿主接口可改善；Fork/永久终结暂停需用户决定，当前不采用 |
| C06 | 合法npm命令虽获字面许可仍因NVM或未声明npm包依赖失败；相对命令按错误cwd判断会误阻断 | tools/orchestrator.rs→sandboxing.rs、exec_policy.rs拒绝测试：集中许可/执行上下文/有依据失败重试，前提是宿主解析及策略可得 | JS元数据首跳与既有Seatbelt；不能搬审批升级语义或自动放NVM。单元allowed_paths读写共用，非只读声明 | 局部采用只读X_OK/shebang/实际cwd及已知node→npm包根诊断；项目内当前runtime真副本、完整材料/命令由Root声明。复杂shell/未知依赖留内核，不执行任务当预检 | 合法binary/script/cwd与越界/network回归通过；b408实际member遇npm包读集和/tmp测试写入失败，重复失败原件保留，Root绕行不算解决。新正例需使用完整项目runtime与项目内TMPDIR/测试路径，不扩外部权限 |
| C07 | 关键日志消费者需知道截至停止切点哪些append真实完成 | rollout/recorder.rs AddItems与Persist/Flush/Shutdown分离；后者oneshot I/O回执，flush等先前处理 | 现有JS进程内writer queue及Ruby消费者，没有Rustrollout完整架构 | 复用已有停止后cutoff确认；先abort/reap再观察append，不全日志同步化 | 本轮实际confirmed-stop含written seq/gap范围，全仓回归有效。非fsync、断电恢复、全历史完整或完整账单 |
| C08 | TS/Ruby重复字段/枚举/额外键规则造成维护漂移；发现codepoint和Unicode空白实际分歧 | app-server-protocol/export.rs/precomputed_exports.rs及生成测试：协议定义派生类型/schema，前提是该协议导出链 | 现有检查schema是权威结构，TS/Ruby保留运行时业务校验；不移植Rust、不泛化所有SDK生成 | 局部采用schema运行时派生allowed/required/enums/closed/coverage界限；共享fixtures辅证。统一1000codepoint长度、coverage首尾Unicode空白 | GLM实现/Grok独立复核；两语言结构修改/Unicode/身份等回归与真实独立检查通过。类型/结构不证明版本、身份、覆盖事实，语义门保留 |
| C09 | provider诊断缺字段已补，但实际恢复由其他控制承担 | protocol/error.rs及现有错误测试传递结构错误/RetryAfter，前提是上游提供 | SDK只公开errorStatus/errorId，缺retry-after不猜；账户排除沿既有runtime | 复用已完成诊断增量；没有相关新故障要求重建taxonomy | 本轮provider/全仓回归；真实Jev OpenTimeout如实记失败，不能冒称完整恢复控制器或新账户故障已测 |
| C10 | 新全目标投影增加请求内容，但程序64KiB不是完整窗口 | session/context_window.rs/turn.rs/tests、guardian/request_budget.rs：窗口、组装输入与工具/text元数据分别处理；需可信model/route信息 | OMP估计pending messages与nonMessageTokens，Orbit context注入在另一阶段；system/tools/MCP/history/原文/读取/输出预留未统一实测 | 暂不引入硬预算/通用平台；记录实际goal bytes/hash和已知请求组成，既有限额保持 | 当前无完整请求溢出原件；64KiB程序投影、4Mi字符桥接均非完整模型容量。实际近限/溢出或可信完整请求接缝出现后再定点评估，不减少验收输入换通过 |


最新有效验证：新增测试源码相对开工dirty基线316行，另7条共享JSON样例207行数据；超出300行建议是实际目标投影、错层参数、完整npm包/TMPDIR/CLI读集、Unicode/停止等回归所需，已有测试未覆盖这些真实风险。按用户明确必要验证授权，无新测试框架/覆盖率目标。8906 operation修复后完整npm test、pack、skill、diff均exit0；程序/schema与受测安装一致，支持安装的SDK package/lock变换及后来仅合同说明补清明列。此前a201/5627对应测试保留原构建事实，不混标。

最新实际事故：5627正例v4确有版本绑定K3推荐、原生实现成员、成员npm127与hub回报、Root独立复测；但Root把operation嵌在work_unit中，finish/read实际走缺省declare，原单元仍bound且误建空单元。终检/confirmed stop不能替代该失败。Root已用共有纯函数在host/native两入口的声明前拒绝并给出正确顶层调用，保留合法缺省declare；K3窄独立复核和native-gate通过，8906新安装正例v5进行中，无Controller后续催办。四次检查结构失败保留，不为过关降低C08规则。最新全仓测试在运行，固定进程未改。

8906正例v5因K3 Root连续write缺content而失败，Controller nativeEsc取消并确认暂停，OMP/MCP退出后关闭pane；未改业务或工具参数伪造成功。同构建/冻结需求的fresh GLM正例v6在运行。operation补修后的完整npm test exit0。新增测试源码316行另有7条共享JSON样例（207行数据），超出建议由必交付且实际发生的回归风险支持，按用户必要验证授权，不另扩测试体系。

8906正例v6：真实推荐K3预注册/实现，成员修正write缺content与命令不匹配后npm127通过，Root独立复测/finish accepted/终检/confirmed stop通过且进程退出。但只有yield返回没有hub消息，Root自述不能替代实际证据，完整矩阵仍未通过。fresh正例v7初始需求明确保留原hub报告约束并区分yield，标准不降低，不改产品制造事件。

8906正例v7实际恢复：K3首单元实现importer，但Root遗漏CLI读路径，成员npm122之后CLI失败；all peer写被拒，改Main有Delivered成功回执。Root收到限制后自主新增含CLI材料的复验单元，Deepseek原生成员npm127通过并经Main成功报告；Root修正finish错误unit id，将两个实际执行单元accepted。重复declare留下两个未派发记录（不计成员/工作），并非原子声明+评估；检查/停止仍待收口。此主线没有Controller中途催办或代写。

最终独立原件复核通过（固定pK，仅本轮v7范围，不替代其他矩阵）；实现、采用验证、全部五维处置已闭合。Root npm实际一次加后续CLI抽查，不能说第二次重跑；便捷member关联空字段/重复未派发记录保留当前局部限制，权威单位绑定和真实结果归属有据。所有测试进程/owner后台与11个新pane已退出关闭，支持临时卸载exit0、17个固定PID/4pane及日常安装摘要不变；最后临时根删除/Goal工具状态收口正在执行。

实际收尾：必要证据完整保存在docs/reference/evidence/codex-lessons-20261010，267个结构化归档文件过滤审计无thinking块；本轮自建安装/所有目录已清，17个固定身份及4pane保留，日常5993d7fb…安装未变。总TODO全勾表示交付条件达成，此收尾记录写入时Goal仍active；后续已收到下方实际complete回执；不把该文字当工具启动或完成。

最终实际工具回执（2026-10-10T06:10:16Z）：Goal `01a123d6-9986-7d12-b447-f6ebcffb40e9` complete，tokensUsed1538326、timeUsedSeconds9977（2小时46分17秒），无硬token预算；该Goal计数不是供应商回执token/现金账单。工具原件goal-final-result.json。以上进行中叙述为按序历史，当前全部必要交付与资源收尾完成。

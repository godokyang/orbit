# Orbit 第一用户体验调整方案

本文基于 [Orbit 第一用户长期使用复盘](orbit-first-user-experience.md) 提炼调整方案。它不是新的问题清单，也不声明这些调整已经实现；它把核心用户在真实长期使用中暴露的问题，转成可排序、可验收、可拆分实现的 Orbit 产品和运行时改进路线。

本文在文档链条中的位置：

- [Orbit 第一用户长期使用复盘](orbit-first-user-experience.md)：源复盘，记录体验、收益和问题域。
- 本文（调整方案）：定义 P0/P1/P2 优先级、覆盖矩阵、分阶段路线和 slice 切分。
- [Orbit 第一用户体验调整实施依据](orbit-first-user-adjustment-development-contract.md)：把每个 slice 落成字段草案、CLI 行为、兼容策略、验收和测试矩阵。

本文与实施依据冲突时，以本文的优先级为准，以实施依据的字段和测试为实现细化依据。

## 目标

本方案要解决的问题是：Orbit 已经证明能挡住假完成、接住长任务和支撑多 agent 协作，但当前体验仍容易变成“流程闭合、目标未闭合”。调整目标是让 Orbit 更清楚地表达真实目标、当前状态、证据可信度、下一步动作和流程成本。

调整后的 Orbit 应具备这些性质：

- 用户能一眼知道当前任务是完成、阻塞、等待 review/test，还是只是某个 slice 通过。
- agent 不能只靠聊天、pane 状态或 checklist 把任务包装成完成。
- review/test gate 的 PASS 语义稳定，能区分机械检查、质量判断、真实路径验证和已接受风险。
- evidence 能长期证明关键结论，但不会无限膨胀成难以维护的副仓库。
- 多 agent 协作的身份、权限、pane lease、旧输出仲裁和 handoff 有机器可读边界。
- 轻量任务不被强行拖进重流程，重任务也不能绕过关键 gate。

## 非目标

- 本文不实现 CLI、schema、模板或 runtime 代码。
- 本文不把当前复盘中的项目特定案例固化成 Orbit 默认规则。
- 本文不要求所有项目使用同一强度流程；轻重流程需要按项目 profile 和任务风险分层。
- 本文不替代 `references/runtime/` 中的运行时规则，后续实现时应把稳定方案再迁入 runtime 文档、模板或 CLI 校验。

## 调整原则

1. **目标优先于流程**：task contract、review、test、handoff 都必须回到用户真实目标和 quality outcome，不能只证明流程动作发生过。
2. **单一状态视图优先于多份结论**：用户、lead、reviewer、tester 和 handoff receiver 应看到同一个 parent goal 状态，而不是各自解释 slice、pane 和 manifest。
3. **机器可读优先于自然语言承诺**：聊天里的 DONE/PASS 只能是通知，权威 gate 必须来自结构化 evidence 和身份校验。
4. **证据保真与成本平衡**：长期保留摘要、hash、关键指标和可复核路径；短期 artifacts 明确生命周期，不靠无限堆文件换可信度。
5. **风险分层而不是默认加码**：P0 处理会造成假完成、误删、错放行的核心风险；P1 处理规模化运行成本；P2 处理组织采用和长期治理。

## P0 调整：先防止错误完成和错误放行

### P0.1 建立 Parent Goal 权威状态视图

来源问题：长任务状态和 parent goal 分裂、用户下一步不明确、slice pass 被误读成 goal complete。

调整内容：

- 在 task/handoff/audit 中增加或规范 `parent_goal_status` 摘要，至少包含 parent objective、done criteria、active slice、remaining blockers、required gates、user_next_action。
- `orbit wait-gate`、`validate`、`audit` 和 handoff 输出统一展示 parent goal 状态，避免只输出局部 gate ready。
- child slice evidence 必须回指 parent objective 和未覆盖范围；child pass 不能自动提升为 parent pass。
- final audit 必须逐条证明 parent done criteria，而不是只聚合 child verdict。

验收信号：

- 用户无需读取多个 `.orbit` 文件，就能从最终输出判断“整体完成了吗、卡在哪里、下一步是谁做”。
- 对有 child slices 的任务，CLI/audit 能明确区分 `slice_ready`、`parent_in_progress`、`parent_done_ready`（完整状态枚举以实施依据文档的 `parent_goal_status.state` 为准）。
- handoff receiver 能通过 parent status 恢复工作，而不是从编号或聊天记忆推断目标。

### P0.2 强化 Quality Outcome Contract 和 Invalid Completion Guard

来源问题：质量门语义失真、task contract 错框、review 机械化。

调整内容：

- 改善类、UX、可靠性、架构、文档维护和测试改进任务必须有完整 quality outcome。
- task contract 增加 `invalid_completion_guards` 或强化现有 `invalid_completions`，列出明确反例。
- reviewer report 必须回答 outcome 是否达成、哪些反例被排除、哪些未验证风险可接受。
- `review_strategy` 默认从 Outcome、Behavior、Structure、Evidence、Residual risk 五层审查，而不是从 checklist 字段开始。

验收信号：

- reviewer 不能只用“文档存在”“测试通过”“grep 命中”关闭改善类任务。
- 质量门报告能说明为什么用户问题已经改善，或明确指出只是动作完成但 outcome 未达成。
- `validate` 能拒绝空泛或只有动作描述的 quality outcome。

### P0.3 固化 Verdict 语义和 Evidence Level

来源问题：PASS 语义混乱、honest blocker/partial/docs pass 混在一起、transport 与 evidence 边界不硬。

调整内容：

- 将 verdict 拆成 `status` 与 `evidence_level`：如 `mechanical_check`、`outcome_quality`、`implementation_readiness`、`real_path_test`、`release_readiness`；evidence level 按 gate 类型分级比较，完整枚举和排序以实施依据文档为准。
- review/test PASS 必须声明覆盖层级、confirmed/assumed/missing、rule_application 和 residual risk。
- pane 消息里的 DONE/PASS 必须标注是否已提交结构化 evidence；未提交时只能显示为 transport notification。
- `wait-gate` 只接受满足 task 最低 evidence level 的结构化 verdict。

验收信号：

- 用户看到 PASS 时能知道它是文档质量通过、实现就绪通过、真实路径通过，还是只表示当前 blocker 被诚实记录。
- Herdr 或其他 transport 的自然语言结论不会被误当成 gate ready。
- 旧 verdict 到达时，Orbit 能按 task/run/revision 判断是否 stale。

### P0.4 角色身份、规范加载和越权写入可审计

来源问题：role 规范依赖自律、identity_valid 被误读为权限隔离、review/test agent 可能污染 worktree。

调整内容：

- 每次结构化 verdict 记录 role doc hash、rules context hash、instance id、workspace hash 和 task hash。
- reviewer/tester 默认记录 `write_policy` 和实际 changed files；如果 gate role 修改了 scope 内文件，必须进入 finding 或 waiver。
- `orbit whoami`、`rules print-context` 和 evidence submit 输出应让用户看到本轮实际加载了哪些规则。
- 对关键任务增加只读/临时 worktree profile，至少支持检测 gate role 的非预期写入。

验收信号：

- gate record 能证明“谁以什么角色、读了哪些规则、基于哪个 task 版本提交 verdict”。
- reviewer/tester 的文件改动不会静默混入 lead/coder 的实现 diff。
- 用户不需要靠口头提醒来维持角色边界。

### P0.5 加固破坏性操作和产物边界

来源问题：混合 worktree、运行产物误提交、删除/回退/清理缺协议。

调整内容：

- 新增 destructive action protocol：dry-run、target list、tracked/untracked、owner、recoverability、evidence impact、user confirmation。
- task contract 明确 `scope.include`、`scope.exclude`、generated/build/runtime artifact policy。
- `validate` 或专门命令检查 changed files 是否越过 task scope。
- 清理 artifacts 时保留 hash、目录清单、删除理由和可恢复性说明。

验收信号：

- 删除、移动、覆盖、清理、杀进程、回退状态前都有可复核计划。
- 不该提交的 `.orbit` runtime、构建产物或测试临时文件不会因为工作树混杂被误带入。
- evidence 引用的关键 artifacts 被删除时，仍有 durable summary 或 hash 证明原结论。

## P1 调整：降低长期运行成本和状态漂移

### P1.1 Evidence 生命周期和压缩策略

来源问题：`.orbit` 膨胀、report/manifest/state 漂移、原始产物易删但摘要不足。

调整内容：

- 定义 evidence retention profile：raw artifact、derived summary、hash/index、long-term report、transient log。
- `compact-evidence` 成为长任务收口默认步骤，保留 task/evidence/handoff hash、latest verdict、关键 artifacts、known gaps。
- `docs check` 或 audit 检测 report、manifest、loop-state、handoff 之间的 latest record 漂移。
- 对大型 `.orbit` 增加归档、索引、迁出和过期策略。

验收信号：

- 新 agent 可以通过 compact summary 快速判断权威结论和剩余风险。
- 删除 transient artifacts 后，关键结论仍可被 hash、目录清单和摘要复核。
- `.orbit` 规模增长有可观测指标和清理建议。

### P1.2 Runtime Reconcile 和环境指纹

来源问题：Orbit 记录和真实运行态分裂、环境/外部服务/构建产物不可复现。

调整内容：

- task evidence 支持 runtime binding：server、browser、external operation、product runtime task、build hash、model/service family。
- test report 记录 redacted config map、port、owner、duration、cleanup、service smoke 和 model identity。
- audit 提供 reconcile summary，指出 Orbit task、产品运行态、browser/session、artifact 路径是否一致。
- blocker 分类稳定区分 code failure、environment failure、service failure、model drift 和 expected fail-closed。

验收信号：

- 用户问“现在卡在哪里”时，不需要人工跨多个状态源推理。
- 同一 real run 的结论能复现到足够程度，且不泄露密钥。
- report 引用已删产物、旧构建产物或错误 server 的情况能被 audit 发现。

### P1.3 多 Agent Lease、队列和旧输出仲裁

来源问题：reviewer/tester 慢、pane 生命周期脆弱、旧 verdict 到达、gate ownership 不清。

调整内容：

- 引入 gate lease：owner instance、task hash、revision、expires_at、renewal、replacement policy。
- lead dispatch 后记录 gate queue 状态，区分 waiting、claimed、running、submitted、stale、superseded。
- old verdict 仲裁以 task hash、evidence manifest revision、source message id 和 role identity 为准。
- handoff 明确接收方必读证据、可忽略旧产物、仍有效用户约束和失效状态。

验收信号：

- 多个 reviewer/tester 输出冲突时，Orbit 能给出当前权威 verdict 和被取代原因。
- 用户能看到应该等谁、是否可以替换 gate owner、旧输出是否还有效。
- handoff receiver 不会误用过期 pane 消息或旧 task 状态。

### P1.4 文档生命周期和长期记忆提升路径

来源问题：旧设计文档仍在 open、聊天决定未记录、摘要和原 evidence 不一致。

调整内容：

- 用 stable doc id 管理 active baseline、open design、implemented archive、historical reference 和 lesson。
- 用户纠偏、手工确认、暂停、取消、继续等事件进入 structured decision record。
- 长期 lesson 进入 runtime 规则前必须经过抽象边界审查，避免项目特例污染默认协议。
- docs audit 检查已关闭文档是否归档、active design 是否仍有效、引用路径是否漂移。

验收信号：

- 新 agent 能判断哪个文档是当前基线，哪个只是历史参考。
- 用户的重要决定不会只存在聊天里。
- 复盘中的经验能被提升为规则，但不会未经筛选直接变成默认强制项。

### P1.5 用户下一步动作标准化

来源问题：用户不知道该等、重试、确认、刷新、修环境还是继续实现。

调整内容：

- 所有收口输出统一包含 `current_state`、`default_next_action`、`user_options`、`waiting_on`、`blocked_by`、`do_not_do`。
- 对 `partial`、`blocked`、`honest blocker`、`ready`、`done_ready` 建立用户可理解的显示文案。
- 用户挫败或纠偏事件进入 evidence/decision record，作为流程调优信号。

验收信号：

- 用户无需理解所有 gate 名词，也能知道下一步该做什么。
- agent 不会在每个小步骤后停下来要求用户重新决策，除非确实需要外部输入。
- 用户明确要求轻量处理时，Orbit 能记录降级原因并避免过度流程化。

## P2 调整：组织采用、合规和 Orbit 自身治理

### P2.1 项目 Profile 和流程轻重档位

来源问题：单个重项目经验可能过度外推，小项目被默认税拖慢。

调整内容：

- 定义 project profile：CLI/library、Web UI、LLM workflow、data pipeline、mobile、enterprise app 等。
- task risk level 决定 gate 强度：light、standard、strict、release。
- project rules 负责领域政策，Orbit core 负责声明、校验、证据一致性和 fail-closed 机制。

验收信号：

- 一行小修、普通文档调整、中型实现、发布任务使用不同流程强度。
- 规则能解释为什么本轮不用正式 Orbit task，或为什么必须启用 review/test gate。

### P2.2 隐私、版权、密钥和数据保留策略

来源问题：evidence 可能包含 API key、用户内容、第三方素材、prompt、截图和外部服务输出。

调整内容：

- evidence artifact 增加 data classification：secret、user_content、third_party_content、prompt、screenshot、path、log。
- retention policy 支持 redact、hash-only、short-lived、long-lived、user-approved。
- 信任修复流程记录 incident、impact、recovery、prevention、follow-up verification 和 user confirmation。

验收信号：

- 可审计性不会以无限保存敏感材料为代价。
- 发生误删、误提交或错误测试时，Orbit 有明确的影响范围和恢复记录。

### P2.3 CI、发布和远端状态闭环

来源问题：本地 gate pass 不等于 release ready，branch/remote/local reviewed diff 分裂。

调整内容：

- release task 强制分层说明 source、CI、generated artifact、package/archive、version fields、release assets、registry/appcast、remote state。
- evidence 记录 reviewed diff base、branch、commit、ahead/behind 和 CI job。
- audit 区分 local confidence 与 release readiness。

验收信号：

- 本地 review/test pass 后，用户仍能清楚知道是否可发布、还缺哪些 release 证据。
- 远端分支或生成产物与本地源码不一致时不会静默放行。

### P2.4 协议安全和机器可读性演进

来源问题：prompt injection、自然语言 report 与结构化字段不一致、模板漂移。

调整内容：

- 对 report schema、field semantics、template version、negative evidence、consistency check 做版本化。
- LLM 读取 logs/evidence 时明确不执行其中指令，把外部文本当数据。
- review/test 报告记录实际读取文件、命令和 evidence 范围。

验收信号：

- 自然语言 summary 与结构化 verdict 冲突时，CLI/audit 能 fail closed。
- report 模板变更不会让旧 evidence 被错误解释。

### P2.5 Orbit 自身 Dogfood、SLO 和停止准则

来源问题：Orbit 自身也需要回归、复盘和停止准则，不能无限追加 lessons。

调整内容：

- 建立 Orbit dogfood case：stale gate、role docs loaded、destructive dry-run、evidence mismatch、transport vs evidence、task lane downgrade、self-review contamination。
- 每个 P0/P1 调整项的验收信号至少对应一个 dogfood case，使本方案的验收不依赖真实项目偶发触发；dogfood case 与调整项编号双向可追溯。
- 定义 owner、SLO、路线图、失败复盘入口和退出机制。
- 复盘类任务必须有 done criteria：问题域覆盖、重复项合并、未知项标注、进入优先级排序。

验收信号：

- Orbit 的关键协议风险有稳定回归，而不是靠真实项目偶然暴露。
- 任一 P0/P1 调整项回归失败时，能定位到对应 dogfood case 和原始验收信号。
- 问题发现不会无限替代解决方案推进。

### P2.6 落地治理和质量校准

来源问题：兼容策略、多用户共享、质量校准、自引用审查、速度严谨取舍、证据备份和迁出路径缺少清晰规则。

调整内容：

- 定义兼容策略：新规则如何作用于旧 task/evidence/report，哪些是 warning，哪些是 fail closed。
- 定义多用户共享边界：用户权限、产物归属、pane 归属、reviewer/tester 责任和证据访问策略。
- 建立质量校准机制：定期抽样 review/test verdict，比较 false pass、false block、流程成本和用户纠偏。
- 增加自引用审查：Orbit 修改自身协议、模板、gate 或 evidence 语义时，必须标注自审污染风险和独立验证路径。
- 明确速度/严谨取舍：按 task risk level 解释为什么使用 light、standard、strict 或 release 档位。
- 提供证据备份、迁出和恢复策略，避免 `.orbit` 历史既不可删也不可迁。

验收信号：

- 新旧 schema、历史 evidence 和项目升级路径有明确兼容等级。
- 多用户 workspace 中能说明文件、pane、artifact 和 evidence 的 owner。
- Orbit 自身改动不会只靠 Orbit 自己的同一套 gate 自证可信。
- 用户可以按风险接受轻量流程，也可以要求严格流程，且决策被记录。

## 分阶段落地建议

### 第一阶段：收口语义和用户状态

优先交付：

- Parent goal 状态视图（P0.1）。
- Quality outcome / invalid completion guard 强化（P0.2）。
- Evidence level 和 verdict 语义（P0.3）。
- 破坏性操作和 scope 护栏（P0.5）。
- 用户下一步动作标准化（P1.5）。

选择理由：这些直接影响“是否错误宣布完成、错误放行或误删产物”，是核心用户信任问题。其中 P0.5 与语义类改动同期交付，避免状态视图清晰之后仍缺破坏性操作护栏。

### 第二阶段：证据生命周期和多 agent 可靠性

优先交付：

- Evidence retention profile 和 compact summary 默认化（P1.1）。
- Runtime reconcile 和环境指纹（P1.2）。
- Gate lease、旧 verdict 仲裁和 handoff 接收条件（P1.3）。
- 文档生命周期和长期记忆提升路径（P1.4）。
- 角色规范加载 hash 和越权写入检测（P0.4）。

选择理由：这些降低长期任务、多 pane、多天运行时的状态漂移和维护成本。P0.4 虽属 P0 优先级，但依赖第一阶段的 verdict/evidence 结构，故与多 agent 可靠性一并交付。

### 第三阶段：组织采用和发布治理

优先交付：

- Project profile 和 task risk level（P2.1）。
- 数据保留和信任修复流程（P2.2）。
- CI/release readiness 分层（P2.3）。
- 协议安全和机器可读性演进（P2.4）。
- Orbit 自身 dogfood suite 和路线图治理（P2.5）。
- 落地治理和质量校准（P2.6）。

选择理由：这些决定 Orbit 能否从单个重项目经验推广到更多项目，而不是变成固定流程税。其中 P2.4 的版本化约定建议在第一阶段改 schema 时即确立，完整 slice 再于本阶段收口，避免模板漂移返工。

## 覆盖矩阵

下表以源复盘的问题域为主线，并把 `Orbit 自身 dogfood`、`落地治理` 这类治理项单独展开，方便后续开发追踪。它不是在改写源复盘的分类数量。

| 复盘问题域 | 主要调整项 |
| --- | --- |
| 质量门语义 | P0.2、P0.3 |
| 长任务状态 | P0.1 |
| 角色与权限 | P0.4、P1.3 |
| Evidence 生命周期 | P1.1、P0.5 |
| 协作 transport | P0.3、P1.3 |
| Git 和破坏性操作 | P0.5 |
| 可复现与安全 | P1.2、P2.2 |
| 用户体验 | P1.5、P0.1 |
| 工程治理 | P2.1、P2.3、P2.5 |
| 多 agent 执行细节 | P1.3 |
| 可执行性和记忆边界 | P1.4 |
| 系统运行治理 | P1.2、P1.3 |
| 协议安全和机器可读性 | P2.4 |
| 长期信任和合规 | P2.2 |
| 多项目适配和组织采用 | P2.1、P2.5 |
| Orbit 自身 dogfood | P2.5 |
| 落地治理 | P2.1、P2.5、P2.6 |

## 后续实现任务切分

建议不要把本文一次性实现成一个大任务。下面的 slice 覆盖全部 P0–P2 调整项，每个 slice 标注它收口的调整项，便于反向追溯：

1. `parent-goal-status-and-user-next-action`（P0.1、P1.5）：统一 parent goal 状态输出、用户下一步动作和 handoff 摘要。
2. `quality-outcome-guardrails`（P0.2）：强化改善类 task contract、review report 和 validate。
3. `verdict-evidence-level-schema`（P0.3）：明确 PASS 语义、最低 evidence level 和 transport 边界。
4. `role-identity-and-write-policy`（P0.4）：记录 role/rules/instance/workspace/task hash，检测 gate role 越权写入。
5. `destructive-action-and-scope-guard`（P0.5）：加入 dry-run、scope check 和 artifact policy。
6. `evidence-retention-and-compact-defaults`（P1.1）：定义 retention profile、drift check 和 compact summary。
7. `runtime-reconcile-and-env-fingerprint`（P1.2）：接入 server/browser/build/service/model 指纹和 reconcile summary。
8. `gate-lease-and-stale-verdict`（P1.3）：处理多 agent gate ownership、旧输出仲裁和 handoff 接收。
9. `doc-lifecycle-and-decision-record`（P1.4）：管理文档生命周期、用户决定记录和 lesson 提升路径。
10. `project-profile-risk-level`（P2.1）：让 Orbit 支持 light/standard/strict/release 档位。
11. `data-classification-and-retention`（P2.2）：增加数据分类、保留策略和信任修复流程。
12. `ci-release-readiness`（P2.3）：分层 CI、release 证据和远端状态。
13. `protocol-schema-versioning`（P2.4）：版本化 report schema、字段语义、负证据和一致性检查。
14. `orbit-dogfood-and-governance`（P2.5）：建立 dogfood case、SLO、路线图和停止准则。
15. `landing-governance-and-calibration`（P2.6）：定义兼容、多用户、质量校准、自引用审查、速度严谨取舍和迁出恢复策略。

每个 slice 都应有自己的 task contract、非目标、acceptance、review/test 证据和 residual risk；本文只作为设计输入和优先级依据。

### Slice 依赖和建议顺序

部分 slice 互为前置，实现时应按依赖而非编号推进：

- `verdict-evidence-level-schema`（P0.3）是 evidence 结构的基础，`quality-outcome-guardrails`、`role-identity-and-write-policy`、`gate-lease-and-stale-verdict`、`evidence-retention-and-compact-defaults`、`runtime-reconcile-and-env-fingerprint` 都依赖它先稳定字段语义。
- `protocol-schema-versioning`（P2.4）虽列在 P2，但一旦多个 slice 开始改 schema，就应尽早确立版本化和一致性检查的约定（即使完整 slice 在第三阶段交付），避免后期模板漂移返工。
- `parent-goal-status-and-user-next-action`（P0.1、P1.5）可与 verdict 语义并行起步，但其 `parent_done_ready` 判定依赖 verdict/evidence level 最终确定。
- `orbit-dogfood-and-governance`（P2.5）依赖前述大多数 slice 落地后才能形成稳定回归，应作为收口而非起步。
- `landing-governance-and-calibration`（P2.6）应在 P2 开始前先确定最低兼容策略，完整质量校准和迁出恢复机制在第三阶段收口。

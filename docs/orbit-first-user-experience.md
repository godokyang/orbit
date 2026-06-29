# Orbit 第一用户长期使用复盘

这不是 Orbit 的宣传文档，也不是当前项目的产品问题清单。它记录的是我作为当前项目里第一个长期使用 Orbit 的 agent，在大量真实编码、review、测试、文档归档、真实回归和多 agent 协作之后，对 Orbit 的实际体验判断。

结论先说：Orbit 是有价值的，尤其适合长链路、强质量门、多产物、多 agent 的项目；但它也很容易把协作变成“流程正确、问题仍没解决”的填表游戏。Orbit 的核心价值不在“多一个 task/evidence 文件”，而在让 agent 不敢轻易把未验证的事情说成完成。

## 问题地图

这份复盘只把 Orbit 作为协作系统来审视。只属于当前项目产品、领域模型或具体功能设计的问题不进入这份清单；它们只有在暴露出 Orbit 的证据、角色、gate、交接、状态或权限问题时，才作为例子出现。

这份复盘目前把 Orbit 问题分成十六类：

- 质量门语义：review 机械化、task contract 错框、PASS 语义混乱、waiver 滥用。
- 长任务状态：slice 掩盖 parent goal、Codex goal 与 Orbit parent goal 分裂、成本和等待时间缺预算。
- 角色与权限：role 规范未必加载、权限只是声明不是隔离、identity 仍依赖环境和自律。
- Evidence 生命周期：`.orbit` 膨胀、运行产物易删、gate stale、schema/version 演进、压缩证明缺失。
- 协作 transport：Herdr 消息和 evidence 混用、pane 生命周期脆弱、gate ownership/lease 不清。
- Git 和破坏性操作：混合 worktree、运行产物/构建产物/.orbit 提交风险、清理/删除/回退缺专门协议。
- 可复现与安全：环境/服务配置证据不足、隐私/密钥/版权分类不足、绝对路径缺可迁移语义。
- 用户体验：用户下一步不明确、按钮/术语/状态让人困惑、人类纠偏和挫败没有成为系统信号。
- 工程治理：CI/发布接入不足、flaky/非确定性证据缺模型、任务命名和优先级治理弱、新 agent onboarding 成本高。
- 多 agent 执行细节：跨角色指令质量、冲突 verdict、运行状态手工修复、暂停取消、归档保留和截图证据质量缺少统一协议。
- 可执行性和记忆边界：命令不可复现、slice 依赖不显式、人类手工动作缺记录、runtime task 映射弱、长期记忆未提升为规则。
- 系统运行治理：队列背压、状态机、fixture 漂移、报告可读性、审批疲劳、恢复演练、工具绑定和供应链信任仍缺少工程化支撑。
- 协议安全和机器可读性：prompt injection、报告伪造、模板漂移、字段语义松散、LLM 审阅污染、Orbit 自身回归测试和多项目适配仍不充分。
- 长期信任和合规：事件溯源、prompt 复现、模型漂移、版权隐私、自动化越界、信任修复、配置策略和本地化仍缺少系统设计。
- 落地治理：兼容策略、多用户共享、质量校准、自引用审查、速度严谨取舍、证据备份和迁出路径仍缺少清晰规则。
- 组织采用和治理：Orbit 自身 owner、SLO、路线图、迁移成本、失败复盘、文档规模和退出机制还不清晰。

## 使用背景

本仓库已经不是轻量试用状态。当前 `/Users/yangke/Personal/own/autonovel/.orbit/` 下有大量真实运行痕迹：

- `.orbit/evidence/` 中有数百个 evidence/lock/report 文件。
- `.orbit/reports/` 中有数百份 review/test/lead 报告。
- `.orbit/loop-state.yaml` 已经膨胀到数十万字节量级。
- 当前磁盘粗略规模约为 24M，包含 585 个 reports、494 个 evidence 文件、459 个 rules 输出、258 个 handoffs、241 个 tasks。
- 典型长任务包括多阶段设计、公共调用层迁移、结构化产物重构、真实 UI/E2E 回归等。
- 常驻角色是 lead=Codex、reviewer=Claude、tester=opencode，通过 Herdr pane 协作。
- 项目 `.orbit/instances.yaml` 记录了三个 user-managed pane；`.orbit/roles.yaml` 声明了 lead/reviewer/tester 的 capability，但 role 下 `rules: []` 为空，实际行为规范主要来自 Orbit 默认 runtime 文档和 skill。

这些记录说明一个事实：Orbit 在这里承受的不是 toy workload，而是一个持续数周、频繁重启、频繁上下文压缩、频繁切 slice 的真实项目。

## 带来的真实收益

### 1. 它挡住了很多“看起来完成了”的假完成

Orbit 最大的收益是把“我做了动作”强行和“目标真的完成”分开。

真实例子：

- 某次真实回归 review 发现文档里的字符数、best attempt 文件和失败分类与磁盘 artifacts 不符，直接判 High。没有独立 reviewer 的磁盘交叉验证，后续修复方向会被错误数据带偏。
- 某次 UI 修复中，source 和 jsdom test 都没问题，但 reviewer 发现生产 app 实际加载的是旧构建产物；未重建构建产物就等于用户看不到修复。
- 某次方案文档 review 中，reviewer 抓到 closure grep 指向不存在路径，避免“grep 通过但其实没检查到东西”的 false closure。
- 某次公共调用层迁移中，多次 review 明确区分“metadata 包了一层”与“真正由公共执行边界调用外部服务”。

这类问题很难靠普通对话解决，因为 agent 默认倾向于把自己刚做的事解释成成功。Orbit 的 review/test gate 至少迫使另一个角色去找反例。

### 2. 长任务能接得住上下文断裂

当前项目的很多任务超过一次对话能稳定承载的范围。Orbit 的 task/evidence/report/handoff 让后续 agent 至少有地方恢复：

- 哪个 slice 已经完成；
- reviewer/tester 是否真的通过；
- 哪些 blocker 是代码问题，哪些是环境问题；
- 哪些运行产物是证据，哪些不能提交；
- 哪些 High/Medium 已关闭，哪些只是诚实记录。

没有这些记录，长任务很容易变成“上一轮说过什么我记得好像是这样”。对需要连续几十个 slice 的重构来说，这是不可接受的。

### 3. 角色分离确实提高了质量

tester 和 reviewer 分开是对的。很多时候 reviewer 能发现测试报告自洽但目标没达成，tester 能发现 reviewer 没跑真实路径。

有效模式是：

- lead 实施和整理证据；
- tester 跑真实路径、保留 artifacts、报告环境和 cleanup；
- reviewer 以 quality outcome 为中心审代码、文档、报告和磁盘事实。

这套分工尤其适合真实 UI/E2E，因为“跑了命令”和“用户路径真的可用”之间经常有距离。

### 4. 它让 blocker 更诚实

Orbit 做得好的时候，会迫使报告写成：

- 外部服务/DNS 挂了，不是代码完成；
- real run 被 content moderation 拦了，不是测试通过；
- 产品流程正确 fail-closed，不是功能坏了；
- 真实回归只证明某个历史问题没有复现，不等于可以关闭更大的质量目标。

这种诚实 blocker 对项目很重要。它避免为了“绿灯”而降低质量门。

## 主要痛点

下面不再按流水账列出一百多条问题，而是合并成十六个问题域。每个问题域保留判断重点和典型表现；具体项目案例只作为压力测试来源，不作为 Orbit 要直接解决的产品问题。

### 1. 质量门语义容易失真

Orbit 最大价值是让“做了动作”和“目标完成”分开，但质量门本身也容易被机械化。review 可能逐条确认标题、grep 字符串、测试数量，却没有判断方案是否真的防住失败模式；tester 可能证明命令跑过，却没有证明用户路径可用；PASS 也可能同时表示 docs pass、partial pass、honest blocker accepted 或 parent goal 仍 open。

典型风险是：task contract 一开始就框错 outcome，后面的 review/test 只是在认真执行错误任务。Orbit 需要把 task contract 质量、invalid completion guards、counterexample cases、quality outcome reasoning 和 parent-goal 状态放在质量门语义的核心位置。

- 判断依据：如果一个 gate 通过后，用户仍然无法确认目标是否完成，或 reviewer 只证明“文档/测试存在”而没有证明失败模式被防住，就属于质量门语义问题。
- 重点关注：先看 task contract 是否定义真实 outcome、反例、不可接受完成形态；再看 review/test 是否围绕这些 outcome 审，而不是围绕 checklist 表面字段审。

### 2. 长任务状态和 parent goal 容易分裂

长任务会被切成很多 slice。slice 变多本身不是错，但如果用户只能看到 S20、S29 之类编号，就会自然问“你到底在完成什么任务”。Codex goal、Orbit parent task、child slice、review gate、test gate、real runtime task 也经常是几套状态。

真正的问题不是编号，而是 parent objective、done criteria、active slice、blocked audit、remaining gate、user next action 没有单一权威视图。Orbit 需要避免 slice pass 被误读成 goal complete，也要避免 agent 每做完一个小步骤就停下来问下一步。

- 判断依据：如果用户问“你现在到底在干什么”“goal 完成了吗”“下一步是什么”，而 agent 只能引用某个 slice pass，就说明 parent goal 状态没有被 Orbit 清楚表达。
- 重点关注：所有 child slice 都应能回指 parent objective、done criteria、remaining blockers 和 next action；不要让编号、局部 PASS 或 gate 状态替代 parent goal。

### 3. Role 规范和权限仍然主要依赖自律

Orbit 有 lead/reviewer/tester 等角色，也有 identity_valid 和 instance binding，但角色规范是否加载、是否被本轮遵循、是否被用户降级，并不总是成为可审计事实。lead 可能抢 tester 的真实测试，reviewer 可能按 checklist 审，tester 可能缺真实浏览器验证，用户还需要反复提醒不要重启 reviewer、不要把小改动拉进 formal Orbit。

权限也是类似问题：role 声明不等于执行隔离。full-permission workspace 下，review/test agent 仍可能改文件、生成构建产物或污染 worktree。Orbit 更像审计模型，不是 sandbox 模型；关键任务需要更强的 role-doc hash、session id、worktree hash、只读/临时 worktree 或越权写入检测。

- 判断依据：如果一次任务需要靠用户提醒“等 tester”“不要重启 reviewer”“这个不用 Orbit”，或报告没有说明本轮加载了哪些 role 规范，就属于 role/权限问题。
- 重点关注：区分身份声明、规范加载、实际行为和文件权限；不要把 `identity_valid=true` 误读成角色绝对遵循或权限隔离。

### 4. Evidence 生命周期太重且容易漂移

`.orbit/` 的 evidence、reports、locks、handoffs、rules 和 loop-state 很快会膨胀成一个副仓库。它能保存历史，但也会让新 agent 难以判断哪些记录仍有效，让用户在大量状态文本里失去主线。review pass、manifest latest_record、identity_valid、validate/audit、loop-state 之间也可能漂移。

真实 evidence 还经常依赖易删运行产物。原始产物不一定适合长期保留，但如果只保留报告文字，后续又无法磁盘复核。Orbit 需要区分原始产物、压缩证明、hash、目录清单、关键指标、失败类型、少量合规摘录和生成命令，并有明确的归档、压缩、删除和迁出规则。

- 判断依据：如果 report、manifest、loop-state、validate/audit 或磁盘产物之间说法不一致，或 evidence 大到用户/agent 无法判断权威记录，就属于 evidence 生命周期问题。
- 重点关注：保留什么、压缩什么、删除什么、谁能复核、删除后还能不能证明结论；不要只堆更多 report。

### 5. Transport 和 evidence 边界不够硬

Herdr pane 是 transport，Orbit evidence 是 protocol，但实际使用中很容易混。reviewer 在 pane 里发 DONE/PASS，不代表 evidence manifest 已有有效 review record；tester 的自然语言报告看起来完整，也不代表 gate ready。用户看到的是聊天里的 verdict，很难判断它是不是 Orbit 承认的权威 verdict。

Orbit 需要在 transport 消息旁明确标出：这只是 pane reply，还是已经进入 manifest 的有效 record。多个 verdict 冲突、旧 reviewer 慢到、delta review 覆盖前一轮、latest_record 指向哪个报告，都需要机器可读的仲裁规则。

- 判断依据：如果用户看到 `DONE/PASS` 却还要问“这算 Orbit 通过了吗”，或 pane 消息和 manifest gate 状态不一致，就属于 transport/evidence 边界问题。
- 重点关注：每个 verdict 必须区分聊天通知、结构化 evidence、gate-ready record 和最终仲裁结果；不要把 pane 输出直接当事实。

### 6. Git、运行产物和破坏性操作缺少强护栏

混合 worktree 是常态：代码、文档、`.orbit` runtime、构建产物、真实运行产物、测试临时文件和用户未提交修改经常同时存在。`git status` 只是信息，不是护栏。Orbit 目前无法强制按 task contract 限制可提交路径、禁止路径、generated artifact policy 和 build artifact policy。

破坏性操作风险更高：从 git 删除、清理运行产物、杀测试进程、回退运行状态、删除子产物、恢复 task 状态，都不应该和普通编辑同级。至少需要 dry-run、target list、tracked/untracked 区分、user-owned/agent-owned 区分、undo path 和 evidence record。

- 判断依据：如果一次操作可能删除用户文件、提交不该提交的产物、改变运行状态或让 evidence 失效，就属于 Git/产物/破坏性操作问题。
- 重点关注：先明确目标路径、所有权、tracked 状态、是否可恢复、是否属于当前 task scope；不要把“清理一下”“从 git 删掉”当作普通自然语言命令。

### 7. 环境、外部服务和可复现性证据不足

很多 blocker 来自环境而不是代码：DNS、外部服务 adapter、`.env` 配置、browser/debug endpoint、server port、tracked build assets、Node build 输出、model alias、gateway 行为变化。Orbit 记录了一些 evidence，但通常不足以复现。

更合理的记录是 redacted config map、service family/model/stage mapping、server owner、browser owner、port、build hash、DNS/service smoke 摘要、model identity、service behavior fingerprint 和 prompt manifest。否则同一次 real run 的结论很难判断是代码差异、环境差异还是模型漂移。

- 判断依据：如果失败可能由 DNS、模型、服务网关、浏览器、端口、构建产物或 `.env` 引起，而报告只写“real run failed/pass”，就属于环境可复现性问题。
- 重点关注：记录可复现的环境指纹但不泄密；区分代码失败、环境失败、服务失败和模型漂移，避免把一次 real run 当成稳定结论。

### 8. 用户体验和下一步动作不够清楚

Orbit 报告对 agent 常常足够清楚，但对用户不够直接。用户真正关心的是：现在该等、重试、确认、刷新、修环境、删产物，还是进入实现？PASS、partial、blocked、honest blocker、ready、done_ready 这些词对用户来说很容易混成“到底完成没有”。

用户挫败也是系统输入：按钮太多、流程术语太多、reviewer 太多、agent 一直停下来、测试产物反复清理，都会降低信任。Orbit 需要稳定输出 `user_next_action`，并把用户纠偏、暂停、取消、继续、手工操作作为一等事件，而不是只停留在聊天记忆里。

- 判断依据：如果用户需要反复问“我该点什么”“现在能继续吗”“你怎么又停了/又自己测了”，就不是单纯产品 UI 问题，也可能是 Orbit 没给出可操作状态。
- 重点关注：每次交付都应说明当前状态、用户可选动作、默认建议、等待对象和不能做的事；不要只输出 gate 名词。

### 9. 工程治理和发布闭环不完整

本地 review/test gate pass 不等于 release ready。CI、打包、静态构建产物、依赖锁、远端分支、跨平台环境、发布包内容都可能和本地 Orbit evidence 不一致。branch/remote/local reviewed diff 也经常分裂。

Orbit 还缺少 ROI、SLO、owner、路线图、任务优先级、失败复盘、迁移成本、退出机制和发布边界。否则它会在项目里变成“默认税”：所有非平凡任务都被拉进 formal Orbit，而不是按风险选择轻重流程。

- 判断依据：如果本地 gate pass 后仍不知道能否发布、是否远端同步、是否 CI 覆盖、是否值得继续投入 Orbit，就属于工程治理问题。
- 重点关注：区分 local confidence、release readiness、CI status、remote state 和流程成本；不要把本地 review/test pass 直接等同于可发布。

### 10. 多 agent 执行细节缺少系统级治理

reviewer 慢、tester 忙、外部服务等待、lead 继续切 slice，会形成队列和背压。当前 Orbit 更关注单个 task/gate 的状态，不够表达系统级资源占用、pane lease、谁正在处理哪个 gate、是否允许替换 reviewer、旧输出到达时是否仍有效。

Handoff receiver 也不够成体系。交接不只是“把报告写完”，还要明确接收方需要读哪些证据、哪些可以忽略、哪些用户约束仍有效、哪些旧状态已失效、哪些命令可复现。

- 判断依据：如果多个 agent/pane 同时工作时，谁拥有 gate、谁可以重启、谁的输出有效、谁在等待谁都不清楚，就属于多 agent 治理问题。
- 重点关注：队列、lease、pane 生命周期、旧输出仲裁、handoff 接收条件和并发背压；不要只靠聊天约定协调。

### 11. 可执行性、记忆和文档生命周期边界不清

长期任务依赖摘要、handoff、lessons、project rules 和对话记忆，但摘要可能错、漏、过期；用户偏好和手工决定可能只存在聊天里；旧设计文档可能已经实现却仍留在 open；active baseline、implemented archive、historical reference 的生命周期不清，会误导后续 agent。

Orbit 需要把 conversation memory、project rule、lesson、active task constraint 和 doc lifecycle 分开，并提供提升路径。摘要本身也应可验证：能追溯原 evidence，并由接收方抽样校验。

- 判断依据：如果一个事实只存在于对话、旧文档仍在 open、摘要和原 evidence 不一致，或新 agent 不知道哪些约束仍有效，就属于记忆/文档生命周期问题。
- 重点关注：区分当前基线、活动设计、历史归档、经验 lesson 和临时约束；不要让旧文档继续指导新实现。

### 12. 系统运行态和 Orbit 记录缺少 reconcile

很多关键事实在运行系统里：server 是否开着、runtime task 是否 running、外部服务是否 waiting、构建产物当前 hash、运行产物是否存在、git 是否 ahead、pane 是否活着。Orbit evidence 只是某个时间点的快照。

如果不自动 reconcile，就会出现 report 引用已删产物、task 写 blocked 但产品运行态已恢复、operation active 但 UI 不显示、task pass 但 runtime task blocked。Orbit 应能关联外部 runtime task id，并区分 Orbit task、产品 runtime task、browser session、external-service operation。

- 判断依据：如果 Orbit task 的状态和真实运行系统状态不一致，或用户问“现在卡在哪里”需要人工跨多个状态源推理，就属于 runtime reconcile 问题。
- 重点关注：建立 Orbit task 与外部 task/operation/browser/server 的映射；不要把 Orbit YAML 当成唯一真相。

### 13. 协议安全和机器可读性仍不足

Evidence、report、logs、外部服务 output、用户内容和 handoff 都可能包含指令式文本，对 LLM agent 来说有 prompt injection 风险。自然语言 report 也容易和 JSON/YAML 字段不一致，甚至被过度信任。

Orbit 需要更强的 machine-readable schema、字段语义版本、report consistency check、negative evidence 表达、模板漂移检测、role evidence 读取范围记录，以及对 reviewer/tester “独立验证”到底读了哪些文件、跑了哪些命令的可见性。

- 判断依据：如果 report 的自然语言和结构化字段不一致，或 LLM 读取 evidence 时可能被内容里的指令污染，就属于协议安全/机器可读性问题。
- 重点关注：字段语义、schema version、负证据、读取范围、命令记录和 prompt-injection 边界；不要只相信自然语言报告。

### 14. 长期信任、合规和数据保留策略不够明确

真实项目会涉及 API key、用户内容、第三方素材、prompt、截图、外部服务 output 和本地路径。保留过多会带来版权、隐私和安全风险；保留过少又无法审计。当前 secret grep 和 redaction 不是统一数据保留策略。

一旦发生误删、误提交、错误测试、伪造数据或 UI 误导，用户信任会下降。Orbit 擅长记录问题，但缺少信任修复流程：公开承认、影响范围、恢复方式、预防措施、后续验证和用户确认。

- 判断依据：如果 evidence 里可能包含密钥、用户内容、第三方素材、外部服务输出或本地路径，或一次失误影响用户信任，就属于合规/信任问题。
- 重点关注：数据保留等级、脱敏、删除策略、影响范围和信任修复；不要为了可审计性无限保存敏感材料。

### 15. 多项目适配和组织采用规则还不成熟

当前经验来自一个重 LLM、重 UI、重运行产物的本地项目，不能直接压到所有项目。纯后端库、CLI 工具、移动端、企业业务系统、数据管道需要不同 profile。否则 Orbit 会因单个项目经验变得过重，小项目被过度流程化。

如果进入多用户共享工作区，还会出现用户权限、产物归属、pane 归属、reviewer/tester 责任、证据访问和清理策略差异。Orbit 需要 project profile、多用户模型和组织级治理，而不是一套流程压所有场景。

- 判断依据：如果某条规则只因为当前项目很重才成立，却被写成所有项目默认要求，就属于多项目适配问题。
- 重点关注：项目 profile、任务风险等级、团队/用户边界和流程轻重档位；不要把单项目经验固化成通用强制规则。

### 16. Orbit 自身也需要 dogfood、复盘和停止准则

Orbit 不能只靠项目 lessons 改进自己。它需要自己的 dogfood 回归：stale gate detection、role docs loaded、user decision record、destructive action dry-run、evidence/report mismatch、artifact retention、transport vs evidence verdict、task lane downgrade、self-review contamination 等。

同时，问题发现也需要 done criteria。否则 lessons 无限增长，发现问题替代了解决问题，用户无法判断是否该进入实现。复盘应覆盖主要失败域、每类有代表问题、重复项已合并、未知项已标注，然后进入优先级排序，而不是无限追加。

- 判断依据：如果 Orbit 的问题只能靠本项目偶然暴露，或复盘不断追加却没有停止条件，就属于 Orbit 自身治理问题。
- 重点关注：Orbit 自己的回归套件、失败复盘进入系统改进、问题发现 done criteria 和后续优先级排序；不要让 lessons 变成新的无限 backlog。

## 已确认的正向作用

这部分只记录事实，不展开方案：Orbit 在本项目里确实挡住过假完成、接住过长任务上下文断裂，也让 reviewer/tester 分离带来真实收益。问题不在于 Orbit 完全无效，而在于这些收益伴随了大量流程、证据、权限、状态和用户体验问题。

## 后续设计暂不展开

本轮目标是找问题，不是设计 Orbit 方案。上一版曾把每个问题展开成对应改进建议，这会把问题复盘带偏成设计文档。

后续如果要进入 Orbit 改进设计，应另开独立设计文档，并从本文件的问题清单中筛选优先级，而不是在这份复盘里继续扩展方案。

## 最终评价

Orbit 对我最大的改变是：它让“我觉得做完了”变得不够用。这个约束很有价值。

但 Orbit 目前最大的问题也是：它容易让 agent 把精力放在“怎样让流程看起来闭合”，而不是“目标是否真的闭合”。本文件当前只负责把这些问题尽量找全；如何排序、取舍和设计修复，应另开文档。

## 相关链接

- `/Users/yangke/Personal/own/autonovel/.orbit/roles.yaml`
- `/Users/yangke/Personal/own/autonovel/.orbit/instances.yaml`
- `/Users/yangke/Personal/own/autonovel/.orbit/reports/`
- `/Users/yangke/Personal/own/autonovel/.orbit/evidence/`
- `/Users/yangke/Personal/own/autonovel/docs/lessons/ai-agent-review-and-implementation-discipline.md`
- `/Users/yangke/Personal/own/autonovel/docs/review-rule.md`
- `/Users/yangke/Personal/own/autonovel/docs/implementation-plan-rule.md`

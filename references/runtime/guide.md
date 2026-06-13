# Orbit Runtime Guide

本文只服务一个场景：在真实项目里运行 Orbit。

如果你是第一次使用 Orbit，先读 [../../README.md](../../README.md)。那里按用户视角说明安装、初始化、配置和跑一轮任务；本文补充更细的运行时规则。

如果目标不是在真实项目里运行 Orbit，不读本文。本文不承载 Orbit 内部开发计划、产品设计过程或外部资料整理。

## 运行时目标

运行时不关心 Orbit 是怎么设计出来的，只关心本轮任务能不能形成可信闭环：

```text
identity -> task contract -> evidence -> loop state -> review/test gate -> handoff
```

运行时 agent 应该留下这些事实：

- 当前 agent 是什么角色。
- 本轮任务要交付什么质量结果。
- 做过哪些命令、review 或 test。
- 当前 loop state 到了哪个阶段。
- 是否通过独立 review/test gate。
- 下一位 agent 或用户如何接手。

## 运行时默认读取顺序

真实运行时优先读：

1. `SKILL.md`：skill 入口和最小工作流。
2. 本项目的 `.orbit/roles.yaml`：角色、capabilities、rules。
3. 本项目的 `.orbit/instances.yaml`：当前 instance 和启动配置。
4. 当前 task file：本轮任务合同。
5. 当前 evidence manifest：本轮证据。
6. 当前 loop state：本轮状态。

只有出现下列情况时，才读取 reference：

| 情况 | 读取文档 |
| --- | --- |
| 不清楚协议字段含义 | `core-operating-model.md` |
| 需要判断改善类任务是否真的变好 | `quality-outcome-and-review.md` |
| 需要实现或修复代码 | `coding-guideline.md` |
| 需要执行测试或判断测试证据 | `testing-guideline.md` |

bug fix、状态流转、artifact 写入、AI 输出解析、resolver、normalizer、validator、gate 和 tool 边界相关任务，默认要遵守 runtime coding/review/testing 文档中的结构约束规则：不要用增长黑名单 / 白名单作为主要边界，检查字段族和单一事实源，修同类入口或记录 known gap，替换旧逻辑时提供 closure guard。不能为了通过当前 gate 静默降级需求、绕过旧 gate、用业务兜底掩盖底层流程没接通，或把 late result 套到错误 run / phase / attempt / revision。

运行时不要默认读取本地 development 资料或项目案例。它们是开发期、设计期或 adoption 材料，读取它们容易把“怎么开发 Orbit”误当成“本轮任务怎么执行”。

## 当前规则机制

当前运行时有只读规则解析命令：

- Orbit 默认规则来自 `SKILL.md` 和本目录下的 runtime reference，始终适用。
- 项目自定义规则来自 `.orbit/roles.yaml` 中当前 role 的 `rules` 字段。
- `orbit whoami --json` 会解析当前身份，并把当前 role 的项目 `rules` 原样输出。
- `orbit rules resolve --json` 会生成可审计的规则解析结果，列出默认规则、项目规则、task 规则和 rule packs。
- `orbit rules print-context --json` 会把规则解析结果转换成本轮 agent 应读取的上下文清单，明确 `load_order`、去重后的 `required_files`、optional rule packs 和 `context_budget`。
- 本轮 task 规则来自 task contract，例如 `quality_rules`、`acceptance` 和 `evidence_requirements`。
- CLI 不读取规则文件全文，也不调用大模型做语义合并；它只做确定性解析、路径存在性检查和身份/task 冲突检查。

因此，项目 `rules` 是叠加层，不是替代层。没有项目 `rules` 时，agent 仍按 Orbit 默认规则工作；存在项目 `rules` 时，agent 先按 Orbit 默认规则工作，再读取项目规则和 task 规则。重复时按更具体的项目规则解释，冲突时按更严格规则执行，或在 evidence / handoff 中显式记录用户 waiver、conflict 和 residual risk。

每条规则上下文都应有稳定 `rule_id` 和 `relation`。默认规则使用 `orbit_default:<category>:<path>` 形式，项目规则默认使用 `project_rule:<path>`，task 规则使用 `task_rules:<path>`；项目可以显式设置 id。`relation` 表示规则与默认协议的关系，常见值是 `baseline`、`supplements`、`overrides`、`stricter_than` 和 `deprecated_by`。`rules print-context` 会给 `load_order` 标注 `dedupe_status`，并在 `context_budget` 中列出 `active`、`deduped`、`shadowed`、`not_loaded_but_related`。agent 只必须读取 active required files；deduped/shadowed/not_loaded entries 是审计线索，不应重复消耗上下文。

当当前用户意图是否需要正式 Orbit 闭环不清楚时，可以先运行：

```bash
orbit classify-intent --text "用户原话" --json
```

分类结果包含顶层 `intent`、`explicit_orbit_workflow` 和 `reason`，以及 `policy.formal_task`、`policy.evidence`、`policy.gates`、`policy.default_task_type` 等默认策略字段。默认意图包括 `discussion`、`design`、`docs_maintenance`、`coding`、`review`、`test`、`handoff`。`discussion` 默认不建 task，但选择不建 task 时要留下 reason；用户明确说“按 Orbit 流程”时必须进入正式 task/evidence/gate；docs maintenance 如果影响 `.orbit`、evidence、handoff、archive、路径引用、历史或规则文件，默认建正式维护 task。

## CLI 优先

只要 `orbit` CLI 可用，运行时优先使用 CLI，不手写协议文件。

真实接入一个新项目时，先确认 CLI 是否在 `PATH` 中：

```bash
command -v orbit
```

如果不可用，先按本仓库安装说明安装，或临时使用明确的 CLI 路径。不要因为找不到 CLI 就直接跳过结构化协议；否则后续 validate、audit 和 handoff 会退化成聊天总结。

推荐最小启动顺序：

```bash
orbit init
orbit new-task --target-role lead --task-type implementation --output .orbit/tasks/current-task.yaml
orbit evidence init --output .orbit/evidence/current-evidence.yaml
orbit state start --task .orbit/tasks/current-task.yaml
```

`task.yaml`、`evidence.yaml/json`、`loop-state.yaml` 是 CLI gate 的主输入。Markdown task contract、review-report、test-report 可以作为人读证据或附件，但不能替代结构化 task/evidence/state。`--evidence` 参数必须传 evidence manifest 文件，不能传 evidence 目录。

推荐命令：

```bash
orbit whoami --json
orbit instances status --json
orbit classify-intent --text "按 Orbit 流程继续实现这个功能" --json
orbit docs alias --id decision.active-design --path docs/open/active-design.md --json
orbit docs check --json
orbit start reviewer --dry-run --json
orbit new-task --target-role reviewer --task-type implementation_review --output task.yaml
orbit rules resolve --task task.yaml --output .orbit/rules/current-resolution.json --json
orbit rules print-context --task task.yaml --output .orbit/rules/current-context.json --json
orbit evidence init --output .orbit/evidence.json
orbit evidence attach-rule --file .orbit/evidence.json --rule-resolution .orbit/rules/current-resolution.json
orbit evidence add --file .orbit/evidence.json --kind review --status pass --summary "..."
orbit evidence from-report --file .orbit/evidence.json --report review-report.md --kind review --json
orbit evidence submit --file .orbit/evidence.json --report review-submit.yaml --json
orbit evidence waive --file .orbit/evidence.json --waiver waiver.yaml --json
orbit wait-gate --task task.yaml --evidence .orbit/evidence.json --json
orbit state show --json
orbit state start --task task.yaml
orbit state transition --to in_review --evidence .orbit/evidence.json
orbit state transition --to review_requested --evidence .orbit/evidence.json
orbit state transition --to user_confirmed --evidence .orbit/evidence.json
orbit state transition --to coding_ready --evidence .orbit/evidence.json
orbit validate --task task.yaml --evidence .orbit/evidence.json --state .orbit/loop-state.yaml --json
orbit audit --task task.yaml --evidence .orbit/evidence.json --state .orbit/loop-state.yaml --json
orbit tools detect --json
orbit tools doctor --json
orbit dispatch --task task.yaml --to reviewer --json
orbit handoff --task task.yaml --state .orbit/loop-state.yaml --evidence .orbit/evidence.json --json
orbit handoff --task task.yaml --state .orbit/loop-state.yaml --evidence .orbit/evidence.json --output handoff.json --record-state --json
orbit handoff --task task.yaml --state .orbit/loop-state.yaml --evidence .orbit/evidence.json --transport generic --json
orbit compact-evidence --task task.yaml --evidence .orbit/evidence.json --handoff handoff.json --output .orbit/summaries/task-summary.json --json
```

`orbit start` 只负责按 `.orbit/instances.yaml` 解析 instance、argv、env 和 cwd；本地模式直接启动命令，Herdr 模式通过 adapter 启动或 dry-run 展示计划。它不替代 `whoami`、task contract 或 evidence。

instance 默认是 `user_managed`：如果 reviewer/tester 已有 healthy binding，Orbit 应复用该 instance，而不是由 lead 新建另一个 pane。`orbit instances status --json` 会输出每个 instance 的 `management`、`binding_status` 和 `recommended_action`。`user_managed` 缺少 healthy binding 时，lead 应请求用户确认或先绑定；`orbit_managed` 才表示 Orbit 可以按配置自动启动缺失 role。`orbit bind-pane --instance reviewer --pane ... --json` 只绑定 transport handle，不改变 role identity。

`orbit dispatch` 只负责生成或发送 task 投递消息；generic 模式输出手工/外部投递 payload，Herdr 模式需要显式 `--pane`。它不改变 task/evidence/state，也不让 gate 自动通过。

如果 evidence manifest 通过 `rule_resolution.file` 引用了规则解析产物，`validate` 会检查该文件存在、schema 正确、`valid: true`，并且和当前 task / role 对得上；`audit` 和 `handoff` 会输出 `rule_resolution_summary`，方便接手者复核本轮实际使用的规则来源。`rules print-context` 生成的是读取清单，不替代可挂载到 evidence 的 `rules resolve` 审计产物。

`orbit evidence from-report` 可以把 reviewer/tester 报告导入 evidence record，但只接受明确 verdict/status token。`APPROVED_WITH_NOTES` 这类模糊结论不会被自动当成 pass；lead 应要求 reviewer/tester 给出清晰 verdict，或把残留风险记录为 `partial/fail`。

`orbit evidence submit` 是 review/test verdict 的结构化提交入口。report 必须包含 `kind`、`verdict`、`summary`、`source_message_id`、`findings`、`coverage` 和 `artifacts`。`source_message_id` 可以指向 Herdr message、pane transcript、CI job、report file 或其他 transport 附件；Herdr 文本本身不是权威 verdict，权威 verdict 是写入 evidence manifest 的结构化 record。兼容入口 `evidence add/from-report --kind review|test` 会写入最小结构化字段，但新流程应优先使用 `evidence submit` 保留完整 coverage/artifact 来源。

tester/test task 的 task contract 会包含 `test_environment`。最新 `kind: test` 且 `verdict: pass` 的结构化 evidence 必须记录 `test_environment`：实际环境、测试 pane/tab、server/browser owner、cleanup hook、artifact cleanup、duration、resource usage、cleanup status、UX 质量和 artifact 质量。缺少这些字段时，`validate` 会拒绝把该 test pass 当作可信成功证据。

性能、UX、workflow、quality、eval、measurement 等质量度量类 task 会包含 `quality_measurement`。最新 passing test evidence 必须记录 baseline、after 和 metrics，或显式记录 waiver 的 reason、risk 和 replacement_evidence。只说“感觉变好”或只跑普通测试，不足以证明这类 task 的 quality outcome。

`orbit evidence waive` 用结构化 waiver 记录用户或 lead 接受的残留风险。waiver 必须包含 `owner`、`scope`、`reason`、`risk`、`replacement_evidence`、`expiry` 和 `revoked_by_user_requirement`。waiver 不会让 review/test gate 自动通过；它只让 audit/handoff 能看见是谁接受了什么风险、用什么替代证据支撑、什么时候失效。

`orbit wait-gate` 只检查 task 的 required gates 是否已有最新结构化 `pass` evidence。它不会读取报告全文，也不会代替 reviewer/tester 判断。输出中的 `aggregate_verdict` 来自 evidence manifest 顶层聚合摘要，用于暴露每个 evidence kind 的最新状态和 waiver 风险；required gate 是否 ready 仍由 task 的 `gates` 和结构化 review/test records 决定。

`orbit docs alias` 维护 `.orbit/docs-registry.json` 中的 stable doc id、current path、content hash 和 updated_at。evidence、task 或 handoff 需要长期引用重要文档时，优先引用 stable doc id，并在文档移动后只更新 registry，不批量重写历史 evidence。`orbit docs check` 会检查 alias target 是否存在、content hash 是否匹配、open 目录是否存在已关闭但未归档或未索引文档，以及 archive 目录是否有 README。

`orbit compact-evidence` 从 task/evidence/handoff 生成 `orbit-durable-evidence-summary-v1` 摘要。摘要保留 task/evidence/handoff 的路径和 sha256、record 计数、latest verdict、rule resolution 引用、source documents、artifact refs 和 handoff audit summary；它不复制长日志、截图、server output 或完整 rule context。长期文档应优先保留 compact summary、final evidence manifest 和 handoff summary；过程中的 rule context、resolution、pane transcript、screenshots、logs 和 server output 默认是 transient artifact，用路径和 hash 引用。

Design-first 任务使用独立 lifecycle：`drafting -> review_requested -> changes_requested|user_confirmed -> coding_ready`。`orbit state start` 遇到 `task_type` 包含 `design` 或 `analysis` 的 task 会从 `drafting` 开始；`coding_ready` 只能从 `user_confirmed` 进入，并且 evidence manifest 必须同时有结构化 review pass 和包含 `user_confirmed` / user confirmation / 用户确认 的 pass evidence。review pass 不能单独让 design task 进入 coding。

`task_type` 包含 `coding` 的 task 必须在 `design_reference` 中引用已确认设计：`required_for_coding: true`、非空 `artifact`、非空 `confirmation_evidence`、`status: confirmed`。这防止 agent 把聊天里的隐含设计直接当成 coding 授权。

中型或大型拆分任务使用 `implementation_plan`、`decomposition` 和 `final_aggregate_audit`。`task_type` 包含 `decomposition` 或 `parent` 时，`validate` 会要求非空 implementation plan summary、child slices、aggregate outcome metrics、stop conditions、replanning path 和 final aggregate audit checks。child slice pass 只证明局部完成；parent final audit 必须重新证明整体 quality outcome。

如果 CLI 不可用，可以按 schema 手动检查，但必须在回复里标注 `local_fallback`，并说明哪个 CLI 动作没能执行。

## 角色运行规则

### Lead / Coder

职责：

- 澄清用户目标。
- 写 task contract。
- 实现或协调实现。
- 维护 loop state。
- 收集 evidence。
- 派 review/test。
- 派 review/test 前检查 `orbit instances status --json`，默认复用 healthy reviewer/tester binding。
- 根据 gate 结果继续、回滚、阻塞或收口。
- coding 时遵守 `coding-guideline.md`，保留 changed files、verification、closure 和 known gaps。

禁止：

- 把“做了动作”直接当成完成。
- 在缺少 review/test evidence 时宣布 gate-ready。
- 用聊天总结替代 evidence manifest。
- 在已有 healthy reviewer/tester binding 时擅自新建同 role instance。
- 以 lead 身份提交 review/test verdict 来关闭 reviewer/tester gate。

### Reviewer

职责：

- 独立判断 quality outcome。
- 审查 behavior、structure、evidence 和 residual risk。
- 输出 review verdict 和 findings。

禁止：

- 把测试通过等同于 review 通过。
- 只给“看起来可以”这类无证据结论。
- 在没有 task contract 时补脑任务目标。

### Tester

职责：

- 执行真实测试路径。
- 保留命令、截图、日志、录屏或其他 evidence。
- 输出 test verdict、覆盖范围和缺口。
- testing 时遵守 `testing-guideline.md`，区分 `pass|fail|partial|invalid`。
- `pass` evidence 必须记录测试环境生命周期；质量度量类 task 还必须记录 baseline/after 指标或显式 waiver。

禁止：

- 修改生产代码来让测试通过。
- 只测 mock happy path 却声称真实路径通过。
- 不保留失败证据。

## Task Contract

运行时 task 至少要说明：

- `target_role`
- `task_type`
- `objective`
- `quality_outcome`
- `acceptance`
- `evidence_requirements`
- `stop_policy`

改善类、重构、文档维护、性能、UX、可靠性和架构收敛类任务必须有非空 `quality_outcome`。`validate` 会检查 `user_problem`、`desired_property`、`measurable_thresholds` 和 `invalid_completions`，不能只留下空 key。否则 reviewer 应默认阻塞或要求补合同。

tester/test task 必须有 `test_environment` 合同，说明测试环境、pane/tab、server/browser owner、cleanup hook、artifact cleanup、duration budget 和 resource budget。质量度量类 task 必须有 `quality_measurement` 合同，说明 baseline/after 必填、需要哪些 metrics，以及 waiver policy。模板字段只是默认合同，lead 应按真实任务补具体值。

### 目标清晰和分片交付

lead 创建 task contract 时，必须把用户目标转成可验证描述，不能把模糊指令直接交给 coder。

task contract 应明确：

- source documents：原始用户消息、设计、issue、测试记录、线上 URL、真实仓库路径或用户确认路径。
- 真实目标：本轮要解决的用户问题或项目质量问题。
- 非目标：本轮明确不做什么，以及为什么不影响当前目标。
- 验收标准：哪些行为、命令、文件、报告或用户路径能证明完成。
- 关键假设：需求不完整时，当前采用了哪些假设；这些假设需要用户、reviewer 或 tester 核验。
- evidence 要求：PASS 前必须留下哪些命令结果、review/test verdict、截图、日志、handoff 或其他 artifact。

如果目标仍不清楚，lead 应优先澄清。只有在用户允许继续、时间受限或上下文足够明确时，才能带假设推进；假设必须写入 task contract，不能只写在聊天里。

`new-task` 会为常见改善类 task type 写入默认 quality outcome 模板和 review strategy。模板不是完成答案，lead 应按当前任务改写；但模板可以防止空 outcome 直接进入 coding。reviewer 默认按 Outcome、Behavior、Structure、Evidence、Residual risk 的顺序审查，测试通过不能替代 quality outcome verdict。

大任务必须拆成 slice。每个 slice 至少包含：

- slice 目标。
- scope include / exclude。
- checkpoint：本 slice 完成后要检查什么。
- acceptance：本 slice 自己的通过条件。
- evidence：本 slice 需要留下的证据。

每个 slice 完成后，先做自检，再进入必要 review/test gate。一个 slice 的 PASS 只证明当前 slice，不证明整个大任务完成。review/test 发现 high 或 medium 问题时，回到当前 slice 修复并重新验证，不应跳到下一个 slice。

可以用提示词帮助整理目标、提取验收点和核验关键信息，但整理结果必须落到 task contract、evidence manifest 或 loop state。聊天内容不能替代这些文件。

### Source Contract 和 Traceability

复杂任务、跨多文件任务、改善类任务和真实测试任务必须有可追溯合同。task contract 需要把 source documents 中的关键要求映射到 slice、验收项和 evidence，避免 agent 把用户目标缩成“先能跑”的版本。

最低要求：

- source contract：不可删减目标、非目标、验收标准、用户体验要求和安全边界。
- traceability：每个关键要求对应哪个 slice、用什么命令/测试/artifact 证明、什么条件算关闭。
- cleanup plan：替换旧逻辑时列出旧入口、旧 helper、旧 fallback、旧 writer 如何关闭。
- final completeness audit：收尾时逐条对照 source contract 和 traceability，确认没有缩减实现、旧路径残留、业务兜底或测试专用分支。

没写进 out of scope 的原始要求，默认仍在 scope 内。Traceability 每一行最终都要有执行证据；review 结论不能替代执行证据。

## Evidence

evidence 是事实记录，不是口头说明。

最小 evidence record：

```yaml
kind: command | review | test | handoff
status: pass | fail | partial | invalid
summary: "发生了什么，以及这个证据支持什么结论。"
created_at: "ISO-8601 timestamp"
```

review evidence 和 test evidence 不能互相替代。review-only evidence 不能让 test gate 通过，test-only evidence 也不能让 review gate 通过。

顶层 `verdict` 是 aggregate 摘要，不是最新 record 的别名。它应包含 `mode: aggregate`、整体 `status`、每个 evidence kind 的最新状态、最新 record 和 waiver 计数。后续 command 或 implementation pass 不能覆盖仍为 fail/partial 的 review/test gate。判断 task 是否 ready 时，以 `wait-gate`、`validate`、`audit` 对 required gates 的检查为准。

Durable evidence 和 transient artifacts 必须分层。durable 层是 task summary、final evidence manifest、handoff packet、compact summary、stable doc registry 和用户可复核的最终报告；transient 层是 rule context、临时 rule resolution、pane transcript、长日志、截图、server output、浏览器录屏和一次性诊断 dump。transient artifact 可以作为 evidence record 的 artifact ref，但不应被全文塞进长期 docs。需要把任务沉淀为长期记录时，运行 `orbit compact-evidence` 并保留摘要路径。

实现类 task 可以在 `gates` 中声明后续 gate：

```yaml
gates:
  - kind: review
    roles: [reviewer]
    required: true
  - kind: test
    roles: [tester]
    required: true
```

`target_role` 仍表示当前实现或协调的主要负责人。`gates.roles` 表示哪些角色可以合法读取同一个 task 并提交 gate evidence。也就是说，reviewer/tester 在 coder 或 lead 的 implementation task 上工作时，不应因为 `target_role` 不同被视为身份冲突；如果当前 role 既不是 `target_role`，也不在 `gates.roles` 中，仍然 fail closed。

普通 `orbit validate --task --evidence` 不会因为 implementation task 的 gate 尚未完成而失败，这样 coder 可以先记录 implementation evidence。进入 `done` 或运行最终 `audit` 时，Orbit 会要求 task 声明的 review/test gate 都有最新 `pass` evidence。

reviewer 或 tester 可以在 evidence manifest 中补充结构化 judgment：

- `review_judgment`：包含 `verdict`、`quality_outcome`、`findings` 和可选 `residual_risk`。
- `test_judgment`：包含 `verdict`、`environment`、`scenarios` 和可选 `coverage_gap`。

CLI 只校验这些 judgment 的结构和必填字段，不替代 reviewer/tester 的判断。
如果没有顶层结构化 judgment，`orbit handoff --json` 会从最新的 `kind=review` / `kind=test` evidence record 推导 `judgment_summary`，来源会标记为 `latest_evidence_record`。这不是替代详细报告，而是给下一位 agent 一个稳定、可机器读取的 gate 摘要。

## Worktree 和 Git 安全

涉及 review、commit、push、release、publish、合并、关闭 issue / PR 或任何会改变公共状态的动作时，必须先读取当前 worktree：

```bash
git status --short --branch -uall
```

modified、staged 和 untracked 文件都默认视为用户或其他 agent 的工作。agent 可以读取并纳入 review surface，但不能为了“保护现场”擅自 stash、clean、reset、checkout、移动到 `/tmp` 或改写这些文件。需要 branch switch、stash、clean、reset 或移动用户文件时，必须取得当前轮明确授权。

commit / push 前后都应重新读取 `git status --short --branch -uall` 和 `git rev-parse HEAD`。如果 HEAD 变化、出现未知提交、或 worktree 出现不属于当前 task 的变化，停止并报告，不要继续 rebase、重提 commit 或 push。

在 dirty 或多 agent checkout 里，测试通过不一定证明当前改动通过；无关 WIP 可能提供符号、配置或 fixture。高风险变更需要隔离验证，例如从已知 commit 建临时 worktree，只应用当前 task 负责的 diff，再运行关键验证。

如果当前项目不是 Git 仓库，不要把 worktree safety 写成模糊的 `not_applicable`。evidence 应显式记录：

```yaml
worktree_safety:
  status: not_git
  reason: "当前项目不是 Git 仓库。"
  unexpected_changes: []
```

`orbit validate` 会要求 `not_git` 带 reason；`audit` 和 `handoff` 会输出 `worktree_safety_summary.mode=non_git_project`。这表示 worktree safety 是不可用而不是漏检。需要 commit、push 或 release 的真实仓库仍必须使用 Git 状态证据。

## Rule Packs

rule pack 是可选增强，不是默认协议。项目可以显式提供 `.orbit/rule-packs.yaml`：

```yaml
schema_version: orbit-rule-packs-v1
rule_packs:
  common:
    - project-common
  review:
    - id: brooks-review
      path: references/rule-packs/brooks-review.md
  test:
    - brooks-test
  audit:
    - orbit-drift
```

没有这个文件时，Orbit 仍然正常运行。存在这个文件时，`orbit whoami --json`、`orbit new-task ...`、`orbit rules resolve --json`、`orbit rules print-context --json` 和 `orbit handoff --json` 会在 `rule_packs` 字段列出本轮建议读取的规则包。CLI 只暴露规则包清单，不解释规则内容，也不把子仓库规则写进默认协议。`print-context` 会把 rule packs 放进 `load_order`，但默认标为 optional/conditional；项目需要强制读取某个规则包时，应把它作为项目规则文件写入 `.orbit/roles.yaml`。

## Project Health 和 Supply Chain

Orbit 默认不做完整 health audit，但运行时应保留以下最低健康边界：

- 非平凡项目应提供稳定验证入口，例如 `make test`、`make check`、`npm test`、`pytest`、`go test ./...` 或 CI 中明确的等价命令。没有稳定 verifier wrapper 时，应记录为结构风险，而不是把零散命令当作默认通过路径。
- 任务引用的文档、规则、skill reference、handoff、release 或安全文档必须存在且路径可解析。缺失引用会让后续 agent 读取错误上下文，应作为 evidence gap 或 structural finding。
- ignored、本地私有 overlay、个人 memory、一次性聊天记录、review scorecard 和 diagnostic dump 不能作为 durable project truth。需要沉淀时，只提取稳定 invariant、验证命令和适用边界。
- 如果同一模块短期内反复出现 fix chain，应把它视为缺少稳定 invariant 或 verifier 的信号，补项目规则、测试或结构化 gate，而不是继续堆点状修复。
- 第三方 skill、plugin、MCP、hook、install script 都是 supply-chain surface。应记录来源和版本 / commit；默认不信任 floating `main`、tracking branch、wildcard tool allowlist、permission-skip flag、API base URL override 或自动信任本地 MCP。
- hook / install script 不应写 credential 目录、secret 文件或绕过用户确认。报告问题时只写 key 名、文件位置或风险类别，不打印 secret 值。

## Loop State

loop state 记录当前协作状态，不依赖聊天历史。

运行时常见 phase：

| Phase | 含义 |
| --- | --- |
| `idle` | 没有绑定任务。 |
| `working` | 正在写合同、实现或协调。 |
| `in_review` | 等待或处理 review gate。 |
| `in_test` | 等待或处理 test gate。 |
| `blocked` | 缺证据、verdict 未通过、需要用户输入或预算不足。 |
| `done` | 必要 gate 已通过，可以交接或关闭。 |

进入 `done` 前必须运行 validate。
长任务应使用 `orbit state progress --message "..." --evidence ...` 记录阶段心跳。progress 不改变 phase，只更新 `status`、`updated_at` 和 `history`，用于让 lead、reviewer、tester 或 handoff receiver 知道当前停在哪个检查点。长时间只在聊天或 pane 输出里说明进度，不如写入 loop state 可审计。
声明 `done` 或交接前应运行 audit，确认 task/evidence/state 没有漂移。
audit 输出会区分 `trusted_for_handoff`、`trusted_for_done` 和 `trusted_for_release`。如果存在 issue，agent 应读取 `remediation` 并补证据或修正状态；例如 done 状态没有记录 handoff artifact 时，`trusted_for_done` 可以为 true，但 `trusted_for_release` 会保持 false。生成最终交接产物时，优先使用 `orbit handoff --output handoff.json --record-state --json`，让 loop state 记录可追溯的 handoff artifact。

Final completeness audit 和真实 E2E / dogfood 不是一回事。Final audit 负责代码侧完整性、traceability、旧路径关闭和 evidence 完整性；真实 E2E / dogfood 负责用户路径是否真的可用。任一方缺失时都不能包装成完整完成，只能记录 residual risk 或 open item。

## Fail Closed

以下情况默认不能宣称完成：

- role identity 冲突。
- task target role 和当前 agent 身份冲突，且当前 role 不在 task `gates.roles` 中。
- 缺 task contract。
- 改善类任务缺 quality outcome。
- 缺必要 evidence。
- implementation task 的 review/test gate 尚无最新 pass evidence，却声明 `done`。
- review/test verdict 为 `fail`、`partial` 或 `invalid`。
- evidence 时间不可排序。
- loop state 与 task/evidence 引用不一致。
- 原始必须项被静默降级成 out of scope。
- 通过业务层兜底掩盖 runner、schema、状态机、provider、tool 或真实入口未接通。
- confirmed artifact、历史证据或失败 run 被原地改写。
- late result 没有绑定 run / phase / attempt / revision 就被应用到当前状态。

用户可以决定接受风险，但 agent 必须把风险说清楚，不能把它包装成已验证完成。

## Transport

herdr、tmux、CI、GitHub Actions、普通 shell 都只是 transport。

运行时只需要保证：

- task 以文件或 payload 传给目标 agent。
- evidence 能被收集回 manifest。
- handoff 能被下一位 agent 或用户读取。
- delivery confirmation：任务确实送达目标 role / instance。
- result collection：lead 主动等待、读取并记录对方输出；不能假设 transport 会自动把回复路由回来。

transport 不改变 Orbit 语义。缺少 herdr 不代表 Orbit 不能运行；可以退回 generic JSON / file handoff。
需要选择 transport 前，先用 `orbit tools detect --json` 或 `orbit tools doctor --json` 检查当前环境能力。
handoff packet 会带上 validate、audit、tools、transport profile 和 judgment 摘要，供下一位 agent 或 transport adapter 判断当前交接是否可信。

如果项目提供 `.orbit/tools.yaml`，`orbit handoff --transport NAME --json` 会读取其中的 `transport_profiles`，并在 `transport_profile.payload` 中输出适合投递的 JSON payload。这个 payload 只描述怎么投递，不实际调用 herdr、tmux 或 CI，也不改变 `required_action`、gate verdict 或 exit code。请求的 profile 缺失或 transport 不可用时，handoff 会降级为 `generic`。

跨 agent 任务应发送 task file 路径、evidence 目标路径和 stop/gate 规则；长 diff、长日志和长上下文写入文件，只发送路径。只在聊天里说“已发给 reviewer/tester”不算 evidence。

---
name: orbit
description: 用于 AI agent 在项目中感知或执行 Orbit 工作流：发现 .orbit 配置后先进入 Orbit-aware 模式；当目标明确且进入实现、评审、测试、验收、交接或 long-running/multi-agent workflow 时，再自动调用 orbit CLI 解析 role identity、创建 task contract、维护 evidence manifest 和 loop state、执行 review/test gate、validate/audit/handoff。manual protocol 是当前稳定默认路径；Herdr automatic runtime 仍是 preview，不提供 direct dispatch 或 verified runtime identity。需求澄清和结对梳理阶段不要创建 task/state/gate。
metadata:
  short-description: Orbit 任务闭环和 gate
---

# Orbit

Orbit 是面向 AI agent 的任务闭环协议。manual file/JSON protocol 是当前稳定、默认且不依赖 Herdr 的路径。Herdr 只能提供 `automatic-preview` 的 pane start/inspect；在 trusted proof provider 和 provider E2E 都未通过前，不能宣称 automatic、direct dispatch 或 Herdr-verified runtime identity。notice 当前只是 `.orbit/runtime/notices` 下的 protocol record / inbox，不是 Herdr pane delivery。这个 skill 的职责是让当前 agent 在项目里感知 Orbit 边界，并在进入正式执行闭环时自动执行 Orbit 流程：确认身份、建立任务合同、记录证据、推进状态、触发 review/test gate、生成交接。

## 何时触发

进入 Orbit-aware 模式：

- 当前仓库存在 `.orbit/roles.yaml`、`.orbit/instances.yaml`、`.orbit/loop-state.yaml` 或 Orbit task/evidence/handoff 文件。此时只代表项目有 Orbit 边界，不代表必须立刻创建 task、推进 state 或要求 gate。
- 用户提到 Orbit、`.orbit`、`orbit init`、`orbit validate`、`orbit audit`、`orbit handoff`、agent operating model、loop engineering、long-running agents 或多 agent 协作。
- 用户要设置或执行 lead、coder、reviewer、tester、handoff receiver 等 role。
- 任务涉及 task contract、evidence manifest、quality outcome、review gate、test gate、loop state、rule conflict 或 service-controlled tools。
- 在已经接入 Orbit 的项目里执行非平凡的实现、评审、测试、验收或交接。
- 用户要把 Orbit 接入具体项目，同时保持项目规则和默认协议分层。

启动正式 Orbit 闭环：

- 用户目标已经清楚，并要求开始实现、修改、评审、测试、验收、发布准备或交接。
- 用户接受了拆分后的 slice，或 agent 已经和用户澄清出可执行的目标、边界和验收标准。
- 当前工作需要多个 role 协作，或需要用 evidence/gate/handoff 保证长任务可接手。
- 用户明确说“按 Orbit 流程”“正式 task”“正式任务”或等价表达时，必须进入正式 task/evidence/gate 闭环。
- 文档维护如果触及 `.orbit`、evidence、handoff、archive、路径引用、历史记录或规则文件，默认按正式维护任务处理。

需求澄清、方案讨论、探索性结对阶段只保持 Orbit-aware：

- 帮用户澄清真实目标、非目标、验收标准、风险、边界和候选 slice。
- 不创建 task contract，不推进 loop state，不要求 review/test gate，不把未定需求包装成正式任务。
- 如果 agent 选择不建 task，应在回复或内部记录中留下简短 reason，例如 `discussion_only`、`requirements_unclear` 或 `docs_light_edit`。
- 可以参考 Orbit 的思路组织问题，但不要用流程动作打断用户表达需求。

不要自动使用这个 skill：

- 仓库没有 `.orbit`，用户也没有要求 Orbit，而且只是简单问答或一次性小改动。
- 用户只是询问和 Orbit 无关的通用编程问题。

## 工作流

1. 先判断当前是不是已经进入正式 Orbit 闭环：
   - 真实项目运行时只读取运行时资料，不让用户承担 Orbit 内部开发材料。
   - CLI 可用且边界不确定时，先用 `orbit classify-intent --text "..." --json` 获取默认策略；它只给确定性建议，不替代 agent 对用户上下文的判断。
   - 如果用户还在澄清需求，停留在 Orbit-aware 模式，先把目标和验收标准问清楚。
2. 在推断 role identity 前，先发现 `orbit` CLI：
   - 优先使用 `PATH` 中的 `orbit`。
   - 如果当前就在本仓库工作，并且 `scripts/orbit` 可执行，就使用它。
   - 如果没有可用 CLI，只能做只读本地文件诊断，并说明 role/config 检查来自文件和 reference，而不是 CLI 解析结果；不要写正式 task/evidence/gate-closing record。
3. 进入正式 Orbit 闭环后，agent 必须自己运行常规 Orbit 命令，不要要求用户代跑：
   - 用 `orbit whoami --json` 解析身份。
   - 默认按稳定 manual protocol 工作。需要 reviewer/tester 或其他 role gate 前，先用 `orbit tools detect --json` 确认 capability mode；当前通常是 `manual` 或 `automatic-preview`，这两种模式都用 `orbit dispatch --manual-payload` 生成手工投递 artifact。
   - 只有未来 capability mode 明确为 `automatic`，且 `orbit instances status --json` 的 resolver 对目标输出 `dispatch_ready: true` 时，才能 direct dispatch。`.orbit/instances.yaml` 的 binding 只是 last-known hint，不是 alive proof；不要自行用 Herdr env、pane、client、binding 或旧 session file 判断 verified。`orbit start INSTANCE` 在 preview 中只代表 pane 启动/检查能力，不代表可信投递；只有 stale/conflict/replacement 场景且用户或 owner 接受替换风险时才用 `--force`。
   - 用 `orbit rules resolve --task task.yaml --output .orbit/rules/current-resolution.json --json` 生成本轮规则解析审计产物；还没有 task 时先用 `orbit rules resolve --output .orbit/rules/current-resolution.json --json`。
   - 用 `orbit rules print-context --task task.yaml --output .orbit/rules/current-context.json --json` 生成本轮读取清单，并读取其中 `required_files`；还没有 task 时先用 `orbit rules print-context --output .orbit/rules/current-context.json --json`。项目规则不得替代默认规则。
   - 用 `orbit new-task` 创建 task contract。
   - `orbit state start` 会把 execution-ready task 冻结为 revision 1。启动后如果 scope、acceptance、risk、规则或其他合同字段变化，先修改 task，再运行 `orbit revision create --task ... --reason ... --change-type ... --json`；不要手改后继续沿用旧 gate。Orbit 只失效该 change type 影响的 evidence。
   - 用 `orbit evidence init/add/from-report/submit/waive/show` 管理 evidence manifest；implementation evidence 必须用 `orbit evidence add --file ... --kind implementation --status pass --summary ... --task task.yaml` 写入，`from-report` 不能创建 implementation evidence。`artifact_provenance.required: true` 时，先用 `orbit artifact inspect` 为实际输出生成带 hash/git head/task revision 的引用，再在 implementation PASS 中提交 changed files、verification 和 `--artifact-ref`；review/test report 必须引用当前 implementation artifact。review/test verdict 必须由 reviewer/tester 自己写独立 report 文件，并用 `orbit evidence submit --file ... --report ... --task ... --json` 写入。gate 只承认 identity 匹配对应角色且 artifact 仍可验证的 record。不要用 `evidence add`、`from-report` 或直接编辑 `.orbit/evidence*.json` 来提交 review/test。
   - 用 `orbit evidence attach-rule --file ... --rule-resolution .orbit/rules/current-resolution.json --task task.yaml` 把本轮规则解析产物挂到 evidence manifest。
   - 默认先用只读的 `orbit status` / `orbit next` 看当前 task、身份、implementation/gate 状态、blocker 和下一条命令；它们只能从 task/state/evidence/runtime 派生，不能建立新的状态事实源。
   - 用 `orbit state show/start/transition` 推进 loop state。solo 实现和自测结束但尚无 fresh-context 独立验收时，必须转为 `implemented_not_independently_accepted`，不能继续模糊停在 `working`，也不能包装成 `done`；随后通过 manual reviewer/tester 或未来 verified automatic gate 完成验收。
   - 用 `orbit wait-gate --task ... --evidence ... --json` 检查 required review/test gates 当前是否 ready。
   - 用 `orbit validate --task ... --evidence ... --state ... --json` 做结构化 gate-ready 检查。
   - 用 `orbit audit --task ... --evidence ... --state ... --json` 做 done/handoff/release 前审计。
   - handoff 统一写入 `.orbit/handoffs/`；`orbit compact-evidence` 默认在 `knowledge.durable_summary_dir` 为每个 task 维护一份可版本化摘要。长日志、截图、rules cache 和 runtime output 保持 transient；生成摘要后才可用 `--cleanup-transient` 清理结构化 transient refs。
   - 用 `orbit handoff --task ... --state ... --evidence ... --json` 生成机器可读交接包。
4. 只有以下情况才向用户要输入：目标不明确、缺少外部权限或密钥、需要破坏性操作、需要公开发布、需要访问用户私有系统但当前环境没有授权。
5. 读取 reference 时按场景分层：
   - 真实运行时先读 `references/runtime/guide.md`；字段语义不清时读 `references/runtime/core-operating-model.md`；改善类 review 口径不清时读 `references/runtime/quality-outcome-and-review.md`；实现代码时读 `references/runtime/coding-guideline.md`；执行测试或判断测试证据时读 `references/runtime/testing-guideline.md`。
   - 需要文档地图时读 `references/overview.md`。
6. 如果在目标项目仓库内工作，先检查现有 `.orbit/roles.yaml`、`.orbit/instances.yaml` 和 `docs/operating-model.md`，再提出修改。

## Role Resolution

1. 如果 CLI 可用，运行 `orbit whoami --json`，并把其中的 `resolved_role`、`rules`、`permissions`、`conflicts` 当作身份解析权威结果。
2. 如果 `conflicts` 非空，停止并报告冲突，不要在假定 role 下继续。
3. 进入正式 Orbit 闭环后，运行 `orbit rules resolve --task task.yaml --output .orbit/rules/current-resolution.json --json`；如果还没有 task，运行 `orbit rules resolve --output .orbit/rules/current-resolution.json --json`。规则解析产物必须写成文件，作为 evidence/handoff 可引用的审计产物。
4. 运行 `orbit rules print-context --task task.yaml --output .orbit/rules/current-context.json --json`；如果还没有 task，运行 `orbit rules print-context --output .orbit/rules/current-context.json --json`。agent 必须读取输出里的 `required_files`，并把 rule packs 当成 optional/conditional 增强清单。
5. `rules print-context` 输出的 `rule_id`、`relation`、`dedupe_status` 和 `context_budget` 是本轮上下文预算的一部分；只把 active required files 当成必读，deduped/shadowed/not_loaded_but_related 要保留为审计线索。
6. 如果 `rules resolve` 或 `rules print-context` 的 `conflicts` 非空，停止并报告冲突；缺失项目规则文件、task target 不匹配或身份冲突都不能静默跳过。
7. 创建 evidence manifest 后，把规则解析产物通过 `orbit evidence attach-rule` 挂到 evidence；后续 validate/audit/handoff 会复核并摘要它。
8. 如果 CLI 不可用，只能读取 `.orbit/roles.yaml`、`.orbit/instances.yaml` 和相关 reference 做只读本地诊断，并明确标注这不是 CLI 解析结果；不得写正式 task/evidence/gate-closing record。
9. 不要只根据当前 prompt、agent client name、pane id 或 task 文案猜测 persistent identity。
10. `whoami` 输出里的 `resolved_instance`、`role_ref`、`expected_command`、`actual_client`、`binding` 和 `herdr` 是审计身份的一部分；review/test verdict 必须能追溯到提交它的 instance。
11. `instances.yaml` 中的 binding 只能作为 launch/reuse hint。agent 不得只凭 binding、pane id、client name、Herdr env 或 `user_managed` 判断目标可复用；必须以 runtime resolver 输出为准。`instances status --json` 默认不得写回版本化 config，只有用户显式运行 `instances status --repair-binding --json` 才能修复 binding。

## Runtime Identity

- `orbit whoami --json` 解析当前 role / instance，但这不等于目标 agent live verified。
- Herdr env、pane id、tab/workspace 名字、client name 都不是可信 identity proof。
- `orbit runtime register --json` 和 piggyback register 在当前版本只能记录 `identity_pending` 或 `manual_runtime` diagnostics，不能把 session 提升为 `herdr_verified`。
- `orbit tools detect --json` 是 capability truth source；`manual` 是稳定路径，`automatic-preview` 只允许 pane start/inspect，二者都不能输出或使用 `direct.dispatch` capability。
- direct dispatch 必须要求目标 instance 的 resolver 输出 `dispatch_ready: true`。
- `identity_pending`、`stale`、`replaced`、`override` 不能关闭 gate，也不能被当成 verified delivery identity。
- 当前版本没有 trusted caller-pane proof provider；任何手写、旧 session file 或无法由 resolver 复核的 `herdr_verified` 都不能 direct dispatch，也不能关闭 gate。
- `manual_runtime` 是 explicit manual protocol path，不触发 automatic runtime；它可以按默认 policy 提交 evidence，但 audit/handoff 必须标注它不是 Herdr-verified。如果 task 要求 Herdr-verified gate，manual evidence 不能直接关闭 gate，除非有显式 waiver 或项目策略允许。

## 缺失配置

- 明确要求初始化，或当前是 lead 初始化上下文：CLI 可用时优先运行 `orbit init`；否则从 `assets/templates/` 创建最薄 starter config。
- reviewer/tester 上下文：报告 config 缺失并停止，不要静默初始化规则。
- 已有项目自定义规则时，仍然必须加载 Orbit 默认 runtime 规则；用户规则是叠加层，不是替代层。
- 若默认规则和项目规则重复或冲突，先按更严格规则执行，并在 evidence/handoff 中显式记录 conflict、waiver 或 residual risk。

## Role 行为

- lead/coder：拆分任务、维护 task/state/evidence、实施变更、收集 verification，不能把“做了动作”直接当成完成。
- design/analysis：不要把设计评审通过当成 coding 授权。design task 应按 `drafting -> review_requested -> changes_requested|user_confirmed -> coding_ready` 推进；进入 `coding_ready` 前必须有结构化 review pass 和用户确认证据。
- parent/decomposition：中型或大型任务必须维护 `implementation_plan`、`child_slices`、aggregate outcome metrics、stop conditions、replanning path 和 final aggregate audit；child slice pass 不能替代 parent outcome 审计。
- reviewer：围绕 quality outcome 做独立评审，输出 verdict 和 findings；高/中风险未关闭时不得放行 gate。
- tester：执行真实行为路径和失败路径验证，保留环境、步骤、artifact 和 verdict；`real_path_required` task 必须运行 journey 引用的项目 test hook，并在 report 开头用 `user_outcomes` 记录用户完成了什么、实际步骤/结果、截图/崩溃/网络/媒体 artifact、设备/浏览器/服务版本和未覆盖路径；passing test evidence 还要记录测试 pane/tab、server/browser owner、duration/resource、cleanup 和 artifact lifecycle；性能/UX/quality/measurement 类任务要记录 baseline/after 或显式 waiver；只跑 build 不等于真实测试。
- handoff receiver：不是当前循环的执行者，而是下一轮接手者；接收 handoff 时先读 task/state/evidence/audit，再判断是否可信。

## 输出要求

- 改进类任务必须先有 Quality Outcome Contract，不能把“做了动作”直接当成完成。
- 当 task 的 `design_reference.required_for_coding: true` 时，coding 必须引用已确认的 design artifact；如果用户要求先设计后确认，agent 不得在 `coding_ready` 前开始实现。小型 coding task 可以显式保持 `required_for_coding: false`。
- coding 必须保留 changed files、verification、closure 和 known gaps；testing 必须保留真实路径、环境、artifact、cleanup/resource/UX/artifact-quality 信息和 verdict。
- review/test verdict 应通过独立 report 文件加 `orbit evidence submit --file ... --report ... --task ... --json` 进入 manifest；可从 `assets/templates/review-report.yaml` 或 `assets/templates/test-report.yaml` 复制模板后填写。不要直接编辑 `.orbit/evidence*.json` 来提交 review/test，即使 JSON 结构看起来正确也不能用来关闭 gate；Herdr 消息只是 transport 附件，不是权威 verdict。
- 长任务或 docs maintenance 涉及路径移动、归档或历史 evidence 时，应使用 `orbit docs alias/check` 维护 stable doc id，并用 `orbit compact-evidence` 生成 durable summary；不要把 rule context、长日志、截图或 pane transcript 全文写入长期文档。
- 缺 evidence、verdict 不清、role 冲突或缺 quality outcome 时，默认 fail 或 escalation。
- transport 和 protocol 要分离：manual file/JSON protocol 是稳定默认路径；Herdr 当前只是 automatic-preview transport。tmux、zellij、wezterm、CI 或普通终端也只能承载 manual protocol，不提供 Orbit automatic start、direct dispatch 或 verified runtime identity。
- 汇报时说明 agent 已运行的 Orbit 命令、当前 gate 状态、剩余风险和下一步，而不是要求用户自己执行常规 Orbit 命令。

## 模板

初始化项目时使用这些 starter 文件：

- `assets/templates/roles.yaml`
- `assets/templates/instances.yaml`
- `assets/templates/loop-state.yaml`
- `assets/templates/task.yaml`
- `assets/templates/evidence.json`

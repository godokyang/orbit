---
name: orbit
description: 用于任意 AI agent 在项目中感知或执行 Orbit 工作流：发现 .orbit 配置后先进入 Orbit-aware 模式；当目标明确且进入实现、评审、测试、验收、交接或 long-running/multi-agent workflow 时，再自动调用 orbit CLI 解析 role identity、创建 task contract、维护 evidence manifest 和 loop state、执行 review/test gate、validate/audit/handoff。需求澄清和结对梳理阶段不要创建 task/state/gate。
metadata:
  short-description: Orbit 任务闭环和 gate
---

# Orbit

Orbit 是面向任意 AI agent 的运行时协作协议，不绑定具体 agent 软件。这个 skill 的职责是让当前 agent 在项目里感知 Orbit 边界，并在进入正式执行闭环时自动执行 Orbit 流程：确认身份、建立任务合同、记录证据、推进状态、触发 review/test gate、生成交接。

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
   - 如果没有可用 CLI，只能进入 `local_fallback` 模式，并说明 role/config 检查来自文件和 reference，而不是 CLI 解析结果。
3. 进入正式 Orbit 闭环后，agent 必须自己运行常规 Orbit 命令，不要要求用户代跑：
   - 用 `orbit whoami --json` 解析身份。
   - 需要 reviewer/tester 或其他 role gate 前，先用 `orbit instances status --json` 检查已有 instance binding；默认复用 healthy 的 `user_managed` reviewer/tester，不要擅自新建。
   - 用 `orbit rules resolve --json` 生成本轮规则解析审计产物。
   - 用 `orbit rules print-context --json` 生成本轮读取清单，并读取其中 `required_files`；项目规则不得替代默认规则。
   - 用 `orbit new-task` 创建 task contract。
   - 用 `orbit evidence init/add/from-report/submit/waive/show` 管理 evidence manifest；review/test gate 优先要求 reviewer/tester 自己用结构化 submit 写入 verdict，且 gate 只承认 identity 匹配对应角色的 review/test record。
   - 用 `orbit evidence attach-rule --file ... --rule-resolution ...` 把本轮规则解析产物挂到 evidence manifest。
   - 用 `orbit state show/start/transition` 读取和推进 loop state。
   - 用 `orbit wait-gate --task ... --evidence ... --json` 检查 required review/test gates 当前是否 ready。
   - 用 `orbit validate --task ... --evidence ... --state ... --json` 做结构化 gate-ready 检查。
   - 用 `orbit audit --task ... --evidence ... --state ... --json` 做 done/handoff/release 前审计。
   - 用 `orbit handoff --task ... --state ... --evidence ... --json` 生成机器可读交接包。
4. 只有以下情况才向用户要输入：目标不明确、缺少外部权限或密钥、需要破坏性操作、需要公开发布、需要访问用户私有系统但当前环境没有授权。
5. 读取 reference 时按场景分层：
   - 真实运行时先读 `references/runtime/guide.md`；字段语义不清时读 `references/runtime/core-operating-model.md`；改善类 review 口径不清时读 `references/runtime/quality-outcome-and-review.md`；实现代码时读 `references/runtime/coding-guideline.md`；执行测试或判断测试证据时读 `references/runtime/testing-guideline.md`。
   - 需要文档地图时读 `references/overview.md`。
6. 如果在目标项目仓库内工作，先检查现有 `.orbit/roles.yaml`、`.orbit/instances.yaml` 和 `docs/operating-model.md`，再提出修改。

## Role Resolution

1. 如果 CLI 可用，运行 `orbit whoami --json`，并把其中的 `resolved_role`、`rules`、`permissions`、`conflicts` 当作身份解析权威结果。
2. 如果 `conflicts` 非空，停止并报告冲突，不要在假定 role 下继续。
3. 进入正式 Orbit 闭环后，运行 `orbit rules resolve --json`；如果已有 task，带上 `--task ...`，并优先把结果写入 `.orbit/rules/<task>-resolution.json` 作为 evidence/handoff 可引用的审计产物。
4. 运行 `orbit rules print-context --json`；如果已有 task，带上 `--task ...`，并优先写入 `.orbit/rules/<task>-context.json`。agent 必须读取输出里的 `required_files`，并把 rule packs 当成 optional/conditional 增强清单。
5. `rules print-context` 输出的 `rule_id`、`relation`、`dedupe_status` 和 `context_budget` 是本轮上下文预算的一部分；只把 active required files 当成必读，deduped/shadowed/not_loaded_but_related 要保留为审计线索。
6. 如果 `rules resolve` 或 `rules print-context` 的 `conflicts` 非空，停止并报告冲突；缺失项目规则文件、task target 不匹配或身份冲突都不能静默跳过。
7. 创建 evidence manifest 后，把规则解析产物通过 `orbit evidence attach-rule` 挂到 evidence；后续 validate/audit/handoff 会复核并摘要它。
8. 如果 CLI 不可用，读取 `.orbit/roles.yaml`、`.orbit/instances.yaml` 和相关 reference 作为 fallback，并明确标注结果为 `local_fallback`。
9. 不要只根据当前 prompt、agent client name、pane id 或 task 文案猜测 persistent identity。
10. `whoami` 输出里的 `resolved_instance`、`role_ref`、`expected_command`、`actual_client` 和 `transport_binding` 是审计身份的一部分；review/test verdict 必须能追溯到提交它的 instance。
11. `instances.yaml` 中默认 `management: user_managed`：已有 healthy binding 时必须复用；只有 `orbit_managed` 或用户明确确认/waiver 时，lead 才能创建缺失 reviewer/tester。

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
- tester：执行真实行为路径和失败路径验证，保留环境、步骤、artifact 和 verdict；passing test evidence 还要记录测试 pane/tab、server/browser owner、duration/resource、cleanup 和 artifact lifecycle；性能/UX/quality/measurement 类任务要记录 baseline/after 或显式 waiver；只跑 build 不等于真实测试。
- handoff receiver：不是当前循环的执行者，而是下一轮接手者；接收 handoff 时先读 task/state/evidence/audit，再判断是否可信。

## 输出要求

- 改进类任务必须先有 Quality Outcome Contract，不能把“做了动作”直接当成完成。
- coding task 必须引用已确认的 design artifact；如果用户要求先设计后确认，agent 不得在 `coding_ready` 前开始实现。
- coding 必须保留 changed files、verification、closure 和 known gaps；testing 必须保留真实路径、环境、artifact、cleanup/resource/UX/artifact-quality 信息和 verdict。
- review/test verdict 应通过结构化 evidence submit 或等价结构化记录进入 manifest；Herdr 消息只是 transport 附件，不是权威 verdict。
- 长任务或 docs maintenance 涉及路径移动、归档或历史 evidence 时，应使用 `orbit docs alias/check` 维护 stable doc id，并用 `orbit compact-evidence` 生成 durable summary；不要把 rule context、长日志、截图或 pane transcript 全文写入长期文档。
- 缺 evidence、verdict 不清、role 冲突或缺 quality outcome 时，默认 fail 或 escalation。
- transport 和 protocol 要分离：herdr、tmux、CI、routines 可以搬运 task，但不定义 operating model。
- 汇报时说明 agent 已运行的 Orbit 命令、当前 gate 状态、剩余风险和下一步，而不是要求用户自己执行常规 Orbit 命令。

## 模板

初始化项目时使用这些 starter 文件：

- `assets/templates/roles.yaml`
- `assets/templates/instances.yaml`
- `assets/templates/loop-state.yaml`
- `assets/templates/task.yaml`
- `assets/templates/evidence.json`

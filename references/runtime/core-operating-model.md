# Core Operating Model

本文定义跨项目通用的 Orbit。它是运行时协议解释，不写任何单项目业务细则，也不承载实施计划。

## 基本原则

- 角色是职责位，不是模型名、客户端名或 pane id。
- 身份必须在 agent 创建、重启或恢复时注入；skill 通过 `orbit whoami` 消费解析结果。
- task file 使用 `target_role` 声明本轮任务目标角色，但不能静默覆盖 agent 的持久身份。
- `.orbit/roles.yaml` 是机器可读项目事实源；`docs/operating-model.md` 是人读说明。
- reviewer/tester 是独立 gate，不是 lead 的附属流程。
- 可枚举、可重复、可验证的动作应工具化；AI 负责判断、取舍和解释。

## 角色和职责

默认最小角色集是 lead / reviewer / tester。这里的角色是 archetype，不是固定组织结构：小项目可以让 lead 兼任 coder；复杂项目可以在 `.orbit/roles.yaml` 显式声明 coder、planner、release 等角色，并把它们映射到 capabilities、permissions 和 gate。

核心协议不从任何单项目产品或源码里导入默认角色，也不把 Codex、Claude Code、opencode 这类客户端类型当职责。

| 角色 | 职责 |
| --- | --- |
| lead | 建 task contract、协调任务、派 review/test、聚合 evidence、更新 loop state；在小项目里可兼任 coder |
| coder | 可选角色；按 task contract 和 `coding-guideline.md` 实现，不拥有独立 review/test gate；也可由 lead 兼任 |
| reviewer | 独立 review、判断 quality outcome、列高/中/低问题、阻塞未达标任务 |
| tester | 按 `testing-guideline.md` 执行真实测试、保留失败证据、提交 `pass|fail|partial|invalid` verdict |

## 身份注入

身份注入发生在 agent 生命周期边界：创建、重启、恢复或由 launcher / transport adapter 拉起新实例时。它不发生在 skill 文件内部，也不应该依赖每次派单时临时说明。

推荐产品形态是 `CLI + skill + project config + runtime identity`：

- 当前 CLI 负责读取项目配置、`ORBIT_INSTANCE` / `ORBIT_ROLE` 和 task file，并给出可审计的 resolved role。
- skill 不直接猜身份；skill 调用 CLI 的 `whoami` 能力，按返回结果加载规则。
- project config 描述项目有哪些角色和规则入口。
- runtime identity 描述当前 agent 实例到底是哪一个角色实例。

核心原则：配置文件只能说明“项目里有哪些角色”，不能自动说明“当前这个 LLM 会话是哪一个角色”。当前实例身份必须来自运行时，例如 `ORBIT_INSTANCE=reviewer-main`、`ORBIT_ROLE=reviewer`、`orbit start reviewer-main`、transport label 或启动 prelude。

推荐注入位置：

| 注入位置 | 场景 | 示例 | 说明 |
| --- | --- | --- | --- |
| 进程环境变量 | 启动 agent 进程时 | `ORBIT_ROLE=reviewer codex` | 给 tool/skill 读取；每个 agent 进程必须单独设置 |
| 启动 prelude | agent 启动后第一条初始化消息 | `你是当前 workspace 的 reviewer role...` | 直接进入 LLM 上下文，是最清晰的身份信号 |
| transport metadata | 创建 tab、pane、session 或 worker 时 | label = `reviewer-main` | 作为环境信号，经 Role Mapping 映射成通用角色 |
| task file | 每次派单时 | `target_role: reviewer` | 只校验本轮任务是否派对人，不给 agent 重新定身份 |

不要在父 shell 里全局 `export ORBIT_ROLE=reviewer` 后启动多个 agent；这样所有子进程都会继承 reviewer 身份。launcher / transport adapter 应为每个实例分别设置 env、label 和 prelude。

启动器伪代码：

```yaml
agents:
  - name: lead-main
    role: lead
    env:
      ORBIT_ROLE: lead
      ORBIT_NAME: lead-main
      ORBIT_DOC: docs/operating-model.md
    transport:
      tab_label: lead-main
    prelude: |
      你是当前 workspace 的 lead role。
      启动后运行 orbit whoami --json，并加载返回的 rules。
      负责实现、派 review/test、记录证据。

  - name: reviewer-main
    role: reviewer
    env:
      ORBIT_ROLE: reviewer
      ORBIT_NAME: reviewer-main
      ORBIT_DOC: docs/operating-model.md
    transport:
      tab_label: reviewer-main
    prelude: |
      你是当前 workspace 的 reviewer role。
      启动后运行 orbit whoami --json，并加载返回的 rules。
      不要实现生产代码，等待 task file。

  - name: tester-main
    role: tester
    env:
      ORBIT_ROLE: tester
      ORBIT_NAME: tester-main
      ORBIT_DOC: docs/operating-model.md
    transport:
      tab_label: tester-main
    prelude: |
      你是当前 workspace 的 tester role。
      启动后运行 orbit whoami --json，并加载返回的 rules。
      执行真实测试，不修改生产代码，等待 task file。
```

## CLI + Skill 身份解析

skill 的推荐启动动作：

```text
1. 若用户意图是否需要正式闭环不清楚，调用 orbit classify-intent --text "..." --json。
2. 调用 orbit whoami --json。
3. 读取 resolved_role、rules、permissions、conflicts。
4. 如果存在 conflicts，停止并报告。
5. 调用 orbit rules resolve --json，已有 task 时带上 --task，生成规则审计产物。
6. 调用 orbit rules print-context --json，已有 task 时带上 --task，读取其中 active required_files。
7. 加载 print-context 中声明的 Orbit 默认规则、项目规则和 task 规则；rule packs 作为 optional/conditional 增强清单，deduped/shadowed/not_loaded_but_related 只作为审计线索。
8. 按 permissions 和 role 执行任务。
```

`orbit classify-intent --json` 的输出用于把 Orbit-aware 和正式 Orbit 闭环分开。它不替代 agent 对用户上下文的判断，但给出稳定默认策略：`discussion` 不建 task 且要记录 skip reason；`design`、`coding`、`review`、`test`、`handoff` 默认进入对应结构化流程；`docs_maintenance` 只有在触及 `.orbit`、evidence、handoff、archive、路径引用、历史或规则文件时默认进入正式维护 task；用户明确要求“按 Orbit 流程”时必须建 task、写 evidence，并按 task 类型要求 gate。

`orbit docs alias/check` 和 `orbit compact-evidence` 是 docs/evidence lifecycle 的协议工具。`docs alias` 建立 stable doc id、current path 和 content hash，避免文档移动时重写历史 evidence；`docs check` 检查 registry、open/archive 状态和断链；`compact-evidence` 把 task/evidence/handoff 压缩成 durable summary，只保留 hash、计数、latest verdict 和 artifact refs，不复制 transient rule context、长日志、截图或 pane transcript。

`orbit whoami --json` 的输出示例：

```json
{
  "schema_version": "orbit-whoami-v1",
  "project": "example-project",
  "instance": "reviewer-main",
  "resolved_instance": "reviewer-main",
  "role_ref": "reviewer-main",
  "resolved_role": "reviewer",
  "expected_command": "codex",
  "actual_client": "codex",
  "transport_binding": {
    "pane": "pane-123",
    "tab": "",
    "space": ""
  },
  "role_sources": {
    "env.ORBIT_INSTANCE": "reviewer-main",
    "env.ORBIT_ROLE": "reviewer",
    "project_config.instances.reviewer-main.role_ref": "reviewer-main",
    "project_config.roles.reviewer-main.role": "reviewer"
  },
  "rules": [
    "docs/operating-model.md",
    "docs/review-rule.md",
    "docs/implementation-rule.md"
  ],
  "capabilities": [
    "review.submit",
    "evidence.write_review"
  ],
  "permissions": {
    "can_edit_production_code": false,
    "can_update_loop_state": false,
    "can_submit_review": true,
    "can_submit_test": false
  },
  "conflicts": []
}
```

项目配置描述角色和规则：

```yaml
# .orbit/roles.yaml
capability_registry:
  task_contract.write:
    kind: service_controlled
    description: "创建或更新任务合同。"
  code.edit:
    kind: agent_action
    description: "修改生产代码。"
  review.submit:
    kind: service_controlled
    description: "提交 review verdict 和 findings。"
  test.run:
    kind: agent_action
    description: "执行测试并保留证据。"
  test.submit:
    kind: service_controlled
    description: "提交测试 verdict 和 evidence。"
  loop_state.update:
    kind: service_controlled
    description: "推进 loop state。"
  artifact.write_authoritative:
    kind: service_controlled
    description: "写权威产物或状态。"

roles:
  lead-main:
    role: lead
    capabilities:
      - task_contract.write
      - code.edit
      - loop_state.update
      - artifact.write_authoritative
    rules:
      - docs/implementation-rule.md
    permissions:
      can_edit_production_code: true
      can_update_loop_state: true

  reviewer-main:
    role: reviewer
    capabilities:
      - review.submit
    rules:
      - docs/review-rule.md
      - docs/implementation-rule.md
    permissions:
      can_edit_production_code: false
      can_submit_review: true

  tester-main:
    role: tester
    capabilities:
      - test.run
      - test.submit
    rules:
      - docs/test-rule.md
    permissions:
      can_edit_production_code: false
      can_submit_test: true

tool_policy:
  service_controlled:
    - loop_state.update
    - review.submit
    - test.submit
    - artifact.write_authoritative
  agent_discoverable:
    - read_only_diagnostics
    - inspect_context

permission_projection:
  can_edit_production_code:
    any_capability:
      - code.edit
  can_update_loop_state:
    any_capability:
      - loop_state.update
  can_submit_review:
    any_capability:
      - review.submit
  can_submit_test:
    any_capability:
      - test.submit
```

运行实例配置描述怎么启动当前实例：

```yaml
# .orbit/instances.yaml
instances:
  reviewer-main:
    role_ref: reviewer-main
    command: codex
    management: user_managed
    transport:
      kind: herdr
      binding:
        pane: ""
        tab: ""
        space: ""
      health:
        last_heartbeat: ""
        cwd: ""
        git_head: ""
        actual_client: ""
    env:
      ORBIT_INSTANCE: reviewer-main
      ORBIT_ROLE: reviewer
```

`management` 定义 instance 生命周期由谁管理：

- `user_managed` 是默认值。用户已经打开或绑定的 reviewer/tester 是权威协作拓扑，lead 必须复用 healthy binding；缺失或不健康时应请求确认或记录 waiver。
- `orbit_managed` 表示 lead/Orbit 可以按配置自动启动缺失 instance。启动成功后 adapter 应写回 binding 和 health。

`transport.binding` 只记录 pane/tab/session 等 transport handle，不定义 role；role 仍来自 `role_ref` 和运行时 identity。gate 等待的是 instance verdict，而不是某个自然语言 pane 消息。

启动命令形态：

```bash
orbit start lead-main
orbit start reviewer-main
orbit start tester-main
```

`orbit start reviewer-main --dry-run --json` 会输出当前实现可审计的启动计划；非 dry-run 会启动配置的 agent 命令。当前 CLI 已负责：

1. 设置进程 env：`ORBIT_INSTANCE=reviewer-main`、`ORBIT_ROLE=reviewer`。
2. 启动 Codex / Claude Code / 其他 agent 客户端，或在 `--transport herdr` 下生成/调用 Herdr start adapter。
3. 输出 argv/env/cwd，避免通过 shell 字符串拼接命令。

transport label、pane 布局和启动 prelude 属于 adapter/agent 客户端能力；如果当前 adapter 不支持，不能假装已经注入。agent 启动后仍必须自己运行 `orbit whoami --json`、`orbit rules resolve --json` 和 `orbit rules print-context --json`。

这样最终流程变成：

```text
skill 不判断身份
skill 调 orbit whoami
skill 调 orbit rules resolve / print-context
orbit 读取 env + project config + task file
orbit 返回 resolved role + rules + permissions + context files
agent 按返回值工作
```

## Role Resolution

角色来源：

| 来源 | 示例 | 作用 | 规则 |
| --- | --- | --- | --- |
| 启动 prelude / launcher metadata | `你是 reviewer role` | 确定默认职责 | 当前 CLI 不直接读取；adapter 应转成 env 或后续 metadata 输入 |
| project config 的 Role Mapping | `reviewer-main: reviewer` | 把项目/transport 名称映射成通用职责 | 只做映射，不直接替代启动指令 |
| transport label | tab / pane / session label = `reviewer-main` | 提供环境信号 | 当前 CLI 不直接读取；adapter 应转成 `ORBIT_INSTANCE` 或后续 metadata 输入 |
| 环境变量 | `ORBIT_ROLE=reviewer` | 机器可读兜底 | 与 prelude 冲突时 fail closed |
| CLI whoami | `orbit whoami --json` | 聚合身份和项目规则路径 | skill 优先使用的身份解析结果 |
| CLI rules resolve | `orbit rules resolve --json` | 解析默认规则、项目规则、task 规则和 rule packs | 正式闭环里的规则审计产物 |
| CLI rules print-context | `orbit rules print-context --json` | 输出 agent 本轮应读取的 load_order、required_files 和 rule packs | 正式闭环里的上下文读取清单 |
| task file | `target_role: reviewer` | 声明本轮任务目标角色 | 必须与当前 agent 身份一致 |
| 用户当前消息 | “请你 review” | 当前交互提示 | 不能覆盖已确定的持久角色 |

判定算法：

1. 如果 CLI 可用，先调用 `orbit whoami --json`，把它作为权威解析结果。
2. 当前 `orbit whoami` 内部收集环境变量、project config 和 task file；prelude、transport label 和用户当前消息不能被假定为已进入 CLI，除非 adapter 明确转换成 env 或后续 metadata 输入。
3. 用 project config / Role Mapping 把项目角色名归一化，例如 `lead-main -> lead`。
4. 如果存在多个持久身份信号且互相冲突，返回 conflicts；skill 停止并报告冲突。
5. 如果 task file 声明的 `target_role` 与当前 agent 身份不一致，停止并要求 lead 重新派单。
6. 如果 CLI 不可用，skill 才按同样规则在本地做降级解析，并在 evidence 中标注 `role_source_mode: local_fallback`。
7. 如果没有持久身份，但 task file 明确声明 `target_role`，可以只在本 task 内临时采用该 role，并在结果里标注 `role_source: task_file_only`。
8. 如果仍无法确定角色，不得默认自己是 reviewer/tester；普通单 agent 会话中，只有用户直接要求实现或协调时，才可临时作为 lead/coder 工作。

禁止事项：

- 不用 `agent=codex/opencode/claude` 判断职责；那只是客户端类型。
- 不用 pane id 判断职责；pane id 会变化，pane 查找由 adapter 处理。
- 不让 task file 静默改变一个已启动 agent 的持久角色。
- 不让 reviewer/tester 在缺少 operating model 时自行初始化项目规则。

## Rule Ownership

规则不是只给 lead 的。每条规则都要有适用对象、owner 和 gate。

| 规则族 | 适用 agent | Owner | Gate / 放行者 | 说明 |
| --- | --- | --- | --- | --- |
| 角色解析与 operating model 读取 | all | 当前 agent 自己 | 当前 agent fail closed | 任何角色启动后都必须先确认身份和项目规则 |
| 任务合同 / Quality Outcome Contract | lead, reviewer | lead | reviewer | lead 写；reviewer 判定是否足以作为完成标准 |
| Source Contract / Traceability Matrix | lead, reviewer | lead | reviewer | lead 建映射；reviewer 查是否缩小需求或缺证据 |
| 实现边界 / scope control / 不隐性扩任务 | lead, coder, reviewer | lead/coder | reviewer | lead/coder 执行；reviewer 阻止低价值搬移和隐性扩 scope |
| 功能闭环 / 契约一致性 / 架构分层 | lead, coder, reviewer | lead/coder | reviewer | 不能只看是否生成代码；必须追到 writer、reader、schema、docs、调用路径和层级边界是否同时成立 |
| 结构约束 / 名单式限制 / 字段族 | lead, coder, reviewer | lead/coder | reviewer | 优先 schema、parser、状态、引用和 provenance；增长型自然语言名单应阻塞 |
| 修改扩散 / 状态回退 / 规则同步 | lead, coder, reviewer, tester | lead | reviewer/tester | 代码、测试、文档、配置、运行时状态和 lessons 必须一起更新；review/test fail 后要回到明确状态 |
| Closure guard / 旧路径关闭 | lead, coder, reviewer | lead/coder | reviewer | 替换旧逻辑时证明旧入口不能继续写权威状态或 artifact |
| 独立 review / 质量第一 / findings first | reviewer | reviewer | reviewer 自身输出，lead 消费 | reviewer 的主规则 |
| 真实测试 / dogfood 纪律 | tester | tester | tester 自身输出，lead 消费；reviewer 可审测试充分性 | tester 不修生产代码，失败证据必须保留 |
| Evidence manifest | all | 各角色写自己的 evidence；lead 聚合 | reviewer/tester 可因证据不足阻塞 | review 结论、测试报告、命令结果都要可追溯 |
| Tool 化 / 阶段可见工具 / service-controlled tool / CLI 不等于可靠调用 | lead, coder, reviewer, tester | lead 或工具 owner | reviewer | lead/coder 落地工具；reviewer 检查关键动作是否仍靠自然语言约定，以及写状态、写 artifact、推进 gate 的动作是否被系统强制执行 |
| 数据安全 / 禁止触碰正式产物 | all | all | reviewer/tester 可阻塞；lead 修复 | 任何角色都不能绕过项目禁止事项 |
| Loop state / done/block/continue 决策 | lead, reviewer, tester | lead | reviewer/tester 提供结论，lead 更新状态 | reviewer/tester 只追加结果，不直接把任务标 done |
| operating model / lessons 演进 | all | lead 汇总 | reviewer 审查规则是否准确 | 任一角色可提出新规则，稳定后由 lead 纳入文档 |

最低要求：

- all agents 都读通用规则、项目规则、任务文件和禁止事项。
- lead/coder 不能自评通过；必须消费 reviewer/tester 的独立结论。
- reviewer 不能只审“是否做了”，必须审 outcome、行为、结构和证据。
- tester 不能帮系统过关；测试污染时结论是 `INVALID TEST`。

## Project Config 模板

每个项目需要一份机器可读配置，优先使用：

```text
.orbit/roles.yaml
.orbit/instances.yaml
```

`docs/operating-model.md` 可以存在，但它是人读说明或由 YAML 生成的文档，不是 CLI/skill 的唯一事实源。

`capabilities` 是规范化事实源；`permissions` 是给 agent 和工具消费的派生结果。CLI 应按 `permission_projection` 从 capabilities 生成 permissions，避免自定义角色只靠自由布尔字段表达能力。

### `.orbit/roles.yaml`

```yaml
schema_version: orbit-roles-v1
capability_registry:
  task_contract.write:
    kind: service_controlled
  code.edit:
    kind: agent_action
  review.submit:
    kind: service_controlled
  test.run:
    kind: agent_action
  test.submit:
    kind: service_controlled
  loop_state.update:
    kind: service_controlled
  artifact.write_authoritative:
    kind: service_controlled

roles:
  lead-main:
    role: lead
    capabilities:
      - task_contract.write
      - code.edit
      - loop_state.update
      - artifact.write_authoritative
    rules:
      - docs/implementation-rule.md
    permissions:
      can_edit_production_code: true
      can_update_loop_state: true

  reviewer-main:
    role: reviewer
    capabilities:
      - review.submit
    rules:
      - docs/review-rule.md
      - docs/implementation-rule.md
    permissions:
      can_edit_production_code: false
      can_submit_review: true

  tester-main:
    role: tester
    capabilities:
      - test.run
      - test.submit
    rules:
      - docs/test-rule.md
    permissions:
      can_edit_production_code: false
      can_submit_test: true

tool_policy:
  service_controlled:
    - loop_state.update
    - review.submit
    - test.submit
    - artifact.write_authoritative
  agent_discoverable:
    - read_only_diagnostics
    - inspect_context

permission_projection:
  can_edit_production_code:
    any_capability:
      - code.edit
  can_update_loop_state:
    any_capability:
      - loop_state.update
  can_submit_review:
    any_capability:
      - review.submit
  can_submit_test:
    any_capability:
      - test.submit

document_zones:
  active_design: docs/design/
  open_work: docs/open/
  reference_only: docs/reference/

default_commands:
  backend_targeted_tests: uv run pytest <tests>

project_prohibitions:
  - Do not write protected artifacts unless explicitly requested.
```

### `.orbit/instances.yaml`

```yaml
schema_version: orbit-instances-v1
instances:
  lead-main:
    role_ref: lead-main
    command: codex
    env:
      ORBIT_INSTANCE: lead-main
      ORBIT_ROLE: lead

  reviewer-main:
    role_ref: reviewer-main
    command: codex
    env:
      ORBIT_INSTANCE: reviewer-main
      ORBIT_ROLE: reviewer

  tester-main:
    role_ref: tester-main
    command: codex
    env:
      ORBIT_INSTANCE: tester-main
      ORBIT_ROLE: tester
```

## Task File

每次派单都生成 task file，而不是直接发送长 prompt。

```yaml
schema_version: orbit-task-v1
target_role: reviewer
task_type: implementation_review
project: example-project
quality_rules:
  - docs/review-rule.md
  - docs/implementation-rule.md
source_documents:
  - docs/design/example.md
source_contract:
  required_outcomes:
    - "不可删减的用户目标、质量底线或安全边界。"
  out_of_scope:
    - "本轮明确不做的内容和原因。"
  cleanup_plan:
    - "旧入口、旧 helper、旧 fallback 或旧 writer 如何关闭。"
traceability:
  - requirement: "source contract 中的一条关键要求。"
    slice: "S1"
    acceptance:
      - "对应验收项。"
    evidence:
      - "对应命令、测试、artifact、截图或 report。"
    closure_condition: "什么条件下可认为关闭。"
scope:
  include:
    - src/example/service.py
  exclude:
    - out-of-scope modules
assumptions:
  - "需求仍不完整但可先验证的关键假设；需要 review/test 或用户核验。"
quality_outcome:
  user_problem: "当前维护问题。"
  desired_property: "改完后的质量属性。"
  measurable_thresholds:
    - "能被测试、结构、指标或 artifact 验证。"
  invalid_completions:
    - "只完成表面动作但问题仍存在。"

# 对改善类、重构、文档维护、性能、UX、可靠性和架构收敛类 task，
# validator 会拒绝空 quality_outcome 字段和空列表。
# new-task 写入的模板只是起点，lead 必须让它匹配当前 source contract。
test_environment:
  required: false
  environment: ""
  test_tab_or_pane: ""
  server_owner: ""
  browser_owner: ""
  cleanup_hook: ""
  artifact_cleanup: ""
  duration_budget: ""
  resource_budget: ""
quality_measurement:
  required: false
  baseline_required: false
  after_required: false
  metrics: []
  waiver_policy: ""

# target_role=tester 或 task_type 包含 test 时，test_environment.required 必须为 true。
# performance / UX / workflow / quality / eval / measurement 类 task
# 会要求 quality_measurement，并在 passing test evidence 中检查 baseline/after 或 waiver。
design_lifecycle:
  enabled: false
  phases:
    - drafting
    - review_requested
    - changes_requested
    - user_confirmed
    - coding_ready
  current_phase: ""
  user_confirmation_required: true
  coding_requires_confirmed_design: true
design_reference:
  required_for_coding: false
  artifact: ""
  confirmation_evidence: ""
  status: not_applicable
implementation_plan:
  required: false
  path: ""
  summary: ""
decomposition:
  parent_task: ""
  child_slices: []
  aggregate_outcome_metrics: []
  stop_conditions: []
  replanning_path: ""
final_aggregate_audit:
  required: false
  checks: []
delivery_plan:
  mode: sliced
  slices:
    - id: S1
      goal: "本 slice 要交付的最小真实能力。"
      scope:
        include:
          - "本 slice 覆盖的文件、入口或用户路径。"
        exclude:
          - "本 slice 明确不处理的后续能力。"
      checkpoint:
        - "本 slice 完成后必须检查的事实。"
      acceptance:
        - "本 slice 自己的通过条件。"
      evidence:
        - "本 slice PASS 前必须留下的证据。"
acceptance:
  - "本轮任务的可验证验收项。"
review_strategy:
  entrypoints:
    - "需要验证的入口、命令或用户流程。"
  suggested_checks:
    - "静态检查、单测、CLI 检查或聚焦检查。"
  runtime_checks:
    - "真实运行、浏览器、服务、TUI、App 或端到端检查。"
  required_capabilities:
    - "review/test 需要发现或加载的能力，例如 browser smoke testing。"
  failure_modes:
    - "reviewer/tester 必须反驳的具体失败假设。"
evidence_requirements:
  - "PASS 前必须存在的命令、artifact、截图、日志、diff 或 report。"
worktree_safety:
  require_status_check: true
  before_public_action:
    - "git status --short --branch -uall"
    - "git rev-parse HEAD"
release_surface:
  required_when_applicable:
    - "version fields"
    - "generated artifacts"
    - "package/archive contents"
    - "release assets or registry/appcast state"
supply_chain:
  third_party_tools:
    - name: "skill/plugin/MCP/hook/install script"
      source: "repo/tag/commit 或 local path。"
      pinned: true
tool_requirements:
  service_controlled:
    - "提交 review/test 结论必须写入 evidence manifest。"
    - "推进 loop state 必须通过受控工具或 lead 写入。"
  agent_discoverable:
    - "只读 diagnostics 可由 agent 自主调用。"
must_answer:
  - "quality outcome 是否已经满足？"
  - "acceptance 是否逐条有证据？"
  - "required capabilities 是否已满足或明确 BLOCKED？"
  - "failure modes 是否已被证据反驳？"
  - "是否存在 High / Medium 问题？"
final_audit:
  required: true
  checks:
    - "source contract 和 traceability 是否逐条有证据。"
    - "旧路径、旧 fallback、旧 writer 是否关闭。"
    - "真实 E2E / dogfood 是否已跑；未跑时 residual risk 是否明确。"
```

lead 发送给 reviewer/tester 时，只发送路径：

```text
请读取 /tmp/orbit-task-review-001.yaml 并执行。完成后把结论写入 evidence。
```

`delivery_plan` 用来表达大任务的分片交付。小任务可以省略；一旦任务跨多个模块、多个角色或多个用户路径，就应拆 slice。slice 是协作边界，不是普通 checklist：当前 slice 没有通过 review/test gate 时，不应推进下一个 slice。

`design_lifecycle` 是 design/analysis task 的状态机字段。CLI 会要求 design task 包含 `drafting -> review_requested -> changes_requested|user_confirmed -> coding_ready`，并在进入 `user_confirmed` 或 `coding_ready` 前检查结构化 review pass 和用户确认证据。

`design_reference` 是 coding task 的边界字段。`task_type` 包含 `coding` 时，CLI 会要求它引用已确认设计 artifact、confirmation evidence，并标记 `status: confirmed`；否则 coding task 不应 validate 通过。

`implementation_plan`、`decomposition` 和 `final_aggregate_audit` 是 parent/decomposition task 的整体收口字段。child slice 的局部 pass 不等于 parent 完成；parent final audit 必须检查 aggregate outcome metrics 和 child slice 覆盖关系。

## Evidence Manifest

review/test/command 结果都写 manifest。manifest 是事实记录，不替代判断。

```json
{
  "schema_version": "orbit-evidence-v1",
  "project": "example-project",
  "role": "reviewer",
  "role_resolution": {
    "resolved_role": "reviewer",
    "resolver": "orbit whoami --json",
    "whoami_result_file": "/tmp/orbit-whoami-reviewer-main.json",
    "role_sources": {
      "env.ORBIT_INSTANCE": "reviewer-main",
      "env.ORBIT_ROLE": "reviewer",
      "project_config.instances.reviewer-main.role_ref": "reviewer-main",
      "project_config.roles.reviewer-main.role": "reviewer",
      "task_file.target_role": "reviewer"
    },
    "role_source_mode": "persistent_identity_confirmed",
    "conflict": null
  },
  "task_type": "implementation_review",
  "task_file": "/tmp/orbit-task-review-001.yaml",
  "result_file": "/tmp/orbit-result-review-001.md",
  "transport": {
    "type": "example-transport",
    "workspace_id": "workspace-123",
    "tab_label": "reviewer-main",
    "session_id": "session-456",
    "managed_by": "orbit adapter"
  },
  "started_at": "2026-06-08T12:00:00+08:00",
  "completed_at": "2026-06-08T12:08:00+08:00",
  "records": [
    {
      "kind": "review",
      "status": "pass",
      "summary": "Structured reviewer verdict passed.",
      "created_at": "2026-06-08T12:08:00+08:00",
      "structured_submit": true,
      "source_message_id": "herdr:reviewer-main:msg-123",
      "findings": [],
      "coverage": ["quality outcome and gate behavior"],
      "artifacts": ["/tmp/orbit-result-review-001.md"]
    }
  ],
  "waivers": [],
  "verdict": {
    "status": "pass",
    "mode": "aggregate",
    "summary": "Aggregate evidence verdict: pass (review=pass).",
    "gates": {
      "review": {
        "status": "pass",
        "summary": "Structured reviewer verdict passed.",
        "created_at": "2026-06-08T12:08:00+08:00",
        "structured": true,
        "source_message_id": "herdr:reviewer-main:msg-123"
      }
    },
    "waivers": {
      "total": 0,
      "open": 0
    }
  },
  "residual_risk": [
    "当前 task 未执行完整端到端验证。"
  ],
  "worktree_safety": {
    "status_before": "git status --short --branch -uall output path or summary",
    "head_before": "commit hash",
    "status_after": "git status --short --branch -uall output path or summary",
    "head_after": "commit hash",
    "unexpected_changes": []
  },
  "regression_guard": {
    "status": "present",
    "evidence": "test/checker/fixture/assertion/verifier path"
  },
  "release_surface": {
    "status": "not_applicable",
    "checked": [],
    "gaps": []
  },
  "rule_resolution": {
    "resolver": "orbit rules resolve --json",
    "file": "/tmp/orbit-rule-resolution-review-001.json",
    "valid": true,
    "resolved_role": "reviewer",
    "conflict_count": 0,
    "missing_project_rule_files": []
  },
  "tool_calls": [
    {
      "tool_name": "orbit validate",
      "input_identity": "/tmp/orbit-task-review-001.yaml + /tmp/orbit-evidence.json",
      "input_hash": "optional-sha256",
      "status": "passed",
      "artifact_path": "/tmp/orbit-validate.json",
      "invoked_at": "2026-06-08T12:07:00+08:00",
      "caller": "lead",
      "used_for": "gate validation"
    }
  ]
}
```

`verdict` 是 aggregate summary，不是最新 record 的别名。review/test gate 只认带结构化字段且 identity 匹配对应角色的 review/test record：review 需要 resolved role `reviewer`，test 需要 resolved role `tester`。无关 command pass 或身份不匹配的 review/test pass 不能覆盖仍然 fail/partial 的 review/test 结论。`orbit evidence submit` 是推荐入口，report 至少包含 `kind`、`verdict`、`summary`、`source_message_id`、`findings`、`coverage` 和 `artifacts`；这三个列表字段必须是字符串列表。reviewer/tester 必须写独立 report 并用 CLI submit；不要直接编辑 `.orbit/evidence*.json`，因为手写 record 不会产生可信 identity，也不会走 schema 校验和并发安全写入。

`verdict: blocked` 会规范化为 partial evidence record，并通过 `blocked.reason`、`blocked.next_step`、`blocked.owner` 保留阻塞细节。`wait-gate` 和 `handoff` 输出 `gate_summary`，用于暴露 required gate 的 ready 状态、identity mismatch、blocked/partial/fail 等阻塞原因。

passing `kind: test` record 如果用于 tester/test task，还必须包含 `test_environment` mapping，记录 environment、test_tab_or_pane、server_owner、browser_owner、cleanup_hook、artifact_cleanup、duration、resource_usage、cleanup_status、ux_quality 和 artifact_quality。质量度量类 task 的 passing test record 还必须包含 `quality_measurement`：baseline、after 和 metrics，或 waiver.reason、waiver.risk、waiver.replacement_evidence。

waiver 使用独立结构，而不是普通 summary 字符串。每条 waiver 至少包含 `owner`、`scope`、`reason`、`risk`、`replacement_evidence`、`expiry` 和 `revoked_by_user_requirement`。waiver 会进入 aggregate verdict 的 risk summary，但不会自动关闭 required review/test gate。

关键工具调用本身也是 evidence。对 preflight、schema validation、context pack、提交 review/test verdict、推进 loop state、写权威 artifact、handoff、transport delivery/result collection 这类关键动作，manifest 应能区分：

- `not_applicable`：本轮不需要。
- `available_not_invoked`：可用但没有调用，必须说明原因。
- `passed` / `warning` / `blocked` / `failed`：真实调用结果。

工具调用记录至少包含 tool name、input identity 或 hash、status、artifact path、invoked_at、caller 和 used_for。CLI 可用不等于 agent 可靠调用；没有工具调用证据时，reviewer 不能默认关键动作已经发生。

## Loop State

loop 不能依赖聊天历史作为唯一记忆。每个长任务都应有外部状态文件：

```yaml
schema_version: orbit-loop-state-v1
objective: "降低 legacy_orchestrator.py 维护复杂度"
phase: contract|execute|review|test|done|blocked
budget:
  max_turns: 12
  max_wall_minutes: 180
  max_review_rounds: 3
  max_test_rounds: 2
quality_outcome_ref: "/tmp/orbit-task-001.yaml#quality_outcome"
artifacts:
  task_file: "/tmp/orbit-task-001.yaml"
  evidence_files: []
  handoff_file: "/tmp/orbit-handoff-001.md"
decision_log:
  - at: "2026-06-08T12:00:00+08:00"
    decision: "start"
    reason: "task accepted"
```

状态文件必须由 lead 或工具写入，reviewer/tester 只追加结果，不直接改完成状态。

## Loop 类型

| 类型 | 触发条件 | 适用场景 | 停止条件 | 风险 |
| --- | --- | --- | --- | --- |
| scheduled loop | 时间间隔 | CI/部署/PR 评论轮询 | 到期、取消、条件满足 | token 成本和空转 |
| goal loop | 上一轮结束后评估未达成 | 有明确可验证终态的开发任务 | evaluator 判定满足目标 | evaluator 只能看已暴露证据 |
| event routine | 外部事件 | CI 失败、告警、issue 创建 | 单次任务完成 | 幂等、权限、重复触发 |
| harness loop | 状态文件驱动 | 多 sprint、多 agent、长任务 | contract 全部通过或预算耗尽 | 状态机复杂、调试困难 |

多 agent review/test 协作更接近 harness loop，而不是简单 scheduled loop。

## Stop / Escalation

每个 task 必须声明停止条件：

```yaml
stop_policy:
  done_when:
    - quality_outcome_satisfied
    - reviewer_no_high_or_medium
    - required_tests_passed_or_waived
  escalate_when:
    - role_conflict
    - missing_operating_model_for_reviewer_or_tester
    - same_failure_repeated_3_times
    - budget_exceeded
  default_fail_if:
    - no_evidence_manifest
    - no_quality_outcome_for_improvement_task
    - review_or_test_verdict_unclear
```

如果没有明确 PASS，状态保持未完成。

## Budget Gate

budget 不只是 token 限制，也包括轮次和时间：

```yaml
budget:
  max_turns: 12
  max_review_rounds: 3
  max_test_rounds: 2
  max_wall_minutes: 180
  max_context_tokens_per_agent: 180000
```

超过预算不等于成功，也不等于失败；应进入 `blocked` 或 `escalate`，并说明剩余工作。

## Fresh-Context Evaluator

适合在这些节点引入 fresh-context evaluator：

- contract 写完后：评估 goal 是否可验证。
- review 前：评估 task/evidence 是否足够。
- test 失败修复后：评估修复是否引入绕过或降级。
- Final Audit 前：评估 plan 状态和 evidence 是否闭合。

evaluator 的输入应是 task file、diff、evidence manifest 和必要源码摘要，而不是整个聊天历史。

## Skill Bootstrap

启动检查顺序：

1. 查找 `.orbit/roles.yaml`。
2. 查找 `.orbit/instances.yaml`。
3. 查找 `docs/operating-model.md`。
4. 如果存在，优先通过 `orbit whoami --json` 读取机器配置并解析身份。
5. 如果不存在，判断当前 role 和用户意图。

缺失 project config 时：

| role / 场景 | 行为 |
| --- | --- |
| lead | 可以创建默认 `.orbit/roles.yaml` 和 `.orbit/instances.yaml` 模板，并提示用户确认需要补哪些项目字段 |
| reviewer | 不应擅自初始化；报告缺少 project config，要求 lead 或用户初始化 |
| tester | 不应擅自初始化；报告缺少 project config，避免在无规则下测试 |
| 用户明确说“初始化 Orbit” | 可以执行初始化 |

skill 内应包含：

- 通用 role 定义。
- task/evidence/loop-state schema 摘要。
- 初始化模板。
- operating model 发现和读取顺序。
- role resolution 规则。
- default-fail / quality outcome 原则。

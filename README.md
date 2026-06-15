# Orbit

Orbit 是给 AI agent 用的任务闭环工具。它把一次中等复杂的 AI 开发任务拆成可检查的几个事实：目标是什么、谁负责实现、谁负责 review、谁负责测试、证据在哪里、当前状态能不能交接。

最典型的用法是在 Herdr、tmux 或多个终端里同时跑几个 agent：一个 lead 负责拆任务和收口，一个 coder 负责实现，一个 reviewer 负责独立评审，一个 tester 负责真实测试。它们可以是不同工具，比如 Codex + Claude Code + OpenCode；也可以全是 OpenCode，只是用不同 role 执行不同职责。

Orbit 解决的不是“让 AI 更会写代码”，而是解决这些更常见的问题：

- 用户只说“改一下”，agent 自己猜目标，最后方向跑偏。
- agent 说“完成了”，但没有 task、review、test、命令输出或交接证据。
- 一个 agent 自己实现、自评、自测，review/test 变成口头承诺。
- 长任务跨 pane、跨 agent 或跨天后，只能靠聊天记录猜现在做到哪里。

Orbit 不阻止用户改文件，也不替代 reviewer/tester 的判断。它只提供一套机器可读的协作骨架，让 agent 的身份、任务、证据、状态和交接可以被检查。

## 适合场景

适合用 Orbit：

- 让 AI 实现一个中等复杂功能，需要 review 和真实测试。
- 多个 agent 分工：lead / coder / reviewer / tester。
- 长任务需要中途暂停、换 agent、换 pane 或交接给下一轮。
- 你希望 agent 不只说“做完了”，而是留下 task、evidence、audit 和 handoff。

不适合用 Orbit：

- 简单问答。
- 一行小修。
- 你还在和 agent 结对澄清需求，目标没有定下来。
- 只想临时跑一个命令，不需要 review/test/handoff。

需求还不清楚时，Orbit 只应该作为思考框架，不应该急着创建 task 或推进状态。等目标、边界和验收标准清楚后，再进入正式闭环。

## 30 秒理解

想象你在 Herdr 里开了 4 个 pane：

```text
pane 1: lead-agent      负责理解用户目标、写 task、派工、判断 gate
pane 2: coder-agent     负责实现代码、记录实现证据
pane 3: reviewer-agent  负责独立 review，不替 coder 背书
pane 4: tester-agent    负责跑真实路径，不只跑 build
```

这 4 个 pane 可以这样组合：

```text
Codex 做 lead + OpenCode 做 coder + Claude Code 做 reviewer + OpenCode 做 tester
```

也可以是：

```text
4 个 OpenCode pane，分别用 ORBIT_INSTANCE=lead/coder/reviewer/tester 区分身份
```

Orbit 给这几个 agent 一个共同的工作台：

```text
用户目标
  -> task contract: 这次到底要交付什么
  -> implementation evidence: 实现做了什么、跑了什么命令
  -> review evidence: reviewer 是否放行，有没有高/中风险
  -> test evidence: tester 是否跑了真实路径
  -> validate/audit: task、evidence、state 是否一致
  -> handoff: 下一位 agent 或用户如何接手
```

核心文件都在目标项目的 `.orbit/` 目录里。无论 agent 是 Codex、Claude Code、OpenCode，还是别的工具，只要它能读写项目文件、运行 `orbit` CLI，就能按同一套 task/evidence/state 协作：

```text
.orbit/
├── roles.yaml
├── instances.yaml
├── loop-state.yaml
├── tasks/
├── evidence/
├── rules/
└── handoff/
```

## 安装

安装 agent skill：

```bash
npx skills add https://github.com/godokyang/orbit -g
```

`skills` CLI 会根据你的环境处理安装目标。如果输出里出现 `PromptScript does not support global skill installation`，但同时显示 `~/.agents/skills/orbit` 已安装成功，可以忽略；这是 PromptScript 不支持全局 skill 安装，不代表 Orbit 安装失败。

如果遇到 GitHub rate limit，按 `skills` CLI 提示使用 `gh login`，或设置 `GITHUB_TOKEN`，或改用它提示的 `--full-depth`。

安装 `orbit` CLI：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
orbit version
```

也可以先 clone 仓库，再从本地安装：

```bash
git clone git@github.com:godokyang/orbit.git
cd orbit
sh install.sh
orbit version
```

更新 CLI：

```bash
git pull
sh install.sh
```

卸载 CLI：

```bash
sh uninstall.sh
```

## 快速开始

进入你要让 AI 工作的项目：

```bash
cd /path/to/your-project
orbit init
```

初始化会生成：

```text
.orbit/
├── roles.yaml
├── instances.yaml
└── loop-state.yaml
```

创建一个实现任务：

```bash
mkdir -p .orbit/tasks .orbit/evidence .orbit/rules .orbit/handoff

orbit new-task \
  --target-role lead \
  --task-type implementation \
  --output .orbit/tasks/current-task.yaml
```

打开 `.orbit/tasks/current-task.yaml`，把这几项补清楚：

- 真实目标：用户到底要什么结果。
- 非目标：这轮明确不做什么。
- scope：允许改哪些范围。
- acceptance：怎样才算通过。
- quality outcome：项目质量要变好在哪里。
- evidence requirements：需要留下哪些证据。

不要把“优化一下”“修一下”“做完整一点”这种模糊目标直接交给 agent。先把它压成可验证的 task contract。

## 一个真实例子

假设你在 Herdr 里让 AI 给一个资料管理 Web 应用新增“标签筛选 + 导入去重 + 移动端可用操作按钮”。这不是一个一行小修：它涉及 UI、数据导入、移动端交互、回归测试和 review。

不用 Orbit 时，agent 可能会这样结束：

```text
已完成，已优化导入和移动端体验。
```

你很难判断它到底改了什么、有没有 review、有没有真实操作过页面、有没有残留风险。

用 Orbit 时，用户只需要把目标交给 lead-agent。lead-agent 负责把目标写成 contract，不应该把“优化一下体验”直接派给 coder：

```yaml
target_role: lead
task_type: implementation
scope:
  - materials import flow
  - tag filter interaction
  - mobile action buttons
quality_outcome:
  required: true
  statement: "用户可以可靠导入资料、筛选标签，并在移动端完成核心操作。"
acceptance:
  - duplicate imports do not create duplicate records
  - active tag filter is visible and clearable
  - mobile action buttons have usable accessible names
evidence_requirements:
  - implementation evidence
  - independent review verdict
  - real browser test verdict
```

接下来是这样的真实协作：

```text
lead-agent:
  - 运行 orbit rules resolve / print-context，确认本轮默认规则和项目规则
  - 创建 .orbit/tasks/current-task.yaml
  - 把实现任务派给 coder-agent

coder-agent:
  - 读取 task contract
  - 实现功能
  - 运行类型检查、构建或单元测试
  - 写入 implementation evidence
  - 明确 changed files、verification 和 known gaps

reviewer-agent:
  - 只按 task contract、diff、quality outcome 和证据做独立 review
  - 如果有 high/medium 问题，输出 CHANGES_REQUESTED
  - 没有阻断问题才输出 APPROVED

tester-agent:
  - 启动应用，真实操作标签筛选、导入去重、移动端按钮
  - 保留测试步骤、环境、截图或日志
  - 输出 PASS / FAIL / PARTIAL

lead-agent:
  - 如果 review 或 test 没过，把修复任务派回 coder
  - 如果都过，运行 orbit validate / audit / handoff
  - 给用户一份可以复核的交接结果，而不是一句“完成了”
```

这里 Herdr 只负责开 pane、传消息和承载多 agent 协作；Orbit 负责让每个 pane 的身份、任务、证据、状态和 gate 可审计。换成 tmux、CI job 或手动开多个终端也一样，Orbit 不绑定 Herdr。

### 不同 agent 混跑

你可以让不同 agent 做它们更擅长的部分：

```text
lead-agent: Codex
coder-agent: OpenCode
reviewer-agent: Claude Code
tester-agent: OpenCode
```

Orbit 不关心这些工具谁更强，也不假设某个工具天然可信。它只要求每个 role 留下自己该留的证据：coder 不能替 reviewer 放行，reviewer 不能替 tester 宣称真实测试通过，tester 不能修改生产代码来让测试过。

### 同一种 agent 多开

如果你只想用一种工具，也可以开三个或四个同类进程：

```text
ORBIT_INSTANCE=lead     opencode
ORBIT_INSTANCE=coder    opencode
ORBIT_INSTANCE=reviewer opencode
ORBIT_INSTANCE=tester   opencode
```

这些进程看起来都是 OpenCode，但 Orbit 会通过 `.orbit/instances.yaml` 和环境变量把它们解析成不同 role。这样 review/test 仍然是独立职责，而不是同一个 agent 在聊天里自说自话。

## 记录证据

初始化 evidence manifest：

```bash
orbit evidence init --output .orbit/evidence/current-evidence.json
```

记录实现证据：

```bash
orbit evidence add \
  --file .orbit/evidence/current-evidence.json \
  --kind implementation \
  --status pass \
  --summary "implementation completed"
```

记录命令证据：

```bash
orbit evidence add \
  --file .orbit/evidence/current-evidence.json \
  --kind command \
  --status pass \
  --summary "npm test passed"
```

记录 review verdict：

```bash
ORBIT_INSTANCE=reviewer orbit evidence submit \
  --file .orbit/evidence/current-evidence.json \
  --report .orbit/evidence/review-report.yaml \
  --json
```

review report 必须包含 `quality_outcome_verdict`。High/Medium finding 需要写成结构化 mapping，包含 symptom、source、consequence 和 remedy。design/analysis review 可从 `assets/templates/design-review-report.yaml` 复制模板。

记录 test verdict：

```bash
ORBIT_INSTANCE=tester orbit evidence submit \
  --file .orbit/evidence/current-evidence.json \
  --report .orbit/evidence/test-report.yaml \
  --json
```

test PASS report 必须包含与 task contract 一致的 `test_level`，并记录 `test_environment` 生命周期字段。只跑 repo regression 不能声称 browser/provider E2E 或 dogfood 通过。

也可以把历史 reviewer/tester 报告导入 evidence：

```bash
orbit evidence from-report \
  --file .orbit/evidence/current-evidence.json \
  --report .orbit/evidence/review-report.md \
  --kind review \
  --json
```

`from-report` 只接受明确 verdict/status，例如 `APPROVED`、`PASS`、`CHANGES_REQUESTED`、`FAIL`、`BLOCKED`、`PARTIAL`。`APPROVED_WITH_NOTES` 不会自动当成通过。

## 推进状态

开始任务：

```bash
ORBIT_INSTANCE=lead orbit state start --task .orbit/tasks/current-task.yaml
```

长任务中记录阶段心跳：

```bash
orbit state progress \
  --message "implementation complete, waiting for review gate" \
  --evidence .orbit/evidence/current-evidence.json
```

进入 review 或 test 阶段：

```bash
orbit state transition --to in_review --evidence .orbit/evidence/current-evidence.json
orbit state transition --to in_test --evidence .orbit/evidence/current-evidence.json
```

检查 required gates 是否 ready：

```bash
orbit wait-gate \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --json
```

`wait-gate` 只检查结构化 evidence 中最新的 required gate 记录。它不能替代 reviewer/tester 的判断。

## 完成和交接

完成前先校验：

```bash
orbit validate \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --state .orbit/loop-state.yaml \
  --json
```

通过后进入 done：

```bash
orbit state transition --to done --evidence .orbit/evidence/current-evidence.json
```

交接或关闭前做 audit：

```bash
orbit audit \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --state .orbit/loop-state.yaml \
  --json
```

生成 handoff：

```bash
orbit handoff \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --state .orbit/loop-state.yaml \
  --output .orbit/handoff/current-handoff.json \
  --record-state \
  --json
```

## 角色和规则

默认角色是：

- `lead`：澄清目标、创建 task、推进状态、判断 gate。
- `reviewer`：独立 review，不替代 tester。
- `tester`：跑真实测试，不临时改生产代码。

常见需要改的是 `.orbit/roles.yaml`：

```yaml
roles:
  lead:
    role: lead
    rules:
      - docs/implementation-rule.md
    permissions:
      can_edit_production_code: true

  reviewer:
    role: reviewer
    rules:
      - docs/review-rule.md
    permissions:
      can_edit_production_code: false

  tester:
    role: tester
    rules:
      - docs/test-rule.md
    permissions:
      can_edit_production_code: false
```

项目自己的 review 规则、测试规则、禁止事项放在项目文档里，再从 `.orbit/roles.yaml` 引用。项目规则是叠加层，不会替代 Orbit 默认规则。

配置 `.orbit/instances.yaml`，把运行时身份映射到角色：

```yaml
instances:
  lead:
    role_ref: lead
    command: codex
    env:
      ORBIT_INSTANCE: lead
      ORBIT_ROLE: lead

  reviewer:
    role_ref: reviewer
    command: codex
    env:
      ORBIT_INSTANCE: reviewer
      ORBIT_ROLE: reviewer

  tester:
    role_ref: tester
    command: codex
    env:
      ORBIT_INSTANCE: tester
      ORBIT_ROLE: tester
```

检查当前身份：

```bash
ORBIT_INSTANCE=reviewer orbit whoami --json
```

生成本轮规则解析结果：

```bash
ORBIT_INSTANCE=lead orbit rules resolve \
  --task .orbit/tasks/current-task.yaml \
  --output .orbit/rules/current-resolution.json \
  --json
```

生成本轮 agent 读取清单：

```bash
ORBIT_INSTANCE=lead orbit rules print-context \
  --task .orbit/tasks/current-task.yaml \
  --output .orbit/rules/current-context.json \
  --json
```

`rules resolve` 是可审计的规则来源结果；`rules print-context` 是本轮 agent 应读取的上下文清单。CLI 不调用大模型，也不自动改写用户规则文件。

## 启动和派单

预览或启动配置好的 agent instance：

```bash
orbit start reviewer --dry-run --json
orbit start reviewer --transport herdr --dry-run --json
```

如果需要把 task 派给另一个 agent instance：

```bash
orbit dispatch --task .orbit/tasks/current-task.yaml --to reviewer --json
orbit dispatch --task .orbit/tasks/current-task.yaml --to reviewer --transport herdr --pane <pane-id> --json
```

`dispatch` 只是 transport adapter，不改变 task/evidence/state 的权威语义。真实 gate 仍以 reviewer/tester 写入的 evidence 和后续 `validate/audit` 为准。

当 reviewer/tester 这类 `user_managed` instance 已经有 healthy binding 时，Orbit 必须优先复用现有 pane。只有用户明确允许创建缺失 instance（例如 `--allow-create`）时，Herdr adapter 才会准备新 role；此时应尽量在 lead 当前同级视图创建，优先沿用当前 tab / workspace 元数据，缺失时在 start plan 中暴露 fallback。新建 role 还必须显式准备权限或 approval mode；Orbit 可以记录这项 requirement，但不能静默绕过用户授权或客户端审批。

真实 Herdr 协调时，lead 不应把 `agent-status done` 当作 reviewer/tester gate。agent 可能已提交结构化 evidence，但在回复 lead、审批 prompt 或 UI 状态上停住。收口时以 `.orbit/evidence*`、`orbit wait-gate --task ... --evidence ... --json`、`orbit validate` 和 `orbit audit` 为准；Herdr status 只作为 transport 诊断信号。需要投递给特定 pane 时，优先使用明确的 `reply-to`，避免把长报告发到普通 shell/root pane。

## 不能直接说完成的情况

- 没有 task contract。
- 改善类任务没有 quality outcome。
- 没有 evidence manifest。
- review/test verdict 是 `fail`、`partial` 或 `invalid`。
- implementation task 声明了 review/test gate，但最新 gate evidence 不是 `pass`。
- task、evidence、loop state 引用不一致。
- 当前 agent 身份和 task `target_role` 冲突，且当前 agent 不在 task `gates.roles` 中。

用户可以接受风险，但 agent 必须把风险说清楚。Orbit 的目标不是替用户做决定，而是让多 agent 协作里的身份、目标、证据、状态和交接变得可检查。

## 继续阅读

- 运行时细则：[references/runtime/guide.md](references/runtime/guide.md)
- 协议字段说明：[references/runtime/core-operating-model.md](references/runtime/core-operating-model.md)
- coding 规范：[references/runtime/coding-guideline.md](references/runtime/coding-guideline.md)
- testing 规范：[references/runtime/testing-guideline.md](references/runtime/testing-guideline.md)

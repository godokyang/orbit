# Orbit

Orbit 是给 AI agent 用的任务闭环工具。它不负责“让 AI 更会写代码”，而是把一次开发任务拆成可检查的事实：

- 这次到底要交付什么。
- 哪个 agent 负责实现、review、测试和收口。
- review/test 是否真的独立发生。
- 证据、状态和交接文件在哪里。
- 当前结果是否可以继续实现、进入下一阶段或交给别人接手。

Orbit 可以配合 Herdr、tmux、CI 或多个普通终端使用。Herdr 只是常见的多 agent 承载方式；Orbit 的核心是 `.orbit/` 里的 task、evidence、state 和 handoff。

## 什么时候用

适合用 Orbit：

- 中等复杂或更大的 AI 开发任务。
- 需要 coder、reviewer、tester 分工的任务。
- 长任务需要暂停、换 agent、换 pane 或跨天接手。
- 你不想只听 agent 说“完成了”，而是要看到 task、review、test、audit 和 handoff。

不适合用 Orbit：

- 简单问答。
- 一行小修。
- 还在澄清需求，目标和验收标准没定下来。
- 只是临时跑一个命令，不需要 review/test/handoff。

需求不清楚时，先澄清需求；不要急着创建 task 或推进状态。

## 核心流程

Orbit 的一轮任务通常长这样：

```text
用户目标
  -> task contract：目标、边界、验收标准
  -> implementation evidence：实现改了什么、跑了什么
  -> review evidence：独立 review 是否放行
  -> test evidence：真实测试是否通过
  -> validate / audit：task、evidence、state 是否一致
  -> handoff：交给用户或下一位 agent 的收口包
```

典型角色：

```text
lead      负责澄清目标、创建 task、派工、判断 gate、收口
coder     负责实现代码并记录实现证据
reviewer 负责独立 review，不替 tester 宣称测试通过
tester   负责真实测试，不临时改生产代码来让测试通过
```

这些角色可以由不同工具承担，例如 Codex + Claude Code + OpenCode；也可以多开同一种 agent，用不同的 `ORBIT_INSTANCE` 区分身份。

## 安装

### 1. 安装 Herdr（可选但推荐）

如果你要跑多个 agent，推荐先安装 Herdr：

```bash
curl -fsSL https://herdr.dev/install.sh | sh
herdr --version
```

也可以用 Homebrew：

```bash
brew install herdr
```

启动 Herdr：

```bash
cd /path/to/your-project
herdr
```

Herdr 会打开或连接到一个持久会话。你可以在里面开多个 pane，分别运行 Codex、Claude Code、OpenCode 或其它 agent。

常用 Herdr 操作：

```text
ctrl+b 然后 v       左右分屏
ctrl+b 然后 -       上下分屏
ctrl+b 然后 c       新建 tab
ctrl+b 然后 q       detach，agent 继续运行
herdr               重新进入会话
```

如果你希望 Herdr 更准确识别 agent 状态，可以安装对应集成：

```bash
herdr integration install codex
herdr integration install claude
herdr integration install opencode
```

Herdr 不是 Orbit 的必需依赖。你也可以用 tmux、CI job 或手动开多个终端。

### 2. 安装 Orbit skill

让支持 agent skill 的工具认识 Orbit：

```bash
npx skills add https://github.com/godokyang/orbit -g
```

如果输出里出现 `PromptScript does not support global skill installation`，但同时显示 `~/.agents/skills/orbit` 已安装成功，可以忽略；这是 PromptScript 不支持全局 skill 安装，不代表 Orbit 安装失败。

如果遇到 GitHub rate limit，按 `skills` CLI 提示使用 `gh login`、设置 `GITHUB_TOKEN`，或改用它提示的 `--full-depth`。

### 3. 安装 Orbit CLI

远程安装：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
orbit version
```

本地安装：

```bash
git clone git@github.com:godokyang/orbit.git
cd orbit
sh install.sh
orbit version
```

更新和卸载：

```bash
sh install.sh
sh uninstall.sh
```

Orbit CLI 需要 Ruby。远程安装还需要 `curl` 或 `wget`。

## 快速开始

用户只需要做四件事：

1. 进入项目并初始化 Orbit。
2. 配置并启动 lead agent。
3. 把真实需求交给 lead agent。
4. 在 agent 给出 task contract 后，确认目标、边界和验收标准是否正确。

### 用户操作

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

然后配置 agent 命令。打开 `.orbit/instances.yaml`，把 `instances.lead.command` 改成你要用的 agent：

```yaml
instances:
  lead:
    role_ref: lead
    command: codex
    env:
      ORBIT_INSTANCE: lead
      ORBIT_ROLE: lead
```

常见写法：

```yaml
command: codex
command: claude
command: opencode
```

第一次启动 lead agent 时允许 Orbit 创建缺失的 instance：

```bash
orbit start lead --allow-create
```

后续这个 instance 已经存在时，直接启动：

```bash
orbit start lead
```

然后把需求交给 lead agent。可以直接这样说：

```text
请按 Orbit 流程执行这个任务：

目标：<写清楚你想要的结果>
范围：<哪些模块/页面/文件可以改，不确定可以让 agent 判断>
验收：<你会怎样判断它做对了>
限制：<这轮明确不要做什么>
```

如果你还没想清楚，也可以让 lead agent 先帮你澄清：

```text
请先按 Orbit 的方式帮我澄清这个需求，先不要开始实现：

<描述你的想法>
```

用户不需要手工填写 `.orbit/tasks/current-task.yaml`。lead agent 应该自己创建和补全 task contract，然后把关键内容展示给用户确认。你只需要重点看这些内容是否正确：

- 目标有没有被误解。
- 哪些范围会改，哪些范围不会改。
- 验收标准是否能判断成败。
- 是否需要独立 review 和真实测试。
- 有哪些风险、假设或需要你确认的点。

不要把“优化一下”“修一下”“做完整一点”直接交给 coder。lead agent 应先把用户表达压成可验证的 task contract；如果目标、边界或验收标准不清楚，先追问用户，再进入实现。

### Agent 动作参考

下面这些命令通常由 lead agent、reviewer 或 tester 执行。普通用户读完“用户操作”就可以开始使用；这一节主要给 agent、维护者和排障时参考。

创建 task：

```bash
mkdir -p .orbit/tasks .orbit/evidence .orbit/rules .orbit/handoff

orbit new-task \
  --target-role lead \
  --task-type implementation \
  --output .orbit/tasks/current-task.yaml
```

初始化 evidence：

```bash
orbit evidence init --output .orbit/evidence/current-evidence.json
```

开始任务：

```bash
ORBIT_INSTANCE=lead orbit state start --task .orbit/tasks/current-task.yaml
```

实现完成后记录实现证据：

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

reviewer 和 tester 需要提交结构化 report：

```bash
ORBIT_INSTANCE=reviewer orbit evidence submit \
  --file .orbit/evidence/current-evidence.json \
  --report .orbit/reports/review-report.yaml \
  --task .orbit/tasks/current-task.yaml \
  --json

ORBIT_INSTANCE=tester orbit evidence submit \
  --file .orbit/evidence/current-evidence.json \
  --report .orbit/reports/test-report.yaml \
  --task .orbit/tasks/current-task.yaml \
  --json
```

报告模板在：

```text
assets/templates/review-report.yaml
assets/templates/test-report.yaml
assets/templates/design-review-report.yaml
```

最后检查 gate、校验、审计并生成 handoff：

```bash
orbit wait-gate \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --json

orbit validate \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --state .orbit/loop-state.yaml \
  --json

orbit audit \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --state .orbit/loop-state.yaml \
  --json

orbit handoff \
  --task .orbit/tasks/current-task.yaml \
  --evidence .orbit/evidence/current-evidence.json \
  --state .orbit/loop-state.yaml \
  --output .orbit/handoff/current-handoff.json \
  --record-state \
  --json
```

如果 `wait-gate`、`validate` 或 `audit` 没过，不要直接说完成。先修复 task、evidence、state 或实际代码问题。

## 在 Herdr 里跑多 agent

一个常见布局：

```text
pane 1: lead-agent      Codex
pane 2: coder-agent     OpenCode
pane 3: reviewer-agent  Claude Code
pane 4: tester-agent    OpenCode
```

可以手动在每个 pane 里启动 agent，也可以让 Orbit 生成启动计划：

```bash
orbit start lead --transport herdr --allow-create
orbit start reviewer --transport herdr --dry-run --json
orbit start tester --transport herdr --dry-run --json
```

先在 `.orbit/instances.yaml` 里给每个 instance 配好 `command`，例如 `codex`、`claude` 或 `opencode`。第一次启动某个缺失 instance 时使用 `--allow-create`；后续已有健康 binding 时，直接运行 `orbit start lead --transport herdr`、`orbit start reviewer --transport herdr` 即可复用。

如果 `.orbit/instances.yaml` 里已经绑定了 pane，Orbit 会优先复用已有 pane。只有用户明确允许创建缺失 instance，例如传入 `--allow-create`，Orbit 才会准备新 pane。

把 task 发给指定 pane：

```bash
orbit dispatch \
  --task .orbit/tasks/current-task.yaml \
  --to reviewer \
  --transport herdr \
  --pane <pane-id> \
  --json
```

注意：

- Herdr 负责承载 pane 和传消息。
- Orbit 负责 task、evidence、state、gate 和 handoff。
- 不要把 Herdr 的 `agent-status done` 当作 review/test 通过。
- 收口时以 `.orbit/evidence*`、`orbit wait-gate`、`orbit validate` 和 `orbit audit` 为准。

## 配置角色和实例

`.orbit/roles.yaml` 定义角色规则和权限：

```yaml
roles:
  lead:
    role: lead
    permissions:
      can_edit_production_code: true

  reviewer:
    role: reviewer
    permissions:
      can_edit_production_code: false

  tester:
    role: tester
    permissions:
      can_edit_production_code: false
```

`.orbit/instances.yaml` 定义运行中的 agent instance：

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
    command: claude
    env:
      ORBIT_INSTANCE: reviewer
      ORBIT_ROLE: reviewer

  tester:
    role_ref: tester
    command: opencode
    env:
      ORBIT_INSTANCE: tester
      ORBIT_ROLE: tester
```

检查当前身份：

```bash
ORBIT_INSTANCE=reviewer orbit whoami --json
```

解析本轮规则：

```bash
ORBIT_INSTANCE=lead orbit rules resolve \
  --task .orbit/tasks/current-task.yaml \
  --output .orbit/rules/current-resolution.json \
  --json

ORBIT_INSTANCE=lead orbit rules print-context \
  --task .orbit/tasks/current-task.yaml \
  --output .orbit/rules/current-context.json \
  --json
```

`rules resolve` 是可审计的规则来源结果；`rules print-context` 是本轮 agent 应读取的上下文清单。项目规则是叠加层，不会替代 Orbit 默认规则。

## 不能直接宣布完成的情况

出现下面任意情况时，agent 不能直接说“完成”：

- 没有 task contract。
- 改善类任务没有 quality outcome。
- 没有 evidence manifest。
- review/test verdict 是 `fail`、`partial` 或 `invalid`。
- implementation task 声明了 review/test gate，但最新 gate evidence 不是 `pass`。
- task、evidence、loop state 引用不一致。
- 当前 agent 身份和 task `target_role` 冲突，且当前 agent 不在 task `gates.roles` 中。

用户可以接受风险，但 agent 必须把风险、缺口和下一步说清楚。

## 命令速查

```bash
orbit init
orbit new-task --target-role lead --task-type implementation --output .orbit/tasks/current-task.yaml
orbit evidence init --output .orbit/evidence/current-evidence.json
orbit evidence add --file .orbit/evidence/current-evidence.json --kind implementation --status pass --summary "..."
orbit evidence submit --file .orbit/evidence/current-evidence.json --report .orbit/reports/review-report.yaml --task .orbit/tasks/current-task.yaml --json
orbit state start --task .orbit/tasks/current-task.yaml
orbit state progress --message "..." --evidence .orbit/evidence/current-evidence.json
orbit state transition --to in_review --evidence .orbit/evidence/current-evidence.json
orbit wait-gate --task .orbit/tasks/current-task.yaml --evidence .orbit/evidence/current-evidence.json --json
orbit validate --task .orbit/tasks/current-task.yaml --evidence .orbit/evidence/current-evidence.json --state .orbit/loop-state.yaml --json
orbit audit --task .orbit/tasks/current-task.yaml --evidence .orbit/evidence/current-evidence.json --state .orbit/loop-state.yaml --json
orbit handoff --task .orbit/tasks/current-task.yaml --evidence .orbit/evidence/current-evidence.json --state .orbit/loop-state.yaml --output .orbit/handoff/current-handoff.json --record-state --json
```

## 继续阅读

- 运行时指南：[references/runtime/guide.md](references/runtime/guide.md)
- 协议字段说明：[references/runtime/core-operating-model.md](references/runtime/core-operating-model.md)
- coding 规范：[references/runtime/coding-guideline.md](references/runtime/coding-guideline.md)
- review 规范：[references/runtime/quality-outcome-and-review.md](references/runtime/quality-outcome-and-review.md)
- testing 规范：[references/runtime/testing-guideline.md](references/runtime/testing-guideline.md)
- Herdr 安装文档：[https://herdr.dev/docs/install/](https://herdr.dev/docs/install/)

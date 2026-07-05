# Orbit

Orbit 是给 AI agent 用的任务闭环工具。它不负责“让 AI 更会写代码”，而是让 agent 的工作结果更可追溯、更可接手、更难假完成。

## 用了以后有什么效果

使用 Orbit 后，一次任务不会只停留在聊天里。agent 会把任务目标写成 task contract，把实现、review、test 和收口写入 evidence / state / handoff。用户可以看到：这轮到底承诺了什么、谁实现了、谁 review 了、谁测试了、哪些 gate 通过了、还有哪些风险没关。

直接效果：

- 目标不容易被 agent 偷偷改小。
- “完成了”必须有证据支撑。
- review/test 需要独立结论，不能由实现者自评通过。
- 长任务中断后可以交给下一个 agent 接手。
- 多 agent 协作不依赖聊天记忆或 pane 名字。
- 用户可以根据 validate / audit / handoff 判断结果是否可信。

Orbit 适合中等复杂或更大的 AI 开发任务、长任务、多 agent 协作和需要 review/test gate 的任务。不适合简单问答、一行小修、目标未定的需求澄清，或只是临时跑一个命令。

## 用户怎么开始

主路径：

```bash
cd /path/to/your-project
orbit init --operation-mode solo
# 编辑 .orbit/instances.yaml 里的 command
orbit start lead-main
```

`orbit start` 依赖 Herdr automatic runtime。如果只用 manual protocol，可以不运行 `orbit start`，而是手动设置 `ORBIT_INSTANCE` / `ORBIT_ROLE` 启动 agent。

然后告诉 lead agent：

```text
请按 Orbit 流程执行这个任务：

目标：...
范围：...
验收：...
限制：...
```

用户不需要手写 task contract、编辑 evidence manifest、提交 review/test verdict，也不需要理解所有 runtime identity 字段。lead agent 应该自己创建 task、补全 evidence/state，并在关键节点展示目标、边界、验收标准和风险。

进入正式 Orbit 流程后，agent 会：

- 确认身份并读取规则上下文。
- 创建 task contract。
- 写 implementation evidence。
- 派 reviewer/tester，并等待结构化 verdict。
- 运行 `wait-gate`、`validate`、`audit`。
- 生成 handoff。

执行细节以 [Orbit skill](skills/orbit/SKILL.md) 为准。README 只给用户和新 agent 最小路径。

## 安装

安装 Herdr。Herdr 是 Orbit automatic runtime 的唯一官方 adapter：

```bash
curl -fsSL https://herdr.dev/install.sh | sh
herdr --version
```

也可以用 Homebrew 安装 Herdr；需要更准确识别 agent 状态时，可安装 `codex` / `claude` / `opencode` Herdr integration。

启动 Herdr：

```bash
cd /path/to/your-project
herdr
```

安装 Orbit skill：

```bash
npx skills add https://github.com/godokyang/orbit -g
```

这会安装完整 Orbit skill 目录，包括 `references/` 和 `assets/templates/`。公开 skill package 位于 `skills/orbit/`，CLI runtime 也使用同一份规则和模板。

安装 Orbit CLI：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
orbit version
```

本地 clone 的用户更新：

```bash
git pull
sh install.sh
orbit version
```

Orbit CLI 需要 Ruby。远程安装还需要 `curl` 或 `wget`。安装脚本会覆盖已安装的 Orbit CLI runtime 和 wrapper，不会修改你项目里的 `.orbit/` 配置。

## Herdr 和 manual protocol

Herdr 是 Orbit automatic runtime 的唯一官方 adapter。需要 `orbit start` 自动创建/唤醒 agent 或 `orbit dispatch` direct delivery 时，必须有 Herdr。

没有 Herdr 时，只能走 manual protocol：用户自己打开终端，进入项目目录，设置 `ORBIT_INSTANCE` / `ORBIT_ROLE` 后启动 agent。

```bash
cd /path/to/your-project
ORBIT_INSTANCE=reviewer-main ORBIT_ROLE=reviewer codex
```

direct dispatch 只看 runtime resolver 输出是否明确 `dispatch_ready: true`。没有 verified target 时，生成 manual payload：

```bash
orbit dispatch \
  --task .orbit/tasks/current-task.yaml \
  --to reviewer-main \
  --manual-payload \
  --json
```

manual protocol 不是 automatic runtime fallback，不提供 automatic start、direct dispatch 或 Herdr-verified runtime identity。当前 notice 是 `.orbit/runtime/notices` 下的 protocol record / inbox，不是 Herdr pane delivery。

## 配置 agent

用户主要改 `.orbit/instances.yaml` 里的 `command`。role 是 `lead` / `reviewer` / `tester`；instance 是 `lead-main` / `reviewer-main` / `tester-main`。启动和 dispatch 使用 instance key，不使用 role 名。

```yaml
instances:
  lead-main:
    role_ref: lead
    command: codex
    env:
      ORBIT_INSTANCE: lead-main
      ORBIT_ROLE: lead

  reviewer-main:
    role_ref: reviewer
    command: claude
    env:
      ORBIT_INSTANCE: reviewer-main
      ORBIT_ROLE: reviewer

  tester-main:
    role_ref: tester
    command: opencode
    env:
      ORBIT_INSTANCE: tester-main
      ORBIT_ROLE: tester
```

同一个 role 可以有多个 instance，例如 `reviewer-main`、`reviewer-security`。

## 判断是否完成

不要根据聊天回复或 Herdr pane 状态判断 Orbit 任务完成。至少要看：

- task contract 是否存在，目标、范围、验收标准是否清楚。
- implementation evidence 是否记录了实现事实。
- required review/test gate 是否有最新结构化 `pass` verdict。
- `orbit wait-gate`、`orbit validate`、`orbit audit` 是否通过。
- handoff 是否记录剩余风险、验证方式和下一步。

用户可以接受风险，但 agent 必须把风险、缺口和下一步说清楚。

## Agent / 排障命令

下面命令主要给 Orbit-aware agent 和排障使用。普通用户通常不需要手动运行。

```bash
orbit whoami --json

orbit new-task \
  --task-type implementation \
  --output .orbit/tasks/current-task.yaml

orbit rules resolve \
  --task .orbit/tasks/current-task.yaml \
  --output .orbit/rules/current-resolution.json \
  --json

orbit rules print-context \
  --task .orbit/tasks/current-task.yaml \
  --output .orbit/rules/current-context.json \
  --json

orbit evidence init --output .orbit/evidence/current-evidence.json

orbit state start --task .orbit/tasks/current-task.yaml

orbit evidence attach-rule \
  --file .orbit/evidence/current-evidence.json \
  --rule-resolution .orbit/rules/current-resolution.json \
  --task .orbit/tasks/current-task.yaml

orbit evidence add \
  --file .orbit/evidence/current-evidence.json \
  --kind implementation \
  --status pass \
  --summary "implementation completed" \
  --task .orbit/tasks/current-task.yaml

orbit evidence submit \
  --file .orbit/evidence/current-evidence.json \
  --report .orbit/reports/review-report.yaml \
  --task .orbit/tasks/current-task.yaml \
  --json

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

Report 模板在 `skills/orbit/assets/templates/review-report.yaml`、`skills/orbit/assets/templates/test-report.yaml` 和 `skills/orbit/assets/templates/design-review-report.yaml`。

## 运行规则摘要

- Orbit 默认规则随 skill 一起安装；agent 进入正式任务后会通过 `orbit rules resolve` 和 `orbit rules print-context` 读取本轮需要的规则。
- 项目规则可以叠加，但不能替代 Orbit 默认 runtime 规则。
- coding、review、testing 都必须通过 task/evidence/state/gate/audit 闭环证明结果。
- 聊天结论、Herdr done、静态 binding、旧 session file、手写 runtime identity 都不是 gate proof。
- review/test verdict 必须由对应 role 用结构化 report 提交。
- implementation evidence 必须带 `--task`，让 CLI 校验 execution contract。
- `dispatch --to` 使用 instance key，例如 `reviewer-main`，不要使用 role 名 `reviewer`。
- 缺 Herdr 时只能走 explicit manual protocol；不要把 manual protocol 写成 automatic runtime downgrade。

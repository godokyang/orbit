# Orbit

Orbit 是给 AI agent 用的控制流：在合理范围内自动实现需求代码。可追溯、可接手、难假完成是附属好处，不是产品目标。

> **v1 已删除（2026-08-17）**：Orbit v1 runtime 已移除，其命令（`new-task` / `state` /
> `evidence` / `rules` / `whoami` / `handoff` 等）、`instances.yaml` roster 与 Herdr
> `automatic-preview` 集成不再存在。当前唯一入口是 v2 CLI（下文全部命令均为 v2）。
> v1 代码删除 ≠ cutover 完成（见 ADR-005 修订记录）。操作入口是本文与
> [skills/orbit/SKILL.md](skills/orbit/SKILL.md)；v1 长文档已归档到
> `docs/history/v1-runtime/`。下一阶段见 [docs/plan/handoff.md](docs/plan/handoff.md)。

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
orbit v2 init <project_id>
```

`init` 一次性建立 protocol root、genesis policy 和本地 provider 密钥
（`.orbit/local-provider.json`；密钥丢失即项目不可验证，须自行备份）。

然后告诉 lead agent：

```text
请按 Orbit 流程执行这个任务：

目标：...
范围：...
验收：...
限制：...
```

用户不需要手写 task 定义或 evidence 文件。lead agent 会自己创建 task、
dispatch 实现/评审 attempt、提交 evidence 与 gate 结论；完成判定来自
`orbit v2 complete` 的派生结果，不是 agent 的自我报告。

进入正式 Orbit 流程后，agent 会：

- 写 task 定义并 `task start`（task contract + lead control 落盘）。
- dispatch 实现 attempt，提交 implementation evidence。
- dispatch 独立评审 attempt（评估者与实现者 runtime identity 不同，独立性是结构约束）。
- 提交 GateEvaluation；有 Finding 时提交 follow-up 评测并 resolve。
- 运行 `complete` 派生 AggregateOutcome。

执行细节以 [Orbit skill](skills/orbit/SKILL.md) 为准。README 只给用户和新 agent 最小路径。

## 安装

安装 Orbit skill：

```bash
npx skills add https://github.com/godokyang/orbit -g
```

这会安装完整 Orbit skill 目录，包括 `references/` 和 `assets/templates/`。公开 skill package 位于 `skills/orbit/`。

安装 Orbit CLI：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
orbit v2 --help
```

本地 clone 的用户更新：

```bash
git pull
sh install.sh
orbit v2 --help
```

Orbit CLI 需要 Ruby。远程安装还需要 `curl` 或 `wget`。安装脚本会覆盖已安装的 Orbit CLI runtime 和 wrapper，不会修改你项目里的 `.orbit/` 数据。

## 判断是否完成

不要根据聊天回复判断 Orbit 任务完成。至少要看：

- task contract 是否存在，目标、范围、验收标准是否清楚。
- implementation evidence 是否记录了实现事实。
- required review gate 是否有当前（非 stale）的独立 pass verdict。
- `orbit v2 status --task <id>` 显示的 gate 状态。
- `orbit v2 complete --task <id>` 是否输出 `closed: true` 且退出码 0；未决
  blocking finding 会让它退出码 1 并显式列出未满足项。

用户可以接受风险，但 agent 必须把风险、缺口和下一步说清楚。

## Agent / 排障命令

v2 全部命令（`v2` 前缀可省略；该双拼法是未决项，最终命令面待定）：

```bash
# 一次性初始化项目（protocol root + genesis policy + 本地 provider 密钥）
orbit v2 init <project_id>

# 创建任务（task 定义 YAML：goal + units）
orbit v2 task start <task_id> --def task.yaml

# 派发实现/评审 attempt（--rule 必须显式给出规则文件）
orbit v2 dispatch --task <task_id> --role implementer --rule rules/coder.md
orbit v2 dispatch --task <task_id> --role reviewer   --rule rules/reviewer.md

# 提交 evidence（implementation 或 evaluator_submission）
orbit v2 evidence submit --task <task_id> --proposal evidence.yaml

# 提交独立 gate 评测（verdict 可为 pass/fail，fail 可携带 findings）
orbit v2 gate submit --task <task_id> --def evaluation.yaml

# 解决 Finding（需先有 follow-up 评测）
orbit v2 finding resolve --task <task_id> --def resolution.yaml

# 派生完成判定（只读；closed: true 退出码 0，否则 1）
orbit v2 complete --task <task_id>

# 只读状态
orbit v2 status [--task <task_id>]
```

输入文件格式与命令细节见 `orbit v2 --help` 与 [Orbit skill](skills/orbit/SKILL.md)。

## 运行规则摘要

- 一个 task = 一个 `task_id` = 一个 Git branch/worktree；存储在
  `.orbit/task-scopes/<task_id>/` 下，不同 task 路径天然隔离。
- 一切受控写入需要 provider receipt；本地 provider 是一致性机制而非安全边界
  （信任根 = 本地机器用户，替换为真实 provider 是记录在案的欠账）。
- 完成不可自宣：`complete` 是只读派生，未决 finding / stale 评测 / 缺 evidence
  都会让 gate 保持 open 并 fail closed。
- dispatch 时规则文件内容被 sha256 钉死；规则文件变动后新 dispatch 会因 digest
  不匹配失败——这是合同语义，不是故障。
- review/test verdict 必须来自与实现者 runtime identity 不同的独立评估者。
- 缺 marker、epoch 不匹配、密钥文件丢失时停止并请求用户决策，不猜、不回填。

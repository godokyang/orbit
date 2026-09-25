# Orbit

**让 Coding Agent 在执行任务时接受独立检查，发现遗漏后回到原会话修正。**

Orbit 可独立用于任何项目。你照常提出需求，当前 Agent 负责实现，Orbit 保存原始要求、检查实际产物、回传问题并核实完成。文档中的 **Root 就是这个与你对话、负责整项任务的 Agent**。

当前版本为 OMP 单宿主架构（见 [ADR-008](docs/adr/008-omp-native-collaboration-base.md)）：用 `orbit omp` 启动原版 Oh My Pi，Root 通过 OMP 原生 `task/hub` 组建一层执行团队，Orbit 负责登记、观察、检查、纠偏与停止确认。版本号以 `orbit --version` 与 `package.json` 为准。

[安装](#安装) · [开始使用](#开始使用) · [模型与启动参数](#模型与启动参数) · [更新](#更新) · [卸载](#卸载) · [常见问题](#常见问题)

## 安装

### 1. 准备环境

| 需要什么 | 用途 |
| --- | --- |
| Ruby 3.2+、Node.js 18+、npm | 运行和安装 Orbit |
| Oh My Pi（`omp`），已配置可用模型 | 执行项目任务、执行成员与独立检查 |
| curl、tar | 下载安装包 |

先确保 OMP 能正常对话、模型已配置。Orbit 不代替 OMP 的安装与模型配置。

### 2. 安装 CLI

复制下面这一整行到终端执行；程序安装一次后，可用于其他项目：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
```

安装脚本自动为 **zsh／bash 保存 PATH 配置**，重复安装不重复添加。安装前检查 Ruby、Node.js、npm；安装后可用 `orbit doctor` 诊断。**安装成功后重新打开终端**，执行 `orbit --version` 确认。

这一步安装 Orbit 程序及 OMP 运行所需的扩展。受控入口是 `orbit omp`（见下节）；普通 `omp` 不加载 Orbit。

## 开始使用

### 1. 进入项目并用受控入口启动 OMP

```bash
cd 你的项目
orbit omp
```

`orbit omp` 启动原版 OMP 并为本会话加载 Orbit 扩展；`--resume`、`--model`、profile、权限等 OMP 原生参数与退出码全部透传，例如 `orbit omp --resume SESSION_ID`、`orbit omp --model provider/id`。普通 `omp` 不是受控入口。普通终端、tmux、Herdr 均可使用。

### 2. 把需求告诉 Agent

有需求文档时直接说，例如：

> 按 docs/requirements.md 实现需求，完成必要验证，并说明实际完成情况。

涉及多个步骤、模块或执行成员的任务，Agent 按任务需要主动经 Orbit 工具接入（扩展已随 `orbit omp` 加载）；讨论、解释和简单独立修改通常不启动。也可以明确说"这次请使用 Orbit"。

**第一次试用**可在一个空目录中启动 `orbit omp`，然后粘贴：

```text
请使用 Orbit 完成下面的任务：

1. 新增 greet.py，提供 greet(name) 函数，返回 Hello, <name>!。
   去掉名字两端的空白；空名字抛出 ValueError。
2. 支持 python3 greet.py Ada，打印 Hello, Ada!。
3. 新增 USAGE.md，说明调用方式和空名字的处理。
4. 做必要验证，告知 Orbit 是否已接入，交付时说明实际检查状态。
```

### 3. 确认接入与查看结果

Agent 确认接入后应主动说明；交付时说明实际结果，检查未完成时明确说"产物已准备好，等待检查"。另开终端在项目目录执行：

```bash
orbit status
```

`orbit status` 区分任务状态、执行协作（成员数与状态）、检查状态（queued／running／stale／verdict）、JEV 候选分与最终决定、下一动作与按角色用量。高 `delegatable` 不等于建议；只有当前签名的持久 `delegation_hint` 才是 Orbit 已送达的最终提示。`queued` 或 `verdict(complete)` 都不是任务 `complete`。多个待处理任务列出 ID，用 `orbit status ID` 查看，ID 可缩写。

| 状态 | 含义 |
| --- | --- |
| `starting` / `running` | 正在启动或执行，还未完成验收 |
| `complete` | 当前交付版本通过独立检查，相关执行已收尾 |
| `paused` | 已暂停，并确认相关执行停止 |
| `needs_user` | 需要用户补充信息或决定，相关执行已停止 |
| `failed` | 运行出错；不能据此推断已停止 |
| `stop_unconfirmed` | 已尝试停止，但仍未确认全部相关执行结束 |

检查发现问题时，纠正回到**当前会话**继续处理。

### 4. 分工、补充要求与停止

需要分工时，Root 用 OMP 原生 `task` 派发成员、用 `hub` 通信与等待；成员只有一层（不能再派发），Orbit 在成员模型工作前登记其真实身份，结果自动回到 Root 由 Root 核验集成。你不必另外开窗口组队。

补充要求直接在原会话里说。切换同一仓库的另一个 worktree 使用显式 `orbit rebind-workspace`；`amend` 与 `dispute` 只追加检查输入或争议理由。

停止：在 OMP 界面中断当前执行，或另开终端执行：

```bash
orbit stop
orbit status
```

多个待处理任务不默认停止任何一个，先列表再 `orbit stop ID`。`stop` 提示"已提交停止请求"只表示请求已排队，以后续实际状态为准。停止保留会话、代码与任务记录；确认范围是 Root、本任务登记成员及其原生后台工作——外部未登记 Agent 不在其中，成员后台工作的退出以实际进程与作业结算为证。

## 模型与启动参数

### 谁使用什么模型

| 角色 | 默认选择 |
| --- | --- |
| Root | 你在 `orbit omp` 里选择的模型（OMP 原生配置） |
| 执行成员 | 沿用 Root 的原生配置；也可在派发时指定 OMP 可用模型 |
| 独立检查者、按需裁定者 | 另一独立只读 OMP 会话；模型由 OMP 配置与可用模型决定，Orbit 记录实际 provider/model |

要单独指定检查模型，在启动任务时提供 OMP 可用的 `provider/id` 形式（例如经 Orbit 工具参数或 CLI 检查模型选项）；示例模型须已在你账户中可用。Orbit 不硬编码型号，也不把目录可见当作账号可用。

### 可选 Jev 检查调度

安装后运行一次：

```bash
orbit jev setup
```

按提示输入 TypeSafe key（输入不显示）并重新打开终端。key 写入仅当前用户可读的 TypeSafe 环境文件，Orbit 只从 `TYPESAFE_API_KEY` 读取，不写入 Orbit 配置或任务记录。路径、验证与项目关闭方法见[进阶说明](docs/reference/usage-reference.md#jev-配置)。

启用后 Jev 给出"可能卡住／偏题／值得完整检查／可能适合分工"的概率；程序按概率与任务状态安排检查或提示 Root，不把概率当问题证据、完成结论或停止授权。分工建议分两阶段，只有持久化的 `delegation_hint` 送达后才算 Orbit 建议，Root 显式派发；派发记录区分跟随建议与 Root 自行决定。项目可用 `.orbit/jev-disabled` 关闭外发。

## 更新

```bash
orbit update
```

沿用本命令所属安装的目录与来源；准备失败保留旧版，运行中的任务与已加载扩展由 lease 保护。远程来源用 `orbit update --ref REF` 切换。更新后重开 `orbit omp` 会话加载新扩展。

## 卸载

先结束使用该安装的 Orbit 任务与 OMP 会话；仍有存活 lease 时卸载会拒绝。然后：

```bash
orbit uninstall
```

卸载不删除项目代码与 `.orbit` 任务记录。

## 常见问题

### 可以直接接管已打开的普通 `omp` 会话吗？

不能。退出后用 `orbit omp --resume SESSION_ID` 恢复同一会话，再开始任务；扩展在启动时加载。

### Agent 没有主动使用 Orbit？

明确说"这次请使用 Orbit"。没有 Orbit 工具时，检查是否经 `orbit omp` 启动、安装后是否重开终端。先运行 `orbit doctor` 看缺口；OMP 中 Agent 经 `xd://orbit` 设备说明调用 Orbit 工具，可用 `context` 核对当前会话绑定。

### 要为每个项目安装一次、建团队或写规范吗？

程序通常安装一次即可。进入任意项目 `orbit omp` 启动；Orbit 读取项目已有规则，成员由 Root 按需要派发，不要求额外业务流程或 Orbit 需求表。

## 当前范围与更多文档

目标路径（`orbit omp` + 原生成员 + 独立 OMP 检查者）的端到端真实验收（M4）已通过：冻结 #1–#9 全部闭合（#5 经用户批准的组合证据，`finding_repeat_ignored` 未真实触发、仅确定性回归覆盖），证据矩阵见 [OMP 目标路径真实验收记录](docs/reference/omp-native-m4-acceptance-20260924.md)。验收针对已安装的 0.6.18（digest `06dba0f1…`，installed_at `2026-09-24T21:55:54Z`）；源码 0.7.0 尚未安装、尚未做真实验收。当前限制与跟踪项见 [当前限制](docs/plan/debt-ledger.md) 与[迁移总 TODO](docs/plan/omp-native-migration.md)；历史 Codex／OpenCode 时代的验收证据保留在 `docs/reference/` 备查。

- [进阶使用参考](docs/reference/usage-reference.md)：安装目录、profile、CLI 参数、集成和版本维护。
- [设计决定](docs/adr/008-omp-native-collaboration-base.md)与[任务运行合同](contracts/task-runtime.md)。
- [当前限制](docs/plan/debt-ledger.md)与[文档索引](docs/README.md)。

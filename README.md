# Orbit

**让 Coding Agent 在执行任务时接受独立检查，发现遗漏后回到原会话修正。**

Orbit 可独立用于任何项目。你照常提出需求，当前 Agent 负责实现，Orbit 保存原始要求、检查实际产物、回传问题并核实完成。文档中的 **Root 就是这个与你对话、负责整项任务的 Agent**。

[安装](#安装) · [开始使用](#开始使用) · [模型与启动参数](#模型与启动参数) · [更新](#更新) · [卸载](#卸载) · [常见问题](#常见问题)

## 安装

### 1. 准备环境

| 需要什么 | 用途 |
| --- | --- |
| Ruby 3.2+、Node.js 18+、npm | 运行和安装 Orbit |
| Codex CLI，已登录且有可用模型 | 执行独立检查；使用 OpenCode 或 OMP 时也需要 |
| 你日常使用的 Codex、OpenCode 或 OMP | 执行项目任务，选择一个即可 |
| curl、tar | 下载下面的安装包 |

先确保所选 Coding Agent 能正常对话。Orbit 不代替它们的安装、登录和模型配置。

### 2. 安装 CLI

复制下面这一整行到终端执行；程序安装一次后，可用于其他项目：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
```

安装脚本会自动为 **zsh／bash 保存 PATH 配置**，重复安装不会重复添加，无需手动编辑配置文件。

**安装成功后，重新打开一个终端**，执行下面的命令确认：

```bash
orbit --version
```

应输出类似 `orbit 0.6.1` 的版本号。当前源码版本为 `0.6.1`；远程命令安装 GitHub 上所选提交的版本。

如果想继续使用当前终端，执行安装结束时显示的 `export PATH=...` 命令即可。自动保存的配置会在以后新开终端、重启电脑后继续生效。其他 shell 或关闭自动配置的方法见[PATH 配置](docs/reference/usage-reference.md#path-配置)。

这一步安装 Orbit 程序及 OpenCode／OMP 运行所需的原生连接扩展，**不安装 skill**。扩展提供会话通信与控制能力；模型、权限配置保持原样。自定义目录和 OMP profile 见[安装选项](docs/reference/usage-reference.md#安装选项)。

### 3. 安装 skill

skill 告诉 Agent 何时使用 Orbit、如何执行和自检。交给 `npx skills` 安装：

```bash
npx skills install godokyang/orbit --skill orbit --global
```

按提示选择日常使用的 Coding Agent。全局安装后，各项目共用；也可省略 `--global`，只安装到当前项目。

OMP 会读取共享的 `.agents/skills` 目录；skills CLI 暂无独立 OMP 选项时，选 Codex 即可同时写入共享目录，无需复制到 OMP。详见[skill 管理与 OMP](docs/reference/usage-reference.md#skill-管理与-omp)。

两步完成后可运行 `orbit doctor` 检查依赖和扩展安装。普通终端没有可验证的会话时会明确显示“未验证”；安装通过不代表会话已经接入，也不验证模型登录和额度。

**CLI 与 skill 两步都完成后，再启动 Coding Agent。** skill 能安装到更多 Agent，不代表这些 Agent 已具备 Orbit 执行接入；当前执行入口仍为 Codex、OpenCode、OMP。

## 开始使用

### 1. 进入要做任务的项目

终端切换到你的项目目录，再选择一个入口：

| 你使用的 Agent | 启动命令 |
| --- | --- |
| Codex | `orbit codex` |
| OpenCode | `opencode` |
| OMP（Oh My Pi） | `omp` |

普通终端、tmux、Herdr 都用这套命令。安装前已经打开的会话，需要退出后恢复，才能加载 Orbit；具体恢复命令见下文。

### 2. 把需求告诉 Agent

有需求文档时，直接说，例如：

> 按 docs/requirements.md 实现需求，完成必要验证，并说明实际完成情况。

把路径换成你项目中真实存在的文件。涉及多个步骤、模块或执行成员的任务，Agent 应根据 skill 主动接入 Orbit；讨论、解释和简单独立修改通常不启动。你也可以明确说“这次请使用 Orbit”。

**第一次试用**可以在一个新建的空目录中启动 Agent，然后粘贴：

```text
请使用 Orbit 完成下面的任务：

1. 新增 greet.py，提供 greet(name) 函数，返回 Hello, <name>!。
   去掉名字两端的空白；空名字抛出 ValueError。
2. 支持 python3 greet.py Ada，打印 Hello, Ada!。
3. 新增 USAGE.md，说明调用方式和空名字的处理。
4. 做必要验证，告知 Orbit 是否已接入，交付时说明实际检查状态。
```

这会调用执行模型和独立检查模型，适合先确认自己的安装能正常运行。

### 3. 确认已经接入并查看结果

Agent 确认接入后应主动说明“已接入 Orbit，后续会独立检查”。交付时说明实际结果；独立检查尚未完成时应明确说“产物已准备好，等待检查”，不能提前宣布通过。

在项目目录或其子目录另开终端查看：

```bash
orbit status
```

默认显示要求摘要、记录状态、最近检查、下次检查时间及用户需处理事项。只有一个待处理任务时自动定位；多个任务时列出 ID，使用 `orbit status ID` 查看其中一个，ID 可缩写为唯一前缀。没有待处理任务时显示最近已结束记录；程序读取使用 `orbit status --json`。

| 状态 | 含义 |
| --- | --- |
| `starting` / `running` | 正在启动或执行，还未完成验收 |
| `complete` | 当前交付版本通过独立检查，相关执行已收尾 |
| `paused` | 已暂停，并确认相关执行停止 |
| `needs_user` | 需要用户补充信息或决定，相关执行已停止 |
| `failed` | 运行出错，查看错误原因；不能据此推断已停止 |
| `stop_unconfirmed` | 已尝试停止，但仍未确认全部相关执行结束 |

如果检查发现问题，纠正会回到**当前 Agent 会话**继续处理。Agent 说“代码写完了”与 Orbit 的 `complete` 是两个不同状态；无需你不停催它检查。

### 4. 补充要求或停止

补充要求时直接在原会话里说，Orbit 会记录新的用户要求。需要分工时，Agent 通过 Orbit 创建成员并集成结果，你不必另外开窗口组队。

停止时可以在原生界面中断当前执行，或让 Agent 停止这项 Orbit 任务。也可另开终端执行：

```bash
orbit stop
orbit status
```

多个待处理任务时不会默认停止任何一个；先查看列表，再用 `orbit stop ID` 选择。需要说明原因可加 `--reason "停止原因"`。

`stop` 提示“已提交停止请求”只表示请求已排队，以后续实际状态为准。正常退出界面也会请求收尾；停止会保留会话、代码和任务记录。确认范围包括本任务登记的成员和原生管理的后台工作，外部未登记 Agent 不在其中。

## 模型与启动参数

### 谁使用什么模型

| 角色 | 默认选择 |
| --- | --- |
| 当前执行 Agent（Root） | 你在 Codex、OpenCode 或 OMP 中选择的模型 |
| 执行成员 | OpenCode／OMP 沿用 Root 模型；Codex 沿用检查模型 |
| 独立检查者、按需裁定者 | 使用本机 Codex CLI 的模型 |

通常可以继续使用已有配置。要单独指定检查模型，在**启动 Agent 前**设置，例如：

```bash
export ORBIT_REVIEW_MODEL=gpt-6-astra
```

示例模型须已在你的账户中可用。没有设置此变量时，Codex 接入沿用当前会话配置；OpenCode／OMP 从本机 Codex `config.toml` 顶层读取模型。使用 Codex profile 配置检查模型时，请显式设置这个变量。更多说明见[角色与模型建议](skills/orbit/references/model-selection.md)。

### 恢复会话和选择模型

下面的 `SESSION_ID` 换成要恢复的原生会话 ID；模型示例换成你已有的模型：

| 用途 | Codex | OpenCode | OMP |
| --- | --- | --- | --- |
| 恢复会话 | `orbit codex resume SESSION_ID` | `opencode --session SESSION_ID` | `omp --resume SESSION_ID` |
| 指定执行模型 | `orbit codex --model gpt-6-astra` | `opencode --model opencode-go/deepseek-v4.1-flash` | `omp --model opencode-go/deepseek-v4.1-flash` |

原生权限和其他启动参数继续按各工具的方式使用；Codex 参数接在 `orbit codex` 后面。Orbit 的检查模型与 OpenCode／OMP 的执行模型分别配置。

## 更新

先结束正在运行的 Orbit 任务，再分别更新程序和 skill。

### 程序

```bash
orbit update
```

自动沿用本命令所属的安装目录与入口选择，CLI 和原生连接扩展一起更新；准备失败保留旧版。远程安装沿用原分支、标签或提交，本地安装沿用原源码目录（需先自行更新该源码，不自动 git pull）。

需要明确切换远程版本时使用 `orbit update --ref REF`，例如 `orbit update --ref main`。不再需要复制安装命令或填写 runtime 路径。

### skill

```bash
npx skills update orbit --global
```

如果是项目安装，在那个项目中改用 `npx skills update orbit --project`。这一步不更新 CLI。两步完成后重新打开 Coding Agent；`orbit version --json` 查看程序版本和来源，`npx skills list --global` 查看全局 skill。

## 卸载

先停止 Orbit 任务。按本文目录安装时，分别卸载程序与 skill：

```bash
# 程序及原生连接扩展
orbit uninstall

# 全局 skill
npx skills remove orbit --global
```

项目级 skill 则在对应项目执行 `npx skills remove orbit`。`orbit uninstall` 自动定位当前 CLI 所属的安装目录，自定义安装也无需填写 runtime 路径。

卸载程序不会删除 npx 管理的 skill；卸载 skill 也不会删除程序。两者均不删除项目代码和 `.orbit` 任务记录。

## 常见问题

### 已经开着普通 Codex，能直接接入吗？

目前不能直接接管这种会话。先结束或暂停当前工作，再使用 `orbit codex resume SESSION_ID` 恢复原会话；之后继续使用原上下文。OpenCode／OMP 的扩展也需要在启动时加载，安装后应退出并恢复会话。

### Agent 没有主动使用 Orbit，怎么办？

先明确说“这次请使用 Orbit，并检查当前会话能否接入”。如果没有 Orbit 工具，检查是否使用了正确入口、是否在安装后重新启动，以及 skill／扩展是否装进当前配置目录。仅有 `orbit --version` 输出只能证明程序已安装。

先运行 `orbit doctor` 查看具体缺口。有唯一待处理任务时，它还会读取该任务的原生连接；多个任务可用 `orbit doctor ID` 选择。Codex 会话内优先验证当前会话，OpenCode／OMP 可让 Agent 调用 Orbit 工具的 `context` 核对本会话。扩展文件存在与会话已加载扩展分别报告，不根据安装文件猜测接入成功。

OMP 的工具可能显示为 `xd://orbit`，由 Agent 按原生设备说明调用。

### 可以只用 OpenCode 或 OMP，不安装 Codex 吗？

目前不行。它们负责执行时，独立检查仍通过本机 Codex CLI。检查模型配置与登录也需要可用。

### 要为每个项目安装一次程序、建立团队或写规范吗？

完整程序通常安装一次即可。进入任意项目后，Orbit 读取该项目已有规则；成员由当前 Agent 按需要创建。不要求额外业务流程、团队或专门的 Orbit 需求表。

## 当前范围与更多文档

当前源码版本 **0.6.1**，尚未发布 npm 包。已验证 Codex CLI 0.154.0、OpenCode 1.18.30、OMP 18.1.16；真实记录覆盖自主接入、原会话纠偏、成员集成和停止。pi 与 OMP 是不同项目，pi 等其他接入暂缓，先试用现有三个入口。

- [进阶使用参考](docs/reference/usage-reference.md)：安装目录、profile、CLI 参数、集成和版本维护。
- [Agent 使用说明](skills/orbit/SKILL.md)：调用时机、分工与纠偏职责。
- [真实验收](docs/reference/user-flow-acceptance-20260914.json)：Codex；另见 [OpenCode](docs/reference/opencode-runtime-acceptance-20260914.json) 与 [OMP](docs/reference/omp-runtime-acceptance-20260914.json)。
- [当前限制](docs/plan/debt-ledger.md)与[文档索引](docs/README.md)：设计、开发规范和后续工作。

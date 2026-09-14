# Orbit

Orbit 是独立的 Coding Agent 任务执行辅助工具，可用于任意项目：保存用户原始要求，执行期间独立检查实际产物，发现偏差后要求修正，并核实最终结果。它可以直接使用，也可以被其他工具调用；不要求先接入外部业务系统或后续审批流程。

**主执行 Agent（Root）就是当前接收用户要求、负责完成这项任务的 Coding Agent。** 通常是已经与你对话的那一个，继续沿用原会话；用户不需要额外创建“Root”角色。Orbit 程序负责观察与控制，独立检查者负责找遗漏和错误，裁定者仅在真实争议时按需参与，不要求常驻团队。

安装并让 Agent 发现 [Orbit skill](skills/orbit/SKILL.md) 后，用户可以直接说“按这份需求文档实现整个流程”。对于已授权且值得独立监督的执行任务，Agent 应主动调用 Orbit，**不需要用户点名工具**；讨论、只读解释和简单局部修改通常直接处理。实际启动还需具备下述会话控制通道和已授权的检查模型。

需要分工时，Root 使用 Orbit 的 `delegate` 创建本任务拥有的 Codex 执行成员，原始要求自动传递、结果自动回到 Root，停止时一并收尾；普通终端就能使用。Herdr、tmux 是可选的终端组织工具，见 [协作说明](skills/orbit/references/agent-collaboration.md)。

## 日常入口

安装后，在目标项目的终端中运行：

```bash
orbit codex
```

然后像平常一样说“按这份需求文档实现整个流程”。入口为当前 Codex TUI 准备本地原生服务和 Orbit MCP，Agent 可自主接入，用户不用填写 socket 或会话 ID。已有模型配置继续使用；检查模型可单独通过 `ORBIT_REVIEW_MODEL` 指定。只给 Orbit 自己的 MCP 工具配置自动批准，不修改全局 Codex 配置，也不放宽模型 shell 沙箱。

Root 始终是这个正在执行的会话，Orbit 纠偏不换人。`orbit start` 只绑定已有会话；`orbit codex` 是用户明确选择的启动入口，两者职责不同。入口关闭会停止其任务、执行成员与原生后台命令，保留磁盘上的会话历史和产物。

普通已经打开的嵌入式 Codex 没有已验证的热接入能力。可先结束／暂停当前工作，再由用户明确通过 `orbit codex resume SESSION_ID` 恢复原会话；程序不会自动搬迁。非 Codex Agent、外部未登记成员及脱管进程尚未纳入控制。普通终端、tmux 和 Herdr 使用同一入口。

原生接口已在 Codex CLI 0.154.0 验证；这些接口仍有实验性变动，连接失败会明确报告。此前底层验收见 [记录](docs/reference/orbit-runtime-acceptance-20260914.md)，本轮自然触发、纠偏、成员统一停止和三种终端入口已按 [执行计划](docs/plan/user-experience-plan.md) 验证，[原始数据](docs/reference/user-flow-acceptance-20260914.json) 保留实际范围与成本，不以单测替代真实接入。当前版本 0.2.0 尚未发布。

## 怎么开始

先在本仓核对当前入口（需要 Ruby 3.2+、Node.js 18+ 与 npm；检查调用已有 Codex CLI）：

```bash
npm ci
./scripts/orbit --help
```

需要从其他项目调用时，可安装到单独目录，再让使用 Orbit 的 Agent 环境加载该 PATH：

```bash
sh install.sh --bin-dir "$HOME/.local/orbit-task-runtime/bin" \
  --runtime-dir "$HOME/.local/share/orbit/task-runtime"
export PATH="$HOME/.local/orbit-task-runtime/bin:$PATH"
orbit --version
orbit version --json
```

安装器默认将 `orbit` skill 链接到 `${CODEX_HOME:-$HOME/.codex}/skills/orbit`。CLI 与 skill 指向同一个已验证版本，更新时一起切换；Agent 按其技能加载方式发现该目录。`--skill-dir DIR` 可指定技能父目录，`--no-skill` 只安装 CLI。已有同名自定义 skill、未知命令包装或旧安装目录时明确拒绝覆盖，使用空目录；旧安装不迁移。更新默认沿用这次安装记录的 bin 和 skill 路径。

`--bin-dir` / `--runtime-dir` / `--skill-dir` 也分别支持 `ORBIT_INSTALL_DIR` / `ORBIT_RUNTIME_DIR` / `ORBIT_SKILL_DIR`。runtime 未指定时使用 `$XDG_DATA_HOME/orbit/orbit`，没有 XDG 设置则为 `~/.local/share/orbit/orbit`。

安装后用 `orbit codex` 打开新会话；支持原生接口的自定义宿主也可使用 `ORBIT_CODEX_SOCKET` 或 `--socket` 指定确实承载当前会话的端点。Agent 优先用 MCP 的 `context` 核对接入；命令行环境可用 `orbit doctor`。若 `orbit --help` 仍显示旧的 init/dispatch/evidence/gate，说明 PATH 指向旧安装，应先检查 `command -v orbit`。

### 更新与卸载

在 Orbit 任务结束后更新或卸载，同一安装目录一次只运行一个安装器。当前不保证运行中的任务在旧版本文件清理后继续可用。

在更新后的本地 checkout 中重跑安装器，会安装该 checkout 的内容，不自动拉取代码：

```bash
sh install.sh --runtime-dir "$HOME/.local/share/orbit/task-runtime"
```

明确指定远程 ref 时会从 GitHub 解析出一个提交 SHA，并下载该 SHA 对应的完整源码归档；后续安装只读这一份源码。`--ref` 可用分支、标签或完整提交 SHA，`ORBIT_REF` 等价。远程管道安装默认 ref 为 `main`，需要 curl 和 tar：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | \
  sh -s -- --ref main --runtime-dir "$HOME/.local/share/orbit/task-runtime" \
  --bin-dir "$HOME/.local/orbit-task-runtime/bin"
```

安装在临时目录准备完整包、执行锁定依赖安装并校验版本和入口，通过后才切换 `current`。准备失败时旧版仍可用，成功后清理旧版本登记的文件。用户额外文件保留；安装器登记的程序文件与依赖目录属于其管理范围，不在其中保存自定义资料。切换不是运行任务的热更新，也不实现掉电恢复或历史版本管理平台。

```bash
sh "$HOME/.local/share/orbit/task-runtime/current/uninstall.sh" \
  --runtime-dir "$HOME/.local/share/orbit/task-runtime"
```

卸载从记录读取 bin 和 skill 路径，仅移除匹配的入口和登记文件。用户额外文件、项目规范和项目 `.orbit` 任务资料保留。

### 版本与发布

版本号以 `package.json` 为准；CLI 与 Codex 连接的客户端版本从同一来源读取。`orbit version --json` 显示版本、来源提交、内容摘要与安装时间。本地安装的 commit 是工作树基线，`dirty` 表示存在本地改动；非 Git 来源的提交与修改状态记为未知。安装清单和运行记录的格式版本独立于产品版本号。

维护者通过 `npm version <新版本> --no-git-tag-version` 同步包与锁文件，再运行 `npm test` 和 `npm pack --dry-run`。版本检查会拒绝包与锁文件不一致；确认发布范围后，才提交并创建对应的 `v<版本>` 标签、推送或发布 npm 包。当前 `0.2.0` 尚未发布，安装器不会自动打标签、发布或后台更新。

## 执行任务

Agent 优先通过 Orbit MCP 执行以下等价操作，避免 shell 沙箱阻断控制连接。原始指令用原生用户消息或明文文件，不另填需求表。`start` 可选 `--thread`、`--socket`、`--project`（默认分别为 `CODEX_THREAD_ID`、`ORBIT_CODEX_SOCKET` 或 Codex 默认控制插座、当前目录）：

```bash
# 最近一条用户消息作为原文；检查模型须是本机 `codex exec` 可用的 ID
orbit start --review-model MODEL --check-in 300 --estimate-minutes 90

# 指定原生 message-id，并附带依据文件（可重复 --basis）
orbit start --review-model MODEL --message-id MESSAGE_ID --basis path/to/spec.md

# 显式 prompt 文件；只有 --deadline 是硬停止线，estimate 只是参考
orbit start --review-model MODEL --prompt-file ./instruction.txt \
  --deadline 2026-09-14T18:00:00Z --estimate-tokens 200000
```

`--foreground` 把本次任务进程留在当前终端，直到任务结束。不加该选项时，`start` 打印 `task_directory`、本次任务进程 pid 和 `starting`；这只证明进程已创建，实际接入状态用 `orbit status` 核对。

```bash
orbit status TASK_DIRECTORY
orbit check TASK_DIRECTORY          # 按约定时间循环之外，立刻排一次检查
orbit amend TASK_DIRECTORY --file FILE
orbit dispute TASK_DIRECTORY --reason "争议点与依据"
orbit stop TASK_DIRECTORY --reason "停止原因"
orbit delegate TASK_DIRECTORY --file scope.txt --model MODEL
```

`stop` / `check` / `amend` / `dispute` / `delegate` 成功时返回 `status: queued`，只表示命令已交给任务进程，**不等于**停止已确认、检查已完成或原文已生效。

## 运行时不要误会的几件事

- `--check-in` 是约定观察间隔，到期再排下一次；等待本身不调用模型。
- `--estimate-minutes` / `--estimate-tokens` 不是上限。只有用户明确给出的 `--deadline` 才是硬线。
- Root 经 skill 加载最小实现和共享规则，其他专项规则按当前动作加载。独立检查加载 review 和共享规则，同时读取固定产物中的相关项目规则。不把 Orbit 规则全局覆写进目标项目 `AGENTS.md`，只读取目标项目实际适用的规范。
- `--review-model` 只走本机 Codex CLI（`codex exec`）。GLM、DeepSeek 等是 Root 已有的协作工具选项，不是 Orbit 已接入的供应商适配。角色建议见 [model-selection.md](skills/orbit/references/model-selection.md)。

## 怎么判断进度

通过 MCP `status` 或 `orbit status` 看任务目录和 的实际状态（如 `running` / `complete` / `paused` / `needs_user` / `failed` / `stop_unconfirmed`），不要只看聊天里的「完成了」。未检查、未停止、未验证要如实看待。`queued` 不是动作完成。

## 被其他工具调用

反馈处理、任务管理或自动化工具可以在获得执行授权后调用同一个 `orbit start`，传入项目、已有 Agent 会话和原始指令依据，保存返回的任务目录，再通过 `orbit status` 或任务事件读取结果。调用方负责自己的业务状态，Orbit 独立运行至完成或停止；直接使用时无需这些接入方。

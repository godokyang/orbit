# Orbit

Orbit 是独立的 Coding Agent 任务执行辅助工具，可用于任意项目：保存用户原始要求，执行期间独立检查实际产物，发现偏差后要求修正，并核实最终结果。它可以直接使用，也可以被其他工具调用；不要求先接入外部业务系统或后续审批流程。

**主执行 Agent（Root）就是当前接收用户要求、负责完成这项任务的 Coding Agent。** 通常是已经与你对话的那一个，继续沿用原会话；用户不需要额外创建“Root”角色。Orbit 程序负责观察与控制，独立检查者负责找遗漏和错误，裁定者仅在真实争议时按需参与，不要求常驻团队。

安装并让 Agent 发现 [Orbit skill](skills/orbit/SKILL.md) 后，用户可以直接说“按这份需求文档实现整个流程”。对于已授权且值得独立监督的执行任务，Agent 应主动调用 Orbit，**不需要用户点名工具**；讨论、只读解释和简单局部修改通常直接处理。实际启动还需具备下述会话控制通道和已授权的检查模型。

本地两条最小真实验收已通过：独立发现遗漏并由原 Root 修正、明确截止时间触发实际停止。验收使用专用 app-server，不代表普通终端会话已经可直接接入。验收范围见 [记录](docs/reference/orbit-runtime-acceptance-20260914.md)；这不代表已证明所有项目均能节省额度。当前工作区版本为 0.2.0，尚未发布。

## 第一版能接什么

只支持**已经 loaded** 于 Codex 原生 Unix app-server 的现有会话。默认线程是当前 Agent 的 `CODEX_THREAD_ID`，默认控制插座是 `$CODEX_HOME/app-server-control/app-server-control.sock`（未设 `CODEX_HOME` 时为 `~/.codex/app-server-control/app-server-control.sock`）。

普通 embedded TUI 没有即时停止接口。插座不存在或线程未在该 app-server 上 loaded 时，Orbit **拒绝接入**，不会新建 Root、自动 resume，也不会为绕过而启动 daemon。

若会话本身由 Codex 的 app-server 托管，那是 Codex 的会话托管，不是 Orbit 常驻平台。`orbit start` 只为**这一次任务**拉起陪伴进程，任务结束后退出。

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

安装 CLI 不会给现有会话补上控制端点。启动任务前，须确认 Root 已加载在所指定的 Codex app-server 中；默认端点不存在时，只能指定该会话实际所在的 `--socket`，不能随意新建服务并假定原会话已接入。若 `orbit --help` 仍显示旧的 init/dispatch/evidence/gate，说明调用的是旧安装，先检查 `command -v orbit`。

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

原始指令用原生用户消息或明文文件，不另填需求表。`start` 可选 `--thread`、`--socket`、`--project`（默认分别为 `CODEX_THREAD_ID`、上述 app-server 插座、当前目录）：

```bash
# 最近一条用户消息作为原文；检查模型须是本机 `codex exec` 可用的 ID
orbit start --review-model MODEL --check-in 300 --estimate-minutes 90

# 指定原生 message-id，并附带依据文件（可重复 --basis）
orbit start --review-model MODEL --message-id MESSAGE_ID --basis path/to/spec.md

# 显式 prompt 文件；只有 --deadline 是硬停止线，estimate 只是参考
orbit start --review-model MODEL --prompt-file ./instruction.txt \
  --deadline 2026-09-14T18:00:00Z --estimate-tokens 200000
```

`--foreground` 把本次任务进程留在当前终端，直到任务结束。不加该选项时，`start` 打印 `task_directory` 和本次任务进程 pid。

```bash
orbit status TASK_DIRECTORY
orbit check TASK_DIRECTORY          # 按约定时间循环之外，立刻排一次检查
orbit amend TASK_DIRECTORY --file FILE
orbit dispute TASK_DIRECTORY --reason "争议点与依据"
orbit stop TASK_DIRECTORY --reason "停止原因"
```

`stop` / `check` / `amend` / `dispute` 成功时返回 `status: queued`，只表示命令已交给任务进程，**不等于**停止已确认、检查已完成或原文已生效。

## 运行时不要误会的几件事

- `--check-in` 是约定观察间隔，到期再排下一次；等待本身不调用模型。
- `--estimate-minutes` / `--estimate-tokens` 不是上限。只有用户明确给出的 `--deadline` 才是硬线。
- Root 经 skill 加载最小实现和共享规则，其他专项规则按当前动作加载。独立检查加载 review 和共享规则，同时读取固定产物中的相关项目规则。不把 Orbit 规则全局覆写进目标项目 `AGENTS.md`，只读取目标项目实际适用的规范。
- `--review-model` 只走本机 Codex CLI（`codex exec`）。GLM、DeepSeek 等是 Root 已有的协作工具选项，不是 Orbit 已接入的供应商适配。角色建议见 [model-selection.md](skills/orbit/references/model-selection.md)。

## 怎么判断进度

看任务目录和 `orbit status` 的实际状态（如 `running` / `complete` / `paused` / `needs_user` / `failed` / `stop_unconfirmed`），不要只看聊天里的「完成了」。未检查、未停止、未验证要如实看待。`queued` 不是动作完成。

## 被其他工具调用

反馈处理、任务管理或自动化工具可以在获得执行授权后调用同一个 `orbit start`，传入项目、已有 Agent 会话和原始指令依据，保存返回的任务目录，再通过 `orbit status` 或任务事件读取结果。调用方负责自己的业务状态，Orbit 独立运行至完成或停止；直接使用时无需这些接入方。

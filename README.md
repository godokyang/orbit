# Orbit

Orbit 是独立执行工具：在**任意项目**里，沿用现有 Coding Agent（Root）推进已授权任务，并在旁路做独立检查与纠偏。不依赖 Zeen、Herdr、Feedback 或任何外部审批流程。

现有 Root 可通过 [Orbit skill](skills/orbit/SKILL.md) 在已授权执行时自行接入。讨论需求、澄清方案不要启动 Orbit。

本地两条最小真实验收已通过：独立发现遗漏并由原 Root 修正、明确截止时间触发实际停止。验收范围见 [记录](docs/reference/orbit-runtime-acceptance-20260914.md)；这不代表已证明所有项目均能节省额度。当前工作区版本为 0.2.0，尚未发布。

## 第一版能接什么

只支持**已经 loaded** 于 Codex 原生 Unix app-server 的现有会话。默认线程是当前 Agent 的 `CODEX_THREAD_ID`，默认控制插座是 `$CODEX_HOME/app-server-control/app-server-control.sock`（未设 `CODEX_HOME` 时为 `~/.codex/app-server-control/app-server-control.sock`）。

普通 embedded TUI 没有即时停止接口。插座不存在或线程未在该 app-server 上 loaded 时，Orbit **拒绝接入**，不会新建 Root、自动 resume，也不会为绕过而启动 daemon。

若会话本身由 Codex 的 app-server 托管，那是 Codex 的会话托管，不是 Orbit 常驻平台。`orbit start` 只为**这一次任务**拉起陪伴进程，任务结束后退出。

## 怎么开始

本地安装当前版本（需要 Ruby 3.2+、Node.js 18+ 与 npm；检查调用已有 Codex CLI）：

```bash
npm ci
sh install.sh --runtime-dir "$HOME/.local/share/orbit/task-runtime"
orbit --help
```

命令面以 `orbit --help` 为准。旧 init / dispatch / evidence / gate 命令和 v2 数据格式不再支持。Unix 连接通过一个小型 Node 桥复用 `ws` 库处理原生 WebSocket，任务状态与控制逻辑仍在 Ruby 中。

安装器不会覆盖没有新版安装标识的旧目录或无关命令包装。已有旧版时可另选空的 `--bin-dir` 与 `--runtime-dir`，确认新版本后再处理旧安装。Skill 位于 `skills/orbit/`，可通过支持本地目录的 skill 安装工具发现；不由 CLI 全局改写项目规范。

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
- Root 经 skill 加载最小实现和共享规则，其他专项规则按当前动作加载。独立检查加载 review 和共享规则，同时读取固定产物中的相关项目规则。不把 Orbit 规则全局覆写进目标项目 `AGENTS.md`，也不引入 Zeen 专用规范。
- `--review-model` 只走本机 Codex CLI（`codex exec`）。GLM、DeepSeek 等是 Root 已有的协作工具选项，不是 Orbit 已接入的供应商适配。角色建议见 [model-selection.md](skills/orbit/references/model-selection.md)。

## 怎么判断进度

看任务目录和 `orbit status` 的实际状态（如 `running` / `complete` / `paused` / `needs_user` / `failed` / `stop_unconfirmed`），不要只看聊天里的「完成了」。未检查、未停止、未验证要如实看待。`queued` 不是动作完成。

## 接入 Feedback

Feedback 在自己的执行授权后调用同一个 `orbit start`，传入项目、已有会话和原始指令依据，保存返回的任务目录，通过 `orbit status` 或任务事件读取结果。业务状态映射留在接入方，不再维护第二套执行调度。Orbit 完成不依赖 Feedback 收到结果，也不要求安装 Zeen。

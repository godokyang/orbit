---
name: orbit
description: 在用户已授权开始执行时，沿用现有 Codex app-server 会话启动 Orbit 独立检查与纠偏。不用于需求讨论、普通 embedded TUI，也不新建 Root。
metadata:
  short-description: 沿用现有 Codex Root 做独立执行检查
---

# Orbit

Orbit 在任意项目中陪伴一次已授权执行：现有 Root 继续做工程判断，Orbit 进程做计时、固定产物上的只读检查、纠正投递和停止确认。不依赖 Zeen、Herdr 或外部审批。最小真实纠偏与停止已验证，适用范围是下述可控会话。

发现本 skill 不等于可以开工。需求讨论、方案探讨、探索性阅读只保持察觉，**不要**调用 `orbit start`。

## 何时启动

用户已给出可执行指令（或明确指定消息 / prompt 文件），并授权开始实现时，在**当前** Codex 会话调用：

```bash
orbit start --review-model MODEL [--thread ID] [--socket PATH]
            [--message-id ID | --prompt-file FILE|-] [--project DIR]
            [--basis FILE] [--check-in SECONDS] [--foreground]
            [--estimate-minutes N] [--estimate-tokens N] [--deadline ISO8601]
```

- 默认 `--thread` 为 `CODEX_THREAD_ID`，`--project` 为当前项目，`--socket` 为 `$CODEX_HOME/app-server-control/app-server-control.sock`。
- 未提供 `--message-id` 或 `--prompt-file` 时，用该会话最近一条**原生用户消息**当原文。不要把模型计划写成原文，不要另填需求表。`--basis` 可重复，指向指令指定的依据文件。
- `--review-model`（或 `ORBIT_REVIEW_MODEL`）必须是本机 `codex exec` 能跑的模型 ID。产品检查通道只接 Codex CLI。
- `--estimate-*` 是参考，不是上限。只有 `--deadline` 是用户明确硬线。
- `--check-in` 为约定观察间隔（秒）；到期检查后安排下一次。
- `--foreground` 把本次任务进程留在当前终端。不加则拉起**本次任务**陪伴进程并打印 `task_directory` 与 pid，任务结束即退出。这不是 Orbit 常驻平台，也不要为此去启动 daemon。

会话必须已经 loaded 在该 Unix app-server 上。普通 embedded TUI 没有即时停止接口：插座不存在或线程未 loaded 时停止并报告错误，**禁止**新建会话、自动 resume、自动 daemon 或改走仅排队控制。

安装需要 Ruby 3.2+、Node.js 18+、npm 与已有 Codex CLI。若命令仍显示旧的 init/dispatch/evidence/gate，使用当前版本入口，不走兼容别名或擅自覆盖未知安装。

## 任务进行中

记录在 `PROJECT/.orbit/tasks/<id>`。后续只使用 `orbit --help` 中的命令：

```bash
orbit status TASK_DIRECTORY
orbit check TASK_DIRECTORY
orbit amend TASK_DIRECTORY --file FILE|-
orbit dispute TASK_DIRECTORY --reason TEXT
orbit stop TASK_DIRECTORY [--reason TEXT]
```

`stop` / `check` / `amend` / `dispute` 返回 `status: queued` 只表示命令已入队，不等于已停止、已检查或原文已更新。完成、暂停、需要用户、失败、停止未确认以 `orbit status` 的实际状态为准；未检查、未停止、未验证如实标明。

准备好交付后结束当前执行轮次，让程序检查最终产物；不要在同一轮里反复等待 `complete` 而持续保持 Root 活跃。收到具体纠正再继续。当前确认范围是绑定 Root 和原生登记的后台命令；不要将脱离管理的后台任务或未接入成员说成已受控。

## 规则与分工

默认只读 skill 内 `assets/rule-library/tasks/minimal-implementation.md` 与 `assets/rule-library/shared/escalation-payload.md`。修复、测试、对外命名、结构化边界、命令表面、质量标准、独立评审按当前动作再读对应 `assets/rule-library/tasks/` 文件。不要把这些规则全局写入或覆盖目标项目 `AGENTS.md`。目标项目已有规则对 Root 与检查者同样适用；不要引入 Zeen 专用规范。

Root 继续担任当前会话。检查者只读固定产物，对照原始指令、指定依据、用户明确修改和实际结果。真实争议再用 `orbit dispute` 按需裁定，只挡争议部分完成。角色与模型建议在需要选模型时再读 [references/model-selection.md](references/model-selection.md)。

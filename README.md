# Orbit

**给 [DeepSeek Harness（DSH）](https://github.com/deepseek-ai/deepseek-harness) 加上受控任务、独立检查与可核对的停止。**

Orbit 现在是一个 DSH bundle：受控 Root、执行成员、独立检查者、任务记录与证据都在 DSH 之上运行；不再依赖 OMP、Ruby 或 OMP 会话文件。

## Orbit 能帮你做什么？

- **把一句话变成可检查的任务**：Root 理解需求、拆工作单元、派发成员，检查者独立读固定快照给出结论。
- **完成必须有证据**：检查者返回 `complete`、覆盖完整、交付就绪，且停止证据齐全，任务才进入 `complete`。
- **停止可核对**：`stop` 只表示围栏已落盘；只有 `stopConfirmation.confirmed=true` 才算停止，缺证据时保留 `stop_unconfirmed`。
- **记录可迁移**：任务、检查、成员、问题、事件与会话投影都在任务目录中，CLI 与 Loom 节点只读公开合同。

## 快速开始

### 1. 构建与安装

```sh
pnpm install
pnpm --filter @zeen/orbit build
pnpm --filter @zeen/orbit exec orbit install \
  --home ~/.dsh --profile orbit-app --template web --mode app
```

安装会创建/复用 DSH profile、复制 `@zeen/orbit`、启用 bundle、应用受控 overlay，并运行 T0 检查。
CI 或离线环境可加 `--skip-t0`；安装后用 `orbit doctor --t0 --home ~/.dsh --profile orbit-app` 复核。

> npm 发布尚未执行；当前请从本仓库构建后用上面的命令安装。

### 2. 启动

```sh
dsh --profile orbit-app
```

应用创建 Root 后，在对话中让 Root 调用 `orbit` 工具，或使用命令栏：

- `/orbit-status`：任务状态、在途检查、open findings、待答问题；
- `/orbit-stop`：请求停止并等待确认；
- `/orbit-questions` / `/orbit-answer <id> <answer>`：查看并答复问题；
- `/orbit-settings`：允许模型、检查者路由、JEV 与候选池的只读摘要。

### 3. 无头节点（Loom）

```sh
orbit launch --json --project /abs/project --home /tmp/orbit-node \
  --profile orbit-node --bootstrap /abs/task.json --result /abs/result.json
```

`launch` 只返回 DSH 启动规格；调用方拉起进程后轮询 control socket。带 `--bootstrap` 时规格会设置
`ELECTRON_RUN_AS_NODE=1`，不打开桌面窗口。任务 spec v1：

```json
{
  "version": 1,
  "action": "start",
  "instruction": "...",
  "project": "/abs/project",
  "externalRefs": ["loom:run-1"],
  "allowedModels": ["deepseek-account/deepseek-flash"],
  "model": { "provider": "deepseek-account", "model": "deepseek-flash" },
  "policy": {
    "readRoots": ["/abs/source"],
    "writePaths": ["/abs/project/result.json"],
    "readLog": "/abs/runtime/session-reads.jsonl",
    "allowBash": false
  }
}
```

`action:"resume"` + `previousTask` 续接同一 Root；`policy` 只允许授权根读取、指定路径写入，并记录读取证据。

## CLI

```sh
orbit status [TASK] --json
orbit status --external-ref REF --json
orbit status --session SESSION --json
orbit events [TASK] --after CURSOR --json
orbit sessions [TASK] --json
orbit questions [TASK] --json
orbit answer [TASK] --question ID --selected A,B [--custom TEXT] --json
orbit prompt [TASK] --message TEXT --json
orbit abort [TASK] --json
orbit stop [TASK] --json
orbit export [TASK] --output FILE --json
orbit capabilities --json
orbit doctor --json [--t0]
orbit install --home DIR --profile P [--mode app|node|checker]
```

`TASK` 可省略（取最新任务），也可传任务目录。所有命令只读公开合同；不读 `.orbit` 内部字段。

## 配置与模型

- 模型路由由 DSH 提供：`provider/model`，例如 `deepseek-account/deepseek-flash`。
- 严格授权：任务可冻结 `allowedModels`；Root、成员、检查者调用前校验，漂移记 `model/violation`。
- 检查者通过 `dsh-sdk` 子进程运行，使用独立 `DSH_HOME` 与只读 sandbox。
- JEV 观测/选型为可选：配置 `jevEndpoint` 后启用；未配置时保留 facts-only。

## 合同与证据

- 集成合同：[contracts/integration.md](contracts/integration.md) / [integration.json](contracts/integration.json)（2.0）。
- 任务语义：[contracts/task-runtime.md](contracts/task-runtime.md)。
- 检查 schema：[contracts/check-result.schema.json](contracts/check-result.schema.json)。
- 决策记录：[docs/adr/](docs/adr/)。
- 真实验收记录：[docs/reference/](docs/reference/)。

## 常见问题

**Q：停止返回成功但任务还在 running？**
`stop` 只表示围栏已落盘；以 `status` 的 `stopConfirmation` 为准。

**Q：检查者报错？**
确认 profile 中已安装 `@deepseek-ai/dsh-subagent-dsh-sdk` 与 `dsh-sdk-client`，并正确配置 `dshBin`、`profile`、`dshHome`。

**Q：安装后 bundle 不生效？**
运行 `orbit doctor --t0`，检查 profile manifest、bundle、host dist 与 T0 输出。

## 当前状态

- B/C2 已完成；C3 的 discovery、执行启动/停止/续接、准备任务与 source policy 已迁到 DSH。
- C1 为命令栏 + 对话卡片，React 面板尚未完成。
- 旧 OMP 文件（`session.py`、`probe.py`）尚未删除，等 D 阶段授权。
- Loom 迁移在独立分支，尚未推送。

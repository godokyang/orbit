# TypeScript Core + DSH 迁移交接（2026-10-21）

## 仓库与分支

| 仓库 | 分支 | 最新提交 | 说明 |
| --- | --- | --- | --- |
| `orbit-ts` | `v2` | `bc51ae5` | 本交接所在分支，包含全部 Orbit 2.0 代码 |
| `orbit-ts` | `feat/ts-core-dsh` | `bc51ae5` | 与 v2 同步 |
| `loom-dsh` | `v2` | `46c3dc5` | 已推送，包含 Loom 2.0 迁移与修复 |
| `loom-dsh` | `feat/dsh-migration` | 合并到 `46c3dc5` | 与 v2 同步 |

- Orbit 包：`@zeen/orbit@0.1.0`（`private` 已移除，发布仍未执行）。
- 合同：`contracts/integration.md/.json` 2.0 冻结。

## 已验证

### Orbit
- 127 个测试通过。
- 真实模型验收（`docs/reference/real-acceptance-20261020.md`）：
  - 基础交付；
  - 冻结验收 #1（检查发现错误 → Root 修正 → 复检通过）；
  - 冻结验收 #2（真实停止）；
  - 成员停止、慢检查者停止（fail closed）。
- 完整项目验证（`docs/reference/real-project-validation-20261021.md`）：实现、测试、独立检查、完成、stop 确认、成员/单元、export、events、外部引用。
- 提问→答复→采用验证（`docs/reference/real-question-adoption-20261021.md`）。
- React 面板（`docs/reference/c1-orbit-panel.md`）：
  - Start/Stop/Check/Complete 均用 ego-browser 复用同一 tab 验证；
  - 可编辑并持久化设置；
  - 独立事件行 `Orbit · start/declare/check/complete`；
  - 仓库内可复现客户端构建（`scripts/build-ui.mjs`）。
- 干净安装 + `doctor --t0`：192 行通过。
- D 阶段清理已执行：旧 OMP/Ruby 代码与测试删除，新增 `contracts/host-dsh.md`；`pnpm pack` 生成 0.1.0 tarball（运行时依赖仅 schemastery）。

### Loom
- 89 个测试通过。
- 迁移与修复（`v2`）：
  - headless DSH 启动/停止/续接原语；
  - DSH `sessions.visible_text` 读取 `loom-self-check`；
  - 2.0 `requirementCoverage` 归一化；
  - checker 模型按节点配置扩展；
  - 模型 id 支持多段斜杠（ZenMux）；
  - candidate replay 返回 `self_check_origin`；
  - Orbit status 暴露 checker identity 与数值 revision。
- ZenMux 已按授权同步到隔离 node profile，`zenmux/google/gemini-3.7-flash` 可正常执行，无 `model/violation`。

## 阻塞（未完成）

V2 上的 Loom 完整执行 run **未完成**。

真实 run 中：

- Orbit 任务能完成（declare/check/finish/accept/complete、`stop_confirmed`）；
- 节点 `prepare` 日志证明检查完成后会正确选择 `action=collect`；
- 但 checker 的 dsh-sdk 子进程在 `session-run` 阶段长期没有 terminal；
- 终止后 Orbit 记录：

```text
check/failed
category: missing-terminal
```

- 因为检查未完成，collect 没有执行，candidate/reviews 没有提交，gate 一直 `complete=false`。

该条件连续多轮复现。已提交的 `self_check_origin` replay 响应尚未在一次不重启 worker 的完整 run 中验证。

## 本地 e2e 方法（手工）

1. 启动 `infra/docker-compose.yml`（Postgres + Temporal，本地已有实例）。
2. 启动 backend（`services/backend`，`uv run uvicorn loom.api.app:create_app --factory`）。
3. 启动 orchestrator（`services/orchestrator`，`uv run loom-orchestrator --address 127.0.0.1:17233`）。
4. 用 API 创建 project/node/execution-target/deliverable/standard/plan，approve 生成 run。
5. 手工 dispatch Temporal workflow（本地 backend 不自动派发）。
6. 用 `loom-node work --config <node.json>` 启动节点，节点启动 headless DSH + Orbit。
7. 用 Orbit CLI `prompt` 推动模型执行 `declare → check → finish/accept → complete`。
8. 轮询 `GET .../runs/{id}`、`/gate`、`/events` 与节点 runtime 的 `run-inbox.json`。

注意：

- node config 需同时包含执行模型与 checker 模型在 `allowed_models`；
- 节点 runtime 必须在私有目录（不能直接在 `/tmp` 下）；
- node/checker profile 的 web host 使用临时端口（`port: 0`），不再占用 3080；
- 不要在 run 进行中重启 node worker，否则会进入 `stop_unknown`。

## 当前现场/清理

- 临时 e2e 目录 `/Users/yangke/loom-*`、`/tmp/loom-*` 已删除；
- 18081 patched backend 已停止；
- 隔离数据库 `loom_v2` 已删除；
- 本地 Loom 用户自己的后台/编排/node 未动；
- 本地 eval 主库中可能仍保留早期创建的测试 project/run 行（没有删除 API）。

## 下一步

1. 修 dsh-sdk checker 的 terminal 超时/收束（或换稳定 checker 环境）；
2. 跑一次不重启 worker 的完整 Loom run，验证 candidate/reviews/gate complete；
3. 通过后再完成 V2 最终验收，并按需发布 `@zeen/orbit`。


## 2026-10-21 追加：headless profile 不再占用 Web 端口

`orbit-node.patch.yml` 与 `orbit-checker.patch.yml` 现在把 `webserver` 绑定到
`127.0.0.1:0`（临时端口），保留 `host`/压缩等必需配置。效果：

- headless 节点仍能启动 Web host（SDK app 需要），但不会占用 `127.0.0.1:3080`；
- 人在同一台机器上可以同时打开 DSH Web（3080）；
- 已在全新 node profile 验证：进程监听 `127.0.0.1:53767`，3080 空闲。

已有 profile 需要重新执行 `orbit install` 或同步 overlay 后重启节点进程才会生效。

## 2026-10-21 追加：无头 profile 与真实 run 的现状

### 已修

- `orbit install` 的 node/checker 默认改用 `sdk` 模板；显式 `--template web` 的
  unattended profile 才追加 `webserver.port: 0`，不会占用 3080。
- `orbit launch` 统一传 `--no-open`，headless 节点不再打开浏览器。
- checker 使用 `sdk` 模板且不加载 `@zeen/orbit`，避免 `orbit-host` 等待
  `agentPresets` 并把警告写到 stdout（会让 `dsh-sdk` 报 protocol 初始化失败）。
- 节点/ checker 的 `dshBin` 指向当前 npx DSH JS 入口，而不是已失效的 App 路径。
- 后台 `run_candidate` 首次插入也返回 `self_check_origin`，不再 500。

提交：Orbit `4520163`（v2 / feat/ts-core-dsh），Loom `db46aa2`（v2）。

### 真实 run 已经走到的位置

在本地 Loom + Temporal 上真实跑通：

- headless DSH 节点启动、ZenMux/GLM 执行、写入 `answer.txt`；
- Orbit `declare → check → finish/accept → complete`，`stop_confirmed`；
- 节点读取 DSH `visible_text` 自检，提交 candidate（DB 有行）；
- 逐标准 review 已提交（HTTP 200）。

### 仍未完成的一处

gate 的 S1 review 是 `unverified` 且 `checker.basis = null`。

用同一份 observation / candidate / origin 手工调用
`build_reports(..., allowed_models=[...])` 会得到 `passed` 且 basis 非空；
因此这是节点在“先发布过一份没有 origin 的报告、后台保留第一份”的竞态，
不是 evidence 本身不成立。需要让节点在 candidate 回读 origin 之后再首次
提交 reviews（或在 origin 缺失时拒绝提交），并避免后台按 candidate/code
保留旧的 unverified 行。

### 模型

按用户要求，后续测试只用智谱 coding plan cn：

- provider：`zai-coding-cn`
- 模型：`zai-coding-cn/glm-5.3`

`llm-pi-ai` 的 provider 配置需要从用户 Web profile 的 `cordis.patch.yml`
带过来，凭据用 `ZAI_CODING_CN_API_KEY`。

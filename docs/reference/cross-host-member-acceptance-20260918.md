# 跨宿主成员验收：OpenCode Root → Codex（2026-09-18）

本文记录[用户结果补齐计划](../plan/user-outcome-completion-plan.md)切片 C 的真实运行证据。它只声明本次实际核对过的路径与能力，不把其他 kind、Herdr 控制或未登记进程算作受控。

## 环境与边界

- 源码：`72c6dde` 之上未提交的切片 C 改动，按 patch 升至 0.6.3，本地安装 `content_digest 8df0acbf…`、`installed_at 2026-09-18T06:06:36Z`；新宿主会话实际加载该版本。
- Root：新启动的 OpenCode 会话（Herdr pane 只作为终端展示，未用于成员投递或停止）。成员：任务运行进程持有的独立 Codex app-server，模型取自 Codex 侧配置 `gpt-5.6-sol`；成员线程按项目目录创建，`approvalPolicy: never`、`workspace-write`、不加载 Orbit MCP。
- 每次委托的事件顺序均为 `member_host_started` → `member_registered`（含 socket、宿主 PID／进程组、thread ID、模型）→ `member_delegated`（`turn/start` 之后）。成员记录在 `turn/start` 前已写入任务状态。

## 1. 结果回到原 Root 并集成（任务 `2c9569a2`）

- Root 实现 `calc.py`、`test_calc.py` 后，用 `kind: codex` 委托成员运行测试并生成 `member-report.md`。成员完成（`gpt-5.6-sol`），其原生观测包含实际命令输出；运行进程确认成员后台终端为空且 turn 已结束，结果经 Root 现有通道回传（`member_result`、`sent_message_ids` 增加）。
- Root 收到结果后核对了报告、比对成员记录的前后哈希（`0825f76…`、`6958a83…`）并独立重跑测试，确认成员未修改产物；`orbit stop` 后任务 `paused`，Root 停止与成员宿主进程组退出均确认，宿主目录已清理。

## 2. 执行中中断与后台工作退出（任务 `f8a9da7d`）

- 成员工作中存在两个 app-server 登记的终端：`python3 -m http.server 8767` 与前台 `python3 -c 'import time; time.sleep(600)'`（检查时两者均在原生 `thread/backgroundTerminals/list` 中，进程与端口可见）。
- 执行中提交 `orbit stop` 后：成员停止证据 `turn_interrupted: true`，两个终端 `terminated: true`，`remaining_terminals: []`，成员状态回到 idle；残留进程为空、端口 8767 不再监听；成员宿主进程组退出确认、目录清理；任务 `paused`，Root 停止确认。

## 3. 运行进程异常退出后的显式停止重试（任务 `d8d03598`）

- 成员带着登记终端（`http.server 8768` 与 `sleep 600`）工作时，对任务运行进程执行 SIGKILL：任务记录仍为 `running`、记录的 `runtime_pid` 已不存在，成员宿主仍在、成员 turn 仍 active，Root 会话仍在。
- 显式 `orbit stop` 走重试路径（记录状态为运行中但运行进程已消失）：重新连回 Root 并确认停止，从任务记录重连成员宿主，`turn_interrupted: true`、登记终端 `terminated: true`、`remaining_terminals: []`；随后宿主进程组退出确认、目录清理，任务 `paused`，原因为 "The user requested cleanup after runtime exit"。无残留进程。

## 验证中发现并修正的接口缺口

1. 面向新 app-server 的成员禁用 Orbit MCP 覆盖（`mcp_servers.orbit.enabled=false`）在基础配置没有该服务器时产生 "invalid transport"；改为任务自有宿主不再传该覆盖，成员边界其余不变。真实失败任务 `b1202b9b` 的停止重试随后核对宿主进程组已不存在并以 `paused` 收尾。
2. 刚创建、尚无用户 turn 的成员线程无法绑定（`thread/turns/list` 返回 "not materialized yet"）。改为经未绑定的宿主连接发起 `turn/start`；绑定只在读取结果时进行。停止路径将该错误识别为"没有需要中断的执行"（`no_materialized_turn`）；真实失败任务 `74ac9e93` 由重试确认（宿主仍在 → 关闭并核对进程退出，任务 `paused`）。
3. macOS 在进程组只剩未回收的僵尸子进程时对 `kill(0, -pgid)` 返回 EPERM。停止核对先回收本进程的子进程再复检进程组，避免把"无权限"当成停止证据，也避免把已退出误报为仍存活。

## 会话历史保留

- 三个成员线程均为非 ephemeral，宿主关闭后在 `~/.codex/sessions/2026/09/18/` 留下 rollout 文件（`rollout-2026-09-18T14-07-07-01a0b320….jsonl` 44 行、`…14-08-54-01a0b321….jsonl` 26 行、`…14-10-02-01a0b322….jsonl` 25 行）。
- Root OpenCode 会话在任务暂停后仍在原 pane 中保留完整对话；任务目录保留原文、依据与状态。

## 未覆盖与未知

- 本次只验证 OpenCode Root → `kind: codex` 一条路径；同宿主 `native` 委托保持原行为，其他 kind、Herdr 控制、通用注册中心未验证，不列为受控。
- 停止范围仍是登记成员的原生执行与宿主可跟踪的后台终端；脱离宿主管理的进程不在声明范围。
- 成员模型调用量由 Codex 侧会话承担，任务记录只保存检查 tokens；本次未把成员消耗归入任务费用。
- 测试覆盖：`npm test` 18 项通过（新增 Codex 成员登记顺序、结果回传、停止证据规则，以及运行进程消失后的 stop 重试）。

# DSH 真实模型验收（2026-10-20）

范围：隔离 `DSH_HOME` 下的 Root 真实模型 + 独立检查者真实模型，一次 hello.txt 交付。使用桌面版 DSH 0.2.1-rc.2，未改用户 `~/.dsh`。

## 环境

| 项 | 事实 |
| --- | --- |
| app home | `/tmp/orbit-real`（web 模板派生，装入 `@zeen/orbit` 单包） |
| checker home | `/tmp/orbit-real-checker`（sdk 模板 + 只读 overlay） |
| 模型 | `deepseek-account/deepseek-flash`（Root 与 checker 相同路由） |
| 凭据 | 将 `~/.dsh/.credentials.yaml` 只读复制到两个隔离 home（0600），验收后删除副本；原文件未修改 |
| 检查者 | `dsh-sdk` 子进程，独立 profile/home，只读 sandbox，读固定快照 |
| 驱动 | `tests/host_conformance/orbit-real-probe/index.js`，创建 standard preset Root，按脚本提示驱动工具 |

## 实际结果

- Root（真实模型）调用 `orbit start`、`declare`，用 write 工具写出 `hello.txt`（5 字节 `hello`），调用 `orbit check`。
- 检查者（真实模型、独立子进程）读取固定快照 `snapshots/check-1-*`，返回 `verdict=complete`、`delivery.ready=true`、`coverage.complete=true`、无 finding；摘要记录 hello.txt 的 5 字节与 SHA-256。
- Root 随后派发并登记了一个成员，`finish` 后 `accept`，再 `orbit complete`。
- 终止状态：`complete`；`completion.checkNumber=1`、`artifactDigest` 与检查快照一致；`stop/confirmed` 的四项证据均为 true；成员 `completed`。
- 事件链：`task/created → work-unit/declared → check/requested → finalization/notice → check/completed → member/registered → member/settled → work-unit/finished → work-unit/accepted → completion/requested → stop/confirmed → task/completed`。

## 证明与边界

证明：真实 Root 能驱动受控任务；检查者在独立进程/独立 home/只读快照上用真实模型完成结构化判定；完成门与实际停止证据可闭合；单包 bundle 在隔离 profile 中运行。

未证明：真实检查发现缺陷后的纠正回合（冻结验收 #1）、真实停止中断场景（#2）、多任务并发/重启、校准后的 JEV 选型、Loom 整链、发布安装路径。凭据复制方式只用于本地验收，不作为生产凭据方案。

证据目录保留在 `/tmp/orbit-real`（任务记录、快照、归档、驱动日志），未提交仓库。

## 冻结验收 #1：真实缺陷纠正

场景：Root 先写入错误内容 `goodbye`，检查者应发现并要求纠正；Root 改为 `hello` 后重新检查并完成。

实际结果：

- check #1：真实检查者 `verdict=continue`、`delivery.ready=false`、finding `hello-txt-wrong-content`，理由明确指出快照中的内容为 `goodbye`、不含 `hello`。
- Root 读取 finding 后修正 `hello.txt`，发起 check #2。
- check #2：`verdict=complete`、`ready=true`、无 finding、`resolved=1`。
- 最终 `complete`，`completion.checkNumber=2`；停止证据四项全 true。
- 事件序列保留两次 check、`finalization/notice`、成员登记/结算、finish/accept、completion 与 stop 确认。

结论：真实模型下的“独立检查发现真实缺陷 → Root 修正 → 再次独立检查通过 → 完成”闭环成立。该次只有一个明显缺陷，不覆盖多缺陷或争议裁定。

## 冻结验收 #2：真实停止中断

场景：Root 启动任务并用 bash 执行 `sleep 120`，外部 CLI/socket 在 8 秒后请求停止。

实际结果：

- stop 请求返回 `fence=armed`；宿主取消 Root、等待 idle、结算成员、核对检查在途。
- 任务在约 1 秒内变为 `paused`，`stop.confirmation.confirmed=true`，`missing=[]`，四项证据全 true。
- `ps` 未发现残留 `sleep 120`；没有新增模型调用；Root 会话使用 `keepInbox` 取消，上下文保留。
- 事件：`stop/requested → stop/confirmed {status: paused}`。

结论：真实运行中的停止能在有界时间内确认，后台 bash 动作被实际终止。该次未覆盖成员执行中停止、检查者进程在途或宿主崩溃后的 `stop_unconfirmed` 重试。

## 追加：成员执行中停止

场景：Root 真实模型 start + declare 后，用 subagent 派发一个成员执行 `sleep 120`；外部 CLI/socket 在成员运行约 10 秒后停止任务。

实际结果：

- `member/registered` 记录成员与 work unit，成员会话在 stop 前已开始执行。
- stop 请求后任务 `paused`，`stop.confirmation.confirmed=true`、`missing=[]`、四项证据全 true。
- 成员被记为 `stopped`（`member/settled`），Root 与成员会话均产生归档。
- `ps` 无残留 `sleep 120`。
- 事件：`member/registered → stop/requested → member/settled {stopped} → stop/confirmed`。

边界：宿主用 `agent.cancel + whenIdle + settle` 收束成员，未直接持有并 dispose 子 Agent 的 `SubagentActivation`；本次用进程空闲与无 `sleep` 残留作为证据，不宣称 activation 级 dispose 已验证。

## 追加：检查者执行中停止（失败关闭）

场景：Root 真实模型 start/declare/write 后调用 `orbit check`；驱动在检测到 `check/requested` 后延迟 1.5 秒或 6 秒，用 CLI socket 停止任务。

实际结果（两次一致）：

- stop 请求落围栏后，任务最终为 `stop_unconfirmed`，`stop.confirmation.confirmed=false`，`missing=["root_idle","checks_settled"]`；
- 检查记录仍为 `in_flight`；宿主没有把停止伪装成已确认，也没有把检查记成通过；
- 说明：真实检查者进程启动/发布 activation 的窗口长于本次停止时机，宿主拿不到可 dispose 的 activation，因此按合同保持未确认。

结论：检查者启动期间停止会**失败关闭**为 `stop_unconfirmed`，这是预期语义；本次未取得“已发布 activation 被 dispose 后转 paused”的真实证据。后续可用慢速假检查者或更长时序补测。

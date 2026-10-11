# 独立验收核查 — 安装体积精简真实矩阵终态（2026-10-11）

- 核查者：Root 之外只读独立核查（本会话）。模式：只读；未修改被测状态、未催办 SUT、未启动其他进程/模型。
- 对象：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-slim-82nka8ra/fixtures/` 下 positive-v2 / negative-v2 / positive(v1) / interrupt-v2 / interrupt(v1) 的任务原件，及 `docs/reference/evidence/install-footprint-optimization-20261011/` 的对应回执副本。本报告全部事实为本次直接读取；Root/成员自述仅作对照，不单独当证据。
- 结论：positive-v2 的完成与停止链、negative-v2 的 findings/resolution、positive v1 与负例 v1 的诚实失败保留、interrupt-v2 的 Esc 诚实边界及源码一致性均成立。无阻断项。未发现 checks/3（见 §1 边界）。

## 1. positive-v2（实质 task/hub 交接正例）

任务 `…/fixtures/positive-v2/.orbit/tasks/40911d14-3d71-484a-ba29-5a2d9b403d33`，work unit `wu-2e3411410400ee15`。

- 原生 hub 事件（collaboration.jsonl）：seq 12 成员（`orbit-5e9e2865-f177-4c1d-81c3-f389f6aa60d2`）hub_call 完成报告（127 验收用例、退出码 0、完整命令原文）→ seq 13 hub_result ok "Delivered to Main."；seq 15 Main 回执 → seq 16 hub_result ok。seq 14 `work_unit_tool_blocked`：成员 `wait` 工具被 work-unit 范围拒绝——范围控制在真实运行中生效。
- 原生模型回执（native-model-calls.json，schema `orbit-native-model-calls-v1`）：26 个调用全部 `finalized:true`，`gaps: []`。Root 侧 `zhipu-coding-plan/glm-5.3-flash`，成员侧 `kimi-code/k3-256k`（oauth credential，provider_response_id、usage_status reported 齐全；样例调用 input 7410/output 354/cacheRead 2048/total 9812）。
- Root 原生核验（root-verifications.jsonl，10 条，source `omp_native_tool_result`）：含 npm test 观测回执，出现 "127 cases passed; integer precision and CLI verified"。
- `member_result_recorded`（events.jsonl seq 34，04:41:05Z）：thread `orbit-5e9e2865…`、status completed、delivery `work_unit_acceptance`；work unit 随后 `accepted`。
- 快照检查（真实独立检查，两次）：
  - checks/1（opencode-go/deepseek-v4.1-flash）：`ok:false`，`review_ran:true`，problems "final message is not valid JSON"，state 记 verdict `check_failed`（exit 1）。失败被诚实记录为检查失败，未计通过；即便失败尝试也验证了工具面（active 仅 glob/grep/read、无禁止工具、confined read 生效、fingerprint before==after）。
  - checks/2（kimi-code/k3-256k，04:42:20 起，pid 83752 已退出）：`ok:true`，verdict `complete`，findings 0，coverage complete（逐项 verified，引用 importer.mjs 行级证据与 root_verification 回执），delivery ready true；4 次调用合计 92,058 tokens。两次检查 fingerprint before==after，均为 `sha256:1ddd8ecdf2f8…`，与 root_verification（04:41:07）及 completion_readiness 的 artifact_digest 一致——固定快照全程未变。
- 终态（我直接重读 state.json，非引用通知）：`status:"complete"`；`stop_confirmation.confirmed=true`（native_owner Main，`status_after:"idle"`、`active_tools_after:0`、`async_jobs_settled:true`；成员确认 idle/async settled；collaboration_persistence observed_through 16 == written_seq 16、failed_observations 0、recorded_gaps 0）；`completion_readiness.status:"complete"`；`runtime_pid` 键已不存在；state.checks 共 2 条。
- 边界：**不存在 checks/3**——checks/ 目录只有 1、2，state.checks 长度 2；最终有效检查记录即 checks/2。checks/1 的模型判读质量属模型输出失败（JSON 协议），其 103,766 tokens 用量如实入账。127 用例的实际执行由原生回执证成，我未重跑 npm test。

## 2. negative-v2（一文件负例：findings/resolution）

任务 `…/fixtures/negative-v2/.orbit/tasks/a079fb15-9bec-4589-a8d2-e18776db0361`，status complete。

- checks/1 verdict `correct`（对负例即正确识别未达标），2 条结构化 findings：f1 要求/evidence/action 齐全（evidence 引用 normalize.mjs 原文 `trimStart()` 与 SPEC "removes whitespace at both ends" 的差异及失败断言）。
- checks/2 verdict `complete`、findings 0——修正后复核通过。findings→resolution 链完整。

## 3. positive v1 / negative v1（失败与取消的诚实保留）

- positive v1（`64807db8-040c-46c6-ae41-9c94c46b5267`）：state `paused`、completion_readiness `stopped`、stop_confirmation confirmed（idle）；events 停止原因记录 Root turn 被中断。计划文档如实记因：PATH 缺系统 shell，成员多次尝试被正式命令范围拒绝，取消并确认全部停止、关闭 pane，**未冒充协作成功、不计正例通过**。
- negative v1：错将独立检查派成 task，取消且 confirmed stop，不计负例通过（计划文档记录）。失败/取消样本均保留，未改写为通过。

## 4. interrupt-v2（Esc 未触发的诚实边界与源码一致）

任务 `…/fixtures/interrupt-v2/.orbit/tasks/83741b70-ea7b-4006-b74a-7752149f5d55`。

- 要求（interrupt-requirement.txt）：sample.txt/SPEC.md 只读一致性核查 + 请求手动终检 + 符合后确认停止。
- 事件链：check_started → check_finished verdict `complete`（快照仅两文件、未修改、未派发成员、receipts artifact_matches）→ `stopped`（confirmed idle、async settled）→ `completed_via_finalized_stop`。events 中**无任何 Esc/interrupt 触发记录**——实际发生的是正常完成 + 停止确认，不是按键中断成功。
- 诚实边界有据：`docs/plan/orbit-install-footprint-optimization.md` "活动 Root/成员 Esc 已确认暂停与停止；空闲 Root 的 Esc 未触发检查器取消，单列边界，不计取消通过"；`docs/plan/debt-ledger.md` "空闲 Root 的 Esc 不等同任务暂停……不能把按键发送回执当停止成功"。
- 源码一致：Orbit 检查器取消的实现是进程组信号（`lib/orbit/check_runner.rb:1130,1139` `Process.kill(signal, -@run.pgid)`）；`lib/orbit/` 与 `plugins/` 中无 Esc 处理路径。Esc 是宿主 TUI 对活动会话的输入，空闲 Root 时不会进入检查器取消链路——实测行为与源码一致，边界记录成立。interrupt v1（check_failed→continue→complete）与 interrupt-v2 均如实保留。

## 5. 回执副本核对

`docs/reference/evidence/install-footprint-optimization-20261011/tasks/positive-v2/`（checks/、collaboration.jsonl、events.jsonl、native-model-calls.json、requirement-coverage.json 等）与 `positive-v2-final-state.json` 存在；final-state 内容（complete/confirmed true/async settled/runtime_pid 无）与我直接读取的 live state 一致。副本核对时点：Root 收尾（关闭 pane、卸载临时安装）之前。

## 6. 未覆盖与边界

- 不重跑任何测试/检查；checks/2 的模型判读内容（逐行代码评述）未由我重新裁判，我核实的是协议、结构、回执与停止链。
- 临时安装卸载与 pane 收口由 Root 收尾中进行，本报告不以卸载结果为事实；固定进程保留按 Root 通知为后续事项。
- 本会话（核查者）自身用量不在本报告内，由 Root 从会话原生记录提取。

## 身份

- 会话配置身份：provider `zhipu-coding-plan`，model `glm-5.3-flash`，reasoning `high`（workstation 配置标注）。

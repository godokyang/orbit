# ORBIT-CHECKER-STARTUP-02

2026-10-12，Loom Root 委托，基线 `fd9779ff2a06754462f1bcf5fe8a4350f7a2cd95` / Orbit 0.8.7 / 集成合同 1.4。范围为零新增模型的只读诊断与必要修复；不另建 Goal。此前 0.8.7 的提交、推送、安装授权已执行完毕；用户随后通过本票发布收尾授权明确允许提交、推送与本机更新。此次按 patch 规则升至 0.8.8，以区分包含阶段日志的新安装构建；合同仍为 1.4。提交身份见 Git 历史，安装回读与更新日志保存在下述证据根的 `release/`。未打 tag 或额外发布。

## 结论与原件

Loom 原件位于 `.loom/local/evidence/orbit-glm-results/`：`first.json` 至 `sixth.json`、`during-check-export.tar.gz`、`check-ended-export.tar.gz`。目标任务 `99f45320-8448-43e5-86f9-55c03d935ebe`。

- 运行中导出的 `task/checks/1/evidence.json` 已有 `session_created=true`、`review_ran=true` 和 GLM provider invocation 的 pending 回执。因此不是模块尚未加载或检查尚未进入。
- OMP 18.9.0 CLI 的 startup watchdog 等待 trusted extension factory 返回；Orbit 的 factory 在内部运行私有检查并有意保持 pending，等待父进程收尾。外层没有活动 startup span 时显示 `module load / pre-phase work`，该提示不能定位私有检查的阶段。已下载对应 18.9.0 npm 源码核对 `main.ts`、`extensibility/extensions/loader.ts`；没有 fork 或修改 OMP。
- `provider proxy resolved / source: none` 是代理环境变量来源，不是凭据不存在。原件证明凭据预检与会话建立已完成；没有据本机 discovery 连接拒绝推断根因。
- check 1 于 09:55:38 UTC 结束，`terminal=failed`、`failure_kind=invalid_result`、`stale=false`、`input_current=true`。9 条 checker 回执均为 `zhipu-coding-plan/glm-5.3` / reported；`session_disposed=true`、`host_completion=complete`。首条 provider 回执结束于 09:54:06.616 UTC，包含 reported output 49,808；这解释了耗时发生在检查执行阶段，但不是延迟、输出量成因或实际计费的证明。
- 最终 `raw_text` 长 1,727 字符，JSON 在零基位置 1,726 报 Extra data，剩余恰为 `}`。模型返回格式错误，现有拒收正确。不修剪多余字符、不放宽 JSON 合同、不把失败检查改成成功；退出 143 是父进程完成收尾机制的一部分，不单独证明崩溃或未启动。

## 本票改动

仅为 `runners/omp-reviewer/reviewer.ts` 增加私有诊断阶段：catalog、credential、session creating/ready、prompt、provider stream/turn、disposing、complete。同步写入既有 evidence 的 `reviewer_phase` / `reviewer_phase_at` 并输出固定阶段日志，不记录提示、响应内容、私有推理或密钥。`complete` 仅表示尝试结束，成功仍由原来的 `ok`/结果校验决定。对外能力和合同版本不变；集成方仍通过公开 status/export 取证，不将这些内部字段作为冻结 API。

这是诊断误导的改进，**没有解决或认证 GLM 长等待与格式输出问题**。当前 0.8.7 的公开 export 已可读到 session/usage/problems 原件，可据此区分未建立会话、调用 pending 和最终结果失败。

## 验证与收尾

本票证据根：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-checker-startup-6gt2jhdo`。

- `zero-host/verification.json`：真实已安装 OMP 18.9.0，隔离 host_probe，未提供 model/prompt；`ok=true`、session created/disposed、`review_ran=false`、`usage=null`。完成后仅保留自有 factory 11 秒，确实再现外层错误阶段提示；新的 phase 日志已经显示 complete。随后只向自有进程组发 TERM，退出 143，进程组消失。
- `runner-test.log`、`authorization-test.log`、`usage-test.log`：既有 runner、授权边界测试通过；15 项用量回执测试通过。未为日志改动新增机械单测，未跑全套或模型验收。安装依赖仅在隔离 snapshot；首次 `npm ci --prefix` 受 npm 路径处理影响失败，改用实际 snapshot cwd 后通过，保留两份日志。
- 保留源码快照、对应 OMP npm 源码与零模型原件供审核；无自有存活进程。没有控制 Root 的 PID、重查/停止其任务、读密钥、改全局账户或模型池。原运行停止由 Loom Root 经正式入口处理；旧 `0595af38` 未触碰。

用户后续明确收束为阶段日志，不再探针或修复模型格式输出。该票不代表 Loom 总 Goal 或真实 GLM 检查验收通过。

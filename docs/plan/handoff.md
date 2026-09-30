# Orbit 当前交接

最后核对：2026-09-30（0.7.25 已提交安装、pair3 终态入档、pair4 mixed 观察中）。Goal **未完成**；本页是当前交接入口，历史运行从既有 reference、Git 和下面原始目录查阅，不重开已经结束的票。

## 目标与用户决定

完整实现并真实验收[混合模型交付主方案](mixed-model-delivery-proposal.md)，按[附属代码审计](mixed-model-delivery-code-audit.md)逐项闭合，完成条件见[当前计划 W1—W10](vision-completion-plan.md)。有限顶级模型资源下保持交付质量，让其他模型承担合适工作，减少用户介入。模型仍会幻觉、偏移、越界、遗忘；系统靠可验证任务、权限、回执、独立检查及纠正控制这些风险，不承诺模型绝不出错。

- 一次完整交付，不设硬预算。选型删除速度、时间和本地耗时评分；运行计时、缓存时效及停止控制不是选型信号。
- `orbit omp` 就是启动命令。`explicit_orbit` 是内部请求分类，不是另一启动需求。普通业务请求须自主进入合适的受控／协作路径，不依赖用户再次说“用 Orbit”或逐次安排成员。
- OpenRouter 给任务相关能力先验，Jev 给任务判断；未校准不能自动正向推荐。OpenRouter 价格不是 OMP 价格；未知费用、用量、额度归属保持未知。
- Codex 编排、集成和审核；复用用户授权的 Herdr OMP 执行者，不自动换内部子 Agent。源码／合同语义改动同步权威文件。
- 本地提交及必要收尾已授权，不推送、发布、购买额度或升级 OMP。失败证据不改判。

## 精确版本与工作区

- **安装 0.7.25（当前生效）**：`orbit version --json` 已复核，clean source `7f572e87a63faa530c82a96c8586316c23f48d3c`（dirty false）；digest `0e0deba496544c4d05db1ac6f1317c44c64564e7ae2f3108774b5dacc7ade933`，installed_at `2026-09-30T16:44:03Z`（安装窗口 `16:43:47Z → 16:44:06Z`，`install.exit`=0，单次）。OMP／reviewer **18.3.4 未升级**。原件 `/private/tmp/orbit-release-0.7.25-delivery/`（`before.json`／`postcommit.json`／`after.json`／`install.{log,exit}`）；**83 个 pack 随包文件与当前提交源逐字节全匹配**（mismatch=[]；docs/tests 不在 npm pack 分发清单内，如实不记失配）。提交 `7f572e8`（恰好 11 文件：A/B 修复 8 文件＋host.mjs 三处 work-unit 必填文案＋package/shrinkwrap，+346/−9）。**组合验证**：178 个 git-tracked 文件全量冻结 pre/post 一致；恢复 run 的权威 `npm-test-recovery.exit=0`（wrapper 前台 `$?`，172 行日志 120 PASS 0 fail、尾 `INSTALL_TEST_PASS`）；`check:version`／`pack`／`diff-check` exit 0；validator（正确绝对路径 skill-creator 脚本，uv run）"Skill is valid!" exit 0。**第一次全量退出无法验证**（kqueue 原件未存 e.flags，data=3 无法排除 EV_ERROR/errno 情形；SIGQUIT 未证，原因未知——见 `orbit-native-handoff-025-combined/kqueue-decode-correction.json`）；证据目录 `/private/tmp/orbit-native-handoff-025-combined/`。
- **上一版历史（不再生效）**：安装 0.7.24（`59eb7e7`，digest `02067f58…`，15:32:10Z）；安装 0.7.23（`5d5a497`，digest `919d5f87…`）；安装 0.7.21（`fffabf80`，digest `ae9ce431…`）。各版结论只在各自构建与场景内有效。
- **0.7.23 组合验证（提交前，已通过）**：full／pack／validator／version／diff-check 全部 exit 0，129 个源／测试／打包文件逐文件 SHA 一致（非仅汇总断言）；证据 `/private/tmp/orbit-regression-0.7.23-gu0Ouq/`。该目录内 `run.out` 是宿主 `setsid` 不可用的**启动失败原始记录**（当时未执行 npm），不是测试失败；`run-recovery.out` 才是本次 full。**decision-3 放行重签**：Root 2026-09-30T13:57:50Z 独立审核（审核者 w1Y:p1A，实现者为 Q）；17 个真实样本逐字保留（samples SHA256 `5a30130a022abd2bc1b35a6ebe61c2ea4fe0e750cafbb0d23d6d51de973d03cc`，共享 call_id、非 17 次新调用、未新 API 校准）；结构 load 通过，旧 -2 副本明确不匹配。

启动增量冻结 SHA256：

| 文件 | SHA256 |
| --- | --- |
| `plugins/omp-host.mjs` | `fdbffecb67ede14a3b50bd3fc5b2ef31fc70a73ed7661516b9534b9cd11433ff` |
| `contracts/task-runtime.md` | `cfb554d07a6ef0c95ec5c9a8114a84fe1012cf49bd67b4aa51448ed04718459d` |
| `tests/omp_native_gate_test.mjs` | `b0c7ad25b7e008a26d16093198127bff6fbc95def22e9181843ffafbc9617a28` |

该增量在首个可扩展 provider 请求中给受控 Root 工作单元引导（不依赖入口概率，显式与自动入口一致；未受控会话与成员不注入），合并注入、不可扩展保持待发、事实记录首次明确编辑前的单元状态；没有直接程序派发、扩大权限或更改质量排序。前轮独立审查的两项缺口（advisory 早退出吞掉同窗 bootstrap、system 与 payload 同句重复）已修复并复核；已知剩余边界：sent 集合仅进程内；按 Q minor 更正，**不得泛称“所有重启都会重注入”**——非本进程 owned 的记录会被 `host.ownsTask` 拒绝，只有该活动任务被新进程实际重新 owned 时才可能再记一次首达事实（幂等指引，接受）。gate 绿不等于组合回归或实机验收。上表为 bootstrap 三文件冻结值（合同行含选型句修改）；bootstrap 与 policy 均已冻结，不再写入。

## 受控串行交接合作政策（自 0.7.24 起交付，0.7.25 沿用）

- **原生指令冲突已确认（源码规则分支＋shape／config 探针证据，非 wire 证据）**：OMP 18.3.4 对 `revision >= 6` 的类规则给 `delegation-bias restrained`（`pi-catalog/src/compat/rules/classes/openai.kdl:42`）；`pi-coding-agent` 在该分支渲染 inline-first 系统文案（`system-prompt.ts:992` `inlineFirstDelegation = restrained && !eagerTasks`，本机无 `task.eager` 覆盖 ⇒ 生效；文案含「NEVER delegate one slice」「2+ independent slices」），与主方案 §5.2「有界单成员串行接力」冲突。只读调查与探针：`/private/tmp/omp-delegation-bias-investigation.json`（含 `.omp` 配置层更正与 `evaluate` 分支说明）。**实际 wire 请求体未落盘，因此不宣称服务器已收到该文案、也不宣称模型心理因果**；这是可执行源码冲突加两轮实测行为一致（phone `01f4925b`、pair2 `d623e8b1` 均 `members=0` 自行实施）。
- **已交付修复（0.7.24 实施并安装；0.7.25 沿用）**：受控 Main Root 在实际 owned＋活动＋runtime alive 的**每个可达 provider 请求**上，于与原生 system／developer **同层**处注入合作政策——可承载位置为 Responses／Codex `instructions`、Anthropic 顶层 `system`（string／blocks）、messages 中既有 `system`／`developer` 原生消息的文本末尾、Responses `input` 中既有 developer 块的原生文本之后；请求内按 marker 幂等；不可识别形状**静默跳过**（不落用户消息尾、不伪称已送达）；不 force 所有任务派发、不代替 Root 的 native `task`、不改用户要求／目标项目规则／工具权限。契约与理由：`contracts/task-runtime.md`、ADR-009 §6.3。首次成功只记一条**本进程内「任务＋政策版本＋渠道」**事实（渠道、版本、任务／会话／型号、文本指纹，`delivered_claim` 明示仅“extension 修改了该载荷”，不含 server 回执或遵循主张），不存请求体／凭据。
- **独立复核**：Q 预部署审 `/private/tmp/orbit-policy-fix-review-q/review.json`（15:15:41Z，PASS_limited_scope_with_one_finding，四项冻结 SHA 复核、三入口 owned/liveness 边界、四分支不可变性与 SDK 形状来源逐项核对）；F-1（messages 承载 developer 角色原生 system 时漏口）已修，增量复核 `addendum-f1-fix.json`（15:20:53Z）**PASS 无新 finding**；`metadata-correction.json`（15:23:05Z）仅勘正 addendum 中一位 hex 誊写与把“== expected”并入值的记录问题，**原件不覆写**。gate 真实日志：`/private/tmp/orbit-policy-fix/gate.log`（首失败，属测试解析而非实现）／`gate2`／`gate3`／`gate4`（均 exit 0，互不覆盖）。
- **边界**：政策不改变 Jev 题义／阈值／decision-3／17 个校准样本，不改 selector 标签；不得因本修复勾选 W1—W10 或宣称自主派发已通过。

## 最小链路的最新事实

1. **真实 Jev API 一次调用成功**：`/private/tmp/orbit-minimal-dispatch-jev/` 原包／回包，HTTP 200，实际 `jev-1.13.0`，`jev-delegation-4`／`jev-selection-input-2`；handoff_fit 0.95、member_task_fit 0.20，input 1647／output 40。该输入没有候选和先验，不能据此判派发失败，也不是派发证明。不要重复同一诊断付费调用。
2. **installed 0.7.21 最小明确交接链已 complete＋confirmed stop**：任务 `26935a3e-fe59-4c74-a2ec-9bc89a272c83`，目录 `/private/tmp/orbit-minimal-chain-PbtkHC/product/.orbit/tasks/26935a3e-fe59-4c74-a2ec-9bc89a272c83`。工作单元 `wu-da565586044f6c8c` 先声明；实际成员 `zenmux/deepseek/deepseek-v4.1-flash` 派发并 accepted；Root 核验固定九例（一个测试组 pass 1／fail 0）；独立 reviewer 同型号、另一进程，终检 complete／coverage complete；Root 与成员停止确认 active_tools 0、async_jobs_settled true。README／package／test 三份固定材料 SHA 未变，全局候选池 SHA 未变。
3. 上述新事实观察保存于 `/private/tmp/orbit-minimal-chain-PbtkHC/controller/handoff-observation.json`；原始 work-units／collaboration／root-verifications／check evidence 仍需新 Root 在需要时核对，不仅相信摘要。
4. **此轮明确要求交接，且只有一个隔离池候选**，只证明该最小机械链可工作；不证明普通需求自主派发、完整池选型、纠正分支或节省资源。启动增量没用于此轮。
5. **最小链资源后验（Root 复核）**：`/private/tmp/orbit-minimal-chain-PbtkHC/controller/resource-post-audit.json`（只读汇总原件）：36 次调用全部 `reported`、call_id 唯一；`native-model-calls.json` 24 条（root 17＋member 7）与 `resource-calls` 1:1 命中，checker 4 条在 `resource-calls` 与 `checks/1/evidence.json` 两处 id 集与用量一致；三组 input+output+cacheRead 等于 provider 报告的 totalTokens，cacheWrite 为 provider 报告的 0（非未知）；reasoningTokens 是单独报告的子集、未另加总；judgment 服务只报 input/output。**billing 与 account 仍未知**，该摘要不证明普通派发、池选型或任何收益，也不推翻下节负例；文件清单逐项 SHA 存于其 `sources_sha256`。**该文件内的 `recorded_at_utc_machine_clock` 是手写估计、时间元数据未核实**（纠正记录：`/private/tmp/orbit-quality-decision-3-impl/install-preflight-timestamp-correction.json`），不据此重标原事件时间、不改原账本。
6. 该轮同时是 **native hint 采纳与成员结算的有限证明**（accepted＋hint adoption＋complete＋confirmed stop）；**其旧负例（p26、`02a5eda7`、`1d977642` 等）原样保留，不改判、不重标。**

## 普通请求真实任务（installed 0.7.23）

任务 `01f4925b-84e2-4560-9a26-20cf1bb5294b`，目录 `/private/tmp/orbit-ordinary-phone-1XOIXp/product/.orbit/tasks/01f4925b-84e2-4560-9a26-20cf1bb5294b`；结构化后验 `controller/terminal-audit.json`（2026-09-30T14:28:58Z，hash／pid／time 全部取自原件，不手写）。

- 原生会话 `01a0f2af-f4ea-7138-9e8a-4c2186d40d70`；请求原文不提 Orbit（`request/ordinary-request.txt`，sha256 `925ed6d4…`），入口分类 `uncertain` → 判定 `start`（`orbit-entry-rules-3`／`orbit-entry-3`／`input-2`／`decision-2`），实际判断模型 `jev-1.13.0`、`answered`；原生消息 `d14d7f47`。任务 14:21:21Z 建立。
- 首个可扩展 provider 载荷记录了 bootstrap 指引（`via: provider_payload`、`work_unit_state: none`）；首次明确 `edit` 前的单元状态同为 `none`（带真实 `tool_call_id`，无 delegation 字段）。**SUT 选择自行实施**（原文“我会自行处理…”），`work_units=0`、`members=0`、无 `members.json`。
- 检查 3 次：1 为 `opencode-go/deepseek-v4.1-flash` 失败（provider Go 429；该次用量 `usage_status: unknown`）；2（自动）与 3（手动）为 `kimi-code/k3-256k`，均 `complete`、findings 0；3 于 14:25:57Z 完成，通知 1 次，Root 自行 stop，14:26:09Z 读到 `complete`＋`confirmed`（`active_tools_after 0`、`async_jobs_settled true`、`status_after idle`）。三次检查 `fingerprint_before == fingerprint_after`、只读、无禁用工具。
- 选择 basis 为 `pool_order_unreleased`：**任务在放行 profile 内，且发生了真实付费判断**（2 次 `jev_checker_selection` `answered`，`judgment_model jev-1.13.0`、decision-3、`requirements_error: null`；task `review.selection` 记 `task_fit_scores["zenmux/deepseek/deepseek-v4.1-flash"]=0.55`），但**无候选过 0.6 门**，因此降级池序。**本轮只证明降级与失败后的有界重选，不证明 decision-3「过门后稳定池序」的正向排序；也不是域外任务。**
- 资源账本（仅本任务）：judgment 8 次（input 14854／output 382）；`root/gpt-6-sol` 19 次（totalTokens 301050）；`checker/k3-256k` 5 次（totalTokens 54277）；`checker/deepseek-v4.1-flash` 1 次用量 unknown。**现金与账户归属仍未知。**
- 独立评估：外部 copy `evaluation-copy` 跑固定 9 例 `npm test` **exit 0（9 pass／0 fail）**；三份固定材料（`README.md`／`package.json`／`test/phone.test.js`）与全局池 SHA 未变（`fixed_sha256`、`pool_sha256 4eafb0a4…`）。
- 元数据纠正：`launch-current.json` 的 `seed_head` 曾手写誊抄错误（`…e974…`），实际 `git rev-parse` 为 `f59f7d0bf5e9479d5aa08e848e97324b215e00be`；纠正记录在 `controller/launch-current-corrections.json`（原文件保留、未重跑、未改 SUT），另记 `instruction.txt` 与请求文件 sha256 并存属末尾换行差异（`equal_strip_final_newline: true`）。
- 边界：**members=0 只说明 Root 选择自行实施，不是自主委派证据，也不构成收益结论**；该 pane 已原生退出并关闭，launch pid 87232 与后续 87289／87405 经 Root 实测不存在，未执行 kill；其 cleanup 记录可由 Q 复用。

## pair2 mixed 臂（普通自主交接核心验证，已成历史记录：complete＋confirmed stop）

原件：`/private/tmp/orbit-reconcile-pair2-6Caerb/`（`controller-records/{launch-current.json,terminal-audit.json,exit-submit.json}`、`root-sessions/`、`mixed/`）。

- 启动（`2026-09-30T14:35:09Z` 记录）：`herdr pane run` 于复用的空闲 shell `w1Y:p26`（命名 `reconcile23core`），命令取自 `FREEZE.arms.mixed.command`，**pid 27206**（进程 args 中 release `e06179ef…`＝0.7.23）。fixture `mixed/`（head `e6085adf…`、tree clean、固定四文件 SHA 存 `fixed4_sha256`、业务 prompt sha256 `dbd4569e…`）；session 目录 `root-sessions`（product 之外），会话 `01a0f2bd-1f7c-740a-b7f7-ee3382f8e738`。
- 任务 `d623e8b1-9d51-4bef-ba7d-8359bd3f7341`：`created_at 2026-09-30T14:35:19Z`，**终态 `complete`，`stop_confirmation.confirmed = true`**（`status_after idle`、`active_tools_after 0`、`async_jobs_settled true`）。终态事件链：`automatic_check_complete_ignored` → `finalization_notice`（14:43:25Z，check 3，version `sha256:ebd6de83…`）→ `completion_stop_queued`（14:43:32Z）→ `completed_via_finalized_stop`（14:43:36Z）→ `stopped`（14:43:36Z，confirmed）。终端后验 `terminal-audit.json` 生成于 **14:44:49Z**。
- 入口与 bootstrap：原生消息 `8eec046e`、分类 `uncertain` → `start`、`jev-1.13.0`、`delegation_value 0.83 ≥ 0.65`（`execution_authorized 0.97`、`supervision_value 0.51`）；`bootstrap_guidance` 事实为 `via: provider_payload`、`work_unit_state: none`；首次 `edit` 前 `unit_state_before_edit = none`。advisory 的实际送达**无法从持久原件独立复核**（会话 jsonl 中 `orbit-entry-advisory` 计数 0；该通道设计不留 fact record），不写成已送达证明。
- 检查 3 次（同一快照前后不变）：1 为 `opencode-go/deepseek-v4.1-flash` `check_failed`（该次用量 `usage_status: unknown`，原样保留、不重标）；2（自动）与 3（手动）为 `kimi-code/k3-256k`，均 `complete`、findings 0。
- 资源（仅本任务，账本口径）：judgment `jev-1.13.0` **10 次**（input 22762／output 492）；`root/gpt-6-sol` **19 次**（totalTokens 388911）；`checker/k3-256k` **6 次**（totalTokens 86974）；`checker/deepseek-v4.1-flash` 1 次用量 unknown；reasoningTokens 为单独报告子集、未另加总。**现金与账户归属仍未知。**
- **进程与现场**：原生 `/exit` 已执行一次（`exit-submit.json` exit-code=0，agent `idle`）；pid 27206／27262／27322 经 Root 再核 ps 均已消失，Herdr agent list 已无 `reconcile23core`；`w1Y:p26` 回到 shell 并保留、不关闭。
- **自主委派负例（保留）**：`members = 0`、无工作单元记录、无 native task 派发、无 `delegation_hint`。Root 首条明文自行依据：“这两个实现文件的契约由同一份 README 和验收测试约束，我会自行完成，避免拆分时重复协调”。**本轮不称自主交接通过**，也不构成收益证据。当前下一步是**只读调查 native 委派规则的生效分支**（为何在有交接入口信号时 Root 选择直接实施）；**尚未证实根因**，不写成已定位。
- Q 外部副本验证已完成：固定 8 tests **8/8**、冻结 6 probes **6/6**，各一次 **exit 0**（`controller-records/external-{evaluation.json,npm-test.log,probes.json}`；评估记录生成 **14:59:13Z**；harness SHA256 `6391e77c82dbec1d40d53bc945f4a947694960f17b21ab1be2de7d157997d3ac`、probe source SHA256 `e4358173adf65ba72e98bce71f71cd4ef50c510488773939ab73e836dd6ece39`）；**主件在外部副本执行、原件未改**，该 PASS **不改 `members=0` 的自主委派负例**。baseline 臂未启动，资源对照未做。

## 自主派发真正缺口与资源风险

- 只读调查 `/private/tmp/orbit-autonomous-dispatch-audit/autonomous-dispatch-evidence.json`：0.7.20 没有 entry advisory 实现；0.7.21 fresh 显式请求没有触发其概率前提。两次都在实现前没有工作单元，后一次推荐出现于实现后的 provenance 单元。**不能说 Root 忽略了已送达的派发指导，也不能说 Jev 服务一直不工作**。
- 宿主 `before_agent_start` 发生在自动建任务之前，而首次 `before_provider_request` 建任务后原来只尝试概率条件下的 advisory。该启动接缝的修复已随 installed 0.7.23／0.7.24 生效，并在 phone、pair2 两轮的首个载荷留下 `via: provider_payload` 记录。**已确认原生指令存在冲突并已针对性修复**：源码可确认的是规则分支（`revision >= 6` → delegation-bias `restrained` ⇒ inline-first 文案）与主方案 §5.2 的串行交接冲突，以及对应 shape／config 的探针输出；**旧两轮 `members=0` 的因果不能由静态推定**，也不主张服务器已收到该文案或模型必然遵循（实际 wire 未落盘）。 0.7.24 已按同层政策修复（见上节）。**仍未闭合的是真实自主验收**：phone／pair2 两轮实测都是 `members=0`、Root 自行实施；pair3 已终态（complete＋confirmed stop）且无成功成员交付（见下条）；pair4 实际 hint 采纳已证（observation-2 时点），成员交付／终检／停止仍在等待——限定该观察时点，其后无新观察不作 current 状态推定。
- 质量正向过门后，可信可比成本分支按成本优先；成本未知／不可比分支决策语义已实现（实现者 Q）并随 installed 0.7.23 生效：过门候选保持调用方稳定输入（池）序，不称便宜或可靠，未知不免费。decision-3 放行由 Root 独立审核后重签（证据边界见上节）。普通 phone 任务 `01f4925b` **有匹配的放行与真实付费判断**（2 次 `jev_checker_selection` `answered`，`judgment_model jev-1.13.0`、decision-3、`requirements_error: null`），但**无候选过 0.6 门**（唯一有分 `zenmux/deepseek/deepseek-v4.1-flash` task-fit 0.55），故当时降级池序：**那次只证明降级**。**phone／pair2 未触发该正向排序；pair3 本次 selection 已触发并直接核对**（state `member_selections[wu-56f0622023bf4fa6]`，released `orbit-quality-decision-3`、`member_task_fit` 门 0.65；候选 quality：index0 0.21、**index1 K3 0.66**、index2 0.15、index3 0.22、**index4 Zen 0.70**、index5 0.38；`positive_ids`=[K3(index1), Zen(index4)]，`first` 仍为 K3、backup Zen，`cost_comparison: unknown`、basis `released_task_fit`）。该结果与“稳定池序、不按最大质量”一致；**真实 hint 采纳与成功成员交付仍未证**。 池顺序不等于便宜；升版本并审计放行绑定、不重标旧分数的约束保持。
- 最小链资源后验（36 调用全 `reported`、call_id 唯一、checker 两账本一致、reasoningTokens 子集未另加）见上节与 `/private/tmp/orbit-minimal-chain-PbtkHC/controller/resource-post-audit.json`。该摘要**只汇总账本**，**不证明普通派发或任何收益**，不推翻下节负例。**未知口径按该摘要原文范围**：现金／实际扣减桶未知（`cash []` 只表示未知，不是 0 成本）；账户归属与 OAuth 归属是否可得**以原件报告各任务范围为限**，本页不把它概括成“全部原生账户缺失”，精确归属待 Root 复核原件后确认。
- **pair3 mixed 臂（已成历史记录：complete＋confirmed stop，非成功成员交付）**：`/private/tmp/orbit-reconcile-pair3-NXisvi`（controller／`FROZEN-SOURCE.json`；两臂 seed `beceae6b6c1b35d1003f48f62cb220eb0e7f6db8` clean；业务 prompt 逐字 `dbd4569e…`；冻结 8 tests＋6 probes 未改）。任务 `b91fe4de-9927-4aaf-883a-e59423845e4c` 终态 **complete＋confirmed stop**（`terminal-state.json` 15:57:15Z；进程已原生退出：Root 19954／MCP 19984/20097 Root 实测消失，pane 回 shell 不关闭）。实际链路（原件分层）：policy1 首层 facts（`instructions` 渠道、指纹 `9877cc7a…`）→ 15:44:12Z Root **自主声明** `wu-56f0622023bf4fa6`（首试 `write xd://orbit` 缺 task 报错→自行读 context 后成功；该文案缺口已随 0.7.25 host.mjs 三处 work-unit 必填文案修复）→ 首个 member_selection＝**TypeSafe Net::OpenTimeout 服务失败**（usage 未知，非有分 decline）→ 15:45:19Z 首派 `opencode-go/deepseek-v4.1-flash` 注册 → 15:45:21Z **native_turn_error 429 Go usage limit、实现前零改动**（member 终态 failed／result_delivery native_turn_error——真实首派/注册/失败，非成功成员交付）→ 15:46:03Z Root 自主 same-unit K3 重派被 bound 门拒（两断点诊断 `breakpoint-diagnosis-redispatch.json`：Seam A host 硬编码 v1 vs selector v2；Seam B native 错误结算不释放 unit——两处均已随 0.7.25 修复实施）→ 15:46:27Z Root finish failed（will implement directly）→ **15:46:30Z decision-3 真实触发**：two-stage 首次（15:46:30Z）recommended K3 .66／backup Zen .67（released、稳定池序）；state 最新为 15:49:51Z 时点 judgment（K3 .66／Zen .70）——两时点不矛盾，.67 仅属首次——**但 hint v2 无采纳——hint 后无实际派发；v1/v2 阻断另由源码确定**（Seam A 两断点与修复保留，见诊断）→ Root 自行实现并集成（checks：#1 deepseek 失败 usage 未知保留／#2 K3 complete findings 0）。外部副本 8 tests＋6 probes 各一次 exit 0（`external-evaluation.json` 15:57:58Z）。**资源（57 调用）**：19 jev-1.13（有用量）＋1 服务失败（model/usage 未知）；root 32（totalTokens 864067）；member Go 1 未知；checker Go 1 未知；checker K3 3（totalTokens 60492）。**account 分列**（`terminal-state-correction.json`）：root 32＋checker K3 3 **有 account_id 及 credential 关联**；20 Jev＋2 Go 未知——不泛称全部 account 未知；现金／扣减桶仍 unknown。baseline 未启动。
- **pair2 mixed 臂已完成该轮**（任务 `d623e8b1` complete＋confirmed stop，原件见上节），但 `members=0`、无工作单元与派发，**不构成自主派发证明**；其资源账本可如实列（judgment 10、root 19、checker k3 6、checker Go 1 unknown），**不作收益结论**。baseline 臂未启动，资源对照与同质量 Top／混合对照均未做。Q 的外部副本验证已完成（固定 8 tests 8/8、6 probes 6/6，各一次 exit 0，评估记录 14:59:13Z），但**不改本轮自主委派负例**。

## 必须保留的负例

- installed 0.7.20 配对 `/private/tmp/orbit-reconcile-acceptance-ucWZ9UmM/controller-records/paired-comparison.json`：两臂固定 8 测试／6 探针通过，mixed **members=0**，全部 GPT-6-sol 角色总量 376410 vs 289685，**约 +30%**；Root 单侧约 +7.9%。不宣称节省。多次检查属于同一 observation 的有界失败重选，包含真实额度／权限失败和非法结果。
- 0.7.20 成员负例任务 `1d977642`，`/private/tmp/orbit-member-settlement-live-6tGQlP/controller-records/postmortem.json`：Go 429 后替补真实 accepted、Root 8/8，但 amend 引起旧失败成员结算撤销而阻止完成；最终 paused＋confirmed stop，非业务完成。21 源码修复不能重标旧实测。
- 0.7.21 takeover 任务 `8e411be9`，`/private/tmp/orbit-takeover-fixture-1D6DEl/controller-records/postmortem-8e411be9.json`：真实 complete＋confirmed stop，**members=0**；多个真实 provider 故障后 Zenmux 检查成功。该轮不是成员自主或收益证明。
- 更早失败／部分完成继续留在[本次验收](../reference/mixed-model-real-acceptance-20260929.md)及 Git。不重跑已经有效且未受新改动影响的检查。

## 现场资源与所有权

2026-09-30 本次 Herdr live 发现如下；恢复时重新发现，不凭 pane 名判断可用：

| Pane | 角色与当前状态 |
| --- | --- |
| `w1Y:p1A` | 当前 Codex Root；新会话需明确接替编排，避免两个 Root 同时写／派发 |
| `w1Y:p1S` | S，DeepSeek Flash；policy 增量实现（含 F-1 修复）由其执行，402 reject_no_credit 后已停写释放路径；后续 0.7.24/0.7.25 的实现、提交与安装由 Q 承接，idle |
| `w1Y:p1Q` | Q，GLM；0.7.24/0.7.25 实现/提交/安装执行者与 policy 预部署审 PASS＋F-1 增量复核 PASS、SDK 委派偏置只读调查；现持 pair4 mixed Controller 票（观察中），不写产品源码（当前文档同步写者） |
| `w1Y:p1R` | R，当前 Grok；本轮报告工作区工具不可用，已明确停票（fixture 无文件产物，由 Q 接手），不再重试或写源码，idle；不能默认可用 |
| `w1Y:p27` | `ordinaryphone23`（installed 0.7.23 普通请求 SUT，任务 `01f4925b` complete＋confirmed stop）：**已原生退出并关闭**，pid 87232 经 ps 实测不存在；其 cleanup 记录可由 Q 复用 |
| `w1Y:p26` | 复用 pane：pair2 `reconcile23core`、pair3 `reconcile24core` 均已原生退出（pid 实测消失、pane 回 shell）。**pair4 mixed 臂运行中**：`reconcile25core`，pid **36581**（MCP 36613/36727）、release `a39256d24e1c840e2f126b9d`（0.7.25），任务 `028437c2-bd4b-4429-aa6b-88b9e6e19018`；pair4 根 `/private/tmp/orbit-reconcile-pair4-iW4p7Z`，`FROZEN-SOURCE.json`＋`controller-records/launch-current.json`（16:49:51Z） |

各 fixture 都把 controller／request／session 保存在 product 之外。phone、旧 minchain21 与 pair2 mixed 的 Root 会话**均已退出**，相关 pid 经 ps 实测不存在，未执行 kill。不要 kill 通用 OMP／Herdr，不批量删除临时目录；Q/R/S 是用户提供的执行者，不关闭它们。**Root 的检查范围**：installed identity（`orbit version --json`）、release-delivery 原件、policy gate／Q 审记录、pair3 `FROZEN-SOURCE.json` 与后续该轮的 launch／state／ledger 原件；不以本页摘要替代原件。

pair2 状态：mixed 臂已完成（complete＋confirmed stop）但 `members=0`，不构成自主派发证明；其 baseline 未启动。pair3：mixed 已终态（见上节），非成功成员交付；baseline 未授权。pair4：mixed 已由 Root 授权启动（028437c2，观察中——见 `launch-current.json`，只报已读阶段），baseline 未授权，资源对照未做。

## 新 Root 的顺序

1. 读取本页、主方案／代码审计／W1—W10、开发规则；核对 live 工作区与 installed identity，继承已有授权。
2. 复用最小链成功、Jev API 证据与最小链资源后验；收好本轮原件（release-delivery、gu0Ouq、ordinary-phone、pair2 terminal-audit）。pair2 mixed 已结束：**进程已退出，pane 回 shell 并保留**；除按需后验外不要重启该轮、不要删其原件。不要重复提交此前业务 prompt。
3. 安装已完成（installed 0.7.25，`7f572e8`；`sh install.sh` exit 0 单次；release-delivery 原件）；不再重复安装、不重跑组合验证、不升级 OMP（18.3.4）。旧 full 不覆盖本轮增量。
4. **当前优先闭合真实自主验收**（不因此缩掉其余 W 项）：pair4 mixed 臂运行中（`reconcile25core`，任务 `028437c2`），针对 0.7.25 两修复（同代 v2 hint 绑定、same-unit 失败重派）的 fresh 复验；只报已读原件事实；**不得称成功成员交付，直到实际接受、checks 与停止证据出现**；baseline 未授权；不诱导派发。判据仍是实际推荐→native task→登记→成员回传→Root 集成。
5. 闭合质量充分后分派与旗舰升级、可信路由成本／实际用量归属、错误控制、finding 纠正、当前版本手动终检与实际停止；decision-3 的“过门后稳定池序”已由 pair3 selection 真实触发（K3 0.66／Zen 0.70 过门、first 仍 K3），**hint 采纳链在 0.7.25 Seam A 修复前不可达**（pair3 v2 hint 未采纳不冒称）；pair4 正在复验该链；政策修复不替代这些验收，也不勾选 W 项。
6. 核心路径通过后再完成冻结的同质量 Top／混合资源对照，报告全部角色和未知量，按主方案 §11.3 调整负收益路径。逐项闭合 W1—W10、文档、收尾和本地提交后才 complete。

当前没有新的用户审批前置；不要把所有模型可靠性证明、外部发票或全型号认证另加成验收门。用户的 Goal 会话迁移不等于已完成或重新获得一份可以无限重复旧失败的资源额度。

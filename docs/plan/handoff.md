# Orbit 当前交接

最后核对：2026-09-30（0.7.23 本地提交＋安装完成、普通 phone 轮收尾后）。Goal **未完成**；本页是当前交接入口，历史运行从既有 reference、Git 和下面原始目录查阅，不重开已经结束的票。

## 目标与用户决定

完整实现并真实验收[混合模型交付主方案](mixed-model-delivery-proposal.md)，按[附属代码审计](mixed-model-delivery-code-audit.md)逐项闭合，完成条件见[当前计划 W1—W10](vision-completion-plan.md)。有限顶级模型资源下保持交付质量，让其他模型承担合适工作，减少用户介入。模型仍会幻觉、偏移、越界、遗忘；系统靠可验证任务、权限、回执、独立检查及纠正控制这些风险，不承诺模型绝不出错。

- 一次完整交付，不设硬预算。选型删除速度、时间和本地耗时评分；运行计时、缓存时效及停止控制不是选型信号。
- `orbit omp` 就是启动命令。`explicit_orbit` 是内部请求分类，不是另一启动需求。普通业务请求须自主进入合适的受控／协作路径，不依赖用户再次说“用 Orbit”或逐次安排成员。
- OpenRouter 给任务相关能力先验，Jev 给任务判断；未校准不能自动正向推荐。OpenRouter 价格不是 OMP 价格；未知费用、用量、额度归属保持未知。
- Codex 编排、集成和审核；复用用户授权的 Herdr OMP 执行者，不自动换内部子 Agent。源码／合同语义改动同步权威文件。
- 本地提交及必要收尾已授权，不推送、发布、购买额度或升级 OMP。失败证据不改判。

## 精确版本与工作区

- **安装 0.7.23（当前生效）**：`orbit version --json` 已复核，clean source `5d5a497ad3565d89b3f7193258c738ede81d03f4`（dirty false）；digest `919d5f87588176f83ba4f387f69da371a72d1ba663c0d10a9b2344cb9051d62d`，2026-09-30T14:17:32Z 安装（`sh install.sh` exit 0；**安装当时的 `git status` 为空**、安装时 HEAD 为 `5d5a497`，不表示当前工作区状态）。OMP／reviewer 18.3.4，未按 UI 提示升级。原件：`/private/tmp/orbit-release-0.7.23-delivery/`（`release-record.json`＝`orbit-install-4`、`install.exit`、`install.log`、before／after identity 与 git head／status）。
- **上一版历史（不再生效）**：安装 0.7.21（`fffabf80`，digest `ae9ce431…`，11:21:07Z）；HEAD 0.7.22（`1893fd7d`，已提交未安装，唯一组合 full exit 0，证据 `/private/tmp/orbit-regression-0.7.22/report.json`）。0.7.21／0.7.22 的实测结论只在各自构建与场景内有效。
- **0.7.23 组合验证（提交前，已通过）**：full／pack／validator／version／diff-check 全部 exit 0，129 个源／测试／打包文件逐文件 SHA 一致（非仅汇总断言）；证据 `/private/tmp/orbit-regression-0.7.23-gu0Ouq/`。该目录内 `run.out` 是宿主 `setsid` 不可用的**启动失败原始记录**（当时未执行 npm），不是测试失败；`run-recovery.out` 才是本次 full。**decision-3 放行重签**：Root 2026-09-30T13:57:50Z 独立审核（审核者 w1Y:p1A，实现者为 Q）；17 个真实样本逐字保留（samples SHA256 `5a30130a022abd2bc1b35a6ebe61c2ea4fe0e750cafbb0d23d6d51de973d03cc`，共享 call_id、非 17 次新调用、未新 API 校准）；结构 load 通过，旧 -2 副本明确不匹配。

启动增量冻结 SHA256：

| 文件 | SHA256 |
| --- | --- |
| `plugins/omp-host.mjs` | `fdbffecb67ede14a3b50bd3fc5b2ef31fc70a73ed7661516b9534b9cd11433ff` |
| `contracts/task-runtime.md` | `cfb554d07a6ef0c95ec5c9a8114a84fe1012cf49bd67b4aa51448ed04718459d` |
| `tests/omp_native_gate_test.mjs` | `b0c7ad25b7e008a26d16093198127bff6fbc95def22e9181843ffafbc9617a28` |

该增量在首个可扩展 provider 请求中给受控 Root 工作单元引导（不依赖入口概率，显式与自动入口一致；未受控会话与成员不注入），合并注入、不可扩展保持待发、事实记录首次明确编辑前的单元状态；没有直接程序派发、扩大权限或更改质量排序。前轮独立审查的两项缺口（advisory 早退出吞掉同窗 bootstrap、system 与 payload 同句重复）已修复并复核；已知剩余边界：sent 集合仅进程内，OMP 重启后活动任务会重注入一次（幂等指引，接受）。gate 绿不等于组合回归或实机验收。上表为 bootstrap 三文件冻结值（合同行含选型句修改）；bootstrap 与 policy 均已冻结，不再写入。

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
- 宿主 `before_agent_start` 发生在自动建任务之前，而首次 `before_provider_request` 建任务后原来只尝试概率条件下的 advisory。该启动接缝的修复已合入 **installed 0.7.23** 并在 phone 与 pair2 两轮的首个载荷留下 `via: provider_payload` 记录。**仍未闭合的是自主委派本身**：两轮都是 `members=0`，Root 依 bootstrap 的“自行实施依据”分支自行完成。**当前动作是只读调查 native 委派规则的生效分支**（有交接入口信号时 Root 为何选择直接实施）；**尚未证实根因**，先取有效原因，再做针对性修复与重验。
- 质量正向过门后，可信可比成本分支按成本优先；成本未知／不可比分支决策语义已实现（实现者 Q）并随 installed 0.7.23 生效：过门候选保持调用方稳定输入（池）序，不称便宜或可靠，未知不免费。decision-3 放行由 Root 独立审核后重签（证据边界见上节）。普通 phone 任务 `01f4925b` **有匹配的放行与真实付费判断**（2 次 `jev_checker_selection` `answered`，`judgment_model jev-1.13.0`、decision-3、`requirements_error: null`），但**无候选过 0.6 门**（唯一有分 `zenmux/deepseek/deepseek-v4.1-flash` task-fit 0.55），故降级池序：**这只证明降级，不证明 decision-3 过门后的排序**。池顺序不等于便宜；升版本并审计放行绑定、不重标旧分数的约束保持。
- 最小链资源后验（36 调用全 `reported`、call_id 唯一、checker 两账本一致、reasoningTokens 子集未另加；billing／account 全 unknown、未推费用）见上节与 `/private/tmp/orbit-minimal-chain-PbtkHC/controller/resource-post-audit.json`。该摘要只汇总账本，**不证明普通派发或任何收益**，不推翻下节负例。
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
| `w1Y:p1S` | S，DeepSeek Flash；bootstrap 增量交付、0.7.23 组合 full／pack（gu0Ouq）与本次文档同步（本票写者）均由其执行，已停写，无 npm 测试残留，idle |
| `w1Y:p1Q` | Q，GLM；bootstrap F1/F2 复核、选型排序审查、phone fixture 准备、policy decision-3 实现、最小链资源后验均已完成并停写；pair2 外部副本验证已完成（固定 8 tests 8/8、冻结 6 probes 6/6，各一次 exit 0，评估记录 `external-evaluation.json` 14:59:13Z），现进行 SDK 只读调查；不写产品源码，idle |
| `w1Y:p1R` | R，当前 Grok；本轮报告工作区工具不可用，已明确停票（fixture 无文件产物，由 Q 接手），不再重试或写源码，idle；不能默认可用 |
| `w1Y:p27` | `ordinaryphone23`（installed 0.7.23 普通请求 SUT，任务 `01f4925b` complete＋confirmed stop）：**已原生退出并关闭**，pid 87232 经 ps 实测不存在；其 cleanup 记录可由 Q 复用 |
| `w1Y:p26` | `reconcile23core`（pair2 mixed 臂被测 Root，installed 0.7.23，pid 27206）：任务 `d623e8b1` 已 `complete`＋confirmed stop，原生 `/exit` 已执行，pid 27206／27262／27322 经 ps 复查均消失、Herdr agent list 已无该 agent；pane 回到 shell 并保留、不关闭 |

各 fixture 都把 controller／request／session 保存在 product 之外。phone、旧 minchain21 与 pair2 mixed 的 Root 会话**均已退出**，相关 pid 经 ps 实测不存在，未执行 kill；当前无自有被测进程需要收尾。不要 kill 通用 OMP／Herdr，不批量删除临时目录；Q/R/S 是用户提供的执行者，不关闭它们；p26 保留为可用 shell。

pair2 状态：mixed 臂**已完成（任务 complete＋confirmed stop）但 `members=0`，不构成自主派发证明**；baseline 臂未启动，资源对照未做。下一步见「自主派发真正缺口」与「新 Root 的顺序」。

## 新 Root 的顺序

1. 读取本页、主方案／代码审计／W1—W10、开发规则；核对 live 工作区与 installed identity，继承已有授权。
2. 复用最小链成功、Jev API 证据与最小链资源后验；收好本轮原件（release-delivery、gu0Ouq、ordinary-phone、pair2 terminal-audit）。pair2 mixed 已结束：**进程已退出，pane 回 shell 并保留**；除按需后验外不要重启该轮、不要删其原件。不要重复提交此前业务 prompt。
3. 安装已完成（0.7.23，`sh install.sh` exit 0；**“工作区干净”只指安装当时**，不由它推断当前状态——本次文档同步本身即让工作区处于 dirty）；不再重复安装或重跑组合验证。旧 22／21 的 full 不覆盖本轮增量，如遇本版新问题按具体事件另行取据。
4. 自主委派仍未闭合（phone `01f4925b` 与 pair2 `d623e8b1` 均 `members=0`）：先完成**只读调查 native 委派规则的生效分支**，取到有效原因后再做针对性修复与重验——**不重复同类大任务、不诱导派发**。有效原因明确前不把任何猜测写成根因。
5. 闭合质量充分后分派与旗舰升级、可信路由成本／实际用量归属、错误控制、finding 纠正、当前版本手动终检与实际停止；新版问题／决策校准绑定保持真实。决策-3 的“过门后稳定池序”正向排序尚未被真实样本触发（phone 有放行与真实付费判断、但无候选过 0.6 门），需另有候选过门的真实样本才算验证。
6. 核心路径通过后再完成冻结的同质量 Top／混合资源对照，报告全部角色和未知量，按主方案 §11.3 调整负收益路径。逐项闭合 W1—W10、文档、收尾和本地提交后才 complete。

当前没有新的用户审批前置；不要把所有模型可靠性证明、外部发票或全型号认证另加成验收门。用户的 Goal 会话迁移不等于已完成或重新获得一份可以无限重复旧失败的资源额度。

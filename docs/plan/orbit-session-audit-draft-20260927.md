# Orbit 本会话流程盘点（临时记录，2026-09-27）

本文件是排查记录，不是产品合同、已批准计划或发布验收结论；审计范围与统计口径以以下原始记录为准。

## 已确认的问题：固定评审模型被误当作自动选模证明

真实委托 `.orbit/tasks/c293d58b-bb4c-48c0-bcd5-73e6096ee9a1/instruction.txt` 只要求用 Orbit 执行批准的计划，**没有指定评审模型**。验收控制者另外编写的隔离 OMP 夹具消息 `/tmp/orbit-live-acceptance-wAlxtU/project-smoke/.orbit/tasks/26d1a7c0-76ef-4c08-9bab-86a13939cd59/instruction.txt` 却要求「独立评审模型显式选 zhipu-coding-plan/glm-5.2」；首个连续任务的夹具消息也要求显式选择同一型号并在本 OMP 会话记住。这是测试控制者的模拟用户消息，不能写成真实委托者的授权。

隔离候选池只含 `kimi-code/k3-256k`，运行 `orbit model-status --project project-smoke` 报该精确身份 `evidence_status=absent`、`quality=not_judged`。自动启动不能选出有证据的评审者；夹具 Root 随后显式传入 `review_model=zhipu-coding-plan/glm-5.2`，任务状态记录 `review.selection.source=explicit`、`in_pool=false`。`lib/orbit/checker_model_selector.rb:61-76,151-179,263-309` 证明显式分支只预检隔离环境可解析性／凭据，绕过候选池证据和 JEV 评审模型质量排序。由此跑通的纠偏、终检和停止只能证明流程闭环，不能证明自动选模、不同模型家族复核或成本收益。`source=explicit` 表示工具参数，不证明真实用户亲自授权。

应将固定模型流程验收与自动选模验收分开；后者须使用精确身份、可核查的有效证据，缺证据就报告未验证，不以自选池外模型代替成功。现阶段不改产品语义，也不伪造模型质量、速度或费用数据。

## 范围、版本与可用记录

本次「本 session」以原生 OMP 会话 `01a0dc8e-eb6b-759f-954b-19119841e45f` 为边界；其本地会话日志为 `/Users/yangke/.omp/agent/sessions/-Personal-omen-orbit/2026-09-26T07-12-29-035Z_01a0dc8e-eb6b-759f-954b-19119841e45f.jsonl`。项目 `.orbit/tasks/*/state.json` 中恰有下表三项任务的 `connection.thread_id` 与它一致，三项均 `status=complete`、`stop_confirmation.confirmed=true`。同目录还存在无 `state.json` 的指令目录 `788fa062-2721-481a-892e-972a626f2bc4`，不能冒充第四项已启动任务；`/tmp/orbit-live-acceptance-wAlxtU/` 下的隔离夹具任务属于**别的 OMP 会话**，不计入下表。会话可跨进程恢复，同一个 session ID **不证明**全程加载相同插件 release。

`orbit --version` 本次实测为 **0.7.6**；本机 release 元数据中 0.7.5 安装于 `2026-09-26T07:12:03Z`，0.7.6 安装于 `2026-09-26T16:19:06Z`（`~/.local/share/orbit/orbit/releases/{f4c90de9002ef4c45d0f8f71,29753bb71943772f8d571462}/.orbit-release.json`）。下表第一项开始于 13:17，后两项分别开始于 16:20、17:25。源码工作树的 0.7.7 和先前隔离安装不可误算为这些任务的日常运行版本；历史文档中「当前日常 0.7.5」不是本次查询时的事实。

本次审计尝试在**不传显式评审模型**的情况下新建受控任务，当前安装返回 `no candidate pool model passed the JEV quality line`，所以没有新任务或新的实际成员；也没有为完成这份只读盘点绕过候选池。后文第四次 `task` 委派尝试因此同样被现有任务已结束的门拒绝。这个失败说明此次调查本身不属于上表的三项受控任务，不能以本临时报告冒充新一轮独立检查通过。

当前已有的**原始事实**是逐任务的 `.orbit/tasks/<id>/state.json`、`events.jsonl`、`members.json`、有记录时的 `collaboration.jsonl`、`checks/` 与原生 OMP 会话文件。`orbit status TASK --json` 查询单任务状态，`orbit export TASK --output FILE` 由用户主动生成单任务本地证据包，不上传；[使用参考](../reference/usage-reference.md#日常查询与诊断)、[导出记录](../reference/task-evidence-export-20260926.md)说明证据与隐私边界。仓内只读脚本 `.agents/skills/orbit-real-acceptance/scripts/summarize_task.rb TASK_DIR` 可汇总单任务检查／事件；**没有发现**现成跨任务、跨 OMP 会话的一键「复盘结论」文档或自动成本账单。以下数字是对上述三项原始 JSON/JSONL 按 session ID 聚合，不把状态的最近一次 Jev 评分当作全部次数。

## 三项任务的实际次数

| 任务（完整目录均在 `.orbit/tasks/`） | 评审运行 | 其中失效／失败 | Jev 任务内观察 | 实际纠偏投递 | 已登记成员 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `2a22d2d8-ddc6-4d69-b4bc-3fb1651dba58`，本地任务证据及导出 | 10 | 6／2 | 44 | 1 | 2 |
| `ae52b2b9-8c56-4ec7-95f3-5b15e3ffc7f5`，版本补丁、提交推送 | 3 | 1／0 | 8 | 0 | 0 |
| `c293d58b-bb4c-48c0-bcd5-73e6096ee9a1`，已批准运行体验计划 | 5 | 2／1 | 115 | 1 | 2 |
| **同一 session 合计** | **18** | **9／3** | **167** | **2** | **4** |

口径：`checks[]` 每个编号计一次，含自动检查和手动／显式重选后检查；其中 `manual=true` 为 7 次（真正以 `manual_check` 触发的 4 次，`review_model` 恢复检查 3 次），**不是** 7 次最终交付。三次失败分别是旧检查模型不在隔离目录（第一任务 #1）、两次评审结果 JSON 结构无效（第一任务 #7、计划任务 #4），失败项无可归属的 `usage`。9 次 `stale=true` 的结论不适用于当时的新版本，但其中一些提供了后来复查的线索，不能简单宣称全无价值。每项任务都有一次 `finalization_notice`，三项最终停止均经程序确认。依据：各任务 `state.json:checks,stop_confirmation`、`events.jsonl:check_started/check_finished/check_failed/finalization_notice/stopped`；运行了上述只读汇总脚本逐项复核。

**纠偏不是「出现问题的次数」：**三项检查结果中共出现 6 个不同 finding ID（第一任务 3 个、计划任务 3 个，版本任务 0 个），其中多条首先见于**失效检查**，并不等于 6 条已正式投递的当前问题。程序 `correction_sent` 只发生 **2 次**：第一任务 #9 的导出清单并发变化问题、计划任务 #3 的隔离 OMP 验收待补问题；`recheck_pending` 另有 3 次。任务结束时无开放 finding。第一任务 `events.jsonl`、计划任务 `events.jsonl` 是投递次数权威，不能按通知重复出现次数或 `resolved_ids` 重复列出次数加总。

**「卡住核实」明确分两层：**167 次 `jev_assessed` 都对 `stuck`／`off_track` 打了分，**不是** 167 次卡住核实。已安装 0.7.5／0.7.6 的 `lib/orbit/task_runtime.rb` 均规定连续两次 `max(stuck,off_track) >= 0.65` 或一次 `>= 0.85` 才触发 `:process` 检查；三任务实际最高 `stuck` 分别为 0.32／0.32／0.36，`off_track` 最高 0.26／0.25／0.40，达 0.65 的轮次 **0**、`kind=process` 的检查 **0**。另有 Jev 服务不可用事件 1 次（计划任务），它不是「卡住」。若「卡主核实」另指人工确认耗时，任务记录没有可归属的人工核实计数，应标**未知**而非填 0。

记录的评审用量三项依次为 1,835,397／201,257／3,752,888 tokens，合计 **5,789,542 checker tokens**；Jev 任务内第一阶段累计 input 696,438、output 12,358 tokens。失败检查 `usage=null`，Root 的任务级 `usage.tokens=null`，成员总费用与订阅账单也未知，因此这些是**已记录用量**，不是全会话完整 tokens 或人民币金额。计划任务 #2 单次记录 3,308,054 checker tokens（其中 `cacheRead=3,161,600`），不能将缓存读 token 直接折成货币。来源：三项 `state.json:usage,checks[].usage`。

## 多 Agent 协作：两批、四名，不是每个任务都有成员

原生 OMP 主会话日志中 `task` 工具尝试 **4 批**，只有 13:18 与 17:28 **2 批成功**，各启动 2 人；16:37 的 `FinalizeUX`／`RouteCost` 和本次盘点尝试的 `OrbitEventAudit`／`NativeAgentAudit` 均因当前绑定的 Orbit 任务已结束被同步拒绝，**没有创建这 4 名拟议成员**。三项任务的 `member_registered` 合计 4、`members[].status=completed` 4、Root 和成员停止确认均为 true；`member_result_recorded` 为 7 条**结果/更新事件**，不是 7 个不同 Agent。全部 4 名真实成员模型记录为 `zhipu-coding-plan/glm-5.2`、`delegation_basis=root_without_hint`：Root 两次均派发通用 `agent="task"`、**未指定模型**；实际模型由原生 task 角色解析，不能误写成 Root 明确选择 GLM，更不是 Jev 候选推荐。

| 实际成员（ID 前缀，完整 ID 见对应 `members.json`） | 任务与原始派发职责 | 记录结果 |
| --- | --- | --- |
| `orbit-26093672` | 第一任务：`plugins/omp-host.mjs` 的任务归属原生协作日志，保留派发与结果证据、跨重启序号和缺口标注。 | `completed`；Root 后续整合。 |
| `orbit-3ca3d581` | 第一任务：`lib/orbit/task_evidence.rb`、`lib/orbit/cli.rb` 的用户主动本地证据包导出、清单、时间窗与不可信路径约束。 | `completed`；检查者后续发现并纠正导出清单问题。 |
| `orbit-596a9758` | 计划任务：`plugins/host.mjs` 与模型选择器／CLI，显式检查模型的会话内记忆、逐次预检与逐候选精确诊断。 | `completed`；Root 整合会话选择路径。 |
| `orbit-f0a84bd5` | 计划任务：检查结果 `delivery.ready`、受限检查者及只读 Git 远端事实、必要回归。 | `completed`；后续按 Root 集成反馈修正显式远端目标。 |

成员职责取自原生主会话两次成功的 `task` 工具输入，结果与实际模型取自相应任务 `state.json:members`、`events.jsonl:member_registered/member_result_recorded`；原生主会话另有对这 4 人的 `write agent://…` **11 次**，不等同于 11 次派发。较早任务未有新格式 `collaboration.jsonl` 时，不能倒推每条原生 hub 消息已被持久记录；计划任务的 `collaboration.jsonl` 明确记录了 2 条 `task_dispatch` 及模型身份。

## 重大遗漏：通用 task 默认模型绕开了成员候选池

当前用户级候选池 `~/.config/orbit/model-candidates.json` 不包含 `zhipu-coding-plan/glm-5.2`。第二批开始前，`c293…/events.jsonl` 17:26 的 `model_evidence_needed.identities.candidates` 明列 5 个可派发池内模型（当前池的第六项是 Root 模型，按规则排除），**没有 GLM-5.2**；17:28 的 `collaboration.jsonl` 两条 `task_dispatch` 却均为 `agent="task", model=null, pinned_model=null`，两条 `model_identity` 随后显示实际运行的是 GLM-5.2。这 **2 个成员**可直接证明在当时走了池外默认角色。第一批的两名成员也实际是 GLM-5.2、原生工具参数同样未指定模型，且 13:52 的评审选模状态记录 GLM-5.2 `in_pool=false`，但**没有第一批 13:18 的候选池快照**，不能把当前池配置或晚 34 分钟的记录冒充当时的直接证明。第一批派发前 Jev `delegatable=0.30`，第二批派发前为 0.64 但仅请求候选证据、没有最终推荐；两批均未经过池内成员质量推荐。

已安装 0.7.6 的 `plugins/omp-host.mjs:1698-1745` 只对池生成的 `orbit-m-*` Agent 刷新／校验模型映射，原生 `agent="task"` 不核对候选池，`expectedModel=null`；同版 `lib/orbit/task_runtime.rb:732-770` 只事后登记模型和 `root_without_hint`。这不是 Orbit 自动推荐了池外模型，而是**没有模型选择的通用派发由 OMP 默认角色落到池外模型且没有池外告警**。现行[任务合同](../../contracts/task-runtime.md#可选-jev-调度)和 [ADR-009](../adr/009-user-selected-model-pool.md#决定)有意允许 Root 原生显式派发不受推荐池影响、用户明确指定池外模型优先；但这次 Root **没有指定 GLM 模型**，故不能称为用户明确授权的池外模型选择。若候选池对执行成员应是实际选模边界，这一默认旁路是高优先级产品语义／保护缺口，必须先裁决合同，再决定让无模型的通用派发选择合格池内成员还是失败并请求用户明确授权；不在本临时盘点中擅自改变运行程序。

默认模型的直接来源：本机现行 `~/.omp/agent/config.yml:6` 配置 `modelRoles.task: zhipu-coding-plan/glm-5.2`，2026-09-24 的[角色映射记录](../reference/model-cost-tier-analysis-20260924.md#本机-omp-入口)也记有相同值；`plugins/omp-host.mjs` 的 `memberModel()` 读取 `models.resolve('@task')`。这解释了 Root 只填 `agent="task"` 时为何四名成员实际落到 GLM-5.2，而不是 Jev 从池里选中了它。当前配置和旧记录不构成每次派发时配置文件未变的快照；实际模型以当时成员身份事件为准。

## 可优化处（观察 → 建议；不是本临时文档授权实施）

1. **优先处理成员池外默认派发及验收授权归属。** 两次通用 `task` 派发产生四名 GLM-5.2 成员，至少第二批两人明确不在当时候选列表；现有允许原生派发的设计不等于用户明确选了该模型。固定 `review_model` 的隔离测试也只能算评审流程闭环；真实用户未指定的型号不能标记为用户选择。模型 `source=explicit` 只记录工具入参，缺少能证明来自哪条真实用户指令的授权来源。池内自动正选择尚无本次构建 live 正例；按[本轮隔离验收](../reference/orbit-runtime-fix-acceptance-20260927.md)单列未验证，不用临时指定模型补洞。
2. **让重复缺证据提示不淹没任务。** 计划任务 `model_evidence_needed` **33 次**，模型身份及所需字段完全相同、提交证据 0 次。0.7.6 运行时 `delegation_signature` 包含产物摘要，变化后为同一身份生成新的请求签名；任务执行期间对真实变化重算可以保留，但面向 Root 的「请补这组公共模型事实」应按精确身份＋所需字段＋有效期去重，发生身份／要求改变才再次提示。这里是有证据的重复打扰，不等于省钱幅度已经测得。
3. **区分观察频率与有价值的卡住核实。** 167 次 Jev 任务观察没有一次达到过程检查门槛。已安装 0.7.5／0.7.6 的观察签名还包含可变的 `host.observations`；源码 0.7.7 的相应签名已去掉该噪声字段并要求可辨认变化后再评估，但本会话的 167 次来自旧安装，**不能凭静态代码推断升级后的节省量**。复验须使用明确内容摘要的新隔离构建和相同任务型的事件计数；不要自动升级日常安装。
4. **减少对持续变化的快照反复评审。** 18 次检查有 9 次失效、3 次失败，且计划任务一次检查缓存读量很大。将工作的自动计时检查与「Root 已交付的最终手动检查」分开计数；对真正仍在变化的产物按现有状态／签名延后完整计时检查，而不跳过用户需要的终检。源码 0.7.7 的此类节流已有实现，仍须与旧版同口径实测，不能把不同夹具的 token 比值宣称节省率；结果 JSON 无效与目录不可用应按故障恢复而非产物纠偏统计。
5. **保留可追溯记录，不默认做自动复盘。** 现有 `status --json`、`export`、本地汇总脚本足以回溯一项任务，但缺跨任务 session ID 汇总和清晰的「纠偏通知 vs finding vs Jev 卡住评分」口径。先把汇总口径固定在只读报告；导出可能包含任务指令与原生会话内容，继续由用户指定路径并主动分享，不自动上传或调用模型生成缺陷结论。

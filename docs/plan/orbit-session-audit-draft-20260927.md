# Orbit 本会话流程盘点（临时记录，2026-09-27）

本文件是排查记录，不是产品合同、已批准计划或发布验收结论；审计范围与统计口径以以下原始记录为准。

## 本轮新增独立夹具检查者池内降级真实闭环

本轮修改后的源码仍标 `0.7.7`，隔离安装在 `/tmp/orbit-pool-fallback-VQ4csdYf/`，`orbit version --json` 报 `content_digest=f0802cd6f36bd140952733b0de4eba7b5cbf946569bf6fdae9af05b9b2979f35`、commit `197d39764c4e47b5c763b4dd975743547c6320ed`、dirty、安装于 `2026-09-27T05:02:45Z`。独立 Git 夹具 `project/` 的隔离 `XDG_CONFIG_HOME` 仅加入 `zhipu-coding-plan/glm-5.2`，没有提交该精确身份模型证据。新 OMP 18.3.2 原生会话 `01a0e13f-b68d-72da-80c4-4a4c676b87cf` 的控制者只要求给 `notes.txt` 追加一行、经独立检查后完成，**未指定 `review_model`，没有池外授权**；这是独立夹具用户消息，不是原始真实委托的型号指令，原先失败启动未重试。

已安装 Orbit 原生 `start` 返回 `review_model=zhipu-coding-plan/glm-5.2`、`selection_tier=fallback`、`notice=候选池降级选择：独立检查模型质量未经证实`。权威目录 `/tmp/orbit-pool-fallback-VQ4csdYf/project/.orbit/tasks/3980289d-4241-428c-9388-4bf7b93b02e0/` 的 `state.json:review.selection` 记录 `source=candidate_pool`、`basis=pool_order_unknown_fit`、`quality_score=null`、`task_fit_scores={}`、唯一 `unscored_candidates`；没有 Jev 检查者选模调用，不会把缺证据假报成 0.03 或质量合格。`orbit status TASK` 同时显示降级警告和未完成状态。Root 实际改动并核对 `notes.txt` 的单行差异，手动终检 #1 在独立只读 checker 中使用池内型号，`verdict=complete`、`delivery.ready=true`、`findings=[]`、`stale=false`、checker `total_tokens=12138`；收到 `finalization_notice` 后 Root `stop(intent=complete)`，最终 `state.json:status=complete`、`stop_confirmation.confirmed=true`。会话正常退出（exit 0）。这证明**缺证据池内自动选择可连通真实终检与停止**；不证明另一个低分型号在 Jev 新问题下的真实评分、多个型号的排序、相对质量或成本优势，也不将它挪作原用户授权。

本轮完整 `npm test` 通过（Ruby／Node／Bun 及安装回归），`npm pack --dry-run --json` 57 文件，`git diff --check` 通过。确定性回归另覆盖低分 0.03 仍选择池内可运行型号、无证据与 Jev 故障降级、高分首选隔离不可运行时换可运行池内备选、全池隔离不可运行才带失败判断记录拒绝、池外型号仅经原生用户精确授权；这些**不是**上述 live 样本。未更新日常安装、未发版。

## 本轮新增独立夹具：Root 补检查者证据后真实重评与终检

另一新 OMP 18.3.2 会话 `01a0e159-3b19-7522-a97d-9bf926e3cd0c` 运行于隔离 `/tmp/orbit-pool-fallback-VQ4csdYf/project-evidence/`，安装的仍是源码 0.7.7 临时构建，`content_digest=637870d544bb19e12e999c7ae5e422dba164231f8c89bd837a4de31bdd97f608`、安装于 `2026-09-27T05:31:33Z`。隔离候选池只有 `zhipu-coding-plan/glm-5.2`，缓存起初没有这个精确身份的证据；夹具原生用户消息只要求完成一行文本变更、遇检查者缺证据查一手资料并如实提交、独立终检通过后结束，**没有 `review_model` 或池外授权**。自动入口创建任务 `a0925d7a-39da-471b-bce9-8844a4ec2df9`，`start` 显示 `evidence_needed=[{"model":"zhipu-coding-plan/glm-5.2","status":"absent"}]` 和 Root 补证步骤；任务没有因缺证据而拒绝池内可运行型号。

Root 实际访问 `z.ai/subscribe`、`zcode.z.ai/en/docs/configuration`、`z.ai/blog/glm-5.3`、`modelscope.cn/models/ZhipuAI/GLM-5.2/summary`，通过 `orbit model-evidence TASK_DIRECTORY --file -` 提交精确型号事实和计费路由；缓存只读查询转为 `valid`。随后一次手动独立检查**开始前**，选模器重新调用真实 TypeSafe `jev-1.13.0`、问题版本 `jev-checker-task-fit-1`，记录质量适配 **0.54**、时间分 **0.11**、`evidence_needed=[]`，仍只选池内该型号并标记 `selection_tier=fallback`（0.54 未达到正向优先 0.55），没有借证据直接声称质量已过门。只读终检 #1 `verdict=complete`、`delivery.ready=true`、零 findings、`stale=false`，记录 **25100** checker tokens；Root 收到通知后提交 `stop(intent=complete)`，最终 `status=complete`、`stop_confirmation.confirmed=true`、会话退出 0。权威状态和事件位于 `/tmp/orbit-pool-fallback-VQ4csdYf/project-evidence/.orbit/tasks/a0925d7a-39da-471b-bce9-8844a4ec2df9/`。

实机 Root 传了任务目录，旧安装的运行时一边将事实写入用户缓存供检查者重评，一边误记一条成员用的 `model_evidence_ignored`；因此这个 live 样本**不证明任务内确认文案正确**。随后源码仅针对当前任务 `review.selection.evidence_needed` 精确匹配的事实改为记录 `checker_model_evidence_submitted`，原有无请求成员证据仍忽略；该修正由确定性任务运行时回归验证，**未重新安装做第二次真实模型复验**。另一条推荐的无任务目录提交不经过成员请求门。这个夹具证明 Root 查证、缓存生效、检查前重评及独立终检／停止闭环；不证明复杂任务下多型号比较的质量或省钱幅度，也不是对原始失败启动的重试。


## 历史排查确认的问题：固定评审模型被误当作自动选模证明（旧选模语义）

真实委托 `.orbit/tasks/c293d58b-bb4c-48c0-bcd5-73e6096ee9a1/instruction.txt` 只要求用 Orbit 执行批准的计划，**没有指定评审模型**。验收控制者另外编写的隔离 OMP 夹具消息 `/tmp/orbit-live-acceptance-wAlxtU/project-smoke/.orbit/tasks/26d1a7c0-76ef-4c08-9bab-86a13939cd59/instruction.txt` 却要求「独立评审模型显式选 zhipu-coding-plan/glm-5.2」；首个连续任务的夹具消息也要求显式选择同一型号并在本 OMP 会话记住。这是测试控制者的模拟用户消息，不能写成真实委托者的授权。

隔离候选池只含 `kimi-code/k3-256k`，运行 `orbit model-status --project project-smoke` 报该精确身份 `evidence_status=absent`、`quality=not_judged`。自动启动不能选出有证据的评审者；夹具 Root 随后显式传入 `review_model=zhipu-coding-plan/glm-5.2`，任务状态记录 `review.selection.source=explicit`、`in_pool=false`。`lib/orbit/checker_model_selector.rb:61-76,151-179,263-309` 证明显式分支只预检隔离环境可解析性／凭据，绕过候选池证据和 JEV 评审模型质量排序。由此跑通的纠偏、终检和停止只能证明流程闭环，不能证明自动选模、不同模型家族复核或成本收益。`source=explicit` 表示工具参数，不证明真实用户亲自授权。

当时应将固定模型流程验收与自动选模验收分开；后者不得以自选池外模型代替成功，也不得伪造模型质量、速度或费用数据。本轮新源码的缺证据池内降级与实机闭环另见上节；不覆盖此处旧构建失败事实。

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

当时已安装 0.7.6 的 `plugins/omp-host.mjs:1698-1745` 只对池生成的 `orbit-m-*` Agent 刷新／校验模型映射，原生 `agent="task"` 不核对候选池，`expectedModel=null`；同版 `lib/orbit/task_runtime.rb:732-770` 只事后登记模型和 `root_without_hint`。这不是 Orbit 自动推荐了池外模型，而是**没有模型选择的通用派发由 OMP 默认角色落到池外模型且没有池外告警**。当时的[任务合同](../../contracts/task-runtime.md#可选-jev-调度)和 [ADR-009](../adr/009-user-selected-model-pool.md#决定)允许 Root 原生派发不受推荐池影响，但 Root **没有指定 GLM 模型**，不能称为用户明确授权。此段是 0.7.6 安装的历史观测；后续源码改动见下节，不改写已有证据。

默认模型的直接来源：本机现行 `~/.omp/agent/config.yml:6` 配置 `modelRoles.task: zhipu-coding-plan/glm-5.2`，2026-09-24 的[角色映射记录](../reference/model-cost-tier-analysis-20260924.md#本机-omp-入口)也记有相同值；`plugins/omp-host.mjs` 的 `memberModel()` 读取 `models.resolve('@task')`。这解释了 Root 只填 `agent="task"` 时为何四名成员实际落到 GLM-5.2，而不是 Jev 从池里选中了它。当前配置和旧记录不构成每次派发时配置文件未变的快照；实际模型以当时成员身份事件为准。

## 可优化处（观察 → 建议；不是本临时文档授权实施）

1. **优先处理成员池外默认派发及验收授权归属。** 两次通用 `task` 派发产生四名 GLM-5.2 成员，至少第二批两人明确不在当时候选列表；现有允许原生派发的设计不等于用户明确选了该模型。固定 `review_model` 的隔离测试也只能算评审流程闭环；真实用户未指定的型号不能标记为用户选择。模型 `source=explicit` 只记录工具入参，缺少能证明来自哪条真实用户指令的授权来源。池内自动正选择尚无本次构建 live 正例；按[本轮隔离验收](../reference/orbit-runtime-fix-acceptance-20260927.md)单列未验证，不用临时指定模型补洞。
2. **让重复缺证据提示不淹没任务。** 计划任务 `model_evidence_needed` **33 次**，模型身份及所需字段完全相同、提交证据 0 次。0.7.6 运行时 `delegation_signature` 包含产物摘要，变化后为同一身份生成新的请求签名；任务执行期间对真实变化重算可以保留，但面向 Root 的「请补这组公共模型事实」应按精确身份＋所需字段＋有效期去重，发生身份／要求改变才再次提示。这里是有证据的重复打扰，不等于省钱幅度已经测得。
3. **区分观察频率与有价值的卡住核实。** 167 次 Jev 任务观察没有一次达到过程检查门槛。已安装 0.7.5／0.7.6 的观察签名还包含可变的 `host.observations`；源码 0.7.7 的相应签名已去掉该噪声字段并要求可辨认变化后再评估，但本会话的 167 次来自旧安装，**不能凭静态代码推断升级后的节省量**。复验须使用明确内容摘要的新隔离构建和相同任务型的事件计数；不要自动升级日常安装。
4. **减少对持续变化的快照反复评审。** 18 次检查有 9 次失效、3 次失败，且计划任务一次检查缓存读量很大。将工作的自动计时检查与「Root 已交付的最终手动检查」分开计数；对真正仍在变化的产物按现有状态／签名延后完整计时检查，而不跳过用户需要的终检。源码 0.7.7 的此类节流已有实现，仍须与旧版同口径实测，不能把不同夹具的 token 比值宣称节省率；结果 JSON 无效与目录不可用应按故障恢复而非产物纠偏统计。
5. **保留可追溯记录，不默认做自动复盘。** 现有 `status --json`、`export`、本地汇总脚本足以回溯一项任务，但缺跨任务 session ID 汇总和清晰的「纠偏通知 vs finding vs Jev 卡住评分」口径。先把汇总口径固定在只读报告；导出可能包含任务指令与原生会话内容，继续由用户指定路径并主动分享，不自动上传或调用模型生成缺陷结论。
6. **区分本会话记录缺口与既有运行限制，不做旧日志兼容或回填。** 第一项任务发生在 `collaboration.jsonl` 接入之前，缺少该文件仅表示无法证明每条原生协作消息都已持久化；旧任务按已有证据读取／导出，并如实标明缺失，不合成历史事件、不增加旧格式适配层。更一般地，异常退出前未完成的异步事件写入可能丢失可恢复证据。用户显式覆盖配置使成员 park 后，OMP 缺少 dispose 完成信号，后台退出只能保持 `stop_unconfirmed`，不能拿成员已完成或 registry idle 充作确认。这两项是[当前限制台账](debt-ledger.md)中的残余边界，**不是**本次四名成员已观察到的停止失败；不能仅靠本次完整停止记录宣布限制解除。

## 实施后复核（源码 0.7.7；旧会话不热更新）

- `plugins/omp-host.mjs` 的受控 `task` 门对通用 Agent 解析当前 `@task` 精确型号、核对现时用户池；池外仅认可本任务原始或其后的真实原生用户消息独立一行 `Orbit authorization: member_model=provider/id`，并保留消息 ID／警示及可得的注册／首次 provider 模型漂移核对。Root 工具入参和另一夹具的文字不能代替本次真实用户授意；未授权默认拒绝。确定性原生门测试覆盖池外拒绝、消息授权与池内派发，**此审计旧会话中没有新建任务或成员**。
- `lib/orbit/model_authorization.rb`、CLI、TaskRuntime 和 OMP 工具面将显式检查者型号绑定到真实用户消息的精确 `review_model=provider/id` 或会话范围 `review_model_session=provider/id`，缺来源拒绝并保留诊断；Root 自传 `review_model`、环境变量、旧的 `source=explicit` 均不够。会话沿用逐任务再核消息与隔离环境，不把先前夹具控制者消息当作本次用户的授权。前述旧显式选模的流程闭环仍是历史事实，**不是新增来源门或池内自动正选择的真实成功样本**。
- 同一证据身份集合和所需字段的提示不再随产物/宿主观察变化重复提交；证据有效性变化后再允许请求。Jev 的周期无新事实不反复评分与 Root 活跃时纯定时完整检查节流在本次源码改动前已存在；本轮不伪造升级后的节省率，不影响手动终检。
- 已实际运行 `scripts/orbit session-summary --thread 01a0dc8e-eb6b-759f-954b-19119841e45f --project .`：汇总 **3** 项旧任务、**18** 次检查（失效 **9**、失败 **3**、`manual=true` **7**）、Jev 观察 **167**、过程检查 **0**、纠偏投递 **2**、finding **6**、成员 **4**、证据请求 **33**；第一项协作日志列为 `missing`，不会倒填。检查者已记录 **5,789,542 tokens**，有失败项 `usage=null`，所以 `checker_tokens_complete=false`，Root／成员／任务总量／金额均 `null`。只读报告和旧人工审计一致，不把它称作发布成本账单。
- 实施后曾运行完整 `npm test`，随后用户可见诊断、后续用户授权消息与检查阻塞门再改动；以本轮最后一次完整测试及新隔离安装为最终证据。新增门仍需隔离原生路径分别检验无授权拒绝、精确原生用户授权、池内派发与会话记忆；缺合格精确型号事实时保持自动质量线失败关闭，不借旧会话的固定型号绕过。异常落盘与 park/dispose 的上游限制不变，见[限制台账](debt-ledger.md)。

## 隔离实机尝试：单文件负例暴露检查者目录不一致

- 控制者在 `/tmp/orbit-auth-live-AvKry1vs/project` 独立 Git 夹具、Herdr pane `w1W:pP` 启动**已安装** `/tmp/orbit-auth-live-AvKry1vs/bin/orbit omp`，OMP 18.3.2；安装源码 `0.7.7`、commit `197d39764c4e47b5c763b4dd975743547c6320ed`、dirty，`content_digest=3dfeac7888f69b5de7fbfc1162cbc7669f4dd1817433b46e63ba68a0934e14e6`、`installed_at=2026-09-27T04:09:10Z`。隔离 `XDG_CONFIG_HOME` 候选池为空，原生消息**没有**指定 `review_model` 或池外成员型号。Root 接收的目标是只在 `README.md` 新增 `Acceptance: native-review-gate` 并验证唯一出现；控制者没有替 Root 修改该夹具产物。
- 受控任务 `04af62ea-b45c-4823-a620-1dd2ee4bf31e`，原生会话 `01a0e10e-dfca-7457-8088-4495bb71a101`，04:11:02Z 建任务；Root 确实修改了 README 并检查该行一次、无成员派发。任务 Jev 观察 1 次（`jev-1.13.0`，input **1457**／output **74** tokens，`delegatable=0.28`、`stuck=0.27`），未产生 hint 或成员；这满足负例的**无委派**部分，不等于受控闭环通过。
- 空池默认检查模型为 Root 的 `openai-codex/gpt-6-sol`，隔离检查者 bundle（SDK 18.2.8）报 `model not in catalog`。同一 Root 在通知后又请求手动 `check`，**7 次**检查（`checks/1` 至 `checks/7`，全部 `trigger_cause=manual_check`）均以 `failure_kind=unavailable` 失败；没有有效 finding、独立终检或最终通知，失败项 checker usage 为 `null`，不能据此填零成本。这是实机暴露的**重复失败模型手动检查门缺口**，不是「自动 Jev 重复触发 7 次」；初始版本只拦自动检查，手动请求绕过 blocked。控制者没有借机传入自行指定的检查模型。
- 夹具控制者明确要求中断且不选替代模型，Root 用 `stop(intent=pause)`；04:12:49Z 状态 `paused`、`stop_confirmation.confirmed=true`、Root `status_after=idle`、`active_tools_after=0`、`async_jobs_settled=true`、成员列表为空。产物本地完成，但**受控独立检查未通过，不计真实闭环 PASS**。原始证据保存在该夹具 `.orbit/tasks/04af62ea-b45c-4823-a620-1dd2ee4bf31e/{state.json,events.jsonl,checks/}`；这份隔离控制者消息也不能被记为本次真实用户的检查模型授权。
- 发现后源码增加失败阻塞时 `check` 同步拒绝、运行时竞态拦截，并让通知只提示用户原生精确授权；新回归先复现旧版手动检查再次启动，再通过修复。旧 release 和宿主会话已退出；下节记录从新 release 启动的**另一个**原生会话。空池默认模型在隔离目录不可用的问题没有被绕过；取得用户真实精确授权或有质量证据的池内可用型号前，不可宣称独立终检正路径完成。

## 修复后隔离实机：通用成员池外拒绝与单次检查失败

- 同一临时安装目录重新安装源码 0.7.7，`installed_at=2026-09-27T04:20:09Z`，新 `content_digest=62ef3ec8875af9c82f7949629265f26b01f7a14f7b8a6c1fcd884336e1b24c30`，旧 Root 进程已退出。Herdr pane `w1W:pP` 在新 Git 夹具 `/tmp/orbit-auth-live-AvKry1vs/project-member` 启动新 `orbit omp` 会话 `01a0e117-eb38-733c-8be8-d5b4a378164b`，候选池继续隔离为空，不提供评审或成员型号授权。
- Root 接收双工作面需求：`src/count.mjs` 的 `countWords` 与独立 `tests/count.test.mjs`，先自行完成源码，再以通用 OMP 原生 `task` 尝试派发测试面。TUI 返回 **`Native @task resolves to zhipu-coding-plan/glm-5.2 outside the candidate pool`**，尚未创建成员；Root 自己完成测试后 `node --test` **2/2 通过**。任务 `529b9d5b-3f95-421c-8631-eb5dd0866c93` 的权威成员清单为空、无 `task_dispatch` 持久记录（被门拒绝不属于已派发），Jev `delegatable=0.86`，但 `evidence_status=no_candidates`、没有最终 `delegation_hint`，**不能把高 stage-one 分数误记为派发推荐**。这是「通用成员无池外授权拒绝」的真实负路径，**未覆盖用户授权例外或池内成员注册正路径**。
- Root 只请求 1 次手动终检；`checks/1` 报同样的默认检查模型不在隔离目录，checker usage 为 `null`，无 finding／通知，**不算交付通过**。用户预先明确中断意图时 Root 调用 `stop(intent=pause)`；04:21:58Z `status=paused`、`stop_confirmation.confirmed=true`、Root idle、`active_tools_after=0`、`async_jobs_settled=true`，无成员需收尾。Jev 单次观察 `jev-1.13.0` input **1618**／output **74** tokens；不从失败检查推算检查成本。原始证据在 `.orbit/tasks/529b9d5b-3f95-421c-8631-eb5dd0866c93/{state.json,events.jsonl,checks/}`。Root 没有重复手动检查符合任务指令，但**仅此不能证明新阻塞门拒绝了重复请求**；该行为另用独立任务验证。

- 同一新会话的**另一项**单文件任务 `676c34e6-084e-4f93-a9ef-2f5eb3993560`，Root 按原生用户要求仅在 README 增一行、确认一次，再请求一次独立手动检查；`checks/1` 因同型号不在隔离目录失败。接到失败通知后 Root 又请求一次 `Orbit action=check`，工具**同步回 `status=rejected, reason=checker_model_blocked`**、无 `command_id`；任务状态只有 **1** 次检查，不存在 `checks/2`。Root 按预先明确的中断意图 `stop(intent=pause)`，04:23:15Z 状态 `paused`、`stop_confirmation.confirmed=true`、idle、0 在途工具、异步作业已结算；Jev 一次 input **1405**／output **74** tokens，失败检查用量 `null`。这与第一夹具在旧 release 上 **7 次同型号失败检查**形成行为对照，但不推算跨夹具 token 节省，也不声称此次检查通过。
- 从**已安装的新 CLI**运行 `orbit session-summary --thread 01a0e117-eb38-733c-8be8-d5b4a378164b --project /tmp/orbit-auth-live-AvKry1vs/project-member`：恰好 2 项本项目同会话任务，检查 **2**（失败 **2**、手动 **2**）、Jev 观察 **2**、finding／纠偏／成员 **0**、两项 `stop_confirmed=true`。`checker_tokens_observed=0` 只是已知记录的求和，`checker_tokens_complete=false` 且 Root／成员／整任务 tokens／金额为 `null`，**不是零成本**。本仓旧原生会话的三任务汇总另见上节，不与隔离夹具混算。
- 结束受控会话后，同一 Herdr pane 直接执行原版 `omp` 而非 `orbit omp`，在 TUI 输入 `/tools`；最近完整工具表可解析 **38** 个条目，**没有名为 `orbit` 的工具行**。这只证明此隔离会话的普通 OMP 被动性，不把普通 OMP 冒充受控 Root。三项隔离任务全部已停止且确认；临时项目与 `.orbit` 证据保留在 `/tmp/orbit-auth-live-AvKry1vs/`，没有更新本机日常 0.7.6。

## 本次验收边界与门禁

修复后 `npm test` 完整通过（Ruby／Node／Bun、安装回归及版本锁文件）；`npm pack --dry-run --json` 共 **57** 文件，含 `model_authorization.rb`、`session_summary.rb` 与运行时；`git diff --check` 通过。真实路径已证明通用 `@task` 无授权池外拒绝、失败后第二次手动检查同步拒绝、单项目同会话汇总与停止确认；**未证明**用户精确授权下的池外成员正路径、池内成员注册与真实模型工作、池内合格质量模型自动正选择、用户选定检查模型的会话记忆及可用独立检查者最终 finding／通知／`complete`。当前配置的空池默认模型在检查者 SDK 目录不可用，且本次原生用户没有指定检查者型号；不自行补 `review_model` 或给候选编造精确证据。park/dispose 与异常退出前未落盘证据仍按[限制台账](debt-ledger.md)报告。Skill 目录只提供 `summarize_task.rb`，没有独立 validator 脚本可执行；已运行该汇总器核对两个真实任务的状态、检查和停止。

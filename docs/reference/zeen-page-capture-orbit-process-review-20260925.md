# Zeen 页面走查任务中的 Orbit 流程：过程诊断与实施复盘（2026-09-25）

> 2026-09-25；长期过程复盘，不是产品合同。用户已确认按本文收敛的范围实施，并要求使用 Goal：Root 负责编排和审核，Orbit 工作区同 pane 组的 OMP、Pi、OpenCode 执行具体工作。本文不修改 Zeen，也不把该任务判为 Orbit `complete`。合同与 ADR 已按本文更新，Ruby 完成硬门与 OMP 插件接入已实现（工作区提交前）；真实验收进行中，完成结论与保留边界见 [Orbit OMP 接入验收记录](orbit-omp-access-acceptance-20260925.md)。本文长期保留当时的 Zeen 过程诊断、Herdr Projects 对照与 OMP 18.2.8 源码依据。

## 本轮实施追踪（2026-09-25 已授权）

- **目标：**已启动任务的当前状态进入每个 OMP 用户回合；无有效终检的完成意图同步拒绝且保留运行任务，显式暂停仍可用；实际停止继续核对版本、成员和资源。
- **非目标：**Zeen 页面缺陷、自动建任务、自动派发成员、PR／发布，以及仅为本次样本优化检查成本。
- **分工：**OMP 修订合同与 ADR；Pi 实施 Ruby 完成硬门；OpenCode 实施 OMP 插件接入；Root 审核交叉语义、整体验证和隔离真实任务验收。三个执行面不共写文件，根目录和安装更新由 Root 统一管理。
- **冻结验收：**无终检时完成请求在调用回合给出明确错误，状态仍可继续；当前版本的手动终检 notice 后完成请求正确入队并在 Root 正常交付后 `complete`；显式暂停保持 `paused`／真实停止确认；每个有活动任务的 OMP 用户回合能看到最新的短状态；最终用隔离安装的 `orbit omp` 任务验证真实调用与事件，确定性测试验证关键分支。
- **当前状态：**合同与 ADR 已更新；Ruby 完成硬门（CLI 同步拒绝与按原因区分的下一动作、运行时二次核对、停止后复核与 `completion_invalidation` 展示）与 OMP 插件接入（每轮状态摘要、完成／暂停意图）已实现，改动仍在工作区未提交。隔离 `orbit omp` 真实验收**进行中**：完成结论、通过项与保留边界只看 [Orbit OMP 接入验收记录](orbit-omp-access-acceptance-20260925.md)；本文不预先下结论，也不对仍在运行的真实任务下结论。

## 范围与依据

只检查 Orbit 在 Zeen 页面走查任务中的接入、协作、独立检查与收尾。Zeen 的页面缺陷和未验收项仍由 Zeen 自己的报告与清单管理，不在这里设计修复。

- 任务记录：`/Users/yangke/Personal/omen/zeen/.orbit/tasks/5d58ce62-2c5a-46c0-b2c0-cfec3ac05fdf/`，重点是 `state.json`、`events.jsonl`、`members.json`、`checks/1..6/evidence.json`。
- 交付产物：`/Users/yangke/Personal/omen/zeen/docs/research/mobile-ui-page-capture-report-2026-09-25.md`、同目录的 fix list 与截图。最终报告记录了 iOS 真机签名阻断和对应未验收范围。
- 本仓语义：[任务运行合同](../../contracts/task-runtime.md) §「程序与模型」「观察与完成」、[ADR-007](../adr/007-task-runtime-refactor.md)；当前源码入口为 [`plugins/host.mjs`](../../plugins/host.mjs)、[`lib/orbit/cli.rb`](../../lib/orbit/cli.rb)、[`lib/orbit/task_runtime.rb`](../../lib/orbit/task_runtime.rb)。当前源码不等同于这次任务当时安装的构建；下文源码分析是实施前写下的机制候选，落地后的行为以合同／ADR 与[验收记录](orbit-omp-access-acceptance-20260925.md)为准。
- 同 pane 的 OMP Root 对自己的调用序和派发原因作了只读回溯；其自述作为线索，机器记录仍为状态与事件事实的依据。

## 已确认的过程事实

| 时间（UTC） | 记录 | 含义 |
| --- | --- | --- |
| 09:20:20 | 任务创建 | Orbit 已接入该 OMP 会话。 |
| 09:25–10:29 | 六次独立检查；其中 #2、#3 因 `host`，#4、#5 因 `artifact` 过期 | #1 提出 TODO 收口门，后来解决；#5 提出 iOS 真机问题但产物版本过期，#6 在新快照上再次确认并向 Root 发送纠正。过期检查不等于有效终检。 |
| 09:41:57 | 一名原生 OMP 成员登记 | 该成员承担 Android 工作；有两次成员结果记录。不能说「多 Agent 完全没有唤起」。 |
| 10:29:21 | 检查 #6：`correct`，`capture-missing-ios-real-device-leg` open | 当时最终报告尚未生成；检查者要求驱动 iOS 真机，或记录签名阻断、冻结输入和未验收范围。 |
| 10:29–10:36 | Root 完成最终报告、清单、README 登记和环境清理 | 报告已写明 iOS 真机阻断与未验收范围，但该最终版本没有再次交给独立检查者。 |
| 10:36:00 | Orbit 工具 `stop` 后记录 `stopped` | `state.status=paused`，停止确认完整；`finalization_notices={}`，iOS finding 仍为 open；没有 `completion_stop_queued` 或 `completed_via_finalized_stop`。Root 的 stop 原因却写「交付完成」。 |

OMP Root 确认它没有调用 `check` 请求手动终检，最终用的是 Orbit 工具 `stop`，收到的回执只有 `status=queued`。记录与这一陈述一致：六次均为自动检查，没有 `manual_check` 或 `finalization_notice` 事件。**可确定的是 Orbit 没有把这次任务记为完成；不能从 #6 推断最终报告仍有同一缺陷，因为 #6 的快照早于报告。**

## 问题分层

### P0：收尾意图与实际结果不一致

合同要求当前版本的有效手动终检无遗留问题、发出 `finalization_notice`，再由 Root 显式完成停止。此任务跳过终检，Root 仍用「交付完成」发起 stop。当前源码中，Root 工具对 `stop` 一律加 `--complete`；运行时在没有有效 notice 时落入普通 `stop(reason)`，最终记 `paused`。CLI 的 `queued` 回执只表示命令入队，未指出完成前置条件不满足。这个反馈缺口使 Root 容易把「已停止」当成「已完成」。

直接影响：最终报告及其 iOS 阻断口径没有得到当前版本的独立复核；开放 finding 留在已暂停任务中，用户只看到交付措辞时难以识别差异。这里不是放宽合同，把 `paused` 改写成 `complete`。

### P1：协作感知与实际派发分离

事件有一名 Android 原生成员、两次结果回收，同时有 50 次 `member_candidates_empty`。依合同，候选池为空只意味着 Jev 不给成员模型建议；Root 仍能显式派发。OMP Root 解释只有 Android 具备独立设备工作面：iOS 真机在派发前因 runner 签名受阻，同一设备不能并发占用。现有证据不支持「Orbit 本应自动唤起更多成员」这个结论，也不能证明这名成员与 Root 的工作产生了多少真实并行收益。需要单独评估是否应在状态展示中清楚区分「无候选建议」和「已有成员」。

### P2：执行纪律与检查成本

Zeen 当时的执行依据要求 `context → start → status` 确认受控。OMP Root 自述只调用 `context/start/stop`，未做这一步；但事件已证明任务被观察和检查，因此这是执行纪律偏差，非本样本连接失败。它还自述把同一 Android 成员工作拆成两轮交办；两次结果记录可证实两次回收，具体派发文本仍需会话记录复核，不能仅凭结果次数定为 Orbit 缺陷。

六次检查中四次过期，检查累计 `1,892,268` tokens（任务 `state.usage.check_tokens`），Jev stage1 另记输入 `520,220`、输出 `5,180` tokens。检查是否过早、重复触发是否可减少，是成本优化候选；#5 过期后 #6 复核属于合同预期，不把同一 finding 的再次出现直接判为重复纠错故障。

## 修复顺序（已授权，实施中）

1. **先修 stop 的用户可见结果。** 把完成与显式暂停区分：无当前有效 `finalization_notice` 的完成意图同步返回结构化前置条件失败，任务保持可继续请求终检；用户明确中断走暂停。仍核对异步入队后的版本变化、Root turn 收尾和现有 CLI 停止语义，避免破坏停止确认。先更新合同与 ADR，再改 host、CLI、runtime。
2. **让终检动作发生在最终交付版本上。** 调整 Root 工具指导与回执，使 Root 写完最终产物后请求手动 `check`、结束当前 turn，收到纠正就修正并重检，收到 notice 后再完成 stop。`status` 不作为等待检查结果的轮询手段。重点是明确下一动作，不增加机械检查次数。
3. **改进状态呈现。** `paused` 且有 open finding 时，在 `status`／任务摘要显示「未完成、尚有待复核问题」及最后检查版本；候选池为空时说明它只影响推荐，同时展示已登记成员数。先确认现有展示没有足够信息，再决定是否改动。
4. **最后评估成本。** 按检查触发原因、freshness、finding 是否首次有效和 token 量复盘这六次调用；只针对可复现的过早触发调整，不削弱在产物变化后复核旧 finding 的能力。

## 冻结验收口径

- 无有效终检时用 Root 工具表达「完成」：调用方明确获知不能完成；任务不被标成 `complete`，也不丢失继续检查的机会。用户明确暂停仍能停止并得到确认。
- 最终产物触发手动终检：只有当前版本无 open finding／待核对线索、成员已结束并发出 notice 后，Root 正常结束交付轮次才记 `complete`；产物或输入在 notice 后改变时不能误完成。
- 使用一个隔离 OMP 真实任务验证「成员结果 → 自动 finding → Root 修正 → 手动终检 → notice → 显式 stop」，同时记录最终状态、事件序列和用户实际收到的回执。确定性测试只覆盖前置条件与状态转换，不替代真实路径。
- 对 Zeen 这份既有任务保持历史原状：它是 `paused`，最终报告没有 Orbit 终检结论。任何新的复核或重跑须另记任务和证据，不能回填历史 `complete`。

## 方案口径（已纳入产品合同，实施中）

- **接入边界：**用户运行 `orbit omp` 才加载扩展；简单讨论不自动创建 Orbit 任务。Root 仍按现行合同决定何时 `start`，也仍显式派发执行成员。此次不改变为专职协调者、自动建任务或自动派人。
- **持续上下文：**已启动任务在每个用户回合的 `before_agent_start` 获取短状态摘要，并在可用的 OMP 界面显示当前阶段。摘要由任务持久记录派生，不写第二份状态；未启动任务只收到简短接入条件。无需用户每轮手动 `status`。
- **明确停止意图：**Root 工具的完成停止维持默认意图，但提供显式 `pause` 意图供用户中断。完成意图在工具执行前核对有效终检：缺 notice 或仍有 open finding／待核对线索时，同步返回结构化拒绝和下一动作，不入队、不自动降级成暂停；运行时在实际停止前再次复核版本、成员和 Root turn。普通 CLI stop 保持暂停语义。这一部分改变现有行为，已同步合同／ADR 并实现。
- **终检闭环：**Root 写完最终版本后请求一次手动 `check` 并结束 turn；有纠正则修复后重检，收到 `finalization_notice` 后完成 stop。旧 finding 能否关闭由新快照的独立检查决定，状态提示不替检查者裁定。
- **`session_stop` 不进首轮必需实现。**先靠工具硬门与回合状态摘要解决已证实的问题；只有隔离真实任务仍出现 Root 直接声称完成、未请求终检就结束的可复现缺口，才增加按任务状态有界触发的一次续跑。它不能成为完成裁定权威。

本方案已获本轮执行授权；若未来要让 `orbit omp` 对每条请求自动建任务，或由 Orbit 自动创建成员，那是另外的产品决策，应单独提出并修订合同。

## 外部参考：Herdr Projects（借鉴范围，非实施决定）

[Herdr Projects](https://github.com/eliasstravik/herdr-projects) 的 [Operations](https://github.com/eliasstravik/herdr-projects/blob/main/docs/operations.md) 描述了三处与本样本相关的机制：文件是任务记录、提示只负责唤醒；协调者每轮读取 `context` 摘要；线程按「需要你处理／待审／工作中／空闲」归组，报告和未处理事件进入 inbox。这里借鉴的是**状态和下一动作的呈现方式**，不是照搬它的项目管理层。

| 参考机制 | Orbit 已有基础 | 针对本样本的可用改进 |
| --- | --- | --- |
| 持久记录优先，提示可丢 | `state.json`、`events.jsonl`、检查证据与成员结果已持久化；纠正会送达 Root | Root 每次收到 Orbit 工具结果或被唤醒时，从当前记录给出明确的「下一动作」，尤其区分 `queued`、待终检、待纠正、可完成与已暂停。无需另建 `MEMORY.md`／inbox 数据源。 |
| 以「需要谁行动」排列状态 | `TaskView` 已显示执行成员、检查、open finding 和下次检查，但 `paused` 且仍有 open finding 时「用户处理」可能仍写「当前记录未要求用户处理」 | 在现有 status 顶部派生一条可操作状态：本样本应是「已暂停、未完成；最终产物未终检，仍有 1 条开放 finding」。此信息也应进入 stop 的机器回执，不只靠用户主动查状态。 |
| 成员报告与待审状态分离 | Orbit 登记成员并记录结果，但成员结果出现不等于 Root 已集成或整项已验收 | 只在真实需要时增加「成员结果待 Root 核验」的提示；本次首要缺口仍是最终版本的独立终检，不能靠成员状态替代它。 |

该仓库让专门的 coordinator 不亲自执行，并默认给每个线程独立 worktree／branch；Orbit 合同则由原 Root 负责实现、分工和交付，共享设备还需要独占。照搬这种角色划分或一律创建 worktree 会扩大产品范围，也不能解决本次 stop 缺口。其 PR 跟进、共享长期记忆、远程机器和自动清理同样不列入这次修复。

## 进一步源码核对：接进 OMP 的更合适位置

本节对照 [Herdr Projects 本次读取的提交](https://github.com/eliasstravik/herdr-projects/tree/068b0c7cc117b5016c5847d33a893c0336656551) 与 [OMP v18.2.8 源码](https://github.com/can1357/oh-my-pi/tree/v18.2.8)；OMP 18.2.8 是 Orbit 当前锁定版本。上游主分支现为 18.3.1，新增接口不算当前可用能力。

### Herdr Projects 实际怎么插入工作流

它不是只注册一个工具、等模型自行决定何时调用。它在专属项目目录生成 [`AGENTS.md`](https://github.com/eliasstravik/herdr-projects/blob/068b0c7cc117b5016c5847d33a893c0336656551/src/project.rs#L484-L494)，Agent 启动时按当前目录确定协调者身份；[协调者指令](https://github.com/eliasstravik/herdr-projects/blob/068b0c7cc117b5016c5847d33a893c0336656551/skill/COORDINATOR.md#L14-L21)要求每轮先读 `context`。此外，它在支持的宿主上装会话开始、用户提交、工具完成等[进度 hooks](https://github.com/eliasstravik/herdr-projects/blob/068b0c7cc117b5016c5847d33a893c0336656551/src/setup.rs#L16)，后台 ticker 只在有未处理事件且协调者稳定 idle 后提醒；状态仍以文件为准。[实现说明](https://github.com/eliasstravik/herdr-projects/blob/068b0c7cc117b5016c5847d33a893c0336656551/docs/operations.md#L195-L204)明确把提示当作唤醒，而不是事实记录。它的项目目录是新工作场所；Orbit 要服务用户原来的项目与 Root，不能覆盖项目 `AGENTS.md` 或强迫迁入另一个目录。

### OMP 18.2.8 已提供的接点

| 接点 | 源码支持的能力 | 对 Orbit 的合适用途与限制 |
| --- | --- | --- |
| [`session_start`](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/extensibility/extensions/types.ts) | 会话启动通知；Orbit 现有扩展已经使用 | 绑定 Root 与项目、恢复可识别的任务状态；不要因用户只是讨论就自动创建任务。 |
| [`before_agent_start`](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/extensibility/extensions/types.ts) | 普通用户请求或出队的用户消息进入模型前，可加入自定义消息或更新 system prompt | 给**已绑定任务**注入短而新鲜的状态：当前阶段、开放问题数、是否已请求终检、可执行的下一步。未启动任务时只提供一条接入条件，不逐轮塞完整合同。它覆盖原生用户回合，比仅靠 `orbit` 工具描述和首次 `start` 回执稳。 |
| [`session_stop`](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/extensibility/shared-events.ts) | 主 Agent 回合将结束时，可附加上下文续跑一轮；[实际调用点](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/session/agent-session.ts)在终结维护阶段 | 仅当记录显示明确、未处理的流程动作时做**一次有界提醒**，例如完成意图被拒绝后引导请求终检。它在回答生成之后发生，不能撤回已展示的「完成」说法；处理器超时或报错也不能充当严格保证，不能把它当完成门。不得在每次普通停顿时循环续跑。 |
| [`ctx.ui.setStatus`／`setWidget`](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/extensibility/extensions/types.ts) | OMP 界面可显示扩展状态 | 持续显示 `未启动／执行中／待终检／待纠正／可收尾／已暂停`，从任务记录派生，不另建状态权威；headless 下仍以工具回执为准。 |
| [`tool_call` 门与注册工具](https://github.com/can1357/oh-my-pi/blob/v18.2.8/packages/coding-agent/src/extensibility/extensions/types.ts) | 模型工具调用可阻止并返回原因；Orbit 已用它保护成员派发 | `orbit stop` 的完成前置条件应在**工具执行前同步检查**并返回明确错误；运行时消费入队命令时再次核对版本和成员。比等 `session_stop` 发现异常更可靠。 |

Orbit 当前 [`host.mjs`](../../plugins/host.mjs) 主要靠工具描述与 `start` 的 `next_action` 给 Root 指引；[`omp-host.mjs`](../../plugins/omp-host.mjs) 虽已挂 `session_start` 和协作工具事件，却没有把活动任务状态在每个用户回合重新带给 Root，也没有在 OMP 界面呈现待终检状态。**这是基于源码的接入缺口判断**；是否能降低漏终检率仍需真实 OMP 任务验证。

OMP 的 `input` 事件只覆盖交互输入，不能作为所有会话来源的唯一入口；`context` 事件在每次模型调用前触发，用来重注入完整任务摘要会增加重复上下文。这里优先选择每个用户回合一次的 `before_agent_start`，并让 stop 的程序门保持最终裁定权。

### 建议的最小落地顺序（历史建议，已按此实施）

当时的落地顺序，保留以便对照实现：

1. 先做完成硬门：有完成意图但无有效 notice 时，工具同步返回结构化拒绝或「需终检」下一步，不排入会导致普通暂停的完成命令；用户明确中断走单独的暂停语义。保留运行时的二次版本复核。这一步直接覆盖本次 Zeen 失误。
2. 再做活动任务的每轮状态摘要：在 `before_agent_start` 读取持久任务记录，按当前状态只注入几行，明确「最终产物已改但尚无当前终检」或「收到 notice 后可 stop」。避免每次 provider 请求注入、长上下文重复、无任务时启动检查。
3. 再用 `setStatus` 展示任务状态。首轮不接 `session_stop`；若真实验收仍证实 Root 可绕过终检直接宣称完成，再设计一次有界续跑。检查失败、用户中断、普通中途回复都要能正常结束回合。
4. 最后在隔离 OMP 18.2.8 真实任务中测「Root 写完产物直接声称完成」「完成工具被拒」「手动终检后正确收口」「用户主动暂停」「恢复／压缩后的状态提示」；记录用户实际看到的文本、Orbit 事件和最终状态。没有真实路径证据前，不宣称接入体验已改善。

这不是决定引入 Herdr Projects 依赖，也不是把 Orbit 改成专职协调者。是否让 `orbit omp` 启动时自动创建任务仍是独立的产品选择；讨论回合不应因此付检查成本。

# Orbit 使用体验复核入口

日期：2026-10-15；更新：2026-10-16。状态：EXP-01—10 已逐项讨论，其中 EXP-07、EXP-10 暂不单独调整；其余已确认方向见方案。EXP-11 的记录入口已并入 EXP-02，漏查误判保留；EXP-12 已确认由 Root 处理裁定，下一项讨论 EXP-13，尚未进入实施。

本目录汇集 Zeen 使用方在 9 月 28 日、10 月 15 日的评价，以及 Orbit 侧结合合同、日志和代码的复核；另收录 10 月 16 日对 Loom 长会话的追查。后续讨论、补证据或修改从本文进入。这里保存分析与候选建议；产品规则以[运行合同](../../../contracts/task-runtime.md)为准，职责调整理由见 [ADR-011](../../adr/011-agent-autonomy-and-runtime-responsibility.md)，其与 ADR-008/009 的替代关系已注明。

2026-10-16 已按用户确认调整产品定位和职责文档，目标规则已落运行合同，尚未改代码；继续修改从[已确认改动方案](agreed-change-plan.md)进入。EXP-13 的修复候选仍待确认。

最新补充已扩大到 117 条入口记录、5 个主会话的 168 条用户消息，以及当前保留的 8 个任务记录。重点核对 15 个介入片段。先读下表的多任务复核，再按议题进入具体证据。168 是用户消息数，不是不满意次数；8 个任务也不代表全部历史。

Loom 补充另核对两段原生主会话及四轮 Orbit 任务。发现误报完成、申诉裁定循环、对话路径错误三项新问题；统计与原 Zeen 样本分开，见下方新报告。

## 材料与阅读顺序

| 材料 | 来源与作用 |
| --- | --- |
| [EXP-13 地址错配根因与原生复现](exp-13-session-path-cause.md) | 本机 OMP 18.9.0 新建、切换聊天复现：活动地址已更新，登记地址未更新；Orbit 取了后者。附探针结果，改法待确认 |
| [EXP-11 检查调用追查](exp-11-review-trace.md) | 回读第一次判完成的检查会话：完整标准已读，原型及缺失页面未读；上一轮九项交付未核实原因未传到下一轮 |
| [Loom 长会话复核](loom-experience-review-20261016.md) | 新增 EXP-11—13；对照用户介入、Goal 计划、四轮任务、检查快照与当前代码，区分已定位原因和待查原因 |
| [已确认改动方案](agreed-change-plan.md) | 汇总确认方向、权威规则链接、代码修改入口和验收关注点；目标文档已调整，代码未实施 |
| [多任务复核：用户介入与监督效果](cross-task-review.md) | 本次补充；跨 9 月 27 日至 10 月 15 日，核对纠正、停工、协作、停止与恢复，补充对原结论的修正 |
| [用户消息定位索引](user-message-index.md) | 5 个主会话的 168 条消息短摘录及行号，方便后续继续追查；不将所有介入计为投诉 |
| [完成判据中的场景规则排查](completion-rule-audit.md) | EXP-03 补充：Git、UI 规则与测试回执限制的代码位置，区分场景验收和通用运行门 |
| [用户主动纠偏与监控链复核](user-correction-monitoring-audit.md) | EXP-05 补充：六个用户介入片段；对齐提交拖延前 15 次 JEV 调用、触发条件与实际恢复，区分漏纠偏和结果过期 |
| [9 月 28 日首轮用户反馈](zeen-mobile-ui-orbit-user-feedback-20260928.md) | 从 Git 恢复的早期评价，保留原文；原出处见多任务复核 |
| [使用体感评估：阅读文档前](zeen-orbit-experience-assessment-20261015.md) | Zeen 使用方的第一轮原始体感，保留当时判断 |
| [文档对照评估：阅读整体文档后](zeen-orbit-document-assessment-20261015.md) | 同一使用方读文档后的第二轮评价，包含对第一轮的修正 |
| [合同、日志与代码复核](evidence-review.md) | 本次 Orbit 侧分析，区分成立的判断、需要修正的归因和遗漏问题，并列出证据及验证边界 |

10 月 15 日的两份评价从 `docs/reference/` 移入，文件名与正文观点保留，只调整相对链接。它们是同一使用方的两轮评价，不是两名独立评审者的结论；9 月 28 日反馈也是执行 Agent 的使用评价，不应按独立用户实验计数。

## 后续讨论与修改索引

编号只用于本目录讨论，不是 Orbit 运行时 finding ID。以下顺序是本次复核的建议，尚未作为实施优先级采纳。

EXP-01—04、取消 coverage 固定 64 项上限、EXP-05 日志优先与减少人为截断、EXP-06 向 JEV 提供用户新消息原文的已采纳方向统一维护在[已确认改动方案](agreed-change-plan.md)，后续修改从该文核对。EXP-07 已确认暂不调整、保留核查；EXP-08—09 修复方向已确认；EXP-10 已确认暂不单独增加汇报机制，继续观察。EXP-11 的记录入口补充已确认并入 EXP-02，漏查误判保留；EXP-12 已确认由 Root 处理裁定，下一项讨论 EXP-13；证据见[成员退出与继续等待的追查](other-round-root-cause-review.md#exp-08-继续追查通知等待和恢复)。原始复核保留发现与讨论过程，不替代最新方案。

| 编号 | 议题与分析入口 | 相关修改入口 | 当前状态 |
| --- | --- | --- | --- |
| EXP-01 | [成员编辑工具与安装依赖](evidence-review.md#exp-01) | `plugins/work-unit-scope.mjs`、`plugins/omp-host.mjs`；成员范围合同 | 已确认取消默认文件限制的方向；Root 事后核对、改错后纠正，不做重置；尚未实施 |
| EXP-02 | [裁定证据压缩失真](evidence-review.md#exp-02) | `lib/orbit/check_runner.rb`、`runners/omp-reviewer/confined-tools.ts`；检查证据合同 | 已确认开放只读访问、完整申诉、概况加证据入口；尚未实施 |
| EXP-03 | [场景专用代码追加验收义务](evidence-review.md#exp-03) | `lib/orbit/git_remote_evidence.rb`、`lib/orbit/check_runner.rb`；事实采集与完成裁决边界 | 已确认移除 Git／UI 专用判据、调整测试证据判断；尚未实施 |
| EXP-04 | [真机与测试证据交付](evidence-review.md#exp-04) | `lib/orbit/task_runtime.rb`、`lib/orbit/check_runner.rb`；快照与原生回执接缝 | 已确认沿用开放只读取证和相关性判断，并验收较早回执可回查；尚未实施 |
| EXP-05 | [过程检查投入](evidence-review.md#exp-05)、[用户主动纠偏及 UC-01 根因](user-correction-monitoring-audit.md)、[其他五个片段根因](other-round-root-cause-review.md) | `plugins/omp-host.mjs`、`lib/orbit/task_runtime.rb`、`lib/orbit/observation_key.rb`、`lib/orbit/jev_advisor.rb` | 已确认先补完整日志、观察真实调用；输入优先评估取消人为截断，不叠加裁剪规则。具体输入与判断调整待证据支持，尚未实施 |
| EXP-06 | [用户新消息未直接传给 JEV](evidence-review.md#exp-06) | `plugins/omp-host.mjs`、`lib/orbit/task_runtime.rb`、`lib/orbit/jev_advisor.rb` | 已确认用户新消息原文也传给 JEV，由其结合旧要求判断当前行动；不自动修改或取消旧任务，尚未实施 |
| EXP-07 | [用户纠正与总目标保持](cross-task-review.md#建议新增的讨论议题) | 原始要求、amend、成员传递、覆盖与总目标关联 | 已确认暂不改代码；先补既定日志和用户消息传递再观察，未解决 |
| EXP-08 | [阻断后的继续执行与接管](other-round-root-cause-review.md#exp-08-当前版本复现退出后仍返回旧的-running-状态) | JEV 观察、Root 继续执行、成员阻断、资源清理 | 当前源码已复现：成员中止并移除后仍返回缓存 running，运行时保持未结束；本机 0.8.11 相关代码相同。已确认保存终态、未知如实返回，不沿用旧 running；尚未实施 |
| EXP-09 | [会话恢复、停止与归属](other-round-root-cause-review.md#exp-09-当前版本核对needs_user-停止后没有续接入口) | 原生句柄、任务绑定、成员结算、takeover、交付归属 | 已确认由 Root 判断用户介入，检查者和程序提供事实；取消 needs_user 自动停止及续接拒绝，复用现有能力；尚未实施 |
| EXP-10 | [进度汇报与总目标状态](cross-task-review.md#建议新增的讨论议题) | 用户消息响应、受检范围、剩余工作与阻断表达 | 已确认暂不单独改动，先落实前述方向并观察；未认定独立的汇报程序缺陷 |
| EXP-11 | [独立检查误报完整交付](loom-experience-review-20261016.md#exp-11独立检查误报完整交付) | 检查者取证、历史逐项结论与 coverage；[调用追查](exp-11-review-trace.md) | 已确认由程序提供实际记录目录和用途，检查者自主补读，并入 EXP-02；已有材料未读却判通过的问题保留观察，未解决 |
| EXP-12 | [申诉裁定持续作废](loom-experience-review-20261016.md#exp-12申诉裁定被持续作废) | `task_runtime.rb` 的角色选择、过期结果处理、申诉清除 | 已确认将裁定及期间变化交给 Root，补工具处理能力；取消程序自动作废及同一申诉自动重复裁定，尚未实施 |
| EXP-13 | [对话证据路径错误](loom-experience-review-20261016.md#exp-13对话证据路径错误) | `omp-host.mjs` 的会话路径、`task_evidence.rb` 的导出定位 | 已定位并用实际 OMP 18.9.0 复现登记地址未随聊天切换更新；Orbit 误取登记旧值，活动会话已有正确地址；[根因报告](exp-13-session-path-cause.md)，方案待确认 |

## 如何继续维护

1. 新分析单独放在本目录，并在上方材料表标明来源、日期和作用。原始反馈保留，修正意见写入新分析，不倒改当时体感。
2. 讨论某一议题时使用上述编号。结论、补证据和验证限制写在对应分析段落；本文只维护导航、状态与已经确认的下一步，避免复制完整结论。
3. 确认进入实施后，在项目 `docs/plan/` 建立或更新实际任务计划，并从本文链接。涉及产品语义或技术决定时，按项目规范更新合同或 ADR；本目录不代替这些权威正文。
4. 修复后明确区分源码、安装和真实运行验证。不能只因测试通过就关闭原体验问题，也不把旧日志改成修复后结果。
5. 分析被正式决定和验证记录吸收后，再按项目文档生命周期决定是否退场；当前材料仍用于讨论，保留原始评价及复核。

## 证据位置与边界

- 初轮代码复核任务：`e9d76e4c-b11b-4168-9458-8508dd23fe19`。
- 原始记录：`/Users/yangke/Personal/omen/zeen/.orbit/tasks/e9d76e4c-b11b-4168-9458-8508dd23fe19/`。
- 补充体验与执行记录：`/tmp/zeen-chat-experience-issues-2026-10-15.md`。
- 初轮统计依据截至日志 `2026-10-15T11:57:53Z`（北京时间 19:57:53）的记录，不代表任务此后的终态。
- 多任务补充的当前记录读至 `2026-10-15T12:03:26Z`；8 项任务清单及历史证据边界见[多任务复核](cross-task-review.md)，5 个主会话位置见[消息索引](user-message-index.md)。

原始日志与真机材料留在原位置，本目录不复制快照或会话内容。绝对路径是本机证据定位，不是随仓库分发的附件。具体安装身份、检查编号和源码入口见[复核正文](evidence-review.md#evidence)。

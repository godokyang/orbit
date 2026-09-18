# 项目检查：用户结果视角下的独立只读审查（2026-09-18）

本文记录一次独立只读审查，不签发产品语义，不新增验收或授权要求。审查对象为当日工作树（已发布 `c80618b` / 0.6.1 之上叠加未提交的 Jev 接入与 `orbit.task` 改名）。区分四类来源：已安装版本、未发布源码、`tests/` 模拟测试、真实使用记录。**真实使用证据只有一份**：本仓 `.orbit/tasks/faf2e5d2-3100-4139-95a9-4536bf7af982/`（Jev 开发任务的完整记录）；其余四份验收均为受控注入遗漏的夹具运行。

**复核说明：**下文保留独立审查者的判断与候选方案，不直接作为实施队列。事实错误已在原处修正；项目对优先级、现行合同和用户明确需求的复核结论见文末。当前执行顺序以[用户结果补齐计划](../plan/user-outcome-completion-plan.md)为准。

审查中运行了完整 `npm test`（去掉 `TYPESAFE_API_KEY`），全部通过；未修改源码、未安装、未发布、未调用模型。

## 出发点

用户把任务交给惯用 Coding Agent 后，希望以合理的时间、成本和人工投入，得到符合原始意图、经过必要验证、可安全中断和接续的成果。问题是：相比 Coding Agent 单独工作，Orbit 在什么场景带来可证实的净收益，在什么场景增加等待、费用、操作负担或失败风险。

## 最重要的发现（按对用户结果的影响排序）

### 1. 唯一一次真实使用中，检查回路交付了 0 条纠正，消耗 424 万检查 tokens【已证实】

`state.json`：运行 1623 秒，8 次检查启动，7 次完成且全部 `stale: true`，第 8 次启动 8 秒后随中断结束；`comparison.correction_messages = 0`、`members = []`、`usage.check_tokens = 4,246,313`（含缓存口径）。

检查 3–7 的 findings 是真实且正确的缺陷（observations 截头截尾、`ORBIT_JEV` 多余门控、TLS 异常未包装、成员结果无界、debounce 绕过、amendments 只取 3 条），当前 `lib/orbit/jev_advisor.rb` 已修复它们。但修复不是运行程序投递的：Codex 会话记录（`~/.codex/sessions/2026/09/18/rollout-…01a0b25d….jsonl`）显示 Root 通过 `status` 读取任务记录 38 次、引用这些 finding id 71 次。Root 自行轮询绕过了"过期即丢弃"规则，与 `skills/orbit/SKILL.md` "无需 Root 持续轮询"相悖。

根因在 `lib/orbit/task_runtime.rb#finish_check`：

- 检查者自设 `next_check_seconds` 为 30–60 秒（覆盖 `review.interval_seconds = 300`），Root 持续编辑时几乎必然过期。
- 过期结论整体丢弃，包括可能仍成立的 findings。

四份夹具验收显示过期检查并非这次独有：user-flow 2/4 过期、OpenCode 2/4、OMP 成功任务 3/5 过期。**审查者不同意 ADR-007 "允许固定副本上的并行检查以减少等待"的收益判断**：在持续编辑的任务里，并行检查主要产生浪费，实际价值通道是 Root 读记录。

### 2. 已解决的问题很窄，"自然遗漏被发现"没有证据【已证实】

已证实：原文与修改原样留存（`task_record.rb`）；含未提交修改的固定快照（`workspace_snapshot.rb`）；独立只读检查（`check_runner.rb`）；Codex 原生停止确认含后台终端（`codex_connection.rb#stop!`，验收 B 真实 PID 退出）。

无证据：所有"独立发现遗漏"验收都是受控注入（删 USAGE.md、greeter 空姓名），没有一次自然遗漏被程序投递并纠正的记录。发现 1 说明检查者判断质量高，但回路没把价值送到。`debt-ledger.md` "效果验证仍有限"应是当前唯一主线，而非表格末行。

### 3. `delegate`／成员／统一停止在真实使用中从未被用过【已证实】

真实任务 `members = []`。三份验收各恰好 1 个成员，做的是琐碎验证。为此维护的代码：`task_runtime.rb` delegate / collect_member_results / members_settled?、`codex_connection.rb` 成员 API、`plugins/host.mjs`／`omp-host.mjs`／`opencode.mjs` 成员逻辑、合同两整段、`agent-collaboration.md`。停止确认的大部分复杂度只在有成员时才有意义。

`user-outcome-completion-plan.md` 切片 B/C 要在这条零使用路径上再加 Herdr 非 Codex 成员与 Jev 委派提示。**审查者不同意把 Herdr 成员列为日常使用缺口的主因**：缺口是发现 1。

### 4. Jev 尚未证明能改善本次观察到的重复检查【部分已证实】

- ADR 新增段落称 Jev "同时针对过早检查的成本"。代码里 Jev 只能推迟首次文件变化触发的检查，不触碰检查者自设的 30–60 秒 `next_check_seconds`——后者是发现 1 中 7 次过期的直接驱动。
- 阈值 0.8／0.85／0.65／streak≥2／60s／20s 全为常数，无数据支撑。
- `jev-runtime-acceptance-20260918.md` 记录一次"模拟执行停滞"得到 `stuck=0.88`；该临时项目的原始请求与运行记录未留存于 `docs/reference/`，现有说明不足以复核完整细节。这不等于真实请求未发生。
- 引入双套路径：有 advisor 时 `changed` 用 5 秒缓存 digest，无 advisor 时每秒全仓 fingerprint。计划自身"防扩张规则 3"警告的正是这种双轨。
- `process_reviewer` 仍走 `start_check` 完整快照复制（约 736K/次），"聚焦检查更便宜"未验证。

### 5. OpenCode／OMP 用户仍必须安装并登录 Codex【已证实】

`contracts/task-runtime.md`："检查者与裁定者当前仍使用 Codex"；README 专节回答"可以只用 OpenCode 或 OMP 吗"。三宿主各有独立接入、插件、测试、安装路径，但用户日常实际用哪个宿主没有记录；真实任务用的是 `orbit codex`。【推测】OpenCode/OMP 路径自 9 月 14 日验收后没有日常使用。

### 6. 检查成本随仓库规模线性增长【推测，有间接证据】

每次检查复制整仓快照并让模型自行阅读；真实任务单次输入 10 万–142 万 tokens（缓存为主）。本仓仅 736K；中大型项目未测。检查 prompt 26–40KB，注入 `skills/orbit/assets/rule-library/` 多份规则（10 文件约 600 行，含 v2 遗留的 `resident/AGENTS.md.template`、`vantage-audit.md`）。

### 7. 从未被使用的机制【已证实】

所有真实与验收记录中：`decisions = []`（裁定者从未运行）、`estimate` 全 null、`hard_deadline` 仅验收 B 用过、`dispute` 零次。对应 `finish_check` adjudicator 分支、`consume_commands` dispute、`comparison` 计算、`verify_prior_check_exit`。

### 8. 文档层重复且三处"下一步"【已证实】

`handoff.md`、`vision-completion-plan.md`、`user-outcome-completion-plan.md`、`user-experience-plan.md`、`jev-integration.md` 相互引用并重复验收细节；`docs/README.md` 同一行指向三份计划。约 400 行计划文本对应 `lib/` 约 3,200 行。

## 从零开始的最小 Orbit

- 保存原始要求与修改；
- 只在 Root 空闲/交付节点对固定快照做一次独立检查，把 findings 投回同一会话；
- `orbit status` 看结果。

其他全部可选：编辑中的定时检查、Jev、成员、多宿主、裁定、硬截止、预估。停止确认只在有成员时才值得保留。约相当于 `task_record` + `workspace_snapshot` + `check_runner` + 一个约 200 行的调度器 + Codex 连接。

## 复杂度收益判断

- 明确收益：`workspace_snapshot.rb`、`check_runner.rb`（进程组控制 + schema 校验）、`codex_connection.rb#stop!`、`cli.rb` status/stop、`task_record.rb`。
- 当前证据下维护成本高于收益：`task_runtime.rb` Jev 分支与 `process_reviewer`；成员路径（含三个 plugin 文件的成员部分）；adjudicator/dispute；estimate/hard_deadline/comparison；`rule-library/` 大半内容；`plugin_connection.rb` 与两个非 Codex 宿主（待宿主实验决定）；`docs/reference/zeen-orbit-handoff-20260913/` 本地快照噪音；五份重叠计划文档。
- 合理但不应再扩：`install.sh`/`manage-install.rb`（376 行）+ 256 行安装测试。

## 独立审查提出的任务清单（非现行计划）

| 计划中的任务 | 决定 | 理由 / 解除条件 |
| --- | --- | --- |
| 切片 A：验证并发布 Jev、更新安装 | 先做小实验，不作为默认开启发布 | 源码可提交（测试通过），只装本机，跑 3 个真实任务记录 `jev_assessed` 与随后过程检查 verdict；过程检查多为 `continue` 或未减少过期检查则不启用 |
| 切片 A："检查 Jev 输入包含有效要求" | 仍需核对 | `jev_advisor.rb` 只取 `last(20)`；不能据此保证更早的有效修改仍在输入中 |
| 切片 B：Herdr 非 Codex 成员路径 | 暂缓 | 解除条件：至少 1 个真实任务中 Root 实际调用过同宿主 `delegate` 且结果被集成 |
| 切片 C：Jev 委派提示 | 删除 | 依赖 B；再加一个问题与一组阈值；无可观察收益假设 |
| 切片 D：status 显示成员/Jev/过期 | 缩小后现在做 | 只加"最近检查是否过期、finding 数、Jev 是否启用"；不做用量平台 |
| 切片 D：用 7 次过期做成本样本 | 现在做（本次已部分完成） | 驱动因素已定位为检查者自设 30–60s |
| vision-plan：pi、Kimi Code 接入 | 从计划删除 | 无需求证据；写成"不计划" |
| vision-plan：Grok、dsh、Cursor Agent | 从计划删除 | 同上 |
| debt-ledger：嵌入式 Codex 热接入 | 暂缓 | 无原生端点，不自研 |
| debt-ledger：跨供应商费用总计 | 删除为建设项 | 保留现有 `check_tokens` 记录 |
| debt-ledger：效果验证 | 升为主线 | 见下一节 |
| 新增：过期检查策略与检查者自调度 | 现在做 | 见下一节 |
| 新增：删除零使用机制（adjudicator/dispute、estimate、rule-library 部分） | 暂缓到主线交付后 | 先修回路，再按实验结果删 |
| 新增：决定 OpenCode/OMP 是否继续维护 | 先确认一个事实 | 用户日常用哪个宿主；只用 Codex 则冻结另两条，不删除、不再扩 |
| 新增：合并五份计划文档 | 暂缓 | 主线交付时顺带更新 handoff |

## 独立审查提出的下一次交付（待复核）

范围（只改 `lib/orbit/task_runtime.rb` 与检查 prompt，不新增文件，不改合同中"过期结论不得直接当作新版本问题"的语义）：

1. Root 处于 `active` 时不启动定时检查；检查只在 Root 空闲/交付、用户 `check`、或距上次检查超过较长上限（如 15 分钟）时启动。Root 活跃时检查者返回的 `next_check_seconds` 不生效。
2. 过期检查若 verdict 为 `correct` 且有 findings，不丢弃：以"基于旧版本，请自行核对当前是否仍成立"标注投递给 Root（不改任务状态、不记为 open finding）。这正是真实任务中 Root 手工做的事。
3. `orbit status` 显示最近检查是否过期、findings 数量。

用户可观察的完成条件：在下一个 ≥20 分钟、持续编辑的真实开发任务中，`state.json` 的 `comparison.stale_checks ≤ 1`，`correction_messages ≥ 1`（或到达 `complete`），`check_tokens` 低于基线 4,246,313 的 25%。

最小验证：`tests/task_runtime_test.rb` 增加 ≤3 个确定性用例（活跃时不启动、过期 correct 投递、空闲后检查）；一次真实任务的 `state.json` 对照。不重跑夹具验收，不新增供应商。

停止扩展并重新评估方向的证据：

- 两个真实任务后，投递的 findings Root 都判断为"已知/无价值"或全被 `dispute` → 独立检查者对用户任务无增益，Orbit 应退化为"交付时一次评审"工具。
- 修改后 `stale_checks` 仍 ≥ 3 → 问题在"检查耗时 > 编辑节奏"，需要更快/更窄的检查方式而非再加调度层。
- 一个真实任务的检查 tokens 仍超过 Root 自身用量 → 成本结构不成立。

## 缺证据的结论与最小实验

| 缺证据的结论 | 最小实验 |
| --- | --- |
| 独立检查能发现 Root 自己会漏掉的问题 | 接下来 3 个真实任务按上节方式运行；对每条投递 finding 记录 Root 反应（接受/已知/反驳）。接受率 < 1/3 即停止投入检查回路 |
| Jev 能减少过早检查或更早发现卡住 | 本机安装 Jev 版本跑同样 3 个任务；统计 `jev_assessed` 后过程检查中 verdict=`correct` 的比例，以及首次变化检查被推迟且未导致晚发现的次数。过程检查 ≥ 2/3 为 `continue` → 不发布默认开启 |
| OpenCode/OMP 是日常宿主 | 用户回答一次；或统计 `.orbit/tasks/*/state.json` 的 `connection.provider`。只有 Codex → 冻结另两条 |
| 多 Agent 分工是日常缺口 | 接下来 5 个真实任务里 Root 是否调用过一次 `delegate`。零次 → B/C 保持暂缓，考虑删除成员代码 |
| 检查成本在大仓库可接受 | 在 ≥5 万行项目上跑一次 `check`，记录快照大小与 input tokens；超过 Root 单轮用量 2 倍 → 检查必须限定到 diff 相关文件 |

前两项决定 Orbit 方向；后三项决定删什么。五项都不需要新建框架，只需运行现有代码并读 `state.json`。

## 项目复核与后续取舍（2026-09-18）

认可的主诊断：本次真实任务的 7 次已完成检查全部过期，Orbit 投递纠正为 0，检查用量记录为 4,246,313 tokens（含缓存口径）。检查者提出的部分问题由 Root 自行查询记录获得；这不能算作 Orbit 自动送达纠正。应先处理检查回路的有效性与成本，再评估新调度与跨 Agent 扩展。受控遗漏验收证明最小路径能工作，不证明日常任务有净收益。

以下审查建议尚不足以直接实施：

- 一次真实任务未使用 `delegate`，只说明那次没有分工，不能证明用户明确提出的 Herdr 协作没有需求，更不能据此删除成员能力。现有同宿主成员及停止已有受控验收；跨宿主路径须另作有界验证。即使没有成员，停止 Root 与自有检查进程仍有价值。
- 将过期的 `correct` finding 标注后直接发给 Root，仍会让旧问题进入当前执行上下文。现行合同要求产物或输入变化后重新核对，不能在“不改合同”的前提下把该建议视为已获准的投递语义。可以单独讨论旧结论是否作为待核对线索，但必须先规定证据、版本和防重复边界。
- Root 活跃时停止定时检查、改用 15 分钟上限，会改变约定时间和执行中纠偏的语义。应先定位重复触发原因，再提出满足现行合同的最小修改；若确需改变语义，先更新合同与 ADR。
- 一次样本不足以否定所有并行检查的收益，也不足以确定 25% 成本、至少 1 条纠正、三次任务接受率等硬门。无问题的任务不应为了达到纠正条数而制造消息；检查 tokens 含缓存，不能直接换算费用或与未可靠归属的 Root 用量比较。
- Jev 默认启用、跨 Agent 协作方向均来自用户明确决定。审查者可以质疑收益并提出实验，不能由“零使用”或候选阈值直接改成删除或默认关闭。真实效果不佳时先报告证据并重新评估。

据此，下一次交付优先处理检查重复过期和有效结果送达；Jev 真实增益与一种 Herdr 协作路径分别验证，后者成立后才评估 Jev 委派提示。具体范围与完成条件以[收敛计划](../plan/user-outcome-completion-plan.md)为准。

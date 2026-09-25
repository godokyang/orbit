# ADR-009 候选模型池真实验收证据（2026-09-25，已完成）

本记录只从只读 `/tmp/orbit-adr009-live/project/.orbit/tasks/` 的真实任务 `state.json`／`events.jsonl`／`checks/*/evidence.json`（连接 `provider=omp`）及真实 OMP 会话摘录事实。确定性测试不代替目标路径。**ADR-009 的选模实现已通过真实验收**：样本 4（失败→显式重选→任务 `complete`+停止确认）、样本 2（原生 GLM 成员→真实检查者 finding F1→根因修复→`resolved_ids`→停止确认）、样本 5（漂移中止+成员／任务双层停止确认）、样本 1／2 的成员成功与停止确认、样本 3 与中间漂移尝试的漂移检测／中止。唯一 live 边界是池内自动（非显式）**正**选择：真实自动尝试被质量线正确 fail-closed 拒绝、未建任务，该正选择分支由确定性选模测试覆盖。历史漂移失败尝试保留为回归历史，不因最终正样本改写。

## 样本 1：`6e0c5ef6-bc39-46eb-8a19-16f814d48339`

- 指令：成员实现 `wordcount.py`，Root 写 `README-notes.md`。
- 起始选模：显式 `zenmux/x-ai/grok-4.6`（`review.selection.source=explicit`、`in_pool=true`、`selected_for=start`）。
- 成员：原生 `task`／`omp_native_task`，模型 `zhipu-coding-plan/glm-5.3-flash`，`status=completed`，`members[*].result` 记录实现与自测。**成员成功一份正样本。**
- 检查者：**未运行**（`checks=[]`）。`events.jsonl` 记录 `runtime_error`：`Orbit::CheckRunner::Error: omp reviewer command is not available: bun`——验收环境 PATH 无 `bun`，独立 reviewer 无法启动。这是验收环境限制，不作为检查选模／执行通过或失败的证据。
- 停止：先 `stop_unconfirmed`（运行时因上述错误退出），随后 `stopped` 且 `stop_confirmation.confirmed=true`（Root 与成员 `status_after=idle`、`active_tools_after=0`、`async_jobs_settled=true`）。终态 `paused`（`stop_reason="The user requested cleanup after runtime exit"`）。**停止确认一份正样本。**

## 样本 2：`3dc116a4-abd2-4356-abb0-b42812ed00cf`

- 指令：成员实现 `linecount.py`，Root 写 `NOTES.md`，Root 调 `check`，通过后 `stop`。
- 成员：原生 `omp_native_task`，模型 `zhipu-coding-plan/glm-5.3-flash`，`status=completed`，`delegation_basis=root_without_hint`。**成员成功一份正样本。**
- 检查 #1（`manual_check`，初始显式 `zenmux/x-ai/grok-4.6`）：`result.verdict=check_failed`，`failure_kind=unavailable`、`failure_basis=heuristic`，错误含 `evidence problems: next_check_seconds must be a positive integer`。`checks/1/evidence.json` 显示模型确实响应（`review_ran=true`、`model=zenmux/x-ai/grok-4.6`、`raw_text` 解析出 `verdict=complete` 但 `next_check_seconds=0`），仅结果违反检查结果合同；分类应为 `invalid_result/structural` 而非 `unavailable/heuristic`。该误分类已在源码修正（`lib/orbit/omp_check_runner.rb` 依 `contract_problems` 归为 `invalid_result/structural`，含一条聚焦回归）。**本样本记录的是修正前的运行事实**，不在样本上重标为修复后行为。
- 失败后：任务保持活动且不自动终止；`events.jsonl` 依次记录 `check_failed` → `review_model_recorded`（模型 `zhipu-coding-plan/glm-5.3-flash`，原因 `explicit checker model after a failed check`，`in_pool=true`）→ `checker_model_block_cleared` → `checker_model_selected`（`source=explicit`，`selected_for=reviewer`）。**同一任务内显式重选一份正样本。**
- 重选后检查（GLM）：#2 `continue`，finding `F1`（快照仍含未要求的 `wordcount.py`／`README-notes.md`，来自样本 1）；#3 `correct`，F1 仍开；#4 `correct`、`resolved_ids=["F1"]`、`findings=[]`（多余文件移除，F1 关闭）。**finding→`resolved_ids` 闭合一份正样本。**
- 停止重试：`completion_stop_queued` → `stop_unconfirmed`（`Checker stop unconfirmed: not permitted to signal check process group 95989`）→ `checker_stop_verified`（pgid 95989 `Recorded process group no longer exists`）→ `stopped` 且 `confirmation.confirmed=true`；终态 `paused`。**停止重试确认一份正样本。**

## 样本 3（漂移，早期构建，停止未确认）：`98329663-68dc-4e40-b5fa-5f405b63338c`

- 指令：`drift probe 2`——派发生成的 GLM 成员 agent `orbit-m-zhipu-coding-plan-glm-5-3-flash-71b48ce8` 写 `driftprobe.txt`。
- **生成 GLM 成员被覆盖为 Grok。** Orbit 记录 `member_model_drift`（`expected=zhipu-coding-plan/glm-5.3-flash`、`actual=zenmux/x-ai/grok-4.6`）；成员子会话 `model_change` 也为 `zenmux/x-ai/grok-4.6`（`resolvedModelIsFallback=false`）。
- **漂移被记录并中止。** `member_model_drift_absorbed` 记录 `abort_attempted=true`、`abort_confirmed=true`；成员 `status=failed`、`result_delivery=refused_model_drift`、`error="model drift: expected … actual …"`。成员 `drift_stop` 记为 `unconfirmed: … stop_member did not confirm idle tools and reaped background work`——即中止动作被确认，但随后停止／回收未确认。成员未产出结果，本次未创建目标产物 `driftprobe.txt`。
- **`after 1 req` 的精确含义。** 该字样来自成员结果 `'(no output) after 1 req'`（duration 97ms），是 OMP 的 **`message_end` 计数**（该成员子会话只有一条被中止的 assistant 消息），**不是网络请求成功或 provider 传输的证明**。未直接观察到 provider 传输：子会话 assistant 消息 `stopReason=aborted`、`errorMessage="Request was aborted"`、`usage` 输入/输出/total 全 0。
- **停止未确认（早期构建）。** 两次 `stop_unconfirmed`（07:00:50 与 07:03:17 重试），错误 `Member orbit-4b4e00e8-…: stop_member did not confirm idle tools and reaped background work`；`member_stop_results[0].confirmation.confirmed=false`，原因：成员结果被接受但会话已处置（`registry_status=aborted`），OMP 18.2.8 异步处置 parked/released 会话且无公开完成信号。任务终态 `stop_unconfirmed`，`runtime.log` 同为 `stop_unconfirmed`。**这是早期构建在"被中止成员丢失存活会话"情形下的停止确认缺口**；最终构建 `6f808e8d…`（样本 5）首次同时确认成员与任务停止，本样本作为回归历史保留，不改写。

### 对照：旧源码漂移样本（静默，`0c194547-be62-42ce-9734-b74fe5278301`）

- 同样的覆盖：派发生成的 GLM 成员，实际记录模型 `zenmux/x-ai/grok-4.6`。
- 旧源码下成员 `task-result status=completed`（duration 18.1s；成员结果文本称已生成并核对 `driftprobe.txt`，当时项目内确有此文件），`members[*]` **没有** `model_drift`，也没有中止或拒绝交付；成员自己的文本还自称 `zhipu-coding-plan/glm-5.3-flash`，漂移被静默吞掉。
- 该对照说明新源码对同一覆盖能检测、记录并中止；但两次运行不是同一构建，停止结果也不同，只作漂移行为的定性对照，不作净收益或全路径证明。

## 样本 4（失败→显式重选→完成，新源码）：`193ad1dd-cd3d-4cbe-8a04-d712f633fe2f`

- 安装 release（取自失败栈）：`6e198faf68f8b12317c52a83`。指令：显式 `ghost/nonexistent` 起任务，立即 `check`，再用 `review-model` 重选 Grok，再 `check`，最后 `stop`。**无成员。**
- 检查 #1（显式 `ghost/nonexistent`）：快速失败，结构化 `unavailable`（`checks/1/evidence.json`：`error.kind="unavailable"`、`detail="model not in catalog: ghost/nonexistent"`、`review_ran=false`、`model=null`），`failure_basis=structured`。模型不在目录、未发起 provider 请求。**结构化失败分类一份正样本。**
- 同一任务显式重选：`review_model_recorded`（`zenmux/x-ai/grok-4.6`）→ `checker_model_block_cleared`（原因 `explicit review model recorded`）→ `checker_model_selected`（`source=explicit`，`selected_for=reviewer`）。
- 检查 #2（`trigger_cause=review_model`，`manual=true`）：`ok=true`、`model=zenmux/x-ai/grok-4.6`、**verdict `continue`**、`findings=[]`、`next_check_seconds=30`。**注意：不是 `complete`。**
- 收尾：`finalization_notice`（check 2）→ `completion_stop_queued` → `completed_via_finalized_stop`（check 2）→ `stopped`，`stop_confirmation.confirmed=true`（`status_after=idle`、`active_tools_after=0`、`async_jobs_settled=true`）；任务 `status=complete`。
- 与样本 2 合并：样本 2 证明成员→finding→纠偏→停止，样本 4 证明检查者失败→同一任务显式重选→完整 `complete`+停止确认。**完成来自 Root 显式停止，不是检查者的 `complete` 裁决**（检查 #2 为 `continue`）。

## 样本 5（漂移最终正样本，最终构建）：`bfcc270a-8c9c-45e8-a900-73c6ebf8d9fa`

- 指令：`drift probe 6 (bounded, final)`——派发生成的 GLM 成员 agent `orbit-m-zhipu-coding-plan-glm-5-3-flash-71b48ce8` 写 `driftprobe6.txt`，不重试成员。
- **生成 GLM 成员被覆盖为 Grok。** `member_model_drift`（`expected=zhipu-coding-plan/glm-5.3-flash`、`actual=zenmux/x-ai/grok-4.6`）；`abort_attempted=true`、`abort_confirmed=true`；成员 `status=failed`、`result_delivery=refused_model_drift`。
- **成员停止确认（早期构建下失败，本构建首次成功）。** `member_model_drift_absorbed` 的 `stop="confirmed"`；成员 `drift_stop="confirmed"`；成员 `stop_confirmation.confirmed=true`（`registry_status=aborted`、`status_after=disposed`、`active_tools_after=0`、`async_jobs_settled=true`；范围含 turn abort、owner-scoped async-job cancel+reap、幂等 session dispose、处置后 busy/tool 观察）。
- **任务级停止确认。** `stop_confirmation.confirmed=true`（`status_after=idle`、`active_tools_after=0`、`async_jobs_settled=true`，含成员确认）；`error=null`；终态 `paused`（`stop_reason="User requested stop"`）。无检查（`checks=[]`）。
- 构建：本次用安装 release `6f808e8d8f28e5e655f285f8`（version `0.7.0`，`.leases/86577.json` `held_at=2026-09-25T07:33:51Z`，与本任务 `attached` 时刻一致；运行中的 OMP 主机与连接 socket `/tmp/orbit-omp-IBfXw2` 同属该 release）。

### 漂移探测各次结果（保留失败，按构建区分）

| 任务 | 时间（UTC） | 构建线索 | 成员结果 | 成员停止 | 任务停止 |
| --- | --- | --- | --- | --- | --- |
| `98329663` | 07:00 | 与 `193ad1dd` 同宿主 → release `6e198faf…`（见样本 4 失败栈） | failed / `refused_model_drift` | `unconfirmed` | `stop_unconfirmed` |
| `3b5ec7de` | 07:11 | 安装目录已被后续安装替换，digest 未保留 | failed / `refused_model_drift` | `unconfirmed` | `stop_unconfirmed` |
| `c828d8b9` | 07:18 | 安装目录已被后续安装替换，digest 未保留 | failed / `refused_model_drift` | `unconfirmed` | `stop_unconfirmed` |
| `3cd9ac7f` | 07:29 | release `59335766592802d8d7100032`（0.7.0，lease `75819` held 07:28:20Z 对上 `attached` 07:29:04Z） | failed / `refused_model_drift` | `confirmed` | `stop_unconfirmed`（OMP 主机 socket 已消失，`connect(2)` ENOENT） |
| **`bfcc270a`** | 07:33 | **release `6f808e8d8f28e5e655f285f8`（0.7.0）** | failed / `refused_model_drift` | **`confirmed`** | **`confirmed`** |

`98329663`／`3b5ec7de`／`c828d8b9` 的成员停止失败原因相同：成员结果被接受但会话已处置，OMP 18.2.8 异步处置且无公开完成信号；`3cd9ac7f` 的成员停止已确认，但任务收尾时 OMP 主机 socket 已不存在。最终构建 `6f808e8d…` 首次同时确认成员与任务停止。以上早期失败保留为回归历史，不因最终正样本而改写。

### 实际耗时与用量（只读记录）

逐项取自各任务只读 `state.json`，回应交付 TODO 对「记录实际总时间与模型消耗」的要求：

| 任务 | created → finished（UTC） | 实际耗时 | `check_tokens` | `usage.tokens` | JEV stage1／stage2（in/out） |
| --- | --- | --- | --- | --- | --- |
| `3dc116a4` | 06:39:23 → 06:43:23 | 240.8s | 51,745 | null（未知） | 5059/222；3695/80 |
| `193ad1dd` | 07:05:27 → 07:06:48 | 81.9s | 14,282 | null（未知） | 1345/74；— |
| `bfcc270a` | 07:33:51 → 07:34:23 | 32.5s | null（无检查） | null（未知） | 1340/74；3649/80 |

`usage.tokens=null` 表示任务总用量**未记录为未知**，不以缺失推算、不换算成节省或净收益；`check_tokens` 为检查者用量合计（`bfcc270a` 无检查故为 null）。本表只记录已知用量与未知总量，不宣称任何净收益。

## 自动（非显式）池内选模：live 边界（正确拒绝，无任务）

- 指令：`Auto checker selection probe`——不传显式检查模型（不 `review-model`），期望由池内自动选检查者。
- **在任务开始前被正确 fail-closed 拒绝。** `orbit` 工具 `action=start` 返回错误文本（`isError=true`，逐字）：`orbit: no candidate pool model passed the JEV quality line; pass --review-model provider/id to choose explicitly`；未返回 `task_directory`，未创建任务，也未产生检查者选模。
- 原因：无候选通过 JEV 质量线（阈值 0.55），当前候选池缺乏质量证据，行为符合 ADR-009「池非空却没有合格检查模型时要求显式指定，不擅自使用池外默认模型」。**live start 本身只记录质量线拒绝，没有落任何分数。**GLM 0.27／Grok 0.04，以及「改动证据后本地 GLM 检查指标 0.42」，是另外单独发起的诊断 JEV 调用结果（为定位拒绝原因而做），不是失败 live start 记录的分数。
- **边界：**本样本只证明自动路径的 fail-closed 分支；池内自动**正**选择（存在合格候选时自动选出一个）未取得 live 样本，仅由确定性选模测试覆盖。

## Live 边界与验收结论

ADR-009 的选模实现已通过真实验收，未取得 live 样本的只有一处：

1. **池内自动（非显式）正选择。** 真实自动尝试被质量线正确拒绝（见上），未观察到自动选中某个候选；该分支由确定性选模测试（含正选择用例）覆盖，本次不宣称 live 自动正选择。

备注（非 ADR-009 选模项）：本记录各样本中检查者从未返回有效的 `complete` 裁决，任务级 `complete` 来自 Root 在显式重选后的显式停止（`completed_via_finalized_stop`）；这是任务运行／检查语义的观察，不影响 ADR-009 选模验收，记录以备对照。

## 已由真实样本覆盖

- **成员模型漂移抑制与停止确认。** 生成 GLM 成员被覆盖为 Grok 时，Orbit 记录 `member_model_drift`、中止并拒绝交付（`refused_model_drift`）。早期构建成员停止 `unconfirmed`（样本 3、`3b5ec7de`、`c828d8b9`）、`3cd9ac7f` 任务停止因主机 socket 消失未确认；最终构建 `6f808e8d…`（样本 5）首次同时确认成员与任务停止。旧源码样本（`0c194547`）则静默完成、无漂移记录。失败样本作为回归历史保留。
- **检查者失败→同任务显式重选→完成/停止。** 样本 2（成员→finding→纠偏→停止）与样本 4（失败→显式重选→任务 `complete`+停止确认）。

## 与文档状态的关系

本记录是 ADR-009 的真实验收证据，结论为**实现完成并已通过真实验收**。运行合同、ADR-009 与交付 TODO 的措辞以此为准，并标注唯一 live 边界：池内自动（非显式）正选择无 live 样本，由确定性选模测试覆盖。失败→同一任务显式重选→完整 `complete`+停止（样本 4）、成员→finding→纠偏→停止（样本 2）、成员模型漂移抑制+双层停止确认（最终构建 `6f808e8d…`，样本 5）均有真实正样本。早期漂移失败尝试（样本 3、`3b5ec7de`、`c828d8b9`、`3cd9ac7f`）保留为回归历史，不因最终正样本改写。未提交、推送或发布。

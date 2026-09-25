# Orbit OMP 接入修复验收记录（2026-09-25）

来源：过程诊断与实施复盘 [Zeen 页面走查任务中的 Orbit 流程](zeen-page-capture-orbit-process-review-20260925.md)（长期保留）。本文只记录隔离 `orbit omp` 真实验收事实，不改变产品语义，不把历史 Zeen 任务判为 `complete`。**所有隔离任务已停止**，最终状态以各任务 `state.json` 为准；本文不把 Root 自述当作机器事实，自述处均标注来源。事件时间均为 UTC；目录 mtime 为本机时间（UTC+8）。**本记录的三套安装均为 `0.7.1` 构建，是 0.7.1 的历史验收证据。当前源码与安装均已为 `0.7.2`（首个源码提交 `9bb24735dd797b621f5b1b1dff983348d5110a67`，release `636cef887383e5f2f818a6c3`，`content_digest 5812d5cdf71f070a135de512d22780ccb4f8717f31806bda4670ae9e85ce4cbe`，`installed_at 2026-09-25T15:59:42Z`）；0.7.2 未另跑真实模型任务，因此本文的十个真实任务结论不替代 0.7.2 的独立真实模型验收。**

## 安装构建 digest

本记录跨**三套安装**。**前八个旧 build、第九个中间 build、第十个最终 build，请勿混同**：

| 构建 | `content_digest` | release id | `installed_at` | 覆盖任务 |
| --- | --- | --- | --- | --- |
| 旧 build | `8ddc99b372c0f249a43dc69514303fa55fbd1c76a9c197fe804a1f2a87093582` | `e666471e019b0cd17f20c611` | `2026-09-25T14:06:52Z` | 第 1–8 个（`14:08:50Z`–`15:15:52Z`） |
| 中间 build | `417a0ff4cb8fa7f1f61b77d6d2731cd85ac8241b5c4feece87b6d127e5bd6048` | `ee7fbb9e73625189dff96c78` | `2026-09-25T15:26:56Z` | 第 9 个 `final_gate`（`15:28:45Z` 起） |
| 最终 build（本次验收） | `e0e1e336199d10d196ddd2add1ac865e8bca25064bf3b923101adb95cb1c2799` | `d4f7194c84d401dd1c3976ec` | `2026-09-25T15:34:53Z` | 第 10 个 `final2`（`15:36:32Z` 起） |

- 共同项（三套安装均为 `0.7.1` 构建）：版本 `0.7.1`；source commit `1cee2166654cce28b3f961223330ee9c4c3a0478`（`dirty: true`）；入口 `~/.local/bin/orbit` → `~/.local/share/orbit/orbit/current`；OMP `18.2.8`（`lib/orbit/omp_entry.rb` `PINNED_OMP_VERSION`）。
- 三套 digest 各不相同：旧→中间，最新代码审核修改了**完成拒绝的判定优先级**与**三个原因码的下一动作**（`lib/orbit/task_runtime.rb` 的 `completion_gate` 顺序与 `COMPLETION_NEXT_ACTIONS`）；中间→最终，只改了根 `README.md`“当前范围与文档”段落的文案（`git diff --stat README.md`：1 行增/1 行删，**未改代码**），随后 `sh install.sh` 重装为 `e0e1e336…`。当时 `orbit version --json` 返回 `version 0.7.1`、`content_digest e0e1e336…`、`installed_at 2026-09-25T15:34:53Z`（该命令**不返回 release 字段**）；release id `d4f7194c…` 取自 `.orbit-release.json` 所在的 release 目录名。
- **第 1–8 个任务运行在旧 build 上，不对应当前 0.7.2 源码（`9bb24735…`）**：旧 build 在安装时与当时工作区一致，但工作区此后有多次代码改动（含后续的 0.7.2 版本提升），因此**不能说它与当前 0.7.2 源码逐字节相同**。第 9 个 `final_gate` 回归的是中间 build `417a0ff4…`；第 10 个 `final2` 回归的是**本次验收最终 build `e0e1e336…`**。
- 三套 build 的 source commit 相同（`1cee216…`，`dirty: true`），差异来自工作区未提交改动，**不能以 commit 区分三套 build**。

## 验收环境与记录位置

- 根目录：`/tmp/orbit-goal-accept-20260925-8x5iv1tb/`（本机解析为 `/private/tmp/...`）。
- 每个子目录是一个真实临时 Git 项目 + `orbit omp` 会话 + `.orbit/tasks/<id>/` 任务记录。
- 检查结果与事件以任务目录的 `state.json`、`events.jsonl`、`members.json`、`instruction.txt` 为准。

## 十个真实任务的事实与路径

> 第 1–8 个在旧 build 上运行；第 9 个 `final_gate` 在中间 build（`417a0ff4…`）上运行；第 10 个 `final2` 在本次验收最终 build（`e0e1e336…`）上运行。

| 场景 | 任务 id | 最终状态 | 记录路径 |
| --- | --- | --- | --- |
| negative（局部修复、无需成员） | `a05f0ece-7622-47c2-9246-d60dac266bbd` | `complete` | `negative/.orbit/tasks/a05f0ece-7622-47c2-9246-d60dac266bbd/` |
| parallel（两独立模块、尝试派发） | `7422b628-277e-4328-936c-22088935e1ce` | `complete` | `parallel/.orbit/tasks/7422b628-277e-4328-936c-22088935e1ce/` |
| gate（完成硬门） | `2cf69377-1a3f-45a3-9369-4558b9e3a10e` | `complete` | `gate/.orbit/tasks/2cf69377-1a3f-45a3-9369-4558b9e3a10e/` |
| pause（显式暂停） | `0b141890-b657-4a79-8769-6074551d872d` | `paused` | `pause/.orbit/tasks/0b141890-b657-4a79-8769-6074551d872d/` |
| interrupt（用户中断） | `c40d5a4e-6893-4c6d-a6f3-43ad87a050ed` | `paused` | `interrupt/.orbit/tasks/c40d5a4e-6893-4c6d-a6f3-43ad87a050ed/` |
| positive2（两独立模块、无合格候选） | `7d3d1496-5144-4937-8b9a-ea14abf3344f` | `complete` | `positive2/.orbit/tasks/7d3d1496-5144-4937-8b9a-ea14abf3344f/` |
| positive3（两独立模块、官方来源证据） | `9c7f39b1-e64c-48f9-b824-21938bcced3c` | `complete` | `positive3/.orbit/tasks/9c7f39b1-e64c-48f9-b824-21938bcced3c/` |
| positive4（两独立模块、隔离 XDG 模型池） | `617fa5e7-a129-48b3-bb0e-c9bfee74c531` | `complete` | `positive4/.orbit/tasks/617fa5e7-a129-48b3-bb0e-c9bfee74c531/` |
| final_gate（中间 build 上的完成硬门回归） | `f3c8dfe9-964f-4731-bd42-dfefef6282fb` | `complete` | `final_gate/.orbit/tasks/f3c8dfe9-964f-4731-bd42-dfefef6282fb/` |
| final2（本次验收最终 build 上的完成回归） | `61aba2a4-91db-4f70-8ac3-3d2d0cad290b` | `complete` | `final2/.orbit/tasks/61aba2a4-91db-4f70-8ac3-3d2d0cad290b/` |

关键事实（按事件序列）：

- **negative**：`attached` → 1 次**手动** artifact 检查（`continue`）→ `finalization_notice` → `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。0 成员，`delivery_digest=sha256:d1de1601…`，**无** `completion_stop_rejected`。局部修改无需派发成员。
- **parallel**：`attached` → 4 次检查（#1 `check_failed`、#2/#4 手动、#3 自动）→ 1 名成员登记并回收 → `finalization_pending` → `finalization_pending_stale` → `finalization_notice` → `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。`delivery_digest=sha256:e4b64f0d…`。完成路径机械通过；成员派发见下节失败。
- **gate**：`attached` → **`completion_stop_rejected`（`source=cli`，`reason=no_current_finalization_notice`，`14:22:43Z`）** → 1 次手动 artifact 检查（`continue`）→ `finalization_notice` → `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。证明无当前有效 notice 的完成意图被同步拒绝（不排队、不改状态），随后按下一动作请求终检再正式完成。
- **pause**：`attached` → `jev_assessed` → `stopped`。0 检查、0 通知、0 成员；`stop_reason` 是显式暂停说明（“no completion intent … Remaining review steps: request independent check … then stop intent=complete”）。**未**走完成路径。
- **interrupt**：`attached` → `jev_assessed` → `stopped`。`stop_reason="The user interrupted the Root turn"`；0 检查、无通知。只证明中断落 `paused`，未到达终检。
- **positive2**：`attached` → `jev_assessed` → `model_evidence_used` → `delegation_pending_candidates`（两名候选 quality `0.19`/`0.36`，均 `pending_quality`，**无最终 `delegation_hint`**）→ 1 次**手动** artifact 检查（`complete`，0 findings）→ `finalization_notice` → `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。0 成员，`delivery_digest=sha256:eb46ed1d…`，`stop_confirmation.confirmed=true`；`stop_reason` 记载 `npm test passes 8/8`（原任务内执行次数为 Root 自述，收尾已在隔离 fixture 独立复跑确认 8/8），并说明“No delegation_hint was emitted, so src/money.mjs was implemented here rather than delegated”。即两模块均由 Root 亲自完成，本地 8/8 通过后经独立终检 `complete`。
- **positive3**：`attached` → 4 次 `jev_assessed` → `model_evidence_submitted`（2 条）→ `model_evidence_used`（root 身份用 DeepSeek 官方发布页/定价页等**官方来源**）→ `delegation_pending_candidates`（1 名候选 `zhipu-coding-plan/glm-5.2`，quality `0.41` / time `0.34`，`pending_quality`，**无最终 `delegation_hint`**）→ `native_collaboration`（hub inbox，空）→ 1 次**手动** artifact 检查（`continue`，0 findings）→ `finalization_notice` → `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。0 成员，`delivery_digest=sha256:0dadafa3…`，`stop_confirmation.confirmed=true`；`stop_reason` 称 `node --test passes 10/10`（原任务内计数为 Root 自述，收尾已在隔离 fixture 独立复跑确认 10/10）且 CSV 由 Root 自行完成。
- **positive4**：`attached` → 多次 `jev_assessed` → `model_evidence_submitted`（一次 `model_evidence_mismatch`）→ `model_evidence_used` → 4 次 `delegation_pending_candidates`（候选 `zenmux/openai/gpt-5.6-sol`，quality `0.30` / time `0.25`，`pending_quality`，**无最终 `delegation_hint`**）→ 18 次检查（4 次手动）→ 9 个 finding 全部 `resolved` → 最终新手动终检 `finalization_notice` → `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。0 成员，`delivery_digest=sha256:c6b45595…`，`stop_confirmation.confirmed=true`；`stop_reason` 称 `node --test = 14/14 pass`（原任务内计数为 Root 自述，收尾已在隔离 fixture 独立复跑确认 14/14），并列出 8 项修正（原文写“seven reported findings”，与本任务 9 个 finding 不完全一致，见疑点）。
- **final_gate**（中间 build）：`attached` → `jev_assessed` → **`completion_stop_rejected`（`source=cli`，`reason=no_current_finalization_notice`，`15:28:54Z`）** →（第二用户回合）`instruction_amended` → 3 次检查（#1 自动 `complete` 被 `automatic_check_complete_ignored`；#2 自动 `continue`；#3 手动 `complete`）→ `finalization_notice`（check #3）→ `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。0 成员、无 `delegation_hint`，`delivery_digest=sha256:d1de1601…`，`stop_confirmation.confirmed=true`。
- **final2**（本次验收最终 build）：`attached` → `jev_assessed` → 1 次**手动** artifact 检查（`continue`，0 findings）→ `finalization_notice`（check #1，`15:37:04Z`）→ `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`。0 成员、无 `delegation_hint`，`delivery_digest=sha256:d1de1601…`，`stop_confirmation.confirmed=true`；**无** `completion_stop_rejected`（本场景首回合即直接请求手动终检，未出现被拒的完成意图）。

### final_gate 两回合完成硬门回归（中间 build `417a0ff4…`）

- **首回合**收到 `stop intent=complete`：同步 `completion_stop_rejected`（`source=cli`，`reason=no_current_finalization_notice`，`detail="no finalization notice exists for the current artifact and input version"`，`15:28:54Z`），任务保持可继续（未排队、未改状态）。
- **第二用户回合**：`instruction_amended`（`15:29:17Z`，`source.kind=omp_user_message`、id `61923759`）要求按拒绝回执请求一次手动检查并等待 notice。该回合 UI 观察到状态显示“**Orbit：执行中（尚未收到终检通知）**”并随后发起手动 `check`（此 UI 文本为协调者观察，不在 `state.json`）。
- 检查 #2 的 `evidence.json` 原文独立复核了首回合回执：`completion_stop_rejected`、`reason=no_current_finalization_notice`、`next_action = request one manual check via action=check then end the turn`，且未发现直接改任务记录的迹象。
- 检查 #3（`manual=true`，`15:30:47Z`）verdict `complete` → `finalization_notice`（version `sha256:d1de1601…`）→ `completion_stop_queued` → `completed_via_finalized_stop` → `stopped`（`stop_confirmation.confirmed=true`）。机器记录 3 checks、`check_tokens=81386`、JEV stage1 `3339/148`、总时长 `129.6s`。

### final2 本次验收最终 build 完成回归（`e0e1e336…`）

- 在**本次验收最终 build**（`content_digest e0e1e336…`，release `d4f7194c…`，`installed_at 2026-09-25T15:34:53Z`）上，首回合即请求一次手动独立终检：`check_started`（`15:36:49Z`）→ `check_finished`（`15:37:04Z`）。
- 该检查 `manual=true`、verdict `continue`、0 findings；`evidence.json` 的 `fingerprint_before=fingerprint_after=sha256:d1de1601…`，与 `state.delivery_digest` 及 `notice.version` 一致。检查者 `zenmux/deepseek/deepseek-v4.1-flash`、SDK `18.2.8`。
- 有效 `finalization_notice`（`15:37:04Z`，check 1，message_id `188f9f85-7abe-4607-b224-6a8f31288634`）→ `completion_stop_queued`（`15:37:08Z`）→ `completed_via_finalized_stop`（`15:37:13Z`）→ `stopped`；`stop_confirmation.confirmed=true`。
- `summarize_task.rb` 输出 `status=complete`、`event_counts` 含 `finalization_notice`/`completion_stop_queued`/`completed_via_finalized_stop` 各 1；`check_tokens=17335`、JEV stage1 `1723/74`、JEV `delegatable=0.30`、总时长 `41.6s`。
- 本场景证明本次验收最终 build 的“手动终检 → 有效 notice → 显式完成停止”路径可用；**不主张**它是 delegation_hint 正样本（0 成员、无 hint）。

### positive4 的返工与 Amendment 1（如实记录）

- 早期手动检查确实发现缺陷：检查 #1（自动）1 个 finding，检查 #2（`manual=true`，`14:59:37Z`）verdict `correct`、3 个 findings。检查/纠正贯穿 #1–#17（#11/#12 为 0 finding 的 `complete`），最终 9 个唯一 finding 全部 `resolved`（`state.findings`）。
- 自动复核一度返回 `complete`（checks #11/#12），但事件 `automatic_check_complete_ignored`（`15:06:47Z`、`15:07:11Z`）表明它们未被当作终检；随后有一段仅自动复核的等待（`15:08–15:11Z` 连续 `jev_assessed`）。
- `instruction_amended`（`15:12:08Z`）对应 Amendment 1（`amendments/1.txt`，`source.kind=omp_user_message`、id `816854e0`）。Amendment 文本明确：“后续自动复核已确认没有开放 finding；请按 Orbit 任务合同为当前最终版本**重新请求一次手动独立终检**……不要把自动复核的 complete 当成最终通知。”
- 之后重新请求手动终检；最终检查 #18（`manual=true`，`15:15:38Z`）产生 `finalization_notice`（消息 `9d2bc11b-6873-4762-a56d-16349fa9787c`），随后 `complete`。检查 #18 原文也记“已按 Amendment 1 重新请求人工独立终检”。
- 说明：Amendment 的**机器记录**只有 `omp_user_message`/`instruction_amended`；“Controller 用户级提醒”这一操作者身份来自协调者说明，不在 `state.json` 中，未作为机器事实。

## 失败：parallel 机械路径通过，但无 `delegation_hint`，Root 自行派发

- Jev 第一阶段 `delegatable` 为 `0.92 / 0.91 / 0.94 / 0.92`（均 ≥ 0.60），程序产出 `delegation_pending_candidates`（`14:14:32Z`），两名候选 quality 分别为 `0.2`（`opencode-go/deepseek-v4.1-flash`）与 `0.45`（`kimi-code/k3-256k`），状态均为 `pending_quality`（低于质量线）。
- 全程**没有最终 delegation_hint**；成员登记时 `native_member_reconciled` 记 `basis: "root_without_hint"`。
- Root 仍在 `14:15:31Z` 通过原生 `task` 自行派发成员 `orbit-6b9bbf12-e002-49f0-89da-5ddb8ea86fdc`，`14:17:36Z` 回收结果，最终完成。
- **本轮验收要求（判定为失败）**：本次验收明确要求“只在这一最终 hint 出现后才派发”；Orbit 全程未给出最终 hint，Root 仍自行派发，**违反了这次验收要求**。因此本场景判定为**未按要求通过**，不能作为 delegation_hint 正样本。
- **合同口径（与上面的验收要求分开）**：合同并未禁止 Root 在无 hint 时自行派发，也没有把它定义为产品缺陷。所以这是一次“验收要求vs.实际行为”的失败，不是完成路径或完成硬门缺陷。
- **本轮总体判定**：**正向 delegation_hint 场景本轮未取得**。positive2/positive3/positive4 同样未得到最终 hint（候选 quality `0.19/0.36`、`0.41`、`0.30`，均 `pending_quality`），三者的另一模块都由 Root 自行完成；final_gate/final2 更连 `delegation_pending_candidates` 都未产生。**机械成员路径**（原生 `task` 派发 → Orbit 登记 → `native_member_reconciled` 回收）**只由 parallel 一次 `root_without_hint` 样本证明**，不能据此认为 hint 驱动派发成立。用户已决定将正向正样本作为后续独立目标；本轮按已证实范围收口，**不声称该正样本通过**。

## 检查者来源与 stop_confirmation

检查者模型来源（`state.review.selection`，均为 `version=orbit-checker-selection-v1`、`source=explicit`）：

| 场景 | 模型 | `in_pool` | `selected_for` | 说明 |
| --- | --- | --- | --- | --- |
| negative | `zenmux/x-ai/grok-4.6` | `false` | `start` | 显式模型在候选池外，`notice="explicit review model is outside the candidate pool"` |
| parallel | `kimi-code/k3-256k` | `true` | `reviewer` | `review_model_recorded`：原 `opencode-go/gpt-6-luna` 不在目录，改用池内独立家族模型 |
| gate | `kimi-code/k3-256k` | `true` | `start` | — |
| pause | `kimi-code/k3-256k` | `true` | `start` | — |
| interrupt | `kimi-code/k3-256k` | `true` | `start` | — |
| positive2 | `kimi-code/k3-256k` | `true` | `start` | 手动终检 verdict `complete`，0 findings |
| positive3 | `zhipu-coding-plan/glm-5.2` | `true` | `start` | 手动终检 verdict `continue`，0 findings |
| positive4 | `zenmux/openai/gpt-5.6-sol` | `true` | `start` | 4 次手动检查；最终手动终检 verdict `continue`，`resolved_ids=[csv-null-options-accepted]` |
| final_gate | `zenmux/deepseek/deepseek-v4.1-flash` | `false` | `start` | 终检 `check #3` verdict `complete`，0 findings；`notice="explicit review model is outside the candidate pool"` |
| final2 | `zenmux/deepseek/deepseek-v4.1-flash` | `false` | `start` | 唯一一次手动终检 verdict `continue`，0 findings；`notice="explicit review model is outside the candidate pool"` |

- **检查者来源**取自 `state.review.selection`（`version=orbit-checker-selection-v1`、`source=explicit`）与 `checks/<n>/evidence.json` 的 `model` 字段，两者一致。
- **快照核对**（只读 `state`/`checks`）：positive3 终检 `checks/1/evidence.json` 的 `fingerprint_before=fingerprint_after=sha256:0dadafa3…`，positive4 终检 `checks/18/evidence.json` 的 `fingerprint_before=fingerprint_after=sha256:c6b45595…`，final_gate 终检 `checks/3/evidence.json` 与 final2 终检 `checks/1/evidence.json` 的 `fingerprint_before=fingerprint_after=sha256:d1de1601…`，都等于各自 `state.delivery_digest`，且 `notice.version` 与之一致。其余任务的 `notice.version` 同样等于 `state.delivery_digest`。SDK 版本 `18.2.8`。

`stop_confirmation`（十个任务全部）：`confirmed: true`，`native_owner: "Main"`，`status_after: "idle"`，`active_tools_after: 0`，`async_jobs_settled: true`，`scope="Native session execution, attached shell processes and owner-scoped async jobs; no unmanaged detached work"`。parallel 额外包含该成员的停止确认（`confirmed: true`，`registry_status: "idle"`，`active_tools_after: 0`）。

## 速度 / 质量 / token 成本

全部取自 `state.usage`、`state.elapsed_seconds` 与 `state.checks`（均为机器字段；测试通过次数另见下方“确定性收尾检查”的隔离 fixture 复跑）：

| 场景 | 检查数（手动） | 唯一 finding | `check_tokens` | JEV stage1 in/out | 总时长 (s) | 检查者模型 |
| --- | --- | --- | --- | --- | --- | --- |
| negative | 1（1） | 0 | `14717` | `1394/74` | 38.8 | `zenmux/x-ai/grok-4.6`（池外） |
| parallel | 4（3） | 0 | `54948` | `21626/444` | 334.1 | `kimi-code/k3-256k` |
| gate | 1（1） | 0 | `16336` | `1729/74` | 49.9 | `kimi-code/k3-256k` |
| pause | 0（0） | 0 | — | `1581/74` | 9.4 | `kimi-code/k3-256k` |
| interrupt | 0（0） | 0 | — | `1528/74` | 12.4 | `kimi-code/k3-256k` |
| positive2 | 1（1） | 0 | `18522` | `9566/148` | 98.5 | `kimi-code/k3-256k` |
| positive3 | 1（1） | 0 | `68770` | `28084/444` | 494.8 | `zhipu-coding-plan/glm-5.2` |
| positive4 | 18（4） | 9（全 resolved） | `389062` | `76348/1258` | 1313.1 | `zenmux/openai/gpt-5.6-sol` |
| final_gate | 3（1） | 0 | `81386` | `3339/148` | 129.6 | `zenmux/deepseek/deepseek-v4.1-flash`（池外） |
| final2 | 1（1） | 0 | `17335` | `1723/74` | 41.6 | `zenmux/deepseek/deepseek-v4.1-flash`（池外） |

- **质量**：positive4 是唯一大量触发“检查→纠正→复检”闭环的样本（18 次检查、9 个唯一 finding 全 resolved，且由手动终检复核），质量证据最强；其余任务终检 0 finding。final_gate/final2 的价值不在缺陷量，而在分别于**中间 build**与**本次验收最终 build**上验证了完成硬门的“拒绝→继续→终检→完成”（final_gate）与“手动终检→完成”（final2）全链路。
- **成本**：`check_tokens` 集中在 positive4（`389062`，约占全部 `check_tokens` 的 59%，即 `389062/661076`）；次高为 final_gate（`81386`，其中含一次被忽略的自动检查与一次自动 `continue`）。
- **速度**：positive4 总时长 `1313.1s`（返工所致），positive3 `494.8s`，final_gate `129.6s`，final2 `41.6s`，其余 ≤ `334.1s`。

## 确定性收尾检查（代码对应本次验收最终 build；已通过）

按 `orbit-real-acceptance` 收尾清单执行，各项均通过：

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 完整 `npm test` | 通过 | `/tmp/orbit-goal-final-npm-test-20260925.log`：`check:version` 报 `Version and lockfile consistent: 0.7.1`，随后全部 Ruby/Node/Bun 测试无失败阶段，末行 `INSTALL_TEST_PASS shell_configuration` |
| `npm pack` dry-run | 通过 | `/tmp/orbit-goal-final2-pack-20260925.json`：`@godokyang/orbit@0.7.1`，`48` 个文件，`size 194444`，`unpackedSize 647850`，`shasum fdb5dffb…`，`integrity sha512-FTVXiE…` |
| Skill validator | 通过 | 按收尾清单执行（无独立日志路径） |
| `git diff --check` | 通过 | exit `0`（记录时复核确认） |
| 重装 + `orbit version --json`（中间 build） | 通过 | `sh install.sh` 成功（`/tmp/orbit-goal-final-install-20260925.log`：`Installed orbit 0.7.1 (1cee216…)`）；`orbit version --json` 返回 `content_digest 417a0ff4…`、`installed_at 2026-09-25T15:26:56Z`；release id `ee7fbb9e…` 取自 release 目录名 |
| 最终 build 重装 + `orbit version --json`（本次验收） | 通过 | `sh install.sh` 成功（`/tmp/orbit-goal-final2-install-20260925.log`：`Installed orbit 0.7.1 (1cee216…)`）；`orbit version --json` 返回 `content_digest e0e1e336…`、`installed_at 2026-09-25T15:34:53Z`；release id `d4f7194c…` 取自 `.orbit-release.json` 所在 release 目录名 |
| 三个任务产物的隔离 fixture `npm test` 复跑 | 通过 | positive2 `8/8`、positive3 `10/10`、positive4 `14/14`，均 exit `0`（Controller 收尾，本轮终端结果） |

说明：上表 `npm test` 证据产生于中间 build 源码状态。中间→最终 build 之间**只改了根 `README.md` 文案、未改代码**，因此该 `npm test` 结论同样适用于最终 build 的代码；最终 build 未再单独复跑。`npm pack` 因打包包含 `README.md`、文案改动会影响打包摘要，已按**本次验收最终 build**重新执行并引用 `/tmp/orbit-goal-final2-pack-20260925.json`（不再使用先前的 pack 数值）。

`npm test` 日志中偶见 `refused … refusal record failed: exit 1` 与 `failed_*` 用例名，均属负向用例的预期路径，不是套件失败。

关于测试数字的区分：**原任务内执行次数**来自 `stop_reason`（Root 自述）；**本次收尾复跑**由 Controller 在三个已完成任务各自的隔离 fixture 目录独立执行，已独立确认**当前产物**的通过状态（数字与 `stop_reason` 一致）。

## 未跑 / 待跑项

- **所有隔离任务已停止**：十个任务均已终态（`8 complete` + `2 paused`，见上表），本轮无运行中任务。
- **正向 delegation_hint 正样本**：**本轮整体仍未取得**。parallel/positive2/positive3/positive4 的候选 quality 均未过线；final_gate/final2 连 `delegation_pending_candidates` 都未产生。**用户已决定把“hint 驱动派发”的正样本作为后续独立目标**，本轮按**已证实范围**收口：只记录“机械成员路径已由 parallel 的 `root_without_hint` 证明”“完成硬门/完成路径已在三套 build 上各有真实样本（旧 build `gate`：拒绝→完成；中间 build `final_gate`：拒绝→继续→终检→完成；最终 build `final2`：手动终检→完成）”，**不主张正向 delegation_hint 正样本通过**。
- **`session_stop` 有界续跑**：首轮明确不实现（提案 §方案口径）；只有隔离真实任务再证实 Root 可绕过终检时才设计。
- **Zeen 历史任务**：保持 `paused` 历史原状，最终报告没有 Orbit 终检结论，不回填 `complete`、不新增复核。

## 证据疑点

1. **pause 残留任务目录**：`pause/.orbit/tasks/e12cb6ee-d8cf-440a-85b3-acacf78cf0da/` 只有 `instruction.txt` 与空 `inbox/`，无 `state.json`/`events.jsonl`。应是未绑定的重复启动残留，不是可验收任务；不得据此推断 pause 有两次真实运行。
2. **parallel 成员 basis**：`root_without_hint` 是机器记录的事实，但成员派发文本需会话记录才能复核；仅凭 `member_result_recorded` 次数不能断定 Root 的派发动机。
3. **negative、gate、final_gate、final2 的 `delivery_digest` 相同**（均为 `sha256:d1de1601…`）：四者都把同一个小文件的 `formatAmount` 修成同一内容，digest 相同属预期，不能据此认为它们是同一产物或同一构建（final_gate 运行在中间 build `417a0ff4…`、final2 运行在最终 build `e0e1e336…` 的代码上）。
4. **interrupt 未覆盖完成路径**：该场景在请求终检前被中断，只证明中断→`paused`，不能作为终检或完成硬门证据。
5. **三套安装 digest，前八任务不对应当前 0.7.2 源码**：第 1–8 个任务在旧 build `8ddc99…`（`installed_at 14:06:52Z`）上运行；代码审核修了完成拒绝优先级与三个原因码下一动作后重装为中间 build `417a0ff4…`（`installed_at 15:26:56Z`），第 9 个 `final_gate` 用它回归；中间→最终**只改了根 `README.md` 文案（未改代码）**，重装为本次验收最终 build `e0e1e336…`（`installed_at 15:34:53Z`），第 10 个 `final2` 用它回归。因此**前八任务的完成/拒绝结论只代表旧 build**；本次验收最终 build 的完成路径只由 `final2` 一次真实样本支撑（其代码与中间 build 相同）。`releases/` 只保留当前一套，旧/中间 release 已不在目录中，无法就地复跑。
6. **时间基准**：事件为 UTC，目录 mtime 为 UTC+8；旧安装 `14:06:52Z` 距首个任务、中间安装 `15:26:56Z` 距 `final_gate`、最终安装 `15:34:53Z` 距 `final2` 均约 2 分钟，不能把各次安装前的手工操作混入结论。
7. **positive4 自述与机器记录不一致**：`stop_reason` 写“All seven reported findings were corrected”，但紧接着列出 8 个条目，且 `state.findings` 实为 **9** 个唯一 finding（全 `resolved`）。三处数字互不一致，机器记录以 `state.findings=9` 为准。
8. **测试数字来源（原任务 vs 收尾复跑）**：**原任务内执行次数**出自 `stop_reason`（Root 自述），独立终检原文未断言计数（positive3 检查称“every test assertion was hand-traced … passes”，positive4 检查只引用 `test/csv.test.mjs:40、49`）。但 **Controller 收尾已在三个任务各自的隔离 fixture 目录独立复跑 `npm test`：positive2 `8/8`、positive3 `10/10`、positive4 `14/14`，均 exit `0`**，因此**当前产物**的通过状态已独立确认，不再是仅凭 Root 自述。
9. **Controller 提醒身份不可机器核对**：Amendment 1 的机器来源仅为 `omp_user_message`（id `816854e0`）；“Controller 用户级提醒”这一操作者身份不在 `state.json`，只能作为协调者说明。
10. **positive4 证据提交曾不匹配**：事件 `model_evidence_mismatch`（`14:57:03Z`）后重新提交并 `model_evidence_used`；说明模型证据提交曾出现一次结构/来源不一致。
11. **final_gate 的 UI 状态文本无机器记录**：第二回合终端显示的“Orbit：执行中（尚未收到终检通知）”来自协调者观察，`state.json`/`events.jsonl` 不含该展示文本；机器侧只能证明 `instruction_amended`（id `61923759`）、`check_started` 与 `finalization_notice` 存在。首回合的 `completion_stop_rejected` 回执则是机器记录（并已被检查 #2 原文复核）。
12. **中间→最终 build 只改了根 `README.md` 文案**：`417a0ff4…` 与 `e0e1e336…` 的差异来自根 `README.md`“当前范围与文档”段落的文案（`git diff --stat README.md` = 1 行增/1 行删，**未改代码**），随后 `sh install.sh` 重装。因此最终 build 的代码与中间 build 相同，先前 `npm test` 结论仍适用；但打包包含 `README.md`，文案改动使 `npm pack` 摘要变化，故 `npm pack` 已按本次验收最终 build 重新执行并引用 `/tmp/orbit-goal-final2-pack-20260925.json`（`48` 文件、`size 194444`、`unpackedSize 647850`、`shasum fdb5dffb…`），不再使用先前 pack 数值。
13. **final2 的终检 verdict 为 `continue` 仍产出有效 `finalization_notice`**：与 positive4 最终手动终检（`continue` → notice）一致，说明“手动检查产出 notice”不要求 verdict 为 `complete`；本记录只作事实记载，不断言该规则的一般条件。

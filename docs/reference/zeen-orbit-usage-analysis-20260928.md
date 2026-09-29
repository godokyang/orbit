# Zeen 近期使用 Orbit 的效果与缺口（2026-09-28）

> 类型：历史证据／研究，按标题及正文记录的日期、版本和配置解读。下文“当前”“本轮”及旧规则不代表现行行为或授权；当前状态见[交接](../plan/handoff.md)，现行语义见[任务合同](../../contracts/task-runtime.md)。

> 对照[Orbit 产品目标](../../README.md#orbit)、[现行合同](../../contracts/task-runtime.md)、[Zeen AI 首轮反馈](zeen-mobile-ui-orbit-user-feedback-20260928.md)、同一 OMP 会话的任务记录及本仓 Git 提交。四个反馈任务是主样本；同会话更早的派发记录用于厘清「本次没有成员」与「此前唤起过成员」的边界。任务时间戳均为 UTC，除非标出 +0800。
>
> **结论先行：**独立检查确实拦下遗漏，但同一产物被误判后，裁定已推翻误判，状态的「下一动作」仍把旧误判当事实。**更大的产品目标缺口是多 Agent：同会话确有 Root 以旧的 OMP 默认任务模型主动派发的 13 项成员工作，却没有证据证明 Jev 选模建议促成过一次成功派发；9 月 28 日的任务全部无成员。** **启动问题也不止显式点名 Orbit 的漏识别：用户进一步澄清，不点名 Orbit 的日常任务中，有些本应自动受控却很难启动，必须检查自动入口的评分、上下文和双门槛，而不是只补显式正则。**本会话有「补做 S1 全程序终检」等非显式请求后续由 Root 手动补启的实例；85 条判定仅 6 条自动 start，但分母包含讨论/小任务，不能直接算应启漏启率。用户进一步指出，改由 Jev 判断的版本在其后使用中再无成功分配多 Agent；本会话支持断层，具体因果仍须按实际安装版本和派发决策追查。状态提示及人工介入体验差，近期构建缺完整目标路径的实测验收；不能说历史上从未实测。节约 Codex token 的数值未知。本文只作分析与候选方案记录，不修改产品语义或 Zeen 代码。

## 1. 分析目标

按[README](../../README.md#orbit)与[合同](../../contracts/task-runtime.md#程序与模型)，Orbit 想让 Root 按需组织执行成员、独立 Agent 核对中间进展和实际产物，及早纠正卡住、跑偏和漏项，减少等待、返工与无收益调用；程序保留原始要求和固定快照、观察状态并确认停止。**省时间、省 token 是目标，不是每次使用的已验证结果**；Root 不派成员时，独立检查者并不替它实施。按此核对四个反馈任务：

1. 独立检查是否拦下真实遗漏（反馈「好用」部分）；
2. 「检查通过」与「任务完成」的状态表达是否清晰；
3. 检查结论前后矛盾时，矛盾出在模型判断还是程序机制；
4. 检查回路的可见开销有多大（只报实测数字，不算节省率）；
5. 多 Agent 与节约能力在本样本中是否被验证。

## 2. 反馈所涉四任务：状态与检查序列

| 任务（目录前缀） | 指令摘要 | 生命周期（UTC） | 终态 / 停止确认 | 检查序列 | 成员 | 记录用量 |
| --- | --- | --- | --- | --- | --- | --- |
| `329b7e87…` Mobile UI 长任务 | 「直接执行，知道所有任务都完成」 | 08:18:43 → 10:14:58（约 1h56m） | `needs_user` / 已确认 | 1 次（`zenmux/deepseek/deepseek-v4.1-flash`，10:12:44–10:14:58，verdict `needs_user`，F-1、F-2 open） | 0 | 检查 1,792,684 tokens；Jev 一阶段输入 411,729（62 次评估，08:18:51–09:20:17） |
| `b60c90a7…` 清理 Java 进程 | 「JAVA 进程快把电脑撑爆了，没有意义就关掉」 | 11:21:18 → 11:24:30（约 3m12s） | `complete` / 已确认（`completed_via_finalized_stop`） | 1 次（`kimi-code/k3-256k`，11:23:02 起，verdict `complete`、`delivery.ready=true`） | 0 | 检查 46,289 tokens；Jev 一阶段输入 13,630（2 次评估） |
| `c5526b58…` 补做 S1 全程序终检 | 复核 W1/W2/G0/V1/R1 后关闭 S1 | 11:28:32 → 11:51:17（约 22m45s） | `complete` / 已确认（`completed_via_finalized_stop`） | 4 次（均 `opencode-go/deepseek-v4.1-flash`，11:29 / 11:36 / 11:40 / 11:45；verdict `correct`→`continue`→`correct`→`complete`，2 个 finding 均已解决） | 0 | 检查 6,765,372 tokens（四轮分别约 1.84M / 0.80M / 2.84M / 1.29M）；Jev 一阶段输入 52,723（8 次评估） |
| `639ea21d…` 整理走查文档与未完成事项 | 「先更新文档，然后把没有完成的任务新建一份文档存放」 | 12:43:33 → 13:12:00（约 28m27s） | `paused`（显式普通停止）/ 已确认 | 8 次：1–2 自动（`k3-256k`，complete）→ 3 手动终检（`k3-256k`，`continue`、判「无交付物」）→ 4 争议裁定（adjudicator 角色同模型，complete、Root 胜）→ 5–6 自动（complete）→ 7 自动（`k3-256k`，结构化失败）→ 8 换模重试（`openai-codex/gpt-6-sol`，complete） | 0 | 检查 **295,931 tokens**（含失败的检查 7：17,541；仅成功轮次 278,390）；Jev 一阶段输入 39,799（14 次评估）；入口 JEV 1,363；2 次 Jev 不可用（TypeSafe HTTP 503） |

四任务的 `state.json` 均 `members: []`，且目录中无 `members.json`。**该「无成员」结论只限这四个任务**；它们与第 6 节更早的有成员任务属于同一 OMP `thread_id=01a0e17f-0f3f-72aa-a282-c13b83155dd0`，但不是同一个 Orbit 任务。故「这四项没有唤起」成立，「整段对话从未唤起」不成立。

时间边界：反馈文档的文件修改时间是 2026-09-28 21:03:08 +0800（= 13:03:08Z）。正文只叙述 `639…` 的检查 1–3 与争议提交，未叙述其后裁定、换模和停止；裁定本身发生在 12:54:57Z，早于该文件修改时间，不能仅凭修改时间断言作者当时尚未看到裁定。下文分别列示记录，而不把反馈写作时的结论当最终状态。

## 3. `639ea21d…` 深挖：同一版本上的相反结论及其后续

### 3.1 checks/2 与 checks/3：同版本、同模型、不同程序上下文下的相反裁定

两份 `evidence.json` 的固定快照指纹及任务指令的 `input_digest` 一致；**这不表示检查者看到的完整 prompt 相同**：

- `checks/2/evidence.json`（12:48:37–12:49:16，自动）：verdict `complete`、`delivery.ready=true`。逐项核实 `docs/research/mobile-ui-page-capture-report-2026-09-25.md`（第 6/270 行状态注记）、`mobile-ui-page-capture-fix-list-2026-09-25.md`（第 6/111/161 行）、新文档 `docs/research/mobile-ui-unfinished-work-2026-09-28.md`（43 行、四节）、`docs/research/README.md` 索引，并确认「提交 `6bf2190a` 即快照 HEAD」。`fingerprint_before = fingerprint_after = sha256:949c3272…b71cbb`。
- `checks/3/evidence.json`（12:53:00–12:53:53，`trigger_cause=manual_check`，手动终检）：verdict `continue`、`delivery.ready=false`，理由「No deliverable exists for this instruction…」。**同一指纹 `sha256:949c3272…b71cbb`，`stale=false`**，`completion_readiness.input_digest=b5006780…` 与 checks/2 及后续裁定记录一致。
- 检查 3 的模型行为（`result.reason` 可证）：① 只看 `review_focus` 里的**未提交**工作区改动（`.mcp.json`、`.mcp.json.example`、`.gitignore`、README 的 MCP key 处理；这些改动不是此任务要交付的文档，21:11 +0800 才作为 `f917a2ac`/`55a7d7ee` 提交）；② 用猜测的中文文件名 glob `docs/**/未完成*` 找不到实际英文命名的新文档；③ 把 Root 最后一条消息（无关的 Orbit UX 反馈）当作唯一交付。合同明确 `review_focus.added` 只是优先级线索、不是归因证据（[合同](../../contracts/task-runtime.md#观察与完成)）。
- 对照[检查 2 prompt](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/checks/2/prompt.txt)与[检查 3 prompt](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/checks/3/prompt.txt)：两者 `review_focus` 均只列 `.mcp.json` 等当前未提交文件、`git_remote.head` 均为 `6bf2190a`；但前者 `root.observations.agent_message` 是包含该提交与四份文档的实际交付说明，后者变为另一独立问答的 Orbit UX 反馈。后者保留前两次 `check_finished` 的 **verdict**，却没有此前核验的文档路径、理由；任务建立时的 HEAD `1080f38d…` 在 `state.json` 的工作区绑定中可见，两个 prompt 都未给出这项起点或本任务从起点到当前 HEAD 的提交/文件变更线索。输入版本和快照虽相同，**检查上下文并不等价**。

**归类：模型误判与程序侧证据呈现缺口并存。** 模型仍有固定快照和原始要求，本应按目标读取已提交文件，不能把中文 glob 的阴性结果当不存在；但程序只给出当前相对 HEAD 的 `review_focus` 和最近一次（可能无关）的 Root 消息，没有任务起点/已核实交付的可归属线索，增加了误判风险。固定快照、指纹、版本过期判定并未失效；是否以及如何提供有界、可信的任务期变更证据须按[开工清单⑥](zeen-orbit-experience-acceptance-20260928.md)验证，不能把 `review_focus` 改称任务期差异或用前次 verdict 代替重新取证。

### 3.2 争议裁定与检查 4–8（反馈未覆盖的部分）

- 用户提交争议后，检查 4（12:54:21–12:54:57，`trigger_cause=manual_dispute`，**role=adjudicator**，同模型）：verdict `complete`、`delivery.ready=true`，`resolved_ids=["check-3-no-deliverable-vs-check-2-complete"]`，理由「Dispute resolved in Root's favor」，逐文件直读固定快照核实交付（`state.json` 的 `decisions[0]`，`decided_at=2026-09-28T12:54:57Z`）。合同「检查误报可被独立裁定推翻；撤销结论和原因保留」的路径真实走通了。
- 检查 5（12:55:00）、6（12:56:04）：自动触发（`trigger_cause=delivery`），均 `complete`、`ready=true`，各产生一条 `automatic_check_complete_ignored`——按合同「自动检查即使判断产物可交付也不发 finalization_notice」属预期行为；检查 6 明确引用「same artifact already adjudicated complete (check 4, digest sha256:949c…)」。
- 检查 7（13:03:38–13:04:11）：`k3-256k` 输出结构化失败，`check_failed` 事件记 `failure_kind=invalid_result`、`failure_basis=structural`（「final message is not valid JSON: JSON Parse error: Unrecognized token '`'」）——**模型输出格式错误，非产物问题**。
- 检查 8（13:04:12–13:04:34）：程序按有界换模机制重选 `openai-codex/gpt-6-sol`（`checker_model_selected`，`basis=pool_order_no_other_family`，quality_score 0.57），verdict `complete`、`ready=true`。**失败留证→换模重试的闭环在真实任务中生效**，与 [docs/README.md](../README.md) 当前源码描述一致。
- 13:12:00 显式普通停止 → `paused`、停止确认 `confirmed=true`。任务**没有** `complete`：检查 3 之后不再有「手动 reviewer 角色」的有效终检（检查 4 是 adjudicator，5/6/8 是自动），完成门未满足，与合同一致。

因此，**检查 3 不是未被质疑的最终结论**：它随后被争议裁定推翻；检查 5、6、8 确认交付存在，检查 7 是模型输出格式失败，不能计作内容结论。反馈正文只覆盖这一链路的前半段。

### 3.3 状态层矛盾的机制定位（程序级）

2026-09-28 晚间实测 `orbit status .orbit/tasks/639ea21d…`（本机，只读）同时显示：

- 「检查状态：verdict(complete)（检查结论，不是任务完成）」「最近检查：complete — 已完成原指令…」「裁定记录：1 条」
- 「下一动作：**补齐实际交付：No deliverable exists for this instruction…**；再重检」——即检查 3 那条已被裁定推翻的理由。

矛盾的时间与机制来源（状态记录可证；以下源码路径解释基于当前源码 0.7.9，运行当时安装版未从任务记录确定，标为 `[推断]`）：

1. 检查 3（12:53:53Z）作为手动 reviewer 给出 `delivery.ready=false`，记录 `completion_readiness={status: not_ready, reason: 检查3理由}` 与 `delivery_not_ready` 事件。
2. `[推断]` 只有新一次合格的手动 reviewer 终检会改写完成就绪；裁定检查 4 的角色是 adjudicator，检查 5/6/8 为自动检查，均不产生 `finalization_notice`，旧 `not_ready` 未获清除。
3. 当前 `orbit status` 把 `not_ready` 的旧理由直接展示为「下一动作」，同时显示最近的 `complete` 和裁定，且任务已是 `paused`；这是**已实际观察到的用户可见矛盾**。当前 `TaskView.next_action` 只对 `stop_unconfirmed`、`needs_user`、`failed` 提前处理终态，`paused` 仍可落入 `completion_readiness.not_ready` 的「补齐…再重检」分支（`lib/orbit/task_view.rb:465-489`），故**未经过争议裁定就普通停止的任务**也可能被错误地指向终态不允许的重检；此为源码推导，尚无对应 live 样本。

**归类：程序级状态派生缺口，不限于裁定后的原因和解。** 记录本身符合合同（自动检查不发终检、裁定结论保留），但把一条已被裁定推翻的 `not_ready` 理由持续当作用户可见的「下一动作」，并在 `paused` 后仍要求「再重检」，违背合同「撤销结论…后续检查不得把已撤销结论自动视为未解决」及终态操作边界。反馈「用户要自己找证据、发起申诉」的成本来自模型误判、检查上下文不足和错误状态提示的叠加。

### 3.4 模型错误与程序机制拆分

| 现象 | 归类 | 证据 |
| --- | --- | --- |
| 检查 3 判「无交付物」（只看未提交改动、猜中文文件名、误读 Root 消息） | 模型误判；程序上下文也缺少任务期交付线索 | `checks/3/evidence.json` 的 `result.reason`；checks/2 与 3 同指纹但 `prompt.txt` 中 Root 最近消息不同，均无起点 HEAD |
| 检查 7 输出非 JSON 结构化失败 | 模型错误（输出格式） | `check_failed` 事件 `invalid_result/structural` |
| 失败后换 `gpt-6-sol` 重试成功 | 程序机制按设计生效（正向） | `checker_model_selected`(13:04:16)、checks/8 `complete` |
| 争议裁定推翻检查 3 | 程序机制按设计生效（正向） | `decisions[0]`，`decided_at=12:54:57Z` |
| 下一动作长期显示已推翻的「无交付物」理由；`paused` 仍可能提示重检 | **程序机制缺口** | 3.3 节实测输出 + `completion_readiness` 与后续检查记录并存；`TaskView.next_action` 的终态分支 |
| 相同任务输入/产物下的自动复检（检查 5、6）及独立追问后的检查 2、6、7 | 程序观察归属/自动触发需复核（不认定所有检查均无价值） | `user_message_unassigned` 与 `check_started(trigger=delivery)` 时间序列；检查 5 在独立消息 `fade69b2` 记录**之前**，不能归因于它 |

## 4. 其余三任务要点

- **`329b7e87…`（needs_user，诚实停止）**：唯一一次检查（`zenmux/deepseek/deepseek-v4.1-flash`）verdict `needs_user`，记录两个 open finding：F-1「登录页《用户协议》《隐私政策》必须成为可达入口，且需正式协议文本与两个可达 URL（ADR 0145；账本 M-112）」、F-2「V1 Android 设备验收：减少动态效果、release splash、更新横幅」。没有把缺口包装成完成；反馈「缺前提时敢停」成立。同一份缺口后来在 `c5526b58…` 中以用户收窄的范围（「更新只验 UI、协议暂缓」）结案，协议项作为开放缺陷保留——两任务记录自洽。开销面：Root 工作约 1 小时内发生 **62 次 Jev 一阶段评估**（08:18:51–09:20:17，`jev_assessed` 事件计数），输入累计 411,729 tokens；单次检查耗 1,792,684 tokens。反馈「频繁的周期性评估」有量化佐证；本样本不判定这些评估是否浪费。
- **`b60c90a7…`（complete，范围守住）**：检查者明确按指令范围审「关掉无意义 Java 进程」，核实 Root 停掉 Gradle 构建与模拟器、无残留 daemon、版本号 29 与原 APK 恢复、临时文件清理，`delivery.ready=true` → `finalization_notice`(11:24:11) → `completed_via_finalized_stop`(11:24:30)。反馈「单项检查能守住范围」「Java 清理通过 ≠ UI 项目收口」均成立；混淆源于用户侧把两件事看成一件，任务记录本身边界清楚。
- **`c5526b58…`（complete，真实拦错 ×2）**：检查 1 发现守卫 `BARE_HEX` 正则只匹配 6/8 位、测试还把 `#abc` 断言为「不是颜色」，而生产代码存在 `#fff`（如 `apps/mobile/src/ui/chat/chat-surface.tsx:379`），使「生产代码裸色归零」结论失去支撑（finding `mobile-ui-guard-bare-hex-misses-3digit`，`correction_sent` 11:33:55，检查 2 复核 resolved 11:39:13）；检查 3 发现账本 `docs/research/mobile-design-issue-registry.md:324/:443` 写登录页有「扫一扫名片」「注销账号」入口，实际 `apps/mobile/app/login.tsx` 只有单一主 CTA 与协议行（finding `F1`，`correction_sent` 11:44:39，检查 4 复核 resolved 11:49:19）；随后 `finalization_notice` → `completed_via_finalized_stop`。反馈「真能找出遗漏」的两处实例全部核实，且修正—复核—关闭链路完整。开销面：四轮检查共 6,765,372 tokens，是四个任务中最高的。

## 5. 反馈与记录如何对照

| 反馈主张 | 核对结果 |
| --- | --- |
| Mobile UI 长任务指出协议入口缺正式内容与地址、Android 验收受设备条件阻断，未假报完成 | **支持**（F-1/F-2 open、verdict `needs_user`、停止确认） |
| Java 清理单独完成且不等于项目收口 | **支持**（检查与终态均限定指令范围） |
| 终检四轮发现 `#fff` 简写漏判、登录页文档失实，第 4 轮通过并确认停止 | **支持**（两个 finding 的记录、投递、复核、终检链路完整） |
| 文档任务两次自动检查确认、认出 `6bf2190a`；手动终检判「没有交付物」，只看提交后的工作区改动并用中文文件名找英文文档 | **支持，且需补充**：`6bf2190a` 提交于 20:48:31 +0800（=12:48:31Z），检查 2 于 6 秒后启动并确认其为快照 HEAD；检查 3 同指纹、同任务输入但 **prompt 的 Root 消息不同**，模型漏看提交文档，程序未提供起点 HEAD 或此前已核实文件的可归属线索。**反馈未覆盖**：争议 12:54:57Z 已裁定 Root 胜；检查 5、6、8 确认交付，检查 7 是结构化失败，任务最终 `paused` 而非卡死 |
| 「检查可能前后打架」 | **部分支持，根源已扩展**：版本机制无失效（同指纹、`stale=false`）；矛盾涉及模型误判 + 检查者上下文/交付归属缺口 + 3.3 节程序级状态呈现缺口（已推翻理由仍作「下一动作」） |
| 长任务频繁周期性评估、终检来回数轮、开销可见 | **支持且有数字**（62 次 Jev 评估 / 411,729 输入 tokens；检查 tokens 1.79M、6.77M 等；Root 侧成本未知，不算节省率） |
| 审过材料 ≠ 用过产品（46 张画面未在手机逐页验收） | **支持但限定四任务**：这些检查者只读固定快照；`329b…` 的 F-2 保留了设备验收缺口。不能据此否认其他 Zeen 任务中后续进行的 Android 实机验证；见第 6 节 |
| 四任务 `members: []`，未验证多 Agent 协作 | **支持，限定到本次四项**；同一原生会话此前两项 Orbit 任务另有 13 个成员工作，均非 Jev 建议促成的派发；见第 6 节 |
| 不能算节省率 | **支持并维持**：同会话只读汇总的 `root_tokens`、`member_tokens`、`task_total_tokens` 均为 `null`，无 Codex 独立完成同类工作的对照 |

## 6. 同会话的多 Agent：旧默认角色有实绩，Jev 推荐正例缺失

以同一 OMP `thread_id=01a0e17f-0f3f-72aa-a282-c13b83155dd0` 的 `orbit session-summary --thread … --project /Users/yangke/Personal/omen/zeen` 和任务原始记录为口径：**12 个 Orbit 任务，只有 9 月 27 日两项唤起执行成员，合计 13 个成员子任务，均记录 `completed`；9 月 28 日的 8 项为 0**。`b9756307…` 的[原生派发日志](../../../zeen/.orbit/tasks/b9756307-f415-4ec0-8cf1-7241935bf8fb/collaboration.jsonl)记录同时唤起 `W1CodeReview`、`W1ScopeReview` 两名只读成员；`940142af…` 的[原生派发日志](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/collaboration.jsonl)记录后端、Stitch 设计及 Mobile 多工作面的 11 项派发，包括先同时 2 人、再同时 3 人。两项任务的 Root 身份是 `openai-codex/gpt-6-sol`，**全部 13 个成员实际模型都是 `zhipu-coding-plan/glm-5.2`**；[W1 状态](../../../zeen/.orbit/tasks/b9756307-f415-4ec0-8cf1-7241935bf8fb/state.json)与[圈子任务状态](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/state.json)均为 `complete` 并确认停止。

这 13 次不是「Jev 为成员选出 GLM」：派发均为通用 `agent="task"`、原始模型入参为 `null`，`pinned_model` 是 OMP `@task` 解析出的 GLM，成员记录的 `delegation_basis=root_without_hint`。[此前源码／会话审计](orbit-session-audit-20260927.md#重大遗漏通用-task-默认模型绕开了成员候选池)已指出本机 `modelRoles.task` 映射到 GLM-5.2，0.7.6 的通用 task 路径曾绕开候选池；「默认角色写死 GLM」是用户此次补充的背景，不应错写成 Jev 的胜出选型。`940…` 原先只是 Stitch 登记文档，后来[修订 1](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/amendments/1.txt)与[修订 2](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/amendments/2.txt)扩成圈子／帖子功能、设计与 Android 验证；第 8 次检查指出验收缺口，第 9 次凭新增记录关闭 finding（[检查 8](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/checks/8/evidence.json)、[检查 9](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/checks/9/evidence.json)）。多成员确实工作并交付，不能以最近四任务的零成员否认；但也不能把旧默认角色的成功算作 Jev 选模效果。

**版本与断层，分清证据和因果。** Git 提交 `1cee216`（2026-09-25）引入用户候选池及 Jev 成员适配／收益比较，设计规定 Jev 只给建议、Root 才派发；`ecdd0ca`（2026-09-27 13:47 +0800，0.7.8）一度对通用 `@task` 的池外默认模型增设派发前授权门；`323408b`（同日 19:56 +0800，0.7.9）依用户裁决撤掉该权限门，让候选池恢复为偏好而非硬名单。提交可分别用 `git show 1cee216 -- docs/adr/009-user-selected-model-pool.md`、`git show ecdd0ca -- plugins/omp-host.mjs`、`git show 323408b -- plugins/omp-host.mjs` 核对；[合同](../../contracts/task-runtime.md#可选-jev-调度)现明确两阶段 Jev 需候选证据，提示不等于自动派发。**用户观察是：更新到由 Jev 判断的路径后，没有再成功分配多 Agent，这是严重功能缺口。**本会话记录与此相符：仅成功的 13 项都是 `root_without_hint`，之后 9 月 28 日任务零成员；任务目录未保存每项实际安装的完整构建身份，不能仅凭提交日期断言特定版本直接造成零派发。下面可确定这些任务中的**首个可见阻断是模型证据未补全/身份不匹配**，但其成因及补证后能否推荐和派发仍需验证；0.7.9 移除旧硬门也未构成 Jev 推荐→Root 派发→成员交付的真实正例。

**委派路径的第一处实际阻断已可缩小。** 按上述同一 `thread_id` 逐一读取 12 个任务的 `state.json`/`events.jsonl`：10 个任务的 `delegatable` 曾达到 0.60 并发出 `model_evidence_needed`（包括 3 分钟 Java 清理任务）；余下两项最高分别 0.56、无该请求。10 项中仅 `5e0b9251…` 有一次 `model_evidence_submitted`，随即 `model_evidence_mismatch`：请求的 root/候选身份均为 `reasoning=unknown`，提交的 6 条均为 `default`；9 月 28 日没有提交。12 项均无 `delegation_assessments`、无 `delegation_hint`，故**这批记录中第二阶段没有形成可供 Root 采纳的推荐**。这锁定了当前样本中「第一阶段→精确证据→第二阶段」的首个可见阻断（证据未补或身份不符）；不能从中断言补证后第二阶段一定推荐、Root 一定派发，或唯一根因已找到。事件证据如 [5e0 提交与不匹配](../../../zeen/.orbit/tasks/5e0b9251-e6ee-4163-819e-3f7666b66634/events.jsonl)、[639 证据请求](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/events.jsonl)；现行代码证据门见 `TaskRuntime#stage_delegation`。

`940…` 的[事件记录](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/events.jsonl)有 318 次 `jev_assessed`，一阶段输入加输出 **1,576,760 tokens**，但成员仍由 Root 无 hint 派发；它本身不能证明 318 次评估都无效。另一[近期任务第 11 次过程检查](../../../zeen/.orbit/tasks/ba1d8627-f0cd-4f58-b0de-5b54e069c126/checks/11/evidence.json)只确认 Root 仍在 Android 构建且无新偏航。会话汇总有 **16,625,485 可观察的检查者 tokens**，但 `checker_tokens_complete=false`、`root_tokens=null`、`member_tokens=null`、`task_total_tokens=null`；它不是 Codex 节约量或订阅账单。缺 Codex 独立执行的对照，**节省的 Codex tokens = 未知，不能从 13 项 GLM 工作倒推**。

### 6.1 Jev 判断节点与 prompt 的独立审阅（2026-09-28；未实施修复）

**先分清两条判定链。**自动入口的 `execution_authorized`／`independent_check_benefit`（[PrestartClassifier](../../lib/orbit/prestart.rb)）与任务内 `stuck`／`off_track`／`artifact_ready`／`delegatable`（[JevAdvisor](../../lib/orbit/jev_advisor.rb)）输入、问题版本和阈值不同，互不消费对方的分数。任务内第一阶段 `delegatable ≥ 0.60` 后，程序检查成员和候选目录，再查精确身份缓存；现行 OMP 的 `PluginConnection#model_catalog` 存在，走**逐候选** `jev-candidates-1`：每个候选问 `quality` 与含交接/返工/集成/验证的端到端 `time`，分别用 0.55、0.50 放行，粗档费用只排序，通过才向 Root 提示，Root 决定是否派发。[运行时](../../lib/orbit/task_runtime.rb)中 `member_fit`／`parallel_gain`／`cost_appropriate` 是宿主**没有**模型目录时的旧默认成员路径，与逐候选判断互斥，并非两套问题顺序执行。现行[合同](../../contracts/task-runtime.md#可选-jev-调度)第 71 行仍以旧两题描述候选池推荐门；这是**合同与实现的描述差异**，不能在未裁决时把任一方默认为已更新的产品语义。入口和任务内都叫 Jev 易混淆，但代码无分数串用。

逐项意见按证据强度记录；下列改法是**候选修复/核验方向**，不修改合同、ADR、判断 prompt 或运行规则：

1. **P0，已复现的精确身份阻断。**[运行时](../../lib/orbit/task_runtime.rb)的 `split_model_identity` 将请求 reasoning 固定为 `unknown`；[缓存](../../lib/orbit/model_evidence_cache.rb)将省略字段归一为 `default`，四元组匹配不相等。`5e0…` 的[事件](../../../zeen/.orbit/tasks/5e0b9251-e6ee-4163-819e-3f7666b66634/events.jsonl)确有 6 项 `unknown` 请求对 6 项 `default` 提交的 `model_evidence_mismatch`；本地直接调用 `ModelEvidenceCache#identity` 也复现两键不同。[CLI 帮助](../../lib/orbit/cli.rb)一边说「reasoning 未知可省略」，一边说成员任务按请求填写，指引容易混淆；错误说明还因先按 reasoning 寻找，把该差异误报为 `billing_route submitted missing`。**不是所有证据都永远不能用**：显式按请求提交 `unknown` 可匹配，不能未经证据将真实未知推定等于 provider 默认。先查宿主是否能提供准确 effort；不能时明确成员请求字段、逐字段报错，并决定未知与默认是否有可证明的等价语义；回放「省略」「显式 unknown」「单字段错」三种提交，证实合法精确证据能进逐候选阶段，不靠弱化身份门。
2. **P0，池内证据全有才评估，代码路径确定、用户损害待真实复验。**`evidence_states` 任一身份缺失就返回 nil，`evidence_complete?` 要求 Root 与**所有**候选为有效 evidence；任一有效期内 `unavailable` 令整轮停止，[提交路径](../../lib/orbit/task_runtime.rb)也如此。审阅时用户级缓存另有 `zhipu-coding-plan/glm-5.3-flashx`、`zenmux/deepseek/deepseek-v4.1-flash` 的 `reasoning=default`、`billing_route=subscription_quota`、`status=unavailable` 项（有效期记录至 2026-10-04）；它们是当时的**动态缓存事实**，并不能直接证明当前 `unknown` 请求命中或所有池配置相同，但说明只修身份仍可能遇到整池不可得门。[ADR-009 §3](../adr/009-user-selected-model-pool.md)允许资料不足的型号列为「待评估」且不进入最终推荐，不能仅因一个候选无资料压住其余有据候选。候选方案：在逐候选路径仅评估可证候选，缺失/不可得者标待评估并只请求真实缺项；Root 证据在逐候选 prompt 是否必需须以比较内容裁决，不能先删其质量依据。用一名 unavailable、两名有效及全不可得的固定池重现和验证；保留缺证据型号不获自动推荐的硬门。
3. **P1，第一阶段区分度不足的迹象，prompt 致因未证。**本线程 12 项中 10 项达到 0.60 并发 `model_evidence_needed`；约 3 分钟 Java 清理也越线，不能仅凭低时长判定其所有拆分均无益。[`delegatable` 问题](../../lib/orbit/jev_advisor.rb)的否定标准未像其他观察题一样明示「当前信息不足」，短续办指令可能诱发过度猜测，但日志未留**完整当轮 JEV 输入**，不能把 10/12 或单一措辞当根因。先事前标注 Java/短修改/讨论等负例及真实双工作面正例，再用相同问题版本对照输入、评分与取证负担；若改题义须升 `jev-observation-*`，重校阈值，不把「连续两次高分」之类新门当既定方案。
4. **P1，合同／校准口径差异，代码可证。**逐候选 `quality`/`time` 使用原为整组 `member_fit`/`parallel_gain` 校准的 0.55/0.50；这两题并不等价，旧[专项计划](../../contracts/task-runtime.md)的样本不能证明新题阈值。旧接口的 `cost_appropriate` 同时将已知档位写在真假标准里，未知时题义不完整，但程序将未知费用分数记载而不作硬门；现行池路径费用仅排序。后续须先在合同明确两条路径，再以逐候选真实正负样本校准，不凭改合同文字宣称运行已修复。
5. **设计风险：没有稳定指名的「最佳有界子任务」。**第一阶段和逐候选 prompt 分别提它，但 JEV 只返回概率；[候选提示](../../lib/orbit/task_runtime.rb)给 Root 的是 Agent、型号和分数，不指出具体工作面。不同题可能各自想象不同子任务，采纳与验收因而难归因；目前未观测到实际 hint，不能声称这已造成失败。最低限度验证为双工作面实际提示→Root 明确选择不重叠的工作面并写进有界交接→成员交付与之对应；是否要让 JEV 返回结构化子任务属于后续设计裁决，不预写成已批准要求。
6. **归因风险，不是放宽旧建议的许可。**`delegation_basis` 要求提示时的签名等于派发时签名，该签名包括产物指纹与成员状态；提示后 Root 合法继续改产物，可能将相关派发记作 `root_without_hint`。反面是只比签名、不校验实际 Agent 是否推荐对象，也可能高估「按推荐型号」；一次提示本就只建议**一层一个子任务**，第二名成员不该自动沿用同一提示。先分开记录「有过建议」「派发当刻建议有效」「实际 Agent/型号匹配」并用真实顺序验收，不能简单延长旧 hint 有效期绕过产物/候选变化的失效保护。
7. **路由风险，尚无混合路由实证。**逐候选身份目前复用默认 `@task` 的 `native_member_route`，而不是按每个候选解析实际 `billing_route`；若池中混合按量与订阅，身份匹配或粗档费用可能偏离真实端点。先用可核实的混合路由池核对宿主解析和缓存键；拿不到可信逐型号路由就记未知，不按品牌臆造，也不把按量价格折算套餐额度。
8. **版本漂移风险，尚未观察到漂移。**任务内 TypeSafe 默认 `jev-latest`，入口 `jev-1.13.0` 并要求经校准的版本号；目前记录的实际型号仍为 1.13.0，不能称现有阈值已因别名失效。继续保留实际模型/问题版本，若决定固定任务内版本或别名所指变化，需按两条问题链分别校准和更新[合同](../../contracts/task-runtime.md)，不能静默替换。

**有效边界与证据缺口。**观察按签名去重、成员活跃时暂停提示、缺证据不按型号猜能力、费用未知不单独压掉池内推荐、Root 自行决定派发，均应保留。现存 Zeen 12 项没有逐候选裁决/hint；9 月 28 日 8 项未补成员证据的原因、候选质量/时间门能否通过及 Jev prompt 哪一句导致短任务高分，均**未知**。测试夹具多用显式 `reasoning: "unknown"`，不足以覆盖真实 `default` 提交；新增的有效回归应捕获省略/显式身份、部分候选不可得、错误字段诊断和实际按推荐派发，不写冻结外部动态模型分数的测试。此处不将静态审阅冒充新构建真实多 Agent 验收。

## 7. 优先级结论

按实际交付目标、用户损害与证据强度排序：

1. **P0：打通 Jev 证据→逐候选推荐→真正派发的正路径。**用户报告版本切换后再未成功分配多 Agent；同会话只有 OMP 默认 GLM 的 13 项 `root_without_hint`，9 月 28 日任务均无成员。当前 12 项任务中 10 项请求模型事实，只有 1 项提交且因 `unknown`/`default` 身份不符被拒，无第二阶段裁决/hint；现行逐候选路径还要求全候选有效证据，合同的旧三题描述不等于生产问题。先处理精确身份、错误诊断及资料不全的候选池边界，再以正负样本校准实际逐候选质量/时间题与 `delegatable`，追推荐送达、Root 派发及登记集成。不能把旧默认角色派发、单纯 `delegatable ≥ 0.60` 或不断增加 `jev_assessed` 算 Jev 改版验收；即使证据门解除，也不能预判候选门和 Root 一定派发。
2. **P0：修正已推翻理由与终态下一动作。** `639…` 的检查 3 被裁定推翻，`orbit status` 仍将「No deliverable exists」作为下一动作，且任务已暂停；使旧就绪理由失效，并确保所有 `paused` 状态不再建议对终态任务「再重检」。运行中的任务仍须一次新的有效手动终检，不能把自动检查的 `complete` 偷换为最终通过。
3. **P1：把任务／检查／验收范围说清。** 状态应直接呈现本次检查对象、自动检查结论、当前版本手动终检、尚缺前提、停止确认及**当前任务**的成员数；最近四项零成员与同会话更早 13 个成员不可混为一谈。材料审查也不能替代设备实操。
4. **P1：按消息归属减少低增量评估与重复检查。** `639…` 同一指纹的检查 5/6 在一分钟内连续自动 `complete`，都按设计不发最终通知；独立消息之后还能触发 `delivery` 检查，单靠相同产物指纹去重不能区分任务交付和无关 Root 回合。`940…` 的 318 次 Jev 评估和 `ba1…` 第 11 次「仍在执行」检查按触发签名审计；保留能找到真实问题的中间检查。
5. **P1：程序给检查者可归属的任务期交付线索，模型仍按真实产物取证。** `639…` 同一快照两次 prompt 的最近 Root 消息不同，起点 HEAD 与此前已核实的交付文件未进入上下文；检查需先看提交树/指定交付物，`review_focus` 不是任务期变更，不能靠猜文件名的 glob 阴性结果断言不存在。提供必要的有界证据也不能代替检查者重新验证。
6. **保留有效的硬门，但不宣称已达节省目标。** `c552…` 两处真问题纠正并复核、`329…` 如实停在外部前提、`940…` 的 Root 主动协作与 Android 补验、`639…` 的争议裁定和换模都是正样本。综合判断：**独立监督有效，Jev 驱动的执行协作未得到真实正例，收益与成本未闭环**；需要同类任务对照及可归属 Root／成员／检查成本才可宣称省时、省 Codex tokens。

补充优先级：**P0 同时修显式受控漏识别、核查并修复不点名 Orbit 的日常任务自动入口、取得 Jev 推荐→实际成员交付的目标路径实测**（第 10、12 节）；修显式正则而仍需用户在每个有价值任务前说出 Orbit，不能算启动问题解决。**P1 面向用户的状态／原因／行动提示**（第 11 节），先消除第 3.3 节已推翻理由仍作下一动作的错误；对 Goal/命令入口和进程架构的取舍、benchmark 指标先记录候选，不当作已批准的产品决定。已有历史 Herdr 实测不等于当前非显式自动启动或 Jev 多 Agent 正路径通过验收。

## 8. 证据链接

- [Zeen 首轮反馈](zeen-mobile-ui-orbit-user-feedback-20260928.md)、[产品目标](../../README.md#orbit)、[任务运行合同](../../contracts/task-runtime.md)、[已知费用与效果边界](../plan/debt-ledger.md)。
- 四任务原始目录：`/Users/yangke/Personal/omen/zeen/.orbit/tasks/` 下 `329b7e87-19be-4d88-a35e-de542c2d20cd/`、`b60c90a7-7a92-4b22-a60e-500662047e2c/`、`c5526b58-6372-4206-826f-c9cfd2dd2ff1/`、`639ea21d-f5cb-4b42-8ed8-b0288219976f/`。各自的 `state.json`、`events.jsonl` 与 `checks/N/evidence.json` 是状态、时间与检查用量的一手来源。
- [639 检查 2](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/checks/2/evidence.json)、[检查 3](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/checks/3/evidence.json)、[检查 2 prompt](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/checks/2/prompt.txt)与[检查 3 prompt](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/checks/3/prompt.txt)、[失败检查 7 的用量](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/checks/7/evidence.json)、[任务状态和裁定](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/state.json)、[运行事件](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/events.jsonl)。
- [c552 任务状态](../../../zeen/.orbit/tasks/c5526b58-6372-4206-826f-c9cfd2dd2ff1/state.json)、[329 任务状态](../../../zeen/.orbit/tasks/329b7e87-19be-4d88-a35e-de542c2d20cd/state.json)、[b60 任务状态](../../../zeen/.orbit/tasks/b60c90a7-7a92-4b22-a60e-500662047e2c/state.json)。
- 同一会话的两项有成员任务：[W1 派发、回执和实际成员模型](../../../zeen/.orbit/tasks/b9756307-f415-4ec0-8cf1-7241935bf8fb/collaboration.jsonl)、[圈子／帖子派发与身份](../../../zeen/.orbit/tasks/940142af-a83c-4516-9e32-6ea8a8173f5f/collaboration.jsonl)；`orbit session-summary --thread 01a0e17f-0f3f-72aa-a282-c13b83155dd0 --project /Users/yangke/Personal/omen/zeen` 为会话总任务数和成本缺口的一手只读汇总。版本轨迹见本仓 `git show 1cee216`、`git show ecdd0ca`、`git show 323408b`，默认角色来源见[既有审计](orbit-session-audit-20260927.md#重大遗漏通用-task-默认模型绕开了成员候选池)。
- 本机只读运行 `orbit status 639ea21d-f5cb-4b42-8ed8-b0288219976f` 与 `orbit status 940142af-a83c-4516-9e32-6ea8a8173f5f`（在 Zeen 目录执行）；前者展示相互冲突的下一动作，后者确认 11 名成员与完成停止。

## 9. 边界与不确定

- 本机只读 `orbit status` 与现存文件证明**当前呈现**；`639…` 旧理由为何未失效的源码解释为 `[推断]`，不可倒推任务运行时的 Orbit 安装版。两次检查的**任务指令摘要与产物指纹一致，完整程序上下文不一致**；由此增加误判风险，不证明缺少起点 HEAD 是唯一因果。普通 `paused` 不经裁定也可能显示错误下一动作是对当前 `TaskView` 的代码推导，尚未取得 live 样本。反馈文件修改时间不是作者已知全部裁定结果的证明。用户补充「Jev 改版后再无成功分配」按其真实使用观察记录；本会话的证据请求未闭环已证，补证后的裁决与派发结果仍未知。
- 检查 token 来源于每轮 `usage.totalTokens` 的合计（包括 cacheRead）；`639…` 8 轮 **295,931** 含结构化失败的第 7 轮 17,541，**278,390** 仅为其余成功轮次之和，不能称作全部检查成本。Jev 一阶段数字来自 `jev_assessed.usage`；这不是订阅扣费金额。会话级只读汇总明确 Root／成员本任务 token 未归属，也没有「不使用 Orbit、全部由 Codex 完成」的同类对照，因此无法给出 Codex 节省量或节省率。
- 只读检查核验 Android 验收记录，不等于本文再次在手机上逐页操作。`940…` 的独立验收是在该任务的具体修订范围内，不能替代 `329…` 仍开放的协议／设备前提或所有 UI 画面收口。

## 10. 启动判断与 Jev 样本（补充）

口径：Zeen 项目级入口台账 [prestart-decisions.json](../../../zeen/.orbit/prestart-decisions.json)（85 条，键为原生消息 id）与逐条入口档 [entry/](../../../zeen/.orbit/entry/)，对照线程日志 `/Users/yangke/.omp/agent/sessions/-Personal-omen-zeen/2026-09-27T06-13-15-711Z_01a0e17f-0f3f-72aa-a282-c13b83155dd0.jsonl`（104 条非空原生用户消息，09-27 06:13 至 09-28 13:01）与该线程 12 个任务 `state.json` 的 `instruction_source.id`。判定的代码事实：入口只问两题 `execution_authorized`／`independent_check_benefit`（`lib/orbit/prestart.rb:36-47`），双阈值 0.80 取 AND（`prestart.rb:158-160`），内置校准 `jev-1.13.0`、样本 6 条（`prestart.rb:230-235`）；宿主在无绑定活跃任务时逐条判定，`decision=start` 才走常规启动（`plugins/omp-host.mjs:1925-2031`）。**任务内 Jev 的 `delegatable` 与入口分无关**：它属于任务运行期观测题集 `jev-observation-1`（`lib/orbit/jev_advisor.rb:21-42`），只以 0.60 门槛（`lib/orbit/task_runtime.rb:26`、`:1008-1013`）决定是否进入第二阶段委派证据比较，入口判定从不读它。

| 消息（时间/id） | 原文节选 | 入口分 ea/ib | 判定 | 实际结果 | 评分对照 |
|---|---|---|---|---|---|
| 09-27 12:12 `eb9b1038` | 「继续 W1 的收尾……用已更新的 Orbit 启动一条新任务，完成独立终检」 | 0.94 / 0.90 | start | 自动建任务 [5e0b9251](../../../zeen/.orbit/tasks/5e0b9251-e6ee-4163-819e-3f7666b66634/state.json) | 结果正确但路径可疑：明示受控请求未命中显式正则（`用…Orbit 启动` 不满足「用+orbit+动词」相邻，`prestart.rb:52-63`），靠分数救回【校准内】 |
| 09-27 15:13 `fc137025` | 「可以，完成W1，需要的东西自己找，我全部授权给你」 | 0.94 / 0.80 | start | 自动建任务 [b9756307](../../../zeen/.orbit/tasks/b9756307-f415-4ec0-8cf1-7241935bf8fb/state.json) | ib 恰好压线 0.80；授权+独立终检收益与原文相称【校准内正例】 |
| 09-27 06:23/06:46 `6f1b23f0`/`035653e7` | 「可以，先做第一阶段」「可以，开始吧」 | 0.92/0.52、0.91/0.49 | root_decides ×2 | 无任务；06:43 用户问 `ad1eac48`「检查一下这几次为什么没有启动orbit」；06:48 Root 手动启动 [19f6b1ba](../../../zeen/.orbit/tasks/19f6b1ba-7c62-4807-993b-be09d4692bf5/state.json)（判定后 +64s） | 继续类请求 ib 系统性 ≈0.5：授权判对、独立检查收益判低，与用户随后手动受控冲突【题义/阈值，非分数写错】 |
| 09-28 05:03 `49e60edd` | 「继续，我都授权，不要再问我，把任务完成再给我汇报」 | 0.96 / 0.78 | root_decides | 无任务；15 分钟后用户 `963dceea`「你好像没有启动orbit啊」（0.10/0.62 亦 root_decides）；[a3bad53c](../../../zeen/.orbit/tasks/a3bad53c-001f-4e1c-bbe0-1d234dd4b396/state.json) 手动启动，`instruction_source` 绑在疑问句 `963dceea` 上 | ib 距阈值 0.02；任务最终绑到抱怨消息而非原始工作请求【阈值位置】 |
| 09-28 08:17 `0f9b35fe` | 「可以，直接执行，知道所有任务都完成，记得用orbit」 | 0.94 / 0.74 | root_decides | Root 55s 后手动启动 [329b7e87](../../../zeen/.orbit/tasks/329b7e87-19be-4d88-a35e-de542c2d20cd/state.json)，绑定本条 | 同句点名 orbit：正则未命中（orbit 后无启动动词）+ib 未过线，双重原因拦下明确受控意图【分类覆盖+阈值】 |
| 09-28 11:27 `19428571` | 「补做 S1 的全程序终检：……复核 W1/W2/G0/V1/R1 后再关闭 S1」 | 0.69 / 0.84 | root_decides | Root 42s 后手动启动 [c5526b58](../../../zeen/.orbit/tasks/c5526b58-6372-4206-826f-c9cfd2dd2ff1/state.json) | `execution_authorized` 低估的误判候选：祈使句「补做」未被认可为执行授权【评分误差】 |
| 09-28 12:43 `0c853b63` | 「先更新文档，然后把没有完成的任务新建一份文档存放」 | 0.86 / 0.80 | start | 自动建任务 [639ea21d](../../../zeen/.orbit/tasks/639ea21d-f5cb-4b42-8ed8-b0288219976f/state.json)（即 §3 任务） | ib 恰好压线 0.80；入口启动本身无接线问题【校准内】 |
| 09-28 11:06–12:34 `c5f48a0e`/`05af8e58`/`11e84813`/`e6bb9685`/`e04c5789`，09-27 16:19 `5afb8952` | 普通追问（如「你现在是在干啥」） | 无分数（TypeSafe Net::OpenTimeout/ReadTimeout/SSLError） | root_decides | 无任务 | 非评分问题：判定服务不可用时按设计拒绝自动启动（`prestart.rb:153-155`）【不可用，fail-closed】 |

分布与接线：85 条判定 = 78 `root_decides`（72 条双阈未过 + 6 条服务不可用）+ 6 `start` + 1 `discussion`（`99d07ef6`「哪些需要我决定的」，唯一确定性命中），**显式正则命中 0 条**。78 条有分数的样本里，双过 6、仅 ea 过 12、仅 ib 过 4、双不过 56；6 条 `start` 中 3 条 ib 恰为 0.80，被拒样本在 ib 0.70–0.78 区间聚了 5 条——边界带正是体验争议所在。6 条 `start` 全部真实建任务（`instruction_source.id` 一一对应），线程日志中 `[orbit-entry-failed]` 出现 0 次，78 条 `root_decides` 的 aside（76 条在本线程、2 条在 13:12 续接线程 `01a0e824` 的日志中按台账时间一一落位）全部投递——**未观察到启动路径接线故障**。104 条消息中 21 条未判定，按时间窗推断均落在绑定任务活跃期间（插件此时跳过入口，`omp-host.mjs:1981-1982`）。续接线程仅 2 条消息且均已判定：`ac09ef96`（整理文档请求，ea 0.47 未过——「我需要你整理」类祈使同样疑似 ea 低估）、`f961451c`（「用goal命令来跑这个任务」，0.86/0.33 被拒）→ [81fefc57](../../../zeen/.orbit/tasks/81fefc57-bee0-4cfe-8a2e-105c5d1e7888/state.json) 于 13:27 手动启动。

**用户「多次提醒才启动」按观察记录，部分样本可证实，不可外推到每条 root_decides。**可证实两簇：09-27 晨（`6f1b23f0` 06:23 被拒 → `ad1eac48` 06:43 用户主动问「为什么没有启动orbit」→ `035653e7` 06:46 再被拒 → 06:48 手动启动）与 09-28 晨（`49e60edd` 05:03 差 0.02 被拒 → 05:18 用户抱怨「你好像没有启动orbit啊」→ 立即手动启动）；另有 `0f9b35fe`「记得用orbit」被拒后 55s 手动补启。**非显式请求的漏启也有可查样本**：`19428571`「补做 S1 全程序终检」授权 0.69、收益 0.84，后由 Root 手动建任务。被拒样本中也存在查文档、问进度、提交一把（`f1c233f0` 0.87/0.72、`10f251ad` 0.86/0.46）等低收益请求，用户此前明确裁定短任务不应默认支付独立检查成本（`prestart.rb:217-226`）；只读类 `ca987775`（0.85/0.16）被拒也正确。不能把全部 `root_decides` 都当漏启，也不能因为有正确拒绝就忽视用户认为应启的日常任务。

**结论：入口接线未见故障，自动启动的产品召回是否达标却不能由「6 次 start 都成功」推出。**（a）显式正则在这 85 条中命中 0 条，含三条明示 orbit 的执行请求全部落入 uncertain，`0f9b35fe` 又因收益 0.74 被拦；（b）普通日常任务不点名 Orbit 时也须由 Orbit 主动判断，`19428571` 的执行授权 0.69、`ac09ef96` 的 0.47 是低估候选，继续/授权类收益 0.49–0.78 被双 0.80 门挡下；入口模型只见本条消息和 Git 变化，六条校准样本不足以覆盖本次续办与完整终检反例；（c）服务不可用按设计交 Root 决定，不等于已启动。用户澄清后，**优先审计非显式正常任务的正/负样本、入口问题定义/上下文/校准与选模前置**，使值得监督的请求有真实自动启动正例，同时守住讨论与短任务负例；不能以修显式正则或笼统降阈值代替。边界：`prompt_excerpt` 截 300 字，长消息原文以线程日志为准；分数为两位小数量化，0.80 压线样本对精度敏感；本文未做模型调用，全部为本地只读证据；未知若扩大自动启动后每条被拒任务的真实检查收益。

## 11. 新增用户体感：提示、人工介入与 OMP 命令

**用户观察（本次新增）：**Orbit 的提示基本只让人知道是否完成，不解释当前状态、原因和自己下一步该做什么；流程中多次需要用户提醒或介入，改用 OMP Goal 模式后体感好一些。随附 OMP 命令菜单截图可见 `goal`（当时显示 off）、`guided-goal`（先访谈再设目标）、`autoresearch`、`agents` 等入口；这是界面与用户体验证据，**不是**这些命令已与 Orbit 生命周期兼容或可替代独立检查的证明。入口补启的原始消息与评分见第 10 节；续接线程的「用goal命令来跑这个任务」被入口以 0.86/0.33 拒绝后，Root 又手动建任务，命令意图未被视作 Orbit 受控意图。

**提示现状（源码及本次记录）：**OMP 状态栏只调用 `phaseLabel`，显示诸如「Orbit：独立检查进行中」或「已完成」（`plugins/omp-host.mjs:1206-1209,1263-1272`）；更长的 `[orbit-task-status]` 状态块带「下一动作」和 `Orbit action=check`、`stop(intent=complete)` 等指令，却是注入给 **Root** 的系统上下文（`plugins/omp-host.mjs:1093-1180,1202-1205`），不能当成普通用户已经得到可理解的行动指南。CLI `orbit status` 虽有「下一动作」，仍会出现「需要用户处理」、`Root`、`JEV`、`手动终检`、任务目录和内部调用方式（`lib/orbit/task_view.rb:421-493,610-679`）；第 3.3 节更实测了 `639…` 在 `paused` 后把被裁定推翻的英文旧理由继续显示为下一动作。故问题并非**完全没有**动作字段，而是用户视角的解释、归属与事实一致性不足。

**候选提示契约，尚未实施：**优先给用户一条简明的「**现在是什么状态｜为什么｜你要做什么（或无需操作）**」，同时标明这次检查针对哪项任务、是过程检查还是最终验收、任务是否确已停止。例：「正在核对这次提交｜最终检查还没结束｜你暂时不用操作，完成后我会告知结果」；真正缺协议文本时：「这项尚不能验收｜缺正式协议文本和可访问地址｜请提供这两项，其余工作继续由助手处理」。若只是 Agent 需要请求检查、补模型证据或处理 finding，应写「由助手继续处理」，不把内部命令转嫁给用户；确需人类批准或外部材料时说清具体对象。技术分数、模型身份、任务目录、token 和 `action=…` 保留给展开详情/诊断与 Root 提示，不丢失可审计证据。先修正权威状态派生，不能只换文案掩盖过期结论。

**人工介入归因与候选改进：**`329…` 的正式协议及部分 Android 设备验收属于真实外部前提，不能用自动模式假装已完成；`639…` 的错误终检与用户举证/申诉、入口漏启后用户提醒，则是应降低的非必要成本。Goal 帮助 Root 持续推进是用户观察，值得在隔离任务里比较；把 OMP 的 `goal`／`guided-goal` 用作目标设定、用 `agents` 呈现分工或用命令显示 Orbit 状态，可先试 **会话交互层**，而非先改监督语义。现有 `orbit omp` 已是显式加载的 OMP 扩展，且插件已有 `/orbit-models` 命令（`lib/orbit/omp_entry.rb:9-15,122-140`；`plugins/omp-host.mjs:2103`），并非「插件与非插件」二选一；受控任务仍由独立 Ruby 运行进程启动、独立 OMP 检查者检查（`lib/orbit/cli.rb:384-395,530-543`；`lib/orbit/omp_check_runner.rb:8-18`）。**纯 OMP 插件且取消独立进程**是另一个架构候选，须先证明会话中断后的持久监督、固定快照的独立只读检查、原生成员登记/结果回收与真实停止确认都不退化；当前 [ADR-008](../adr/008-omp-native-collaboration-base.md#已确认的决定)保留这些职责。Goal 不能单凭菜单存在就替代它们。先用实测定位到底是入口漏启、Root 不推进、委派建议缺失、派发受阻还是检查误判，再决定是否改架构。

## 12. 新增用户体感：真实运行验收缺口与 benchmark 候选

**用户判断：**多 Agent 协作这个重大缺口在开发后未被发现，怀疑原因是没有在真实环境运行测试；现有 Herdr 可创建真实环境，希望考虑建立 benchmark。区分事实与推测：历史确有 Herdr 启动安装版 `orbit omp` 的真实样本，包括 [M4 原生协作验收](omp-native-m4-acceptance-20260924.md) 和 [0.7.7 运行体验隔离验收](orbit-runtime-fix-acceptance-20260927.md)，不能写成「从未实测」。然而 0.7.7 的这批受控任务均无执行成员，验收记录也明确无低成本成员自动委派正例；[0.7.9 交接](../plan/handoff.md)只证明本轮完整测试、隔离检查者烟测及局部模型解析，不是新构建完整任务→Jev 建议→Root 原生派发→成员 `hub` 回报→独立检查→停止的目标路径实测。旧版本的 Root 自发派发正例或选模隔离烟测都不能代替这一新行为的发布前验收。更准确的缺口是**针对变更后的关键用户路径缺少冻结构建上的真实正例与明确失败门**，不是笼统「没运行测试」；本次记录未重新运行 Herdr、未给当前构建发通过结论。

**候选验收门（实施前需定版）：**沿用已有 [Herdr 真实验收操作规范](../../.agents/skills/orbit-real-acceptance/SKILL.md)，在全新临时 Git 项目冻结安装摘要，以 Herdr 启动真实 `orbit omp`，另确认普通 `omp` 不接入。至少覆盖普通短任务/只读讨论不误启、用户明确要求 Orbit、**不点名 Orbit 但独立完整且值得受控的日常任务自动启动**（事前标注正负例并重复运行，记录漏启与误启）；「继续已有目标」暂独立核实归属，若需要把旧目标纳入新任务原始指令，先裁决并更新合同/ADR，不预设现有入口必须自动绑定。足以分工的双工作面任务须实际走过精确模型证据→第二阶段 hint→Root 原生 `task` 派发→Orbit 登记成员→`hub` 回报与集成，同时 Root 推进自有工作，再经独立固定快照检查和最终停止确认；若任一步不发生，保留为失败样本而非拿旧默认 GLM 的 `root_without_hint` 充数。另检验已提交产物、无关问答后仍能得到正确手动终检，并由普通用户视角读一次提示，记录「状态、原因、用户下一步」与被迫介入。确认版本/配置、分数、事件、成员结果与检查来源；实际外部授权或资料缺失如实标记阻塞，不降低完成门。

**benchmark 候选，非已立项实现：**同一组冻结需求（短任务负例、可分工双工作面正例、含真实验收前提的 UI/文档类任务），记录 Orbit 路径与可比的原生 OMP 路径；如评估 Goal，单列开启与关闭的受控样本，保持模型、权限、工作区基线、要求和交付标准可比，重复运行并保留失败。分列统计：入口应启/误启/漏启与提醒次数、最终 hint 到登记/交付成员的转化、真实发现及误报、最终完成和停止确认、用户介入回合/外部阻塞、端到端耗时，以及 Root／成员／Jev／检查者可归属 tokens；费用或某角色用量不可得即标未知。质量、时间、人类负担和成本分别报告，不用单一「省 token」分数掩盖质量或漏启；同任务严格配对之前不报节省率。已有真实验收 skill 可作为执行规程，benchmark 则负责跨版本可重复的**用户目标**和比较口径，两者不互相冒充。

修复范围、各修改项的原因/方案/取舍/完成条件及真实验收门，见[开工清单](zeen-orbit-experience-acceptance-20260928.md)。本分析仍保留为事实来源，不充当产品合同。

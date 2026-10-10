# positive-v7（构建 8906）独立证据复核——六问逐答（全部原件亲读，非复述）

## 1. version-bound 推荐 → 首模型前登记 → K3 实质实现：**成立**
时间链原件：instruction 源 `668e7d4a` → 05:37:55 `wu-ba0fe8204e726eb9` declared → **05:38:51** member_selection（`orbit-member-selection-v2`，release 绑 `orbit-quality-decision-4`/`jev-selection-input-2`，judgment jev-1.13.0 `handoff_fit 0.91/member_task_fit 0.82`，recommendation.first=`kimi-code/k3-256k`，limitations 如实声明 route cost unknown、positive rank 仅由本 decision version release 授权）→ dispatch `call_48a95b…` **hint_signature=`db13db9b…` 恰为该 selection signature**（hint_message_id 33afec03）→ **05:38:53 登记**（binding_pending“模型登记时不可观察”如实记）→ **05:38:56 首个成员模型调用**（43 条调用全 finalized、gaps=[]，13 条 K3 调用模型与 pin 一致无漂移）→ 成员实现 importer 并 yield 前两次 hub（05:41:33 to all 被 scope 拦→05:41:45 to Main 成功）→ 05:42:25 accepted。注：05:38:33 有一次 23ms 即败的首次 task 调用（call_dca974），Root 自行重试，非 Controller 介入。

## 2. Root 合法复验路径原件：**存在，一处措辞超出回执**
- Root 独立 npm：bash 回执 **05:41:58** exit 0（`PATH=.runtime/bin… npm-cli.js test`，PASS 121-123 可见含 "PASS 123: CLI success"）。
- Root 独立 CLI：bash 回执 **05:43:57**（success JSON exit=0；`error: line 2: invalid amount` exit 1 等抽查）。
- Deepseek 单位 `wu-5637739e9b6d23b5` accepted：成员环境内 127/127（CLI 123-127）exit 0，hub→Main 原件（hub_call/hub_result call_00_l2l03d3…，05:43:45，yield 前）。
- **两个 accepted 原件在**：wu-ba0fe…（K3，call_48a95b…）与 wu-5637…（Deepseek，call_24fe6d…）。
- ⚠️ 措辞偏差：wu-5637.verification 写 "Root independently **re-ran the same command**: exit 0, 127 cases"——回执中 npm test 仅 05:41:58 一次（先于该单位派发），其后只有 CLI 抽查回执。该句应读为引用既有 05:41:58 回执+05:43:57 抽查的组合叙述，单独的“第二次重跑”无独立回执。非伪造（所引运行均存在），但 verification 文案宽于回执，建议 Root 定稿时收紧。

## 3. stop scope/退出身份：**可信**
stop_confirmation：root thread `01a12450…` idle、active_tools 0、async settled；双成员逐一 confirmed（idle/0/settled）；collab 持久化 written 34/34、0 failed、0 gap；foreground pids 83781/83811/83850 全 exited；独立检查 pids 86341/86637/86922 全 exited（86922=check3 run.json pid 同一）；pane_closed true。scope 文案与上述回执一致，无未停成员对象。

## 4. Controller 中途催办/代写：**无**
`positive-v7-prompt-submitted.json`：initial_requirements_sent 1、**controller_followups 0**；原生会话仅 05:36:59 一条 user 消息（初始需求），之后零用户输入；collaboration 无任何 correction 类事件。代写排除：Root 全部 write 目标 = `xd://orbit`（工具调用）×10 + **src/cli.mjs**（05:38:59，Root 自担职责）+ **README.md**——从未写 `src/importer.mjs`；成员 sandbox 缺 cli.mjs 读权限与“CLI 晚于 declare 05:37:55 才写（05:38:59）”自洽，成员诊断诚实。

## 5. 残留/空字段/真实绑定三分：**已区分，不互相掩盖**
- **未派发 declare 残留**：`wu-a0c651…`（05:37:38，同目标先声明）与 `wu-74afde…`（05:42:35，与 wu-5637 同目标的重复声明），均 dispatches=[]、selection 为 facts_only/recommendation null（05:46:53-54 补算）——是声明残留，**不是**漏停成员（无线程、无模型调用、无 stop 对象）。
- **成员2 state.work_unit_id=null**：members 行 member2（thread orbit-4423db03…）该字段确为 null（member1 行有值）——但 durable 侧绑定完整：wu-5637.member_id=该 thread、dispatch bound_at 05:42:49、binding_pending/workspace_applied 事件、9 条 work_unit_tool_blocked 均引用该 unit。**归属以 durable 单位为准成立；成员行空字段是簿记不对称**（影响：只读 members 行的消费者会漏掉 member2 的单位关联），如实报告不掩饰。
- **资源字段 unknown**：route_cost_inputs={}、selection limitations 明示 "route cost comparison is unknown"、actual_identity.reasoning=null（缺失 null 约定）、resource-calls 70 条（root 23/judgment 15/member 20/checker 12）**无 cost/cash 字段**——未知保持未知，无编造。

## 6. check3 独立手动终检：**有效**
scope.json：number 3、role reviewer、kind artifact、**manual true、trigger manual_check**、快照 orbit-workspace-snapshot-v1（git_head c0c49dcb、digest `sha256:fa9609ae…` 与 completion_readiness/state 一致）；独立 OMP profile 独立会话 `01a12458…`（≠root/members）；request model opencode-go/deepseek-v4.1-flash ≠ Root 模型、sdk 18.8.0、source_agent_dir 复用宿主目录无二次登录；evidence：ok、review_ran、read_tool_is_confined true、forbidden_tools []、active 仅 glob/grep/read、fingerprint before==after（检查期间快照未变）、contract_problems []、verdict **complete**、delivery.ready=true（引用固定快照内实际文件）、coverage complete 19 项、0 findings、usage 5 条均 reported 无 gaps。

**通过范围**：以上 6 问在 positive-v7 单案例、本轮读取原件范围内成立。**不能外推**：单案例≠全矩阵；tool-pairing/投影仅为该构建在该案例的表现；Root“第二次重跑”措辞差异如上；成员行 work_unit_id 空字段待 K3 修簿记。**真阻断**：未发现。临时目录仍存 `/tmp/orbit-c02-sdk-188`（待 Root 裁定去留）。
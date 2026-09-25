# OMP 单宿主目标路径真实验收（2026-09-24，进行中）

本记录只计入由 Herdr 启动的已安装 `orbit omp` Root 真实模型任务。确定性测试、普通 `omp` 和直接调用运行时不代替目标路径。最终结论在全部场景完成后更新；失败样本保留原样。

## 已安装构建与普通 OMP

- **构建 A（N1，已取代）**：`0.6.13`，local source `/Users/yangke/Personal/omen/orbit`，dirty，`content_digest=7382f6535d0332084e9f90b07dca949fc0ea1cd1368c83a0e668cf6560c08b24`，`installed_at=2026-09-24T09:11:16Z`，release `c4dad314ffae4f3db137c428`。
- **构建 B（N2 复验）**：`0.6.13`，同一 local source（dirty），`content_digest=9599adbed370b6377557bab3c0dcf60bec48bf9ca3051abbfe10a1099cefbf87`，`installed_at=2026-09-24T09:20:37Z`，release `f5e40e80074841a36dcfbcad`；含插件工具说明与 CLI `check.next_action` 的冻结修正，更新记录与 SHA 匹配见 `/tmp/orbit-m4-n1-update.log`。该 release 在 N3 更新时无存活 lease，已按安装器规则清理。
- **构建 C（N3）**：`0.6.13`，同一 local source（dirty），`content_digest=1a6fac3f19b628c2d9e3034a1af3db480b7deea83c3feb430971a49bc3d5096d`，`installed_at=2026-09-24T09:43:53Z`，release `783b44b07813a89a8ecaaf57`；含 inbox 命令消费加固前的冻结源码。该 release 在 N4 更新时无存活 lease，已按安装器规则清理。
- **构建 D（N4/P1 使用，历史）**：`0.6.13`，同一 local source（dirty），`content_digest=7de1a1e2fc26582ef37daec80295d1639bd7421eb2e787ae9ce592bacd7199bb`，`installed_at=2026-09-24T09:54:09Z`，release `925aea4d155040f79a0c4c6d`；含 N3 后的 inbox 命令容忍加固（`tests/inbox_command_test.rb` 回归），更新与 SHA 匹配见 `/tmp/orbit-m4-n4-update.log`。N4 与 P1 两个真实样本均在此构建上取得。
- **构建 E（P2 与普通 `omp` 实测，历史）**：`0.6.13`，同一 local source（dirty），`content_digest=03fe3800bcafce15438b22c90533781ecbe2176b165477106ec2e2c877e7a411`，`installed_at=2026-09-24T10:10:53Z`，release `4c2987bb5a3d49582c474e2b`；含 N3 后的 inbox 加固与 diagnostics/文档状态同步，更新与 SHA 匹配见 `/tmp/orbit-m4-final-source-update.log`。E 上已跑 P2 双工作面样本（**未通过**，见下）与普通 `omp` 被动实测；N4/P1 仍属构建 D，不得记为 E 的实测，E 也不得记为全通过。
- **构建 F（P3 单 Root 检查与 complete 路径实测，历史）**：`0.6.13`，同一 local source（dirty），`content_digest=6ad26e9c60edd2dcc23d44f8e814346fe5f6943c4afe1db5d8bbbb8261c9a958`，`installed_at=2026-09-24T11:04:02Z`，release `c4132869c0ab3d79b26b7134`；含停止补丁与 model-evidence 帮助收口。安装时 `lib/orbit/task_runtime.rb`、`plugins/host.mjs`、`lib/orbit/cli.rb` 与工作树 SHA 一致，`doctor` installation/version_ready 通过，OMP CLI pin 18.2.8，旧全局入口不存在，现有编码 OMP 会话未触动；来源 `/tmp/orbit-m4-post-stop-update.log`。F 上已跑 P3（单 Root 手动终检 + 正常 `complete` 停止，见下）；**成员正样本、带 finding 纠偏、rebind、崩溃重试仍未在 F 上验证**，不得预宣称整体通过（N4/P1 属 D，P2 与普通 `omp` 属 E）。
- **构建 G（历史，未实测）**：`0.6.13`，同一 local source（dirty），`content_digest=80050aa1e9baf74c0725102a0eac0a7e1b09a38ee149bb80c0637882345caab7`，`installed_at=2026-09-24T11:27:02Z`，release `7b264650feafebe062b1a25c`；含 JEV 证据记录修正（累积停止补丁与 model-evidence 帮助）。`orbit update` exit 0，安装 SHA 与工作树一致（`task_runtime.rb` `6438b5e3…`、`cli.rb` `a4a4242f…`、`host.mjs` `061b1b91…`）；**但仓库外默认 PATH 运行 `orbit doctor --json` 失败**：`scripts/orbit` shebang 为 `#!/usr/bin/env -S ruby --disable-gems`，解析到 `/usr/bin/ruby` 2.6.10，解析 `lib/orbit/plugin_connection.rb` 的 endless method 定义报 SyntaxError（exit 1）；仅当 Homebrew ruby 4.0.6 前置时 `installation_ready/version_ready` 为 true。**G 安装入口存在真实阻断，修复前不视为安装可用**；OMP CLI pin 18.2.8 与旧全局入口不存在、编码 OMP 会话未触动（均在 Homebrew ruby 前置下核对）；来源 `/tmp/orbit-m4-evidence-update.log`。**G 尚未做任何真实模型端到端验收**（N4/P1 属 D，P2 与普通 `omp` 属 E，P3 属 F），不得预宣称任何场景在 G 上通过。
- **构建 H（已被构建 I 取代）**：`0.6.13`，同一 local source（dirty），`content_digest=74bd84600d3bf9c833cbddd93c839d8541b0dc0b4cb92616c175cafc03eda2c1`，`installed_at=2026-09-24T12:03:44Z`，release `4dc31e162db91d6c1c85df44`；含 Ruby 钉住修补（安装 wrapper pin `ORBIT_RUBY=RbConfig.ruby` 并保留 `--disable-gems`；插件 CLI、成员登记、reviewer 指纹等扩展派生子进程经 `ORBIT_RUBY || ruby` 使用同一解释器）与旧 wrapper 安全升级（`legacy_wrapper` 字节级归属认定、原子替换、失败恢复旧内容、篡改仍拒绝；回归 `tests/install_test.rb` 的 `old_wrapper_update`）。验证事实：`orbit update` exit 0 后，验证条件与结果分清记录：常规 PATH 从 `/` 运行，`orbit version --json` exit 0（digest 与上相符），`orbit doctor --json` 输出有效 JSON——`installation.ready=true`、`omp_entry.version=18.2.8`/`version_ready=true`、`migration.phase=M4`，因无可用会话 `connection.ready=false`、整体 exit 2（如实，非失败）；另有受限 PATH 且最前放置假 `ruby 2.6.10` 的条件测试：pinned Ruby 生效（`version --json` exit 0），该条件下 doctor 因 PATH 内无 node/omp 报缺失（既有 PATH 依赖，与本构建无关）。`~/.omp/agent/extensions/` 无旧全局入口。已知限制：无 locale（`env -i`）下 `TaskRecord#state` 读 UTF-8 记录报编码错（真实终端有 LANG 不触发），一行修法待排期。
- **构建 I（已被构建 J 取代）**：`0.6.13`，`content_digest=f1e5cbc09fb7ccc6c8ed27de60fd6256d36d4f3f5e90073645a5df8b54780320`，`installed_at=2026-09-24T12:58:19Z`，release `98caf20b114ba5dfa387573a`。`orbit update` exit 0；`npm test`、`npm pack --dry-run` 39 文件与 skill validator 通过。本构建上已有 rebind3、无成员异常退出重试，以及 member-audit；该审计两次 stage2 declined，成员正样本仍未跑。
- **构建 J（已被构建 K 取代）**：`0.6.13`，`content_digest=6e2426f01234ca3dbabc2242ce3ba5958a5dad733ac34bf8372dde5d06e80bdc`，`installed_at=2026-09-24T13:26:55Z`，release `1493134dcd429928acdf1de5`。从 `/` 运行 `orbit version --json` 与 `orbit doctor --json` 均 exit 0；安装、环境与 OMP 18.2.8 ready。整体 `ready=false`，`connection.ready` 为空，因为没有会话。证据修复已在该安装中。本构建的 member-v2 失败，见下；不因此宣称检查通过。
- **构建 K（已被构建 L 取代）**：`0.6.13`，`content_digest=fbfeea6ba9c010848f5725831c340279261cf1632f28fb2117df69cd99a19235`，`installed_at=2026-09-24T13:57:45Z`，release `9492683662ccccd4aab88d29`。`orbit update` exit 0。从 `/` 运行 `orbit version --json` 与 `orbit doctor --json` 均 exit 0；环境、安装与 OMP 18.2.8 ready，`connection.ready` 为空（未提供会话），整体 `ready=false`。`npm test` exit 0；`npm pack --dry-run` 42 文件，含新增 reviewer 解析模块和 2 条测试；`git diff --check` 通过。
- **构建 L（已被构建 M 取代）**：`0.6.13`，`content_digest=47a933336b66f015def6b48e09ea69b454e9fd9d268b4dedbe48b7df06b8244c`，`installed_at=2026-09-24T15:26:06Z`，release `3c46649173975b169855884a`。`orbit update` exit 0（保留存活 lease 的旧 release 与无记录旧版）。从 `/` 运行 `orbit version --json` 与 `orbit doctor --json` 均 exit 0（正常环境；`installation`/`environment`/`omp_entry` ready，OMP 18.2.8，`connection.ready` 为空、整体 `ready=false`）。门禁：`npm test` exit 0（39 PASS）、`npm pack --dry-run` 42 文件无旧宿主、`git diff --check` 0。已跑跨模型样本 L1（见下），无 hint/成员；构建 L 不因此算全通过。
- **构建 M（历史，已被构建 O 取代）**：`0.6.13`，`content_digest=a5ad94260be64a8c70b7c48cb59069154c8da0b73648dc6c0037b8e5ba9f578d`，`installed_at=2026-09-24T16:25:37Z`，release 前缀 `934e2ab1`。已跑 `4d41ba19` 与单链样本 `5ec69b23`（合同收尾语义 FAIL，见下）；不是全通过。
- **构建 N（已被构建 O 取代；失败记录保留）**：`0.6.13`，`content_digest=3b15a5f75cd393d1fa175e6ec360f900dec6581a44a30aa0eb6c4e76a6de2798`，`installed_at=2026-09-24T16:55:01Z`，release `f947b6b9fa078428b1e15353`。`orbit update` exit 0（本地源码；保留存活 lease 的 `b10408f6…` 与无记录旧版 `e4db92bf…`）。从 `/` 运行 `orbit --version` 与 `orbit doctor --json` 均 exit 0：installation/environment/omp_entry ready、OMP 18.2.8、checker active、`connection` 未提供；旧全局扩展 absent。安装前门禁：`ruby --disable-gems tests/task_runtime_test.rb` PASS、`npm pack --dry-run` 42 文件、`git diff --check` 0。含 Pi 对 `5ec69b23` 合同收尾违例的修复；已跑 postfix one-chain `66d7fa45`——**FAIL：显式 stop 路径仍缺 `finalization_notice`**（该样本后续 orphan 重试见 `/tmp/orbit-m4-build-o-orphan-retry.md`，进入 `stop_unconfirmed` exit 1）；已跑单链样本 `b9e87009`——**PARTIAL-A**（成员/hub OK、无 finding、`correction_sent`=0，不勾冻结 9；同 check/version 的 `finalization_pending`→`finalization_notice` 时序分支与显式 stop 收尾路径通过，见下）；不是全通过。
- **构建 O（已被构建 P 取代）**：`0.6.13`，`content_digest=7228ee7ae6ee037923ee8e4b1707a9e225161e013b74f4bd2457d9abb08b7e04`，`installed_at=2026-09-24T17:20:54Z`，release `08a08b036a327993864d4118`。`orbit update` exit 0（本地源码；保留存活 lease 的 `b10408f6…` 与无记录旧版 `e4db92bf…`；构建 N 的 release `f947b6b9…` 因租约全死由安装器按常规清理）。从 `/` 运行 `orbit --version` 与 `orbit doctor --json` 均 exit 0：installation/environment/omp_entry ready、OMP 18.2.8、checker active、`connection` 未提供；旧全局扩展 absent。安装前门禁：`npm test` exit 0、`npm pack --dry-run` 42 文件、`git diff --check` 0。合并内容：orphan PID 离线 `stop` 重试修复（`TaskView.runtime_abandoned?`）与 Pi 延迟通知修复。已对构建 N 的遗留任务 `66d7fa45` 做唯一一次 `orbit stop`：`running` → `stop_unconfirmed`（exit 1，成员桥 socket 缺失、无 confirmed），**不计冻结 7 全过**；不把源码修复当真实 finalization 通过。已跑单链样本 `b9e87009`（PARTIAL-A，见下）。证据 `/tmp/orbit-m4-build-o-install.md`、`/tmp/orbit-m4-build-o-orphan-retry.md`。
- **构建 P（当前安装）**：`0.6.14`，`content_digest=dcf89b004045c832af66072d636bc037d9df1cd6cd677f14c59813af5a900926`，release `b21d27802cfa1945d9a27f22`，`installed_at=2026-09-24T18:06:22Z`；门禁 `npm test` 与 pack 通过（Root 审核记录）。已跑冻结 9 真实样本 `df4cf490`——**FAIL（检查环假阴性）**，见下；不是全通过。
- 各构建的 `orbit omp` OMP 与独立 reviewer SDK 均为 `18.2.8`；旧 `~/.omp/agent/extensions/orbit.js` 不存在；存活旧 OMP 会话 PID 21723/37321 未触动。
- 普通 `omp` 被动证据：构建 A（Herdr pane `w1B:p1Y`）保存在 `/tmp/orbit-m4-plain-omp-tools-final.txt`；构建 E 已在同一隔离项目用 pane `w1B:p23` 实测，`/tools` 列表保存在 `/tmp/orbit-m4-e-plain-tools-pane.txt`（无 `xd://orbit` 或 Orbit 工具），随后 `/exit` 关闭；两轮均只算入口被动证据。

## 小任务负样本 N1：失败，保留作纠偏依据

- 固定构建：上述 `7382f653…`；Herdr pane `w1B:p1Y`，命名 `orbit-m4-negative-0613`，命令为 `orbit omp --model zhipu-coding-plan/glm-5.2`，启动进程 argv 含已安装 release `c4dad314ffae4f3db137c428/plugins/omp.mjs`。
- 隔离 Git 项目：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-m4-fixtures-x1vgk3ql/negative`；完整用户要求在 `/tmp/orbit-m4-negative-prompt.txt`。Root 自主 `start` 后的记录为 `.orbit/tasks/8aed1b33-3345-4f98-8113-b30454f6538a/`。
- JEV 第一阶段真实分数：`delegatable=0.41`、`stuck=0.19`、`off_track=0.20`、`artifact_ready=0.14`，用量 input 1406/output 74；无模型证据请求、无最终 `delegation_hint`。Root 仍自行派发单文件修改，登记实际 OMP 成员 `orbit-c5e14ad7-7aa6-41bc-85fb-66aab3b443e5`，`delegation_basis=root_without_hint`。因此**小任务不派发**验收失败；不能把分数或成员成功误写成 Orbit 建议。
- 原生 `task` 返回 spawn，Root 两次 `hub wait`，后者取得成员的真实结果；TaskRuntime 在 `members.json` 与 `events.jsonl` 记录成员、模型、结果和协作事件。成员只改 `src/slug.js`；验后 `npm test` 为 1 pass/0 fail，项目 Git 仅此生产文件修改。
- 独立检查 #1 于 09:14:33Z 启动，`checks/1/run.json` 记录独立 OMP reviewer 进程 PID/PGID 58361、模型 `zhipu-coding-plan/glm-5.2`、固定快照；Root 在结果仍 `in_flight` 时于 09:15:14Z 主动 `stop`，检查未产生 verdict。进程组随后核对为不存在。任务终态 `paused`，**不算检查通过或任务 complete**。
- 停止桥对 Root 与该成员均返回 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；这是本路径的一条真实停止正样本，不证明长时间 parked 成员或异常退出重试。完整索引可运行 `.agents/skills/orbit-real-acceptance/scripts/summarize_task.rb` 指向上述任务目录。
- 判因：Root 把单文件工作误判为值得派发，且在手动检查运行中把“交付”理解为立即停止。已交由 OMP 插件工具说明与 CLI `check.next_action` 的写者修正；该构建和任务不重标为通过。新构建必须重新安装并用新会话重新跑（复验见下方 N2）。

## 小任务负样本 N2（复验）：失败，保留作纠偏依据

- 固定构建：构建 B（`9599adb…`，release `f5e40e80074841a36dcfbcad`）；Herdr pane `w1B:p1Z`（新会话）；隔离项目 `/tmp/orbit-m4-negative-retry.Bpizvb/project`；任务 `25e5b326-eeba-4579-89c2-aeaedb97563c`（原文：只改 `src/slug.js` 的 `slug(title)`，跑现有 `npm test`）。
- 派发行为（负向期望）：JEV `delegatable=0.44`（`stuck=0.18`、`off_track=0.19`、`artifact_ready=0.51`，input 1560/output 74），无模型证据请求、无最终 `delegation_hint`，`members=[]`，Root 未派发任何成员。与 N1 的误派发相比，本样本未出现派发；单样本只记"未观察到误派发"，不等于负向验收通过。
- 独立检查 #1：09:21:59Z 启动（`manual_check`，reviewer，模型 `zhipu-coding-plan/glm-5.2`，PID/PGID 78351，固定快照），09:23:13Z 完成，`stale=false`，verdict `correct`；finding `F1` 指出固定快照 `src/slug.js` 与 `basis/0-slug.js` **逐字节一致**（sha256 `ea94eefc…`，即未做修改），且现有实现 `trim()`/`toLowerCase()` 比指令的"仅 ASCII 空格／仅英文字母"范围更宽，现有 `npm test` 不能区分。检查用量 input_tokens 17006／output 5050／total 22056。
- 纠偏投递（失败）：检查完成后 TaskRuntime 在 Root 活跃时投递纠正，`send` 超时——`Orbit::Connection::Error: omp connection: execution expired`（09:23:28Z）；`sent_message_ids=[]`、`comparison.correction_messages=0`，finding `F1` 未送达 Root。任务因此 `failed`（09:23:29Z，`stop_reason` 同上）；Root 停止确认 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- 判因：N1 的使用指导修正使本样本不再误派发（单样本）；但检查完成后的**纠偏投递未送达**，本样本不能算通过。`finding → Root → 修复 → 复核` 路径仍未验收。

## 小任务负样本 N3（复验）：失败，暴露 inbox 命令契约缺口

- 固定构建：构建 C（`1a6fac3f…`，release `783b44b07813a89a8ecaaf57`）；Herdr pane `w1B:p10`（新会话）；隔离项目 `/tmp/orbit-m4-negative-n3.pENGH2/project`；任务 `7d8c541b-16d0-45af-870b-618729f639da`。
- 派发行为（负向期望）：JEV `delegatable=0.44`（`stuck=0.12`、`off_track=0.09`、`artifact_ready=0.47`，input 1320/output 74），无模型证据请求、无最终 `delegation_hint`，`members=[]`，未派发成员；单样本只记"未观察到误派发"。
- 失败：Root 未使用 Orbit 工具，而是手写 `.orbit/tasks/<id>/inbox/check.json`：`{"action":"check","text":"Done: rewrote slug(title) …"}`（无 `type`）。TaskRuntime 消费 inbox 时 `KeyError: key not found: "type"`（09:45:57Z），任务 `failed`（35.2s）；`checks=[]`、`sent_message_ids=[]`。Root 停止确认 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- 判因：客户端写入的 inbox 负载与程序期望的 `type` 契约不一致，且程序对畸形负载不具容忍性（非致命化缺失）。已按最小加固修复：`TaskRecord#commands` 对无效 JSON／非对象／缺 `type` 的命令记录 `command_rejected` 并移除，不进入 runtime；`TaskRuntime#consume_commands` 对缺必填字段的命令记录 `command_rejected` 而非中断；回归 `tests/inbox_command_test.rb`。该修复为确定性变更，需重装并用新的真实样本复验后才算通过。

## 小任务负样本 N4（复验）：行为已观察到的一次通过样本；纠偏路径仍待

- 固定构建：构建 D（`7de1a1e2…`，release `925aea4d155040f79a0c4c6d`）；Herdr pane `w1B:p21`（新会话）；隔离项目 `/tmp/orbit-m4-negative-n4.KvUGfn/project`；任务 `64f6a244-67a3-4bce-9b40-24094a8c8da5`（同一要求：只改 `src/slug.js` 的 `slug(title)`，跑现有 `npm test`）。
- 派发行为（负向期望）：JEV `delegatable=0.31`（`stuck=0.13`、`off_track=0.14`、`artifact_ready=0.17`，input 1383/output 74），无模型证据请求、无最终 `delegation_hint`，`members=[]`，未派发成员。
- 交付：Root 将 `src/slug.js` 改为 `title.replace(/^ +| +$/g, '').replace(/ +/g, '-').toLowerCase()`（basis `2a767fa3…` → 快照 `471cad7c…`），其余文件与 basis 一致；Root 报告 `npm test` 1 pass/0 fail 与手工样例矩阵。
- 独立检查 #1：09:55:35Z 触发（`trigger=delivery`，非 manual；reviewer，模型 `zhipu-coding-plan/glm-5.2`，PID/PGID 71937），09:56:05Z 完成，`stale=false`，verdict `complete`、无 findings；固定快照指纹 before=after=`sha256:86f6d04cbaea33878f278527215617c153fcb9100a57df6b2e3f9f2a5063e428`；检查用量 input_tokens 14327／output_tokens 1445／total 15772（3 条消息：input 5303 + cacheRead 9024）。
- 终态：任务 `complete`（50.6s）；Root 停止确认 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；无纠正消息（`sent_message_ids=[]`）。
- 结论边界：本样本"小任务不派发 + 独立检查通过 + 完成 + 实际停止"记为**行为已观察到的一次通过样本**；不据此宣称负向验收全部通过，也不宣称纠偏路径（finding→Root→修复→复核）已验证——该路径在 N4 未触发。另：检查者把 `.toLowerCase()` 视为满足"英文字母转成小写"的措辞，而 N2 检查者持更严格解释（仅 A–Z）；两样本口径不同，**不能声称"仅英文字母小写"已被证明**。

## 双工作面正样本（P1）：中断／部分，未完成

- 固定构建：构建 D（`7de1a1e2…`，release `925aea4d155040f79a0c4c6d`）；Herdr pane `w1B:p22`（新会话）；隔离项目 `/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-m4-fixtures-x1vgk3ql/positive`；任务 `7f6aaf5d-457c-4635-8fbb-5457d0ff57ec`。
- JEV：两次评估均 `delegatable=0.91`（09:58:38Z：stuck .19／off_track .25／artifact_ready .15；09:59:39Z：stuck .10／off_track .09／artifact_ready .41）；09:59:39Z 发出 `model_evidence_needed`（root 与候选均为 `zhipu-coding-plan/glm-5.2`、reasoning unknown；需要 speed/quality/cost/local_samples），`evidence_status=requested`，**无最终 `delegation_hint`**。
- 派发：Root 未等待证据/提示，于 09:59:53Z 派发一名原生成员 `orbit-110f00d2-31a2-4823-a3b0-5306bb2d0da2`（`member_registered` + `native_member_reconciled`，`basis=root_without_hint`，模型 `zhipu-coding-plan/glm-5.2`；`native_collaboration` 记录 spawn 文本）。这符合"无 hint 时 Root 可自行显式派发"的边界，但不是 Orbit 建议的派发。
- 中断与停止：用户要求停止当前测试 Agent，控制器发送原生 Esc；10:00:06Z 任务 `paused`，`stop_reason="The user interrupted the Root turn"`；Root 停止确认 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`，成员停止确认同为 `confirmed=true`、`registry_status=idle`、`active_tools_after=0`、`async_jobs_settled=true`。随后 `/exit` 并关闭全部测试 pane。
- 用量与覆盖：`elapsed_seconds=95.97`；JEV 合计 input 6230／output 148；`checks=[]`、`check_tokens=null`；`sent_message_ids` 仅含证据请求消息 `445cd1b8-…`。**本样本没有端到端完成，也没有任何独立检查或纠正投递**，不得记为通过。
- 附带观察：`runtime.log` 出现 `JSON.generate: UTF-8 string passed as BINARY` 警告（Ruby json 3.0 前为警告）；未影响本样本停止确认，待后续核对。
- 结论边界：双工作面正样本、模型证据两阶段、Root 跟随最终提示、成员结果集成、独立检查与纠偏路径在本样本均**未完成**；真实验收仍需后续样本，不能以本样本或确定性测试代替。

## 双工作面样本 P2（构建 E）：未通过，成员正样本未满足

- 固定构建：构建 E（`03fe3800…`，release `4c2987bb…`）；Herdr pane `w1B:p24`；隔离项目 `/tmp/orbit-m4-e-8FRZ3o/project`；任务 `cd084686-ab4a-48d7-86d9-f306ee39b79f`；启动命令 `orbit omp --model zhipu-coding-plan/glm-5.2`，提示按 `/tmp/orbit-m4-positive-prompt.txt` 并附加"若要求模型证据先提交并等最终建议"。Root 自行完成两个模块，fixture `npm test` 8/8。
- JEV 两阶段：stage1 最高 `delegatable=0.90`（10:19:03Z；10:18:04Z 为 0.84）；模型证据请求两次、提交一次（10:23:04Z `model_evidence_submitted`/`model_evidence_used`，缓存 `valid_until=2026-10-01T10:25:00Z`）；stage2 三次均 `declined`（`.33/.33`、`.28/.35`、`.31/.20`），**无最终 `delegation_hint`**，`members=[]`，Root 未派发成员。因此**成员正样本未满足**，本样本不能作为成员协作正样本。
- 独立检查：自动 #1（10:22:08Z 触发，change；digest `ad5848a1…`）完成时 `stale=true`（`artifact`，verdict continue，4 条 finding），不计当前版本 finding，转入待核对线索（`recheck_pending count=4`）；手动终检 #2（10:24:56Z 启动，pid/pgid 15429；10:25:43Z 完成，`stale=false`）无 findings、`resolved_ids=CHK-001..004`，指纹 before=after=`3e26bbba…`，并发出 `finalization_notice`。检查用量 #1 30267、#2 32152，合计 62419 tokens。
- 停止与终态：Root 收到终检通知后调用 stop；10:25:49Z 停止确认 `confirmed=true`、`status_after=idle`、`active_tools_after=0`、`async_jobs_settled=true`；但 **`state.status=paused`**（非 `complete`），且 TUI 出现 "Operation aborted"（用户报告）。停止缺口已交 OMP 处理，需新构建复验；**不得记 complete**。
- 其他事实：10:22:07Z TypeSafe 一次 `Net::OpenTimeout`（`jev_unavailable`，非终止，后续评估恢复）；Root 因证据格式先查源码后才提交（使用指导问题）；空任务目录 `0d647029-a82a-439e-a415-25847f14c37a` 仅有 `instruction.txt`、无 `state.json`，记为**待查**。
- 用量汇总（原值）：`elapsed=473.9s`；JEV stage1 input 19793／output 518，stage2 input 13544／output 114；检查 62419 tokens；`sent_message_ids` 3 条。
- 结论边界：P2 未满足成员正样本；自动检查的 stale finding **不是纠偏送达**（本样本无 finding 送达 Root）；E 不得记为全通过；M4 仍待验。

## 单 Root 样本 P3（构建 F）：单 Root 检查与正常 complete 路径通过，成员正样本仍不满足

- 固定构建：构建 F（`6ad26e9c…`，release `c4132869…`，installed_at `2026-09-24T11:04:02Z`）；Herdr 临时 pane `w1B:p25`；隔离项目 `/tmp/orbit-m4-next-positive-sxNiAt/project`；任务 `129b1f69-179e-4d81-9aa8-487d3ade82c5`；命令 `orbit omp --model zhipu-coding-plan/glm-5.2`，完整 prompt `/tmp/orbit-m4-next-positive-sxNiAt/prompt.txt`。Root 独自完成两个模块（A `src/ingest.js` + 测试 5/5，B `src/publish.js` + 测试 4/4），fixture `npm test` 9/9（Root 停止原因记录）。
- JEV：stage1 首次 `delegatable=0.92`（11:09:53Z）；stage2 `member_fit=0.15`、`parallel_gain=0.30`、`decision=declined`（11:09:54Z）；**无 `evidence_request`、无 `delegation_hint`、无成员**（`members=[]`），Root 独自完成。本样本**不构成成员正样本**。
- 独立检查：手动终检 `checks/1`（11:12:03Z–11:13:12Z；独立 OMP reviewer，PID/PGID 79600，模型 `zhipu-coding-plan/glm-5.2`）；基于固定快照（`scope.json`），`evidence.json` 指纹 before=after=`sha256:feeca5b1e7cd86d0ac3ca4f8ce6cf831a2f0d85ec1e3e01a70a883a214adf966`（与 `finalization_notice` 的 `version` 同值），`active_tools` 为 glob/grep/read，`read_tool_is_confined=true`，`forbidden_tools_present=[]`；verdict `continue`、无 findings；check tokens 35873。
- 完成与停止：11:13:12Z 发 `finalization_notice`；11:13:18Z `completion_stop_queued`；11:13:31Z `completed_via_finalized_stop` 与 `stopped`；`state.status=complete`，`stop_confirmation` `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；Root 完整最终回复可见；测试 pane 已 `/exit` 并关闭，Root PID 63330 与 reviewer PID 79600 均已消失。
- 用量汇总（原值）：`elapsed=224.2s`；JEV stage1 input 12594／output 296（含 4 次评估），stage2 input 3952／output 38；检查 35873 tokens。
- 其他事实：空任务目录 `e9049496…` 仅有 `instruction.txt` 与 `inbox/`、无 `state.json`，记为**待查**（OMP 编码会话正在只读调查）。
- 结论边界：P3 证明 **F 上单 Root 独立检查与正常 `complete` 停止路径**；**不证明**成员正样本、带 finding 纠偏送达、worktree rebind 或崩溃后显式 `stop` 重试；F 不得记为整体通过（当时口径：M4 pending；已于 2026-09-25 闭合）。

## 双工作面样本 H（构建 H）：中断，不算完成

- 固定构建：构建 H（`74bd8460…`，release `4dc31e162db91d6c1c85df44`）；Herdr pane `w1B:p27`（新会话，Root 模型 `kimi-code/kimi-for-coding`）；隔离项目 `/tmp/orbit-m4-dual-b61fDt/project`；任务 `380b12ee-7653-450e-a4fb-fa9cefa3dfcf`。
- JEV 两阶段（真实分数与用量取自 `events.jsonl`）：第一阶段 `delegatable=0.93`（其后观察 0.92/0.91/0.84），存在可调用成员，12:07:52Z 记录 `model_evidence_needed`（Root `kimi-code/kimi-for-coding`，候选 `zhipu-coding-plan/glm-5.2`，reasoning 均 unknown）。Root 两次提交证据，第二阶段两次均 declined：12:14:32Z `member_fit=0.44/parallel_gain=0.40`（input 3401/output 38），12:16:13Z `member_fit=0.29/parallel_gain=0.44`（input 5084/output 38）；两次证据摘要均带观察签名持久化（`model_evidence_used`）。**无 `delegation_hint`，`members=[]`，未派发成员**——不记为成员/分工正样本，只记"未观察到误派发"。
- 独立检查：#1 `process_reviewer`（PID 872，12:09:53Z）、#2 `reviewer`（PID 9037，12:12:46Z）、#3 `reviewer`（PID 25055，12:18:10Z）均在interrupt前在途，无 verdict、无用量记录；reviewer 模型 `kimi-code/kimi-for-coding`（非 GLM）。
- 中断与停止：Controller 发现真实矛盾（`forecast.test.js:41` 与需求/测试 #2 冲突），以原生 Esc 中断 Root turn（12:19:15Z），`stop_reason="The user interrupted the Root turn"`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；Root 进程 PID 93688 在 /exit 后消失，reviewer PID 25055 复核不存在，pane 已关闭。任务终态 `paused`。**样本因真实产品矛盾被主动中断，不算完成**；带 finding 的纠偏、复核收敛、rebind、成员正样本在本样本中均未发生，不预宣称通过。
- 证据质量限制：stage1/2 分数与用量来自任务 `events.jsonl`；三次检查均在途，无 verdict 与检查 token 用量可记；检查者实际模型为 kimi-code/kimi-for-coding。普通 `omp` 被动证据：构建 H 用 pane `w1B:p26` 实测，argv 为裸 `omp`，`/tools` recent 未见 Orbit 工具，无旧全局入口，已 /exit 关闭。

## 单 Root 样本 H（构建 H）：自检 + 独立无 finding 终检 + complete，通过（仍不证明纠偏投递）

- 固定构建：构建 H（`74bd8460…`，release `4dc31e162db91d6c1c85df44`）；Herdr pane `w1B:p28`（新会话）；fixture 仓库 `/tmp/orbit-m4-finding-fixture.U14s0x`（预置 greet 库，USAGE.md 真实遗漏空名处理两处）；任务 `81285102-6e53-410e-8228-db0fac7fb5e8`。
- Root 行为：Root 自己发现并修复 USAGE.md 两处遗漏，`python3 -m unittest` 5/5 通过。
- 独立检查 #1：12:24:57–12:25:34Z，`manual_check` reviewer，进程 PID/PGID 48277，模型 `kimi-code/kimi-for-coding`，只读受限工具（read/glob/grep）；固定快照前后指纹一致（`sha256:189ba7a5…`）；verdict `continue`、无 findings；检查 tokens 22993。`finalization_notice` 送达后 Root 工具 stop（complete 意图），turn 正常结束，12:26:01Z 记录 `completed_via_finalized_stop`，`status=complete`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- JEV 与异常：第二阶段 `member_fit=0.46/parallel_gain=0.27` declined（缓存证据路径），一次 `Net::OpenTimeout` 非致命恢复。
- 收尾：Root PID 34194 与 reviewer PID 48277 均已消失，p28 已 /exit 关闭。
- 范围声明：本轮仅证明 **H 上单 Root 自检 + 独立无 finding 终检 + 正常 complete 停止**；带 finding 的纠偏投递仍未验收，文档状态不变（仍 pending）。

## 双工作面样本 dual2（构建 H）：中断，不算完成

- 固定构建：构建 H（`74bd8460…`，release `4dc31e16…`）；Herdr pane `w1B:p29`（新会话，Root `kimi-code/kimi-for-coding`）；隔离项目 `/tmp/orbit-m4-dual2-QUwzRl/project`；任务 `02bb9fc0-6f71-4a0f-8322-f9869763f922`。
- JEV：第一阶段 `delegatable=0.93`；提交证据后第二阶段 `member_fit=0.25/parallel_gain=0.35` declined。**无 `delegation_hint`、`members=[]`、无检查**（0 次 `check_started`）；fixture 14 项测试与 prompt 一致，但该任务尚未交付。
- 中断与停止：Controller 判定正样本不可能且不为消耗模型，原生 Esc 中断 Root turn；`stop_reason="The user interrupted the Root turn"`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；任务终态 `paused`；/exit 后 p29 关闭，Root PID 54538 消失。本样本不算完成，成员正样本与纠偏投递仍未验收。

## 短试 p2A（构建 H）：未进入目标拓扑，不计通过

- Herdr pane `w1B:p2A`，隔离项目 `/tmp/orbit-m4-finding-buwc4o/project`：Root 在读取现有代码时自行发现遗漏，但**未创建 `.orbit` 任务**；Controller Esc → /exit → 关闭 pane，项目未改动。该短试未进入受控 Orbit 拓扑，不计入任何验收，亦不证明 finding 已送达。

## 短试 p2B（构建 H）：未创建任务，不计目标拓扑

- 隔离项目 `/tmp/orbit-m4-rebind-AYUSYZ/repo`。Root 未创建 Orbit task，误用 native task 做终检；登记门提示 `Start Orbit for this session before delegating`。Controller Esc / exit 关闭。未进入目标拓扑，不计验收。

## 短试 p2C（构建 H）：rebind 局部证据，不算完整 rebind

- 构建 H（`74bd8460…`）；Herdr pane `w1B:p2C`；隔离项目 `/tmp/orbit-m4-rebind2-7GP9De/repo`；任务 `7411294c-0132-491b-afa3-d22d1a690c50`。
- check1 于 12:43:50 在途；Controller 于 12:43:59 将产物目录 rebind 到关联 worktree 并 amend。check1 于 12:44:23 结束，`stale_reasons` 为 `workspace` / `artifact` / `input`，finding 不迁移。
- check2（trigger `rebind`，12:44:24–12:44:48）fresh；scope 的 `artifact_root` 为该 worktree。独立 OMP reviewer pid 93985，只用 read/glob/grep，前后指纹 `sha256:b94012ff…`。3 个 finding 为 open。纠正消息 `sent_message_ids` 1 条，`comparison.correction_messages=1`。
- Root 仍在旧 repo 写入，worktree 未改。fixture `test/merge.test.js` 第一条期望 `[[1,4],[5,7]]` 与相邻合并需求冲突。Controller 于 12:45:26 Esc；`status=paused`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；/exit 后 pane 关闭。
- 只证明在途检查因 rebind 过期、新根另起一次检查、纠正消息送出一次。不算完整 rebind，也不算 finding 纠偏收敛。

## rebind3（构建 I）：完整 rebind 与纠偏收敛通过

- 构建 I（`f1e5cbc0…`，release `98caf20b114ba5dfa387573a`）；Herdr pane `w1B:p2D`；repo `/tmp/orbit-m4-rebind3-MjSLNf/repo`，worktree `/tmp/orbit-m4-rebind3-MjSLNf/worktree`；任务 `2e27fce9-60c3-46db-a192-b3da3cabb76d`。运行中的 runtime PID 为 26015。
- check1 于 12:59:20 在途；Controller 于 12:59:32 rebind 到关联 worktree 并 amend。check1 于 12:59:39 结束，`stale_reasons` 为 `workspace` / `artifact` / `input`，4 个 finding 不迁移。
- check2（trigger `rebind`，12:59:41–13:00:18）fresh，scope 为 worktree，给出 F1–F4。13:00:18 有一次 `correction_sent`。`sent_message_ids` 共 4 条，`comparison.correction_messages=4`，其中只有这一条是纠偏事件，不把该计数当成四次纠偏。
- Root 收到通知和该次纠正后在 worktree 完成；旧 repo 只剩未跟踪的 `.orbit`，产品改动在 worktree。记录的 `npm test` 为 7/7。Root 以 `check` 请求 check3（13:01:13–13:01:29）fresh，无 finding，`resolved_ids` 为 F1–F4；随后 `finalization_notice` 与 `completed_via_finalized_stop`。终态 `complete`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- 三次独立 OMP reviewer PID 26347 / 27085 / 30043，模型 `kimi-code/kimi-for-coding`，scope 根依次为旧 repo、worktree、worktree。前后指纹分别为 `sha256:91cff19a…`、`sha256:8a83d141…`、`sha256:e5c2f7c9…`，且 before 等于 after。工具只有 read/glob/grep，`forbidden_tools_present=[]`，`read_tool_is_confined=true`。三次 `total_tokens` 16677+16448+13068=46193，与 `usage.check_tokens` 一致。记录的 `jev_stage1` 为 7122/222；`members=[]`。事后 Root 与三个 reviewer PID 均不存在，p2D 已 /exit 关闭。
- 本样本通过完整 rebind、真实 finding 送达、Root 修复、复核与正常 `complete`。不证明成员正样本或异常退出后的显式 `stop` 重试。p2B、p2C 的失败与局部事实仍保留。

## 异常退出重试（构建 I）：无成员路径通过

- 构建 I；临时 OMP pane `w1B:p2F`（已关闭）；任务目录 `/tmp/orbit-m4-runtime-pXAKRX/project/.orbit/tasks/aa82d66e-415a-486a-9ba6-e146584abcd2`。
- `state.runtime_pid` 为 45885。Controller 核对进程命令与 PGID 后，只对该正 PID 发送 SIGKILL。该字段在终态仍保留：SIGKILL 不跑 `ensure`，`retry_stop` 也不删除它，不能据此说进程仍存活。
- 随后 `orbit stop --json` 走重试。记录的 `stop_reason` 为 `The user requested cleanup after runtime exit`，`status=paused`。`stop_confirmation.confirmed=true`、`status_after=idle`、`active_tools_after=0`、`async_jobs_settled=true`。事件 `stopped` 于 13:06:46Z，无 `stop_unconfirmed`。
- `members=[]`，无检查。只证明无成员时，运行进程异常退出后的显式 `stop` 重试。不证明成员停止，也不证明 parked 成员。

## member-audit（构建 I）：stage2 declined，不证明成员正样本

- 构建 I；Herdr pane `w1B:p2G`（已 /exit 关闭）；fixture `/tmp/orbit-m4-member-audit-n5wq/project`，prompt 与 audit 在同目录，commit `4964d06`。任务 `f3763481-92d8-4443-b8a3-f93e674a95d2`。
- Root 为 `zhipu-coding-plan/glm-5.2`，task 候选为 `deepseek/deepseek-flash`。stage1 `delegatable` 为 0.89 与 0.91；stage2 两次均为 declined（0.28/0.35、0.32/0.38）。无 `delegation_hint`，`members=[]`。Root 自己完成 A/B；停止原因记录 `npm test` 14/14。
- 一次 fresh 手动终检（13:15:11–13:16:50）无 finding。reviewer 模型 `zhipu-coding-plan/glm-5.2`，只用 read/glob/grep，`forbidden_tools_present=[]`，`read_tool_is_confined=true`，前后指纹同为 `sha256:c2f6a7e8…`，`total_tokens` 59730，与 `usage.check_tokens` 一致。随后 `finalization_notice` 与 `completed_via_finalized_stop`。终态 `complete`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- 候选缓存的 `comparison.identity_offset` 写成 Root 与候选同为 `deepseek/deepseek-flash`，与同份摘要里的 Root 身份 `zhipu-coding-plan/glm-5.2` 矛盾。这是缓存事实错误，代码修复在途，原样本不改写。不推断该错误一定导致 declined。
- 同目录 `c38dd10b-ea95-4ec7-8528-96a9d0b7dbe5` 没有 `state.json`，不是任务，另行核查，不计入本样本。
- **不证明成员正样本。**

## member-v2（构建 J）：检查解析失败，不计 complete

- 构建 J；Herdr pane `w1B:p2H`（已关闭）；任务 `/tmp/orbit-m4-member-v2-auwl/project/.orbit/tasks/f7e31c75-e64e-4a21-acb7-d2e0879e2e4d`。Root `zhipu-coding-plan/glm-5.2`，候选 `deepseek/deepseek-flash`。stage1 `delegatable` 为 0.89 与 0.88；stage2 declined（0.20/0.34、0.21/0.34）。无 hint，`members=[]`。Root 做了 A/B；验收观察记录 `npm test` 15/15。这不是任务完成结论。
- check1 于 13:30:59 启动。快照指纹 before 等于 after（`sha256:f4679e39…`），工具只有 read/glob/grep，`forbidden_tools_present=[]`，`read_tool_is_confined=true`。reviewer 最终消息在 JSON 前有英文散文，解析错误为 `Unexpected identifier "I"`。TaskRuntime 记 `failed`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。reviewer PID 12690 见 `run.json`；runtime PID 8087 为 Controller 记录，终态已无 `runtime_pid`。两进程均已退出。
- 本次交给 JEV 的候选摘要不再含 `comparison.identity_offset`。不把该字段的缺失或存在推断为 declined 的原因。checker 故障仍由 OMP 只读审计，不宣称检查通过。
- 同规格 clone `/tmp/orbit-m4-member-k3-zri7/project` 后来在构建 K 上启动，见 K3 样本；当时这条 v2 记录不把它算进 v2。
- **不计 complete，不计成员正样本，不宣称 checker 通过。** 该失败原貌保留。

## K3（构建 K）：无成员 finding 纠偏收敛，不算成员正样本

- 构建 K；Herdr pane `w1B:p2J`（已 /exit 关闭）；任务 `/tmp/orbit-m4-member-k3-zri7/project/.orbit/tasks/35c06d44-c3a4-490c-829d-0308d392b92d`。Root `zhipu-coding-plan/glm-5.2`，task 候选 `kimi-code/k3`。证据请求两次、提交一次后，stage2 declined（`member_fit=0.25`、`parallel_gain=0.41`）。stage1 在提交前达到 0.89，其后另有 0.88；更早读数为 0.86–0.87。无 hint，`members=[]`。Root 自己完成 A/B；停止原因记录 `npm test` 15/15。
- check1 是 process reviewer，`continue`，fresh。check2 由 timer 触发，fresh，finding 为 `F1-REPORT-STUB`、`F2-README-EXAMPLES`、`F3-INTEGRATION-ACCEPTANCE`，14:05:26 一次 `correction_sent`。check3 为手动终检，fresh，无 finding，`resolved_ids` 为这三项。随后 `finalization_notice` 与 `completed_via_finalized_stop`。终态 `complete`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- 三次 reviewer PID 90364 / 94261 / 98229 见各次 `run.json`，模型均为 `zhipu-coding-plan/glm-5.2`，只用 read/glob/grep，`forbidden_tools_present=[]`，`read_tool_is_confined=true`，前后指纹相等。runtime PID 84086 为 Controller 记录，终态已无 `runtime_pid`。这些进程均已退出。
- 只证明无成员时的 finding 纠偏收敛。**不算成员正样本。** 构建 J 的 v2 仍是 `failed`。

## GLM 同模型对照（构建 K）：stage2 declined，不算成员正样本

- 构建 K；Herdr pane `w1B:p2K`（已 /exit 关闭）；任务 `/tmp/orbit-m4-member-glm-woag/project/.orbit/tasks/9d8af567-13d6-44f5-907b-3c9a3ab79115`。交给 JEV 的 Root 与候选都是 `zhipu-coding-plan/glm-5.2`，reasoning 都是 `unknown`。stage1 `delegatable` 先为 0.88，后为 0.87；stage2 declined（`member_fit=0.21`、`parallel_gain=0.38`）。无 `delegation_hint`，`members=[]`。
- Root 完成两个模块。check1（14:12:35–14:14:33）fresh，无 finding；reviewer 只用 read/glob/grep，`forbidden_tools_present=[]`，`read_tool_is_confined=true`，前后指纹相等。随后 `finalization_notice` 与 `completed_via_finalized_stop`。终态 `complete`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。停止原因文本是 `User requested stop`。
- 只证明同模型身份下 stage2 仍 declined，且无成员时可以正常终检并 `complete`。**不算成员正样本。**

## 英文对照（构建 K）：同模型仍 declined，不算成员正样本

- 构建 K；Herdr pane `w1B:p2M`（已 /exit 关闭）；夹具 `/tmp/orbit-m4-member-english-66aj/project`，prompt `/tmp/orbit-m4-member-english-prompt.txt`；任务 `e07af778-1323-49f3-8025-27454192942f`。Root 与候选都是 `zhipu-coding-plan/glm-5.2`，reasoning 都是 `unknown`。初始 HEAD `4a4ec3b0` 与中文对照 `7197ca7f` 相比，只有 `README.md` 的 blob 不同；README 与外部 prompt 为英文。
- stage1 首次 `delegatable=0.87`，随后有 0.82。stage2 先 declined（0.15/0.35），后 declined（0.18/0.35）。无 `delegation_hint`，`members=[]`。停止原因记录 ingest 7/7、report 7/7、完整 `npm test` 15/15。
- check1（14:29:52–14:31:20）fresh，无 finding。reviewer PID 57690，只用 read/glob/grep，`forbidden_tools_present=[]`，`read_tool_is_confined=true`，前后指纹相等。随后 `finalization_notice` 与 `completed_via_finalized_stop`。终态 `complete`，`stop_confirmation.confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- 只证明英文 README/prompt 的同模型对照仍 declined，且无成员时可以正常终检并 `complete`。**不算成员正样本，也不认定语言是 declined 的原因。**

## 显式成员机械路径（构建 K）：不是 JEV hint 正样本

- 构建 K；Herdr pane `w1B:p2N`（已 /exit 关闭）；夹具 `/tmp/orbit-m4-explicit-member-levr/project`，prompt `/tmp/orbit-m4-explicit-member-prompt.txt`；任务 `61bbd66d-981a-4706-97e8-00fae87e9f58`。用户显式要求派发工作面 B。stage1 `delegatable=0.95`；stage2 declined（`member_fit=0.27`、`parallel_gain=0.53`）。无 `delegation_hint`。
- 原生成员 `orbit-04344597-6bde-4fea-9f35-02bf938b4bdb` 于 14:37:28 持久登记，`basis=root_without_hint`。成员会话首次 `model_usage` 为 14:37:29.235Z，首个 assistant message 为 14:37:31.120Z。`member_result_recorded` 于 14:38:00，`delivery=native_task`。停止原因记录成员 B 7/7、整体 `npm test` 15/15。
- 观察到的 `native_collaboration` 只有一条 `task_result`，文本说明结果自动交付。没有观察到显式 `hub send` 或 `hub wait`，不宣称该路径。
- check1（14:38:58–14:40:19）fresh，verdict `correct`，无 finding。reviewer PID 89414 已不存在；只用 read/glob/grep，`forbidden_tools_present=[]`，`read_tool_is_confined=true`，前后指纹同为 `sha256:e6d0acd9…`。终态 `complete`。Root 与该成员的 `stop_confirmation` 都是 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。
- **机械路径正样本，但不满足 JEV hint 正样本，也未覆盖成员异常重试。**

## 有成员异常停止重试（构建 K）：只证明在途停止确认

- 构建 K；Herdr pane `w1B:p2P`（已 /exit 关闭）；夹具 `/tmp/orbit-m4-member-stopretry-m0o6`；任务 `c8d89ea6-178b-4b03-94a1-0d9564f25fde`。Root 与候选都是 `zhipu-coding-plan/glm-5.2`。stage1 `delegatable=0.95`；stage2 declined（0.25/0.52）。无 hint，无检查。
- 成员 `orbit-194291ea-08a2-458f-bc63-68f3b0e3c629` 于 14:45:31 登记，`basis=root_without_hint`。终态成员字段仍是 `status=registered`、`registry_status=running`，`runtime_pid` 仍是 1723。这是 SIGKILL 前留下的字段，不是停止权威。
- Controller 先用 `ps` 核对该正 PID，再于 14:45:53Z 只对它发送 SIGKILL。随后从 `/` 执行 `orbit stop`，记录的原因是运行进程被单独 SIGKILL 时成员仍在登记并工作。事件 `stopped` 于 14:46:03Z。终态 `paused`。Root 与成员的 `stop_confirmation` 都是 `confirmed=true`、`status_after=idle`、`active_tools_after=0`、`async_jobs_settled=true`；成员确认里的 `registry_status=idle`。
- 任务被故意中断。**不计完成，不计成员协作交付，不宣称 JEV hint 或 check。** 只证明有成员在途时，异常 runtime 退出后的显式 `stop` 重试与确认。

## 跨模型样本 L1（构建 L）：无 hint/成员，stale finding 自动复核 resolved（无 correction_sent），正常 complete 停止

- 构建 L；夹具 `/tmp/orbit-m4-crossmodel-rlev/project`（HEAD `cd541a5`，模型中性 prompt，无模型名；`npm test` 15/15）；任务 `42d1977e-d9a6-4464-bc98-8ab75cd67fe7`。Root `zhipu-coding-plan/glm-5.2`，task 候选 `volcengine/kimi-k2.7-code`（跨模型）。
- JEV：stage1 `delegatable=0.88`（15:34:29Z）；证据请求两次（15:34:29Z、15:35:30Z），提交一次（15:39:53Z，2 entries）；stage2 declined（`member_fit=0.28`、`parallel_gain=0.21`，15:39:55Z），无 `delegation_hint`，`members=[]`，Root 自行完成 A/B。
- 独立检查：#1 `process_reviewer`（15:37:30Z–15:38:07Z）stale `host`、verdict `continue`；#2 `reviewer`（15:39:23Z–15:40:43Z）verdict `correct`，finding `F1-readme-run-examples`（README 缺逐面运行示例），完成时 artifact stale → `recheck_pending`（count=1）；**事件记录中无 `correction_sent`**：Root 已自行更新 README（#3 新快照前）；#3 手动终检 `reviewer`（15:40:44Z–15:41:53Z）对新快照 `stale=false`、verdict `continue`、`resolved_ids=[F1-readme-run-examples]`、指纹 before=after `sha256:505b1dfa…`、只读受限（glob/grep/read）、`forbidden_tools_present=[]`；15:41:53Z `finalization_notice`。检查 tokens 合计 121345（#1 32229、#2 40481、#3 48635）。
- 停止与终态：15:41:57Z `completion_stop_queued`（reason `User requested stop`）；15:42:05Z `completed_via_finalized_stop` + `stopped`；`state.status=complete`，`stop_confirmation` `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；`elapsed=463.9s`；JEV stage1 29448/444、stage2 6276/38。
- 结论边界：本样本证明构建 L 上跨模型候选无 hint、无成员，以及 stale finding 自动复核并 resolved（**无 `correction_sent`，不是纠偏送达路径**）与正常 `complete` 停止；**不构成 JEV hint 正样本或成员正样本**，不计全通过。

## 活动成员修改（构建 M）：`4d41ba19`，不是 hint，也不是冻结 9

- 构建 M；夹具 `/tmp/orbit-m4-amend-next-YSON/project`；任务 `4d41ba19-7ec7-4d4e-a709-c4181e54bd1e`。stage2 declined（`member_fit=0.20`、`parallel_gain=0.30`）。无 `delegation_hint`。一名成员 `orbit-bd72e310-aca3-4fe0-a646-e2dac3b8d46b`，模型 `deepseek/deepseek-flash`，`basis=root_without_hint`。
- 16:30:03.086Z 成员会话第一条 assistant。16:30:03Z `instruction_amended`（`explicit_text`）与 `member_amendment_sent`。16:30:03.692Z 成员 JSONL 有 `customType=orbit` 的 amendment 正文。其后 assistant 写明按 0.97→1.7 实现，并改了 `src/reorder.js` 与 `test/reorder.test.js`。Controller 日志把同一秒标成 `same_second_uncertain`，不把传输回执当成模型收到。
- hub：16:30:05Z 与 16:30:40Z `hub_call op=send`，结果文本为 `injected`；16:31:19Z 结果文本为 `woken`。事件里没有 `op=wait`。两次 `member_result_recorded`（16:31:05Z、16:31:25Z），`delivery=native_task`。
- 检查 #1 16:30:49Z `stale=true`（`artifact`），verdict `continue`。检查 #2 16:32:37Z `stale=false`，verdict `continue`，findings 为空。无 `correction_sent`。Root 会话 16:31:36.756Z 的 `npm test` 后台结果是 tests 13、pass 13、fail 0。这是会话记录，不是 Controller 复跑。
- 16:32:50Z `completed_via_finalized_stop` 与 `stopped`。Root 与该成员的停止确认都是 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`。终态 `complete`。
- **不是 JEV hint 正样本。** 无 finding、无 `correction_sent`，不满足冻结验收 9。不计全通过。

## 前一失败 `9238dc06`：amend 晚到，检查 JSON 解析失败

- 报告 `/tmp/orbit-m4-rerun-9238dc06-report.md`。任务 `9238dc06-10bb-4ba3-b892-e641451fe8cd`。stage2 declined（0.20/0.31），`basis=root_without_hint`，无 `delegation_hint`。成员 16:12:01Z 已 `member_result_recorded`，外部 amend 16:12:05Z，无 `member_amendment_sent`。
- 检查 #2 的 `raw_text` 不是整段 JSON，错误是 `Unexpected identifier "All"`。任务 `failed`。停止确认仍为真。不是 hint 正样本，也不算活动成员送达。

## 单链样本 one-chain（构建 M）：合同收尾语义 FAIL，冻结 9 未通过

- 构建 M；方案 `/tmp/orbit-m4-one-chain-next-design.md`；夹具 `/tmp/orbit-m4-one-chain-HpXY/project`（clone 自干净 8-file HEAD `64b612f`）；任务 `5ec69b23-1aa6-4839-b9f0-c0b2ecd7aeb8`；报告 `/tmp/orbit-m4-one-chain-result.md`；Root 会话默认模型 `kimi-code/kimi-for-coding`，成员 `deepseek/deepseek-flash`。
- 成员路径 OK：恰好 1 名跨模型成员，16:42:34Z 登记先于模型工作，16:42:42Z `member_result_recorded`（`delivery=native_task`），hub 回传后 Root 集成。
- **checker 无 finding**：check #1（16:43:41Z）与 #2（16:44:11Z）均 `stale=false`、`verdict=complete`；SUT 自然完成两条文档验收条款（README 单跑命令与 B-200 qty 37 示例，运行前 grep 证实发现面存在）；`correction_sent` 计数 0。finding/correction/recheck 一环未发生。
- **合同收尾语义 FAIL（不勾冻结 9，不勾停止语义通过）**：`events.jsonl`（15 行）止于 check_finished #2，**无 `finalization_notice`、无 `completed_via_finalized_stop`、无 `stopped`**；`state.finalization_notices={}`。reviewer #2 返回 fresh `complete` 时，TaskRuntime 旧 complete 分支（`lib/orbit/task_runtime.rb:1640-1663`）直接把 `state=complete` 并写入 `stop_confirmation`（confirmed=true），Root 未显式调用 stop，也无终检通知 Root 的记录；违反 `contracts/task-runtime.md:50,71` 与 `docs/adr/007-task-runtime-refactor.md:133`。state.json 与 #2 同时落盘（16:44:11Z）佐证自动 complete 分支。**资源收尾证据存在**（stop_confirmation scope 完整、member_stop_results confirmed、`active_tools_after=0`、`async_jobs_settled=true`），但由 runtime 自动盖章产生，不充当合同收尾语义。**已交 Pi 修复；修复已写入并安装为构建 N（digest `3b15a5f7…`，release `f947b6b9…`，installed_at `2026-09-24T16:55:01Z`）。N 复验已有结果：postfix one-chain `66d7fa45` FAIL（显式 stop 路径仍缺 `finalization_notice`，见下节）；不把 `5ec69b23` 的 state=complete 当作停止语义或冻结 9 证据。
- 产物：A/B 实现，`node --test` 12/12 通过；Frozen integration 未改；单次初始 prompt 后 controller 零 steering。

## postfix one-chain（构建 N）：显式 stop 路径仍失败，非冻结 9

- 构建 N（digest `3b15a5f…`，installed_at `16:55:01Z`）；方案 `/tmp/orbit-m4-postfix-one-chain-design.md`；夹具 `/tmp/orbit-m4-postfix-FqOk/project`（K3 HEAD `f3b6022` clone，两桩零改动）；任务 `66d7fa45-eed9-4f3c-b1a4-04d2c3191e40`；报告 `/tmp/orbit-m4-postfix-one-chain-result.md`；Root `kimi-code/kimi-for-coding`，成员 `deepseek/deepseek-flash`。
- 成员路径 OK：1 名跨模型成员 17:00:15Z 登记、17:00:24Z `member_result_recorded`（`delivery=native_task`）、hub 回收。
- finding 环未触发（如实）：check #1（17:01:56Z）`stale=false`、`verdict=complete`、无 finding——SUT 正确实现"字段校验先于去重登记"语义并写入 README；`correction_sent`=0。
- **FAIL 主因（Pi 修复未覆盖）**：check #1 fresh complete 后**无 `finalization_notice`**（`state.finalization_notices={}`）；`next_check_manual=false`、`next_check_trigger=checker_interval`；17:02:56Z 自动 check #2 fresh complete 被 `automatic_check_complete_ignored` 正确忽略，同样不通知 Root；Root 按 prompt 等待通知不自停 → **显式 stop 不可达**。此后仅 JEV 空转 tick（至 17:07:18Z），22 条事件中无 finalization/stopped/correction_sent。
- **收尾实况（如实，含 Controller 失误）**：Root 空闲时原生 Esc（多种 herdr 语法）均不产生 `stopped`——空闲 OMP 无可用用户中断；Controller 在 user 指示 `/exit` 前误执行了后台 `herdr pane close w1B:p2X`（取消不及），会话进程实退；随后 `orbit stop` 三次（REAL_EXIT=0）均 `status=queued` 写入 inbox（3 条 `{type:stop}` 无人消费，CLI 明示"入队不代表停止已确认"）。**终态：`status=running`（记录态）、`runtime_pid=None`、`stop_confirmation=None`——确认不足，但产品未进入 `stop_unconfirmed` 状态**；成员早已 completed，全部真实进程已退出。**以上均为 Controller 清理与进程事实，非 Root 完成。**
- 结论：构建 N 上冻结 9 仍不通过。剩余缺口归口：① `finalization_notice` timing——Pi 已实现并随构建 O 安装，构建 N 实测仍缺（`66d7fa45`），构建 O 上尚未用新的真实任务复验；② 进程存活时 CLI `orbit stop` 在 awaiting notice 期间的可消费性——本样本未验证（Esc 未触发 `stopped` 已实记），待验证；③ runtime 死亡后 orphan PID 收尾（inbox stop 无人消费）——OpenCode 已实现并随构建 O 安装，O 上对 `66d7fa45` 的唯一一次离线 stop 为诚实判负（见下）。

## 构建 O：orphan 遗留任务唯一一次离线 stop（诚实判负，不算冻结 7 全过）

- 构建 O（digest `7228ee7a…`，release `08a08b03…`，installed_at `17:20:54Z`）；任务仍为构建 N 的 postfix one-chain `66d7fa45-eed9-4f3c-b1a4-04d2c3191e40`；证据 `/tmp/orbit-m4-build-o-orphan-retry.md`、CLI 响应 `/tmp/orbit-m4-build-o-stop.json`。
- 调用前（只读核对）：`status=running`、`runtime_pid=None`、`finished_at=17:07:33Z`、`stop_confirmation=None`；成员 `orbit-a2f55e4b-…` completed；inbox 仍有构建 N 时写入的 3 条 queued stop；无相关进程，前置条件成立。
- 唯一一次 `orbit stop TASK --json`：**REAL_EXIT=1**，响应 `status=stop_unconfirmed`；state 由 `running` → **`stop_unconfirmed`**；`stop_reason=The user requested cleanup after runtime exit`，`stop_confirmation=None`（**未确认**）；`events.jsonl` 新增一条 `17:21:57Z type=stop_unconfirmed`，error 为成员桥 socket 不存在（`Member orbit-a2f55e4b-…: omp connection: No such file or directory - connect(2)`）；inbox 仍 3 条（离线路径不消费 inbox）。
- 判定：orphan PID 路径对"runtime 已死 + 成员桥 socket 缺失"给出如实的负向终态，没有把确认不足写成成功；成员实际停止确认因 socket 缺失无法取得，因此**不算冻结验收 7 全过**，也不把源码修复当真实 finalization 通过。`66d7fa45` 的构建 N FAIL 与原始记录原样保留。

## 单链样本 b9e87009（构建 O）：PARTIAL-A + 延迟通知时序分支通过，仍非冻结 9

- 构建 O（digest `7228ee7a…`，installed_at `17:20:54Z`）；方案 `/tmp/orbit-m4-build-o-one-chain-design.md`；夹具 `/tmp/orbit-m4-buildo-voOs/project`（K3 HEAD `f3b6022` clone，两桩零改动）；任务 `b9e87009-96ff-460d-a81f-5b1048951c5b`；报告 `/tmp/orbit-m4-build-o-one-chain-result.md`；Root `kimi-code/kimi-for-coding`，成员 `deepseek/deepseek-flash`。
- 成员路径 OK：1 名成员 17:29:07Z 登记先于模型工作，17:29:27Z `member_result_recorded`（`delivery=native_task`），hub 回收；用户显式授权派发——**派发前 stage2 决策为 17:28:59Z `member_fit=0.22`/`parallel_gain=0.29` declined**（basis=root_without_hint，非 JEV hint；17:30:00Z 第二次 0.46/0.33 declined 发生在登记后，不作派发前决策）。
- finding 环未触发（如实）：check #1（17:31:04→17:31:57）`stale=false`、`verdict=complete`、无 finding；`correction_sent`=0。SUT 完全满足本轮时区语义（README:29 条款 + `Date.parse` instant 排序），`node --test` 15/15。用量（TaskStore 口径）：check #1 `check_tokens=62281`（含 cacheRead，分段见 `checks/1/evidence.json`，reviewer `kimi-code/kimi-for-coding`）；JEV stage1 input 12827/output 296、stage2 input 7806/output 76；成员 20s；elapsed 229.9s（≈3.8min）。
- **Pi 延迟通知时序分支（专项实测通过）**：17:31:57Z `finalization_pending`（check 1, version `sha256:c75cf969…`）→ Root idle → 17:32:23Z `finalization_notice`（同一 check、同一 version）。
- **显式 stop 达成**：17:32:30Z `completion_stop_queued` → 17:32:40Z `completed_via_finalized_stop` + `stopped`（Root 显式 stop）；`status=complete`、`stop_confirmation.confirmed=true`、成员 stop confirmed=true。
- 判定：**PARTIAL-A**——不勾冻结 #9（无 finding 无 `correction_sent`），不勾 JEV hint；收尾路径与延迟通知时序分支记通过事实。观察 4.4 分钟、检查 1 次，零 steering，cleanup stop 未使用。

## 冻结 9 样本 df4cf490（构建 P，历史）：FAIL——检查环假阴性（当时 #9 尚无通过样本）

- 构建 P（digest `dcf89b00…`，`0.6.14`，installed_at `18:06:22Z`）；设计 `/tmp/orbit-m4-frozen9-next-design.md`（v6）；夹具 `/tmp/orbit-m4-frozen9-MK1O/project`（expense-ledger，4 核心测试）；任务 `df4cf490-0251-43d6-83ba-f6d122185dfc`；报告 `/tmp/orbit-m4-frozen9-result.md`；Root `kimi-code/kimi-for-coding`，成员 `deepseek/deepseek-flash`。
- 成员路径 OK：1 名成员 18:11:24Z 登记、18:11:33Z `member_result_recorded`（登记先于模型工作由登记门 fail-close 保证，未引用成员 JSONL 首个 assistant 时间戳）；派发前 stage2 18:08:27Z 0.21/0.29 declined（root_without_hint 非 hint）。
- **真实产品遗漏**：prompt 要求逐行恰好四字段；`src/parse.js` 解构 `line.split(",")` 静默接受第五字段。Controller 只读复现（check #1 完成后、SUT 停止前，未改文件未 steering）：五字段行返回 rows 1 条、errors 空。
- **check #1 假阴性**：18:12:47Z `stale=false` verdict `complete` 且声称覆盖完整 A 契约，未报告上述遗漏 → 无 `correction_sent`，#9 finding/纠偏环断裂。记 FAIL（检查质量失败），不记 PASS/PARTIAL-A。
- 收尾通过事实：18:12:47Z `finalization_pending` → 18:13:08Z `finalization_notice`（同 check/version `5e4d04d7…`）→ 18:14:13Z `completed_via_finalized_stop`+`stopped`（Root 显式 stop），确认完整（Root+成员）。`node --test` 4/4（测试本就不锚字段数边界）。
- 用量：check #1 `check_tokens=26913`；JEV stage1 input 13682/output 370、stage2 input 3482/output 38；成员 ~9s；elapsed 353.8s（观察 6.4min）。零 steering、未用 cleanup stop。
- 产品发现：reviewer 对解析类"恰好 N 字段"契约未做反例探测（第二次检查质量缺口，对照 `5ec69b23`）。

## B3 retry_stop（构建 P）：SIGKILL 后显式 stop 重试通过（保留：retry_stop 名称未现于事件）

- 任务 `122167ec-b69f-4f40-8ae7-71f2cb35f8ca`，夹具 `/tmp/orbit-m4-b3-y0om`，报告 `/tmp/orbit-m4-build-p-stop7-b3-result.md`。
- 流程：Root 起 1 名 DeepSeek 成员（completed）+ owner-scoped `sleep 600`（PID 16344）；核对 runtime 15016（构建 P release、lsof 3 处锁任务目录）/ host 8762 / job 16344 互异且存活；18:39:29Z 仅 SIGKILL runtime，`orbit stop` exit 0 → 18:39:32Z `stopped`（reason `cleanup after runtime exit`），Root 与成员 stop_confirmation 均 confirmed=true，**job 16344 实退**，host 未动。
- 判定：按可观察行为通过；events 无 `retry_stop` 命名事件，该实现名是否触发无法证实，如实保留。

## adjudicator smoke（构建 P）：独立进程裁定通过（不证明活争议回路）

- 证据 `/tmp/orbit-m4-adjudicator-smoke.md`：`OmpCheckRunner.start(role:"adjudicator")` 独立进程组（PID/PGID 16956）在固定快照（expense-ledger 交付态，保留五字段争议上下文）完成一次模型裁定；verdict `continue`（推翻原 `complete`，finding 带行号证据）；active_tools=[glob,grep,read]、confined、指纹 before==after；模型 `kimi-code/kimi-for-coding`。
- 偏差：驱动 v1 收集阶段崩溃（未用 `runner.poll`），进程自退后证据自磁盘收集，无第二次模型调用。
- 范围：仅证明打包 adjudicator 独立进程/只读边界/裁定能力；**不证明**活 TaskRuntime 争议路由纠偏回路（该项仍缺）。

## 冻结 9 样本 b4e01ef4（0.6.15）：FAIL——无送达纠偏 + finalization 等待死锁

- 任务 `b4e01ef4-cfc5-4907-ae6c-4af9245630eb`，夹具 `/tmp/orbit-m4-frozen9v7-vuSr/project`，报告 `/tmp/orbit-m4-frozen9v7-result.md`；构建 `0.6.15` digest `8ab11bdd…` installed_at `19:20:48Z`。
- 成员机械路径 OK（19:28:18Z 登记、19:28:29Z hub 回收）；SUT 实现并文档化 `invalid_field_count`，测试 4/4。
- check #1/#2 verdict correct 但分别 stale(host)/stale(artifact)，**零 correction_sent**；check #3/#4 fresh continue 零 finding；`finalization_pending` 19:29:30Z 后 **notice 未送达**——Root 违反 no-poll/no-sleep（起 sleep 250/170 + hub wait 循环），idle 前置未满足；19:37:16Z Controller cleanup stop exit 0 → stopped confirmed=true、async_jobs_settled=true、成员 confirmed，status=paused。
- **cost-gate UX 失败（两次）**：19:27:06Z 与 19:35:26Z Root 提交证据均缺候选 `billing_route` → `model_evidence_mismatch`，门按设计 fail-closed（无 hint），但无字段级提示；另记 JEV 证据请求 vs process_reviewer off-track 归因冲突。
- 当时 #9 尚无通过样本（correction 环零真实送达；finalization 时序第二次缺口，本次根因 Root 等待纪律）。两个 instruction-only 目录（`01df6ac5`/`abd8e670`）为失败启动痕迹，保留待清理。

## 冻结 9 样本 ea2d9fe5（0.6.16）：PARTIAL-A——全链机械环通过，finding 环未触发（非假阴性）

- 任务 `ea2d9fe5-fd18-42ef-aa87-ac61a30487d0`，夹具 `/tmp/orbit-m4-frozen9v8-zVsn/project`（含种子 date|category 去重缺陷），报告 `/tmp/orbit-m4-frozen9v8-result.md`；0.6.16 digest `24de7b7b…` installed_at `19:50:43Z`。
- 成员机械环 OK（19:55:13Z 登记、19:55:26Z hub 回收，root_without_hint）；**Root 在检查前自行修复种子缺陷**（index.js 去重删除、rows 直通，git diff 证实）。
- check #1 19:57:50Z fresh complete 零 finding——**判定正确**（快照已无违规）；同秒 `finalization_notice`（0.6.16 正常投递路径验证；**60s fallback 分支本样本未触发**，定向回归通过）。Root 按 prompt 结束 turn 等待（无 sleep/poll/hub wait）；19:58:11Z `completed_via_finalized_stop`+`stopped`（显式 stop），确认完整（Root+成员），status=complete。
- 0.6.16 新事件 `delegation_cost_unverified`：cost 门 fail-closed 显式可见；显式派发不受阻。
- 用量：check #1 18616 tokens；JEV stage1 20807/444；elapsed 330.5s；成员 13s。
- **不勾冻结 #9**：finding→correction 环依旧零真实样本（本次无 finding 因属主自检修复，非 checker 发现）。#9 唯一剩余环。

## 冻结 9 样本 f8f36109（0.6.16，两段式早检）：PARTIAL-A——早检干净，全链通过

- 任务 `f8f36109-d31f-4a54-b08a-c9d308c3ee1a`，夹具 `/tmp/orbit-m4-frozen9v9-VOYv/project`，报告 `/tmp/orbit-m4-frozen9v9-result.md`。
- 成员 20:10:14Z 登记→20:10:31Z hub 回收；早检 #1 20:11:29→20:12:02Z fresh、findings=[]（reason 逐条核实全部边界，**首稿即满足规格，非漏检**）；`finalization_notice` 20:12:02Z；Root 显式 stop 20:12:20Z，`completed_via_finalized_stop`，确认完整（Root+成员），status=complete；测试 5/5。
- 澄清：verdict `correct` 在本 schema 意为"已核实"（findings 空），非"需纠正"——措辞反转风险建议 schema 文档明示。
- 用量 check #1 33677、elapsed 140.7s、检查 1/3、零 steering。**#9 finding→correction 环仍零真实样本**（连续两轮机械环稳定通过后的唯一缺环）。

## 冻结 9 样本 dfec3e93（0.6.16，包面缺陷候选）：PARTIAL-A——Root 自修 exports 缺陷，finding 环第三次非假阴性零触发

- 任务 `dfec3e93-d424-4ddc-b95e-4f58b294d51d`，夹具 `/tmp/orbit-m4-frozen9v10-xMVm/project`，报告 `/tmp/orbit-m4-frozen9v10-result.md`。初始快照含 `exports→legacy` 桩缺陷；**Root 交付前自修**（package.json 重指 src/index.js，事后探针证实）；成员 20:25:44Z 登记/hub **wait**（无 send）回收；check #1 20:26:52Z fresh complete 零 finding（判定正确，检查的是修复后快照）；`finalization_notice` 20:27:02Z；显式 stop 20:27:27Z，确认完整。**correction_sent=0**。
- 观察：三轮样本中 Root 都在 checker 看到之前自修了其拥有面的缺陷；这不构成必要条件证明，但下一候选（若继续）可考虑把 finding 面放到成员（B）面或两工作面交互缝；**不再继续盲跑**。连续三轮（v8/v9/v10）机械环稳定；#9 的 finding→correction 环后由 staged `0bc4ec93`（0.6.17）闭合，见下节。

## 冻结 3 样本 ec90a0a9（0.6.17，frozen3-r2 两成员异模型 idle-wake）：**PASS**

- 任务 `ec90a0a9-5bed-4e0c-994e-cb131b4388f1`，夹具 `/tmp/orbit-m4-frozen3r2-oJUF/project`（HEAD `6403cce`），报告关键证据见下。
- **idle 前置**：Root 21:18:23Z `hub list` 见 builder idle；sonic 21:18:39Z `hub list` 再确认 builder idle（其 audit 笔记原文记录 "idle → precondition PASSED"）；builder JSONL 证明其遵守 yield 纪律（**0 次 hub wait**，初始 turn 21:18:19 结束）。
- **member→member idle-wake**：21:18:42Z sonic `hub send` `to: builder`、`await:true` → `hub_result` 为 `woken` + builder 回复；builder JSONL 21:18:42Z `irc:incoming`、21:18:43Z 新 assistant 回合（独立 wake turn）、21:18:43Z 反向 `send`（replyTo）、21:18:44Z 再次完成。
- **Orbit 观测（0.6.17 修复生效）**：任务 events 记录**成员源** hub 调用——21:18:42Z send（`agent_id`=sonic、`to`=builder）、21:18:43Z builder reply（`agent_id`=builder），from/to 正确。
- **异模型、无嵌套**：builder `deepseek/deepseek-flash`（events `model` 字段 + JSONL）、sonic `zhipu-coding-plan/glm-5.2`（JSONL `model` 8 处）；全程仅 2 名成员。
- **收尾**：check #1 fresh complete；`finalization_notice`；Root 显式 stop → 21:20:14Z `completed_via_finalized_stop`+`stopped`，stop_confirmation 全员（Root+两成员）；测试 7/7；elapsed 151.7s、check_tokens 25107、零 steering。
- 结论：冻结 #3 全部子项（一层派发、成员间消息、等待、**idle 唤醒**、结果回收）取得真实样本，**#3 判 PASS**。

## 冻结 9 样本 0bc4ec93（0.6.17，staged-delivery）：**PASS——#9 全链首次完整真实样本**

- 任务 `0bc4ec93-3484-45be-a6a2-ae9613d5584b`，夹具 `/tmp/orbit-m4-f9staged-5xgO/project`，报告 `/tmp/orbit-m4-f9staged-result.md`；staged 工作流：M1 核心路径 → **强制中期检查** → M2 全合同加固 → 终检。
- 成员 21:37:09Z 登记（deepseek-flash，独立 B 面）→ 21:37:23Z hub 回收；全程 1 成员、无嵌套、同一 Root 单会话。
- 中期 check #1 21:38:25Z `stale=false` verdict `correct`、finding **F1**（parse.js:14 缺 `invalid_field_count`，行级证据）→ **同秒 `correction_sent`**（id `553aca1f`）。
- 同一 Root 修复（diff 3 文件 +114）；终检 check #2 `complete`、**`resolved_ids=['F1']`**、指纹一致只读。
- 21:40:37Z notice → 21:40:59Z `completed_via_finalized_stop`+`stopped`（显式 stop），Root+成员确认全 true/idle；测试 5/5；check_tokens 52133、elapsed 293.8s、零 steering。
- 注：前置错误 cwd 的 p3G 启动已作废隔离、未建任务、不计入。

## 冻结 5 费用门 live 样本（0.6.18，subscription_quota typed 路由）：观察事实与保守判定

- 任务 `249935cc-0688-4829-ba1e-fef4af1831bd`（夹具 `/tmp/orbit-m4-jev-iuQn/project`，报告 `/tmp/orbit-m4-jev-live-result.md`；Pi 审计 `/tmp/orbit-m4-jev-audit-pi.md`）。
- **观察到的真实行为**：21:58:27Z stage1 0.92 → `model_evidence_needed`（候选 typed `subscription_quota`；旧无路由缓存条目不匹配、未复用）→ Root 自取证 → 22:01:51Z submitted/used → **缓存新增 typed 条目**（billing_route=subscription_quota，metrics 全 `quota.*`+来源，valid 7d）→ stage2 `member_fit=0.54 / parallel_gain=0.30 / cost_appropriate=0.57 → declined`，**无持久 hint**；两成员派发均 `root_without_hint`；check #2 为 **adjudicator**（#6 活回路事实）；收尾 complete+显式 stop 确认完整。
- **夹具矛盾（不作产品验收依据）**：fixture 测试硬编码 W38 vs 显式 ISO 要求（真值 W39），Root 改写 README 口径后 F1 被解决——根因一半是夹具设计缺陷，不构成干净的 reviewer 假阴性结论。JEV 路由链证据不依赖周口径、依然有效。
- **路由分类（0.6.18 已修正，Pi 代码评审 PASS `/tmp/orbit-m4-jev-code-review-pi.md`）**：`direct_api` 已排除 `pi-native` transport，DeepSeek 判定核对方 HTTPS endpoint 的 host；`subscription_quota`（Zhipu/Kimi 等）核对方 HTTPS endpoint 的 host 且路径含 coding 前缀，不再由品牌名推断——Pi 先前指出的两处为 0.6.18 之前的问题。
- **保守判定（按冻结原文三句，非后加 hint 门槛）**：① 候选分≠建议——负向真实证据成立；② 仅持久 hint 可称建议——负向证据成立（全部显式派发 root_without_hint）；③ 纠偏按证据版本收敛——**过期半句有真实证据**（rebind3/L1 stale finding 不送达），**同版本重复抑制分支（finding_repeat_ignored）无真实事件**；Pi 论证该分支在活回路结构性难触发（纠正同刻唤醒 Root→二次检查必过期；检查者只要求复用 id 不要求逐字复刻 requirement/evidence/action）。该分支**记为结构性未触发、不再排期**（确定性回归覆盖），不写成已观察、也不作为可执行闭合条件。
- 结论：**冻结 #5 判 PASS——用户批准的组合证据**（2026-09-25）。证据构成：同版本重复纠正由确定性回归证明；真实任务证明一次纠偏收敛与过期结论拦截——rebind3 `2e27fce9` stale finding 不送达+一次 correction_sent 后 resolved、K3 `35c06d44`、L1 `42d1977e`、staged `0bc4ec93`；0.6.18 subscription_quota typed 全链 declined 留证 `249935cc`；JEV 两禁止句有真实负向证据，费用门 fail-closed 与纠偏收敛/过期拦截均有真实证据。**限制（保留）**：`finding_repeat_ignored` 未在真实任务触发——该分支结构性未触发、不再排期，仅确定性回归覆盖；hint 正样本为后加跟踪项，不是冻结原文通过条件。旧冻结'全部以真实运行证据'对 #5 此项经用户明确批准例外。

## 冻结验收 1–9 证据矩阵（2026-09-25 终态：#1–#9 全部通过）

| # | 项 | 判定 | 关键证据 | 最小真实缺口 |
| --- | --- | --- | --- | --- |
| 1 | 入口（orbit omp 参数/退出码/恢复/权限审批；普通 omp 被动） | **PASS（本机）** | help=launch 级一致；非法 model/profile/approval/resume 失败退出码一致；隔离 profile TUI 与 `--resume` 成功面（`/tmp/orbit-m4-entry-install-negatives.md`）；普通 omp `/tools` 无 Orbit（E/H）；**交互审批 parity**（`/tmp/orbit-m4-permission-approval-result.md`）；受控入口用户扩展同载（`orbit omp -e probe-ext.mjs` 同载 `xd://orbit`+`xd://probe_ping`，`/tmp/orbit-m4-other-extension-result.md`） | 无（未来新 OMP 版本参数复核随 ADR-008 决定 7 流程，非缺口） |
| 2 | 成员登记先于模型工作（含写失败失败关闭） | **PASS** | 登记门正向样本多轮（`4d41ba19`/`b9e87009`/`df4cf490`/`ea2d9fe5`/`dfec3e93`）；M0.1/M0.2 负向真实证据 | 无（登记时序毫秒级证明依赖 JSONL，已在 YSON 轮取得） |
| 3 | 一层派发与原生通信 | **PASS** | 单/多成员派发与 hub 结果回收多轮；**member→member idle-wake 真实样本**（frozen3-r2 `ec90a0a9`：idle 前置双确认、sonic send await:true→builder 独立 wake turn+reply、Orbit events 记录成员源调用、DeepSeek/GLM 异模型、无嵌套）；一层 enforcement 已接 | 无 |
| 4 | 用户修改送达 Root 与活动成员 | **PASS** | `4d41ba19`：CLI amend→`explicit_text`→`custom_message(orbit)`→成员执行 assistant，毫秒因果链 | 无（amis_window 时序对快成员的窗口问题已由 watcher 方案与 v6+ 规格规避） |
| 5 | JEV 与纠偏 | **PASS（用户批准的组合证据）** | 禁止句负向真实证据；费用门 fail-closed 两轮 + 0.6.18 subscription_quota typed 全链 declined；纠偏收敛与过期拦截真实样本（rebind3/L1/K3/#9 staged）；同版本重复纠正由确定性回归证明 | `finding_repeat_ignored` 未在真实任务触发（结构性未触发、不再排期）；hint 正样本为后加跟踪项；旧'全真实证据'冻结头句对 #5 此项经用户批准例外 |
| 6 | 独立检查（只读固定快照/来源/边界） | **PASS** | 多条固定快照 reviewer 样本；confinement 专项 17/17；**活 TaskRuntime adjudicator 机械回路真实闭合**（live 样本 `249935cc` check #2：role=adjudicator、trigger_cause=manual_dispute、`ok=true`、model kimi-for-coding、active_tools=[glob,grep,read]、`read_tool_is_confined=true`、`forbidden_tools_present=[]`、fingerprint before==after=`a6c0382a…`、stale=false）；组件级 adjudicator smoke 与 confinement 专项保留 | 无（机械/只读/路由回路已验；adjudicator 裁定**内容**是否满足含 ISO 周口径的原合同未在本夹具验证——该夹具存在 W38/W39 规格矛盾，内容正确性另行验证） |
| 7 | 实际停止（Root+成员+后台工作+异常重试） | **PASS** | N4/P1 停止确认；`aa82d66e`（无成员异常重试）；`c8d89ea6`（有成员在途）；**B3 `122167ec`（构建 P：owner-scoped async job 实退、SIGKILL 后重试）**；orphan 离线 stop 诚实判负 | B（成员工作中中断）未跑，TTL=0 下非阻塞 |
| 8 | 安装切换（单宿主/更新失败保留/活租约拒绝） | **PASS（本机）** | 隔离前缀负样本（拒绝卸载 exit 1 保留完整、update 失败保留旧版）；update 成功路径由 0.6.14→0.6.16 多次 exit 0 证明；旧全局扩展 absent | 无（未来新构建 update 只作门禁运行） |
| 9 | 目标路径端到端（成员+finding+修复+complete） | **PASS** | staged 样本 `0bc4ec93`（0.6.17）：成员独立 B 面+hub 回收；中期检查 fresh finding F1（行级证据）→ `correction_sent` → 同一 Root 修复 → 终检 `resolved_ids=['F1']` → `completed_via_finalized_stop`+显式 stop，确认完整 | 无 |

## 冻结 1 权限审批 parity（0.6.16）：PASS

- 证据 `/tmp/orbit-m4-permission-approval-result.md`：四会话 TUI 实测（orbit/plain × deny/approve），`--approval-mode always-ask` + deepseek-flash；`Allow tool: write` 对话框渲染、键位（up/down/enter/esc，以屏显为准）两侧一致；deny→`gate.txt` 缺席、approve→存在且内容正确，均一致；pane 全关、进程 0。未用超时推断；未建 Orbit 任务。
- 冻结 #1 本机部分闭合；仅剩未来新 OMP 版本参数复核（ADR-008 决定 7 流程，非缺口）。

## 待跑场景

- 小任务负样本：N1、N2、N3 为失败样本；N4（D）观察到一次"不派发 + 独立检查通过 + complete + 停止确认"正样本。N 系列本身没有覆盖纠偏送达。
- inbox 命令容忍（畸形/缺 `type` 非致命、`command_rejected` 记录）：确定性修复已随构建 D 安装；真实样本复验未做（N4 未触发该路径）。
- 纠偏投递（finding 送达 Root 并完成修复与复核）：构建 I 的 rebind3 与构建 K 的 K3 已覆盖无成员路径；构建 L 的 L1 为 stale finding 自动复核 resolved、**无 `correction_sent`**，不覆盖纠偏送达；N2 的 send 超时和 N1 未到该步骤仍保留，不把它们改写成通过。
- 双工作面正样本：P1 为**中断/部分样本**（构建 D）；P2 为构建 E 的双工作面样本，**未通过**（无 hint、无成员、终态 `paused`）；P3（F）为双工作面、Root 独做，只证明无成员时的检查与 `complete`；构建 L 的 L1 为跨模型候选、stage2 declined（.28/.21）、无成员。**原生成员机械路径（登记先于模型工作、hub 结果回收、停止确认）已由 `4d41ba19`（构建 M）、`b9e87009`（构建 O）、`df4cf490`（构建 P）证明**；`df4cf490` 的 Root JSONL 显示 A 在派发前完成、成员 9s 工作窗内 Root 无并行活动，**并行收益未证实**（与 stage2 parallel_gain 低分一致）。**仍缺**：JEV hint 正样本（全部显式派发、root_without_hint）与同任务"finding→correction_sent→同 Root 修复→resolved"链（`df4cf490` 暴露 reviewer 假阴性，见上）。
- 停止终态：**冻结 7 在构建 P 判通过**——（A）`aa82d66e`（构建 I）无成员时 runtime SIGKILL 后显式 `orbit stop` 重试成功；**（B3）`122167ec`（构建 P，报告 `/tmp/orbit-m4-build-p-stop7-b3-result.md`）有成员 completed + owner-scoped async job（`sleep 600`，PID 16344）在途时，仅 SIGKILL runtime（15016，构建 P release、lsof 锁任务目录，与 host 8762/job 16344 互异核对），一次 `orbit stop` exit 0 → 18:39:32Z `stopped`，Root 与成员 stop_confirmation 均 confirmed=true，**async job 实退**，host 未动。B3 限制：events 无 `retry_stop` 命名事件（按行为确认）、终态 `runtime_pid=15016` 保留（SIGKILL 不跑 ensure）、`finished_at=null`。（B）有成员**正在工作**时的中断重试（`c8d89ea6` 为在途停止确认、非工作时）未跑，不阻塞——当前安装 Orbit TTL=0，冻结 7 不要求 parked 语义；parked 成员采样自阻断移除。P2（E）确认完整但 `state.status=paused` 为该样本终态；P3（F）/L1/`b9e87009`/`df4cf490` 已复验正常 `complete` 收尾路径与延迟通知。
- 证据/使用指导：P2 显示 Root 需先查源码才提交模型证据（格式问题）；空任务目录 `0d647029-…` 待查。
- 独立 OMP 检查来源与快照指纹：N4 与 P3 有 `complete` 无 finding 样本（P3 含只读工具受限与前后指纹一致）。带 finding 的纠偏路径已由构建 I 的 rebind3 与构建 K 的 K3 跑过，两者都不是成员正样本；构建 L 的 L1 也跑过（#2 stale finding → #3 新快照 resolved，无 `correction_sent`，指纹一致），同样不是成员正样本。
- worktree rebind 与带 finding 纠偏：构建 I 的 rebind3 已通过完整路径；H 的 p2B 不计拓扑，p2C 仍只是局部证据。无成员异常退出重试已由 `aa82d66e` 通过。member-audit 与构建 J 的 member-v2 均未形成成员正样本；v2 终态仍是 `failed`，不计 complete，也不宣称 checker 通过。构建 K 的 K3 只证明无成员 finding 纠偏收敛；同构建的 GLM 对照（`9d8af567`）与英文对照（`e07af778`）都是同为 `glm-5.2` 且 stage2 declined。三者都不算 JEV hint 正样本；英文样本不认定语言是原因。构建 K 的 `61bbd66d` 是显式派发的原生成员机械路径正样本，不是 JEV hint 正样本。`c8d89ea6` 只证明有成员在途时的异常停止重试，不计完成。
- 当前安装为 **0.6.18**（digest `06dba0f1…`，installed_at `2026-09-24T21:55:54Z`）。真实样本：`df4cf490`（P，假阴性 FAIL）、`b4e01ef4`（0.6.15，finalization 死锁 FAIL，Root 等待纪律）、`ea2d9fe5`（0.6.16，**PARTIAL-A**：全链机械环通过，finalization 为正常投递路径、60s fallback 未触发（定向回归通过），finding 环未触发非假阴性）。**冻结 #9 已 PASS**（staged `0bc4ec93` 同一任务全链真实通过）；JEV hint 正样本同缺。构建 N/O 的复验与失败记录保留；剩余缺口归口：② 进程存活时 CLI stop 可消费性（待验证）、③ orphan PID 收尾（O 判负保留）；未列项保持 pending；每项以独立任务的真实记录判定。（该声明为当时语境；M4 已于 2026-09-25 整体闭合，见矩阵与本记录末节。）

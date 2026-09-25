# Orbit 单一 OMP 改版总 TODO

状态：**唯一整项改版总 TODO**（2026-09-24 建立，持续更新）。[ADR-008](../adr/008-omp-native-collaboration-base.md) 已采纳；`orbit omp`、原生 `task/hub` 接线、独立 OMP 检查组件、单宿主安装与旧路径清理已进入实现和回归阶段。本机已执行一次安装切换（当前 0.6.18）；**冻结 #9 目标路径端到端已通过**（0.6.17 staged `0bc4ec93`），M4 整体闭合：冻结 #1–#9 全部取得判定（#5 为用户批准的组合证据 PASS，例外与限制见阻断 2；#6 机械回路 PASS、矛盾夹具内容不计）。路径原型与早期证据见[路径验证票](omp-native-path-probe.md)和[验证记录](../reference/omp-native-path-probe-20260924.md)。本文件是这次改版唯一的执行队列；完成后已完成项退出待办，并把结论归入相应正文。

## 用户目标

1. **唯一宿主。** 下一版只支持原版 OMP 加 Orbit 扩展；Root 使用 OMP 原生 `task/hub` 组建一层执行团队，Orbit 不再以自己的 SDK 成员替代原生团队。
2. **显式入口。** `orbit omp` 为受控入口，保留 OMP 原生参数、恢复、profile、权限与其他扩展；普通 `omp` 不接入 Orbit。
3. **检查独立。** 独立检查者使用另一 OMP 只读会话读取固定快照；裁定者同样不参与执行团队；执行成员与检查者的模型由 OMP 配置与可用模型决定，Orbit 记录实际使用值。
4. **停止可信。** 报告完成或停止成功前，确认本任务派出的全部成员及其原生后台工作实际结束；证据不足保留 `stop_unconfirmed`，异常退出后可显式重试收尾。
5. **安装与版本。** 现有安装安全切换到显式入口并清除旧全局扩展；固定已验证的 OMP 版本范围，更新上游前先核对扩展钩子、`task/hub`、模型解析与停止路径并跑通隔离验收。
6. **旧路径移除。** 移除 Codex、OpenCode 等旧宿主路径，不建设兼容层或历史任务迁移（ADR-008 决定 1）。
7. **文档同步。** 代码与真实验收完成后同步更新合同、ADR 状态、skill 与使用文档；不提前改写运行事实。

## 非目标

- 旧宿主（Codex、OpenCode）的运行能力、旧安装参数兼容层与双轨运行。
- 历史任务迁移、旧任务记录兼容与旧会话热接入。
- Zeen 或其他外部项目的专用规则与外部编排器识别。
- 其他宿主（pi、Kimi、Grok、Cursor Agent 等）接入与跨宿主成员。
- Fork OMP 或复制 `task/hub` 模块；仅在扩展接口被证明不足时按 ADR-008 单独评估。
- 使用旧 Orbit 产品 skill（`skills/orbit/`）执行或验收本次改版；M4 使用独立的 `.agents/skills/orbit-real-acceptance`，须先切到目标路径。

## 冻结的可观察验收

全部以真实运行证据判定；确定性测试只验证接线与版本约束，不代替真实模型与控制验证。**经用户明确批准的例外（2026-09-25）：冻结 #5 的同版本重复纠正分支以确定性回归证明、其余以真实任务证据闭合（详见'当前阻断'第 2 条）。**

1. **入口。** 普通 `omp` 看不到 Orbit 工具；`orbit omp` 启动后 Root 可 `context` 绑定当前会话；原生 `--resume`、`--model`、profile、权限参数与退出码和普通 OMP 一致；其他扩展照常加载。
2. **成员登记（原生成员接线首关）。** 每个原生执行成员的真实 ID 在其首个模型工作前写入 TaskStore；写入失败或分配 ID 与预期漂移时，成员不发生模型工作（失败关闭），并有真实负向证据。
3. **一层派发与原生通信。** 仅 Root 能派发；成员无 `task` 能力、不能启动 Orbit；成员间消息、等待、唤醒与结果回收经原生 `hub` 完成。
4. **用户修改。** 用户明确修改送达 Root 与相关活动成员，不混入内部纠正或成员回报；结果回原 Root 并由 Root 核验集成。
5. **JEV 与纠偏。** 候选分不等于最终建议；只有持久 `delegation_hint` 才可称 Orbit 建议；纠正按 finding 证据版本去重收敛，过期结论不冒充当前版本。
6. **独立检查。** 独立 OMP reviewer 只读固定快照，越界读取被拒绝；adjudicator 独立于执行团队；检查前后快照指纹一致。
7. **实际停止。** 停止确认覆盖 Root、本任务全部登记成员及其原生后台工作，实际进程退出为证据；不足时保留 `stop_unconfirmed`；运行进程异常退出后显式 `stop` 可重试收尾。
8. **安装切换。** 现有安装切换后不再被动加载 Orbit 扩展；`install`/`update`/`uninstall`/`doctor` 只管理单宿主安装；更新失败保留旧版；卸载拒绝在有存活租约时保留完整安装。
9. **目标路径端到端。** 隔离项目中用户提出真实要求 → Root 自主接入 → 原生成员完成一个独立工作面并集成 → 独立 OMP 检查发现遗漏 → 同一 Root 修正 → `complete`；原生中断或退出后相关执行与后台工作实退、上下文保留。

## 切片与依赖顺序

主线不是全串行：M0.1／M0.2 是原生成员正式接线的首关，只阻塞 M1.1／M1.2 的成员部分与合同改写；独立 reviewer（M0.3／M0.4、M1.4）、`orbit omp` 入口与安装（M2，M2.2 依赖 M2.1 可运行）等依赖就绪即可并行推进。每个切片的最小单位是一个完整行为，有一个主要执行者；独立核查与验收不参与该行为的实现。

### M0 首关（只阻塞原生成员正式接线）

| ID | 切片 | 状态 | 完成证据 |
| --- | --- | --- | --- |
| M0.1 | 真实成员 ID 在模型工作前写入 TaskStore；写失败或 ID 漂移时失败关闭 | 正式登记门已接；实际 OMP 成员登记正向与写失败负向样本已取得；冻结验收 2 PASS（正向多轮 + 写失败负向），完整目标路径已由 M4 矩阵闭合；登记时序毫秒级证明依赖 JSONL（YSON 轮已取得） | 冻结验收 2 的正向与负向真实证据 |
| M0.2 | 钩子层 enforcement 或等价可验证接缝；`devin-agent` 类不触发钩子的模型拒收或等价处理 | 原生 `task` 调用门及 registry 登记回调已接；缺失钩子时拒绝派发，写失败时真实阻断成员模型工作；后续升级仍需复核钩子 | 请求未出站或等价阻断的真实证据 |
| M0.3 | 原生停止证据：成员 job 与真实进程退出；`hub cancel` 回执不代替退出证据 | 正式停止桥已接：N4（单独 Root）与 P1（Root＋原生成员）均返回 `confirmed=true`、`active_tools_after=0`、`async_jobs_settled=true`；P2（构建 E）停止确认完整但该样本 `state.status=paused`，不是当前完成路径缺口；P3（构建 F）与构建 L 的 L1 已复验 `state.status=complete` 与 `completed_via_finalized_stop`；构建 I 的 `aa82d66e` 通过无成员崩溃后显式 `stop` 重试；构建 K 的 `c8d89ea6` 通过有成员在途时的异常 runtime 显式 `stop` 重试与确认，不计完成；冻结验收 7 PASS（B「成员工作中中断」未跑，当前 TTL=0 下非阻断；parked 成员退出不可证实，桥保持 `stop_unconfirmed`，非完成路径缺口） | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；冻结验收 7 PASS（B 未跑非阻断） |
| M0.4 | 独立进程 OMP reviewer 会话的正式打包、只读工具边界与版本固定（方案已采纳：另一独立 OMP 会话） | 打包与版本固定已完成；独立 reviewer 会话已在目标路径真实运行（N4：由 TaskRuntime 调度，固定快照，指纹 before=after `86f6d04c…`，verdict `complete`）；无成员 finding 送达已由 rebind3 与 K3 跑过；L1 的 stale finding 经复核 resolved，但无 `correction_sent`，不算送达。**组件级 adjudicator 与只读逃逸专项已跑过**：adjudicator smoke（构建 P，独立进程组裁定、confined、指纹不变，证据 `/tmp/orbit-m4-adjudicator-smoke.md`）与 confinement 专项 17/17；活 TaskRuntime adjudicator 机械回路已真实闭合（`249935cc` check #2：manual_dispute、confined、指纹不变 a6c0382a…、stale=false；裁定内容对 ISO 原合同的正确性因夹具 W38/W39 矛盾另行验证） | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；[验证记录补记](../reference/omp-native-path-probe-20260924.md)；冻结验收 6 PASS（机械/只读/路由回路已闭合；裁定内容因 W38/W39 夹具矛盾另行验证） |

对照 [ADR-008](../adr/008-omp-native-collaboration-base.md) 的实现前事实缺口：第 1 条归 M0.1；第 2 条的成员再次派发与全量观察原型已取得、正式实现归 M1.1，`hub cancel` 不能代替退出证据归 M0.3；第 4 条的只读边界归 M0.4，固定快照检查与裁定路径归 M1.4。第 3 条的入口隔离归 M2.1／M2.2。

### M1 核心接线

| ID | 切片 | 状态 | 完成证据 |
| --- | --- | --- | --- |
| M1.1 | 扩展观察并登记原生 `task` 成员、`hub` 流量、实际模型、结果与后台工作；一层派发限制 | 正式代码与定向回归已接；冻结验收 2、3 PASS（成员登记多轮正样本；成员→成员 idle-wake `ec90a0a9`；成员源 hub 调用记录自 0.6.17） | 冻结验收 2、3 PASS |
| M1.2 | TaskRuntime 接入原生成员：登记、结果回收、用户修改送达、统一停止 | 正式代码与定向回归已接；冻结验收 4、7 PASS（`4d41ba19` amendment→成员执行；停止路径 A/B3 含 owner-scoped async job 实退；B「成员工作中中断」未跑，TTL=0 非阻断） | 冻结验收 4、7 PASS |
| M1.3 | JEV／纠偏／状态记录保持：两阶段提示、finding 与 stale、observation 去重、待核对线索 | 正式代码与既有回归已接；冻结验收 5 经用户批准的组合证据闭合（M4 整体闭合）；保留边界：`finding_repeat_ignored` 未真实触发（确定性回归覆盖），hint 正样本为后加跟踪项 | 冻结验收 5（组合证据批准，边界见验收记录） |
| M1.4 | 独立 OMP reviewer 与 adjudicator 接入 Orbit 调度 | 组件与正式调度均已接：N4 由 TaskRuntime 调度独立 OMP reviewer（固定快照、`complete`、无 finding）；P2（构建 E）自动检查 #1 因 artifact stale 不计当前 finding，手动终检 #2 无 findings、resolved CHK-001..004 并发 `finalization_notice`；P3（构建 F）手动终检基于固定快照、只读工具受限（glob/grep/read）、无 findings、前后指纹一致（check 35873 tokens）；无成员 finding 送达已由 rebind3 与 K3 跑过；L1 不是送达。**adjudicator 组件级已验**（构建 P smoke：独立进程组、保留争议上下文、裁定带行号证据，证据 `/tmp/orbit-m4-adjudicator-smoke.md`），confinement 专项 17/17；活 TaskRuntime 争议路由/裁定只读机械回路已真实闭合（同上）；adjudicator 裁定内容的合同符合性另行验证 | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)、组件证据 `/tmp/orbit-m04-real-xu17Jy`；冻结验收 6 PASS（活回路机械/只读/路由已闭合；裁定内容 W38/W39 矛盾另行验证） |
| M1.5 | 停止确认与异常重试：Root、成员、后台工作、运行进程崩溃后的显式 `stop` | N4/P1 的停止确认已取得；P2（E）确认完整但该样本终态 `paused`；P3（F）与构建 L 的 L1 停止确认完整且终态 `complete`（`completed_via_finalized_stop`）；构建 I 的 `aa82d66e` 通过无成员异常退出后的显式 `stop` 重试；构建 K 的 `c8d89ea6` 通过有成员在途时的异常 runtime 显式 `stop` 重试与确认，不计完成；冻结验收 7 PASS（B「成员工作中中断」未跑，TTL=0 非阻断；parked 成员退出不可证实，`stop_unconfirmed` 边界保留） | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；冻结验收 7 PASS（B 未跑非阻断） |

### M2 入口与安装

| ID | 切片 | 状态 | 完成证据 |
| --- | --- | --- | --- |
| M2.1 | `orbit omp` 正式入口：帮助与原生帮助透传、参数与退出码保留、会话租约 | 0.6.13–0.6.16 已在构建 D 至 0.6.16 的真实 `orbit omp` 会话中使用。冻结验收 1 的无模型面已验：help 透传（launch 级一致）、非法 `--model`/`--profile`/`--approval-mode`/`--resume` 失败退出码与原版 OMP 一致、隔离 profile 的 TUI 启动/退出与 `--resume` 成功面（证据 `/tmp/orbit-m4-entry-install-negatives.md`）；权限参数在真实工具审批中的行为与 profile 成功路径已验（交互审批 parity `/tmp/orbit-m4-permission-approval-result.md`；profile 成功面 `/tmp/orbit-m4-entry-install-negatives.md`） | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；冻结验收 1 的本机部分 |
| M2.2 | 普通 `omp` 不接入：安装不再写全局扩展入口；现有安装安全切换并清除旧全局扩展 | 本机切换与 owned 旧全局扩展清理已完成；构建 E 的普通 `omp` 已在 pane `w1B:p23` 实测 `/tools` 无 Orbit 工具（证据 `/tmp/orbit-m4-e-plain-tools-pane.txt`） | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；冻结验收 1、8 本机 PASS |
| M2.3 | `install`／`update`／`uninstall`／`doctor` 单宿主化与安装记录切换（只做安全切换，不建旧参数兼容层） | 当前安装是 0.6.18（digest `06dba0f1…`，installed_at `2026-09-24T21:55:54Z`；历史构建见验收记录）。构建 H 的 Ruby 钉住已修复 G 的默认 PATH 阻断，并经 `/` 复核；更新失败保留旧版、有存活租约时拒绝卸载已在隔离前缀取得无模型负样本（exit 1 且保留完整安装，证据 `/tmp/orbit-m4-entry-install-negatives.md`）；**update 成功路径已被证明**（构建 P 即由 `orbit update` exit 0 安装，digest `dcf89b00…`，installed_at `18:06:22Z`），未来新构建 update 只作门禁 | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；冻结验收 8 的本机部分 |
| M2.4 | 上游 OMP 版本固定与更新验证流程 | 版本固定已完成：`orbit omp` 对非 `18.2.8` 拒绝启动，SDK 精确 pin 18.2.8 并在 stage 校验，隔离安装通过；新版本升级验证流程未执行（无经验证的新版本，按 ADR-008 决定 7 复核接口并隔离实跑后再改 pin） | [验证记录补记](../reference/omp-native-path-probe-20260924.md)；ADR-008 决定 7 的流程尚无新版本可验 |

### M3 旧路径移除与文档

| ID | 切片 | 状态 | 完成证据 |
| --- | --- | --- | --- |
| M3.1 | 移除 Codex／OpenCode 代码、脚本、测试、依赖与资产（含 MCP、TUI 代理、OpenCode 插件，以及被原生 `task` 取代的旧 `tests/omp_test.mjs`） | 移除完成：旧宿主代码/脚本/测试/依赖与旧产品 skill 已删（含 `codex_connection.rb`/`codex_member_host.rb`）；构建 L 门禁为 `npm pack --dry-run` 42 文件且无旧宿主资产，`npm test` 39 PASS | 相关回归 + 打包清单 |
| M3.2 | 合同、ADR-007 状态、skill、README 与使用文档同步（ADR-008 要求验收后替换运行事实） | 仓库与安装器旧 skill 文案已清、本机旧 skill 已可逆备份撤下；合同/ADR 已按 OMP 单宿主改写（OMP 负责），验收记录已建并追加 N1–N4/P1；README/usage/debt 收口已完成 | 文档链接与口径检查通过 |
| M3.3 | 版本号与安装记录同步（本次源码 0.7.0 minor；安装仍为验收用 0.6.18） | 源码 0.7.0（2026-09-25 升 minor，未安装、尚未做 0.7.0 真实任务验收）；当前安装仍是 0.6.18 digest `06dba0f1…`（installed_at `2026-09-24T21:55:54Z`）——版本文字与安装暂不一致，如实记录，不把安装切换写成版本号变更 | `check-version.rb` 与版本文字一致 |

### M4 真实验收

| ID | 切片 | 状态 | 完成证据 |
| --- | --- | --- | --- |
| M4.1 | 独立验收 skill（`.agents/skills/orbit-real-acceptance`，非旧 Orbit 产品 skill）从 `orbit codex` 切换到 `orbit omp` | **已完成**（2026-09-24）：启动入口、观测对象与证据口径改为 `orbit omp`、原生 task/hub 一层成员、独立 OMP 只读检查、JEV／纠偏／结果回收／实际停止；验收本身未执行 | skill 与 reference 指向受控入口；保留隔离项目、Herdr 新会话、已安装版与真实模型纪律 |
| M4.2 | 隔离项目目标路径端到端 | **已完成**（冻结 #9 PASS，M4 整体闭合）：N4（D）一次通过；P1（D）被中断；P2（E）双工作面**未通过**（无 hint、无成员、终态 `paused`）；P3（F）单 Root 检查 + 正常 `complete` 通过（无成员、无纠偏）；H 双工作面样本被 Controller 因真实产品矛盾主动 Esc 中断（两阶段 JEV 均 declined、三次检查在途、停止确认真实，终态 `paused`，不算完成）；H 单 Root 样本（自检 + 独立无 finding 终检 + 正常 `complete`）通过，但不证明纠偏投递；H 双工作面 dual2（stage2 declined、无成员无检查）被 Controller 主动 Esc 中断；H p2B 未建任务，不计拓扑；H p2C 仍只是局部证据；构建 I 的 rebind3 通过完整 rebind、finding 送达、Root 修复、复核与正常 `complete`；`aa82d66e` 只通过无成员异常退出后的显式 `stop` 重试；member-audit（`f3763481`）与构建 J 的 member-v2（`f7e31c75`，终态仍 `failed`）都不证明成员正样本；构建 K 的 K3（`35c06d44`）只证明无成员 finding 纠偏收敛；GLM 中文对照（`9d8af567`）与英文对照（`e07af778`）都是同为 `glm-5.2` 且 stage2 declined，不算成员正样本，也不认定语言是原因；构建 K 的 `61bbd66d` 是显式派发的原生成员机械路径正样本（stage2 declined、`basis=root_without_hint`），不是 JEV hint 正样本，也未覆盖成员异常重试；`c8d89ea6` 只证明有成员在途时的异常停止确认，不计完成。构建 L 的 L1（`42d1977e`）无 hint、无成员，stage2 declined（0.28/0.21）；stale finding `F1-readme-run-examples` 由检查 #2 到 #3 自动复核并 resolved，事件中无 `correction_sent`，不是纠偏送达；终态 `complete`。构建 M 的 `4d41ba19` 是一名 DeepSeek 成员的显式派发：活动窗口收到 amendment，hub 有 send，检查 #2 无 finding，无 `correction_sent`，`complete`。`9238dc06` 是 amend 晚到且检查 JSON 解析失败，终态 `failed`。二者都无 `delegation_hint`。构建 M 的单链样本 `5ec69b23`（one-chain）成员路径 OK（1 名跨模型成员、登记先于模型工作、hub 回收），但 checker 两次 fresh complete 无 finding（`correction_sent`=0）；且终态由 TaskRuntime 旧 complete 分支（`lib/orbit/task_runtime.rb:1640-1663`）在 fresh complete 时自动写 `state=complete`+`stop_confirmation`，**无 `finalization_notice`/`completed_via_finalized_stop`/`stopped` 事件、Root 未显式 stop**，合同收尾语义 FAIL（违 `contracts/task-runtime.md:50,71`、`docs/adr/007-task-runtime-refactor.md:133`），已交 Pi 修复；修复已写入并安装为构建 N（digest `3b15a5f7…`，release `f947b6b9…`，installed_at `2026-09-24T16:55:01Z`）。**N 复验已有结果（postfix one-chain `66d7fa45`）：FAIL 未消除**——check #1 fresh complete 后仍无 `finalization_notice`（`finalization_notices={}`、`next_check_trigger=checker_interval`；自动 check #2 被 `automatic_check_complete_ignored`，自动重检也不通知 Root），Root 等待通知无法显式 stop；收尾实况：空闲 Root 下 Esc 无效；Controller 在指示 `/exit` 前误关 pane（进程实退），`orbit stop` 三次仅 queued（inbox 3 条无人消费），**任务记录终态 `status=running`、`runtime_pid=None`、`stop_confirmation=None`（确认不足，但未进入 `stop_unconfirmed` 状态）**，进程全退但属 Controller 清理、非 Root 完成。剩余缺口归口：① `finalization_notice` timing——Pi 已实现并随构建 O 安装，构建 N 实测仍缺，O 待新真实任务复验；② 进程存活时 CLI stop 可消费性——待验证（Esc 未触发已实记）；③ orphan PID 收尾——OpenCode 已实现并随构建 O 安装，O 上对 `66d7fa45` 唯一一次离线 stop 得 `stop_unconfirmed`（exit 1，成员桥 socket 缺失、无 confirmed），如实判负，不计冻结 7 全过。JEV hint 正样本与冻结 9 仍 pending。构建 O 单链样本 `b9e87009`：**PARTIAL-A**——成员路径 OK（1 名 DeepSeek 成员、登记先于模型工作、hub 回收；派发前 stage2 17:28:59Z 0.22/0.29 declined，root_without_hint 非 hint）；check #1 fresh complete 无 finding、`correction_sent`=0（不勾冻结 9）；**同 check/version 的 `finalization_pending`→`finalization_notice` 时序分支与 Root 显式 stop 收尾（`completed_via_finalized_stop`+`stopped`、stop_confirmation 完整）通过**；用量 check #1 62281 tokens（含 cacheRead）、JEV stage1 12827/296、stage2 7806/76、成员 20s、elapsed 229.9s。构建 P（`0.6.14`，digest `dcf89b00…`，installed_at `2026-09-24T18:06:22Z`）冻结 9 样本 `df4cf490`：**FAIL（检查环假阴性）**——成员机械路径 OK（1 名 DeepSeek 成员 18:11:24Z 登记、18:11:33Z hub 回收；派发前 stage2 18:08:27Z 0.21/0.29 declined，root_without_hint 非 hint）；SUT 对"恰好四字段"契约静默接受第五字段（Controller 只读复现，时点在 check #1 后、SUT 停止 18:14:13Z 前，未改文件未 steering），check #1 18:12:47Z `stale=false` complete 未报告 → 无 `correction_sent`，#9 断裂；Root JSONL 显示 A 于 18:08:20/18:10:50 在派发前完成、成员 9s 工作窗内 Root 无并行活动，**并行收益未证实**；收尾路径通过（`finalization_pending`→`notice` 同 version `5e4d04d7…`→ 显式 stop → `completed_via_finalized_stop`+`stopped` 18:14:13Z，确认完整）；用量 check #1 26913、JEV stage1 13682/370、stage2 3482/38、成员 ~9s、elapsed 353.8s。0.6.16 样本 `ea2d9fe5` PARTIAL-A（全链机械环通过、finding 环未触发非假阴性）、`f8f36109` PARTIAL-A（两段式早检 fresh 无 finding、显式 stop 确认完整）——**#9 已于 0.6.17 staged `0bc4ec93` 判 PASS**（finding F1→correction_sent→同 Root 修复→resolved→显式 stop 全链） | [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；冻结验收 9 完成 |
| M4.3 | 本机真实安装切换与旧全局扩展核对 | **本机切换完成，当前 0.6.18**（digest `06dba0f1…`，installed_at `2026-09-24T21:55:54Z`；门禁通过）| [验收记录](../reference/omp-native-m4-acceptance-20260924.md)；冻结验收 1、8 的本机部分 |

**顺序约束：** M0.1 与 M0.2 是原生成员正式接线的首关：未闭合不开始 M1.1／M1.2 的成员部分，也不改写合同。独立 reviewer（M0.3／M0.4、M1.4）、入口与安装（M2，M2.2 依赖 M2.1 可运行）可与 M0 并行推进。M1 成员链路完成前不删除旧宿主代码（旧检查与停止仍在用）；M3.1 在 M2 完成后执行；M4.1 先于 M4.2；合同与 ADR 正文最后更新。可并行条件：依赖就绪、产物独立、文件与运行资源不冲突；同一接缝一次只归一个写者。

## 负责人边界

- 编排与审核：本计划的编排者（Root）只负责编排、审核与集成（含本总 TODO 维护），不亲自实现 M0–M3；下文目标路径语义中的 Root 指受控 OMP 会话内的主执行 Agent。
- 实现与文档：M0–M3 的代码与文档由同 pane 的 OMP／OpenCode／Pi 执行成员承担；按 [开发流程](../agents/development-workflow.md) 分工，一个完整行为一个主要执行者，同一接缝一次只归一个写者。
- 独立核查：非执行该切片的只读会话；高风险或跨模块行为不能由实现者自证通过。
- 检查与裁定：M1.4 起的独立进程 OMP 会话，不参与执行团队，不获得执行成员权限。
- 真实验收：M4 在已授权的 Goal 内执行，不另设再次授权门；验收者不替 Root 调用 Orbit，不中途改 prompt 或阈值充当通过，实现者不自证通过。

## 资源与模型

- 执行成员与检查者模型由 OMP 配置和用户已授权模型决定；Orbit 记录实际 provider/model，不硬编码型号，不把目录可见当账号可用。
- 额度与费用按实际可得记录，未知标未知；不启用未授权供应商，不为探测启动跨宿主成员。
- 真实模型实验只在对应切片进入验收时执行；本轮建立与维护总 TODO 不跑模型实验。

## 真实验收方法

- 使用独立的 `.agents/skills/orbit-real-acceptance`（与旧 Orbit 产品 skill 不同；M4.1 已把口径切到 `orbit omp`、原生 task/hub 一层成员、独立 OMP 只读检查与原生停止），在隔离临时 Git 项目内由 Herdr 启动全新的已安装 `orbit omp` 进程，把完整用户要求交给 Root；不直接替 Root 调用 Orbit，不用旧宿主检查者充当目标路径证据。本次改版不使用旧 Orbit 产品 skill（`skills/orbit/`）执行或验收。
- 每次记录：入口命令、目录、安装摘要与版本、普通 `omp` 不加载 Orbit 的核对、Root 与成员实际身份／模型、原生 `task/hub` 派发与结果回收、独立 OMP 检查者来源与快照指纹、原生后台进程退出证据、检查结果与用量、停止确认、失败与作废样本；失败样本不写成通过。
- 真实安装切换（M4.3）已完成并记录摘要（见[验收记录](../reference/omp-native-m4-acceptance-20260924.md)）：旧全局扩展已清除、`orbit omp` 版本门正常；普通 `omp` 的被动复核在构建 E 与构建 H 完成（`/tools` 无 Orbit）。构建 L 未另跑普通 `omp` 会话，不把 H 的结果写成 L 的新复核。
- 结论分开报告确定性测试、真实安装与真实模型路径分别证明了什么。

## 当前阻断

冻结验收 1–9 仍是原条件，不新增。当前安装是 0.6.18（digest `06dba0f1…`，installed_at `2026-09-24T21:55:54Z`；`df4cf490` 假阴性 FAIL、`b4e01ef4` 死锁 FAIL、`ea2d9fe5`/`f8f36109`/`dfec3e93` PARTIAL-A；#9 已于 0.6.17 staged `0bc4ec93` 判 PASS，见验收记录）。已关闭的旧阻断不再占用本段：G 的默认 PATH Ruby 阻断已在 H 修复；P2 的 `paused` 是该样本终态，后续 P3 与 L1 已有正常 `complete`。

仍缺或只有局部证据：

1. **冻结 9 已 PASS（0.6.17 staged 样本 `0bc4ec93`）。** 单一任务内：原生成员独立工作面+hub 回收 → 中期检查 fresh finding F1（行级证据）→ `correction_sent` → 同一 Root 修复 → 终检 `resolved_ids=['F1']` → `completed_via_finalized_stop`+显式 stop，确认完整（报告 `/tmp/orbit-m4-f9staged-result.md`）。此前失败样本（`df4cf490` 假阴性、`b4e01ef4` 死锁、v8/v9/v10 PARTIAL-A）保留为历史。
2. ~~冻结 5~~ **冻结 5 已 PASS（用户批准组合证据）。** 冻结 #5 判 PASS（用户批准的组合证据：同版本重复纠正由确定性回归证明；真实任务证明一次纠偏收敛与过期结论拦截——rebind3 `2e27fce9` stale finding 不送达+一次 correction_sent 后 resolved、K3 `35c06d44`、L1 `42d1977e`、staged `0bc4ec93`；0.6.18 subscription_quota typed 全链 declined 留证 `249935cc`。**限制**：`finding_repeat_ignored` 未在真实任务触发（Pi 审计论证活回路结构性难触发，不再排期）；hint 正样本为后加跟踪项。旧冻结'全部以真实运行证据'对 #5 此项经用户明确批准例外）。
3. **冻结 4 有一条活动窗口样本。** `4d41ba19` 在 `member_result_recorded` 前有 `member_amendment_sent`，成员会话随后有 assistant 执行 amendment。`9238dc06` 的 amend 晚于完成，不算。这不改变冻结条件，也不等于冻结 9。
4. ~~冻结 3 仍是局部。~~ **冻结 3 已 PASS**（0.6.17 样本 `ec90a0a9`：两成员异模型 member→member send await:true→idle builder 独立 wake turn+reply、Orbit events 记录成员源调用、无嵌套、正常 stop；见验收记录）。
5. **冻结 7 已在构建 P 判通过（不再阻塞）。** 证据：A `aa82d66e`（无成员异常退出显式 `stop` 重试）+ B3 `122167ec`（构建 P：成员 completed + owner-scoped async job 在途，仅 SIGKILL runtime 后经一次 `orbit stop`，Root/成员确认完整、async job 实退；限制：无 `retry_stop` 命名事件、`runtime_pid` 终态保留、`finished_at=null`，见验收记录）。B（成员工作中中断）未跑，不阻塞——TTL=0 下冻结 7 不要求 parked 语义。构建 O 的 orphan 离线 stop（`66d7fa45`）如实判负：`stop_unconfirmed`（exit 1，成员桥 socket 缺失、无 confirmed），不计冻结 7 全过。
6. **冻结 6 已 PASS（机械回路）。** adjudicator 组件 smoke（构建 P，独立进程组、confined、指纹不变，`/tmp/orbit-m4-adjudicator-smoke.md`）与只读逃逸专项 confinement 17/17 已过；**活 TaskRuntime adjudicator 机械回路已真实闭合**（live 样本 `249935cc` check #2：role=adjudicator、trigger_cause=manual_dispute、`ok=true`、model kimi-for-coding、active_tools=[glob,grep,read]、`read_tool_is_confined=true`、`forbidden_tools_present=[]`、fingerprint before==after=`a6c0382a…`、stale=false）。**夹具内容注意**：该夹具存在 W38/W39 ISO 周规格矛盾，adjudicator **裁定内容**对原合同的符合性不作判定、另行验证。固定快照检查已有多条样本。
7. **冻结 1、8 的无模型面已验（证据 `/tmp/orbit-m4-entry-install-negatives.md`）。** 构建 P 上：help 透传（launch 级一致）、非法 `--model`/`--profile`/`--approval-mode`/`--resume` 失败退出码与原版 OMP 一致、隔离 profile 的 TUI 启动/退出、`--resume` 成功面（复用本组隔离会话，零模型调用）；隔离前缀的安装、update 失败保留旧版、活租约拒绝卸载均通过。权限参数真实审批行为已验（0.6.18 交互审批 parity，`/tmp/orbit-m4-permission-approval-result.md`）；普通 `omp` 被动复核停在 E/H（历史证据，未来新 OMP 版本随决定 7 流程重跑）。**update 成功路径已被证明**：构建 P 即由 `orbit update` exit 0 安装（digest `dcf89b00…`，installed_at `18:06:22Z`），此前多个构建同法；未来新构建的 update 只作为门禁运行一次，不再是未决的冻结 8 要求（失败保留旧版、活租约拒绝卸载的事实保留，见验收记录）。

当前状态：M4 已整体闭合（冻结 #1–#9 全部通过；#5 为用户批准的组合证据 PASS）；剩余为上游跟进与文档维护，非阻塞。构建 P 安装前门禁为 `npm test` 与 pack 通过（构建 O 当时为 `npm test` exit 0、`npm pack --dry-run` 42 文件、`git diff --check` 0；构建 N 当时为 `ruby --disable-gems tests/task_runtime_test.rb` PASS）。历史失败样本不计整体通过（当前 M4 已整体闭合：冻结 #1–#9 全部通过，#5 为用户批准的组合证据）。reviewer bundle 单 release 实测约 932MB（含 SDK 与 stage 内 bun cache），磁盘压力确认前不改打包方式。

## 实现选择（Root 按 ADR-008 处理，不作为用户裁决项）

- 独立进程 reviewer 的打包、依赖与版本固定的具体形式（检查者必须独立于执行团队，另一独立 OMP 会话的方案已采纳）。
- doctor／CLI 在 OMP 下识别当前会话的机制，以及 `start`／`delegate`／`model-evidence` 的保留面。
- 执行成员、检查者与裁定者的模型配置来源与默认值（由 OMP 配置与已授权模型决定，Orbit 记录实际值）。
- 上游版本固定的具体范围（按 ADR-008 决定 7 的验证流程执行）。

# Orbit 优化真实验收计划（2026-09-22）

状态：**已运行主链路、小任务与 worktree 路径，并追加严格的 Herdr → `orbit codex` 复验；0.6.12 针对“误读 JEV 最终结论、终检轮询导致 stale、rebind 等待冲突”的复验通过，未覆盖分支仍单列，不把整份矩阵写成全绿**。早期任务位于 `/tmp/orbit-real-acceptance-byaSzI`，0.6.11 严格 Skill 复验位于 `/tmp/orbit-skill-retest-Dm4AwQ`，0.6.12 复验位于 `/tmp/orbit-0.6.12-real-xfUmZe`，均未在 Orbit 仓库自举。

现行语义以 [任务运行合同](../../contracts/task-runtime.md) 为准。实现与确定性回归已经完成；本文件只证明真实路径有没有跑过。

## 前置

- 使用当前文档口径源码安装。每轮记录 `orbit version --json` 的 version、source 和 content digest；历史运行继续保留当时的 0.6.11，不回写成新版本。
- 启动环境已有 `TYPESAFE_API_KEY`。诊断只确认变量存在，不打印值。
- 准备一个临时 Git 仓库和一条同仓库 worktree。不用生产用户任务，不用 Zeen Login 任务，也不在 Orbit 自己的仓库上启动 Orbit。
- 成员名单允许本次要用的 kind。执行成员和检查者分开记录：检查者／裁定者不是执行成员。
- 每个路径单独建任务。开始前记下墙钟起点；结束后确认停止，并保留任务目录。

## 要采集的事实

每条路径都留下：

- 墙钟：开始、第一次提示或第一次检查、成员结束、Root 集成、任务终态。
- 调用次数：JEV 第一阶段、模型证据请求、第二阶段、reviewer、process_reviewer、adjudicator。
- token：status 上的分角色用量。缺值保持未知，不把 Root 会话累计量加进任务量。
- 成员：是否出现 `delegate`、kind、工作目录、结果是否回到原 Root。
- 工作区：`project_root`、`artifact_root`、rebind history、检查是否 stale 以及原因。
- 裁定：finding id、resolve 或 decision 事件、重开是否被拒绝。
- 停止确认：`stop_confirmation.confirmed` 与任务状态。`queued` 或检查 `verdict(complete)` 不算任务完成。

## 路径 1：两个可并行工作面

给定一个临时项目，里面有两个可以独立交付的工作面。

1. 接入 Orbit，让 Root 开始实现其中一个工作面。
2. 记录 JEV 是否实际运行。若 `delegatable` 达到 0.60 且有可调用成员，记录是否发出一次模型证据请求。
3. Root 用 `model-evidence` 提交事实。记录第二阶段的 `member_fit` 与 `parallel_gain`。
4. 只有两者分别不低于 0.55 和 0.50 时，才应出现最终提示。提示必须写明由 Root 显式 `delegate`。
5. 若提示出现，由 Root 显式派发一个执行成员，并核验结果是否被集成。

成功：至少一条路径里，提示、显式派发、成员结果和集成都发生，并有墙钟与 token。只发出提示不算成功。若分数不足而没有提示，如实记下，不改阈值。

## 路径 2：worktree 切换

1. 任务先绑定原工作树并完成至少一次检查。
2. 在同仓库 worktree 写出不同产物，执行 `rebind-workspace`，记录来源、原因和 history。
3. 用 `amend` 写入另一条路径文字，确认产物目录不变。
4. 确认旧工作区上的在途检查即使内容摘要相同也因 workspace stale，且其 finding 没有迁入待核对线索。
5. 确认新 root 上随后有一次检查，读取的是新的产物目录。

成功：rebind 后的有效检查只读新 root，amend 没有改绑定。本路径不要求程序发现「Root 口头说的路径和绑定不一致」并自动暂停；那个行为没有实现。

## 路径 3：同一 finding 不无证据重开

1. 让检查者提出一个带稳定 id 的 finding，并确认 Root 收到一次纠正。
2. 在该 id 仍为 open，且输入、产物目录、产物摘要和 requirement／evidence／action 都不变时再跑一次检查。记录是否出现 `finding_repeat_ignored`，以及 Root 是否没有再次收到这条纠正。
3. 由裁定者撤销或由后续检查 resolve。在同样没有新证据时再跑一次检查，记录该 id 是否被拒绝重开。
4. 改变任一证据维度后再检查，记录该 id 是否重新投递。
5. 若检查者换了一个新 id 描述同一问题，只记录它有没有按 prompt 复用原 id。程序没有拦住新 id，不算实现失败。

成功：同一 id 已 open 且证据都不变时记 `finding_repeat_ignored` 且不再次纠正 Root；已 resolve 且证据都不变时不重开；任一证据维度变化后重新投递。换新 id 的语义同义项不算程序漏判。

## 路径 4：相同观察不重复自动检查

1. 在产物和输入保持不变时，交错持续编辑之后的停顿、一次 stale 结果、一次 Root 交付和若干次 `status`。
2. 记录相同 observation key 的自动检查是否被跳过。
3. 手动 `check` 应能再跑一次，但不得与已在进行的检查并发。
4. 普通 stale 之后不应立刻再开一轮完整检查。workspace stale 除外，它只为新 root 安排一次。
5. `status` 不触发 JEV 或检查者。

成功：自动调用次数能对上 observation key，最终仍有一次完整检查。token 按角色可核算；缺的角色保持未知。

## 小任务

用一个有界小改再跑一条任务。成功标准是：没有独立工作面时不提示、不检索模型资料、不创建执行成员。检查者仍可按原调度运行。

## 成功与失败

四条路径和小任务各自保留自己的记录。一条失败不改写另一条。下列任一情况都不是通过：

- 只用确定性测试代替上述临时项目。
- 提示已发出，但没有 Root 显式 `delegate` 和成员结果。
- 把检查 `verdict(complete)` 或 `queued` 写成任务完成。
- 用 Root 会话累计 token 填上未知的任务用量。
- 在 Orbit 仓库上用 Orbit 检查这次改动，当作本 runbook 已执行。

## 回滚

验收使用临时项目和临时任务目录。结束时对每条任务执行显式 `stop`，确认 Root、执行成员和检查进程的停止证据。不删除临时仓库里的验收记录，直到记录被抄进本文件的「运行记录」一节。

若验收中的安装影响日常使用：停掉本轮任务后，用该安装自己的 `orbit update` 或原安装目录恢复。不在失败的验收任务上继续派发成员。

## 运行记录

### 安装与夹具

- 最终主链路使用本地 dirty 安装 `0.6.11`，内容摘要 `ee779f384afaec9d030b0192fe5abeff2f01bae268cdb603a5d60cd72ad86613`，安装时间 `2026-09-22T11:35:54Z`。校准期间每次源码变化都重新安装并新开会话，旧 run 不改写为新 build 的结果。
- 最终收尾与 rebind 修复安装摘要为 `5fcdd8be7e48269b83e9f3ad726d0eaf5b198e120723d39171637fe318f47863`，安装时间 `2026-09-22T11:54:24Z`；对应补充实测另记，不与此前主链路混算。
- 0.6.11 全量回归、验收记录和项目级 Skill 完成后再次本地安装，摘要 `2dae3924159afedaf1392ddc91c6b11106bb8de571665cafbefcf0d3d399140b`，安装时间 `2026-09-22T12:10:21Z`。该摘要随后用于 0.6.11 严格复验；复验发现的问题由下方 0.6.12 build 修正，不把旧摘要称为当前最终源码。
- 临时项目：`small`（有界单文件）、`large`（两个独立 Ruby 模块）及其同仓库 worktree `large-wt`。证据目录暂时保留。

### 严格按项目 Skill 的复验（12:45–13:03）

用户指出此前“Controller 直接操作运行时”没有覆盖真实使用方式后，使用项目级 `orbit-real-acceptance` Skill 从头复验。Controller 只通过 Herdr 启动三条全新的已安装 `orbit codex` 会话并发送用户需求；实现、Orbit 调用、成员委派、检查和停止均由受测 Root 完成。测试 build 为 `0.6.11`、dirty content digest `2dae3924159afedaf1392ddc91c6b11106bb8de571665cafbefcf0d3d399140b`，隔离证据保留在 `/tmp/orbit-skill-retest-Dm4AwQ`。三个 Herdr pane 分别为 `w1B:p1C`、`w1B:p1D`、`w1B:p1E`，均用 `herdr pane run … 'orbit codex'` 启动，未用普通 Codex 替代。

- 小任务 `small/.orbit/tasks/94d982ba-f02b-4bec-b1da-714884aae8ee`：初始要求为“请读取 TASK.md 并完成其中的 release label 需求。使用 Orbit 管理这次工作，按任务要求修改、运行验证、请求独立最终检查，并在确认结果后停止 Orbit。不要提交代码。最终简要报告实际修改、验证、Orbit 是否产生执行成员以及停止结果。”任务从 `12:45:48Z` 到 `12:47:38Z`。`delegatable=0.07`，没有 evidence request、最终提示或成员，`ruby verify.rb` 通过，停止确认；负样本委派判断通过。唯一 reviewer 因 Root 在检查期间轮询状态而以 `host` stale，Root 却仍据此停止，因此“有效终检后停止”不通过。JEV 第一阶段累计 `8,510/148` input/output，检查 `79,134` tokens。
- 并行任务 `parallel/.orbit/tasks/63496da2-4bcd-4f31-8cd3-06a6454a15e1`：初始要求为“请读取 TASK.md，完成其中的 import pipeline 实现。使用 Orbit 管理执行与独立检查。你负责整体交付并立即开始 Surface A；Surface B 是独立工作面，如果 Orbit 建议委派，就形成完整执行票显式交给一个成员，并在成员工作时继续自己的部分。集成后运行任务规定的全部验证，处理真实检查意见，最后显式停止 Orbit。不要修改测试，不要提交。最终报告时间线、是否发生真实 delegate、成员结果、检查结论和停止状态。”任务从 `12:49:16Z` 到 `12:54:18Z`。第一阶段 `delegatable=0.91`，第二阶段 `member_fit=0.63`、`parallel_gain=0.40`，持久事件是 `delegation_declined`，没有 `delegation_hint`；Root 却把第一阶段高分误读成最终建议信号并自行委派。成员 `01a0c92a-d7da-7a81-97af-4336217ee5f4` 确实完成 Surface B、结果回收和停止确认，Root 并行完成 Surface A，组合验证 6 runs / 8 assertions 通过。因此成员机械链路通过，但“仅按 Orbit 最终建议委派”的工作流验收失败。最终 reviewer 又因 Root 轮询成为 `host` stale。JEV 第一阶段 `13,576/222`、第二阶段 `5,944/38`，两次检查累计 `140,552` tokens。
- rebind 任务 `rebind/.orbit/tasks/b2d9bd7b-3315-424c-8f70-9bb446b429bc`：初始要求为“请读取 TASK.md，并用 Orbit 验证 linked worktree 中的交付。linked worktree 是 /tmp/orbit-skill-retest-Dm4AwQ/rebind-wt。先让 Orbit 绑定当前 main 工作树并实际启动一次手动检查；确认该旧检查已经 in flight 后，显式 rebind 到 linked worktree，理由写‘user selected linked delivery’，再追加一条 amendment：‘Mentioned path /tmp/text-only-path is contextual text and must not change the binding.’ 不要修改任何受跟踪文件。让旧检查自然以 workspace stale 结束，确认随后有效检查读取 linked worktree，最后显式停止 Orbit。不要提交。最终报告检查 scope、stale 原因、最终 artifact_root 和停止结果。”任务从 `12:55:43Z` 到 `13:03:44Z`。旧 root 的 check 1 在 rebind 后以 `workspace/artifact/input/host` stale；history 正确记录切换理由，amendment 中的假路径没有改变绑定，check 4 non-stale 且 scope 指向 `rebind-wt`，停止确认，因此 rebind 语义通过。Root 的状态轮询使 check 2、3 额外 `host` stale，最终共跑四次 reviewer、消耗 `531,726` tokens，效率验收失败。JEV 第一阶段累计 `18,273/370`。

本次严格复验三条任务的 reviewer 合计 `751,412` tokens；JEV 第一阶段合计 `40,359/740`，另有第二阶段 `5,944/38`。所有任务均为 `paused` 且 `stop_confirmation.confirmed=true`，三个测试 pane 与关联进程已结束，证据目录保留。结论是：项目 Skill 已能覆盖正确的真实拓扑；小任务不委派、成员执行链路和 worktree 绑定机制分别得到真实证据，但当前 Root 会误把阶段一分数当作最终提示，并通过轮询 `status` 系统性破坏检查 freshness，整体工作流不能判为全绿。

### 0.6.12 针对性严格复验（14:39–15:01）

Controller 继续只通过 Herdr 启动全新的已安装 `orbit codex`，不直接替 Root 调用 Orbit。小任务和 JEV 任务使用 `0.6.12` dirty build `c6fdd264773b7fec5ff27fe2c47311799a8d3475e9572c2040bc90c8cc9622f7`；rebind 等待文案在真实失败后收窄，最终通过的 build 为 `38118717fb1591fa517c32dcf96c92bd02e3bc54851b67c269f9820d1cfe22c1`，测试前安装时间 `2026-09-22T14:56:04Z`。收尾后从同一源码再次安装，摘要保持不变，最终安装时间 `2026-09-22T15:07:58Z`；全局 Orbit skill 与仓库版本逐字一致。每次运行时代码或用户 skill 变化后都重新安装并新开会话，旧结果不冒充新 build 结果。

- 小任务 `small/.orbit/tasks/33888c26-2a26-47a8-9947-c7aec1236025`：`delegatable` 初始为 `0.20`，没有第二阶段、hint 或成员。Root 改一行并通过 `ruby verify.rb`，请求一次手动终检后立即结束 turn，没有 sleep、poll 或 status；Orbit 以 `finalization_notice` 唤醒 Root。唯一 check 从 `14:40:19Z` 到 `14:41:15Z`，`stale=false`、无 finding，input/output 为 `76,393/1,039`，随后显式 stop，停止确认。证明常规终检无需轮询且 artifact check 不再被宿主等待动作弄 stale。
- 双工作面任务 `parallel/.orbit/tasks/46ed1c80-0940-4781-a54d-b0319d1662ff`：第一轮 `delegatable=0.91`，第二阶段 `member_fit=0.66`、`parallel_gain=0.44`，持久 `decision=declined` 且没有 `delegation_hint`。Root 明确说这是阶段一候选分和最终拒绝，没有 delegate、没有成员，也没有伪称 Orbit 建议；后续观察的第二阶段同样均为 declined。两面由 Root 实现，组合验证 5 runs / 13 assertions 通过。唯一终检 `stale=false`、无 finding，input/output `75,585/1,048`；Root 被唤醒后显式 stop，停止确认。该路径关闭了 0.6.11 的“把候选分误读成最终建议”真实缺陷；`root_without_hint` 的成员字段和事件仍由确定性回归覆盖，本轮没有为了制造证据强行 override。
- reviewer prompt 的真实文件包含有界 `review_focus` 以及“先看变更路径和直接依赖、仍须覆盖完整要求”的规则。小任务单次 input 从旧样本约 `79,134` 降到 `76,393`，不能据此声称显著单次压缩；并行任务从两次合计 `140,552` input 降为一次 `75,585`，主要收益来自消除重复 stale 检查。
- 第一条 rebind 复验揭示等待纪律写得过宽：Root 在 check 后立即结束 turn，旧检查完成后才 rebind，无法形成 in-flight stale；第二条证明仅把 check/rebind/amend 连续入队也不够，异步队列会先处理 rebind，reviewer 随后才启动。两次均如实判失败并停止，没有写成通过。最终规则只禁止“为了等待检查结论”轮询；用户明确要求的状态变更可用最少查询确认它的状态前置条件，不能扩大成普通轮询。
- 最终 rebind 任务 `rebind3/.orbit/tasks/edbc4768-4564-4038-85f0-d930930451f1`：Root 发起 check 后只读一次 status，确认 check 1 已 `in_flight`，随即 rebind、amend 并请求最终检查。check 1 的 scope 是 main worktree，结束时 `stale=true`，原因为 `workspace/artifact/input`；check 2 自动在 linked worktree 启动，`stale=false`、无 finding，并发出 finalization notice。两次 input/output 分别为 `94,418/1,133` 与 `190,162/2,774`，合计 input `284,580`，低于旧严格样本四次 `531,726`，但单次成本仍高。最终 `artifact_root` 是 `/private/tmp/orbit-0.6.12-real-xfUmZe/rebind3-wt`，amendment 中假路径未改变绑定，任务 `paused` 且停止确认。

本轮三个最终样本均停止确认，Herdr 测试 pane 与临时测试进程已关闭，证据目录保留。结论限于：JEV 最终拒绝不再被误读、常规终检可无轮询唤醒且 fresh、artifact/process freshness 分离按真实 artifact 路径生效、in-flight rebind 用一个明确前置条件查询即可在两次检查内闭合。它不证明所有 finding repeat/reopen、observation 去重分支或无 hint Root override 都已由真实模型覆盖。

### 小任务：通过

任务 `small/.orbit/tasks/8b61af4c-1d38-4c10-a6cc-330a0faf39b7`：

- `delegatable` 真实分数为 `0.18`、`0.21`，没有模型证据请求、最终提示或执行成员，`members: []`。
- JEV 累计 input `2,525`、output `148` tokens。
- 一次 reviewer 检查 input `87,275`、cached input `76,288`、output `929`。小任务不委派是正确的，但检查基线成本明显过高。
- 显式 stop 后任务为 `paused`，停止已确认。第一条校准小任务也得到 `0.18/0.35/0.31`，同样未委派；它不替代上述最终样本。

### 两个可并行工作面：主链路通过，暴露并修复两个收尾问题

任务 `large/.orbit/tasks/50acc26e-10b1-4001-a799-3026bedf6eb3`，创建于 `2026-09-22T11:36:48Z`：

- `11:36:54Z` 第一阶段 `delegatable=0.86`；`11:36:55Z` 第二阶段 `member_fit=0.67`、`parallel_gain=0.59`；`11:36:56Z` 发出最终提示。
- `11:37:18Z` Root 显式委派完整 Surface B 给 Codex 成员 `01a0c8e7-f11b-7f71-b86f-167df73df714`。成员仅修改 `lib/event_summary.rb`，focused test 为 4 runs / 7 assertions，并带确认停止回到原 Root。Root 同时完成 Surface A；组合验证为 8 runs / 13 assertions，`git diff --check` 通过。
- JEV 第一阶段累计 input `17,494`、output `296`；第二阶段累计 input `12,532`、output `76`。累计包含一次活跃成员期间不应出现的第二次判断；该 run 因而发现并推动“活跃成员阻断新自动提示”的修复。
- reviewer 第一次发现真实缺陷 `config-delete-override-only-nested`：override-only 的嵌套分支没有应用 DELETE 语义。第一次结果因 Root 状态变化而 stale；第二次有效检查复现并投递一次纠正。Root 修复后第四次有效终检以同一 id 记为 resolved。
- 四次已记录检查 input tokens 分别为 `100,123`、`97,512`、`94,477`、`47,542`，任务累计 `check_tokens=344,548`。检查者确实提升了质量，但成本与两模块夹具不成比例。
- 第四次终检无 finding，却返回 `continue` 与 `next_check_seconds=1`；旧实现不会唤醒已 idle 的 Root，并启动了第五次检查。人工唤醒 Root 后显式停止，第五次在途检查被停止且未冒充已完成检查。任务为 `paused`，Root 与成员停止均确认。
- 针对上述两个事实，运行时新增：成员处于 `starting/working` 时不再发新自动提示；有效无 finding 的手动终检按版本只发一次 `finalization_notice`，并恢复约定间隔等待 Root 显式停止。确定性回归已通过，最终 dirty 安装的补充实测单列记录。

终检补充实测任务 `large/.orbit/tasks/420a575a-4581-4627-a651-b5361adf6b33` 使用最终摘要 `5fcdd8be…`：先有一次 non-stale delivery reviewer 返回 `continue` 和 `next_check_seconds=1`；外部排队的手动检查随后作为 check 2 运行，同样 non-stale、无 finding、`continue`、建议 1 秒。运行时于 `12:07:48Z` 只记录一次 `finalization_notice`，把 next trigger 改为 `finalization_wait`；Root 被通知唤醒后于 `12:07:56Z` 显式 stop，任务为 `paused` 且停止确认。没有第三次 reviewer 检查，证明新收尾路径阻断了 1 秒检查风暴。

### worktree 路径：通过

补充任务 `large/.orbit/tasks/d1703c9e-0397-4820-b311-3e88104c1d45` 使用最终摘要 `5fcdd8be…`：

- 显式 rebind 从 `large` 切到同仓库 `large-wt`，history 记录来源、理由 `real acceptance workspace switch` 与时间。
- 随后的 amendment 写入 `/tmp/not-a-binding-change`，`artifact_root` 仍为 `large-wt`，证明文字要求不会暗改绑定。
- 第一轮把 `check`、`rebind`、`amend` 连续入队；runtime 在处理 rebind 后才真正启动检查，因此该检查直接绑定新 root。这条只证明绑定和 amendment，不被冒充为旧 root 过期证据。
- 严格时序复验任务 `large/.orbit/tasks/e35ff4e2-5e53-4292-b0b8-4277432a75e4` 先于 `12:00:41Z` 在原 `large` 启动 check 2，再于 `12:01:12Z` rebind 到 `large-wt`。check 2 的 `scope.json` 明确记录旧 `artifact_root/source_root=large`，结束时 stale reasons 含 `workspace`；没有 finding 被迁移。`12:01:40Z` 自动启动 check 3，其 scope 明确记录 `artifact_root/source_root=large-wt`，结果 non-stale 且任务停止确认。amendment 中的 `/tmp/must-not-rebind` 没有改变绑定。
- 严格复验 JEV input/output 为 `3,298/74`；三次检查累计 input `131,558`。任务最终 `complete`，`stop_confirmation.confirmed=true`。

### finding 与 observation 路径

- finding 稳定 id、有效投递、修复和 resolved 已在并行主链路真实覆盖；open 同版本重复的 `finding_repeat_ignored`、resolved 同版本重开的 `finding_reopen_ignored` 尚未分别用真实模型强制复现，只有确定性回归。
- 普通 stale 不立即复查、手动与 delivery 检查时序已真实出现；相同 observation 的自动 `check_duplicate_skipped` 和 `status` 零调用规则有确定性回归，本轮尚未把每个分支都做成独立真实模型任务。

### 结论与剩余产品限制

- 真实正负样本支持当前 `0.60 / 0.55 / 0.50` 三个门槛作为初始校准，但样本量很小，后续必须积累数据，不能把它们视为永久最佳值。
- Codex Root 当前实际可调用的本次成员仍是同模型 Codex。Herdr 中可见 OMP、OpenCode、Cursor 不等于 Orbit 已拥有这些跨宿主成员适配器，因此“Codex 比 Flash 慢”的潜在并行收益在本链路里没有实现。JEV 只能比较实际 callable identity，不能用网上评价假装某个快模型已经可派发。
- 检查 prompt 已有有界上下文，但真实 reviewer 输入仍为每次约 4.7 万到 10 万 tokens；这是明确的未关闭成本问题。质量收益与 token 成本必须分别汇报。

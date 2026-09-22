# Zeen Login 任务中的 Orbit 使用复盘与 JEV 证据（2026-09-22）

## 结论

这次任务使用了 Orbit 的任务记录、独立检查和争议裁定，但没有启动执行成员，因此准确状态是：

> Orbit 已接入，当前仅独立检查；执行成员 0 个。没有启动多 Agent 执行协作。

本次 JEV 没有参与调度。任务记录没有任何 JEV 评估、不可用、委派提示或提示落实事件；运行环境证据进一步表明，启动 Orbit 的宿主进程虽然带有 `TYPESAFE_API_KEY`，实际执行 `start` 的 Orbit MCP 子进程却没有继承该变量，导致 `JevAdvisor.for_project` 返回 `nil`。因此不能把本次没有委派成员解释成“JEV 判断无需委派”：JEV 根本没有作出判断。

## 任务范围与证据

- 项目：`/Users/yangke/Personal/omen/zeen`
- 隔离产物：`/Users/yangke/Personal/omen/zeen-login-baseline-workspace`
- Orbit 任务：`6597a3cb-bef6-4762-8dfb-9cda00184303`
- 原始会话：`01a0c757-0cb0-76a3-a5b0-2f297b5f392a`
- Orbit 记录：`/Users/yangke/Personal/omen/zeen/.orbit/tasks/6597a3cb-bef6-4762-8dfb-9cda00184303/`
- Codex 会话：`/Users/yangke/.codex/sessions/2026/09/22/rollout-2026-09-22T12-19-26-01a0c757-0cb0-76a3-a5b0-2f297b5f392a.jsonl`

以下判断只覆盖这一次真实任务，不据此推断 Orbit 在所有任务中的普遍收益。

## 已证实的使用体验

### 接入 Orbit 不等于启动执行协作

Orbit 的独立检查者和裁定者确实是另外的 Agent，但它们不承担实现。只有 Root 显式调用 `delegate` 才会创建执行成员；Orbit 不自动派发。

本任务的 `state.json` 最终记录 `members: []`、`member_hosts: {}`，会话中也没有 `delegate` 调用。Root 先独自完成设计资料迁移、Login 实现、测试和设备操作，用户追问“你用了 Orbit 吗”后才补接检查链路。因此此前只说“用了 Orbit”虽然字面成立，却没有说明执行吞吐仍由一个 Root 承担。

对外状态应明确区分：

- `Orbit 已接入，当前仅独立检查；执行成员 0 个。`
- `Orbit 已接入，已委派 N 个执行成员；多 Agent 执行协作已启动。`

### 检查对象绑定错误，修改说明没有改变快照根

任务记录的 `project_root` 是原工作树 `/Users/yangke/Personal/omen/zeen`，实际产物位于隔离 worktree `/Users/yangke/Personal/omen/zeen-login-baseline-workspace`。Root 在 amendment 和 dispute 中反复说明正确路径，但 amendment 只修改检查输入，不改变任务的快照根。

结果是检查 2、3、5、10、11 等多次从原工作树读取旧文件，再次提出相同的迁移和 Login 布局 finding。检查 4、6、8、9、12、13 又以“读取了错误工作树”为由撤销它们。对于固定项目根的任务，说明另一个 worktree 的路径不能替代真正从该 worktree 建立任务或快照。

### 同一争议反复摇摆

`orbit-check-2-001` 至 `003` 在检查 2 至 13 中反复出现和被撤销。“忘记密码”尤其经历了多次相反裁定：一部分检查要求在本轮补齐匿名短信重置全链路，另一部分检查认定这会把 Login 视觉改版扩大为跨后端、契约、客户端 transport 和页面的新功能。

最终检查采用后一结论，但中间复查没有稳定复用已经成立的工作树和范围证据。该过程确实留下了可追溯记录，也确实制造了重复等待和判断噪音。

### 检查成本与状态表达不匹配任务规模

任务共启动 13 次检查，13 次结果全部标记为 stale；记录的检查 token 为 `9,621,916`，单次输入从约 18.7 万到 127.6 万不等。Root 另有多次手动 `status`，且曾以 5 秒 `check_in` 启动任务。检查风暴不能只归因于 UI：激进初始间隔、自动 stale/recheck、交付触发和 Root 轮询共同造成了额外开销。

最后一次检查的内部 verdict 是 `complete`，但同一秒运行程序因 Root `systemError` 无法确认停止，任务最终状态是 `stop_unconfirmed`。这说明 `queued`、`running`、检查 verdict `continue/complete` 和任务终态不是同一层状态；面向 Root 的摘要需要更直接地说明“动作已入队”“检查意见”“任务是否完成并已确认停止”。

### Orbit 实际提供的价值

本任务保存了原始要求、9 条 amendment、一次完整 dispute、13 次检查结果和停止失败证据。独立检查迫使 Root 给出提交、测试、设备和工作树证据，而不是只作口头完成声明。

这些价值属于可追溯监督，不等于执行吞吐提升。本次没有执行成员，检查和争议又主要围绕错误快照重复，因此 Orbit 在这次任务中提高了证据要求，但没有缩短实现关键路径，整体上增加了交付时间。

## 分工复盘

没有调用 `delegate` 主要是 Root 的调度责任，不是 Orbit 自动派发失败；现行产品明确把是否委派留给 Root。

不过，事后方案不能改写真实时间线。用户先单独要求设计目录迁移，迁移完成后才追加“提交一下，然后开始对 Login 页面进行改版”，而且明确了先后顺序。因此“从任务最初就并行派发文档迁移 A 和 Login 实现 B”并不是当时已有的选择。

更合理的真实委派点是 Login 改版开始时：

1. Root 读取规范、冻结 Login 的产品和视觉边界，处理“忘记密码”等范围冲突。
2. 一个执行成员承担完整 Login 页面实现及直接相关测试，而不是按按钮或测试文件碎拆。
3. Root 核验、集成并运行组合检查。
4. 实现稳定后，由 verify-only 成员操作设备并回报视觉和行为证据；Orbit checker 复核证据与完成声明。设备是共享资源，这一步与仍在变化的实现不宜强行并行。

最新的“移除注销入口、主体居中”是有界小改，单独派发的交接成本可能高于实现成本；遗漏委派的主要节点是此前完整 Login 改版，而不是之后每一项小修正。

## JEV 是否起到作用

### 结论：没有运行，因此没有作用

任务的一手记录中不存在以下任何事件：

- `jev_assessed`
- `jev_unavailable`
- `delegation_hint`
- `delegation_hint_failed`
- `delegation_hint_followed`

`state.json` 也不存在 `jev` 或 `delegation_hint` 字段。若 JEV 调用成功，`TaskRuntime#assess_jev` 必须写入 `jev_assessed` 事件和 `state["jev"]`；若调用失败，则必须写入 `jev_unavailable` 和失败状态。两类记录都不存在，只能说明本任务的 runtime 没有创建 advisor，而不是 JEV 给出了低分或建议被 Root 忽略。

13 次检查的角色分布是 3 次 reviewer、10 次 adjudicator、0 次 process reviewer；原 Root 会话中也没有收到 `Orbit delegation hint`。因此不能把任何一次检查启动、争议重核或 Root 行为归因于 JEV。

### 环境证据与根因链

2026-09-22 核对仍在运行、且控制地址与该任务 `connection.socket` 一致的原 Orbit 宿主时：

- Orbit 宿主进程 PID 1606 的环境包含 `TYPESAFE_API_KEY`。
- 为该 Codex app-server 启动的 Orbit MCP 进程 PID 1778 的环境不包含 `TYPESAFE_API_KEY`。
- 项目不存在 `.orbit/jev-disabled`。
- 当时安装的 Orbit release 包含 `JevAdvisor`、`jev_assessed` 和 delegation hint 实现，源码与当前仓库对应文件哈希一致；不是旧版本缺功能。

代码路径与该观察吻合：

1. `scripts/orbit-mcp.cjs` 用 MCP 进程的 `process.env` 执行 `orbit start`。
2. `lib/orbit/cli.rb` 在任务进程中调用 `JevAdvisor.for_project(project_root)`。
3. `lib/orbit/jev_advisor.rb` 在 `TYPESAFE_API_KEY` 为空时直接返回 `nil`，不会记录“不可用”。
4. `TaskRuntime` 收到 `advisor: nil` 后只走普通定时/交付检查路径，不会评估 `delegatable`，也不会发送委派提示。

因此，本次真实故障不是 JEV 模型判断质量问题，而是 key 没有进入 MCP → CLI → task runtime 的环境链路。现有“在启动 Coding Agent 的 shell 中设置 key”只保证了外层 Orbit 宿主可见，未保证 Codex 为 MCP 子进程保留该变量。

另有一个没有在本次产生实际影响、但需要后续验证的调度风险：任务以 5 秒 `check_in` 启动，运行循环又在 JEV 之前优先处理到期检查和 Root delivery；争议存在时，stale 结果还可能立即安排下一次检查。事件记录中检查 4 至 13 经常在前一次结束后 1–2 秒启动。即使修复 key 传递，这种持续检查链也可能让 JEV 很难获得评估窗口。该项是根据代码顺序和事件时间作出的风险判断，不是本次“JEV 未运行”的根因替代解释。

### 即使运行，JEV 也不会自动 delegate

当前 JEV 第一阶段评估 `stuck`、`off_track`、`artifact_ready` 和 `delegatable` 四个概率。`delegatable >= 0.6`、存在可调用且获授权的成员类型、模型证据和第二阶段判断均满足现行门槛、状态仍新鲜时，Orbit 最多向 Root 发送一次 delegation hint。提示明确声明由 Root 决定子任务和是否委派，Orbit 不自动 dispatch。

所以修好环境传递以后，正确验收不是只看 `jev_assessed`，而是分四层：

1. JEV 是否实际运行并留下 `jev_assessed`。
2. 是否对真实可拆任务给出足够高的 `delegatable`。
3. 是否成功投递 `delegation_hint`，且提示基于未过期状态。
4. Root 是否据此调用 `delegate`，以及成员是否真的缩短关键路径。

本次四层都没有发生，不能宣称 JEV 已帮助识别分工、改善调度或降低检查成本。

## 后续建议

本记录只确认当时的问题，不改写本次任务的环境与检查事实。随后的实现已进入
[任务运行合同](../../contracts/task-runtime.md)。它不追溯修复这次 MCP 子进程缺少 key、检查读错 worktree 或 13 次 stale 的历史记录。

此后已实现并有确定性回归、但没有在本任务上重放：

- Codex `orbit codex` 用 `env_vars` 只传递 `TYPESAFE_API_KEY` 名称；值由 app-server 从启动环境解析；诊断不泄漏值。
- 工作区显式绑定，以及 workspace stale 不迁移 finding、新 root 一次检查。
- JEV 第一阶段、模型证据请求与缓存、`model-evidence`、第二阶段 `member_fit`／`parallel_gain`，只提示不自动 `delegate`，每个观察签名至多一次。
- observation key 自动去重；手动请求可绕过，但不能并发。普通 stale 不立即重查。
- 同一 finding id 已 open 且证据未变化时记 `finding_repeat_ignored`，不再次纠正 Root；任一证据维度变化才重新投递。已 resolve 的同一 id 无新证据不重开。
- status 分层和按角色用量；未知不推算。

仍然没有：绑定冲突的自动检测与暂停；程序对换新 finding id 的语义同义问题不做猜测。四条真实路径验收未运行，见 [优化真实验收计划](orbit-optimization-acceptance-plan-20260922.md)。

原后续项的当前位置：

1. Codex 启动链的 key 名称传递已进入合同。这次历史任务本身没有被重放。
2. `status` 已显示 JEV 状态。配置过 key 仍不等于本任务运行过 JEV。
3. “当前仅独立检查”和“已有执行成员”已分开显示。
4. 显式 rebind 已进入合同。绑定冲突时自动暂停完整检查没有实现。
5. 同一 finding id 已 open 时重复报告记 `finding_repeat_ignored`，无新证据不重开，普通 stale 不立即重查。换 id 的语义重复仍靠 prompt。

## 一手来源

- Zeen 任务 `state.json`、`events.jsonl`、`runtime.log` 与 13 份 `checks/*` 记录。
- 原 Codex 会话 JSONL，包含用户补充、Root 状态声明和 Orbit MCP 调用。
- `lib/orbit/task_runtime.rb`：JEV 评估、事件、提示阈值与不会自动派发的实现。
- `lib/orbit/jev_advisor.rb`：key、禁用文件、四个判断及 API 调用边界。
- `lib/orbit/cli.rb`、`scripts/orbit-mcp.cjs`：MCP 到任务运行进程的环境和启动链。
- `docs/reference/jev-runtime-acceptance-20260918.md`：JEV 能在有 key 的受控运行中真实调用并触发过程检查的既有验收边界。
- `docs/adr/007-task-runtime-refactor.md`、`docs/plan/debt-ledger.md`：现有真实样本尚未证明 delegation hint 和过程检查带来分工或检查成本收益。

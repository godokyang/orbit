# Orbit 执行协作与检查回路整体调优计划

状态：2026-09-22 实现与确定性回归完成，真实验收待跑。现行语义以
[`contracts/task-runtime.md`](../../contracts/task-runtime.md) 为准。四条真实路径尚未执行，见
[优化真实验收计划](../reference/orbit-optimization-acceptance-plan-20260922.md)。

## 目标

Zeen Login 任务暴露的不是单一 JEV 问题，而是执行协作、产物绑定、检查收敛、成本控制和状态表达共同失配：

- Orbit 接入了任务记录与独立检查，但执行成员始终为 0，检查能力没有转化为执行吞吐。
- 任务绑定原工作树，实际产物位于隔离 worktree；文字 amendment 无法改变检查快照根。
- 同一批 finding 在错误工作树和相同证据上反复提出、撤销、再提出，裁定没有形成稳定决策记忆。
- 13 次检查全部 stale，记录约 962 万检查 tokens；自动调度、争议重核与 Root 轮询没有收敛。
- `queued`、`running`、检查 verdict、任务终态和停止确认混在一起，Root 难以判断是否还需要动作。
- JEV 实际没有运行；即使运行，现有 `delegatable` 也只覆盖“可能可拆”，没有判断真实并行收益。

目标是让 Orbit 同时做到：该分工时真正帮助 Root 启动执行成员；检查始终读取正确产物；finding 和裁定稳定收敛；
自动检查成本与任务变化相称；状态不需要靠轮询和猜测解释。

不把所有任务强制变成多 Agent，不让 Orbit 自动派发，不降低最终独立验收，也不建设与当前问题无关的通用调度平台。

## 执行状态

- [x] 切片 A：JEV 环境事实链与分层状态。实现与确定性回归完成，真实验收待跑。Codex `env_vars` 只传 key 名称；status 已分层。
- [x] 切片 B：`artifact_root`、工作区身份与受控 rebind。实现与确定性回归完成，真实验收待跑。绑定冲突的自动检测与暂停没有实现。
- [x] 切片 C：observation 去重、finding／裁定收敛与检查输入控制。实现与确定性回归完成，真实验收待跑。换新 finding id 的语义同义问题不由程序猜测。
- [x] 切片 D：分层委派判断、模型证据缓存和执行提示落实记录。实现与确定性回归完成，真实验收待跑。提示不自动 `delegate`。
- [ ] 四条真实路径与小任务验收。用户明确禁止本轮使用 Orbit 自举，因此未执行，不能勾成已验收。

当前由 Root 负责总编排、热点接线与审核；Cursor、OMP、OpenCode 只承接边界清晰的执行票。开发过程不使用 Orbit 自举。

## 冻结的整体原则

1. **执行与检查是两条状态轴。** Orbit checker／adjudicator 是监督角色，只有成功 `delegate` 才算启动执行成员。
2. **Root 负责方向与集成，完整执行票交给成员。** 多个独立工作面出现时主动评估并行收益；小改、强耦合工作和共享设备热点由 Root 直接处理。
3. **检查对象是受控绑定，不是 prompt 里的路径文字。** amendment 只改变用户要求，不能暗中切换产物根。
4. **同一证据只裁一次。** finding、撤销和裁定形成决策记忆；没有新证据不得反复重开。
5. **只为新信息付检查成本。** 相同输入、相同产物和相同决定不重复启动模型；stale 不自动制造检查风暴。
6. **动态模型事实按需检索。** Orbit 不内置排行榜，不让用户填写速度；Root 检索并提交带来源和有效期的证据，JEV 只消费摘要。
7. **运行事实分层显示。** 排队、执行、检查意见、整体完成和停止确认分别报告，不能用一个“完成”覆盖不同阶段。

## 一、执行协作真正进入主流程

### Root 的职责

Root 读取原始要求并冻结验收，识别依赖和文件／资源边界，决定哪些工作必须由自己处理。适合委派的是可以完整描述、
独立交付和独立验收，并能在 Root 继续其他关键工作时并行推进的执行票；不按按钮、测试文件或机械步骤碎拆。

典型分工：

- Root：全局规范、产品冲突、依赖顺序、集成和最终验收。
- 执行成员：一个边界完整的迁移、页面实现、后端能力或相关测试闭环。
- verify-only 成员／checker：在实现稳定后使用共享设备或环境复核，不与仍在变化的实现争用资源。

任务开始时没有独立工作面不提示；后续用户新增需求形成新工作面时允许重新判断。每个观察签名至多一个提示；输入、产物或成员候选实质变化才形成新签名。

### JEV 的位置

JEV 负责语义判断，不负责模型资料检索、成员存在性、自动派发或完成裁决。委派判断分为任务可拆性、成员质量适配和
关键路径收益；完整 prompt、阈值、证据缓存和接口见
[JEV 委派判断专项计划](jev-delegation-optimization.md)。

该专项计划是本总方案的一部分，不代表其余检查回路问题已经解决。

## 二、工作区与产物绑定

### 显式绑定

任务记录同时保存：

- `project_root`：用户授权和项目规则所属目录；
- `artifact_root`：当前实现与检查实际读取的工作区；
- Git 仓库／worktree 身份、HEAD 和绑定时间；
- 每次检查实际使用的 artifact root 与快照版本。

默认两者相同。Root 创建或切换隔离 worktree 后，通过 `rebind_workspace` 变更 `artifact_root`；CLI 对应
`orbit rebind-workspace TASK_DIRECTORY PATH`。现行规则只接受同一真实路径，或同一 Git 仓库（相同 common dir）中的另一个 worktree，并记录原因和来源。旧工作区上的在途检查在应用结果时变为 stale。没有跨仓库授权豁免。

amendment、dispute 或普通消息中出现另一个路径，只作为文字证据，不改变绑定。这样不会再用“我在另一个 worktree”
掩盖程序仍读取旧快照的问题。

### 错误绑定时停止放大

本小节没有实现。程序不检测 Root 声明的产物位置是否与当前绑定冲突，也不因此暂停自动完整检查。

若以后实现，预期行为是：如果检查发现当前绑定与 Root 声明的产物位置冲突，记录 `workspace_mismatch` 并暂停新的自动完整检查，向 Root 请求
`rebind_workspace` 或确认继续使用当前工作区。已有错误工作区 finding 不进入有效问题列表，也不触发连续裁定；
用户手动请求检查时仍明确显示该阻断，而不是读取已知错误快照再消耗一次模型。

`status` 始终显示当前 `artifact_root`、快照版本和最近一次 rebind，使 Root 在第一次检查前就能发现路径错误。

### 现行范围（2026-09-22）

已进入合同：新任务记录 `project_root` 与 `workspace`／`artifact_root`；显式 rebind 校验同一 Git 仓库并记录来源、原因和 history；`amend`／`dispute` 不改路径；指纹、快照、JEV 变更摘要和新执行成员工作目录使用 `artifact_root`；旧工作区上的在途检查即使摘要相同也 stale；`status` 显示产物目录、绑定时间和最近 rebind；旧记录只读回退 `project_root`。MCP `rebind_workspace` 已接到 CLI。

没有实现：检查发现绑定与 Root 声明的产物位置冲突时，记录 `workspace_mismatch` 并暂停新的自动完整检查。已实现的是显式 rebind，以及 workspace stale 不迁移 finding、并为新 root 安排一次检查。

## 三、finding、争议与裁定收敛

本节已进入合同。同一 finding id 已 open 且输入、产物目录、产物摘要、requirement、evidence、action 都未变化时，重复报告记 `finding_repeat_ignored`，不再次纠正 Root；任一维度变化才重新投递。已 resolve 的同一 id 在这些证据都未变化时不重开。换新 id 的语义同义问题只靠检查者 prompt 复用原 id，程序不做语义猜测。

### 稳定身份与决策记忆

程序以检查者复用的 finding ID 作为稳定身份，并把输入摘要、artifact root、产物摘要和
requirement／evidence／action 作为证据版本。finding 当前只持久化 `open / resolved`；裁定另存于 decisions。
检查者必须优先复用已有 ID。程序不猜测两个不同 ID 是否只是同一问题的换措辞。

裁定记录结论、适用要求版本、相关产物指纹和理由。已经撤销或裁定不成立的 finding，只有以下任一事实变化才能重开：

- 用户要求或指定依据相关部分改变；
- 绑定工作区改变；
- finding 所涉及的产物改变；
- 出现此前裁定未包含的新证据。

重开必须指出具体变化；“另一位检查者意见不同”不是新证据。相同证据版本只允许一次裁定，后续检查直接消费决策记忆。

### stale 结果

stale finding 只进入待核对线索，不直接纠正 Root。下一次有效检查按当前版本逐项确认；未确认的线索继续保留，但不会
因为其存在立即启动另一轮完整检查。错误 workspace 产生的 stale 结果直接标记绑定无效，不作为待核对线索迁移。

## 四、检查调度与 token 控制

observation key 已接入自动去重。手动请求可绕过去重，但不能与在途检查并发。新 runtime 遇到旧进程遗留的同 key `in_flight`、且本进程没有 owned checker 时，记录 `check_abandoned_recovered` 并以新检查号重试一次，避免去重永久饿死；正常本进程在途检查仍不并发。普通 stale 不立即重查。检查者程序上下文上限 64KiB，长文本保留前缀与 sha256，历史列表有限额。

### 触发合并

自动触发按输入版本、artifact 版本、宿主状态和开放 finding 集合生成 observation key：

- 相同 key 已检查、正在检查或已排队时，不创建新检查。旧进程遗留的同 key `in_flight` 在本进程没有 owned checker 时除外：记录 `check_abandoned_recovered` 并以新检查号重试一次。
- 同一时刻只允许一个完整检查；后续变化合并为下一版本，不为每个文件事件排队。
- stale 结果本身不立即触发完整重查；等待 Root 交付、用户请求、约定时间或稳定的新版本。
- Root 正在连续编辑时，检查者建议不能缩短约定的完整检查间隔。
- `status` 只读，不触发 JEV、检查者或裁定者；Root 不需要为了等结论持续轮询。

### 输入收缩

完整检查不再反复把整个工作树内容塞进 prompt。固定输入包含原始要求、有效修改、项目规则、变化清单、开放 finding 和
决策记忆；检查者在固定快照中按需读取相关文件。针对 stale 线索或已修复 finding 的复核只提供相关范围，不重开无关问题。

每次模型调用记录角色、原因、observation key、输入／输出 tokens、缓存口径、读取文件和结果是否 stale。任务状态汇总
JEV、reviewer、adjudicator 分项及总量；取不到的 Root／成员用量保持 unknown，不从时间推算。

### 成本保护

用户明确的硬预算继续作为停止边界。没有硬预算时不使用任意 token 数自动降低验收，但以下重复调用必须由程序抑制：

- 相同 observation key；
- 相同证据上的重复裁定；
- 已知 workspace mismatch 下的自动检查；
- 只有状态查询、没有任务或产物变化；
- 已有检查在途时的同类自动触发。

如果单次或累计输入异常增长，`status` 显示增长来源；程序先收缩重复上下文和检查范围，不通过删除用户要求或跳过最终验收省 token。

## 五、状态与对外表达

现行 `status` 已分层：任务状态、执行协作、JEV、检查状态、下一动作，以及按角色用量。`queued` 和 `verdict(complete)` 不是任务完成。缺值与 incomplete 聚合显示未知，不把 Root 会话累计量当成本任务量。下面的英文分块是设计时的字段对照，中文 status 以合同为准。

`status` 分块显示，不把不同层级压成一个词：

```text
Task: running | complete | paused | failed | stop_unconfirmed
Workspace: <artifact_root> @ <snapshot/version>
Execution: 0 members; collaboration not started
Review: queued | running | verdict(correct/continue/complete) | stale | idle
JEV: disabled | unavailable | assessed; last assessed at ...
Open findings: N; pending clues: N; adjudicated: N
Usage: JEV ...; reviewer ...; adjudicator ...; total ...
Next action: waiting for Root | rebind workspace | review scheduled | none
```

对外固定区分：

- `Orbit 已接入，当前仅独立检查；执行成员 0 个。`
- `Orbit 已接入，已委派 N 个执行成员；多 Agent 执行协作已启动。`
- `动作已排队` 不等于检查完成。
- 检查 verdict `complete` 不等于任务停止已经确认。
- `stop_unconfirmed` 不能表述为任务已完成。

自然事件继续通过宿主向 Root 投递；状态查询用于核实，不把轮询当通知机制。

## 六、实施切片

### 切片 A：事实链和状态

1. 修复 `TYPESAFE_API_KEY` 从宿主到 MCP 的名称传递，只暴露存在性。Codex `orbit codex` 的 `env_vars` 已实现。
2. 增加 JEV 实际状态、执行成员状态和分层 review／task 状态。已实现。
3. 对外文案区分检查接入与执行协作。已实现。

### 切片 B：工作区绑定

1. 增加 `artifact_root`、工作区身份和 `rebind_workspace`。已实现。
2. 检查记录实际快照根；旧根结果自动 stale。已实现。确定性回归通过，真实验收待跑。
3. 检测 mismatch 后暂停自动完整检查。没有实现。切片 B 的其余项不因此退回未实现。

### 切片 C：检查收敛

实现与确定性回归完成，真实验收待跑。

1. 引入 observation key 去重和自动触发合并。已实现。手动请求可绕过，但不能并发。旧进程遗留的同 key `in_flight` 在本进程没有 owned checker 时记 `check_abandoned_recovered` 并以新检查号重试一次。
2. 固化 finding 身份与裁定适用版本，禁止无新证据重开。
3. 收缩检查输入，按 finding 和变化范围复核；增加分角色用量状态。

### 切片 D：执行吞吐

实现与确定性回归完成，真实验收待跑。

1. 接入分层 JEV 判断和按观察签名提示。已实现。
2. 增加 Root 模型证据请求、`model-evidence` 回传和有效期缓存。已实现。
3. 让 Root 在提示后形成完整执行票并显式 `delegate`；记录提示是否落实及原因。

切片按依赖顺序完成，不同时重写检查、成员和宿主控制。每片只增加支撑真实用户行为的少量测试；不为了覆盖率扩张。

## 七、真实验收

状态：未运行。可执行步骤见 [优化真实验收计划](../reference/orbit-optimization-acceptance-plan-20260922.md)。本轮用户明确禁止使用 Orbit 自举，因此下面四条路径和小任务都没有执行，不能勾成已验收。

至少覆盖四条独立路径：

1. **多工作面执行任务**：真实出现两个可并行执行面；JEV 确实运行并留下证据；Root 获得有效提示、派发至少一个成员、
   集成产物。记录与 Root 单独执行合理基线相比的墙钟变化、返工、集成和 token，不能只证明提示发出。
2. **worktree 切换**：任务从原工作树切到隔离 worktree；rebind 后所有有效检查只读取新根，旧检查明确 stale，
   amendment 不能伪造切换。
3. **争议收敛**：构造一次检查误报并裁定撤销；同一 finding id 在输入、产物目录、产物摘要和文本都不变时不得重开。同一 id 已 open 且这几项证据都不变时，重复报告应留下 `finding_repeat_ignored`，并且不再次纠正 Root；任一证据维度变化才重新投递。换一个新 id 的语义同义问题，程序不会拦住，验收只记录检查者是否按 prompt 复用原 id。
4. **检查风暴抑制**：持续编辑、stale 结果、Root 交付和状态查询交错；相同 observation 不重复调用，检查次数和 tokens 可归因，
   最终完整验收仍执行。

另用一个有界小改证明系统可以选择不委派、不检索模型资料，也不会为了展示多 Agent 增加成员。

完成标准不是“所有测试通过”或“JEV 给了高分”，而是上述真实路径分别证明执行吞吐、正确工作区、争议收敛、成本控制和
状态清晰。任何未跑通的路径保留为限制，不用文档把计划能力写成当前事实。

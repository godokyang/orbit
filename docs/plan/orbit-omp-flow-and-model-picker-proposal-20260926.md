# Orbit 接入回路与候选模型选择：临时修复方案

> 状态：**已按用户指令实施 A–D（源码；2026-09-26）**。下文「推荐改法」与原始 Zeen 观察保留为设计依据；最后的待审核文字由本次授权取代。入口与判断语义以[合同](../../contracts/task-runtime.md)及 [ADR-008](../adr/008-omp-native-collaboration-base.md) 为准，选模交互以 [ADR-009](../adr/009-user-selected-model-pool.md) 为准；0.7.4 OMP 最低版本门不属于本方案。

## 目标与证据边界

目标是让 `orbit omp` 在真实任务里更容易被 Root 接入，在出现提问中断、重复检查问题和停止未确认时给出可执行的下一步；同时把 `/orbit-models` 从逐条复制命令改为键盘搜索、批量选择。保留当前原生 `task/hub` 派发、独立检查、JEV 判断和 [ADR-009](../adr/009-user-selected-model-pool.md) 的候选池语义。

本次依据是 Zeen 任务 `.orbit/tasks/58cc119b-e7e3-4b09-b209-86b743c89bfc/` 的事件与检查、此前[过程诊断](../reference/zeen-page-capture-orbit-process-review-20260925.md)、当前[任务合同](../../contracts/task-runtime.md)、Orbit 代码，以及已检查的 OMP 18.2.8 源码。现行入口允许 OMP ≥18.2.8；实施前还需在实际使用的 OMP 版本核对所依赖的扩展事件与 UI 接口。Zeen 样本有 2 个原生成员完成并确认停止；因此“Orbit 完全没有多 Agent”不符合该样本。JEV 评估约 50 次，没有持久 `delegation_hint`；成员登记为 `root_without_hint`。这说明自动建议正路径仍缺真实证据，不能把显式派发记成 JEV 建议成功。

| 问题 | 已观察事实 | 尚需定性 |
| --- | --- | --- |
| 接入与分工不够显眼 | `orbit omp` 依赖 Root 正确启动任务、理解候选池与原生派发；Zeen 曾靠 Root 显式派发成员，JEV 没有给 hint | 单次任务为何没有 hint 需看模型证据、任务拆分和判断记录；不据此降低 JEV 门槛 |
| 原生 `Ask` 被系统提示打断 | Zeen 同 pane OMP 回报一次 `Ask` 得到宿主的 `interrupt_skipped` 合成结果，后续没补问 | 要在可控样本核对 OMP 事件边界与 Orbit 插入时机；不能直接认定 Orbit 是上游中断的唯一原因 |
| 同一开放 finding 停滞 | Zeen 有效检查 #7/#8 重复指出 `w1-adjudication-items-not-tracked-in-todo` | 需区分同一问题未修、证据争议和检查快照变化；重复报告本身不等于检查器错误 |
| 停止未确认 | 样本出现 `stop_unconfirmed`，报 Root 未停止；Orbit runtime 已退出，OMP Root 仍在 | 未定位停止请求、会话状态与确认事件之间的根因；必须保留未确认状态 |
| 模型证据请求不醒目 | JEV 可能等待 `model-evidence`，当前 Root 容易只看到没有 hint | 需确认该样本是否处于待提交状态；显示应来自实际状态，不按无 hint 猜测 |
| `/orbit-models` 逐条复制 | 当前裸命令列出几十个 `provider/id` 和 `add/remove` 文案；每加一个都要复制 ID、再发一条命令 | 这是确认的操作体验问题；列表规模越大，操作成本越高 |

## 推荐改法与顺序

### 1. 先让运行回路可恢复

1. **`Ask` 中断恢复。** 先用实际 OMP 版本确认扩展能否稳定观察 `interrupt_skipped` 及原提问调用 ID，并确定下一次提示不会再次打断原生 `Ask`。若接缝存在，Orbit 只在已绑定任务中记录该结果；原提问仍待处理时，在下一个安全的 Root 回合给一次短提醒，请 Root 重新发起原生 `Ask`，附调用引用，按 ID 去重。任务状态变化、提问成功或 Root 明确放弃后清除。若接缝不可观察，先记录上游缺口，不以猜测的对话文本触发重试。Orbit 不代填答案，也不重复发送用户问题。
2. **重复开放 finding 升级。** 同一 finding 在连续两次有效且基于当前输入的检查中仍开放时，状态里突出其 ID、最新证据和下一动作：修复并重检、按现有 dispute 流程附证据，或把真正的产品口径交用户。沿用当前重复 finding 的去重机制；本项只提升行动提示，不重发同一纠正、不凭次数自动关闭或停止任务。finding 状态或检查依据实质变化后才允许再提示。
3. **`stop_unconfirmed` 诊断与重试。** 先复现并定位停止请求、目标 Root/成员会话、宿主返回、确认观察及超时环节，再补缺失的结构化诊断。状态指向现有显式 `stop` 重试路径，不另造停止命令；重试前重新读会话与任务状态，已停不重复打断，未停则按现有授权再次请求并等待确认。证据不足始终保留 `stop_unconfirmed`，不能把 runtime 退出当作宿主停止。
4. **启动前 JEV 判定（已确认，待实施）。** 现行 JEV 只在 Orbit 任务启动后评估，无法决定是否启动。目标是在未绑定任务的新用户请求上，最多做一次有界的 JEV 入口判断：用户是否已授权执行、独立检查是否有实际收益。明确要求使用 Orbit 的请求直接进入受控路径；明确讨论或只读问答不启动；其余请求用原文和必要的项目事实判断，记录所用消息 ID、结果与失败原因。高把握适合受控执行时，由程序在 Root 工作前启动任务，避免 Root 忘记调用工具；不确定、JEV 不可用或项目已禁用外发时保留 Root 显式决定并显示一次提示。判定和启动按消息 ID 去重，同一任务不能重复创建，用户中途改变要求时重新按有效请求判断。阈值须用真实请求样本校准，不沿用任务内“是否值得派成员”的 JEV 分数。任务启动后，状态摘要再区分“已有原生成员”“候选池为空”“JEV 待模型证据”“JEV 未建议派发”。不自动派发成员。

第 4 项已由用户确认，改变现行“Root 显式调用 `start`、Orbit 不自动建任务”的入口规则；实施前仍需验证 OMP 钩子能在首个模型工作前取得最新用户消息并安全创建任务，不可把任务内 JEV 评估搬到启动前充数。当前合同中的完成硬门和独立检查仍是最终裁决，不因入口判断改变。

**统一判断数据模型（已确认，待实施）。** 当前 `JevAdvisor` 直接调用 TypeSafe 托管的 `https://api.typesafe.ai/v1/systemone`，使用 `TYPESAFE_API_KEY`，请求模型固定为 `jev-latest`。目标是让 Orbit 的判断调用只读写一套自有数据结构，不按今天的调用场景枚举 provider 方法。业务代码构造 `JudgmentRequest`，消费 `JudgmentResult`；服务适配器可以自行使用 HTTP、SDK 或本地模型，只负责把请求翻译成该服务能接受的形式，并把回答映射回统一结果。TypeSafe 是首个适配器；将来换服务只新增相应适配器并显式选择 provider／模型。此处的 provider 独立于 `/orbit-models` 的 **OMP 执行／检查模型候选池**。

首版模型只覆盖当前真正使用的二元概率判断，不预设其他回答类型：

```text
JudgmentRequest { schema_version, state, questions: { id: { instruction, true_criterion, false_criterion } }, question_set_version }
JudgmentResult  { schema_version, status: answered | unavailable,
                  answers: { id: { probability_true: 0..1 } },
                  source: { provider, actual_model }, usage?, error? }
```

`state` 由 Orbit 按现有预算裁剪；`questions` 的 ID 与判定标准由业务定义，provider 不重写其含义。`answered` 要求每个请求 ID 都有有限的 `[0,1]` 分数，`unavailable` 带结构化原因且不能携带可用于自动动作的部分答案。`probability_true` 表示该判断为真的估计概率，不是模型对自由文本答案自报的“信心”。Orbit 负责校验结果、按问题 ID 取值、执行各自的阈值和失败路径，并记录 `question_set_version`、实际 provider／模型及可得用量。各适配器自行处理鉴权、调用、超时和原生响应；它们不决定何时启动、检查、派发或停止。

其他服务若不能稳定产出可校准的二元概率，就先返回 `unavailable`；不得把自由文本或未校准的自报置信度硬塞进 `probability_true`。新 provider／模型须按会触发自动动作的判断问题分别验证和校准，再启用相应阈值。provider 或模型切换须显式发生，不在单次判断失败后静默切换或混用分数；凭据只从所选 provider 的安全来源读取，不写入任务记录。现有 `JevAdvisor.observation` 的输入裁剪可保留为 Orbit 公共逻辑，当前所有外部判断调用迁移到这一数据模型，不增加另一套按场景分派的接口。

TypeSafe 的 [模型文档](https://docs.typesafe.ai/models) 和 [API 文档](https://docs.typesafe.ai/api)说明，同一 `/v1/systemone` 接口可通过 `model` 字段选择该账号可用的 System One 模型；当前公开列表只列 Jev 1.13 和其别名。入口自动启动门应使用经校准的版本化模型 ID，并记录响应中的实际模型 ID 与判断规则版本；同一 TypeSafe 服务内换模型也需重校准。其他服务商通过新适配器接入后同样按判断用途分别校准，不因 provider 层存在就宣称已支持。项目禁用外发或所选 provider 无凭据时不发起入口外部调用，回到 Root 显式决定。

### 2. 改造 `/orbit-models` 为搜索式多选

当前 OMP 原生 `Alt+P`／`/switch` 的模型界面能输入搜索词、方向键移动和 Enter 选择，但它是**会话切模的单选内部组件**。扩展公开了 `ctx.ui.custom(...)`，可承载有键盘焦点的自定义组件；`ctx.ui.select(...)` 仅为单选，不足以完成批量勾选。方案借鉴 OMP 的操作方式，使用公开扩展 UI 接口构建简洁多选列表，不直接依赖 `src/modes/components/model-picker.ts` 等内部实现。

默认交互：

```text
/orbit-models                 候选模型池 · 已选 3 / 当前可选 42
搜索: glm                    （输入即按 provider/id 模糊过滤）
  [x] zhipu/glm-5.2          ← 当前行
  [ ] other/glm-...
↑/↓ 移动  Space 勾选/取消  Backspace 删除搜索  Enter 保存  Esc 取消
```

- 裸 `/orbit-models` 在交互 TUI 打开选择器。直接输入搜索词，按 `provider/id` 过滤；上下键移动，Space 切换当前行，Enter **一次保存本次所有变化**，Esc 退出且不写入。列表明确显示总选中数、过滤结果数和本次待新增/待移出数。终端高度不足时列表滚动，空结果给出提示。
- 会话可选模型来自 `ctx.models.list()`。已入池但本会话不可选的 ID 单列为“当前不可选、仍保留”，也可搜索和移动焦点，用 Space 移出；不能把它当作可新增模型。界面不能把“可选择”写成“已验证可调用或有额度”。
- Enter 提交时用最终勾选状态与打开时快照计算**净增删差量**；重新读取 `ctx.models.list()`，若待新增 ID 已不可选，提示刷新且不写入。由模型池在现有跨进程锁内一次读写差量：其他会话对不同 ID 的修改保留；若本次要改的 ID 当前入池状态已不同于打开时，拒绝提交并提示刷新，避免静默覆盖。没有净变化则直接关闭。提交成功后同步本会话 Agent 映射，显示最终池和同步结果；保存失败时保留选择界面与错误信息，避免用户重选。
- 现有 `/orbit-models add <provider/id>`、`remove <provider/id>` 与 `orbit model-candidates` 单项命令继续可用，供无 TUI、脚本和故障回退。无 UI 的裸命令仍输出文字列表。交互成功只改变后续推荐与派发，不切换当前 Root 模型，不改在途成员或检查。

数据层最小变动是给现有 `ModelCandidatePool` 增加一次应用增删差量的操作，并为 OMP 扩展提供一个 CLI 桥；沿用已有格式、锁和原子写。不要为 UI 新造第二份候选池状态。`/orbit-models` 现有逐条命令仍保留，故不会破坏已有调用方。

### 3. 实施与审核切口

| 阶段 | 改动范围 | 可观察验收 |
| --- | --- | --- |
| A：恢复路径 | OMP 扩展事件识别、任务状态与停止诊断 | `Ask` 跳过后只提醒一次且可补问；重复 finding 有明确下一步；未停止不能误报停止 |
| B：候选模型 UI | `/orbit-models` 扩展界面、模型池一次差量提交、必要文案 | 几十个模型可搜索和一次多选；Esc 无持久变化；会话冲突不丢修改；不可选旧项可移出 |
| C：判断数据模型、入口判定与状态 | 统一请求／结果、TypeSafe 映射、启动前判断、去重、成员/候选/JEV 证据状态 | 现有判断调用按问题 ID 消费同一结果结构且行为不漂移；高把握任务只启动一次；讨论不启动；判断不可用时 Root 能显式决定；不自动派发 |
| D：受影响路径验收 | 隔离 OMP 真实会话 | 验证选择器的搜索、多选、保存/取消；对已改动的恢复路径核对原生事件与实际宿主状态。复用未改动的 `task/hub`、检查与纠偏既有有效证据 |

先运行相关已有测试，再补少量高价值回归：可观察的 `Ask` 合成结果去重、重复 finding 提示、停止未确认、模型多选保存/取消、提交前可选列表变化、并发同 ID 冲突与不可选旧项，以及 OMP 交互实测。按根 `AGENTS.md` 控制测试规模。对没有出现的 JEV `delegation_hint` 正样本只记录未验，不把它加成本轮 UI 与恢复路径完成门。

上述入口和统一判断决定已写入[合同](../../contracts/task-runtime.md)与 [ADR-008](../adr/008-omp-native-collaboration-base.md)，选模交互已写入 [ADR-009](../adr/009-user-selected-model-pool.md)；本次用户指令授权 A–D 实施。未放宽 JEV 质量线、模型漂移防护、检查独立性或停止确认要求；Zeen 产品代码不在范围内。

## 实施边界与验收

源码已接通：OMP 原生消息 ID 的启动前判断与去重、TypeSafe 二元概率适配及入口校准；任务内判断保留问题集版本和实际 provider／模型；Ask 合成跳过的单次恢复提醒、连续有效开放 finding 的行动升级、未确认停止的结构化诊断及显式重试；候选池搜索多选与原子差量提交。成员仍只由 Root 原生派发，检查与停止硬门未改变。

OMP 18.3.2 隔离 TUI 已观察 `/orbit-models` 搜索、勾选多个 ID 后一次保存（候选池实际含 `kimi-code/k3`、`deepseek/deepseek-flash`、`deepseek/deepseek-v4-flash`）；另一轮切换未保存后 Ctrl-C 取消，池未改变。原生 `orbit omp --print` 在独立临时项目收到明确受控请求后，入口账本及任务 state 同记消息 `d6140ed9`，模型回复「收到。」；短会话退出时任务 `paused`、原生停止确认 `true`，**不当作完成验收**。旧的根会话 Ask 跳过没有在这两个实测中重现；该分支以真实事件结构的确定性回归覆盖，不宣称宿主正样本。

另一独立 OMP 18.3.2 `--print` 讨论请求回复 `1 + 1 = 2。`；账本将原生消息 `dccc1bca` 记录为 `discussion/no_start`，项目中没有 `tasks/`。不确定请求、禁用外发与同消息并发由隔离回归覆盖；未宣称此处已有真实 Jev 自动启动正样本。

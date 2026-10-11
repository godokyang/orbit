# Loom 集成合同实施（总 TODO）

状态：2026-10-11 用户经协作会话转交并授权实现下述四项（范围见下），并授权 Loom 侧统筹、修改本仓**文档**；实现已提交在本地分支 `feat/integration-contract`（`b38f0d0` 合同 1.0；`92a00dd` 合同 1.1，空串/纯空白 `ref` 视为未提供），**未推送、未升软件版本、未发布**。下方“后续提案”只是方案材料：B 已有评估（O3）但未实现，C 未评估，均不是已生效规则。决定与理由见 [ADR-010](../adr/010-integration-contract.md)，合同见 [integration.md](../../contracts/integration.md)。

## 目标

让集成方（首个是 Loom）依赖 Orbit 声明的合同而不是内部结构：独立合同版本、按能力判断可用、检查项与任务的通用互引、发布前契约测试。全部向后兼容；Orbit 不引入集成方的业务概念，也不依赖它。

## 非目标

- `needs_user` 终态接续（只给看法，见限制清单）。
- 自动入口建立任务时的外部引用；Loom 侧 CI；多模型/多次数的真实会话验收；升版、推送。

## 已实现与验证

| 项 | 状态 |
| --- | --- |
| 集成合同 `contracts/integration.md/.json`，版本 1.0，已加入 `package.json` files | 完成 |
| `orbit capabilities [--json]`，读 integration.json，不连会话 | 完成；安装测试断言打包版可用 |
| 覆盖项可选 `ref`：schema、Ruby/TS 校验、覆盖存储（写死的字段检查已同步）、检查者提示、共享样例 | 完成；既有校验与覆盖测试通过 |
| `start --external-ref`（及扩展 `external_refs` 参数）、`state.external_refs`、status/export 原样输出 | 完成 |
| 契约测试 `tests/integration_contract_test.rb`，已入 `npm test`（3 个测试函数） | 完成；变异检查（丢弃 `ref`）能使其失败 |
| 合同 1.1：空串/纯空白 `ref` 视为未提供且不保存（`capabilities.check_coverage_ref.blank_is_omitted`）；检查者提示改为“没有就省略该键” | 完成；契约测试补空串/纯空白用例 |

## 边界与限制

- 契约测试的 OMP 会话与检查模型是替身，只证明合同面与字段形状。
- 真实检查者试验（2026-10-11，`minimax-code-cn/MiniMax-M3.1-Flash-Preview`，7 次，仅一个模型）：带编号要求的 12 个带标号项只有 1 个设了 `ref`（逐字正确），无自编；不带编号的 3 次中 1 次写了 `"ref": ""` 导致整次检查被拒。据此合同 1.1 把空串/纯空白按未提供处理。抄录召回率低，调用方必须保留回退。
- 全套 `npm test` 在 `tests/prestart_test.rb` 处有环境相关失败，在未改动的 HEAD 副本上同样复现，与本改动无关；其余步骤独立运行结果见交接。
- 测试规模：新增 3 个测试函数，测试文件约 240 行，另有安装测试 3 行；共享校验夹具增加 5 条样例（展开约 200 行 JSON 数据，只验证 Ruby/TS 两个校验器对新字段的一致性）。代码行数在建议内，加上夹具数据后合计超过“≤300 行”的建议；必要性：契约测试是本任务明确要求的交付，样例是新字段在两种语言校验器间唯一的一致性防线，已有测试不覆盖该字段。

## 后续提案（方案材料；B 已评估未实施，C 未评估）

整理：2026-10-11，Loom 侧统筹。背景：集成方（首个是 Loom）现在只能取 `status`/`export` 快照。Orbit 内部已经算好“是否需要用户、下一步动作、检查是否通过”，但没进入冻结合同；`events.jsonl` 是内部审计日志（约 60 种内部类型、无序号、写入尽力而为），不能直接承诺给外部。集成方因此看不到阶段，也无法判断“自上次以来变没变”。本节整理出可选的改进，**是否做由用户决定**（Loom 侧决策点 G1/G3，见 Loom 仓库 `docs/implementation.md` §5）。

### 提案 B：对外状态补充（合同次版本 1.2）

原则：通用，不含任何集成方概念；只加不改；全部可选新增并各以 `capabilities` 新能力名声明；旧调用方不受影响。

| 项 | 内容 |
| --- | --- |
| 变更标记 | `revision`：整数，单调递增，进程重启后不回退，同一 `revision` 对应唯一状态；`updated_at`。集成方可见的字段发生变化（状态、检查结果登记、停止确认、问题/finding 的开闭等）时递增；纯诊断、用量刷新是否计入由评估决定。读命令（含 `status`）不得改变它。能力名 `status_revision` |
| 关注摘要 | `attention`：`phase`（建议枚举：接入中/实现中/检查中/返工中/等待用户/停止中/已停止，最终由评估确定）、`needs_user`（布尔）、`reason_code`、`next_action_code`；只用枚举码，不放长篇自然语言；码表在 `integration.json` 冻结，新增只加不改，集成方遇未知码按“未知”处理。来源是现有的 `user_attention`/`next_action` 等内部判断，须先确认其稳定。能力名 `status_attention` |
| 最近检查摘要 | `latest_check`：时间、输入版本、产物摘要、`ready`、是否针对当前输入/产物、未满足原因的短摘要（有长度上限）、要求项总数与已验证数；不重复 `requirement_coverage.items`。能力名 `status_latest_check` |
| 不在范围 | AI 提问原文与答复（来自 OMP 原生通道）；任何集成方业务概念；写入集成方的数据 |

评估时需要回答（对应 Loom 侧 O3）：
1. 哪些持久状态变化必须计入 `revision`，放在 `state.json` 还是单独计数；并发写下如何保证“同一 revision 唯一状态”；重启后如何保证不回退。
2. 是否依赖 `events.jsonl`（不应依赖：其写入是尽力而为）。
3. `attention` 对现有 `user_attention`/`next_action`/`waiting_for_root` 的映射是否稳定、可冻结；有哪些状态没有合适的枚举。
4. 对现有 `status` 输出、性能、旧记录（没有 `revision` 的旧任务）的影响；风险与回滚方式；预计改动面。
5. 测试预算：契约测试扩展建议不超过 3 个测试函数/约 120 行，遵循本仓测试规模纪律；超过需说明。

验证：①契约测试覆盖 `revision` 随状态变化递增、读命令不递增、重启后不回退，`capabilities` 能力名出现；②真实任务手工核对一次：创建→检查→停止，每步 `revision` 递增，反复 `status` 不变；③不改变既有字段的含义与取值。

### O3 评估结果（提案 B；2026-10-11，只评估，未实现）

依据源码：`TaskRecord#save`（临时文件＋fsync＋rename）、`TaskRuntime#save`、`TaskView` 的 `next_action`/`user_attention`/`waiting_for_root?`/`current_state`。

1. **`revision`**：技术上可行，但口径要诚实。`state.json` 只有运行时进程写（持 `runtime.lock`，另有创建时一次写），所以单写者；把 `revision` 与 `updated_at` 放进 `state.json`，在 `save` 内与状态同一次原子 rename 写出，即可同时保证“同一 revision 对应唯一的已落盘状态”和重启不回退（崩溃后读到旧版或新版，不会读到更小值），不需要另设计数文件。计数规则：`save` 时对“集成方可见字段”的投影（状态、完成就绪、检查登记、开放/关闭的 finding、要求覆盖登记、停止确认与停止诊断、`external_refs`）取摘要，与上次不同才加一；用量、`next_check_at`、各类时间戳不计入。投影用**排除清单**而不是白名单（多算只是多一次无害的递增，漏算才会让集成方错过变化）。**不能保证的部分**：`status` 里有读时现算的字段——`requirement_coverage.current/ready/gap`（随工作区实际指纹变化）与 `usage.resource_calls`——它们不在 `state.json`，变化时 `revision` 不变；合同必须写明“`revision` 标识已落盘状态，现算字段不在其内”。新任务（含 `--resume-from`）的 `revision` 从该任务自己的 id 重新起算，调用方以（任务 id，revision）为键。
2. **不依赖 `events.jsonl`**，也不应依赖：它是尽力而为的追加日志，无序号，写失败只记 `event_error`，不进入 `save` 路径。
3. **`attention`**：现有输出都是中文自然语言（`user_attention` 是整句，`next_action` 约 15 个分支的整句），不是码。但它们的判定条件是确定的谓词，可直接映射成枚举，不必解析文字：`needs_user` 仅是终态（`stop(status: "needs_user")`，任务已停止）；`stop_unconfirmed`/`failed`/`complete`/`paused` 各有自己的状态；运行中按优先级为 完成申请待核对（`completion_stop_pending`）→ 检查进行/已排队（`check_in_flight`/`manual_check_queued`）→ 有开放 finding 或重检线索（返工）→ 其余为实现中；`starting` 单独为接入中。**缺口**：①“等待用户”只有 `needs_user` 终态一种，不覆盖“Root 的原生提问待用户答复”——状态里只记录被打断未答的原生 ask（`ask_interrupts`），没有“正在等用户答复”的记录；②排队中的停止命令只在 inbox 文件里，未写入状态，`stopping` 只能表示 `completion_stop_pending`／`stop_unconfirmed`；③`reason_code`、`next_action_code` 现在没有稳定的码源，硬冻结会把当前措辞分支固化；④`needs_user` 目前不可接续（见[限制](debt-ledger.md)），`attention.needs_user=true` 不能暗示可答复后继续。
4. **影响与回滚**：全部是新增字段与新能力名，旧调用方不受影响；`state.json` 多两个键，旧版本 Orbit 读到会忽略；没有 `revision` 的旧任务不合成该字段（合同写“有则出现，无则按未知”，旧任务只要还有运行时保存一次就会出现）。性能：每次 `save` 多一次小 JSON 摘要，相对已有的整份 `pretty_generate`＋fsync 可忽略；`status` 不新增读盘。主要风险：投影漏算/多算（用排除清单＋一个固定回归用例缓解）、`save` 在每个 tick 都可能调用，需用真实任务确认“无变化的 tick 不递增”。回滚：移除计数与能力名即可，无需数据迁移，多出的键无害。
5. **改动面与测试预算**：约 `lib/orbit/task_record.rb`（save 内计数）、新增一个小的投影/attention 模块（约 60–80 行）、`task_view`/`cli` 的 status JSON 注入 `attention`、`contracts/integration.json/md` 升 1.2 与新能力名、ADR-010 追加。测试 ≤3 个函数、约 120 行：①状态变化递增、重复读不递增、重启后不回退；②`attention` 各分支与未知码；③能力声明。不改既有字段含义。

**建议：改范围后做。** 做 `revision`＋`updated_at`（能力 `status_revision`，价值最大、风险最小）和粗粒度 `attention`（只含 `phase` 与 `needs_user`，能力 `status_attention`，用上面的谓词映射，码表冻结且调用方对未知码按“未知”）。**暂不做** `reason_code`/`next_action_code`（无稳定码源）和 `latest_check`（`checks`、`requirement_coverage` 已在 `status` 中，Loom 可自行推导；有实际缺口再加，属可加性改动）。实现前先在一个真实任务上确认“无变化的 tick 不递增”和排除清单是否完整，并在合同中明写 `revision` 不覆盖现算字段。

### 提案 C：对外有序事件流（仅在触发条件成立后评估）

触发条件：集成方在真实运行中出现关键过程丢失，且无法用 `export` 的原件补回。设计要点（若触发）：以 B 的 `revision` 为序号基础；对外是**精选投影**而不是暴露 `events.jsonl`；只追加、可按序号拉取（如 `--since`）；保留期限与压缩策略先定；事件类型只加不改。在触发前不做，避免过早冻结事件种类。

### 明确不做

- Orbit 反向依赖集成方，或读集成方数据；集成方的业务概念（交付项、权重、批准等）进入 Orbit。
- `needs_user` 终态接续：见 [限制](debt-ledger.md)，需用户另行决定并真实验证。
- 在没有真实运行数据前，对外承诺 `events.jsonl` 的任何内部事件类型。

### Orbit 侧事项与状态

| 编号 | 事项 | 状态 |
| --- | --- | --- |
| O1 | 合同 1.0：capabilities、外部引用、覆盖项 `ref`、契约测试 | 已完成（本地分支 `b38f0d0`，未推送） |
| O2 | 合同 1.1：空串/纯空白 `ref` 视为未提供 | 已完成（本地分支 `92a00dd`，未推送） |
| O3 | 评估提案 B（回答上面 5 个问题，给出书面评估） | 已完成（见上“O3 评估结果”），建议改范围后做；等用户决定是否实现 |
| O4 | 实现提案 B（合同 1.2、ADR-010 追加、契约测试扩展、真实任务核对） | 依赖 O3 与用户决定 |
| O5 | 推送/升版/发布本分支 | 等用户决定 G2 |
| O6 | 评估提案 C | 触发条件成立后 |
| O7 | `tests/prestart_test.rb` 等因缺 `node_modules` 失败的环境问题 | Orbit 自有事项，与集成无关，未开始 |
| O8 | 若集成方的要求原文编号对应实测仍不稳，评估“一条标准一个独立检查项” | 条件触发（取决于 Loom 侧 L4 实测） |

约定：合同留在本仓并由本仓维护；Loom 侧负责节点适配与每日契约测试（Loom 的 L5）；合同变更先改 `contracts/integration.*` 与 ADR-010，再通知集成方，同一主版本内只加不改不删。

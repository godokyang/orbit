# Loom 集成合同实施（总 TODO）

状态：2026-10-11 用户已授权在 `main` 完成提案 B 的阶段 A（合同 1.2）与阶段 B（合同 1.3）。基线 `52bb3848a706013fbbb8ddc7d6613e6564e093a9`，开工工作区干净；合同 1.0/1.1 提交 `b38f0d0`、`92a00dd` 已在 main，无需从旧分支纳入。Codex 是唯一编排者与审核者，通过当前 Herdr workspace 的既有 OMP 执行席交付；不新建分支/worktree，不用内部子 Agent。用户授权每阶段审核通过后各一次 main 本地提交；最新明确指令：只用用户当前 Git 署名（杨科 / godokyang@qq.com），不加 AI 协作者署名；不推送、升软件版本、tag、发布或更新日常安装。

## 2026-10-12 外部 CLI 冷启动修复（Goal）

用户明确要求修复并使用 Goal。范围只补外部 start 与 OMP 宿主任务绑定：运行时在原始指令投递、协作事件读取和 running 状态前登记真实任务；宿主校验项目/路径、provider/socket/thread、活动状态与自有运行时 PID，拒绝覆盖其他活动绑定。既有状态字段和通信语义保持现行合同，不修改 Loom、needs_user 接续或模型选择。

验收冻结：相关回归测试；隔离快照全套 npm test；指定 MiniMax 的真实外部 CLI --prompt-file 冷启动进入 running、真实无变化 tick/协作事件读取、指令实际执行、公开状态/引用回读及确认停止；独立 OMP 只读审核；自有资源收尾。成功检查覆盖另记实际结果，不用其他供应商替代。Root 唯一写者，复用既有只读核查席，不开新席/分支/worktree、不推送/升版/发布/更新日常安装；提交用用户署名。

当前状态：修复完成并通过隔离快照全套 npm test、独立 OMP 只读核查和指定 MiniMax 的真实外部 CLI 冷启动/协作事件/Root 写入/确认停止。新增两处回归约50行；实际 tick 和重复状态读取亦通过。宿主不扫描猜任务；运行时持既有锁登记精确目录，接纳后才获得监督与停止权限。自有资源已核对收尾，保留证据；随本轮 main 本地提交交付，成功终检与 Loom CI 不在已证明范围。

## 本次冻结验收与执行

- 阶段 A：G9a `ORBIT_EXTERNAL_INTEGRATION=1` 关闭自动入口；G9b `ORBIT_CONTROL_SOCKET` 在 session_start 提前监听、调用方目录不删除、会话切换重监听、路径逐字一致且不 realpath、私有目录/路径长度/死 socket 归属安全；G8 `status --external-ref REF [--project DIR] --json` 固定 tasks 数组、精确匹配、无匹配退出 0、失败非零，与 TASK 互斥。有效验证后声明三项能力。
- A 的门槛：含当前任务 diff 的隔离文件快照跑全套 npm test；真实 OMP rpc 会话验证首条消息前 socket 监听与 get_state.sessionId、首条受控请求不自动建任务、显式 start 与引用回读、退出后目录保留/socket 释放。审核并本地提交后才启动 B。
- 阶段 B：原子落盘 revision/updated_at，变化才递增，重复读/无变化 tick 不递增，重启不回退；现算覆盖状态/用量不计入，旧任务未知。attention 仅 phase/needs_user。latest_check 取最后完成记录含失败/陈旧，保留 models 去重数组与 input_current、沿用旧字段回退/null，不暴露敏感文本。save 路径由未参与实现的 OMP 独立只读核查。
- B 的门槛：隔离副本 npm test 与真实小任务（minimax-code-cn/MiniMax-M3.1-Flash-Preview，最少调用）证明变化、重复读、实际无变化 tick、重启、attention/检查记录与模型回执。未覆盖分支明确记录。
- 已决定：采用调用方指定通道，不做登记；Root start 不隐藏，节点仍核对 external_refs；不按引用 start 去重；不做 status --session；OMP rpc 首条消息前的 sessionId 只按实测版本承诺。
- 两阶段新增测试合计建议不超过 8 函数/约 300 行，超出先说明风险与不足；不做提案 C、needs_user 接续、无关清理或生产项目操作。
- 文件所有权：Codex 独占合同、ADR、计划与交接；A-G9 OMP w23:pH（G8结束后接票）独占 plugins/host.mjs、plugins/omp-host.mjs 与相关 .mjs 测试；A-G8 OMP 独占 lib/orbit/cli.rb、必要 TaskView 查询与 tests/integration_contract_test.rb。同一路径和运行资源一次一个写者。

| 阶段/票 | 状态与证据 |
| --- | --- |
| A-G9 | w23:pH 完成生产接线与相关测试，Root 已核对 diff；Node close 删除调用方替换文件的实际缺陷用内部监听＋硬链接修正，真实 RPC 与测试均通过。测试失败资源回收已核；独立审核发现 alias 认领竞态，Root 实际复现后由原作者修复并定点通过；原 w23:pJ 已停止且无产物/资源 |
| A-G8 | 实现回执已收，Codex 已审核 diff/测试覆盖；1 个新增函数，含精确/多任务/终态/无匹配/互斥/坏记录错误。真实回读与组合 npm test 均通过 |
| A 组合测试/真实 rpc/审核/提交 | 真实 RPC（OMP 18.9.0、指定 MiniMax）通过；最终生产四文件与重跑的实测快照 SHA256 一致；指定模型两次 Root 回复（首次验证＋修正后复核），无自动检查调用。首轮与最后快照 npm test 均退出 0；最后真实 RPC 亦退出 0，暂停已确认/进程与 socket 已释放/目录保留。w23:pK 独立只读审核已收，唯一已确认缺陷经 Root 定点复核关闭；Codex A 审核通过，已完成 main 本地提交 `86d09af`（杨科，无 AI 署名）。证据见[验收记录](../reference/loom-integration-acceptance-20261011.md) |
| B 实现/独立审核/真实验证/提交 | A 门槛已闭合；w23:pH 主要接线后撤回所有写权，Root 有界修正；w23:pK 独立只读 save 核查通过，未参与 B 实现。隔离快照全套 npm test 通过，真实状态/无变化 tick/同任务重启与失败检查回执已交叉核验；原驱动超时/KeyError 保留，成功检查未证明。Codex 审核通过，B 随本轮 main 本地提交交付，见验收记录 |


B 的 phase 冻结：`starting`、`implementing`、`checking`、`reworking`、`stopping`、`stopped`、`needs_user`、`failed`、`unknown`。优先级：needs_user/failed/stop_unconfirmed/complete或paused/starting 等状态优先；运行中 completion_stop_pending→stopping；in-flight 或 manual queued→checking；现有 rebind/open finding/recheck 线索→reworking；其余 implementing；未知 status→unknown。needs_user 布尔只在 needs_user 终态为 true。普通未来定时检查不把整个执行期标成 checking。

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

## 评估依据（历史评估；本次生效范围以上述冻结验收为准）

整理：2026-10-11，Loom 侧统筹。背景：集成方（首个是 Loom）现在只能取 `status`/`export` 快照。Orbit 内部已经算好“是否需要用户、下一步动作、检查是否通过”，但没进入冻结合同；`events.jsonl` 是内部审计日志（约 60 种内部类型、无序号、写入尽力而为），不能直接承诺给外部。集成方因此看不到阶段，也无法判断“自上次以来变没变”。本节整理出可选的改进，**是否做由用户决定**（Loom 侧决策点 G1/G3，见 Loom 仓库 `docs/implementation.md` §5）。

### 提案 B：对外状态补充（本次合同 1.3；原提案评估如下）

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

**用户决定（2026-10-11，Loom 侧转述）**：提案 B 的范围为 `revision`＋`updated_at`（`status_revision`）、粗粒度 `attention`（`status_attention`），**并追加**“最近检查记录”的只读暴露（`status_latest_check`）：暴露 `checks` 里已有的记录，不新增计算，至少含检查完成时间、检查者实际角色/模型、对应输入摘要与产物摘要、是否已过期；其余仍不做（`reason_code`/`next_action_code`）。原评估未含此项：实现前需先补评估（哪些字段已稳定、哪些含敏感内容不应外露、旧任务缺字段时的表现）。**同时追加评估**“按外部引用查任务”（如 `status`/`list` 按 `--external-ref` 返回任务；现有合同没有按标记查询的命令，集成方在崩溃或重复请求后找不到已启动的任务）：通用能力、可加性改动，评估其改动面、与多任务/旧任务的关系。本次用户已另行授权实现，范围与门槛见开头。

**用户决定（2026-10-11，Loom 侧转述）追加两项通用能力的评估范围（G9，只评估，未实现）**：

1. **外部集成会话模式**：会话启动时由集成方声明（启动参数或环境变量）；启用后该会话**不做自动入口判定**——不自己建任务、不向 Root 注入入口提示（同时省掉判定的模型调用）；任务只由集成方显式 `orbit start` 建立；建立之后监督、检查、停止与普通任务一致。依据（Loom 侧在合同分支 `ac7705b` 干净副本、OMP 18.8.9、`orbit omp --mode rpc` 下实测）：首条用户消息明确写“请用 Orbit 受控执行…”时入口判定为 `start`，扩展自己立即建任务且 `external_refs` 为空，集成方随后的 `start` 因“该消息已有任务”被拒；首条为普通问题时判定 `root_decides`，只注入提示、不建任务。现有代码无关闭该判定的开关。
2. **会话发现**：外部集成会话模式下，控制通道在会话启动时就建好，并在项目内写一条会话登记（至少含 provider、会话编号、通道路径、进程号、启动时间；退出时删除，启动时清理进程已不在的旧登记）；`orbit start/status/stop` 可只凭会话编号解析通道。依据：通道目前在第一条用户消息时才建、没有官方查询方式，集成方只能比对 `/tmp/orbit-omp-*` 新增目录；会话退出后可能留下无进程占用的死 socket；并发时比对会认错。

请评估：改动面与风险、是否可加性（不改变现有交互用法）、测试预算、与 B 其余项的实现顺序、是否有更小的做法。Loom 侧倾向先做这两项（依据最扎实、后续都依赖）。

### G7–G9 评估结果（2026-10-11，只评估，未实现、未改代码）

依据源码：`plugins/omp-host.mjs`（预启动入口钩子 `host.entry` 唯一调用点、`connect`/`close`/`session_start`/`session_shutdown`）、`plugins/host.mjs`（`createOrbitHost.listen` 懒建通道、`close` 删通道目录）、`lib/orbit/cli.rb`（`start`/`entry`/`status`，只有 `start`、`entry`、`model-status` 使用通道）、`lib/orbit/task_view.rb`（`records`/`select`/`current_state`）、`lib/orbit/task_runtime.rb`（`finish_check`/`projected_check`）、`lib/orbit/prestart.rb`。

| 项 | 可加性 | 改动面 | 建议测试 | 备注 |
| --- | --- | --- | --- | --- |
| G9a 外部集成会话模式 | 是：默认关闭，不设开关时行为不变 | 约 5 行早退 + 合同/说明 | 1 个函数 | 开关用环境变量；**必须与 G9b 同时交付**（见下） |
| G9b 会话发现 | 是：默认关闭，`--socket` 旧用法不变 | 首选“调用方指定通道路径”约 15 行；登记方案约 80–100 行 | 1–2 个函数 | 有更小做法，见下 |
| G8 按外部引用查任务 | 是：只加 `status` 的一个选项 | 约 25 行（含 `--project`） | 1 个函数 | 纯读，不碰状态 |
| G7 最近检查记录 | 是：只加一个字段 | 约 40 行 + 一处只读抽取 | 1 个函数 | 数据已在 `checks` 中，不新增计算 |

**G9a 外部集成会话模式**
- 入口判定只有一个调用点（`omp-host.mjs` 预启动钩子里 `await connect(ctx); host.entry(...)`）。在它之前对“外部集成模式”早退即可：不连接、不调 `orbit entry`、不写入口判定记录、不注入入口提示。显式 `start` 本来就不依赖入口判定（契约测试已覆盖），所以“监督、检查、停止与普通任务一致”无需额外改动；已绑定任务的注入（接续提示、协作策略）不走这条路径，保持不变。
- **G9a 不能单独交付，必须与 G9b 同时。** 通道是懒建的，只有 `entry`/`execute` 会触发；早退跳过了 `connect`/`host.entry`，外部集成模式下就没有任何东西会建通道，集成方将无 socket 可用，连显式 `start` 都做不了。因此外部集成模式必须在 `session_start` 主动建通道（G9b 本就要做），两者是一个整体。
- 开关建议用**环境变量**（如 `ORBIT_EXTERNAL_INTEGRATION=1`）而不是启动参数：`orbit omp` 对原生参数零改动是既有约定（`omp_entry.rb` 注释），新增自有参数要在启动器里剥离；扩展读环境变量已有先例（`ORBIT_RUBY`、`ORBIT_SESSION_AGENT_ROOT` 等）。能力名 `external_session_mode`，声明开关名与“关闭自动入口”。
- **与 Loom 描述的两处出入**：①入口判定是确定性规则（`orbit-entry-rules-3`），只有存在 `.orbit/jev-entry.json` 校准且命中“不确定”分支才会调用模型；未校准时不确定分支直接 `root_decides`、不调模型。所以“省掉判定的模型调用”只在已校准的项目里成立，通常省的是一次 `orbit entry` 子进程与判定记录写入。②模式只关闭**自动**入口：Root 自己仍可调用 `orbit` 工具的 `start`。若 Loom 要求“只能由集成方建任务”，需另行决定隐藏或拒绝 Root 的 `start`；建议先不做（改动面大，且影响 Root 的接续与恢复）。
- 风险：低。验证需要真实 OMP（`--mode rpc`）：首条写“请用 Orbit 受控执行…”的消息不建任务，随后显式 `start` 成功且 `external_refs` 已存。契约测试的替身会话不经过这个钩子；`tests/omp_*_test.mjs` 是否能驱动该钩子需实现时核对，不能就以真实验证并记入限制。

**G9b 会话发现**
- 现状核实：通道在首次 `bind/execute/entry` 时才建（`listen()` 懒建，路径 `/tmp/orbit-omp-<随机>/control.sock`），`session_start` 只做主会话绑定与代理同步；`thread_id` 就是 OMP 的会话编号。Loom 描述的缺口成立。
- **更正**：`orbit status` 与 `orbit stop` 不使用通道（`status` 读盘，`stop` 往任务的 inbox 入队），本来就只凭任务 id/目录；只有 `start` 需要通道。所以“`start/status/stop` 凭会话编号解析通道”实际只涉及 `start`。若还需要“按会话找任务”，任务记录里已有 `connection.thread_id`，可作为 G8 同类的只读过滤（`status --session ID`），属可选项，不默认做。
- **更小的做法（首选）：调用方指定通道路径。** 集成方启动 `orbit omp` 时通过环境变量给出自己选定的 socket 路径（如 `ORBIT_CONTROL_SOCKET`），扩展在 `session_start` 立即在该路径监听（`listen` 本来就能监听任意路径），集成方因此始终知道通道，无需发现、登记、清理，并发时也不会认错。代价与要点：⓪**`--thread` 仍需会话编号**：`orbit start` 要 `--thread`（OMP 会话编号），而 socket 协议的每个请求都要带 `session`（`dispatch` 先 `owned(request.session)`），没有“不带会话编号就问这条通道是哪个会话”的方法，所以会话编号只能来自 OMP 一侧——Loom 须确认 rpc 模式的 `get_state` 会返回它（Orbit 不能代为验证 OMP 的 rpc 行为）。若不能，则本做法不完整，需退到登记方案，或加一个很小的无参 `state`（每个主机进程只有一个主会话，约 5 行），并让 `start` 在省略 `--thread` 时向通道取；①调用方传给 OMP 与传给 `orbit start --socket` 的路径必须是**同一个字符串**：任务记录用 `File.expand_path` 保存、扩展侧用精确字符串比对归属（`ownedTask`），不做 `realpath`，macOS 上把 `/tmp/x` 写成 `/private/tmp/x` 会被判为不属于当前会话，合同须写明；②调用方负责路径长度（macOS 限 104 字节）和目录权限（需 0700）；③**现有 `close()` 会 `rm -rf` 通道所在目录**，对调用方指定的目录必须改为只删 socket 文件，否则会误删调用方目录；④会话切换/分支时 `close()` 会关通道，扩展须在随后的 `session_start` 重新监听同一路径；⑤调用方进程崩溃后遗留的死 socket 由调用方自己的目录管理，Orbit 重新监听前先删除同路径旧 socket。需要让 `createOrbitHost` 公开提前建通道的入口（目前 `listen` 是内部函数）。
- **备选（Loom 原方案）：会话登记。** 项目内 `.orbit/sessions/<provider>-<会话编号>.json`（0600、原子写，含 provider、会话编号、通道路径、进程号、启动时间、项目），`orbit start --session ID` 作为 `--socket` 的替代，`--thread` 缺省取登记值。建议登记只由扩展写/删（`session_start` 写，`close()`/`session_shutdown` 删），读取方（Ruby）负责校验与惰性清理：进程已不存在**且**通道连不上才算死登记；不做“启动时全量清理”，避免误删活会话（进程号可复用，单看 pid 不可靠）。登记含通道路径，属访问凭据，文件与通道目录同为私有权限。适用场景：集成方需要重新发现不是自己启动的 OMP 会话；若集成方自己启动并记录路径，首选做法已足够。
- 两种做法都默认关闭（只在外部集成模式或设置了环境变量时生效），不改变现有交互用法。风险：①`session_start` 在 rpc/无界面模式下的触发时机需真实验证；②提前建通道对没有任务的 `close(true)` 无副作用（`tasks` 为空），但切换会话后的重建要验证；③登记方案多出“写入与进程退出之间的崩溃窗口”，只能靠读时校验兜底。

**G8 按外部引用查任务**
- 现状：没有 `list` 命令；`orbit status`（无参数）只返回未结束的任务（没有则最近一个已结束的），带参数只认任务 ID 前缀或目录；`external_refs` 已在 `state.json`，`TaskView.records` 已按项目扫描全部任务。
- 建议：`orbit status --external-ref REF --json`，**恒返回** `{"tasks":[…]}`（0 个、1 个或多个，创建时间新→旧，含已结束任务），元素与现有 `status --json` 同形。不新增 `list` 命令；注意现有 `status` 恰好 1 个任务时返回裸对象、多个时返回数组，这个选项必须固定数组形状，否则调用方会因匹配数量不同而解析不同。无匹配退出码 0 且数组为空（崩溃恢复需要区分“没有”和“出错”）；精确全等匹配（不做前缀/大小写折叠）；REF 校验与 `start --external-ref` 同规则；与位置参数 `TASK` 互斥。能力名 `status_by_external_ref`。
- 与既有行为：`ref` 不要求唯一，同一 `ref` 可对应多个任务（重复 `start`、`--resume-from` 后重传），Orbit 全部返回由调用方选择；不做按 `ref` 的 `start` 去重（那会改变既有行为，若要做需另议）。无 `external_refs` 的旧任务与自动入口建的任务不会匹配；`--resume-from` 的新任务不继承 `ref`，按旧 `ref` 只能查到旧任务，调用方用 `continuation.previous_task` 或重传。
- 成本与风险：全部任务 `state.json` 读取解析，O(任务数)；**项目定位取决于当前目录**：`TaskView.project` 从 `Dir.pwd` 向上找，现有 `status` 没有 `--project`（`status 任务目录` 才可在任意目录运行），所以按引用查询要么只能在项目内执行，要么新增 `--project DIR`——建议新增（`start`/`entry` 已有同名选项，语义一致），合同注明；只对命中的任务调用 `current_state`（含工作区指纹，较重）。`TaskView.records` 遇到不属于本项目或格式不支持的记录会整体报错，一条坏记录会使查找失败；建议保持（报错优于静默漏查），合同注明。纯读，不影响任何状态，也不影响 `revision`。

**G7 最近检查记录（`status_latest_check`）**
- 数据已存在：`state.checks[]` 每条已有 `number`、`role`、`kind`、`started_at`、`finished_at`、`input_digest`、`artifact_digest`、`stale`、`stale_reasons`、`result`、`usage`，`status --json` 现已整份输出，只是不在合同字段内。所以 G7 是把已有字段的一个投影冻结进合同，不是新增计算。`TaskRuntime#projected_check` 已是这样一个投影（含旧记录读 `checks/<n>/scope.json` 回退），但它是运行时私有的；对外需要把它抽成只读函数，`check_history` 的输出保持不变。
- **可暴露（稳定）**：`number`、`role`、`kind`、`finished_at`、`input_digest`、`artifact_digest`、`stale`、`stale_reasons`（取值 `workspace/artifact/input/host/dispute`）、结果 `terminal`（检查 schema 的 `verdict` 取值，或 `failed`/`stale`）、`failure_kind`（枚举）。
- **检查者模型**：没有“每条检查的模型”单字段，只有 `usage.calls[].model`/`requested_model`（实际调用回执）；失败发生在调用之前或旧记录时 `usage` 为空。建议给 `models`（去重的 `provider/model` 数组，可为空），不伪造单值；`role` 是检查种类（如 `reviewer`/`process_reviewer`），不是模型角色，需在合同里这样写。
- **不应外露**：`result.reason`、`result.findings` 文本、`result.error`/`failure_basis`（错误文本可能含路径和供应商响应）、`observation_key`、`artifact_root`（检查者工作区路径）、`usage` 的令牌/成本明细与 `provider_response_id`。要求项证据本来就在 `requirement_coverage.items[].evidence` 中，不重复。
- **“是否已过期”有两层含义**：①落盘时已判定的 `stale`（检查结束时快照/输入/宿主/争议与启动时不一致）——已记录，可直接给；②“相对当前是否仍是最新”需要把 `input_digest`/`artifact_digest` 与当前输入摘要、现算的工作区指纹比较，后者是读时现算（与 `requirement_coverage.current` 同类，较重，也不进 `revision`）。建议 `latest_check` 只给①，并给只比较输入摘要的 `input_current`（纯 `state` 内、便宜）；产物是否仍对应当前工作区继续读 `requirement_coverage.current`，不重复实现。
- “最近”的定义：`checks` 的最后一条已完成记录（含失败、陈旧），**不含进行中的检查**（运行中的检查尚未写入 `checks`，进行中由 `attention.phase=检查中` 表达）；它不等于“最近一次可采纳的检查”。无检查时该字段缺省（“有则出现”）。旧任务缺 `artifact_digest` 等字段时按 `scope.json` 回退，仍缺则为 `null`，不合成。
- 因 `checks` 登记已计入 B 的 `revision` 投影，G7 不增加 `revision` 的口径；与 `attention` 共用同一个“对外只读投影”模块较省。

**建议实现顺序与合同版本**
1. 先做 G9（G9a＋G9b 作为一个整体，首选做法）与 G8，一起升合同 1.2（均为可加、默认关闭或纯读；G9 依据最扎实且后续依赖它，G8 最小且与 G9 互相独立，可并行）。每项各自出现在 `capabilities`（`external_session_mode`、`control_socket_env`、`status_by_external_ref`），实现并有测试后才声明。
2. 再做 B 的 `revision`＋粗粒度 `attention` 与 G7，合并升 1.3（提案 B 标题原写“次版本 1.2”，G9/G8 先发则顺延为 1.3；版本号以实际发布顺序为准）（共用 `status` 的投影，`revision` 是唯一触及 `save` 路径的改动，风险最高，放最后并用真实任务确认“无变化的 tick 不递增”）。
3. 每步先在干净副本上跑 `npm test`，G9 另需一次真实 OMP rpc 会话验证；做不到的部分写入[当前限制](debt-ledger.md)，不宣称已验证。

**测试预算**：G9a 1、G9b 1（登记方案 2）、G8 1、G7 1，均为契约测试内的函数或现有 `.mjs` 测试内的用例；合计新增 4–5 个，每个约 30–40 行，共约 120–180 行；加上 B 的 ≤3 个/约 120 行，B＋G7–G9 总计 7–8 个、约 240–300 行，个数在 AGENTS.md 建议的 ≤10 内，行数贴近 ≤300 的上沿；若实际超出，在实现时说明必要性，不拆票。

**原评估的决定点（本次均已确认，见开头）**：①G9b 采用“调用方指定通道路径”（推荐）还是会话登记；②外部集成模式下是否还要隐藏 Root 的 `start`（建议先不做）；③G8 的无匹配语义（建议退出码 0＋空数组）及是否之后要 `start` 按 `ref` 去重（建议不做）；④G7 的 `models` 形式与 `input_current` 是否保留；⑤是否需要 `status --session ID`；⑥Loom 确认 OMP rpc 模式能否在启动后取得会话编号（决定 G9b 首选做法是否成立）。

### 提案 C：对外有序事件流（仅在触发条件成立后评估）

触发条件：集成方在真实运行中出现关键过程丢失，且无法用 `export` 的原件补回。设计要点（若触发）：以 B 的 `revision` 为序号基础；对外是**精选投影**而不是暴露 `events.jsonl`；只追加、可按序号拉取（如 `--since`）；保留期限与压缩策略先定；事件类型只加不改。在触发前不做，避免过早冻结事件种类。

### 明确不做

- Orbit 反向依赖集成方，或读集成方数据；集成方的业务概念（交付项、权重、批准等）进入 Orbit。
- `needs_user` 终态接续：见 [限制](debt-ledger.md)，需用户另行决定并真实验证。
- 在没有真实运行数据前，对外承诺 `events.jsonl` 的任何内部事件类型。

### Orbit 侧事项与状态

| 编号 | 事项 | 状态 |
| --- | --- | --- |
| O1 | 合同 1.0：capabilities、外部引用、覆盖项 `ref`、契约测试 | 已完成（main 含 `b38f0d0`） |
| O2 | 合同 1.1：空串/纯空白 `ref` 视为未提供 | 已完成（main 含 `92a00dd`） |
| O3 | 评估提案 B（回答上面 5 个问题，给出书面评估） | 已完成（见上“O3 评估结果”），用户已确认范围并授权阶段 A/B |
| O4 | 实现提案 B（A 合同 1.2、B 合同 1.3、ADR-010、测试与真实验证） | A 已提交 `86d09af`；B 实现及冻结字段门槛审核完成，随本轮 main 本地提交交付 |
| O5 | 推送/升版/发布本分支 | 等用户决定 G2 |
| O6 | 评估提案 C | 触发条件成立后 |
| O7 | `tests/prestart_test.rb` 等因缺 `node_modules` 失败的环境问题 | Orbit 自有事项，与集成无关，未开始 |
| O8 | 若集成方的要求原文编号对应实测仍不稳，评估“一条标准一个独立检查项” | 条件触发（取决于 Loom 侧 L4 实测） |

约定：合同留在本仓并由本仓维护；Loom 侧负责节点适配与每日契约测试（Loom 的 L5）；合同变更先改 `contracts/integration.*` 与 ADR-010，再通知集成方，同一主版本内只加不改不删。

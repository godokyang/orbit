# Orbit v2 Slice 6 阶段 C 设计说明：存储任务化（Gate 3a）

- 日期：2026-08-17
- 执行：wA:pF（omp）；审核：wA:pD
- 基线：`c198590`（阶段 B 已提交）
- 状态：**设计稿，待批准。本文档不含任何已实施的代码改动。**
- 工单：[slice6-workorder](./slice6-workorder.md) 第 4 节

## 0. 现状盘点（设计输入）

- `ActiveRoot.marker_for(active_root, code:, label:)`（`lib/orbit/v2/active_root.rb:21`）：断言
  `File.realpath(active_root) == <realpath(File.dirname(active_root))>/.orbit`，然后在
  canonical project root 读 ProtocolRoot marker。lib/ 内共 **17 处**调用（审核方提到 20，
  实测 lib/ 为 17：control_store 8、task_store 5、evidence/gate_engine/gate_fact/policy
  各 1；差异可能来自 tests/ 计数，3b 时再精确对账），涉及 6 个错误码：
  `control_store_unpinned`(8)、`task_store_unpinned`(5)、`evidence_store_unpinned`、
  `gate_engine_unpinned`、`gate_facts_unpinned`、`policy_store_unpinned` 各 1。
- 五锁顺序 policy→task→control→evidence→gate 出现在 control/evidence/gate_fact/
  gate_engine 的写路径；锁文件路径全部由 `File.join(@active_root, <FILE>)` 构造。
- 构造器现状：四 store + gate_engine 均为 `initialize(active_root:)`，仅校验
  `File.directory?(@active_root)`（错误码 `<store>_argument_invalid`）。
- `task_id` pattern：`/\Aotask_[a-z0-9][a-z0-9_-]{7,95}\z/`（`identifiers.rb:13`）。
  字符类 `[a-z0-9_-]` 不含 `.` 与 `/`，故 pattern 命中即排除 `..`、隐藏文件与
  路径分隔符——但校验必须显式发生在路径构造处（见 §3）。
- `DurableFile.atomic_write` 已有 `FileUtils.mkdir_p(dir)`（`durable_file.rb:135`），
  TransactionLog append 因此可写入尚不存在的目录树；但构造器的
  `File.directory?` 前置检查仍会先拦住。

## 1. 目录布局（问题 1）

```text
<project>/
└── .orbit/
    ├── protocol.yaml                       # 项目级，不变
    ├── policy-transactions.json            # 项目级，不变（PolicyStore/ProtocolRoot 定位不动）
    └── task-scopes/
        └── <task_id>/                      # 每 Task 一目录
            ├── task-definitions.json       # TaskStore 日志（文件名不变）
            ├── control-transactions.json   # ControlStore 日志
            ├── evidence-transactions.json  # EvidenceStore 日志
            └── gate-facts.json             # GateFactStore 日志
```

**目录名裁决（2026-08-17，审核方定）**：segment 用 `task-scopes`，禁止 `tasks`。
理由（比「与 v1 live root 撞名」更硬）：`ProtocolRoot.create` 的 v1 mixed-epoch 扫描
（`reject_mixed_epoch!`，`protocol_root.rb:111`）**无条件先于** create-only marker
检查（L124-137）执行，而 v1 的权威目录清单 `KNOWN_V1_AUTHORITY_PATHS` 含 `tasks`。
若 v2 复用该名，一个完全合法的 v2 root 只要存在 `.orbit/tasks/`，重放
`ProtocolRoot.create`（幂等路径）就会被自己的 guard 判成 v1 混合纪元——**v2 自身
数据在 epoch 检测眼里与 v1 权威产物永久不可区分**。这是结构性歧义而非时序偶发。
护栏：`active_root.rb` 定义 `V2::TASK_SCOPES_SEGMENT` 常量并在加载期断言其与
`KNOWN_V1_AUTHORITY_PATHS` 不相交——将来任何人复用 `evidence`/`rules`/`handoffs`
等 v1 名字会当场失败，而不是等到 dogfood 撞上。

- 只迁移四个日志文件的位置，文件名与 TransactionLog 格式零变化；不引入
  revisions/ control/ evidence/ 等子目录分片（每 store 单文件日志，分片无收益，
  违反最小变更）。
- `.orbit/` 与 `task-scopes/` 与 `<task_id>/` 目录的创建责任：沿用现行模式——项目根由
  `ProtocolRoot.create` 建立；`task-scopes/<task_id>/` 由 Task 任务创建流（目前是测试
  fixture / 未来 CLI `task create`）或 `TaskStore#genesis` 的 ensure 步骤建立（见
  §4-d）。其余 store 构造即要求目录存在（fail closed，与今天对 `.orbit` 的要求
  同构）。


### 1.1 task 目录内的持久事实与运行时临时物（2026-08-17 补充）

**是否将 `.orbit` 纳入版本控制由项目自行决定，Orbit 不硬编码任何一种假设**（用户
已定调：按项目决定、由人自选、默认不跟踪）。布局只需保证「选择性跟踪」不改代码
即可行，因此必须区分 task 目录内的两类文件：

**持久事实**（TransactionLog 日志，选择跟踪的项目可提交）：

```text
.orbit/task-scopes/<task_id>/task-definitions.json
.orbit/task-scopes/<task_id>/control-transactions.json
.orbit/task-scopes/<task_id>/evidence-transactions.json
.orbit/task-scopes/<task_id>/gate-facts.json
```

**运行时临时物**（绝不提交；选择跟踪的项目必须排除）：

- `*.lock` —— `DurableFile.with_exclusive_lock` 在每个被锁日志旁创建的零字节
  flock 文件（`durable_file.rb:43`，`<path>.lock`）。项目级
  `.orbit/policy-transactions.json.lock` 同理。
- `.*.tmp.*` —— `create_staging_file` 在**目标同目录**生成的暂存文件
  （`durable_file.rb:144-146`，`.<basename>.tmp.<pid>.<tid>.<hex>`）。同目录是
  原子 rename 的硬约束，不可搬迁；提交前的 `ensure` 分支会清理，但崩溃残骸
  可能留存。

选择跟踪的项目可直接使用以下 `.gitignore` 片段（放行四个日志、挡住 lock 与
tmp）：

```gitignore
# Orbit v2 task-local durable facts (opt-in tracking)
!.orbit/
!.orbit/task-scopes/
!.orbit/task-scopes/**
.orbit/task-scopes/**/*.lock
.orbit/task-scopes/**/.*.tmp.*
```

注：锁文件与暂存文件的位置**本阶段不改**——搬迁锁位置超出阶段 C 范围，且暂存
同目录是 atomic rename 的硬约束。

## 2. `ActiveRoot.marker_for` 的信任边界如何泛化（问题 2，最高风险项）

### 2.1 新断言的确切形式

```ruby
def task_scope(active_root, task_id, code:, label:)
  # 1. pattern 校验（§3）：task_id 不含 / 与 .，路径段词法安全
  # 2. 原样调用 marker_for（断言与错误码未动）
  # 3. 恒等断言：File.realpath(<canonical .orbit>/task-scopes/<task_id>)
 #     必须逐字符等于拼接路径（恒等包含，非前缀匹配）
  # 4. 返回 [marker, canonical_active_root, canonical_task_dir]
end
```

关键点：

1. **比较对象是两个 fully-resolved 路径的恒等**，不是对调用方输入字符串做前缀
   匹配。`canonical_task_dir` 由「marker 已证明的 canonical `.orbit`」+ 校验过的
   `task_id` 拼出（见 §3），不含任何调用方路径成分。
2. `File.realpath` 的性质保证：若解析结果与拼接路径逐字符相等，则沿途
   `task-scopes/`、`<task_id>/` 每一段都不是 symlink（任一段是 symlink，realpath 结果
   就会偏离拼接串）。
3. marker 仍在项目根读取（`marker_for` 内 `ProtocolRoot.read(project_root:)`），
  mixed-epoch、containment、canonical rendering 复核链不变。
4. **返回值绑定（审核必改项 1）**：`task_scope` 返回验证后的
   `canonical_active_root` 与 `canonical_task_dir`；store 的所有后续文件操作
   （日志路径、五锁路径）只从 canonical 值拼接，绝不从原始输入 `@active_root`
   重拼。具体机制见 §4a：构造器从 `File.realpath(@active_root)` + 已校验
   `task_id` 按 canonical-by-construction 派生；每个操作窗口内调用 `task_scope`
   并断言其返回值与构造值逐字符相等（不等即同码 `*_unpinned` fail closed）。
   「验证过的东西」与「实际打开的东西」是同一个字符串。

### 2.2 它如何仍然挡住 shadow store

攻击面逐条对照（新模型下）：

| 攻击 | 结果 |
| --- | --- |
| sibling 目录 `.orbit/task-scopes-shadow/otask_x/` 借用真 marker | `marker_for` 先行失败：realpath(`…/task-scopes-shadow/otask_x`) 的 dirname 链解不出 `<proj>/.orbit`，`*_unpinned` |
| 仓外 shadow `/evil/.orbit/task-scopes/otask_x` | 其 `.orbit` 自身要通过 `marker_for` 的 realpath 恒等 + 在 `/evil` 读出有效 marker + marker pin 的 genesis 能从 `/evil` 的 policy store 解析——即完全独立自洽的第二项目根，不是「借用」pin；与现行 `.orbit` 模型面对的等价，非新增风险 |
| `.orbit/tasks` 或 `task-scopes/<task_id>` 是指向仓外的 symlink | realpath 解析后 `real_task_dir ≠ canonical_task_dir`，同码 fail closed（这正是「不能放宽成前缀匹配」要保住的 symlink 逃逸防护） |
| `<task_id>` 内含 `../`、`/`、`.` | 过不了 §3 的 pattern 校验，路径根本拼不出来 |
| 传入 symlink 别名指回真 task 目录 | realpath 归一后恒等成立，通过——与现行 `marker_for` 对 `.orbit` symlink 别名的态度一致（canonicalize，而非拒绝） |

一句话：**信任锚仍是「store 自己解析后的位置必须恒等于 marker 定义的 canonical
位置」，只是 canonical 位置从 `.orbit` 推广到 `.orbit/task-scopes/<校验过的 task_id>`；
恒等比较（而非前缀匹配）保住了全部逃逸防护。**

### 2.3 调用点适配

17 处调用从 `ActiveRoot.marker_for(@active_root, code:, label:)` 改为
`ActiveRoot.task_scope(@active_root, @task_id, code:, label:)`——**code 与 label
逐字不变**。policy_store.rb:343 与 protocol_root 内部构造不在此列，保持原样。

## 3. `task_id` 作为路径段的校验（问题 3）

- **校验位置：每个 store 构造器内、任何路径拼接之前**，且 `task_scope` 内再做第
  二道（防构造后篡改）。双保险，不依赖调用方自觉。
- **形式**：`Identifiers.valid?("task_id", task_id)`（现成 pattern，见 §0）。
- **错误码**：新code `<store>_task_scope_invalid`（如 `task_store_task_scope_invalid`、
  `control_store_task_scope_invalid`、`evidence_store_task_scope_invalid`、
  `gate_facts_task_scope_invalid`、`gate_engine_task_scope_invalid`），与既有
  `<store>_argument_invalid` 区分开，测试可精确断言。
- pattern 本身（`[a-z0-9_-]`，无 `.`/`/`）使 `..`、绝对段、隐藏文件在词法层
  不可能；即使未来有人放宽 pattern，`task_scope` 的 realpath 恒等断言仍是兜底。

## 4. Task scope 传入方式与调用方适配（问题 4）

### a. 签名变更

```ruby
TaskStore.new(active_root:, task_id:)                 # clock 无
ControlStore.new(active_root:, task_id:)
EvidenceStore.new(active_root:, task_id:, clock: ...)
GateFactStore.new(active_root:, task_id:, clock: ...)
GateEngine.new(active_root:, task_id:)
# 四个 Cutoff 类同步：ControlStore::Cutoff / EvidenceStore::Cutoff /
# GateFactStore::Cutoff.new(active_root:, task_id:)
```

- `@active_root` 语义不变（仍是项目 `.orbit`）；新增 `@task_id`（已校验）。
- **canonical-by-construction（必改项 1 的实现机制）**：构造器从
  `File.realpath(@active_root)`（解析后的 canonical `.orbit`，目录存在性检查
  之后）+ 已校验 `@task_id` 拼出 `@canonical_orbit` 与 `@task_dir`；`@log`
  路径与五锁路径只从这两个 canonical 值拼接，**绝不经原始输入 `@active_root`
  重拼**。每个操作窗口内调用 `task_scope`，断言其返回的
  `canonical_active_root`/`canonical_task_dir` 与构造值逐字符相等（不等即同码
  `*_unpinned` fail closed），并沿用返回的 marker。TaskStore 因 genesis 需先建
  目录，构造器允许 task 目录尚不存在（TransactionLog 对缺失文件按空链处理），
  但 `.orbit` 本身必须存在。
  （TaskStore 之外的四类构造器要求 `@task_dir` 已存在，fail closed。）
- 五锁顺序的字面顺序不变（policy → task → control → evidence → gate）；
  policy 锁仍在项目级文件，其余四锁落在同一 task 目录。跨 Task 并发：不同
  task 目录锁互不相交，共享的 policy 锁恒最先获取——无死序，天然并行。
- `gate_engine.derive(task_id:, task_revision_id:, ...)` 的公共参数保留，但
  `task_id` 必须等于构造 scope，否则 `gate_engine_task_scope_invalid`。
- **方法级 scope 交叉校验**：TaskStore/各 store 以 `task_id:` 为参数的方法
  （resolve、authorizations 等）要求实参 == `@task_id`，不等即
  `<store>_task_scope_invalid`。这使「cross-task 引用」在存储层直接 fail closed，
  对应合同 `cross_task_revision` 语义，不新增判定逻辑。

### b. lib/ 内部调用点适配（同批传播 `@task_id`）

- control_store：内部 TaskStore/EvidenceStore/GateFactStore::Cutoff 构造
  （行 1434/2128/2954/3034 等）全部传 `task_id: @task_id`；2128 处 parent task
  解析按合同本就同 task（`task_id_unchanged`），不一致时由上条交叉校验拒绝。
- evidence_store / gate_fact_store / gate_engine：各自内部跨 store 构造同理。
- protocol_root.rb:185 的 `PolicyStore.new`：不动（项目级）。

### c. 测试适配（55 处构造点，3b 报破坏面）

- 每处构造补 `task_id:`（fixture 已有 `otask_` id 生成）；fixture factory 若有
  单点 helper 则改一处即可。**3b 时先 grep 精确计数（lib+tests 全量），报数
  停下来，不自行大改**（工单 tripwire）。

### d. 目录创建时序

- `TaskStore#genesis`（任务身份的创建 seam，对标 policy 侧的 ProtocolRoot.create）
  在 policy 锁窗口内 ensure：若 `task-scopes/<task_id>` 不存在则 `mkdir_p`，然后重跑
  §2.1 的 realpath 恒等断言（mkdir 可能顺着被伪造的 symlink 走，恒等断言兜底）；
  已存在则直接断言。其余 store 与 TaskStore 的读路径一律要求目录已存在。

## 5. 明确不做（对照工单 C.0）

- 不删任何 cross-control 代码（含 `ControlStore` 内 transfer 相关私有逻辑——
  单 control 下自动失效，留待后续阶段）。
- 不改 `schemas/*.json`（lead-control.schema.json 分歧维持已记录状态）。
- 不改 validator 判定语义；不改 `transaction_log.rb`；不动 policy_store 与
  protocol_root 的项目级定位与代码。
- 不新增目录分片、不建全局 task index。

## 6. 风险与开放问题（呈审核方）

1. `task_scope` 在每次操作多一次 `File.realpath`（每 store 每操作 O(1) 次系统调
   用）。与 `marker_for` 的 marker 读相比成本可忽略，不认为需要缓存（缓存反而
   弱化逃逸防护的时效性）。
2. 旧项目级日志文件（如已存在的 `.orbit/task-definitions.json`）在新代码下成为
   孤儿文件。不删除（清理属用户/后续阶段），但 mixed 检查不覆盖它们——它们不
   再被任何 reader 读到，ADR-005 无双读语义保持。
3. 测试破坏面未知规模（35 处 lib 引用 + tests 构造点 + 可能的路径断言）；按
   tripwire 在 3b 实测后上报，由审核方定向。
4. `TaskStore#genesis` 的 `mkdir_p` 已知行为（审核记录项 2）：若 `task-scopes` 段已被
   伪造成指向仓外的 symlink，`mkdir_p` 会在重定向目标处先建出目录，随后的
   realpath 恒等断言才拒绝该 scope——fail closed 语义不变，但可能留下一个仓外
   垃圾目录。接受此行为（与 `ProtocolRoot.create` 对已存在 `.orbit` 的处理
   同族），不做预检：预检与 mkdir 之间存在 TOCTOU，且伪造 symlink 本身需要
   仓内写权限，届时破坏面已不受此边界保护。

5. 既有不一致（审核方 2026-08-17 记账，非本阶段引入，不修，留待后续阶段）：
   `control_store` 给 `RuleResolution.validate!` 传 `File.dirname(.orbit)`（仓库
   根），而 `evidence_store` 传 `.orbit` 本身；`rule_resolution.rb:141-142` 会在
   该 root 下解析 rule path 并做包含校验，两处实际在强制两套不同的路径约定，
   其中一处很可能是错的。阶段 C 保持各自既有行为（本阶段仅做值等价替换），
   待后续阶段查证统一。

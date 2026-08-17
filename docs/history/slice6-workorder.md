# Orbit v2 Slice 6 纠偏工单（执行方：omp / wA:pF）

> **历史记录（2026-08-17 归档）**：本工单的阶段 A–F 已全部执行完毕，正文保留为当时下达的原文，不作现在时指令阅读。正文中的 `docs/open/...` 路径是当时的仓库状态，文档已于同日重组；对照见 [docs/README.md](../README.md)。ADR-005 修订记录引用本文第 6 节作为 v1 删除的决策依据。

- 统筹与审核：`wA:pD`（Document Reviewer）
- 执行：`wA:pF`（omp）
- 基线 HEAD：`8bad815 feat(v2): derive durable gate outcomes`
- 背景文档：`docs/open/orbit-v2-slice6-handoff.md`（先读完再动手）

本工单已包含执行所需的全部结论，不需要你重做审计。审计结果由审核方在 `wA:pD` 产出并已核验。

---

## 0. 一句话背景

Orbit v2 Slice 6 建立在一个已被用户否定的前提上：「同项目多个长期 Lead control 并行 + Task 在 control 之间转移」。真实协作边界是「一个 Task = 一个 task_id = 一个 Git branch/worktree」。现在要做的是**可恢复地撤回未提交的 Inc6j**，然后**只做文档级架构重置**。

本工单**不包含任何 production code 修改**。

---

## 1. 不可违反的约束

1. 不运行 Orbit CLI。
2. 不运行任何测试：不跑 `tests/orbit_test.sh`，不跑 focused suite，不跑单方法。HEAD 已有完整绿色标记。
3. 不使用 code-review skill。
4. 不修改 `lib/` 与 `tests/` 下的任何文件。
5. 不删除任何 cross-control production 代码。那是后续阶段的事，现在删会失去审计基线。
6. 不得宣称 Slice 6 完成、v2 激活或 cutover ready。
7. 不使用 `git reset --hard`、`git clean`、`git checkout .` 等递归操作。工作区是共享的。
8. 卡住或出现工单未覆盖的情况时**停下来上报**，不要自行扩大范围。

### 绝对不可触碰的文件

```text
docs/open/rule_loading_case.md            # 既有 untracked，必须保持 untouched
docs/open/orbit-v2-slice6-handoff.md      # 交接文档
docs/open/orbit-v2-slice6-workorder.md    # 本文件
```

这三个文件不读取修改无所谓（`rule_loading_case.md` 连读都不要读），关键是：**不修改、不暂存、不提交、不纳入任何清理范围**。

---

## 2. 阶段 A：可恢复地收回 Inc6j

### A.1 精确范围

只有这 4 个 tracked 文件：

```text
contracts/orbit-v2/contract.yaml
lib/orbit/v2/control_store.rb
lib/orbit/v2/validator/lead_control.rb
tests/fixtures/orbit-v2/contract_test.rb
```

审核方核验过的期望 diff 规模（`git diff --numstat`）：

```text
18	3	contracts/orbit-v2/contract.yaml
1090	102	lib/orbit/v2/control_store.rb
20	6	lib/orbit/v2/validator/lead_control.rb
282	0	tests/fixtures/orbit-v2/contract_test.rb
合计 +1410 / -111
```

**执行前先核对这个数字。对不上就停下上报**，说明工作区在交接后发生了变化。

### A.2 步骤

1. 在**仓库外**创建备份目录，例如 `~/orbit-inc6j-backup-20260817/`。
2. 用 `git diff --binary -- <上述 4 个文件>` 生成补丁存进去。显式列出 4 个路径，不要用无参数 `git diff`。
3. 同时把 `git diff --numstat` 和 `git status --porcelain` 的原始输出各存一份，作为事后对账依据。
4. 用 `git checkout -- <上述 4 个文件>` 恢复到 HEAD。**逐个显式列出路径。**
5. **恢复性验证（必做）**：撤销后运行 `git apply --check <备份补丁>`。必须退出码 0——这证明补丁能被还原回去。若非 0，立刻停下上报，不要继续阶段 B。

### A.3 Gate 1 验收标准

`git status --porcelain` 必须**恰好**是：

```text
?? docs/open/orbit-v2-slice6-handoff.md
?? docs/open/orbit-v2-slice6-workorder.md
?? docs/open/rule_loading_case.md
```

同时 `git diff` 为空，`git log -1 --oneline` 仍是 `8bad815`。

达成后**立即上报并停止**，等审核方确认再进入阶段 B。

---

## 3. 阶段 B：只做文档级架构重置

前置条件：Gate 1 已被审核方确认。

因为阶段 A 已把 `contract.yaml` 恢复到 HEAD，**下面所有行号都以 HEAD 版本为准，是精确可用的**。改动过程中行号会漂移，逐个文件从后往前改可以减少漂移。

### B.0 ADR 用「修订记录」而非「原地改写」

ADR 是决策记录，不是当前状态说明。**不要把 003/005/006 里的多 control 条款直接删掉或就地改写**——那会抹掉「我们曾经这样决定过、以及为什么改」的记录，而这恰恰是下一个接手的人最需要的。

正确做法：在每个 ADR 末尾（或紧邻受影响条款处）加一个明确的修订/supersede 小节，写清楚三件事：

1. 哪些条款被取代（列出条款编号或原文要点）；
2. 取代它们的新语义是什么（引用 B.1 的冻结规则）；
3. 为什么改——真实协作边界是 Git branch/worktree + 唯一 task_id，项目级多 control 调度不是 MVP 必要能力。

被取代的条款本身保留原文，但要就近标注为已取代（例如加 `> **已取代（2026-08-17）**：…` 之类的显式标记），让读者一眼看出它不再生效。

`contracts/` 下的三个文件性质不同，它们是机器可读的当前权威，**可以直接改写**，不需要保留历史条款。

### B.1 要写进文档的冻结语义

```text
.orbit/
├── protocol.yaml          # project-level，低频全局事实
├── policy/                # project-level authority lineage
└── tasks/
    └── <task-id>/         # revisions/ control/ attempts/ evidence/ gates/ findings/ handoffs/
```

1. `task_id` 是协作、存储和冲突隔离的单位。
2. 一个 Task 通常对应一个 Git branch/worktree。
3. 一个 Task 只允许一条 accepted control lineage。
4. 不同 Task 路径不重叠，天然并行。
5. 项目级 task/status/index 是派生视图，不是共享可写权威。
6. 同一 Task 的并行修改是真实冲突，由 Git merge 和 Task lineage 校验发现。
7. Lead/agent 更换走 Task 内 session replacement 或 handoff。
8. 不存在 cross-control Task transfer。
9. 不存在 project-wide Task ownership registry。
10. 不存在同项目多 control 之间的 runtime-subject/session transfer。

**必须显式写明的两点：**

- **这是产品范围修订**，不是原 ADR 的完成。不得把缩减后的 MVP 说成原 ADR 全部达成。
- **项目级例外**：`protocol.yaml` 和 `policy/` 保留在项目级，因此保留 Git 合并冲突风险。这是有意接受的：policy rotation 低频，且两个分支同时轮换 policy 本来就是真实冲突，应该冲突。

### B.2 精确修订位置

行号为审核方在 HEAD 上核验所得。改之前请先读上下文确认语义，不要机械替换。

**`contracts/orbit-v2/contract.yaml`**

```text
127, 129          overlapping_owned_task / disjoint_task_and_subject
137-138           control_pins / cross_store_facts
163               project_wide_nonterminal_backstop（task-local 下天然成立，需复核措辞）
203               transition
215               cross_control_session_transfer_and_recovery
276               control_scope（含 transfer_release_provenance）
322               deferred: [cross_control_transfer]
789-790           owned_task_refs 的 project_scoped 定性
796-803           multi_lineage 整节
804-821           task_transfer 整节（release/acquire）
827-834           canonical subject project-wide 绑定与 transfer
835-839           cross_control_attempt_succession
857               cross_control: fail_closed
872               projection
922, 924, 926     action enum / event enum 里的 release·suspend·acquire
1026-1033         task_transfer_acquire
```

> **排雷**：512、588、651-653、1123、1169-1174 里的 `release` 是 **gate 评审角色**（release.evaluate / gate.release.submit），与 task release 无关。**不要改这些行。** 机械搜索 `release` 一定会误伤。

**`contracts/orbit-v2/authority-matrix.yaml`**

```text
63                control_identity_genesis_and_task_ownership
71-79             task_ownership_transfer（整条 fact，含 exact_bindings）
252-253, 256      prohibited_owners / disjoint / cross_control closure
262, 268, 275     not_implemented / cross_store_facts / deferred
357, 384          transition / deferred
482, 484-486      并行边界、project-wide subject、transfer provenance、cross-control successor
488, 498          fingerprint transfer 跳转、control authority store 描述
```

**`contracts/orbit-v2/validator-invariants.md`**

```text
756-760           Parallel boundary / LogicalLead closure / Subject active binding 三行表格
1162-1166         control genesis 的 overlapping task 拒绝描述
```

**`docs/adr/003-lead-orchestrated-dynamic-agent-team.md`**：24、264、437、699

**`docs/adr/005-orbit-v2-clean-cut-and-legacy-retirement.md`**：13、42（条款 11）、57、70、80、157、160、166、247-249、253（条款 17）、273

**`docs/adr/006-serialized-lead-orchestration-control-loop.md`**：19、29、31、39、64、89、91、93、195-199、205、222（条款 3）、224（条款 5）、229、257、264、293

**`docs/adr/orbit-v2-agent-independent-control-amendments.md`**：被 ADR-005:253 与 ADR-006:264 引用为「并行边界不变」，需一并核对该文中的并行边界表述。

**`docs/open/orbit-v2-implementation-plan.md`**

```text
203               增量 1 描述里的初始 task ownership / 并行前提
466-512           Slice 6 交付物与强制 E2E
  其中 491        「repeat ... for a disjoint Task set and distinct runtime subject」
  其中 493        「atomically acquires disjoint Task ownership」
  其中 509-511    release → 旧 session terminal → 新 lineage acquire 三步
514-561           负向测试清单
  其中 524        双 queue ownership / transfer refs / 重叠 task sets 整条
  其中 525        project-wide backstop 措辞
```

Slice 6 的 done criteria 需要按 task-centric 重写。新验收预算参考 handoff 第 10 节的 6 个场景。

### B.3 Gate 2 验收标准

1. `git diff --name-only` 的结果中**不得出现任何 `lib/` 或 `tests/` 下的路径**。这是硬性检查，必须实际跑一遍并把输出贴进报告。
2. `git log -1 --oneline` 仍是 `8bad815`（不要提交，除非审核方另行指示）。
3. 上面列出的三个不可触碰文件未被修改。
4. 在 contracts 三个文件中搜索 cross-control 词汇后，残留项要么已改，要么属于 B.2 标注的 gate release 白名单，逐条说明。

---

## 4. 阶段 C：存储任务化（production 代码，分两个 Gate）

前置状态：阶段 A/B 已完成并提交为 `c198590 docs(v2): reset slice 6 to task-centric architecture`。基线干净。

### C.0 范围

**只做一件事**：把四个 store 的日志路径从项目级单文件改为 Task 本地。

```text
lib/orbit/v2/control_store.rb        control-transactions.json
lib/orbit/v2/task_store.rb           task-definitions.json
lib/orbit/v2/evidence_store.rb       evidence-transactions.json
lib/orbit/v2/gate_fact_store.rb      gate-facts.json
lib/orbit/v2/gate_engine.rb          reader，跟随上述作用域
```

**明确不做**（做了就是超范围，会被打回）：

- 不删除任何 cross-control 代码。那 400 行在单 control 下自动失效，留到后续阶段。
- 不改 `contracts/orbit-v2/schemas/*.json`，包括已记录的 `lead-control.schema.json` 分歧。
- 不改任何 validator 判定语义。
- 不改 `transaction_log.rb` 本身。
- 不动 `policy_store.rb` 与 `protocol_root.rb` 的项目级定位。

### C.1 Gate 3a：先出设计说明，**不写实现代码**

先产出一份设计说明（放 `docs/open/` 下新文件），我批准后才进入实现。说明必须回答下面四个问题，其中第 2 条是本阶段最高风险项。

**1. 目录布局**

写出确切路径。项目级保留 `.orbit/protocol.yaml` 与 policy 日志；四个 Task 本地日志放在 `.orbit/tasks/<task_id>/` 下。

**2. `ActiveRoot.marker_for` 的信任边界如何泛化（关键）**

现行实现（`lib/orbit/v2/active_root.rb:22-24`）断言：

```ruby
canonical_active_root = File.join(File.realpath(File.dirname(active_root)), ".orbit")
File.realpath(active_root) == canonical_active_root
```

即 `active_root` 必须**就是**那个 `.orbit`。一旦传入 Task root，`File.dirname` 变成 `.orbit/tasks`，这个断言必然失效。

它现在的作用是**安全边界**：防止 sibling/shadow/alias store 借用 marker 的 pin（见该文件 8-17 行注释）。泛化时必须说明：

- 新断言的确切形式（Task root 的 realpath 必须被 canonical `.orbit` 真包含，marker 仍在项目根读取）；
- 它**如何仍然**阻止 shadow store —— 不能简单放宽成「路径前缀匹配即可」，那会丢掉 symlink 逃逸防护；
- 20 处调用点各自的 `*_unpinned` 错误码保持不变，避免影响既有断言。

**3. `task_id` 作为路径段的校验**

`task_id` 现行 pattern 是 `/\Aotask_[a-z0-9][a-z0-9_-]{7,95}\z/`（`identifiers.rb:13`），本身已排除 `/` 与 `..`。但校验必须**显式发生在路径构造处**，不能依赖「调用方应该已经校验过」。写明在哪里校验、校验失败时的错误码。

**4. Task scope 如何传入**

四个 store 与 gate_engine 的 `initialize(active_root:)` 签名怎么变，调用方（含 55 处测试构造点）如何适配。

### C.2 Gate 3b：实现

Gate 3a 批准后再动代码。

**测试策略变更**：语义已随 `c198590` 冻结，此前的「完全不跑测试」约束解除，替换为：

- 允许 `ruby -c` 静态检查和**精确单方法**测试；
- **不要**先跑 focused suite 或 `tests/orbit_test.sh`；
- 增量收口后由我决定何时跑 focused。

**测试爆炸面 tripwire（必须遵守）**：

改完 `lib/` 后，先静态检查，然后**统计**测试破坏面并**停下上报**，不要自行大规模改 fixture。仓库里有 55 处 store 构造点和 11600 行 `contract_test.rb`，破坏面可能很大。报数后由我决定是继续修还是重新评估方案。

绝对禁止：为了让测试通过而修改产品规则或放松校验。测试反映的是旧模型，该改的是测试。

### C.3 Gate 3a / 3b 共同验收

- `git log -1` 应仍是 `c198590`（不要提交，除非我指示）；
- 三个不可触碰文件仍未被修改；
- Gate 3a 阶段 `git diff --name-only` 不得出现任何 `lib/` 路径。

---

## 5. 阶段 D：交付一条能跑的真实路径（新会话从这里开始）

前置状态（可用 `git log --oneline -3` 自行核对）：

```text
347fd05 docs(v2): record task-scopes naming and tracking decisions
0aaf95d feat(v2): scope durable stores to task-local roots
c198590 docs(v2): reset slice 6 to task-centric architecture
```

工作区应只有三个 untracked 文件（handoff、本工单、`rule_loading_case.md`）。

### D.0 为什么这一步最重要

`lib/orbit/v2` 有 24,531 行库代码、`contract_test.rb` 有 11,600 行测试，但 `git grep "V2::" -- lib/ ':!lib/orbit/v2'` 是**空的**——没有任何用户可运行的入口。这才是 Slice 6 至今未完成的真实含义。

在有一条真实可跑的路径之前，不要再增加任何 invariant、validator 或存储能力。

### D.1 目标路径

```text
init v2 project
  -> create/start one Task
  -> dispatch one Attempt
  -> submit Evidence
  -> independent review/test GateEvaluation
  -> resolve Finding if present
  -> derive outcome
  -> handoff/complete
```

以及两条验证：

1. Task A 与 Task B 的 `.orbit/task-scopes/` 路径不重叠，互不干扰。
2. 同一 Task 的不兼容 lineage 明确失败。

### D.2 Gate 5a：设计说明，**不写实现代码**

现状锚点（已核实，可直接用）：

- `lib/orbit/cli.rb` 是 220 行的命令分发器，`run_orbit_cli(argv)` 里 28 个 v1 命令（含 `init`、`new-task`、`dispatch`、`evidence`、`handoff`、`validate`、`state`、`wait-gate`）。
- 可执行入口是 `scripts/orbit`，由 `install.sh` 装到 bin-dir。
- v1 代码完全不加载 v2（`git grep "orbit/v2\|V2::" -- lib/ ':!lib/orbit/v2'` 为空）。

设计说明必须回答：

**1. provider-verified authority 从哪来（先答这个，它决定阶段 D 是小还是巨大）**

v2 的每个受控写入都要求 provider-verified 的 identity/authority assertion。真人在命令行敲一条命令时，这些 assertion 由谁产生、如何被验证？

这是最可能让范围爆炸的一点。如果答案是"要先建一套 provider 基础设施"，**立刻停下上报**，不要开工——那说明最小路径需要重新定义，可能要先做一个受控的本地 provider 或显式的信任降级，而那是需要用户决策的产品问题。

**2. 命令面**

最小命令集是什么？每条命令的输入、输出、失败模式。宁可少，不要全。

**3. 与 v1 共存**

v2 命令是加在现有分发器里（如 `orbit v2 <cmd>`）、还是别的形式？硬约束：**不得破坏任何现有 v1 命令**，cutover 是阶段 E 之后的事。

**4. 明确不做**

写清楚这一版**不**提供什么，避免被读成完整交付。

### D.3 Gate 5b：实现

Gate 5a 批准后才动代码。

- 只增不改：不得修改 v1 命令的行为。
- 不删 cross-control 代码，不改 `schemas/*.json`，不改 validator 语义。
- 测试纪律（AGENTS.md）：新增测试方法 ≤10、新增测试代码 ≤300 行。**优先一条真实 E2E，而不是一堆单元测试。**
- CPU 纪律沿用第 4 节：单进程串行；迭代用精确单方法；focused 只在最终收口跑，整个增量最多两次；开跑前看 `uptime`。
- 遇到必须改既有断言才能通过的情况：与既有裁决同型的直接套用并在报告里列明，确实是新类型的停下报我。

### D.3.1 Gate 5a 裁决记录（2026-08-17，审核方 wA:pD + 用户）

设计稿 `docs/open/orbit-v2-slice6-minimal-cli-path-design.md` 的三个待决事项已裁决。审核方独立核验了四个承重论据：`lib/` 内 `def issue` 命中 0；三个 verifier 均为 `initialize(providers: {})` 且 `validator.rb:143-148` 默认不带 provider；三个 `*_provider_unconfigured` 错误码；`gate.schema.json:110` 必填 `evaluator_attempt_id` 且 `independence_violation` 校验存在。均属实。

**裁决 1：本地 provider 信任模型 —— 批准，附条件。**

定性修正（写进 5b 交付物）：在阶段 D，本地 provider **不是安全机制，是一致性机制**。它对能读密钥的本地攻击者零防御（该攻击者本就能重写整个 `.orbit`）；它的真实作用是让生产验证路径真的执行而非被绕过。批准它不等于批准"Orbit 的安全模型是本地用户信任"。

**附加条件（5b 必做）**：设计稿 §1.4 的信任降级声明必须在 5b 提交时记入 `docs/open/orbit-v2-implementation-plan.md`（或新 ADR），使"替换为真实 provider"成为有据可查的欠账。理由：该声明现仅存于 untracked 工作稿，而 Slice 6 第一次跑偏正是"未确认的前提被静默继承"。

**裁决 2：密钥文件不提交进 git —— 推翻设计稿 §1.4 末的默认建议。**

理由：(a) 若 `.orbit` 不跟踪，第二个 worktree 缺的不只是密钥，而是 protocol.yaml/policy 在内的全部权威状态——这是 `.orbit` 整体跟踪问题，阶段 C 已裁决为"按项目自决、默认不跟踪"；(b) `.gitignore` 现为 `.orbit/*` + `!.orbit/README.md`，提交密钥需专门开 secret 例外，方向不对；(c) 阶段 D 不需要跨 worktree 验证——按 Gate 4 记录，默认不跟踪下的真实等价物是"两个 task-scopes 路径不重叠"，单仓库可验。

密钥由 `v2 init` 生成，落在既有 gitignore 覆盖下，无需任何 gitignore 改动。**5b 不得新增 gitignore 例外。**

**裁决 3：两次 dispatch —— 批准，不算范围膨胀。**

工单 D.1 的"dispatch one Attempt"是摘要简写，非约束。schema 必填 `evaluator_attempt_id` + 独立性校验机械要求 reviewer 拥有自己的 attempt，一次 dispatch 走不完 independent review。

**其余 5b 约束（沿用 D.3）：**

- 规模停止线收紧：设计稿 §5 预估 1100-1300 行。若 `document_factory` 单文件超 ~800 行仍收不了口，**停下上报**，不硬堆。
- 风险 4（`terminal` 的 successor 可空性）按设计稿所述，5b 开工第一步用精确单方法验证，结果写进报告。
- 风险 7 第 3 项（`RuleResolution.validate!` 的 project_root 不一致）按"与既有裁决同型直接套用"处理并在报告列明。

**前瞻提醒（阶段 E，5b 不处理）**：本仓库 `.orbit` 是 v1 live root（`.orbit/tasks/` 存有 v1 任务文件），`ProtocolRoot.create` 会对其抛 `protocol_root_mixed_epoch`。这是 ADR-005 no-in-place-upgrade 的正确行为，但意味着**阶段 E 的 dogfood 不能在本仓库现有 `.orbit` 上进行**，需要另择 root 或先做迁移决策。请勿在 5b 中顺手处理。

### D.4 待办事项（已记账，阶段 D 不要碰）

- 约 400 行 cross-control 死代码（单 control 下自动失效，不阻塞任何交付）；
- `lead-control.schema.json` 的 enum 与 `contract.yaml` 未对齐（见 plan「已知分歧」节）；
- `RuleResolution.validate!` 的 `project_root` 在 control_store 与 evidence_store 传值不一致（见设计文档 §6.5）。

---

## 6. 阶段 F：删除 v1

前置：`3d68d7b`（阶段 D 已提交）。用户已决策**先删 v1，再 dogfood**。

### F.0 决策依据（已核实，不要重新论证）

- **无用户**：`npm view @godokyang/orbit` 返回 404（从未发布）；GitHub public 但 1 star / 0 fork。
- **v2 零依赖 v1**：`lib/orbit/v2/` 下所有 `require_relative "../*"` 均解析在 v2 目录内部，无一行指向 v1。切口是干净的。
- **v1 已停用 17 天**：`.orbit/` 最后写入 2026-07-31；整个 Slice 6 用的是 git + docs，未用过一条 v1 命令。
- **ADR-005 本就以删除为终点**（L158「Cutover 必须删除或使下列路径无法继续写入…」）。

### F.1 两类可逆性（决定 Gate 划分，务必分开）

| 对象 | 可逆性 | 处置 |
| --- | --- | --- |
| v1 代码（36 文件 / 20,122 行） | **可逆**，在 git 历史里 | 直接删 |
| 本仓库 `.orbit/` 数据（130 文件 / 3.7M） | **不可逆**，`git ls-files .orbit/` 仅 README | 必须先备份到仓库外 |

### F.2 Gate 6a：删代码 + 换入口（可逆，先做）

删除：

- `lib/orbit/*.rb` 全部 36 个文件（注意：**不含** `lib/orbit/v2/` 子目录）
- `tests/orbit_test.sh`（274 行）
- `contracts/orbit-v2/legacy-v1-writer-reader-inventory.yaml`（v1 清单，随 v1 作废）

改写：

- **入口**：`scripts/orbit` 现在 `require lib/orbit/cli` 再 `run_orbit_cli(ARGV)`。改为直接 require `lib/orbit/v2/cli.rb` 并调 `run_v2_cli`。
- **命令面不变**：仍保持 `orbit v2 <cmd>`。去掉 `v2` 前缀是 UX 变更，**不在本增量做**——本增量只做减法，保持可审。
- `install.sh` 的显式文件清单（L152 起逐行列 v1 文件）改为列 v2 文件，否则装出来的 CLI 直接坏掉。`uninstall.sh` 同步核对。
- `package.json` 的 `"test"` 脚本引用了将被删除的 `tests/orbit_test.sh`。

测试调整：

- 删 `test_v1_inventory`、`test_slice_isolation`（连同阶段 D 加的 allowlist，一并作废）。
- `test_v2_entry_isolation_and_wiring`：「v1 启动路径零加载 v2」这一半失去意义，删；**真实入口接线那一半保留并加强**——它现在是唯一守护入口的断言。

验收：经 `scripts/orbit` 真实入口跑通 init → task start → dispatch ×2 → evidence → gate → finding resolve → complete；`contract_test.rb` 全绿。

### F.3 Gate 6b：停止对外说谎（agent-facing，必须做）

`skills/orbit/references/runtime/guide.md` 现在教 agent 跑 `orbit new-task` / `orbit state start` / `orbit evidence init` / `orbit revision create` / `orbit artifact inspect`；`skills/orbit/assets/templates/` 的 task.yaml / evidence.json / roles.yaml 是 v1 schema。这个 skill 装在 agent 环境里，v1 删除后它会**主动误导**。

本 Gate 的最低要求是**让它不再指向不存在的命令**——可以是停用标注、可以是改写为 v2 命令面。完整的 v2 runtime 文档重写（ADR-005 第 7 条）体量大，**不要求在本增量完成**，但必须明确标注当前状态，不得留下沉默的错误指引。

### F.4 Gate 6c：移除本仓库 v1 数据（不可逆，最后做）

`.orbit/` 下 130 个文件（evidence 17 / handoffs 24 / rules 14 / tasks 4 / test-artifacts 54 等）**不在 git 里**，删除不可恢复。

必须先按阶段 A 的先例备份到仓库外（如 `~/orbit-v1-data-backup-<date>/`），并在报告中给出可校验的备份证据，再移除。保留 `.orbit/README.md`（已跟踪）。

此 Gate 的目的是让本仓库能成为 v2 root（`reject_mixed_epoch!` 会因残留 v1 产物拒绝 v2 init）。

### F.5 硬约束

- **不宣称 cutover 完成**。ADR-005 有 12 条 cutover 条件，本增量只满足其中一部分。必须在 ADR-005 加修订记录，写明：v1 代码已删除；这**不等于** cutover 完成；仍未满足的条件逐条列出（至少含第 7 条 runtime 文档/模板/help、第 10 条 gate 正负向测试面）。这是本增量最重要的纪律项——否则半年后「v1 已删」会被读成「cutover 已完成」。
- **不改 `task-scopes` 命名**。改回 `tasks` 很有诱惑（v1 走了名字就空出来了），但删除 + 存储布局变更 = 同一增量两种风险。留作后续。
- **保留 `reject_mixed_epoch!` 与 `KNOWN_V1_AUTHORITY_PATHS`**。它现在防的是 v2 在残留 v1 数据上初始化（其他项目仍可能有）。移除它是独立决策，且与上一条的改名绑定。
- 测试预算与 CPU 纪律沿用第 5 节：单方法迭代，focused 最终收口，整个增量最多两次。
- 三个不可触碰文件不动。

---

## 7. 上报格式

每个 Gate 完成后回到 `wA:pD`，正文以 `DONE:` 或 `BLOCKED:` 开头，包含：

- 实际执行的命令与关键输出
- 与本工单期望值的逐项对账
- 任何你判断需要偏离工单的地方及理由

不要粘贴长 diff，写文件路径即可。helper 在 herdr skill 目录下，不在本仓库：

```bash
/Users/yangke/.claude/skills/herdr/scripts/herdr-msg wA:pD --task slice6-inc6j --kind reply <<'MSG'
DONE: 阶段 B 完成。<对账内容>
MSG
```

用 `herdr pane run` 手工发送等价，内容一致即可。

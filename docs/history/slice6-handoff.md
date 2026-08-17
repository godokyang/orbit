# Orbit v2 Slice 6 Handoff：暂停、复盘与纠偏路线

> **历史记录（2026-08-17 归档）**：本文记录 Slice 6 暂停时的状态与纠偏路线，其中的纠偏路线已执行完毕。正文的状态描述（含"当前生效 runtime：仍为 v1"）是**写作当时**的事实；同日 v1 已删除，v2 成为唯一 runtime。正文中的 `docs/open/...` 路径同理为当时状态，文档已重组，对照见 [docs/README.md](../README.md)。ADR-003/005/006 修订记录引用本文作为 task-centric 转向的背景。

- 日期：2026-08-17
- 状态：**PAUSED / 需要新对话重新冻结架构后再继续**
- 当前分支：`main`
- 当前 HEAD：`8bad815 feat(v2): derive durable gate outcomes`
- 当前生效 runtime：仍为 v1；Slice 6 尚未完成，v2 尚未 cutover
- 交接目的：让新对话不依赖旧长上下文，能够从可核验事实重新判断 Slice 6

## 1. 一页结论

Slice 6 原本负责把 Orbit v2 从合同/Validator 变成真实运行时，并完成 v1 → v2 clean cut。这个核心目的成立，不能用 Slice 1-5 的 bundle 校验代替。

但是，当前 Slice 6 把“同一项目内多个长期 Lead control 并行、Task 在 control 之间原子转移”当成了 cutover 前置条件，并在 Inc6j 开始实现一套 project-wide ownership、session transfer、connected-control bundle 和跨 store 锁协议。

用户已经明确纠正这一前提：

> 协作应由 Git branch/worktree 隔离；Orbit 资料按 `task_id` 唯一存放。不同 Task 路径不重叠，不需要项目级 Task ownership 或 cross-control transfer。

因此当前判断是：

1. Slice 6 的 ProtocolRoot、policy authority、Task 内原子写入、Evidence/Gate/Finding、CLI/E2E/cutover 仍然必要。
2. “同项目多 control + cross-control transfer”不是 Orbit MVP 的必要能力。
3. 未提交的 Inc6j 建立在错误前提上，不应继续补测试或扩展实现。
4. 已提交到 Inc6i 的代码不能盲目全部保留或全部推倒；必须按新的 task-centric 模型分为保留、改造、删除三类。
5. 下一步不是继续跑测试，而是先安全保存 Inc6j diff、撤销这批未提交变更、修订 ADR/plan，再做代码审计。

## 2. 原始目标与 Slice 6 的存在理由

Orbit v2 的目标是形成一条可恢复、可验证的闭环：

```text
ProtocolRoot / ProjectPolicy
  -> TaskRevision / WorkUnit
  -> Lead decision / Attempt
  -> Evidence
  -> GateEvaluation / Finding / FindingResolution
  -> derived outcome / handoff
```

Slice 1-5 主要完成 schema、权威关系、Validator 和派生投影。它们可以证明“一个最终 bundle 是否符合约束”，但不能证明真实运行时只会通过合法过程产生该 bundle。

Slice 6 的合理核心职责是：

- create-only ProtocolRoot 与 `protocol_epoch: orbit-v2`；
- user-controlled policy genesis 和受控 rotation；
- durable compare-and-append、幂等、损坏检测和恢复；
- 受控 Task/Attempt/Evidence/Gate writer 与 reader；
- provider-verified identity/authority；
- 一条真实 CLI E2E；
- mixed v1/v2 fail-closed；
- clean-install dogfood；
- 最终关闭 v1 fallback 并完成 cutover。

没有这些能力，v2 仍然只是合同模型，当前 runtime 仍是 v1。

## 3. 当前不可违反的约束

- 不运行 Orbit CLI。
- 不使用 code-review skill。
- 不读取、修改、暂存或提交 `docs/open/rule_loading_case.md`。
- 该文件当前是既有 untracked 文件，必须保持 untouched。
- 不在语义未冻结时运行完整 focused 或 `tests/orbit_test.sh`。
- 每个增量新增测试方法不超过 10 个。
- 每个增量新增测试代码不超过 300 行。
- 测试是验证手段，不得为了 fixture 或理论反例修改产品规则。
- 同一问题反复修复仍不能闭合时，停止加码，回到安全 checkpoint 重新判断方向。
- 工作区是共享的；不得把用户或其他 agent 的未提交内容当作可随意清理的数据。

## 4. 已经走过的提交路径

以下提交均已进入 `main`：

| 阶段 | Commit | 已落地内容 |
| --- | --- | --- |
| Inc1 | `0bd8389` | 原子 TransactionLog / durable compare-and-append |
| Inc2 | `9af6c95` | ProtocolRoot 与 root/epoch preflight |
| Inc3 | `9730660` | durable PolicyStore、provider-verified policy lineage/rotation |
| Inc4 | `6a2b001` | controlled control/session genesis |
| Inc5 | `e7e3b83` | controlled Task definitions |
| Inc6a | `982542f` | successor checkpoints / LogicalLead closure |
| Inc6b | `99826c3` | atomic dispatch + AttemptCreated + observation |
| Inc6c | `f3e97b1` | terminal reconciliation + recovery |
| Inc6d | `67a49c0` | Task definition successors |
| Inc6e | `75a6ec4` | TaskRevision proposal activation |
| Inc6f | `d6801fe` | durable Evidence acceptance |
| fixes | `71b3fca`, `3d2e841`, `384272c` | exact attempt resolution 与 fork/child lock preservation |
| Inc6g | `0ad5541` | GateEvaluation + Finding acceptance |
| Inc6h | `8772949` | FindingResolution + causal observation closure |
| Inc6i | `8bad815` | read-only GateEngine aggregate outcome projection |

### 最近一次已完成验证

- GateEngine 单方法：`ORBIT_V2_GATE_ENGINE_TARGET_PASS assertions=19`
- 完整 focused：`ORBIT_V2_CONTRACT_TESTS_PASS assertions=7746`
- 完整真实测试：`REAL_TESTS_PASS count=1104`
- 以上标记覆盖到已提交 HEAD `8bad815`。

这些结果不能证明当前未提交 Inc6j 正确。

## 5. 当前工作区事实

任务已暂停，当前没有 Ruby/contract/orbit_test 测试进程。

未提交 tracked 变更：

```text
M contracts/orbit-v2/contract.yaml
M lib/orbit/v2/control_store.rb
M lib/orbit/v2/validator/lead_control.rb
M tests/fixtures/orbit-v2/contract_test.rb
```

既有、受保护且未触碰的 untracked 文件：

```text
?? docs/open/rule_loading_case.md
```

Inc6j 精确 diff 规模（创建本 handoff 前）：

```text
contracts/orbit-v2/contract.yaml          +18 / -3
lib/orbit/v2/control_store.rb           +1090 / -102
lib/orbit/v2/validator/lead_control.rb     +20 / -6
tests/fixtures/orbit-v2/contract_test.rb  +282 / -0
合计                                      +1410 / -111
```

Inc6j 最后一个已知测试结果：

- 单方法目标：`INC6J_TARGET_PASS`
- 完整 focused：**未运行**
- `tests/orbit_test.sh`：**未运行**
- 静态/文档最终收口：**未完成**
- Inc6j：**未提交、不得宣称 stable/done**

## 6. 未提交 Inc6j 实际在做什么

Inc6j 当前实现的核心是 cross-control transfer：

- 新增 `ControlStore#transfer`；
- source control release Task，destination control acquire Task；
- 可选地同时 terminal source/destination session 并创建 successor session；
- 连接多个 control 的 registry/checkpoint/attempt/task facts；
- 验证 project-wide Task ownership、runtime subject 和 nonterminal Attempt；
- 让 transfer 后的 destination 执行普通 checkpoint/dispatch/terminal/activate/recover；
- 扩展多 Task queue activation；
- 固定 policy → task → control → evidence → gate 全局锁顺序；
- 一个约 282 行的 `test_control_store_transfer` 场景。

合同只在 `contract.yaml` 中部分同步；`validator-invariants.md` 与 `authority-matrix.yaml` 尚未完成同步。

这批实现不是简单 bugfix，而是在建设项目级多控制器运行时。它正是本次需要撤回并重新评估的部分。

## 7. 跑偏发生在哪里

错误前提是：

```text
同一项目需要多个长期 Lead control
  -> 每个 control 持有一组 Task
  -> Task 可在 control 间迁移
  -> 必须防止双重 ownership
  -> 必须设计 release/acquire/session transfer
  -> 必须增加 project-wide locks 和 connected bundles
```

但真实协作边界更简单：

```text
一个 Task
  -> 唯一 task_id
  -> 唯一 Orbit 资料目录
  -> 一个 Git branch/worktree
  -> Task 内自己的 revision/attempt/evidence/gate/handoff
```

不同 Task 写不同路径，Git 已经提供 workspace 隔离和最终 merge 边界。Orbit 应验证 Task 内事实闭环，不应成为第二个项目级并发调度平台。

执行层面的失误包括：

- 把规划文档中的高级架构能力默认当成首版真实需求；
- 没有在进入 Inc6j 前重新确认产品价值；
- 连续反例修复时没有回到安全 checkpoint；
- 把“完成所有理论 invariant”放在“交付一条真实 CLI 用户路径”之前；
- 在语义仍变化时多次运行耗时约 7 分钟的完整 focused suite；
- 让验证成本和复杂度超过了增量本身的用户价值。

## 8. 新的 task-centric 架构方向

建议重新冻结为：

```text
.orbit/
├── protocol.yaml                 # project-level，低频全局事实
├── policy/                       # project-level authority lineage
└── tasks/
    ├── <task-a>/
    │   ├── revisions/
    │   ├── control/
    │   ├── attempts/
    │   ├── evidence/
    │   ├── gates/
    │   ├── findings/
    │   └── handoffs/
    └── <task-b>/
        └── ...
```

冻结规则：

1. `task_id` 是协作、存储和冲突隔离单位。
2. 一个 Task 通常对应一个 Git branch/worktree。
3. 一个 Task 只允许一条 accepted control lineage。
4. 不同 Task 的路径不重叠，可以自然并行。
5. 项目级 task/status/index 是派生视图，不是共享可写权威。
6. 同一 Task 的并行修改是真实冲突，由 Git merge 和 Task lineage 校验发现。
7. agent/Lead 更换使用 Task 内 session replacement 或 handoff。
8. 不存在 cross-control Task transfer。
9. 不存在 project-wide Task ownership registry。
10. 不存在同项目多个 control 之间的 runtime-subject/session transfer。

### 仍应保留的 Slice 6 能力

- Canonical JSON、schema 与 document validation；
- TransactionLog 的原子性、幂等和损坏检测，但作用域应缩到 Task；
- ProtocolRoot / epoch；
- PolicyStore 与 provider verification；
- Task/Evidence/Gate/Finding exact binding；
- GateEngine deterministic projection；
- v2 CLI、真实 E2E、mixed epoch rejection、clean-install dogfood 和最终 cutover。

### 应改造成 Task-local 的能力

- TaskStore；
- ControlStore；
- EvidenceStore；
- GateFactStore；
- checkpoint/attempt lineage；
- snapshot/CAS/lock，只保护一个 Task 的原子操作。

### 应删除或重新论证的能力

- `ControlStore#transfer`；
- project-wide ownership sets；
- connected-control transaction assembly；
- multi-control session/runtime-subject transfer；
- 为不同 Task 设置的全局五层锁；
- project-wide mutable task/control registry；
- “不同 control 的 Task/runtime-subject sets 必须 disjoint”整套协议。

## 9. 推荐继续步骤

### 阶段 A：可恢复地收回 Inc6j

这一步包含撤销未提交变更，必须获得用户明确授权后执行。

1. 只把上述 4 个 tracked 文件的 binary diff 保存到仓库外的持久位置或专用安全分支。
2. 明确排除 `docs/open/rule_loading_case.md`。
3. 将 4 个 tracked 文件恢复到 HEAD `8bad815`。
4. 核对工作区只剩既有 protected untracked doc 和本 handoff。
5. 不运行测试；HEAD 已有完整绿色标记。

不要直接 `git reset --hard`，不要递归清理工作区。

### 阶段 B：只做文档级架构重置

在写 production code 前修订：

- ADR-003：Lead/control 改为 Task-scoped，不承担 project-wide scheduler；
- ADR-005：cutover 不再要求 cross-control Task/session transfer；
- ADR-006：串行边界改为 per Task；跨 Task 并行交给 branch/worktree；
- implementation plan：重写 Slice 6 E2E 和 done criteria；
- contract docs：删除 deferred/required cross-control transfer 语义。

文档必须明确：这是产品范围修订，不能把缩减后的 MVP 冒充原 ADR 全部完成。

### 阶段 C：审计已提交代码，不立即修复

输出一个保留/改造/删除表：

- 哪些文件完全符合 task-centric 模型；
- 哪些文件只需要路径或 scope 调整；
- 哪些代码只服务 project-wide multi-control；
- 哪些 public API/contract 已受影响；
- 最小安全迁移顺序。

先报告审计结果，等待用户确认，再开始删除或重构。

### 阶段 D：交付最小真实路径

优先完成一条用户可运行路径：

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

同时验证：

1. Task A 与 Task B 在不同 branch/worktree 下没有 Orbit 路径冲突。
2. 同一 Task 的不兼容 lineage 明确失败或产生 Git 冲突。

### 阶段 E：dogfood 后再决定 cutover

用 Orbit 自己完成一个真实中等规模任务，评估：

- 是否更容易恢复主目标；
- handoff 是否真的降低上下文损失；
- evidence/gate 是否改善归因；
- 文件数量、命令复杂度和维护成本是否可接受；
- 两个独立 Task 分支能否无冲突合并。

实际价值成立后，才继续 v2 CLI 全量替换、v1 rejection、runtime docs 更新和 clean-install cutover。

## 10. 新验收预算

建议首个 task-centric MVP 只保留约 6 个高价值场景：

1. 单 Task 完整 happy path。
2. 两个 Task 的路径/分支隔离。
3. 同一 Task fork/reuse 冲突拒绝。
4. Evidence 与 Attempt/Task exact binding。
5. unresolved Finding 阻止完成，合法 resolution 后通过。
6. wrong/mixed protocol epoch 拒绝。

纪律：

- 测试方法 ≤10；新增测试代码 ≤300 行。
- 语义稳定前只跑静态检查和精确单方法。
- focused 在增量收口后跑一次。
- `tests/orbit_test.sh` 在 focused 通过后跑一次。
- 同一区域连续失败并引发新业务分支时，停止并重新评估，不继续堆 patch。

## 11. 新对话不要做的事

- 不要继续 Inc6j 的下一个失败点。
- 不要先跑完整 focused 或 full suite。
- 不要把当前 Inc6j 单方法 PASS 当成设计正确证明。
- 不要未经授权恢复/删除未提交文件。
- 不要为了保留已写代码而维护 cross-control 兼容层。
- 不要先实现全局 task index、scheduler、portfolio 或 multi-control runtime。
- 不要让测试 fixture 决定产品语义。
- 不要宣称 Slice 6 或 v2 cutover 已完成。

## 12. 新对话建议起始指令

可直接把下面内容交给新对话：

```text
阅读 docs/open/orbit-v2-slice6-handoff.md，先独立核对 git status、HEAD 和 Inc6j diff。
不要运行 Orbit CLI，不使用 code-review skill，不触碰 docs/open/rule_loading_case.md，不跑测试。

第一步只评审 handoff 中的 task-centric 架构纠偏是否成立，并输出：
1. Inc6j 安全备份与撤销的精确文件范围；
2. ADR-003/005/006 和 Slice 6 plan 的最小修订清单；
3. 已提交 Inc1-Inc6i 的保留/改造/删除矩阵。

没有得到确认前，不撤销工作区、不修改 production code、不增加测试。
```

## 13. 当前交接状态

- 任务：已暂停。
- 测试进程：无。
- 最后已验证提交：`8bad815`。
- Inc6j：未提交、仅单方法 PASS、设计前提已被否定。
- 下一 gate：用户确认 task-centric 架构重置，以及是否授权安全备份并撤销 Inc6j。
- 当前不能宣称：Slice 6 完成、v2 激活或 cutover ready。


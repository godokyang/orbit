# Orbit 欠账台账

- 最后更新：2026-08-17
- 性质：本文是**唯一的欠账出处**。各交付阶段发现但有意推迟的项目集中记在这里，不再散落在 slice 计划里。
- 用法：动到相关代码前先查本表。新增欠账写明**为什么推迟**与**解除条件**，不写"以后再说"。

## 索引

| # | 欠账 | 触及面 | 风险 | 解除条件 |
| --- | --- | --- | --- | --- |
| 1 | 本地 provider 是一致性机制而非安全机制 | `lib/orbit/v2/local_provider.rb` | 中 | 阶段 J 可信观测者成为真实 provider |
| 2 | `.cli-clock` 是日志之外的第二时间真值源 | `lib/orbit/v2/cli.rb` | 低 | 改为从 TransactionLog 自身推导 |
| 3 | `lead-control.schema.json` 仍含 cross-control enum | `contracts/orbit-v2/schemas/` | 低 | 与 store 改造同批，须有测试兜底 |
| 4 | cross-control 语义残留代码 | lib ×6 / contracts ×3 | 低 | 确认自我中和后统一删除 |
| 5 | 命令面双拼法未定形 | `lib/orbit/v2/cli.rb` | 低 | cutover 前定 |
| 6 | v2 runtime 文档未重写 | `skills/orbit/references/runtime/` | 中 | 阶段 G 之后 |

---

## 1. 本地 provider 信任降级（阶段 D 裁决，2026-08-17）

阶段 D 的最小真实 CLI 路径引入**本地 HMAC provider**（`lib/orbit/v2/local_provider.rb`，密钥文件 `.orbit/local-provider.json`，由 `init` 生成、落既有 `.orbit/*` gitignore 覆盖、不提交）。

工单 D.3.1 已定性：**在阶段 D 它是字符串一致性机制，不是安全机制**——对能读取密钥文件的本地攻击者零防御（该攻击者本就可以重写整个 `.orbit`）。它的真实作用是让生产验证路径（`AuthorityVerifier` / `RuntimeIdentityVerifier` / `LifecycleVerifier` 的 receipt 验证）真的执行而非被绕过。批准它**不等于**批准"Orbit 的安全模型是本地用户信任"。

**风险**：`local.hmac.*` 三个 provider id 及其密钥文件参与 policy genesis 后即成为项目持久权威事实；密钥文件丢失 = 项目不可再验证（fail closed，无恢复路径）。

**解除条件**：替换为真实外部 provider 属**产品级决策**，需用户批准。[愿景计划](./vision-completion-plan.md)阶段 J 是这笔欠账的自然归宿——可信观测者（测试运行器、仓库扫描器）本身成为 provider，事实来源从"CLI 递什么就签什么"变成"测出来什么就是什么"，不需要单独立项。

## 2. `.cli-clock` 第二时间真值源（阶段 D 记账，2026-08-17）

v2 CLI 的跨命令时间单调依赖旁路文件 `.orbit/task-scopes/<task_id>/.cli-clock`（每次发戳取 `max(now, last+1s)`）。

已核实 store 不枚举 task 目录内文件，该文件今天不会被误当权威事实，**无现行 bug**。

**风险**：持久事实的时间戳因此存在日志之外的第二个真值源。该文件丢失或被编辑后，CLI 可能发出相对既有日志倒退的时间戳。

**更稳健做法**：从四个 `TransactionLog` 自身推导上一时间戳（自愈、无第二真值源）。阶段 D 有意不改实现。

## 3. `lead-control.schema.json` 与 contract.yaml 的 enum 分歧（阶段 B 记账，2026-08-17）

`contracts/orbit-v2/schemas/lead-control.schema.json` 尚未与 2026-08-17 已修订的 `contract.yaml` enum 对齐，仍含：L127 `task_transfer_acquire` 定义、L301-310 `TaskAcquire`（L303 `released_*` required 块）、L726 action enum 的 `release/suspend/acquire`、L753-754 event enum 的 `task_suspend/task_acquire`。

**为什么推迟**：与 `contract.yaml`（仅被 tests 读取的规格文件）不同，`schemas/*.json` 经 `schema_catalog.rb` 被 lib 运行时加载（control_store、evidence_store、gate_fact_store、policy_store、protocol_root、rule_resolution），修改属 **production 变更**——删 enum 值会使既有合法文档立即失效，冲击面直达 contract_test fixture。

**解除条件**：须与 store 路径改造同批进行，届时才有测试兜底。

## 4. cross-control 语义残留代码

2026-08-17 的 task-centric 修订否定了「同项目多个长期 Lead control 并行 + Task 在 control 之间转移」，但相应代码未删除。

**现状测量**（2026-08-17，`task_transfer|task_acquire|task_suspend|released_from|cross_control|cross_lineage` 命中计数）：

```text
lib/orbit/v2/validator/lead_control.rb        20
lib/orbit/v2/validator/runtime_lifecycle.rb    3
lib/orbit/v2/control_store.rb                  3
lib/orbit/v2/lead_control.rb                   2
lib/orbit/v2/gate_engine.rb                    2
lib/orbit/v2/validator.rb                      1
lib/orbit/v2/cli/document_factory.rb           1
contracts/orbit-v2/schemas/lead-control.schema.json   3
contracts/orbit-v2/authority-matrix.yaml              3
contracts/orbit-v2/validator-invariants.md            1
contracts/orbit-v2/contract.yaml                      1
```

**行数规模未复核**——上表是命中计数，不是删除规模。删除前需先测量。

**为什么可以推迟**：在"一个 Task 一条 accepted control lineage"的模型下，这些路径大多**自我中和**（cross-control 场景无法构造），属死代码而非错误行为。

**风险**：死代码会误导后来的阅读者以为该能力存在。

## 5. 命令面双拼法未定形

`orbit v2 <cmd>` 与裸 `<cmd>` 并存的最终形态待定。出处：ADR-005 修订记录。

## 6. v2 runtime 文档未重写

ADR-005 cutover 条件第 7 条要求 `skills/orbit/references/runtime/` 只描述已实现的 v2。当前 `core-operating-model.md`（947 行）与 `guide.md`（465 行）是 v1 内容，只加了停用标注。

**风险**：agent 读到 v1 操作模型会按已删除的命令行事。

**解除条件**：[愿景计划](./vision-completion-plan.md)阶段 G 重切规则库时一并处理；阶段 G 本身不含这两份文档的重写。

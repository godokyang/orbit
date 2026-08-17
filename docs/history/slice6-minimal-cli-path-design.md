# Orbit v2 Slice 6 阶段 D 设计说明：最小真实 CLI 路径（Gate 5a）

- 日期：2026-08-17
- 执行：wA:pF（omp）；审核：wA:pD
- 基线：`347fd05`（阶段 C 已提交）
- 状态：**设计稿，待批准。本文档不含任何已实施的代码改动。**
- 工单：[slice6-workorder](./slice6-workorder.md) 第 5 节

## 0. 现状盘点（设计输入）

以下事实均在 `347fd05` 上实测核实：

- **无用户可运行入口**：`git grep "V2::" -- lib/ ':!lib/orbit/v2'` 为空（今日复测仍为
  0 行）。可执行入口是 `scripts/orbit` → `lib/orbit/cli.rb` 的 `run_orbit_cli(argv)`，
  220 行、28 个 v1 命令的 case 分发；v1 代码不加载任何 v2 文件。
- **体量**：`lib/orbit/v2`（含 `validator/`）实测 23,860 行 `.rb`（工单写 24,531，
  差异应为统计口径，不载荷）；`contract_test.rb` 11,600 行。
- **三个 verifier 全部是构造器注入**：`AuthorityVerifier` / `RuntimeIdentityVerifier` /
  `LifecycleVerifier` 均为 `initialize(providers: {})`，按 `assertion["provider_id"]`
  查进程内 provider 对象并调用其 `verify(...)`（各文件 12-60 行）。
  `validator.rb:145-147` 的默认构造**不带任何 provider**。
- **lib/ 内零个 provider 实现**。仓库里唯一的 provider 实现在
  `tests/fixtures/orbit-v2/fixture_factory.rb:67-196`：三个 `Fake*Provider`，
  HMAC-SHA256 + 硬编码 secret，`issue`/`verify` 两方法。
- **无 provider 必失败**：provider-less verifier 对任何 assertion 抛
  `authority_provider_unconfigured` 等；`contract_test.rb:3858-3860` 的负向测试
  正是靠这一点构造失败。因此真实 CLI **必须**在进程内构造 provider。
- **provider 注册表不在盘上**：每次进程构造。但 `provider_id` 经
  marker → policy genesis（`authorization_assertion_digest` 钉 assertion）→
  assertion → receipt 传递性地被钉死：换 provider id 或换密钥，`preflight`/
  `resolve` 全链重放即失败。密钥一旦参与 genesis 就是项目持久权威事实。
- **受控写入序列**（`contract_test.rb:4373-4388` 及 store 公开 API）：
  policy genesis + ProtocolRoot.create → TaskStore.genesis → ControlStore.genesis
  → activate → dispatch → EvidenceStore.accept → GateFactStore.accept
  （→ accept_resolution）→ ControlStore.terminal → `AggregateOutcome.derive`。
  每步都要 assertion/receipt，dispatch/terminal 还要 runtime identity 与
  lifecycle writer receipt。
- **独立性是机械约束**：`evidence_evaluation.rb:248-259`——`independent_evaluator`
  要求评估者的 runtime identity（provider_id + runtime_subject_id）不与任何
  subject producer 重合；且 `GateEvaluation` schema 必填
  `evaluator_attempt_id` + `evaluator_submission_record_id`。**review 侧需要
  自己的 dispatched attempt**（fixture 的 `role: "reviewer"` 分派同理）。
- **rule resolution 不可为空**：`rule-resolution.schema.json` 对
  `required_rules` 有 `minItems: 1`，且 `RuleResolution.build` 逐条对
  `project_root` 下真实文件校验 sha256（`rule_resolution.rb:60-68`）。
  `skills/orbit/references/runtime/*.md` 在仓内存在，可作为默认规则文件。
- **repository_snapshot 是闭形状**：`{kind: "git", commit_sha: 40-hex,
  tree_digest: sha256:...}`（`code_surface.rb:55-63`）；tree 枚举器属 provider 侧，
  本地 CLI 需自定义一个确定性枚举。
- **v2 无 handoff 实体**：`git grep handoff -- lib/orbit/v2` 仅命中 v1 权威路径
  清单。D.1 的 "handoff/complete" 在 v2 语义 = `ControlStore.terminal`（终态化
  attempt + 后继 checkpoint）+ `AggregateOutcome.derive`（输出 closed/outcome）。

## 1. 问题 1：provider-verified authority 从哪来（先答）

### 1.1 结论与规模判断

**lib/ 中不存在任何 provider 实现；最小真实路径必须新增一个受控的本地 provider
（authority + runtime identity + lifecycle writer 三合一）。** 预计 ~150 行 Ruby +
一次性密钥文件管理，形态对齐 fixture 的 `Fake*Provider`。

这**不是**「一套 provider 基础设施」：verifier 缝隙是刻意依赖注入的，provider 接口
只有 `issue`/`verify` 两个方法、无外部依赖、无网络、无守护进程、无轮换逻辑。
但它**是一次显式信任降级**（信任根 = 本地机器用户），按工单 D.2 的定义属于
「需要用户决策的产品问题」。**本文档给出推荐方案；批准本节即视为对该信任模型的
裁决。未获批准前不动任何代码。**

### 1.2 assertion 的产生与验证机制（以 dispatch 为例）

1. CLI 进程读 `.orbit/local-provider.json` 密钥文件，构造三个本地 provider 与
   三个 verifier（每命令一次，进程内复用）。
2. CLI 的文档工厂构造 assertion：`issuer_kind: "user"`（策略/工作授权）或
   `"control_plane"`（checkpoint writer），`issuer_subject` 取密钥文件里的本地身份，
   `grants` 取 policy `authority_grants` 已列出的 action，
   `assertion_digest` 由 `AuthorityVerifier.assertion_digest` 的排除规则计算。
3. `LocalAuthorityProvider.issue(assertion)` 产生
   `verification_receipt = hmac-sha256(secret, CanonicalJSON(receipt body))`，
   receipt 绑定 assertion_digest / project_id / assertion_id / issuer / grants。
4. 写入路径 `store.dispatch(..., authority_verifier:)` → `verify!(assertion)` →
   按 `provider_id` 查 provider → 结构绑定校验（`authority_verifier.rb:26-36`）→
   `provider.verify(receipt)` 重算 HMAC 比对。
5. 落盘后一切读取（`resolve`/`preflight`）重放同一验证：跨进程一致性完全由
   密钥文件保证，无数据库、无服务。

### 1.3 本地 provider 设计

- 新文件 `lib/orbit/v2/local_provider.rb`：`LocalAuthorityProvider` /
  `LocalRuntimeIdentityProvider` / `LocalLifecycleProvider` 三个小类共享一个
  HMAC secret 模块；`verify` 一律常量时间比较（fixture 已有同型实现可移植）。
- provider id 固定 `local.hmac.v1`（三个 provider 分别为
  `local.hmac.authority` / `local.hmac.runtime` / `local.hmac.lifecycle`，
  写进各自 receipt）。
- 密钥文件 `.orbit/local-provider.json`：扁平文件，不新增目录
  段（避免任何与 `KNOWN_V1_AUTHORITY_PATHS`（8 个 v1 权威名）的新交互；
  `reject_mixed_epoch!` 不受影响）。内容：
  `{schema_version, provider_id, secret: <32B hex>, issuer_subject, created_at}`，
  权限 0600，`orbit v2 init` 时生成。
- 密钥丢失 = 项目不可再验证（全链 fail closed，无恢复路径）。**备份责任显式
  写进 init 输出**。密钥轮换/provider 替换明确不在本阶段（见 §4）。

### 1.4 显式信任降级声明（必须被批准的句子）

> 本地 provider 把信任根设为**本地机器用户**（与 git 对提交完整性的地位相同）。
> receipt 防的是：手工篡改日志、跨项目/跨 task 混淆、digest/receipt 结构不一致、
> 跨进程不一致签名。**不防**能读取密钥文件的本地攻击者——该攻击者本就可以
> 重写整个 `.orbit`。

密钥是否提交进 git：默认建议**提交**。理由：task=worktree 模型下每个 worktree
的 `.orbit` 是独立工作树副本，不提交则第二个 worktree 无法验证同一项目权威
（preflight fail closed）；而 HMAC 密钥在此威胁模型下不是机密性边界（信任根本来
就是本地用户）。与阶段 C 设计 §1.1「`.orbit` 是否纳管由项目自决」一致。
**此项单独呈审核方裁决。**

### 1.5 被否决的替代方案

- **外部 provider**（OIDC / API token / 平台身份）：真实基础设施，范围爆炸，不做。
- **跳过 provider 验证的信任降级**：必须改 verifier 判定语义，违反 D.3
  「不改 validator 语义」，不做。
- **复用 fixture Fake\*（硬编码 secret）**：等于无密钥，仅形态可借鉴，不做。

## 2. 问题 2：命令面

原则：**每条命令 = 恰好一个受控写入边界（或一个只读投影）**；深结构文档一律
YAML 文件输入，CLI 只负责身份/digest/receipt 字段的合成。共 8 条，命名空间
`orbit v2 <cmd>`。

| 命令 | 输入 | 输出 | 主要失败模式 |
| --- | --- | --- | --- |
| `v2 init <project_id> [--policy file]` | 项目根（cwd） | 密钥文件、`policy_revision_id`、marker 路径、自检 preflight 结果 | `protocol_root_mixed_epoch`（v1 权威产物在场）、`protocol_root_reuse`（异内容重放）、`policy_store_genesis_invalid` |
| `v2 task start <task_id> --def task.yaml` | task 定义（objective、gate requirements、work units、theses、rule 文件清单） | `task_revision_id`、`control_id`、genesis checkpoint id | `task_store_genesis_invalid`、`control_store_genesis_invalid`、`activation_invalid`；task 定义可先落盘而 control 失败（重试幂等，见 §6.3） |
| `v2 dispatch --task id --role implementer\|reviewer --unit owu_x [--subject s]` | task/control 现状 | `attempt_id` | `rule_resolution_digest`（规则文件变动）、`control_store_dispatch_invalid` |
| `v2 evidence submit --task id --attempt id --proposal file` | evidence proposal（claims/artifact refs） | `evidence_record_id` | `derived_input_invalid`（快照形状）、evidence acceptance 各码 |
| `v2 gate submit --task id --def evaluation.yaml` | 评审结论（verdict、answers、findings） | `gate_evaluation_id`、finding id 列表 | `independence_violation`（评估者与 producer 同 subject）、acceptance 各码 |
| `v2 finding resolve --task id --def resolution.yaml` | resolution（waive/fix 佐证） | `finding_resolution_id` | resolution authority/lineage 各码 |
| `v2 complete --task id` | task/control 现状 | terminal checkpoint id + derive 结果（closed、outcome） | 未决 blocking finding 拒绝终态化；`closed=false` 时显式输出未满足项 |
| `v2 status --task id` | 只读 | task tip、active attempt、evidence/gate/finding 摘要 | resolve 各码；无 `--task` 时仅列 `task-scopes/` 目录（派生视图，不建 index） |

流程对应 D.1：`init → task start → dispatch(implementer) → evidence submit →
dispatch(reviewer) → gate submit → (finding resolve) → complete`。

两个必须说明的偏差：

1. **两次 dispatch**。工单 D.1 写「dispatch one Attempt」，但合同层独立性
   （§0 第 7 条）要求 GateEvaluation 引用独立评估者 attempt。E2E 需要一次
   implementer dispatch + 一次 reviewer dispatch。这不是范围膨胀，是
   「independent review」的机械含义。
2. **subject 默认值**：implementer/evidence 默认 runtime subject
   `local.<issuer_subject>`；`gate submit` 默认 `local.<issuer_subject>.reviewer`，
   保证默认路径满足独立性；`--subject` 可显式覆盖（覆盖错则 independence 校验
   fail closed，不静默）。

所有命令成功 exit 0 + 人读摘要（id 与短 digest）；失败 exit 1 + `code: message`
（`ContractError` 自带 code/message/path）。store 是全有或全无事务，CLI 的职责是
在任何 store 调用前完成参数校验，不留半写。

## 3. 问题 3：与 v1 共存

- **唯一 v1 改动点**：`run_orbit_cli` case 里新增一个 `when "v2"` 分支（约 3 行），
  惰性 require 后转发到新文件 `lib/orbit/v2/cli.rb` 的 `run_v2_cli(argv)`。
  v1 启动路径保持零加载 v2（现有 grep 不变量不被破坏，且可被 E2E 断言）。
- 不改 `scripts/orbit`、`install.sh`、任何既有 when 分支、任何 v1 帮助文本主体。
- **两纪元互斥是内建的**：`ProtocolRoot.create` 对含 v1 权威产物（`.orbit/runtime`、
  `tasks`、`evidence` 等 8 项）的 root 抛 `protocol_root_mixed_epoch`；反之 v1
  命令不读 `.orbit/protocol.yaml`。同一 root 不可能同时充当 v1 与 v2 权威。
- 验证：v1 命令行为零变化由「只增一个 when 分支 + 既有 v1 测试不动即绿」保证；
  Gate 5b 收口时跑一次 focused（工单允许的两次之内）。

## 4. 明确不做（防止被读成完整交付）

- 不做 policy rotation CLI（只 genesis）。
- 不暴露 retry/fuse/budget override/checkpoint-due observation 等控制流命令
  （库内已实现，D.1 不需要）。
- 不做跨 task 查询、全局 task index、scheduler、portfolio。
- 不做密钥轮换、多 provider 配置、远程/外部 provider。
- 不做 LeadControl session replacement / handoff 命令（D.1 的 complete =
  terminal + derive；session replacement 属后续阶段）。
- 不动 gate-engine closure（维持 deferred 状态）、`schemas/*.json`、
  validator 语义、cross-control 代码（沿用 D.3）。
- 不宣称 Slice 6 完成、v2 激活或 cutover ready。

## 5. Gate 5b 落地清单与规模预估（供决策参考）

| 文件 | 性质 | 预估 |
| --- | --- | --- |
| `lib/orbit/v2/local_provider.rb` | 新增 | ~150 行 |
| `lib/orbit/v2/cli.rb`（子命令路由 + 8 命令） | 新增 | ~350 行 |
| `lib/orbit/v2/cli/document_factory.rb`（policy/task/control/dispatch/evidence/evaluation/resolution 最小 builder，自 fixture 移植） | 新增 | ~600-800 行 |
| `lib/orbit/cli.rb` | +1 when 分支 | ~3 行 |

- 测试：**1 条真实 E2E**（子进程跑 `run_v2_cli`，临时 git repo，两 task 全流程），
  映射 handoff §10 场景 1+2；场景 3（同 task 不兼容 lineage 拒绝）视预算加 1 个
  精确方法；场景 4-6 已有 store 级合同测试覆盖。总量守 ≤10 方法 / ≤300 行。
- 文档工厂是 5b 的真实工作量所在（sealed digest 链、checkpoint predecessor/
  trigger 结构），不是 provider。若实现中超过 ~1000 行仍收不了口，按 D.3 精神
  停下上报，不硬堆。

## 6. 风险与开放问题（呈审核方）

1. **信任降级裁决（最大项）**：本地 provider = 本地用户为信任根（§1.4）。
   需要显式批准；这是进入 5b 的前置条件。
2. **密钥是否入 git**（§1.4 末）：默认建议提交，理由已列；呈裁决。
3. **`task start` 的跨 store 半程**：TaskStore.genesis 与 ControlStore.genesis 是
   两个独立事务；control 失败时 task 定义已落盘（孤儿定义无害，重试走
   idempotent 分支）。接受，不引入补偿事务。
4. **terminal 的 successor 语义**：`ControlStore.terminal` 要求 successor
   checkpoint；`successor_attempt` 在终态完成（无后继分派）时是否可空需在 5b
   开工第一步用精确单方法验证；若不可空，`complete` 需要合成终态后继 checkpoint
   （fixture 已有同型先例），不改库。
5. **tree_digest 枚举器**：本地 CLI 定义为 `sha256(git ls-tree -r --full-tree HEAD
   的规范输出)`；唯一硬要求是跨运行一致（evidence exact-binding 依赖）。
6. **rule 文件绑定**：dispatch 时规则文件内容被 sha256 钉死；规则文件后续变动会使
   新 dispatch 的 digest 校验失败——这是合同语义（fail closed），CLI 不做缓存或
   宽容。
7. 工单 D.4 三项已记账事项（cross-control 死代码、schema enum 分歧、
   `RuleResolution.validate!` 的 project_root 不一致）本阶段不碰；其中第 3 项会
   直接影响 CLI 的 evidence 路径取值，5b 实现时按「与既有裁决同型直接套用」处理
   并在报告列明。

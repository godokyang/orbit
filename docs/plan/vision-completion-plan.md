# Orbit 愿景达成计划

- 日期：2026-08-17
- 基线：`63b9d83`（阶段 F 完成，v1 已删除）
- 状态：**计划稿，待批准**。本文不构成任何已实现能力的声明。
- 性质：本文是交付计划（non-normative）。语义权威仍是 ADR-003/004/005/006 与 contracts；冲突时以 ADR 为准。

## 0. 目标定义

产品目标（owner 2026-08-17 确认）：

> **Orbit 是一个能在合理范围内自动实现需求代码的控制流。目前所有的控制都是为了这个目的；事实可追溯、不可抵赖等是附属好处，不是目标。**

这个定位改变了完成度的算法：evidence/gate 那条脊柱是**基础设施**，控制循环才是**产品**。

### 验收（两个场景，缺一不可）

**场景 A（能跑完）**：给一个真实的小需求，Orbit 无人值守运行，产出通过独立评审的代码，以 `completed` 停止。

**场景 B（能停住）**：给一个会漂移或超预算的需求，Orbit **在边界处停下**，以 `frozen` 或 `needs_user` 停止，并说明缺什么。

场景 B 比 A 更重要。愿景不是"能自动化"，而是"能在**合理范围内**自动化"——边界才是产品。只有 A 通过而 B 不通过，等于造了一个跑得更快的失控循环。

## 1. 现状分账（2026-08-17 实测）

| 层 | 状态 | 证据 |
| --- | --- | --- |
| 事实/审计层 | ✅ 建成，且超建 | `lib/orbit/v2` 24,531 行；`contract_test.rb` 11,600 行 |
| 决策层 | ✅ 建成，❌ 无出口 | `LeadControl.reconcile(facts, trigger) -> LeadDecision` 751 行，四互斥停止态、budget bindings、fingerprint 齐备 |
| 上下文投递层 | ✅ 建成，❌ 无出口 | `ContextProjection.lead / work_agent / evaluator`；work_agent 已按 unit refs 裁剪 acceptance/evidence/source requirements 并钉 plan+basis digest |
| 规则内容层 | ⚠️ 有素材，未接线 | 901 行手艺规范（coding 370 / testing 267 / quality 264）；按角色而非任务组织；无 `description` 元数据；无反向约束；`--rule` 无默认值——**Orbit 现在不自带任何可用规则** |
| CLI | ⚠️ 只有脊柱 | 8 条命令覆盖 evidence/gate；控制流命令（retry/fuse/budget override/checkpoint 观测）库内已实现但未暴露 |
| 执行层 | ❌ 不存在 | `lib/orbit/v2` 全部子进程调用只有 `git rev-parse`、`git ls-tree` 与 `Process.pid`（文件锁）。**v2 不能让任何事发生** |

反复出现的模式：**能力建好了，但没有出口。** 本计划的大部分工作是接线与内容，不是新建底座。

### 已删除但可参考的实现

v1 曾有执行层，在 `8b5ab8c` 删除，可从 `8b5ab8c^` 取回参考（**不是复用**，v2 契约不同）：

| 文件 | 行数 |
| --- | --- |
| `lib/orbit/task_herdr_probe.rb` | 1,227 |
| `lib/orbit/task_herdr_exec.rb` | 982 |
| `lib/orbit/task_launch_dispatch.rb` | 559 |
| `lib/orbit/runtime_commands.rb` | 362 |
| `lib/orbit/herdr_probe.rb` | 72 |

建执行层前必须先读这 3,202 行，不要从零重造启动与探测逻辑。

## 2. 关键设计判断（讨论结论，作为计划前提）

**Orbit 不能让 AI 在循环中持续守规则。** 它在 agent 外层，够不到内循环。它能做且只能做三件事：

1. **投递**：attempt 开始时交付 bounded context（含钉死的规则）；
2. **让 attempt 短到规则不失效**：这是 bounded work unit 的第二个理由——规则第 1 轮注入、第 40 轮已被稀释（ADR-003 引的多轮下降与 Lost in the Middle）。**规则的生效方式是每次 attempt 重新投递，不是持续约束**；
3. **事后独立复核**：评审者拿到逐字节相同的规则（同一 `effective_verification_plan_digest`），digest 证明双方同本。

**控制代码不判断"符不符合规范"。** ADR-003 决策九：机械规则只管 refs/digest/lineage/cardinality/budget 记账；语义判断属 Lead，verdict 属独立评审。原文："软判断不得伪装成 validator correctness。"

**推论：循环的质量上限由评审 agent 的判断力决定，而规范文件是评审者的判据。** 所以 `references/` 是产品的有效载荷，控制代码是运货车。**规则不到位时先做 runner，等于自动化地产出不受约束的工作。**

**规则是项目里的真实文件。** `rule_resolution` 存 path + content_sha256，用 `project_root/path` 的真实字节重算比对。后果：改规则文件会让使用它的新 dispatch fail closed——**改规则是有版本的事件，不是静默编辑**；且任务化切分能让规则演进只影响相关 attempt。

## 3. 计划

五个阶段，按依赖排序。每阶段先设计后实施，沿用既有 Gate 模式。

### 阶段 G：规则库最小可用集

**为什么排第一**：它是有效载荷；且规则会被 sha256 钉进每次 dispatch，切错了比代码写错贵。

#### 裁决 1（2026-08-17）：规则文件装进用户项目，随项目版本化

依据是既有合同已经做过这个选择。`rule_resolution.rb` 的 `canonicalize_path!` 叠了三条约束：路径必须是项目相对 POSIX 路径（禁 `..`、禁绝对路径）；要过 `File.realpath` 解析符号链接；解析后必须仍在 `project_root` 内（L142）。digest 重算也从 `File.join(project_root, path)` 读真实字节（L59）。

因此：

- **装进项目**：原生可用，零产品改动。
- **留在 skill 目录**：当前合同直接拒绝——skill 路径无法表达成项目相对路径，符号链接会被 `realpath` 解析后落在 root 外而被拒。走通需要放宽这条路径契约，而它同时是防逃逸边界，属安全相关的产品变更。
- **hybrid**：基线部分撞同一堵墙，另加来源解析歧义（同一 `rule_id` 两来源谁赢、digest 记谁的）。

"单一来源"的真实诉求是**分发**，但用运行时共享解决它在 Orbit 里是反效果：规则被 digest 钉死，共享目录一改，所有项目的判据在无人复核的情况下静默改变——正是 alpha #7「审核标准移动」的机制。

**分发方式**：skill 目录保留母版，身份从运行时来源降级为分发来源。`init` 拷入项目（`init` 本就是每项目必跑，不新增步骤）；后续用一条更新命令拷入新版本，在项目里产生**可评审的 diff**。规则变更因此是有版本、能被看见、能被拒绝的事件。

旁证：DeepSeek 的 11 个 skill 同样放在仓库内 `.agents/skills/`；[Codex AGENTS.md 加载规则](../reference/codex-agents-md-loading.md) §3 的"项目增量规则"也预设规则随项目走。

#### 裁决 2（2026-08-17）：结构做完整重切，投递按 4–5 条控制

两件事分开定，因为代价曲线相反：

- **结构改动的代价随时间上升**。规则被 `content_sha256` 钉死，改一个字会让引用它的新 dispatch fail closed。370 行一个文件意味着改一条测试取舍规则会连带作废所有引用 `coding-guideline` 的 attempt。**细粒度切分不只是上下文经济，是变更隔离**。所以结构一次做对，原三个角色文件（coding 370 / testing 267 / quality 264）退役。
- **内容扩张的代价可以摊开**。初始只把 4–5 条接进 `dispatch` 默认；其余重切后的文件先落地不接线。在规则能被循环检验之前建全套投递，是 alpha 第 5 条"先把底座加固到很深，核心循环没接上"的重演。

即：**重切保证不丢内容，限额约束投递面**。

#### 三层结构

```text
常驻层     项目 AGENTS.md ——极短，只写项目增量 + 路由触发条件
任务规则层  dispatch --rule 的目标 ——每任务一文件
参考层     深度材料 ——只在规则显式指向时读
```

体量纪律取自 deepseek-harness 的经验值（14 个 AGENTS.md 共 500 行，根 149；11 个 skill 共 957 行，最大 146）：**任务规则单文件 ≤150 行，常驻层 ≤150 行**。对照现状，Orbit 单个 `core-operating-model.md` 947 行比对方整个 AGENTS.md 体系还长。

需要区分两条投递通道，不要混谈：[Codex AGENTS.md 加载规则](../reference/codex-agents-md-loading.md)描述的是 Codex 的**自动发现链**（路径决定、常驻、32 KiB 上限）；`--rule` 是**另一条通道**（按 attempt 显式钉入、digest 验证、控制流投递）。两者的关系是：该文档误区三指出"链接了专项文档 ≠ 加载了专项文档"，路由仍依赖 agent 自觉去读；**Orbit 正是这层路由缺的强制力**——不让 agent 自己决定读不读，而是投递内容并记录投递了什么、评审者拿到的是否同一份。因此 Orbit 的规则文件应照该文档 §5 的**专项文档**设计（单一主题、明确触发条件），而非照 `AGENTS.md` 本身。

按 alpha 病例反推的投递候选（G.1 设计时定最终取舍）：

| 任务规则 | 来源病例 | 现有素材 |
| --- | --- | --- |
| 定向修复 | #1 修复链路跑偏、#9 补丁链失控 | coding-guideline「Bugfix Root Cause Discipline」（三次假设失败进 blocked 已有） |
| 最小实现 | #5 过度设计 | coding-guideline「保持最小可用实现」「精准修改」 |
| 测试取舍 | #10 测试爆炸、#8 审核边界失误 | testing-guideline + ADR-004 `verification_class` 三分类已产品化 |
| 评审 | #7 审核标准移动 | quality-outcome-and-review + closure basis 冻结 |
| 视角审计 | #2 过程命名进正式代码 | **无判据**，需新写 |

#### 单文件模板（六项，现有规范普遍缺后四项）

1. **`description` 前言块** —— 供 dispatch 机器选择，`Use when...` 句式。这是从"人读"到"机器选"的最小必要改动。
2. **判据** —— 一句可判定的测试，而非"应该/不要"。视角审计可直接采用 vantage test：*could a reader at HEAD, with no access to any session transcript, PR thread, or uncommitted draft, resolve every reference and verify every claim?*（`dsh-trim-cot-leakage:12`）
3. **反向约束** —— "什么不算"。**对自动循环最关键的一项**：全是禁令的规则会让评审者一路 block 到底，正是 alpha #8/#10 的机制。
4. **降级路径** —— 不止"什么不算"，还要有"够不上就降级到哪"。`dsh-find-simplifications:79` 的"想法对但太小 → 改成 TODO"是范例，避免评审者只能放行或 block 的二值化。
5. **规则内优先级** —— 写进规则的止损条款。`dsh-code-review:8`：*"a short review with one substantiated blocker is better than a list of nits"*；`dsh-find-simplifications:8`：*"prefer a few well-proven candidates over a pile of thin guesses"*。
6. **自我限定句** —— "It is guidance, not a script/checklist."，三个 DeepSeek skill 开头都有。规则声明自己不是清单，才挡得住机械执行，与本仓库 `AGENTS.md` 防"为测试而测试"的立场同源。

另有一项属于写法而非结构：**判据前先做语料分类**。`dsh-find-simplifications` 要求先把消费者分成 production / non-production / ambiguous 再判断，把"有没有消费者"从主观变成可核查。适用于所有需要举证的规则。

**外部参考的使用边界**：`deepseek-ai/deepseek-harness/.agents/skills` 可借鉴的是**形式与少数判据**（上述六项、规则间所有权声明如 `dsh-trim-cot-leakage:8` 的 "owns the ... rule this skill applies"、按任务切分），**不可搬内容**——那些绑定 pnpm/Agent Notes/Cordis/oxlint/双语等仓库细则。Orbit `overview.md` 原有约束适用："不能直接把项目细则或子仓库细则写进默认协议。"

**交付**：901 行按任务重切完毕、三个角色文件退役、`init` 拷贝规则进项目、4–5 条接进 `dispatch --rule` 默认。

### 阶段 H：上下文投递出口

**规模最小的一阶段**——`ContextProjection` 是已建成的纯函数，只缺 CLI 出口。

- 新增只读命令输出三种投影（work_agent / evaluator / lead），供启动器交给 agent。
- 与阶段 G 接线：投影中的规则来自 attempt 钉死的 rule resolution。

**交付**：能把一个 attempt 的 bounded context 作为文件/stdout 交给 agent。

### 阶段 I：bounded runner（先用 stub 执行器）

**为什么在真实执行层之前**：runner 的正确性是确定性的、可精确测试的；真实 agent 不是。用 stub 先把四个停止态、checkpoint 追加、预算累计测准，比掺进 agent 的非确定性后再调试便宜得多。

按 ADR-006 冻结的形态实现外层驱动：

```text
collect authoritative facts → reconcile → 受控 writer 原子 compare-and-append
accepted checkpoint → 执行恰好一个允许动作 → 下一轮
```

四个互斥停止态：`completed` / `blocked` / `frozen` / `needs_user`。

**stub 执行器的硬约束**：必须显式标注为临时、写明移除条件，并在阶段 J 移除。coding-guideline 明确禁止"为了通过 E2E / dogfood 加业务层兜底，掩盖 runner、schema、状态机、provider、tool 或真实入口未接通"——stub 若留成永久件，本计划即自我违规。

**交付**：一条命令能把一个 task 驱动到四态之一，预算/熔断/continuation 首次可达。

### 阶段 J：真实执行层 + 可信观测

**最大且风险最高的一段。唯一没有任何现成实现的部分。**

两个必须同时解决的问题：

**启动**：怎么真正拉起一个 coding agent（herdr pane / 子进程）。先读 `8b5ab8c^` 的 3,202 行。

**观测**：自动循环里 evidence 谁写？如果由干活的 agent 自己写，就是自报——违反 Orbit 全部前提。ADR-006 已定调："计数只来自真实 change surface 与 trusted provider（CI/test-runner 的 provider-verified 计数、repository 权威扫描），**不信 agent 自报**。"

所以执行层不只是启动器，还需要**可信观测者**（测试运行器、仓库扫描器）把 agent 的产出变成 provider 验证过的事实。

**这一步顺带解决一笔欠账**：阶段 D 的本地 provider（"一致性机制而非安全机制"）在此处升级——观测者本身成为 provider，事实来源从"CLI 递什么就签什么"变成"测出来什么就是什么"。这是[欠账台账](./debt-ledger.md)第 1 项"替换真实 provider"的真实解法，不需要单独立项。

**前置未知（必须在 J.1 设计时正面回答）**：ADR-002 已经推翻了 ADR-001 的 automatic session refresh，结论是"真实 Herdr 不提供对应信任原语"。因此**被拉起的 agent 的 provider-verified runtime subject 从哪来，是一个开放问题**，可能是本阶段最硬的一块。若答案是需要新的信任基础设施，停下上报，不要顺势建。

**交付**：`dispatch` 真正拉起 agent；evidence 从观测事实派生而非自报；stub 移除。

### 阶段 K：愿景验证

按第 0 节的两个场景验收，场景 B 优先。

ADR-003「Orbit 落地仍需验证的问题」列了 11 条经验问题并要求对照实验设计。本阶段**只取 2–3 条**最相关的（建议：goal drift 发生率、修复被提升为主目标的次数、bounded 是否降低偏移），不做全量——全量属于研究，不属于交付。

**交付**：Orbit 达成或未达成愿景的证据；未达成时输出具体缺口，不含糊。

## 4. 不在本计划内（明确记账）

- **cutover 完成**：ADR-005 有 12 条 cutover 条件，本计划不以满足全部为目标。相关记录见 ADR-005 修订记录。
- **所有已记账欠账**：本地 provider 替换、`.cli-clock`、schema enum 分歧、cross-control 残留代码、命令面双拼法、v2 runtime 文档重写——逐条见[欠账台账](./debt-ledger.md)。其中第 1 项由阶段 J 顺带解除，其余不在本计划内。
- **`core-operating-model.md` 重写**：阶段 G 只做规则库；这份 947 行 v1 文档（已加停用标注）的 v2 重写不在内（台账第 6 项）。
- **README 定位措辞**：现有首句"它不负责『让 AI 更会写代码』，而是让工作结果更可追溯"把附属好处写成了产品定义，与本文第 0 节冲突。建议随阶段 G 一并修正（改动极小）。

## 5. 主要风险

| 风险 | 阶段 | 说明 |
| --- | --- | --- |
| runtime subject 信任缺口 | J | Herdr 不提供所需信任原语（ADR-002）；被拉起 agent 的身份证明是开放问题 |
| stub 变永久 | I→J | 已设硬约束与移除条件；若阶段 J 受阻，必须显式标注"未接通"而非默认可用 |
| 重切丢内容 | G | 三个角色文件退役后必须可追溯到重切后的归宿；需要逐节对照表而非凭印象搬运 |
| 投递面过度扩张 | G | 结构可全量重切，但接进 `dispatch` 默认的限 4–5 条；扩张前须先有循环反馈 |
| 规则改动的连带失效 | G 之后 | digest 钉死使规则变更成为版本事件；细粒度切分缩小爆炸半径但不消除，仍需规则版本策略 |
| 执行层体量失控 | J | v1 同类实现 3,202 行；设计时须给出停止线并如实上报超出 |

## 6. 执行纪律（沿用）

- 每阶段先设计后实施，设计不写实现代码，Gate 通过再动手。
- 测试预算：新增测试 ≤10 方法 / ≤300 行；超出先说明业务风险。
- CPU：迭代用精确单方法，focused 仅最终收口，每增量最多两次。
- 不可逆操作（数据删除等）必须先备份、交可校验证据、独立核验后才执行。
- 不宣称未达成的能力；每阶段交付说明必须写明"未做什么"。

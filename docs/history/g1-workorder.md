# 阶段 G.1 工单：规则库结构设计（执行方：grok / `wA:pG`）

> **历史记录（2026-08-17 归档）**：已完成。裁决在 [`../plan/vision-completion-plan.md`](../plan/vision-completion-plan.md)。交付物现为 [`g1-rule-library-design.md`](./g1-rule-library-design.md)。

- 统筹与审核：`wA:pD`
- 基线 HEAD：`fc01f60 docs: track the two files ADR decisions cite as their basis`
- 交付物：`docs/plan/g1-rule-library-design.md`（新文件）
- 性质：**设计说明，零实现代码**

本工单**不拥有任何裁决**，只做派发。裁决在 `docs/plan/vision-completion-plan.md`「如果你刚接手」的 D1–D10 表；**两者冲突时以计划为准**。工单完成后移入 `docs/history/`（无裁定权层），所以规格不能留在这里。

---

## 0. 必读材料（按序）

| 文件 | 读什么 |
| --- | --- |
| `docs/plan/vision-completion-plan.md` | **先读「如果你刚接手」的 D1–D10 裁决表**，再读阶段 G 全节：裁决 1（规则装进项目）、裁决 2（结构全量重切／投递限 4–5 条）、三层结构、**单文件模板 D8 完整规格**、外部吸收清单 D9、投递候选表 |
| `docs/reference/codex-agents-md-loading.md` | §3（全局／项目／模块分工）、§5（把 AGENTS.md 设计成上下文路由器）、§9 误区三 |
| `docs/reference/alpha-test-findings.md` | 十项病例——规则要治的病 |
| `skills/orbit/references/runtime/coding-guideline.md` | 370 行，重切素材 |
| `skills/orbit/references/runtime/testing-guideline.md` | 267 行，重切素材 |
| `skills/orbit/references/runtime/quality-outcome-and-review.md` | 264 行，重切素材 |

外部参考（**只看形式，不搬内容**）：`/Users/yangke/Personal/AI/deepseek-harness/.agents/skills/`，重点看 `dsh-trim-cot-leakage`（45 行）、`dsh-code-review`（49 行）、`dsh-find-simplifications`（146 行）。

## 1. 背景：为什么要重切（不需要你再论证，但要理解）

**规则被 digest 钉死。** `lib/orbit/v2/rule_resolution.rb` 存 `path` + `content_sha256`，用 `project_root/path` 的真实字节重算比对（L59）。改一个字，引用该文件的新 dispatch 就 fail closed。

因此 370 行一个 `coding-guideline.md` 意味着：**改一条测试取舍规则，会连带作废所有引用它的 attempt。** 细粒度切分不只是上下文经济，是**变更隔离**。

**规则要能被机器选。** `dispatch --rule` 目前要求显式传路径、无默认值。现有三个文件按角色组织（coding / testing / quality），没有 `description` 元数据，机器无法按任务挑选。

**规则装进用户项目。** `canonicalize_path!`（L125-156）要求项目相对路径、`realpath` 解析后仍在 `project_root` 内。skill 目录方案会被合同直接拒绝。母版留在 skill 目录作**分发源**，`init` 拷进项目。

## 2. 必须回答的六个问题

### Q1 完整文件清单

重切后有哪些任务规则文件？每个文件：文件名、`description` 一句话、治哪几条 alpha 病例、预估行数。

约束：**单文件 ≤150 行**（deepseek-harness 最大 skill 146 行，14 个 AGENTS.md 共 500 行）。文件总数给出你的判断并说明依据。

### Q2 逐节切分对照表（**本工单最重要的一项**）

901 行的**每一节**都要有归宿。表格形式：

| 源文件 | 源小节（标题或行号区间） | 行数 | 去向 | 处理 |
| --- | --- | --- | --- | --- |

"去向"必须是 Q1 清单里的具体文件，或明确标注为下列之一：

- **参考层**（内容有价值但不是任务规则，降为深度材料）
- **删除**（已被产品机制取代——须写明是哪个机制，例如 `verification_class` 三分类已在 ADR-004 产品化）
- **重写**（原文不能直接用，须重新表述——写明为什么）

**禁止凭印象搬运。** 逐节对照是"重切丢内容"这条风险的唯一控制手段。表格覆盖不到的行数即视为遗漏。表末给出行数对账：901 = Σ各去向。

### Q3 单文件模板实例

给出**一个完整写好的规则文件**（不是骨架）。模板见下方补充节（2026-08-17 修订：六项扩为七项必备 + 三项条件性）。

建议用"最小实现"或"定向修复"做实例（素材最足）。

### Q4 投递名单

哪 4–5 条接进 `dispatch --rule` 默认？为什么是这几条、为什么其余先不接。

依据：alpha 病例的发生频率与危害。其余重切后的文件**先落地不接线**。

### Q5 母版位置与分发形态

- 母版在 skill 目录的哪个路径、什么目录结构？
- `init` 往项目的哪个路径拷？（注意：不能是 `.orbit/` 下——`.orbit` 默认 gitignore，而规则必须能被 git 看见才能产生可评审 diff）
- 更新命令叫什么、怎么产生可评审 diff、已被项目修改过的文件怎么处理（覆盖／跳过／冲突标记）？

### Q6 常驻层写什么

项目 `AGENTS.md` 里放什么、不放什么。按 `codex-agents-md-loading.md` §5 的路由器模型：少量常驻规则 + 明确触发条件。≤150 行。

**注意两条通道的区别**：`AGENTS.md` 走 Codex 自动发现链（路径决定、常驻、32 KiB 上限）；`--rule` 走 Orbit 投递（按 attempt 钉入、digest 验证）。同一条规则不要两边都写——那是 §4 明令禁止的重复。

## 3. 硬约束

1. **零实现代码。** 不改 `lib/`、`tests/`、`skills/` 下任何文件，不新建规则文件本身。只产出设计说明（Q3 的实例写在设计说明里）。
2. **不搬 DeepSeek 内容。** 借形式与 vantage test 一句判据；他们的正文绑死 pnpm／Agent Notes／Cordis／oxlint／双语流程，一行不搬。`skills/orbit/references/overview.md` 原有约束适用："不能直接把项目细则或子仓库细则写进默认协议。"
3. **不放宽合同。** `rule_resolution.rb` 的路径契约是防逃逸边界，设计不得依赖放宽它。
4. **不动仓库根 `AGENTS.md`。** 它是开发 Agent 的客户端纪律，不是产品 authority。Q6 讨论的是**用户项目**的 `AGENTS.md` 模板。
5. **不宣称阶段 G 完成。** 本工单只到设计。

## 4. 停止上报条件（撞到即停，不要自行扩大范围）

- 901 行里出现**无法归入任何任务规则、也不该删除**的内容——说明 Q1 清单不完整，停下报清单缺口。
- 某条规则要成立就必须**放宽产品合同**——停下报，不要自行削弱校验。
- 规模越界：文件数 > 12 或任一文件 > 150 行——停下报，说明为什么压不下去。
- 发现 `vision-completion-plan.md` 阶段 G 的**裁决有误**——停下报证据，不要绕过。
- 发现 `docs/` 重组后有断链或事实错误——报给我，不要自行修（那是我的交付面）。

## 5. 报告

完成后用 herdr-msg 报到 `wA:pD`：

```bash
~/.claude/skills/herdr/scripts/herdr-msg --to wA:pD --task g1-rule-library \
  --kind reply --body "..."
```

报告须含：

- 六个问题的答案概要（Q2 的行数对账必须给出：901 = Σ各去向）
- 偏离工单之处与理由
- 撞到的停止条件（如有）
- 确认：`git status --porcelain` 只有新增的 `docs/plan/g1-rule-library-design.md`，`git diff` 为空，HEAD 仍 `fc01f60`

---

## 补充（2026-08-17 修订，来源：`/Users/yangke/Personal/omen/zeen/.agents/skills/`）

该目录的六个 skill 里有几项是 deepseek 那套没有的，且更贴 Orbit 的问题。**同样只借形式与判据，不搬内容**——它们绑死了 Zeen 的模块／领域／契约结构。

### 单文件模板：七项必备 + 三项条件性

**规格在计划里，本工单不复制**：见 `docs/plan/vision-completion-plan.md` §3 阶段 G「单文件模板（D8）」。原始出处逐项对照：

| 项 | 原始出处 |
| --- | --- |
| 7 升格条件（何时算真边界） | `zeen-prose-standard:62` |
| 7 升格条件（待裁定格式与两条禁令） | `zeen-module-handbook:29` |
| 8 反问法警告 | `zeen-doc-authority:26` |
| 9 反发明边界 | `zeen-decision-record:65` |
| 10 过度纠正五陷阱 | `zeen-trim-cot-leakage:80-81` |
| 3 放行表要给依据、承认永久误报 | `zeen-trim-cot-leakage:43` |

### 另外一条写法要求

**不要为了凑数制造改动。** 规则正文里要有一句等效于"复核任务只报告不修改""不要为了凑够删除量制造改动"（`zeen-prose-standard:56`）。

### Q2 对照表新增一列

去向之外加一列 **升格条件**：该规则触发时，什么情况该停下交给人。没有升格条件的规则在自动循环里只会一路 block。

### 停止条件新增一条

- 某条规则**写不出可证伪判据**，只能写成"应该／尽量"——停下报，不要留一条无法判定的规则。无法判定的规则在自动循环里等于噪声。

---

我批准设计后才进入 G.2（实际重切与写文件）。

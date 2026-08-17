# G.1 规则库结构设计

- 日期：2026-08-17
- 基线 HEAD：`fc01f60`
- 工单：[`g1-workorder.md`](./g1-workorder.md)（只派发，不拥有裁决；完成后将移入 `docs/history/`）
- 性质：**设计说明，零实现代码。** 不宣称阶段 G 完成。
- 权威：模板与阶段 G 裁决以 [`vision-completion-plan.md`](./vision-completion-plan.md) 顶部 D1–D10 及 §3 D8/D9 正文为准。语义以 ADR / `contracts/orbit-v2/` 为准。工单与计划冲突时以计划为准。

本文件回答工单六个问题。不重做审计。D5（规则装进用户项目）与 D6（按任务全量重切、投递限 4–5 条）按计划执行。

---

## 0. 设计前提（不重新论证）

1. 规则被 `path` + `content_sha256` 钉在每次 dispatch 上（`rule_resolution.rb` L59）。细切是变更隔离，不只是上下文经济。
2. `canonicalize_path!`（L125–156）要求项目相对 POSIX 路径，且 `realpath` 后仍在 `project_root` 内。母版可以留在 skill 目录，运行时文件必须是项目内真实文件。本设计不放宽这条路径契约。
3. 任务规则按任务切，不按角色切。现有三个角色文件在 G.2 退役。
4. 两条通道不混写：项目 `AGENTS.md` 是 Codex 自动发现链；`--rule` 是 Orbit 按 attempt 钉入。同一条规则正文只存在于后者。
5. 单文件模板以计划 D8 **正文**为准（工单只留出处对照表，规格不在工单里）。必备是第 0–7 项共八项，外加第 8–10 项条件性。判据必须可证伪，优先「问题 → 判定 → 动作」。升格 payload 按类型分型，不是一种格式打天下。
6. 外部吸收以计划 D9 为准：只借形式与判据，不搬正文。D9「明确未采用」的部分本设计不重新提出（见 §0.1）。D8 表头仍写「七项必备」而正文已列入第 0 项，编号漂移见文末，不改计划。

### 0.1 D1–D10 对齐（已读，不重提被否备选）

| 裁决 | 本设计怎么用 |
| --- | --- |
| D1 目标是自动实现需求代码 | 规则为控制循环服务，不为审计仪式加文件 |
| D2 场景 B 比 A 更重要 | 每条规则必有升格；写不出可证伪判据的不进清单 |
| D3 / D4 阶段序与 stub 移除 | G.1 不设计 runner / 执行层 |
| D5 规则进项目；skill 目录只是分发源 | Q5。不把 skill 路径当 `--rule` 运行时路径，不提 hybrid |
| D6 全量重切、默认只接 4–5 条 | Q1 / Q4。不先建全套投递再接循环 |
| D7 ≤150 行 | Q1 预估均低于此 |
| D8 模板 | Q3 实例；Q1 升格分型 |
| D9 只借形式 | 见下表。无「合并外部文档」阶段 |
| D10 三项能力未承诺 | 升格里「缺陷」三要素是规则写法，不是把 Finding 机械门槛产品化；不做完整性下界，不改 `needs_user` schema |

D9 已吸收、本设计用到的形式：模板 0–10、按任务切分、放行依据、反事实判据、vantage test（唯一字面借用，G.2 才写入 `vantage-audit`）。

D9 **明确未采用**（此处只记账，G.2 也不做）：

- 三库的具体规则正文、目录结构和守卫脚本
- Zeen 的四层文档模型（product / architecture / domains / modules）——Orbit 没有对应分层，不按那四层切规则
- 多席评审的轮次生命周期——Orbit 用 gate / Finding，不用 research 轮次
- Zeen 技术栈条目（属项目细则）

D9 投递候选里留给 G.2 的形式（不搬原文）：`targeted-fix` 用可观察症状而不是轮次计数；`minimal-implementation` 写清「最小 ≠ 一次性」；`test-selection` 写动态数据不固化、测试不能驱动业务偏离；`review` 用标准轴 / 规格轴，做多了同样要报。

---

## Q1 完整文件清单

重切后 **8 个任务规则文件**。依据：

- 变更隔离：会独立演变的主题必须分文件。把 CLI 卸载安全写进「最小实现」，改一句卸载规则会作废所有普通实现 attempt。
- 投递面：默认只接 4–5 条（Q4）。其余落地不接线，避免 alpha #5「先把底座加固到很深」。
- 上限：8 ≤ 12；每个预估行数 ≤ 150。预估是 G.2 写成 D8（0–7 + 适用的 8–10）后的正文，不是源文件行数（源行见 Q2）。

`description` 供以后按任务挑选。当前 CLI 仍是显式 `--rule PATH`、无默认值；默认名单是 G.2 的接线目标，不是现在的行为。

| # | 文件（项目内路径） | `description` | 治的 alpha 病例 | 预估行数 | G.2 默认？ |
| --- | --- | --- | ---: | ---: | --- |
| 1 | `rules/minimal-implementation.md` | Use when implementing a scoped feature, refactor, or contract-bound change that must stay the smallest change that satisfies the current task — not when isolating a failing symptom (use `targeted-fix`) and not when only reviewing. | #5 过度设计 | 120 | 是（implementer） |
| 2 | `rules/targeted-fix.md` | Use when reproducing, isolating, or repairing a failing symptom — not when adding a green-field feature with no failing path, and not when the only question is which tests to keep. | #1 修复链路跑偏、#9 补丁链失控 | 110 | 是（implementer） |
| 3 | `rules/test-selection.md` | Use when adding, changing, skipping, or defending a test, or when classifying an evidence requirement as regression / release audit / acceptance evidence. | #8 审核边界失误、#10 测试爆炸 | 140 | 是（implementer） |
| 4 | `rules/review.md` | Use when independently judging whether a change improved the contracted quality outcome — not when implementing, and not when the only job is to restate a green command. | #7 审核标准移动 | 130 | 是（reviewer，叠在 subject 已钉规则之上） |
| 5 | `rules/vantage-audit.md` | Use when adding or renaming a user-visible symbol, file, API, or doc claim, to check that a reader at HEAD can resolve every reference without session transcript or phase labels. | #2 过程命名进正式代码 | 80（新写） | 是（implementer） |
| 6 | `rules/structured-boundary.md` | Use when changing a parser, resolver, normalizer, validator, state machine, artifact writer, gate, or tool boundary — not for ordinary feature plumbing that does not invent a fact source. | 无独立编号；#1/#9 的机制面 | 120 | 否 |
| 7 | `rules/mutating-surface.md` | Use when changing a CLI, installer, uninstall/cleanup, migration, package, release asset, or other command that mutates user state. | 无独立编号；#8 的表面面 | 110 | 否 |
| 8 | `rules/quality-outcome.md` | Use when writing or revising a task contract’s quality outcome, measurable thresholds, or invalid completions — not when implementing against an already-frozen contract. | #5、#7 的合同面 | 130 | 否 |

未单列的 alpha 病例由产品机制承担，不靠任务规则：

| 病例 | 产品机制 | 规则还剩什么 |
| --- | --- | --- |
| #3 多任务编排 | ADR-006 task queue / single-active | 无 |
| #4 任务异常评判 | ADR-006 bounded runner / fuse | 无 |
| #6 Lead 自检 | ADR-006 四层 reconcile | 无 |
| #7 标准移动（机械部分） | ADR-004 `closure_basis_digest` | `review.md` 只禁止 reviewer 改标准 |
| #8 三类验证（机械部分） | ADR-004 `verification_class` 三分类互斥 | `test-selection.md` 只做分类判断 |
| #9 补丁封顶（机械部分） | ADR-006 runner / recovery | `targeted-fix.md` 只做根因与三次假设 |
| #10 数量封顶（机械部分） | ADR-006 `effective_budget_bindings` | `test-selection.md` 只做取舍；10/300 不是 schema 常量 |

`vantage-audit.md` 在 901 行里没有对应节（愿景表已写「无判据，需新写」）。Q2 对账为 0 源行。G.2 按 D9 允许的 vantage test 新写，不从 DeepSeek / Zeen 搬正文。

### Q1 对投递候选「外部可借形式」列（只借形式）

计划投递候选表五条默认规则的外部范本，G.2 按此写，不搬原文。

| 文件 | 外部可借形式（出处） | 本设计怎么用 |
| --- | --- | --- |
| `targeted-fix` | `AGENTS-development.md` §四：可观察症状（单测反复改 / 修复引发新失败 / 代码不断变复杂），不是轮次计数；第三步判断是否设计方向错误 | 升格用症状，不用「第 N 轮」。三次假设是 901 行原有素材，与症状并列，不互相替代 |
| `minimal-implementation` | 同文 §二：判据式范本；「先跑通再加固」与「不接受注定被替换的权宜方案」同时成立 | Q3 已写。最小 ≠ 一次性 |
| `test-selection` | `AGENTS-testing.md` §四动态数据不固化（ADR-004 的散文形态）、§八测试不能驱动业务偏离 | G.2 写入；机械分类仍归 `verification_class` |
| `review` | `zeen-change-review` 双轴（标准轴 / 规格轴）+「做多了同样要报」 | G.2 写入 `review.md`；不采用多席轮次 |
| `vantage-audit` | vantage test（唯一字面借用） | G.2 原文写入该文件 |

后三份非默认文件计划未标外部范本：`structured-boundary` / `mutating-surface` 用 901 行自身素材；`quality-outcome` 的反发明逃生口用 D8 第 9 项形式。

### 每个文件的升格条件（停下来交给人）

写不出可证伪判据的规则不得进入清单。下面八条都能写成反事实提问。升格用两段式：何时算真边界；停下按类型交 payload。

三型 payload（D8；各文件正文重复此表，不另建文件）：

| 升格类型 | 交什么 |
| --- | --- |
| 裁不了的缺口 | `待裁定：<问题> —— <2–3 个候选与各自代价>`，交付摘要单独列出 |
| 报一条缺陷 | 位置（文件:行）+ 能自己复现的证据 + 影响。三样缺一样是意见，不是缺陷 |
| 发现范围外问题 | 问题描述 + 影响范围 + 建议方案。本 attempt 不改 |

禁令：不要自己选一个答案写进代码或合同；不要用「按需返回」「视情况」绕开。裁定后删干净，不留「原本这里有一条，现已裁定」。禁止只在对话中拍板。

| 文件 | 真边界（才升格） | 不是边界 | 默认 payload 型 |
| --- | --- | --- | --- |
| `minimal-implementation` | 两个以上实现都满足合同与本规则，但在已接受原则之间取舍不同（复用别扭旧 API vs 加一个更小的本地函数），且本规则没有直接裁定 | 删掉无条款可指的 service / interface / 配置层 | 缺口；顺手发现的归范围外 |
| `targeted-fix` | 三次假设都失败，或根因需要项目外信息（账号、设备、未授权系统） | 还没复现就换策略；用 catch-all 消症状 | 缺口（缺外部信息） |
| `test-selection` | 同一证据同时像稳定规则又像数据快照，且 Lead 尚未给出 `verification_class` | 把一次性 URL 写成永久测试；为凑数量加低价值用例 | 缺口 |
| `review` | 合同内 outcome 已达成，但新发现的风险是否 blocking 要由 policy / risk owner 裁 | reviewer 改 acceptance；用「测试过了」代替 outcome | 缺陷；blocking 裁决归缺口 |
| `vantage-audit` | 一个名字在仓库内可解析，但对外承诺与实现绑定捆在同一标识里，本规则没有裁定留哪一半 | `FreshP6Initialization`、`xxx-slice1-handler` 这种阶段标签 | 缺陷（阶段标签）；捆在一起的归缺口 |
| `structured-boundary` | 结构化方案与窄名单在当前合同下都能成立，且扩表风险无法从本仓库证明 | 用增长词表当主边界；新旧路径同时写权威结果 | 缺口 |
| `mutating-surface` | 真实命令表面无法在本环境验证（无安装权、无 registry），需要人接受 residual risk | 只跑库测试就标 CLI/release 完成 | 缺口 |
| `quality-outcome` | 两个阈值都能量化「变好」，但选哪一个会改变任务范围 | 合同只有动作没有 outcome 仍开写实现 | 缺口 |

### 条件性三项：哪个文件要写

不适用不凑。G.2 按此表，不要每份都抄第 8–10 项。

| 文件 | 8 反问法 | 9 反发明 | 10 过度纠正 |
| --- | --- | --- | --- |
| `minimal-implementation` | 要。「更完整 / 更通用更好」给反答案 | 不要。不要求补历史备选 | 不要。主旨是少写，不是清理既有正文 |
| `targeted-fix` | 要。「看起来像缓存 / 异步」不是根因 | 要。写根因时判不了就写「未记录」，禁止编一个因果 | 不要 |
| `test-selection` | 要。「覆盖率高 / 测得越多越安全」给反答案 | 不要 | 要（删测试或精简套件时）。第五陷阱：删掉「下次补回归」的承诺却不补 |
| `review` | 要。「测试绿了就是 outcome 达成」给反答案 | 要。finding 缺位置/证据/影响则降为意见，不发明缺陷 | 要（评清理/删除 diff 时） |
| `vantage-audit` | 要。vantage test 本身就是反问法的正问 | 要。重述可保留事实时，判不了写「未记录」 | 要。这是清理类规则，五个陷阱全写 |
| `structured-boundary` | 要。「补一个词就过了」给反答案 | 不要 | 不要 |
| `mutating-surface` | 不要。没有那个「看起来对」的假问法 | 不要 | 不要 |
| `quality-outcome` | 要。「做了动作就是完成」给反答案 | 要。补无效完成 / 被否备选时，判不了写「未记录」 | 不要 |

### 参考层（非任务规则，不计入 12 文件上限）

一个文件：`docs/orbit/reference/report-and-evidence-examples.md`（母版在 skill 目录，见 Q5）。只收提交格式示例与自检问题表。G.2 不把它接进 `--rule`。权威 schema 仍是 v2 evidence / GateEvaluation 合同；v2 输入模板尚未替换 `.v1-deprecated` 那批，所以这些示例先降级而不是删除。

---

## Q2 逐节切分对照表

行号按源文件 1-based，含小节标题与节末空行。`quality-outcome-and-review.md` L72 的 `## Quality Outcome` 在代码围栏内，不记作独立小节；L67–94 整段算「Review 输出」。

「去向」只使用：Q1 的 8 个文件名、**参考层**、**删除**。内容进入某文件但原文不能直接粘贴时，去向仍是该文件，处理记「重写」及原因。

升格条件列：指向 Q1 表；删除 / 参考层记「—」。

### coding-guideline.md（370）

| 源小节 | 行号 | 行数 | 去向 | 处理 | 升格条件 |
| --- | --- | ---: | --- | --- | --- |
| 标题 + 角色总序 | 1–6 | 6 | 删除 | 角色文件退役（计划 D6）。不是产品机制替换，是本重切的前提 | — |
| Implementation fact record | 7–10 | 4 | 删除 | 命令面是 v1。v2 对应物是 `EvidenceRecord.submission_artifact_refs` + `implementation_check` 必填 `changed_paths` / `verification_refs`（`contracts/orbit-v2/contract.yaml` L1049–1071；`schemas/evidence.schema.json` L61–72）。失败 run 不可原地覆盖：同 ID 异内容 fail closed（`contract.yaml` L1035） | — |
| Coding 目标 | 11–22 | 12 | `minimal-implementation` | 重写为「留下什么」判据。原文是角色目标陈述，不能当任务规则用 | 见 Q1 该文件 |
| 输入顺序 | 23–34 | 12 | 删除 | `.orbit/roles.yaml` 与默认读 `core-operating-model.md` 是 v1 角色装载：v1 已退役（ADR-005）；ADR-004 L32 / L462 禁止把 ADR 自动加入 required files。「读合同再写」与已入 `minimal-implementation` 的「先读再写」重复。不把尚未接线的 `ContextProjection`（阶段 H 才有 CLI）说成已取代读序 | — |
| LLM Coding Failure Guardrails 导语 | 35–38 | 4 | 删除 | 无独立规范；子节已分别入任务文件 | — |
| 先读再写 | 39–49 | 11 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| 写前说明假设和选择 | 50–60 | 11 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| 保持最小可用实现 | 61–71 | 11 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| 精准修改 | 72–82 | 11 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| 验证优先于自信（复现 / baseline / 无证据不 pass） | 83–89 | 7 | `targeted-fix` | 压缩搬入 | 见 Q1 |
| 验证优先于自信（不写低价值测试） | 90–91 | 2 | `test-selection` | 压缩搬入 | 见 Q1 |
| 验证优先于自信（无验证不完整 pass） | 92–93 | 2 | `targeted-fix` | 压缩搬入 | 见 Q1 |
| 调试时不要猜 | 94–105 | 12 | `targeted-fix` | 压缩搬入 | 见 Q1 |
| 依赖默认不增加 | 106–116 | 11 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| 沟通和交接要具体 | 117–122 | 6 | 删除 | 已被 `implementation_check` 结构化字段取代：`scope_match` / `acceptance_results` / `known_gaps` / `verification_refs`（ADR-004 决策四；`schemas/evidence.schema.json` L63–72；`contract.yaml` L1067–1088） | — |
| Scope Discipline | 123–138 | 16 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| Source Contract（合同要有 outcome） | 139–151 | 13 | `quality-outcome` | 重写为合同作者判据。原文把 lead/coder 绑在同一角色文件里 | 见 Q1 |
| Source Contract（不得静默缩 scope） | 152–153 | 2 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| Implementation Discipline（复用 / 抽象） | 154–159 | 6 | `minimal-implementation` | 压缩搬入 | 见 Q1 |
| Implementation Discipline（名单、writer/reader） | 160–161 | 2 | `structured-boundary` | 压缩搬入 | 见 Q1 |
| Implementation Discipline（sibling 入口） | 162 | 1 | `targeted-fix` | 压缩搬入 | 见 Q1 |
| Implementation Discipline（关旧路径、tool 化） | 163–166 | 4 | `structured-boundary` | 压缩搬入 | 见 Q1 |
| Bugfix Root Cause Discipline | 167–184 | 18 | `targeted-fix` | 压缩搬入 | 见 Q1 |
| Structural Guardrails 导语 | 185–188 | 4 | `structured-boundary` | 压缩为文件导语 | 见 Q1 |
| 不用增长名单当主要安全边界 | 189–206 | 18 | `structured-boundary` | 压缩搬入 | 见 Q1 |
| 字段族和单一事实源 | 207–224 | 18 | `structured-boundary` | 压缩搬入 | 见 Q1 |
| 扩散一致性 | 225–238 | 14 | `targeted-fix` | 压缩搬入 | 见 Q1 |
| Closure Guard | 239–248 | 10 | `structured-boundary` | 压缩搬入 | 见 Q1 |
| 禁止假完成 | 249–262 | 14 | `minimal-implementation` | 重写为作者禁令。机械项（artifact 原地覆盖、late result 绑错 attempt）已由 validator 承担，不搬命令步骤 | 见 Q1 |
| CLI / Installer / Mutating Command Surface | 263–282 | 20 | `mutating-surface` | 压缩搬入 | 见 Q1 |
| Release / Package Artifact Surface（命令与包） | 283–294 | 12 | `mutating-surface` | 压缩搬入 | 见 Q1 |
| Release 节内 brooks-lint 编码风险表 | 295–307 | 13 | 参考层 | 降为深度材料。自检问题，不是任务判据 | — |
| Evidence | 308–324 | 17 | 删除 | 字段已被 `implementation_check` 取代：`changed_paths`、`verification_refs`、`acceptance_results`、`known_gaps`（`schemas/evidence.schema.json` L63–72；`contract.yaml` L1067–1088）。`tool_calls` / `handoff_notes` 在 v2 无同名字段，不另留一份平行清单 | — |
| Fail Closed | 325–338 | 14 | 删除 | 与已入 `minimal-implementation` 的「禁止假完成」重复。机械项对应 `implementation_check` 必填（同上）与 blocking Finding 未决时禁止新非评估 dispatch（`contract.yaml` L252 `dispatch_barrier`） | — |
| Coding Output（YAML 示例） | 339–369 | 31 | 参考层 | 降为深度材料。schema 权威在合同；v2 模板尚未替换 v1-deprecated | — |
| Coding Output 末句（修完再走 review） | 370 | 1 | 删除 | 未决 blocking Finding 时禁止新非评估 dispatch（`contract.yaml` L252）；`complete` 是派生 AggregateOutcome，不能自宣（`lib/orbit/v2/cli.rb` L557–572） | — |

小节合计：370。

### testing-guideline.md（267）

| 源小节 | 行号 | 行数 | 去向 | 处理 | 升格条件 |
| --- | --- | ---: | --- | --- | --- |
| 标题 + 角色总序 | 1–6 | 6 | 删除 | 角色文件退役（计划 D6） | — |
| Testing 目标 | 7–20 | 14 | `test-selection` | 重写为可证伪判据。原文是 tester 角色目标 | 见 Q1 |
| 输入顺序 | 21–32 | 12 | 删除 | 与已入 `test-selection` 的 Testing 目标「不补脑合同」重复。默认读 `core-operating-model.md` 被 ADR-004 L462 禁止。不把阶段 H 才出口的 ContextProjection 说成已取代读序 | — |
| Tester 边界 | 33–50 | 18 | `test-selection` | 压缩搬入作者/执行者禁令。v2 CLI 尚无 tester 角色，但实现者写测试同样能污染 | 见 Q1 |
| Test Contract | 51–75 | 25 | `test-selection` | 压缩搬入 | 见 Q1 |
| Verdict | 76–88 | 13 | `test-selection` | 重写。v2 没有 tester 四分类：`EvidenceRecord` 无 verdict 字段（`schemas/evidence.schema.json` L32–47）；`GateEvaluation.quality_outcome_verdict` 只有 pass/fail/partial（`schemas/gate.schema.json` L138）。`invalid`（污染/前提不成立）在 v2 的意思是「不要提交能关 gate 的 evaluation」，不是第四个 enum | 见 Q1 |
| Evidence（字段清单） | 89–106 | 18 | 参考层 | 降为深度材料。权威在 schema | — |
| Test Quality Checks | 107–123 | 17 | `test-selection` | 压缩搬入 | 见 Q1 |
| Pattern-Fix Testing | 124–137 | 14 | `test-selection` | 压缩搬入；机制面所有权在 `structured-boundary` | 见 Q1 |
| Regression Guard | 138–146 | 9 | `test-selection` | 压缩搬入。作者侧「必须留 guard」已在 `targeted-fix` 根因节 | 见 Q1 |
| Real Path Priority（优先级 1–4） | 147–157 | 11 | `test-selection` | 压缩搬入 | 见 Q1 |
| Real Path 末段（CLI/release 表面） | 158–159 | 2 | `mutating-surface` | 压缩搬入 | 见 Q1 |
| Artifact 和用户可见状态一致 | 160–171 | 12 | `test-selection` | 压缩搬入 | 见 Q1 |
| Fail Closed | 172–190 | 19 | 删除 | 与已入 `test-selection` 的 Tester 边界 / Real Path / Artifact 一致 / Regression Guard 重复。独一条「修完未再走 review」对应 `contract.yaml` L252 `dispatch_barrier`。不把本节说成 budget 机械校验——本节正文没有预算字段 | — |
| Testing Output（YAML 示例） | 191–257 | 67 | 参考层 | 降为深度材料 | — |
| Testing Output（user_journeys / test-hook / artifact inspect / test_level） | 258–261, 264–266 | 7 | 参考层 | `user_journeys`、`test-hook`、`orbit artifact inspect`、`test_level` / `blocked` 作为 verdict 在 `lib/orbit/v2/` 与 `contracts/orbit-v2/` 命中为 0。不是产品机制，降为格式史料 | — |
| Testing Output（submit 与不改 manifest） | 262–263 | 2 | 删除 | `orbit v2 evidence submit --task ID --proposal FILE`（`lib/orbit/v2/cli.rb` L355–358）。v1 的 `--file` / `--report` / 手写 `.orbit/evidence*.json` 不是 v2 命令面 | — |
| Testing Output 末句（tester 不标 done） | 267 | 1 | 删除 | `complete` 派生 AggregateOutcome 的 `closed`（`lib/orbit/v2/cli.rb` L557–572），评估者不能把任务写成 done | — |

小节合计：267。

### quality-outcome-and-review.md（264）

| 源小节 | 行号 | 行数 | 去向 | 处理 | 升格条件 |
| --- | --- | ---: | --- | --- | --- |
| 标题 + 导语 | 1–4 | 4 | 删除 | 角色总序退役（计划 D6） | — |
| 问题 | 5–19 | 15 | `quality-outcome` | 重写为合同作者动机，去掉 checklist 说教 | 见 Q1 |
| Quality Outcome Contract（YAML 模板） | 20–36 | 17 | 参考层 | 降为深度材料。字段集合的权威是 `TaskRevision.quality_outcome`（`schemas/task-work.schema.json` L18、L179–190 的 `QualityOutcome`）。原文「`orbit new-task` 结构校验」是 v1 命令，不引用 | — |
| Quality Outcome Contract（阈值必须能判断「变好」） | 37–41 | 5 | `quality-outcome` | 压缩搬入 | 见 Q1 |
| 通用审查问题 | 42–66 | 25 | `review` | 压缩搬入 | 见 Q1 |
| Review 输出（verdict 模板 + outcome 未达标不能完成） | 67–82 | 16 | 删除 | `GateEvaluation.quality_outcome_verdict` 为 pass/fail/partial（`schemas/gate.schema.json` L114、L138；`contract.yaml` L1099–1100、L1138–1145）。`review-report` 不是合同概念 | — |
| Review 输出（finding 四要素 + PASS 定义） | 83–91 | 9 | `review` | 压缩搬入。Finding 合同字段是 `body` 字符串 + `basis` / `severity`（`schemas/finding.schema.json` L13–35），没有 symptom/source/consequence/remedy 四列——四要素仍是规则写法，不是 schema | 见 Q1 |
| Review 输出（submit 命令 + 不改 manifest） | 92–94 | 3 | 删除 | 评估提交是 `orbit v2 evidence submit --proposal` 再 `orbit v2 gate submit --def`（`lib/orbit/v2/cli.rb` L355–358、L414）。不是 `review-report.yaml` | — |
| Finding 质量门槛 | 95–106 | 12 | `review` | 压缩搬入。这是反向约束与降级路径的主素材 | 见 Q1 |
| Reviewer 行为升级 | 107–141 | 35 | `review` | 压缩搬入 | 见 Q1 |
| LLM Coding Failure 审查 | 142–178 | 37 | 删除 | 与 implementer 三份规则重复。reviewer inherit 的合同支撑是 `closure_basis_freezes` 含 `assigned_rule_resolution_ref`（`contract.yaml` L937），不是 `effective_verification_plan_digest`。不在 `review.md` 再抄——否则改一条实现规则要动两个 digest | — |
| Final Audit 和 E2E | 179–187 | 9 | `review` | 压缩搬入 | 见 Q1 |
| Safety Sink | 188–196 | 9 | `review` | 压缩搬入。高危害，评审默认必须看见 | 见 Q1 |
| Release Gate 分层 | 197–199 | 3 | `mutating-surface` | 压缩搬入 | 见 Q1 |
| 规则同步 | 200–203 | 4 | `review` | 压缩搬入 | 见 Q1 |
| Lead 行为升级 | 204–229 | 26 | `quality-outcome` | 压缩搬入 | 见 Q1 |
| 低价值完成反例 | 230–264 | 35 | `quality-outcome` | 压缩搬入（反向约束主素材） | 见 Q1 |

小节合计：264。

### 行数对账

| 去向 | 行数 |
| --- | ---: |
| `rules/minimal-implementation.md` | 105 |
| `rules/targeted-fix.md` | 54 |
| `rules/test-selection.md` | 135 |
| `rules/review.md` | 103 |
| `rules/vantage-audit.md` | 0（新写） |
| `rules/structured-boundary.md` | 56 |
| `rules/mutating-surface.md` | 37 |
| `rules/quality-outcome.md` | 94 |
| 参考层 | 153 |
| 删除 | 164 |
| **合计** | **901** |

验算：105+54+135+103+56+37+94 = 584；584+153+164 = 901。

相对初稿：删除 193 → 164。挪出的 29 行是 HEAD 上解析不到替代物的内容：testing Verdict 13 行入 `test-selection`；quality Review 输出中 finding 四要素 9 行入 `review`；testing Output 里 user_journeys / test-hook / artifact inspect / test_level 7 行入参考层。对账变了，以 HEAD 可解析为准。

源行进入任务文件后还要按 D8 重写。`test-selection` 源行 135，预估成文仍 140。G.2 若压不进 150，把 Test Contract 的 test map 细项再降到参考层，不新开第 9 个任务文件。

#### 删除列 HEAD 核验

每一行删除都在下面给出可 `rg` 的出处。查不到真实替代物的已经改去向，不留在本列。

| 源 | 行 | 行数 | HEAD 出处 |
| --- | --- | ---: | --- |
| coding | 1–6 | 6 | 计划 D6（角色文件退役），不是 runtime 替换 |
| coding | 7–10 | 4 | `contract.yaml` L1049–1071 `submission_artifact_refs` + `implementation_check` 必填；L1035 同 ID 异内容 fail closed |
| coding | 23–34 | 12 | ADR-005（v1 退役）；ADR-004 L32/L462（ADR 不自动进 required files）；与已入 `minimal-implementation` 的「先读再写」重复 |
| coding | 35–38 | 4 | 无独立规范，子节已入任务文件 |
| coding | 117–122 | 6 | ADR-004 决策四；`schemas/evidence.schema.json` L63–72 |
| coding | 308–324 | 17 | 同上 `implementation_check` 必填字段 |
| coding | 325–338 | 14 | 与已入「禁止假完成」重复；`contract.yaml` L252 `dispatch_barrier` |
| coding | 370 | 1 | `contract.yaml` L252；`cli.rb` L557–572 |
| testing | 1–6 | 6 | 计划 D6 |
| testing | 21–32 | 12 | 与已入 Testing 目标重复；ADR-004 L462 |
| testing | 172–190 | 19 | 与已入 `test-selection` 四节重复；L252 `dispatch_barrier` |
| testing | 262–263 | 2 | `cli.rb` L355–358 `evidence submit --proposal` |
| testing | 267 | 1 | `cli.rb` L557–572 `complete` 派生 `closed` |
| quality | 1–4 | 4 | 计划 D6 |
| quality | 67–82 | 16 | `schemas/gate.schema.json` L114/L138；`contract.yaml` L1099–1100、L1138–1145 |
| quality | 92–94 | 3 | `cli.rb` L355–358、L414 |
| quality | 142–178 | 37 | `contract.yaml` L937 `assigned_rule_resolution_ref` |

合计 6+4+12+4+6+17+14+1+6+12+19+2+1+4+16+3+37 = 164。

明确不再引用的幽灵名：`orbit artifact inspect`、`--artifact-ref`、`user_journeys`、`test-hook`、`review-report`（合同概念）、`orbit new-task`。

---

## Q3 单文件模板实例

下面是 `rules/minimal-implementation.md` 的完整正文，供 G.2 按此粒度写其余七份。不是骨架。按 D8：必备 0–7 全写；条件性只写第 8 项反问法。第 9、10 项不适用，不凑。

判据写成「问题 → 判定 → 动作」。**最小 ≠ 一次性**：先跑通当前合同，但「只为当下、明知下一轮整段替换」的壳也不算最小。

```markdown
---
description: Use when implementing a scoped feature, refactor, or contract-bound change that must stay the smallest change that satisfies the current task — not when isolating a failing symptom (use targeted-fix) and not when only reviewing or only choosing tests.
---

# 最小实现

**所有权边界**：本文只拥有当前 attempt 里「这处改动是否满足合同的最小变化」的判定、降级与升格。产品事实、schema、`verification_class`、budget、gate 语义由 TaskRevision / ADR / `contracts/` 拥有，本文只链接锚点，不复制正文。根因与三次假设归 `targeted-fix`；写不写测试归 `test-selection`；符号是否像过程名归 `vantage-audit`；名单 / 字段族 / 旧路径关闭归 `structured-boundary`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。不要为了让 diff 看起来更完整而制造改动。

## 判据

先把被讨论的符号、抽象或依赖的消费者分成 production / non-production / ambiguous，再问：

- 删掉这处改动，当前 TaskRevision 哪一条 acceptance 或 quality outcome 会失败？指不出条款 → 不写。
- 这个抽象现在有合同内的第二个 production 调用方吗？没有 → 不引入。
- 更小的改动能满足同一条条款吗？能 → 选它。
- 这是只为当下、下一轮注定整段替换的壳吗？是 → 换成能留下的路径，或按升格交缺口。

## 反问法警告

不要问「这样是不是更完整 / 更通用 / 以后更好改」。那个问法对「单一用例上的提前抽象」给反答案。要问「删掉它谁会坏」。

## 反向约束

| 看起来像多余 | 为什么放行 | 备注 |
| --- | --- | --- |
| 复用项目已有 helper / 模式，即使多碰一个文件 | 复用降低已经存在的复杂度，不是为第二个实现预留 | |
| 清理本次改动造成的 unused import、dead branch、fixture | 精准修改的一部分 | |
| 合同或项目既有模式已经要求的接口、配置、扩展点 | 需求已在合同里，不是发明未来 | |
| 项目流程或本 task 明确要求跑 formatter，因而改动了格式 | 格式探针会永久命中这些 diff | 会被永久命中，别每轮重推 |

## 降级路径

- 想法对，但删掉它当前 acceptance 仍成立 → 不写进本 diff。需要记住就写 `TODO` 或 known gap，不升级成抽象。
- 修复或实现开始级联到无关模块 → 范围外问题 payload，本 attempt 不改完。
- 风格偏好、注释拼写、import 顺序 → 不改，也不报 finding。

## 规则内优先级

先保住合同内最小可验证、且不注定被替换的变化。一处能指到条款的删除，好过一组指不到条款的「以后会用到」的新增。

## 升格条件

只有当两个以上实现都满足本规则与当前合同，但在已接受的原则之间取舍不同（例如复用别扭的旧 API，还是加一个更小的本地函数），且本规则没有直接裁定时，才算边界。有唯一答案的改写——删掉无条款可指的 service、strategy、provider、base class、interface 或配置层——不是边界。

停下时按类型交 payload，不要混用一种格式：

| 类型 | 何时用 | 交什么 |
| --- | --- | --- |
| 裁不了的缺口 | 两方案都过判据，本规则无裁定 | `待裁定：<问题> —— <2–3 个候选与各自代价>`，交付摘要单独列出 |
| 报一条缺陷 | 仅复核任务。发现合同被违反 | 位置（文件:行）+ 能自己复现的证据 + 影响 |
| 发现范围外问题 | 真问题但不在本 attempt 合同内 | 问题描述 + 影响范围 + 建议方案；本 diff 不改 |

不要自己选一个写进代码。不要用「按需」「视情况」绕开。不要只在对话里拍板。裁定后删干净缺口行，不留「原本有一条待裁定」。

## 先读再写

写之前读改动面：目标文件和相邻实现、同类 route / service / test 的既有模式、文件顶部 imports、相关测试里的真实预期。代码库没有可复用模式时，说明这一点并给出最小一致方案；不要默默引入外来风格、库或架构。

当前代码、diff、测试、日志和 task contract 优先于聊天历史。

## 假设先说

需求、接口、数据形状、认证、持久化、缓存、错误处理或外部依赖有多种可行方案时，先写假设、权衡、为什么不选更复杂的方案、哪些点要用户确认。选择写进 task contract、evidence 或 handoff，不只留在 diff 或对话里。

## 精准修改

不改无关文件、无关命名、注释拼写或 import 顺序。不跑会重排大文件的 formatter，除非项目流程或当前 task 明确要求。没写进 `out_of_scope` 的原始要求默认仍要满足；发现原设计不可行时更新合同或进入 blocked，不在代码里静默缩小目标。

## 依赖

新增依赖前先证明：项目已有能力、标准库或平台 API 不够用。确实新增时说明原因，并同步 lockfile。

## 假完成

不能用下面这些让当前 slice 看起来通过：删除或弱化已有 gate；把必须项静默改成 out of scope；用「后续再补」替代当前必须能力；用业务层兜底掩盖未接通的入口。用户可以接受风险，但必须写进 evidence 或 handoff，不能包装成已验证完成。
```

---

## Q4 投递名单

接进 `dispatch --rule` 默认的 5 条：

| 默认规则 | 挂在谁身上 | 为什么接 | 不接的代价 |
| --- | --- | --- | --- |
| `minimal-implementation` | implementer | #5 是愿景里「底座先加固、核心没接上」的原病例 | 循环会稳定地过度设计 |
| `targeted-fix` | implementer | #1 / #9 是修复链路把修复当主线、补丁链失控 | 失败后继续叠 patch |
| `test-selection` | implementer | #8 / #10 发生在写测试的人身上；v2 CLI 还没有独立 tester 角色 | 一次性验收变成永久测试，或弃主线扩测试 |
| `vantage-audit` | implementer | #2 发生在实现当时；评审后补命名成本更高 | 阶段标签进正式符号 |
| `review` | reviewer，**叠在 subject attempt 已钉规则之上** | #7 的语义面；机械面已由 `closure_basis_digest` 冻结 | 评审者没有 outcome 判据，或与实现者不同本 |

其余 3 条落地、显式 `--rule` 才挂：

| 先不接 | 为什么 |
| --- | --- |
| `structured-boundary` | 只在碰 parser / validator / 状态机 / artifact writer 时成立。默认挂上会让改一句名单规则作废所有普通实现 attempt。 |
| `mutating-surface` | 只在碰 CLI / installer / release 时成立。频率低于前五条。 |
| `quality-outcome` | 给写合同的人，不是给已经冻结合同的 implementer。写进实现 attempt 会与「评审不得移标准」抢通道。 |

### reviewer 与「同一份字节」

愿景第 2 节：评审者拿到与实现者逐字节相同的规则。因此 reviewer 默认不是「只挂 `review.md`」，而是：

```text
subject attempt 的 required_rules
  + rules/review.md（relation: supplements）
```

`review.md` 不复写实现规则正文。这是 Q2 删除「LLM Coding Failure 审查」37 行的前提。若 G.2 做不到 inherit，应停下，不要把那 37 行抄回 `review.md`——那会破坏变更隔离。

`targeted-fix` 挂到每一次 implementer attempt，不只是 bugfix unit：#1 / #9 经常从功能任务中途开始。代价是改 `targeted-fix` 会作废所有实现 attempt。G 阶段接受这个代价；若该文件后来高频改，再拆「复现」与「三次假设」。

当前 CLI：`--rule PATH` 必填、无默认。Q4 是 G.2 要接的默认名单，不在本工单改 CLI。

---

## Q5 母版位置与分发形态

### 母版（skill 目录，只作分发源）

```text
skills/orbit/assets/rule-library/
  README.md
  MANIFEST.yaml
  tasks/
    minimal-implementation.md
    targeted-fix.md
    test-selection.md
    review.md
    vantage-audit.md
    structured-boundary.md
    mutating-surface.md
    quality-outcome.md
  resident/
    AGENTS.md.template
  reference/
    report-and-evidence-examples.md
```

放在 `assets/` 而不是 `references/runtime/`：这些文件的身份是「拷进用户项目的载荷」，不是本仓库开发 agent 的运行时必读。G.2 退役 `references/runtime/coding-guideline.md`、`testing-guideline.md`、`quality-outcome-and-review.md` 三个角色文件。

`MANIFEST.yaml` 每条记录：`rule_id`、相对路径、是否默认、适用 profile（implementer / reviewer）、母版 `content_sha256`。`rule_id` 建议 `orbit.minimal-implementation` 这种稳定 id，不把路径当 id。

### 项目内落点（git 可见）

```text
rules/
  .orbit-source.yaml          # 上次装入的母版 sha256；纳入 git
  minimal-implementation.md
  ...
docs/orbit/reference/
  report-and-evidence-examples.md    # 参考层；默认不进 --rule
AGENTS.md                     # 仅当项目还没有该文件时创建
```

选择 `rules/` 的原因：

- 合同测试已经用 `rules/*.md` 作为项目相对路径（例如 `rules/inc6b-coder.md`）。零合同改动。
- 不在 `.orbit/` 下。`.gitignore` 是 `.orbit/*`，放进去则规则不可见、不能产生可评审 diff，也和「规则必须是项目内真实文件」一致。
- 不用 `docs/agent/`。那是 Codex 路由器常指向的专项文档位置；任务规则走 `--rule`，混放会把两条通道写成一条。

参考层放 `docs/orbit/reference/`，不放 `rules/`，避免被误当成可钉文件。

本设计不依赖符号链接、绝对路径或 skill 目录运行时解析。

### `init` 与更新命令

`orbit v2 init` 在现有 protocol / policy / key 步骤之后，增加一次规则拷贝（不新发明用户步骤）。拷贝对象：`tasks/*.md` → `rules/`，`reference/` → `docs/orbit/reference/`，并写 `rules/.orbit-source.yaml`。`AGENTS.md`：目标不存在才从模板创建；已存在则打印一段「请把路由器表附到现有 AGENTS.md」的提示，**绝不覆盖**。

更新命令：`orbit v2 rules update`。

产生可评审 diff 的方式：把新母版写进工作区已跟踪文件，由项目 git diff 承担评审。Orbit 不在规则正文里插入冲突标记。

已修改文件的处理：

| 工作区文件 vs `.orbit-source.yaml` 里上次装入的 sha256 | 动作 |
| --- | --- |
| 相等（项目没改过） | 用新母版覆盖，更新 manifest。git diff 就是升级评审面 |
| 不相等（项目改过） | **跳过覆盖**。另写 `rules/<name>.md.upstream`，命令结束时打印跳过清单 |
| 项目没有该文件 | 按新母版创建 |
| 项目多出来的、manifest 没有的文件 | 不动 |

不在活规则里写冲突标记：那会让新 dispatch 要么 fail closed，要么把冲突标记钉成规则正文。需要合并时由人用 git / `git merge-file`，合并结果再进下一次 dispatch。

`rules update` 只拷文件、写 manifest，不改已钉死 attempt 的 digest。旧 attempt 仍按旧字节解释；新 dispatch 才读新文件。

G.2 实现这些命令。本文件不改 `lib/`。

---

## Q6 常驻层（用户项目 `AGENTS.md` 模板）

对象是 **用户项目** 的 `AGENTS.md`，不是本仓库根 `AGENTS.md`。常驻层 ≤150 行。按 `codex-agents-md-loading.md` §5：少量常驻 + 可观察触发条件。链接不等于加载；Orbit attempt 里专项正文只来自 `--rule`。

### 放什么

1. 项目是做什么的、明确不做什么（占位，由项目自己填）。
2. 安装 / 测试 / 检查命令（占位）。
3. 一条工作记忆顺序：当前代码、diff、测试、日志、task contract 优先于聊天历史。
4. 停止条件（可观察、非任务规则）：没有 quality outcome 不开写实现；身份冲突停下；破坏性操作先确认。
5. 路由器表：触发动作 → Orbit 将钉入的规则文件。表里只写路径和触发，不写规则正文。
6. 通道说明：本文件是路由器；`rules/*.md` 由 `orbit v2 dispatch --rule` 钉入。非 Orbit 会话若仍要做表中动作，要么先开 Orbit task，要么在动笔前完整读对应文件——但那不是可信投递。
7. 自我限定：本文件不是规则库，也不替代 ProjectPolicyRevision / TaskRevision。

### 不放什么

- 八份任务规则的判据、反向约束、降级、升格正文。
- `verification_class`、budget、closure basis 的产品教程。
- evidence / review / test 的 YAML schema。
- 「coder 读 coding-guideline」这类角色映射。
- 本仓库根 `AGENTS.md` 里的客户端测试纪律原文（那是 Orbit 开发仓库的纪律，不是产品默认协议）。

### 路由器表（模板正文）

```markdown
## 按需规则（由 Orbit dispatch 钉入，不要把正文抄到本文件）

在执行下列动作之前，当前 attempt 应已被钉入对应文件；若当前不是 Orbit attempt，先开 task 或完整读取该文件：

- 实现功能、重构、按合同改代码 → `rules/minimal-implementation.md`
- 复现、隔离或修复一个失败症状 → `rules/targeted-fix.md`
- 新增、修改、删除或为测试辩护；给 evidence 选 verification_class → `rules/test-selection.md`
- 独立判断质量结果是否变好 → `rules/review.md`
- 新增或重命名用户可见符号、文件、API、对外陈述 → `rules/vantage-audit.md`
- 改 parser / resolver / validator / 状态机 / artifact writer / gate / tool 边界 → `rules/structured-boundary.md`
- 改 CLI、安装、卸载、迁移、打包、release 资产 → `rules/mutating-surface.md`
- 撰写或改写 quality outcome / 阈值 / 无效完成 → `rules/quality-outcome.md`
```

G.2 写成的模板应控制在约 80–120 行，留空位给项目自己的目录与命令。

---

## 偏离工单之处

1. **Q2「去向」枚举没有「常驻层」。** 原准备把 coding「输入顺序」末两行标成常驻层。改为整节删除（与「先读再写」、ContextProjection 重复），Q6 只保留一句路由器记忆。对账不引入第四种去向。
2. **reviewer 默认 = subject 已钉规则 + `review.md`。** 工单 Q4 问「哪 4–5 条」，未写 inherit。这是愿景「评审者拿到同一份字节」的直接推论，也是删除 37 行重复审查清单的前提。
3. **`vantage-audit.md` 源行 = 0。** 愿景候选表已声明无素材。不从 901 行硬挤。
4. **D8 编号：裁决表写「七项必备」，§3 正文标题是 0–7 共八项 + 8–10 条件性。** 工单补充节也仍写七项。规格唯一出处是计划 D8 正文；跟正文，不改计划、不改工单。
5. **工作区在动手前不是干净的。** 见下一节。本文件只改自己，未改那些已有改动。
6. **删除列返工（审核阻断项）。** 初稿 193 行删除里有三处点名了 HEAD 上不存在的机制。已逐条重验：164 行留下并写清出处；29 行改去向（13 → `test-selection`，9 → `review`，7 → 参考层）。参考层文件从过程名 `demoted-from-role-guidelines.md` 改为 `report-and-evidence-examples.md`。

没有放宽 `canonicalize_path!`。没有把规则放到 skill 目录当运行时路径。没有改本仓库根 `AGENTS.md`。没有宣称阶段 G 完成。

---

## 停止条件

工单第 4 节五条 + 补充节一条，均未触发：

- 901 行均有去向。删除列 164 行均有 HEAD 出处；查不到替代物的已改去向，没有为了对账硬留。
- 设计不依赖放宽路径契约或其它产品校验。
- 8 个任务文件，预估行数均 ≤150。
- 未发现裁决 1 / 裁决 2 有误。
- 未修改 `docs/` 既有文件。观察到工作区在本工单开始时已有未提交改动（`docs/README.md`、`docs/plan/vision-completion-plan.md`、未跟踪的 `docs/plan/g1-workorder.md`），按停止条件「发现 docs 重组问题报给统筹、不要自行修」——这些改动不是本工单产出，也不在本文件里改。
- 八条规则都能写成可证伪判据（见 Q1 升格表与 Q3 实例）。没有「应该 / 尽量」充数的条目。

---

## G.2 才做的事（本文件不做）

- 按 Q3 粒度写其余七份规则，退役三个角色文件。
- `init` 拷贝与 `orbit v2 rules update`。
- dispatch 默认名单接线（含 reviewer inherit）。
- 从规则文件读取 `description` 做机器选择。
- 改 `lib/`、`tests/`、`skills/` 除设计指定的母版新文件之外的任何内容。

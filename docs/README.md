# Orbit 文档索引

按**体裁**分目录，每类内容只有一个出处。找东西先看这张表。

| 我想知道… | 去哪 |
| --- | --- |
| 为什么这么设计 | [`adr/`](./adr/) —— 架构决策记录，**唯一 normative 语义来源**（连同 `contracts/orbit-v2/`） |
| 接下来做什么 | [`plan/vision-completion-plan.md`](./plan/vision-completion-plan.md) —— 唯一前瞻计划 |
| 欠了什么、能不能动这块代码 | [`plan/debt-ledger.md`](./plan/debt-ledger.md) —— 唯一欠账出处 |
| 判据、外部规范、事故发现 | [`reference/`](./reference/) —— 参考资料，会被反复查阅 |
| 之前发生过什么 | [`history/`](./history/) —— 已完成工作的记录，不作现在时指令阅读 |

## 目录

### `adr/` —— 架构决策

| 文件 | 主题 |
| --- | --- |
| `001-task-evidence-trust-boundaries.md` | Task/Evidence 信任边界 |
| `002-herdr-runtime-identity-boundary.md` | Herdr 运行时身份边界（推翻了 ADR-001 的 automatic session refresh） |
| `003-lead-orchestrated-dynamic-agent-team.md` | Lead 编排的动态 Agent 团队 |
| `004-role-rule-context-evidence-binding.md` | 角色/规则/上下文/证据绑定 |
| `005-orbit-v2-clean-cut-and-legacy-retirement.md` | v2 一刀切与 v1 退役 |
| `006-serialized-lead-orchestration-control-loop.md` | 串行 Lead 编排控制循环 |

ADR 用**修订记录**方式演进：原文不删，就近加已取代标注，文末追加修订节。

### `plan/` —— 活跃计划

| 文件 | 说明 |
| --- | --- |
| `vision-completion-plan.md` | 阶段 G–K，让 Orbit 达成"在合理范围内自动实现需求代码"的能力 |
| `debt-ledger.md` | 有意推迟的项目，含推迟理由与解除条件 |

### `reference/` —— 参考资料

| 文件 | 说明 |
| --- | --- |
| `codex-agents-md-loading.md` | Codex 的 `AGENTS.md` 发现/合并规则与编写方法；规则库设计依据 |
| `alpha-test-findings.md` | Alpha 测试十项病例与设计状态矩阵；规则库的病例来源 |
| `test-explosion-case.md` | 测试爆炸事故与跨 Agent 结论 |

### `history/` —— 交付历史

| 文件 | 说明 |
| --- | --- |
| `v2-delivery-record.md` | Slice 0–6 的交付编排与验收条目（原 Orbit v2 Implementation Plan） |
| `agent-independent-control-amendments.md` | agent-independent control 的设计来源，条款已整合进 ADR-003/004/005/006 |
| `slice6-handoff.md` | Slice 6 暂停时的状态与纠偏路线，ADR-003/005/006 引用其为 task-centric 转向背景 |
| `slice6-workorder.md` | Slice 6 纠偏工单，ADR-005 引用其第 6 节为 v1 删除的决策依据 |
| `slice6-task-local-storage-design.md` | Task 本地存储布局设计 |
| `slice6-minimal-cli-path-design.md` | 最小真实 CLI 路径设计 |

`history/` 中的文档保留写作当时的原文与路径。**其状态描述反映当时事实**，与今日现状的差异在各文件头部说明。

## SSOT 约定

同一事实只有一个权威出处；其他地方只能引用，不能复制。

| 事实 | 权威出处 |
| --- | --- |
| 语义合同、schema | `contracts/orbit-v2/`（`schemas/*.json` 由 lib 运行时加载） |
| 权威归属（fact → owner） | `contracts/orbit-v2/authority-matrix.yaml` |
| 已闭合不变量 | `contracts/orbit-v2/validator-invariants.md` |
| 架构决策 | `docs/adr/` |
| 前瞻计划 | `docs/plan/vision-completion-plan.md` |
| 欠账 | `docs/plan/debt-ledger.md` |

`docs/` 下的散文描述若与 `contracts/` 或 ADR 冲突，以后者为准。仓库根 `AGENTS.md` 是**开发 Agent 的客户端纪律**，不是产品 authority。

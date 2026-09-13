# Handoff：阶段 G 已完成，先讨论重构方案

当前先完成 Orbit 减重与重构方向讨论：工具目标、模型与程序的职责、与 Zeen 反馈执行服务的独立接入，以及最小验收路径。尚未批准具体实现方案，不直接启动旧阶段 H、产品初始化、真实模型验证或实现 Goal。

开发本仓遵守[开发协作流程](../agents/development-workflow.md)，由根 `AGENTS.md` 加载。Zeen 的规范与代码保存在[交接包](../reference/zeen-orbit-handoff-20260913/README.md)，仅作参考；本仓开发规范不代表 Orbit 产品已具备自动监督能力。

- 接续日期：2026-09-13；实现状态基于阶段 G 的 2026-08-17 交付
- 基线 HEAD：`24efecb`（本清理提交叠在其上）
- 对象：下一个对话 / 下一个 agent。读完本文再读计划，不要从 `history/` 开始改。

## 先读什么

1. 本文（现在在哪、下一步是什么、不要重开的争论）
2. [新交接包](../reference/zeen-orbit-handoff-20260913/README.md) 的用户边界与未决事项，再读 [`vision-completion-plan.md`](./vision-completion-plan.md) D1–D11 理解既有取舍
3. 动 `lib/` 或 `contracts/` 前：[`debt-ledger.md`](./debt-ledger.md)
4. 语义以 `contracts/orbit-v2/` 与 `docs/adr/` 为准

工单（`history/g*-workorder.md`）没有裁定权。G.1 设计稿已归档，切分事实以仓库里的规则文件和 D11 为准。

## 现在的产品状态

阶段 **G 已交付**。规则能装进项目、能钉进 attempt、能更新、能被评审者继承。

| 能力 | 落点 |
| --- | --- |
| 八份任务规则 + 共享升格格式 + 常驻路由器模板 | `skills/orbit/assets/rule-library/` |
| `init` 拷 `tasks/`+`shared/` → `rules/`，参考层 → `docs/orbit/reference/`，无 `AGENTS.md` 才创建 | `lib/orbit/v2/cli.rb` |
| implementer 默认钉四条 + 共享 payload；reviewer inherit subject 已记录字节 + `review.md` | 同上 |
| `rules update`：未改过覆盖，改过写 `.upstream` | 同上 |
| 本仓库根 `AGENTS.md` | **开发仓纪律，不是产品默认协议** |

CLI 现有：`init` / `task start` / `rules update` / `dispatch` / `evidence submit` / `gate submit` / `finding resolve` / `complete` / `status`。控制流命令（retry / fuse / budget override / checkpoint 观测）库内有、未暴露。

**还没有的**：把 `ContextProjection` 交给 agent 的出口（H）；外层循环（I）；真正拉起 agent（J）；愿景验收（K）。v2 **仍不能让任何 agent 发生**。

## 已用测试钉住的性质

除非改到对应代码或出现新的失败证据，不重复验证这些性质：

- 默认规则的 `content_sha256` 等于文件真实 digest
- 改规则字节后，旧 attempt 仍钉旧 digest；新 dispatch 钉新字节
- 历史复验走 `RuleResolution.validate!` 的 `verify_files: false`（`contract.yaml:158`）
- 规则中途被改 → reviewer inherit 在 `RuleResolution.build` 以 `rule_resolution_digest` fail closed（D11，正确行为）
- `rules update` 不改已钉 attempt，不在活文件里插冲突标记
- 已有项目 `AGENTS.md` 时 `init` 字节不变

## 不要重新提出

| 已否 | 为什么 |
| --- | --- |
| 规则留在 skill 目录当 `--rule` 运行时路径 | `canonicalize_path!` 会拒；放宽它是安全边界 |
| hybrid（skill 基线 + 项目增量） | 同一 `rule_id` 两来源 |
| 先写全套投递再接循环 | alpha #5 |
| 升格 payload 复制进 8 份规则 | 爆炸半径与抽共享文件相同，但会漂移（D11） |
| 让 inherit 跳过 `verify_files` | pin 与磁盘脱钩 |
| 真实执行层先于 runner | D3：先测确定性循环 |
| stub 留成永久件 | D4，自我违规 |
| Zeen 四层文档 / 多席轮次 / 三库正文 | D9 |
| 完整性下界 / `needs_user` payload / Finding 门槛产品化 | D10，未承诺 |

## 当前讨论的交付

由 Root 直接核查并收敛重构方案，不默认派发。明确哪些版本、证据与上下文机制保留，哪些协议操作应由程序承担；说明运行中如何发现并落实纠偏，以及如何避免 Orbit 和反馈执行服务拥有两套调度状态。

方案需包含正常交付与该停时能停的最小验证，区分确定性测试和真实模型效果。未定产品问题逐项讨论，既有明确授权不重复询问。形成共识后，先对齐需要变化的 ADR／合同与实施计划，再进入开发。

旧 H（投递出口）、I（runner）、J（真实执行与观察）、K（愿景验收）见[既有计划](./vision-completion-plan.md)。它们仍是差距清单，但不是当前开工顺序；不在本交接内提前决定重写或删除产品能力。

## 本轮从活跃层清走的文件

| 原位置 | 去向 | 原因 |
| --- | --- | --- |
| `docs/plan/g1-workorder.md` 与 `g1-rule-library-design.md` | `docs/history/` | G.1 已完成 |
| `docs/plan/g2a`–`g2e-workorder.md` | `docs/history/` | G.2 已完成（无独立 `g2c-workorder.md`，那轮只经 herdr 派发） |
| `skills/orbit/references/runtime/guide.md` | `docs/history/v1-runtime/` | v1 命令面，会让 agent 按已删除的命令行事 |
| `skills/orbit/references/runtime/core-operating-model.md` | `docs/history/v1-runtime/` | 同上，947 行 |

v2 操作入口只剩 [`skills/orbit/SKILL.md`](../../skills/orbit/SKILL.md) 与 `orbit v2 --help`。完整 v2 runtime 文档重写仍是欠账第 6 项，但风险从「skill 目录里有一份看起来像现行指南的 v1 稿」降为「history 里的史料」。

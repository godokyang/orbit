# Handoff：阶段 G 完成，下一阶段是 H

- 日期：2026-08-17
- 基线 HEAD：`24efecb`（本清理提交叠在其上）
- 对象：下一个对话 / 下一个 agent。读完本文再读计划，不要从 `history/` 开始改。

## 先读什么

1. 本文（现在在哪、下一步是什么、不要重开的争论）
2. [`vision-completion-plan.md`](./vision-completion-plan.md) 顶部 D1–D11（全部有约束力的裁决）
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

不要在 H 里重测这些，除非你改到对应代码：

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

## 下一阶段：H

规模最小。`ContextProjection`（`lib/orbit/v2/context_projection.rb`）已是纯函数，缺 CLI。

交付：一条只读命令，把 `work_agent` / `evaluator` / `lead` 三种投影打到 stdout 或文件；投影里的规则来自 attempt 已钉的 rule resolution。

不要在 H 里做 runner、不要拉起 agent、不要写新规则、不要改 pin 语义。

然后 I（stub runner）→ J（真执行 + 可信观测，拆 stub）→ K（场景 A 能跑完、场景 B 能停住；B 更重要）。

## 本轮从活跃层清走的文件

| 原位置 | 去向 | 原因 |
| --- | --- | --- |
| `docs/plan/g1-workorder.md` 与 `g1-rule-library-design.md` | `docs/history/` | G.1 已完成 |
| `docs/plan/g2a`–`g2e-workorder.md` | `docs/history/` | G.2 已完成（无独立 `g2c-workorder.md`，那轮只经 herdr 派发） |
| `skills/orbit/references/runtime/guide.md` | `docs/history/v1-runtime/` | v1 命令面，会让 agent 按已删除的命令行事 |
| `skills/orbit/references/runtime/core-operating-model.md` | `docs/history/v1-runtime/` | 同上，947 行 |

v2 操作入口只剩 [`skills/orbit/SKILL.md`](../../skills/orbit/SKILL.md) 与 `orbit v2 --help`。完整 v2 runtime 文档重写仍是欠账第 6 项，但风险从「skill 目录里有一份看起来像现行指南的 v1 稿」降为「history 里的史料」。

# G.2a 工单：规则投递的垂直切片

- 日期：2026-08-17
- 基线 HEAD：`f81515d`
- 执行：grok（wA:pG）
- 性质：**派发文件，不拥有裁决。** 裁决在 [`vision-completion-plan.md`](./vision-completion-plan.md) D1–D10；切分在 [`g1-rule-library-design.md`](./g1-rule-library-design.md)。本工单与二者冲突时以它们为准。

## 为什么先做切片而不是先写全 8 份

G.1 已经把 901 行切完了，剩下的工作看起来是「照着写 7 份，然后接线」。但那个顺序会让我们在**从未证明过一条规则真能被钉入**的前提下先写约 940 行正文。这正是愿景里 alpha 病例 #5 的形状：底座加固到很深，核心没接上。

所以 G.2a 只做一条：把 G.1 设计稿 Q3 里那份已经写完的 `minimal-implementation.md` 变成真文件，让 `orbit v2 dispatch` 真的把它钉在 attempt 上。写满 8 份是 G.2b 的事。

## 范围

做这些：

1. 母版落地：`skills/orbit/assets/rule-library/tasks/minimal-implementation.md`，正文取 G.1 设计稿 Q3 代码块（那是完整正文，不是骨架；照抄，不要重写）。
2. `skills/orbit/assets/rule-library/MANIFEST.yaml`：按 Q5 的字段（`rule_id`、相对路径、是否默认、适用 profile、母版 `content_sha256`）。本轮只有一条记录。
3. `orbit v2 init` 增加规则拷贝：`tasks/*.md` → 项目 `rules/`，并写 `rules/.orbit-source.yaml`。目标文件已存在则不覆盖、打印跳过。
4. `orbit v2 dispatch` 默认名单：implementer 未显式给 `--rule` 时默认挂 `rules/minimal-implementation.md`。显式 `--rule` 仍然优先，行为不变。

**不做这些**（G.2b）：其余 7 份规则正文、reviewer inherit、`orbit v2 rules update`、退役三个角色文件、参考层文件、按 `description` 做机器选择。

## 必须证明的两件事

端到端测试要证明的不是「命令没报错」，而是：

1. **投递真的发生**：`init` 之后 `dispatch` 产出的 attempt 里，`required_rules` 含 `rules/minimal-implementation.md`，且其 `content_sha256` 等于该文件的真实 sha256。
2. **变更隔离真的成立**：改一个字节再 dispatch 一次，新 attempt 的 digest 变了，而**旧 attempt 仍按旧字节解释**。这是整个细切方案的全部理由；证不出来，细切就只是文件更多。

第 2 条如果发现产品层做不到，停下报我，不要改断言迁就。

## 约束

- 不放宽 `canonicalize_path!`。规则必须是项目内真实文件、项目相对 POSIX 路径。
- `rules/` 在项目根，不在 `.orbit/` 下——那里被 `.gitignore` 挡住，规则就不可评审了。
- 不改本仓库根 `AGENTS.md`。
- 测试预算：≤2 个方法、≤150 行。超了先说明再扩。
- CPU 纪律：单方法迭代用 `ORBIT_V2_ONLY`；focused 全量最多 2 次，收口时才跑。

## 停止条件（撞到就停，不要自行绕开）

- 需要放宽任何既有产品校验才能接线。
- 变更隔离证不出来。
- `init` 往项目里写文件的行为与既有 protocol/policy/key 步骤的失败语义冲突。
- 发现 G.1 切分或 D1–D10 有误。

## 交付

改动面报告 + 上面两条证明的实际测试输出。不要宣称阶段 G 完成。

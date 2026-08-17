---
description: Use when independently judging whether a change improved the contracted quality outcome — not when implementing, and not when the only job is to restate a green command.
---

# 评审

**所有权边界**：本文只拥有当前评审 attempt 里「质量结果是否变好」的判定、降级与升格。产品事实、`closure_basis_digest`、GateEvaluation / Finding schema、`verification_class` 由 TaskRevision / ADR / `contracts/` 拥有，本文只链接锚点，不复制正文。实现规则正文归本次 subject 已钉的规则；写合同归 `quality-outcome`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。不要为了凑 finding 数量制造改动。

## 判据

过两轴，两轴都要出结论：

- 标准轴：对照本次 attempt 已钉的规则与冻结的 TaskRevision，删掉这条改动，哪一条 acceptance 或 quality outcome 会失败？指不出条款 → 不是合同违反。
- 规格轴：题干要求的每一项，判「做到 / 部分 / 没做 / 做多了」。做多了同样要报。

不要问「测试是不是绿了」。那个问法对「字面完成但质量结果没变」给反答案。要问「删掉它谁会坏，以及质量属性是否真的变好」。

## 反问法警告

不要用「测试通过了吗」当 outcome 判据。它对「只证明旧行为未破坏」给反答案。要问「合同里的 desired_property 现在是否成立」。

## 反发明边界

finding 只记录已经观察到的缺陷。位置、能自己复现的证据、影响三样缺一样就不是缺陷，是意见。判不了就写「未记录」，不要为了填格子虚构触发条件或后果。

## 过度纠正陷阱

评清理 / 删除 / 精简 diff 时核这五个：把义务改成许可、把设想说成已落地、删掉一条真事实、丢了出处、**删掉修复承诺却不修缺口**。第五个是自动循环特有的。

## 反向约束

| 看起来像该报 | 为什么放行 | 备注 |
| --- | --- | --- |
| 零 High/Medium，且 review surface 清楚 | 没发现阻塞问题是有效评审 | |
| 低置信风格偏好 | 不够成阻断；升格为意见或降级 | |
| 绿守卫已经查过的链接 / 格式 | 不复述自动检查 | |
| 已钉规则里的实现禁令 | 由 subject 已钉规则拥有，本文不复写 | 会被永久命中，别每轮重推 |

## 降级路径

- 答不出位置、触发条件、现有 guard 为何没挡住 → 降为意见，或先补 evidence，不写阻断 finding。
- 合同内 outcome 已达成、新风险是否 blocking 要由 policy / risk owner 裁 → 升格缺口，不自己改 acceptance。
- 风格或范围外问题 → 范围外 payload，本 attempt 不改实现。

## 规则内优先级

一份带一个已证实阻断项的短评审，好过一串鸡毛蒜皮。先判 outcome，再看行为与结构。

## 升格条件

只有当两个以上判断都满足已钉规则与冻结合同，但在已接受原则之间取舍不同（例如新发现的风险是否 blocking），且本文没有直接裁定时，才算边界。reviewer 改 acceptance、用「测试过了」代替 outcome，不是边界。

停下时交什么：见本次 attempt 已钉的 `rules/escalation-payload.md`，不要在本文件复写格式。

## 审查顺序

1. Outcome：质量目标是否达成。
2. Behavior：功能是否正确，旧路径是否安全。
3. Structure：边界、依赖方向、单一事实源是否改善。
4. Evidence：测试与 artifact 是否支撑结论。
5. Residual risk：未覆盖风险是否可接受。

先看失败路径（中断、恢复、late result、capability 不可用时是否放行），再看 happy path。字面完成但质量结果没达成、低价值搬移冒充重构、threshold 没达成却不改 scope，给阻断。

## 收尾证据

代码侧完整性审计通过，不等于真实用户路径通过；真实路径通过，也不能掩盖旧路径仍能写权威结果。缺任一项就补证据、降级，或写入 residual risk。触及删除用户数据、从用户输入构造 shell / path、改 auth / release 资产的 diff，validation 或回滚不清楚就阻塞。

本轮若改了后续 agent 的通过标准，检查已钉规则与 task contract 是否同步；不要按过期规则放行。

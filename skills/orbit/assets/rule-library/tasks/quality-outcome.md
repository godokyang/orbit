---
description: Use when writing or revising a task contract’s quality outcome, measurable thresholds, or invalid completions — not when implementing against an already-frozen contract.
---

# 质量结果合同

**所有权边界**：本文只拥有「任务合同有没有可判定的质量结果」的判定。字段集合由 `TaskRevision.quality_outcome` 拥有。对照已冻结合同做评审归 `review`。实现归 `minimal-implementation`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。

## 判据

- 合同里有没有 `user_problem`、`desired_property`、至少一条能判断「变好」的阈值、以及无效完成方式？缺任一 → 先补合同，不开写实现。
- 删掉这条 measurable_threshold，reviewer 还能不能判断结果变好了？不能 → 合同不够。
- 完成标准写的是动作（拆文件、加测试）还是质量属性？是动作 → 重写成属性，再列动作当手段。
- 某个完成方式触发了合同里的 invalid_completions 吗？触发 → 即使做了动作也不算完成。

## 反问法警告

不要问「动作做了没有」。它对「7000 行变 6900 行」给反答案。要问「维护者 / 用户现在少读或少受什么罪」。

## 反发明边界

补无效完成或被否备选时，只记录已经出现过的失败方式。判不了写「未记录」，不要发明一套没人走过的无效完成来填格子。

## 反向约束

| 看起来像合同不够 | 为什么放行 | 备注 |
| --- | --- | --- |
| 阈值不是数字，但 reviewer 能判断变好 | 阈值不必是数字 | |
| 已冻结合同上的实现 attempt | 本文不在实现 attempt 改合同 | |

## 降级路径

- 合同只有动作没有 outcome → 停下补合同，不开始实现。
- 两个阈值都能量化「变好」，但选哪一个会改变任务范围 → 升格缺口。
- 发现原设计不可行 → 更新合同或 blocked，不在代码里静默缩小目标。

## 规则内优先级

质量结果是完成标准，动作是手段。先写无效完成方式，再写要实现什么。

## 升格条件

只有当两个阈值都能量化「变好」，但选哪一个会改变任务范围时，才算边界。合同只有动作没有 outcome 仍开写实现，不是边界。

停下时交什么：见本次 attempt 已钉的 `rules/escalation-payload.md`，不要在本文件复写格式。

## 无效完成要写具体

每个改善类任务写自己的无效完成：只抽无状态 helper、只减单次成本却增加失败率、只换文案但路径仍不清、只补 try/except 但状态不可恢复、只加 facade 但旧路径仍写权威结果、只加 mock happy path。

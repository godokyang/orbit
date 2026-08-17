---
description: Use when changing a parser, resolver, normalizer, validator, state machine, artifact writer, gate, or tool boundary — not for ordinary feature plumbing that does not invent a fact source.
---

# 结构化边界

**所有权边界**：本文只拥有「正式事实源是不是结构化的、旧路径是否已关闭」的判定。最小变化归 `minimal-implementation`；同形态 sibling  sweep 归 `targeted-fix`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。

## 判据

- 限制 AI 产出或输入的主边界，是 schema / 稳定 enum / 状态机，还是会随用户措辞增长的词表？是词表 → 不成立。
- 同形态输入还会不会进入正式事实源？会 → 点状补词不算完成。
- 新状态、新字段、新 artifact 有没有 writer、reader、schema、验证路径？缺任一 → 不成立。
- 旧路径还能不能写出权威结果？能 → 没有 closure，不能宣称完成。
- 多个等价字段矛盾时是 fail closed，还是静默选一个？后者 → 不成立。

## 反问法警告

不要问「补这个词 / 这个 option 是不是就能过」。它对「名单当主边界」给反答案。要问「同形态输入会不会仍进入正式事实源」。

## 反向约束

| 看起来像名单 | 为什么放行 | 备注 |
| --- | --- | --- |
| 稳定协议枚举（status、verdict、event type、phase id） | 不会随用户输入增长 | |
| 危险命令或泄漏标记的安全兜底 | 诊断统计，不是主事实源 | |
| 已有 helper / parser / protocol API 负责这类字段 | 单一事实源已存在 | |

## 降级路径

- 当前报错调用链修了，同层级入口未查 → 补 grep / 测试，或把超出 scope 的写入 known gap。
- 必须保留兼容 fallback → 写清迁移窗口、使用条件和移除条件；永久双写不成立。
- 结构化方案与窄名单在当前合同下都能成立，且扩表风险无法从本仓库证明 → 升格缺口。

## 规则内优先级

先关掉能写权威结果的旧路径，再谈别名和名单。一个 fail closed 的单一事实源，好过一串互相修好的字段。

## 升格条件

只有当结构化方案与窄名单在当前合同下都能成立，且扩表风险无法从本仓库证明时，才算边界。用增长词表当主边界、新旧路径同时写权威结果，不是边界。

停下时交什么：见本次 attempt 已钉的 `rules/escalation-payload.md`，不要在本文件复写格式。

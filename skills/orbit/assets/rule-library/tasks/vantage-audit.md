---
description: Use when adding or renaming a user-visible symbol, file, API, or doc claim, to check that a reader at HEAD can resolve every reference without session transcript or phase labels.
---

# 视角审计

**所有权边界**：本文只拥有「站在 HEAD 的读者能否解析每个引用、核验每个断言」的判定。最小变化归 `minimal-implementation`；评审 outcome 归 `review`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。不要为了去掉过程味而删掉仍需核验的事实。

## 判据

对每个新增或重命名的用户可见符号、文件、API、对外陈述问：

**could a reader at HEAD, with no access to any session transcript, PR thread, or uncommitted draft, resolve every reference and verify every claim?**

- 不能 → 把能独立成立的事实改写成仓库视角，删掉会话残渣。
- 能，但是阶段标签、slice 名、过程编号（`FreshP6Initialization`、`xxx-slice1-handler`）→ 仍不成立，换成稳定产品能力名。
- 一个标识同时捆了对外承诺和实现绑定，本文没有裁定留哪一半 → 升格，不自己砍。

## 反问法警告

不要问「读起来像不像历史」。可解析的变更故事仍可能是过程叙述。正问就是上面那句 vantage test。

## 反发明边界

重述可保留事实时，只提取原文里已经有的命题。原文否定句本身就是备选，提取是重构不是发明。判不了写「未记录」，不要补会话里才有的出处。

## 过度纠正陷阱

清理过程叙述时核这五个：把义务改成许可、把设想说成已落地、删掉一条真事实、丢了出处、**删掉修复承诺却不修缺口**。第五个是自动循环特有的。

## 反向约束

| 看起来像过程名 | 为什么放行 | 备注 |
| --- | --- | --- |
| 仓库内可解析的 issue / 稳定文档路径 | HEAD 读者能打开 | |
| 运行时 old/new 生命周期（旧连接排空后新连接才接） | 这是机制，不是变更史 | |
| 已冻结的对外协议枚举名 | 名字就是契约 | |

## 降级路径

- 过程叙述里有可独立成立的事实 → 改写成现在时，删掉会话外壳。
- 纯过程标签、无事实载荷 → 删除或改名。
- 对外承诺与实现绑定捆在同一标识 → 升格缺口。

## 规则内优先级

先处理会进入正式目录、导出符号、public API 的名字。注释里的过程残渣次之。

## 升格条件

只有当一个名字在仓库内可解析，但对外承诺与实现绑定捆在同一标识里、本文没有裁定留哪一半时，才算边界。`FreshP6Initialization`、`xxx-slice1-handler` 这种阶段标签不是边界。

停下时交什么：见本次 attempt 已钉的 `rules/escalation-payload.md`，不要在本文件复写格式。

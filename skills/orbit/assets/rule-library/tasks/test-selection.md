---
description: Use when adding, changing, skipping, or defending a test, or when classifying an evidence requirement as regression / release audit / acceptance evidence.
---

# 测试取舍

**所有权边界**：本文只拥有「这条验证该不该写成永久测试」的判定。`verification_class` 三分类与 test budget 由 TaskRevision / ADR-004 / ADR-006 拥有。根因与 regression guard 的作者义务归 `targeted-fix`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。不要为了凑覆盖率制造测试。

## 判据

先把被测事实分成稳定程序规则 / 动态或时效数据 / 本任务一次性复现，再问：

- 换一轮数据，这条断言还成立吗？不成立 → 不是 `regression`，不要写成永久测试。
- 删掉这条测试，发现真实问题的能力会下降吗？不会 → 不写。
- 它测的是可观察行为，还是构造函数赋值、mock wiring、实现细节？后者 → 不写。
- 污染过生产代码、改过输入、覆盖过失败 run 的结果，还能不能关 gate？不能 → 不要提交能关 gate 的 evaluation。

## 反问法警告

不要问「覆盖率够高吗 / 再加几条是不是更安全」。它对「一次性验收扩成永久测试」给反答案。要问「删掉它谁会坏，换一轮数据还成立吗」。

## 过度纠正陷阱

删测试或精简套件时核这五个：把义务改成许可、把设想说成已落地、删掉一条真事实、丢了出处、**删掉「下次补回归」的承诺却不补**。第五个是自动循环特有的。

## 反向约束

| 看起来像该加测试 | 为什么放行 | 备注 |
| --- | --- | --- |
| 发布审计或本轮截图 / URL 复验 | 那是 `release_audit` / `acceptance_evidence`，不是永久测试 | |
| 框架、标准库、SDK 已保证的行为 | 无业务价值 | |
| 只服务测试的代码结构 | 测试不能驱动业务偏离 | |

## 降级路径

- 只能验证当前具体词 / 具体样例 → `partial`，在 coverage gap 写明缺同形态输入。
- 缺真实用户路径 → 降为 residual risk，不宣称路径通过。
- 同一证据又像稳定规则又像数据快照，且 Lead 尚未给出 `verification_class` → 升格缺口。

## 规则内优先级

先覆盖本轮 change path、失败模式和用户路径。需求与测试冲突时，完成需求主线；测试不能阻塞核心功能。

## 升格条件

只有当同一证据同时像稳定规则又像数据快照，且 Lead 尚未给出 `verification_class` 时，才算边界。把一次性 URL 写成永久测试、为凑数量加低价值用例，不是边界。

停下时交什么：见本次 attempt 已钉的 `rules/escalation-payload.md`，不要在本文件复写格式。

## 污染与真实路径

禁止改生产代码、覆盖失败 run、手工补系统应生成的 artifact，或改输入后仍声称原测试通过。用户可见完成状态与 artifact / 状态文件矛盾时不能过。只跑编译或 mock happy path，不能证明真实路径。

测 parser / resolver / 状态机 / artifact writer 时，要证明同形态输入也不会进入正式事实源；只过当前报错样例不够。

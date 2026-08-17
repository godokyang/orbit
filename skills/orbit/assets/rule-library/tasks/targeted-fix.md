---
description: Use when reproducing, isolating, or repairing a failing symptom — not when adding a green-field feature with no failing path, and not when the only question is which tests to keep.
---

# 定向修复

**所有权边界**：本文只拥有当前 attempt 里「这个失败症状的根因是否已被理解，以及修复是否被验证」的判定。最小变化归 `minimal-implementation`；写不写测试归 `test-selection`；名单 / 字段族 / 旧路径关闭归 `structured-boundary`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。不要为了显得在修而叠 patch。

## 判据

- 能不能用一句话说清：哪个文件 / 函数 / 条件，因为什么 evidence，导致哪个用户可见症状？不能 → 还没有根因，先补复现，不改逻辑。
- 这个症状修完后还会不会以可观察方式再出现（单测反复改、修复引发新失败、代码不断变复杂）？会 → 停下来重建假设，不继续加码。
- 删掉这次改动，那个症状是否仍能被复现命令或失败测试打出来？不能指出复现面 → 修复未被验证，不能标完成。

## 反问法警告

不要把「看起来像缓存 / 异步 / 状态管理问题」当成根因。那个说法对任何未理解的症状都给「可以先改一处」的反答案。要问「哪条 evidence 把假设和其他可能分开了」。

## 反发明边界

根因必须指向已观察到的文件、条件或入口。只能说「可能是」时写「未记录」，先补 probe / log / 最小 fixture。不要为了填格子编一个因果。

## 反向约束

| 看起来像乱修 | 为什么放行 | 备注 |
| --- | --- | --- |
| 先加能区分假设的 probe / assertion 再改逻辑 | 行为、lifecycle、race 类问题需要它才能验证根因 | |
| 不能写测试时的替代 evidence（复现命令、日志、截图） | 架构或环境限制下仍可验证 | |
| 同形态 sibling 入口一并修 | 当前 scope 内的同一 class-of-bug | |

## 降级路径

- 一次只改一个假设点；修完症状还在 → 回退该改动，换假设，不叠 workaround。
- 三次可观察假设都失败，或根因需要项目外信息 → 升格缺口。
- 同形态问题超出本 attempt scope → 写入 known gap，不顺手改。

## 规则内优先级

先复现、再修、再验证。一个被失败测试钉住的根因，好过一串 catch-all、null check、sleep、retry。

## 升格条件

只有当三次假设都失败，或根因需要账号、设备、未授权系统等本仓库给不了的信息时，才算边界。还没复现就换策略、用 catch-all 消症状，不是边界。

停下时交什么：见本次 attempt 已钉的 `rules/escalation-payload.md`，不要在本文件复写格式。

## 复现与验证

能写 regression test 时，先写能失败的测试或 fixture，再让它通过。修改前已有测试失败时，记录 baseline，避免把旧失败归因到本次。没有验证命令或替代 evidence，不能标完整 pass。视觉 / 渲染 / 生成 artifact 类问题，compile 不能证明修复。

反复出现过的 bug 必须留下长期 guard（测试、schema check、runtime assertion）。临时脚本和一次性观察不能替代。

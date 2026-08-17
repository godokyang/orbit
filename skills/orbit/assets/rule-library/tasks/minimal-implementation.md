---
description: Use when implementing a scoped feature, refactor, or contract-bound change that must stay the smallest change that satisfies the current task — not when isolating a failing symptom (use targeted-fix) and not when only reviewing or only choosing tests.
---

# 最小实现

**所有权边界**：本文只拥有当前 attempt 里「这处改动是否满足合同的最小变化」的判定、降级与升格。产品事实、schema、`verification_class`、budget、gate 语义由 TaskRevision / ADR / `contracts/` 拥有，本文只链接锚点，不复制正文。根因与三次假设归 `targeted-fix`；写不写测试归 `test-selection`；符号是否像过程名归 `vantage-audit`；名单 / 字段族 / 旧路径关闭归 `structured-boundary`。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。不要为了让 diff 看起来更完整而制造改动。

## 判据

先把被讨论的符号、抽象或依赖的消费者分成 production / non-production / ambiguous，再问：

- 删掉这处改动，当前 TaskRevision 哪一条 acceptance 或 quality outcome 会失败？指不出条款 → 不写。
- 这个抽象现在有合同内的第二个 production 调用方吗？没有 → 不引入。
- 更小的改动能满足同一条条款吗？能 → 选它。
- 这是只为当下、下一轮注定整段替换的壳吗？是 → 换成能留下的路径，或按升格交缺口。

## 反问法警告

不要问「这样是不是更完整 / 更通用 / 以后更好改」。那个问法对「单一用例上的提前抽象」给反答案。要问「删掉它谁会坏」。

## 反向约束

| 看起来像多余 | 为什么放行 | 备注 |
| --- | --- | --- |
| 复用项目已有 helper / 模式，即使多碰一个文件 | 复用降低已经存在的复杂度，不是为第二个实现预留 | |
| 清理本次改动造成的 unused import、dead branch、fixture | 精准修改的一部分 | |
| 合同或项目既有模式已经要求的接口、配置、扩展点 | 需求已在合同里，不是发明未来 | |
| 项目流程或本 task 明确要求跑 formatter，因而改动了格式 | 格式探针会永久命中这些 diff | 会被永久命中，别每轮重推 |

## 降级路径

- 想法对，但删掉它当前 acceptance 仍成立 → 不写进本 diff。需要记住就写 `TODO` 或 known gap，不升级成抽象。
- 修复或实现开始级联到无关模块 → 范围外问题 payload，本 attempt 不改完。
- 风格偏好、注释拼写、import 顺序 → 不改，也不报 finding。

## 规则内优先级

先保住合同内最小可验证、且不注定被替换的变化。一处能指到条款的删除，好过一组指不到条款的「以后会用到」的新增。

## 升格条件

只有当两个以上实现都满足本规则与当前合同，但在已接受的原则之间取舍不同（例如复用别扭的旧 API，还是加一个更小的本地函数），且本规则没有直接裁定时，才算边界。有唯一答案的改写——删掉无条款可指的 service、strategy、provider、base class、interface 或配置层——不是边界。

停下时按类型交 payload，不要混用一种格式：

| 类型 | 何时用 | 交什么 |
| --- | --- | --- |
| 裁不了的缺口 | 两方案都过判据，本规则无裁定 | `待裁定：<问题> —— <2–3 个候选与各自代价>`，交付摘要单独列出 |
| 报一条缺陷 | 仅复核任务。发现合同被违反 | 位置（文件:行）+ 能自己复现的证据 + 影响 |
| 发现范围外问题 | 真问题但不在本 attempt 合同内 | 问题描述 + 影响范围 + 建议方案；本 diff 不改 |

不要自己选一个写进代码。不要用「按需」「视情况」绕开。不要只在对话里拍板。裁定后删干净缺口行，不留「原本有一条待裁定」。

## 先读再写

写之前读改动面：目标文件和相邻实现、同类 route / service / test 的既有模式、文件顶部 imports、相关测试里的真实预期。代码库没有可复用模式时，说明这一点并给出最小一致方案；不要默默引入外来风格、库或架构。

当前代码、diff、测试、日志和 task contract 优先于聊天历史。

## 假设先说

需求、接口、数据形状、认证、持久化、缓存、错误处理或外部依赖有多种可行方案时，先写假设、权衡、为什么不选更复杂的方案、哪些点要用户确认。选择写进 task contract、evidence 或 handoff，不只留在 diff 或对话里。

## 精准修改

不改无关文件、无关命名、注释拼写或 import 顺序。不跑会重排大文件的 formatter，除非项目流程或当前 task 明确要求。没写进 `out_of_scope` 的原始要求默认仍要满足；发现原设计不可行时更新合同或进入 blocked，不在代码里静默缩小目标。

## 依赖

新增依赖前先证明：项目已有能力、标准库或平台 API 不够用。确实新增时说明原因，并同步 lockfile。

## 假完成

不能用下面这些让当前 slice 看起来通过：删除或弱化已有 gate；把必须项静默改成 out of scope；用「后续再补」替代当前必须能力；用业务层兜底掩盖未接通的入口。用户可以接受风险，但必须写进 evidence 或 handoff，不能包装成已验证完成。

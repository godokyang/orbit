# Orbit 参考总览

本文件是 `orbit` 的文档导航。它只回答一个问题：当前要读哪类文档。

当前仓库的示例运行时入口是 [SKILL.md](../SKILL.md)。相关运行时长文档放在 `references/`。如果迁入新的独立实施工程，应把这些参考文档作为需求种子，而不是原样当作产品源码结构。

`SKILL.md` 是 skill 的必需入口；`assets/`、`references/`、`scripts/` 都只是可选组织方式。当前公开目录只保留运行时需要的资料，不是所有 skill 必须遵循的规范。

## 两条主线

### 真实运行时

在真实项目里执行任务、review、test、handoff 时，先读 [runtime/guide.md](runtime/guide.md)。

运行时文档只回答：

- 当前 agent 是谁。
- 本轮 task contract 是什么。
- evidence 和 loop state 在哪里。
- review/test gate 是否满足。
- handoff 怎么交给下一位 agent 或用户。

运行时不要默认读 implementation plan、工程化参考或子仓库细则。

## 文档地图

运行时文档：

| 文档 | 类型 | 用途 |
| --- | --- | --- |
| [runtime/guide.md](runtime/guide.md) | 运行时入口 | 真实项目中执行 Orbit 的最小读法、命令和 fail-closed 规则。 |
| [runtime/core-operating-model.md](runtime/core-operating-model.md) | 协议解释 | 需要解释 role、task、evidence、loop state 或 bootstrap 语义时读取。 |
| [runtime/quality-outcome-and-review.md](runtime/quality-outcome-and-review.md) | 质量 gate | 改善类任务需要判断 quality outcome 时读取。 |
| [runtime/coding-guideline.md](runtime/coding-guideline.md) | coding 规范 | lead/coder 实现代码、保留证据和控制 scope 时读取。 |
| [runtime/testing-guideline.md](runtime/testing-guideline.md) | testing 规范 | tester 执行真实测试、保留失败证据和输出 verdict 时读取。 |

## 目录约定

- `runtime/` 放真实运行时会用到的操作入口、协议解释、coding/testing 规范和质量 gate。
- 根目录只保留本导航，不继续堆积长正文。
- 任何开发期参考或项目案例进入运行时协议前都必须重新做抽象边界审查；不能直接把项目细则或子仓库细则写进默认协议。

当前公开目录只保留运行时文档。开发期资料和项目案例可以在本地 checkout 中保留，但不随公开仓库发布。迁入独立工程时，可以按实现需要新增 `schemas/`、`fixtures/` 或 `examples/`，但不要因为有资料就提前扩张目录。

迁入新工程后的建议归位：

| 当前文档 | 新工程建议位置 |
| --- | --- |
| `runtime/core-operating-model.md` | 产品核心设计中的运行时协议。 |
| `runtime/quality-outcome-and-review.md` | quality gate 设计。 |
| `runtime/coding-guideline.md` | coding 运行时规范。 |
| `runtime/testing-guideline.md` | testing 运行时规范。 |
| `.orbit/roles.yaml`、`.orbit/instances.yaml` 和 schema 示例 | implementation fixtures / examples。 |

核心设计判断和待补实现方向已经移到开发期文档。运行时 agent 不需要从本总览里继承这些开发讨论。

# Orbit 参考总览

本文件只回答：当前要读哪类文档。

> v1 runtime 已删除。v1 长文档在 [`docs/history/v1-runtime/`](../../../docs/history/v1-runtime/)，不是现行操作指引。

## 现行入口

| 文档 | 用途 |
| --- | --- |
| [SKILL.md](../SKILL.md) | skill 触发边界与 v2 最短闭环 |
| [../assets/rule-library/tasks/](../assets/rule-library/tasks/) | 任务规则母版；`init` 拷进项目 `rules/`，由 dispatch 钉入 |
| [../assets/rule-library/shared/](../assets/rule-library/shared/) | 被钉的共享层（升格 payload 格式） |
| [../assets/rule-library/resident/](../assets/rule-library/resident/) | 用户项目 `AGENTS.md` 模板；不进 `--rule` |
| [../../../docs/plan/handoff.md](../../../docs/plan/handoff.md) | 阶段交接：G 已完成，下一阶段是 H |

`orbit v2 --help` 是命令面的权威。

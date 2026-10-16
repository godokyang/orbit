# Orbit 当前总待办

最后核对：2026-10-16。产品决定见[任务运行合同](../../contracts/task-runtime.md)、[ADR-009](../adr/009-user-selected-model-pool.md)和 [ADR-011](../adr/011-agent-autonomy-and-runtime-responsibility.md)；实现与验证边界见[交接](handoff.md)。

## 未完成事项

- [ ] 检查者页面材料漏判与 workspace rebind 真实验证：触发条件和收口标准统一维护在[缺口清单](debt-ledger.md)。
- [ ] Loom 阶段二：等待用户另行通知，届时按 Loom 的规范与实际代码复核下列协同事项。

## 阶段二：Loom 协同

- `needs_user` 任务续接，以及能力、用户消息、停止确认、身份和模型授权核对。
- Root 提问与用户答案的往返，以及停止任务的续接语义。
- 原生会话记录绑定和 `root_session_file` 补取。
- 检查、交付、缓存与版本记录；Root 采纳裁定不得冒充独立终检。
- 如果 Loom 消费检查器证据，验证来源、版本和外发授权能到达 reviewer。
- 保持 Loom 现有授权与模型选择语义；严格路径继续关闭 JEV。

候选池拆分没有已证实的 Loom 接口改动：Loom 当前只传递显式 `--review-model`，不消费候选池配置或 `/orbit-models`。本次未修改 Loom 或 Zeen。

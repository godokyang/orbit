# Orbit 当前需求与待办

产品行为以[任务运行合同](../../contracts/task-runtime.md)为准，公开接口以[集成合同](../../contracts/integration.md)为准。

## 已确认需求

- JEV 按入口、观察、成员选型和检查者选型分别组织输入；仅两类选型按需压缩，保留必要信息，复用缓存及在途请求。Root 决定提交终检，JEV 不判断成果就绪。理由见 [ADR-012](../adr/012-jev-purpose-specific-input-and-compaction.md)。
- 默认终检聚焦功能、关键安全边界和必要验证；明确要求的文档、权限、资源及报告仍须验收。未检查项由检查者续查，缺证和缺陷交 Root 处理。同版本有效结论可沿用，反证撤销旧结论，跨版本不得自动继承完成资格。理由见 [ADR-013](../adr/013-final-review-scope-and-continuation.md)。
- 执行者与检查者候选池分离；程序不自动更换 Root 型号，不越过用户模型授权。理由见 [ADR-009](../adr/009-user-selected-model-pool.md) 与 [ADR-011](../adr/011-agent-autonomy-and-runtime-responsibility.md)。

### Loom 协同边界

- 仅适配 Loom 的实证缺口；Orbit 只补兼容公开能力，不改 Zeen，不发布或部署。提交与推送按功能验收后的用户另行授权执行。
- 已确认停止的公开可续接任务在同一业务 run/attempt 内追加监督绑定历史，不增加或扣减尝试额度；保存答复与显式续接分开。
- 核对同 Root、项目、真实原生用户输入、停止与严格授权；未知停止或未知接收结果不得放行第二写者或盲目重发。
- 新监督边界重新取得自检、独立检查、候选及业务验收；旧终态、问答与证据保留，但不冒用其当前资格。
- 通过公开 `session_binding` 与宿主接口取得原生身份、记录路径和启动边界；外部接续协商可选 `resume_wake`，原生 ACK 不等于执行或采用。
- Loom 严格路径继续关闭 JEV，保留显式检查模型和当前 Root 型号，不强加角色池配置或界面。


## 未完成事项

待验证事项及收口条件集中维护在[缺口清单](debt-ledger.md)。当前源码和验证边界见[交接](handoff.md)。

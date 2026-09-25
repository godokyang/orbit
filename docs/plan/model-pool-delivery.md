# ADR-009 模型候选池交付 TODO（已完成，2026-09-25）

状态：已完成（2026-09-25）。目标与产品边界见 [ADR-009](../adr/009-user-selected-model-pool.md)；现行运行事实见 [任务运行合同](../../contracts/task-runtime.md)。真实验收已覆盖：显式不可用检查者结构化失败→同任务显式重选→任务 `complete`+停止确认（`193ad1dd`）；原生 GLM 成员→真实检查者 finding F1→根因修复→`resolved_ids` 闭合→停止确认（`3dc116a4`）；成员模型漂移被检测、记录并中止、拒绝交付，最终构建 `6f808e8d…` 首次成员与任务双层停止确认（`bfcc270a`；早期失败保留为回归历史）。**Live 边界：**无显式检查者的池内自动正选择未取得 live 样本——真实尝试在任务开始前被正确 fail-closed 拒绝、未建任务（live start 只记录质量线拒绝，未落分数）；另作诊断 JEV 调用得 GLM 0.27、Grok 0.04（均 < 0.55），改动证据后的本地 GLM 检查指标为 0.42；该正选择分支由确定性选模测试覆盖。见[真实验收证据](../reference/model-pool-acceptance-20260925.md)。本单是此功能的唯一进度清单，不改写已结束的 OMP 迁移验收。

## 完成条件

- `/orbit-models` 从当前 OMP 会话可选列表增删长期候选池；跨会话持久化、交集与空池/显式指定行为符合 ADR-009，不保存凭据。
- Root 获得质量达标、比较端到端时间与粗档费用的具体成员模型/角色建议；同 Root 模型不自动推荐，Root 显式派发，实际模型与建议一致且失败不静默换模。
- 独立只读检查者按池内可解析模型自动选模，优先异家族；无可用池内检查者时要求显式指定，失败后显式重选；在途工作不因池变化切模。
- 权威合同、JEV 规则、用户文档和实际实现一致；相关确定性回归通过，隔离项目中的真实 `orbit omp` 成员→检查→纠正/完成→停止路径验证并记录成本和时间边界。提交、推送和发布不在本任务范围内。

## 执行顺序与负责人

| 步骤 | 负责人 | 状态 | 完成证据 |
| --- | --- | --- | --- |
| OMP 动态 Agent 定义、模型优先级/漂移与检查者隔离目录接线小型验证 | OMP | 已完成（含上游限制）：动态定义可承载、成员最终模型核对生效；OMP `task.agentModelOverrides` 优先于会话 Agent 定义，动态定义不能约束实际模型，覆盖时由漂移检测中止并交 Root 重选；最终构建 `6f808e8d…` 首次成员与任务双层停止确认 | 样本 5（`bfcc270a-…`）+ 早期失败历史（样本 3、`3b5ec7de`、`c828d8b9`、`3cd9ac7f`）+ 旧源码静默对照 `0c194547-…`，见[证据记录](../reference/model-pool-acceptance-20260925.md) |
| 长期候选池存储与原子修改、内部 CLI 读写桥 | OpenCode | 已实现并通过确定性测试 | `ModelCandidatePool` 与 `orbit model-candidates`；跨会话、斜杠 ID、并发写与不保存凭据 |
| 共享检查者选模器与显式重选命令 | OpenCode | 已实现并通过确定性测试；同一任务内显式重选已由真实样本证明（含检查者失败→重选→任务 `complete`+停止） | `lib/orbit/checker_model_selector.rb`、`orbit review-model`、隔离可解析探针；真实样本见[证据记录](../reference/model-pool-acceptance-20260925.md) |
| `/orbit-models`、会话隔离成员定义及实际模型核对 | OMP | 实际模型核对已生效（成员产出前捕获 Grok 漂移并中止）；会话 Agent 物化未阻止该覆盖；最终构建完成成员与任务双层停止确认 | `member_model_drift`／`member_model_drift_absorbed`（`stop="confirmed"`，样本 5），见[证据记录](../reference/model-pool-acceptance-20260925.md) |
| JEV 多候选、质量/时间/粗档费用建议 | Pi | 成员池候选比较（质量→时间→`cost_tier`）与旧路径粗档费用比较已实现并测试；真实会话已产出带质量/时间/费用档的候选建议，并据质量线正确拒绝无合格候选的自动选模 | `assess_candidates` + `candidate_cost_band` + `pending_candidates`；拒绝原因可追溯 |
| 独立检查者池内选模、异家族偏好及失败重选 | OpenCode | 选模顺序与失败分类已实现并测试；失败不终止、同任务显式重选与任务 `complete`+停止已真实验证；池内自动（非显式）正选择仅由确定性测试覆盖（live 尝试被质量线正确拒绝） | `CheckerModelSelector` 的选模顺序与 `usage` 记录；真实样本见[证据记录](../reference/model-pool-acceptance-20260925.md) |
| 文档同步、组合检查与真实任务验收 | Root 审核，成员执行 | 已完成：文档同步、真实样本与组合检查完成；池内自动正选择为 live 边界（确定性测试覆盖），早期漂移失败保留为回归历史 | 合同／ADR／使用参考已同步；真实样本见[证据记录](../reference/model-pool-acceptance-20260925.md) |

## 协作边界

Root 负责编排、审核、集成与完成判定。成员按 [开发流程](../agents/development-workflow.md)派发，不能继续派发；不同写任务不并发修改同一文件。`README.md`、`docs/README.md`、`docs/plan/handoff.md` 与 ADR-009 在本任务开始前已有工作区改动，任何成员修改前须先核对并保留这些改动。只改 Orbit，不动 Zeen。模型调用、真实任务与进程清理要记录实际证据；不以确定性测试代替真实模型/停止验收。

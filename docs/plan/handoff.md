# Orbit 当前交接

2026-09-14：用户已授权 Goal 实施独立任务运行重构，实现与收尾已完成。本次基线 `e578365`；用户在验收完成后明确授权提交并推送至 `origin/main`，不包含发布 npm 包或修改 Zeen。

## 从这里继续

先读根 `AGENTS.md`、[开发流程](../agents/development-workflow.md)、[当前总 TODO](vision-completion-plan.md)，再按任务读取 [ADR-007](../adr/007-task-runtime-refactor.md) 和 [运行合同](../../contracts/task-runtime.md)。旧 D1–D11/H–K 不再是待做阶段；需溯源时读 [设计基线](../history/task-runtime-design-baseline-20260914.md) 和 [旧交接快照](../history/pre-task-runtime-handoff-20260914.md)。

## 已验证事实

- Orbit 新入口为 `scripts/orbit` → `lib/orbit/cli.rb`，无 `v2` 别名、init/evidence/gate 手工流程，也不解析旧数据。
- 原生 Codex Unix 实为 WebSocket。新程序可接入同一 server 上已加载、具备历史的现有 Root；普通 embedded TUI 无即时控制端点，明确拒绝。
- 原始指令、实际内容快照、自动检查、纠正、按需裁定和停止均已接线。
- 真实遗漏纠正与真实停止两条路径已通过；详细结果与局限在 [验收记录](../reference/orbit-runtime-acceptance-20260914.md)。确定性测试不冒充模型效果。
- 旧 v2 运行代码、合同、fixture、旧 skill 入口和 v1 模板共 81 个文件已删除；规范、Zeen 交接资料及历史决定保留。

## 当前交付状态

安装／卸载核对、10 个行为测试、skill 校验、npm 打包清单与差异格式检查均通过。依赖锁文件已纳入包；现行文档已切换。验收临时进程、tab 和目录清理完成，夹具会话已归档，开发成员会话保留。预估与实际见当前总 TODO，原始事实选段随验收记录保存。

本轮实现与验收没有剩余必做项。提交与远端同步状态以 Git 记录为准。后续按用户新的任务继续；接入其他 Coding Agent 需要真实原生能力验证，不能把现有 Codex 路径的通过当作其他通道也已支持。

原始重构讨论入口与 Zeen 外部快照仍保留在 [交接包](../reference/zeen-orbit-handoff-20260913/README.md)，它们不产生本仓执行规则。

# Orbit 当前交接

最后核对：2026-10-11。源码版本以 `package.json` 为准（当前 0.8.5）；用户安装版本、commit 与内容摘要须以 `orbit version --json` 核对，本页不记录。

## 当前进展

- **集成合同（Loom 等集成方）**：已实现并提交在本地分支 `feat/integration-contract`——`b38f0d0`（合同 1.0：`orbit capabilities --json`、覆盖项可选 `ref`、`start --external-ref`、契约测试 `tests/integration_contract_test.rb`）与 `92a00dd`（合同 1.1：空串/纯空白 `ref` 视为未提供）。**未推送、未升软件版本、未发布、未更新日常安装。** 合同见 [integration.md](../../contracts/integration.md)，决定与理由见 [ADR-010](../adr/010-integration-contract.md)，计划、真实检查者 `ref` 小样本试验（1 个模型、7 次）与提案 B 评估（O3）见 [loom-integration-contract.md](loom-integration-contract.md)。提案 B（对外状态补充）已评估、建议缩小范围，等用户决定；提案 C（事件流）未评估；`needs_user` 终态接续未做，均见[当前限制](debt-ledger.md)。
- **文档整理**（2026-10-11，用户要求）：历史方案、阶段计划、验收记录、证据原件与研究报告已从当前树移除，只保留现行有效文件；历史在 Git 中查阅，恢复基线提交 `aa089bb`（用法见 [docs/README.md](../README.md)）。该整理在工作区、未提交，需用户审阅后另行提交。
- **最近一次真实验收的构建**：0.8.4（`25f0104` dirty，临时安装 digest `c70f5b60…`），内容为本地 OMP 宿主复用与检查历史内容去重归档；之后 0.8.5 只改版本元数据，不重标为实测。其真实验收范围与已知缺口列在[当前限制](debt-ledger.md)；Zeen 存量数据迁移/清理仍暂缓。

## 环境提示

- 全仓 `npm test` 需要 `node_modules`：本工作区未安装依赖时，`prestart_test.rb`、四个 `.mjs` 测试和 bun 套件因缺 `zod` 失败，在未改动的 HEAD 副本上同样复现；`npm ci` 后通过。需要时在临时副本里安装，不要把依赖装进仓库。
- 提交、推送、发布、打标签、更新日常安装各自需要用户明确授权；升版默认只加 patch。

## 当前有效边界

产品语义以[任务运行合同](../../contracts/task-runtime.md)、[检查结果 schema](../../contracts/check-result.schema.json) 和 ADR-008/009/010 为准；有界真实验收不推广为全模型、全分支或普遍成本收益。开发规则沿 [AGENTS.md](../../AGENTS.md) 与[开发流程](../agents/development-workflow.md)。

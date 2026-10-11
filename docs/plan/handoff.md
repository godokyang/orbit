# Orbit 当前交接

最后核对：2026-10-11。源码版本以 `package.json` 为准（当前 0.8.5）；用户安装版本、commit 与内容摘要须以 `orbit version --json` 核对，本页不记录。

## 当前进展

- **Loom 集成合同提案 B**：用户已授权在 `main` 依次交付阶段 A（合同 1.2：外部会话模式、调用方指定控制通道、按外部引用查询）和阶段 B（合同 1.3：revision/updated_at、attention、最近完成检查记录）。基线 `52bb3848` 干净，已有合同 1.0/1.1 提交 `b38f0d0`、`92a00dd` 已在 main。A 已实现并通过含待交付改动的隔离快照全套 npm test、OMP 18.9.0 真实 rpc 验证及独立只读审核/修正与 Codex 收口；已完成本地提交 `86d09af`（用户署名，无 AI 署名）；B 已实现，隔离快照全套 npm test 与独立 OMP save 核查通过；真实任务证明 revision 变化/三次读稳定/实际无变化 tick/运行时重启不回退，最近失败检查与真实模型回执一致。B 随本轮 main 本地提交交付（提交标识见 Git 历史）；成功模型检查及未触发分支不据此认证。验收与驱动错误见[记录](../reference/loom-integration-acceptance-20261011.md)。冻结范围、文件所有权与门槛见[总 TODO](loom-integration-contract.md)。本次每阶段本地提交已授权；不推送、不升软件版本、不发布、不更新日常安装。
- **最近一次真实验收的构建**：0.8.4（`25f0104` dirty，临时安装 digest `c70f5b60…`），内容为本地 OMP 宿主复用与检查历史内容去重归档；之后 0.8.5 只改版本元数据，不重标为实测。其真实验收范围与已知缺口列在[当前限制](debt-ledger.md)；Zeen 存量数据迁移/清理仍暂缓。

## 环境提示

- 全仓 `npm test` 需要 `node_modules`：本工作区未安装依赖时，`prestart_test.rb`、四个 `.mjs` 测试和 bun 套件因缺 `zod` 失败，在未改动的 HEAD 副本上同样复现；`npm ci` 后通过。需要时在临时副本里安装，不要把依赖装进仓库。
- 本次 A/B 的 main 本地提交已有用户明确授权；推送、发布、tag、更新日常安装和软件升版未授权。

## 当前有效边界

产品语义以[任务运行合同](../../contracts/task-runtime.md)、[检查结果 schema](../../contracts/check-result.schema.json) 和 ADR-008/009/010 为准；有界真实验收不推广为全模型、全分支或普遍成本收益。开发规则沿 [AGENTS.md](../../AGENTS.md) 与[开发流程](../agents/development-workflow.md)。

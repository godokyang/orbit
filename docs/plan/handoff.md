# Orbit 当前交接

最后核对：2026-10-12。源码版本以 `package.json` 为准（当前 0.8.8）；用户安装版本、commit 与内容摘要须以 `orbit version --json` 核对，本页不记录。

## 当前进展

- **ORBIT-CHECKER-STARTUP-02**：0.8.7 基线的 GLM 检查实际已进入 provider 流，OMP 外层 startup watchdog 因 trusted factory 保持 pending 而误报模块阶段。仅补内部阶段证据和日志，真实零模型宿主复现与相关既有测试通过。原 check 最终因多余 `}` 被正确拒收为 invalid_result；长等待/模型格式问题未宣称修复。用户要求收束、不新增模型，原运行停止归 Loom Root。用户追加本票提交、推送与本机更新授权，patch 升至 0.8.8；具体提交与安装身份以 Git 和公开 version 回读为准，详见[诊断记录](../reference/checker-startup-20261012.md)。

- **Loom 联动：严格模型授权票**：2026-10-12 用户授权 Orbit 定位/实现并向 Loom Root（w22:p1）回报，不另建 Goal。源码新增合同 1.4 `model_authorization`：`start --allowed-model` 与可选 `ORBIT_ALLOWED_MODELS` 启动上限，冻结任务名单、接续继承/缩小、调用前守卫与池耗尽阻断；普通任务保留偏好池。可选 JEV 关闭，宿主公开 stream/resolver/getApiKey 与选模接缝受限。实现与实测基线 `4a529aa`（0.8.6）；用户随后明确授权升至 0.8.7、提交/推送 main 并执行本机 orbit update，交付身份见 Git 历史与公开 version。发布与 tag 未授权。零模型边界、隔离全套 npm test、MiniMax 实际 Root/独立检查/确认暂停与独立只读核查均有记录；最终定点复核与资源收尾见[本票记录](../reference/loom-model-authorization-20261012.md)。Loom 原 `0595af38` 的未知停止来自宿主 socket 拒绝连接，不能确认 Root/工具退出；保持 unknown/writer，不修改其状态。Loom 端适配与复验由 Loom Root 负责，原生严格成员/实际故障回退/硬名单的真实接续组合未据此认证。

- **版本与推送**：用户于 2026-10-12 追加授权更新版本号、提交并推送 `main`；软件 patch 升至 0.8.6，包含已完成的 Loom 集成 A/B 与冷启动绑定修复。此轮仅改版本元数据与交接，不重标既有真实验收构建；发布、tag 和日常安装不在本次范围。

- **外部 CLI 冷启动绑定修复**：用户追加 Goal 授权，Root 已补运行时精确绑定与接纳前权限边界；隔离快照 npm test、真实 OMP 18.9.0/MiniMax 的外部 CLI 启动→running/hub事件→Root写入→引用回读→确认暂停，以及独立 OMP 只读审核通过。随本轮 main 本地提交交付，已移除原冷启动缺口；成功终检、Loom CI 和其他平台仍未据此认证。原始证据与探针残留资源收尾见[验收记录](../reference/loom-integration-acceptance-20261011.md)。


- **Loom 集成合同提案 B**：用户已授权在 `main` 依次交付阶段 A（合同 1.2：外部会话模式、调用方指定控制通道、按外部引用查询）和阶段 B（合同 1.3：revision/updated_at、attention、最近完成检查记录）。基线 `52bb3848` 干净，已有合同 1.0/1.1 提交 `b38f0d0`、`92a00dd` 已在 main。A 已实现并通过含待交付改动的隔离快照全套 npm test、OMP 18.9.0 真实 rpc 验证及独立只读审核/修正与 Codex 收口；已完成本地提交 `86d09af`（用户署名，无 AI 署名）；B 已实现，隔离快照全套 npm test 与独立 OMP save 核查通过；真实任务证明 revision 变化/三次读稳定/实际无变化 tick/运行时重启不回退，最近失败检查与真实模型回执一致。B 随本轮 main 本地提交交付（提交标识见 Git 历史）；成功模型检查及未触发分支不据此认证。验收与驱动错误见[记录](../reference/loom-integration-acceptance-20261011.md)。冻结范围、文件所有权与门槛见[总 TODO](loom-integration-contract.md)。阶段 A/B 当时仅授权每阶段本地提交；后续升版与推送授权见本页“版本与推送”。
- **最近一次真实验收的构建**：0.8.4（`25f0104` dirty，临时安装 digest `c70f5b60…`），内容为本地 OMP 宿主复用与检查历史内容去重归档；之后 0.8.5 只改版本元数据，不重标为实测。其真实验收范围与已知缺口列在[当前限制](debt-ledger.md)；Zeen 存量数据迁移/清理仍暂缓。

## 环境提示

- 全仓 `npm test` 需要 `node_modules`：本工作区未安装依赖时，`prestart_test.rb`、四个 `.mjs` 测试和 bun 套件因缺 `zod` 失败，在未改动的 HEAD 副本上同样复现；`npm ci` 后通过。需要时在临时副本里安装，不要把依赖装进仓库。
- 本次 A/B 与冷启动修复的 main 本地提交已有用户明确授权；2026-10-12 追加授权本票软件 patch 升至 0.8.7、提交/推送与本机 orbit update。发布、tag 未授权。

## 当前有效边界

产品语义以[任务运行合同](../../contracts/task-runtime.md)、[检查结果 schema](../../contracts/check-result.schema.json) 和 ADR-008/009/010 为准；有界真实验收不推广为全模型、全分支或普遍成本收益。开发规则沿 [AGENTS.md](../../AGENTS.md) 与[开发流程](../agents/development-workflow.md)。

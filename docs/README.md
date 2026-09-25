# Orbit 文档入口

当前源码版本文字：**0.7.2**（由 0.7.1 升 patch；`package.json` 与 `npm-shrinkwrap.json` 已为 0.7.2）。0.7.2 确定性门禁已通过：`npm test` exit 0（`/tmp/orbit-072-npm-test-20260925.log`，`check:version` 报 `Version and lockfile consistent: 0.7.2`）、`npm pack --dry-run --json` exit 0 且 48 文件（`/tmp/orbit-072-pack-20260925.json`；根 `README.md` 文案收尾后会再跑）、skill validator 与 `git diff --check` 通过。**本机当前仍装 0.7.1；0.7.2 尚未安装、尚未做真实模型验收**——安装与真实验收事实待补充。以下为 **0.7.1 本地安装与接入验收（2026-09-25，历史）**：该版最终安装已用 `sh install.sh` 完成本机本地安装（release `d4f7194c84d401dd1c3976ec`，source commit `1cee2166`（dirty），`content_digest e0e1e336199d10d196ddd2add1ac865e8bca25064bf3b923101adb95cb1c2799`，`installed_at 2026-09-25T15:34:53Z`；`orbit` 在 PATH；完整门禁 `npm test`／`npm pack`／skill validator／`git diff --check` 通过）。该次重装的原因：根 `README.md` 属打包文件，上一轮文案变更改变了摘要。此前的 `417a0ff4…`（release `ee7fbb9e…`，`installed_at 15:26:56Z`）是第九个隔离任务 `final_gate` 所用构建（该样本 `complete` 并确认停止）；更早的 `8ddc99b3…`（release `e666471e…`，`installed_at 14:06:52Z`）是前八个隔离真实任务的安装。新的 `final2` 隔离任务（`61aba2a4-91db-4f70-8ac3-3d2d0cad290b`）已在该安装上结束：`complete`，`stop_confirmation.confirmed=true`，1 次 manual_check 无 findings，`finalization_notice` 与 `completed_via_finalized_stop` 均已落盘，p6 OMP 已退出；本轮按已证实范围收口，`delegation_hint` 正样本改为后续独立目标。0.6.18（digest `06dba0f1…`，installed_at `2026-09-24T21:55:54Z`）是其前的历史验收安装，旧 OMP M4 真实验收在该安装上取得；ADR-009 选模真实验收在临时隔离安装的 0.7.0 release 上取得。本轮的核心完成硬门、显式暂停、原生 Esc 中断与检查纠偏收尾已有真实证据；**`delegation_hint` 派发正样本仍未取得**（`parallel` 场景成员为 `root_without_hint`，不标通过）。通过项、失败项与保留边界见 [Orbit OMP 接入验收记录](reference/orbit-omp-access-acceptance-20260925.md)。本文说明怎么用、为什么这样设计、怎么开发，以及实际验证到哪里。已结束的工单、旧协议和重复快照通过 Git 查阅，不再作为执行队列。

| 要解决的问题 | 阅读入口 |
| --- | --- |
| 怎么安装和开始任务 | [仓库 README](../README.md) |
| 自定义安装、skill 管理和 CLI 参数 | [进阶使用参考](reference/usage-reference.md) |
| Agent 何时自行调用 Orbit | [任务运行合同](../contracts/task-runtime.md)（角色与主动调用） |
| 如何在隔离项目真实验收 Orbit | [Orbit 开发专用真实验收 skill](../.agents/skills/orbit-real-acceptance/SKILL.md)、[OMP 目标路径真实验收记录](reference/omp-native-m4-acceptance-20260924.md) |
| Root 如何派发成员、使用 Herdr 和收尾 | [任务运行合同](../contracts/task-runtime.md)、[单一 OMP 改版总 TODO](plan/omp-native-migration.md) |
| 为什么采用当前设计、下一版决定了什么 | [历史 ADR-007](adr/007-task-runtime-refactor.md)、[当前 OMP 单宿主 ADR-008](adr/008-omp-native-collaboration-base.md)、[候选模型池 ADR-009（已实现并验收）](adr/009-user-selected-model-pool.md)、[OMP 路径验证](reference/omp-native-path-probe-20260924.md) |
| 程序和模型各负责什么、何时完成或停止 | [任务运行合同](../contracts/task-runtime.md) |
| 独立检查返回什么 | [检查结果 schema](../contracts/check-result.schema.json) |
| 开发本仓要遵守什么 | [AGENTS.md](../AGENTS.md)、[开发流程](agents/development-workflow.md) |
| 当前做到哪里、还有什么工作 | [交接](plan/handoff.md)、[单一 OMP 改版总 TODO](plan/omp-native-migration.md)、[模型候选池交付 TODO](plan/model-pool-delivery.md)、[执行协作与检查回路整体调优计划](plan/orbit-execution-review-optimization.md)、[JEV 委派判断专项计划](plan/jev-delegation-optimization.md)、[用户结果补齐计划](plan/user-outcome-completion-plan.md)、[当前计划](plan/vision-completion-plan.md) |
| 哪些能力尚不具备 | [当前限制](plan/debt-ledger.md) |
| 最新项目检查发现什么 | [用户结果独立审查及复核](reference/project-review-20260918.md)、[角色、协作与运行边界检查](reference/project-review-20260914.md) |
| Zeen 走查暴露的过程缺口、修复实施与 OMP 接入验收 | [Zeen 过程诊断与实施复盘](reference/zeen-page-capture-orbit-process-review-20260925.md)、[Orbit OMP 接入验收记录](reference/orbit-omp-access-acceptance-20260925.md) |
| 真实任务中的 Orbit 与 JEV 表现 | [Zeen Login 使用复盘与 JEV 证据](reference/zeen-login-orbit-experience-20260922.md) |
| 普通终端和现有会话如何落地、有哪些现成方案 | [用户流程交付计划](plan/user-experience-plan.md)、[现成方案调研](reference/existing-orchestrators-20260914.md) |
| 实际验收证明了什么 | [检查回路与 Jev 实际验证](reference/check-loop-acceptance-20260918.md)、[跨宿主成员验收](reference/cross-host-member-acceptance-20260918.md)、[Jev 调度运行验收](reference/jev-runtime-acceptance-20260918.md)、[底层真实验收](reference/orbit-runtime-acceptance-20260914.md)、[Codex 日常流程验收](reference/user-flow-acceptance-20260914.json)、[OpenCode 正式验收](reference/opencode-runtime-acceptance-20260914.json)、[OMP 正式验收](reference/omp-runtime-acceptance-20260914.json)、[候选模型池真实验收](reference/model-pool-acceptance-20260925.md) |
| 优化后的真实路径怎么验收、已经跑到哪里 | [优化真实验收记录](reference/orbit-optimization-acceptance-plan-20260922.md) |
| 过去哪些失误值得记住 | [工程经验](reference/engineering-lessons.md) |
| 历史：Codex 如何加载项目规范 | [按需阅读的说明](reference/codex-agents-md-loading.md)（旧宿主证据） |

## 各类文档的职责

- `contracts/` 与 ADR 定义产品语义；当前运行为 OMP 单宿主（ADR-008），历史路径（Codex、OpenCode、OMP 旧 SDK 成员）证据保留在 `docs/reference/`，不再是当前入口。修改设计先改这里，不通过开发规范绕过产品行为。工作区绑定、成员登记与 `task/hub` 协作、JEV 候选分／最终 decision／持久 hint、派发 basis、产物与过程检查分开的 freshness、observation 去重、finding 绑定、终检收尾和 status 分层已写入合同；冻结 #9 目标路径端到端已通过（0.6.17 staged `0bc4ec93`）；M4 已整体闭合——冻结 #1–#9 全部通过（#5 为用户批准的组合证据 PASS：同版本重复纠正由确定性回归证明、纠偏收敛与过期拦截有真实任务证据，`finding_repeat_ignored` 未真实触发已注明；#6 机械回路 PASS，矛盾夹具内容不计）；合同中的"待验"标注不得当作已验收。
- 根 `AGENTS.md` 与 `docs/agents/` 约束开发 Orbit 的 Agent，不产生产品运行事实。
- `docs/plan/` 保存当前状态、范围与已知限制；已完成的工作不保留为待办，不复制合同正文。
- `docs/reference/` 保存验证事实、经验与参考资料，不独立增加验收或授权要求。

独立检查者的提示与只读边界随实现维护（`lib/orbit/omp_check_runner.rb` 与 `runners/omp-reviewer/`），不复制到本目录。使用和开发 Orbit 所需的说明均在本仓；外部参考资料按需读取，外部项目规范不全局安装。

## 历史怎么查

需要溯源时使用 `git log --all -- <路径>`，再用 `git show <提交>:<路径>` 读取当时正文。历史描述不作为现在时指令。失效文档在结论已归入现行正文后可删除，并同步清理引用；不为了归档再复制一份。

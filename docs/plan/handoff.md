# Orbit 当前交接

最后核对：2026-09-30，bootstrap 修复复核与选型实现推进后更新。Goal **未完成**；本页是当前交接入口，历史运行从既有 reference、Git 和下面原始目录查阅，不重开已经结束的票。

## 目标与用户决定

完整实现并真实验收[混合模型交付主方案](mixed-model-delivery-proposal.md)，按[附属代码审计](mixed-model-delivery-code-audit.md)逐项闭合，完成条件见[当前计划 W1—W10](vision-completion-plan.md)。有限顶级模型资源下保持交付质量，让其他模型承担合适工作，减少用户介入。模型仍会幻觉、偏移、越界、遗忘；系统靠可验证任务、权限、回执、独立检查及纠正控制这些风险，不承诺模型绝不出错。

- 一次完整交付，不设硬预算。选型删除速度、时间和本地耗时评分；运行计时、缓存时效及停止控制不是选型信号。
- `orbit omp` 就是启动命令。`explicit_orbit` 是内部请求分类，不是另一启动需求。普通业务请求须自主进入合适的受控／协作路径，不依赖用户再次说“用 Orbit”或逐次安排成员。
- OpenRouter 给任务相关能力先验，Jev 给任务判断；未校准不能自动正向推荐。OpenRouter 价格不是 OMP 价格；未知费用、用量、额度归属保持未知。
- Codex 编排、集成和审核；复用用户授权的 Herdr OMP 执行者，不自动换内部子 Agent。源码／合同语义改动同步权威文件。
- 本地提交及必要收尾已授权，不推送、发布、购买额度或升级 OMP。失败证据不改判。

## 精确版本与工作区

- **安装 0.7.21**：`orbit version --json` 已复核，clean source `fffabf801b430b61aa11d58f86f99960bdd9c8aa`；digest `ae9ce431ead61d3bb61eb04c5050a7408ef2faf0cdbd42d02e5127512cd7d4fd`，2026-09-30T11:21:07Z 安装。OMP／reviewer 18.3.4，没有按 UI 更新提示升级。
- **HEAD 源码 0.7.22，已本地提交、未安装**：`1893fd7d281167cbe066d536ce70667f3899f50c`，包含 takeover 声明追加、Go 路由结构匹配及精确映射、范围说明与相关测试。其唯一组合 full `npm test` exit 0，pack／version／validator 通过；129 个源／测试／打包文件前后 SHA 一致。证据 `/private/tmp/orbit-regression-0.7.22/report.json`。这次 full 不覆盖下面后来产生的修改。
- **工作区 0.7.23，组合验证已通过、待本票提交安装（安装仍 0.7.21）**：选型决策升 `orbit-quality-decision-3`（不可比时过门候选保持稳定池序，不称质量／费用优势）＋ member v2／checker v7＋policy 回归测试＋合同选型句＋bootstrap 修复增量；`npm version patch` 同步 package 与 shrinkwrap。**组合 full／pack／validator／version／diff-check 全部 exit 0**：证据 `/private/tmp/orbit-regression-0.7.23-gu0Ouq/`（report.json＋原始 exit/log/packjson），Root 已直接核验并逐文件复算 pre/post/current 129 个 SHA 完全一致；S 跑完已停票，无 npm 测试残留。**decision-3 放行已重签**：Root 2026-09-30T13:57:50Z 独立审核（w1Y:p1A）；policy 实现者是 Q，Root 只独立审核与重签、不是实施者；17 个真实样本逐字保留（`JSON.stringify(samples)` SHA256 `5a30130a022abd2bc1b35a6ebe61c2ea4fe0e750cafbb0d23d6d51de973d03cc`，共享 call_id 原样，非 17 次新调用、未新 API 校准，仅证门不证跨候选排序）；结构 load 通过，旧 -2 副本明确不匹配（临时副本验证）。

启动增量冻结 SHA256：

| 文件 | SHA256 |
| --- | --- |
| `plugins/omp-host.mjs` | `fdbffecb67ede14a3b50bd3fc5b2ef31fc70a73ed7661516b9534b9cd11433ff` |
| `contracts/task-runtime.md` | `cfb554d07a6ef0c95ec5c9a8114a84fe1012cf49bd67b4aa51448ed04718459d` |
| `tests/omp_native_gate_test.mjs` | `b0c7ad25b7e00a26d16093198127bff6fbc95def22e9181843ffafbc9617a28` |

该增量在首个可扩展 provider 请求中给受控 Root 工作单元引导（不依赖入口概率，显式与自动入口一致；未受控会话与成员不注入），合并注入、不可扩展保持待发、事实记录首次明确编辑前的单元状态；没有直接程序派发、扩大权限或更改质量排序。前轮独立审查的两项缺口（advisory 早退出吞掉同窗 bootstrap、system 与 payload 同句重复）已修复并复核；已知剩余边界：sent 集合仅进程内，OMP 重启后活动任务会重注入一次（幂等指引，接受）。gate 绿不等于组合回归或实机验收。上表为 bootstrap 三文件冻结值（合同行含选型句修改）；bootstrap 与 policy 均已冻结，不再写入。

## 最小链路的最新事实

1. **真实 Jev API 一次调用成功**：`/private/tmp/orbit-minimal-dispatch-jev/` 原包／回包，HTTP 200，实际 `jev-1.13.0`，`jev-delegation-4`／`jev-selection-input-2`；handoff_fit 0.95、member_task_fit 0.20，input 1647／output 40。该输入没有候选和先验，不能据此判派发失败，也不是派发证明。不要重复同一诊断付费调用。
2. **installed 0.7.21 最小明确交接链已 complete＋confirmed stop**：任务 `26935a3e-fe59-4c74-a2ec-9bc89a272c83`，目录 `/private/tmp/orbit-minimal-chain-PbtkHC/product/.orbit/tasks/26935a3e-fe59-4c74-a2ec-9bc89a272c83`。工作单元 `wu-da565586044f6c8c` 先声明；实际成员 `zenmux/deepseek/deepseek-v4.1-flash` 派发并 accepted；Root 核验固定九例（一个测试组 pass 1／fail 0）；独立 reviewer 同型号、另一进程，终检 complete／coverage complete；Root 与成员停止确认 active_tools 0、async_jobs_settled true。README／package／test 三份固定材料 SHA 未变，全局候选池 SHA 未变。
3. 上述新事实观察保存于 `/private/tmp/orbit-minimal-chain-PbtkHC/controller/handoff-observation.json`；原始 work-units／collaboration／root-verifications／check evidence 仍需新 Root 在需要时核对，不仅相信摘要。
4. **此轮明确要求交接，且只有一个隔离池候选**，只证明该最小机械链可工作；不证明普通需求自主派发、完整池选型、纠正分支或节省资源。启动增量没用于此轮。资源账本尚未完整后验汇总，不能承诺收益。

## 自主派发真正缺口与资源风险

- 只读调查 `/private/tmp/orbit-autonomous-dispatch-audit/autonomous-dispatch-evidence.json`：0.7.20 没有 entry advisory 实现；0.7.21 fresh 显式请求没有触发其概率前提。两次都在实现前没有工作单元，后一次推荐出现于实现后的 provenance 单元。**不能说 Root 忽略了已送达的派发指导，也不能说 Jev 服务一直不工作**。
- 宿主 `before_agent_start` 发生在自动建任务之前，而首次 `before_provider_request` 建任务后原来只尝试概率条件下的 advisory。这是启动接缝的具体缺口；S 增量已修复并复核通过，**待安装与普通请求实测**。
- 质量正向过门后，可信可比成本分支按成本优先；成本未知／不可比分支决策语义已改并实现（实现者 Q）：过门候选保持调用方稳定输入（池）序，不称便宜或可靠，未知不免费。decision-3 放行由 Root 独立审核后重签（证据边界见上节）；组合验证已全绿，**生效以本票安装与后续普通请求实测为准**。池顺序不等于便宜；升版本并审计放行绑定、不重标旧分数的约束保持。
- Q 已完成最小链资源后验 `/private/tmp/orbit-minimal-chain-PbtkHC/controller/resource-post-audit.json`（36 调用全 reported、call_id 唯一、checker 两账本一致、reasoningTokens 子集未另加；billing 全 unknown、未推费用）。该摘要只汇总账本，**不证明普通派发或任何收益**，不推翻下节负例。

## 必须保留的负例

- installed 0.7.20 配对 `/private/tmp/orbit-reconcile-acceptance-ucWZ9UmM/controller-records/paired-comparison.json`：两臂固定 8 测试／6 探针通过，mixed **members=0**，全部 GPT-6-sol 角色总量 376410 vs 289685，**约 +30%**；Root 单侧约 +7.9%。不宣称节省。多次检查属于同一 observation 的有界失败重选，包含真实额度／权限失败和非法结果。
- 0.7.20 成员负例任务 `1d977642`，`/private/tmp/orbit-member-settlement-live-6tGQlP/controller-records/postmortem.json`：Go 429 后替补真实 accepted、Root 8/8，但 amend 引起旧失败成员结算撤销而阻止完成；最终 paused＋confirmed stop，非业务完成。21 源码修复不能重标旧实测。
- 0.7.21 takeover 任务 `8e411be9`，`/private/tmp/orbit-takeover-fixture-1D6DEl/controller-records/postmortem-8e411be9.json`：真实 complete＋confirmed stop，**members=0**；多个真实 provider 故障后 Zenmux 检查成功。该轮不是成员自主或收益证明。
- 更早失败／部分完成继续留在[本次验收](../reference/mixed-model-real-acceptance-20260929.md)及 Git。不重跑已经有效且未受新改动影响的检查。

## 现场资源与所有权

2026-09-30 本次 Herdr live 发现如下；恢复时重新发现，不凭 pane 名判断可用：

| Pane | 角色与当前状态 |
| --- | --- |
| `w1Y:p1A` | 当前 Codex Root；新会话需明确接替编排，避免两个 Root 同时写／派发 |
| `w1Y:p1S` | S，DeepSeek Flash；bootstrap 增量交付后经原生 Esc 停写；0.7.23 组合 full／pack 已由其跑完并停票（gu0Ouq），无 npm 测试残留，idle |
| `w1Y:p1Q` | Q，GLM；bootstrap F1/F2 复核、选型排序审查、phone fixture 准备、policy decision-3 实现、最小链资源后验均已完成并停写，idle |
| `w1Y:p1R` | R，当前 Grok；本轮报告工作区工具不可用，已明确停票（fixture 无文件产物，由 Q 接手），不再重试或写源码，idle；不能默认可用 |
| `w1Y:p26` | `minchain21` 被测 Root，已业务完成，idle；不是开发写者。实际进程 PID 49647 已不存在（本轮复核，未执行 kill），checker 记录 PID 63787 早已不存在 |

最小 fixture 保存 controller／request／session 在 product 之外。其 Root 会话当前 PID 49647 已不存在，本轮未执行 kill（进程表不证明退出原因）；无派生进程需停，原件按需后验核对。不要 kill 通用 OMP／Herdr，不批量删除临时目录；Q/R/S 是用户提供的执行者，不关闭它们。

`/private/tmp/orbit-reconcile-pair2-6Caerb` 已准备但**未启动**。先修并真实验证核心自主链，再用冻结标准作对照，不绕回大任务刷测试。

## 新 Root 的顺序

1. 读取本页、主方案／代码审计／W1—W10、开发规则；核对 live 工作区与 installed identity，继承已有授权。
2. 复用最小链成功和 Jev API 证据；收好本轮原件、处理空闲测试进程。不要重复提交此前业务 prompt。
3. bootstrap 修复与 policy decision-3 均已冻结；0.7.23 组合验证全绿（gu0Ouq，Root 复算 129 SHA）；本交付票执行本地提交＋`sh install.sh`，证据存 `/private/tmp/orbit-release-0.7.23-delivery/`。旧 22 full 不覆盖后来增量。
4. 安装放行后启动已备 phone fixture（`/private/tmp/orbit-ordinary-phone-1XOIXp/`，seed `f59f7d0`，固定 9 测试，请求原文不提 Orbit，沿用用户真实全池，**未启动**）：普通业务请求、不要求用户显式交接，验证实现前 unit／或有据的 Root 自行决定，随后真实推荐、native task、登记、成员回传、Root 集成。若断链，先定位到具体事件和原因再修，不重复大任务。
5. 闭合质量充分后分派与旗舰升级、可信路由成本／实际用量归属、错误控制、finding 纠正、当前版本手动终检与实际停止；新版问题／决策校准绑定保持真实。
6. 核心路径通过后再完成冻结的同质量 Top／混合资源对照，报告全部角色和未知量，按主方案 §11.3 调整负收益路径。逐项闭合 W1—W10、文档、收尾和本地提交后才 complete。

当前没有新的用户审批前置；不要把所有模型可靠性证明、外部发票或全型号认证另加成验收门。用户的 Goal 会话迁移不等于已完成或重新获得一份可以无限重复旧失败的资源额度。

# Orbit 当前执行计划

最后核对：2026-09-30。产品方向以用户认可的[混合模型交付主方案](mixed-model-delivery-proposal.md)为准；当前源码状态见[交接](handoff.md)，逐项实现、调整和删除结论见[代码审计](mixed-model-delivery-code-audit.md)。本页只维护推进顺序，不复制第二份需求或历史实施票。

## 当前交付

用户已认可启动 prompt 并明确要求以 Goal 模式开始完整实现。Goal 已激活，目标是主方案全部必要行为与真实验收同次闭合，不设硬预算。Codex 总编排与审核，已复用同一 Herdr 布局中的四个 OMP 执行者；开发团队和被测 Orbit 原生团队分别记录。

**当前支持安装 0.7.21**（clean commit `fffabf801b430b61aa11d58f86f99960bdd9c8aa`，content digest `ae9ce431ead61d3bb61eb04c5050a7408ef2faf0cdbd42d02e5127512cd7d4fd`，2026-09-30T11:21:07Z 安装，`orbit version --json` 复核一致；未发布；OMP 与 reviewer 18.3.4 未升级）。唯一组合回归 run2 `npm test` exit 0（`/private/tmp/orbit-regression-0.7.21/report.json`）。**源码已提交并安装，业务闭环尚未验收**：普通阶段已结束且未建任务；请求 02 已提交；任务 `8e411be9` 的接管边界已核对，**自动接管已实机跑通一轮并 complete＋confirmed stop（11:44:53Z）**，但**成员=0、无对照或节省证据**，`prior_scope` 追加与 Go 映射接线（五文件）**未安装**；后验见 `controller-records/postmortem-8e411be9.json`。 此前支持安装依次为 0.7.20（clean `1618b81`，digest `08472661…`，08:58:27Z）、0.7.19（`0faf1ce8…`）、0.7.18、0.7.17 与 0.7.12／`a1f9291`。0.7.20 组合交付：成员结算修订、history-gap 检查历史、root_without_hint 恢复、未知生效日成本存档；唯一组合 full npm exit 0（123 PASS，`/private/tmp/orbit-regression-0.7.20/npm-test.log`），pack dry-run 83 files。不因安装宣称完整目标已验收。

主方案 §1.3 和逐项审计是冻结范围。内部实现依赖不是分期发布；自主派发的真实失败、资源归属、独立完成与停止是验收必需项。0.7.11／0.7.12 检查点（`1ffec49`／`a1f9291`）及更早版本的提交、回归与真实运行流水见[本次验收](../reference/mixed-model-real-acceptance-20260929.md)与 Git，不再逐版复制。

## 编排与文件所有权

以下只维护当前有效执行者；已结束的 B／C／D／E 不再是当前席位，其独有事实归入既有 `docs/reference/` 报告与 Git 历史，不另建队列。Codex 负责编排与审核，不声称接管全部体力代码实现。任务票携带主方案条款、审计编号、有效规则、接口与允许修改范围，成员未提交或推送。

| 执行者 | 完整工作面 | 计划主要所有权 | 当前状态 |
| --- | --- | --- | --- |
| Q（`p1Q`） | 独立只读审查 | 只读源码和冻结证据；不改产品或 fixture | 已审接管、入口提示、覆盖容量与自动接管关键测试；执行结算与回执压缩修复经 Q 二次审 PASS，复用已有效结论 |
| R（`p1R`） | 源码修复与组合回归 | runtime／host／合同；最终唯一 full owner | 0.7.20 已组合验证并安装；0.7.21 接管/入口提示/结算与资格修复已集成，**唯一组合 full run2 exit 0**（`/private/tmp/orbit-regression-0.7.21/report.json`，129 文件前后 SHA 相同）；已本地提交 `fffabf80` 并安装（`sh install.sh` exit 0，`orbit version --json` 0.7.21／digest `ae9ce431…`／11:21:07Z）；自动接管已实机跑通 fresh 任务 `8e411be9`（**complete＋confirmed stop 11:44:53Z，成员=0**）；`prior_scope` 追加与 Go 映射接线（五文件）**未安装**，成员路径与对照仍未验 |
| S（`p1S`） | 关键测试、运行后验与回执投影 | gate／check_runner 和各自相关测试；Controller 证据与 docs 按票独写 | 自动接管关键测试已通过（`9fedfd2b…`，含 stdin 修正与 OpenCode Go route bridge 组）；fresh 接管 postmortem 已保存（`postmortem-8e411be9.json`，原件 SHA 前后一致）、0.7.20 成员负例后验保留；回执压缩选择修复已完成（相关 suite exit 0，Q 二次审 PASS） |
| Codex | 编排、集成与审核 | 当前代码与文档 | 编排三个执行者并审核其回执；不声称接管全部体力代码实现 |

已结束的 pane 不再占用界面；被测 Orbit 原生团队与开发执行者分别计证。无需人为占满四个席位，也不将他们替换为内部 Codex 子 Agent。

## 同次交付完成条件

- [ ] W1：入口以执行授权及委派／监督任一路径判断；审计交付、续办归属、拒绝和失败恢复有据，题义与放行记录版本一致。
- [ ] W2：成员与检查者消费任务相关、无时间信号的能力事实；agentic-only、intelligence、上下文／模态、真实路由、冲突和日期未知资格明确。
- [ ] W3：池内、旧无目录、检查者、补证、状态／CLI 和文档全部退出旧时间与粗档费用选型；运行计时、缓存与停止控制保留。
- [ ] W4：明确工作单元与实际派发绑定，原始要求、范围、依赖、验证及升级条件可追溯；串行与自主派发路径不增加用户逐次确认。
- [ ] W5：真实路由价格／额度规则与可得用量按调用、任务、角色及实际身份关联；缺失保持未知，失败和判断用量不漏计，不新增硬预算门。
- [ ] W6：新判断经过代表性真实任务、失败和缺证样本校准，实际型号与问题／输入／决策版本绑定；历史分数不迁成新判断。
- [ ] W7：分层检查与当前要求覆盖闭合，实际工具范围与独立只读生效，必要升级保留此前结果与消耗；最终门及停止不退化。
- [ ] W8：冻结安装构建的真实自主派发、回收、集成、finding 纠偏、手动终检与停止完成；开发者辅助动作不冒充被测 Root 行为。
- [ ] W9：同等验收下比较交付、顶级资源、其他消耗、缺陷与介入；有范围地报告效果，不能以推荐次数或历史不同任务宣称节省。
- [ ] W10：相关检查、完整回归、打包和证据核对完成；文档同步、必要收尾及本地提交完成；不推送或发布后才更新 Goal complete。

## 当前实现与证据

- 入口题义、成员／检查者质量政策、真实 SDK 路由限制、工作单元耐久存储与工具入口、逐调用判断／检查回执账本、覆盖门与近期保留、资源事实／预测 CLI 及成本消费者均已接线；runtime 的旧成员时间双门与整组补证门已删除。有限默认放行的题面／预标签／失败／holdout 与实际 Jev 型号见[有限校准](../reference/mixed-model-calibration-20260929.md)；旧分数不迁移。
- 覆盖门（E04）：逐项留存 requirement／status／evidence 与 check、kind、role、输入／固定产物／根；当前产物 reviewer 完整枚举且全部 verified 才可终检就绪，过程／裁定／stale 不授资格，缺项或坏记录不捞旧 ready。
- 成本表示（0.7.20）：显式未知生效日的事实可 archive／list／report，但**永不覆盖调用、永不参与定价或自动排序**；交叉单价无构成即未知，SDK／OpenRouter 目录价格不作 OMP 结算，订阅不折算现金。
- 宿主 task 预检、实际模型绑定、单元权限与真实内核沙盒、Root 原生自主选择已接线并在脚本／本机核验；脚本通过不等于模型自主交付。
- 接管（takeover）与 entry advisory 已合入 **0.7.21 工作区源码**（`omp-host 83e62a1b…`／`prestart ec1e206c…`／`contract 498ded5e…`），相关测试与 Q 独立审通过；需求文本容量 300→1000 已通过相关验证与独立审；验证回执压缩选择修复（`check_runner c39968f3…`／`contexttest 23254c9a…`）相关 suite exit 0、**Q 二次审 PASS**。**0.7.21 唯一组合 full run2 exit 0**（`/private/tmp/orbit-regression-0.7.21/report.json`；首次 exit 1 为旧校准 stub 无 release 的夹具问题，失败日志保留，只修既有 `judgment_usage_test` 夹具到生产校准形状，未放宽生产门），已提交并安装（`fffabf80`／`ae9ce431…`／11:21:07Z），**实机验收进行中，不能称完整闭环通过**；0.7.20 真实成员运行已完成并保留为负例（见[交接](handoff.md)与[本次验收](../reference/mixed-model-real-acceptance-20260929.md)）。

## 真实验收当前状态

[本次验收](../reference/mixed-model-real-acceptance-20260929.md)及 JSON 记录入口、安装 digest、精确任务与原始用量。**当前支持安装 0.7.21**（clean `fffabf80`，digest `ae9ce431…`，2026-09-30T11:21:07Z；OMP 与 reviewer 18.3.4 未升级）；此前支持安装依次为 0.7.20（`1618b81`／`08472661…`）、0.7.19（`0faf1ce8…`／`80b33374…`）、0.7.18、0.7.17 与 0.7.12／`a1f9291`。本版自动接管已完成 fresh 实机一轮（任务 `8e411be9` complete＋confirmed stop；**成员=0**），**成员路径与对照仍未验**。普通 omp 旗舰对照和 orbit omp 负例分开，开发 B/C/D/E 不算被测成员。

- **0.7.20 安装后已实测**：provider 错误分类与 reviewer 会话原件一致（真实 429／403 → `auth_or_quota`）；paired 对照（baseline plain OMP 18.3.4 vs installed 0.7.20，冻结 8 项测试与 6 项探针每臂只跑一次）两臂 **8/8 与 6/6 全通过**，冻结标准下质量无可检出差异；混合臂 **members=0**（未 exercise 成员替代路径）；顶级模型 GPT-6-sol 总量 mixed 376410 vs baseline 289685（**约 +30%**，root 单侧 +7.9%）；用户介入两臂均 0；自动检查 1—6 是**同一 observation** 上的有界失败重选（Go 429／K3 403／FlashX 403／Go 429／`invalid_result`），非重复观察，check5 的 126455 token 为真实消耗、零接受产出。证据 `paired-comparison.json`。
- **成本事实（installed 0.7.20 已实 CLI 验证）**：隔离项目 `import` exit 0（显式未知生效日存档）、缺标记的缺生效日导入 exit 1、`list` 显示 `effective.unknown=true`、两份真实台账副本 `report` exit 0 且 `cash []`／`cost_complete=false`（107／111 次调用）；`cash` 为空只表示未知，不是 0 成本；账户与实际扣减桶仍未知。证据 `/private/tmp/orbit-resource-unknown-final-akE3Nz/controller-records/live-cli-verification.json`。
- **0.7.20 成员复测为负例**：任务 `1d977642` 首 Go 成员 429、替补成员获原生接受，业务测试原生回执 8/8；验证补证经 `amend` 改变输入后，旧失败成员错误回到未结算，阻止完成。另发现检查上下文压缩遗漏现行测试回执。Controller 原生退出后 `paused`／`stop_confirmation.confirmed=true`，Root、成员与后台工作均停止；不记业务完成。后验见 `/private/tmp/orbit-member-settlement-live-6tGQlP/controller-records/`。相关修复、新版接管／自主派发真实闭环、同质量对照成员路径与效果（W9）仍未闭合；账户与实际现金成本未知。
- **保留的历史失败与限制（不重标）**：0.7.11 两轮混合运行暴露交付证据、native yield 与正常退出缺陷，Root 用量 44／60 次且 input／cacheRead 明显高于基线，**不宣称节省**；0.7.12 第二轮明确交接闭环通过但普通需求自主派发仍待验收，其一轮在途成员 Esc 停止与「27 次账本 3 次用量未知」的记录保留；0.7.12 同质复测显示 Root input 约为旗舰基线 3 倍、cacheRead 约 3.5 倍（**负收益信号**，W9 未闭合）；0.7.13 删除自动注入缺证清单并修正 CLI 路由文案，但该轮完整 npm test 因沙盒 `EPERM` 未完成、不宣称回归通过；0.7.17 已安装轮的旧检查自身失败使 **workspace-stale-on-completion 语义未验证**（后续 0.7.18 rebind 任务 `35f925ba` 已验 `stale=[workspace,artifact,input]`）；0.7.18 首轮 `1216aeef` 完成但 `findings={}`、members=0；0.7.18 `02a5eda7` 仍为 **partial／paused**（非业务完成，详见[交接](handoff.md)与[限制清单](debt-ledger.md)）；正式基准 API 匿名实测 401、ego-browser bootstrap 失败等历史记录保留。逐轮细节见[本次验收](../reference/mixed-model-real-acceptance-20260929.md)。

## 下一动作

当前优先级按 2026-09-30 只读取证纠正（证据 `/private/tmp/orbit-autonomous-dispatch-audit/autonomous-dispatch-evidence.json`）：

1. **生产 Jev 一次最小调用**：先把真实 Jev API 与具体单元判断跑通一次（该能力此前成功过，与“自主派发未 ready”分开记录，不能互相替代）。
2. **明确单元，再走真实 native 派发／回收**：要求“**实现开始前就有可派发单元**”，随后验证 hint→Root 原生 `task` 派发→成员注册→结果回收。
3. **修实现前路由与关键事件**：普通入口与显式入口都要在实现前的可扩展请求窗口给出“先声明单元”的指引或事件；**0.7.20 没有 advisory 代码，0.7.21 fresh 的显式入口也没触发 advisory，且实现前没有 unit**——这是产品接缝缺口，**不能归因 Root 忽略**。
4. **核心链通过后**才做更大任务与旗舰／混合资源对照（此前 paired 的 members=0 不构成成员结论）。

事实边界：0.7.22 增量 full 已绿但**未提交、未安装**，当前安装仍为 **0.7.21**；`prior_scope` 追加与 Go 映射接线（五文件）仍属未安装增量，与本条优先级无关。逐项闭合 W1—W10 后才更新 Goal complete；**不推送、不发布。**

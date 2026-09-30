# Orbit 当前执行计划

最后核对：2026-09-30。产品方向以用户认可的[混合模型交付主方案](mixed-model-delivery-proposal.md)为准；当前源码状态见[交接](handoff.md)，逐项实现、调整和删除结论见[代码审计](mixed-model-delivery-code-audit.md)。本页只维护推进顺序，不复制第二份需求或历史实施票。

## 当前交付

用户已认可启动 prompt 并明确要求以 Goal 模式开始完整实现。Goal 已激活，目标是主方案全部必要行为与真实验收同次闭合，不设硬预算。Codex 总编排与审核，已复用同一 Herdr 布局中的四个 OMP 执行者；开发团队和被测 Orbit 原生团队分别记录。当前源码 package 为 **0.7.20（待安装、未发布）**；**支持安装仍为 0.7.19** clean 构建（commit `0faf1ce8f723f89059cc01054bd7ce5014a5587c`，digest `80b33374dbdad0154eb61fca0401414d77ba734b0b39ad70a14c09be88d74844`，2026-09-30T06:14:55Z 安装；OMP 18.3.4 未升级）。包内标记不代表已安装行为，实际安装元数据待真实安装后另写一次；不因安装宣称完整目标已验收。此前支持安装依次为 0.7.18（clean `90433694…`）与 0.7.17（clean `4a00ba70…`）。

主方案 §1.3 和逐项审计是冻结范围。内部实现依赖不是分期发布；自主派发的真实失败、资源归属、独立完成与停止是验收必需项。基线本地提交为 `4ce0b3a`、`8e3f0da`；0.7.11 检查点 `1ffec49` 保存覆盖门及之前有限校准、成本数据流、基准双接口、有效上下文和终态用量；两轮真实运行暴露交付证据、native yield 与正常退出缺陷。修复提交 `a1f9291` 已安装并完成 0.7.12 真实实测（历史，不重标）；0.7.17 已安装，本轮真实路径与开放问题见下。

## 编排与文件所有权

以下只维护当前有效执行者；已结束的 B／C／D／E 不再是当前席位，其独有事实归入既有 `docs/reference/` 报告与 Git 历史，不另建队列。Codex 负责编排与审核，不声称接管全部体力代码实现。任务票携带过主方案条款、审计编号、有效规则、接口与允许修改范围，成员未提交或推送。

| 执行者 | 完整工作面 | 计划主要所有权 | 当前状态 |
| --- | --- | --- | --- |
| Q（`p1Q`） | 只读独立审查与外部探针 | 只读；不改源码、不改 fixture | 进行中：0.7.19 修复的 5 文件逻辑审查 PASS（`/private/tmp/orbit-reviewer-429-fix/review-q.json`）；0.7.19 修复逻辑与组合接缝复核 PASS（`independent-review-combined-frozen.json`，含自选成员 `work_unit_id` 接缝）；reconcile 准备态的独立审查与 P1—P6 探针已写 `/private/tmp/orbit-reconcile-acceptance-ucWZ9UmM/controller/independent-review-and-probes.json`；**当前只读审剩余缺口** |
| R（`p1R`） | 源码修复、回归与安装 | 源码与运行元数据 | 进行中：0.7.19 真实 provider 错误分类修复已装入（full npm test exit 0，日志 `/private/tmp/orbit-reviewer-429-fix/npm-test.log`）；已交付 02a5eda7 根因只读报告（成员结算不随工作单元终裁、`members_settled?` 阻断 pending 通知且无超时出口；停止时 bridge 读失败属次生），R 报告的 F1—F3 只是候选，Root 实施票**不采**“终裁单独置 completed／failed”，方向为多事实结算（原生本派发结果／真实 error＋精确 work-unit 核验＋真实执行就绪；`acceptedAt` 不伪盖；缺证一次通知 Root、不自动 needs_user／stop_unconfirmed／失败）；**多事实结算语义已写入合同（2026-09-30 修订）**；S 定版（8 文件）经 Q 独立审 PASS 后集成，组合 9 文件在先前定版上 8 条相关套件 exit 0。**源码已集成**（主仓含成本表示补丁，4 个成本文件与 S frozen SHA 一致；合同保留两轮逻辑）；自选成员 `work_unit_id` 接缝经 Q 独立复核 PASS（`task_runtime.rb` `c01a2df3…`、`task_runtime_test.rb` `b1c957b7…`、合同 `568edd7e…`）但**未实测**；**R 当前跑唯一组合 full npm**，package 已 bump 0.7.20、**未安装**（支持安装仍 0.7.19） |
| S（`p1S`） | 事实收集、fixture 与文档 | `/private/tmp` fixture 与六份 docs | 进行中：reconcile 两臂准备与冻结、member-positive/rebind/finding-order 终态事实归档；路由资源事实报告经 Root 复核撤回两处不成立推断（Go 事实的生效日、日期门结论）后重做并冻结（0 条可导入、10 条字段级阻塞、三份真实台账证据；该报告无独立 PASS，独立 PASS 属 history-gap 源码定版），随后按 0.7.19 源码修正六份文档；成本表示补丁（显式未知生效日 archive／list，永不覆盖／定价／排序）已由 R 集成进源码、未安装。**当前进行七份文档同步（不含源码／合同／主方案）** |
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

- 已提交／安装的集成检查点 `27f4ee1`：新版有限入口与选型放行、overview-v3 双接口／多变体、实际 SDK 路由限制、成本预测生产及消费者、真实 credential 归属、晚到用量、cwd／首轮 AGENTS 重绑定。完整回归、打包与 skill／diff 核对通过。
- 默认放行的真实题面／预标签／失败／holdout／实际 Jev 型号与独立复核见[有限校准](../reference/mixed-model-calibration-20260929.md)。只限 Git 未截断入口及有界 Git 交付；新题面 delegation-4／candidates-4／checker-task-fit-5，选择 input-2／decision-2。旧分数不迁移，Noul 不作未来成功证书。
- E04 已接后续源码：覆盖逐项留存 requirement／status／evidence 与 check、kind、role、输入／固定产物／根。新版检查启用覆盖门，当前产物 reviewer 完整枚举且全部 verified 才可终检就绪；过程／裁定／stale 不授资格。缺项、坏记录、写失败不捞旧 ready。私有投影有界保留近期记录和最新适用 reviewer，完整历史在 checks，不按累计检查次数阻断。核心链与精确保留修复均经 C 独立复核；当前源码相关测试通过。
- 覆盖接线版完整 npm test exit 0，随后只改近期保留逻辑及新版检查启用 flag；其相关测试、独立 probe 和最终一行复核通过。版本按规则升为 0.7.11，提交 `1ffec49` 并已支持安装，不能将 0.7.10 的负例当新覆盖门实测。
- 宿主 task 预检、实际模型绑定、单元权限及真实内核沙盒、Root 原生自主选择已经接线；无池按实际可解析原生成员处理，不用整组补证门。脚本通过不等于模型自主交付。
- 费用预测严格绑定真实路由、账户／计划、当前单元／检查与可信源。交叉单价无构成则未知，SDK／OpenRouter 目录价格不作 OMP 结算，订阅不折算现金；账本保留真实分类、失败、pending 和晚到 final。

## 真实验收当前状态

[本次验收](../reference/mixed-model-real-acceptance-20260929.md)及 JSON 记录新 Herdr 入口、安装 digest、精确任务与原始用量。当前支持安装 0.7.19（源码 clean `0faf1ce8…`，digest `80b33374…`，2026-09-30T06:14:55Z；OMP 18.3.4 未升级）；此前依次为 0.7.18（clean `90433694…`，05:02:32Z）与 0.7.17（clean `4a00ba70…`）；此前支持安装为 0.7.12／`a1f9291`，digest `3f3446eb02ef794c917f5affc11d74d137f68d4167467fe78346543d92880613`，安装时源码 clean；此前 0.7.11／`1ffec49` 的 digest `7a9c57577866fb8e4308367330e53ec10c089b344e37cccffa05b3011101b07c`。普通 omp 旗舰对照和 orbit omp 负例分开，开发 B/C/D/E 不算被测成员。

- **history-gap 组合**：S 定版通过 Q 静态审（`/private/tmp/orbit-history-gap-c4Qfwfly/controller-records/independent-review-s-fixed.json`，PASS；其回放是**控制器确定性重放**，不是新 Orbit 实测），已并入；相关套件已通过，0.7.20 组合完整 `npm test` exit 0（`/private/tmp/orbit-regression-0.7.20/npm-test.log`），未装实测。自选成员的 `work_unit_id` 关联缺失已由 R 精确恢复，并经 **Q 独立复核 PASS**（`task_runtime.rb` sha256 `c01a2df3…`、`task_runtime_test.rb` `b1c957b7…`、合同 `568edd7e…`、`final-integrated.patch` `8347fa0b…`；`resolve_member_unit_id` 按精确 thread_id＋tool_call_id 取该单元最新派发，要求 input_digest 与 artifact_root 均为当前，模型不符即漂移不匹配、歧义为 nil，绝不按相似型号或时间接近归属），**未安装、未实测**；**源码回归不当作新构建真实验收通过**。
- **reconcile 两臂（2026-09-30）**：baseline 臂用 plain OMP 18.3.4（非 Orbit 验收），有效轮真实 8/8（最终回执 `node --test 8/8`；终端观测 `controller-records/baseline-terminal-observation.json`，开局冻结探针回放 2/6 通过对应未实现起点 `harness-smoke-baseline.json`；一次 Controller 提示错误轮单列不合并）；mixed 臂已备**未跑**（`controller-records/mixed-launch-plan.json` status=prepared, NOT launched，等待合并修复复核、全量回归、clean commit 与新安装构建）。
- **真实成本报告仍全为 unknown（2026-09-30）**：对三份真实台账运行 `route-resources report`（store 为空）得 107／111／41 次调用全部 unknown、`cash=[]`；`02a5eda7` 的 gap 分为 37（无已核实事实，codex）、37（缺账户范围，zenmux 36＋opencode-go 1）、33（缺开始时间，typesafe 27＋kimi-code 5＋opencode-go 1）。第一方价格／计划资料存在，但页面未给发布生效日，事实因此 0 条可落盘，未用目录价或推断日期补账。
- 负例 passed：实际一行修改和验证，当前 Jev 价值门未过，未建立任务／hint／原生成员；正常退出及派生进程结束已确认。
- 旗舰对照：独立完成 CSV，冻结八项 8/8；十八次 SDK 分类用量和退出留证，C 独立按规范静态核对及额外本地探针通过。
- 第一混合轮 `cae67791-af23-4058-8096-30d18b24f7f6` 自行完成，固定八项通过；独立终检、程序 complete／confirmed stop 及原生退出留证，但无成员派发。第二轮 `b410702f-039a-4a83-9365-7a67c8a1fd83` 的当前 Jev hint→原生成员→hub→Root 集成发生，固定八项通过；需求明确要求交接，普通自主选择仍待证明。七次 yield 被拦导致成员无 acceptedAt，终检后仍未通知；原生退出实际进程结束，但程序 stop_unconfirmed，不能算通过。
- 六份已完成产物均通过冻结原始八项和同一组 README 导出的补充八项；0.7.11 两轮混合 Root 44／60 次调用、input 与 cacheRead 明显高于基线18次，当前不宣称节省。逐次探针和分类资源对照见验收报告。
- 0.7.12 已接 scope-2、Root 原生测试验证回执、检查调用副本关联、native yield、pending 成员最终通知与 registry 已移除时精确 retained session 停止屏障、目录单候选错误隔离和闲置状态更新。相关回归及 B/C 独立精确复核通过，完整 npm test exit 0、打包与 skill／diff 检查通过。新构建第一轮实测可信 `npm test` 回执、独立 OMP 固定快照与 scope-2 交付覆盖 ready，一次通知后 complete 且 confirmed stop；Root 自行实现。第二轮明确模块交接的 Jev hint→原生 task/hub→成员两次实际 yield／accepted→Root 集成／工作单元 accepted→原始 8 项通过→一次独立无 finding 终检→一次通知→Root／成员 confirmed stop，完整闭环；原生 /exit 后进程消失且状态不回退。仍不能将明确交接等同于普通需求会自主选择派发。
- 0.7.12 第三轮在 Zenmux 原生成员仍运行且未交付时，经 Herdr 发送原生 Esc；Orbit 记 paused、Root 和成员均确认实际停止、活动工具与归属异步作业为零。随后 /exit 后 Root／MCP 进程消失；27 次账本调用中 3 次用量未知，未编造中断后的值。该轮不证明交付终检，也未单独构造后台 shell 作业。
- linked-worktree 重绑定准备轮在 Controller 抓取 `in_flight` 前已完成，没有真正 rebind 或 workspace stale，不计验收。旧根检查者一次 schema 错误后有界换 K3，第二次独立检查通过并 confirmed stop；原始 8 项在 Controller 副本重放 8/8。该轮只提供时间窗与降级事实，不推断重绑定通过。
- 同质产品复测显示 0.7.12 自行完成／明确交接两轮 Root input 分别约为独立旗舰基线 3.05／2.96 倍，cacheRead 约为 3.49／3.63 倍；成员、检查者与 Jev 另有消耗，真实 OMP 现金／额度成本未知。这是当前 CSV 样本的负收益信号，不能把成员派出视为已证明节省；W9 尚需不同任务与完整比较。
- 原始 0.7.12 会话显示，自行完成轮被首轮 `[orbit-model-evidence-needed]` 提示引向 Kimi／GLM 一手资料研究，虽已选到可运行降级检查者、无执行成员；提示还硬写 `billing_route: unknown`，与 `evidence_needed` 的真实 `subscription_quota` 冲突。0.7.13 源码删除这条自动注入，保留可选精确补证响应并要求逐候选保留真实四键。定向 CLI 测试、JS 语法和打包检查通过；完整 npm test 在沙盒 TCP bind `EPERM`、宿主 JS 测试在 Unix socket `EPERM` 处停止，不宣称新源码回归或真实降耗已证明。
- 0.7.14 源码修正 F03：`declared_workload` 仍可展示按可信本路由价格算出的条件性金额，但无可归属用量样本时不能自动比较总成本或改变质量排序；`similar_unit` 的 token 分类构成必须等于可归属完成回执的逐类均值，真实引用不能掩盖任意预测数字。仅一个正向候选时也不宣称发生费用比较。定向成本／成员／检查者选型测试通过；当时完整回归待环境恢复（2026-09-30 已恢复，后续版本全量通过），真实派发效果仍待新安装构建验证。
- 0.7.15 源码修正 D02／D06／D09：工作单元每次 finish 的结果和核验绑定对应派发记录，重派及换模保留历史；现有 Jev 投影与原生成员交接继续传递这些字段。工作单元、两阶段选择输入及资源定向测试通过；不宣称真实失败升级已验收。
- 0.7.16 源码修正 F03／D09：历史成员成本样本除单元最终 accepted 外，还须匹配实际被接受的成员和型号；前次调用正常返回但结果被拒绝，不能因后续换人成功获得成功样本资格，实际消耗仍留账。新增回归先复现旧代码误放行，再验证修复；成本／选择／工作单元／账本定向测试通过。执行环境权限已恢复，0.7.16 完整 npm test exit 0、pack dry-run 与 diff 检查通过，原始日志在 /private/tmp/orbit-regression-0.7.16；仍未安装或真实派发验收。0.7.17 源码修正：原生 record_check 回执不携带 reasoning、账本存 nil，similar_unit 引用核验仅在比较处把该缺失对齐类型化 unknown（不回写账本、具体已报告档位仍精确匹配），并修正 prior_sources 被 MAX_SOURCES=5 截断时丢失 artificialanalysis.ai——基准实测站点与专用端点优先保留；复现旧失败后修复，完整 npm test exit 0（日志 /private/tmp/orbit-regression-0.7.17）、pack dry-run 与 diff 检查通过，当时未安装（注：该构建 0.7.17 后来已安装，见下文 2026-09-30 真实路径段）。
- 用户要求清理界面后，已结束的 B/C/D/E、自有 F/G、空闲未接任务的 H/J 及验收 K/M/N 均已关闭。重绑定准备轮 `w1Y:p1P` 的 Orbit 任务先前已 confirmed stop；随后 Herdr 允许向空闲 pane 输入，Controller 发送原生 `/exit`、待 OMP 返回 shell 后发送 `exit`，`herdr pane list` 确认该 pane 消失，界面只剩主 pane。执行环境曾拒绝 Herdr 的 `pane split`／`process-info`／`close`（`Operation not permitted`），为当时历史失败记录；权限现已恢复（0.7.16／0.7.17 完整 npm test exit 0 期间含 socket 绑定测试通过）。已准备的独立 linked-worktree 夹具 `/private/tmp/orbit-rebind-live-pshm82xn/` 确认两目录同属 Git `40fd207`、原始八项测试 SHA256 同为 `5e3161e3fadf9588b4a0269a8fd50b3fd99430e932105b74a5dc2e33114d27fd`、初始各仅 4/8 通过且尚未实现交付。夹具准备不等于重绑定通过。

OpenRouter 正式基准匿名请求曾实际 HTTP401，该历史保留不重标。项目 `.env` 现已提供 `OPENROUTER_API_KEY`，经源码双接口实测 HTTP200、刷新 446 个非 alias 行，key-free 证据在 /private/tmp/orbit-or-verify/verification.json；不借用其他供应商凭据。checker 与 member 两侧 facts 消费各有实证（member 侧目录事实消费已有实证（后台任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07` 成员选择阶段，4/6 候选随真实 Jev 输入送达；详情见验收报告与 JSON）；member 推荐采纳与成功交付、完整真实身份与覆盖仍待证）；基准语义测量日期单独一项仍 unknown（无逐模型测量日期，只有快照级 as_of）；第一方价格／计划事实已按其适用条件留证，账户凭据与实际扣减归属是另一项未知，两者不合并；新安装构建真实闭环与候选完整身份／冲突资格仍需实际核验。OpenCode Go 官方资料允许套餐额度用尽后以 Zen 余额回退，单靠端点不能证明逐调用额度归属；此前受限执行环境的 ego-browser bootstrap 失败记录保留，未改账户或价格事实。

2026-09-30 0.7.17 已安装构建的真实路径（同一内容 digest `4b3e6f40…`）：logstat 两臂同质产品对照在冻结 8 项黑盒测试与 6 项冻结探针上均 8/8 与 6/6 通过（exit 0）；Root 逐类用量（input/output/cacheRead）为 baseline 23060/4904/150528、mixed 23782/4971/458112，mixed 更高，**不是节省**，member 未派发（members=0）；混合臂 Root 经 `xd://orbit` 设备调用控制面 4 次（read 协议 + write context/check/stop），两次自动唤醒注入驱动手动终检与完成申请，账本 root 25 笔与会话 25 条逐类相等。在途旧根 rebind：确认旧根 reviewer 真在途（独立 pid 98639）后排队 rebind+amend，1 秒后 `workspace_rebound`，新根检查 5/6 complete 且终态 stop 确认；**旧检查自身失败（无效 JSON）：旧检查 1 于 03:32:15Z 启动（reviewer 进程 03:32:20Z），重绑定 03:32:22Z 生效，该检查 03:33:13Z 记 `check_failed`、`stale` 为 null：该旧检查自身失败、未得到正常的 stale 结果，因此 workspace-stale-on-completion 语义未验证**；同模型连续 4 次检查者终态消息失败作为环境／模型稳健性观察报告 Root。一行修改负例单列、未与 rebind 路径混用。后台预览任务：paused 中断停止 + stop_confirmation 确认（Root 与两名成员），/exit 后原 PID 26548/26665/26773 与 preview 33443 均不存在、pane 关闭，**业务交付仍未完成**。0.7.18 源码修复 `715e579`：两处已定位缺陷（hint 边界自失效、`edit` hashline 投影拒绝）已修，npm／version／pack／diff 均 exit 0，Q 直接影响复核通过，SDK 无模型探针参考 `/private/tmp/orbit-sdk-surface-probe/sdk-surface.json`；0.7.18 首轮实机（任务 `1216aeef`）已实测：首个有效程序独立检查严格早于任何产品编辑、`delivery.ready=false` 且未诊断金额缺陷（缺陷由 Root 自测失败暴露）、终检 `ready=true`、1 次终检通知与 1 次完成停止 confirmed，但 `findings={}` 未 exercise 结构化 finding 生命周期、members=0，**不作成员交付／质量诊断／节省结论**；实机成员编辑与采纳闭环仍待验收；0.7.18 另两轮终态：**rebind 任务 `35f925ba` 最终 complete／confirmed**，旧检查 1 `stale=[workspace,artifact,input]`、findings 未迁移（Q 终态原件 `controller-records/terminal-verify-35f925ba.json`；Root `/exit` 后 PID 89427／89483／89602／93302／95760／29378／74402 均不存在、p23 关闭）；其间类型化 finding `preimplementation-check-evidence` 走了 record→correct→resolve→finalize 闭环，但检查者看不到 checks/2 与首改原件的历史证据缺口使 Root 额外自造证明文件并多轮争议，**不因此伪称该 bug 不存在**。**member-positive 任务 `02a5eda7`（`/private/tmp/orbit-member-positive-N0ghF3bI`）为 partial**：首个成员真实采纳 `orbit_hint` 后遇 Go 429，替换 Zenmux 返回解析器、Root 整合后 8 项通过；手动 check2 `ready=true`，但两成员仍 registered／registry idle、无 accepted_at，`pending_finalization` 等待而未通知，Root 仅以 `/exit` 结束 → `paused`（Root 与两成员 confirmed），**非业务完成**；根因**已定位**（详见验收报告与 JSON）：成员原生终态停在 registered／idle、unit 终裁不驱动结算、`members_settled?` 阻断 pending 通知且无超时出口；停止时的 bridge 读失败是次生症状，不是停滞原因。修复未落地（R 实施、Q 审核）；该轮仍为 0.7.18 partial／paused，0.7.19 分类源码／安装不等于新实测（PID 27817／27874／28039、worker 31539 已不存在，p24 关闭）。0.7.19 修复真实 provider 错误分类（Go 429、401／403 auth、瞬态 429／500 unavailable；errored turn 即使合法 JSON 也不授结果），装入前 full npm test exit 0（`/private/tmp/orbit-reviewer-429-fix/npm-test.log`），Q 逻辑 PASS；**不声称 0.7.19 新 runtime 已通过实测**。新开放问题：后台任务三因已确认：① K3 成员的 `edit` 走 hashline `{i,input}` 方言，被 `work-unit-scope.mjs` 的键白名单投影拒绝（**0.7.18 源码已修（715e579），当前实机待验收**）；② 首个成员收到 provider HTTP 429 `Go usage limit exceeded` 被判 rejected（provider 额度，非 Orbit 缺陷）；③ **hint 采纳归因根因已确认、源码已修（715e579）、当前实机待验收**：`task_runtime.rb` 的 `collect_amendments` 将本任务 `sent_message_ids` 中的内部提示推进 `last_user_message_id`，使自身提示的 `user_boundary` 失效（宿主门与 `current_delegation_hint` 都要求两者相等）；03:43:28Z 首次 hint 本可匹配（模型／单元／输入／产物均对）却未绑定；该缺陷已在 0.7.18 源码修复（715e579），当前实机待验收。work-unit dispatch bind 记录真实存在（不是未绑定派发）；W1—W10 仍未勾选，Goal 保持 active，经济收益尚未证明。价格事实只按第一方适用条件记录，账户凭据与实际扣减保持 unknown，不用 SDK／目录价格冒充结算。

## 下一动作

1. 已完成精确复核、打包与文档检查，提交并支持安装 0.7.11／`1ffec49`，digest `7a9c57577866fb8e4308367330e53ec10c089b344e37cccffa05b3011101b07c`。
2. 已完成 0.7.12 完整回归、打包、本地提交和支持安装；两轮实测分别验证可信回执／无成员停止及明确交接的原生成员、集成、终检和 Root／成员完成停止。普通需求的自主派发策略仍待验收；在途成员 Esc 已通过，失败旧样本保留，不重标通过。
3. 在途成员原生 Esc 与完成成员的正常退出已实测；继续按冻结矩阵闭合真实 finding 纠偏、真正处于 in_flight 的 rebind stale 和独立后台作业边界，用冻结产品要求与统一评价比较旗舰及混合资源。恢复 Herdr 的 pane 创建权限后，在已准备的 linked worktree 上运行新任务；旧 P pane 已清理。
4. 吸收证据、同步状态、停止并清理自有资源；完整 W1—W10 和必要收尾都满足后才 complete。当前仍全部未勾选，不推送或发布。

新增验证总量超过单一小改动的 10 项／300 行建议，原因是完整目标跨入口、选型、单元权限、路由资源、覆盖及停止；覆盖已复现身份失配、沙盒越界、跨账户混算、晚到回执和未核验误放行，不机械追求覆盖率，也不据此拆成后续发布。主方案及审计是冻结范围，旧 M4 和旧体验任务不重开。

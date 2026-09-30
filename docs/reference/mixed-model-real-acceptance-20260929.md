# 混合模型交付真实验收

2026-09-29 开始，2026-09-30 更新，实施与验收中。完整目标见[主方案](../plan/mixed-model-delivery-proposal.md)，逐项对应见[代码审计](../plan/mixed-model-delivery-code-audit.md)。本文保存同次任务的真实交付证据，不以校准、确定性测试或开发 helper 工作替代被测程序。原始入口判断、SDK 用量、精确要求与对照测试输出见[证据 JSON](mixed-model-real-acceptance-20260929.json)。

## 冻结构建与拓扑

- 源码检查点 `27f4ee1a39112c83a5ed116718ec540b0ce1e834`，已通过完整 npm test、package dry-run、skill validator 和 diff check。本地支持安装路径成功，版本 0.7.10，dirty=false，2026-09-29T15:04:06Z 安装；content digest `9765c856e5b8e1d98e8494f081ee3919a6c8acc708d866677e0bb2e9971add09`，OMP／reviewer SDK 18.3.4。它不是完整目标已经验收或发布的声明。
- Controller 为当前 Codex，Herdr 传送与观察；本轮自有临时目录 `/private/tmp/orbit-mixed-live-c8n233cn`。开发 B/C/D/E panes 不算被测成员。
- 负例：新 pane `w1Y:p1G`，明确安装入口 `orbit omp --model openai-codex/gpt-6-sol …`；进程参数实际含安装 release 的扩展。
- 旗舰对照：新 pane `w1Y:p1F`，普通 `omp --model openai-codex/gpt-6-sol …`；实际参数没有 Orbit 扩展，会话未调用 Orbit 或原生 task。安装未创建全局 Orbit 入口。两者均在隔离临时 Git 项目中运行，无 Controller 代写交付。
- 覆盖记录接线后提交 `1ffec4938b45cd3609323528c69c6601a6d4a95e`，支持安装为 0.7.11、dirty=false、源码路径回到原仓，2026-09-29T15:33:00Z 安装；content digest `7a9c57577866fb8e4308367330e53ec10c089b344e37cccffa05b3011101b07c`。上述负例不充当新覆盖门验证。
- 混合正例已经在新构建启动：复用自有 shell pane `w1Y:p1F`，命名 `mixed-positive`，实际 Root PID 79153、原始会话 `01a0edcc-c4ca-738a-9919-7c637928c5a6`，cwd 为隔离 `mixed/`；实际 argv 加载新安装 release，初始要求仅发送一次。程序建立任务 `cae67791-af23-4058-8096-30d18b24f7f6`。该轮 Root 自行实现，未派发成员；两次独立终检后受控完成及原生退出已确认。它不能证明自主混合派发，完整要求和构建在证据 JSON。

## 已取得结果

| 路径 | 实际结果 | 证明范围 |
| --- | --- | --- |
| 一行修改负例 | GPT 修改指定导出字符串，npm test 通过；无任务目录、无 hint、无 native task／注册成员；原生 /exit 后 PID 39248、39314、39455 全部消失，pane 回到 shell | 新版入口与普通执行边界、这一负例的退出；不证明有成员任务的停止 |
| 入口真实 Jev | 实际 jev-1.13.0，授权 0.95、委派价值 0.50、监督价值 0.13，决策 root_decides；当前 entry-3／input-2／decision-2 与有限校准绑定；input 802／output 63 | 当前题义未把局部改字升为受控任务 |
| 旗舰独立交付 | CSV 解析与订单聚合实现完成；Root 自跑 9 项，新增一项行号测试但未改原 8 项；Controller 在产物副本上重放冻结的原始 8 项，8/8 通过。原生 /exit 后 PID 36422、36566、36821 全部消失 | 对照产物及统一黑盒验收通过；C 独立按冻结规范复核并做额外本地探针通过；混合效果比较仍待闭合 |

订单任务的产品要求冻结在种子 README 与原始八项黑盒测试：严格表头、引用／转义／CRLF、正整数数量、最多两位非负金额、整数分聚合、排序 JSON、非法输入报错与无部分 stdout。旗舰组明确单独执行，混合组允许有界解析模块交接、Root 集成与终检；执行方式按实验条件区别，产品要求和统一验收不变。Controller 只准备未实现种子和检验产物副本，不改被测交付。

旗舰组 SDK 记录十八次 gpt-6-sol 调用：input 24895、output 6889、cacheRead 279936、cacheWrite 0；reasoning 报告和为 3595，其中四次未报告。分类按 SDK 原定义保留，不把 reasoning 再加到 output 或假设缺失为零。Find 等内置服务没有额外资源回执时保持未知。SDK 的 cost 数字是目录估算，不是可核验订阅结算；实际现金和额度消耗未知。

## 两轮混合实测及失败

第一轮 `cae67791-af23-4058-8096-30d18b24f7f6` 的初始需求允许 Root 自主决定解析模块交接，Root 选择自行实现。固定八项重放通过；两次独立终检后发出有效通知，任务在 15:47:28Z 记录 complete、stop_confirmation.confirmed=true，实际工具为零且背景工作已收尾。随后 Controller 原生 /exit，Root／MCP PID 79153、79183、79217 消失。该轮第一检查没有可信测试执行证据，Root 保存自写日志后二检将其视为通过；这是待修的证据问题，不能把日志当程序回执。

第二轮 `b410702f-039a-4a83-9365-7a67c8a1fd83` 明确要求把解析模块交给成员。真实 Jev delegation-4／candidates-4 产生当前单元与版本绑定的 hint，Root 自主选 opencode-go/deepseek-v4.1-flash，登记成员 `orbit-e55dd99b-79fd-478f-8173-0b53a96717bd` 后实际运行、通过原生 hub 返回、Root 集成并接受单元。另一个 Zenmux 原生成员进行了只读执行审查；它仍是执行成员，不能冒充程序独立检查者。之后程序另启独立 OMP 固定快照检查。固定八项在产物副本重放 8/8，原测试摘要未改变。

两成员合计七次 native yield 被范围门拒绝。SDK 18.3.4 的三个 markResultAccepted 入口都以实际 yield 为条件，因此成员即使 idle、有回复和 output_path，仍没有 acceptedAt，任务没有 finalization_notice。不能以 idle 或 Root accepted 声明改写为成员完成。Controller 保存失败后原生 /exit：Root／MCP PID 93804、93870、93984 已消失，但 Orbit 停止时遇到 registry 先移除成员、保留的精确会话未进入停止分支，实际记 stop_unconfirmed。这轮是交接链路证据和完成／停止失败样本。

| 组别 | Root SDK 调用 | input | output | cacheRead | 当前结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| 旗舰基线 | 18 | 24895 | 6889 | 279936 | 固定验收通过 |
| 混合一轮自行完成 | 44 | 157788 | 12419 | 1793664 | 交付及无成员受控停止通过，未派发 |
| 混合二轮明确交接 | 60 | 136031 | 15321 | 1976704 | 集成交付通过，完成与成员停止失败 |

第二轮原生成员另有 opencode-go 23 次、Zenmux 13 次调用，其中 Zenmux 一次分类用量未知。按角色／实际型号分桶的已知数和缺失分类在 JSON；两轮还发生 Jev、独立检查及内置 WebSearch 服务调用，不从这张 Root 表推断总成本。reasoning 是 output 子集，不能重加；SDK 单价不是可信 OMP 结算，现金和订阅实际消耗仍未知。这些失败／校准试跑比基线用更多旗舰资源，不能据此声称有效节省。

## 本次源码修复与验证边界

源码升为 0.7.12，提交 `a1f9291a65bc2cf830c0e8ab745b75049db925b8` 并支持安装：2026-09-29T16:38:36Z，dirty=false，content digest `3f3446eb02ef794c917f5affc11d74d137f68d4167467fe78346543d92880613`。新任务尚在实测：放行成员 native yield 生命周期入口；覆盖 scope-2 区分交付和后续检查／停止，测试执行仍属交付；真实 Root 工具 start/end 生成私有验证回执，钉住 start 要求／任务与 end 产物，检查者消费当前版本匹配、失败和截断事实，不信自写日志；检查者消息副本使用真实串行调用边界关联用量；同次未核验不能立即被自身退休逻辑翻掉，合格手动检查可等待成员实际接受后发一次通知；registry 已移除时仅凭精确 retained session 的实际取消、回收、dispose 与工具观测确认停止；无关坏目录身份不再清空所有检查者任务要求；完成后的闲置 pane 状态随耐久记录更新。

B 独立静态核对去时间的七个面并通过；B 独立复核验证回执两端，指出身份失配已修及中断 replay 的真实 started 变体已保留为 interrupted；C 独立定位 finalization 阻断并复核原门未弱化、同次 readiness 修复、retained stop 屏障，相关回归通过。源码接线和脚本验证不是新安装真实完成证明。

0.7.12 第一轮新任务 `327bba74-e1e5-4e2b-807f-f4e64bf540a4` 使用独立种子 `mixed-fixed/`，Herdr pane `w1Y:p1K` 的真实 `orbit omp` Root PID 49091，session `01a0ee0c-5a1f-7273-bf2b-af4fb46b578a`，安装 digest 如上。原始要求允许 Root 自行决定解析模块是否交接；Root 再次自行实现，没有原生成员或委派 hint。因此这轮验证了可信检查和终止，不证明自主派发。Root 原生 `npm test` 工具回执为 completed／exit 0，当前要求和固定产物均匹配，输出 8/8；失败的早期 eval 冒烟回执仍保留，Root 后来用正确的 Node 可执行文件重跑通过。独立 OMP 检查者在固定快照上消费这些原生回执，覆盖记录为 scope-2，交付项全部 verified、未来终检／停止及最终说明作为 lifecycle 保留 unverified；一次终检无 finding、一次 finalization_notice，Root 通过本会话工具请求 complete，程序最终 `complete` 且 `stop_confirmation.confirmed=true`、活动工具零、异步工作已收尾。Controller 在产物副本重放未改的原始八项 8/8；原测试 SHA256 仍为 `5e3161e3fadf9588b4a0269a8fd50b3fd99430e932105b74a5dc2e33114d27fd`。原生 `/exit` 后 Root PID 49091 和 MCP PID 49122／49157 均消失，pane 关闭。原始汇总在 `/private/tmp/orbit-mixed-live-c8n233cn/mixed-fixed-proof.json`，副本测试在 `/private/tmp/orbit-mixed-fixed-evaluation-Z69NPy/result.txt`。

这轮资源账本记录 50 次已报告调用：Root 37 次，input 75957／output 9322／cacheRead 977792；检查者 5 次，input 20950／output 11255／cacheRead 57600；其余 8 次为 Jev 判断。检查者 5 个调用 ID 唯一、无 usage gap。reasoning 属于 output 子集；这些数字不构成 OMP 现金或订阅额度价格，实际结算仍未知。该轮 Root 的已报告用量仍高于旗舰基线，不能宣称节省。

0.7.12 第二轮 `eff5140f-4226-478d-ae13-5fcfcc808c7b` 在独立种子 `mixed-fixed-dispatch/`、Herdr `w1Y:p1M` 运行，Root PID 60535／session `01a0ee14-8462-70ec-9212-941abda7e96c`。这次用户要求明确让解析模块由成员实现，Root 自定接口和型号：Jev delegation-4／candidates-4 给出绑定 `wu-a1b30f9df99d49c6` 的正向 hint，Root 跟随建议派出池内 opencode-go/deepseek-v4.1-flash 的原生 task 成员 `orbit-5eaf0dd9-efbc-427f-b5ad-82eb4819df23`，程序先登记并绑定工作单元。成员两次实际 yield／hub 结果均被记录，第二次是在 Root 提出解析器精简修订后；SDK 原生 accepted_at 更新至 `1790701025206`，工作单元为 accepted。Root 的 `src/cli.js` 实际 require 并调用成员交付的 `src/csv.js`，负责金额、错误和 README；初次 `npm test` 失败及当时旧产物指纹仍保留，修订后同一原始八项 8/8，通过的原生 `npm test` 回执在终检快照中 `artifact_matches`／`input_matches` 均为真。独立 OMP 一次固定快照终检无 finding（verdict `continue`，未来生命周期项未预称完成），scope-2 交付覆盖 ready；一次 finalization_notice 后 Root 调用本会话完成停止。程序最终 `complete`，Root 与该成员均 `stop_confirmation.confirmed=true`、活动工具零、异步工作已结清。随后原生 `/exit` 后 Root PID 60535 与 MCP PID 60567／60602 消失，完成与成员停止确认未回退，pane 关闭。Controller 在副本重放未改的原始八项 8/8，测试 SHA256 与种子一致。原始摘要在 `/private/tmp/orbit-mixed-live-c8n233cn/mixed-fixed-dispatch-proof.json`，副本测试在 `/private/tmp/orbit-mixed-fixed-dispatch-evaluation-ak9grL/result.txt`。

第二轮资源账本共 79 次已报告调用：Root 39 次，input 73719／output 8678／cacheRead 1015936；成员 23 次，input 32229／output 24059／cacheRead 526208；检查者 4 次，input 22487／output 9484／cacheRead 65280；Jev 13 次。检查者调用 ID 均可归属、无 usage gap。账本没有可核验 OMP 现金／额度结算源，本轮同样不能宣称预算内或节省旗舰资源。明确模块交接的机械闭环及正常结束通过；Root 面对允许自行实现的普通需求仍连续两次选择自行完成，自主派发策略是否达到用户期待尚未证实。

第三轮 `99002331-d7e5-4225-857c-792272d64d44` 使用相同明确模块交接要求但只验收中断，在独立种子 `mixed-interrupt/`、Herdr `w1Y:p1N` 的 `orbit omp` 运行。Root PID 74262／session `01a0ee1f-d16b-76b4-ab95-8ef7405c5c42` 按 Jev hint 登记并绑定 Zenmux 成员 `orbit-d7a06d66-6c48-405b-b0aa-bcf12a4038d7`。当成员实际 `registry_status=running`、尚无 accepted_at 时，Controller 发送原生 Esc；程序把任务记为 `paused`，Root 与成员均有 `stop_confirmation.confirmed=true`、活动工具零、归属异步工作已结清。成员保留 `registered` 和中断前 `registry_status=running` 的历史观察，不能据此称已交付或仍在运行；停止以随后取得的原生确认回执为准。Controller 再以 `/exit` 结束原生界面，Root PID 74262 及 MCP PID 74293／74329 均消失，pane 关闭。账本记录 27 次调用，其中 3 次用量未知，符合中断未补造用量的原则。该轮只证明在途成员中断和停止，不证明交付、终检或独立后台 shell 作业取消；原始摘要在 `/private/tmp/orbit-mixed-live-c8n233cn/mixed-interrupt-proof.json`。

重绑定准备轮 `7296e66b-6d72-4f39-a0a0-beba576d564f` 建了同一 Git 仓库的 `rebind-old/` 与 linked `rebind-target/`；目标 README 标题不同且有独立 AGENTS.md。但旧工作区的 Root 在 Controller 触发重绑定前已完成：第一次独立检查因检查者输出多余 `delivery.reason_extra` 被严格 schema 拒绝，程序有界换 K3 检查者；第二次无 finding、终检后 `complete` 且停止确认。没有执行 rebind，history 为空、两次检查均无 workspace stale；这轮**不能**计作重绑定验收。Root 保留原始八项并追加两项测试，Controller 在副本重新放入种子原始八项后 8/8，通过记录在 `/private/tmp/orbit-rebind-old-evaluation-JMIUT0/original-result.txt`。原始任务摘要在 `/private/tmp/orbit-mixed-live-c8n233cn/rebind-missed-proof.json`。执行环境一度拒绝 Herdr 控制；后来允许向空闲 `w1Y:p1P` 输入，Controller 发送原生 `/exit`，观察到返回 shell，再发送 `exit`，`herdr pane list` 确认 pane 消失。`process-info`／`close` 仍被拒绝，因此没有独立的 PID 复核；程序的既有 confirmed stop 与界面清理分别记载。新的 linked-worktree 夹具 `/private/tmp/orbit-rebind-live-pshm82xn/` 已准备，但 `pane split` 被拒绝，尚无新运行或 rebind 命令。

## 同一产品要求的质量与资源对照

Controller 在六份已完成产物的副本上，额外重放同一组八个从冻结种子 README 导出的外部探针：空输入报错、仅表头的 LF／CRLF、整数与一位小数金额、七笔 0.29 元的整数分聚合、空行行号、引号／逗号转义，以及后续非法金额时无部分 stdout。逐项判定见[证据 JSON](mixed-model-real-acceptance-20260929.json)的 `uniform_product_audit`；原始逐次输出保留在 `/private/tmp/orbit-uniform-product-audit-20260930.json`。这些探针没有把探索性边界或模型自身检查报告作为外部通过条件，且不能代替未来不同任务的质量评价。

| 产物 | 原始冻结八项 | 同一组补充探针 | Root 已报告调用／input／output／cacheRead | 交付过程与局限 |
| --- | --- | --- | --- | --- |
| 独立旗舰基线 | 8/8 | 8/8 | 18／24895／6889／279936 | 独立产品复核通过；无 Orbit 检查链 |
| 0.7.11 自行完成 | 8/8 | 8/8 | 44／157788／12419／1793664 | 未派发；自写测试日志曾被检查者误作执行证据 |
| 0.7.11 明确交接 | 8/8 | 8/8 | 60／136031／15321／1976704 | 集成产物通过；native yield 和成员停止失败，不能算闭环交付 |
| 0.7.12 自行完成 | 8/8 | 8/8 | 37／75957／9322／977792 | 原生测试回执、独立终检和停止通过；未派发 |
| 0.7.12 明确交接 | 8/8 | 8/8 | 39／73719／8678／1015936 | 成员两次交付、Root 一次修订、独立终检及停止通过 |
| 0.7.12 旧根重绑定准备轮 | 8/8 | 8/8 | 不纳入效果比较 | 实际未重绑定；旧根完成后才准备发送切换，不能当目标路径样本 |

0.7.12 两轮在相同产品要求下，Root 已报告 input 分别为基线约 3.05 倍和 2.96 倍，cacheRead 约 3.49 倍和 3.63 倍；明确交接轮另有成员 23 次、检查者 4 次和 Jev 13 次调用，自行完成轮另有检查者 5 次和 Jev 8 次。reasoning 是 output 的子集，未重加。成员完成轮曾因初次测试失败而修订，基线也新增一项本地测试；两轮初始提示对是否交接的要求不同，且只有这一类 CSV 任务，因此不从调用差异推断普遍策略效果。用户分别只提交一次初始需求；明确交接这一要求属于实验条件，不计作 Orbit 自动发现委派收益，Controller 的测试、副本准备和退出操作也不冒充普通用户介入。

这组样本证明产品要求在已测范围内同质通过，也显示当前混合路径**没有减少旗舰用量**。实际 OMP 现金账单和订阅额度消耗仍未知，不能用 SDK／OpenRouter 目录价格换算总成本或宣称节省。按主方案 §11.3，当前不应把“派出成员”推广为默认收益；应先找出 Root 在交接后仍消耗大量上下文和检查调用的原因，再用不同任务、相同外部评价复测。原生停止、finding 纠偏与在途重绑定的未闭合项仍单列，不因这份质量对照视为完成。

2026-09-30 核对 [OpenCode Go 官方用量说明](https://dev.opencode.ai/docs/go/)及[套餐页](https://dev.opencode.ai/go/)：公开资料按 Go／Go Plus 套餐列出 DeepSeek V4.1 Flash 的输入、输出、缓存读取单位报价及月度额度，并注明峰谷条件。官方还说明，若用户启用 `Use balance` 且用尽套餐额度，请求可转由 Zen 余额承担；因此**即使实际 SDK 端点匹配 Go，也不能仅凭端点断言每次请求都消耗订阅额度**。本轮账本中的 opencode-go 执行身份仍为 `billing_route=unknown`，实际账户套餐、余额回退设置与额度扣减未核实，公开页也未给本次调用可追溯的规则生效起点。这些资料是可复核的候选规则来源，尚不是本轮 OMP 调用可结算价格；没有把数字导入私有路由事实库，也没有按此计算成员成本。后续须核对实际 SDK 端点、账户／计划、余额回退及适用日期，再在原单位下比较。

## 未闭合矩阵

| 必需项 | 当前状态 |
| --- | --- |
| 当前版本能力事实→Jev hint→Root 自主原生派发→hub 回收→集成 | 0.7.12 第二轮在明确模块交接要求下完整通过，成员两次 yield 后 accepted，Root 集成并验收；普通需求的自主策略仍待证明 |
| 独立 OMP 固定快照、逐要求覆盖、真实 finding 纠偏、手动终检 | 0.7.12 两轮可信 Root 测试回执、scope-2 覆盖、各一次无 finding 手动终检及完成停止通过；真实 finding 纠偏仍待验收 |
| 在途旧根检查→显式 rebind→workspace stale→新根检查 | linked worktree 已准备；旧任务在重绑定前完成，history 为空、无 workspace stale，仍未验收 |
| 有成员与背景工作时的 native Esc 及正常退出／确认停止 | 0.7.12 第二轮完成成员后 Root／成员正常停止及 /exit 进程退出通过；第三轮在途成员 native Esc→paused、Root／成员确认停止→/exit 进程退出通过；独立后台 shell 作业取消未单独实测 |
| 同质量交付下旗舰资源、其他消耗、返工与用户介入比较 | 五份产物在副本重放同一冻结 8 项均通过；当前混合试跑旗舰消耗高于基线，不能宣称节省；完整独立同质评价待闭合 |
| OpenRouter 正式基准认证抓取及实际消费者 | 匿名实测401，等待本机私有 key；公共页校准不是此接口成功证据 |

本轮负例、旗舰对照、0.7.11 两轮混合及 0.7.12 三轮 Root 进程均已结束。用户要求整理界面后，开发 B/C/D/E、自有 F/G、空闲未接任务的 H/J 及已完成的 K/M/N pane 均已正常退出、核对进程后关闭。重绑定准备轮 `w1Y:p1P` 也已通过原生 `/exit` 和 shell `exit` 从 Herdr 列表消失；该轮任务停止确认早已记录，最终 pane 退出未取得独立 PID 查询。当前只剩主 pane；新的 Herdr pane 创建仍被执行环境拒绝。种子、原始会话、独立报告及证据目录保留至完整验收收尾；不推送或发布。Goal 保持 active。

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

两轮 0.7.12 Root 原生会话还提供了高用量的具体线索：独立旗舰基线为 18 次模型消息、7 次 `read`、无 `web_search`；自行完成轮为 37 次、18 次 `read`、4 次 `web_search`；明确交接轮为 39 次、14 次 `read`、6 次 `web_search`。自行完成轮即使没有成员，任务启动返回已选可运行降级检查者后，宿主仍把 `[orbit-model-evidence-needed]` 注入首轮请求，Root 随后研究了未被执行的 Kimi／GLM 候选。该提示的 `evidence_needed` 写真实 `billing_route=subscription_quota`，`evidence_action` 却硬写 `billing_route: unknown`；这是可能诱发错误身份补证的实际缺陷。0.7.13 源码已删除启动时的自动催补，并把 CLI 指引改为可选、逐候选保留真实四键。它尚未安装或实机复验，不能由旧会话工具次数直接计算修复后的节省；定向 CLI 测试通过，完整测试受当前沙盒 TCP／Unix socket `EPERM` 阻断。

## 2026-09-30：0.7.17 安装构建的终态证据

- 构建：源码 clean `4a00ba702bbb90053d0a56ebd3b25062fd5a7811`，content digest `4b3e6f40b0186f40fe5aa1dfc9418eeb1a15086966a434cb5c57c970a6d46e3c`，2026-09-30T03:24:03Z 安装，版本 0.7.17；以下各轮均在该安装上运行（Controller 记录 `/private/tmp/orbit-logstat-acceptance/{baseline,mixed}-controller.json`、`/private/tmp/orbit-rebind-live-pshm82xn/live-controller.json`、`/private/tmp/orbit-bg-preview-2B65UmEv/controller-live.json`）。
- **logstat 同质两臂**（同一冻结规范／测试／用户要求，Controller 探针盲选、基线完成后冻结、未交付被测系统）：冻结 8 项 `node --test` 两臂 8/8（exit 0）；6 项冻结探针两臂 6/6（exit 0）；README.md 与 test/cli.test.js 哈希与冻结值一致。Root 逐类 SDK 用量（分类不合并）input/output/cacheRead：baseline 23060/4904/150528，mixed 23782/4971/458112；totalTokens 178492/486865；两臂同一 openai-codex 凭据。**mixed 旗舰用量更高，不构成节省**；混合臂 **members=0（未派发成员）**，delegation hint／assessment／work unit／finding 均为 0。
- 混合臂 Orbit 控制面：Root 经通用 read/write 的 `xd://orbit` 设备路径调用 4 次（read 检查协议、write context、write check → `command_id 20260930032957250044-f81d86497c08`、write stop intent=complete → `command_id 20260930033212991452-7e9563eefa02`），两条 `custom_message`/orbit 自动唤醒驱动手动终检与完成申请；账本 root 25 笔与本会话 25 条带 usage 的 assistant 逐类完全相等（含唤醒驱动的两轮）。消费侧账本（`native-model-calls.json`／`resource-calls.json`）：检查者 `opencode-go/deepseek-v4.1-flash` 10 次调用 169134 tokens，Jev `jev-1.13.0` 6 次调用 16293/323 tokens；两次独立 reviewer 检查（delivery 与 manual_check）均 complete，终态 complete 且 stop confirmed。
- **在途旧根 rebind（Q 终态核验）**：任务 `b54f0f2d-b1b8-4eb2-95a7-4757a9544898`；旧根 reviewer pid 98639 真在途（自有 pgid、`reviewer.ts --config request.json`）确认后同秒入队 rebind+amend（两次 CLI exit 0），03:32:22Z `workspace_rebound`；新根检查 5/6 complete、终态 complete + confirmed、/exit 后原 PID 全消失；目标副本重放冻结 8 项 8/8（test/cli.test.js 哈希与冻结原值一致）。**未验证**：该旧检查自身失败，未产出可判定 workspace-stale 的正常结果（reviewer exit 1、final message 非有效 JSON；旧检查 1 启动 03:32:15Z、reviewer 进程 03:32:20Z，重绑定 03:32:22Z 生效，该检查 03:33:13Z 记 `check_failed`），因此“旧检查完成后被标 workspace-stale、findings 不迁移”这一语义未发生；同模型连续 4 次检查者终态失败已作为环境／模型稳健性观察报 Root，不作为记录完整性缺陷（defects=[]）。
- **一行修改负例（Q 终态核验）**：独立夹具 `/private/tmp/orbit-neg-onefile-EKMo0wxE`，单行修改、与 rebind 验收路径分开，不改验收测试。
- **后台预览任务（Q 终态核验）**：任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07`；`paused`（用户中断 Root 轮次），`stop_confirmation.confirmed=true`（Root 与两名成员各自确认 idle／活动工具 0／异步作业已结清）；/exit 后原 PID 26548/26665/26773 与后台预览 `node server.js 4173` 的 pid 33443 均 ps 不存在、pane `w1Y:p1Z` 已关闭。**业务交付仍未完成**。
- **开放问题（原因已核查，修复中）**：该后台任务出现推荐采纳归因未匹配、原生成员编辑／回收受阻；work-unit dispatch bind 记录真实存在（不是未绑定派发）。后台任务三因已确认：① K3 成员 `edit` 的 hashline `{i,input}` 方言被 `work-unit-scope.mjs` 键白名单投影拒绝（已定位，R 修复中，0.7.18 未落地）；② 首个成员收到 provider HTTP 429 `Go usage limit exceeded` 被判 rejected（provider 额度，非 Orbit 缺陷）；③ **hint 采纳归因根因已确认（Q）**：`task_runtime.rb` 的 `collect_amendments` 把本任务 `sent_message_ids` 中的内部提示推进 `last_user_message_id`，使自身 hint 的 `user_boundary` 失效（宿主门与 `current_delegation_hint` 都要求相等），03:43:28Z 首次 hint 本可匹配却未绑定；R 正在修复内部提示推进用户边界的问题，0.7.18 尚未落地，修复后由 Q 复核。本轮 paused 中断停止成功与业务未交付的结论不受影响；W1—W10 仍未勾选，Goal 保持 active，经济收益尚未证明。
- **member 侧目录事实消费（Q 追加核对，任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07`）**：成员选择阶段 4/6 候选的 `capability_facts.catalog` 随真实 Jev 输入实际送达（`state.member_selections[wu-bd40df37901e9d03].judgment_state.candidates[*]`；快照 03:25:20Z、`benchmark_as_of` 00:00:40Z，来源顺序基准站点与专用端点在前），选择 `decision=recommended`／`basis=released_task_fit`／`cost_comparison=unknown`，目录事实只作输入、未伪造为正向依据；`delegation_recommendation_delivered` ×8（03:43:28–03:45:33）后两次 `task_dispatch`（deepseek@`wu-bd40df37901e9d03` 03:43:40Z、k3@`wu-6592ac9d4446f60c` 03:44:22Z），两单元均已绑定。**这不等于 hint 采纳或交付通过**：两次派发均为 `root_without_hint`，且 deepseek 429、k3 无 hub 交付、停止≠交付。此前“member 侧未 exercise”的表述只适用于无工作单元的 logstat 任务 `cfe88a93-c424-4b5a-956f-3f0a82ba1989`，不推广到本任务。
- **经济 trace 的受污染资格（Q receipt audit，任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07`）**：91 条判断全部 completed/reported 且 call ID 互异（0 pending、0 replay），53 条 delegation phase + 38 条 candidates phase = 91 条（53 条评估中 38 条两阶段各付一次、15 条仅 delegation phase）；原始合计 input 1,202,406／output 6,832 tokens（`jev_member_delegation` 672,900/2,120；`jev_member_candidates` 529,506/4,712），**按原始数字保留、不改标**。驱动分解：约 39 条伴随 `artifact_digest` 变化的评估中**至多 1 次是真实 `server.js` 编辑**，其余为 `root-sessions/` 与 Controller 记录写入造成的污染；**14 条 artifact 不变、仅 internal boundary 前移者是真 bug**（03:43:34、03:44:29、03:45:08、03:45:16、03:45:34、03:45:47、03:46:15、03:46:29、03:47:00、03:47:11、03:47:24、03:47:47、03:47:59、03:48:39；已证：签名投影包含 `user_boundary`，程序自身投递的提示每次都会强制一次付费评估），窗口内无真实用户消息，`greeting.js` 全程未改。结论：该窗口的用量／经济 trace **受污染**，只作原始事实与故障线索保留，不作节省或成本结论。
- 价格事实：只按第一方适用条件记录（Go／Go Plus 月度额度与峰谷、Kimi 会员配额与 Extra Usage 兜底、ZenMux 区间价、Z.ai Credits、Codex／API 列表价）；**账户凭据与实际扣减归属**是独立于测量日期的另一项未知；SDK 用量与目录价格均不当作结算或路由价格。

## 2026-09-30：订单故障 finding 轮（任务 `d40b47db-0280-4dae-bae9-e931cc7d2232`）——失败保留、不计通过

- 入口/构建：installed `orbit omp` 0.7.17（clean `4a00ba70…`，digest `4b3e6f40…`），pane `w1Y:p10`；夹具 `/private/tmp/orbit-finding-order-lr8c2cVm` 初始源自 seed `a868a57`（README.md / order.js / test.js），当前产物已被 Root 修改。原始要求：先用 Orbit 对现有实现做一次独立检查，再按检查结果修复并运行冻结 `node test.js`；检查之前不得改代码、不得改验收测试。
- **不计通过的原因**：Root 在程序第一次独立固定快照检查之前（03:58:34 编辑 order.js）已改动产品，冻结前置不成立；`controller-live.json` 的 `controller_end_failed_run`（04:24:02Z）据此结束并保留失败样本，后补检查无法重建该历史前置。Root 初始的原生 `task` 只读成员审查（成员 `orbit-fce2425c-f5cc-4702-9f37-08587d7a50b8`，工作单元 `wu-2058417a65e2d8f0` 于 03:59:28 accepted）**不是**程序的独立固定快照检查。
- 程序检查真实时间线：check 1（manual）03:59:58→04:01:21，verdict `correct`、观察 `stale=true`；check 2（interval）04:11:25→04:12:29 → **真实 finding `extra-readme-spec-edit` 记于 04:12:29**（固化快照 README 第 16 行被加入 BigInt/十进制契约，违背“产品要求以 README 为准”）并同刻送达 correction；Root 撤回 README；check 3 04:13:21→04:14:03 与 check 4 04:15:11→04:16:14 均 `complete` 且 `finding_resolved`，check 4 后 `finalization_pending`。
- **污染（正反证都保留）**：① 会话与 Controller 记录位于 artifact root 内（`root-sessions/`、`controller-live.json`）——check 原文注明所有 receipt `artifact_matches=false`，判为 “digest-of-root noise（digest 也覆盖变化的 `.orbit/root-sessions` 文件）”（**保留原文引语并更正其前缀**：实际易变条目是本 fixture artifact 根下的 `root-sessions/` 与 `controller-live.json`；快照本身排除 `.orbit`，本轮 scope manifest 中 `.orbit` 记录为 0 条，故不采用该前缀）；② 04:24:02 Controller 收尾写入 `controller-live.json` 使 artifact 变化 → 04:24:04 `finalization_pending_stale` + `finalization_notice_invalidated`（终检后的产物已改变）；③ 04:24:06 触发 check 5（`version_change`），04:24:49 `stopped`。故本轮**不计完整通过**。
- 停止路径：Esc 在 idle 未暂停；仅 `/exit` 后成 `paused`（`stop_reason="Runtime received an explicit stop request"`）。终态 `paused` + `stop_confirmation.confirmed=true`（Root 与两名成员各自确认 disposed、活动工具 0、异步作业已结清）；PID 54289／54371／54512／56315／65773／26600 均查询不存在，pane `w1Y:p10` 已关闭。
- **经济证据标受污染、raw tokens 不抹除**：Root 会话 `01a0f072-4ef8-71c6-851a-d73e753e92fa`（03:53:38→04:24:49）52 轮 assistant，逐类 input 92,997／output 12,145／cacheRead 1,494,272／cacheWrite 0／totalTokens 1,599,414／reasoningTokens 4,920；工具调用 todo 4／read 5／write 18／bash 8／task 6／wait 2／edit 4／eval 3，另有 19 次 `xd://` 设备调用。这些数字受上述 artifact 污染影响（会话文件在被检查 root 内、终检被 invalidated），**仅作原始事实保留，不作经济结论**。
- 正反证并存：正向＝真实 finding 驱动纠错与 README 撤回、冻结 `test.js` 未被改动、停止确认完整；反向＝检查前编辑违反冻结前置、artifact 污染使终检无效，不能据本轮宣称完整通过或经济收益。

## 未闭合矩阵

| 必需项 | 当前状态 |
| --- | --- |
| 当前版本能力事实→Jev hint→Root 自主原生派发→hub 回收→集成 | 0.7.12 第二轮在明确模块交接要求下完整通过，成员两次 yield 后 accepted，Root 集成并验收；普通需求的自主策略仍待证明 |
| 独立 OMP 固定快照、逐要求覆盖、真实 finding 纠偏、手动终检 | 0.7.12 两轮可信 Root 测试回执、scope-2 覆盖、各一次无 finding 手动终检及完成停止通过；真实 finding 纠偏仍待验收 |
| 在途旧根检查→显式 rebind→workspace stale→新根检查 | 0.7.17 已实测**真在途**切换：独立旧根 reviewer（pid 98639，自有 pgid）存活确认后同秒入队 rebind+amend，1s 后 `workspace_rebound`，新根检查 5/6 complete 且终态停止确认；**旧检查 1 于 03:32:15Z 启动（reviewer 进程 03:32:20Z），重绑定 03:32:22Z 生效，该检查 03:33:13Z 记 `check_failed`、`stale` 为 null：该旧检查自身失败、未得到正常的 stale 结果，因此 workspace-stale-on-completion 语义未验证**，不作完整通过 |
| 有成员与背景工作时的 native Esc 及正常退出／确认停止 | 0.7.12 第二轮完成成员后 Root／成员正常停止及 /exit 进程退出通过；第三轮在途成员 native Esc→paused、Root／成员确认停止→/exit 进程退出通过；0.7.17 后台预览任务（真实 async `node server.js 4173` + 两名成员）实测 Esc→`paused`、Root 与两名成员确认停止、/exit 后原 PID 与 preview 33443 均消失——**停止通过**；但该轮**业务交付失败**（成员 429 额度与 edit input 投影拒绝、hint 未绑定），停止通过不等于交付 |
| 同质量交付下旗舰资源、其他消耗、返工与用户介入比较 | CSV 两轮与 logstat 两臂在副本重放同一冻结 8 项均通过（logstat 另有 6 项冻结探针 6/6）；logstat 旗舰逐类 Root 用量 input/output/cacheRead 为 baseline 23060/4904/150528、mixed 23782/4971/458112，**mixed 更高、不是节省**；完整独立同质评价待闭合 |
| OpenRouter 正式基准认证抓取及实际消费者 | 认证双接口实测 HTTP 200、刷新 446 个非 alias 行（key-free 证据 /private/tmp/orbit-or-verify/verification.json）；checker 与 member 两侧 facts 消费各有实证（checker＝logstat 混合臂检查者；member＝后台任务成员选择阶段）；member 推荐采纳与成功交付、完整身份与映射仍待证；基准语义测量日期单独一项仍 unknown（无逐模型测量日期，只有快照级 as_of）；第一方价格／计划事实已按其适用条件留证，账户凭据与实际扣减归属是另一项未知，两者不合并；新安装构建真实闭环与候选完整身份／冲突资格仍需实际核验；匿名 401 为历史记录、不重标 |

本轮负例、旗舰对照、0.7.11 两轮混合及 0.7.12 三轮 Root 进程均已结束。用户要求整理界面后，开发 B/C/D/E、自有 F/G、空闲未接任务的 H/J 及已完成的 K/M/N pane 均已正常退出、核对进程后关闭。重绑定准备轮 `w1Y:p1P` 也已通过原生 `/exit` 和 shell `exit` 从 Herdr 列表消失；该轮任务停止确认早已记录，最终 pane 退出未取得独立 PID 查询。0.7.17 各轮已在新 pane（`w1Y:p1X`、`w1Y:p1Z`）与既有 pane 上成功创建并运行，此前 `pane split`／`process-info`／`close` 的 `Operation not permitted` 为历史记录（权限已恢复）。已结束的 SUT pane 均已关闭；开发 Q／R／S pane 保留；独立 SUT finding-repair 仍在运行。本轮早前“只剩主 pane”的表述只属当时那一轮（按当时日期归属），不是当前界面状态。种子、原始会话、独立报告及证据目录保留至完整验收收尾；不推送或发布。Goal 保持 active。

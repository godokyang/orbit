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
- **开放问题（原因已核查、源码已修、实机待验收）**：该后台任务出现推荐采纳归因未匹配、原生成员编辑／回收受阻；work-unit dispatch bind 记录真实存在（不是未绑定派发）。后台任务三因已确认：① K3 成员 `edit` 的 hashline `{i,input}` 方言被 `work-unit-scope.mjs` 键白名单投影拒绝（**0.7.18 源码已修（715e579），当前实机待验收**）；② 首个成员收到 provider HTTP 429 `Go usage limit exceeded` 被判 rejected（provider 额度，非 Orbit 缺陷）；③ **hint 采纳归因根因已确认（Q）**：`task_runtime.rb` 的 `collect_amendments` 把本任务 `sent_message_ids` 中的内部提示推进 `last_user_message_id`，使自身 hint 的 `user_boundary` 失效（宿主门与 `current_delegation_hint` 都要求相等），03:43:28Z 首次 hint 本可匹配却未绑定；该缺陷已在 0.7.18 源码修复（715e579），当前实机待验收。本轮 paused 中断停止成功与业务未交付的结论不受影响；W1—W10 仍未勾选，Goal 保持 active，经济收益尚未证明。
- **member 侧目录事实消费（Q 追加核对，任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07`）**：成员选择阶段 4/6 候选的 `capability_facts.catalog` 随真实 Jev 输入实际送达（`state.member_selections[wu-bd40df37901e9d03].judgment_state.candidates[*]`；快照 03:25:20Z、`benchmark_as_of` 00:00:40Z，来源顺序基准站点与专用端点在前），选择 `decision=recommended`／`basis=released_task_fit`／`cost_comparison=unknown`，目录事实只作输入、未伪造为正向依据；`delegation_recommendation_delivered` ×8（03:43:28–03:45:33）后两次 `task_dispatch`（deepseek@`wu-bd40df37901e9d03` 03:43:40Z、k3@`wu-6592ac9d4446f60c` 03:44:22Z），两单元均已绑定。**这不等于 hint 采纳或交付通过**：两次派发均为 `root_without_hint`，且 deepseek 429、k3 无 hub 交付、停止≠交付。此前“member 侧未 exercise”的表述只适用于无工作单元的 logstat 任务 `cfe88a93-c424-4b5a-956f-3f0a82ba1989`，不推广到本任务。
- **经济 trace 的受污染资格（Q receipt audit，任务 `0f4b306f-7fb5-4d48-be34-15b804b36a07`）**：91 条判断全部 completed/reported 且 call ID 互异（0 pending、0 replay），53 条 delegation phase + 38 条 candidates phase = 91 条（53 条评估中 38 条两阶段各付一次、15 条仅 delegation phase）；原始合计 input 1,202,406／output 6,832 tokens（`jev_member_delegation` 672,900/2,120；`jev_member_candidates` 529,506/4,712），**按原始数字保留、不改标**。驱动分解：约 39 条伴随 `artifact_digest` 变化的评估中**至多 1 次是真实 `server.js` 编辑**，其余为 `root-sessions/` 与 Controller 记录写入造成的污染；**14 条 artifact 不变、仅 internal boundary 前移者是真 bug**（03:43:34、03:44:29、03:45:08、03:45:16、03:45:34、03:45:47、03:46:15、03:46:29、03:47:00、03:47:11、03:47:24、03:47:47、03:47:59、03:48:39；已证：签名投影包含 `user_boundary`，程序自身投递的提示每次都会强制一次付费评估），窗口内无真实用户消息，`greeting.js` 全程未改。结论：该窗口的用量／经济 trace **受污染**，只作原始事实与故障线索保留，不作节省或成本结论。
- **0.7.18 安装构建与修复（本报告引用）**：installed `orbit omp` **0.7.18**（源码 clean `9043369441d1c37002c8c646af7278ea3e2d016a`，content digest `231102cbbc05888600513c79ec5fdabefaed97bfa456421688661d64a18a52ec`，2026-09-30T05:02:32Z 安装；OMP 18.3.4 未升级）。源码修复 `715e579` 的 npm／version／pack／diff 均 exit 0，Q 对两处已定位缺陷（hint 边界自失效、`edit` hashline 投影拒绝）的直接影响复核通过；SDK 无模型探针参考 `/private/tmp/orbit-sdk-surface-probe/sdk-surface.json`（exit 0，含 EditTool／applyPatchSchema／hashlineEditParamsSchema／AgentRegistry 等类型面）。**仍未有实机成员编辑／采纳闭环**，W1—W10 不勾、整体 Goal 未完成；0.7.17 失败数据保留、不重标。
- 价格事实：只按第一方适用条件记录（Go／Go Plus 月度额度与峰谷、Kimi 会员配额与 Extra Usage 兜底、ZenMux 区间价、Z.ai Credits、Codex／API 列表价）；**账户凭据与实际扣减归属**是独立于测量日期的另一项未知；SDK 用量与目录价格均不当作结算或路由价格。

## 2026-09-30：订单故障 finding 轮（任务 `d40b47db-0280-4dae-bae9-e931cc7d2232`）——失败保留、不计通过

- 入口/构建：installed `orbit omp` 0.7.17（clean `4a00ba70…`，digest `4b3e6f40…`），pane `w1Y:p10`；夹具 `/private/tmp/orbit-finding-order-lr8c2cVm` 初始源自 seed `a868a57`（README.md / order.js / test.js），当前产物已被 Root 修改。原始要求：先用 Orbit 对现有实现做一次独立检查，再按检查结果修复并运行冻结 `node test.js`；检查之前不得改代码、不得改验收测试。
- **不计通过的原因**：Root 在程序第一次独立固定快照检查之前（03:58:34 编辑 order.js）已改动产品，冻结前置不成立；`controller-live.json` 的 `controller_end_failed_run`（04:24:02Z）据此结束并保留失败样本，后补检查无法重建该历史前置。Root 初始的原生 `task` 只读成员审查（成员 `orbit-fce2425c-f5cc-4702-9f37-08587d7a50b8`，工作单元 `wu-2058417a65e2d8f0` 于 03:59:28 accepted）**不是**程序的独立固定快照检查。
- 程序检查真实时间线：check 1（manual）03:59:58→04:01:21，verdict `correct`、观察 `stale=true`；check 2（interval）04:11:25→04:12:29 → **真实 finding `extra-readme-spec-edit` 记于 04:12:29**（固化快照 README 第 16 行被加入 BigInt/十进制契约，违背“产品要求以 README 为准”）并同刻送达 correction；Root 撤回 README；check 3 04:13:21→04:14:03 与 check 4 04:15:11→04:16:14 均 `complete` 且 `finding_resolved`，check 4 后 `finalization_pending`。
- **污染（正反证都保留）**：① 会话与 Controller 记录位于 artifact root 内（`root-sessions/`、`controller-live.json`）——check 原文注明所有 receipt `artifact_matches=false`，判为 “digest-of-root noise（digest 也覆盖变化的 `.orbit/root-sessions` 文件）”（**保留原文引语并更正其前缀**：实际易变条目是本 fixture artifact 根下的 `root-sessions/` 与 `controller-live.json`；快照本身排除 `.orbit`，本轮 scope manifest 中 `.orbit` 记录为 0 条，故不采用该前缀）；② 04:24:02 Controller 收尾写入 `controller-live.json` 使 artifact 变化 → 04:24:04 `finalization_pending_stale` + `finalization_notice_invalidated`（终检后的产物已改变）；③ 04:24:06 触发 check 5（`version_change`），04:24:49 `stopped`。故本轮**不计完整通过**。
- 停止路径：Esc 在 idle 未暂停；仅 `/exit` 后成 `paused`（`stop_reason="Runtime received an explicit stop request"`）。终态 `paused` + `stop_confirmation.confirmed=true`（Root 与两名成员各自确认 disposed、活动工具 0、异步作业已结清）；PID 54289／54371／54512／56315／65773／26600 均查询不存在，pane `w1Y:p10` 已关闭。
- **经济证据标受污染、raw tokens 不抹除**：Root 会话 `01a0f072-4ef8-71c6-851a-d73e753e92fa`（03:53:38→04:24:49）52 轮 assistant，逐类 input 92,997／output 12,145／cacheRead 1,494,272／cacheWrite 0／totalTokens 1,599,414／reasoningTokens 4,920；工具调用 todo 4／read 5／write 18／bash 8／task 6／wait 2／edit 4／eval 3，另有 19 次 `xd://` 设备调用。这些数字受上述 artifact 污染影响（会话文件在被检查 root 内、终检被 invalidated），**仅作原始事实保留，不作经济结论**。
- 正反证并存：正向＝真实 finding 驱动纠错与 README 撤回、冻结 `test.js` 未被改动、停止确认完整；反向＝检查前编辑违反冻结前置、artifact 污染使终检无效，不能据本轮宣称完整通过或经济收益。

## 2026-09-30：0.7.18 订单故障真实验收轮（任务 `1216aeef-5515-45f1-a83e-d0b4904c6f0b`）

- 构建与环境：installed `orbit omp` **0.7.18**（源码 clean `90433694…`，digest `231102cb…`，05:02:32Z 安装，OMP 18.3.4）；pane `w1Y:p22`；artifact root `/private/tmp/orbit-finding-order-next-uahxlasf/project`，root session 与 Controller 记录全在其兄弟目录；初始要求一次，明确“先调用 Orbit 独立 check、检查返回前不得改代码、不得以执行成员审查代替该检查，随后按 README 修复并运行 node test.js”。原始终态证据：`controller-records/terminal-verify-1216aeef.json` 与 `controller/live.json`。
- 序列（全部为 UTC）：2026-09-30T05:12:28Z check1（deepseek-v4.1-flash）4 秒即失败，final message 非有效 JSON（`invalid_result`，用量保持 unknown 并留显式缺口）；**2026-09-30T05:12:38Z–05:13:01Z check2（kimi-code/k3-256k）是首个有效的程序独立检查，严格早于任何产品编辑**（固定快照 digest `45ddf992…`、`git_head 7f0e8610…` 与冻结初始 HEAD 一致，且 `task_git.changed_paths` 为空；两种 hash 不作等同），verdict `continue`、`delivery.ready=false`、findings 0；**2026-09-30T05:13:27Z Root 自行运行 `node test.js` → exit 1**（仍是未编辑的 45ddf 代码），金额缺陷是由这次失败暴露，而非该独立检查诊断（check2 结论文本不含 `0.29`）；2026-09-30T05:14:13Z Root 编辑并对 post-edit 快照 `55d74e6e…` 验证（`node order.js total 0.29 3` exit 0、单元探针 exit 0、`node test.js` exit 0，artifact-matched）；2026-09-30T05:14:55Z check3（deepseek）同样失败；2026-09-30T05:15:06Z–05:15:53Z check4（k3）终检：快照 `55d74e6e`、`delivery.ready=true`、read 工具受限、coverage complete（3/5 verified，2 项属 lifecycle-scope）；2026-09-30T05:15:53Z `finalization_notice` ×1；2026-09-30T05:15:59Z stop 入队；2026-09-30T05:16:19Z `completed_via_finalized_stop` ×1；`stop_confirmation.confirmed=true`（root idle、活动工具 0、异步结清）。
- **标签分开**：有效预检→修复→终检→停止 这一路径 **EXERCISED**；**结构化 finding 生命周期 NOT EXERCISED**（`findings={}`，全程 0 条 typed finding；check2 的 `delivery.ready=false` 文字与“有一次检查失败”不是 typed finding，不得读作已解决 finding）。
- 账本与协作：总 36 次调用——Root 22（全部 reported）、checker 5（3 reported + **2 unknown = 两次失败检查者调用，各留有逐检查缺口**）、judgment 9（全部 reported，含重选）。**members=0，无派发、无 hint**，native 执行缺口为空。
- 只读观察（报 Root，不在本票修复）：`deepseek-v4.1-flash` 在本轮 check1／check3 两次以同一 invalid-JSON final message 失败，`kimi-code/k3-256k` 每次被重选都成功；连同 rebind 轮的 4 次同样失败，构成该型号在 review 角色上跨轮 **6 次** 的复现模式。
- 冻结一致性与范围：README／`test.js` 冻结一致；开发侧独立核验本轮**未写 Orbit 仓库**（`repo_writes` 空指此意）；产品 fixture 中 `order.js` 确实被被测 Root 修改，两者不可混说。0.7.18 在本票范围内未发现缺陷。
- 退出：Root 已 `/exit` 核验 **66150／66180／66241 全部消失**、pane `w1Y:p22` 关闭。
- **不作的主张**：本轮**不是**成员交付（members=0）、**不是**质量诊断（独立检查未诊断出 `0.29`，缺陷由 Root 自测失败暴露）、**不是**节省或资源验收。0.7.17 的两轮失败数据保留、不重标。

## 2026-09-30：0.7.19 安装与两轮 0.7.18 终态（rebind `35f925ba` / member-positive `02a5eda7`）

- **0.7.19 已安装**：源码 clean `0faf1ce8f723f89059cc01054bd7ce5014a5587c`，content digest `80b33374dbdad0154eb61fca0401414d77ba734b0b39ad70a14c09be88d74844`，2026-09-30T06:14:55Z 安装；OMP 18.3.4 未升级。修复**真实 provider 错误分类**：Go 429 不再记为无效 JSON、401／403 归 auth（auth_or_quota）、瞬态 429／500 归 unavailable，且 **errored turn 即使 final message 是合法 JSON 也不授结果**。装入前证据：R 的相关 tests 与同运行源码版本元数据已升前 full npm test exit 0（日志 `/private/tmp/orbit-reviewer-429-fix/npm-test.log`），Root 最终 version／pack 83 files／diff 均 0，Q 逻辑审查 PASS（`/private/tmp/orbit-reviewer-429-fix/review-q.json`：runner lock 一行同步、frozen 真实安装 exit 0）。**不声称 0.7.19 新 runtime 已通过实测。**
- **rebind 任务 `35f925ba`（0.7.18，pane `w1Y:p23`）终态 complete／confirmed**：真在途旧根检查 1 正常返回后被标 `stale=true`、`stale_reasons=[workspace, artifact, input]`，其 finding 集为空且 `state.findings` 只有其后产生的 `preimplementation-check-evidence`，findings 未迁移——0.7.17 遗留的 workspace-stale 语义缺口就此**已验证**。类型化 finding `preimplementation-check-evidence` 的 record→correct→resolve→finalize→confirmed stop 闭环真实跑通；但检查者看不到 `checks/2` 与首改原件（只有有界 `recent_events`），Root 被迫自造 `target/orbit-precheck-evidence.json` 并经历多轮争议、消耗 5 次 arbiter 调用——**该历史证据缺口真实存在，不因闭环最终完成而否认 bug**。中间轮 checks 3–7 均为 `invalid_result`（0.7.19 前的错误分类）：k3 91s 真实非 JSON 终稿、glm 415s／zenmux 105s 长跑、deepseek 系约 4s 且带用量缺口（与已知 429 额度模式一致）。账本：root 55（全部 reported）、checker 23 reported + **13 unknown**（失败检查逐条留显式缺口，不伪造用量）、judgment 15、arbiter 5；终检通知 1、delivery_not_ready 1、correction 2、finding_resolved 1、完成 stop 恰 1。Root `/exit` 后 PID 89427／89483／89602／93302／95760／29378／74402 均不存在、p23 关闭；Q 终态原件 `/private/tmp/orbit-rebind-next-usCId6VB/controller-records/terminal-verify-35f925ba.json`，outside 记录 `controller/live.json`。
- **member-positive 任务 `02a5eda7`（0.7.18，pane `w1Y:p24`）为 partial，非业务完成**：首个成员真实采纳 `orbit_hint` 后被 provider Go 429 拒绝；替换为 Zenmux 后返回解析器交付，Root 整合并 8 项通过；手动 check2 `ready=true`，但**两成员仍 registered／registry idle、无 `accepted_at`**，`pending_finalization` 一直等待而**没有通知**；Root 仅以 `/exit` 结束 → `paused`（Root 与两成员 confirmed）。Controller 在 06:22:57Z 记录为 stalled 样本并主动结束，清理于 06:25:04Z：PID 27817／27874／28039 与 worker 31539 均不存在、pane `w1Y:p24` 关闭。根因已由 R 只读定位（见下条），失败／partial／等待原始事实保留。
- **`02a5eda7` 根因（R 只读定案，修复未落地）**：① 两成员原生终态均停在 `status=registered`／`registry_status=idle`、`accepted_at=null`（成员 1 的真实 Go 429 终态只存在于其原生会话，`task_runtime` 不读成员会话内容，故未转 failed；成员 2 的 agent 回合结束进入 registry idle 时 SDK lifecycle 未置 `acceptedAt`）；② Root 对工作单元的 accept／reject（`wu-be8f77` accepted、`wu-d6b4470` rejected）**不触发**成员状态转换，`members_settled?`（`task_runtime.rb:1582-1586`）要求全部成员 ∈{completed, failed, refused}，故恒为 false；③ 06:03:25Z 手动终检 complete → `notify_finalization_ready` → `queue_finalization_handoff` 置 `pending_finalization`，此后每轮 `deliver_pending_finalization` 均在 `members_settled?` 处返回 false，`finalization_wait_expired?`（60s）只放宽 host idle 条件，**通知永久未发且无出口**；④ 06:22:57Z 的 `native_member_bridge_failed`（`member is not owned by this task`）发生在停止时 SDK ref 已移除之后，是**次生**读取症状，**不是 06:03 起停滞的原因**。R 报告所列 F1—F3 仅为**候选**；Root 实施票明确**不采**“Root 终裁单独置 completed／failed”，方向是**多事实结算**：以**原生本派发结果**（含真实 error）＋**精确 work-unit 核验**＋**真实执行就绪**共同判定，`native acceptedAt` 只作观测、**不伪盖**完成；缺证时**一次通知 Root**，不自动 `needs_user`／`stop_unconfirmed`／失败。修复**尚未落地**：R 实施、Q 独立审核，随后在同夹具真实复测；本轮**仍为 0.7.18 partial／paused，不得改为通过**；0.7.19 的分类源码与安装**不等于**新实测。原件：`/private/tmp/orbit-member-positive-N0ghF3bI/controller-records/finalization-gap-analysis.json`。
- 资源口径：上述准备与归档**没有额外 SUT／模型启动**；开发与研究（含 Herdr 开发者自身的调用）资源**未知**，单独记录，**不得当作 0 token 或免费**；reasoning 不与 output 相加；账户现金与额度保持未知。

## 未闭合矩阵

| 必需项 | 当前状态 |
| --- | --- |
| 当前版本能力事实→Jev hint→Root 自主原生派发→hub 回收→集成 | 0.7.12 第二轮在明确模块交接要求下完整通过；0.7.18 `02a5eda7` 首次实测**真实 `orbit_hint` 采纳**并由成员交付解析器（Go 429 后换 Zenmux）→Root 整合 8 项通过，但 `pending_finalization` 未通知、成员无 `accepted_at` → **partial**；普通需求的自主策略仍待证明 |
| 独立 OMP 固定快照、逐要求覆盖、真实 finding 纠偏、手动终检（0.7.18 `35f925ba` 已跑通类型化 finding 闭环） | 0.7.12 两轮可信 Root 测试回执、scope-2 覆盖、各一次无 finding 手动终检及完成停止通过；0.7.18（任务 `1216aeef`）实测“首个有效程序独立检查严格早于任何编辑”→修复→终检 `ready=true`→1 次终检通知／1 次完成 stop confirmed，但 `findings={}`，**结构化 finding 生命周期仍未 exercise**，真实 finding 纠偏仍待验收 |
| 在途旧根检查→显式 rebind→workspace stale→新根检查（0.7.18 `35f925ba` 已验证） | 0.7.17 已实测**真在途**切换：独立旧根 reviewer（pid 98639，自有 pgid）存活确认后同秒入队 rebind+amend，1s 后 `workspace_rebound`，新根检查 5/6 complete 且终态停止确认；**旧检查 1 于 03:32:15Z 启动（reviewer 进程 03:32:20Z），重绑定 03:32:22Z 生效，该检查 03:33:13Z 记 `check_failed`、`stale` 为 null：该旧检查自身失败、未得到正常的 stale 结果，因此 workspace-stale-on-completion 语义未验证**，不作完整通过 |
| 有成员与背景工作时的 native Esc 及正常退出／确认停止 | 0.7.12 第二轮完成成员后 Root／成员正常停止及 /exit 进程退出通过；第三轮在途成员 native Esc→paused、Root／成员确认停止→/exit 进程退出通过；0.7.17 后台预览任务（真实 async `node server.js 4173` + 两名成员）实测 Esc→`paused`、Root 与两名成员确认停止、/exit 后原 PID 与 preview 33443 均消失——**停止通过**；但该轮**业务交付失败**（成员 429 额度与 edit input 投影拒绝、hint 未绑定），停止通过不等于交付 |
| 同质量交付下旗舰资源、其他消耗、返工与用户介入比较 | CSV 两轮与 logstat 两臂在副本重放同一冻结 8 项均通过（logstat 另有 6 项冻结探针 6/6）；logstat 旗舰逐类 Root 用量 input/output/cacheRead 为 baseline 23060/4904/150528、mixed 23782/4971/458112，**mixed 更高、不是节省**；完整独立同质评价待闭合 |
| OpenRouter 正式基准认证抓取及实际消费者 | 认证双接口实测 HTTP 200、刷新 446 个非 alias 行（key-free 证据 /private/tmp/orbit-or-verify/verification.json）；checker 与 member 两侧 facts 消费各有实证（checker＝logstat 混合臂检查者；member＝后台任务成员选择阶段）；member 推荐采纳与成功交付、完整身份与映射仍待证；基准语义测量日期单独一项仍 unknown（无逐模型测量日期，只有快照级 as_of）；第一方价格／计划事实已按其适用条件留证，账户凭据与实际扣减归属是另一项未知，两者不合并；新安装构建真实闭环与候选完整身份／冲突资格仍需实际核验；匿名 401 为历史记录、不重标 |

本轮负例、旗舰对照、0.7.11 两轮混合及 0.7.12 三轮 Root 进程均已结束。用户要求整理界面后，开发 B/C/D/E、自有 F/G、空闲未接任务的 H/J 及已完成的 K/M/N pane 均已正常退出、核对进程后关闭。重绑定准备轮 `w1Y:p1P` 也已通过原生 `/exit` 和 shell `exit` 从 Herdr 列表消失；该轮任务停止确认早已记录，最终 pane 退出未取得独立 PID 查询。0.7.17 各轮已在新 pane（`w1Y:p1X`、`w1Y:p1Z`）与既有 pane 上成功创建并运行，此前 `pane split`／`process-info`／`close` 的 `Operation not permitted` 为历史记录（权限已恢复）。已结束的 SUT pane 均已关闭；开发 Q／R／S pane 保留；独立 SUT finding-repair 仍在运行。本轮早前“只剩主 pane”的表述只属当时那一轮（按当时日期归属），不是当前界面状态。种子、原始会话、独立报告及证据目录保留至完整验收收尾；不推送或发布。Goal 保持 active。

## 2026-09-30 追加：0.7.21 源码验证集与 0.7.20 真实成员负例

本追加只记录事实并区分三类证据（**源码/静态**、**mock/脚本**、**live 实机**），不重开已结束阶段，也不改写任何原件或把失败结论改为通过。

### 0.7.21 已提交并安装（`fffabf80`／digest `ae9ce431…`／2026-09-30T11:21:07Z；唯一组合 full run2 exit 0；自动接管已实机一轮，见下文 fresh 任务）

| 项目 | 事实 | 证据类别 |
| --- | --- | --- |
| 入口提示 + 自动/手工接管 | `plugins/omp-host.mjs` `83e62a1b…`、`lib/orbit/prestart.rb` `ec1e206c…`、`contracts/task-runtime.md` `498ded5e…`；R 的相关 run exit 0，Q 四文件独立审 PASS | 源码 + 静态审 |
| 运行时结算／宿主（R） | `lib/orbit/task_runtime.rb` `97414ff1…`、宿主 `28e4cffa…`、测试 `28fee447…`；最终冻结源码的验证跑在 `run4-errorstruct.log` **exit 0**（“run4”是日志标签，不表示四次运行全部通过；更早的 fixture 失败以会话摘录保留，日志覆盖不冒称全部通过） | 源码 + 静态审 |
| 自动接管关键测试（S） | `tests/omp_native_gate_test.mjs` `9fedfd2b7db01fb99ac1242dd264ca59ebbabe79f9513e4347ae5b67110d1122`（含 stdin 修正、OpenCode Go route bridge 组与自有 runtime 退出清理）；单次 `node` gate exit 0；首次 fixture 泄漏失败日志保留 | mock/脚本（真实任务记录与真实 socket，无模型调用） |
| 需求文本容量 300→1000 | `contracts/check-result.schema.json`、`runner check-result.ts`、`lib/orbit/check_runner.rb`、`lib/orbit/requirement_coverage.rb` 同界；真实被拒原件在本地校验可接纳；**缺证、重复、>1000 字符仍被拒**。`complete:false` 本身是合法的可解析结果（不是 JSON 拒收）；当前 delivery 未核验时不授 ready。不能把任何 false 或伪造的 complete 都说成“被 JSON 拒绝” | 源码 + 静态审 |
| 验证回执压缩选择（S） | `lib/orbit/check_runner.rb` `c39968f3…`、`tests/check_runner_context_test.rb` `23254c9a…`；相关 suite exit 0（退化 caps 下交付给检查者的 JSON 保留当前执行回执、失败条与省略计数）；反向副本验证旧 `recent_tail` 会失败。Q 二次审 PASS（其 PASS 路径已发出） | 源码 + 静态审 |

以上均为**源码或脚本证据**，没有用它们替代实机验收。**0.7.21 唯一组合回归已完成**：run2 `npm test` **exit 0**（日志 `/private/tmp/orbit-regression-0.7.21/npm-test-run2.log`，末尾 `INSTALL_TEST_PASS shell_configuration`；126 只是 PASS 标记行数、不是测试数量）；同次 `npm pack --dry-run` 83 files／422028 B、`check:version` 与 skill validator exit 0；**129 个源/测试/打包文件 run2 前后 SHA 相同**（`hash-compare.diff` 为空）。首次 full 的 `exit 1` 与中间 `judgment_usage_test` fixture 失败日志**全部保留**；修复**只改既有测试夹具到生产校准形状**（`tests/judgment_usage_test.rb` `78b744e2…`），**未放宽任何生产门**。该组合已由 Root 本地提交 `fffabf801b430b61aa11d58f86f99960bdd9c8aa` 并经 `sh install.sh` 真实 exit 0 安装（`orbit version --json`：0.7.21、dirty=false、digest `ae9ce431…`、11:21:07Z；原始身份记录 `/private/tmp/orbit-takeover-fixture-1D6DEl/controller-records/installed-version-0.7.21.json`）。**本版自动接管已完成 fresh 实机一轮**：普通阶段仅改解析模块且未建任务；请求 02 后任务 `8e411be9` 于 11:27:42Z 保存接管边界（`prior_scope unknown`、真实原生消息 `b4d56978`、私有快照六文件与普通阶段一致），**complete＋confirmed stop（11:44:53Z）**，成员=0；详见下节。

### 2026-09-30 fresh 自动接管实机（任务 `8e411be9-9703-47c0-8898-f95348eb34b5`，installed 0.7.21）

- 普通阶段：仅 `src/parse.js` 被改、未建任务，Root 用自己的原生冒烟命令验证（Controller 记录 `ordinary-stage-boundary.json`／`ordinary-stage-terminal.txt`）。
- 自动接管（请求 02）：任务于 11:27:42Z 保存接管块——`prior_scope unknown`、真实原生消息 `b4d56978`、私有 `takeover-snapshot`（六文件哈希与普通阶段边界一致）、程序时间戳；Root 其后手工 `start` 带的 `takeover.scope` 被宿主**已激活任务的早返回忽略**（会话 11:28:08.507Z，结果 `{existing_task:true}`），**不是 CLI 拒绝**。
- 六次真实 checks（同一 input `5ca00fc9…`／同一快照 `sha256:f8c2a0852b…`）：1—4 为 provider 失败（Go 429×2、K3 周配额 403、GLM-5.3-FlashX 403 无权限），5、6（zenmux）有效并 complete，11:44:33Z 终检通知；11:44:53Z **stopped 且 confirmed**（active_tools 0、async jobs settled）。`findings` 为空、无纠偏。
- 账本（仅本任务）66 次：root 26／checker 24／judgment 16；**checker 14 次无完整用量**；`reasoningTokens/totalTokens` 为子集不相加；**现金与额度仍未知**。普通阶段的原生模型调用不在该账本内，未按时间归属。
- `work-unit wu-8e8d3f0c…` 是**当前要求版本**的声明（input `5ca00fc9…`），不追认此前 parseLog 为受控；**成员=0**，不构成自主派发或节省证据。`prior_scope` 追加与 Go 映射接线（五文件）尚未安装。
- 进程：已记录并实测缺失 → 63257／63315／63458／78421；六次检查各自 reviewer pid（87896／88073／88202／9751／10136／20653）亦实测缺失；按 fixture 路径与会话 id 扫描无引用。
- 原件保护：`controller-records/originals-sha-{before,after}.sha`（118 项，diff 为空）；完整后验见 `controller-records/postmortem-8e411be9.json`，`summarize_task.rb` 只读输出存 `controller-records/summarize-task-8e411be9.json`。

### 0.7.20 真实成员运行（任务 `1d977642-e478-4553-9959-7bc1a7381c9b`）——保留为负例

- 链路：`09:38` 声明单元 → `09:39:05` 成员 `orbit-f5624373…` 注册（`orbit_hint`）→ **`09:39:06.820` 该成员 `last_turn_error` = HTTP 429 `Go usage limit exceeded`** → 单元 rejected → `dispatch_changed` 使其结算失效 → `09:40` 替补成员 `orbit-a7732dde…`（`root_without_hint`）注册 → `09:48:54` **真实 native accepted** → `09:49:39` 单元 accepted（Root 集成）→ `09:50:00` Root 自有 `node --test` 回执 **exit 0，8 pass/0 fail**。
- `10:00:33` 的 `amend` 输入修订**撤销了首派失败结算**：该成员最终停在 `registered`（未结算），`pending_finalization` 未送达 → 任务终态 **paused ＋ confirmed stop**，两成员 `disposed`、async jobs settled；**已记录并实测缺失**：Root `43508`、MCP `43564`/`43679`、runtime `45378`，且按 fixture 路径与会话 id 扫描无引用；**reviewer PID 未逐一记录，不能声称全部逐 PID 实测退出**。**paused 不是 complete**。
- 手工终检补证的**绕行根因已定位**：检查收到的 `root_verifications` 在 64 KiB 压缩把 `list_limit` 降到 2 时被 `recent_tail` 只留最新两条 control-URI 写回执，程序自己的 `node --test` bash 回执（当时 `input_matches`/`artifact_matches` 均为真）被静默丢弃——是**程序选择缺口**，不是检查者撒谎；check12 输入已变更（digest `6bbf0011…`），旧回执本就不 current。原件未改、旧 check 未改为通过；调查见 `/private/tmp/orbit-member-settlement-live-6tGQlP/controller-records/{postmortem.json,receipt-gap-analysis.json}`。
- 成本：账本 185 次调用（root 51／member 49／checker 41／judgment 40／arbiter 4），**29 次未上报用量**；按角色分类保留真实类别，`reasoningTokens/totalTokens` 不并入 output；**没有已核实路由价格覆盖本次运行，现金与额度成本保持 unknown**——未知不等于实现不了核算。
- 边界：Controller 的 native `/exit` 是**负例记录**，不构成业务完成；本次为**明确 fixture 派发**，不当作普通自主派发或经济收益证据。

### 待办（下一步，不扩范围）

0.7.21 已提交（`fffabf80`）并经 `sh install.sh` exit 0 安装；下一步用已备好的临时项目完成自动接管／真实成员交付与确认停止的实机验收（自动接管已一轮 complete＋confirmed stop，成员=0），以及不带强制派发的 paired 对照。W1—W10 依据证据仍未完整闭合，本追加不主张完整 Goal。

> 该段为当日事实记录；后续版本进展见下面 0.7.23 追加段。

## 2026-09-30 追加：0.7.23 安装构建与 installed 0.7.23 普通请求任务

本追加延续同一口径：区分源码/静态、mock/脚本与 live 实机证据，不改任何原件，不把失败或未触发分支写成通过。

### 构建与安装（installed `0.7.23`／commit `5d5a497`，`dirty:false`）

- 身份：`orbit version --json` → 0.7.23、commit `5d5a497ad3565d89b3f7193258c738ede81d03f4`、digest `919d5f87588176f83ba4f387f69da371a72d1ba663c0d10a9b2344cb9051d62d`、installed_at `2026-09-30T14:17:32Z`；`sh install.sh` **exit 0**（`install.log`：`Installed orbit 0.7.23 (5d5a497…)`，OMP CLI 18.3.4 经版本门接受，reviewer bundle SDK 18.3.4，`release-record.json` 格式 `orbit-install-4`）；按实际字段：提交前 `before-git-head.txt` 为 `1893fd7`、提交后 `after-git-head.txt` 为 `5d5a497`，**安装的源码提交即 `5d5a497`**（`install.log` 原文）；`after-git-status.txt` 为空（**安装当时**的清洁状态，不代表本追加写作时的工作区——本追加写作时四文档为 dirty）。原件目录 `/private/tmp/orbit-release-0.7.23-delivery/`。
- 提交前组合回归（`/private/tmp/orbit-regression-0.7.23-gu0Ouq/`）：`npm test` 单次 **exit 0**（PID 60360，日志末 `INSTALL_TEST_PASS shell_configuration`；同目录 `run.out` 是宿主 `setsid` 不可用导致首次 launch 未执行 npm 的原始记录，**不是测试失败**，`run-recovery.out` 才是本次 full）；`npm pack --dry-run --json` 83 files／426977 B；skill validator `Skill is valid!`；`check:version` → 0.7.23；`git diff --check` exit 0；**129 个源/测试/打包文件逐文件 SHA 比对无差异**，docs 状态前后一致（差别另列）。
- 版本标签（源码/静态）：`orbit-quality-decision-3`、`orbit-member-selection-v2`、`orbit-checker-selection-v7`、checker signature `v8`；17 个真实校准样本逐字保留（samples SHA256 `5a30130a022abd2bc1b35a6ebe61c2ea4fe0e750cafbb0d23d6d51de973d03cc`），decision-3 放行由 Root 于 `2026-09-30T13:57:50Z` 独立审核后重签。

### installed 0.7.23 普通请求任务 `01f4925b-84e2-4560-9a26-20cf1bb5294b`（live 实机）

- fixture `/private/tmp/orbit-ordinary-phone-1XOIXp/product`（seed `f59f7d0bf5e9479d5aa08e848e97324b215e00be`、tree clean、请求原文不提 Orbit，sha256 `925ed6d4…`，真实全池 sha256 `4eafb0a4…`）；结构化后验 `controller/terminal-audit.json`（生成于 `2026-09-30T14:28:58Z`，hash／pid／时间取自原件）。
- 入口：分类 `uncertain` → 判定 `start`（`orbit-entry-rules-3`／`orbit-entry-3`／`input-2`／`decision-2`），实际模型 `jev-1.13.0`、`answered`，原生消息 `d14d7f47`；任务 14:21:21Z 建立。
- bootstrap：首个可扩展 provider 载荷记录 `via: provider_payload`、`work_unit_state: none`；首次明确 `edit` 前单元状态同为 `none`。SUT 选择自行实施（`work_units=0`、`members=0`、无 `members.json`）。
- 检查 3 次：1 失败（`opencode-go/deepseek-v4.1-flash`，Go 429，用量 `unknown`）；2（自动）与 3（手动）为 `kimi-code/k3-256k`，均 `complete`、findings 0；14:25:57Z 完成后通知 1 次，Root 自行 stop，14:26:09Z `complete`＋`confirmed`（`active_tools_after 0`、`async_jobs_settled true`）。三次 `fingerprint_before == fingerprint_after`、只读、无禁用工具。
- 选择：basis `pool_order_unreleased`——**任务在放行 profile 内且有真实付费判断**（2 次 `jev_checker_selection` `answered`、`judgment_model jev-1.13.0`、decision-3、`requirements_error: null`；`task review.selection` 记 `task_fit_scores["zenmux/deepseek/deepseek-v4.1-flash"]=0.55`），但**无候选过 0.6 门**，故降级池序——**本轮只证明降级与失败后的有界重选，未验证 decision-3 过门后的稳定池序正向排序；该任务不是域外任务**。
- 资源（仅本任务）：judgment 8 次（input 14854／output 382）；`root/gpt-6-sol` 19 次（totalTokens 301050）；`checker/k3-256k` 5 次（totalTokens 54277）；`checker/deepseek-v4.1-flash` 1 次用量 unknown；**现金与账户归属仍未知**。
- 独立评估：外部 copy 跑固定 9 例 `npm test` **exit 0（9 pass／0 fail）**；`README.md`／`package.json`／`test/phone.test.js` 与全局池 SHA 未变。
- 元数据：`launch-current.json` 的 `seed_head` 手写誊抄有误（`…e974…`），实际 `f59f7d0b…e97324b215e00be`；纠正记录 `controller/launch-current-corrections.json`（保留原文件、不重跑、不改 SUT），另有 `instruction.txt` 与请求文件 sha256 并存的末尾换行差异（`equal_strip_final_newline: true`）与 prompt 回执 stalled 但任务确已创建（原生消息 `d14d7f47`）两条补充。
- 边界：**`members=0` 只说明 Root 选择自行实施，不构成自主委派或收益证据**；launch pid 87232 与后续 87289／87405 经 Root 实测已不存在，未执行 kill。

### 最小链资源后验（installed 0.7.21，任务 `26935a3e`，live 实机＋只读汇总）

`/private/tmp/orbit-minimal-chain-PbtkHC/controller/resource-post-audit.json`（只读汇总原件；其 `recorded_at_utc_machine_clock` 是**手写估计、时间未核实**，纠正记录 `/private/tmp/orbit-quality-decision-3-impl/install-preflight-timestamp-correction.json`，不据此重标原事件、不改账本）：36 次调用全部 `reported`、call_id 唯一；`native-model-calls.json` 24 条（root 17＋member 7）与 `resource-calls` 1:1 命中，checker 4 条在 `resource-calls` 与 `checks/1/evidence.json` 两处 id 集与用量一致；三组 input+output+cacheRead 等于 provider 报告的 totalTokens、cacheWrite 为 provider 报告的 0；reasoningTokens 为单独报告子集、未另加总；judgment 服务只报 input/output；**billing／account 仍未知**。该轮同时是 **native hint 采纳与成员结算的有限证明**（accepted＋hint adoption＋complete＋confirmed stop）；**其旧负例（p26、`02a5eda7`、`1d977642` 等）原样保留、不改判**。本摘要只汇总该轮明确交接＋唯一池候选的账本，**不证明普通派发、池选型或任何收益**；原件逐项 SHA 见其 `sources_sha256`。

### pair2 mixed 臂（普通自主交接核心验证；该轮 complete＋confirmed stop，自主委派仍为负例）

- 启动记录 `controller-records/launch-current.json`（`2026-09-30T14:35:09Z`）：`herdr pane run` 于复用空闲 shell `w1Y:p26`（命名 `reconcile23core`，命令取自 `FREEZE.arms.mixed.command`），**pid 27206**（进程 args release `e06179ef…`＝0.7.23）；fixture `mixed/` head `e6085adf…`、固定四文件 SHA 与业务 prompt sha256 `dbd4569e…` 存档；session 目录 `root-sessions`（product 之外）。
- 任务 `d623e8b1-9d51-4bef-ba7d-8359bd3f7341`，会话 `01a0f2bd-1f7c-740a-b7f7-ee3382f8e738`，`created_at 2026-09-30T14:35:19Z`；原生消息 `8eec046e`；入口 `uncertain → start`（`jev-1.13.0`、`execution_authorized 0.97`、`delegation_value 0.83 ≥ 0.65`、`supervision_value 0.51`）；`bootstrap_guidance` 事实为 `via: provider_payload`、`work_unit_state: none`；首次 `edit` 前 `unit_state_before_edit = none`。
- **终态**：`complete`，`stop_confirmation.confirmed = true`（`status_after idle`、`active_tools_after 0`、`async_jobs_settled true`）；事件链 `automatic_check_complete_ignored` → `finalization_notice`（14:43:25Z，check 3，version `sha256:ebd6de83…`）→ `completion_stop_queued`（14:43:32Z）→ `completed_via_finalized_stop`（14:43:36Z）→ `stopped`（14:43:36Z）。终端后验 `controller-records/terminal-audit.json` 生成于 **14:44:49Z**。
- 检查 3 次、快照前后不变：1 为 `opencode-go/deepseek-v4.1-flash` `check_failed`（用量 `unknown`，保留）；2（自动）与 3（手动）为 `kimi-code/k3-256k`，均 `complete`、findings 0。
- 资源（仅本任务）：judgment `jev-1.13.0` 10 次（input 22762／output 492）；`root/gpt-6-sol` 19 次（totalTokens 388911）；`checker/k3-256k` 6 次（totalTokens 86974）；`checker/deepseek-v4.1-flash` 1 次用量 unknown；reasoningTokens 为子集、未另加总；**现金与账户归属仍未知**。
- **自主委派负例（保留）**：`members=0`、无工作单元记录、无 native task 派发、无 `delegation_hint`；Root 首条明文自行依据：“这两个实现文件的契约由同一份 README 和验收测试约束，我会自行完成，避免拆分时重复协调”；advisory 的实际送达无法从持久原件独立复核（会话 jsonl 计数 0，该通道不留 fact record）。**该轮不作为自主交接通过或收益证据。**
- 进程：原生 `/exit` 已执行（`exit-submit.json` exit-code=0、agent idle）；pid 27206／27262／27322 经 Root 复查 ps 均消失，Herdr agent list 已无 `reconcile23core`，pane 回到 shell 并保留。
- Q 外部副本验证已完成：固定 8 tests **8/8**、冻结 6 probes **6/6**，各一次 **exit 0**（`controller-records/external-{evaluation.json,npm-test.log,probes.json}`；评估记录生成 **14:59:13Z**；harness SHA256 `6391e77c82dbec1d40d53bc945f4a947694960f17b21ab1be2de7d157997d3ac`、probe source SHA256 `e4358173adf65ba72e98bce71f71cd4ef50c510488773939ab73e836dd6ece39`）。**该 PASS 在外部副本执行、不改原件，也不改 `members=0` 的自主委派负例。** baseline 臂未启动、资源对照未做。下一步为只读调查 native 委派规则的生效分支，**尚未证实根因**，原因明确后再做针对性修复与重验。

### 状态

W1—W10 仍未整项勾选；普通全池自主委派与同质量资源对照未完成（pair2 mixed 该轮已 complete＋confirmed stop 且进程已退出，但 `members=0` 仍是自主委派负例；Q 外部副本固定 8 tests 8/8＋6 probes 6/6 各一次 exit 0 属有限 PASS，不改该负例；baseline 臂未启动、资源对照未做）；本追加不主张完整 Goal，不新增任何框架或验收门。

## 2026-09-30 追加：0.7.24 受控串行交接合作政策（本地提交＋安装＋独立复核）

本追加延续同一口径：源码/静态、mock/脚本、live 实机分开陈述，不改旧结论与负例。

### 指令冲突（源码有效分支，非 wire 证据）

- 已安装 OMP 18.3.4 的类规则对 `revision >= 6` 给 `delegation-bias restrained`（`pi-catalog/src/compat/rules/classes/openai.kdl`）；`pi-coding-agent/src/system-prompt.ts` 的 `inlineFirstDelegation = delegationBias === "restrained" && !eagerTasks` 在该分支渲染 inline-first 文案（`prompts/system/system-prompt.md` 的「NEVER delegate one slice」「2+ independent slices」，`eagerTasks` 默认 `default`⇒false）。这与主方案 §5.2「有界单成员串行接力」冲突；**这是源码规则分支与 shape／config 探针证据**，**不能由静态推定旧两轮 `members=0` 的因果**（phone `01f4925b`、pair2 `d623e8b1` 的实测行为一致只属对照事实）。
- 只读调查与探针输出：`/private/tmp/omp-delegation-bias-investigation.json`（含 `.omp` 配置层更正：本机无 `task.eager` 覆盖、无 CLI 旗标）。**实际请求体未落盘**，故只主张 shape／config 与源码规则分支证据，不宣称服务器收到该文案、也不宣称模型心理因果。

### 交付与安装（installed 0.7.24）

- `npm version patch --no-git-tag-version` → 0.7.24；提交 `59eb7e777fd521e9db138e9953ff0adc277538e2`（“fix: allow controlled serial handoff at the native instruction layer”），提交后工作区 clean。
- 组合验证（同一次 run）：`npm test` **exit 0**、`npm pack --dry-run` **exit 0**、skill validator **exit 0**、`npm run check:version` **exit 0**、`git diff --check` **exit 0**；129 文件 pre/post/final **逐文件**一致（`/private/tmp/orbit-regression-0.7.24-fqtEee/report.json`，含 `six-files-sha256.txt` 与 `hash-compare*.diff` 空）。
- 安装：`install.exit`=0（窗口 `15:31:55Z→15:32:12Z`），installed 0.7.24／commit `59eb7e7`／digest `02067f58…`／installed_at `15:32:10Z`／dirty false；OMP 18.3.4 未升级；随包文件（host／contract／package／quality policy／calibration）与源码逐字节一致，`docs/`、`tests/` 不在 pack 清单（旧字段 false 已勘正：不存在≠失配）。原件 `/private/tmp/orbit-release-0.7.24-delivery/`。

### 实现与边界（同层政策）

每个可达 provider 请求、仅实际 owned＋活动＋runtime alive 的受控 Main 注入条件式政策（“若原生默认以仅 2+ 独立片段或不委派单一片段限制交接，则本受控任务适用有界交接规则”）：先声明工作单元供 Jev two-stage 真实适配判断，再依据真实 hint 或带局限的 Root 选择决定是否用 native `task` 派发；缺并行片段／共享接口／需等待依赖不单独构成拒派理由；短小低收益可有据自行实现。可承载位置：`instructions`、Anthropic 顶层 `system`、messages 既有 `system`／`developer` 消息文本末尾、Responses `input` 既有 developer 块之后；不可识别形状**静默跳过**（不落用户消息尾、不伪称送达）；请求内幂等；首次成功每“本进程／任务／版本／渠道”记一次事实（含文本指纹与 `delivered_claim`=仅 extension 修改该载荷），不存请求体／凭据。不改用户要求／目标项目规则／工具权限，不代替 Root 派发、不增加用户批准、不改 Jev 题义／阈值／decision-3／17 个校准样本。

### 独立复核

Q 预部署审 `review.json`（15:15:41Z，PASS_limited_scope_with_one_finding）＋ F-1 增量复核 `addendum-f1-fix.json`（15:20:53Z，PASS，无新 finding；F-1 = messages 承载 developer 角色原生 system 时漏口，已修并断言渠道 `developer_message`）；`metadata-correction.json`（15:23:05Z）仅勘正 addendum 中一位 hex 誊写与把判断词并入 hash 值的记录问题，**原件不覆写**；并限定其 minor note：`policyRecorded` 为进程内 Set，但非本进程记录会被 `host.ownsTask` 拒绝，只有该任务被新进程实际重新 owned 时才可能再记首达事实。gate 真实日志（互不覆盖）：`/private/tmp/orbit-policy-fix/gate.log`（首失败，属测试解析非实现）／`gate2`／`gate3`／`gate4`（均 exit 0）。

### pair3 mixed 臂（已启动；详见下文独立小节）

`/private/tmp/orbit-reconcile-pair3-NXisvi`：从 pair2 baseline 六文件复制生成两隔离 Git 臂（同 seed `beceae6`），逐字节等于 `b01a87c` 归档源（历史记录中 README／package.json 两处 hash 誊写误值按实际复算标注、旧记录不重写）；业务 prompt 逐字复用 `dbd4569e…`（不含派发／Orbit／型号／成员数提示）；P1–P6 探针源＋harness 逐字复制（`6391e77c…`／`e4358173…`），冻结 8 tests＋6 probes 原题、expectations 未改；`controller/FROZEN-SOURCE.json` 为准（旧 `FREEZE.json` 是历史副本，identity 不代表本臂）。**mixed 臂已启动（见下一小节，running／partial）；baseline 未授权、未启动；只报已读原件事实，未见实际接受与停止证据前不得称成功。**

### pair3 mixed 臂（已启动；截至本次读取 2026-09-30T15:49:08Z 为 running／partial）

- 启动原件 `controller-records/launch-current.json`（15:42:07Z）：`herdr pane run` 于复用的 `w1Y:p26` shell，**pid 19954**，参数指向 release `c57f2888e80281027ffc166d`（0.7.24），session 目录在 product 之外，`eager_override`: none；fixture seed `beceae6b6c1b35d1003f48f62cb220eb0e7f6db8`、六文件与 `FROZEN-SOURCE.json` 一致、prompt `dbd4569e…`。
- 任务 `b91fe4de-9927-4aaf-883a-e59423845e4c`：15:42:28Z 建立，**现 `running`、checks=0、无 stop**（`state.json` 读取时）；会话 `01a0f2fa-88e5-754f-8e66-afabd2e8ac31`。
- 已读原件的阶段事实：① policy1 首个成功事实 `channel: instructions`（model `openai-codex/gpt-6-sol`、文本指纹 `9877cc7a…`、`delivered_claim` 仅“extension 修改该载荷”）；② 15:44:12Z Root **自主声明** `wu-56f0622023bf4fa6`（非请求派发指令）；③ 15:44:15Z 首次 member selection `not_recommended`，原因 `TypeSafe assessment failed: Net::OpenTimeout`（`jev-1.13.0` requested、status unavailable、无分、无 hint）；④ 15:45:19Z Root **无 hint 自主首派**，成员 `orbit-3696a6fb-6554-4878-96a7-c833a459442a` 注册（basis `root_without_hint`、model null）并绑定工作单元；⑤ 该成员 **provider 429（Go usage limit）真实失败**（未产生任何实现改动），工作单元 15:46:27Z `failed`、`member_settlement_invalidated`（dispatch_changed）；⑥ 15:46:30Z 新一次真实 selection `recommended`：首选 `orbit-m-kimi-code-k3-256k-301bb915`、备选 `orbit-m-zenmux-deepseek-deepseek-v4-1-flash-0afa958f`，`handoff_fit 0.83／member_task_fit 0.71`（`jev-1.13.0`），`delegation_recommendation_delivered` 事件存在。
- **decision-3 正向排序已触发**：latest selection（state `at` `2026-09-30T15:49:51Z`，signature `d4325c38…`）release `orbit-quality-decision-3`、门 0.65；候选 quality index0 0.21／**index1 K3 0.66**／index2 0.15／index3 0.22／**index4 Zen 0.70**／index5 0.38；`positive_ids`=[K3(index1), Zen(index4)]、`first` K3／backup Zen、`cost_comparison: unknown`、basis `released_task_fit`（首次该窗口推荐事件 15:46:30Z：handoff 0.83／member 0.71）。**phone／pair2 未触发；真实 hint 采纳与成功成员交付仍未证。**
- **同窗成员结算**：`member_settled` 两次（15:45:21Z／15:46:27Z）均为 `status: failed`、`source: native_turn_error`，工作单元随之 `failed`；**不是长期未结算**。
- **两个已核断点（只读诊断 `controller-records/breakpoint-diagnosis-redispatch.json`，只评估未实现）**：Seam B＝成员真实原生错误失败、unit 仍 `bound` 时自主重派被宿主前置门拒绝；Seam A＝host `matchedHint` 硬编码 `orbit-member-selection-v1` 而当前 selector `v2`（0.7.23／24 的 v2 hint 绑定链源码不可达，pair3 未发生该 seam 实机拒绝）。下一步只读诊断后最小修复，不盲重启。
- **边界**：截至本次读取 checks 已出现 1 次（artifact／reviewer #1），仍无**已接受**成员交付、无停止；本追加不把该轮称为成功或失败终结，也不把 policy 注入当成员交付证据；baseline 臂未授权、未启动。后续状态以该任务目录原件为准。

### 资源未知口径（窄范围，待 Root 复核）

本轮**不做资源结论**。既有摘要的未知按各自报告范围理解：**现金与实际扣减桶未知**（`cash []` 只表示未知，不是 0 成本）；**账户／OAuth 归属是否可得以各任务原件报告范围为准**，不得概括为“全部原生账户缺失”，精确归属待 Root 复核原件后确认。旧负例（0.7.20 paired `members=0`、Top 约 +30%；p26；`02a5eda7`；`1d977642`）与 pair2 `members=0` 全部保留，本追加不改判。

## 2026-09-30 追加：0.7.25 同代 hint／失败重派修复（本地提交＋安装）与 pair3 终态、pair4 fresh 复验

- **0.7.25 已安装**（commit `7f572e8`、digest `0e0deba4…`、installed_at `16:44:03Z`、单次 install exit 0；83 pack 文件与源逐字节全匹配；原件 `/private/tmp/orbit-release-0.7.25-delivery/`）。组合验证：178 git-tracked 全量冻结 pre/post 一致、恢复 run 权威 `npm-test-recovery.exit=0`（第一次全量退出无法验证——kqueue 原件缺 e.flags，原因未知）、check:version／pack／diff-check exit 0、validator（skill-creator 绝对路径）"Skill is valid!"。本版实施 Seam A（host 同代 hint 门，旧 v1 硬编码移除）与 Seam B（真实 native 错误＋实际 idle 时原子记 unit failed、保留历史）及 host.mjs 三处 work-unit 必填文案；实现由 Q 承接 S 半成品（S 402 停写），Root 独立 review 通过。
- **pair3 mixed 臂终态（complete＋confirmed stop，非成功成员交付）**：任务 `b91fe4de`；链路＝自主声明→首个 selection 服务失败（TypeSafe Net::OpenTimeout，非有分 decline）→无 hint 首派 `opencode-go/deepseek-v4.1-flash` 注册后 429 Go usage limit 真实失败（native_turn_error，实现前零改动）→Root 自主 same-unit K3 重派被 bound 门拒（两断点诊断 `controller-records/breakpoint-diagnosis-redispatch.json`）→Root finish failed 自行实现→decision-3 two-stage 真实触发（K3 .66／Zen .67、稳定池序）但 v2 hint 无采纳——hint 后无实际派发；v1/v2 阻断另由源码确定（Seam A 断点与修复保留）→checks #1 Go 失败（usage 未知保留）/#2 K3 complete→外部 copy 8 tests＋6 probes 各一次 exit 0。资源 57 调用：root 32（864067 totalTokens）＋checker K3 3（60492）有 account_id 及 credential 关联；20 Jev＋2 Go 未知——分列，不泛称全部 account 未知；现金/扣减桶 unknown。进程已原生退出（Root 19954／MCP 实测消失）。
- **pair4 mixed fresh 复验（0.7.25，运行中、未终态）**：根 `/private/tmp/orbit-reconcile-pair4-iW4p7Z`（FROZEN-SOURCE 冻结、两臂 seed `037b84ed…` clean）；任务 `028437c2`；已读阶段（observation-2，16:54:20Z）：16:51:44Z 自主 declare `wu-f80688eccb4d7fc6`→16:51:45Z 真实 v2 hint（sig `1eea74bb…`、recommended）→16:52:38Z 原生 dispatch K3 注册 `orbit-e1e3db0c…`、**bound dispatch 实际含 hint_signature＋message_id、followed=true／delegation_basis=orbit_hint**——「同代 hint→自主 native 派发→绑定采纳」链的实机正向证据；成员尚 registered，不称 accepted/交付/停止。首次 `unit_state_before_edit(none)` 由 `write xd://orbit action=context` 触发，非业务源码编辑（与 pair3 同一分类规则）。baseline 未授权。

## 2026-09-30 追加：0.7.26 交付与 pair4 两臂终态、冻结对照结论

- **0.7.26 已安装**（commit `b7401a2`、digest `2314ec03…`、installed_at `19:59:55Z`、单次 exit 0；83 pack 对 release 字节全一致、installed loader accepted:6）。仅两处最小修复：Go 订阅映射 verified_by 短标签（限定理由以要点形式保留于 [mapping audit](openrouter-model-mapping-audit.md) 追加节（非逐字原文））＋host.mjs work-unit 类型 help。组合验证全绿（full 前台 wrapper 权威 exit 0 19:51:26Z→19:54:39Z＋check:version/pack/validator/diff-check exit 0；178＋83 对 tested-pre 一致；两段 freeze 边界与 pass_markers 227→127 勘误见 `orbit-regression-0.7.26-k7Ar/metadata-corrections.json`）。**回归通过≠新真实验收或收益证明。**
- **pair4 mixed 臂（0.7.25 试验）终态**：complete＋confirmed stop 17:02:54Z；全链真实——同代 v2 hint（sig `1eea74bb…`）→native K3 派发（注册先于模型工作）→bound dispatch 含 `hint_signature`/`message_id`→`followed=true`/`basis=orbit_hint`→member completed（`accepted_at` 1790787522088）→Root 集成（node --test 8/0 两次原生回执＋CLI smoke exit 0）→manual final checker#2 只读（fingerprint 前后同 `ea0dfee2…`、仅 glob/grep/read、coverage verified 5/0）→停止确认（Main 与成员均 idle/tools 0/jobs settled）→原生 exit（36581/36613/36727 消失）。**Seam B（same-unit 失败自动释放）未触发，列 unexercised 不冒称**。外评 8 tests＋P1–P6 各一次 exit 0。
- **pair4 baseline 臂（plain 18.3.4）终态**：session `01a0f352…`，业务 final `05615ab5` 17:23:54Z（stopReason=stop；13 assistant 回执）；node --test 8/0（原生 bash 回执）；外评 8 tests＋P1–P6 各一次 exit 0；原生 exit（72133/72162/72250 消失）。
- **冻结对照（`paired-comparison.json`＋`paired-comparison-correction.json`，原件保留）**：旗舰用量 input 34,746 vs 27,442（+26.616%）、output 5,940 vs 6,061（−1.996%）、cacheRead 571,392 vs 227,328（+151.351%）、cacheWrite 0/0、totalTokens 612,078 vs 260,831（+134.665%）；26 vs 13 root calls。全部其他角色分列（judgment 15、member K3 11＝249,231、checker K3 4、checker Go 1 unknown）；**account_id 41 known／16 unknown（judgment 15＋checker Go 1）；credential_id 42 known／15 unknown（judgment 15；Go credential 已知 1）；baseline 13 credential known／13 account_id 原生未报告**——不泛称身份缺失；现金/实际扣减未知（与身份分列），不按 percent/total 假设套餐扣减。reasoning：mixed root 21 known/5 missing（全 OMP 口径 21/21）、baseline 10 known/3 missing——子集不另加。每臂用户业务 prompt 恰 1 次；Controller 观察/外评/exit 分列，不计作被测干预也不称无动作。Root 仅 1 次 native wait，无已证轮询 loop。
- **负结论（不重标）**：固定 14 项验收质量两臂无可检出差异；**该任务 mixed 未证明节省旗舰资源**（分类用量描述不等于扣减结论）。0.7.25 原始试验身份不能写成 0.7.26 跑的。旧 minimum21/phone/pair2/pair3/paired20/rebind18 各版失败与 scope 边界原样留存，当前不再运行。

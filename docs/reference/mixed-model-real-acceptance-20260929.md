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

源码升为 0.7.12，尚待冻结安装及新任务实测：放行成员 native yield 生命周期入口；覆盖 scope-2 区分交付和后续检查／停止，测试执行仍属交付；真实 Root 工具 start/end 生成私有验证回执，钉住 start 要求／任务与 end 产物，检查者消费当前版本匹配、失败和截断事实，不信自写日志；检查者消息副本使用真实串行调用边界关联用量；同次未核验不能立即被自身退休逻辑翻掉，合格手动检查可等待成员实际接受后发一次通知；registry 已移除时仅凭精确 retained session 的实际取消、回收、dispose 与工具观测确认停止；无关坏目录身份不再清空所有检查者任务要求；完成后的闲置 pane 状态随耐久记录更新。

B 独立静态核对去时间的七个面并通过；B 独立复核验证回执两端，指出身份失配已修及中断 replay 的真实 started 变体已保留为 interrupted；C 独立定位 finalization 阻断并复核原门未弱化、同次 readiness 修复、retained stop 屏障，相关回归通过。源码接线和脚本验证不是新安装真实完成证明。

## 未闭合矩阵

| 必需项 | 当前状态 |
| --- | --- |
| 当前版本能力事实→Jev hint→Root 自主原生派发→hub 回收→集成 | 0.7.11 第二轮已发生，成员交付集成并通过固定 8 项；需求明确要求模块交接，普通需求的自主选择仍待新构建 |
| 独立 OMP 固定快照、逐要求覆盖、真实 finding 纠偏、手动终检 | 两轮独立固定快照已运行；真实 finding 纠偏及 0.7.12 可信测试回执／生命周期覆盖仍待验收 |
| 在途旧根检查→显式 rebind→workspace stale→新根检查 | 未运行 |
| 有成员与背景工作时的 native Esc 及正常退出／确认停止 | 0.7.11 有成员正常退出失败，程序记 stop_unconfirmed；物理进程已结束。修复后正常退出和在途 Esc 仍待重测 |
| 同质量交付下旗舰资源、其他消耗、返工与用户介入比较 | 三份产物在副本重放同一冻结 8 项均通过；当前混合试跑旗舰消耗明显高于基线，不能宣称节省；完整独立同质评价待闭合 |
| OpenRouter 正式基准认证抓取及实际消费者 | 匿名实测401，等待本机私有 key；公共页校准不是此接口成功证据 |

本轮负例、旗舰对照和两轮混合 Root 进程均已结束。用户要求整理界面后，开发 B/C/D/E 及自有 F/G pane 均已在正常退出、核对进程后关闭；之后出现的 H/J pane 归属未确认，未操作。种子、原始会话、独立报告及证据目录保留至完整验收收尾；不推送或发布。Goal 保持 active。

# 长任务优化验收（2026-10-09）

T01—T13 在本次正式授权下按三批实施。完成门、D1、验证边界沿[原方案](../plan/orbit-long-task-optimization.md)，未另建计划或扩大为全域评测。主执行者完成接缝集成与验收，开发 OMP 的回报未当作产品验收。**T01—T13 修复、约定验证、最终 TODO 展示补验及隔离资源收尾全部完成，实际 Goal 工具已标记 complete。**

## 构建与原件

- 启动 HEAD：`dbd93aa8a8a35e0d6e8a16f5fb7259ab75ae7455`；实施被测源码为 `0.8.2`，保留原有四份修改及两份未跟踪文档。该实施阶段未提交、推送、发布、升级用户全局安装或宿主。用户随后明确授权升patch至0.8.3并提交推送；只是版本元数据与交接状态更新，不改标以下真实被测构建。
- 最终隔离安装：`7f262f91c54f8b9f3bee9346a16f7fb01a2b173ecb8ac7816bfa7406acd93124`，`2026-10-09T07:39:41Z`，本地 dirty 源码。15 个关键源码／安装文件逐一 SHA256 相同。此前通过的路径保留自己的构建摘要，不改标为最终版；最终变动为用户来源过滤、合同链接、有效终检的 TODO 整理指引，并分别做相关补验。
- 实际 Root OMP `18.8.0`；独立检查 SDK 的 coding-agent/pi-utils `18.8.0`，直接 pi-ai `18.3.4`。以检查回执／安装包事实为准，安装器打印的源锁 SDK `18.3.4` 不冒充实际检查 SDK。SDK 原生 `task.items[].model` 优先级、工具入口和 TODO 接口已按官方18.8.0包源码核对，未修改用户 SDK。
- Herdr client/server `0.9.1`、`HERDR_ENV=1`；每个 SUT 通过 `herdr pane run …/bin/orbit omp --cwd 临时Git项目` 启动，显式 `-e` 来自隔离安装。plain OMP 未被安装器修改，用户／项目扩展入口未发现旧全局 Orbit；验收启动 `--no-extensions` 禁止发现扩展，只有 `orbit omp` 添加显式 Orbit。普通开发 OMP 不计入产品证据。
- [脱敏事实原件索引](long-task-optimization-evidence-20261009.json)：逐任务原要求／修订、原生消息和工具 ID、Jev 版本／真实分数、工作单元／型号、检查快照及 coverage、停止确认、实际用量。仅白名单字段；不复制认证头、账号／凭据 ID、环境、原始会话或图像 base64。
- 原件目录：`/private/tmp/orbit-long-task-EdkDDM`；task 下 `state.json`、`events.jsonl`、`collaboration.jsonl`、`checks/N/{scope,prompt,evidence,run}.json/txt`，以及对应原生 session。每单已运行 skill 的 `summarize_task.rb`，其结果仅作索引，实际判定核对上述原件。
- OpenRouter 真实缓存来源及时间另外记录在临时目录 `cache-provenance.json`；没有伪造分数。指标、价格是本次审计事实，未固化成单测的实时断言。

## T01—T13 逐项结果

| 项 | 实现与确定性验证 | 真实验证／限制 |
| --- | --- | --- |
| T01 | 检查／裁定的 work_units 使用专门投影；允许路径／工具／命令和有效 requirements 保持声明顺序，不按历史截尾。不可完整时明确计数／摘要／缺证，提示禁止据此认定越权。`check_runner_context_test.rb` 六路径／五工具及压力历史回归旧 HEAD 失败，新版通过。 | 独立检查读取固定快照与完整单元声明；本轮未自然产生权限误报／反证裁定，未伪造 finding，裁定提示的独立模型更正分支保持未测。 |
| T02 | 有效自动 artifact continue、无finding、未交付、可归属且实际 idle 时，每版本只唤醒一次；工具／成员在途、暂停、手动终检不重复。发送前重核输入／产物；ACK 与后续真实工具分别记录。runtime 历史回归通过。 | progressive check1：通知 `07:11:51Z`，真实新工具 `07:12:12Z`；先于下一次用户纠正，不把答应继续算执行。最终实现、验证、终检与停止通过。 |
| T03 | amend 必须指向明确真实原生用户消息，原文或省略text；context 提供原生ID；排除 attribution=agent。原交付及修订版本可追溯；状态询问只作续接来源。既有 runtime/native 回归通过。 | progressive 的 `0d26434c` 原文修订 line 字段，下一动作改代码／测试／README；旧检查因 input 失效，新终检核对最新版本。独立问答不 amend／不新建任务。首轮Root把进度问句登记为amend的错误保留，补清原文与来源指引后继续验证。 |
| T04 | resume_from 只接受同项目、同原生 Root、paused+confirmed 的旧任务；同 Root 新socket可接，保留原要求、有效修订和触发原文／真实快照，不迁成员、检查、用量或追认空档；成员实际停止与历史登记分开。 | native Esc 后当下停止；同任务追问先答再建 `6cfc83bd…` 并实际派新成员／写CLI，旧 `e5222c26…` 终态保留。明确暂停、状态讨论及独立HTTP问答不续接。正常 Ctrl-D 在成员工作中使Root／成员／后台确认停止。一次 Esc 首次未确认，实际收尾后 retained session dispose/async reap 通过，未假停。 |
| T05 | 用户通知默认简报、展开保留协议／错误；CLI status 一至两行，--details/--json 保留诊断；终态 readiness 与排队观察退役。有效终检后Root整理其本任务已核验／过期TODO，停止仍由真实Orbit状态确认。 | 终检通知后Root实际 stop，status及时变complete，用户无需轮询。先前原生复合TODO残留单独留证；最终 fresh Root 的 todo 工具回执显示四项已核验事项 completed，过期等待停止项删除；Orbit complete 且停止确认。没有批量勾完未知归属TODO。 |
| T06 | confined read 对PNG/JPEG/GIF/WebP返回实际ImageContent及路径／字节／SHA；记录真实独立session的model.input能力；无图能力／未读保持未验证。覆盖缺口与完成门保留。已有confined tests加一项图像行为回归通过。 | 独立K3实际读 `reference.png`，1379bytes，SHA `954491b5…d04ed`，model_image_input=true；前后固定快照一致，private registry仅OrbitReviewer、global空、无禁止工具。报告与左红方／右绿圆／米白背景一致。不是整页审美、所有图像格式或所有模型视觉认证。 |
| T07 | Root declared 自执行单元可 accepted/rejected/failed，无需伪造成员；输入／工作区／依赖／核验依据门保留。工具及错误说明合法枚举和非空字符串；既有work_unit测试扩一行为组通过。 | visual-finish root单元 `wu-836f5c44306defd0` accepted、dispatches为空；独立终检与停止通过。progressive 修订后旧单元拒收，Root新声明有效单元并核验，未把旧拒收归咎成员质量。 |
| T08 | 按官方SDK实际解析 item.model，再校验用户池；显式覆盖优先，单值数组解包，多候选歧义拒绝，注册／调用漂移门保留。不删除历史GLM5.2 fixture字符串。native gate／collab tests通过。 | K3实派／注册／调用与批准一致。池外默认值被显式覆盖的具体分支、池外拒绝及多值数组仅确定性证明。 |
| T09 | declare／dispatch核实必要宿主工具入口和bash sandbox；完整路径／命令guard保留；超时先核实实际登记／结果，缺能力由有权者接管或问必要前置。scope/native tests通过。 | 真实K3限定2文件、read/write/edit，越范围工具被拒绝后正常交付；结果经native回收。刻意缺工具环境仅确定性，开发Grok工具失败不算产品native验收。 |
| T10 | 审计精确身份→同具体型号→有标记基础降级；歧义／冲突保持未知，不复制渠道价格／额度／上下文。补Root relevant_indices及任务理由指引，不改Jev题义／阈值。映射／依赖回归通过。 | positive-final relevant coding/agentic来源使 recommended 与绑定hint实际影响K3派发；真实handoff_fit .92、member_task_fit .82，候选质量 .81/.46/.75。目录弱先验经AA/OpenRouter来源，推理／测量日期／方法／成本缺口保留；早先facts_only只算自主交接。GPT-6.1未知指标不等于弱，也未禁用GPT-6。 |
| T11 | 已观测402账户余额门归auth_or_quota，任务级排除跨产物更新保持；重试必须记录实际恢复依据，注明Root声明非程序证明；瞬时网络／格式失败有界。provider/runtime已有回归通过。 | 不为测试制造账户余额失败，不反复支付已知不可用套餐。本轮产品余额恢复／外部格式故障未自然触发；没有降低标签或完成门。 |
| T12 | 保留稳定签名／观察去重及权限裁决字段，汇总实际check跳过、Jev失败、通知与执行分别计数；真实call账本保持角色／类别及unknown。既有去重／runtime／resource tests通过。 | Controller两次只读status前后 Jev=5、check_started=2、finished=2均不变；没有付新模型调用。未做普遍现金收益对照，自动相同观察全组合／finding收敛历史欠账没有新增完成门。 |
| T13 | Root指引落实指定工具、可恢复阻断的有界核实、途中答复并继续、必要非敏感探查、准确内部协议与简报；成员票据／权限／失败停止条件按开发规则。 | 全程Herdr显式ID，未触碰Beacon/Zeen，不输出环境／认证原件。p2/p3承担局部实现及只读核查，p4不可用由主执行者接管；未将开发OMP冒充native成员或独立产品检查。空设备列表类外部环境未运行，不能宣称全部工具环境已测。 |

## 真实路径与失败保持

| 路径／构建 | 任务／结论 |
| --- | --- |
| negative，build1／negative-final，350d5530… | 两次单文件编辑＋Node严格断言通过；native task与任务记录均0，无派发建议或登记。 |
| 初始positive，build2 | `e5222c26…`：facts_only自主K3交接＋Esc confirmed stop；D1首轮读完要求却保持暂停，失败保留。 |
| D1补验，7a23f641… | `6cfc83bd…`：同原生Root新socket、新任务、原要求保留、旧成员未唤醒、真实推进／修订。测试随后明确暂停，剩余todo交付未完成；其程序状态paused及停止确认不冒充complete。 |
| positive-final，7a23f641… | `e5b6914d…`：recommended→原生task注册／实际模型→native结果／hub→Root阅读集成→10项测试＋CLI子进程→独立check1→complete、Root／成员／异步确认停止。 |
| visual，build2；visual-final，7a23f641… | 第一单独立实际看图通过但 model.input 来源null，不倒填；第二单model_image_input=true。第二单Root finish枚举盲试失败但真实视觉交付通过，登记缺陷保留。 |
| visual-finish，3ca7b455… | `75a062c2…`：Root单元accepted、独立看图、覆盖与stop通过，解决finish文档缺失。 |
| progressive，3ca7b455… | `96a75034…`：无催促的continue后真实执行、原生纠正落实、10项测试、check2 input-stale、check3有效手动终检（verdict=continue但delivery.ready=true且覆盖有效）、complete confirmed stop。 |
| 正常退出，7a23f641… | `187919fd…`：成员工作中Ctrl-D；paused、Root／成员active_tools=0、async_jobs_settled=true，进程退出且测试pane关闭。没有声称交付完成。 |
| 最终TODO补验，7f262f91… | `837c727c…`：新安装、新进程；Root单元accepted、独立只读图片检查、终检通知后实际整理其待办。原生 todo 回执 `bf59f397`（07:45:24.906Z）四项核验 completed，过期停止等待项移除；complete、confirmed stop、runtime_pid=null，退出并关闭pF。 |

控制者仅准备基线、图片和需求／真实用户纠正；未实现交付、制造Jev／finding或注入检查结果。最终手动检查排队后均让Root结束回合；控制者不编辑文件、发新要求或轮询Orbit状态，只读持久证据／Herdr。rebind语义未修改，历史rebind及自然finding争议、后备全组合保持未运行标签。

## 确定性验证与用量

相关既有测试先跑，再补历史回归。最后修正后的完整 `npm test` 通过（`full-test-completion2.log`，退出码0）；`npm pack --dry-run --json`、skill validator、`git diff --check` 均通过，未仅以局部单测结束。新增约10个主要行为组；测试净增314行（363新增／49删除）。超过300行建议的少量增量用于十三接缝的真实历史风险与原生来源防混入，不扩展理论边界或新增测试平台。

全套先后暴露两处旧fixture不符合新行为（错误文案、resolver只实现@task），修正其真实API假设；另一个status断言把start在途的合法旧定时读数也算作成功后残留，改核对start返回后的当前显示。另一次运行发现声明命令已被runtime消费，改核对真实CLI持久回执而非瞬时inbox长度；异步hint日志曾在1秒内未被观察到，保留实际dispatch门断言并有界等至3秒。未放宽业务／模型池／完成门，失败原件在临时测试log中保留。

实际资源按调用回执记录。例如positive-final：Root input=66858/output=3960/cacheRead=634624；成员18667/14978/71168；检查21751/1997/43520；Jev input=61048/output=474。progressive Root有一条unknown用量，停止验收中的被中断成员也有缺口。类别不可盲目相加为现金，订阅实际扣减／总金额仍unknown。没有同需求两臂成本对照，不宣称节省百分比或已知现金收益。

## 收尾

自开测试pane w23:p5/p6/p7/p8/p9/pA/pB/pC/pD/pE/pF 均在相关任务／执行停止、进程退出后关闭。9个程序任务 stop_confirmation.confirmed=true 且 runtime_pid=null；两条负例无Orbit任务。最终隔离安装按所属 runtime/bin 路径卸载，未发现所属活跃 Root／成员／检查进程。程序审计与Herdr现状保存在脱敏索引 cleanup（临时原件 process-audit.json）：Orbit workspace只剩控制者p1及预先p2/p3/p4，三位idle保留。原件留存供复核，没有关闭预先OMP、升级全局、提交推送或动外部会话。

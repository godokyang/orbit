# Codex 借鉴实施验收（2026-10-09）

2026-10-10 补注：本页保留前轮实际构建、通过／失败、Goal 回执和资源事实；候选“已有能力满足”的充分性判断已由[全部决定重评](codex-decisions-reevaluation-20261010.md)修正，尤其 C02/C04/C06/C08。不得用前轮有界验收推导 Goal 完整借鉴、无人工纠正或普遍资源节省。

状态：全部交付条件已通过，实际 Goal complete；无 token 硬预算。时间均为UTC，亚洲上海收口日期为2026-10-10。Goal实际完成工具回执：tokensUsed1046299、timeUsedSeconds5699（约95分钟），无tokenBudget；这是开发Goal执行计数，非供应商账单或本表模型调用token总和。唯一总 TODO 与冻结验收沿[实施清单](../plan/codex-lessons-implementation.md)。C01/C05/C07/C09代码、独立核查和必要真实验收已通过；C01真实降级失败修复后已在新安装检查输入复验，文档／资源收口亦已结束。失败和未跑不改成通过，T01—T13历史边界不重开。

## 基线、授权与责任

源码0.8.3，HEAD `9f5e66db681ac312d12f2f1f1c70cc804bcaad38`，dirty。保留原有索引／交接修改及四份未跟踪实施／上下文／研究文档；共享本仓执行，没有丢文档或并发写热点，没有开发worktree。Root负责采用、C05/C07/C09、集成及验收；固定K3负责C01两投影，Root独立核查；真实降级后Root补C01预算，固定GLM独立核查；Grok只读C02—C07，GLM只读C08—C10及采用项。开发回报不计产品运行证据。

固定资源：w23:p1 Root wrapper38007/Codex38008、shell37403；pH kimi-code/k3-256k OMP12801、shell11899；pJ cursor/grok-4.7-500k-fast OMP12883、shell12208；pK zhipu-coding-plan/glm-5.3-flash OMP12966、shell12485；Herdr服务2145、客户端2144。其所属MCP进程保留，其他workspace不碰。启动前保存panes/agents/process基线，之后按返回ID登记测试资源。

日常安装保持0.8.3／d947af6983c341429d597e9a494b4f4ef5880452／dirty=false，digest `5993d7fbde77cf3b466aa925df31844d30a977f2456acb6354ac539c84e3c493`，安装2026-10-09T08:16:15Z。没有全局安装、宿主、Fork、全局配置、权限或版本变更，没有发布、推送、提交或新外部账号。OMP实际18.8.0，隔离检查coding-agent SDK18.8.0、直接pi-ai/pi-natives18.3.4；版本不同不自行断言行为漂移。旧18.4.9安装修正仍保留其限定适用条件。

临时根 `/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-codex-lessons-xi_veusp`，安装采用 `install.sh --runtime-dir …/runtime --bin-dir …/bin --no-modify-path`。plain OMP配置未加载Orbit；所有产品Root经Herdr启动隔离安装的 `orbit omp`，不是普通OMP或Controller模拟runtime。配置／模型证据缓存使用当前用户池的临时副本，凭据只确认存在、不输出。

## 候选处置与实现

完整逐项证据沿总表。采用C01/C05/C07/C09；C02目标／修订／续接、C04登记／型号／结果归属、C06当前工具范围、C08跨语言schema已有能力满足。C03接收处原子expected-turn、C10完整请求容量调整条件未成立。没有新通用平台、预算或模型认证。

- C01：仅bash/eval output在JS4000 UTF-16单位和Ruby2000 Unicode字符内保留首尾，标记可见长度、字节数、SHA-256；上游output_omitted、来源、退出码／来源和版本匹配保留。command/script仍原策略，短输出不改，历史尾部不补造。真实普通字段125字符降级会挤掉全部正文，Root修复为日志最低500字符；其他字段继续降级，整体65536bytes硬门及无法容纳时显式省略全记录仍成立。
- C05：普通／失败停止也执行完成停止已有的耐久成员名单复核；晚登记或不可读名单保持stop_unconfirmed和实际已停止范围。未宣称全宿主原子关闭准入或失去session后有新退出证明。
- C07：真实取消／abort／reap后返回当前writer队列cutoff、append完成、已写seq、失败／gap和错误范围。append不等于fsync；日志失败不改变confirmed，export仍只读截取。真实I/O失败测试保留失败计数，恢复后写gap。
- C09：SDK公开errorStatus/errorId安全数值进入evidence.error.status/error_id，缺失null；分类、账户排除和恢复不改，公开消息没有retryAfter，不造字段。未人为制造真实账户故障。

C06实际成员npm test已通过字面命令声明门，随后Seatbelt拒绝读用户NVM npm-cli.js：现有系统库例外仅/usr,/System,/Library,/bin,/sbin,/opt，不包含~/.nvm，属既有read allowlist边界。放开需要新增workspace外读取权限，本轮保持权限、由Root验证。Root声明的node-inline placeholder不是实际命令，不扩字面匹配来迁就它。固定GLM核查了宿主／库源码和合同。C03原子接收、C05会话丢失、C06解析后统一目标接口保留上游限制，不用发送前读取或idle标签冒充证明。

## 工程验证与独立核查

采用前先相关已有测试。C01三个入口、少量长日志／双层／Unicode／降级行为回归、跨语言冒烟通过；Root补9,600个可达补充字符切点冒烟通过。真实降级修复把已有降级用例改为125字符风险，`check_runner_context_test.rb`通过，GLM只读核查PASS，未放宽权限或64KiB。

C05修复前后task_runtime通过，新增普通／失败晚登记与不可读名单回归，GLM独立复跑PASS。C07已有collab evidence的不可写目录→停止确认保留→恢复gap断言通过，GLM独立PASS；C09在既有4个provider-error用例补实际429/error_id659456及null断言，4/4 PASS，GLM独立PASS。Grok旧writer快照评语不当最终diff审查证据。

首轮及500字符修复后全仓npm test均exit0。pack dry-run83文件、skill validator（本机已有Python3.9）和diff检查通过。默认Python缺PyYAML的校验失败保留，未安装新依赖。最终83个pack文件按安装算法计算摘要，与3ea4a306…受测安装完全一致。

## 真实矩阵及失败记录

| 路径／task | 实际结果及边界 | 证据 |
| --- | --- | --- |
| 一文件负例92ad84c5 | GLM Root，无hint／原生成员／任务交接证据请求；两次独立检查通过，complete confirmed=true，writer4/4。start列8个检查模型缺证候选不等于交接研究请求，不认证fallback质量。Root40309、MCP40340/40384、checker44717/45586退出，pM删除。 | [negative](evidence/codex-lessons-20261009/negative.tar.gz) |
| 错接口校准9e5927f6 | Controller误写summarizeExpenses而SPEC要求importExpenses，不能计正例。facts_only，未登记成员；原生Esc暂停confirmed=true，writer4/4；Root47576、MCP47633/47672退出，pN删除。只证明Root及所属工作中断，无成员中断分支。 | [interrupt-calibration](evidence/codex-lessons-20261009/interrupt-calibration.tar.gz) |
| K3正例06484dc7 | 正确接口仍持续派发失败、facts_only、无成员；两次独立finding后Root回退实现，第三次complete/resolved并confirmed stop。输出先经head/tail裁掉，推荐／成员／C01链不通过。OMP49494、MCP49526/49566、checker51793/52463/53512退出，pP删除。 | [positive-k3-fallback](evidence/codex-lessons-20261009/positive-k3-fallback.tar.gz) |
| 正常退出e937aa5e | 原生Ctrl+D前task已complete/confirmed stop，writer4/4；不能称活跃checker取消。Root50660、MCP50690/50730、checker51337退出，pQ删除，无成员分支。 | [normal-exit](evidence/codex-lessons-20261009/normal-exit.tar.gz) |
| GLM交接1a683e0d | 版本绑定Jev推荐→native登记→真实成员调用→hub回报→Root集成127cases；独立finding修正后complete/confirmed Root及成员stop。Controller终检前一次过程纠正，监督介入不省略。SDK minimizer把8853bytes输出变248字符+artifact链接，C01未触发。Root54009/MCP54039/54078/checker60946/62174退出，pR删除。 | [positive-glm-corrected](evidence/codex-lessons-20261009/positive-glm-corrected.tar.gz) |
| 原始输出8436644f | 会话公开shellMinimizer.enabled=false，推荐／登记／成员／hub／集成127cases／独立终检／Root成员stop通过，无Controller过程纠正；JS4000首尾正确，Ruby实际125预算交付128字符marker-only，C01 **失败**，context54527bytes。Root62988、MCP63060/63099、checker64561退出，pS删除。 | [positive-raw-failed](evidence/codex-lessons-20261009/positive-raw-failed.tar.gz) |
| 修复构建C01正例9f47f925 | 新安装、fresh importer/CLI stubs，Root／登记成员实际交付，127cases通过；独立手动check2 complete、non-stale，Root及成员confirmed stop，writer14/14无gap。JS4000→Ruby500两端及上游omission／退出来源／版本绑定实际保留，context51465bytes。初次native task工具列表失败，随后eval agent未登记，Controller一次纠正；返回改为native task/yield自动送达，不冒称新显式hub/hint_followed事件。Root70163/MCP70203/70256/checker71459/73798退出，pT删除。 | [positive-fixed](evidence/codex-lessons-20261009/positive-fixed.tar.gz) |

负例首次安装digest `b4d7513dbd55f292dc0ab933d70494111983479ab01f298a5b1f7af3eb3388e3`；其余前五路径最终安装digest `3f61961a946bf3752f763030ecec60a386d2a73a75a4fab5d302591d02a0681d`、2026-10-09T15:05:14Z。两者功能相同，后者多C05合同说明。修复安装digest `3ea4a306fea2bbf7e2bb65b8981858b96c31351aea41009ca0a3b37e03a1e9ef`、2026-10-09T15:54:37Z，所有构建均源码0.8.3、同HEAD dirty，不重标旧失败。

GLM交接实际Typesafe Jev1.13.0，校准bounded_git_delivery_v1放行；delegation-4 handoff_fit0.86/member_task_fit0.72、candidates-4首选quality0.74，input jev-selection-input-2／decision orbit-quality-decision-4。wu-2a8236b781691fba的hint15:23:28Z、成员orbit-ace1049a登记15:24:29Z、hint_followed15:24:30Z、首真实opencode-go/deepseek-v4.1-flash调用15:24:33.886Z、原生回报15:35:07Z。权限导致成员未验证，Root实跑127cases；第一次独立check发现readme-example-count-mismatch，Root修正并实际核对示例，第二次resolved同ID。Root成员confirmed、active_tools_after0、async_jobs_settled=true，writer55/55无gap。

原始输出正例成员orbit-61730cca由真实hint选择opencode-go/deepseek-v4.1-flash，Root承担所有shell验证。手动终检只读固定快照；终检排队后Controller只观察持久文件和Herdr，不发状态轮询或改产物。独立检查各自run/scope/evidence保存SDK18.8.0、独立PID、工具仅glob/grep/read、forbidden=[]、confined=true、privateRegistry OrbitReviewer／globalRegistry为空、before/after固定快照fingerprint相同。修复正例亦按该纪律观察：check1是自动process_reviewer，host-stale／continue，不计完成；check2是有效独立手动reviewer，固定快照前后fingerprint相同，complete且无finding。成员orbit-0e13fa8b登记16:00:36Z、首模型调用16:00:38.186Z，实际opencode-go/deepseek-v4.1-flash。本轮修复只动Ruby日志预算；推荐／显式hub／finding纠正路径复用未变化宿主代码的先前GLM实证，不把旧构建标成新构建重跑。

模型事实为带来源／日期的发行方或分发方规格和有限先验，不能认证精确渠道编码成功率。临时缓存原稿两条input_modalities=1与text+image basis矛盾，原稿留档，新测试副本删掉未核实指标；来源／其余值／阈值不变。新的事实提交失败同样按实际记录，不替Root造值或打分。

## 资源与限制

[实际调用用量索引](evidence/codex-lessons-20261009/resource-usage-index.json)按task、role、phase、actual provider/model和来源单位汇总，包括失败／校准／重做，保留每字段reported_sum/reported_calls/missing_calls。SDK input/output/cacheRead/cacheWrite/totalTokens不重复相加，reasoning为output子集；Jev沿其原单位，不换算现金。账本只能证明已持久调用范围，不能推算现金、套餐扣减、未知配额或普遍节省；Root Codex供应商分类回执不可得，Goal tokensUsed也不混作账单。Parallel检索未有费用回执，未知。

三个固定开发OMP从Goal启动14:37:13Z后的原生assistant回执窗口（非任务精确账单），下表为C01补修复独立核查前的冻结窗口；补核查用量单独保存，不改旧窗口。

| 角色／实际型号 | 回执 | input | output | cacheRead | cacheWrite | reported totalTokens | reasoningTokens |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| K3 C01实现 | 58 | 99961 | 37290 | 3511296 | 0 | 3648547 | 未报告 |
| Cursor Grok C02—C07审计 | 6 | 456076 | 63122 | 4674432 | 0 | 5193630 | 45654 |
| GLM C08—C10／采用项核查 | 87 | 316234 | 49535 | 8356864 | 0 | 8722633 | 35468 |

GLM补C01核查窗口另有4条回执：input8287、output4901、cacheRead658880、cacheWrite0、totalTokens672068、reasoningTokens3992，单位token。新正例未登记eval子作业3条SDK回执单独纳入索引（不算受控成员）：input16035、output6461、cacheRead20608、totalTokens43104；reasoning4757仅2条报告、1条未知，SDK估价不当实际扣费。该子会话已yield Result submitted，随后h.cancel因句柄过期返回unknown，不把这个失败取消回执称成功；最后Root owner-scoped jobs settled、OMP进程退出提供实际收尾范围。

旧未测自然分支、C05失去session、全宿主原子准入、完整请求超限、真实账户失败status诊断仍有界／未跑，不重新列本轮TODO。SDK先于Orbit的minimizer可能丢原文，Orbit只保存实际可见输出，不从artifact链接补造正文。可比较的成本／监督基线没有，本轮不能宣称资源节省或消除用户纠偏。

本轮七个测试pane及已知所属工作均退出后关闭，夹具／会话／独有overlay已删除；临时安装按支持的uninstall路径已卸载。最后资源基线、逐项身份／退出确认、开发用量补录、构建摘要、独立核查及验证日志已保存于[资源归档](evidence/codex-lessons-20261009/delivery-resources.tar.gz)，临时根／pointer／本轮验证日志及SUT创建的/tmp/model-evidence.json已按归属删除。最终workspace只剩原四个pane，固定13个Root／OMP／MCP／Herdr进程PID全部存活；日常安装摘要与开工一致。按用户要求必要证据先保存，归属不明资源不删；固定Root、三个OMP、Herdr及所属固定进程保留。

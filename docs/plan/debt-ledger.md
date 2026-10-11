# Orbit 当前限制

最后核对：2026-10-11（本地检查宿主与历史内容归档修复；源码0.8.5，实际安装与Goal状态见[交接](handoff.md)）。本页只列**当前仍影响用户的限制与未测范围**；已修复项、旧版本流水与已结束票据不在本页保留（`git show 3865b76:docs/plan/debt-ledger.md` 查阅历史）。逐项收口与证据＝完成记录（Git 历史：`aa089bb:docs/reference/mixed-model-delivery-completion-20261001.md`）；现行行为以[合同](../../contracts/task-runtime.md)及 ADR-008/009 为准。

| 限制 | 当前影响 | 解除条件 |
| --- | --- | --- |
| 本地 OMP 复用的实测范围有限 | 临时安装不含私有SDK，macOS/18.8.0可信factory、受限工具/图片字节、真实检查、失败/取消及停止已通过；日常安装未更新，其他宿主/平台未认证 | 其他宿主版本先跑实际能力探针，再验证相关真实路径，不继承18.8.0结果 |
| Zeen旧数据暂缓，旧摘要异常成因未确认 | 新检查重复增量0、小改动102bytes/4KiB、三门回收/异常保留、历史恢复、自包含导出及旧完整目录兼容已实测。Zeen既有309份工作区/29.22GB和181摘要不符/1缺失保留原诊断，成因未裁定 | Zeen存量迁移/预览/清理未授权，不作为本轮验收条件；单独确认成因及方案后处理 |
| 显式start选模未持续绑定后续reviewer选择 | 本轮failure-v4 start记录显式Zenmux，实际check重新从池选DeepSeek；runner严格使用当次请求型号，process-failure后自动fallback也未受Root“不换型”文字要求约束 | 单独修正CLI记录/selector显式绑定与失效规则，并明确程序fallback与用户指定的优先关系；本轮未扩修选择层 |
| 原生会话材料导出仍有缺口 | 本轮正例export missing2：一条不可安全归属协作行、一个成员native transcript身份无法核验；失败/取消各有一条协作子集缺口。历史workspace已自包含，manifest保留实际缺失 | 单独核对native session/成员身份接缝与协作截取；不因完整历史快照而宣称所有会话材料完整 |
| 空闲 Root 的 Esc 不等同任务暂停 | 本轮在 private checker in_flight、Root 已空闲时按 Esc 未触发 native interruption，检查随后正常完成；活动 Root／登记成员 Esc 确认暂停另有实证。不能把按键发送回执当停止成功 | 需要支持该 UI 场景时另定正确用户入口和宿主接缝；本轮仅记录真实边界，不改暂停语义 |
| 活动任务续跑的有效推进证据有范围 | C02已沿SDK每请求context派生完整授权目标；普通/amend/custom wake/compact/resume及暂停分离有界实测。continue_unfinished_task仍依赖自动artifact review且每版本一次，不能把工具次数当进展；该具体空闲续跑分支本轮未自然触发 | 真实分支出现后按现行版本核对，不重新打开历史理论组合；SDK hook超时/异常和最终请求容量仍是宿主边界 |
| 成员派发失败恢复仍有范围 | C04已补实际tools挂载、agent/model和spec/operation层级诊断，当前真实Missing context/声明失败后改调用、成员缺content/命令不匹配后修正并通过npm。v5重复8次缺content仍需Controller取消；v6只有yield却自述hub成功，不能据有界恢复断言通用闭环充分 | 以最新真实完整矩阵验证采用范围；新实际失败再定点处理，不支持全部eval或维护Fork，不把Root自述和接管当委派成功 |
| 成员便捷记录的单位关联字段有空值 | 本轮v7第二成员state.work_unit_id为null，durable work-unit的member_id/dispatch call_id及实际scope/结果完整；只读members行的消费者会缺少便捷关联，不能填造unknown | 单独同步已验证的durable绑定到便捷成员记录并定点验证；当前真实归属沿权威单位记录，不扩成新协议框架 |
| 程序 integration 选型 live 未触发 | 实现已装并经确定性验证；真实运行从未进入其前提（manual-ready 窗口＋真实 resolved finding）。注意区分：Root 的 `root-model` 工具选模不受该前提约束，其 live 未触发只因为没有运行需要换型 | 真实路径出现后核验；不人为制造，非完工门 |
| 非 stale process finding→纠正→恢复组合未实测 | 共用送达路径源码完整且 artifact 孪生已 live（033）；组合自然分支未出现 | 真实路径出现后核验；不加证明门 |
| Root 停止自有 queued marker 分支仅确定性证据 | 0.7.37 修复经 gate 验证；真实搁浅 marker 现场未再出现 | 真实路径出现后核验 |
| park/dispose 后退出不可证实 | 已完成成员 park 后失去 session；不能把 idle、cancel 回执当退出，保留 `stop_unconfirmed`。前轮名单复核保留，本轮接入实际hasAdmittedSubmission忙态并实测活动成员Esc/正常退出；仍不解除失去全部session或宿主原子准入限制 | 上游提供 dispose 完成信号并验证 |
| 上游 provider/控制钩子缺口 | `devin-agent` 类不触发 `before_provider_request`；部分异常不能可靠 fail-close；单成员编程 kill、已 park 工作与保留名碰撞受上游接口限制 | 实证最小缺失接口后按 ADR-008 跟进，不预维护 Fork |
| 自动入口失败时未知请求体 | 已核对的 OMP messages / Responses 可传恢复提示；不能安全识别的请求体仍中止 | 取得实际请求体与返回契约并隔离验证 |
| 历史读取有前置条件 | 需已加载且具备历史读取能力的持久会话；ephemeral／未物化会话不支持 | 原生接口具备能力且有明确需求后适配 |
| 异常退出时协作日志仍可能缺失 | 可归属事件已另写 `collaboration.jsonl`；本轮C07在Root停止后增加当前进程writer队列切点append诊断，仍不保证硬崩溃、后续事件或旧任务完整；异步写入未完成／失败仍可能丢失，导出继续按实际截取显示缺口 | 可恢复事件流或同步确认边界＋真实异常退出验证 |
| 整次任务费用与现金归属 unknown | 失败检查 usage、Root/成员归属、实际路由价格、订阅消耗与**现金/实际扣减**仍可能未知；交叉单价不能判总成本；`cash []` 只表示未知不是 0 成本；账户／OAuth 归属可得性按各任务原件报告范围区分 | 不新增结论；有第一方可信来源时按合同口径核实 |
| 选型/收益效果的有限范围 | W9 单任务配对：旗舰 observed 0 vs 7、其他角色开销更高（unknown 分列）——单任务范围；更早 pair4 对照为负（+134.665%）保留不改判；域外泛化未证 | 真实任务自然累积；不宣称普遍节省 |
| 独立检查投入较高 | 历史样本数万至数十万 input token；同质两臂质量无差异但经济收益未证明 | 同条件比较整体交付/返工/核验/人工投入后按需压缩 |
| OpenRouter 映射覆盖不全 | 已审计映射及同具体型号／有标记基础降级已接线并有界实测；歧义、冲突和未匹配身份仍 unknown；测量日期/方法多数 unknown，映射命中不是费用或路由质量证明 | 补第一方来源映射并核实测量日期；无全型号认证门 |
| 工作区冲突不自动暂停检查 | 程序不检测 Root 声明产物位置与绑定冲突 | 单独明确检测与暂停语义并取得真实路径证据 |
| 语义同义 finding 不自动合并 | 依赖检查者复用已有 id，不猜不同 id 语义相同 | 有实际重复误报证据后再定显式对照方案 |
| 用户NVM运行时不在成员读例外 | C06真实npm进入Seatbelt后读取~/.nvm npm-cli.js被拒；当前保持边界，已接静态首跳、实际cwd和已知node→npm包根诊断，不新增NVM读权限；项目.runtime完整材料、项目内TMPDIR已在v4/v6原生成员实际npm127通过，不扩大NVM读取；复杂依赖/其他shell形式仍unknown。v2/v3包读取EPERM和Controller取消保留，Root绕行不算成员恢复 | 其他真实运行依赖需要额外外部读集时先说明具体路径/影响并由用户决定；继续按具体依赖准备项目材料，保持越界拒绝 |
| eval agent不属于已接线受控成员入口 | C04真实正例的eval agent未登记，不计Orbit成员；改走既有原生task/hub后完成。收尾证据只含该子会话已yield、Root owner-scoped jobs settled及进程退出 | 如决定支持该入口，先核实宿主注册／范围门／用量与停止接缝；当前不扩产品接口 |
| `needs_user` 终态不可接续 | `resume_from` 只接受已确认停止的 `paused`；Loom 的“手机答复后继续”无合法接续路径。接续还要求一条真实的原生用户消息，外部答复须先以原生用户消息进入同一 Root 会话 | 用户决定是否放宽到 `needs_user`（改 ADR-008 与任务运行合同，并做真实验证）；放宽后在集成合同 `resume_from.from_status` 增补取值（次版本） |
| 集成合同真实验证范围有限 | 假调用方对真实 CLI／运行时／存储，但 OMP Root 会话与检查模型是替身。`ref` 已做一次小样本真实检查（1 个模型、7 次：带编号 12 项只有 1 项填了 `ref`，无自编；1 次写空串，已在合同 1.1 放宽）；合同 1.2 已有 OMP 18.9.0/macOS 单模型真实 RPC 证明首消息前通道/显式启动与引用回读/停止退出；多模型/更多次数、外部引用经自动入口建任务均未实测；Loom 的持续集成尚未对最新版运行 | 更多模型/次数的真实验收；确定自动入口是否需要入队式追加外部引用 |
| 合同 1.3 真实分支范围有限 | revision/attention/latest_check 已实现，npm 与独立 save 审核通过；真实任务变化、稳定读、实际 tick、重启不回退与失败检查摘要已核验。成功检查、complete/needs_user/stop_unconfirmed/reworking/unknown、stale/旧 scope 回退未真实认证；原驱动错误保留 | 真实场景出现后按[验收记录](../reference/loom-integration-acceptance-20261011.md)核对对应分支，不从确定性覆盖推导模型表现 |
| CLI 冷启动任务与原生宿主绑定有缺口 | 本轮隔离 OMP 18.9.0 外部模式下 CLI --prompt-file start 建立记录后运行时因 hub_events requires a bound task session 失败并确认停止；Root 原生 Orbit start 路径可执行，但不等于修复外部 CLI 全流程 | 单独核对 CLI start 后任务登记/宿主绑定接缝；本轮只交付合同状态字段，未扩大修改产品启动协议 |
| 指定控制通道的跨平台/文件系统范围有限 | 内部 Unix socket 通过硬链接暴露调用方路径，需两目录同文件系统且支持 socket 硬链接；macOS 已实测，Linux/其他 OMP 版本未认证，失败拒绝而不覆盖 | 有调用方真实需求时在对应平台/文件系统按[合同](../../contracts/integration.md)验证，不由单平台推断 |
| 对外有序事件流（提案 C）未做 | 内部 `events.jsonl` 无序号、类型多且不稳定，不对外承诺 | 集成方真实运行中关键过程丢失且无法用 `export` 补回，再评估 |
| 外部引用不随 `resume_from` 继承 | 接回的新任务需调用方重新传入 `external_refs` | 调用方明确需要继承时再定，属可加性改动 |

Root 故障只记录，不自动替换或恢复模型执行。新供应商、全局调度和复杂统计平台不因列入限制而获得实施授权。

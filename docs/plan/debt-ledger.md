# Orbit 当前限制

最后核对：2026-10-10（当前剩余能力交付已收口，实际 Goal complete；源码 0.8.3，实际安装身份见[交接](handoff.md)，不更新用户全局安装）。本页只列**当前仍影响用户的限制与未测范围**；已修复项、旧版本流水与已结束票据不在本页保留（`git show 3865b76:docs/plan/debt-ledger.md` 查阅历史）。逐项收口与证据＝[完成记录](../reference/mixed-model-delivery-completion-20261001.md)；现行行为以[合同](../../contracts/task-runtime.md)及 ADR-008/009 为准。

| 限制 | 当前影响 | 解除条件 |
| --- | --- | --- |
| 活动任务续跑的有效推进证据有范围 | C02已沿SDK每请求context派生完整授权目标；普通/amend/custom wake/compact/resume及暂停分离有界实测。continue_unfinished_task仍依赖自动artifact review且每版本一次，不能把工具次数当进展；该具体空闲续跑分支本轮未自然触发 | 真实分支出现后按现行版本核对，不重新打开历史理论组合；SDK hook超时/异常和最终请求容量仍是宿主边界 |
| 成员派发失败恢复仍有范围 | C04已补实际tools挂载、agent/model和spec/operation层级诊断，当前真实Missing context/声明失败后改调用、成员缺content/命令不匹配后修正并通过npm。v5重复8次缺content仍需Controller取消；v6只有yield却自述hub成功，不能据有界恢复断言通用闭环充分 | 以最新真实完整矩阵验证采用范围；新实际失败再定点处理，不支持全部eval或维护Fork，不把Root自述和接管当委派成功 |
| 成员便捷记录的单位关联字段有空值 | 本轮v7第二成员state.work_unit_id为null，durable work-unit的member_id/dispatch call_id及实际scope/结果完整；只读members行的消费者会缺少便捷关联，不能填造unknown | 单独同步已验证的durable绑定到便捷成员记录并定点验证；当前真实归属沿权威单位记录，不扩成新协议框架 |
| 程序 integration 选型 live 未触发 | 实现已装并经确定性验证；真实运行从未进入其前提（manual-ready 窗口＋真实 resolved finding）。注意区分：Root 的 `root-model` 工具选模不受该前提约束，其 live 未触发只因为没有运行需要换型 | 真实路径出现后核验；不人为制造，非完工门 |
| 非 stale process finding→纠正→恢复组合未实测 | 共用送达路径源码完整且 artifact 孪生已 live（033）；组合自然分支未出现 | 真实路径出现后核验；不加证明门 |
| Root 停止自有 queued marker 分支仅确定性证据 | 0.7.37 修复经 gate 验证；真实搁浅 marker 现场未再出现 | 真实路径出现后核验 |
| 检查者 SDK 18.4.9 暂存源码修正 | 官方包 sdk.ts 的 ratchet/prelude 导入被 Bun 解析成同名 .js 注入脚本；安装器仅对实际 18.4.9 的已核实一行显式指明 .ts，用户宿主不变，差异已由 OMP2 独立核实 | 上游修复且实际目标版本验证通过后删除此版本限定修正，不扩展 SDK fork |
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

Root 故障只记录，不自动替换或恢复模型执行。新供应商、全局调度和复杂统计平台不因列入限制而获得实施授权。

# Codex 借鉴决定重评（2026-10-10）

后续实施状态：用户随后已授权剩余问题整轮交付，新的实际 Goal 已最终complete，C02/C04/C06/C08 按[唯一总清单 §9](../plan/codex-lessons-implementation.md#9-剩余问题交付2026-10-10当前执行)推进。本文的“建议未实施／未创建Goal”是该次重评阶段事实；不替代后续实现、独立核查和真实验收。当前五维处置沿[实施 §9](../plan/codex-lessons-implementation.md#c01c10-当前五维处置)，新运行、失败及资源沿[2026-10-10验收](codex-lessons-acceptance-20261010.md)；C02/C04/C06/C08已经局部实施，必要正例仍在复验。

状态：**全部 C01—C10 及既有采用原则已评估；新增建议尚未实施，不产生新产品语义。** 结论：保留四项局部实现及其验证边界；撤回 C02/C04/C06 的充分满足结论，优先处理活动目标推进、可用交接与失败恢复。用户随后要求记录 C08 单一协议定义方向，纳入下一轮局部采用方案；C03/C10 暂不扩大实现。C01/C05/C07/C09 的“保留”不表示整体控制机制已足够或具有大型项目成熟度认证，具体判断见下文补充。

Root 负责 Orbit 源码、归档产品证据及裁决；按 [research skill](/Users/yangke/.agents/skills/research/SKILL.md) 和 [Herdr skill](/Users/yangke/.agents/skills/herdr/SKILL.md)，复用固定 w23:pK 的 GLM-5.3-Flash 核查 Codex 源码。Root 独立检查成员回报并纠正不成立的反证；没有新建 Agent／pane，没有内部 Codex subagent。本次未运行 Codex 或新的产品验收。固定提交源码、原研究、当前实现和实际受测范围分别作为证据，不互相替代。

## Orbit 对照与重新裁决（Root）

本节是本次评估结论和建议，不是已实施的产品决定。基线仍为源码 0.8.3、HEAD `9f5e66db681ac312d12f2f1f1c70cc804bcaad38` 加前轮未提交修改；本次未改变运行代码、合同、ADR、模型池、权限或用户安装。

### 先纠正评价方法

前轮做成了 C01/C05/C07/C09 四项局部修改，也验证了部分既有链路。但将 C02/C04/C06/C08 统称“已有能力满足”，把“存在相关代码、当前权限合理、没有定位新错误”当成了方向性问题已解决，结论过宽。前轮验收中反复错误派发、一次非受控 eval 子作业、环境权限阻断、Controller 过程纠正和 Root 接管，都必须进入采用判断。前轮实际 Goal 的 complete 回执与已通过的具体代码验证保留；它们不能作为“完整借鉴了 Goal 机制”或“减少监督已证明”的证据。

同时，最近讨论中“Orbit 只有提示、没有自动续跑”的说法也不准确。[TaskRuntime](../../lib/orbit/task_runtime.rb) 已有 `continue_unfinished_task`（当前 3277 行）和 `observe_continuation_progress`（3309 行）。重评应补足缺口，不否认已有实现来制造新功能需求。

本次评价使用三个不同问题：机制是否存在；在授权范围内是否真实可用；是否改善交付与监督投入。前一个问题为真，不推导后两个为真。借鉴价值取决于具体失败、已知结构缺口、验证办法和维护代价，不能用新增代码数量、Codex 的功能名或用户提出过某个方向直接裁决。

### C01—C10 的最终重评表

| 项 | 前轮处置 | 本次结论 | 依据、代价与下一步 |
| --- | --- | --- | --- |
| C01 日志首尾 | 采用完成 | **保留实现，限定保证范围** | 原前缀裁剪确实会丢尾部；真实链路发现 Ruby 125 字符预算只剩标记，修复后 JS4000→Ruby500、51465 bytes 的实际检查输入保留两端。保留来源、结果、版本和截断事实有价值。500 字符最低日志预算会挤占其他上下文，外层仍可能明确省略全记录；SDK 更早裁掉的内容不能恢复。无需再做通用压缩平台。 |
| C02 目标／推进／恢复 | 已有满足 | **撤回充分满足结论；优先补全活动任务的交付反馈** | 原要求、amend、下一动作、暂停后续接已有；自动未完成唤醒也已有，但依赖自动 artifact review、每个输入／产物版本仅一次。新工具回执只能证明执行，不证明有效进展。本轮归档正例没有触发该续跑分支，不能靠确定性测试或状态提示断言整个反馈有效。优先评估目标投影、真实等待、无进展修正、失败升级和终检请求的连续行为；复用 task 记录，不先造独立 Goal 数据库。 |
| C03 接收处回合条件 | 原子接口条件未成立 | **保留上游依赖判断，缩小适用面** | 原生消息／输入／产物版本门有价值；发前读取不等于接收处原子条件。仅依赖当前回合的 steer／interrupt 需要 expected-turn；持续有效 finding 仍按要求与产物版本，不绑定任意已过期回合。不维护 Fork 或另写回合执行器。下一步是具体 SDK 接口需求；局部准备措施不能宣称补齐原子性。 |
| C04 成员交接与归属 | 原生路径已有满足 | **复用底座，撤回“可用交接已满足”；优先修失败恢复** | GLM 1a683e0d 的推荐→登记→成员调用→回报→集成成立；K3 06484dc7 却反复派发失败，无成员，最后 Root 回退；修复正例 9f47f925 先用错 native task 参数，再转 eval agent 未登记，Controller 纠正后才走受控原生入口。应围绕实际宿主工具形状、可执行材料／范围交接、错误分类和一次有效修正补接线，避免同错换入口继续烧资源。不要把支持全部 eval 子会话作为默认目标，也不要重写宿主执行器。 |
| C05 停止准入／退出 | 采用完成 | **保留补丁，不称完整停机协议已解决** | 普通／失败停止缺少耐久名单复核是真缺口，现有补丁与回归成立；真实 Root／登记成员停止有范围证据。停止后读名单仍不是原子关闭新工作准入，失去 session 后 dispose 退出仍不可证明。继续保留 stop_unconfirmed；完整关闭接缝优先作为 OMP 上游需求，不为此引入 Fork。 |
| C06 执行目标与权限 | 当前语法已有满足 | **安全约束保留；撤回“合法工作可用已满足”；优先核对环境与修正入口** | 1a683e0d 的成员 `npm test` 已获字面命令许可，Seatbelt 随后拒绝读取用户 NVM 的 npm-cli.js。拒绝符合当前权限，但说明获准命令不等于可执行。`validateWorkUnitPreflight`（work-unit-scope 当前 506 行）核对工具、材料、路径和沙箱入口，未证明所需执行依赖可读。建议在实际失败／任务相关环境上做有界可用性核对，明确由谁验证和如何恢复；不能在派发前运行任意获准命令，因为它可能写文件或产生其他副作用。新增具体外部读范围属于用户权限决定，不自动放开整个 ~/.nvm，也不自动放开网络。 |
| C07 关键事件确认 | 采用完成 | **保留实现，不推广所有事件同步写** | 停止后 writer cutoff 的 append 结果、seq、gap／失败范围能使证据完整性可观察；取消／abort／reap 优先、日志失败不改变真实 stop 是正确取舍。它不是 fsync、崩溃恢复或完整资源账单。暂无证据支持扩大到全部日志同步或另建事件平台。 |
| C08 跨语言协议 | 已有满足 | **纳入下一轮局部采用方案；以现有 schema 为单一结构定义源** | JSON schema、TS `validateCheckResult` 与 Ruby `validate_result`／`validate_coverage` 确实存在；后两者手写重复字段、枚举、额外键、coverage 规则。重复维护本身足以支持局部改进，不必等线上漂移。结构定义尽量从现有 schema 复用／派生，保留必要语义校验，并用少量共享样例核对两侧一致性；具体生成范围和依赖待实施前核实。用户要求先记文档，当前未改代码、不建全仓生成框架、不换 Rust。 |
| C09 故障事实与恢复 | 采用完成 | **保留诊断补充，不声称闭合恢复** | SDK 公开 status/errorId 的结构化保留是明确低成本增量；现有分类、账户排除与恢复规则保持有价值。status 不能独自判断额度，也不能自动重新启用失败目标；真实账户故障诊断本轮未诱发。派发工具形状错误、环境阻断属于 C04/C06 的失败恢复，不能靠这两个 provider 字段替代。 |
| C10 完整请求容量 | 调整条件未成立 | **维持暂不自适应预算；撤回“64KiB足以证明请求容量”的任何外推** | 程序上下文上限不包含独立原要求、工具、后续读取、输出预留与宿主历史，目录规格也不是实际路由保证。本次没有请求溢出原件，不按目录自动加减预算。若后续修改目标投影／交接链，核对实际最终请求组成及未知项即可；发现超限或明确近限后再做定点策略，不扩常驻统计平台，不默认减少验收输入。 |

这里的“优先”是本次建议，不是新增实施 TODO 或已生效语义。四项已实现的补丁不因优先级重新排序而回退；三项交付问题需要补路线；C08 的局部采用方向已按用户要求记录，具体代码尚未实施；两项宿主／容量方向不立即扩大实现。

### C08 补充：借鉴单一协议定义，先落文档

用户在核对 Ruby 与 JS/TS 分工后要求先记录 Codex 的做法。固定提交中的 App Server 协议在一个 Rust 类型上声明 `Serialize`、`Deserialize`、`JsonSchema`、`TS`（例如 [TurnStartParams](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/protocol/v2/turn.rs)），再由[生成器](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/export.rs)导出 TypeScript 类型与 JSON Schema。这里核对的是 App Server 协议，不声称所有 TS SDK 类型和业务校验都由此生成。

Orbit 的下一轮局部采用方向：以已有 `contracts/check-result.schema.json` 维护共有结构，减少 TS/Ruby 对字段、枚举和额外键的手写重复；类型与结构校验如何从它派生，先核对两侧工具和维护成本。非空／长度等边界要保持单位明确，coverage、完成资格、身份与版本等语义约束不得因生成而放宽；少量共享协议样例核对两侧接受／拒绝一致性。只增加样例可以发现漂移，不能宣称已消除重复维护。

该方向不要求合并语言、引入 Rust 或建设全仓生成平台。当前授权是先记录方案，未新增依赖、运行校验实现或产品语义；下一阶段仍沿唯一实施清单推进。

### C01/C05/C07/C09 补充：实现来源与“足够使用”的判断

用户进一步提出：跨语言重新实现会不会使控制门失去大型项目验证。前轮已有固定提交源码研究及 Orbit 接缝对照，不是仅观察 Codex 表现后凭印象重写；当前代码是按 Orbit 的 JS/Ruby/TS 和 OMP 公共接口另行实现，没有直接移植 Codex Rust 模块。开发记录未证明每个写者都亲自重读对应 Codex 全链，也没有逐条行为等价认证；这些未知不能补写成已做。

原实现来自 Codex 或原样复制，也不能继承其测试和实际使用结果：容量单位、调度与队列、文件系统、宿主成员生命周期和错误接口都可能不同。Codex 开源项目规模不是这些具体模块已在何种大型项目／负载下通过的证明；本次没有这样的生产遥测或长期配对数据。Orbit 的把握只能来自自身代码审查、关键不变量、真实失败回归与产品路径证据。

| 项 | Codex 机制与 Orbit 实现差异 | 目前有依据的使用判断 | 仍不能宣称 |
| --- | --- | --- | --- |
| C01 | Codex 是按 bytes 增量维护 HeadTailBuffer；Orbit 对两处已采集字符串按 JS UTF-16／Ruby 字符预算裁剪，另有 SHA-256／截断元数据与日志最低500字符空间 | **当前日志投影范围可保留使用。** 已有短日志／非日志边界／Unicode／双层降级回归，真实 marker-only 失败修正后在检查实际输入复验 | 原始完整日志可恢复、任意大任务上下文永远装得下，或裁剪不会漏掉中部重要事实。当前没有证据要求为获得 Codex 名义成熟度而重写为流式字节缓冲。 |
| C05 | Codex 在自身 runtime 关闭成员准入并等待 membership 排空；Orbit 本次仅把停止后的耐久名单复核推广到普通／失败停止，晚登记／不可读保持 stop_unconfirmed | **补丁本身应保留；完整停止能力仍不足以作强保证。** 回归覆盖晚登记与名单不可读，真实 Root／登记成员停止有范围证据 | 全宿主原子关闭新工作准入，或失去 session 后 dispose 已退出。重点后续工作是核实最小宿主准入关闭／可等待清理接口；再加 Orbit 控制门或自己的 Promise 不能补齐。 |
| C07 | Codex Persist／Flush／Shutdown 有 I/O 回执；Orbit 在先取消／abort／reap 后等待当前 writer 队列 cutoff，超时／写失败单独标记，保存 seq／gap 范围 | **作为当前进程写入诊断可保留使用。** 不可写目录→停止 confirmed 保留→恢复 gap 的实际文件 I/O 回归已通过，真实停止有 checkpoint 记录 | fsync、硬崩溃恢复、所有旧／后续事件完整，或日志失败会使实际停止自动失败。若交付将来依赖强持久化，需要另行明确语义和对应实现；当前不升级成该承诺。 |
| C09 | Codex 提供自己的结构化错误与 RetryAfter；Orbit 复用 OMP SDK 分类，本次只增加公开 status/error_id 的安全数值透传，缺失 null | **当前诊断增量可保留使用。** 已有错误回放及4个分类用例验证，现有分类／账户排除／恢复不改 | 完整故障恢复已闭合、上游未公开的 retry-after 已取得，或本轮真实诱发并验证了新账户故障诊断。它不是新恢复控制器。 |

结论是按职责保留，而非四项一概“已足够”：C01/C09 是有边界的局部策略／诊断；C07 的充分性限 append 诊断；C05 保留防误确认补丁，同时保留未解除的宿主关键缺口。当前不因未经大型项目认证而整套重写，也不借局部通过授予更强控制保证。后续核查聚焦已知缺口和上述不变量，不把所有历史未测分支重新列为必须重跑。

本次补充重新读取四项代码差异、相关已有回归断言、前轮受测与失败记录，并重新取读固定 Codex 源码；没有改产品代码、重跑既有测试或启动新的模型产品任务。源码比较不是新的 live 验收。

### Goal 具体值得借鉴什么，哪些不适合照搬

Codex 固定提交的 Goal 不是一个名字或单条提示：它把持久目标、空闲生命周期准入、目标原文投影、自动 turn、错误与空响应抑制、用量记账接在一起（见本页源码核查附录）。其中“有价值进展／已验证等待／无进展”和逐条完成审计，部分是模型提示要求；程序对特定错误与空响应可做限制，不等于程序已证明每轮交付质量，也不证明它比 Orbit 在本任务上更省资源。官方[Goal 说明](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)可作为行为入口，技术裁决仍使用固定提交。

Orbit 应借鉴的是**活动且已授权任务的交付反馈接线**：沿一个 task 的原要求及有效修订，空闲后判断剩余工作／真实在途等待／具体阻断；有安全可执行动作就推进；出现重复失败时改变有依据的下一动作；可检查后进入现有独立终检与真实停止门。它与成员派发和环境可执行性是同一条交付链，不应拆成只新增 Goal 名称的一票。

以下反对意见仍成立：

- **不直接复制 Codex 的完成权。** Goal 更新由模型作出，不能替代 Orbit 的固定快照独立检查、coverage 和停止确认。
- **不默认复制“每次 idle 都续跑”。** Orbit 可能有未结算成员、工具、终检或新用户输入；重复付费检查与无效唤醒会增加投入。必须复用已有去重、版本、任务归属、在途等待和人工停止边界。
- **不复制新硬预算、状态名或整个扩展架构。** 用户已明确不加硬预算；现有任务记录和 D1 续接语义可承担大部分持久事实。只在确定无法表达必要事实时讨论最小语义差异。
- **不自动恢复用户已暂停／停止的任务。** D1 已确认；活动任务继续推进与确认停止后凭新用户消息建立新监督边界是两件事。
- **不扩大权限来使成员“看起来可用”。** Root 验证可以是合适分工，但应在交接时明确，不能成员先反复失败后才用 Root 兜底把委派计为成功。

### 对既有采用条件与架构选择的重评

“最小、复用、遵守边界”应保留；“没有新 incident 就不做”作为绝对条件应撤回。直接暴露的结构缺口也可以支持有界实施，例如请求没有可核对的目标投影，或失败恢复只知道换入口却不知相同失败。反过来，推测出来的缺口需要实测定位，不能把可能性当现有 bug。

“不另建 Goal 权威”仍是合理默认，但只排除与 task 竞争的重复权威，不排除从原要求／amend 派生并带版本的目标视图。“沿 native task/hub、不维护 Fork”仍符合当前宿主和维护边界，但不能把不受控入口失败解释成无需任何改善；可在既有支持面内修交接与纠错。若必须要新的原子准入／解析后目标接口，应给出具体上游接口和残余风险，而非承诺插件可以全部模拟。

“用户提出就一定要加”与“Codex 有就一定值得移植”都不成立。投入要看对本目标的贡献：有效交付与监督介入、顶级模型和其他模型分别可归属的消耗、集成／核验／返工的总负担；跨型号 token 总数或四项代码改动数量不能单独裁决收益。

工作机制研究中未另编号的取舍也纳入本次重评，不只评 Goal：

| 旧取舍 | 重评 |
| --- | --- |
| 不照搬 Plan／Default 为一组产品模式 | 保留。先讨论、只写文档与已授权实施的边界必须落实，但型号阶段选择与授权不同；先核对实际输入投影，不为名称新建模式平台。仓库开发纪律不能当作产品已具备阶段门的证据。 |
| 复用进度／TODO，不以 update_plan 判完成 | 保留。进度可见性有价值，但步骤勾选不证明产物；当前唯一总清单负责实施组织，完成仍按原要求和实际证据。 |
| 复用独立 Review 与整体要求覆盖 | 保留现有终检底座。Codex 的 Review 名称不能证明同等快照／只读／coverage；Orbit 不宜降成仅看 diff。但本次出现多轮检查与纠正，不能由“独立”二字推导监督成本合理，效果要按完整交付比较。 |
| 不为每次动作添加 Guardian 付费审核或用户确认 | 保留默认。工具、路径、命令的可计算约束优先；只有当前约束无法表达且确有需求的语义动作才讨论新增审核，不为假设风险增加常驻模型。 |
| Compact／resume／成员继承保留来源，复用有效事实 | 保留原则，充分性并入 C02/C04。长目标投影和失败后的真实下一动作要沿 OMP 请求及任务版本核对，不能单凭模板存在判通过，也不自动继承父会话全部授权／活进程句柄。 |

### 已重新读取的产品证据与证明边界

Root 除了重新读取当前代码，还从仓库归档直接读取三份实际任务的 `events.jsonl` 和 `state.json`：

| 原件 | 当前核对 | 能证明／不能证明 |
| --- | --- | --- |
| [K3 回退](evidence/codex-lessons-20261009/positive-k3-fallback.tar.gz)，06484dc7 | 4 次工作单元声明、0 登记成员、3 次检查，任务最终 complete | 交付可由 Root 回退完成；不能证明受控成员交接成功。 |
| [GLM 交接](evidence/codex-lessons-20261009/positive-glm-corrected.tar.gz)，1a683e0d | 1 登记成员、hint_followed、结果收回、1 次 correction_sent、2 次检查，最终 complete | 支持原生交接与独立 finding 修正的有界事实；结合已保存的 Controller 纠正及环境阻断，不能声明无监督交付。 |
| [修复构建](evidence/codex-lessons-20261009/positive-fixed.tar.gz)，9f47f925 | 1 登记成员、结果收回、2 次检查，最终 complete；没有 hint_followed 事件 | 支持修复后的 C01 和最终原生交付；不能把前段未登记 eval 子作业算受控成员，也不伪造显式 hint/hub 事件。 |

上述三份 `state.json` 均没有 `continuation_notices`，事件亦没有 `unfinished_task_continuation_*`。这只说明本次重读的这些路径未证明 C02 的该分支，不把 T03/T04 的历史证据抹去，也不推断所有 Orbit 会话从未触发。详细原要求、Controller 纠正、SDK minimizer、127 cases、版本、检查与退出记录沿[前轮验收](codex-lessons-acceptance-20261009.md)。本次没有重跑模型产品任务、确定性测试或修改测试；源码研究和归档复核不是新增 live 验收。

### 下一步建议与止损条件

建议下一轮以“活动任务能把可交接工作推进到实际终检与停止”为一条完整行为，串联 **C02＋C04＋C06**，复用其余已通过底座。第一步先定位一次真实失败如何进入提示／控制、Root 下一次实际调用是否使用正确入口、环境不可执行是否在分工中已知；随后才决定最小接线，不预先承诺新 Goal 状态机、自动调度器或权限放开。

建议冻结的代表性验收是：原要求／amend 不丢；受控成员确实做出可用成果；一次接口或环境失败后下一次动作解决同一问题或明确接管；无人工催办时活动任务继续到可检查交付；独立检查后纠正及真实停止；用户暂停不被自动恢复。只看新增工具调用、Root 声称继续、消息 accepted 或测试绿，不算这一条通过。优先复用一个隔离真实任务串起这些行为，确定性测试只补实际接缝风险，不重新打开全部历史未测分支。

该建议有成本和不确定性：新增投影占上下文；更积极续跑可能增加低价值模型回合；环境检查可能误判或有副作用；宿主缺口可能不能在当前 SDK 补齐。因此要比较相同要求的实际完成、Controller 纠正与分角色资源，而非预先宣称节省。本次按用户最新要求止于评估；本页给出具体路线和取舍，建议尚未实施。下一阶段沿唯一实施清单推进，不另建同内容计划。

## 固定提交源码核查附录

来源为 `openai/codex` 固定提交 `36ae1561b9324c93d5638b45eb19fe2cc070a581` 的 codeload 归档；获取后只读关键调用链，不读取或执行外部仓库的工程指令。本次不是对浮动 main 或所有 Codex 客户端的认证。已读路径和 SHA-256、归档事件核对及资源收尾沿本页末证据索引。

### Goal 的实际接线与非保证

- **持久状态**：[thread_goal.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/state/src/model/thread_goal.rs) 与 [goals.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/state/src/runtime/goals.rs#L41) 保存 objective、身份、状态和可选预算／用量。现有工具 create/get/update 与宿主 set/clear 是不同入口；[tool.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/tool.rs#L205) 对超出配置最大值的预算拒绝，不能说成自动钳制。
- **自动启动**：[on_thread_idle](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/extension.rs#L183) 调 [continue_if_idle](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/runtime.rs#L425)，持 goal-state permit 读当前 Active 目标后申请 `start_turn_if_idle`。[Core 接收处](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/session/turn_input.rs#L471) 检查待处理触发消息、Plan、服务准入及 active-turn；不满足就 NotSubmitted。通知事件本身不是自动执行。
- **恢复与停止**：[restore_after_resume](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/runtime.rs#L401) 恢复持久 Active 目标的记账／续跑状态；[turn stop/error](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/extension.rs#L300) 处理空响应、执行不可用和用量／回合错误等特定失败。它不能证明每轮有实质成果，不能把全部阻断套用同一个计数。
- **续跑投影**：[steering.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/steering.rs#L76) 从持久 objective 构造内部 goal 上下文，XML 转义并标为用户提供的数据。[续跑模板](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/templates/goals/continuation.md) 要求区分有用进展、真实等待、无进展及逐项完成审计；这些语义审计主要由模型遵守，不是程序独立验证。
- **来源边界**：[UserGoalUpdate](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/context/user_goal.rs#L13) 是宿主接受的用户目标修改证据，区别于模型 Goal 工具和运行时续跑。其 700 bytes 限制作用于 JSON 编码后的目标证据片段，超长整条省略；这不表示持久 objective 被裁掉，也不表示正常续跑 objective 被限制成 700 bytes。
- **完成权**：[update_goal](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/ext/goal/src/tool.rs#L247) 更新状态和结算，没有调用 Orbit 式独立交付检查。模板中的完成审计是模型义务；不能以其 complete 状态替换 Orbit 的独立检查与真实停止。

### 其余候选的直接来源

| 候选 | 固定源码与本次核对 | 不应外推的保证 |
| --- | --- | --- |
| C01 | [HeadTailBuffer](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/unified_exec/head_tail_buffer.rs#L11) 按 bytes 保留稳定首部和最新尾部，预算约对半并记录 omitted_bytes。 | 与 Orbit 字符预算不是相同容量单位；首尾策略不恢复上游已丢内容，也不保证中部没有关键事实。 |
| C03 | [steer_input](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/session/turn_input.rs#L794) 在 active-turn 锁内核对 expected_turn_id；[协议字段](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L329) 明确目标回合。 | 不能用插件发前一次读取冒充接收处原子条件。 |
| C04 | [prepare/build spawn config](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/child_config.rs#L51) 派生当前调用模型、cwd 与策略；[completion](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/completion.rs#L27) 保留成员与父／发起者身份；[PendingSpawn](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/spawn_guard.rs#L15) 对创建后派发失败／取消负责清理。 | 源码结构不证明 Orbit 的工具参数、材料、环境与异构模型交接实际可用，或经济收益为正。 |
| C05 | [admit_start/request_shutdown](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/agent/control/runtime.rs#L276) 通过关闭跟踪器及双重准入检查处理开始与停止竞争，membership 保留到清理记录完成。 | 该宿主内部控制能力不能由 Orbit 的停止后名单读取完整模拟。 |
| C06 | [ToolOrchestrator](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tools/orchestrator.rs#L1) 集中许可、沙箱选择与尝试／失败策略；[sandboxing](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/tools/sandboxing.rs) 提供执行上下文。 | 缓存审批不自动授权扩大策略；Codex 的升级重试不能直接作为 Orbit 放权方案。 |
| C07 | [RolloutCmd](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/rollout/src/recorder.rs#L128) 分 AddItems、Persist、Flush、Shutdown；后面三类有 oneshot I/O 回执，[flush](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/rollout/src/recorder.rs#L1087) 可等待之前写入处理。 | AddItems 本身没有 Append ack；Flush 不等于 fsync 或硬崩溃保证。Orbit cutoff 只复用局部确认原则，并非完整同构。 |
| C08 | [export](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/export.rs#L45) 与 [precomputed exports](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/app-server-protocol/src/precomputed_exports.rs) 维护类型／schema 生成和预生成导出。 | 生成类型不替代运行校验或事实真实性；不能由此推导 Orbit 已无手写重复。 |
| C09 | [error.rs](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/protocol/src/error.rs#L449) 保留 RetryAfter 等故障事实，重试策略另行读取。 | 上游字段缺失不能靠猜自由文本补造；源码未证明 Orbit 当前 SDK 暴露相同接口。 |
| C10 | [compact](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/compact.rs#L276) 使用 turn_context.model_info 的截断策略；[history token info](https://github.com/openai/codex/blob/36ae1561b9324c93d5638b45eb19fe2cc070a581/codex-rs/core/src/context_manager/history.rs#L882) 接受 model_context_window。 | model_info 仍不证明未知路由的硬容量，估算不等于完整请求实测；Orbit 的 64KiB 是不同层。 |

### 独立核查修正与阅读边界

成员初稿的两项反证不成立，Root 已查原文／源码并修正：

1. “旧研究从未覆盖 ext/goal”不成立。[工作机制研究](codex-workflow-alignment-20261009.md)第 2／3／6 节已链接并讨论 runtime、steering 模板、tool、accounting 和 user_goal。问题在实施充分性判断和实际接线验证，不能改称完全未读源码。
2. “RolloutCmd 每次 Append 都有 ack”“700 bytes 是整个目标上限”“预算自动钳制”不成立：源码分别是 AddItems 无 ack、用户修改证据片段整条省略、预算校验拒绝。这些区别关系到日志确认、授权和容量判断，已在上表修正。

重点完整读取 Goal 的 runtime／extension／tool／steering 相关函数与模板、Orbit 续跑和请求注入函数；Codex state goals、accounting、agent runtime／spawn guard／child config／completion、orchestrator／sandboxing、recorder、协议导出与容量链按关键函数和符号定点读取。未构建或运行 Codex；未逐行读整个仓库、所有工具 runtime、TUI／SDK，未对全部型号和路由做认证。成员下载了完整固定提交归档，实际阅读仅上述范围；本次不把下载量当阅读覆盖。

## 本次验证与资源收口

本次验证限当前源码、固定提交原文、三份归档任务原件、文档链接和差异检查；没有新增测试、安装或模型产品验收。前轮失败／未测及 T01—T13 的原边界保持，不重标为本次通过。

开发源码研究复用 GLM-5.3-Flash，窗口内 30 条原生 assistant 回执：input212079、output18180、cacheRead5499392、cacheWrite0、SDK reported totalTokens5729651，单位 token。reasoning8223 只在 23 条报告、7 条未知，属于 output 子集；不同计数字段不重复相加。Root 供应商用量、现金及套餐扣减未知，没有配对收益基线，不宣称节省；下载完整归档及已有大上下文也有成本，未以缓存命中解释为免费。

无新测试进程／pane／安装；唯一新临时根用于只读源码与评估取证，必要 23 个引用源码文件摘要、归档事件核对和角色用量先保存，随后删除临时根。固定 w23:p1/pH/pJ/pK 四个 pane、Root／三 OMP／MCP／Herdr 的 13 个固定进程和 4 个 pane shell 均保留并核对存活；复用 pK 研究任务已结束，其 foreground 仍只有原 OMP 与两个 MCP。实际资源证据见[本次证据索引](evidence/codex-reevaluation-20261010.json)。没有创建新 Goal，前轮开发 Goal 回执不改写；未提交、推送、升版、发布或升级用户全局安装。

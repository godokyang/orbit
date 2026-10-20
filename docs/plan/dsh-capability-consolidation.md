# Orbit → DSH 能力整合与源码复核

状态：2026-10-20，用户已确认本次迁移统一重写为 TypeScript/Node.js，技术决定见 [ADR-015](../adr/015-typescript-core-and-dsh-migration.md)。同日 [ADR-015 修订](../adr/015-typescript-core-and-dsh-migration.md#2026-10-20-修订)改为 Core 与宿主插件同进程，本文引用的"进程隔离"与"失联不放行"以修订为准；实施依据见[实施计划](dsh-implementation-plan.md)。下方 R1 保留原双方复核记录，其中“保留 Ruby Core”已被新决定替代；其他监督和兼容义务保留。独立 Coding Agent、DSH 应用入口及证据反馈目标不变。当前只完善文档，不开始重写或 P3；不宣称新路线已获原 R1 的独立复核或运行验收。

基线：Orbit `2c6c3a1d6013d447cdae18020bb934b2c0de7258`（0.8.22）；DSH `687f282e8625c6b8d11ff58211a90524be2e4317`（0.2.1-rc.2）。工作区与验证状态见[交接](handoff.md)，唯一任务入口见[总待办](agent-autonomy-implementation.md)。多 Agent 具体流程见[协作专题](dsh-collaboration.md)；本文件负责跨功能的整合与退场判据，不重复定义该流程。

## 1. 已认可的方向

Orbit 保留受控交付监督，DSH 承担执行运行时。当前 Orbit 已复用 OMP task/hub，并没有另一套完整成员调度器；收益主要来自宿主适配与重复执行机制的精简，不预估删码比例或性能收益。

| 能力 | 方向 | 不可随之删除的义务 |
| --- | --- | --- |
| 成员执行、会话与消息 | 复用 DSH subagent、SessionEvent、查询与恢复，替换 OMP 接线 | 工作单元与真实派发身份绑定、单层团队、修订送达事实 |
| 后台执行与资源管理 | 复用 DSH jobs/subprocess，避免第二套执行注册表 | 任务范围、清理证据与停止未确认，不能把 job 终态当 OS 资源已释放 |
| 模型连接与凭据 | 使用宿主路由、模型适配和凭据解析 | 用户授权、角色池、JEV 适配判断、真实模型身份与资源事实 |
| 请求、工具与权限执行 | 使用 DSH 拦截点和底层沙箱，不复制 OMP 内部语法 | 首调用前登记、内部记录保护、命令与读取范围、网络限制；DSH 文件沙箱不自动覆盖这些 |
| Goal 与续跑 | 受控任务只有一个继续执行的决定者；Orbit 决定，DSH 承载执行 | 不让 Goal driver 独立唤醒 Root，或让 goal.complete 绕过 Orbit 完成门 |
| 上下文压缩 | 执行会话交 DSH；判断材料保真规则先保留 | JEV 的 purpose/must_keep、缓存和溢出处理，检查所需完整要求与有效修订 |
| 调用采集 | 用 DSH 原生调用事件替换 OMP 专用观察器 | 任务/角色归属、去重、缺失字段未知、账户与计费语义 |
| 对外集成 | 保持 Orbit 集成合同，不让 Loom 耦合 DSH 内部协议 | 提问答复、事件游标、会话身份、停止续接与兼容承诺 |

不重复建设 DSH 已有的执行设施，也不把监督规则误判成重复基础设施。Goal、Team 任务板和 Orbit 工作单元不得各自拥有同一业务事实的独立写权限。重写后的任务记录统一写入口、宿主原生日志区别及失联不放行规则见 [ADR-015](../adr/015-typescript-core-and-dsh-migration.md#后果与不变边界)；插件登记不能另写一份监督事实。

### 联合方案 R1

历史适用范围：本节保留当时确认的原文。语言选择已由 [ADR-015](../adr/015-typescript-core-and-dsh-migration.md)替代，**不再以第 1 条“保留 Ruby”指导新实现**；职责、隔离、权限、停止、兼容及证据要求仍适用。

Root 与用户指定的相邻 OMP `w28:p2`（会话 `01a1585f-0096-70e9-bac5-1bd1e81ff2cf`）经 Herdr 协作；对方第一轮未读 Root 两份分析稿，先独立查固定版本源码，再逐项交换反例。它不是 Orbit 登记成员；正式文档由 Root 一人集成。

确认记录：对方在最终核对中明确回复“明确同意该R1方案主体”，确认的合并稿 SHA256 为 `5514f4c798ce62624ceb6c63f2133bad7d800f2d4fdde5ff0ec890bcec43f915`，并确认协作/阶段专题同步段无冲突、剩余是未跑探针而非双方分歧。此 SHA 仅对应当时确认稿，不包含后续用户确认补充或 TypeScript 重写决定；原文保留供追溯，不冒充新决定的双方确认。

1. **保留 Ruby 监督核，接入 DSH 进程内插件。** Root 仍是面向用户的宿主会话，不再创建一个“Orbit Root”。执行复用 DSH 原语；SDK/ACP 可作检查进程或外部自动化载体，不替代 Root 请求、登记、权限与停止拦截。监督事实的归属不变。
2. **采用显式、最小的受控 profile。** 固定版本及有效插件/配置组合，普通 DSH 不自动受控。初始验证集合不启用 HMR、动态插件修改、独立 Goal driver、schedule 自动唤醒、未授权标题模型调用及会话上传；checker 不加载 workflow/PTC，Root/成员的首批探针也先不启用。若正式切换需要这些能力，须纳入同一守卫后验证，不能把试验支持集合当成用户已同意的功能削减；不改普通 DSH 的默认行为。
3. **登记与调用授权分两层，不能相互替代。** 本地 `agent/created` 同步门负责真实身份的耐久登记；请求准备及 `llm/stream` 核对实际路由、授权与调用归属。后者不是所有 provider 最早的凭据/I/O 门，见 C15。首批成员适配优先本地 spawn；本地恢复须独立验证；不满足 H4 的外部一次性后端先排除在受控成员之外，不以“显式降级”冒充必需义务达标。成员互发仍按协作专题 O1 单独决定，不能无声退成只经 Root。
4. **检查与停止维持 Orbit 语义。** checker 使用独立进程、固定快照与登记读根，不 fork 执行上下文。停止先封本任务 admission，再收束已知及在建成员、Root 活动、jobs、在途工具、迟到问题/消息/唤醒和检查进程；精确处理本任务消息，保留 Root 及无关输入。未知仍为 `stop_unconfirmed`，后续合法新任务必须仍能派发。
5. **选新增宿主中性读取能力，不造 OMP 影子日志。** 经 DSH 正式读取/导出接口取得事件、来源和代际，不另写原始压缩日志解析器；以次版本新增能力承载中性消息及不透明游标，Loom 按能力协商迁移。旧 1.x 消费者语义不得回归，不将 DSH seq、压缩文件路径或合成 OMP 记录冒充旧合同支持；未支持须明确拒绝，不能空结果成功。能力未接线不是删除旧合同；若现有协商无法合法表达宿主差异，正式切换阻断，先由用户确认合同主版本及迁移方案。本轮不改合同或升版本。
6. **JEV/TypeSafe 不并入普通 chat。** 概率请求/结果、输入保真、校准与失败未知语义保留；JEV 压缩的 OMP 执行载体另换。严格型号授权继续关闭可选判断。宿主变化若改变校准输入或实际模型，不自动沿用旧放行；标题、压缩、重试、检查各类真实调用与目录查询分别归属，不能把目录 HTTP 算成模型 token 调用。
7. **先证明替代，再退场旧胶水。** §2 的代码仅在对应接缝、公开兼容、安装/更新/失败恢复及真实任务验收闭合后删除；宿主专用 `orbit omp` 可随正式切换退场，不把它承诺为永久别名。P3 的探针与后续生产切换是两道不同边界，现在均未启动。

### 双方差异与处理

| 议题 | 独立复核与对比发现 | 合并结论 |
| --- | --- | --- |
| 登记与模型门 | Root 找到可等待的 `agent/created`；对方强调公共 `llm/stream` | 两者组合，分别承担登记与实际调用核对；外部后端不能继承本地保证 |
| 停止 | Root 找到全树 drain 的永久关闭标记；对方补出 `session/wait`、job 结算与 schedule 的遗漏 | 任务级停止，不以 idle、回执或进程关闭任一项代替全部证据，见 C7 |
| 沙箱 | 对方首轮称 DSH OS 沙箱“更强”；Root 指出文件层读取不受限 | 撤回强弱泛化；按真实读根、工具、网络、进程与平台能力逐项核验，见 C6 |
| 动态插件 | 对方首轮将管理 service 与模型工具混同 | `tool-plugin-manager` 在 base 默认禁用；冻结有效组合与其他修改入口，不误写默认模型已有管理权限，见 C14 |
| 辅助调用及凭据 | Root 原稿侧重压缩/重试；对方补标题 LLM、headless 凭据差异，并一度将 prepareCall 概括为本地解析 | 补入 C15；Root 查到 Account 路由在 prepareCall 可读凭据并查询目录，撤回“stream 前没有凭据/I/O”的泛化 |
| 外部兼容 | Root 原稿未展开合同中的原生日志承诺；对方首轮称合同不变、Loom 面不变 | 区分语义保留与原样兼容，选择新增中性读取能力，不承诺 Loom 零改动 |
| 证据快照 | Root 区分 worktree 与快照；对方补 workspace-changes 临时性和 present 不复制内容 | 保留 Orbit 快照/归档；会话 surface、原始事件与交付字节分别取证，见 C2/C11 |

### 对外兼容的逐项处置

| 合同面 | 推荐处置与切换前条件 |
| --- | --- |
| 任务 start/check/stop/status、external-ref、revision、attention、latest-check、型号授权 | 保留 Orbit 语义；DSH 接口只是执行载体，不能用 session idle 替代任务停止 |
| events_read、export | 事件仍读 Orbit 任务日志；导出保留原字节/来源及必要的可读解码，标注缺失，不把压缩字节当文本或用 surface 覆盖原始证据 |
| session_binding、resume_from/resume_wake | 保留真实宿主身份、原生消息与启动边界；session_file 的真实编码/代际不得隐瞒；旧 OMP 任务不得跨宿主伪续接 |
| launch、prompt、abort、questions/answer | 保持“不替调用方启动进程”、真实用户归属、session 中止不等于 task 停止、ACK 不等于采用；DSH live-root/continued 等限制须显式映射并验证 |
| conversation_read、native_user_messages | 不直接支持旧 OMP 格式假设；采用上方新增中性能力路线，明确来源、编码、游标及错误行为，Loom 改为协商使用。兼容未闭合前不正式切换 |
| `orbit omp` 与安装入口 | 前者是宿主专用入口，不在稳定集成命令清单内；安装/更新/恢复必须按新载体重核，不能因 RPC 可启动就宣布可替换 |

### 用户确认补充：独立使用、应用入口与证据反馈

2026-10-20 用户确认以下产品方向并要求落盘。目标及可观察验收集中维护在[总待办](agent-autonomy-implementation.md#已确认的迁移产品目标)；本节记录理由与实现边界，不把未实施目标写成当前 DSH 能力，也不修改现行任务/集成合同。

**产品上保留独立 Coding Agent，内部继续分工。** 用户不依赖 Loom，也能直接让 Orbit 完成 coding 交付。Orbit 不退化成仅供集成方调用的后台服务；“独立使用”不等于自建模型循环。按后续已确认的 ADR-015，目标由 TypeScript Core 承担监督和任务证据职责，DSH 承担执行，进程内插件负责接入与硬边界。重写是本次统一技术栈的选择，不是使用应用界面的必要条件，也不要求另造 TUI。

**复用 DSH 应用承载交互，不把 preset 当作监督接入。** 固定版本的 [Web 应用说明](https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/bundle/web-app/README.md)已有聊天、会话、模型管理、Agent presets 和客户端插件机制；[Web 组合配置](https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/bundle/web-app/cordis.patch.yml)区分宿主服务与界面插件。这是扩展基础，不是已存在的 Orbit 开关。目标是在已加载 Orbit 宿主插件的应用里建立受控会话，接通 TypeScript Core，展示真实任务、成员、检查、交付及停止状态；登记、权限、授权、采集和停止仍在运行时落实，不能只加提示词或前端标签。活动任务不能借切换 preset/关闭 UI 绕过收尾。Web 路径与桌面应用打包、插件加载及生命周期分别验收；普通 DSH 行为不变。

应用采用公开集成接口还是内部宿主适配，在接线设计时明确；无论哪条路径，都复用 Core 的授权、状态变更与真实事实投影，不直接写任务文件或另建完成/停止状态源。公开 CLI 与自动化能力仍按合同保留，不能因独立交付在应用中验收就删除；`orbit omp` 仅按宿主专用入口处理。新宿主启动命令与装配尚未设计，不等于承诺新建 CLI/TUI 执行引擎。

**保留用于改进的证据链，不把日志量等同于数据飞轮。** DSH 原生事件提供执行事实，Orbit 继续保存任务级关联、版本、判断与结果。独立应用入口和 Loom 入口遵循同一证据规则，不能把事实分散在两个互不关联的记录体系；原始执行、模型可见 surface、产物版本和用户反馈仍须区分。数据应支持从失败/返工/用户纠正回到具体派发、检查和产物，再经复盘与验证改进后续行为，而不是自动把一次成功升级成普遍有效策略。

现有证据采集、归档与导出是该闭环的基础，不是“使用越多自动训练、自动优化策略”已实现的证明。沿用 [ADR-008 的本地证据与主动分享边界](../adr/008-omp-native-collaboration-base.md)：不自动上传 `.orbit`，不在任务结束后自动调用模型分析；DSH 遥测、会话上传或消息反馈不替代 Orbit 证据与用户授权。校准仍按 [ADR-009](../adr/009-user-selected-model-pool.md)绑定实际模型、输入和适用范围；本次不新增自动训练、自动调参或集中上传机制。

本次仅文档落盘；没有运行 DSH 应用、安装插件或验证真实反馈闭环。上述用户确认补充不构成 P3、产品代码修改、发布、提交或推送授权。

## 2. 退场范围与顺序

| 当前实现 | 处置条件 |
| --- | --- |
| Ruby Core 的任务状态、要求、工作单元、检查/裁定、选型/JEV、账本、快照及 CLI | 按合同在 TypeScript 中实现完整行为；不得只包一层 TS 调旧 Ruby。对应行为与真实切换验收通过后，删除被替代的执行代码及 Ruby 运行依赖 |
| `plugins/omp-host.mjs` 的 OMP 专用会话/事件/目录接线 | DSH 对应入口和回执经过验证后替换；其中混合的监督政策先识别和迁出，不整块丢弃 |
| `lib/orbit/hosts/omp/omp_entry.rb` | DSH 启动与恢复入口满足现有调用方后退场 |
| `lib/orbit/hosts/omp/omp_check_runner.rb`、`runners/omp-reviewer/` 的宿主启动部分 | 替换检查进程载体；保留只读取证、快照、结构化结果验证及清理证据 |
| `plugins/native-call-recorder.mjs` 的 OMP 消息边界采集 | DSH 能给出同等实际调用事实并映射既有账本后替换 |
| `plugins/work-unit-scope.mjs` 的 OMP 路径选择器解析 | OMP 工具调用方迁完后删除；不让 DSH 模拟 OMP 路径语法 |
| `conversation.rb`、`user_messages.rb` 的原生日志解析 | 新执行路径采用中性投影与能力协商；旧合同消费者及历史读取仍须满足原承诺，不用 DSH seq 偷换 OFFSET，也不造 OMP 影子日志 |
| `jev_compaction_runner.rb` 的 OMP 启动与型号探测 | 与 checker 载体一起迁移；`JevInputCompactor` 的判断输入规则不因此删除 |
| OMP 专用配置与测试 | 对应真实调用方退出后删除；宿主无关的行为验收保留 |

本次目标已由“只换宿主接线”调整为 TypeScript Core 与 DSH 同次迁移。先确认行为与接缝，再分段实现和验证，最后统一切换；开发期可留旧实现作参照，不允许双核心写同一任务。不得在准备或 P3 试验阶段先删现行入口。任务历史、公开语义和必要进程隔离不随 Ruby 退场；当前没有改代码、进程或存储的执行授权。

### TypeScript 重写与切换条件

本节是 [ADR-015](../adr/015-typescript-core-and-dsh-migration.md)的实施准备，不是本轮执行清单。目标与进度由[唯一总待办](agent-autonomy-implementation.md#typescript-重写目标与边界)维护；下列通过信号均待实现后核对。

C13 列出的现有 CLI/集成面均须逐项核对迁移处置；下表只按完整行为分组，不取代命令与消费者清单。公开能力按合同保留，宿主专用入口按 §1/§2 条件替换，不能用“分组表没写”遗漏接管、裁定、历史恢复、模型管理或安装诊断等行为。

| 完整行为 | 重写范围与通过信号 |
| --- | --- |
| 要求、任务状态与工作区 | TypeScript 接续真实来源、有效修订、工作区绑定及输入/产物版本规则；修订或 rebind 后旧检查不能错误取得当前资格，状态持久化与版本变化保持原语义 |
| 多 Agent、检查、裁定与完成 | 原生登记、派发身份、结果结算、独立只读检查、覆盖/finding/ruling 和完成门进入新核心；不能只返回 DSH 的 completed 或合法 JSON 就算业务接受 |
| 停止与恢复 | 正常完成、中断、失败及迟到消息路径均实际收束本任务执行和资源，未知不确认；Core 断线/超时/身份不明不放行新受控执行，重连不盲重发。保留无关输入，同 Root 合法新任务仍可继续；不得用销毁 Root 或清空全部消息掩盖停止缺口 |
| 模型、JEV 与用量 | 保留 Root/角色池/严格授权、TypeSafe 概率协议、输入保真、失败与校准资格；实际请求、重试、辅助调用与资源账本正确归属，未知不补零；不把 JEV 改成普通 DSH chat |
| 历史、快照与公开兼容 | 新核心能读取实际历史记录、导出和受检快照，核对来源、版本及摘要；先保持现有格式，不因 JSON 表达差异重算旧身份。公开 CLI/合同与中性消息能力按 §1 兼容表验证，不靠旧 Ruby 运行时兜底 |
| 独立应用与 Loom | 不依赖 Loom 的 DSH 应用受控旅程可完成 coding 交付；Loom 所需能力协商与任务路径仍成立，两种入口进入同一证据体系；UI 不合成完成或停止状态 |
| 安装、更新与干净切换 | 核对实际 Node/DSH 版本、构建产物、插件与独立进程启动/回收责任，覆盖应用退出；Loom 调用方的进程所有权不变。安装或升级失败不破坏记录，旧执行先确认停止再启用新核心；回退在交给旧版前按实际格式兼容能力阻止不支持的读写，不依赖旧版自行拒绝 |

验证先使用现有公开合同、稳定历史样例及关键业务行为，迁移有价值的回归而非照搬 Ruby 私有步骤断言。确定性检查在新 TypeScript 入口上运行；真实 DSH 的登记、隔离、停止和独立交付另验。原有 Ruby 检查结果仅在其前提未变时说明旧实现，不授予新核心通过资格；既有未完成事项不因重写消失。

同一次迁移可按上述完整行为分段实现，只有范围和验收全部闭合后才正式切换并删除旧执行路径。历史 OMP 数据按真实读取需求支持，不构成保留 OMP 执行宿主或永久双核心的理由。本轮不选新框架、数据库或 IPC，不创建 TS 骨架、不安装依赖、不执行任何切换。

## 3. 源码复核后的遗漏与修正

Root 亲自读取了下列实现，并核对了相邻 OMP 的新增证据。表中“事实”是固定版本静态代码结论；“处置”是迁移要求或候选，不宣称 DSH 已通过 Orbit 验收。编号用于本专题取证，不另立任务系统。

| 编号／功能 | 代码事实与此前遗漏 | 处置与后续通过信号 |
| --- | --- | --- |
| C1 核心残余 OMP 耦合 | [TaskRuntime][O-runtime] 的 `collect_member_results`、`reject_legacy_members!` 和停止分支只认 `omp_native_task`；`root_verifications_for` 只收 `omp_native_tool_result`。仅替换 `hosts/omp/` 不够 | 核心中宿主事实分支也须切换；不能把 DSH 成员伪标 OMP 绕过旧检查。证明 DSH 成员结果、修订、验证回执及停止全部进入原业务门 |
| C2 会话读取与公开游标 | [Conversation][O-conversation] 只识别 `type=message`；[UserMessages][O-users] 校验 session 头、cwd 及用户事件。DSH 的头可部分相容，但 `assistant/message`、`assistant/attempt`、`user/message` 形状不同 [D-loop]；默认持久化使用 zstd 与代际文件 [D-persistence]。surface replace 改变模型可见历史，不等于原始事件消失 [D-surface] | 采用 §1 的新增中性读取能力，不直接把 DSH 文件填入旧解析器；来源/解码不支持须明确报错，不能空消息成功。字节 OFFSET、DSH seq、物理代际不能互换；旧 OMP 记录可读可导出，不强迁 |
| C3 真实用户来源 | DSH 同为 `user/message` 的内容可以来自 runtime-context、goal、工具、子 Agent 或用户；Goal 权限代码按 `source.kind=user` 认直接人类输入 [D-authority] | 程序注入必须显式标来源；不能仅按 role=user 建立要求、amend 或续接。用户问答答复也不能自动当作修改原要求；保持原生消息 ID 和接管边界 |
| C4 首调用前登记 H4 | 不应把所有 DSH 生命周期事件概括为 observe-only。`AgentRegistry.announce` **await serial `agent/created`**；AgentLoop 在 maintenance 中等待初始化，失败则取消并回收 [D-created][D-factory] | 本地创建/恢复已有明确候选门，不先造第二套调度器。但实际 route 经 `agent/request` 与 `prepareCall` 后才确定 [D-route]，创建事件不能单独证明模型已校验。登记、flush、路由守卫及所有入口须组合探针；外部 provider 的 `start()` 先于返回实际 ID [D-external]，不能外推本地保证 |
| C5 工具硬门 H3 | DSH `tools.guard()` 在可扩展 pre-execute/审批之后作单调拒绝；`restrict()` 控制可见工具 [D-tools]。此前只写“中间件待核对”不够准确 | 优先复用 guard/restrict，区分异步准备和最终同步拒绝。核对 native、PTC 内层、workflow、MCP、插件变更后的入口；拒绝不能被另一层 allow 覆盖。受信插件直接访问服务不等于经过模型工具门，不把该机制宣称为插件安全沙箱 |
| C6 沙箱与检查者读边界 | `SandboxedFileSystem` 只重写 write/edit，**读取不受该层限制** [D-fs]；Orbit 当前还限读路径、禁止内部目录及 shell 网络 [O-scope] | 不能用 DSH `read-only` 替代 checker 的“只能读登记材料”。检查者仍需独立进程、读根限制、禁写/派发/网络等工具面约束；成员保留 `.git/.orbit`、精确命令和环境规则。平台 file-effect 沙箱的 partial 状态不能冒充 full |
| C7 停止后同 Root 续接 | `interrupt` 留队列；`Agent.cancel()` 默认清整箱。`drainDescendants` 把 Root 放入 `closingScopes`，仅在 disposed 时删除，之后 admission 被拒 [D-drain]。`session/wait` 只核对 idle、子执行和稳定 seq [D-wait]；`job/settled.producerReported` 明说不证明资源释放 [D-jobs]；schedule 可恢复会话并 followup [D-schedule] | **全树 drain 不是可逆 pause，session/wait 也不是停止确认。** 先封本任务 admission，精确收束已知及在建执行、Root、jobs、工具、问题答复、消息/自动唤醒和检查进程。`drainChildren` 仅是已知驻留子执行的候选；保留无关输入，同 Root 后续合法新任务仍可派发 |
| C8 人工提问与迟到答复 | `askTimed` 可返回 pending；`answer()` 只接 continued 问题，防重复，随后 `agent.steer()`，不等于已处理。只有精确 live Root 可以提问，子 Agent 返回 `DELEGATED_CALLER` [D-questions] | 将 pending、跳过、拒绝、关闭面板、已排队、已采用分开映射到 Orbit questions/answer。成员问题交 Root。停止后答复不能无授权唤醒旧任务；断线/重开和重发须保持稳定调用身份，不静默重发 |
| C9 Goal 控制入口 | base **默认挂载** Goal service、driver、工具与命令 [D-base]。工具确有 live Root、人类轮次/当前 goal round、CAS 和暂停恢复检查，不是“毫无限制”；但 complete 分支直接调用 `ctx.goals.complete`，没有 Orbit 独立验收 [D-goal-tool] | 受控 profile 不直接并行运行原生自主 driver。工具、命令和 Remote 状态修改都需明确边界，不能只隐藏工具就认为 Goal 已关闭；非受控会话是否使用原生 Goal 不在本次裁定 |
| C10 压缩、重试与辅助判断 | [JevCompactionRunner][O-compactor] 直接依赖 OmpCheckRunner 启动/凭据/探测。DSH 一步内可多次 prepare/stream，失败写 attempt 后重试 [D-retry]。Orbit [TypeSafeJudgment][O-typesafe] 则是独立 `/v1/systemone` 概率协议，不是普通 chat；严格授权使 TaskRuntime 的 advisor 关闭 | 压缩执行载体迁移，JEV purpose/must_keep、缓存、校准及失败未知语义保留。provider attempt、step、turn、派发、check 分开；失败/重试/压缩/检查如实归账，账户/额度/计费未知不补零。DSH LLM 不能默认替代 TypeSafe 或取得原校准资格 |
| C11 worktree、cwd 与证据快照 | DSH 有独立实验性 worktree，Git checkout 后修改 workingDirectory [D-worktree]；workspace-changes 排除子会话，临时比较数据随 Session/Host 回收 [D-changes]；present 声明已有文件，不复制字节 [D-present]。均不等于 Orbit [WorkspaceBinding][O-workspace] 或 [archive restore][O-archive] | 保留内容快照、摘要及归档；cwd 变化不能自动扩大沙箱或修改 artifact_root。rebind 核验同仓身份并使旧检查失效；不能拿临时差异或当前文件链接代替受检版本/历史交付 |
| C12 默认数据外发路径 | base 配置 OTel `FEEDBACK_ONLY`，同时另挂 session-log-deepseek [D-base]。后者 enabled 默认 true，给官方 DeepSeek 请求贡献 `dsh_session_log`，逐段读取 canonical events [D-log] | DSH“本地执行”不等于“只发送当前提示”。迁移前对 Root/成员/checker profile 分别列明请求内容与遥测去向；不能认为关 OTel 就关闭另一个贡献器。这里记录部署准备项，未发送任何资料、未自行改变用户隐私政策 |
| C13 对外集成与历史裁定 | [CLI][O-cli] 除执行还有 entry、questions/answer、messages/conversation/events、model/route 管理、dispute/ruling、takeover、export、restore-check、diagnostics/安装入口。TaskRuntime 还处理检查失效、覆盖续查、Root 裁定与终检后版本复核 [O-runtime] | 这些不能因 DSH 有 UI/RPC/Goal 而删除。保留原公开合同及严格外部模式，宿主名称/字段的变化按兼容规则处理；SDK 可启动进程不证明具备 Orbit 检查报告 schema、快照、裁定及资源清理证据 |
| C14 有效插件组合与配置修改 | base 的 `tool-plugin-manager` **disabled=true**；plugin-manager service/HMR 是否启用依赖 profileContext，workflow/PTC 则已挂载 [D-base]。管理工具若启用需完整权限或审批，且修改影响整个 profile、插件代码在工作区沙箱外运行 [D-plugin-tool] | 不把 service 存在写成模型默认已有工具。受控 profile 固定实际插件、patch、环境与入口；checker 去掉 workflow/PTC；其他运行方式须验证内层守卫。隐藏工具不能控制受信插件/Remote/HMR 的直接修改，审批也不能扩大任务授权 |
| C15 非 agent-loop 调用及预备 I/O | 标题服务单独 prepare/stream，带 session-title purpose 但无 loop 身份 [D-title]；`llm/stream` 包住流式派发 [D-llm][D-stream]。Account adapter 在 prepareCall 经 connect/catalog.view 可解析 token、查询模型目录，**早于该流式门** [D-adapter][D-account][D-catalog][D-listing]。headless 禁用已存凭据，与交互 profile 不同 [D-headless] | H4/H6 不能只守 agent loop，llm/stream 也不能宣称覆盖最早凭据/I/O。分别核对 provider 预备、初始化出站与推理流，必要的授权门早于 prepare/connect；缓存、认证刷新及后台目录查询的生命周期也须核验。未经授权的辅助调用关闭；按实际 profile 验证认证，不打印凭据，不把 GUI 登录当 checker 可用；目录查询不冒充 token 推理账单 |

### 必须保持的两组边界

- **执行设施与监督语义分开。** Session、subagent、jobs、工具管线、沙箱和执行会话压缩优先复用；要求来源、有效修订、工作单元验收、角色池/JEV、独立检查/裁定、覆盖资格、任务级账本、停止证据及公开合同继续由 Orbit 拥有。
- **源码支持不等于整合完成。** H3/H4 已找到比原方案更具体的原生接缝；H5 的可逆暂停反而发现额外约束。通过信号是实际负例被阻断、真实执行已停止且合法新任务可继续，不是接口存在或返回成功。

### 待验证入口覆盖

P3 获授权后，先冻结 Root、成员、checker、compactor 的实际插件树与支持集合，再验证 H3/H4/H5/H7。H4 的外部后端缺口不降级为通过；H6 包含标题等非 loop 调用及失败/重试；可选功能若未装载，不预先实现。正式切换还需闭合上述兼容表，不能以较小探针范围缩减既有产品承诺。未检查的 provider 不列为已支持，不将本专题扩成 DSH 全产品审计。

## 4. 本轮验证与证明边界

- 实际运行当前 Orbit `scripts/orbit capabilities --json`，返回源码版本 0.8.22、集成合同 1.8；据此将消息、问题、启动/中止、续接、事件等公开能力纳入处置表。返回清单不证明它们已适配 DSH。
- 运行一次无文件、无模型的 Ruby 协议样例，调用当前 `Conversation.visible` 与 `UserMessages.visible_user`：OMP 样例返回文本 `delivered`；按 DSH 源码事件格式构造的 assistant/user 样例均返回 null。它证明旧投影不兼容该格式，不是 DSH 真会话实测，也不是现行 OMP 功能缺陷。
- Root 与相邻 OMP 均静态阅读固定版本源码，Root 复核新增证据及争议反例；未安装 DSH、未构建其依赖、未调用 DSH 真实模型。H3/H4/H5/H7、权限隔离、问答重连、完整出站行为和多平台差分均未运行。
- 本轮只改迁移文档；产品测试不因调研新增。相对链接核验只证明文件/锚点，不能证明研究结论正确。先前工作区 CLI 冒烟在源码未变的前提下沿用。
- R1 合并时实际运行文档链接检查，只有原有 3 处断链；当时核验了 9 个本地源码目标和 31 个固定提交的 DSH 引用，路径与行段有效。新增 ADR-015 及后续文档的链接检查另按当前交接记录；不将旧源码引用核验冒充新文档或运行验证。
- 已清理本轮临时 `.dsh-peer-review` checkout；未安装 DSH 或改产品代码。迁移 worktree、正式文档及固定来源保留；相邻 OMP 会话未关闭、未换模型。

## 5. 源码索引

Orbit 链接指向迁移工作树；本轮未改代码，源码基线见页首。DSH 链接全部固定到同一提交，行段是实际核对位置；所列接缝之外不作“全仓无遗漏”的保证。

[O-runtime]: ../../lib/orbit/task_runtime.rb
[O-conversation]: ../../lib/orbit/conversation.rb
[O-users]: ../../lib/orbit/user_messages.rb
[O-scope]: ../../plugins/work-unit-scope.mjs
[O-compactor]: ../../lib/orbit/jev_compaction_runner.rb
[O-workspace]: ../../lib/orbit/workspace_binding.rb
[O-archive]: ../../lib/orbit/check_snapshot_archive.rb
[O-cli]: ../../lib/orbit/cli.rb
[O-typesafe]: ../../lib/orbit/type_safe_judgment.rb
[D-loop]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/core/agent-loop/src/agent.ts#L409-L545
[D-authority]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/goal/tool-goal/src/authority.ts#L75-L118
[D-created]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/core/agent/src/index.ts#L530-L561
[D-factory]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/core/agent-loop/src/index.ts#L789-L834
[D-route]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/core/agent-loop/src/agent.ts#L593-L612
[D-external]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/subagent/subagent/src/manager.ts#L850-L904
[D-tools]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/core/tools/src/index.ts#L1497-L1546
[D-fs]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/fs/fs-sandbox/src/index.ts#L1-L24
[D-drain]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/subagent/subagent/src/manager.ts#L296-L369
[D-questions]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/interaction/user-questions/src/index.ts#L131-L268
[D-base]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/bundle/base/cordis.patch.yml
[D-goal-tool]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/goal/tool-goal/src/index.ts#L255-L331
[D-retry]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/core/agent-loop/src/agent.ts#L504-L545
[D-worktree]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/experimental/worktree/src/index.ts#L107-L173
[D-log]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/session/session-log-deepseek/src/index.ts#L184-L243
[D-persistence]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/session/session-persistence-jsonl/src/index.ts#L60-L104
[D-surface]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/docs/subsystems/session.md#L294-L338
[D-wait]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/sdk/server/src/server.ts#L233-L257
[D-jobs]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/jobs/jobs/src/types.ts#L23-L64
[D-schedule]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/schedule/schedule/src/runtime.ts#L90-L140
[D-changes]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/deliverables/workspace-changes/src/index.ts#L59-L155
[D-present]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/deliverables/tool-present/src/index.ts#L34-L43
[D-plugin-tool]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/boot/plugin-manager/src/tools.ts#L78-L109
[D-title]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/session/session-title-llm/src/index.ts#L230-L284
[D-llm]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/llm/llm/src/index.ts#L956-L1013
[D-stream]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/llm/llm/src/index.ts#L1170-L1179
[D-adapter]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/llm/llm-deepseek/src/adapter.ts#L50-L63
[D-account]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/llm/llm-deepseek-account/src/index.ts#L73-L115
[D-catalog]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/llm/llm-deepseek-account/src/catalog.ts#L68-L114
[D-listing]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/llm/llm-deepseek-account/src/listing.ts#L150-L159
[D-headless]: https://github.com/deepseek-ai/deepseek-harness/blob/687f282e8625c6b8d11ff58211a90524be2e4317/packages/bundle/headless/cordis.patch.yml#L32-L43

## 6. 资料生命周期

后续采纳的产品语义进入所属合同/ADR，实际验证进入交接，未完成事项由唯一总待办指向本文件。信息被正式正文吸收、未决项有归属且入链已处理后，本研究文件才可退场；版本变化只重核受影响结论。

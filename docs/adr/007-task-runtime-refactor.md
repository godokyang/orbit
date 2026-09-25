# ADR-007：独立任务运行与按需纠偏

- 状态：历史 ADR（Codex／OpenCode 多宿主时代，2026-09-14 用户授权实施，已完成其当时两条冻结真实验收）。**当前运行入口以 [ADR-008](008-omp-native-collaboration-base.md) 为准**：单宿主原版 OMP + `orbit omp` 显式入口、原生 task/hub 一层团队；本文中 Codex、OpenCode 及其跨宿主成员、检查者角色的宿主特定接入已退役，仅保留为历史事实与已验收证据索引。与宿主无关的检查、finding、工作区与停止语义已由现行合同继承并继续有效。
- 依据：2026-09-13 至 2026-09-14 用户确认的独立任务运行、已有 Root、原文检查、真实停止与无兼容重构决定。

主执行 Agent（Root）指当前接受用户要求、负责整项交付的 Coding Agent，通常沿用正在与用户对话的会话。它是职责名称，无需用户另建角色。

## 对旧合同的修订范围

本 ADR 取代旧运行协议的设计：Orbit 按任务运行，当前 Agent 可继续担任 Root；同任务允许固定产物上的独立只读检查与执行并行；测试数量／行数、第三次同类失败、时间和额度预估不再产生默认硬门。Root 不自动替换，不建设故障恢复或需求讨论管理。淘汰机制直接删除，不兼容旧命令、字段和数据格式；已有用户资料保留，不等于新版承诺读取旧协议。

旧运行路径已整体退役。旧 ADR、阶段工单与操作指南从当前目录移除，历史从 Git 查阅；本 ADR 独立说明当前决定及理由。新实现只保留完成当前任务实际需要的关联和验证，不读取旧 v2 数据，不为旧字段维持双轨。

## 关键取舍与理由

| 取舍 | 理由 |
| --- | --- |
| 一次任务一个运行进程，模型按需调用 | Root 忙碌或没有主动交付时，仍有人负责计时和观察；等待不消耗模型调用 |
| 原文与实际内容由程序采集，固定版本后检查 | 多个模型若只读同一份残缺摘要或旧提交，会共同漏掉需求；增加评审席位不能补足错误输入 |
| 使用真实接入能力，不把 pane、环境变量或本地凭证当身份认证 | 观察到会话存在不等于获得不可伪造的执行授权；本地任务记录用于协作追踪，不是抵御同用户篡改的安全隔离层 |
| 保留当前 Root，纠正失败时实际暂停 | 维护上下文比自动换人更符合当前需求；没有真实故障依据就不建设恢复体系 |
| 允许固定副本上的并行检查，应用结论前重新核对版本 | 减少等待，同时防止旧检查中断已修正的工作；只读限制也不能替代对验证命令外部副作用的判断 |
| 按依据裁定真实争议，不按票数或固定重试次数 | 检查者也会误报；偏好不应阻断交付，裁定不能扩张原始需求或授权 |
| 复用原生控制与成熟传输库，按真实路径验收 | 方法名存在、模拟测试通过或请求已接收，都不足以证明执行已经停止 |
| 预估与实际对比，未知保留未知 | 超时不等于无效工作，缓存 tokens 不等于额外用量；缺少完整账单时不宣称已节约费用 |

## 职责与依据

Orbit 是可直接用于任意项目的独立工具，其他工具可选择通过同一入口调用；单个任务进程拥有执行状态、事件与检查安排，接入层提供实际会话与工具状态。Root 提供工程判断，检查者直接看用户原始执行指令、其指定依据、有效修改、相关项目规则和实际产物；裁定者只处理真实争议。普通工程选择不要求用户逐项批准。

用户授权开始执行、任务值得独立检查且原生接入可用时，当前 Agent 应通过 skill 主动启动，无需用户点名 Orbit。触发条件写入可供 Agent 选择 skill 的简介；仅讨论、只读评审与简单局部修改通常不启动，同一任务不重复启动。

2026-09-14 用户要求跑通日常流程后，职责补充为：Root 决定必要分工，程序创建并登记本任务 Codex 执行成员、传递原文与修改、回收结果、统一停止；Root 核验集成。仅让 Root 口头负责收尾不够，因为用户中断 Root 后它可能无法再停止成员。外部协作工具的成员没有自动登记，Herdr／tmux 不成为运行前提。

新增用户选择的 `orbit codex` 启动入口，复用 Codex 原生 app-server 与 TUI；通过官方 MCP SDK 暴露 Orbit 操作，解决模型 shell 沙箱无法访问控制 socket 的真实问题。仅配置 Orbit 工具批准，不扩大 shell 权限，不写全局配置。`orbit start` 仍只绑定当前 Root，不创建／恢复它。已有普通嵌入式会话不能假装热接入；显式恢复由用户选择。拒绝用 daemon 命令强迫 npm Codex 用户改装 standalone，也不将 hcom 的通信成功当作派生进程停止证据。

原始指令应原样取自触发消息或明确提供的文本，不能把模型计划标成原文。只读检查默认不运行会改写共享工作区的命令；确需执行验证时使用隔离副本／资源或无冲突时段。程序负责记录与版本关联，模型不手工维护摘要／digest／receipt 链。

## 实际产物

快照必须包含当前任务相关的真实文件内容，包括 Git 已跟踪文件的未提交修改、删除和未忽略的新文件；无 Git 项目也按内容识别变化。排除 Orbit 自有记录、Git 内部文件及不属于检查输入的生成依赖，不跟随指向项目外部的符号链接采集数据。

快照固定后检查只读取该副本。项目规则及用户指定的需求文档作为检查依据保留对应版本。收集期间发生相关变化时不能声称取得一致快照，应重新采集或报告具体未固定范围；执行产生的新版本不会被旧检查结论自动覆盖。

## 判断、暂停和完成

事件与约定时间触发独立观察，不依赖 Root 主动申请；观察后安排下一次，等待本身不调用模型。耗时或无代码 diff 不直接判失败。当前工作是否值得继续由原始任务和具体证据判断，及时停止无关优化、过度测试或无依据的重复尝试。

普通纠正通过消息落实并复核；必须停止时暂停承载相关工作的 Agent 当前执行，确认关联后台动作停止，保留 Root 会话与上下文。不能只凭状态字段或中断请求成功宣称已停止；无关独立成员继续。同一会话当前执行混合多支线时一起暂停，不增加语义级切断机制。

完成要求原始指令得到满足、交付相关问题已解决且独立检查对应实际最终产物；检查误报可由有依据的独立裁定推翻，不要求原检查者同意，不按票数。未检查、未停止、未验证应如实标明，不自宣成功。固定次数与预估不替代判断，用户另行明确的授权边界和硬上限仍有效。

## 规则与资源

通用职责短而明确，专项规则按任务加载；目标项目规则适用于双方，不全局安装任何特定项目的业务流程。角色模型配置是初始建议，接入能力和效果分别验证，不自动启用新供应商或最高推理档。时间和消耗先粗估、后对比偏差，未知标未知，不建设独立统计平台。

两条最小验收仍为真实遗漏纠正与真实停止；确定性测试只证明程序行为，不能替代真实模型判断或原生会话控制验证。

## 实施结果与边界

现行接口及状态定义见 [任务运行合同](../../contracts/task-runtime.md)。首个接入是已有 Codex Unix app-server 会话，实际采用 WebSocket；普通 embedded TUI 没有所需控制端点，程序明确拒绝，不通过自动新建／恢复 Root 绕过。控制范围是绑定 Root、本任务登记执行成员的当前执行与原生后台动作，以及自有检查进程，未承诺控制其他供应商或任意脱管进程。

两条真实路径与观察到的额外检查成本记录在 [验收事实](../reference/orbit-runtime-acceptance-20260914.md)。它们证明最小纠偏与停止路径可用，不证明所有工程任务都能节省额度。按实际结果优化触发，保留可得用量与未知范围。

## 多 Agent 接入决定

2026-09-14 用户确认按真实需要扩展 Coding Agent 接入。Orbit 的原文留存、快照、观察、纠偏与完成规则共用，各家接入负责真实会话控制；Root、执行成员和检查者的工具／模型可分别选择。先前实现全部依赖 Codex；各宿主是否已受控以对应完整路径的验收事实为准。

先通过 OpenCode 的第二条完整用户路径提取必要共用接口，再接 OMP、pi、Kimi Code；不提前建设通用编排框架。skill 主体规则共用，宿主调用方式按需补充。优先保留原生日常界面、恢复会话、模型、登录与权限配置；只有确需准备控制通道时才补启动入口，不把 Codex 的接入限制推广到所有宿主。

Grok、dsh、Cursor Agent 列为低优先级，仅在官方提供满足所需角色的接入方案时推进；官方没有合适方案则暂缓，不通过屏幕解析、模拟按键或逆向私有协议补齐。能调用 Orbit 的工具接口，与 Orbit 能控制宿主会话，是分别需要验证的能力。支持范围按 Root、执行成员、检查者分别记录，不把 RPC／ACP 可启动、取消请求成功或后台模式可用视为现有交互会话已接入、相关工作已停止。

理由是保留用户已有工作方式，同时让控制范围与真实能力一致，避免为了供应商数量增加维护和验证成本。顺序、官方接口线索与最小验收路径见 [当前计划](../plan/vision-completion-plan.md)。本次只确认方案和优先级，未启动接入实现。

2026-09-18 用户确认跨宿主成员应走原生控制：先验证 OpenCode Root 派发 Codex 成员这一条路径。此前 `delegate` 只创建 Root 同宿主成员；Herdr 的 Agent 列表与 pane 可用于发现或展示，但按键投递、屏幕读取与 pane 存在都不是 Orbit 的结果回收或停止证据。此前 Herdr OpenCode 实验暴露的脱管后台服务见[验证记录](../reference/check-loop-acceptance-20260918.md)，不通过要求成员避免启动后台服务来替代控制验证。

跨宿主成员宿主由任务运行进程持有，记录短控制地址和进程归属以供异常退出后的显式停止重连；成员先登记再开始模型工作。当前同宿主成员的原生停止、后台工作核对和会话历史保留要求继续适用；停止成员后再关闭其宿主。首条路径只声明实际验收的 Codex 成员能力，不以支持 kind 数量为验收目标。目标模型从 Codex 侧选择；Codex 执行成员权限按下文“成员允许名单与 full access”的后续决定执行。具体运行边界见[任务运行合同](../../contracts/task-runtime.md)，验证事实见[跨宿主成员验收](../reference/cross-host-member-acceptance-20260918.md)。

2026-09-14 后续授权的 OpenCode 最小实验已通过原生插件读取、同一会话纠偏、成员结果集成与事件触发的团队停止，见 [验证数据](../reference/opencode-probe-20260914.json)。这支持优先复用官方插件及原生客户端的接入方向；实验脚本尚未纳入生产 TaskRuntime，无端口完整控制与安装入口仍须落实，当前支持声明不变。

2026-09-14 用户继续授权完成 OpenCode 正式接入。采用原生插件持有客户端，以私有 Unix socket 连接现有 TaskRuntime；普通 OpenCode 不需要显式端口，Root 不替换。原文和内部投递按原生消息区分，OpenCode 成员默认沿用 Root 的供应商、模型和 variant；检查者保留 Codex。安装器与 CLI 同版管理插件，保持用户原生配置。正常退出插件时先请求任务收尾，不增加故障恢复。

## 安装与版本

2026-09-14 用户授权补齐安装、更新和版本管理。`package.json` 是产品版本来源，锁文件随版本工具同步，CLI 与 Codex 连接读取同一个版本；安装格式和任务记录格式单独演进，不用产品版本号冒充兼容承诺。

远程 ref 先解析为提交 SHA，再取得同一提交的源码；本地工作树记录基线提交、修改状态及实际安装内容摘要。新版在隔离目录完成准备和校验后，以同一个 `current` 链接切换 CLI 与原生连接扩展。准备失败保留旧版，更新与卸载只清理登记的文件及匹配入口，用户资料保留。

该流程用于任务结束后的安装维护，不保证热更新、并行安装或掉电恢复。旧安装格式不迁移；版本发布和日常会话接入仍是独立授权范围。操作入口在 [README](../../README.md)。

## OMP 原生接入

2026-09-14 用户同意在提交推送 OpenCode 0.3.0 后完成 OMP。采用 OMP 18.1.16 官方扩展及包根 SDK，通过原生 AgentRegistry 按当前 session ID 定位已有 Root；不另建 Root，不要求改用 RPC 界面。原文来自当前原生分支，内部纠正使用原生 custom message 标记。

执行成员由原生 createAgentSession 创建并先登记再启动，采用 Root 已授权模型和配置、独立会话身份；限制再次派发。停止使用原生 session.abort 和按 owner 取消、等待后台工作真实结算，不能只看 cancelled 字段。正常退出或明确切换会话前先收尾本任务，保持原上下文与成果。

OpenCode 与 OMP 复用实际相同的私有通信通道及工具入口，宿主只实现原生会话操作；不为未接入供应商增加框架。检查者仍为 Codex。OMP 18.1.16 完整真实验收已通过，见 [运行数据](../reference/omp-runtime-acceptance-20260914.json)。扩展工具由原生 xd://orbit 提供；需要成员的执行任务先接入再派发。实际运行发现 followUp 会被 hub wait 阻塞，因此采用原生 steer 投递；切换前停止未确认则取消切换并保留连接，而非关闭通道。

2026-09-14 用户决定拆分安装职责：`install.sh` 管理 CLI 与运行所需的原生连接扩展，skill 安装、更新和移除全部交给 `npx skills`，不再维护各 Agent 的技能目录、链接和开关。运行包仍包含检查者使用的规则资源，不向 Agent 安装 skill。安装格式改为 orbit-install-3；不兼容旧格式，不保留旧 skill 安装路径或自动迁移层；本机旧版由其原有卸载器一次性清理。

## 日常命令简化（2026-09-15）

用户授权将任务查询与停止定位放在 CLI 内：从当前目录向上寻找最近项目的任务记录，多任务必须显式选择，不能默认停止最近任务。停止未确认与 failed 仍是待处理候选；仅查询时没有待处理任务可显示最近结束记录。可读输出与 `--json` 分离，内部工具明确使用 JSON，任务状态和停止证据语义不变。

诊断分别报告环境、原生扩展安装与实际连接；插件文件存在不证明已加载，读取成功不证明模型登录或余额可用。安装维护沿用当前 CLI 所属安装目录，update 复用安装器：远程来源沿用 ref，本地来源保存并复用源码目录，不隐式改成远端。skill 始终独立管理，不加迁移或恢复机制。

2026-09-15 用户要求安装脚本自动完成 PATH 配置，修订此前“本轮不改 shell 配置”的实施范围。安装成功后按 `$SHELL` 为 zsh／bash 追加可重复执行的 PATH 配置，保留用户原文与链接；zsh 遵循已导出的 ZDOTDIR，Bash 同时处理交互配置和实际登录配置。选项允许退出自动配置，并随安装记录保留。当前父终端环境不能由子安装脚本修改，完成时提示重开终端或执行即时命令。卸载保留共享 bin 目录的 PATH 设置，避免影响其他命令。

## Jev 作为检查调度依据（2026-09-18）

用户决定在已全局启用的所有 Orbit 任务中使用 TypeSafe Jev，按项目允许关闭；运行时只读取启动 Coding Agent 时的 `TYPESAFE_API_KEY`，不把 key 写进 Orbit 配置。`orbit jev setup` 一次性输入 key，写入仅当前用户可读写的 TypeSafe 环境文件，并让 zsh／bash 的新终端自动提供环境变量；已有环境变量优先。它估计过程卡住／偏题或产物值得检查的可能性，再由现有独立检查者核实；不要求 Jev 解释工程根因。这样同时针对过早检查的成本和执行中遗漏、跑偏的质量风险。开发侧完成测试和真实流程验证后才考虑发布，不要求用户承担观察试点。

Jev 的判断不取代固定产物上的独立检查及实际停止证据。程序保留约定时间和 Root 交付时的完整检查，过程疑点交给同一检查角色作聚焦核查；无新证据不反复唤起。TypeSafe 不可用时恢复原调度。外发仅限有界任务内容（包括指定依据摘录）、近期观察与差异摘要；截断或省略显式标注，key 不进入任务记录。具体接口和状态以任务运行合同为准。

## 执行协作与检查回路整体调优（2026-09-22，方向已冻结）

Zeen Login 真实任务同时暴露了零执行成员、实际 worktree 与任务快照根不一致、相同 finding 和相反裁定反复出现、13 次检查全部 stale 且消耗约 962 万检查 tokens，以及排队／检查意见／任务终态不易区分。用户决定把这些问题作为一个整体处理，而不是只优化 JEV：执行与检查分成两条状态轴；工作区通过受控 rebind 改变，文字 amendment 不改变快照根；finding 和裁定按证据版本形成决策记忆；自动触发按 observation 去重合并；状态分别显示 workspace、成员、检查、JEV、finding 和用量。完整边界、实施切片和真实验收见 [Orbit 执行协作与检查回路整体调优计划](../plan/orbit-execution-review-optimization.md)。实现与确定性回归已进入合同，见下一节。四条真实路径验收尚未运行。程序仍不自动检测工作区声明冲突，也不把换了 id 的语义同义 finding 猜成同一问题。

## 工作区、检查收敛与 Codex JEV 环境名（2026-09-22，已进入现行合同）

新任务记录 `project_root` 与 `workspace`。`project_root` 继续负责授权、任务记录和 Root 会话归属；`artifact_root` 负责固定快照、指纹、Jev 变更摘要和新执行成员的工作目录，默认与项目根相同。显式 `rebind-workspace`（Codex MCP 动作为 `rebind_workspace`）只接受同一真实路径，或同一 Git 仓库中的另一个 worktree，并记录来源、原因和 history。`amend` 与 `dispute` 只追加检查输入或争议理由。在途检查若仍绑定旧产物目录，即使内容摘要相同也按 `workspace` 过期；这类 finding 不迁入待核对线索，新产物目录安排一次检查。其他过期不立即重查。自动检查按 observation key 去重，手动请求可绕过去重但不能并发。旧进程遗留的同 key `in_flight` 在本进程没有 owned checker 时记 `check_abandoned_recovered` 并以新检查号重试一次；本进程在途检查仍不并发。同一 finding id 已 open 且输入、产物目录、产物摘要和 requirement／evidence／action 都未变化时，重复报告记 `finding_repeat_ignored`，不再次纠正 Root；任一维度变化才重新投递。已 resolve 的同一 id 在这些证据都未变化时不重开。检查者程序上下文上限 64KiB。`status` 分层显示检查状态、下一动作和按角色用量，未知不推算。没有 `workspace` 的旧记录在只读 `status` 与 `stop` 时回退到 `project_root`。程序不自动检测绑定与声明的冲突，也不因此暂停检查。确定性回归已通过；四条真实路径验收未运行，见 [优化真实验收计划](../reference/orbit-optimization-acceptance-plan-20260922.md)。

`orbit codex` 在启动环境已有 `TYPESAFE_API_KEY` 时，只把该名称写入 MCP 的 `env_vars`。值由 app-server 从启动环境解析。MCP 配置、命令行和诊断输出只出现变量名。这不追溯改变 Zeen Login 当时 MCP 子进程缺少该变量的记录。

## JEV 委派判断与模型证据（2026-09-22，已进入现行合同）

Zeen Login 真实任务表明，“Orbit 已接入检查”与“已启动执行成员”必须显式区分；该任务的 JEV 因 key 未进入 MCP 子进程而没有运行，不能把零成员解释为 JEV 判断结果。当时的单一 `delegatable` 信号不足以表示执行吞吐收益。用户决定将委派建议分成任务可拆性、成员质量适配和关键路径收益三层；程序核对成员可调用性、任务状态和观察新鲜度，Root 仍决定执行票、成员和是否派发，Orbit 不自动 `delegate`。

模型速度、质量和费用是快速变化的外部事实，不进入 Orbit 发布包，也不要求用户维护配置。只有结构判断发现真实可委派面时，Root 才按实际 provider、model 和 reasoning effort 查询带来源、时间和有效期的证据；有效缓存跨任务复用，JEV 不联网，只接收压缩后的比较。输出 tokens/s 不能直接等同于任务耗时，判断必须计入交接、返工、集成、共享资源和验证。第一阶段 `delegatable` 达到 0.60 且存在可调用成员后，程序查询模型证据缓存；缺失时每个观察签名只请求一次，Root 用 `model-evidence` 提交。有效证据才问 `member_fit` 与 `parallel_gain`；两者分别不低于 0.55 和 0.50 才提示，且 Root 必须显式 `delegate`。同一观察签名至多提示一次，已有活跃执行成员时暂停新的自动提示。专项阈值、真实校准依据与 prompt 见 [JEV 委派判断专项计划](../plan/jev-delegation-optimization.md)。这是现行合同语义。

严格 Herdr → `orbit codex` 复验发现 Root 会把第一阶段 `delegatable=0.91` 误称为最终建议，而真实第二阶段是 `parallel_gain=0.40` 与 `delegation_declined`。运行时因此新增按观察签名持久化的 `decision=recommended|declined|unavailable`；人类状态把候选分、第二阶段结果和已持久化 `delegation_hint` 分开。只有当前 input、artifact 与成员候选签名一致、且尚未跟随的 hint 能把一次显式派发记为 `basis=orbit_hint`；其他派发记为 `root_without_hint`，但不被禁止。basis 同时保存在成员记录和事件中，避免“成员确实运行”被误写成“Orbit 建议运行”。

真实验收还暴露了手动终检的收尾缝隙：检查者正确地不替 Root 宣布产品任务完成，但 `continue` 配合极短 `next_check_seconds` 会让已完成的 Root 没有被唤醒、检查反复启动。现行规则是在有效手动终检无当前 finding、无待核对线索且成员已结束时，按输入和产物版本向 Root 发送一次 `finalization_notice`，要求 Root 自行确认实现和本地验证后显式停止；Root 未完成一轮时偏好等其 turn 结束再通知，但按版本绑定的 pending 通知即使 Root 仍在 active/等待也必须在有界 60 秒内送达（v7 真实样本观察到 Root 等待期间通知无限期挂起）；送达 pending 不自动完成任务，显式停止仍等待 Root turn 收尾并核对当前状态。等待期间恢复约定检查间隔，不自动完成任务。

0.6.12 首轮真实复验又发现：把“手动 check 后结束 turn”写成无条件规则，会阻断用户明确要求的 in-flight rebind 验收；只连续入队 check 与 rebind 又会因异步命令队列而让 rebind 先于 reviewer 真正启动。等待纪律因此只禁止为了等检查结论而 `status`／sleep／poll；若用户已经要求一个不依赖检查结果的状态变更（例如旧检查实际启动后立即 rebind），Root 可以用最少查询确认明确的状态前置条件，紧接执行动作，再结束本轮，不能把例外扩大为普通轮询。

后续严格复验又证明 Root 为等待结果调用只读 `status` 会改变宿主观察摘要，使产物终检被记为 `host` stale，三条小型任务因此消耗 `751,412` reviewer tokens。产物 reviewer 现只按固定 snapshot 的 workspace、artifact、input、dispute 判断 freshness，纯 turn／status／观察变化不再使它过期；过程 reviewer 仍审查 Root 行为并保留 `host` stale。`check` 的机器响应要求 Root 结束当前 turn 等待唤醒。固定 snapshot 的 added／modified／deleted 路径另作为有界 `review_focus` 交给 reviewer：先看这些路径和直接依赖，但不得把它当范围限制。该改变先消除重复检查，再用真实模型衡量单次成本，不预先宣称节省额度。

## 检查回路的有效到达（2026-09-18）

[独立审查及复核](../reference/project-review-20260918.md)确认：一次真实开发任务中 7 次已完成检查全部过期、自动投递纠正为 0，检查者自设 30–60 秒的下次观察时间与持续编辑叠加，产生重复完整检查。复核保持版本核对语义不变：过期结论不直接用于当前版本，也不能静默丢失。程序把过期检查中待纠正的问题记为待核对线索，在 Root 交付或下一次约定检查时对新版本重新核对，确认后自动送达 Root；检查完成时记录具体过期原因；Root 正在执行时，完整检查间隔以约定时间为下限，检查者建议不得使其更频繁。`orbit status` 显示最近检查是否过期、待处理问题与下次检查依据。具体范围与验证要求见[用户结果补齐计划](../plan/user-outcome-completion-plan.md)。

## 跨宿主成员：OpenCode Root → Codex（2026-09-18）

用户要求 Root 能把已授权、实际可用的不同 Coding Agent 纳入分工；首条路径为 OpenCode Root 显式选择 `kind: codex`。任务运行进程为该任务启动并持有独立的 Codex app-server，以 `/tmp` 下的短控制 socket 提供原生接口；成员 thread 在 `turn/start` 前持久登记（kind、socket、宿主 PID／进程组、thread ID、模型和状态）。成员按项目目录创建，模型取自 Codex 自身配置或显式授权，沿用 `approvalPolicy: never`、`workspace-write`（默认权限随后由“成员允许名单与 full access”一节改为 full access）且不加载 Orbit MCP，不沿用 OpenCode 的 provider／model 字符串。结果从成员原生会话读取并经 Root 现有通道回传。

停止确认覆盖成员当前 turn、宿主跟踪的后台终端，随后关闭成员 app-server 并核对进程组退出；socket 消失本身不是停止证据，进程组不存在才是。运行进程异常退出而成员宿主仍存活时，记录保留可重连地址，显式 `stop` 重试从任务记录重连、停止并核对；证据不足保持 `stop_unconfirmed`。成员会话按原生记录保留，不要求终态后成员仍在线。Herdr／tmux 只可用于展示，不承担投递、结果或停止控制；同宿主 `delegate` 保留，不为跨宿主放宽沙箱、权限或停止证据，也不在本轮建设其他 kind、通用注册中心或热更新。真实验收要求分别证明结果回到原 Root、执行中中断与后台工作退出、运行进程异常退出后的显式停止重试，以及会话历史保留；验证事实见 [跨宿主成员验收](../reference/cross-host-member-acceptance-20260918.md)。

## Codex 会话内 Orbit MCP 的审批与调用身份修正（2026-09-18）

`orbit codex` 原先按服务名 `orbit` 写 per-tool 审批覆盖；Codex 只按实际工具名 `task` 匹配 `mcp_servers.orbit.tools.<tool>.approval_mode`，未匹配时回退默认 `auto`，对缺少只读标注的自定义 MCP 工具要求审批，`approval_policy=never` 会话因此收到 “MCP tool call requires approval, but approval policy is never”。修正为按真实工具名设置 `approve`：仅 `orbit.task` 在该入口启动的会话内预批准，其他工具、shell 沙箱、成员边界与全局配置不变。验证中发现 Codex 0.155 通过 `_meta.threadId` 传递调用方会话身份，MCP 桥接随后同时接受该键与旧的前缀键，`start` 才能绑定当前 Root；此前 `start` 因缺少身份失败。真实验证见 [Codex 审批与 MCP 调用验收](../reference/codex-approval-acceptance-20260918.md)。

## 成员允许名单与 full access（2026-09-18）

用户明确授权默认允许 `codex、omp、opencode、kimi、cursor-agent、grok`，并让 Orbit 新启动的执行 Agent 默认 full access，避免成员在受限沙箱内反复审批或执行失败；同时要求只声明实际接通的路径，不为凑齐 kind 写按键或屏幕解析。

- 允许名单：可选 `~/.config/orbit/members.json` 只含 `allowed_kinds`。缺失时用默认六项，存在时完整覆盖，空数组禁止创建新成员；`native` 解析为 Root 实际 kind 后检查。派发前先检查名单与适配器，失败在创建任何宿主或成员之前给出具体原因；名单变化不影响已登记成员的停止与结果回收。
- 适配器范围：只声明同宿主 Codex／OpenCode／OMP 成员与已验收的 OpenCode Root → Codex 成员；`kimi`、`cursor-agent`、`grok` 允许但无可调用适配器时表现为不可调用并说明缺口，不新增供应商适配器。`doctor` 显示允许、可调用与缺口。
- 权限：Codex 执行成员明确设置 full access（`approvalPolicy: never` + `danger-full-access`）；OpenCode 成员沿用 Root 原生权限与模型配置，用户已确认其默认权限满足日常编码，Orbit 不修改该权限接线；OMP 成员沿用 Root 原生权限与工具集。`orbit codex` 把本次启动的权限作为唯一策略：默认 full access，显式沙箱／审批参数按字段覆盖，TUI argv 不再携带权限覆盖参数；入口自有的透明代理在 `thread/start`、`thread/fork`（`threadSource=user` 非 ephemeral）与 `thread/resume` 的历史边界原子应用该策略，原生界面内 `/new`、`/resume`、`/fork` 与首次启动一致，系统／ephemeral 线程不改写。Orbit 控制、成员、检查者与停止链继续直连 `control.sock`。`-p/--profile` 首版明确拒绝，不新增 TOML 解析；其他权限形态不纳入改写。不修改全局配置，不扩大检查者与裁定者的只读权限。分工提示在状态新鲜度复核后发送，同次判断触发的检查优先。
- Jev 分工提示：在同一请求中增加“可能适合独立分工”的概率；只有存在允许且可调用的成员时至多提示 Root 一次，不自动派发、不选择 kind、不替代检查者。记录信号、实际派发与额外用量；无收益不增加阈值或路由。真实样本尚未触发提示，分工收益未验证。

真实验收要求：名单允许与拒绝都在创建前生效；不支持 kind 不报成可调用；当前受控路径成员真实任务无反复审批、结果回 Root、停止确认；Codex 新会话与恢复分别核对；Jev 提示最多一次且不自动派发。验证事实见 [成员名单与 full access 验收](../reference/member-policy-acceptance-20260918.md)。

## `orbit codex` 权限的单一权威（2026-09-19，已实现并完成隔离真实验收）

用户在 `orbit codex --dangerously-bypass-approvals-and-sandbox` 打开、显示 YOLO mode 的界面内使用 `/resume`，收到 Codex 的 “Permission overrides are not supported when resuming a remote task”。上一轮只处理了启动命令带 `resume` 的路径，覆盖不到界面内的原生会话操作。用户认定继续按命令逐条修补不可接受，要求从根上解决；本节记录经用户认可的决定与理由。问题定义见 [Codex 远端会话入口的权限边界问题](../plan/codex-remote-session-boundary-20260919.md)。

### 根因

Orbit 把“本次启动选定的权限”这一个意图同时交给两个主体：远端 TUI 的启动参数与入口持有的 app-server 配置，再在两者分歧或 Codex 拒绝其一的每条路径（新建、`resume UUID`、`--last`、picker、界面内 `/resume`、fork）分别修补。Codex 远端模式本身只有一个权限主体。按 Codex 0.155 源码核对（`codex-rs/tui/src/app_server_session.rs`、`tui/src/app/config_persistence.rs`、`tui/src/app/thread_routing.rs`、`tui/src/chatwidget/settings.rs`、`app-server/src/request_processors/thread_processor.rs`、`persisted_resume_settings.rs`、协议 `v2/thread.rs`）：

- 远端 TUI 对 `thread/resume` 与继承式 `thread/fork` 不发送审批、沙箱和权限 profile，由 server 恢复保存的设置；TUI 带 CLI 权限覆盖，或选中的 profile 含审批／沙箱字段时，远端 resume 会被拒绝。隔离实测未复现“用户在界面内运行时改过权限就会被拒绝”，不把它列为根因。
- 远端 TUI 的 `thread/start` 会把自己配置里的审批策略和沙箱发给 server，盖过 app-server 的 `-c` 配置；这是当前实现不得不同时给 TUI 传权限参数的来源。
- server 恢复线程时只回填保存的审批策略、审批路由与命名 permission profile，不回填 legacy 沙箱。
- server 提供 `thread/settings/update`（`approvalPolicy`、`sandboxPolicy` 或 `permissions`），对任意已加载线程生效，写入会话记录（后续恢复也会沿用），并广播 `thread/settings/updated`；TUI 收到后更新自己的权限配置与状态栏，之后每个 `turn/start` 发送更新后的审批策略，沙箱保持跟随 server。Orbit 现有控制连接已以 `experimentalApi` 初始化，可直接调用。

### 已决定的原则

1. 权限只有一个产品权威：同一次 `orbit codex` 启动选定的权限必须与状态栏和每一轮实际执行一致。
2. 新建、`resume`、`--last`、picker、界面内 `/resume`、`/new` 与 fork 必须经过同一条生命周期规则，不能逐条增加特殊分支。
3. 权限必须在 `thread/start`／`thread/resume`／`thread/fork` 的生命周期边界原子确定，并在首个 `turn/start` 前生效；用户在会话内显式改动权限后由 Codex 原生接管。
4. Orbit MCP 仅预批准 `orbit.task`，不写全局配置，不扩大检查者与裁定者的只读权限；执行成员的权限决定不受本节影响。

### 理由

让用户把 full access 写进 `config.toml` 会把 Orbit 的默认扩散到用户所有 Codex 用法，并违背不写全局配置的边界。权限仍需由 Orbit 的本次入口选择，但必须通过一个覆盖所有线程生命周期操作且无首轮竞态的控制点实现。

### 已否定的具体机制

- 第二控制连接在隔离实测中没有收到 TUI 的 `thread/started`；轮询能发现线程，但属于事后观察。
- 轮询发现后立即调用 `thread/settings/update` 仍输给 TUI 首轮 `turn/start`：首轮实际为 `on-request + danger-full-access`，第二轮才成为 `never + danger-full-access`。因此“每个线程更新一次”不满足首轮权限承诺。
- app-server 提前创建带目标权限的空线程后，远端 TUI 无法恢复它，返回 `no rollout found`；不能用空线程预创建堵住竞态。
- `-p` 指向含权限字段的 profile 也会触发远端恢复拒绝；仅剥离显式权限标志不完整。
- 完整证据见 [Codex 远端会话入口的权限边界问题](../plan/codex-remote-session-boundary-20260919.md)。

### 已验证的实现机制

- Codex 的 `thread/start`、`thread/resume`、`thread/fork` 请求本身都接受 `approvalPolicy` 与 `sandbox`。隔离代理在请求进入 app-server 前原子改写这两个字段后，新建、终端恢复、界面内 picker、`/new` 与 `/fork` 均成功，状态栏与首轮 `turn_context` 一致为 `never + danger-full-access`。
- 生产入口使用双 socket：Orbit 控制连接直接访问 app-server 的 `control.sock`；TUI 通过透明代理的 `tui.sock`。代理只影响本次用户界面，不改变成员、检查者与停止连接。
- 新建和 fork 仅改写 `threadSource: "user"` 且非 ephemeral 的请求。实测的标题生成线程是 `threadSource: "system"`、`ephemeral: true`，过滤后保持原来的 read-only。resume 请求没有来源字段，只在 TUI 专用 socket 上统一处理。
- TUI 不再接收直接权限标志；入口解析它们形成代理策略。`-p/--profile` 内含权限字段时，TUI 会在请求发出前拒绝远端 resume/fork，首版明确报不支持而不静默丢弃 profile；没有真实需求前不引入 TOML 解析或配置镜像。
- 已按此实现：入口解析一次策略并移除 TUI argv 中的权限覆盖参数，TUI 连接 `tui.sock`，代理只改写用户线程生命周期请求；按目标 UUID 预测恢复设置、项目内替换 `--last`、picker 拒绝及保存沙箱推断的旧实现已删除，原生命令统一经过生命周期边界。隔离真实 TUI 结果见 [Codex 远端会话入口的权限边界问题](../plan/codex-remote-session-boundary-20260919.md) 的落地与验证一节。

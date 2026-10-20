# TypeScript Core 与 DSH 实施计划

状态：2026-10-20 用户确认七项决定（见 [ADR-015 修订](../adr/015-typescript-core-and-dsh-migration.md#2026-10-20-修订)），宿主探针已跑通（见[探针记录](dsh-host-probes.md)）。本文是实施依据；产品语义仍以任务运行合同与集成合同为准。未开始写 Core 代码。

## 1. 结构

| 包 | 内容 | 依赖 |
| --- | --- | --- |
| `@orbit/core` | 任务记录、要求版本、工作单元、派发登记、检查调度、覆盖/finding/裁定、完成门、停止状态机、角色池与授权、JEV 客户端、账本、快照/归档、导出、旧 OMP 记录读取。对宿主只暴露一个 `HostPort` 接口 | 零 Cordis/DSH 依赖 |
| `@orbit/dsh-host` | `OrbitService extends Service`，ctx key `orbit`；用 DSH 接缝实现 `HostPort`；注册监听、工具、命令、预设、私有控制 socket、`@Remote` 命名空间 | DSH 最新版 |
| `@orbit/dsh-ui` | 客户端插件：面板与对话行；只读 `orbit` Remote 与 session 事件 | 随宿主 release 重建 |
| `orbit` bin | 文件读取（status/export/events）+ 对活插件的 socket 调用；`orbit launch` 返回 dsh 启动规格 | `@orbit/core` 读模块 |

四者打成**一个 npm 包**，`dsh.bundle.patch` 指向 cordis.patch.yml。安装与更新走 DSH：Web Plugins 页、`plugin_manager` 工具或 `dsh plugin add` 后在 profile 清单里选中。Loom 节点机器同样安装，从 profile 目录解析 bin。

Core 与宿主插件同进程。进程隔离只留给检查者与 JEV 压缩 runner。接受的取舍：任一兄弟插件的未捕获异常可在写入中途带走 Orbit；缓解是每次写入原子化，重启后宿主死亡期间的任务一律 `stop_unconfirmed`。

## 2. 受控 profile

Orbit 只发布 bundle；profile 从 DSH 模板派生：`dsh --profile orbit-app --from-default-profile web`，再装 bundle。三个 profile：

| profile | 模板 | 用途 |
| --- | --- | --- |
| `orbit-app` | web | 应用内直接使用 |
| `orbit-node` | sdk | Loom 节点拉起；stdin EOF 即有界关闭 |
| `orbit-checker` | sdk | 检查者子进程；只读预设 |

bundle patch 按 id 覆盖 `disabled: true`：`cordis-host-runner`、`cordis-client-runner`、`tool-cordis`、`tool-plugin-manager`、`hmr`、`goal-round-driver`、`command-goal`、`tool-goal`、`schedule` 唤醒、`session-log-deepseek`、`session-title-llm`；Creator 预设不用于受控会话；approval 策略 `never`；sandbox `workspace-write`，检查者 `read-only`。用户 home patch 优先级高于 bundle（T0b 已证实），所以每次启动前用 `--dump-config` 做 T0 断言，不符合即拒绝受控会话。

## 3. 义务到接缝

| 义务 | DSH 接缝（已探针） | 实现要点 |
| --- | --- | --- |
| H1 入口 | `agent/pre-step` | 首 step 前读 claimed messages 的 `id`/`source`；拒绝则 turn 落盘无 step |
| H2 投影 | `ctx.systemPrompt.section` + 动态 context provider | 要求与修订每次 admission 前重读；不写进用户消息 |
| H3 工具门 | `restrict` + `guard` | guard 不可被 pre-execute 的 allow 覆盖；读根限制必须由 guard 做，沙箱只管写 |
| H4 登记 | `agent/created`（serial，抛错回滚）+ `llm/stream` 路由核对 | 派发用 `startActivation` 带 `childId`；在 created 里同步写成员记录并 flush |
| H5 停止 | 见 §4 | |
| H6 回执 | `sessionProjections` 单元折叠 `request/context`、`assistant/message` usage、`tool/call`/`tool/result` | 不订阅原始事件重扫 |
| H7 检查者 | `dsh-sdk` 后端，caller delivery，独立 home，脱敏 env | 发行物带 `dsh-subagent-dsh-sdk` 与 `dsh-sdk-client`；`dshBin` 指向 JS 入口 |
| O2 修订送达 | `ctx.subagents.sendMessage` | 记录 MessageId |
| O3 提问 | `user-questions/request` answerer | sdk profile 需插入 `dsh-tool-ask-user` |
| 应用入口 | `ctx.commands`、Root 预设内的 `orbit` 工具、`@Remote` | 三者调同一 Core 函数；授权类动作只给用户 |

每条注入的 `UserMessage` 必须完整（id、role、content、source）；活 API 不校验，读取端会拒绝整份日志。

## 4. 停止：任务级围栏 + 精确收束

Orbit 持久记录每个任务的归属集合：Root 会话、每次派发的 activation、检查者进程、自己注入的消息 id、自己发出的问题 id、以任务会话为 owner 的 job。

1. 先落盘围栏（`stop_requested`，`fence=armed`，永久保留）。
2. 围栏生效点：`agent/created` 拒绝已停任务成员会话的 resume；`agent/pre-step` 拒绝本任务注入消息、本任务问题的 `user-question-reply`、本任务成员的 agent-message，放行新用户消息；`guard` 对本任务 agent 的工具一律拒绝；`llm/stream` 对本任务 agent 拒绝新流；不接受本任务 agent 的新提问。
3. 精确收束：成员 `activation.dispose()`；Root `cancel(cause, {keepInbox:true})` 后只移除本任务注入的消息并等 `whenIdle()`；jobs 按 owner `list` → `kill(id, caller, reason)` → `wait`，必须在会话日志观察到 `job/settled`；检查者 dispose 走 SDK 关闭阶梯；terminal `terminate()`。
4. 证据与判定：

| 证据 | 来源 |
| --- | --- |
| 围栏已落盘 | state.json |
| Root 与成员 idle，无未配对 `tool/call` | agent status + 会话日志 |
| 派发 activation 已 dispose，result 已结算 | activation |
| 本任务会话 owner 的 job 都有 `job/settled` | 会话日志 |
| terminal 已 terminate | 子进程 seam |
| 检查者进程已退出 | SDK backend 回执 |

任一缺失即 `stop_unconfirmed` 并列出缺项。DSH 的 JobView 没有 pid；探针观察到 dispose 与 kill 后无 OS 残留，但 macOS 子进程层对 root 退出后未观察范围保持 unknown，这类情况保持 unconfirmed。宿主崩溃后日志带 `turn/end {kind: interrupted}` 与"outcome is unknown"的 tool/result，映射为 `stop_unconfirmed`。

## 5. 宿主日志三层读取

| 层 | 时机 | 机制 |
| --- | --- | --- |
| A 在线投影 | 宿主运行中 | `sessionProjections.stateOf`、`sessionQuery.readSurface` 派生可见文本、用户消息、活动、问题、送达；经 socket 给 CLI，经 Remote 给 UI |
| B 证据归档 | 检查开始/结束、完成、停止、宿主关闭 | `sessionQuery.readSession` 取完整校验快照，对 Root 与成员增量写入任务目录，附 DSH 版本、逻辑格式版本、seq 范围、摘要 |
| C 事后读取 | 宿主已退出 | CLI 只读 B 层 |

B 层用 DSH 官方读取 API 与逻辑格式，不解析物理 zstd 文件。两个缺口如实记录：宿主死后不能再取快照，最后归档到停止之间记 gap；两个归档点之间生灭且未观察的成员会话记未归档。不读旧 OMP 记录，不提供旧字节偏移读取（ADR-015 修订第 8 条）。

## 6. Loom

节点拉起 `dsh --profile orbit-node`，持有 stdin，全程只用 `orbit` CLI；停止确认后关 stdin。Root 会话由插件创建，`--thread` 不再需要。集成合同出 **2.0**，字段按 DSH 重新设计（ADR-015 修订第 9 条）：能力集合至少覆盖启动规格、状态、停止回执、事件游标、会话投影（可见文本、用户消息、活动、问题与送达）、提问答复、导出、模型授权；不再保留 OMP 时代的 `session_file`、字节偏移与 `provider="omp"` 假设。节点必改：启动、活动来源、送达取证、会话文件解析、续接改走 `resume_from`/`resume_wake`、探针改走 `capabilities`/`doctor`，一次改到 2.0；不做 1.x 并行路径。

## 7. 凭据与模型参数

JEV 的 key 走 `ctx.credentials` 引用（默认 `TYPESAFE_API_KEY`），每次调用 resolve；用户经 Orbit 设置卡或环境变量提供。OpenRouter 作为执行路由由 DSH 的 pi-ai 适配器承担；作为能力目录可继续自请求。允许模型、检查模型、角色池进插件 `Config`。检查者子进程看不到父 store，派发前 resolve 后经 provider 实例的显式 env 传入。现有 shell 文件写法退场。

## 8. DSH 版本

不钉版，跟最新。保留三件事：T0 组合断言、编译在 DSH 导出类型上的类型检查、`session-format-catalog` 恢复历史归档。UI 半边本来只在宿主同一 release 下加载。

## 9. 顺序

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| A | 宿主探针 | 已完成，见探针记录 |
| B | 切片一：Root、显式 start、要求注入、一个本地 spawn 成员、停止、检查者子进程、`status/stop/events` CLI | 未开始 |
| C | 应用 UI、合同 1.9、Loom 节点改造 | 未开始 |
| D | 历史读取、安装升级、干净切换、Ruby 退场 | 未开始 |

B 阶段开工前只需补一份短设计：JEV 观察输入在 DSH 事件下的投影形状与去重键，因为它决定重校准，已写在[观察投影设计](jev-observation-projection.md)。其余在实施中决定：Root 的 `orbit` 工具参数定义（做完给用户过目）、工作单元范围 guard 规则、工具链与包命名（开工时问一次 npm scope）、任务记录格式（全新设计，不兼容旧记录）。C 阶段的界面由 AI 先做第一版，合同 2.0 字段在 C 阶段设计时定。

## 实施决定（2026-10-20，切片一开工）

- 仓库布局：pnpm workspace，`packages/core`、`packages/dsh-host`、`packages/cli`、`packages/dsh-ui`；内部包暂用 `@orbit/*` 私有名，发布 scope 仍待用户确认（检查点 1）。
- 工具链与 DSH 对齐：Node `^22.19.0 || >=24.0.0`、TypeScript 6.0、tsdown 0.22、vitest 4；tsdown 产物为 ESM（`.mjs`/`.d.mts`）。
- 任务记录 v1（全新，不兼容 OMP）：`state.json`、`members.json`、`work-units.json`、`findings.json`、`requirement-coverage.json`、`checks/<n>.json`、`events.jsonl`。`TaskStore` 是唯一写入口；每个文件原子写（临时文件 + fsync + rename + 目录 fsync），进程内串行，事件序号单调。
- 完成门：只认当前输入与产物版本的手动 reviewer 检查（`verdict=complete`、`delivery.ready`、`coverage.complete` 且所有 delivery 项 verified），并要求无 open finding、成员全部结算、无在途检查、停止证据齐全；否则停止后记 `paused` 并写 `completion_invalidation`。
- 检查结果在边界用 zod 校验，并落实合同语义：非空文本、覆盖 requirement 去重、verified 必须有 evidence、`gap_kind` 仅用于 unverified、`ref` 长度与控制字符规则。
- finding 去重按六项绑定（输入摘要、产物根、产物摘要、requirement、evidence、action）；绑定不变时只累计 repeats，绑定变化时重开。
- 当前验证：`@orbit/core` 的 14 个 vitest 用例通过，覆盖记录持久化、修订版本、停止围栏、成员与工作单元、完成门、finding 去重与重开、检查结果校验；尚未接 DSH 宿主，未跑 T0/T1、真实模型或 Loom。

## 实施进展（2026-10-20，切片一宿主接线）

- `@orbit/dsh-host` 以 Cordis service `orbit` 装载；`orbit` 工具提供 `start`/`status`/`stop`/`declare`/`finish`/`accept`/`reject`，全部调用 Core 的单一写入口。
- H4 接线：`tools/pre-execute` 校验受控 `subagent` 调用的 prompt 含 `orbit-unit: wu-...`、单元已声明且输入/产物根匹配，然后把派发暂存；`agent/created` 在子会话首次模型调用前完成 `members.json` 登记，登记失败抛错阻断创建。
- H3/H5 第一层：停止后把 Root 与已登记成员加入进程内围栏集合，guard 拒绝其工具调用，`agent/created` 拒绝已停会话的 resume，`tools/pre-execute` 拒绝已停任务的新派发。围栏的持久来源仍是 `state.json` 的 stop 记录。
- 验证：`tests/host_conformance/orbit-host-probe` 在隔离 `DSH_HOME` 用假模型跑通 start → declare → 受控 subagent 派发与成员登记 → stop 围栏 → 第二次派发被拒；日志在 `$DSH_HOME/results/orbit-host.out`。零真实模型、零网络。
- 尚未实现：停止的实际资源收束与 `confirmStop` 证据、成员结算后的自动状态、要求注入与每轮状态、观察投影、检查者子进程、CLI/socket、T0 组合断言、受控 profile bundle。
- 已知限制：围栏集合是进程内缓存，插件重启后需从任务记录重建；当前 probe 的 `stop` 只落围栏，任务仍为 `running`，不宣称停止已确认。

### 同日追加：停止收束与要求注入

- `orbit` 工具 `stop` 先持久化围栏，再在工具结果送达后异步执行收束：取消 Root 与已登记成员、等待 idle（每项 5 秒上限）、把未结算成员记为 `stopped`、重读检查在途状态，最后用实际观察到的证据调用 `confirmStop`；证据缺失保持 `stop_unconfirmed`，不伪造确认。
- 围栏集合持久到 `$DSH_HOME/orbit-fences.json`（原子替换），插件重启时加载；任务记录仍是唯一权威，缓存丢失只会削弱重启围栏。
- H2 第一版：任务启动后在 Root 的 agent 作用域注册 `systemPrompt.context`，每次 admission 从 `state.json` 重读原始要求与全部修订；读取失败显式声明记录不可读。
- 探针新增断言：停止后状态为 `paused`、`stop.confirmation.confirmed=true`、`missing=[]`；成员结算为 `stopped`；第二次派发被拒；模型侧观察到 Orbit 要求上下文的调用 10/12。
- 仍未做：检查者子进程、CLI/socket、T0 组合断言与受控 profile bundle、冻结验收 #1/#2、真实模型与 Loom。

## 实施进展（2026-10-20，CLI 与私有 socket）

- `@orbit/dsh-host` 在任务启动时为项目创建私有 Unix socket `<project>/.orbit/orbit.sock`（0600，陈旧文件可回收，活 socket 拒绝覆盖；插件卸载时关闭并删除）。协议是逐行 JSON：`{id, method: status|events|stop, task?}` → `{id, ok, result|error}`，单行上限 1 MiB。
- `@orbit/cli`（bin `orbit-ts`，D 阶段再并入 `orbit`）实现 `status` / `events` / `stop`：有活宿主时走 socket，status/events 无宿主时回退只读本地记录；stop 无活宿主时失败关闭。
- 验证：新增 8 个 vitest（control server 3、CLI 5），全套 22 个通过；DSH T1 探针改为通过真实 CLI 子进程执行 status/events/stop，外部 stop 后任务 `paused`、`confirmed=true`、围栏仍拒绝第二次派发。
- 仍未做：检查者子进程（H7）、T0 组合断言与受控 profile bundle、真实模型、冻结验收 #1/#2、Loom。

## 实施进展（2026-10-20，独立检查者与完成门）

- H7：`orbit` 工具新增 `check`，用 `digestWorkspace` 对产物根做确定性摘要（路径、可执行位、大小、内容/链接目标；排除 `.git`/`.orbit`/`node_modules`，有界），再经 `dsh-sdk` 后端启动独立 DSH 子进程；子进程使用隔离 `DSH_HOME`、独立 profile 与只读意图，返回 `check-result` JSON，由 Core 的 zod/语义校验落盘。provider 缺失、非 completed 或非法结果都失败关闭并记 `check/failed`。
- 新增 `complete` 动作：先核对完成门（当前手动终检、覆盖完整、无 open finding、成员结算、无在途检查），再入队完成停止；收束后用同一产物摘要复核并记 `complete`，否则 `paused` + `completion_invalidation`。
- 停止围栏改为任务边界：停止后除 `orbit` 工具外全部 fenced；同一 Root 会话成功 `start` 新任务会释放会话围栏，旧任务记录与成员仍保持终态。
- 验证：DSH 探针装入 `@deepseek-ai/dsh-subagent-dsh-sdk` / `dsh-sdk-client`，用独立 checker profile 的假模型返回合法结果，跑通 start → declare → check（completed、finalization=true）→ subagent 登记 → finish/accept → complete（confirmed、missing=[]、completion 记录）→ 旧任务围栏拒绝派发 → 同会话新任务 start → CLI stop 后 paused。实时日志见 `$DSH_HOME/results/orbit-host.out`。
- 仍未做：T0 组合断言、受控 profile bundle/preset、真实模型（checker 与 Root）、冻结验收 #1/#2、Loom。

## 实施进展（2026-10-20，T0 与受控 bundle）

- 新增 `@orbit/bundle`：`cordis.patch.yml` 禁用 `tool-plugin-manager`、`hmr`、`session-log-deepseek`、`session-title-llm`、goal 四行、`cordis-host-runner`、`cordis-client-runner`、`cordis-inspect-providers`、`ui-cordis`、Creator `preset-cordis`；固定 approval `never`、sandbox `workspace-write`，并补上匹配的 `orbit-controlled` permission preset（否则 permission-presets 拒绝启动）。checker overlay 把 sandbox 与 permission preset 改为只读。
- 新增 T0：`packages/dsh-host/src/profile.ts` 解析 `dsh --dump-config` 的有效配置，要求禁用行、`approval.policy: never`、`sandbox-policy.mode`、`permission.defaultPreset` 与 `approval: never`；`orbit-t0` bin 直接对运行中的 profile 做断言。
- 验证：在 web 模板 profile 装入本地 bundle 后，`--dump-config` 191 行通过 T0；用户 home patch 重新启用 `hmr` 时 T0 失败（T0b）。受控 profile 实际启动成功，无激活错误或 pending 行；T0 单测 9 个。
- 仍未做：bundle 发布与 `orbit` 单包、真实模型、冻结验收 #1/#2、Loom。

## 实施进展（2026-10-20，修订、导出与 profile 派生）

- `orbit` 工具新增 `amend`：Root 提交用户修订原文与可选原生 message id，Core 追加输入版本；后续每次 admission 的要求上下文自动读到新版本，旧版本工作单元自然失去派发资格。
- `orbit-ts export [TASK] --output FILE`：只读快照任务目录为自包含 JSON（state、events、members、units、checks、coverage 等，文本 UTF-8 / 二进制 base64），不联系宿主、不上传。
- 新增 `packages/bundle/scripts/derive-profile.mjs`：从 web/sdk 模板派生 profile，拷入本地构建的 host 与 bundle，写入 `dsh.profile.bundles`，应用 app/checker overlay，并运行 T0。app 与 checker 两个 profile 都派生成功并通过 T0；app profile 实际启动无错误。
- bundle 的 web 专属禁用行移到 `profiles/orbit-app.patch.yml`，避免 sdk/checker profile 出现“entry not found”；共享 patch 只保留各模板都存在的核心行。
- 探针新增 amend 与 CLI export 断言：输入版本变为 2、模型上下文在 18/22 次调用中看到修订、导出 7 个文件且包含两个输入版本。
- 仍未做：单一 npm 包、真实模型、冻结验收 #1/#2、Loom、B2 其余义务。

## 实施进展（2026-10-20，争议、重绑定与过程检查）

- 争议/裁定：新增 `disputes.json`、`orbit` 的 `dispute`/`ruling` 动作。Root 对 open finding 可开争议；`adopt` 把 finding 记为 resolved（`resolution=ruling`），`uphold` 保持 open。同一 finding 只允许一个 pending 争议；结果与理由进事件。
- 工作区重绑定：`rebind` 只接受同一真实路径，或同一 Git common dir 的另一 worktree；Core 记录 history，宿主在 start 时采集 realPath/gitCommonDir/worktree/HEAD。旧终检因产物根变化自然失效。
- 检查通道：`check` 新增 `kind=artifact|process`。过程检查可以完成并由宿主记录，但永远不会产生 `finalization_notice`；探针中过程检查 `finalization=false`，随后 artifact 检查才产生 notice。
- `status`/CLI 增加 open disputes 计数与字段。
- 验证：新增 5 个争议/重绑定单测；DSH 探针跑通 process check → artifact check → 完成链路，24 次模型调用。
- 仍未做：JEV、角色池/严格模型授权、drift 校验、takeover、真实模型、冻结验收 #1/#2、Loom。

## 实施进展（2026-10-20，观察投影与判断客户端）

- 新增 `orbitObservation` 会话投影单元（`stateVersion=1`，仅 host 侧）：把 `turn/*`、`step/start`、`tool/call`、`tool/result` 折叠成操作环，记录 id/seq/turn/step/名称/声明目的/产物根相对目标/状态/起止时间；状态区分 `ok`、`error`、`aborted`、`interrupted`、`not_observed`，`turn/end interrupted` 会标记未完成操作并记 `crashGap`；只保留最近 50 条，窗口取最近 20 条并给出省略数与 history/crash gap。宿主启动时注册，DSH 探针实测 3 条操作、`lastTurnStatus=completed`。
- 新增 `observation-key`：按合同把输入摘要、产物根真实路径、产物摘要、host 稳定状态（最近 10 条操作哈希）、open findings、dispute、trigger 规范化后哈希为 64 hex；字符串超过 2000 字符时保留前缀 + 长度 + 全文 SHA-256；对象键排序、数组顺序保留。
- 新增 TypeSafe System One 客户端：`POST /v1/systemone`，`questions[].true_criterion/false_criterion` 线格式；任何 HTTP/网络/缺答案/越界概率都返回 `unavailable`，保留可得实际模型与 usage，不产生部分答案。
- 验证：观察投影 6 个、观察键 5 个、TypeSafe 4 个单测；全套测试继续通过。
- 仍未做：JEV 观察输入组装与 5s/5min 调度、成员/检查者选型问题集、真实 key 与真实模型、Loom。

## 实施进展（2026-10-20，JEV 观察输入与调度）

- 新增 `jev-observation-input-4`：把任务状态、原始要求与修订、成员/工作单元、投影窗口（最近 20 条操作、省略数、history/crash gap）、最近检查、open findings、产物摘要和 async job 数组装为 `jev-observation-4` 输入；不发送工具输入输出、长回复或日志。
- 观察键复用 `observation-key`，host 稳定字段来自投影（最近 10 条操作哈希），触发原因标为 observation。
- 宿主调度：任务启动后 5 秒首次观察，之后 5 分钟一次；任务非 running、已有 stop 围栏、检查在途、或 `TYPESAFE_API_KEY` 不可解析时跳过且不补发。每次调用写 `jev/observation` 事件（key、status、callId、answers/model/usage 或 unavailable 原因）；任一概率达到阈值（暂定 0.5，未重新校准）写 `jev/signal`。停止时清理定时器。
- 验证：JEV 输入/键/问题集 3 个单测；DSH 探针用本地 TypeSafe 端点验证 `jev/observation` 与 `jev/signal`，answers 为 `{stuck:0.9, off_track:0.1}`，signal 记录 stuck。
- 仍未做：信号触发的自动过程检查、输入按需压缩、选型/检查者质量判断、真实 TypeSafe key 与校准、真实模型、Loom。

## 实施进展（2026-10-20，信号触发的过程检查）

- JEV 任一概率过阈值后，除写 `jev/signal` 外，还会在任务仍 running、未停止、无在途检查时启动一次 `kind=process, trigger=auto` 的检查者子进程；同一 observation key 只触发一次，同一任务同一时刻只允许一个自动检查，检查失败记 `check/failed` 与 `jev/process-check-failed`。
- 过程检查提示词只要求指出当前需要纠正的具体问题，明确不判断交付就绪、不授予完成；覆盖可省略，`delivery.ready` 固定为 false。
- 验证：DSH 探针中本地 TypeSafe 端点返回 stuck=0.9，宿主写 `jev/observation`、`jev/signal`，自动启动 check #1（process/auto, completed），随后手动 process #2、artifact #3 产生 finalization 并完成；完整链路不受自动检查干扰。
- 仍未做：按需压缩、成员/检查者选型、真实 key 与校准、真实模型、Loom。

## 实施进展（2026-10-20，严格模型授权）

- 插件 `allowedModels`（精确 `provider/model`）在 `start` 时冻结进任务记录 `authorization`；`llm/stream` 同步监听每个映射到任务的会话：Root 与成员的每次模型流都按冻结名单校验，成员首次流后绑定路由，后续 provider/model 漂移被拒绝并写 `model/violation` 事件；Root 在名单内的原生模型切换不被当成 drift。
- 严格任务必须显式配置 `checkerProvider/checkerModel` 且位于冻结名单内，手动与 JEV 自动过程检查都在启动检查者前核对；理由 effort 不参与路由身份比较。
- 验证：授权决策 6 个单测、Core 冻结名单 1 个单测；DSH 探针在 `allowedModels=['probe/probe-1']` + 显式 checker 配置下完整链路通过。
- 仍未做：CLI 的 `--allowed-model` 入口、检查者子进程内部的名单复核、选型缓存、真实模型。

## 实施进展（2026-10-20，续接与接管）

- `resume`：只接受同项目、同 Root、已确认停止的 `paused`/`needs_user` 前序任务；新任务复制原要求与有效修订（保留来源），把续接消息作为新的有效版本，记录 `continuation.previousTaskId/previousTaskDir/previousStatus/sourceMessageId`，旧任务保持终态不变。
- `takeover`：`start` 可带 `reason`、可选 `priorScope`、原生消息 id 与产物快照（digest/files/bytes/at）；记录 `state.takeover`，不把此前执行追认为受控。快照当前是摘要清单，不是完整字节副本。
- 宿主把 start/resume/takeover 的后续接线收口到 `adopt`：授权绑定、清围栏、要求上下文、JEV 调度、控制 socket。
- 验证：Core 续接/接管 3 个单测；DSH 探针完成 paused 任务 resume（版本 [1,2] + continuation）→ stop → takeover（reason/priorScope/snapshot 落盘）→ stop；全套链路仍通过。
- 仍未做：完整快照副本、prior_scope 追加声明命令、续接的 review-model 继承、真实模型、Loom。

## 实施进展（2026-10-20，固定快照）

- 新增 `snapshotWorkspace`：把产物根复制到任务目录 `snapshots/check-<n>/`，保留内容、权限位与符号链接，跳过 `.git`/`.orbit`/`node_modules`，有文件数与字节上限；使用与 `digestWorkspace` 相同的清单算法，快照摘要与实时摘要可直接比对。
- `check kind=artifact` 现在先落固定快照，再以快照摘要发起检查；`CheckRecord.snapshotDir` 记录路径，检查者子进程的 cwd 指向快照，提示词声明“快照是受检版本、实时工作区可能已变化”。过程检查仍读实时工作区。
- 验证：快照单测 2 个（摘要一致、权限/链接、排除目录、上限）；DSH 探针 artifact check #3 的 `snapshotDir` 存在且检查完成，完成门仍以实时摘要复核通过。
- 仍未做：快照保留/回收策略、并发检查的快照目录唯一性、完整 B 层归档（会话日志增量）、Loom。

## 实施进展（2026-10-20，接管范围声明与快照唯一性）

- 新增 `takeover-scope` 动作与 `appendPriorScope`：仅 takeover 任务、仅 running 状态可追加；记录声明文本、可选理由、实际声明时间与来源 `root-declaration`；同内容重复提交幂等，不覆盖创建时的 `priorScope`，也不追认旧执行。
- 检查快照目录改为 `check-<n>-<random>`，避免并发检查按 nextNumber 命名冲突；快照仍不自动回收（证据保留），导出会带上快照文件。
- 验证：Core 接管声明 1 个新单测（含幂等、非 takeover 拒绝）；DSH 探针 takeover 后声明落盘 `count=1`，随后 stop 正常；全套 79 个测试通过。
- 仍未做：快照回收策略、完整 B 层会话归档、JEV 选型/压缩、单一 npm 包、真实模型、Loom。

## 实施进展（2026-10-20，单一 npm 包）

- 新增 `@zeen/orbit` 单包：`dist/host.mjs`（宿主服务）、`dist/cli.mjs`（bin `orbit`）、`dist/t0.mjs`（bin `orbit-t0`）、共享 `cordis.patch.yml` 与三个 profile overlay；打包时把 core/host/cli 全部内联，`dist/` 除 `@deepseek-ai/*` peer 外自包含。
- bundle patch 的插入行指向 `@zeen/orbit/host`；`derive-profile.mjs` 改为一律安装单包并引导 app/checker profile；旧的 `packages/bundle` 已移除，避免两份 patch 漂移。
- 验证：单包构建后本地装入 web profile，`--dump-config` 191 行通过 T0，受控 app profile 启动无错误；app 与 checker 两个派生 profile 均通过 T0；CLI `orbit` 帮助与导出可用。
- 仍未做：发布/版本与真实 npm scope（检查点 1）、真实模型（检查点 2）、Loom、D 阶段退场。

## 实施进展（2026-10-20，JEV 选型问题与输入投影）

- 新增 `jev-delegation-5`（handoff_fit、member_task_fit）、`jev-candidates-5`（逐候选 `candidate_N_task_fit`）、`jev-checker-task-fit-6`（逐检查者 `quality_N`）问题构造，文本与判定标准沿用现有校准版本。
- 新增 `jev-selection-input-3` 投影：递归剥离 speed/latency/elapsed/duration/throughput/price/cost/quota 以及 comparison、usage、resource_calls、route_costs 等噪声，记录 `omitted_from_judgment`；保留任务要求、候选能力事实与 catalog/exact evidence。
- 暂不应用阈值与决策组合：没有新的真实校准放行记录，阈值不得凭旧样本或猜测启用；先只固定问题与输入形状。
- 验证：新增 5 个选型单测；全套 84 个测试通过。
- 仍未做：选型调用接线、阈值放行、压缩、真实 key/模型、Loom。

## 实施进展（2026-10-20，B 层会话归档）

- 新增 `TaskStore.writeArchive`（任务内相对路径、拒绝 `..`/绝对路径），用于把宿主会话快照写进任务目录。
- 宿主在手动 artifact 检查前后、停止确认后用 `sessionQuery.readSession` 归档 Root 与已登记成员会话到 `sessions/<sessionId>.json`：记录 DSH 会话格式版本、继承事件数、首/末 seq、事件数、事件 JSON 的 SHA-256 与完整快照；不解析物理 zstd 文件。
- 归档失败只记录错误，不阻塞检查或停止；归档是证据，不改变门禁。
- 验证：Core 归档写入/路径穿越单测；DSH 探针 artifact 检查时归档存在（seqCount=70、seqLast=69、摘要记录），完成链路仍通过；全套 85 个测试通过。
- 仍未做：增量归档（当前整份覆盖）、归档点间 gap 记录、快照回收、Loom。

## 实施进展（2026-10-20，选型放行与决策组合）

- 新增 `orbit-quality-decision-4` 放行文件校验：必须匹配当前 decision 版本、四类阈值键、当前三套 question set；缺文件/字段、旧版本、额外阈值都失败关闭。
- 无放行时选型只返回 facts（概率），不产生 `recommended`；有放行时 delegation 先过 `handoff_fit`，再按候选 `candidate_task_fit` 逐个过门，`member_task_fit` 只作诊断、不否决候选；checker 只用 `checker_task_fit` 门。排序只按概率，不引入价格/速度。
- 尚未接线到宿主工具与真实 JEV 调用；当前只有 Core 决策函数，避免没有放行记录时产生自动推荐。
- 验证：新增 6 个放行/决策单测；全套 91 个测试通过。
- 仍未做：宿主 assess 动作与调用接线、输入压缩、真实校准放行、真实模型、Loom。

## 实施进展（2026-10-20，宿主 assess 接线）

- `orbit` 工具新增 `assess`（`assessKind=members|checker`）：用配置的 `memberCandidates` 或显式 checker 路由构造 `jev-selection-input-3` 状态与问题，调用 TypeSafe，写 `jev/selection` 事件并返回概率与决策。
- 没有 `TYPESAFE_API_KEY` 时返回 `jev_unavailable`；没有 `selectionReleaseFile` 或放行无效时只返回 `facts_only`，不产生 `recommended`；放行文件只在启动时加载一次，无效则失败关闭为 facts-only。
- 验证：DSH 探针本地端点返回 `handoff_fit=0.9, candidate_0=0.7`，`assess` 返回 `facts_only` 且无推荐，事件落盘；全套 91 个测试仍通过。
- 仍未做：真实放行文件与真实 key、输入压缩、推荐结果进入自动派发（仍由 Root 决定）、Loom。

## 实施进展（2026-10-20，增量会话归档）

- 会话归档从整份覆盖改为增量段 `sessions/<sessionId>/seq-<first>-<last>.json`：读取已有段的最大 `seq.last` 作为游标，只写新事件；段内记录首/末 seq、事件数、上一游标、事件 JSON 摘要与完整事件。
- 宿主重启或丢失观察导致首事件 > 上一游标+1 时，段内写 `gap {from,to}`；没有新事件时不写空段；损坏的旧段不降低游标。
- 验证：Core 段规划 4 个单测（首段、续段、gap、空）；DSH 探针归档为 2 段（seq 1–69、70–82），无 gap，总事件 82；全套 95 个测试通过。
- 仍未做：归档点与宿主死亡之间的不可观察缺口只能事后标记、无法补齐；快照/归档回收、Loom。

## 实施进展（2026-10-20，JEV 输入按需压缩）

- 新增 `InputCompactor`：仅在能可靠计数且超过容量，或显式标记超限时触发；一次压缩后最多一次重试；空输出、丢失 `mustKeep` 或异常都判失败，最终返回 `unavailable`，不产生部分结果。
- 缓存键绑定原文、用途、必保项、输出预算与规则版本；只缓存成功结果，内容变化即失效。
- 当前未接入宿主 selection 调用：缺少可靠 token 计数/容量事实与压缩模型配置；接线前不宣称压缩已运行。
- 验证：新增 6 个压缩单测（不触发、容量触发、缓存、重试、失败关闭、必保丢失、内容变化失效）；全套 101 个测试通过。
- 仍未做：压缩模型选择、真实 token 计数、宿主接线、Loom。

## 实施进展（2026-10-20，真实模型验收）

- 用户确认最终单包名 `@zeen/orbit`、真实验收走 A（复制现有账户凭据到隔离 home）。
- 在隔离 `/tmp/orbit-real`（web）与 `/tmp/orbit-real-checker`（sdk 只读）上，用 `deepseek-account/deepseek-flash` 跑通真实 Root + 独立检查者：Root 写 `hello.txt` → 手动 artifact 检查 → 检查者返回 complete/ready/coverage complete → 成员派发/结算 → finish/accept → `complete`，停止四项证据全 true。
- 细节、证明与边界见[真实模型验收记录](../reference/ts-dsh-real-acceptance-20261020.md)。凭据只读副本验收后删除，原 `~/.dsh` 未改。
- 仍未做：冻结验收 #1（真实缺陷纠正）与 #2（真实停止中断）、多任务/重启、JEV 校准、Loom、发布安装。

## 实施进展（2026-10-20，冻结验收 #1/#2 真实通过）

- 冻结验收 #1（真实缺陷纠正）：真实检查者先发现 `goodbye` 不符合要求并给出 finding，Root 修正为 `hello`，第二次检查 complete/ready，任务以 checkNumber=2 完成。
- 冻结验收 #2（真实停止）：Root 执行 `sleep 120` 时通过 CLI socket 停止，任务约 1 秒内 `paused`、四项证据全 true、无残留 sleep、会话保留。
- 细节与边界见[真实模型验收记录](../reference/ts-dsh-real-acceptance-20261020.md)。仍未覆盖成员执行中停止、检查者进程在途、宿主崩溃后的 unconfirmed 重试。
- 下一步：Loom C 阶段（合同 2.0 与节点迁移）与 D 阶段安装/退场。

## 实施进展（2026-10-20，停止时收束在途检查者）

- `runChecker` 暴露已发布的 `SubagentActivation`；宿主按检查号记录在途检查者。停止收束时先 dispose 所有在途检查者，若对应检查仍在 `inFlight` 则记 `check/failed {kind: stopped}`，再重读 `checks_settled`，避免把“检查者仍在跑”误记为已停止。
- 检查者结果仍走原有 record/fail 路径；dispose 后的拒绝被限制在本次检查，不污染后续任务。
- 验证：checker 单测覆盖 activation 暴露与 dispose；DSH 探针完成链路无回归；全套 101 个测试通过。
- 未覆盖：真实检查者执行中停止的端到端证据（需要慢检查或真实长检查）；成员执行中停止仍只有取消+settle，未验证子进程残留。

## 实施进展（2026-10-20，真实成员执行中停止）

- 真实模型场景：Root 派发成员执行 `sleep 120`，外部 socket 在约 10 秒后停止；任务 `paused`、确认证据齐全，成员 `stopped`，Root/成员会话归档，无残留 sleep。
- 边界：成员收束使用 `agent.cancel + whenIdle + settle`，未直接 dispose 子 Agent 的 activation；不宣称 activation 级收束已验证。
- 仍未覆盖：真实检查者在途停止、宿主崩溃后的 unconfirmed 重试、Loom。

## 实施进展（2026-10-20，宿主死亡后的孤儿任务恢复）

- 任务记录新增 `runtime {pid, instanceId, startedAt}`；宿主启动/打开任务时对账：运行中任务的 owner 不是当前实例且进程已不存在（或同一 pid 的插件已重载）时，标记 `stop_unconfirmed`，写 `stop.confirmation {confirmed:false, missing:['runtime_gone']}` 与 `task/orphaned` 事件；不再把死亡宿主的任务继续显示为 running。
- 若 owner 是另一个仍存活的进程（例如另一个窗口），不误判为孤儿，只记录警告并保留原状态，避免两个窗口互相抢占。
- 验证：Core 孤儿恢复单测（同实例不变、异实例转 unconfirmed、事件）；DSH 探针完整链路无回归；全套 102 个测试通过。
- 边界：没有心跳/租约，pid 复用或宿主窗口并发写同一任务仍未完全排除；CLI 本地只读 status 不做对账。

## 实施进展（2026-10-20，会话投影与 CLI sessions）

- 新增只读 `projectSession`：从已提交的 DSH 会话事件与 observation 单元投影可见助手文本、真实用户消息（仅 `source.kind=user`）、工具活动、待答问题与 turn 完成送达；宿主已退出或会话不可读时返回 `unavailable`，不伪造在线状态。
- 私有 socket 新增 `sessions` 方法：返回 Root 与全部已登记成员的投影及 `as_of_seq`；CLI 新增 `orbit sessions [TASK] --json`，仅在有活宿主时可用。
- 验证：投影单测 2 个、CLI fake socket 单测 1 个；DSH 探针 CLI 读取 `asOfSeq=22`、visible=1、userMessages=1、activities=1；全套 105 个测试通过。
- 仍未做：投影字段最终按合同 2.0 冻结、离线归档投影、问题/送达的更细分类、Loom 消费。

## 实施进展（2026-10-20，离线会话投影）

- CLI `orbit sessions` 在无活宿主时回退到任务内增量归档：合并 `sessions/<id>/seq-*.json` 的事件，投影可见文本、真实用户消息、工具活动（按 tool/result 判 ok/error/not_observed）、turn 完成送达、归档段数与 gap；无归档时返回 `unavailable`，不伪造在线状态。
- 验证：CLI 归档投影 2 个单测（可用字段、gap、无归档 unavailable）；用真实验收留下的 `/tmp/orbit-real` 任务离线投影，得到 as_of_seq=39、Root 可见文本 2 条、真实用户消息 1 条、活动与成员投影；全套 107 个测试通过。
- 仍未做：合同 2.0 字段冻结、问题/送达细分、离线 gap 与 Loom 消费约定。

## 实施进展（2026-10-20，检查者启动期间停止）

- 真实模型场景：在 `check/requested` 后 1.5s / 6s 停止，均得到 `stop_unconfirmed`、`missing=["root_idle","checks_settled"]`、检查仍 `in_flight`；宿主未伪称确认，也未把检查记成通过。
- 结论：检查者 activation 尚未发布时停止，按失败关闭处理；已发布 activation 的 dispose 路径仍只有单测，缺真实端到端证据。
- 仍未做：慢检查者/更长时序的真实 dispose 证据、`stop_unconfirmed` 的显式重试验收、Loom。

## 实施进展（2026-10-20，停止围栏拒绝迟到检查结果）

- Core 在 stop 围栏已落盘后拒绝 `recordCheckResult`（`stop_fenced`）；检查动作把它记成 `check/failed {kind: stopped}`，不再生成 `finalization_notice`，避免检查者晚到的结果把已停止任务“洗成”通过。
- 探针用 4 秒延迟的假检查者在 activation 已发布后停止：任务 `paused`、`confirmed=true`、`missing=[]`，check #1 `failed/stopped`，无 finalization；验证 dispose + 围栏拒绝的组合路径。
- 真实检查者启动窗口内停止仍按失败关闭为 `stop_unconfirmed`（见真实验收记录），与本次“已发布 activation”场景互补。
- 全套测试 108 个通过。

## 实施进展（2026-10-20，修订送达与任务查找修正）

- `orbit amend` 在写入新输入版本后，向所有仍 `registered` 的成员经 `ctx.subagents.sendMessage` 发送带版本号的修订消息，记录真实 `messageId`（`amendment/delivered`）；失败写 `amendment/undelivered` 与原因，不重发、不伪造送达。
- 修正按会话找任务的逻辑：同一 Root 在停止旧任务后新建任务时，优先返回 running 的新任务，而不是按目录顺序返回已停止的旧任务；否则新任务的派发会被旧任务围栏误拒（探针已复现并修复）。
- 验证：DSH 探针中成员已登记后 amend，事件记录 `version=2`、`memberId`、`messageId`；完整链路其余部分无回归；全套 108 个测试通过。
- 仍未做：修订送达后的成员确认/采用归因、undelivered 的显式重试界面、Loom。

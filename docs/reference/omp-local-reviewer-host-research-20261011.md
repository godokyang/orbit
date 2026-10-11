# 本地 OMP 复用检查器宿主调研（2026-10-11）

状态：只读源码调研报告，供用户审核方案；不是实现、不是验收、不改合同/版本/安装。调研基线：本仓 0.8.4（提交 25f0104 优化已完成，不改其结果）；本地宿主 `~/.local/bin/omp` 为 18.8.0 编译 Mach-O（`file` 与 `omp --version` 实测）；静态源码取自本机已安装检查器 SDK `~/.local/share/orbit/orbit/current/runners/omp-reviewer/node_modules/@oh-my-pi/pi-coding-agent`（18.8.0，含 `src/` 与 `dist/cli.js`）。下文行号均指该 18.8.0 源码树；**源码静态支持不等于当前编译 binary 实测**，所有待验项集中在 §6。

## 1. 问题与体积事实

目标问题：独立检查器随 Orbit 安装携带私有 OMP SDK，能否改为复用用户本地已安装的 OMP，移除该私有 SDK 体积。

实测体积（2026-10-11，`du -sh`，本机）：

| 对象 | 体积 |
| --- | ---: |
| 仓库 dev `runners/omp-reviewer/node_modules` | 946 MiB |
| 日常安装 current 的 reviewer `node_modules` | 948 MiB |
| 其中 `@oh-my-pi/*` 合计 | 294 MiB |
| 其中 `onnxruntime-node` | 292 MiB |
| 其中 `onnxruntime-web` | 142 MiB |
| 其中 `@opentelemetry` | 54 MiB |
| 其中 `sherpa-onnx-darwin-arm64` | 33 MiB |

「约 437 MiB」有第二阶段原始[体积回执](evidence/install-footprint-optimization-20261011/footprint-v3.json)依据：`reviewer_node_modules_kib=447320`，即 **436.8 MiB**；`release_kib=457580`，即整体冷安装 **446.9 MiB**。本轮未重建已清理的该临时安装；这是此前实际记录，不是本轮新测。移除私有依赖树的预期收益以它为参考，最终新构建体积仍须实测，不承诺直接达到某个总安装数字。当前日常安装仍为 958.2 MiB（未应用第二阶段优化，见[交接](../plan/handoff.md)）。

[体积记录](orbit-install-footprint-20261011.md)第 39 行旧结论「用户已有的编译版 `omp` 不能充当可导入 SDK」需要细化：编译 binary 确实不能作为 npm 包被 `bun reviewer.ts` 导入，但其**进程内宿主包可通过扩展加载面到达**（§3），这是本调研的新事实，不 retroactively 改写旧文档。

## 2. 现行检查器调用链（基线）

- 安装前置：`scripts/manage-install.rb:232-260` 的 `prerequisites!` 检查 Ruby、Node、npm、Bun，**没有检查 OMP**；`:505` 在创建 release/staging 前调用它。`:340-341` 当前缺 OMP 时回退到固定 SDK 版本继续安装；`:571-585` 只在安装成功后提醒用户安装 OMP。这不是完全没有提示，而是提示过晚，且未来复用本地宿主的方案不能继续依靠这一回退。
- 实际公开入口还包括仓库根 `install.sh`：远程安装先下载/解包源码，再调用 `manage-install.rb`；因此仅给 Ruby 管理器加检查，不能声称已在源码下载之前提示。方案应在 bootstrap 的 help/参数处理后、源码下载前做 OMP 存在/可运行检查，并在管理器统一前置门再次核对版本，覆盖本地安装、远程安装及直接管理入口；不拦截 `--help` 或卸载。
- `lib/orbit/omp_check_runner.rb:14-17`：`REVIEWER = runners/omp-reviewer/reviewer.ts`，默认命令 `["bun", REVIEWER]`。
- 启动：`omp_check_runner.rb:333-346` 写 request.json（snapshot/profile/out/prompt/model/source_session_fields/sdk_version），`:504-520` 以独立进程组 spawn，`PI_CODING_AGENT_DIR=<全新 profile>`、`OMP_PROFILE/PI_PROFILE` 置空、`chdir` 到输出目录。
- 探针：`:95-126` `probe_models` 同一 runner 的 `--probe-models` 模式，60 秒有界（`:36`）。
- reviewer.ts 核心：
  - SDK 版本闸 `reviewer.ts:329-332`（与安装 pin 漂移即失败关闭）；
  - 源目录/凭据解析 `:229-264`（`discoverAuthStorage(sourceAgentDir)` + `ModelRegistry(authStorage, sourceAgentDir/models.yml, {cacheDbPath})`，凭据不复制）；
  - 精确模型 `:365-369`（`modelRegistry.find(provider, id)`，id 可含斜杠；`:373-379` 凭据预检失败即结构化 `auth_or_quota`）；
  - 隔离会话 `:389-435`（`createAgentSession`：`cwd=snapshot`、`agentDir=全新 profile`、`Settings.isolated` 关 memory/STT/fetch/web_search/github/bash/autolearn/checkpoint/goal/`retry.enabled:false`、`toolNames=[read,grep,glob]` + `restrictToolNames` + `allowRestrictedCustomTools` + `createConfinedTools`、`enableMCP/enableIrc/enableLsp:false`、`disableExtensionDiscovery:true`、`skills:[]/rules:[]`、`hasUI:false`、私有 `AgentRegistry`）；
  - 工具装配断言 `:439-451`（活动工具恰为 read/grep/glob、禁工具缺席、read 为受限替换、全局 registry 无注册）；
  - 回执 `:506-617`（订阅 `message_start/message_end`，call 边界绑定、usage 逐 call 保留、`providerErrorFact` 从 assistant 消息 `stopReason/errorStatus/errorId/errorMessage/errorClassificationMessage` 提取，`provider-error.ts:17-49`）；
  - 快照指纹前后一致 `:629-632`；结果 schema 校验 `:608-614`（`check-result.ts`）；图片字节事实经 `confined-tools.ts:19-41`（sha256/字节数/MIME 嗅探）。
- Ruby 侧回执归一化与失败分类：`omp_check_runner.rb:362-405`（poll）、`:420-433`（stop! 后仍读回执）、`:536-617`（usage 归一化、逐 call receipt）、`:627-647`（structured 优先、heuristic 标注）。

## 3. 关键新事实：编译 binary 的宿主包对扩展可达

静态证实（18.8.0 源码）：

1. **打包宿主包清单包含 pi-utils，不止三个 legacy shim**：`src/extensibility/plugins/legacy-pi-compat.ts:817-825` `PI_PACKAGE_NAMES = [pi-agent-core, pi-ai, pi-catalog, pi-coding-agent, pi-natives, pi-tui, pi-utils]`。
2. **compiled resolution overrides**：同文件 `:993-1062`——shim 根（pi-ai/pi-coding-agent/pi-tui）恒走 compat shim；其余宿主包在 compiled/npm bundle 模式映射到 `omp-legacy-pi-bundled:<key>` 合成模块，解析到**进程内同一份模块实例**（避免插件 node_modules 重复副本，`:806-816` 注释）。`:750-768` 未注册 key 抛错（失败关闭）。
3. **pi-coding-agent shim 再导出完整面**：`legacy-pi-coding-agent-shim.ts` 头部注释与 import 块证实其从 `../sdk` 引入 `createAgentSession` 等并再导出（为绕开 bun --compile 入口冲突，issue #1474）。
4. **api.pi 注入**：`extensibility/extensions/loader.ts:29`（`import * as PiCodingAgent from "../../index"`）、`:451/:472`（`new ConcreteExtensionAPI(PiCodingAgent, …)`），类型面 `extensibility/extensions/types.ts:1375`（`pi: typeof PiCodingAgent`）及 `:1363-1373`（注入 logger/typebox/arktype/zod）。index barrel（`src/index.ts`）`export * from "./sdk"`（createAgentSession）、`"./session/auth-storage"`（discoverAuthStorage/isAuthenticated）、`"./config/model-registry"`（ModelRegistry）、`"./session/session-manager"`（SessionManager）、`"./config/settings"`（Settings，含 `Settings.isolated`，`config/settings.ts:745`）。
5. **可信扩展在宿主会话创建前执行**（Root 独立核对）：`main.ts:1652-1666` `--trusted-extension` 路径解析为 realpath 文件、置 `disableExtensionDiscovery=true`、作为 `additionalExtensionPaths`；factory 绑定/await 于 `main.ts` 约 2287 行，**早于普通宿主 `createAgentSession` 调用**（约 2190-2330 段）。因此扩展 factory 可以先执行完整检查流程、dispose、写证据并退出，**普通 CLI 会话的 MCP 默认（`sdk.ts:2441` `enableMCP ?? true`）可在该候选路径避免；factory 前已经进行的设置、认证、目录与遥测 bootstrap 并未因此消失，需要 §6 实测**。
6. **扩展工具可同名替换内建**：`sdk.ts:3362-3365` 扩展注册工具 `toolRegistry.set(tool.name, tool)` 并删内建名标记；`:3346-3352` 保留 native 原实现供 `ctx.invokeTool` 委托。（`restrictToolNames:true` 时该扩展注册列表不进会话，`sdk.ts:3303`。这是路线 B 的接线参考；路线 A 继续使用现有直接传入 `customTools` 与 `allowRestrictedCustomTools:true` 的受限 SDK 路径。）
7. **RPC 转发可用**：`modes/rpc/rpc-session-events.ts:36-75` 给 `message_start/message_update/message_end` 盖稳定 `messageId`，默认全量转发、可 `set_event_filter` 过滤；rpc 命令含 `prompt`（`rpc-mode.ts:1864`）与 `abort`（`:1915`）。Root 指示纯 RPC 无需再追全部协议；此处仅留证。
8. **CLI 旗标到会话选项的映射**（`omp --help` 实测存在 + 源码）：`--tools/--no-tools`→`options.toolNames`（`main.ts:1625-1629`）；`--no-lsp`（`:1631-1633`）；`--no-skills`/`--no-rules`→空数组（`:1636-1646`）；`--no-extensions`→`disableExtensionDiscovery`（`:1673-1675`，显式 `-e` 仍加载）；`--no-session`/`--session-dir`（`cli/args.ts:62-63,317-318`；`main.ts:531` `SessionManager.create(cwd, args.sessionDir)`）；`--config` overlay 进入 `Settings.init({configFiles})`（`main.ts:1835`），overlay 优先于 protocolDefault（`main.ts:248-254` 注释）。
9. **认证与目录绑定**：`pi-ai/src/auth-broker/discover.ts:324-326` 优先级 env `OMP_AUTH_BROKER_URL/TOKEN` > `<agentDir>/config.yml` 的 `auth.broker.*` > token 文件 > 本地 SQLite；本地 SQLite 恒在 agentDir 下（`:455` `getAgentDbPath(agentDir)`）。`pi-utils/src/dirs.ts:619` `getAgentDir()` 由 `PI_CODING_AGENT_DIR`/profile 决定。即 **CLI 层面没有把「目录/凭据来源」与「会话状态目录」拆开的旗标**；拆分只在库层面可做（reviewer.ts 现行做法）。
10. **信号**：print 模式注册 postmortem（`modes/print-mode.ts:113-122`，SIGINT/SIGTERM/SIGHUP→130/143/129 并 dispose）；**rpc 模式未见自有 postmortem 注册**（grep 无命中），main.ts 仅注册 python 探针与 settings watcher（`:2374`、`:2524`）。

## 4. 候选路线

### 路线 A（推荐）：Orbit 私有子进程 + 可信扩展 factory 驱动既有检查逻辑

形态：Orbit 由 `OmpCheckRunner` spawn 一个**新的、可随时终止的本地 `omp` 子进程**（独立进程组，现有 TERM/KILL 清理不变），命令形如：

```
omp --mode rpc --no-ui --no-session --no-tools --no-pty \
    --no-extensions --no-skills --no-rules --no-lsp \
    --trusted-extension <Orbit 扩展入口的绝对路径> --config <隔离 overlay>
```

- 扩展 factory 在宿主会话创建前执行（§3.5），在 factory 内**原样移植** reviewer.ts 的 `createAgentSession` 调用（§2）：全新 profile agentDir、`discoverAuthStorage(sourceAgentDir)` + `ModelRegistry` 源目录、精确 `find(provider,id)`、`Settings.isolated` 同一组关闭项、`restrictToolNames` + `createConfinedTools`、禁用 MCP/IRC/LSP/扩展发现。imports 全部经宿主打包面（`@oh-my-pi/pi-coding-agent`、`@oh-my-pi/pi-utils` 均在 §3.1-3.2 清单），**不重写 profile/cache 路径规则**。
- 完成后 dispose 私有会话、原子写 evidence.json（沿用 `writeEvidenceAtomically`）、`process.exit`；候选成功路径在普通宿主会话创建前结束；私有检查会话及其资源必须主动 dispose，回执写完再退出。factory 前的 bootstrap 不受这一退出位置保护，需关闭遥测等设置并核验其他副作用。不得把未运行的候选说成已验证无副作用。
- 认证：与现行完全一致——源 agentDir 由 Orbit 在 spawn 前按现有 `source_session_fields` 语义传入，扩展直接 `discoverAuthStorage(sourceAgentDir)`；**不依赖 CLI 的 agentDir 认证路径，也不需要用户运行 auth-broker**。
- 改动面：`reviewer.ts` 主体（~600 行）迁移为扩展模块 + 薄入口；`confined-tools.ts`/`model-probe.ts`/`provider-error.ts`/`usage-receipt.ts`/`json-recovery.ts`/`check-result.ts` 不变；Ruby 侧接入子进程命令、请求传递、探针与版本/能力门；安装器在实际宿主导出与加载探针通过后才移除私有依赖安装，并保持切换前验证、失败保留旧版及 release lease。SIGTERM/取消回执沿 §6/§8 验证，不承诺只有改命令这一行。
- 收益：移除私有 SDK node_modules（日常安装实测约948 MiB；既有优化构建的份额436.8 MiB）；检查器与宿主不用再安装两份不同 SDK。Orbit 自有适配代码仍可能与未来宿主 API 不兼容，不能据此删除能力检测或宣称升级无需验证。

### 路线 B（备选，不推荐）：纯 CLI/RPC 重写检查器

`omp -p`/`--mode json` 或 `--mode rpc` + `--tools read,grep,glob` + `-e` 注册受限同名工具，宿主解析 RPC 事件流取 usage/error。静态证实可行件：同名工具替换（§3.6）、RPC 事件转发与 abort（§3.7）、print/json 输出全事件（`print-mode.ts:64-105`）。

不选原因：

- **CLI flags 不证明目录隔离**：`--tools` 选的是原生 read/grep/glob，非受限实现；受限只能靠 `-e` 扩展——既然必须写扩展，路线 A 直接复用全部既有逻辑更薄。
- **认证/目录不可拆**（§3.9）：用隔离 `PI_CODING_AGENT_DIR` 则丢目录与凭据（除非用户常跑 auth-broker，改变用户环境，否决）；用用户真实 agentDir 则 **不等于隔离**：`~/.omp/agent/mcp.json` 会被加载且 `enableMCP` 默认 true（`sdk.ts:2441`）、无 `--no-mcp` 旗标（`mcp/settings.ts` 只有 project-config/超时/通知键），settings/history/stats 副作用面需逐项关闭——把用户 profile 直接启动当隔离等价是错误前提。
- 会话/usage/错误回执需重写 RPC 帧解析与 messageId 对账，替代现成 `session.subscribe`；`--model` 为模糊匹配（--help 自述），精确性需额外核对。
- `--mode rpc` 无 prompt 可空转（`main.ts:267-269` 允许），但整条链路的协议细节 Root 已指示不再追。

## 5. 需求逐项核对（静态证实 vs 待验）

| 需求 | 路线 A 状态 | 依据 |
| --- | --- | --- |
| 独立会话（非成员、非用户 Root） | 静态支持，待 binary 探针 | Orbit spawn 私有子进程 + 进程内私有 `createAgentSession`（现行同构）；执行载体是 Orbit 新建可终止进程，不在固定用户 Root 里跑 |
| 精确 provider/model/认证 | 静态支持 | 沿用 `reviewer.ts:365-379` 精确 find + 凭据预检；不经 CLI 模糊匹配 |
| 隔离配置 | 静态支持 | 同一组 `Settings.isolated` 关闭项（`reviewer.ts:397-414`）；`--config` overlay 与 `Settings.isolated` 关系需探针确认（§6） |
| 不发现环境扩展 | 静态支持 | `--no-extensions`→`disableExtensionDiscovery`（`main.ts:1673-1675`）+ `--trusted-extension` 路径本身即禁发现（`:1652-1666`）；该旗标须绝对文件路径，且与 `-e/--extension/--hook` 互斥（`cli/args.ts:387-400`）。reviewer 私有会话另带 `disableExtensionDiscovery:true` |
| 只读目录 + 图片字节验证 | 静态支持 | `createConfinedTools` 原样可用；`confined-tools.ts:29-41` 字节嗅探/sha256 不变；`zod` 经注入面（`types.ts:1371-1373`）或 shim 导出可得 |
| 结果 schema | 静态支持 | `check-result.ts` 校验原样；Ruby 侧不变 |
| 原生 usage/error 回执 | 静态支持 | 私有会话 `session.subscribe` 不变（`reviewer.ts:556-572`）；provider error 字段不变（`provider-error.ts:17-49`） |
| 可靠 cancel/进程清理 | 部分待验 | 进程组 TERM/KILL 与现行一致；**rpc 模式无 postmortem 注册**（§3.10），扩展私有会话在 TERM 下的 dispose 须探针确认或扩展自注册信号处理 |
| SDK/宿主版本一致 | 结构性改善 | 检查器即宿主模块，漂移类消失；`sdk_version` 闸改为宿主版本断言 |

## 6. 第一项冻结验证（无模型探针，实施前必做）

这组探针尚未运行，属于获批实施后的第一步。它不跑模型、不建测试 pane、不改用户安装；一个临时 `--trusted-extension` 探针扩展 + 短生命周期子进程即可：

1. **实际 binary 的打包导出面**：探针扩展 `import`（或 `api.pi` 读取）并列举 `createAgentSession/discoverAuthStorage/ModelRegistry/Settings.isolated/AgentRegistry/SessionManager/isAuthenticated` 及 `@oh-my-pi/pi-utils` 的 `getBaseConfigRoot/getModelDbPath/getProfileRootDir/resolveProfileEnv` 是否真实可解析——§3 全部结论的实测落点。
2. **factory 时序**：确认 trusted factory 在真实 binary 中先于宿主会话创建执行，且 factory 内 `process.exit` 干净结束（无双重退出、无悬挂宿主会话）。
3. **TERM 清理**：spawn 后 SIGTERM，确认扩展私有会话 dispose 路径与进程组退出码（130/143），rpc 模式无 postmortem 的缺口如何处理。
4. **启动副作用残留**：隔离 agentDir 载体下核对 settings 初始化、`Settings.isolated` 与 `--config` overlay 的优先级（`main.ts:248-254`）、遥测默认（`main.ts:2198-2211` OTLP 由 `telemetry.otlpExportEnabled` 门控）、目录刷新及插件预加载是否有其他启动入口（`main.ts:1761-1772` preload、`:1860-1970` 目录初始化发生在 factory 之前；不得由 factory 提前退出推断没有此前 I/O 或网络）。
5. **空认证载体启动**：宿主侧 `discoverAuthStorage` 指向全新 agentDir（`main.ts:1838-1843`）时启动是否安静成功、无任何模型请求。

## 7. 明确不做与边界

- 本票只调研与方案审核：不实现、不改 TODO/合同/版本、不提交推送、不删文件、不安装更新、不跑模型/测试子进程、不建临时 pane、不二次派发。
- 不采用未注册 eval agent 路径，不替换宿主，不维护 fork，不静默退回重复 SDK。
- 不承诺未实测的最终体积；§1 表格是本机当日实测，非跨平台断言。
- 静态源码结论以 18.8.0 安装树为准；宿主后续升级需重核 §3 各接缝（同现行「宿主升级需重验证」边界）。

## 8. 待审核实施范围与后续验收

2026-10-11 用户补充要求：**安装时检查本地 OMP 是否已安装，缺失时提醒用户**。方案据此增加安装前置门：安装脚本启动后，在下载源码/依赖、准备 release 和切换入口之前解析 PATH 中的 `omp`，按上述两个入口核对可执行性及版本；缺失时输出明确中文提示，例如「未找到 OMP（Oh My Pi）。Orbit 需要复用本地 OMP，请先安装并加入 PATH，再重新运行安装命令」，并终止本次安装、保留旧安装。找到文件但无法执行或版本不支持时分别说明原因，不能误报为未安装。Orbit 不自动下载或升级 OMP，也不在缺失时静默安装私有 SDK 替代。实际宿主导出/加载能力在隔离暂存探针通过后才允许切换；“命令存在”不等于检查器已经可用。

安装回归范围包含：本地/远程安装及直接管理入口遇到 OMP 缺失均提示且不继续准备、下载源码/依赖或切换；OMP 已安装且兼容时复用同一实际路径；不可执行、版本或能力不支持时诊断准确并保留旧版；help/卸载不因缺 OMP 受阻。用户以 curl 获取安装脚本本身发生在脚本执行前，不纳入“缺 OMP 后不继续下载”的承诺。不能以安装结束后的提示代替前置门。

建议批准：以路线 A 做最小入口适配，在实际导出/加载及隔离载体探针通过后去掉私有 SDK 安装；保留既有检查语义、源认证和目录规则，不复制凭据、不引入 broker 服务、不扩权限、不升级用户 OMP、不维护 fork。能力不足的宿主在切换前明确失败并保留旧安装，不静默重新下载一份 SDK。当前源码的 18.8.0 支持不能自动延伸为所有旧版本支持；现有最低版本用户的影响必须在能力门和文档中明确。

移除依赖前先跑相关已有测试，入口适配只补必要回归；随后按 `orbit-real-acceptance` 在隔离 Git 项目/临时安装运行真实已安装 `orbit omp`。必须实际验证：精确选型与源认证、独立 registry、只读越界拒绝/图片原字节、结果结构与业务语义、逐调用 usage/error 与失败保留、在途取消及确认进程组退出、正常检查回收和安装切换失败保留旧版。主线还应覆盖原生 task/hub 和 Root 集成，不能只跑直接 SDK API 代替产品路径。实际新构建和平台分列安装目录、Orbit 自有依赖、宿主既有文件/缓存及物理占用，不把宿主缓存迁移冒充节省。自建 pane、进程与临时安装结束即清理，固定 Root/OMP/Herdr 保留。

若第一项探针证明所需接口或生命周期不可用，报告具体断点，保留既有可用安装，提出同一用户能力的替代方案；不得把未实施的去重承诺记为完成，也不擅自维护 fork 或扩大权限。本轮没有运行这些探针或产品验收。

资源与研究边界：复用固定 pane `w23:pH`、OMP PID12801，原进程内 `/new` 后按当前任务重新加载材料；实际 UI 显示 K3-256k、OMP18.8.0。成员只读源码与尺寸，保存本报告，Root 直接核对 loader/index/CLI args/main 生命周期并修正可信旗标、bootstrap 副作用和已有尺寸原件引用。研究过程中成员 Write 两次缺 `content` 失败，之后保存成功；这是开发工具回报，不能算产品委派路径验收或模型自行恢复能力证明。未运行产品模型检查，未新建测试 pane/安装。当前研究的原生 token 回执、实际费用与配额未取得，均 unknown；UI 估算不作为账单。此前优化 Goal 的 complete 与计数不属于本次研究。

收尾：成员回报六个只读后台命令均结束；Root 的现场进程树核对未见这些命令残留。H 下除原 OMP/MCP 外，另有 PID35871 `omp __omp_worker_daemon_broker`，启动于2026-10-09 22:59:46，本轮之前，保留而未清理。固定 H/J/K 的 PID12801/12883/12966 与 Herdr2144/2145的启动时间/命令保持；没有新建测试 pane 或需要卸载的临时安装。Zeen 未写入，最终改动仅两个研究报告及索引、交接、当前限制。

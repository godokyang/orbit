# Orbit 安装体积修复（2026-10-11）

第一阶段目标：修复正常安装中的 SDK 重复和下载缓存残留，显著减少安装目录占用；保持独立检查器、只读边界、安装失败回滚及运行中 release 保护。只修改安装流程，不裁剪 SDK 内部功能、改检查协议或升级用户 OMP。下文第一阶段事实保留；用户随后批准的可选依赖优化见文末。

冻结验证：实际安装三个直接 SDK 依赖版本一致；成功安装不保留 `.npm-cache`／`.bun-cache`；当前 macOS arm64／OMP 18.8.0 的真实安装只含一份大型原生模块且体积低于旧安装；实际 reviewer 创建会话、只读边界探测及一次模型检查通过；已有安装回滚／lease／卸载测试通过。体积是本机测量，不固定为跨平台单元测试断言。

## 原因与实现

- 旧安装 `11dc101724b09fd70979e967`：源码 0.8.4／`5e781e4` clean，2026-10-10T06:58:03Z，digest `1ebbd903…`，`du -sk` 3,555,480 KiB。
- 安装器只把 `pi-coding-agent`、`pi-utils` 随宿主对齐到 18.8.0，直接 `pi-ai` 仍为 18.3.4。依赖树形成八份约 168–169 MiB 的原生二进制，检查器 `node_modules` 为 2,389,592 KiB。
- 每个 release 保留私有 Bun 安装缓存，旧缓存为 1,154,568 KiB。它是准备阶段的下载缓存；运行时从已安装模块加载。
- `scripts/manage-install.rb` 对齐并核对三个直接 SDK 包，使用 Bun 自带 hoisted linker；成功准备后删除两个私有安装缓存。安装输出改为记录中的实际 reviewer SDK 版本。
- 保留 source 锁文件回退、18.4.9 限定导入修正、准备失败不切换 current、活跃 lease 不删除旧 release，以及卸载时只清理安装器所有文件的边界。

## 已完成验证

- 最终临时安装：0.8.4／`5e781e4` dirty，2026-10-11T03:54:32Z，digest `82ba262fc7ebaf350fd01e18361c516075b42aaaeee7acd2528960474dda38f0`。三个直接 SDK 包均为 18.8.0；缓存均不存在；原生模块只有一份；`du -sk` 为 976,804 KiB（953.9 MiB），较旧安装下降 72.5%。
- 真实安装的 reviewer 创建独立 SDK 会话：仅 `read`／`grep`／`glob`，无禁止工具，16 项内部读取／路径逃逸／外部链接边界探测全部通过，快照指纹不变。
- 初版临时安装 `050c55d9…` 执行上述探测及一次 `opencode-go/deepseek-v4.1-flash` 真实检查：实际读取固定文本夹具，结果符合检查 schema，coverage verified、delivery ready、无 finding，前后指纹一致。随后仅修正安装器的实际 SDK 显示，最终安装为上面的 `82ba262f…`，reviewer 源码未改变。两条模型回执原始 totalTokens 为 2,831 与 4,479（合计 7,310，含 cacheRead；费用和配额未知）。这验证精简后的检查器，不替代此前 Orbit task/hub 整轮验收。
- 已有安装专项测试通过，新增断言限制在三包对齐、保留运行模块及不保留安装缓存。开始时一个旧测试进程加载旧 fixture 后遇到正在更新的新安装源码而失败；源码与 fixture 同步后完整重跑通过，不计为产品验收通过或真实模型失败。

- `npm test` 全仓测试、版本一致性、打包 dry-run、差异检查均通过。
- Herdr 原有 `w23:pK`／OMP PID 12966／`zhipu-coding-plan/glm-5.3-flash` 只读独立核查完成：直接读取 diff、安装/回滚/lease 源码、测试和真实临时依赖树，三项核心判断通过，无本轮阻断。未修改文件、二次派发或执行安装。其缓存硬链接描述未作为终验依据，实际安全性由无缓存的真实运行验证。
- 独立核查保留既有边界：18.4.9 补丁未在本轮重跑；content_digest 表示 SDK 对齐前的源码包（安装后 manifest 会派生改写）；宿主后续升级需再次更新 Orbit 才对齐 reviewer。

- 用户本机已通过正常安装器从本轮源码更新：当前 release `e8c29c03c7eb0777acd84a9c`，0.8.4／`5e781e4` dirty，2026-10-11T04:00:49Z，digest `82ba262f…`。三个 SDK 包均为 18.8.0，原生模块一份，两种缓存均无；release 为 981,164 KiB（958.2 MiB），整个 `~/.local/share/orbit` 为 982,504 KiB（959.5 MiB），比旧目录下降约 72.4%。安装前旧 release 无 lease／进程路径引用；正常收口删除了旧受管 release，现有 release 数量仍为一。原有三个 OMP 的 12 个执行者／MCP／shell PID 均存活，未升级宿主 OMP。
- 本机最终安装的 reviewer 再跑 16 项只读边界探测全部通过，快照指纹不变；`orbit doctor --json` 的安装与依赖均 ready。
- 额外直接在安装包内运行 reviewer 测试：25 项通过，一项共享结构测试因安装包不包含仓库 `tests/fixtures` 而无法运行（ENOENT）；原失败保留，未改安装内容以通过测试。随后显式用仓库的七份共享样例调用本机已安装的 validator，全部匹配预期。仓库 `npm test` 原本包含该 fixture 且全通过。
- 临时安装已通过正常卸载器卸载；其余本轮临时目录、进程及检查 profile 的收口结果见证据索引。本机新安装保留。源码未升版、提交、推送或发布，远程 `main` 尚未包含此修复。

## 保留边界

当前仍安装完整 SDK，其 ONNX、语音、图像等传递依赖仍占空间；本轮不删除运行包里的文件。未来宿主版本、平台和依赖变动会影响体积。macOS APFS 可能共享 clone 数据块，`du` 目录占用下降不能直接等同实际释放的物理磁盘字节。

原件见 [安装体积证据](evidence/install-footprint-20261011/)；未将旧 0.8.4 构建或历史 Codex Goal 改标为本轮验证。

## 第二阶段：用户批准的可选依赖优化

实际 Goal 已 complete（2026-10-11T04:50:53Z，工具计数415,228／2,182秒，约36分钟，非供应商账单），原件 `goal-final.json`；沿[本轮冻结实施清单](../plan/orbit-install-footprint-optimization.md)维护状态。只减少私有检查器不使用的依赖，不替换宿主、共享全局 SDK 或维护 Fork。Orbit 安装仍携带运行独立检查器所需的 OMP SDK；用户已有的编译版 `omp` 不能充当可导入 SDK，继续保留这一架构。

适配依据是本机实际 `@oh-my-pi/pi-coding-agent@18.8.0`、`pi-mnemopi`、`pi-natives` 的包声明和调用链，详见[独立源码核查](evidence/install-footprint-optimization-20261011/independent-code-review.md)。SDK 把本地模型、语音列作 optional，mnemopi 还把 ONNX 列作 optional peer；Bun 自动安装 peer，因此必须同时 `--omit optional --omit peer --omit dev`。平台原生 addon 虽也被上游列作 optional，却是 reviewer 必需，安装器按实际 Bun 的 platform/arch 显式安装同版本 leaf，并在 release 切换前验证 SDK/native 可加载。没有删除上游包内部文件。

检查器显式设置 `memory.backend=off`、`memories.enabled=false`、`stt.enabled=false`，保持 headless、仅 read/grep/glob、无 MCP/LSP/IRC 或扩展发现。SDK 仍注册 local-inference transport；tiny 模型显式选型仍可能触发 worker，MLX 甚至不依赖被省略的 npm 包。本轮依据远程检查模型和实际受限会话验证未触发下载，不声称省略依赖就永久阻止 SDK 任意本地模型路径。

| 安装阶段／构建 | release `du -sk` | 结果 |
| --- | ---: | --- |
| 第一阶段日常安装 `e8c29c03…`／`82ba262f…` | 981,164 KiB（958.2 MiB） | 去重和缓存已收口；本轮不修改 |
| 第二阶段 v2 `9ec0e290…` | 756,696 KiB（739.0 MiB） | 仅 omit optional；仍有 ONNX peer，不算最终通过 |
| 第二阶段最终 v3 `df8ab704…`／`22fb7d27…` | 457,580 KiB（446.9 MiB） | optional/peer/dev 省略；一个匹配平台 native，SDK 18.8.0；准备缓存无 |

最终构建源码 0.8.4／`5e781e44…` dirty，2026-10-11T04:20:19Z；临时安装路径与完整摘要沿[安装原件](evidence/install-footprint-optimization-20261011/install-v3.json)。同口径较第一阶段 release 减少 53.4%（约 511.3 MiB）；目录统计不等于 APFS 实际释放字节，不推为跨平台固定体积。日常 `~/.local/share/orbit` 仍约 959.5 MiB，未将临时安装数字冒充用户目录已变小。

验证与失败原件沿[第二阶段证据](evidence/install-footprint-optimization-20261011/)：全仓 `npm test`、最终安装专项测试、pack、版本和 skill 校验通过；新增原生组件缺失／载入失败时保留旧 release 的回归，既有失败切换及 lease 测试通过。两次真实 v3 reviewer 只读探测通过、指纹不变。源码 pin 18.3.4 的真实冷依赖、Settings 创建及完整只读探测也通过；18.2.8 仅读取官方源码确认 settings，未跑旧宿主整轮；跨平台、18.4.9 既有修正分支未重跑。

失败不改标：初次 `--production` 冻结锁文件阻止 staged adaptation；改用 omit dev 后才重装。v2 发现 optional peer 后新 v3 复验。兼容探测曾误用旧 Settings 不存在的 get 方法，随后 Controller 夹具又遗漏 plugins/contracts/lib；全部 stderr 保留，完整材料上的 v4 探测才通过，production 未添加这些错误调用。

真实产品矩阵使用上述最终安装，在全新 Git 夹具中由已安装 `orbit omp` 自己完成任务：

| 场景 | 结果与边界 |
| --- | --- |
| 单文件负例 v2 | 通过。私有检查发现 trimStart 缺陷及尚缺验证（f1/f2），Root 自主修正、测试、终检 resolved 并 complete/confirmed stop；零证据请求／hint／成员 |
| 实质交接正例 v2 | 通过。04:38:11Z 产生绑定当前输入的 Decision-4／input-2 推荐，04:38:25Z 登记 K3 成员，04:38:28.188Z 首次成员模型调用。成员实现 importer，Root 实现 CLI／README，双方实际 npm127通过，04:40:34Z hub send／ok 与 Root 回执齐全；04:41:02Z accepted、04:41:05Z 原生结果归档；独立终检、04:43:30Z complete/confirmed stop，成员及 owner 后台 settled |
| 独立检查来源 | 通过。单独 Bun 进程载入 OMP SDK18.8.0，固定快照、私有会话仅 read/grep/glob，run PID／请求／输入与产物 digest／调用回执可追溯，成功检查前后指纹一致；TS 结果经过 Ruby 结构和业务验证后才进入终检与停止门 |
| 活动 Root／成员 Esc | 通过。负例 v1、正例 v1 取消记录均为 paused／confirmed stop，登记成员 owner 工作结束；随后正常退出、进程组为空、关闭 pane |
| 正常退出 | 通过。完成的负例、只读场景及正例 v2 确认停止后 Ctrl+D 退出，逐个核对 OMP／MCP 进程组退出，再关闭 pane |
| 空闲 Root 的 Esc | 未触发取消。interrupt-v2 在 checker in_flight／Root 空闲时发送 Esc，程序未记录 native interruption，随后正常完成；保留为 UI 入口边界，不算取消通过 |

每条原件沿 `tasks/<fixture>/`、`native-receipts/`、`*-summary.json`、`*-cleanup.json`。正例 v2 在初始需求之后未收到 Controller 催办或实现代写，Root 自行处理未声明 work-unit 的首次接口拒绝；成员第一次给命令加前缀被拒后，改用正式允许的完整命令并成功。这是一条有界自主闭环，不能外推普遍减少监督或节省模型资源。正例 v1 的错误 PATH／重复拒绝、负例 v1 的错误派发不改为成功；它们均取消并保存。

正例 v2 还有实际失败：一次 Jev 请求出现 SSL 异常；首次 DeepSeek 终检输出不是合法 JSON，自动换 K3 后第二次终检才通过。只读 interrupt 的首次结果也无效，自动后备成功。全部失败、回执缺口与用量保留，不把后备成功冒充首选成功。rebind／finding 去重未改且本轮未跑；没有重开历史验证分支。

资源以[原始字段汇总](evidence/install-footprint-optimization-20261011/model-resource-summary.json)为准：被测 Root GLM70次（totalTokens 已报 1,347,624，另2次缺失）；K3 成员31次（824,285，另1次缺失）；误派 DeepSeek 成员6次（41,989，另2次缺失）；DeepSeek checker14次（211,600），K3 checker6次（110,352）。Jev28条记录中26条明确实际 jev-1.13.0（input_tokens 174,293，output 单列），2条失败实际型号／用量未知。字段单位 token，cached/input/output关系按原回执，不再次相加。独立开发核查 GLM 的真实回执另存 `independent-review-usage.json`；Controller Codex Goal 工具计数另记，不能当供应商账单。现金、配额及剩余额度未知，无可比同任务基线，不宣称节省。

重复 reviewer 及模型检查后，省略包均未恢复、私有检查 profiles／隔离 XDG cache 无模型或语音权重产物；release 增长48KiB来自12条微小 lease记录，正常卸载器会裁决并清理 stale lease。两份临时安装均正常卸载成功。6个自建测试 pane 已全部在停止／进程组退出后关闭；20个基线固定PID的身份／开始时间／命令完全一致，日常安装元数据完全一致。必要证据先保存，归属临时根（删除前1,206,200KiB）已删除，6个被测会话的外置 session-agent 临时根亦不存在；进程路径审计为空。系统临时目录另有19个空 session-agent 根，部分早于本 Goal，缺创建回执／目录基线不能仅凭名字日期认领，全部保留，原件列于 `resource-cleanup.json`。独立最终验收核查 `independent-acceptance-review.md` 无阻断；核查员不替代 Root 的最终资源审计。本轮源码0.8.4保持，无升版、提交、推送、发布、全局安装更新或宿主升级。

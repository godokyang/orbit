# Orbit 当前交接

用户指出当前多 Agent 协作、Herdr 可用成员发现、Jev 委派提示、状态可见性与真实安装仍未满足日常使用目标。2026-09-18 [独立审查及复核](../reference/project-review-20260918.md)确认：一次真实开发任务的 7 次已完成检查全部过期，Orbit 投递纠正为 0，检查用量记录为 4,246,313 tokens（含缓存口径）。按[用户结果补齐计划](user-outcome-completion-plan.md)执行到：切片 A 已实现并经受控路径、持续编辑任务和 0.6.2 新宿主会话验证；切片 B 已核对 Jev 输入边界、真实判断与额外消耗，完成 patch 升级与本机安装；切片 C 已按跨宿主原生成员路径实现并完成真实验收：OpenCode Root 显式 `kind: codex`，任务运行进程持有成员 app-server，结果回收、执行中中断、运行进程异常退出后的显式停止重试与会话保留分别取证；同宿主 `native` 委托保留，其他 kind 与 Herdr 控制未验证。切片 D 未推进。实际证据、用量与未覆盖范围见[检查回路与 Jev 实际验证](../reference/check-loop-acceptance-20260918.md)与[跨宿主成员验收](../reference/cross-host-member-acceptance-20260918.md)。

## 检查回路修正与验证（2026-09-18）

- 过期检查记录产物、输入、宿主、争议分项原因；Root 执行时完整检查间隔以约定时间为下限，空闲、用户请求、明确修改和交付语义不变。
- 过期 `correct`/`continue` findings 作为待核对线索传给下一次审查者检查（“Pending clues”），确认后自动送达 Root，未提及则保留；过程检查不接收产物线索。`orbit status` 显示过期原因、开放问题与待核对线索、下次检查依据。
- 验证：受控临时项目注入真实缺陷后，检查 2 过期 `correct`，检查 3 收到线索、复用同一 id 并自动投递，Root 修复后 `complete`（4 次检查、2 次过期、1 条纠正、431,281 tokens）；本仓持续编辑任务观察到 300 秒下限收敛、分项过期与自动纠正。完整 `npm test` 17 项通过。
- 真实 Jev（`jev-1.13.0`）判断与用量可核对；本次样本未触发过程检查、未减少完整检查，额外消耗约 2.4–2.7k 输入 tokens/次，持续编辑时约 20 秒一次。默认启用按用户决定保留。

## 本机安装与最终验证（2026-09-18）

源码按版本规则 patch 升到 **0.6.2**（`npm version patch --no-git-tag-version`），完整 `npm test` 17 项通过。所有相关任务进入终态后，从工作树（基线 `c80618b`，dirty）本地安装到 `~/.local/share/orbit/orbit`：`orbit version --json` 返回 `version 0.6.2`、`source.kind local`、`dirty true`、`content_digest a2a05621…`、`installed_at 2026-09-18T05:16:37Z`；CLI、OpenCode 插件与 OMP 扩展指向新 release，已在运行的宿主会话重开后加载新版。

新打开的 OpenCode 宿主会话中复核受控任务 `fd88d76a`：7 次检查、4 次过期、2 条纠正自动送达、最终 `complete`（306 秒、检查 tokens 566,645）；检查 prompt 实际包含待核对线索并复用同一 finding id；真实 Jev 3 次调用，判断与用量可核对。

跨宿主成员路径随后并入未提交改动并再次按 patch 升到 **0.6.3**（`content_digest 8df0acbf…`、`installed_at 2026-09-18T06:06:36Z`）。新宿主会话中的三个真实任务分别证明：Codex 成员结果回原 Root 并核验集成（`2c9569a2`）；执行中中断使 turn 与两个登记后台终端退出、宿主进程组退出确认（`f8a9da7d`）；运行进程 SIGKILL 后显式 `orbit stop` 从记录重连、停止并核对（`d8d03598`）；三个成员 rollout 与 Root 会话历史保留。验证中发现并修正三处接口缺口（成员宿主 MCP 覆盖、未物化成员线程的启动与停止、Darwin 僵尸进程组的退出核对）；两个真实失败任务由停止重试收尾为 `paused`。详见[跨宿主成员验收](../reference/cross-host-member-acceptance-20260918.md)。

**已知顺序限制：** 任务运行期间安装会让运行中任务读取旧 release 失败（本仓任务 `30586614` 因规则库 `ENOENT` 记为 `failed`，停止已确认）。本轮不扩展热更新；使用顺序为结束任务→安装→重开宿主会话，见[当前限制](debt-ledger.md)。

本次未推送、未发布、未打标签；提交状态以 Git 为准。

## Jev 接入（2026-09-18，源码待发布）

用户确认 `TYPESAFE_API_KEY` 作为所有新 Orbit 任务的全局启用条件，项目可用 `.orbit/jev-disabled` 关闭。源码已接入 Jev 调度：可能卡住／偏题唤起过程检查，产物就绪唤起完整检查；定时和 Root 交付检查保留，服务异常回退原路径。真实 Jev 与运行循环、独立 Codex 检查已在临时项目中联动，完整测试通过。具体证据及夹具边界见 [Jev 运行验收](../reference/jev-runtime-acceptance-20260918.md)与[检查回路与 Jev 实际验证](../reference/check-loop-acceptance-20260918.md)。本机全局安装已随本次源码更新（见上）；未推送或发布，启动中的旧会话在重开前不会加载新扩展。

当前源码 **0.6.1**：用户要求由安装器自动完成 PATH 配置，已实现 zsh／bash 持久配置、重复安装幂等与更新沿用禁用选择。README 已移除手写 `.zshrc` 的步骤，改为安装后重开终端验证。版本按用户规则仅增加 patch。

本次修改尚未提交或推送。五条安装测试通过，覆盖原有安装／更新／失败回退／卸载路径及 shell 配置；实际新 zsh 可发现 CLI，Bash 验证自定义路径、重复加载、已有内容、链接与权限保留。独立只读核查无阻断；未调用执行／检查模型，也未修改本机真实 shell 配置。日志保留在 `/tmp/orbit-path-install-tests.log`。

此前日常命令简化 **0.6.0 / d6e0951** 与版本规则 **72b5a9e** 已推送。0.5.0 安装拆分及本机旧版卸载已经完成，skill 继续独立交给 npx skills，本机尚未全局安装新版。外部交接资料继续保留并忽略，新宿主接入仍暂缓。

## 0.6.0 的用户入口与验证

- 在项目或子目录运行 `orbit status` / `orbit stop`。多个待处理记录列出 ID，停止不猜；可用唯一 ID 前缀或显式目录。failed / stop_unconfirmed 仍是待处理项；仅查询在无待处理项时显示最近结束任务。
- 人类输出明确区分过期检查、实际停止错误、等待检查与完成。程序用 `--json`；MCP、原生插件及 OMP 切换停止重试均已改成显式 JSON。
- `doctor` 不调用模型；无上下文时会话未验证，已有任务或当前 Codex 上下文通过原生接口读取连接。安装文件不证明已加载，模型登录和额度保持未验证。
- `update` 复用安装器：远程沿用 ref，本地沿用记录的源码目录；显式 `--ref` 可选择远程来源。真实安装目录与传入目录拼写一起核对，避免 macOS `/var` 与 `/private/var` 别名误报。无需 wrapper 增加环境变量即可保留用户的卸载体验。
- Agent 确认接入后主动简短告知；产物准备好但检查未完成时说明待检查。最终状态在自然工作节点或用户查询时据实报告，不新增通知专用的模型调用或轮询。

新增 7 个 CLI 行为测试，并扩充既有安装／MCP 用例；新增测试约 170 行。覆盖单任务、多个候选不误停、结束任务和嵌套项目、过期结论及真实错误、无连接与缺依赖诊断、两种插件协议的只读连接、安装维护入口；停止控制本身沿用既有回归。

四条隔离安装生命周期通过，包含真实打包、npm 依赖准备、已安装 CLI 的远程／本地更新、错误回退、doctor 扩展缺失识别和修复、从任意目录卸载及用户资料保留。远程下载使用固定传输夹具，OMP／OpenCode 诊断使用 Unix 协议夹具，均不冒充新的真实模型或完整宿主验收。既有 OMP 停止回归已发现并关闭内部 JSON 接缝遗漏；独立只读评审与针对性复核完成。完整 `npm test`、skill 校验、36 处文档链接及 shell 示例检查通过；测试进程和临时目录已清理，最终回归日志保留在 `/tmp/orbit-ux-final-tests.log`。本次 Goal 交付已完成，后续只按用户的新要求继续。

## 当前怎么用

- **OMP**：项目目录直接运行 `omp`。可继续使用原生 `--resume SESSION_ID`、`--model provider/id`、`--approval-mode` 和 profile。安装后的扩展通过原生 `xd://orbit` 提供工具；Agent 读取设备说明后按原生协议调用，无需用户填写内部 ID 或端口。
- **OpenCode**：直接运行 `opencode`，保留原生恢复、模型和权限参数。
- **Codex**：运行 `orbit codex` 或 `orbit codex resume SESSION_ID`；普通 embedded Codex 仍不自动热接入。
- Root 就是当前负责用户整项任务的 Agent，不另建、不替换。需要成员的执行任务先接入再 delegate；其他合适的多步骤工作由共用 skill 主动判断，讨论和简单独立修改通常不启动。
- 成员与 Root 同宿主。OMP 沿用 Root 模型、thinking、项目及有效权限，只开放 Root 当前启用的基础编码工具，不复制扩展、MCP 或再次派发。OpenCode 沿用 Root 模型、variant、Agent 和权限；Codex 默认沿用检查模型与工作区写入沙箱。均由 Root 核验集成结果。
- **检查者仍需要 Codex**。检查模型优先 `ORBIT_REVIEW_MODEL`；OMP／OpenCode 默认从 Codex config.toml 顶层读取，使用 Codex profile 时显式指定。已实测的执行模型为 `opencode-go/deepseek-v4.1-flash`，不要与 V4、Zen 或直連混用。

推荐 runtime 目录 `~/.local/share/orbit/orbit`，CLI `~/.local/bin/orbit`；本机这套旧安装现已卸载。新版安装器只管理 CLI、OpenCode 插件和 OMP 扩展，skill 全部交给 npx skills。OMP 扩展采用 `PI_CODING_AGENT_DIR`、其次 `OMP_PROFILE` 对应的 agent 目录，默认 `~/.omp/agent`；OpenCode 遵循 `OPENCODE_CONFIG_DIR`。OMP 可原生读取 npx 安装的共享 `.agents/skills`，不需要专用 skill 安装路径。

安装职责拆分验证：四条安装生命周期回归覆盖首次安装不创建技能目录、成功／失败更新与卸载保留外部 skill；OMP 18.1.16 在无模型请求的原生启动中发现 npx 安装的项目 `.agents/skills/orbit/SKILL.md`，返回的 skill 命令路径与实际文件一致。独立只读核查无代码阻断，两处旧升级说明已随用户“不兼容”决定删除。完整 `npm test`、skill 校验、66 处文档链接与 shell 示例检查通过；隔离 skill 更新和移除也通过。验证目录和进程已清理，整次未发起执行或检查模型请求。

## 0.4.0 的既有执行验收

完整数据见 [OMP 运行验收](../reference/omp-runtime-acceptance-20260914.json)，保留真实失败与修正，不以接线测试代替实际运行。

- 普通 OMP 18.1.16 中，用户要求未点名 Orbit，Agent 自主启动并保存原文和 requirements.md；一个已登记的 Go／V4.1 成员完成验证，结果回到原 Root 并被集成。
- Root 与成员完成后受控移除 USAGE.md，独立 Codex 检查发现遗漏，同一 Root 补回；5 次检查中 3 次过期弃用，最终 complete。内部纠正与回报未混入用户补充要求。
- 原生 Esc 中断，Root／成员及各自子进程共 4 个 PID 全部退出，心跳停止，任务 paused。
- 原生 --resume 恢复同一会话，再运行两支原生后台任务；正常退出界面后 4 个 PID、任务进程和私有 socket 全部收尾，任务 paused。两条停止验收均未调用检查模型。
- 既有全套回归、OMP 接线与实际后台任务结算／切换失败重试测试、四条安装更新卸载路径、skill／版本校验通过。独立只读核查与针对性复核完成，无剩余已识别阻断。
- 当时本机更新到 0.4.0；在没有项目扩展的普通 OMP 中观察到全局 Orbit 扩展与新版 skill，CLI／三个宿主的入口同版。原生模型和权限配置内容保持一致。

实际运行发现并修正两处：小任务需要成员时也应先接入；followUp 被 hub wait 挡住，改用原生 steer，避免回报延迟。独立核查补齐切换前停止确认：未确认则取消切换，保留原连接供重试。

首次未成功闭环的任务在取消一个正在执行的 Codex 检查进程组时收到 EPERM，记录保留 stop_unconfirmed；其 Root／成员停止已确认，事后核对登记检查 PID 和进程组均不存在。未把这一失败改写成通过。后续完整流程和两条停止验收分别保留自己的结果。

本轮自有宿主、执行及检查进程已结束，临时控制 socket 已关闭。隔离夹具、原生历史、检查副本及评审日志保留，位置见验收数据。初估 2–4 小时，未连续记录整次实施时长和套餐扣量。成功纠偏任务记录 466223 检查 tokens（包含缓存口径）；说明几次过期检查的成本，不据最小验收宣称普遍节省额度。

## 后续边界

其他宿主接入暂缓，先试用 Codex、OpenCode、OMP 并改进使用说明。未来恢复接入时沿用既定顺序：pi、Kimi Code；Grok、dsh、Cursor Agent 保持低优先级。本轮完成不自动授权下一宿主，不扩展混合宿主成员、自动恢复、Root 替换或需求讨论管理。

[OpenCode 正式验收](../reference/opencode-runtime-acceptance-20260914.json)、[Codex 日常验收](../reference/user-flow-acceptance-20260914.json) 与 [底层验收](../reference/orbit-runtime-acceptance-20260914.md) 保留为既有证据。当前语义见 [运行合同](../../contracts/task-runtime.md) 与 [ADR-007](../adr/007-task-runtime-refactor.md)，进度见 [当前计划](vision-completion-plan.md)。旧阶段和 upstream 不再是待办；旧 0.1.15 资料仍在 `~/.local/share/orbit/retired-0.1.15-20260914`，没有兼容执行路径。

# 普通真实任务修复验收（2026-10-02）

范围：原要求八项推荐、权限与监督问题；沿冻结验收，不扩为全型号测评、现金核算或生命周期全分支治理。当前行为以[任务运行合同](../../contracts/task-runtime.md)与 ADR-008/009 为准。

## 构建与证据

运行源码 0.8.1，基线 `a0fe2f1651a002fac65fe1dd220e6a521bb790da` 工作树。所有以下最终运行使用独立安装 build3：digest `bcd9cbfda5782084f22c97a95d34a608d5bd19afbbab143aa16c7a680f2d45fc`，安装于 `2026-10-02T02:31:50Z`；实际检查者 OMP 包 `@oh-my-pi/pi-coding-agent` 18.4.9。运行期间冻结源码；最终交接文档不在 npm 安装清单，不改运行代码或该 digest。

原件根：`/private/tmp/orbit-ordinary-repair-1d_06gw_`（下文路径均相对该根）。Controller 只准备初始夹具、提交用户式要求、读取记录及做明确标注的原生中断/退出；未实施夹具修复。正式入口是私有安装的 `bin/orbit omp`，经 Herdr 检测 idle 后提交一个完整要求。普通 OMP 的被动布局已核对。用户全局安装维持 0.8.0／a0fe2f1／digest `92aa2e6dbd8344c805d97a11818959e41064108e79b8f02fec2565b02bf1bea3`；用户池未改，zeen 始终只读。

## 八项收口

| 要求 | 实现与核验 | 边界 |
| --- | --- | --- |
| 1 队列与派前建议 | execution=root 排除自执行；未评估优先、相关变化与轮转；declare/select 经运行时唯一写评估，task 派前复用/核对版本。selector/runtime/native gate 回归；positive3 两单均有真实派前评估，Root 按建议实际派发 | 保留 Root 裁量和池序；选型回执与已送达 hint 分开，缺消息归因不补造 |
| 2 选型缓存 | 以自身要求/上下文/依赖完整摘要、候选能力与政策为依据；无关 artifact/user ID 不失效；负面结果复用 | 回归直接断言付费调用次数；依赖正文投影仍有界，完整 hash 保证尾部变化能失效 |
| 3 结构与具体候选 | decision-4 经 OMP2 原件独立复核，原题与阈值未改；handoff_fit 判结构，member_task_fit 为诊断，候选独立过原质量门；首选/备选/限制/未知成本明确 | 17标签/14历史调用未伪称新样本；positive3 才是新组合实机证据；不宣称全域或成本节省 |
| 4 原生语法与权限 | read 行选择器/多路径、grep 多路径/范围/裸通配递归、glob 范围逐目标校验；真实 SDK 原始与 gate 后工具结果核对 | .git/.orbit、越界、symlink 拒绝；搜索子树含受保护目录/任何 symlink 或超过10000项，需缩小入口 |
| 5 可执行预检 | 声明及 task 启动前校验路径、工具、完整命令、input_materials；空入口、未知工具、受保护路径、不可读材料返回恢复建议；native gate 断言失败不启动成员 | 技能/MCP/项目外资料不自动放权；Root 可准备项目内材料/context |
| 6 阻断进入监督 | 共享跨扩展事件，实际 member/unit/dispatch/tool/time/reason 持久化；有界摘要送 Jev 与独立检查上下文；重复同墙且 Root 回合推进触发一次 process 检查 | positive3 真实阻断、native反馈纠正、合法命令成功及终检；反复重派 stalled 分支由针对性回归核验，未冒称自然现场再现 |
| 7 去重与纠正 | 过程 key 去掉工具/轮次噪声，同类阻断不因计数增长重开；观察间隔、stale诊断与当前复核边界保留；review-dedup 实际发现→correction_sent→原生成员修正→check2 resolved三个原ID | 真实稳定观察结果见下节；不以检查次数代替纠正，不重标过期检查 |
| 8 真实成员收尾 | positive2 确认改派后旧失败成员误撤销；物理身份取该成员最新尝试，业务资格仍取单元最新尝试；失败补记 finished_at 不伪造新执行。既有收尾回归与 OMP3 独立源码复核通过；positive3 旧失败和新accepted均能确认停止 | 未扩为所有生命周期边界；真实新轮、新错误、同成员重派及漂移仍失效 |

## 普通正例：passed

`positive3/.orbit/tasks/9655c0fc-d405-46b1-869a-06802e6c6cfa`。Root 为 openai-codex/gpt-6-sol；需求为严格记录校验/聚合与 Markdown 模块分单，Root 保留接口/CLI/最终测试集成。

- 创建 `02:33:17Z`；两个单首次建议 `02:34:00Z`、`02:34:13Z`。handoff_fit `.93/.92`，member_task_fit `.69/.72`；Zenmux候选质量 `.68/.71`，GLM备选 `.67/.73`，价格/额度 unknown。候选过门后沿用户池序，不用适配概率冒充排序优势。
- 原生 batch 注册/绑定 `02:34:33–34Z`，先按建议派 Zenmux，原生真实402；精确失败自动记录，Root 得到新建议后于 `02:34:57Z` 派 GLM。至少两个派发留存精确 hint signature/message ID，另两次缺消息归因保留未知；全部四次有实际派前工作单评估。
- `02:36:10Z` 成员 bash 附加 `&& echo SYNTAX_OK` 被拒；真实 tool_result 立即返回具体原因。`02:36:13Z`、`02:36:25Z` 按授权 `node --check src/summarize.mjs` 成功；阻断身份和摘要进入后续监督与检查原件。Root 接收 hub 返回、核对源文件、集成 CLI，npm test **7/7**，实际 CLI 成功且输入不被修改。
- 独立检查 #1 GLM JSON结构失败（保留已报告tokens）；#2 Go 429额度失败（用量unknown）；#3 K3 于 `02:39:43Z` 启动、`02:40:40Z` 得到 complete，无 stale、无 finding。只读工具 glob/grep/read，私有 OrbitReviewer、global registry 空；snapshot 前后均 `sha256:1b28952b9f51ec6876071c43103629cf80f16f541d989ba2e4e080f4d5491f2c`。
- 一次 finalization_notice 后 Root 请求完成；`02:40:50Z` status=complete，Root 与四个成员均 idle、active_tools=0、async_jobs_settled=true、stop_confirmation.confirmed=true，runtime_pid=null。旧两次402失败未因备用成员accepted再次撤销。

索引：`controller/positive3-audit.json`、`positive3-native-correction.json`、`positive3-resource-groups.json`、`positive3-summary.json`、任务 state/events/collaboration、checks/3 run/evidence/prompt；Pane w22:p8 已关闭。

## 独立发现与复核：passed（阶段暂停）

`review-dedup/.orbit/tasks/218749e1-0f99-4dc4-b43c-9024c6cbc2c1`。夹具最初已有缺陷，Controller 不实施修正。独立 K3 检查 #1 非 stale，发现 `minutes-upper-bound`、`duplicate-id-not-rejected`、`unknown-fields-not-rejected`；`02:52:10Z` finding_recorded 与 correction_sent。Root 据此派原生 GLM 成员修正 src/validate.mjs，自己补行为测试与集成，npm test **6/6** 和实际 Node 调用通过。独立 #2 在新固定快照逐项确认三个原 ID resolved；根据明确的阶段交付/等待下一步要求，真实判 pause，Root 与成员停止确认 true。不是完成正例，不改标为 complete。

Controller 没有补发实现指令或修改产物。该跑法未形成预期的静态 timer 窗口：首次 idempotent start 保留实际300秒，Root 手动 check 被误称自动；复核按阶段要求暂停，不能声称观察去重通过。另发现工具说明缺 finish 状态枚举，Root盲试无效值，当前工作单未 accepted；这属于新增已记录限制，未擅自扩展修复。

原件：`controller/review-dedup-audit.json` 与对应任务 state/events/checks/1、2。原生 ctrl+d 正常退出后，Herdr foreground 仅剩 shell、检查者PID不存在，会话可恢复；`review-dedup-normal-exit-screen.txt`。

## 原生中断：passed

`native-interrupt/.orbit/tasks/e699a300-1257-49df-9da7-2444431b0030`。注册一个 GLM 原生成员；Root/成员实际启动240秒验证，分别 PID83384/83679，运行时83016。Root脚本在中断前刚好自然结束，成员进程仍 live。原生 Esc 后 stop_reason="The user interrupted the Root turn"，status=paused、stop_confirmation.confirmed=true，Root/成员 idle、tools0、async settled，三个 PID 均不存在；随后原生退出可恢复会话。

该样本的 native wait 循环产生新 Root 观察，不能用于证明相同观察不重付费。原件：`controller/native-interrupt-{stable-baseline,before-esc,esc,audit}.json`。没有按进程名批量 kill。

## 稳定观察

`dedup-static/.orbit/tasks/3aac20f6-11f8-4c29-9815-48eea1d46d28`：passed（稳定前台观察与状态/定时控制）。仅本次进程用官方 `--config` 覆盖 `bash.autoBackground.enabled=false`，预检读取确认生效，不改用户配置或 SDK。Root 声明 execution=root，实际无成员、无成员选型、无付费成员判断。脚本PID86918、runtime86624；`03:15:39Z` 至 `03:19:13Z` 文件摘要完全相同，Jev调用数保持2（最后一次 `03:14:44Z`），两次 Controller 明确的只读 status exit0、事件字节不变、checks=0。默认300秒定时在 `03:18:38Z` 被延至 `03:23:38Z`，原因为 Root仍工作；没有重复支付同一静态观察。

原生 Esc 后 paused、Root停止确认 true、脚本和runtime PID均退出，再原生 ctrl+d 正常退出。这里不宣称已完成-check 的同 key重复或 stalled 重派自然分支也实机覆盖；这些直接针对性的去重回归已通过。未配置的前一次 `dedup-foreground` 被 SDK auto-background 破坏前台前提，明确 failed precondition 并 confirmed pause，不计通过。

原件：`controller/dedup-static-{baseline,observation-1,before-esc,esc,stop}.json`、`foreground-config-preflight.json`。最后测试pane w22:pA已关闭，所有本次测试任务 runtime_pid=null、停止确认 true；`controller/final-task-stop-audit.json`。

## 失败与负例保留

- negative：build1（digest `30cc2264…`，0.8.1）单文件 README 修改，无 task/evidence请求/hint/native成员；w22:p6 关闭。其入口代码之后未改，不冒称这是build3同次运行。`controller/negative-audit.json`。
- 首轮 positive：官方 OMP18.4.9模块加载错误失败；w22:p5关闭。安装器仅在暂存副本对已核实版本的一处 ratchet/prelude import 明确 `.ts`；OMP2 对官方tarball与完整入口独立核实。用户全局OMP不变，未升级SDK或维护fork。
- positive2：有真实推荐、交付、9/9测试与独立完整终检，但旧失败成员未结算阻止完成，**failed completion** 保留；普通 cleanup stop=paused confirmed，w22:p7关闭。`controller/positive2-audit.json`、`positive2-settlement-failure/`。

## 资源与检查

positive3 原资源组分列：Root GPT 35调用，已报告 input69873/output6716/cacheRead1211392；执行GLM10调用 input65262/output9586/cacheRead59968；Zenmux两次失败用量unknown。Jev entry1377/63、stage1 20720/330、结构42627/160、候选48755/576、checker选型13583/84（input/output）；独立GLM已报告 input22991/output2167/cacheRead41600，K3 input23490/output2498/cacheRead64256，Go额度失败unknown。检查 reported subtotal157002，不代表完整总量；Root/成员/缓存桶不混算，现金、实际额度扣减与整任务总费用仍unknown。这是单任务可用性证据，无配对成本优势结论。

最新完整 `npm test` exit0（`controller/full-test-restored-result.json`，`02:31:33Z`，含成员收尾、原生裸grep及安装修正）；焦点回归与独立三OMP原件复核已完成。真实 SDK工具 read/grep/glob 原始/gate后结果核对在 `controller/grep-native-semantics.{ts,json,log}`，不是模型驱动验收的替代。

最终 `npm pack --dry-run --json --ignore-scripts` exit0（83文件）、real-acceptance Skill validator exit0。`controller/final-source-digest.json` 重算83源文件 digest 与被测build3完全一致；安装暂存树只有按实际宿主18.4.9同步的 reviewer package/lock 两个预期差异，未把它们冒称逐字一致。最终文档均不在安装清单，运行代码、合同和校准内容未变化。`git diff --check` 的最终退出码由 `controller/final-verification.json` 保存。

保留以上夹具和原件供复核；无用测试pane与自有工作进程已收尾，用户指定三个OMP及zeen保持原状态。本次不推送、发布或更新全局安装。

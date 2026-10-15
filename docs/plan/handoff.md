# Orbit 当前交接

最后核对：2026-10-12。源码版本以 `package.json` 为准（当前 0.8.11）；用户安装版本、commit 与内容摘要须以 `orbit version --json` 核对，本页不记录。

## 当前进展

- **剩余修复复核（2026-10-16）**：用户授权审核并提交有价值的剩余代码。下列长目录覆盖登记与 `complete` 携带问题却未通知 Root 的两项修复均保留；核对了读写一致性、目录绑定、问题去重、纠正投递与完成条件。`requirement_coverage_test.rb`、`task_runtime_test.rb` 和版本一致性检查本轮通过；本轮未运行新的真实模型验收、未安装或升版。两项代码、对应测试和交接记录随本次提交保存；产品职责调整仍只完成文档。

- **产品职责调整（2026-10-16，仅文档）**：用户确认先改产品定位与冲突规则。[ADR-011](../adr/011-agent-autonomy-and-runtime-responsibility.md)记录替代理由，[任务运行合同](../../contracts/task-runtime.md#已确认的职责调整待实现)规定 Root 判断、成员自主实施、检查者自主取证、程序如实记录与执行的目标职责；README、ADR-008/009 和[改动方案](../reference/orbit-experience-review-20261015/agreed-change-plan.md)已对齐。总成本按整项任务评估，包含重试、重复检查、等待、返工及用户介入，不新增硬门。本轮未改产品代码、schema、集成合同、安装或版本。特别是当前 `needs_user` 仍为已停止状态，续接仍仅支持 `paused`；目标改动需按 ADR-010 处理真实调用方兼容后实施。EXP-05 先日志后观察，EXP-07/10 暂不单独改，EXP-11 漏查保留，EXP-13 路径修复候选尚未确认。后续从上述改动方案进入，不把目标文档当作已修复证明。

- **Zeen 使用体验复核（2026-10-15，继续讨论）**：原始评价与合同／日志／代码分析已集中到[使用体验复核入口](../reference/orbit-experience-review-20261015/README.md)。补充复核跨 117 条入口、5 个主会话的 168 条用户消息及当前 8 项任务，恢复了 9 月 28 日首轮反馈，重点分析 15 个用户介入片段。入口维护 EXP-01—10；用户已确认[EXP-01—04 改动方案](../reference/orbit-experience-review-20261015/agreed-change-plan.md)，当前仅落文档、尚未实施，本次未修改产品代码与原始任务记录。用户另已确认取消 coverage 固定 64 项上限；EXP-04 沿用开放只读取证与相关性判断，补充较早回执可回查的验收。EXP-05 已确认补充完整 JEV 请求、裁剪、返回与程序决策记录，以及监督中断／恢复、成员退出／通知／接管记录；顺序已确认先补日志并观察真实调用；输入方案优先评估取消人为截断，独立检查者沿用自主取证。具体输入、判断、触发和纠偏调整待证据支持。EXP-06 已确认将用户新指令、提问和纠正的原文传给 JEV，结合旧要求判断当前行动，不自动修改或取消旧任务；EXP-07 已确认暂不调整、保留核查。EXP-08 除历史等待错误外，当前源码已通过本地无模型探针复现成员中止并移除后仍返回缓存 running、运行时保留未结束的缺陷；本机 0.8.11 相关实现与工作区相同。证据已写入其他轮根因复核；已确认保存成员终态、未知如实返回、不沿用旧 running 的修复方向，未改产品代码。EXP-09 于 2026-10-16 已确认由 Root 判断是否需要用户介入，检查者与程序提供事实，不再用 needs_user 自动停止或拒绝续接；沿用既有提问、通知与续接能力，用户明确停止仍有效。方案已落文档、未实施；EXP-10 已确认暂不单独调整汇报机制。10 月 16 日另完成 [Loom 长会话复核](../reference/orbit-experience-review-20261015/loom-experience-review-20261016.md)：核对主会话、Goal 计划及四轮任务，新增 EXP-11 独立检查误报完成、EXP-12 同一申诉 22 次裁定全部过期而未结束、EXP-13 四项任务错指旧对话；后两项有当前代码依据，EXP-13 另有只读探针复现导出遗漏。EXP-11 已追加[检查调用追查](../reference/orbit-experience-review-20261015/exp-11-review-trace.md)：最后检查完整读到标准，但未读原型或遗漏页面代码；上一轮 9 项交付未核实原因未传入下一轮，源码证实历史仅投影元信息。用户已确认将 EXP-11 的记录访问并入 EXP-02：程序提供实际任务记录目录与文件用途，检查者自主补读，不默认塞入全部历史或另建机制。原型及页面本可读却未查的漏判仍保留。EXP-12 已确认：裁定及期间变化交给 Root，补充 Root 通过现有 Orbit 工具采纳或要求补查的能力；程序不自动作废、不自动重复裁同一申诉，等待处理不阻断其他工作与正常检查。方案已落文档、未实施。EXP-13 已追加[根因与原生复现](../reference/orbit-experience-review-20261015/exp-13-session-path-cause.md)：本机 OMP 18.9.0 新建和切换聊天时活动地址更新、Registry 登记地址不更新，Orbit 误取后者；从活动会话公开属性读取实际地址的候选方向已有探针依据，尚未确认修复方案。未修改 Loom、OMP 或产品代码。

- **Loom 终检纠正派发修复（2026-10-15，仅隔离安装）**：真实分析 `e2137804-87dd-4225-9f56-05f6b6b19837` 的 reviewer 返回 `complete` 且带来源标识笔误 finding；运行时将其保存为 open，却只等待而不唤醒 Root。`task_runtime.rb` 的 complete 分支现对新接纳 finding 复用既有纠正派发，未清空问题或放宽终检、版本及停止门。既有 runtime 回归改用该组合并通过；旧真实任务保留 paused、停止 confirmed、工具零与异步结清记录。标准安装器仅更新 Loom 本轮隔离目录，后续真实分析 `aa293d07-cd80-4bd4-8183-a9debae66a65` 取得独立终检、complete 与真实停止回执；这证明新安装可收尾，不声称该次又触发了相同 finding 分支。该报告随后因 Loom 补入追加授权上下文而过期，未改写原件。未更新全局安装、升版、提交、推送或发布。

- **Loom 长工作目录覆盖登记修复（2026-10-15，仅隔离安装）**：真实准备任务的产物根路径超过128字符，被误用短标签上限拒绝，独立检查结束后仍无法登记逐要求覆盖。`requirement_coverage.rb` 对路径单独采用4096字符边界，写入与历史回读一致；短标签上限、逐字根路径绑定和完成门不变。`requirement_coverage_test.rb` 通过长路径保存、回读及换根失效回归；源码经标准安装器装入 Loom 本轮隔离目录，未切换全局安装。真实 GLM 项目分析任务 `b5d3d956-2fe7-4d9c-8996-7bcc6c5a9785` 的公开回读为 `status=complete`、停止确认与覆盖 ready 均为真，第2次 artifact reviewer 检查非陈旧且 input_current 为真。该证据证明 Orbit 在长目录下完成；首份报告的来源补读缺口由 Loom 工具授权修复，不冒充项目验收。原失败任务保持原记录，未发布或升版。

- **Loom 旧派发结算修复（2026-10-14，未更新全局安装）**：要求修订后，已被 Root `failed/rejected` 的旧派发因不再匹配当前输入而永久 `registered`。运行时现对精确身份及真实输出作核对，再经实际 `stop_member` 屏障记停止后拒收；旧 `accepted`、未知停止、新派发与当前终检门均不放宽，原失败记录不改。`task_runtime_test.rb` 全部通过，新增三项覆盖正常收尾、异步未收完拒绝收尾及旧接受不提升。Loom 同一活动 Goal `ff1ef948-416d-434c-9ae4-987fc863493d` 的观察进程经源码入口重新附着，四个真实成员均为 `rejected`／`execution_status=stopped`，实际停止确认、工具零与异步结算均为真，`accepted_at` 仍为空；原第34次手动终检恢复为当前可申请完成。未手工改写任务记录或加载新 OMP 宿主插件，未改全局安装；随后公开完成申请已确认，Goal 的独立检查与实际停止均通过。

- **Loom Root 交付归属修复（2026-10-14，源码未安装）**：独立用户问题之后，宿主忽略真实 Orbit `custom_message`，导致后续任务报告仍归到旧用户消息。`omp-host.mjs` 已按实际 native 分支采用 Orbit 的耐久标记并截断近期观察，运行时继续按本任务发送集合验证，未放宽独立问答或完成门。回归在旧实现以 `independent-user != task-wake-marker` 失败；修复后 `omp_collab_evidence_test.mjs`、`omp_native_gate_test.mjs` 与 `task_runtime_test.rb` 通过。当时 Loom Root 的公开只读接口证明：已送达的本任务 Orbit 标记存在，但旧宿主仍返回 iOS 独立问题 `c3275471`。该 OMP 宿主未热改或全局更新，不能把源码测试称作宿主已恢复。用户随后授权本轮提交与推送，发布与全局安装不在此授权内。

- **ORBIT-REVIEW-OUTPUT-10**：私有检查者已接 OMP 原生 `outputSchema` / `requireYieldTool` / `yield`；完整报告必须通过原参数严格校验及成功提交门，末尾文本仅留证，不再解析为报告。相关零模型测试与官方 18.9 源码定点验证通过，四类旧错误原件仍拒收。Root 已复核并触发持续发布授权，patch 升至 0.8.11；补齐含 yield 的会话工具断言，真实 OMP 18.9.0 零模型逃逸检查通过并释放。未调用模型或复测弹窗；提交与安装身份以 Git、公开 version 及 release 回执为准。接口、SDK 局部适配和未验证范围见[实现记录](../reference/reviewer-structured-output-20261013.md)。

- **ORBIT-REVIEWER-TOOLS-08**：修复私有 read/grep/glob 将 Zod 实例误作 SDK JSON Schema 的接线；声明显式转换，执行前复用原定义拒绝缺必填，合法 intent 不误拒。OMP 18.9.0 真实零模型宿主已验证三工具 schema 与参数 validator，既有权限测试通过。Root 已复核并触发持续发布授权，patch 升至 0.8.10；提交与本机安装身份以 Git 和公开 version 回读为准，详见[实现记录](../reference/reviewer-tool-schema-20261012.md)。

- **ORBIT-STRUCTURED-RESULT-05**：Root 授权单一完整 json 围栏格式恢复，已实现并按复核修正 JSON 字符串含反引号时的兼容边界。原文保留，内部严格校验不变；18项相关测试及三份原件零模型重放通过预期，GLM两类非法输出仍拒收。Root 已独立复核通过并触发已有持续发布授权，patch 升至 0.8.9；提交与本机安装身份以 Git 和公开 version 回读为准，详见[实现记录](../reference/structured-result-recovery-20261012.md)。

- **ORBIT-CHECKER-STARTUP-02**：0.8.7 基线的 GLM 检查实际已进入 provider 流，OMP 外层 startup watchdog 因 trusted factory 保持 pending 而误报模块阶段。仅补内部阶段证据和日志，真实零模型宿主复现与相关既有测试通过。原 check 最终因多余 `}` 被正确拒收为 invalid_result；长等待/模型格式问题未宣称修复。用户要求收束、不新增模型，原运行停止归 Loom Root。用户追加本票提交、推送与本机更新授权，patch 升至 0.8.8；具体提交与安装身份以 Git 和公开 version 回读为准，详见[诊断记录](../reference/checker-startup-20261012.md)。

- **Loom 联动：严格模型授权票**：2026-10-12 用户授权 Orbit 定位/实现并向 Loom Root（w22:p1）回报，不另建 Goal。源码新增合同 1.4 `model_authorization`：`start --allowed-model` 与可选 `ORBIT_ALLOWED_MODELS` 启动上限，冻结任务名单、接续继承/缩小、调用前守卫与池耗尽阻断；普通任务保留偏好池。可选 JEV 关闭，宿主公开 stream/resolver/getApiKey 与选模接缝受限。实现与实测基线 `4a529aa`（0.8.6）；用户随后明确授权升至 0.8.7、提交/推送 main 并执行本机 orbit update，交付身份见 Git 历史与公开 version。发布与 tag 未授权。零模型边界、隔离全套 npm test、MiniMax 实际 Root/独立检查/确认暂停与独立只读核查均有记录；最终定点复核与资源收尾见[本票记录](../reference/loom-model-authorization-20261012.md)。Loom 原 `0595af38` 的未知停止来自宿主 socket 拒绝连接，不能确认 Root/工具退出；保持 unknown/writer，不修改其状态。Loom 端适配与复验由 Loom Root 负责，原生严格成员/实际故障回退/硬名单的真实接续组合未据此认证。

- **版本与推送**：用户于 2026-10-12 追加授权更新版本号、提交并推送 `main`；软件 patch 升至 0.8.6，包含已完成的 Loom 集成 A/B 与冷启动绑定修复。此轮仅改版本元数据与交接，不重标既有真实验收构建；发布、tag 和日常安装不在本次范围。

- **外部 CLI 冷启动绑定修复**：用户追加 Goal 授权，Root 已补运行时精确绑定与接纳前权限边界；隔离快照 npm test、真实 OMP 18.9.0/MiniMax 的外部 CLI 启动→running/hub事件→Root写入→引用回读→确认暂停，以及独立 OMP 只读审核通过。随本轮 main 本地提交交付，已移除原冷启动缺口；成功终检、Loom CI 和其他平台仍未据此认证。原始证据与探针残留资源收尾见[验收记录](../reference/loom-integration-acceptance-20261011.md)。


- **Loom 集成合同提案 B**：用户已授权在 `main` 依次交付阶段 A（合同 1.2：外部会话模式、调用方指定控制通道、按外部引用查询）和阶段 B（合同 1.3：revision/updated_at、attention、最近完成检查记录）。基线 `52bb3848` 干净，已有合同 1.0/1.1 提交 `b38f0d0`、`92a00dd` 已在 main。A 已实现并通过含待交付改动的隔离快照全套 npm test、OMP 18.9.0 真实 rpc 验证及独立只读审核/修正与 Codex 收口；已完成本地提交 `86d09af`（用户署名，无 AI 署名）；B 已实现，隔离快照全套 npm test 与独立 OMP save 核查通过；真实任务证明 revision 变化/三次读稳定/实际无变化 tick/运行时重启不回退，最近失败检查与真实模型回执一致。B 随本轮 main 本地提交交付（提交标识见 Git 历史）；成功模型检查及未触发分支不据此认证。验收与驱动错误见[记录](../reference/loom-integration-acceptance-20261011.md)。冻结范围、文件所有权与门槛见[总 TODO](loom-integration-contract.md)。阶段 A/B 当时仅授权每阶段本地提交；后续升版与推送授权见本页“版本与推送”。
- **最近一次真实验收的构建**：0.8.4（`25f0104` dirty，临时安装 digest `c70f5b60…`），内容为本地 OMP 宿主复用与检查历史内容去重归档；之后 0.8.5 只改版本元数据，不重标为实测。其真实验收范围与已知缺口列在[当前限制](debt-ledger.md)；Zeen 存量数据迁移/清理仍暂缓。

## 环境提示

- 全仓 `npm test` 需要 `node_modules`：本工作区未安装依赖时，`prestart_test.rb`、四个 `.mjs` 测试和 bun 套件因缺 `zod` 失败，在未改动的 HEAD 副本上同样复现；`npm ci` 后通过。需要时在临时副本里安装，不要把依赖装进仓库。
- 本次 A/B 与冷启动修复的 main 本地提交已有用户明确授权；2026-10-12 追加授权本票软件 patch 升至 0.8.7、提交/推送与本机 orbit update。发布、tag 未授权。

## 当前有效边界

产品语义以[任务运行合同](../../contracts/task-runtime.md)、[检查结果 schema](../../contracts/check-result.schema.json) 和 ADR-008/009/010 为准；有界真实验收不推广为全模型、全分支或普遍成本收益。开发规则沿 [AGENTS.md](../../AGENTS.md) 与[开发流程](../agents/development-workflow.md)。

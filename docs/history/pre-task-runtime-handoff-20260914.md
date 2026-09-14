> 历史快照：保存自 `e578365` 的 `docs/plan/handoff.md`。其中阶段与授权描述是写作当时的事实；现行入口为 `docs/plan/handoff.md`，语义以 ADR-007 和 `contracts/task-runtime.md` 为准。相对路径保留原文语境。

# Handoff：阶段 G 已完成，先讨论重构方案

本次收尾授权（2026-09-14）：用户要求先做一次本地提交，保存当前方案与评审交接资料；此前“不提交”的限制对本次提交解除。未授权推送、实现、初始化或启动 Goal。

最新决定（2026-09-14）：用户同意第二轮评审收敛，并明确本次重构不兼容旧版，不需要的能力直接删除。愿景计划已同步「重构与兼容边界」「第二轮评审收敛」及代码取舍：不留兼容层、旧命令别名、旧格式解析或仅为旧数据续用的迁移机制；本仓相关调用、规范和测试随删除同步调整。当前仍未授权实现或实际删除，用户数据、自定义规范及现有规范和交接资料继续保留。

2026-09-14：Root 已对照当前代码整理[代码取舍与最小实施顺序](./vision-completion-plan.md#重构收敛稿代码取舍与最小实施顺序2026-09-14)，包含保留／简化／删除建议、必须补齐的能力、Zeen 复用边界、合同和调用影响，以及两条验收的最小走法。供整体审阅，尚未批准实现；少数具体删除／替换建议与既有用户确认方向在正文中区分。不续做旧 H–K，不提交推送。

用户随后要求评估角色规范。Root 已补充愿景计划「角色规范与 Zeen 规则取舍」：以精简重复与错误升格为主，补齐 Root／检查／裁定职责；Zeen 通用经验适配吸收，项目专属规则只在对应项目按需读取。该节为建议，运行时规则、manifest 与产品合同尚未修改，不恢复旧三份角色指南。

用户要求配置说明提供各角色的模型方案，已补充「用户配置中的角色与模型建议」：包含单供应商和已有多供应商搭配、官方来源及适用边界。具体型号是初始建议，不是 Orbit 实测排名或已支持接入声明；不要求四种模型常驻，不自动更换当前 Root 或购买套餐。

用户随后授权四位现有 Herdr Agent 第二轮独立挑战，已全部完成；见[第二轮回报与 Root 核查](../reference/orbit-refactor-challenge-20260913.md#第二轮2026-09-14-最新收敛稿与角色模型建议)。用户随后同意 Root 收敛出的原始执行消息传递、共同适用的项目规则、只读检查的执行验证隔离三项澄清，并保留误报撤销的验证方向，已进入愿景计划；其余扩展不自动采纳，不扩大验收，不启动第三轮。

当前先完成 Orbit 减重与重构方向讨论：工具目标、模型与程序的职责、与 Zeen 反馈执行服务的独立接入，以及最小验收路径。尚未批准具体实现方案，不直接启动旧阶段 H、产品初始化、真实模型验证或实现 Goal。

2026-09-13 本轮已确认的方向及最小验收记录在[愿景计划「当前重构方向」](./vision-completion-plan.md#当前重构方向2026-09-13-讨论确认)。恢复时先读该节，不重复询问已确认决定；Root 自动替换与运行故障自动恢复均退出当前范围。产品合同未修改，后续先对齐具体差异，不直接开工。

用户随后指定四位 Herdr Agent 独立挑战，反馈与 Root 核查见[一轮挑战记录](../reference/orbit-refactor-challenge-20260913.md)。其中建议仍待讨论，不自动改变已确认方向；优先补清最小执行主体、检查输入与实际停止边界。

运行主体已确认：受控任务从 Orbit 启动，独立 Orbit 进程负责整个运行过程，完成必要收尾后退出；支持 Coding Agent 在已有授权内通过 skill 自主调用，见愿景计划「运行方式」。常规只读检查与执行并行、交付前核对实际版本的方向也已确认，见「检查与执行的关系」。[同类项目调研](../reference/orbit-execution-host-research-20260913.md)保留来源与理由。后续继续明确接入、输入和停止边界；尚未批准实现或依赖选型。

最新接入方向：调用 skill 的现有 Agent 默认继续担任 Root，保留上下文，以通信与控制通道接入 Orbit；不采用第一版强制新建 Root 的建议。下一步核实通道能力，不重复要求用户在新旧 Root 之间选择。

通道核查已有具体依据：本机 Codex 提供已有会话消息入口，官方 App Server 文档提供途中输入、状态读取与轮次中断；详见[调研中的现有 Root 接口核查](../reference/orbit-execution-host-research-20260913.md#现有-root-的通信与控制接口核查)。仅查帮助与文档，未实测接入。暂停粒度已获用户确认，见愿景计划「暂停粒度」；不能把轮次中断视为全部后台执行停止。

执行输入也已确认，见愿景计划「执行输入」：保存用户原始执行指令，检查时对照该指令及其指定的文档或 prompt；不接管需求讨论，不收集整段聊天或增加需求表。不要重新扩展成需求管理流程。

额度与时间已确认，见愿景计划「额度与时间」：优先完成需求，先粗估、完成后对比并分析偏差，作为后续优化依据；超预估不自动停止或要求审批。只有用户另行明确指定的硬上限才产生资源停止条件。关键产品讨论已收敛，代码机制取舍与最小实施顺序已整理在 2026-09-14 收敛稿，仍未授权实现。

开发本仓遵守[开发协作流程](../agents/development-workflow.md)，由根 `AGENTS.md` 加载。Zeen 的规范与代码保存在[交接包](../reference/zeen-orbit-handoff-20260913/README.md)，仅作参考；本仓开发规范不代表 Orbit 产品已具备自动监督能力。

- 接续日期：2026-09-13；实现状态基于阶段 G 的 2026-08-17 交付
- 基线 HEAD：`24efecb`（本清理提交叠在其上）
- 对象：下一个对话 / 下一个 agent。读完本文再读计划，不要从 `history/` 开始改。

## 先读什么

1. 本文（现在在哪、下一步是什么、不要重开的争论）
2. [新交接包](../reference/zeen-orbit-handoff-20260913/README.md) 的用户边界与未决事项，再读 [`vision-completion-plan.md`](./vision-completion-plan.md) D1–D11 理解既有取舍
3. 动 `lib/` 或 `contracts/` 前：[`debt-ledger.md`](./debt-ledger.md)
4. 语义以 `contracts/orbit-v2/` 与 `docs/adr/` 为准

工单（`history/g*-workorder.md`）没有裁定权。G.1 设计稿已归档，切分事实以仓库里的规则文件和 D11 为准。

## 现在的产品状态

阶段 **G 已交付**。规则能装进项目、能钉进 attempt、能更新、能被评审者继承。

| 能力 | 落点 |
| --- | --- |
| 八份任务规则 + 共享升格格式 + 常驻路由器模板 | `skills/orbit/assets/rule-library/` |
| `init` 拷 `tasks/`+`shared/` → `rules/`，参考层 → `docs/orbit/reference/`，无 `AGENTS.md` 才创建 | `lib/orbit/v2/cli.rb` |
| implementer 默认钉四条 + 共享 payload；reviewer inherit subject 已记录字节 + `review.md` | 同上 |
| `rules update`：未改过覆盖，改过写 `.upstream` | 同上 |
| 本仓库根 `AGENTS.md` | **开发仓纪律，不是产品默认协议** |

CLI 现有：`init` / `task start` / `rules update` / `dispatch` / `evidence submit` / `gate submit` / `finding resolve` / `complete` / `status`。控制流命令（retry / fuse / budget override / checkpoint 观测）库内有、未暴露。

**还没有的**：把 `ContextProjection` 交给 agent 的出口（H）；外层循环（I）；真正拉起 agent（J）；愿景验收（K）。v2 **仍不能让任何 agent 发生**。

## 已用测试钉住的性质

除非改到对应代码或出现新的失败证据，不重复验证这些性质：

- 默认规则的 `content_sha256` 等于文件真实 digest
- 改规则字节后，旧 attempt 仍钉旧 digest；新 dispatch 钉新字节
- 历史复验走 `RuleResolution.validate!` 的 `verify_files: false`（`contract.yaml:158`）
- 规则中途被改 → reviewer inherit 在 `RuleResolution.build` 以 `rule_resolution_digest` fail closed（D11，正确行为）
- `rules update` 不改已钉 attempt，不在活文件里插冲突标记
- 已有项目 `AGENTS.md` 时 `init` 字节不变

## 不要重新提出

| 已否 | 为什么 |
| --- | --- |
| 规则留在 skill 目录当 `--rule` 运行时路径 | `canonicalize_path!` 会拒；放宽它是安全边界 |
| hybrid（skill 基线 + 项目增量） | 同一 `rule_id` 两来源 |
| 先写全套投递再接循环 | alpha #5 |
| 升格 payload 复制进 8 份规则 | 爆炸半径与抽共享文件相同，但会漂移（D11） |
| 让 inherit 跳过 `verify_files` | pin 与磁盘脱钩 |
| 真实执行层先于 runner | D3：先测确定性循环 |
| stub 留成永久件 | D4，自我违规 |
| Zeen 四层文档 / 多席轮次 / 三库正文 | D9 |
| 完整性下界 / `needs_user` payload / Finding 门槛产品化 | D10，未承诺 |

## 当前讨论的交付

由 Root 直接核查并收敛重构方案，不默认派发。明确哪些版本、证据与上下文机制保留，哪些协议操作应由程序承担；说明运行中如何发现并落实纠偏，以及如何避免 Orbit 和反馈执行服务拥有两套调度状态。

方案需包含正常交付与该停时能停的最小验证，区分确定性测试和真实模型效果。未定产品问题逐项讨论，既有明确授权不重复询问。形成共识后，先对齐需要变化的 ADR／合同与实施计划，再进入开发。

旧 H（投递出口）、I（runner）、J（真实执行与观察）、K（愿景验收）见[既有计划](./vision-completion-plan.md)。它们仍是差距清单，但不是当前开工顺序；不在本交接内提前决定重写或删除产品能力。

## 本轮从活跃层清走的文件

| 原位置 | 去向 | 原因 |
| --- | --- | --- |
| `docs/plan/g1-workorder.md` 与 `g1-rule-library-design.md` | `docs/history/` | G.1 已完成 |
| `docs/plan/g2a`–`g2e-workorder.md` | `docs/history/` | G.2 已完成（无独立 `g2c-workorder.md`，那轮只经 herdr 派发） |
| `skills/orbit/references/runtime/guide.md` | `docs/history/v1-runtime/` | v1 命令面，会让 agent 按已删除的命令行事 |
| `skills/orbit/references/runtime/core-operating-model.md` | `docs/history/v1-runtime/` | 同上，947 行 |

v2 操作入口只剩 [`skills/orbit/SKILL.md`](../../skills/orbit/SKILL.md) 与 `orbit v2 --help`。完整 v2 runtime 文档重写仍是欠账第 6 项，但风险从「skill 目录里有一份看起来像现行指南的 v1 稿」降为「history 里的史料」。

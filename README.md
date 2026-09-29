# Orbit

**Orbit 帮你在有限的顶级模型额度下组织开发任务：主 Agent 负责交付，其他模型承接工作，独立 Agent 核验进展和成果，发现跑偏或漏项后回到原会话纠正。目标是尽可能保持质量、完成更多工作，并减少用户介入。**

- **组织分工：**Root 可从当前会话的候选模型中派发有边界的工作，并核验、集成结果。
- **保存目标与纠正问题：**记录原始要求和修订，按需独立检查，发现问题后交回 Root 修正。
- **交付更清楚：**独立核对实际成果，有遗漏就回原会话修；你能看到任务仍在执行、等待检查，还是已确认完成。

例如你让 Agent 实现登录功能，不用自己盯着它是否卡住、是否漏了错误提示，也不用在几个 Agent 之间转述要求；你只和原 Agent 对话，并查看最终检查和任务状态。

卡住／偏航判断和分工建议需要[启用 Jev](docs/reference/usage-reference.md#jev-配置)。Orbit 不自动派发成员；现有有限样本不能证明所有任务都能节省额度或可靠交付。认可的新方向是任务相关质量与可信 OMP 路由 token 成本；当前源码仍有时间评分和粗费用档位，改造尚未完成，详见[主方案与代码审计](docs/plan/mixed-model-delivery-code-audit.md)。

## 三步开始

### 1. 准备并安装

先准备 Ruby 3.2+、Node.js 18+、npm、Bun 1.3.14+，以及**已配置可用模型的 OMP 18.2.8 或更新版本**。远程安装还需要 `curl` 和 `tar`。`orbit omp` 只拒绝低于 18.2.8 或无法识别版本的 OMP；更高版本通过版本门不代表其全部运行路径已单独验收。

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh
```

安装程序会为 zsh／bash 保存 PATH 配置。重新打开终端后运行：

```bash
orbit --version
orbit doctor
```

要启用上面的卡住／偏航判断和分工建议，再运行 `orbit jev setup` 配置 TypeSafe key，并重新打开终端。未启用 Jev 时，任务记录和独立产物检查仍可使用。

若希望检查者在缺精确资料时参考有来源的模型级编程基准，可另运行 `orbit openrouter setup`，在无回显提示中填入独立 OpenRouter key，重新开终端。**可选，不配置就不向 OpenRouter 请求目录**；项目 `.orbit/jev-disabled` 也禁止该请求。只有已核实映射和非空指标可作为弱质量排序先验，不能代替本路由质量、费用、耗时或执行成员的精确补证。目前六候选中仅 Kimi K3 一条有可用编程指标；设置、状态和来源见[进阶说明](docs/reference/usage-reference.md#openrouter-模型概述自愿启用)。

程序只需安装一次，各项目共用。安装对外只创建 Orbit CLI 入口；扩展由 `orbit omp` 在启动该会话时加载，不写入 OMP 的全局扩展目录。

### 2. 在项目里启动会话

```bash
cd 你的项目
orbit omp
```

Orbit 基于原版 [Oh My Pi（OMP）](https://github.com/can1357/oh-my-pi)；`orbit omp` 只为本次会话加载扩展，普通 `omp` 不会接入。具体执行要求即使不提 Orbit，也会在 Jev 入口判断执行授权与独立检查收益都达到 0.80 时自动尝试受控启动；明确要求 Orbit 受控执行直接尝试启动。只读讨论、明确不使用 Orbit 的请求不启动；不确定、缺少 TypeSafe key 或项目禁用外发时仍由当前 Agent 显式决定。**显式受控请求启动失败不能改作普通执行；非显式自动候选启动失败会告知原因，Root 可按原要求普通执行，但这次没有 Orbit 检查或停止确认。**新题义的非显式召回仍以[历史冻结构建验收](docs/reference/zeen-orbit-experience-acceptance-20260928.md)为准，不从一次模型抽样推断已稳定。

像平常一样提出需求，例如：“按 `docs/requirements.md` 实现功能，完成必要验证并交付结果。”如果必须由 Orbit 监督，可补充“这次请使用 Orbit”；产品名不是日常自动启动的前提。

`orbit omp` 原样透传 OMP 的模型、profile、权限和恢复参数。例如 `orbit omp --model provider/id`，或 `orbit omp --resume SESSION_ID` 恢复已有会话。普通终端、tmux 和 Herdr 都可以使用。

### 3. 查看任务结果

Agent 会在会话中处理任务和检查。你可以在同一项目的另一个终端查看：

```bash
orbit status
```

`complete` 表示当前版本的实际交付经过独立检查，相关执行也已确认停止。没有 finding 的检查不等于完成：文字答复要在终检时已实际交付，提交并推送要核验目标远端引用；检查暂不可确认时状态会指出缺少什么。检查仍在排队或运行时，任务也未完成。`orbit status` 首屏区分当前状态、原因、用户是否需要操作；助手执行检查／补证据的内部步骤不要求用户代做。普通暂停的任务不能重检或在终态申请完成，若仍需交付则创建新任务；多个任务时用 `orbit status ID` 指定一项。

Agent 验证并交付结果时应对当前任务调用 Orbit `check` 请求手动终检，在本轮回复中给出真实交付并结束；若回复仍在生成，终检会等回复完成后再启动。已完成答复被干净的自动产物检查确认后，Orbit 会按当前版本提醒助手补发一次手动终检请求；自动检查本身不发最终完成通知，用户不必为此重新催办。终检发出有效通知后才按下一步申请完成。

看到「可申请完成」时，当前 Agent 对该任务调用 Orbit 工具 `stop`，意图为 `complete`，并结束本轮；完成申请在回复结束后核实产物、要求、成员和停止结果。普通 CLI `orbit stop` 只暂停，不把历史检查通知当作完成。文件或要求变化使通知失效，须重新检查；只有最终状态为 `complete` 才算完成。`stop_unconfirmed` 不能当作已停止。

独立检查发现问题时，通知按「问题、依据、建议处理」逐项展示；它是对原任务的检查反馈，不是新的用户要求。当前助手据此修正或提交反证，随后重新检查。

## Orbit 如何协作

| 角色 | 做什么 |
| --- | --- |
| 当前 OMP Agent（Root） | 对整项需求负责，写代码、决定是否分工、核验成员结果并交付 |
| 执行成员 | 由 Root 通过 OMP 原生 `task/hub` 派发；成员不能再派发成员或另起 Orbit 任务 |
| 独立检查者 | 在单独的只读 OMP 会话里检查实际产物，把具体问题送回 Root |
| Orbit | 保存任务要求与状态，观察执行和检查，并确认停止结果 |

你不需要预先建团队，也不需要为每个项目写 Orbit 专用规范。Root 可以自行完成任务；只有分工有实际收益时才派发成员。

Root 和执行成员使用当前 OMP 会话可用的模型；候选池内可用 Agent 是受控成员的派发范围，Jev 的分工建议不自动派发。池内已有精确身份证据的候选分别评估，缺失／不可得者保持未评分，不拖住有据候选，也不能无证据推荐。Root 可以在补证待答时自行显式选择池内 Agent，记录为自己的决定；独立检查者可用池内型号即使缺证也可运行，但标记质量未经证实。

例如 OMP 的 `modelRoles.task` 为池外 `zhipu-coding-plan/glm-5.2`，受控任务有可用池内 Agent 时调用通用 `agent="task"` **会被拒绝并列出可选 Agent**，不会静默派给 GLM5.2；池空或无可用 Agent 才继续使用可解析的 OMP 默认。Root 可用 `/orbit-models` 显式加入所需型号后派发。第一阶段高分、补证请求均不是 Jev 的最终推荐：若希望按 Jev 选模，提交至少一名候选有来源、身份精确的质量与整项端到端时间资料，再核对实际送达的提示；没有推荐时可自己完成或显式选池内成员，不把自选冒充 Jev 推荐。检查者补证的 `reasoning`／`billing_route` 均明确为 `unknown`；不能把旧 `default` 缓存或不同计费路由当作同一身份。

**多模型选择：**会话内 `/orbit-models` 从当前 OMP 可选列表维护跨会话候选池。检查者优先预检池内可用型号，池空或池内均不可运行时继续从 OMP 当前可用目录中选择；Root 可显式指定可运行型号，无须用户逐型号授权。缺精确事实时标记“检查质量未经证实”，不把型号可选或凭据预检说成实际请求成功。检查失败后 Orbit 在当前产物版本内有界尝试不同可运行型号；全失败则保留证据并阻塞完成，由 Root 检查 OMP 配置并重新选择。状态见[合同](contracts/task-runtime.md)、[ADR-009](docs/adr/009-user-selected-model-pool.md)及[交接](docs/plan/handoff.md)。

#### 选择候选模型（`/orbit-models`）

在交互式 `orbit omp` 会话里输入 `/orbit-models`，直接输入文字按 `provider/id` 搜索；↑/↓ 移动，Space 勾选或取消，Enter 一次保存本次净变化，Esc 取消。当前会话不可选但已入池的旧标识仍保留在列表，可勾掉移出，不能新增。列表仅表示当前会话可选择，不保证模型已验证可调用或有额度。

池内证据标签只来自**精确 `provider/id` 身份**的本地缓存，过期／缺失会明确标出；「质量未判断」「隔离检查者未探测」不代表质量或凭据已验证。`orbit model-status --project DIR` 只读候选池与证据，不运行 Jev 或隔离探针；真实启动返回 `evidence_needed`，Root 用 `orbit model-evidence --file -` 补交一手资料，也可带当前任务目录提交对应检查者事实；无法核实可提交 `status=unavailable`。新增有效资料在下一次独立检查前重新判断；逐型号判断随任务状态保存，无可运行型号的失败保存在项目 `.orbit/checker-selection-failures.jsonl`。Root 可在启动时传 `review_model` 或在任务中执行 `orbit review-model TASK_DIRECTORY --model provider/id`；用法见[使用参考](docs/reference/usage-reference.md#候选模型池与检查者重选adr-009)。

无交互界面或需要脚本操作时，继续使用：

```text
/orbit-models add provider/id     # 加入当前会话可选列表中的模型
/orbit-models remove provider/id  # 从候选池移除
orbit model-candidates list       # 终端查看候选池
```

候选池跨会话保存，只保存模型标识，不保存凭据。批量保存拒绝同一模型的并发冲突，不覆盖其他会话对不同模型的修改；池内但当前会话不可选的标识可移除但不会因此启用。池空时不生成自动成员建议，Root 仍可使用当前 OMP 可解析的通用 `task`；检查者从 OMP 可用目录选择。池非空却没有可运行检查型号时同样回退到 OMP 目录；全部不可运行才阻塞受控启动。

缺同标识质量事实时，Orbit 不让 Jev 凭模型名称评分；可运行型号降级选择后仍需真实独立检查。Root 可从一手来源查证后用 `orbit model-evidence --file FILE` 更新缓存；不能核实则记录不可得。Root 显式检查模型在建任务前预检隔离目录与凭据，实际请求或额度仍可能失败。操作见[进阶使用参考](docs/reference/usage-reference.md#模型证据提交model-evidence)。

## 日常命令

| 命令 | 用途 |
| --- | --- |
| `orbit omp` | 启动带 Orbit 扩展的 OMP 会话 |
| `orbit status [ID]` | 查看任务、成员、检查和下一步 |
| `orbit stop [ID]` | 请求停止任务；再用 `status` 确认结果 |
| `orbit export TASK --output FILE` | 本地导出单任务证据包，供你选择是否交给开发者分析 |
| `orbit session-summary --thread ID` | 只读汇总本项目同一原生 OMP 会话的任务与检查；缺失和费用未知如实保留 |
| `orbit doctor` | 检查安装、环境与可验证的会话连接 |
| `orbit update` | 更新这份安装；已有会话继续使用其启动时的版本 |
| `orbit uninstall` | 卸载这份安装 |

用户在原会话发来的新消息不会被无条件加入现有任务；确认它确实修订旧任务时由当前 Agent 显式 `amend`，独立问题另行处理。需要从另一个 worktree 继续同一任务时使用 `orbit rebind-workspace`；其他手动参数见[进阶使用参考](docs/reference/usage-reference.md)。

任务在运行中或结束后均可导出。包内是观察到的派发、模型、协作、检查与纠偏事实及证据缺口，不会调用模型复盘或自动上传；实际完成仍以 `orbit status` 的任务状态为准。导出包可能含任务原文、项目代码快照和会话内容，分享前请自行检查。

卸载前请结束使用该安装的任务和 OMP 会话。若仍有会话占用旧版本，卸载会拒绝并保留安装；卸载不会删除项目代码或 `.orbit` 任务记录。

## 常见问题

### 已打开的普通 `omp` 会话能直接接入吗？

不能。退出后用 `orbit omp --resume SESSION_ID` 恢复；扩展在会话启动时加载。

### Agent 没有启动 Orbit 任务？

普通执行请求不要求先说出 Orbit：若没有自动启动，请先看入口提示与 `orbit status`，区分低收益判断、TypeSafe 不可用和建任务前置校验失败。需要明确受控时可直接说“这次请使用 Orbit”；若启动受候选检查模型或环境校验阻断，由 Agent 按提示补充真实证据或显式选择可运行检查模型。显式请求失败前不普通执行；普通请求的自动候选失败则会标明本次不受监督，可继续普通执行。若会话里没有 Orbit 工具，先确认它由 `orbit omp` 启动，再运行 `orbit doctor` 检查安装和连接。

### `orbit status` 显示检查通过，任务就结束了吗？

还要看任务状态。检查结论、当前版本可交付、完成申请入队与实际停止是不同事实；只有任务状态为 `complete` 才表示都已完成。`stop_unconfirmed` 表示已尝试停止，但尚未确认相关执行全部退出。完整状态说明见[进阶使用参考](docs/reference/usage-reference.md)。

## 当前范围与文档

当前源码版本为 **0.7.10**；发布和用户安装状态另行核对 `orbit version --json`。当前实现、未完成项与真实验收边界见[交接](docs/plan/handoff.md)。安装或更新使用 `sh install.sh`，选项见使用参考。

- [进阶使用参考](docs/reference/usage-reference.md)：安装选项、Jev、OpenRouter、CLI 与维护。
- [任务运行合同](contracts/task-runtime.md)、[ADR-008](docs/adr/008-omp-native-collaboration-base.md)和[ADR-009](docs/adr/009-user-selected-model-pool.md)：当前角色、选模、检查与停止语义。
- [认可的混合模型交付方案](docs/plan/mixed-model-delivery-proposal.md)与[代码审计](docs/plan/mixed-model-delivery-code-audit.md)：目标及每项实现差距，不能当成当前已上线能力。
- [当前限制](docs/plan/debt-ledger.md)与[文档索引](docs/README.md)：已知边界和有版本范围的历史证据。

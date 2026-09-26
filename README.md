# Orbit

**Orbit 用多 Agent 协作帮你完成开发任务：主 Agent 组织执行，独立 Agent 按需检查进展和成果，发现卡住、跑偏或漏项就回到原会话纠正，帮你减少等待、返工和不必要的 token 消耗。**

- **省时间：**适合并行的工作可交给其他 Agent，卡住或跑偏时尽早纠正，减少等待和事后返工。
- **省 token 和模型额度：**避免重复检查；你可以从当前会话可选模型中维护候选池，建议分工时按质量、端到端时间和粗档费用比较，减少无收益的调用。
- **交付更清楚：**独立核对实际成果，有遗漏就回原会话修；你能看到任务仍在执行、等待检查，还是已确认完成。

例如你让 Agent 实现登录功能，不用自己盯着它是否卡住、是否漏了错误提示，也不用在几个 Agent 之间转述要求；你只和原 Agent 对话，并查看最终检查和任务状态。

卡住／偏航判断和分工建议需要[启用 Jev](docs/reference/usage-reference.md#jev-配置)。Orbit 不自动派发成员；时间和 token 的实际节省取决于任务，不能保证每项任务都比直接使用 OMP 更快或更省。

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

程序只需安装一次，各项目共用。安装对外只创建 Orbit CLI 入口；扩展由 `orbit omp` 在启动该会话时加载，不写入 OMP 的全局扩展目录。

### 2. 在项目里启动会话

```bash
cd 你的项目
orbit omp
```

Orbit 基于原版 [Oh My Pi（OMP）](https://github.com/can1357/oh-my-pi)；`orbit omp` 只为本次会话加载扩展，普通 `omp` 不会接入。新用户请求明确要求 Orbit 受控执行时直接走受控启动；明确讨论／只读问答不启动；其他请求只有经过 Jev 入口判断且执行授权、独立检查收益都达到校准门槛才自动启动。不确定、缺少 TypeSafe key 或项目禁用外发时仍由当前 Agent 显式决定。

然后像平常一样提出需求，例如：“按 `docs/requirements.md` 实现功能，完成必要验证；这次请使用 Orbit，交付时说明独立检查结果。”

`orbit omp` 原样透传 OMP 的模型、profile、权限和恢复参数。例如 `orbit omp --model provider/id`，或 `orbit omp --resume SESSION_ID` 恢复已有会话。普通终端、tmux 和 Herdr 都可以使用。

### 3. 查看任务结果

Agent 会在会话中处理任务和检查。你可以在同一项目的另一个终端查看：

```bash
orbit status
```

`complete` 表示当前版本已通过独立检查，相关执行也已确认收尾。检查仍在排队或运行时，产物可能已经写好，但任务还没有完成。发现问题后，当前会话会继续修正。`orbit status` 还会显示成员、检查与下一步；多个任务时用 `orbit status ID` 指定一项。

看到「曾收到检查通过通知，任务尚未完成」时，意思是**某次检查通过了，但 Orbit 还没确认当前文件和要求仍是那一版，也没确认执行已收尾**。当前 Agent 会核对改动：没有新改动就申请完成，有新改动就重新检查。看到「正在结束任务」时等待本轮回复结束；只有最终状态为 `complete` 才算完成。「任务是否已停止还无法确认」也不能当作已停止，需按状态提示重试核实。用户通常不必手动操作这些步骤。

独立检查发现问题时，通知按「问题、依据、建议处理」逐项展示；它是对原任务的检查反馈，不是新的用户要求。当前助手据此修正或提交反证，随后重新检查。

## Orbit 如何协作

| 角色 | 做什么 |
| --- | --- |
| 当前 OMP Agent（Root） | 对整项需求负责，写代码、决定是否分工、核验成员结果并交付 |
| 执行成员 | 由 Root 通过 OMP 原生 `task/hub` 派发；成员不能再派发成员或另起 Orbit 任务 |
| 独立检查者 | 在单独的只读 OMP 会话里检查实际产物，把具体问题送回 Root |
| Orbit | 保存任务要求与状态，观察执行和检查，并确认停止结果 |

你不需要预先建团队，也不需要为每个项目写 Orbit 专用规范。Root 可以自行完成任务；只有分工有实际收益时才派发成员。

Root 和执行成员使用 OMP 中可用的模型；检查者使用独立 OMP 会话。可选的 [Jev 调度](docs/reference/usage-reference.md#jev-配置)根据卡住、偏航和产物进展信号安排检查，并权衡端到端时间与粗档费用后给出分工建议。Root 决定是否派发；Jev 的概率不代替独立检查的结论。

**多模型选择（已实现并通过真实验收；池内自动正选择为 live 边界）：**你可以用会话内 `/orbit-models` 从当前 OMP 可选列表维护一个跨会话候选池。Orbit 只在候选池与当前会话可选列表的交集内比较：为执行成员给出模型建议，为独立检查者选模，按“质量先过线 → 端到端时间 → 粗档费用”排序，并记录实际使用的模型；不按品牌排序，也不引入精确 token／金额门槛。Root 始终显式派发成员，成员不能再派发成员或另起 Orbit 任务。完整链路（会话动态成员 Agent 定义与漂移核对、检查者失败后的显式重选）已实现，其中漂移核对与显式重选已有真实样本；池内自动（非显式）正选择仅由确定性测试覆盖——真实自动尝试因无候选通过质量线被正确拒绝，未取得 live 正样本。状态见 [ADR-009](docs/adr/009-user-selected-model-pool.md)、[交付 TODO](docs/plan/model-pool-delivery.md) 与[验收证据](docs/reference/model-pool-acceptance-20260925.md)。

#### 选择候选模型（`/orbit-models`）

在交互式 `orbit omp` 会话里输入 `/orbit-models`，直接输入文字按 `provider/id` 搜索；↑/↓ 移动，Space 勾选或取消，Enter 一次保存本次净变化，Esc 取消。当前会话不可选但已入池的旧标识仍保留在列表，可勾掉移出，不能新增。列表仅表示当前会话可选择，不保证模型已验证可调用或有额度。

无交互界面或需要脚本操作时，继续使用：

```text
/orbit-models add provider/id     # 加入当前会话可选列表中的模型
/orbit-models remove provider/id  # 从候选池移除
orbit model-candidates list       # 终端查看候选池
```

候选池跨会话保存，只保存模型标识，不保存凭据。批量保存会拒绝同一模型的并发冲突，不覆盖其他会话对不同模型的修改；出现冲突时刷新界面再选。池内但当前会话不可选的标识可移除但不会因此启用。候选池为空时，检查者沿用现有默认模型行为，也不给执行成员模型建议；池非空却没有合格检查模型时，Orbit 不擅自使用池外默认模型，需要你显式指定。

新候选模型缺少同标识的质量事实时，Orbit 不让 JEV 凭模型名称评分，也不会把未启动的请求当作受控任务。Root 可从一手来源查证后用 `orbit model-evidence --file FILE` 在建任务前写入缓存，再对原用户消息显式启动；若仍无合格检查模型，需显式指定。显式检查模型在建任务前先核对隔离检查者的模型目录与凭据，实际请求或额度仍可能失败。操作和证据格式见[进阶使用参考](docs/reference/usage-reference.md#模型证据提交model-evidence)。

## 日常命令

| 命令 | 用途 |
| --- | --- |
| `orbit omp` | 启动带 Orbit 扩展的 OMP 会话 |
| `orbit status [ID]` | 查看任务、成员、检查和下一步 |
| `orbit stop [ID]` | 请求停止任务；再用 `status` 确认结果 |
| `orbit export TASK --output FILE` | 本地导出单任务证据包，供你选择是否交给开发者分析 |
| `orbit doctor` | 检查安装、环境与可验证的会话连接 |
| `orbit update` | 更新这份安装；已有会话继续使用其启动时的版本 |
| `orbit uninstall` | 卸载这份安装 |

补充要求直接在原会话里说。需要从另一个 worktree 继续同一任务时，使用 `orbit rebind-workspace`；其他手动参数见[进阶使用参考](docs/reference/usage-reference.md)。

任务在运行中或结束后均可导出。包内是观察到的派发、模型、协作、检查与纠偏事实及证据缺口，不会调用模型复盘或自动上传；实际完成仍以 `orbit status` 的任务状态为准。导出包可能含任务原文、项目代码快照和会话内容，分享前请自行检查。

卸载前请结束使用该安装的任务和 OMP 会话。若仍有会话占用旧版本，卸载会拒绝并保留安装；卸载不会删除项目代码或 `.orbit` 任务记录。

## 常见问题

### 已打开的普通 `omp` 会话能直接接入吗？

不能。退出后用 `orbit omp --resume SESSION_ID` 恢复；扩展在会话启动时加载。

### Agent 没有启动 Orbit 任务？

明确说“这次请使用 Orbit”；若自动启动受候选检查模型或环境校验阻断，按提示选择检查模型后由 Agent 显式启动，不把失败当成受控。若会话里没有 Orbit 工具，先确认它由 `orbit omp` 启动，再运行 `orbit doctor` 检查安装和连接。

### `orbit status` 显示检查通过，任务就结束了吗？

还要看任务状态。检查结果与执行收尾是两件事；只有任务状态为 `complete` 才表示都已完成。`stop_unconfirmed` 表示已经尝试停止，但尚未确认相关执行全部退出。完整状态说明见[进阶使用参考](docs/reference/usage-reference.md)。

## 当前范围与文档

本仓源码版本为 **0.7.3**（由 0.7.2 升 patch，含两处 bugfix：OMP 会话内成功 `start` 后同回合刷新任务状态栏；JEV 摘要 UTF-8 截断导致的序列化失败）。`orbit omp`、原生执行成员与独立 OMP 检查者的端到端真实验收在 **0.7.1** 上取得：其前的 **0.6.18** 是历史验收安装，ADR-009 选模真实验收在临时隔离安装的 **0.7.0** release 上取得（见[候选模型池真实验收](docs/reference/model-pool-acceptance-20260925.md)）。0.7.1 的隔离真实任务中，第九个 `final_gate` 跑在中间构建上、第十个 `final2` 跑在最终 0.7.1 构建上，两者均 `complete` 并确认停止；完成硬门、显式暂停、原生 Esc 中断与检查纠偏收尾已有真实证据，`delegation_hint` 派发正样本留作后续独立目标（`parallel` 为 `root_without_hint`，不标通过）。**0.7.2** 的 Zeen UI 任务在启动后出现 JEV 序列化故障并确认暂停，未取得该版本的完整真实模型验收。**0.7.3** 的两处修复属源码与确定性验证（完整 `npm test`、打包与 diff check），不声称已通过真实模型验收。安装或更新到本版本用 `sh install.sh`，安装选项与维护见[进阶使用参考](docs/reference/usage-reference.md)。验收事实与保留边界见 [Orbit OMP 接入验收记录](docs/reference/orbit-omp-access-acceptance-20260925.md)，历史证据见[验收证据](docs/reference/omp-native-m4-acceptance-20260924.md)。

- [进阶使用参考](docs/reference/usage-reference.md)：安装选项、Jev、CLI 与维护。
- [任务运行合同](contracts/task-runtime.md)与[设计决定](docs/adr/008-omp-native-collaboration-base.md)：角色、检查和停止语义。
- [当前限制](docs/plan/debt-ledger.md)与[文档索引](docs/README.md)：已知边界和其他文档。
- [模型候选池交付 TODO](docs/plan/model-pool-delivery.md)：ADR-009 的实现进度与未验证项。

---
name: orbit
description: 当用户要求实现功能、修复问题、重构或按需求文档执行，且任务需要委派成员，或涉及多个步骤、模块、容易遗漏的验收要求时，主动使用 Orbit 做执行期间的独立检查与纠偏，无需用户点名 Orbit。用户明确要求 Orbit 时也使用。需要成员的执行任务先接入再委派；仅讨论、解释、只读评审或无协作的简单局部修改通常不启动；已有任务不重复启动。支持安装原生插件后的普通 OpenCode／OMP，以及通过 orbit codex 启动的 Codex。
metadata:
  short-description: 在已授权的复杂执行任务中主动开展独立检查与纠偏
---

# Orbit

Orbit 是独立的任务执行辅助工具，适用于任意项目。它保存用户原始要求，在执行期间定时检查实际产物，发现漏做、做错或多做时发回纠正，并核实最终结果或实际停止。只需要当前项目、已授权的执行要求和可接入的 Agent 会话；新项目不需要先建立额外业务流程或填写 Orbit 需求表。

**主执行 Agent（Root）就是当前接收用户要求、负责完成整项任务的 Coding Agent，通常就是正在读取本 skill 的你。** 这是职责名称，不要求用户另建角色或启动另一个会话。你继续实现、决定必要分工并响应纠正；Orbit 进程负责观察和投递，另外按需启动独立检查者，有真实争议时再启动裁定者。小团队不是前置条件，你可以独自实现。

## 自主判断调用时机

- 用户已经要求开始执行，且独立检查能帮助防止遗漏或跑偏时，主动启动。例如“按这份文档实现整个流程”“修复跨模块问题并验证”“重构这部分并保持现有行为”。用户不必说“启动 Orbit”，也不为已授权的常规调用再问一次许可。
- 用户明确要求使用 Orbit 时，按本流程接入。若既有授权未涵盖检查所需的模型资源，先说明具体缺口；不以调用 skill 为由启用新供应商。
- “这个方案怎么样”“解释这段代码”“先 review，不实现”只讨论或评审，不启动执行进程。拼写修正等可以直接完成并核对的小任务通常不用；不要为了使用工具扩大任务。
- 已有 Orbit 任务时复用其任务目录。若你只是另一位 Agent 委派的执行者，不为同一项主任务再启动 Orbit；Orbit 的纠正消息也不是一项新的用户需求。

## 接入与执行

需要执行成员时，即使代码量小，也先接入 Orbit，再用 `delegate`；否则成员结果与统一停止无法纳入同一任务。

使用当前宿主提供的 `orbit` 工具（Codex 为 MCP，OpenCode／OMP 为原生扩展）；它提供 `context / start / status / check / amend / dispute / stop / delegate`。OMP 将扩展工具挂载到 `xd://orbit` 时，先用原生 `read` 读取该设备的说明与 JSON schema，再按原生设备协议写入参数调用，这与独立命名的工具是同一入口。普通 Codex 工作区沙箱中的 shell 不一定能访问控制 socket，不能用反复执行 shell 命令替代可用 MCP。

1. 读取目标项目已有规则，确定用户原始要求。调用 `orbit` 工具的 `context` 检查当前会话，OpenCode／OMP 自动提供当前项目与会话，无需端口和 ID；Codex 宿主通常提供会话身份，确实缺少时从环境读取 `CODEX_THREAD_ID`，传入 `thread_id`，不要让用户查内部 ID。
2. 用 `start`；Codex 传 `project` 绝对路径，OpenCode／OMP 自动取当前项目；用户指定文档时传 `basis` 路径数组。不传 `message_id` 时读取最近原生用户消息；若最新只是“同意”，传实际包含执行要求的原始消息 ID。不要把自己的计划或摘要冒充用户原文。
3. 检查模型优先使用已配置的 `ORBIT_REVIEW_MODEL`，否则 Codex 沿用当前会话配置，OpenCode／OMP 读取本机 Codex config.toml 的顶层模型；有明确角色配置时传 `review_model`。需要选型再读 [模型建议](references/model-selection.md)。不启用未经授权的新供应商。
4. 保存返回的 `task_directory`，在下一正常工作节点用 `status` 和 `task` 核对实际接入，然后继续实现。`starting` 表示进程已创建；`queued` 表示动作已入队，均不代表完成。已有本任务时复用，不重复启动。

OpenCode 用户直接运行 **`opencode`**，OMP 用户直接运行 **`omp`**，继续使用原生模型、恢复与权限参数；插件在下次启动时加载，skill 不能在当前会话内另开 Root。工具不可见时说明插件尚未加载，保留当前上下文，用户可按原生方式恢复会话。

Codex 没有 MCP 时，可在具有原生控制端点和相应访问权限的宿主中使用 CLI：`orbit start --project DIR --basis FILE`。`ORBIT_CODEX_SOCKET` 指向当前会话所属服务；不要猜测其他服务或迁移会话。`orbit doctor` 检查连接，`orbit --help` 提供 CLI 参数。

接入失败只核对具体缺口，不循环重试。普通终端、tmux、Herdr 都可由用户通过 **`orbit codex`** 打开可接入的 Codex；这是日常启动入口，skill 不能在当前会话内部再调用它来替换自己。已经打开的普通嵌入式 Codex 尚无已验证的热接入；说明情况，保留当前上下文。用户可在停止当前工作后明确使用 `orbit codex resume SESSION_ID` 恢复该会话。一般授权工作可以继续，但不得声称已受 Orbit 检查；用户要求必须受控时先解决接入缺口。

## 必要分工

Root 在用户授权和项目规则范围内决定是否需要执行成员，一个 Agent 足够就自己完成。需要时使用 `delegate`，传 `task` 和具体 `text`（范围、文件边界、验证和回报要求）；程序自动附上原始要求与已生效修改，创建本任务拥有的同宿主成员（Codex、OpenCode 或 OMP），结果自动回到当前 Root。`model` 可指定已授权模型，否则 Codex 成员沿用检查模型，OpenCode 成员沿用 Root 的原生供应商、模型和 variant；OMP 成员沿用 Root 的模型、thinking、项目与权限设置，只开放当前已启用的基础编码工具（read/write/edit/grep/glob/bash/python/lsp），不复制扩展、MCP 或委派工具；`member` 可复用本任务已有成员。Root 核验并集成结果，成员不再创建团队。OMP 的 `hub wait` 不等待 Orbit 回报；不要用它或 shell 等待成员。结束本轮后，Orbit 会把结果送回当前会话。

这条路径不需要额外终端窗口。Herdr、tmux 只影响展示；用户明确要求使用其他协作工具时按 [协作说明](references/agent-collaboration.md) 处理，不把外部成员说成已纳入 Orbit 的统一停止。

## 纠偏与收尾

工具的任务操作都传 `task`：`check` 请求独立核对；`dispute` 的 `text` 提供真实反证；`amend` 的 `text` 只传用户明确补充的原文；`stop` 停止整项受控任务。正常用户消息由程序观察并同步给活动成员，不需要重复手动 `amend`。

收到检查纠正后对照原始要求修复；有真实争议才申请裁定。程序按事件和约定时间检查，无需 Root 持续轮询。首次间隔可用 `check_in` 设置，之后由检查者约定下次；预估与硬截止的 CLI 参数见 `orbit --help`，不自行把估计变成硬限制。

产物准备好后结束本轮并说明实际结果，让独立检查核对最终版本。不要在活跃轮次内持续等 `complete`。检查若发现遗漏，会唤起同一个 Root 继续修正；最终状态保存于任务记录，可通过 `status` 查询，不能把 Root 自己的完成声明当作独立验收通过。

原生界面中断 Root 或调用 `stop` 后，程序停止 Root、本任务登记成员及各自宿主管理的命令（OpenCode 包括原生 shell 工具所附属的进程树；OMP 包括本会话拥有的原生后台任务，等待实际执行结束后才确认停止），保留会话和产物。确认失败须报告 `stop_unconfirmed`；任务进程报错退出后，仍可用 `stop` 显式重试收尾。禁止将本任务工作放入脱离宿主管理的后台进程；外部未登记 Agent 不在确认范围。关闭 `orbit codex` 入口或正常退出 OpenCode／OMP 会收尾本次宿主的相关执行；不承诺强杀宿主后的自动恢复。

## 按需规则

启动本次任务时读取 [最小实现](assets/rule-library/tasks/minimal-implementation.md) 和 [共用职责](assets/rule-library/shared/escalation-payload.md)。修复、测试、对外命名、结构化边界、安装／命令表面、质量与评审，按实际动作读取 `assets/rule-library/tasks/` 中对应文件。项目规则对执行者和检查者同样适用，不将 Orbit 规则复制成项目必填配置。

CLI 和原生连接扩展由 `install.sh` 管理，skill 的安装、更新与移除交给 `npx skills`，两者分别维护；`orbit version --json` 只查询运行程序来源。更新或卸载在 Orbit 任务结束后进行。运行需要 Ruby 3.2+、Node.js 18+、npm 与已有 Codex CLI，安装后可直接运行 `opencode`／`omp` 或用 `orbit codex` 打开支持接入的会话；OpenCode／OMP 的检查者当前仍需要 Codex，不能将其 provider/model 填作检查模型；安装不会改造已经打开的会话。

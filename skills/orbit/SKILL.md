---
name: orbit
description: 当用户要求实现功能、修复问题、重构或按需求文档执行，且任务涉及多个步骤、模块、协作者或容易遗漏的验收要求时，主动使用 Orbit 做执行期间的独立检查与纠偏，无需用户点名 Orbit。用户明确要求 Orbit 时也使用。仅讨论、解释、只读评审或简单局部修改通常不启动；已有任务不重复启动。当前执行接入支持具备原生控制接口的 Codex 会话。
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

## 接入前确认

1. 确定目标项目和用户原始执行要求。项目已有规范按作用域读取；没有规范文件不妨碍接入，不要求创建模板。指定需求文档用 `--basis` 传入。
2. 确认本机可用的 `orbit --version`、现有会话和已授权的检查模型。复用 `ORBIT_REVIEW_MODEL`；没有设置时，用已有授权中可供 `codex exec` 调用的模型填 `--review-model`，需要选型才读 [模型建议](references/model-selection.md)。
3. 当前适配仅支持已加载在 Codex Unix app-server 上、可读取历史的已有会话。默认会话来自 `CODEX_THREAD_ID`，默认 socket 是 `${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server-control.sock`；指定其他 socket 必须确实承载当前会话。

接入失败时结束这次接入尝试，并说明缺少的命令、模型配置或控制能力。不得伪称 Orbit 已运行，不新建／恢复会话或启动 daemon 来代替原会话，也不反复重试同一缺口。一般已授权工作可继续，但应明确它未受 Orbit 检查；若用户明确要求必须在 Orbit 控制下执行，则先处理该缺口。

## 启动一次任务

在目标项目中调用；从其他目录发起时补 `--project DIR`：

```bash
# 已配置 ORBIT_REVIEW_MODEL；原生最新用户消息本身包含本次执行要求
orbit start --basis path/to/requirements.md

# 指定包含实际要求的原始消息，而不是随后单独一句“同意”
orbit start --message-id MESSAGE_ID --review-model MODEL --basis path/to/requirements.md
```

没有指定依据文档就省略 `--basis`，多个文档可重复传入。不指定 `--message-id` 时程序读取最近一条原生用户消息；使用用户提供的 prompt 文件时可改用 `--prompt-file FILE`，程序会把该原文投递给当前主执行 Agent。不要把自己的计划或摘要冒充用户原文，不收集整段需求讨论。

启动成功后保存返回的 `task_directory`，继续原任务。检查按事件和约定时间发生，不需要你反复申请。`--check-in SECONDS` 设置首次约定观察间隔，之后由检查结果安排下一次；`--estimate-minutes` / `--estimate-tokens` 只作预估，只有用户明确给出的 `--deadline` 才是硬停止时间。

默认在后台运行本次任务进程。Agent 自行调用时使用该默认方式；`--foreground` 会占住调用直到任务结束，仅在另有执行终端的显式安排中使用。不要用阻塞调用让主执行会话无法继续工作。

## 执行与收尾

记录在 `PROJECT/.orbit/tasks/<id>`；按需查询或控制：

```bash
orbit status TASK_DIRECTORY
orbit check TASK_DIRECTORY
orbit amend TASK_DIRECTORY --file FILE
orbit dispute TASK_DIRECTORY --reason "争议点与具体依据"
orbit stop TASK_DIRECTORY --reason "停止原因"
```

命令返回 `queued` 只说明已入队，不等于动作已完成。收到纠正时对照原始要求修正；有真实反证再申请独立裁定，工程偏好不阻断交付。`amend` 仅传用户明确修改的原文，不能用来扩大自己的授权。

准备好交付后结束当前执行轮次，让 Orbit 检查最终产物；不要在同一轮持续等待 `complete` 而保持会话活跃。根据实际状态区分完成、暂停、需要用户、失败和停止未确认。停止确认覆盖当前主执行会话与原生登记的后台命令，不把未接入成员或脱管进程说成已停止。

## 按需规则

启动本次任务时读取 [最小实现](assets/rule-library/tasks/minimal-implementation.md) 和 [共用职责](assets/rule-library/shared/escalation-payload.md)。修复、测试、对外命名、结构化边界、安装／命令表面、质量与评审，按实际动作读取 `assets/rule-library/tasks/` 中对应文件。项目规则对执行者和检查者同样适用，不将 Orbit 规则复制成项目必填配置。

安装器让 CLI 和 skill 使用同一版本；`orbit version --json` 查询来源。更新或卸载在 Orbit 任务结束后进行。运行需要 Ruby 3.2+、Node.js 18+、npm 与已有 Codex CLI，安装不会自动给会话增加控制端点。

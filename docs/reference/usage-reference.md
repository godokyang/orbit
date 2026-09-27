# Orbit 进阶使用参考

首次安装和日常使用见 [README](../../README.md)。本文用于自定义安装、维护、手动 CLI 操作和其他工具集成。

## 安装选项

### 自定义目录

在本地 Orbit 仓库执行 `sh install.sh` 时安装当前源码；远程安装命令通过 `--ref` 选择源码。入口目录与运行程序目录必须分开。

| 参数 | 默认值／环境变量 | 说明 |
| --- | --- | --- |
| `--runtime-dir DIR` | `ORBIT_RUNTIME_DIR`，否则 `$XDG_DATA_HOME/orbit/orbit`，未设置 XDG 时为 `~/.local/share/orbit/orbit` | 保存版本和安装记录 |
| `--bin-dir DIR` | `ORBIT_INSTALL_DIR`，否则 `~/.local/bin` | `orbit` 命令所在目录，需在 PATH 中 |
| `--no-modify-path` | 默认自动配置 | 不修改 shell 配置；选择随安装记录保存，`--modify-path` 可重新开启 |
| `--ref REF` | 远程安装默认 `main`；也可用 `ORBIT_REF` | 从 GitHub 获取分支、标签或完整提交 SHA |

安装器只安装 Orbit 程序与 `orbit omp` 受控入口，不再向 OMP 目录写入全局扩展；普通 `omp` 不会获得 Orbit。

更新沿用安装记录中的目录；改变目录时先卸载再安装。环境变量和显式目录也要与原安装保持一致。

已有未知命令包装、同名自定义扩展或无归属的安装目录时，安装器拒绝覆盖。先确认原入口由谁管理，通过对应工具卸载，或改用独立目录；不要直接覆盖自定义资料。

### Jev 配置

运行 `orbit jev setup`，按提示输入 TypeSafe key 并回车。命令不回显 key，将它写入 `${XDG_CONFIG_HOME:-$HOME/.config}/typesafe-ai/env`（权限 `0600`），并在 zsh／bash 启动文件中追加加载该文件的语句；重复运行可替换旧 key。重新打开终端，再从该终端启动 `orbit omp`。Orbit 运行时只读取启动进程的 `TYPESAFE_API_KEY`，不读取 Orbit 配置文件；当前终端和已有任务不会自动改变。

原有的 `TYPESAFE_API_KEY` 环境变量继续可用，存在时优先于环境文件。新任务发生 Jev 判断后，`orbit status --json` 的 `jev.provider`、`jev.model`、`jev.question_set_version`、`jev.scores` 和 `jev.usage` 记录该次判断的来源、版本、概率及可得用量；`jev.unavailable` 表示服务调用失败。任务内既有问题使用 `jev-latest`，入口自动判定固定 `jev-1.13.0`，不是把任务内派发概率当作启动概率。需要对某个项目关闭外发时，在项目根目录创建 `.orbit/jev-disabled`；没有 key、服务不可用或禁用外发时，入口不自动启动，交 Root 显式决定。移除标记后，新请求才恢复使用 Jev。不要把环境文件放进项目或提交到 Git。

入口判定以 OMP 原生用户消息 ID 去重；明确要求 Orbit 受控执行会尝试启动任务，明确讨论／只读问答不启动。其余请求仅在执行授权概率 ≥ 0.80 且独立检查收益概率 ≥ 0.80 时自动启动；当前门槛来自六条实际标注请求，其中短版本任务的收益 0.74／0.72 曾误入旧阈值，不保证所有表达方式都能自动识别。项目可在 `.orbit/jev-entry.json` 指定已校准的入口阈值；切换 provider／模型必须重新校准，不能因判断失败静默回退。`orbit status --json` 的 `entry` 保留判定来源；入口自动启动不等于自动派发成员。**显式受控启动失败保持失败关闭，不得改成普通执行；仅非显式的自动候选失败时可告知用户本次不受 Orbit 监督并继续普通请求。**

Root 可在无活动 Orbit 任务时使用 OMP 原生 `task`：不建立 Orbit 成员记录、独立检查或停止确认；会话给出未受控提示。已有活动任务仍受成员登记门约束，非所属任务、未知调用者和成员二次派发不得借此绕过。Root 的执行模型由 `orbit omp --model provider/id` 原生选择，Orbit 不在小任务中暗换模型。

### PATH 配置

安装成功后，脚本根据 `$SHELL` 自动配置当前安装的 bin 目录（包括自定义 `--bin-dir`）：

- zsh：追加到 `~/.zshrc`；已导出 `ZDOTDIR` 时使用该目录的 `.zshrc`。
- bash：追加到 `~/.bashrc`，以及已有的第一个登录配置：`.bash_profile`、`.bash_login`、`.profile`；都不存在时使用 `~/.profile`。

保留原有内容、文件链接和权限；重复安装不重复追加，重复加载也不会把目录重复放入 PATH。启动文件规则见 [zsh 官方说明](https://zsh.sourceforge.io/Doc/Release/Files.html)与 [Bash 官方说明](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html)。

安装脚本无法改变父终端的环境。完成后重新打开终端，或复制安装输出中的 `export PATH=...` 命令让当前终端立即生效。使用其他 shell、特殊启动配置或配置文件无法写入时，按提示将实际 bin 目录加入对应配置；仍可通过输出中的完整命令路径使用 Orbit。

不希望脚本修改配置时：

```bash
curl -fsSL https://raw.githubusercontent.com/godokyang/orbit/main/install.sh | sh -s -- --no-modify-path
```

此选择在 `orbit update` 和重复安装时保留。以后重新执行安装命令并传入 `--modify-path` 可开启；关闭自动配置不会删除已保存的 PATH 内容。卸载同样保留共享 bin 目录的 PATH 设置，避免影响该目录中的其他命令。

### OMP profile

`orbit omp` 沿用 OMP 原生的 profile 机制：例如 `orbit omp --profile work` 使用 `work` profile 的 OMP 配置与会话存储。Orbit 安装本身不再写入 OMP 的 agent/profile 目录；安装目录由安装器的 `--runtime-dir`／`--bin-dir` 管理，与 OMP profile 无关。

### 更新和卸载的行为

`orbit update` 读取当前安装记录，沿用原目录；远程来源沿用原 ref，本地来源沿用保存的源码目录。显式 `--ref REF` 可改用远程来源；本地源码目录不存在时给出重新安装或显式改用远程的提示。

远程安装先把 ref 解析成一个 SHA，再下载该提交的完整源码。更新先准备依赖并验证新版，通过后才切换 `current`，CLI 与原生连接扩展一起切换。准备失败保留旧版，成功后清理旧版登记文件。

新版本持有 lease 的运行任务与已加载宿主不会因更新而失去旧 release；持有者退出后的下一次安装会清理旧 release。这不是正在运行任务的热更新。卸载前须结束使用该安装的任务和宿主；若仍有存活 lease，卸载会在移除任何入口或安装记录前拒绝。首次从未登记 lease 的旧版升级前仍需结束旧任务和会话。同一安装目录一次只运行一个安装器。

卸载读取安装记录，只移除仍匹配的入口和已登记文件。用户额外文件、项目代码和项目 `.orbit` 资料保留。自定义安装的命令为：

```bash
orbit uninstall
```

## 手动 CLI 操作

日常由 Agent 通过受控 OMP 会话（`orbit omp`）中的 Orbit 工具完成调用，不需要用户填写内部 ID。下面的 CLI 用于该受控会话所在任务的管理、诊断或集成，不能直接接管任意普通会话。

### 日常查询与诊断

`orbit status [TASK]`、`orbit stop [TASK]` 从当前目录向上寻找最近的 `.orbit` 项目，到独立 Git 项目边界停止。TASK 可为目录或当前项目唯一 ID 前缀。省略时优先待处理记录（包括 failed / stop_unconfirmed）；多个候选列出供选择，停止不猜测。仅 status 在无待处理记录时显示最近结束的一项。

status 默认输出可读文本；`--json` 返回单项原始 state，多个／没有候选时返回 `{ "tasks": [...] }`。stop 默认说明入队和后续查询方式，`--json` 返回机器结果，供扩展桥与自动化集成使用。

`orbit export TASK --output FILE` 在用户指定的位置生成单任务本地证据包（可在运行中或结束后执行）；TASK 为任务目录或当前项目唯一 ID 前缀。包内包括按时间排列的事实记录、成员与检查证据、可安全归属的原生会话材料以及无法取得的证据清单；运行中包仅代表导出时刻。不会上传、调用模型或改变任务状态；请检查包内任务指令、项目快照和会话内容后再自愿分享。`orbit status` 和现有终检仍是任务完成的权威依据，复盘文件不作缺陷判定。

`orbit session-summary --thread NATIVE_OMP_SESSION_ID [--project DIR]` 只读汇总同一项目、同一原生会话的 Orbit 任务，输出 JSON：任务数、检查／过期／失败／手动次数、Jev 调用、finding、成员及可得的 token。旧任务缺失原生协作日志或事件时列出缺失，相关数值可能为 `null`；Root 用量和总金额无可归属证据时保持 `null`，不推算订阅费用。不会发起检查、创建任务或跨项目扫描。

`orbit doctor [TASK] [--json]` 不调用模型，不修改安装。依赖、扩展安装、连接和模型配置分别报告；`connection.ready: null` 表示没有可验证的会话，`false` 表示验证失败。只有环境通过且真实连接成功才有顶层 `ready: true`，并不代表模型登录或额度可用。无连接上下文时纯环境检查通过可返回退出码 0；发现环境、安装或连接错误返回 2。多个任务不自动选择连接，传 TASK 或在目标会话调用原生工具。

默认 `orbit --help` 展示日常入口；`orbit start --help` 等子命令展示执行参数。

### 受控入口与恢复

`orbit omp [OMP 原生参数]` 是唯一受控入口：入口为本次 Root 会话显式加载 Orbit 扩展，模型、profile、`--resume`、权限等原生参数与退出码透传。普通 `omp` 不是受控入口；安装切换状态见[当前限制](../plan/debt-ledger.md)。恢复会话：`orbit omp --resume SESSION_ID`。

### 接入已有会话

OMP 下由 `orbit omp` 启动的会话自动具备 Orbit 扩展；Agent 经原生 Orbit 工具（`xd://orbit`）调用，用 `context` 核对当前会话绑定，不让用户猜测端口或会话 ID。历史 Codex／OpenCode 的 socket／线程接入方式已随旧宿主退役。

在已具备 OMP 受控会话的环境中，也可以经 CLI 显式启动任务：

```bash
# 选取最近一条原生用户消息，指定检查模型（OMP 可用模型的 provider/id）
orbit start --review-model provider/id --check-in 300 --estimate-minutes 90

# 指定原生用户消息，并保存其明确引用的依据文件
orbit start --review-model provider/id --message-id MESSAGE_ID --basis path/to/spec.md

# 使用明确的原始指令文件
orbit start --review-model provider/id --prompt-file ./instruction.txt --estimate-tokens 200000
```

占位符应换成实际值。`--thread`、`--project` 可显式提供；项目默认当前目录，`--basis` 可以重复。不应把 Agent 自己整理的计划冒充用户原文。命令面以安装版本的 `orbit --help` 为准。

`start` 默认创建任务进程并返回 `task_directory`、pid 和 `starting`。`--foreground` 将任务进程留在当前终端，直到任务结束。两者都要通过实际状态确认接入。

### 检查、补充、争议和停止

```bash
orbit status TASK_DIRECTORY --json
orbit check TASK_DIRECTORY
orbit amend TASK_DIRECTORY --file amendment.txt
orbit dispute TASK_DIRECTORY --reason "具体争议与反证"
orbit stop TASK_DIRECTORY --reason "停止原因" --json
```

`check` 请求一次独立检查；`amend` 只提交用户补充要求的原文；`dispute` 提交真实反证。任务内分工由 Root 在会话内经原生 `task` 派发（Orbit 在成员模型工作前完成登记）；`orbit delegate` 命令面以安装版本 `--help` 为准。结果由 Root 核验并集成。

这些控制操作返回 `queued` 表示入队，不能据此判断已完成或已停止。原会话中的新用户消息不自动修订正在运行的旧任务；确认属于旧任务时由 Root 显式 `amend`，新问题按独立请求处理。

最终检查同时给出 `delivery.ready` 与具体理由，和 finding／`verdict` 分开：`continue` 且零问题不表示实际答复已经送出。Root 在实际验证后调用 Orbit `action=check, task=<任务目录>`，在本轮回复中交付可核验结果并结束；手动终检若在回复过程中入队，等该轮交付完成才开始。自动检查即使判定 `complete` 也不会发完成通知，不能只等待自动检查唤醒。纯文字结果须先在 Root 已完成的回复中可见，修订文件后旧通知失效；推送要求另以只读、限时的 Git 远端引用对比当前 HEAD，远端不可达或目标不明确时记未验证，不接受 Root 自报。状态区分等待检查、当前版本可申请完成、完成申请已入队、通知失效、停止确认中；只有在本会话 Orbit 工具中显式 `stop(intent=complete)` 且最终停止确认后才能记 `complete`，普通 CLI `orbit stop` 始终只是暂停。

### 候选模型池与检查者重选（ADR-009）

在交互式 `orbit omp` 会话输入 `/orbit-models` 打开搜索多选：直接输入文字过滤 `provider/id`，↑/↓ 移动，Space 勾选，Enter 一次保存净变化，Esc 取消。当前不可选但已入池的旧标识可移出，不能新增。列表逐项展示当前会话可选性与精确身份的证据状态（缺失、过期、不可用或有效）；**质量未判断、隔离检查者未探测**不代表已验证质量、认证或额度，也不等于池内模型不能被实际启动探针选择。无 UI 时文字列表仍给出诊断；`orbit model-status --project DIR` 只读池和用户级证据缓存，不发起 JEV 或模型探测。提交前若可选列表变化或同一 ID 被另一会话修改，界面提示刷新，不覆盖对方的修改。逐项命令和脚本入口保留：

```text
/orbit-models add provider/id     # 只能加入当前会话可选列表中的模型
/orbit-models remove provider/id  # 可移除池内但当前不可选的旧标识
orbit model-candidates list       # 命令行查看；add/remove 可用于脚本
orbit model-status --project DIR  # 只读精确身份的证据诊断；无会话时可选性未知
```

候选池保存在用户级配置，跨会话共用，只保存型号，不保存凭据。它是**优先范围，不是授权名单**：Orbit 先从池与当前 OMP 会话可用目录的交集中预检隔离检查者；池中无可运行型号或池空时，从 OMP 当前会话可用型号中继续筛选，Root 也可显式指定当前会话可用型号。通用原生 `task` 派发使用 OMP 解析的准确型号，无须模型入池或用户逐型号授权；成员实际型号漂移仍被拒绝。Jev 的执行成员收益判断只给建议，Root 决定是否派发。

检查者选型保留 Jev 当前任务适配判断：有精确有效事实的可运行候选进入评分，正向信号优先，再比较端到端时间、粗档费用、家族和候选顺序；全低分选最高分，无评分按顺序降级，标记“检查质量未经证实”。OMP 会话可选与本地预检仅说明可尝试，不等于真实模型请求成功或检查通过；Root 指定的模型仍须属于当前 OMP 目录并通过隔离预检，也保留 Jev 判断结果。成功任务的 `review.selection` 记录选择来源、实际输入、逐型号分数、未评分身份和降级原因。

精确身份资料缺失／过期时，`start.evidence_needed` 请求 Root 在有一手来源时用 `orbit model-evidence --file -` 补证；查不到如实记 `status=unavailable`。证据不是可运行型号的启动硬门，不借近似型号编造。新有效证据在下一次检查前重新评分，不中断在途检查。无可运行型号时，项目本地 `.orbit/checker-selection-failures.jsonl` 留存实际探针与判断；无法建任务应告知 Root 具体失败，而非要求用户发送型号授权行。

独立检查者沿用 OMP 模型配置与凭据解析，仍在独立只读会话中读取固定快照。认证、额度或结果校验失败会留下失败检查记录，Orbit 在**检查结束后**从尚未尝试的可运行型号中按池优先和 Jev 次序有界重试；所有型号失败才阻塞，不把失败当终检。Root 修复环境后可从 OMP 当前可用型号中重选：

```bash
orbit review-model TASK_DIRECTORY --model provider/id --reason "检查者凭据恢复"
```

该命令入队前核对当前 OMP 会话与隔离环境，任务进程在真正开始检查前再核对；在途检查不会切换。同一失败型号不能靠重复 `check` 绕过阻塞。Root 使用 Orbit 工具 `start` 的 `review_model` 参数也只接受经上述可用性核对的 OMP 型号。没有有效独立终检时，不称任务已完成；需要中断则按用户指令普通暂停并确认停止。

### 模型证据提交（model-evidence）

Root 从一手来源检索模型事实，提交一个 JSON object 或 array。执行成员的任务内请求使用 `orbit model-evidence TASK_DIRECTORY --file FILE|-`，`provider`/`model`/`reasoning` 与请求身份完全一致；检查者缺证据按 `start.evidence_needed` 中精确的 `provider/id` 拆为 `provider` 和 `model`，`reasoning` 未知可省略，优先不传任务目录，也可携当前任务目录提交匹配的检查者事实。建任务前按候选池中准确的 `provider/model` 身份填写。不写网页正文或凭据，不伪造来源或指标。

还未创建任务时，用同一格式直接写入用户级缓存，不需要虚构 `TASK_DIRECTORY`：

```bash
orbit model-evidence --file ./model-facts.json
```

无任务目录模式仅校验并缓存，不创建任务、不入队任务命令；携带当前任务目录时，匹配检查者缺口的提交记录为检查者补证，下一次检查前重评，执行成员的请求仍按原有身份门处理。显式 `start --review-model provider/id` 在创建任务前检查该模型是否能在隔离检查者的目录和凭据中解析；探测不发送模型请求，不能保证额度或实际检查结果。

占位结构（尖括号处替换为真实结果；`valid_until` 可省略，不得超过该模型标识的有效期）：

```json
[{"provider":"<候选的 provider>","model":"<候选的 model>","reasoning":"<实际 reasoning>",
  "status":"evidence","retrieved_at":"<ISO8601，含时区>",
  "valid_until":"<ISO8601>",
  "sources":["https://<真实来源 URL>"],
  "metrics":{"<指标名>":{"value":0,"unit":"<单位>","basis":"<测量口径与样本说明>"}}}]
```

约束：`sources` 为 1–5 个绝对 http(s) URL（不带凭据）；`metrics` 为命名对象，每项 `value` 为有限数字、`unit` 与 `basis` 为文本；`retrieved_at` 不能是未来时间。`metrics` 只写该模型自身的测量事实，不写比较或身份断言：`comparison.*` 这类跨身份指标会被拒绝；既有缓存中的此类指标也不会进入二阶段摘要（摘要 note 只声明结构校验、指标由提交者提供）。无法取得证据时提交 `status: "unavailable"` 并给出 `reason`，不得编造证据：

```json
[{"provider":"…","model":"…","reasoning":"…","status":"unavailable","retrieved_at":"…","reason":"<为什么无法取得>"}]
```

Orbit 校验后原子写入用户级缓存；仅带任务目录时还通知该任务进程重查。缓存按模型标识的有效期使用，过期后重新检索。具体字段限制以 `orbit model-evidence --help` 与校验错误为准。

### 时间和用量

| 参数 | 含义 |
| --- | --- |
| `--check-in SECONDS` | 首次观察间隔，后续由检查者约定下一次时间；等待不调用模型 |
| `--estimate-minutes N` | 耗时预估，用于事后对比 |
| `--estimate-tokens N` | token 预估，用于事后对比，不是硬上限 |
| `--deadline ISO8601` | 用户明确指定的硬截止，例如带时区的日期时间 |

只有明确设置的截止时间才会形成硬停止线。任务总费用拿不到时记录未知；不能把原会话累计消耗当成本任务消耗。

`status` 将可得 tokens 分列为入口 Jev、检查模型选择 Jev、任务内 Jev 第一／二阶段、各角色独立检查；缺测标为未知。Root 会话累计量不能归属本任务，不并入任务 tokens。纯计时不会让执行中的 Root 重复支付 Jev 或完整检查；任务状态、产物、成员或输入发生可辨认变化时仍按合同检查。

## 被其他工具调用

反馈处理、任务管理或自动化工具可以在获得执行授权后调用同一个 `orbit start`，提供项目、已接入的 Agent 会话、原始指令和依据。保存返回的任务目录，再通过 `orbit status` 或任务事件读取结果。

调用方管理自己的业务状态，Orbit 独立运行至完成或停止。执行不依赖调用方的前置／后置业务流程。

## 开发与版本维护

在本仓运行：

```bash
npm ci
./scripts/orbit --help
npm test
```

版本号以 `package.json` 为准，`orbit version --json` 显示版本、来源提交、内容摘要和安装时间。本地安装的 `commit` 是工作树基线，`dirty` 表示安装时有本地改动；非 Git 来源记为未知。

按 [版本号管理规则](../../AGENTS.md#版本号管理)，需要升版时默认只将最后一位加一，例如 `0.6.0 → 0.6.1`；前两位由用户决定，只有明确指定后才调整。

```bash
npm version patch --no-git-tag-version
```

该命令同步包和锁文件，之后进行相应验证。仅在用户明确指定版本时使用 `npm version <指定版本> --no-git-tag-version`。不是每次文档修改或提交都需要升版。包内容用 `npm pack --dry-run` 核对；发布包、打标签与提交推送分别取得相应授权，安装器不会自动执行这些操作。

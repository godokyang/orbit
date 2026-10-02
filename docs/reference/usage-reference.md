# Orbit 进阶使用参考

首次安装和日常使用见 [README](../../README.md)。本文用于自定义安装、维护、手动 CLI 操作和其他工具集成。本文按当前源码说明入口、选型与工作单元。源码版本从 `package.json` 读取，安装事实以 `orbit version --json` 为准；生效限制见[当前限制](../plan/debt-ledger.md)。

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

入口判定以 OMP 原生用户消息 ID 去重。入口判定（已交付）：明确要求 Orbit 受控执行会尝试启动，引用或代码例子里的命令不直接启动；明确拒绝、讨论及概念问答不启动。实质串行交接和有交付要求的只读审计也可提供启动价值。`orbit-entry-3` 分别问执行授权、交接和监督，按「授权且（交接或监督）」组合；门值来自同问题内容、输入、决策版本及实际模型的真实校准放行，不沿用旧 0.80／0.80。当前源码内置固定实际 `jev-1.13.0` 的有限入口放行（执行授权 0.85、交接／监督各 0.65），八个真实干净 Git 输入样本及独立复核支持；决策版本为 `orbit-entry-decision-2`。非 Git／截断 uncertain 请求不支付判断，Root 可按原始要求自主决定；领域外效果未证明，也没有要求用户手工派发。开发者放行文件（可选项目 `.orbit/jev-entry.json`）需保留真实标注样本、回执与复核理由，不能只填样本数或修改阈值。没有活动任务的裸「继续」要先找可追溯原要求，活动任务按绑定继续。`orbit status --json` 的 `entry` 保留来源；入口自动启动、Jev 推荐与实际派发分别记录。**显式受控启动失败保持失败关闭，不得改成普通执行；仅非显式的自动候选失败时可告知用户本次不受 Orbit 监督并继续普通请求。**

Root 可在无活动 Orbit 任务时使用 OMP 原生 `task`：不建立 Orbit 成员记录、独立检查或停止确认；会话给出未受控提示。已有活动任务仍受成员登记门约束，非所属任务、未知调用者和成员二次派发不得借此绕过。Root 的执行模型由 `orbit omp --model provider/id` 原生选择，Orbit 不在小任务中暗换模型。

### OpenRouter 模型概述（自愿启用）

安装不询问 OpenRouter key；需要成员或独立检查者在缺精确事实时参考有来源的模型级质量基准，可运行 `orbit openrouter setup`，在**不回显**的交互提示中输入 key。先验按任务点名的相关指标（coding／agentic／intelligence）给出，只在该型号有已核实映射、且快照在该指标上有非空数值时成立；可用候选数随候选池与映射／快照数据变化，不固定写死；快照抓取日期不是基准测量日期。命令只写当前用户私有环境文件 `${XDG_CONFIG_HOME:-$HOME/.config}/openrouter/env`（权限 `0600`）并让新 zsh／bash 终端加载；启动进程已有 `OPENROUTER_API_KEY` 时优先，当前终端或已运行的 Orbit 任务不会自动获取新 key。setup 不验证鉴权。不要把 key 置于命令参数、项目文件或 Git；不借用 `TYPESAFE_API_KEY`、`OPENCODE_API_KEY` 等其他凭据。

新终端启动 `orbit omp` 后，若项目没有 `.orbit/jev-disabled` 且存在 `OPENROUTER_API_KEY`，选模准备阶段可请求 OpenRouter 官方 `/api/v1/models` 元数据和 `/api/v1/benchmarks?source=artificial-analysis` 基准；只发送认证头及来源筛选，不发送任务描述、代码或对话。私有用户级成功快照在 72 小时内复用，两来源均成功才发布新快照；断网、认证失败、限流或无新基准不会阻止检查者降级路径。项目禁用或去掉环境变量后不联网，旧快照也不再提供先验。`orbit model-status --project DIR` 是**只读**诊断，显示是否启用、最近抓取结果与逐候选状态，不借此刷新或探测模型。

Orbit 随版本发布 `provider/model/reasoning/billing_route` → OpenRouter 目录 `id` 与 `canonical_slug` 成对映射，用户可在 `${XDG_CONFIG_HOME:-$HOME/.config}/orbit/openrouter-model-map.json` 显式提供经来源核实的覆盖项；未核实映射无效，不靠近似型号自动配对。[映射来源审计](openrouter-model-mapping-audit.md)记录的历史版本对应不证明完整 reasoning、实际计费路由或实时指数覆盖；当前随包映射为 5 条路由条目（4 个 provider/model 身份，K3 占 2 条计费路由），逐次核对真实宿主路由。实抓 `/models` 不含能力指数，Artificial Analysis 数值从独立基准接口取得，再按实际 permaslug 精确关联；不把模型页的旧观察当新 API 覆盖结论。它们只是型号级质量先验，不证明实际路由、推理档位、价格或额度。

当前实现使用 overview-v3：保存目录 ID、上下文／模态、支持参数及可得 coding／agentic／intelligence；不复用旧 v1／v2，agentic-only 不被通用 coding 门挡住。查询默认只显示事实，明确选择任务相关指标才提供先验；缺 coding 不用其他指数补成编码证据。当前测量日期和方法版本未知，72 小时只表示抓取有效期；任务要求已知测量日期时不给先验。目录上限与工具声明不替代实际路由／宿主能力。成员与检查者任务指标已接该投影（有限校准与独立复核见完成记录）；未分类消费者只接收事实、不自动评分。旧 `jev-checker-task-fit-2` 按历史版本解释，不进入新排序；现行安装即含该投影；历史构建差异见 Git。

同模型多个基准变体逐行保留，不取最大或平均值，也不推断当前 OMP reasoning 属于哪行。`meta.as_of` 是基准数据集更新时刻，仍不充当测量日期。精确同名指标与所有已报告变体均显著分歧时暂停正向建议并交 Root 复核；只与部分变体分歧时并列呈现未解决差异，不能谎称冲突已消除。

覆盖文件与随包 [`lib/orbit/data/openrouter-model-map.json`](../../lib/orbit/data/openrouter-model-map.json) 同格式：顶层 `schema_version="orbit-openrouter-model-map-v1"`、`entries` 数组；每项**恰好**含 `provider`、`model`、`reasoning`、`billing_route`、`openrouter_id`、`canonical_slug`、`sources`（1–5 个无凭据的绝对网页 URL）、`verified_at`（ISO 8601 UTC）、`verified_by`。`openrouter_id` 是目录实际行的 `id`，可与日期后缀的 `canonical_slug` 不同；`~…-latest` 别名不可作目标。程序校验结构、目标行和 canonical 漂移，但**不能代用户阅读网页来确认厂商版本事实**；提交覆盖前由 Root／用户审核资料。不需要覆盖已核实的默认项。

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

status 默认输出可读文本；`--json` 返回单项原始 state，多个／没有候选时返回 `{ "tasks": [...] }`。终态的文本「下次检查：未安排」不再附上停止前遗留的待收尾／待重检依据，即使 `--json` 仍保留原始审计字段。stop 默认说明入队和后续查询方式，`--json` 返回机器结果，供扩展桥与自动化集成使用。

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

`check` 请求一次独立检查；`amend` 只提交用户补充要求的原文；`dispute` 提交真实反证。任务内分工由 Root 在会话内经原生 `task` 派发（Orbit 在成员模型工作前完成登记）；`orbit delegate` 命令面以安装版本 `--help` 为准。成员通过 OMP 原生 `hub` 或 `write agent://Main` 把结果发给 Root，Root 核验并集成；任务内协作记录区分消息调用、送达结果和自动 `task` 回执，不能凭「已生成成员」判定交付。

这些控制操作返回 `queued` 表示入队，不能据此判断已完成或已停止。原会话中的新用户消息不自动修订正在运行的旧任务；确认属于旧任务时由 Root 显式 `amend`，新问题按独立请求处理。

最终检查同时给出 `delivery.ready` 与具体理由，和 finding／`verdict` 分开：`continue` 且零问题不表示实际答复已经送出。Root 在实际验证后调用 Orbit `action=check, task=<任务目录>`，在本轮回复中交付可核验结果并结束；手动终检若在回复过程中入队，等该轮交付完成才开始。自动检查即使判定 `complete` 也不会发完成通知，不能只等待自动检查唤醒。纯文字结果须先在 Root 已完成的回复中可见，修订文件后旧通知失效；推送要求另以只读、限时的 Git 远端引用对比当前 HEAD，远端不可达或目标不明确时记未验证，不接受 Root 自报。状态区分等待检查、当前版本可申请完成、完成申请已入队、通知失效、停止确认中；只有在本会话 Orbit 工具中显式 `stop(intent=complete)` 且最终停止确认后才能记 `complete`，普通 CLI `orbit stop` 始终只是暂停。

状态中的「自动检查已安排」表示尚未开始（可能因 Root 正在工作而延期），不是检查在途或任务完成；「独立检查进行中」只在检查者已启动时显示。终检可见同一输入与产物版本最近至多四条已完成且可归属的 Root 回复：手动检查入队后的简短等待回执不撤销此前的实际交付；后续实质修订仍须核对，修改输入或产物后不能沿用旧答复。检查者只能根据固定快照、已交付内容和真实验证作结论。

### 候选模型池与检查者重选（ADR-009）

在交互式 `orbit omp` 会话输入 `/orbit-models` 打开搜索多选：直接输入文字过滤 `provider/id`，↑/↓ 移动，Space 勾选，Enter 一次保存净变化，Esc 取消。当前不可选但已入池的旧标识可移出，不能新增。列表逐项展示当前会话可选性、精确身份的证据状态（缺失、过期、不可用或有效）及可选模型概述状态；**质量未判断、隔离检查者未探测**不代表已验证质量、认证或额度，也不等于池内模型不能被实际启动探针选择。无 UI 时文字列表仍给出诊断；`orbit model-status --project DIR` 只读池、用户级证据及概述快照，不发起 JEV、OpenRouter 刷新或模型探测。提交前若可选列表变化或同一 ID 被另一会话修改，界面提示刷新，不覆盖对方的修改。逐项命令和脚本入口保留：

```text
/orbit-models add provider/id     # 只能加入当前会话可选列表中的模型
/orbit-models remove provider/id  # 可移除池内但当前不可选的旧标识
orbit model-candidates list       # 命令行查看；add/remove 可用于脚本
orbit model-status --project DIR  # 只读精确身份的证据诊断；无会话时可选性未知
```

候选池保存在用户级配置，跨会话共用，只保存型号，不保存凭据。检查者优先从池与当前 OMP 会话可用目录的交集中预检；池中无可运行型号或池空时，从 OMP 当前会话可用型号中继续筛选，Root 也可显式指定可用检查者。**受控任务的成员**有可用池内 Agent 时，通用 `agent="task"` 若解析为池外 OMP 默认型号会被拒绝并列出可用 Agent；Root 可直接派池内 Agent，即使 Jev 尚待补证。池空或当前无可用池内 Agent 才放行可解析的 OMP 默认。Root 想派默认型号可通过 `/orbit-models` 把它加入池；无需额外用户逐型号授权。非受控 OMP 会话不受此门约束，成员实际型号漂移仍被拒绝。Jev 只给建议，Root 自选不冒充推荐。

新版成员选择针对 Root 声明的有界工作单元，保留目标、要求引用、上下文／决定、范围、验收、依赖和升级条件。单元绑定当前输入与实际产物根；未满足依赖不派发建议，修订或工作区重绑定后不能采纳旧结果。Root 可通过 Orbit 工具或 `orbit work-unit` 声明与核验；工作区已接真实宿主 bind 和逐工具范围校验。Root 的原生 task 文本须以独立行引用 `orbit-unit: wu-...`；未知／过期单元或真实模型失配拒绝派发或工具执行。macOS 声明命令还经系统沙盒；没有已验证沙盒的平台由 Root 执行必要核验，不能默许成员无约束运行。当前修复的真实闭环证据与剩余限制见[验收记录](ordinary-task-repair-acceptance-20261002.md)。

工作单元可设 `execution=root|delegate`（缺省 delegate），Root 的集成单设 root，不占选型队列。declare 回执携带运行时选型；可用 `work-unit select` 刷新具体单元，native task 在派发前再次预检、复用和版本核对。Root 保留候选池内自选裁量。成员需要的项目文件可列入 `input_materials`，必须已存在且在 allowed_paths 内；外部技能/MCP 不自动开放。bash 必须声明完整 allowed_commands；无可执行入口或无权限材料会在成员启动前返回修复步骤。

read 的原生行号选择器、多路径及 grep/glob 的内嵌通配符按真实目标校验。grep 裸通配符保留原生递归语义，要求成员实际 cwd 与产物根一致。当前目录搜索仍采用保守边界：搜索子树出现 `.git`、`.orbit`、符号链接，或遍历超过 10000 项时拒绝；Root 应给出较窄的项目目录或具体文件入口。

成员与检查者同时取得精确证据和目录先验，相关 coding／agentic／intelligence 明确来自任务需求，不默认猜编码。目录能力与实际 SDK 路由 limits 分开；上下文／模态／工具要求未知或不满足、同指标潜在冲突以及明确测量日期要求未满足时，候选暂停自动正向建议，交 Root 复核。任务质量指数不与 Jev 分数相加；不是模型可靠性证书。

问题采用 delegation-4／candidates-4／checker-task-fit-5、selection-input-2／quality-decision-4。真正校准放行、实际 task profile、provider／型号／input／qset 匹配后才作正向建议；未放行只显示事实并保留可运行选项，不因未知费用阻断 Root。新分派不使用速度、时间、关键路径缩短或粗费用档，运行超时／TTL／停止计时保留。旧 delegatable／0.55／0.50 按历史版本解释。

decision-4 保留原问题和质量阈值，handoff_fit 判结构可交接，member_task_fit 是泛化限制，逐候选 task fit 决定具体适配；返回首选、备选和未知费用等限制。无关文件变化不重新支付同单元选型，要求、相关上下文、依赖与候选事实变化会失效。

`member_selection_assessed` 是保存的判断；`delegation_recommendation_delivered` 和持久 delegation_hint 才表示已经送达。Root 自主经原生 task 使用候选，串行交接也合法。只有实际工作单元、成员、调用、型号及目标派发尝试，连同实际 bind 留存的已送达提示签名／message ID，都匹配才记为采纳；旧失败调用、同型号或相邻时间不能领取下一轮建议归因。Root 自选记为 root_without_hint。

检查者始终先核对隔离只读环境可解析性，未放行不支付选型判断；缺事实不要求用户补完整池。质量未证实的可运行型号仍可降级，显式选模不跳过独立检查、手动终检或停止核对。模型级先验不证明本路由／推理档位／额度或价格；真实效果按有限真实验收记录，不作全域宣称（见完成记录）。

独立检查者沿用 OMP 模型配置与凭据解析，仍在独立只读会话中读取固定快照。认证、额度或结果校验失败会留下失败检查记录，Orbit 在**检查结束后**从尚未尝试的可运行型号中按池优先和 Jev 次序有界重试；所有型号失败才阻塞，不把失败当终检。Root 修复环境后可从 OMP 当前可用型号中重选：

```bash
orbit review-model TASK_DIRECTORY --model provider/id --reason "检查者凭据恢复"
```

该命令入队前核对当前 OMP 会话与隔离环境，任务进程在真正开始检查前再核对；在途检查不会切换。同一失败型号不能靠重复 `check` 绕过阻塞。Root 使用 Orbit 工具 `start` 的 `review_model` 参数也只接受经上述可用性核对的 OMP 型号。没有有效独立终检时，不称任务已完成；需要中断则按用户指令普通暂停并确认停止。

Root 在受控会话中需要自己换用不同精确型号时（例如硬性 provider 错误需换型号诊断），使用 Orbit 工具的 `root-model` 动作——**这是 OMP 工具动作，不是新的 CLI 命令**：

```text
orbit 工具调用: { action: "root-model", task: TASK_DIRECTORY }
              # 不带 root_model 时列出当前池 ∩ OMP 目录的精确 provider/id
orbit 工具调用: { action: "root-model", task: TASK_DIRECTORY,
                  root_model: "provider/id",   # 如 "provider-a/model-x"，从上面列出的可选 ID 中选
                  phase: "diagnosis",          # execution | integration | diagnosis
                  text: "选择理由" }            # 非空原因，写入事实记录
```

目标必须同时在候选池与当前 OMP 目录中并精确解析；`from`／`to` 按切换前后的真实身份记录。**配置选择回执本身不证明实际调用身份**——实际身份由切换后后续 native assistant 调用回执（`resource-calls.json` 中的 `actual_identity.provider`／`actual_identity.model`；`actual_model` 只是中间 receipt 字段）证明，该阶段归属适用于切换后的后续调用，不局限仅一次。在途独立检查、排队的手动终检或完成停止窗口内拒绝切换。同型号同阶段重复请求被拒；原生 `/model` 切换后可重新选择。这不是给检查者重选型号的入口（那用 `orbit review-model`）。


除 Root 手动调用外，程序自身也可在满足合同的全部边界时（真实缺陷已被独立检查确认修复、手动终检提醒**发送之前**的窄程序标记、来源检查与账本回执可精确交叉核验等）为该任务选择**一次** integration 阶段型号（目标＝实际发现该缺陷的检查调用型号）。**该程序来源不是 Root 工具调用**：记录使用独立 kind（`tool_call_id=null`、origin=program），不冒充 Root 动作；配置选择回执同样不证明实际调用身份，仍以下一 native assistant 回执为准。程序保守识别已有显式选择并优先；之后用户与 Root 仍可自行改型（原生 `/model`、`root-model`），程序不自动回滚、不重试失败，并发场景的最后写者限制以合同为准。

### 模型证据提交（model-evidence）

Root 从一手来源核实任务质量事实，按真实 provider／model／reasoning／billing_route 提交一个 JSON object 或 array；不要求 Root 与全池同时补证。unknown 与 provider default、不同计费路由不互换，不为命中 lookup 改路由。主会话的配置解析不证明独立检查进程的服务端身份或账号；不能证明的字段如实未知。

```bash
orbit model-evidence --file ./model-facts.json
orbit model-evidence TASK_DIRECTORY --file ./model-facts.json
```

无任务目录仅校验／缓存，不创建任务；带目录通知下一次判断重读事实，不中断在途检查。来源和数据须真实，无法取得可记 unavailable；提交不等于自动推荐、派发或完成。

质量 entry 示例（替换尖括号；测量日期／方法版本未知时省略，不用抓取日期填补）：

```json
[{"provider":"<真实 provider>","model":"<真实 model>","reasoning":"<实际档位或 unknown>",
  "billing_route":"<实际 direct_api|subscription_quota|unknown>",
  "status":"evidence","retrieved_at":"<含时区 ISO8601>",
  "sources":["https://<一手来源>"],
  "metrics":{"<任务相关质量指标>":{"value":0,"unit":"<单位>","basis":"<测量口径>"}},
  "measured_at":"<含时区实际测量时间>","method_version":"<真实方法版本>"}]
```

sources 为 1–5 个无凭据绝对 http(s) URL；value 有限数字，unit／basis 文本；valid_until 可省略且受型号标识有效期约束。measured_at 不得晚于 retrieved_at；抓取时效不等于测量时效。新写不接收速度／时间／local_samples／comparison 指标、cost_tier 或 cost.／quota.；历史原文保留，旧字段不进入当前质量判断，剥离后没有质量指标的记录不当命中。具体约束见 `orbit model-evidence --help`。

本路由价格与订阅规则走独立可信资源流，不能用 OpenRouter 报价或粗档代替；没有可信输入／输出／缓存构成时，交叉单价不能给出总成本高低。价格、用量、账户／计划可比条件不足均保持未知；不折算假账单、不承诺预算内、不新增硬预算门。第一方页面未给发布生效日时，不得用页面“最后更新”日期顶替生效日：该事实保持未知、不参与定价（截至 2026-09-30，被抽查的真实台账报告的每一笔均为 unknown，不外推到全部账目；账户范围与实际扣减桶仍未知）。schema 并不禁止价格事实落盘：当前抓取资料的发布生效日、账户范围与已核实路由分别未闭合，任一未闭合即不可用。缺生效日且未标记 unknown 的导入仍被拒绝；显式 `unknown` 标记的真实来源可存档并列出（已实测），但它不覆盖任何调用、不定价、不参与自动排序。报告里 `cash` 为空或 priced 为 0 只表示**未知**，不是 0 成本。

### 时间和用量

`orbit route-resources import --project DIR --file FILE` 导入带真实来源、适用身份／账户／计划、有效期、币种和单位的路由事实；`list` 只读查阅。`report TASK_DIRECTORY` 优先使用逐调用实际 SDK credential/account 观察；可用 `--file FILE` 补已核实的账户／计划上下文，与实际观察矛盾时保持未知，不从价格反推账户。该入口不请求模型或建立预算门，不能用目录报价或 SDK 自报金额替代可信来源。该语义已用隔离 CLI 实测（显式未知生效日的导入行为同现行安装）：显式未知生效日的事实可 `import`／`list`（`effective.unknown=true`），缺标记的缺生效日导入仍被拒绝，两份真实台账副本 `report` 全部 unknown、`cash []`；**未知生效日永不覆盖调用、永不参与定价或自动排序**，`cash` 为空只表示未知。

`orbit route-resources forecast TASK_DIRECTORY --file FILE` 保存当前单元或检查范围的预测构成，私有记录绑定当前要求和产物根。JSON 顶层是 `scope`（member／review）、成员范围的 `work_unit_id` 和按 provider/model 索引的 `candidates`；每项包含真实四键 `route`、已核实 `account_scope`／`plan` 及 `prediction`。预测种类 `declared_workload` 明确是 Root 的有界工作量假设：可展示条件性金额，缺少可归属用量样本时不参与自动费用排序。`similar_unit` 还需本任务已完成、同身份／角色且用量完整的 `reference_call_ids`，成员引用须来自已接受单元的实际成员和型号，不能因替换成员后来成功而将此前拒绝结果算成已接受样本；填写的分类和数字必须等于这些回执逐类均值，否则该候选成本未知。原生回执未报告 reasoning 时账本保持缺失，引用核验仅在该比较处按类型化 `unknown` 对齐；已报告的具体档位仍精确匹配，不回写账本。保留 `usage` 原分类、`basis` 和 `applies_to`；它不是实际消耗或预算保证，不能沿用帮助示例的数字。修订或重绑定后失效，缺可信价格／用量时成本未知，Root 继续按质量和现有事实派发。

Root／成员原生调用回执按实际边界独立计账，字段分别保留，不能把 input、缓存、reasoning 和 total 无条件相加。pending 和写入失败明确显示覆盖缺口；停止后晚到 final 可以继续写入账本，不改变任务终态。资源报告仅汇总可归属记录，按币种和实际账户分开；订阅仅展示原规则，不折算金额或未知消耗。这些行为均已随安装交付（逐调用账本在真实任务中运行；现金／扣减未知保持原边界）。

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

## 逐项要求覆盖

独立检查报告逐项 requirement／scope／status／evidence 并声明是否完整枚举。程序把证据绑定实际检查、输入、固定产物和真实目录；只有当前产物 reviewer 完整且至少一项 delivery、全部 delivery verified 才可进入手动终检就绪。lifecycle 只列本次最终检查、后续停止与收尾回复，由程序另外核实；测试执行始终属于 delivery。旧缺 scope 项按 delivery 解释，不追认旧未核验为通过。原生 Root 工具回执保留 start 输入／任务及 end 产物绑定、实际执行目录、退出状态与截断标记；自写日志不冒充程序回执。未核验、缺报告、损坏或写失败保持未知，普通停止仍可收尾。`status` 与会话汇总显示当前覆盖；历史任务缺字段不追认通过。私有近期投影可压缩，原始检查结果和绑定仍在任务 checks，导出继续保留。程序校验结构与版本，枚举完整性仍是独立检查者的判断。当前安装构建及真实验收以[交接](../plan/handoff.md)为准。

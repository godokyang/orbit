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

原有的 `TYPESAFE_API_KEY` 环境变量继续可用，存在时优先于环境文件。新任务发生 Jev 判断后，`orbit status --json` 中的 `jev.model` 与 `jev.scores` 表示请求成功；`jev.unavailable` 表示服务调用失败。需要对某个项目关闭外发时，在项目根目录创建 `.orbit/jev-disabled`；移除后，新任务恢复使用 Jev。不要把环境文件放进项目或提交到 Git。

执行成员由 Root 经 OMP 原生 `task` 派发，不再有按宿主 kind 的允许名单；成员一层、沿用 Root 原生权限。

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

这些控制操作返回 `queued` 表示入队，不能据此判断已完成或已停止。直接在原会话补充的用户消息由 Orbit 观察，不需要再手动提交相同 amendment。

### 候选模型池与检查者显式重选（ADR-009）

在 `orbit omp` 会话内维护候选池：

```text
/orbit-models                     # 列出当前会话可选模型、候选池与状态
/orbit-models add provider/id     # 只能加入当前会话可选列表中的模型
/orbit-models remove provider/id  # 移除；池内但当前不可用的标识标为不可用，可移除但不会因此启用
```

候选池保存在用户级配置，跨会话共用，只保存模型标识，不保存凭据。Orbit 只在该池与「当前会话可选列表」的交集内比较：为执行成员给出模型建议，为独立检查者选模，按质量先过线、端到端时间、粗档费用排序，并记录实际模型；不按品牌排序。候选池为空时检查者沿用现有默认模型行为，池非空却没有合格检查模型时要求显式指定，不擅自使用池外默认模型。Root 始终显式派发成员，成员不能再派发成员。

检查者在真实认证或额度失败后，任务保持运行并阻塞，需要你显式指定下一次检查使用的模型：

```bash
orbit review-model TASK_DIRECTORY --model provider/id --reason "认证失败后改用"
```

指定模型可在候选池外，会记录池外提示；命令只入队，不自动重试、不在检查进行中切换。**状态：选模规则与 `review-model` 命令已随源码落地并通过真实验收；运行时在每次检查前重选、失败后阻塞与显式重选的端到端接线已有真实失败路径样本。池内自动（非显式）正选择仅由确定性测试覆盖（真实自动尝试因无候选通过质量线被正确拒绝，未取得 live 正样本）。** 进度见[模型候选池交付 TODO](../plan/model-pool-delivery.md)。

### 模型证据提交（model-evidence）

当 Orbit/JEV 要求模型证据时，Root 从一手来源检索事实后用 `orbit model-evidence TASK_DIRECTORY --file FILE|-` 提交（一个 JSON object 或 array）。`provider`/`model`/`reasoning` 必须与请求中的身份完全一致；不写网页正文或凭据，不伪造来源或指标。

占位结构（尖括号处替换为真实结果；`valid_until` 可省略，不得超过该模型标识的有效期）：

```json
[{"provider":"<请求的 provider>","model":"<请求的 model>","reasoning":"<请求的 reasoning>",
  "status":"evidence","retrieved_at":"<ISO8601，含时区>",
  "valid_until":"<ISO8601>",
  "sources":["https://<真实来源 URL>"],
  "metrics":{"<指标名>":{"value":0,"unit":"<单位>","basis":"<测量口径与样本说明>"}}}]
```

约束：`sources` 为 1–5 个绝对 http(s) URL（不带凭据）；`metrics` 为命名对象，每项 `value` 为有限数字、`unit` 与 `basis` 为文本；`retrieved_at` 不能是未来时间。`metrics` 只写该模型自身的测量事实，不写比较或身份断言：`comparison.*` 这类跨身份指标会被拒绝；既有缓存中的此类指标也不会进入二阶段摘要（摘要 note 只声明结构校验、指标由提交者提供）。无法取得证据时提交 `status: "unavailable"` 并给出 `reason`，不得编造证据：

```json
[{"provider":"…","model":"…","reasoning":"…","status":"unavailable","retrieved_at":"…","reason":"<为什么无法取得>"}]
```

Orbit 校验后原子写入用户级缓存并通知任务进程重查；缓存按模型标识的有效期使用，过期后重新检索。具体字段限制以 `orbit model-evidence --help` 与校验错误为准。

### 时间和用量

| 参数 | 含义 |
| --- | --- |
| `--check-in SECONDS` | 首次观察间隔，后续由检查者约定下一次时间；等待不调用模型 |
| `--estimate-minutes N` | 耗时预估，用于事后对比 |
| `--estimate-tokens N` | token 预估，用于事后对比，不是硬上限 |
| `--deadline ISO8601` | 用户明确指定的硬截止，例如带时区的日期时间 |

只有明确设置的截止时间才会形成硬停止线。任务总费用拿不到时记录未知；不能把原会话累计消耗当成本任务消耗。

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

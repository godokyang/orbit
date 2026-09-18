# Orbit 进阶使用参考

首次安装和日常使用见 [README](../../README.md)。本文用于自定义安装、维护、手动 CLI 操作和其他工具集成。

## 安装选项

### 自定义目录

在本地 Orbit 仓库执行 `sh install.sh` 时安装当前源码；远程安装命令通过 `--ref` 选择源码。入口目录与运行程序目录必须分开。

| 参数 | 默认值／环境变量 | 说明 |
| --- | --- | --- |
| `--runtime-dir DIR` | `ORBIT_RUNTIME_DIR`，否则 `$XDG_DATA_HOME/orbit/orbit`，未设置 XDG 时为 `~/.local/share/orbit/orbit` | 保存版本和安装记录 |
| `--bin-dir DIR` | `ORBIT_INSTALL_DIR`，否则 `~/.local/bin` | `orbit` 命令所在目录，需在 PATH 中 |
| `--opencode-dir DIR` | `OPENCODE_CONFIG_DIR`，否则 `${XDG_CONFIG_HOME:-$HOME/.config}/opencode` | OpenCode 的 `plugins/orbit.js` 所在配置目录 |
| `--omp-dir DIR` | `PI_CODING_AGENT_DIR`，其次 `OMP_PROFILE` 对应目录，否则 `~/.omp/agent` | OMP 的 `extensions/orbit.js` 所在 agent 目录 |
| `--no-opencode` | 默认不禁用 | 不安装 OpenCode 原生连接插件 |
| `--no-omp` | 默认不禁用 | 不安装 OMP 原生连接扩展 |
| `--no-modify-path` | 默认自动配置 | 不修改 shell 配置；选择随安装记录保存，`--modify-path` 可重新开启 |
| `--ref REF` | 远程安装默认 `main`；也可用 `ORBIT_REF` | 从 GitHub 获取分支、标签或完整提交 SHA |

`--no-opencode --no-omp` 一起使用只安装 CLI。它不会让普通 OpenCode／OMP 获得控制通道。

更新沿用安装记录中的目录和扩展禁用选择；改变这些目录或扩展选择时先卸载再安装。环境变量和显式目录也要与原安装保持一致。

已有未知命令包装、同名自定义扩展或无归属的安装目录时，安装器拒绝覆盖。先确认原入口由谁管理，通过对应工具卸载，或改用独立目录；不要直接覆盖自定义资料。

### Jev 与成员名单配置

运行 `orbit jev setup`，按提示输入 TypeSafe key 并回车。命令不回显 key，将它写入 `${XDG_CONFIG_HOME:-$HOME/.config}/typesafe-ai/env`（权限 `0600`），并在 zsh／bash 启动文件中追加加载该文件的语句；重复运行可替换旧 key。重新打开终端，再从该终端启动 Codex、OpenCode 或 OMP。Orbit 运行时只读取启动进程的 `TYPESAFE_API_KEY`，不读取 Orbit 配置文件；当前终端和已有任务不会自动改变。

原有的 `TYPESAFE_API_KEY` 环境变量继续可用，存在时优先于环境文件；执行设置命令时会提示这一点。新任务发生 Jev 判断后，`orbit status --json` 中的 `jev.model` 与 `jev.scores` 表示请求成功；`jev.unavailable` 表示服务调用失败。需要对某个项目关闭外发时，在项目根目录创建 `.orbit/jev-disabled`；移除后，新任务恢复使用 Jev。不要把环境文件放进项目或提交到 Git。

成员授权名单是另一项配置：默认使用 `codex、omp、opencode、kimi、cursor-agent、grok`，无需创建文件。要覆盖默认名单，在 `${XDG_CONFIG_HOME:-$HOME/.config}/orbit/members.json` 保存 JSON 对象，例如 `{"allowed_kinds":["codex","opencode"]}`；空数组禁止创建新成员。`orbit doctor` 显示名单来源、允许的 kind 和当前会话实际可调用的 kind。名单允许不代表已安装、已登录或已有受控适配器。

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

OMP 的 profile 使用独立的 agent 目录。例如首次安装到 `work` profile：

```bash
OMP_PROFILE=work sh install.sh
```

未设置 `PI_CODING_AGENT_DIR` 时，这会使用 `~/.omp/profiles/work/agent`。之后用 `omp --profile work` 启动。默认 profile 的扩展不会因此安装到所有 profile。

已有安装需要沿用其记录路径；单纯在更新时换 `OMP_PROFILE` 不会迁移已有安装。确需改用另一目录时，先卸载原安装再选择新目录。

### 更新和卸载的行为

`orbit update` 读取当前安装记录，沿用原目录和扩展选择；远程来源沿用原 ref，本地来源沿用保存的源码目录。显式 `--ref REF` 可改用远程来源；本地源码目录不存在时给出重新安装或显式改用远程的提示。

远程安装先把 ref 解析成一个 SHA，再下载该提交的完整源码。更新先准备依赖并验证新版，通过后才切换 `current`，CLI 与原生连接扩展一起切换。准备失败保留旧版，成功后清理旧版登记文件。

新版本持有 lease 的运行任务、`orbit codex` 会话与已加载宿主不会因更新而失去旧 release；持有者退出后的下一次安装会清理旧 release。这不是正在运行任务的热更新。卸载前须结束使用该安装的任务和宿主；若仍有存活 lease，卸载会在移除任何入口或安装记录前拒绝。首次从未登记 lease 的旧版升级前仍需结束旧任务和会话。同一安装目录一次只运行一个安装器。

卸载读取安装记录，只移除仍匹配的入口和已登记文件。用户额外文件、项目代码和项目 `.orbit` 资料保留。自定义安装的命令为：

```bash
orbit uninstall
```

## skill 管理与 OMP

skill 安装、更新和移除全部交给 `npx skills`。`install` 是 `add` 的官方别名；作用域、Agent 选择和参数以 [skills CLI](https://github.com/vercel-labs/skills/blob/main/README.md) 为准，Orbit 不维护各宿主技能目录列表。

全局安装通常只需一次；项目级命令省略 `--global`，在目标项目执行：

```bash
npx skills install godokyang/orbit --skill orbit --agent codex opencode
npx skills list
npx skills update orbit --project
npx skills remove orbit
```

移除时不必加 `--agent`，否则可能只清理选定 Agent 的入口，仍保留共享 skill。项目与全局是两份来源；只保留实际需要的作用域，避免旧项目副本覆盖更新后的全局说明。

### OMP 的共享目录发现

skills CLI 为 Codex／OpenCode 安装时使用共享 `.agents/skills`；全局为 `~/.agents/skills`，项目级为 `<项目>/.agents/skills`。OMP 原生支持这两种目录，见 [OMP 18.1.16 官方发现实现](https://github.com/can1357/oh-my-pi/blob/v18.1.16/packages/coding-agent/src/discovery/agents.ts)。因此即使 skills CLI 没有 OMP 目标，也可选 Codex 安装共享 skill：

```bash
npx skills install godokyang/orbit --skill orbit --agent codex --global
```

无需新增 Orbit 安装开关，也不要用 `--agent pi` 冒充 OMP。若主动关闭过 OMP 的 Agent Dirs skill 发现，先恢复对应发现设置。OMP profile 的扩展仍按上面的目录安装；共享 skill 与扩展是不同来源。

### 维护边界

`install.sh` 不再接受 `--skill-dir`、`--no-skill`，也不读取 `ORBIT_SKILL_DIR`。运行包保留检查者需要的规则资源，但不向任何 Agent 创建 skill 入口。程序与 skill 分别更新，`orbit version --json` 不代表 skill 版本。

本地开发可把 `godokyang/orbit` 换成本仓绝对路径，由 skills CLI 安装未推送的 skill。

## 手动 CLI 操作

日常由 Agent 通过宿主提供的 Orbit 工具完成调用，不需要用户填写内部 ID。下面的 CLI 用于已有控制连接的自定义宿主、诊断或集成，不能直接接管任意普通会话。

### 日常查询与诊断

`orbit status [TASK]`、`orbit stop [TASK]` 从当前目录向上寻找最近的 `.orbit` 项目，到独立 Git 项目边界停止。TASK 可为目录或当前项目唯一 ID 前缀。省略时优先待处理记录（包括 failed / stop_unconfirmed）；多个候选列出供选择，停止不猜测。仅 status 在无待处理记录时显示最近结束的一项。

status 默认输出可读文本；`--json` 返回单项原始 state，多个／没有候选时返回 `{ "tasks": [...] }`。stop 默认说明入队和后续查询方式，`--json` 保留机器结果；MCP 和原生插件显式请求 JSON。

`orbit doctor [TASK] [--json]` 不调用模型，不修改安装。依赖、扩展安装、连接和模型配置分别报告；`connection.ready: null` 表示没有可验证的会话，`false` 表示验证失败。只有环境通过且真实连接成功才有顶层 `ready: true`，并不代表模型登录或额度可用。无连接上下文时纯环境检查通过可返回退出码 0；发现环境、安装或连接错误返回 2。多个任务不自动选择连接，传 TASK 或在目标会话调用原生工具。

默认 `orbit --help` 展示日常入口；`orbit start --help` 等子命令展示执行参数。

### Codex 入口的权限与恢复

`orbit codex` 新会话默认 full access，显式权限参数优先。恢复使用显式会话 ID 时，Orbit 按该会话记录的沙箱恢复（full 保持 full，受限保持受限；记录不可读时要求显式沙箱，不会降权继续）；显式沙箱参数经本入口持有的 app-server 生效，不传给会拒绝远程权限覆盖的远端 TUI；显式审批参数与 Codex 保存的审批策略不一致时在启动前报错，不会以其他权限继续。`resume --last` 由 Orbit 在当前项目的本地记录中解析为最新可恢复会话的 UUID，再按该会话恢复并把 UUID 交给 Codex，不会让它使用可能选中其他项目的全局 `--last`；当前项目没有匹配记录时要求显式会话 ID，选择器暂不支持。显式会话 ID 不受项目限制。

### 接入已有会话

Codex 宿主提供 `CODEX_THREAD_ID` 与当前原生控制端点；`ORBIT_CODEX_SOCKET` 或 `--socket` 指向实际承载该会话的服务。`orbit doctor` 在有当前 Codex 会话身份时验证该连接；其他宿主使用已有任务的连接记录，或由 Agent 的原生 Orbit `context` 核对。

OpenCode／OMP 插件自动提供项目、会话和私有连接。Agent 分别通过原生 Orbit 工具或 `xd://orbit` 调用，不让用户猜测端口、socket 或会话 ID。

在已具备 Codex 控制连接的环境中：

```bash
# 选取最近一条原生用户消息，指定检查模型
orbit start --review-model MODEL --check-in 300 --estimate-minutes 90

# 指定原生用户消息，并保存其明确引用的依据文件
orbit start --review-model MODEL --message-id MESSAGE_ID --basis path/to/spec.md

# 使用明确的原始指令文件
orbit start --review-model MODEL --prompt-file ./instruction.txt --estimate-tokens 200000
```

占位符应换成实际值。`--thread`、`--socket`、`--project` 可显式提供；项目默认当前目录，`--basis` 可以重复。不应把 Agent 自己整理的计划冒充用户原文。

`start` 默认创建任务进程并返回 `task_directory`、pid 和 `starting`。`--foreground` 将任务进程留在当前终端，直到任务结束。两者都要通过实际状态确认接入。

### 检查、补充、争议和成员

```bash
orbit status TASK_DIRECTORY --json
orbit check TASK_DIRECTORY
orbit amend TASK_DIRECTORY --file amendment.txt
orbit dispute TASK_DIRECTORY --reason "具体争议与反证"
orbit delegate TASK_DIRECTORY --file scope.txt --model MODEL
orbit delegate TASK_DIRECTORY --file scope.txt --kind codex
orbit stop TASK_DIRECTORY --reason "停止原因" --json
```

`check` 请求一次独立检查；`amend` 只提交用户补充要求的原文；`dispute` 提交真实反证；`delegate` 的文件写明成员范围、资源和回报要求。默认 `delegate` 创建同宿主成员；已验证的 `--kind codex` 路径由 OpenCode Root 创建独立 Codex 成员，使用 Codex 自身配置的模型或显式指定的已授权模型。目标 kind 必须已获用户允许；安装或出现在 Herdr 列表中不等于授权。结果由 Root 核验并集成。

这些控制操作返回 `queued` 表示入队，不能据此判断已完成或已停止。直接在原会话补充的用户消息由 Orbit 观察，不需要再手动提交相同 amendment。

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

# DSH 宿主探针记录

日期：2026-10-20。目的：在写任何 Core 代码之前，用空壳插件逐项验证[实施计划](dsh-implementation-plan.md)依赖的 DSH 接缝。探针代码与复跑方法在 [`tests/host_conformance/dsh-probe/`](../../tests/host_conformance/dsh-probe/README.md)。

## 环境与边界

| 项 | 事实 |
| --- | --- |
| DSH | 桌面版 0.2.1-rc.2 注册的 `dsh` 命令（Electron Node 24.21.0），与方案钉的提交 687f282e 同版本 |
| 隔离 | 独立 `DSH_HOME`，从 `sdk` 模板派生 `orbit-probe` profile；检查者用第二个独立 home 的 `orbit-checker` profile；未触碰用户的 `~/.dsh` |
| 模型 | 没有真实模型。探针插件注册名为 `probe` 的假 LLM 适配器，按脚本返回文本或工具调用，驱动真实的 agent 循环、工具管线、子 Agent、jobs 与持久化 |
| 宿主插件 | 以绝对路径经 `--patch` 插入的单文件 ESM 插件；bundle 层序另用本地 bundle 经 `dsh plugin add` 安装验证 |
| 未覆盖 | web profile（动态 Cordis、Web answerer）、真实模型下的时序、Loom 整链、Linux/Windows、ACP 后端 |

这些结论证明接缝存在且行为符合设计前提，不证明 Orbit 的产品行为已在 DSH 上通过验收。

## 结果

| 探针 | 验证什么 | 结果 | 关键事实 |
| --- | --- | --- | --- |
| T0 组合 | 受控 profile 能禁掉清单里的行 | 通过 | `--dump-config` 可断言 `goal-round-driver`、`command-goal`、`tool-goal`、`session-log-deepseek`、`tool-plugin-manager`、`hmr` 为 disabled；sdk profile 本无 `cordis-host-runner` |
| T0b 层序 | 用户 home patch 能否推翻 bundle 的禁用 | 通过（结论：能） | 本地 bundle 经 `dsh plugin add` 装入并写进 `dsh.profile.bundles` 后，bundle 层禁用的行被 `$DSH_HOME/cordis.patch.yml` 一行 `disabled: false` 重新打开。T0 断言不能省 |
| P1 登记 | `agent/created` 抛错能否阻止创建与模型调用 | 通过 | 创建被拒、agent 不在注册表、零次模型调用；放行时监听器完成时间早于首次模型流。注意：被拒的 session 记录仍出现在会话目录列表里 |
| P2 工具门 | `guard` 的拒绝不被 `tools/pre-execute` 的 allow 覆盖；读路径是否受限 | 通过 | pre-execute 返回 allow 后 guard 仍拒绝，bash 未执行，tool/result 为 isError。工作区外 `read /etc/hosts` 在 `workspace-write` 下**成功**，证明读不受沙箱限制；Orbit guard 可按 `file_path` 拒绝 |
| P3 投影 | 从宿主取可见文本、用户消息、问题、活动 | 通过 | `sessionProjections.stateOf(session,'inbox'|'userQuestions')` 可读；`sessionQuery.readSurface` 给模型可见 surface。`user/message` 的 `source.kind` 含 `user`、`runtime-context`、`skill-catalog`，与方案 C3 一致：不能按 role 认人 |
| P4 归档 | `readSession` 快照能否作为 Orbit 证据落盘 | 通过 | 返回 `{session: {version,id,createdAt,cwd,isSeeded}, inheritedEventCount, events}`，写文件后回读一致；DSH 自己的物理文件为 `session.v4.jsonl.zstd` |
| P5 answerer | sdk profile 里 Orbit 能否充当提问答复者 | 通过 | 注册 `user-questions/request` waterfall 后，`ask_user_question` 的 tool/result 即为 Orbit 给的答案。sdk profile 默认不挂该工具，需插入 `dsh-tool-ask-user` |
| P6 检查者 | `dsh-sdk` 后端能否作为独立只读检查进程 | 通过 | 子进程独立 pid、独立 home、cwd 为指定工作区、父进程的 `TYPESAFE_API_KEY` 不可见、显式 env 可见，返回 `CHECK OK`，stopReason completed |
| P7 凭据 | `ctx.credentials` 的引用解析 | 通过 | 启动环境变量按 `source: env` 解析；`set` 后 `source: file` 优先；`unset` 后回到 absent；store 文件不残留明文 |
| S1 成员停止 | dispose 能否收束执行中的成员 | 通过 | `activation.dispose()` 8 ms 返回；成员 job 被 SIGTERM，`job/settled` 落盘，tool/result 记 aborted，`turn/end` reason 为 aborted by parent；之后零次模型调用；`ps` 在 +0/+1/+3 s 均无残留 `sleep`；同一 Root 继续可用 |
| S2 后台 job | 按会话列出并杀 job，结算是否落盘 | 通过 | `jobs.list(owner)` 列出 running；`kill(id, caller, reason)` 返回 requested；`wait` 后 status killed、detail 带 Orbit 原因；`job/settled` 在会话日志里且 `producerReported: true`；无 OS 残留 |
| S3–S5 围栏 | pre-step 能否拒迟到答复与非用户唤醒、放行新用户消息 | 通过 | `user-question-reply` 与 Orbit 标记的唤醒被 reject，turn 落盘无 step，零模型调用；随后的真实用户消息进入并调用模型 |
| S4 复活 | 已停成员会话能否被 resume | 通过 | `agents.resume` 在 `agent/created` 被拒，零模型调用。对已停成员的 `sendMessage` 因参数形状错误未得出结论 |
| S6 杀宿主 | 进程被 SIGKILL 后日志与重启行为 | 通过 | 执行中 `sleep` 无残留；重启后日志里有 `tool/result` "outcome is unknown" 与 `turn/end {kind: interrupted}`；Root 与成员都能 resume，状态 idle，不自动续跑 |

## 探针中发现的实现约束

- 以绝对路径插入的插件文件必须位于某个 `$DSH_HOME/profiles/<name>/` 之下才能解析 `@deepseek-ai/*` 包；放在仓库目录里会 `ERR_MODULE_NOT_FOUND`。经 `dsh plugin add` 安装的 bundle 天然满足；复跑脚本因此先把探针复制进 profile 目录。
- 活的 Agent API 不校验消息形状：缺 `id` 或 `role` 的 `UserMessage` 当场被接受并调用模型，但之后 `readSession` 拒绝整份日志。Orbit 注入的每条消息必须是完整的 `{id, role:'user', content, source}`。
- `sessionQuery.filterEvents` 返回的是带文本的语义文档，不是全部事件；取全量事件用 `readSession`。`listSessions` 需要请求对象参数。
- `approval/policy` 为 `ask` 时没有 answerer 就失败关闭；受控 profile 要显式定策略。
- `dsh plugin add` 只转发 pnpm，不把 bundle 写进 `dsh.profile.bundles`；选择要改 profile 的 `package.json`（Web 的 Plugins 页会做这一步）。
- 桌面版运行时不带 `dsh-subagent-dsh-sdk` 与 `dsh-sdk-client`，需装进 profile；SDK 客户端用 `process.execPath` 直接运行 `dshBin`，它必须是 JS 入口，不能是 shell 脚本；桌面版下还需 `ELECTRON_RUN_AS_NODE=1`。
- 假适配器必须实现 `providerInfo` 返回 `{id,name}`，`resolveModel` 返回含 `id`、`name` 的对象，否则请求以 `INVALID_MODEL_INFO` 失败且 turn 无 step。
- `llm/stream` 监听器必须是同步函数并返回 `next()` 的结果；async 包装会让流不可迭代。

## 对实施计划的影响

- H1–H7 全部有已验证接缝；H5 的证据清单按 S1/S2/S6 的实际事件形状填写（job/settled、tool/result aborted、turn/end 原因）。
- 日志三层读取里的 A 层用 projection 与 `readSurface`，B 层用 `readSession`，均已验证；物理格式是 zstd 代际文件，不可外部解析的前提成立。
- T0 必须作为每次启动前的断言，因为用户层能推翻 bundle 层。
- 检查者载体选 `dsh-sdk` 后端成立，但发行物要把两个 SDK 包作为依赖带上。

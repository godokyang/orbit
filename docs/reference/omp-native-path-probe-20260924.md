# OMP 原生协作路径验证记录（2026-09-24）

本记录对应 [ADR-008](../adr/008-omp-native-collaboration-base.md) 与[冻结的路径验证条件](../plan/omp-native-path-probe.md)。使用原版 OMP 18.2.8、隔离临时项目和 profile、已配置的 `zhipu-coding-plan/glm-5.2` 实跑。Root 审核接缝与证据；同一 Herdr tab 的 OMP、OpenCode、Cursor Agent 分别实现原生协作探针、CLI 入口和独立检查者探针。没有迁移正式运行程序、修改全局安装、发布或推送。

## 验证结果

| 条件 | 结果与证据 |
| --- | --- |
| 显式入口 | [入口原型](../../lib/orbit/omp_entry.rb)通过 OMP 原生 `-e` 加载本仓扩展，透传参数与退出码；`orbit omp --version` 实际返回 18.2.8，入口行为测试通过。隔离 profile 没有自动发现的 Orbit 扩展。当时本机全局 `omp` 仍安装旧 Orbit 扩展，因此普通入口被动化属于正式切换工作，当时尚未作为真实安装行为验收。 |
| 原生派发、通信、结果 | 当时的一次性原生探针（隔离成功轮 `/tmp/omp-ok.hupmpz`）中，Root 最终输出 `SUCCESS-DONE:orbit-…:MEMBER-FINISHED:orbit-…`；停止轮记录原生 `task_result`、`hub_result`。成员启用工具含 `hub` 而无 `task`，满足一层派发样本。该探针已被本机删除；现行正式实现见 [`plugins/omp-host.mjs`](../../plugins/omp-host.mjs) 与 [`tests/omp_native_gate_test.mjs`](../../tests/omp_native_gate_test.mjs)。 |
| 成员登记 | `/tmp/omp-probe.s7mWz1` 与 `/tmp/omp-probe.36Wm8Z` 的登记顺序检查 A–F 全部通过：预分配 ID 在原生 `task` 执行前同步写入，注册表实际 ID 与之相同，成员首个 `before_provider_request` 钩子内写入确认记录。强制预登记写入失败的 `/tmp/omp-neg.Js1KDM` 未创建成员。 |
| 实际停止 | 脚本驱动的 `/tmp/omp-probe.s7mWz1` 在 SIGINT 前观察到 OMP PID 91577 的真实 Python 子 PID 91968，OMP 托管的 `bg_1` 仍运行；SIGINT 后两个 PID 退出，Root 和成员均有 `session_shutdown`，成员从注册表移除，脚本输出 `stop_result: pass`。另一个后台样本 `/tmp/omp-probe.36Wm8Z` 的子 PID 75272 也在中断后退出。 |
| 独立检查 | 当时的一次性检查者原型使用独立 OMP SDK 进程和受限 `read/grep/glob`，只读固定快照。最终模型轮 `/tmp/omp-reviewer-run-4rAd2K` 为 29 PASS、0 FAIL；模型读到快照中的缺陷并给出有效 `correct` 结果，检查前后快照指纹一致。初版原生读取工具可越界，已作为反例保留；该原型当时改用自行限定路径的工具，原型已删除。现行正式实现见 [`runners/omp-reviewer/reviewer.ts`](../../runners/omp-reviewer/reviewer.ts)。 |

OMP 探针与检查者当时各有一次性复跑脚本和逐项原始证据（脚本随原型一并退役，证据仍保留在 `/tmp` 原始输出与验收记录中）。`/tmp/omp-probe.z7QQmz` 出现两次派发，第一支未注册，逐支检查为 FAIL；不计作全绿样本。停止实验早期使用 `sleep`，它在 OMP 内嵌 shell 中没有独立 OS PID；最终改用真实 Python 子进程，分别观察后台 job 与操作系统进程。中途脚本错误样本均未计入通过。

## 正式实施前须闭合的保证

这轮证明**原版 OMP 的接缝可以跑通成功路径和实际停止**，还没有证明 Orbit 的现行运行合同已经由新架构满足：

1. `appendFileSync` 只提供本实验中的同步顺序；正式实现需要写入 TaskStore，并明确崩溃时的持久性。OMP 的 ID 分配器在重名时加后缀，高熵 UUID 只能降低冲突概率；实际 ID 确认失败时，必须保证成员模型工作不能越过登记门。
2. 成员 `before_provider_request` 确认写入失败的负向轮 `/tmp/omp-neg.aQwkuX` 调用了 `ctx.abort()`，成员最终 aborted、无工具或产物；扩展异常被宿主吞并，当前证据无法证明请求未出站。正式实现不能把该钩子当成已验证的失败关闭门。如果原版扩展没有足够接缝，应向上游补充最窄接口或维护最小补丁，不能放宽成员先登记合同。
3. OMP 官方文档指出 `devin-agent` 不触发 `before_provider_request`。依赖该钩子的实现需拒绝这类成员模型，或提供等价且可验证的接缝。其他模型和未来 OMP 版本未实跑；检查者 SDK 固定 18.2.8，升级时应先验证接口与固定版本同步。
4. 当时的 CLI 原型显式加载旧 `plugins/omp.mjs`（该旧入口与原型均已随正式实现退役）；它没有把原生 `task/hub` 与 Orbit 正式状态机、独立检查者、停止判定串成产品链路。当时全局旧扩展仍被普通 `omp` 自动发现，正式安装须取消这条被动接入。

结论：可以开始按 ADR-008 实施正式接线，但**不能把本轮原型当作正式迁移完成**。第一项实现门槛是闭合“实际成员 ID 的失败关闭登记”，然后把原生停止和检查结果接入现行 TaskRuntime；若原版 OMP 官方接口做不到，按已采纳决定评估最小上游补丁／fork。

## M0.4／M2.4 打包与版本锁定补记（2026-09-24）

本节只记录该实施票的实际验证，不改变上文路径原型结论，也不表示目标路径已接通。

**产物与行为**

- `runners/omp-reviewer/package.json` + `bun.lock`：精确 pin `@oh-my-pi/pi-coding-agent@18.2.8`（lockfile 177 条、安装 130 包）；SDK 不进入根 `package.json` 运行依赖，`npm-shrinkwrap.json` 未变。
- 根 `package.json` `files` 纳入 `runners/omp-reviewer` 与 `scripts/orbit-register-member`（后者由 OMP 侧并发加入）。
- `scripts/manage-install.rb`：新增 `bun >= 1.3.14` 前置；`prepare` 在 stage 内 `bun install --frozen-lockfile`（cache 指向 stage），校验 SDK 版本恰为 18.2.8；校验 `scripts/orbit-register-member` 存在且无参可用；`owned_directories` 增加 `runners/omp-reviewer/node_modules`、`.bun-cache`，并兼容旧列表。
- `lib/orbit/omp_entry.rb`：`PINNED_OMP_VERSION`／`PINNED_SDK_VERSION` 均为 18.2.8；`omp --version` 解析失败或与 pin 不同即拒绝启动。`lib/orbit/diagnostics.rb` 报告 `version`／`pinned_version`／`version_ready`。

**隔离真实安装／卸载（HOME 与 runtime/bin 均在临时目录，未动本机安装）**

- `HOME=<tmp> sh install.sh --runtime-dir <tmp>/runtime --bin-dir <tmp>/bin --no-modify-path` → 退出 0；stage 内装入 SDK 18.2.8；在 release 内执行 `bun -e 'import { createAgentSession } …'` 解析成功（`sdk-import-ok function`）。
- staged `scripts/orbit-register-member` 存在且可执行；对含 `state.json` 的临时任务目录真实登记 `orbit-probe-1` → `{"ok":true,…}` 并写入 `members.json`；重复 ID → 退出 1。
- 卸载 → 退出 0；`current`、`runners/omp-reviewer/node_modules`、`scripts/orbit-register-member` 均已清理（该样本无用户文件）。
- 入口版本门在真实进程中执行过：`orbit omp --version`（真实 `omp/18.2.8`）退出 0；PATH 前置 stub `omp/18.3.0` 时退出 1 并明确拒绝启动。
- 两轮隔离安装均成功；持久日志 `/tmp/orbit-m24-results.log` 覆盖第二轮的安装、登记入口与卸载流程。
- 单 release bundle 实测约 932MB（含 SDK 与 stage 内 bun cache），磁盘压力确认前不改变打包方式。

**回归**

- `ruby --disable-gems tests/install_test.rb` 退出 0：含 SDK 版本漂移与 bun 安装失败均保留旧 release 的负例、嵌套依赖目录卸载清理、staged 登记入口校验。
- `ruby --disable-gems tests/omp_entry_test.rb`、`ruby --disable-gems tests/cli_test.rb` 退出 0。
- `npm test` 当时失败于 `tests/omp_test.mjs`（该旧测试与旧入口已随 M3.1 退役）：`plugins/omp-host.mjs` 调用 `sdk.AgentRegistry.global().onChange`，测试替身未提供该方法（`session_start` 触发 `TypeError`）。属 OMP 侧在途改动，补齐替身后需复跑全量；在该失败点之前的既有套件均通过。

**未验证**

- 本机真实安装切换与旧全局扩展清理（M4.3）；隔离项目目标路径端到端（M4.2）。
- reviewer 会话在产品链路中的只读边界与调度接入（M1.4）；本轮只验证 SDK 在 release 内可解析，未运行真实 reviewer 会话。
- 新上游版本的复核与 pin 更新（ADR-008 决定 7）：未对任何非 18.2.8 版本声称支持。

# ADR-014：宿主接口与适配层

状态：提议，2026-10-19。**未采纳**；采纳前现行规则仍以 [ADR-008](008-omp-native-collaboration-base.md)、[任务运行合同](../../contracts/task-runtime.md)与[集成合同](../../contracts/integration.md)为准。

关联：[ADR-010](010-integration-contract.md)（集成合同）、[ADR-011](011-agent-autonomy-and-runtime-responsibility.md)（Agent 判断与程序职责）、[宿主接口与事件通路实施方案](../plan/host-port-and-events.md)（本仓 docs/plan）。

## 背景

Orbit 的核心是 Ruby，但宿主是 OMP。当前耦合集中在少数文件：

- `task_runtime.rb`、`cli.rb`、`diagnostics.rb`、`omp_entry.rb`、`omp_check_runner.rb`、`checker_model_selector.rb` 按 OMP 词计数合计一百多处；
- `plugin_connection.rb` 经私有 socket 调用扩展，协议已经存在，但没有名字、没有合同、没有测试；
- `plugins/omp-host.mjs` 承载宿主内的门与回执（`tool_call`、`before_agent_start`、`before_provider_request`、`context`、`tool_result`、`session_start`、`session_shutdown`）。

结果是：换宿主必须改核心；核心的每次改动都要同时理解 OMP 的钩子语义。Loom 的展示缺口（事件通路）和将来更换宿主的可能性，都要求把“宿主细节”收在一处。

## 决定

**1. 分三层。**

```text
Loom ──只依赖──> Orbit 集成合同
Orbit 核心 ──只依赖──> 宿主接口
宿主细节（OMP / 将来其他）──只出现在──> 适配层
```

适配层包括 `lib/orbit/hosts/<host>/` 与 `plugins/<host>-host.mjs`。

**2. 宿主接口分两半。**

- **控制协议**（运行时 → 宿主）：`contracts/host-port.md` 与 `contracts/host-port.json`。JSON 行协议，请求 `{method, session, ...params}`，返回 `{result}` 或 `{error}`。
- **宿主内义务**（宿主 → 运行时）：H1–H7 与 O1–O4，按必需/可选分级。义务不是函数调用，而是宿主必须提供的拦截、登记、回执、停止与隔离能力。

**3. 能力分级与失败关闭。**

任何宿主须通过一致性测试才能承载受控任务。不满足的义务按级别关闭对应功能，并如实报告，不静默降级：

- 必需义务缺失：不能承载受控任务；
- 可选义务缺失：关闭对应协作，在记录中写明“未送达”或“未提供”。

**4. 当前仍只有 OMP 一个宿主。**

ADR-008 的单宿主决定不变。本 ADR 让更换可行，不预先实现第二个适配层，不同时维护多个宿主。

**5. 核心收口。**

把 `omp_entry.rb`、`omp_check_runner.rb`、`plugin_connection.rb` 移入 `lib/orbit/hosts/omp/`，清理核心文件中的 OMP 专属逻辑，改用宿主接口。检查方式是 grep：核心目录不再出现 OMP 专属名称。

**6. 合同拆分。**

P1 最后一步把 `task-runtime.md` 拆成两份：宿主无关的产品不变量留在现文件，OMP 适配说明（钩子名、SDK 接口名、特定版本行为）移到适配层文档。逐节进行，每条规则只出现一次，不改语义。

## 理由

- **换得起，而不是现在就换。** 宿主接口把“换宿主”从“重写核心”降为“写一个适配层 + 过一致性测试”。
- **一处认识宿主。** 核心不再散落 OMP 钩子名与 SDK 调用，故障定位和升级验证都只在一个目录。
- **不破坏现行语义。** 完成门、停止确认、模型授权、独立检查、成员登记全部保持；本 ADR 只改变事实的暴露方式和代码边界。
- **可验证。** 一致性测试把“宿主能不能承载受控任务”从口头判断变成一组可重跑的探针。

## 后果

- 需要一次协议改名。Ruby 与扩展同包发布，改名一次完成，不保留兼容别名。
- 需要移动文件、清理核心、拆分合同；改动碰停止与登记路径，必须重跑冻结验收 #1（独立检查纠偏）与 #2（真实停止）。
- 需要新建一致性测试目录 `tests/host_conformance/`，并把它接到宿主版本升级流程。
- 核心文件里出现宿主专有名词时应视为回归。
- 本 ADR 不改变 Loom 的集成合同；Loom 仍只依赖 Orbit 集成合同。

## 备选

| 方案 | 不采用的理由 |
| --- | --- |
| 不抽象，继续直接依赖 OMP | 换宿主时重写核心；每次升级仍要逐个文件核对钩子 |
| 用通用插件协议（LSP、ACP 等） | 不覆盖成员、停止确认、模型目录、成员登记这些控制面 |
| 立即并行维护两个宿主 | 成本高，且 ADR-008 明确单宿主 |
| 把宿主接口做成公开集成合同 | 宿主接口是内部架构，不是 Loom 的依赖面；公开会冻结本应随宿主变化的细节 |

## 待决

- 协议改名的最终方法名以 `contracts/host-port.md` 为准，本文只定原则。
- 一致性测试的真实模型部分需要可运行的宿主安装，验收时机另行确认。
- `task-runtime.md` 的拆分范围和顺序，在 P1 开工时逐节确认。

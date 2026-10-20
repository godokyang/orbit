# Goal：在新工作区完成 Orbit 向 TypeScript Core + DSH 的整次迁移

你是实施这次迁移的开发 Agent。目标是完成 ADR-015 及其 2026-10-20 修订定义的整次迁移：B 阶段核心与宿主、C 阶段应用入口与 Loom、D 阶段切换与退场。设计已经定了，不要重开讨论；按阶段推进，一个阶段验收完立即进入下一个，只在第 5 节列出的用户检查点停下。**不要在切片 B 停下。**

## 1. 先读什么（按顺序，读完再动手）

1. `AGENTS.md`、`docs/README.md`、`docs/agents/development-workflow.md`：仓库纪律。
2. `docs/adr/015-typescript-core-and-dsh-migration.md`，重点是"2026-10-20 修订"十条决定，它们覆盖正文中冲突的条款。
3. `docs/plan/dsh-implementation-plan.md`：结构、受控 profile、义务到接缝、停止与日志设计、Loom、凭据、阶段顺序。
4. `docs/plan/dsh-host-probes.md`：已在 DSH 0.2.1-rc.2 上验证的接缝事实与实现约束。探针代码在 `tests/host_conformance/dsh-probe/`，改造成一致性测试。
5. `docs/plan/jev-observation-projection.md`：观察投影单元设计。
6. `contracts/task-runtime.md`（产品语义权威）、`contracts/check-result.schema.json`、`contracts/integration.md` 与 `docs/adr/010-integration-contract.md`（2.0 已于 2026-10-20 冻结，见 ADR-010 与合同变更记录）。
7. ADR-009、011、012、013：模型池、Agent 自主、JEV 用途、终检范围。这些产品语义不随语言改变。
8. DSH 源码 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness/tree/687f282e8625c6b8d11ff58211a90524be2e4317)（提交 `687f282e`）：`docs/architecture.md`、`docs/user/develop/`、`packages/preset/agent-preset/skills/cordis-plugin-development/references/`。DSH 是"一切皆插件"，按它的写法写。
9. Loom 仓库 `/Users/yangke/Personal/workspace/ai-tools/loom`：`AGENTS.md`、`docs/execution.md`、`docs/integration-readiness.md`、`services/node/`。C 阶段才动它。
10. 行为参照：`lib/orbit/*.rb`、`plugins/*.mjs`、`runners/omp-reviewer/`。只参照行为，不逐行翻译，不调用 Ruby。

## 2. 工作区规则（硬性）

Orbit 与 Loom 在现有分支上都有正在运行的实例，**不能影响正常的分支流程**。

- Orbit：不在 `/Users/yangke/Personal/workspace/ai-tools/orbit` 现有工作树里改代码，不碰 `main`。第一步：

  ```sh
  cd /Users/yangke/Personal/workspace/ai-tools/orbit
  git worktree add ../orbit-ts -b feat/ts-core-dsh docs/dsh-typescript-migration-plan
  ```

  之后 Orbit 的所有工作在 `/Users/yangke/Personal/workspace/ai-tools/orbit-ts`，提交只落在 `feat/ts-core-dsh`。
- Loom：现有工作树在 `feat/sso-login` 上有人在用，不碰。C3 开始时从 Loom 的默认分支另建工作树与分支：

  ```sh
  cd /Users/yangke/Personal/workspace/ai-tools/loom
  git worktree add ../loom-orbit-dsh -b feat/orbit-dsh <默认分支>
  ```

  Loom 的所有工作在 `/Users/yangke/Personal/workspace/ai-tools/loom-orbit-dsh`，遵守 Loom 自己的 `AGENTS.md`。
- 两个仓库都不合并、不 rebase 其他分支；推送前向用户报告。
- DSH 相关测试与试跑一律用独立的 `DSH_HOME`（例如 `/tmp/orbit-dsh-dev`），不碰 `~/.dsh`、`desktop` 与 `omdsh` profile，不改用户凭据文件。
- D 阶段之前：不发布 npm 包，不全局安装，不改 `install.sh`，不升 `package.json` 版本，不删除 Ruby/OMP 代码。D 阶段的每个破坏性步骤单独取得用户授权。

## 3. 阶段与范围

### B 阶段：核心与宿主

**B1 切片一。** 用户提出开发要求 → Root 显式 `start` 建立受控任务 → 要求与修订每轮注入 → Root 声明一个工作单元并派发一个本地 spawn 成员 → 成员首次模型调用前完成登记 → 成员交付、Root 接受 → Root 申请终检 → 检查者在独立子进程只读检查并返回结构化结果 → 完成门判定 → 停止收束并确认 → `orbit status`、`orbit stop`、`orbit events` 能看到全部事实。

涉及：`@orbit/core`（任务记录全新格式、要求与修订版本、工作单元与派发登记、检查调度、覆盖/finding/完成门、停止状态机、单一耐久写入口）；`@orbit/dsh-host`（`OrbitService`、启动时 T0 断言、三个预设、实施计划 §3 监听器、§4 围栏与收束、§5 投影与归档、观察投影单元、私有 socket、Root 的 `orbit` 工具）；检查者（`dsh-sdk` 后端指向 `orbit-checker`，只读预设，结果按 schema 校验）；`orbit` 命令 `status`/`stop`/`events`；单一 npm 包与 profile 派生脚本。

**B2 补齐全部现行产品义务。** 以任务运行合同为清单逐项实现并验证：

- JEV 四类用途全部接 TypeSafe（key 走 credentials 引用）：入口判断（H1，仅应用路径，外部集成模式关闭）、观察（用投影单元）、成员选型、检查者选型；按需压缩的 purpose/must_keep 与缓存规则；失败即 unavailable。
- 执行者与检查者候选池、严格模型授权、Root 固定用启动模型、模型证据与质量策略；实际调用、重试、标题等辅助调用分别归账，缺 usage 记 unknown。
- 修订送达 O2、提问 answerer 与跳过追踪 O3、合作政策同层注入 O4；成员互发 O1 显式降级为只经 Root，并在状态与账本里标明。
- 过程检查、终检、续查、结论沿用与撤销、裁定 dispute/ruling、takeover、工作区快照与 rebind、导出；完成与停止分开。
- 一致性测试：T0 组合断言、T1 零模型探针、T2 真实模型场景（S1–S6 的真实模型版）与冻结验收 #1（独立检查纠偏）、#2（真实停止）的 DSH 版本。

### C 阶段：应用入口与 Loom

**C1 应用界面第一版。** 由你自己发挥：任务面板、对话流里的 Orbit 事件行、用户操作（发起受控任务、停止、申请检查、回答提问、确认完成）、设置卡（JEV key、候选池、允许模型）。按 DSH UI 实践：React 组件进 slot、只用主题 token、不 import 宿主 Client 包、对话行经 `ctx.uiConversation.events.register()`；界面不合成完成或停止状态；活动任务不能靠切换预设或关面板绕过停止确认；授权类动作只给用户。做完给用户过目，之后按反馈迭代。

**C2 集成合同 2.0。** 按 DSH 重新设计字段，写 `contracts/integration.md`、`integration.json` 与 ADR-010 变更记录。能力至少覆盖：启动规格、状态、停止回执、事件游标、会话投影（可见文本、用户消息、活动、问题与送达）、提问答复、导出、模型授权；不保留 `session_file`、字节偏移与 `provider="omp"` 假设。定稿前给用户过目。

**C3 Loom 节点迁移。** 在 Loom 工作树里让节点只依赖 2.0 合同：启动改用 `orbit launch` 的 dsh 规格、活动改读 Orbit 能力、送达取证改读 Orbit 能力、删除 OMP 会话文件解析、续接改走 `resume_from`/`resume_wake`、探针改走 `capabilities`/`doctor`；一次改到 2.0，不做 1.x 并行路径。更新 Loom 的 `docs/execution.md` 节点依赖一节与通信核对文档。验证：discovery 三轮问答、执行 run 的提问→答复→采用、停止、续接、运行中重启节点后游标不重不漏，在一个测试项目上真实跑通。

### D 阶段：切换与退场

- 安装与更新：profile 派生脚本、bundle 装入与选中、`orbit doctor`（bundle 已启用 + T0 通过 + DSH 版本报告）。
- 干净切换流程：确认旧 OMP 任务已停止 → 启用新核心 → 新任务由新核心拥有；安装或升级失败不破坏记录。
- 退场：删除 Ruby 执行代码、OMP 插件、`runners/omp-reviewer`、`install.sh` 的 Ruby 与 OMP 探测、OMP 专用测试；`contracts/host-omp.md` 替换为 `host-dsh.md`；README 与使用参考改写。
- 版本号与发布由用户决定并执行；每个删除步骤先列清单取得授权。

## 4. 实施顺序

B1 → B2 → C1 → C2 → C3 → D。B1 内部：工具链与骨架（pnpm workspace、`packages/core`、`packages/dsh-host`、`packages/cli`，Node 22 以上，vitest，tsdown，编译在 DSH 导出类型上）→ Core 域逻辑与单元测试 → 宿主插件先过探针级 T0/T1 再接 Core → 检查者 → CLI → 真实模型验收。DSH 跟最新版本；每次升级 DSH 先跑 T0/T1。

## 5. 用户检查点（只在这些事上停下来问）

1. npm scope 与包名（B1 开工时问一次）。
2. 真实模型的路由与 key，或授权把凭据配进隔离 home（B1 真实验收前）。
3. 应用界面第一版过目（C1 结束）。
4. 集成合同 2.0 定稿（C2 结束）。
5. Loom 默认分支确认与推送授权（C3 开始与结束）。
6. D 阶段每个删除、安装切换、版本号与发布动作的授权。
7. 任何会改变产品语义的取舍。

其余自己决定并记录。

## 6. 验收

- 每阶段：T0 与 T1 在隔离 `DSH_HOME` 全绿；该阶段的真实模型路径跑通一次。
- B 结束：合同里的每条义务都有对应实现与验证记录；冻结验收 #1、#2 的 DSH 版本通过。
- C 结束：独立应用路径与 Loom 路径进入同一证据体系；Loom 整链真实通过。
- D 结束：新安装只依赖 DSH 与单一 npm 包；仓库里没有 Ruby/OMP 执行代码；`orbit doctor` 与 README 与现实一致。
- 任何时候：停止确认按实施计划 §4 的证据清单给出，缺项即 `stop_unconfirmed`；完成门只在有效终检通过且停止确认后给 `complete`。

## 7. 纪律

- 产品语义的改动先写进 ADR 或合同再实现；实施中新做的技术决定回写 `docs/plan/dsh-implementation-plan.md` 新增的"实施决定"小节，带日期。交接与验证记录写进 `docs/plan/handoff.md`。
- 新增测试每次建议不超过 10 个、300 行；只测业务规则与真实回归风险，不为覆盖率写测试。
- 探针记录里的实现约束必须遵守：每条注入消息完整 `{id, role, content, source}`；`llm/stream` 监听器同步；不向 DSH 会话日志追加自定义事件类型；读路径限制由 guard 做；工具参数名以 schema 为准；`dshBin` 必须是 JS 入口；外部插件文件要在 profile 目录下才能解析 DSH 包。
- 失败关闭：耐久写失败即拒绝新派发与工具；未知保持 unconfirmed；不把 DSH 的 completed 或 idle 当业务接受。
- 每完成一个阶段报告四件事：做了什么、验证了什么、未验证什么、需要用户决定什么。不宣称未验证的东西已通过。

# Goal：在新工作区实施 Orbit TypeScript Core + DSH 切片 B

你是实施这份计划的开发 Agent。目标是把 Orbit 的 TypeScript Core 与 DSH 宿主插件做到能在 DSH 上跑通第一个真实受控任务。范围、顺序、验收、工作区规则都在下面；设计已经定了，不要重开讨论，遇到设计没覆盖的事按"纪律"一节处理。

## 1. 先读什么（按顺序，读完再动手）

1. `AGENTS.md`、`docs/README.md`、`docs/agents/development-workflow.md`：仓库纪律。
2. `docs/adr/015-typescript-core-and-dsh-migration.md`，重点是"2026-10-20 修订"十条决定。它们覆盖正文中冲突的条款。
3. `docs/plan/dsh-implementation-plan.md`：结构、受控 profile、义务到接缝、停止与日志设计、阶段顺序。
4. `docs/plan/dsh-host-probes.md`：已在 DSH 0.2.1-rc.2 上验证过的接缝事实与实现约束。探针代码在 `tests/host_conformance/dsh-probe/`，可以直接改造成一致性测试。
5. `docs/plan/jev-observation-projection.md`：观察投影单元的字段、窗口、游标、去重键。
6. `contracts/task-runtime.md`：产品语义的权威；`contracts/check-result.schema.json`：检查结果格式。
7. DSH 源码在 `~/Workspace/deepseek-harness`（提交 687f282e）：`docs/architecture.md`、`docs/user/develop/`、`packages/preset/agent-preset/skills/cordis-plugin-development/references/practices.md`。DSH 是"一切皆插件"，按它的写法写。
8. 行为参照：`lib/orbit/*.rb`、`plugins/omp-host.mjs`。只参照行为，不逐行翻译，不调用 Ruby。

## 2. 工作区规则（硬性）

- Orbit 与 Loom 在现有分支上都有正在运行的实例。**不在 `/Users/dy/Workspace/orbit` 现有工作树里改代码，不碰 `main`，不碰 Loom 仓库。**
- 第一步新建独立工作树与分支：

  ```sh
  cd /Users/dy/Workspace/orbit
  git worktree add ../orbit-ts -b feat/ts-core-dsh docs/dsh-typescript-migration-plan
  ```

  之后所有工作在 `/Users/dy/Workspace/orbit-ts`。提交只落在 `feat/ts-core-dsh`；不合并、不 rebase 其他分支；推送前向用户报告。
- DSH 相关的测试与试跑一律用独立的 `DSH_HOME`（例如 `/tmp/orbit-dsh-dev`），不碰 `~/.dsh`、`desktop` 与 `omdsh` profile，不改用户的凭据文件。
- 不发布 npm 包，不全局安装，不改 `install.sh`，不升 `package.json` 版本，不删除 Ruby/OMP 代码（开发期保留作参照，退场是 D 阶段的事）。

## 3. 切片 B 的范围

做到这一条用户路径在 DSH 上真实跑通：用户提出开发要求 → Root 显式 `start` 建立受控任务 → 要求与修订每轮注入 → Root 声明一个工作单元并派发一个本地 spawn 成员 → 成员首次模型调用前完成登记 → 成员交付、Root 接受 → Root 申请终检 → 检查者在独立子进程只读检查并返回结构化结果 → 完成门判定 → 停止收束并确认 → `orbit status`、`orbit stop`、`orbit events` 三条命令能看到以上全部事实。

包含：

- `@orbit/core`（宿主无关）：任务记录（全新格式，按 TS 需要设计，不兼容旧记录）、要求与修订版本、工作单元与派发登记、检查调度、覆盖/finding/完成门、停止状态机、单一耐久写入口（原子写 + lease）。
- `@orbit/dsh-host`：`OrbitService extends Service`（ctx key `orbit`）；启动时的 T0 组合断言；`orbit-root`/`orbit-member`/`orbit-checker` 三个预设；实施计划 §3 的监听器；§4 的围栏与收束；§5 的 A 层投影与 B 层归档；观察投影单元 `orbitObservation`；私有控制 socket；Root 可用的 `orbit` 工具（start、amend、work_unit、dispatch、check、complete、status）。
- 检查者：`dsh-sdk` 后端实例指向 `orbit-checker` profile，只读预设，结果按 `check-result.schema.json` 校验；发行物依赖 `@deepseek-ai/dsh-subagent-dsh-sdk` 与 `@deepseek-ai/dsh-sdk-client`。
- `orbit` 命令：`status`、`stop`、`events`，读任务目录，必要时经 socket 调活插件。
- 包装：单一 npm 包，`dsh.bundle.patch` 指向 cordis.patch.yml；一个脚本从 DSH 模板派生 `orbit-app`、`orbit-node`、`orbit-checker` 并把 bundle 写进 profile 清单。

不包含（后续阶段）：应用 UI、Loom、集成合同 2.0、自动入口判断（H1）、JEV 的 HTTP 调用、成员互发、历史兼容、安装脚本、Ruby 退场。观察投影单元要做，但不接 TypeSafe。

## 4. 实施顺序

1. 工具链与骨架：pnpm workspace，`packages/core`、`packages/dsh-host`、`packages/cli`，Node 22 以上，vitest，tsdown，编译在 DSH 导出类型上。npm scope 问用户一次。
2. Core 域逻辑与单元测试。行为参照 Ruby 实现与合同，接口按 TS 自然形状设计。
3. 宿主插件：先让 T0 断言、登记门、工具门、围栏在探针级别通过（改造 `tests/host_conformance/dsh-probe/` 为可重复的 T1），再接 Core。
4. 检查者子进程与结果校验。
5. 三条 CLI。
6. 真实模型验收：先向用户要一条可用的模型路由与 key（或授权把凭据配进隔离 home），然后跑第 3 节那条完整路径，并重跑冻结验收 #1（独立检查纠偏）与 #2（真实停止）的 DSH 版本。

## 5. 验收

- T0 与 T1 在隔离 `DSH_HOME` 下全绿。
- 第 3 节的路径用真实模型跑通一次，`status`、`stop`、`events` 的输出与任务目录里的记录一致。
- 停止确认按实施计划 §4 的证据清单给出结果；任何缺项必须是 `stop_unconfirmed`，不得伪造确认。
- 完成门只在有效终检通过且停止确认后给 `complete`。

## 6. 纪律

- 产品语义的改动先写进 ADR 或合同再实现；实施中新做的技术决定回写到 `docs/plan/dsh-implementation-plan.md` 新增的"实施决定"小节，带日期。
- 新增测试每次建议不超过 10 个、300 行；只测业务规则与真实回归风险，不为覆盖率写测试。
- 探针记录里的实现约束必须遵守：每条注入消息完整 `{id, role, content, source}`；`llm/stream` 监听器同步；不向 DSH 会话日志追加自定义事件类型；读路径限制由 guard 做；工具参数名以 schema 为准（bash 必填 `description`，read 用 `file_path`）；`dshBin` 必须是 JS 入口。
- 失败关闭：耐久写失败即拒绝新派发与工具；未知保持 unconfirmed；不把 DSH 的 completed 或 idle 当业务接受。
- 只在这些事上问用户：npm scope；真实模型的路由与 key；任何会改变产品语义的取舍。其余自己决定并记录。
- 每完成一个阶段报告四件事：做了什么、验证了什么、未验证什么、需要用户决定什么。不宣称未验证的东西已通过。

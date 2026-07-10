# Orbit 优化修改方案

> 汇总依据：
>
> - [12-orbit-skill-retrospective.md](12-orbit-skill-retrospective.md)：实际使用、自检、真实产品流程与成本复盘。
> - [user-perspective-functional-review-2026-07-10.md](user-perspective-functional-review-2026-07-10.md)：基于代码、设计和真实 CLI 旅程的用户视角功能评估。

## 1. 总体判断

Orbit 不应该继续扩展成“所有任务都走完整协议”的操作系统，而应收敛成：

> **按风险启用、以用户结果为完成标准、能力边界诚实、状态清晰可见的 agent 质量治理工具。**

当前 Orbit 已经能够有效处理身份、角色、task revision、evidence、gate、audit 和 handoff 的结构一致性，但这些收益被以下问题抵消：

1. 技术动作完成与真实用户问题解决之间仍有距离。
2. 产品设计假设 automatic runtime 可用，实际主要依靠 manual protocol。
3. 不同风险的任务承担了近似的协议成本。
4. evidence 数量很多，但与真实 artifact、代码版本和用户旅程绑定不足。
5. 内部状态丰富，用户却很难快速知道谁在工作、卡在哪里、下一步做什么。

因此，后续优化不应继续横向增加 schema 字段，而应优先改变这些系统性质。

## 2. Quality Outcome

### 用户问题

Orbit 能提高高风险工程任务的质量，但当前流程过重、状态不透明、自动运行能力不可达，且 gate 通过仍不能保证真实用户主流程可用。用户需要持续理解 identity、pane、task hash、evidence 和 gate 等内部细节，才能判断任务是否真的完成。

### 期望性质

改造后的 Orbit 应满足：

- 小任务几乎没有额外负担，高风险任务才启用完整门禁。
- `done` 代表真实用户路径成立，而不只是测试、构建和报告齐全。
- 用户一眼能看懂谁在工作、当前卡点和下一步。
- manual 模式可以独立、稳定使用。
- automatic 能力只有真正可用时才对外宣称。
- evidence 能绑定真实 artifact、代码版本和 task revision。
- 长期保留的是精简知识，而不是大量重复 runtime 文件。

### 无效完成方式

以下情况不能视为优化完成：

- 只增加状态面板，但不改变错误的完成语义。
- 只压缩文件，却继续允许空 acceptance 进入执行。
- 通过放宽 gate 让 solo task 显示完成。
- 只增加更多关键词修补意图分类。
- runtime 仍不可达，却继续报告 `direct.dispatch` 可用。
- 只证明回归测试通过，没有证明真实用户旅程改善。

## 3. P0：修正完成语义和风险分级

### 为什么要改

两份评估共同指向一个根因：Orbit 对所有任务使用近似相同的重流程，同时又允许缺少具体用户结果的 task 通过结构校验。

这导致：

- 小任务的流程成本超过质量收益。
- 高风险任务可能严格地验证了错误目标。
- UI、真机和跨端主流程仍会在 gate 后暴露明显问题。

### 怎么改

不新增平行的 A/B/C 风险枚举，直接复用现有风险模型：

| 现有风险级别 | 用户侧档位 | 默认流程 |
| --- | --- | --- |
| `light` | C：轻量修改 | 不创建正式 task，只记录一句结果和验证 |
| `standard` | B：普通功能 | 精简 task + implementation + review/test 二选一 |
| `strict` / `release` | A：高风险 | implementation + 独立 review + 独立 test + audit/handoff |

为 task 增加结构化变更表面：

```yaml
change_surface: internal | api | user_flow | data | security | release
risk_sinks:
  - auth
  - money
  - privacy
  - migration
  - destructive
  - concurrency
real_path_required: true | false
```

增加两级校验：

- `draft-valid`：只验证 schema，允许模板占位。
- `execution-ready`：启动执行前必须有具体 user problem、required outcomes、acceptance、evidence requirement 和 traceability。

`state start` 必须自动调用 execution-ready 校验。standard 以上 task 如果仍使用默认占位文案或空 acceptance，不能进入 `working`。

主要修改位置：

- `lib/orbit/project_profile_risk.rb`
- `lib/orbit/task_launch_dispatch.rb`
- `lib/orbit/validate_task_contract.rb`
- `lib/orbit/state_validate_gate.rb`
- task 模板及风险相关测试

### 验收标准

- `light` 修改不产生完整 task/evidence/rules/handoff。
- standard 任务未经业务填写不能启动。
- user-flow、跨端、鉴权、收益、隐私等任务不能被降级为纯技术验收。
- 风险档位由结构化字段决定，不依赖自然语言关键词。

## 4. P0：修复状态可见性和 solo 闭环

### 为什么要改

用户多次需要追问当前 goal、coder 是否工作、gate 为什么卡住，说明内部状态没有被产品化。

Solo 当前也只有“谁实现”的语义，没有“如何结束”的语义：缺少独立角色时只能永久停留在 `working`，或者冒险放宽 gate。

### 怎么改

新增两个只读入口：

```text
orbit status
orbit next
```

`status` 默认输出一屏人类摘要：

- 当前 task、风险级别、operation mode。
- 当前 role/instance 及 `manual | pending | verified`。
- implementation/review/test 最新状态。
- 未关闭的 High/Medium finding。
- 当前 blocker。
- 下一条建议命令。

状态必须从已有 task/state/evidence/runtime resolver 派生，不能建立新的状态事实源。

Solo 明确拆成两种结果：

1. `solo-implementation`
   - lead 完成实现和自测。
   - 最终状态为 `implemented_not_independently_accepted`。
   - 可以交接，但不能包装成完整完成。
2. `solo-assisted-review`
   - 自动或手工拉起 fresh-context reviewer/tester。
   - 只有独立 gate 通过后才能进入 done。
   - 拉起失败时显示明确 blocker 和修复命令。

### 验收标准

- 用户不读取 JSON 即可知道当前状态和下一步。
- 没有独立验收时，状态不会长期停留在模糊的 `working`。
- `implemented_not_independently_accepted` 不得被 audit/handoff 表述为完整完成。
- 状态面板不复制或修改权威 task/evidence/state。

## 5. P0：让 manual/automatic 能力边界真实

### 为什么要改

当前实现中 trusted caller proof 固定不可用，`dispatch_ready` 无法进入 true；但安装仍强制依赖 Herdr，工具检测还会宣称存在 `direct.dispatch`。

这同时伤害了两类用户：

- 只想使用 manual protocol 的用户无法正常安装。
- 期待 automatic runtime 的用户获得了无法兑现的能力承诺。

### 怎么改

明确三种运行模式：

- `manual`：当前稳定模式，不依赖 Herdr。
- `automatic-preview`：可以启动 pane，但不承诺 verified identity/direct dispatch。
- `automatic`：只有 provider E2E 通过后才能启用。

具体修改：

- `install.sh --mode manual|automatic`，manual 为可独立安装路径。
- `tools detect` 根据 resolver 能力报告，而不是只检查 Herdr 命令是否存在。
- 没有 trusted proof 时不输出 `direct.dispatch` capability。
- `start` 输出清晰的 capability degradation，而不是要求用户理解内部 session 字段。
- skill 中默认把 manual 描述为稳定路径，automatic 描述为 preview。

### 验收标准

- 没有 Herdr 时可以安装并完成 manual workflow。
- trusted proof 不可用时，任何命令都不会声称 direct dispatch 可用。
- automatic-preview 产生的 evidence 不会被误认为 verified evidence。

## 6. P0：把真实用户旅程变成硬 gate

### 为什么要改

复盘中最严重的信任问题不是协议报错，而是 task、report 和测试都完成后，Android/Web 第一遍真实使用仍出现崩溃、入口错误、视频不可见、信息密度过高等问题。

这说明现有 gate 主要验证“执行了什么”，没有验证“用户完成了什么”。

### 怎么改

为 user-facing 和跨系统 task 引入结构化用户旅程：

```yaml
user_journeys:
  - id: upload_and_review
    actor: collector
    surface: android_to_web
    steps: []
    expected_observables: []
    required_evidence: provider_e2e
```

Test report 增加：

- `user_outcomes`
- `journey_id`
- 实际步骤与结果
- 截图、崩溃日志、网络请求、媒体状态
- 设备/浏览器/服务版本
- 未覆盖路径

Orbit 本身不负责实现所有平台测试器，而是提供项目级 hook：

- Android：ADB、instrumentation 或项目测试脚本。
- Web：浏览器自动化。
- 跨端：Android → API → worker → storage → Web 的组合脚本。

如果 `real_path_required: true`，缺少对应 journey evidence 时只能是 `partial`，不能关闭 test gate。

### 验收标准

- UI 或跨端任务不能用 build/unit test 代替真实路径。
- gate 报告首先说明用户完成了什么，其次才列执行命令。
- 真机/浏览器失败与 artifact 状态不一致时 fail closed。
- 30 天试用期间，gate 后由用户发现的 P0/P1 问题明显下降。

## 7. P1：让 evidence 绑定真实事实

### 为什么要改

当前 evidence 对身份、schema 和 task hash 校验很严格，但 artifact 大多仍是自由文本路径。格式正确不等于事实真实。

### 怎么改

统一使用结构化 artifact reference：

```yaml
artifact:
  path: relative/path
  sha256: ""
  producer_command: ""
  created_at: ""
  git_head: ""
  task_revision: ""
  lifecycle: transient | durable
```

同时要求：

- implementation pass 必须包含 changed files 和 verification，或明确 no-change reason。
- review/test 必须引用 implementation artifact。
- validator 检查文件存在、hash、git head、生成时间和 task revision。
- 失败 artifact 不得被后续成功运行覆盖。
- 大日志和截图只保存引用与 hash，不写入长期 summary。

### 验收标准

- artifact pass 可验证文件存在、hash、task revision 和 git head。
- 不存在或已变化的 artifact 不能继续支持 pass verdict。
- review/test 能追溯到当前 implementation 和真实测试输出。

## 8. P1：建立 revision 和耐久知识模型

### 为什么要改

当前 `.orbit` 有大量重复 rules、evidence、report 和 handoff，但全部被 Git 忽略并包含绝对路径。它承担了记录成本，却没有形成可靠的跨机器知识。

### 怎么改

- task 启动后冻结 `revision_id`。
- 范围或 acceptance 变化时创建新 revision，并记录变更原因。
- evidence 绑定具体 revision。
- 根据变更类型精确失效相关 gate，避免所有旧 evidence 模糊失效。
- rules resolution 按 `(task revision, role, rules hash)` 缓存，禁止重复生成。
- loop state、handoff 使用项目相对路径。
- 统一 `handoff/` 和 `handoffs/`。
- 每个任务只生成一份 durable compact summary；原始 runtime artifact 保持本地和可清理。
- durable summary 放在可配置、可版本化的位置，而不是强制依赖被忽略的 `.orbit/`。

### 验收标准

- 新任务不再为同一 revision/role/rules hash 重复生成 resolution。
- 换机器或重新 clone 后，能从 compact summary 理解任务结论和剩余风险。
- B 类任务的 durable artifact 控制在少量文件内。
- 所有持久路径均为项目相对路径。

## 9. P1/P2：压缩 CLI 和 Skill 认知成本

### 为什么要改

这不会直接提高 gate 正确性，但会显著减少用户追问、agent token 消耗和误操作，是 Orbit 能否长期默认启用的决定性因素。

### 怎么改

- 增加 `orbit task draft` 和 `orbit task start` 高层命令。
- `task start` 统一完成 execution-ready 校验、evidence 初始化、rules 解析和 state start。
- 人类输出默认精简，完整协议通过 `--json` 或 `--verbose` 获取。
- 所有一级命令统一支持 `--help`。
- skill 主文件只保留触发边界、档位选择和最小流程；角色细则按需加载。
- `rules print-context` 默认只输出 active required files、hash 和冲突。

### 验收标准

- 常见手工任务从 init 到可执行状态不超过 5 条命令。
- `orbit status` 默认输出不超过一屏。
- 所有一级命令的 `--help` 行为一致。
- B/C 类任务的上下文和 artifact 数量显著下降。

## 10. P2：重做意图分类，而不是继续加关键词

### 为什么要改

关键词分类无法可靠判断真实风险。继续扩展词表只会制造更多语言补丁，无法解决机制问题。

### 怎么改

- 分类结果返回全部命中信号和冲突，不再取第一个关键词。
- `问题` 不再单独代表 discussion。
- 支持 `--intent` 显式覆盖并记录原因。
- 风险等级最终由 task 的结构化 surface/risk sinks 决定。
- 自然语言分类只用于建议，不得直接关闭或跳过 gate。

### 验收标准

- `修复这个问题`、`审视当前项目`、`评估功能效果` 不再被降级为 discussion/light。
- 分类冲突可见且可以显式覆盖。
- 分类器不能替代 task 的结构化风险合同。

## 11. Automatic runtime 的最终改造

可信 runtime identity 仍然重要，但不应该阻塞前面的 manual 产品价值。

实施顺序：

1. 先让能力报告诚实。
2. 再定义 Herdr 与 Orbit 的可信握手协议。
3. 使用 nonce、project hash、instance hash、短 TTL 和受控签发。
4. 最后增加真实 provider E2E：

```text
start
→ verified identity
→ dispatch_ready
→ direct dispatch
→ reviewer/tester evidence submit
→ wait-gate ready
```

只有这条路径稳定通过，automatic 模式才能从 preview 升级为正式能力。

## 12. 推荐实施顺序

### 里程碑 1：可用且诚实的 Manual Orbit

- 风险分级。
- execution-ready 校验。
- manual 安装。
- 能力检测修正。
- `status` / `next`。
- solo 结果语义。
- CLI help 一致化。

这一阶段先解决用户能否理解、信任和持续使用 Orbit 的问题。

### 里程碑 2：结果可信

- 用户旅程合同。
- project test hooks。
- 结构化 artifact reference。
- implementation/review/test 事实交叉校验。
- UI/跨端真实路径 gate。

这一阶段确保 Orbit 证明的是用户结果，而不是流程动作。

### 里程碑 3：低成本、可持续

- task revision。
- rules 缓存与去重。
- transient cleanup。
- 相对路径。
- durable compact summary。
- skill/context 瘦身。

这一阶段在证据 schema 稳定后降低长期成本，避免先压缩错误的数据模型。

### 里程碑 4：正式 Automatic Runtime

- Herdr trusted proof。
- verified direct dispatch。
- completion acknowledgement。
- provider E2E。

这一阶段依赖外部 runtime 的可信证明能力，因此不应阻塞前面三个里程碑。

## 13. 为什么按这个顺序实施

1. **先修完成语义**：如果 task 的目标和 acceptance 本身不可信，后续状态面板、自动派单和 artifact 优化只会更高效地执行错误流程。
2. **再修状态与能力边界**：用户需要先看懂当前系统实际能做什么，才能恢复对流程的信任。
3. **再绑定真实用户结果和 evidence**：完成语义稳定后，才能确定需要保存哪些证据以及如何关闭 gate。
4. **再做 revision、压缩和耐久化**：证据模型稳定后再优化存储，避免为旧 schema 建立新的兼容负担。
5. **最后完成 automatic runtime**：它依赖 Herdr 的可信 proof provider，技术不确定性最高，不应拖住 manual 模式的产品价值。

## 14. 30 天试用指标

需要从改造前开始记录：

- 每类任务增加的时间和 token。
- 每个 task 的 artifact 数量和体积。
- implementation 到最终 gate 的等待时间。
- identity/schema/task revision 导致的失败次数。
- reviewer/tester 发现的独立缺陷数。
- gate 后仍由用户发现的 P0/P1 缺陷数。
- 用户询问“当前状态/下一步/谁在工作”的次数。
- automatic session 中进入 verified 的比例。

继续保留完整 Orbit 的条件：

- A 类任务持续发现现有测试未覆盖的真实缺陷。
- Android/Web gate 后的用户级回归明显下降。
- 用户不再需要反复询问角色、goal 和下一步。
- B/C 类任务的流程成本明显下降。
- automatic runtime 不再长期停留在 manual/identity pending。

考虑只保留精简检查清单的条件：

- 多数任务只生成重复报告，没有独立 finding。
- UI/真机问题仍主要依赖用户在 gate 后发现。
- runtime identity 仍无法稳定自动建立。
- artifact 和上下文增长明显快于有效决策。
- 轻量 task + 独立 E2E review 能稳定取得相同结果。

## 15. 最终建议

保留 Orbit，但立即调整产品重心：

1. 从“默认完整协议”转为“按风险启用”。
2. 从“技术动作完成”转为“真实用户结果完成”。
3. 从“内部状态丰富”转为“用户状态清晰”。
4. 从“automatic 名义可用”转为“manual 稳定、automatic 诚实预览”。
5. 从“保存所有过程文件”转为“保存可复核的耐久知识”。

完成前三个里程碑后，再用 30 天数据判断完整 Orbit 是否值得长期保留；在此之前，不应继续横向增加更多协议字段或默认 gate。

## 16. 实施状态（2026-07-10）

本方案的工程改造已全部落地，按独立功能提交并推送到 `V1`。原始“为什么要改”和验收标准保留在上文；下表记录实现证据，而不是重写方案。

| 调优项 | 状态 | 实现提交 | 主要验收证据 |
| --- | --- | --- | --- |
| 风险分级与 execution-ready | 已实现 | `b9e500d` | `tests/parts/14_project_profile_risk.sh`：结构化 surface/sink、draft/execution-ready、standard 占位阻断、light 策略 |
| manual / automatic 能力真实性 | 已实现 | `2046712` | `tests/parts/01_installer.sh`：无 Herdr manual 安装闭环、preview 不暴露 direct dispatch |
| 状态可见性与 solo 完成语义 | 已实现 | `9fcbde1` | `tests/parts/20_status_solo.sh`：一屏 status/next、只读派生、`implemented_not_independently_accepted` |
| 真实用户旅程硬 gate | 已实现 | `d7c9b5b` | `tests/parts/21_user_journey.sh`：journey hook、技术 pass 降级、artifact 矛盾 fail closed |
| evidence 与真实 artifact 绑定 | 已实现 | `f5bbed9` | `tests/parts/22_artifact_provenance.sh`：文件/hash/git/revision 校验、implementation/review/test 交叉引用 |
| task revision 与耐久知识 | 已实现 | `e4604ee` | `tests/parts/23_revision_knowledge.sh`：精确失效、rules cache、相对路径、单一 summary、受控清理 |
| 高层 CLI 与 Skill/context 瘦身 | 已实现 | `e42f3a1` | `tests/parts/24_task_workflow.sh`：3 条命令进入执行、统一 help、精简输出、跨 task cache 隔离 |
| 可审计意图分类 | 已实现 | `6d8e42d` | `tests/parts/25_intent_classification.sh`：全部信号/冲突、带理由覆盖、task 风险权威、三个中文反例 |
| 正式 automatic runtime | 已实现 | `2864f31` | `tests/parts/26_automatic_runtime.sh`：nonce/project/role/instance/pane/TTL、重放/撤销、direct dispatch、evidence、gate、ack 完整 E2E |
| 30 天试用指标采集 | 已实现 | `0f583fc` | `tests/parts/27_trial_metrics.sh`：8 类指标、30 天窗口、缺失覆盖可见、无 prompt/自由文本落盘 |
| 状态 transition 最终加固 | 已实现 | `5fc2ced` | `tests/parts/24_task_workflow.sh`：高层 start 挂载的 rules/evidence 可继续用于 solo 结果 transition |
| 任务身份与证据域隔离 | 已实现（复核加固） | `89be7b8` | 不可变 `task_id` 贯穿 revision/evidence/artifact/cache/state/handoff；非空跨任务 evidence 在 revision freeze 前拒绝 |
| revision 全字段 fail-closed | 已实现（复核加固） | `89be7b8` | 单一字段映射覆盖模板；`execution_contract` 有明确失效语义；未知字段和 task_id 变更拒绝 |
| runtime proof 生命周期 | 已实现（复核加固） | `d8b6bae` | 一次性 challenge 兑换 300 秒 renewable session attestation；本地过期优先于 provider valid |
| 试用指标配对与仲裁 | 已实现（复核加固） | `27e8b1d` | snapshot 按 `task_id + stage` 配对，报告 baseline/after/delta、分母与 missing/observed_zero；gate wait 使用当前 revision 仲裁 |
| 稳定知识进入版本历史 | 已实现（复核加固） | 本文档提交 | 本方案、两份评估、ADR 与 `.orbit/README.md` 进入 Git；运行缓存继续本地化 |
| 父任务进度与 revision 隔离 | 已实现（收尾加固） | `9da93d4` | `parent_goal` 合同留在 task，动态 `parent_goal_status` 进入 loop state；冻结任务 progress 后哈希不变且 validate 通过 |
| 零事件计数的独立观测分母 | 已实现（收尾加固） | `4573d22` | baseline/after 配对任务作为观测分母，失败、缺陷、用户追问事件只作为指标值；零事件报告 `observed_zero` |
| next action 动态实例解析 | 已实现（收尾加固） | `fad1940` | 从缺失 gate 的 roles 和 `instances.yaml` 解析目标；多实例时返回候选并要求选择，不生成虚假 dispatch 命令 |
| 指标分子与 paired cohort 对齐 | 已实现（边界加固） | `4b9d5f1` | 四类 task-scoped count event 强制绑定不可变 `task_id`；只统计 paired task IDs，并单列 unbound/out-of-cohort 事件 |
| progress 显式 task 一致性 | 已实现（边界加固） | `1351c70` | 在原子 state 写入前同时核对 canonical task path 和 `task_id`；不匹配时 state 哈希保持不变 |
| gate role 兼容归一化 | 已实现（边界加固） | `fc9ca68` | status 与 validator 共用单复数 role normalizer，实例通过 `role_for_instance_config` 解析；唯一候选直接 resolved |
| unbound 指标事件 fail-closed | 已实现（决策边界加固） | `bfce67a` | unbound task-scoped event 不进入 paired cohort 分子，同时把顶层状态降为 `ambiguous_event_scope`；已绑定的 out-of-cohort 事件仍可安全排除 |
| trial report 语义自描述 | 已实现（兼容边界加固） | `bfce67a` | standalone report 升级为 `orbit-trial-metrics-report-v2`，并携带 `schema_semantics.feature_versions.trial_metrics: v4` |
| gate role 原始合同校验 | 已实现（合同边界加固） | `9c17542` | validator 逐项检查原始 roles 数组，只在合同合法后由 runtime normalizer 消费；混合合法/非法值不再被静默过滤 |

本轮复核加固后的最终完整回归为 `REAL_TESTS_PASS count=1098`。测试同时保留了旧 Herdr、无 provider、手写 `herdr_verified`、identity pending、artifact 漂移、跨任务证据复用、凭证本地过期和真实路径缺失等负向场景，避免新能力通过放宽旧 gate 获得绿色结果。

### 当前产品行为

- `manual` 仍是无 Herdr 依赖的稳定路径。
- 旧 Herdr 或 provider E2E 未通过时保持 `automatic-preview`，不暴露 `direct.dispatch`。
- Herdr 实现受控 `orbit-proof status/prove/verify` 且完整 E2E 为 pass 时，Orbit 才进入 `automatic`；resolver 会持续复核 proof，失效后立即 fail closed。
- 常见正式任务使用 `orbit task draft` → 填写业务合同 → `orbit task start`；从 init 计共 3 条 Orbit 命令。
- 轻量问答/低风险一次性修改由 trigger/classifier 保持非正式路径，不强制创建完整 task。
- `parent_goal` 是冻结 task 中的合同；`parent_goal_status` 是 loop state 中的动态执行状态。进度心跳不会再造成 task revision 漂移。
- `state progress --task ...` 是兼容入口，但显式 task 必须与 loop state 的 current task 在 canonical path 和不可变 `task_id` 上同时一致，否则在写入前拒绝。
- `orbit next` 根据归一化 gate role 查找真实配置实例，兼容 `roles: [...]` 和旧 `role: ...`；唯一实例可直接生成 dispatch 建议，多实例必须先由用户选择。
- `orbit metrics capture|record|report` 从现在开始收集 30 天试用所需的结构化计数，不保存 prompt、报告正文或自由文本；成本类 snapshot 必须形成同一 `task_id` 的 baseline/after 配对后才进入变化量统计，计数类指标强制绑定 task，并且只有 paired task cohort 内的事件进入分子。已绑定的 out-of-cohort 事件单独报告并安全排除；旧 unbound 事件虽然不进入分子，但会将报告降为 `ambiguous_event_scope`，避免把未知归属误报为零缺陷。
- 新生成的指标报告使用 `orbit-trial-metrics-report-v2`，并在报告自身声明 `trial_metrics: v4`。v1 报告只代表旧 global-count/非自描述语义，必须从原始 JSONL 重新生成，不能直接作为 cohort-safe 决策输入；旧 v1 event ledger 仍可读取，但其中 unbound task-scoped event 必须先备份账本并完成经核验的显式 task 迁移，不能由报告器猜测归属。当前版本不提供 event-scope waiver 入口。

### 尚需真实观察期验证的结果

工程验收通过不等于 30 天业务结果已经发生。以下趋势必须通过真实项目试用观测，不能用仓库测试伪造：

- gate 后用户发现的 P0/P1 缺陷是否下降；
- B/C 类任务的实际时间与 token 成本是否下降；
- 用户追问状态、下一步和执行者的次数是否下降；
- production Herdr automatic session 的 verified 比例是否稳定；
- 完整 Orbit 相比精简检查清单是否持续产生独立有效 finding。

用 `orbit metrics report --window-days 30 --json` 查看覆盖状态。`observed_zero` 表示已经观测但变化量或计数为零，`missing` 才表示没有数据；只有 `observation_status` 明确为 `ready_for_trial_decision`，且真实趋势满足第 14 节条件后，才能作出长期保留或进一步精简的产品决策。`ambiguous_event_scope` 表示仍有未绑定事件，必须先完成经核验的显式迁移，不能把局部 `observed_zero` 当成可决策结论。

# Quality Outcome And Review

本文定义改善类任务的 Quality Outcome Contract 和 review 行为。它解决的问题是：agent 完成了字面动作，但软件质量没有真正改善。

## 问题

当前流程容易奖励“完成 checklist”：

- 有没有破坏功能。
- 有没有满足字面任务。
- 测试是否通过。

但这不够。改善类任务还必须判断：

- 任务背后的质量目标是否达成。
- 改动是否产生了足够的结构性收益。
- 是否只是移动少量代码来满足 checklist。
- 后续维护者、用户或测试者的工作是否真的更容易。

## Quality Outcome Contract

建议每个重构、优化、拆分、可靠性、UX 或架构收敛任务都写：

```yaml
quality_outcome:
  user_problem: "当前系统给维护者、用户或运营流程造成的真实问题。"
  desired_property: "改完后系统应具备的质量属性。"
  measurable_thresholds:
    - "能用测试、指标、代码结构、用户流程或 artifact 证据判断是否达成。"
    - "至少包含一个结果阈值，而不只是动作完成。"
    - "明确哪些证据由工具产生，哪些判断由 reviewer 作出。"
  invalid_completions:
    - "只完成表面动作，但用户问题或维护问题仍然存在。"
    - "只证明没有破坏旧行为，不能证明质量属性改善。"
    - "用局部绕过、硬编码或临时兜底掩盖目标没达成。"
```

阈值不一定是数字，但必须让 reviewer 能判断“结果是否变好”，而不是只判断“动作是否发生”。

## 通用审查问题

review 不应被某个例子锚定。不同任务的质量结果不同，应先按任务类型选择审查问题。

通用问题：

- 原始用户问题或维护问题是否仍然存在？
- 改动是否只完成了动作，还是改变了系统性质？
- 结果是否能被证据验证，而不是靠实现者自述？
- 是否引入了新的复杂度、隐式耦合、隐藏状态或不可观测路径？
- 后续维护者、用户或测试者的工作是否真的更容易？
- 如果继续沿用这个改法，系统会更健康还是只会积累新债？

按任务类型选择补充问题：

| 任务类型 | reviewer 应重点问 |
| --- | --- |
| 模块拆分 / 重构 | 职责边界是否更清楚；依赖方向是否更简单；旧中心模块是否少承担真实职责；新 API 是否更容易理解和测试 |
| 性能 / 成本优化 | 是否有基线和改后指标；是否只是移动成本；极端输入是否退化；观测指标是否能持续验证 |
| UX / 工作流优化 | 用户关键路径是否更短或更清晰；错误状态是否更可恢复；是否用真实界面或截图验证；文案和状态是否降低认知负担 |
| 可靠性 / 恢复能力 | 失败、中断、重试、late result 是否闭合；是否 fail closed；是否有可诊断日志和状态 |
| 架构收敛 / SSOT | 旧路径是否删除或降级；单一事实源是否真实生效；writer/reader/schema 是否一致；是否减少双写和隐式 fallback |
| 测试 / QA 改进 | 是否覆盖了真实风险；是否减少盲区；测试是否可重复、可诊断；是否避免只测 mock happy path |
| 安全 / 数据保护 | 是否保护用户数据和正式产物；权限边界是否明确；危险路径是否有 hard gate；失败时是否默认安全 |

## Review 输出

review 输出必须包含 outcome verdict：

```md
## Quality Outcome

Verdict: pass|fail

Reason:
这次改动完成了表面动作，但没有证明 quality outcome 已达成。
原始维护问题仍然存在；新增结构没有清晰边界；证据只能说明旧行为未破坏，
不能说明系统性质已经变好。
```

如果 outcome 未达标，即使测试通过，也不能说任务完成。

review findings 必须先于总结出现。每个 High / Medium finding 至少包含：

- Symptom：观察到的事实或缺口。
- Source：违反的 task contract、source contract、runtime 规则或项目约束。
- Consequence：如果不处理，会破坏什么用户结果、质量结果、gate 或后续维护路径。
- Remedy：下一步需要的具体修复、验证或阻塞动作。

没有 High / Medium 问题时，也要说明剩余风险、实际检查过的证据、未验证路径和为什么可接受。PASS 不是“看起来可以”，而是“未发现阻塞问题 + 证据足够 + residual risk 可接受”。

### Finding 质量门槛

reviewer 写入 High / Critical finding 前，必须能回答：

- 准确位置在哪里：文件、行、函数、状态或 artifact。
- 触发条件是什么：具体输入、状态、顺序、环境、用户路径或失败样例。
- 为什么现有 guard 没挡住：类型系统、validator、schema、上游检查、框架默认行为、测试或权限边界为何不足。

答不出来时，应降级为 Medium/Low/advisory，或先补 evidence。不要为了证明 review 有价值而制造低置信 finding；零 High/Medium 且 review surface 清楚，是有效 review。

reviewer 在报告 line number、dirty 文件数量、branch ahead/behind、release artifact 状态、fallback 行为、locale 覆盖、包内容或远端状态前，应在当前轮重新读取来源。旧聊天、上一个 agent 的说明和自己的记忆只算线索，不是 source-of-truth。

## Reviewer 行为升级

reviewer 应从“找 bug”升级为“判断软件质量是否真的改善”。

默认审查顺序：

1. **Outcome**：任务背后的质量目标是否达成。
2. **Behavior**：功能是否正确，旧路径是否安全。
3. **Structure**：模块边界、依赖方向、单一事实源是否改善。
4. **Evidence**：测试、grep、E2E、artifact 是否支撑结论。
5. **Residual risk**：未覆盖风险是否可接受。

review 不应从 diff 第一行开始逐行看。先判断这次改动解决的失败模式：

- 当前 bug 是状态流转、artifact 一致性、tool 边界、恢复路径、证据缺失、AI 产出漂移、用户体验还是安全边界问题。
- 同类问题是否可能出现在其他入口、phase、runner、恢复路径或 agent 角色中。
- 当前方案是在修机制，还是只给当前 case 打补丁。
- 是否有更小的机制性改动可以收口同类问题。

review 要优先看失败路径，而不只看 happy path：

- 中断、错误、取消、恢复和重试后状态是否正确。
- review/test fail 后是否回到正确 gate。
- 文件缺失、artifact 损坏、旧 run 恢复、late result 是否 fail closed。
- 用户可见文案、状态文件和 artifact 是否一致。
- required capability 不可用时是否错误放行。

对改善类任务，以下情况应给 High 或 Medium：

- 字面完成但质量结果没有达成。
- 用低价值搬移冒充重构。
- 新抽象没有边界，反而增加理解成本。
- 计划里的 measurable threshold 没达成却没有更新 scope。
- review 结论只说测试通过，没有评价 maintainability outcome。

以下通用工程风险也应进入 High 或 Medium 判断：

- 用黑名单 / 白名单、自然语言词表或 free-text 命中作为 AI 输入/输出、状态推进、artifact mutation、gate/block 结论的主要边界。
- 只补一个具体词、具体 option、具体 prompt 片段或具体业务场景让测试通过，却没有稳定 schema、parser、状态机、provenance 或结构化 classifier。
- 只修当前报错调用链，没有检查同层级 guard、filter、cleanup、resolver、normalizer、validator 或 state transition。
- 新增字段、状态或 artifact，但 writer、reader、schema、docs、tests 或 CLI/tool 输出没有同步。
- 多个事实源冲突时静默选择一个，而不是 fail closed。
- 替换旧逻辑但旧路径仍能产出权威状态或 artifact，缺少 closure guard。
- 用业务兜底、测试专用分支或手写 artifact 掩盖真实入口、tool、schema、provider、runner 或状态机未接通。
- confirmed artifact、失败证据或历史记录被原地覆盖，导致 reviewer/tester 无法追溯。
- late result 未绑定 run / phase / attempt / revision，却被应用到当前状态。
- dirty 或多 agent worktree 中只用本地测试证明当前 diff，通过路径可能被无关 WIP 污染。
- CLI / installer / uninstall / cleanup / migration 改动只跑库测试，没有安装后真实命令、非交互、错误路径或 mutating safety evidence。
- release / package / generated artifact 相关改动只验证源码，未检查包内容、生成物、版本字段、release assets、registry/appcast、CI 或远端状态。

reviewer 发现名单式限制或 free-text 路由时，应要求作者说明：

- 这是稳定协议枚举，还是会随用户输入/模型措辞增长的自然语言补丁表。
- 为什么结构化方案不可用。
- 同形态输入如何被验证。
- 同层级相邻入口是否已经 grep 或测试。

## Final Audit 和 E2E

reviewer 应区分两种收尾证据：

- Final completeness audit：对照 source contract、traceability matrix、changed files、closure guard 和 evidence，判断代码侧完整性。
- Final E2E / dogfood：按真实用户路径运行，判断用户体验和系统行为是否成立。

Final audit 通过不等于真实 E2E 通过；真实 E2E 通过也不能掩盖旧路径仍能写权威状态。缺任一项时，reviewer 应要求补证据、降级 verdict，或把风险写入 residual risk，而不是让 lead 包装成完整完成。

## Safety Sink 和 Release Gate

触及这些 sink 的 diff，reviewer 应要求显式 validation 和 rollback 证据：

- 删除、移动、覆盖用户文件、缓存、历史、配置、偏好、生成输出。
- 从用户输入构造 shell、AppleScript、SQL、URL 或 filesystem path。
- 修改 cwd、symlink、path traversal、sandbox、approval、auth prompt、签名、notarization、appcast、license、payment 或 release asset 流程。

如果 validation、用户确认、回滚方式、operation log、idempotency 或 partial-failure 处理不清楚，应阻塞或要求补证据。

release-ready 结论必须分层说明：source、CI、generated artifact、package/archive、version fields、release assets、registry/appcast、remote state、runtime smoke。缺失层是 explicit gap，不是 pass。

## 规则同步

如果本轮改动改变了后续 agent 的 review、coding、testing、slice gate、tool 使用或通过标准，reviewer 应检查规则文档、项目 `.orbit/roles.yaml`、task template 或 handoff 是否同步。规则明显滞后时，应列为 Medium 或要求 follow-up；不要按过期规则放行。

## Lead 行为升级

lead 不应把任务写成“拆小文件”这种动作，而应写成目标。

不好：

```text
拆小 legacy_orchestrator.py。
```

更好：

```text
降低 legacy_orchestrator.py 的维护复杂度：把 retry lifecycle 从 request orchestration 中拆出，
使主 orchestration 文件减少至少 20%，并让 retry 的状态读写、摘要、测试入口可独立审查。
```

然后再列动作：

- 抽模块。
- 调整 imports。
- 补 tests。
- 跑 regression。

动作是手段，quality outcome 才是完成标准。

## 低价值完成反例

如果任务只写成：

```text
拆小 legacy_orchestrator.py。
```

agent 容易把它理解成“移动一些代码即可”。7000 行变 6900 行时，形式上确实做了动作，但很可能没有解决维护复杂度。

如果任务写成：

```yaml
quality_outcome:
  user_problem: "legacy_orchestrator.py 过大，request orchestration、retry、fallback 和 context fetch 互相混在一起，维护者无法独立理解 retry 生命周期。"
  desired_property: "retry lifecycle 成为独立模块，主文件只保留 orchestration 调用。"
  measurable_thresholds:
    - "legacy_orchestrator.py 至少减少 20%。"
    - "新模块文件名体现领域边界，不叫 generic utils。"
    - "retry summary/state helpers 可独立测试。"
    - "reviewer 能说明维护者现在少读哪些代码。"
  invalid_completions:
    - "只抽 3-6 个无状态 helper。"
    - "主文件仍需要理解 retry 细节才能修改 request orchestration。"
```

那么 review 应按质量结果判断，而不是按“是否拆了”判断。7000 行变 6900 行通常应不通过，不是因为行数本身，而是因为它触发了合同里的无效完成方式。

其他任务也要写自己的无效完成方式：

- 性能优化：只减少单次请求 token，但增加重试次数或失败率。
- UX 优化：只换布局或文案，但用户关键路径仍不清晰。
- 可靠性优化：只补 try/except，但状态仍不可恢复。
- 架构收敛：只新增 facade，但旧路径仍能产出权威结果。
- 测试改进：只增加 snapshot 或 mock happy path，但真实风险仍未覆盖。

# ADR 001：任务、证据与运行身份的信任边界

- 状态：Accepted
- 日期：2026-07-10

## 背景

Orbit 已能用 revision、evidence、runtime proof 和 gate 约束 agent 工作流，但复核发现四个信任缺口：同内容任务可能得到相同 revision id；revision 字段映射不完整；provider proof 缺少本地到期语义；试用指标把 baseline 与 after 相加，无法说明优化效果。

这些问题的共同后果是：结构上合法的旧事实可能被错误地解释为当前任务的有效事实。

## 决策

1. 每个 task 创建时生成不可变的 `task_id`。revision id 由包含 `task_id` 的完整语义快照生成。
2. task、evidence manifest、每条 revision-bound record、artifact ref、rules cache、loop state 与 handoff 同时绑定 `task_id + revision`。非空且未绑定或绑定到其他任务的 evidence 不允许复用。
3. revision snapshot 默认覆盖 task 的全部非 revision 元数据字段。字段到 change type 使用单一映射；出现未知字段时 fail closed，直到显式定义失效语义。
4. 60 秒 provider challenge 只用于一次兑换。持久凭证是最长 300 秒、可续期的 session attestation；本地到期后，即使 provider 仍返回 valid 也不再可信，必须从 canonical pane 续期或重新兑换。
5. 试用 snapshot 以 `task_id + stage` 配对，只报告 baseline、after 与 `after - baseline`；同时报告 paired/unpaired 分母，并区分 `observed_zero` 与 `missing`。
6. task-scoped count event 只有在绑定 paired cohort 的不可变 `task_id` 后才进入分子。已绑定的 out-of-cohort event 可以安全排除；unbound event 不进入分子但必须把报告状态降为 `ambiguous_event_scope`，禁止作出试用决策。
7. standalone 指标报告使用 `orbit-trial-metrics-report-v2`，并在自身声明 `schema_semantics.feature_versions.trial_metrics: v4`，使消费者可以区分旧 global-count 与新 cohort-count 语义。
8. `.orbit/` 继续只保存本地运行状态；稳定方案、ADR 与 compact summary 放入可版本化目录。

## 为什么这样做

- `revision_id` 描述任务版本，不足以充当任务身份；两个相同合同仍是两个独立授权与证据域。
- 新增字段如果默认不参与 revision，会静默复用旧 gate；默认拒绝比错误放行更符合 Orbit 的质量治理定位。
- provider 的“仍可验证”不等于本地 session 应永久有效；短期 attestation 限制凭证泄露和僵尸会话影响面。
- baseline 与 after 的总和没有决策意义；只有同任务配对的变化量才能说明成本或等待时间是否改善。
- 未绑定事件的真实 task cohort 不可知；把它排除后仍宣称 ready 会将未知缺陷伪装成零缺陷，因此必须 fail closed。已绑定的外部 task 身份明确，不需要阻塞当前 cohort。
- 报告含义改变时只升级代码 feature version 不足以保护独立消费者；standalone schema 和内嵌语义版本必须同时可见。
- 原始运行文件高频、含本机路径且体积不可控；版本历史应保存结论和理由，而不是复制运行缓存。

## 后果

- 旧的非空、未绑定 evidence 不能自动迁移到新 task，需要保留为历史或重新采集。
- 新 task 字段必须同时声明 revision change type，否则 revision 创建会被拒绝。
- 本 ADR 原先描述的 automatic session refresh 已由 ADR-002 推翻：真实 Herdr 不提供对应信任原语，Orbit 不再暴露该成功路径。
- v1 指标报告属于旧 global-count/非自描述语义，不能原地解释为 cohort-safe v2；消费者必须从原始 JSONL 重新生成 v2 报告。
- v1 event ledger 仍可作为迁移输入，但其中 unbound task-scoped event 会阻断决策，直到备份账本并完成经核验的显式 task 绑定迁移。迁移工具不得根据路径或时间静默猜测 `task_id`；当前版本不定义 event-scope waiver。
- v2 指标消费者必须读取 standalone schema、`schema_semantics`、分阶段数据、分母与 `observation_status`，不能只检查局部 coverage 或继续使用 snapshot 总和。

## 验证要求

- 两个同形 task 的 `task_id` 与 revision id 必须不同，且不能互用 evidence 或 artifact。
- task 模板每个语义字段必须出现在 revision 映射中；未知字段测试必须失败。
- legacy `herdr_verified`/provider proof 记录必须 fail closed，`dispatch_ready` 始终为 false；不得通过本地 refresh 恢复。
- 指标固定样例 `120 → 90` 秒应报告 delta `-30`，`500 → 350` tokens 应报告 delta `-150`。
- 存在 unbound task-scoped event 时，计数分子仍只包含 paired cohort，但 `observation_status` 必须为 `ambiguous_event_scope`；只有 bound out-of-cohort event 时可保持 `ready_for_trial_decision`。
- gate roles 原始数组含数字、空字符串等非法项时必须校验失败，不能由运行时 normalizer 过滤后通过。
- 新报告必须声明 `orbit-trial-metrics-report-v2` 和 `trial_metrics: v4`。

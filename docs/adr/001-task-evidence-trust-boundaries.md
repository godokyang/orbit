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
6. `.orbit/` 继续只保存本地运行状态；稳定方案、ADR 与 compact summary 放入可版本化目录。

## 为什么这样做

- `revision_id` 描述任务版本，不足以充当任务身份；两个相同合同仍是两个独立授权与证据域。
- 新增字段如果默认不参与 revision，会静默复用旧 gate；默认拒绝比错误放行更符合 Orbit 的质量治理定位。
- provider 的“仍可验证”不等于本地 session 应永久有效；短期 attestation 限制凭证泄露和僵尸会话影响面。
- baseline 与 after 的总和没有决策意义；只有同任务配对的变化量才能说明成本或等待时间是否改善。
- 原始运行文件高频、含本机路径且体积不可控；版本历史应保存结论和理由，而不是复制运行缓存。

## 后果

- 旧的非空、未绑定 evidence 不能自动迁移到新 task，需要保留为历史或重新采集。
- 新 task 字段必须同时声明 revision change type，否则 revision 创建会被拒绝。
- automatic session 需要定期可信活动或显式 `runtime refresh-session`。
- 指标报告结构发生兼容性变化，消费者应读取分阶段数据与分母，不能再使用 snapshot 总和。

## 验证要求

- 两个同形 task 的 `task_id` 与 revision id 必须不同，且不能互用 evidence 或 artifact。
- task 模板每个语义字段必须出现在 revision 映射中；未知字段测试必须失败。
- attestation 本地过期而 provider proof 仍存在时，`dispatch_ready` 必须为 false；受控刷新后才能恢复。
- 指标固定样例 `120 → 90` 秒应报告 delta `-30`，`500 → 350` tokens 应报告 delta `-150`。

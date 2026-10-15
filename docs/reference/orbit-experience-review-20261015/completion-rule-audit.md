# 完成判据中的场景规则排查

日期：2026-10-15。范围：当前工作区 `lib/orbit/`、`plugins/`、`runners/omp-reviewer/` 的相关判据、提示词和检查结果消费链。只读审查，未修改产品代码，未新增运行验收。当前工作区已有其他任务对 `task_runtime.rb`、`requirement_coverage.rb` 的未提交修改，不将本次源码检查冒称为所有历史安装版本的行为证明。

## 结论

明确找到两类场景专用规则：Git 远端交付和 UI／视觉验证。Git 包括关键词识别及特定完成判据两个环节。另外发现测试回执证据规则存在过强的一概排除，值得按同一职责边界讨论。固定快照读取限制属于此前 EXP-02 的证据可达性问题，不重复计为新的业务场景规则。

这些规则多数不是运行时直接写 `if UI then fail`，而是代码生成的提示词强制独立检查者作特定判断。检查者的 `delivery.ready` 与 coverage 结果随后进入真实完成门，因而仍会影响完成。不能把这类提示词当作无执行后果的普通建议，也不能把其效果说成程序逐项独立验证了业务事实。

## 具体位置与判断

| 编号 | 代码中的实际规则 | 位置 | 问题与边界 |
| --- | --- | --- | --- |
| CR-01 | 正则匹配 `push/publish/github/gitlab/gitee`、`推送/发布/远端/远程`、`PR` 等词，`remote_delivery_required?` 直接返回匹配结果 | [关键词](../../../lib/orbit/git_remote_evidence.rb:60)、[判定函数](../../../lib/orbit/git_remote_evidence.rb:197) | 程序按词面解释用户是否要求远端交付，没有语义上的否定、引用或不同发布目标区分。命中会触发远端采集；完成提示词仍写着“当要求推送时”，不能夸大成关键词一命中就直接拒绝完成 |
| CR-02 | `remote_head == head` 才记 verified；提示词规定远端交付只能使用这些事实，mismatch/unknown 时 `ready` 必须 false | [事实状态赋值](../../../lib/orbit/git_remote_evidence.rb:150)、[强制交付规则](../../../lib/orbit/check_runner.rb:1075) | 头相等本身是可记录的 Git 事实；将它写成所有推送交付的必要条件，是场景代码追加验收义务。Zeen 现场已有成功推送后远端前进的误报 |
| CR-03 | `A visual or UI requirement is verified only by an image you actually read`；未读到图片就保持 unverified，不能 complete 或 ready | [UI 规则](../../../lib/orbit/check_runner.rb:1039) | 要求证据真实合理，但直接把所有 UI 要求的验证方式限定成实际读取图片过宽。UI 范围也包含交互、状态等事实，具体证明方式应由要求决定；图片也不自动证明这些行为通过。当前没有逐项判定所有历史 UI 拒绝都由此造成 |
| CR-04 | `Missing, failed, truncated or artifact-mismatched receipts cannot prove an executed successful test` | [测试回执规则](../../../lib/orbit/check_runner.rb:1047)、[artifact_matches 计算](../../../lib/orbit/task_runtime.rb:3064) | 缺失／失败与截断／版本变化被并列排除。后两者仍应核对截掉什么、改动影响什么；全产物摘要不匹配不等同于受测行为失效。这是一条通用证据规则过强，不是新的业务特例。该规则没有要求所有任务都跑测试，也不等于所有输入修订自动作废测试；输入变化在后文明确允许比较要求 |

CR-04 的程序计算还要求执行 cwd、产物根及其完成时根、指纹状态均匹配。程序如实输出这些事实没有问题；需要讨论的是提示词是否应把任一产物摘要变化一概解释成该测试不能支持当前要求。不能把改过版本的回执伪装成当前版本执行，也不能省略对其仍然相关性的判断。

## 规则如何进入真实完成门

`CheckRunner#build_prompt` 将 `requirement_coverage_note` 和 `delivery_rules_note` 加入独立检查输入。检查者返回结构化 `delivery` 与 `coverage` 后：

- [task_runtime.rb:3453](../../../lib/orbit/task_runtime.rb:3453)：`delivery.ready=false` 记录 not_ready、发出补交付通知，不发送就绪通知。
- [requirement_coverage.rb:115](../../../lib/orbit/requirement_coverage.rb:115)：检查者未完整枚举、没有交付要求或仍有 unverified 项时，coverage 不就绪。
- [task_runtime.rb:3464](../../../lib/orbit/task_runtime.rb:3464)：覆盖不就绪阻止后续完成准备。

因此，检查者如遵守 CR-02/03 的强制提示，就会产生阻止完成的结果。这里应纠正的是被强加的语义前提，不是直接让 runtime 忽略所有 ready／coverage 结果。

## 另列的通用约束

- 要求检查结果来自正确任务和受检版本、检查确实执行、成员真实结算、停止得到确认，是运行事实与生命周期约束。本次不把它们等同于 Git／UI 场景代码，也不因用户拒绝场景补丁自动取得删除这些机制的授权。
- coverage 最多 64 项，并规定无法在输出限制内完整枚举就 `complete=false`，见 [check_runner.rb:1023](../../../lib/orbit/check_runner.rb:1023)及 [check_runner.rb:1053](../../../lib/orbit/check_runner.rb:1053)。这属于通用容量限制对完成的影响，值得单独评估；不能据此声称所有超过 64 条自然语言要求的任务必然失败，也尚未核对本次现场由此阻断的案例。
- 原生权限、模型授权、只读检查与停止确认的实现中还有其他条件，本清单不声称已经逐行审计所有控制分支。核心已发现问题是用程序预设的证明方式代替依据当前用户要求作判断。

上述为发现清单；后续用户已确认的修改方向见[已确认改动方案](agreed-change-plan.md)，包括取消固定 64 项上限，尚未实施。从[总入口](README.md)继续讨论其他问题。

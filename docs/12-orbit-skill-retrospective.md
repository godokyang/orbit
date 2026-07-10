# Orbit Skill 使用复盘

> 复盘日期：2026-07-10
> 复盘范围：本项目当前会话的实际使用体验，以及仓库现存 `.orbit` task、evidence、report、rules、handoff 和 loop state。
> 复盘立场：优先从使用者是否省心、是否信任结果、是否愿意持续开启的角度判断，而不是从协议功能是否完整的角度判断。

## 1. 使用者结论

| 问题 | 结论 |
| --- | --- |
| Orbit 有没有效果 | 有，特别是在高风险后端任务上 |
| 效果是否足够大 | 局部很大，整体中等 |
| 当前是否愿意默认开启 | 不愿意 |
| 高风险长任务是否愿意开启 | 愿意，但必须有真实 reviewer/tester 和可见状态 |
| 是否应该立刻删除 skill | 不建议，先瘦身后试用 |
| 如果完全不优化，是否长期保留 | 不建议 |

**按使用者价值加权后的总体评分是 5/10。**

这不是说 Orbit 一半功能不能用，而是说它当前创造的质量收益，被运行身份失败、流程不透明、产物膨胀、等待成本和 UI/真机漏测抵消了相当一部分。

评分方法如下。它不是科学测量，但比直接给一个印象分更可复核：

| 维度 | 权重 | 评分 | 加权结果 |
| --- | ---: | ---: | ---: |
| 高风险工程质量门禁 | 25% | 8/10 | 2.00 |
| 独立 review/test 组织能力 | 20% | 7/10 | 1.40 |
| 最终产品与用户主流程质量 | 25% | 3/10 | 0.75 |
| 易用性、可见性和可预测性 | 15% | 3/10 | 0.45 |
| 时间、上下文和产物效率 | 15% | 2/10 | 0.30 |
| **总体** | **100%** |  | **4.90/10，取整为 5/10** |

一句话判断：**Orbit 值得保留为高风险任务的质量门禁，不适合继续充当所有工作的默认操作系统。**

## 2. 作为使用者，我原本期待什么

当我说“用 Orbit 执行 goal”“继续 goal”或“暂停 goal”时，我期待的是：

1. 系统记得当前目标、已完成项和下一步，不需要我反复确认。
2. team 模式下 coder、reviewer、tester 自动各司其职，不需要我理解 pane、identity、evidence manifest 或 gate 内部细节。
3. 我能随时看到谁在工作、做到了哪里、为什么还没完成。
4. agent 说“完成”时，代表真实用户流程已走通，而不只是代码、单测和文档完成。
5. 小修改仍然快速，不会因为引入 Orbit 就多出一整套仪式。
6. 暂停后可以自然恢复，不需要重新解释 goal 或猜测当前状态。

实际体验只满足了一部分：长期状态比纯聊天可靠，独立评审也确实发现了重要问题；但角色是否真正运行、goal 当前是什么、coder 是否在写、为什么 gate 未完成，仍需要多次追问。

如果一个工作流要求使用者持续关心 `manual_runtime`、`identity_pending`、task hash、pane binding 和 report revision，它就还没有把内部复杂度封装好。

## 3. 实际使用感受

### 3.1 最有价值的时刻

当 reviewer/tester 返回一个具体、可复现、会影响真实数据或运行时的 finding 时，Orbit 的价值最明显。此时它不只是记录“跑过测试”，而是阻止了错误实现被当作完成。

当前会话中的代表案例包括：

- P8-U4：发现任务接口仍可能绕过用户档案边界，登录响应还错误暴露成长字段和隐式 profile fallback。
- P8-U9：发现 `needs_training` 缺少确定、持久、可验证的恢复条件。
- P8-U10：发现缺失 `UserProfileRecord` 的旧数据仍可进入收益、结算和采集路径。
- P8-U12：发现公开质量榜单缺少用户主动公开授权。
- P8-U13：发现风险信号可以只靠自由文本创建，没有结构化主体引用。
- P8-U14：发现风险动作会覆盖已有人工审核/QC 的 `QualityEvent`，破坏历史来源；当时普通全量测试仍然全部通过。
- P9-U2：真实 Compose 测试发现 API 与 worker 并发执行 Alembic 时发生迁移竞争，API 首次启动退出。
- P6-U4：发现媒体详情没有兼容 Android 实际生成的 overlay 结构。

P8-U14 和 P9-U2 是最有说服力的案例：它们需要主动构造反例或运行真实组合环境才能发现。Orbit 强制把“测试是绿的”和“结果可信”分开，这一点有效。

### 3.2 最令人失望的时刻

最差的体验是：已有 task、evidence、review/test 甚至“DONE”消息，但拿真机或浏览器走主流程后，仍然很快遇到用户级问题。

本次 Android/Web 真实使用中，用户继续发现了：

- 默认 Tab 不符合主流程。
- 审核、运维和训练入口不符合采集员工角色。
- 记录列表无法进入详情或继续处理。
- 点击提交审核崩溃。
- 录后自查、补充画面信息和事件列表占据过多屏幕。
- 收益卡片不可进入，也没有独立详情页。
- 任务学习缺少成功/失败示例和隐私要求详情。
- 视频上传后 Web 不可见、详情视频为空或不能播放。
- 中文用户界面仍有大量英文和技术描述。
- 页面信息密度高，主要动作不突出。

从首个 Android 视觉系统提交 `cdd82d2` 到本次复盘时的 HEAD，共有 77 个后续提交，其中 45 个是 `fix:`。这不能证明所有修复都是 Orbit 造成的，也不能证明没有 Orbit 就不会返工，但它足以说明此前的 gate 没有证明真实用户主流程已经好用。

对使用者而言，最伤信任的不是某个测试失败，而是“流程显示完成，实际第一遍使用就失败”。

### 3.3 最费心的时刻

当前会话中，用户多次需要追问：

- 是否遵循了 Orbit 流程。
- 当前 goal 是什么。
- 下一步做什么。
- coder 是否真的在写代码。
- 为什么 team 模式由 lead 自己实现。
- reviewer 是否读取了 reviewer 规范。

这些问题不应该由用户反复提出。一个好用的 agent 工作流应该主动显示这些状态，而不是要求用户理解和审计内部协议。

## 4. 哪些效果属于 Orbit Skill，哪些不属于

为了判断是否保留 skill，必须拆开责任。否则很容易把 reviewer 的能力、CLI 的校验和 Herdr 的运行问题全部算到 skill 头上。

| 组成部分 | 它实际负责什么 | 本次表现 |
| --- | --- | --- |
| Orbit skill | 告诉 agent 何时进入 Orbit-aware/formal workflow，要求解析身份、建 task、留 evidence、走 gate | 方向正确，但触发偏重、说明过长，对小任务过度介入 |
| Orbit CLI/协议 | `whoami`、task/evidence/state、`wait-gate`、`validate`、`audit`、`handoff` | Fail-closed 和结构校验有效，但 schema、hash 和产物成本较高 |
| Herdr runtime | 启动/承载多 agent、pane 投递和可验证运行身份 | 本次没有稳定形成 verified identity，是主要短板之一 |
| coder/reviewer/tester agent | 实际写代码、推理、构造反例、运行测试、发现缺陷 | 真正发现了有价值的问题；能力不能全部归功于 Orbit |
| 项目 task/acceptance 设计 | 定义什么叫完成、要求哪些真实路径 | 后端边界较好，Android/Web 用户旅程定义不足 |

因此，客观说法应是：

- Orbit skill **促使** agent 执行了更严格的流程。
- Orbit CLI **阻止** 了一部分错误 gate 和证据漂移。
- reviewer/tester **发现** 了具体缺陷。
- Herdr/identity **没有稳定兑现** skill 设想的自动协作体验。
- UI/真机漏测主要来自 task acceptance 和执行证据不足，不能只归咎于 CLI。

这也是为什么不应该把所有成功都算给 Orbit，也不应该因为 UI 做得不好就说 Orbit 完全无效。

## 5. 可验证的收益和成本

截至本次复盘，本地 `.orbit` 大致情况如下：

| 项目 | 数量或体积 | 使用者含义 |
| --- | ---: | --- |
| task 文件 | 179 | 长目标被拆得很细，但查找成本上升 |
| evidence 文件 | 396 | 有过程记录，也存在多轮重复 |
| review/test report | 198 | 独立结论较多，部分为重跑或 minimal 报告 |
| rules 解析产物 | 936 | 约 13 MB，是最大重复来源 |
| handoff 文件 | 106 | 有交接意识，但存在两套目录 |
| `.orbit` 总文件数 | 2045 | 总体积约 23 MB |
| Git 跟踪的 `.orbit` 文件 | 0 | 本机有历史，换机器或重新 clone 后没有 |

report 文本统计显示：

- 约 26 个 report 曾给出 fail 或 changes requested。
- 5 个 report 文件包含 High/Critical finding。
- 19 个 report 文件包含 Medium finding。
- 37 个 report 文件名包含 `minimal`。

这些是文件数量，不等同于独立缺陷数；同一 finding 的失败与关闭报告可能重复出现。当前也没有无 Orbit 的对照组，所以不能证明所有 finding 只有 Orbit 才能发现。

从使用者角度，净收益可以概括为：

| 收益 | 成本 |
| --- | --- |
| 高风险问题更难被测试绿灯掩盖 | 小任务也可能产生重流程 |
| 多 agent 结论有结构、有追溯 | 角色和 gate 状态不直观 |
| 未实现边界和 known gaps 更诚实 | 规则、证据和报告高度重复 |
| 长会话恢复比只靠聊天可靠 | 本地产物不进 Git，跨环境价值有限 |
| `validate` 能发现 task/evidence 漂移 | task 改动会让旧 evidence hash 失效并产生返工 |
| 独立角色减少实现者自证 | automatic runtime 身份没有稳定建立 |

## 6. 当前最关键的问题

### 6.1 “完成”的定义仍然离用户太远

大量 evidence 证明的是执行动作，不是最终体验：

- `191 passed` 不能证明 Android 记录页在真机上可以点进去。
- Web build 通过不能证明视频 URL 在反向代理后指向正确端口。
- Compose healthy 不能证明 Android 到 MinIO 的 LAN 地址可达。
- UI 截图完整不能证明信息密度合适、主要动作可触达。

只要 acceptance 仍由实现者写成容易通过的技术指标，Orbit 就可能产生结构化的自证。

### 6.2 Automatic runtime 在本次使用中基本没有成立

当前 shell 直接执行 `orbit whoami --json` 会因缺少 `ORBIT_INSTANCE` / `ORBIT_ROLE` 返回冲突；手工补入身份后才能解析 solo 执行合同。

仓库证据还显示：

- 至少 92 个 evidence 文件明确记录 `manual_runtime`。
- 没有 evidence 文件记录到可检索的 `herdr_verified`。
- 当前大任务最新 implementation evidence 是 `identity_pending`，原因是 `unbound_herdr_session`。

虽然会话实际使用了 Herdr pane 和 agent 消息，但 Orbit 最看重的 verified runtime identity 没有稳定建立。规范复杂度按照“自动且可信的 runtime”设计，实际体验却经常退回环境变量和 manual protocol。

### 6.3 Solo 模式没有真正闭环

项目已经切到 solo 模式，lead 是实现权威，但当前大任务仍要求独立 reviewer 和 tester。结果是：

- implementation 可以完成。
- lead 可以运行大量本地测试。
- lead 不能伪装成 tester/reviewer，这一点是正确的。
- 没有独立角色时，task 永远不能 ready，loop state 长期停在 working。

这在协议上诚实，在产品体验上却不完整。Solo 模式只解决了“谁写代码”，没有解决“谁能验收”。

### 6.4 产物没有形成耐久知识

整个 `.orbit/` 被 Git 忽略，2045 个文件没有一个进入版本历史；loop state 中还有大量 `/Users/yangke/...` 绝对路径。

这意味着项目承担了生成审计材料的成本，却只得到当前机器、当前 checkout 内的追溯能力。重新 clone、换机器、CI 或长期团队接手时，这些材料并不天然存在。

### 6.5 Skill 的触发粒度仍然偏重

skill 已经区分讨论与正式任务，但进入正式实现后仍倾向完整 task/evidence/rules/gate。TODO 勾选、文案修改、局部样式和小型文档维护，不应该承受与数据库迁移、鉴权和支付状态机相同的流程。

## 7. 哪些场景应该用，哪些不应该用

| 场景 | 建议 | 原因 |
| --- | --- | --- |
| 鉴权、收益、结算、隐私、删除、迁移、并发 | 完整使用 | 错误代价高，独立反例和 fail-closed 很有价值 |
| 跨 Android/API/worker/MinIO/Web 的主流程 | 使用，但必须绑定真实 E2E | 只做单端测试容易出现“每端都绿，链路不通” |
| 长期 goal、多 agent、多人接手 | 使用 | task/state/handoff 能减少上下文丢失 |
| 普通 API 或中型功能 | 精简使用 | task + 一个独立 gate 通常足够 |
| UI 重设计 | 仅在能执行真机/浏览器验收时使用 | 没有真实交互证据时，完整 Orbit 价值很低 |
| 文案、TODO、局部样式、小文档 | 不创建正式 task | 流程成本高于风险 |
| 紧急本地调试 | 先修复和复现，事后补最小证据 | 不应让协议阻塞恢复现场 |

## 8. 优化优先级

### P0：按风险提供三个档位

| 档位 | 适用任务 | 最小流程 |
| --- | --- | --- |
| A：高风险 | 鉴权、收益、数据状态机、迁移、并发、隐私、发布 | task + implementation + 独立 review + 独立 test + validate/audit |
| B：普通功能 | 新 API、跨模块业务功能 | 精简 task + implementation + review/test 二选一；用户主流程必须 E2E |
| C：轻量修改 | 文案、TODO、局部样式、小文档 | 不建正式 task，只保留一句 verification summary |

只有 A 类默认生成完整 rules、handoff 和长期 evidence。

### P0：给用户一个状态面板

一屏显示：

- 当前 goal/task 和 operation mode。
- coder/reviewer/tester 是否在线、正在做什么。
- implementation/review/test 最新状态。
- 未关闭 High/Medium finding。
- 当前 blocker 和下一步。
- 当前身份是 manual、pending 还是 verified。

使用者不应该再问“有没有遵循 Orbit”“coder 在写吗”“下一步做什么”。

### P0：把真实用户旅程设为产品任务硬 gate

- Android：通过 ADB 或 instrumentation 完成真实点击路径，保留关键截图和崩溃日志。
- Web：通过浏览器自动化检查操作、可见文本、网络请求、媒体状态和窄屏布局。
- 跨端上传：从 Android 录制/提交，到 API/worker/MinIO，再到 Web 查看和播放。
- UI 改善：保留前后截图和用户完成步骤，不能只跑单测或写“更美观”。

Evidence 首页应先回答“用户完成了什么”，再列“执行了什么命令”。

### P0：修复 runtime identity 和 solo 语义

建议提供两种 solo：

1. `solo-strict`：只有 implementation gate，最终状态明确为 `implemented_not_independently_accepted`，不伪装成完成，也不永久卡在 working。
2. `solo-with-fresh-review`：自动拉起 fresh-context reviewer/tester，并建立可信身份；拉起失败时不声明 required gate。

进入 Herdr 项目后，应自动识别当前 instance，或给出一个可直接执行的单行修复命令，不再依赖用户理解环境变量和 pane binding。

### P1：压缩产物并引入 task revision

- 每个 task revision 只保留一份规范化 rules resolution。
- context 默认是临时文件，完成后自动压缩或删除。
- 去掉重复 `minimal` report。
- 统一 `handoff/` 与 `handoffs/`。
- loop state 使用相对路径。
- task 开始后冻结 revision；范围变化创建新 revision，不让所有旧 evidence 模糊失效。
- 每个任务最终生成一份可版本化 compact summary，原始 runtime 产物继续本地保存。

## 9. 是否保留的试用标准

建议保留 30 天，但先完成 P0 优化，并按 A/B/C 档位试运行。

试用期间至少统计：

- 每个任务额外消耗的时间和 token。
- 每个任务生成的 artifact 数量和体积。
- reviewer/tester 发现的独立缺陷数。
- 有多少 finding 是现有测试发现不了的。
- gate 通过后仍由用户发现的 P0/P1 回归数。
- 从 implementation 到最终 gate 的等待时间。
- identity、schema、task hash 导致的流程失败次数。

继续保留的条件：

- A 类任务持续发现现有测试未覆盖的真实缺陷。
- Android/Web gate 后的用户级回归明显下降。
- 用户不再需要反复询问角色、goal 和下一步。
- automatic runtime 不再长期停留在 manual/identity pending。
- B/C 类任务的流程成本明显下降。

考虑移除完整 skill、只保留精简检查清单的条件：

- 多数任务只生成重复报告，没有独立 finding。
- UI/真机问题仍主要依赖用户在 gate 后发现。
- runtime identity 仍无法稳定自动建立。
- artifact 和上下文增长明显快于有效决策。
- 轻量 task + 独立 E2E review 能稳定取得相同结果。

## 10. 最终判断

**Orbit 有效，但当前不是一个让我愿意默认开启的工作流。**

我愿意在鉴权、结算、迁移、并发、隐私和跨端数据链路这类高风险任务上使用它，因为它已经证明能促成有价值的反例评审并阻止错误 gate。

我不愿意在文案、TODO、局部 UI 和快速调试中使用完整流程，因为当前成本明显高于收益。

我也不会因为 task、evidence 和 report 都存在就相信功能已经完成。对 Android/Web 产品任务，必须看到真实设备或浏览器中的完整用户旅程。

因此建议：**保留 skill，立即改成风险分级，并优先修复状态可见性、真实 E2E gate、runtime identity、solo 闭环和产物压缩。优化后再用数据决定是否长期保留。**

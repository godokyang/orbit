# JEV 委派判断专项计划

状态：2026-09-22 实现与确定性回归完成，真实验收待跑。现行运行事实以
[`contracts/task-runtime.md`](../../contracts/task-runtime.md) 为准。本文件只负责 JEV 与模型证据。
四条真实路径尚未执行，见 [优化真实验收计划](../reference/orbit-optimization-acceptance-plan-20260922.md)。

Codex `orbit codex` 已用 `env_vars` 只传递 `TYPESAFE_API_KEY` 名称，值由 app-server 从启动环境解析，诊断不泄漏值。第一阶段达到阈值后查询缓存，缺失时每个观察签名请求一次；`model-evidence` 写入缓存后，第二阶段才判断 `member_fit` 与 `parallel_gain`。过阈值只提示，不自动 `delegate`。第二阶段高分评估若在提示投递前崩溃，新 runtime 会从持久 assessment 恢复并只投递一次 hint。没有 pending request 的 model_evidence 仍进入可复用缓存，但任务记 `evidence_status=unrequested` 与 `model_evidence_ignored`，不声称已消费。

## 要解决的问题

Zeen Login 真实任务证明，Orbit 接入检查链路不等于启动多 Agent 执行协作。该任务没有执行成员，
JEV 也因环境变量没有进入 MCP 子进程而没有运行；现有单一 `delegatable` 判断即使正常运行，也只判断
“可能存在可拆子任务”，没有把 Root 与成员的速度差、质量返工、交接集成和 token 成本纳入并行收益。

本轮目标是让 Orbit 在确有独立执行面且委派可能缩短关键路径时，向 Root 给出可解释、可追溯的提示；
Root 仍决定具体执行票、成员和是否调用 `delegate`。Orbit 不自动派发。

非目标：维护随版本发布的模型排行榜、要求用户填写模型速度、让 JEV 临时联网、自动购买或启用新供应商、
把所有任务强制拆成多 Agent、用复杂统计平台替代最小可用闭环。

## 冻结的产品边界

### 状态表达

对外状态必须区分：

- `Orbit 已接入，当前仅独立检查；执行成员 0 个。`
- `Orbit 已接入，已委派 N 个执行成员；多 Agent 执行协作已启动。`

`start`、`status` 和 `check` 不产生执行成员；只有成功的 `delegate` 才改变执行协作状态。

### 判断分层

程序先核对确定事实：任务状态允许委派、存在名单允许且实际可调用的成员、没有重复派发同一工作、
当前观察仍新鲜。JEV 只处理需要语义判断的三项概率：

1. `delegatable`：现在是否存在边界清晰、结果明确、可与 Root 并行的独立执行票。
2. `member_fit`：至少一个可调用成员，仅凭有界交接可以传递的信息，是否可能达到该有界子任务的验收线。评估时不假定交接已经发生，也不假定成员能看到 Root 上下文。模型身份相同不是能力相当的直接证据。交接、返工和集成的时间开销只计入 `parallel_gain`。
3. `parallel_gain`：计入交接、返工、集成、共享资源争用与验证后，委派是否可能缩短整项任务的端到端关键路径（输出速度不等于任务完成速度）。
4. `cost_appropriate`：仅按宿主确认的路由与带来源的提交价格或套餐额度资料（只做结构校验，不做语义核实），判断候选的粗档价格或额度对该有界子任务是否相称。`direct_api` 路由用 `cost.*` 按量价格事实，`subscription_quota` 路由用 `quota.*` 套餐/额度粗档事实，两者不互换、不折算为等价每 token 价。不换算货币、不与 Root 自己的计费路由比较、不按品牌排名；路由或事实缺失/过期视为 unknown，unknown 不是免费，不得抬高该分。

首版提示条件冻结为：

```text
delegatable >= 0.60
member_fit >= 0.55
parallel_gain >= 0.50
cost_appropriate >= 0.50   # 且通过计费路由 fail-closed 门
```

`cost_appropriate` 门（2026-09-24 随源码落地，2026-09-25 按端点结构性证明修订；模型侧行为未验收）：阈值 0.50 为最小约定值（无校准证据）；硬要求是路由或事实未知时**永不提示**。原生成员路由由 OMP host 从解析出的 `@task` 端点（HTTPS host 与 path 前缀）与传输方式做结构性判定，**不按 provider 名称推断**（仅接受 HTTPS 端点，http 或自定义 scheme 一律 unknown）：`direct_api` 仅接受已验证的第一方按量端点（当前为 DeepSeek 官方 `https://api.deepseek.com`）；`subscription_quota` 仅接受已验证的第一方套餐端点（zhipu-coding-plan 官方 `https://open.bigmodel.cn` 的 `/api/coding/` 路径、kimi-code 官方 `https://api.kimi.com` 的 `/coding/` 路径）；两者都要求传输方式不是 `pi-native`。每个被比较候选的证据条目须在缓存有效期窗口内、`billing_route` 以类型化身份（provider/model/reasoning/route）匹配同一路由，并带对应命名空间的数值型事实：`direct_api` 用 `cost.*`，`subscription_quota` 用 `quota.*`（提交附来源 URL，Orbit 只校验结构与数值形态，不抓取 URL、不做语义核实）。其它 provider、自定义或未验证端点、unknown、无路由或无对应事实一律 fail closed，任务记 `cost route or required fact is not verified; no automatic delegation hint`。用户明确授权的原生派发不受此门影响。基于模型的 cost 门真实表现尚无真实样本验证。

第一阶段门槛于 2026-09-22 用首组真实正负样本校准：明确包含两个独立工作面的任务首次得到 0.64，
单文件小任务得到 0.18，并在后续观察中保持明显间隔，因此从未校准的 0.80 调为 0.60。它只决定是否值得
收集模型证据，并不直接提示委派。校准后的 prompt 在中等复杂度双模块任务上得到 `member_fit=0.78`、
`parallel_gain=0.53`；完整 runtime 的同类任务为 `member_fit=0.58`、`parallel_gain=0.52`，而两个交接成本偏高的
小任务分别为 `0.45/0.45` 与 `0.42/0.48`。因此 `member_fit` 从 0.75 调为 0.55，`parallel_gain` 从 0.70
调为 0.50。三个维度不按同一量纲加权。任何硬条件不满足都不提示；
一次判断只推荐一个边界最清晰、预期收益最高的完整执行票。JEV 不选择 `kind`，也不调用 `delegate`。

2026-09-24 用户确认：分工建议必须同时考虑端到端完成时间与费用。时间仍只由 `parallel_gain` 判断。费用必须是有证据的粗档判断，不是叙述。用户举过的 Codex／Claude 与 GLM／Kimi 例子只是说明，不是固定档位。**费用门已随源码落地（三个定型问题 + `cost_appropriate >= 0.50` + 计费路由 fail-closed 门，见上）；基于模型的 cost 门真实表现尚未经真实样本验收**。计费路由 typed 身份（provider/model/reasoning/billing_route）已采纳；2026-09-25 产品决定：`direct_api`（数值 `cost.*`）与已验证 `subscription_quota`（数值 `quota.*`）都可授权 cost 门，路由按宿主解析端点 host+path 与传输方式证明，不按 provider 名称。

### JEV 问题文本

发给 JEV 的可控文本保持英文；任务原文、路径、代码和用户内容不翻译。初始问题定义为：

```text
delegatable:
Is there likely a bounded, independent subtask that an authorized execution
member could deliver now while the main agent continues? Judge this from the
effective instruction, basis, amendments and remaining work, not from whether
Root has already mentioned or started the subtask in recent activity. Explicit
disjoint files, modules or acceptance surfaces are strong evidence. Exclude
trivial, overlapping, preference-only or dependency-blocked work. Availability
is enforced by the caller and must not lower this task-structure probability.

member_fit:
Given the callable member options and the supplied model evidence, is at least
one member likely to meet the best bounded subtask's acceptance bar using only
information that can be passed in a bounded handoff? Do not assume a handoff
already exists, and do not assume the member can see Root's context. Do not
treat a matching provider, model or reasoning identity as direct evidence of
capability parity. Treat missing or stale evidence as unknown and do not infer
capability from a model name alone. Handoff, rework and integration time
overhead belong only to parallel_gain.

parallel_gain:
Given the remaining task dependencies and the supplied execution evidence,
would delegating the best bounded subtask now likely shorten the overall critical path
after handoff, expected rework, integration, shared-resource contention, and
verification are included? Output speed alone is not task completion speed.
```

JEV 输出概率，不输出硬编码综合分。质量通过预期返工影响有效耗时，token 和费用作为资源证据与约束，
不为了得到一个“总分”把不同单位机械相加。

## 模型证据由 Root 按需检索

本节接口已接入任务运行。缓存命中才进入第二阶段；incomplete 或未知不把最近一次评估当成累计总量。

Orbit 不维护内置模型画像，也不要求用户配置相对速度。Orbit 只维护检索协议、结构化证据格式、缓存、
失效规则和向 JEV 提供的有界摘要。

判断流程：

1. 第一阶段用任务结构判断 `delegatable`。低于阈值时结束，不发起模型资料检索。
2. 高于阈值且存在可调用成员时，先按实际 provider、model、reasoning effort 查询缓存。
3. 缓存缺失或过期时，运行程序记录 `model_evidence_needed`，向 Root 发送一次有界请求，列出待比较的模型标识、
   所需指标和已有本地样本。Root 使用当前宿主已有的联网检索能力获取公开资料；JEV 和 Orbit 后台进程不自行浏览网页。
4. Root 通过新增的 `model_evidence` 控制操作提交 JSON；CLI 对应
   `orbit model-evidence TASK_DIRECTORY --file FILE|-`。该操作只接受模型事实证据，不修改用户要求，不能复用 `amend`。
5. 运行程序校验模型标识、指标口径、来源 URL、取得时间和有效期，原子更新用户级缓存，再从有效证据派生
   Root 与候选成员的比较摘要，判断 `member_fit`、`parallel_gain` 与 `cost_appropriate`（价格或套餐额度只结构校验，不做语义核实）。
6. 满足全部条件（含计费路由 fail-closed 门）才发送最终委派提示；证据请求、检索失败、判断和最终提示分别记录，不能把前两者说成已委派。

来源优先级为：

1. Orbit 本地同类任务的实际执行数据；
2. 独立公开评测；
3. 官方规格、价格和版本资料；
4. 厂商宣传只能作为低置信度补充。

查不到资料时明确记为 `unknown`，不得根据 `flash`、`pro`、`max` 等名称猜测。公开的输出 tokens/s 只作为速度先验；
端到端完成时间还必须考虑首 token／推理延迟、工具调用、上下文、返工和集成。

## 缓存与失效

缓存属于可再生运行证据，不进入 Orbit 发布包，也不是用户配置。固定位置为
`${XDG_CACHE_HOME:-$HOME/.cache}/orbit/model-evidence-v1.json`，使同一模型证据可在项目间复用；只通过
`model_evidence` 操作原子更新，不保存凭据或网页全文。任务记录保存本次实际使用的证据摘要和来源，保证事后可追溯，
但不复制整个全局缓存。

- 明确版本默认有效 7 天。
- `latest`、`preview` 等浮动别名默认有效 24 小时。
- provider、model 或 reasoning effort 任一变化即不命中。
- 每条证据保存来源 URL、取得时间、有效期、指标口径和原始模型标识。
- 公开检索以实际完整模型标识为关键词；优先查同一独立评测中的可比速度／质量数据，再用官方资料补价格、
  上下文和版本事实。不同口径的数据不直接相减或合并为伪精确分数。
- 有效期内直接复用；过期只在下一次真正需要比较时刷新，不做后台榜单维护。
- 外部证据和本地数据冲突时同时保留来源；同类本地真实任务样本优先，但必须显示样本量和时间范围。
- Root 当前没有联网检索能力或找不到可比资料时，提交 `unavailable` 及原因；Orbit 不循环请求，仍允许 Root
  基于自身判断手动 `delegate`，但不发送声称有模型证据支持的最终提示。

传给 JEV 的是压缩后的比较，不是网页正文或完整排行榜，例如：

```json
{
  "root": {
    "provider": "openai",
    "model": "gpt-6-astra",
    "reasoning": "max"
  },
  "candidate": {
    "provider": "opencode-go",
    "model": "deepseek-v4.1-flash",
    "reasoning": "default"
  },
  "comparison": {
    "speed_ratio": 3.48,
    "quality_delta": -14,
    "cost_ratio": 0.08,
    "local_samples": 0
  },
  "evidence": {
    "retrieved_at": "2026-09-22T10:00:00Z",
    "valid_until": "2026-09-29T10:00:00Z",
    "sources": ["https://artificialanalysis.ai/models"]
  }
}
```

示例数字只说明 schema，不固化为产品事实。

## 有效耗时与三个调优维度

决策使用关键路径，不以单项输出速度替代总收益：

```text
成员有效耗时
= 成员执行耗时
+ 交接耗时
+ 预期返工耗时
+ Root 集成与验证耗时

并行收益
= Root 单独完成的预计关键路径
- 委派后的预计关键路径
```

- 速度：优先使用本地同类任务墙钟数据；没有样本时使用公开端到端延迟与输出速度作为先验。
- 质量：以首次验收通过率、返工次数／时间和相关 coding／agentic 评测表示，主要进入预期返工。
- token／费用：记录 Root、JEV、成员和检查链可得的实际用量；用户硬预算是门槛，普通成本用于收益比较，
  不从墙钟时间推算缺失用量。

## 调用频率与状态

- 只在首次出现可委派执行面、任务范围实质变化、候选成员变化或相关证据失效时重新判断。
- 已有执行成员处于 `starting` 或 `working` 时，不再自动运行第二阶段或发送新的提示；Root 仍可按自身判断手动派发。
- `status`、普通 `check` 和无实质变化的运行循环不重复检索或运行完整委派判断。
- 结构判断、证据请求、证据有效、最终提示、Root 是否调用 `delegate` 和成员结果分别记录。
- `status` 显示 JEV 为 `disabled / unavailable / assessed`，并显示最近判断时间；配置过 key 不等于本任务运行过 JEV。
- 每个观察版本最多一个有效提示；范围实质变化后可以产生新版本，不能用“一生一次”掩盖后续新增的独立工作面。

## 实施顺序与验收

1. 修复并验证 `TYPESAFE_API_KEY` 从宿主到 MCP 的名称传递；诊断只显示存在性。Codex 启动链已实现。
2. 增加 JEV 状态可见性，以及“仅检查／已有执行成员”的明确状态。已实现。
3. 增加模型证据 schema、Root 写入入口、用户级缓存和失效逻辑；不实现内置排行榜。已实现。
4. 将 `member_fit`、`parallel_gain` 和有界证据摘要接入 JEV，保留现有检查调度判断。已实现。
5. 增加少量确定性测试，覆盖缓存命中／失效、未知证据、硬条件、阈值和不重复调用。确定性回归已覆盖接线，不构成真实路径验收。
6. 用包含两个真实独立工作面的受控任务做端到端验收：记录首次提示时间、是否派发、成员结果、关键路径、
   Root 返工／集成时间、JEV 与检查 token；另用小任务证明不会为了协作产生无收益委派。未运行。

完成不能只看 JEV 返回高分。至少要证明一次真实执行成员被 Root 派发、产物被集成，且与 Root 单独执行的合理基线相比，
关键路径确有改善；如果没有改善，如实保留为无收益样本并重新校准，不修改证据来迎合阈值。

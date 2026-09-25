# 模型费用档分析（2026-09-24）

检索日：2026-09-24；2026-09-25 以官方页复核，关键数值未变。只使用厂商官方页。示例里的 Codex／Claude 与 GLM／Kimi 档位不是产品事实，也不写入永久价格。API 按量、订阅额度和本机 OMP 入口分开，不互相折算。

## 复核（2026-09-25）

- DeepSeek Flash：输入 $0.15／输出 $0.60（非高峰）；$0.30／$1.20（高峰）。<https://api-docs.deepseek.com/quick_start/pricing>
- Kimi K2.7 Code：输入 $0.95／输出 $4.00。<https://platform.kimi.ai/docs/pricing/chat-k3.md>
- GLM-5.3：API 8／28 元；本机 task 入口走 GLM Coding Plan 积分，不能按此计。<https://docs.bigmodel.cn/cn/guide/start/pricing.md>
- GPT-5.3-Codex（标准短上下文）：$1.75／$14.00。<https://developers.openai.com/api/docs/pricing>

## 证据

### GLM API 按量

来源：<https://docs.bigmodel.cn/cn/guide/start/pricing>（markdown：<https://docs.bigmodel.cn/cn/guide/start/pricing.md>）。单位是元／百万 tokens。

| 模型 | 输入 | 输出 | 缓存命中 |
| --- | --- | --- | --- |
| GLM-5.3 | 8 | 28 | 2 |
| GLM-5.2 | 8 | 28 | 2 |
| GLM-5.3-Flash | 0.8 | 2.8 | 0.23 |
| GLM-5.3-FlashX | 2 | 7 | 0.57 |

缓存存储对上表模型写的是限时免费。这是 API 标价，不是 Coding Plan 扣费。

### GLM Coding Plan

来源：<https://docs.bigmodel.cn/cn/coding-plan/overview>（markdown：<https://docs.bigmodel.cn/cn/coding-plan/overview.md>）。

- 套餐支持 GLM-5.3 与 GLM-5.3-Flash。调用历史模型 GLM-5.2、GLM-5.1 会自动切到 GLM-5.3；调用 GLM-5-Turbo、GLM-4.7 会自动切到 GLM-5.3-Flash。
- 扣的是积分，不是上表的元／百万 tokens。积分 =（输入 token × Input 系数 + 缓存命中 token × Cached Input 系数 + 输出 token × Output 系数）／10000。
- GLM-5.3 系数：输入 6.9，缓存命中 1.7，输出 24。GLM-5.3-Flash：2.3、0.56、8。
- 高峰是周一至周五 14:00–18:00（UTC+8）。非高峰按基础积分的 50% 抵扣。同一页还写，9 月 25 日至 10 月 7 日全天按非高峰规则。充分利用非高峰时相对 GLM-5.3 标准 API 最高可省 92%，这是宣传比较，不是可直接相除的单价。
- 当前新套餐的包月人民币价格不在这份概览页。另一页 <https://docs.bigmodel.cn/cn/coding-plan/notice/usage-revision> 的 Lite 49／Pro 149／Max 469 元是 V1 用户到期前可买的 V2 价格，不记为当前新套餐标价。
- 本机 `zhipu-coding-plan/glm-5.2` 应按套餐积分消耗和剩余额度评估，不能用 API 标价 8／28 元代替。

### Kimi API 按量

来源：<https://platform.kimi.ai/docs/pricing/chat-k3.md>。单位是美元／百万 tokens，不含税。

| 模型 | 缓存写入 5 分钟 | 缓存写入 1 小时 | 缓存命中输入 | 输入 | 输出 | 上下文 |
| --- | --- | --- | --- | --- | --- | --- |
| kimi-k3 | 3.00 | 6.00 | 0.30 | 3.00 | 15.00 | 1,048,576 |
| kimi-k2.7-code | — | — | 0.19 | 0.95 | 4.00 | 262,144 |
| kimi-k2.7-code-highspeed | — | — | 0.38 | 1.90 | 8.00 | 262,144 |

K2.7 Code 行的三列是官方表的 cache hit、cache miss、output。K3 另有缓存写入费。未找到把 `kimi-code/kimi-for-coding` 映射到这两个 API id 的官方页。火山方舟 Coding Plan 是另一套订阅和抵扣，见 <https://www.volcengine.com/activity/codingplan>；转售路由的账单不能用 Moonshot API 标价代替。本次没有采用第三方聚合站的火山单价。

### DeepSeek API 按量

来源：<https://api-docs.deepseek.com/quick_start/pricing>。单位是美元／百万 tokens。`deepseek-flash` 的版本名是 DeepSeek-V4.1-Flash；旧名 `deepseek-v4-flash` 仍接受，但按 Flash 价格计。

| 项目 | 非高峰 | 高峰 |
| --- | --- | --- |
| 输入缓存命中 | 0.003 | 0.006 |
| 输入缓存未命中 | 0.15 | 0.30 |
| 输出 | 0.60 | 1.20 |

高峰是周一至周五 UTC 01:00–04:00 与 06:00–10:00，不含中国法定节假日。其余时间为非高峰，周末和中国法定节假日全天非高峰。非高峰是高峰的一半。

### Claude API 标价

当前页：<https://platform.claude.com/docs/en/about-claude/pricing>，检索日 2026-09-24。单位是美元／百万 tokens。下表是页面主表的输入／输出，不是缓存写入价。

| 模型 | 输入 | 输出 |
| --- | --- | --- |
| Claude Opus 5.5 | 4 | 20 |
| Claude Sonnet 5 | 2 | 10 |
| Claude Haiku 4.5 | 1 | 5 |

现价以上面的文档页为准。订阅页 <https://claude.com/pricing> 是另一套额度，不拿来和上表相除。本机 `modelRoles` 没有 Claude。

### OpenAI API 与 Codex 订阅

来源：<https://developers.openai.com/api/docs/pricing>，检索日 2026-09-24。单位是美元／百万 tokens。页面数据中的标准价：

| 模型 | 输入 | 缓存输入 | 输出 |
| --- | --- | --- | --- |
| gpt-5 | 1.25 | 0.125 | 10 |
| gpt-5-mini | 0.25 | 0.025 | 2 |
| gpt-5.3-codex（标准） | 1.75 | 0.175 | 14 |

上表是该页 Standard 短上下文价。同一页的 Standard 长上下文价可以更高，见 <https://developers.openai.com/api/docs/pricing>。Codex 订阅与 API 按量分开。官方说明见 <https://developers.openai.com/codex/pricing>：套餐内的本地消息和云端对话共用额度；用 API key 走 CLI／SDK／IDE 时按 token 付费，模型范围跟随该 key 可用的 API 模型。不能把 Codex 套餐额度换成上表单价。

## 本机 OMP 入口

只读角色映射，不含凭据：`modelRoles.task` 是 `zhipu-coding-plan/glm-5.2`；`modelRoles.default` 是 `kimi-code/kimi-for-coding:max`。

因此当前 task 候选走的是 GLM Coding Plan，不是 GLM API 的 8／28 元标价。官方套餐页说 GLM-5.2 调用会切到 GLM-5.3 并扣积分。`kimi-for-coding` 不能按 kimi-k3 或 kimi-k2.7-code 的 API 标价计费；该映射未知。

## 完成时间

本次没有同一任务、受控条件下的跨模型墙钟样本，因此不做速度排序。墙钟时间包括准备、工具调用、返工和核对，不只是输出 token 速度。此前缓存里的单次小样本不能当作排名。现有原始观察见下节表格；速度档位保持未知。

## 单 token 标价与单任务总费用（标准化画像，非账单）

单 token 标价只回答"单价"，不回答"完成一个任务要花多少"。可操作的做法是先固定一个**标准化 token 画像**做同币种、同计费渠道的粗比较，再单独处理成功率、返工、审查与等待。**同一 P1 的 token 数不等于同一段文本或同一工作量**：各厂商 tokenizer 与提示格式不同（Claude 官方 pricing 页说明 4.7 及更新模型的新 tokenizer 对同一文本约多产生 30% tokens），P1 只用于标价算术。

画像 P1（仅用于粗档比较，不是账单）：1M 未命中缓存输入 + 0.2M 输出，无缓存命中、无重试。按官方标价直接相乘：

| 渠道（同渠道内可比） | 模型 | P1 推算（标价算术，非账单） |
| --- | --- | --- |
| USD API 按量 | DeepSeek Flash（非高峰） | $0.15 + 0.2×$0.60 = $0.27 |
| USD API 按量 | DeepSeek Flash（高峰） | $0.30 + 0.2×$1.20 = $0.54 |
| USD API 按量 | Kimi K2.7 Code | $0.95 + 0.2×$4.00 = $1.75 |
| USD API 按量 | GPT-5 | $1.25 + 0.2×$10.00 = $3.25 |
| USD API 按量 | Claude Sonnet 5 | $2.00 + 0.2×$10.00 = $4.00 |
| USD API 按量 | GPT-5.3-Codex（标准短上下文） | $1.75 + 0.2×$14.00 = $4.55 |
| USD API 按量 | Claude Opus 5.5 | $4.00 + 0.2×$20.00 = $8.00 |
| CNY API 按量 | GLM-5.3-Flash | 0.8 + 0.2×2.8 = 1.36 元 |
| CNY API 按量 | GLM-5.3-FlashX | 2 + 0.2×7 = 3.4 元 |
| CNY API 按量 | GLM-5.3／GLM-5.2 | 8 + 0.2×28 = 13.6 元 |

- 上表只做同币种、同渠道内比较；USD 与 CNY 不互算；P1 是标价算术，**不是模型真实单任务成本排序**，也不代表同文本／同工作量。
- 缓存命中、缓存写入、Batch／Fast mode 等都会改变结果；画像 P1 未含这些。
- 订阅与转售路由（GLM Coding Plan、Kimi Code 套餐、Codex／ChatGPT 套餐、Claude 订阅、火山方舟／zenmux 等转售）**单任务边际费用未知**，不能拿 API 标价代替。

**单任务总费用还会被这些因素改变（官方指引）**：OpenAI Model guidance 写明更高单价的模型可能用更少输出 token，"delivering a lower estimated API cost per task … despite its higher per-token pricing"（<https://developers.openai.com/api/docs/guides/latest-model>）；其 agent 优化指南写明更便宜的模型若需要重复尝试、无谓工具调用或人工纠正，可能比一次做对的高价模型更贵（<https://developers.openai.com/cookbook/examples/agent_optimization/optimizing_agents_for_cost_and_quality>）。因此单 token 档位只能作输入之一，不能直接当单任务结论；语音等其它场景的结论不向编码任务外推。

## 完成时间：现有真实运行原始观察（不可排名）

以下 `elapsed_seconds` 来自各任务 `state.json`；任务大小、状态与是否派成员都不同，**不能据此给模型排速度档**；没有同一任务、受控条件下的跨模型墙钟对照。

| 任务 | 状态 | elapsed(s) | 成员数 | 备注 |
| --- | --- | --- | --- | --- |
| `2e27fce9` | complete | 164.3 | 0 | 单 Root |
| `81285102` | complete | 149.5 | 0 | 单 Root |
| `129b1f69` | complete | 224.2 | 0 | P3 单 Root |
| `f3763481` | complete | 222.5 | 0 | member-audit，stage2 declined |
| `61bbd66d` | complete | 241.7 | 1 | 显式成员机械路径（成员完成并集成） |
| `9d8af567` | complete | 259.1 | 0 | 同模型对照 |
| `e07af778` | complete | 261.8 | 0 | 英文对照 |
| `d18305f5` | paused | 353.9 | 2 | 候选 `volcengine/kimi-k2.7-code` 400 崩溃 |
| `42d1977e` | complete | 463.9 | 0 | 跨模型 L1；证据阶段 5 分 24 秒 |
| `cd084686` | paused | 473.9 | 0 | P2 |
| `35c06d44` | complete | 583.6 | 0 | K3 |

速度档结论：**未知**。可操作条件：只有在同一任务、同一工具面、带时间戳的本地墙钟观测下，且**重复观测足够多、能看清波动与成功率**时才谈档位；不设固定样本数，也不按品牌或单 token 速度推断。

## 粗档位候选（分析候选，非最终产品规则）

- 成本分组（仅本次 P1 样例的临时观察，不是门槛）：USD API 按量列自然分成四组——$0.27–0.54（DeepSeek Flash 两档）、$1.75（Kimi K2.7 Code）、$3.25–4.55（GPT-5、Sonnet 5、GPT-5.3-Codex）、$8.00（Opus 5.5）；CNY 列三组——1.36 元（Flash）、3.4 元（FlashX）、13.6 元（5.3/5.2）。这些数字只是对本次画像结果的描述，**不构成门槛、不供运行时硬编码**；换画像、换渠道或换 tokenizer 都会变。订阅与转售路由单列"边际未知"，不并入上述组。
- 时间档：**未知**（见上表条件）；不得用单 token 速度或品牌代替端到端墙钟。
- 条件判断（分析口径；相称性门已按合同在 0.6.16 实现，粗档分组仍不硬编码、不供运行时使用）：先确认候选路由的计费渠道；渠道可比且证据足够时，用粗档与任务性质做"相称性"判断；渠道未知或不可比时记未知，**未知不是免费**；若本地证据显示更高档模型单任务更少 token／一次做对，允许其单任务总费用更低。

## 已观察开销（构建 L，`42d1977e`）

来源：`/tmp/orbit-m4-crossmodel-rlev/project/.orbit/tasks/42d1977e-d9a6-4464-bc98-8ab75cd67fe7`。Root 身份是 `zhipu-coding-plan/glm-5.2`，候选是 `volcengine/kimi-k2.7-code`，reasoning 都是 `unknown`。`members` 为空，候选没有执行。不据此做速度排序，也不把上面的标价例子改成事实。

阶段时间都是 `events.jsonl` 的 `at`：

- 15:34:29Z 第一次 stage1（`delegatable=0.88`）并在同一秒 `model_evidence_needed`。
- 等待期间又有 stage1：15:35:29Z、15:36:30Z、15:37:30Z、15:38:30Z；15:35:30Z 再次 `model_evidence_needed`。
- 15:39:53Z `model_evidence_submitted` 与 `model_evidence_used`。距第一次 stage1／证据请求 5 分 24 秒。
- 15:39:55Z stage2 `delegation_assessed` 与 `delegation_declined`（0.28／0.21）。距证据使用 2 秒。

JEV 用量只有 `input_tokens`／`output_tokens`，没有 `cacheRead`，缓存未知而不是 0。stage2 之前的五次 stage1 合计输入 24605、输出 370。stage2 一次是输入 6276、输出 38。决定之后 15:41:55Z 还有一次 stage1，输入 4843、输出 74，不计入上面的阶段间隔。

三次检查的模型都是 `zhipu-coding-plan/glm-5.2`。`evidence.json` 的 usage 分项相加：检查 1 输入 8927、缓存读 21376、输出 1926；检查 2 输入 11860、缓存读 23488、输出 5133；检查 3 输入 12984、缓存读 31616、输出 4035。合计输入 33771、缓存读 76480、输出 11094。记录里的 `cost.total` 都是 0，这不是账单。Root 会话用量不在这些事件里，路由也不同，所以不能换算金额。

## 已观察开销（构建 O，`b9e87009`）

来源：`/tmp/orbit-m4-buildo-voOs/project/.orbit/tasks/b9e87009-96ff-460d-a81f-5b1048951c5b`（构建 O，digest `7228ee7a…`）；只读判因审计见 `/tmp/orbit-m4-build-o-jev-audit.md`。候选有实际执行的 `deepseek/deepseek-flash` 成员；不据此做速度档排序。

- 派发前 17:28:58Z stage1 `delegatable=0.92`；17:28:59Z stage2 `member_fit=0.22／parallel_gain=0.29 → declined`（签名 `6dbed2e9…`）。成员完成后 17:30:00Z 另有 `0.46／0.33`，只作事后观察，不用于解释派发前决策。
- 候选已提交证据只有官方按量标价与能力上限；速度、质量、本地时间样本三项 coverage 明确为 0（标注"无数据"）。成员实际约 20 秒（17:29:07Z 登记 → 17:29:26.654Z 接受）完成 B 面，但该实测没有回灌证据缓存。
- Root `kimi-code/kimi-for-coding` 的缓存条目复用了 K3 家族级第三方速度／质量／API 价，basis 自认精确后端未公开固定、按家族级对待——与本文件"映射未知、不可按 API 标价折算"的口径冲突；是否影响 stage2 分数无法从外部断言。
- 任务记录 229 秒（17:28:51Z→17:32:40Z）；成员约 20 秒是含模型延迟与工具调用的端到端，Root 独自完成 B 的串行反事实未测。
- 该 decline 与冻结判据一致（候选能力证据缺失时 fit 走 unknown=false），**不据此改阈值**；本节为历史观察。`cost_appropriate` 已于 0.6.16 按合同实现（typed 路由 + 结构校验事实 + fail-closed），2026-09-25 修订为双路由接受（已验证 `direct_api` 用数值 `cost.*`，已验证 `subscription_quota` 用数值 `quota.*`；路由按宿主解析端点 host+path 与传输方式证明）；粗档分组与速度档仍属分析口径，不写产品规则。

## 临时阅读，不是产品规则

- 美元 API 标价只和美元 API 标价放在一起看，输入和输出分开。相对当前页上的 Claude Sonnet 5（输入 2、输出 10）：DeepSeek Flash、Kimi K2.7 Code、GPT-5 Mini（0.25／2）的输入和输出都更低；GPT-5 输入 1.25 更低，输出 10 相同。相对 Kimi K3（输入 3、输出 15），上述几项的输入和输出都更低。这不是对人民币标价的排序。
- 人民币 API 标价只和人民币 API 标价放在一起看：GLM-5.3-Flash 是 0.8／2.8 元，GLM-5.3-FlashX 是 2／7 元，GLM-5.2 与 GLM-5.3 都是 8／28 元。不把这些元价说成低于或高于美元标价。
- 本机 task 入口不是 GLM API 的 8／28 元标价。
- 品牌举例不是档位事实。未知费用档保持未知，不是免费。

## 研究候选（历史）与 0.6.16 实现状态

可以研究让 Jev 增加 `cost_appropriate`：只判断当前配置的 `@task` 候选，在已提交证据和用户计费上下文里，费用档是否与该有界工作相称。Orbit 并不列出全部更便宜的模型，所以不能宣称该候选是全局最便宜。若证据里已经可信地知道有更低费用且能完成工作的选择，常规杂务仍用更高档，这一项应为否。费用未知则证据不足，不为费用成立的 hint。`parallel_gain` 若保留，应只看端到端墙钟时间。以下是当时的候选表述（历史）；现行语义以 `contracts/task-runtime.md` 为准。

**实现状态（0.6.16；2026-09-25 端点结构性证明修订）**：第二阶段现有三个定型问题（`member_fit`、`parallel_gain`、`cost_appropriate`），阈值 `cost_appropriate >= 0.50`；原生成员路由由 OMP host 从解析出的 `@task` 端点（HTTPS host 与 path 前缀）和传输方式做结构性判定，**不按 provider 名称推断**（仅名称或仅 host 都不够，http 端点一律 unknown）。`direct_api` 仅接受已验证的第一方按量端点（当前为 DeepSeek 官方 `https://api.deepseek.com`，且 `transport` 不是 `pi-native`）；`subscription_quota` 仅接受已验证的第一方套餐端点（zhipu-coding-plan 官方 `https://open.bigmodel.cn` 的 `/api/coding/` 路径、kimi-code 官方 `https://api.kimi.com` 的 `/coding/` 路径，且 `transport` 不是 `pi-native`）。每个被比较候选以 typed 身份 `provider/model/reasoning/route` 匹配同一路由，并带对应命名空间的数值型事实：`direct_api` 用 `cost.*`，`subscription_quota` 用 `quota.*`（提交附来源 URL）；实现判断的是候选粗档相对该有界子任务是否相称，不换算币种、不与调用方自身计费路线比较；其它 provider、自定义或未验证端点、`unknown`、无路由或无对应事实一律 fail-closed、不自动提示；事实仅做结构与数值形态校验，不抓取 URL、不做语义核实。基于模型的 cost 门已于 0.6.18 经 live 样本实测一次（任务 `249935cc`：typed `subscription_quota` 证据请求/提交/缓存新增，`member_fit=0.54/parallel_gain=0.30/cost_appropriate=0.57` declined，证据 `/tmp/orbit-m4-jev-live-result.md`）；该次只验证门的行为与 fail-closed 收敛，不构成对当前价格的认可；正样本 hint 仍未观察、为可选跟进。

补充（2026-09-25；分析口径，0.6.16 实现只结构校验价格或额度事实、不计算单任务总费用）：成本判断应以**单任务总费用**为口径（标准化 token 画像 + 成功率/返工/审查/并行等待），单 token 标价只作输入之一；更高档模型可能因更少 token／一次做对而单任务更便宜（见 OpenAI Model guidance 与 agent 成本指南）。速度没有同任务受控对照时为**未知**，不得按品牌或单 token 速度推断。

# OMP 候选 → OpenRouter canonical_slug 映射审计（2026-09-29）

> 类型：历史证据／研究，按标题及正文记录的日期、版本和配置解读。下文“当前”“本轮”及旧规则不代表现行行为或授权；当前状态见[交接](../plan/handoff.md)，现行语义见[任务合同](../../contracts/task-runtime.md)。

这是 OpenRouter 接入时的模型版本来源审计；后续方向见[认可主方案](../plan/mixed-model-delivery-proposal.md) §8/§10。方法：仅官方/第一手来源；对 OpenRouter 只做**无 key 的公共 `GET /api/v1/models`**（该端点公开），未读取任何 `.env`，未发送任何携带凭据的请求，未访问需认证的 `/api/v1/benchmarks`。所有 URL 均于 2026-09-29 核对。

## OpenRouter 目录观察（2026-09-29，无 key 公共 GET）

- `GET https://openrouter.ai/api/v1/models` 返回 **460 项**、`links.next=null`（完整列表，与 Root 同日持 key 观察一致）。
- 与六候选相关的条目（`benchmarks.artificial_analysis` 的 coding/agentic/intelligence）：

| OpenRouter id | canonical_slug | created(UTC) | coding | agentic | int | ctx |
| --- | --- | --- | --- | --- | --- | --- |
| `moonshotai/kimi-k3` | `moonshotai/kimi-k3-20260715` | 2026-07-16 | **76.2** | **50** | 43.6 | 1,048,576 |
| `deepseek/deepseek-v4.1-flash`（含 `:batch`） | `deepseek/deepseek-v4.1-flash-20260910` | 2026-09-10 | **null** | null | 39.5 | 1,048,576 |
| `deepseek/deepseek-v4-flash` | `deepseek/deepseek-v4-flash-20260423` | 2026-04-24 | 56.2 | 22.2 | 24.2 | 1,048,576 |
| `deepseek/deepseek-v4-flash-0731` | `deepseek/deepseek-v4-flash-20260731` | 2026-07-31 | 69.1 | 41 | 34.3 | 1,310,720 |
| `z-ai/glm-5.3-flashx` | `z-ai/glm-5.3-flashx-20260918` | 2026-09-18 | **null** | null | null | 1,048,576 |
| `z-ai/glm-5.3-flash`（相邻型号，勿代用） | `z-ai/glm-5.3-flash-20260826` | 2026-08-26 | 71.5 | 50.9 | 41.8 | 1,310,720 |
| `openai/gpt-6-sol`（含 `:batch`） | `openai/gpt-6-sol-20260922` | 2026-09-22 | **null** | null | 47.5 | 1,050,000 |
| `openai/gpt-5.6-sol`（相邻型号，勿代用） | `openai/gpt-5.6-sol-20260709` | 2026-07-09 | 77.4 | 50.2 | 47 | 1,050,000 |

Root 同日观察（Kimi K3 coding 76.2/agentic 50；`deepseek/deepseek-v4-flash` 56.2）与本次独立抓取逐值一致。另有别名条目 `~deepseek/deepseek-v4-flash-latest`、`~moonshotai/kimi-latest`、`~openai/gpt-sol-latest`、`~z-ai/glm-flash-latest` 等，均无基准数据；别名解析目标不在静态目录中体现，未使用。

## 逐项审计

完整身份核验尚未完成：默认清单中的 `reasoning=unknown` 和 `billing_route=unknown` 只表示未知值。尤其 K3 的实际 OMP 路由可能是 `subscription_quota`；lookup 精确匹配，不能为命中旧清单改写真实路由。下文 verified 仅指所列模型版本对应，逐候选真实路由仍须独立核实。

判定分两列：**映射**（能否核实 OMP 型号版本 → canonical_slug，不证明完整 reasoning／billing route）与**基准**（该 slug 的 coding_index 是否非空）。`reasoning=unknown` 一律保持弱标记，不推成具体档；OpenRouter 先验不含本路由价格/额度/端到端时间。

### 1. `kimi-code/k3-256k` → `moonshotai/kimi-k3-20260715` — 映射 verified，基准可用（coding 76.2 / agentic 50）

- Kimi Code 官方模型页（Moonshot 第一方）：Model ID `k3-256k`，Model version 一栏就是 **K3**，描述为 "The 256K context version of K3"，固定 262,144 ctx、`reasoning_effort: low/high/max`（默认 high）。即 `k3-256k` 不是另一个模型版本，只是同一 K3 的 256K 上下文封装（与 `k3` 的差异仅为上下文上限、配额消耗和 `k3-256k` 仅图像输入）。来源：https://www.kimi.com/code/docs/en/kimi-code/models.html
- Kimi 官方博客：K3 于 2026-07-16 发布（2.8T 参数、1M ctx），经 Kimi.com、Kimi Work、**Kimi Code** 与 Kimi API 提供。来源：https://www.kimi.com/en/blog/kimi-k3
- OpenRouter `moonshotai/kimi-k3` created 2026-07-16（canonical_slug 标注 20260715，为 OpenRouter 自身标签，差一天不影响同一 K3 版本判断），1,048,576 ctx 与 K3 规格一致。
- 注意：OpenRouter 上无单独的 k3-256k 条目；先验来自 K3 本体。OMP 路由实际 reasoning 档未核实（K3 系列默认 high），标 `reasoning=unknown` 弱先验。

### 2. `opencode-go/deepseek-v4.1-flash` → `deepseek/deepseek-v4.1-flash-20260910` — 映射 verified，基准 no_benchmark（coding null）

- OpenCode Go 官方目录将 **DeepSeek V4.1 Flash** 与 DeepSeek V4 Flash 列为两个独立条目（各有独立月度限额），即 OMP id `deepseek-v4.1-flash` 明确指 V4.1 一代。来源：https://opencode.ai/docs/go/ （OpenCode Zen 目录同 id：https://opencode.ai/docs/en/zen/ ）
- DeepSeek 官方新闻：**DeepSeek-V4.1-Flash 于 2026-09-10 发布**（552B MoE、原生多模态），并点名 "Official partners WorkBuddy (including CodeBuddy) & **OpenCode** now fully support V4.1-Flash"。来源：https://www.deepseek.com/en/news/deepseek-v4-1-flash/
- OpenRouter canonical `deepseek/deepseek-v4.1-flash-20260910` 与官方发布同日；V4.1-Flash 迄今只有一个已发布版本，无同名变体分叉。
- OpenCode Go 对该型号按 Peak/Off-Peak 计费（页内链接 DeepSeek 官方定价）；billing 档位差异不改变此处核实的模型版本，但不代表两档均已形成可命中的完整路由映射。基准：coding_index=null → `no_benchmark`。

### 3. `zenmux/deepseek/deepseek-v4.1-flash` → `deepseek/deepseek-v4.1-flash-20260910` — 映射 verified，基准 no_benchmark

- ZenMux 官方模型页 `deepseek/deepseek-v4.1-flash`：标题 "DeepSeek: DeepSeek V4.1 Flash"，**By: DeepSeek**，**Publish time: 2026-09-10**，描述（552B MoE、causal encoder-decoder、原生多模态）与 DeepSeek 官方新闻逐点对应；上游 provider 为 DeepSeek/Alibaba/Baidu。来源：https://zenmux.ai/deepseek/deepseek-v4.1-flash
- 发布日期、架构描述与 DeepSeek 官方 2026-09-10 公告及 OpenRouter canonical `...-20260910` 三方一致。基准：coding_index=null → `no_benchmark`。

### 4. `openai-codex/gpt-6-sol` → `openai/gpt-6-sol-20260922` — 映射 verified，基准 no_benchmark

- OpenAI 官方模型页：Model ID `gpt-6-sol`，1,050,000 ctx / 128K 输出，快照仅 `gpt-6-sol` 一个（无日期分叉快照），`reasoning.effort` 支持 none/low/medium(默认)/high/xhigh/max。来源：https://developers.openai.com/api/docs/models/gpt-6-sol
- OpenAI 官方 changelog：**2026-09-22 发布 GPT-6 Sol**；09-25 修复条目明确该模型服务于 "the API and **Codex**, including computer use"。来源：https://developers.openai.com/api/docs/changelog
- OpenRouter canonical `openai/gpt-6-sol-20260922` 与官方发布同日，ctx 1,050,000 与官方完全一致。Codex 面可用 gpt-6-sol 为官方明示，OMP `openai-codex` 路由身份成立。基准：coding_index=null → `no_benchmark`（intelligence 47.5 非本功能首版输入）。

### 5. `zhipu-coding-plan/glm-5.3-flashx` — 映射 unverified，不入默认清单；即使映射也是 no_benchmark

- Z.ai 官方文档确认模型存在：GLM-5.3-Flash/FlashX 同页，Model Code `glm-5.3-flash`/`glm-5.3-flashx`，FlashX 为同一模型的 200 tokens/s 高速服务档。来源：https://docs.z.ai/guides/vlm/glm-5.3-flash
- 但同一官方页明确：**"GLM-5.3-FlashX is not yet available on the plan"**——GLM Coding Plan 官方模型只有 `glm-5.3` 与 `glm-5.3-flash`（另见 https://docs.z.ai/devpack/latest-model ）。因此 OMP 以 `zhipu-coding-plan` 为 provider 提供 `glm-5.3-flashx` 这一事实**无法用官方 Coding Plan 资料核实**（或目录超前于官方文档），按纪律判 unverified，不凭名称入默认清单。
- 即便将来核实：OpenRouter `z-ai/glm-5.3-flashx` coding_index=null → no_benchmark。相邻的 `z-ai/glm-5.3-flash-20260826`（coding 71.5）是**另一个 OpenRouter 条目**，按"无相邻型号代用"规则不得冒用。

### 6. `opencode-go/deepseek-v4-flash` — 映射 unverified，不入默认清单（同名多版本歧义）

- OpenCode Go 官方目录确有 "DeepSeek V4 Flash" 条目（与 V4.1 Flash 并列），但**未标注日期子版本**；其无 key 公共模型端点 `https://opencode.ai/zen/v1/models` 的 created 均为目录刷新时间（2026-09-29），不能用于钉版本。来源：https://opencode.ai/docs/go/
- DeepSeek 官方 changelog 显示 `deepseek-v4-flash` 一名之下至少三个互斥状态：0424 预览（04-23/24）、**0731 正式版**（仅重后训练）、2026-09-10 起随 V4-Flash 退役**临时别名路由到 V4.1-Flash**。来源：https://api-docs.deepseek.com/updates/
- OpenRouter 侧对应**两个**不同 canonical：`deepseek-v4-flash-20260423`（coding 56.2）与 `deepseek-v4-flash-20260731`（coding 69.1）。OpenCode Go 今日实际服务哪一版（或已随 DeepSeek 别名切到 V4.1-Flash 权重）无法从官方静态资料判定——ZenMux 的 V4 Pro 页甚至明示各家 provider 在 0424/0731 间分裂。按"不能猜同名"规则判 unverified；56.2 不能冒称属于本候选。

## 汇总与默认清单建议

| OMP provider/model（reasoning/billing 均 unknown） | canonical_slug | 映射 | 首版可用先验 |
| --- | --- | --- | --- |
| `kimi-code/k3-256k` | `moonshotai/kimi-k3-20260715` | **verified** | **coding 76.2 / agentic 50**（reasoning 未核实，弱标记） |
| `opencode-go/deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash-20260910` | verified | no_benchmark（coding null） |
| `zenmux/deepseek/deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash-20260910` | verified | no_benchmark |
| `openai-codex/gpt-6-sol` | `openai/gpt-6-sol-20260922` | verified | no_benchmark |
| `zhipu-coding-plan/glm-5.3-flashx` | — | unverified | —（Coding Plan 官方文档未含 FlashX） |
| `opencode-go/deepseek-v4-flash` | — | unverified | —（0423/0731/别名三分叉，无法钉版本） |

四字段写法：`{provider, model, reasoning:"unknown", billing_route:"unknown"} -> canonical_slug`；这只是当前清单的未知值写法。Peak/Off-Peak 不改变模型版本，但 lookup 按完整键精确匹配；未知值不能覆盖任意 billing_route，每个实际路由仍须核实并建立对应条目。

## 实际收益评估（供 Root 决策）

- **只有 1/6 候选（kimi-code/k3-256k）今天能产生非空 coding 先验**；其余三条 verified 映射全部落在 coding_index=null 的条目上，进入默认清单只带来"已映射但无基准"状态，检查者排序零增益。
- 覆盖第 2–4 项的边际收益为零，直到 Artificial Analysis 为这些 slug 补数（届时仍须核对完整路由、目标版本及任务指标资格，不能只因补数免审）；为凑数把 `z-ai/glm-5.3-flash`、`deepseek-v4-flash-0731`、`openai/gpt-5.6-sol` 等相邻条目冒名顶替则违反既定纪律。
- 与方案的"若只有一两个可核实，先重新评估自动接入收益"相符：这里可核实映射有四条，但**有效先验只有一条**——自动预取整个 /models 快照的价值基本等于给 Kimi K3 一个先验，这只是当时首版覆盖的收益观察；外发已是可选能力，后续成员接线和指标资格按认可主方案处理。

## 失效监控要点

- `deepseek-v4-flash` 官方 API 名已别名化（→V4.1-Flash）：任何未来把 `opencode-go/deepseek-v4-flash` 映射到 `deepseek-v4-flash-20260423` 的尝试都需先核实 OpenCode Go 实际权重版本。
- 每次快照刷新需核对目标仍在目录且 canonical_slug 未变；`~…-latest` 类别名不得作为映射目标。
- Z.ai 若把 FlashX 纳入 Coding Plan（官方 docs 更新），第 5 项可复核升级为 verified；届时基准仍为 null，收益不变。

## 来源清单（均于 2026-09-29 访问）

1. OpenRouter 公共模型目录（无 key GET）：https://openrouter.ai/api/v1/models
2. DeepSeek 官方新闻 V4.1-Flash：https://www.deepseek.com/en/news/deepseek-v4-1-flash/
3. DeepSeek API changelog：https://api-docs.deepseek.com/updates/
4. Kimi Code 官方模型配置：https://www.kimi.com/code/docs/en/kimi-code/models.html
5. Kimi K3 官方博客：https://www.kimi.com/en/blog/kimi-k3
6. Z.ai GLM-5.3-Flash/FlashX 官方指南：https://docs.z.ai/guides/vlm/glm-5.3-flash
7. Z.ai GLM Coding Plan 切换指南：https://docs.z.ai/devpack/latest-model
8. OpenAI GPT-6 Sol 官方模型页：https://developers.openai.com/api/docs/models/gpt-6-sol
9. OpenAI API changelog：https://developers.openai.com/api/docs/changelog
10. OpenCode Go 官方目录与限额：https://opencode.ai/docs/go/
11. OpenCode Zen 模型目录：https://opencode.ai/docs/en/zen/ 及公共端点 https://opencode.ai/zen/v1/models
12. ZenMux 官方模型页 deepseek-v4.1-flash：https://zenmux.ai/deepseek/deepseek-v4.1-flash

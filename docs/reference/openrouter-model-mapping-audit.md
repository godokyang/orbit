# OMP 候选 → OpenRouter canonical_slug 映射审计（当前 shipped）

> 类型：当前 shipped 映射的来源与边界。方法沿旧审计：仅官方／第一手来源，OpenRouter 只做无 key 公共 `GET /api/v1/models`。旧目录快照（460 项观察、逐项首版审计、0.7.26 修复流水）沿 Git 查阅：`git show 3865b76:docs/reference/openrouter-model-mapping-audit.md`。

## Shipped 映射（`lib/orbit/data/openrouter-model-map.json`）

六个精确身份变体（四个模型 identity）。四键＝OMP `provider/model/reasoning/billing_route` 精确匹配；`unknown` 键值不匹配真实 subscription 变体——即默认 `unknown/unknown` 行不会命中 `subscription_quota` 真实路由，须独立变体行命中。

| OMP provider/model | reasoning/billing_route | canonical_slug | verified |
| --- | --- | --- | --- |
| `kimi-code/k3-256k` | unknown/unknown | `moonshotai/kimi-k3-20260715` | 2026-09-29 |
| `kimi-code/k3-256k` | unknown/subscription_quota | `moonshotai/kimi-k3-20260715` | 2026-09-29 |
| `opencode-go/deepseek-v4.1-flash` | unknown/unknown | `deepseek/deepseek-v4.1-flash-20260910` | 2026-09-29 |
| `opencode-go/deepseek-v4.1-flash` | unknown/subscription_quota | `deepseek/deepseek-v4.1-flash-20260910` | 2026-09-30 |
| `zenmux/deepseek/deepseek-v4.1-flash` | unknown/unknown | `deepseek/deepseek-v4.1-flash-20260910` | 2026-09-29 |
| `openai-codex/gpt-6-sol` | unknown/unknown | `openai/gpt-6-sol-20260922` | 2026-09-29 |

来源 URL、核对时间与 `verified_by` 均以[运行清单](../../lib/orbit/data/openrouter-model-map.json)逐条记录为准，不将一个变体的核验标签外推到其他变体。

## 边界

- **未映射**：GLM 系、Go `deepseek-v4-flash`（V4 非 V4.1）等池内身份无 shipped 映射；lookup 返回无先验，不用相邻型号代用。
- **verified 仅指型号版本对应**：不证明完整 reasoning 档、实际计费路由、费用或额度；`reasoning` 未知保持弱标记。
- **动态基准不固化**：coding/agentic/intelligence 数值来自抓取时快照（72 小时抓取有效期，非测量日期），不在本文固定为实时事实；测量日期未知保留局限；仅当任务明确要求测量日期且证据不满足时暂停自动正向建议。
- 映射命中不是费用事实或专属 route 质量证明。

# 角色与模型建议

只在需要给 `--review-model` 选 Codex CLI 模型，或 Root 用已有工具分工时阅读本文。这是起步建议，不是 Orbit 实测排名，也不是已接入供应商清单。不要按价格或本轮评审用过的模型固定分配。核对账号里**真实可用的模型 ID**，不要臆造 ID。

## 产品接入 vs 协作工具

- Orbit 任务里的 `--review-model` / `ORBIT_REVIEW_MODEL` 只传给本机 `codex exec`。当前产品检查通道只接 Codex CLI。
- GLM、DeepSeek、OpenCode、OMP 等是 Root **已经在用的**协作工具选项，用来派人做实现或对照，不是 Orbit 已提供的供应商 adapter。没有适配的通道不要写成「Orbit 已能观察和停止该 Agent」。
- 不自动启用未授权供应商或最高推理档，不因建议表替换当前 Root 会话。

## 起步搭配

| 职责 | 需要什么 | 建议 |
| --- | --- | --- |
| Root | 完整目标、长程取舍、协调 | 保留当前会话。优先用户已有的强推理模型，例如 GPT-6 Astra；一般复杂度不必上最高推理档 |
| 常规实现 | 稳工具调用、按范围改、可验证 | 可用 GPT-5.6 Terra 或 GLM-5.3；范围小、容易验证的任务可试 DeepSeek-V4.1-Flash。复杂核心改动交给当前池中更合适的模型 |
| 独立检查 | 对照原文找漏做／做错／做多 | 用足够强的**独立** Codex 会话，例如 GPT-6 Astra；不要因为不写代码就换最弱模型。`--review-model` 填该 Codex 模型 ID |
| 按需裁定 | 看争议依据、给出可执行结论 | 用未参与争议双方判断的独立强模型会话，例如 GPT-6 Astra；可与 Root 同型号，不能让 Root 本人自裁 |

两种够用的配法：

- **只用已有 Codex 套餐**：当前 Astra 做 Root；常规实现可用 Terra；检查与必要裁定用 Astra 的独立会话。小任务可由 Root 直接做完。
- **复用 Root 已接入的其他工具**：当前 Astra 做 Root；实现可走已有 GLM-5.3，明确小任务可走 DeepSeek-V4.1-Flash；检查仍用 Codex CLI 的强模型。工具名与模型名分开写。

四种职责不要求四个常驻席位或四种模型。本轮仓库规则评审用过 Grok，只说明该次分工，不是产品默认角色，也不是质量或成本排名。

厂商定位（2026-09-14 查阅，不是 Orbit 评测）：OpenAI 将 [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) 用于复杂端到端工作，将 [GPT-5.6 Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra) 作为能力与成本平衡；Z.AI 将 [GLM-5.3](https://autoclaw.z.ai/models/) 用于复杂工程；DeepSeek 将 [`deepseek-flash` 映射至 DeepSeek-V4.1-Flash](https://api-docs.deepseek.com/quick_start/pricing/)。API 标价不是 Coding Plan 实际消耗。

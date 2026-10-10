# C02 独立只读核查报告（GLM pK，未按开发者自述给通过）

## 一、emitContext 跨 provider 判断（Root 新指令，本票不动运行代码）

**结论：context hook 架构上可覆盖四场景且可达 cursor/blob 形状，但有两个接线前提（单层注入、尾形状仍需合并感知）。**

证据链（18.8.0 pi-coding-agent，`/tmp/orbit-c02-sdk-188/package`）：
- `src/sdk.ts:4112-4114`：`transformContext = emitContext(messages) → wrapSteeringForModel`；`onPayload = emitBeforeProviderRequest` 是其后的最后 wire 层。
- 调用点（dist/cli.js）：主循环每请求构建 `Zuo`（15177922 附近，`o=await t.transformContext(o,s)` 后 `convertToLlm`）与 live-steering `toProvider`（15177591，即 `deliverAs:'steer'` 唤醒的当轮请求）**都先过 emitContext 再 convertToLlm→provider 序列化**。`Zuo` 在主 agent loop 内（15171910），即每工具迭代/每 turn/压缩后重建/唤醒触发 turn 全走。
- `emitContext`（dist 25927893）`structuredClone(messages)` 交 handlers，结果 **wire-only 不回写 session** → 每请求重派生、无跨请求累积。
- 官方扩展示例 `examples/extensions/plan-mode.ts:330` 确认 `pi.on("context")` 是公开 API，操作 `event.messages`（AgentMessage 层）→ cursor/blob（Root 引 pi-ai 18.8 cursor.ts:5484 的 onPayload 形状缺陷）在转换之前，天然可达。

**两个前提**：
1. **单层注入**：context 层若与现有 onPayload 投影并存，每请求两份投影。onPayload 路径须撤除或门控。
2. **尾部形状**：**18.3.4** pi-ai `convertAnthropicMessages`（本地 runners node_modules 唯一可读源）逐消息 push user param，仅连续 assistant 有 "Continue." 修补，**连续 user/toolResult 无合并**——context 层尾部盲追加 user AgentMessage 在 anthropic 会 400；须合并进最后 user AgentMessage；尾=toolResult（mid-turn 工具循环）在 context 层同样无法干净并文本，该窗口与现 payload helper 的 null fail-open 等价（非回归非改进）。另 `wrapSteeringForModel` 在 emitContext 之后运行，投影位置与 steer 重排的相互作用未运行验证。

**版本声明**：架构链读自 18.8.0 src/dist；adapter 合并行为读自本地 18.3.4 pi-ai；pi-ai 18.8 未在本地，cursor.ts:5484 采信 Root 引用未独立读。

## 二、C02 四场景核查（当前工作树实际代码）

**覆盖成立的证据**：
- 普通/amend：`omp-host.mjs:3393-3405` bound+active 每 request 重派生；`goalProjectionText`（1698-1750）instruction/amendments/basis/continuation **全文+sha256+来源标签**，不可读组件显式列为“投影不完整+恢复动作”；amend 落盘 `amendments/{n}.txt`+source（task_runtime.rb:1088-1093），amend 后同 turn 续请求即携带新版。
- 自定义唤醒：`deliverCustomMessage`→`sendCustomMessage({triggerTurn,deliverAs:'steer'})`（2286-2344），不经 before_agent_start，但 provider 请求必经 hook：SDK `Ces=emitBeforeProviderRequest` 挂 agent 构造 `onPayload`（dist 26239162），**返回值替换请求体**（25928727 `if(u!==void 0)o=u`）→ bound+active 路径覆盖。
- 压缩/恢复：投影每请求从盘上 durable record 重派生（不依赖 session 记忆）✓；resume 后 `resolveBoundTask` 盘上回扫 `connection.thread_id`（2007-2034）✓。
- 可追溯：`goal_projection` collab 记录 source/input_digest（只读 orbit-root-binding helper）/projection_sha256/model/channel/delivered_claim（1759-1784）✓。
- 暂停：授权边界行在投影尾；paused+confirmed+本任务来源消息窗口（3429-3436）只投 continuation+投影、不自动重启 ✓；ownership/runtimeAbandoned 不满足时跳投影不冒充 ✓。
- tool 配对：`appendToMessagesPayload` 当前工作树版（含 git diff @@ -657/-666 修复 hunk）：assistant tool_use 尾 null fail-closed、user 尾原地合并、其余尾保留全部消息追加、Responses call-item 尾 null ✓。

**缺陷/边界（位置+实际影响）**：
1. `omp-host.mjs:3405/3385` `if (projected)` — payload 形状不可扩展（空 input、未知尾、cursor blob）时**该请求静默无投影、无记录无告警**（delivered_claim 只记成功首投）。影响：单请求授权范围不可证，下一可达请求自愈；与“不可读原件必须显式 omission”的自我要求不符。建议：null 时记 collab 观察事件，不 abort。
2. cursor/blob 类 provider 即缺陷 1 的现实实例（Root 已发现的跨 provider 缺口）；在 Root 通知 K3 的修复落地前，**不声称所有适配型号已验证**。
3. `goalProjectionRecorded`（1692）进程内存去重：resume 后新进程重记首投——与 delivered_claim 文案一致，非缺陷，如实声明。
4. 阅读边界：`applyCooperationPolicy`(1904)/`continuationBlock`(1547) 仅读与投影交界部分，未逐行审 policy 全文；Codex goal 源码本轮未重读（上轮 C08 已读 export/turn 派生机制，goal 投影语义对照沿用 §9/重评记录）。

## 临时资源身份（收尾）

`/tmp/orbit-c02-sdk-188/`：我建的 pi-coding-agent@**18.8.0** tarball+解包（npm pack 下载，非复用旧目录）。Root 裁定后我可删除或留作 K3 落地 context hook 的参照。未写任何共享文件/总TODO；未动运行代码。
# C02 只读核查（续）：K3 context hook 现行版 + wake 去重

## Root 指定四点核验结果

**1. paused+confirmed 投影尾重复原授权——已修复，现行版通过**。`omp-host.mjs:3544-3546` 现为投影加显式前缀：“本任务当前为已确认停止的暂停状态；以下目标投影只供判断本轮消息与原任务的关系，**不构成恢复执行或续跑授权**”，且 `recordGoalProjection` 对含前缀全文取 hash（3547-3548）。同请求 payload 层只投 continuationBlock（3412，含 resume_from 决策程序），两者分工不再矛盾：context 投影自我否认恢复授权，续接决策唯一归 continuationBlock。

**2. basis source 字符串丢失——已修复，且与真实数据形状匹配**。实证：`task_record.rb:40-44` basis 元素实为 `{"source" => 文件路径字符串, "path", "sha256"}`（`--basis FILE` 原路径）；旧 `sourceLabel` 对字符串产出 "unknown/unknown" 确曾丢失。现行 `omp-host.mjs:1713` 字符串透传，对象走 kind/id——两形状均覆盖。

**3. tool 配对——不构成缺陷（按当前 SDK 实证，非旧经验推断）**。链路：agent-loop.ts:1316-1323（pi-agent-core 18.8.0）证明 SDK 自身 live steering 就是把 user 消息推入 toolResult 之后的 mid-turn 上下文（`pendingMessages` → `currentContext.messages.push`），是一等支持流程；三层转换（pi-coding-agent `convertToLlm` messages.ts:1204 逐消息、pi-ai `transformMessages`、`convertAnthropicMessages`）均无相邻 user 合并，adapter 仅显式修补连续 **assistant**（5381 "the API rejects consecutive assistant messages"）。即 context hook 追加尾部 user 与 SDK 自身 steering 同形状同层——supported。**边界**：此为代码形状等价+SDK 流程存在性证明，非我发起的真实 provider 调用；Root 可用新构建真实 K3 调用终验。ephemeral：`emitContext` structuredClone（runner.ts）+ `Zuo` 局部变量 wire-only，不落 session；每请求重派生 → amend/恢复/压缩下“每次当前输入”成立。

**4. payload 不重复——成立**。`injectGoalProjection` 已全部移除（grep 零命中）；goal 唯一通道 = context hook（3523-3549）；payload hook 现仅 entry/policy/guidance（3393-3405）+ paused 窗口 continuationBlock。K3 测试 `omp_native_gate_test.mjs:436-439` 断言 payload 形状无 `[orbit-goal]` ✓；`recordGoalProjection` 去重键含 channel（1761），事实不含原始 payload（测试 448 行断言）✓。

## wake 去重变化核查（Root 新指令）

`task_runtime.rb:3277-3315` 现行版：全文副本已移除，注释明示“per-request host context hook projects the complete durable goal；wake 只是 versioned next-action notice”。保留项实证：`input_digest`+来源引用（3299）、有价值进展/真实在途等待/无进展三分（3300-3302）、once-per-reviewed-version 门 `attempts[key]`，key=SHA256(artifact_root+input_digest+current_digest)（3292-3295）✓。**custom wake 不依赖 before_agent_start 确认**：`send_message` → plugin `request("send")`（plugin_connection.rb:128-136）→ `deliverCustomMessage` → `sendCustomMessage({triggerTurn, deliverAs:'steer'})`（omp-host.mjs:2286-2296）→ idle 时主循环 `Zuo`、streaming 时 steering `toProvider`，两条都必经 `transformContext`→`emitContext`（sdk.ts:4112-4114；dist 15177591/15177922），before_agent_start 缺席无影响 ✓。omp-host.mjs 内 instruction.txt 全文读取仅剩 1717（context hook）；1554 continuationBlock 只引用路径、1927 只取 digest——无第三通道 ✓。

## 直接读取的固定 Codex 源码/测试（本轮亲读，非转述）

`core/src/context/user_goal.rs`（host 注解定授权、markers 控可见性、MAX_OBJECTIVE_BYTES=700 **超限整条省略**——“截断不能把限制变成授权”）、`core/src/session/retained_context.rs:84-124`（goal 先过持久化屏障 `try_ensure_rollout_materialized` 才进 live 上下文，“failed append must not change live authorization"）、`context/contextual_user_message.rs`（host 注解优先于文本标记）、`retained_context_tests.rs:23,84`（持久化顺序/屏障测试）。Orbit 适配差异如实：Codex 把 goal 持久化为带注解 history item 随重放自然存活；Orbit 不能改写 OMP session，改为每请求从 durable record 重派生——语义等价靠“每次完整投影+不完整时显式 omission”达成。

## 真实缺陷/边界（现行版）

1. **投影尺寸无上界**（边界，非缺陷）：Codex 对 >700B 目标整条省略；Orbit `readPart` 无条件全文投影，超大 instruction.txt/amendments 会按全文进每个请求。与“截断窄化授权”的合同选择一致，但无 Codex 式 omit-whole 兜底——量级风险未知，建议 Root/K3 评估是否需要与 64KiB 程序上下文口径对齐的上界。
2. **30s handler 超时 fail-open**（边界）：hook 每请求做 resolveBoundTask 盘扫+N 次文件读（EXTENSION_HANDLER_TIMEOUT_MS=30_000，runner.ts:130）；超时/异常该请求无投影且无投影事实记录，下一请求自愈。wake 文案“请求上下文另行完整投影”在该窗口会暂时落空。
3. **tool pairing 未做真实 provider 终验**：形状等价于 SDK steering（见第 3 点），建议列 Root 的真实矩阵项。
4. **测试缺口**：K3 新测试覆盖 active/payload 不重复/amend/不可读 omission（omp_native_gate_test.mjs:419-475），未覆盖 context hook 的 paused 分支前缀与 basis 字符串 source 两处新修复——确定性易补，两条断言即可。
5. handler 返回的追加消息无 `setContextHistoryIndex` 戳（runner.ts 对克隆逐条打索引后交 handler，handler 返回的新数组元素未经此步）——下游仅历史映射使用，wire 路径未见表副作用，观察项非缺陷。

未写共享文件/总TODO；未动运行代码；临时目录仍为 `/tmp/orbit-c02-sdk-188`（18.8.0 tarball+解包）与 Root 指定 runtime 树（pi-coding-agent 18.8.0 + **pi-ai 18.3.4** 实配——cursor.ts:5484 属宿主 18.8 pi-ai，本树无，采信 Root 引用）。
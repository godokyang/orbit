全部相关测试通过。C02 实现完成，释放 omp-host 热点给 C04。

## C02 交付与热点释放

**改动（5 文件）**
- `plugins/omp-host.mjs`：新增 `goalProjectionText`/`injectGoalProjection`（`[orbit-goal]`）；接入 `before_provider_request` 四个路径——bound active 普通/amend/自定义唤醒请求（owned 且非 abandoned，与 policy 共用一次 `verifiedOwnership`）、entry-recovery bound 路径、paused 续接路径（continuationBlock 同载荷追加）、自动 start 首请求。投影=原要求＋全部有效修订＋指定依据＋续接来源**完整原文**（各带来源 kind/id、sha256、字节数），任何组成部分不可读→头句撤回完整性声明、逐条标明"仍是有效授权事实，不能按缺失片段继续，先恢复原件核对当前约束"。首次 append 事实记 `goal_projection`（channel、真实 input_digest——复用 `readRootBinding`/orbit-root-binding，未复制 Ruby 摘要、projection_bytes/sha、实际 model；dedup 键含 model，resume/换型后同版本再记一次；delivered_claim 明确只证本进程该版本该型号首次 append，后续请求逐请求重投影不逐条记录）。修复 `appendToMessagesPayload` 非 user 尾替换缺陷：现保留全部 messages 追加新 user，tool result/assistant 配对不丢；assistant tool_use 尾保持 null 门。
- `lib/orbit/task_runtime.rb`：`continue_unfinished_task` 唤醒消息携带完整当前目标（来源 kind/id、sha256、input_digest、逐条修订完整原文）＋有价值进展/真实在途等待（具体存活句柄）/无进展（工具/消息/TODO 数量不算）/重复阻断改变下一动作的分类要求；读取失败降级为原短消息不阻塞唤醒。
- 测试：`omp_native_gate_test.mjs` +C02 三场景（普通请求完整投影＋事实记录/amend 后下一请求含完整修订与来源/不可读原要求显式省略），并修两条 policy 断言适配投影共存（Root 的 6 行 preflight 断言未动）；`omp_entry_recovery_test.mjs` 修两条旧缺陷行为断言＋1 个 tool-tail 回归（工具输出不丢）；`task_runtime_test.rb` 既有唤醒 fixture +4 行断言（完整目标、版本、进展分类）。新增约 84 行、3+1 场景，在协调预算内。

**实际验证（确定性）**：`omp_native_gate_test` PASS、`omp_entry_recovery_test` PASS、`task_runtime_test` PASS；`omp_collab_evidence`/`work_unit_scope`/`omp_model_picker`/`model_call_receipts`/`root_verifications`（两文件）全 PASS。

**五维事实**
- 问题影响：原 statusBlock 只在 `before_agent_start`，自定义唤醒不经过该 hook，amend/压缩/恢复后请求无可核对目标投影；唤醒消息无目标原文与版本。
- Codex 前提（固定 36ae1561）：`continue_if_idle`→`start_turn_if_idle`（permit＋deferral＋NotIdle/PlanMode/ServerDraining 原子拒绝）；continuation.md 完整 objective＋进展/已验证等待/无进展/阻断审计为**模型义务**非程序验证。测试阅读边界：ext/goal/tests/steering.rs 全读；turn_input_submission.rs 选读（Plan 原子拒绝等段）；goal_extension_backend.rs 只读测试名索引，accounting.rs 未读。
- Orbit 差异：无 goal-state permit/接收处 expected-turn 接口；复用 task 记录与现有生命周期，不建 Goal 数据库/状态机，不无条件 idle 唤醒（沿用现版本门一次）。
- 采用理由：每请求从耐久记录重投影统一覆盖五类窗口；完整原文不截短（容量策略不在本轮）；digest 取真实 TaskRecord 定义。
- 边界剩余：未证明真实模型依投影行动、live 无催办自主推进（留 Root 真实安装验证）；真实 compact 会话投影未取证；C05 SDK admitted-submission 未触碰。

**身份**：provider/model/reasoning＝kimi-code/k3-256k:high（工作台元数据）；原生 session 文件路径：unknown（未向我暴露）。Codex 测试边界如上。omp-host 热点现在释放。

✅ 三项测试全绿。主实现与测试编辑完成，现释放 `plugins/omp-host.mjs` 写入归属。

## C02 收口报告

**改动（全部在 plugins/omp-host.mjs + tests/omp_native_gate_test.mjs + 已有的 appendInstructionToPayload tail 修复）**

1. **目标投影移至 SDK `context` hook**（omp-host.mjs 3512-3550）：payload hook 还原为本票前原样。`context` hook 在每请求 `convertToLlm` 前运行，覆盖普通/amend/自定义唤醒/压缩后请求及 Cursor 类 protobuf/blob shape（payload hook 对此 shape 无 `messages`/`input` 可挂载）。`prepareProviderCall` 每调用从 `context.messages` 重派生——投影不累积、不进会话历史。payload hook 不再携带 goal，无双重投影（gate 显式断言）。
2. **goalProjectionText**：完整原要求全文 + 每条有效修订全文 + 可追溯来源/sha；任一原文不可读 → 显式"目标投影不完整"+恢复动作，绝不以截断前缀冒充完整授权。
3. **sourceLabel**（1713）：`basis[].source` 为字符串时原样保留；对象取 `kind/id`；缺省 `unknown/unknown`。runtime 实际 amendment.source 为 `{kind,id}` 对象，测试 fixture 按此真实形态。
4. **暂停不解除**：暂停任务仅在分支引用先验输入源时投影，且投影前缀明示"已确认停止的暂停状态…不构成恢复执行或续跑授权"；`授权边界`行保留用户暂停/讨论/取消优先。事实记录 sha 覆盖实际追加文本（含前缀）。
5. **首调用诚实**：auto-start 的首个模型请求在 `before_provider_request` 才建任务，`context` 已先行——首调用本身含完整用户要求原文，本实现不对其记录任何投影事实；记录仅覆盖后续实际经 context 追加的调用（recordGoalProjection 的 delivered_claim 即此语义）。
6. **事实落账**：`goal_projection` collab fact 记 `channel:'context_hook'`、真实 `input_digest`（orbit-root-binding 只读 helper）、projection_bytes/sha256、actual model；不落原始 payload；每投影版本×模型首次追加记一次。

**验证（均真实 exit）**
- `node tests/omp_native_gate_test.mjs` → PASS, exit 0（C02 场景：普通请求单次投影、stray 会话无投影、amend 次请求全文+来源、不可读显式省略、payload 不再重复 goal、2 条版本化事实）
- `node tests/omp_entry_recovery_test.mjs` → all assertions passed, exit 0（entry 路径还原无损，含 tool-tail 安全修复回归）
- `ruby --disable-gems tests/task_runtime_test.rb` → TASK_RUNTIME_TEST_PASS

**边界与剩余**：未做 live 模型验证（授权内真实请求矩阵由 Root 统筹）；`context` hook 每请求对未绑定会话做一次 tasks 目录扫描（map 未命中时），成本有界；GLM 独立核查新版待 Root 派发。

**热点释放**：`plugins/omp-host.mjs` 写入归属即刻交还 Root，可串行集成 C04/C05；本成员不再编辑该文件。
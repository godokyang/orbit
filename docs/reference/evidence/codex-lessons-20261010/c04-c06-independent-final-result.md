## 复核结果（限两条改动）

**C06 execCwd 修正 — 通过**
- `assertCommandReadable(command, root, allowed, execCwd)`：成员调用处传入已 scope 校验的实际 `cwd`（work-unit-scope.mjs:510），相对 token/相对 PATH 条目以 `base = execCwd ?? root` 解析——与实际 bash 执行 cwd 语义一致，我报告的误阻断/误放行组合消除。
- 派前无 execCwd 时相对 exe 或 PATH 含相对条目 → 直接 return（unknown，不认证），且 `validateWorkUnitPreflight` 文档注释改为"not proof of complete command/dependency feasibility"——不误认证，诚实。
- 方向均 fail-safe：派前 unknown 留给成员调用时判定，内核沙箱仍是最终强制。新增子 cwd 脚本回归 Root 已报全过，未重跑。

**C04 agent 名误填 model 诊断 — 通过**
- `sessionAgents.has(selector.trim())` 在 resolve 之前拦截（omp-host.mjs:2959-2968），原因含两条具体修正路径（`agent` 字段+省略 model，或 `sessionAgents.get` 的精确 provider/id + `agent:"task"`）+ 先 declare 持久 work-unit 带 `orbit-unit: id`；明确"其他 alias 同样失败、不要当作不可用型号路由"——防同类重试和错误降级。
- 记录同一 `native_task_preflight_failed` 事实（dispatched:false），不自动改写调用，符合"诊断改变下一次真实调用"。
- toolDescription（host.mjs:35）已同步 agent/model 字段分工，先声明 work-unit 的顺序一致。

**保留项**：retained owner 回退（理论分支，当前 SDK 不可触发）按 AGENTS 不加兼容/测试，限制照实留——同意此处置。无新缺陷，未扩范围。
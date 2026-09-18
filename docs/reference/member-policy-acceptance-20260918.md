# 成员允许名单、full access 与 Jev 分工提示验收（2026-09-18）

本文记录最小成员允许名单、Codex 执行成员和 `orbit codex` 新会话默认 full access，以及切片 D 有界 Jev 分工提示的开发侧验证。OpenCode／OMP 成员沿用 Root 原生权限。验证时的源码基线为提交 `f51d537` 之上的未提交改动；本机安装 0.6.5（`content_digest e860c0da…`、`installed_at 2026-09-18T08:13:06Z`），Codex `0.155.0`。

## 允许名单

- `~/.config/orbit/members.json` 只识别 `allowed_kinds`：文件缺失时默认 `codex、omp、opencode、kimi、cursor-agent、grok`；存在时完整覆盖；空数组禁止创建新成员；未知键、重复项、非法 JSON 明确报错。`native` 在派发时解析为 Root 实际 kind 再检查。确定性用例覆盖以上路径。
- 真实任务 `975e4686`（OpenCode Root，配置 `{"allowed_kinds":["kimi"]}`）：
  - `orbit delegate --kind codex` 在创建前被拒绝：`member kind "codex" is not in allowed_kinds (…: kimi)`；退出码 1；
  - `orbit delegate --kind kimi` 报缺口：`allowed but has no controlled adapter from a opencode Root`；
  - 两次拒绝后 inbox、成员列表与成员宿主进程均为 0。
- 名单变化不影响已登记成员：任务 `975e4686` 的两个成员完成后把名单改为空数组，`orbit stop` 仍确认停止两个成员（`member_stop_results` 均 `confirmed=true`）并关闭 Codex 成员宿主（进程组退出确认），任务 `paused`。
- `orbit doctor` 分别显示允许、可调用与缺口：配置 `["codex","opencode","kimi"]` 时输出“可调用成员：codex、opencode（provider：opencode）”“不可调用成员：kimi（允许但无受控适配器）”。**会话连接失败时不报告可调用成员**：任务 socket 不可达时 `callable_kinds` 为 null、`connection_ready=false`，文本显示“可调用成员：未验证”；同一记录在 socket 可读回原生状态后才按 provider 报告可调用 kind（针对性用例覆盖两种输出）。只声明已验证路径：同宿主 codex／opencode／omp 与 OpenCode Root → codex；未新增供应商适配器。

## full access

- Codex 成员：`thread/start` 默认 `approvalPolicy: never`、`sandbox: danger-full-access`，显式更严格值可覆盖；任务自有成员宿主不再收到部分 Orbit MCP 覆盖。确定性用例断言请求参数与显式覆盖。
- 真实任务 `975e4686` 中两个成员并行工作：同宿主 OpenCode 成员与 OpenCode Root → Codex 成员（`gpt-5.6-sol`）。Codex 成员在项目外创建 `/tmp/orbit-member-full-access.txt`（内容 `ok`）成功，证明 full access 生效且无审批；两个结果都回到原 Root 并被集成（`member_result`，Root 复核测试输出与文件）；两者停止确认均通过，成员宿主进程组退出确认、目录清理。
- `orbit codex` 新会话：TUI 显示 `permissions: YOLO mode`，项目外写文件成功。启动器仅在用户未显式给权限参数时为**新会话**注入 full access；显式 `-s`／`-a`／`-c sandbox_mode`／`--dangerously-bypass-approvals-and-sandbox` 等原样保留，不静默丢弃。
- **恢复会话的已知缺口**：`orbit codex resume --last` 恢复的会话沿用原保存权限，项目外写入被拒（`Operation not permitted`）；显式带权限覆盖的恢复命令（`--dangerously-bypass-approvals-and-sandbox` 与 `-c sandbox_mode=…`）都被 Codex 拒绝：`Error: Permission overrides are not supported when resuming a remote task`。启动器不对恢复注入权限参数（注入会使恢复直接失败），也不声称已修复该限制；恢复后的 full access 需要 Codex 原生支持或用户在会话内用原生 `/permissions` 调整。已记录为限制。
- 检查者与裁定者仍是只读 Codex，权限未扩大；全局 Codex 配置未修改。

## Jev 分工提示（切片 D）

- 同一 Jev 请求新增 `delegatable` 概率；真实 `jev-1.13.0` 返回该分数（本仓验证样本观察到 0.17）。
- 只有名单允许且实际可调用的成员存在时才可能提示，且每个任务至多一次；提示不派发、不选择 kind。提示在状态新鲜度复核后发送：同次判断触发的过程／产物检查优先，提示不得打断或推迟检查；观察在判断期间发生变化时丢弃提示，不把旧状态的判断当依据。确定性用例覆盖：发送一次且不再重复、无可调用成员时不发送、Root 实际 `delegate` 后记录 `delegation_hint_followed`、检查决定同次不被提示打断、状态变化时提示被丢弃并由后续新鲜判断送达。
- 本次真实任务分数低于阈值，未出现提示（无信号时不制造提示）；既有 Jev 失败回退与定时／交付检查未改动。**样本未触发提示，不能据此声称分工收益已验证。**

## 测试与未覆盖

- `npm test` 22 项通过（新增成员策略、派发前拒绝、Jev 提示边界、Codex 成员 full access、启动注入与 doctor 名单用例，Node 桥接测试隔离开发者真实名单）。
- 未在本轮重跑 OMP 同宿主成员的完整真实任务（此前已有验收，权限沿用 Root 原生设置，未新增限制）；其他 kind 与 Herdr 控制仍未验证，不列为受控。
- 恢复会话 full access 缺口见上；验收时实现尚未提交、推送或发布。

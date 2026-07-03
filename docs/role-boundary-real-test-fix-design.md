# Role boundary real-test fix design

本文记录 2026-07-03 真实测试暴露的 Orbit 越界写入问题，以及准备实施的修复方案。目标是防止 team 模式下 lead 越界写入 implementation evidence、覆盖 task-scoped rule resolution，或用旧 review/test pass 误放行新的 implementation，同时保留 solo 模式下 lead 自己完成实现的简单工作流。

## Status

- Status: proposed
- Scope: Orbit CLI / evidence protocol / gate freshness
- Compatibility: breaking change; projects upgraded to this package must run `orbit init` again before using task/evidence commands.
- Non-goal: 不修复已经产生的历史 evidence 内容；历史修复应通过单独的 repair evidence 或重新 review/test 完成。
- Runtime baseline: Herdr-only automatic runtime. Role-boundary design must use current `binding` / `herdr` fields as primary runtime diagnostics; old `transport.*`, `binding_status`, and static `healthy` wording are not valid liveness contracts.

## Incident

真实测试中的任务实际进入了 team 分工语义：实现工作应由 coder 执行，lead 只负责调度、审计和收口。现有 task 只用单个 `target_role` 表达这个边界：

```yaml
target_role: coder
```

但后续 follow-up 中，lead 重新进入同一个 coder task，执行了代码审计、修改和 implementation/evidence 操作。过程中生成或覆盖了默认 rule resolution 文件：

```text
.orbit/rules/locusmind-client-annotation-capabilities-resolution.json
```

该文件后来以 lead 身份写入，内容变成：

```text
valid=false
resolved_role=lead
conflict: task target_role "coder" does not match resolved_role "lead"
```

正确的 coder resolution 仍然存在：

```text
.orbit/rules/locusmind-client-annotation-capabilities-coder-resolution.json
valid=true
resolved_role=coder
```

问题不是 coder resolution 缺失，而是 Orbit 没有把项目默认协作模式、task ownership 和 implementation authority 清楚表达出来。evidence 挂到了错误/漂移的默认 resolution 文件上，后续 gate 又看到了旧的 review/test pass，于是没有强制重新 review/test 最新 implementation。

## Root Cause

这次越界由五个机制缺口叠加造成：

1. `orbit evidence attach-rule` 没有 task 语境。

   当前 attach 只把一个 rule resolution 文件挂到 evidence manifest，没有强制检查：

   - resolution 是否 `valid: true`
   - resolution 的 `resolved_role` 是否等于 `task.target_role`
   - resolution 的 task hash / task path 是否和当前 evidence 绑定的 task 一致
   - resolution 文件是否被其它 role 覆盖

2. `orbit evidence add --kind implementation` 是 free-form。

   它没有要求 `--task`，也没有写入完整 `role_execution_context`。因此 lead 可以给 coder task 添加 implementation/pass record，Orbit 只能看到“有 implementation evidence”，看不到这是越权实现。

3. gate freshness 只看 review/test 是否存在 pass，不看它们是否覆盖了最新 implementation。

   `wait-gate` 能识别 review/test role identity，但没有强制：

   ```text
   latest_review.created_at >= latest_implementation.created_at
   latest_test.created_at >= latest_implementation.created_at
   ```

   所以旧 review/test pass 可能在新的 implementation evidence 之后仍然被视为 ready。

4. task-scoped rule output 文件名容易被不同 role 覆盖。

   `rules resolve --task --output` 的常见默认建议使用 `<task>-resolution.json` 这类通用路径。lead/coder 在同一 task 上反复操作时，容易覆盖同一个 rule artifact。覆盖后 evidence 仍指向同一路径，但文件内容已漂移。

5. Orbit 把项目默认协作模式、task ownership 和 implementation authority 混在一个 `target_role` 里。

   真实使用中有两种稳定模式：

   - solo：lead owns task，也亲自实现。
   - team：lead owns task，但 coder 执行 implementation。

   如果只用 `target_role`，要么把 task 标成 `lead`，丢失 coder 执行边界；要么标成 `coder`，又让 lead 的调度/收口行为看起来像 role mismatch。更关键的是，大多数项目会形成固定协作习惯，不能要求 agent 每次从用户一句“用 Orbit 流程执行”里重新猜模式。这个灰区会诱导 lead “顺手实现”，最终突破 team 边界。

## Desired Invariant

Orbit 对 task 的基本不变量应收紧为：

1. 项目默认协作模式必须全局配置，agent 创建 task 时不得靠改动大小动态猜。
2. task ownership 和 implementation authority 必须分开表达。
3. `operation_mode: solo` 时，lead 可以规划、实现、写 implementation evidence。
4. `operation_mode: team` 时，lead 只能做调度、审计、评论、handoff、sanity check；implementation evidence 必须来自 `implementation_authority` 指定的 role 和 `assigned_instance` 指定的 instance key。
5. evidence 挂载的 rule resolution 必须与 task 和 role 同时匹配。
6. review/test gate 必须晚于最新 implementation record，才可以 ready。
7. task-scoped rule artifacts 不能被不同 role 静默覆盖。
8. Runtime 只按 Herdr 思考：role boundary 不引入 adapter registry、transport fallback 或 pane-id heuristic。

## Proposed CLI Changes

### 0. Project operation default becomes explicit

新增项目级 operation 默认配置，写入 `.orbit/roles.yaml` 顶层：

```yaml
operation_defaults:
  owner_instance: lead-main
  owner_role: lead
  operation_mode: solo | team
  implementation_authority: lead | coder
  assigned_instance: lead-main | coder-main
```

字段语义必须分开：

- `implementation_authority` 是 role，回答“哪个 role 可以写 implementation evidence”。
- `assigned_instance` 是 `.orbit/instances.yaml` 里的 instance key，回答“哪个 concrete instance 是本 task 的 implementation assignee，以及 start/dispatch/hook 默认找哪个 Herdr pane”。team 项目允许多个 coder instance，例如 `coder-main`、`coder-android`、`coder-ios`，不能把 role name 当成唯一 instance。
- `owner_instance` 是 task owner 的默认 instance key，回答“Phase B notice surfacing 应发到哪个 lead Herdr pane”。如果存在 `lead-main`、`lead-mobile` 多个 lead instance，`owner_role: lead` 只决定 role inbox，不能决定 Herdr pane。

推荐语义：

```yaml
operation_defaults:
  owner_instance: lead-main
  owner_role: lead
  operation_mode: solo
  implementation_authority: lead
  assigned_instance: lead-main
```

solo 模式用于单 agent 或 lead 直接实现的工作流。lead 可以执行 implementation，并写入 implementation evidence。

```yaml
operation_defaults:
  owner_instance: lead-main
  owner_role: lead
  operation_mode: team
  implementation_authority: coder
  assigned_instance: coder-main
```

team 模式用于 lead/coder 分工。lead owns task，但不执行 implementation；coder 是 implementation executor。项目一旦把默认模式设为 team，lead 在默认 task 中不再允许因为“小改动”或“顺手修”直接改 production code 或写 implementation/pass evidence。

不放在 `instances.yaml` 的原因：

- `instances.yaml` 描述 persistent agent identity、command、Herdr binding hints。
- `operation_defaults` 描述项目协作策略，是 role/policy 层语义。
- 同一个 instance 可以参与不同项目；项目习惯不应写进 instance 启动绑定。

当前 runtime schema 已收窄为 Herdr-only，`instances.yaml` 中稳定的绑定字段应是：

```yaml
binding:
  adapter: herdr
  workspace: ""
  tab: ""
  pane: ""
  canonical_pane: ""
view:
  min_columns: 120
  min_rows: 36
```

`binding` 是稳定 Herdr handle。`view` 是 launch/layout policy，必须作为 `binding` 的 sibling 字段，而不是 binding 的一部分。`view` 是 Herdr-only 后可以直接提供的体验增强：`orbit start INSTANCE` 不需要猜非 Herdr 终端语义，可以为 lead/coder/reviewer/tester 创建可读的 workspace/tab/pane 布局，避免新 role 被启动到过窄的视图里。`workspace` / `tab` 仍只是 view hint；只有 `pane` / `canonical_pane` 加 Herdr live probe 才能证明 bound/alive。

落地要求：

- validator 接受并校验 sibling `view.min_columns` / `view.min_rows`，拒绝把 `view` 写进 `binding` 的新 schema。
- init template 为默认 instance 写入 sibling `view`。
- `instances status --json` 输出 view policy、observed geometry 和 `too_narrow` diagnostic。
- `start --dry-run --json` 输出 planned workspace/tab/pane 和 planned view policy。
- `start` 创建 Herdr view 时尽量满足 `view.min_columns` / `view.min_rows`；无法满足时输出 explicit warning，不把窄 pane 当作正常 ready。

旧 `transport.kind` / `transport.binding` / `transport.health` 不再作为新配置写入，也不能作为 role-boundary、start、dispatch 或 gate 的 liveness 依据。

`orbit new-task` 创建 task 时，必须把当时解析到的项目默认写成 task execution snapshot：

```yaml
execution_contract:
  owner_instance: lead-main
  owner_role: lead
  operation_mode: team
  implementation_authority: coder
  assigned_instance: coder-main
  source: project_defaults
```

task snapshot 是审计锚点：后续 `.orbit/roles.yaml` 的默认值改变，不 retroactively 改变已有 task 的执行边界。需要偏离项目默认时，只能通过显式 `orbit new-task --operation-mode ...` 或等价受控参数创建 task，并在 snapshot 中记录 `source: explicit_override`。

execution contract validator 必须强校验：

- `owner_instance` 必须存在于 `.orbit/instances.yaml`，且它的 `role_ref` 最终解析到 `owner_role`。
- `assigned_instance` 必须存在于 `.orbit/instances.yaml`，且它的 `role_ref` 最终解析到 `implementation_authority`。
- 如果 `operation_mode: solo`，`owner_instance` 和 `assigned_instance` 默认相同，且都解析到 `owner_role`。
- 如果 `operation_mode: team`，`implementation_authority: coder` 但 `assigned_instance: reviewer-main` 这类配置必须 fail closed，避免 dispatch/hook 找错 Herdr pane。

`orbit init` 必须同时支持参数和交互式选择，参数优先：

```bash
orbit init --operation-mode solo
orbit init --operation-mode team
```

规则：

- 如果传入 `--operation-mode solo|team`，直接按参数生成配置，不再询问。
- 如果没有传入 `--operation-mode` 且 stdin/stdout 是 TTY，显示选择项，让用户选择 `solo` 或 `team`。
- 如果没有传入 `--operation-mode` 且不是 TTY，fail closed，输出 remediation：`Run orbit init --operation-mode solo` or `orbit init --operation-mode team`。
- `--force` 只控制是否覆盖已有文件，不改变 mode 选择规则。
- `team` init 必须生成 `coder` role 和至少一个 coder instance，默认 key 建议为 `coder-main`；`solo` init 可以只生成基础 `lead/reviewer/tester` roles，但 instance keys 必须是 `lead-main`、`reviewer-main`、`tester-main`。
- `orbit init --operation-mode team` 生成的 `operation_defaults` 应为 `owner_role=lead`、`owner_instance=lead-main`、`implementation_authority=coder`、`assigned_instance=coder-main`。
- `orbit init --operation-mode solo` 生成的 `operation_defaults` 应为 `owner_role=lead`、`owner_instance=lead-main`、`implementation_authority=lead`、`assigned_instance=lead-main`。

Breaking change / init policy：

- 新版本不兼容旧 task schema；只有 `target_role` 的 task 不再自动解析。
- 升级到包含本修复的新包后，项目必须重新运行 `orbit init --operation-mode solo|team`，生成带 `operation_defaults` 的 roles config、task template 和 runtime guide。
- 新 task 必须包含 `execution_contract` snapshot。
- CLI 发现旧 schema 时 fail closed，并提示用户运行 `orbit init` 重新生成配置；不提供 `target_role -> operation_mode` 的自动迁移。
- 如果用户需要保留历史 evidence，只能作为历史审计材料读取；新 gate 和新 evidence 不得建立在旧 task schema 上。

evidence 中必须记录：

```json
{
  "role_execution_context": {
    "owner_role": "lead",
    "owner_instance": "lead-main",
    "operation_mode": "team",
    "implementation_authority": "coder",
    "assigned_instance": "coder-main",
    "resolved_role": "coder",
    "resolved_instance": "coder-main",
    "execution_contract_source": "project_defaults"
  }
}
```

### 1. `evidence attach-rule` 增加 `--task`

新用法：

```bash
orbit evidence attach-rule \
  --file .orbit/evidence.json \
  --task .orbit/tasks/task.yaml \
  --rule-resolution .orbit/rules/task-coder-resolution.json \
  --json
```

Fail closed 条件：

- resolution JSON 解析失败。
- `schema_version` 不是已知 rule resolution schema。
- `valid != true`。
- `conflicts` 非空。
- `resolved_role` / `resolved_instance` 不符合 task `execution_contract` 的 role boundary：solo 模式要求 `resolved_role == owner_role` 且 `resolved_instance == owner_instance`；team implementation resolution 要求 `resolved_role == implementation_authority` 且 `resolved_instance == assigned_instance`。
- 如果需要其它同 role instance 接手 implementation，必须创建显式 override evidence；不能让 `coder-android` 静默写入 `assigned_instance: coder-main` 的 task。
- resolution 中的 task path/hash 与 `--task` 不一致。
- evidence manifest 已经绑定到另一个 task hash。

Breaking behavior：

- 新版本中，task-bound evidence 必须带 `--task`。
- 缺少 `--task` 且 evidence manifest 需要 task 语义时直接失败，不提供 warning-only 兼容期。
- 旧 rule resolution 或旧 evidence manifest 只能用于只读审计，不能继续 attach 到新 evidence。
- 文档、helper 输出和 `orbit init` 模板全部改成带 `--task`。

输出契约示例：

```json
{
  "action": "blocked",
  "reason": "rule_resolution_role_mismatch",
  "owner_role": "lead",
  "owner_instance": "lead-main",
  "operation_mode": "team",
  "implementation_authority": "coder",
  "assigned_instance": "coder-main",
  "execution_contract_source": "project_defaults",
  "resolution_role": "lead",
  "resolution_instance": "lead-main",
  "resolution_valid": false,
  "conflicts": [
    {
      "source": "task.execution_contract.implementation_authority",
      "message": "Task implementation_authority \"coder\" does not match resolved_role \"lead\"."
    }
  ]
}
```

### 2. `evidence add --kind implementation` 要求 `--task`

新规则：

- `--kind implementation` 必须带 `--task`。
- record 必须写入 `role_execution_context`，字段沿用 `evidence submit` 的上下文结构。
- CLI 从 task `execution_contract` 读取 mode，不在 evidence 命令里重新读取当前项目默认。
- solo 模式下，当前 `resolved_role` 必须等于 `owner_role`，且 `resolved_instance` 必须等于 `owner_instance`。
- team 模式下，当前 `resolved_role` 必须等于 `implementation_authority`，且 `resolved_instance` 必须等于 `assigned_instance`；lead 不允许写 implementation record。
- 同 role 的其它 instance 不能写 implementation record，除非 task 中存在显式 override evidence，并且该 override 记录了原因、授权者和替代 instance。
- lead 在 team task 上只能写 `command`、`lead_sanity`、`coordination` 或 `audit_note` 这类非 implementation record。
- `--kind pass` 如果表示 implementation pass，也必须走同一套 implementation authority 检查；review/test pass 仍按各自 gate role 校验。

示例失败：

```json
{
  "action": "blocked",
  "reason": "implementation_role_mismatch",
  "owner_role": "lead",
  "owner_instance": "lead-main",
  "operation_mode": "team",
  "implementation_authority": "coder",
  "assigned_instance": "coder-main",
  "execution_contract_source": "project_defaults",
  "resolved_role": "lead",
  "resolved_instance": "lead-main",
  "allowed_kinds": ["command", "lead_sanity", "coordination", "audit_note"]
}
```

需要同步修改：

- `orbit evidence add --help`
- runtime guide 中所有 implementation evidence 示例
- tests 中直接 add implementation 的旧用法

### 3. `implementation_instance_override` evidence

同 role 的其它 instance 接手 implementation 必须有一条结构化 override evidence。它不是普通 comment，也不能靠口头约定或 pane message 代替。

建议命令：

```bash
orbit evidence add \
  --file .orbit/evidence.json \
  --task .orbit/tasks/task.yaml \
  --kind implementation_instance_override \
  --from-instance coder-main \
  --to-instance coder-android \
  --reason "coder-main is blocked on local Android SDK setup" \
  --expires-at 2026-07-03T16:00:00Z \
  --json
```

最小 record schema：

```json
{
  "kind": "implementation_instance_override",
  "task": ".orbit/tasks/task.yaml",
  "task_sha256": "sha256...",
  "from_role": "coder",
  "from_instance": "coder-main",
  "to_role": "coder",
  "to_instance": "coder-android",
  "authorized_by_role": "lead",
  "authorized_by_instance": "lead-main",
  "reason": "coder-main is blocked on local Android SDK setup",
  "created_at": "2026-07-03T10:18:00Z",
  "expires_at": "2026-07-03T16:00:00Z",
  "no_expiry": false
}
```

Rules:

- `from_instance` 必须等于 task `assigned_instance`，且它的 `role_ref` 必须解析到 `implementation_authority`。
- `to_instance` 必须存在于 `.orbit/instances.yaml`，且它的 `role_ref` 必须解析到同一个 `implementation_authority`。
- `authorized_by_role` / `authorized_by_instance` 必须等于 task `owner_role` / `owner_instance`，或者来自受控 CLI policy 明确允许的管理员 role。
- 必须提供 `reason`。
- 必须提供 `expires_at`，或者显式 `no_expiry: true` 并记录原因；默认不允许无期限 override。
- override 只授权 implementation evidence 和 implementation rule resolution 的 instance mismatch，不改变 task `assigned_instance`，也不授权 review/test verdict。
- audit / wait-gate 在接受 `resolved_instance != assigned_instance` 时必须找到未过期、task hash 匹配、授权者匹配、目标 instance 匹配的 override evidence；否则 fail closed。

### 4. `wait-gate` / `audit` 增加 stale gate 规则

新规则：

- 找到最新有效 implementation record。
- 对每个 required gate，找到最新可接受 pass record。
- 如果 gate pass 早于最新 implementation，gate 不 ready。

建议输出：

```json
{
  "gate": "review",
  "ready": false,
  "blocking_reason": "stale_after_implementation",
  "latest_implementation_created_at": "2026-07-03T10:18:00Z",
  "latest_review_created_at": "2026-07-03T09:42:00Z",
  "remediation": "Request a fresh review after the latest implementation record."
}
```

时间策略：

- 正常按 `created_at` UTC 时间比较。
- `created_at` 无法解析时，该 record 不得用于 freshness pass。
- 时间相同且 record 顺序不清时 fail closed，要求重新提交 gate evidence。

### 5. `rules resolve --task --output` 默认建议加 role/instance 后缀

文档和 context preflight 中推荐路径改为：

```text
.orbit/rules/<task-id>-<instance>-resolution.json
.orbit/rules/<task-id>-<instance>-context.json
```

如果用户显式写入一个已存在 resolution 文件，CLI 应读取旧文件并拒绝静默覆盖以下情况：

- 旧文件 `resolved_role` 与当前解析结果不同。
- 旧文件 task hash 与当前 task 不同。
- 旧文件 `valid: true`，当前解析结果 `valid: false`。

允许覆盖的情况：

- 同 task、同 instance、同 role 的刷新。
- 用户传入未来显式参数，例如 `--force-overwrite-rule-artifact`，并在 JSON 输出中记录风险。

### 6. Agent 操作规范收紧

任何 task 上手前必须运行：

```bash
orbit whoami --task <task> --json
```

如果当前 role 不符合 task 的 operation mode：

- solo：owner role 可以继续 implementation。
- team：lead 只能做调度、审计、评论、任务拆分、handoff 或请求 implementation authority 继续。
- team 下 lead 不能写 `implementation/pass`。
- lead 不能把自己的 invalid rule resolution attach 到 evidence。
- 如确需 lead 接管实现，默认新建 solo repair task；只有在用户显式创建 override task 后，才能偏离项目默认，不能在 team task 中临时“顺手修”。

### 7. Herdr-aware hooks as early guardrails

Hook 可以用来降低任意 role/instance 手快越界的概率，但不能作为唯一安全边界。所有关键约束仍必须在 Orbit CLI 内 fail closed，因为用户或 agent 可以绕过某个具体 agent client 的 hook。

Herdr-only 后，hook 不需要设计成跨 runtime adapter。建议提供一组 Orbit CLI entrypoints，由 Herdr-integrated agent client 调用；普通 shell 仍可手动运行这些命令，但不会得到自动 preflight 体验。

```bash
orbit hook pre-command --intent-json PATH|- --json
orbit hook pre-edit --intent-json PATH|- --json
orbit hook pre-evidence --intent-json PATH|- --json
orbit hook pre-start --intent-json PATH|- --json
orbit hook pre-idle --intent-json PATH|- --json
```

hook 输入只接收 caller intent 和不可避免的本地上下文：

- command/edit/evidence/start intent
- task path
- edited path 或 evidence kind
- `ORBIT_INSTANCE` / `ORBIT_ROLE` env hint
- cwd

`--intent-json` 是必需入口，避免 hook 从外部上下文猜测动作。各 hook 的最小 intent 字段：

- `pre-command`: `argv`, `cwd`, optional `task`
- `pre-edit`: `path`, `operation`, `cwd`, optional `task`
- `pre-evidence`: `kind`, `file`, `cwd`, optional `task`, `rule_resolution`, `report`
- `pre-start`: `instance`, `force`, `cwd`, optional `layout`
- `pre-idle`: `task`, `cwd`, optional `latest_evidence`

Herdr context 不能由 caller 传入并被信任。Orbit CLI 必须自己采集并校验：

- current workspace/tab/pane/canonical pane from Herdr/current pane env
- bound pane from `instances.yaml`
- Herdr live probe result
- detected agent client on the bound pane, when available
- view size / geometry, when Herdr reports it

hook 输出可以包含 `herdr_context_summary` 方便诊断，但任何 liveness、client、cwd、geometry 判断都必须来自 Orbit CLI probe，不接受 caller 声称的 live probe。

hook 输出使用统一结构：

```json
{
  "action": "allow | block | warn | require_confirmation",
  "reason": "role_boundary_violation",
  "message": "team task implementation must be written by coder, not lead",
  "remediation": "Ask coder to continue, or create a solo repair task."
}
```

Hook 应覆盖三类高频事故：

1. Role boundary preflight

   - 任意 role 准备执行不符合 task `execution_contract` 的 production edit 时，`pre-edit` 返回 `block`。
   - team task 中，非 `implementation_authority` 的 role 准备编辑 production code 或提交 `implementation/pass` evidence 时，`pre-edit` / `pre-evidence` 返回 `block`。
   - solo task 中，非 `owner_role` 的 role 准备编辑 production code 或提交 `implementation/pass` evidence 时，`pre-edit` / `pre-evidence` 返回 `block`。
   - 任意 role 准备 attach 与当前 task、resolved role、或 execution contract 不匹配的 rule resolution 时，`pre-evidence` 返回 `block`。
   - 非 reviewer 准备提交 review verdict、非 tester 准备提交 test verdict、非 handoff receiver 准备接收 handoff 时，对应 hook 返回 `block`。
   - 任意 role 准备直接编辑 `.orbit/evidence*.json`、`.orbit/loop-state.yaml` 或 task authoritative fields 来伪造 gate/state 时，`pre-edit` 返回 `block`，提示使用 Orbit CLI。

2. Impatient role recreation guard

   - 任意 role/instance 准备执行 `orbit start INSTANCE --force` 时，`pre-start` 先检查 `.orbit/runtime/locks/start-INSTANCE.lock`、最近 start/replacement 记录、Herdr bound pane 是否仍存在、以及 bound pane 上是否仍有 expected client。
   - 如果同一 instance 最近已经 start/retry 过，且还在 readiness grace window 内，返回 `require_confirmation` 或 `block`，提示继续等待。
   - 如果要修改或删除 `.orbit/instances.yaml` 中已有 role/instance binding，`pre-edit` 返回 `require_confirmation`，除非命令来自 `orbit init --force` 或受控迁移命令。
   - 对 `rm -rf .orbit/runtime`、手工删除 `.orbit/instances.yaml`、批量重建 reviewer/tester/coder 的命令，`pre-command` 默认 `block`，提示使用 `orbit start --force` 或后续明确的 `orbit instance reset` 命令。
   - 如果 Herdr 报告目标 pane 太窄或 view hint 缺失，`pre-start` 返回 `warn`，并设置 `recommended_action: resize_or_recreate_view`。`--force` 只用于替换不可信 binding，不作为普通 resize/layout 修复入口。
   - Herdr-only 后应提供更精确的修复出口，例如 `orbit start INSTANCE --layout repair` 或 `orbit instance view repair INSTANCE`；它们只调整 workspace/tab/pane layout，不伪装成 binding replacement。

3. Completion notice guard

   - 任意 role 完成自己的 implementation/review/test/handoff 子任务后，准备 idle/exit 前，`pre-idle` 检查是否已有发给 task owner 的 completion notice。
   - 如果 latest implementation/review/test pass 已存在，但没有对应 notice，hook 返回 `warn` 或 `require_confirmation`，提示先写 notice。
   - 如果 task 是 team mode，implementation authority 完成 implementation 后必须写 notice 给 `owner_role` / `owner_instance`。
   - reviewer/tester 完成 gate verdict 后也应写 notice 给 `owner_role`，但是否阻塞 gate 由 task policy 决定。

建议默认窗口：

- readiness grace window: 90 seconds
- force restart cooldown per instance: 180 seconds
- repeated force threshold: 2 次后必须用户显式确认

Hook 的定位：

- hook 负责在 agent 准备动作前给出低延迟阻拦和解释。
- CLI 负责在 `evidence add`、`attach-rule`、`wait-gate`、`audit`、`start --force` 中做最终强校验。
- hook 不应直接改 `.orbit` 权威文件；需要修复状态时调用 Orbit CLI。
- hook 不实现 runtime adapter discovery；它只消费 Orbit CLI 自己采集的 Herdr context 和 Orbit protocol state。

### 8. Completion notice protocol

“通知 lead”不能设计成直接给某个 pane 或 terminal 发消息。Orbit 只支持 Herdr 作为官方 automatic runtime，但 notice 的权威事实仍应是 `.orbit` 中的 protocol record。非 Herdr 环境只能手动运行 Orbit protocol，不承诺自动投递。

Notice 分两阶段落地：

- Phase A：`.orbit/runtime/notices/` 是权威 inbox，不声明 `notice.delivery` capability，不自动发 pane message。
- Phase B：可选 Herdr surfacing，只对 `execution_contract.owner_instance` 的 live-confirmed Herdr binding 做 best-effort pane message；失败只进入 observability，不影响 notice authority、gate 或 audit。

核心命令应避免命名成 `notify`，因为它暗示“发消息”。建议使用 notice：

```bash
orbit notice add --task TASK --to ROLE [--to-instance INSTANCE] --event implementation_complete --evidence EVIDENCE --json
orbit notice list --for ROLE --json
orbit notice ack --id ID --json
```

`notice add` 默认从 task `execution_contract.owner_instance` 派生 `to_instance`。如果用户显式传 `--to-instance`，它必须等于 `owner_instance`，否则 fail closed；Phase A 仍只写 role inbox，Phase B 才使用 `to_instance` 找 Herdr pane。

推荐 notice 记录：

```json
{
  "schema_version": "orbit-notice-v1",
  "id": "notice-20260703-implementation-complete",
  "task": ".orbit/tasks/example.yaml",
  "task_sha256": "sha256...",
  "evidence_ref": ".orbit/evidence/example.json",
  "evidence_sha256": "sha256...",
  "from_role": "coder",
  "from_instance": "coder-main",
  "to_role": "lead",
  "to_instance": "lead-main",
  "event": "implementation_complete",
  "status": "pending_ack",
  "created_at": "2026-07-03T10:18:00Z",
  "delivery": {
    "attempted": false,
    "mode": "protocol_record",
    "herdr": {
      "attempted": false,
      "reason": "Herdr notice surfacing is not implemented in this slice."
    },
    "reason": "The notice record is authoritative."
  }
}
```

支持的事件：

- `implementation_complete`
- `review_complete`
- `test_complete`
- `handoff_ready`
- `blocked_needs_owner`

存储位置：

- 权威 inbox 建议使用 `.orbit/runtime/notices/<role>/<notice-id>.json`，这是 per-checkout runtime 状态。
- evidence / handoff 可以引用 notice id 和 notice path，但不要把 pane transcript、manual artifact 或 direct delivery transcript 当成权威 notice。
- `.orbit/runtime/notices/` 必须 gitignored。

Gate/audit 判断的是 notice protocol，不是 Herdr surface/delivery：

- notice 是否存在。
- `to_role` 是否等于 task `owner_role`。
- `to_instance` 是否等于 task `owner_instance`；如果只写 role inbox，Phase B surfacing 不得执行。
- `from_role` / `from_instance` 必须按 event-specific source contract 校验。
- `task_sha256` / `evidence_sha256` 是否匹配。
- notice 是否晚于对应 implementation/review/test pass。
- notice 是否 `pending_ack` 或 `acked`，以及当前 task policy 是否要求 ack。

Event-specific source contract：

- `implementation_complete`: `from_role == implementation_authority` 且 `from_instance == assigned_instance`，除非有显式 override evidence。
- `review_complete`: `from_role == reviewer`；如果 task 有 reviewer instance contract，则 `from_instance` 必须匹配该 reviewer instance，否则只校验 reviewer role。
- `test_complete`: `from_role == tester`；如果 task 有 tester instance contract，则 `from_instance` 必须匹配该 tester instance，否则只校验 tester role。
- `handoff_ready`: `from_role` / `from_instance` 必须匹配当前 handoff producer contract。
- `blocked_needs_owner`: 允许来自当前 responsible role/instance，按阻塞事件来源 contract 校验。

Phase B 的 Herdr notice surfacing 规则：

- Phase A 不声明 `notice.delivery` capability；Phase B 实现前，capability table 仍必须显示 protocol record only。
- Herdr 把 notice summary surface 到 owner pane 前，必须走 `execution_contract.owner_instance` 的 live-confirmed Herdr binding。
- `manual_artifact` 和 `explicit_override` 只能表示 delivery precondition / user override，不得把 `live_binding_confirmed` 或 deprecated alias `live_confirmed_for_delivery` 置为 true。
- 非 Herdr 环境不提供官方 adapter；notice 仍然有效，owner 下次运行 `orbit notice list --for lead`、`orbit audit`、`orbit whoami --task` 时能看到。
- Herdr surfacing 失败不得让 notice 消失；只记录 `delivery.herdr.success=false` 和错误摘要。

### 9. Runtime contract alignment

本设计的 role-boundary 修复不能重新引入已删除的 runtime 抽象：

- `orbit whoami --task --json` 的主契约是 `binding` 和 `herdr`；`transport_binding` 已移除，不能用于 liveness、dispatch、gate 或 role authority 判定。
- `binding_status` 已移除；任何静态 pane/canonical pane binding 都不能被称为 `healthy`。
- `instances status` 的主字段应是 `binding`、`liveness`、`availability`、`herdr`。
- `orbit start INSTANCE` 的自动路径只支持 Herdr；无 binding 的已配置 instance 默认创建，不再需要 `--allow-create`。
- role-boundary hook 读取 runtime 状态时只能把 Herdr live probe 结果当作 alive evidence；不能从旧 `transport.health`、pane id 字符串格式、manual payload 或 explicit pane override 推断 alive。
- 所有 notice / handoff / evidence 设计都应使用 `delivery` 或 `manual_artifact` 术语，不再把手动 payload 称为 generic transport。

Herdr-only 后可以删掉的复杂度：

- 不需要 runtime adapter interface、adapter registry、adapter capability negotiation。
- 不需要判断 pane id 属于哪一种非 Herdr 终端。
- 不需要 `--transport` / `--allow-create` / local transport 分支。
- 不需要在 role-boundary hook 里支持多种 pane status schema。
- 不需要为 notice 设计 delivery backend abstraction；先做 `.orbit/runtime/notices/` 权威 inbox。

Herdr-only 后应该做得更好的体验：

- `start` 可以按 instance role 创建稳定 workspace/tab/pane，并应用 `min_columns` / `min_rows`，避免新建 role 视图过窄。
- `whoami` 可以同时显示 role identity 和 Herdr bound pane/current pane，帮助 agent 发现自己在错误 pane 或错误 checkout。
- `instances status` 可以把 `bound`、`live-confirmed`、`wrong-client`、`wrong-cwd`、`too-narrow` 这类状态直接说清楚。
- `hook pre-start` 可以在 force 前给出具体 pane、client、cwd、view size 证据，而不是泛泛提示“状态不对”。
- `notice list` 可以成为 lead 的可靠 inbox；未来如果加 Herdr surfacing，也只是把 inbox 摘要显示到 Herdr pane，不改变权威状态。

## Current Code Gap Matrix

基于当前代码，三层防线现状如下。

### Gate semantic boundary

Gate 不能直接判断“自然语言规范是否被遵守”。自然语言规范必须先被投影成结构化义务，gate 只能校验这些义务是否存在、是否新鲜、是否由正确 role 提交、是否覆盖必答项。

原则：

- 自然语言规则是来源，不是 gate 的直接判定对象。
- 每条可 gate 的规范必须有稳定 `rule_id`。
- `rules resolve` / `rules print-context` 必须输出本轮适用的 required rule ids、required files 和 required checks。
- review/test/implementation evidence 必须记录 `rule_application`，说明哪些 required rules 被读取、哪些 checks 被执行、哪些不适用。
- Gate 只检查结构化事实；自然语言质量由对应 role 的 structured verdict 承担，再由 reviewer/tester 的独立判断和 audit 兜底。

推荐 evidence 结构：

```yaml
rule_application:
  required_rule_files_read:
    - references/runtime/quality-outcome-and-review.md
  applied_checks:
    - id: quality_outcome_checked
      verdict: pass
      evidence: "Compared implementation evidence against desired_property and invalid_completions."
    - id: counterexamples_checked
      verdict: pass
      evidence: "Checked stale review/test and role mismatch cases."
  not_applicable: []
```

Gate 可判定项：

- required rule file 是否被读取。
- required check id 是否都有回答。
- check verdict 是否是 `pass|fail|blocked|not_applicable`。
- `not_applicable` 是否有 reason。
- evidence 是否来自正确 role/instance。
- evidence 的 `task_sha256`、`rules_context_sha256`、`role_config_sha256` 是否匹配当前 task/rules/config。
- review/test evidence 是否晚于最新 implementation evidence。
- required question、confirmed/assumed/missing、residual risk 是否完整。

Gate 不应直接判定：

- reviewer 是否真的“认真看了”。
- tester 是否真的“理解了用户路径”。
- lead 拆分是否“合理”。
- implementation 是否“优雅”。

这些只能通过结构化 review/test verdict、counterexample checks、quality outcome checks、negative evidence、residual risk 和 audit 形成可追责证据。没有投影成结构化 checklist 的自然语言规范只能作为 advisory，不能作为 gate 条件。

### Layer 1: Hook preflight

已有：

- 没有真正的 hook 层。

缺口：

- `lib/orbit/core.rb` 的 help/dispatch 里没有 `orbit hook` 子命令。
- 没有 `pre-command`、`pre-edit`、`pre-evidence`、`pre-start` entrypoint。
- 没有 `pre-idle` / completion guard，不能在 agent 结束前提醒它写 completion notice。
- 不能在 agent 准备编辑 production code 前按 `execution_contract` 拦截。
- 不能在 agent 准备直接编辑 `.orbit/evidence*.json`、`.orbit/loop-state.yaml`、`.orbit/instances.yaml` 前拦截。
- 不能在 repeated `start --force` 之前做 grace window / cooldown 提醒。
- 不能在 role 完成 implementation/review/test 后检查是否已向 task owner 写 notice。

需要补：

- 新增 `orbit hook pre-command|pre-edit|pre-evidence|pre-start|pre-idle --intent-json PATH|- --json`。
- hook 缺少 `--intent-json` 时 fail closed，避免从外部上下文猜测 command/edit/evidence/start intent。
- hook 只读 task、roles、instances、runtime replacement diagnostics 和 lock 状态，输出 `allow|warn|require_confirmation|block`。
- hook 必须复用 CLI 内部的 identity / execution contract 判定函数，避免 hook 和 CLI 判断分叉。
- hook 读取 `.orbit/runtime/notices/`，发现 completion pass 后缺 notice 时提示写 `orbit notice add`。

### Layer 2: CLI write-time enforcement

已有：

- `evidence submit` 会通过 `require_evidence_submit_capability!` 校验 review/test 提交角色或 capability。
- `evidence submit` 会写 `role_execution_context`，包括 `resolved_role`、`task_sha256`、`rules_context_sha256`、`role_config_sha256`。
- `evidence add` 已阻止 review/test PASS 走 free-form 路径，要求用 structured `evidence submit`。
- `evidence attach-rule` 当前至少要求 rule resolution schema 正确且 `valid == true`。
- `start --force` 已有 per-instance lock，能阻止并发 force start 写坏状态。
- `start --force` replacement diagnostic 已写到 `.orbit/runtime/instances/<name>.json`，没有继续污染 `instances.yaml`。

缺口：

- `orbit init` 只有 `--force`，没有 `--operation-mode solo|team`，也没有 TTY 交互选择。
- init 模板只生成 `lead/reviewer/tester`，team 模式需要的 `coder` role/instance 还没有生成。
- `.orbit/roles.yaml` 模板没有 `operation_defaults`。
- task 模板和 `new-task` 仍写 `target_role`，没有 `execution_contract` snapshot。
- `whoami --task` 的 task 约束仍在 `apply_task_constraints` 中按 `task.target_role` 判断，没有按 `execution_contract` 判断 owner / implementation authority / gate role。
- `evidence add --kind implementation` 仍不要求 `--task`，也不写 `role_execution_context`，因此 implementation evidence 仍可被非授权 role free-form 写入。
- `evidence add --kind pass` 没有区分 implementation pass 和其它 pass 语义，无法按 implementation authority 拦截。
- `evidence attach-rule` parser 虽然接受 `--task`，但 attach 当下没有要求 `--task`，也没有校验 resolution task path/hash、resolved role 与 execution contract 是否匹配。
- `rules resolve --output` 还没有 role/instance suffix overwrite guard。
- `start --force` 只有并发 lock 和风险提示，没有 readiness grace window、cooldown、重复 force 阈值。
- 没有 `orbit notice` 子命令，也没有 `.orbit/runtime/notices/` 权威 notice 存储。
- completion/handoff 仍依赖 agent 自觉口头汇报、direct delivery 消息或手工 payload，不能被 gate/audit 稳定复核。

需要补：

- 把 operation mode 引入 init/new-task/task schema 后，先改所有写入命令从 `execution_contract` 读取边界。
- `evidence add --kind implementation|pass` 必须带 `--task`，并写 `role_execution_context`。
- `attach-rule --task` 必须在写 manifest 前 fail closed。
- `start --force` 写入/读取 recent replacement diagnostics，执行 cooldown 和 repeated force guard。
- 增加 `orbit notice add|list|ack`，只写/读 `.orbit/runtime/notices/`；本轮不实现 Herdr notice surfacing。

### Layer 3: Gate / audit post-check

已有：

- `wait-gate` 会按 gate kind 校验 review/test identity，非 reviewer/tester 不能关闭对应 gate。
- `wait-gate` 会优先读取 `role_execution_context`，且 strict mode 下会拦 malformed/missing/stale `task_sha256` 和 missing `rules_context_sha256`。
- `validate` / `audit` 会复核 attached rule resolution 是否 valid、是否属于当前 task、resolved role 是否匹配旧 `target_role` / gate role。
- `wait-gate` 已有 verdict arbitration，能阻止旧 task sha 的 stale verdict 关闭当前 gate。
- `validate` / `audit` 已有 write policy、quality outcome、required questions、evidence level、release readiness 等后验检查。

缺口：

- gate/audit 的 task role 判断仍围绕旧 `target_role`，没有按 `execution_contract` 判断 implementation authority。
- gate/audit 还没有 “latest implementation created_at 必须早于 fresh review/test pass” 的 freshness 规则。
- `evidence add` 产生的 implementation record 没有 `role_execution_context`，导致 gate/audit 无法可靠判断 implementation author 是否符合 contract。
- 旧 task schema 仍被当前 validator 接受为 `orbit-task-v1 + target_role`，没有按 breaking change 要求 fail closed 并提示重新 init。
- attached rule resolution 的 role mismatch 后验检查目前依赖旧 target_role，没有覆盖 solo/team execution contract。
- 没有针对直接手工修改 `.orbit` 权威文件的后验 drift/audit 摘要；只能通过文件内容本身的 schema/字段检查发现一部分问题。
- gate/audit 还没有 completion notice 检查；无法发现 coder/reviewer/tester 已完成但未向 owner 留下结构化 notice。
- audit 也不区分 protocol notice 和 Herdr surfacing，当前没有可复核的 notice status / ack status。

需要补：

- gate/audit 增加 `execution_contract_summary`，所有 mismatch 输出都指向 owner_role/owner_instance/implementation_authority/assigned_instance/gate role。
- 增加 `stale_after_implementation`：latest review/test pass 必须晚于 latest implementation record。
- 对缺少 `execution_contract` 的 task fail closed，输出 `task_schema_reinit_required`。
- 对 `owner_instance` 或 `assigned_instance` 缺失、找不到、或 role_ref 不匹配 fail closed。
- 对 implementation evidence 缺失 `role_execution_context` 或 author mismatch fail closed。
- 对 non-assigned implementation instance 必须复核 `implementation_instance_override` 的 task hash、授权者、目标 instance 和过期时间。
- audit 输出 direct-edit suspicion：manifest/state/task 缺少 CLI 写入痕迹或 hash 链断裂时给出 explicit finding。
- gate/audit 增加 `notice_summary`，检查 required completion notice 是否存在、是否指向最新 evidence、是否发给 task owner、是否需要 ack。
- gate/audit 不依赖 Herdr surfacing 成功；delivery 只作为 observability 字段。

## Implementation Order

1. 更新 Herdr instance schema / validator / templates，写入 sibling `binding.adapter: herdr`、workspace/tab/pane/canonical pane、以及 `view.min_columns/min_rows`；拒绝把 `view` 写进 `binding` 的新 schema。
2. 更新 `instances status` 和 `start --dry-run`，输出 planned/observed workspace/tab/pane、view policy、geometry、`too_narrow` 和 layout remediation。
3. 更新 `orbit init` CLI，支持 `--operation-mode solo|team`，并在未传参且 TTY 时交互选择；team 模式默认生成 `coder-main` instance。
4. 更新 `orbit new-task`，从项目级 `operation_defaults` 生成 task `execution_contract` snapshot；`owner_role` / `implementation_authority` 是 role，`owner_instance` / `assigned_instance` 是 instance key。
5. 给 task schema validator 加强制检查：缺少 `execution_contract` 或只包含旧 `target_role` 时 fail closed，并提示重新运行 `orbit init`。
6. 给 `evidence attach-rule` 加 `--task`，实现 rule resolution 与 task execution contract 的强校验。
7. 给 `evidence add --kind implementation` 加 `--task` 和 `role_execution_context`，拒绝 team 模式下非 implementation authority 写 implementation。
8. 增加 `implementation_instance_override` evidence kind 和受控创建命令。
9. 给 `wait-gate` 增加 review/test freshness 检查，并复核 implementation instance override 是否有效、未过期、授权者匹配。
10. 给 `audit` 增加相同 freshness / override 检查，并在 done/handoff/release 前 fail closed。
11. 更新 `rules resolve` / `rules print-context` 的推荐输出路径，加入 instance/role 后缀。
12. 增加 rule artifact overwrite guard。
13. 增加 `orbit notice add|list|ack` Phase A，把 completion notice 写入 `.orbit/runtime/notices/`。
14. 增加 Herdr-aware hook entrypoints，覆盖任意 role boundary、force restart cooldown、completion notice guard、视图过窄提醒和手工修改 `.orbit/instances.yaml` 的提前阻拦；hook 的 Herdr context 必须由 Orbit CLI 自己 probe。
15. 更新 audit/wait-gate notice summary，复核 completion notice 但不依赖 Herdr surfacing。
16. 更新模板和 runtime guide，在 `.orbit/roles.yaml` 生成 `operation_defaults`；team 模式模板必须包含 lead/coder roles 和 `lead-main` / `coder-main` instances。
17. 后续 Phase B 才实现 Herdr notice surfacing；实现前不得声明 `notice.delivery` capability。
18. 更新 SKILL、README 和 release notes，明确升级后需要重新 `orbit init --operation-mode solo|team`。

## Test Plan

必须新增的回归：

1. `orbit init --operation-mode solo` 生成 solo `operation_defaults`，`owner_instance` / `assigned_instance` 是 `lead-main` 这类 instance key，且不要求 coder instance。
2. `orbit init --operation-mode team` 生成 team `operation_defaults`，`owner_instance: lead-main`，`implementation_authority: coder`，`assigned_instance: coder-main`，并生成 lead/coder roles 和 `lead-main` / `coder-main` instances。
3. `orbit init` 未传 mode 且 TTY 时显示 `solo` / `team` 选择，选择后生成对应配置。
4. `orbit init` 未传 mode 且非 TTY 时失败，并提示 `--operation-mode solo|team`。
5. `.orbit/roles.yaml` 中 `operation_defaults: solo` 时，`orbit new-task` 生成 solo `execution_contract`。
6. `.orbit/roles.yaml` 中 `operation_defaults: team` 时，`orbit new-task` 生成 team `execution_contract`，并保留 `owner_instance` / `assigned_instance` key 而不是 role name。
7. `execution_contract.assigned_instance` 不存在时 fail closed。
8. `execution_contract.assigned_instance` 的 `role_ref` 不解析到 `implementation_authority` 时 fail closed。
9. `execution_contract.owner_instance` 的 `role_ref` 不解析到 `owner_role` 时 fail closed。
10. solo task 中 `ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead` 可以写 implementation evidence，并记录 `operation_mode: solo`。
11. team task 中 `ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead` 写 implementation evidence 失败。
12. team task 中 `ORBIT_INSTANCE=coder-main ORBIT_ROLE=coder` 写 implementation evidence 通过，并记录 `implementation_authority: coder`、`resolved_instance: coder-main` 和 `execution_contract_source`。
13. team task 中 `ORBIT_INSTANCE=coder-android ORBIT_ROLE=coder` 写 implementation evidence 失败，除非存在显式 override evidence 指向 `coder-android`。
14. `implementation_instance_override` 缺少 reason、授权者、task hash、expires_at/no_expiry 或 role_ref 校验失败时 fail closed。
15. 未过期且授权者匹配的 `implementation_instance_override` 可以允许 `coder-android` 写 implementation evidence，但 audit 必须把 override 摘要列出。
16. 过期 override 不能让 non-assigned instance 继续写 implementation evidence 或通过 gate。
17. task 创建后修改 `.orbit/roles.yaml` 默认值，不改变已有 task 的 `execution_contract` 判定。
18. `orbit new-task --operation-mode solo` 在 team 默认项目里生成 `source: explicit_override`。
19. `attach-rule --task team-task` 挂载 lead implementation resolution 时失败。
20. `attach-rule --task team-task` 挂载同 role 但非 assigned instance 的 coder resolution 时失败，除非有显式 override evidence。
21. `attach-rule --task team-task` 挂载 `valid=false` resolution 时失败。
22. `attach-rule --task team-task` 挂载正确 coder resolution 时通过。
23. lead 可以对 team task 写 `command` 或 `lead_sanity`，但这些 record 不满足 implementation gate。
24. 最新 implementation 晚于 review pass 时，`wait-gate` review gate 返回 `stale_after_implementation`。
25. 最新 implementation 晚于 test pass 时，`wait-gate` test gate 返回 `stale_after_implementation`。
26. fresh review/test 晚于最新 implementation 后，gate 重新 ready。
27. `audit` 对 stale review/test fail closed。
28. `rules resolve --output existing.json` 遇到不同 role 的旧 resolution 时拒绝覆盖。
29. recommended context commands 输出 role/instance suffixed rule artifact path。
30. 只有 `target_role` 的旧 task 在 `whoami --task`、`evidence add --task`、`wait-gate` 和 `audit` 中全部 fail closed，并输出 `run orbit init --operation-mode solo|team` remediation。
31. `orbit init` 生成的新 task template 不再包含 `target_role`。
32. hook `pre-edit` 在 team task 中阻止非 `implementation_authority` role 编辑 production code。
33. hook `pre-edit` 在 solo task 中阻止非 `owner_role` role 编辑 production code。
34. hook `pre-evidence` 阻止任意非授权 role 写 implementation/pass、review verdict、test verdict 或不匹配的 rule attachment。
35. hook `pre-edit` 阻止任意 role 直接编辑 `.orbit/evidence*.json`、`.orbit/loop-state.yaml` 或 task authoritative fields 伪造状态。
36. hook `pre-start` 在 readiness grace window 内阻止重复 `orbit start INSTANCE --force`。
37. hook `pre-command` 阻止手工删除 `.orbit/instances.yaml` 或批量删除 `.orbit/runtime`，并提示使用 Orbit CLI 出口。
38. hook `pre-command|pre-edit|pre-evidence|pre-start|pre-idle` 缺少 `--intent-json` 时 fail closed。
39. `orbit notice add --event implementation_complete` 写入 `.orbit/runtime/notices/<owner-role>/...json`，记录 task/evidence hash、`from_instance: coder-main` 和 `to_instance: lead-main`。
40. `review_complete` / `test_complete` notice 按 reviewer/tester event-specific source contract 校验，不要求 `from_instance == assigned_instance`。
41. `orbit notice list --for lead` 能列出 pending completion notice。
42. `orbit notice ack --id ...` 能把 notice 标为 acked，且保留 ack role/instance/time。
43. hook `pre-idle` 在 implementation/review/test pass 后缺 completion notice 时返回 `warn` 或 `require_confirmation`。
44. audit 在 team task 中发现 latest implementation pass 缺 owner completion notice 时给出 `missing_completion_notice`。
45. notice record 在没有 Herdr surfacing 时仍可创建、列出、ack；audit 不因为没有自动投递而失败。
46. 如果未来启用 Herdr notice surfacing，surfacing 失败不影响 notice 存在；audit 只把 surfacing failure 作为 warning/observability。
47. `whoami --task --json` 的 role preflight 示例和测试只使用 `binding` / `herdr` 主字段，不输出 `binding_status` 或 `transport_binding`。
48. `orbit init --operation-mode team` 生成 coder/reviewer/tester instance 的 sibling Herdr `view` hint，不把 `view` 写进 `binding`。
49. `orbit start INSTANCE --dry-run --json` 输出 planned workspace/tab/pane 和 view size policy。
50. validator 接受 sibling `view.min_columns/min_rows`，并拒绝新 schema 中的 `binding.view`。
51. `instances status --json` 输出 observed geometry、view policy、`too_narrow` 和 `resize_or_recreate_view` remediation。
52. Herdr 报告 pane 过窄时，`hook pre-start` 或 `instances status` 输出 `too_narrow` / remediation，而不是让 agent 静默运行。
53. hook `pre-*` 不接受 caller 提供的 Herdr live probe、manual payload、explicit pane override 或 `transport_binding` 作为 live proof；只认 Orbit CLI 自己采集的 Herdr probe。
54. Phase A 不声明 `notice.delivery` capability；Phase B Herdr surfacing 只对 `owner_instance` 的 live-confirmed binding 发 best-effort pane message，失败只进 observability。

## Upgrade Notes

这是 breaking change，不提供旧 task schema 的自动兼容或自动迁移。

- 安装新包后，项目必须重新运行 `orbit init --operation-mode solo|team`，或在 TTY 中运行 `orbit init` 并选择模式。
- 重新 init 会更新 `.orbit/roles.yaml` 的 `operation_defaults`、task template、runtime guide 和推荐命令。
- 历史 evidence 可以保留用于审计，但不能继续作为新 gate 的有效输入。
- 旧 task 若仍需继续，应按新模板重建 task，再由对应 role 重新生成 rule resolution、implementation evidence、review/test evidence。
- 不建议手工编辑旧 task/evidence 伪装成新 schema；修复动作应以新 task 和新 evidence record 记录。

## Open Questions

1. `lead_sanity` 是否作为新 evidence kind 引入，还是复用 `command` 并增加 `subkind`？
2. team 项目是否允许 `new-task --operation-mode solo`？默认允许显式 override，但必须记录 `source: explicit_override`。
3. rule artifact overwrite guard 是否需要 `--force` 参数，还是直接要求用户换输出路径？
4. 旧 schema 的报错码统一命名为 `task_schema_reinit_required` 还是沿用通用 schema error？

## Expected Outcome

修复后，同类问题会在三个位置被拦住：

1. solo/team 默认模式由项目全局配置决定，agent 不需要按“小改动/大改动”动态猜边界。
2. team 模式下 lead 不能写 implementation evidence。
3. lead 不能把自己的 invalid rule resolution attach 到 team implementation evidence。
4. 即使最新 implementation 已写入，旧 review/test pass 也不能继续让 gate ready。
5. 新版本不会继续承载旧 `target_role` 分支；升级后的项目必须通过重新 `orbit init` 得到带 `operation_defaults` 的新 schema。

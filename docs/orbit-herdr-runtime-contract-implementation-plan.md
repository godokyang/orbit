# Orbit-Herdr runtime contract implementation plan

本文是 `docs/orbit-herdr-runtime-contract-design.md` 的实施计划。设计文档定义用户体验和 runtime contract；本文只把它拆成编码、测试和 review 可以逐条验收的 slice。

## Scope

本轮实现必须完成：

- 安装器默认要求 Herdr：安装成功前必须检查 `herdr` 可执行。
- 新增 Orbit runtime session 文件和统一 instance runtime 文件 schema。
- 新增 `orbit runtime register|ack-session --json`；当前版本不提供独立 heartbeat 子命令。
- `orbit start INSTANCE` 生成 session/launch env，支持 `started_identity_pending`，并输出 pane-aware remediation。
- `instances status`、`start`、`dispatch` 和 gate-closing evidence 写入路径共用 on-demand runtime resolver。
- `dispatch` direct delivery 要求 live + verified + available。
- evidence 记录 runtime session attribution，区分 `manual_runtime`、`explicit_waiver`、`stale`、`replaced`。`herdr_verified` 只有 trusted caller-pane proof provider 接入后才能成为可通过分类；当前版本必须 fail closed。
- README、runtime guide、help 和 tests 同步说明 Herdr 是普通 Orbit runtime 的必需依赖。

本轮不做：

- 重新引入 tmux/zellij/wezterm adapters。
- 让 Herdr `done` 成为 Orbit task/evidence/gate 的完成依据。
- long-running Orbit daemon。
- 自动 kill 旧 agent。
- 把 Herdr notification/request delivery 当作 registration 成功。registration request 只是提示；只有目标 agent 实际运行 `orbit runtime register --json` 并通过 Orbit probe，session 才能变成 verified。

## 不可接受中间态

- installer 不检查 Herdr，却安装出一个普通 `orbit start` / direct `dispatch` 都不可用的 CLI。
- 缺 Herdr 时普通安装静默成功，或只在首次 `start` 时才告诉用户缺依赖。
- `started_identity_pending` 可被 direct dispatch。
- `--pane` explicit override 被写成 `verified`，或被 evidence/gate 当作可信 runtime identity。
- `instances status --json` 默认写 `.orbit/instances.yaml` 造成 git diff。
- `start` 只修复 stale binding、没有启动新 agent，却写回 `.orbit/instances.yaml`。
- `.orbit/runtime/instances/<instance>.json` 被 `orbit-start-replacement-v1` 裸 payload 覆盖，导致 current session pointer 丢失。
- Herdr env (`HERDR_ENV` / `HERDR_PANE_ID`) 被当作 identity proof，而不是 probe 输入。
- 当前版本 `start` 不得输出 verified reuse；未来 trusted proof provider 接入后，才允许无 binding 时扫描唯一 live verified runtime session。
- 任意 Orbit CLI 命令在 Herdr 环境内运行时不刷新 runtime session，导致 `started_identity_pending` 只能靠人工修复。
- `orbit runtime register` 只凭 env 或用户传参写出 `herdr_verified`，没有匹配 Orbit 先前创建的 pending/provisional session。
- 全局 piggyback 没有 reentry guard，导致 `runtime register|ack-session` 或其内部 resolver 调用递归触发自身。

## Code Entry Points

- `install.sh`
  - Herdr prerequisite check、manual-only 显式模式、安装输出。
- `README.md`
  - 安装步骤、Herdr requirement、manual-only 降级说明。
- `lib/orbit/core.rb`
  - `runtime` subcommand help、top-level usage、removed/migration messages。
- `lib/orbit/cli.rb`
  - `run_orbit_cli` command dispatch must add `when "runtime"` and load `runtime_commands` before dispatch.
- `lib/orbit/identity_rules.rb`
  - `instances status`、`bind-pane`、instance binding normalization、whoami runtime fields。
- `lib/orbit/task_herdr_probe.rb`
  - start plan、Herdr probe、creation/wake/reuse、force replacement diagnostics、pending output。
- `lib/orbit/task_herdr_exec.rb`
  - `start` execution、Herdr agent start env、dispatch packet/gate。
- `lib/orbit/evidence.rb`
  - implementation/review/test evidence runtime attribution.
- `lib/orbit/evidence_submit_validate.rb`
  - structured review/test submit validation if runtime attribution is enforced there.
- `lib/orbit/validate_gate_commands.rb`
  - gate-closing evidence session checks.
- `lib/orbit/audit_tools.rb`
  - tools doctor runtime diagnostics、audit/handoff summaries for runtime verification gaps.
- `lib/orbit/validate_task_contract.rb`
  - any config/schema validation for runtime settings.
- `tests/parts/01_installer.sh`
  - installer, start, instances status, dispatch, tools doctor primary tests.
- `tests/parts/02_task_evidence.sh`
  - evidence attribution and gate behavior.

新增共享边界必须落地，不能只把逻辑继续散在现有大文件里：

- `lib/orbit/runtime_store.rb`
  - `.orbit/runtime` 的唯一读写入口，负责 file lock、atomic replace、schema 迁移、session/instance pointer 查询。
- `lib/orbit/herdr_probe.rb`
  - Herdr CLI 查询和输出 normalization 的唯一入口，负责 pane、agent、cwd、client、named session namespace 的事实采集。
- `lib/orbit/runtime_resolver.rb`
  - `instances status`、`start`、`dispatch`、evidence attribution、gate/audit 共用的 liveness/identity/availability resolver。
- `lib/orbit/runtime_commands.rb`
  - `runtime register|ack-session` 的命令实现，调用 store/probe/resolver，不直接拼写 verified 规则。

边界规则：

- `.orbit/runtime/**` 只能通过 `runtime_store` 写。
- 命令层不能自行判断 `herdr_verified`；只能消费 `runtime_resolver` 的结果。
- `status`、`start`、`dispatch`、gate-closing evidence 写入、audit/handoff 必须调用同一个 resolver。
- `task_herdr_probe.rb` 和 `task_herdr_exec.rb` 可以编排 Herdr 操作，但不能成为 runtime session schema 的权威实现。

## State Naming Contract

实现里允许不同输出面使用不同用户可读词，但映射必须固定：

| Concept | Session file value | Status JSON value | Evidence `runtime_identity.verification` | Dispatch meaning |
| --- | --- | --- | --- | --- |
| Verified Herdr runtime | `identity.verification: "herdr_verified"` and `state: "active"` | `identity_verification: "verified"` | `herdr_verified` | only this can satisfy live identity proof |
| Pending registration | `state: "pending"` and `identity.verification: "identity_pending"` | `identity_verification: "pending"` | not allowed for gate-closing evidence | not dispatch-ready |
| Manual runtime | `state: "active"` and `identity.verification: "manual_runtime"` | `identity_verification: "manual_runtime"` | `manual_runtime` | active protocol session without Herdr proof; no Herdr direct dispatch; gate allowed only by policy |
| Stale session | `state: "stale"` | `identity_verification: "stale"` | `stale` | not dispatch-ready and cannot close gate |
| Replaced session | `state: "replaced"` | `identity_verification: "stale"` with `stale_reason: "replaced"` | `replaced` | not dispatch-ready and cannot close gate |
| Missing/absent identity | no valid session | `identity_verification: "absent"` | not written | not dispatch-ready |
| Mismatch/conflict | session exists but probe/config/identity conflicts | `identity_verification: "mismatch"` | not written | not dispatch-ready |
| Explicit pane override | no session value | `identity_verification: "override"` | never written as verified evidence | manual risk path only |

`herdr_verified` 是 evidence/runtime 内部证明词；`verified` 是 status/dispatch 面向用户的压缩词。两者只能由 resolver 映射，不能在命令层临时互换。

## Slice Order

### Slice 0: installer prerequisite

Goal: Herdr dependency is visible before users install Orbit.

Changes:

- `install.sh` checks both `command -v herdr` and `herdr --version` before reporting success.
- Missing Herdr exits non-zero with:

```text
Herdr is required for Orbit automatic runtime.
Install Herdr first:
  curl -fsSL https://herdr.dev/install.sh | sh
  herdr --version
Then rerun the Orbit installer.
```

- If manual-only mode is implemented, it must be explicit (`--manual-only` or `ORBIT_MANUAL_ONLY=1`) and print that `orbit start` automatic create/wake, Herdr direct dispatch, and Herdr notice surfacing are unavailable.
- README install section presents Herdr as required for normal Orbit runtime usage.

Tests:

- installer fails when `herdr` is absent from `PATH`.
- installer fails when `herdr --version` exits non-zero.
- installer succeeds when fake `herdr --version` succeeds.
- manual-only mode, if implemented, succeeds only when explicit and prints capability downgrade.

Acceptance:

```bash
bash tests/parts/01_installer.sh
```

### Slice 1: runtime session storage

Goal: create durable per-checkout runtime state before start/dispatch depend on it.

Changes:

- Add helpers for `.orbit/runtime/sessions/<session_id>.json`.
- Add unified `.orbit/runtime/instances/<instance>.json` schema `orbit-runtime-instance-v1`.
- Runtime instance file holds `current_session_id`, `current_state`, `previous_sessions[]`, `replacement_diagnostics[]`, and `ack`.
- Session file required fields:
  - `schema_version`
  - `session_id`
  - `launch_id`
  - `state`
  - `project_root`
  - `project_root_sha256`
  - `project_id`
  - `host_id`
  - `user`
  - `instance`
  - `role`
  - `role_ref`
  - `role_config_sha256`
  - `instance_config_sha256`
  - `client`
  - `command`
  - `herdr.session` for the named Herdr session namespace
  - `herdr.workspace`
  - `herdr.tab`
  - `herdr.pane`
  - `herdr.canonical_pane`
  - `identity.verification`
  - `identity.whoami_valid`
  - `identity.conflicts`
  - `created_at`
  - `updated_at`
  - `heartbeat.last_seen_at`
  - `heartbeat.ttl_seconds`
- Migrate existing naked `orbit-start-replacement-v1` content into `replacement_diagnostics[]` on read/write.
- Writes use file locks and atomic replace.
- `.orbit/runtime/` remains gitignored and never becomes evidence.

Tests:

- writing session file is atomic and valid JSON.
- existing `orbit-start-replacement-v1` diagnostic is preserved under `replacement_diagnostics[]`.
- current session pointer survives force replacement diagnostic writes.
- missing `project_root_sha256`, `role_config_sha256`, `instance_config_sha256`, or `herdr.session` makes the session unreadable as verified.
- changed project root hash, role config hash, instance config hash, or named Herdr session namespace makes the session stale/mismatch instead of verified.

Acceptance:

```bash
ruby -c lib/orbit/task_herdr_probe.rb
bash tests/parts/01_installer.sh
```

### Slice 2: runtime CLI

Goal: expose the registration protocol explicitly.

Changes:

- Add `orbit runtime register --json`.
- Add `orbit runtime ack-session INSTANCE --json`.
- `register` runs the same identity resolver as `whoami`.
- `register` treats `HERDR_ENV` / `HERDR_PANE_ID` as probe input only.
- `register` never writes `identity.verification=herdr_verified` in the current implementation because Herdr lacks trusted caller-pane proof.
- Future promotion to `herdr_verified` requires all preconditions plus a trusted proof provider:
  - `ORBIT_SESSION_ID` exists in runtime store as an Orbit-created pending/provisional session for the same instance.
  - `ORBIT_LAUNCH_ID` matches that pending/provisional session.
  - current `whoami` has no identity conflicts and resolves to the session instance/role.
  - `project_root_sha256` matches the current checkout.
  - `role_config_sha256` and `instance_config_sha256` match current `.orbit/roles.yaml` and `.orbit/instances.yaml` projections.
  - Herdr named session namespace matches the pending/provisional session.
  - Herdr probe confirms the current pane/agent/cwd/client match the expected session facts.
- Probe failure writes `identity_pending` or `manual_runtime`, with `dispatch_ready=false`.
- `ack-session` writes ack for current target session/pane and refuses stale session ids.
- `ack-session` records `acknowledged_by` with resolved Orbit role/instance, session id, pane, and timestamp.
- `ack-session INSTANCE` has no task parameter in this slice, so owner authority is instance/project scoped:
  - allow `lead` by default;
  - allow roles listed in project runtime policy as `runtime_ack_owner_roles`;
  - allow the instance config owner role if that field exists;
  - reject all other roles until a future task-scoped `ack-session --task TASK` contract exists.
- `ack-session` rejects identity conflicts, manual override identity, and unknown instance identity.

Tests:

- `orbit runtime --help` is reachable through `run_orbit_cli`.
- `orbit runtime register --json` and `orbit runtime ack-session INSTANCE --json` dispatch through `lib/orbit/cli.rb`; no standalone heartbeat command is exposed.
- register without Herdr env does not produce `herdr_verified`.
- forged Herdr env without matching Herdr probe does not produce `herdr_verified`.
- forged `ORBIT_SESSION_ID` does not produce `herdr_verified`.
- wrong `ORBIT_LAUNCH_ID` does not produce `herdr_verified`.
- config hash change between start and register does not produce `herdr_verified`.
- cross-checkout registration does not produce `herdr_verified`.
- named Herdr session namespace mismatch does not produce `herdr_verified`.
- successful fake Herdr probe still does not produce verified session without trusted caller-pane proof.
- ack-session only applies to current session and expires/invalidates when session changes.
- non-owner/non-lead ack-session fails and does not unblock dispatch.
- ack-session with identity conflict or manual override fails closed.

Acceptance:

```bash
bash tests/parts/01_installer.sh
```

### Slice 3: start session registration

Goal: `start` creates or reuses Herdr agents with Orbit session identity.

Changes:

- `orbit start INSTANCE` generates `ORBIT_SESSION_ID` and `ORBIT_LAUNCH_ID`.
- Herdr start command passes `ORBIT_INSTANCE`, `ORBIT_ROLE`, `ORBIT_PROJECT_ROOT`, `ORBIT_PROJECT_ID`, `ORBIT_SESSION_ID`, and `ORBIT_LAUNCH_ID`.
- Generated agent context must not imply that `["orbit", "runtime", "register", "--json"]` can promote a session to verified in the current version.
- Every Orbit CLI command running with Herdr session env may piggyback runtime diagnostics before command-specific behavior:
  - If the matching session is pending/provisional, attempt `register`.
  - There is no lightweight heartbeat command; verified sessions cannot be refreshed until trusted caller-pane proof exists.
  - Piggyback failure must not forge verification; the primary command may continue only if its own policy allows pending/manual runtime.
- Piggyback eligibility must be explicit:
  - current directory must contain a valid `.orbit` project config;
  - command must have `ORBIT_SESSION_ID` or a resolvable Orbit runtime identity;
  - skip `help`, `--help`, `version`, `--version`, `init`, and all `runtime *` subcommands;
  - skip when no `.orbit` exists, even if Herdr env variables are present;
  - skip installer/bootstrap contexts.
- Piggyback must be protected by a reentry guard:
  - Set `ORBIT_RUNTIME_REFRESHING=1` around the piggyback refresh.
  - If `ORBIT_RUNTIME_REFRESHING=1` is already present, skip global piggyback.
  - `orbit runtime register|ack-session` never trigger global piggyback themselves; they call store/probe/resolver directly.
  - resolver/whoami calls made inside runtime commands must not recursively invoke CLI-level piggyback.
- New agent start writes provisional session.
- If verified registration is not observed, output `action: started_identity_pending`, `dispatch_ready: false`, and pane-aware `next`:

```yaml
next:
  - inspect_pane: herdr pane read <pane>
  - manual_payload: "Herdr verified runtime is unavailable until trusted caller-pane proof exists; use orbit dispatch --manual-payload for task delivery."
```

- Herdr request delivery, if attempted, is best-effort only and must not mark the session verified.
- `start` new/force may write `.orbit/instances.yaml`.
- `start` stale repair without new agent writes only `.orbit/runtime`.

Tests:

- start dry-run includes session env.
- start dry-run does not include `["orbit", "runtime", "register", "--json"]` as a verified promotion preflight command.
- real fake-Herdr start writes provisional session and pending output.
- first `orbit whoami --json` / `orbit evidence ...` command inside fake Herdr env piggybacks register diagnostics but does not produce `herdr_verified`.
- no standalone heartbeat command is exposed.
- Orbit command without Herdr env does not claim `herdr_verified` through piggyback.
- `HERDR_ENV=1 orbit --help` and `HERDR_ENV=1 orbit version` outside `.orbit` do not write runtime state and do not fail.
- `HERDR_ENV=1 orbit init` does not piggyback before config exists.
- `orbit runtime register|ack-session` do not recursively invoke global piggyback.
- `ORBIT_RUNTIME_REFRESHING=1 orbit whoami --json` skips piggyback and does not recurse.
- pending start cannot be used as dispatch-ready.
- stale repair by start does not mutate `.orbit/instances.yaml`.
- new/force start still writes intended binding.

Acceptance:

```bash
bash tests/parts/01_installer.sh
```

### Slice 4: unified runtime resolver and instances status

Goal: one resolver decides liveness/identity/availability for all command paths.

Changes:

- Add resolver used by `instances status`, `start`, `dispatch`, and gate-closing evidence paths.
- Resolver reads config, runtime instance pointer, runtime session, and current Herdr facts.
- Resolver outputs:
  - `herdr_liveness: alive|not_alive|unknown`
  - `identity_verification: verified|pending|manual_runtime|stale|mismatch|absent|override`
  - `availability: available|available_needs_seen|busy|needs_user_or_owner_attention|unknown`
  - `binding_resolution: current|repaired|stale|missing|ambiguous`
  - `canonical_pane`
  - `dispatch_ready`
- Current `start INSTANCE` with no `.orbit/instances.yaml` binding does not perform verified reuse:
  - Handwritten or old `herdr_verified` runtime sessions are ignored without trusted caller-pane proof.
  - client/cwd match without a valid trusted runtime session is never enough to reuse.
  - Future trusted proof provider may reintroduce `reuse_discovered` / ambiguous verified candidates as a separate slice.
- `bind-pane` writes manual binding hint only.
- `bind-pane` output must include `identity_verification: absent`, `dispatch_ready: false`, and next steps to register/verify.
- `bind-pane` must not create or mark an active runtime session.
- `instances status --json` default does not write `.orbit/instances.yaml`.
- `instances status --repair-binding --json` is the only status path that writes repaired binding to versioned config.

Tests:

- status with handwritten or old `herdr_verified` session reports dispatch not ready while trusted caller-pane proof is unavailable.
- status with Herdr agent but no runtime session reports identity absent and dispatch not ready.
- status does not repair runtime pointer from untrusted verified session files.
- `--repair-binding` does not write config from untrusted verified session files.
- duplicate handwritten verified sessions are ignored rather than treated as ambiguous verified candidates.
- start with no binding and handwritten verified session files does not return `reuse_discovered`.
- start with no binding and only client/cwd matching Herdr agent creates/pends normally instead of reusing.
- bind-pane writes only manual hint and reports `identity_verification: absent`.
- bind-pane never writes `.orbit/runtime/sessions/<session_id>.json`.

Acceptance:

```bash
bash tests/parts/01_installer.sh
```

### Slice 5: dispatch gate

Goal: direct delivery only reaches verified live Orbit runtime participants.

Changes:

- `dispatch --to INSTANCE` calls unified resolver.
- Direct dispatch requires task contract allowed + `alive` + `verified` + `available`.
- Direct dispatch target pane must be the verified session's `canonical_pane`; a caller-supplied pane or repaired hint cannot substitute for session ownership.
- `available_needs_seen` blocks until `orbit runtime ack-session INSTANCE --json`.
- `--manual-payload` remains protocol-safe fallback.
- `--pane` remains explicit override but sets `identity_verification: override`, emits risk, and never writes active session/evidence identity.

Tests:

- pending session dispatch fails closed.
- absent/mismatch/stale session dispatch fails closed.
- manual payload works without Herdr-verified target.
- explicit pane override emits risk and `live_binding_confirmed=false`.
- verified session exists but dispatch pane differs from session `canonical_pane` fails closed.
- done/available_needs_seen blocks until ack-session, then permits dispatch within ack TTL.

Acceptance:

```bash
bash tests/parts/01_installer.sh
```

### Slice 6: evidence session attribution

Goal: gate-closing evidence records know which runtime session authored them.

Changes:

- Add runtime attribution to implementation/review/test evidence records:

```json
"runtime_identity": {
  "verification": "herdr_verified",
  "session_id": "ors_...",
  "herdr_pane": "w1:p2"
}
```

- Categories: `herdr_verified`, `manual_runtime`, `explicit_waiver`, `stale`, `replaced`.
- Default policy allows `manual_runtime` evidence to participate in gate, but audit/handoff must expose verification gap.
- Project policy may require Herdr-verified gate; then `manual_runtime` needs waiver or explicit project allowance.
- `explicit_waiver` is a structured risk acceptance record, not a loose category. Required fields:
  - `schema_version`
  - `waiver_id`
  - `owner_role`
  - `owner_instance`
  - `accepted_by_role`
  - `accepted_by_instance`
  - `reason`
  - `risk`
  - `scope`
  - `replacement_evidence`
  - `expires_at` or `no_expiry: true`
  - `created_at`
  - `task_sha256`
  - `evidence_record_sha256`
- Strict Herdr-verified policy accepts `explicit_waiver` only when the waiver is unexpired, owner-authorized, scoped to the same task/evidence record, and references replacement evidence.
- `stale` and `replaced` cannot close gate.
- Force replacement marks old session replaced; later evidence from replaced session fails gate-closing validation.

Tests:

- verified runtime evidence closes eligible gate.
- manual runtime evidence can close gate under default policy and appears in audit/handoff as not Herdr-verified.
- strict Herdr-verified policy blocks manual runtime without waiver.
- strict Herdr-verified policy accepts manual runtime only with a valid unexpired `explicit_waiver`.
- expired waiver, missing owner, missing reason/risk, wrong task hash, or missing replacement evidence cannot close strict gate.
- replaced/stale session evidence cannot close review/test gates.

Acceptance:

```bash
bash tests/parts/02_task_evidence.sh
bash tests/orbit_test.sh
```

### Slice 7: doctor and docs

Goal: diagnostics and user docs match the new runtime contract.

Changes:

- `tools doctor --json` includes Herdr session/workspace/tab/pane diagnostics.
- Add `herdr agent explain --json` and manifest status diagnostics where available.
- README install section says Herdr is required for normal Orbit runtime.
- Runtime guide explains `started_identity_pending`, `runtime register`, `ack-session`, and config/runtime/Herdr query layers.
- No docs claim Herdr notification delivery is authoritative registration or evidence.

Tests:

- tools doctor includes Herdr runtime contract diagnostics.
- README install snippets cover Herdr prerequisite.
- rg checks show no active docs describing Herdr as optional for normal runtime.

Acceptance:

```bash
bash tests/parts/01_installer.sh
git diff --check
```

## Final Acceptance

Run:

```bash
ruby -c lib/orbit/core.rb
ruby -c lib/orbit/cli.rb
ruby -c lib/orbit/identity_rules.rb
ruby -c lib/orbit/runtime_store.rb
ruby -c lib/orbit/herdr_probe.rb
ruby -c lib/orbit/runtime_resolver.rb
ruby -c lib/orbit/runtime_commands.rb
ruby -c lib/orbit/task_herdr_probe.rb
ruby -c lib/orbit/task_herdr_exec.rb
ruby -c lib/orbit/evidence.rb
ruby -c lib/orbit/audit_tools.rb
bash tests/orbit_test.sh
git diff --check
```

Expected final state:

- ordinary installer fails clearly without Herdr.
- explicit manual-only install, if implemented, reports degraded capabilities.
- `start` can create/wake agents or return `started_identity_pending` with pane-aware remediation; it does not output verified reuse in the current version.
- `start` with no binding ignores handwritten/old verified runtime sessions until trusted caller-pane proof exists.
- Herdr-launched agents do not receive `orbit runtime register --json` as a verified promotion preflight command.
- Orbit CLI commands running inside Herdr may piggyback register diagnostics without treating env as proof; there is no standalone heartbeat command.
- `dispatch` cannot target pending/stale/absent/mismatch sessions.
- `dispatch` cannot be unblocked by non-owner `ack-session`.
- `.orbit/instances.yaml` is not modified by `instances status --json` or status-like stale repair.
- evidence/audit/handoff expose runtime verification state.

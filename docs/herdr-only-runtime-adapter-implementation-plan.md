# Herdr-only runtime adapter implementation plan

本文是 `docs/herdr-only-runtime-adapter-design.md` 的执行计划。设计文档定义目标语义；本文把目标拆成可以编码、测试和 review 的 slice，避免 breaking change 做到一半停在半兼容状态。

## Scope

本轮实现必须一次性完成这些 breaking 改动：

- Herdr 是唯一官方 runtime adapter。
- `orbit start INSTANCE` 默认走 Herdr create/wake/reuse 语义，不再有 `--transport local|herdr`。
- `orbit start INSTANCE` 对已配置 instance 默认允许创建；删除 `--allow-create`。
- `--force` 保留，但只表示冲突替换 binding，不是普通 create/wake 的入口。
- `orbit dispatch --to INSTANCE` 的 direct delivery 只走 live-confirmed Herdr binding；不再有正常路径的 `--transport generic|herdr`。
- `orbit handoff` 不再接受 `--transport NAME`；handoff 是 protocol packet，manual payload 是 artifact/delivery mode。
- `bind-pane` 不再接受 `--transport NAME`；binding schema 改成 Herdr canonical workspace/tab/pane。
- `tools detect` / `tools doctor` 不再把 tmux/zellij/wezterm/generic transport 当 runtime adapter。
- README、runtime guide、starter templates、help 和 tests 必须同步进入 Herdr-only 语义。

本轮明确不做：

- tmux/zellij/wezterm/CI runtime adapter。
- heartbeat 系统。
- 自动 kill 旧 agent。
- Herdr notice delivery 的完整实现；可以保留 protocol inbox 设计和 TODO，但不能把未实现 delivery 写成已支持。
- queue 机制；`dispatch` 遇到 busy/blocked/unknown 先 fail closed。
- 旧 schema 迁移器。安装新包后要求重新 `orbit init`，旧字段只用于清晰报错或本地诊断读取。

Notice 边界：`orbit notice add|list|ack` 和 completion notice audit 由 `docs/role-boundary-real-test-fix-design.md` 单独覆盖。本计划只要求 Herdr-only adapter 改动不要继续承诺非 Herdr notice delivery，也不要把未实现的 Herdr delivery 写成已支持。如果本 PR 顺手增加 notice protocol storage，必须保持 protocol notice 和 Herdr delivery 分层；否则把 notice 测试标为后续 PR 覆盖。

不要混淆两个 binding 词：

- 本计划要替换的是 `.orbit/instances.yaml` 里的 runtime adapter binding schema。
- evidence/report 里的 `runtime_binding` 是测试环境、构建、浏览器、server、model service 等 provenance metadata，已有大量验证逻辑和测试覆盖；本 PR 不应重命名或删除它。

## Current code entry points

主要代码入口：

- `lib/orbit/core.rb`
  - 顶层 help、command help、用户可见用法。
- `lib/orbit/task_herdr_probe.rb`
  - `parse_start_args`
  - `start_plan`
  - creation policy
  - Herdr pane/candidate probe
  - start human output
  - replacement diagnostic shape
- `lib/orbit/task_herdr_exec.rb`
  - `start`
  - `run_herdr_start`
  - `run_herdr_wake`
  - `run_herdr_self_wake`
  - `parse_dispatch_args`
  - `dispatch_packet`
  - `run_herdr_dispatch`
- `lib/orbit/identity_rules.rb`
  - `init_config`
  - instance normalization
  - `instances status`
  - `whoami` transport/binding fields
  - `bind-pane`
  - `write_instance_binding!`
- `lib/orbit/handoff.rb`
  - `parse_handoff_args`
  - transport profile resolution
  - handoff packet output
- `lib/orbit/audit_tools.rb`
  - `tools detect`
  - `tools doctor`
  - runtime adapter readiness output
- `lib/orbit/validate_task_contract.rb`
  - instance schema validation.

Primary test entry:

- `tests/parts/01_installer.sh`
  - CLI help/install smoke tests.
  - start/Herdr fake command tests.
  - dispatch tests.
  - tools detect/doctor tests.
  - README/install coverage.

Secondary test entries:

- `tests/parts/04_schema_version.sh`
- `tests/parts/10_retention_compact.sh`
- `tests/parts/11_runtime_reconcile.sh`
- `tests/parts/13_doc_lifecycle.sh`
- `tests/parts/16_ci_release_readiness.sh`
- `tests/parts/17_protocol_schema_versioning_full.sh`

These mostly validate handoff/audit protocol behavior and should keep passing after transport terminology is removed from handoff output.

## Slice order

### Slice 0: red tests and help contract

Goal: make the expected breaking behavior visible before changing internals.

Code/tests:

- Update `tests/parts/01_installer.sh`.
- Update help expectations around `lib/orbit/core.rb`.

Tests to add or flip:

- `orbit start lead --transport herdr --json` fails with migration guidance.
- `orbit start lead --transport local --json` fails with migration guidance.
- `orbit start lead --allow-create --json` fails with migration guidance.
- `orbit dispatch --task ... --to coder --transport generic --json` fails with migration guidance.
- `orbit dispatch --task ... --to coder --transport herdr --json` fails with migration guidance.
- `orbit handoff ... --transport generic --json` fails with migration guidance.
- `orbit bind-pane --instance coder --pane P --transport herdr --json` fails with migration guidance.
- Help no longer advertises removed flags.

Parser requirement:

- Removed flags must be recognized explicitly and fail with migration guidance.
- Do not let them fall through to generic `Unknown ... option`; that would hide the breaking-change remediation from users and make tests brittle.

Red-check command:

```bash
bash tests/parts/01_installer.sh
```

Expected state after this slice may be red until later slices implement the behavior. Do not stop the PR here; this command becomes an acceptance command only after the later implementation slices are complete.

### Slice 1: tools detect/doctor vocabulary

Goal: remove generic transport language from environment detection first, because README/help can then point to stable terms.

Code:

- `lib/orbit/audit_tools.rb`
- `lib/orbit/core.rb` help text for `tools`

Changes:

- `tools detect --json` reports `local_shell`, `herdr`, `ci`, `git`.
- Herdr capabilities are limited to implemented behavior: `agent.start`, `pane.message`, `pane.capture`, and `direct.dispatch`. Do not advertise `notice.delivery` until a transport-neutral notice backend exists.
- `tools detect --json` does not report `tmux`, `zellij`, `wezterm`, or `generic` as runtime adapters.
- `tools doctor --json` replaces `preferred_transport` with:
  - `runtime_adapter: herdr|unavailable`
  - `manual_payload_available: true`
  - `agent_state_authority` mapping when data is available.
  - `herdr_diagnostics.current_pane`
  - `herdr_diagnostics.configured_bindings`
  - `herdr_diagnostics.client_integration_authority`
  - `herdr_diagnostics.inner_tmux`
- Herdr missing warning says automatic runtime adapter features require Herdr, but protocol/manual artifact usage remains possible.

Acceptance command:

```bash
bash tests/parts/01_installer.sh
```

### Slice 2: schema and binding normalization

Goal: establish the new binding vocabulary before start/dispatch depend on it.

Code:

- `lib/orbit/identity_rules.rb`
- `lib/orbit/validate_task_contract.rb`
- starter templates under `assets/templates/`

Changes:

- New instance binding shape:

```yaml
binding:
  adapter: herdr
  workspace: w3
  tab: t1
  pane: p4
  canonical_pane: p4
```

- Remove new writes of `transport.kind`, `transport.binding`, and `transport.health`.
- `instances status --json` primary fields become:
  - `binding: bound|unbound`
  - `liveness: alive|not_alive|unknown`
  - `liveness_reason`
  - `availability`
  - `herdr`
- Only `pane` or `canonical_pane` makes an instance `bound`. `workspace` and `tab` are view hints; a workspace/tab-only binding remains `unbound` and `orbit start INSTANCE` creates by default.
- `whoami --json` must not emit `transport_binding`; evidence records must use `role_execution_context` plus `binding` / `herdr` authority where runtime context is needed. Old `transport_binding` must not be used for liveness, dispatch, start, gate, or evidence decisions.
- `bind-pane` accepts Herdr canonical binding arguments without `--transport`.
- `bind-pane --transport` is removed as a supported option, but the parser must keep an explicit removed-flag branch that prints migration guidance instead of falling through to generic unknown-option handling.
- `init_config` and `assets/templates/instances.yaml` write the new binding schema; update init tests that currently assert `transport.binding` and `transport.health`.

Migration rule:

- Existing `transport.*` in project config is not silently migrated.
- If encountered in new command paths, report: `transport.* instance schema is no longer supported; rerun orbit init or update instances.yaml to binding.adapter: herdr.`

Acceptance commands:

```bash
bash tests/parts/01_installer.sh
bash tests/parts/08_identity_policy.sh
```

### Slice 3: handoff artifact terminology

Goal: remove runtime transport from handoff before dispatch/start work, because handoff is protocol output and should stay independent.

Code:

- `lib/orbit/handoff.rb`
- `lib/orbit/core.rb`
- `.orbit/tools.yaml` template/default handling if present
- README/runtime guide examples

Changes:

- Remove `--transport NAME` as a supported handoff option, but keep an explicit removed-flag branch for migration guidance.
- Replace `transport_profile` output with a delivery/manual artifact block:

```json
{
  "delivery": {
    "mode": "manual_artifact",
    "runtime_adapter": "none",
    "payload_format": "json"
  }
}
```

- Rename `transport_handoff_payload` and related helpers to delivery/manual artifact terminology.
- Replace `transport_profiles` with `delivery_profiles`, or remove profiles if manual artifact defaults are sufficient.

Acceptance commands:

```bash
bash tests/parts/01_installer.sh
bash tests/parts/04_schema_version.sh
bash tests/parts/10_retention_compact.sh
bash tests/parts/11_runtime_reconcile.sh
bash tests/parts/13_doc_lifecycle.sh
bash tests/parts/16_ci_release_readiness.sh
bash tests/parts/17_protocol_schema_versioning_full.sh
```

### Slice 4: start argument contract

Goal: make `orbit start INSTANCE` Herdr-only at the CLI boundary.

Code:

- `lib/orbit/task_herdr_probe.rb`
- `lib/orbit/task_herdr_exec.rb`
- `lib/orbit/core.rb`

Changes:

- `parse_start_args` no longer accepts `--transport` or `--allow-create`.
- `parse_start_args` still needs explicit branches for removed `--transport` and `--allow-create` so it can print migration guidance instead of generic unknown-option errors.
- Default adapter is Herdr.
- Missing Herdr returns `doctor_required` / usage error with manual protocol instructions, not `use --transport local`.
- Configured instance with no binding creates by default.
- `user_managed` no-binding no longer blocks on `--allow-create`; future `launch_policy` can control this, but not in this slice.
- Start output uses Herdr terms: session/workspace/tab/pane/process/detected agent/readiness.

Migration errors:

```text
start --transport was removed. Herdr is the only automatic runtime adapter. For manual protocol usage, start the agent in a terminal with ORBIT_INSTANCE and ORBIT_ROLE set.
```

```text
start --allow-create was removed. Configured instances are created by default; use instance config to disable automatic launch when launch policy exists.
```

Acceptance command:

```bash
bash tests/parts/01_installer.sh
```

### Slice 5: start liveness and force semantics

Goal: stop fake reuse while keeping force narrowly scoped.

Code:

- `lib/orbit/task_herdr_probe.rb`
- `lib/orbit/task_herdr_exec.rb`
- `lib/orbit/identity_rules.rb`

Changes:

- Static binding or old health never proves alive.
- Alive requires Herdr agent probe on canonical pane plus cwd/client checks where available.
- `not_alive` cases:
  - `no_binding`: create.
  - `pane_missing`: create and write stale binding diagnostic to `.orbit/runtime/instances/<instance>.json`.
  - `no_agent_detected` with safe idle shell: wake.
  - `client_mismatch`, `cwd_mismatch`, duplicate candidates: `needs_force`.
- `--force` uses per-instance lock for read/probe/start/write.
- Forced replacement writes runtime diagnostic only, never replacement history in `instances.yaml`.
- Risk output must include:
  - `duplicate_instance_agents_may_run_concurrently`
  - `old_and_new_agents_may_compete_for_orbit_state`

Acceptance command:

```bash
bash tests/parts/01_installer.sh
```

### Slice 6: Herdr layout and readiness

Goal: improve the experience now that Herdr is the only automatic adapter.

Code:

- `lib/orbit/task_herdr_probe.rb`
- `lib/orbit/task_herdr_exec.rb`
- tests with fake Herdr commands in `tests/parts/01_installer.sh`

Changes:

- Add `--layout auto|same-tab|new-tab`.
- Add `--min-cols` and `--min-rows`, or use named constants if explicit flags are deferred; either way the hard minimum must be enforced.
- Default `auto` chooses new tab when same-tab split would produce unreadable panes.
- `--layout same-tab` must fail closed when the resulting pane would be below the hard minimum unless an explicit future override is added.
- Start JSON includes:
  - `layout.selected`
  - `layout.reason`
  - source pane size
  - minimum readable size
  - existing agent pane count
- Ready markers become client-configurable for Codex, Claude, and OpenCode.
- Missing ready marker returns `started_unverified`, not `ready`.

Acceptance command:

```bash
bash tests/parts/01_installer.sh
```

### Slice 7: dispatch Herdr-only delivery

Goal: make direct delivery reliable and fail closed.

Code:

- `lib/orbit/task_herdr_exec.rb`
- `lib/orbit/task_herdr_probe.rb` if probe helpers are shared
- `lib/orbit/core.rb`

Changes:

- `parse_dispatch_args` removes `--transport`.
- `parse_dispatch_args` still needs an explicit removed-flag branch for `--transport` with migration guidance.
- `dispatch --to INSTANCE` resolves target instance and role from config.
- Dispatch requires live-confirmed Herdr binding.
- Dispatch refuses stale/unverified binding; it does not auto-start.
- Dispatch refuses `working`, `blocked`, and `unknown` states by default. Missing Herdr `agent_status` is `unknown`, not `available`.
- `done` does not mean Orbit done; require inspected/queue mechanism before sending by default, or return `available_needs_seen`.
- `--pane PANE` remains repair/override only if we keep it; output must record `explicit_override: true` and still resolve target role before sending.
- Reply-to defaults to `HERDR_PANE_ID`, then lead binding.
- Result includes selected pane, reply-to pane, Herdr submission result, and message header.

Migration error:

```text
dispatch --transport was removed. Direct delivery uses the target instance's live Herdr binding. Use --dry-run or --manual-payload for manual delivery artifacts.
```

Acceptance command:

```bash
bash tests/parts/01_installer.sh
```

### Slice 8: status and doctor polish

Goal: make diagnosis match the new runtime model.

Code:

- `lib/orbit/identity_rules.rb`
- `lib/orbit/audit_tools.rb`
- `lib/orbit/core.rb`

Changes:

- `instances status --json` includes `binding`, `liveness`, `availability`, and `herdr`.
- Human status says:
  - role
  - workspace/tab/pane
  - live agent detection
  - next action: `orbit start INSTANCE`, `orbit start INSTANCE --force`, or `orbit doctor herdr`.
- `doctor` reports Herdr installation, current pane, bound pane existence, canonicalization, client integration authority, and inner tmux detection when available.
- Labels/titles are diagnostic only and never role authority.

Acceptance command:

```bash
bash tests/parts/01_installer.sh
```

### Slice 9: docs, templates, installer, README

Goal: remove stale public guidance after the CLI behavior is actually changed.

Files:

- `README.md`
- `references/runtime/guide.md`
- `docs/start-instance-liveness-design.md`
- `docs/herdr-only-runtime-adapter-design.md`
- `assets/templates/instances.yaml`
- `assets/templates/roles.yaml` if examples mention runtime mode
- `install.sh`
- generated help/readme snippets if any

Required changes:

- README support table:
  - Herdr required for automatic wake/create/direct delivery.
  - Other terminals are manual protocol only.
  - No examples using `--transport`, `--allow-create`, or `transport.kind`.
- Manual protocol section:
  - show `ORBIT_INSTANCE=... ORBIT_ROLE=... <agent-command>`.
  - do not call this `local transport`.
- Herdr section:
  - `herdr`
  - `orbit start lead`
  - `orbit start coder`
  - `orbit dispatch --task ... --to coder --json`
- Update install/curl progress docs only if touched by this PR; otherwise do not mix installer UX changes into this runtime adapter PR.

Acceptance commands:

```bash
rg -n -- "--transport|--allow-create|transport\\.kind|transport_profiles|preferred_transport" README.md references assets lib tests
bash tests/parts/01_installer.sh
```

The `rg` command should only show migration-error tests or historical design docs, not active usage examples.

### Slice 10: full regression

Goal: prove the breaking change did not damage unrelated protocol behavior.

Final commands:

```bash
git diff --check
bash tests/orbit_test.sh
```

If full tests are too slow during iteration, run changed slices first, then full suite before commit.

## Migration rules

Removed flags must fail loudly:

- `start --transport local|herdr`
- `start --allow-create`
- `dispatch --transport generic|herdr`
- `handoff --transport NAME`
- `bind-pane --transport NAME`

Errors must include:

- what was removed
- what to run now
- whether the replacement is automatic Herdr behavior or manual protocol usage
- they must be emitted by deliberate removed-flag checks, not by the generic unknown-option path

Old schema handling:

- `transport.kind`, `transport.binding`, and `transport.health` are not migrated.
- New `orbit init` writes the new schema.
- Existing old configs fail with a message that tells users to rerun `orbit init` or update `instances.yaml`.
- Runtime replacement metadata goes under `.orbit/runtime/instances/<instance>.json`; never write timestamp/history noise into versioned config.

Manual delivery:

- Do not call manual payloads `generic transport`.
- Use `manual_payload`, `delivery.mode: manual_artifact`, or equivalent delivery terminology.
- Manual artifact generation must not imply a message was delivered.

## Unacceptable intermediate states

Do not stop implementation in any of these states:

- Docs say Herdr-only but CLI help still advertises `--transport`.
- `orbit start` defaults to Herdr but `--allow-create` is still required for configured instances.
- `--force` is needed for ordinary no-binding create.
- `instances.yaml` writes `previous_binding`, timestamps, or replacement history.
- `dispatch --transport generic` still works as a normal path.
- `handoff --transport generic` still appears in help or examples.
- `tools doctor` still emits `preferred_transport`.
- `instances status` still uses `binding_status/recommended_action` as the main machine decision contract.
- `transport.health` or static pane binding can produce `reuse`.
- Herdr `done` is treated as Orbit task completion.
- A role/instance mismatch can reach Herdr delivery before failing.

## Review checklist

Before review, confirm:

- Help output matches README examples.
- Removed flags have explicit migration errors.
- New config schema is written by templates/init.
- Old config schema is rejected or reported clearly.
- Start no-binding create works without `--allow-create`.
- Safe idle shell wake is classified, but cached non-live binding requires `--force` before wake.
- Conflict replacement requires `--force` and records runtime diagnostic only.
- Dispatch uses live Herdr binding and refuses stale/busy/blocked/unknown targets.
- Handoff output contains no runtime transport delivery claim.
- `tools detect` and `tools doctor` speak Herdr adapter plus manual artifact, not generic transport.
- Full test suite passes.

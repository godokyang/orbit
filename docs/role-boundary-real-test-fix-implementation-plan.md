# Role boundary real-test fix implementation plan

This document turns `docs/role-boundary-real-test-fix-design.md` into an implementation checklist. It is intentionally execution-oriented: each slice must leave the CLI in a coherent state and must not reintroduce generic runtime adapters.

## Scope

This implementation is a breaking change for task/evidence role-boundary behavior.

Must complete:

- Herdr-only instance schema additions: sibling `view`, not `binding.view`.
- Project `operation_defaults` with `owner_role`, `owner_instance`, `operation_mode`, `implementation_authority`, and `assigned_instance`.
- Task `execution_contract` snapshot generated from `operation_defaults`.
- Instance-key validation for `owner_instance` and `assigned_instance`.
- Implementation evidence role and instance enforcement.
- `implementation_instance_override` evidence and audit/gate validation.
- `evidence attach-rule --task` enforcement for task / role / instance match.
- Fresh review/test gate after latest implementation.
- Phase A notice inbox in `.orbit/runtime/notices/`.
- Herdr-aware hook entrypoints with `--intent-json PATH|-`.
- Templates, runtime references, README, skill docs, and tests updated to the new contracts.

Explicitly not in this implementation:

- Phase B Herdr notice surfacing.
- Automatic migration from old task `target_role` schema.
- Runtime adapters for tmux, zellij, wezterm, local transport, or generic dispatch.
- Killing old external agents when replacing Herdr bindings.

## Migration Rules

- Old task schema with only `target_role` fails closed for `whoami --task`, `evidence add --task`, `attach-rule --task`, `wait-gate`, `validate`, and `audit`.
- Projects upgraded to this package must rerun `orbit init --operation-mode solo|team`.
- Old `transport.*`, `binding_status`, static `healthy`, `--transport`, and `--allow-create` remain migration errors or deprecated diagnostic text only.
- `assigned_instance` is a concrete implementation assignee, not just a dispatch hint.
- `owner_instance` is required for Phase B surfacing readiness even though Phase B is not implemented in this slice.

## Slice 1: Herdr Instance Schema And View Policy

Goal: land the runtime shape needed by later hooks and status checks.

Code entrypoints:

- `assets/templates/instances.yaml`
- `lib/orbit/identity_rules.rb`
- `lib/orbit/task_herdr_probe.rb`
- `lib/orbit/task_herdr_exec.rb`
- `references/runtime/core-operating-model.md`
- `references/runtime/guide.md`
- `README.md`

Required behavior:

- New instance schema uses sibling fields:

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

- New schema rejects `binding.view`.
- `instances status --json` includes view policy, observed geometry when available, `too_narrow`, and remediation `resize_or_recreate_view`.
- `start --dry-run --json` includes planned workspace/tab/pane and planned view policy.
- `start` should warn when Herdr cannot satisfy minimum view size; it must not mark a too-narrow pane as normal ready.

Tests:

- Add installer/template tests in `tests/parts/01_installer.sh`.
- Add runtime/status/start dry-run tests in `tests/parts/11_runtime_reconcile.sh`.
- Keep `bash tests/orbit_test.sh` green.

Unacceptable intermediate states:

- `view` nested under `binding`.
- `instances status` still using `binding_status` as primary output.
- A too-narrow Herdr pane reported as healthy/ready.

## Slice 2: Operation Defaults And Init Modes

Goal: make project collaboration mode explicit and deterministic.

Code entrypoints:

- `lib/orbit/identity_rules.rb`
- `assets/templates/roles.yaml`
- `assets/templates/instances.yaml`
- `assets/templates/task.yaml`
- `tests/parts/01_installer.sh`

Required behavior:

- `orbit init --operation-mode solo|team` writes `operation_defaults`.
- TTY `orbit init` without `--operation-mode` asks user to choose solo/team.
- Non-TTY `orbit init` without `--operation-mode` fails closed.
- Solo defaults:
  - `owner_role: lead`
  - `owner_instance: lead-main`
  - `implementation_authority: lead`
  - `assigned_instance: lead-main`
- Team defaults:
  - `owner_role: lead`
  - `owner_instance: lead-main`
  - `implementation_authority: coder`
  - `assigned_instance: coder-main`
- Init templates use instance keys like `lead-main`, `reviewer-main`, `tester-main`, `coder-main`; role names remain `lead`, `reviewer`, `tester`, `coder`.

Tests:

- Init solo/team generation.
- Interactive selection fixture if the harness supports TTY.
- Non-TTY failure.
- Templates do not emit role-name instance keys for new config.

Unacceptable intermediate states:

- `assigned_instance: coder` or `owner_instance: lead` in new templates.
- Silent default to solo/team when no mode is provided in non-TTY context.

## Slice 3: Task Execution Contract Snapshot

Goal: freeze role/instance boundaries per task and make the basic identity preflight understand them in the same slice.

Code entrypoints:

- `lib/orbit/task_launch_dispatch.rb`
- `lib/orbit/project_profile_risk.rb`
- `lib/orbit/validate_task_contract.rb`
- `assets/templates/task.yaml`
- `tests/parts/02_task_evidence.sh`
- `tests/parts/03_validate.sh`

Required behavior:

- `orbit new-task` writes `execution_contract`.
- `orbit new-task --target-role ROLE` is removed as a normal path. Keep an explicit removed-flag branch that fails with migration guidance instead of silently mapping it.
- `orbit new-task --operation-mode solo|team` is allowed as an explicit task override and records `source: explicit_override`.
- Optional explicit override flags:
  - `--implementation-authority ROLE`
  - `--assigned-instance INSTANCE`
  - `--owner-role ROLE`
  - `--owner-instance INSTANCE`
- If any explicit override flag is present, all affected role/instance pairs must validate before writing the task.
- If no explicit override is present, values come from project `operation_defaults`.
- Task type, risk, title, summary, acceptance criteria, and gate options remain separate task fields; they are not inferred from old `target_role`.
- Default review/test gates should be derived from task type/risk/gate options, not from `target_role`.
- Rename or re-sign risk/gate helpers that currently accept `target_role`, such as `infer_task_risk_level(target_role, task_type)`, `derive_task_risk(target_role, ...)`, and `default_gates_for_risk(risk_level, target_role, task_type)`. New helpers should accept task type/risk/gate context and, where needed, gate role context explicitly.
- Snapshot includes `owner_role`, `owner_instance`, `operation_mode`, `implementation_authority`, `assigned_instance`, and `source`.
- Validator rejects missing `execution_contract` and old `target_role`-only task schema.
- `owner_instance` must exist and resolve via `role_ref` to `owner_role`.
- `assigned_instance` must exist and resolve via `role_ref` to `implementation_authority`.
- `whoami --task` must minimally read `execution_contract`, fail closed on old schema, and report execution contract summary in this slice. This keeps identity preflight coherent once new tasks are created.
- Changing `.orbit/roles.yaml` defaults later does not change existing task interpretation.

Tests:

- New task in solo/team projects.
- `new-task --target-role coder` fails with migration guidance.
- `new-task --operation-mode solo` in a team project writes `source: explicit_override`.
- `new-task --implementation-authority coder --assigned-instance coder-main` validates role/instance pairing.
- `new-task --implementation-authority coder --assigned-instance reviewer-main` fails.
- Risk/gate helper tests cover task type/risk/gate options without passing `target_role`.
- Missing instance keys fail closed.
- `assigned_instance: reviewer-main` with `implementation_authority: coder` fails.
- Old `target_role` task fails with `task_schema_reinit_required`.
- `whoami --task` fails closed on old schema and reports execution contract summary on new schema.

Unacceptable intermediate states:

- Task validator still accepting `target_role` as active schema.
- `new-task --target-role` still generating active tasks.
- Risk/gate helpers still requiring or branching on `target_role`.
- New task schema exists but `whoami --task` still follows old `target_role` logic.
- `assigned_instance` treated as optional or as a role name.

## Slice 4: Rule Resolution Boundary

Goal: make task-scoped rule resolution fully role-and-instance aware after Slice 3 establishes minimal identity preflight.

Code entrypoints:

- `lib/orbit/identity_rules_context.rb`
- `lib/orbit/identity_rules.rb`
- `lib/orbit/evidence_submit_validate.rb`
- `tests/parts/08_identity_policy.sh`
- `tests/parts/09_identity_full.sh`

Required behavior:

- Implementation context requires:
  - solo: `resolved_role == owner_role` and `resolved_instance == owner_instance`
  - team: `resolved_role == implementation_authority` and `resolved_instance == assigned_instance`
- Gate roles still resolve as reviewer/tester where appropriate; they must not be forced to match `assigned_instance`.
- Rule resolution output should include role and instance sufficient for later `attach-rule` checks.

Tests:

- `ORBIT_INSTANCE=coder-main ORBIT_ROLE=coder` passes team implementation preflight.
- `ORBIT_INSTANCE=coder-android ORBIT_ROLE=coder` fails without override.
- Reviewer/tester can still resolve for gate context without becoming implementation assignee.

Unacceptable intermediate states:

- Checks use only `resolved_role`.
- Gate roles blocked because they do not match `assigned_instance`.

## Slice 5: Implementation Evidence Enforcement

Goal: stop free-form implementation evidence from unauthorized role/instance.

Code entrypoints:

- `lib/orbit/evidence.rb`
- `lib/orbit/evidence_submit_validate.rb`
- `lib/orbit/validate_evidence_record.rb`
- `tests/parts/02_task_evidence.sh`
- `tests/parts/03_validate.sh`

Required behavior:

- `evidence add --kind implementation` requires `--task`.
- Implementation records include `role_execution_context` with:
  - `owner_role`
  - `owner_instance`
  - `operation_mode`
  - `implementation_authority`
  - `assigned_instance`
  - `resolved_role`
  - `resolved_instance`
  - `execution_contract_source`
- Team mode rejects lead and rejects same-role non-assigned instances without override.
- `--kind pass` used as implementation pass follows the same authority checks.
- Lead in team mode can still write `command`, `lead_sanity`, `coordination`, and `audit_note`; these do not satisfy implementation gate.

Tests:

- Solo lead implementation passes.
- Team lead implementation fails.
- Team `coder-main` implementation passes.
- Team `coder-android` implementation fails without override.
- Implementation evidence missing `role_execution_context` fails validate/audit.

Unacceptable intermediate states:

- `evidence add --kind implementation` still works without `--task`.
- Implementation context records omit `assigned_instance`.

## Slice 6: Implementation Instance Override Evidence

Goal: support deliberate same-role implementation handoff without opening a loophole.

Code entrypoints:

- `lib/orbit/evidence.rb`
- `lib/orbit/identity_rules_context.rb`
- `lib/orbit/identity_rules.rb`
- `lib/orbit/validate_evidence_record.rb`
- `lib/orbit/validate_gate_commands.rb`
- `lib/orbit/evidence_submit_validate.rb`
- `tests/parts/02_task_evidence.sh`
- `tests/parts/03_validate.sh`

Required behavior:

- Add `implementation_instance_override` evidence kind.
- Controlled command accepts `from_instance`, `to_instance`, `reason`, `expires_at` or explicit `no_expiry`.
- Record includes `task_sha256`, `from_role`, `from_instance`, `to_role`, `to_instance`, `authorized_by_role`, `authorized_by_instance`, `reason`, `created_at`, `expires_at`, `no_expiry`.
- `authorized_by_role` and `authorized_by_instance` must be derived from current `whoami --task` identity. User-supplied authorizer fields are rejected or ignored; callers cannot claim lead authorization through parameters.
- Only `owner_role` / `owner_instance` or explicit admin policy can authorize.
- `from_instance` must equal task `assigned_instance`.
- `to_instance` must resolve to the same `implementation_authority`.
- Override only authorizes implementation evidence and implementation rule resolution instance mismatch.
- Override does not authorize review/test verdict.
- Wait-gate/audit must reject expired, malformed, wrong-task, wrong-authorizer, or wrong-target override.
- `whoami --task` must consult valid override evidence when current role matches `implementation_authority` but current instance differs from `assigned_instance`.
- With a valid override, `whoami --task` must not return a normal role-boundary failure for the replacement instance; it should return an allowed or explicit override status with an override summary.
- Without a valid override, non-assigned same-role instances still fail preflight.

Tests:

- Missing reason fails.
- Missing expiry/no-expiry fails.
- Wrong authorizer fails.
- User-supplied `authorized_by_role` / `authorized_by_instance` parameters cannot spoof lead authorization.
- Wrong `to_instance` role fails.
- Valid unexpired override allows `coder-android`.
- Expired override fails gate/audit.
- Valid unexpired override lets `ORBIT_INSTANCE=coder-android ORBIT_ROLE=coder orbit whoami --task ... --json` return an override-backed allowed/status result.
- Expired override makes `coder-android` fail `whoami --task` preflight again.
- Audit surfaces override summary.

Unacceptable intermediate states:

- Override implemented as unstructured comment.
- Override silently changes task `assigned_instance`.
- Override permits review/test gate verdicts.

## Slice 7: Attach Rule Enforcement

Goal: prevent rule resolution drift and wrong-role artifacts.

Code entrypoints:

- `lib/orbit/evidence_submit_validate.rb`
- `lib/orbit/evidence.rb`
- `lib/orbit/validate_gate_commands.rb`
- `tests/parts/02_task_evidence.sh`
- `tests/parts/03_validate.sh`

Required behavior:

- `evidence attach-rule` requires `--task` for task-bound evidence.
- Reject invalid rule resolution, conflicts, task hash/path mismatch, role mismatch, and instance mismatch.
- For implementation resolution:
  - solo: resolution role/instance must match owner role/instance.
  - team: resolution role/instance must match implementation authority/assigned instance, unless valid override exists.
- Recommended output paths include task and instance suffix.
- Overwrite guard rejects existing resolution for different role, instance, task hash, or valid-to-invalid replacement.

Tests:

- Attach lead resolution to team coder task fails.
- Attach same-role non-assigned coder resolution fails without override.
- Attach valid override-backed non-assigned coder resolution passes.
- Attach correct `coder-main` resolution passes.
- Existing different-role/instance output path fails.

Unacceptable intermediate states:

- `attach-rule` parser accepts `--task` but does not enforce it.
- Rule artifact path can be silently overwritten by another instance.

## Slice 8: Gate And Audit Freshness

Goal: stop stale review/test pass from approving newer implementation.

Code entrypoints:

- `lib/orbit/validate_gate_commands.rb`
- `lib/orbit/validate_evidence_record.rb`
- `lib/orbit/gate_lease.rb`
- `tests/parts/03_validate.sh`
- `tests/parts/12_gate_lease.sh`

Required behavior:

- Find latest valid implementation record.
- Review/test pass must be later than latest implementation.
- Equal or unparseable timestamps fail closed.
- Gate/audit reports `stale_after_implementation`.
- Gate/audit also validates implementation author context and override if used.

Tests:

- Review pass before implementation is stale.
- Test pass before implementation is stale.
- Fresh review/test after implementation makes gate ready.
- Malformed implementation timestamp blocks gate.
- Override-backed implementation still requires fresh review/test after it.

Unacceptable intermediate states:

- Wait-gate ready based only on existence of old review/test pass.

## Slice 9: Notice Phase A

Goal: provide a protocol inbox so roles do not rely on memory or pane messages.

Code entrypoints:

- New notice module or `lib/orbit/evidence.rb` if kept small.
- `lib/orbit/cli.rb`
- `lib/orbit/core.rb`
- `lib/orbit/validate_gate_commands.rb`
- `tests/parts/02_task_evidence.sh`
- `tests/parts/03_validate.sh`

Required behavior:

- Add `orbit notice add|list|ack`.
- Store notices under `.orbit/runtime/notices/<role>/`.
- Notice records include task/evidence hash, `from_role`, `from_instance`, `to_role`, `to_instance`, event, status, created/acked metadata.
- `notice add` derives `to_instance` from task `owner_instance`; explicit `--to-instance` must match owner instance.
- Event-specific source contract:
  - `implementation_complete`: implementation authority and assigned instance unless override.
  - `review_complete`: reviewer role and optional reviewer instance contract.
  - `test_complete`: tester role and optional tester instance contract.
  - `handoff_ready`: current handoff producer contract.
  - `blocked_needs_owner`: current responsible role/instance.
- No `notice.delivery` capability in this phase.

Tests:

- Add/list/ack notice.
- Missing completion notice yields audit finding when policy requires it.
- Implementation notice from non-assigned instance fails without override.
- Review/test notice does not require `from_instance == assigned_instance`.
- Explicit wrong `--to-instance` fails.

Unacceptable intermediate states:

- Notice treated as pane transcript.
- Notice delivery capability advertised before Phase B.

## Slice 10: Herdr-Aware Hooks

Goal: add low-latency preflight without trusting caller-provided liveness.

Code entrypoints:

- `lib/orbit/cli.rb`
- `lib/orbit/core.rb`
- New hook module or `lib/orbit/identity_rules_context.rb` helpers.
- `lib/orbit/task_herdr_probe.rb`
- `tests/parts/08_identity_policy.sh`
- `tests/parts/11_runtime_reconcile.sh`

Required behavior:

- Add:
  - `orbit hook pre-command --intent-json PATH|- --json`
  - `orbit hook pre-edit --intent-json PATH|- --json`
  - `orbit hook pre-evidence --intent-json PATH|- --json`
  - `orbit hook pre-start --intent-json PATH|- --json`
  - `orbit hook pre-idle --intent-json PATH|- --json`
- Missing `--intent-json` fails closed.
- Hook input only contains caller intent and local hints.
- Orbit CLI collects Herdr context itself through Herdr probe / current pane env / instances status.
- Hook output may include `herdr_context_summary`.
- Hook never trusts caller-provided live probe, manual payload, explicit pane override, or `transport_binding` as live proof.
- `pre-start` returns `recommended_action: resize_or_recreate_view` for too-narrow panes; `--force` remains binding replacement, not resize.

Tests:

- Missing intent fails.
- Caller-supplied fake live probe ignored.
- Team lead production edit blocked.
- Team non-assigned coder implementation edit blocked unless override exists.
- Direct `.orbit/evidence*.json` edits blocked.
- Too-narrow pane returns resize remediation.
- Repeated force inside cooldown warns/blocks.

Unacceptable intermediate states:

- Hook reconstructs action from shell history or ambient command text.
- Hook trusts caller-supplied Herdr liveness.

## Slice 11: Documentation And Skill Updates

Goal: make user-facing docs match the new breaking contract.

Entry points:

- `README.md`
- `references/runtime/guide.md`
- `references/runtime/core-operating-model.md`
- `/Users/yangke/.agents/skills/orbit/SKILL.md` if this repo owns the installed copy flow, otherwise source skill docs/templates.
- `docs/role-boundary-real-test-fix-design.md`
- Release notes if present.

Required behavior:

- No examples using role-name instance keys for new config.
- No active examples using old `target_role`.
- No active examples using `binding_status` as a primary contract.
- No active examples using `--transport` or `--allow-create`.
- Clearly state that upgraded projects must rerun `orbit init --operation-mode solo|team`.
- Clarify Phase A notice only records protocol inbox; Phase B Herdr surfacing is not implemented.

Tests/checks:

```bash
rg -n "target_role|binding_status|--transport|--allow-create|assigned_instance: coder([^-\n]|$)|ORBIT_INSTANCE=coder([^-\n]|$)" README.md references assets docs tests
```

Review any matches as legacy/problem statements only.

Unacceptable intermediate states:

- Docs instruct users to write config rejected by the new CLI.
- README claims notice delivery or generic runtime adapter support.

## Final Acceptance

Run at minimum:

```bash
ruby -c lib/orbit/*.rb
bash tests/orbit_test.sh
git diff --check
rg -n "binding_status|transport\\.kind|transport\\.binding|transport\\.health|--allow-create|--transport" README.md references assets lib tests docs
```

Expected:

- Main test suite passes.
- Ruby syntax passes.
- Diff check passes.
- Remaining legacy/runtime terms appear only in migration errors, explicit deprecation notes, or historical problem descriptions.

## Unacceptable Final States

- Role-boundary checks use only role and ignore instance.
- `assigned_instance` is treated as a dispatch hint instead of implementation assignee.
- Non-assigned same-role implementation can pass without valid override.
- Review/test notices are forced to match `assigned_instance`.
- Hook accepts caller-provided Herdr liveness as proof.
- Docs say Herdr-only while CLI still exposes normal `--transport` / `--allow-create` paths.

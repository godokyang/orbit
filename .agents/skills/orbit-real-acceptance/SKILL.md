---
name: orbit-real-acceptance
description: Run real, model-backed end-to-end acceptance by using Herdr to launch an installed `orbit omp` process in an isolated temporary Git project, sending that Root a realistic user requirement, and observing Orbit's JEV, native task/hub execution members, independent OMP read-only checking, correction, result collection, and actual stop behavior. Use when the user asks to real-test, live-test, dogfood, or end-to-end verify Orbit; do not use ordinary OMP, direct runtime calls, or deterministic tests as substitutes.
---

# Orbit Real Acceptance

Use this Skill to prove runtime behavior with real host sessions and model calls. Deterministic tests remain necessary, but never substitute them for the live evidence requested here.

## Prerequisite: the installed single-host layout

Acceptance runs only on the installed single-host layout:

- `orbit omp` starts the original OMP binary and loads the release Orbit extension for that session; native arguments, recovery, profile, permissions, and exit codes stay OMP's.
- Plain `omp` must not load the Orbit extension. Confirm and record this (installation check or a plain `omp` pane without the Orbit tool) before treating a run as target-path evidence.
- If the machine still holds an old global Orbit entry, or the run needs an old-host entry to work, stop and report: the run is not target-path evidence.

## Required test topology

Keep these roles separate:

- **Controller:** the current Agent. It prepares an isolated fixture, starts and observes the system through Herdr, sends the initial requirement, and records evidence. It does not implement the fixture task for the Root.
- **System under test:** a fresh installed `orbit omp` process launched inside the fixture directory. This process is the Root that receives the realistic user requirement and operates Orbit.
- **Execution members:** the Root's OMP-native `task` members, one layer only. The Root dispatches them; Orbit registers and observes them, and results return through the native `hub`. Only a member Orbit actually registered counts as an execution member.
- **Independent checkers and adjudicators:** separate OMP processes, not the Root process, reading a fixed snapshot read-only. They are never execution members and never join the execution team.

The required launch sequence is:

1. Split or allocate an available shell pane whose cwd is the fixture project.
2. Run `orbit omp` in that pane with `herdr pane run`; do **not** launch the ordinary `omp` binary or a Herdr ordinary-agent launch, because that bypasses the installed Orbit entry point.
3. Wait until Herdr detects the launched OMP session as idle, then give it a unique acceptance-run name.
4. Send one complete, user-like requirement with `herdr agent prompt`. The requirement tells the Root what product artifact to deliver and what final validation is required; it must not script internal JEV scores, name native member IDs, or fabricate Orbit events.
5. Let that Root call Orbit, implement its owned work, follow or decline real hints, dispatch the native `task` members it decides on, integrate their `hub` results, react to checks, and stop. The Controller observes through Herdr and persisted task files.

Helper panes, ordinary OMP sessions, and old-host panes are never evidence for the required `orbit omp` workflow, and helper Agents used to prepare fixtures are not Orbit execution members.

## Safety and scope

- Read the repository `AGENTS.md`, `docs/README.md`, `docs/agents/development-workflow.md`, `docs/plan/handoff.md`, and current plan before acting.
- Read and follow the `herdr` Skill. Require `HERDR_ENV=1`; stop and report the missing prerequisite otherwise.
- Never start Orbit against the Orbit repository itself. Create fresh temporary Git repositories and worktrees with `mktemp -d`.
- Never use production user tasks, credentials, or repositories as fixtures.
- Do not print secret values. Only confirm whether required environment-variable names are present.
- Do not publish, push, tag, or delete preserved evidence unless the user explicitly asks.
- Keep every live path in its own task. Explicitly stop every task and verify `stop_confirmation.confirmed=true`.

## Freeze the tested build

1. Record `orbit version --json`, including version, source, dirty state, content digest, and installation time.
2. If source changes, run the repository's supported local update path and start a fresh Herdr `orbit omp` process. Sessions loaded before the update may still hold the old release.
3. Do not change prompts or thresholds midway and call the same run a pass. Record the failed/calibration run, install the new build, and start a fresh run.

## Run the minimum real matrix

Read [scenarios.md](references/scenarios.md) before preparing fixtures.

Run at least:

1. A bounded one-file negative task. It must not request model evidence, hint delegation, dispatch a native `task` member, or register one.
2. A substantive positive task with two disjoint production surfaces. Root starts one surface immediately. If and only if Orbit emits a final delegation hint, Root dispatches the complete other surface through OMP-native `task`, Orbit registers that member before its model work, the result returns through the native `hub`, and Root integrates and validates the combined artifact before requesting one manual final check and stopping.
3. An independent-check provenance path. Every counted check must come from a separate OMP read-only session on a fixed snapshot. An old-host or Codex checker does not count as target-path evidence.
4. A workspace-rebind task when rebind semantics are in scope. Start a check on the old root, confirm the reviewer is actually `in_flight`, explicitly rebind to a same-repository worktree, and prove the old check is workspace-stale and the next valid check reads the new root. A queued check command alone is not proof that its fixed snapshot has started; Orbit may process a queued rebind first.
5. A native interrupt and stop path. Interrupt or exit the OMP interface and prove the Root, every registered member, and their native background work actually ended; evidence short of this stays `stop_unconfirmed`.

For finding convergence or observation deduplication changes, also run the corresponding scenario from the reference. Clearly mark optional paths that were not run.

## Herdr operating discipline

- Use a fresh named Herdr-launched `orbit omp` process for each clean runtime path. Record the pane, launch command, detected session, cwd, and installed content digest; Herdr is transport and observation, not Orbit's result or stop authority.
- Do not call Orbit's internal Ruby objects or its CLI actions from the Controller to simulate Root behavior. Scenario-specific external CLI timing actions, such as queuing a check after Root becomes idle, are allowed only when explicitly recorded as Controller actions.
- Do not count helper panes or ordinary OMP work as proof of Orbit execution members. Conversely, the required acceptance does not require those helpers: the proof is that the Herdr-launched `orbit omp` Root drives Orbit and its native `task/hub` members correctly after receiving the requirement.
- Root must continue its owned surface while an execution member works.
- Do not treat `start`, `status`, `check`, a hint, or a checker as an execution member. Only a native `task` member that Orbit actually registered changes that fact.
- Do not treat a high stage-one `delegatable` score as a delegation recommendation. Count a recommendation only when the persisted task events contain the final `delegation_hint`; `delegation_declined` means Orbit recommended against delegation even if Root later dispatches a member on its own.
- Score workflow policy and execution mechanics separately. A member that successfully runs after Root ignored `delegation_declined` proves the registration and result-return path, but fails the “Root follows Orbit's recommendation” acceptance criterion.
- After queuing the final manual check, do not poll Orbit status, edit files, or send the Root another prompt. Yield. Rebind acceptance may use the minimum status read needed to confirm the explicit `in_flight` precondition before rebind; that exception is not permission to wait for the check conclusion.
- A valid no-finding manual final check should wake Root once with a finalization notice. Root then calls `stop`; Orbit does not infer product completion from checker `continue`.
- If the checker finds a defect, let Root fix it, rerun focused validation, and request a new final check. Preserve the original finding ID and resolution evidence.

## Dynamic model evidence

- Orbit/JEV does not browse. When it requests model evidence, Root obtains current evidence from primary vendor sources and time-stamped local samples.
- Match provider, model, and reasoning identity exactly. Keep unknown fields unknown.
- Cache evidence only for its declared validity period. Never maintain release-bundled speed rankings.
- Distinguish output speed from task critical-path benefit. Record handoff, integration, contention, and verification costs.
- Never claim a faster external model was considered when the configured OMP task agents cannot actually use it.

## Evidence and reporting

For every task, preserve:

- Controller evidence: Herdr pane, fixture cwd, `orbit omp` launch, the plain-`omp` passivity check, session detection, and the exact initial requirement;
- wall-clock start, first JEV decision, evidence request, final hint, native `task` dispatch, Orbit registration, `hub` messages and wakes, member result return, integration, each check, correction, final check, and stop;
- stage-one and stage-two JEV scores and tokens;
- checker provenance (separate OMP read-only session), snapshot fingerprint, stale reasons, finding lifecycle, and tokens per check;
- member identity/model/status/result and confirmed stop, including native background job exit evidence;
- project root, artifact root, rebind history, and input/artifact version;
- final status and confirmed stop scope.

Run:

```bash
ruby .agents/skills/orbit-real-acceptance/scripts/summarize_task.rb /absolute/path/to/.orbit/tasks/TASK_ID
```

Treat the output as an index into the preserved task record, not as a replacement for inspecting `state.json`, `events.jsonl`, and relevant check files. Report speed, quality, and token cost separately. A checker that catches a real defect is quality evidence even if its token cost is unacceptable.

## Close the run

1. Run focused regression tests for any product fix, then the repository's full test command, package dry-run, Skill validator, and `git diff --check`.
2. Update the repository acceptance record with exact paths, digests, timestamps, scores, tokens, defects, fixes, remaining gaps, and unrun paths.
3. Preserve temporary fixtures until the evidence is copied into the repository record.
4. Do not mark the Goal complete while required paths, final reinstall, or stop confirmation remain outstanding.

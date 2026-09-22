---
name: orbit-real-acceptance
description: Run real, model-backed end-to-end acceptance by using Herdr to launch an installed `orbit codex` process in an isolated temporary Git project, sending that Root a realistic user requirement, and observing Orbit's JEV, delegation, member, checking, workspace, finalization, and stop behavior. Use when the user asks to real-test, live-test, dogfood, or end-to-end verify Orbit; do not use ordinary Codex, direct runtime calls, or deterministic tests as substitutes.
---

# Orbit Real Acceptance

Use this Skill to prove runtime behavior with real host sessions and model calls. Deterministic tests remain necessary, but never substitute them for the live evidence requested here.

## Required test topology

Keep these roles separate:

- **Controller:** the current Agent. It prepares an isolated fixture, starts and observes the system through Herdr, sends the initial requirement, and records evidence. It does not implement the fixture task for the Root.
- **System under test:** a fresh installed `orbit codex` process launched inside the fixture directory. This process is the Root that receives the realistic user requirement and operates Orbit.
- **Orbit execution members and checkers:** processes created and controlled by Orbit during that task. Only their persisted task events count as member/checker evidence.

The required launch sequence is:

1. Split or allocate an available shell pane whose cwd is the fixture project.
2. Run `orbit codex` in that pane with `herdr pane run`; do **not** use `herdr agent start --kind codex`, because that launches ordinary Codex and bypasses the installed Orbit entry point.
3. Wait until Herdr detects the launched Codex as idle, then give it a unique acceptance-run name.
4. Send one complete, user-like requirement with `herdr agent prompt`. The requirement tells the Root what product artifact to deliver and what final validation is required; it must not script internal JEV scores or fabricate Orbit events.
5. Let that Root call Orbit, implement its owned work, follow or decline real hints, integrate real member output, react to checks, and stop. The Controller observes through Herdr and persisted task files.

Starting an OMP, OpenCode, Cursor, or ordinary Codex pane may be useful only when that host adapter is explicitly the subject of a separate scenario. Their presence is never evidence for the required `orbit codex` workflow, and helper Agents used to prepare fixtures are not Orbit execution members.

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
2. If source changes, run the repository's supported local update path and start a fresh Herdr `orbit codex` process. Existing app servers may still hold the old release.
3. Do not change prompts or thresholds midway and call the same run a pass. Record the failed/calibration run, install the new build, and start a fresh run.

## Run the minimum real matrix

Read [scenarios.md](references/scenarios.md) before preparing fixtures.

Run at least:

1. A bounded one-file negative task. It must not request model evidence, hint delegation, or create a member.
2. A substantive positive task with two disjoint production surfaces. Root starts one surface immediately. If and only if Orbit emits a final delegation hint, Root explicitly delegates the complete other surface, integrates the returned result, validates the combined artifact, requests one manual final check, and stops.
3. A workspace-rebind task when rebind semantics are in scope. Start a check on the old root, confirm the reviewer is actually `in_flight`, explicitly rebind to a same-repository worktree, and prove the old check is workspace-stale and the next valid check reads the new root. A queued check command alone is not proof that its fixed snapshot has started; Orbit may process a queued rebind first.

For finding convergence or observation deduplication changes, also run the corresponding scenario from the reference. Clearly mark optional paths that were not run.

## Herdr operating discipline

- Use a fresh named Herdr-launched `orbit codex` process for each clean runtime path. Record the pane, launch command, detected Agent, cwd, and installed content digest; Herdr is transport and observation, not Orbit's result or stop authority.
- Do not call Orbit's internal Ruby objects or its MCP task actions from the Controller to simulate Root behavior. Scenario-specific external CLI timing actions, such as queuing a check after Root becomes idle, are allowed only when explicitly recorded as Controller actions.
- Do not count helper OMP/OpenCode/Cursor work as proof of Orbit delegation. Conversely, the required acceptance does not require those helpers: the proof is that the Herdr-launched `orbit codex` Root drives Orbit correctly after receiving the requirement.
- Root must continue its owned surface while an execution member works.
- Do not treat `start`, `status`, `check`, a hint, or a checker as an execution member. Only a successful explicit `delegate` changes that fact.
- Do not treat a high stage-one `delegatable` score as a delegation recommendation. Count a recommendation only when the persisted task events contain the final `delegation_hint`; `delegation_declined` means Orbit recommended against delegation even if Root later delegates on its own.
- Score workflow policy and execution mechanics separately. A member that successfully runs after Root ignored `delegation_declined` proves the adapter and result-return path, but fails the “Root follows Orbit's recommendation” acceptance criterion.
- After queuing the final manual check, do not poll Orbit status, edit files, or send the Root another prompt. Yield. Rebind acceptance may use the minimum status read needed to confirm the explicit `in_flight` precondition before rebind; that exception is not permission to wait for the check conclusion.
- A valid no-finding manual final check should wake Root once with a finalization notice. Root then calls `stop`; Orbit does not infer product completion from checker `continue`.
- If the checker finds a defect, let Root fix it, rerun focused validation, and request a new final check. Preserve the original finding ID and resolution evidence.

## Dynamic model evidence

- Orbit/JEV does not browse. When it requests model evidence, Root obtains current evidence from primary vendor sources and time-stamped local samples.
- Match provider, model, and reasoning identity exactly. Keep unknown fields unknown.
- Cache evidence only for its declared validity period. Never maintain release-bundled speed rankings.
- Distinguish output speed from task critical-path benefit. Record handoff, integration, contention, and verification costs.
- Never claim a faster external model was considered when the current Root adapter cannot actually call it.

## Evidence and reporting

For every task, preserve:

- Controller evidence: Herdr pane, fixture cwd, `orbit codex` launch, Agent detection, and the exact initial requirement;
- wall-clock start, first JEV decision, evidence request, final hint, delegate, member result, integration, each check, correction, final check, and stop;
- stage-one and stage-two JEV scores and tokens;
- checker role, stale reasons, finding lifecycle, and tokens per check;
- member kind/model/status/result and confirmed stop;
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

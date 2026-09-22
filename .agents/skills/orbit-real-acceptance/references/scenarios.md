# Real acceptance scenarios

Every scenario starts the same way: the external Controller uses Herdr to run the installed `orbit codex` command inside a temporary fixture repository, waits for that Codex Root to become idle, then sends the task as a user prompt. Use small fixtures whose expected behavior is obvious from their task file. Keep production and test surfaces disjoint so a member ticket is independently verifiable.

The following do not satisfy a scenario on their own:

- running unit tests or directly constructing `TaskRuntime`;
- starting ordinary Codex with `herdr agent start --kind codex`;
- calling Orbit MCP actions from the Controller instead of giving the requirement to the launched Root;
- showing that an OMP/OpenCode/Cursor pane exists;
- asking a helper Agent to implement the fixture outside the task-owned Orbit member path.

## One-file negative

- One localized edit with one focused verification command.
- Pass: JEV may assess structure, but there is no evidence request, final hint, or member.
- Record checker cost even when the implementation is tiny.

## Parallel positive

- Two independent production modules with existing focused tests.
- Root explicitly owns A; the only valid member ticket is complete B plus its focused test.
- Pass: structural score reaches the current contract threshold; current model evidence is used; member-fit and parallel-gain reach their thresholds; exactly one hint is emitted before delegation; Root explicitly delegates; the member result returns; Root integrates and runs combined verification.
- While a member is `starting` or `working`, no second automatic hint may be emitted.
- A real checker defect must be corrected and resolved before stop. A no-finding manual final review should wake Root once to stop, not start a short recheck loop.

## Workspace rebind

- Create a repository and a linked worktree with distinguishable artifacts.
- Start one old-root check, then use the minimum status observation needed to confirm the reviewer is actually `in_flight`; `check` returning `queued` is insufficient because a queued rebind may be applied before the reviewer takes its fixed snapshot.
- Once `in_flight` is confirmed, immediately rebind and append any required amendment. Do not poll for the review conclusion. Request the final manual check and yield for Orbit's notification.
- Pass: workspace history records source/reason; the old check is stale for `workspace`; its findings do not migrate as clues; a new-root check reads the new artifact root. An amendment containing a path does not change binding.

## Finding convergence

- Obtain one stable finding ID on a fixed input/root/artifact.
- Repeat unchanged: expect `finding_repeat_ignored` and no duplicate Root correction.
- Resolve it, then re-raise unchanged: expect `finding_reopen_ignored`.
- Change one evidence dimension and recheck: delivery is allowed again.
- A semantically equivalent new ID remains a checker-prompt quality issue, not proof that the runtime's same-ID guard failed.

## Observation deduplication

- Keep input and artifact fixed while interleaving status calls and timer opportunities.
- Pass: status causes no JEV/check calls; the same automatic observation is skipped; a manual check can bypass dedupe but never overlap an in-flight check; non-workspace stale checks do not immediately restart.

## Evidence status

For every scenario label it `passed`, `failed`, `partially exercised`, or `unrun`. Also label whether the required Herdr → `orbit codex` → user requirement topology was proven. Never infer an unrun live path from unit tests or helper-Agent activity.

# Real acceptance scenarios

Every scenario starts the same way: the external Controller uses Herdr to run the installed `orbit omp` command inside a temporary fixture repository, waits for that OMP Root to become idle, then sends the task as a user prompt. Use small fixtures whose expected behavior is obvious from their task file. Keep production and test surfaces disjoint so a member ticket is independently verifiable, and confirm the single-host layout first: plain `omp` loads no Orbit extension and only `orbit omp` provides the Orbit tool.

The following do not satisfy a scenario on their own:

- running unit tests or directly constructing `TaskRuntime`;
- starting ordinary `omp` (or a Herdr ordinary-agent launch) instead of `orbit omp`;
- calling Orbit's internal Ruby objects or CLI actions from the Controller instead of giving the requirement to the launched Root;
- showing that a helper pane or ordinary OMP session exists;
- asking a helper Agent to implement the fixture outside the native task/hub member path;
- counting a check produced by an old-host or Codex checker, or by the Controller.

## One-file negative

- One localized edit with one focused verification command.
- Pass: JEV may assess structure, but there is no evidence request, no final hint, and no native `task` member dispatched or registered.
- Record checker cost even when the implementation is tiny.

## Parallel positive

- Two independent production modules with existing focused tests.
- Root explicitly owns A; the only valid member ticket is complete B plus its focused test.
- Pass: structural score reaches the current contract threshold; current model evidence is used; member-fit and parallel-gain reach their thresholds; exactly one hint is emitted before dispatch; Root explicitly dispatches through OMP-native `task`; Orbit registers the member before its model work; the result returns through the native `hub`; Root integrates and runs combined verification.
- While a member is `starting` or `working`, no second automatic hint may be emitted.
- A real checker defect must be corrected and resolved before stop. A no-finding manual final review should wake Root once to stop, not start a short recheck loop.

## Independent OMP check provenance

- Every counted check must run in a separate OMP process (not the Root process) against a fixed snapshot.
- Record the snapshot fingerprint before and after the check; the check must not change it and must not join the execution team.
- Pass: the check reports a role, verdict, stale reasons, and findings from the fixed snapshot; the reviewer can read only inside the snapshot.
- An old-host or Codex checker proves nothing about the target path; label such runs as out of scope instead of passed.

## Native interrupt and stop

- Interrupt the OMP interface (native Esc) and, in a second run, exit normally.
- Pass: the Root, every registered member, and their native background work actually end, with process/exit evidence recorded; sessions and context stay recoverable, and the task records a confirmed stop.
- If exit evidence is incomplete, the task must stay `stop_unconfirmed`; do not rewrite it into a pass.

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

For every scenario label it `passed`, `failed`, `partially exercised`, or `unrun`. Also label whether the required Herdr → `orbit omp` → user requirement topology was proven, and whether the check provenance was a separate OMP read-only session. Never infer an unrun live path from unit tests or helper-Agent activity.

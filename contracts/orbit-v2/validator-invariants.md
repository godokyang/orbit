# Orbit v2 Validator invariant closure

Status: Slice 0 design and executable mutation contract. This document does not
activate Orbit v2 or change the public `Validator#validate`, `#validate!`, or
`#validate_document!` interfaces.

## Seam

`Validator` remains the single external validation interface and orchestration
module. Internally it delegates two repeated classes of work:

- `InvariantGraph` indexes immutable records once and resolves typed references
  by exact identity, digest, and optional kind. Duplicate identity, phantom
  targets, stale digests, and wrong-kind edges at migrated call sites therefore
  share one implementation.
- `EvidenceContract` validates one EvidenceRecord through that graph. Every
  implementation ref resolves to a record-owned `ArtifactClaim`, and every
  changed path must be in the intersection of the canonical CodeSurface, the
  WorkUnit writable-path authority, and the exact change-claim paths.

### ArtifactClaim trust boundary

An `ArtifactClaim` is implementation-submitted, create-only provenance inside
an EvidenceRecord. `InvariantGraph` proves only the record-internal
`ref -> ArtifactClaim` identity/digest/kind closure. In Slice 0 there is no
trusted artifact resolver, byte store, or provider receipt, so this contract
does **not** prove that an external artifact exists, that the declared digest
matches external bytes, or that the claim is true. GateEvaluation must still
perform independent outcome review; claim presence is never sufficient for a
PASS verdict. A later trusted artifact adapter would be an additional seam and
is outside this contract-freeze change. Only `change` claims may own repository
paths, and their path set is non-empty and canonical. `verification` and
`report` claims are path-free and never participate in changed-path authority.

### Repository path contract

Paths are validated lexically without filesystem or symlink access. A path or
scope is canonical only when it is a non-empty repository-relative POSIX path,
does not begin with `/`, contains no backslash, and has no empty, `.` or `..`
segment. Scopes use segment-aware containment: `lib/orbit/v2` covers itself and
`lib/orbit/v2/validator.rb`, but not `lib/orbit/v20`. Path and scope arrays are
sorted unique canonical sets; equivalent sets cannot acquire different meaning
from array order.

The evidence seam uses these frozen shapes:

```yaml
work_unit:
  authority_scope:
    writable_paths: [lib/orbit/v2]

evidence_record:
  submission_artifact_refs:
    - artifact_ref: artifact://implementation/change
      artifact_kind: change
      content_digest: sha256:...
      paths: [lib/orbit/v2/validator.rb]
    - artifact_ref: artifact://implementation/verification
      artifact_kind: verification
      content_digest: sha256:...
      paths: []
  implementation_check:
    verification_refs:
      - artifact_ref: artifact://implementation/verification
        content_digest: sha256:...
```

All nested `evidence_refs` use the same exact ref shape. `changed_paths` is the
canonical sorted set of paths owned by `change` artifacts; it is not an
independent assertion. Work authority digests include `writable_paths`, so a
path-scope edit invalidates the AuthorizationRecord scope as well as evidence.

## Finding-to-invariant matrix

IDs use `R<review>-<ordinal>` and cover all 38 findings in the first eight
reports.

| ID | Finding (abbreviated) | Invariant family |
| --- | --- | --- |
| R1-1 | forgeable bootstrap assertion | authority / permission binding |
| R1-2 | published schema not executed | structural and identity closure |
| R1-3 | accepted ADR facts absent | evidence and contract completeness |
| R1-4 | evaluation not bound to gate/evaluator work | authority / permission binding |
| R1-5 | mutable append-store inputs | structural and identity closure |
| R2-1 | later event replaces Assignment | lifecycle |
| R2-2 | unrelated-task Attempt enters subject | evaluation subject |
| R2-3 | evaluator role is self-described | authority / permission binding |
| R2-4 | phantom Finding refs | reference closure |
| R2-5 | phantom/mismatched initial thesis | reference closure |
| R3-1 | resolution issuer not bound to gate | authority / permission binding |
| R3-2 | incompatible/phantom Finding lineage refs | reference closure |
| R3-3 | ChangeThesis starts at revision 2 | lifecycle / lineage |
| R4-1 | child revision reuses parent gate/evaluation | evaluation subject / lineage |
| R4-2 | protected authorization replay | authority / permission binding |
| R4-3 | evaluation resolves its own Finding | independence / lifecycle |
| R4-4 | conflicting resolution provenance variants | evidence completeness |
| R5-1 | second parentless TaskRevision | lifecycle / lineage |
| R5-2 | superseded policy authorizes change | authority / lifecycle |
| R5-3 | unlinked gate impersonates lineage | reference closure / lineage |
| R5-4 | phantom optional authorization ref | reference closure |
| R5-5 | phantom waiver support | reference closure |
| R5-6 | duplicated evidence-level ordering | structural and identity closure |
| R6-1 | rotation lacks parent grant | authority / permission binding |
| R6-2 | assertion receipt not candidate-content-bound | authority / digest binding |
| R6-3 | caller closure flag permits stale work | lifecycle |
| R6-4 | duplicate grants depend on order | structural and identity closure |
| R6-5 | TaskRevision authority wrong action/subject | authority / permission binding |
| R6-6 | gate minimum depends on order | structural and identity closure |
| R7-1 | policy does not pin issuer assertion digest | reference / digest closure |
| R7-2 | impossible timestamps bypass stale history | lifecycle |
| R7-3 | same-kind gate uniqueness narrows design | evaluation subject / set semantics |
| R7-4 | WorkUnit/Attempt refs wrong action/subject | authority / permission binding |
| R8-1 | empty execution authorization provenance | authority / evidence completeness |
| R8-2 | independence trusts AgentInstance ID | independence |
| R8-3 | empty implementation check closes gate | evidence completeness |
| R8-4 | WorkUnit kind hides implementation Attempt | evaluation subject / authority |
| R8-5 | terminated Agent owns later Attempt | lifecycle / independence |
| R9-1 | phantom implementation ArtifactClaim ref | reference / digest / kind closure |
| R9-2 | changed path outside authority or claim paths | evidence completeness / path authority |
| R10-1 | verification ArtifactClaim carries an ungoverned repository path | evidence completeness / claim path semantics |

The families close as follows:

| Family | Closed invariant | Single owner/seam |
| --- | --- | --- |
| Structural/identity | schema shape, unique semantic keys, canonical sets, immutable IDs/digests | SchemaCatalog + InvariantGraph |
| Reference closure | every ref at a migrated call site resolves to the exact expected identity/digest/kind; domain lineage remains with its owner | InvariantGraph plus domain owner |
| Authority binding | action, subject, policy, role, permission, capability, and scope are exact and non-empty | AuthorityVerifier, TaskAuthority, WorkAuthority, Validator orchestration |
| Lifecycle | one genesis, legal typed transitions, trusted monotonic chronology, and valid cross-stream activity | LifecycleVerifier + Validator orchestration |
| Evidence completeness | every accepted claim has exact record-internal ArtifactClaim closure and exact acceptance/evidence/thesis coverage; claim truth remains independently reviewed | EvidenceContract |
| Evaluation subject | selector result is complete, current, lineage-exact, digest-pinned, and set-order independent | EvaluationSubject |
| Independence | evaluator/confirmer runtime subject is provider-verified and absent from all producers | RuntimeIdentityVerifier + EvaluationSubject |
| Finding closure | immutable source/gate lineage and one authorized resolution tip; supersedes never erases a blocker | Validator closure projection |

## Mutation matrix

Every row crosses the public `Validator#validate` seam. Mutations are made from
the valid bundle and all affected content/subject digests are recomputed unless
the row intentionally tests a stale digest.

| Mutation class | Representative mutation | Expected invariant/error |
| --- | --- | --- |
| missing | delete a required nested ref/field | structural closure / `contract_shape_invalid` |
| empty | empty authority, implementation, or PASS answer refs | cardinality / shape or completeness error |
| phantom | point an implementation claim at an absent artifact | reference closure / `evidence_reference_invalid` |
| wrong-kind | use a `change` artifact as a verification ref | kind closure / `evidence_reference_invalid` |
| cross-task | bind Attempt/Evidence/Finding authority across task lineage | ownership or subject-lineage error |
| stale digest | keep artifact ID but change its referenced digest | digest closure / `evidence_reference_invalid` |
| non-change claim path | add any path, canonical or not, to a verification/report claim | claim path semantics / `evidence_reference_invalid` |
| duplicate | repeat a semantic artifact ID with same or different bytes | identity closure / `evidence_reference_invalid` |
| order | reorder a semantic set of artifact refs or policy/gate keys | canonical-set error or identical authority result |
| unauthorized path | claim a CodeSurface path outside WorkUnit `writable_paths` | `implementation_path_unauthorized` |
| unproven path | claim a path absent from change ArtifactClaims | `implementation_path_unauthorized` |
| absolute path | use `/lib/orbit/v2/validator.rb` | canonical path / `implementation_path_unauthorized` |
| traversal path | use `lib/orbit/v2/../v1.rb` or `./lib/orbit/v2` | canonical path / `implementation_path_unauthorized` |
| empty segment | use `lib//orbit/v2.rb` or a trailing slash | canonical path / `implementation_path_unauthorized` |
| prefix trap | use `lib/orbit/v20/file.rb` under `lib/orbit/v2` scope | segment-aware containment / `implementation_path_unauthorized` |
| illegal timeline | reverse start/end, backdate acceptance, or assign after termination | lifecycle chronology/activity error |
| runtime alias | reuse one provider/runtime subject under a new AgentInstance ID | `runtime_identity_duplicate` + independence error |

Historical negative fixtures remain in place. New matrix cases extend them; they
do not replace review-specific counterexamples with a smaller happy-path suite.

## Slice 1 addendum: exact work graph, control lineage, and single-active

Slice 1 freezes ADR-006 exact refs on the existing Slice 0 objects. No new
collections are added: `dispatch_lead_checkpoint_ref` is validated for format,
exact stable ref, and chain-internal consistency only; store-backed existence,
tip, and selection checks belong to Slice 2's LeadCheckpoint. New frozen shapes:

```yaml
work_unit:
  parent_work_unit_ref: null-or-owu_id   # null only for the unique root
  depends_on_work_unit_refs: [owu_id]    # DAG ordering within one revision

work_unit_attempt:
  lead_control_id: olcontrol_id
  predecessor_work_unit_attempt_ref: null-or-oattempt_id
  dispatch_lead_checkpoint_ref: olcheckpoint_id
```

New invariant families and their single owner/seam:

| Family | Closed invariant | Single owner/seam |
| --- | --- | --- |
| Work graph | exactly one root per TaskRevision; every WorkUnit reachable from the root through the parent tree; parent/dependency refs resolve only inside the same exact revision; no parent cycle; dependency graph is a DAG | Validator orchestration over `work_units` |
| Readiness | dependency state is derived at the dependent AttemptCreated instant: at least one terminal-before Attempt (ended strictly earlier) and no dependency Attempt already started and not yet ended at that instant; dependency Attempts created later are ignored, so a post-dispatch retry never retroactively invalidates a legal dispatch | Validator orchestration over Attempt facts at the dispatch time point |
| Attempt control lineage | every Attempt pins `lead_control_id`; a successor pins the same control, a terminal predecessor from the exact same WorkUnit, and is created only after that terminal event; null predecessor is unique per WorkUnit; the chain is linear (one successor, no fork, no cycle); one accepted LeadCheckpoint authorizes exactly one dispatch within its control lineage | RuntimeLifecycle validator |
| Strict single-active | the half-open Attempt intervals `[created_at, ended_at)` never overlap per project-scoped scope; an open-ended Attempt stays active into the future; historical overlap of already-terminal Attempts fails closed; scopes are `[project_id, lead_control_id]`, `[project_id, task_id]`, `[project_id, work_unit_id]`; implementation/review/test/research/release share the same serial limit | RuntimeLifecycle validator |

Mutation matrix additions (all cross the public `Validator#validate` seam):

| Mutation class | Representative mutation | Expected invariant/error |
| --- | --- | --- |
| multiple root | clear the parent ref of a non-root WorkUnit | `work_unit_graph_invalid` |
| orphan / cross-revision parent | point a parent ref at an absent unit or one in another TaskRevision | `reference_not_found` |
| parent cycle | two WorkUnits parent each other | `work_unit_graph_invalid` |
| dependency cycle | dependency edges close a loop | `work_unit_graph_invalid` |
| cross-revision edge | parent/dependency ref into another TaskRevision | `reference_not_found` |
| not ready | remove the dependency's terminal event | `work_unit_dependency_not_ready` |
| readiness chronology | dependency terminal event after dependent start | `work_unit_dependency_not_ready` |
| dependency open at dispatch | a dependency Attempt already started and not ended at the dependent creation instant | `work_unit_dependency_not_ready` |
| post-dispatch dependency retry | dependency retry created after a legal dependent dispatch, all terminal | valid (no retroactive invalidation) |
| cross-work-unit predecessor | predecessor ref into another WorkUnit | `attempt_successor_invalid` |
| dispatch ref reuse | two Attempts claim the same dispatch checkpoint in one control lineage | `attempt_dispatch_invalid` |
| historical interval overlap | two already-terminal Attempts with overlapping half-open intervals | `single_active_violation` |
| second open attempt | a new open Attempt while another is active in the same scope | `single_active_violation` |
| cross-project isolation | a second project reuses identical control/dispatch/task/WorkUnit refs | valid (project-scoped keys) |

Slice 2 will add the store-backed LeadCheckpoint existence/tip/selection
validation and the Task/executor transfer provenance exception to the
same-control successor rule.

## Slice 2 increment 1 addendum: control identity anchor

Freezes the project-scoped control registry claim, the required
provider-verified LeadSession subject pins, and the genesis/lineage
LeadCheckpoint shape. Dispatch store-backed binding, active
selection/current attempt, decision/trigger, assessment/progress, and
recovery arrive in increment 2 with their consumers. This addendum proves
only model-level accepted final-state closure: invalid bundles are not
accepted and accepted final states close the invariants below.
Store-level compare-and-append atomic execution (concurrency, crash
rollback) closes at Slice 6 activation; no transaction primitive is
simulated here.

New frozen shapes:

```yaml
lead_session:
  lead_control_id: olcontrol_id                  # required exact registry binding
  lead_runtime_subject_ref: runtime-subject-...  # provider-verified pin
  lead_runtime_subject_assertion_digest: sha256:...  # = agent verification receipt digest

lead_control_registry:                           # create-only, one per control
  lead_control_id, genesis_checkpoint_ref, writer_authority_provenance,
  owned_task_refs

lead_checkpoint:                                 # create-only append-only linear lineage
  lead_checkpoint_id, lead_control_id, is_genesis, predecessor_lead_checkpoint_ref,
  project_policy_revision_ref, lead_agent_instance_ref, active_lead_session_ref,
  lead_runtime_subject_ref, lead_runtime_subject_assertion_digest,
  logical_lead_refs, task_queue, writer_authority_provenance
```

New invariant families:

| Family | Closed invariant | Single owner/seam |
| --- | --- | --- |
| Control genesis | exactly one registry per `lead_control_id`; registry pins the accepted genesis checkpoint, the exact active session id+generation, and owned task refs that resolve exactly; at most one active LeadSession per control | Validator orchestration over `control_registries` |
| Writer authority | registry/checkpoint writer provenance carries a provider-verified AuthorityAssertion scoped to the exact `lead_control_id`, pinned to the exact policy revision written under, whose grants cover that policy's required external grant for the writer action; payload self-report is rejected | AuthorityVerifier + LeadControl |
| Checkpoint lineage | exactly one genesis per control; genesis predecessor null; non-genesis predecessor is the exact prior same-control checkpoint; one successor per checkpoint; fork/cycle/multiple tip fail closed | LeadControl |
| Checkpoint pins | policy pin resolves exactly to the policy revision written under; the lineage tip of an open control pins the active policy; session id+generation exact and active; agent equals the session agent; subject pins byte-equal the session pins | LeadControl |
| Queue projection | checkpoint `task_queue` is the byte-exact ordered projection of registry `owned_task_refs`; each ref resolves to the exact TaskRevision; both arrays are unique per task identity (different revisions of one task fail closed) | LeadControl |
| Session chronology | the exact session-generation Agent context event (`AgentCreated`/`AgentContextAdvanced`) recorded at or before `LeadSessionStarted.recorded_at`; no `AgentTerminated` at or before that instant | RuntimeLifecycle |

Mutation matrix additions (all cross the public `Validator#validate` seam):

| Mutation class | Representative mutation | Expected invariant/error |
| --- | --- | --- |
| duplicate genesis | second `is_genesis` checkpoint in one control | `control_genesis_duplicate` |
| forged writer assertion | writer provenance `assertion_id` replaced | `control_writer_authority_invalid` |
| unresolved queue ref | registry owned task revision id replaced | `control_task_ownership_invalid` |
| duplicate task identity | a second owned ref for the same task (different revision) | `control_task_ownership_invalid` |
| cross-control predecessor | successor predecessor points at another control's checkpoint | `checkpoint_lineage_invalid` |
| fork | two successors of one checkpoint | `checkpoint_lineage_invalid` |
| subject pin drift | checkpoint subject ref diverges from the session pin | `checkpoint_pin_invalid` |
| stale tip policy | open lineage tip pins a non-active policy revision | `checkpoint_pin_invalid` |
| late session context | session start generation context event recorded after `LeadSessionStarted` | `lead_session_invalid` |

Store-backed dispatch binding closes in increment 2 (below); Task/executor
transfer provenance and fingerprint/fuse machinery remain increment 3/4 work.

## Slice 2 increment 2 addendum: minimal recoverable control loop

Closes the Slice 1 dispatch deferral and lands the recoverable loop: exact
dispatch refs, active selection/current-attempt/assessment/progress fields,
typed decision/trigger, `LeadControl.reconcile/2` replay, recovery, and
same-lineage session replacement. No fingerprint/budget/fallback fields;
fingerprint-dependent decisions freeze.

New frozen shapes:

```yaml
work_unit_attempt:
  dispatch_lead_checkpoint_ref: { lead_checkpoint_id, content_digest }

lead_checkpoint:
  active_task_ref, selected_work_unit_ref, current_or_terminal_attempt_ref,
  assessments, delivery_progress, assurance_progress, lead_decision,
  reconcile_trigger, next_trigger
```

New invariant families:

| Family | Closed invariant | Single owner/seam |
| --- | --- | --- |
| Dispatch binding | attempt dispatch ref resolves to an accepted same-control checkpoint with exact digest whose selection (active task revision / selected work unit) exactly matches the Attempt; one dispatch per checkpoint; historical checkpoint pins never stale from later attempt events | RuntimeLifecycle + LeadControl |
| One-way causality | checkpoint attempt refs only pin attempts accepted before it and never the attempt it authorizes; switch checkpoints pin a terminal attempt of the prior selection; observation pins match the current selection; event pins are exact and never require the attempt's current latest event | LeadControl |
| Trigger lifecycle | genesis reconciles on genesis and awaits dispatch_before; dispatch checkpoints reconcile on dispatch_before/attempt_terminal/successor_before and await attempt_created; observation reconciles on attempt_created/session_change with the matching awaited event | LeadControl |
| Decision replay | every accepted checkpoint decision is byte-equal to `LeadControl.reconcile(facts, reconcile_trigger.event)` over its own exact ref; self-reported decisions fail closed | Validator orchestration + LeadControl |
| Assessment basis | each layer pins its exact `basis_projection` and `none` iff the basis projection is null; rationale required | LeadControl |
| Progress judgment | `change` is not_assessed iff measured terminal ref is null; measured rounds pin an exact terminal event, delivery/assurance measured refs agree; substantive kinds require matching exact supporting refs; stop-loss only on measured terminal rounds | LeadControl |
| Session lineage | exactly one root per control; exact predecessor terminal event pin with generation; single successor, no fork/cycle; successor starts at/after prior terminal; the unique active session is the lineage tip | LeadControl |
| Same-failure fuse | pinned failed/blocked event with chain length >= 2 freezes the successor (fingerprint unprovable); completed/cancelled never trigger it; zero-delivery fuses walk distinct-terminal rounds only | LeadControl |
| Dispatch observation | the exact AttemptCreated observation checkpoint is the immediate accepted successor of the Attempt's dispatch checkpoint, reconciles on attempt_created, and pins that exact AttemptCreated event; intervening checkpoints and non-tip dispatch refs fail closed | LeadControl |
| Registry create-only | the registry carries no active-session pointer; genesis exact-pins the initial session and the current active session derives from the unique lineage tip plus session lineage | LeadControl |
| Substantive delta | a claimed thesis/context/scope/verification-plan delta must be provable against the exact lineage predecessor projection (deterministic authoritative basis per kind; verification-plan basis is the artifact `identity_sha256`, matching supporting-ref resolution); thesis/verification-plan current basis is the single exact proposed successor ref in the authorizing checkpoint's provenance compared to the predecessor's effective basis (ADR-006 redirection: the successor Attempt does not exist yet, so zero/multiple proposals fail closed and the later AttemptCreated assignment must match); a checkpoint-level cardinality invariant rejects more than one change_thesis or rule_resolution ref (distinct or repeated identical — supporting refs have no uniqueness rule) regardless of trigger/progress/action; a merely resolvable supporting ref is never evidence; a kind without a basis fails closed | LeadControl |
| Change-trigger delta | session/task-revision/scope/thesis/finding/gate/context/authority/dependency change triggers are never accepted from the enum alone: the exact authoritative projection must differ from the exact lineage predecessor. Finding delta is proven only by a new exact `finding` ref in the checkpoint's supporting provenance (assessment layers + progress); gate delta only by a new exact `gate_evaluation` ref; thesis_change delta is the single exact proposed successor `change_thesis` ref compared to the predecessor's effective pinned thesis (ADR-006 redirection). FindingResolution and GateRequirement-record changes have no exact ref kind in Inc2 checkpoint provenance, so those subtypes fail closed rather than inventing a latest-wins projection | LeadControl |
| Recovery | recovery re-runs the unique tip's own stored-trigger pipeline, so stop-loss/dependency/fuse outcomes are recomputed exactly and frozen decisions never thaw; non-tip recovery fails closed | LeadControl |

Mutation matrix additions (all cross the public `Validator#validate` or
`LeadControl.reconcile` seams):

| Mutation class | Representative mutation | Expected invariant/error |
| --- | --- | --- |
| forged decision | stored lead_decision diverges from reconcile result | `checkpoint_decision_replay_invalid` |
| duplicate dispatch | a second Attempt claims one dispatch checkpoint | `attempt_dispatch_invalid` |
| stale pin | later attempt event appended after an accepted pin | valid (pin exact) |
| replacement without provenance | second session with null predecessor | `session_binding_invalid` |
| first zero round | measured round delivery unchanged, no substantive kinds | frozen |
| assurance-only | delivery unchanged, assurance changed | frozen |
| two zero rounds | two distinct-terminal rounds delivery unchanged | frozen |
| third failure | pinned failed event, chain length 2 | frozen (fingerprint unprovable) |
| intervening dispatch | context checkpoint between dispatch and its AttemptCreated observation | `checkpoint_dispatch_observation_invalid` |
| unobserved dispatch | Attempt cites a dispatch checkpoint no observation follows | `checkpoint_dispatch_observation_invalid` |
| fabricated substantive delta | arbitrary resolvable scope ref claims substantive scope without a selection delta | `checkpoint_progress_invalid` |
| fabricated change trigger | session/task-revision/scope/thesis/finding/gate/context/authority/dependency trigger with no projection delta vs predecessor | `checkpoint_trigger_invalid` |
| ambiguous proposal | two distinct or repeated identical change_thesis/rule_resolution refs on one checkpoint | `checkpoint_proposal_ambiguous` |
| registry active-session rewrite | registry pins a later session generation | `contract_shape_invalid` (field absent) |

## Slice 2 increment 3 addendum: cross-lineage closure and transfer

Lands the multi-lineage acceptance boundary and the exact release/acquire and
executor transfer provenance. Model-level accepted-final-state closure only:
real compare-and-append atomic execution closes at Slice 6 activation; no
transaction primitive is simulated.

New frozen shapes:

```yaml
lead_checkpoint:
  task_transfer_acquire:            # required with the acquire decision
    released_checkpoint_ref: { lead_checkpoint_id, content_digest }
    released_lead_control_id: olcontrol_id
    task_ref: { task_id, task_revision_id, content_digest }
  lead_decision.action: [..., release, suspend, acquire]
  next_trigger.event: [..., task_release, task_suspend, task_acquire]
```

New invariant families:

| Family | Closed invariant | Single owner/seam |
| --- | --- | --- |
| Parallel boundary | multiple open control lineages are accepted only when derived tip task ownership sets and active canonical runtime-subject sets (provider_id + runtime_subject_id from the verified AgentInstance identity) are pairwise disjoint; AgentInstance IDs/aliases never substitute for the canonical subject; overlapping task sets fail closed | LeadControl |
| LogicalLead closure | one Task/LogicalLead belongs to at most one open queue and is active-selected by at most one accepted tip; a lineage tip can claim only logical leads whose task its own tip queue owns | LeadControl |
| Subject active binding | one canonical runtime subject binds at most one active LeadSession project-wide; a subject reused across controls requires exactly one origin lineage and exact terminal/release -> successor/bind transfer chains; a root session reusing a subject from another control fails closed; cross-control session forks and cycles fail closed | LeadControl |
| Session transfer | a cross-control session successor is the first generation of its lineage, pins the prior session exact terminal LeadSessionEnded event id+digest, keeps the same canonical runtime subject, and starts at/after the prior terminal; a same-lineage replacement may coexist with one transfer from the same terminal session | LeadControl |
| Queue projection | genesis exact-pins the immutable registry claim; release/suspend checkpoints remove exactly one owned task from the queue projection (active selection removed too); acquire checkpoints append exactly the payload task ref; other checkpoints keep the ordered projection with per-task revision lineage | LeadControl |
| Transfer provenance | the acquire decision requires `task_transfer_acquire`; the released checkpoint ref resolves to an exact accepted release/suspend checkpoint of a different control; the acquire task ref byte-equals the released queue element; every release/suspend checkpoint has exactly one matching acquire; the released task has no non-terminal Attempt in the releasing control; missing release, early acquire, wrong refs/digest/task/control, duplicate ownership and replay fail closed | LeadControl |
| Cross-control succession | a successor Attempt may cross control lineages only when its control validly acquired the Attempt's task from the predecessor's control and the authorizing acquire is a strict accepted-lineage ancestor of the Attempt's exact dispatch checkpoint (never the dispatch itself, a future acquire, or a side branch), with a payload resolving exactly to an accepted release/suspend checkpoint that released exactly this task ref; the predecessor is terminal | RuntimeLifecycle + LeadControl |

Mutation matrix additions (all cross the public `Validator#validate` or
`LeadControl.reconcile` seams):

| Mutation class | Representative mutation | Expected invariant/error |
| --- | --- | --- |
| overlapping task sets | second lineage tip queue claims the main task | `control_task_ownership_conflict` |
| unowned lead claim | tip logical_lead_refs names a lead of a task outside its queue | `checkpoint_pin_invalid` |
| subject alias | AgentInstance alias of one verified runtime subject | `runtime_identity_duplicate` |
| double active subject | one canonical subject backs two active LeadSessions across controls | `runtime_subject_active_conflict` |
| subject reuse without transfer | root session reuses a subject present in another control | `session_binding_invalid` |
| acquire without release | acquire pins an absent/non-release checkpoint | `task_transfer_invalid` |
| wrong released control | acquire `released_lead_control_id` diverges from the release checkpoint | `task_transfer_invalid` |
| mismatched task ref | acquire `task_ref` differs from the released queue element | `task_transfer_invalid` |
| dangling release | release/suspend checkpoint without exactly one matching acquire | `task_transfer_invalid` |
| release with active attempt | released task has a non-terminal Attempt in the releasing control | `task_transfer_invalid` |
| early executor bind | cross-control successor pins a non-terminal session event | `session_binding_invalid` |
| cross-control fork | one session referenced by two transfer successors | `session_binding_invalid` |
| future acquire | acquire checkpoint positioned after the attempt's dispatch checkpoint in the lineage | `attempt_successor_invalid` |
| forged acquire payload | acquire payload whose released checkpoint ref does not resolve | `attempt_successor_invalid` + `task_transfer_invalid` |

## InvariantGraph migration ledger

This change migrates only call sites whose semantics are genuinely identical:

- all `COLLECTIONS` immutable identity/duplicate indexing in `build_indexes`;
- EvidenceRecord nested ArtifactClaim refs (identity + digest + kind);
- generic supersedes/related target existence and non-self resolution;
- FindingResolution supporting EvidenceRecord target resolution.

The following remain Validator/domain-module local because resolution alone is
insufficient: policy/task/gate parent lineage, protected-change authorization,
ChangeThesis composite revision lineage, evaluation subject selection and
freshness, evaluator authority, and FindingResolution gate compatibility. They
may use an indexed lookup, but their domain compatibility rules are not claimed
as generic InvariantGraph behavior. Therefore this document does not claim that
every historical exposed ref has been mechanically migrated.

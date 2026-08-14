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

### EvidenceRequirement class pairing

Every `EvidenceRequirement` carries a required `verification_class`
(`regression` / `release_audit` / `acceptance_evidence`), frozen at dispatch
through the exact TaskRevision ref/digest already present in the closure
basis; the class is never duplicated into checkpoints and no effective-plan
object exists. Each
`implementation_check.evidence_requirement_results[]` entry carries a
required `verification_use`, and the validator exact-resolves the result's
`evidence_requirement_id` to its requirement's class, then enforces the exact
pairing `regression -> permanent_test_evidence`,
`release_audit -> audit_record_evidence`,
`acceptance_evidence -> acceptance_proof_evidence`. Each result's
`evidence_refs` must resolve to record-owned ArtifactClaims of the compatible
kind: permanent test evidence to `verification`, audit and acceptance proof to
`report`. Missing or unknown class/use values fail at contract shape;
class/use mismatches fail through `evidence_requirement_pair_invalid`;
unresolved requirements/refs and incompatible claim kinds fail closed.
Free-text semantics are never inspected or inferred; stable-rule vs
data-snapshot classification stays with the Lead/reviewer and its provenance.

### RuleResolution immutable history and exact Attempt/Evidence binding

Authoring a NEW RuleResolutionArtifact (`RuleResolution.build`) resolves
canonical in-repo paths and hashes the current rule bytes; stored artifacts
(`RuleResolution.validate!`) are never reinterpreted through current
filesystem bytes — the stored identity must equal its own canonical
normalization (deterministic relation/rule_id/path/hash tuple ordering,
canonical paths) and its resolution ID and `identity_sha256` must describe
exactly those stored bytes, so an already created artifact stays valid with
its old rule hashes after rule files change or disappear. A changed rule
produces a new resolution ID, and because the immutable AttemptCreated
assignment pins the old assigned ID, the new artifact can never be silently
attributed to the old Attempt. Every WorkUnitAttempt
`assigned_rule_resolution_id` must resolve to an artifact whose canonical
identity exact-matches that Attempt and its immutable assignment
(protocol/project/task/task_revision/work_unit/attempt, resolved_role,
agent_instance_id, context_generation); existence alone is insufficient, so
reviewer/tester reuse of an implementation resolution fails closed even when
checkpoint/evidence refs are consistently resealed. An EvidenceRecord's
submitted resolution must resolve to its exact record Attempt and equal the
assigned canonical identity in both ID and identity fields; mismatched
rules/role/agent/context/attempt cannot produce accepted evidence.
Envelope metadata (`resolution_id`, `identity_sha256`, `schema_version`,
`created_at`) stays outside the identity hash domain, and identical canonical
identities always produce the same ID.

### Finding typed basis and active-policy disposition

`Finding.basis` is a required typed enum (`contract_violation` /
`regression` / `newly_discovered_risk` / `hardening_opportunity`); the
former `blocking` boolean is forbidden at contract shape, so an agent can
never self-assert or deny blocking. Every ProjectPolicyRevision carries a
closed `finding_disposition` mapping (all four basis keys required, const
values, no free-text) inside its content digest; closure derives the
disposition from the ACTIVE policy mapping, never from Finding body or
severity. Unresolved contract_violation/regression findings still block
gate closure and require an authorized FindingResolution tip; unresolved
hardening_opportunity never blocks and never preempts selection. A
finding_change checkpoint introducing a newly_discovered_risk without an
exact pinned FindingResolution ref replays deterministically to
`state=needs_user, action=escalate` awaiting `authority_change`, with hard
precedence over ordinary warning/blocked assessment layers and stop-loss; a
forged blocked/continue decision fails the public Validator replay. An
unadjudicated risk that no accepted checkpoint introduces fails closed
(`finding_risk_unobserved`), and replay may consume only a
FindingResolution ref the checkpoint itself exact-pins, so a later
resolution never rewrites accepted checkpoint history. The resume is an
IMMEDIATE successor authority_change checkpoint whose exact predecessor is
the needs_user/escalate finding_change checkpoint and whose newly pinned
valid FindingResolution refs cover every risk that predecessor introduced
left unadjudicated; unrelated, partial, or stale resolution pins fail
closed in both the trigger proof and the deterministic replay.

### Budget assessment consumer closure

An unverified budget measurement closes only through the one-way chain
`C_pending -> independent GateEvaluation -> immediate successor C_reviewed`.
The GateRequirement selector must explicitly require budget assessment, and
the evaluation's `budget_assessment_result` exact-binds the assessed
checkpoint ref+digest, the COMPLETE assessed binding digest, lead_control,
scope, and both metric statuses (exact-match, at least one unverified) with
the typed `accepted|rejected` outcome; only the unverified metric(s) consume
the accepted/rejected assessment and ref. The successor consumes it with the
exact review_status/disposition mapping; self/circular,
non-immediate-predecessor, cross-binding, mismatched outcome/scope/status,
ordinary evaluations, missing selectors, and non-independent evaluators all
fail closed; an accepted review unlocks the unverified lead_adjustment path
while pending remains fail-closed. Freshness is the
`budget_review_subject_projection` compared byte-for-byte while excluding
ONLY review_status, lead_disposition, and review_gate_evaluation_ref — the
complete binding digest is never a freshness basis. The ONE typed exception
(Slice 4 amendment, Slice 2 current/inherited provenance unchanged): when
the assessed binding's adjustment source is `mode=current`, the consuming
successor may make exactly one deterministic `current->inherited` flip —
same adjustment_digest, `inherited_checkpoint_ref` exactly equal to the
assessed predecessor ref, every other non-review byte equal; any wrong
ref/digest/mode/ceilings/source fails closed. Only this exact accepted
consumption replays as the eligible dispatch decision; rejected replays
frozen for deterministic replan.

### AggregateOutcome deterministic projection

Slice 5 increment 1 adds one pure derived seam:
`AggregateOutcome.derive(bundle, task_revision_id, validator:)`. It writes
nothing, is not an authoritative bundle collection or schema, and never
produces an outcome an agent or Lead can persist as a fact source.

The validated-input boundary is mechanically enforced: `derive` runs
`Validator#validate` on the bundle before projecting. Validation is the
single eligibility boundary — evaluator provenance and independence,
active-policy/authorization, resolution authority, and every unresolved ref
are enforced by the real Validator, never re-derived here. The ONLY tolerated
validation error is the historical stale-evaluation error, identified by a
shared explicit predicate (`ProjectionPrimitives.historical_stale_evaluation_error?`)
keyed on code `subject_stale` plus the exact path
`gate_evaluations.<id>.subject` — never message text. That error proves a
structurally complete create-only GateEvaluation no longer matches the
CURRENT canonical subject; ADR-005 keeps the accepted evaluation immutable,
later subject changes make it stale for closure while the artifact remains
stored, and `project_requirement` excludes it (status `missing`, never
`closed`). Every other error — including the sibling `subject_stale` paths
for stale GateRequirement digest (`.gate_requirement_content_digest`) and
stale active-policy authority (`.subject.task_revision_ref`), malformed or
incomplete subjects (`subject_incomplete`/shape errors), and all shape/
authority/provenance/independence/resolution errors — raises
`ContractError` (`aggregate_outcome_invalid`) and produces no projection, so
no cache identity can claim validity for an invalid fact set.

The output is a canonical hash: exact task/policy refs, gate results sorted
by `gate_requirement_id`, sorted unresolved blocking/adjudication-required
finding refs, a `closed` boolean, a complete sorted source ID+digest
manifest, `source_digest`, and `content_digest`. Gate statuses are the
minimal enum `passed | not_passed | missing | ambiguous`.

A GateEvaluation participates only when its `gate_requirement_content_digest`
is current and `EvaluationSubject.select` recomputes byte-identical for the
active TaskRevision, repository snapshot, and CodeSurface (budget gates
include the canonical `budget_review_subject_projection` identity). The
current evaluation is selected structurally through supersedes lineage tips:
exactly one compatible current-subject tip may decide a gate; zero is
missing; multiple or forked tips are ambiguous and never close. No timestamp
or array order participates. `closed` is true iff every TaskRevision-owned
GateRequirement has a unique current passing evaluation and there are no
unresolved policy-blocking findings or unadjudicated
newly_discovered_risk findings; a later pass never erases an unresolved
blocking Finding. Resolutions count only through the existing append-only
lineage semantics, and `hardening_opportunity` is nonblocking.

The source manifest covers every validated bundle source — whole-bundle
over-invalidation by design, since the eligibility boundary consumes the
entire bundle: protocol root (exactly once), authority assertions,
authorization records, policy/task/gate/work-unit/attempt/evidence/
evaluation/finding/resolution records, agent instances (runtime identity),
lead sessions, control registries, checkpoints, rule-resolution artifacts,
change theses, repository snapshot, and CodeSurface. Every source identity
appears exactly once, with no duplicate (kind, id); documents without a
stored content digest get their canonical content digest recomputed.
`source_digest` is therefore a complete future deletable-cache key: repeat
recomputation is byte-identical and any change to any validated bundle
source changes the projection. No persisted cache, LeadControl transition,
role context projection, RelationshipView, audit layer, or budget digest/
two-lineage projection exists in this increment.

Shared derivation (`finding_disposition`, `finding_lineage`, supersedes-tip
analysis, canonical budget-subject identity) lives in
`ProjectionPrimitives`; the Validator delegates to the same functions, so
projection and validation cannot drift into two subtly different truths.

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
| class/use mismatch | close a requirement with a non-paired `verification_use` | pairing closure / `evidence_requirement_pair_invalid` |
| incompatible claim kind | point permanent evidence at a report claim, or audit/acceptance evidence at a verification claim | kind closure / `evidence_reference_invalid` |
| reviewer/tester rule reuse | assign an implementation resolution to a reviewer attempt with dependent refs consistently resealed | identity binding / `rule_resolution_identity_mismatch` |
| forged blocking field | write `blocking` true/false on a typed Finding | contract shape / `contract_shape_invalid` |
| stale budget projection | consume a budget review whose binding drifted outside the three review-result fields | projection freshness / `budget_assessment_invalid` |
| forged adjustment transition | flip the assessed current-mode source to inherited with a wrong ref/digest/mode or drifted ceilings | typed transition / `budget_assessment_invalid` |
| forged risk continuation | store blocked/continue on a finding_change checkpoint introducing an unadjudicated risk | decision replay / `checkpoint_decision_replay_invalid` |
| unpinned risk | record an unadjudicated risk with no introducing checkpoint provenance | risk closure / `finding_risk_unobserved` |
| masked escalation | store a blocked/frozen decision with blocked/warning assessments over an introduced risk | decision replay precedence / `checkpoint_decision_replay_invalid` |
| unpinned adjudication | let a later resolution adjudicate a risk the checkpoint did not pin | decision replay / `checkpoint_decision_replay_invalid` |
| rule bytes drift | submit an artifact rebuilt from changed rule bytes for the old Attempt | assigned/submitted identity / `rule_resolution_identity_mismatch` |
| identity field drift | shift attempt/role/agent/context inside a stored canonical identity | identity binding / `rule_resolution_identity_mismatch` |
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
| Dispatch observation | the exact AttemptCreated observation checkpoint is the immediate accepted successor of the Attempt's dispatch checkpoint, reconciles on attempt_created, and pins that exact AttemptCreated event; intervening checkpoints and non-tip dispatch refs fail closed; every dispatch checkpoint pins exactly one proposed ChangeThesis and one RuleResolution in its supporting provenance, the plan/closure digests derive from them, and the AttemptCreated assignment must exact match — a generic nil basis is never a legal dispatch | LeadControl |
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

## Slice 2 increment 4 addendum: anomaly/fuse/budget machinery

Completes Slice 2 (ADR-003 decision 7/9, ADR-004 decision 7, ADR-005
conditions 13-17, ADR-006 Amendment): policy-pinned wall-clock fallback,
canonical failure/finding fingerprint identity with separated supporting
provenance and prior chain, the provider-verified `task.retry.override`,
the two-layer effective budget bindings with verified/unverified
measurements and adjust/override consume|inherit, the one-way
`budget_adjustment_digest -> effective_budget_bindings ->
effective_verification_plan_digest -> closure_basis_digest` chain, and the
bounded runner's four mutually exclusive stop states. Model-level
accepted-final-state closure only; compare-and-append/store atomicity
closes at Slice 6 activation.

New frozen shapes:

```yaml
project_policy_revision:
  orchestration_policy:
    wall_clock_fallback: { interval_seconds, upper_bound_seconds }  # finite, non-zero
    test_budget: { work_unit_lineage: TestBudgetScope, task_lineage: TestBudgetScope }
  TestBudgetScope: { default_test_count, default_test_code_lines,
                     lead_ceiling_test_count, lead_ceiling_test_code_lines }

authorization_record:                       # provider-verified, create-only, pre-existing
  action: task.retry.override               # + retry_override_envelope (canonical scope digest:
    project, TaskRevision ref, WorkUnit ref, fingerprint, ordered prior Attempt chain,
    authorizing checkpoint ref, lead_control_id)
  action: test.budget.override              # + budget_override_envelope (scope digest:
    budget_scope_type, policy, project, TaskRevision, WorkUnit, authorizing predecessor
    checkpoint ref + predecessor binding digest, absolute ceilings, lead_control_id)
  action: control.fallback.authorize        # + fallback_envelope (project, policy, control,
    finite interval + upper bound)

lead_checkpoint:
  effective_budget_bindings: [binding_work_unit_lineage, binding_task_lineage]  # fixed order
  budget_adjustment_digest: sha256 | absent  # iff the typed test_budget_adjust payload exists
  test_budget_adjust: payload | absent       # never carries the checkpoint itself or measurements
  effective_verification_plan_digest: sha256 # derived, always pinned
  closure_basis_digest: sha256               # frozen dispatch-time refs, always pinned
  wall_clock_fallback: { source_kind: policy|authorization_record, deadline, source_ref } | absent
  fingerprint_identity_basis: { canonicalization_version: orbit-fingerprint-v1, scope,
    category: finding|test|rule|check, failure_code, finding_ref | stable_signal_identity }
  fingerprint: sha256                       # recomputable from the identity basis only
  fingerprint_supporting_provenance: { terminal_attempt_ref, outcome_refs,
    authoring_checkpoint_ref, prior_attempt_chain }  # never hashed
  retry_override_ref: authorization_record ref | absent   # consumed at the third dispatch
```

New invariant families:

| Family | Closed invariant | Single owner/seam |
| --- | --- | --- |
| Wall-clock fallback | a checkpoint awaiting `checkpoint_due` pins the exact active policy orchestration fallback (finite non-zero interval/upper bound) or a policy-authorized `control.fallback.authorize` record; the schedule basis is the exact Attempt event already pinned by the schedule checkpoint or a strict same-control lineage ancestor (future/side/unobserved events fail closed); the deadline is never free text: it must equal the basis event's provider-recorded `recorded_at` plus the exact source interval; the timer occurrence is proven only by a provider-verified `control.checkpoint_due.observe` AuthorityAssertion whose canonical scope exact binds project/active policy/control/scheduled checkpoint ref+digest/deadline/observed_at, with asserted_at and receipt issued_at equal to observed_at >= deadline and the active policy trusting the grant — an ordinary lifecycle event never proves the timer fired; `checkpoint_due` comes only from the exact scheduled lineage predecessor | LeadControl |
| Fingerprint identity | the ONLY fingerprint hash input is the canonical identity basis (known canonicalization version, TaskRevision/WorkUnit scope, typed category/code, stable Finding identity OR stable test/rule/check identity + signal subject + normalized failure code); fingerprint fields appear only on a failed terminal round and vice versa; the digest is byte-recomputable; the scope exact-resolves the pinned failure attempt's task/work-unit digests; the typed `failure_code` must byte-equal the trusted terminal `failure_signal.normalized_failure_code`, and a non-Finding stable signal identity must byte-equal the trusted `failure_signal` recorded on the pinned AttemptFailed/AttemptBlocked event itself (provider-verified lifecycle receipt) — changing only the code or any signal string of a real failure can never mint a new fingerprint; the trusted `failure_signal` is REQUIRED on every AttemptFailed/AttemptBlocked terminal event (an immutable failure without its only fingerprint anchor is rejected at the schema); attempt/checkpoint/session/AgentInstance/outcome identities, wording, order and paths never enter the hash | LeadControl |
| Supporting provenance | provenance pins the exact terminal failure event, resolvable outcome refs supporting the basis (finding occurrences include the stable Finding ref), and the exact dispatch checkpoint of the failed Attempt as the non-circular authoring ref; the ordered prior attempt chain byte-equals the same-fingerprint occurrences walked across the accepted lineage (including exact transfer jumps, skipping the current occurrence and counting each terminal event identity exactly once regardless of intermediate re-pins) | LeadControl |
| Retry override | the third same-fingerprint dispatch requires a provider-verified create-only `task.retry.override` record whose canonical scope exact binds project/TaskRevision/WorkUnit/fingerprint/ordered prior chain/authorizing checkpoint (the second-failure checkpoint)/control; consumption binds the exact ACTIVE policy the consuming checkpoint was written under (record policy == active policy + active policy grant trusted), so records issued under old or revoked policies fail closed after rotation; the record is pre-existing, consumed by exactly one checkpoint, and never appears without a pending third dispatch; a needs_user checkpoint proves the absence of authority | LeadControl |
| Effective budget bindings | exactly two bindings in fixed `work_unit_lineage`/`task_lineage` order, each deterministically derivable from the authoritative facts with one exclusive source (`policy_default`, `lead_adjustment` current/inherited, `user_override` consume/inherit); the WorkUnit ref binds ONLY the `work_unit_lineage` scope — `task_lineage` overrides carry the canonical null and never relax the WorkUnit-lineage binding (the two layers derive independently, cross-scope replay fails closed); the adjust payload binds the exact predecessor checkpoint ref + predecessor binding digest + old/new absolute ceilings inside the policy lead ceiling and canonicalizes to `budget_adjustment_digest` (no checkpoint self-reference, no measurement tuple); an override record exact binds project/policy/task/unit/scope/authorizing predecessor/binding/ceilings/control, is consumed once, and inherits only along the continuous accepted lineage with the exact origin ref | LeadControl |
| Measurements | `test_count`/`test_code_lines` fixed key set, each `verified` (usage >= 0 + a provider-verified `test.measurement.attest` AuthorityAssertion whose canonical scope exact binds project/active policy/TaskRevision/scope-appropriate WorkUnit ref (exact for work_unit_lineage, canonical null for task_lineage)/metric identity/usage/repository snapshot ref+digest, one assertion per metric) or `unverified` (canonical nulls + typed `unverified_assessment` with the exact pending mapping); a bare snapshot reference or a self-reported usage can never claim verified; mechanical within/over-budget derivation exists ONLY for verified metrics; default dispatch may proceed unverified/pending, but a `lead_adjustment` in effect for a scope (current or inherited) must carry provider-attested verified measurements — pending adjustment fails closed in Slice 2; accepted/rejected review states depend on the Slice 4 independent budget assessment consumer and fail closed | LeadControl |
| One-way digest chain | `budget_adjustment_digest` (iff present) -> complete ordered `effective_budget_bindings` -> `effective_verification_plan_digest` -> `closure_basis_digest`, each recomputable byte-identical; the enclosing checkpoint identity never enters any preimage; no plan truth object exists; the closure basis freezes dispatch-time TaskRevision/WorkUnit/thesis/rule refs plus the plan digest (a terminal-dispatch checkpoint uses the proposed successor basis, an observation the pinned Attempt's actual assignment) | LeadControl |
| Stop states | each reconcile yields exactly one of `completed/blocked/frozen/needs_user`; hard overruns needing user authority (verified budget overrun, third same-fingerprint retry without override) are `needs_user`; Lead-replannable control anomalies (zero-delivery fuses, unprovable identity) are `frozen`; recovery re-runs the tip's stored pipeline so `needs_user`/`frozen` never thaw implicitly; `checkpoint_due` and a resumed `authority_change` dispatch re-run the same dispatch authorization path | LeadControl |

Mutation matrix additions (all cross the public `Validator#validate` or
`LeadControl.reconcile` seams):

| Mutation class | Representative mutation | Expected invariant/error |
| --- | --- | --- |
| third retry without override | second same-fingerprint failure checkpoint with a forged dispatch decision | `needs_user` + `checkpoint_decision_replay_invalid` |
| forged fingerprint | recorded fingerprint diverges from the identity basis | `checkpoint_fingerprint_invalid` |
| prior chain gap | second occurrence provenance chain emptied | `checkpoint_fingerprint_invalid` |
| fingerprint on non-failure | fingerprint fields on an observation checkpoint | `checkpoint_fingerprint_invalid` |
| failure without fingerprint | failed terminal round without identity/provenance | `checkpoint_fingerprint_invalid` |
| fallback without pin | awaiting checkpoint_due with no wall_clock_fallback | `checkpoint_fallback_invalid` |
| unscheduled timer | checkpoint_due reconcile without predecessor schedule | `checkpoint_trigger_invalid` |
| stale fallback digest | fallback pin diverges from the active policy digest | `checkpoint_fallback_invalid` |
| drifted deadline | deadline does not equal the trusted schedule basis recorded_at plus the exact interval | `checkpoint_fallback_invalid` |
| unrelated basis | schedule basis event not pinned by the schedule checkpoint or a strict same-control ancestor | `checkpoint_fallback_invalid` |
| early due | checkpoint_due observation assertion observed_at before the scheduled deadline | `checkpoint_trigger_invalid` |
| lifecycle-as-due | ordinary lifecycle event ref used as the timer due receipt | schema `contract_shape_invalid` |
| usage tamper | measurement usage diverges from the attested usage scope | `checkpoint_budget_invalid` |
| invented signal | fingerprint stable signal strings diverge from the trusted terminal failure_signal | `checkpoint_fingerprint_invalid` |
| invented failure code | fingerprint failure_code diverges from the trusted terminal failure_signal.normalized_failure_code (compound bypass: code change + recompute + cleared chain + dropped override + successor_before) | `checkpoint_fingerprint_invalid` |
| signalless terminal failure | signed AttemptFailed/AttemptBlocked without the required failure_signal (unobserved event included) | schema `contract_shape_invalid` |
| dispatch without proposal | dispatch checkpoint with zero change_thesis or rule_resolution refs | `checkpoint_proposal_missing` |
| stale-policy retry | retry override record policy diverges from the consuming checkpoint active policy | `checkpoint_retry_override_invalid` |
| pending adjustment | lead_adjustment binding with unverified pending measurements | `checkpoint_budget_invalid` |
| re-pinned occurrence | intermediate checkpoint re-pins a historical failure event | valid (counted once) |
| extra typed envelope | typed AuthorizationRecord action with a second typed envelope | schema `contract_shape_invalid` |
| measurement scope replay | task_lineage metric references the work_unit_lineage attestation | `checkpoint_budget_invalid` |
| task override null | task_lineage override carries a WorkUnit ref | schema/`checkpoint_budget_invalid` |
| cross-scope replay | work_unit binding consumes the task_lineage override record | `checkpoint_budget_invalid` |
| verified overrun | verified usage above the effective ceiling, no override | `needs_user` + replay invalid |
| overrun past override | verified usage above even the override ceiling | `needs_user` |
| second consume | a second checkpoint consumes the same override record | `checkpoint_budget_invalid` |
| inherit without origin | override inherit with a nil origin ref | `checkpoint_budget_invalid` |
| adjustment over ceiling | adjust payload `new` above the policy lead ceiling | `checkpoint_budget_invalid` |
| forged adjustment digest | `budget_adjustment_digest` does not match the payload | `checkpoint_budget_invalid` |
| absent-adjustment digest | digest pinned without any payload | `checkpoint_budget_invalid` |
| unverified with usage | unverified measurement carries a numeric usage | `checkpoint_budget_invalid` |
| pending with review ref | pending assessment carries a review ref | `checkpoint_budget_invalid` |
| Slice 4 review state | accepted/rejected assessment before the budget GateEvaluation consumer | `checkpoint_budget_invalid` |
| plan/basis mutation | stored effective_verification_plan_digest / closure_basis_digest diverges | `checkpoint_digest_invalid` |
| binding order | two bindings swapped | `checkpoint_budget_invalid` |

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

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

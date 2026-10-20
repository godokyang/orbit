/**
 * Orbit task record domain types (schema version 1).
 *
 * This format is new for the TypeScript core. It intentionally does not read or
 * migrate OMP-era records: ADR-015 revision 8 drops historical compatibility.
 */

export const TASK_SCHEMA_VERSION = 1 as const

export type TaskStatus =
  | 'running'
  | 'paused'
  | 'needs_user'
  | 'complete'
  | 'failed'
  | 'stop_unconfirmed'

/** Statuses that mean execution has actually been stopped and confirmed. */
export const CONFIRMED_STOP_STATUSES: readonly TaskStatus[] = [
  'paused',
  'needs_user',
  'complete',
  'failed',
]

export type StopReason = 'user' | 'complete' | 'failure' | 'needs_user'

export interface ModelIdentity {
  provider: string
  model: string
  reasoning?: string
}

export interface RequirementSource {
  kind: 'user-message' | 'explicit-text' | 'continuation'
  /** Native user message id when the instruction came from a user turn. */
  messageId?: string
  sessionId?: string
  /** True only when the bytes are the user's original message. */
  verbatim: boolean
  at: string
}

export interface RequirementVersion {
  /** 1-based, monotonically increasing. */
  version: number
  text: string
  sha256: string
  source: RequirementSource
  recordedAt: string
}

export interface WorkspaceRebind {
  from: string
  to: string
  at: string
  reason: string
}

export interface WorkspaceBinding {
  /** Authorized project root: owns the task record and the root session. */
  projectRoot: string
  /** Directory whose artifacts are checked and whose snapshot is fixed. */
  artifactRoot: string
  realPath?: string
  gitCommonDir?: string
  worktree?: string
  head?: string
  boundAt: string
  history: WorkspaceRebind[]
}

export interface RootBinding {
  sessionId: string
  agentId?: string
  model?: ModelIdentity
}

export interface StopEvidence {
  [key: string]: boolean | undefined
}

export interface StopConfirmation {
  confirmed: boolean
  at: string
  evidence: Record<string, boolean>
  missing: string[]
  diagnostics?: string
}

export interface StopRecord {
  requestedAt: string
  reason: StopReason
  /** The fence is permanent once armed; it is never released for this task. */
  fence: 'armed'
  confirmation?: StopConfirmation
}

export interface FinalizationNotice {
  id: string
  at: string
  checkNumber: number
  inputVersion: number
  inputDigest: string
  artifactDigest: string
  artifactRoot: string
}

export interface CompletionRecord {
  at: string
  checkNumber: number
  inputVersion: number
  inputDigest: string
  artifactDigest: string
  artifactRoot: string
  noticeId: string
}

export interface CompletionInvalidation {
  code: string
  message: string
  at: string
}

/** Persisted in state.json. */
export interface TaskState {
  schemaVersion: typeof TASK_SCHEMA_VERSION
  id: string
  createdAt: string
  updatedAt: string
  status: TaskStatus
  projectRoot: string
  workspace: WorkspaceBinding
  root: RootBinding
  input: {
    versions: RequirementVersion[]
  }
  checks: {
    nextNumber: number
    inFlight: number | null
  }
  stop?: StopRecord
  /** Frozen strict model authorization for this task, when the user supplied one. */
  authorization?: {
    allowedModels: string[]
  }
  /** Set when this task continues a confirmed-stopped predecessor. */
  continuation?: {
    previousTaskId: string
    previousTaskDir: string
    previousStatus: TaskStatus
    sourceMessageId?: string
    at: string
  }
  /** Root declarations appended after takeover, in submission order. */
  priorScopeDeclarations?: Array<{
    text: string
    reason?: string
    at: string
    source: 'root-declaration'
  }>
  /** Set when supervision starts on work the Root already executed. */
  takeover?: {
    reason: string
    priorScope?: string
    messageId?: string
    snapshot: { digest: string; files: number; bytes: number; at: string }
  }
  finalization?: FinalizationNotice
  completion?: CompletionRecord
  completionInvalidation?: CompletionInvalidation
  /** Last appended event sequence, kept for status/export convenience. */
  eventSeq: number
}

export type MemberStatus =
  | 'registered'
  | 'completed'
  | 'failed'
  | 'refused'
  | 'rejected'
  | 'stopped'
  | 'unknown'

export interface MemberRecord {
  /** Native host agent/session identity; never a display name. */
  id: string
  requestedName: string
  workUnitId: string
  inputVersion: number
  artifactRoot: string
  model?: ModelIdentity
  toolCallId?: string
  status: MemberStatus
  registeredAt: string
  settledAt?: string
  note?: string
}

export interface MembersFile {
  schemaVersion: typeof TASK_SCHEMA_VERSION
  taskId: string
  members: MemberRecord[]
}

export type WorkUnitStatus =
  | 'declared'
  | 'bound'
  | 'finished'
  | 'accepted'
  | 'rejected'
  | 'failed'

export type ExecutionTarget = 'root' | 'delegate'

export interface WorkUnitScope {
  /** Bash sandbox paths; not a whitelist for native file tools. */
  allowedPaths: string[]
  /** Exact, verbatim allowed commands; never prefixes. */
  allowedCommands: string[]
}

export interface DispatchAttempt {
  attempt: number
  memberId: string
  model?: ModelIdentity
  toolCallId?: string
  boundAt: string
  finishedAt?: string
  outcome?: 'completed' | 'failed' | 'refused' | 'rejected'
  summary?: string
}

export interface WorkUnitRecord {
  id: string
  createdAt: string
  updatedAt: string
  goal: string
  requirementRefs: string[]
  context?: string
  scope: WorkUnitScope
  acceptance: string
  dependencies: string[]
  escalation?: string
  execution: ExecutionTarget
  status: WorkUnitStatus
  /** Input and artifact versions captured at declaration time. */
  inputVersion: number
  artifactRoot: string
  attempts: DispatchAttempt[]
  result?: {
    outcome: 'completed' | 'failed' | 'refused' | 'rejected'
    summary: string
    at: string
  }
  acceptedAt?: string
  rejectedAt?: string
  rejectionReason?: string
}

export interface WorkUnitsFile {
  schemaVersion: typeof TASK_SCHEMA_VERSION
  taskId: string
  units: WorkUnitRecord[]
}

export type CheckRole = 'reviewer' | 'adjudicator'
export type CheckKind = 'artifact' | 'process'
export type CheckTrigger = 'manual' | 'auto' | 'ruling' | 'continuation'
export type CheckStatus =
  | 'in_flight'
  | 'completed'
  | 'failed'
  | 'stale'
  | 'abandoned'

export type StaleReason = 'artifact' | 'input' | 'host' | 'workspace' | 'dispute'

export interface CheckFailure {
  kind: string
  message: string
  at: string
}

export interface FindingBinding {
  inputDigest: string
  artifactRoot: string
  artifactDigest: string
  requirement: string
  evidence: string
  action: string
}

export interface FindingRecord {
  id: string
  requirement: string
  evidence: string
  action: string
  status: 'open' | 'resolved'
  firstSeenCheck: number
  lastSeenCheck: number
  /** Number of subsequent reports ignored because all six bindings were unchanged. */
  repeats: number
  binding: FindingBinding
  resolvedByCheck?: number
  resolvedAt?: string
  /** How a resolved finding was closed; absent on historical check-resolved rows. */
  resolution?: 'check' | 'ruling'
}

export interface FindingsFile {
  schemaVersion: typeof TASK_SCHEMA_VERSION
  taskId: string
  findings: FindingRecord[]
}

export type DisputeStatus = 'pending' | 'adopted' | 'upheld'

export interface DisputeRecord {
  id: string
  findingId: string
  reason: string
  status: DisputeStatus
  openedAt: string
  ruling?: {
    decision: 'adopt' | 'uphold'
    reason: string
    at: string
  }
}

export interface DisputesFile {
  schemaVersion: typeof TASK_SCHEMA_VERSION
  taskId: string
  disputes: DisputeRecord[]
}

export interface CoverageItem {
  requirement: string
  scope: 'delivery' | 'lifecycle'
  status: 'verified' | 'unverified'
  evidence: string
  gap_kind?: 'not_checked' | 'evidence_missing' | 'defect'
  ref?: string
}

export interface Coverage {
  complete: boolean
  items: CoverageItem[]
}

export interface CoverageRecord {
  checkNumber: number
  role: CheckRole
  kind: CheckKind
  coverage: Coverage
  inputVersion: number
  inputDigest: string
  artifactDigest: string
  artifactRoot: string
  recordedAt: string
  stale?: { reason: StaleReason; at: string }
}

export interface CoverageFile {
  schemaVersion: typeof TASK_SCHEMA_VERSION
  taskId: string
  records: CoverageRecord[]
}

export interface CheckResult {
  verdict: 'continue' | 'correct' | 'pause' | 'complete' | 'needs_user'
  reason: string
  findings: Array<{
    id: string
    requirement: string
    evidence: string
    action: string
  }>
  resolvedIds: string[]
  nextCheckSeconds: number
  delivery: { ready: boolean; reason: string }
  coverage?: Coverage
}

export interface CheckRecord {
  schemaVersion: typeof TASK_SCHEMA_VERSION
  taskId: string
  number: number
  role: CheckRole
  kind: CheckKind
  trigger: CheckTrigger
  status: CheckStatus
  inputVersion: number
  inputDigest: string
  artifactDigest: string
  artifactRoot: string
  /** Fixed checker copy captured for this check, when one was taken. */
  snapshotDir?: string
  requestedAt: string
  startedAt?: string
  finishedAt?: string
  model?: ModelIdentity
  result?: CheckResult
  failure?: CheckFailure
  stale?: { reason: StaleReason; at: string; detail?: string }
}

export interface TaskEvent {
  seq: number
  at: string
  type: string
  data?: unknown
}

export interface CompletionCheckInput {
  artifactDigest: string
  now?: string
}

export interface CompletionRejection {
  ok: false
  code:
    | 'not_running'
    | 'stop_pending'
    | 'no_finalization_notice'
    | 'stale_input'
    | 'stale_artifact'
    | 'stale_workspace'
    | 'open_findings'
    | 'unsettled_members'
    | 'check_in_flight'
    | 'coverage_unverified'
    | 'membersfile_unreadable'
  message: string
  nextAction: string
}

export interface CompletionAcceptance {
  ok: true
}

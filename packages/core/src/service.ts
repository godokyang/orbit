import { OrbitError } from './errors.js'
import { Mutex } from './mutex.js'
import { newId, sha256Hex } from './ids.js'
import { parseCheckResult } from './check-result.js'
import { TaskStore } from './store.js'
import type {
  CheckKind,
  CheckRecord,
  CheckResult,
  CheckRole,
  CheckTrigger,
  CompletionAcceptance,
  CompletionRejection,
  CoverageFile,
  DisputeRecord,
  DisputesFile,
  CoverageRecord,
  DispatchAttempt,
  FindingRecord,
  FindingsFile,
  MemberRecord,
  MemberStatus,
  MembersFile,
  ModelIdentity,
  RequirementSource,
  RequirementVersion,
  TaskState,
  TaskStatus,
  WorkUnitRecord,
  WorkUnitsFile,
  WorkspaceBinding,
  StopReason,
} from './types.js'

export const STOP_EVIDENCE_KEYS = [
  'fence_persisted',
  'root_idle',
  'members_stopped',
  'checks_settled',
] as const

export type StopEvidenceKey = (typeof STOP_EVIDENCE_KEYS)[number]

export interface StartTaskOptions {
  projectRoot: string
  artifactRoot?: string
  rootSessionId: string
  rootAgentId?: string
  rootModel?: ModelIdentity
  instruction: string
  source?: RequirementSource
  workspace?: Partial<WorkspaceBinding>
  allowedModels?: string[]
  /** Versions copied from a confirmed-stopped predecessor (resume only). */
  priorVersions?: RequirementVersion[]
  continuation?: TaskState['continuation']
  takeover?: TaskState['takeover']
  runtime?: TaskState['runtime']
  taskId?: string
  clock?: () => Date
}

export interface DeclareWorkUnitOptions {
  goal: string
  acceptance: string
  requirementRefs?: string[]
  context?: string
  scope?: { allowedPaths?: string[]; allowedCommands?: string[] }
  dependencies?: string[]
  escalation?: string
  execution?: 'root' | 'delegate'
  id?: string
}

export interface RegisterMemberOptions {
  id: string
  requestedName: string
  workUnitId: string
  model?: ModelIdentity
  toolCallId?: string
}

export interface FinishWorkUnitOptions {
  id: string
  outcome: 'completed' | 'failed' | 'refused' | 'rejected'
  summary: string
}

export interface RequestCheckOptions {
  role: CheckRole
  kind: CheckKind
  trigger: CheckTrigger
  artifactDigest: string
  model?: ModelIdentity
  snapshotDir?: string
}

export interface ConfirmStopOptions {
  evidence: Partial<Record<StopEvidenceKey, boolean>>
  artifactDigest: string
  diagnostics?: string
}

export function inputDigest(versions: RequirementVersion[]): string {
  return sha256Hex(versions.map((v) => `${v.version}\n${v.sha256}\n${v.text}`).join('\n---\n'))
}

function nonEmpty(value: string, field: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new OrbitError('invalid_input', `${field} must be a non-empty string`)
  }
  return value
}

function sameModel(a?: ModelIdentity, b?: ModelIdentity): boolean {
  return a?.provider === b?.provider && a?.model === b?.model && a?.reasoning === b?.reasoning
}

/**
 * Task operations. Reads flow through TaskStore; every mutation is serialized
 * by the service mutex so a stop fence cannot be bypassed by an interleaved
 * registration.
 */
export class TaskService {
  private readonly mutex = new Mutex()

  private constructor(readonly store: TaskStore) {}

  static async start(options: StartTaskOptions): Promise<{ service: TaskService; state: TaskState }> {
    const projectRoot = options.projectRoot
    const instruction = nonEmpty(options.instruction, 'instruction')
    const rootSessionId = nonEmpty(options.rootSessionId, 'rootSessionId')
    const clock = options.clock ?? (() => new Date())
    const now = clock().toISOString()
    const id = options.taskId ?? newId('task')
    const text = instruction
    const versions: RequirementVersion[] = (options.priorVersions ?? []).map((prior) => structuredClone(prior))
    const version: RequirementVersion = {
      version: versions.length + 1,
      text,
      sha256: sha256Hex(text),
      source: options.source ?? { kind: 'explicit-text', verbatim: true, at: now },
      recordedAt: now,
    }
    versions.push(version)
    const workspace: WorkspaceBinding = {
      projectRoot,
      artifactRoot: options.workspace?.artifactRoot ?? options.artifactRoot ?? projectRoot,
      boundAt: now,
      history: [],
      ...options.workspace,
      ...(options.workspace?.boundAt === undefined ? { boundAt: now } : {}),
    }
    const state: TaskState = {
      schemaVersion: 1,
      id,
      createdAt: now,
      updatedAt: now,
      status: 'running',
      projectRoot,
      workspace,
      root: {
        sessionId: rootSessionId,
        ...(options.rootAgentId === undefined ? {} : { agentId: options.rootAgentId }),
        ...(options.rootModel === undefined ? {} : { model: options.rootModel }),
      },
      input: { versions },
      checks: { nextNumber: 1, inFlight: null },
      ...(options.allowedModels === undefined || options.allowedModels.length === 0
        ? {}
        : { authorization: { allowedModels: [...options.allowedModels] } }),
      ...(options.continuation === undefined ? {} : { continuation: options.continuation }),
      ...(options.takeover === undefined ? {} : { takeover: options.takeover }),
      ...(options.runtime === undefined ? {} : { runtime: options.runtime }),
      eventSeq: 0,
    }
    const store = await TaskStore.create(
      projectRoot,
      id,
      {
        state,
        members: { schemaVersion: 1, taskId: id, members: [] },
        workUnits: { schemaVersion: 1, taskId: id, units: [] },
        findings: { schemaVersion: 1, taskId: id, findings: [] },
        disputes: { schemaVersion: 1, taskId: id, disputes: [] },
        coverage: { schemaVersion: 1, taskId: id, records: [] },
      },
      clock,
    )
    const reloaded = await store.readState()
    return { service: new TaskService(store), state: reloaded }
  }

  static async open(taskDir: string, clock?: () => Date): Promise<TaskService> {
    return new TaskService(await TaskStore.open(taskDir, clock))
  }

  /**
   * Start a new task from a confirmed-stopped paused/needs_user predecessor.
   * Copies the original requirements and effective amendments, appends the
   * continuation message as the new effective version, and leaves the old task
   * terminal and unchanged.
   */
  static async resumeFrom(
    previousTaskDir: string,
    options: StartTaskOptions & { instruction: string },
  ): Promise<{ service: TaskService; state: TaskState }> {
    const previous = await TaskService.open(previousTaskDir)
    const previousState = await previous.state()
    if (previousState.status !== 'paused' && previousState.status !== 'needs_user') {
      throw new OrbitError('invalid_state', `cannot resume a ${previousState.status} task`)
    }
    if (previousState.stop?.confirmation?.confirmed !== true) {
      throw new OrbitError('invalid_state', 'the predecessor has no confirmed stop')
    }
    if (previousState.projectRoot !== options.projectRoot) {
      throw new OrbitError('invalid_state', 'resume requires the same project root')
    }
    if (previousState.root.sessionId !== options.rootSessionId) {
      throw new OrbitError('invalid_state', 'resume requires the same Root session')
    }
    const continuation: TaskState['continuation'] = {
      previousTaskId: previousState.id,
      previousTaskDir: previous.store.dir,
      previousStatus: previousState.status,
      ...(options.source?.messageId === undefined ? {} : { sourceMessageId: options.source.messageId }),
      at: new Date().toISOString(),
    }
    const started = await TaskService.start({
      ...options,
      priorVersions: previousState.input.versions,
      continuation,
    })
    await started.service.store.appendEvent('continuation/started', {
      previousTaskId: previousState.id,
      previousStatus: previousState.status,
    })
    return started
  }

  async state(): Promise<TaskState> {
    return this.store.readState()
  }

  async currentInputDigest(): Promise<string> {
    const state = await this.store.readState()
    return inputDigest(state.input.versions)
  }

  private assertRunning(state: TaskState, operation: string): void {
    if (state.status !== 'running') {
      throw new OrbitError('invalid_state', `${operation}: task is ${state.status}, not running`)
    }
    if (state.stop !== undefined) {
      throw new OrbitError('stop_fenced', `${operation}: the stop fence is armed`)
    }
  }

  async amend(text: string, source: RequirementSource): Promise<TaskState> {
    nonEmpty(text, 'amendment text')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'amend')
      const version = state.input.versions.length + 1
      const requirement: RequirementVersion = {
        version,
        text,
        sha256: sha256Hex(text),
        source,
        recordedAt: this.store.now(),
      }
      const next = await this.store.updateState((draft) => {
        draft.input.versions.push(requirement)
      })
      await this.store.appendEvent('input/amended', { version, sha256: requirement.sha256, source })
      return next
    })
  }

  async declareWorkUnit(options: DeclareWorkUnitOptions): Promise<WorkUnitRecord> {
    const goal = nonEmpty(options.goal, 'goal')
    const acceptance = nonEmpty(options.acceptance, 'acceptance')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'declareWorkUnit')
      const existing = await this.store.workUnits()
      for (const dependency of options.dependencies ?? []) {
        const unit = existing.units.find((candidate) => candidate.id === dependency)
        if (unit === undefined) {
          throw new OrbitError('invalid_input', `unknown work-unit dependency: ${dependency}`)
        }
        if (unit.status !== 'accepted') {
          throw new OrbitError('invalid_state', `work-unit dependency ${dependency} is ${unit.status}, not accepted`)
        }
      }
      const now = this.store.now()
      const unit: WorkUnitRecord = {
        id: options.id ?? newId('wu'),
        createdAt: now,
        updatedAt: now,
        goal,
        requirementRefs: [...(options.requirementRefs ?? [])],
        ...(options.context === undefined ? {} : { context: options.context }),
        scope: {
          allowedPaths: [...(options.scope?.allowedPaths ?? [])],
          allowedCommands: [...(options.scope?.allowedCommands ?? [])],
        },
        acceptance,
        dependencies: [...(options.dependencies ?? [])],
        ...(options.escalation === undefined ? {} : { escalation: options.escalation }),
        execution: options.execution ?? 'delegate',
        status: 'declared',
        inputVersion: state.input.versions.length,
        artifactRoot: state.workspace.artifactRoot,
        attempts: [],
      }
      if (existing.units.some((candidate) => candidate.id === unit.id)) {
        throw new OrbitError('duplicate', `work unit already exists: ${unit.id}`)
      }
      await this.store.updateWorkUnits((file) => {
        file.units.push(unit)
      })
      await this.store.appendEvent('work-unit/declared', { id: unit.id, goal: unit.goal, execution: unit.execution })
      return unit
    })
  }

  async registerMember(options: RegisterMemberOptions): Promise<MemberRecord> {
    const id = nonEmpty(options.id, 'member id')
    const requestedName = nonEmpty(options.requestedName, 'requestedName')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'registerMember')
      const units = await this.store.workUnits()
      const unit = units.units.find((candidate) => candidate.id === options.workUnitId)
      if (unit === undefined) {
        throw new OrbitError('not_found', `unknown work unit: ${options.workUnitId}`)
      }
      if (unit.execution === 'root') {
        throw new OrbitError('invalid_state', 'a root-executed work unit cannot be dispatched to a member')
      }
      if (unit.inputVersion !== state.input.versions.length) {
        throw new OrbitError('stale_input', `work unit ${unit.id} was declared for input version ${unit.inputVersion}`)
      }
      if (unit.artifactRoot !== state.workspace.artifactRoot) {
        throw new OrbitError('stale_artifact', `work unit ${unit.id} was declared for ${unit.artifactRoot}`)
      }
      const members = await this.store.members()
      if (members.members.some((member) => member.id === id)) {
        throw new OrbitError('duplicate', `member already registered: ${id}`)
      }
      if (unit.status !== 'declared' && unit.status !== 'bound') {
        throw new OrbitError('invalid_state', `work unit ${unit.id} is ${unit.status}`)
      }
      const boundMember = unit.attempts.at(-1)?.memberId
      if (unit.status === 'bound' && boundMember !== id) {
        throw new OrbitError('invalid_state', `work unit ${unit.id} is already bound to ${boundMember}`)
      }
      const now = this.store.now()
      const member: MemberRecord = {
        id,
        requestedName,
        workUnitId: unit.id,
        inputVersion: unit.inputVersion,
        artifactRoot: unit.artifactRoot,
        status: 'registered',
        registeredAt: now,
        ...(options.model === undefined ? {} : { model: options.model }),
        ...(options.toolCallId === undefined ? {} : { toolCallId: options.toolCallId }),
      }
      await this.store.updateMembers((file) => {
        file.members.push(member)
      })
      await this.store.updateWorkUnits((file) => {
        const target = file.units.find((candidate) => candidate.id === unit.id)
        if (target === undefined) throw new OrbitError('not_found', `work unit vanished: ${unit.id}`)
        target.updatedAt = now
        target.status = 'bound'
        const attempt: DispatchAttempt = {
          attempt: target.attempts.length + 1,
          memberId: id,
          boundAt: now,
          ...(options.model === undefined ? {} : { model: options.model }),
          ...(options.toolCallId === undefined ? {} : { toolCallId: options.toolCallId }),
        }
        target.attempts.push(attempt)
      })
      await this.store.appendEvent('member/registered', {
        memberId: id,
        workUnitId: unit.id,
        toolCallId: options.toolCallId,
        model: options.model,
      })
      return member
    })
  }

  async settleMember(id: string, status: Exclude<MemberStatus, 'registered'>, note?: string): Promise<MemberRecord> {
    return this.mutex.run(async () => {
      const file = await this.store.members()
      const member = file.members.find((candidate) => candidate.id === id)
      if (member === undefined) throw new OrbitError('not_found', `unknown member: ${id}`)
      if (member.status !== 'registered') {
        throw new OrbitError('invalid_state', `member ${id} is already ${member.status}`)
      }
      const now = this.store.now()
      await this.store.updateMembers((current) => {
        const target = current.members.find((candidate) => candidate.id === id)
        if (target === undefined) throw new OrbitError('not_found', `unknown member: ${id}`)
        target.status = status
        target.settledAt = now
        if (note !== undefined) target.note = note
      })
      await this.store.appendEvent('member/settled', { memberId: id, status, note })
      return { ...member, status, settledAt: now, ...(note === undefined ? {} : { note }) }
    })
  }

  async finishWorkUnit(options: FinishWorkUnitOptions): Promise<WorkUnitRecord> {
    const summary = nonEmpty(options.summary, 'summary')
    return this.mutex.run(async () => {
      const units = await this.store.workUnits()
      const unit = units.units.find((candidate) => candidate.id === options.id)
      if (unit === undefined) throw new OrbitError('not_found', `unknown work unit: ${options.id}`)
      if (unit.status !== 'bound' && unit.status !== 'finished') {
        throw new OrbitError('invalid_state', `work unit ${unit.id} is ${unit.status}`)
      }
      const now = this.store.now()
      const attempt = unit.attempts.at(-1)
      if (attempt === undefined) throw new OrbitError('invalid_state', `work unit ${unit.id} has no dispatch attempt`)
      attempt.finishedAt = now
      attempt.outcome = options.outcome
      attempt.summary = summary
      const updated: WorkUnitRecord = {
        ...unit,
        status: 'finished',
        updatedAt: now,
        result: { outcome: options.outcome, summary, at: now },
      }
      await this.store.updateWorkUnits((file) => {
        const index = file.units.findIndex((candidate) => candidate.id === unit.id)
        file.units[index] = updated
      })
      await this.store.appendEvent('work-unit/finished', {
        id: unit.id,
        memberId: attempt.memberId,
        outcome: options.outcome,
      })
      return updated
    })
  }

  async acceptWorkUnit(id: string): Promise<WorkUnitRecord> {
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      const units = await this.store.workUnits()
      const unit = units.units.find((candidate) => candidate.id === id)
      if (unit === undefined) throw new OrbitError('not_found', `unknown work unit: ${id}`)
      if (unit.status !== 'finished') {
        throw new OrbitError('invalid_state', `work unit ${id} is ${unit.status}, not finished`)
      }
      if (unit.inputVersion !== state.input.versions.length) {
        throw new OrbitError('stale_input', `work unit ${id} belongs to input version ${unit.inputVersion}`)
      }
      if (unit.artifactRoot !== state.workspace.artifactRoot) {
        throw new OrbitError('stale_artifact', `work unit ${id} belongs to ${unit.artifactRoot}`)
      }
      const now = this.store.now()
      await this.store.updateWorkUnits((file) => {
        const target = file.units.find((candidate) => candidate.id === id)
        if (target === undefined) throw new OrbitError('not_found', `unknown work unit: ${id}`)
        target.status = 'accepted'
        target.acceptedAt = now
        target.updatedAt = now
      })
      await this.store.appendEvent('work-unit/accepted', { id })
      return { ...unit, status: 'accepted', acceptedAt: now, updatedAt: now }
    })
  }

  async rejectWorkUnit(id: string, reason: string): Promise<WorkUnitRecord> {
    nonEmpty(reason, 'rejection reason')
    return this.mutex.run(async () => {
      const units = await this.store.workUnits()
      const unit = units.units.find((candidate) => candidate.id === id)
      if (unit === undefined) throw new OrbitError('not_found', `unknown work unit: ${id}`)
      if (unit.status !== 'finished') {
        throw new OrbitError('invalid_state', `work unit ${id} is ${unit.status}, not finished`)
      }
      const now = this.store.now()
      await this.store.updateWorkUnits((file) => {
        const target = file.units.find((candidate) => candidate.id === id)
        if (target === undefined) throw new OrbitError('not_found', `unknown work unit: ${id}`)
        target.status = 'rejected'
        target.rejectedAt = now
        target.rejectionReason = reason
        target.updatedAt = now
      })
      await this.store.appendEvent('work-unit/rejected', { id, reason })
      return { ...unit, status: 'rejected', rejectedAt: now, rejectionReason: reason, updatedAt: now }
    })
  }

  /**
   * A running task whose recorded runtime instance is not the current host was
   * orphaned by that host's death. Mark it stop_unconfirmed with an explicit
   * missing runtime_gone evidence item; never keep claiming it runs.
   */
  async recoverOrphaned(instanceId: string, reason = 'host instance changed'): Promise<TaskState> {
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      if (state.status !== 'running') return state
      if (state.runtime?.instanceId === instanceId) return state
      const now = this.store.now()
      const next = await this.store.updateState((draft) => {
        draft.status = 'stop_unconfirmed'
        draft.stop = {
          requestedAt: now,
          reason: 'failure',
          fence: 'armed',
          confirmation: {
            confirmed: false,
            at: now,
            evidence: {},
            missing: ['runtime_gone'],
            diagnostics: `${reason}: recorded ${draft.runtime?.instanceId ?? 'unknown'} (pid ${draft.runtime?.pid ?? 'unknown'}), current ${instanceId}`,
          },
        }
      })
      await this.store.appendEvent('task/orphaned', {
        reason,
        previousRuntime: state.runtime,
        currentInstanceId: instanceId,
      })
      return next
    })
  }

  /**
   * Append a later Root declaration of the scope that predated supervision.
   * Only takeover tasks can carry these; identical text is idempotent.
   */
  async appendPriorScope(text: string, reason?: string): Promise<TaskState> {
    nonEmpty(text, 'prior scope declaration')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'appendPriorScope')
      if (state.takeover === undefined) {
        throw new OrbitError('invalid_state', 'prior scope declarations are only valid on a takeover task')
      }
      if (state.priorScopeDeclarations?.at(-1)?.text === text) return state
      const next = await this.store.updateState((draft) => {
        draft.priorScopeDeclarations ??= []
        draft.priorScopeDeclarations.push({
          text,
          ...(reason === undefined ? {} : { reason }),
          at: this.store.now(),
          source: 'root-declaration',
        })
      })
      await this.store.appendEvent('takeover/scope-declared', { text, reason })
      return next
    })
  }

  /** Open a Root dispute against one open finding. */
  async openDispute(findingId: string, reason: string): Promise<DisputeRecord> {
    nonEmpty(reason, 'dispute reason')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'openDispute')
      const findings = await this.store.findings()
      const finding = findings.findings.find((candidate) => candidate.id === findingId)
      if (finding === undefined) throw new OrbitError('not_found', `unknown finding: ${findingId}`)
      if (finding.status !== 'open') throw new OrbitError('invalid_state', `finding ${findingId} is already resolved`)
      const disputes = await this.store.disputes()
      if (disputes.disputes.some((candidate) => candidate.findingId === findingId && candidate.status === 'pending')) {
        throw new OrbitError('duplicate', `finding ${findingId} already has a pending dispute`)
      }
      const now = this.store.now()
      const dispute: DisputeRecord = {
        id: newId('dispute'),
        findingId,
        reason,
        status: 'pending',
        openedAt: now,
      }
      await this.store.updateDisputes((file) => {
        file.disputes.push(dispute)
      })
      await this.store.appendEvent('dispute/opened', { disputeId: dispute.id, findingId, reason })
      return dispute
    })
  }

  /** Record the Root's ruling on a pending dispute. Adopting resolves the finding. */
  async ruleDispute(id: string, decision: 'adopt' | 'uphold', reason: string): Promise<DisputeRecord> {
    nonEmpty(reason, 'ruling reason')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'ruleDispute')
      const disputes = await this.store.disputes()
      const dispute = disputes.disputes.find((candidate) => candidate.id === id)
      if (dispute === undefined) throw new OrbitError('not_found', `unknown dispute: ${id}`)
      if (dispute.status !== 'pending') throw new OrbitError('invalid_state', `dispute ${id} is ${dispute.status}`)
      const now = this.store.now()
      const updated: DisputeRecord = {
        ...dispute,
        status: decision === 'adopt' ? 'adopted' : 'upheld',
        ruling: { decision, reason, at: now },
      }
      await this.store.updateDisputes((file) => {
        const index = file.disputes.findIndex((candidate) => candidate.id === id)
        file.disputes[index] = updated
      })
      if (decision === 'adopt') {
        await this.store.updateFindings((file) => {
          const finding = file.findings.find((candidate) => candidate.id === dispute.findingId)
          if (finding === undefined) return
          finding.status = 'resolved'
          finding.resolvedAt = now
          finding.resolution = 'ruling'
        })
      }
      await this.store.appendEvent('dispute/ruled', { disputeId: id, findingId: dispute.findingId, decision, reason })
      return updated
    })
  }

  /**
   * Rebind the artifact root. Only the same real path or another worktree of
   * the same repository (matching git common dir) is accepted.
   */
  async rebindWorkspace(input: {
    artifactRoot: string
    reason: string
    realPath?: string
    gitCommonDir?: string
    worktree?: string
    head?: string
  }): Promise<TaskState> {
    nonEmpty(input.artifactRoot, 'artifactRoot')
    nonEmpty(input.reason, 'rebind reason')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'rebindWorkspace')
      const current = state.workspace
      const samePath = input.realPath !== undefined && current.realPath !== undefined && input.realPath === current.realPath
      const sameRepo =
        input.gitCommonDir !== undefined && current.gitCommonDir !== undefined && input.gitCommonDir === current.gitCommonDir
      if (!samePath && !sameRepo) {
        throw new OrbitError('invalid_state', 'rebind requires the same real path or another worktree of the same Git repository')
      }
      const now = this.store.now()
      const next = await this.store.updateState((draft) => {
        draft.workspace.history.push({
          from: draft.workspace.artifactRoot,
          to: input.artifactRoot,
          at: now,
          reason: input.reason,
        })
        draft.workspace.artifactRoot = input.artifactRoot
        if (input.realPath !== undefined) draft.workspace.realPath = input.realPath
        if (input.gitCommonDir !== undefined) draft.workspace.gitCommonDir = input.gitCommonDir
        if (input.worktree !== undefined) draft.workspace.worktree = input.worktree
        if (input.head !== undefined) draft.workspace.head = input.head
      })
      await this.store.appendEvent('workspace/rebound', { to: input.artifactRoot, reason: input.reason })
      return next
    })
  }

  async requestCheck(options: RequestCheckOptions): Promise<CheckRecord> {
    nonEmpty(options.artifactDigest, 'artifactDigest')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      this.assertRunning(state, 'requestCheck')
      if (state.checks.inFlight !== null) {
        throw new OrbitError('check_in_flight', `check ${state.checks.inFlight} is still in flight`)
      }
      const now = this.store.now()
      const number = state.checks.nextNumber
      const check: CheckRecord = {
        schemaVersion: 1,
        taskId: state.id,
        number,
        role: options.role,
        kind: options.kind,
        trigger: options.trigger,
        status: 'in_flight',
        inputVersion: state.input.versions.length,
        inputDigest: inputDigest(state.input.versions),
        artifactDigest: options.artifactDigest,
        artifactRoot: state.workspace.artifactRoot,
        ...(options.snapshotDir === undefined ? {} : { snapshotDir: options.snapshotDir }),
        requestedAt: now,
        startedAt: now,
        ...(options.model === undefined ? {} : { model: options.model }),
      }
      await this.store.writeCheck(check)
      await this.store.updateState((draft) => {
        draft.checks.nextNumber = number + 1
        draft.checks.inFlight = number
      })
      await this.store.appendEvent('check/requested', {
        number,
        role: check.role,
        kind: check.kind,
        trigger: check.trigger,
        artifactDigest: check.artifactDigest,
      })
      return check
    })
  }

  async recordCheckResult(number: number, rawResult: unknown): Promise<{ check: CheckRecord; finalization: boolean }> {
    const result = parseCheckResult(rawResult)
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      const check = await this.store.readCheck(number)
      if (check.status !== 'in_flight') {
        throw new OrbitError('invalid_state', `check ${number} is ${check.status}`)
      }
      const now = this.store.now()
      const findings = await this.applyFindings(check, result, now)
      let coverageRecord: CoverageRecord | undefined
      if (result.coverage !== undefined) {
        coverageRecord = {
          checkNumber: number,
          role: check.role,
          kind: check.kind,
          coverage: result.coverage,
          inputVersion: check.inputVersion,
          inputDigest: check.inputDigest,
          artifactDigest: check.artifactDigest,
          artifactRoot: check.artifactRoot,
          recordedAt: now,
        }
        await this.store.updateCoverage((file) => {
          file.records.push(coverageRecord as CoverageRecord)
        })
      }

      const completed: CheckRecord = {
        ...check,
        status: 'completed',
        finishedAt: now,
        result,
      }
      await this.store.writeCheck(completed)
      await this.store.updateState((draft) => {
        if (draft.checks.inFlight === number) draft.checks.inFlight = null
      })

      const qualifying =
        check.trigger === 'manual' &&
        check.role === 'reviewer' &&
        check.kind === 'artifact' &&
        result.verdict === 'complete' &&
        result.delivery.ready &&
        result.coverage !== undefined &&
        result.coverage.complete &&
        result.coverage.items.some((item) => item.scope === 'delivery') &&
        result.coverage.items.filter((item) => item.scope === 'delivery').every((item) => item.status === 'verified') &&
        findings.findings.every((finding) => finding.status !== 'open')

      let finalization = false
      if (qualifying) {
        const notice = {
          id: newId('finalization'),
          at: now,
          checkNumber: number,
          inputVersion: check.inputVersion,
          inputDigest: check.inputDigest,
          artifactDigest: check.artifactDigest,
          artifactRoot: check.artifactRoot,
        }
        await this.store.updateState((draft) => {
          draft.finalization = notice
        })
        finalization = true
        await this.store.appendEvent('finalization/notice', { number, ...notice })
      }

      await this.store.appendEvent('check/completed', {
        number,
        verdict: result.verdict,
        ready: result.delivery.ready,
        findings: result.findings.length,
        resolved: result.resolvedIds.length,
      })
      return { check: completed, finalization }
    })
  }

  private async applyFindings(check: CheckRecord, result: CheckResult, now: string): Promise<FindingsFile> {
    return this.store.updateFindings((file) => {
      for (const finding of result.findings) {
        const binding = {
          inputDigest: check.inputDigest,
          artifactRoot: check.artifactRoot,
          artifactDigest: check.artifactDigest,
          requirement: finding.requirement,
          evidence: finding.evidence,
          action: finding.action,
        }
        const existing = file.findings.find((candidate) => candidate.id === finding.id)
        if (existing === undefined) {
          const record: FindingRecord = {
            id: finding.id,
            requirement: finding.requirement,
            evidence: finding.evidence,
            action: finding.action,
            status: 'open',
            firstSeenCheck: check.number,
            lastSeenCheck: check.number,
            repeats: 0,
            binding,
          }
          file.findings.push(record)
          continue
        }
        if (bindingEqual(existing.binding, binding)) {
          existing.lastSeenCheck = check.number
          if (existing.status === 'open') {
            existing.repeats += 1
          }
          continue
        }
        existing.requirement = finding.requirement
        existing.evidence = finding.evidence
        existing.action = finding.action
        existing.binding = binding
        existing.status = 'open'
        existing.lastSeenCheck = check.number
        existing.repeats = 0
        delete existing.resolvedByCheck
        delete existing.resolvedAt
      }
      for (const id of result.resolvedIds) {
        const existing = file.findings.find((candidate) => candidate.id === id)
        if (existing === undefined) continue
        if (existing.status === 'open') {
          existing.status = 'resolved'
          existing.resolvedByCheck = check.number
          existing.resolvedAt = now
        }
      }
    })
  }

  async failCheck(number: number, failure: { kind: string; message: string }): Promise<CheckRecord> {
    return this.mutex.run(async () => {
      const check = await this.store.readCheck(number)
      if (check.status !== 'in_flight') {
        throw new OrbitError('invalid_state', `check ${number} is ${check.status}`)
      }
      const now = this.store.now()
      const failed: CheckRecord = {
        ...check,
        status: 'failed',
        finishedAt: now,
        failure: { kind: failure.kind, message: failure.message, at: now },
      }
      await this.store.writeCheck(failed)
      await this.store.updateState((draft) => {
        if (draft.checks.inFlight === number) draft.checks.inFlight = null
      })
      await this.store.appendEvent('check/failed', { number, kind: failure.kind, message: failure.message })
      return failed
    })
  }

  async requestStop(reason: StopReason = 'user'): Promise<TaskState> {
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      if (state.stop !== undefined) return state
      if (state.status !== 'running') {
        throw new OrbitError('invalid_state', `cannot stop a ${state.status} task`)
      }
      const next = await this.store.updateState((draft) => {
        draft.stop = { requestedAt: this.store.now(), reason, fence: 'armed' }
      })
      await this.store.appendEvent('stop/requested', { reason })
      return next
    })
  }

  async requestCompletion(artifactDigest: string): Promise<CompletionAcceptance | CompletionRejection> {
    nonEmpty(artifactDigest, 'artifactDigest')
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      if (state.status !== 'running') {
        return rejection('not_running', `task is ${state.status}`, '创建新任务或按续接规则处理')
      }
      if (state.stop !== undefined && state.stop.reason !== 'complete') {
        return rejection('stop_pending', 'a different stop is already pending', '等待当前停止确认')
      }
      const gate = await this.evaluateCompletion(state, artifactDigest)
      if (!gate.ok) return gate
      if (state.stop === undefined) {
        await this.store.updateState((draft) => {
          draft.stop = { requestedAt: this.store.now(), reason: 'complete', fence: 'armed' }
        })
        await this.store.appendEvent('completion/requested', { artifactDigest })
      }
      return { ok: true }
    })
  }

  async confirmStop(options: ConfirmStopOptions): Promise<TaskState> {
    return this.mutex.run(async () => {
      const state = await this.store.readState()
      if (state.status !== 'running' && state.status !== 'stop_unconfirmed') {
        throw new OrbitError('invalid_state', `cannot confirm stop for a ${state.status} task`)
      }
      if (state.stop === undefined) {
        throw new OrbitError('invalid_state', 'stop was never requested')
      }
      const evidence: Record<string, boolean> = {}
      const missing: string[] = []
      for (const key of STOP_EVIDENCE_KEYS) {
        const value = options.evidence[key] === true
        evidence[key] = value
        if (!value) missing.push(key)
      }
      const now = this.store.now()
      if (missing.length > 0) {
        const next = await this.store.updateState((draft) => {
          draft.status = 'stop_unconfirmed'
          if (draft.stop === undefined) throw new OrbitError('invalid_state', 'stop was never requested')
          draft.stop.confirmation = {
            confirmed: false,
            at: now,
            evidence,
            missing,
            ...(options.diagnostics === undefined ? {} : { diagnostics: options.diagnostics }),
          }
        })
        await this.store.appendEvent('stop/unconfirmed', { missing, diagnostics: options.diagnostics })
        return next
      }

      const reason = state.stop.reason
      let status: TaskStatus = 'paused'
      let completion: TaskState['completion']
      let invalidation: TaskState['completionInvalidation']
      if (reason === 'complete') {
        const gate = await this.evaluateCompletion(state, options.artifactDigest)
        if (gate.ok) {
          status = 'complete'
          completion = {
            at: now,
            checkNumber: state.finalization?.checkNumber ?? 0,
            inputVersion: state.finalization?.inputVersion ?? 0,
            inputDigest: state.finalization?.inputDigest ?? '',
            artifactDigest: options.artifactDigest,
            artifactRoot: state.workspace.artifactRoot,
            noticeId: state.finalization?.id ?? '',
          }
        } else {
          status = 'paused'
          invalidation = { code: gate.code, message: gate.message, at: now }
        }
      } else if (reason === 'needs_user') {
        status = 'needs_user'
      } else if (reason === 'failure') {
        status = 'failed'
      }

      const next = await this.store.updateState((draft) => {
        draft.status = status
        if (draft.stop === undefined) throw new OrbitError('invalid_state', 'stop was never requested')
        draft.stop.confirmation = {
          confirmed: true,
          at: now,
          evidence,
          missing: [],
          ...(options.diagnostics === undefined ? {} : { diagnostics: options.diagnostics }),
        }
        if (completion !== undefined) draft.completion = completion
        if (invalidation !== undefined) draft.completionInvalidation = invalidation
      })
      await this.store.appendEvent('stop/confirmed', { status, evidence })
      if (status === 'complete') {
        await this.store.appendEvent('task/completed', { checkNumber: completion?.checkNumber })
      } else if (invalidation !== undefined) {
        await this.store.appendEvent('completion/invalidated', invalidation)
      }
      return next
    })
  }

  async markCheckStale(number: number, reason: StaleReasonLike, detail?: string): Promise<CheckRecord> {
    return this.mutex.run(async () => {
      const check = await this.store.readCheck(number)
      if (check.status === 'stale') return check
      const stale: CheckRecord = {
        ...check,
        status: 'stale',
        stale: { reason, at: this.store.now(), ...(detail === undefined ? {} : { detail }) },
      }
      await this.store.writeCheck(stale)
      await this.store.updateState((draft) => {
        if (draft.checks.inFlight === number) draft.checks.inFlight = null
      })
      await this.store.appendEvent('check/stale', { number, reason, detail })
      return stale
    })
  }

  private async evaluateCompletion(state: TaskState, artifactDigest: string): Promise<CompletionAcceptance | CompletionRejection> {
    const notice = state.finalization
    if (notice === undefined) {
      return rejection(
        'no_finalization_notice',
        'no manual finalization notice for the current delivery',
        '在最终版本上请求手动 check 并结束当前 turn 等待',
      )
    }
    if (notice.inputVersion !== state.input.versions.length || notice.inputDigest !== inputDigest(state.input.versions)) {
      return rejection('stale_input', 'the finalization notice belongs to an older input version', '在当前输入版本上重新申请终检')
    }
    if (notice.artifactDigest !== artifactDigest) {
      return rejection('stale_artifact', 'the artifact changed after the finalization notice', '在当前产物版本上重新申请终检')
    }
    if (notice.artifactRoot !== state.workspace.artifactRoot) {
      return rejection('stale_workspace', 'the artifact root changed after the finalization notice', '在新产物根上重新申请终检')
    }
    if (state.checks.inFlight !== null) {
      return rejection('check_in_flight', `check ${state.checks.inFlight} is still in flight`, '等待检查结束')
    }

    let members: MembersFile
    try {
      members = await this.store.members()
    } catch {
      return rejection('membersfile_unreadable', 'the authoritative members file is unreadable', '停止后重试并核对成员名单')
    }
    const unsettled = members.members.filter((member) => member.status === 'registered')
    if (unsettled.length > 0) {
      return rejection('unsettled_members', 'some members have not settled', '先结束成员')
    }

    const findings = await this.store.findings()
    const open = findings.findings.filter((finding) => finding.status === 'open')
    if (open.length > 0) {
      return rejection('open_findings', `open findings: ${open.map((finding) => finding.id).join(', ')}`, '修正 open finding 或提交 dispute 后重新检查')
    }

    const coverage = await this.store.coverage()
    const record = coverage.records.find((candidate) => candidate.checkNumber === notice.checkNumber)
    if (record === undefined || record.stale !== undefined) {
      return rejection('coverage_unverified', 'no current coverage record for the final check', '重新运行覆盖完整的终检')
    }
    const deliveryItems = record.coverage.items.filter((item) => item.scope === 'delivery')
    if (!record.coverage.complete || deliveryItems.length === 0 || deliveryItems.some((item) => item.status !== 'verified')) {
      return rejection('coverage_unverified', 'the checker did not verify every delivery requirement', '重新运行覆盖完整的终检')
    }

    const check = await this.store.readCheck(notice.checkNumber)
    if (
      check.status !== 'completed' ||
      check.trigger !== 'manual' ||
      check.role !== 'reviewer' ||
      check.kind !== 'artifact' ||
      check.result?.verdict !== 'complete' ||
      !check.result.delivery.ready
    ) {
      return rejection('coverage_unverified', 'the finalization check is not a current manual reviewer check', '在当前版本上重新申请手动终检')
    }

    return { ok: true }
  }

  async status(): Promise<{
    state: TaskState
    inputDigest: string
    members: MembersFile
    workUnits: WorkUnitsFile
    checks: CheckRecord[]
    findings: FindingsFile
    disputes: DisputesFile
    coverage: CoverageFile
    openFindings: FindingRecord[]
    openDisputes: DisputeRecord[]
  }> {
    const [state, members, workUnits, checks, findings, disputes, coverage] = await Promise.all([
      this.store.readState(),
      this.store.members(),
      this.store.workUnits(),
      this.store.listChecks(),
      this.store.findings(),
      this.store.disputes(),
      this.store.coverage(),
    ])
    return {
      state,
      inputDigest: inputDigest(state.input.versions),
      members,
      workUnits,
      checks,
      findings,
      disputes,
      coverage,
      openFindings: findings.findings.filter((finding) => finding.status === 'open'),
      openDisputes: disputes.disputes.filter((dispute) => dispute.status === 'pending'),
    }
  }
}

type StaleReasonLike = 'artifact' | 'input' | 'host' | 'workspace' | 'dispute'

function bindingEqual(a: FindingRecord['binding'], b: FindingRecord['binding']): boolean {
  return (
    a.inputDigest === b.inputDigest &&
    a.artifactRoot === b.artifactRoot &&
    a.artifactDigest === b.artifactDigest &&
    a.requirement === b.requirement &&
    a.evidence === b.evidence &&
    a.action === b.action
  )
}

function rejection(code: CompletionRejection['code'], message: string, nextAction: string): CompletionRejection {
  return { ok: false, code, message, nextAction }
}

export { sameModel }

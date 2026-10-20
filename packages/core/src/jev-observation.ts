import type {
  CheckRecord,
  FindingsFile,
  MembersFile,
  TaskState,
  WorkUnitsFile,
} from './types.js'
import { inputDigest } from './service.js'
import { observationKey } from './observation-key.js'
import type { JudgmentQuestion } from './judgment.js'

export const JEV_OBSERVATION_QUESTION_SET_VERSION = 'jev-observation-4'
export const JEV_OBSERVATION_INPUT_VERSION = 'jev-observation-input-4'

/** Provisional threshold; the version bump invalidated old calibration. */
export const JEV_OBSERVATION_THRESHOLD = 0.5

export const JEV_OBSERVATION_QUESTIONS: JudgmentQuestion[] = [
  {
    id: 'stuck',
    instruction:
      'Is the coding agent likely unable to make useful progress on the current task now? Do not infer this from elapsed time alone; ordinary exploration or a single failed command is not stuckness.',
    trueCriterion: 'Repeated failure or inactivity without a useful new approach',
    falseCriterion: 'Useful work is continuing or the evidence is insufficient',
  },
  {
    id: 'off_track',
    instruction:
      'Is recent work likely outside or contrary to the latest effective user request? Normal investigation, tests and necessary setup can be relevant work.',
    trueCriterion: 'Concrete recent activity appears unrelated or contrary to the request',
    falseCriterion: 'Activity appears relevant or the evidence is insufficient',
  },
]

export interface JevOperation {
  id: string
  seq: number
  turn: number
  step: number
  name: string
  declaredIntent: string
  target: string
  status: 'ok' | 'error' | 'aborted' | 'interrupted' | 'not_observed'
  startedAt: number
  finishedAt?: number
  durationMs?: number
}

export interface JevOperationWindow {
  operations: JevOperation[]
  omittedOlderOperations: number
  historyGap: boolean
  crashGap?: { seq: number }
}

export interface JevObservationBuildInput {
  state: TaskState
  members: MembersFile
  units: WorkUnitsFile
  checks: CheckRecord[]
  findings: FindingsFile
  window: JevOperationWindow
  /** Host-confirmed owner jobs still running/stopping. */
  asyncJobs: number
  artifactDigest: string
  trigger?: unknown
  now?: Date
}

/** Bounded observation material for `jev-observation-4`; no tool inputs/outputs. */
export function buildJevObservationState(input: JevObservationBuildInput): Record<string, unknown> {
  const { state } = input
  const now = input.now ?? new Date()
  const elapsedMs = Math.max(0, now.getTime() - Date.parse(state.createdAt))
  const original = state.input.versions[0]
  const amendments = state.input.versions.slice(1).map((version) => ({
    version: version.version,
    text: version.text,
    source_kind: version.source.kind,
  }))
  const byMember = new Map(input.members.members.map((member) => [member.id, member]))
  const lastCheck = input.checks.at(-1)

  return {
    input_version: JEV_OBSERVATION_INPUT_VERSION,
    task: {
      id: state.id,
      created_at: state.createdAt,
      elapsed_ms: elapsedMs,
      status: state.status,
      project_root: state.projectRoot,
      artifact_root: state.workspace.artifactRoot,
    },
    instruction: {
      original: original?.text ?? '',
      amendments,
    },
    host: {
      status: state.status,
      turn_id: input.window.operations.at(-1)?.turn ?? null,
      last_turn_id: input.window.operations.at(-1)?.turn ?? null,
      last_turn_status: input.window.crashGap === undefined ? 'unknown' : 'interrupted',
      active_tools: input.window.operations.filter((operation) => operation.status === 'not_observed').length,
      async_jobs: input.asyncJobs,
    },
    members: input.members.members.map((member) => {
      const unit = input.units.units.find((candidate) => candidate.id === member.workUnitId)
      const recent = [...input.window.operations].reverse().find((operation) => operation.turn !== undefined)
      return {
        id: member.id,
        status: member.status,
        work_unit_id: member.workUnitId,
        unit_status: unit?.status ?? 'unknown',
        model: member.model ?? null,
        last_operation: recent === undefined ? null : { name: recent.name, status: recent.status, finished_at: recent.finishedAt ?? null },
        knows_member: byMember.has(member.id),
      }
    }),
    work_units: input.units.units.map((unit) => ({
      id: unit.id,
      status: unit.status,
      goal: unit.goal,
      acceptance: unit.acceptance,
      execution: unit.execution,
      dependencies: unit.dependencies,
    })),
    window: {
      operations: input.window.operations,
      omitted_older_operations: input.window.omittedOlderOperations,
      history_gap: input.window.historyGap,
      ...(input.window.crashGap === undefined ? {} : { crash_gap: input.window.crashGap }),
    },
    checks: {
      count: input.checks.length,
      latest:
        lastCheck === undefined
          ? null
          : {
              number: lastCheck.number,
              role: lastCheck.role,
              kind: lastCheck.kind,
              status: lastCheck.status,
              verdict: lastCheck.result?.verdict ?? null,
              delivery_ready: lastCheck.result?.delivery.ready ?? null,
              findings: lastCheck.result?.findings.length ?? null,
            },
    },
    findings: {
      open: input.findings.findings
        .filter((finding) => finding.status === 'open')
        .map((finding) => ({
          id: finding.id,
          requirement: finding.requirement,
          evidence: finding.evidence,
          action: finding.action,
          repeats: finding.repeats,
        })),
    },
    artifact: { digest: input.artifactDigest },
    question_set_version: JEV_OBSERVATION_QUESTION_SET_VERSION,
    ...(input.trigger === undefined ? {} : { trigger: input.trigger }),
  }
}

/** Deterministic dedup key for one observation input. */
export function jevObservationKey(input: JevObservationBuildInput): string {
  return observationKey({
    inputDigest: inputDigest(input.state.input.versions),
    artifactRoot: input.state.workspace.artifactRoot,
    artifactDigest: input.artifactDigest,
    host: {
      status: input.state.status,
      lastTurnId: input.window.operations.at(-1)?.turn ?? null,
      lastTurnStatus: input.window.crashGap === undefined ? 'unknown' : 'interrupted',
      observations: input.window.operations,
    },
    findings: input.findings.findings,
    dispute: undefined,
    trigger: input.trigger ?? { kind: 'observation', question_set_version: JEV_OBSERVATION_QUESTION_SET_VERSION },
  })
}

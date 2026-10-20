import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { TaskService, TaskStore, type CheckRecord, type TaskEvent, type TaskState } from '@orbit/core'

export interface StatusView {
  ok: true
  taskId: string
  status: TaskState['status']
  inputVersion: number
  artifactRoot: string
  externalRefs?: string[]
  modelAuthorization?: unknown
  checksInFlight: number | null
  stop?: string
  completionInvalidation?: TaskState['completionInvalidation']
  members: unknown[]
  workUnits: Array<{ id: string; status: string; goal: string }>
  checks: Array<{ number: number; status: string; verdict?: string }>
  openFindings: string[]
  openDisputes?: string[]
  revision?: string
  attention?: { phase: string; needsUser: boolean }
  pendingQuestions?: string[]
  latestCheck?: unknown
  requirementCoverage?: unknown
}

export async function taskDirs(projectRoot: string, limit = 64): Promise<string[]> {
  const root = TaskStore.tasksRoot(projectRoot)
  const names = await readdir(root).catch(() => [] as string[])
  return names.filter((entry) => !entry.startsWith('.')).sort().slice(-limit).map((entry) => join(root, entry))
}

export async function findLatest(projectRoot: string, limit = 64): Promise<TaskService | undefined> {
  let fallback: TaskService | undefined
  for (const dir of await taskDirs(projectRoot, limit)) {
    let service: TaskService
    try {
      service = await TaskService.open(dir)
    } catch {
      continue
    }
    const state = await service.state()
    if (state.status === 'running') return service
    fallback ??= service
  }
  return fallback
}

export async function openTask(projectRoot: string, id?: string): Promise<TaskService> {
  if (id !== undefined) {
    return TaskService.open(join(TaskStore.tasksRoot(projectRoot), id))
  }
  const latest = await findLatest(projectRoot)
  if (latest === undefined) throw new Error(`no Orbit task in ${projectRoot}`)
  return latest
}

function viewOf(
  state: TaskState,
  members: unknown[],
  units: StatusView['workUnits'],
  checks: CheckRecord[],
  openFindings: string[],
  openDisputes: string[],
  revision: string,
  attention: { phase: string; needsUser: boolean },
  pendingQuestions: string[],
  latestCheck: unknown,
  requirementCoverage: unknown,
): StatusView {
  return {
    ok: true,
    taskId: state.id,
    status: state.status,
    inputVersion: state.input.versions.length,
    artifactRoot: state.workspace.artifactRoot,
    ...(state.externalRefs === undefined ? {} : { externalRefs: state.externalRefs }),
    modelAuthorization: state.authorization ?? null,
    checksInFlight: state.checks.inFlight,
    ...(state.stop === undefined ? {} : { stop: state.stop.reason }),
    ...(state.completionInvalidation === undefined ? {} : { completionInvalidation: state.completionInvalidation }),
    members,
    workUnits: units,
    checks: checks.map((check) => ({
      number: check.number,
      status: check.status,
      ...(check.result === undefined ? {} : { verdict: check.result.verdict }),
    })),
    openFindings,
    openDisputes,
    revision,
    attention,
    pendingQuestions,
    latestCheck,
    requirementCoverage,
  }
}

function latestCheckView(check: CheckRecord | undefined): unknown {
  if (check === undefined) return null
  return {
    number: check.number,
    role: check.role,
    kind: check.kind,
    trigger: check.trigger,
    status: check.status,
    inputVersion: check.inputVersion,
    artifactDigest: check.artifactDigest,
    requestedAt: check.requestedAt,
    ...(check.finishedAt === undefined ? {} : { finishedAt: check.finishedAt }),
    ...(check.result === undefined ? {} : { result: check.result }),
    ...(check.failure === undefined ? {} : { failure: check.failure }),
    ...(check.stale === undefined ? {} : { stale: check.stale }),
  }
}

export async function statusOf(service: TaskService): Promise<StatusView> {
  const status = await service.status()
  return viewOf(
    status.state,
    status.members.members,
    status.workUnits.units.map((unit) => ({ id: unit.id, status: unit.status, goal: unit.goal })),
    status.checks,
    status.openFindings.map((finding) => finding.id),
    status.openDisputes.map((dispute) => dispute.id),
    status.state.updatedAt,
    {
      phase: status.state.status === 'running'
        ? (status.state.checks.inFlight === null ? 'working' : 'checking')
        : status.state.status,
      needsUser: status.state.status === 'needs_user' || status.questions.some((question) => question.status === 'pending'),
    },
    status.questions.filter((question) => question.status === 'pending').map((question) => question.id),
    latestCheckView(status.checks.at(-1)),
    status.coverage.records.at(-1) ?? null,
  )
}

export async function localStatus(projectRoot: string, id?: string): Promise<StatusView> {
  return statusOf(await openTask(projectRoot, id))
}

export async function localStatusByRef(projectRoot: string, ref: string, limit = 64): Promise<StatusView[]> {
  const tasks: StatusView[] = []
  for (const dir of (await taskDirs(projectRoot, limit)).reverse()) {
    let service: TaskService
    try {
      service = await TaskService.open(dir)
    } catch {
      continue
    }
    const state = await service.state()
    if (state.externalRefs?.includes(ref) === true) tasks.push(await statusOf(service))
  }
  return tasks
}

export async function localQuestions(projectRoot: string, id?: string): Promise<{ taskId: string; questions: unknown[] }> {
  const service = await openTask(projectRoot, id)
  const state = await service.state()
  const file = await service.store.questions()
  return { taskId: state.id, questions: file.questions }
}

export async function localEvents(projectRoot: string, id?: string): Promise<{ taskId: string; events: TaskEvent[] }> {
  const service = await openTask(projectRoot, id)
  return { taskId: (await service.state()).id, events: await service.store.events() }
}

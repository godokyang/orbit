import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { TaskService, TaskStore, type CheckRecord, type TaskEvent, type TaskState } from '@orbit/core'

export interface StatusView {
  ok: true
  taskId: string
  status: TaskState['status']
  inputVersion: number
  artifactRoot: string
  checksInFlight: number | null
  stop?: string
  completionInvalidation?: TaskState['completionInvalidation']
  members: unknown[]
  workUnits: Array<{ id: string; status: string; goal: string }>
  checks: Array<{ number: number; status: string; verdict?: string }>
  openFindings: string[]
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

function viewOf(state: TaskState, members: unknown[], units: StatusView['workUnits'], checks: CheckRecord[], openFindings: string[]): StatusView {
  return {
    ok: true,
    taskId: state.id,
    status: state.status,
    inputVersion: state.input.versions.length,
    artifactRoot: state.workspace.artifactRoot,
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
  }
}

export async function localStatus(projectRoot: string, id?: string): Promise<StatusView> {
  const service = await openTask(projectRoot, id)
  const status = await service.status()
  return viewOf(
    status.state,
    status.members.members,
    status.workUnits.units.map((unit) => ({ id: unit.id, status: unit.status, goal: unit.goal })),
    status.checks,
    status.openFindings.map((finding) => finding.id),
  )
}

export async function localEvents(projectRoot: string, id?: string): Promise<{ taskId: string; events: TaskEvent[] }> {
  const service = await openTask(projectRoot, id)
  return { taskId: (await service.state()).id, events: await service.store.events() }
}

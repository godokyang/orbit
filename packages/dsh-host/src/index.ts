import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { Service, type Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-agent'
import { TaskService, TaskStore, type TaskState } from '@orbit/core'

export const name = 'orbit'

declare module '@deepseek-ai/cordis' {
  interface Context {
    orbit: OrbitHost
  }
}

export interface Config {
  /** Maximum tasks scanned when resolving the latest task. */
  maxTasks?: number
  /** Native subagent tool name; controlled dispatch requires this exact tool. */
  subagentTool?: string
}

interface PendingDispatch {
  unitId: string
  description: string
  toolCallId: string
  at: number
}

const TEXT_OUTPUT = {
  schema: { type: 'string' as const },
  render: (_args: unknown, value: string) => [{ type: 'text' as const, text: value }],
}

function agentCwd(ctx: Context, agentId: string): string {
  const session = ctx.sessions.get(agentId as never)
  const cwd = session?.header.cwd
  if (cwd === undefined) throw new Error('orbit: the calling agent has no workspace cwd')
  return cwd
}

async function taskDirs(projectRoot: string, limit: number): Promise<string[]> {
  const root = TaskStore.tasksRoot(projectRoot)
  const names = await readdir(root).catch(() => [] as string[])
  return names.filter((entry) => !entry.startsWith('.')).sort().slice(-limit).map((entry) => join(root, entry))
}

async function findLatest(projectRoot: string, limit: number): Promise<TaskService | undefined> {
  const dirs = await taskDirs(projectRoot, limit)
  let fallback: TaskService | undefined
  for (const dir of dirs) {
    try {
      const service = await TaskService.open(dir)
      const state = await service.state()
      if (state.status === 'running') return service
      fallback ??= service
    } catch {
      // Ignore incomplete or foreign directories; a real task record must parse.
    }
  }
  return fallback
}

async function openTask(projectRoot: string, limit: number, id?: string): Promise<TaskService> {
  if (id !== undefined) {
    const service = await TaskService.open(join(TaskStore.tasksRoot(projectRoot), id)).catch(() => undefined)
    if (service === undefined) throw new Error(`orbit: unknown task ${id}`)
    return service
  }
  const latest = await findLatest(projectRoot, limit)
  if (latest === undefined) throw new Error('orbit: no task exists in this project')
  return latest
}

async function findTaskForSession(projectRoot: string, limit: number, sessionId: string): Promise<TaskService | undefined> {
  for (const dir of await taskDirs(projectRoot, limit)) {
    let service: TaskService
    try {
      service = await TaskService.open(dir)
    } catch {
      continue
    }
    const state = await service.state()
    if (state.root.sessionId === sessionId) return service
    const members = await service.store.members().catch(() => undefined)
    if (members?.members.some((member) => member.id === sessionId) === true) return service
  }
  return undefined
}

function summarize(state: TaskState): Record<string, unknown> {
  return {
    taskId: state.id,
    status: state.status,
    inputVersion: state.input.versions.length,
    artifactRoot: state.workspace.artifactRoot,
    checksInFlight: state.checks.inFlight,
    stop: state.stop?.reason,
    completionInvalidation: state.completionInvalidation,
  }
}

function orbitUnitOf(prompt: unknown): string | undefined {
  if (typeof prompt !== 'string') return undefined
  return /\borbit-unit:\s*(wu-[A-Za-z0-9-]+)\b/.exec(prompt)?.[1]
}

/**
 * Orbit host service. This slice owns task creation/status/stop and controlled
 * delegation: a Root must reference a declared work unit in a `subagent` prompt,
 * the child is registered durably before its first model call, and a stopped
 * task's agents are fenced from further tool use.
 */
export default class OrbitHost extends Service {
  static inject = ['tools', 'sessions', 'agents']

  static Config: z<Config> = z.object({
    maxTasks: z.number().step(1).min(1).default(64),
    subagentTool: z.string().default('subagent'),
  })

  private readonly maxTasks: number
  private readonly subagentTool: string
  private readonly pending = new Map<string, PendingDispatch[]>()
  private readonly fencedSessions = new Set<string>()

  constructor(ctx: Context, config: Config = {}) {
    super(ctx, 'orbit')
    const maxTasks = config.maxTasks ?? 64
    this.maxTasks = maxTasks
    this.subagentTool = config.subagentTool ?? 'subagent'
    const host = this

    ctx.tools.register(
      defineTool({
        name: 'orbit',
        description:
          'Start or inspect an Orbit supervised task in the current workspace. '
          + 'start requires the verbatim user instruction; declare creates a work unit; '
          + 'accept/reject settle a finished unit; status/stop target the latest task.',
        parameters: {
          action: {
            type: 'string',
            required: true,
            enum: ['start', 'status', 'stop', 'declare', 'finish', 'accept', 'reject'],
            description: 'start | status | stop | declare | finish | accept | reject',
          },
          instruction: { type: 'string', description: 'The user instruction, verbatim. Required for action=start.' },
          task: { type: 'string', description: 'Optional task id; defaults to the latest task.' },
          goal: { type: 'string', description: 'Work-unit goal. Required for action=declare.' },
          acceptance: { type: 'string', description: 'Work-unit acceptance criteria. Required for action=declare.' },
          dependencies: {
            type: 'array',
            items: { type: 'string' },
            description: 'Work-unit ids that must already be accepted. Optional for action=declare.',
          },
          execution: {
            type: 'string',
            enum: ['root', 'delegate'],
            description: 'delegate (default) or root. Optional for action=declare.',
          },
          unit: { type: 'string', description: 'Work-unit id. Required for finish/accept/reject.' },
          outcome: {
            type: 'string',
            enum: ['completed', 'failed', 'refused', 'rejected'],
            description: 'Observed execution outcome. Required for action=finish.',
          },
          summary: { type: 'string', description: 'Execution summary. Required for action=finish.' },
          reason: { type: 'string', description: 'Rejection reason. Required for action=reject.' },
        },
        output: TEXT_OUTPUT,
        timeoutMs: 15_000,
        async execute(args, exec) {
          const agent = exec.agent
          if (agent === undefined) throw new Error('orbit: the tool requires an agent-bound caller')
          const projectRoot = agentCwd(ctx, agent.id)
          const action = (args as { action: string }).action

          if (action === 'start') {
            const instruction = (args as { instruction?: string }).instruction
            if (typeof instruction !== 'string' || instruction.trim().length === 0) {
              throw new Error('orbit: action=start requires a non-empty instruction')
            }
            const active = await findLatest(projectRoot, maxTasks)
            if (active !== undefined && (await active.state()).status === 'running') {
              throw new Error('orbit: this workspace already has a running task')
            }
            const { service, state } = await TaskService.start({
              projectRoot,
              rootSessionId: agent.id,
              instruction,
              source: { kind: 'explicit-text', verbatim: true, at: new Date().toISOString() },
            })
            return JSON.stringify({ ok: true, ...summarize(state), taskDir: service.store.dir })
          }

          if (action === 'status') {
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const status = await service.status()
            return JSON.stringify({
              ok: true,
              ...summarize(status.state),
              members: status.members.members,
              workUnits: status.workUnits.units.map((unit) => ({ id: unit.id, status: unit.status, goal: unit.goal })),
              checks: status.checks.map((check) => ({ number: check.number, status: check.status, verdict: check.result?.verdict })),
              openFindings: status.openFindings.map((finding) => finding.id),
            })
          }

          if (action === 'stop') {
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.requestStop('user')
            const members = await service.store.members()
            host.fencedSessions.add(state.root.sessionId)
            for (const member of members.members) host.fencedSessions.add(member.id)
            return JSON.stringify({ ok: true, ...summarize(state), fence: state.stop?.fence ?? 'none' })
          }

          if (action === 'declare') {
            const { goal, acceptance, dependencies, execution } = args as {
              goal?: string
              acceptance?: string
              dependencies?: string[]
              execution?: 'root' | 'delegate'
            }
            if (goal === undefined || acceptance === undefined) {
              throw new Error('orbit: action=declare requires goal and acceptance')
            }
            const service = await openTask(projectRoot, maxTasks)
            const unit = await service.declareWorkUnit({
              goal,
              acceptance,
              ...(dependencies === undefined ? {} : { dependencies }),
              ...(execution === undefined ? {} : { execution }),
            })
            return JSON.stringify({ ok: true, unit })
          }

          if (action === 'finish') {
            const { unit, outcome, summary } = args as { unit?: string; outcome?: 'completed' | 'failed' | 'refused' | 'rejected'; summary?: string }
            if (unit === undefined || outcome === undefined || summary === undefined) {
              throw new Error('orbit: action=finish requires unit, outcome and summary')
            }
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const units = await service.store.workUnits()
            const target = units.units.find((candidate) => candidate.id === unit)
            if (target === undefined) throw new Error(`orbit: unknown work unit ${unit}`)
            const memberId = target.attempts.at(-1)?.memberId
            if (memberId !== undefined) {
              await service.settleMember(memberId, outcome).catch(() => undefined)
            }
            const finished = await service.finishWorkUnit({ id: unit, outcome, summary })
            return JSON.stringify({ ok: true, unit: finished, memberId })
          }

          if (action === 'accept' || action === 'reject') {
            const { unit, reason } = args as { unit?: string; reason?: string }
            if (unit === undefined) throw new Error(`orbit: action=${action} requires unit`)
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            if (action === 'accept') {
              return JSON.stringify({ ok: true, unit: await service.acceptWorkUnit(unit) })
            }
            if (reason === undefined) throw new Error('orbit: action=reject requires reason')
            return JSON.stringify({ ok: true, unit: await service.rejectWorkUnit(unit, reason) })
          }

          throw new Error(`orbit: unknown action ${action}`)
        },
      }),
    )

    // H4: the Root's subagent call must reference a declared unit; park the
    // dispatch so agent/created can register the child before its first model call.
    ctx.on('tools/pre-execute', async (exec, next) => {
      if (exec.name !== this.subagentTool || exec.agent === undefined) return next()
      const projectRoot = agentCwd(ctx, exec.agent.id)
      const task = await findTaskForSession(projectRoot, maxTasks, exec.agent.id)
      if (task === undefined) return next()
      const state = await task.state()
      if (state.root.sessionId !== exec.agent.id) return next()
      if (state.stop !== undefined) return { kind: 'deny', reason: 'orbit: the task is stopped; no new member may be dispatched' }
      const args = exec.arguments as { prompt?: unknown; description?: unknown }
      const unitId = orbitUnitOf(args.prompt)
      if (unitId === undefined) {
        return {
          kind: 'deny',
          reason: 'orbit: controlled delegation requires the prompt to contain a line "orbit-unit: wu-...", where wu-... is a declared work unit',
        }
      }
      const units = await task.store.workUnits()
      const unit = units.units.find((candidate) => candidate.id === unitId)
      if (unit === undefined) return { kind: 'deny', reason: `orbit: unknown work unit ${unitId}` }
      if (unit.status !== 'declared') return { kind: 'deny', reason: `orbit: work unit ${unitId} is ${unit.status}, not ready to dispatch` }
      if (unit.inputVersion !== state.input.versions.length) return { kind: 'deny', reason: `orbit: work unit ${unitId} belongs to input version ${unit.inputVersion}` }
      if (unit.artifactRoot !== state.workspace.artifactRoot) return { kind: 'deny', reason: `orbit: work unit ${unitId} belongs to ${unit.artifactRoot}` }
      const queue = this.pending.get(exec.agent.id) ?? []
      queue.push({
        unitId,
        description: typeof args.description === 'string' ? args.description : 'member',
        toolCallId: exec.callId,
        at: Date.now(),
      })
      this.pending.set(exec.agent.id, queue)
      return next()
    })

    ctx.on('agent/created', async ({ agent }) => {
      if (host.fencedSessions.has(agent.id)) throw new Error('orbit: session belongs to a stopped task')
      const session = ctx.sessions.get(agent.id)
      const parent = session?.header.parentSession
      if (parent === undefined) return
      if (host.fencedSessions.has(parent)) throw new Error('orbit: parent session belongs to a stopped task')
      const projectRoot = session?.header.cwd
      if (projectRoot === undefined) return
      const queue = this.pending.get(parent)
      const dispatch = queue?.shift()
      if (queue?.length === 0) this.pending.delete(parent)
      if (dispatch === undefined) return
      const task = await findTaskForSession(projectRoot, maxTasks, parent)
      if (task === undefined) throw new Error('orbit: delegated member has no owning task')
      try {
        await task.registerMember({
          id: agent.id,
          requestedName: dispatch.description,
          workUnitId: dispatch.unitId,
          toolCallId: dispatch.toolCallId,
        })
      } catch (error) {
        throw new Error(`orbit: member registration refused: ${(error as Error).message}`)
      }
    })

    // H3/H5: a stopped task's agents cannot use tools. The fence is the durable
    // stop record, so it survives plugin reloads.
    ctx.tools.guard((exec) => {
      if (exec.agent !== undefined && host.fencedSessions.has(exec.agent.id)) {
        return 'orbit: this task is stopped; tool use is fenced'
      }
      return undefined
    })
  }
}

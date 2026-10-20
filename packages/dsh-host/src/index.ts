import { readFileSync, renameSync, writeFileSync } from 'node:fs'
import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { Service, type Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-agent-loop'
import type {} from '@deepseek-ai/dsh-session'
import { CONTROL_SOCKET_FILE, TaskService, TaskStore, digestWorkspace, type ControlRequest, type ModelIdentity, type TaskState } from '@orbit/core'
import { ControlServer } from './control.js'
import { buildCheckerPrompt, runChecker } from './checker.js'

export { ControlServer } from './control.js'

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
  /** Optional explicit checker route; the dsh-sdk provider defaults apply when absent. */
  checkerProvider?: string
  checkerModel?: string
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

const STOP_TIMEOUT_MS = 5_000

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

async function projectStatus(service: TaskService): Promise<Record<string, unknown>> {
  const status = await service.status()
  return {
    ...summarize(status.state),
    members: status.members.members,
    workUnits: status.workUnits.units.map((unit) => ({ id: unit.id, status: unit.status, goal: unit.goal })),
    checks: status.checks.map((check) => ({ number: check.number, status: check.status, verdict: check.result?.verdict })),
    openFindings: status.openFindings.map((finding) => finding.id),
  }
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

function fenceRegistryPath(): string | undefined {
  const home = process.env.DSH_HOME
  return home === undefined || home.length === 0 ? undefined : join(home, 'orbit-fences.json')
}

function loadFenceRegistry(): Set<string> {
  const path = fenceRegistryPath()
  if (path === undefined) return new Set()
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as { sessionIds?: unknown }
    return new Set(Array.isArray(parsed.sessionIds) ? parsed.sessionIds.filter((id): id is string => typeof id === 'string') : [])
  } catch {
    return new Set()
  }
}

function saveFenceRegistry(sessions: Set<string>): void {
  const path = fenceRegistryPath()
  if (path === undefined) return
  const temp = `${path}.tmp`
  try {
    writeFileSync(temp, JSON.stringify({ version: 1, sessionIds: [...sessions] }), { mode: 0o600 })
    renameSync(temp, path)
  } catch {
    // The task record stays authoritative; a lost host cache only weakens
    // restart fencing, it never confirms a stop.
  }
}

function renderRequirements(taskDir: string): string {
  try {
    const state = JSON.parse(readFileSync(join(taskDir, 'state.json'), 'utf8')) as TaskState
    const versions = state.input.versions
      .map((version) => {
        const label = version.version === 1 ? '原始要求' : `修订 v${version.version}`
        const source = version.source.kind === 'user-message' ? `用户消息 ${version.source.messageId ?? ''}` : '显式文本'
        return `${label}（来源：${source}）：\n${version.text}`
      })
      .join('\n\n')
    return [
      `[Orbit 受控任务 ${state.id}]`,
      `状态：${state.status}；输入版本：${state.input.versions.length}；产物根：${state.workspace.artifactRoot}`,
      versions,
      '要求与修订以本块为准；原生用户消息本身不自动成为修订。',
      '停止使用 orbit 工具 action=stop；完成必须经过独立检查与停止确认，不得自行声称完成。',
    ].join('\n')
  } catch (error) {
    return `[Orbit] 任务记录不可读（${(error as Error).message}）；不要按缩小后的授权继续。`
  }
}

async function bounded(promise: Promise<unknown>, ms: number): Promise<boolean> {
  let timer: NodeJS.Timeout | undefined
  const timeout = new Promise<false>((resolve) => {
    timer = setTimeout(() => resolve(false), ms)
  })
  try {
    return (await Promise.race([promise.then(() => true), timeout])) === true
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

/**
 * Orbit host service. This slice owns task creation/status/stop and controlled
 * delegation: a Root must reference a declared work unit in a `subagent` prompt,
 * the child is registered durably before its first model call, a stopped task's
 * agents are fenced, and stop teardown records the evidence it actually saw.
 */
export default class OrbitHost extends Service {
  static inject = ['tools', 'sessions', 'agents', 'systemPrompt', 'subagents']

  static Config: z<Config> = z.object({
    maxTasks: z.number().step(1).min(1).default(64),
    subagentTool: z.string().default('subagent'),
    checkerProvider: z.string().default(''),
    checkerModel: z.string().default(''),
  })

  private readonly maxTasks: number
  private readonly subagentTool: string
  private readonly checkerModel: ModelIdentity | undefined
  private readonly pending = new Map<string, PendingDispatch[]>()
  private readonly fencedSessions = loadFenceRegistry()
  private readonly requirementDisposers = new Map<string, () => void>()
  private readonly controls = new Map<string, ControlServer>()

  constructor(ctx: Context, config: Config = {}) {
    super(ctx, 'orbit')
    const maxTasks = config.maxTasks ?? 64
    this.maxTasks = maxTasks
    this.subagentTool = config.subagentTool ?? 'subagent'
    this.checkerModel =
      config.checkerProvider !== undefined && config.checkerProvider.length > 0 && config.checkerModel !== undefined && config.checkerModel.length > 0
        ? { provider: config.checkerProvider, model: config.checkerModel }
        : undefined
    const host = this

    ctx.tools.register(
      defineTool({
        name: 'orbit',
        description:
          'Start or inspect an Orbit supervised task in the current workspace. '
          + 'start requires the verbatim user instruction; declare creates a work unit; '
          + 'finish/accept/reject settle a member unit; status/stop target the latest task.',
        parameters: {
          action: {
            type: 'string',
            required: true,
            enum: ['start', 'status', 'stop', 'declare', 'finish', 'accept', 'reject', 'check', 'complete'],
            description: 'start | status | stop | declare | finish | accept | reject | check | complete',
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
        timeoutMs: 600_000,
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
            host.fencedSessions.delete(agent.id)
            saveFenceRegistry(host.fencedSessions)
            host.attachRequirements(agent, service)
            await host.ensureControl(projectRoot).catch((error: Error) => {
              console.error(`orbit: control socket unavailable: ${error.message}`)
            })
            return JSON.stringify({ ok: true, ...summarize(state), taskDir: service.store.dir })
          }

          if (action === 'status') {
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            return JSON.stringify({ ok: true, ...(await projectStatus(service)) })
          }

          if (action === 'stop') {
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await host.beginStop(service, 50)
            return JSON.stringify({ ok: true, ...summarize(state), fence: state.stop?.fence ?? 'none', teardown: 'scheduled' })
          }

          if (action === 'check') {
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.state()
            if (state.status !== 'running') throw new Error(`orbit: cannot check a ${state.status} task`)
            const rootAgent = ctx.agents.get(state.root.sessionId as never)
            if (rootAgent === undefined) throw new Error('orbit: the Root agent is not live; cannot run an independent check')
            const snapshot = await digestWorkspace(state.workspace.artifactRoot)
            const check = await service.requestCheck({
              role: 'reviewer',
              kind: 'artifact',
              trigger: 'manual',
              artifactDigest: snapshot.digest,
              ...(host.checkerModel === undefined ? {} : { model: host.checkerModel }),
            })
            const prompt = buildCheckerPrompt({ state, taskDir: service.store.dir, artifactDigest: snapshot.digest })
            try {
              const raw = await runChecker({
                subagents: ctx.subagents,
                parent: rootAgent,
                prompt,
                cwd: state.workspace.artifactRoot,
                signal: exec.signal,
                ...(host.checkerModel === undefined ? {} : { model: host.checkerModel }),
              })
              const recorded = await service.recordCheckResult(check.number, raw)
              return JSON.stringify({
                ok: true,
                checkNumber: check.number,
                finalization: recorded.finalization,
                verdict: recorded.check.result?.verdict,
                ready: recorded.check.result?.delivery.ready,
                findings: recorded.check.result?.findings.length ?? 0,
              })
            } catch (error) {
              await service.failCheck(check.number, { kind: 'checker_error', message: (error as Error).message }).catch(() => undefined)
              throw new Error(`orbit: independent check failed: ${(error as Error).message}`)
            }
          }

          if (action === 'complete') {
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.state()
            if (state.status !== 'running') throw new Error(`orbit: cannot complete a ${state.status} task`)
            const snapshot = await digestWorkspace(state.workspace.artifactRoot)
            const gate = await service.requestCompletion(snapshot.digest)
            if (!gate.ok) return JSON.stringify({ ...gate })
            setTimeout(() => { void host.performStop(service, snapshot.digest) }, 50)
            return JSON.stringify({ ok: true, completion: 'scheduled', artifactDigest: snapshot.digest })
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

    // H3/H5: a stopped task's agents cannot use tools. The fence cache is
    // rebuilt from DSH_HOME at load; the durable task record remains the authority.
    ctx.tools.guard((exec) => {
      if (exec.agent !== undefined && host.fencedSessions.has(exec.agent.id) && exec.name !== 'orbit') {
        return 'orbit: this task is stopped; tool use is fenced (the orbit tool may start a new task)'
      }
      return undefined
    })

    ctx.effect(() => () => {
      for (const server of host.controls.values()) void server.close()
      host.controls.clear()
    })
  }

  /** Start the private control socket for this project on first use. */
  private async ensureControl(projectRoot: string): Promise<void> {
    if (this.controls.has(projectRoot)) return
    const server = new ControlServer(join(projectRoot, '.orbit', CONTROL_SOCKET_FILE), (request) =>
      this.handleControl(projectRoot, request),
    )
    await server.start()
    this.controls.set(projectRoot, server)
  }

  private async handleControl(projectRoot: string, request: ControlRequest): Promise<unknown> {
    if (request.method === 'status') {
      const service = await openTask(projectRoot, this.maxTasks, request.task)
      return { ok: true, ...(await projectStatus(service)) }
    }
    if (request.method === 'events') {
      const service = await openTask(projectRoot, this.maxTasks, request.task)
      return { ok: true, taskId: (await service.state()).id, events: await service.store.events() }
    }
    if (request.method === 'stop') {
      const service = await openTask(projectRoot, this.maxTasks, request.task)
      const state = await this.beginStop(service, 0)
      return { ok: true, ...summarize(state), fence: state.stop?.fence ?? 'none' }
    }
    throw new Error(`orbit: unknown control method ${String(request.method)}`)
  }

  /** Arm the durable fence, persist the host cache and schedule teardown. */
  private async beginStop(service: TaskService, delayMs: number): Promise<TaskState> {
    const state = await service.requestStop('user')
    const members = await service.store.members()
    this.fencedSessions.add(state.root.sessionId)
    for (const member of members.members) this.fencedSessions.add(member.id)
    saveFenceRegistry(this.fencedSessions)
    setTimeout(() => { void this.performStop(service) }, delayMs)
    return state
  }

  /** H2: per-Root dynamic context; each admission rereads the durable record. */
  private attachRequirements(agent: NonNullable<import('@deepseek-ai/dsh-tools').ToolRunContext['agent']>, service: TaskService): void {
    const taskDir = service.store.dir
    if (this.requirementDisposers.has(taskDir)) return
    const dispose = agent.ctx.systemPrompt.context({
      name: `orbit:requirements:${taskDir}`,
      order: 800,
      required: true,
      text: () => renderRequirements(taskDir),
    })
    this.requirementDisposers.set(taskDir, dispose)
  }

  /**
   * Stop the task's actual execution after the tool result is delivered:
   * cancel the Root and registered members, wait for idle, settle members, then
   * confirm stop with the observed evidence. Missing evidence stays unconfirmed.
   */
  private async performStop(service: TaskService, artifactDigest = ''): Promise<void> {
    const state = await service.state()
    if (state.stop === undefined) return
    const evidence: Record<string, boolean> = {
      fence_persisted: true,
      root_idle: false,
      members_stopped: false,
      checks_settled: state.checks.inFlight === null,
    }
    try {
      const root = this.ctx.agents.get(state.root.sessionId as never)
      if (root === undefined) {
        evidence.root_idle = true
      } else {
        root.cancel({ kind: 'user' }, { keepInbox: true })
        evidence.root_idle = await bounded(root.whenIdle(), STOP_TIMEOUT_MS)
      }

      const members = await service.store.members()
      let stopped = true
      for (const member of members.members) {
        if (member.status !== 'registered') continue
        const agent = this.ctx.agents.get(member.id as never)
        if (agent !== undefined) {
          agent.cancel({ kind: 'user' }, { keepInbox: true })
          const idle = await bounded(agent.whenIdle(), STOP_TIMEOUT_MS)
          if (!idle) stopped = false
        }
        await service.settleMember(member.id, 'stopped').catch(() => undefined)
      }
      evidence.members_stopped = stopped
      evidence.checks_settled = (await service.state()).checks.inFlight === null

      await service.confirmStop({ artifactDigest, evidence })
    } catch (error) {
      // Never fabricate confirmation: a failed teardown leaves the durable stop
      // record unconfirmed for a later explicit retry.
      console.error(`orbit: stop teardown failed: ${(error as Error).message}`)
    }
  }
}

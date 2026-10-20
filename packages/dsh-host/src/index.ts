import { execFileSync } from 'node:child_process'
import { readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { readdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { Service, type Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-agent-loop'
import type {} from '@deepseek-ai/dsh-session'
import type {} from '@deepseek-ai/dsh-jobs'
import {
  CONTROL_SOCKET_FILE,
  JEV_OBSERVATION_QUESTIONS,
  JEV_OBSERVATION_THRESHOLD,
  TypeSafeJudgmentClient,
  TaskService,
  TaskStore,
  buildJevObservationState,
  digestWorkspace,
  jevObservationKey,
  type ControlRequest,
  type ModelIdentity,
  type TaskState,
} from '@orbit/core'
import { ControlServer } from './control.js'
import { buildCheckerPrompt, buildProcessCheckerPrompt, runChecker } from './checker.js'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { observationWindow, orbitObservationDefinition } from './observation.js'
import { allowedSet, authorizeRoute, routeKey, type ModelRoute } from './authorization.js'

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
  /** Optional TypeSafe endpoint override (tests/local proxies). */
  jevEndpoint?: string
  /** Optional judgment model alias; defaults to the provider's jev-latest. */
  jevModel?: string
  /** Observation signal threshold; provisional until real calibration. */
  jevThreshold?: number
  jevIntervalMs?: number
  jevFirstDelayMs?: number
  /** Frozen strict model list (exact `provider/model`). Empty means no freeze. */
  allowedModels?: string[]
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

function workspaceInfo(path: string): { artifactRoot: string; realPath: string; gitCommonDir?: string; worktree?: string; head?: string } {
  const realPath = realpathSync(path)
  const base = { artifactRoot: path, realPath }
  try {
    const git = (args: string[]): string => execFileSync('git', ['-C', realPath, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    const common = git(['rev-parse', '--git-common-dir'])
    const worktree = git(['rev-parse', '--show-toplevel'])
    const head = git(['rev-parse', 'HEAD'])
    return { ...base, gitCommonDir: resolve(realPath, common), worktree: realpathSync(worktree), head }
  } catch {
    return base
  }
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

async function projectStatus(service: TaskService): Promise<Record<string, unknown>> {
  const status = await service.status()
  return {
    ...summarize(status.state),
    members: status.members.members,
    workUnits: status.workUnits.units.map((unit) => ({ id: unit.id, status: unit.status, goal: unit.goal })),
    checks: status.checks.map((check) => ({ number: check.number, status: check.status, verdict: check.result?.verdict })),
    openFindings: status.openFindings.map((finding) => finding.id),
    openDisputes: status.openDisputes.map((dispute) => dispute.id),
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
  static inject = ['tools', 'sessions', 'agents', 'systemPrompt', 'subagents', 'sessionProjections', 'credentials', 'jobs']

  static Config: z<Config> = z.object({
    maxTasks: z.number().step(1).min(1).default(64),
    subagentTool: z.string().default('subagent'),
    checkerProvider: z.string().default(''),
    checkerModel: z.string().default(''),
    jevEndpoint: z.string().default(''),
    jevModel: z.string().default(''),
    jevThreshold: z.number().min(0).max(1).default(JEV_OBSERVATION_THRESHOLD),
    jevIntervalMs: z.number().step(1).min(1).default(300_000),
    jevFirstDelayMs: z.number().step(1).min(1).default(5_000),
    allowedModels: z.array(z.string()).default([]),
  })

  private readonly maxTasks: number
  private readonly subagentTool: string
  private readonly checkerModel: ModelIdentity | undefined
  private readonly jevEndpoint: string | undefined
  private readonly jevModel: string | undefined
  private readonly jevThreshold: number
  private readonly jevIntervalMs: number
  private readonly jevFirstDelayMs: number
  private readonly jevTimers = new Map<string, NodeJS.Timeout>()
  private readonly lastSignalKey = new Map<string, string>()
  private readonly allowedModels: Set<string>
  private readonly modelBindings = new Map<
    string,
    { taskDir: string; role: 'root' | 'member'; allowed: Set<string>; bound?: ModelRoute }
  >()
  private readonly autoChecks = new Set<string>()
  private readonly pending = new Map<string, PendingDispatch[]>()
  private readonly fencedSessions = loadFenceRegistry()
  private readonly requirementDisposers = new Map<string, () => void>()
  private readonly controls = new Map<string, ControlServer>()

  constructor(ctx: Context, config: Config = {}) {
    super(ctx, 'orbit')
    const maxTasks = config.maxTasks ?? 64
    this.maxTasks = maxTasks
    this.allowedModels = allowedSet(config.allowedModels)
    this.subagentTool = config.subagentTool ?? 'subagent'
    this.checkerModel =
      config.checkerProvider !== undefined && config.checkerProvider.length > 0 && config.checkerModel !== undefined && config.checkerModel.length > 0
        ? { provider: config.checkerProvider, model: config.checkerModel }
        : undefined
    this.jevEndpoint = config.jevEndpoint === undefined || config.jevEndpoint.length === 0 ? undefined : config.jevEndpoint
    this.jevModel = config.jevModel === undefined || config.jevModel.length === 0 ? undefined : config.jevModel
    this.jevThreshold = config.jevThreshold ?? JEV_OBSERVATION_THRESHOLD
    this.jevIntervalMs = config.jevIntervalMs ?? 300_000
    this.jevFirstDelayMs = config.jevFirstDelayMs ?? 5_000
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
            enum: ['start', 'status', 'stop', 'declare', 'finish', 'accept', 'reject', 'check', 'complete', 'amend', 'dispute', 'ruling', 'rebind', 'resume', 'takeover'],
            description: 'start | status | stop | declare | finish | accept | reject | check | complete | amend | dispute | ruling | rebind | resume | takeover',
          },
          instruction: { type: 'string', description: 'The user instruction, verbatim. Required for action=start.' },
          amendment: { type: 'string', description: 'The user amendment text, verbatim. Required for action=amend.' },
          messageId: { type: 'string', description: 'Native user message id that carries the amendment. Optional for action=amend.' },
          kind: {
            type: 'string',
            enum: ['artifact', 'process'],
            description: 'Check kind. Default artifact; process checks can never grant completion.',
          },
          finding: { type: 'string', description: 'Finding id. Required for action=dispute.' },
          dispute: { type: 'string', description: 'Dispute id. Required for action=ruling.' },
          decision: {
            type: 'string',
            enum: ['adopt', 'uphold'],
            description: 'Ruling decision. Required for action=ruling.',
          },
          artifactRoot: { type: 'string', description: 'New artifact root. Required for action=rebind.' },
          from: { type: 'string', description: 'Previous task id. Required for action=resume.' },
          priorScope: { type: 'string', description: 'Root-declared scope before takeover. Optional for action=takeover.' },
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
              workspace: workspaceInfo(projectRoot),
              ...(host.allowedModels.size === 0 ? {} : { allowedModels: [...host.allowedModels] }),
            })
            host.modelBindings.set(agent.id, {
              taskDir: service.store.dir,
              role: 'root',
              allowed: new Set(host.allowedModels),
            })
            await host.adopt(service, agent, projectRoot)
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
            const kind = (args as { kind?: 'artifact' | 'process' }).kind ?? 'artifact'
            const checkerModel = host.strictCheckerModel()
            const snapshot = await digestWorkspace(state.workspace.artifactRoot)
            const check = await service.requestCheck({
              role: 'reviewer',
              kind,
              trigger: 'manual',
              artifactDigest: snapshot.digest,
              ...(checkerModel === undefined ? {} : { model: checkerModel }),
            })
            const prompt = buildCheckerPrompt({ state, taskDir: service.store.dir, artifactDigest: snapshot.digest })
            try {
              const raw = await runChecker({
                subagents: ctx.subagents,
                parent: rootAgent,
                prompt,
                cwd: state.workspace.artifactRoot,
                signal: exec.signal,
                ...(checkerModel === undefined ? {} : { model: checkerModel }),
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

          if (action === 'amend') {
            const { amendment, messageId } = args as { amendment?: string; messageId?: string }
            if (typeof amendment !== 'string' || amendment.trim().length === 0) {
              throw new Error('orbit: action=amend requires the verbatim amendment text')
            }
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.state()
            const updated = await service.amend(amendment, {
              kind: messageId === undefined ? 'explicit-text' : 'user-message',
              ...(messageId === undefined ? {} : { messageId, sessionId: state.root.sessionId }),
              verbatim: messageId !== undefined,
              at: new Date().toISOString(),
            })
            return JSON.stringify({ ok: true, inputVersion: updated.input.versions.length })
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

          if (action === 'resume') {
            const { from, instruction, messageId } = args as { from?: string; instruction?: string; messageId?: string }
            if (from === undefined || instruction === undefined) throw new Error('orbit: action=resume requires from and instruction')
            const active = await findLatest(projectRoot, maxTasks)
            if (active !== undefined && (await active.state()).status === 'running') {
              throw new Error('orbit: this workspace already has a running task')
            }
            const { service, state } = await TaskService.resumeFrom(join(TaskStore.tasksRoot(projectRoot), from), {
              projectRoot,
              rootSessionId: agent.id,
              instruction,
              source: {
                kind: 'continuation',
                verbatim: true,
                at: new Date().toISOString(),
                ...(messageId === undefined ? {} : { messageId }),
              },
              workspace: workspaceInfo(projectRoot),
              ...(host.allowedModels.size === 0 ? {} : { allowedModels: [...host.allowedModels] }),
            })
            await host.adopt(service, agent, projectRoot)
            return JSON.stringify({ ok: true, ...summarize(state), taskDir: service.store.dir })
          }

          if (action === 'takeover') {
            const { instruction, reason, priorScope, messageId } = args as {
              instruction?: string
              reason?: string
              priorScope?: string
              messageId?: string
            }
            if (instruction === undefined || reason === undefined) throw new Error('orbit: action=takeover requires instruction and reason')
            const active = await findLatest(projectRoot, maxTasks)
            if (active !== undefined && (await active.state()).status === 'running') {
              throw new Error('orbit: this workspace already has a running task')
            }
            const snapshot = await digestWorkspace(projectRoot)
            const { service, state } = await TaskService.start({
              projectRoot,
              rootSessionId: agent.id,
              instruction,
              source: {
                kind: messageId === undefined ? 'explicit-text' : 'user-message',
                verbatim: messageId !== undefined,
                at: new Date().toISOString(),
                ...(messageId === undefined ? {} : { messageId, sessionId: agent.id }),
              },
              workspace: workspaceInfo(projectRoot),
              takeover: {
                reason,
                ...(priorScope === undefined ? {} : { priorScope }),
                ...(messageId === undefined ? {} : { messageId }),
                snapshot: { ...snapshot, at: new Date().toISOString() },
              },
              ...(host.allowedModels.size === 0 ? {} : { allowedModels: [...host.allowedModels] }),
            })
            await host.adopt(service, agent, projectRoot)
            return JSON.stringify({ ok: true, ...summarize(state), taskDir: service.store.dir })
          }

          if (action === 'dispute') {
            const { finding, reason } = args as { finding?: string; reason?: string }
            if (finding === undefined || reason === undefined) throw new Error('orbit: action=dispute requires finding and reason')
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            return JSON.stringify({ ok: true, dispute: await service.openDispute(finding, reason) })
          }

          if (action === 'ruling') {
            const { dispute, decision, reason } = args as { dispute?: string; decision?: 'adopt' | 'uphold'; reason?: string }
            if (dispute === undefined || decision === undefined || reason === undefined) {
              throw new Error('orbit: action=ruling requires dispute, decision and reason')
            }
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            return JSON.stringify({ ok: true, dispute: await service.ruleDispute(dispute, decision, reason) })
          }

          if (action === 'rebind') {
            const { artifactRoot, reason } = args as { artifactRoot?: string; reason?: string }
            if (artifactRoot === undefined || reason === undefined) throw new Error('orbit: action=rebind requires artifactRoot and reason')
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.rebindWorkspace({ ...workspaceInfo(artifactRoot), reason })
            return JSON.stringify({ ok: true, workspace: state.workspace })
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
        host.modelBindings.set(agent.id, {
          taskDir: task.store.dir,
          role: 'member',
          allowed: new Set(host.allowedModels),
        })
      } catch (error) {
        throw new Error(`orbit: member registration refused: ${(error as Error).message}`)
      }
    })

    // H3/H5: a stopped task's agents cannot use tools. The fence cache is
    // rebuilt from DSH_HOME at load; the durable task record remains the authority.
    // Strict model authorization: the listener must stay synchronous and
    // return next() so the stream remains iterable.
    ctx.on('llm/stream', (options, next) => {
      const sessionId = options.sessionId === undefined ? undefined : String(options.sessionId)
      const binding = sessionId === undefined ? undefined : this.modelBindings.get(sessionId)
      if (binding === undefined) return next()
      const route: ModelRoute = {
        provider: options.provider,
        model: options.model,
        ...(options.reasoningEffort === undefined ? {} : { reasoning: options.reasoningEffort }),
      }
      const decision = authorizeRoute({
        route,
        allowed: binding.allowed,
        ...(binding.role === 'member' && binding.bound !== undefined ? { bound: binding.bound } : {}),
      })
      if (!decision.ok) {
        void (async () => {
          try {
            const store = await TaskStore.open(binding.taskDir)
            await store.appendEvent('model/violation', { code: decision.code, route, message: decision.message })
          } catch {
            // The rejection still fails closed even if the audit write fails.
          }
        })()
        throw new Error(`orbit: ${decision.message}`)
      }
      binding.bound = decision.bound
      return next()
    })

    ctx.tools.guard((exec) => {
      if (exec.agent !== undefined && host.fencedSessions.has(exec.agent.id) && exec.name !== 'orbit') {
        return 'orbit: this task is stopped; tool use is fenced (the orbit tool may start a new task)'
      }
      return undefined
    })

    ctx.effect(() => ctx.root.sessionProjections.register(orbitObservationDefinition), 'orbit.observation()')

    ctx.effect(() => () => {
      for (const timer of host.jevTimers.values()) clearTimeout(timer)
      host.jevTimers.clear()
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

  /** Shared post-start wiring for start/resume/takeover. */
  private async adopt(
    service: TaskService,
    agent: NonNullable<import('@deepseek-ai/dsh-tools').ToolRunContext['agent']>,
    projectRoot: string,
  ): Promise<void> {
    this.modelBindings.set(agent.id, { taskDir: service.store.dir, role: 'root', allowed: new Set(this.allowedModels) })
    this.fencedSessions.delete(agent.id)
    saveFenceRegistry(this.fencedSessions)
    this.attachRequirements(agent, service)
    this.startJev(service, agent)
    await this.ensureControl(projectRoot).catch((error: Error) => {
      console.error(`orbit: control socket unavailable: ${error.message}`)
    })
  }

  /** First observation after the start grace period; then a fixed cadence. */
  private startJev(service: TaskService, agent: NonNullable<import('@deepseek-ai/dsh-tools').ToolRunContext['agent']>): void {
    const taskDir = service.store.dir
    this.scheduleJev(taskDir, service, agent, this.jevFirstDelayMs)
  }

  private scheduleJev(
    taskDir: string,
    service: TaskService,
    agent: NonNullable<import('@deepseek-ai/dsh-tools').ToolRunContext['agent']>,
    delayMs: number,
  ): void {
    const existing = this.jevTimers.get(taskDir)
    if (existing !== undefined) clearTimeout(existing)
    const timer = setTimeout(() => {
      this.jevTimers.delete(taskDir)
      void this.observeJev(taskDir, service, agent).finally(() => {
        this.scheduleJev(taskDir, service, agent, this.jevIntervalMs)
      })
    }, delayMs)
    timer.unref?.()
    this.jevTimers.set(taskDir, timer)
  }

  private stopJev(taskDir: string): void {
    const timer = this.jevTimers.get(taskDir)
    if (timer !== undefined) clearTimeout(timer)
    this.jevTimers.delete(taskDir)
  }

  private async observeJev(
    taskDir: string,
    service: TaskService,
    agent: NonNullable<import('@deepseek-ai/dsh-tools').ToolRunContext['agent']>,
  ): Promise<void> {
    try {
      const state = await service.state()
      if (state.status !== 'running' || state.stop !== undefined) return
      if (state.checks.inFlight !== null) return
      const credential = await this.ctx.credentials.resolve(credentialRef('TYPESAFE_API_KEY'))
      const apiKey = credential?.value
      if (apiKey === undefined || apiKey.trim().length === 0) return

      const projection = this.ctx.sessionProjections.stateOf(agent.session, 'orbitObservation')
      if (projection === undefined) return
      const window = observationWindow(projection, 0)
      const status = await service.status()
      const jobs = await this.ctx.jobs.list(agent.id)
      const running = jobs.filter((job) => job.status === 'running' || job.status === 'stopping').length
      const artifactDigest =
        status.checks.at(-1)?.artifactDigest ?? (await digestWorkspace(state.workspace.artifactRoot)).digest
      const input = {
        state,
        members: status.members,
        units: status.workUnits,
        checks: status.checks,
        findings: status.findings,
        window,
        asyncJobs: running,
        artifactDigest,
      }
      const key = jevObservationKey(input)
      const client = new TypeSafeJudgmentClient({
        apiKey,
        ...(this.jevEndpoint === undefined ? {} : { endpoint: this.jevEndpoint }),
        ...(this.jevModel === undefined ? {} : { model: this.jevModel }),
      })
      const result = await client.judge({ state: buildJevObservationState(input), questions: JEV_OBSERVATION_QUESTIONS })
      await service.store.appendEvent('jev/observation', {
        key,
        status: result.status,
        callId: result.callId,
        ...(result.status === 'answered' ? { answers: result.answers, model: result.model, usage: result.usage } : { reason: result.reason }),
      })
      if (result.status === 'answered') {
        const triggered = Object.entries(result.answers).filter(([, probability]) => probability >= this.jevThreshold)
        if (triggered.length > 0) {
          const questions = triggered.map(([id, probability]) => ({ id, probability }))
          await service.store.appendEvent('jev/signal', { key, questions })
          if (this.lastSignalKey.get(taskDir) !== key) {
            this.lastSignalKey.set(taskDir, key)
            void this.runSignalCheck(taskDir, service, agent, input, questions)
          }
        }
      }
    } catch (error) {
      await service.store.appendEvent('jev/error', { message: (error as Error).message }).catch(() => undefined)
    }
  }

  /** Strict tasks must name a checker inside the frozen list; others stay optional. */
  private strictCheckerModel(): ModelIdentity | undefined {
    if (this.allowedModels.size === 0) return this.checkerModel
    if (this.checkerModel === undefined) {
      throw new Error('orbit: a strict task requires checkerProvider/checkerModel explicitly')
    }
    if (!this.allowedModels.has(routeKey(this.checkerModel))) {
      throw new Error(`orbit: checker model ${routeKey(this.checkerModel)} is outside the frozen authorization list`)
    }
    return this.checkerModel
  }

  /** Run one signalled process check; deduped by observation key and overlap. */
  private async runSignalCheck(
    taskDir: string,
    service: TaskService,
    agent: NonNullable<import('@deepseek-ai/dsh-tools').ToolRunContext['agent']>,
    input: Parameters<typeof buildJevObservationState>[0],
    signal: Array<{ id: string; probability: number }>,
  ): Promise<void> {
    if (this.autoChecks.has(taskDir)) return
    this.autoChecks.add(taskDir)
    let number: number | undefined
    try {
      const state = await service.state()
      if (state.status !== 'running' || state.stop !== undefined) return
      if (state.checks.inFlight !== null) return
      const artifactDigest = input.artifactDigest
      const checkerModel = this.strictCheckerModel()
      const check = await service.requestCheck({
        role: 'reviewer',
        kind: 'process',
        trigger: 'auto',
        artifactDigest,
        ...(checkerModel === undefined ? {} : { model: checkerModel }),
      })
      number = check.number
      const prompt = buildProcessCheckerPrompt({
        state,
        taskDir,
        signal,
        operations: input.window.operations.map((operation) => ({
          name: operation.name,
          status: operation.status,
          target: operation.target,
          declaredIntent: operation.declaredIntent,
        })),
      })
      const raw = await runChecker({
        subagents: this.ctx.subagents,
        parent: agent,
        prompt,
        cwd: state.workspace.artifactRoot,
        signal: AbortSignal.timeout(10 * 60_000),
        ...(checkerModel === undefined ? {} : { model: checkerModel }),
      })
      const recorded = await service.recordCheckResult(check.number, raw)
      await service.store.appendEvent('jev/process-check', {
        number: check.number,
        verdict: recorded.check.result?.verdict,
        findings: recorded.check.result?.findings.length ?? 0,
      })
    } catch (error) {
      if (number !== undefined) {
        await service.failCheck(number, { kind: 'jev_process_check_error', message: (error as Error).message }).catch(() => undefined)
      }
      await service.store.appendEvent('jev/process-check-failed', { number, message: (error as Error).message }).catch(() => undefined)
    } finally {
      this.autoChecks.delete(taskDir)
    }
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
    this.stopJev(service.store.dir)
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

import { execFileSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { appendFileSync, existsSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { readdir, readFile } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import { Service, type Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-agent-loop'
import type {} from '@deepseek-ai/dsh-session'
import type {} from '@deepseek-ai/dsh-jobs'
import type {} from '@deepseek-ai/dsh-session-query'
import {
  CONTROL_SOCKET_FILE,
  JEV_OBSERVATION_QUESTIONS,
  JEV_OBSERVATION_THRESHOLD,
  TypeSafeJudgmentClient,
  TaskService,
  TaskStore,
  buildJevObservationState,
  candidateQuestions,
  checkerQuestions,
  decideChecker,
  decideDelegation,
  delegationQuestions,
  digestWorkspace,
  isOrbitError,
  loadSelectionRelease,
  planArchiveSegment,
  projectSelectionState,
  sha256Hex,
  snapshotWorkspace,
  jevObservationKey,
  type ControlRequest,
  type ModelIdentity,
  type SelectionRelease,
  type TaskState,
} from '@orbit/core'
import { ControlServer } from './control.js'
import { readHeadlessSpec, type HeadlessSpec } from './headless.js'
import { buildCheckerPrompt, buildProcessCheckerPrompt, runChecker } from './checker.js'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { observationWindow, orbitObservationDefinition } from './observation.js'
import { projectSession, unavailableSession } from './sessions-projection.js'
import { allowedSet, authorizeRoute, routeKey, type ModelRoute } from './authorization.js'

export { ControlServer } from './control.js'
export * from './profile.js'

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
  /** Candidate pool used only for advisory selection facts. */
  memberCandidates?: Array<{ label?: string; provider: string; model: string }>
  /** Optional orbit-quality-decision-4 release file; absent means facts only. */
  selectionReleaseFile?: string
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

function canonicalPolicyPath(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    try {
      return join(realpathSync(dirname(path)), basename(path))
    } catch {
      return resolve(path)
    }
  }
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
    const service = await TaskService.open(id.startsWith('/') ? id : join(TaskStore.tasksRoot(projectRoot), id)).catch(() => undefined)
    if (service === undefined) throw new Error(`orbit: unknown task ${id}`)
    return service
  }
  const latest = await findLatest(projectRoot, limit)
  if (latest === undefined) throw new Error('orbit: no task exists in this project')
  return latest
}

async function findTaskForSession(projectRoot: string, limit: number, sessionId: string): Promise<TaskService | undefined> {
  let fallback: TaskService | undefined
  for (const dir of (await taskDirs(projectRoot, limit)).reverse()) {
    let service: TaskService
    try {
      service = await TaskService.open(dir)
    } catch {
      continue
    }
    const state = await service.state()
    const members = await service.store.members().catch(() => undefined)
    const owns = state.root.sessionId === sessionId || members?.members.some((member) => member.id === sessionId) === true
    if (!owns) continue
    if (state.status === 'running') return service
    fallback ??= service
  }
  return fallback
}

function latestCheckView(check: import('@orbit/core').CheckRecord | undefined): Record<string, unknown> | null {
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
    ...(check.startedAt === undefined ? {} : { startedAt: check.startedAt }),
    ...(check.finishedAt === undefined ? {} : { finishedAt: check.finishedAt }),
    ...(check.result === undefined ? {} : { result: check.result }),
    ...(check.failure === undefined ? {} : { failure: check.failure }),
    ...(check.stale === undefined ? {} : { stale: check.stale }),
  }
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
    revision: status.state.updatedAt,
    attention: {
      phase: status.state.status === 'running'
        ? (status.state.checks.inFlight === null ? 'working' : 'checking')
        : status.state.status,
      needsUser: status.state.status === 'needs_user' || status.questions.some((question) => question.status === 'pending'),
    },
    pendingQuestions: status.questions.filter((question) => question.status === 'pending').map((question) => question.id),
    latestCheck: latestCheckView(status.checks.at(-1)),
    requirementCoverage: status.coverage.records.at(-1) ?? null,
  }
}

function summarize(state: TaskState): Record<string, unknown> {
  return {
    taskId: state.id,
    status: state.status,
    inputVersion: state.input.versions.length,
    artifactRoot: state.workspace.artifactRoot,
    projectRoot: state.projectRoot,
    rootSessionId: state.root.sessionId,
    externalRefs: state.externalRefs ?? [],
    modelAuthorization: state.authorization ?? null,
    checksInFlight: state.checks.inFlight,
    stop: state.stop?.reason,
    stopConfirmation: state.stop?.confirmation,
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
  static inject = ['tools', 'sessions', 'agents', 'agentPresets', 'systemPrompt', 'subagents', 'sessionProjections', 'credentials', 'jobs', 'sessionQuery']

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
    memberCandidates: z
      .array(z.object({ label: z.string().default(''), provider: z.string(), model: z.string() }))
      .default([]),
    selectionReleaseFile: z.string().default(''),
  })

  private readonly maxTasks: number
  private readonly subagentTool: string
  private checkerModel: ModelIdentity | undefined
  private jevEndpoint: string | undefined
  private readonly jevModel: string | undefined
  private readonly jevThreshold: number
  private readonly jevIntervalMs: number
  private readonly jevFirstDelayMs: number
  private readonly jevTimers = new Map<string, NodeJS.Timeout>()
  private readonly lastSignalKey = new Map<string, string>()
  private readonly allowedModels: Set<string>
  private readonly instanceId = randomUUID()
  private readonly activeCheckers = new Map<number, import('@deepseek-ai/dsh-subagent').SubagentActivation>()
  private readonly resumingSessions = new Set<string>()
  private headlessPolicy: import('./headless.js').HeadlessSpec['policy']
  private headlessCwd: string | undefined
  private readonly pendingQuestions = new Map<
    string,
    { resolve: (answer: { selected: string[]; custom?: string }) => void; reject: (error: Error) => void }
  >()
  private readonly memberCandidates: Array<{ label?: string; provider: string; model: string }>
  private readonly selectionRelease: SelectionRelease | undefined
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
    this.memberCandidates = [...(config.memberCandidates ?? [])]
    this.selectionRelease =
      config.selectionReleaseFile === undefined || config.selectionReleaseFile.length === 0
        ? undefined
        : (() => {
            try {
              return loadSelectionRelease(config.selectionReleaseFile as string)
            } catch (error) {
              console.error(`orbit: selection release ignored: ${(error as Error).message}`)
              return undefined
            }
          })()
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
    this.applyPersistedSettings()
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
            enum: ['start', 'status', 'stop', 'declare', 'finish', 'accept', 'reject', 'check', 'complete', 'amend', 'dispute', 'ruling', 'rebind', 'resume', 'takeover', 'takeover-scope', 'assess', 'answer'],
            description: 'start | status | stop | declare | finish | accept | reject | check | complete | amend | dispute | ruling | rebind | resume | takeover | takeover-scope | assess | answer',
          },
          instruction: { type: 'string', description: 'The user instruction, verbatim. Required for action=start.' },
          externalRefs: {
            type: 'array',
            items: { type: 'string' },
            description: 'Opaque caller references (max 8). Optional for action=start.',
          },
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
          priorScope: { type: 'string', description: 'Root-declared scope before takeover. Optional for action=takeover; declaration text for action=takeover-scope.' },
          question: { type: 'string', description: 'Question record id (or pending external id). Required for action=answer.' },
          selected: {
            type: 'array',
            items: { type: 'string' },
            description: 'Selected option labels. Required for action=answer.',
          },
          custom: { type: 'string', description: 'Optional free-text answer. Optional for action=answer.' },
          assessKind: {
            type: 'string',
            enum: ['members', 'checker'],
            description: 'Advisory selection kind. Default members.',
          },
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
        presentCall(args: unknown) {
          const action = (args as { action?: string }).action ?? 'status'
          return { card: 'generic', title: `Orbit ${action}`, kind: 'other', rawInput: action }
        },
        presentResult(args: unknown, result: { content: Array<{ type?: string; text?: string }>; isError: boolean }) {
          const action = (args as { action?: string }).action ?? 'status'
          const raw = result.content.find((block) => block.type === 'text')?.text ?? ''
          let body = raw
          try {
            const parsed = JSON.parse(raw) as Record<string, unknown>
            if (typeof parsed.error === 'string') body = `**${action} failed** · ${parsed.error}`
            else if (typeof parsed.status === 'string') {
              body = `**${String(parsed.taskId ?? parsed.id ?? 'task')}** · ${String(parsed.status)}`
              if (typeof parsed.inputVersion === 'number') body += ` · input v${parsed.inputVersion}`
              if (parsed.checksInFlight !== undefined && parsed.checksInFlight !== null) body += ` · check #${String(parsed.checksInFlight)}`
              if (typeof parsed.unit === 'object' && parsed.unit !== null && 'id' in parsed.unit) body += ` · unit ${String((parsed.unit as { id: unknown }).id)}`
            } else if (typeof parsed.verdict === 'string') {
              body = `Check ${String(parsed.checkNumber ?? '')} · ${String(parsed.verdict)}`
            }
          } catch {
            // Non-JSON results stay as their text.
          }
          return { card: 'generic', title: `Orbit ${action}`, content: [{ type: 'text', text: body }] }
        },
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
            const externalRefs = (args as { externalRefs?: string[] }).externalRefs
            const active = await host.latest(projectRoot, maxTasks)
            if (active !== undefined && (await active.state()).status === 'running') {
              throw new Error('orbit: this workspace already has a running task')
            }
            const { service, state } = await TaskService.start({
              projectRoot,
              rootSessionId: agent.id,
              instruction,
              source: { kind: 'explicit-text', verbatim: true, at: new Date().toISOString() },
              workspace: workspaceInfo(projectRoot),
              runtime: host.runtimeInfo(),
              ...((host as any).allowedModels.size === 0 ? {} : { allowedModels: [...(host as any).allowedModels] }),
              ...(externalRefs === undefined ? {} : { externalRefs }),
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
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            return JSON.stringify({ ok: true, ...(await projectStatus(service)) })
          }

          if (action === 'stop') {
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await host.beginStop(service, 50)
            return JSON.stringify({ ok: true, ...summarize(state), fence: state.stop?.fence ?? 'none', teardown: 'scheduled' })
          }

          if (action === 'check') {
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.state()
            if (state.status !== 'running') throw new Error(`orbit: cannot check a ${state.status} task`)
            const rootAgent = ctx.agents.get(state.root.sessionId as never)
            if (rootAgent === undefined) throw new Error('orbit: the Root agent is not live; cannot run an independent check')
            const kind = (args as { kind?: 'artifact' | 'process' }).kind ?? 'artifact'
            const checkerModel = host.strictCheckerModel()
            let artifactDigest: string
            let snapshotDir: string | undefined
            let checkerCwd = state.workspace.artifactRoot
            if (kind === 'artifact') {
              snapshotDir = join(service.store.dir, 'snapshots', `check-${state.checks.nextNumber}-${randomUUID().slice(0, 8)}`)
              const snapshot = await snapshotWorkspace(state.workspace.artifactRoot, snapshotDir)
              artifactDigest = snapshot.digest
              checkerCwd = snapshot.dir
            } else {
              artifactDigest = (await digestWorkspace(state.workspace.artifactRoot)).digest
            }
            await host.archiveSession(service, state.root.sessionId)
            const check = await service.requestCheck({
              role: 'reviewer',
              kind,
              trigger: 'manual',
              artifactDigest,
              ...(snapshotDir === undefined ? {} : { snapshotDir }),
              ...(checkerModel === undefined ? {} : { model: checkerModel }),
            })
            const prompt = buildCheckerPrompt({
              state,
              taskDir: service.store.dir,
              artifactDigest,
              ...(snapshotDir === undefined ? {} : { snapshotDir }),
            })
            try {
              const raw = await runChecker({
                subagents: ctx.subagents,
                parent: rootAgent,
                prompt,
                cwd: checkerCwd,
                signal: exec.signal,
                ...(checkerModel === undefined ? {} : { model: checkerModel }),
                onActivation: (activation) => host.activeCheckers.set(check.number, activation),
              }).finally(() => {
                host.activeCheckers.delete(check.number)
              })
              const recorded = await service.recordCheckResult(check.number, raw)
              await host.archiveSession(service, state.root.sessionId)
              return JSON.stringify({
                ok: true,
                checkNumber: check.number,
                finalization: recorded.finalization,
                verdict: recorded.check.result?.verdict,
                ready: recorded.check.result?.delivery.ready,
                findings: recorded.check.result?.findings.length ?? 0,
              })
            } catch (error) {
              const kind = isOrbitError(error) && error.code === 'stop_fenced' ? 'stopped' : 'checker_error'
              await service.failCheck(check.number, { kind, message: (error as Error).message }).catch(() => undefined)
              throw new Error(`orbit: independent check failed: ${(error as Error).message}`)
            }
          }

          if (action === 'amend') {
            const { amendment, messageId } = args as { amendment?: string; messageId?: string }
            if (typeof amendment !== 'string' || amendment.trim().length === 0) {
              throw new Error('orbit: action=amend requires the verbatim amendment text')
            }
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.state()
            const updated = await service.amend(amendment, {
              kind: messageId === undefined ? 'explicit-text' : 'user-message',
              ...(messageId === undefined ? {} : { messageId, sessionId: state.root.sessionId }),
              verbatim: messageId !== undefined,
              at: new Date().toISOString(),
            })
            const version = updated.input.versions.length
            const members = await service.store.members()
            const delivered: Array<{ memberId: string; messageId: string }> = []
            for (const member of members.members) {
              if (member.status !== 'registered') continue
              try {
                const messageIdSent = await ctx.subagents.sendMessage(
                  agent,
                  member.id as never,
                  [{ type: 'text', text: `Orbit amendment v${version}: ${amendment}` }],
                  { signal: exec.signal },
                )
                delivered.push({ memberId: member.id, messageId: String(messageIdSent) })
                await service.store.appendEvent('amendment/delivered', {
                  version,
                  memberId: member.id,
                  messageId: String(messageIdSent),
                })
              } catch (error) {
                await service.store.appendEvent('amendment/undelivered', {
                  version,
                  memberId: member.id,
                  reason: (error as Error).message,
                })
              }
            }
            return JSON.stringify({ ok: true, inputVersion: version, delivered })
          }

          if (action === 'complete') {
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
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
            const externalRefs = (args as { externalRefs?: string[] }).externalRefs
            const active = await host.latest(projectRoot, maxTasks)
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
              runtime: host.runtimeInfo(),
              ...((host as any).allowedModels.size === 0 ? {} : { allowedModels: [...(host as any).allowedModels] }),
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
            const externalRefs = (args as { externalRefs?: string[] }).externalRefs
            const active = await host.latest(projectRoot, maxTasks)
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
              runtime: host.runtimeInfo(),
              takeover: {
                reason,
                ...(priorScope === undefined ? {} : { priorScope }),
                ...(messageId === undefined ? {} : { messageId }),
                snapshot: { ...snapshot, at: new Date().toISOString() },
              },
              ...((host as any).allowedModels.size === 0 ? {} : { allowedModels: [...(host as any).allowedModels] }),
            })
            await host.adopt(service, agent, projectRoot)
            return JSON.stringify({ ok: true, ...summarize(state), taskDir: service.store.dir })
          }

          if (action === 'answer') {
            const { question, selected, custom } = args as { question?: string; selected?: string[]; custom?: string }
            if (question === undefined) throw new Error('orbit: action=answer requires question')
            const service = await openTask(projectRoot, maxTasks, (args as { task?: string }).task)
            const questions = await service.store.questions()
            const record = questions.questions.find((candidate) => candidate.id === question)
              ?? questions.questions.find((candidate) => candidate.externalId === question && candidate.status === 'pending')
            if (record === undefined) throw new Error(`orbit: unknown question ${question}`)
            const answered = await service.answerQuestion(record.id, { selected: selected ?? [], ...(custom === undefined ? {} : { custom }) })
            const pending = host.pendingQuestions.get(record.id)
            if (pending !== undefined) {
              host.pendingQuestions.delete(record.id)
              pending.resolve({ selected: selected ?? [], ...(custom === undefined ? {} : { custom }) })
            }
            return JSON.stringify({ ok: true, question: answered })
          }

          if (action === 'assess') {
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.state()
            if (state.status !== 'running') throw new Error(`orbit: cannot assess a ${state.status} task`)
            const credential = await ctx.credentials.resolve(credentialRef('TYPESAFE_API_KEY'))
            const apiKey = credential?.value
            if (apiKey === undefined || apiKey.trim().length === 0) {
              return JSON.stringify({ ok: false, code: 'jev_unavailable', reason: 'TYPESAFE_API_KEY is not configured' })
            }
            const status = await service.status()
            const assessKind = (args as { assessKind?: 'members' | 'checker' }).assessKind ?? 'members'
            const unit = status.workUnits.units.filter((candidate) => candidate.status === 'declared' || candidate.status === 'bound').at(-1)
            const candidates = host.memberCandidates
            const projected = projectSelectionState({
              task_context: {
                instruction: status.state.input.versions.map((version) => ({ version: version.version, text: version.text })),
                unit: unit === undefined ? null : { id: unit.id, goal: unit.goal, acceptance: unit.acceptance, scope: unit.scope },
                candidates: candidates.map((candidate) => ({ provider: candidate.provider, model: candidate.model })),
              },
              catalog_priors: [],
              exact_evidence: [],
            })
            const checkerRoute = (host as any).checkerModel
            const questions =
              assessKind === 'members'
                ? [...delegationQuestions(), ...candidateQuestions(candidates)]
                : checkerQuestions(checkerRoute === undefined ? [] : [{ model: `${checkerRoute.provider}/${checkerRoute.model}` }])
            const client = new TypeSafeJudgmentClient({
              apiKey,
              ...((host as any).jevEndpoint === undefined ? {} : { endpoint: (host as any).jevEndpoint }),
              ...(host.jevModel === undefined ? {} : { model: host.jevModel }),
            })
            const judgment = await client.judge({ state: projected as unknown as Record<string, unknown>, questions })
            if (judgment.status !== 'answered') {
              await service.store.appendEvent('jev/selection', { kind: assessKind, status: 'unavailable', reason: judgment.reason })
              return JSON.stringify({ ok: false, code: 'jev_unavailable', reason: judgment.reason })
            }
            let decision: unknown
            if (assessKind === 'members') {
              const handoff = judgment.answers.handoff_fit
              if (handoff === undefined) throw new Error('orbit: judgment is missing handoff_fit')
              decision = decideDelegation(
                {
                  handoffFit: handoff,
                  ...(judgment.answers.member_task_fit === undefined ? {} : { memberTaskFit: judgment.answers.member_task_fit }),
                  candidates: candidates.map((_, index) => ({
                    index,
                    probability: judgment.answers[`candidate_${index}_task_fit`] ?? 0,
                  })),
                },
                host.selectionRelease,
              )
            } else {
              decision = decideChecker(
                checkerRoute === undefined ? [] : [{ index: 0, probability: judgment.answers.quality_0 ?? 0 }],
                host.selectionRelease,
              )
            }
            await service.store.appendEvent('jev/selection', {
              kind: assessKind,
              status: 'answered',
              model: judgment.model,
              answers: judgment.answers,
              decision,
            })
            return JSON.stringify({ ok: true, judgment: { status: 'answered', model: judgment.model, answers: judgment.answers }, decision })
          }

          if (action === 'takeover-scope') {
            const { priorScope, reason } = args as { priorScope?: string; reason?: string }
            if (priorScope === undefined || priorScope.trim().length === 0) {
              throw new Error('orbit: action=takeover-scope requires priorScope text')
            }
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            const state = await service.appendPriorScope(priorScope, reason)
            return JSON.stringify({ ok: true, declarations: state.priorScopeDeclarations?.length ?? 0 })
          }

          if (action === 'dispute') {
            const { finding, reason } = args as { finding?: string; reason?: string }
            if (finding === undefined || reason === undefined) throw new Error('orbit: action=dispute requires finding and reason')
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            return JSON.stringify({ ok: true, dispute: await service.openDispute(finding, reason) })
          }

          if (action === 'ruling') {
            const { dispute, decision, reason } = args as { dispute?: string; decision?: 'adopt' | 'uphold'; reason?: string }
            if (dispute === undefined || decision === undefined || reason === undefined) {
              throw new Error('orbit: action=ruling requires dispute, decision and reason')
            }
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
            return JSON.stringify({ ok: true, dispute: await service.ruleDispute(dispute, decision, reason) })
          }

          if (action === 'rebind') {
            const { artifactRoot, reason } = args as { artifactRoot?: string; reason?: string }
            if (artifactRoot === undefined || reason === undefined) throw new Error('orbit: action=rebind requires artifactRoot and reason')
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
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
            const service = await host.open(projectRoot, maxTasks)
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
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
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
            const service = await host.open(projectRoot, maxTasks, (args as { task?: string }).task)
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

    ctx.tools.register(
      defineTool({
        name: 'orbit_ask',
        description:
          'Ask the Orbit supervisor a question while working as a supervised member. '
          + 'The question is recorded durably and answered by the Root or the user; '
          + 'the call waits for that answer. Only members of a running Orbit task may use this tool.',
        parameters: {
          question: { type: 'string', required: true, description: 'The question text.' },
          id: { type: 'string', description: 'Stable question id. Defaults to "q".' },
          header: { type: 'string', description: 'Optional short heading.' },
          detail: { type: 'string', description: 'Optional supporting detail.' },
          options: {
            type: 'array',
            items: { type: 'string' },
            description: 'Optional offered labels.',
          },
          multiSelect: { type: 'boolean', description: 'Whether several options may be selected.' },
        },
        output: TEXT_OUTPUT,
        presentCall() {
          return { card: 'generic', title: 'Orbit ask', kind: 'other' }
        },
        presentResult(_args: unknown, result: { content: Array<{ type?: string; text?: string }> }) {
          const raw = result.content.find((block) => block.type === 'text')?.text ?? ''
          try {
            const parsed = JSON.parse(raw) as { answers?: Array<{ id?: string; selected?: string[]; custom?: string }> }
            const first = parsed.answers?.[0]
            const answer = first === undefined ? '' : [...(first.selected ?? []), first.custom ?? ''].filter(Boolean).join(' / ')
            return { card: 'generic', title: 'Orbit ask', content: [{ type: 'text', text: answer || 'answered' }] }
          } catch {
            return { card: 'generic', title: 'Orbit ask', content: [{ type: 'text', text: raw }] }
          }
        },
        async execute(args: {
          question: string
          id?: string
          header?: string
          detail?: string
          options?: string[]
          multiSelect?: boolean
        }, exec: any): Promise<string> {
          if (exec.agent === undefined) throw new Error('orbit_ask: no calling agent')
          const projectRoot = agentCwd(ctx, exec.agent.id)
          const task = await findTaskForSession(projectRoot, maxTasks, exec.agent.id)
          if (task === undefined) throw new Error('orbit_ask is only available to members of a running Orbit task')
          const state = await task.state()
          if (state.status !== 'running' || state.stop !== undefined) throw new Error('orbit_ask: the task is stopped')
          const members = await task.store.members()
          const isMember = members.members.some((member) => member.id === exec.agent?.id)
          const isRoot = state.root.sessionId === exec.agent?.id && process.env.ORBIT_BOOTSTRAP !== undefined
          if (!isMember && !isRoot) {
            throw new Error('orbit_ask is only available to registered members or a headless Root of a running Orbit task')
          }
          const input = args as {
            question?: string
            id?: string
            header?: string
            detail?: string
            options?: string[]
            multiSelect?: boolean
          }
          if (typeof input.question !== 'string' || input.question.length === 0) throw new Error('orbit_ask requires question')
          const externalId = input.id ?? 'q'
          const record = await task.askQuestion({
            memberId: exec.agent.id,
            externalId,
            question: input.question,
            ...(input.header === undefined ? {} : { header: input.header }),
            ...(input.detail === undefined ? {} : { detail: input.detail }),
            ...(input.options === undefined
              ? {}
              : { options: input.options.map((label) => ({ label })) }),
            ...(input.multiSelect === undefined ? {} : { multiSelect: input.multiSelect }),
            source: isRoot ? 'root' : 'member',
          })
          const answer = await host.waitForAnswer(task, record.id, exec.signal)
          return JSON.stringify({
            answers: [{ id: externalId, selected: answer.selected, ...(answer.custom === undefined ? {} : { custom: answer.custom }) }],
          })
        },
      } as any),
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
      if (host.resumingSessions.delete(agent.id)) {
        host.fencedSessions.delete(agent.id)
        saveFenceRegistry(host.fencedSessions)
      } else if (host.fencedSessions.has(agent.id)) {
        throw new Error('orbit: session belongs to a stopped task')
      }
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

    // O3: member questions are recorded durably and wait for a Root/user answer.
    const questionRelay = async (
      request: {
        agent?: { id: string }
        questions: Array<{
          id: string
          question: string
          header?: string
          detail?: string
          options?: Array<{ label: string; description?: string }>
          multiSelect?: boolean
        }>
        signal?: AbortSignal
      },
      next: () => unknown,
    ) => {
      const asker = request.agent
      if (asker === undefined) return next()
      const session = ctx.sessions.get(asker.id as never)
      const projectRoot = session?.header.cwd ?? process.cwd()
      if (projectRoot === undefined) return next()
      const task = await findTaskForSession(projectRoot, maxTasks, String(asker.id)).catch(() => undefined)
      if (task === undefined) return next()
      const state = await task.state()
      if (state.status !== 'running' || state.stop !== undefined) return next()
      const members = await task.store.members()
      const isMember = members.members.some((member) => member.id === String(asker.id))
      const isRoot = state.root.sessionId === String(asker.id)
      if (!isMember && !(isRoot && process.env.ORBIT_BOOTSTRAP !== undefined)) return next()

      try {
        const answers = []
        for (const question of request.questions) {
          const record = await task.askQuestion({
            memberId: String(asker.id),
            externalId: question.id,
            question: question.question,
            ...(question.header === undefined ? {} : { header: question.header }),
            ...(question.detail === undefined ? {} : { detail: question.detail }),
            ...(question.options === undefined ? {} : { options: question.options.map((option) => ({ ...option })) }),
            ...(question.multiSelect === undefined ? {} : { multiSelect: question.multiSelect }),
            source: isRoot ? 'root' : 'member',
          })
          const answer = await host.waitForAnswer(task, record.id, request.signal)
          answers.push({ id: question.id, selected: answer.selected, ...(answer.custom === undefined ? {} : { custom: answer.custom }) })
        }
        return { answers }
      } catch (error) {
        await task.cancelPendingQuestions(String(asker.id)).catch(() => undefined)
        throw error
      }
    }

    ;(ctx.root.on as any)('user-questions/request', questionRelay)
    ;(ctx.on as any)('user-questions/request', questionRelay)

    ;(ctx as any).inject(['commands'], (commandCtx: any) => {
      const locate = async (agentId: string): Promise<TaskService | undefined> => {
        const root = agentCwd(ctx, agentId)
        return findTaskForSession(root, maxTasks, agentId).catch(() => undefined)
      }
      commandCtx.commands.register({
        definitionId: '@zeen/orbit/status' as never,
        name: 'orbit-status',
        description: 'Show the current Orbit task status',
        handler: async ({ agent }: { agent: { id: string } }) => {
          const service = await locate(agent.id)
          if (service === undefined) return { kind: 'error', text: 'No Orbit task in this workspace.' }
          const status = await service.status()
          const stop = status.state.stop?.confirmation?.confirmed === true ? 'stopped' : 'active'
          const pending = status.questions.filter((question) => question.status === 'pending').length
          return {
            kind: 'success',
            text: `${status.state.id} · ${status.state.status} (${stop}) · check in flight: ${status.state.checks.inFlight ?? 'none'} · open findings: ${status.openFindings.length} · pending questions: ${pending}`,
          }
        },
      })
      commandCtx.commands.register({
        definitionId: '@zeen/orbit/settings' as never,
        name: 'orbit-settings',
        description: 'Show Orbit model, checker and JEV settings',
        handler: async () => ({
          kind: 'success',
          text: [
            `allowed models: ${(host as any).allowedModels.size === 0 ? '(config pool)' : [...(host as any).allowedModels].join(', ')}`,
            `checker: ${(host as any).checkerProvider || '(config default)'}/${(host as any).checkerModel || '(config default)'}`,
            `JEV: ${(host as any).jevEndpoint || '(disabled)'}${(host as any).jevEndpoint === '' ? '' : ` (threshold ${(host as any).jevThreshold})`}`,
            `member candidates: ${(host as any).memberCandidates.length}`,
          ].join(' · '),
        }),
      })
      commandCtx.commands.register({
        definitionId: '@zeen/orbit/stop' as never,
        name: 'orbit-stop',
        description: 'Request a confirmed stop for the current Orbit task',
        handler: async ({ agent }: { agent: { id: string } }) => {
          const service = await locate(agent.id)
          if (service === undefined) return { kind: 'error', text: 'No Orbit task in this workspace.' }
          const state = await service.requestStop('user')
          void host.performStopLater(service)
          return { kind: 'success', text: `Stop armed for ${state.id}; confirmation follows status/stopConfirmation.` }
        },
      })
      commandCtx.commands.register({
        definitionId: '@zeen/orbit/questions' as never,
        name: 'orbit-questions',
        description: 'List pending Orbit questions',
        handler: async ({ agent }: { agent: { id: string } }) => {
          const service = await locate(agent.id)
          if (service === undefined) return { kind: 'error', text: 'No Orbit task in this workspace.' }
          const file = await service.store.questions()
          const pending = file.questions.filter((question) => question.status === 'pending')
          if (pending.length === 0) return { kind: 'success', text: 'No pending Orbit questions.' }
          return { kind: 'success', text: pending.map((question) => `${question.id}: ${question.question}`).join('\n') }
        },
      })
      commandCtx.commands.register({
        definitionId: '@zeen/orbit/answer' as never,
        name: 'orbit-answer',
        description: 'Answer a pending Orbit question by id',
        input: { hint: '<question-id> <answer>' },
        handler: async ({ agent, rawInput }: { agent: { id: string }; rawInput: string }) => {
          const service = await locate(agent.id)
          if (service === undefined) return { kind: 'error', text: 'No Orbit task in this workspace.' }
          const [questionId, ...rest] = rawInput.trim().split(/\s+/)
          if (questionId === undefined || questionId.length === 0) return { kind: 'error', text: 'Usage: /orbit-answer <question-id> <answer>' }
          const custom = rest.join(' ').trim()
          const answered = await service.answerQuestion(questionId, { selected: [], ...(custom.length === 0 ? {} : { custom }) })
          const pending = host.pendingQuestions.get(answered.id)
          if (pending !== undefined) {
            host.pendingQuestions.delete(answered.id)
            pending.resolve({ selected: [], ...(custom.length === 0 ? {} : { custom }) })
          }
          return { kind: 'success', text: `Answered ${answered.id}.` }
        },
      })
    })

    ;(ctx as any).inject(['webServer'], (webCtx: any) => {
      webCtx.effect(() => webCtx.webServer.register({
        kind: 'exact',
        path: '/orbit/api',
        handler: async (req: any, res: any) => {
          const send = (status: number, body: unknown): void => {
            res.statusCode = status
            res.setHeader('content-type', 'application/json; charset=utf-8')
            res.end(JSON.stringify(body))
          }
          try {
            const url = new URL(String(req.url), 'http://localhost')
            if (req.method === 'GET') {
              const sessionId = url.searchParams.get('session') ?? ''
              const session = ctx.sessions.get(sessionId as never)
              const projectRoot = session?.header.cwd
              if (projectRoot === undefined) return send(404, { error: 'session is not live' })
              const service = await findTaskForSession(projectRoot, maxTasks, sessionId)
              if (service === undefined) return send(404, { error: 'no Orbit task for this session' })
              const status = await service.status()
              const events = (await service.store.events()).slice(-5).map((event) => ({ seq: event.seq, type: event.type }))
              return send(200, {
                ...(await projectStatus(service)),
                config: {
                  allowedModels: [...(host as any).allowedModels],
                  checkerProvider: (host as any).checkerModel?.provider ?? '',
                  checkerModel: (host as any).checkerModel?.model ?? '',
                  jev: typeof (host as any).jevEndpoint === 'string' && (host as any).jevEndpoint.length > 0,
                  jevEndpoint: (host as any).jevEndpoint ?? '',
                  candidates: ((host as any).memberCandidates as Array<{ label?: string; provider: string; model: string }>).map((candidate) => candidate.label || `${candidate.provider}/${candidate.model}`),
                },
                recentEvents: events,
                pendingQuestions: status.questions.filter((question) => question.status === 'pending')
                  .map((question) => ({ id: question.id, question: question.question, options: question.options ?? [] })),
              })
            }
            if (req.method === 'POST') {
              if (req.headers['x-orbit-api'] !== '1') return send(403, { error: 'missing x-orbit-api' })
              const chunks: Buffer[] = []
              for await (const chunk of req) chunks.push(Buffer.from(chunk))
              const body = JSON.parse(Buffer.concat(chunks).toString('utf8')) as {
                session?: string; action?: string; question?: string; selected?: string[]; custom?: string; message?: string
              }
              const sessionId = body.session ?? ''
              const session = ctx.sessions.get(sessionId as never)
              const projectRoot = session?.header.cwd
              if (projectRoot === undefined) return send(404, { error: 'session is not live' })
              const service = await findTaskForSession(projectRoot, maxTasks, sessionId)
              if (service === undefined) return send(404, { error: 'no Orbit task for this session' })
              if (body.action === 'stop') {
                const state = await service.requestStop('user')
                void host.performStopLater(service)
                return send(200, { ok: true, taskId: state.id, status: state.status })
              }
              if (body.action === 'settings') {
                const input = body as {
                  allowedModels?: unknown; checkerProvider?: unknown; checkerModel?: unknown; jevEndpoint?: unknown
                }
                if (Array.isArray(input.allowedModels)) {
                  const models = input.allowedModels.filter((item): item is string => typeof item === 'string' && item.length > 0)
                  host.allowedModels.clear()
                  for (const model of models) host.allowedModels.add(model)
                }
                if (typeof input.checkerProvider === 'string' && typeof input.checkerModel === 'string'
                    && input.checkerProvider.length > 0 && input.checkerModel.length > 0) {
                  host.checkerModel = { provider: input.checkerProvider, model: input.checkerModel }
                }
                if (typeof input.jevEndpoint === 'string') host.jevEndpoint = input.jevEndpoint.length === 0 ? undefined : input.jevEndpoint
                host.persistSettings()
                return send(200, { ok: true, allowedModels: [...host.allowedModels], checker: host.checkerModel ?? null, jev: host.jevEndpoint ?? '' })
              }
              if (body.action === 'prompt' && typeof body.message === 'string' && body.message.length > 0) {
                const state = await service.state()
                const agent = ctx.agents.get(state.root.sessionId as never)
                if (agent === undefined) return send(409, { error: 'root session is not live' })
                const messageId = randomUUID()
                agent.followup({
                  id: messageId as never, role: 'user',
                  content: [{ type: 'text', text: body.message }],
                  source: { kind: 'user' },
                } as never)
                return send(200, { ok: true, accepted: true, taskId: state.id, messageId })
              }
              if (body.action === 'answer' && typeof body.question === 'string') {
                const selected = Array.isArray(body.selected) ? body.selected.filter((item) => typeof item === 'string') : []
                const answered = await service.answerQuestion(body.question, {
                  selected, ...(typeof body.custom === 'string' ? { custom: body.custom } : {}),
                })
                const pending = host.pendingQuestions.get(answered.id)
                if (pending !== undefined) {
                  host.pendingQuestions.delete(answered.id)
                  pending.resolve({ selected, ...(typeof body.custom === 'string' ? { custom: body.custom } : {}) })
                }
                return send(200, { ok: true, question: answered })
              }
              return send(400, { error: 'unsupported action' })
            }
            return send(405, { error: 'method not allowed' })
          } catch (error) {
            return send(500, { error: (error as Error).message })
          }
        },
      }), 'orbit api')
    })

    // Source-preparation policy: a headless task may only read under the
    // granted roots, write the declared result path, and never run bash.
    ctx.on('tools/pre-execute', async (exec, next) => {
      const denial = this.headlessDenial(exec)
      if (denial !== undefined) return { kind: 'deny', reason: denial }
      return next()
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

    if (process.env.ORBIT_BOOTSTRAP !== undefined) {
      void this.bootstrapHeadless(ctx)
    }
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
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      return { ok: true, ...(await projectStatus(service)) }
    }
    if (request.method === 'events') {
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      return { ok: true, taskId: (await service.state()).id, events: await service.store.events() }
    }
    if (request.method === 'prompt') {
      if (request.message === undefined || request.message.length === 0) throw new Error('prompt requires message')
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      const state = await service.state()
      const agent = this.ctx.agents.get(state.root.sessionId as never)
      if (agent === undefined) throw new Error('root session is not live in this host')
      const messageId = randomUUID()
      agent.followup({
        id: messageId as never,
        role: 'user',
        content: [{ type: 'text', text: request.message }],
        source: { kind: 'user' },
      } as never)
      return { ok: true, accepted: true, taskId: state.id, messageId }
    }
    if (request.method === 'abort') {
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      const state = await service.state()
      const agent = this.ctx.agents.get(state.root.sessionId as never)
      if (agent === undefined) throw new Error('root session is not live in this host')
      agent.cancel({ kind: 'user' })
      return { ok: true, taskId: state.id, scope: 'session', aborted: true }
    }
    if (request.method === 'questions') {
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      const file = await service.store.questions()
      return { ok: true, questions: file.questions }
    }
    if (request.method === 'answer') {
      if (request.question === undefined) throw new Error('answer requires question')
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      const answered = await service.answerQuestion(request.question, {
        selected: request.selected ?? [],
        ...(request.custom === undefined ? {} : { custom: request.custom }),
      })
      const pending = this.pendingQuestions.get(answered.id)
      if (pending !== undefined) {
        this.pendingQuestions.delete(answered.id)
        pending.resolve({ selected: request.selected ?? [], ...(request.custom === undefined ? {} : { custom: request.custom }) })
      }
      return { ok: true, question: answered }
    }
    if (request.method === 'sessions') {
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      const state = await service.state()
      const members = await service.store.members()
      const root = await this.projectSession(state.root.sessionId)
      const projected = []
      for (const member of members.members) {
        projected.push(await this.projectSession(member.id))
      }
      return { ok: true, as_of_seq: root.as_of_seq, root, members: projected }
    }
    if (request.method === 'stop') {
      const service = await this.open(projectRoot, this.maxTasks, request.task)
      const state = await this.beginStop(service, 0)
      return { ok: true, ...summarize(state), fence: state.stop?.fence ?? 'none' }
    }
    throw new Error(`orbit: unknown control method ${String(request.method)}`)
  }

  /** Command-bar stop: reuse the same teardown and confirmation path. */
  async performStopLater(service: TaskService): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, 0))
    await this.performStop(service)
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

  private settingsFile(): string | undefined {
    const home = process.env.DSH_HOME
    return home === undefined || home.length === 0 ? undefined : join(home, 'orbit-settings.json')
  }

  private applyPersistedSettings(): void {
    const path = this.settingsFile()
    if (path === undefined || !existsSync(path)) return
    try {
      const value = JSON.parse(readFileSync(path, 'utf8')) as {
        allowedModels?: unknown
        checkerProvider?: unknown
        checkerModel?: unknown
        jevEndpoint?: unknown
      }
      if (Array.isArray(value.allowedModels)) {
        const models = value.allowedModels.filter((item): item is string => typeof item === 'string' && item.length > 0)
        this.allowedModels.clear()
        for (const model of models) this.allowedModels.add(model)
      }
      if (typeof value.checkerProvider === 'string' && typeof value.checkerModel === 'string'
          && value.checkerProvider.length > 0 && value.checkerModel.length > 0) {
        this.checkerModel = { provider: value.checkerProvider, model: value.checkerModel }
      }
      if (typeof value.jevEndpoint === 'string') this.jevEndpoint = value.jevEndpoint.length === 0 ? undefined : value.jevEndpoint
    } catch (error) {
      console.error(`orbit: persisted settings ignored: ${(error as Error).message}`)
    }
  }

  private persistSettings(): void {
    const path = this.settingsFile()
    if (path === undefined) return
    const value = {
      allowedModels: [...this.allowedModels],
      checkerProvider: this.checkerModel?.provider ?? '',
      checkerModel: this.checkerModel?.model ?? '',
      jevEndpoint: this.jevEndpoint ?? '',
    }
    writeFileSync(path, JSON.stringify(value, null, 2), { mode: 0o600 })
  }

  private headlessDenial(exec: { name: string; arguments?: unknown }): string | undefined {
    const policy = this.headlessPolicy
    if (policy === undefined) return undefined
    const args = (exec.arguments ?? {}) as Record<string, unknown>
    const pathOf = (): string | undefined => {
      const value = args.file_path ?? args.path
      return typeof value === 'string' ? value : undefined
    }
    const inside = (candidate: string, roots: string[]): boolean => {
      let resolved: string
      try { resolved = realpathSync(candidate) } catch { resolved = resolve(candidate) }
      return roots.some((root) => resolved === root || resolved.startsWith(`${root}/`))
    }
    if (exec.name === 'bash') {
      return policy.allowBash ? undefined : 'headless policy: bash is not allowed for this preparation task'
    }
    if (exec.name === 'edit' || exec.name === 'write' || exec.name === 'apply_patch') {
      const target = pathOf()
      if (target === undefined) return 'headless policy: write without an explicit path is refused'
      const resolved = canonicalPolicyPath(target)
      if (!policy.writePaths.includes(resolved)) return `headless policy: write outside the declared result path: ${target}`
      return undefined
    }
    if (exec.name === 'read' || exec.name === 'grep' || exec.name === 'glob') {
      const target = pathOf() ?? this.headlessCwd ?? process.cwd()
      if (!inside(target, policy.readRoots)) return `headless policy: read outside the granted roots: ${target}`
      if (policy.readLog !== undefined) {
        try {
          const entry: Record<string, unknown> = {
            tool: exec.name === 'read' ? 'loom_read' : exec.name === 'grep' ? 'loom_search' : 'loom_list',
            path: target,
            at: new Date().toISOString(),
          }
          if (exec.name === 'read') {
            try {
              const bytes = readFileSync(target)
              entry.sha256 = createHash('sha256').update(bytes).digest('hex')
              entry.bytes = bytes.length
              entry.size_bytes = bytes.length
            } catch {}
          }
          if (exec.name === 'grep' && typeof args.query === 'string') entry.query = args.query
          if (exec.name === 'grep' && typeof args.pattern === 'string') entry.query = args.pattern
          appendFileSync(policy.readLog, `${JSON.stringify(entry)}\n`, { mode: 0o600 })
        } catch (error) {
          return `headless policy: cannot record the read: ${(error as Error).message}`
        }
      }
    }
    return undefined
  }

  /** Unattended Loom node: create the Root from a frozen spec, start, adopt, prompt. */
  private async bootstrapHeadless(ctx: Context): Promise<void> {
    const specPath = process.env.ORBIT_BOOTSTRAP
    const resultPath = process.env.ORBIT_BOOTSTRAP_RESULT
    const report = (value: Record<string, unknown>): void => {
      if (resultPath === undefined) return
      try {
        writeFileSync(resultPath, JSON.stringify(value), { mode: 0o600 })
      } catch (error) {
        console.error(`orbit: cannot write bootstrap result: ${(error as Error).message}`)
      }
    }
    try {
      if (specPath === undefined) throw new Error('ORBIT_BOOTSTRAP is unset')
      const spec = readHeadlessSpec(specPath)
      this.headlessPolicy = spec.policy
      if (spec.policy !== undefined) {
        this.headlessPolicy = {
          ...spec.policy,
          readRoots: spec.policy.readRoots.map((root) => realpathSync(root)),
          writePaths: spec.policy.writePaths.map(canonicalPolicyPath),
        }
      }
      let sessionId: string | undefined
      if (spec.action === 'resume') {
        const previous = await TaskService.open(join(TaskStore.tasksRoot(spec.project), spec.previousTask as string))
        sessionId = (await previous.state()).root.sessionId
      }
      if (sessionId !== undefined) this.resumingSessions.add(sessionId)
      this.headlessCwd = spec.project
      const agent = await this.createHeadlessRoot(ctx, spec, sessionId)
      const workspace = workspaceInfo(spec.project)
      const options = {
        projectRoot: spec.project,
        rootSessionId: agent.id,
        instruction: spec.instruction,
        workspace,
        runtime: this.runtimeInfo(),
        ...(spec.externalRefs.length === 0 ? {} : { externalRefs: spec.externalRefs }),
        ...(spec.allowedModels.length === 0 ? {} : { allowedModels: spec.allowedModels }),
      }
      const { service, state } = spec.action === 'resume'
        ? await TaskService.resumeFrom(join(TaskStore.tasksRoot(spec.project), spec.previousTask as string), {
            ...options,
            source: { kind: 'continuation', verbatim: true, at: new Date().toISOString() },
          })
        : await TaskService.start({
            ...options,
            source: { kind: 'explicit-text', verbatim: true, at: new Date().toISOString() },
          })
      await this.adopt(service, agent as never, spec.project)
      const instructionId = randomUUID()
      agent.followup({
        id: instructionId as never,
        role: 'user',
        content: [{ type: 'text', text: spec.instruction }],
        source: { kind: 'user' },
      } as never)
      report({
        ok: true,
        action: spec.action,
        taskId: state.id,
        sessionId: agent.id,
        messageId: instructionId,
        project: spec.project,
      })
    } catch (error) {
      const message = (error as Error).message
      console.error(`orbit: headless bootstrap failed: ${message}`)
      report({ ok: false, error: message })
    }
  }

  private async createHeadlessRoot(ctx: Context, spec: HeadlessSpec, sessionId?: string): Promise<any> {
    const c = ctx as any
    let preset: { id: string } | undefined
    for (let attempt = 0; attempt < 120 && preset === undefined; attempt += 1) {
      try {
        preset = await c.agentPresets.resolve('standard')
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 500))
      }
    }
    if (preset === undefined) throw new Error('no agent preset is registered')
    await c.agentPresets.acquireScope(preset.id)
    for (let attempt = 0; attempt < 120; attempt += 1) {
      try {
        const options = {
          agentOptions: { provider: spec.model.provider, model: spec.model.model } as never,
          setup: async (agentCtx: unknown) => {
            await c.agentPresets.mount(agentCtx, preset?.id as string)
          },
        }
        const handle = sessionId === undefined
          ? await c.agents.create({
              sessionId: randomUUID() as never,
              ...options,
              meta: { cwd: spec.project, agentPreset: preset.id },
            } as never)
          : await c.agents.resume({ resumeSessionId: sessionId as never, ...options } as never)
        return handle.agent
      } catch (error) {
        if (!String((error as Error).message).includes('no agent factory')) throw error
        await new Promise((resolve) => setTimeout(resolve, 500))
      }
    }
    throw new Error('no agent factory registered')
  }

  private runtimeInfo(): { pid: number; instanceId: string; startedAt: string } {
    return { pid: process.pid, instanceId: this.instanceId, startedAt: new Date().toISOString() }
  }

  /** Open a task and reconcile a running record owned by a dead host instance. */
  private async open(projectRoot: string, limit: number, id?: string): Promise<TaskService> {
    const service = await openTask(projectRoot, limit, id)
    await this.reconcile(service)
    return service
  }

  private async latest(projectRoot: string, limit: number): Promise<TaskService | undefined> {
    const service = await findLatest(projectRoot, limit)
    if (service !== undefined) await this.reconcile(service)
    return service
  }

  private async reconcile(service: TaskService): Promise<void> {
    try {
      const state = await service.state()
      if (state.status !== 'running' || state.runtime?.instanceId === this.instanceId) return
      const ownerPid = state.runtime?.pid
      let ownerAlive = false
      if (ownerPid !== undefined) {
        try {
          process.kill(ownerPid, 0)
          ownerAlive = true
        } catch {
          ownerAlive = false
        }
      }
      // A different live process may still own this task; never orphan it from
      // another window. Same-pid means our plugin instance was reloaded.
      if (ownerAlive && ownerPid !== process.pid) {
        console.error(`orbit: task ${state.id} is owned by live host pid ${ownerPid}; leaving it running`)
        return
      }
      await service.recoverOrphaned(this.instanceId)
    } catch (error) {
      console.error(`orbit: runtime reconciliation failed: ${(error as Error).message}`)
    }
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

  /** B layer: append only events not yet archived for one session. */
  private async archiveSession(service: TaskService, sessionId: string): Promise<void> {
    try {
      if (sessionId.includes('/') || sessionId.includes('\0')) return
      const snapshot = await this.ctx.sessionQuery.readSession(sessionId as never)
      if (snapshot === undefined) return
      const all = snapshot.events ?? []
      if (all.length === 0) return
      const directory = join(service.store.dir, 'sessions', sessionId)
      const names = await readdir(directory).catch(() => [] as string[])
      let lastArchived = 0
      for (const name of names.filter((entry) => /^seq-\d+-\d+\.json$/.test(entry))) {
        try {
          const previous = JSON.parse(await readFile(join(directory, name), 'utf8')) as { seq?: { last?: number } }
          lastArchived = Math.max(lastArchived, previous.seq?.last ?? 0)
        } catch {
          // A corrupt archive cannot lower the cursor; keep the highest valid one.
        }
      }
      const segment = planArchiveSegment(
        all.map((event) => ({ seq: event.seq as unknown as number, event })),
        lastArchived,
      )
      if (segment === undefined) return
      const payload = {
        format: 'orbit-session-archive-v2',
        capturedAt: new Date().toISOString(),
        sessionId,
        sessionVersion: snapshot.session.version ?? null,
        inheritedEventCount: snapshot.inheritedEventCount ?? 0,
        seq: { first: segment.first, last: segment.last, count: segment.count, previous_last: segment.previousLast },
        ...(segment.gap === undefined ? {} : { gap: segment.gap }),
        sha256: sha256Hex(JSON.stringify(segment.events.map((entry) => entry.event))),
        events: segment.events.map((entry) => entry.event),
      }
      await service.store.writeArchive(`sessions/${sessionId}/seq-${segment.first}-${segment.last}.json`, payload)
    } catch (error) {
      console.error(`orbit: session archive failed for ${sessionId}: ${(error as Error).message}`)
    }
  }

  private waitForAnswer(
    task: TaskService,
    questionId: string,
    signal: AbortSignal | undefined,
  ): Promise<{ selected: string[]; custom?: string }> {
    return new Promise((resolve, reject) => {
      const finish = (error: Error | undefined, answer?: { selected: string[]; custom?: string }): void => {
        this.pendingQuestions.delete(questionId)
        clearTimeout(timer)
        signal?.removeEventListener('abort', onAbort)
        if (error !== undefined) reject(error)
        else if (answer !== undefined) resolve(answer)
      }
      const onAbort = (): void => finish(new Error('question aborted'))
      const timer = setTimeout(() => finish(new Error('question answer timed out')), 10 * 60_000)
      timer.unref?.()
      signal?.addEventListener('abort', onAbort, { once: true })
      this.pendingQuestions.set(questionId, {
        resolve: (answer) => finish(undefined, answer),
        reject: (error) => finish(error),
      })
      // A CLI answer may race the registration above; check the durable state.
      void task.store.questions().then((file) => {
        const record = file.questions.find((candidate) => candidate.id === questionId)
        if (record?.status === 'answered' && record.answer !== undefined) {
          finish(undefined, record.answer)
        } else if (record?.status === 'cancelled') {
          finish(new Error('question cancelled'))
        }
      }).catch(() => undefined)
    })
  }

  /** Read-only projection for one session; unavailable after the host is gone. */
  private async projectSession(sessionId: string): Promise<ReturnType<typeof unavailableSession>> {
    try {
      const snapshot = await this.ctx.sessionQuery.readSession(sessionId as never)
      if (snapshot === undefined) return unavailableSession(sessionId)
      const session = this.ctx.sessions.get(sessionId as never)
      const observation = session === undefined ? undefined : this.ctx.sessionProjections.stateOf(session, 'orbitObservation')
      const questions = session === undefined ? undefined : this.ctx.sessionProjections.stateOf(session, 'userQuestions' as never)
      return projectSession(snapshot as never, observation, questions)
    } catch {
      return unavailableSession(sessionId)
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
        onActivation: (activation) => this.activeCheckers.set(check.number, activation),
      }).finally(() => {
        this.activeCheckers.delete(check.number)
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

      await service.cancelPendingQuestions().catch(() => undefined)
      for (const pending of this.pendingQuestions.values()) pending.reject(new Error('task stopped'))
      this.pendingQuestions.clear()

      for (const [number, activation] of this.activeCheckers) {
        await activation.dispose().catch(() => undefined)
        this.activeCheckers.delete(number)
        const current = await service.state()
        if (current.checks.inFlight === number) {
          await service.failCheck(number, { kind: 'stopped', message: 'checker disposed by task stop' }).catch(() => undefined)
        }
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
      await this.archiveSession(service, state.root.sessionId)
      for (const member of members.members) await this.archiveSession(service, member.id)
    } catch (error) {
      // Never fabricate confirmation: a failed teardown leaves the durable stop
      // record unconfirmed for a later explicit retry.
      console.error(`orbit: stop teardown failed: ${(error as Error).message}`)
    }
  }
}

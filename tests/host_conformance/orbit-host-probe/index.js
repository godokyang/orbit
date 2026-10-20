// Orbit DSH host T1 probe: real agent loop, scripted fake model. Drives start,
// declare, a controlled subagent dispatch (H4 registration), stop fence and a
// denied second dispatch. No real model, no network.
import { appendFileSync, mkdirSync, readdirSync, readFileSync, existsSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { promisify } from 'node:util'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { LlmAdapter } from '@deepseek-ai/dsh-llm'

export const name = 'orbit-host-probe'
export const inject = ['llm', 'agents', 'sessions', 'tools', 'sessionQuery', 'sessionProjections']

const HOME = process.env.DSH_HOME
const WORK = join(HOME, 'project')
const OUT = process.env.ORBIT_PROBE_OUT || '/dev/stderr'

const log = (record) => appendFileSync(OUT, JSON.stringify({ t: new Date().toISOString(), ...record }) + '\n')
const execFileAsync = promisify(execFile)
async function cli(args) {
  const { stdout } = await execFileAsync(process.execPath, [process.env.ORBIT_CLI, ...args], {
    cwd: WORK,
    encoding: 'utf8',
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  })
  return stdout
}
const short = (error) => String(error && (error.stack || error.message || error)).split('\n').slice(0, 3).join(' | ').slice(0, 500)
const msg = (text) => ({ id: randomUUID(), role: 'user', content: [{ type: 'text', text }], source: { kind: 'user' } })

function textChunks(text) {
  return [
    { type: 'block-start', index: 0, blockType: 'text' },
    { type: 'text-delta', index: 0, text },
    { type: 'block-end', index: 0, block: { type: 'text', text } },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'stop' } },
  ]
}
function toolChunks(toolName, args) {
  const id = `call-${randomUUID().slice(0, 8)}`
  const argsText = JSON.stringify(args)
  return [
    { type: 'block-start', index: 0, blockType: 'tool-call' },
    { type: 'tool-call-delta', index: 0, id, name: toolName, argumentsDelta: argsText },
    { type: 'block-end', index: 0, block: { type: 'tool-call', id, name: toolName, arguments: argsText } },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'tool-calls' } },
  ]
}

const scripts = []
const calls = []
let jevServer

function startJevServer() {
  return new Promise((resolve, reject) => {
    jevServer = createServer((request, response) => {
      let body = ''
      request.setEncoding('utf8')
      request.on('data', (chunk) => { body += chunk })
      request.on('end', () => {
        let ids = []
        try {
          const parsed = JSON.parse(body)
          ids = Array.isArray(parsed.questions) ? parsed.questions.map((question) => question.id) : []
        } catch {}
        const answers = ids.includes('handoff_fit')
          ? { handoff_fit: { noul: 0.9 }, member_task_fit: { noul: 0.8 }, candidate_0_task_fit: { noul: 0.7 } }
          : { stuck: { noul: 0.9 }, off_track: { noul: 0.1 } }
        response.writeHead(200, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ model: 'jev-probe', answers, usage: { input_tokens: 20, output_tokens: 2 } }))
      })
    })
    jevServer.once('error', reject)
    jevServer.listen(3987, '127.0.0.1', () => resolve())
  })
}
class ProbeAdapter extends LlmAdapter {
  providerInfo(provider) { return { id: provider, provider, name: 'Orbit probe', displayName: 'Orbit probe' } }
  async listModels(provider) { return [{ id: 'probe-1', provider, model: 'probe-1', name: 'probe-1', displayName: 'probe-1' }] }
  async resolveModel(provider, model) { return { provider, id: model, name: model, model, context: { contextWindow: 100000 } } }
  async *stream(options) {
    const serialized = JSON.stringify(options)
    calls.push({
      sawOrbitContext: serialized.includes('Orbit 受控任务') && serialized.includes('Build the migration slice.'),
      sawAmendment: serialized.includes('Also cover the CLI.'),
    })
    const script = scripts.shift()
    yield* script ? script() : textChunks('ok')
  }
}

function tasksRoot(project) { return join(project, '.orbit', 'tasks') }
function taskDirs(project) {
  const root = tasksRoot(project)
  if (!existsSync(root)) return []
  return readdirSync(root).filter((entry) => !entry.startsWith('.')).sort().map((entry) => join(root, entry))
}
function readChecks(task) {
  const dir = join(task.dir, 'checks')
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((entry) => entry.endsWith('.json'))
    .map((entry) => JSON.parse(readFileSync(join(dir, entry), 'utf8')))
    .sort((a, b) => a.number - b.number)
}

function readTask(project) {
  for (const dir of taskDirs(project).reverse()) {
    const stateFile = join(dir, 'state.json')
    const unitsFile = join(dir, 'work-units.json')
    const membersFile = join(dir, 'members.json')
    if (!existsSync(stateFile)) continue
    try {
      return {
        dir,
        state: JSON.parse(readFileSync(stateFile, 'utf8')),
        units: existsSync(unitsFile) ? JSON.parse(readFileSync(unitsFile, 'utf8')) : { units: [] },
        members: existsSync(membersFile) ? JSON.parse(readFileSync(membersFile, 'utf8')) : { members: [] },
      }
    } catch {}
  }
  return undefined
}
async function waitFor(fn, timeoutMs, label) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    const value = await fn().catch(() => undefined)
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  throw new Error(`timeout waiting for ${label}`)
}
async function toolResults(ctx, sessionId) {
  const snapshot = await ctx.sessionQuery.readSession(sessionId).catch(() => undefined)
  return (snapshot?.events ?? [])
    .filter((event) => (event.event?.type ?? event.type) === 'tool/result')
    .map((event) => {
      const data = event.event?.data ?? event.data ?? {}
      return { isError: data.message?.isError, text: JSON.stringify(data.message?.content ?? data).slice(0, 400) }
    })
}

async function turn(handle, ctx, text, script) {
  if (script) scripts.push(script)
  handle.agent.followup(msg(text))
  await handle.agent.whenIdle()
  return toolResults(ctx, handle.agent.id)
}

async function run(ctx) {
  mkdirSync(WORK, { recursive: true })
  ctx.llm.registerAdapter(['probe'], new ProbeAdapter())

  const handle = await ctx.agents.create({
    sessionId: randomUUID(),
    agentOptions: { provider: 'probe', model: 'probe-1' },
    meta: { cwd: WORK },
  })
  log({ step: 'agent-created', sessionId: handle.agent.id, cwd: WORK })

  scripts.push(() => toolChunks('orbit', { action: 'start', instruction: 'Build the migration slice.' }))
  scripts.push(() => textChunks('started'))
  handle.agent.followup(msg('Please start an Orbit task for the slice.'))
  await handle.agent.whenIdle()
  let task = readTask(WORK)
  log({ step: 'start', taskId: task?.state?.id, status: task?.state?.status, instruction: task?.state?.input?.versions?.[0]?.text })

  const cliStatus = JSON.parse(await cli(['status', '--json', '--project', WORK]))
  log({ step: 'cli-status', source: 'socket', taskId: cliStatus.taskId, status: cliStatus.status })
  const cliEvents = JSON.parse(await cli(['events', '--json', '--project', WORK]))
  log({ step: 'cli-events', count: cliEvents.events?.length })

  // Amendment: the durable version becomes v2 and the next admission sees it.
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'amend', amendment: 'Also cover the CLI.', messageId: 'msg-amend-1' }))
  scripts.push(() => textChunks('amended'))
  handle.agent.followup(msg('Amend the requirement.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  log({ step: 'amend', inputVersion: task?.state?.input?.versions?.length, versions: task?.state?.input?.versions?.map((v) => v.version) })

  scripts.push(() => toolChunks('orbit', { action: 'declare', goal: 'Implement slice', acceptance: 'Tests pass', dependencies: [] }))
  scripts.push(() => textChunks('declared'))
  handle.agent.followup(msg('Declare the work unit.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  const unit = task?.units?.units?.[0]
  log({ step: 'declare', unitId: unit?.id, unitStatus: unit?.status, inputVersion: unit?.inputVersion })

  await new Promise((resolve) => setTimeout(resolve, 2200))
  task = readTask(WORK)
  const events = readFileSync(join(task.dir, 'events.jsonl'), 'utf8').trim().split('\n').map((line) => JSON.parse(line))
  const jevEvents = events.filter((event) => String(event.type).startsWith('jev/'))
  log({
    step: 'jev',
    events: jevEvents.map((event) => event.type),
    answers: jevEvents.find((event) => event.type === 'jev/observation')?.data?.answers,
    signal: jevEvents.find((event) => event.type === 'jev/signal')?.data,
  })

  await waitFor(async () => (readTask(WORK)?.state?.checks?.inFlight === null ? true : undefined), 15000, 'auto check settle').catch(() => undefined)
  task = readTask(WORK)
  const autoCheck = readChecks(task).find((check) => check.kind === 'process' && check.trigger === 'auto')
  log({
    step: 'jev-auto-check',
    number: autoCheck?.number,
    kind: autoCheck?.kind,
    trigger: autoCheck?.trigger,
    status: autoCheck?.status,
    verdict: autoCheck?.result?.verdict,
  })

  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'assess', assessKind: 'members' }))
  scripts.push(() => textChunks('assessed'))
  handle.agent.followup(msg('Assess member candidates.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  const selectionEvent = readFileSync(join(task.dir, 'events.jsonl'), 'utf8')
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line))
    .filter((event) => event.type === 'jev/selection')
    .at(-1)
  log({ step: 'assess', status: selectionEvent?.data?.status, decision: selectionEvent?.data?.decision })

  const observation = ctx.sessionProjections.stateOf(handle.agent.session, 'orbitObservation')
  log({
    step: 'observation',
    operations: observation?.operations?.length,
    activeTools: observation?.activeTools,
    lastTurnStatus: observation?.lastTurnStatus,
    last: observation?.operations?.at(-1)?.name,
    lastTarget: observation?.operations?.at(-1)?.target,
  })

  // Process check first: it must never create a finalization notice.
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'check', kind: 'process' }))
  scripts.push(() => textChunks('process checked'))
  handle.agent.followup(msg('Run a process check.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  const processCheck = readChecks(task).filter((check) => check.kind === 'process' && check.trigger === 'manual').at(-1)
  log({
    step: 'process-check',
    checkStatus: processCheck?.status,
    kind: processCheck?.kind,
    verdict: processCheck?.result?.verdict,
    finalization: Boolean(task?.state?.finalization),
  })

  // Artifact check through the dsh-sdk child process.
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'check', kind: 'artifact' }))
  scripts.push(() => textChunks('checked'))
  handle.agent.followup(msg('Run the independent artifact check.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  const check = readChecks(task).filter((candidate) => candidate.kind === 'artifact').at(-1)
  const archiveDir = join(task.dir, 'sessions', handle.agent.id)
  const archiveFiles = existsSync(archiveDir) ? readdirSync(archiveDir).filter((entry) => entry.endsWith('.json')) : []
  const archives = archiveFiles.map((entry) => JSON.parse(readFileSync(join(archiveDir, entry), 'utf8')))
  const checkResults = await toolResults(ctx, handle.agent.id)
  log({
    step: 'archive',
    segments: archives.length,
    seqRanges: archives.map((archive) => archive.seq),
    gaps: archives.filter((archive) => archive.gap !== undefined).map((archive) => archive.gap),
    totalEvents: archives.reduce((sum, archive) => sum + (archive.seq?.count ?? 0), 0),
    digest: archives.at(-1)?.sha256?.slice(0, 12),
  })
  log({
    step: 'check',
    checkNumber: check?.number,
    checkStatus: check?.status,
    snapshotDir: check?.snapshotDir,
    snapshotExists: check?.snapshotDir ? existsSync(check.snapshotDir) : false,
    verdict: check?.result?.verdict,
    ready: check?.result?.delivery?.ready,
    coverageComplete: check?.result?.coverage?.complete,
    finalization: Boolean(task?.state?.finalization),
    last: checkResults.at(-1),
  })

  // Controlled dispatch: fake Root calls subagent with the unit reference.
  scripts.push(() => toolChunks('subagent', {
    description: 'implement slice',
    prompt: `Implement the slice.\norbit-unit: ${unit?.id}`,
    cwd: WORK,
  }))
  scripts.push(() => textChunks('child finished'))
  scripts.push(() => textChunks('root saw child'))
  handle.agent.followup(msg('Delegate the slice to a member.'))
  await handle.agent.whenIdle()
  const dispatchResults = await toolResults(ctx, handle.agent.id)
  log({ step: 'dispatch-turn', last: dispatchResults.at(-1) })
  const registered = await waitFor(async () => {
    const current = readTask(WORK)
    const member = current?.members?.members?.[0]
    return member ? { member, current } : undefined
  }, 10000, 'member registration')
  log({ step: 'member', id: registered.member.id, status: registered.member.status, unitId: registered.member.workUnitId, model: registered.member.model })
  const results = await toolResults(ctx, handle.agent.id)
  log({ step: 'dispatch-result', last: results.at(-1) })

  // Let the child settle, then finish/accept the unit and request completion.
  await new Promise((resolve) => setTimeout(resolve, 1200))
  log({ step: 'child-status', status: ctx.agents.get(registered.member.id)?.status })
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'finish', unit: unit?.id, outcome: 'completed', summary: 'probe worker delivered' }))
  scripts.push(() => textChunks('finished'))
  handle.agent.followup(msg('Finish the member unit.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  log({
    step: 'finish',
    unitStatus: task?.units?.units?.[0]?.status,
    memberStatus: task?.members?.members?.[0]?.status,
  })

  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'accept', unit: unit?.id }))
  scripts.push(() => textChunks('accepted'))
  handle.agent.followup(msg('Accept the unit.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  log({ step: 'accept', unitStatus: task?.units?.units?.[0]?.status })

  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'complete' }))
  handle.agent.followup(msg('Complete the task.'))
  await handle.agent.whenIdle()
  task = await waitFor(async () => {
    const current = readTask(WORK)
    return current?.state?.status !== 'running' ? current : undefined
  }, 15000, 'completion confirmation').catch(() => readTask(WORK))
  log({
    step: 'complete',
    status: task?.state?.status,
    stop: task?.state?.stop?.reason,
    confirmed: task?.state?.stop?.confirmation?.confirmed,
    missing: task?.state?.stop?.confirmation?.missing,
    completion: task?.state?.completion,
    invalidation: task?.state?.completionInvalidation,
  })

  scripts.length = 0
  const beforeFence = (await toolResults(ctx, handle.agent.id)).length
  scripts.push(() => toolChunks('subagent', { description: 'late', prompt: `Late work.\norbit-unit: ${unit?.id}`, cwd: WORK }))
  scripts.push(() => textChunks('after denial'))
  handle.agent.followup(msg('Try one more dispatch.'))
  await handle.agent.whenIdle()
  const after = await toolResults(ctx, handle.agent.id)
  log({ step: 'fenced-dispatch', newResults: after.length - beforeFence, last: after.at(-1) })

  const exportPath = join(HOME, 'results', 'export.json')
  const exportOut = await cli(['export', '--output', exportPath, '--project', WORK])
  const exported = JSON.parse(readFileSync(exportPath, 'utf8'))
  log({ step: 'cli-export', output: exportOut.trim(), taskId: exported.taskId, files: Object.keys(exported.files).length, versions: exported.state?.input?.versions?.length })

  // A stopped session may start a fresh task; the old fence must not block it.
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'start', instruction: 'Second supervised task.' }))
  scripts.push(() => textChunks('second started'))
  handle.agent.followup(msg('Start a second task.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  log({ step: 'new-task-after-stop', taskId: task?.state?.id, status: task?.state?.status })
  const stopSecond = JSON.parse(await cli(['stop', '--json', '--project', WORK]))
  log({ step: 'cli-stop-second', taskId: stopSecond.taskId, status: stopSecond.status, fence: stopSecond.fence })
  const secondState = await waitFor(async () => {
    const current = readTask(WORK)
    return current?.state?.status !== 'running' ? current : undefined
  }, 12000, 'second stop confirmation').catch(() => readTask(WORK))
  log({ step: 'second-stop', status: secondState?.state?.status, confirmed: secondState?.state?.stop?.confirmation?.confirmed })

  // Resume the paused second task, then stop the continuation.
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'resume', from: secondState?.state?.id, instruction: 'Continue the second task.' }))
  scripts.push(() => textChunks('resumed'))
  handle.agent.followup(msg('Resume the stopped task.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  log({
    step: 'resume',
    taskId: task?.state?.id,
    versions: task?.state?.input?.versions?.map((version) => version.version),
    continuation: task?.state?.continuation,
  })
  await cli(['stop', '--json', '--project', WORK])
  await waitFor(async () => (readTask(WORK)?.state?.status !== 'running' ? true : undefined), 12000, 'resume stop').catch(() => undefined)

  // Take over work that already exists, recording scope and a snapshot.
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'takeover', instruction: 'Take over the existing work.', reason: 'probe takeover', priorScope: 'partial' }))
  scripts.push(() => textChunks('took over'))
  handle.agent.followup(msg('Take over the existing work.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  log({
    step: 'takeover',
    taskId: task?.state?.id,
    reason: task?.state?.takeover?.reason,
    priorScope: task?.state?.takeover?.priorScope,
    snapshot: task?.state?.takeover?.snapshot,
  })
  scripts.length = 0
  scripts.push(() => toolChunks('orbit', { action: 'takeover-scope', priorScope: 'Existing edits in src were pre-supervision.' }))
  scripts.push(() => textChunks('scope declared'))
  handle.agent.followup(msg('Declare the pre-supervision scope.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  log({
    step: 'takeover-scope',
    count: task?.state?.priorScopeDeclarations?.length,
    last: task?.state?.priorScopeDeclarations?.at(-1),
  })

  await cli(['stop', '--json', '--project', WORK])
  await waitFor(async () => (readTask(WORK)?.state?.status !== 'running' ? true : undefined), 12000, 'takeover stop').catch(() => undefined)

  await handle.dispose()
  if (jevServer !== undefined) await new Promise((resolve) => jevServer.close(() => resolve()))
  log({
    phase: 'done',
    ok: true,
    taskCreated: Boolean(task),
    unitId: unit?.id,
    memberRegistered: Boolean(registered),
    modelCalls: calls.length,
    callsWithOrbitContext: calls.filter((call) => call.sawOrbitContext).length,
    callsWithAmendment: calls.filter((call) => call.sawAmendment).length,
  })
}

export async function apply(ctx) {
  log({ phase: 'start', pid: process.pid, node: process.version })
  try {
    await startJevServer()
    log({ phase: 'jev-server', port: 3987 })
  } catch (error) {
    log({ phase: 'jev-server-error', message: short(error) })
  }
  try {
    await run(ctx)
  } catch (error) {
    log({ phase: 'error', message: short(error) })
  } finally {
    setTimeout(() => { try { ctx.appExit(0) } catch {} }, 300)
    setTimeout(() => process.exit(0), 8000)
  }
}

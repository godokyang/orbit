// Orbit DSH host T1 probe: real agent loop, scripted fake model. Drives start,
// declare, a controlled subagent dispatch (H4 registration), stop fence and a
// denied second dispatch. No real model, no network.
import { appendFileSync, mkdirSync, readdirSync, readFileSync, existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { LlmAdapter } from '@deepseek-ai/dsh-llm'

export const name = 'orbit-host-probe'
export const inject = ['llm', 'agents', 'sessions', 'tools', 'sessionQuery']

const HOME = process.env.DSH_HOME
const WORK = join(HOME, 'project')
const OUT = process.env.ORBIT_PROBE_OUT || '/dev/stderr'

const log = (record) => appendFileSync(OUT, JSON.stringify({ t: new Date().toISOString(), ...record }) + '\n')
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
class ProbeAdapter extends LlmAdapter {
  providerInfo(provider) { return { id: provider, provider, name: 'Orbit probe', displayName: 'Orbit probe' } }
  async listModels(provider) { return [{ id: 'probe-1', provider, model: 'probe-1', name: 'probe-1', displayName: 'probe-1' }] }
  async resolveModel(provider, model) { return { provider, id: model, name: model, model, context: { contextWindow: 100000 } } }
  async *stream() {
    const script = scripts.shift()
    yield* script ? script() : textChunks('ok')
  }
}

function tasksRoot(project) { return join(project, '.orbit', 'tasks') }
function taskDirs(project) {
  const root = tasksRoot(project)
  if (!existsSync(root)) return []
  return readdirSync(root).filter((entry) => !entry.startsWith('.')).map((entry) => join(root, entry))
}
function readTask(project) {
  for (const dir of taskDirs(project)) {
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

  scripts.push(() => toolChunks('orbit', { action: 'declare', goal: 'Implement slice', acceptance: 'Tests pass', dependencies: [] }))
  scripts.push(() => textChunks('declared'))
  handle.agent.followup(msg('Declare the work unit.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  const unit = task?.units?.units?.[0]
  log({ step: 'declare', unitId: unit?.id, unitStatus: unit?.status, inputVersion: unit?.inputVersion })

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

  // Let the child settle and drop any unscripted leftovers before the stop turn.
  await new Promise((resolve) => setTimeout(resolve, 1200))
  log({ step: 'child-status', status: ctx.agents.get(registered.member.id)?.status })
  scripts.length = 0
  const beforeStop = (await toolResults(ctx, handle.agent.id)).length
  scripts.push(() => toolChunks('orbit', { action: 'stop' }))
  scripts.push(() => textChunks('stopped'))
  handle.agent.followup(msg('Stop the task.'))
  await handle.agent.whenIdle()
  task = readTask(WORK)
  const stopResults = await toolResults(ctx, handle.agent.id)
  log({ step: 'stop', status: task?.state?.status, stop: task?.state?.stop?.reason, fence: task?.state?.stop?.fence, newResults: stopResults.length - beforeStop, last: stopResults.at(-1) })

  scripts.length = 0
  const beforeFence = stopResults.length
  scripts.push(() => toolChunks('subagent', { description: 'late', prompt: `Late work.\norbit-unit: ${unit?.id}`, cwd: WORK }))
  scripts.push(() => textChunks('after denial'))
  handle.agent.followup(msg('Try one more dispatch.'))
  await handle.agent.whenIdle()
  const after = await toolResults(ctx, handle.agent.id)
  log({ step: 'fenced-dispatch', newResults: after.length - beforeFence, last: after.at(-1) })

  await handle.dispose()
  log({ phase: 'done', ok: true, taskCreated: Boolean(task), unitId: unit?.id, memberRegistered: Boolean(registered) })
}

export async function apply(ctx) {
  log({ phase: 'start', pid: process.pid, node: process.version })
  try {
    await run(ctx)
  } catch (error) {
    log({ phase: 'error', message: short(error) })
  } finally {
    setTimeout(() => { try { ctx.appExit(0) } catch {} }, 300)
    setTimeout(() => process.exit(0), 8000)
  }
}

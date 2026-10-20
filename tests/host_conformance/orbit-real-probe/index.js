// Real-model acceptance driver. Runs inside the controlled app profile, creates
// a Root agent on the desktop account route, and asks it to drive one task
// through start → declare → write → check → finish/accept → complete.
import { appendFileSync, mkdirSync, readdirSync, readFileSync, existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'

export const name = 'orbit-real-driver'
export const inject = ['agents', 'sessions', 'agentPresets']

const HOME = process.env.DSH_HOME
const WORK = join(HOME, 'real-project')
const OUT = process.env.ORBIT_REAL_OUT || join(HOME, 'results', 'real.out')
mkdirSync(join(HOME, 'results'), { recursive: true })

function log(record) {
  appendFileSync(OUT, JSON.stringify({ t: new Date().toISOString(), ...record }) + '\n')
}
function msg(text) {
  return { id: randomUUID(), role: 'user', content: [{ type: 'text', text }], source: { kind: 'user' } }
}
function latestTask() {
  const root = join(WORK, '.orbit', 'tasks')
  if (!existsSync(root)) return undefined
  const dirs = readdirSync(root).filter((entry) => !entry.startsWith('.')).sort().reverse()
  for (const entry of dirs) {
    const file = join(root, entry, 'state.json')
    if (!existsSync(file)) continue
    try {
      return { dir: join(root, entry), state: JSON.parse(readFileSync(file, 'utf8')) }
    } catch {}
  }
  return undefined
}
function checksOf(task) {
  const dir = join(task.dir, 'checks')
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((entry) => entry.endsWith('.json'))
    .map((entry) => JSON.parse(readFileSync(join(dir, entry), 'utf8')))
    .sort((a, b) => a.number - b.number)
}

function promptText() {
  return `You are running a controlled Orbit acceptance task. Do exactly these steps with tools and do not ask the user anything.

1. Call the orbit tool with {"action":"start","instruction":"Create hello.txt in the workspace containing the word hello."}
2. Call the orbit tool with {"action":"declare","goal":"write hello.txt","acceptance":"hello.txt exists and contains hello"}.
3. Call the write tool with {"file_path":"${join(WORK, 'hello.txt')}","content":"hello"}.
4. Call the orbit tool with {"action":"check"}.
5. From the declare result, take the work unit id (wu-...). Call the orbit tool with {"action":"finish","unit":"<the unit id>","outcome":"completed","summary":"wrote hello.txt"}.
6. Call the orbit tool with {"action":"accept","unit":"<the same unit id>"}.
7. Call the orbit tool with {"action":"complete"}.
Then reply with one short sentence summarizing the result.`
}

let presetScope

async function resolvePreset(ctx) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      return await ctx.agentPresets.resolve('standard')
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 500))
    }
  }
  const presets = await ctx.agentPresets.list()
  log({ step: 'preset-list', ids: presets.map((preset) => preset.id) })
  const fallback = presets.find((preset) => preset.id === 'standard') ?? presets[0]
  if (fallback === undefined) throw new Error('no agent preset is registered')
  return fallback
}

async function createRoot(ctx) {
  let lastError
  const preset = await resolvePreset(ctx)
  log({ step: 'preset', id: preset.id })
  presetScope = await ctx.agentPresets.acquireScope(preset.id)
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      return await ctx.agents.create({
        sessionId: randomUUID(),
        agentOptions: { provider: 'deepseek-account', model: 'deepseek-flash' },
        meta: { cwd: WORK, agentPreset: preset.id },
        setup: async (agentCtx) => {
          await ctx.agentPresets.mount(agentCtx, preset.id)
        },
      })
    } catch (error) {
      lastError = error
      if (!String(error && error.message).includes('no agent factory')) throw error
      await new Promise((resolve) => setTimeout(resolve, 500))
    }
  }
  throw lastError
}

async function run(ctx) {
  mkdirSync(WORK, { recursive: true })
  mkdirSync(join(HOME, 'results'), { recursive: true })
  const handle = await createRoot(ctx)
  log({ step: 'root-created', sessionId: handle.agent.id })
  handle.agent.followup(msg(promptText()))
  const timeout = new Promise((resolve) => setTimeout(() => resolve('timeout'), 300_000))
  let finished = await Promise.race([handle.agent.whenIdle().then(() => 'idle'), timeout])
  log({ step: 'root-idle', round: 0, finished })

  for (let round = 1; round <= 2; round += 1) {
    const current = latestTask()
    if (current === undefined || current.state.status !== 'running') break
    const checks = checksOf(current)
    const last = checks.at(-1)
    if (last?.result?.delivery?.ready === true) break
    const reason = last?.result?.reason ?? 'no independent check has run yet'
    handle.agent.followup(msg(
      `The independent check did not pass: ${reason}. Correct it now: create ${join(WORK, 'hello.txt')} with content hello, then call orbit check again, then finish/accept the unit and call orbit complete. Do not ask questions.`,
    ))
    finished = await Promise.race([handle.agent.whenIdle().then(() => 'idle'), timeout])
    log({ step: 'root-idle', round, finished })
  }

  const task = latestTask()
  log({
    step: 'task',
    taskId: task?.state?.id,
    status: task?.state?.status,
    inputVersion: task?.state?.input?.versions?.length,
    members: task?.state?.members?.length,
    checks: task ? checksOf(task).map((check) => ({ number: check.number, kind: check.kind, status: check.status, verdict: check.result?.verdict })) : [],
    completion: task?.state?.completion,
  })
  await handle.dispose().catch(() => undefined)
  await presetScope?.dispose?.().catch?.(() => undefined)
}

export async function apply(ctx) {
  log({ phase: 'start', pid: process.pid, node: process.version })
  try {
    await run(ctx)
    log({ phase: 'done' })
  } catch (error) {
    log({ phase: 'error', message: String(error && (error.stack || error.message || error)).slice(0, 1000) })
  } finally {
    setTimeout(() => { try { ctx.appExit(0) } catch {} }, 300)
    setTimeout(() => process.exit(0), 8000)
  }
}

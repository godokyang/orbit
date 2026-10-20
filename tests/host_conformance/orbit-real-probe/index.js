// Real-model acceptance driver. Runs inside the controlled app profile, creates
// a Root agent on the desktop account route, and asks it to drive one task
// through start → declare → write → check → finish/accept → complete.
import { appendFileSync, mkdirSync, readdirSync, readFileSync, existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { connect } from 'node:net'
import { execSync } from 'node:child_process'

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

const SCENARIO = process.env.ORBIT_REAL_SCENARIO ?? 'clean'
const INITIAL_CONTENT = SCENARIO === 'correction' ? 'goodbye' : 'hello'

function promptText() {
  return `You are running a controlled Orbit acceptance task. Do exactly these steps with tools and do not ask the user anything.

1. Call the orbit tool with {"action":"start","instruction":"Create hello.txt in the workspace containing the word hello."}
2. Call the orbit tool with {"action":"declare","goal":"write hello.txt","acceptance":"hello.txt exists and contains hello"}.
3. Call the write tool with {"file_path":"${join(WORK, 'hello.txt')}","content":"${INITIAL_CONTENT}"}.
4. Call the orbit tool with {"action":"check"}. If the check is not ready, read the finding, write ${join(WORK, 'hello.txt')} again with content hello, and call orbit check again.
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

function stopViaSocket() {
  return new Promise((resolve, reject) => {
    const socket = connect(join(WORK, '.orbit', 'orbit.sock'))
    let buffer = ''
    socket.setEncoding('utf8')
    socket.once('connect', () => socket.write(JSON.stringify({ id: randomUUID(), method: 'stop' }) + '\n'))
    socket.on('data', (chunk) => {
      buffer += chunk
      const index = buffer.indexOf('\n')
      if (index >= 0) {
        socket.destroy()
        resolve(JSON.parse(buffer.slice(0, index)))
      }
    })
    socket.once('error', reject)
    setTimeout(() => reject(new Error('stop socket timeout')), 5000)
  })
}

async function runStop(ctx) {
  mkdirSync(WORK, { recursive: true })
  mkdirSync(join(HOME, 'results'), { recursive: true })
  const handle = await createRoot(ctx)
  log({ step: 'root-created', sessionId: handle.agent.id, scenario: 'stop' })
  handle.agent.followup(msg(`You are running a controlled Orbit stop acceptance. Do exactly this and do not ask questions:
1. Call orbit with {"action":"start","instruction":"Start a long-running command for the stop acceptance."}
2. Call orbit with {"action":"declare","goal":"run a long command","acceptance":"the command is stopped by Orbit"}.
3. Call the bash tool with {"command":"sleep 120","description":"long wait for stop acceptance"}.
Do not stop the task yourself and do not ask questions.`))
  await new Promise((resolve) => setTimeout(resolve, 8000))
  const response = await stopViaSocket().catch((error) => ({ error: String(error && error.message) }))
  log({ step: 'socket-stop', response })
  let task = latestTask()
  for (let attempt = 0; attempt < 60 && task?.state?.status === 'running'; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 500))
    task = latestTask()
  }
  let sleepLeft = ''
  try {
    sleepLeft = execSync('ps -axo pid,command | grep -F "sleep 120" | grep -v grep || true', { encoding: 'utf8' }).trim()
  } catch {}
  log({
    step: 'stop-result',
    status: task?.state?.status,
    stop: task?.state?.stop?.reason,
    confirmed: task?.state?.stop?.confirmation?.confirmed,
    missing: task?.state?.stop?.confirmation?.missing,
    sleepLeft,
  })
  await handle.dispose().catch(() => undefined)
  await presetScope?.dispose?.().catch?.(() => undefined)
}

async function runMemberStop(ctx) {
  mkdirSync(WORK, { recursive: true })
  mkdirSync(join(HOME, 'results'), { recursive: true })
  const handle = await createRoot(ctx)
  log({ step: 'root-created', sessionId: handle.agent.id, scenario: 'member-stop' })
  handle.agent.followup(msg(`You are running a controlled Orbit member-stop acceptance. Do exactly this and do not ask questions:
1. Call orbit with {"action":"start","instruction":"Member stop acceptance."}
2. Call orbit with {"action":"declare","goal":"run a long member command","acceptance":"the member is stopped by Orbit"}.
3. From the declare result take the work unit id. Call the subagent tool with description "long sleeper" and a prompt that starts with this exact line: orbit-unit: <the unit id>
   Then tell the member to call the bash tool with {"command":"sleep 120","description":"long member wait"}.
4. Do not stop the task yourself and do not ask questions. Wait for the member.`))
  await new Promise((resolve) => setTimeout(resolve, 15000))
  const response = await stopViaSocket().catch((error) => ({ error: String(error && error.message) }))
  log({ step: 'socket-stop', response })
  let task = latestTask()
  for (let attempt = 0; attempt < 60 && task?.state?.status === 'running'; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 500))
    task = latestTask()
  }
  const members = task ? JSON.parse(readFileSync(join(task.dir, 'members.json'), 'utf8')).members : []
  let sleepLeft = ''
  try {
    sleepLeft = execSync('ps -axo pid,command | grep -F "sleep 120" | grep -v grep || true', { encoding: 'utf8' }).trim()
  } catch {}
  log({
    step: 'member-stop-result',
    status: task?.state?.status,
    confirmed: task?.state?.stop?.confirmation?.confirmed,
    missing: task?.state?.stop?.confirmation?.missing,
    members: members.map((member) => ({ id: member.id, status: member.status, settledAt: member.settledAt })),
    sleepLeft,
  })
  await handle.dispose().catch(() => undefined)
  await presetScope?.dispose?.().catch?.(() => undefined)
}

function waitForEvent(type, timeoutMs) {
  const start = Date.now()
  return new Promise((resolve) => {
    const timer = setInterval(() => {
      const task = latestTask()
      if (task !== undefined) {
        try {
          const events = readFileSync(join(task.dir, 'events.jsonl'), 'utf8').trim().split('\n').map((line) => JSON.parse(line))
          if (events.some((event) => event.type === type)) {
            clearInterval(timer)
            resolve(events)
            return
          }
        } catch {}
      }
      if (Date.now() - start > timeoutMs) {
        clearInterval(timer)
        resolve(undefined)
      }
    }, 200)
  })
}

async function runCheckerStop(ctx) {
  mkdirSync(WORK, { recursive: true })
  mkdirSync(join(HOME, 'results'), { recursive: true })
  const handle = await createRoot(ctx)
  log({ step: 'root-created', sessionId: handle.agent.id, scenario: 'checker-stop' })
  handle.agent.followup(msg(`You are running a controlled Orbit checker-stop acceptance. Do exactly this and do not ask questions:
1. Call orbit with {"action":"start","instruction":"Checker stop acceptance: write a file and check it."}
2. Call orbit with {"action":"declare","goal":"write hello.txt","acceptance":"hello.txt exists"}.
3. Call the write tool with {"file_path":"${join(WORK, 'hello.txt')}","content":"hello"}.
4. Call orbit with {"action":"check"}.
Do not stop the task yourself and do not ask questions.`))
  const events = await waitForEvent('check/requested', 60000)
  log({ step: 'check-requested', found: events !== undefined })
  await new Promise((resolve) => setTimeout(resolve, Number(process.env.ORBIT_CHECKER_STOP_DELAY ?? 1500)))
  const response = await stopViaSocket().catch((error) => ({ error: String(error && error.message) }))
  log({ step: 'socket-stop', response })
  let task = latestTask()
  for (let attempt = 0; attempt < 60 && task?.state?.status === 'running'; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 500))
    task = latestTask()
  }
  const checks = task ? checksOf(task) : []
  log({
    step: 'checker-stop-result',
    status: task?.state?.status,
    confirmed: task?.state?.stop?.confirmation?.confirmed,
    missing: task?.state?.stop?.confirmation?.missing,
    checks: checks.map((check) => ({ number: check.number, status: check.status, failure: check.failure, verdict: check.result?.verdict })),
  })
  await handle.dispose().catch(() => undefined)
  await presetScope?.dispose?.().catch?.(() => undefined)
}

async function run(ctx) {
  mkdirSync(WORK, { recursive: true })
  mkdirSync(join(HOME, 'results'), { recursive: true })
  if (SCENARIO === 'stop') {
    await runStop(ctx)
    return
  }
  if (SCENARIO === 'member-stop') {
    await runMemberStop(ctx)
    return
  }
  if (SCENARIO === 'checker-stop') {
    await runCheckerStop(ctx)
    return
  }
  const handle = await createRoot(ctx)
  log({ step: 'root-created', sessionId: handle.agent.id, scenario: SCENARIO, initialContent: INITIAL_CONTENT })
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
    checks: task
      ? checksOf(task).map((check) => ({
          number: check.number,
          kind: check.kind,
          status: check.status,
          verdict: check.result?.verdict,
          ready: check.result?.delivery?.ready,
          findings: check.result?.findings?.length,
          reason: check.result?.reason?.slice(0, 240),
        }))
      : [],
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

// Orbit host probes. One probe per process, selected by $ORBIT_PROBE.
// A scripted fake LLM adapter ("probe" provider) drives the real agent loop.
// Results: JSON lines appended to $ORBIT_PROBE_OUT.
import { appendFileSync, writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { execSync } from 'node:child_process'
function pgrep(pattern) { try { return execSync(`pgrep -f ${JSON.stringify(pattern)} | wc -l`).toString().trim() } catch { return '0' } }
function psList(pattern) { try { return execSync(`ps -axo pid,ppid,pgid,stat,command | grep -F ${JSON.stringify(pattern)} | grep -v grep`).toString().trim().split('\n').filter(Boolean) } catch { return [] } }
async function osTrace(pattern) { const out = {}; for (const d of [0, 1000, 3000]) { await sleep(d === 0 ? 0 : d - (d === 1000 ? 0 : 1000)); out[`+${d}ms`] = psList(pattern) } return out }
import { LlmAdapter } from '@deepseek-ai/dsh-llm'
import { credentialRef } from '@deepseek-ai/dsh-credentials'

export const name = 'orbit-probe'
export const inject = ['llm', 'agents', 'tools', 'credentials', 'sessionQuery', 'sessionProjections', 'jobs', 'subagents', 'userQuestions', 'sessions']

const PROBE = process.env.ORBIT_PROBE || 'smoke'
const OUT = process.env.ORBIT_PROBE_OUT || '/dev/stderr'
const HOME = process.env.DSH_HOME
const WORK = join(HOME, 'work')
const STATE = join(HOME, 'probe-state.json')

function log(record) { appendFileSync(OUT, JSON.stringify({ t: new Date().toISOString(), probe: PROBE, ...record }) + '\n') }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
function msg(text, source = { kind: 'user' }) { return { id: randomUUID(), role: 'user', content: [{ type: 'text', text }], source } }
function short(e) { return String(e && (e.stack || e.message || e)).split('\n').slice(0, 3).join(' | ').slice(0, 400) }

// ---------- scripted fake adapter ----------
const calls = [] // { n, at, model, sessionTag, tools:[...] }
let scripts = [] // FIFO of (options) => chunks[]
function textChunks(text) {
  return [
    { type: 'block-start', index: 0, blockType: 'text' },
    { type: 'text-delta', index: 0, text },
    { type: 'block-end', index: 0, block: { type: 'text', text } },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'stop' } },
  ]
}
function toolChunks(toolName, args, id = `call-${randomUUID().slice(0, 8)}`) {
  const argsText = JSON.stringify(args)
  return [
    { type: 'block-start', index: 0, blockType: 'tool-call' },
    { type: 'tool-call-delta', index: 0, id, name: toolName, argumentsDelta: argsText },
    { type: 'block-end', index: 0, block: { type: 'tool-call', id, name: toolName, arguments: argsText } },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'tool-calls' } },
  ]
}
class ProbeAdapter extends LlmAdapter {
  providerInfo(provider) { return { id: provider, provider, name: 'Orbit probe', displayName: 'Orbit probe' } }
  async listModels(provider) { return [{ id: 'probe-1', provider, model: 'probe-1', name: 'probe-1', displayName: 'probe-1' }] }
  async resolveModel(provider, model) { return { provider, id: model, name: model, model, context: { contextWindow: 100000 } } }
  async *stream(options) {
    const n = calls.length + 1
    const toolNames = (options.tools || []).map((t) => t.name || t.function?.name).filter(Boolean)
    calls.push({ n, at: Date.now(), model: options.model, messages: (options.messages || []).length, tools: toolNames.length })
    const script = scripts.shift()
    const chunks = script ? script(options, toolNames) : textChunks(`reply ${n}`)
    for (const c of chunks) yield c
  }
}

// ---------- helpers over DSH services ----------
async function eventsOf(ctx, sessionId, types) {
  const snap = await ctx.sessionQuery.readSession(sessionId)
  const items = snap.events || []
  return types ? items.filter((e) => types.includes(e.type)) : items
}
async function waitFor(fn, timeoutMs, label) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try { const v = await fn(); if (v) return v } catch {}
    await sleep(150)
  }
  throw new Error(`timeout waiting for ${label}`)
}
async function createRoot(ctx, tag, extra = {}) {
  const sessionId = randomUUID()
  const handle = await ctx.agents.create({ sessionId, agentOptions: { provider: 'probe', model: 'probe-1' }, meta: { cwd: WORK }, ...extra })
  log({ step: 'root-created', tag, sessionId: handle.agent.id })
  return handle
}
function summarizeEvents(items) {
  return items.map((e) => {
    const ev = e.event || e
    const d = ev.data || {}
    const extra = {}
    if (ev.type === 'tool/result') { extra.isError = d.message?.isError ?? d.isError; extra.text = JSON.stringify(d.message?.content ?? d.content ?? d).slice(0, 160) }
    if (ev.type === 'turn/end') extra.reason = JSON.stringify(d.reason ?? d).slice(0, 300)
    if (ev.type === 'assistant/attempt') extra.attempt = JSON.stringify(d).slice(0, 300)
    if (ev.type === 'tool/call') extra.name = d.block?.name ?? d.name
    if (ev.type === 'user/message') extra.source = d.source
    if (ev.type === 'job/settled') extra.settled = d
    return { seq: ev.seq, type: ev.type, ...extra }
  })
}

// ---------- probes ----------
const probes = {
  async smoke(ctx) {
    log({ tools: ctx.tools.schemas ? (await ctx.tools.schemas()).length : 'n/a' })
  },

  async 'p7-credentials'(ctx) {
    const ref = credentialRef('TYPESAFE_API_KEY')
    const hit = await ctx.credentials.resolve(ref)
    const info = await ctx.credentials.describe(ref)
    log({ step: 'env-ref', configured: info?.configured, source: info?.source ?? hit?.source, writable: info?.writable, valueLength: hit?.value?.length ?? 0 })
    const ref2 = credentialRef('ORBIT_PROBE_KEY')
    log({ step: 'before-set', describe: await ctx.credentials.describe(ref2) })
    await ctx.credentials.set(ref2, 'probe-secret-value')
    const hit2 = await ctx.credentials.resolve(ref2)
    log({ step: 'after-set', describe: await ctx.credentials.describe(ref2), resolvedSource: hit2?.source, valueLength: hit2?.value?.length })
    await ctx.credentials.unset(ref2)
    log({ step: 'after-unset', describe: await ctx.credentials.describe(ref2), resolved: (await ctx.credentials.resolve(ref2)) === undefined ? 'absent' : 'present' })
    const file = join(HOME, '.credentials.yaml')
    log({ step: 'store-file', exists: existsSync(file), containsSecret: existsSync(file) && readFileSync(file, 'utf8').includes('probe-secret-value') })
  },

  async 'p1-registration'(ctx) {
    const rejectSet = new Set()
    const timeline = []
    ctx.on('agent/created', async ({ agent, source }) => {
      timeline.push({ ev: 'created-listener-start', id: agent.id, source, at: Date.now() })
      await sleep(300)
      if (rejectSet.has(agent.id)) throw new Error('orbit: registration refused')
      timeline.push({ ev: 'created-listener-done', id: agent.id, at: Date.now() })
    })
    // (a) refused registration must fail creation
    const badId = randomUUID()
    rejectSet.add(badId)
    let createError = null
    try { await ctx.agents.create({ sessionId: badId, agentOptions: { provider: 'probe', model: 'probe-1' }, meta: { cwd: WORK } }) } catch (e) { createError = short(e) }
    log({ step: 'refused-create', rejected: Boolean(createError), error: createError, live: Boolean(ctx.agents.get(badId)), adapterCalls: calls.length })
    const sessions = await ctx.sessionQuery.filterSessions([{ kind: 'id', values: [badId] }]).catch((e) => short(e))
    log({ step: 'refused-session-listed', result: Array.isArray(sessions) ? sessions.length : sessions })
    // (b) accepted registration completes before the first model call
    const handle = await createRoot(ctx, 'good')
    handle.agent.followup(msg('hello'))
    await handle.agent.whenIdle()
    const done = timeline.find((t) => t.ev === 'created-listener-done' && t.id === handle.agent.id)
    log({ step: 'order', createdDoneAt: done?.at, firstStreamAt: calls[0]?.at, listenerBeforeStream: Boolean(done && calls[0] && done.at <= calls[0].at), adapterCalls: calls.length })
    log({ step: 'events', events: summarizeEvents(await eventsOf(ctx, handle.agent.id)) })
    await handle.dispose()
  },

  async 'p2-toolgate'(ctx) {
    const names = (await ctx.tools.schemas?.()) ?? []
    log({ step: 'tool-names', names: names.map((s) => s.name).slice(0, 40) })
    let guardHits = 0
    let preExecuteHits = 0
    ctx.on('tools/pre-execute', async (exec, next) => { preExecuteHits++; return { kind: 'allow' } })
    const guardOff = ctx.tools.guard((exec) => { guardHits++; return exec.name === 'bash' ? 'orbit: bash denied by guard' : undefined })
    const handle = await createRoot(ctx, 'gate')
    // turn 1: model calls bash -> guard must deny even though pre-execute allowed
    scripts.push(() => toolChunks('bash', { description: 'write marker', command: 'echo probe-should-not-run > ' + join(WORK, 'bash-ran.txt') }))
    scripts.push(() => textChunks('after denial'))
    handle.agent.followup(msg('run bash'))
    await handle.agent.whenIdle()
    log({ step: 'bash-denied', guardHits, preExecuteHits, bashRan: existsSync(join(WORK, 'bash-ran.txt')), events: summarizeEvents(await eventsOf(ctx, handle.agent.id, ['tool/call', 'tool/result'])) })
    // turn 2: read outside the workspace with no read guard -> expected to succeed (reads are unconfined)
    scripts.push(() => toolChunks('read', { file_path: '/etc/hosts' }))
    scripts.push(() => textChunks('after read'))
    handle.agent.followup(msg('read hosts'))
    await handle.agent.whenIdle()
    const ev2 = summarizeEvents(await eventsOf(ctx, handle.agent.id, ['tool/result']))
    log({ step: 'read-outside-no-guard', last: ev2[ev2.length - 1] })
    // turn 3: Orbit read-root guard
    ctx.tools.guard((exec) => (exec.name === 'read' && typeof exec.arguments?.file_path === 'string' && !exec.arguments.file_path.startsWith(WORK)) ? 'orbit: read outside root denied' : undefined)
    scripts.push(() => toolChunks('read', { file_path: '/etc/hosts' }))
    scripts.push(() => textChunks('after read 2'))
    handle.agent.followup(msg('read hosts again'))
    await handle.agent.whenIdle()
    const ev3 = summarizeEvents(await eventsOf(ctx, handle.agent.id, ['tool/result']))
    log({ step: 'read-outside-with-guard', last: ev3[ev3.length - 1] })
    guardOff()
    await handle.dispose()
  },

  async 'p3-projection'(ctx) {
    const handle = await createRoot(ctx, 'proj')
    scripts.push(() => toolChunks('bash', { description: 'say hi', command: 'echo hi' }))
    scripts.push(() => textChunks('visible reply one'))
    handle.agent.followup(msg('first'))
    await handle.agent.whenIdle()
    handle.agent.inject(msg('injected context', { kind: 'orbit-probe' }))
    const inbox = ctx.sessionProjections.stateOf(handle.agent.session, 'inbox')
    log({ step: 'inbox-projection', inbox: JSON.stringify(inbox).slice(0, 400) })
    const all = await eventsOf(ctx, handle.agent.id)
    const byType = {}
    for (const e of all) { const t = (e.event || e).type; byType[t] = (byType[t] || 0) + 1 }
    log({ step: 'events-by-type', byType, recordKeys: Object.keys(all[0] || {}) })
    const users = await eventsOf(ctx, handle.agent.id, ['user/message'])
    log({ step: 'user-messages', items: users.map((e) => { const ev = e.event || e; return { seq: ev.seq, id: ev.data?.id, source: ev.data?.source, text: JSON.stringify(ev.data?.content).slice(0, 80) } }) })
    const surface = await ctx.sessionQuery.readSurface(handle.agent.id).catch((e) => ({ error: short(e) }))
    log({ step: 'surface', keys: Object.keys(surface), count: surface.events?.length, capturedThroughSeq: surface.capturedThroughSeq })
    const uq = ctx.sessionProjections.stateOf(handle.agent.session, 'userQuestions')
    log({ step: 'userQuestions-projection', value: JSON.stringify(uq).slice(0, 200) })
    await handle.dispose()
  },

  async 'p4-archive'(ctx) {
    const handle = await createRoot(ctx, 'arch')
    scripts.push(() => textChunks('archive me'))
    handle.agent.followup(msg('go'))
    await handle.agent.whenIdle()
    const snap = await ctx.sessionQuery.readSession(handle.agent.id)
    const dir = join(HOME, 'orbit-archive'); mkdirSync(dir, { recursive: true })
    const file = join(dir, `${handle.agent.id}.json`)
    writeFileSync(file, JSON.stringify(snap))
    const back = JSON.parse(readFileSync(file, 'utf8'))
    log({ step: 'archive', keys: Object.keys(snap), header: snap.header ? Object.keys(snap.header) : null, headerVersion: snap.header?.version, events: snap.events?.length, roundTrip: back.events?.length === snap.events?.length, bytes: readFileSync(file).length })
    // where does DSH persist it physically?
    const list = await ctx.sessionQuery.listSessions([{ kind: 'id', values: [handle.agent.id] }]).catch((e) => short(e))
    log({ step: 'listed', rec: JSON.stringify(list).slice(0, 400) })
    await handle.dispose()
  },

  async 'p5-answerer'(ctx) {
    let asked = null
    ctx.on('user-questions/request', async (request, next) => {
      asked = { questions: request.questions.map((q) => q.id), wait: request.wait, agent: request.agent?.id }
      return { answers: request.questions.map((q) => ({ id: q.id, selected: [q.options?.[0]?.label ?? 'yes'] })) }
    })
    const handle = await createRoot(ctx, 'ask')
    const schemas = await ctx.tools.schemas()
    const askSchema = schemas.find((s) => s.name === 'ask_user_question')
    log({ step: 'ask-schema', found: Boolean(askSchema), params: JSON.stringify(askSchema?.parameters ?? askSchema?.inputSchema ?? {}).slice(0, 500) })
    scripts.push(() => toolChunks('ask_user_question', { questions: [{ id: 'q1', question: 'Which?', options: [{ label: 'alpha' }, { label: 'beta' }] }] }))
    scripts.push(() => textChunks('thanks'))
    handle.agent.followup(msg('ask me'))
    await handle.agent.whenIdle()
    log({ step: 'asked', asked, results: summarizeEvents(await eventsOf(ctx, handle.agent.id, ['tool/call', 'tool/result'])) })
    await handle.dispose()
  },

  async 's1-stop-member'(ctx) {
    log({ step: 'providers', list: JSON.stringify(ctx.subagents.list?.() ?? null).slice(0, 300) })
    const root = await createRoot(ctx, 'root')
    const fence = new Set()
    const childCalls = []
    ctx.on('llm/stream', (...args) => { const next = args[args.length - 1]; return next() })
    const guardOff = ctx.tools.guard((exec) => (exec.agent && fence.has(exec.agent.id)) ? 'orbit: task stopped' : undefined)
    scripts.push(() => toolChunks('bash', { description: 'long sleep', command: 'sleep 15' }))
    scripts.push(() => textChunks('child done'))
    const ac = new AbortController()
    const act = await ctx.subagents.startActivation({ provider: 'spawn', label: 'member-1', request: { prompt: [{ type: 'text', text: 'work' }], parent: root.agent, agentOptions: { provider: 'probe', model: 'probe-1' } }, signal: ac.signal, delivery: 'caller' })
    log({ step: 'activation', childId: act.childId, messageId: act.messageId })
    try {
      await waitFor(async () => (await eventsOf(ctx, act.childId, ['tool/call'])).length > 0, 10000, 'child tool/call')
    } catch (e) {
      const settled = await Promise.race([act.result.then((r) => ({ settled: JSON.stringify(r).slice(0, 300) }), (err) => ({ rejected: short(err) })), sleep(100).then(() => ({ pending: true }))])
      log({ step: 'child-no-tool-call', settled, childLive: Boolean(ctx.agents.get(act.childId)), childStatus: ctx.agents.get(act.childId)?.status, events: summarizeEvents(await eventsOf(ctx, act.childId).catch(() => [])) })
      throw e
    }
    const callsBefore = calls.length
    fence.add(act.childId)
    const t0 = Date.now()
    let disposeError = null
    try { await act.dispose() } catch (e) { disposeError = short(e) }
    const elapsed = Date.now() - t0
    let result = null
    try { result = await Promise.race([act.result, sleep(5000).then(() => 'timeout')]) } catch (e) { result = { error: short(e) } }
    await sleep(500)
    log({ step: 'disposed', elapsedMs: elapsed, disposeError, result: JSON.stringify(result).slice(0, 300), childLive: Boolean(ctx.agents.get(act.childId)), callsAfter: calls.length - callsBefore, rootStatus: root.agent.status, osSleep15After: await osTrace('sleep 15') })
    log({ step: 'child-events-tail', events: summarizeEvents(await eventsOf(ctx, act.childId)).filter((e) => ['tool/call','tool/result','turn/end','step/end','job/registered','job/settled'].includes(e.type)) })
    // can the same root still work after the member stop?
    scripts.push(() => textChunks('root continues'))
    root.agent.followup(msg('continue'))
    await root.agent.whenIdle()
    log({ step: 'root-after', calls: calls.length, rootEvents: summarizeEvents(await eventsOf(ctx, root.agent.id, ['user/message', 'assistant/message'])) })
    guardOff()
    await root.dispose()
  },

  async 's2-stop-job'(ctx) {
    const root = await createRoot(ctx, 'jobroot')
    const schemas = await ctx.tools.schemas()
    const bash = schemas.find((s) => s.name === 'bash')
    log({ step: 'bash-schema', hasBackground: JSON.stringify(bash?.parameters ?? bash?.inputSchema ?? {}).includes('run_in_background') })
    scripts.push(() => toolChunks('bash', { description: 'background sleep', command: 'sleep 30', run_in_background: true }))
    scripts.push(() => textChunks('started job'))
    root.agent.followup(msg('bg'))
    await root.agent.whenIdle()
    log({ step: 'tool-events', events: summarizeEvents(await eventsOf(ctx, root.agent.id, ['tool/call', 'tool/result', 'job/registered', 'job/settled'])) })
    const jobs = await ctx.jobs.list(root.agent.id)
    log({ step: 'jobs-after-turn', jobs: JSON.stringify(jobs).slice(0, 500), unowned: JSON.stringify(await ctx.jobs.list()).slice(0, 300) })
    const job = (Array.isArray(jobs) ? jobs : jobs.items || [])[0]
    if (!job) { log({ step: 'no-job' }); await root.dispose(); return }
    const id = job.id ?? job.jobId
    let killErr = null
    const osBefore = pgrep('sleep 30')
    try { killErr = ctx.jobs.kill(id, root.agent.id, 'orbit: task stopped') } catch (e) { killErr = short(e) }
    let waitRes = null
    try { waitRes = await ctx.jobs.wait(id, 10000, root.agent.id) } catch (e) { waitRes = { error: short(e) } }
    const osAfter = await osTrace('sleep 30')
    await sleep(500)
    let after; try { after = await ctx.jobs.get(id, root.agent.id) } catch (e) { after = { error: short(e) } }
    log({ step: 'killed', killResult: killErr, waitRes: JSON.stringify(waitRes).slice(0, 300), after: JSON.stringify(after).slice(0, 300), osSleepBefore: osBefore, osSleepAfter: osAfter })
    log({ step: 'job-events', events: summarizeEvents(await eventsOf(ctx, root.agent.id, ['job/registered', 'job/settled'])) })
    await root.dispose()
  },

  async 's3-s5-fence'(ctx) {
    // Fence at agent/pre-step: reject late replies / orbit-injected messages for a stopped task, admit fresh user input.
    const stoppedCallIds = new Set(['call-old-question'])
    const stoppedInjected = new Set()
    const decisions = []
    ctx.on('agent/pre-step', async (payload, next) => {
      const rejected = payload.messages.filter((m) => (m.source?.kind === 'user-question-reply' && stoppedCallIds.has(m.source.callId)) || (m.source?.kind === 'orbit' && stoppedInjected.has(m.source.tag)))
      if (rejected.length) { decisions.push({ turn: payload.turn, rejected: rejected.map((m) => m.source) }); return { kind: 'reject' } }
      decisions.push({ turn: payload.turn, entered: payload.messages.map((m) => m.source?.kind) })
      return next()
    })
    const root = await createRoot(ctx, 'fence')
    scripts.push(() => textChunks('first reply'))
    root.agent.followup(msg('task one'))
    await root.agent.whenIdle()
    const c1 = calls.length
    // S3: late answer to a stopped task's question
    root.agent.steer(msg('alpha', { kind: 'user-question-reply', callId: 'call-old-question', outcome: 'answered' }))
    await root.agent.whenIdle()
    // S4-like: non-user wake for the stopped task
    stoppedInjected.add('task1')
    root.agent.followup(msg('reminder for task1', { kind: 'orbit', tag: 'task1' }))
    await root.agent.whenIdle()
    const c2 = calls.length
    // S5: fresh user message for a new task must be admitted
    scripts.push(() => textChunks('new task reply'))
    root.agent.followup(msg('task two'))
    await root.agent.whenIdle()
    const c3 = calls.length
    log({ step: 'fence', callsAfterTask1: c1, callsAfterLateInputs: c2, callsAfterNewTask: c3, decisions })
    log({ step: 'turns', events: summarizeEvents(await eventsOf(ctx, root.agent.id, ['turn/start', 'turn/end', 'step/start', 'user/message'])) })
    await root.dispose()
  },

  async 's4-resume-fence'(ctx) {
    const stopped = new Set()
    ctx.on('agent/created', ({ agent, source }) => { if (stopped.has(agent.id)) throw new Error('orbit: session belongs to a stopped task') })
    const root = await createRoot(ctx, 'root')
    scripts.push(() => textChunks('member reply'))
    const act = await ctx.subagents.startActivation({ provider: 'spawn', label: 'member-2', request: { prompt: [{ type: 'text', text: 'work' }], parent: root.agent, agentOptions: { provider: 'probe', model: 'probe-1' } }, signal: new AbortController().signal, delivery: 'caller' })
    await act.result.catch(() => null)
    await act.dispose().catch(() => null)
    stopped.add(act.childId)
    const callsBefore = calls.length
    let resumeErr = null
    try { await ctx.agents.resume({ resumeSessionId: act.childId, parentAgent: root.agent, agentOptions: { provider: 'probe', model: 'probe-1' } }) } catch (e) { resumeErr = short(e) }
    log({ step: 'resume-refused', refused: Boolean(resumeErr), error: resumeErr, live: Boolean(ctx.agents.get(act.childId)), callsDelta: calls.length - callsBefore })
    // sendMessage to the stopped member must not wake it either
    let sendErr = null
    try { await ctx.subagents.sendMessage(root.agent, act.childId, [{ type: 'text', text: 'late' }], { signal: new AbortController().signal }) } catch (e) { sendErr = short(e) }
    await sleep(800)
    log({ step: 'late-send', error: sendErr, live: Boolean(ctx.agents.get(act.childId)), callsDelta: calls.length - callsBefore })
    await root.dispose()
  },

  async 's6-kill-host'(ctx) {
    const root = await createRoot(ctx, 'root')
    scripts.push(() => toolChunks('bash', { description: 'long sleep', command: 'sleep 30' }))
    const act = await ctx.subagents.startActivation({ provider: 'spawn', label: 'member-3', request: { prompt: [{ type: 'text', text: 'work' }], parent: root.agent, agentOptions: { provider: 'probe', model: 'probe-1' } }, signal: new AbortController().signal, delivery: 'caller' })
    await waitFor(async () => (await eventsOf(ctx, act.childId, ['tool/call'])).length > 0, 10000, 'child tool/call')
    writeFileSync(STATE, JSON.stringify({ rootId: root.agent.id, childId: act.childId, killedAt: Date.now() }))
    await ctx.sessions.flush?.(act.childId).catch(() => null)
    log({ step: 'killing-host', childId: act.childId })
    await sleep(300)
    process.kill(process.pid, 'SIGKILL')
  },

  async 's6-after'(ctx) {
    const state = JSON.parse(readFileSync(STATE, 'utf8'))
    const before = summarizeEvents(await eventsOf(ctx, state.childId))
    log({ step: 'child-log-after-crash', tail: before.slice(-6), openTurn: before.filter((e) => e.type === 'turn/start').length > before.filter((e) => e.type === 'turn/end').length })
    const live = ctx.agents.get(state.childId)
    log({ step: 'live-after-restart', childLive: Boolean(live), rootLive: Boolean(ctx.agents.get(state.rootId)) })
    // what a resume does to the interrupted log
    const root = await ctx.agents.resume({ resumeSessionId: state.rootId, agentOptions: { provider: 'probe', model: 'probe-1' } }).catch((e) => ({ error: short(e) }))
    const child = await ctx.agents.resume({ resumeSessionId: state.childId, parentAgent: root.agent, agentOptions: { provider: 'probe', model: 'probe-1' } }).catch((e) => ({ error: short(e) }))
    const after = summarizeEvents(await eventsOf(ctx, state.childId))
    log({ step: 'after-resume', rootResumed: !root.error, childResumed: !child.error, errors: [root.error, child.error].filter(Boolean), tail: after.slice(-5), childStatus: child.agent?.status })
    if (child.agent) await child.dispose().catch(() => null)
    if (root.agent) await root.dispose().catch(() => null)
  },

  async 'p6-checker'(ctx) {
    log({ step: 'providers', list: JSON.stringify(ctx.subagents.list?.() ?? null).slice(0, 400) })
    const root = await createRoot(ctx, 'root')
    const ac = new AbortController()
    let act = null
    try {
      act = await ctx.subagents.startActivation({ provider: 'dsh-sdk', label: 'checker', request: { prompt: [{ type: 'text', text: 'check this' }], parent: root.agent, cwd: WORK }, signal: ac.signal, delivery: 'caller' })
    } catch (e) { log({ step: 'start-failed', error: short(e) }); await root.dispose(); return }
    log({ step: 'checker-started', childId: act.childId })
    const result = await Promise.race([act.result, sleep(60000).then(() => ({ timeout: true }))]).catch((e) => ({ error: short(e) }))
    log({ step: 'checker-result', result: JSON.stringify(result).slice(0, 600) })
    await act.dispose().catch((e) => log({ step: 'dispose-error', error: short(e) }))
    await root.dispose()
  },

  async child(ctx) {
    // Runs inside the checker child process: answer with a fixed verdict and report env visibility.
    log({ step: 'child-env', hasTypesafeKey: Boolean(process.env.TYPESAFE_API_KEY), hasMarker: process.env.ORBIT_CHILD_MARKER, cwd: process.cwd(), home: HOME })
    scripts.push(() => textChunks('CHECK OK'))
    return 'stay'
  },
}

export async function apply(ctx) {
  mkdirSync(WORK, { recursive: true })
  ctx.llm.registerAdapter(['probe'], new ProbeAdapter())
  log({ phase: 'start', pid: process.pid, node: process.version })
  let stay = false
  try {
    const fn = probes[PROBE]
    if (!fn) throw new Error(`unknown probe ${PROBE}`)
    const r = await fn(ctx)
    stay = r === 'stay'
    log({ phase: 'done', ok: true, adapterCalls: calls.length })
  } catch (error) {
    log({ phase: 'error', message: short(error), adapterCalls: calls.length })
  } finally {
    if (!stay) {
      setTimeout(() => { try { ctx.appExit(0) } catch {} }, 300)
      setTimeout(() => process.exit(0), 8000)
    }
  }
}

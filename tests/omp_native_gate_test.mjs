import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { z } from 'zod';
import { installOmpExtension, agentNameFor } from '../plugins/omp-host.mjs';
import { execSync } from 'node:child_process';

// The installer pins the verified Ruby via ORBIT_RUBY; exercise that branch so
// extension children (CLI spawns, member registration) use the same interpreter.
process.env.ORBIT_RUBY = process.env.ORBIT_RUBY || execSync('which ruby').toString().trim();

// M0.1/M0.2 gate test: real task record, real scripts/orbit-register-member,
// real socket bridge. No paid model calls (no provider traffic).
delete process.env.TYPESAFE_API_KEY;
process.env.XDG_CONFIG_HOME = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-gate-test-'));

const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-gate-')));
let events = {}; const sessions = [];
const model = { provider: 'glm', id: 'x' };
const mainAgentId = 'Main';
const aborted = [], setStatuses = [];
let registryListener, definition, started;
// The extension registers several handlers per event name (task gate + hub
// observation on tool_call); keep them all and dispatch in order.
const emit = async (name, ...args) => {
  let result;
  for (const handler of events[name] || []) {
    const value = await handler(...args);
    if (value !== undefined) result = value;
  }
  return result;
};

function session(id, branch = []) {
  const listeners = new Set();
  const native = { sessionId: id, model, isStreaming: false,
    sessionManager: { getSessionId: () => id, getCwd: () => project, getBranch: () => branch },
    getAgentId: () => id,
    hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
    sendCustomMessage: async (message, options) => {
      assert.equal(options.deliverAs, 'steer');
      branch.push({ type: 'custom_message', id: `native-${branch.length}`, ...message });
    },
    abort: async () => {},
    asyncJobManager: {
      cancelAll: ({ ownerId }) => assert.equal(ownerId, id),
      cancelAndReapOwnerJobs: async ownerId => { assert.equal(ownerId, id); return { settled: true }; }
    }
  };
  sessions.push(native); return native;
}

const root = session('root', [{ type: 'message', id: 'original', message: { role: 'user', content: 'Original requirement.' } }]);
const memberSession = session('member-session-1');
const extraRefs = [
  { id: 'orbit-native-1', kind: 'sub', parentId: mainAgentId, status: 'idle', session: memberSession, sessionFile: '/tmp/m1.jsonl', history: {}, activity: null },
  { id: 'orbit-outsider', kind: 'sub', parentId: 'someone-else', status: 'idle', session: null, sessionFile: null, history: {}, activity: null }
];
const rootRef = { id: mainAgentId, kind: 'main', parentId: null, status: 'running', session: root, sessionFile: '/tmp/root.jsonl', history: {}, activity: null };
const registry = {
  list: () => [rootRef, ...extraRefs],
  get: id => [rootRef, ...extraRefs].find(r => r.id === id),
  onChange: listener => { registryListener = listener; return () => { registryListener = null; }; },
  setStatus: (id, status) => { setStatuses.push([id, status]); const ref = registry.get(id); if (ref) ref.status = status; return true; }
};
const ctx = { cwd: project, sessionManager: root.sessionManager, models: { list: () => [model] }, hasUI: true,
  ui: { notify: () => {} } };
const memberCtx = { cwd: project, sessionManager: memberSession.sessionManager, models: { list: () => [model] }, hasUI: true,
  ui: { notify: () => {} } };
const pi = { zod: z, registerTool: tool => { definition = tool; },
  registerCommand: () => {},
  on: (name, handler) => { (events[name] ||= []).push(handler); } };
const sdk = { MAIN_AGENT_ID: mainAgentId,
  AgentRegistry: { global: () => registry, onChange: undefined, get: undefined },
  isUserInterruptAbort: () => false };

const tool = async (args, context = ctx) => JSON.parse((await definition.execute('call', args, null, null, context)).content[0].text);
const taskState = async () => JSON.parse(await fs.readFile(path.join(started.task_directory, 'state.json'), 'utf8'));
const membersFile = async () => JSON.parse(await fs.readFile(path.join(started.task_directory, 'members.json'), 'utf8'));
const request = async (method, extra = {}) => {
  const { connection } = await taskState();
  return new Promise((resolve, reject) => {
    const peer = net.createConnection(connection.socket); let data = '';
    peer.on('error', reject);
    // Do NOT half-close after writing: with allowHalfOpen=false the server
    // socket can close before the async dispatch replies (empty response).
    peer.on('connect', () => peer.write(JSON.stringify({ method, session: 'root', ...extra }) + '\n'));
    peer.on('data', b => {
      data += b;
      if (data.includes('\n')) { const line = data.split('\n')[0]; peer.end(); const r = JSON.parse(line); r.error ? reject(new Error(method + ": " + r.error)) : resolve(r.result); }
    });
    peer.on('end', () => { if (data.trim()) { const r = JSON.parse(data.trim().split('\n')[0]); r.error ? reject(new Error(method + ": " + r.error)) : resolve(r.result); } });
  });
};

try {
  // ADR-009 fixture env (read at install time): a private session agent root
  // and a stub pool CLI, so generated-agent dispatch can re-sync the pool.
  const agentRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-sess-gate-'));
  await fs.mkdir(path.join(agentRoot, 'agents'), { recursive: true });
  process.env.ORBIT_SESSION_AGENT_ROOT = agentRoot;
  const poolStub = path.join(agentRoot, 'pool.sh');
  await fs.writeFile(poolStub, '#!/bin/sh\nprintf \'{"models":["glm/x"]}\\n\'\n');
  await fs.chmod(poolStub, 0o755);
  process.env.ORBIT_CLI_BIN = poolStub;
  installOmpExtension(pi, sdk);
  await emit("session_start", {}, ctx);

  // 1. Fail-closed before Orbit start: task dispatch is refused.
  const unbound = await emit("tool_call", { toolName: "task", toolCallId: "pre-start", input: { task: "x" } }, ctx);
  assert.equal(unbound.block, true, 'task before orbit start must be blocked');
  assert.match(unbound.reason, /Start Orbit/);

  // 1b. Actions without task must name the exact handoff, not invite inbox guessing.
  await assert.rejects(
    () => tool({ action: 'check' }),
    /pass task: <task_directory returned by start> to the orbit tool[\s\S]*Do NOT write \.orbit\/inbox manually/);

  // Bind a real task through the real CLI (same bridge the production path uses).
  started = await tool({ action: 'start', message_id: 'original' });
  assert.ok(started.task_directory, 'start must return a task directory');
  // Deterministic seam fixture: the detached TaskRuntime needs a full runner
  // setup this test does not provide and can flip the task out of the active
  // states on its own schedule. Stop it and pin the fixture task to
  // 'running'. This exercises the registration-gate seam deterministically;
  // it is NOT a full end-to-end run.
  try { process.kill(-started.pid, 'SIGTERM'); } catch { /* already gone */ }
  for (let n = 0; n < 40; n++) {
    try { process.kill(started.pid, 0); } catch { break; }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  {
    const statePath = path.join(started.task_directory, 'state.json');
    const fixture = JSON.parse(await fs.readFile(statePath, 'utf8'));
    fixture.status = 'running';
    // Pin a LIVE sentinel pid: a running task whose runtime is available.
    fixture.runtime_pid = process.pid;
    await fs.writeFile(statePath, JSON.stringify(fixture));
  }

  // Root session model and the native task role are different identities.
  // Billing route is a structural proof from the resolved endpoint (host plus
  // path prefix) and transport, never a provider-name list.
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'zhipu-coding-plan', id: 'glm-5.2', thinking: 'max', baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4' }
    : undefined;
  assert.equal(await request('model'), 'glm/x', 'Root model RPC stays the live session model');
  const memberModel = await request('member_model');
  assert.deepEqual(memberModel, { provider: 'zhipu-coding-plan', id: 'glm-5.2', billing_route: 'subscription_quota' },
    'the verified zhipu coding-plan endpoint is subscription_quota');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'zhipu-coding-plan', id: 'glm-5.2', baseUrl: 'https://open.bigmodel.cn/api/paas/v4' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'zhipu-coding-plan', id: 'glm-5.2', billing_route: 'unknown' },
    'the standard Zhipu API path is not the coding-plan endpoint');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'zhipu-coding-plan', id: 'glm-5.2', baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4', transport: 'pi-native' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'zhipu-coding-plan', id: 'glm-5.2', billing_route: 'unknown' },
    'a pi-native transport never proves a first-party route');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'zhipu-coding-plan', id: 'glm-5.2', baseUrl: 'https://plan.example.com/api/coding/paas/v4' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'zhipu-coding-plan', id: 'glm-5.2', billing_route: 'unknown' },
    'a same-named custom provider on another host stays unknown');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'zhipu-coding-plan', id: 'glm-5.2', baseUrl: 'http://open.bigmodel.cn/api/coding/paas/v4' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'zhipu-coding-plan', id: 'glm-5.2', billing_route: 'unknown' },
    'a plain-http plan endpoint is not first-party proof');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'kimi-code', id: 'kimi-for-coding', baseUrl: 'https://api.kimi.com/coding/v1' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'kimi-code', id: 'kimi-for-coding', billing_route: 'subscription_quota' },
    'the verified Kimi Code endpoint is subscription_quota');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'kimi-code', id: 'kimi-for-coding', baseUrl: 'https://api.moonshot.ai/v1' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'kimi-code', id: 'kimi-for-coding', billing_route: 'unknown' },
    'the Moonshot direct API host is not the Kimi Code plan endpoint');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'github-copilot', id: 'gpt-5.4', baseUrl: 'https://api.githubcopilot.com' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'github-copilot', id: 'gpt-5.4', billing_route: 'unknown' },
    'a plan service without a verified first-party endpoint stays unknown');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'deepseek', id: 'deepseek-flash', api: 'openai-completions', baseUrl: 'https://api.deepseek.com/v1' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'deepseek', id: 'deepseek-flash', billing_route: 'direct_api' },
    'the verified first-party DeepSeek endpoint is direct_api');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'deepseek', id: 'deepseek-flash', baseUrl: 'https://api.deepseek.com/v1', transport: 'pi-native' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'deepseek', id: 'deepseek-flash', billing_route: 'unknown' },
    'a gateway-forwarded DeepSeek endpoint is not direct_api');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'deepseek', id: 'deepseek-flash', baseUrl: 'http://api.deepseek.com/v1' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'deepseek', id: 'deepseek-flash', billing_route: 'unknown' },
    'a plain-http DeepSeek endpoint is not direct_api');
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'deepseek', id: 'deepseek-flash', baseUrl: 'https://proxy.example.com/v1' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'deepseek', id: 'deepseek-flash', billing_route: 'unknown' },
    'a custom DeepSeek endpoint stays unknown');
  ctx.models.resolve = () => undefined;
  await assert.rejects(() => request('member_model'), /unresolved/);
  assert.equal(await request('model'), 'glm/x', 'a failed task-role lookup does not replace the Root model');
  delete ctx.models.resolve;

  // 2. Happy path: requested name is assigned; registered window writes the
  //    durable record BEFORE the member can stream.
  const revised = await emit("tool_call", { toolName: 'task', toolCallId: 'call-1', input: { task: 'member work' } }, ctx);
  assert.ok(revised.input, `task dispatch must not be blocked here: ${JSON.stringify(revised)}`);
  assert.ok(revised.input.name.startsWith('orbit-'), 'tool_call must assign the requested identity');
  const liveMemberListeners = new Set();
  const liveMemberSession = { sessionId: 'member-live', model, isStreaming: false,
    sessionManager: memberSession.sessionManager,
    hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
    getAgentId: () => revised.input.name,
    subscribe: listener => { liveMemberListeners.add(listener); return () => liveMemberListeners.delete(listener); },
    sendCustomMessage: async (message, options) => {
      assert.equal(options.deliverAs, 'steer'); assert.equal(options.triggerTurn, true);
      memberSession.sessionManager.getBranch().push({ type: 'custom_message', id: `member-msg-${Math.random()}`, ...message });
    },
    abort: async () => {},
    asyncJobManager: { cancelAll: () => {}, cancelAndReapOwnerJobs: async () => ({ settled: true }) } };
  const liveRef = { id: revised.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
    session: liveMemberSession,
    sessionFile: '/tmp/live.jsonl', history: { outputPath: '/tmp/live.md', resolvedModel: 'glm/x' }, activity: 'working' };
  extraRefs.push(liveRef);
  registryListener({ type: 'registered', ref: liveRef });
  const members = await membersFile();
  assert.equal(members.length, 1);
  assert.equal(members[0].thread_id, revised.input.name);
  assert.equal(members[0]['requested_name'], revised.input.name);
  assert.equal(members[0].status, 'registered');
  assert.equal(members[0].model, 'glm/x');
  assert.equal(members[0]['tool_call_id'], 'call-1');

  // Bridge: query by ACTUAL agent id.
  const roster = await request('members');
  assert.ok(roster.some(m => m.id === revised.input.name && m.registered === true));
  const mstate = await request('member_state', { id: revised.input.name });
  assert.equal(mstate.model, 'glm/x');
  assert.equal(mstate.output_path, '/tmp/live.md');
  const mresult = await request('member_result', { id: revised.input.name });
  assert.equal(mresult.output_path, '/tmp/live.md');
  const msent = await request('send_member', { id: revised.input.name, text: 'amendment' });
  assert.equal(msent.action, 'native_custom_message');
  const mstop = await request('stop_member', { id: revised.input.name });
  assert.equal(mstop.confirmed, true);
  assert.equal(mstop.async_jobs_settled, true);
  // stop_member is idempotent over verified confirmations: a repeat call must
  // return the cached result (the live session evidence is gone by then).
  const mstopAgain = await request('stop_member', { id: revised.input.name });
  assert.equal(mstopAgain.confirmed, true, 'repeat stop must return the cached verified confirmation');
  await assert.rejects(() => request('member_state', { id: 'orbit-outsider' }), /not owned/);

  // 3. Drift: allocator returned a suffixed duplicate -> aborted + refused record.
  const driftCall = await emit("tool_call", { toolName: 'task', toolCallId: 'call-2', input: { task: 'second' } }, ctx);
  const driftedId = `${driftCall.input.name}-2`;
  const driftRef = { id: driftedId, kind: 'sub', parentId: mainAgentId, status: 'running', session: null, sessionFile: null, history: {}, activity: null };
  extraRefs.push(driftRef);
  registryListener({ type: 'registered', ref: driftRef });
  assert.ok(setStatuses.some(([id, status]) => id === driftedId && status === 'aborted'), 'drifted id must be aborted');
  const afterDrift = await membersFile();
  const refusal = afterDrift.find(m => m.thread_id === driftedId);
  assert.equal(refusal.status, 'refused');
  assert.equal(refusal.reason, 'id_drift');
  // Cleanup: the same id registering again (revival) must be ignored, not re-recorded.
  registryListener({ type: 'registered', ref: { id: driftedId, kind: 'sub', parentId: mainAgentId, status: 'running', session: null, sessionFile: null, history: {}, activity: null } });
  assert.equal((await membersFile()).filter(m => m.thread_id === driftedId).length, 1);

  // 3b. Model drift (ADR-009): dispatch through a generated agent name pins an
  //     expected pool model. If the model resolved at the registration window
  //     already differs (task.agentModelOverrides wins), the member is aborted
  //     and the drift recorded on the existing entry — the registration
  //     boundary provably precedes any member provider work. A re-bound child
  //     factory then still sees the shared member state (the 2026-09-25 real
  //     probe showed closure-scoped maps leave the child hook blind).
  const pinnedAgent = agentNameFor('glm/x');
  const modelDriftCall = await emit('tool_call', { toolName: 'task', toolCallId: 'call-md', input: { agent: pinnedAgent, task: 'drift probe' } }, ctx);
  assert.ok(!modelDriftCall.block, `pinned dispatch must pass the gate: ${JSON.stringify(modelDriftCall)}`);
  const modelDriftRef = { id: modelDriftCall.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
    session: { ...memberSession, sessionId: 'drift-sess-1', model: { provider: 'zhipu', id: 'other' } },
    sessionFile: null, history: {}, activity: null };
  extraRefs.push(modelDriftRef);
  registryListener({ type: 'registered', ref: modelDriftRef });
  const driftModelEntry = (await membersFile()).find(m => m.thread_id === modelDriftCall.input.name);
  assert.equal(driftModelEntry.status, 'registered', 'original registration survives the drift record');
  assert.equal(driftModelEntry.model_drift.expected, 'glm/x');
  assert.equal(driftModelEntry.model_drift.actual, 'zhipu/other');
  assert.equal(driftModelEntry.model_drift.abort_attempted, true);
  assert.ok(setStatuses.some(([id, s]) => id === modelDriftCall.input.name && s === 'aborted'), 'drifted member must be aborted at registration');
  // Rebind visibility: a second (child-rebound) factory instance fires
  // before_provider_request for the same member with the drifted model. The
  // shared module state must make it abort WITHOUT recording a second drift.
  const childEvents = {};
  const childPi = { zod: z, registerTool: () => {}, registerCommand: () => {}, on: (n, h) => { (childEvents[n] ||= []).push(h); } };
  installOmpExtension(childPi, { MAIN_AGENT_ID: mainAgentId, AgentRegistry: { global: () => registry }, isUserInterruptAbort: () => false });
  let childAborted = false;
  const childCtx = { cwd: project, sessionManager: { getSessionId: () => 'drift-sess-1' },
    models: { list: () => [model] }, model: { provider: 'zhipu', id: 'other' },
    abort: () => { childAborted = true; }, ui: { notify: () => {} }, hasUI: true };
  for (const h of childEvents.before_provider_request || []) await h({ payload: {} }, childCtx);
  assert.ok(childAborted, 're-bound child hook must abort a drifted member via shared module state');
  assert.equal((await membersFile()).filter(m => m.thread_id === modelDriftCall.input.name && m.model_drift).length, 1,
    'child hook must not duplicate the drift record');

  // 3c. attachSession has NO registry event: a member registered with a null
  //     session is attached silently later. The (re-bound) child's
  //     before_provider_request must capture the live session into the shared
  //     retained map — this is the OMP 18.2.8 lifecycle the real 2026-09-25
  //     probes exposed.
  process.env.ORBIT_CLI_BIN = poolStub; // gate re-syncs the pool on orbit-m-* dispatch
  const lateCall = await emit('tool_call', { toolName: 'task', toolCallId: 'call-late', input: { agent: pinnedAgent, task: 'late attach' } }, ctx);
  assert.ok(!lateCall.block, `pinned dispatch must pass the gate: ${JSON.stringify(lateCall)}`);
  const lateRef = { id: lateCall.input.name, kind: 'sub', parentId: mainAgentId, status: 'running', session: null, sessionFile: null, history: {}, activity: null };
  extraRefs.push(lateRef);
  registryListener({ type: 'registered', ref: lateRef }); // session null: nothing to retain yet
  const lateSession = { ...memberSession, sessionId: 'late-sess', model: { provider: 'zhipu', id: 'other' } };
  lateRef.session = lateSession; // silent attachSession — no registry event
  const lateChildEvents = {};
  const latePi = { zod: z, registerTool: () => {}, registerCommand: () => {}, on: (n, h) => { (lateChildEvents[n] ||= []).push(h); } };
  installOmpExtension(latePi, { MAIN_AGENT_ID: mainAgentId, AgentRegistry: { global: () => registry }, isUserInterruptAbort: () => false });
  let lateAborted = false;
  const lateCtx = { cwd: project, sessionManager: { getSessionId: () => 'late-sess' },
    models: { list: () => [model] }, model: { provider: 'zhipu', id: 'other' },
    abort: () => { lateAborted = true; }, ui: { notify: () => {} }, hasUI: true };
  for (const h of lateChildEvents.before_provider_request || []) await h({ payload: {} }, lateCtx);
  assert.ok(lateAborted, 'hook must abort the drifted member');
  const lateState = await request('member_state', { id: lateCall.input.name });
  assert.equal(lateState.retained_session_seen, true, 'silent attach must be captured into the shared retained map');
  await fs.rm(agentRoot, { recursive: true, force: true });
  delete process.env.ORBIT_CLI_BIN;

  // 4. Write failure (corrupt members list): aborted, list not overwritten.
  const failCall = await emit("tool_call", { toolName: 'task', toolCallId: 'call-3', input: { task: 'third' } }, ctx);
  await fs.writeFile(path.join(started.task_directory, 'members.json'), 'not-json');
  const failRef = { id: failCall.input.name, kind: 'sub', parentId: mainAgentId, status: 'running', session: null, sessionFile: null, history: {}, activity: null };
  extraRefs.push(failRef);
  registryListener({ type: 'registered', ref: failRef });
  assert.ok(setStatuses.some(([id, status]) => id === failCall.input.name && status === 'aborted'));
  assert.equal((await fs.readFile(path.join(started.task_directory, 'members.json'), 'utf8')), 'not-json', 'corrupt list must not be overwritten');
  await fs.rm(path.join(started.task_directory, 'members.json')); // fixture cleanup: later sections register anew

  // 5. Members cannot re-dispatch (one-level delegation), independent of depth config.
  const redispatch = await emit("tool_call", { toolName: 'task', toolCallId: 'member-call', input: { task: 'sub task' } }, memberCtx);
  assert.equal(redispatch.block, true);
  assert.match(redispatch.reason, /one-level/);

  // 6. A failed task call must NOT clean pending names: the async-spawn ACK
  //    (tool_result) precedes the registry `registered` event; premature
  //    cleanup would unregister the gate and let members start unregistered.
  //    Pending names live until the registered window or a refusal.
  await emit("tool_call", { toolName: 'task', toolCallId: 'call-4', input: { task: 'fourth' } }, ctx);

  // 7. Fail closed when the registry event surface is unavailable: without
  //    the gate, registration is impossible, so dispatch must be refused.
  const brokenEvents = {};
  const noChangeRegistry = { list: () => [rootRef], get: id => registry.get(id), setStatus: () => true };
  const brokenPi = { zod: z, registerTool: () => {}, registerCommand: () => {}, on: (n, h) => { (brokenEvents[n] ||= []).push(h); } };
  installOmpExtension(brokenPi, { MAIN_AGENT_ID: mainAgentId, AgentRegistry: { global: () => noChangeRegistry }, isUserInterruptAbort: () => false });
  const brokenEmit = async (name, ...args) => {
    let result;
    for (const handler of brokenEvents[name] || []) {
      const value = await handler(...args);
      if (value !== undefined) result = value;
    }
    return result;
  };
  await brokenEmit('session_start', {}, ctx);
  const gated = await brokenEmit('tool_call', { toolName: 'task', toolCallId: 'broken', input: { task: 'x' } }, ctx);
  assert.equal(gated.block, true, 'task dispatch must fail closed without the registration gate');
  assert.match(gated.reason, /registration gate is unavailable/);
  const unknownCaller = await emit("tool_call", { toolName: 'task', toolCallId: 'unknown', input: { task: 'x' } },
    { cwd: project, sessionManager: { getSessionId: () => 'ghost-session' }, models: { list: () => [model] }, hasUI: true, ui: { notify: () => {} } });
  assert.equal(unknownCaller.block, true, 'unresolvable caller must not dispatch');
  assert.match(unknownCaller.reason, /not the verified Root/);

  // 8. Hub observation carries real wire content, and waking a registered
  //    member is refused once its task is not active or it was confirmed stopped.
  {
    await emit('tool_call', { toolName: 'hub', toolCallId: 'hub-1', input: { op: 'send', to: 'orbit-native-1', message: 'ping-from-root' } }, ctx);
    const before = (await request('hub_events')).events.filter(e => e.kind === 'hub_call');
    assert.equal(before.at(-1).message, 'ping-from-root', 'hub message content must be observed');
    assert.equal(before.at(-1).to, 'orbit-native-1');
    // Task not active -> wake refused (task is 'running' here, so flip first).
    const statePath0 = path.join(started.task_directory, 'state.json');
    const fixture0 = JSON.parse(await fs.readFile(statePath0, 'utf8'));
    fixture0.status = 'paused';
    await fs.writeFile(statePath0, JSON.stringify(fixture0));
    const refusedWake = await emit('tool_call', { toolName: 'hub', toolCallId: 'hub-2', input: { op: 'send', to: revised.input.name, message: 'wake?' } }, ctx);
    assert.equal(refusedWake.block, true, 'waking a registered member outside an active task must be blocked');
    fixture0.status = 'running';
    await fs.writeFile(statePath0, JSON.stringify(fixture0));
    // Confirmed-stopped member cannot be re-woken.
    const mstop2 = await request('stop_member', { id: revised.input.name });
    assert.equal(mstop2.confirmed, true);
    const stoppedWake = await emit('tool_call', { toolName: 'hub', toolCallId: 'hub-3', input: { op: 'send', to: revised.input.name, message: 'wake?' } }, ctx);
    assert.equal(stoppedWake.block, true, 'a confirmed-stopped member must not be re-woken via hub');
    // Non-Orbit members are untouched by the wake gate.
    const outsider = await emit('tool_call', { toolName: 'hub', toolCallId: 'hub-4', input: { op: 'send', to: 'orbit-outsider', message: 'hi' } }, ctx);
    assert.equal(outsider, undefined, 'hub traffic to non-Orbit peers must not be blocked');
  }

  // 8b. Member-origin hub traffic is observed through the existing member
  //     session subscription, tagged with the member identity and owning task.
  {
    for (const listener of liveMemberListeners) {
      await listener({ type: 'tool_execution_start', toolCallId: 'member-hub-1', toolName: 'hub',
        args: { op: 'send', to: 'Main', message: 'member clarification', replyTo: 'msg-1', await: true } });
    }
    for (const listener of liveMemberListeners) {
      await listener({ type: 'tool_execution_end', toolCallId: 'member-hub-1', toolName: 'hub',
        result: { content: [{ type: 'text', text: 'member reply text' }] }, isError: false });
    }
    const all = (await request('hub_events')).events;
    const memberCall = all.find(e => e.kind === 'hub_call' && e.tool_call_id === 'member-hub-1');
    assert.ok(memberCall, 'member hub call must be observed');
    assert.equal(memberCall.agent_id, revised.input.name, 'member hub call carries the member agent id');
    assert.equal(memberCall.session_id, 'member-live', 'member hub call carries the member session id');
    assert.equal(memberCall.op, 'send');
    assert.equal(memberCall.to, 'Main');
    assert.equal(memberCall.message, 'member clarification');
    assert.equal(memberCall.await_reply, true);
    assert.equal(memberCall.task_dir, started.task_directory, 'member hub call is scoped to its owning task');
    assert.ok(memberCall.seq > 0 && memberCall.id === `collab-${memberCall.seq}`, 'member hub call is sequenced');
    const memberResult = all.find(e => e.kind === 'hub_result' && e.tool_call_id === 'member-hub-1');
    assert.ok(memberResult, 'member hub result must be observed');
    assert.equal(memberResult.agent_id, revised.input.name, 'member hub result carries the member agent id');
    assert.equal(memberResult.session_id, 'member-live', 'member hub result carries the member session id');
    assert.equal(memberResult.text, 'member reply text');
    assert.equal(memberResult.ok, true);
    assert.equal(memberResult.task_dir, started.task_directory, 'member hub result stays in the same task');
    assert.ok(all.filter(e => e.kind === 'hub_call').every(e => e.task_dir === started.task_directory),
      'no cross-task hub traffic leaks into this task buffer');
  }

  // 9. Stop-retry semantics: with the task stop_unconfirmed, member reads and
  //    stop_member must still work for explicit retry; send_member refuses.
  {
    const statePath = path.join(started.task_directory, 'state.json');
    const fixture = JSON.parse(await fs.readFile(statePath, 'utf8'));
    fixture.status = 'stop_unconfirmed';
    await fs.writeFile(statePath, JSON.stringify(fixture));
    const retryState = await request('member_state', { id: revised.input.name });
    assert.equal(retryState.id, revised.input.name, 'member_state must remain reachable for stop retry');
    assert.ok('lifecycle' in retryState, 'member_state must expose registry lifecycle evidence');
    const retryStop = await request('stop_member', { id: revised.input.name });
    assert.equal(retryStop.confirmed, true, 'stop_member must remain reachable for stop retry');
    await assert.rejects(() => request('send_member', { id: revised.input.name, text: 'late work' }), /refusing member delivery/);
    fixture.status = 'running';
    await fs.writeFile(statePath, JSON.stringify(fixture));
  }

  // 10. A member whose session is disposed (park path) cannot be confirmed:
  //     structured evidence, confirmed:false, never "completed" as proof.
  {
    const parkedCall = await emit('tool_call', { toolName: 'task', toolCallId: 'call-parked', input: { task: 'parked member' } }, ctx);
    const parkedRef = { id: parkedCall.input.name, kind: 'sub', parentId: mainAgentId, status: 'parked', session: null,
      sessionFile: '/tmp/parked.jsonl', history: { outputPath: '/tmp/parked.md' },
      lifecycle: { responseAt: 1, acceptedAt: 2, terminalAt: 3 }, activity: null };
    extraRefs.push(parkedRef);
    registryListener({ type: 'registered', ref: parkedRef });
    const parkedEntry = (await membersFile()).find(m => m.thread_id === parkedRef.id);
    assert.equal(parkedEntry.status, 'registered', 'parked member still registers durably (it did work under a real id)');
    const parkedStop = await request('stop_member', { id: parkedRef.id });
    assert.equal(parkedStop.confirmed, false, 'disposed-session member stop must NOT be confirmed');
    assert.equal(parkedStop.evidence.lifecycle.acceptedAt, 2, 'acceptedAt evidence must be exposed');
    assert.match(parkedStop.reason, /no public completion signal|unverifiable/);
    const parkedState = await request('member_state', { id: parkedRef.id });
    assert.equal(parkedState.session_attached, false);
    assert.equal(parkedState.lifecycle.acceptedAt, 2);
  }

  // 11. Correction/finalization delivery ACK state machine, modeled on OMP
  //    18.2.8 #dispatchCustomMessage: streaming steer-queue resolves fast;
  //    idle triggerTurn stays pending until the marker lands in the branch;
  //    idle false resolve / window timeout fail closed; late rejection after
  //    an ACK is surfaced through state().
  {
    process.env.ORBIT_DELIVERY_ACK_MS = '600';
    const originalSend = root.sendCustomMessage;
    const originalStreaming = root.isStreaming;
    const timers = [];
    try {
      // (a) Streaming Root: fast resolve while streaming ACKs via steer-queue,
      //     even though the branch marker only appears later at consumption.
      root.isStreaming = true;
      root.sendCustomMessage = async (message, options) => {
        assert.equal(options.deliverAs, 'steer'); assert.equal(options.triggerTurn, true);
        timers.push(setTimeout(() => root.sessionManager.getBranch().push({ type: 'custom_message', id: `consume-${Date.now()}`, ...message }), 2000));
        return false;
      };
      const t0 = Date.now();
      const queued = await request('send', { text: 'correction to streaming root' });
      assert.equal(queued.delivery, 'accepted');
      assert.equal(queued.via, 'steer-queue');
      assert.ok(Date.now() - t0 < 1500, 'streaming ACK must not wait for branch consumption');

      // (b) Idle Root with a slow initiated turn: marker lands in the branch
      //     while the send promise is still pending -> ACK via branch.
      root.isStreaming = false;
      root.sendCustomMessage = (message, options) => new Promise(resolve => {
        assert.equal(options.deliverAs, 'steer');
        timers.push(setTimeout(() => { root.sessionManager.getBranch().push({ type: 'custom_message', id: `idle-${Date.now()}`, ...message }); }, 250));
        timers.push(setTimeout(() => resolve(true), 60000)); // the whole prompt far outlives the RPC
      });
      const idleAck = await request('send', { text: 'correction to idle root' });
      assert.equal(idleAck.via, 'branch');

      // (c) Idle preflight discard (resolves false without accepting) -> fail closed.
      root.sendCustomMessage = async () => false;
      await assert.rejects(() => request('send', { text: 'discarded correction' }), /discarded by the session/);

      // (d) No acceptance signal at all -> fail closed, never a false report.
      root.sendCustomMessage = () => new Promise(() => {});
      await assert.rejects(() => request('send', { text: 'lost correction' }), /not accepted within/);

      // (e) Marker accepted, transport rejects later -> ACK stands, error surfaced.
      root.sendCustomMessage = async (message, options) => {
        root.sessionManager.getBranch().push({ type: 'custom_message', id: `late-${Date.now()}`, ...message });
        return Promise.reject(new Error('transport died after accept'));
      };
      const late = await request('send', { text: 'late rejection case' });
      assert.equal(late.delivery, 'accepted');
      let observed = false;
      for (let n = 0; n < 30; n++) {
        const state = await request('state');
        if (JSON.stringify(state.observations).includes('transport died after accept')) { observed = true; break; }
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      assert.ok(observed, 'late delivery failure must surface through state(), not be swallowed');
    } finally {
      for (const timer of timers) clearTimeout(timer);
      root.sendCustomMessage = originalSend;
      root.isStreaming = originalStreaming;
      delete process.env.ORBIT_DELIVERY_ACK_MS;
    }
  }

  // 12. Per-turn bound-task status: an active bound task injects a short
  //     record-derived status; a terminal task only refreshes the status line,
  //     never an unowned or dead-runtime record shown as controlled.
  {
    const statusCalls = [];
    const statusCtx = { ...ctx, ui: { notify: () => {}, setStatus: (key, value) => statusCalls.push([key, value]) } };
    const setState = async patch =>
      fs.writeFile(path.join(started.task_directory, 'state.json'), JSON.stringify({ ...(await taskState()), ...patch }));
    const statusTurn = async prompt => {
      const out = await emit('before_agent_start', { prompt, systemPrompt: ['BASE'] }, statusCtx);
      return out ? out.systemPrompt.join('\n') : '';
    };
    const injected = await emit('before_agent_start', { prompt: 'next user turn', systemPrompt: ['BASE'] }, statusCtx);
    assert.ok(injected?.systemPrompt?.some(part => part.includes('[orbit-task-status]')), 'an active bound task must inject a marked per-turn status block');
    const block = injected.systemPrompt.join('\n');
    assert.ok(block.includes((await taskState()).id), 'the block must carry the task id');
    assert.ok(block.includes('执行中') && block.includes('intent=pause'), 'a running task reads as 执行中 with the interrupt intent');
    assert.ok(statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('执行中')), 'setStatus must show the phase');
    // A record whose control socket is not this host's is what an OMP restart
    // leaves: shown as unowned, never controlled (the tool would refuse it).
    const boundConnection = (await taskState()).connection;
    await setState({ connection: { ...boundConnection, socket: path.join(os.tmpdir(), 'orbit-gone-control.sock') } });
    const staleText = await statusTurn('after crash');
    assert.ok(staleText.includes('未接管') && staleText.includes('被拒绝') && staleText.includes(started.task_directory), 'an unowned record warns tool calls are refused and gives the cleanup directory');
    assert.ok(!staleText.includes('intent=pause'), 'the unowned block gives no normal stop directive');
    assert.ok(statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('未接管')), 'setStatus must mark the unowned record');
    // Owned but dead runtime: the socket matches this host, the recorded runtime is gone.
    const { runtime_pid: savedPid, finished_at: savedFinished } = await taskState();
    await setState({ connection: boundConnection, runtime_pid: null, finished_at: new Date().toISOString() });
    const lostText = await statusTurn('runtime died');
    assert.ok(lostText.includes('运行时已失联') && lostText.includes('停止重试'), 'a dead runtime reads as lost and points at the stop retry');
    assert.ok(!lostText.includes('intent=pause'), 'the abandoned block gives no normal stop directive');
    assert.ok(statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('运行时已失联')), 'setStatus must mark the dead runtime');
    // Terminal task: the status line refreshes but no per-turn block is injected.
    await setState({ runtime_pid: savedPid, finished_at: savedFinished, status: 'paused' });
    assert.equal(await statusTurn('next'), '', 'a terminal task injects no system prompt block');
    assert.ok(statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('已暂停')), 'a paused task still refreshes the status line');
    await setState({ status: 'running' });
  }

  // 12b. Restart recovery: a fresh instance (no in-memory binding) recovers the
  //      record by (provider, thread_id) for display, but presents it as unowned
  //      and never rebinds it (the tool would refuse every action).
  {
    const savedRoot = process.env.ORBIT_SESSION_AGENT_ROOT;
    delete process.env.ORBIT_SESSION_AGENT_ROOT; // recovery must not trigger a pool sync spawn
    const recoveryEvents = {};
    const recoveryPi = { zod: z, registerTool: () => {}, registerCommand: () => {}, on: (n, h) => { (recoveryEvents[n] ||= []).push(h); } };
    installOmpExtension(recoveryPi, { MAIN_AGENT_ID: mainAgentId, AgentRegistry: { global: () => registry }, isUserInterruptAbort: () => false });
    const savedEvents = events;
    events = recoveryEvents;
    try {
      const recoveryStatus = [];
      const recoveryCtx = { ...ctx, ui: { notify: () => {}, setStatus: (key, value) => recoveryStatus.push([key, value]) } };
      await emit('session_start', {}, recoveryCtx);
      const recovered = await emit('before_agent_start', { prompt: 'after resume', systemPrompt: ['BASE'] }, recoveryCtx);
      assert.ok(recovered?.systemPrompt?.some(part => part.includes('[orbit-task-status]')), 'record-based recovery must inject status after a restart with no in-memory binding');
      const recoveredText = recovered.systemPrompt.join('\n');
      assert.ok(recoveredText.includes((await taskState()).id), 'recovery must resolve the same durable task record');
      assert.ok(recoveredText.includes('未接管') && recoveredText.includes('被拒绝') && recoveredText.includes(started.task_directory), 'a recovered record stays unowned, warns tool calls are refused, and gives the cleanup directory');
      assert.ok(!recoveredText.includes('intent=pause'), 'recovery must not give the normal stop directive');
      assert.ok(recoveryStatus.some(([key, value]) => key === 'orbit' && String(value).includes('未接管')), 'setStatus must mark the recovered record unowned');
    } finally {
      events = savedEvents;
      if (savedRoot) process.env.ORBIT_SESSION_AGENT_ROOT = savedRoot;
    }
  }

  // 13. Root-tool stop intent: a completion intent (the default) carries
  //     --complete for the Ruby gate to adjudicate; an explicit pause never does.
  //     An exit-0 structured refusal passes through unchanged and changes no record.
  {
    const stubDir = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-stop-stub-'));
    const stub = path.join(stubDir, 'fake-ruby.mjs');
    const log = path.join(stubDir, 'args.json');
    await fs.writeFile(stub, `#!/usr/bin/env node
import fs from 'node:fs';
fs.writeFileSync(process.env.ORBIT_STOP_STUB_LOG, JSON.stringify(process.argv.slice(2)));
process.stdout.write((process.env.ORBIT_STOP_STUB_RESULT || '{"status":"queued"}') + '\\n');
`);
    await fs.chmod(stub, 0o755);
    const savedRuby = process.env.ORBIT_RUBY;
    try {
      process.env.ORBIT_RUBY = stub;
      process.env.ORBIT_STOP_STUB_LOG = log;
      const stopArgs = async () => JSON.parse(await fs.readFile(log, 'utf8'));
      delete process.env.ORBIT_STOP_STUB_RESULT;
      await tool({ action: 'stop', task: started.task_directory, intent: 'pause', text: 'user interrupt' });
      const paused = await stopArgs();
      assert.ok(!paused.includes('--complete') && paused.includes('--reason'), 'pause keeps the reason, never --complete');

      await tool({ action: 'stop', task: started.task_directory, intent: 'complete' });
      assert.ok((await stopArgs()).includes('--complete'), 'complete intent carries --complete to the Ruby gate');

      await tool({ action: 'stop', task: started.task_directory });
      assert.ok((await stopArgs()).includes('--complete'), 'stop intent defaults to complete');
      process.env.ORBIT_STOP_STUB_RESULT = JSON.stringify({ task_directory: started.task_directory, status: 'rejected',
        reason: 'no_current_finalization_notice', next_action: 'request a final check and end the turn' });
      const refused = await tool({ action: 'stop', task: started.task_directory, intent: 'complete' });
      assert.ok(refused.status === 'rejected' && refused.next_action, 'an exit-0 structured refusal passes through unchanged with its next_action');
      assert.equal((await taskState()).status, 'running', 'a refused completion changes no record');
    } finally {
      if (savedRuby === undefined) delete process.env.ORBIT_RUBY; else process.env.ORBIT_RUBY = savedRuby;
      delete process.env.ORBIT_STOP_STUB_LOG;
      delete process.env.ORBIT_STOP_STUB_RESULT;
      await fs.rm(stubDir, { recursive: true, force: true });
    }
  }

  // 14. Same-turn status refresh (Zeen 2026-09-25 regression): a successful
  //     start must show the NEW task's real state immediately, in the same
  //     turn, not only at the next user turn. A rejected start must refresh
  //     nothing, so it can never present a task that was not accepted.
  {
    const statusCalls = [];
    const startCtx = { ...ctx, ui: { notify: () => {}, setStatus: (key, value) => statusCalls.push([key, value]) } };
    const stubDir = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-start-stub-'));
    const stub = path.join(stubDir, 'fake-ruby.mjs');
    // Emulates the real `orbit start` result shape: it creates a durable record
    // whose connection is the control socket that THIS host passed on the
    // command line, so ownership is decided exactly as in production.
    await fs.writeFile(stub, `#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const argv = process.argv.slice(2);
const flags = {};
for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) flags[argv[i]] = argv[i + 1];
if (process.env.ORBIT_START_STUB_FAIL) { process.stderr.write('start refused for test\\n'); process.exit(1); }
const id = 'stub-' + Date.now() + '-' + Math.random().toString(16).slice(2);
const dir = path.join(flags['--project'], '.orbit', 'tasks', id);
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify({
  format: 'orbit-task-1', id, project_root: flags['--project'],
  created_at: new Date().toISOString(), status: 'running',
  connection: { provider: 'omp', socket: flags['--socket'], thread_id: flags['--thread'] }
}));
process.stdout.write(JSON.stringify({ task_directory: dir, status: 'starting' }) + '\\n');
`);
    await fs.chmod(stub, 0o755);
    const savedRuby = process.env.ORBIT_RUBY;
    let newDir = null;
    try {
      // The old bound task is terminal: the turn's status line reads ITS state.
      const statePath = path.join(started.task_directory, 'state.json');
      const fixture = JSON.parse(await fs.readFile(statePath, 'utf8'));
      fixture.status = 'paused';
      await fs.writeFile(statePath, JSON.stringify(fixture));
      await emit('before_agent_start', { prompt: 'same turn', systemPrompt: ['BASE'] }, startCtx);
      assert.ok(statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('已暂停')),
        'the status line must first show the previous paused task');

      // A successful start in the SAME turn must immediately show the new task.
      process.env.ORBIT_RUBY = stub;
      statusCalls.length = 0;
      const started2 = await tool({ action: 'start', message_id: 'original' }, startCtx);
      newDir = started2.task_directory;
      assert.notEqual(newDir, started.task_directory, 'a successful start creates a new task record');
      assert.ok(statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('执行中')),
        'a successful start must refresh the status line to the new task in the same turn');
      assert.ok(!statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('已暂停')),
        'the previous paused label must not survive a successful start');

      // A rejected start must refresh nothing: no phantom takeover.
      const newState = JSON.parse(await fs.readFile(path.join(newDir, 'state.json'), 'utf8'));
      newState.status = 'paused'; // make the new task terminal so start re-runs the CLI
      await fs.writeFile(path.join(newDir, 'state.json'), JSON.stringify(newState));
      process.env.ORBIT_START_STUB_FAIL = '1';
      statusCalls.length = 0;
      await assert.rejects(() => tool({ action: 'start', message_id: 'original' }, startCtx), /start refused/);
      assert.equal(statusCalls.length, 0, 'a rejected start must not refresh or report a takeover');
      delete process.env.ORBIT_START_STUB_FAIL;
    } finally {
      delete process.env.ORBIT_START_STUB_FAIL;
      if (savedRuby === undefined) delete process.env.ORBIT_RUBY; else process.env.ORBIT_RUBY = savedRuby;
      if (newDir) await fs.rm(newDir, { recursive: true, force: true });
      await fs.rm(stubDir, { recursive: true, force: true });
    }
  }

  console.log('omp_native_gate_test: PASS');
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  if (started?.pid) {
    try { process.kill(-started.pid, 'SIGTERM'); } catch { /* already gone */ }
    for (let n = 0; n < 40; n++) {
      try { process.kill(started.pid, 0); } catch { break; }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    try { process.kill(-started.pid, 'SIGKILL'); } catch { /* already gone */ }
  }
  for (const native of sessions) native.dispose?.();
  await fs.rm(project, { recursive: true, force: true });
  await fs.rm(process.env.XDG_CONFIG_HOME, { recursive: true, force: true });
}

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { z } from 'zod';
import { installOmpExtension } from '../plugins/omp-host.mjs';
import { execSync } from 'node:child_process';

// The installer pins the verified Ruby via ORBIT_RUBY; exercise that branch so
// extension children (CLI spawns, member registration) use the same interpreter.
process.env.ORBIT_RUBY = process.env.ORBIT_RUBY || execSync('which ruby').toString().trim();

// M0.1/M0.2 gate test: real task record, real scripts/orbit-register-member,
// real socket bridge. No paid model calls (no provider traffic).
delete process.env.TYPESAFE_API_KEY;
process.env.XDG_CONFIG_HOME = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-gate-test-'));

const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-gate-')));
const events = {}, sessions = [];
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
  const brokenPi = { zod: z, registerTool: () => {}, on: (n, h) => { (brokenEvents[n] ||= []).push(h); } };
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

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { z } from 'zod';
import { installOmpExtension, agentNameFor } from '../plugins/omp-host.mjs';
import { observeNativeCalls, flushNativeCalls } from '../plugins/native-call-recorder.mjs';
import { execSync, spawnSync } from 'node:child_process';

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
const aborted = [], setStatuses = [], warnings = [];
let registryListener, definition, started;
// The extension registers several handlers per event name (task gate + hub
// observation on tool_call); keep them all and dispatch in order.
const emit = async (name, ...args) => {
  // Controlled native fixtures carry real durable handoffs. This does not
  // invoke a model and does not stand in for autonomous acceptance.
  const [event, context] = args;
  if (started?.task_directory && name === 'tool_call' && event?.toolName === 'task' &&
      context?.sessionManager?.getSessionId() === 'root' && !event.fixture_no_unit &&
      ['starting', 'running'].includes((await taskState()).status)) {
    const unit = await tool({ action: 'work-unit', task: started.task_directory, operation: 'declare', work_unit: {
      spec: { objective: event.input.task || 'Native member fixture', requirements: ['original request'],
        allowed_paths: ['src'], allowed_tools: ['read', 'write'], allowed_commands: [],
        acceptance: 'Fixture scope is honored', escalation: 'Report failed binding to Root' }
    } });
    event.input = { ...event.input, task: `${event.input.task}\norbit-unit: ${unit.unit.id}` };
  }
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
    emitNative: event => Promise.all([...listeners].map(listener => listener(event))),
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
  ui: { notify: (message, level) => warnings.push({ message, level }) } };
const memberCtx = { cwd: project, sessionManager: memberSession.sessionManager, models: { list: () => [model] }, hasUI: true,
  ui: { notify: () => {} } };
const pi = { zod: z, registerTool: tool => { definition = tool; },
  registerCommand: () => {},
  on: (name, handler) => { (events[name] ||= []).push(handler); } };
let discoverCtxThrows = false;
const sdk = { MAIN_AGENT_ID: mainAgentId,
  AgentRegistry: { global: () => registry, onChange: undefined, get: undefined },
  getAgentDir: () => process.env.PI_CODING_AGENT_DIR,
  isUserInterruptAbort: () => false,
  // Scriptable stand-in for the SDK's public context-file discovery; the
  // host rebuilds a rebound member's project instructions from it.
  discoverContextFiles: async cwd => {
    if (discoverCtxThrows) throw new Error('discovery-unavailable');
    if (cwd !== project) return [];
    return [{ path: '/user-config/AGENTS.md', content: 'USER-LEVEL-RULE' },
      { path: path.join(project, 'AGENTS.md'), content: 'NEW-PROJECT-RULE', depth: 0 }];
  } };

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
  // The real isolated preflight reads the parent OMP store. Supply a local
  // provider with a config credential; no model request or network is made.
  process.env.PI_CODING_AGENT_DIR = agentRoot;
  await fs.writeFile(path.join(agentRoot, 'models.yml'), `providers:
  glm:
    baseUrl: https://example.invalid/v1
    apiKey: fixture-key
    api: openai-completions
    models:
      - id: x
        name: Fixture GLM
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
`);
  process.env.ORBIT_SESSION_AGENT_ROOT = agentRoot;
  const poolStub = path.join(agentRoot, 'pool.sh');
  await fs.writeFile(poolStub, '#!/bin/sh\nprintf \'{"models":["glm/x"]}\\n\'\n');
  await fs.chmod(poolStub, 0o755);
  process.env.ORBIT_CLI_BIN = poolStub;
  installOmpExtension(pi, sdk);
  await emit("session_start", {}, ctx);

  // A verified Root without an active Orbit task may use native OMP task.
  // The call remains unsupervised and must not be registered as an Orbit member.
  const unbound = await emit("tool_call", { toolName: "task", toolCallId: "pre-start", input: { task: "x" } }, ctx);
  assert.equal(unbound, undefined, 'unbound native delegation stays available');
  assert.equal(warnings.filter(item => item.level === 'warning' && item.message.includes('未绑定 Orbit')).length, 1,
    'the Root sees that this native task is not independently checked by Orbit');
  await emit("tool_call", { toolName: "task", toolCallId: "second-unbound", input: { task: "y" } }, ctx);
  assert.equal(warnings.length, 1, 'the unsupervised warning is shown once per session');

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
  // 1c. Implementation-bootstrap guidance. A controlled task that has no work
  // unit must learn it in the FIRST provider payload the model answers — the
  // entry advisory cannot cover this because an explicit request never runs the
  // entry-3 judgment. An unextendable payload stays pending, the next reachable
  // window delivers once, and the task never repeats it.
  const bootWindow = { payload: { messages: [{ role: 'user', content: 'Original requirement.' }] } };
  // The bound system prompt carries only the regular status guidance: the
  // bootstrap never rides both the system prompt and the payload of one
  // request; the extensible payload is its only channel.
  const unitlessTurn = await emit('before_agent_start', { prompt: 'next', systemPrompt: ['BASE'] }, ctx);
  assert.ok(!(unitlessTurn?.systemPrompt ?? []).join('\n').includes('[orbit-bootstrap]'),
    'the bound system prompt never carries the work-unit bootstrap');
  const unextendable = await emit('before_provider_request', { payload: { messages: [] } }, ctx);
  assert.ok(!JSON.stringify(unextendable ?? {}).includes('[orbit-bootstrap]'),
    'a payload the injector cannot extend stays pending instead of reporting success');
  const booted = await emit('before_provider_request', bootWindow, ctx);
  const bootedText = (booted?.payload ?? booted)?.messages?.at(-1)?.content;
  assert.ok(typeof bootedText === 'string' && bootedText.includes('[orbit-bootstrap]'),
    'the first extendable payload carries the work-unit bootstrap for a task with no unit');
  const repeated = await emit('before_provider_request',
    { payload: { messages: [{ role: 'user', content: 'second window' }] } }, ctx);
  assert.ok(!JSON.stringify(repeated ?? {}).includes('[orbit-bootstrap]'),
    'the bootstrap is task-scoped and never repeats');
  const straySession = session('no-task-session', []);
  const strayCtx = { ...ctx, sessionManager: straySession.sessionManager };
  const stray = await emit('before_provider_request',
    { payload: { messages: [{ role: 'user', content: 'uncontrolled request' }] } }, strayCtx);
  assert.ok(!JSON.stringify(stray ?? {}).includes('[orbit-bootstrap]'),
    'an uncontrolled session is never given the bootstrap');
  // The factual pre-edit observation: what unit state existed before Root's
  // first explicit artifact edit, with the real tool_call_id, recorded once.
  const collabPath = path.join(started.task_directory, 'collaboration.jsonl');
  const collabEntries = async () => {
    const raw = await fs.readFile(collabPath, 'utf8').catch(() => '');
    return raw.split('\n').filter(Boolean).map(line => JSON.parse(line));
  };
  const waitFor = async predicate => {
    for (let n = 0; n < 20; n++) {
      const entries = await collabEntries();
      if (predicate(entries)) return entries;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    return collabEntries();
  };
  await emit('tool_call', { toolName: 'edit', toolCallId: 'root-edit-1', input: { path: 'src/parse.js' } }, ctx);
  const observed = (await waitFor(entries => entries.some(e => e.kind === 'unit_state_before_edit')))
    .filter(e => e.kind === 'unit_state_before_edit');
  assert.equal(observed.length, 1, 'the first Root artifact edit records one unit-state observation');
  assert.equal(observed[0].tool_call_id, 'root-edit-1', 'the observation keeps the real tool_call_id');
  assert.ok(['declared', 'none', 'unknown'].includes(observed[0].work_unit_state),
    'the observation states the observed unit state instead of guessing');
  assert.equal(Object.hasOwn(observed[0], 'delegation'), false, 'the observation never infers a delegation refusal');
  await emit('tool_call', { toolName: 'edit', toolCallId: 'root-edit-2', input: { path: 'src/parse.js' } }, ctx);
  assert.equal((await collabEntries()).filter(e => e.kind === 'unit_state_before_edit').length, 1,
    'the pre-edit observation is recorded once per task');
  await emit('tool_call', { toolName: 'bash', toolCallId: 'root-shell-1', input: { command: 'echo x > src/parse.js' } }, ctx);
  assert.equal((await collabEntries()).filter(e => e.kind === 'unit_state_before_edit').length, 1,
    'a shell command is never read as an artifact edit');
  // 1d. Controlled-Root cooperation policy. A bounded single-member serial
  //     handoff must be visible to the model at the SAME layer as the native
  //     system/developer instruction — on the first controlled request and on
  //     later ones (a policy, not a one-shot) — while shapes this release
  //     cannot place there stay honestly undelivered, and unowned/terminal
  //     records get nothing.
  {
    const policyCount = text => (String(text).match(/\[orbit-cooperation-policy\]/g) ?? []).length;
    // The SDK hook's return value IS the raw request body (never a wrapper), so
    // read the emitted value the same way the runtime does.
    const bodyOf = (out, original) => out?.payload ?? out ?? original;
    const codexShape = extra => ({ instructions: 'NATIVE SYSTEM PROMPT', input: [
      { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'do the thing' }] }], ...extra });
    const policyFacts = async () => (await waitFor(entries => entries.some(e => e.kind === 'cooperation_policy')))
      .filter(e => e.kind === 'cooperation_policy');

    // (a) bound + active: the policy joins the native system instruction layer
    //     and neither the native text nor the user turn is rewritten.
    const firstPayload = bodyOf(await emit('before_provider_request', { payload: codexShape() }, ctx), codexShape());
    assert.ok(firstPayload.instructions.startsWith('NATIVE SYSTEM PROMPT'), 'the native system text stays first');
    assert.equal(policyCount(firstPayload.instructions), 1, 'the policy reaches the system instruction layer');
    assert.equal(firstPayload.input[0].content[0].text, 'do the thing', 'the user turn is never used as the policy channel');
    const firstFacts = await policyFacts();
    assert.equal(firstFacts.length, 1, 'the first successful delivery records exactly one policy fact');
    assert.equal(firstFacts[0].channel, 'instructions', 'the recorded channel names the layer actually used');
    assert.equal(firstFacts[0].policy_version, 'orbit-cooperation-policy-1');
    assert.ok(firstFacts[0].instruction_sha256.startsWith('sha256:'), 'the fact keeps a text fingerprint');
    assert.equal(Object.hasOwn(firstFacts[0], 'input'), false, 'no raw payload is persisted');
    assert.equal(Object.hasOwn(firstFacts[0], 'payload'), false, 'no raw payload is persisted');

    // (b) a later request still carries it, exactly once per request.
    const secondShape = codexShape({ sequence_number: 7 });
    const secondPayload = bodyOf(await emit('before_provider_request', { payload: secondShape }, ctx), secondShape);
    assert.equal(policyCount(secondPayload.instructions), 1,
      'the policy persists on later requests without duplicating itself');
    assert.equal((await policyFacts()).length, 1, 'repeat delivery on the same channel is not re-recorded');

    // (c) Codex responses-lite: the native instruction already sits in a
    //     leading developer item, so the policy is appended AFTER that text in
    //     the same block instead of being prepended ahead of it.
    const lite = { input: [
      { type: 'additional_tools', role: 'developer', tools: [] },
      { type: 'message', role: 'developer', content: [{ type: 'input_text', text: 'NATIVE SYSTEM PROMPT' }] },
      { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'do the thing' }] }] };
    const liteOut = bodyOf(await emit('before_provider_request', { payload: lite }, ctx), lite);
    const developerText = liteOut.input[1].content[0].text;
    assert.ok(developerText.startsWith('NATIVE SYSTEM PROMPT') && policyCount(developerText) === 1,
      'the developer layer keeps the native text first and carries the policy after it');
    assert.equal(liteOut.instructions, undefined, 'the lite shape keeps no top-level instructions');

    // (c2) chat-completions bodies may carry the native system text as a
    //      developer-role message (the SDK uses role developer when the model
    //      reasons and the profile supports it): same authoritative layer, and
    //      it must be recorded under its own channel name.
    const developerMessages = { messages: [
      { role: 'developer', content: 'NATIVE SYSTEM PROMPT' },
      { role: 'user', content: 'do the thing' }] };
    const devOut = bodyOf(await emit('before_provider_request', { payload: developerMessages }, ctx), developerMessages);
    assert.ok(devOut.messages[0].content.startsWith('NATIVE SYSTEM PROMPT') && policyCount(devOut.messages[0].content) === 1,
      'a developer-role native message carries the policy after its own text');
    assert.equal(devOut.messages[1].content, 'do the thing', 'the user message stays untouched');
    const devFacts = (await policyFacts()).filter(entry => entry.channel === 'developer_message');
    assert.equal(devFacts.length, 1, 'the developer-message channel is recorded distinctly from system_message');

    // (d) Anthropic messages: the top-level system field is that provider's
    //     system layer, so the policy appends there.
    const anthropic = { system: 'NATIVE SYSTEM PROMPT', messages: [{ role: 'user', content: 'do the thing' }] };
    const anthropicOut = bodyOf(await emit('before_provider_request', { payload: anthropic }, ctx), anthropic);
    assert.equal(policyCount(anthropicOut.system), 1, 'an anthropic system field carries the policy');
    assert.equal(anthropicOut.messages[0].content, 'do the thing', 'the user turn is untouched there too');

    // (e) a messages payload with no system layer cannot host it: the request
    //     stays unpolluted instead of falling back to the user message.
    const bare = { messages: [{ role: 'user', content: 'no system layer here' }] };
    const bareOut = await emit('before_provider_request', { payload: bare }, ctx);
    assert.equal(policyCount(JSON.stringify(bareOut ?? {})), 0,
      'an unrecognised payload shape stays undelivered and unmodified');

    // (f) terminal records and uncontrolled sessions get nothing.
    const savedRaw = await fs.readFile(path.join(started.task_directory, 'state.json'), 'utf8');
    try {
      const paused = JSON.parse(savedRaw); paused.status = 'paused';
      await fs.writeFile(path.join(started.task_directory, 'state.json'), JSON.stringify(paused));
      const pausedShape = codexShape();
      const pausedOut = await emit('before_provider_request', { payload: pausedShape }, ctx);
      assert.equal(policyCount(JSON.stringify(bodyOf(pausedOut, pausedShape))), 0, 'a terminal task is never given the policy');
    } finally {
      await fs.writeFile(path.join(started.task_directory, 'state.json'), savedRaw);
    }
    const policyStray = session('no-task-policy-session', []);
    const strayPolicyOut = await emit('before_provider_request', { payload: codexShape() },
      { ...ctx, sessionManager: policyStray.sessionManager });
    assert.equal(policyCount(JSON.stringify(strayPolicyOut ?? {})), 0, 'an uncontrolled session is never given the policy');
    assert.equal(policyCount(JSON.stringify(
      await emit('before_provider_request', { payload: codexShape() }, memberCtx) ?? {})), 0,
      'a member session is never given the controlled-Root policy');

    // (g) a record controlled by ANOTHER process is not ours even while its
    //     status says running: real ownership is re-verified, never inferred.
    const unownedDir = path.join(project, '.orbit', 'tasks', 'policy-unowned-fixture');
    try {
      await fs.mkdir(unownedDir, { recursive: true });
      const unownedState = JSON.parse(savedRaw);
      unownedState.connection = { provider: 'omp', thread_id: 'policy-unowned', socket: '/tmp/not-our-socket.sock' };
      unownedState.status = 'running';
      await fs.writeFile(path.join(unownedDir, 'state.json'), JSON.stringify(unownedState));
      const unownedSession = session('policy-unowned', []);
      const unownedOut = await emit('before_provider_request', { payload: codexShape() },
        { ...ctx, sessionManager: unownedSession.sessionManager });
      assert.equal(policyCount(JSON.stringify(unownedOut ?? {})), 0,
        'a record whose control socket is not ours gets no policy');
    } finally {
      await fs.rm(unownedDir, { recursive: true, force: true });
    }

    // (h) coexistence with the one-shot bootstrap: the policy repeats as a
    //     policy while the bootstrap never does, and one request never carries
    //     the same sentence twice.
    const boundSystem = { messages: [{ role: 'system', content: 'NATIVE SYSTEM PROMPT' },
      { role: 'user', content: 'window one' }] };
    const firstWindow = bodyOf(await emit('before_provider_request', { payload: boundSystem }, ctx), boundSystem);
    const secondWindowShape = { messages: [{ role: 'system', content: 'NATIVE SYSTEM PROMPT' },
      { role: 'user', content: 'window two' }] };
    const secondWindow = bodyOf(await emit('before_provider_request', { payload: secondWindowShape }, ctx), secondWindowShape);
    const secondText = JSON.stringify(secondWindow ?? {});
    assert.equal(policyCount(JSON.stringify(firstWindow)), 1, 'the policy lands on the system message of this shape');
    assert.equal(policyCount(secondText), 1, 'the policy recurs on the next request');
    assert.ok(!JSON.stringify(firstWindow).includes('[orbit-bootstrap]'),
      'the bootstrap already sent for this task is not repeated by the policy');
    assert.ok(!secondText.includes('[orbit-bootstrap]'), 'nor on the later request');
  }
  assert.equal((await request('model_catalog')).agent_dir, agentRoot,
    'the catalog carries the host-resolved agent directory for isolated profile credentials');
  const declared = await tool({ action: 'work-unit', task: started.task_directory, operation: 'declare', work_unit: {
    spec: { objective: 'Deliver a bounded module', requirements: ['original request'],
      allowed_paths: ['src'], allowed_tools: ['read', 'write'], allowed_commands: [],
      acceptance: 'Module behavior passes its check', escalation: 'Report missing input to Root',
      model_requirements: { relevant_indices: ['coding_index'] } }
  } });
  assert.equal(declared.unit.status, 'declared', 'Root can durably declare a handoff through the actual Orbit tool');
  const units = await tool({ action: 'work-unit', task: started.task_directory, operation: 'list' });
  assert.equal(units.units[0].id, declared.unit.id, 'the host/CLI unit API reads the same durable store');
  // A declared work unit is exactly the state the cooperation policy must keep
  // reaching: the native instruction layer still carries it on the next request
  // (the one-shot bootstrap is gone by then), so the policy cannot silently
  // disappear once a handoff candidate exists.
  {
    const afterDeclare = { instructions: 'NATIVE SYSTEM PROMPT', input: [
      { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'after declare' }] }] };
    const afterDeclareOut = await emit('before_provider_request', { payload: afterDeclare }, ctx);
    const afterDeclareBody = afterDeclareOut?.payload ?? afterDeclareOut ?? afterDeclare;
    assert.equal(((String(afterDeclareBody?.instructions).match(/\[orbit-cooperation-policy\]/g)) ?? []).length, 1,
      'the policy still reaches the request after a real work unit was declared');
    assert.ok(!String(afterDeclareBody?.instructions).includes('[orbit-bootstrap]'),
      'the one-shot bootstrap is not smuggled back in as the policy');
  }
  // 1e. Generation-matched hint binding. Only a hint whose non-empty version
  // equals the persisted selection record for THIS unit rides the host gate.
  // The negatives (old generation against the same v2 selection, or two
  // missing versions) stay observations; the live-generation case then goes
  // through the REAL registration gate so the Ruby WorkUnitStore.bind
  // dispatch carries member, tool call, model, hint_signature and
  // hint_message_id — proving the hint reached the actual unit dispatch.
  {
    const hintedUnit = await tool({ action: 'work-unit', task: started.task_directory, operation: 'declare', work_unit: {
      spec: { objective: 'hint binding fixture', requirements: ['original request'],
        allowed_paths: ['src'], allowed_tools: ['read', 'write'], allowed_commands: [],
        acceptance: 'Fixture scope is honored', escalation: 'Report to Root' } } });
    const unitId = hintedUnit.unit.id;
    const statePath = path.join(started.task_directory, 'state.json');
    const sig = 'gate-hint-sig-v2';
    const writeHintState = async transform => {
      const state = JSON.parse(await fs.readFile(statePath, 'utf8'));
      state.member_selections = { [unitId]: { version: 'orbit-member-selection-v2', signature: sig, decision: 'recommended' } };
      state.delegation_hint = {
        version: 'orbit-member-selection-v2', signature: sig, message_id: 'gate-hint-msg',
        work_unit_id: unitId, input_digest: hintedUnit.unit.input_digest,
        artifact_root: hintedUnit.unit.artifact_root, dispatch_attempt: 1,
        user_boundary: state.last_user_message_id, followed: false,
        recommendation: { first: { model: 'glm/x', agent: agentNameFor('glm/x') }, backups: [] },
      };
      transform?.(state);
      await fs.writeFile(statePath, JSON.stringify(state));
    };
    const dispatchOf = async callId => (await waitFor(
      entries => entries.some(e => e.kind === 'task_dispatch' && e.tool_call_id === callId)))
      .filter(e => e.kind === 'task_dispatch' && e.tool_call_id === callId);
    // Negative first: an old-generation hint against the same v2 selection.
    await writeHintState(state => { state.delegation_hint.version = 'orbit-member-selection-v1'; });
    await emit('tool_call', { toolName: 'task', toolCallId: 'hint-bind-v1', fixture_no_unit: true,
      input: { agent: agentNameFor('glm/x'), task: `Stale hint dispatch\norbit-unit: ${unitId}` } }, ctx);
    const v1 = await dispatchOf('hint-bind-v1');
    assert.equal(v1.length, 1);
    assert.equal(v1[0].hint_signature, null, 'an old-generation hint against a v2 selection never binds');
    // Negative: two missing versions never pass as a generation match.
    await writeHintState(state => { delete state.delegation_hint.version; delete state.member_selections[unitId].version; });
    await emit('tool_call', { toolName: 'task', toolCallId: 'hint-bind-none', fixture_no_unit: true,
      input: { agent: agentNameFor('glm/x'), task: `Versionless dispatch\norbit-unit: ${unitId}` } }, ctx);
    const none = await dispatchOf('hint-bind-none');
    assert.equal(none.length, 1);
    assert.equal(none[0].hint_signature, null, 'two missing versions never pass as a generation match');
    // Positive LAST: the live v2 generation dispatches, then the REAL
    // registry registration window binds the unit with the hint attached.
    await writeHintState();
    const dispatched = await emit('tool_call', { toolName: 'task', toolCallId: 'hint-bind-live', fixture_no_unit: true,
      input: { agent: agentNameFor('glm/x'), task: `Hinted dispatch\norbit-unit: ${unitId}` } }, ctx);
    assert.ok(dispatched?.input?.name?.startsWith('orbit-'),
      `the hinted dispatch must assign the requested identity: ${JSON.stringify(dispatched)}`);
    const live = await dispatchOf('hint-bind-live');
    assert.equal(live.length, 1, 'the generation-matched dispatch is observed once');
    assert.equal(live[0].hint_signature, sig, 'the live-generation hint rides the host gate');
    const listeners = new Set();
    const liveSession = { sessionId: 'member-hint-live', model, isStreaming: false,
      sessionManager: memberSession.sessionManager,
      hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
      getAgentId: () => dispatched.input.name,
      subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
      sendCustomMessage: async () => {}, abort: async () => {},
      asyncJobManager: { cancelAll: () => {}, cancelAndReapOwnerJobs: async () => ({ settled: true }) } };
    const liveRef = { id: dispatched.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
      session: liveSession, sessionFile: '/tmp/hint-live.jsonl',
      history: { outputPath: '/tmp/hint-live.md', resolvedModel: 'glm/x' }, activity: 'working' };
    extraRefs.push(liveRef);
    registryListener({ type: 'registered', ref: liveRef });
    const boundUnits = await tool({ action: 'work-unit', task: started.task_directory, operation: 'list' });
    const bound = boundUnits.units.find(item => item.id === unitId);
    assert.equal(bound.status, 'bound', 'the real registration binds the hinted unit');
    assert.equal(bound.member_id, liveRef.id);
    assert.equal(bound.tool_call_id, 'hint-bind-live');
    assert.equal(bound.model, 'glm/x', 'the registration binds the actually observed model');
    assert.equal(bound.dispatches.length, 1);
    assert.equal(bound.dispatches[0].hint_signature, sig,
      'the hint signature reaches the actual Ruby work-unit dispatch record');
    assert.equal(bound.dispatches[0].hint_message_id, 'gate-hint-msg',
      'the bound dispatch carries the hint message id');
  }
  const missingUnit = await emit('tool_call', { toolName: 'task', toolCallId: 'no-unit',
    fixture_no_unit: true, input: { agent: agentNameFor('glm/x'), task: 'No handoff' } }, ctx);
  assert.equal(missingUnit.block, true, 'controlled execution cannot bypass the durable handoff');
  assert.match(missingUnit.reason, /work-unit/);
  await assert.rejects(() => tool({ action: 'work-unit', task: started.task_directory, operation: 'finish',
    work_unit: { id: declared.unit.id, status: 'accepted', result: 'done', verification: 'self-report' } }),
    /only a bound unit can finish/, 'declaring and self-reporting cannot fabricate a native dispatch');

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
  assert.equal((await request('model_catalog')).routes['glm/x'], 'unknown',
    'the pool Agent does not inherit the unrelated @task subscription route');
  ctx.models.list = () => [model, { provider: 'kimi-code', id: 'k3-256k' }];
  ctx.models.resolve = spec => spec === 'kimi-code/k3-256k'
    ? { provider: 'kimi-code', id: 'k3-256k', baseUrl: 'https://api.kimi.com/coding/v1',
        contextWindow: 262144, input: ['text', 'image'], cost: { input: 999 }, apiKey: 'private-key' }
    : undefined;
  const routeCatalog = await request('model_catalog');
  assert.equal(routeCatalog.routes['kimi-code/k3-256k'], 'subscription_quota',
    'a non-pooled checker also receives its exact resolved route');
  assert.deepEqual(routeCatalog.limits['kimi-code/k3-256k'], {
    source: 'omp_model_registry', context_window: 262144, input_modalities: ['text', 'image'],
    output_modalities: ['text'], supports_tools: true
  }, 'the configured route limit crosses the bridge; omitted supportsTools permits SDK native tools');
  assert.equal(JSON.stringify(routeCatalog).includes('private-key'), false, 'model credentials never cross the catalog bridge');
  assert.equal(Object.hasOwn(routeCatalog.limits['kimi-code/k3-256k'], 'cost'), false,
    'catalog prices are never represented as verified route costs');
  ctx.models.list = () => [model];
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
  // OpenCode Go: the verified first-party Go endpoint is a subscription plan;
  // the same provider on another path, another host, plain http or a
  // gateway-forwarded transport stays unknown.
  ctx.models.resolve = spec => spec === '@task'
    ? { provider: 'opencode-go', id: 'deepseek-v4.1-flash', baseUrl: 'https://opencode.ai/zen/go/v1' }
    : undefined;
  assert.deepEqual(await request('member_model'),
    { provider: 'opencode-go', id: 'deepseek-v4.1-flash', billing_route: 'subscription_quota' },
    'the verified OpenCode Go endpoint is subscription_quota');
  ctx.models.list = () => [{ provider: 'opencode-go', id: 'deepseek-v4.1-flash' }];
  assert.equal((await request('model_catalog')).routes['opencode-go/deepseek-v4.1-flash'], 'subscription_quota',
    'the Go plan route crosses the catalog bridge as subscription_quota');
  for (const [label, refused] of [
    ['the Zen non-Go path', { provider: 'opencode-go', id: 'deepseek-v4.1-flash', baseUrl: 'https://opencode.ai/zen/v1' }],
    ['another host with the same path', { provider: 'opencode-go', id: 'deepseek-v4.1-flash', baseUrl: 'https://opencode.ai.example/zen/go/v1' }],
    ['a plain-http Go endpoint', { provider: 'opencode-go', id: 'deepseek-v4.1-flash', baseUrl: 'http://opencode.ai/zen/go/v1' }],
    ['a gateway-forwarded Go endpoint', { provider: 'opencode-go', id: 'deepseek-v4.1-flash',
      baseUrl: 'https://opencode.ai/zen/go/v1', transport: 'pi-native' }]
  ]) {
    ctx.models.resolve = candidate => (candidate === '@task' ? refused : undefined);
    assert.deepEqual(await request('member_model'),
      { provider: 'opencode-go', id: 'deepseek-v4.1-flash', billing_route: 'unknown' },
      `${label} stays unknown`);
  }
  ctx.models.list = () => [model];
  ctx.models.resolve = () => undefined;
  await assert.rejects(() => request('member_model'), /unresolved/);
  assert.equal(await request('model'), 'glm/x', 'a failed task-role lookup does not replace the Root model');
  delete ctx.models.resolve;
  // Missing quality facts do not make a pool member unusable. Root can
  // explicitly choose it without pretending Jev recommended it.
  const pendingStatePath = path.join(started.task_directory, 'state.json');
  const pendingState = await taskState();
  pendingState.evidence_request = {
    identities: { root: null, candidates: [{ provider: 'glm', model: 'x', reasoning: 'unknown', billing_route: 'unknown' }] },
    needed: ['quality', 'speed', 'local_samples'], at: new Date().toISOString()
  };
  await fs.writeFile(pendingStatePath, JSON.stringify(pendingState));
  const premature = await emit('tool_call', { toolName: 'task', toolCallId: 'evidence-unanswered',
    input: { agent: agentNameFor('glm/x'), task: 'member work' } }, ctx);
  assert.ok(premature.input && !premature.block,
    'a pool-backed member remains available while Jev still needs exact model facts');

  // With a live pool member, generic @task must not silently resolve to a
  // different default model. The Root must name a pool Agent explicitly.
  ctx.models.resolve = () => ({ provider: 'zhipu-coding-plan', id: 'glm-5.2' });
  const poolBypass = await emit('tool_call', { toolName: 'task', toolCallId: 'pool-bypass',
    input: { agent: 'task', task: 'member work' } }, ctx);
  assert.equal(poolBypass.block, true, 'a pool-outside default model cannot bypass a nonempty controlled pool');
  assert.match(poolBypass.reason, new RegExp(agentNameFor('glm/x')));
  assert.match(poolBypass.reason, /orbit model-evidence/);
  pendingState.evidence_request.resolved = 'used';
  await fs.writeFile(pendingStatePath, JSON.stringify(pendingState));
  ctx.models.resolve = () => model;
  // Drift on the in-pool generic path: an actual member model that differs
  // from the pinned @task identity is aborted, never silently accepted.
  const driftOutside = await emit('tool_call', { toolName: 'task', toolCallId: 'outside-drift',
    input: { agent: 'task', task: 'drift work' } }, ctx);
  const driftOutsideRef = { id: driftOutside.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
    session: session('outside-drift-session'), sessionFile: null, history: {}, activity: null };
  driftOutsideRef.session.model = { provider: 'zenmux', id: 'x-ai/grok-4.6' };
  extraRefs.push(driftOutsideRef);
  registryListener({ type: 'registered', ref: driftOutsideRef });
  const driftOutsideEntry = (await membersFile()).find(m => m.thread_id === driftOutside.input.name);
  assert.equal(driftOutsideEntry.model_drift.expected, 'glm/x', 'drift records the pinned in-pool @task identity');
  assert.equal(driftOutsideEntry.model_drift.actual, 'zenmux/x-ai/grok-4.6', 'drift records the actual member model');
  assert.ok(setStatuses.some(([id, s]) => id === driftOutside.input.name && s === 'aborted'),
    'a drifted in-pool member must be aborted at registration');
  // The empty-pool case still permits the native default task model.
  const emptyPoolStub = path.join(agentRoot, 'pool-empty.sh');
  await fs.writeFile(emptyPoolStub, '#!/bin/sh\nprintf \'{"models":[]}\\n\'\n');
  await fs.chmod(emptyPoolStub, 0o755);
  const savedCliBin = process.env.ORBIT_CLI_BIN;
  process.env.ORBIT_CLI_BIN = emptyPoolStub;
  const emptyPool = await emit('tool_call', { toolName: 'task', toolCallId: 'empty-pool',
    input: { agent: 'task', task: 'work' } }, ctx);
  assert.ok(emptyPool.input && !emptyPool.block, 'an empty candidate pool does not block a known-model @task dispatch');
  process.env.ORBIT_CLI_BIN = savedCliBin;
  // Unknown effective model stays rejected.
  ctx.models.resolve = () => undefined;
  const unknown = await emit('tool_call', { toolName: 'task', toolCallId: 'unresolved-model',
    input: { agent: 'task', task: 'work' } }, ctx);
  assert.equal(unknown.block, true, 'an unresolvable @task model must be rejected');
  assert.match(unknown.reason, /cannot be resolved/);
  ctx.models.resolve = () => model;

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
  {
    const boundUnits = await tool({ action: 'work-unit', task: started.task_directory, operation: 'list' });
    const unit = boundUnits.units.find(item => item.member_id === liveRef.id);
    assert.equal(unit.status, 'bound');
    assert.equal(unit.tool_call_id, 'call-1');
    assert.equal(unit.model, 'glm/x', 'the registration binds the actually observed model');
    assert.equal(unit.dispatches.length, 1);
    const actualMemberCtx = { ...memberCtx, sessionManager: { ...memberCtx.sessionManager, getSessionId: () => 'member-live' } };
    const escaped = await emit('tool_call', { toolName: 'write', toolCallId: 'outside-write',
      input: { path: '../outside.txt', content: 'bad' } }, actualMemberCtx);
    assert.equal(escaped.block, true, 'the real extension entrance rejects a path outside the member scope');
    // Model-shaped SDK events are scripted here; they verify the real host
    // subscriptions and durable accounting path, not model-backed acceptance.
    await root.emitNative({ type: 'message_start', message: { role: 'assistant', provider: 'glm', model: 'x' } });
    await root.emitNative({ type: 'message_end', message: { role: 'assistant', provider: 'glm', model: 'x',
      stopReason: 'stop', usage: { input: 21, output: 4, cacheRead: 0, cacheWrite: 0 } } });
    for (const listener of liveMemberListeners)
      await listener({ type: 'message_start', message: { role: 'assistant', provider: 'glm', model: 'x' } });
    for (const listener of liveMemberListeners)
      await listener({ type: 'message_end', message: { role: 'assistant', provider: 'glm', model: 'x',
        stopReason: 'error', errorMessage: 'scripted failure', usage: { input: 17, output: 0, cacheRead: 0 } } });
    await flushNativeCalls(started.task_directory);
    const observations = JSON.parse(await fs.readFile(path.join(started.task_directory, 'native-model-calls.json'), 'utf8'));
    const receipts = Object.values(observations.calls);
    assert.equal(receipts.length, 2);
    assert.equal(receipts.find(call => call.meta.role === 'member').ledger_receipt.work_unit_id, unit.id);
    assert.equal(receipts.find(call => call.meta.role === 'member').ledger_receipt.status, 'failed');
    assert.deepEqual(receipts.find(call => call.meta.role === 'member').ledger_receipt.usage, { input: 17 });
    assert.ok(receipts.every(call => call.finalized && call.started_at && call.ledger_receipt.completed_at));
    assert.equal((await fs.stat(path.join(started.task_directory, 'native-model-calls.json'))).mode & 0o777, 0o600);
    const directlyRecorded = JSON.parse(await fs.readFile(path.join(started.task_directory, 'resource-calls.json'), 'utf8'));
    assert.equal(Object.keys(directlyRecorded.calls).length, 2, 'actual final observations persist without a runtime tick');
    const accounting = spawnSync(process.env.ORBIT_RUBY, ['--disable-gems', '-Ilib', '-rorbit/task_runtime', '-e',
      'record = Orbit::TaskRecord.new(ARGV[0]); runtime = Orbit::TaskRuntime.allocate; runtime.instance_variable_set(:@record, record); runtime.instance_variable_set(:@state, record.state); 2.times { runtime.send(:capture_native_calls) }; puts JSON.generate(runtime.send(:resource_call_ledger).calls)',
      started.task_directory], { cwd: process.cwd(), encoding: 'utf8' });
    assert.equal(accounting.status, 0, accounting.stderr);
    const accounted = JSON.parse(accounting.stdout);
    assert.equal(accounted.length, 2, 're-reading the native sidecar never double-counts a call');
    assert.equal(accounted.find(call => call.role === 'root').usage.input, 21);
    assert.equal(accounted.find(call => call.role === 'member').usage_status, 'partial');
    assert.ok(accounted.every(call => call.actual_identity.reasoning === null), 'an unreported reasoning setting stays absent');

    // A stop never seals a pending observation into an immutable unknown row.
    // A final SDK response can arrive while the Root session remains alive.
    await root.emitNative({ type: 'message_start', message: { role: 'assistant', provider: 'glm', model: 'x' } });
    await flushNativeCalls(started.task_directory);
    const savedState = await taskState();
    await fs.writeFile(path.join(started.task_directory, 'state.json'), JSON.stringify({ ...savedState, status: 'paused' }));
    const pendingAccounting = spawnSync(process.env.ORBIT_RUBY, ['--disable-gems', '-Ilib', '-rorbit/task_runtime', '-e',
      'record = Orbit::TaskRecord.new(ARGV[0]); runtime = Orbit::TaskRuntime.allocate; runtime.instance_variable_set(:@record, record); runtime.instance_variable_set(:@state, record.state); runtime.send(:capture_native_calls); puts JSON.generate({calls: runtime.send(:resource_call_ledger).calls, gaps: runtime.instance_variable_get(:@state).dig("usage", "resource_call_gaps")})',
      started.task_directory], { cwd: process.cwd(), encoding: 'utf8' });
    assert.equal(pendingAccounting.status, 0, pendingAccounting.stderr);
    assert.equal(JSON.parse(pendingAccounting.stdout).calls.length, 2, 'a pending call is never sealed or counted as zero');
    assert.match(JSON.parse(pendingAccounting.stdout).gaps.native_execution, /final usage is pending/);
    await root.emitNative({ type: 'message_end', message: { role: 'assistant', provider: 'glm', model: 'x',
      stopReason: 'stop', usage: { input: 31, output: 7, cacheRead: 0, cacheWrite: 0 } } });
    await flushNativeCalls(started.task_directory);
    const lateRecorded = Object.values(JSON.parse(await fs.readFile(path.join(started.task_directory, 'resource-calls.json'), 'utf8')).calls);
    assert.equal(lateRecorded.length, 3, 'late final usage is recorded after runtime termination without reopening the task');
    assert.equal(lateRecorded.find(call => call.usage?.input === 31).usage.output, 7);
    assert.equal((await taskState()).status, 'paused', 'host accounting never overwrites runtime-owned task state');
    await fs.writeFile(path.join(started.task_directory, 'state.json'), JSON.stringify(savedState));

    const corruptDir = path.join(project, '.orbit', 'tasks', 'corrupt-native-receipt');
    await fs.mkdir(corruptDir);
    await fs.writeFile(path.join(corruptDir, 'state.json'), JSON.stringify({ ...savedState,
      id: path.basename(corruptDir), status: 'paused' }));
    await fs.writeFile(path.join(corruptDir, 'native-model-calls.json'), '{corrupt');
    const corruptSession = session('corrupt-native-receipt');
    observeNativeCalls(corruptSession, () => ({ taskDir: corruptDir, projectRoot: project,
      role: 'root', actualProvider: 'glm', actualModelId: 'x', actualModel: 'glm/x', billingRoute: 'unknown' }));
    await corruptSession.emitNative({ type: 'message_start', message: { role: 'assistant' } });
    await corruptSession.emitNative({ type: 'message_end', message: { role: 'assistant', provider: 'glm', model: 'x',
      stopReason: 'stop', usage: { input: 9, output: 2, cacheRead: 0, cacheWrite: 0 } } });
    await flushNativeCalls(corruptDir);
    assert.match(await fs.readFile(path.join(corruptDir, 'native-model-call-gaps.jsonl'), 'utf8'), /persistence failed/);
    assert.equal((await fs.stat(path.join(corruptDir, 'native-model-call-gaps.jsonl'))).mode & 0o777, 0o600);
    assert.equal(Object.keys(JSON.parse(await fs.readFile(path.join(corruptDir, 'resource-calls.json'), 'utf8')).calls).length, 1,
      'sidecar corruption remains visible while independently preserving the final receipt');
    await fs.rm(corruptDir, { recursive: true, force: true });
  }
  const members = await membersFile();
  assert.equal(members.length, 3); // drifted in-pool member, this pool member, and the 1e hint-bound member
  const poolMember = members.find(m => m.thread_id === revised.input.name);
  assert.equal(poolMember['requested_name'], revised.input.name);
  assert.equal(poolMember.status, 'registered');
  assert.equal(poolMember.model, 'glm/x');
  assert.equal(poolMember['tool_call_id'], 'call-1');

  // 2c. Workspace rebind (real runtime cwd): the Root session cwd is never
  //     compared or mutated; the member child session cwd is set to the
  //     unit's current artifact_root at the registration window and verified
  //     by read-back. A member whose cwd cannot reach it never binds.
  {
    const elsewhere = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-member-cwd-')));
    // (a) Pre-dispatch: a Root session running from a DIFFERENT real cwd (the
    // post-rebind situation) is not blocked on cwd; only the declared
    // workspace must be real.
    const reboundCall = await emit('tool_call', { toolName: 'task', toolCallId: 'call-rebind',
      input: { task: 'rebound member work' } }, { ...ctx, cwd: elsewhere });
    assert.ok(!reboundCall.block, `post-rebind dispatch must not compare Root cwd: ${JSON.stringify(reboundCall)}`);

    // (b) Registration sets the child session's real cwd to artifact_root and
    // binds; Root's own session cwd is untouched.
    let memberCwd = elsewhere;
    let refreshSeen = 0;
    const reboundListeners = new Set();
    const reboundSession = { sessionId: 'rebind-sess', model, isStreaming: false,
      sessionManager: { getSessionId: () => 'rebind-sess', getCwd: () => memberCwd,
        setCwdWithoutRelocation: next => { memberCwd = path.resolve(next); }, getBranch: () => [] },
      getAgentId: () => reboundCall.input.name,
      hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
      subscribe: listener => { reboundListeners.add(listener); return () => reboundListeners.delete(listener); },
      refreshSkillsAndCommands: async () => { refreshSeen += 1; },
      abort: async () => {},
      asyncJobManager: { cancelAll: () => {}, cancelAndReapOwnerJobs: async () => ({ settled: true }) } };
    const reboundRef = { id: reboundCall.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
      session: reboundSession, sessionFile: null, history: {}, activity: null };
    extraRefs.push(reboundRef);
    registryListener({ type: 'registered', ref: reboundRef });
    assert.equal(memberCwd, project, 'member session cwd must become the unit artifact_root');
    assert.equal(root.sessionManager.getCwd(), project, 'Root session cwd is never mutated');
    await new Promise(resolve => setImmediate(resolve));
    assert.ok(refreshSeen >= 1, 'skills/commands metadata realign is requested best-effort after the cwd change');
    const reboundUnits = await tool({ action: 'work-unit', task: started.task_directory, operation: 'list' });
    assert.equal(reboundUnits.units.find(item => item.member_id === reboundRef.id)?.status, 'bound',
      'a member whose cwd reached artifact_root binds normally');
    const reboundStop = await request('stop_member', { id: reboundRef.id });
    assert.equal(reboundStop.confirmed, true);

    // (c) Fail-closed: the child cwd cannot be set (runtime refuses) -> the
    // member is aborted, never binds, and its tool gate stays closed.
    const stuckCall = await emit('tool_call', { toolName: 'task', toolCallId: 'call-stuck',
      input: { task: 'stuck member work' } }, ctx);
    assert.ok(!stuckCall.block, JSON.stringify(stuckCall));
    const stuckSession = { sessionId: 'stuck-sess', model, isStreaming: false,
      sessionManager: { getSessionId: () => 'stuck-sess', getCwd: () => elsewhere,
        setCwdWithoutRelocation: () => { throw new Error('cwd locked'); }, getBranch: () => [] },
      getAgentId: () => stuckCall.input.name,
      hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
      subscribe: () => () => {},
      abort: async () => {},
      asyncJobManager: { cancelAll: () => {}, cancelAndReapOwnerJobs: async () => ({ settled: true }) } };
    const stuckRef = { id: stuckCall.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
      session: stuckSession, sessionFile: null, history: {}, activity: null };
    extraRefs.push(stuckRef);
    registryListener({ type: 'registered', ref: stuckRef });
    assert.ok(setStatuses.some(([id, status]) => id === stuckRef.id && status === 'aborted'),
      'a member without the real workspace cwd is aborted at registration');
    const stuckUnits = await tool({ action: 'work-unit', task: started.task_directory, operation: 'list' });
    assert.equal(stuckUnits.units.some(item => item.member_id === stuckRef.id), false,
      'a member without the real workspace cwd never binds');
    const stuckTool = await emit('tool_call', { toolName: 'write', toolCallId: 'stuck-write',
      input: { path: 'src/x.txt', content: 'x' } },
      { ...memberCtx, sessionManager: { ...memberCtx.sessionManager, getSessionId: () => 'stuck-sess' } });
    assert.equal(stuckTool.block, true, 'an unbound member keeps its tool gate closed');
    await fs.rm(elsewhere, { recursive: true, force: true });
  }

  // 2d. Rebound project context: the member's FIRST prompt already carries
  //     the real artifact_root instructions; the spawn-time project rules are
  //     gone; user-level rules and every other prompt part survive untouched.
  //     A discovery failure is durably recorded and aborts preparation.
  {
    const ctxCall = await emit('tool_call', { toolName: 'task', toolCallId: 'call-ctx', input: { task: 'context member work' } }, ctx);
    assert.ok(!ctxCall.block, JSON.stringify(ctxCall));
    const elsewhere = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-ctx-cwd-')));
    let ctxMemberCwd = elsewhere;
    const ctxSession = { sessionId: 'ctx-sess', model, isStreaming: false,
      sessionManager: { getSessionId: () => 'ctx-sess', getCwd: () => ctxMemberCwd,
        setCwdWithoutRelocation: next => { ctxMemberCwd = path.resolve(next); }, getBranch: () => [] },
      getAgentId: () => ctxCall.input.name,
      hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
      subscribe: () => () => {}, abort: async () => {},
      asyncJobManager: { cancelAll: () => {}, cancelAndReapOwnerJobs: async () => ({ settled: true }) } };
    const ctxRef = { id: ctxCall.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
      session: ctxSession, sessionFile: null, history: {}, activity: null };
    extraRefs.push(ctxRef);
    registryListener({ type: 'registered', ref: ctxRef });
    assert.equal(ctxMemberCwd, project, 'registration applies the real workspace cwd first');
    let contextAborts = 0;
    const ctxMemberCtx = { ...memberCtx, abort: () => { contextAborts += 1; },
      sessionManager: { ...memberCtx.sessionManager, getSessionId: () => 'ctx-sess' } };

    const startEvent = { prompt: 'ORIGINAL-USER-REQUEST',
      systemPrompt: ['BASE-PART',
        `intro\n<file path="/old/project/AGENTS.md">\nOLD-PROJECT-RULE\n</file>\noutro`,
        'tail-part'] };
    const replaced = await emit('before_agent_start', startEvent, ctxMemberCtx);
    assert.ok(replaced?.systemPrompt, 'the first pre-request hook already rebuilds the project context');
    const joined = replaced.systemPrompt.join('\n');
    assert.ok(!joined.includes('OLD-PROJECT-RULE'), 'spawn-time project rules are removed');
    assert.ok(joined.includes('NEW-PROJECT-RULE'), 'real artifact_root instructions are present');
    assert.ok(joined.includes('USER-LEVEL-RULE'), 'user-level rules survive');
    assert.ok(joined.includes('intro') && joined.includes('outro') && joined.includes('BASE-PART') && joined.includes('tail-part'),
      'wrappers and every other prompt part stay untouched');
    assert.equal(replaced.prompt, undefined, 'the user request text is never rewritten');
    // Root's own preparation is never rewritten.
    const rootStart = await emit('before_agent_start', { prompt: 'root turn',
      systemPrompt: ['<file path="/old/project/AGENTS.md">\nOLD-PROJECT-RULE\n</file>'] }, ctx);
    assert.ok(!rootStart?.systemPrompt || (rootStart.systemPrompt.join('\n').includes('OLD-PROJECT-RULE') &&
      !rootStart.systemPrompt.join('\n').includes('NEW-PROJECT-RULE')),
      'Root system prompt context entries are never rewritten');

    // Discovery failure: durably recorded, the prompt is refused outright
    // and the member tool gate closes — no round runs on stale instructions,
    // no first-round-run/second-round-repair.
    discoverCtxThrows = true;
    const failed = await emit('before_agent_start', { prompt: 'again',
      systemPrompt: ['<file path="/old/project/AGENTS.md">\nOLD-PROJECT-RULE\n</file>'] }, ctxMemberCtx);
    assert.equal(contextAborts, 1, 'a failed discovery cancels actual prompt preparation through the public abort API');
    assert.ok(setStatuses.some(([id, status]) => id === ctxRef.id && status === 'aborted'),
      'the registered member is also marked aborted');
    assert.ok(!failed?.systemPrompt, 'a refused prompt is never rewritten');
    await emit('before_provider_request', { payload: {} }, ctxMemberCtx);
    assert.equal(contextAborts, 2, 'a blocked member also aborts a later provider continuation');
    const blockedTool = await emit('tool_call', { toolName: 'read', toolCallId: 'ctx-tool-1', input: { path: 'x' } }, ctxMemberCtx);
    assert.equal(blockedTool?.block, true, 'the member tool gate stays closed while context is blocked');
    discoverCtxThrows = false;
    const collab = await fs.readFile(path.join(started.task_directory, 'collaboration.jsonl'), 'utf8');
    assert.ok(collab.includes('work_unit_context_failed'), 'the context failure is durably recorded');
    // A later successful preparation clears the block and applies the real
    // context for that round.
    const recovered = await emit('before_agent_start', { prompt: 'again',
      systemPrompt: ['intro\n<file path="/old/project/AGENTS.md">\nOLD-PROJECT-RULE\n</file>\noutro'] }, ctxMemberCtx);
    assert.ok(recovered?.systemPrompt?.join('\n').includes('NEW-PROJECT-RULE'),
      'a later successful preparation clears the block and applies the real context');
    await request('stop_member', { id: ctxRef.id });
    await fs.rm(elsewhere, { recursive: true, force: true });
  }

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
  // Keep the fixture pool live for the remaining generic @task gate probes.

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

  // 7. A second host instance without task ownership cannot dispatch into
  // the first instance's active Orbit task; missing registry support stays blocked.
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
  assert.equal(gated.block, true, 'an active task owned by another host cannot accept dispatch');
  assert.match(gated.reason, /active Orbit task is not owned/);
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

  // Native /exit unregisters members before the extension's shutdown hook.
  // The exact retained session remains a disposal barrier, never a bare-id pass.
  {
    const call = await emit('tool_call', { toolName: 'task', toolCallId: 'call-unregistered', input: { task: 'exit member' } }, ctx);
    let disposals = 0;
    const session = { sessionId: 'exit-member-session', isStreaming: false,
      subscribe: () => () => {}, hasPendingAsyncWork: () => false,
      dispose: async () => { disposals++; },
      model: { provider: 'glm', id: 'x' } };
    const ref = { id: call.input.name, kind: 'sub', parentId: mainAgentId,
      status: 'idle', session, history: {} };
    extraRefs.push(ref);
    registryListener({ type: 'registered', ref });
    extraRefs.splice(extraRefs.indexOf(ref), 1);
    const confirmation = await request('stop_member', { id: ref.id });
    assert.equal(confirmation.confirmed, true);
    assert.equal(confirmation.active_tools_after, 0);
    assert.equal(disposals, 1, 'missing registry identity still awaits actual session disposal');
    assert.equal((await request('stop_member', { id: ref.id })).confirmed, true);
    await assert.rejects(() => request('stop_member', { id: 'orbit-foreign' }), /not owned/);
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
  await fs.rm(agentRoot, { recursive: true, force: true });
  delete process.env.ORBIT_CLI_BIN;

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
    const activeStatus = statusCalls.at(-1);
    assert.equal(activeStatus?.[0], 'orbit', 'an active task refreshes the OMP status line');
    // A manual check starts after Root's completed reply; the durable record
    // has an in-flight observation but no longer has next_check_manual=true.
    // Do not invite another check while the independent reviewer is running.
    await setState({ check_observations: { final: { status: 'in_flight', manual: true } },
      next_check_manual: false, next_check_trigger: 'manual_check',
      completion_readiness: { status: 'waiting', reason: '尚无当前版本的有效终检' } });
    const checkingText = await statusTurn('review in progress');
    assert.match(statusCalls.at(-1)?.[1], /独立检查进行中/, 'status bar shows the live review rather than asking for another check');
    assert.match(checkingText, /等待独立检查结果/, 'Root gets an actionable wait instruction');
    assert.doesNotMatch(checkingText, /调用 Orbit action=check/, 'in-flight review must not request a duplicate manual check');
    await setState({ check_observations: {}, next_check_trigger: 'timer' });
    // Kickoff ④/⑤: an invalidated notice on a RUNNING task asks only for a
    // new valid manual final check; the user bar names no user work.
    await setState({ completion_readiness: { status: 'invalidated', reason: '产物在通知后变化' } });
    const invalidatedText = await statusTurn('notice invalidated');
    assert.match(statusCalls.at(-1)?.[1], /检查通知已失效.*用户无需操作/,
      'the bar explains the invalidated notice without assigning the user work');
    assert.match(invalidatedText, /仍需当前版本的有效手动终检/,
      'Root is told a new valid manual final check is required, not a repeat of the old notice');
    await setState({ status: 'complete', stop_confirmation: { confirmed: true } });
    for (let n = 0; n < 30 && !statusCalls.at(-1)?.[1]?.includes('已完成'); n++)
      await new Promise(resolve => setTimeout(resolve, 100));
    assert.match(statusCalls.at(-1)?.[1], /已完成/,
      'completion after the final turn updates the idle pane without another model turn or tool call');
    // Kickoff ④: a paused task advises a new task on the bar and injects no
    // block that could ask the stopped record for a re-check.
    await setState({ status: 'paused', stop_confirmation: { confirmed: true } });
    assert.equal(await statusTurn('after ordinary stop'), '', 'a paused task injects no system prompt block');
    assert.match(statusCalls.at(-1)?.[1], /已暂停.*若仍需交付请新建任务/,
      'the paused bar advises a new task instead of a re-check');
    assert.doesNotMatch(statusCalls.at(-1)?.[1], /重检|补齐/,
      'the paused bar never asks the stopped task for artifacts or another check');
    await setState({ status: 'running', stop_confirmation: null, completion_readiness: { status: 'waiting', reason: '尚无当前版本的有效终检' } });
    // A record whose control socket is not this host's is what an OMP restart
    // leaves: shown as unowned, never controlled (the tool would refuse it).
    const boundConnection = (await taskState()).connection;
    await setState({ connection: { ...boundConnection, socket: path.join(os.tmpdir(), 'orbit-gone-control.sock') } });
    const staleText = await statusTurn('after crash');
    assert.ok(staleText.includes(started.task_directory), 'an unowned record provides the cleanup task directory');
    const staleStatus = statusCalls.at(-1);
    assert.equal(staleStatus?.[0], 'orbit');
    assert.notEqual(staleStatus[1], activeStatus[1], 'lost ownership is not presented as active control');
    // Owned but dead runtime: the socket matches this host, the recorded runtime is gone.
    const { runtime_pid: savedPid, finished_at: savedFinished } = await taskState();
    await setState({ connection: boundConnection, runtime_pid: null, finished_at: new Date().toISOString() });
    const lostText = await statusTurn('runtime died');
    assert.ok(lostText.includes(started.task_directory), 'a dead runtime provides the cleanup task directory');
    const lostStatus = statusCalls.at(-1);
    assert.equal(lostStatus?.[0], 'orbit');
    assert.notEqual(lostStatus[1], activeStatus[1], 'a dead runtime is not presented as active execution');
    // Terminal task: the status line refreshes but no per-turn block is injected.
    await setState({ runtime_pid: savedPid, finished_at: savedFinished, status: 'paused' });
    assert.equal(await statusTurn('next'), '', 'a terminal task injects no system prompt block');
    assert.notEqual(statusCalls.at(-1)?.[1], activeStatus[1], 'a paused task refreshes the phase in the status line');
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
      assert.ok(recoveredText.includes(started.task_directory), 'a recovered task gives its explicit cleanup directory');
      assert.equal(recoveryStatus.at(-1)?.[0], 'orbit', 'recovery refreshes the OMP status line');
    } finally {
      events = savedEvents;
      if (savedRoot) process.env.ORBIT_SESSION_AGENT_ROOT = savedRoot;
    }
  }

  // 12c. Entry-delegation advisory — qualification negatives and the existing
  //      task fallback: the already-paid pre-start entry judgment reaches Root
  //      exactly once when it cleared its calibrated delegation threshold and
  //      no unit is declared. Complete-but-old rulesets, unknown calibration
  //      schemas, model drift, below-threshold values, amended inputs and
  //      already-declared units all stay silent. The real auto-start lifecycle
  //      lives in 12d; this block covers only the fallback channel on a task
  //      that already exists.
  {
    const advisoryState = async patch =>
      fs.writeFile(path.join(started.task_directory, 'state.json'), JSON.stringify({ ...(await taskState()), ...patch }));
    const advisoryTurn = async () => {
      const out = await emit('before_agent_start', { prompt: 'next', systemPrompt: ['BASE'] }, ctx);
      return out ? out.systemPrompt.join('\n') : '';
    };
    const advisoryLine = text => text.split('\n').find(line => line.includes('[orbit-entry-advisory]'));
    const unitsPath = path.join(started.task_directory, 'work-units.json');
    const savedUnits = await fs.readFile(unitsPath, 'utf8').catch(() => null);
    const savedEntry = (await taskState()).entry || null;
    const savedAmendments = (await taskState()).amendments || [];
    // The production trace shape (measured against the live
    // EntryCalibration.load release and a real 0.7.20 task record):
    // top-level versions/provider/models/question_digest, and the validated
    // release merged into `calibration` — schema + version binding + digest +
    // the calibrated model and thresholds.
    const calibrationOf = (overrides = {}) => ({
      reason: 'fixture release', scope: 'fixture scope', profile: 'git_untruncated_request_v1',
      reviewed_by: 'fixture', reviewed_at: '2026-09-29T14:33:28Z',
      schema_version: 'orbit-entry-calibration-v2', rule_version: 'orbit-entry-rules-3',
      question_set_version: 'orbit-entry-3', input_version: 'orbit-entry-input-2',
      decision_version: 'orbit-entry-decision-2', question_digest: 'dg-current',
      model: 'jev-1.13.0',
      thresholds: { execution_authorized: 0.85, delegation_value: 0.65, supervision_value: 0.65 },
      sample_count: 8, sample_digest: 'sd-current', ...overrides,
    });
    const entryDocument = (overrides = {}) => ({
      decision: 'start', message_id: 'm1',
      trace: {
        rule_version: 'orbit-entry-rules-3', input_version: 'orbit-entry-input-2',
        decision_version: 'orbit-entry-decision-2', question_set_version: 'orbit-entry-3',
        judgment_status: 'answered', provider: 'typesafe',
        actual_model: 'jev-1.13.0', requested_model: 'jev-1.13.0', question_digest: 'dg-current',
        calibration: calibrationOf(),
        thresholds: { execution_authorized: 0.85, delegation_value: 0.65, supervision_value: 0.65 },
        probabilities: { execution_authorized: { probability_true: 0.9 },
          delegation_value: { probability_true: 0.85 }, supervision_value: { probability_true: 0.51 } },
        ...(overrides.trace || {}),
      },
      ...(overrides.entry || {}),
    });
    // (a) below threshold: no advisory.
    await advisoryState({ entry: entryDocument({ trace: { thresholds: { execution_authorized: 0.85, delegation_value: 0.9, supervision_value: 0.65 } } }) });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'a below-threshold entry value never advises');
    // (b) COMPLETE but older ruleset (every field populated, self-consistent,
    //     not the current pinned versions): rejected on the version pin.
    await advisoryState({ entry: entryDocument({ trace: {
      rule_version: 'orbit-entry-rules-2', input_version: 'orbit-entry-input-1',
      decision_version: 'orbit-entry-decision-1', question_set_version: 'orbit-entry-2',
      question_digest: 'dg-old',
      calibration: calibrationOf({ rule_version: 'orbit-entry-rules-2', input_version: 'orbit-entry-input-1',
        decision_version: 'orbit-entry-decision-1', question_set_version: 'orbit-entry-2', question_digest: 'dg-old' }),
    } }) });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'a complete older-ruleset trace is rejected by the current-version pin');
    // (c) unknown calibration schema (current versions, stale release schema).
    await advisoryState({ entry: entryDocument({ trace: { calibration: calibrationOf({ schema_version: 'orbit-entry-calibration-v1' }) } }) });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'an unknown calibration schema stays silent');
    // (d) actual model drift away from the requested/calibrated model.
    await advisoryState({ entry: entryDocument({ trace: { actual_model: 'zhipu/glm-5.3' } }) });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'a model-drifted attribution stays silent');
    // (d2) an old projection without the calibrated model stays silent.
    await advisoryState({ entry: entryDocument({ trace: { calibration: calibrationOf({ model: undefined }) } }) });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'a calibration without the calibrated model stays silent');
    // (d3) profile must match exactly: a missing profile is not a pass.
    await advisoryState({ entry: entryDocument({ trace: { calibration: calibrationOf({ profile: undefined }) } }) });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'a calibration without the observable profile stays silent');
    // (e) amended input: the old score never rides along.
    await advisoryState({ entry: entryDocument(), amendments: [{ path: 'amendments/1.txt' }] });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'an amended task never re-uses the old entry score');
    // (f) a declared unit suppresses the advisory.
    await fs.writeFile(unitsPath, JSON.stringify({ format: 'orbit-work-units-2', task_id: (await taskState()).id,
      units: { 'wu-fixture': { id: 'wu-fixture', task_id: (await taskState()).id } } }));
    await advisoryState({ entry: entryDocument(), amendments: [] });
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'an already-declared unit suppresses the entry advisory');
    // (g) fallback positive: an already-existing task with a qualified current
    //     fact gets exactly one advisory on this channel; the valid empty unit
    //     store is the no-handoff state. Restores the saved file afterwards.
    await fs.writeFile(unitsPath, JSON.stringify({ format: 'orbit-work-units-2', task_id: (await taskState()).id, units: {} }));
    const qualified = await advisoryTurn();
    const line = advisoryLine(qualified);
    assert.ok(line, 'a qualified entry fact advises on the existing-task fallback');
    assert.ok(line.includes('0.85') && line.includes('0.65') && line.includes('Root 自主决定'),
      'the advisory states the measured fact and leaves the decision to Root');
    assert.ok(!/已选|节省|成本|预算|耗时/.test(line),
      'the advisory never claims a member is selected or adds cost/time claims');
    assert.ok(!(await advisoryTurn()).includes('[orbit-entry-advisory]'),
      'the advisory never repeats in this process');
    if (savedUnits === null) await fs.rm(unitsPath, { force: true });
    else await fs.writeFile(unitsPath, savedUnits);
    await advisoryState({ entry: savedEntry, amendments: savedAmendments });
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
      assert.ok(statusCalls.some(([key, value]) => key === 'orbit' && String(value).includes('任务尚未完成')),
        'a successful start must refresh the status line to an active, not-yet-complete task in the same turn');
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

  // 12d. Entry-delegation advisory on the REAL auto-start lifecycle: an
  //      unbound main session runs the entry hook inside
  //      before_provider_request, which creates the task through the real
  //      start path and injects the advisory into THAT request payload (the
  //      first reachable window — before_agent_start runs before the task
  //      exists). The next reachable request with another user message never
  //      repeats it. No task is pre-seeded for this block.
  {
    const realRuby = process.env.ORBIT_RUBY || 'ruby';
    const advDir = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-adv-'));
    const traceShape = {
      rule_version: 'orbit-entry-rules-3', input_version: 'orbit-entry-input-2',
      decision_version: 'orbit-entry-decision-2', question_set_version: 'orbit-entry-3',
      provider: 'typesafe', actual_model: 'jev-1.13.0', call_id: 'call-fixture',
      judgment_status: 'answered', requested_model: 'jev-1.13.0',
      thresholds: { execution_authorized: 0.85, delegation_value: 0.65, supervision_value: 0.65 },
      question_digest: 'dg-current',
      calibration: { reason: 'fixture', scope: 'fixture', profile: 'git_untruncated_request_v1',
        reviewed_by: 'fixture', reviewed_at: '2026-09-29T14:33:28Z',
        schema_version: 'orbit-entry-calibration-v2', rule_version: 'orbit-entry-rules-3',
        question_set_version: 'orbit-entry-3', input_version: 'orbit-entry-input-2',
        decision_version: 'orbit-entry-decision-2', question_digest: 'dg-current',
        model: 'jev-1.13.0',
        thresholds: { execution_authorized: 0.85, delegation_value: 0.65, supervision_value: 0.65 },
        sample_count: 8, sample_digest: 'sd-current' },
      probabilities: { execution_authorized: { probability_true: 0.9 },
        delegation_value: { probability_true: 0.85 }, supervision_value: { probability_true: 0.51 } },
      usage: { input_tokens: 1, output_tokens: 1 },
    };
    // The entry trace template follows the VALIDATED release shape (measured
    // from the live EntryCalibration.load + PrestartClassifier projection).
    const templatePath = path.join(advDir, 'entry-template.json');
    await fs.writeFile(templatePath, JSON.stringify({ classification: 'uncertain', decision: 'start',
      reason: 'fixture', message_id: 'adv-user-1',
      source: { id: 'adv-user-1', kind: 'native_user_message' }, trace: traceShape }));
    // Entry shim: answers the unpaid-shape `entry` call without any model or
    // network (binding the trace to the actual message id), and delegates
    // every other subcommand (start/status/...) to the real Ruby CLI, so the
    // task record, entry trace and runtime are real.
    const shim = path.join(advDir, 'orbit-shim.mjs');
    await fs.writeFile(shim, `#!/usr/bin/env node
import { spawnSync, } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
if (args.includes('entry')) {
  const mid = args[args.indexOf('--message-id') + 1] || 'unknown';
  const doc = JSON.parse(readFileSync(process.env.ORBIT_ADV_TRACE_TEMPLATE, 'utf8'));
  doc.message_id = mid;
  if (doc.source) doc.source.id = mid;
  const file = process.env.ORBIT_ADV_ENTRY_DIR + '/' + mid + '.json';
  writeFileSync(file, JSON.stringify(doc));
  process.stdout.write(JSON.stringify({ decision: 'start', entry_file: file, classification: 'uncertain' }));
  process.exit(0);
}
// Forward stdin: start reads its optional takeover payload from stdin
// (start --takeover-file -), so the shim must not swallow it while delegating.
let forwardedInput;
try { if (!process.stdin.isTTY) forwardedInput = readFileSync(0, 'utf8'); } catch { forwardedInput = undefined; }
const run = spawnSync(process.env.ORBIT_ADV_REAL_RUBY, args, { encoding: 'utf8', input: forwardedInput });
process.stdout.write(run.stdout || '');
process.stderr.write(run.stderr || '');
process.exit(run.status ?? 1);
`);
    await fs.chmod(shim, 0o755);
    const autoBranch = [{ type: 'message', id: 'adv-user-1',
      message: { role: 'user', content: 'Do the bounded thing.' } }];
    const autoSession = session('auto-sess', autoBranch);
    const savedRootSession = rootRef.session;
    rootRef.session = autoSession;
    const autoCtx = { ...ctx, sessionManager: autoSession.sessionManager };
    const savedRubyEnv = process.env.ORBIT_RUBY;
    const savedAgentDir = process.env.PI_CODING_AGENT_DIR;
    const savedAgentRootEnv = process.env.ORBIT_SESSION_AGENT_ROOT;
    const savedCliBinEnv = process.env.ORBIT_CLI_BIN;
    // The earlier block removed the fixture agent root, so the real start path
    // gets its own minimal runnable-checker environment (same shape as the
    // top-level fixture; no model request or network is made).
    const advAgentRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-adv-agent-'));
    await fs.mkdir(path.join(advAgentRoot, 'agents'), { recursive: true });
    await fs.writeFile(path.join(advAgentRoot, 'models.yml'), `providers:
  glm:
    baseUrl: https://example.invalid/v1
    apiKey: fixture-key
    api: openai-completions
    models:
      - id: x
        name: Fixture GLM
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
`);
    const advPoolStub = path.join(advDir, 'pool.sh');
    await fs.writeFile(advPoolStub, '#!/bin/sh\nprintf \'{"models":["glm/x"]}\n\'\n');
    await fs.chmod(advPoolStub, 0o755);
    process.env.PI_CODING_AGENT_DIR = advAgentRoot;
    process.env.ORBIT_SESSION_AGENT_ROOT = advAgentRoot;
    process.env.ORBIT_CLI_BIN = advPoolStub;
    process.env.ORBIT_ADV_REAL_RUBY = realRuby;
    process.env.ORBIT_ADV_TRACE_TEMPLATE = templatePath;
    process.env.ORBIT_ADV_ENTRY_DIR = advDir;
    process.env.ORBIT_RUBY = shim;
    const tasksRoot = path.join(project, '.orbit', 'tasks');
    const beforeDirs = new Set(await fs.readdir(tasksRoot).catch(() => []));
    let autoPid = null;
    let autoPid2 = null;
    try {
      await emit('session_start', {}, autoCtx);
      const out = await emit('before_provider_request',
        { payload: { instructions: 'NATIVE SYSTEM PROMPT',
          messages: [{ role: 'user', content: 'Do the bounded thing.' }] } }, autoCtx);
      const autoBody = out?.payload ?? out;
      const injected = autoBody?.messages?.at(-1)?.content;
      assert.ok(typeof injected === 'string' && injected.includes('[orbit-entry-advisory]'),
        'the auto entry start injects the advisory into the CURRENT provider request payload');
      assert.ok(typeof injected === 'string' && injected.includes('[orbit-bootstrap]'),
        'the SAME auto request also carries the work-unit bootstrap — the advisory never returns ahead of it');
      assert.ok(injected.includes('0.85') && injected.includes('0.65'),
        'the auto-path advisory carries the measured fact');
      // The auto-start FIRST window must also carry the cooperation policy at
      // the native instruction layer — the same request, not a later one.
      assert.equal(((String(autoBody?.instructions).match(/\[orbit-cooperation-policy\]/g)) ?? []).length, 1,
        'the auto entry start carries the cooperation policy on the system instruction layer');
      const newDir = (await fs.readdir(tasksRoot)).find(dir => !beforeDirs.has(dir));
      assert.ok(newDir, 'the auto entry path created a real task record');
      const autoState = JSON.parse(await fs.readFile(path.join(tasksRoot, newDir, 'state.json'), 'utf8'));
      const autoPolicyFacts = async () => {
        for (let n = 0; n < 20; n++) {
          const entries = (await fs.readFile(path.join(tasksRoot, newDir, 'collaboration.jsonl'), 'utf8').catch(() => ''))
            .split('\n').filter(Boolean).map(line => JSON.parse(line));
          const facts = entries.filter(entry => entry.kind === 'cooperation_policy');
          if (facts.length) return facts;
          await new Promise(resolve => setTimeout(resolve, 50));
        }
        return [];
      };
      const autoFacts = await autoPolicyFacts();
      assert.equal(autoFacts.length, 1, 'the auto-start first success records exactly one policy fact');
      assert.equal(autoFacts[0].channel, 'instructions', 'the recorded channel names the layer actually used');
      assert.equal(autoState.entry?.decision, 'start',
        'the auto-created task record carries the paid entry trace');
      for (let n = 0; n < 20 && !autoPid; n++) {
        autoPid = autoState.runtime_pid || null;
        if (!autoPid) await new Promise(resolve => setTimeout(resolve, 100));
      }
      autoBranch.push({ type: 'message', id: 'adv-user-2',
        message: { role: 'user', content: 'Follow-up request.' } });
      const again = await emit('before_provider_request',
        { payload: { messages: [{ role: 'user', content: 'Follow-up request.' }] } }, autoCtx);
      const againContent = (again?.payload ?? again)?.messages?.at(-1)?.content;
      assert.ok(!(typeof againContent === 'string' && againContent.includes('[orbit-entry-advisory]')),
        'a later reachable request never repeats the advisory');

      // A second auto start whose FIRST payload cannot be extended stays
      // pending (no sent mark, no abort) and delivers on the next reachable
      // request — including a tool-turn request whose branch has no fresh
      // native user message (the manual same-turn window).
      // A session that already shows program-visible tool execution before the
      // current user message: the auto entry start must save a real takeover
      // boundary for THIS task (prior scope unknown, earlier work never
      // recognized as controlled). The prior items are the ordinary native
      // branch shape (an assistant message whose content carries a toolCall);
      // no product-internal simulation is used to fabricate history.
      const autoBranch2 = [
        { type: 'message', id: 'b-user-0', message: { role: 'user', content: 'Earlier ordinary request.' } },
        { type: 'message', id: 'b-assistant-0',
          message: { role: 'assistant', content: [{ type: 'toolCall', id: 'b-call-0', name: 'edit', arguments: { path: 'src/parse.js' } }] } },
        { type: 'message', id: 'b-user-1', message: { role: 'user', content: 'Second bounded thing.' } },
      ];
      const autoSession2 = session('auto-sess-2', autoBranch2);
      rootRef.session = autoSession2;
      const autoCtx2 = { ...ctx, sessionManager: autoSession2.sessionManager };
      const priorTaskStateBefore = await fs.readFile(path.join(started.task_directory, 'state.json'));
      await emit('session_start', {}, autoCtx2);
      const emptyOut = await emit('before_provider_request', { payload: { messages: [] } }, autoCtx2);
      assert.ok(!JSON.stringify(emptyOut || {}).includes('[orbit-entry-advisory]'),
        'an unextendable first payload stays pending instead of aborting');
      const newDir2 = (await fs.readdir(tasksRoot)).find(dir => !beforeDirs.has(dir) && dir !== newDir);
      assert.ok(newDir2, 'the second auto entry path created its own task record');
      const autoState2Path = path.join(tasksRoot, newDir2, 'state.json');
      const autoState2 = JSON.parse(await fs.readFile(autoState2Path, 'utf8'));
      const takeover = autoState2.takeover;
      assert.ok(takeover, 'a session with a prior assistant tool call records a takeover boundary');
      assert.equal(takeover.requirement?.native_message_id, 'b-user-1',
        'the takeover binds the CURRENT native user message as the requirement source');
      assert.equal(takeover.prior_scope?.status, 'unknown',
        'the prior scope stays unknown instead of being guessed from the branch');
      assert.ok(takeover.artifact?.snapshot_path && takeover.artifact?.digest?.startsWith('sha256:') &&
        (await fs.stat(path.join(tasksRoot, newDir2, takeover.artifact.snapshot_path)).catch(() => null))?.isDirectory(),
        'the takeover preserved a real snapshot inside the task private directory');
      assert.ok(takeover.supervision?.starts_at && takeover.artifact?.captured_at,
        'the boundary carries program timestamps');
      assert.equal(takeover.prior_execution?.recognized_as_controlled, false,
        'the earlier work is not recognized as controlled');
      assert.deepEqual(takeover.prior_execution?.imported, [],
        'the new task imports no earlier usage, members or checks');
      assert.ok((await fs.readFile(path.join(started.task_directory, 'state.json'))).equals(priorTaskStateBefore),
        'the pre-existing task record is left untouched by the takeover');
      assert.ok(!autoState.takeover || !Object.keys(autoState.takeover).length,
        'the fresh auto start without prior tool calls keeps no takeover block');
      autoBranch2.push({ type: 'message', id: 'b-assistant-1',
        message: { role: 'assistant', content: 'working' } });
      const retryOut = await emit('before_provider_request',
        { payload: { messages: [{ role: 'user', content: 'retry window' }] } }, autoCtx2);
      const retryContent = (retryOut?.payload ?? retryOut)?.messages?.at(-1)?.content;
      assert.ok(typeof retryContent === 'string' && retryContent.includes('[orbit-entry-advisory]'),
        'a no-user tool-turn request still gets the pending advisory (manual same-turn window)');
      assert.ok(typeof retryContent === 'string' && retryContent.includes('[orbit-bootstrap]'),
        'the pending bootstrap travels in the same retried payload as the advisory');
      const thirdOut = await emit('before_provider_request',
        { payload: { messages: [{ role: 'user', content: 'third window' }] } }, autoCtx2);
      const thirdContent = (thirdOut?.payload ?? thirdOut)?.messages?.at(-1)?.content;
      assert.ok(!(typeof thirdContent === 'string' && thirdContent.includes('[orbit-entry-advisory]')),
        'the second task never repeats its advisory');
      // A later takeover start on the ACTIVE task uses the real host early-return
      // path: a valid prior_scope queues through the CLI without changing the
      // task directory, an omitted key stays idempotent, and a bad value is
      // refused rather than treated as absent.
      const inboxDir = path.join(tasksRoot, newDir2, 'inbox');
      const inboxBefore = (await fs.readdir(inboxDir).catch(() => [])).length;
      const declared = await tool({ action: 'start', task: newDir2,
        takeover: { reason: 'declare what the ordinary stage covered',
                    prior_scope: 'ordinary execution only changed src/parse.js' } }, autoCtx2);
      assert.equal(declared.task_directory, path.join(tasksRoot, newDir2), 'a later declaration keeps the same task directory');
      assert.equal(declared.existing_task, true, 'the active task keeps its existing-task answer');
      assert.equal(declared.takeover_scope_queued?.status, 'queued', 'the declaration is queued through the real CLI');
      assert.equal(declared.takeover_scope_queued?.task_directory, path.join(tasksRoot, newDir2),
        'the queued command names the same task');
      assert.equal((await fs.readdir(inboxDir)).length, inboxBefore + 1, 'exactly one declaration command is queued');
      const omitted = await tool({ action: 'start', task: newDir2, takeover: { reason: 'no scope stated' } }, autoCtx2);
      assert.equal(omitted.takeover_scope_queued, undefined, 'an omitted prior_scope keeps the previous result');
      assert.equal((await fs.readdir(inboxDir)).length, inboxBefore + 1, 'nothing is queued without a declaration');
      await assert.rejects(() => tool({ action: 'start', task: newDir2,
        takeover: { reason: 'bad scope type', prior_scope: 42 } }, autoCtx2), /prior_scope/,
        'a non-string prior_scope is refused instead of treated as absent');
      assert.equal((await fs.readdir(inboxDir)).length, inboxBefore + 1, 'a refused declaration queues nothing');
      for (let n = 0; n < 20 && !autoPid2; n++) {
        const autoState2 = JSON.parse(await fs.readFile(autoState2Path, 'utf8'));
        autoPid2 = autoState2.runtime_pid || null;
        if (!autoPid2) await new Promise(resolve => setTimeout(resolve, 100));
      }
    } finally {
      if (savedRubyEnv === undefined) delete process.env.ORBIT_RUBY; else process.env.ORBIT_RUBY = savedRubyEnv;
      delete process.env.ORBIT_ADV_REAL_RUBY;
      delete process.env.ORBIT_ADV_TRACE_TEMPLATE;
      delete process.env.ORBIT_ADV_ENTRY_DIR;
      if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
      if (savedAgentRootEnv === undefined) delete process.env.ORBIT_SESSION_AGENT_ROOT; else process.env.ORBIT_SESSION_AGENT_ROOT = savedAgentRootEnv;
      if (savedCliBinEnv === undefined) delete process.env.ORBIT_CLI_BIN; else process.env.ORBIT_CLI_BIN = savedCliBinEnv;
      rootRef.session = savedRootSession;
      // The auto-created runtimes are detached process-group leaders. Signal the
      // group, then wait for the process to actually exit and force-kill what
      // survives, so nothing keeps writing into the project after teardown.
      const autoPids = [autoPid, autoPid2].filter(pid => pid);
      for (const pid of autoPids) {
        try { process.kill(-pid, 'SIGTERM'); } catch { try { process.kill(pid, 'SIGTERM'); } catch { /* already gone */ } }
      }
      for (const pid of autoPids) {
        for (let n = 0; n < 20; n++) {
          try { process.kill(pid, 0); } catch { break; }
          await new Promise(resolve => setTimeout(resolve, 50));
        }
        try { process.kill(-pid, 'SIGKILL'); } catch { try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ } }
      }
      await fs.rm(advAgentRoot, { recursive: true, force: true });
      await fs.rm(advDir, { recursive: true, force: true });
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
  // A straggler runtime (the auto-start fixtures spawn their own detached
  // runtimes) can recreate its task directory after the first removal. Bound
  // the teardown: kill only processes whose command line still references this
  // fixture path, remove the project, and stop after a few attempts.
  for (let attempt = 0; attempt < 5; attempt++) {
    const stragglers = execSync('ps -eo pid=,command=', { encoding: 'utf8' }).split('\n')
      .filter(line => line.includes(project) && !line.includes('omp_native_gate_test'))
      .map(line => Number(line.trim().split(/\s+/)[0]))
      .filter(pid => Number.isInteger(pid) && pid > 0 && pid !== process.pid);
    if (!stragglers.length && !(await fs.stat(project).catch(() => null))) break;
    for (const pid of stragglers) {
      try { process.kill(-pid, 'SIGKILL'); } catch { try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ } }
    }
    await fs.rm(project, { recursive: true, force: true });
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  await fs.rm(process.env.XDG_CONFIG_HOME, { recursive: true, force: true });
}

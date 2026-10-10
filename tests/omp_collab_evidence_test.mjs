// Durable task-local collaboration evidence (collaboration.jsonl): every
// attributed observation is appended at observation time with an ISO `at`, a
// monotonic per-task sequence and the ORIGINAL untruncated payload, so early
// evidence survives the bounded in-process buffer and an OMP exit. Unattributed
// traffic never leaks into a task file; persistence failures surface as
// explicit persistence_gap lines. Real task records, real register-member
// script, real socket bridge; no provider traffic.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { z } from 'zod';
import { execSync } from 'node:child_process';
import { installOmpExtension } from '../plugins/omp-host.mjs';

process.env.ORBIT_RUBY = process.env.ORBIT_RUBY || execSync('which ruby').toString().trim();
delete process.env.ORBIT_CLI_BIN;
process.env.XDG_CONFIG_HOME = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-collab-xdg-'));
// The isolated preflight reads the same model store as this OMP session.
// A local provider with a config credential makes the fixture offline.
const agentRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-collab-agents-'));
await fs.mkdir(path.join(agentRoot, 'agents'), { recursive: true });
process.env.PI_CODING_AGENT_DIR = agentRoot;
process.env.ORBIT_SESSION_AGENT_ROOT = agentRoot;
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

const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-collab-')));
const model = { provider: 'glm', id: 'x' };
const mainAgentId = 'Main';
let registryListener, definition;
let events = {};
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
  return { sessionId: id, model, isStreaming: false, listeners,
    sessionManager: { getSessionId: () => id, getCwd: () => project, getBranch: () => branch },
    getAgentId: () => id, hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); } };
}
const root = session('root', [{ type: 'message', id: 'original', message: { role: 'user', content: 'Original requirement.' } }]);
const root2 = session('root2', [{ type: 'message', id: 'original2', message: { role: 'user', content: 'Second requirement.' } }]);
const root3 = session('root3', [{ type: 'message', id: 'original3', message: { role: 'user', content: 'Third requirement.' } }]);
delete root3.model; // no observable model at binding -> no durable write until traffic
const root4 = session('root4', [{ type: 'message', id: 'original4', message: { role: 'user', content: 'Fourth requirement.' } }]);
delete root4.model; // same as root3: no durable line at binding
const rootRef = { id: mainAgentId, kind: 'main', parentId: null, status: 'running', session: root, sessionFile: '/tmp/root.jsonl', history: {}, activity: null };
const registry = {
  list: () => [rootRef],
  get: id => (id === mainAgentId ? rootRef : undefined),
  onChange: listener => { registryListener = listener; return () => { registryListener = null; }; },
  setStatus: () => true,
};
const ctxFor = s => ({ cwd: project, sessionManager: s.sessionManager,
  models: { list: () => [model], resolve: spec => spec === '@task' || spec === 'glm/x' ? model : undefined },
  hasUI: true, ui: { notify: () => {} } });
const ctx = ctxFor(root);
const pi = { zod: z, registerTool: tool => { definition = tool; }, registerCommand: () => {},
  on: (name, handler) => { (events[name] ||= []).push(handler); } };
const sdk = { MAIN_AGENT_ID: mainAgentId, AgentRegistry: { global: () => registry }, isUserInterruptAbort: () => false };
const tool = async (args, context) => JSON.parse((await definition.execute('call', args, null, null, context)).content[0].text);

const collabLines = async dir => (await fs.readFile(path.join(dir, 'collaboration.jsonl'), 'utf8')).trim().split('\n').map(l => JSON.parse(l));
const waitFor = async (fn, label, ms = 8000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await fn().catch(() => null);
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${label}`);
    await new Promise(resolve => setTimeout(resolve, 50));
  }
};
const socketOf = async dir => JSON.parse(await fs.readFile(path.join(dir, 'state.json'), 'utf8')).connection.socket;
const request = async (dir, method, extra = {}) => {
  const socket = await socketOf(dir);
  return new Promise((resolve, reject) => {
    const peer = net.createConnection(socket); let data = '';
    peer.on('error', reject);
    peer.on('connect', () => peer.write(JSON.stringify({ method, ...extra }) + '\n'));
    peer.on('data', b => { data += b; if (data.includes('\n')) { peer.end(); resolve(JSON.parse(data.split('\n')[0]).result); } });
  });
};
// The detached TaskRuntime is stopped and the fixture pinned to 'running'
// with a live sentinel pid, exactly like the gate test's deterministic seam.
const startTask = async (context, messageId, reviewModel) => {
  const started = await tool({ action: 'start', message_id: messageId, ...(reviewModel ? { review_model: reviewModel } : {}) }, context);
  try { process.kill(-started.pid, 'SIGTERM'); } catch { /* already gone */ }
  for (let n = 0; n < 40; n++) {
    try { process.kill(started.pid, 0); } catch { break; }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const statePath = path.join(started.task_directory, 'state.json');
  const fixture = JSON.parse(await fs.readFile(statePath, 'utf8'));
  fixture.status = 'running';
  fixture.runtime_pid = process.pid;
  await fs.writeFile(statePath, JSON.stringify(fixture));
  return started.task_directory;
};

// Fixture stand-in for the stopped TaskRuntime at the real select seam: the
// Root CLI (declare receipt / native dispatch gate) submits a member_selection
// inbox command and waits up to 120s for
// member-selection-responses/<request_id>.json — the runtime is its sole
// writer. This watcher mirrors the runtime consumption (unlink after read)
// and answers with an explicitly facts_only-marked fixture response. It is
// NOT a JEV judgment or live evidence and never reaches production state;
// the native dispatch gate still enforces its persisted-selection receipt
// (a string signature) and would block without it.
const serveFixtureSelections = taskDir => {
  const inbox = path.join(taskDir, 'inbox');
  const responses = path.join(taskDir, 'member-selection-responses');
  const served = new Set();
  const timer = setInterval(() => {
    (async () => {
      let files = [];
      try { files = await fs.readdir(inbox); } catch { return; }
      for (const file of files) {
        if (!file.endsWith('.json') || served.has(file)) continue;
        served.add(file);
        let command;
        try { command = JSON.parse(await fs.readFile(path.join(inbox, file), 'utf8')); } catch { continue; }
        if (command?.type !== 'member_selection' || typeof command.request_id !== 'string' ||
            typeof command.work_unit_id !== 'string') continue;
        const response = {
          ok: true, request_id: command.request_id, work_unit_id: command.work_unit_id,
          responded_at: new Date().toISOString(),
          selection: {
            version: 'fixture', signature: `fixture-selection-${command.request_id}`,
            decision: 'facts_only', fixture: true,
            reason: 'fixture facts_only response; not a JEV judgment or live evidence',
            candidates: [], recommendation: {}
          }
        };
        await fs.mkdir(responses, { recursive: true, mode: 0o700 });
        await fs.writeFile(path.join(responses, `${command.request_id}.json`), JSON.stringify(response, null, 2),
          { mode: 0o600 });
        await fs.rm(path.join(inbox, file), { force: true });
      }
    })().catch(() => {});
  }, 50);
  timer.unref?.();
  return timer;
};

try {
  installOmpExtension(pi, sdk);

  // Pre-association hub traffic from the future Root session: observed but
  // unattributable — it must reach no task file, and later become an
  // explicit association gap.
  await emit('tool_call', { toolName: 'hub', toolCallId: 'early-1', input: { op: 'send', to: 'nobody', message: 'early one' } }, ctx);
  await emit('tool_result', { toolName: 'hub', toolCallId: 'early-1', isError: false, content: [{ type: 'text', text: 'early ack' }] }, ctx);

  const taskDir = await startTask(ctx, 'original');
  serveFixtureSelections(taskDir);
  await waitFor(async () => (await collabLines(taskDir)).length >= 2, 'association gap + root identity');
  const poolStub = path.join(agentRoot, 'pool.sh');
  await fs.writeFile(poolStub, '#!/bin/sh\nprintf \'{"models":["glm/x"]}\\n\'\n');
  await fs.chmod(poolStub, 0o755);
  process.env.ORBIT_CLI_BIN = poolStub;

  // Task dispatch evidence: original item input (name/model/task/rationale as
  // explicitly supplied) captured before the gate rewrites the name.
  const declareUnit = async (dir, context, objective) => (await tool({ action: 'work-unit', task: dir,
    operation: 'declare', work_unit: { spec: { objective, requirements: ['original user request'],
      allowed_paths: ['src'], allowed_tools: ['read'], allowed_commands: [],
      acceptance: 'Check the delegated facts', escalation: 'Report missing evidence to Root' } } }, context)).unit;
  const dispatchUnit = await declareUnit(taskDir, ctx, 'Check the limits');
  const originalTask = `Check the limits\norbit-unit: ${dispatchUnit.id}`;
  const dispatch = await emit('tool_call', { toolName: 'task', toolCallId: 'call-dispatch',
    input: { agent: 'task', name: 'member-a', model: 'glm/x', task: originalTask, why: 'explicit delegation rationale' } }, ctx);
  assert.ok(!dispatch.block, `dispatch must pass the gate: ${JSON.stringify(dispatch)}`);
  const memberSession = session('member-live');
  const memberRef = { id: dispatch.input.name, kind: 'sub', parentId: mainAgentId, status: 'running',
    session: memberSession, sessionFile: '/tmp/m.jsonl', history: {}, activity: null };
  registry.list = () => [rootRef, memberRef];
  registry.get = id => (id === mainAgentId ? rootRef : id === memberRef.id ? memberRef : undefined);
  registryListener({ type: 'registered', ref: memberRef });
  await waitFor(async () => (await collabLines(taskDir)).some(l => l.kind === 'task_dispatch' && l.requested_name === dispatch.input.name), 'task_dispatch line');

  // Member peer traffic through the session subscription: both the legacy
  // hub tool and actual OMP `write agent://Main` are durable and task-scoped.
  for (const listener of memberSession.listeners) {
    await listener({ type: 'tool_execution_start', toolCallId: 'member-hub-1', toolName: 'hub',
      args: { op: 'send', to: mainAgentId, message: 'm'.repeat(3000) } });
    await listener({ type: 'tool_execution_end', toolCallId: 'member-hub-1', toolName: 'hub',
      result: { content: [{ type: 'text', text: 'member reply' }] }, isError: false });
    await listener({ type: 'tool_execution_start', toolCallId: 'member-peer-write', toolName: 'write',
      args: { path: 'agent://Main', content: 'B delivered: 11 invoice tests pass' } });
    await emit('tool_call', { toolName: 'write', toolCallId: 'member-peer-write',
      input: { path: 'agent://Main', content: 'B delivered: 11 invoice tests pass' } }, ctxFor(memberSession));
    await listener({ type: 'tool_execution_end', toolCallId: 'member-peer-write', toolName: 'write',
      result: { content: [{ type: 'text', text: 'Delivered to Main.' }],
        details: { message: { op: 'send', from: memberRef.id, to: mainAgentId,
          receipts: [{ to: mainAgentId, outcome: 'injected' }] } } }, isError: false });
    await emit('tool_result', { toolName: 'write', toolCallId: 'member-peer-write', isError: false,
      content: [{ type: 'text', text: 'Delivered to Main.' }] }, ctxFor(memberSession));
    await listener({ type: 'tool_execution_start', toolCallId: 'ordinary-write', toolName: 'write',
      args: { path: 'src/invoice.js', content: 'not a peer message' } });
    await listener({ type: 'tool_execution_end', toolCallId: 'ordinary-write', toolName: 'write',
      result: { content: [{ type: 'text', text: 'Wrote file' }] }, isError: false });
  }
  const rootPeer = await emit('tool_call', { toolName: 'write', toolCallId: 'root-peer-write',
    input: { path: `agent://${memberRef.id}`, content: 'Review new invoice edge' } }, ctx);
  assert.ok(!rootPeer?.block, 'Root can use the native peer-write route while the task is active');
  await emit('tool_result', { toolName: 'write', toolCallId: 'root-peer-write', isError: false,
    content: [{ type: 'text', text: 'Delivered to member.' }] }, ctx);
  await emit('tool_result', { toolName: 'task', toolCallId: 'call-dispatch', isError: false,
    content: [{ type: 'text', text: 'member-a finished' }] }, ctx);
  await waitFor(async () => (await collabLines(taskDir)).some(l => l.kind === 'task_result'), 'task_result line');

  // The bounded bridge keeps its historical shape: capped copy of the same
  // observation, full evidence still only in the file.
  const early = await request(taskDir, 'hub_events', { session: 'root' });
  const earlyCall = early.events.find(e => e.kind === 'hub_call' && e.tool_call_id === 'member-hub-1');
  assert.equal(earlyCall.message.length, 2000, 'buffer copy keeps the 2000-char cap');
  assert.ok(early.events.some(e => e.kind === 'task_dispatch'), 'buffer still carries recent evidence for the runtime');

  // Root session file reference: path only, straight from the registry ref.
  const rootState = await request(taskDir, 'state', { session: 'root' });
  assert.equal(rootState.session_file, rootRef.sessionFile, 'state exposes the main ref session file path');
  // Bounded delivery-attribution origin (kickoff ⑥): the nearest native user
  // message id preceding the last assistant turn — null while no assistant
  // turn exists, then the user message that turn answers.
  assert.equal(rootState.last_turn_user_message_id, null, 'no assistant turn yet: origin stays null');
  root.sessionManager.getBranch().push({ type: 'message', id: 'reply-1', message: { role: 'assistant', content: 'working' } });
  const withTurn = await request(taskDir, 'state', { session: 'root' });
  assert.equal(withTurn.last_turn_user_message_id, 'original', 'the last assistant turn names the native user message it answers');

  // Rollover: more attributed observations than the 500-entry buffer cap.
  for (let n = 0; n < 520; n++)
    await emit('tool_result', { toolName: 'hub', toolCallId: `roll-${n}`, isError: false,
      content: [{ type: 'text', text: `rollover ${n}` }] }, ctx);

  const lines = await waitFor(async () => {
    const all = await collabLines(taskDir);
    return all.some(l => l.kind === 'hub_result' && l.text === 'rollover 519') ? all : null;
  }, 'all rollover lines durable');
  const bridge = await request(taskDir, 'hub_events', { session: 'root' });
  assert.equal(bridge.events.length, 500, 'buffer stays at its cap');
  assert.ok(bridge.dropped_oldest > 0, 'buffer rollover is visible to the runtime');
  assert.ok(!bridge.events.some(e => e.kind === 'task_dispatch'), 'rolled-out events are gone from the buffer');

  // Durable invariants: contiguous per-task seq, ISO timestamps, 0600 file,
  // early lines still present after the buffer dropped them.
  assert.deepEqual(lines.map(l => l.seq), lines.map((_, index) => index + 1), 'durable sequence is gap-free 1..N');
  for (const line of lines) assert.match(line.at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, 'at is ISO');
  assert.equal((await fs.stat(path.join(taskDir, 'collaboration.jsonl'))).mode & 0o777, 0o600, 'file mode is 0600');
  const first = lines[0];
  assert.equal(first.kind, 'persistence_gap', 'the first durable line is the association gap');
  assert.equal(first.session_id, 'root');
  assert.equal(first.lost_count, 2, 'both pre-association observations are counted');
  const rootIdentity = lines.find(l => l.kind === 'model_identity' && l.role === 'root');
  assert.equal(rootIdentity.model, 'glm/x', 'root actual model identity is recorded');
  const dispatchLine = lines.find(l => l.kind === 'task_dispatch');
  assert.equal(dispatchLine.input_name, 'member-a', 'original requested name is kept');
  assert.equal(dispatchLine.agent, 'task');
  assert.equal(dispatchLine.model, 'glm/x', 'explicitly requested model is kept');
  assert.equal(dispatchLine.rationale, 'explicit delegation rationale', 'explicit rationale is kept');
  assert.equal(dispatchLine.rationale_source, 'dispatch_input', 'the reason is marked as dispatch-supplied');
  assert.equal(dispatchLine.task, originalTask, 'the complete native input is preserved before adding the durable handoff');
  assert.equal(dispatchLine.requested_name, dispatch.input.name);
  const memberIdentity = lines.find(l => l.kind === 'model_identity' && l.role === 'member');
  assert.equal(memberIdentity.agent_id, dispatch.input.name);
  assert.equal(memberIdentity.model, 'glm/x', 'member actual model at registration is recorded');
  const memberCall = lines.find(l => l.kind === 'hub_call' && l.tool_call_id === 'member-hub-1');
  assert.equal(memberCall.message.length, 3000, 'durable payload is untruncated');
  const peerWrite = lines.find(l => l.kind === 'hub_call' && l.tool_call_id === 'member-peer-write');
  const peerReceipt = lines.find(l => l.kind === 'hub_result' && l.tool_call_id === 'member-peer-write');
  assert.equal(peerWrite.to, mainAgentId);
  assert.equal(peerWrite.message, 'B delivered: 11 invoice tests pass');
  assert.equal(peerReceipt.ok, true);
  assert.equal(peerReceipt.text, 'Delivered to Main.');
  assert.equal(lines.filter(l => l.tool_call_id === 'member-peer-write' && l.kind === 'hub_call').length, 1,
    'one member write is observed once despite both native event surfaces firing');
  assert.equal(lines.filter(l => l.tool_call_id === 'member-peer-write' && l.kind === 'hub_result').length, 1,
    'one member receipt is observed once despite both native event surfaces firing');
  const rootPeerCall = lines.find(l => l.kind === 'hub_call' && l.tool_call_id === 'root-peer-write');
  const rootPeerResult = lines.find(l => l.kind === 'hub_result' && l.tool_call_id === 'root-peer-write');
  assert.equal(rootPeerCall.to, memberRef.id);
  assert.equal(rootPeerCall.message, 'Review new invoice edge');
  assert.equal(rootPeerResult.text, 'Delivered to member.');
  const firstStatePath = path.join(taskDir, 'state.json');
  const firstState = JSON.parse(await fs.readFile(firstStatePath, 'utf8'));
  firstState.status = 'paused';
  await fs.writeFile(firstStatePath, JSON.stringify(firstState));
  const blockedPeer = await emit('tool_call', { toolName: 'write', toolCallId: 'stopped-peer-write',
    input: { path: `agent://${memberRef.id}`, content: 'Must not wake' } }, ctx);
  assert.equal(blockedPeer.block, true, 'native peer write cannot wake a member after its Orbit task stops');
  assert.ok(!lines.some(l => l.tool_call_id === 'ordinary-write'), 'ordinary file writes are not peer messages');
  assert.ok(!lines.some(l => l.text === 'early ack' || l.message === 'early one'), 'unattributed pre-association content never lands in the file');

  // Second task, second session: attribution must not leak across tasks.
  rootRef.session = root2;
  const taskDir2 = await startTask(ctxFor(root2), 'original2');
  serveFixtureSelections(taskDir2);
  await emit('tool_call', { toolName: 'hub', toolCallId: 'other-task', input: { op: 'send', to: 'nobody', message: 'other task traffic' } }, ctxFor(root2));
  await waitFor(async () => (await collabLines(taskDir2)).some(l => l.tool_call_id === 'other-task'), 'task2 durable line');
  const noReason = await emit('tool_call', { toolName: 'task', toolCallId: 'no-reason',
    input: { agent: 'task', task: `Inspect task two\norbit-unit: ${(await declareUnit(taskDir2, ctxFor(root2), 'Inspect task two')).id}` } }, ctxFor(root2));
  assert.ok(!noReason.block);
  const missingReason = await waitFor(async () => (await collabLines(taskDir2))
    .find(l => l.kind === 'task_dispatch' && l.tool_call_id === 'no-reason'), 'unrecorded reason');
  assert.equal(missingReason.rationale, null);
  assert.equal(missingReason.rationale_source, 'unrecorded', 'Orbit does not invent a reason for Root');
  assert.ok(!(await collabLines(taskDir)).some(l => l.tool_call_id === 'other-task'), 'no cross-task entry');
  // Persistence gap: a task with no durable write yet (no observable model at
  // binding, no pre-association traffic) whose directory turns read-only
  // before its first attributed observation. The append fails, the loss is
  // mirrored into the bridge, and recovery writes an explicit gap line with
  // the lost sequence range before the next event.
  rootRef.session = root3;
  const ctx3 = ctxFor(root3);
  // No observable Root model: specify the same local model explicitly, so
  // no identity line lands before the read-only window.
  const taskDir3 = await startTask(ctx3, 'original3', 'glm/x');
  await fs.chmod(taskDir3, 0o500);
  await emit('tool_call', { toolName: 'hub', toolCallId: 'gap-1', input: { op: 'send', to: 'nobody', message: 'lost one' } }, ctx3);
  await emit('tool_call', { toolName: 'hub', toolCallId: 'gap-2', input: { op: 'send', to: 'nobody', message: 'lost two' } }, ctx3);
  await waitFor(async () => (await request(taskDir3, 'hub_events', { session: 'root3' }))
    .events.some(e => e.kind === 'persistence_gap'), 'bridge persistence_gap mirror');
  // A real append failure is diagnostic evidence, never a failed execution
  // stop: the checkpoint names its cutoff and unrecorded gap explicitly.
  const failedCheckpoint = await request(taskDir3, 'stop', { session: 'root3' });
  assert.equal(failedCheckpoint.confirmed, true, 'a broken log sink cannot prevent cancellation');
  const failedPersistence = failedCheckpoint.collaboration_persistence;
  assert.equal(failedPersistence.status, 'written_with_gaps');
  assert.equal(failedPersistence.observed_through, 2);
  assert.equal(failedPersistence.written_seq, 0);
  assert.equal(failedPersistence.failed_observations, 2);
  assert.equal(failedPersistence.pending_gap.count, 2);
  assert.match(failedPersistence.last_error, /append failed/);
  await fs.chmod(taskDir3, 0o755);
  await emit('tool_call', { toolName: 'hub', toolCallId: 'gap-3', input: { op: 'send', to: 'nobody', message: 'recovered' } }, ctx3);
  const lines3 = await waitFor(async () => {
    const all = await collabLines(taskDir3);
    return all.some(l => l.tool_call_id === 'gap-3') ? all : null;
  }, 'recovered write');
  const gap = lines3.find(l => l.kind === 'persistence_gap' && (l.reason || '').includes('append failed'));
  assert.ok(gap, 'a durable persistence_gap line exists');
  assert.equal(gap.lost_count, 2, 'both lost observations are counted');
  assert.match(gap.first_lost_at, /^\d{4}-\d{2}-\d{2}T/, 'the loss window start is dated');
  assert.deepEqual(lines3.map(l => l.seq), [1, 2], 'sequence numbers stay contiguous across the loss');
  assert.equal(lines3.at(-1).tool_call_id, 'gap-3');
  assert.equal((await fs.stat(path.join(taskDir3, 'collaboration.jsonl'))).mode & 0o777, 0o600, 'recovered file is 0600');
  const recoveredCheckpoint = await request(taskDir3, 'stop', { session: 'root3' });
  assert.equal(recoveredCheckpoint.confirmed, true);
  const recoveredPersistence = recoveredCheckpoint.collaboration_persistence;
  assert.equal(recoveredPersistence.observed_through, 3);
  assert.equal(recoveredPersistence.written_seq, lines3.at(-1).seq);
  assert.equal(recoveredPersistence.pending_gap, null);
  assert.equal(recoveredPersistence.failed_observations, 2, 'recovery does not erase the failed observations');
  assert.equal(recoveredPersistence.recorded_gaps, 1);
  assert.equal(recoveredPersistence.status, 'written_with_gaps');


  // Restart/resume: a task whose evidence file already exists (written by a
  // previous OMP process) with a valid last line and a crash-left PARTIAL
  // trailing line. The sequence must resume from the last valid line, the
  // fragment must be terminated and preserved, and the resume must surface
  // as an explicit gap — never an overwrite, never a restart at 0.
  rootRef.session = root4;
  const ctx4 = ctxFor(root4);
  const taskDir4 = await startTask(ctx4, 'original4', 'glm/x');
  const seeded = JSON.stringify({ seq: 7, at: '2026-09-26T00:00:00.000Z', at_ms: 0, kind: 'hub_result',
    task_dir: taskDir4, session_id: 'previous-process', agent_id: null, ok: true, text: 'earlier run' }) + '\n';
  const fragment = '{"seq":8,"kind":"hub_call","mess'; // no trailing newline
  await fs.writeFile(path.join(taskDir4, 'collaboration.jsonl'), seeded + fragment);
  await emit('tool_call', { toolName: 'hub', toolCallId: 'resume-1', input: { op: 'send', to: 'nobody', message: 'after restart' } }, ctx4);
  const raw4 = await waitFor(async () => {
    const text = await fs.readFile(path.join(taskDir4, 'collaboration.jsonl'), 'utf8');
    return text.includes('after restart') ? text : null;
  }, 'resumed write');
  const parsed4 = raw4.split('\n').filter((line, index, all) => line.length > 0 || index === all.length - 1)
    .map(line => { try { return JSON.parse(line); } catch { return { malformed: line }; } });
  assert.equal(parsed4[0].seq, 7, 'the pre-existing sequenced line is kept');
  assert.equal(parsed4[0].text, 'earlier run');
  assert.deepEqual(parsed4[1], { malformed: fragment }, 'the partial fragment is terminated and preserved verbatim');
  assert.equal(parsed4[2].kind, 'persistence_gap', 'the resume writes an explicit gap line');
  assert.equal(parsed4[2].seq, 8);
  assert.equal(parsed4[2].lost_count, 1, 'the skipped fragment is counted');
  assert.match(parsed4[2].reason, /malformed\/partial/);
  assert.equal(parsed4[3].kind, 'hub_call');
  assert.equal(parsed4[3].seq, 9, 'the sequence resumes monotonically from the last valid line');
  assert.equal(parsed4[3].tool_call_id, 'resume-1');
  assert.equal((await fs.stat(path.join(taskDir4, 'collaboration.jsonl'))).mode & 0o777, 0o600, 'resumed file is normalized to 0600');
  // Process-level shutdown flushes and closes the durable writers (root4 is
  // the current main session; root3's context no longer matches the ref).
  const finalCount1 = (await collabLines(taskDir)).length;
  await emit('session_shutdown', {}, ctx4);
  assert.equal((await collabLines(taskDir)).length, finalCount1, 'shutdown changes nothing already durable');

  console.log('omp collab evidence: PASS');
  await fs.rm(project, { recursive: true, force: true }).catch(() => {});
} catch (error) {
  console.error(error);
  process.exit(1);
}

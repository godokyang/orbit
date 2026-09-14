import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { z } from 'zod';
import { installOmpExtension } from '../plugins/omp-host.mjs';

// Native SDK doubles exercise the actual private bridge and task process.
// User behavior: original input, controlled members, amendments, real stop.
const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-omp-test-')));
const events = {}, sessions = [], created = [], reaped = [];
const model = { provider: 'authorized', id: 'execution' };
const settings = { getAgentDir: () => '/native/profile', cloneForCwd: async cwd => ({ cwd, approval: 'always-ask' }) };
let definition, started, sequence = 0, failReap = false;
function session(id, branch = []) {
  const listeners = new Set();
  const native = { sessionId: id, model, settings, thinkingLevel: 'medium', modelRegistry: { authStorage: {} },
    isStreaming: true, jobsRunning: true,
    sessionManager: { getSessionId: () => id, getCwd: () => project, getBranch: () => branch },
    getAgentId: () => id, getActiveToolNames: () => ['read', 'bash', 'task', 'orbit', 'mcp_foreign'],
    hasPendingAsyncWork: () => native.jobsRunning, getAsyncJobSnapshot: () => ({ running: native.jobsRunning ? [id] : [] }),
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
    emit: event => listeners.forEach(listener => listener(event)),
    sendCustomMessage: async (message, options) => {
      assert.equal(options.deliverAs, 'steer'); assert.equal(options.triggerTurn, true);
      branch.push({ type: 'custom_message', id: `native-${++sequence}`, ...message }); native.isStreaming = true;
    },
    abort: async () => { native.isStreaming = false; }, dispose: async () => {},
    asyncJobManager: {
      cancelAll: ({ ownerId }) => assert.equal(ownerId, id),
      cancelAndReapOwnerJobs: async ownerId => {
        assert.equal(ownerId, id);
        if (failReap) return { settled: false };
        await new Promise(resolve => setTimeout(resolve, 120));
        native.jobsRunning = false; reaped.push(id); return { settled: true };
      }
    }
  };
  sessions.push(native); return native;
}
const original = 'Implement the requested feature and verify it with one member.';
const root = session('root', [{ type: 'message', id: 'original', message: { role: 'user', content: original } }]);
const notices = [];
const ctx = { cwd: project, sessionManager: root.sessionManager, models: { list: () => [model] }, hasUI: true,
  ui: { notify: message => notices.push(message) } };
const pi = { zod: z, registerTool: tool => { definition = tool; }, on: (name, handler) => { events[name] = handler; } };
const sdk = { AgentRegistry: { global: () => ({ list: () => sessions.map(s => ({ session: s })) }) },
  SessionManager: { create: () => ({}), getDefaultSessionDir: () => '/native/sessions' },
  isUserInterruptAbort: message => message.errorId === 'native-user-interrupt',
  createAgentSession: async options => {
    created.push(options);
    const child = session(`member-${created.length}`);
    return { session: child, setToolUIContext: (ui, hasUI) => { assert.equal(ui, ctx.ui); assert.equal(hasUI, true); } };
  }
};
const tool = async (args, context = ctx) => JSON.parse((await definition.execute('call', args, null, null, context)).content[0].text);
const record = async () => JSON.parse(await fs.readFile(path.join(started.task_directory, 'state.json'), 'utf8'));
const waitFor = async test => {
  for (let n = 0; n < 100; n++) { if (await test()) return; await new Promise(r => setTimeout(r, 100)); }
  throw new Error('Timed out waiting for native/Orbit state');
};
const request = async (method, extra = {}) => {
  const { connection } = await record();
  return new Promise((resolve, reject) => {
    const peer = net.createConnection(connection.socket); let data = '';
    peer.on('error', reject);
    peer.on('connect', () => peer.end(JSON.stringify({ method, session: 'root', ...extra }) + '\n'));
    peer.on('data', b => { data += b; });
    peer.on('end', () => { const r = JSON.parse(data); r.error ? reject(new Error(r.error)) : resolve(r.result); });
  });
};
try {
  installOmpExtension(pi, sdk); events.session_start({}, ctx);
  assert.equal((await tool({ action: 'context' })).thread_id, 'root');
  started = await tool({ action: 'start', review_model: 'unused-check-model', check_in: 3600 });
  await waitFor(async () => (await record()).status === 'running');
  assert.equal((await record()).instruction_source.kind, 'omp_user_message');
  const marker = await request('send', { text: 'Internal correction.' });
  assert.deepEqual((await request('messages')).map(m => [m.id, m.internal]), [['original', false], [marker.id, true]]);
  await assert.rejects(request('state', { session: 'foreign' }), /not owned/);
  await tool({ action: 'delegate', task: started.task_directory, text: 'Verify only, do not edit.' });
  await waitFor(async () => (await record()).members[0]?.status === 'working');
  assert.equal(created[0].settings.approval, 'always-ask'); assert.notEqual(created[0].settings, settings);
  assert.deepEqual(created[0].toolNames, ['read', 'bash']); assert.equal(created[0].restrictToolNames, true);
  assert.equal(created[0].parentAgentId, 'root'); assert.equal(created[0].model, model);
  assert.equal(created[0].modelRegistry, root.modelRegistry); assert.equal(created[0].disableExtensionDiscovery, true);
  const child = sessions[1];
  assert(child.sessionManager.getBranch()[0].content.includes(original));
  await assert.rejects(tool({ action: 'context' }, { ...ctx, sessionManager: child.sessionManager }), /report to Root/);
  root.sessionManager.getBranch().push({ type: 'message', id: 'amendment', message: { role: 'user', content: 'Keep the change small.' } });
  await waitFor(async () => (await record()).amendments.length === 1);
  root.emit({ type: 'message_end', message: { role: 'assistant', errorId: 'native-user-interrupt' } });
  await waitFor(async () => (await record()).status === 'paused');
  assert.deepEqual(new Set(reaped), new Set(['root', child.sessionId]));
  assert.equal((await record()).checks.length, 0);
  await waitFor(async () => !(await record()).runtime_pid);
  // Native switch must keep the original connection if actual work cannot stop.
  root.isStreaming = root.jobsRunning = true;
  started = await tool({ action: 'start', review_model: 'unused-check-model', check_in: 3600 });
  await waitFor(async () => (await record()).status === 'running');
  failReap = true;
  assert.deepEqual(await events.session_before_switch(), { cancel: true });
  assert.equal((await record()).status, 'stop_unconfirmed'); assert(notices.length);
  assert.equal((await tool({ action: 'context' })).thread_id, 'root');
  failReap = false;
  assert.equal(await events.session_before_switch(), undefined);
  assert.equal((await record()).status, 'paused');
  console.log('OMP_TEST_PASS native input, owned members, inherited permissions, amendments and owner-scoped reap');
} finally {
  await events.session_shutdown?.();
  await fs.rm(project, { recursive: true, force: true });
}

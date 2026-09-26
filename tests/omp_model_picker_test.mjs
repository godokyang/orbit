// ADR-009 picker (proposal B): keyboard multi-select over ctx.ui.custom().
// Pure-component flows plus the /orbit-models command bridge against the REAL
// model-candidates CLI (temporary XDG config; no provider traffic). The ask
// observation seam (ask_interrupted / ask_resolved) is exercised through a
// live session subscription after a real orbit start, mirroring how the root
// `remember()` subscription observes it in production.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { execFileSync, execSync } from 'node:child_process';
import { createModelPicker, decodePickerKey, pickerNetDelta, installOmpExtension } from '../plugins/omp-host.mjs';
import fsSync from 'node:fs';
import { z } from 'zod';

process.env.ORBIT_RUBY = process.env.ORBIT_RUBY || execSync('which ruby').toString().trim();
delete process.env.TYPESAFE_API_KEY;
process.env.XDG_CONFIG_HOME = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-picker-xdg-'));
const CLI_ARGS = ['--disable-gems', path.resolve('scripts/orbit'), 'model-candidates'];
const runCli = (...args) => JSON.parse(execFileSync(process.env.ORBIT_RUBY, [...CLI_ARGS, ...args], { encoding: 'utf8' }));

const ENTRIES = [
  { id: 'zhipu/glm-5.2', available: true },
  { id: 'zhipu/glm-4.7', available: true },
  { id: 'old/pooled-1', available: false },
];

// 1. Key decoding: legacy + kitty CSI-u for the bound keys; unknowns never
// leak into the query.
assert.equal(decodePickerKey('\x1b[A'), 'up');
assert.equal(decodePickerKey('\x1bOB'), 'down');
assert.equal(decodePickerKey('\r'), 'enter');
assert.equal(decodePickerKey(' '), 'space');
assert.equal(decodePickerKey('\x7f'), 'backspace');
assert.equal(decodePickerKey('\x1b'), 'escape');
assert.equal(decodePickerKey('\x03'), 'escape', 'ctrl+c cancels like Esc');
assert.equal(decodePickerKey('\x1b[5~'), 'pageUp');
assert.equal(decodePickerKey('\x1b[13u'), 'enter', 'kitty enter');
assert.equal(decodePickerKey('\x1b[127u'), 'backspace', 'kitty backspace');
assert.equal(decodePickerKey('g'), 'text:g');
assert.equal(decodePickerKey('Ω'), null, 'non-ascii input is ignored');
assert.equal(decodePickerKey('\x1b[200~'), null, 'paste escape is ignored');
assert.equal(decodePickerKey(''), null);

// 2. Search, toggle, and the unavailable-entry rule. The stale pool entry is
// removable but can never be (re-)added from this session.
{
  const commits = [];
  let outcome = null;
  const picker = createModelPicker({
    entries: ENTRIES, snapshot: ['old/pooled-1'],
    commit: async delta => { commits.push(delta); return { ok: true, models: ['zhipu/glm-5.2'] }; },
    done: result => { outcome = result; },
  });
  const rows = () => picker.render(100).join('\n');
  assert.match(rows(), /已选 1 \/ 当前可选 2/, 'snapshot membership is the opening checkbox state');
  assert.match(rows(), /> \[ \] zhipu\/glm-5\.2/, 'cursor starts on the first selectable row');
  assert.match(rows(), /\[x\] old\/pooled-1\s+· 当前不可选，仅可移出/, 'a pooled-but-unselectable entry is listed as kept');

  for (const ch of 'glm5') picker.handleInput(ch);
  assert.doesNotMatch(rows(), /glm-4\.7/, 'typing narrows by provider/id subsequence');
  assert.match(rows(), /zhipu\/glm-5\.2/, 'the match stays visible');
  for (let n = 0; n < 4; n++) picker.handleInput('\x7f');
  assert.match(rows(), /glm-4\.7/, 'backspace restores the full list');

  picker.handleInput(' ');
  picker.handleInput('\x1b[B');
  picker.handleInput('\x1b[B');
  picker.handleInput(' ');
  assert.match(rows(), /本次待新增 1 待移出 1/, 'the pending net delta is visible before Enter');
  picker.handleInput(' ');
  assert.match(rows(), /\[ \] old\/pooled-1/, 'an unavailable entry stays unchecked after the refusal');
  assert.match(rows(), /提示：old\/pooled-1 当前不可选，只能移出，不能新增/, 'adding an unavailable entry is refused with a reason');
  picker.handleInput('\r');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(commits, [{ add: ['zhipu/glm-5.2'], remove: ['old/pooled-1'], base: ['old/pooled-1'] }],
    'one Enter submits the whole net delta against the opening snapshot');
  assert.equal(outcome.status, 'committed');
}

// 3. Esc cancels without any write; a no-change Enter closes as noop.
{
  const commits = [];
  let outcome = null;
  const picker = createModelPicker({
    entries: ENTRIES, snapshot: ['old/pooled-1'],
    commit: async delta => { commits.push(delta); return { ok: true }; },
    done: result => { outcome = result; },
  });
  picker.handleInput(' ');
  picker.handleInput('\x1b');
  assert.equal(outcome.status, 'cancelled');
  assert.equal(commits.length, 0, 'Esc never reaches the pool');

  let noopOutcome = null;
  const noopPicker = createModelPicker({
    entries: ENTRIES, snapshot: ['old/pooled-1'],
    commit: async delta => { commits.push(delta); return { ok: true }; },
    done: result => { noopOutcome = result; },
  });
  noopPicker.handleInput('\r');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(noopOutcome.status, 'noop', 'no net change closes without writing');
  assert.equal(commits.length, 0);
  assert.deepEqual(pickerNetDelta(ENTRIES, new Set(['old/pooled-1']), new Set(['old/pooled-1'])),
    { add: [], remove: [] }, 'snapshot-identical selection is no delta');
}

// 4. A refused commit keeps the selection and the error on screen; a refresh
// hands back the current pool as the new base for an immediate retry.
{
  const commits = [];
  let outcome = null;
  const picker = createModelPicker({
    entries: ENTRIES, snapshot: ['old/pooled-1'],
    commit: async delta => {
      commits.push(delta);
      if (commits.length === 1)
        return { ok: false, error: '提交被拒绝：changed since the snapshot',
          entries: [...ENTRIES, { id: 'other/new-session', available: true }], snapshot: ['old/pooled-1', 'zhipu/glm-5.2'] };
      return { ok: true, models: ['ok'] };
    },
    done: result => { outcome = result; },
  });
  picker.handleInput(' ');           // select zhipu/glm-5.2
  picker.handleInput('\x1b[B');
  picker.handleInput('\x1b[B');
  picker.handleInput(' ');           // uncheck old/pooled-1 (a removal the refresh cannot satisfy)
  picker.handleInput('\r');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(outcome, null, 'a refused commit keeps the picker open');
  assert.match(picker.render(100).join('\n'), /保存失败：提交被拒绝：changed since the snapshot/, 'the refusal reason stays on screen');
  assert.match(picker.render(100).join('\n'), /\[x\] zhipu\/glm-5\.2/, 'the user\'s selection survives the refresh');
  picker.handleInput('\r');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(commits.length, 2, 'retry is possible without re-picking');
  assert.deepEqual(commits[1].base, ['old/pooled-1', 'zhipu/glm-5.2'], 'the retry is computed against the refreshed snapshot');
  assert.deepEqual(commits[1].remove, ['old/pooled-1'], 'the still-unsatisfied removal is the retry delta');
  assert.equal(outcome.status, 'committed');
}

// 5. Long lists scroll inside the viewport instead of overflowing it.
{
  const many = Array.from({ length: 30 }, (_, index) => ({ id: `p/m-${String(index).padStart(2, '0')}`, available: true }));
  const picker = createModelPicker({
    entries: many, snapshot: [], commit: async () => ({ ok: true }), done: () => {}, listRows: 5,
  });
  assert.match(picker.render(60).join('\n'), /还有 25 项（继续 ↓）/, 'the window is bounded');
  for (let n = 0; n < 6; n++) picker.handleInput('\x1b[B');
  assert.match(picker.render(60).join('\n'), /以上还有 2 项（继续 ↑）/, 'moving down scrolls the window');
  picker.handleInput('\x1b[5~');
  assert.match(picker.render(60).join('\n'), /> \[ \] p\/m-02/, 'pageUp moves up by a page');
  picker.handleInput('\x1b[5~');
  assert.match(picker.render(60).join('\n'), /> \[ \] p\/m-00/, 'a second pageUp reaches the top');
}
console.log('picker component flows: PASS');

// --- Command bridge against the real CLI ----------------------------------
const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-picker-cmd-')));
const agentRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-picker-agents-'));
await fs.mkdir(path.join(agentRoot, 'agents'), { recursive: true });
process.env.ORBIT_SESSION_AGENT_ROOT = agentRoot;
delete process.env.ORBIT_CLI_BIN;

let command;
const pi = { registerTool: () => {}, registerCommand: (_name, def) => { command = def; }, on: () => {}, zod: z };
const sessions = [];
function fakeSession(id) {
  const listeners = new Set();
  const native = {
    sessionId: id, model: { provider: 'glm', id: 'x' }, isStreaming: false,
    sessionManager: { getSessionId: () => id, getCwd: () => project, getBranch: () => id === 'root' ? [{ type: 'message', id: 'original', message: { role: 'user', content: 'Original requirement.' } }] : [] },
    getAgentId: () => id, hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
  };
  sessions.push({ native, listeners });
  return native;
}
const root = fakeSession('root');
const rootRef = { id: 'Main', kind: 'main', parentId: null, status: 'running', session: root, sessionFile: '/tmp/pk.jsonl', history: {}, activity: null };
const registry = { list: () => [rootRef], get: id => (id === 'Main' ? rootRef : undefined),
  onChange: () => () => {}, setStatus: () => true };
const sdk = { MAIN_AGENT_ID: 'Main', AgentRegistry: { global: () => registry }, isUserInterruptAbort: () => false };

const models = [{ provider: 'zhipu', id: 'glm-5.2' }, { provider: 'zhipu', id: 'glm-4.7' }];
const notifications = [];
let activePicker = null;
let resolveCustom = null;
const ctx = {
  cwd: project, sessionManager: root.sessionManager,
  models: { list: () => models },
  hasUI: true,
  ui: {
    notify: (text, level) => notifications.push({ text, level }),
    custom: factory => new Promise(resolve => {
      resolveCustom = resolve;
      activePicker = factory({}, {}, {}, result => resolve(result));
    }),
  },
};
const drive = keys => { for (const key of keys) activePicker.handleInput(key); };
const open = async (keys, extra = {}) => {
  notifications.length = 0;
  const pending = command.handler('', { ...ctx, ...extra });
  if (keys === null) return pending; // no ui.custom driven path
  drive(keys);
  return pending;
};

installOmpExtension(pi, sdk);

// 6. One Enter commits the whole selection through the real pool CLI and the
// session agent mapping is re-synced afterwards.
runCli('add', 'old/pooled-1');
await open([' ', '\x1b[B', '\x1b[B', ' ', '\r']);
assert.deepEqual(runCli('list').models, ['zhipu/glm-5.2'], 'the committed pool replaced the snapshot state atomically');
assert.match(notifications.at(-1).text, /已保存候选池：zhipu\/glm-5\.2/, 'the final pool is shown');
assert.match(notifications.at(-1).text, /orbit-m-zhipu-glm-5-2-[0-9a-f]{8}/, 'the synced session agent is named');
assert.equal(notifications.at(-1).level, 'info');

// 7. Esc leaves the persisted pool untouched.
runCli('remove', 'zhipu/glm-5.2');
runCli('add', 'old/pooled-1');
await open([' ', '\x1b']);
assert.deepEqual(runCli('list').models, ['old/pooled-1'], 'cancel persists nothing');
assert.match(notifications.at(-1).text, /已取消/);

// 8. Same-ID conflict from another session since the snapshot: the commit is
// refused, the picker stays open with the reason, and the other session's
// pool state is not overwritten.
const pendingConflict = open([' ']);
runCli('add', 'zhipu/glm-5.2'); // another Orbit session added the same id
drive(['\r']);
await new Promise(resolve => setImmediate(resolve));
assert.match(activePicker.render(120).join('\n'), /保存失败：提交被拒绝：.*changed since the snapshot/, 'the conflict reason is on screen');
drive(['\x1b']);
await pendingConflict;
assert.deepEqual(runCli('list').models, ['old/pooled-1', 'zhipu/glm-5.2'],
  'the other session\'s add survives and the local removal never landed');

// 9. A would-be add that stopped being selectable is refused with a refreshed
// list; nothing is written.
runCli('remove', 'old/pooled-1');
runCli('remove', 'zhipu/glm-5.2');
const pendingStale = open(['\x1b[B', ' ']); // select glm-4.7 while it is still selectable
models.pop(); // glm-4.7 leaves the session catalog mid-flight
drive(['\r']);
await new Promise(resolve => setImmediate(resolve));
assert.match(activePicker.render(120).join('\n'), /保存失败：待新增模型已不在当前会话可选列表：zhipu\/glm-4\.7/, 'the stale add names the id');
assert.deepEqual(runCli('list').models, [], 'a stale add writes nothing');
drive(['\x1b']);
await pendingStale;
models.push({ provider: 'zhipu', id: 'glm-4.7' });

// 10. Headless: without ctx.ui.custom the bare command still prints the text
// list and keeps the per-item commands.
const headless = await command.handler('', { ...ctx, ui: { notify: ctx.ui.notify } });
assert.match(headless === undefined ? notifications.at(-1).text : '', /addable/, 'no-UI fallback prints the text list');
assert.match(notifications.at(-1).text, /\/orbit-models add/);

// --- Native ask interruption observation ----------------------------------
// 11. A real start binds the root session; a synthetic interrupt_skipped
// ask end on that session lands in hub_events exactly once, and a later
// non-error ask end from the same agent resolves it.
const definition = {};
pi.registerTool = tool => { definition.tool = tool; };
installOmpExtension(pi, sdk);
const tool = async args => JSON.parse((await definition.tool.execute('call', args, null, null, ctx)).content[0].text);
const started = await tool({ action: 'start', message_id: 'original' });
try { process.kill(-started.pid, 'SIGTERM'); } catch { /* already gone */ }
for (let n = 0; n < 40; n++) {
  try { process.kill(started.pid, 0); } catch { break; }
  await new Promise(resolve => setTimeout(resolve, 100));
}
{
  const statePath = path.join(started.task_directory, 'state.json');
  const fixture = JSON.parse(await fs.readFile(statePath, 'utf8'));
  fixture.status = 'running';
  fixture.runtime_pid = process.pid;
  await fs.writeFile(statePath, JSON.stringify(fixture));
}
const request = (method, extra = {}) => new Promise((resolve, reject) => {
  const peer = net.createConnection(JSON.parse(fsSync.readFileSync(path.join(started.task_directory, 'state.json'), 'utf8')).connection.socket);
  let data = '';
  peer.on('error', reject);
  peer.on('connect', () => peer.write(JSON.stringify({ method, session: 'root', ...extra }) + '\n'));
  peer.on('data', b => { data += b; if (data.includes('\n')) { peer.end(); resolve(JSON.parse(data.split('\n')[0]).result); } });
});
const emitToRoot = event => { for (const { listeners } of sessions) if (listeners.size) for (const listener of listeners) listener(event); };
emitToRoot({ type: 'tool_execution_start', toolName: 'ask', toolCallId: 'ask-1',
  args: { questions: [{ id: 'q1', question: '用哪个数据库？' }] } });
emitToRoot({ type: 'tool_execution_end', toolName: 'ask', toolCallId: 'ask-1', isError: true,
  result: { content: [{ type: 'text', text: 'Skipped due to pending steering message. Do not count this skipped result as completed work or verification.' }],
    details: { __synthetic: true, source: 'interrupt_skipped', executed: false } } });
emitToRoot({ type: 'tool_execution_end', toolName: 'ask', toolCallId: 'ask-1', isError: true,
  result: { content: [{ type: 'text', text: 'Skipped due to pending steering message.' }], details: { __synthetic: true, source: 'interrupt_skipped', executed: false } } });
emitToRoot({ type: 'tool_execution_end', toolName: 'bash', toolCallId: 'b-1', isError: false, result: { details: {} } });
let events = (await request('hub_events')).events;
const interrupted = events.filter(e => e.kind === 'ask_interrupted');
assert.equal(interrupted.length, 1, 'the skip is recorded exactly once per invocation id');
assert.equal(interrupted[0].tool_call_id, 'ask-1');
assert.equal(interrupted[0].agent_id, 'Main');
assert.equal(interrupted[0].question, '用哪个数据库？');
assert.equal(interrupted[0].skipped_source, 'pending steering message');
assert.equal(interrupted[0].started, false);
assert.equal(events.filter(e => e.kind === 'ask_resolved').length, 0, 'a non-ask tool end never resolves');
emitToRoot({ type: 'tool_execution_end', toolName: 'ask', toolCallId: 'ask-2', isError: false, result: { content: [] } });
events = (await request('hub_events')).events;
const resolved = events.filter(e => e.kind === 'ask_resolved');
assert.equal(resolved.length, 1, 'a successful ask end resolves');
assert.equal(resolved[0].tool_call_id, 'ask-2');

console.log('orbit model picker + ask observation: PASS');

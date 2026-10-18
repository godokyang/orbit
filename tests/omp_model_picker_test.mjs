// ADR-009 picker (proposal B): keyboard multi-select over ctx.ui.custom(),
// scoped to ONE role pool per invocation (executor or checker). Pure-component
// flows plus the /orbit-models command bridge against the REAL model-candidates
// CLI (temporary XDG config; no provider traffic). The ask observation seam
// (ask_interrupted / ask_resolved) is exercised through a live session
// subscription after a real orbit start, mirroring how the root `remember()`
// subscription observes it in production.
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
const pickerTempDirs = [];
process.on('exit', () => { for (const dir of pickerTempDirs) fsSync.rmSync(dir, { recursive: true, force: true }); });
process.env.XDG_CONFIG_HOME = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-picker-xdg-'));
pickerTempDirs.push(process.env.XDG_CONFIG_HOME);
const CLI_ARGS = ['--disable-gems', path.resolve('scripts/orbit'), 'model-candidates'];
const runCli = (...args) => JSON.parse(execFileSync(process.env.ORBIT_RUBY, [...CLI_ARGS, ...args], { encoding: 'utf8' }));
const rolePool = role => runCli('list', '--role', role);
const tick = () => new Promise(resolve => setImmediate(resolve));

const ENTRIES = [
  { id: 'zhipu/glm-5.2', available: true },
  { id: 'zhipu/glm-4.7', available: true },
  { id: 'old/pooled-1', available: false },
];
const roleView = ({ role = 'executor', label = '执行者', scope = '受控任务的执行成员',
  entries = ENTRIES, snapshot = [], configured = false, roleScoped = true, statusNote = null } = {}) =>
  ({ role, label, scope, entries, snapshot, configured, roleScoped, statusNote });

// 1. Key decoding: legacy + kitty CSI-u for the bound keys; unknowns never
// leak into the query.
assert.equal(decodePickerKey('\x1b[A'), 'up');
assert.equal(decodePickerKey('\x1bOB'), 'down');
assert.equal(decodePickerKey('\r'), 'enter');
assert.equal(decodePickerKey(' '), 'space');
assert.equal(decodePickerKey('\t'), 'roleNext', 'tab switches the edited role');
assert.equal(decodePickerKey('\x1b[Z'), 'rolePrev', 'shift+tab switches back');
assert.equal(decodePickerKey('\x1b[C'), 'models');
assert.equal(decodePickerKey('\x1b[D'), 'categories');
assert.equal(decodePickerKey('\x7f'), 'backspace');
assert.equal(decodePickerKey('\x1b'), 'escape');
assert.equal(decodePickerKey('\x03'), 'escape', 'ctrl+c cancels like Esc');
assert.equal(decodePickerKey('\x1b[5~'), 'pageUp');
assert.equal(decodePickerKey('\x1b[13u'), 'enter', 'kitty enter');
assert.equal(decodePickerKey('\x1b[9u'), 'roleNext', 'kitty tab');
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
    roles: [roleView({ snapshot: ['old/pooled-1'] })], role: 'executor',
    commit: async delta => { commits.push(delta); return { ok: true, models: ['zhipu/glm-5.2'] }; },
    done: result => { outcome = result; },
  });
  const rows = () => picker.render(100).join('\n');
  assert.match(rows(), /> \[ \] zhipu\/glm-5\.2/, 'cursor starts on the first selectable row');

  for (const ch of 'glm5') picker.handleInput(ch);
  assert.doesNotMatch(rows(), /glm-4\.7/, 'typing narrows by provider/id subsequence');
  assert.match(rows(), /zhipu\/glm-5\.2/, 'the match stays visible');
  for (let n = 0; n < 4; n++) picker.handleInput('\x7f');
  assert.match(rows(), /glm-4\.7/, 'backspace restores the full list');

  picker.handleInput(' ');
  picker.handleInput('\x1b[B');
  picker.handleInput('\x1b[B');
  picker.handleInput(' ');
  picker.handleInput(' ');
  assert.match(rows(), /\[ \] old\/pooled-1/, 'an unavailable entry stays unchecked after the refusal');
  picker.handleInput('\r');
  await tick();
  assert.deepEqual(commits, [{ role: 'executor', add: ['zhipu/glm-5.2'], remove: ['old/pooled-1'], base: ['old/pooled-1'] }],
    'one Enter submits ONE role-scoped net delta against the opening snapshot');
  assert.deepEqual(outcome, { status: 'committed', role: 'executor', label: '执行者', models: ['zhipu/glm-5.2'] });
}


// 3. Esc cancels without any write; a no-change Enter closes as noop.
{
  const commits = [];
  let outcome = null;
  const picker = createModelPicker({
    roles: [roleView({ snapshot: ['old/pooled-1'] })], role: 'executor',
    commit: async delta => { commits.push(delta); return { ok: true }; },
    done: result => { outcome = result; },
  });
  picker.handleInput(' ');
  picker.handleInput('\x1b');
  assert.equal(outcome.status, 'cancelled');
  assert.equal(commits.length, 0, 'Esc never reaches the pool');

  let noopOutcome = null;
  const noopPicker = createModelPicker({
    roles: [roleView({ snapshot: ['old/pooled-1'] })], role: 'executor',
    commit: async delta => { commits.push(delta); return { ok: true }; },
    done: result => { noopOutcome = result; },
  });
  noopPicker.handleInput('\r');
  await tick();
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
    roles: [roleView({ snapshot: ['old/pooled-1'] })], role: 'executor',
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
  await tick();
  assert.equal(outcome, null, 'a refused commit keeps the picker open');
  assert.match(picker.render(100).join('\n'), /\[x\] zhipu\/glm-5\.2/, 'the user\'s selection survives the refresh');
  picker.handleInput('\r');
  await tick();
  assert.equal(commits.length, 2, 'retry is possible without re-picking');
  assert.deepEqual(commits[1].base, ['old/pooled-1', 'zhipu/glm-5.2'], 'the retry is computed against the refreshed snapshot');
  assert.deepEqual(commits[1].remove, ['old/pooled-1'], 'the still-unsatisfied removal is the retry delta');
  assert.equal(outcome.status, 'committed');
}

// 5. Long lists scroll inside the viewport instead of overflowing it.
{
  const many = Array.from({ length: 30 }, (_, index) => ({ id: `p/m-${String(index).padStart(2, '0')}`, available: true }));
  const picker = createModelPicker({
    roles: [roleView({ entries: many, snapshot: [] })], role: 'executor',
    commit: async () => ({ ok: true }), done: () => {}, listRows: 5,
  });
  for (let n = 0; n < 6; n++) picker.handleInput('\x1b[B');
  picker.handleInput('\x1b[5~');
  assert.match(picker.render(60).join('\n'), /> \[ \] p\/m-02/, 'pageUp moves up by a page');
  picker.handleInput('\x1b[5~');
  assert.match(picker.render(60).join('\n'), /> \[ \] p\/m-00/, 'a second pageUp reaches the top');
}

// 6. The first screen chooses the role; each row states that role's own pool
// state, so an unconfigured role and an explicitly empty one never look alike.
{
  let outcome = null;
  const picker = createModelPicker({
    roles: [
      roleView({ entries: [{ id: 'zhipu/glm-5.2', available: true }], snapshot: ['zhipu/glm-5.2'] }),
      roleView({ role: 'checker', label: '检查者', scope: '独立检查者的首选型号',
        entries: [{ id: 'zhipu/glm-5.2', available: true }], snapshot: [], configured: true }),
    ],
    commit: async () => ({ ok: true }), done: result => { outcome = result; },
  });
  const rows = () => picker.render(120).join('\n');
  picker.handleInput('\x1b[B');
  picker.handleInput('\r');
  assert.match(rows(), /\[ \] zhipu\/glm-5\.2/, 'the empty checker pool starts unchecked even though the executor pool has that model');
  picker.handleInput('\r');
  await tick();
  assert.equal(outcome.status, 'noop', 'an untouched empty checker pool saves nothing');
}

// 7. Pending edits block the role switch instead of being carried across, and
// one Enter commits exactly one role-scoped delta.
{
  const commits = [];
  let outcome = null;
  const picker = createModelPicker({
    roles: [
      roleView({ entries: [{ id: 'zhipu/glm-5.2', available: true }], snapshot: [], configured: true }),
      roleView({ role: 'checker', label: '检查者', entries: [{ id: 'zhipu/glm-4.7', available: true }], snapshot: [], configured: true }),
    ],
    role: 'executor',
    commit: async delta => { commits.push(delta); return { ok: true, models: delta.add }; },
    done: result => { outcome = result; },
  });
  picker.handleInput(' ');
  picker.handleInput('\t');
  picker.handleInput('\r');
  await tick();
  assert.deepEqual(commits, [{ role: 'executor', add: ['zhipu/glm-5.2'], remove: [], base: [] }], 'one Enter = one role-scoped delta');
  assert.deepEqual(outcome, { status: 'committed', role: 'executor', label: '执行者', models: ['zhipu/glm-5.2'] });
}

// 8. --role skips the chooser and edits only that pool.
{
  const commits = [];
  let outcome = null;
  const picker = createModelPicker({
    roles: [
      roleView({ snapshot: [] }),
      roleView({ role: 'checker', label: '检查者', entries: [{ id: 'kimi-code/k3-256k', available: true }], snapshot: [] }),
    ],
    role: 'checker',
    commit: async delta => { commits.push(delta); return { ok: true, models: delta.add }; },
    done: result => { outcome = result; },
  });
  picker.handleInput(' ');
  picker.handleInput('\r');
  await tick();
  assert.deepEqual(commits, [{ role: 'checker', add: ['kimi-code/k3-256k'], remove: [], base: [] }]);
  assert.equal(outcome.role, 'checker');
}
// Categories restrict browsing, never the selected set or the role-scoped delta.
{
  const entries = [
    { id: 'alpha/first', available: true },
    { id: 'beta/second', available: true },
    { id: 'retired/old', available: false },
  ];
  const commits = [];
  const picker = createModelPicker({ roles: [roleView({ entries, snapshot: ['beta/second', 'retired/old'] })],
    role: 'executor', commit: async delta => { commits.push(delta); return { ok: true }; }, done() {} });
  const screen = () => picker.render(160).join('\n');
  assert.match(screen(), /alpha\s+1/);
  picker.handleInput('\x1b[D'); // category focus
  picker.handleInput('\x1b[B'); // selected scope
  assert.doesNotMatch(screen(), /\[ \] alpha\/first/);
  picker.handleInput('\x1b[B'); // alpha scope
  picker.handleInput('\r'); // enter models, never commit
  assert.equal(commits.length, 0);
  assert.match(screen(), /> \[ \] alpha\/first/);
  assert.match(screen(), /\[x\] beta\/second/, 'other-provider selection remains visible in its own panel');
  picker.handleInput(' ');
  picker.handleInput('z');
  assert.match(screen(), /无匹配模型/);
  picker.handleInput('\r');
  await tick();
  assert.deepEqual(commits[0], { role: 'executor', add: ['alpha/first'], remove: [], base: ['beta/second', 'retired/old'] });
}

// A long pool remains inspectable via the selected scope.
{
  const entries = Array.from({ length: 24 }, (_, i) => ({ id: `provider-${i}/model-with-a-long-name-${i}`, available: true }));
  const picker = createModelPicker({ roles: [roleView({ entries, snapshot: entries.map(e => e.id) })],
    role: 'executor', commit: async () => ({ ok: true }), done() {}, listRows: 5 });
  picker.handleInput('\x1b[1;5B');
  for (let i = 0; i < 23; i++) picker.handleInput('\x1b[B');
  assert.match(picker.render(160).join('\n'), /> \[x\] provider-23\/model-with-a-long-name-23/);
}

// ANSI focus must stay within its pane; Chinese text must not overflow cells.
{
  const theme = {
    fg: (_token, text) => `\x1b[36m${text}\x1b[39m`,
  };
  const picker = createModelPicker({
    roles: [roleView({ snapshot: ['old/pooled-1'] })], role: 'executor', theme,
    commit: async () => ({ ok: true }), done() {},
  });
  for (const width of [40, 80, 132, 180]) {
    for (const line of picker.render(width)) {
      const plain = line.replace(/\x1b\[\d+(?:;\d+)*m/g, '');
      assert.ok(!plain.includes('\x1b'), 'no partial escape sequence escapes clipping');
      const cells = [...plain].reduce((sum, ch) => sum + (ch.codePointAt(0) >= 0x2e80 ? 2 : 1), 0);
      assert.ok(cells <= width, `rendered line exceeds ${width} terminal cells`);
    }
  }
  const focused = picker.render(180).join('\n').match(/\x1b\[7m([\s\S]*?)\x1b\[27m/g);
  assert.equal(focused.length, 1, 'only the active pane owns a keyboard focus highlight');
  assert.ok(focused[0].includes('zhipu/glm-5.2'));
  assert.ok(!focused[0].includes('old/pooled-1'), 'selection summary is not painted as focused');
  picker.handleInput('\x1b[D');
  const categoryFocus = picker.render(180).join('\n').match(/\x1b\[7m([\s\S]*?)\x1b\[27m/g);
  assert.equal(categoryFocus.length, 1);
  assert.ok(!categoryFocus[0].includes('zhipu/glm-5.2'), 'focus moved out of the model list');
}

console.log('picker component flows: PASS');

// --- Command bridge against the real CLI ----------------------------------
const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-picker-cmd-')));
const agentRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-picker-agents-'));
pickerTempDirs.push(project, agentRoot);
await fs.mkdir(path.join(agentRoot, 'agents'), { recursive: true });
process.env.PI_CODING_AGENT_DIR = agentRoot;
await fs.writeFile(path.join(agentRoot, 'models.yml'), `providers:
  zhipu:
    baseUrl: https://example.invalid/v1
    apiKey: fixture-key
    api: openai-completions
    models:
      - id: glm-5.2
        name: Fixture GLM 5.2
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
      - id: glm-4.7
        name: Fixture GLM 4.7
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
`);
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
      activePicker = factory({ requestRender() {} }, {}, {}, result => resolve(result));
    }),
  },
};
const drive = keys => { for (const key of keys) activePicker.handleInput(key); };
const open = async (keys, extra = {}, args = '') => {
  notifications.length = 0;
  const pending = command.handler(args, { ...ctx, ...extra });
  if (keys === null) return pending; // no ui.custom driven path
  drive(keys);
  return pending;
};
const agentFiles = async () => (await fs.readdir(path.join(agentRoot, 'agents'))).sort();

installOmpExtension(pi, sdk);

// 9. The role chooser then ONE Enter commits the whole executor selection
// through the real pool CLI; the untouched checker role keeps inheriting the
// legacy shared list, and the session agent mapping is re-synced.
runCli('add', 'old/pooled-1');
await open(['\r', ' ', '\x1b[B', '\x1b[B', ' ', '\r']);
assert.deepEqual(rolePool('executor').models, ['zhipu/glm-5.2'], 'the executor delta landed atomically');
assert.deepEqual(rolePool('checker').models, ['old/pooled-1'], 'the checker role still inherits the legacy list');
assert.equal(rolePool('executor').configured, true);
assert.equal(rolePool('checker').configured, false);
assert.match(notifications.at(-1).text, /已保存候选池：执行者（executor）：zhipu\/glm-5\.2/, 'the final pool names the role');
assert.match(notifications.at(-1).text, /orbit-m-zhipu-glm-5-2-[0-9a-f]{8}/, 'the synced session agent is named');
assert.equal(notifications.at(-1).level, 'info');
assert.ok((await agentFiles()).some(name => name.includes('glm-5-2')), 'an executor save materializes its member agent');

// 10. Esc leaves the persisted pool untouched.
await open(['\r', '\x1b[B', ' ', '\x1b']);
assert.deepEqual(rolePool('executor').models, ['zhipu/glm-5.2'], 'cancel persists nothing');
assert.match(notifications.at(-1).text, /已取消/);

// 11. Same-ID conflict from another session since the snapshot: the commit is
// refused, the picker stays open with the reason, and the other session's
// pool state is not overwritten.
const pendingConflict = open(['\r', '\x1b[B', ' ']); // executor: check glm-4.7
runCli('add', 'zhipu/glm-4.7', '--role', 'executor'); // another Orbit session added the same id
drive(['\r']);
await tick();
assert.match(activePicker.render(120).join('\n'), /保存失败：提交被拒绝：.*changed since the snapshot/, 'the conflict reason is on screen');
drive(['\x1b']);
await pendingConflict;
assert.deepEqual(rolePool('executor').models, ['zhipu/glm-5.2', 'zhipu/glm-4.7'],
  'the other session\'s add survives and the local duplicate never landed');

// 12. A would-be add that stopped being selectable is refused with a refreshed
// list; nothing is written.
runCli('remove', 'zhipu/glm-4.7', '--role', 'executor');
const pendingStale = open(['\r', '\x1b[B', ' ']); // select glm-4.7 while it is still selectable
models.pop(); // glm-4.7 leaves the session catalog mid-flight
drive(['\r']);
await tick();
assert.match(activePicker.render(120).join('\n'), /保存失败：待新增模型已不在当前会话可选列表：zhipu\/glm-4\.7/, 'the stale add names the id');
assert.deepEqual(rolePool('executor').models, ['zhipu/glm-5.2'], 'a stale add writes nothing');
drive(['\x1b']);
await pendingStale;
models.push({ provider: 'zhipu', id: 'glm-4.7' });

// 13. A checker-pool save names its role, never re-syncs the executor member
// agents, and never materializes an agent for a checker-only candidate.
runCli('remove', 'zhipu/glm-5.2', '--role', 'executor'); // no CLI-side sync: the generated agent file stays
await open(['\x1b[B', '\r', '\x1b[B', ' ', '\r']);      // chooser → checker, check glm-4.7
assert.deepEqual(rolePool('checker').models, ['old/pooled-1', 'zhipu/glm-4.7']);
assert.deepEqual(rolePool('executor').models, [], 'the executor pool was not touched');
assert.match(notifications.at(-1).text, /已保存候选池：检查者（checker）：old\/pooled-1, zhipu\/glm-4\.7/);
assert.match(notifications.at(-1).text, /执行者成员 Agent 未改动/);
assert.ok((await agentFiles()).some(name => name.includes('glm-5-2')),
  'a checker save does not re-sync (a resync would have dropped the now-unpooled executor agent)');
assert.equal((await agentFiles()).filter(name => name.includes('glm-4-7')).length, 0,
  'a checker-only candidate never becomes a member agent');

// 14. Headless: without ctx.ui.custom the command prints both role sections
// with their real state, and the per-item commands accept an explicit --role.
const headless = await command.handler('', { ...ctx, ui: { notify: ctx.ui.notify } });
const text = headless === undefined ? notifications.at(-1).text : '';
assert.match(text, /\[addable\]/, 'no-UI fallback prints the text list');
assert.match(text, /\/orbit-models add <provider\/id> \[--role executor\|checker\]/);
assert.match(text, /执行者（executor）已配置：0 个候选（显式空池：不借用另一角色候选，也不回退 OMP 默认）/);
assert.match(text, /检查者（checker）已配置：2 个候选/);

await command.handler('add zhipu/glm-5.2 --role checker', { ...ctx, ui: { notify: ctx.ui.notify } });
assert.match(notifications.at(-1).text, /Added zhipu\/glm-5\.2 → 检查者池（checker）/, 'the role is named');
assert.match(notifications.at(-1).text, /执行者成员 Agent 未改动/);
assert.deepEqual(rolePool('checker').models, ['old/pooled-1', 'zhipu/glm-4.7', 'zhipu/glm-5.2']);
assert.deepEqual(rolePool('executor').models, [], 'a role-scoped add never writes the other pool');

await command.handler('add zhipu/glm-4.7', { ...ctx, ui: { notify: ctx.ui.notify } });
assert.match(notifications.at(-1).text, /Added zhipu\/glm-4\.7 → 旧共享列表（无角色）/, 'a bare add stays on the legacy shared list');
assert.match(notifications.at(-1).text, /Live session agents:/, 'the legacy shared scope still re-syncs member agents');

// --- Native ask interruption observation ----------------------------------
// 15. A real start binds the root session; a synthetic interrupt_skipped
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
let events = (await request('collaboration_events')).events;
const interrupted = events.filter(e => e.kind === 'ask_interrupted');
assert.equal(interrupted.length, 1, 'the skip is recorded exactly once per invocation id');
assert.equal(interrupted[0].tool_call_id, 'ask-1');
assert.equal(interrupted[0].agent_id, 'Main');
assert.equal(interrupted[0].question, '用哪个数据库？');
assert.equal(interrupted[0].skipped_source, 'pending steering message');
assert.equal(interrupted[0].started, false);
assert.equal(events.filter(e => e.kind === 'ask_resolved').length, 0, 'a non-ask tool end never resolves');
emitToRoot({ type: 'tool_execution_end', toolName: 'ask', toolCallId: 'ask-2', isError: false, result: { content: [] } });
events = (await request('collaboration_events')).events;
const resolved = events.filter(e => e.kind === 'ask_resolved');
assert.equal(resolved.length, 1, 'a successful ask end resolves');
assert.equal(resolved[0].tool_call_id, 'ask-2');

console.log('orbit model picker + ask observation: PASS');

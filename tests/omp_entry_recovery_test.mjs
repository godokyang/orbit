import assert from 'node:assert/strict';
import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { z } from 'zod';
import { execSync, spawn, spawnSync } from 'node:child_process';
import { installOmpExtension, appendInstructionToPayload } from '../plugins/omp-host.mjs';

// The installer pins the verified Ruby via ORBIT_RUBY; extension children
// (the real orbit CLI: entry, start, model-candidates, model-evidence) use it.
process.env.ORBIT_RUBY = process.env.ORBIT_RUBY || execSync('which ruby').toString().trim();
// Bootstrap-deadlock regression, exercised through the REAL stack: the real
// orbit CLI (entry + start), the real checker selector, the real
// ModelEvidenceCache, the real socket bridge. No model quality is mocked:
// TYPESAFE_API_KEY is deleted, so every selection that needs a quality
// verdict fails closed with its real reason.
delete process.env.TYPESAFE_API_KEY;
process.env.XDG_CONFIG_HOME = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-entry-cfg-'));
process.env.XDG_CACHE_HOME = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-entry-cache-'));

const ruby = process.env.ORBIT_RUBY;
const runCli = (args, input = '') => spawnSync(ruby, ['--disable-gems', cli, ...args],
  { input, encoding: 'utf8', env: process.env, timeout: 60000 });

const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-entry-rec-')));
const originalText = '请用 Orbit 受控方式执行：修复登录页并独立检查。';
const model = { provider: 'glm', id: 'x' };
const mainAgentId = 'Main';
const repo = new URL('..', import.meta.url).pathname;
const cli = path.join(repo, 'scripts', 'orbit');

let events = {}; let definition;
const aborts = [], asides = [], notifications = [];
let extProject = null;
// G9 block resources, recovered in finally even when an assertion fails
// mid-block: caller-owned directories, live servers/child processes and any
// harness whose extension got as far as listening.
const g9Paths = [], g9Closers = [], g9Harnesses = [];

function session(id, branch = []) {
  const listeners = new Set();
  return { sessionId: id, model, isStreaming: false, isCompacting: false, isBashRunning: false, isEvalRunning: false,
    sessionManager: { getSessionId: () => id, getCwd: () => project, getBranch: () => branch },
    getAgentId: () => id, hasPendingAsyncWork: () => false, getAsyncJobSnapshot: () => ({ running: [] }),
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
    sendCustomMessage: async () => {}, abort: async () => {} };
}
const root = session('root', [{ type: 'message', id: 'original', message: { role: 'user', content: originalText } }]);
const rootRef = { id: mainAgentId, kind: 'main', parentId: null, status: 'running', session: root, sessionFile: '/tmp/root.jsonl', history: {}, activity: null };
const registry = { list: () => [rootRef], get: id => (id === mainAgentId ? rootRef : undefined) };
const ctx = { cwd: project, sessionManager: root.sessionManager, models: { list: () => [model] }, hasUI: true,
  ui: { notify: (text, level) => notifications.push({ text, level }) }, abort: () => { aborts.push('root'); } };
const pi = { zod: z, registerTool: tool => { definition = tool; }, registerCommand: () => {},
  on: (name, handler) => { (events[name] ||= []).push(handler); },
  sendMessage: (message, options) => { asides.push({ message, options }); } };
const sdk = { MAIN_AGENT_ID: mainAgentId, AgentRegistry: { global: () => registry }, isUserInterruptAbort: () => false };

// Dispatch like OMP's extension runner: each before_provider_request return
// value replaces the payload the next handler (and finally the provider) sees.
const emit = async (name, event, context) => {
  let result;
  for (const handler of events[name] || []) {
    const value = await handler(event, context);
    if (value !== undefined) { result = value; if (event && typeof event === 'object' && 'payload' in event) event.payload = value; }
  }
  return result;
};
const requestPayload = () => ({ model: 'glm/x', max_tokens: 128, system: [{ type: 'text', text: 'system' }],
  messages: [{ role: 'user', content: [{ type: 'text', text: originalText }] }] });
const tool = async args => JSON.parse((await definition.execute('call', args, null, null, ctx)).content[0].text);
const taskDirectories = async () => (await fs.readdir(path.join(project, '.orbit', 'tasks')).catch(() => [])).sort();
const lastBlockText = payload => {
  const last = payload.messages.at(-1);
  const content = last.content;
  return typeof content === 'string' ? content : content.at(-1).text;
};

try {
  // Non-empty real candidate pool (glm/x is in the fake session catalog), so
  // the selector takes the auto path and must judge cached quality evidence.
  assert.equal(runCli(['model-candidates', 'add', 'glm/x']).status, 0, 'pool add must succeed');
  // Session agent root + pool stub so the extension can re-sync the pool and
  // serve the model catalog over the real bridge.
  const agentRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-sess-entry-'));
  await fs.mkdir(path.join(agentRoot, 'agents'), { recursive: true });
  process.env.ORBIT_SESSION_AGENT_ROOT = agentRoot;
  const poolStub = path.join(agentRoot, 'pool.sh');
  await fs.writeFile(poolStub, '#!/bin/sh\nprintf \'{"models":["glm/x"]}\\n\'\n');
  await fs.chmod(poolStub, 0o755);
  process.env.ORBIT_CLI_BIN = poolStub;
  installOmpExtension(pi, sdk);
  await emit('session_start', {}, ctx);

  // The automatic entry fails on the real isolated selector (glm/x is not
  // available). Recovery must ride the CURRENT request, without aborting it.
  const first = await emit('before_provider_request', { payload: requestPayload() }, ctx);
  assert.ok(first && first.messages, 'hook must return a request payload');
  const instruction = lastBlockText(first);
  assert.match(instruction, /\[orbit-entry-failed\]/);
  assert.match(instruction, /glm\/x/, 'the verbatim selector reason must list the candidate');
  assert.match(instruction, /核对 OMP 当前会话模型及隔离检查者凭据/);
  assert.match(instruction, /message_id="original"/);
  assert.match(instruction, /action=start/);
  assert.equal(first.messages.length, 1, 'instruction merges into the trailing user turn');
  assert.deepEqual(first.messages[0].content.map(block => block.type), ['text', 'text']);
  assert.equal(first.messages[0].content[0].text, originalText, 'original user content stays intact');
  assert.equal(aborts.length, 0, 'no abort: the current request must carry the instruction');
  assert.equal(asides.length, 0, 'no stale aside: it would re-deliver after the turn');
  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].level, 'error');
  assert.deepEqual(await taskDirectories(), [], 'selector failure must not leave a TaskRecord');
  const ledger = JSON.parse(await fs.readFile(path.join(project, '.orbit', 'prestart-decisions.json'), 'utf8'));
  assert.equal(ledger.original.decision, 'start', 'the message was classified once (decision recorded)');

  // 2. A later provider request of the SAME turn re-attaches the instruction
  // (payload-only injection never persists) and still does not abort; the
  // message is not re-classified.
  root.sessionManager.getBranch().push({
    type: 'message', id: 'assistant-tool', message: { role: 'assistant', content: [{ type: 'tool_call', name: 'bash' }] }
  });
  const second = await emit('before_provider_request', { payload: requestPayload() }, ctx);
  assert.match(lastBlockText(second), /\[orbit-entry-failed\]/, 'same-turn retry keeps the instruction');
  const instructionText = lastBlockText(second);
  // Same turn on the openai-codex Responses transport (the real failing
  // provider shape): the instruction rides the `input` item list too.
  const codexPayload = { type: 'response.create', model: 'openai-codex/gpt-6-sol', store: false, stream: true,
    input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: originalText }] }] };
  const codexSecond = await emit('before_provider_request', { payload: codexPayload }, ctx);
  const codexLast = codexSecond.input.at(-1);
  assert.equal(codexLast.role, 'user');
  assert.deepEqual(codexLast.content, [{ type: 'input_text', text: originalText },
    { type: 'input_text', text: instructionText }], 'responses input keeps the instruction');
  assert.equal(aborts.length, 0);
  const ledgerAgain = JSON.parse(await fs.readFile(path.join(project, '.orbit', 'prestart-decisions.json'), 'utf8'));
  assert.deepEqual(Object.keys(ledgerAgain), ['original'], 'no automatic re-classification');

  // 3. A synthetic evidence fixture exercises taskless cache submission.
  // example.com is not a real provider source; this tests storage and recovery,
  // not the validity of model facts or the quality decision.
  const retrievedAt = new Date().toISOString();
  const validUntil = new Date(Date.now() + 24 * 3600 * 1000).toISOString();
  const submission = runCli(['model-evidence', '--file', '-'], JSON.stringify({
    provider: 'glm', model: 'x', reasoning: 'default', billing_route: 'unknown',
    status: 'evidence', retrieved_at: retrievedAt, valid_until: validUntil,
    sources: ['https://example.com/glm-x-notes'],
    metrics: { context_window_tokens: { value: 128000, unit: 'tokens', basis: 'provider docs page' } }
  }));
  assert.equal(submission.status, 0, `taskless model-evidence must succeed: ${submission.stderr}`);
  assert.equal(JSON.parse(submission.stdout).status, 'cached');

  // 4. Explicit recovery on the SAME original message is permitted and makes
  // real progress: no duplicate-task refusal (none was created). Cached evidence
  // cannot make a model missing from the isolated catalog runnable.
  await assert.rejects(() => tool({ action: 'start', message_id: 'original' }), error => {
    assert.doesNotMatch(error.message, /already has an Orbit task/, 'no task existed, retry must not be refused');
    return true;
  });
  assert.deepEqual(await taskDirectories(), [], 'still no TaskRecord: no duplicate task');

  // 4b. The real failing provider shape end-to-end: a NEW message whose
  // automatic entry still fails on isolated model availability in an openai-codex
  // Responses body gets the recovery instruction injected into `input` — no
  // abort, no aside, exactly like the messages-array transports.
  root.sessionManager.getBranch().push({ type: 'message', id: 'third', message: { role: 'user', content: originalText } });
  const codexFirst = await emit('before_provider_request', { payload: {
    type: 'response.create', model: 'openai-codex/gpt-6-sol', store: false, stream: true,
    input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: originalText }] }] } }, ctx);
  const codexItem = codexFirst.input.at(-1);
  assert.equal(codexItem.type, 'message');
  assert.equal(codexItem.role, 'user');
  assert.match(codexItem.content.at(-1).text, /\[orbit-entry-failed\]/, 'responses body carries the instruction');
  assert.match(codexItem.content.at(-1).text, /message_id="third"/);
  assert.equal(aborts.length, 0, 'responses transport must not hit the abort trap');
  assert.equal(asides.length, 0);

  // 5. Unknown request shape keeps the fail-closed trap: aside + abort, and
  // the payload passes through untouched. New message, same failure family
  // (JEV gate now), still through the real stack.
  root.sessionManager.getBranch().push({ type: 'message', id: 'second', message: { role: 'user', content: originalText } });
  const opaque = { api: 'cursor', conversationState: { rootPromptMessages: [] } };
  const fallback = await emit('before_provider_request', { payload: opaque }, ctx);
  assert.equal(fallback, opaque, 'opaque payload must pass through unchanged');
  assert.equal(aborts.length, 1, 'unknown shape still aborts the turn (fail-closed)');
  assert.equal(asides.length, 1, 'unknown shape still queues the aside');
  assert.match(asides[0].message.content, /\[orbit-entry-failed\]/);
  assert.match(asides[0].message.content, /message_id="second"/);
  assert.equal(asides[0].options.deliverAs, 'aside');
  assert.deepEqual(await taskDirectories(), [], 'no TaskRecord in any path');

  // 6. Pure payload-shape matrix: every handled shape appends without
  // mutating the input; unhandled shapes return null (fail-closed caller).
  {
    const openai = { model: 'm', messages: [{ role: 'user', content: 'hi' }] };
    let out = appendInstructionToPayload(openai, 'X');
    assert.equal(out.messages[0].content, 'hi\n\nX');
    assert.deepEqual(openai, { model: 'm', messages: [{ role: 'user', content: 'hi' }] }, 'input never mutated');

    const anthropicToolResult = { messages: [{ role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1' }] }] };
    out = appendInstructionToPayload(anthropicToolResult, 'X');
    assert.deepEqual(out.messages[0].content.at(-1), { type: 'text', text: 'X' }, 'typed block after tool_result');

    const bedrock = { messages: [{ role: 'user', content: [{ text: 'hi' }] }] };
    out = appendInstructionToPayload(bedrock, 'X');
    assert.deepEqual(out.messages[0].content.at(-1), { text: 'X' }, 'bare bedrock text block');

    const assistantTail = { messages: [{ role: 'user', content: [{ text: 'hi' }] }, { role: 'assistant', content: 'done' }] };
    out = appendInstructionToPayload(assistantTail, 'X');
    assert.equal(out.messages.length, 3, 'an assistant tail is preserved, never replaced');
    assert.deepEqual(out.messages.at(-1), { role: 'user', content: 'X' }, 'new string user turn after assistant');

    const assistantToolText = { messages: [{ role: 'assistant', content: [{ type: 'text', text: 'done' }] }] };
    out = appendInstructionToPayload(assistantToolText, 'X');
    assert.equal(out.messages.length, 2, 'the assistant message stays and a user turn is appended');
    assert.deepEqual(out.messages[0].content.at(-1), { type: 'text', text: 'done' }, 'assistant content is untouched');
    assert.deepEqual(out.messages.at(-1), { role: 'user', content: [{ type: 'text', text: 'X' }] }, 'typed block in the appended user turn');

    // Tool-loop tail: an assistant tool call answered by its tool result must
    // keep the result and its pairing when a projection appends after it.
    const toolLoop = { messages: [
      { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'bash', arguments: '{}' } }] },
      { role: 'tool', tool_call_id: 'call_1', content: 'exit 0' }] };
    out = appendInstructionToPayload(toolLoop, 'X');
    assert.equal(out.messages.length, 3, 'the tool result is never dropped');
    assert.deepEqual(out.messages[1], { role: 'tool', tool_call_id: 'call_1', content: 'exit 0' },
      'the tool result keeps its call pairing');
    assert.deepEqual(out.messages[2], { role: 'user', content: 'X' }, 'the projection lands after the tool result');

    assert.equal(appendInstructionToPayload(
      { messages: [{ role: 'assistant', content: [{ type: 'tool_use', id: 't', name: 'n' }] }] }, 'X'), null,
      'assistant tool_use tail must not be followed by a user turn');
    // openai-codex Responses bodies: OMP's own Responses finalizer appends
    // user content as {type:'message', role:'user', content:[{type:'input_text'}]}
    // (verified in omp/18.3.2); the helper mirrors that item exactly.
    const responsesMerge = { type: 'response.create', model: 'openai-codex/gpt-6-sol',
      input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hi' }] }] };
    out = appendInstructionToPayload(responsesMerge, 'X');
    assert.deepEqual(out.input.at(-1).content.at(-1), { type: 'input_text', text: 'X' }, 'responses input_text part');
    assert.deepEqual(responsesMerge.input.at(-1).content, [{ type: 'input_text', text: 'hi' }], 'input never mutated');

    const responsesString = { input: [{ type: 'message', role: 'user', content: 'hi' }] };
    out = appendInstructionToPayload(responsesString, 'X');
    assert.equal(out.input.at(-1).content, 'hi\n\nX', 'responses string content merges');

    const responsesAfterOutput = { input: [
      { type: 'message', role: 'user', content: 'q' },
      { type: 'function_call', call_id: 'c', name: 'n', arguments: '{}' },
      { type: 'function_call_output', call_id: 'c', output: 'ok' }] };
    out = appendInstructionToPayload(responsesAfterOutput, 'X');
    assert.deepEqual(out.input.at(-1), { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'X' }] },
      'new user item after function_call_output');

    assert.equal(appendInstructionToPayload(
      { input: [{ type: 'function_call', call_id: 'c', name: 'n', arguments: '{}' }] }, 'X'), null,
      'responses function_call tail must not be followed by a user item');
    assert.equal(appendInstructionToPayload(
      { input: [{ type: 'message', role: 'user', content: 'hi' }, { type: 'reasoning', id: 'r' }] }, 'X'), null,
      'responses reasoning tail must not be followed by a user item');
    assert.equal(appendInstructionToPayload({ type: 'response.create', input: [] }, 'X'), null,
      'empty responses input stays untouched');
    assert.equal(appendInstructionToPayload(null, 'X'), null);
    assert.equal(appendInstructionToPayload({ messages: [] }, 'X'), null);
  }

  // 7. External integration mode (G9a) + caller-specified control socket
  //    (G9b): the automatic entry does not classify, record or prompt; the
  //    channel listens at session_start before the first user message; a
  //    session switch re-listens; close removes only our own socket — a file
  //    the caller placed at the path survives — and the caller directory is
  //    never touched. Unsafe specified paths (live socket, non-private
  //    parent) are refused; a proven-dead socket is replaced.
  extProject = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-ext-rec-')));
  // Unix socket paths are short (macOS < 104 bytes): the caller directories
  // must live under the same short /tmp strategy the production listen uses,
  // or os.tmpdir()-long prefixes push control.sock past the limit.
  const tmpBase = process.platform === 'darwin' ? '/tmp' : os.tmpdir();
  const trackPath = dir => (g9Paths.push(dir), dir);
  const probeConnect = target => new Promise((resolve, reject) => {
    const probe = net.connect(target);
    const timer = setTimeout(() => { probe.destroy(); reject(new Error(`no listener at ${target}`)); }, 3000);
    probe.on('connect', () => { clearTimeout(timer); probe.destroy(); resolve(); });
    probe.on('error', error => { clearTimeout(timer); reject(error); });
  });
  const freshHarness = branch => {
    const local = { events: {}, asides: [], notifications: [], aborts: [] };
    const pi = { zod: z, registerTool: tool => { local.definition = tool; }, registerCommand: () => {},
      on: (name, handler) => { (local.events[name] ||= []).push(handler); },
      sendMessage: (message, options) => { local.asides.push({ message, options }) } };
    local.pi = pi;
    local.emit = async (name, event, context) => {
      let result;
      for (const handler of local.events[name] || []) {
        const value = await handler(event, context);
        if (value !== undefined) { result = value; if (event && typeof event === 'object' && 'payload' in event) event.payload = value; }
      }
      return result;
    };
    const root = session('root', branch);
    const ref = { id: mainAgentId, kind: 'main', parentId: null, status: 'running', session: root, sessionFile: '/tmp/root-ext.jsonl', history: {}, activity: null };
    const registry = { list: () => [ref], get: id => (id === mainAgentId ? ref : undefined) };
    local.sdk = { MAIN_AGENT_ID: mainAgentId, AgentRegistry: { global: () => registry }, isUserInterruptAbort: () => false };
    local.ctx = { cwd: extProject, sessionManager: root.sessionManager, models: { list: () => [model] }, hasUI: true,
      ui: { notify: (text, level) => local.notifications.push({ text, level }) }, abort: () => { local.aborts.push('root'); } };
    return local;
  };

  const callerDir = trackPath(await fs.mkdtemp(path.join(tmpBase, 'orbit-caller-')));
  await fs.chmod(callerDir, 0o700);
  await fs.writeFile(path.join(callerDir, 'sentinel.txt'), 'caller-owned');
  const controlSocket = path.join(callerDir, 'control.sock');
  process.env.ORBIT_EXTERNAL_INTEGRATION = '1';
  process.env.ORBIT_CONTROL_SOCKET = controlSocket;
  const ext = freshHarness([{ type: 'message', id: 'ext1', message: { role: 'user', content: '请用 Orbit 受控执行：外部集成首条消息。' } }]);
  installOmpExtension(ext.pi, ext.sdk);
  g9Harnesses.push(ext);
  await ext.emit('session_start', {}, ext.ctx);
  assert.ok(fsSync.existsSync(controlSocket), 'G9b: the channel listens at session_start, before the first user message');
  await probeConnect(controlSocket);

  const extPayload = requestPayload();
  const passed = await ext.emit('before_provider_request', { payload: extPayload }, ext.ctx);
  assert.equal(passed, extPayload, 'G9a: the first controlled message passes through untouched');
  assert.equal(ext.asides.length, 0, 'G9a: no entry prompt aside');
  assert.equal(ext.aborts.length, 0, 'G9a: no fail-closed abort');
  assert.deepEqual(await fs.readdir(path.join(extProject, '.orbit', 'tasks')).catch(() => []), [], 'G9a: no automatic task is created');
  const extLedger = JSON.parse(await fs.readFile(path.join(extProject, '.orbit', 'prestart-decisions.json'), 'utf8').catch(() => '{}'));
  assert.ok(!('ext1' in extLedger), 'G9a: no durable entry classification record');

  // External runtime attachment uses the exact durable task, never a guessed
  // scan result. Both native tool context and hub reads see the same binding.
  const bridge = payload => new Promise((resolve, reject) => {
    const peer = net.connect(controlSocket); let data = '';
    peer.on('connect', () => peer.write(JSON.stringify({ session: 'root', ...payload }) + '\n'));
    peer.on('data', part => { data += part; if (data.includes('\n')) {
      peer.destroy(); try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
    } });
    peer.on('error', reject);
  });
  const bindDir = path.join(extProject, '.orbit', 'tasks', 'external');
  await fs.mkdir(bindDir, { recursive: true });
  const bindState = { format: 'orbit-task-1', id: 'external', project_root: extProject,
    status: 'starting', runtime_pid: process.pid, review: { model: 'glm/x' },
    connection: { provider: 'omp', socket: controlSocket, thread_id: 'root' } };
  const writeBindState = value => fs.writeFile(path.join(bindDir, 'state.json'), JSON.stringify(value));
  await writeBindState({ ...bindState, connection: { ...bindState.connection, thread_id: 'foreign' } });
  assert.match((await bridge({ method: 'bind_task', task_directory: bindDir })).error, /does not belong/);
  assert.match((await bridge({ method: 'hub_events' })).error, /requires a bound/);
  await writeBindState({ ...bindState, status: 'paused' });
  assert.match((await bridge({ method: 'bind_task', task_directory: bindDir })).error, /active runtime/);
  await writeBindState(bindState);
  const bound = await bridge({ method: 'bind_task', task_directory: bindDir });
  assert.equal(bound.result.task_directory, bindDir);
  assert.ok(Array.isArray((await bridge({ method: 'hub_events' })).result.events));
  const context = JSON.parse((await ext.definition.execute('context', { action: 'context' }, null, null, ext.ctx)).content[0].text);
  assert.equal(context.task_directory, bindDir, 'native context adopts external runtime binding');
  const otherDir = path.join(extProject, '.orbit', 'tasks', 'other');
  await fs.mkdir(otherDir);
  await fs.writeFile(path.join(otherDir, 'state.json'), JSON.stringify({ ...bindState, id: 'other' }));
  assert.match((await bridge({ method: 'bind_task', task_directory: otherDir })).error, /another active/);
  await writeBindState({ ...bindState, status: 'paused' }); // this fixture owns no runtime process

  const switched = await ext.emit('session_before_switch', {}, ext.ctx);
  assert.notEqual(switched?.cancel, true, `switch close must succeed: ${ext.notifications.at(-1)?.text || ''}`);
  assert.ok(!fsSync.existsSync(controlSocket), 'close removes our own socket file');
  assert.equal(await fs.readFile(path.join(callerDir, 'sentinel.txt'), 'utf8'), 'caller-owned', 'the caller directory survives close');
  await ext.emit('session_start', {}, ext.ctx);
  assert.ok(fsSync.existsSync(controlSocket), 'session switch re-runs session_start, which re-listens');

  await fs.unlink(controlSocket);
  await fs.writeFile(controlSocket, 'caller replaced the alias');
  await ext.emit('session_shutdown', {}, ext.ctx);
  assert.equal(await fs.readFile(controlSocket, 'utf8'), 'caller replaced the alias', 'a caller file that replaced our socket survives shutdown');
  assert.equal(await fs.readFile(path.join(callerDir, 'sentinel.txt'), 'utf8'), 'caller-owned', 'the caller directory survives shutdown');
  await fs.rm(callerDir, { recursive: true, force: true });

  const liveDir = trackPath(await fs.mkdtemp(path.join(tmpBase, 'orbit-live-')));
  await fs.chmod(liveDir, 0o700);
  const liveSocket = path.join(liveDir, 'control.sock');
  const liveServer = net.createServer(() => {});
  g9Closers.push(() => liveServer.close());
  await new Promise((resolve, reject) => { liveServer.once('error', reject); liveServer.listen(liveSocket, resolve); });
  process.env.ORBIT_CONTROL_SOCKET = liveSocket;
  const live = freshHarness([]);
  installOmpExtension(live.pi, live.sdk);
  g9Harnesses.push(live);
  await live.emit('session_start', {}, live.ctx);
  assert.match(live.notifications.at(-1)?.text || '', /occupied/, 'a live socket at the caller path is refused, not replaced');
  await probeConnect(liveSocket);
  liveServer.close();
  await fs.rm(liveDir, { recursive: true, force: true });

  const openDir = trackPath(await fs.mkdtemp(path.join(tmpBase, 'orbit-open-')));
  await fs.chmod(openDir, 0o755);
  process.env.ORBIT_CONTROL_SOCKET = path.join(openDir, 'control.sock');
  const open = freshHarness([]);
  installOmpExtension(open.pi, open.sdk);
  g9Harnesses.push(open);
  await open.emit('session_start', {}, open.ctx);
  assert.match(open.notifications.at(-1)?.text || '', /private/, 'a non-private parent directory is refused');
  assert.ok(!fsSync.existsSync(path.join(openDir, 'control.sock')), 'a refused path leaves no socket behind');
  await fs.rm(openDir, { recursive: true, force: true });

  const deadDir = trackPath(await fs.mkdtemp(path.join(tmpBase, 'orbit-dead-')));
  await fs.chmod(deadDir, 0o700);
  const deadSocket = path.join(deadDir, 'control.sock');
  const owner = spawn(process.execPath, ['-e', `require('node:net').createServer().listen(${JSON.stringify(deadSocket)})`]);
  g9Closers.push(() => { owner.kill('SIGKILL'); });
  for (let n = 0; n < 100 && !fsSync.existsSync(deadSocket); n++) await new Promise(resolve => setTimeout(resolve, 20));
  owner.kill('SIGKILL');
  await new Promise(resolve => owner.once('exit', resolve));
  assert.ok(fsSync.existsSync(deadSocket), 'a killed owner leaves a dead socket file behind');
  process.env.ORBIT_CONTROL_SOCKET = deadSocket;
  const dead = freshHarness([]);
  installOmpExtension(dead.pi, dead.sdk);
  g9Harnesses.push(dead);
  await dead.emit('session_start', {}, dead.ctx);
  await probeConnect(deadSocket);
  assert.equal(dead.notifications.length, 0, 'a proven-dead socket is replaced without an error');
  await dead.emit('session_shutdown', {}, dead.ctx);
  assert.ok(!fsSync.existsSync(deadSocket), 'shutdown removes the replaced socket');
  await fs.rm(deadDir, { recursive: true, force: true });

  console.log('omp_entry_recovery_test: all assertions passed');
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  delete process.env.ORBIT_EXTERNAL_INTEGRATION;
  delete process.env.ORBIT_CONTROL_SOCKET;
  // G9 block recovery, best effort and idempotent: stop live servers and child
  // processes, shut down any harness extension that reached a listening host
  // (session_shutdown closes the channel and recycles its own directory), then
  // remove the caller-owned directories. Individual mid-block rms above make
  // most entries no-ops; failed assertions must not leak any of them.
  for (const closer of g9Closers.splice(0)) { try { await closer(); } catch { /* best effort */ } }
  for (const harness of g9Harnesses.splice(0).reverse()) {
    try { await harness.emit('session_shutdown', {}, harness.ctx); } catch { /* best effort */ }
  }
  for (const dir of g9Paths.splice(0)) await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  await fs.rm(extProject, { recursive: true, force: true }).catch(() => {});
  await fs.rm(project, { recursive: true, force: true });
  await fs.rm(process.env.XDG_CONFIG_HOME, { recursive: true, force: true });
  await fs.rm(process.env.XDG_CACHE_HOME, { recursive: true, force: true });
  await fs.rm(process.env.ORBIT_SESSION_AGENT_ROOT, { recursive: true, force: true }).catch(() => {});
}

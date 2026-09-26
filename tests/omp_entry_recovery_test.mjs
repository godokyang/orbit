import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { z } from 'zod';
import { execSync, spawnSync } from 'node:child_process';
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

  // 1. The automatic entry fails on the REAL selector (no cached quality
  // evidence for glm/x). The recovery instruction must ride the CURRENT
  // request (the hook return value replaces the provider payload), and the
  // turn must NOT be aborted into the old trap.
  const first = await emit('before_provider_request', { payload: requestPayload() }, ctx);
  assert.ok(first && first.messages, 'hook must return a request payload');
  const instruction = lastBlockText(first);
  assert.match(instruction, /\[orbit-entry-failed\]/);
  assert.match(instruction, /没有创建任何 Orbit 任务/);
  assert.match(instruction, /glm\/x/, 'the verbatim selector reason must list the candidate');
  assert.match(instruction, /orbit model-evidence --file/);
  assert.match(instruction, /message_id="original"/);
  assert.match(instruction, /action=start/);
  assert.match(instruction, /already has an Orbit task/);
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

  // 3. Root follows the instruction: submit REAL sourced evidence through the
  // taskless CLI into the same cache the selector reads (no quality verdicts
  // are invented — facts with sources only).
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
  // real progress: no duplicate-task refusal (none was created), the cached
  // evidence is consumed, and the next gate (JEV) fails closed with its own
  // actionable reason instead of the bootstrap deadlock repeating.
  await assert.rejects(() => tool({ action: 'start', message_id: 'original' }), error => {
    assert.doesNotMatch(error.message, /already has an Orbit task/, 'no task existed, retry must not be refused');
    assert.doesNotMatch(error.message, /valid cached quality evidence/, 'the submitted evidence must be consumed');
    assert.match(error.message, /JEV quality judgment is unavailable/, 'next gate fails closed with its real reason');
    return true;
  });
  assert.deepEqual(await taskDirectories(), [], 'still no TaskRecord: no duplicate task');

  // 4b. The real failing provider shape end-to-end: a NEW message whose
  // automatic entry fails (JEV gate now) on an openai-codex Responses body
  // gets the recovery instruction injected into `input` — no abort, no
  // aside, exactly like the messages-array transports.
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
    assert.equal(out.messages.length, 2);
    assert.deepEqual(out.messages.at(-1), { role: 'user', content: 'X' }, 'new string user turn after assistant');

    const assistantToolText = { messages: [{ role: 'assistant', content: [{ type: 'text', text: 'done' }] }] };
    out = appendInstructionToPayload(assistantToolText, 'X');
    assert.equal(out.messages.length, 1);
    assert.deepEqual(out.messages[0].content.at(-1), { type: 'text', text: 'X' }, 'typed block after assistant text');

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

  console.log('omp_entry_recovery_test: all assertions passed');
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  await fs.rm(project, { recursive: true, force: true });
  await fs.rm(process.env.XDG_CONFIG_HOME, { recursive: true, force: true });
  await fs.rm(process.env.XDG_CACHE_HOME, { recursive: true, force: true });
  await fs.rm(process.env.ORBIT_SESSION_AGENT_ROOT, { recursive: true, force: true }).catch(() => {});
}

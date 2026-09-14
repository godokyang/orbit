import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { OrbitPlugin } from '../plugins/opencode.mjs';

// Exercise the installed-plugin contract through the real CLI/runtime and Ruby
// connection. Native SDK responses are doubles; real model acceptance is separate.
const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-opencode-test-')));
const selection = { providerID: 'authorized', modelID: 'execution-model' };
const histories = new Map([['root', [{ info: { id: 'original', role: 'user', model: selection, variant: 'high', agent: 'restricted-project-agent' },
  parts: [{ type: 'text', text: 'Implement the original multi-step requirement.' }] }]]]);
const sessions = new Map([['root', { id: 'root', directory: project, permission: [{ permission: 'edit', pattern: '*', action: 'deny' }] }]]);
const statuses = { root: { type: 'busy' } }, prompts = [], aborted = [];
let plugin, seq = 0, started;
const waitFor = async test => {
  for (let n = 0; n < 100; n++) { if (await test()) return; await new Promise(r => setTimeout(r, 100)); }
  throw new Error('Timed out waiting for native/Orbit state');
};
const client = { session: {
  get: async ({ path: { id } }) => ({ data: sessions.get(id) }),
  messages: async ({ path: { id } }) => ({ data: histories.get(id) }),
  status: async () => ({ data: { ...statuses } }),
  create: async ({ body }) => {
    const id = `member-${++seq}`;
    sessions.set(id, { ...body, id, directory: project }); histories.set(id, []);
    return { data: sessions.get(id) };
  },
  promptAsync: async ({ path: { id }, body }) => {
    prompts.push({ id, body });
    histories.get(id).push({ info: { id: `native-${++seq}`, role: 'user', model: body.model, variant: body.variant, agent: body.agent }, parts: body.parts });
    statuses[id] = { type: 'busy' };
    return { data: undefined };
  },
  abort: async ({ path: { id } }) => {
    aborted.push(id); delete statuses[id];
    await plugin.event({ event: { type: 'session.error', properties: { sessionID: id, error: { name: 'MessageAbortedError' } } } });
    return { data: true };
  }
} };
const tool = async args => JSON.parse(await plugin.tool.orbit.execute(args, { sessionID: 'root' }));
const state = async () => JSON.parse(await fs.readFile(path.join(started.task_directory, 'state.json'), 'utf8'));
const ruby = source => new Promise((resolve, reject) => {
  const child = spawn('ruby', ['--disable-gems', '-Ilib', '-rorbit/opencode_connection', '-e', source, started.task_directory]);
  let out = '', err = '';
  child.stdout.on('data', b => out += b); child.stderr.on('data', b => err += b);
  child.on('error', reject); child.on('close', code => code ? reject(new Error(err || out)) : resolve(out));
});
try {
  plugin = await OrbitPlugin({ client, directory: project });
  const context = await tool({ action: 'context' });
  assert.equal(context.thread_id, 'root'); assert.equal(context.project, project);
  started = await tool({ action: 'start', review_model: 'unused-check-model', check_in: 3600 });
  await waitFor(async () => (await state()).status === 'running');
  assert.equal((await tool({ action: 'start' })).task_directory, started.task_directory);
  assert.equal((await state()).instruction_source.kind, 'opencode_user_message');
  await ruby(`
    record = JSON.parse(File.read(File.join(ARGV[0], 'state.json')))
    connection = Orbit::OpenCodeConnection.new(socket: record.dig('connection','socket'), thread_id: 'root').connect!
    raise 'original lost' unless connection.user_message['text'] == 'Implement the original multi-step requirement.'
    sent = connection.send_message('Orbit correction, not a new user requirement.')
    messages = connection.user_messages(after_id: 'original')
    raise 'native metadata marker lost' unless messages.last['id'] == sent['id'] && messages.last['internal']
    raise 'model changed' unless connection.configured_model == 'authorized/execution-model'
    begin
      Orbit::OpenCodeConnection.new(socket: record.dig('connection','socket'), thread_id: 'foreign').connect!
      raise 'foreign session accepted'
    rescue Orbit::Connection::Error => error
      raise unless error.message.include?('has not called Orbit')
    end
  `);
  assert.deepEqual(prompts[0].body.model, selection); assert.equal(prompts[0].body.variant, 'high');
  await tool({ action: 'delegate', task: started.task_directory, text: 'Verify only; no modifications.' });
  await waitFor(async () => (await state()).members[0]?.status === 'working');
  const member = (await state()).members[0];
  assert.equal(member.model, 'authorized/execution-model');
  assert.equal(sessions.get(member.thread_id).model.variant, 'high');
  assert.equal(sessions.get(member.thread_id).agent, 'restricted-project-agent');
  assert.equal(prompts.find(p => p.id === member.thread_id).body.agent, 'restricted-project-agent');
  assert.deepEqual(sessions.get(member.thread_id).permission, [
    { permission: 'edit', pattern: '*', action: 'deny' },
    { permission: 'task', pattern: '*', action: 'deny' }, { permission: 'orbit', pattern: '*', action: 'deny' }
  ]);
  assert(prompts.find(p => p.id === member.thread_id).body.parts[0].text.includes('Implement the original multi-step requirement.'));
  await assert.rejects(plugin.tool.orbit.execute({ action: 'context' }, { sessionID: member.thread_id }), /must report to Root/);
  // A real user amendment must be saved and forwarded; internal messages must not.
  histories.get('root').push({ info: { id: 'amendment', role: 'user', model: selection }, parts: [{ type: 'text', text: 'Keep output concise.' }] });
  await waitFor(async () => (await state()).amendments.length === 1);
  assert.equal((await state()).amendments[0].source.kind, 'opencode_user_message');
  assert(prompts.some(p => p.id === member.thread_id && p.body.parts[0].text.includes('Keep output concise.')));
  // A quick continuation can already be busy when Orbit observes the abort.
  // The task-level interruption still has to stop every owned execution.
  await plugin.event({ event: { type: 'session.error', properties: { sessionID: 'root', error: { name: 'MessageAbortedError' } } } });
  await waitFor(async () => (await state()).status === 'paused');
  assert(aborted.includes('root')); assert(aborted.includes(member.thread_id)); assert.equal((await state()).checks.length, 0);
  await waitFor(async () => !(await state()).runtime_pid);
  console.log('OPENCODE_TEST_PASS original, ownership, native model, amendments, delegate and interruption');
} finally {
  if (plugin) await plugin.dispose();
  await fs.rm(project, { recursive: true, force: true });
}

// ADR-009 2026-09-27 supplement: the session-remembered checker model.
// `start` with review_model + remember_review_model opts that model in for the
// rest of THIS OMP host process; later starts without a model reuse it, a
// one-off explicit model never changes it, forget-review-model clears it, a
// failing remembered start explains both recovery paths, and a fresh host
// process inherits nothing. The CLI side is a shim so the test asserts the
// exact `--review-model` argument handoff (every reuse is a fresh explicit
// selection, re-validated and re-probed by the Ruby side on every start).
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createOrbitHost } from '../plugins/host.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-pin-test-'));
await fs.mkdir(path.join(tmp, 'project'), { recursive: true });
const project = await fs.realpath(path.join(tmp, 'project'));

// run() spawns `${ORBIT_RUBY} --disable-gems <cli> ...`; the shim records the
// start arguments, can be told to fail like a probe failure, and writes the
// minimal terminal task record ownedTask() verifies on the next start.
const log = path.join(tmp, 'args.json');
await fs.writeFile(log, '[]');
const cli = path.join(tmp, 'cli.mjs');
await fs.writeFile(cli, `import fs from 'node:fs';
import path from 'node:path';
const argv = process.argv.slice(2).filter(a => a !== '--disable-gems');
const flag = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
const log = JSON.parse(fs.readFileSync('${log}', 'utf8'));
log.push({ command: argv[1], review_model: flag('--review-model') });
fs.writeFileSync('${log}', JSON.stringify(log));
if (process.env.PIN_FAIL === '1') {
  console.error('orbit: explicit review model zhipu/glm is unavailable (not resolvable in the isolated profile); choose another --review-model provider/id');
  process.exit(1);
}
const dir = path.join(flag('--project'), '.orbit', 'tasks', 't' + log.length);
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify({
  connection: { provider: 'omp', socket: flag('--socket'), thread_id: flag('--thread') },
  status: 'complete'
}));
console.log(JSON.stringify({ task_directory: dir, status: 'complete' }));
`);
const shim = path.join(tmp, 'ruby-shim.sh');
await fs.writeFile(shim, `#!/bin/sh\nexec node "${cli}" "$@"\n`);
fsSync.chmodSync(shim, 0o755);
process.env.ORBIT_RUBY = shim;

const dispatch = async req => (req.method === 'messages' ? [{ id: 'm1', text: 'do it' }] : { cwd: project });
const host = createOrbitHost({ provider: 'omp', project, dispatch, bind: async () => 'sess-1', reset: () => {} });
const call = async args => JSON.parse(await host.execute({ message_id: 'm1', ...args }, {}));

// Same OMP session: explicit model + opt-in, then a start with no model.
assert.equal((await call({ action: 'context' })).session_review_model, null,
  'a session starts with no remembered checker model');
let started = await call({ action: 'start', review_model: 'zhipu/glm-5.2', remember_review_model: true });
assert.equal(started.session_review_model, 'zhipu/glm-5.2', 'the opted-in model is reported on the start result');
started = await call({ action: 'start' });
assert.equal(started.remembered_review_model, true, 'the next start without a model reuses the remembered choice');

// A one-off explicit model is NOT remembered and does not disturb the pin.
started = await call({ action: 'start', review_model: 'kimi/k3' });
assert.equal(started.remembered_review_model, undefined, 'an explicit one-off is not marked remembered');
assert.equal(started.session_review_model, 'zhipu/glm-5.2', 'the remembered choice survives a one-off override');

// Clearing resets the session; the following start sends no model.
const cleared = await call({ action: 'forget-review-model' });
assert.deepEqual(cleared, { status: 'cleared', session_review_model: null, previously: 'zhipu/glm-5.2' });
started = await call({ action: 'start' });
assert.equal(started.remembered_review_model, undefined, 'nothing is injected after the clear');
assert.equal((await call({ action: 'context' })).session_review_model, null);

// A failing remembered start keeps the pin and names both recovery paths.
await call({ action: 'start', review_model: 'zhipu/glm', remember_review_model: true });
process.env.PIN_FAIL = '1';
await assert.rejects(() => host.execute({ action: 'start', message_id: 'm1' }, {}),
  /remembered for this OMP session.*forget-review-model/s,
  'a reused model that fails re-validation explains the one-off and the clear');
delete process.env.PIN_FAIL;

// remember_review_model without a model is refused before any CLI call.
await assert.rejects(() => host.execute({ action: 'start', remember_review_model: true, message_id: 'm1' }, {}),
  /remember_review_model requires review_model/);

// Every reuse is a fresh explicit --review-model to the CLI: pin, pin, one-off,
// none after clear, pin, failing pin.
const passed = JSON.parse(await fs.readFile(log, 'utf8'));
assert.deepEqual(passed.map(e => e.review_model),
  ['zhipu/glm-5.2', 'zhipu/glm-5.2', 'kimi/k3', undefined, 'zhipu/glm', 'zhipu/glm'],
  'the CLI receives exactly the intended explicit selections');

// The pre-start hook may have started the task before Root can opt in.
// Returning the existing task must not silently discard that opt-in.
const prestarted = createOrbitHost({ provider: 'omp', project, dispatch, bind: async () => 'sess-prestarted', reset: () => {} });
const prestart = async args => JSON.parse(await prestarted.execute({ action: 'start', message_id: 'm1', ...args }, {}));
const active = await prestart({});
const activeFile = path.join(active.task_directory, 'state.json');
const activeState = JSON.parse(await fs.readFile(activeFile, 'utf8'));
activeState.status = 'active';
activeState.review = { model: 'zhipu/glm-5.2' };
await fs.writeFile(activeFile, JSON.stringify(activeState));
await assert.rejects(() => prestart({ review_model: 'kimi/k3', remember_review_model: true }),
  /already active with checker zhipu\/glm-5\.2/);
assert.equal((await prestart({ review_model: 'zhipu/glm-5.2', remember_review_model: true })).session_review_model,
  'zhipu/glm-5.2', 'an explicit opt-in pins the model of the pre-started task');
activeState.status = 'complete';
await fs.writeFile(activeFile, JSON.stringify(activeState));
assert.equal((await prestart({})).remembered_review_model, true,
  'a subsequent task inherits the model pinned after pre-start');
assert.equal(JSON.parse(await fs.readFile(log, 'utf8')).at(-1).review_model, 'zhipu/glm-5.2');

// A new host process (another OMP session) inherits nothing.
const fresh = createOrbitHost({ provider: 'omp', project, dispatch, bind: async () => 'sess-1', reset: () => {} });
assert.equal(JSON.parse(await fresh.execute({ action: 'context' }, {})).session_review_model, null,
  'the remembered model never crosses host processes');

fs.rm(tmp, { recursive: true, force: true });
console.log('PASS host review model pin');

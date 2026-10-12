import assert from 'node:assert/strict';
import { installModelAuthorization, parseAllowedModels } from '../plugins/model-authorization.mjs';

// Counters sit at the credential and provider boundaries: rejected requests
// cannot touch either, including cached resolvers and native child sessions.
const allowed = { provider: 'minimax', id: 'model' };
const foreign = { provider: 'other', id: 'model' };
let credentials = 0, requests = 0;
const registry = { getApiKey() { credentials++; return 'fixture'; }, resolver() { return () => { credentials++; return 'fixture'; }; } };
let policy = ['minimax/model'];
const root = { sessionId: 'root', model: allowed, modelRegistry: registry,
  setModel(model) { this.model = model; },
  cycleModel() { this.model = foreign; },
  agent: { streamFn() { requests++; return 'stream'; } } };
installModelAuthorization(root, () => policy, { main: true });
assert.throws(() => root.setModel(foreign), /outside/);
assert.throws(() => root.cycleModel(), /exact authorized/);
assert.deepEqual(root.model, allowed);
assert.throws(() => root.agent.streamFn(foreign), /outside the task authorization/);
assert.throws(() => registry.resolver(foreign, 'root'), /outside the task authorization/);
assert.throws(() => registry.resolver('other', { sessionId: 'root' }), /outside/);
await assert.rejects(() => registry.getApiKey(foreign, 'auxiliary-session'), /outside/);
assert.equal(credentials, 0);
assert.equal(requests, 0);
assert.equal(root.agent.streamFn(allowed), 'stream');
registry.resolver(allowed, 'root')();
assert.equal(requests, 1);
assert.equal(credentials, 1);
const cached = registry.resolver(allowed, 'root');
policy = ['other/model'];
assert.throws(() => cached(), /outside/);
assert.equal(credentials, 1);
policy = ['minimax/model'];
const child = { sessionId: 'child', model: allowed, modelRegistry: registry,
  agent: { streamFn() { requests++; } } };
installModelAuthorization(child, () => policy);
assert.throws(() => child.agent.streamFn(foreign), /outside/);
assert.throws(() => registry.resolver(foreign, 'child'), /outside/);
assert.throws(() => registry.resolver(foreign, 'auxiliary-session'), /outside/);
assert.equal(requests, 1);
assert.equal(credentials, 1);
const ordinaryRegistry = { getApiKey() { return 'ordinary'; }, resolver() { return () => 'ordinary'; } };
const ordinary = { sessionId: 'ordinary', model: foreign, modelRegistry: ordinaryRegistry,
  agent: { streamFn() { return 'ordinary'; } } };
installModelAuthorization(ordinary, () => null, { main: true });
assert.equal(ordinary.agent.streamFn(foreign), 'ordinary');
assert.equal(ordinaryRegistry.resolver(foreign, 'ordinary')(), 'ordinary');
assert.throws(() => installModelAuthorization({}, () => policy), /requires Agent/);
for (const invalid of [[], ['alias'], ['p/m', 'p/m'], 'p/m']) assert.throws(() => parseAllowedModels(invalid));
console.log('MODEL_AUTHORIZATION_TEST_PASS provider and credential calls stay inside the current task authorization');

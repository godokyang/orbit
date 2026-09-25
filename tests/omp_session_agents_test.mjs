// ADR-009 session agent naming: readable slug + stable short hash. Distinct
// identifiers that collide after non-alphanumeric folding must never share an
// agent name, or the session mapping would dispatch the wrong pinned model.
import { agentNameFor, AGENT_NAME_PREFIX } from '../plugins/omp-host.mjs';

const assert = (condition, message) => { if (!condition) { console.error(`ASSERTION FAILED: ${message}`); process.exit(1); } };

const dotted = agentNameFor('provider/a.b');
const dashed = agentNameFor('provider/a-b');
assert(dotted !== dashed, `colliding identifiers must map to distinct agent names: ${dotted} vs ${dashed}`);
assert(dotted.startsWith(AGENT_NAME_PREFIX) && dashed.startsWith(AGENT_NAME_PREFIX), 'names must use the generated namespace');
assert(agentNameFor('zenmux/x-ai/grok-4.7').startsWith(AGENT_NAME_PREFIX), 'slashed model ids must be nameable');
assert(agentNameFor('provider/a.b') === dotted, 'naming must be stable for a given identifier');
assert(!dotted.includes('.'), 'folded names must not retain raw punctuation');

console.log('omp_session_agents_test: PASS');

// Guard the public Agent stream and ModelRegistry resolver, not extension
// hooks: OMP catches hook failures, which cannot enforce authorization.
const registries = new WeakMap();
const agents = new WeakMap();

export function parseAllowedModels(value) {
  if (value == null) return null;
  if (!Array.isArray(value) || value.length < 1 || value.length > 64 ||
      value.some(model => typeof model !== 'string' || !/^[^\s/]+\/[^\s]+$/.test(model)) ||
      new Set(value).size !== value.length)
    throw new Error('allowed models must be 1-64 unique exact provider/model identities');
  return value;
}

export function sessionAllowedModels() {
  const value = process.env.ORBIT_ALLOWED_MODELS;
  if (value === undefined) return null;
  const allowed = parseAllowedModels(JSON.parse(value));
  if (!allowed) throw new Error('ORBIT_ALLOWED_MODELS must be a nonempty JSON array');
  return allowed;
}

export function requireAllowedModel(model, allowed) {
  allowed = parseAllowedModels(allowed);
  const id = typeof model === 'object' && model ? `${model.provider}/${model.id}` : model;
  if (allowed && !allowed.includes(id)) throw new Error(`model ${id ?? 'unknown'} is outside the task authorization`);
}

export function installModelAuthorization(session, getAllowed, { main = false } = {}) {
  const allowed = getAllowed(); // Invalid policy fails closed before binding.
  const agent = session?.agent;
  const registry = session?.modelRegistry;
  if (!agent || typeof agent.streamFn !== 'function' || !registry || typeof registry.resolver !== 'function' || typeof registry.getApiKey !== 'function') {
    if (allowed) throw new Error('OMP model authorization requires Agent.streamFn and ModelRegistry.resolver/getApiKey');
    return false;
  }
  if (!agents.has(agent)) {
    const original = agent.streamFn;
    const guard = { getAllowed };
    agent.streamFn = function(model, ...args) {
      requireAllowedModel(model, guard.getAllowed());
      return original.call(this, model, ...args);
    };
    for (const name of ['setModel', 'setModelTemporary']) {
      if (typeof session[name] !== 'function') continue;
      const select = session[name];
      session[name] = function(model, ...args) {
        requireAllowedModel(model, guard.getAllowed());
        return select.call(this, model, ...args);
      };
    }
    if (typeof session.cycleModel === 'function') {
      const cycle = session.cycleModel;
      session.cycleModel = function(...args) {
        if (guard.getAllowed()) throw new Error('strict model authorization requires an exact authorized model selection');
        return cycle.call(this, ...args);
      };
    }
    agents.set(agent, guard);
  } else agents.get(agent).getAllowed = getAllowed;
  let guard = registries.get(registry);
  if (!guard) {
    guard = { sessions: new Map(), fallback: sessionAllowedModels };
    const getApiKey = registry.getApiKey;
    registry.getApiKey = async function(model, id, ...args) {
      const policy = () => (guard.sessions.get(id) ?? guard.fallback)();
      requireAllowedModel(model, policy());
      const key = await getApiKey.call(this, model, id, ...args);
      requireAllowedModel(model, policy());
      return key;
    };
    const original = registry.resolver;
    registry.resolver = function(model, options) {
      const id = typeof options === 'string' ? options : options?.sessionId;
      const policy = () => (guard.sessions.get(id) ?? guard.fallback)();
      const exact = typeof model === 'string' ? (options?.modelId ? `${model}/${options.modelId}` : null) : model;
      requireAllowedModel(exact, policy());
      const resolve = original.call(this, model, options);
      // A resolver can be cached before a task begins or narrows its policy.
      return (...args) => { requireAllowedModel(exact, policy()); return resolve(...args); };
    };
    registries.set(registry, guard);
  }
  guard.sessions.set(session.sessionId, getAllowed);
  if (main) guard.fallback = getAllowed;
  requireAllowedModel(session.model, allowed);
  return true;
}

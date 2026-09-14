import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { createOrbitHost, toolArgs, toolDescription } from './host.mjs';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const textOf = content => typeof content === 'string' ? content : (content || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
const codingTools = new Set(['read', 'write', 'edit', 'grep', 'glob', 'bash', 'python', 'lsp']);

// The SDK is supplied by OMP itself, including in its standalone binary.
export function installOmpExtension(pi, sdk) {
  const entries = new Map();
  let host, currentContext;

  function remember(session, { root, dispose } = {}) {
    const id = session.sessionId;
    if (entries.has(id)) return entries.get(id);
    const entry = { id, session, root, dispose, activeTools: new Set(), pending: 0, interrupted: false };
    entry.unsubscribe = session.subscribe(event => {
      if (event.type === 'tool_execution_start') entry.activeTools.add(event.toolCallId);
      if (event.type === 'tool_execution_end') entry.activeTools.delete(event.toolCallId);
      if (event.type === 'message_end' && event.message.role === 'assistant' && sdk.isUserInterruptAbort(event.message)) entry.interrupted = true;
    });
    entries.set(id, entry);
    return entry;
  }
  function rootFor(ctx) {
    const id = ctx.sessionManager.getSessionId();
    if (entries.get(id)?.root) throw new Error('Execution members must report to Root, not start Orbit');
    const ref = sdk.AgentRegistry.global().list().find(r => r.session?.sessionId === id);
    if (!ref?.session) throw new Error('OMP has not registered this native session');
    currentContext = ctx;
    return remember(ref.session);
  }
  function owned(id) {
    const entry = entries.get(id);
    if (!entry || entry.session.sessionId !== id) throw new Error('Session is not owned by this Orbit host');
    return entry;
  }
  function messages(entry) {
    return entry.session.sessionManager.getBranch().flatMap(item => {
      if (item.type === 'message' && item.message.role === 'user')
        return [{ id: item.id, item_id: item.id, text: textOf(item.message.content), internal: false }];
      if (item.type === 'custom_message' && item.customType === 'orbit')
        return [{ id: item.details?.orbitMessage || item.id, item_id: item.id, text: textOf(item.content), internal: true }];
      return [];
    }).filter(m => m.text.trim());
  }
  function state(entry) {
    const session = entry.session;
    const branch = session.sessionManager.getBranch();
    const last = branch.filter(e => e.type === 'message' && e.message.role === 'assistant').at(-1);
    const busy = session.isStreaming || session.isCompacting || session.isBashRunning || session.isEvalRunning || session.hasPendingAsyncWork() || entry.pending > 0;
    const message = last?.message;
    const observations = last ? [{ kind: 'agent_message', text: textOf(message.content) }, ...branch.slice(branch.indexOf(last) + 1)
      .filter(e => e.type === 'message' && e.message.role === 'toolResult').map(e => ({ kind: 'command', tool: e.message.toolName,
        status: e.message.isError ? 'failed' : 'completed', aggregated_output: textOf(e.message.content).slice(0, 2000) }))] : [];
    return { thread_id: entry.id, cwd: session.sessionManager.getCwd(), status: busy ? 'active' : 'idle', interrupted: entry.interrupted,
      turn_id: busy ? last?.id : null, last_turn_id: last?.id || (entry.error ? 'delivery-error' : null),
      last_turn_status: entry.interrupted ? 'interrupted' : busy ? 'inProgress' : entry.error || ['error', 'aborted'].includes(message?.stopReason) ? 'failed' : last ? 'completed' : null,
      observations: entry.error ? [...observations, { kind: 'error', text: entry.error }] : observations,
      active_tools: entry.activeTools.size, async_jobs: session.getAsyncJobSnapshot() };
  }
  function send(entry, text) {
    const marker = randomUUID();
    entry.pending++;
    entry.error = null;
    if (entry.root) entry.interrupted = false;
    entry.session.sendCustomMessage({ customType: 'orbit', content: text, display: true, details: { orbitMessage: marker } },
      { triggerTurn: true, deliverAs: 'steer' }).catch(error => { entry.error = error.message; }).finally(() => { entry.pending--; });
    return { id: marker, action: 'native_custom_message' };
  }
  async function stop(entry) {
    const session = entry.session;
    const manager = session.asyncJobManager, owner = session.getAgentId();
    if (!owner) throw new Error('OMP session has no native async-work owner');
    if (manager) manager.cancelAll({ ownerId: owner });
    if (state(entry).status !== 'idle' || entry.activeTools.size) await session.abort({ goalReason: 'internal' });
    // Cancellation labels precede process exit. Reap actual native job promises.
    if (manager && !(await manager.cancelAndReapOwnerJobs(owner, Date.now() + 5000)).settled)
      throw new Error(`OMP background processes did not settle for ${entry.id}`);
    for (let n = 0; n < 50; n++) {
      const after = state(entry);
      if (after.status === 'idle' && after.active_tools === 0) return { confirmed: true, thread_id: entry.id,
        scope: 'Native session execution, attached shell processes and owner-scoped async jobs; no unmanaged detached work',
        native_owner: owner, status_after: after.status, active_tools_after: 0, async_jobs_settled: true };
      await pause(100);
    }
    throw new Error(`OMP execution did not stop for ${entry.id}`);
  }
  async function dispatch(request) {
    const entry = owned(request.session);
    switch (request.method) {
      case 'state': return state(entry);
      case 'messages': return messages(entry);
      case 'model': return `${entry.session.model.provider}/${entry.session.model.id}`;
      case 'send': return send(entry, request.text);
      case 'stop': return stop(entry);
      case 'create_member': {
        if (entry.root) throw new Error('Execution members cannot create a team');
        const model = currentContext.models.list().find(m => `${m.provider}/${m.id}` === request.model);
        if (!model) throw new Error('Requested member model is not available in the current OMP session');
        const native = entry.session, cwd = native.sessionManager.getCwd();
        const settings = await native.settings.cloneForCwd(cwd);
        const agentId = `orbit-${randomUUID()}`;
        const result = await sdk.createAgentSession({ cwd, agentDir: native.settings.getAgentDir(), settings,
          authStorage: native.modelRegistry.authStorage, modelRegistry: native.modelRegistry, model, thinkingLevel: native.thinkingLevel,
          parentTaskPrefix: agentId, agentId, parentAgentId: native.getAgentId(), agentDisplayName: 'Orbit execution member',
          toolNames: native.getActiveToolNames().filter(name => codingTools.has(name)), restrictToolNames: true,
          disableExtensionDiscovery: true, hasUI: currentContext.hasUI, interactiveMode: false,
          sessionManager: sdk.SessionManager.create(cwd, sdk.SessionManager.getDefaultSessionDir(cwd, native.settings.getAgentDir())) });
        result.setToolUIContext(currentContext.ui, currentContext.hasUI);
        const child = remember(result.session, { root: entry.id, dispose: () => result.session.dispose() });
        return child.id;
      }
      case 'start_member': {
        const member = owned(request.member);
        if (member.root !== entry.id) throw new Error('Member is not owned by this Root');
        send(member, request.text);
        return true;
      }
      default: throw new Error('Unknown Orbit connection operation');
    }
  }
  async function connect(ctx) {
    const entry = rootFor(ctx);
    if (!host) host = createOrbitHost({ provider: 'omp', project: await fs.realpath(ctx.cwd), dispatch,
      bind: context => rootFor(context).id, reset: id => { owned(id).interrupted = false; } });
    return entry;
  }
  async function close(requireConfirmation = false) {
    if (host) { await host.close({ requireConfirmation }); host = undefined; }
    for (const entry of entries.values()) {
      entry.unsubscribe();
      if (entry.dispose) await entry.dispose();
    }
    entries.clear();
  }
  pi.registerTool({ name: 'orbit', label: 'Orbit', description: toolDescription, parameters: pi.zod.object(toolArgs(pi.zod)),
    async execute(_id, args, _signal, _update, ctx) {
      await connect(ctx);
      return { content: [{ type: 'text', text: await host.execute(args, ctx) }], details: {} };
    }
  });
  pi.on('session_start', (_event, ctx) => { rootFor(ctx); });
  pi.on('session_shutdown', () => close());
  for (const event of ['session_before_switch', 'session_before_branch', 'session_before_tree']) pi.on(event, async () => {
    try { await close(true); }
    catch (error) { currentContext?.ui.notify(error.message, 'error'); return { cancel: true }; }
  });
}

import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { createOrbitHost, toolArgs, toolDescription } from './host.mjs';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

// Only the official plugin owns a native client for a default, portless TUI.
// This socket is scoped to this plugin instance; it is not an OpenCode server.
export const OrbitPlugin = async ({ client, directory }) => {
  const project = await fs.realpath(directory);
  const allowed = new Set(), members = new Map(), cancelled = new Set();

  async function native(method, options = {}) {
    const response = await client.session[method](options);
    if (response.error) throw new Error(`OpenCode ${method}: ${JSON.stringify(response.error)}`);
    return response.data;
  }
  const history = id => native('messages', { path: { id } });
  async function session(id) {
    if (!allowed.has(id)) throw new Error('Session has not called Orbit on this host');
    const info = await native('get', { path: { id } });
    if (await fs.realpath(info.directory) !== project) throw new Error('Session belongs to another project');
    return info;
  }
  function userMessages(messages) {
    return messages.filter(m => m.info.role === 'user').map(m => {
      const parts = m.parts.filter(p => p.type === 'text');
      const sent = parts.find(p => p.metadata?.orbitMessage)?.metadata.orbitMessage;
      return { id: sent || m.info.id, item_id: m.info.id, text: parts.map(p => p.text).join('\n'),
        internal: !!sent || (parts.length > 0 && parts.every(p => p.synthetic)) };
    }).filter(m => m.text.length > 0);
  }
  async function model(id) {
    const info = await session(id);
    const users = (await history(id)).filter(m => m.info.role === 'user');
    const current = users.at(-1)?.info;
    const selected = current?.model || (info.model && { providerID: info.model.providerID, modelID: info.model.id });
    if (!selected?.providerID || !selected?.modelID) throw new Error('Current session has no native model selection');
    return { model: selected, variant: current?.variant ?? info.model?.variant, agent: current?.agent || info.agent || 'build' };
  }
  async function state(id) {
    const info = await session(id), messages = await history(id);
    const statuses = await native('status');
    const assistants = messages.filter(m => m.info.role === 'assistant');
    const last = assistants.at(-1);
    const active = statuses[id] && statuses[id].type !== 'idle';
    const errored = last?.info.error;
    const status = active ? 'active' : 'idle';
    const observations = (last?.parts || []).flatMap(p => {
      if (p.type === 'text') return [{ kind: 'agent_message', text: p.text }];
      if (p.type !== 'tool') return [];
      return [{ kind: 'command', tool: p.tool, status: p.state.status,
        command: p.state.input?.command, exit_code: p.state.metadata?.exit,
        aggregated_output: String(p.state.output || p.state.error || '').slice(0, 2000) }];
    });
    return { thread_id: id, cwd: info.directory, status, interrupted: cancelled.has(id), status_detail: statuses[id] || { type: 'idle' },
      turn_id: active ? last?.info.id : null, last_turn_id: last?.info.id || null,
      last_turn_status: cancelled.has(id) ? 'interrupted' : active ? 'inProgress' : errored ? 'failed' : last?.info.time.completed ? 'completed' : null,
      observations, active_tools: messages.flatMap(m => m.parts).filter(p => p.type === 'tool' && ['pending', 'running'].includes(p.state.status)).length };
  }
  async function send(id, text) {
    if (members.has(id)) cancelled.delete(id);
    const selection = await model(id);
    const marker = randomUUID();
    // Preserve provider/model and variant from the native session, never the
    // review configuration. Native-generated IDs retain native history order.
    await native('promptAsync', { path: { id }, body: { ...selection,
      parts: [{ type: 'text', text, metadata: { orbitMessage: marker } }] } });
    return { id: marker, action: 'native_prompt' };
  }
  async function stop(id) {
    await session(id);
    const before = await state(id);
    if (before.status !== 'idle' || before.active_tools) await native('abort', { path: { id } });
    for (let attempt = 0; attempt < 40; attempt++) {
      const after = await state(id);
      if (after.status === 'idle' && after.active_tools === 0) return { confirmed: true, thread_id: id,
        scope: 'Native session execution and its attached shell process trees; no unmanaged detached work',
        status_after: after.status, active_tools_after: after.active_tools };
      await pause(100);
    }
    throw new Error(`OpenCode did not confirm execution stopped for ${id}`);
  }
  async function dispatch(request) {
    const id = request.session;
    await session(id);
    switch (request.method) {
      case 'state': return state(id);
      case 'messages': return userMessages(await history(id));
      case 'model': { const selected = await model(id); return `${selected.model.providerID}/${selected.model.modelID}`; }
      case 'send': return send(id, request.text);
      case 'stop': return stop(id);
      case 'create_member': {
        if (members.has(id)) throw new Error('Execution members cannot create a team');
        const root = await session(id), selected = await model(id);
        const slash = request.model.indexOf('/');
        if (slash < 1) throw new Error('OpenCode member model must be provider/model');
        const memberModel = { providerID: request.model.slice(0, slash), id: request.model.slice(slash + 1) };
        if (`${selected.model.providerID}/${selected.model.modelID}` === request.model && selected.variant) memberModel.variant = selected.variant;
        const member = await native('create', { body: { parentID: id, title: 'Orbit execution member', model: memberModel, agent: selected.agent,
          permission: [...(root.permission || []), { permission: 'task', pattern: '*', action: 'deny' }, { permission: 'orbit', pattern: '*', action: 'deny' }] } });
        allowed.add(member.id);
        members.set(member.id, { root: id, model: memberModel, agent: selected.agent });
        return member.id;
      }
      case 'start_member': {
        const member = members.get(request.member);
        if (member?.root !== id) throw new Error('Member is not owned by this Root');
        cancelled.delete(request.member);
        await native('promptAsync', { path: { id: request.member }, body: {
          model: { providerID: member.model.providerID, modelID: member.model.id }, variant: member.model.variant, agent: member.agent,
          parts: [{ type: 'text', text: request.text, metadata: { orbitMessage: randomUUID() } }] } });
        return true;
      }
      default: throw new Error('Unknown Orbit connection operation');
    }
  }
  const host = createOrbitHost({ provider: 'opencode', project, dispatch, reset: id => cancelled.delete(id),
    async bind(context) {
      if (members.has(context.sessionID)) throw new Error('Execution members must report to Root, not start Orbit');
      allowed.add(context.sessionID);
      await session(context.sessionID);
      return context.sessionID;
    }
  });
  return {
    tool: { orbit: { description: toolDescription, args: toolArgs(z), execute: (args, context) => host.execute(args, context) } },
    async event({ event }) {
      if (event.type === 'session.error' && event.properties.error?.name === 'MessageAbortedError') cancelled.add(event.properties.sessionID);
    },
    dispose: () => host.close()
  };
};

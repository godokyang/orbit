import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

const cli = fileURLToPath(new URL('../scripts/orbit', import.meta.url));
const terminal = new Set(['complete', 'paused', 'needs_user', 'failed', 'stop_unconfirmed']);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const guidance = 'Continue the authorized implementation. When your work is ready, report results and END YOUR TURN. Do not sleep or poll waiting for Orbit complete: the independent checker needs your turn to finish and will wake this same session if corrections are needed. Member results also return automatically.';

async function run(args, cwd, input = '') {
  return new Promise((resolve, reject) => {
    const child = spawn('ruby', ['--disable-gems', cli, ...args], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '';
    child.stdout.on('data', chunk => { out += chunk; });
    child.stderr.on('data', chunk => { err += chunk; });
    child.once('error', reject);
    child.once('close', code => {
      if (code !== 0) return reject(new Error(err || out || `Orbit exited ${code}`));
      try { resolve(JSON.parse(out)); } catch (error) { reject(error); }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
}

// Only the official plugin owns a native client for a default, portless TUI.
// This socket is scoped to this plugin instance; it is not an OpenCode server.
export const OrbitPlugin = async ({ client, directory }) => {
  const project = await fs.realpath(directory);
  const allowed = new Set(), members = new Map(), tasks = new Map(), cancelled = new Set();
  let host, socket, setup, closing = false;

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
  async function listen() {
    if (setup) return setup;
    setup = (async () => {
      // macOS Unix socket paths are short: os.tmpdir() can exceed the limit.
      const folder = await fs.mkdtemp(path.join(process.platform === 'darwin' ? '/tmp' : os.tmpdir(), 'orbit-opencode-'));
      await fs.chmod(folder, 0o700);
      socket = path.join(folder, 'control.sock');
      host = net.createServer(peer => {
        let data = '';
        peer.setEncoding('utf8');
        peer.on('error', () => {});
        peer.on('data', async chunk => {
          data += chunk;
          if (data.length > 4 * 1024 * 1024) return peer.destroy();
          if (!data.includes('\n')) return;
          peer.removeAllListeners('data');
          try { peer.end(JSON.stringify({ result: await dispatch(JSON.parse(data.split('\n')[0])) }) + '\n'); }
          catch (error) { peer.end(JSON.stringify({ error: error.message }) + '\n'); }
        });
      });
      await new Promise((resolve, reject) => { host.once('error', reject); host.listen(socket, resolve); });
      await fs.chmod(socket, 0o600);
      host.unref();
    })();
    return setup;
  }
  async function ownedTask(task, id) {
    const real = await fs.realpath(task);
    if (!real.startsWith(path.join(project, '.orbit', 'tasks') + path.sep)) throw new Error('Task is outside this project');
    const value = JSON.parse(await fs.readFile(path.join(real, 'state.json'), 'utf8'));
    if (value.connection.provider !== 'opencode' || value.connection.socket !== socket || value.connection.thread_id !== id)
      throw new Error('Task does not belong to the current Root on this host');
    return value;
  }
  return {
    tool: { orbit: {
      description: 'Start independent execution checks when implementing multi-step requirements, fixing cross-module issues or refactoring. Use the Orbit skill. context identifies this exact session; start saves the native original user instruction and named basis. Continue work after start; corrections and member results return here. Do not start for discussion or simple local edits. No Root is replaced.',
      args: {
        action: z.enum(['context', 'start', 'status', 'check', 'amend', 'dispute', 'stop', 'delegate']),
        task: z.string().optional(), basis: z.array(z.string()).optional(), message_id: z.string().optional(),
        review_model: z.string().optional(), model: z.string().optional(), member: z.string().optional(),
        text: z.string().optional(), check_in: z.number().int().positive().optional()
      },
      async execute(a, context) {
        if (closing) throw new Error('OpenCode host is closing');
        if (members.has(context.sessionID)) throw new Error('Execution members must report to Root, not start Orbit');
        allowed.add(context.sessionID);
        await session(context.sessionID);
        await listen();
        const id = context.sessionID;
        if (a.action === 'context') return JSON.stringify({ ready: true, provider: 'opencode', project, thread_id: id, task_directory: tasks.get(id)?.task_directory || null });
        if (a.action === 'start') {
          const previous = tasks.get(id);
          if (previous && !terminal.has((await ownedTask(previous.task_directory, id)).status)) return JSON.stringify(previous);
          cancelled.delete(id);
          const users = userMessages(await history(id)).filter(m => !m.internal);
          const original = a.message_id ? users.find(m => m.id === a.message_id || m.item_id === a.message_id) : users.at(-1);
          if (!original) throw new Error('No original native user message found');
          const args = ['start', '--provider', 'opencode', '--project', project, '--thread', id, '--socket', socket, '--message-id', original.id];
          if (a.review_model) args.push('--review-model', a.review_model);
          if (a.check_in) args.push('--check-in', String(a.check_in));
          for (const file of a.basis || []) args.push('--basis', path.resolve(project, file));
          const result = { ...await run(args, project), next_action: guidance };
          tasks.set(id, result);
          return JSON.stringify(result);
        }
        if (!a.task) throw new Error('Use task_directory returned by start');
        await ownedTask(a.task, id);
        const args = [a.action, a.task];
        if (['amend', 'delegate'].includes(a.action)) {
          if (!a.text?.trim()) throw new Error('Provide the original amendment or delegated scope');
          args.push('--file', '-');
          if (a.action === 'delegate' && a.model) args.push('--model', a.model);
          if (a.action === 'delegate' && a.member) args.push('--member', a.member);
        } else if (a.text) args.push('--reason', a.text);
        const result = await run(args, project, a.text);
        if (a.action === 'status' && !terminal.has(result.status)) result.next_action = guidance;
        return JSON.stringify(result);
      }
    } },
    async event({ event }) {
      if (event.type === 'session.error' && event.properties.error?.name === 'MessageAbortedError') cancelled.add(event.properties.sessionID);
    },
    async dispose() {
      closing = true;
      // Keep the bridge available while task processes stop their reviewers.
      for (const [id, task] of tasks) {
        try {
          const current = await ownedTask(task.task_directory, id);
          if (!terminal.has(current.status)) {
            process.kill(task.pid, 'SIGTERM');
            for (let n = 0; n < 60; n++) {
              if (terminal.has((await ownedTask(task.task_directory, id)).status)) break;
              await pause(100);
            }
          }
        } catch (error) { process.stderr.write(`Orbit shutdown: ${error.message}\n`); }
      }
      if (host) {
        host.close();
        await fs.rm(path.dirname(socket), { recursive: true, force: true });
      }
    }
  };
};

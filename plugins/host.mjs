import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

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

export const toolDescription = 'For authorized implementation that needs execution members, start Orbit BEFORE delegating, even for small changes. Also use for multi-step fixes/refactoring needing independent checks. Read the Orbit skill. context identifies this exact session; start preserves original user input and named basis. Continue working; member results and corrections return automatically. When ready, report results and end your turn; do not poll waiting for complete. Do not start for discussion or simple local edits. Root is never replaced.';
export const toolArgs = z => ({
        action: z.enum(['context', 'start', 'status', 'check', 'amend', 'dispute', 'stop', 'delegate']),
        task: z.string().optional(), basis: z.array(z.string()).optional(), message_id: z.string().optional(),
        review_model: z.string().optional(), model: z.string().optional(), member: z.string().optional(),
        text: z.string().optional(), check_in: z.number().int().positive().optional()
      });

// Shared transport and task operations for native plugin hosts. Each adapter
// supplies only its real session operations and native invocation identity.
export function createOrbitHost({ provider, project, dispatch, bind, reset }) {
  const tasks = new Map();
  let host, socket, setup, closing = false;
  async function listen() {
    if (setup) return setup;
    setup = (async () => {
      // macOS Unix socket paths are short: os.tmpdir() can exceed the limit.
      const folder = await fs.mkdtemp(path.join(process.platform === 'darwin' ? '/tmp' : os.tmpdir(), `orbit-${provider}-`));
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
    if (value.connection.provider !== provider || value.connection.socket !== socket || value.connection.thread_id !== id)
      throw new Error('Task does not belong to the current Root on this host');
    return value;
  }
  return {
      async execute(a, context) {
        if (closing) throw new Error('Agent host is closing');
        const id = await bind(context);
        await listen();
        if (a.action === 'context') return JSON.stringify({ ready: true, provider, project, thread_id: id, task_directory: tasks.get(id)?.task_directory || null });
        if (a.action === 'start') {
          const previous = tasks.get(id);
          if (previous && !terminal.has((await ownedTask(previous.task_directory, id)).status)) return JSON.stringify(previous);
          reset(id);
          const users = (await dispatch({ method: 'messages', session: id })).filter(m => !m.internal);
          const original = a.message_id ? users.find(m => m.id === a.message_id || m.item_id === a.message_id) : users.at(-1);
          if (!original) throw new Error('No original native user message found');
          const args = ['start', '--provider', provider, '--project', project, '--thread', id, '--socket', socket, '--message-id', original.id];
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
      },
    async close({ requireConfirmation = false } = {}) {
      closing = true;
      const failures = [];
      // Keep the bridge available while task processes stop their reviewers.
      for (const [id, task] of tasks) {
        try {
          let current = await ownedTask(task.task_directory, id);
          if (current.status === 'stop_unconfirmed' && requireConfirmation)
            await run(['stop', task.task_directory, '--reason', 'Native session switch'], project);
          if (!terminal.has(current.status)) {
            process.kill(task.pid, 'SIGTERM');
            for (let n = 0; n < 60; n++) {
              if (terminal.has((await ownedTask(task.task_directory, id)).status)) break;
              await pause(100);
            }
          }
          current = await ownedTask(task.task_directory, id);
          if (!terminal.has(current.status) || current.status === 'stop_unconfirmed') failures.push(`${task.task_directory}: ${current.status}`);
        } catch (error) { failures.push(error.message); process.stderr.write(`Orbit shutdown: ${error.message}\n`); }
      }
      if (requireConfirmation && failures.length) {
        closing = false;
        throw new Error(`Orbit could not confirm stop: ${failures.join('; ')}`);
      }
      if (host) {
        host.close();
        await fs.rm(path.dirname(socket), { recursive: true, force: true });
      }
    }
  };
}

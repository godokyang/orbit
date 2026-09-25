import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { holdReleaseLease } from './lease.mjs';

holdReleaseLease();

const cli = fileURLToPath(new URL('../scripts/orbit', import.meta.url));
const terminal = new Set(['complete', 'paused', 'needs_user', 'failed', 'stop_unconfirmed']);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const guidance = 'Continue the authorized implementation; do simple local edits yourself. When your work is ready, report results and END YOUR TURN — do not sleep or poll waiting for Orbit complete: the independent checker needs your turn to finish and will wake this same session if corrections are needed. If you requested a final check, end the turn and wait for the finalization_notice or corrections; do not stop the task just to deliver, unless the user explicitly asked to interrupt. Member results also return automatically. Later status/check/amend/dispute/stop calls must pass task: the task_directory returned by start; never write .orbit/inbox manually.';

async function run(args, cwd, input = '') {
  return new Promise((resolve, reject) => {
    // The installer pins the verified Ruby in ORBIT_RUBY; fall back to PATH
    // only for repository development runs.
    const ruby = process.env.ORBIT_RUBY || 'ruby';
    const child = spawn(ruby, ['--disable-gems', cli, ...args], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
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

export const toolDescription = 'Start Orbit only for work that benefits from independent checks: multi-step changes, real parallel work surfaces, or fixes needing objective review. Simple single-file or local edits: just do them yourself, without dispatching members. If the user explicitly asks to use Orbit, still start Orbit for those small tasks — but do the work yourself and let the checker verify; no members. context identifies this exact session; start preserves original user input and named basis and returns a task_directory. Keep that task_directory: for status/check/amend/dispute/stop pass it back as task: <task_directory returned by start> to this Orbit tool — never write .orbit/inbox manually. Root dispatches members only through the native task tool (one level) when there is a genuine independent work surface — Root decides; JEV only advises, never blocks. Continue working; member results and corrections return automatically. When your work is ready, report results and end your turn; if you requested a final check, end the turn and wait for the Orbit finalization_notice or corrections — do not stop the task just to deliver, do not poll. For a normal delivery after that notice, call stop with intent=complete (the default) and finish the turn normally: the Orbit completion gate adjudicates that intent, and when the current version has no valid finalization_notice it refuses with the required next action instead of quietly pausing the task. Reserve intent=pause for a user-requested interruption. An accepted stop is queued and completed after your turn, so the final summary is fully delivered. Do not start for discussion. Root is never replaced.';
export const toolArgs = z => ({
        action: z.enum(['context', 'start', 'status', 'check', 'amend', 'dispute', 'stop', 'review-model']),
        task: z.string().optional().describe('Required for status/check/amend/dispute/stop: the exact task_directory string returned by action=start. Never write .orbit/inbox manually.'),
        basis: z.array(z.string()).optional(), message_id: z.string().optional(),
        review_model: z.string().optional(),
        intent: z.enum(['complete', 'pause']).optional().describe('stop only. complete (default) is the deliberate post-finalization completion hand-off, adjudicated by the Ruby completion gate; pause is an explicit user interruption and takes the ordinary pause path.'),
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
        if (!a.task) throw new Error('This action needs the task: pass task: <task_directory returned by start> to the orbit tool (status/check/amend/dispute/stop/review-model all take it). Do NOT write .orbit/inbox manually.');
        if (a.action === 'review-model' && (typeof a.review_model !== 'string' || !a.review_model.trim()))
          throw new Error('review-model requires review_model: <provider/id> (Root reselection after a blocked check; never auto-retries or switches a check in flight)');
        await ownedTask(a.task, id);
        const args = [a.action, a.task];
        if (['status', 'stop'].includes(a.action)) args.push('--json');
        // Root-tool stop is a deliberate completion hand-off by default. An
        // explicit pause intent is a user interruption and must take the
        // ordinary pause path (no --complete), never the completion gate. The
        // plugin never adjudicates completion itself: the Ruby gate decides and
        // returns a structured result (exit 0), which run() passes through.
        if (a.action === 'stop' && a.intent !== 'pause') args.push('--complete');
        if (a.action === 'review-model') {
          args.push('--model', a.review_model.trim());
        }
        if (a.action === 'amend') {
          if (!a.text?.trim()) throw new Error('Provide the original amendment');
          args.push('--file', '-');
        } else if (a.text) args.push('--reason', a.text);
        const result = await run(args, project, a.text);
        if (a.action === 'status' && !terminal.has(result.status)) result.next_action = guidance;
        return JSON.stringify(result);
      },
    // Whether THIS process currently owns the durable record, using the same
    // (provider, socket, thread_id) test as ownedTask. After an OMP restart the
    // old record's socket is gone, so this is false: callers must not imply the
    // task is under control, and must not silently rebind it.
    async ownsTask(taskDir, id) {
      if (!socket) return false;
      try {
        const value = JSON.parse(await fs.readFile(path.join(await fs.realpath(taskDir), 'state.json'), 'utf8'));
        return value.connection?.provider === provider && value.connection?.socket === socket && value.connection?.thread_id === id;
      } catch { return false; }
    },
    async close({ requireConfirmation = false } = {}) {
      closing = true;
      const failures = [];
      // Keep the bridge available while task processes stop their reviewers.
      for (const [id, task] of tasks) {
        try {
          let current = await ownedTask(task.task_directory, id);
          if (current.status === 'stop_unconfirmed' && requireConfirmation)
            await run(['stop', task.task_directory, '--reason', 'Native session switch', '--json'], project);
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

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
const guidance = 'Continue the authorized implementation; do simple local edits yourself. Once the artifact is verified, call Orbit action=check with task: the task_directory returned by start to request the manual final check. Give the actual delivery result in your visible reply and END YOUR TURN. Orbit waits for that completed reply before starting the manual final check; automatic checks never issue a finalization_notice. Wait for that notice or corrections without sleeping or polling. On a valid notice call stop with intent=complete, then finish your reply; do not stop merely to deliver unless the user explicitly asked to interrupt. Member results return automatically. Later status/check/amend/dispute/stop calls must pass the task_directory as task; never write .orbit/inbox manually.';

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

export const toolDescription = 'Start Orbit only for work that benefits from independent checks: multi-step changes, real parallel work surfaces, or fixes needing objective review. Simple single-file or local edits: just do them yourself, without dispatching members. If the user explicitly asks to use Orbit, still start Orbit for those small tasks — but do the work yourself and let the checker verify; no members. context identifies this exact session and reports the remembered checker model for this session, if any; start preserves original user input and named basis and returns a task_directory. start with review_model plus remember_review_model=true keeps that checker model for the rest of this OMP session (later starts reuse it, still re-validated each start; forget-review-model clears it; never inherited by another session). Keep that task_directory: for status/check/amend/dispute/stop pass it back as task: <task_directory returned by start> to this Orbit tool — never write .orbit/inbox manually. Root dispatches members only through the native task tool (one level) when there is a genuine independent work surface — Root decides, JEV only advises, never blocks. Continue working; member results and corrections return automatically. Once work is verified, call action=check with task for a manual final check, include the actual delivery result in your visible final reply and end your turn. Orbit waits for that completed reply before checking; automatic checks do not send finalization_notice. Wait for the notice or corrections without polling. After a valid notice, call stop with intent=complete (the default) and finish the turn normally: the completion gate adjudicates that intent and refuses with the next action when no current notice exists. Reserve intent=pause for a user-requested interruption. An accepted stop is queued and completed after your turn, so the final summary is fully delivered. Do not start for discussion. Root is never replaced.';
export const toolArgs = z => ({
        action: z.enum(['context', 'start', 'status', 'check', 'amend', 'dispute', 'stop', 'review-model', 'forget-review-model']),
        task: z.string().optional().describe('Required for status/check/amend/dispute/stop: the exact task_directory string returned by action=start. Never write .orbit/inbox manually.'),
        basis: z.array(z.string()).optional(), message_id: z.string().optional(),
        review_model: z.string().optional(),
        remember_review_model: z.boolean().optional().describe('start only, together with review_model: remember that checker model for the rest of this OMP session. Later starts without review_model reuse it (re-validated, credentials re-probed on every start) until action=forget-review-model clears it. A start without review_model never changes or creates the remembered choice.'),
        intent: z.enum(['complete', 'pause']).optional().describe('stop only. complete (default) is the deliberate post-finalization completion hand-off, adjudicated by the Ruby completion gate; pause is an explicit user interruption and takes the ordinary pause path.'),
        text: z.string().optional(), check_in: z.number().int().positive().optional()
      });

// Shared transport and task operations for native plugin hosts. Each adapter
// supplies only its real session operations and native invocation identity.
export function createOrbitHost({ provider, project, dispatch, bind, reset }) {
  const tasks = new Map();
  // Session-remembered checker model (user opt-in via start with
  // remember_review_model): lives ONLY in this plugin process's memory,
  // keyed by the bound session id, so it never crosses OMP processes or
  // sessions and dies with this host. A remembered model is re-validated by
  // the CLI on every start that uses it (explicit --review-model probing),
  // and pool changes never overwrite it because explicit selection wins.
  const reviewModels = new Map();
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
  async function entry(messageId, context) {
    if (closing) throw new Error('Agent host is closing');
    const id = await bind(context);
    await listen();
    return run(['entry', '--provider', provider, '--project', project, '--thread', id,
      '--socket', socket, '--message-id', messageId], project);
  }
  return {
      async execute(a, context) {
        if (closing) throw new Error('Agent host is closing');
        const id = await bind(context);
        await listen();
        if (a.action === 'context') return JSON.stringify({ ready: true, provider, project, thread_id: id, task_directory: tasks.get(id)?.task_directory || null, session_review_model: reviewModels.get(id) || null });
        if (a.action === 'forget-review-model') {
          const previous = reviewModels.get(id) || null;
          reviewModels.delete(id);
          return JSON.stringify({ status: 'cleared', session_review_model: null, previously: previous });
        }
        if (a.action === 'start') {
          if (a.remember_review_model === true && (typeof a.review_model !== 'string' || !a.review_model.trim()))
            throw new Error('remember_review_model requires review_model: <provider/id> (it remembers that checker model for this OMP session)');
          const previous = tasks.get(id);
          if (previous) {
            const state = await ownedTask(previous.task_directory, id);
            if (!terminal.has(state.status)) {
              if (a.review_model) {
                const selected = state.review?.model;
                if (a.review_model.trim() !== selected)
                  throw new Error(`Task already active with checker ${selected || 'unknown'}; use action 'review-model' on that task to change its checker`);
                // The pre-start hook can create an explicit Orbit task before
                // Root gets to call start with remember_review_model. Accept
                // the opt-in only for the model actually selected by that
                // task, rather than silently returning without pinning it.
                if (a.remember_review_model === true) reviewModels.set(id, selected);
              }
              return JSON.stringify({ ...previous, session_review_model: reviewModels.get(id) || null,
                existing_task: true });
            }
          }
          reset(id);
          const users = (await dispatch({ method: 'messages', session: id })).filter(m => !m.internal);
          const original = a.message_id ? users.find(m => m.id === a.message_id || m.item_id === a.message_id) : users.at(-1);
          if (!original) throw new Error('No original native user message found');
          const args = ['start', '--provider', provider, '--project', project, '--thread', id, '--socket', socket, '--message-id', original.id];
          // A remembered model reaches the CLI as an ordinary explicit
          // --review-model, so every start re-validates the provider/id and
          // re-probes the isolated checker credentials; a plain explicit
          // review_model (no remember flag) is a one-off and never changes
          // the remembered choice.
          const remembered = !a.review_model && reviewModels.get(id);
          if (a.review_model || remembered) args.push('--review-model', (a.review_model || remembered).trim());
          if (a.entry_file) args.push('--entry-file', a.entry_file);
          if (a.check_in) args.push('--check-in', String(a.check_in));
          for (const file of a.basis || []) args.push('--basis', path.resolve(project, file));
          let result;
          try {
            result = { ...await run(args, project), next_action: guidance };
          } catch (error) {
            if (remembered) {
              throw new Error(`${error.message}; ${remembered} is the checker model remembered for this OMP session — retry start with an explicit review_model for a one-off choice, or clear it with action 'forget-review-model'`);
            }
            throw error;
          }
          if (a.remember_review_model === true) reviewModels.set(id, a.review_model.trim());
          if (reviewModels.has(id)) result.session_review_model = reviewModels.get(id);
          if (remembered) result.remembered_review_model = true;
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
    entry,
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

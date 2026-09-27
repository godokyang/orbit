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

export const toolDescription = 'Start Orbit for multi-step work or when the user requests it; do local one-file edits yourself. Automatic checker selection stays within runnable candidate-pool models. JEV task-fit scores rank models but never block a runnable pool candidate; missing evidence or low scores select a pooled checker with an unverified-quality notice. Only a native user message with a standalone Orbit authorization: review_model=provider/id or Orbit authorization: review_model_session=provider/id may choose an explicit checker; your review_model tool argument alone is NOT authorization. Never supply a model to bypass a failed automatic selection; if no pool model can run, report the task is uncontrolled unless the user explicitly chooses an authorized alternative. A session-scoped user choice may be remembered and is re-probed each task; forget-review-model clears it. Controlled native task members must use a live pool model; @task outside the pool requires the exact native user directive Orbit authorization: member_model=provider/id. Root decides whether to delegate genuine independent work; JEV only advises. start preserves the original native user instruction and returns task_directory; pass that exact directory as task for status/check/amend/dispute/stop and never write .orbit/inbox manually. After verification call action=check for a manual final check, deliver the actual result in your visible reply, and END YOUR TURN. Wait for corrections or the finalization_notice without polling. After a valid notice call stop with intent=complete; use intent=pause only for a user-requested interruption. A queued stop completes after your turn; Root is never replaced.';
export const toolArgs = z => ({
        action: z.enum(['context', 'start', 'status', 'check', 'amend', 'dispute', 'stop', 'review-model', 'forget-review-model']),
        task: z.string().optional().describe('Required for status/check/amend/dispute/stop: the exact task_directory string returned by action=start. Never write .orbit/inbox manually.'),
        basis: z.array(z.string()).optional(), message_id: z.string().optional().describe('Native user message id: selects the original instruction for start or the exact user authorization for review-model. A tool-provided id alone does not grant model use.'),
        review_model: z.string().optional().describe('Exact provider/id explicitly chosen by a native user; the CLI verifies that message before any checker model is used.'),
        remember_review_model: z.boolean().optional().describe('start only: session memory requires the native user directive Orbit authorization: review_model_session=provider/id. Root cannot grant a session pin using this flag alone.'),
        intent: z.enum(['complete', 'pause']).optional().describe('stop only. complete (default) is the deliberate post-finalization completion hand-off, adjudicated by the Ruby completion gate; pause is an explicit user interruption and takes the ordinary pause path.'),
        text: z.string().optional(), check_in: z.number().int().positive().optional()
      });
function userReviewModel(text) {
  let fenced = false, choice = null;
  for (const line of (text || '').split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue; }
    if (fenced) continue;
    const match = /^Orbit authorization: review_model(_session)?=([^\s/]+\/[^\s]+)$/.exec(line);
    if (!match) continue;
    const next = { model: match[2], scope: match[1] ? 'session' : 'task' };
    if (choice && (choice.model !== next.model || choice.scope !== next.scope))
      throw new Error('Conflicting review model choices in native user message');
    choice = next;
  }
  return choice;
}

// Shared transport and task operations for native plugin hosts. Each adapter
// supplies only its real session operations and native invocation identity.
export function createOrbitHost({ provider, project, dispatch, bind, reset }) {
  const tasks = new Map();
  // Only the Ruby CLI's verified native-user authorization can create a
  // session pin. The map carries its message id as well as the model; a Root
  // tool argument alone is never a grant. Pins die with this host process.
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
        if (a.action === 'context') return JSON.stringify({ ready: true, provider, project, thread_id: id, task_directory: tasks.get(id)?.task_directory || null, session_review_model: reviewModels.get(id)?.model || null });
        if (a.action === 'forget-review-model') {
          const previous = reviewModels.get(id)?.model || null;
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
                const grant = state.review?.selection?.authorization;
                if (a.remember_review_model === true) {
                  if (grant?.scope !== 'session' || grant.model !== selected)
                    throw new Error('Only a native user message with Orbit authorization: review_model_session=<provider/id> can pin the checker for this session');
                  reviewModels.set(id, { model: selected, message_id: grant.message_id });
                }
              }
              return JSON.stringify({ ...previous, session_review_model: reviewModels.get(id)?.model || null,
                existing_task: true });
            }
          }
          reset(id);
          const users = (await dispatch({ method: 'messages', session: id })).filter(m => !m.internal);
          const original = a.message_id ? users.find(m => m.id === a.message_id || m.item_id === a.message_id) : users.at(-1);
          if (!original) throw new Error('No original native user message found');
          const direct = userReviewModel(original.text);
          const laterGrant = a.review_model && !direct
            ? users.slice(users.indexOf(original) + 1).findLast(message => userReviewModel(message.text))
            : null;
          const userChoice = direct || (laterGrant && userReviewModel(laterGrant.text));
          const chosen = a.review_model?.trim() || direct?.model;
          if (a.review_model && userChoice && chosen !== userChoice.model)
            throw new Error('review_model conflicts with the native user model choice');
          if (a.remember_review_model === true && (userChoice?.scope !== 'session' || userChoice.model !== chosen))
            throw new Error('Only a native user message with Orbit authorization: review_model_session=<provider/id> can pin the checker for this session');
          const args = ['start', '--provider', provider, '--project', project, '--thread', id, '--socket', socket, '--message-id', original.id];
          const remembered = !chosen && reviewModels.get(id);
          if (chosen || remembered) args.push('--review-model', chosen || remembered.model);
          if (laterGrant) args.push('--review-authorization-message', laterGrant.id);
          if (remembered) args.push('--review-authorization-message', remembered.message_id);
          if (a.entry_file) args.push('--entry-file', a.entry_file);
          if (a.check_in) args.push('--check-in', String(a.check_in));
          for (const file of a.basis || []) args.push('--basis', path.resolve(project, file));
          let result;
          try {
            result = { ...await run(args, project), next_action: guidance };
          } catch (error) {
            if (remembered) {
              throw new Error(`${error.message}; ${remembered.model} is the checker model remembered for this OMP session — retry start with an explicitly user-authorized one-off review_model, or clear it with action 'forget-review-model'`);
            }
            throw error;
          }
          if (chosen) {
            const state = await ownedTask(result.task_directory, id);
            const grant = state.review?.selection?.authorization;
            if (a.remember_review_model === true && (grant?.scope !== 'session' || grant.model !== chosen))
              throw new Error('Only a native user message with Orbit authorization: review_model_session=<provider/id> can pin the checker for this session');
            if (grant?.scope === 'session' && grant.model === chosen)
              reviewModels.set(id, { model: grant.model, message_id: grant.message_id });
          }
          if (reviewModels.has(id)) result.session_review_model = reviewModels.get(id).model;
          if (remembered) result.remembered_review_model = true;
          tasks.set(id, result);
          return JSON.stringify(result);
        }
        if (!a.task) throw new Error('This action needs the task: pass task: <task_directory returned by start> to the orbit tool (status/check/amend/dispute/stop/review-model all take it). Do NOT write .orbit/inbox manually.');
        if (a.action === 'review-model' && (typeof a.review_model !== 'string' || !a.review_model.trim()))
          throw new Error('review-model requires the exact native user-authorized review_model: <provider/id>; it never auto-retries or switches a check in flight');
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
          if (a.message_id) args.push('--authorization-message-id', a.message_id);
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

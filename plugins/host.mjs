import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { holdReleaseLease } from './lease.mjs';
import { workUnitOperationError } from './native-task-preflight.mjs';

holdReleaseLease();

const cli = fileURLToPath(new URL('../scripts/orbit', import.meta.url));
const terminal = new Set(['complete', 'paused', 'needs_user', 'failed', 'stop_unconfirmed']);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const guidance = 'Continue the authorized implementation; do simple local edits yourself. Once the artifact is verified, call Orbit action=check with task: the task_directory returned by start to request the manual final check. Give the actual delivery result in your visible reply and END YOUR TURN. Orbit waits for that completed reply before starting the manual final check; automatic checks never issue a finalization_notice. Wait for that notice or corrections without sleeping or polling. On a valid notice call stop with intent=complete, then finish your reply; do not stop merely to deliver unless the user explicitly asked to interrupt. Member results return automatically. Later status/check/amend/dispute/stop/work-unit calls must pass the task_directory as task; never write .orbit/inbox manually.';

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

export const toolDescription = 'Start Orbit for multi-step work or when the user requests it; do local one-file edits yourself. Use takeover only to bring an already-executed requirement under supervision, stating why; the earlier execution is never recognized as controlled. Orbit prefers runnable models in the OMP candidate pool; if none run, Root can use another OMP-accessible model. JEV task-fit ranks suitable checkers but low or missing scores do not block a runnable model. No per-model user authorization is required. After a failed check Orbit records the failure and tries an unused runnable OMP model; never treat a failed check as a pass. Root may choose review_model from the current OMP catalog. For necessary integration or diagnosis after bounded delivery, Root may also select a stronger stage model via action root-model (pool∩catalog exact provider/id, phase, reason) — optional, never required per task. Controlled delegation first declares an Orbit work-unit and puts its actual orbit-unit: id in task text. In native task items, agent is the generated Orbit candidate name; model is an exact provider/model selector, never an agent name. Use native task/hub with that durable work unit. Native task.tools mounts eval-defined tools; omit it for native read/write/edit/bash, whose permissions are enforced by the work unit. Repair the actual failed native call rather than switching to an unregistered eval agent. Independent checks and confirmed completion remain required.';
export const toolArgs = z => ({
        action: z.enum(['context', 'start', 'status', 'check', 'amend', 'dispute', 'stop', 'review-model', 'work-unit', 'root-model']),
        task: z.string().optional().describe('Required for status/check/amend/dispute/stop/work-unit/review-model/root-model: the exact task_directory returned by start.'),
        basis: z.array(z.string()).optional(), message_id: z.string().optional().describe('start: native user message id selecting the original instruction; amend: the exact native user correction id, required explicitly. A progress question is a continuation source, never an amendment.'),
        review_model: z.string().optional().describe('Optional Root-selected provider/id from the current OMP model catalog.'),
        recovery_evidence: z.string().optional().describe('review-model only: for a model with a recorded account/quota refusal, cite an actual account recovery or successful same-route call before retry. A new artifact or model name alone is not recovery.'),
        resume_from: z.string().optional().describe('start only: exact stopped task_directory for continuing the SAME delivery after answering the user. Uses the preserved original instruction and amendments, creates a new supervised boundary, and never revives stopped members. Explicit pause/discussion/cancel wins; unrelated questions never resume.'),
        root_model: z.string().optional().describe('root-model only: exact provider/id from the CURRENT user pool ∩ OMP catalog for this session. The action can be called without it to list the exact IDs now available.'),
        phase: z.enum(['execution', 'integration', 'diagnosis']).optional().describe('root-model only: which stage the selected model is for. An intent declaration, not a capability measurement.'),

        intent: z.enum(['complete', 'pause']).optional().describe('stop only: complete (default) requires the actual finalization gate; pause is an explicit interruption.'),
        operation: z.enum(['declare', 'read', 'list', 'finish', 'select']).optional().describe('work-unit operation; declare records a bounded handoff and returns member selection before dispatch; select refreshes relevant facts using the existing assessment cache; finish records Root verification.'),
        work_unit: z.record(z.string(), z.unknown()).optional().describe('declare payload types: {spec:{objective:non-empty string, requirements:non-empty string[], allowed_paths/allowed_tools/allowed_commands:string[] (at least one non-empty), acceptance:non-empty string, escalation:non-empty string, optional context:string, decisions:string[], input_materials:string[] of existing project files accessible through allowed_paths, dependencies:string[] of existing unit ids}}. Paths/tools/commands are flat allowed_* fields inside spec, never nested scope. allowed_paths is the member\'s entire accessible path set (read and write share it): read-only specs/tests/dependencies must be listed there too, or their necessary facts go into context; it grants no automatic read-only protection. allowed_commands must be complete commands, matched verbatim — never prefixes. bash requires explicit allowed_commands. Skills, MCP or external files are not automatic member entrances; prepare needed facts in context or project input_materials before declaring. Delegate units need actual tool entrances and bounded paths; invalid declarations return a concrete repair before selection or dispatch. Remaining optional spec fields: execution (root|delegate, default delegate; declare Root integration work as root so it never occupies member selection), model_requirements ({relevant_indices: [coding_index|agentic_index|intelligence_index], required_input_modalities: [text|image], required_parameters: [tools], ...}; declare only task-relevant indices, leave unclassified tasks unknown). fresh without prior may mean missing relevant_indices; facts_only is not a recommendation. Explain task-related reasons for accepting a hint or selecting a model yourself and honor explicit user model preferences. read/finish use id; finish needs {id, status:accepted|rejected|failed, result:non-empty string, verification:non-empty string}. Root units may finish without member binding; accepted records Root verification, not independent final acceptance.'),
        takeover: z.object({ reason: z.string(), prior_scope: z.string().optional() }).optional()
          .describe('Take over an already-executed original requirement via start: say why (reason) and optionally declare the prior execution scope (prior_scope). The artifact digest and supervision start time are captured by the program, never supplied here.'),
        text: z.string().optional().describe('amend: exact native user correction text, or omit it to fetch the original; user-authorized requirement revisions only, never progress or independent questions; never a way to submit test results or completion evidence (verified execution enters checks through real Root tool receipts). stop: the reason text.'), check_in: z.number().int().positive().optional()
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
  async function entry(messageId, context) {
    if (closing) throw new Error('Agent host is closing');
    const id = await bind(context);
    await listen();
    return run(['entry', '--provider', provider, '--project', project, '--thread', id,
      '--socket', socket, '--message-id', messageId], project);
  }
  return {
      async execute(a, context) {
        const operationError = workUnitOperationError(a);
        if (operationError) throw new Error(operationError);
        if (closing) throw new Error('Agent host is closing');
        const id = await bind(context);
        await listen();
        if (a.action === 'context') {
          const latest = (await dispatch({ method: 'messages', session: id })).filter(m => !m.internal).at(-1);
          return JSON.stringify({ ready: true, provider, project, thread_id: id,
            task_directory: tasks.get(id)?.task_directory || null,
            native_user_message_id: latest?.id || latest?.item_id || null });
        }
        if (a.action === 'start') {
          const previous = tasks.get(id);
          if (previous) {
            const state = await ownedTask(previous.task_directory, id);
            if (!terminal.has(state.status)) {
              if (a.review_model && a.review_model.trim() !== state.review?.model)
                throw new Error(`Task already active with checker ${state.review?.model || 'unknown'}; use action 'review-model' to change it`);
              // A later prior_scope on an existing takeover task is enqueued
              // through the small CLI queue entry; the runtime stays the only
              // state writer and appends it without touching the created
              // boundary. Presence is validated — a non-string or empty value
              // is refused, never treated as absent — while an omitted key
              // (undefined) keeps the previous idempotent result untouched.
              const laterScope = a.takeover?.prior_scope;
              if (laterScope !== undefined) {
                if (typeof laterScope !== 'string' || !laterScope.trim())
                  throw new Error('takeover prior_scope must be a non-empty string when present');
                const queued = await run(['takeover-scope', previous.task_directory, '--file', '-'], project,
                  JSON.stringify({ prior_scope: laterScope, reason: a.takeover.reason }));
                return JSON.stringify({ ...previous, existing_task: true, takeover_scope_queued: queued });
              }
              return JSON.stringify({ ...previous, existing_task: true });
            }
          }
          reset(id);
          const users = (await dispatch({ method: 'messages', session: id })).filter(m => !m.internal);
          const original = a.message_id ? users.find(m => m.id === a.message_id || m.item_id === a.message_id) : users.at(-1);
          if (!original) throw new Error('No original native user message found');
          const chosen = a.review_model?.trim();
          const args = ['start', '--provider', provider, '--project', project, '--thread', id, '--socket', socket, '--message-id', original.id];
          if (a.resume_from) {
            const old = JSON.parse(await fs.readFile(path.join(await fs.realpath(a.resume_from), 'state.json'), 'utf8'));
            if (old.connection?.provider !== provider || old.connection?.thread_id !== id ||
                await fs.realpath(old.project_root) !== await fs.realpath(project))
              throw new Error('Continuation must belong to this native Root session and project');
            if (old.status !== 'paused' || old.stop_confirmation?.confirmed !== true)
              throw new Error('Continuation needs a confirmed stopped task; clean up unconfirmed work first');
            args.push('--resume-from', await fs.realpath(a.resume_from));
          }
          if (chosen) args.push('--review-model', chosen);
          if (a.entry_file) args.push('--entry-file', a.entry_file);
          if (a.check_in) args.push('--check-in', String(a.check_in));
          for (const file of a.basis || []) args.push('--basis', path.resolve(project, file));
          let takeoverInput = '';
          if (a.takeover) {
            if (typeof a.takeover.reason !== 'string' || !a.takeover.reason.trim())
              throw new Error('takeover needs a stated reason for taking over this requirement');
            args.push('--takeover-file', '-');
            takeoverInput = JSON.stringify({ reason: a.takeover.reason, prior_scope: a.takeover.prior_scope });
          }
          const result = { ...await run(args, project, takeoverInput), next_action: guidance };
          tasks.set(id, result);
          return JSON.stringify(result);
        }
        if (!a.task) throw new Error('This action needs the task: pass task: <task_directory returned by start> to the orbit tool (status/check/amend/dispute/stop/work-unit/review-model/root-model all take it). Do NOT write .orbit/inbox manually.');
        if (a.action === 'review-model' && (typeof a.review_model !== 'string' || !a.review_model.trim()))
          throw new Error('review-model requires a Root-selected provider/id from the current OMP model catalog');
        if (a.action === 'root-model') {
          // The host validates ownership only; the native side owns the pool
          // ∩ catalog check, the real setModel call, and the factual record.
          await ownedTask(a.task, id);
          return null; // native dispatch handles this action
        }
        await ownedTask(a.task, id);
        if (a.action === 'work-unit') {
          const operation = a.operation || 'declare';
          const result = await run(['work-unit', a.task, operation, '--file', '-'], project,
            JSON.stringify(a.work_unit || {}));
          if (operation === 'declare') {
            // Return the actual assessment in the same native tool result.
            // The Root sees it before composing its task dispatch, including
            // an explicit facts-only/declined result; no steer wake is needed.
            const selected = await run(['work-unit', a.task, 'select', '--file', '-'], project,
              JSON.stringify({ id: result.unit.id }));
            result.selection = selected.selection;
            result.selection_request_id = selected.request_id;
            if (result.selection?.decision === 'facts_only' && !result.unit.model_requirements?.relevant_indices?.length)
              result.notice = '本单元未声明任务相关指标，当前没有适配推荐。若本单元是编码工作，在新声明的 spec.model_requirements.relevant_indices 中填写 coding_index 等真实相关指标；明确未分类的任务可保持未知并说明自选依据。不要把 facts_only 当推荐。';
          }
          return JSON.stringify(result);
        }
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
          if (a.recovery_evidence) args.push('--recovery-evidence', a.recovery_evidence);
        }
        if (a.action === 'amend') {
          if (!a.message_id) throw new Error('Provide the native user correction message_id explicitly; action=context reports the latest native user id. Only amend an actual requirement correction, never a progress question.');
          const users = (await dispatch({ method: 'messages', session: id })).filter(m => !m.internal);
          const revision = users.find(m => m.id === a.message_id || m.item_id === a.message_id);
          if (!revision) throw new Error('No native user amendment found');
          if (a.text !== undefined && a.text !== revision.text)
            throw new Error('Use the original native user correction verbatim; do not replace it with a Root summary');
          a = { ...a, text: revision.text };
          if (!a.text?.trim()) throw new Error('Provide the original amendment');
          args.push('--file', '-');
          args.push('--message-id', revision.id);
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

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
// G9b: probe result for a pre-existing socket file at a caller-specified
// control path. Only 'refused' (ECONNREFUSED) can mean a dead owner; anything
// connected, timed out or failing otherwise stays occupied/unknown and is
// never removed.
function probeSocketState(target) {
  return new Promise(resolve => {
    const attempt = net.connect(target);
    let settled = false;
    const timer = setTimeout(() => finish('timeout'), 2000);
    const finish = state => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      attempt.destroy();
      resolve(state);
    };
    attempt.on('connect', () => finish('connected'));
    attempt.on('error', error => finish(error?.code === 'ECONNREFUSED' ? 'refused' : `error:${error?.code || 'unknown'}`));
  });
}

// G9b caller-specified control socket (ORBIT_CONTROL_SOCKET). Security
// invariants: the string is used VERBATIM (the Ruby side stores
// File.expand_path(socket) and ownership compares exact strings, so any
// realpath/normalization here would break ownership, e.g. /tmp vs
// /private/tmp on macOS); path.resolve is a validation check only. The caller
// owns the parent directory: it must exist with the same uid and private
// permissions, and we never chmod it or delete it. An existing socket file is
// replaced only when it is provably dead (ECONNREFUSED) and its inode has not
// changed since we lstat'ed it.
async function validateSpecifiedSocket(target) {
  if (path.resolve(target) !== target)
    throw new Error('ORBIT_CONTROL_SOCKET must be a normalized absolute path; the string is used verbatim (no realpath), so it must be spelled exactly as passed to orbit start --socket');
  const limit = (process.platform === 'darwin' ? 104 : 108) - 1; // trailing NUL
  if (Buffer.byteLength(target) > limit)
    throw new Error(`ORBIT_CONTROL_SOCKET path exceeds the ${limit}-byte unix socket limit on ${process.platform}`);
  const parent = path.dirname(target);
  let parentStat;
  try { parentStat = await fs.lstat(parent); }
  catch (error) { throw new Error(`ORBIT_CONTROL_SOCKET parent directory is not accessible: ${error.message}`); }
  if (!parentStat.isDirectory()) throw new Error('ORBIT_CONTROL_SOCKET parent exists but is not a directory');
  if (parentStat.uid !== process.getuid())
    throw new Error('ORBIT_CONTROL_SOCKET parent directory must be owned by the current user');
  if (parentStat.mode & 0o077)
    throw new Error('ORBIT_CONTROL_SOCKET parent directory must be private (no group/other access); create it 0700');
  const existing = await fs.lstat(target).catch(error => (error?.code === 'ENOENT' ? null : Promise.reject(error)));
  if (!existing) return;
  if (!existing.isSocket() || existing.uid !== process.getuid())
    throw new Error('ORBIT_CONTROL_SOCKET exists and is not a socket owned by the current user');
  const probe = await probeSocketState(target);
  if (probe !== 'refused')
    throw new Error(`ORBIT_CONTROL_SOCKET is occupied: ${probe === 'connected' ? 'a live process accepts connections' : `the probe did not prove it dead (${probe})`}`);
  const now = await fs.lstat(target);
  if (now.dev !== existing.dev || now.ino !== existing.ino)
    throw new Error('ORBIT_CONTROL_SOCKET changed while being probed; refusing to remove it');
  await fs.unlink(target);
}
const guidance = 'Continue the authorized implementation; do simple local edits yourself. Once the artifact is verified, call Orbit action=check with task: the task_directory returned by start to request the manual final check. Give the actual delivery result in your visible reply and END YOUR TURN. Orbit waits for that completed reply before starting the manual final check; automatic checks never issue a finalization_notice. Wait for that notice or corrections without sleeping or polling. On a valid notice call stop with intent=complete, then finish your reply; do not stop merely to deliver unless the user explicitly asked to interrupt. Member results return automatically. A returned independent adjudication is Root\'s decision: call action=ruling with the adjudicated check number and accept, or recheck with the missing evidence; the program never voids a ruling by itself and never re-adjudicates that appeal while your decision is pending. Later status/check/amend/dispute/ruling/stop/work-unit calls must pass the task_directory as task; never write .orbit/inbox manually.';

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

export const toolDescription = 'Start Orbit for multi-step work or when the user requests it; do local one-file edits yourself. Use takeover only to bring an already-executed requirement under supervision, stating why; the earlier execution is never recognized as controlled. Execution members are selected from the executor pool and independent checkers from the checker pool; configured pools never borrow candidates across roles or fall back to the full OMP catalog. An unconfigured role inherits legacy candidates when present; otherwise execution members retain the @task fallback and checkers retain the current OMP catalog fallback. After a failed check Orbit records the failure and tries an unused runnable checker-pool candidate. Root keeps the current OMP model; action review-model explicitly lets Root choose any runnable model from the current OMP catalog for a check. Never treat a failed check as a pass. Controlled delegation first declares an Orbit work-unit and puts its actual orbit-unit: id in task text. In native task items, agent is the generated Orbit candidate name; model is an exact provider/model selector, never an agent name. Use native task/hub with that durable work unit. Native task.tools mounts eval-defined tools; omit it for native read/write/edit/bash, whose permissions are enforced by the work unit. Repair the actual failed native call rather than switching to an unregistered eval agent. A returned independent adjudication is decided by Root through action=ruling (accept, or recheck with the missing evidence): the program never voids a ruling by itself and never repeats that appeal while the decision is pending. Independent checks and confirmed completion remain required.';
export const toolArgs = z => ({
        action: z.enum(['context', 'start', 'status', 'check', 'amend', 'dispute', 'ruling', 'stop', 'review-model', 'work-unit']),
        task: z.string().optional().describe('Required for status/check/amend/dispute/ruling/stop/work-unit/review-model: the exact task_directory returned by start.'),
        basis: z.array(z.string()).optional(), message_id: z.string().optional().describe('start: native user message id selecting the original instruction; amend: the exact native user correction id, required explicitly. A progress question is a continuation source, never an amendment.'),
        allowed_models: z.array(z.string()).min(1).max(64).optional().describe("Optional exact task model authorization; cannot exceed the session authorization."),
        review_model: z.string().optional().describe('Optional Root-selected provider/id from the current OMP model catalog.'),
        task_overview: z.string().optional().describe('Optional task selection context already known to Root; do not investigate solely to fill this field.'),
        recovery_evidence: z.string().optional().describe('review-model only: for a model with a recorded account/quota refusal, cite an actual account recovery or successful same-route call before retry. A new artifact or model name alone is not recovery.'),
        resume_from: z.string().optional().describe('start only: exact confirmed-stopped task_directory for continuing the SAME delivery from paused or legacy needs_user. Requires a real native user message in the same Root session. Uses the preserved original instruction and amendments, creates a new supervised boundary, and never revives stopped members. Explicit pause/discussion/cancel wins; unrelated questions never resume.'),
        external_refs: z.array(z.string()).optional().describe('start only: opaque references the caller attaches to this task (for example an external tracker id); at most 16, each non-blank, at most 256 characters, distinct. Stored verbatim and returned by status/export; never interpreted. A continuation does not inherit them.'),

        intent: z.enum(['complete', 'pause']).optional().describe('stop only: complete (default) requires the actual finalization gate; pause is an explicit interruption.'),
        operation: z.enum(['declare', 'read', 'list', 'finish', 'select']).optional().describe('work-unit operation; declare records a bounded handoff and returns member selection before dispatch; select refreshes relevant facts using the existing assessment cache; finish records Root verification.'),
        ruling: z.object({ check: z.number().int().positive(), decision: z.enum(['accept', 'recheck']), reason: z.string().optional() }).optional()
          .describe('ruling only: Root\'s decision on a returned independent adjudication. check is the adjudicated check number named by the ruling message; accept applies the ruling (overturned problems are closed, the appeal ends), recheck requires reason (the missing evidence and why) and keeps the original result for a new adjudication. The program never voids a ruling by itself, and no decision means no repeated adjudication of that appeal.'),
        work_unit: z.record(z.string(), z.unknown()).optional().describe('declare payload types: {spec:{objective:non-empty string, requirements:non-empty string[], allowed_paths/allowed_tools/allowed_commands:string[] (at least one non-empty), acceptance:non-empty string, escalation:non-empty string, optional context:string, decisions:string[], input_materials:string[] of existing project files under the artifact root, dependencies:string[] of existing unit ids}}. Paths/tools/commands are flat allowed_* fields inside spec, never nested scope. Native read/write/edit/grep/glob tools autonomously choose files under the artifact root with per-target root and protected-path checks; allowed_paths scopes the bash filesystem sandbox and command path preflight, not native file access. It grants no automatic read-only protection. allowed_commands must be complete commands, matched verbatim — never prefixes. bash requires explicit allowed_paths and allowed_commands. Skills, MCP or external files are not automatic member entrances; prepare needed facts in context or project input_materials before declaring. Delegate units need actual tool entrances and bounded paths; invalid declarations return a concrete repair before selection or dispatch. Remaining optional spec fields: execution (root|delegate, default delegate; declare Root integration work as root so it never occupies member selection), model_requirements ({relevant_indices: [coding_index|agentic_index|intelligence_index], required_input_modalities: [text|image], required_parameters: [tools], ...}; declare only task-relevant indices, leave unclassified tasks unknown). fresh without prior may mean missing relevant_indices; facts_only is not a recommendation. Explain task-related reasons for accepting a hint or selecting a model yourself and honor explicit user model preferences. read/finish use id; finish needs {id, status:accepted|rejected|failed, result:non-empty string, verification:non-empty string}. Root units may finish without member binding; accepted records Root verification, not independent final acceptance.'),
        takeover: z.object({ reason: z.string(), prior_scope: z.string().optional() }).optional()
          .describe('Take over an already-executed original requirement via start: say why (reason) and optionally declare the prior execution scope (prior_scope). The artifact digest and supervision start time are captured by the program, never supplied here.'),
        text: z.string().optional().describe('amend: exact native user correction text, or omit it to fetch the original; user-authorized requirement revisions only, never progress or independent questions; never a way to submit test results or completion evidence (verified execution enters checks through real Root tool receipts). stop: the reason text.'), check_in: z.number().int().positive().optional()
      });

// Shared transport and task operations for native plugin hosts. Each adapter
// supplies only its real session operations and native invocation identity.
export function createOrbitHost({ provider, project, dispatch, bind, reset, authorizeTask, promptUser }) {
  const tasks = new Map();
  let host, socket, setup, ownFolder = null, socketIdentity = null, closing = false;
  async function listen() {
    if (setup) return setup;
    setup = (async () => {
      // A caller-specified channel (ORBIT_CONTROL_SOCKET) wins over the
      // self-created default; default keeps the lazy behavior unchanged.
      const specified = typeof process.env.ORBIT_CONTROL_SOCKET === 'string' && process.env.ORBIT_CONTROL_SOCKET
        ? process.env.ORBIT_CONTROL_SOCKET : null;
      // Validate the caller path BEFORE creating anything, so a refusal
      // leaves no server and no directory behind.
      if (specified) await validateSpecifiedSocket(specified);
      // macOS Unix socket paths are short: os.tmpdir() can exceed the limit.
      ownFolder = await fs.mkdtemp(path.join(process.platform === 'darwin' ? '/tmp' : os.tmpdir(), `orbit-${provider}-`));
      await fs.chmod(ownFolder, 0o700);
      const internalSocket = path.join(ownFolder, 'control.sock');
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
      await new Promise((resolve, reject) => { host.once('error', reject); host.listen(internalSocket, resolve); });
      await fs.chmod(internalSocket, 0o600);
      if (specified) {
        // Node's net.Server.close() unlinks the path it listened on, so the
        // server must NEVER listen directly inside the caller's directory: a
        // caller file replacing our socket would be deleted on close. The
        // caller-visible path is instead a HARD LINK to our internal socket
        // (connecting via either path works); `socket` keeps the verbatim
        // caller string for record ownership and --socket. The link refuses
        // EEXIST rather than overwriting a racing live path. Our identity is
        // captured from the INTERNAL socket BEFORE the link: lstat'ing the
        // caller alias afterwards is racy — the caller may already have
        // replaced it with a live socket, and close() would then unlink a
        // file we never created.
        socketIdentity = await fs.lstat(internalSocket);
        try {
          await fs.link(internalSocket, specified);
        } catch (error) {
          host.close();
          await fs.rm(ownFolder, { recursive: true, force: true });
          throw new Error(`ORBIT_CONTROL_SOCKET could not be linked into place: ${error.message}`);
        }
      }
      socket = specified || internalSocket;
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
    // G9b: session_start pre-listens the control channel so an external
    // integration caller can drive explicit start/status/stop from session
    // start on. Idempotent; the default launch path keeps lazy listen.
    listen,
    async bindTask(taskDirectory, id) {
      if (closing) throw new Error('Agent host is closing');
      const real = await fs.realpath(taskDirectory);
      const value = await ownedTask(real, id);
      if (value.format !== 'orbit-task-1' || value.project_root !== project ||
          !['starting', 'running'].includes(value.status) ||
          !Number.isSafeInteger(value.runtime_pid) || value.runtime_pid <= 0)
        throw new Error('Task binding requires this project\'s active runtime');
      const previous = tasks.get(id);
      if (previous && previous.task_directory !== real &&
          !terminal.has((await ownedTask(previous.task_directory, id)).status))
        throw new Error('Root session already has another active Orbit task');
      if (authorizeTask) await authorizeTask(value, id);
      const result = { task_directory: real, pid: value.runtime_pid,
        status: value.status, review_model: value.review?.model };
      tasks.set(id, result);
      return result;
    },
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
            if (!['paused', 'needs_user'].includes(old.status) || old.stop_confirmation?.confirmed !== true)
              throw new Error('Continuation needs a confirmed stopped task; clean up unconfirmed work first');
            args.push('--resume-from', await fs.realpath(a.resume_from));
          }
          for (const model of a.allowed_models || []) args.push("--allowed-model", model);
          if (chosen) args.push('--review-model', chosen);
          if (a.task_overview !== undefined) args.push('--task-overview', a.task_overview);
          for (const ref of a.external_refs || []) args.push('--external-ref', ref);
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
        if (!a.task) throw new Error('This action needs the task: pass task: <task_directory returned by start> to the orbit tool (status/check/amend/dispute/ruling/stop/work-unit/review-model all take it). Do NOT write .orbit/inbox manually.');
        if (a.action === 'review-model' && (typeof a.review_model !== 'string' || !a.review_model.trim()))
          throw new Error('review-model requires a Root-selected provider/id from the current OMP model catalog');
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
        if (a.action === 'ruling') {
          const ruling = a.ruling;
          if (!ruling || !Number.isSafeInteger(ruling.check) || ruling.check <= 0)
            throw new Error('ruling needs the adjudicated check number: pass ruling: { check: <number named by the ruling message>, decision: "accept" | "recheck", reason? }');
          args.push('--check', String(ruling.check), '--decision', ruling.decision);
          if (ruling.reason) args.push('--reason', ruling.reason);
          a = { ...a, text: undefined };
        }
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
        // Node's net.Server.close() unlinks the INTERNAL listen path itself,
        // so only our own holding directory is recycled here. The caller-
        // visible hard-link alias is removed separately, and only while it
        // still IS our socket (same dev/ino): a caller file that replaced it
        // survives — we never delete what is not ours.
        host.close();
        if (socketIdentity) {
          const current = await fs.lstat(socket).catch(() => null);
          if (current && current.isSocket() && current.dev === socketIdentity.dev && current.ino === socketIdentity.ino)
            await fs.unlink(socket).catch(() => {});
        }
        if (ownFolder) await fs.rm(ownFolder, { recursive: true, force: true });
      }
    }
  };
}

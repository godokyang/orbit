import fs from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createOrbitHost, toolArgs, toolDescription } from './host.mjs';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const textOf = content => typeof content === 'string' ? content : (content || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
// Internal synchronous registration entry (TaskRecord-backed, atomic+durable).
// Overridable in tests; production resolves next to this file.
const registerMemberBin = process.env.ORBIT_REGISTER_MEMBER_BIN
  || fileURLToPath(new URL('../scripts/orbit-register-member', import.meta.url));

// The SDK is supplied by OMP itself, including in its standalone binary.
export function installOmpExtension(pi, sdk) {
  const entries = new Map();
  // Requested spawn name -> { taskDir, toolCallId }. The registry gate matches
  // registered ids against this map: exact match is the expected identity, a
  // suffixed match (`<name>-2`) is allocator drift and must be refused.
  const requestedNames = new Map();
  const nativeMemberIds = new Set();
  const memberTasks = new Map();    // member agent id -> task directory (ownership check for member_* ops)
  const memberActiveTools = new Map(); // member agent id -> Set of in-flight tool call ids (observed)
  const stoppedMembers = new Set(); // member ids whose stop was CONFIRMED via the live-session path
  const taskDirs = new Map();       // root session id -> task directory (bound via orbit start/context)
  const collabEvents = [];          // native hub traffic + native task results (bounded, readable via dispatch)
  const COLLAB_CAP = 500;
  const collabSeqByTask = new Map();    // task_dir -> last assigned seq (per-task, gap-free)
  const collabDroppedByTask = new Map(); // task_dir -> count of dropped oldest events
  let host, currentContext, registryHookInstalled;

  // Observable record of native collaboration. Root hub traffic is captured by
  // the awaited tool_call/tool_result hooks; member-origin hub traffic is
  // captured by the member session's tool_execution_start/end subscription
  // (member start fires after the tool gate, so it is observation only).
  // hub_call captures the wire intent (op/recipient/body); hub_result and
  // task_result capture what actually came back. Every entry is tagged with
  // the owning task directory (Root sessions via their binding, member
  // sessions via memberTasks) so a bounded buffer can never mix tasks.
  function observeCollab(entry) {
    entry.id = null;
    entry.seq = null;
    entry.task_dir = taskDirs.get(entry.session_id) ?? (entry.agent_id ? memberTasks.get(entry.agent_id) : undefined) ?? null;
    if (entry.task_dir) {
      const seq = (collabSeqByTask.get(entry.task_dir) ?? 0) + 1;
      collabSeqByTask.set(entry.task_dir, seq);
      entry.seq = seq;
      entry.id = `collab-${seq}`;
    }
    collabEvents.push(entry);
    if (collabEvents.length > COLLAB_CAP) {
      const dropped = collabEvents.splice(0, collabEvents.length - COLLAB_CAP);
      for (const item of dropped) {
        if (item.task_dir) collabDroppedByTask.set(item.task_dir, (collabDroppedByTask.get(item.task_dir) ?? 0) + 1);
      }
    }
  }

  function trackMemberTools(id, session) {
    if (memberActiveTools.has(id) || typeof session?.subscribe !== 'function') return;
    const active = new Set();
    memberActiveTools.set(id, active);
    session.subscribe(event => {
      if (event.type === 'tool_execution_start') {
        active.add(event.toolCallId);
        if (event.toolName === 'hub' && memberTasks.has(id)) {
          const input = event.args || {};
          observeCollab({ kind: 'hub_call', at: Date.now(), session_id: session.sessionId ?? null, agent_id: id,
            tool_call_id: event.toolCallId ?? null, op: input.op ?? null, to: input.to ?? null, from: input.from ?? null,
            reply_to: input.replyTo ?? null, await_reply: input.await === true,
            message: typeof input.message === 'string' ? input.message.slice(0, 2000) : null });
        }
      }
      if (event.type === 'tool_execution_end') {
        active.delete(event.toolCallId);
        if (event.toolName === 'hub' && memberTasks.has(id)) {
          const result = event.result;
          let text = null;
          if (typeof result === 'string') {
            text = result;
          } else if (Array.isArray(result?.content)) {
            text = result.content.filter(part => part && part.type === 'text' && typeof part.text === 'string')
              .map(part => part.text).join(' ');
          }
          observeCollab({ kind: 'hub_result', at: Date.now(), session_id: session.sessionId ?? null, agent_id: id,
            tool_call_id: event.toolCallId ?? null, ok: event.isError === false,
            text: text ? text.slice(0, 2000) : null });
        }
      }
    });
  }

  function remember(session) {
    const id = session.sessionId;
    if (entries.has(id)) return entries.get(id);
    const entry = { id, session, activeTools: new Set(), pending: 0, interrupted: false };
    entry.unsubscribe = session.subscribe(event => {
      if (event.type === 'tool_execution_start') entry.activeTools.add(event.toolCallId);
      if (event.type === 'tool_execution_end') entry.activeTools.delete(event.toolCallId);
      if (event.type === 'message_end' && event.message.role === 'assistant' && sdk.isUserInterruptAbort(event.message)) entry.interrupted = true;
    });
    entries.set(id, entry);
    return entry;
  }
  function agentIdFor(sessionId) {
    try {
      const ref = sdk.AgentRegistry.global().list().find(r => r.session?.sessionId === sessionId);
      return ref?.id ?? null;
    } catch { return null; }
  }
  function rootFor(ctx) {
    const id = ctx.sessionManager.getSessionId();
    const ref = sdk.AgentRegistry.global().list().find(r => r.session?.sessionId === id);
    // Native task members are real registry refs too; only the process main
    // agent may bind Orbit. Anything else must not reach tool registration or
    // the task binding (it would let a member start Orbit as a fake Root).
    if (!ref?.session || ref.id !== sdk.MAIN_AGENT_ID || ref.kind !== 'main')
      throw new Error('Only the main agent session can use Orbit; execution members must report to Root');
    currentContext = ctx;
    return remember(ref.session);
  }
  function owned(id) {
    const entry = entries.get(id);
    if (!entry || entry.session.sessionId !== id) throw new Error('Session is not owned by this Orbit host');
    return entry;
  }
  // Returns true only when the registration gate is actually installed. A
  // missing registry event surface means member registration is impossible;
  // task dispatch must then fail closed instead of starting unregistered
  // members.
  function subscribeRegistryGate() {
    if (registryHookInstalled) return true;
    let registry;
    try { registry = sdk.AgentRegistry.global(); } catch { return false; }
    if (typeof registry.onChange !== 'function') return false;
    try {
      registry.onChange(ev => {
      if (ev.type !== 'registered') return;
      const ref = ev.ref;
      if (process.env.ORBIT_GATE_DEBUG) process.stderr.write(`Orbit gate: registered id=${ref.id} kind=${ref.kind} parent=${ref.parentId ?? 'null'} pending=${requestedNames.has(ref.id)}\n`);
      if (ref.kind !== 'sub') return;
      const pending = requestedNames.get(ref.id);
      const base = ref.id.replace(/-\d+$/, '');
      const drifted = !pending && requestedNames.has(base);
      if (!pending && !drifted) return; // not one of ours (e.g. revived agent)
      const taskDir = pending?.taskDir ?? requestedNames.get(base)?.taskDir;
      if (!taskDir) return;
      if (ref.session) trackMemberTools(ref.id, ref.session);
      if (drifted) {
        refuseMember(ref.id, taskDir, base, 'id_drift');
        return;
      }
      const result = registerMember(taskDir, {
        id: ref.id, requested: ref.id, toolCallId: pending.toolCallId,
        model: ref.session?.model ? `${ref.session.model.provider}/${ref.session.model.id}` : undefined
      });
      if (result.ok) {
        nativeMemberIds.add(ref.id);
        memberTasks.set(ref.id, taskDir);
        requestedNames.delete(ref.id);
      } else {
        // Duplicate or unreadable member list: never let model work proceed
        // under an identity Orbit did not durably record.
        refuseMember(ref.id, taskDir, ref.id, `registration_failed: ${result.reason}`);
      }
      });
      registryHookInstalled = true;
      return true;
    } catch { return false; }
  }
  function registerMember(taskDir, { id, requested, toolCallId, model, status = 'registered', reason, abortConfirmed }) {
    const args = ['--disable-gems', registerMemberBin, taskDir, '--id', id, '--requested', requested, '--status', status];
    if (model) args.push('--model', model);
    if (toolCallId) args.push('--tool-call-id', toolCallId);
    if (reason) args.push('--reason', reason);
    if (abortConfirmed !== undefined) args.push('--abort-confirmed', abortConfirmed ? 'true' : 'false');
    try {
      const ruby = process.env.ORBIT_RUBY || 'ruby';
      const run = spawnSync(ruby, args, { encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
      if (run.status !== 0 || !run.stdout) return { ok: false, reason: (run.stderr || run.error?.message || `exit ${run.status}`).trim().slice(0, 300) };
      return JSON.parse(run.stdout.trim().split('\n').at(-1));
    } catch (error) {
      return { ok: false, reason: String(error?.message || error).slice(0, 300) };
    }
  }
  // The block is only real if the terminal flip landed: setStatus is a public
  // boolean API and the ref must read back aborted. A swallowed or failed
  // signal must be exposed, never recorded as a clean refusal.
  function signalAbort(id) {
    try {
      const registry = sdk.AgentRegistry.global();
      if (registry.setStatus(id, 'aborted') !== true) return false;
      return registry.get?.(id)?.status === 'aborted';
    } catch { return false; }
  }
  function refuseMember(id, taskDir, requested, reason) {
    const abortConfirmed = signalAbort(id);
    const recordedReason = abortConfirmed ? reason : `${reason}; abort_unconfirmed`;
    const refusal = registerMember(taskDir, { id, requested, status: 'refused', reason: recordedReason, abortConfirmed });
    if (!abortConfirmed)
      process.stderr.write(`Orbit: member ${id} registration refused (${reason}) but the abort signal could not be confirmed; the member may still start\n`);
    if (!refusal.ok) process.stderr.write(`Orbit: member ${id} refused (${recordedReason}) but refusal record failed: ${refusal.reason}\n`);
    // Never let a refused or failed request linger: a later unrelated
    // registration (e.g. a revived parked agent) must not be misattributed.
    requestedNames.delete(id);
    const base = id.replace(/-\d+$/, '');
    if (requestedNames.has(base)) requestedNames.delete(base);
  }
  const ACTIVE = new Set(['starting', 'running']);
  // A binding is only usable while the task it names is still active and still
  // belongs to this Root session. Unknown or terminal states, other providers,
  // and stale bindings are all refused (and cleared), so members never
  // register into a finished or foreign task.
  async function boundTask(sessionId) {
    const taskDir = taskDirs.get(sessionId);
    if (!taskDir) return { ok: false, reason: 'Start Orbit for this session before delegating (orbit action=start)' };
    let state;
    try {
      state = JSON.parse(await fs.readFile(path.join(taskDir, 'state.json'), 'utf8'));
    } catch (error) {
      return { ok: false, reason: `The bound Orbit task record is unreadable (${String(error?.message || error)}); refusing dispatch` };
    }
    if (!ACTIVE.has(state.status) || state.connection?.provider !== 'omp' || state.connection?.thread_id !== sessionId) {
      taskDirs.delete(sessionId);
      return { ok: false, reason: 'The bound Orbit task is not active for this Root; start a new Orbit task before delegating' };
    }
    return { ok: true, taskDir };
  }
  // Member read/stop operations must survive terminal task states: an
  // explicit stop retry after stop_unconfirmed (or a failed runtime) still
  // needs member_state/member_result/stop_member by durable id. Unlike the
  // dispatch gate this never clears the binding, and it accepts the states
  // where收尾 retry is meaningful. `requireActive` (send_member) keeps the
  // stricter active-only rule but also does not mutate the binding.
  async function memberTaskFor(sessionId, memberId, { requireActive }) {
    const taskDir = memberTasks.get(memberId) ?? taskDirs.get(sessionId);
    if (!taskDir) throw new Error(`member ${memberId} is not owned by this task`);
    let state;
    try {
      state = JSON.parse(await fs.readFile(path.join(taskDir, 'state.json'), 'utf8'));
    } catch (error) {
      throw new Error(`member ${memberId}: bound task record unreadable (${String(error?.message || error)})`);
    }
    if (state.connection?.provider !== 'omp' || state.connection?.thread_id !== sessionId)
      throw new Error(`member ${memberId} does not belong to the requester's session`);
    if (requireActive) {
      if (!ACTIVE.has(state.status)) throw new Error(`member ${memberId}: task is ${state.status}; refusing member delivery`);
    } else if (!['starting', 'running', 'failed', 'stop_unconfirmed'].includes(state.status)) {
      throw new Error(`member ${memberId}: task is ${state.status}; no retry applies`);
    }
    return taskDir;
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
  function memberRoster() {
    let refs = [];
    try { refs = sdk.AgentRegistry.global().list(); } catch { return []; }
    return refs
      .filter(ref => nativeMemberIds.has(ref.id))
      .map(ref => ({ id: ref.id, status: ref.status, kind: ref.kind, parent_id: ref.parentId ?? null,
        model: ref.session?.model ? `${ref.session.model.provider}/${ref.session.model.id}` : (ref.history?.resolvedModel ?? null),
        activity: ref.activity ?? null, output_path: ref.history?.outputPath ?? null,
        registered: true }));
  }
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  // Delivery ACK is based on OBSERVABLE acceptance: the message with THIS
  // marker must appear in the session branch. sendCustomMessage's promise is
  // unusable for that — while idle with triggerTurn it awaits the whole
  // initiated prompt (model latency), so awaiting it made busy-session
  // corrections time out at the control RPC. triggerTurn stays true: an idle
  // Root must wake. Late rejections after acceptance are recorded, not
  // swallowed.
  const deliveryAckMs = () => parseInt(process.env.ORBIT_DELIVERY_ACK_MS || '8000', 10);
  const memberDeliveryErrors = new Map(); // member id -> late delivery error
  // ACK state machine, per OMP 18.2.8 #dispatchCustomMessage semantics:
  // - Streaming: agent.steer() queues the message and the promise resolves
  //   promptly (false). The branch entry appears only when the queued steer
  //   is consumed at a step boundary, which can outlast any RPC window — so a
  //   fast resolve while streaming IS the acceptance signal (steer queue).
  // - Idle with triggerTurn: the promise awaits the whole initiated prompt, so
  //   it stays pending; acceptance must be observed as THIS marker appearing
  //   in the session branch (the message is appended before the turn runs).
  // - A promise that resolves false while IDLE returned from preflight
  //   without accepting (generation change / hidden queue / deferral): fail.
  // - Neither within the window: fail closed. Late rejections after an ACK
  //   are recorded via onLateError, never swallowed.
  async function deliverCustomMessage(session, text, onLateError) {
    const marker = randomUUID();
    const payload = { customType: 'orbit', content: text, display: true, details: { orbitMessage: marker } };
    let submitted;
    try {
      submitted = session.sendCustomMessage(payload, { triggerTurn: true, deliverAs: 'steer' });
    } catch (error) {
      throw new Error(`OMP message delivery failed: ${error.message}`);
    }
    submitted?.catch?.(error => onLateError(`message ${marker} delivery failed: ${error.message}`));
    const outcome = await new Promise((resolve, reject) => {
      const started = Date.now();
      let settled = false;
      const finish = (fn, value) => { if (!settled) { settled = true; clearInterval(timer); fn(value); } };
      const timer = setInterval(() => {
        try {
          const branch = session.sessionManager?.getBranch?.() || [];
          const hit = branch.some(item => item.type === 'custom_message' && item.customType === 'orbit'
            && item.details?.orbitMessage === marker);
          if (hit) return finish(resolve, { via: 'branch' });
          if (Date.now() - started > deliveryAckMs())
            return finish(reject, new Error(`delivery not accepted within ${deliveryAckMs()}ms`));
        } catch (error) { finish(reject, error); }
      }, 100);
      Promise.resolve(submitted).then(value => {
        // Resolution can race the branch poll: a synchronously appended marker
        // must win over the streaming/value heuristics.
        try {
          const branchNow = session.sessionManager?.getBranch?.() || [];
          if (branchNow.some(item => item.type === 'custom_message' && item.customType === 'orbit'
            && item.details?.orbitMessage === marker)) return finish(resolve, { via: 'branch' });
        } catch { /* fall through to the heuristics */ }
        if (session.isStreaming === true) return finish(resolve, { via: 'steer-queue' });
        if (value === true) return finish(resolve, { via: 'turn-started' });
        return finish(reject, new Error('message discarded by the session before acceptance (preflight returned without accepting)'));
      }).catch(error => {
        // Late transport failure AFTER the marker landed still counts as
        // accepted delivery; the error itself is surfaced via onLateError.
        try {
          const branchNow = session.sessionManager?.getBranch?.() || [];
          if (branchNow.some(item => item.type === 'custom_message' && item.customType === 'orbit'
            && item.details?.orbitMessage === marker)) return finish(resolve, { via: 'branch' });
        } catch { /* fall through to the failure */ }
        finish(reject, error);
      });
    });
    return { id: marker, action: 'native_custom_message', delivery: 'accepted', ...outcome };
  }
  async function send(entry, text) {
    entry.pending++;
    entry.error = null;
    if (entry.root) entry.interrupted = false;
    try {
      return await deliverCustomMessage(entry.session, text, message => { entry.error = message; });
    } catch (error) {
      entry.error = error.message;
      throw error;
    } finally {
      entry.pending--;
    }
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
  // Member-scoped bridge: native task members have no `entries` record (no
  // Orbit-owned session id); they are addressed by their ACTUAL OMP agent id
  // as recorded in the task's members.json. Shapes:
  //   member_state  { id } ->
  //     { id, registry_status, streaming, model, activity, session_id,
  //       session_file, output_path, active_tools, async_jobs }
  //   member_result { id } ->
  //     { id, registry_status, output_path, output_text (bounded 2000 chars) }
  //   send_member   { id, text } -> { id, action: 'native_custom_message' }
  //     (steer custom message; reaches waiting members like Root corrections)
  //   stop_member   { id } ->
  //     { confirmed, id, scope, status_after, active_tools_after,
  //       async_jobs_settled }  — aborts the turn, cancels owner-scoped async
  //     jobs and REAPS them; a settle timeout throws instead of reporting
  //     success. Parked/never-started members (no live session) error.
  async function memberDispatch(request) {
    const ref = sdk.AgentRegistry.global().get(request.id);
    if (!ref || !nativeMemberIds.has(ref.id))
      throw new Error(`member is not owned by this task: ${request.id}`);
    const requireActive = request.method === 'send_member';
    await memberTaskFor(request.session, ref.id, { requireActive });
    if (ref.session) trackMemberTools(ref.id, ref.session);
    const session = ref.session;
    switch (request.method) {
      case 'member_state':
        if (!session) return { id: ref.id, registry_status: ref.status, streaming: null, model: ref.history?.resolvedModel ?? null,
          activity: ref.activity ?? null, session_id: null, session_file: ref.sessionFile, output_path: ref.history?.outputPath ?? null,
          active_tools: null, async_jobs: null, session_attached: false,
          lifecycle: ref.lifecycle ?? null };
        return { id: ref.id, registry_status: ref.status, streaming: session.isStreaming === true,
          model: session.model ? `${session.model.provider}/${session.model.id}` : (ref.history?.resolvedModel ?? null),
          activity: ref.activity ?? null, session_id: session.sessionId, session_file: ref.sessionFile,
          output_path: ref.history?.outputPath ?? null,
          active_tools: memberActiveTools.has(ref.id) ? memberActiveTools.get(ref.id).size : null,
          async_jobs: session.getAsyncJobSnapshot ? session.getAsyncJobSnapshot() : null,
          session_attached: true, lifecycle: ref.lifecycle ?? null,
          last_delivery_error: memberDeliveryErrors.get(ref.id) ?? null };
      case 'member_result': {
        const outputPath = ref.history?.outputPath ?? null;
        let outputText = null;
        if (outputPath) {
          try { outputText = (await fs.readFile(outputPath, 'utf8')).slice(0, 2000); }
          catch { outputText = null; }
        }
        return { id: ref.id, registry_status: ref.status, output_path: outputPath, output_text: outputText };
      }
      case 'send_member': {
        if (!session) throw new Error(`member session is not live: ${ref.id}`);
        if (typeof request.text !== 'string' || !request.text.trim()) throw new Error('send_member requires text');
        return deliverCustomMessage(session, request.text, message => memberDeliveryErrors.set(ref.id, message));
      }
      case 'stop_member': {
        if (!session) {
          // The member's session is gone. In 18.2.8, park()/release() detach
          // the session and set status first, then dispose asynchronously
          // (registry/agent-lifecycle.ts:310-319, :474-489) with no public
          // completion signal — so a parked/disposed ref cannot prove its
          // background work or child processes have exited. Report structured
          // evidence and let the runtime keep stop_unconfirmed; never convert
          // "completed"/registry idle into a stop confirmation.
          const lifecycle = ref.lifecycle ?? {};
          const completed = Boolean(lifecycle.acceptedAt || lifecycle.terminalAt || lifecycle.responseAt || ref.history?.outputPath);
          return { confirmed: false, id: ref.id,
            registry_status: ref.status,
            reason: completed
              ? `member result was accepted, but its session is disposed (status ${ref.status}) and OMP 18.2.8 disposes parked/released sessions asynchronously with no public completion signal; background/process exit is unverifiable from the registry`
              : `member has no live session (status ${ref.status}); stop cannot be confirmed without a session or a dispose-completion signal`,
            evidence: { registry_status: ref.status, lifecycle,
                        output_path: ref.history?.outputPath ?? null, session_file: ref.sessionFile },
            async_jobs_settled: null };
        }
        const manager = session.asyncJobManager, owner = session.getAgentId ? session.getAgentId() : ref.id;
        if (!owner) throw new Error(`OMP member session has no native async-work owner: ${ref.id}`);
        const busyFlags = s => s.isStreaming || s.isCompacting || s.isBashRunning || s.isEvalRunning || s.hasPendingAsyncWork?.();
        const busy = busyFlags(session);
        // Tool-state tracking started only now cannot account for execution
        // that began earlier; never confirm a stop on such a partial view.
        const preTracked = memberActiveTools.has(ref.id);
        if (ref.session) trackMemberTools(ref.id, ref.session);
        if (manager) manager.cancelAll({ ownerId: owner });
        if (busy) await session.abort({ goalReason: 'internal' });
        if (manager && !(await manager.cancelAndReapOwnerJobs(owner, Date.now() + 5000)).settled)
          throw new Error(`OMP member background processes did not settle for ${ref.id}`);
        if (busy && !preTracked)
          throw new Error(`OMP member tool state unconfirmed for ${ref.id} (tracking began after execution)`);
        for (let n = 0; n < 50; n++) {
          if (!busyFlags(session)) {
            // Confirm with an OBSERVED tool-state measurement, not a constant.
            const measured = memberActiveTools.has(ref.id) ? memberActiveTools.get(ref.id).size : null;
            if (measured !== 0)
              throw new Error(`OMP member tool state unconfirmed for ${ref.id} (active_tools=${measured === null ? 'unobserved' : measured})`);
            stoppedMembers.add(ref.id);
            return { confirmed: true, id: ref.id,
              scope: 'Member turn, attached shell processes and owner-scoped async jobs; no unmanaged detached work',
              registry_status: sdk.AgentRegistry.global().get(ref.id)?.status ?? null,
              status_after: busyFlags(session) ? 'active' : 'idle', active_tools_after: measured, async_jobs_settled: true };
          }
          await pause(100);
        }
        throw new Error(`OMP member execution did not stop for ${ref.id}`);
      }
      default: throw new Error('Unknown member operation');
    }
  }
  const MEMBER_METHODS = new Set(['member_state', 'member_result', 'send_member', 'stop_member']);
  // Billing route is a structural proof, never a provider-name list: the
  // resolved @task model must point at a first-party HTTPS endpoint verified
  // against the bundled pi-catalog descriptors (host plus path prefix) and must
  // not be forwarded through an auth gateway (`transport: pi-native`). Only the
  // sanitized label leaves this process; the resolved URL is never serialized.
  // Other plan services (github-copilot, minimax-code, qwen-portal, the
  // alibaba/xiaomi plans) stay unknown until their first-party plan endpoints
  // are verified the same way.
  const ROUTE_ENDPOINT_PROOFS = [
    { route: 'direct_api', provider: 'deepseek', host: 'api.deepseek.com' },
    { route: 'subscription_quota', provider: 'zhipu-coding-plan', host: 'open.bigmodel.cn', pathPrefix: '/api/coding/' },
    { route: 'subscription_quota', provider: 'kimi-code', host: 'api.kimi.com', pathPrefix: '/coding/' }
  ];
  function endpointParts(baseUrl) {
    if (typeof baseUrl !== 'string' || !baseUrl.trim()) return null;
    try {
      const url = new URL(baseUrl);
      // First-party proof is HTTPS-only: a plain-http endpoint is not the
      // official API/plan transport and stays unknown.
      if (url.protocol !== 'https:') return null;
      const host = url.hostname.toLowerCase();
      return host ? { host, path: url.pathname || '/' } : null;
    } catch { return null; }
  }
  function billingRoute(resolved) {
    const provider = typeof resolved?.provider === 'string' ? resolved.provider.trim() : '';
    if (!provider || resolved?.transport === 'pi-native') return 'unknown';
    const parts = endpointParts(resolved?.baseUrl);
    if (!parts) return 'unknown';
    const proof = ROUTE_ENDPOINT_PROOFS.find(candidate =>
      candidate.provider === provider && candidate.host === parts.host &&
      (!candidate.pathPrefix || parts.path.startsWith(candidate.pathPrefix)));
    return proof ? proof.route : 'unknown';
  }
  function memberModel() {
    const resolve = currentContext?.models?.resolve;
    if (typeof resolve !== 'function') throw new Error('native task model is unresolved: models.resolve is unavailable');
    const resolved = resolve('@task');
    const provider = typeof resolved?.provider === 'string' ? resolved.provider.trim() : '';
    const id = typeof resolved?.id === 'string' ? resolved.id.trim() : '';
    if (!provider || !id) throw new Error('native task model is unresolved: @task did not resolve to a provider/id');
    return { provider, id, billing_route: billingRoute(resolved) };
  }
  async function dispatch(request) {
    if (typeof request.method === 'string' && MEMBER_METHODS.has(request.method)) return memberDispatch(request);
    const entry = owned(request.session);
    switch (request.method) {
      case 'state': return state(entry);
      case 'messages': return messages(entry);
      case 'model': return `${entry.session.model.provider}/${entry.session.model.id}`;
      case 'member_model': return memberModel();
      case 'send': return send(entry, request.text);
      case 'stop': return stop(entry);
      // Simple readable interface for TaskRuntime wiring (M1.x): the native
      // member roster and recent native hub traffic.
      case 'members': return memberRoster();
      case 'hub_events': {
        // Task-scoped read: only events bound to the requester's task. An
        // event observed before any binding (or from an unbound session) is
        // never attributed to a task from this buffer.
        // Shape for TaskRuntime (M1.1): { events, dropped_oldest, next_seq,
        // buffer_cap }. Sequences are PER TASK and gap-free: a jump in seq or
        // dropped_oldest growth is a real observation loss signal for that
        // task. The buffer is in-process and bounded; consumers must poll
        // promptly, and events are NOT durable across an OMP exit.
        const taskDir = taskDirs.get(request.session);
        if (!taskDir) throw new Error('hub_events requires a bound task session');
        return { events: collabEvents.filter(entry => entry.task_dir === taskDir),
                 dropped_oldest: collabDroppedByTask.get(taskDir) ?? 0,
                 next_seq: (collabSeqByTask.get(taskDir) ?? 0) + 1, buffer_cap: COLLAB_CAP };
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
    for (const entry of entries.values()) entry.unsubscribe();
    entries.clear();
  }

  // Native task gate: intercept Root's model-issued task dispatches, assign the
  // requested identity, and bind it to the current task. Members calling task
  // are refused (one-level delegation, independent of depth configuration).
  pi.on('tool_call', async (event, ctx) => {
    if (event.toolName !== 'task') return;
    const input = event.input;
    if (!input || typeof input !== 'object') return;
    const sessionId = ctx.sessionManager.getSessionId();
    // Only the verified main agent may dispatch. An unresolvable caller
    // (registry miss/exception) is NOT treated as Root: fail closed.
    const caller = agentIdFor(sessionId);
    if (process.env.ORBIT_GATE_DEBUG) process.stderr.write(`Orbit gate: tool_call task caller=${caller ?? 'unresolved'} session=${sessionId}\n`);
    if (caller !== sdk.MAIN_AGENT_ID)
      return { block: true, reason: caller ? 'Execution members cannot dispatch tasks (one-level delegation)' : 'Task dispatch refused: caller identity is not the verified Root' };
    if (!subscribeRegistryGate())
      return { block: true, reason: 'Orbit member registration gate is unavailable in this OMP session; refusing task dispatch' };
    const bound = await boundTask(sessionId);
    if (!bound.ok) return { block: true, reason: bound.reason };
    const taskDir = bound.taskDir;
    const items = Array.isArray(input.tasks) && input.tasks.length ? input.tasks : [input];
    for (const item of items) {
      if (!item || typeof item !== 'object') continue;
      const requested = `orbit-${randomUUID()}`;
      item.name = requested;
      requestedNames.set(requested, { taskDir, toolCallId: event.toolCallId ?? null });
    }
    return { input };
  });
  // Native collaboration observation (M1.1): hub call intents carry the wire
  // content (op/to/from/message) at tool_call time; results carry what came
  // back. This is real observed traffic, not a start-boundary stub.
  pi.on('tool_call', async (event, ctx) => {
    if (event.toolName !== 'hub') return;
    const sessionId = ctx.sessionManager.getSessionId();
    const input = event.input || {};
    observeCollab({ kind: 'hub_call', at: Date.now(), session_id: sessionId,
      agent_id: agentIdFor(sessionId), tool_call_id: event.toolCallId ?? null,
      op: input.op ?? null, to: input.to ?? null, from: input.from ?? null,
      reply_to: input.replyTo ?? null, await_reply: input.await === true,
      message: typeof input.message === 'string' ? input.message.slice(0, 2000) : null });
    // Stop stability: a member Orbit confirmed stopped, or one addressed
    // while its task is no longer active, must not be re-woken through the
    // native hub. Only applies to this task's registered members.
    if (input.op === 'send' && typeof input.to === 'string' && memberTasks.has(input.to)) {
      if (stoppedMembers.has(input.to))
        return { block: true, reason: `member ${input.to} was stopped for this Orbit task; refusing to wake it` };
      try {
        const state = JSON.parse(await fs.readFile(path.join(memberTasks.get(input.to), 'state.json'), 'utf8'));
        if (!ACTIVE.has(state.status))
          return { block: true, reason: `Orbit task is ${state.status}; refusing to wake member ${input.to}` };
      } catch {
        return { block: true, reason: 'Orbit task state unreadable; refusing to wake a registered member' };
      }
    }
  });
  pi.on('tool_result', async (event, ctx) => {
    if (event.toolName === 'hub') {
      const text = Array.isArray(event.content)
        ? event.content.filter(p => p.type === 'text').map(p => p.text).join(' ').slice(0, 2000) : null;
      observeCollab({ kind: 'hub_result', at: Date.now(), session_id: ctx.sessionManager.getSessionId(),
        agent_id: agentIdFor(ctx.sessionManager.getSessionId()), tool_call_id: event.toolCallId ?? null,
        ok: event.isError === false, text });
      return;
    }
    if (event.toolName === 'task') {
      const text = Array.isArray(event.content)
        ? event.content.filter(p => p.type === 'text').map(p => p.text).join(' ').slice(0, 2000) : null;
      observeCollab({ kind: 'task_result', at: Date.now(), session_id: ctx.sessionManager.getSessionId(),
        agent_id: agentIdFor(ctx.sessionManager.getSessionId()), tool_call_id: event.toolCallId ?? null,
        ok: event.isError === false, text });
    }
  });

  pi.registerTool({ name: 'orbit', label: 'Orbit', description: toolDescription, parameters: pi.zod.object(toolArgs(pi.zod)),
    async execute(_id, args, _signal, _update, ctx) {
      const entry = await connect(ctx);
      const text = await host.execute(args, ctx);
      try {
        const result = JSON.parse(text);
        if (typeof result.task_directory === 'string') taskDirs.set(entry.id, result.task_directory);
      } catch { /* non-JSON results carry no task binding */ }
      return { content: [{ type: 'text', text }], details: {} };
    }
  });
  pi.on('session_start', (_event, ctx) => { rootFor(ctx); subscribeRegistryGate(); });
  pi.on('session_shutdown', () => close());
  for (const event of ['session_before_switch', 'session_before_branch', 'session_before_tree']) pi.on(event, async () => {
    try { await close(true); }
    catch (error) { currentContext?.ui.notify(error.message, 'error'); return { cancel: true }; }
  });
}

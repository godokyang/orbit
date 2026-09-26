import fs from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createOrbitHost, toolArgs, toolDescription } from './host.mjs';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const textOf = content => typeof content === 'string' ? content : (content || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
// Internal synchronous registration entry (TaskRecord-backed, atomic+durable).
// Overridable in tests; production resolves next to this file.
const registerMemberBin = process.env.ORBIT_REGISTER_MEMBER_BIN
  || fileURLToPath(new URL('../scripts/orbit-register-member', import.meta.url));
// Pool edits must run THIS release's CLI, never whatever `orbit` happens to
// be first on PATH (an older install would write a stale schema/format).
// Same release-anchored, ruby-invoked shape as the member registration entry.
const orbitCliBin = fileURLToPath(new URL('../scripts/orbit', import.meta.url));
const rubyBin = () => process.env.ORBIT_RUBY || 'ruby';

// Generated member agent namespace (ADR-009). Readable slug plus a stable
// short hash: distinct identifiers that collide after non-alphanumeric
// folding (e.g. `provider/a.b` vs `provider/a-b`) must never share one agent
// name, or the mapping would silently dispatch the wrong pinned model.
export const AGENT_NAME_PREFIX = 'orbit-m-';
export function agentNameFor(model) {
  const slug = model.replace(/[^A-Za-z0-9_-]+/g, '-');
  const hash = createHash('sha1').update(model).digest('hex').slice(0, 8);
  return `${AGENT_NAME_PREFIX}${slug}-${hash}`;
}

// Process-wide member state, deliberately MODULE-scoped: OMP's task executor
// re-binds every extension factory against each child session runtime
// (packages/coding-agent/src/task/executor.ts ~508-519), so a closure-scoped
// map is invisible to a re-bound child handler — the real 2026-09-25 drift
// probe showed the child-side before_provider_request matching nothing and
// staying silent while an override-drifted member ran to completion. The
// AgentRegistry itself is process-global; these mirrors must be too.
const nativeMemberIds = new Set();
const memberTasks = new Map();
const memberExpectedModels = new Map();
const memberDriftReported = new Set();
const memberActiveTools = new Map(); // member agent id -> Set of in-flight tool call ids (observed)
// Verified stop confirmations keyed by member id. stop_member must be
// idempotent: TaskRuntime retries and follow-up stops re-query a member whose
// retained session has already been disposed, and re-confirmation is
// impossible once the evidence (live session / retained reference) is gone.
// Returning the cached VERIFIED result repeats no inference; stoppedMembers
// independently keeps native hub wake blocked.
const memberStopConfirmations = new Map();
// Member sessions retained by member id until a CONFIRMED stop, captured at
// whichever seam sees the attached session first: the AgentRegistry
// `registered` window when the session is already attached, or the member's
// `before_provider_request` hook after OMP's silent attachSession (which
// emits no registry event, agent-registry.ts ~290-304). Either way the
// capture provably precedes member provider dispatch. OMP 18.2.8 can detach
// (park/abort) the registry ref with no public dispose-completion signal, so
// the retained reference lets stop_member make REAL observations (busy
// flags, tracked active tools, owner-scoped async-job reaping, idempotent
// dispose) instead of inferring from a tombstone. Entries are removed only
// on confirmed stop.
const memberRetainedSessions = new Map();

// Native ask call observation, also MODULE-scoped for the same re-binding
// reason: question excerpts are cached from the tool_execution_start events
// of the SAME session that later reports the skip, but the subscriptions that
// see them can be installed by different extension closures (root remember()
// vs a re-bound child trackMemberTools backstop). Bounded FIFOs: a long
// session must not accumulate unbounded ask-call state.
const askCallArgs = new Map();      // tool call id -> bounded question excerpt
const askEmittedEvents = new Set(); // tool call ids already emitted (once-only)
const ASK_CACHE_CAP = 200;
function rememberAskArgs(event) {
  if (event.toolName !== 'ask' || typeof event.toolCallId !== 'string') return;
  const questions = event.args?.questions;
  if (!Array.isArray(questions) || !questions.length) return;
  const texts = questions
    .filter(question => question && typeof question.question === 'string' && question.question.trim())
    .map(question => question.question.trim());
  if (!texts.length) return;
  askCallArgs.set(event.toolCallId, texts.join(' / ').slice(0, 200));
  if (askCallArgs.size > ASK_CACHE_CAP) askCallArgs.delete(askCallArgs.keys().next().value);
}

// --- ADR-009 keyboard multi-select picker (proposal B, 2026-09-26) --------
// Pure component over ctx.ui.custom(): no OMP imports, no IO. The extension
// command supplies entries (session-available first, pooled-but-unavailable
// last), the opening snapshot and an async commit; the component owns search,
// cursor/scroll, checkbox state and the ONE Enter-driven net-delta submit.
// Space on an unavailable row can only uncheck (stale pool entries are
// removable, never addable); Esc closes without writing; a failed commit
// keeps the selection on screen with the error so nothing must be re-picked.
const PICKER_MAX_QUERY = 64;
const PICKER_LIST_ROWS = 12;

// Raw terminal data -> canonical key. Covers the legacy sequences OMP's TUI
// forwards plus the kitty CSI-u forms for the bound keys; anything else is
// ignored (returns null) so unknown escapes can never corrupt the query.
export function decodePickerKey(data) {
  if (typeof data !== 'string' || !data.length) return null;
  switch (data) {
    case '\r': case '\n': return 'enter';
    case ' ': return 'space';
    case '\x7f': case '\b': return 'backspace';
    case '\x1b': case '\x03': return 'escape'; // bare Esc; ctrl+c cancels like Esc
    case '\x1b[A': case '\x1bOA': return 'up';
    case '\x1b[B': case '\x1bOB': return 'down';
    case '\x1b[5~': return 'pageUp';
    case '\x1b[6~': return 'pageDown';
    default: break;
  }
  const kitty = data.match(/^\x1b\[(\d+)(?::\d+)?u$/);
  if (kitty) {
    return { 13: 'enter', 32: 'space', 27: 'escape', 127: 'backspace' }[Number(kitty[1])] ?? null;
  }
  if (data.length === 1) {
    const code = data.charCodeAt(0);
    return code >= 0x20 && code <= 0x7e ? `text:${data}` : null;
  }
  return null;
}

// Case-insensitive subsequence match: typing glm52 finds zhipu/glm-5.2 the
// way OMP's own model picker narrows by provider/id.
function pickerQueryMatches(id, query) {
  const wanted = query.toLowerCase();
  let at = 0;
  for (const ch of id.toLowerCase()) {
    if (ch === wanted[at]) at++;
    if (at === wanted.length) return true;
  }
  return at === wanted.length;
}

// The net delta Enter submits: adds are unchecked rows that are selectable
// RIGHT NOW; removals are snapshot rows the user unchecked (available or
// stale alike — stale entries only ever leave the pool).
export function pickerNetDelta(entries, snapshot, selected) {
  const available = new Set(entries.filter(entry => entry.available).map(entry => entry.id));
  const add = [...selected].filter(id => !snapshot.has(id) && available.has(id));
  const remove = [...snapshot].filter(id => !selected.has(id));
  return { add, remove };
}

export function createModelPicker({ entries, snapshot, commit, done, listRows = PICKER_LIST_ROWS }) {
  const rowFor = new Map(entries.map(entry => [entry.id, { id: entry.id, available: entry.available === true }]));
  let current = [...rowFor.values()];
  let selected = new Set([...snapshot].filter(id => rowFor.has(id)));
  let base = new Set(snapshot);
  let query = '';
  let cursor = 0;
  let scroll = 0;
  let notice = null;
  let error = null;
  let committing = false;
  let closed = false;
  const finish = result => { if (!closed) { closed = true; done(result); } };

  const filtered = () => query ? current.filter(entry => pickerQueryMatches(entry.id, query)) : current;
  const clampCursor = () => {
    const rows = filtered();
    if (!rows.length) { cursor = 0; scroll = 0; return; }
    cursor = Math.min(cursor, rows.length - 1);
    if (cursor < scroll) scroll = cursor;
    if (cursor >= scroll + listRows) scroll = cursor - listRows + 1;
  };

  function render(width) {
    const rows = filtered();
    const availableCount = current.filter(entry => entry.available).length;
    const delta = pickerNetDelta(current, base, selected);
    const head = [
      `候选模型池 · 已选 ${selected.size} / 当前可选 ${availableCount}` +
        (delta.add.length || delta.remove.length
          ? ` · 本次待新增 ${delta.add.length} 待移出 ${delta.remove.length}` : ''),
      `搜索: ${query || '（输入即过滤）'}`,
    ];
    const body = [];
    if (rows.length) {
      const start = Math.max(0, scroll);
      const stop = Math.min(rows.length, start + listRows);
      for (let index = start; index < stop; index++) {
        const entry = rows[index];
        const mark = selected.has(entry.id) ? '[x]' : '[ ]';
        const pointer = index === cursor ? '>' : ' ';
        const tag = entry.available ? '' : '  · 当前不可选，仅可移出';
        body.push(`${pointer} ${mark} ${entry.id}${tag}`);
      }
      if (rows.length > stop) body.push(`  … 还有 ${rows.length - stop} 项（继续 ↓）`);
      if (start > 0) body.unshift(`  … 以上还有 ${start} 项（继续 ↑）`);
    } else {
      body.push(query ? '（无匹配模型；Backspace 删词后重试）' : '（当前会话没有可选模型）');
    }
    const statusLine = error ? `保存失败：${error}` : notice ? `提示：${notice}` : null;
    const footer = [
      '↑/↓ 移动  Space 勾选/取消  Backspace 删除搜索  Enter 保存  Esc 取消',
      ...(statusLine ? [statusLine] : []),
    ];
    return [...head, ...body, ...footer].map(line => line.length > width ? line.slice(0, width - 1) + '…' : line);
  }

  async function submit() {
    const delta = pickerNetDelta(current, base, selected);
    if (!delta.add.length && !delta.remove.length) return finish({ status: 'noop' });
    committing = true;
    error = null;
    notice = '正在保存……';
    try {
      // The snapshot this delta was computed against travels WITH the commit:
      // after a failure-refresh the picker's base may differ from the pool
      // state at open, and the pool must compare against exactly what the
      // user saw when they pressed Enter.
      const result = await commit({ add: delta.add, remove: delta.remove, base: [...base] });
      if (result && result.ok) return finish({ status: 'committed', add: delta.add, remove: delta.remove, models: result.models });
      error = (result && result.error) || '保存失败（未知原因）';
      if (result && Array.isArray(result.entries)) {
        rowFor.clear();
        for (const entry of result.entries) rowFor.set(entry.id, { id: entry.id, available: entry.available === true });
        current = [...rowFor.values()];
        selected = new Set([...selected].filter(id => rowFor.has(id)));
      }
      if (result && Array.isArray(result.snapshot)) base = new Set(result.snapshot);
    } catch (failure) {
      error = String(failure?.message || failure);
    } finally {
      committing = false;
      notice = null;
      clampCursor();
    }
  }

  function handleInput(data) {
    const key = decodePickerKey(data);
    if (!key || closed || committing) return;
    if (key === 'escape') return finish({ status: 'cancelled' });
    if (key === 'enter') { void submit(); return; }
    if (key === 'backspace') { query = query.slice(0, -1); error = null; notice = null; clampCursor(); return; }
    if (key.startsWith('text:')) {
      if (query.length < PICKER_MAX_QUERY) { query += key.slice(5); error = null; notice = null; clampCursor(); }
      return;
    }
    const rows = filtered();
    if (!rows.length) return;
    if (key === 'up' || key === 'down') {
      cursor = (cursor + (key === 'up' ? -1 : 1) + rows.length) % rows.length;
    } else if (key === 'pageUp' || key === 'pageDown') {
      const step = Math.max(1, listRows - 1);
      cursor = Math.min(rows.length - 1, Math.max(0, cursor + (key === 'pageUp' ? -step : step)));
    } else if (key === 'space') {
      const entry = rows[cursor];
      if (selected.has(entry.id)) { selected.delete(entry.id); error = null; notice = null; }
      else if (entry.available) { selected.add(entry.id); error = null; notice = null; }
      else { notice = `${entry.id} 当前不可选，只能移出，不能新增`; }
    }
    clampCursor();
  }

  return { render, handleInput, dispose() { closed = true; }, debugId: 'orbit-model-picker' };
}

// The SDK is supplied by OMP itself, including in its standalone binary.
export function installOmpExtension(pi, sdk) {
  const entries = new Map();
  // Requested spawn name -> { taskDir, toolCallId, expectedModel }. The
  // registry gate matches registered ids against this map: exact match is the
  // expected identity, a suffixed match (`<name>-2`) is allocator drift and
  // must be refused. Member id/task/expected-model maps themselves live at
  // module scope: the OMP child runtime re-binds this factory per subagent,
  // and closure state would be invisible to a re-bound child handler.
  const requestedNames = new Map();
  const stoppedMembers = new Set(); // member ids whose stop was CONFIRMED via the live-session path
  const taskDirs = new Map();       // root session id -> task directory (bound via orbit start/context)
  const statusBoundTasks = new Map(); // root session id -> task directory recovered from durable records (status display only)
  const collabEvents = [];          // native hub traffic + native task results (bounded, readable via dispatch)
  const COLLAB_CAP = 500;
  const collabSeqByTask = new Map();    // task_dir -> last assigned seq (per-task, gap-free)
  const collabDroppedByTask = new Map(); // task_dir -> count of dropped oldest events
  let lastKnownPool = null; // last successful pool read (status display only; never a second pool state)
   let host, currentContext, registryHookInstalled;

  // --- ADR-009: user-selected model pool + session-isolated member agents ---
  // The pool only constrains what Orbit recommends. Root may still dispatch
  // any native agent explicitly (including out-of-pool ones); only dispatches
  // through OUR generated `orbit-m-*` agent names carry a pinned model that
  // must survive override/auth-fallback resolution.
  const sessionAgentRoot = process.env.ORBIT_SESSION_AGENT_ROOT || null;
  const sessionAgents = new Map();        // generated agent name -> 'provider/id' (per bound instance; rebuilt on sync)
  const poolBin = () => process.env.ORBIT_CLI_BIN || orbitCliBin;
  const poolArgv = args => (process.env.ORBIT_CLI_BIN ? [poolBin(), ['model-candidates', ...args]] : [rubyBin(), ['--disable-gems', poolBin(), 'model-candidates', ...args]]);
  const runPoolCli = args => {
    try {
      const [bin, argv] = poolArgv(args);
      const run = spawnSync(bin, argv, { encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
      if (run.status !== 0 || !run.stdout) return { ok: false, reason: ((run.stderr || run.error?.message || `exit ${run.status}`) || 'no output').trim().slice(0, 200) };
      const parsed = JSON.parse(run.stdout.trim().split('\n').at(-1));
      const models = Array.isArray(parsed?.models) ? parsed.models.filter(m => typeof m === 'string') : [];
      lastKnownPool = models;
      return { ok: true, models };
    } catch (error) {
      return { ok: false, reason: String(error?.message || error).slice(0, 200) };
    }
  };
  // Rewrite the session agent root from pool ∩ ctx.models.list(). Files are
  // re-read by OMP on every native task execution (resolveEffectiveSubagentPolicy
  // rediscovers agents), so runtime edits are picked up without a restart.
  // Nothing is written to project `.omp/agents` or the user agent directory.
  async function syncSessionAgents(ctx) {
    if (!sessionAgentRoot) return { ok: false, reason: 'ORBIT_SESSION_AGENT_ROOT is not set; dynamic member agents need the orbit omp entry' };
    const pool = runPoolCli(['list']);
    if (!pool.ok) return { ok: false, reason: `model pool unreadable: ${pool.reason}` };
    let available = [];
    try { available = (ctx.models?.list?.() ?? []).map(m => `${m.provider}/${m.id}`); } catch { available = []; }
    const availableSet = new Set(available);
    const desired = new Map();
    for (const model of pool.models) {
      if (!availableSet.has(model)) continue; // session intersection only (ADR-009)
      desired.set(agentNameFor(model), model);
    }
    const agentsDir = path.join(sessionAgentRoot, 'agents');
    await fs.mkdir(agentsDir, { recursive: true });
    for (const existing of await fs.readdir(agentsDir).catch(() => [])) {
      if (!existing.startsWith(AGENT_NAME_PREFIX) || !existing.endsWith('.md')) continue;
      if (!desired.has(existing.slice(0, -'.md'.length))) await fs.rm(path.join(agentsDir, existing), { force: true });
    }
    for (const [name, model] of desired) {
      const file = path.join(agentsDir, `${name}.md`);
      const body = ['---',
        `name: ${name}`,
        `description: Orbit member agent pinned to ${model} (generated for this session only)`,
        `model: ${model}`,
        'spawns: ""',
        '---', '',
        `You are an Orbit execution member. Your model is fixed to ${model} for this run.`,
        'Report results to Root through the native hub tool; you cannot dispatch further tasks.', '',
      ].join('\n');
      if ((await fs.readFile(file, 'utf8').catch(() => null)) === body) continue;
      // Atomic replace: a concurrent native task re-discovery re-reads this
      // directory, and a half-written frontmatter must never be observed.
      const tmp = path.join(agentsDir, `.${name}.${process.pid}.tmp`);
      await fs.writeFile(tmp, body);
      await fs.rename(tmp, file);
    }
    // In-flight members keep their resolved model: OMP only re-reads these
    // files when a NEW spawn is prefighted, never for a running session.
    sessionAgents.clear();
    for (const [name, model] of desired) sessionAgents.set(name, model);
    return { ok: true, agents: [...desired].map(([name, model]) => ({ name, model })) };
  }

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

  // --- Native Ask interruption observation (proposal A, 2026-09-26) -------
  // Verified against installed omp/18.3.2 (same surface as 18.2.8): when a
  // pending message must be serviced, the agent loop synthesizes
  // tool_execution_end events for calls the model emitted but never ran,
  // with result.details.source 'interrupt_skipped' — {__synthetic:true,
  // executed:false} when the call never invoked, {__interrupted:true,
  // execution:'started'} when it was interrupted after start — and content
  // text starting 'Skipped due to <reason>.'. The extension tool_result hook
  // does NOT run for these (no execute happened), so the session event stream
  // is the only reliable seam; both the Root and member subscriptions below
  // already ride it. Recorded ONLY for the native ask tool (name 'ask') and
  // only into the task-scoped collab buffer, so unbound sessions never
  // surface. ask_resolved marks a later non-error ask end from the same
  // agent: the runtime clears that agent's pending interrupts on it (a new
  // ask has a new call id; per-ask granularity is not observable upstream).
  // Orbit never answers or re-sends the question itself.
  function askSkippedSource(result) {
    const text = Array.isArray(result?.content)
      ? (result.content.find(part => part && part.type === 'text' && typeof part.text === 'string')?.text ?? '') : '';
    const match = typeof text === 'string' ? text.match(/^Skipped due to (.+?)\./) : null;
    return match ? match[1].slice(0, 120) : null;
  }
  const isInterruptSkip = details => details?.source === 'interrupt_skipped'
    && (details.__synthetic === true || (details.__interrupted === true && details.execution === 'started'));
  function observeAskEnd(event, sessionId, agentId) {
    if (event.toolName !== 'ask' || typeof event.toolCallId !== 'string') return;
    const question = askCallArgs.get(event.toolCallId) ?? null;
    askCallArgs.delete(event.toolCallId);
    if (askEmittedEvents.has(event.toolCallId)) return;
    if (event.isError === true && isInterruptSkip(event.result?.details)) {
      askEmittedEvents.add(event.toolCallId);
      observeCollab({ kind: 'ask_interrupted', at: Date.now(), session_id: sessionId, agent_id: agentId,
        tool_call_id: event.toolCallId, question, skipped_source: askSkippedSource(event.result),
        started: event.result?.details?.__interrupted === true });
      return;
    }
    if (event.isError !== true) {
      askEmittedEvents.add(event.toolCallId);
      observeCollab({ kind: 'ask_resolved', at: Date.now(), session_id: sessionId, agent_id: agentId,
        tool_call_id: event.toolCallId });
    }
  }

  function trackMemberTools(id, session) {
    if (memberActiveTools.has(id) || typeof session?.subscribe !== 'function') return;
    const active = new Set();
    memberActiveTools.set(id, active);
    session.subscribe(event => {
      if (event.type === 'tool_execution_start') {
        active.add(event.toolCallId);
        rememberAskArgs(event);
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
        observeAskEnd(event, session.sessionId ?? null, id);
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
      if (event.type === 'tool_execution_start') {
        entry.activeTools.add(event.toolCallId);
        rememberAskArgs(event);
      }
      if (event.type === 'tool_execution_end') {
        entry.activeTools.delete(event.toolCallId);
        // Ask observation only: the registry lookup is deliberately lazy so a
        // normal tool end never pays for it.
        if (event.toolName === 'ask') observeAskEnd(event, id, agentIdFor(id));
      }
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
      if (ref.session) {
        trackMemberTools(ref.id, ref.session);
        // Retain for observable stop confirmation after registry detachment.
        memberRetainedSessions.set(ref.id, ref.session);
      }
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
        if (pending.expectedModel) memberExpectedModels.set(ref.id, pending.expectedModel);
        requestedNames.delete(ref.id);
        // ADR-009 fail-closed model gate. The AgentRegistry `registered`
        // window provably precedes any member provider work, and the resolved
        // model is observable on the ref here: if task.agentModelOverrides
        // (or any other resolution) already changed the final model away from
        // the pinned pool model, record the drift durably and abort the
        // member NOW. The before_provider_request backstop alone is NOT a
        // proven suppression seam (real drift probe 2026-09-25: override to
        // grok-4.6 ran to completion with zero hook evidence), so the
        // registration boundary is the enforced gate.
        if (pending.expectedModel && ref.session?.model) {
          const actual = `${ref.session.model.provider}/${ref.session.model.id}`;
          if (actual !== pending.expectedModel && !memberDriftReported.has(ref.id)) {
            memberDriftReported.add(ref.id);
            const abortConfirmed = signalAbort(ref.id);
            const recorded = recordModelDrift(taskDir, { id: ref.id, expected: pending.expectedModel, actual, abortConfirmed });
            process.stderr.write(`Orbit: member ${ref.id} model drift at registration (${pending.expectedModel} -> ${actual}); ` +
              `drift record: ${recorded.ok ? 'ok' : recorded.reason}; abort confirmed: ${abortConfirmed}\n`);
          }
        }
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
  // --- Per-turn bound-task status (Zeen review steps 2/3) -------------------
  // The Root binding lives in process memory (taskDirs). After an OMP restart
  // or `--resume` (same session id: session-manager.ts header.id), it is
  // recovered from the durable task record by (provider, thread_id); the short
  // status is re-derived from state.json every user turn, never persisted as a
  // second state source. Display only: it does not adjudicate completion or
  // override the checker.
  const STATUS_MARKER = '[orbit-task-status]';
  const activeState = state => state && (state.status === 'starting' || state.status === 'running');
  const stopConfirmed = state => state?.stop_confirmation?.confirmed === true;
  const openFindings = state => {
    const findings = state?.findings;
    return findings && typeof findings === 'object'
      ? Object.values(findings).filter(finding => finding && finding.status === 'open').length : 0;
  };
  const recheckClues = state => Array.isArray(state?.recheck?.findings) ? state.recheck.findings.length : 0;
  const noticeCount = state => {
    const notices = state?.finalization_notices;
    return notices && typeof notices === 'object' ? Object.keys(notices).length : 0;
  };
  // Mirrors TaskView.runtime_abandoned?: a starting/running record whose
  // recorded runtime process is gone cannot consume queued commands. A recorded
  // finish without a positive pid is an exited runtime; without a recorded
  // finish a missing pid may only mean the runtime is still starting.
  function runtimeAbandoned(state) {
    if (!activeState(state)) return false;
    const pid = state?.runtime_pid;
    const finished = typeof state?.finished_at === 'string' && state.finished_at.length > 0;
    if (!(Number.isInteger(pid) && pid > 0)) return finished;
    try { process.kill(pid, 0); return false; }
    catch (error) { return error?.code === 'ESRCH'; }
  }
  function phaseLabel(state) {
    switch (state.status) {
      case 'complete': return '已完成（独立检查与收尾通过）';
      case 'paused': return '已暂停（已确认停止）';
      case 'needs_user': return '需用户处理（已确认停止）';
      case 'stop_unconfirmed': return '任务是否已停止还无法确认';
      case 'failed': return stopConfirmed(state) ? '运行失败（停止已确认）' : '运行失败（停止待核实）';
      default: break;
    }
    // A live status can outlive its runtime process. Never present that as an
    // execution phase: only the socket check plus a live runtime is control.
    if (runtimeAbandoned(state)) return '任务处理进程已退出，状态待清理';
    if (state.completion_stop_pending) return '正在结束任务（等待当前回复结束）';
    if (openFindings(state) > 0 || recheckClues(state) > 0) return '检查仍有待处理问题，尚未完成';
    if (state.pending_finalization) return '最终检查已结束，等待结果通知';
    // A stored notice can outlive the version it was issued for. Only the
    // completion gate can decide whether the current files still qualify.
    if (noticeCount(state) > 0) return '曾收到检查通过通知，任务尚未完成';
    return '执行中，尚未完成最终检查';
  }
  // Mirrors TaskView.next_action for display only. The durable record stays the
  // authority; this never decides completion.
  function nextActionLabel(state) {
    if (state.status === 'needs_user' || state.status === 'stop_unconfirmed') return '需要用户处理';
    if (state.status === 'failed') return stopConfirmed(state) ? '运行失败，停止已确认' : '运行失败，需核实停止';
    if (!activeState(state)) return null;
    if (state.completion_stop_pending) return '等待当前回复结束，再确认任务是否完成';
    const lastCheck = Array.isArray(state.checks) ? state.checks.filter(c => c && typeof c === 'object').at(-1) : null;
    if (state.next_check_trigger === 'rebind' || state.next_check_basis === '工作区重新绑定'
      || (lastCheck && Array.isArray(lastCheck.stale_reasons) && lastCheck.stale_reasons.includes('workspace'))) return '重新绑定工作区';
    if (state.next_check_manual === true) return '等待本次检查';
    if (state.pending_finalization) return '等待最终检查结果通知';
    if (openFindings(state) > 0 || recheckClues(state) > 0) return '等待当前助手处理检查问题';
    if (noticeCount(state) > 0) return '当前助手核对是否有新改动，再申请完成或重新检查';
    const queued = (typeof state.next_check_at === 'string' && state.next_check_at) || (typeof state.next_check_trigger === 'string' && state.next_check_trigger);
    if (!queued) return '等待当前助手完成工作';
    return '等待已安排的检查';
  }
  function phaseDirective(state) {
    if (state.completion_stop_pending) return '结束任务的请求已提交。当前助手正常结束本轮回复；Orbit 随后核对并确认结果，不要重复提交。';
    if (openFindings(state) > 0 || recheckClues(state) > 0) return '检查还有问题。当前助手先修正或核对，再重新检查；现在不能报告任务完成。';
    if (state.pending_finalization) return '最终检查已结束，结果还在发送。当前助手结束本轮并等待通知，不必反复查询。';
    if (noticeCount(state) > 0)
      return '此前收到过检查通过的通知，但之后文件或要求可能已变化，任务尚未完成。若没有新改动、实现也已验证，当前助手调用 orbit stop 申请完成；Orbit 会再次核对。若有新改动，先重新检查；申请被拒绝时按返回的原因处理。用户只要求暂停时不要申请完成。';
    return '还没有收到最终检查通过的通知。当前助手完成工作并验证后，请求最终检查并结束本轮；收到结果再申请完成。用户要求暂停时按暂停处理。';
  }
  // Pending native-Ask interruptions (contract with TaskRuntime, 2026-09-26):
  // an entry is pending while it has NO cleared_at, regardless of reminded_at
  // (there is a legitimate window between recording and the one-shot reminder
  // delivery). Orbit never answers or re-sends the question; Root re-issues
  // the native ask if it is still needed.
  function askInterruptLine(state) {
    const interrupts = state.ask_interrupts;
    if (!interrupts || typeof interrupts !== 'object') return null;
    const pending = Object.values(interrupts)
      .filter(entry => entry && typeof entry === 'object' && entry.cleared_at == null);
    if (!pending.length) return null;
    const sample = pending.find(entry => typeof entry.tool_call_id === 'string') ?? pending[0];
    const reference = typeof sample.tool_call_id === 'string' ? `（参考编号 ${sample.tool_call_id.slice(0, 8)}）` : '';
    return `有 ${pending.length} 个向用户提的问题被中断，尚未得到回答${reference}。当前助手若仍需要答案，请重新提问；Orbit 不会代答或自动重发。`;
  }
  // Collaboration state line (proposal item 4): members come from the durable
  // record; the candidate pool is the process-local last-known read (no
  // per-turn CLI spawn) and is omitted entirely when no read ever succeeded —
  // never guessed. JEV text mirrors TaskView.jev_status wording.
  function collaborationLine(state) {
    const parts = [];
    const memberCount = Array.isArray(state.members) ? state.members.length : 0;
    parts.push(memberCount > 0 ? `已有 ${memberCount} 个协作成员` : '尚无协作成员');
    if (Array.isArray(lastKnownPool))
      parts.push(lastKnownPool.length > 0 ? `备选模型 ${lastKnownPool.length} 个` : '尚未选择备选模型');
    const jev = state.jev;
    if (jev && typeof jev === 'object') {
      if (jev.status === 'unavailable') parts.push('自动评估暂时不可用');
      else if (jev.evidence_status === 'requested') parts.push('等待当前助手补充模型资料');
      else if (jev.evidence_status === 'used') parts.push('已参考模型资料');
      else if (jev.evidence_status === 'incomplete') parts.push('模型资料不完整，暂不提供分工建议');
      else if (jev.evidence_status === 'unavailable') parts.push('模型资料暂不可用');
      else if (jev.evidence_status === 'mismatch') parts.push('提交资料与候选模型不符');
      else if (jev.evidence_status === 'unknown') parts.push('无法识别待比较的模型');
      else if (jev.evidence_status === 'unrequested') parts.push('尚未请求本次模型资料');
      else if (typeof jev.evidence_status === 'string' && jev.evidence_status)
        parts.push('模型资料状态需核对');
      const decision = jev.delegation && typeof jev.delegation === 'object' ? jev.delegation.decision : null;
      if (decision === 'declined') parts.push('目前不建议分工');
      else if (decision === 'recommended')
        parts.push(state.delegation_hint && Object.keys(state.delegation_hint).length
          ? '有可供当前助手参考的分工建议' : '分工建议尚未保存，不能据此派发');
    }
    return parts.length ? `协作：${parts.join('；')}` : null;
  }
  function statusBlock(state) {
    const counts = [];
    if (openFindings(state) > 0) counts.push(`待解决问题 ${openFindings(state)} 个`);
    if (recheckClues(state) > 0) counts.push(`待重新核对 ${recheckClues(state)} 个`);
    const next = nextActionLabel(state);
    const context = [askInterruptLine(state), collaborationLine(state)].filter(Boolean);
    return [
      `${STATUS_MARKER} Orbit 任务 ${state.id}：${phaseLabel(state)}`,
      counts.length ? counts.join('；') : '当前未记录待解决的问题',
      ...(context.length ? [context.join('；')] : []),
      ...(next && next !== '无' ? [`下一动作：${next}`] : []),
      phaseDirective(state),
    ].join('\n');
  }
  // A record that outlived the host connection that created it (OMP restart or
  // crash) is display-only. Every Orbit tool call on it is refused by the
  // ownership check, so the block must never imply control and must send the
  // user to an explicit, out-of-session cleanup instead of a stop.
  function unownedBlock(state, taskDir) {
    return [
      `${STATUS_MARKER} Orbit 任务 ${state.id}：来自上一次 OMP 会话，本会话不能控制`,
      '当前会话不能继续检查或停止这个旧任务，也不能凭旧记录判断它已经完成。',
      `请当前 Agent 在终端用 orbit status "${taskDir}" 查看实际状态；确需停止时用 orbit stop "${taskDir}" 清理。若要继续工作，请新建任务。`,
    ].join('\n');
  }
  // Owned record whose runtime process is gone: the connection is ours, but
  // there is nothing to execute. Cleanup is a stop retry, never execution.
  function abandonedBlock(state, taskDir) {
    return [
      `${STATUS_MARKER} Orbit 任务 ${state.id}：处理任务的进程已退出，尚未确认完成`,
      '记录仍显示在执行，但任务进程已退出，不会继续检查或自动完成。',
      `请当前 Agent 在终端运行 orbit stop "${taskDir}" 清理并确认停止；若要继续工作，请新建任务。`,
    ].join('\n');
  }
  function withStatusBlock(systemPrompt, block) {
    const base = Array.isArray(systemPrompt) ? systemPrompt : [];
    return [...base.filter(part => !(typeof part === 'string' && part.includes(STATUS_MARKER))), block];
  }
  function applyStatus(ctx, label) {
    if (typeof ctx?.ui?.setStatus !== 'function') return;
    try { ctx.ui.setStatus('orbit', label); } catch { /* headless/RPC: no-op */ }
  }
  async function exists(file) { try { await fs.stat(file); return true; } catch { return false; } }
  // Mirrors TaskView.project: the nearest ancestor carrying .orbit, else .git.
  async function projectRootFor(cwd) {
    if (!cwd) return null;
    let dir = await fs.realpath(cwd).catch(() => cwd);
    for (;;) {
      if (await exists(path.join(dir, '.orbit'))) return dir;
      if (await exists(path.join(dir, '.git'))) return dir;
      const parent = path.dirname(dir);
      if (parent === dir) return null;
      dir = parent;
    }
  }
  async function readRecordState(taskDir) {
    try {
      const state = JSON.parse(await fs.readFile(path.join(taskDir, 'state.json'), 'utf8'));
      return state && state.format === 'orbit-task-1' ? state : null;
    } catch { return null; }
  }
  async function resolveBoundTask(sessionId, cwd) {
    const known = taskDirs.get(sessionId) ?? statusBoundTasks.get(sessionId);
    if (known) {
      const state = await readRecordState(known);
      if (state && state.connection?.provider === 'omp' && state.connection?.thread_id === sessionId) return { taskDir: known, state };
      statusBoundTasks.delete(sessionId);
      if (taskDirs.get(sessionId) === known) taskDirs.delete(sessionId);
    }
    const project = await projectRootFor(cwd);
    if (!project) return null;
    let best = null;
    for (const name of await fs.readdir(path.join(project, '.orbit', 'tasks')).catch(() => [])) {
      const taskDir = path.join(project, '.orbit', 'tasks', name);
      const state = await readRecordState(taskDir);
      if (!state || state.connection?.provider !== 'omp' || state.connection?.thread_id !== sessionId) continue;
      if (!best) { best = { taskDir, state }; continue; }
      const better = (activeState(state) && !activeState(best.state))
        || (activeState(state) === activeState(best.state) && String(state.created_at || '') > String(best.state.created_at || ''));
      if (better) best = { taskDir, state };
    }
    if (!best) return null;
    statusBoundTasks.set(sessionId, best.taskDir);
    return best;
  }
  // Re-derive the per-session status line from the durable record. Shared by
  // the per-turn hook and the orbit tool: a task started (or changed) by a tool
  // call must be reflected in THIS turn, not only at the next user turn
  // (Zeen 2026-09-25: after a successful start the bar still read the previous
  // paused task until the following turn). Display only — it never adjudicates
  // completion, rebinds an unowned record, or overrides the checker. Returns
  // null when there is no resolvable record, so callers can preserve their
  // no-block behavior.
  async function refreshStatus(ctx, sessionId) {
    try {
      const bound = await resolveBoundTask(sessionId, ctx?.cwd);
      if (!bound) { applyStatus(ctx, undefined); return null; }
      const owned = host ? await host.ownsTask(bound.taskDir, sessionId) : false;
      const abandoned = runtimeAbandoned(bound.state);
      if (!owned || abandoned) {
        applyStatus(ctx, `Orbit：${owned ? '' : '未接管 · '}${phaseLabel(bound.state)}`);
        return { bound, owned, abandoned };
      }
      applyStatus(ctx, `Orbit：${phaseLabel(bound.state)}`);
      return { bound, owned, abandoned };
    } catch { return null; }
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
          retained_session_seen: memberRetainedSessions.has(ref.id),
          lifecycle: ref.lifecycle ?? null };
        return { id: ref.id, registry_status: ref.status, streaming: session.isStreaming === true,
          model: session.model ? `${session.model.provider}/${session.model.id}` : (ref.history?.resolvedModel ?? null),
          activity: ref.activity ?? null, session_id: session.sessionId, session_file: ref.sessionFile,
          output_path: ref.history?.outputPath ?? null,
          active_tools: memberActiveTools.has(ref.id) ? memberActiveTools.get(ref.id).size : null,
          async_jobs: session.getAsyncJobSnapshot ? session.getAsyncJobSnapshot() : null,
          session_attached: true, retained_session_seen: memberRetainedSessions.has(ref.id), lifecycle: ref.lifecycle ?? null,
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
        const cached = memberStopConfirmations.get(ref.id);
        if (cached) return cached;
        if (!session) {
          // Registration-retained session (captured in the AgentRegistry
          // `registered` window): OMP may have detached the registry ref
          // (park/abort) with no public dispose-completion signal, but the
          // retained reference is the exact session object. AgentSession
          // dispose() is idempotent with a shared settled promise
          // (agent-session.ts ~4710, issue #4080) and drains the owned
          // AsyncJobManager, so awaiting it here is a REAL disposal barrier,
          // safe to run concurrently with OMP's own lifecycle. Confirm only
          // from these observations — never from the tombstone alone.
          const retained = memberRetainedSessions.get(ref.id);
          let retainedError = null;
          if (retained) {
            try {
              const busyFlags = s => s.isStreaming || s.isCompacting || s.isBashRunning || s.isEvalRunning || s.hasPendingAsyncWork?.();
              if (busyFlags(retained)) await retained.abort({ goalReason: 'internal' }).catch(() => {});
              const manager = retained.asyncJobManager;
              const owner = retained.getAgentId ? retained.getAgentId() : ref.id;
              if (manager && owner) {
                manager.cancelAll({ ownerId: owner });
                const reaped = await manager.cancelAndReapOwnerJobs(owner, Date.now() + 5000);
                if (!reaped.settled) throw new Error(`retained member background processes did not settle for ${ref.id}`);
              }
              // dispose() is idempotent with a shared settled promise
              // (agent-session.ts ~4710): even if OMP already started
              // disposing, awaiting it is the completion barrier, not a
              // reason to skip. It can still return with an active run
              // timed out, so busy flags are verified AFTER the await.
              await retained.dispose();
              if (busyFlags(retained))
                throw new Error(`retained member still busy after dispose for ${ref.id}`);
              // Tool state must be OBSERVED at zero; an untracked member can
              // never be confirmed (a null measurement is unknown, not zero).
              const measured = memberActiveTools.has(ref.id) ? memberActiveTools.get(ref.id).size : null;
              if (measured !== 0)
                throw new Error(`retained member tool state unconfirmed for ${ref.id} (active_tools=${measured === null ? 'unobserved' : measured})`);
              memberRetainedSessions.delete(ref.id);
              memberActiveTools.delete(ref.id);
              stoppedMembers.add(ref.id);
              const confirmation = { confirmed: true, id: ref.id,
                scope: 'Retained member session (captured before provider dispatch, from the attached member session): turn abort, owner-scoped async-job cancel+reap, idempotent session dispose, and post-dispose busy/tool observation; registry ref was already detached',
                registry_status: ref.status, status_after: 'disposed', active_tools_after: measured,
                async_jobs_settled: true };
              memberStopConfirmations.set(ref.id, confirmation);
              return confirmation;
            } catch (error) {
              // Observability, not inference: the exact reason the retained
              // session could not confirm travels with the structured
              // unconfirmed evidence (OMP plugin stderr is not always
              // reachable by operators).
              retainedError = error.message;
              process.stderr.write(`Orbit: retained-session stop for ${ref.id} could not confirm: ${error.message}\n`);
            }
          }
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
                        output_path: ref.history?.outputPath ?? null, session_file: ref.sessionFile,
                        retained_stop_attempt: retainedError },
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
            const liveConfirmation = { confirmed: true, id: ref.id,
              scope: 'Member turn, attached shell processes and owner-scoped async jobs; no unmanaged detached work',
              registry_status: sdk.AgentRegistry.global().get(ref.id)?.status ?? null,
              status_after: busyFlags(session) ? 'active' : 'idle', active_tools_after: measured, async_jobs_settled: true };
            memberStopConfirmations.set(ref.id, liveConfirmation);
            return liveConfirmation;
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
      // ADR-009 bridge for the Ruby runtime side: the live model catalog plus
      // the dispatchable agent mapping. `agents` maps `provider/id` -> the
      // generated session agent name for candidates that are BOTH in the pool
      // AND selectable in this session right now; consumers must not re-derive
      // the name in Ruby (the slug+hash stays JS-internal). `families` is a
      // per-call comparison token, never persisted.
      case 'model_catalog': {
        if (!currentContext?.models) throw new Error('model catalog is unavailable before the extension context is initialized');
        // Another Orbit session may have edited the shared pool since our last
        // sync; the catalog MUST reflect the pool now. Fail closed: a stale
        // or unrefreshable mapping is never reported as current.
        const sync = await syncSessionAgents(currentContext);
        if (!sync.ok) throw new Error(`model catalog is stale: pool re-sync failed (${sync.reason})`);
        let available = [];
        try { available = currentContext.models.list() ?? []; } catch { available = []; }
        const families = {};
        for (const m of available) {
          const key = `${m.provider}/${m.id}`;
          try { families[key] = currentContext.models.family?.(m) ?? null; } catch { families[key] = null; }
        }
        const current = currentContext.models.current?.() ?? null;
        const agents = {};
        for (const [name, model] of sessionAgents) agents[model] = name;
        return { current: current ? `${current.provider}/${current.id}` : null,
                 available: available.map(m => `${m.provider}/${m.id}`), families, agents };
      }
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
    prestartSeen.clear();
    // NOTE: the per-session agent root is intentionally NOT removed here.
    // close() also runs on session_before_switch/branch/tree, where the same
    // OMP process keeps running and the root must survive for the next
    // session_start re-sync. Removal happens only on the real process-level
    // session_shutdown (see below).
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
    // Refresh the pool before validating generated-agent dispatches: another
    // Orbit session may have edited it since our last sync. Only dispatches
    // through our namespace require the refresh; plain native dispatches are
    // unaffected by pool state (in-flight members never switch models).
    let syncError = null;
    if (items.some(item => item && typeof item === 'object' && typeof item.agent === 'string'
      && item.agent.trim().startsWith(AGENT_NAME_PREFIX))) {
      const sync = await syncSessionAgents(ctx);
      if (!sync.ok) syncError = sync.reason;
    }
    for (const item of items) {
      if (!item || typeof item !== 'object') continue;
      // ADR-009: dispatches through our generated agent names pin a model.
      // Out-of-pool/native agents are untouched (pool limits recommendations
      // only), but a stale generated name must not silently resolve to a
      // different or unknown agent.
      const itemAgent = typeof item.agent === 'string' ? item.agent.trim() : '';
      let expectedModel = null;
      if (itemAgent.startsWith(AGENT_NAME_PREFIX)) {
        if (syncError)
          return { block: true, reason: `candidate agents are stale (pool re-sync failed: ${syncError}); refusing to dispatch ${itemAgent} on a possibly outdated mapping` };
        expectedModel = sessionAgents.get(itemAgent) ?? null;
        if (!expectedModel)
          return { block: true, reason: `${itemAgent} is not a live session candidate agent (pool changed?); re-run /orbit-models and dispatch again` };
      }
      const requested = `orbit-${randomUUID()}`;
      item.name = requested;
      requestedNames.set(requested, { taskDir, toolCallId: event.toolCallId ?? null, expectedModel });
    }
    return { input };
  });
  // ADR-009 model drift block. `task.agentModelOverrides`, frontmatter and
  // auth fallback all resolve BEFORE the first provider request; OMP's
  // before_provider_request hook fires per request with that final model
  // (the sdk wiring runs auth fallback and role reclaim first), so a member
  // whose pinned pool model was overridden/fallen back is caught here, before
  // its first real request is dispatched. The drift is recorded through the
  // DEDICATED model-drift entry (`--event model_drift`), which updates the
  // already-registered member — never a second register_member, which the
  // record refuses as duplicate_member_id.
  // RELIABILITY LIMIT (explicit blocker, not proven): the hook can only
  // REPLACE the payload; handler throws are swallowed by OMP, so ctx.abort()
  // is the only suppression available, and live verification that the abort
  // reliably prevents the in-flight request (incl. retry-fallback switches
  // mid-run) is still pending. Until then this is best-effort drift evidence
  // + abort, never reported as a proven gate.
  function recordModelDrift(taskDir, { id, expected, actual, abortConfirmed }) {
    try {
      const ruby = process.env.ORBIT_RUBY || 'ruby';
      const run = spawnSync(ruby, ['--disable-gems', registerMemberBin, taskDir, '--event', 'model_drift',
        '--id', id, '--expected', expected, '--actual', actual,
        '--abort-attempted', 'true', '--abort-confirmed', abortConfirmed ? 'true' : 'false'],
        { encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
      if (run.status !== 0 || !run.stdout) return { ok: false, reason: (run.stderr || `exit ${run.status}`).trim().slice(0, 300) };
      return JSON.parse(run.stdout.trim().split('\n').at(-1));
    } catch (error) {
      return { ok: false, reason: String(error?.message || error).slice(0, 300) };
    }
  }
  pi.on('before_provider_request', async (event, ctx) => {
    let sessionId = null;
    try { sessionId = ctx.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!sessionId) return event.payload;
    const agentId = agentIdFor(sessionId);
    if (!agentId || !nativeMemberIds.has(agentId)) return event.payload;
    // OMP 18.2.8 emits `registered` with ref.session still null and attaches
    // the session later with NO registry event (agent-registry.ts ~290-304).
    // This hook fires with the session live and before provider dispatch, so
    // capture it into the shared retained map (and start tool tracking) for a
    // real stop-confirmation barrier even when the registration window never
    // saw the session.
    try {
      const ref = sdk.AgentRegistry.global().get(agentId);
      if (ref?.session) {
        memberRetainedSessions.set(agentId, ref.session);
        trackMemberTools(agentId, ref.session);
      }
    } catch { /* observation only; never block the request path */ }
    const expected = memberExpectedModels.get(agentId);
    if (!expected) return event.payload;
    const model = ctx.model;
    const actual = model ? `${model.provider}/${model.id}` : null;
    if (!actual || actual === expected) return event.payload;
    if (!memberDriftReported.has(agentId)) {
      memberDriftReported.add(agentId);
      const taskDir = memberTasks.get(agentId);
      // Only the registry flip is confirmable; ctx.abort() has no public
      // completion signal and is recorded as attempted-only.
      const abortConfirmed = signalAbort(agentId);
      const recorded = recordModelDrift(taskDir, { id: agentId, expected, actual, abortConfirmed });
      process.stderr.write(`Orbit: member ${agentId} model drift (${expected} -> ${actual}); ` +
        `drift record: ${recorded.ok ? 'ok' : recorded.reason}; member abort attempted\n`);
    }
    try { ctx.abort?.(); } catch { /* abort is advisory */ }
    return event.payload;
  });
  // The current native user entry is not persisted yet at before_agent_start.
  // OMP 18.3.2 persists and awaits message_end before this hook, which still
  // precedes the first provider request. Never use prompt text as an identity.
  const prestartSeen = new Set();
  pi.on('before_provider_request', async (event, ctx) => {
    let sessionId = null;
    try { sessionId = ctx.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!sessionId || !isMainSession(sessionId)) return event.payload;
    const branch = ctx.sessionManager.getBranch();
    let user = null;
    for (let index = branch.length - 1; index >= 0; index--) {
      const item = branch[index];
      if (item.type !== 'message') continue;
      if (item.message?.role === 'assistant') break;
      if (item.message?.role === 'user' && item.message.attribution !== 'agent') {
        user = item;
        break;
      }
    }
    if (!user?.id || !textOf(user.message.content).trim()) return event.payload;
    const key = `${sessionId}:${user.id}`;
    if (prestartSeen.has(key)) return event.payload;
    prestartSeen.add(key);
    try {
      const bound = await resolveBoundTask(sessionId, ctx.cwd);
      if (bound && activeState(bound.state)) return event.payload;
      await connect(ctx);
      const decision = await host.entry(user.id, ctx);
      if (decision.decision === 'start') {
        const started = JSON.parse(await host.execute({ action: 'start', message_id: user.id,
          entry_file: decision.entry_file }, ctx));
        taskDirs.set(sessionId, started.task_directory);
        await refreshStatus(ctx, sessionId);
      } else if (decision.decision === 'root_decides' && decision.prompt) {
        pi.sendMessage({ customType: 'orbit-entry', content: decision.prompt, attribution: 'agent' },
          { deliverAs: 'aside' });
      }
    } catch (error) {
      const message = `Orbit 入口未能启动受控任务：${error?.message || error}。请停止本轮普通执行，检查原因后显式调用 orbit start；不能把未启动当作已受控。`;
      try { ctx.ui?.notify(message, 'error'); } catch { process.stderr.write(`${message}\n`); }
      pi.sendMessage({ customType: 'orbit-entry', content: message, attribution: 'agent' },
        { deliverAs: 'aside' });
      // A specifically requested controlled run must not silently continue as
      // ordinary work after its start preflight failed.
      try { ctx.abort?.(); } catch { /* the host may already be stopping */ }
    }
    return event.payload;
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
      // A successful start (or any state-changing action) must show its real
      // status in THIS turn: the per-turn hook only refreshes at the next user
      // turn. A failed/rejected call throws above and refreshes nothing, so it
      // never presents a task that was not actually accepted.
      await refreshStatus(ctx, entry.id);
      return { content: [{ type: 'text', text }], details: {} };
    }
  });
  pi.registerCommand('orbit-models', {
    description: 'Searchable keyboard multi-select for the ADR-009 model candidate pool: type to filter, Space toggles, Enter saves ONE net delta atomically, Esc cancels; add/remove subcommands remain for headless and script use',
    handler: async (args, ctx) => {
      const [sub, model] = (args || '').trim().split(/\s+/).filter(Boolean);
      const notify = (text, level = 'info') => { try { ctx.ui.notify(text, level); } catch { process.stderr.write(`${text}\n`); } };
      try {
        if (sub === 'add') {
          if (!model) return notify('usage: /orbit-models add <provider/id>', 'warning');
          // ADR-009: candidates are picked from THIS session's selectable
          // list; adding anything else would persist an identifier the user
          // never saw as available here.
          let available = [];
          try { available = (ctx.models?.list?.() ?? []).map(m => `${m.provider}/${m.id}`); } catch { available = []; }
          if (!available.includes(model))
            return notify(`${model} is not selectable in this session (see the list above). ` +
              'Only models from the current session list can enter the pool; stale entries can still be removed.', 'warning');
          const result = runPoolCli(['add', model]);
          if (!result.ok) return notify(`model-candidates add failed: ${result.reason}`, 'error');
          const sync = await syncSessionAgents(ctx);
          return notify(`Added ${model}. ` +
            (sync.ok ? `Live session agents: ${sync.agents.map(a => `${a.name} -> ${a.model}`).join(', ') || 'none (pool empty or nothing selectable here)'}` : sync.reason),
            sync.ok ? 'info' : 'warning');
        }
        if (sub === 'remove') {
          if (!model) return notify('usage: /orbit-models remove <provider/id>', 'warning');
          const result = runPoolCli(['remove', model]);
          if (!result.ok) return notify(`model-candidates remove failed: ${result.reason}`, 'error');
          await syncSessionAgents(ctx);
          return notify(`Removed ${model}.`, 'info');
        }
        if (sub) return notify('usage: /orbit-models [add|remove <provider/id>]', 'warning');
        const pool = runPoolCli(['list']);
        if (!pool.ok) return notify(`model pool unreadable: ${pool.reason}`, 'error');
        const sessionModelIds = () => {
          try { return (ctx.models?.list?.() ?? []).map(m => `${m.provider}/${m.id}`); } catch { return []; }
        };
        const poolEntries = (poolModels, available) => {
          const listed = new Set(available);
          const entries = available.map(id => ({ id, available: true }));
          for (const id of poolModels) if (!listed.has(id)) entries.push({ id, available: false });
          return entries;
        };
        // Legacy/headless surface: no UI (or a UI that cannot host custom
        // components) still gets the plain text list and per-item commands.
        const textListing = available => {
          const poolSet = new Set(pool.models);
          const stale = pool.models.filter(id => !available.includes(id));
          return [
            'Model candidate pool (ADR-009). Selectable in this session:',
            ...available.filter(id => poolSet.has(id)).map(id => `  [in pool]  ${id}`),
            ...available.filter(id => !poolSet.has(id)).map(id => `  [addable]  ${id}`),
            ...(stale.length ? ['In pool but NOT selectable in this session (kept; removable):', ...stale.map(id => `  [stale]    ${id}`)] : []),
            'Commands:',
            '  /orbit-models add <provider/id>    (only IDs marked [addable])',
            '  /orbit-models remove <provider/id>',
            'Root 显式派发池外原生 Agent 不受此池限制。',
          ].join('\n');
        };
        if (typeof ctx.ui?.custom !== 'function') {
          notify(textListing(sessionModelIds()));
          await syncSessionAgents(ctx);
          return;
        }
        // One Enter = one net-delta commit (proposal B): the session's
        // selectable list is re-read AT COMMIT TIME; a would-be add that is
        // no longer selectable is refused with a refreshed view and nothing
        // written; the pool applies the delta under its cross-process lock
        // with same-ID conflict refusal, so different-ID concurrent edits by
        // other sessions are preserved. Any failure hands the refreshed
        // entries + snapshot back so the picker keeps the remaining
        // selection for an immediate retry instead of forcing a re-pick.
        const commitPoolDelta = async ({ add, remove, base }) => {
          const availableNow = sessionModelIds();
          const poolNow = runPoolCli(['list']);
          if (!poolNow.ok) return { ok: false, error: `model pool unreadable: ${poolNow.reason}` };
          const availableSet = new Set(availableNow);
          const staleAdds = add.filter(id => !availableSet.has(id));
          if (staleAdds.length)
            return { ok: false, error: `待新增模型已不在当前会话可选列表：${staleAdds.join('、')}；列表已刷新，请重新确认`,
              entries: poolEntries(poolNow.models, availableNow), snapshot: poolNow.models };
          const applied = runPoolCli(['apply-delta',
            '--base', base.join(','), '--add', add.join(','), '--remove', remove.join(',')]);
          if (!applied.ok)
            return { ok: false, error: `提交被拒绝：${applied.reason}`,
              entries: poolEntries(poolNow.models, availableNow), snapshot: poolNow.models };
          return { ok: true, models: applied.models };
        };
        // RPC mode's custom() resolves undefined without showing anything
        // (verified in 18.3.2): any non-object outcome falls back to text.
        let outcome = null;
        try {
          outcome = await ctx.ui.custom((_tui, _theme, _keybindings, done) =>
            createModelPicker({ entries: poolEntries(pool.models, sessionModelIds()), snapshot: pool.models, done, commit: commitPoolDelta }));
        } catch (error) {
          notify(`picker unavailable (${error?.message || error}); falling back to the text list`, 'warning');
        }
        if (!outcome || typeof outcome !== 'object') {
          notify(textListing(sessionModelIds()));
          await syncSessionAgents(ctx);
          return;
        }
        if (outcome.status === 'committed') {
          const sync = await syncSessionAgents(ctx);
          const listing = (outcome.models ?? []).join(', ');
          return notify(`已保存候选池：${listing || '（空）'}。` + (sync.ok
            ? ` 本会话 Agent：${sync.agents.map(a => `${a.name} -> ${a.model}`).join(', ') || '无（池为空或本会话无可选模型）'}`
            : ` Agent 同步失败：${sync.reason}`), sync.ok ? 'info' : 'warning');
        }
        if (outcome.status === 'noop') return notify('没有净变化，未写入候选池。', 'info');
        return notify('已取消：候选池未修改。', 'info');
      } catch (error) {
        notify(`/orbit-models failed: ${error?.message || error}`, 'error');
      }
    },
  });
  function isMainSession(sessionId) {
    try {
      const ref = sdk.AgentRegistry.global().list().find(r => r.session?.sessionId === sessionId);
      return Boolean(ref?.session) && ref.id === sdk.MAIN_AGENT_ID && ref.kind === 'main';
    } catch { return false; }
  }
  // Per user turn, an already-bound task gets a short status derived from the
  // durable record (fresh every turn, no polling). Terminal/unbound sessions
  // only refresh the status line. This hook does not create tasks, dispatch
  // members, or gate completion — the Ruby completion gate remains the
  // authority.
  pi.on('before_agent_start', async (event, ctx) => {
    let sessionId = null;
    try { sessionId = ctx?.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!sessionId || !isMainSession(sessionId)) return;
    // Control requires BOTH this process owning the record's control socket
    // AND a live recorded runtime. A record can read 'running' while its
    // socket is stale (OMP restart) or its runtime_pid is dead (crash/
    // abnormal exit). Only the both-true case gets execution guidance; the
    // others get conservative cleanup/stop-retry text. Never rebind the old
    // task; continuing means a new orbit start.
    const resolved = await refreshStatus(ctx, sessionId);
    if (!resolved) return;
    const { bound, owned, abandoned } = resolved;
    if (!owned || abandoned) {
      if (!activeState(bound.state)) return;
      const block = owned && abandoned
        ? abandonedBlock(bound.state, bound.taskDir)
        : unownedBlock(bound.state, bound.taskDir);
      return { systemPrompt: withStatusBlock(event?.systemPrompt, block) };
    }
    if (!activeState(bound.state)) return;
    return { systemPrompt: withStatusBlock(event?.systemPrompt, statusBlock(bound.state)) };
  });
  pi.on('session_start', (_event, ctx) => {
    // Re-bound child runtimes also fire session_start (OMP re-binds factories
    // per subagent). Only the process main agent may bind Orbit; member
    // sessions skip binding — their hooks (drift guard) are installed at
    // factory scope — instead of throwing through the child dispatch loop,
    // which could disable the extension exactly where the guard must run.
    let sessionId = null;
    try { sessionId = ctx.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!isMainSession(sessionId)) return;
    rootFor(ctx);
    subscribeRegistryGate();
    // Best-effort: materialize pool ∩ session into the private agent root so
    // generated agents are dispatchable immediately after startup.
    syncSessionAgents(ctx).catch(() => {});
  });
  pi.on('session_shutdown', async (_event, ctx) => {
    // Fires PER SESSION. Re-bound CHILD runtimes dispose independently; they
    // must neither tear down the Root host nor delete the shared session
    // agent root — only the process main session's shutdown does that.
    let sessionId = null;
    try { sessionId = ctx?.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!isMainSession(sessionId)) return;
    await close();
    // Process-level shutdown only (never on child dispose or on switch/branch/
    // tree): remove our own root. Stray roots from crashed sessions are left
    // for explicit install-time/human cleanup — a quiet long-running session
    // can legitimately sit untouched, so age sweeping is unsafe.
    if (sessionAgentRoot) await fs.rm(sessionAgentRoot, { recursive: true, force: true }).catch(() => {});
  });
  for (const event of ['session_before_switch', 'session_before_branch', 'session_before_tree']) pi.on(event, async () => {
    try { await close(true); }
    catch (error) { currentContext?.ui.notify(error.message, 'error'); return { cancel: true }; }
  });
}

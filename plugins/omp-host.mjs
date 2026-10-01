import fs from 'node:fs/promises';
import { readFileSync, realpathSync, watchFile, unwatchFile } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createOrbitHost, toolArgs, toolDescription } from './host.mjs';
import { captureStart, buildReceipt, appendReceipt, readReceipts, CAPTURED_TOOLS } from './root-verifications.mjs';
import { validateMemberTool, createEditProjection } from './work-unit-scope.mjs';
import { observeNativeCalls, flushNativeCalls } from './native-call-recorder.mjs';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const textOf = content => typeof content === 'string' ? content : (content || []).filter(p => p.type === 'text').map(p => p.text).join('\n');
// Internal synchronous registration entry (TaskRecord-backed, atomic+durable).
// Overridable in tests; production resolves next to this file.
const registerMemberBin = process.env.ORBIT_REGISTER_MEMBER_BIN
  || fileURLToPath(new URL('../scripts/orbit-register-member', import.meta.url));
const workUnitBin = fileURLToPath(new URL('../scripts/orbit-work-unit', import.meta.url));
// Same release-anchored, ruby-invoked shape for the read-only binding helper
// that pins a Root receipt's input identity (start) and artifact digest (end).
const rootBindingBin = process.env.ORBIT_ROOT_BINDING_BIN
  || fileURLToPath(new URL('../scripts/orbit-root-binding', import.meta.url));
// Pool edits must run THIS release's CLI, never whatever `orbit` happens to
// be first on PATH (an older install would write a stale schema/format).
// Same release-anchored, ruby-invoked shape as the member registration entry.
const orbitCliBin = fileURLToPath(new URL('../scripts/orbit', import.meta.url));
const rubyBin = () => process.env.ORBIT_RUBY || 'ruby';

function runWorkUnit(taskDir, action, payload = {}) {
  try {
    const run = spawnSync(rubyBin(), ['--disable-gems', workUnitBin, taskDir, action],
      { input: JSON.stringify(payload), encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
    const result = run.stdout && JSON.parse(run.stdout.trim().split('\n').at(-1));
    if (run.status === 0 && result?.ok === true) return result;
    return { ok: false, reason: result?.reason || (run.stderr || run.error?.message || `exit ${run.status}`).trim().slice(0, 300) };
  } catch (error) { return { ok: false, reason: String(error?.message || error).slice(0, 300) }; }
}

// Native task has no extra permission fields. A standalone marker in its
// task/context names the durable handoff; full context is injected below.
function dispatchUnitId(item, context) {
  const markers = [item.task, context].filter(value => typeof value === 'string')
    .flatMap(value => [...value.matchAll(/^\s*orbit-unit:\s*(wu-[0-9a-f]{16})\s*$/gm)].map(match => match[1]));
  return markers.length && new Set(markers).size === 1 ? markers[0] : null;
}

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
// Shared with child extension closures; bind only an actually observed model.
const memberWorkUnits = new Map();
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

// Last-known registry snapshot per member id, captured while the ref was still
// readable. When OMP detaches/unregisters a finished member's ref, read-side
// member_state/member_result fall back to this snapshot so an already
// observed terminal fact (status, lifecycle, persisted output path, resolved
// model) does not disappear with the ref. Read-only: a member with neither a
// live ref nor a snapshot is still "not owned"; stop_member keeps its own
// retained-session barrier, and send_member never uses this surface.
const memberRetainedSnapshots = new Map();

function captureMemberSnapshot(id, ref) {
  try {
    if (!id || !ref) return;
    memberRetainedSnapshots.set(id, {
      status: ref.status ?? null,
      lifecycle: ref.lifecycle ?? null,
      activity: ref.activity ?? null,
      sessionFile: ref.sessionFile ?? null,
      history: ref.history ? { outputPath: ref.history.outputPath ?? null, resolvedModel: ref.history.resolvedModel ?? null } : null,
      capturedAt: new Date().toISOString(),
    });
  } catch { /* observation only */ }
}

// The member's CURRENT native turn error fact, from the SDK's own session
// objects (sessionManager branch), not from prose: the branch's LAST
// assistant message ending in stopReason "error". Bounded and structured;
// a newer non-error turn yields null, so a stale error never masquerades as
// current.
function lastTurnError(session) {
  try {
    const branch = session?.sessionManager?.getBranch?.() ?? [];
    for (let i = branch.length - 1; i >= 0; i--) {
      const item = branch[i];
      if (item?.type !== 'message' || item.message?.role !== 'assistant') continue;
      const message = item.message;
      if (message.stopReason !== 'error') return null;
      const errorMessage = typeof message.errorMessage === 'string' ? message.errorMessage : '';
      return {
        message_id: item.id ?? null,
        at: item.timestamp ?? null,
        stop_reason: 'error',
        error_status: typeof message.errorStatus === 'number' ? message.errorStatus : null,
        error_id: message.errorId ?? null,
        error_message: errorMessage.replace(/\s+/g, ' ').trim().slice(0, 200),
        provider: message.provider ?? null,
        model: message.model ?? null,
      };
    }
  } catch { /* observation only */ }
  return null;
}

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

// --- Durable task-local collaboration evidence (collaboration.jsonl) -------
// The per-session collab buffer is bounded (COLLAB_CAP) and lives only as
// long as the OMP process, so evidence observed before a TaskRuntime poll —
// or beyond the buffer cap — was silently lost. Every ATTRIBUTED observation
// is therefore also appended, at observation time, to
// <task_dir>/collaboration.jsonl (mode 0600, same discipline as
// TaskRecord's events.jsonl but a separate file: TaskRuntime appends to
// events.jsonl on its own ticks, and two independent appenders must not
// interleave in one file). MODULE scope, like the member maps above: OMP
// re-binds the extension factory per child session, and the per-task
// sequence plus one file handle per task must be shared process-wide or
// re-bound closures would write competing counters into the same file.
// The append is fire-and-forget and serialized per task: observation must
// never block or fail native work. Write failures are never swallowed —
// once writing recovers they surface as an explicit persistence_gap line
// (and a bounded-buffer event) carrying the lost count and time window.
const COLLAB_FILENAME = 'collaboration.jsonl';
const COLLAB_BUFFER_TEXT_CAP = 2000;
// Long string payloads stay full-length in the durable file (original
// decision-relevant inputs/results) but keep the historical bounded shape
// inside the in-process bridge buffer the TaskRuntime polls.
const COLLAB_BOUNDED_FIELDS = ['message', 'text', 'task', 'context', 'prompt', 'description', 'question'];
function boundedCollabEntry(entry) {
  let copy = entry;
  for (const field of COLLAB_BOUNDED_FIELDS) {
    const value = copy[field];
    if (typeof value === 'string' && value.length > COLLAB_BUFFER_TEXT_CAP) {
      if (copy === entry) copy = { ...entry };
      copy[field] = value.slice(0, COLLAB_BUFFER_TEXT_CAP);
    }
  }
  return copy;
}

const collabWriters = new Map(); // task_dir -> { handle, queue, seq, lost }
// Observations that could not be attributed to any task when they happened,
// counted per session so the task that later binds that session can learn
// how much pre-association traffic exists. The CONTENT is never written
// anywhere: an unattributable event must not leak into any task's file.
const unattributedBySession = new Map();
const UNATTRIBUTED_SESSION_CAP = 512;
// Last durably recorded model identity per task/role/agent, so a model that
// does not change between provider requests is recorded once, not per
// request. Actual resolved identity stays authoritative in members.json and
// the runtime; these are observations only.
const modelIdentitySeen = new Map();

function collabWriterFor(taskDir) {
  let writer = collabWriters.get(taskDir);
  if (!writer) {
    writer = { handle: null, queue: Promise.resolve(), seq: 0, lost: null, prepared: false };
    collabWriters.set(taskDir, writer);
  }
  return writer;
}

async function collabWriteLine(writer, taskDir, line) {
  if (!writer.handle) {
    writer.handle = await fs.open(path.join(taskDir, COLLAB_FILENAME), 'a', 0o600);
    // 0600 governs creation only; normalize a pre-existing file too.
    await writer.handle.chmod(0o600);
  }
  await writer.handle.writeFile(JSON.stringify(line) + '\n');
}

// First-touch preparation for a task's evidence file. The per-task sequence
// must stay monotonic across an OMP restart/resume on the same task
// directory: resume from the LAST parseable sequenced line instead of
// restarting at 0. A crash can leave a partial trailing line or malformed
// region; it is surfaced as an explicit persistence_gap episode (reusing
// the drain's gap machinery) and left intact — never overwritten, never
// silently assumed zero.
async function collabPrepare(writer, taskDir) {
  writer.prepared = false;
  const file = path.join(taskDir, COLLAB_FILENAME);
  let raw;
  try { raw = await fs.readFile(file, 'utf8'); }
  catch (error) {
    if (error?.code === 'ENOENT') { writer.prepared = true; return; } // no file yet
    throw error; // surfaced as a persistence gap by the drain error path
  }
  const partial = raw.length > 0 && !raw.endsWith('\n');
  const physical = (partial ? raw + '\n' : raw).split('\n');
  if (physical.at(-1) === '') physical.pop();
  let lastSeq = null;
  let skipped = 0;
  for (let index = physical.length - 1; index >= 0; index--) {
    let parsed = null;
    try { parsed = JSON.parse(physical[index]); } catch { parsed = null; }
    if (parsed && typeof parsed === 'object' && Number.isInteger(parsed.seq)) { lastSeq = parsed.seq; break; }
    skipped += 1;
  }
  if (lastSeq !== null) writer.seq = lastSeq;
  if (partial || skipped > 0) {
    writer.lost = writer.lost ?? { count: skipped, first_at: Date.now(), last_at: Date.now(),
      reason: lastSeq === null
        ? `existing ${COLLAB_FILENAME} has no parseable sequenced line; numbering restarted at 0 with ${skipped} unparseable line(s) left intact`
        : `${skipped} malformed/partial line(s) skipped while resuming the durable sequence after a restart; they were left intact` };
  }
  // Open the handle here so a partial trailing fragment is terminated
  // BEFORE any appended line can merge into it.
  if (writer.handle) await writer.handle.close();
  writer.handle = null;
  writer.handle = await fs.open(file, 'a', 0o600);
  await writer.handle.chmod(0o600);
  if (partial) await writer.handle.write('\n');
  writer.prepared = true;
}

// The gap line documents a loss EPISODE: how many observations, over what
// time range, and the exact failure. Sequence numbers are committed only
// when a line lands, so a lost observation consumes no sequence and the
// persisted numbering is contiguous by construction — the gap line is the
// explicit marker, never a silent hole.
function collabGapLine(lost, taskDir, atMs, seq) {
  return { seq, at: new Date(atMs).toISOString(), at_ms: atMs,
    kind: 'persistence_gap', task_dir: taskDir, session_id: null, agent_id: null,
    lost_count: lost.count,
    first_lost_at: new Date(lost.first_at).toISOString(), last_lost_at: new Date(lost.last_at).toISOString(),
    reason: lost.reason };
}

// One serialized drain turn: recover any pending loss episode with a gap
// line, then append the observation. `onGap` runs at most once per episode
// (the transition into a lost state) so a persistently broken sink cannot
// loop; the callback must not itself persist, or a failing mirror would
// recurse. The queue chain never rejects.
async function drainCollab(writer, taskDir, line, onGap) {
  try {
    if (!writer.prepared) await collabPrepare(writer, taskDir);
    if (writer.lost) {
      const gapSeq = writer.seq + 1;
      await collabWriteLine(writer, taskDir, collabGapLine(writer.lost, taskDir, Date.now(), gapSeq));
      writer.seq = gapSeq;
      writer.lost = null;
    }
    line.seq = writer.seq + 1;
    await collabWriteLine(writer, taskDir, line);
    writer.seq = line.seq;
  } catch (error) {
    const reason = `collaboration.jsonl append failed: ${String(error?.message || error).slice(0, 200)}`;
    if (writer.lost) {
      writer.lost.count += 1;
      writer.lost.last_at = Date.now();
      writer.lost.reason = reason;
    } else {
      writer.lost = { count: 1, first_at: Date.now(), last_at: Date.now(), reason };
      try { onGap?.(writer.lost, taskDir); } catch { /* the mirror must not break the chain */ }
    }
  }
}

// Fire-and-forget durable append.
function persistCollabLine(taskDir, line, onGap) {
  const writer = collabWriterFor(taskDir);
  writer.queue = writer.queue.then(() => drainCollab(writer, taskDir, line, onGap));
}

// Process-level shutdown only (never on child dispose or session switch):
// flush the queue, make one last attempt at recording an unresolved loss
// episode, and close the handles.
async function closeCollabWriters() {
  await Promise.allSettled([...collabWriters.entries()].map(async ([taskDir, writer]) => {
    await writer.queue.catch(() => {});
    if (!writer.prepared) {
      try { await collabPrepare(writer, taskDir); } catch { /* the gap attempt below surfaces it */ }
    }
    if (writer.lost) {
      try {
        const gapSeq = writer.seq + 1;
        await collabWriteLine(writer, taskDir, collabGapLine(writer.lost, taskDir, Date.now(), gapSeq));
        writer.seq = gapSeq;
        writer.lost = null;
      } catch { /* left to the exporter's missing-evidence reconciliation */ }
    }
    try { await writer.handle?.close(); } catch { /* best effort */ }
    writer.handle = null;
  }));
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
  const rowFor = new Map(entries.map(entry => [entry.id, {
    id: entry.id, available: entry.available === true,
    evidenceStatus: entry.evidenceStatus, overviewStatus: entry.overviewStatus,
  }]));
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
        const evidence = entry.evidenceStatus ? `  · 证据 ${entry.evidenceStatus}` : '';
        const overview = entry.overviewStatus ? `  · 概述 ${entry.overviewStatus}` : '';
        body.push(`${pointer} ${mark} ${entry.id}${tag}${evidence}${overview}`);
      }
      if (rows.length > stop) body.push(`  … 还有 ${rows.length - stop} 项（继续 ↓）`);
      if (start > 0) body.unshift(`  … 以上还有 ${start} 项（继续 ↑）`);
    } else {
      body.push(query ? '（无匹配模型；Backspace 删词后重试）' : '（当前会话没有可选模型）');
    }
    const statusLine = error ? `保存失败：${error}` : notice ? `提示：${notice}` : null;
    const footer = [
      '↑/↓ 移动  Space 勾选/取消  Backspace 删除搜索  Enter 保存  Esc 取消',
      'Root 模型由 OMP 原生 --model 选择；本候选池不切换当前 Root。',
      '缺证据：orbit model-evidence --file FILE|-；质量与隔离环境尚未探测。',
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
        for (const entry of result.entries) rowFor.set(entry.id, {
          id: entry.id, available: entry.available === true,
          evidenceStatus: entry.evidenceStatus, overviewStatus: entry.overviewStatus,
        });
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

// --- Automatic-entry failure: current-turn recovery instruction -----------
// The automatic entry path below can fail before any TaskRecord exists — the
// live case is the ADR-009 checker selector failing closed when no candidate
// pool model is runnable in the isolated profile. The historical response
// (notify + deliverAs:'aside' + ctx.abort()) trapped Root: verified against
// installed omp/18.3.2, an aside sent while the session is streaming is only
// QUEUED for a later turn (session sendCustomMessage -> queueAside), and
// ctx.abort() cancels the in-flight provider request — so the turn that
// needed the instruction died before ever seeing it, no task existed, the
// same message was never reclassified (prestartSeen), and Root had no
// permitted next action. The one seam PROVEN to reach the current model
// request is this hook's RETURN VALUE: the agent runtime wires
// before_provider_request as the provider `onPayload` filter and its return
// value replaces the request body actually sent (emitBeforeProviderRequest
// `if (u !== undefined) n = u`; the anthropic, openai-completions,
// bedrock-converse and openai-codex Responses paths — both its websocket
// `response.create` send and the SSE fallback — all honor it). So on failure
// the recovery instruction is appended to the request's trailing user
// content and the turn is NOT aborted: Root reads the failure, its exact
// reason and the approved recovery flow in THIS request. The injection is
// payload-only and never persists to the session. Explicit requests carry
// the recovery instruction across later provider requests until Root starts
// a task or a newer message supersedes it. Non-explicit failures notify once:
// repeating the warning after every tool call distracts Root from ordinary work.
// Request shapes this release cannot confidently mutate keep the old
// fail-closed trap (aside + abort).
function entryRecoveryInstruction(reason, messageId, explicit) {
  const intro = [
    '[orbit-entry-failed] 本条消息的 Orbit 入口启动失败，没有创建 Orbit 任务。',
    `失败原因：${reason}`,
  ];
  if (!explicit) return [
    ...intro,
    '这是非显式的自动受控候选，本次工作未受 Orbit 监督。可以按原要求普通执行并向用户说明未受控；不要声称独立检查或完成门已经启动。',
    '如希望改用受控任务：Orbit 优先从候选池选择 OMP 可运行检查模型；池内都不可用时 Root 可从 OMP 当前可用型号中选择。缺证据时仅提交一手来源事实：orbit model-evidence --file FILE|-。不需要用户逐型号授权。',
    `然后对原始消息调用 Orbit action=start，message_id="${messageId}"。选模失败不会自动重试；不想受控则无需补证据。`,
  ].join('\n');
  return [
    ...intro,
    '用户明确要求 Orbit 受控：本轮不要以普通执行替代。请修复失败原因后对原始消息显式启动；不要将未启动当作已受控。',
    '先核对 OMP 当前会话模型及隔离检查者凭据；Root 可指定可运行的 provider/id，证据缺失时只提交真实来源事实，不借近似型号或编造指标。',
    `显式调用 Orbit action=start，message_id="${messageId}"；已有任务则用返回的 task_directory 继续。`,
  ].join('\n');
}

// Returns a NEW request payload with `text` appended to the trailing user
// turn — merged into the last message when it already has the user role (so
// strict-alternation providers such as Bedrock Converse never see two
// consecutive user turns), appended as a new user message otherwise — or
// null when the payload is not a shape this release can confidently mutate
// (caller then keeps the fail-closed abort path). Handled shapes are the
// ones observed in real OMP provider payloads: `messages` arrays with string
// content (openai-completions), {type:'text', text} blocks (anthropic /
// openai parts) and bare {text} blocks (bedrock-converse); and Responses
// bodies (openai-codex) whose `input` item list gets the exact user-message
// item OMP's own Responses finalizer appends (verified in omp/18.3.2:
// e.input = [...a, { type: "message", role: "user", content:
// [{ type: "input_text", text }] }]). The input payload is never mutated.
export function appendInstructionToPayload(payload, text) {
  if (payload && typeof payload === 'object' && Array.isArray(payload.input) && !Array.isArray(payload.messages))
    return appendToResponsesInput(payload, text);
  return appendToMessagesPayload(payload, text);
}

// Assistant-side Responses call items must be followed by their own outputs
// (a user message in between is rejected by the API), so those tails defer
// to the fail-closed path instead.
const RESPONSES_CALL_ITEMS = new Set(['function_call', 'custom_tool_call', 'computer_call', 'reasoning',
  'shell_call', 'apply_patch_call', 'local_shell_call']);
function appendToResponsesInput(payload, text) {
  const items = payload.input;
  if (items.length === 0) return null;
  const last = items[items.length - 1];
  if (!last || typeof last !== 'object' || Array.isArray(last)) return null;
  const messageLike = last.type === 'message' || (last.type === undefined && typeof last.role === 'string');
  if (messageLike && last.role === 'user') {
    if (typeof last.content === 'string')
      return { ...payload, input: [...items.slice(0, -1), { ...last, content: last.content ? `${last.content}\n\n${text}` : text }] };
    if (Array.isArray(last.content))
      return { ...payload, input: [...items.slice(0, -1), { ...last, content: [...last.content, { type: 'input_text', text }] }] };
    return null;
  }
  if (RESPONSES_CALL_ITEMS.has(last.type)) return null;
  return { ...payload, input: [...items, { type: 'message', role: 'user', content: [{ type: 'input_text', text }] }] };
}

function appendToMessagesPayload(payload, text) {
  const messages = payload && typeof payload === 'object' && Array.isArray(payload.messages) ? payload.messages : null;
  if (!messages || messages.length === 0) return null;
  const last = messages[messages.length - 1];
  if (!last || typeof last !== 'object' || typeof last.role !== 'string') return null;
  // An assistant turn ending in tool_use must be answered by tool results,
  // never by a fresh user message (anthropic rejects that outright).
  if (last.role !== 'user' && Array.isArray(last.content)
    && last.content.some(part => part && typeof part === 'object' && part.type === 'tool_use')) return null;
  const blockFor = content => {
    const withText = content.find(part => part && typeof part === 'object' && typeof part.text === 'string');
    if (withText) return withText.type === 'text' ? { type: 'text', text } : { text };
    return content.some(part => part && typeof part === 'object' && typeof part.type === 'string')
      ? { type: 'text', text } : null;
  };
  let message;
  if (last.role === 'user') {
    if (typeof last.content === 'string') {
      message = { ...last, content: last.content ? `${last.content}\n\n${text}` : text };
    } else if (Array.isArray(last.content) && last.content.length > 0) {
      const block = blockFor(last.content);
      if (!block) return null;
      message = { ...last, content: [...last.content, block] };
    } else return null;
  } else if (typeof last.content === 'string') {
    message = { role: 'user', content: text };
  } else if (Array.isArray(last.content) && last.content.length > 0) {
    const block = blockFor(last.content);
    if (!block) return null;
    message = { role: 'user', content: [block] };
  } else return null;
  return { ...payload, messages: [...messages.slice(0, -1), message] };
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
  const rootAgentWrites = new Set(); // in-flight OMP `write agent://...` calls awaiting their result
  const COLLAB_CAP = 500;
  const collabSeqByTask = new Map();    // task_dir -> last assigned seq (per-task, gap-free)
  const collabDroppedByTask = new Map(); // task_dir -> count of dropped oldest events
  let lastKnownPool = null; // last successful pool read (status display only; never a second pool state)
  let host, currentContext, registryHookInstalled;

  // The candidate pool is a PREFERENCE surface: it materializes generated
  // session agents for pooled models. It is not an authorization list —
  // generic @task dispatches resolve the session task-role model directly
  // (contract: model usage boundary, 2026-09-27 user ruling).
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
  // Read-only exact-identity cache facts; session availability is supplied by
  // ctx.models.list() and neither quality nor isolated credentials are probed.
  const runModelStatusCli = project => {
    try {
      const argv = ['model-status', '--project', project];
      const run = process.env.ORBIT_CLI_BIN
        ? spawnSync(poolBin(), argv, { encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 })
        : spawnSync(rubyBin(), ['--disable-gems', poolBin(), ...argv],
          { encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
      if (run.status !== 0 || !run.stdout) return { ok: false, reason: (run.stderr || run.error?.message || `exit ${run.status}`).trim().slice(0, 200) };
      return { ok: true, report: JSON.parse(run.stdout.trim().split('\n').at(-1)) };
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
        'tools: [read, write, edit, bash, grep, glob, hub]',
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

  // Native collaboration: OMP 18.3.4 sends peer messages through both the
  // `hub` tool and `write agent://<peer>`; member session subscriptions observe
  // each form. Root hub traffic uses the awaited tool hooks below. hub_call
  // records wire intent; hub_result and task_result record actual returns.
  // Every entry is tagged with
  // the owning task directory (Root sessions via their binding, member
  // sessions via memberTasks) so a bounded buffer can never mix tasks — and
  // attribution is decided HERE, before anything is persisted: an event with
  // no resolvable task is never written to any task's durable file.
  // Attributed entries are appended to <task_dir>/collaboration.jsonl at
  // observation time (module-scope writer above) with an ISO `at` timestamp
  // and a monotonic per-task durable sequence, independent of the bounded
  // buffer sequence the TaskRuntime polls.
  function pushBounded(entry) {
    collabEvents.push(entry);
    if (collabEvents.length > COLLAB_CAP) {
      const dropped = collabEvents.splice(0, collabEvents.length - COLLAB_CAP);
      for (const item of dropped) {
        if (item.task_dir) collabDroppedByTask.set(item.task_dir, (collabDroppedByTask.get(item.task_dir) ?? 0) + 1);
      }
    }
  }
  // Durable append for an entry whose task_dir is already known. The line
  // keeps the ORIGINAL untruncated payload; only the bounded buffer copy is
  // capped. A failing append surfaces once per loss episode as a
  // persistence_gap buffer event (never re-persisted, so a broken sink
  // cannot loop); the durable gap line itself is written by the writer on
  // recovery or at shutdown.
  function queueCollabPersist(entry) {
    const taskDir = entry.task_dir;
    const observedAt = typeof entry.at === 'number' ? entry.at : Date.now();
    const line = { at: new Date(observedAt).toISOString(), at_ms: observedAt };
    for (const [key, value] of Object.entries(entry)) {
      if (key !== 'id' && key !== 'seq' && key !== 'at' && key !== 'task_dir') line[key] = value;
    }
    line.task_dir = taskDir;
    persistCollabLine(taskDir, line, (lost, dir) => {
      const seq = (collabSeqByTask.get(dir) ?? 0) + 1;
      collabSeqByTask.set(dir, seq);
      pushBounded({ kind: 'persistence_gap', at: Date.now(), session_id: null, agent_id: null,
        task_dir: dir, seq, id: `collab-${seq}`, lost_count: lost.count, reason: lost.reason });
    });
  }
  function recordCollabFor(taskDir, entry) {
    entry.task_dir = taskDir;
    const seq = (collabSeqByTask.get(taskDir) ?? 0) + 1;
    collabSeqByTask.set(taskDir, seq);
    entry.seq = seq;
    entry.id = `collab-${seq}`;
    queueCollabPersist(entry);
    pushBounded(boundedCollabEntry(entry));
  }
  function observeCollab(entry) {
    entry.id = null;
    entry.seq = null;
    entry.task_dir = taskDirs.get(entry.session_id) ?? (entry.agent_id ? memberTasks.get(entry.agent_id) : undefined) ?? null;
    if (entry.task_dir) {
      recordCollabFor(entry.task_dir, entry);
      return;
    }
    // Unattributable right now. Counted per session (bounded) so the task
    // that later binds this session learns the observation gap explicitly;
    // the content itself is deliberately dropped — never attributed
    // retroactively, never written into a foreign task's file.
    if (typeof entry.session_id === 'string' && entry.session_id) {
      if (unattributedBySession.size >= UNATTRIBUTED_SESSION_CAP) unattributedBySession.delete(unattributedBySession.keys().next().value);
      unattributedBySession.set(entry.session_id, (unattributedBySession.get(entry.session_id) ?? 0) + 1);
    }
    pushBounded(boundedCollabEntry(entry));
  }
  // Called at every seam that newly attributes a session to a task (orbit
  // start binding, member registration). Pre-association observations from
  // that session become an explicit, dated gap line instead of silence.
  function noteAssociation(sessionId, taskDir) {
    if (typeof sessionId !== 'string' || !sessionId || !taskDir) return;
    const lost = unattributedBySession.get(sessionId);
    if (!lost) return;
    unattributedBySession.delete(sessionId);
    recordCollabFor(taskDir, { kind: 'persistence_gap', at: Date.now(), session_id: sessionId, agent_id: null,
      reason: 'observations existed before this session was attributed to the task; their content was never attributable and is not recorded',
      lost_count: lost });
  }
  // Per-task actual model identity, observed only where it is real: member
  // registration / member provider requests / Root provider requests on a
  // bound session. `provider/id` strings only — no auth material, no request
  // payload. The authoritative resolved identity stays in members.json and
  // the runtime; recorded once per identity change.
  function noteModelIdentity({ taskDir, role, agentId, sessionId, model, requestedModel }) {
    if (!taskDir || !model) return;
    const key = `${taskDir}\n${role}\n${agentId ?? sessionId ?? ''}`;
    if (modelIdentitySeen.get(key) === model) return;
    modelIdentitySeen.set(key, model);
    recordCollabFor(taskDir, { kind: 'model_identity', at: Date.now(), session_id: sessionId ?? null,
      agent_id: agentId ?? null, role, model, requested_model: requestedModel ?? null });
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

  // --- Root execution verification receipts (ticket D-ROOT-VERIFICATIONS) --
  // Facts only, captured from real Root tool_execution_start/end events and
  // the read-only scripts/orbit-root-binding helper. The input identity
  // (artifact_root + input_digest) is pinned at tool START so a mid-run
  // amend/rebind can never make an old command look like evidence for a new
  // requirement or a new root; the artifact fingerprint is captured at
  // completion. No TTL cache and no JS-side "current" verdict: matching
  // against the current snapshot/input is the Ruby start_check's job.
  // Members are never captured here — remember() is the main session only.
  const rootVerifyStarts = new Map(); // toolCallId -> pinned start record
  const ROOT_VERIFY_STARTS_CAP = 256;
  function readRootBinding(taskDir, { fingerprint = true } = {}) {
    const argv = ['--disable-gems', rootBindingBin, taskDir];
    if (!fingerprint) argv.push('--no-fingerprint');
    const run = spawnSync(rubyBin(), argv, { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 });
    if (run.error || run.status !== 0) return null;
    try {
      const value = JSON.parse(run.stdout);
      return value && value.ok === true ? value : null;
    } catch { return null; }
  }
  function observeRootVerifyStart(event, session) {
    // bash/eval plus Root file tools (edit/write): the latter add identity and
    // bounded target metadata only, never content or a diff.
    if (!CAPTURED_TOOLS.includes(event.toolName)) return;
    if (typeof event.toolCallId !== 'string') return;
    if (rootVerifyStarts.size >= ROOT_VERIFY_STARTS_CAP) rootVerifyStarts.delete(rootVerifyStarts.keys().next().value);
    let sessionCwd = null;
    try { sessionCwd = session.sessionManager?.getCwd?.() ?? null; } catch { sessionCwd = null; }
    const start = captureStart(event, { sessionCwd });
    if (!start) return;
    const taskDir = taskDirs.get(session.sessionId);
    start.task_directory = taskDir ?? null;
    start.root_session_id = session.sessionId ?? null;
    const binding = taskDir ? readRootBinding(taskDir, { fingerprint: false }) : null;
    if (binding) {
      start.artifact_root = binding.artifact_root ?? null;
      start.input_digest = binding.input_digest ?? null;
    } else {
      // Explicit gap: no bound task or unreadable binding at start — the
      // receipt keeps the execution fact but grants no input identity.
      start.binding_status = 'unknown';
    }
    rootVerifyStarts.set(event.toolCallId, start);
  }
  function observeRootVerifyEnd(event, session) {
    if (!CAPTURED_TOOLS.includes(event.toolName)) return;
    const start = typeof event.toolCallId === 'string' ? rootVerifyStarts.get(event.toolCallId) ?? null : null;
    if (typeof event.toolCallId === 'string') rootVerifyStarts.delete(event.toolCallId);
    // Keep the START owner when a new task is bound while the command runs.
    // A command started outside a task is never assigned to a later task.
    const taskDir = start ? start.task_directory : taskDirs.get(session.sessionId);
    if (!taskDir) return; // unattributable: never write into a foreign task
    const endBinding = readRootBinding(taskDir); // null = explicit gap
    const receipt = buildReceipt({ event, start, endBinding,
      taskDirectory: taskDir, rootSessionId: session.sessionId });
    if (!receipt) return; // synthetic interrupt replay: nothing executed
    const error = appendReceipt(taskDir, receipt);
    if (error) recordCollabFor(taskDir, { kind: 'verification_persist_failed', at: Date.now(),
      session_id: session.sessionId ?? null, agent_id: null, tool_call_id: event.toolCallId ?? null,
      reason: String(error?.message || error).slice(0, 200) });
  }

  function trackMemberTools(id, session) {
    if (memberActiveTools.has(id) || typeof session?.subscribe !== 'function') return;
    const active = new Set();
    memberActiveTools.set(id, active);
    observeNativeCalls(session, () => nativeCallContext(session));
    const agentWrites = new Set();
    session.subscribe(event => {
      if (event.type === 'tool_execution_start') {
        active.add(event.toolCallId);
        rememberAskArgs(event);
        const peerWrite = event.toolName === 'write' && typeof event.args?.path === 'string'
          && event.args.path.startsWith('agent://');
        if (peerWrite) agentWrites.add(event.toolCallId);
        if ((event.toolName === 'hub' || peerWrite) && memberTasks.has(id)) {
          const input = event.args || {};
          observeCollab({ kind: 'hub_call', at: Date.now(), session_id: session.sessionId ?? null, agent_id: id,
            tool_call_id: event.toolCallId ?? null, op: peerWrite ? 'send' : input.op ?? null,
            to: peerWrite ? input.path.slice('agent://'.length) : input.to ?? null, from: input.from ?? null,
            reply_to: peerWrite ? null : input.replyTo ?? null, await_reply: peerWrite ? false : input.await === true,
            message: typeof (peerWrite ? input.content : input.message) === 'string'
              ? (peerWrite ? input.content : input.message) : null });
        }
      }
      if (event.type === 'tool_execution_end') {
        active.delete(event.toolCallId);
        observeAskEnd(event, session.sessionId ?? null, id);
        if ((event.toolName === 'hub' || (event.toolName === 'write' && agentWrites.delete(event.toolCallId))) && memberTasks.has(id)) {
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
            text: text ?? null });
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
        observeRootVerifyStart(event, session);
      }
      if (event.type === 'tool_execution_end') {
        entry.activeTools.delete(event.toolCallId);
        observeRootVerifyEnd(event, session);
        // Ask observation only: the registry lookup is deliberately lazy so a
        // normal tool end never pays for it.
        if (event.toolName === 'ask') observeAskEnd(event, id, agentIdFor(id));
      }
      if (event.type === 'model_changed') {
        // Public AgentSession event (subscribe) — model_changed has no
        // extension-facing hook. A change while rootModelInFlight is set was
        // caused by the orbit tool or the program switch; anything else is an
        // external explicit selection (native /model, UI) and conservatively
        // wins over program auto-selection.
        if (rootModelInFlight.has(id)) ownModelSwitches.set(id, (ownModelSwitches.get(id) || 0) + 1);
        else externalModelChange.set(id, true);
      }
      if (event.type === 'message_end' && event.message.role === 'assistant' && sdk.isUserInterruptAbort(event.message)) entry.interrupted = true;
    });
    entries.set(id, entry);
    // Durable model_change baseline at attach time: the launch entry already
    // exists here, so any later durable entry this process did not cause (see
    // the model_changed handler above) is an external explicit selection.
    try {
      const count = session.sessionManager?.getBranch?.().filter(e => e && e.type === 'model_change').length;
      modelChangeBaseline.set(id, typeof count === 'number' ? count : -1);
    } catch { modelChangeBaseline.set(id, -1); } // -1 = unknown -> never auto-select
    observeNativeCalls(session, () => nativeCallContext(session));
    return entry;
  }
  function nativeCallContext(session) {
    const agentId = agentIdFor(session.sessionId), member = memberTasks.has(agentId);
    if (!member && agentId !== sdk.MAIN_AGENT_ID) return null;
    const taskDir = member ? memberTasks.get(agentId) : taskDirs.get(session.sessionId);
    if (!taskDir) return null;
    let state;
    try {
      state = JSON.parse(readFileSync(path.join(taskDir, 'state.json'), 'utf8'));
      if (!ACTIVE.has(state.status)) return null;
    } catch { return null; }
    const model = session.model;
    // The Root phase is an intent declaration captured at message_start; it
    // rides the recorder meta so the switch's own (old-model) call stays in
    // its original phase and only the next new-model call carries the phase.
    const rootPhase = member ? undefined : rootPhaseByTask.get(taskDir);
    return { taskDir, projectRoot: state.project_root, role: member ? 'member' : 'root', agentId,
      ...(rootPhase ? { phase: rootPhase } : {}),
      workUnitId: memberWorkUnits.get(agentId)?.bound ? memberWorkUnits.get(agentId).unitId : undefined,
      actualProvider: model?.provider, actualModelId: model?.id,
      actualModel: model?.provider && model?.id ? `${model.provider}/${model.id}` : undefined,
      requestedModel: memberExpectedModels.get(agentId), billingRoute: billingRoute(model) };
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
  // Sets the member's real runtime cwd to the unit's current artifact_root
  // (Root's own session cwd is never touched). The SDK reads
  // sessionManager.getCwd() live for every tool context and hook ctx, so one
  // synchronous mutation at the registration/bind window — which provably
  // precedes member provider work — covers every later tool call. Read-back
  // verification is mandatory: a member whose cwd cannot reach the declared
  // workspace stays unbound and its tool gate stays closed.
  //
  // Refresh limit (installed OMP 18.3.4, verified against primary src):
  // refreshSkillsAndCommands re-discovers skills, commands and prompt
  // metadata for the new cwd. The before_agent_start hook below separately
  // discovers the bound workspace's AGENTS.md files and replaces the native
  // context; ctx.abort() stops the turn when that binding cannot be applied.
  function applyMemberWorkspace(id, session) {
    const pending = memberWorkUnits.get(id);
    if (!pending) return { ok: false, reason: 'actual dispatch has no Orbit work unit' };
    if (pending.workspaceRoot) {
      return session?.sessionManager?.getCwd?.() === pending.workspaceRoot
        ? { ok: true }
        : { ok: false, reason: 'member session cwd drifted from the work unit artifact_root' };
    }
    const report = runWorkUnit(pending.taskDir, 'read', { id: pending.unitId });
    if (!report.ok || !report.unit?.artifact_root)
      return { ok: false, reason: report.reason || 'work unit is unreadable' };
    let real;
    try { real = realpathSync(report.unit.artifact_root); } catch {
      return { ok: false, reason: `work unit artifact_root is not a real workspace: ${report.unit.artifact_root}` };
    }
    const manager = session?.sessionManager;
    if (manager?.getCwd?.() !== real) {
      if (typeof manager?.setCwdWithoutRelocation !== 'function')
        return { ok: false, reason: 'this OMP runtime cannot set the member session cwd' };
      try { manager.setCwdWithoutRelocation(real); } catch (error) {
        return { ok: false, reason: `member session cwd could not be set: ${String(error?.message || error).slice(0, 200)}` };
      }
      if (manager.getCwd?.() !== real)
        return { ok: false, reason: 'member session cwd did not reach the work unit artifact_root' };
    }
    pending.workspaceRoot = real;
    // Best-effort skills/commands/prompt-metadata realign (AGENTS limit above);
    // it never blocks the binding window.
    try { Promise.resolve(session.refreshSkillsAndCommands?.()).catch(() => {}); } catch { /* observation only */ }
    observeCollab({ kind: 'work_unit_workspace_applied', task_dir: pending.taskDir, agent_id: id,
      work_unit_id: pending.unitId, artifact_root: real, at: Date.now() });
    return { ok: true };
  }
  function bindMemberWorkUnit(id, actualModel) {
    const pending = memberWorkUnits.get(id);
    if (!pending) return { ok: false, reason: 'actual dispatch has no Orbit work unit' };
    if (pending.bound) return { ok: true };
    if (!pending.workspaceRoot) return { ok: false, reason: 'member session cwd is not the current unit artifact_root' };
    if (!actualModel) return { ok: false, reason: 'actual member model is not observable yet' };
    if (actualModel !== pending.expectedModel) return { ok: false, reason: 'actual member model differs from the dispatched model' };
    const result = runWorkUnit(pending.taskDir, 'bind', {
      id: pending.unitId, member_id: id, tool_call_id: pending.toolCallId,
      model: actualModel, ...(pending.hint || {})
    });
    if (result.ok) pending.bound = true;
    return result;
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
      captureMemberSnapshot(ref.id, ref);
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
        memberWorkUnits.set(ref.id, { taskDir, unitId: pending.unitId, toolCallId: pending.toolCallId,
          expectedModel: pending.expectedModel, hint: pending.hint, bound: false });
        if (pending.expectedModel) memberExpectedModels.set(ref.id, pending.expectedModel);
        requestedNames.delete(ref.id);
        // Durably attribute the member session from this moment on, and
        // record the actual model identity observed at registration
        // (provider/id only; members.json stays the authority).
        noteAssociation(ref.session?.sessionId ?? null, taskDir);
        noteModelIdentity({ taskDir, role: 'member', agentId: ref.id, sessionId: ref.session?.sessionId ?? null,
          model: ref.session?.model ? `${ref.session.model.provider}/${ref.session.model.id}` : null,
          requestedModel: pending.expectedModel ?? null });
        // The real runtime cwd must equal the current unit artifact_root
        // before any provider work (Root's cwd never changes). Failure leaves
        // the member unbound with its tool gate closed.
        if (ref.session) {
          const workspace = applyMemberWorkspace(ref.id, ref.session);
          if (!workspace.ok) {
            const aborted = signalAbort(ref.id);
            observeCollab({ kind: 'work_unit_binding_failed', task_dir: taskDir, agent_id: ref.id,
              work_unit_id: pending.unitId, reason: workspace.reason, abort_confirmed: aborted, at: Date.now() });
            process.stderr.write(`Orbit: member ${ref.id} workspace binding failed: ${workspace.reason}; abort confirmed: ${aborted}\n`);
            return;
          }
        }
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
          } else if (actual === pending.expectedModel) {
            const binding = bindMemberWorkUnit(ref.id, actual);
            if (!binding.ok) {
              const aborted = signalAbort(ref.id);
              process.stderr.write(`Orbit: member ${ref.id} work-unit binding failed: ${binding.reason}; abort confirmed: ${aborted}\n`);
              observeCollab({ kind: 'work_unit_binding_failed', task_dir: taskDir, agent_id: ref.id,
                work_unit_id: pending.unitId, reason: binding.reason, abort_confirmed: aborted, at: Date.now() });
            }
          }
        } else {
          // Some OMP versions attachSession after the registry notification.
          // Never label the declared model as observed at that earlier seam.
          observeCollab({ kind: 'work_unit_binding_pending', task_dir: taskDir, agent_id: ref.id,
            work_unit_id: pending.unitId, reason: 'actual session model is not observable at registration', at: Date.now() });
          if (ref.session) signalAbort(ref.id); // attached but unresolved is not runnable
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
  const uncontrolledDispatchNotified = new Set();
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
      rootPhaseByTask.delete(taskDir);
      rootToolSelectedByTask.delete(taskDir);
      for (const key of rootIntegrationAttempts.keys()) if (key.startsWith(JSON.stringify([taskDir]).slice(0, -1) + ','))
        rootIntegrationAttempts.delete(key);
      return { ok: false, reason: 'The bound Orbit task is not active for this Root; start a new Orbit task before delegating' };
    }
    return { ok: true, taskDir, state };
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
  const readiness = state => state?.completion_readiness && typeof state.completion_readiness === 'object'
    ? state.completion_readiness : { status: 'waiting', reason: '尚无当前版本的有效终检' };
  const checkInFlight = state => {
    const observations = state?.check_observations;
    if (!observations || typeof observations !== 'object') return false;
    for (const key in observations)
      if (Object.hasOwn(observations, key) && observations[key]?.status === 'in_flight') return true;
    return false;
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
  // User-facing phase for the OMP status bar (kickoff ⑤): state, why, and
  // whether the user must act. Operator commands stay in nextActionLabel and
  // phaseDirective (the Root-injected block), never here.
  const bounded = (text, max) => {
    const value = String(text ?? '').trim();
    return value.length > max ? `${value.slice(0, max)}…` : value;
  };
  function phaseLabel(state) {
    switch (state.status) {
      case 'complete': return '已完成（独立检查与停止确认；用户无需操作）';
      case 'paused': return '已暂停（已确认停止；若仍需交付请新建任务）';
      case 'needs_user': {
        const why = [state.stop_reason, state.error].find(v => typeof v === 'string' && v.trim());
        return why ? `需用户处理（已确认停止）：${bounded(why, 40)}` : '需用户处理（已确认停止）';
      }
      case 'stop_unconfirmed': return '停止尚未确认：尚不可称完成（须重试停止收尾）';
      case 'failed': return stopConfirmed(state) ? '运行失败（停止已确认）' : '运行失败（停止待核实）';
      default: break;
    }
    if (runtimeAbandoned(state)) return '任务处理进程已退出，须清理';
    if (state.completion_stop_pending) return '完成申请已入队，等待核对（用户无需操作）';
    if (openFindings(state) > 0 || recheckClues(state) > 0) return '检查仍有待处理问题（由助手继续处理，用户无需操作）';
    const current = readiness(state);
    if (current.status === 'invalidated') return `检查通知已失效（${bounded(current.reason, 40)}）：待助手重新终检，用户无需操作`;
    if (current.status === 'review_needed') return '先前不可交付理由已推翻：待助手手动终检（用户无需操作）';
    if (state.pending_finalization) return '等待当前版本检查通知（用户无需操作）';
    if (current.status === 'ready') return '可申请完成：停止收尾由助手完成（用户无需操作）';
    if (state.next_check_manual === true) return '等待手动终检（由助手请求），任务尚未完成';
    if (checkInFlight(state)) return '独立检查进行中，等待结果（用户无需操作）';
    const lastCheck = Array.isArray(state.checks) ? state.checks.at(-1) : null;
    if (lastCheck && !lastCheck.finished_at) return '独立检查进行中，任务尚未完成（用户无需操作）';
    if (current.status === 'not_ready') return `尚未就绪（${bounded(current.reason, 40)}）：由助手补齐交付，任务尚未完成`;
    return '尚无有效终检：由助手完成工作并请求终检；任务尚未完成';
  }
  // Display only: the Ruby completion gate remains authoritative.
  function nextActionLabel(state) {
    if (state.status === 'needs_user' || state.status === 'stop_unconfirmed') return '需要用户处理或重试停止确认';
    if (state.status === 'failed') return stopConfirmed(state) ? '运行失败，停止已确认' : '运行失败，需核实停止';
    if (!activeState(state)) return null;
    if (runtimeAbandoned(state)) return '运行进程已退出，显式普通 stop 清理；不能申请完成';
    if (state.completion_stop_pending) return '结束本轮回复，等待 Orbit 确认停止';
    const lastCheck = Array.isArray(state.checks) ? state.checks.filter(c => c && typeof c === 'object').at(-1) : null;
    if (state.next_check_trigger === 'rebind' || state.next_check_basis === '工作区重新绑定'
      || (lastCheck && Array.isArray(lastCheck.stale_reasons) && lastCheck.stale_reasons.includes('workspace'))) return '重新绑定工作区并重检';
    if (state.next_check_manual === true || state.pending_finalization) return '结束本轮，等待检查或通知';
    if (checkInFlight(state)) return '等待独立检查结果，不要再次请求';
    if (openFindings(state) > 0 || recheckClues(state) > 0) return '当前助手处理检查问题，再重检';
    const current = readiness(state);
    if (current.status === 'ready') return '当前助手调用 Orbit stop(intent=complete)，结束本轮';
    if (current.status === 'invalidated') return `当前通知已失效（${current.reason}）：仍需当前版本的有效手动终检`;
    if (current.status === 'review_needed') return '先前不可交付理由已推翻；当前助手请求新一轮手动终检';
    if (current.status === 'not_ready') return `补齐实际交付（${current.reason}），再请求一次有效手动终检（自动检查通过不替代终检）`;
    return '完成实际工作后调用 Orbit action=check 请求手动终检';
  }
  function phaseDirective(state) {
    if (state.completion_stop_pending) return '完成申请已入队。当前助手结束本轮，Orbit 才能核对产物、输入、成员及实际停止；不要重复申请。';
    if (openFindings(state) > 0 || recheckClues(state) > 0) return '先修正或核对检查问题，再请求最终检查；现在不能报告任务完成。';
    if (state.pending_finalization) return '当前版本的最终检查已就绪，等待通知；结束本轮，不要轮询。';
    if (checkInFlight(state)) return '独立检查进行中；直接结束本轮，通知会唤醒当前助手。不要调用 wait、轮询状态、查询 CLI 帮助或重复请求检查，也不要称任务已完成。';
    const current = readiness(state);
    if (current.status === 'ready') return '当前终检已就绪但任务尚未完成。当前助手现在调用 Orbit 工具 action=stop, intent=complete, task=<当前任务目录>，再正常结束本轮；普通 CLI orbit stop 仅暂停。被拒绝时按原因处理，不假称完成。';
    if (current.status === 'invalidated') return `检查通知已失效：${current.reason}。先在当前产物与要求上重新请求手动终检；旧通知不能用于完成申请，自动检查通过也不能替代。`;
    if (current.status === 'review_needed') return '裁定或后续独立检查已确认旧不可交付理由不成立；当前助手须在当前版本请求新的有效手动终检，自动检查和裁定均不发完成通知。';
    if (current.status === 'not_ready') return `独立检查未确认可交付：${current.reason}。先产生可核验的实际答复或产物，再请求新的有效手动终检。`;
    return '当前助手完成工作并实际验证，调用 Orbit action=check, task=<当前任务目录> 请求手动终检；在本轮回复中交付可核验结果并结束，终检会等待回复完成后开始。自动检查通过不会自动发完成通知。';
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
      ...(activeState(state) ? [
        '原生 task 派发前，用 Orbit work-unit declare 保存本次目标、有效要求、范围、验收及升级条件；在每个 task 文本中单独写一行 orbit-unit: <返回的wu-id>。',
        '工具仅限单元允许范围；成员不能改 Orbit／Git 内部记录、访问外部工具或二次派发。通过 hub 向 Root 回报；Root 核验实际结果后 finish accepted/rejected/failed。失败历史保留，依赖只在 accepted 后继续；无需用户逐次安排。',
        '识别到有界交接即可先 declare 工作单元供 Jev 评估并开始派发，无需 Root 先补证或全池校准完成；是否派发仍由 Root 自主决定。',
      ] : []),
      '新用户消息不自动修改旧任务：明确修订时调用 Orbit amend；独立问题按独立请求处理，必要时先确认归属。',
    ].join('\n');
  }
  // Root's first reachable request after an automatic entry start gets ONE
  // non-coercive advisory when the already-paid pre-start entry judgment
  // cleared its calibrated delegation threshold and no work unit exists yet.
  // It surfaces the stored fact only — never a member recommendation, never a
  // dispatch, no user confirmation, no cost/time comparison — and never
  // repeats (per task, in this process). Unknown or older traces, amended
  // inputs and already-declared units stay silent.
  const entryAdvisorySent = new Set();
  // The current production entry-calibration identity, mirroring the pins in
  // lib/orbit/prestart.rb (rule/question/input/decision versions, the
  // orbit-entry-calibration-v2 release schema and the supported observable
  // profile). A trace qualifies only when it actually carries THIS
  // calibration: a complete-but-old ruleset, an unknown calibration schema or
  // a model-drifted trace stays silent. The calibrated model itself is
  // verified through the trace's own facts (service-confirmed actual model
  // equals the requested/calibrated one), so no second model list is kept.
  const ENTRY_CURRENT = {
    rule: 'orbit-entry-rules-3', input: 'orbit-entry-input-2',
    decision: 'orbit-entry-decision-2', question_set: 'orbit-entry-3',
    calibration_schema: 'orbit-entry-calibration-v2',
    profile: 'git_untruncated_request_v1',
  };
  function entryDelegationAdvisory(state, taskDir) {
    if (!state || !taskDir || entryAdvisorySent.has(taskDir)) return null;
    const entry = state.entry;
    const trace = entry && entry.trace;
    if (!entry || !trace || entry.decision !== 'start') return null;
    const calibration = trace.calibration;
    if (trace.judgment_status !== 'answered' || !calibration || typeof calibration !== 'object') return null;
    if (trace.rule_version !== ENTRY_CURRENT.rule || trace.input_version !== ENTRY_CURRENT.input ||
        trace.decision_version !== ENTRY_CURRENT.decision ||
        trace.question_set_version !== ENTRY_CURRENT.question_set) return null;
    if (calibration.schema_version !== ENTRY_CURRENT.calibration_schema) return null;
    if (calibration.profile !== ENTRY_CURRENT.profile) return null;
    // The release binding must be the same current ruleset as the trace, and
    // the pinned question digest must be present and identical on both sides.
    if (typeof trace.question_digest !== 'string' || !trace.question_digest ||
        calibration.question_digest !== trace.question_digest ||
        calibration.rule_version !== trace.rule_version ||
        calibration.input_version !== trace.input_version ||
        calibration.decision_version !== trace.decision_version ||
        calibration.question_set_version !== trace.question_set_version) return null;
    // The calibrated model and thresholds recorded on the release must be the
    // ones this trace actually ran and was scored with (no second model list,
    // no caller-supplied value accepted).
    if (typeof trace.requested_model !== 'string' || !trace.requested_model ||
        trace.actual_model !== trace.requested_model ||
        calibration.model !== trace.requested_model ||
        calibration.thresholds?.delegation_value !== trace.thresholds?.delegation_value) return null;
    if (trace.provider !== 'typesafe') return null;
    const value = trace.probabilities?.delegation_value?.probability_true;
    const threshold = trace.thresholds?.delegation_value;
    if (typeof value !== 'number' || !Number.isFinite(value) ||
        typeof threshold !== 'number' || !Number.isFinite(threshold)) return null;
    if (!(value >= threshold)) return null;
    if (Array.isArray(state.amendments) && state.amendments.length > 0) return null;
    // Unknown unit state fails closed: without a readable work-units file the
    // advisory stays silent instead of guessing whether work was handed off.
    // A MISSING file is the fresh-task no-handoff state, not unknown.
    try {
      const units = JSON.parse(readFileSync(path.join(taskDir, 'work-units.json'), 'utf8'));
      if (units?.units && Object.keys(units.units).length > 0) return null;
    } catch (error) {
      if (error?.code !== 'ENOENT') return null;
    }
    // Caller marks entryAdvisorySent only after a successful injection.
    return `[orbit-entry-advisory] 入口判断显示本任务具备实质交接价值（delegation_value ${value.toFixed(2)} ≥ 校准阈值 ${threshold.toFixed(2)}）；` +
      '若识别到有界子任务，可先用 Orbit work-unit declare 供两阶段评估再决定是否派发，' +
      '也可说明选择自行实施的依据——是否分工由 Root 自主决定。';
  }
  // A newly controlled task must learn, in the FIRST request the model actually
  // answers, that a work unit comes before implementation. The entry advisory
  // above depends on the entry-3 judgment (a calibrated delegation probability),
  // so a task started by an explicit request — which never runs that judgment —
  // received no guidance, and Root began editing with no unit and therefore no
  // candidate to dispatch. This bootstrap depends on no probability: it fires
  // for any controlled active task whose work-unit store is still empty, is
  // task-scoped, is marked sent only after a successful injection, and leaves an
  // unextendable payload pending for the next reachable window.
  const bootstrapSent = new Set();
  const BOOTSTRAP_LINE = '[orbit-bootstrap] 本任务已受控但尚无工作单元：开始实现前先用 Orbit work-unit declare ' +
    '保存目标、有效要求、范围、验收与升级条件（并在原生 task 文本中写一行 orbit-unit: <wu-id>），' +
    '或说明自行实施的依据——是否派发由 Root 自主决定。';

  // declared / none / unknown, read from the task's own durable store only.
  function workUnitState(taskDir) {
    try {
      const units = JSON.parse(readFileSync(path.join(taskDir, 'work-units.json'), 'utf8'));
      return units?.units && Object.keys(units.units).length > 0 ? 'declared' : 'none';
    } catch (error) {
      return error?.code === 'ENOENT' ? 'none' : 'unknown';
    }
  }
  function bootstrapGuidance(state, taskDir) {
    if (!state || !taskDir || bootstrapSent.has(taskDir) || !activeState(state)) return null;
    return workUnitState(taskDir) === 'none' ? BOOTSTRAP_LINE : null;
  }
  // Both first-request guidance lines travel in ONE append to the CURRENT
  // provider payload (the request being answered right now): the auto entry
  // start happens inside this hook, so this window is the first reachable one —
  // before_agent_start runs before the task exists. Appending them separately
  // would be payload-safe too (appendInstructionToPayload never mutates), but
  // two returns raced: a successful advisory's early return dropped the
  // bootstrap from the auto-start payload. Each line marks its own sent set
  // only after this shared append succeeded, so an unextendable payload leaves
  // both pending (no sent mark, no abort) for the next reachable window and
  // claims no delivery.
  function injectEntryGuidance(payload, state, taskDir) {
    if (!payload) return null;
    const advisory = entryAdvisorySent.has(taskDir) ? null : entryDelegationAdvisory(state, taskDir);
    const bootstrap = bootstrapSent.has(taskDir) ? null : bootstrapGuidance(state, taskDir);
    if (!advisory && !bootstrap) return null;
    const injected = appendInstructionToPayload(payload, [advisory, bootstrap].filter(Boolean).join('\n\n'));
    if (!injected) return null;
    if (advisory) entryAdvisorySent.add(taskDir);
    if (bootstrap) bootstrapSent.add(taskDir);
    return { payload: injected, bootstrap: Boolean(bootstrap) };
  }
  // ---- controlled-Root cooperation policy (system layer) -------------------
  // The native system prompt of a "restrained" model tells Root to keep work
  // inline ("NEVER delegate one slice"; fan out only for "2+ independent
  // slices"). The product rule this extension implements is narrower and
  // incompatible with that blanket default: a BOUNDED SINGLE-MEMBER SERIAL
  // handoff may carry real implementation. The policy therefore travels in the
  // SAME layer as the native system/developer instructions — never in the
  // trailing user message, where it would sit below them. It is a policy, not
  // a one-shot: it is re-applied on every reachable provider request and is
  // idempotent within one request (marker check).
  const POLICY_VERSION = 'orbit-cooperation-policy-1';
  const POLICY_MARKER = '[orbit-cooperation-policy]';
  const POLICY_LINE = `${POLICY_MARKER} 若本模型原生默认以“仅 2+ 独立片段才委派”或“不委派单一片段”限制交接，本受控任务适用以下有界交接规则：` +
    '识别到可实质交接的实现、且 Root 能独自集成与核验时，先声明工作单元供 Jev two-stage 真实适配判断，' +
    '再依据该判断返回的 hint，或带局限的 Root 选择，决定是否用原生 task 派发；' +
    '单一成员、共享接口或需要等待依赖都不单独构成拒派理由。没有合适单元、短小低收益的任务仍可有据自行实现。' +
    '用户要求、目标项目规则与工具权限照常不变；程序不代替 Root 派发、不增加用户批准、不强制每个任务派成员，也不提高适配分。' +
    '质量与成本未知仍为未知；入口高 delegation 概率不是实际候选推荐。';
  const policyRecorded = new Set(); // `${taskDir}:${version}:${channel}`

  // Same-layer, shape-recognised append; returns the modified payload and the
  // channel actually used, or null when this release cannot place the text at
  // the system/developer layer. The caller must NOT fall back to the trailing
  // user message: an unextendable request stays honestly undelivered.
  function appendPolicyToSystemLayer(payload, text) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
    // OpenAI Responses / Codex: the native system block is the top-level
    // `instructions` string (a Responses-Lite reshape later moves this same
    // text into a leading developer message, still the authoritative layer).
    if (typeof payload.instructions === 'string') {
      if (!payload.instructions.trim()) return null;
      if (payload.instructions.includes(POLICY_MARKER)) return { payload, channel: 'instructions', already: true };
      return { payload: { ...payload, instructions: `${payload.instructions}\n\n${text}` }, channel: 'instructions' };
    }
    // Anthropic Messages: top-level `system` (string or text-block array).
    if (typeof payload.system === 'string') {
      if (!payload.system.trim()) return null;
      if (payload.system.includes(POLICY_MARKER)) return { payload, channel: 'system', already: true };
      return { payload: { ...payload, system: `${payload.system}\n\n${text}` }, channel: 'system' };
    }
    if (Array.isArray(payload.system)) {
      const parts = payload.system;
      if (parts.some(part => typeof part === 'string' && part.includes(POLICY_MARKER)) ||
          parts.some(part => part && typeof part === 'object' && typeof part.text === 'string' && part.text.includes(POLICY_MARKER)))
        return { payload, channel: 'system_blocks', already: true };
      const last = parts[parts.length - 1];
      if (last && typeof last === 'object' && !Array.isArray(last) && last.type === 'text' && typeof last.text === 'string')
        return { payload: { ...payload, system: [...parts.slice(0, -1), { ...last, text: `${last.text}\n\n${text}` }] },
          channel: 'system_blocks' };
      if (parts.every(part => part && typeof part === 'object' && part.type === 'text'))
        return { payload: { ...payload, system: [...parts, { type: 'text', text }] }, channel: 'system_blocks' };
      return null;
    }
    // Responses bodies: the native instruction can already live in the input
    // item list (Codex `responses-lite` moves the top-level instructions into a
    // leading developer message). Append AFTER the native text INSIDE that same
    // developer block — prepending our text ahead of a conflicting native block
    // would not have covered it.
    if (Array.isArray(payload.input)) {
      for (let index = 0; index < payload.input.length; index++) {
        const item = payload.input[index];
        if (!item || typeof item !== 'object' || item.type !== 'message' || item.role !== 'developer' || !Array.isArray(item.content)) continue;
        const texts = item.content.filter(part => part && typeof part === 'object' && part.type === 'input_text' && typeof part.text === 'string');
        if (texts.some(part => part.text.includes(POLICY_MARKER))) return { payload, channel: 'developer', already: true };
        if (!texts.length) continue; // keep looking for the native text block
        const lastText = texts[texts.length - 1];
        const content = item.content.map(part => part === lastText ? { ...part, text: `${part.text}\n\n${text}` } : part);
        return { payload: { ...payload, input: [
          ...payload.input.slice(0, index), { ...item, content }, ...payload.input.slice(index + 1)] }, channel: 'developer' };
      }
      return null;
    }
    // Chat-completions bodies: the native system text can be a `system` message
    // OR a `developer` message — the SDK picks role developer when the model
    // reasons and the compat profile supports it (openai-completions.ts
    // `useDeveloperRole = model.reasoning && compat.supportsDeveloperRole`).
    // Append into the LAST such native block so our text follows all native
    // system/developer text; never invent a role, never touch user or tool
    // messages.
    if (Array.isArray(payload.messages)) {
      let index = -1;
      for (let cursor = payload.messages.length - 1; cursor >= 0; cursor--) {
        const candidate = payload.messages[cursor];
        if (candidate && typeof candidate === 'object' && (candidate.role === 'system' || candidate.role === 'developer')) { index = cursor; break; }
      }
      if (index < 0) return null;
      const item = payload.messages[index];
      const channel = item.role === 'developer' ? 'developer_message' : 'system_message';
      const replace = content => ({ ...payload, messages: payload.messages.map((value, i) => i === index ? { ...item, content } : value) });
      if (typeof item.content === 'string') {
        if (item.content.includes(POLICY_MARKER)) return { payload, channel, already: true };
        return { payload: replace(`${item.content}\n\n${text}`), channel };
      }
      if (Array.isArray(item.content) && item.content.length > 0) {
        const texts = item.content.filter(part => part && typeof part === 'object' && typeof part.text === 'string');
        if (texts.some(part => part.text.includes(POLICY_MARKER))) return { payload, channel, already: true };
        const lastText = texts[texts.length - 1];
        if (!lastText) return null;
        return { payload: replace(item.content.map(part => part === lastText ? { ...part, text: `${part.text}\n\n${text}` } : part)),
          channel };
      }
      return null;
    }
    return null;
  }

  // Ownership is re-verified against the real control socket on every request:
  // a `running` record whose runtime is gone, or one created by another
  // process, is NOT treated as ours. No cache — the owner boundary is a
  // correctness fact, not a performance knob.
  async function verifiedOwnership(sessionId, taskDir) {
    try { return host ? await host.ownsTask(taskDir, sessionId) : false; } catch { return false; }
  }

  // One request's policy delivery. Controlled Main + ACTIVE state are required
  // by the caller; this additionally re-verifies real ownership and runtime
  // liveness, and refuses payload shapes it cannot place at the system layer.
  async function applyCooperationPolicy(payload, sessionId, ctx, bound, { owned } = {}) {
    if (!payload || !bound?.taskDir || !activeState(bound.state)) return null;
    if (!(owned ?? await verifiedOwnership(sessionId, bound.taskDir))) return null;
    if (runtimeAbandoned(bound.state)) return null;
    const placed = appendPolicyToSystemLayer(payload, POLICY_LINE);
    if (!placed) return null;
    if (!placed.already) {
      const key = `${bound.taskDir}:${POLICY_VERSION}:${placed.channel}`;
      if (!policyRecorded.has(key)) {
        policyRecorded.add(key);
        // Minimal first-delivery fact: channel, version, real task/session/model
        // and the injected text fingerprint. No raw payload, no credentials, and
        // no claim that the server received it or that the model complied.
        recordCollabFor(bound.taskDir, {
          kind: 'cooperation_policy', at: Date.now(),
          session_id: sessionId, agent_id: sdk.MAIN_AGENT_ID,
          task_id: bound.state?.id ?? null,
          model: ctx?.model ? `${ctx.model.provider}/${ctx.model.id}` : null,
          channel: placed.channel, policy_version: POLICY_VERSION,
          instruction_sha256: `sha256:${createHash('sha256').update(POLICY_LINE).digest('hex')}`,
          delivered_claim: 'the extension modified this request payload at the system/developer layer; no server receipt and no model-compliance claim',
        });
      }
    }
    return { payload: placed.payload, channel: placed.channel };
  }

  function bootstrapFacts(taskDir, state, ctx, kind, extra = {}) {
    let instructionDigest = null;
    try {
      instructionDigest = `sha256:${createHash('sha256').update(readFileSync(path.join(taskDir, 'instruction.txt'))).digest('hex')}`;
    } catch { /* unknown */ }
    return {
      kind, at: Date.now(),
      session_id: ctx?.sessionManager?.getSessionId?.() ?? null,
      task_dir: taskDir, task_id: state?.id ?? null,
      native_user_message_id: state?.instruction_source?.id ?? null,
      instruction_digest: instructionDigest, input_digest: null,
      artifact_root: state?.workspace?.artifact_root ?? null,
      model: ctx?.model ? `${ctx.model.provider}/${ctx.model.id}` : null,
      work_unit_state: workUnitState(taskDir),
      ...extra,
    };
  }
  // Program-visible execution already present in this Root branch before the
  // current native user message: an assistant message carrying at least one
  // toolCall content item. Prose, quotes and replies are never execution.
  function hasPriorToolCall(branch, beforeIndex) {
    for (let index = 0; index < beforeIndex; index++) {
      const item = branch[index];
      if (item?.type !== 'message' || item.message?.role !== 'assistant') continue;
      const content = item.message.content;
      if (Array.isArray(content) && content.some(part => part?.type === 'toolCall')) return true;
    }
    return false;
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
      if (taskDirs.get(sessionId) === known) {
        taskDirs.delete(sessionId); rootPhaseByTask.delete(known); rootToolSelectedByTask.delete(known);
        for (const key of rootIntegrationAttempts.keys()) if (key.startsWith(JSON.stringify([known]).slice(0, -1) + ','))
          rootIntegrationAttempts.delete(key);
      }
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
  let statusWatch = null;
  function stopStatusWatch() {
    if (statusWatch) unwatchFile(statusWatch.file, statusWatch.listener);
    statusWatch = null;
  }
  function watchStatus(taskDir, ctx, sessionId) {
    if (typeof ctx?.ui?.setStatus !== 'function') return;
    const file = path.join(taskDir, 'state.json');
    if (statusWatch?.file === file && statusWatch.ctx === ctx) return;
    stopStatusWatch();
    const listener = () => { refreshStatus(ctx, sessionId).catch(() => {}); };
    statusWatch = { file, ctx, listener };
    // Display only. Runtime completion after the closing turn must update the
    // idle pane without paying for another model turn or a status tool call.
    watchFile(file, { persistent: false, interval: 1000 }, listener);
  }
  async function refreshStatus(ctx, sessionId) {
    try {
      const bound = await resolveBoundTask(sessionId, ctx?.cwd);
      if (!bound) { stopStatusWatch(); applyStatus(ctx, undefined); return null; }
      watchStatus(bound.taskDir, ctx, sessionId);
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
  // Root OMP session file path from the main AgentRegistry ref, when the
  // ref exposes one: a durable REFERENCE only (never session content), so
  // TaskRuntime can record which native session file belongs to this task
  // for safe task-scoped export. Lazily looked up per state() RPC; null
  // when the registry surface or the ref has no file.
  function sessionFileFor(sessionId) {
    try {
      const ref = sdk.AgentRegistry.global().list().find(r => r.session?.sessionId === sessionId);
      return typeof ref?.sessionFile === 'string' && ref.sessionFile ? ref.sessionFile : null;
    } catch { return null; }
  }
  // Raw durable receipts of the Root session's own bound task; empty when
  // the session has no bound task (never another task's or member's file).
  function rootVerificationsFor(sessionId) {
    const taskDir = taskDirs.get(sessionId);
    return taskDir ? readReceipts(taskDir) : [];
  }
  // Bounded recent-history window for process observation (stuck/off_track):
  // the NEWEST N observation EVENTS (assistant/toolResult entries) before the
  // last assistant, enough to compare a consecutive-failure run; the whole
  // branch is never copied. Older events get one truthful omission marker.
  const RECENT_EVENT_WINDOW = 18;
  // Native tool-call metadata for assistant observation entries. A
  // toolCall-only assistant message projects EMPTY text (delivery honesty is
  // preserved — never a borrowed earlier answer), which otherwise discards
  // the native declared intent and file target BEFORE stuck/off_track
  // assessment. These summaries carry only truthful metadata: native
  // tool_call id, native name, the native DECLARED intent (a declaration by
  // the model, not proof any work executed) and the plain `arguments.path`
  // target for read/write/edit only. Everything else — raw arguments, file
  // bodies, patches, bash commands, eval code — never enters THIS SUMMARY
  // (existing toolResult output projection is unchanged); embedded paths
  // inside eval/bash are NOT guessed. At most the NEWEST 3 native toolCalls
  // in native order; more calls yield a real omission count; missing native
  // values stay 'unknown'; every field is character-bounded with a truthful
  // truncation marker. An assistant with no toolCalls gets no extra field.
  const TOOL_CALL_SUMMARY_MAX = 3;
  const TOOL_CALL_FIELD_LIMITS = { id: 128, name: 64, declared_intent: 400, target: 400 };
  const TOOL_CALL_TARGET_TOOLS = new Set(['read', 'write', 'edit']);
  function toolCallSummaries(content) {
    const calls = Array.isArray(content)
      ? content.filter(part => part && typeof part === 'object' && part.type === 'toolCall') : [];
    if (calls.length === 0) return null;
    const bounded = (value, limit) => {
      const text = typeof value === 'string' && value ? value : 'unknown';
      return text.length > limit ? { value: `${text.slice(0, limit)}…`, truncated: true } : { value: text, truncated: false };
    };
    const summaries = calls.slice(-TOOL_CALL_SUMMARY_MAX).map(call => {
      const args = call.arguments;
      const rawTarget = TOOL_CALL_TARGET_TOOLS.has(call.name) && args && typeof args === 'object'
        && typeof args.path === 'string' && args.path ? args.path : null;
      const fields = {
        id: bounded(call.id, TOOL_CALL_FIELD_LIMITS.id),
        name: bounded(call.name, TOOL_CALL_FIELD_LIMITS.name),
        declared_intent: bounded(call.intent, TOOL_CALL_FIELD_LIMITS.declared_intent),
        target: bounded(rawTarget, TOOL_CALL_FIELD_LIMITS.target)
      };
      const truncated = Object.keys(fields).filter(key => fields[key].truncated);
      return { id: fields.id.value, name: fields.name.value,
        declared_intent: fields.declared_intent.value, target: fields.target.value,
        ...(truncated.length ? { truncated_fields: truncated } : {}) };
    });
    return calls.length > TOOL_CALL_SUMMARY_MAX
      ? { tool_calls: summaries, omitted_tool_calls: calls.length - TOOL_CALL_SUMMARY_MAX }
      : { tool_calls: summaries };
  }
  function state(entry) {
    const session = entry.session;
    const branch = session.sessionManager.getBranch();
    let lastIndex = -1;
    let lastUserBeforeLastAssistant = null;
    for (let i = branch.length - 1; i >= 0; i--) {
      const item = branch[i];
      if (lastIndex < 0) {
        if (item.type === 'message' && item.message.role === 'assistant') lastIndex = i;
      } else if (item.type === 'message' && item.message.role === 'user') {
        lastUserBeforeLastAssistant = item.id;
        break;
      }
    }
    const last = branch[lastIndex];
    const busy = session.isStreaming || session.isCompacting || session.isBashRunning || session.isEvalRunning || session.hasPendingAsyncWork() || entry.pending > 0;
    const message = last?.message;
    const observations = last ? [{ kind: 'agent_message', text: textOf(message.content), ...toolCallSummaries(message.content) }] : [];
    for (let i = lastIndex + 1; i < branch.length && last; i++) {
      const item = branch[i];
      if (item.type === 'message' && item.message.role === 'toolResult') {
        observations.push({ kind: 'command', tool: item.message.toolName,
          status: item.message.isError ? 'failed' : 'completed', aggregated_output: textOf(item.message.content).slice(0, 2000) });
      }
    }
    // Bounded RECENT history: process observation (stuck/off_track) must see
    // consecutive failed turns, not just the last one. We collect events
    // between the nearest user boundary and the last assistant (the CURRENT
    // user turn's real history only — an older task's or an unrelated user
    // turn's evidence never enters), then keep only the NEWEST N observation
    // events in native order. Older events are summarized by one truthful
    // omission marker with a real count — never silently dropped. Without a
    // trusted boundary we do not guess that older branch content belongs to
    // the current task (empty history, not "everything").
    // N counts observation EVENTS (assistant/toolResult entries), not whole
    // rounds; it is large enough to compare a consecutive-failure run and
    // bounded so the whole branch is never copied into memory.
    if (lastUserBeforeLastAssistant !== null) {
      const boundary = branch.findIndex(item => item.id === lastUserBeforeLastAssistant);
      if (boundary >= 0) {
        let total = 0;
        for (let i = boundary + 1; i < lastIndex; i++) {
          const role = branch[i]?.type === 'message' ? branch[i].message?.role : null;
          if (role === 'assistant' || role === 'toolResult') total++;
        }
        let kept = 0;
        for (let i = lastIndex - 1; i > boundary && kept < RECENT_EVENT_WINDOW; i--) {
          const item = branch[i];
          if (item?.type !== 'message') continue;
          const role = item.message?.role;
          if (role === 'assistant') {
            observations.unshift({ kind: 'prior_agent_message', turn_id: item.id,
              text: textOf(item.message.content).slice(0, 2000),
              stop_reason: item.message.stopReason ?? null, ...toolCallSummaries(item.message.content) });
            kept++;
          } else if (role === 'toolResult') {
            observations.unshift({ kind: 'prior_command', message_id: item.id,
              tool: item.message.toolName,
              status: item.message.isError ? 'failed' : 'completed',
              aggregated_output: textOf(item.message.content).slice(0, 2000) });
            kept++;
          }
        }
        if (total > kept) observations.unshift({ kind: 'omitted_older_history', count: total - kept });
      }
    }
    // The nearest native user before the last assistant is the origin of
    // last_turn_id once that turn completes. Orbit injections are not users.
    return { thread_id: entry.id, cwd: session.sessionManager.getCwd(), status: busy ? 'active' : 'idle', interrupted: entry.interrupted,
      turn_id: busy ? last?.id : null, last_turn_id: last?.id || (entry.error ? 'delivery-error' : null),
      last_turn_user_message_id: lastUserBeforeLastAssistant,
      last_turn_status: entry.interrupted ? 'interrupted' : busy ? 'inProgress' : entry.error || ['error', 'aborted'].includes(message?.stopReason) ? 'failed' : last ? 'completed' : null,
      observations: entry.error ? [...observations, { kind: 'error', text: entry.error }] : observations,
      active_tools: entry.activeTools.size, async_jobs: session.getAsyncJobSnapshot(), session_file: sessionFileFor(entry.id),
      // Facts captured from this Root session's own real tool executions for
      // its bound task only (receipts live in <task_dir>/root-verifications.jsonl,
      // so they survive later assistant messages and are never mixed across
      // tasks or members). Raw facts as stored — the Ruby start_check computes
      // artifact_matches/input_matches against its own snapshot and input.
      root_verifications: rootVerificationsFor(entry.id) };
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
  // The CURRENT task's own accepted-send markers, read once from its durable
  // state (state.json sent_message_ids — the ids send() ACKed for exactly
  // this task). Only these may ever be removed from the session queues: a
  // different task's Orbit markers (a rebound or prior binding) and every
  // other source stay. No task dir or an unreadable record means NO surgery —
  // attribution is never guessed and failure is never papered over.
  // Returns { markers } for a bound task (its durable accepted-send ids),
  // null when this session has no bound task dir (the ordinary stop path),
  // or { error } when a bound task's attribution record exists but cannot be
  // read/parsed — a failure that must SURFACE, never be swallowed into a
  // confirmed stop, and never justify deleting messages of unknown ownership.
  async function currentTaskSentIds(entry) {
    const taskDir = taskDirs.get(entry.id);
    if (!taskDir) return null;
    let taskState;
    try {
      taskState = JSON.parse(await fs.readFile(path.join(taskDir, 'state.json'), 'utf8'));
    } catch (error) {
      return { error: `sent-id attribution unreadable for ${entry.id}: ${error.message}` };
    }
    // An ABSENT field is legitimate (TaskRecord does not initialize it; the
    // runtime writes it on first save — a never-sent task has nothing of
    // ours queued). A PRESENT field of the wrong shape is real corruption.
    const ids = taskState.sent_message_ids;
    if (ids === undefined || ids === null) return { markers: new Set() };
    if (!Array.isArray(ids)) return { error: `sent-id attribution malformed for ${entry.id}` };
    const markers = new Set(ids.filter(id => typeof id === 'string' && id));
    return { markers };
  }
  // An own stranded marker that is OBSERVABLE in the queues but cannot be
  // removed (no public replaceQueues) would resurrect the session after stop —
  // that must fail honestly too, never confirm over an unremovable own wake.
  function ownMarkerUnremovable(session, markers) {
    const agent = session.agent;
    if (!markers || !agent || typeof agent.peekSteeringQueue !== 'function' ||
        typeof agent.peekFollowUpQueue !== 'function') return null;
    if (typeof agent.replaceQueues === 'function') return null;
    const isOwn = message => message && message.role === 'custom' && message.customType === 'orbit' &&
      markers.has(message.details?.orbitMessage);
    return [...agent.peekSteeringQueue(), ...agent.peekFollowUpQueue()].some(isOwn)
      ? { error: `own stranded Orbit marker queued but replaceQueues is unavailable for ${session.sessionId}` }
      : null;
  }
  // Precise removal of this task's stranded Orbit messages from the session's
  // agent queues: public Agent.peek*/replaceQueues only, exact marker match
  // (role custom + customType orbit + the id in the CURRENT task's durable
  // sent set), order-preserving. Absent capability or unknown attribution = no
  // surgery.
  function removeQueuedOrbitMarkers(session, markers) {
    const agent = session.agent;
    if (!agent || typeof agent.peekSteeringQueue !== 'function' ||
        typeof agent.peekFollowUpQueue !== 'function' ||
        typeof agent.replaceQueues !== 'function' || !markers) return;
    const isOwn = message => message && message.role === 'custom' && message.customType === 'orbit' &&
      markers.has(message.details?.orbitMessage);
    const steering = [...agent.peekSteeringQueue()];
    const followUp = [...agent.peekFollowUpQueue()];
    const keptSteering = steering.filter(message => !isOwn(message));
    const keptFollowUp = followUp.filter(message => !isOwn(message));
    if (keptSteering.length !== steering.length || keptFollowUp.length !== followUp.length)
      agent.replaceQueues(keptSteering, keptFollowUp);
  }
  async function stop(entry) {
    const session = entry.session;
    const manager = session.asyncJobManager, owner = session.getAgentId();
    if (!owner) throw new Error('OMP session has no native async-work owner');
    // runModeExitTeardown is the SDK's OWN bounded guard that keeps abort's
    // stranded-queue drain from auto-resuming the session across a teardown's
    // awaits (18.3.4 agent-session.ts:7621). When present it wraps the ENTIRE
    // stop sequence so cancel/reap/confirmation observe real state, not a
    // session resurrected by its own queued messages; an older SDK without it
    // keeps the legacy sequence (no ordinary stop is refused just because the
    // guard is unavailable).
    const teardown = typeof session.runModeExitTeardown === 'function'
      ? session.runModeExitTeardown.bind(session) : null;
    let confirmation;
    const work = async () => {
      // Attribution read ONCE from the CURRENT task's durable record; both
      // cleanup passes below use this exact set (no session-wide history).
      // A READ/SHAPE FAILURE IS PRESERVED, not swallowed: the owner's
      // cancel/abort/reap still run below, and the failure is thrown AFTER
      // them — a bound task's stop never reports confirmed over unknown
      // attribution, and no message of unknown ownership is ever removed.
      const attribution = await currentTaskSentIds(entry);
      const markers = attribution?.markers ?? null;
      // Suppress THIS owner's async deliveries at the source first: a job
      // that already finished with a DEFERRED delivery otherwise injects an
      // async-result follow-up after abort and wakes a fresh turn (35 task
      // 22b36fa0: bg_2's completed-but-deferred result landed after the
      // interrupt and the model re-Asked at 10:19:42).
      // acknowledgeDeliveries only suppresses delivery — it never marks
      // results consumed or verified. Then drop this session's already
      // queued async-result entries via the same public cleanup the SDK
      // applies on its own owner-cancel path.
      if (manager && typeof manager.getAllJobs === 'function' &&
          typeof manager.acknowledgeDeliveries === 'function') {
        const ownIds = manager.getAllJobs({ ownerId: owner }).map(job => job.id).filter(Boolean);
        if (ownIds.length) manager.acknowledgeDeliveries(ownIds);
      }
      if (session.yieldQueue && typeof session.yieldQueue.clear === 'function')
        session.yieldQueue.clear('async-result');
      if (manager) manager.cancelAll({ ownerId: owner });
      // Remove the already-attributed stranded Orbit hint BEFORE abort, so
      // the guard starts from a queue holding no own marker.
      removeQueuedOrbitMarkers(session, markers);
      if (state(entry).status !== 'idle' || entry.activeTools.size) await session.abort({ goalReason: 'internal' });
      // Cancellation labels precede process exit. Reap actual native job promises.
      if (manager && !(await manager.cancelAndReapOwnerJobs(owner, Date.now() + 5000)).settled)
        throw new Error(`OMP background processes did not settle for ${entry.id}`);
      // abort can requeue live-steered input, so the same precise cleanup
      // runs again AFTER abort/reap, still inside the guard.
      removeQueuedOrbitMarkers(session, markers);
      // Attribution/unremovability failures surface only after the owner's
      // cancel/abort/reap attempts completed (an own marker that is visible
      // but not removable would resurrect the session after stop).
      const unremovable = ownMarkerUnremovable(session, markers);
      const failure = attribution?.error || unremovable?.error;
      if (failure) throw new Error(failure);
      for (let n = 0; n < 50; n++) {
        const after = state(entry);
        // A suppressed delivery never wakes the loop, but an unsuppressed
        // pending wake (e.g. a job id created after the suppression
        // snapshot) is real pending work: confirmation waits or fails
        // honestly — never reports success over a live wake source.
        const pendingWake = typeof session.hasPendingAsyncWork === 'function'
          ? session.hasPendingAsyncWork() : false;
        if (after.status === 'idle' && after.active_tools === 0 && !pendingWake) {
          await flushNativeCalls(taskDirs.get(entry.id));
          confirmation = { confirmed: true, thread_id: entry.id,
          scope: 'Native session execution, attached shell processes and owner-scoped async jobs; no unmanaged detached work',
          native_owner: owner, status_after: after.status, active_tools_after: 0, async_jobs_settled: true };
          return;
        }
        await pause(100);
      }
      throw new Error(`OMP execution did not stop for ${entry.id}`);
    };
    // runModeExitTeardown returns void (the SDK only awaits the callback), so
    // the confirmation is captured by the callback and returned after the
    // guard closes; a legacy session runs the work directly.
    if (teardown) await teardown(work);
    else await work();
    return confirmation;
  }
  // Member-scoped bridge: native task members have no `entries` record (no
  // Orbit-owned session id); they are addressed by their ACTUAL OMP agent id
  // as recorded in the task's members.json. Shapes:
  //   member_state  { id } ->
  //     { id, registry_status, streaming, model, activity, session_id,
  //       session_file, output_path, active_tools, async_jobs,
  //       session_attached, retained_snapshot, lifecycle, last_turn_error }
  //   member_result { id } ->
  //     { id, registry_status, output_path, output_text (bounded 2000 chars),
  //       output_mtime, output_size }
  //   send_member   { id, text } -> { id, action: 'native_custom_message' }
  //     (steer custom message; reaches waiting members like Root corrections)
  //   stop_member   { id } ->
  //     { confirmed, id, scope, status_after, active_tools_after,
  //       async_jobs_settled }  — aborts the turn, cancels owner-scoped async
  //     jobs and REAPS them; a settle timeout throws instead of reporting
  //     success. Parked/never-started members (no live session) error.
  // A detached registry ref is read-served from the last readable snapshot
  // (member_state/member_result only); last_turn_error is the SDK session's
  // own structured last assistant error turn, never prose-based.
  async function memberDispatch(request) {
    // Native /exit can unregister the child before Orbit's shutdown hook.
    // stop_member may use our exact retained session (or an already verified
    // stop receipt); reads fall back to a retained read-only snapshot, and
    // send_member still requires a live registry identity.
    const registered = sdk.AgentRegistry.global().get(request.id);
    if (registered) captureMemberSnapshot(request.id, registered);
    const retainedStop = request.method === 'stop_member' && nativeMemberIds.has(request.id) &&
      (memberRetainedSessions.has(request.id) || memberStopConfirmations.has(request.id));
    // Read-side retention: a finished member's registry ref can be detached
    // (native /exit, park/abort) with no public signal. member_state and
    // member_result fall back to the last READABLE snapshot so an already
    // observed terminal fact (status, lifecycle, persisted output) does not
    // vanish with the ref. Reads are read-only: ownership (nativeMemberIds +
    // memberTaskFor) and the stop barrier keep their exact rules, and
    // send_member still requires a live session.
    const retainedRead = (request.method === 'member_state' || request.method === 'member_result') &&
      nativeMemberIds.has(request.id) && memberRetainedSnapshots.has(request.id);
    const snapshot = retainedRead ? memberRetainedSnapshots.get(request.id) : null;
    const ref = registered ?? (retainedStop ? { id: request.id, status: null, session: null }
      : (snapshot ? { id: request.id, status: snapshot.status, session: null, lifecycle: snapshot.lifecycle,
          activity: snapshot.activity, sessionFile: snapshot.sessionFile, history: snapshot.history } : null));
    if (!ref || !nativeMemberIds.has(ref.id))
      throw new Error(`member is not owned by this task: ${request.id}`);
    const requireActive = request.method === 'send_member';
    await memberTaskFor(request.session, ref.id, { requireActive });
    if (ref.session) trackMemberTools(ref.id, ref.session);
    const session = ref.session;
    switch (request.method) {
      case 'member_state':
        if (!session) {
          const retainedSession = memberRetainedSessions.get(ref.id) ?? null;
          const observed = { id: ref.id, registry_status: ref.status,
            streaming: retainedSession?.isStreaming === true ? true : null,
            model: ref.history?.resolvedModel ?? null,
            activity: ref.activity ?? null, session_id: null, session_file: ref.sessionFile,
            output_path: ref.history?.outputPath ?? null,
            active_tools: null, async_jobs: null, session_attached: false,
            retained_session_seen: Boolean(retainedSession), retained_snapshot: retainedRead,
            lifecycle: ref.lifecycle ?? null };
          // No live session and no retained one means the turn error is
          // UNKNOWN, not absent: omit the key so the runtime keeps its last
          // observed fact instead of treating unknown as "no error".
          if (retainedSession) observed.last_turn_error = lastTurnError(retainedSession);
          return observed;
        }
        return { id: ref.id, registry_status: ref.status, streaming: session.isStreaming === true,
          model: session.model ? `${session.model.provider}/${session.model.id}` : (ref.history?.resolvedModel ?? null),
          activity: ref.activity ?? null, session_id: session.sessionId, session_file: ref.sessionFile,
          output_path: ref.history?.outputPath ?? null,
          active_tools: memberActiveTools.has(ref.id) ? memberActiveTools.get(ref.id).size : null,
          async_jobs: session.getAsyncJobSnapshot ? session.getAsyncJobSnapshot() : null,
          session_attached: true, retained_session_seen: memberRetainedSessions.has(ref.id),
          retained_snapshot: retainedRead, lifecycle: ref.lifecycle ?? null,
          last_delivery_error: memberDeliveryErrors.get(ref.id) ?? null,
          last_turn_error: lastTurnError(session) };
      case 'member_result': {
        const outputPath = ref.history?.outputPath ?? null;
        let outputText = null;
        let outputMtime = null;
        let outputSize = null;
        if (outputPath) {
          try {
            const [text, stats] = await Promise.all([
              fs.readFile(outputPath, 'utf8'),
              fs.stat(outputPath),
            ]);
            outputText = text.slice(0, 2000);
            outputMtime = stats.mtime.toISOString();
            outputSize = stats.size;
          } catch { outputText = null; }
        }
        return { id: ref.id, registry_status: ref.status, output_path: outputPath, output_text: outputText,
          output_mtime: outputMtime, output_size: outputSize };
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
              await flushNativeCalls(memberTasks.get(ref.id));
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
            await flushNativeCalls(memberTasks.get(ref.id));
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
    { route: 'subscription_quota', provider: 'kimi-code', host: 'api.kimi.com', pathPrefix: '/coding/' },
    // OpenCode Go subscription: first-party console docs pin the Go endpoint at
    // https://opencode.ai/zen/go/v1/ (verified 2026-09-30) and the pinned
    // pi-catalog 18.3.4 carries the same default. Matched only against the
    // actually resolved base URL; account scope, prices and the real
    // deduction bucket stay unknown.
    { route: 'subscription_quota', provider: 'opencode-go', host: 'opencode.ai', pathPrefix: '/zen/go/' }
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
        const agents = {};
        for (const [name, model] of sessionAgents) agents[model] = name;
        const families = {}, routes = {}, limits = {};
        let taskModel;
        for (const m of available) {
          const key = `${m.provider}/${m.id}`;
          try { families[key] = currentContext.models.family?.(m) ?? null; } catch { families[key] = null; }
          let resolved;
          try { resolved = currentContext.models.resolve?.(key); } catch { /* no exact resolution */ }
          if (`${resolved?.provider}/${resolved?.id}` !== key) {
            if (taskModel === undefined) {
              try { taskModel = currentContext.models.resolve?.('@task') ?? null; } catch { taskModel = null; }
            }
            resolved = `${taskModel?.provider}/${taskModel?.id}` === key ? taskModel : null;
          }
          routes[key] = billingRoute(resolved);
          if (resolved) {
            // These are the exact OMP registry's configured execution limits,
            // not OpenRouter's potentially larger model-level description.
            // Never serialize endpoints, credentials or catalog price fields.
            limits[key] = {
              source: 'omp_model_registry',
              context_window: Number.isSafeInteger(resolved.contextWindow) && resolved.contextWindow > 0
                ? resolved.contextWindow : null,
              input_modalities: Array.isArray(resolved.input)
                ? resolved.input.filter(value => value === 'text' || value === 'image') : [],
              output_modalities: !resolved.kind || resolved.kind === 'chat' ? ['text'] : [],
              // SDK 18.3.4: false is the sole unsupported signal; an omitted
              // supportsTools permits native tools (pi-catalog/types.ts).
              supports_tools: resolved.supportsTools !== false
            };
          }
        }
        const current = currentContext.models.current?.() ?? null;
        return { current: current ? `${current.provider}/${current.id}` : null,
                 available: available.map(m => `${m.provider}/${m.id}`), families, agents, routes, limits,
                 agent_dir: typeof sdk.getAgentDir === 'function' ? sdk.getAgentDir() : null };
      }
      case 'send': {
        // Ordinary sends behave exactly as before. An integration_check tag is
        // a narrow program-purpose marker from remind_manual_final_check only;
        // the tag alone grants nothing — the tagged branch re-verifies every
        // durable fact and performs any eligible public pi.setModel selection
        // BEFORE the same custom-message wake, so the woken turn (which the
        // SDK never routes through before_agent_start) still lands on the
        // selected model. Selection failure never blocks the reminder.
        let text = request.text;
        if (Number.isInteger(request.integration_check) && request.integration_check > 0) {
          try {
            const outcome = await considerProgramIntegrationSwitch(entry, currentContext,
              await resolveBoundTask(entry.id, currentContext?.cwd), entry.id,
              { taggedCheck: request.integration_check });
            // The program-source guidance rides the SAME reminder message —
            // only when a selection actually succeeded for the current target.
            if (outcome && typeof outcome.guidance === 'string') text = `${request.text}\n\n${outcome.guidance}`;
          } catch { /* classified trace only; the reminder below still goes out */ }
        }
        return send(entry, text);
      }
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
    stopStatusWatch();
    await flushNativeCalls();
    if (host) { await host.close({ requireConfirmation }); host = undefined; }
    for (const entry of entries.values()) entry.unsubscribe();
    entries.clear();
    prestartSeen.clear();
    entryRecovery.clear();
    // Pure in-memory selection state follows the same entry lifecycle: a
    // branch/resume creates a fresh entry for the same sessionId, and a stale
    // own-switch count would swallow same-ID native /model durable entries.
    // Persistent ledgers and agent roots are NOT touched (see note below).
    rootPhaseByTask.clear();
    rootIntegrationAttempts.clear();
    modelChangeBaseline.clear();
    ownModelSwitches.clear();
    externalModelChange.clear();
    rootToolSelectedByTask.clear();
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
    const bound = await boundTask(sessionId);
    if (!bound.ok) {
      if (bound.reason.includes('unreadable'))
        return { block: true, reason: bound.reason };
      if (entryRecovery.get(sessionId)?.explicit)
        return { block: true, reason: 'The explicitly requested Orbit task has not started; native delegation cannot replace controlled execution' };
      const existing = await resolveBoundTask(sessionId, ctx.cwd);
      if (existing && activeState(existing.state))
        return { block: true, reason: 'An active Orbit task is not owned by this Root connection; finish or clean it up before delegating' };
      const nativeItems = Array.isArray(input.tasks) && input.tasks.length ? input.tasks : [input];
      if (nativeItems.some(item => typeof item?.agent === 'string' && item.agent.startsWith(AGENT_NAME_PREFIX)))
        return { block: true, reason: 'Orbit-generated candidate agents require an active Orbit task; use a native OMP agent for unsupervised delegation' };
      if (!uncontrolledDispatchNotified.has(sessionId)) {
        uncontrolledDispatchNotified.add(sessionId);
        try { ctx.ui?.notify('原生 OMP task 未绑定 Orbit：不登记成员、不做独立检查，也不由 Orbit 确认停止。', 'warning'); }
        catch { process.stderr.write('Native OMP task is not supervised by Orbit.\n'); }
      }
      return; // Native OMP retains its own one-level team and permissions.
    }
    if (!subscribeRegistryGate())
      return { block: true, reason: 'Orbit member registration gate is unavailable in this OMP session; refusing task dispatch' };
    const taskDir = bound.taskDir;
    const items = Array.isArray(input.tasks) && input.tasks.length ? input.tasks : [input];
    // A controlled dispatch must observe the current pool, even for the
    // generic @task role. Otherwise OMP's default role silently wins over a
    // nonempty pool and a pending Jev evidence request.
    const sync = await syncSessionAgents(ctx);
    if (!sync.ok)
      return { block: true, reason: `candidate pool is unavailable (${sync.reason}); refusing controlled member dispatch` };
    // Decision-relevant dispatch evidence: the ORIGINAL item input as issued
    // by the model (captured before `item.name` is rewritten to the
    // Orbit-assigned requested name), the explicitly supplied model and an
    // explicit rationale field only — never an inferred motivation. Entries are
    // recorded only when the WHOLE call passes the gate and actually
    // dispatches; a blocked call is not a dispatch.
    const dispatches = [];
    const staged = [];
    const unitReport = runWorkUnit(taskDir, 'list');
    if (!unitReport.ok) return { block: true, reason: `Orbit work units are unreadable: ${unitReport.reason}` };
    const units = Array.isArray(unitReport.units) ? unitReport.units : [];
    const selectedUnits = new Set();
    if (typeof event.toolCallId !== 'string' || !event.toolCallId)
      return { block: true, reason: 'Controlled task needs an actual native tool call id' };
    for (const item of items) {
      if (!item || typeof item !== 'object') return { block: true, reason: 'Invalid controlled task item' };
      // Unpinned custom agents may carry frontmatter/overrides that cannot be
      // resolved before dispatch. Use a generated candidate or the verified
      // @task role instead; the registration gate still catches later drift.
      const itemAgent = typeof item.agent === 'string' ? item.agent.trim() : '';
      let expectedModel;
      if (itemAgent.startsWith(AGENT_NAME_PREFIX)) {
        expectedModel = sessionAgents.get(itemAgent);
        if (!expectedModel)
          return { block: true, reason: `${itemAgent} is not a live session candidate agent (pool changed?); re-run /orbit-models and dispatch again` };
      } else if (!itemAgent || itemAgent === 'task') {
        // A pool-backed generic role is safe, but an out-of-pool default
        // must not bypass the user's controlled-task member preference.
        // Non-Orbit OMP sessions keep native @task behavior.
        try {
          const resolved = ctx.models?.resolve?.('@task');
          if (!resolved?.provider || !resolved?.id) throw new Error('unresolved @task');
          expectedModel = `${resolved.provider}/${resolved.id}`;
          if (sync.agents.length && !sync.agents.some(candidate => candidate.model === expectedModel)) {
            const choices = sync.agents.map(candidate => `${candidate.name} (${candidate.model})`).join(', ');
            const request = bound.state.evidence_request;
            const evidenceAction = request?.identities?.candidates?.length &&
              !['used', 'unavailable', 'deferred', 'stale'].includes(request.resolved)
              ? ` Jev is awaiting exact candidate facts: submit sourced evidence with orbit model-evidence ${taskDir} --file -, or continue with an available pool agent without claiming a Jev recommendation.`
              : '';
            return { block: true, reason: `OMP @task resolves to ${expectedModel}, outside the available Orbit candidate pool; use a generated pool agent: ${choices}.${evidenceAction}` };
          }
        } catch {
          return { block: true, reason: 'Native @task model cannot be resolved before dispatch; choose a live Orbit candidate agent' };
        }
      } else {
        return { block: true, reason: `Native agent ${itemAgent} has no verifiable pre-dispatch model; use a live Orbit candidate or @task` };
      }
      const unitId = dispatchUnitId(item, input.context);
      const unit = units.find(candidate => candidate.id === unitId);
      if (!unit) return { block: true, reason: 'Declare an Orbit work-unit, then put a standalone orbit-unit: wu-... line in each native task text' };
      if (selectedUnits.has(unitId)) return { block: true, reason: `Work unit ${unitId} cannot be dispatched twice in one call` };
      if (!['declared', 'rejected', 'failed'].includes(unit.status) ||
          unit.input_digest !== unitReport.task_input_digest || unit.artifact_root !== unitReport.artifact_root)
        return { block: true, reason: `Work unit ${unitId} is already bound/accepted or has stale requirements/workspace; declare or finish the correct unit` };
      if (!Array.isArray(unit.dependencies) || unit.dependencies.some(id => !units.some(dep => dep.id === id && dep.status === 'accepted')))
        return { block: true, reason: `Work unit ${unitId} has unaccepted dependencies` };
      // Native isolated worktrees change the actual artifact root without an
      // Orbit rebind. Use the declared workspace; isolation is not a sandbox.
      if (input.isolated === true || item.isolated === true)
        return { block: true, reason: 'An Orbit unit must run in its declared artifact_root; native isolated worktrees require an explicit workspace rebind' };
      // The Root session's own cwd is not the member's workspace and is never
      // compared to it: after a workspace rebind it legitimately differs. The
      // child session cwd is set and verified at the registration/bind window
      // (applyMemberWorkspace); here the declared workspace only needs to be
      // a real directory.
      const artifactRoot = await fs.realpath(unit.artifact_root).catch(() => null);
      if (!artifactRoot)
        return { block: true, reason: `Work unit ${unitId} artifact_root is not a real workspace; rebind the workspace or declare a valid unit before dispatch` };
      selectedUnits.add(unitId);
      const hint = bound.state.delegation_hint;
      const models = hint?.recommendation
        ? [hint.recommendation.first, ...(hint.recommendation.backups || [])].filter(Boolean).map(candidate => candidate.model) : [];
      // The hint binds only when its version and the persisted selection record
      // for THIS unit are the same generation: both must be non-empty versions
      // that agree. An old-generation hint must never pair with a newer
      // selection record, and two absences (undefined == undefined) never pass.
      const selection = bound.state.member_selections?.[unitId];
      const hintVersion = typeof hint?.version === 'string' && hint.version.trim() ? hint.version : null;
      const selectionVersion = typeof selection?.version === 'string' && selection.version.trim() ? selection.version : null;
      const matchedHint = hintVersion !== null && hintVersion === selectionVersion && !hint.followed && !hint.invalid_reason &&
        hint.work_unit_id === unitId && hint.input_digest === unit.input_digest && hint.artifact_root === unit.artifact_root &&
        hint.dispatch_attempt === unit.dispatches.length + 1 && hint.user_boundary === bound.state.last_user_message_id &&
        typeof hint.signature === 'string' && typeof hint.message_id === 'string' &&
        selection.signature === hint.signature && models.includes(expectedModel);
      const hintBinding = matchedHint ? { hint_signature: hint.signature, hint_message_id: hint.message_id } : null;
      const requested = `orbit-${randomUUID()}`;
      const rationale = explicitDispatchRationale(item);
      dispatches.push({ kind: 'task_dispatch', at: Date.now(), session_id: sessionId, agent_id: caller,
        tool_call_id: event.toolCallId ?? null,
        input_name: typeof item.name === 'string' && item.name.trim() ? item.name : null,
        agent: itemAgent || null,
        model: typeof item.model === 'string' && item.model.trim() ? item.model : null,
        pinned_model: expectedModel,
        effort: typeof item.effort === 'string' && item.effort.trim() ? item.effort : null,
        task: typeof item.task === 'string' ? item.task : null,
        context: typeof input.context === 'string' ? input.context : null,
        rationale,
        rationale_source: rationale ? 'dispatch_input' : 'unrecorded',
        requested_name: requested, work_unit_id: unitId,
        hint_signature: hintBinding?.hint_signature ?? null, hint_message_id: hintBinding?.hint_message_id ?? null });
      staged.push({ item, requested, expectedModel, unit, hint: hintBinding });
    }
    // Stage the whole batch first: rejection cannot leave partial requested
    // names or rewritten items that a later unrelated registration could use.
    for (const { item, requested, expectedModel, unit, hint } of staged) {
      item.name = requested;
      // Native task.tools mounts named eval tools; it is NOT a restriction
      // list. Scope is enforced at the child tool entrance, not through it.
      item.task = `${item.task}\n\n[Orbit durable work unit]\n${JSON.stringify(unit)}\nReport results to Root through hub; Root verifies and records finish. This record is context, not permission to expand the original request.`;
      requestedNames.set(requested, { taskDir, toolCallId: event.toolCallId, expectedModel, unitId: unit.id, hint });
    }
    for (const dispatch of dispatches) observeCollab(dispatch);

    return { input };
  });
  // An explicit rationale is recorded only when the model supplied one as
  // part of the dispatch input; Orbit never infers or attributes motivation
  // (e.g. never turns a Jev delegation hint into the Root's reason).
  function explicitDispatchRationale(item) {
    for (const field of ['rationale', 'why', 'reason']) {
      const value = item?.[field];
      if (typeof value === 'string' && value.trim()) return value;
    }
    return null;
  }
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

  // Rendered context-file entries inside the SDK system prompt parts. The
  // entry format `<file path="...">...</file>` is stable across the bundled
  // prompt variants (verified against installed OMP 18.3.4: both the
  // <project-context> and <repo-rules> wrappers use it); the wrapper itself
  // varies by model and is deliberately left untouched.
  const CONTEXT_FILE_ENTRY = /<file path="[^"]*">\n[\s\S]*?\n<\/file>/g;
  // A rebound member must not keep the spawn-time project instructions: the
  // session's real cwd is already the unit artifact_root, but AGENTS context
  // files are discovered only at session creation. The public
  // before_agent_start hook (systemPrompt replace policy, chained in order)
  // fires before the member's first request and every later preparation, so
  // the context-file entries are rebuilt there from the SDK's own public
  // discovery (discoverContextFiles) rooted at the current artifact_root.
  // Only the file-entry set changes: user requirements, the member's task
  // prompt, wrappers and every other part stay as they are — this context is
  // instruction text, never a new authorization. A discovery failure is
  // recorded durably and aborts preparation instead of running stale rules.
  // One durable line per distinct gap per member: this hook fires at every
  // prompt preparation, so repeat failures must not flood the evidence file.
  const memberContextGaps = new Set();
  // Members whose project context could not be rebuilt for the current round.
  // A blocked member never runs a round on stale spawn-time instructions:
  // prompt preparation is aborted, the provider gate aborts and the member
  // tool gate stays closed until a later preparation succeeds — no first
  // round on old context with a second-round repair.
  const memberContextBlocked = new Set();
  const noteContextGap = (agentId, binding, reason) => {
    const key = `${agentId}:${reason}`;
    if (memberContextGaps.has(key)) return;
    memberContextGaps.add(key);
    observeCollab({ kind: 'work_unit_context_failed', task_dir: binding?.taskDir ?? null,
      agent_id: agentId, work_unit_id: binding?.unitId ?? null,
      reason: String(reason).slice(0, 300), at: Date.now() });
  };
  pi.on('before_agent_start', async (event, ctx) => {
    let sessionId = null;
    try { sessionId = ctx.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!sessionId) return;
    const agentId = agentIdFor(sessionId);
    if (!agentId || !nativeMemberIds.has(agentId)) return;
    const refuse = reason => {
      memberContextBlocked.add(agentId);
      noteContextGap(agentId, memberWorkUnits.get(agentId), reason);
      signalAbort(agentId);
      try { ctx.abort?.(); } catch { /* abort is advisory; the gates stay closed */ }
      // before_agent_start has no block result in the public SDK. abort()
      // invalidates promptGeneration synchronously; AgentSession checks it
      // after this hook and discards preparation before any model request.
      // Keep the independent provider/tool barriers for later continuations.
      return undefined;
    };
    // A registration without a session does not mean there is no session at
    // prompt time: attachSession emits no event, but the executor attaches
    // before session.prompt. Use the actually attached session NOW to bind
    // the real workspace before judging the context.
    let binding = memberWorkUnits.get(agentId);
    if (!binding?.workspaceRoot) {
      let attached = null;
      try { attached = sdk.AgentRegistry.global().get(agentId)?.session ?? null; } catch { attached = null; }
      if (attached) {
        const workspace = applyMemberWorkspace(agentId, attached);
        if (!workspace.ok) return refuse(workspace.reason);
        binding = memberWorkUnits.get(agentId);
      }
    }
    if (typeof sdk.discoverContextFiles !== 'function')
      return refuse('discoverContextFiles unavailable on the injected sdk');
    if (!Array.isArray(event.systemPrompt))
      return refuse('non-array systemPrompt: context entries not locatable');
    const root = binding?.workspaceRoot;
    if (!root) return refuse('workspace_root_not_bound_before_prompt');
    let files;
    try { files = await sdk.discoverContextFiles(root); } catch (error) {
      return refuse(error?.message || error);
    }
    if (!Array.isArray(files))
      return refuse('discoverContextFiles returned a non-array result');
    const entries = files.map(file =>
      `<file path="${file.path}">\n${typeof file.content === 'string' ? file.content : ''}\n</file>`).join('\n');
    let found = false;
    const replaced = event.systemPrompt.map(part => {
      if (typeof part !== 'string' || !part.includes('<file path="')) return part;
      let inserted = false;
      return part.replace(CONTEXT_FILE_ENTRY, () => {
        if (inserted) return '';
        inserted = true;
        found = true;
        return entries;
      });
    });
    // A prompt variant without a rendered context region carries no stale
    // project instructions to remove; the real workspace instructions are
    // still appended as their own clearly-marked part so they take effect.
    if (!found && entries) replaced.push(`Project instructions discovered from the current workspace:\n${entries}`);
    // This round carries the real workspace context (or provably needs none):
    // the member is applicable again.
    memberContextBlocked.delete(agentId);
    if (!found && !entries) return;
    return { systemPrompt: replaced };
  });
  pi.on('before_provider_request', async (event, ctx) => {
    let sessionId = null;
    try { sessionId = ctx.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!sessionId) return event.payload;
    const agentId = agentIdFor(sessionId);
    if (!agentId || !nativeMemberIds.has(agentId)) return event.payload;
    // A member whose project context could not be rebuilt never starts a
    // round on stale spawn-time instructions: abort and keep the gates
    // closed until a before_agent_start preparation succeeds.
    if (memberContextBlocked.has(agentId)) {
      signalAbort(agentId);
      try { ctx.abort?.(); } catch { /* abort is advisory; the member tool gate stays closed */ }
      return event.payload;
    }
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
      captureMemberSnapshot(agentId, ref);
    } catch { /* observation only; never block the request path */ }
    // Late-attach workspace window: when the registration event saw no live
    // session, the real runtime cwd is applied here instead — still before the
    // member's first provider request. A member whose cwd cannot reach the
    // current unit artifact_root is aborted and stays unbound; it must not
    // reach a provider under an unknown workspace.
    let workspaceSession = null;
    try { workspaceSession = sdk.AgentRegistry.global().get(agentId)?.session ?? null; } catch { workspaceSession = null; }
    if (workspaceSession) {
      const workspace = applyMemberWorkspace(agentId, workspaceSession);
      if (!workspace.ok) {
        signalAbort(agentId);
        try { ctx.abort?.(); } catch { /* the member tool gate remains closed */ }
        observeCollab({ kind: 'work_unit_binding_failed', task_dir: memberTasks.get(agentId), agent_id: agentId,
          work_unit_id: memberWorkUnits.get(agentId)?.unitId ?? null, reason: workspace.reason, at: Date.now() });
        return event.payload;
      }
    }
    // Provider-request identity observation (before the pinned-model early
    // return, so unpinned members are covered too): the ACTUAL resolved
    // model at dispatch time, provider/id only. Deduplicated per identity
    // change; never blocks the request path.
    try {
      const requestModel = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : null;
      noteModelIdentity({ taskDir: memberTasks.get(agentId), role: 'member', agentId, sessionId,
        model: requestModel, requestedModel: memberExpectedModels.get(agentId) ?? null });
    } catch { /* observation only */ }
    const expected = memberExpectedModels.get(agentId);
    if (!expected) return event.payload;
    const model = ctx.model;
    const actual = model ? `${model.provider}/${model.id}` : null;
    if (actual === expected) {
      const binding = bindMemberWorkUnit(agentId, actual);
      if (!binding.ok) {
        signalAbort(agentId);
        try { ctx.abort?.(); } catch { /* member tool gate remains closed */ }
        process.stderr.write(`Orbit: refusing unbound member ${agentId}: ${binding.reason}\n`);
      }
      return event.payload;
    }
    if (!actual) {
      signalAbort(agentId);
      try { ctx.abort?.(); } catch { /* no actual identity, no tools */ }
      return event.payload;
    }
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
  // session id -> { key, instruction } for failed EXPLICIT entries awaiting
  // Root's recovery. Non-explicit failures get one current-request warning
  // and then proceed without Orbit supervision.
  const entryRecovery = new Map();
  pi.on('before_provider_request', async (event, ctx) => {
    let sessionId = null;
    try { sessionId = ctx.sessionManager?.getSessionId?.() ?? null; } catch { /* unowned */ }
    if (!sessionId || !isMainSession(sessionId)) return event.payload;
    // Root model identity for an ALREADY-BOUND task, observed at provider
    // request (provider/id only, deduplicated per identity change). A cheap
    // map lookup for unbound sessions; the binding created later in this
    // handler or by the orbit tool records its own identity note.
    try {
      const boundDir = taskDirs.get(sessionId);
      if (boundDir && ctx.model)
        noteModelIdentity({ taskDir: boundDir, role: 'root', agentId: sdk.MAIN_AGENT_ID, sessionId,
          model: `${ctx.model.provider}/${ctx.model.id}` });
    } catch { /* observation only */ }
    const branch = ctx.sessionManager.getBranch();
    const pending = entryRecovery.get(sessionId);
    if (pending) {
      // Tool turns add assistant messages after the native user message.
      // Keep the recovery attached across those requests without treating an
      // unrelated assistant-only turn as a fresh user entry.
      let latestUserId = null;
      for (let index = branch.length - 1; index >= 0; index--) {
        const item = branch[index];
        if (item.type === 'message' && item.message?.role === 'user' && item.message.attribution !== 'agent') {
          latestUserId = item.id;
          break;
        }
      }
      if (pending.key === `${sessionId}:${latestUserId}`) {
        const bound = await resolveBoundTask(sessionId, ctx.cwd);
        if (bound && activeState(bound.state)) {
          entryRecovery.delete(sessionId);
          // This is also an owned+active reachable request: the cooperation
          // policy applies here too, not only on the general bound path.
          let recovered = event.payload;
          try {
            const policy = await applyCooperationPolicy(recovered, sessionId, ctx, bound);
            if (policy) recovered = policy.payload;
          } catch { /* policy is optional; the recovery path stays intact */ }
          return recovered;
        }
        const injected = appendInstructionToPayload(event.payload, pending.instruction);
        if (injected) return injected;
        pi.sendMessage({ customType: 'orbit-entry', content: pending.instruction, attribution: 'agent' },
          { deliverAs: 'aside' });
        try { ctx.abort?.(); } catch { /* the host may already be stopping */ }
        return event.payload;
      }
      entryRecovery.delete(sessionId);
    }
    // A manual tool start in the same turn can leave requests whose branch has
    // no fresh native user message; before the user scan concludes there is
    // nothing to do, an already-bound active task gets its one advisory
    // window. Injection failure stays pending (no sent mark) for the next
    // reachable request.
    try {
      const boundNow = await resolveBoundTask(sessionId, ctx.cwd);
      if (boundNow && activeState(boundNow.state)) {
        let payload = event.payload;
        const policy = await applyCooperationPolicy(payload, sessionId, ctx, boundNow);
        if (policy) payload = policy.payload;
        const guidance = injectEntryGuidance(payload, boundNow.state, boundNow.taskDir);
        if (guidance) {
          if (guidance.bootstrap) recordCollabFor(boundNow.taskDir, bootstrapFacts(boundNow.taskDir, boundNow.state, ctx,
            'bootstrap_guidance', { via: 'provider_payload' }));
          return guidance.payload;
        }
        if (payload !== event.payload) return payload;
      }
    } catch { /* guidance only; never block the request path */ }
    let user = null;
    let userIndex = -1;
    for (let index = branch.length - 1; index >= 0; index--) {
      const item = branch[index];
      if (item.type !== 'message') continue;
      if (item.message?.role === 'assistant') break;
      if (item.message?.role === 'user' && item.message.attribution !== 'agent') {
        user = item;
        userIndex = index;
        break;
      }
    }
    if (!user?.id || !textOf(user.message.content).trim()) return event.payload;
    const key = `${sessionId}:${user.id}`;
    if (prestartSeen.has(key)) return event.payload;
    prestartSeen.add(key);
    let decision = null;
    try {
      const bound = await resolveBoundTask(sessionId, ctx.cwd);
      if (bound && activeState(bound.state)) return event.payload;
      await connect(ctx);
      decision = await host.entry(user.id, ctx);
      if (decision.decision === 'start') {
        const startArgs = { action: 'start', message_id: user.id, entry_file: decision.entry_file };
        if (userIndex >= 0 && hasPriorToolCall(branch, userIndex)) {
          // The requirement's session already contains program-visible tool
          // execution from before this message. Save a real boundary for the
          // CURRENT task; prior_scope stays unknown and the earlier work is
          // never recognized as controlled. A previous controlled task in the
          // same session keeps its own record untouched.
          startArgs.takeover = {
            reason: '会话已有此前工具执行；关联范围未知，不追认为本任务已受控，历史任务按原记录解释',
          };
        }
        const started = JSON.parse(await host.execute(startArgs, ctx));
        taskDirs.set(sessionId, started.task_directory);
        noteAssociation(sessionId, started.task_directory);
        noteModelIdentity({ taskDir: started.task_directory, role: 'root', agentId: sdk.MAIN_AGENT_ID, sessionId,
          model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : null });
        await refreshStatus(ctx, sessionId);
        // start already selected a runnable checker. Missing candidate facts
        // remain in the response for deliberate lookup; injecting them into
        // the user's first turn made Root research unused models
        // before implementing the authorized task.
        // The entry advisory is different: it is the already-paid entry fact
        // for THIS task, and this request is the first reachable window. A
        // payload the injector cannot extend stays pending for the fallback
        // (before_agent_start on the next turn) instead of aborting anything.
        try {
          const state = JSON.parse(await fs.readFile(path.join(started.task_directory, 'state.json'), 'utf8'));
          let payload = event.payload;
          // The task was just created by THIS process, so ownership is real by
          // construction; the runtime-liveness check still applies.
          const policy = await applyCooperationPolicy(payload, sessionId, ctx,
            { taskDir: started.task_directory, state }, { owned: true });
          if (policy) payload = policy.payload;
          const guidance = injectEntryGuidance(payload, state, started.task_directory);
          if (guidance) {
            if (guidance.bootstrap) recordCollabFor(started.task_directory, bootstrapFacts(started.task_directory, state, ctx,
              'bootstrap_guidance', { via: 'provider_payload' }));
            return guidance.payload;
          }
          if (payload !== event.payload) return payload;
        } catch { /* guidance is optional; never block the start path */ }
      } else if (decision.decision === 'root_decides' && decision.prompt) {
        pi.sendMessage({ customType: 'orbit-entry', content: decision.prompt, attribution: 'agent' },
          { deliverAs: 'aside' });
      }
    } catch (error) {
      const reason = String(error?.message || error);
      const explicit = decision?.classification !== 'uncertain';
      const instruction = entryRecoveryInstruction(reason, user.id, explicit);
      if (explicit) entryRecovery.set(sessionId, { key, instruction, explicit });
      const injected = appendInstructionToPayload(event.payload, instruction);
      if (injected) {
        // PROVEN current-request delivery (see appendInstructionToPayload):
        // this hook's return value replaces the request body this turn's
        // model answers, so Root reads the failure, its reason and the
        // recovery steps now. Aborting here would cancel the very request
        // carrying the instruction — the old trap — and the queued aside
        // would only re-deliver it after the turn; both are skipped.
        try { ctx.ui?.notify(`Orbit 入口启动失败，未创建任务（${reason.slice(0, 200)}）；${decision?.classification === 'uncertain' ? '本次不受 Orbit 监督，可普通执行' : '显式受控请求仍需恢复'}。`, decision?.classification === 'uncertain' ? 'warning' : 'error'); }
        catch { process.stderr.write(`${instruction}\n`); }
        return injected;
      }
      // Unrecognized request shape: cannot prove the instruction reaches the
      // current model request, so the fail-closed trap stays. A specifically
      // requested controlled run must not silently continue as ordinary work
      // after its start preflight failed.
      try { ctx.ui?.notify(instruction, 'error'); } catch { process.stderr.write(`${instruction}\n`); }
      pi.sendMessage({ customType: 'orbit-entry', content: instruction, attribution: 'agent' },
        { deliverAs: 'aside' });
      try { ctx.abort?.(); } catch { /* the host may already be stopping */ }
    }
    return event.payload;
  });

  // Child extension factories share the actual unit map. Every native tool
  // passes this entrance: the handoff declaration is never treated as a
  // permission until its real member/call/model binding has succeeded.
  // One factual line before Root's first explicit artifact edit: was a work
  // unit already declared for this task? Only the real artifact tools count —
  // shell commands are never read as artifact edits — and the record states
  // only what was observed (declared / none / unknown) with the real
  // tool_call_id. No delegation refusal is inferred from it.
  const unitPreEditNoted = new Set();
  pi.on('tool_call', async (event, ctx) => {
    if (!['write', 'edit', 'ast_edit'].includes(event?.toolName)) return;
    let sessionId = null;
    try { sessionId = ctx?.sessionManager?.getSessionId?.() ?? null; } catch { return; }
    if (!sessionId || !isMainSession(sessionId)) return;
    if (memberTasks.has(agentIdFor(sessionId))) return;
    let bound = null;
    try { bound = await resolveBoundTask(sessionId, ctx?.cwd); } catch { bound = null; }
    if (!bound || !activeState(bound.state) || unitPreEditNoted.has(bound.taskDir)) return;
    unitPreEditNoted.add(bound.taskDir);
    recordCollabFor(bound.taskDir, bootstrapFacts(bound.taskDir, bound.state, ctx, 'unit_state_before_edit', {
      tool: event.toolName,
      tool_call_id: typeof event.toolCallId === 'string' ? event.toolCallId : null,
    }));
  });

  pi.on('tool_call', async (event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const agentId = agentIdFor(sessionId);
    if (!nativeMemberIds.has(agentId)) return;
    const binding = memberWorkUnits.get(agentId);
    if (!binding?.bound) return { block: true, reason: 'Orbit member has no actual bound work unit; stop; Root must reconcile the host binding-failure record' };
    if (memberContextBlocked.has(agentId))
      return { block: true, reason: 'Orbit member project context is not rebuilt for the current round; stop; Root must reconcile or redispatch' };
    const report = runWorkUnit(binding.taskDir, 'read', { id: binding.unitId });
    const unit = report.unit;
    let state;
    try { state = JSON.parse(await fs.readFile(path.join(binding.taskDir, 'state.json'), 'utf8')); }
    catch { return { block: true, reason: 'Orbit member task state is unreadable' }; }
    if (!ACTIVE.has(state.status) || !report.ok || !unit || unit.status !== 'bound' ||
        unit.member_id !== agentId || unit.tool_call_id !== binding.toolCallId ||
        unit.input_digest !== report.task_input_digest || unit.artifact_root !== report.artifact_root ||
        unit.model !== memberExpectedModels.get(agentId) || memberDriftReported.has(agentId))
      return { block: true, reason: 'Orbit work unit is finished, stale, drifted or belongs to another actual member; stop and let Root reconcile the result' };
    const result = await validateMemberTool(unit, { toolName: event.toolName, input: event.input,
      cwd: ctx.cwd, rootAgentId: sdk.MAIN_AGENT_ID,
      // The projector comes from the host's own SDK with this session's actual
      // model, so the scope gate sees exactly the targets the member's native
      // edit tool would write (every dialect, incl. move/rename destinations).
      editTargets: event.toolName === 'edit' ? createEditProjection(sdk, ctx.model) : undefined });
    if (result?.block) observeCollab({ kind: 'work_unit_tool_blocked', task_dir: binding.taskDir,
      session_id: sessionId, agent_id: agentId, work_unit_id: unit.id,
      tool_call_id: event.toolCallId, tool: event.toolName, reason: result.reason, at: Date.now() });
    return result;
  });

  // Native peer messages use either `hub` or `write agent://<peer>`.
  // Both routes record their wire intent and result and respect member stop.
  pi.on('tool_call', async (event, ctx) => {
    const peerWrite = event.toolName === 'write' && typeof event.input?.path === 'string'
      && event.input.path.startsWith('agent://');
    if (event.toolName !== 'hub' && !peerWrite) return;
    const sessionId = ctx.sessionManager.getSessionId();
    // Member sessions are observed through trackMemberTools; the global hook
    // also fires for them, but must not duplicate their durable hub events.
    if (memberTasks.has(agentIdFor(sessionId))) return;
    const input = event.input || {};
    const op = peerWrite ? 'send' : input.op;
    const to = peerWrite ? input.path.slice('agent://'.length) : input.to;
    observeCollab({ kind: 'hub_call', at: Date.now(), session_id: sessionId,
      agent_id: agentIdFor(sessionId), tool_call_id: event.toolCallId ?? null,
      op: op ?? null, to: to ?? null, from: input.from ?? null,
      reply_to: peerWrite ? null : input.replyTo ?? null, await_reply: peerWrite ? false : input.await === true,
      message: typeof (peerWrite ? input.content : input.message) === 'string'
        ? (peerWrite ? input.content : input.message) : null });
    // A stopped member must not be woken by either native peer-send route.
    if (op === 'send' && typeof to === 'string' && memberTasks.has(to)) {
      if (stoppedMembers.has(to))
        return { block: true, reason: `member ${to} was stopped for this Orbit task; refusing to wake it` };
      try {
        const state = JSON.parse(await fs.readFile(path.join(memberTasks.get(to), 'state.json'), 'utf8'));
        if (!ACTIVE.has(state.status))
          return { block: true, reason: `Orbit task is ${state.status}; refusing to wake member ${to}` };
      } catch {
        return { block: true, reason: 'Orbit task state unreadable; refusing to wake a registered member' };
      }
    }
    if (peerWrite) rootAgentWrites.add(event.toolCallId);
  });
  pi.on('tool_result', async (event, ctx) => {
    if (event.toolName !== 'hub' && event.toolName !== 'task' &&
        !(event.toolName === 'write' && rootAgentWrites.has(event.toolCallId))) return;
    if (memberTasks.has(agentIdFor(ctx.sessionManager.getSessionId()))) return;
    if (event.toolName === 'hub' || (event.toolName === 'write' && rootAgentWrites.delete(event.toolCallId))) {
      const text = Array.isArray(event.content)
        ? event.content.filter(p => p.type === 'text').map(p => p.text).join(' ') : null;
      observeCollab({ kind: 'hub_result', at: Date.now(), session_id: ctx.sessionManager.getSessionId(),
        agent_id: agentIdFor(ctx.sessionManager.getSessionId()), tool_call_id: event.toolCallId ?? null,
        ok: event.isError === false, text });
      return;
    }
    if (event.toolName === 'task') {
      const text = Array.isArray(event.content)
        ? event.content.filter(p => p.type === 'text').map(p => p.text).join(' ') : null;
      observeCollab({ kind: 'task_result', at: Date.now(), session_id: ctx.sessionManager.getSessionId(),
        agent_id: agentIdFor(ctx.sessionManager.getSessionId()), tool_call_id: event.toolCallId ?? null,
        ok: event.isError === false, text });
    }
  });

  // Root-stage model selection (action=root-model). Ownership was already
  // verified by the shared host; this closure owns the pool∩catalog check,
  // the public pi.setModel call, and one small factual record per attempt.
  // No credentials, no raw provider payloads, no rollback guessing; the
  // actual identity after the switch is proven by the next native assistant
  // receipt, never by this return value.
  const rootModelInFlight = new Set();
  // The declared Root phase for the NEXT and subsequent provider calls of
  // this task session. Keyed by taskDir (canonical owned path), set only on a
  // confirmed switch, cleared when the session re-binds or the task ends.
  const rootPhaseByTask = new Map();
  // Program-initiated Root integration selection (contract: 程序发起的 Root
  // integration 阶段选择). One attempt per (taskDir,input,artifactRoot,
  // artifactDigest); the value records the classified outcome so a duplicate
  // same-triple tagged send never switches twice.
  const rootIntegrationAttempts = new Map();
  // User/Root selection priority: durable model_change baseline per session
  // (captured at first observation, AFTER the launch entry exists), our own
  // switch count while rootModelInFlight was set, and a live flag from the
  // public session subscribe (model_changed has no extension-facing hook).
  const modelChangeBaseline = new Map();
  const ownModelSwitches = new Map();
  const externalModelChange = new Map();
  // Tasks where the ROOT TOOL path confirmed a model selection: conservative
  // per-task priority over any later program attempt (the program's own
  // switch sets rootPhaseByTask for attribution but never this set).
  const rootToolSelectedByTask = new Set();
  async function handleRootModel(args, entry, ctx, toolCallId) {
    const sessionId = entry.id;
    // Trusted log destination starts null and is set only after ownership is
    // re-verified; an early reject never writes to a caller-supplied path.
    let boundDir = null;
    const record = (extra) => {
      const payload = {
        kind: 'root_model_selection', at: Date.now(), session_id: sessionId,
        agent_id: sdk.MAIN_AGENT_ID,
        task_dir: (extra.canonical_task_dir ?? null),
        tool_call_id: typeof toolCallId === 'string' ? toolCallId : null,
        from: extra.original_from ?? null,
        actual_model_after: extra.actual_model_after ?? undefined,
        to: args.root_model ?? null, phase: args.phase ?? null,
        reason: typeof args.text === 'string' ? args.text.slice(0, 300) : null,
        ...extra,
      };
      try { if (payload.task_dir) recordCollabFor(payload.task_dir, payload); } catch { /* record only */ }
      return payload;
    };
    const reject = (error, extra = {}) => { record({ ok: false, error, canonical_task_dir: boundDir ?? null, ...extra }); return { ok: false, error }; };
    // Bind the real task now: re-resolve, re-verify ownership+activity+runtime
    // so a foreign or stale task_dir is never used as a log destination.
    let bound;
    try { bound = await resolveBoundTask(sessionId, ctx?.cwd); }
    catch { return reject('task binding could not be verified'); }
    // resolveBoundTask is a display-grade lookup (provider/thread match only).
    // A trusted log destination requires REAL ownership: the current process
    // must hold this task's control socket AND the caller's path must resolve
    // to the same canonical directory we would write to.
    let controlOwned = false;
    try { controlOwned = !!bound && await host.ownsTask(bound.taskDir, sessionId) === true; } catch { controlOwned = false; }
    if (!bound || !controlOwned || !args.task || bound.taskDir !== args.task)
      return reject('task is not owned by the current host session');
    boundDir = bound.taskDir; // ONLY after successful ownership and exact task match
    if (!activeState(bound.state)) return reject('task is not active');
    if (runtimeAbandoned(bound.state)) return reject('task runtime is no longer running');
    // Waiting discipline: an in-flight independent check or a queued manual
    // finalization means the Root should yield, not switch mid-verification.
    // Real shapes: state.check_observations[*].status === 'in_flight' and
    // state.pending_finalization (queued manual final), per task_runtime.
    const observations = bound.state.check_observations;
    if (observations && typeof observations === 'object'
        && Object.values(observations).some(o => o && typeof o === 'object' && o.status === 'in_flight'))
      return reject('an independent check is in flight; wait for its notice');
    if (bound.state.pending_finalization || bound.state.completion_stop_pending)
      return reject('a manual final check or completion stop is queued; wait for its notice');
    if (bound.state.next_check_manual === true)
      return reject('the task is waiting on its manual final check window; wait for its notice');
    // The catalog resolves only through the CURRENT pool∩session intersection;
    // no guessed targets, no cached lists. The listing branch stays here (it
    // is tool-only); the shared switch core below is reused verbatim by the
    // program-initiated integration selection.
    const sync = await syncSessionAgents(ctx);
    if (!sync.ok) return reject(`model catalog is stale: pool re-sync failed (${sync.reason})`);
    const exact = [...new Set(sessionAgents.values())];
    if (!args.root_model || !args.root_model.trim())
      return { ok: true, listing_only: true, available: exact, note: 'pass root_model with one of these exact provider/id values plus phase and text' };
    const target = args.root_model.trim();
    if (!args.phase) return reject('phase is required (execution | integration | diagnosis)');
    if (typeof args.text !== 'string' || !args.text.trim())
      return reject('text (a non-empty selection reason) is required');
    return performRootModelSwitch({ entry, ctx, boundDir, target, phase: args.phase, reason: args.text,
      origin: 'tool', toolCallId });
  }

  // Shared switch core used by BOTH the Root `root-model` tool action and the
  // program-initiated integration selection: same public pi.setModel chain,
  // same pool∩catalog + exact resolve + in-flight latch + API check, same
  // record shape. `origin` selects the record kind ('tool' keeps
  // root_model_selection with the real tool_call_id; 'program' uses the
  // separate kind with tool_call_id=null and never fakes a Root tool call).
  async function performRootModelSwitch({ entry, ctx, boundDir, target, phase, reason, origin, toolCallId = null, provenance = {} }) {
    const sessionId = entry.id;
    const recordSwitch = (extra) => {
      const payload = {
        kind: origin === 'program' ? 'root_integration_model_selected' : 'root_model_selection',
        at: Date.now(), session_id: sessionId, agent_id: sdk.MAIN_AGENT_ID,
        origin, tool_call_id: origin === 'program' ? null : (typeof toolCallId === 'string' ? toolCallId : null),
        task_dir: boundDir, to: target, phase: phase ?? null,
        reason: typeof reason === 'string' ? reason.slice(0, 300) : null,
        ...provenance, ...extra,
      };
      try { recordCollabFor(boundDir, payload); } catch { /* record only */ }
      return payload;
    };
    // Every classified refusal from the shared core leaves the same bounded,
    // owned-log evidence the tool path always produced — never a silent skip.
    const rejectSwitch = (error, extra = {}) => {
      recordSwitch({ ok: false, error, ...extra });
      return { ok: false, error, ...extra };
    };
    // The intersection is the synced session-agent set (pool ∩ session
    // catalog), NOT ctx.models.list() (which is the full session catalog and
    // would allow out-of-pool targets). Same set for listing and selection.
    const exact = [...new Set(sessionAgents.values())];
    if (!target || !exact.includes(target))
      return rejectSwitch(`target ${target} is not in the current pool ∩ OMP catalog`, { available: exact });
    if (rootModelInFlight.has(sessionId)) return rejectSwitch('another root-model selection is already in progress for this session');
    // API availability first: a missing surface must not consume the latch.
    if (typeof pi.setModel !== 'function')
      return rejectSwitch('pi.setModel is not available in this extension API surface');
    // Capture the model identity BEFORE any switch attempt: reading
    // entry.session.model after setModel would record `to` as `from`.
    const originalFrom = entry.session?.model ? `${entry.session.model.provider}/${entry.session.model.id}` : null;
    // Duplicate = the ACTUAL current model already IS the target AND this
    // task's declared phase already IS the requested phase. A new task in the
    // same session starts with a different (or absent) phase entry, and a
    // native /model change resets the actual model — both correctly allow a
    // fresh selection without any extra state machine.
    if (originalFrom === target && rootPhaseByTask.get(boundDir) === phase)
      return rejectSwitch('this exact model and phase is already active for this task');
    // The SDK needs the fully resolved Model. Catalog list entries may be
    // partial ModelInfo shapes; resolve the exact provider/id and require the
    // resolved identity to match — never guess from a list element or @task.
    let model;
    try { model = ctx.models?.resolve?.(target) ?? null; } catch { model = null; }
    if (!model || `${model.provider}/${model.id}` !== target)
      return rejectSwitch('target model could not be resolved to its exact provider/id in the current session');
    rootModelInFlight.add(sessionId);
    let switched = false;
    const nowModel = () => entry.session?.model ? `${entry.session.model.provider}/${entry.session.model.id}` : null;
    try {
      switched = await pi.setModel(model);
    } catch {
      // A classified, bounded record only: no raw SDK error strings (they can
      // carry provider payloads). The actually observable current model is
      // recorded — never a claimed rollback or success.
      return rejectSwitch('sdk_error', { from: originalFrom, actual_model_after: nowModel() });
    } finally {
      rootModelInFlight.delete(sessionId);
    }
    if (switched !== true)
      return rejectSwitch('pi.setModel returned without confirming the switch', { from: originalFrom, actual_model_after: nowModel() });
    // A true return is only a CONFIGURATION success. The phase (and the
    // success record) are granted only when the live session model actually
    // reads back as the exact target; anything else stays a classified gap.
    const liveAfter = nowModel();
    if (liveAfter !== target)
      return rejectSwitch('switch not verified on the live session model', { from: originalFrom, actual_model_after: liveAfter });
    rootPhaseByTask.set(boundDir, phase);
    if (origin === 'tool') rootToolSelectedByTask.add(boundDir);
    recordSwitch({ ok: true, switched: true, from: originalFrom, actual_model_after: liveAfter });
    return { ok: true, switched: true, from: originalFrom, to: target, phase };
  }

  // Program-initiated Root integration selection (contract: 程序发起的 Root
  // integration 阶段选择). Entry point is the TAGGED pre-send position in the
  // owned `send` RPC only (remind_manual_final_check persists durable facts,
  // then sends with integration_check). All gates reuse existing read-side
  // state and wait discipline; cheap screens run before the fingerprint probe.
  // Returns the classified outcome (cached in rootIntegrationAttempts so a
  // duplicate same-triple send never switches twice) plus guidance text that
  // rides the SAME reminder message when the switch succeeded.
  async function considerProgramIntegrationSwitch(entry, ctx, bound, sessionId, options = {}) {
    // The ONLY entry is the tagged pre-send position in the owned send RPC.
    // A missing/invalid tag selects nothing (and never blocks the reminder).
    if (!Number.isInteger(options.taggedCheck) || options.taggedCheck <= 0)
      return { attempted: false, reason: 'tag_missing_or_invalid' };
    // Main-session identity and a live entry: the RPC's session must be the
    // registry main, the entry's own session, AND the ctx that will resolve
    // models must be the SAME session's context — otherwise selection would
    // use another context's catalog for the current entry. Registry identity
    // is checked against the LIVE ref (ref.session === entry.session); any
    // unknown shape is a skip, never a guess.
    let ctxSessionId = null;
    try { ctxSessionId = ctx?.sessionManager?.getSessionId?.() ?? null; } catch { ctxSessionId = null; }
    let liveRef = null;
    try { liveRef = sdk.AgentRegistry.global().list().find(r => r.id === sdk.MAIN_AGENT_ID && r.kind === 'main') ?? null; }
    catch { liveRef = null; }
    if (!isMainSession(sessionId) || !entry || entry.session?.sessionId !== sessionId
        || ctxSessionId !== sessionId || !liveRef || liveRef.session !== entry.session
        || !activeState(bound.state) || runtimeAbandoned(bound.state))
      return { attempted: false, reason: 'main_session_or_task_not_live' };
    // Real control ownership — resolveBoundTask is display-grade. After the
    // awaits, re-read the CURRENT state synchronously (one read, no polling)
    // and make it the SINGLE authority for every gate below: read failure,
    // or a connection that no longer matches the just-confirmed owned
    // binding, is a skip. Cached and first attempts therefore share exactly
    // the same fresh authority — no duplicated gate block.
    let controlOwned = false;
    try { controlOwned = await host.ownsTask(bound.taskDir, sessionId) === true; } catch { controlOwned = false; }
    if (!controlOwned) return { attempted: false, reason: 'task_not_owned_by_current_host' };
    let state = null;
    try { state = JSON.parse(readFileSync(path.join(bound.taskDir, 'state.json'), 'utf8')); } catch { state = null; }
    if (!state || state.connection?.provider !== 'omp'
        || state.connection?.thread_id !== sessionId
        || state.connection?.socket !== bound.state.connection?.socket
        || !activeState(state) || runtimeAbandoned(state))
      return { attempted: false, reason: 'current_state_unavailable_or_rebound' };
    const td = state.task_delivery;
    if (!td || typeof td !== 'object'
        || typeof td.artifact_root !== 'string' || typeof td.input_digest !== 'string' || typeof td.artifact_digest !== 'string')
      return { attempted: false, reason: 'no_current_task_delivery' };
    // Full tagged-clean authority, evaluated BEFORE any cached outcome so a
    // bad tag or an already-ACKed reminder can never serve stale guidance:
    // verdict complete/continue, delivery.ready, an EMPTY findings array (not
    // merely a missing key), and the exact current triple.
    const taggedCheck = (state.checks || [])[options.taggedCheck - 1];
    const reminderKey = createHash('sha256')
      .update(JSON.stringify([td.artifact_root, td.input_digest, td.artifact_digest])).digest('hex');
    // Full tagged-clean authority as one local predicate, reused verbatim by
    // the final post-await re-check so validity can never be inferred from a
    // record read before the awaits.
    const taggedClean = (check, triple) => !!check && Number.isInteger(options.taggedCheck)
      && check.number === options.taggedCheck
      && !check.stale && !check.manual && check.role === 'reviewer'
      && check.kind === 'artifact'
      && ['complete', 'continue'].includes(check?.result?.verdict)
      && check?.result?.delivery?.ready === true
      && Array.isArray(check?.result?.findings) && check.result.findings.length === 0
      && check.input_digest === triple.input_digest && check.artifact_root === triple.artifact_root
      && check.artifact_digest === triple.artifact_digest;
    const taggedAuthorityOk = taggedClean(taggedCheck, td);
    if (!taggedAuthorityOk) return { attempted: false, reason: 'tagged_check_scope_mismatch' };
    if ((state.manual_check_reminders || {})[reminderKey])
      return { attempted: false, reason: 'reminder_already_sent_for_triple' };
    const attemptKey = JSON.stringify([bound.taskDir, td.input_digest, td.artifact_root, td.artifact_digest]);
    // Idempotency slot is consumed ONLY by an actual switch attempt (success
    // or classified failure): precondition screens below can mature later
    // (reminder arrival, member settle, busy clear) and must stay re-checkable.
    const finish = (outcome) => { if (outcome.attempted === true) rootIntegrationAttempts.set(attemptKey, outcome); return outcome; };
    // Root tool selection on this task conservatively wins (any confirmed
    // switch in this process, regardless of version).
    if (rootToolSelectedByTask.has(bound.taskDir)) return finish({ attempted: false, reason: 'root_tool_already_selected' });
    // Wait discipline: identical gates to the root-model tool.
    const observations = state.check_observations;
    if (observations && typeof observations === 'object'
        && Object.values(observations).some(o => o && typeof o === 'object' && o.status === 'in_flight'))
      return finish({ attempted: false, reason: 'independent_check_in_flight' });
    if (state.pending_finalization || state.completion_stop_pending || state.next_check_manual === true)
      return finish({ attempted: false, reason: 'manual_final_or_stop_queued' });
    if (state.recheck) return finish({ attempted: false, reason: 'recheck_scheduled' });
    const findings = Object.values(state.findings || {});
    if (findings.some(f => f && f.status === 'open')) return finish({ attempted: false, reason: 'open_finding' });
    // Tagged authority and the pre-send reminder window were verified above,
    // BEFORE the cached outcome; the busy screens follow.
    // Root must actually be at rest: live tools, native streaming, and
    // owner-scoped async jobs. At this PRE-SEND RPC position no direct prompt
    // is preparing (#promptInFlightCount is 0), so the public isStreaming
    // getter is a valid busy screen here — unlike inside before_agent_start
    // preparation, where it is always true.
    if (entry.activeTools.size > 0) return finish({ attempted: false, reason: 'root_tools_in_flight' });
    if (entry.session?.isStreaming === true) return finish({ attempted: false, reason: 'root_streaming' });
    let asyncSnapshot = null;
    try { asyncSnapshot = typeof entry.session?.getAsyncJobSnapshot === 'function' ? entry.session.getAsyncJobSnapshot() : null; }
    catch { asyncSnapshot = null; }
    if (!asyncSnapshot || !Array.isArray(asyncSnapshot.running))
      return finish({ attempted: false, reason: 'async_job_state_unknown' });
    if (asyncSnapshot.running.length > 0) return finish({ attempted: false, reason: 'owner_async_jobs_running' });
    // Members settled: the runtime's own rule (terminal member statuses, no
    // queued amendment delivery).
    if (!Array.isArray(state.members))
      return finish({ attempted: false, reason: 'members_state_unknown' });
    if (!state.members.every(m => m && ['completed', 'failed', 'refused', 'rejected'].includes(m.status)))
      return finish({ attempted: false, reason: 'members_not_settled' });
    if (Array.isArray(state.amendment_delivery_queue) && state.amendment_delivery_queue.length)
      return finish({ attempted: false, reason: 'amendments_queued' });
    // External explicit model selection conservatively wins: live flag from
    // the public session subscribe, or durable model_change entries beyond
    // the baseline that this process did not cause. Baseline is captured at
    // first observation (after the launch entry exists); unknown -> skip.
    if (externalModelChange.get(sessionId)) return finish({ attempted: false, reason: 'external_model_change_observed' });
    let branchChanges = null;
    try {
      branchChanges = entry.session?.sessionManager?.getBranch?.().filter(e => e && e.type === 'model_change').length ?? null;
    } catch { branchChanges = null; }
    const baseline = modelChangeBaseline.get(sessionId);
    if (branchChanges === null || typeof baseline !== 'number' || baseline < 0)
      return finish({ attempted: false, reason: 'model_change_baseline_unknown' });
    if (branchChanges < baseline) return finish({ attempted: false, reason: 'model_change_history_rewound' });
    if (branchChanges - baseline - (ownModelSwitches.get(sessionId) || 0) > 0)
      return finish({ attempted: false, reason: 'external_model_change_recorded' });
    // Cached outcome: every generic gate above (fresh durable wait/members/
    // delivery, live busy screens, external selection) has already run. The
    // cache only decides TARGET/PHASE liveness and fingerprint validity — a
    // stale target is never presented as "selected for this turn".
    const prior = rootIntegrationAttempts.get(attemptKey);
    if (prior) {
      const liveModel = entry.session?.model ? `${entry.session.model.provider}/${entry.session.model.id}` : null;
      const targetStillLive = prior.ok === true && prior.to === liveModel
        && rootPhaseByTask.get(bound.taskDir) === 'integration';
      const bindingNow = readRootBinding(bound.taskDir);
      const tripleStillCurrent = !!bindingNow && bindingNow.fingerprint_status === 'ok'
        && bindingNow.artifact_root === td.artifact_root && bindingNow.input_digest === td.input_digest
        && bindingNow.artifact_digest === td.artifact_digest;
      if (!targetStillLive || !tripleStillCurrent) return { ...prior, guidance: undefined };
      return prior;
    }
    // Provenance: only the checks that ACTUALLY found a resolved finding for
    // the current triple. No state.review.model, no ranking, no time-based
    // inference; ledger cross-check by exact call_id.
    let ledger = null;
    try {
      // Same-task verification goes through the ledger document's own scope
      // fields (ResourceCallLedger#read/valid_row shape): a known schema
      // version, the CURRENT task id at the top level, and per-row exact
      // call_id + task_id. A foreign or unknown document is a classified
      // skip — a file merely sitting in this directory proves nothing.
      const document = JSON.parse(await fs.readFile(path.join(bound.taskDir, 'resource-calls.json'), 'utf8'));
      if (typeof state.id !== 'string' || !state.id
          || document.schema_version !== 'orbit-resource-calls-v1'
          || document.task_id !== state.id
          || !document.calls || typeof document.calls !== 'object' || Array.isArray(document.calls))
        return finish({ attempted: false, reason: 'ledger_scope_unknown_or_foreign' });
      ledger = document.calls;
    } catch { return finish({ attempted: false, reason: 'ledger_unreadable' }); }
    const resolvedForCurrent = findings.filter(f => f && typeof f === 'object' && f.status === 'resolved'
      && f.observed_input === td.input_digest && f.observed_root === td.artifact_root
      && f.resolution_input === td.input_digest && f.resolution_root === td.artifact_root
      && f.resolution_version === td.artifact_digest
      && typeof f.check === 'number' && typeof f.resolution_check === 'number');
    const targets = new Map();
    const INDEPENDENT_ROLES = ['reviewer', 'adjudicator'];
    for (const f of resolvedForCurrent) {
      const raiseCheck = (state.checks || [])[f.check - 1];
      const resolveCheck = (state.checks || [])[f.resolution_check - 1];
      if (!raiseCheck || raiseCheck.stale || !resolveCheck || resolveCheck.stale)
        return finish({ attempted: false, reason: 'finding_check_stale_or_missing' });
      // Raising check scope must match the finding's OBSERVED triple (the
      // buggy version), and it must actually contain the finding id.
      if (!INDEPENDENT_ROLES.includes(raiseCheck.role) || raiseCheck.kind !== 'artifact'
          || raiseCheck.input_digest !== f.observed_input || raiseCheck.artifact_root !== f.observed_root
          || typeof f.observed_version !== 'string' || raiseCheck.artifact_digest !== f.observed_version)
        return finish({ attempted: false, reason: 'raising_check_scope_mismatch' });
      const raising = Array.isArray(raiseCheck?.result?.findings)
        && raiseCheck.result.findings.some(x => x && (x.id === f.id || x === f.id));
      if (!raising) return finish({ attempted: false, reason: 'finding_not_in_raising_check_result' });
      // Resolution check scope must match the finding's RESOLUTION triple (the
      // fixed version) and its real result must carry the finding as resolved.
      if (!INDEPENDENT_ROLES.includes(resolveCheck.role) || resolveCheck.kind !== 'artifact'
          || resolveCheck.input_digest !== f.resolution_input || resolveCheck.artifact_root !== f.resolution_root
          || resolveCheck.artifact_digest !== f.resolution_version
          || !['complete', 'continue', 'correct'].includes(resolveCheck?.result?.verdict)
          || !Array.isArray(resolveCheck?.result?.resolved_ids) || !resolveCheck.result.resolved_ids.includes(f.id))
        return finish({ attempted: false, reason: 'resolution_check_scope_mismatch' });
      const calls = raiseCheck?.usage?.calls;
      if (!Array.isArray(calls) || !calls.length) return finish({ attempted: false, reason: 'raising_check_has_no_calls' });
      const models = new Set();
      for (const c of calls) {
        if (!c || typeof c.provider !== 'string' || typeof c.model !== 'string' || typeof c.call_id !== 'string')
          return finish({ attempted: false, reason: 'raising_call_shape_invalid' });
        const row = ledger[c.call_id];
        if (!row || row.call_id !== c.call_id || row.task_id !== state.id
            || row.status !== 'completed' || row.role !== 'checker'
            || row.actual_identity?.provider !== c.provider || row.actual_identity?.model !== c.model)
          return finish({ attempted: false, reason: 'raising_call_ledger_mismatch' });
        models.add(`${c.provider}/${c.model}`);
      }
      if (models.size !== 1) return finish({ attempted: false, reason: 'raising_identity_ambiguous' });
      const target = models.values().next().value;
      const priorEntry = targets.get(target) || { findingIds: [], callIds: [] };
      targets.set(target, { findingIds: [...priorEntry.findingIds, f.id],
        callIds: [...priorEntry.callIds, ...calls.map(c => c.call_id)] });
    }
    if (targets.size === 0) return finish({ attempted: false, reason: 'no_resolved_finding_for_current_triple' });
    if (targets.size > 1) return finish({ attempted: false, reason: 'multiple_finding_models_no_ranking' });
    const target = targets.keys().next().value;
    const { findingIds, callIds } = targets.get(target);
    // Target must differ from the live current Root model.
    const currentModel = entry.session?.model ? `${entry.session.model.provider}/${entry.session.model.id}` : null;
    if (target === currentModel) return finish({ attempted: false, reason: 'finding_model_already_root' });
    // readRootBinding fingerprint gate: unknown/stale/amend/rebind refuse.
    const binding = readRootBinding(bound.taskDir);
    if (!binding || binding.fingerprint_status !== 'ok'
        || binding.artifact_root !== td.artifact_root || binding.input_digest !== td.input_digest
        || binding.artifact_digest !== td.artifact_digest)
      return finish({ attempted: false, reason: 'root_binding_fingerprint_mismatch' });
    // Fresh pool∩catalog re-sync AFTER the screens mature and BEFORE the
    // final binding/ownership/wait re-verification: a sessionAgents cache
    // left by an earlier tool call must never authorize a target the user
    // has since removed from their pool. A failed re-sync is a classified
    // skip of this evaluation (no idempotency slot consumed).
    const freshSync = await syncSessionAgents(ctx);
    if (!freshSync.ok) return finish({ attempted: false, reason: 'pool_resync_failed' });
    // Bounded re-verification after every await (ledger read, screens): the
    // task must still be the same owned active binding with the same wait
    // gates clear — a terminal transition, rebind, or queued manual during
    // evaluation aborts the attempt without consuming the idempotency slot.
    const rebind = await resolveBoundTask(sessionId, ctx?.cwd).catch(() => null);
    let stillOwned = false;
    try { stillOwned = !!rebind && rebind.taskDir === bound.taskDir && await host.ownsTask(rebind.taskDir, sessionId) === true; } catch { stillOwned = false; }
    // Final bounded verification: re-read the CURRENT state synchronously
    // (never the pre-await rebind.state), re-check the owned connection and
    // that the ctx/session/live Main identity still correspond. Read failure
    // or a changed ownership is a skip — no new RPC, no claim of eliminating
    // every cross-process or concurrent-UI race (the documented last-writer
    // limitation stands).
    // Synchronous fingerprint FIRST: readRootBinding shells out to Ruby, and a
    // check state written by another process during that window must not be
    // ignored by an rs read that started earlier. Only after the fingerprint
    // returns is the CURRENT state read synchronously.
    const bindingFinal = readRootBinding(bound.taskDir);
    const tripleAuthoritative = !!bindingFinal && bindingFinal.fingerprint_status === 'ok'
      && bindingFinal.artifact_root === td.artifact_root && bindingFinal.input_digest === td.input_digest
      && bindingFinal.artifact_digest === td.artifact_digest;
    let rs = null;
    try { rs = JSON.parse(readFileSync(path.join(bound.taskDir, 'state.json'), 'utf8')); } catch { rs = null; }
    let ctxSessionIdFinal = null;
    try { ctxSessionIdFinal = ctx?.sessionManager?.getSessionId?.() ?? null; } catch { ctxSessionIdFinal = null; }
    if (!stillOwned || !rs || rs.connection?.provider !== 'omp'
        || rs.connection?.thread_id !== sessionId
        || rs.connection?.socket !== bound.state.connection?.socket
        || ctxSessionIdFinal !== sessionId
        || !isMainSession(sessionId) || entry.session?.sessionId !== sessionId)
      rs = null;
    const rtd = rs?.task_delivery;
    // The fresh tagged check must bind to the SAME triple the selection was
    // derived from: explicit field-by-field equality with the original td,
    // beyond taggedClean's internal scope match against rtd itself.
    const taggedStillCurrent = !!rtd
      && rtd.artifact_root === td.artifact_root && rtd.input_digest === td.input_digest
      && rtd.artifact_digest === td.artifact_digest
      && taggedClean((rs.checks || [])[options.taggedCheck - 1], rtd)
      && !(rs.manual_check_reminders || {})[reminderKey];
    // Live Root busy screens re-checked AFTER every await: work that started
    // during the ledger/pool/rebind/ownsTask awaits must not be overridden.
    let jobsNow = null;
    try { jobsNow = typeof entry.session?.getAsyncJobSnapshot === 'function' ? entry.session.getAsyncJobSnapshot() : null; }
    catch { jobsNow = null; }
    let branchChangesNow = null;
    try {
      branchChangesNow = entry.session?.sessionManager?.getBranch?.().filter(e => e && e.type === 'model_change').length ?? null;
    } catch { branchChangesNow = null; }
    if (!rs || !activeState(rs) || runtimeAbandoned(rs)
        || (rs.check_observations && typeof rs.check_observations === 'object'
            && Object.values(rs.check_observations).some(o => o && typeof o === 'object' && o.status === 'in_flight'))
        || rs.pending_finalization || rs.completion_stop_pending || rs.next_check_manual === true
        || rs.recheck || Object.values(rs.findings || {}).some(f => f && f.status === 'open')
        || !Array.isArray(rs.members) || !rs.members.every(m => m && ['completed', 'failed', 'refused', 'rejected'].includes(m.status))
        || (Array.isArray(rs.amendment_delivery_queue) && rs.amendment_delivery_queue.length)
        || !tripleAuthoritative || !taggedStillCurrent
        || entry.activeTools.size > 0 || entry.session?.isStreaming === true
        || !jobsNow || !Array.isArray(jobsNow.running) || jobsNow.running.length > 0
        || rootToolSelectedByTask.has(bound.taskDir) || externalModelChange.get(sessionId)
        || branchChangesNow === null)
      return finish({ attempted: false, reason: 'state_changed_during_evaluation' });
    const finalBaseline = modelChangeBaseline.get(sessionId);
    if (typeof finalBaseline !== 'number' || finalBaseline < 0 || branchChangesNow < finalBaseline
        || branchChangesNow - finalBaseline - (ownModelSwitches.get(sessionId) || 0) > 0)
      return finish({ attempted: false, reason: 'state_changed_during_evaluation' });
    const outcome = { attempted: true, ...(await performRootModelSwitch({ entry, ctx, boundDir: bound.taskDir, target,
      phase: 'integration',
      reason: `program integration selection: finding(s) ${findingIds.join(',')} found by ${target}`,
      origin: 'program',
      provenance: { finding_ids: findingIds, detecting_call_ids: callIds,
        raising_check_of_first_finding: resolvedForCurrent[0].check,
        resolution_check_of_first_finding: resolvedForCurrent[0].resolution_check, tagged_check: options.taggedCheck,
        detecting_model: target,
        version_triple: { artifact_root: td.artifact_root, input_digest: td.input_digest, artifact_digest: td.artifact_digest } } })) };
    if (outcome.ok === true) outcome.guidance = `程序来源提示（本条为程序追加，非用户新要求）：已核查的独立检查发现并确认修复的真实缺陷（${findingIds.join(',')}，逐项来源与回执见 root_integration_model_selected 记录）由 ${target} 发现——程序已在发送本终检提醒前选择该型号承担 integration 阶段（仅此一次，配置已选择；真实调用以本回合后的 native 回执为准）。（核对职责已由本轮提醒正文承担。）task_delivery 与 Root verifications 归属不变。`;
    return finish(outcome);
  }

  pi.registerTool({ name: 'orbit', label: 'Orbit', description: toolDescription, parameters: pi.zod.object(toolArgs(pi.zod)),
    async execute(_id, args, _signal, _update, ctx) {
      const entry = await connect(ctx);
      let text;
      if (args?.action === 'root-model') {
        // The shared host already verified task ownership; this branch owns
        // the pool∩catalog check, the public pi.setModel call, and the small
        // factual record. A null from host.execute means "native dispatch".
        await host.execute(args, ctx);
        text = JSON.stringify(await handleRootModel(args, entry, ctx, typeof _id === 'string' ? _id : null));
      } else {
        text = await host.execute(args, ctx);
      }
      try {
        const result = JSON.parse(text);
        if (typeof result.task_directory === 'string') {
          taskDirs.set(entry.id, result.task_directory);
          // An explicit start that succeeded completes entry recovery: later
          // provider requests of this turn must not carry the stale
          // "[entry failed, start it]" instruction anymore.
          entryRecovery.delete(entry.id);
          noteAssociation(entry.id, result.task_directory);
          noteModelIdentity({ taskDir: result.task_directory, role: 'root', agentId: sdk.MAIN_AGENT_ID, sessionId: entry.id,
            model: entry.session?.model ? `${entry.session.model.provider}/${entry.session.model.id}` : null });
        }
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
        const modelStatus = runModelStatusCli(ctx.cwd);
        const reportedCandidates = modelStatus.ok && Array.isArray(modelStatus.report?.candidates)
          ? modelStatus.report.candidates : [];
        const statusByModel = new Map(reportedCandidates.map(candidate => [candidate.model, candidate]));
        const sessionModelIds = () => {
          try { return (ctx.models?.list?.() ?? []).map(m => `${m.provider}/${m.id}`); } catch { return []; }
        };
        const poolEntries = (poolModels, available) => {
          const listed = new Set(available);
          const entries = available.map(id => ({
            id, available: true,
            evidenceStatus: poolModels.includes(id) ? statusByModel.get(id)?.evidence_status ?? '未知' : undefined,
            overviewStatus: poolModels.includes(id) ? statusByModel.get(id)?.model_overview : undefined,
          }));
          for (const id of poolModels) if (!listed.has(id))
            entries.push({ id, available: false, evidenceStatus: statusByModel.get(id)?.evidence_status ?? '未知',
              overviewStatus: statusByModel.get(id)?.model_overview });
          return entries;
        };
        // Legacy/headless surface: no UI (or a UI that cannot host custom
        // components) still gets the plain text list and per-item commands.
        const textListing = available => {
          const poolSet = new Set(pool.models);
          const stale = pool.models.filter(id => !available.includes(id));
          return [
            'Model candidate pool (ADR-009). Selectable in this session:',
            ...available.filter(id => poolSet.has(id)).map(id => `  [in pool]  ${id} · 证据 ${statusByModel.get(id)?.evidence_status ?? '未知'} · 概述 ${statusByModel.get(id)?.model_overview ?? '未知'}${statusByModel.get(id)?.evidence_detail ? `（${statusByModel.get(id).evidence_detail}）` : ''}`),
            ...available.filter(id => !poolSet.has(id)).map(id => `  [addable]  ${id}`),
            ...(stale.length ? ['In pool but NOT selectable in this session (kept; removable):', ...stale.map(id => `  [stale]    ${id} · 证据 ${statusByModel.get(id)?.evidence_status ?? '未知'} · 概述 ${statusByModel.get(id)?.model_overview ?? '未知'}`)] : []),
            ...(modelStatus.ok ? [] : [`证据诊断不可用：${modelStatus.reason}`]),
            '质量：未判断；检查者隔离目录/凭据：未探测。缺证据请从一手来源提交 orbit model-evidence --file FILE|-；Root 可直接选择 OMP 可用且隔离检查者可解析的型号。',
            'Commands:',
            '  /orbit-models add <provider/id>    (only IDs marked [addable])',
            '  /orbit-models remove <provider/id>',
            '受控通用 task 派发按当前会话解析 @task 精确型号，并在注册与首次请求核对实际成员模型；候选池只用于生成首选成员 agent。',
            `当前 Root：${ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : '未知'}；低成本会话请自行指定 orbit omp --model <provider/id>，Orbit 不暗中切换模型。`,
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
    const block = statusBlock(bound.state);
    const advisory = entryDelegationAdvisory(bound.state, bound.taskDir);
    if (advisory) entryAdvisorySent.add(bound.taskDir);
    // Only the regular status guidance (and the advisory, deduplicated by its
    // own sent set) rides the system prompt. The work-unit bootstrap is NOT
    // carried here: it belongs to the extensible provider payload path alone,
    // so one request never sees the same sentence twice. The program-initiated
    // integration selection does NOT ride this hook anymore: the SDK's idle
    // custom-message wake (deliverCustomMessage) never runs before_agent_start,
    // and the direct path is self-locked by isStreaming during preparation.
    // Selection happens in the owned `send` RPC branch (see the
    // integration_check tag handling there).
    const parts = [block];
    if (advisory) parts.push(advisory);
    return { systemPrompt: withStatusBlock(event?.systemPrompt, parts.join('\n')) };
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
    // Flush durable collaboration evidence: drain per-task queues, make one
    // final attempt at recording an unresolved persistence-gap episode, and
    // close the 0600 append handles. A hard crash can still lose the
    // unflushed tail; the exporter's missing-evidence reconciliation covers
    // that instead of a fabricated continuous record.
    await closeCollabWriters();
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

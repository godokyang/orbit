// Root execution verification receipts (ticket D-ROOT-VERIFICATIONS).
//
// Facts only. Every field comes from a real OMP tool_execution_start /
// tool_execution_end event of the Root session, or from the read-only
// scripts/orbit-root-binding helper invoked at capture time. Nothing here
// decides whether a receipt verifies the CURRENT requirement: comparing a
// receipt's pinned input_digest/artifact_digest against the current task
// input and artifact snapshot (artifact_matches / input_matches) is the
// Ruby start_check path's job. No TTL-cached "current" verdicts in JS.
//
// bash exit-code contract (verified against SDK 18.3.4 primary source
// src/tools/bash.ts #buildCompletedResult + #throwIfUnfinished): a terminal
// bash result that is NOT an error is only reachable when the process exit
// code was 0 — cancellation and missing status throw, timeout throws or
// returns an error result, and non-zero code marks the result failed. The SDK omits
// details.exitCode for that success case, so the 0 is recorded with
// exit_code_source 'sdk_terminal_success_contract': a contract citation,
// not a reported field and never a blind zero-fill. Background launches
// (details.async), failures without a reported code, and every eval keep
// 'unknown'.
//
// eval receipts carry only the OUTER eval execution status: an ok eval is
// not an exit 0 of any test run inside the cell. The checker must read the
// saved script/output for that evidence; no synthetic subprocess receipt is
// fabricated here.
//
// Interrupt replay distinguishes calls that never ran (dropped) from calls
// already started (kept as interrupted, with unknown exit status).

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export const VERIFY_FILENAME = 'root-verifications.jsonl';
// Tools whose real tool_execution_start/end events produce a durable receipt.
// bash/eval carry an execution status; edit/write are FILE-tool observations:
// they record identity, binding and a bounded target list only — never the
// written content, the patch/diff or any script body. Observing a completed
// file tool call is NOT proof that bytes changed.
export const CAPTURED_TOOLS = ['bash', 'eval', 'edit', 'write'];
// Bounded target metadata for file tools.
export const FILE_TARGET_CAP = 8;
export const FILE_TARGET_LENGTH_CAP = 512;
// Per-string payload bound for durable receipts; the flag next to each
// field records whether truncation happened. Missing data stays null.
export const TEXT_CAP = 4000;
// state() returns at most this many most-recent receipts of the bound task.
export const STATE_RECEIPT_CAP = 32;
// Tail window when reading the durable file; a partial first line fails
// JSON.parse and is skipped, so a huge file never floods state().
const TAIL_BYTES = 256 * 1024;

function boundedText(value) {
  if (typeof value !== 'string') return { text: null, truncated: false };
  return value.length > TEXT_CAP
    ? { text: value.slice(0, TEXT_CAP), truncated: true }
    : { text: value, truncated: false };
}

// bash/eval OUTPUT uses a dedicated head+tail policy (ticket C01): the head
// of a log carries the run context and the tail carries the failure summary,
// so a prefix-only cut loses exactly the evidence an independent check
// needs. The in-band marker states this layer's visible length with explicit
// units (UTF-16 code units = JS string length, plus UTF-8 bytes) and the
// SHA-256 of that visible text; the same facts ride as structured
// `output_omitted` metadata so a later compression layer never has to parse
// or re-wrap this marker. Cut points never split a surrogate pair, so the
// kept text stays valid Unicode. command/script and every other string keep
// the prefix-only boundedText policy above.
function boundedLogText(value) {
  const untrimmed = { text: typeof value === 'string' ? value : null, truncated: false, omitted: null };
  if (typeof value !== 'string') return untrimmed;
  if (value.length <= TEXT_CAP) return untrimmed;
  const sha256 = createHash('sha256').update(value, 'utf8').digest('hex');
  const bytes = Buffer.byteLength(value, 'utf8');
  let omitted = value.length;
  // The marker's own digit count feeds the body budget. Within one digit
  // count the computation is a constant function, so a round that lands in
  // the same digit class converges on the spot; between rounds the digit
  // count strictly shrinks (a surrogate adjustment can bounce it up by one
  // class exactly once at a power-of-ten boundary, which the next round
  // settles). Twelve rounds therefore cover every reachable input; anything
  // else is an invariant violation, never a reason to emit a lossy cut.
  for (let round = 0; round < 12; round += 1) {
    const marker = `…[omitted ${omitted} of ${value.length} UTF-16 code units / ${bytes} UTF-8 bytes sha256:${sha256}]`;
    let head = Math.ceil((TEXT_CAP - marker.length) / 2);
    let tail = TEXT_CAP - marker.length - head;
    // Never split a surrogate pair at a cut point.
    const lastHead = value.charCodeAt(head - 1);
    if (lastHead >= 0xd800 && lastHead <= 0xdbff) head -= 1;
    const firstTail = value.charCodeAt(value.length - tail);
    if (firstTail >= 0xdc00 && firstTail <= 0xdfff) tail -= 1;
    const next = value.length - head - tail;
    if (next === omitted) {
      return { text: value.slice(0, head) + marker + value.slice(value.length - tail), truncated: true,
               omitted: { omitted_utf16_units: next, visible_utf16_units: value.length,
                          visible_utf8_bytes: bytes, sha256 } };
    }
    omitted = next;
  }
  throw new Error('boundedLogText did not converge: marker budget invariant violated');
}

function resultText(result) {
  if (typeof result === 'string') return result;
  if (Array.isArray(result?.content)) {
    return result.content
      .filter(part => part && part.type === 'text' && typeof part.text === 'string')
      .map(part => part.text)
      .join('\n');
  }
  return null;
}

function boundTargets(values) {
  const out = [];
  for (const value of values) {
    if (typeof value !== 'string' || !value) continue;
    const bounded = value.length > FILE_TARGET_LENGTH_CAP ? value.slice(0, FILE_TARGET_LENGTH_CAP) : value;
    if (!out.includes(bounded)) out.push(bounded);
    if (out.length >= FILE_TARGET_CAP) break;
  }
  return out;
}

// A control address (agent://, xd://, ...) is a routing target, not a file.
function isControlUri(value) {
  return typeof value === 'string' && /^[a-z][a-z0-9+.-]*:\/\//i.test(value);
}

// Target metadata for a file tool call. Only a plain string `path` is
// projected. The hashline `{i, input}` dialect is deliberately NOT hand-parsed
// here: its targets stay unknown rather than guessed, and its body is never
// captured.
function fileTargets(args) {
  const candidate = typeof args?.path === 'string' && args.path ? args.path : null;
  if (candidate === null) {
    return { targets: null, targets_status: 'unknown', control_targets: [] };
  }
  if (isControlUri(candidate)) {
    return { targets: null, targets_status: 'control_uri', control_targets: boundTargets([candidate]) };
  }
  return { targets: boundTargets([candidate]), targets_status: 'path', control_targets: [] };
}

// Start-side fact capture. `sessionCwd` is the Root session's real cwd at
// the moment of the tool start (sessionManager.getCwd()); a bash args.cwd is
// resolved against it exactly like the SDK does (resolveToCwd semantics:
// relative cwd resolves against the session cwd). The artifact_root is never
// used as a stand-in for the execution cwd.
export function captureStart(event, { sessionCwd = null } = {}) {
  const tool = event?.toolName;
  if (!CAPTURED_TOOLS.includes(tool)) return null;
  const args = event.args && typeof event.args === 'object' ? event.args : {};
  const isFileTool = tool === 'edit' || tool === 'write';
  // File tools never contribute a captured body: no content, no patch, no script.
  const rawText = tool === 'bash' ? args.command : tool === 'eval' ? args.code : null;
  let executionCwd = sessionCwd;
  if (tool === 'bash' && typeof args.cwd === 'string' && args.cwd) {
    let cwd = args.cwd;
    if (cwd === '~' || cwd.startsWith('~/')) cwd = path.join(os.homedir(), cwd.slice(2));
    // These SDK-specific path normalizations are not reproduced here.
    // Keep unknown instead of recording an approximation as the actual cwd.
    if (/^[@:]|^file:|[\u00a0\u2000-\u200a\u202f\u205f\u3000]/.test(cwd)) executionCwd = null;
    else if (/^\/+$/u.test(cwd)) executionCwd = sessionCwd;
    else executionCwd = sessionCwd ? path.resolve(sessionCwd, cwd) : path.isAbsolute(cwd) ? cwd : null;
  }
  const observedAt = Date.now();
  return {
    tool,
    text: typeof rawText === 'string' ? rawText : null,
    executionCwd,
    // Program-local observation of the REAL tool_execution_start event. This is
    // the moment the program saw the start event, not an SDK-reported field:
    // the SDK start event carries no such timestamp. It is what makes it
    // possible to say "the tool started after check N returned"; without a
    // start event the receipt keeps start_observed: false and null instead.
    start_observed_at: new Date(observedAt).toISOString(),
    start_observed_at_ms: observedAt,
    start_observed_at_source: 'program_local_event_observation',
    ...(isFileTool ? fileTargets(args) : {}),
    // Filled by the caller from the read-only binding helper at start time;
    // binding_status 'unknown' marks an explicit gap, never a guess.
    artifact_root: null,
    input_digest: null,
    binding_status: null,
  };
}

// Completion-side receipt. `start` is the record pinned at the real
// tool_execution_start; when it is missing the receipt keeps
// start_observed: false and null input identity instead of guessing from
// nearby observations. `endBinding` is the fresh read-only helper result at
// completion; null records the gap explicitly.
export function buildReceipt({ event, start, endBinding, taskDirectory = null, rootSessionId = null }) {
  if (!event || event.type !== 'tool_execution_end') return null;
  const tool = event.toolName;
  if (!CAPTURED_TOOLS.includes(tool)) return null;
  const isFileTool = tool === 'edit' || tool === 'write';
  const details = event.result && typeof event.result === 'object' ? event.result.details : null;
  const interrupted = details?.source === 'interrupt_skipped';
  if (interrupted && details.execution !== 'started') return null;
  const isError = event.isError === true || interrupted;
  const asyncExec = !!(details && typeof details === 'object' && details.async);
  let exitCode = null;
  let exitCodeSource = 'unknown';
  if (isFileTool) {
    exitCodeSource = 'not_applicable';
  } else if (tool === 'bash') {
    if (typeof details?.exitCode === 'number') {
      exitCode = details.exitCode;
      exitCodeSource = 'reported';
    } else if (!isError && !asyncExec && details?.timedOut !== true) {
      exitCode = 0;
      exitCodeSource = 'sdk_terminal_success_contract';
    }
  }
  // File tools record NO result body: an edit result can carry the applied
  // patch and a write result its content, so the receipt keeps metadata only.
  const output = isFileTool ? { text: null, truncated: false, omitted: null } : boundedLogText(resultText(event.result));
  const input = boundedText(start?.text ?? null);
  const now = Date.now();
  const receipt = {
    kind: 'root_verification',
    source: 'omp_native_tool_result',
    task_directory: start?.task_directory ?? taskDirectory,
    root_session_id: start?.root_session_id ?? rootSessionId,
    at: new Date(now).toISOString(),
    at_ms: now,
    start_observed_at: start?.start_observed_at ?? null,
    start_observed_at_ms: start?.start_observed_at_ms ?? null,
    start_observed_at_source: start?.start_observed_at_source ?? null,
    tool_call_id: typeof event.toolCallId === 'string' ? event.toolCallId : null,
    tool,
    status: interrupted ? 'interrupted' : isError ? 'failed' : 'completed',
    is_error: isError,
    async: asyncExec,
    exit_code: exitCode,
    exit_code_source: exitCodeSource,
    output: output.text,
    output_truncated: output.truncated || Boolean(details?.meta?.truncation || details?.meta?.artifactError),
    execution_cwd: start?.executionCwd ?? null,
    artifact_root: start?.artifact_root ?? null,
    input_digest: start?.input_digest ?? null,
    artifact_root_at_completion: endBinding?.artifact_root ?? null,
    artifact_digest: endBinding?.artifact_digest ?? null,
    fingerprint_status: endBinding?.fingerprint_status ?? 'unknown',
  };
  // Capture-layer omission facts travel as structured metadata, so the
  // check-input compression layer never has to parse or re-wrap the marker.
  if (output.omitted) receipt.output_omitted = output.omitted;
  if (tool === 'bash') {
    receipt.command = input.text;
    receipt.command_truncated = input.truncated;
  } else if (tool === 'eval') {
    receipt.script = input.text;
    receipt.script_truncated = input.truncated;
  } else {
    // File tool: identity + bounded targets only. The result status is the
    // tool result, NOT a statement that the file's bytes changed, and no
    // content or diff is ever stored.
    receipt.targets = start?.targets ?? null;
    receipt.targets_status = start?.targets_status ?? 'unknown';
    receipt.control_targets = start?.control_targets ?? [];
    receipt.effect = 'file_tool_call_observed_not_bytes_changed';
    receipt.content_saved = false;
    receipt.diff_saved = false;
    receipt.output_saved = false;
  }
  if (!start) receipt.start_observed = false;
  if (start?.binding_status === 'unknown' || !endBinding) receipt.binding_status = 'unknown';
  return receipt;
}

// Durable append. Returns null on success, the error on failure — the
// caller surfaces the failure through the collaboration evidence channel;
// a lost receipt is never silent.
export function appendReceipt(taskDir, receipt) {
  try {
    fs.appendFileSync(path.join(taskDir, VERIFY_FILENAME), JSON.stringify(receipt) + '\n', { mode: 0o600 });
    return null;
  } catch (error) {
    return error;
  }
}

// Most-recent receipts of exactly this task directory. Malformed or partial
// tail lines are skipped; a missing file is an empty history, not an error.
export function readReceipts(taskDir, limit = STATE_RECEIPT_CAP) {
  const file = path.join(taskDir, VERIFY_FILENAME);
  let raw;
  try {
    const stat = fs.statSync(file);
    const size = Math.min(stat.size, TAIL_BYTES);
    const buffer = Buffer.alloc(size);
    const fd = fs.openSync(file, 'r');
    try {
      fs.readSync(fd, buffer, 0, size, stat.size - size);
    } finally {
      fs.closeSync(fd);
    }
    raw = buffer.toString('utf8');
  } catch {
    return [];
  }
  const receipts = [];
  for (const line of raw.split('\n')) {
    if (!line) continue;
    try {
      const value = JSON.parse(line);
      if (value && value.kind === 'root_verification') receipts.push(value);
    } catch { /* partial tail line or corruption: skip, never fabricate */ }
  }
  return receipts.slice(-limit);
}

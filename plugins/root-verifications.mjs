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

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export const VERIFY_FILENAME = 'root-verifications.jsonl';
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

// Start-side fact capture. `sessionCwd` is the Root session's real cwd at
// the moment of the tool start (sessionManager.getCwd()); a bash args.cwd is
// resolved against it exactly like the SDK does (resolveToCwd semantics:
// relative cwd resolves against the session cwd). The artifact_root is never
// used as a stand-in for the execution cwd.
export function captureStart(event, { sessionCwd = null } = {}) {
  const tool = event?.toolName;
  if (tool !== 'bash' && tool !== 'eval') return null;
  const args = event.args && typeof event.args === 'object' ? event.args : {};
  const rawText = tool === 'bash' ? args.command : args.code;
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
  return {
    tool,
    text: typeof rawText === 'string' ? rawText : null,
    executionCwd,
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
  if (tool !== 'bash' && tool !== 'eval') return null;
  const details = event.result && typeof event.result === 'object' ? event.result.details : null;
  const interrupted = details?.source === 'interrupt_skipped';
  if (interrupted && details.execution !== 'started') return null;
  const isError = event.isError === true || interrupted;
  const asyncExec = !!(details && typeof details === 'object' && details.async);
  let exitCode = null;
  let exitCodeSource = 'unknown';
  if (tool === 'bash') {
    if (typeof details?.exitCode === 'number') {
      exitCode = details.exitCode;
      exitCodeSource = 'reported';
    } else if (!isError && !asyncExec && details?.timedOut !== true) {
      exitCode = 0;
      exitCodeSource = 'sdk_terminal_success_contract';
    }
  }
  const output = boundedText(resultText(event.result));
  const input = boundedText(start?.text ?? null);
  const now = Date.now();
  const receipt = {
    kind: 'root_verification',
    source: 'omp_native_tool_result',
    task_directory: start?.task_directory ?? taskDirectory,
    root_session_id: start?.root_session_id ?? rootSessionId,
    at: new Date(now).toISOString(),
    at_ms: now,
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
  if (tool === 'bash') {
    receipt.command = input.text;
    receipt.command_truncated = input.truncated;
  } else {
    receipt.script = input.text;
    receipt.script_truncated = input.truncated;
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

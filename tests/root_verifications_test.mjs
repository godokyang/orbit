// Regression for ticket D-ROOT-VERIFICATIONS: Root execution receipts are
// built from the real OMP 18.3.4 tool_execution_start/tool_execution_end
// event shapes, stay durable across later assistant messages, and never mix
// another task's or member's facts.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { captureStart, buildReceipt, appendReceipt, readReceipts, VERIFY_FILENAME } from '../plugins/root-verifications.mjs';

const taskA = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-root-verify-a-'));
const taskB = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-root-verify-b-'));

// Successful terminal bash: SDK omits details.exitCode; the contract-derived
// 0 is marked with its source, never reported and never a blind fill.
const start = captureStart(
  { type: 'tool_execution_start', toolCallId: 'call-npm-test', toolName: 'bash', args: { command: 'npm test', cwd: '.' } },
  { sessionCwd: taskA });
assert.equal(start.executionCwd, taskA); // args.cwd resolved against the real session cwd
assert.equal(captureStart({ toolName: 'bash', args: { cwd: '~/' } }, { sessionCwd: taskA }).executionCwd, os.homedir());
start.artifact_root = taskA;
start.input_digest = 'sha-input-1';
start.task_directory = taskA;
start.root_session_id = 'root-A';
const receipt = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'call-npm-test', toolName: 'bash', isError: false,
    result: { content: [{ type: 'text', text: 'tests 8/8 pass' }], details: {} } },
  start,
  endBinding: { artifact_root: taskA, artifact_digest: 'sha-art-1', fingerprint_status: 'ok' } });
assert.equal(receipt.exit_code, 0);
assert.equal(receipt.exit_code_source, 'sdk_terminal_success_contract');
assert.equal(receipt.command, 'npm test');
assert.equal(receipt.input_digest, 'sha-input-1'); // pinned at tool start
assert.equal(receipt.artifact_digest, 'sha-art-1'); // captured at completion
assert.equal(receipt.is_error, false);
assert.equal(receipt.output_truncated, false);
const sdkTruncated = buildReceipt({ start, endBinding: null, event: { type: 'tool_execution_end',
  toolCallId: 'short-but-partial', toolName: 'bash', isError: false,
  result: { content: [{ type: 'text', text: 'only the tail' }], details: {
    meta: { truncation: { direction: 'tail', totalLines: 100, outputLines: 1 } } } } } });
assert.equal(sdkTruncated.output_truncated, true, 'SDK truncation remains explicit even below our own text cap');
assert.equal(receipt.task_directory, taskA);
assert.equal(receipt.root_session_id, 'root-A');
const rebound = buildReceipt({ event: { type: 'tool_execution_end', toolCallId: 'call-npm-test',
  toolName: 'bash', isError: false, result: { content: [], details: {} } }, start,
  endBinding: { artifact_root: taskB, artifact_digest: 'sha-art-2', fingerprint_status: 'ok' },
  taskDirectory: taskB, rootSessionId: 'root-B' });
assert.equal(rebound.task_directory, taskA);
assert.equal(rebound.root_session_id, 'root-A');
assert.equal(rebound.artifact_root, taskA);
assert.equal(rebound.artifact_root_at_completion, taskB);

// Reported failure keeps the real code; a missing end binding is an
// explicit gap, never a guessed identity.
const failed = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'c2', toolName: 'bash', isError: true,
    result: { content: [{ type: 'text', text: 'boom' }], details: { exitCode: 2 } } },
  start, endBinding: null });
assert.equal(failed.exit_code, 2);
assert.equal(failed.exit_code_source, 'reported');
assert.equal(failed.binding_status, 'unknown');
assert.equal(failed.artifact_digest, null);

// Background launch: the command's exit stays unknown (ok is launch-only).
const asyncReceipt = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'c3', toolName: 'bash', isError: false,
    result: { content: [], details: { async: { state: 'running', jobId: 'j1', type: 'bash' } } } },
  start: captureStart({ type: 'tool_execution_start', toolCallId: 'c3', toolName: 'bash', args: { command: 'npm run watch' } }, { sessionCwd: taskA }),
  endBinding: { artifact_digest: null, fingerprint_status: 'unknown' } });
assert.equal(asyncReceipt.async, true);
assert.equal(asyncReceipt.exit_code, null);
assert.equal(asyncReceipt.exit_code_source, 'unknown');

// eval keeps only the OUTER execution status; never a child-process exit 0.
const evalReceipt = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'c4', toolName: 'eval', isError: false,
    result: { content: [{ type: 'text', text: 'ok' }], details: {} } },
  start: captureStart({ type: 'tool_execution_start', toolCallId: 'c4', toolName: 'eval', args: { code: 'print(1)' } }, { sessionCwd: taskA }),
  endBinding: { artifact_digest: 'sha-art-1', fingerprint_status: 'ok' } });
assert.equal(evalReceipt.exit_code, null);
assert.equal(evalReceipt.exit_code_source, 'unknown');
assert.equal(evalReceipt.script, 'print(1)');

// Synthetic interrupt replay: the call never ran, so no receipt exists.
assert.equal(buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'c5', toolName: 'bash', isError: true,
    result: { content: [{ type: 'text', text: 'Skipped due to interrupt.' }],
      details: { source: 'interrupt_skipped', __synthetic: true, executed: false } } },
  start: null, endBinding: null }), null);

// Missed start event: the execution fact is kept, input identity is never
// guessed from nearby observations.
const interrupted = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'interrupted-call', toolName: 'bash', isError: true,
    result: { content: [], details: { source: 'interrupt_skipped', __interrupted: true, execution: 'started' } } },
  start, endBinding: null });
assert.equal(interrupted.status, 'interrupted');
assert.equal(interrupted.exit_code, null);

const noStart = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'c6', toolName: 'bash', isError: false,
    result: { content: [], details: {} } },
  start: null, endBinding: { artifact_digest: 'x', fingerprint_status: 'ok' } });
assert.equal(noStart.start_observed, false);
assert.equal(noStart.command, null);
assert.equal(noStart.input_digest, null);

// Receipts are durable across later assistant messages and isolated per
// task directory.
assert.equal(appendReceipt(taskA, receipt), null);
assert.equal(appendReceipt(taskA, failed), null);
const later = readReceipts(taskA);
assert.deepEqual(later.map(r => r.tool_call_id), ['call-npm-test', 'c2']);
assert.equal(later[0].output, 'tests 8/8 pass');
assert.equal(readReceipts(taskB).length, 0);
assert.equal(((await fs.stat(path.join(taskA, VERIFY_FILENAME))).mode & 0o777).toString(8), '600');

await fs.rm(taskA, { recursive: true, force: true });
await fs.rm(taskB, { recursive: true, force: true });
console.log('ROOT_VERIFICATIONS_TEST_PASS');

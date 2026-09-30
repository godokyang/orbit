import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { captureStart, buildReceipt, appendReceipt, readReceipts, VERIFY_FILENAME, CAPTURED_TOOLS } from '../plugins/root-verifications.mjs';

// History-gap ticket: Root FILE tool receipts (edit/write) plus the bounded
// check-history projection contract. bash/eval behaviour is unchanged.
const taskDir = await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-root-write-'));
const sessionCwd = '/private/tmp/orbit-history-gap-fixture';

assert.deepEqual(CAPTURED_TOOLS, ['bash', 'eval', 'edit', 'write']);

// 1) A write with a plain path records identity + bounded target only.
const writeStart = captureStart(
  { type: 'tool_execution_start', toolCallId: 'call-write-1', toolName: 'write', args: { path: 'src/parse.js', content: 'SECRET CONTENT' } },
  { sessionCwd });
assert.equal(writeStart.tool, 'write');
assert.deepEqual(writeStart.targets, ['src/parse.js']);
assert.equal(writeStart.targets_status, 'path');
assert.equal(writeStart.text, null); // content is never captured
writeStart.task_directory = taskDir;
writeStart.root_session_id = 'root-W';
const WRITE_RESULT_SENTINEL = 'SECRET-WRITE-RESULT-BODY';
const writeReceipt = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'call-write-1', toolName: 'write', isError: false,
    result: { content: [{ type: 'text', text: `wrote src/parse.js\n${WRITE_RESULT_SENTINEL}` }] } },
  start: writeStart, endBinding: { artifact_root: taskDir, artifact_digest: 'sha-art-w', fingerprint_status: 'ok' } });
assert.equal(writeReceipt.tool, 'write');
assert.equal(writeReceipt.status, 'completed');
assert.equal(writeReceipt.exit_code, null);
assert.equal(writeReceipt.exit_code_source, 'not_applicable');
assert.deepEqual(writeReceipt.targets, ['src/parse.js']);
assert.equal(writeReceipt.content_saved, false);
assert.equal(writeReceipt.diff_saved, false);
assert.equal(writeReceipt.effect, 'file_tool_call_observed_not_bytes_changed');
assert.equal(writeReceipt.output, null);            // the tool result body is not stored
assert.equal(writeReceipt.output_saved, false);
assert.equal(writeReceipt.output_truncated, false);
const writeSerialized = JSON.stringify(writeReceipt);
assert.equal(writeSerialized.includes('SECRET CONTENT'), false);            // request content
assert.equal(writeSerialized.includes(WRITE_RESULT_SENTINEL), false);       // result body
assert.equal(writeSerialized.includes('wrote src/parse.js'), false);

// The program's own local observation time of the REAL start event is kept,
// separately from the completion time, and is labelled as an observation.
assert.equal(writeStart.start_observed_at_source, 'program_local_event_observation');
assert.match(writeStart.start_observed_at, /^\d{4}-\d{2}-\d{2}T/);
assert.equal(writeReceipt.start_observed_at, writeStart.start_observed_at);
assert.ok(writeReceipt.at_ms >= writeReceipt.start_observed_at_ms,
  'the completion observation cannot precede the start observation');

// 2) A control URI (agent://, xd://) is an address, never a file change.
const peerStart = captureStart(
  { type: 'tool_execution_start', toolCallId: 'call-peer', toolName: 'write', args: { path: 'agent://peer-1', content: 'hi' } },
  { sessionCwd });
assert.equal(peerStart.targets_status, 'control_uri');
assert.equal(peerStart.targets, null);
assert.deepEqual(peerStart.control_targets, ['agent://peer-1']);
const xdStart = captureStart({ type: 'tool_execution_start', toolCallId: 'call-xd', toolName: 'write', args: { path: 'xd://orbit', content: '{}' } }, { sessionCwd });
assert.equal(xdStart.targets_status, 'control_uri');

// 3) The hashline {i, input} dialect is NOT hand-parsed: targets stay unknown.
const hashStart = captureStart(
  { type: 'tool_execution_start', toolCallId: 'call-hash', toolName: 'edit', args: { i: 'Editing parser', input: '[src/parse.js#AB12]\nPUT 3.=9:\n+line' } },
  { sessionCwd });
assert.equal(hashStart.targets, null);
assert.equal(hashStart.targets_status, 'unknown');
assert.equal(hashStart.text, null); // no diff/input captured
const EDIT_RESULT_SENTINEL = 'SECRET-EDIT-APPLIED-PATCH';
const hashReceipt = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'call-hash', toolName: 'edit', isError: false,
    result: { content: [{ type: 'text', text: `applied\n@@ -1 +1 @@\n-${EDIT_RESULT_SENTINEL}\n+ok` }] } },
  start: hashStart, endBinding: null });
assert.equal(hashReceipt.output, null);
assert.equal(JSON.stringify(hashReceipt).includes(EDIT_RESULT_SENTINEL), false);
assert.equal(JSON.stringify(hashReceipt).includes('@@ -1 +1 @@'), false);
assert.equal(hashReceipt.targets_status, 'unknown');
assert.equal(hashReceipt.binding_status, 'unknown'); // binding gap stays explicit

// 4) A path-dialect edit keeps its target and never stores the patch.
const editStart = captureStart(
  { type: 'tool_execution_start', toolCallId: 'call-edit', toolName: 'edit', args: { path: 'src/cli.js', old_string: 'a', new_string: 'b' } },
  { sessionCwd });
assert.deepEqual(editStart.targets, ['src/cli.js']);
assert.equal(editStart.text, null);

// 5) isError=false is an observed tool result, not proof that bytes changed.
const failedWrite = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'call-write-1', toolName: 'write', isError: true, result: { content: [{ type: 'text', text: 'denied' }] } },
  start: writeStart, endBinding: null });
assert.equal(failedWrite.status, 'failed');
assert.equal(failedWrite.effect, 'file_tool_call_observed_not_bytes_changed');

// 6) Receipts stay durable through append/re-read and keep the file class.
const write2 = { ...writeReceipt, tool_call_id: 'call-write-2' };
assert.equal(appendReceipt(taskDir, writeReceipt), null);
assert.equal(appendReceipt(taskDir, write2), null);
const reread = readReceipts(taskDir);
assert.equal(reread.length, 2);
assert.equal(reread[0].tool, 'write');
assert.equal(reread[1].content_saved, false);
const durable = await fs.readFile(path.join(taskDir, VERIFY_FILENAME), 'utf8');
assert.equal(durable.includes('SECRET CONTENT'), false);

// 6b) A receipt without an observed start keeps the start facts unknown and
// still never stores a file tool's result body.
const unobserved = buildReceipt({
  event: { type: 'tool_execution_end', toolCallId: 'call-never-started', toolName: 'write', isError: false,
    result: { content: [{ type: 'text', text: WRITE_RESULT_SENTINEL }] } },
  start: null, endBinding: null, taskDirectory: taskDir, rootSessionId: 'root-W' });
assert.equal(unobserved.start_observed, false);
assert.equal(unobserved.start_observed_at, null);
assert.equal(unobserved.start_observed_at_ms, null);
assert.equal(unobserved.start_observed_at_source, null);
assert.equal(unobserved.output, null);
assert.equal(JSON.stringify(unobserved).includes(WRITE_RESULT_SENTINEL), false);

// 7) bash stays exactly as before (no regression on the older contract).
const bashStart = captureStart({ type: 'tool_execution_start', toolCallId: 'call-npm', toolName: 'bash', args: { command: 'npm test' } }, { sessionCwd });
bashStart.task_directory = taskDir;
bashStart.root_session_id = 'root-W';
const bashReceipt = buildReceipt({ event: { type: 'tool_execution_end', toolCallId: 'call-npm', toolName: 'bash', isError: false, result: { content: [{ type: 'text', text: 'ok' }], details: {} } }, start: bashStart, endBinding: null });
assert.equal(bashReceipt.command, 'npm test');
assert.equal(bashReceipt.exit_code, 0);
assert.equal(bashReceipt.exit_code_source, 'sdk_terminal_success_contract');
assert.equal(bashReceipt.targets, undefined);
assert.equal(bashReceipt.output, 'ok'); // bash output is still recorded
assert.ok(bashReceipt.start_observed_at && !bashReceipt.start_observed);

await fs.rm(taskDir, { recursive: true, force: true });
console.log('ROOT_VERIFICATIONS_FILE_TOOLS_TEST_PASS');

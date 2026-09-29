// Invocation-boundary observations, kept separate from the immutable ledger.
// A pending SDK call can finish later; only finalized receipts enter accounting.
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mintCallId, pendingCallReceipt, modelCallReceipts, ledgerReceipt } from './model-call-receipts.mjs';

const writers = new Map();
const observed = new WeakMap();
const FORMAT = 'orbit-native-model-calls-v1';
const FILE = 'native-model-calls.json';
const GAP_FILE = 'native-model-call-gaps.jsonl';
const resourceBin = fileURLToPath(new URL('../scripts/orbit-route-resources', import.meta.url));

async function persistenceGap(taskDir, writer, error, callId) {
  const reason = `${callId ? `${callId}: ` : ''}native receipt persistence failed: ${error.message}`;
  if (writer.document) writer.document.gaps.push(reason);
  try {
    const file = await fs.open(path.join(taskDir, GAP_FILE), 'a', 0o600);
    try {
      await file.chmod(0o600);
      await file.writeFile(JSON.stringify({ at: new Date().toISOString(), reason }) + '\n');
      await file.sync();
    } finally { await file.close(); }
  } catch (gapError) {
    process.stderr.write(`Orbit native receipt gap persistence failed: ${gapError.message}\n`);
  }
  process.stderr.write(`Orbit ${reason}\n`);
}

// Finalized usage may arrive after the runtime has stopped. Record it from
// this actual SDK observer, without updating runtime-owned state.json. Pending
// observations stay mutable and can never conflict with the final receipt.
function recordFinalCall(taskDir, call) {
  return new Promise((resolve, reject) => {
    const child = execFile(process.env.ORBIT_RUBY || 'ruby', ['--disable-gems', resourceBin],
      { timeout: 15000, maxBuffer: 64 * 1024 }, (error, stdout) => {
        if (error) return reject(error);
        try {
          const result = JSON.parse(stdout);
          if (result.ok !== true) throw new Error(result.error || 'native call ledger refused the receipt');
          resolve();
        } catch (failure) { reject(failure); }
      });
    child.stdin.on('error', reject);
    child.stdin.end(JSON.stringify({ action: 'record_call', task_path: taskDir,
      project_root: call.meta.projectRoot, role: call.meta.role, receipt: call.ledger_receipt }));
  });
}

function publish(taskDir, call, gap) {
  if (!taskDir) return;
  let writer = writers.get(taskDir);
  if (!writer) { writer = { queue: Promise.resolve(), document: null }; writers.set(taskDir, writer); }
  writer.queue = writer.queue.then(async () => {
    if (!writer.document) {
      let document;
      try { document = JSON.parse(await fs.readFile(path.join(taskDir, FILE), 'utf8')); }
      catch (error) {
        if (error.code !== 'ENOENT') throw error;
        document = { schema_version: FORMAT, task_id: path.basename(taskDir), calls: {}, gaps: [] };
      }
      if (document.schema_version !== FORMAT || document.task_id !== path.basename(taskDir) ||
          !document.calls || !Array.isArray(document.gaps)) throw new Error('native call observations are corrupt or foreign');
      writer.document = document;
    }
    if (call) writer.document.calls[call.receipt.call_id] = call;
    if (gap && !writer.document.gaps.includes(gap)) writer.document.gaps.push(gap);
    const file = path.join(taskDir, FILE), temp = `${file}.${randomUUID()}.tmp`;
    try {
      const handle = await fs.open(temp, 'wx', 0o600);
      try { await handle.writeFile(JSON.stringify(writer.document) + '\n'); await handle.sync(); }
      finally { await handle.close(); }
      await fs.rename(temp, file);
      const directory = await fs.open(taskDir, 'r');
      try { await directory.sync(); } finally { await directory.close(); }
    } finally { await fs.rm(temp, { force: true }); }
  }).catch(error => persistenceGap(taskDir, writer, error, call?.receipt.call_id))
    .then(() => call?.finalized ? recordFinalCall(taskDir, call) : undefined)
    .catch(error => persistenceGap(taskDir, writer, error, call?.receipt.call_id));
}

export function observeNativeCalls(session, context) {
  if (observed.has(session)) return;
  let pending = null;
  const unsubscribe = session.subscribe(event => {
    if (event.message?.role !== 'assistant') return;
    if (event.type === 'message_start') {
      const contextAtBoundary = context();
      const meta = contextAtBoundary ? { ...contextAtBoundary, sessionId: session.sessionId } : null;
      const callId = mintCallId();
      if (pending?.meta?.taskDir) publish(pending.meta.taskDir, pending,
        `${pending.receipt.call_id}: another boundary started before its final response was observed`);
      pending = { meta, started_at: new Date().toISOString(), finalized: false,
        receipt: pendingCallReceipt({ call_id: callId, message: event.message,
          requested_model: meta?.requestedModel, session_model: meta?.actualModel }) };
      if (meta?.taskDir) publish(meta.taskDir, pending);
    } else if (event.type === 'message_end') {
      const currentMeta = context();
      if (!pending || !pending.meta?.taskDir) {
        if (currentMeta?.taskDir) publish(currentMeta.taskDir, null,
          'an assistant result had no task-associated invocation boundary; its usage is not added to this task');
        pending = null; return;
      }
      const call = pending;
      pending = null;
      const result = modelCallReceipts([{ call_id: call.receipt.call_id, message: event.message }], call.meta.requestedModel);
      const receipt = result.calls[0];
      // Session configuration is only the executed OMP identity fallback. It
      // never fills the upstream supplier's unreported identity.
      receipt.provider ||= call.meta.actualProvider;
      receipt.model ||= call.meta.actualModelId;
      const sameModel = receipt.model === call.meta.actualModel ||
        `${receipt.provider}/${receipt.model}` === call.meta.actualModel;
      const row = ledgerReceipt(receipt, { role: call.meta.role, phase: `${call.meta.role}_execution`,
        session_id: session.sessionId, agent_id: call.meta.role === 'member' ? call.meta.agentId : undefined,
        work_unit_id: call.meta.workUnitId, route: sameModel ? call.meta.billingRoute : 'unknown' });
      row.started_at = call.started_at;
      row.completed_at = new Date().toISOString();
      publish(call.meta.taskDir, { ...call, receipt, finalized: true, ledger_receipt: row },
        result.gaps.length ? result.gaps.join('; ') : null);
    }
  });
  observed.set(session, unsubscribe);
}

export async function flushNativeCalls(taskDir) {
  if (taskDir) await writers.get(taskDir)?.queue;
  else await Promise.all([...writers.values()].map(writer => writer.queue));
}

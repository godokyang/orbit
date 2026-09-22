#!/usr/bin/env node
'use strict';

// The host launches MCP tools outside the model's command sandbox. This thin
// adapter exposes only Orbit operations; model execution keeps its own policy.
const { Server } = require('@modelcontextprotocol/sdk/server/index.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { CallToolRequestSchema, ListToolsRequestSchema } = require('@modelcontextprotocol/sdk/types.js');
const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const { version } = require('../package.json');

const server = new Server({ name: 'orbit', version }, { capabilities: { tools: {} } });
const actions = ['context', 'start', 'status', 'check', 'amend', 'dispute', 'stop', 'delegate', 'rebind_workspace', 'model_evidence'];
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [{
  name: 'task',
  description: 'Independent execution checks for your current coding session. Use the Orbit skill for appropriate tasks. context checks attachment; start binds the current session and original user message; task actions inspect or control an existing task. No Root is created or replaced.',
  inputSchema: { type: 'object', additionalProperties: false,
    properties: {
      action: { type: 'string', enum: actions },
      thread_id: { type: 'string', description: 'Current CODEX_THREAD_ID, if not provided by host metadata.' },
      project: { type: 'string', description: 'Absolute project directory for start.' },
      message_id: { type: 'string', description: 'Original native user message; omit to use the latest.' },
      review_model: { type: 'string', description: 'Already authorized Codex review model.' },
      model: { type: 'string', description: 'Already authorized execution member model; otherwise use the configured review model.' },
      member: { type: 'string', description: 'Owned member thread ID to reuse for a delegated follow-up.' },
      kind: { type: 'string', enum: ['native', 'codex'], description: 'Execution member kind: native (same host as Root) or codex (task-owned Codex app-server; OpenCode Root path).' },
      basis: { type: 'array', items: { type: 'string' } },
      task: { type: 'string', description: 'task_directory returned by start.' },
      text: { type: 'string', description: 'Delegated scope, user amendment, dispute evidence, stop reason, or rebind reason.' },
      path: { type: 'string', description: 'Artifact workspace directory for rebind_workspace; must be a non-empty path.' },
      evidence: { type: ['object', 'array'], items: { type: 'object' }, description: 'Model evidence JSON for model_evidence: one entry object or an array of entry objects (identity, status, sources, metrics). Never web page text.' },
      check_in: { type: 'integer', minimum: 1 }
    }, required: ['action'] }
}] }));

function isEvidence(value) {
  if (Array.isArray(value)) return value.every(item => item && typeof item === 'object' && !Array.isArray(item));
  return Boolean(value) && typeof value === 'object';
}

function run(args, env, input) {
  return new Promise((resolve, reject) => {
    const child = spawn('ruby', ['--disable-gems', path.join(__dirname, 'orbit'), ...args],
      { env, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.once('error', reject);
    child.once('close', code => resolve({ code, stdout, stderr }));
    child.stdin.on('error', () => {});
    child.stdin.end(input || '');
  });
}

server.setRequestHandler(CallToolRequestSchema, async request => {
  if (request.params.name !== 'task') throw new Error('Unknown Orbit tool');
  const a = request.params.arguments || {};
  if (!actions.includes(a.action)) throw new Error('Unsupported Orbit action');
  const metadata = request.params._meta || {};
  // Codex sends the session id as plain `threadId` (mcp_tool_call.rs,
  // MCP_TOOL_THREAD_ID_META_KEY); older transports used codex/-prefixed keys.
  const hostThread = metadata['codex/thread-id'] || metadata['codex/threadId'] || metadata.threadId;
  const thread = hostThread || a.thread_id || process.env.CODEX_THREAD_ID;
  const env = { ...process.env };
  if (thread) env.CODEX_THREAD_ID = thread;
  const args = [{ context: 'doctor', rebind_workspace: 'rebind-workspace', model_evidence: 'model-evidence' }[a.action] || a.action];
  if (['context', 'status', 'stop'].includes(a.action)) args.push('--json');
  let input;
  if (a.action === 'start') {
    if (!thread) throw new Error('Provide your current CODEX_THREAD_ID as thread_id.');
    if (!a.project) throw new Error('start requires the absolute project directory.');
    args.push('--project', a.project);
    if (a.message_id) args.push('--message-id', a.message_id);
    if (a.review_model) args.push('--review-model', a.review_model);
    for (const file of a.basis || []) args.push('--basis', file);
    if (a.check_in) args.push('--check-in', String(a.check_in));
  } else if (a.action !== 'context') {
    if (!a.task) throw new Error('This operation requires task_directory from start.');
    const state = JSON.parse(fs.readFileSync(path.join(a.task, 'state.json'), 'utf8'));
    if (!thread || state.connection.thread_id !== thread ||
        state.connection.socket !== process.env.ORBIT_CODEX_SOCKET) {
      throw new Error('This task does not belong to the calling Root on this Orbit host.');
    }
    args.push(a.task);
    if (a.action === 'amend' || a.action === 'delegate') {
      if (typeof a.text !== 'string' || !a.text.trim()) throw new Error('Provide the original user amendment or delegated scope.');
      args.push('--file', '-');
      input = a.text;
      if (a.action === 'delegate' && a.kind) args.push('--kind', a.kind);
      if (a.action === 'delegate' && a.model) args.push('--model', a.model);
      if (a.action === 'delegate' && a.member) args.push('--member', a.member);
    } else if (a.action === 'rebind_workspace') {
      const workspace = typeof a.path === 'string' ? a.path.trim() : '';
      if (!workspace) throw new Error('rebind_workspace requires a non-empty workspace path.');
      args.push(workspace);
      const reason = typeof a.text === 'string' ? a.text.trim() : '';
      if (reason) args.push('--reason', reason);
    } else if (a.action === 'model_evidence') {
      if (!isEvidence(a.evidence)) throw new Error('model_evidence requires evidence as a JSON object or array of objects.');
      args.push('--file', '-');
      input = JSON.stringify(a.evidence);
    } else if (a.text) {
      args.push('--reason', a.text);
    }
  }
  const result = await run(args, env, input);
  return { isError: result.code !== 0,
    content: [{ type: 'text', text: result.stdout + result.stderr || `Orbit exited ${result.code}` }] };
});

server.connect(new StdioServerTransport()).catch(error => {
  process.stderr.write(`Orbit MCP: ${error.message}\n`);
  process.exitCode = 1;
});

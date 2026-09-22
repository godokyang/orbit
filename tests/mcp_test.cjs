'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StdioClientTransport } = require('@modelcontextprotocol/sdk/client/stdio.js');

const MCP_SCRIPT = path.resolve(__dirname, '../scripts/orbit-mcp.cjs');
const ORBIT_SCRIPT = path.resolve(__dirname, '../scripts/orbit');

function git(dir, ...args) {
  execFileSync('git', ['-C', dir, ...args], { stdio: 'ignore' });
}

// Test-only `ruby` replacement on PATH. It records the exact argv and stdin
// and reports a queued command, locking the MCP parameter mapping even if the
// Ruby backend changes.
function stubRuby() {
  const js = [
    'const fs = require("fs");',
    'const record = { argv: process.argv.slice(1), stdin: fs.readFileSync(0, "utf8") };',
    'fs.writeFileSync(process.env.STUB_RECORD, JSON.stringify(record));',
    'process.stdout.write(JSON.stringify({ task_directory: process.env.STUB_TASK, command_id: "stub", status: "queued" }) + "\\n");'
  ].join(' ');
  return `#!/bin/sh\nexec "${process.execPath}" -e '${js}' -- "$@"\n`;
}

(async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'orbit-mcp-test-'));
  try {
    const project = path.join(root, 'project');
    const worktree = path.join(root, 'artifact');
    fs.mkdirSync(project);
    git(project, 'init', '-q');
    git(project, '-c', 'user.name=orbit-test', '-c', 'user.email=orbit-test@example.com',
        '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'init');
    git(project, 'worktree', 'add', '--detach', '-q', worktree);

    const socket = path.join(root, 'host.sock');
    const cacheHome = path.join(root, 'cache');
    const task = path.join(project, '.orbit', 'tasks', 'mcp-test-task');
    fs.mkdirSync(task, { recursive: true });
    fs.writeFileSync(path.join(task, 'state.json'), JSON.stringify({
      format: 'orbit-task-1', id: 'mcp-test-task', status: 'running', project_root: project,
      connection: { thread_id: 'own-root', socket }
    }));
    const inboxDir = path.join(task, 'inbox');
    const inboxFiles = () => (fs.existsSync(inboxDir) ? fs.readdirSync(inboxDir).sort() : []);
    const inboxCommands = () => inboxFiles().map(name => JSON.parse(fs.readFileSync(path.join(inboxDir, name), 'utf8')));
    const call = (client, args, meta = { 'codex/thread-id': 'own-root' }) =>
      client.callTool({ name: 'task', arguments: args, _meta: meta });

    const client = new Client({ name: 'orbit-test', version: '1' });
    const transport = new StdioClientTransport({
      command: process.execPath, args: [MCP_SCRIPT],
      env: { ...process.env, ORBIT_CODEX_SOCKET: socket, XDG_CACHE_HOME: cacheHome }, stderr: 'inherit'
    });
    try {
      await client.connect(transport);
      const [tool] = (await client.listTools()).tools;
      assert.deepEqual([tool.name], ['task']);
      assert(tool.inputSchema.properties.action.enum.includes('rebind_workspace'), 'rebind_workspace is in the action enum');
      assert(tool.inputSchema.properties.action.enum.includes('model_evidence'), 'model_evidence is in the action enum');
      assert.deepEqual(tool.inputSchema.properties.evidence.type, ['object', 'array'], 'evidence accepts a JSON object or array');

      // Host identity wins over an argument claiming ownership of another task.
      await assert.rejects(call(client, { action: 'stop', task, thread_id: 'own-root' },
        { 'codex/thread-id': 'different-root' }), /does not belong/);
      await assert.rejects(call(client, { action: 'rebind_workspace', task, path: worktree },
        { 'codex/thread-id': 'different-root' }), /does not belong/);
      await assert.rejects(call(client, { action: 'model_evidence', task, evidence: { status: 'unavailable', reason: 'x' } },
        { 'codex/thread-id': 'different-root' }), /does not belong/);
      assert.equal(fs.existsSync(inboxDir), false, 'rejected ownership queues nothing');

      // Per-action required parameters are checked before any CLI call.
      await assert.rejects(call(client, { action: 'rebind_workspace', task }), /non-empty workspace path/);
      await assert.rejects(call(client, { action: 'rebind_workspace', task, path: '   ' }), /non-empty workspace path/);
      await assert.rejects(call(client, { action: 'model_evidence', task }), /evidence as a JSON object/);
      await assert.rejects(call(client, { action: 'model_evidence', task, evidence: 'https://example.com/full-page-text' }),
        /evidence as a JSON object/);
      assert.equal(fs.existsSync(inboxDir), false, 'missing parameters queue nothing');

      // Current Codex sends the native identity as plain `threadId`; the
      // legacy prefixed key must keep working for other clients.
      const result = await call(client, { action: 'check', task }, { threadId: 'own-root' });
      assert.equal(JSON.parse(result.content[0].text).status, 'queued');
      assert.equal(inboxCommands().length, 1);
      assert.equal(inboxCommands()[0].type, 'check');
      for (const action of ['status', 'stop']) {
        const reply = await call(client, { action, task });
        assert.equal(reply.isError, false);
        assert.equal(JSON.parse(reply.content[0].text).status, action === 'status' ? 'running' : 'queued');
      }

      // rebind_workspace maps to the dedicated CLI command; the queued command
      // carries the canonical same-repository worktree, its reason and source.
      const beforeRebind = inboxCommands().length;
      const rebind = await call(client, { action: 'rebind_workspace', task, path: worktree, text: 'move checks to the artifact worktree' });
      assert.equal(rebind.isError, false);
      const rebindReply = JSON.parse(rebind.content[0].text);
      assert.equal(rebindReply.status, 'queued');
      const reboundFiles = inboxFiles();
      assert.equal(reboundFiles.length, beforeRebind + 1);
      assert.equal(reboundFiles.at(-1), `${rebindReply.command_id}.json`);
      const rebound = inboxCommands().at(-1);
      assert.equal(rebound.type, 'rebind_workspace');
      assert.equal(rebound.path, fs.realpathSync(worktree));
      assert.equal(rebound.reason, 'move checks to the artifact worktree');
      assert.deepEqual(rebound.source, { kind: 'cli', command: 'rebind-workspace' });

      // A path argument must not leak into amend or dispute; both still carry text only.
      const amend = await call(client, { action: 'amend', task, text: 'keep the current workspace', path: worktree });
      assert.equal(amend.isError, false);
      const amended = inboxCommands().at(-1);
      assert.equal(amended.type, 'amend');
      assert.equal(amended.text, 'keep the current workspace');
      assert.equal('path' in amended, false, 'amend must not carry a workspace path');
      const dispute = await call(client, { action: 'dispute', task, text: 'the workspace claim is wrong', path: worktree });
      assert.equal(dispute.isError, false);
      const disputed = inboxCommands().at(-1);
      assert.equal(disputed.type, 'dispute');
      assert.equal(disputed.reason, 'the workspace claim is wrong');
      assert.equal('path' in disputed, false, 'dispute must not carry a workspace path');

      // model_evidence maps to the dedicated Ruby CLI command, which
      // validates and writes the user-level cache and queues identity and
      // status only; the runtime re-reads the cache instead of the body.
      const beforeEvidence = inboxCommands().length;
      const evidence = { provider: 'opencode-go', model: 'deepseek-v4.1-flash', reasoning: 'default',
        status: 'evidence', retrieved_at: new Date(Date.now() - 60_000).toISOString(),
        sources: ['https://artificialanalysis.ai/models'],
        metrics: { output_tokens_per_second: { value: 120.5, unit: 'tokens/s', basis: 'Artificial Analysis median' } } };
      const evidenceReply = await call(client, { action: 'model_evidence', task, evidence });
      assert.equal(evidenceReply.isError, false, evidenceReply.content[0].text);
      const evidenceResult = JSON.parse(evidenceReply.content[0].text);
      assert.equal(evidenceResult.status, 'queued');
      assert.equal(evidenceResult.count, 1);
      assert.deepEqual(evidenceResult.identities,
        [{ provider: 'opencode-go', model: 'deepseek-v4.1-flash', reasoning: 'default' }]);
      assert.equal(inboxCommands().length, beforeEvidence + 1);
      const submitted = inboxCommands().at(-1);
      assert.equal(submitted.type, 'model_evidence');
      assert.deepEqual(submitted.source, { kind: 'cli', command: 'model-evidence' });
      assert.deepEqual(submitted.entries,
        [{ provider: 'opencode-go', model: 'deepseek-v4.1-flash', reasoning: 'default', status: 'evidence' }]);
      assert.equal('metrics' in submitted, false, 'the queued command never copies metrics');
      assert.equal('sources' in submitted, false, 'the queued command never copies sources');
      const cache = JSON.parse(fs.readFileSync(path.join(cacheHome, 'orbit', 'model-evidence-v1.json'), 'utf8'));
      assert.equal(cache.entries.length, 1);
      assert.equal(cache.entries[0].metrics.output_tokens_per_second.value, 120.5, 'validated evidence is cached');
    } finally {
      await client.close();
    }

    // A stub ruby on PATH proves the exact mapping: dedicated command,
    // `--file -`, and the submitted evidence as verbatim stdin JSON.
    const stubBin = path.join(root, 'stub-bin');
    fs.mkdirSync(stubBin);
    const recordPath = path.join(root, 'stub-record.json');
    fs.writeFileSync(path.join(stubBin, 'ruby'), stubRuby());
    fs.chmodSync(path.join(stubBin, 'ruby'), 0o755);
    const stubClient = new Client({ name: 'orbit-test-stub', version: '1' });
    const stubTransport = new StdioClientTransport({
      command: process.execPath, args: [MCP_SCRIPT],
      env: { ...process.env, ORBIT_CODEX_SOCKET: socket, PATH: `${stubBin}${path.delimiter}${process.env.PATH}`,
        STUB_RECORD: recordPath, STUB_TASK: task },
      stderr: 'inherit'
    });
    try {
      await stubClient.connect(stubTransport);
      const evidence = { provider: 'opencode-go', model: 'deepseek-v4.1-flash', reasoning: 'default', status: 'evidence',
        retrieved_at: '2026-09-22T09:00:00Z', sources: ['https://artificialanalysis.ai/models'],
        metrics: { output_tokens_per_second: { value: 120.5, unit: 'tokens/s', basis: 'Artificial Analysis median' } } };
      const reply = await call(stubClient, { action: 'model_evidence', task, evidence });
      assert.equal(reply.isError, false);
      const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
      assert.deepEqual(record.argv, ['--disable-gems', ORBIT_SCRIPT, 'model-evidence', task, '--file', '-']);
      assert.equal(record.stdin, JSON.stringify(evidence), 'evidence reaches the control command verbatim');
      assert.equal(record.argv.includes('amend'), false, 'model_evidence never reuses amend');
      assert.equal(record.argv.includes('--reason'), false, 'evidence is not mixed into text');
    } finally {
      await stubClient.close();
    }

    console.log('MCP_TEST_PASS task ownership, rebind workspace and model evidence mapping');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StdioClientTransport } = require('@modelcontextprotocol/sdk/client/stdio.js');

(async () => {
  const task = fs.mkdtempSync(path.join(os.tmpdir(), 'orbit-mcp-test-'));
  const socket = path.join(task, 'host.sock');
  fs.writeFileSync(path.join(task, 'state.json'), JSON.stringify({
    status: 'running', connection: { thread_id: 'own-root', socket }
  }));
  const client = new Client({ name: 'orbit-test', version: '1' });
  const transport = new StdioClientTransport({
    command: process.execPath, args: [path.resolve(__dirname, '../scripts/orbit-mcp.cjs')],
    env: { ...process.env, ORBIT_CODEX_SOCKET: socket }, stderr: 'inherit'
  });
  try {
    await client.connect(transport);
    // Host identity wins over an argument claiming ownership of another task.
    await assert.rejects(client.callTool({ name: 'orbit',
      arguments: { action: 'stop', task, thread_id: 'own-root' },
      _meta: { 'codex/thread-id': 'different-root' }
    }), /does not belong/);
    assert.equal(fs.existsSync(path.join(task, 'inbox')), false);
    const result = await client.callTool({ name: 'orbit',
      arguments: { action: 'check', task }, _meta: { 'codex/thread-id': 'own-root' }
    });
    assert.equal(JSON.parse(result.content[0].text).status, 'queued');
    const commands = fs.readdirSync(path.join(task, 'inbox'));
    assert.equal(commands.length, 1);
    assert.equal(JSON.parse(fs.readFileSync(path.join(task, 'inbox', commands[0]))).type, 'check');
    console.log('MCP_TEST_PASS task ownership and real CLI delivery');
  } finally {
    await client.close();
    fs.rmSync(task, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

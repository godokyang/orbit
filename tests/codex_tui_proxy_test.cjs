'use strict';

// The TUI proxy must rewrite only the permission fields of user-thread
// lifecycle requests, leave system/ephemeral threads and all other traffic
// untouched, and close the TUI connection plus remove its socket when the
// app-server goes away or the proxy exits.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const WebSocket = require('ws');
const { WebSocketServer } = WebSocket;

const policy = { approvalPolicy: 'never', sandbox: 'danger-full-access' };

function connect(socketPath) {
  return new WebSocket('ws://localhost/', {
    createConnection: () => net.createConnection({ path: socketPath }),
    handshakeTimeout: 5000,
    perMessageDeflate: false
  });
}

function nextMessage(ws) {
  return new Promise((resolve, reject) => {
    ws.once('message', data => resolve(JSON.parse(data.toString())));
    ws.once('error', reject);
  });
}

function waitFor(predicate, timeout = 5000) {
  const deadline = Date.now() + timeout;
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (predicate()) return resolve();
      if (Date.now() > deadline) return reject(new Error('timeout'));
      setTimeout(poll, 20);
    };
    poll();
  });
}

(async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'orbit-tui-proxy-test-'));
  const controlSocket = path.join(directory, 'control.sock');
  const tuiSocket = path.join(directory, 'tui.sock');
  const received = [];
  const upstreamClients = [];
  const upstreamServer = http.createServer();
  const upstream = new WebSocketServer({ server: upstreamServer });
  upstream.on('connection', client => {
    upstreamClients.push(client);
    client.on('message', data => received.push(JSON.parse(data.toString())));
  });
  await new Promise(resolve => upstreamServer.listen(controlSocket, resolve));

  const proxy = spawn(process.execPath, [path.resolve(__dirname, '../scripts/codex-tui-proxy.cjs'),
    tuiSocket, controlSocket, JSON.stringify(policy)], { stdio: ['ignore', 'ignore', 'inherit'] });
  let client;
  try {
    await waitFor(() => fs.existsSync(tuiSocket));
    client = connect(tuiSocket);
    await new Promise((resolve, reject) => { client.once('open', resolve); client.once('error', reject); });

    const send = async request => {
      client.send(JSON.stringify(request));
      await waitFor(() => received.some(entry => entry.id === request.id));
      return received.find(entry => entry.id === request.id);
    };

    const userStart = await send({ id: 1, method: 'thread/start',
      params: { threadSource: 'user', ephemeral: false, approvalPolicy: 'on-request', sandbox: 'workspace-write' } });
    assert.deepEqual([userStart.params.approvalPolicy, userStart.params.sandbox], ['never', 'danger-full-access'],
      'a user thread/start receives the launch policy');

    const internalStart = await send({ id: 2, method: 'thread/start',
      params: { threadSource: 'system', ephemeral: true, approvalPolicy: 'on-request', sandbox: 'read-only' } });
    assert.deepEqual([internalStart.params.approvalPolicy, internalStart.params.sandbox], ['on-request', 'read-only'],
      'a system ephemeral thread keeps its own permissions');

    const internalFork = await send({ id: 3, method: 'thread/fork',
      params: { threadSource: 'system', ephemeral: true, approvalPolicy: 'on-request', sandbox: 'read-only' } });
    assert.deepEqual([internalFork.params.approvalPolicy, internalFork.params.sandbox], ['on-request', 'read-only'],
      'a system ephemeral fork keeps its own permissions');

    const userFork = await send({ id: 4, method: 'thread/fork',
      params: { threadSource: 'user', ephemeral: false, approvalPolicy: 'on-request', sandbox: 'workspace-write' } });
    assert.deepEqual([userFork.params.approvalPolicy, userFork.params.sandbox], ['never', 'danger-full-access'],
      'a user fork receives the launch policy');

    const resume = await send({ id: 5, method: 'thread/resume', params: { threadId: 'abc' } });
    assert.deepEqual([resume.params.approvalPolicy, resume.params.sandbox], ['never', 'danger-full-access'],
      'a resume on the TUI socket receives the launch policy');

    const turn = await send({ id: 6, method: 'turn/start', params: { threadId: 'abc', sandbox: 'read-only' } });
    assert.equal(turn.params.sandbox, 'read-only', 'other requests are forwarded unchanged');

    client.send(JSON.stringify({ method: 'thread/started', params: { threadId: 'abc' } }));
    await waitFor(() => received.some(entry => entry.method === 'thread/started'));
    assert.ok(received.some(entry => entry.method === 'thread/started'), 'client notifications pass through');

    const downstream = { method: 'thread/settings/updated', params: { threadId: 'abc' } };
    const incoming = nextMessage(client);
    for (const upstreamClient of upstreamClients) upstreamClient.send(JSON.stringify(downstream));
    assert.deepEqual(await incoming, downstream, 'server notifications pass through unchanged');

    for (const upstreamClient of upstreamClients) upstreamClient.terminate();
    await waitFor(() => client.readyState !== WebSocket.OPEN, 3000);
    assert.notEqual(client.readyState, WebSocket.OPEN, 'the TUI connection closes when the app-server goes away');

    console.log('PROXY_TEST_PASS lifecycle rewrite and transparent forwarding');
  } finally {
    client?.terminate();
    for (const upstreamClient of upstreamClients) upstreamClient.terminate();
    proxy.kill('SIGTERM');
    await new Promise(resolve => proxy.once('exit', resolve));
    await waitFor(() => !fs.existsSync(tuiSocket), 2000).catch(() => {});
    assert.equal(fs.existsSync(tuiSocket), false, 'the proxy removes its own socket on exit');
    upstream.close();
    upstreamServer.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });

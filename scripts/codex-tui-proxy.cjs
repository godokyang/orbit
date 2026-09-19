#!/usr/bin/env node
'use strict';

// Transparent WebSocket proxy between the Codex TUI and the app-server that
// the `orbit codex` entry owns. The TUI connects to tui.sock; the proxy
// connects to control.sock, which stays the direct endpoint for every Orbit
// control connection (MCP, members, checks, stop). Only the permission fields
// of user-thread lifecycle requests are rewritten on the way in:
//   - thread/start, thread/fork: only threadSource "user" and not ephemeral;
//   - thread/resume: always, because only the TUI reaches this socket.
// Every other message, in both directions, is forwarded unchanged.
//
// usage: codex-tui-proxy.cjs <tui-socket> <control-socket> <policy-json>

const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const WebSocket = require('ws');
const { WebSocketServer } = WebSocket;

const [tuiSocket, controlSocket, policyJson] = process.argv.slice(2);
if (!tuiSocket || !controlSocket || !policyJson) {
  process.stderr.write('usage: codex-tui-proxy.cjs <tui-socket> <control-socket> <policy-json>\n');
  process.exit(1);
}

let policy;
try {
  policy = JSON.parse(policyJson);
} catch (error) {
  process.stderr.write(`invalid policy JSON: ${error.message}\n`);
  process.exit(1);
}
if (!policy || typeof policy !== 'object' || Array.isArray(policy)) {
  process.stderr.write('policy must be a JSON object of lifecycle permission fields\n');
  process.exit(1);
}

const LIFECYCLE_METHODS = new Set(['thread/start', 'thread/fork', 'thread/resume']);

// Returns the message to forward, possibly rewritten. Non-requests, malformed
// frames and every method other than the user-thread lifecycle boundary are
// returned byte-for-byte.
function rewrite(message) {
  let request;
  try {
    request = JSON.parse(message);
  } catch {
    return message;
  }
  if (!request || typeof request !== 'object' || Array.isArray(request)) return message;
  if (!LIFECYCLE_METHODS.has(request.method) || !('id' in request)) return message;
  const params = request.params;
  if (!params || typeof params !== 'object' || Array.isArray(params)) return message;
  if (request.method !== 'thread/resume') {
    if (params.threadSource !== 'user' || params.ephemeral === true) return message;
  }

  let changed = false;
  for (const [key, value] of Object.entries(policy)) {
    if (params[key] !== value) {
      params[key] = value;
      changed = true;
    }
  }
  return changed ? JSON.stringify(request) : message;
}

if (fs.existsSync(tuiSocket)) fs.unlinkSync(tuiSocket);

const server = http.createServer((request, response) => {
  response.writeHead(426, { 'content-type': 'text/plain' });
  response.end('WebSocket only\n');
});
const wss = new WebSocketServer({ server });

wss.on('error', (error) => {
  process.stderr.write(`proxy server error: ${error.message}\n`);
  process.exitCode = 1;
});

wss.on('connection', (client) => {
  const upstream = new WebSocket('ws://localhost/', {
    createConnection: () => net.createConnection({ path: controlSocket }),
    handshakeTimeout: 10000,
    perMessageDeflate: false,
    closeTimeout: 1000
  });
  const pending = [];

  client.on('message', (data, isBinary) => {
    const payload = isBinary ? data : rewrite(data.toString());
    if (upstream.readyState === WebSocket.OPEN) upstream.send(payload, { binary: isBinary });
    else pending.push([payload, isBinary]);
  });
  upstream.on('open', () => {
    for (const [payload, isBinary] of pending.splice(0)) upstream.send(payload, { binary: isBinary });
  });
  upstream.on('message', (data, isBinary) => {
    if (client.readyState === WebSocket.OPEN) client.send(data, { binary: isBinary });
  });
  upstream.on('close', () => {
    try { client.close(); } catch { /* already closed */ }
  });
  upstream.on('error', () => {
    try { client.terminate(); } catch { /* already closed */ }
  });
  client.on('close', () => {
    try { upstream.close(); } catch { /* already closed */ }
  });
  client.on('error', () => {
    try { upstream.terminate(); } catch { /* already closed */ }
  });
});

server.listen(tuiSocket, () => {
  process.stdout.write('ready\n');
});
server.on('error', (error) => {
  process.stderr.write(`proxy listen error: ${error.message}\n`);
  process.exit(1);
});

function shutdown() {
  for (const client of wss.clients) client.terminate();
  server.close();
  try {
    fs.unlinkSync(tuiSocket);
  } catch {
    /* already removed */
  }
  process.exit(0);
}

for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, shutdown);

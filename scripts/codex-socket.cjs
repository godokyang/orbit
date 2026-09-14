#!/usr/bin/env node
'use strict';

// Codex's Unix endpoint is WebSocket, not newline JSON. Keep framing in ws;
// the Ruby task process only sees native JSON-RPC messages on its own pipes.
const net = require('node:net');
const readline = require('node:readline');
const WebSocket = require('ws');

const socketPath = process.argv[2];
if (!socketPath) {
  process.stderr.write('Codex Unix socket path is required\n');
  process.exit(1);
}
const ws = new WebSocket('ws://localhost/', {
  createConnection: () => net.createConnection({ path: socketPath }),
  handshakeTimeout: 10000,
  perMessageDeflate: false,
  closeTimeout: 1000
});
const lines = readline.createInterface({ input: process.stdin });
let opened = false;
let pending = [];
let closing = false;

lines.on('line', (line) => {
  if (!line.trim()) return;
  if (opened) ws.send(line);
  else pending.push(line);
});
ws.on('open', () => {
  opened = true;
  for (const line of pending) ws.send(line);
  pending = [];
  if (closing) ws.close();
});
ws.on('message', (data) => process.stdout.write(data.toString() + '\n'));
ws.on('error', (error) => {
  process.stderr.write(`Codex connection: ${error.message}\n`);
  process.exitCode = 1;
});
ws.on('close', () => {
  lines.close();
  process.stdin.destroy();
});
lines.on('close', () => {
  closing = true;
  if (opened) ws.close();
});
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    lines.close();
    ws.terminate();
  });
}

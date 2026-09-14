#!/usr/bin/env node
'use strict';

// Test-only fake Codex app-server for tests/codex_connection_test.rb.
//
// argv[2]: Unix socket path. Binds a REAL WebSocket server (the `ws`
// dependency) on that Unix socket, so the Ruby tests exercise the same
// transport as a real `codex app-server --listen unix://…`: HTTP upgrade
// handshake plus RFC 6455 text frames, one JSON-RPC message per frame.
//
// Wire behavior for the Ruby harness (single connection):
//   - writes "READY\n" to stderr once the socket is listening
//   - every client text frame is forwarded as one stdout line
//   - every stdin line is sent to the client as one text frame
//   - stdin EOF closes the server and exits 0
const http = require('node:http');
const fs = require('node:fs');
const { WebSocketServer } = require('ws');

const socketPath = process.argv[2];
if (!socketPath) {
  process.stderr.write('Unix socket path is required\n');
  process.exit(1);
}
try { fs.unlinkSync(socketPath); } catch {}

const server = http.createServer((_req, res) => {
  res.destroy();
});
const wss = new WebSocketServer({ server });

let ws = null;
wss.on('connection', (socket) => {
  ws = socket;
  socket.on('message', (data) => {
    process.stdout.write(`${data.toString()}\n`);
  });
});

let buffer = '';
process.stdin.on('data', (chunk) => {
  buffer += chunk.toString();
  let newline = buffer.indexOf('\n');
  while (newline >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (line.trim() && ws && ws.readyState === ws.OPEN) ws.send(line);
    newline = buffer.indexOf('\n');
  }
});
process.stdin.on('end', () => {
  if (ws && ws.readyState === ws.OPEN) ws.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500).unref();
});

server.on('error', (error) => {
  process.stderr.write(`fake server: ${error.message}\n`);
  process.exit(1);
});
server.listen(socketPath, () => {
  process.stderr.write('READY\n');
});

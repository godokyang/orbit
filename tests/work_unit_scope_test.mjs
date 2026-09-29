import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { validateMemberTool } from '../plugins/work-unit-scope.mjs';

const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "orbit-scope-'quote-")));
const outside = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-scope-outside-')));
const unit = { artifact_root: project, scope: { allowed_paths: ['src'],
  allowed_tools: ['read', 'write', 'edit', 'grep', 'glob', 'bash'], allowed_commands: [] } };
const gate = (toolName, input) => validateMemberTool(unit, { toolName, input, rootAgentId: 'Main' });
const execute = input => new Promise(resolve => {
  const child = spawn('/bin/sh', ['-c', input.command], { cwd: input.cwd, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; }); child.stderr.on('data', chunk => { stderr += chunk; });
  const timeout = setTimeout(() => child.kill('SIGKILL'), 5000);
    child.on('close', (code, signal) => { clearTimeout(timeout); resolve({ code, signal, stdout, stderr }); });
});
let server;
try {
  await fs.mkdir(path.join(project, 'src'));
  await fs.writeFile(path.join(outside, 'secret.txt'), 'outside');
  await fs.symlink(outside, path.join(project, 'src', 'escape'));
  assert.equal((await gate('write', { path: 'src/new.js', content: 'yes' })).input.path, path.join(project, 'src/new.js'));
  for (const value of ['../elsewhere', path.join(outside, 'secret.txt'), 'src/escape/secret.txt', '.orbit/state.json', 'https://example.com'])
    assert.equal((await gate('read', { path: value })).block, true, value);
  assert.equal((await gate('edit', { path: 'src/new.js', input: 'unprojected alternate format' })).block, true);
  assert.equal((await gate('edit', { path: 'src/new.js', edits: [{ rename: '../bad', diff: 'x' }] })).block, true);
  assert.equal((await gate('glob', { path: 'src', pattern: '../*' })).block, true);
  assert.equal((await gate('grep', { path: 'src', pattern: 'secret' })).block, true, 'search cannot traverse the descendant escape symlink');
  assert.equal((await gate('fetch', { url: 'https://example.com' })).block, true);
  assert.equal((await gate('hub', { op: 'send', to: 'Main', message: 'result' })).input.to, 'Main');
  assert.equal((await gate('hub', { op: 'send', to: 'another-member', message: 'expand scope' })).block, true);
  // A bound member can end its lifecycle through the native result return,
  // while re-dispatch and other resource tools stay blocked.
  assert.equal((await gate('yield', { data: { summary: 'parser done' } })).input.data.summary, 'parser done');
  assert.equal((await gate('yield', { error: 'cannot complete' })).input.error, 'cannot complete');
  assert.equal((await gate('task', { tasks: [{ agent: 'task', task: 'x', solutionSpace: 'y' }] })).block, true);
  assert.equal((await gate('eval', { code: 'process.env' })).block, true);
  console.log('WORK_UNIT_SCOPE_TEST_PASS native_tools_and_paths');

  const write = 'printf allowed > src/allowed.txt'; unit.scope.allowed_commands.push(write);
  const wrapped = await gate('bash', { command: write });
  if (wrapped.block) {
    assert.match(wrapped.reason, /sandbox/);
    console.log('WORK_UNIT_SCOPE_TEST_SKIP actual_system_sandbox_unavailable; command entrance remains blocked');
  } else {
    const allowedResult = await execute(wrapped.input);
    assert.equal(allowedResult.code, 0, JSON.stringify(allowedResult));
    assert.equal(await fs.readFile(path.join(project, 'src/allowed.txt'), 'utf8'), 'allowed');
    const denied = "printf bad > forbidden.txt"; unit.scope.allowed_commands.push(denied);
    assert.notEqual((await execute((await gate('bash', { command: denied })).input)).code, 0);
    await assert.rejects(fs.stat(path.join(project, 'forbidden.txt')), { code: 'ENOENT' });
    const redirected = 'printf bad > src/escape/new.txt'; unit.scope.allowed_commands.push(redirected);
    assert.notEqual((await execute((await gate('bash', { command: redirected })).input)).code, 0);
    await assert.rejects(fs.stat(path.join(outside, 'new.txt')), { code: 'ENOENT' });
    const privateWrite = 'mkdir -p src/.orbit'; unit.scope.allowed_commands.push(privateWrite);
    assert.notEqual((await execute((await gate('bash', { command: privateWrite })).input)).code, 0, 'nested protected metadata is denied by the kernel too');
    // Different syntax in the actual command cannot escape quoted wrapper
    // arguments, even when the workspace itself contains a single quote.
    const quoted = "printf '%s' \"literal ' quote\" > src/quoted.txt"; unit.scope.allowed_commands.push(quoted);
    assert.equal((await execute((await gate('bash', { command: quoted })).input)).code, 0);
    assert.equal(await fs.readFile(path.join(project, 'src/quoted.txt'), 'utf8'), "literal ' quote");
    console.log('WORK_UNIT_SCOPE_TEST_PASS actual_kernel_write_scope');

    server = net.createServer(socket => { socket.end('reachable'); });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const command = `/usr/bin/curl --silent --max-time 1 http://127.0.0.1:${server.address().port}/`;
    unit.scope.allowed_commands.push(command);
    assert.notEqual((await execute((await gate('bash', { command })).input)).code, 0, 'declaring the command does not authorize network access');
    console.log('WORK_UNIT_SCOPE_TEST_PASS actual_kernel_network_denial');
  }
} finally {
  if (server) await new Promise(resolve => server.close(resolve));
  await fs.rm(project, { recursive: true, force: true });
  await fs.rm(outside, { recursive: true, force: true });
}

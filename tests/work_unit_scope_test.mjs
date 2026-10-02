import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { validateMemberTool, createEditProjection, validateWorkUnitPreflight } from '../plugins/work-unit-scope.mjs';

const project = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "orbit-scope-'quote-")));
const outside = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'orbit-scope-outside-')));
const unit = { artifact_root: project, scope: { allowed_paths: ['src'],
  allowed_tools: ['read', 'write', 'edit', 'grep', 'glob', 'bash'], allowed_commands: [] } };
const gate = (toolName, input, extra = {}) => validateMemberTool(unit, { toolName, input, rootAgentId: 'Main', ...extra });
// Contract-fixture projection: stands in for the host's real native
// editInspect projector; the scope gate must check every listed target.
const projected = (targets, cwd = project) => ({ editTargets: async () => targets, cwd });
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
  const hashline = { i: 'Implementing formatGreeting body', input: '[src/new.js#AAAA]\nPUT 1.:\n+line\n' };
  const passed = await gate('edit', hashline, projected(['src/new.js']));
  assert.equal(passed.block, undefined);
  assert.equal(passed.input.input, hashline.input, 'a projected payload passes through unchanged');
  assert.equal((await gate('edit', hashline, projected(['src/new.js', 'src/second.js']))).block, undefined,
    'every section target inside the allowed paths is accepted');
  for (const targets of [['../escape.txt'], [path.join(outside, 'secret.txt')], ['src/escape/secret.txt'], ['.orbit/state.json']])
    assert.equal((await gate('edit', hashline, projected(targets))).block, true, JSON.stringify(targets));
  assert.equal((await gate('edit', hashline, projected(['src/a.js', '../b.js']))).block, true,
    'a move/rename destination outside the allowed paths is refused');
  assert.equal((await gate('edit', hashline, projected(['src/a.js', 'src/b.js']))).block, undefined,
    'a move/rename destination inside the allowed paths is accepted');
  assert.equal((await gate('edit', hashline, projected(undefined))).block, true,
    'an unprojected payload stays refused');
  assert.equal((await gate('edit', hashline, projected(['new.js'], path.join(project, 'src')))).block, undefined,
    'projected relative paths resolve against the actual member execution cwd');
  assert.equal((await gate('edit', hashline, projected(['new.js'], outside))).block, true,
    'a member cwd outside the work-unit root is refused');
  // The projector factory resolves the mode with the same provider-qualified
  // model identity the native session reports (provider/id), so
  // provider-scoped edit.modelVariants apply exactly as in the real tool.
  const seen = { model: undefined, mode: undefined };
  const fakeSdk = { settings: {}, EditTool: class {
    constructor(session) { seen.model = session.getActiveModelString(); }
    get mode() { return 'hashline'; }
  } };
  const projector = createEditProjection(fakeSdk, { provider: 'kimi-code', id: 'k3-256k' },
    async () => (mode, argsJson) => { seen.mode = mode; return { paths: ['src/new.js'], entries: [], fileOps: [] }; });
  assert.equal((await gate('edit', hashline, { editTargets: projector, cwd: project })).block, undefined);
  assert.equal(seen.model, 'kimi-code/k3-256k', 'mode resolution receives the provider-qualified model identity');
  assert.equal(seen.mode, 'hashline', 'the member session mode reaches the native projection');
  assert.equal(createEditProjection({}, { provider: 'a', id: 'b' }), undefined,
    'an SDK without the native edit tool stays fail-closed');
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

  // Native read/grep/glob syntax: selectors, multi-paths and embedded globs
  // reach their real targets; escapes stay blocked. Directory searches use
  // src/clean because src deliberately contains the `escape` symlink.
  await fs.mkdir(path.join(project, 'src', 'clean'));
  await fs.writeFile(path.join(project, 'src', 'clean', 'a.ts'), 'a\nb\n');
  await fs.writeFile(path.join(project, 'src', 'clean', 'b.ts'), 'c\n');
  await fs.writeFile(path.join(project, 'src', 'literal:1-2'), 'colon\n');
  for (const selector of ['src/clean/a.ts:1', 'src/clean/a.ts:1-2', 'src/clean/a.ts:1+1', 'src/clean/a.ts:2-',
      'src/clean/a.ts:-1', 'src/clean/a.ts:1,2', 'src/clean/a.ts:raw', 'src/clean/a.ts:raw:1-2', 'src/clean/a.ts:1-2:raw'])
    assert.equal((await gate('read', { path: selector })).block, undefined, selector);
  assert.equal((await gate('read', { path: 'src/clean/a.ts:1-2' })).input.path, `${project}/src/clean/a.ts:1-2`,
    'the selector survives with the pinned absolute path');
  assert.equal((await gate('read', { path: 'src/literal:1-2' })).input.path, path.join(project, 'src', 'literal:1-2'),
    'an existing colon-named file stays a literal path (native issue #4618)');
  assert.equal((await gate('read', { path: 'src/clean/a.ts;src/clean/b.ts' })).block, undefined, 'delimited multi-read');
  for (const escape of ['../outside.ts:1-5', 'src/clean/a.ts:1-2;.orbit/state.json', 'src/clean/a.ts;../outside/secret.txt',
      'src/escape/secret.txt:-1', 'src/clean/a.ts;https://example.com'])
    assert.equal((await gate('read', { path: escape })).block, true, escape);
  assert.equal((await gate('grep', { path: 'src/clean/a.ts:1-2', pattern: 'a' })).block, undefined, 'grep line range');
  assert.equal((await gate('grep', { path: 'src/clean/a.ts:raw', pattern: 'a' })).block, true, 'grep rejects display selectors');
  assert.equal((await gate('grep', { path: 'src/clean/*.ts', pattern: 'a' })).block, undefined, 'grep glob entry');
  const bareSearch = cwd => validateMemberTool({ artifact_root: path.join(project, 'src/clean'),
    scope: { allowed_paths: ['.'], allowed_tools: ['grep'] } },
  { toolName: 'grep', input: { path: '*.ts', pattern: 'a' }, cwd });
  assert.equal((await bareSearch(path.join(project, 'src/clean'))).input.path, '*.ts',
    'native bare glob keeps recursive search semantics at the verified member cwd');
  assert.equal((await bareSearch(project)).block, true, 'bare glob cannot search a different cwd');
  assert.equal((await gate('grep', { path: 'src/clean/*.ts:1-2', pattern: 'a' })).block, true, 'range on a glob');
  assert.equal((await gate('grep', { path: 'src/clean;src/clean/a.ts', pattern: 'a' })).block, undefined, 'multi-path search');
  assert.equal((await gate('grep', { path: 'src/clean;../outside', pattern: 'a' })).block, true, 'one escaping entry blocks');
  assert.equal((await gate('grep', { path: 'src', pattern: 'a' })).block, true, 'the escape symlink still blocks searching src');
  assert.equal((await gate('glob', { path: 'src/clean/*.ts' })).block, undefined, 'embedded find glob');
  assert.equal((await gate('glob', { path: 'src/clean' })).block, undefined, 'plain directory find');
  assert.equal((await gate('glob', { path: 'src/clean/*.ts;../*' })).block, true, 'escaping find entry');
  assert.equal((await gate('glob', { path: 'src/clean/*-missing' })).block, undefined,
    'a missing glob target is the native tool\'s answer, not a scope block');
  console.log('WORK_UNIT_SCOPE_TEST_PASS native_selector_multipath_glob');

  // Pre-dispatch preflight: executable unit passes; protected paths, empty or
  // mismatched entrances and unreadable materials block with a repair reason.
  const preflight = (over, materials) => validateWorkUnitPreflight(
    { artifact_root: project, scope: { allowed_paths: ['src'], allowed_tools: ['read', 'write'], allowed_commands: [], ...over } },
    materials === undefined ? {} : { materials });
  assert.equal((await preflight({})).ok, true);
  assert.match((await preflight({ allowed_tools: [] })).reason, /no tool or command entrance/, 'empty entrances');
  assert.match((await preflight({ allowed_paths: ['.orbit'] })).reason, /escapes the actual artifact root|protected/, 'protected declared path');
  assert.match((await preflight({ allowed_paths: ['../x'] })).reason, /invalid work-unit scope path/, 'escaping declared path');
  assert.match((await preflight({ allowed_tools: ['read', 'fetch'] })).reason, /no member entrance: fetch/, 'unknown tool');
  assert.match((await preflight({ allowed_commands: ['ls'] })).reason, /without the bash tool entrance/, 'commands without bash');
  assert.match((await preflight({ allowed_paths: [] })).reason, /no allowed_paths/, 'tools without paths');
  await fs.writeFile(path.join(project, 'note.md'), 'material\n');
  assert.match((await preflight({}, ['note.md'])).reason, /outside the member's allowed paths/, 'unreadable material');
  assert.match((await preflight({}, ['missing.md'])).reason, /does not exist/, 'missing material');
  assert.equal((await preflight({}, ['src/clean/a.ts'])).ok, true, 'material under an allowed path');
  console.log('WORK_UNIT_SCOPE_TEST_PASS work_unit_preflight');

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

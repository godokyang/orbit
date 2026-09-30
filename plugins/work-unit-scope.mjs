// Actual native member tool entrance. Declarations do not enforce permissions;
// the host calls this for each bound member and keeps Root's tools separate.
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const within = (root, target) => {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative));
};
const quote = value => `'${String(value).replace(/'/g, "'\\''")}'`;
const protectedPath = target => target.split(path.sep).some(part => part === '.git' || part === '.orbit');
const supported = new Set(['read', 'write', 'edit', 'grep', 'glob', 'bash']);
let sandboxReady;

async function canonical(target) {
  const tail = [];
  let current = target;
  for (;;) {
    try { return path.join(await fs.realpath(current), ...tail.reverse()); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const parent = path.dirname(current);
      if (parent === current) throw new Error('path has no existing parent');
      tail.push(path.basename(current)); current = parent;
    }
  }
}

async function scopedPath(value, root, allowed, base = root) {
  if (typeof value !== 'string' || !value || value.includes('\0') || value.startsWith('~') ||
      /^[A-Za-z][A-Za-z0-9+.-]*:/.test(value) || value.split(/[\\/]/).includes('..'))
    throw new Error('path is not a bounded workspace path');
  const lexical = path.resolve(base, value);
  const real = await canonical(lexical);
  if (!within(root, lexical) || !within(root, real) || protectedPath(lexical) || protectedPath(real) ||
      !allowed.some(entry => within(entry, lexical) && within(entry, real)))
    throw new Error('path is outside the allowed work-unit paths');
  return real;
}

// Loads the public pi-natives editInspect the native edit tool projects with,
// anchored at the release's own bundled SDK dependency tree
// (runners/omp-reviewer, pinned @oh-my-pi/pi-coding-agent 18.3.4 with the
// matching pi-natives 18.3.4). The release layout ships no node_modules next
// to plugins/, so bare specifier resolution would either fail or silently
// pick a different copy; this anchor always names the exact versioned tree
// the release was built against. Unavailable → null, and callers fail closed.
let editInspectLoader;
function loadEditInspect() {
  return editInspectLoader ||= (async () => {
    try {
      const anchored = new URL('../runners/omp-reviewer/node_modules/@oh-my-pi/pi-natives/native/index.js', import.meta.url);
      const mod = await import(anchored);
      return typeof mod.editInspect === 'function' ? mod.editInspect : null;
    } catch { return null; }
  })();
}

// Builds the edit-target projector for one member session from the host's own
// SDK. The mode resolves exactly as that session's native EditTool resolves
// it: same live settings, and the same provider-qualified active model string
// (`${provider}/${id}`, the SDK's formatModelString semantics) this session
// reports for the tool call. The projection is the native editInspect that
// tool itself uses. The result covers every dialect the SDK supports
// (replace, patch, apply_patch, hashline, sloppy) and lists every written
// path: section targets plus move/rename destinations. An unparseable or
// target-less payload projects nothing and is refused.
export function createEditProjection(sdk, model, loadInspect = loadEditInspect) {
  if (typeof sdk?.EditTool !== 'function') return undefined;
  let mode;
  try {
    mode = new sdk.EditTool({
      settings: sdk.settings,
      getActiveModelString: () => (model ? `${model.provider}/${model.id}` : undefined),
    }).mode;
  } catch { return undefined; }
  return async input => {
    const inspect = await loadInspect();
    if (typeof inspect !== 'function') return undefined;
    let inspection;
    try { inspection = inspect(mode, JSON.stringify(input ?? {})); } catch { return undefined; }
    const base = inspection?.entries?.length ? inspection.entries.map(entry => entry.path) : (inspection?.paths ?? []);
    const targets = [...base];
    for (const op of inspection?.fileOps ?? []) {
      if (typeof op.path === 'string') targets.push(op.path);
      if (op.kind === 'move' && typeof op.to === 'string') targets.push(op.to);
    }
    const unique = [...new Set(targets)];
    return unique.length ? unique : undefined;
  };
}

async function safeSearchBase(base) {
  if (!(await fs.stat(base)).isDirectory()) return;
  const pending = [base];
  let visited = 0;
  while (pending.length) {
    const directory = pending.pop();
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      if (++visited > 10000) throw new Error('search base is too broad to verify; choose a smaller scoped directory');
      if (entry.name === '.git' || entry.name === '.orbit' || entry.isSymbolicLink())
        throw new Error('native search could traverse protected data or a symlink; choose a narrower base or use scoped read');
      if (entry.isDirectory()) pending.push(path.join(directory, entry.name));
    }
  }
}

function sandboxProfile(root, allowed) {
  const string = value => JSON.stringify(value);
  const libraries = ['/usr', '/System', '/Library', '/bin', '/sbin', '/opt'];
  if (root.includes('\\')) throw new Error('this command sandbox cannot safely express a backslash in the workspace path');
  const escapedRoot = root.replace(/[.*+?^${}()|[\]]/g, character =>
    character === '[' ? '[[]' : character === ']' ? '[]]' : `[${character}]`);
  const privateDescendants = `^${escapedRoot}/(.*/)?[.](git|orbit)(/.*)?$`;
  // dyld and getcwd need directory traversal. Literal ancestor directories
  // grant no access to the file contents of their other descendants.
  const directories = new Set();
  for (const target of [root, ...allowed, ...libraries, '/dev/null']) {
    let directory = path.dirname(target);
    for (;;) {
      directories.add(directory);
      const parent = path.dirname(directory);
      if (parent === directory) break;
      directory = parent;
    }
  }
  return ['(version 1)', '(deny default)', '(allow process*)', '(allow sysctl-read)',
    '(allow file-read-metadata)', '(allow mach-lookup)',
    `(allow file-read-data ${[...directories].map(base => `(literal ${string(base)})`).join(' ')})`,
    `(allow file-read-data ${[...allowed, ...libraries].map(base => `(subpath ${string(base)})`).join(' ')} (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))`,
    `(allow file-write* ${allowed.map(base => `(subpath ${string(base)})`).join(' ')})`,
    `(deny file-read* (subpath ${string(path.join(root, '.orbit'))}) (subpath ${string(path.join(root, '.git'))}))`,
    `(deny file-write* (subpath ${string(path.join(root, '.orbit'))}) (subpath ${string(path.join(root, '.git'))}))`,
    `(deny file-read* file-write* (regex #${string(privateDescendants)}))`,
    '(allow file-write-data (literal "/dev/null"))'].join('\n');
}

function availableSandbox() {
  if (sandboxReady !== undefined) return sandboxReady;
  if (process.platform !== 'darwin') return (sandboxReady = false);
  const probe = spawnSync('/usr/bin/sandbox-exec', ['-p', '(version 1) (deny default) (allow process*) (allow file-read*)',
    '/bin/sh', '-c', ':'], { timeout: 5000, encoding: 'utf8' });
  return (sandboxReady = probe.status === 0);
}

export async function validateMemberTool(unit, { toolName, input, rootAgentId, editTargets, cwd }) {
  try {
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('invalid native tool input');
    // A currently bound member can report to the owning Root. Peer wakeups and hub
    // control ops cannot be used to extend the unit's execution authority.
    if (toolName === 'hub') {
      if (input.op === 'send' && input.to === rootAgentId) return { input };
      throw new Error('members may only send their result to the owning Root');
    }
    // Native result submission (SDK tools/yield.ts): the subagent's terminal
    // or incremental result return carries only data/error/type, spawns
    // nothing and touches no path. It is the member's lifecycle end, not a
    // resource entrance, so it is allowed for any bound member regardless of
    // the unit's allowed_tools; `task` re-dispatch stays blocked below.
    if (toolName === 'yield') return { input };
    if (toolName === 'write' && typeof input.path === 'string' && input.path.startsWith('agent://')) {
      if (input.path === `agent://${rootAgentId}`) return { input };
      throw new Error('member peer writes may only report to the owning Root');
    }
    if (!supported.has(toolName) || !unit.scope?.allowed_tools?.includes(toolName))
      throw new Error(`tool ${toolName} has no allowed work-unit entrance`);
    const root = await fs.realpath(unit.artifact_root);
    const allowed = [];
    for (const declared of unit.scope.allowed_paths || []) {
      if (typeof declared !== 'string' || declared.startsWith('~') || declared.includes('\0') ||
          declared.split(/[\\/]/).includes('..') || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(declared))
        throw new Error('invalid work-unit scope path');
      const lexical = path.resolve(root, declared), real = await canonical(lexical);
      if (!within(root, lexical) || !within(root, real) || protectedPath(real)) throw new Error('work-unit scope escapes the actual artifact root');
      allowed.push(real);
    }
    if (!allowed.length) throw new Error('work unit allows no filesystem path');
    if (toolName === 'bash') {
      if (typeof input.command !== 'string' || !unit.scope.allowed_commands?.includes(input.command))
        throw new Error('command is absent from the declared work-unit commands');
      if (input.pty || input.env || input.name || input.ready) throw new Error('PTY, injected environment and services have no bounded command entrance');
      const cwd = input.cwd === undefined ? root : await scopedPath(input.cwd, root, [root]);
      if (!availableSandbox()) throw new Error('no verified system command sandbox is available; Root must run the required verification');
      // The outer native shell sees only quoted constants. All user command
      // syntax runs inside the kernel sandbox; inherited provider credentials
      // are removed from the command environment. No network rule is allowed.
      const command = `/usr/bin/sandbox-exec -p ${quote(sandboxProfile(root, allowed))} /usr/bin/env -i PATH=${quote(process.env.PATH || '/usr/bin:/bin')} /bin/bash --noprofile --norc -c ${quote(input.command)}`;
      return { input: { ...input, command, cwd } };
    }
    const result = { ...input };
    if (toolName === 'edit') {
      if (editTargets) {
        // Complete projection from the host's own native edit machinery (same
        // mode, same settings): every written path, section targets plus
        // move/rename destinations. Unknown or target-less forms stay refused;
        // a member can use scoped write or ask Root, never a partial path scan.
        const targets = await editTargets(input);
        if (!targets) throw new Error('this edit form exposes no complete target paths; use a scoped write or report to Root');
        // Projected relative paths resolve against the member session's actual
        // execution cwd, exactly where the native edit tool will resolve them;
        // the payload itself is passed through unchanged.
        const execBase = await canonical(cwd || root);
        if (!within(root, execBase)) throw new Error('member execution cwd is outside the work-unit artifact root');
        for (const target of targets) await scopedPath(target, root, allowed, execBase);
        return { input };
      }
      // Fallback when the host SDK exposes no projection: only the verified
      // replace/patch key form is accepted, every target scope-checked.
      if (typeof input.path !== 'string') throw new Error('this edit form exposes no complete target paths; use a scoped write or report to Root');
      if (Object.keys(input).some(key => !['path', 'old_string', 'new_string', 'replace_all', 'edits'].includes(key)))
        throw new Error('edit contains an unprojected input form');
      result.path = await scopedPath(input.path, root, allowed);
      if (input.edits !== undefined) {
        if (!Array.isArray(input.edits)) throw new Error('invalid native edit list');
        result.edits = await Promise.all(input.edits.map(async edit => {
          if (!edit || typeof edit !== 'object') throw new Error('invalid native edit');
          return { ...edit, ...(edit.rename === undefined ? {} : { rename: await scopedPath(edit.rename, root, allowed) }) };
        }));
      }
    } else {
      if ((toolName === 'glob' && typeof input.pattern === 'string' &&
          (path.isAbsolute(input.pattern) || input.pattern.split(/[\\/]/).includes('..') || input.pattern.startsWith('~'))) ||
          (typeof input.glob === 'string' && (path.isAbsolute(input.glob) || input.glob.split(/[\\/]/).includes('..'))))
        throw new Error('search pattern escapes its scoped base');
      result.path = await scopedPath(input.path || '.', root, allowed);
      if (toolName === 'grep' || toolName === 'glob') await safeSearchBase(result.path);
    }
    return { input: result };
  } catch (error) { return { block: true, reason: `Orbit work-unit scope: ${error.message}` }; }
}

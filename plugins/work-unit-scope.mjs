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


// ---------------------------------------------------------------------------
// Native read/grep/glob path grammar, mirrored line-by-line from the pinned
// host SDK (@oh-my-pi/pi-coding-agent 18.3.4 src/tools/read.ts, grep.ts,
// glob.ts, tools/path-utils.ts; @oh-my-pi/pi-tui src/tools/read.ts and
// tools/line-ranges.ts). Selector and search grammars were cross-checked
// against the installed live OMP 18.4.9 binary (identical selector error
// strings and splitPathAndSelPreferringLiteral entry points). The gate must
// parse exactly what the native tools parse: line selectors (`:N`, `:N-M`,
// `:N+K`, `:N-`, `:-N`, comma lists, `:raw`/`:conflicts`/`:img`, compound
// `:raw:50-100`), `;`-delimited multi-paths with literal-path preference, and
// glob-carrying search entries. Reimplemented here because the SDK ships
// type-stripped-unimportable TS sources; every rule names its native origin.

// pi-tui tools/line-ranges.ts LINE_RANGE_CHUNK_SOURCE + read.ts RANGE_SELECTOR_CHUNK lookbehind.
const RANGE_CHUNK = String.raw`L?(?:\d+)(?:(?:\.\.|[-+])L?(?:\d+)?)?(?<=[\d.-])`;
const RANGE_LIST_RE = new RegExp(`^${RANGE_CHUNK}(?:,${RANGE_CHUNK})*$`, 'i');
const TAIL_RE = /^-\d+$/;
// pi-tui tools/read.ts FILE_LINE_RANGE_RE / FILE_LINE_RANGE_ONLY_RE / FILE_RAW_ONLY_RE.
const FILE_LINE_RANGE_RE = new RegExp(`^(?:${RANGE_CHUNK}(?:,${RANGE_CHUNK})*|-\\d+|raw|conflicts|img)$`, 'i');
const FILE_LINE_RANGE_ONLY_RE = new RegExp(`^(?:${RANGE_CHUNK}(?:,${RANGE_CHUNK})*|-\\d+)$`, 'i');
const FILE_RAW_ONLY_RE = /^raw$/i;
// pi-coding-agent tools/path-utils.ts GLOB_PATH_CHARS.
const hasGlobPathChars = value => ['*', '?', '[', '{'].some(char => value.includes(char));

// pi-tui tools/read.ts splitPathAndSel: peel a trailing selector, including the
// two-chunk `raw`+range compound in either order.
function splitPathAndSel(rawPath) {
  const colon = rawPath.lastIndexOf(':');
  if (colon <= 0) return { path: rawPath };
  const candidate = rawPath.slice(colon + 1);
  if (!FILE_LINE_RANGE_RE.test(candidate)) return { path: rawPath };
  let basePath = rawPath.slice(0, colon);
  let sel = candidate;
  const innerColon = basePath.lastIndexOf(':');
  if (innerColon > 0) {
    const inner = basePath.slice(innerColon + 1);
    if ((FILE_RAW_ONLY_RE.test(inner) && FILE_LINE_RANGE_ONLY_RE.test(candidate)) ||
        (FILE_LINE_RANGE_ONLY_RE.test(inner) && FILE_RAW_ONLY_RE.test(candidate))) {
      sel = `${inner}:${candidate}`;
      basePath = basePath.slice(0, innerColon);
    }
  }
  return { path: basePath, sel };
}

// path-utils.ts probeLiteralPathExists: lstat three-way probe (POSIX: an
// inconclusive probe keeps the literal interpretation).
async function probeLiteral(filePath, base) {
  try { await fs.lstat(path.resolve(base, filePath)); return 'exists'; }
  catch (error) {
    if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR' || error?.code === 'ENAMETOOLONG') return 'missing';
    return 'unknown';
  }
}

// path-utils.ts splitPathAndSelPreferringLiteral: a real file named `a:1-2`
// always outranks the `:1-2` selector reading (native issue #4618).
async function splitPreferringLiteral(rawPath, base) {
  const strict = splitPathAndSel(rawPath);
  if (strict.sel === undefined) return strict;
  return (await probeLiteral(rawPath, base)) !== 'missing' ? { path: rawPath } : strict;
}

// path-utils.ts parseSearchPath: split at the first glob segment.
function parseSearchPath(filePath) {
  const normalized = filePath.replace(/\\/g, '/');
  const segments = normalized.split('/');
  const index = segments.findIndex(hasGlobPathChars);
  if (index === -1) return { basePath: normalized };
  if (index <= 0) return { basePath: '.', glob: normalized };
  return { basePath: segments.slice(0, index).join('/'), glob: segments.slice(index).join('/') };
}

// path-utils.ts parseFindPattern (glob tool: the pattern is embedded in path).
function parseFindPattern(pattern) {
  const normalized = pattern.replace(/\\/g, '/');
  const segments = normalized.split('/');
  const index = segments.findIndex(hasGlobPathChars);
  if (index === -1) return { basePath: normalized, globPattern: '**/*', hasGlob: false };
  if (index === 0)
    return { basePath: '.', globPattern: normalized.startsWith('**/') ? normalized : `**/${normalized}`, hasGlob: true };
  return { basePath: segments.slice(0, index).join('/'), globPattern: segments.slice(index).join('/'), hasGlob: true };
}

// path-utils.ts normalizePathLikeInput (trim + strip outer double quotes).
const normalizeEntry = value => {
  const trimmed = value.trim();
  return trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length > 1 ? trimmed.slice(1, -1) : trimmed;
};

// path-utils.ts hasTopLevelPathDelimiter / splitTopLevelDelimitedPath:
// `,` `;` and whitespace delimit only outside `{}` groups; `\` escapes.
function splitTopLevel(entry, mode) {
  const parts = [];
  let depth = 0, start = 0;
  for (let index = 0; index < entry.length; index++) {
    const char = entry[index];
    if (char === '\\' && index + 1 < entry.length) { index++; continue; }
    if (char === '{') { depth++; continue; }
    if (char === '}') { if (depth > 0) depth--; continue; }
    if (depth !== 0) continue;
    const delimits = mode === 'semicolon' ? char === ';'
      : mode === 'comma' ? char === ','
      : mode === 'whitespace' ? /\s/.test(char)
      : char === ',' || char === ';' || /\s/.test(char);
    if (delimits) { parts.push(entry.slice(start, index)); start = index + 1; }
  }
  parts.push(entry.slice(start));
  return parts;
}

// path-utils.ts delimitedPathPartResolves (existence of the entry's search base).
async function partResolves(entry, base, splitter) {
  const { basePath } = splitter(splitPathAndSel(entry).path);
  try { await fs.stat(path.resolve(base, basePath)); return true; }
  catch (error) {
    if (error?.code === 'ENOENT' || error?.code === 'ENAMETOOLONG') return false;
    throw error;
  }
}

// path-utils.ts splitDelimitedPathEntry, minus internal-URL handling (member
// scope rejects URLs outright): existing literal paths win over delimiter
// recovery; `;` splits unconditionally, `,` needs one resolving part,
// whitespace/mixed need every part to resolve.
async function splitDelimited(entry, base, splitter) {
  const normalized = normalizeEntry(entry);
  const mixedParts = splitTopLevel(normalized, 'mixed');
  if (mixedParts.length < 2) return null;
  if (await probeLiteral(normalized, base) !== 'missing') return null;
  const selectorSplit = splitPathAndSel(normalized);
  if (selectorSplit.sel !== undefined && await probeLiteral(selectorSplit.path, base) !== 'missing') return null;
  if (!hasGlobPathChars(selectorSplit.path) && await partResolves(normalized, base, splitter)) return null;
  const trySplit = async (mode, requirement) => {
    const rawParts = splitTopLevel(normalized, mode);
    if (rawParts.length < 2) return null;
    const parts = rawParts.map(normalizeEntry).filter(part => part.length > 0);
    if (parts.length === 0) return null;
    if (parts.length < 2 && rawParts.length === parts.length) return null;
    if (requirement !== 'none') {
      const resolved = await Promise.all(parts.map(part => partResolves(part, base, splitter)));
      if (requirement === 'all' ? !resolved.every(Boolean) : !resolved.some(Boolean)) return null;
    }
    return parts;
  };
  return await trySplit('semicolon', 'none') ?? await trySplit('comma', 'some') ??
    await trySplit('whitespace', 'all') ?? await trySplit('mixed', 'all');
}

// pi-tui render/render-utils.ts toPathList: a JSON string array is a path list.
function toPathList(value) {
  const trimmed = value.trim();
  if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
    try {
      const parsed = JSON.parse(trimmed);
      if (Array.isArray(parsed) && parsed.every(entry => typeof entry === 'string')) return parsed;
    } catch { /* not an encoded list */ }
  }
  return [value];
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

// Resolve the unit's artifact root and declared allowed paths to canonical
// real paths. Shared by the per-call gate and the pre-dispatch preflight.
async function resolveUnitScope(unit) {
  const root = await fs.realpath(unit.artifact_root);
  const allowed = [];
  for (const declared of unit.scope?.allowed_paths || []) {
    if (typeof declared !== 'string' || declared.startsWith('~') || declared.includes('\0') ||
        declared.split(/[\\/]/).includes('..') || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(declared))
      throw new Error('invalid work-unit scope path');
    const lexical = path.resolve(root, declared), real = await canonical(lexical);
    if (!within(root, lexical) || !within(root, real) || protectedPath(lexical) || protectedPath(real))
      throw new Error('work-unit scope escapes the actual artifact root');
    allowed.push(real);
  }
  return { root, allowed };
}

async function safeSearchBase(base) {
  let stat;
  try { stat = await fs.stat(base); }
  catch (error) {
    // A missing base searches nothing; the native tool reports the miss (and
    // tolerates missing entries in a multi-path call), so there is no tree to
    // verify here.
    if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR') return;
    throw error;
  }
  if (!stat.isDirectory()) return;
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

// read: `path` may carry line selectors and `;`-delimited multi-targets
// (read.ts #tryReadDelimitedPaths). Every resolved target is scope-checked;
// the validated absolute path is reassembled with its selector so the native
// tool applies the identical grammar to the pinned path.
async function scopedReadTarget(value, root, allowed) {
  if (typeof value !== 'string' || !value) throw new Error('invalid native read path');
  const parts = await splitDelimited(value, root, parseSearchPath) ?? [value];
  const rewritten = [];
  for (const part of parts) {
    const split = await splitPreferringLiteral(part, root);
    const base = await scopedPath(split.path, root, allowed);
    rewritten.push(split.sel === undefined ? base : `${base}:${split.sel}`);
  }
  return rewritten.join(';');
}

// grep: `path` entries may be `;`-delimited, carry line-range-only selectors,
// or embed a glob whose base directory is the searched scope (grep.ts
// parsePathSpecs/resolveToolSearchScope). A missing entry searches nothing.
async function scopedGrepTarget(value, root, allowed, cwd) {
  const entries = [];
  for (const raw of value === undefined ? ['.'] : toPathList(value)) {
    if (typeof raw !== 'string') throw new Error('invalid native search path');
    entries.push(...await splitDelimited(raw, root, parseSearchPath) ?? [raw]);
  }
  const rewritten = [], bases = [];
  for (const entry of entries) {
    const split = await splitPreferringLiteral(entry, root);
    if (split.sel !== undefined && !RANGE_LIST_RE.test(split.sel))
      throw new Error(`path entry "${entry}" — only line-range selectors like ":50-100" are supported (no ":raw"/":conflicts")`);
    if (hasGlobPathChars(split.path) && await probeLiteral(split.path, root) === 'missing') {
      if (split.sel !== undefined) throw new Error(`Line-range selector requires a single file, not a glob: ${entry}`);
      const { basePath, glob } = parseSearchPath(split.path);
      if (glob !== undefined && glob.split('/').includes('..')) throw new Error('search pattern escapes its scoped base');
      const base = await scopedPath(basePath, root, allowed);
      bases.push(base);
      // SDK 18.4.9 makes a bare glob recursive. Absolute rewriting loses
      // that native flag, so retain this spelling only at the verified cwd.
      if (!split.path.includes('/') && !split.path.includes('\\')) {
        if (!cwd || await canonical(cwd) !== root)
          throw new Error('bare grep glob requires the member cwd to match the artifact root');
        rewritten.push(split.path);
      } else rewritten.push(glob === undefined ? base : `${base}/${glob}`);
      continue;
    }
    const real = await scopedPath(split.path, root, allowed);
    bases.push(real);
    rewritten.push(split.sel === undefined ? real : `${real}:${split.sel}`);
  }
  return { path: rewritten.join(';'), bases };
}

// glob: the find pattern is embedded in `path` itself (glob.ts +
// parseFindPattern); `;`-delimited entries fan out per pattern.
async function scopedFindTarget(value, root, allowed) {
  const entries = [];
  for (const raw of value === undefined ? ['.'] : toPathList(value)) {
    if (typeof raw !== 'string') throw new Error('invalid native find path');
    entries.push(...await splitDelimited(raw, root, parseFindPattern) ?? [raw]);
  }
  const rewritten = [], bases = [];
  for (const entry of entries) {
    const pattern = normalizeEntry(entry).replace(/\\/g, '/');
    if (/^\/+$/.test(pattern)) throw new Error("searching from root directory '/' is not allowed");
    if (!pattern.length) throw new Error('`path` must contain non-empty globs or paths');
    const parsed = parseFindPattern(pattern);
    if (parsed.globPattern.split('/').includes('..')) throw new Error('search pattern escapes its scoped base');
    const base = await scopedPath(parsed.basePath, root, allowed);
    bases.push(base);
    rewritten.push(parsed.hasGlob ? `${base}/${parsed.globPattern}` : base);
  }
  return { path: rewritten.join(';'), bases };
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
    const { root, allowed } = await resolveUnitScope(unit);
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
    } else if (toolName === 'read') {
      result.path = await scopedReadTarget(input.path, root, allowed);
    } else if (toolName === 'grep' || toolName === 'glob') {
      // Non-schema keys keep the conservative escape guard; the native glob
      // tool takes no `pattern`/`glob` parameter (the find pattern is embedded
      // in `path`), so these only fire on off-schema input.
      if ((toolName === 'glob' && typeof input.pattern === 'string' &&
          (path.isAbsolute(input.pattern) || input.pattern.split(/[\\/]/).includes('..') || input.pattern.startsWith('~'))) ||
          (typeof input.glob === 'string' && (path.isAbsolute(input.glob) || input.glob.split(/[\\/]/).includes('..'))))
        throw new Error('search pattern escapes its scoped base');
      const scoped = toolName === 'grep'
        ? await scopedGrepTarget(input.path, root, allowed, cwd)
        : await scopedFindTarget(input.path, root, allowed);
      result.path = scoped.path;
      for (const base of scoped.bases) await safeSearchBase(base);
    } else {
      result.path = await scopedPath(input.path || '.', root, allowed);
    }
    return { input: result };
  } catch (error) { return { block: true, reason: `Orbit work-unit scope: ${error.message}` }; }
}

// Pre-dispatch executability check for a declared work unit, run by the host
// before any member session or candidate-model spend. Returns { ok: true,
// root, allowed } when the unit can actually exercise its declared entrances,
// or { block: true, reason } with the concrete repair Root must apply.
// options.materials: task input material paths the Root plans to hand the
// member; each must already exist inside the artifact root, outside
// .git/.orbit, and inside the member's allowed paths (members read nothing
// else — Root must place materials under an allowed path first). options.cwd
// is the caller-verified workspace, used only when unit.artifact_root is absent.
export async function validateWorkUnitPreflight(unit, { materials = unit?.input_materials ?? [], cwd, availableTools } = {}) {
  try {
    const { root, allowed } = await resolveUnitScope({ ...unit, artifact_root: unit?.artifact_root ?? cwd });
    const tools = unit.scope?.allowed_tools ?? [];
    const commands = unit.scope?.allowed_commands ?? [];
    if (!tools.length && !commands.length)
      throw new Error('the unit declares no tool or command entrance; declare allowed_tools or allowed_commands before dispatch');
    const unknown = tools.filter(name => !supported.has(name) && name !== 'hub' && name !== 'yield');
    if (unknown.length)
      throw new Error(`declared tools have no member entrance: ${unknown.join(', ')}; the member gate exposes read/write/edit/grep/glob/bash plus the native hub/yield lifecycle`);
    if (!allowed.length)
      throw new Error('the unit declares no allowed_paths; the member gate refuses every tool and command call without at least one allowed path');
    if (commands.length && !tools.includes('bash'))
      throw new Error('allowed_commands are declared without the bash tool entrance; add bash to allowed_tools or drop the commands');
    if (tools.includes('bash') && !commands.length)
      throw new Error('bash has no allowed_commands and cannot execute; declare complete commands or remove bash before dispatch');
    if (tools.includes('bash') && !availableSandbox())
      throw new Error('the bounded command sandbox is unavailable; Root must run commands instead of dispatching an unexecutable unit');
    if (Array.isArray(availableTools)) {
      const missing = tools.filter(name => !['hub', 'yield'].includes(name) && !availableTools.includes(name));
      if (missing.length) throw new Error(`required native tools are unavailable: ${missing.join(', ')}; Root must provide the capability or take over`);
    }
    if (!Array.isArray(materials)) throw new Error('invalid materials list');
    for (const material of materials) {
      if (typeof material !== 'string' || !material || material.startsWith('~') || material.includes('\0') ||
          material.split(/[\\/]/).includes('..') || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(material))
        throw new Error(`material ${JSON.stringify(material)} is not a bounded workspace path`);
      const lexical = path.resolve(root, material);
      let real;
      try { real = await fs.realpath(lexical); }
      catch { throw new Error(`material ${material} does not exist; prepare it in the project before dispatch instead of re-dispatching`); }
      if (!within(root, lexical) || !within(root, real) || protectedPath(lexical) || protectedPath(real))
        throw new Error(`material ${material} is outside the artifact root or under a protected path`);
      if (!allowed.some(entry => within(entry, lexical) && within(entry, real)))
        throw new Error(`material ${material} is outside the member's allowed paths; place it under an allowed path or extend allowed_paths before dispatch`);
    }
    return { ok: true, root, allowed };
  } catch (error) { return { block: true, reason: `Orbit work-unit preflight: ${error.message}` }; }
}

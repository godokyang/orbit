import { createHash } from 'node:crypto'
import { lstat, readdir, readFile, readlink } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'

const DEFAULT_SKIP = new Set(['.git', '.orbit', 'node_modules'])

export interface WorkspaceDigestOptions {
  /** Maximum files hashed before the digest is refused. */
  maxFiles?: number
  /** Maximum total bytes hashed before the digest is refused. */
  maxBytes?: number
  /** Directory names skipped at any depth. */
  skip?: Iterable<string>
}

export interface WorkspaceDigest {
  /** SHA-256 over the sorted path/mode/size/content manifest. */
  digest: string
  files: number
  bytes: number
}

function normalize(path: string): string {
  return path.split(sep).join('/')
}

async function safeLink(path: string): Promise<string> {
  try {
    return await readlink(path)
  } catch {
    return '<unreadable-link>'
  }
}

/**
 * Hash the artifact tree as the checker's fixed version identifier: relative
 * path, executable bit, size and content (or symlink target) for every regular
 * entry. Generated/supervision directories are excluded. This is a version
 * identifier, not a copy of the tree.
 */
export async function digestWorkspace(root: string, options: WorkspaceDigestOptions = {}): Promise<WorkspaceDigest> {
  const maxFiles = options.maxFiles ?? 4_000
  const maxBytes = options.maxBytes ?? 67_108_864
  const skip = new Set([...DEFAULT_SKIP, ...(options.skip ?? [])])
  const entries: string[] = []
  let files = 0
  let bytes = 0

  async function walk(directory: string): Promise<void> {
    const children = await readdir(directory, { withFileTypes: true })
    children.sort((a, b) => a.name.localeCompare(b.name))
    for (const child of children) {
      if (child.isDirectory() && skip.has(child.name)) continue
      const absolute = join(directory, child.name)
      const path = normalize(relative(root, absolute))
      const info = await lstat(absolute)
      if (info.isDirectory()) {
        await walk(absolute)
        continue
      }
      if (info.isSymbolicLink()) {
        entries.push(`${path}\0link\0${await safeLink(absolute)}`)
        files += 1
        continue
      }
      if (!info.isFile()) continue
      files += 1
      bytes += info.size
      if (files > maxFiles) throw new Error(`workspace has more than ${maxFiles} files; reduce the artifact root or check a subdirectory`)
      if (bytes > maxBytes) throw new Error(`workspace exceeds ${maxBytes} bytes; reduce the artifact root or check a subdirectory`)
      const content = await readFile(absolute)
      const hash = createHash('sha256').update(content).digest('hex')
      const executable = (info.mode & 0o111) !== 0 ? 'x' : '-'
      entries.push(`${path}\0${executable}\0${info.size}\0${hash}`)
    }
  }

  const info = await lstat(root)
  if (!info.isDirectory()) throw new Error(`artifact root is not a directory: ${root}`)
  await walk(root)
  entries.sort()
  const digest = createHash('sha256').update(entries.join('\n')).digest('hex')
  return { digest, files, bytes }
}

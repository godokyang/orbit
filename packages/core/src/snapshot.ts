import { createHash } from 'node:crypto'
import { chmod, lstat, mkdir, readFile, readdir, readlink, rm, symlink, writeFile } from 'node:fs/promises'
import { dirname, join, relative, sep } from 'node:path'

const DEFAULT_SKIP = new Set(['.git', '.orbit', 'node_modules'])

export interface SnapshotOptions {
  maxFiles?: number
  maxBytes?: number
  skip?: Iterable<string>
}

export interface WorkspaceSnapshot {
  dir: string
  digest: string
  files: number
  bytes: number
}

function normalize(path: string): string {
  return path.split(sep).join('/')
}

/**
 * Copy the artifact tree into a fixed snapshot directory and hash the copied
 * bytes with the same manifest as `digestWorkspace`. The snapshot is the
 * checker's read root; the live workspace may keep changing.
 */
export async function snapshotWorkspace(root: string, dest: string, options: SnapshotOptions = {}): Promise<WorkspaceSnapshot> {
  const maxFiles = options.maxFiles ?? 4_000
  const maxBytes = options.maxBytes ?? 67_108_864
  const skip = new Set([...DEFAULT_SKIP, ...(options.skip ?? [])])
  await rm(dest, { recursive: true, force: true })
  await mkdir(dest, { recursive: true, mode: 0o700 })
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
      const target = join(dest, path)
      const info = await lstat(absolute)
      if (info.isDirectory()) {
        await mkdir(target, { recursive: true, mode: 0o700 })
        await walk(absolute)
        continue
      }
      await mkdir(dirname(target), { recursive: true, mode: 0o700 })
      if (info.isSymbolicLink()) {
        const link = await readlink(absolute)
        await symlink(link, target)
        entries.push(`${path}\0link\0${link}`)
        files += 1
        continue
      }
      if (!info.isFile()) continue
      files += 1
      bytes += info.size
      if (files > maxFiles) throw new Error(`workspace has more than ${maxFiles} files`)
      if (bytes > maxBytes) throw new Error(`workspace exceeds ${maxBytes} bytes`)
      const content = await readFile(absolute)
      await writeFile(target, content, { mode: info.mode & 0o777 })
      await chmod(target, info.mode & 0o777)
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
  return { dir: dest, digest, files, bytes }
}

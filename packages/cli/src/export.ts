import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join, relative, sep } from 'node:path'
import type { TaskState } from '@orbit/core'
import { openTask } from './tasks.js'

interface ExportedFile {
  encoding: 'utf8' | 'base64'
  content: string
}

export interface ExportResult {
  format: 'orbit-export-v1'
  exportedAt: string
  taskId: string
  taskDir: string
  state: TaskState
  files: Record<string, ExportedFile>
  bytes: number
  output: string
}

function toPosix(path: string): string {
  return path.split(sep).join('/')
}

async function collect(directory: string, root: string, files: Record<string, ExportedFile>): Promise<number> {
  let bytes = 0
  const entries = await readdir(directory, { withFileTypes: true })
  entries.sort((a, b) => a.name.localeCompare(b.name))
  for (const entry of entries) {
    if (entry.name.endsWith('.tmp') || entry.name.endsWith('.sock')) continue
    const absolute = join(directory, entry.name)
    if (entry.isDirectory()) {
      bytes += await collect(absolute, root, files)
      continue
    }
    if (!entry.isFile()) continue
    const content = await readFile(absolute)
    bytes += content.length
    const text = content.toString('utf8')
    const utf8 = Buffer.from(text, 'utf8').equals(content)
    files[toPosix(relative(root, absolute))] = utf8
      ? { encoding: 'utf8', content: text }
      : { encoding: 'base64', content: content.toString('base64') }
  }
  return bytes
}

/**
 * Build a self-contained evidence package for one task. Read-only: it snapshots
 * the task directory (state, events, members, units, checks, coverage) and does
 * not contact the live host or upload anything.
 */
export async function exportTask(projectRoot: string, id: string | undefined, output: string): Promise<ExportResult> {
  const service = await openTask(projectRoot, id)
  const state = await service.state()
  const files: Record<string, ExportedFile> = {}
  const bytes = await collect(service.store.dir, service.store.dir, files)
  const result: ExportResult = {
    format: 'orbit-export-v1',
    exportedAt: new Date().toISOString(),
    taskId: state.id,
    taskDir: service.store.dir,
    state,
    files,
    bytes,
    output,
  }
  await mkdir(dirname(output), { recursive: true })
  await writeFile(output, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
  return result
}

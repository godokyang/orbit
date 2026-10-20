import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { digestWorkspace } from '../src/workspace-digest.js'
import { snapshotWorkspace } from '../src/snapshot.js'

const dirs: string[] = []
async function temp(prefix: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), prefix))
  dirs.push(dir)
  return dir
}
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('workspace snapshot', () => {
  it('copies content, mode and symlinks and matches the digest', async () => {
    const root = await temp('orbit-snap-src-')
    await writeFile(join(root, 'a.txt'), 'one')
    await mkdir(join(root, 'sub'))
    await writeFile(join(root, 'sub', 'run.sh'), '#!/bin/sh\n', { mode: 0o755 })
    await symlink('a.txt', join(root, 'link'))
    await mkdir(join(root, '.orbit'))
    await writeFile(join(root, '.orbit', 'state.json'), '{}')

    const dest = join(await temp('orbit-snap-dst-'), 'copy')
    const snapshot = await snapshotWorkspace(root, dest)
    expect(snapshot.digest).toBe((await digestWorkspace(root)).digest)
    expect(snapshot.files).toBe(3)
    expect(await readFile(join(dest, 'a.txt'), 'utf8')).toBe('one')
    expect((await lstat(join(dest, 'sub', 'run.sh'))).mode & 0o111).not.toBe(0)
    expect((await lstat(join(dest, 'link'))).isSymbolicLink()).toBe(true)
    await expect(lstat(join(dest, '.orbit'))).rejects.toThrow()
  })

  it('leaves the live workspace untouched and refuses oversized trees', async () => {
    const root = await temp('orbit-snap-bound-')
    await writeFile(join(root, 'a.txt'), 'one')
    await writeFile(join(root, 'b.txt'), 'two')
    await expect(snapshotWorkspace(root, join(root, 'copy'), { maxFiles: 1 })).rejects.toThrow(/more than 1 files/)
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('one')
  })
})

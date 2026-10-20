import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { digestWorkspace } from '../src/workspace-digest.js'

const dirs: string[] = []

async function project(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'orbit-digest-'))
  dirs.push(dir)
  return dir
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('workspace digest', () => {
  it('is stable across calls and changes when content changes', async () => {
    const dir = await project()
    await writeFile(join(dir, 'a.txt'), 'one')
    await mkdir(join(dir, 'sub'))
    await writeFile(join(dir, 'sub', 'b.txt'), 'two')

    const first = await digestWorkspace(dir)
    const again = await digestWorkspace(dir)
    expect(first).toEqual(again)
    expect(first.files).toBe(2)

    await writeFile(join(dir, 'a.txt'), 'changed')
    const changed = await digestWorkspace(dir)
    expect(changed.digest).not.toBe(first.digest)
  })

  it('ignores .git, .orbit and node_modules', async () => {
    const dir = await project()
    await writeFile(join(dir, 'a.txt'), 'one')
    const before = await digestWorkspace(dir)

    await mkdir(join(dir, '.git'))
    await writeFile(join(dir, '.git', 'config'), 'ignored')
    await mkdir(join(dir, '.orbit'))
    await writeFile(join(dir, '.orbit', 'state.json'), '{}')
    await mkdir(join(dir, 'node_modules'))
    await writeFile(join(dir, 'node_modules', 'x.js'), 'ignored')

    expect(await digestWorkspace(dir)).toEqual(before)
  })

  it('hashes symlink targets without following them', async () => {
    const dir = await project()
    await writeFile(join(dir, 'target.txt'), 'x')
    await symlink('target.txt', join(dir, 'link'))
    const before = await digestWorkspace(dir)
    await rm(join(dir, 'link'))
    await symlink('target.txt', join(dir, 'link2'))
    expect((await digestWorkspace(dir)).digest).not.toBe(before.digest)
  })

  it('refuses a tree over the file bound', async () => {
    const dir = await project()
    await writeFile(join(dir, 'a.txt'), 'one')
    await writeFile(join(dir, 'b.txt'), 'two')
    await expect(digestWorkspace(dir, { maxFiles: 1 })).rejects.toThrow(/more than 1 files/)
  })
})

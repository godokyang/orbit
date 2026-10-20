import { realpathSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { observationKey, observationKeyMaterial } from '../src/observation-key.js'
import type { FindingRecord } from '../src/types.js'

const dirs: string[] = []
async function root(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'orbit-key-'))
  dirs.push(dir)
  return dir
}
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

function finding(id: string, overrides: Partial<FindingRecord> = {}): FindingRecord {
  return {
    id,
    requirement: 'r',
    evidence: 'e',
    action: 'a',
    status: 'open',
    firstSeenCheck: 1,
    lastSeenCheck: 1,
    repeats: 0,
    binding: { inputDigest: 'i', artifactRoot: '/x', artifactDigest: 'a', requirement: 'r', evidence: 'e', action: 'a' },
    ...overrides,
  }
}

describe('observation key', () => {
  it('is deterministic and returns 64 hex characters', async () => {
    const dir = await root()
    const input = {
      inputDigest: 'input-1',
      artifactRoot: dir,
      artifactDigest: 'artifact-1',
      host: { status: 'idle', lastTurnId: 3, lastTurnStatus: 'completed', observations: [{ name: 'read' }] },
      findings: [finding('f1')],
    }
    const first = observationKey(input)
    expect(first).toMatch(/^[0-9a-f]{64}$/)
    expect(observationKey(input)).toBe(first)
  })

  it('ignores finding order but changes with finding content', async () => {
    const dir = await root()
    const base = {
      inputDigest: 'i',
      artifactRoot: dir,
      artifactDigest: 'a',
      host: {},
    }
    const first = observationKey({ ...base, findings: [finding('b'), finding('a')] })
    expect(observationKey({ ...base, findings: [finding('a'), finding('b')] })).toBe(first)
    expect(observationKey({ ...base, findings: [finding('a'), finding('b', { evidence: 'new' })] })).not.toBe(first)
    expect(observationKey({ ...base, findings: [finding('a'), finding('b', { status: 'resolved' })] })).not.toBe(first)
  })

  it('hashes only the newest ten observations', async () => {
    const dir = await root()
    const base = {
      inputDigest: 'i',
      artifactRoot: dir,
      artifactDigest: 'a',
      findings: [],
    }
    const observations = Array.from({ length: 11 }, (_, index) => ({ index }))
    const first = observationKey({ ...base, host: { observations } })
    const olderChanged = observationKey({ ...base, host: { observations: [{ index: 99 }, ...observations.slice(1)] } })
    expect(olderChanged).toBe(first)
    const lastChanged = observationKey({
      ...base,
      host: { observations: [...observations.slice(0, 10), { index: 100 }] },
    })
    expect(lastChanged).not.toBe(first)
  })

  it('canonicalizes object key order and exposes the material', async () => {
    const dir = await root()
    const input = {
      inputDigest: 'i',
      artifactRoot: dir,
      artifactDigest: 'a',
      host: { observations: [{ a: 1, b: 2 }] },
      findings: [],
      trigger: { b: 1, a: 2 },
    }
    const swapped = { ...input, trigger: { a: 2, b: 1 } }
    expect(observationKey(swapped)).toBe(observationKey(input))
    expect(observationKeyMaterial(input)).toMatchObject({ version: 1, artifact_root: realpathSync(dir) })
  })

  it('rejects an unresolvable artifact root', async () => {
    expect(() =>
      observationKey({ inputDigest: 'i', artifactRoot: '/does/not/exist', artifactDigest: 'a', host: {}, findings: [] }),
    ).toThrow(/not resolvable/)
  })
})

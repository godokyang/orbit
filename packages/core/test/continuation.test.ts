import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { TaskService, STOP_EVIDENCE_KEYS } from '../src/service.js'
import { isOrbitError } from '../src/errors.js'

const dirs: string[] = []
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

async function stoppedTask(): Promise<{ service: TaskService; dir: string; projectRoot: string }> {
  const projectRoot = await mkdtemp(join(tmpdir(), 'orbit-cont-'))
  dirs.push(projectRoot)
  let tick = Date.parse('2026-10-20T00:00:00Z')
  const { service } = await TaskService.start({
    projectRoot,
    rootSessionId: 'root-1',
    instruction: 'Original delivery.',
    clock: () => new Date((tick += 1000)),
  })
  await service.amend('First amendment.', { kind: 'explicit-text', verbatim: false, at: 't' })
  await service.requestStop('user')
  await service.confirmStop({
    artifactDigest: '',
    evidence: Object.fromEntries(STOP_EVIDENCE_KEYS.map((key) => [key, true])),
  })
  return { service, dir: service.store.dir, projectRoot }
}

describe('resume_from', () => {
  it('copies requirements and appends the continuation message as a new task', async () => {
    const previous = await stoppedTask()
    const { service, state } = await TaskService.resumeFrom(previous.dir, {
      projectRoot: previous.projectRoot,
      rootSessionId: 'root-1',
      instruction: 'Continue with the CLI.',
      source: { kind: 'continuation', verbatim: true, messageId: 'msg-continue', at: 't' },
    })

    expect(state.id).not.toBe((await previous.service.state()).id)
    expect(state.input.versions.map((version) => version.text)).toEqual([
      'Original delivery.',
      'First amendment.',
      'Continue with the CLI.',
    ])
    expect(state.input.versions[2]?.source.kind).toBe('continuation')
    expect(state.continuation).toMatchObject({ previousTaskId: (await previous.service.state()).id, sourceMessageId: 'msg-continue' })

    const old = await previous.service.state()
    expect(old.status).toBe('paused')
    expect(old.input.versions).toHaveLength(2)
    expect(await service.currentInputDigest()).not.toBe(await previous.service.currentInputDigest())
  })

  it('refuses to resume a running task or a different Root', async () => {
    const projectRoot = await mkdtemp(join(tmpdir(), 'orbit-cont-'))
    dirs.push(projectRoot)
    const { service } = await TaskService.start({ projectRoot, rootSessionId: 'root-1', instruction: 'work' })
    await expect(
      TaskService.resumeFrom(service.store.dir, { projectRoot, rootSessionId: 'root-1', instruction: 'again' }),
    ).rejects.toSatisfy((error) => isOrbitError(error) && error.code === 'invalid_state')

    const stopped = await stoppedTask()
    await expect(
      TaskService.resumeFrom(stopped.dir, { projectRoot: stopped.projectRoot, rootSessionId: 'root-2', instruction: 'again' }),
    ).rejects.toSatisfy((error) => isOrbitError(error) && error.code === 'invalid_state')
  })
})

describe('takeover', () => {
  it('records the reason, prior scope and snapshot without claiming prior execution', async () => {
    const projectRoot = await mkdtemp(join(tmpdir(), 'orbit-takeover-'))
    dirs.push(projectRoot)
    const { state } = await TaskService.start({
      projectRoot,
      rootSessionId: 'root-1',
      instruction: 'Take over the existing work.',
      source: { kind: 'user-message', verbatim: true, messageId: 'msg-1', sessionId: 'root-1', at: 't' },
      takeover: {
        reason: 'already implemented before supervision',
        priorScope: 'partial',
        messageId: 'msg-1',
        snapshot: { digest: 'abc', files: 3, bytes: 10, at: 't' },
      },
    })
    expect(state.takeover).toMatchObject({ reason: 'already implemented before supervision', priorScope: 'partial', messageId: 'msg-1' })
    expect(state.input.versions[0]?.source).toMatchObject({ kind: 'user-message', messageId: 'msg-1', verbatim: true })
  })
})

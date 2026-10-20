import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { TaskService } from '../src/service.js'
import { isOrbitError } from '../src/errors.js'

const dirs: string[] = []

async function startService(workspace?: Record<string, unknown>): Promise<TaskService> {
  const projectRoot = await mkdtemp(join(tmpdir(), 'orbit-dispute-'))
  dirs.push(projectRoot)
  let tick = Date.parse('2026-10-20T00:00:00Z')
  const { service } = await TaskService.start({
    projectRoot,
    rootSessionId: 'root-1',
    instruction: 'Deliver the slice.',
    clock: () => new Date((tick += 1000)),
    ...(workspace === undefined ? {} : { workspace: { artifactRoot: projectRoot, ...workspace } }),
  })
  return service
}

function findingResult(id: string): Record<string, unknown> {
  return {
    verdict: 'correct',
    reason: 'defect found',
    findings: [{ id, requirement: 'r', evidence: 'seen', action: 'fix' }],
    resolved_ids: [],
    next_check_seconds: 300,
    delivery: { ready: false, reason: 'not ready' },
  }
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('disputes and rulings', () => {
  it('adopting a ruling resolves the finding', async () => {
    const service = await startService()
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'A' })
    await service.recordCheckResult(1, findingResult('f1'))

    const dispute = await service.openDispute('f1', 'the evidence does not show a real gap')
    expect(dispute.status).toBe('pending')
    const ruled = await service.ruleDispute(dispute.id, 'adopt', 'false positive confirmed')
    expect(ruled.status).toBe('adopted')

    const status = await service.status()
    expect(status.findings.findings[0]).toMatchObject({ status: 'resolved', resolution: 'ruling' })
    expect(status.openDisputes).toHaveLength(0)
  })

  it('upholding a ruling keeps the finding open', async () => {
    const service = await startService()
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'A' })
    await service.recordCheckResult(1, findingResult('f2'))

    const dispute = await service.openDispute('f2', 'disagree')
    const ruled = await service.ruleDispute(dispute.id, 'uphold', 'defect is real')
    expect(ruled.status).toBe('upheld')

    const status = await service.status()
    expect(status.openFindings.map((finding) => finding.id)).toEqual(['f2'])
  })

  it('refuses a second pending dispute for the same finding', async () => {
    const service = await startService()
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'A' })
    await service.recordCheckResult(1, findingResult('f3'))
    await service.openDispute('f3', 'first')
    await expect(service.openDispute('f3', 'second')).rejects.toSatisfy(
      (error) => isOrbitError(error) && error.code === 'duplicate',
    )
  })
})

describe('workspace rebind', () => {
  it('accepts another worktree with the same git common dir and records history', async () => {
    const service = await startService({ realPath: '/repo/main', gitCommonDir: '/repo/.git', worktree: '/repo/main' })
    const state = await service.rebindWorkspace({
      artifactRoot: '/repo/wt-b',
      realPath: '/repo/wt-b',
      gitCommonDir: '/repo/.git',
      worktree: '/repo/wt-b',
      reason: 'move to the task worktree',
    })
    expect(state.workspace.artifactRoot).toBe('/repo/wt-b')
    expect(state.workspace.history).toHaveLength(1)
    expect(state.workspace.history[0]).toMatchObject({ from: state.projectRoot, to: '/repo/wt-b' })
  })

  it('accepts the same real path and rejects an unrelated repository', async () => {
    const service = await startService({ realPath: '/repo/main', gitCommonDir: '/repo/.git' })
    await expect(
      service.rebindWorkspace({ artifactRoot: '/repo/other', realPath: '/repo/main', reason: 'same path' }),
    ).resolves.toBeTruthy()

    await expect(
      service.rebindWorkspace({
        artifactRoot: '/elsewhere',
        realPath: '/elsewhere',
        gitCommonDir: '/elsewhere/.git',
        reason: 'unrelated',
      }),
    ).rejects.toSatisfy((error) => isOrbitError(error) && error.code === 'invalid_state')
  })
})

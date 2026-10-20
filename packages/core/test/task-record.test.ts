import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { TaskService } from '../src/service.js'
import { isOrbitError } from '../src/errors.js'
import type { StartTaskOptions } from '../src/service.js'

const dirs: string[] = []

export function makeClock(): () => Date {
  let tick = Date.parse('2026-10-20T00:00:00Z')
  return () => new Date((tick += 1000))
}

export async function startService(overrides: Partial<StartTaskOptions> = {}): Promise<TaskService> {
  const projectRoot = await mkdtemp(join(tmpdir(), 'orbit-core-'))
  dirs.push(projectRoot)
  const { service } = await TaskService.start({
    projectRoot,
    rootSessionId: 'root-session-1',
    instruction: 'Ship the migration slice.',
    clock: makeClock(),
    ...overrides,
  })
  return service
}

export async function prepareBoundMember(service: TaskService): Promise<{ unitId: string; memberId: string }> {
  const unit = await service.declareWorkUnit({ goal: 'Implement slice', acceptance: 'Tests pass' })
  const memberId = 'member-1'
  await service.registerMember({ id: memberId, requestedName: 'impl', workUnitId: unit.id })
  await service.finishWorkUnit({ id: unit.id, outcome: 'completed', summary: 'done' })
  await service.settleMember(memberId, 'completed')
  await service.acceptWorkUnit(unit.id)
  return { unitId: unit.id, memberId }
}

export function readyResult(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    verdict: 'complete',
    reason: 'delivered and verified',
    findings: [],
    resolved_ids: [],
    next_check_seconds: 300,
    delivery: { ready: true, reason: 'deliverable is present' },
    coverage: {
      complete: true,
      items: [
        { requirement: 'Implement slice', status: 'verified', evidence: 'tests pass' },
        { requirement: 'Report result', status: 'verified', evidence: 'final answer' },
      ],
    },
    ...overrides,
  }
}

export async function passingReview(service: TaskService, artifactDigest = 'artifact-A'): Promise<void> {
  await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest })
  await service.recordCheckResult(1, readyResult())
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('task record', () => {
  it('persists a complete task directory and a monotonic event log', async () => {
    const service = await startService()
    const state = await service.state()
    const tasksRoot = join(state.projectRoot, '.orbit', 'tasks')
    const eventsText = await readFile(join(tasksRoot, state.id, 'events.jsonl'), 'utf8')
    const events = eventsText
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line) as { seq: number; type: string })

    expect(state.status).toBe('running')
    expect(state.input.versions).toHaveLength(1)
    expect(events[0]?.type).toBe('task/created')
    expect(events.map((event) => event.seq)).toEqual([...events.map((event) => event.seq)].sort((a, b) => a - b))
    expect(new Set(events.map((event) => event.seq)).size).toBe(events.length)
  })

  it('writes task-local archives and rejects path traversal', async () => {
    const service = await startService()
    const path = await service.store.writeArchive('sessions/root.json', { format: 'test', events: 3 })
    expect(JSON.parse(await readFile(path, 'utf8'))).toEqual({ format: 'test', events: 3 })
    await expect(service.store.writeArchive('../escape.json', {})).rejects.toSatisfy(
      (error) => isOrbitError(error) && error.code === 'invalid_input',
    )
  })

  it('freezes the strict model list on the task record', async () => {
    const service = await startService({ allowedModels: ['p/m', 'p/n'] })
    const state = await service.state()
    expect(state.authorization).toEqual({ allowedModels: ['p/m', 'p/n'] })
  })

  it('increments the input version on amend and records the source', async () => {
    const service = await startService()
    const before = await service.currentInputDigest()
    const state = await service.amend('Also cover the CLI.', {
      kind: 'user-message',
      messageId: 'msg-2',
      sessionId: 'root-session-1',
      verbatim: true,
      at: new Date().toISOString(),
    })
    expect(state.input.versions.map((version) => version.version)).toEqual([1, 2])
    expect(state.input.versions[1]?.source.messageId).toBe('msg-2')
    expect(await service.currentInputDigest()).not.toBe(before)
  })
})

describe('member registration and stop fence', () => {
  it('registers and settles a member through a bound work unit', async () => {
    const service = await startService()
    const { unitId, memberId } = await prepareBoundMember(service)
    const units = await service.status()
    expect(units.members.members[0]).toMatchObject({ id: memberId, status: 'completed', workUnitId: unitId })
    expect(units.workUnits.units[0]?.status).toBe('accepted')
  })

  it('refuses registration after the stop fence is armed', async () => {
    const service = await startService()
    const unit = await service.declareWorkUnit({ goal: 'work', acceptance: 'done' })
    await service.requestStop('user')
    await expect(
      service.registerMember({ id: 'member-2', requestedName: 'late', workUnitId: unit.id }),
    ).rejects.toSatisfy((error) => isOrbitError(error) && error.code === 'stop_fenced')
  })

  it('refuses a unit declared for an older input version', async () => {
    const service = await startService()
    const unit = await service.declareWorkUnit({ goal: 'work', acceptance: 'done' })
    await service.amend('changed requirement', {
      kind: 'explicit-text',
      verbatim: true,
      at: new Date().toISOString(),
    })
    await expect(
      service.registerMember({ id: 'member-3', requestedName: 'stale', workUnitId: unit.id }),
    ).rejects.toSatisfy((error) => isOrbitError(error) && error.code === 'stale_input')
  })
})

describe('completion gate', () => {
  it('completes only after a ready manual check, settled members and full stop evidence', async () => {
    const service = await startService()
    await prepareBoundMember(service)
    await passingReview(service)

    await expect(service.requestCompletion('artifact-A')).resolves.toEqual({ ok: true })
    const state = await service.confirmStop({
      artifactDigest: 'artifact-A',
      evidence: { fence_persisted: true, root_idle: true, members_stopped: true, checks_settled: true },
    })
    expect(state.status).toBe('complete')
    expect(state.completion?.checkNumber).toBe(1)
    expect(state.completionInvalidation).toBeUndefined()
  })

  it('keeps stop_unconfirmed when evidence is missing, then confirms on retry', async () => {
    const service = await startService()
    await prepareBoundMember(service)
    await passingReview(service)
    await service.requestCompletion('artifact-A')

    const unconfirmed = await service.confirmStop({
      artifactDigest: 'artifact-A',
      evidence: { fence_persisted: true, root_idle: true, members_stopped: false, checks_settled: true },
    })
    expect(unconfirmed.status).toBe('stop_unconfirmed')
    expect(unconfirmed.stop?.confirmation?.missing).toEqual(['members_stopped'])

    const confirmed = await service.confirmStop({
      artifactDigest: 'artifact-A',
      evidence: { fence_persisted: true, root_idle: true, members_stopped: true, checks_settled: true },
    })
    expect(confirmed.status).toBe('complete')
  })

  it('rejects completion while a finding is open and accepts after it is resolved', async () => {
    const service = await startService()
    await prepareBoundMember(service)
    await passingReview(service)

    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await service.recordCheckResult(
      2,
      readyResult({
        verdict: 'correct',
        delivery: { ready: false, reason: 'not ready' },
        findings: [{ id: 'f1', requirement: 'Implement slice', evidence: 'missing test', action: 'add test' }],
      }),
    )

    const blocked = await service.requestCompletion('artifact-A')
    expect(blocked).toMatchObject({ ok: false, code: 'open_findings' })

    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await service.recordCheckResult(3, readyResult({ resolved_ids: ['f1'] }))
    await expect(service.requestCompletion('artifact-A')).resolves.toEqual({ ok: true })
  })

  it('rejects a completion whose artifact changed after the notice', async () => {
    const service = await startService()
    await prepareBoundMember(service)
    await passingReview(service)

    const result = await service.requestCompletion('artifact-B')
    expect(result).toMatchObject({ ok: false, code: 'stale_artifact' })
    const state = await service.state()
    expect(state.stop).toBeUndefined()
  })

  it('does not create a finalization notice without complete coverage', async () => {
    const service = await startService()
    await prepareBoundMember(service)
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    const { finalization } = await service.recordCheckResult(
      1,
      readyResult({
        coverage: {
          complete: false,
          items: [{ requirement: 'Implement slice', status: 'unverified', evidence: 'not looked at', gap_kind: 'not_checked' }],
        },
      }),
    )
    expect(finalization).toBe(false)
    const result = await service.requestCompletion('artifact-A')
    expect(result).toMatchObject({ ok: false, code: 'no_finalization_notice' })
  })
})

describe('finding binding', () => {
  it('counts a repeat only when all six binding dimensions are unchanged', async () => {
    const service = await startService()
    const finding = { id: 'f1', requirement: 'r', evidence: 'e', action: 'a' }

    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await service.recordCheckResult(1, readyResult({ verdict: 'correct', findings: [finding] }))
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await service.recordCheckResult(2, readyResult({ verdict: 'correct', findings: [finding] }))

    const status = await service.status()
    expect(status.findings.findings).toHaveLength(1)
    expect(status.findings.findings[0]?.repeats).toBe(1)
    expect(status.openFindings).toHaveLength(1)
  })

  it('reopens a resolved finding when its evidence changes', async () => {
    const service = await startService()
    const finding = { id: 'f1', requirement: 'r', evidence: 'e', action: 'a' }
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await service.recordCheckResult(1, readyResult({ verdict: 'correct', findings: [finding] }))
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await service.recordCheckResult(2, readyResult({ resolved_ids: ['f1'] }))
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-B' })
    await service.recordCheckResult(3, readyResult({ verdict: 'correct', findings: [{ ...finding, evidence: 'still bad' }] }))

    const status = await service.status()
    expect(status.findings.findings[0]?.status).toBe('open')
    expect(status.findings.findings[0]?.repeats).toBe(0)
  })
})

describe('check result validation', () => {
  it('refuses a result with duplicate coverage requirements', async () => {
    const service = await startService()
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await expect(
      service.recordCheckResult(
        1,
        readyResult({
          coverage: {
            complete: true,
            items: [
              { requirement: 'same', status: 'verified', evidence: 'one' },
              { requirement: ' same ', status: 'verified', evidence: 'two' },
            ],
          },
        }),
      ),
    ).rejects.toSatisfy((error) => isOrbitError(error) && error.code === 'check_result_invalid')

    const state = await service.state()
    expect(state.checks.inFlight).toBe(1)
  })

  it('refuses verified coverage without evidence', async () => {
    const service = await startService()
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'artifact-A' })
    await expect(
      service.recordCheckResult(
        1,
        readyResult({
          coverage: {
            complete: true,
            items: [{ requirement: 'r', status: 'verified', evidence: '   ' }],
          },
        }),
      ),
    ).rejects.toSatisfy((error) => isOrbitError(error) && error.code === 'check_result_invalid')
  })
})

describe('stop fence and check results', () => {
  it('refuses a check result that arrives after the stop fence', async () => {
    const service = await startService()
    await service.requestCheck({ role: 'reviewer', kind: 'artifact', trigger: 'manual', artifactDigest: 'A' })
    await service.requestStop('user')
    await expect(service.recordCheckResult(1, readyResult())).rejects.toSatisfy(
      (error) => isOrbitError(error) && error.code === 'stop_fenced',
    )
    const failed = await service.failCheck(1, { kind: 'stopped', message: 'checker disposed by stop' })
    expect(failed.status).toBe('failed')
  })
})

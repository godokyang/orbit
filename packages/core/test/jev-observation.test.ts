import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  JEV_OBSERVATION_QUESTIONS,
  buildJevObservationState,
  jevObservationKey,
  type JevObservationBuildInput,
} from '../src/jev-observation.js'
import type { CheckRecord, FindingRecord, TaskState } from '../src/types.js'

const dirs: string[] = []
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

async function input(): Promise<JevObservationBuildInput> {
  const root = await mkdtemp(join(tmpdir(), 'orbit-jev-'))
  dirs.push(root)
  const state: TaskState = {
    schemaVersion: 1,
    id: 'task-1',
    createdAt: '2026-10-20T00:00:00.000Z',
    updatedAt: '2026-10-20T00:01:00.000Z',
    status: 'running',
    projectRoot: root,
    workspace: { projectRoot: root, artifactRoot: root, boundAt: '2026-10-20T00:00:00.000Z', history: [] },
    root: { sessionId: 'root-1' },
    input: {
      versions: [
        { version: 1, text: 'Ship it.', sha256: 'a', source: { kind: 'explicit-text', verbatim: true, at: 't' }, recordedAt: 't' },
        { version: 2, text: 'Also test it.', sha256: 'b', source: { kind: 'user-message', messageId: 'm', verbatim: true, at: 't' }, recordedAt: 't' },
      ],
    },
    checks: { nextNumber: 3, inFlight: null },
    eventSeq: 1,
  }
  const finding: FindingRecord = {
    id: 'f1',
    requirement: 'r',
    evidence: 'e',
    action: 'a',
    status: 'open',
    firstSeenCheck: 1,
    lastSeenCheck: 1,
    repeats: 0,
    binding: { inputDigest: 'i', artifactRoot: root, artifactDigest: 'd', requirement: 'r', evidence: 'e', action: 'a' },
  }
  const check: CheckRecord = {
    schemaVersion: 1,
    taskId: 'task-1',
    number: 1,
    role: 'reviewer',
    kind: 'artifact',
    trigger: 'manual',
    status: 'completed',
    inputVersion: 2,
    inputDigest: 'i',
    artifactDigest: 'd',
    artifactRoot: root,
    requestedAt: 't',
    finishedAt: 't',
    result: {
      verdict: 'correct',
      reason: 'gap',
      findings: [{ id: 'f1', requirement: 'r', evidence: 'e', action: 'a' }],
      resolvedIds: [],
      nextCheckSeconds: 300,
      delivery: { ready: false, reason: 'gap' },
    },
  }
  const operations = Array.from({ length: 25 }, (_, index) => ({
    id: `c${index + 1}`,
    seq: index + 1,
    turn: 1,
    step: 1,
    name: 'read',
    declaredIntent: 'unknown',
    target: `f${index}.ts`,
    status: 'ok' as const,
    startedAt: index,
    finishedAt: index + 1,
    durationMs: 1,
  }))
  return {
    state,
    members: {
      schemaVersion: 1,
      taskId: 'task-1',
      members: [
        {
          id: 'member-1',
          requestedName: 'impl',
          workUnitId: 'wu-1',
          inputVersion: 2,
          artifactRoot: root,
          status: 'registered',
          registeredAt: 't',
        },
      ],
    },
    units: {
      schemaVersion: 1,
      taskId: 'task-1',
      units: [
        {
          id: 'wu-1',
          createdAt: 't',
          updatedAt: 't',
          goal: 'Build',
          requirementRefs: [],
          scope: { allowedPaths: [], allowedCommands: [] },
          acceptance: 'works',
          dependencies: [],
          execution: 'delegate',
          status: 'bound',
          inputVersion: 2,
          artifactRoot: root,
          attempts: [],
        },
      ],
    },
    checks: [check],
    findings: { schemaVersion: 1, taskId: 'task-1', findings: [finding] },
    window: {
      operations: operations.slice(-20),
      omittedOlderOperations: 5,
      historyGap: false,
      crashGap: { seq: 25 },
    },
    asyncJobs: 1,
    artifactDigest: 'd',
    now: new Date('2026-10-20T00:05:00.000Z'),
  }
}

describe('JEV observation input', () => {
  it('keeps requirements, members, units, window and findings without tool payloads', async () => {
    const built = await input()
    const state = buildJevObservationState(built)
    expect(state).toMatchObject({
      input_version: 'jev-observation-input-4',
      instruction: { original: 'Ship it.', amendments: [{ version: 2, text: 'Also test it.', source_kind: 'user-message' }] },
      host: { status: 'running', active_tools: 0, async_jobs: 1 },
      findings: { open: [{ id: 'f1' }] },
      checks: { latest: { number: 1, verdict: 'correct', delivery_ready: false } },
    })
    expect((state.window as { operations: unknown[] }).operations).toHaveLength(20)
    expect((state.window as { omitted_older_operations: number }).omitted_older_operations).toBe(5)
    expect(JSON.stringify(state)).not.toContain('tool input')
    expect((state.task as { elapsed_ms: number }).elapsed_ms).toBe(300_000)
  })

  it('has a deterministic key that changes with substantive material', async () => {
    const built = await input()
    const key = jevObservationKey(built)
    expect(key).toMatch(/^[0-9a-f]{64}$/)
    expect(jevObservationKey(built)).toBe(key)

    const changedOperation = {
      ...built,
      window: {
        ...built.window,
        operations: built.window.operations.map((operation, index) =>
          index === built.window.operations.length - 1 ? { ...operation, status: 'error' as const } : operation,
        ),
      },
    }
    expect(jevObservationKey(changedOperation)).not.toBe(key)

    const amended = structuredClone(built)
    amended.state.input.versions[1]!.text = 'Changed amendment.'
    expect(jevObservationKey(amended)).not.toBe(key)
  })

  it('defines the two observation questions with both criteria', () => {
    expect(JEV_OBSERVATION_QUESTIONS.map((question) => question.id)).toEqual(['stuck', 'off_track'])
    for (const question of JEV_OBSERVATION_QUESTIONS) {
      expect(question.instruction.length).toBeGreaterThan(20)
      expect(question.trueCriterion.length).toBeGreaterThan(5)
      expect(question.falseCriterion.length).toBeGreaterThan(5)
    }
  })
})

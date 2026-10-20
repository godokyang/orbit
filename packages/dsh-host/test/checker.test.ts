import { describe, expect, it, vi } from 'vitest'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { SubagentRuntime } from '@deepseek-ai/dsh-subagent'
import type { TaskState } from '@orbit/core'
import { buildCheckerPrompt, buildProcessCheckerPrompt, extractCheckerJson, runChecker } from '../src/checker.js'

function state(): TaskState {
  return {
    schemaVersion: 1,
    id: 'task-1',
    createdAt: '2026-10-20T00:00:00.000Z',
    updatedAt: '2026-10-20T00:00:00.000Z',
    status: 'running',
    projectRoot: '/repo',
    workspace: { projectRoot: '/repo', artifactRoot: '/repo', boundAt: '2026-10-20T00:00:00.000Z', history: [] },
    root: { sessionId: 'root-1' },
    input: {
      versions: [
        { version: 1, text: 'Original ask', sha256: 'a', source: { kind: 'explicit-text', verbatim: true, at: 't' }, recordedAt: 't' },
        {
          version: 2,
          text: 'Amendment ask',
          sha256: 'b',
          source: { kind: 'user-message', messageId: 'm2', verbatim: true, at: 't' },
          recordedAt: 't',
        },
      ],
    },
    checks: { nextNumber: 1, inFlight: null },
    eventSeq: 1,
  }
}

function fakeSubagents(result: { output: Array<{ type: 'text'; text: string }>; stopReason?: string }, provider = true): SubagentRuntime {
  return {
    getProvider: () => (provider ? {} : undefined),
    startActivation: vi.fn(async () => ({
      childId: 'checker-1',
      result: Promise.resolve({ output: result.output, stopReason: result.stopReason ?? 'completed' }),
      dispose: vi.fn(async () => undefined),
    })),
  } as unknown as SubagentRuntime
}

describe('checker prompt', () => {
  it('includes every requirement version and the artifact digest', () => {
    const prompt = buildCheckerPrompt({ state: state(), taskDir: '/repo/.orbit/tasks/task-1', artifactDigest: 'digest-1' })
    expect(prompt).toContain('Original ask')
    expect(prompt).toContain('Amendment v2')
    expect(prompt).toContain('digest-1')
    expect(prompt).toContain('/repo/.orbit/tasks/task-1')
    expect(prompt).toContain('coverage')
  })
})

describe('process checker prompt', () => {
  it('carries the signal and recent operations without judging delivery', () => {
    const prompt = buildProcessCheckerPrompt({
      state: state(),
      taskDir: '/repo/.orbit/tasks/task-1',
      signal: [{ id: 'stuck', probability: 0.9 }],
      operations: [{ name: 'read', status: 'ok', target: 'src/a.ts', declaredIntent: 'inspect' }],
    })
    expect(prompt).toContain('stuck=0.90')
    expect(prompt).toContain('read [ok] target=src/a.ts')
    expect(prompt).toContain('coverage is optional')
    expect(prompt).toContain('do not judge final delivery readiness')
  })
})

describe('checker output', () => {
  it('extracts raw and fenced JSON', () => {
    expect(extractCheckerJson('{"verdict":"continue"}')).toEqual({ verdict: 'continue' })
    expect(extractCheckerJson('```json\n{"verdict":"complete"}\n```')).toEqual({ verdict: 'complete' })
    expect(() => extractCheckerJson('no json here')).toThrow(/no JSON object/)
  })

  it('runs the dsh-sdk activation, exposes it and disposes it', async () => {
    const subagents = fakeSubagents({ output: [{ type: 'text', text: '{"verdict":"continue","reason":"more"}' }] })
    const seen: unknown[] = []
    const result = await runChecker({
      subagents,
      parent: { id: 'root-1' } as Agent,
      prompt: 'check',
      cwd: '/repo',
      signal: new AbortController().signal,
      onActivation: (activation) => seen.push(activation),
    })
    expect(result).toEqual({ verdict: 'continue', reason: 'more' })
    expect(seen).toHaveLength(1)
    expect((seen[0] as { dispose: { mock: { calls: unknown[] } } }).dispose.mock.calls).toHaveLength(1)
  })

  it('fails closed when the dsh-sdk provider is absent', async () => {
    await expect(
      runChecker({
        subagents: fakeSubagents({ output: [] }, false),
        parent: { id: 'root-1' } as Agent,
        prompt: 'check',
        cwd: '/repo',
        signal: new AbortController().signal,
      }),
    ).rejects.toThrow(/dsh-sdk/)
  })

  it('refuses a non-completed checker run', async () => {
    await expect(
      runChecker({
        subagents: fakeSubagents({ output: [], stopReason: 'error' }),
        parent: { id: 'root-1' } as Agent,
        prompt: 'check',
        cwd: '/repo',
        signal: new AbortController().signal,
      }),
    ).rejects.toThrow(/stopped with error/)
  })
})

import { describe, expect, it } from 'vitest'
import type { SessionEvent } from '@deepseek-ai/dsh-session'
import {
  applyObservation,
  observationStateSchema,
  observationWindow,
  orbitObservationDefinition,
  type ObservationState,
} from '../src/observation.js'

function event(seq: number, type: string, data: unknown): SessionEvent {
  return { seq, time: 1_000 + seq, type, data } as unknown as SessionEvent
}

function initial(): ObservationState {
  return orbitObservationDefinition.init({ cwd: '/repo' } as never, 0 as never)
}

function call(seq: number, callId: string, name: string, args: Record<string, unknown>): SessionEvent {
  return event(seq, 'tool/call', { turn: 1, step: 1, callId, name, arguments: JSON.stringify(args) })
}

function result(seq: number, callId: string, options: { error?: boolean; text?: string } = {}): SessionEvent {
  return event(seq, 'tool/result', {
    turn: 1,
    step: 1,
    message: {
      toolCallId: callId,
      isError: options.error ?? false,
      content: options.text === undefined ? [] : [{ type: 'text', text: options.text }],
    },
  })
}

describe('observation projection', () => {
  it('records tool operations with declared intent and artifact-relative targets', () => {
    let state = initial()
    state = applyObservation(state, event(1, 'turn/start', { turn: 1 }))
    state = applyObservation(state, event(2, 'step/start', { turn: 1, step: 1 }))
    state = applyObservation(state, call(3, 'c1', 'bash', { description: 'run tests', command: 'pnpm test' }))
    state = applyObservation(state, call(4, 'c2', 'read', { file_path: 'src/a.ts' }))
    state = applyObservation(state, call(5, 'c3', 'read', { file_path: '/etc/hosts' }))
    state = applyObservation(state, result(6, 'c1'))
    state = applyObservation(state, result(7, 'c2', { error: true, text: 'denied' }))
    state = applyObservation(state, result(8, 'c3'))

    expect(state.operations.map((operation) => operation.name)).toEqual(['bash', 'read', 'read'])
    expect(state.operations[0]).toMatchObject({ declaredIntent: 'run tests', target: 'unknown', status: 'ok' })
    expect(state.operations[1]).toMatchObject({ target: 'src/a.ts', status: 'error' })
    expect(state.operations[2]).toMatchObject({ target: 'outside-workspace', status: 'ok' })
    expect(state.operations[0]?.durationMs).toBe(3)
    expect(state.activeTools).toBe(0)
    expect(state.lastTurnStatus).toBe('open')
  })

  it('classifies aborted and interrupted results', () => {
    let state = initial()
    state = applyObservation(state, call(1, 'c1', 'bash', { description: 'sleep' }))
    state = applyObservation(state, result(2, 'c1', { error: true, text: 'tool call aborted by parent' }))
    state = applyObservation(state, call(3, 'c2', 'bash', { description: 'sleep' }))
    state = applyObservation(state, result(4, 'c2', { error: true, text: 'outcome is unknown' }))
    expect(state.operations.map((operation) => operation.status)).toEqual(['aborted', 'interrupted'])
  })

  it('marks open operations interrupted and records a crash gap', () => {
    let state = initial()
    state = applyObservation(state, call(1, 'c1', 'bash', { description: 'work' }))
    state = applyObservation(state, event(2, 'turn/end', { turn: 1, reason: { kind: 'interrupted' } }))
    expect(state.operations[0]?.status).toBe('interrupted')
    expect(state.crashGap).toEqual({ seq: 2 })
    expect(state.activeTools).toBe(0)
  })

  it('keeps the last 50 operations and reports omitted history', () => {
    let state = initial()
    for (let index = 1; index <= 60; index += 1) {
      state = applyObservation(state, call(index, `c${index}`, 'read', { file_path: `f${index}.ts` }))
    }
    expect(state.operations).toHaveLength(50)
    expect(state.omittedOlder).toBe(10)
    expect(state.operations[0]?.id).toBe('c11')
  })

  it('slices a bounded window with explicit gaps', () => {
    let state = initial()
    for (let index = 1; index <= 30; index += 1) {
      state = applyObservation(state, call(index, `c${index}`, 'read', { file_path: `f${index}.ts` }))
    }
    state = applyObservation(state, event(31, 'turn/end', { turn: 1, reason: { kind: 'interrupted' } }))

    const window = observationWindow(state, 0)
    expect(window.operations).toHaveLength(20)
    expect(window.omittedOlderOperations).toBe(10)
    expect(window.crashGap?.seq).toBe(31)

    const recent = observationWindow(state, 25)
    expect(recent.operations.map((operation) => operation.id)).toEqual(['c26', 'c27', 'c28', 'c29', 'c30'])
    expect(recent.historyGap).toBe(false)

    const gap = observationWindow(state, 5)
    expect(gap.historyGap).toBe(false)
  })

  it('validates the persisted shape', () => {
    const state = initial()
    expect(observationStateSchema.parse(state)).toMatchObject({ operations: [], targetRoot: '/repo' })
  })
})

import { describe, expect, it } from 'vitest'
import { projectSession, unavailableSession } from '../src/sessions-projection.js'
import type { ObservationState } from '../src/observation.js'

const snapshot = {
  session: { id: 'session-1', version: 4 },
  events: [
    { seq: 1, type: 'turn/start', data: { turn: 1 } },
    { seq: 2, type: 'user/message', data: { id: 'u1', role: 'user', content: [{ type: 'text', text: 'Build it' }], source: { kind: 'user' } } },
    { seq: 3, type: 'user/message', data: { id: 'u2', role: 'user', content: [{ type: 'text', text: 'runtime context' }], source: { kind: 'runtime-context' } } },
    { seq: 4, type: 'assistant/message', data: { turn: 1, step: 1, message: { content: [{ type: 'text', text: 'Working' }] } } },
    { seq: 5, type: 'turn/end', data: { turn: 1, reason: { kind: 'completed' } } },
  ],
}

const observation: ObservationState = {
  operations: [
    { id: 'c1', seq: 6, turn: 1, step: 1, name: 'bash', declaredIntent: 'test', target: 'unknown', status: 'ok', startedAt: 10, finishedAt: 20 },
  ],
  omittedOlder: 0,
  activeTools: 0,
  turn: 1,
  step: 1,
  lastTurnId: 1,
  lastTurnStatus: 'completed',
}

describe('session projection', () => {
  it('projects visible text, real user messages, activities, questions and deliveries', () => {
    const projected = projectSession(snapshot as never, observation, { questions: [{ id: 'q1', question: 'Which?' }] })
    expect(projected).toMatchObject({ session_id: 'session-1', as_of_seq: 5, state: 'available' })
    expect(projected.visible_text).toEqual([{ seq: 4, text: 'Working' }])
    expect(projected.user_messages).toEqual([{ id: 'u1', seq: 2, text: 'Build it' }])
    expect(projected.activities).toEqual([
      { seq: 6, name: 'bash', status: 'ok', target: 'unknown', declared_intent: 'test' },
    ])
    expect(projected.questions[0]).toMatchObject({ id: 'q1', question: 'Which?' })
    expect(projected.deliveries).toEqual([{ seq: 5, kind: 'turn_completed' }])
  })

  it('returns an explicit unavailable projection', () => {
    expect(unavailableSession('missing')).toMatchObject({ session_id: 'missing', state: 'unavailable', as_of_seq: -1 })
  })
})

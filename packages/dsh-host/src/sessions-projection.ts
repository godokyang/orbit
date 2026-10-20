import type { ObservationState } from './observation.js'

export interface SessionVisibleText {
  seq: number
  text: string
}

export interface SessionUserMessage {
  id: string
  seq: number
  text: string
}

export interface SessionQuestion {
  id?: string
  seq?: number
  question?: string
  raw?: unknown
}

export interface ProjectedSession {
  session_id: string
  as_of_seq: number
  state: 'available' | 'unavailable'
  visible_text: SessionVisibleText[]
  user_messages: SessionUserMessage[]
  activities: Array<{ seq: number; name: string; status: string; target: string; declared_intent: string }>
  questions: SessionQuestion[]
  deliveries: Array<{ seq: number; kind: string }>
}

interface SnapshotEvent {
  seq: number
  type: string
  data: Record<string, unknown>
}

interface Snapshot {
  session: { id?: string; version?: unknown }
  events: readonly SnapshotEvent[]
}

function textBlocks(value: unknown): string {
  const blocks = Array.isArray(value) ? value : []
  return blocks
    .filter((block): block is { type?: string; text?: string } => typeof block === 'object' && block !== null)
    .filter((block) => block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text ?? '')
    .join('')
}

/**
 * Bounded, read-only projection of one DSH session. It reads committed events
 * and the observation unit; it never mutates the session or replays a turn.
 */
export function projectSession(
  snapshot: Snapshot,
  observation?: ObservationState,
  userQuestions?: unknown,
): ProjectedSession {
  const visibleText: SessionVisibleText[] = []
  const userMessages: SessionUserMessage[] = []
  const deliveries: Array<{ seq: number; kind: string }> = []
  for (const event of snapshot.events) {
    const data = event.data ?? {}
    if (event.type === 'assistant/message') {
      const message = (data.message ?? {}) as { content?: unknown }
      const text = textBlocks(message.content)
      if (text.length > 0) visibleText.push({ seq: event.seq as unknown as number, text })
    } else if (event.type === 'user/message') {
      const source = data.source as { kind?: string } | undefined
      if (source?.kind !== 'user') continue
      const text = textBlocks(data.content)
      if (text.length === 0) continue
      userMessages.push({
        id: String(data.id ?? `seq-${String(event.seq)}`),
        seq: event.seq as unknown as number,
        text,
      })
    } else if (event.type === 'turn/end') {
      const reason = data.reason as { kind?: string } | undefined
      if (reason?.kind === 'completed') deliveries.push({ seq: event.seq as unknown as number, kind: 'turn_completed' })
    }
  }
  const activities = (observation?.operations ?? []).map((operation) => ({
    seq: operation.seq,
    name: operation.name,
    status: operation.status,
    target: operation.target,
    declared_intent: operation.declaredIntent,
  }))
  const questions: SessionQuestion[] =
    userQuestions === undefined
      ? []
      : Array.isArray((userQuestions as { questions?: unknown[] }).questions)
        ? ((userQuestions as { questions: Array<Record<string, unknown>> }).questions).map((question) => ({
            ...(typeof question.id === 'string' ? { id: question.id } : {}),
            ...(typeof question.question === 'string' ? { question: question.question } : {}),
            raw: question,
          }))
        : [{ raw: userQuestions }]
  const last = snapshot.events.at(-1)?.seq
  return {
    session_id: String(snapshot.session.id ?? 'unknown'),
    as_of_seq: last === undefined ? -1 : (last as unknown as number),
    state: 'available',
    visible_text: visibleText,
    user_messages: userMessages,
    activities,
    questions,
    deliveries,
  }
}

export function unavailableSession(sessionId: string): ProjectedSession {
  return {
    session_id: sessionId,
    as_of_seq: -1,
    state: 'unavailable',
    visible_text: [],
    user_messages: [],
    activities: [],
    questions: [],
    deliveries: [],
  }
}

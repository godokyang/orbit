import { z } from 'zod'
import type { SessionEvent, SessionHeader, SessionLogOffset } from '@deepseek-ai/dsh-session'
import type { ProjectionDefinition } from '@deepseek-ai/dsh-session-projection'
import { resolve, relative, isAbsolute } from 'node:path'

export type ObservationStatus = 'ok' | 'error' | 'aborted' | 'interrupted' | 'not_observed'

export interface ObservationOperation {
  id: string
  seq: number
  turn: number
  step: number
  name: string
  declaredIntent: string
  target: string
  status: ObservationStatus
  startedAt: number
  finishedAt?: number
  durationMs?: number
}

export interface ObservationState {
  /** Newest-last ring of the last 50 operations. */
  operations: ObservationOperation[]
  /** Operations dropped from the retained ring. */
  omittedOlder: number
  activeTools: number
  turn: number | null
  step: number | null
  lastTurnId: number | null
  lastTurnStatus: string | null
  /** Set when the log records `turn/end {kind:'interrupted'}`. */
  crashGap?: { seq: number }
  /** Session cwd used to relativize file targets; plain JSON, restored with state. */
  targetRoot?: string
}

declare module '@deepseek-ai/dsh-session-projection' {
  interface SessionProjectionStateMap {
    orbitObservation: ObservationState
  }
}

const MAX_OPERATIONS = 50

const operationSchema = z.object({
  id: z.string(),
  seq: z.number(),
  turn: z.number(),
  step: z.number(),
  name: z.string(),
  declaredIntent: z.string(),
  target: z.string(),
  status: z.enum(['ok', 'error', 'aborted', 'interrupted', 'not_observed']),
  startedAt: z.number(),
  finishedAt: z.number().optional(),
  durationMs: z.number().optional(),
})

export const observationStateSchema = z.object({
  operations: z.array(operationSchema),
  omittedOlder: z.number(),
  activeTools: z.number(),
  turn: z.number().nullable(),
  step: z.number().nullable(),
  lastTurnId: z.number().nullable(),
  lastTurnStatus: z.string().nullable(),
  crashGap: z.object({ seq: z.number() }).optional(),
  targetRoot: z.string().optional(),
})

function parseArguments(raw: string): Record<string, unknown> | undefined {
  try {
    const parsed: unknown = JSON.parse(raw)
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

function targetOf(args: Record<string, unknown> | undefined, cwd: string | undefined): string {
  if (args === undefined) return 'unknown'
  const file = args.file_path
  if (typeof file !== 'string' || cwd === undefined) return 'unknown'
  const absolute = isAbsolute(file) ? file : resolve(cwd, file)
  const rel = relative(cwd, absolute)
  if (rel.startsWith('..') || isAbsolute(rel)) return 'outside-workspace'
  return rel
}

function resultStatus(message: { isError?: boolean; content?: Array<{ type: string; text?: string }> }): ObservationStatus {
  const text = (message.content ?? [])
    .filter((block) => block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text ?? '')
    .join('\n')
  if (/tool call aborted/i.test(text)) return 'aborted'
  if (/outcome is unknown/i.test(text)) return 'interrupted'
  return message.isError === true ? 'error' : 'ok'
}

function trim(state: ObservationState): ObservationState {
  if (state.operations.length <= MAX_OPERATIONS) return state
  const dropped = state.operations.length - MAX_OPERATIONS
  return {
    ...state,
    operations: state.operations.slice(dropped),
    omittedOlder: state.omittedOlder + dropped,
  }
}

/** Pure fold from committed DSH session events into the observation ring. */
export function applyObservation(state: ObservationState, event: SessionEvent): ObservationState {
  const data = event.data as Record<string, unknown>
  switch (event.type) {
    case 'turn/start':
      return { ...state, turn: data.turn as number, step: null, lastTurnId: data.turn as number, lastTurnStatus: 'open' }
    case 'step/start':
      return { ...state, turn: data.turn as number, step: data.step as number }
    case 'turn/end': {
      const reason = data.reason as { kind?: string } | undefined
      const kind = reason?.kind ?? 'unknown'
      const interrupted = kind === 'interrupted'
      const operations = interrupted
        ? state.operations.map((operation) =>
            operation.status === 'not_observed' && operation.turn === (data.turn as number)
              ? { ...operation, status: 'interrupted' as const }
              : operation,
          )
        : state.operations
      const active = operations.filter((operation) => operation.status === 'not_observed').length
      return {
        ...state,
        operations,
        activeTools: active,
        lastTurnStatus: kind,
        ...(interrupted ? { crashGap: { seq: event.seq as unknown as number } } : {}),
      }
    }
    case 'tool/call': {
      const args = parseArguments(String(data.arguments ?? ''))
      const operation: ObservationOperation = {
        id: String(data.callId),
        seq: event.seq as unknown as number,
        turn: data.turn as number,
        step: data.step as number,
        name: String(data.name),
        declaredIntent: typeof args?.description === 'string' ? args.description : 'unknown',
        target: targetOf(args, state.targetRoot),
        status: 'not_observed',
        startedAt: event.time,
      }
      return trim({
        ...state,
        operations: [...state.operations, operation],
        activeTools: state.activeTools + 1,
      })
    }
    case 'tool/result': {
      const message = data.message as { toolCallId?: string; isError?: boolean; content?: Array<{ type: string; text?: string }> }
      const index = state.operations.findIndex((operation) => operation.id === message.toolCallId)
      if (index < 0) return state
      const operation = state.operations[index]!
      const status = resultStatus(message)
      const updated: ObservationOperation = {
        ...operation,
        status,
        finishedAt: event.time,
        durationMs: event.time - operation.startedAt,
      }
      const operations = [...state.operations]
      operations[index] = updated
      return {
        ...state,
        operations,
        activeTools: Math.max(0, state.activeTools - 1),
      }
    }
    default:
      return state
  }
}

export const orbitObservationDefinition: ProjectionDefinition<'orbitObservation', ObservationState> = {
  key: 'orbitObservation',
  stateVersion: 1,
  // DSH and Orbit may resolve different zod minor instances; the schema is
  // structurally identical at runtime, only the nominal type differs.
  stateSchema: observationStateSchema as never,
  init(header: SessionHeader, _inherited: SessionLogOffset): ObservationState {
    const state: ObservationState = {
      operations: [],
      omittedOlder: 0,
      activeTools: 0,
      turn: null,
      step: null,
      lastTurnId: null,
      lastTurnStatus: null,
      targetRoot: header.cwd,
    }
    return state
  },
  apply(state, event) {
    return applyObservation(state, event)
  },
}

export interface ObservationWindow {
  operations: ObservationOperation[]
  omittedOlderOperations: number
  historyGap: boolean
  crashGap?: { seq: number }
}

/** Window from the last checked seq: newest 20 operations, explicit gaps. */
export function observationWindow(state: ObservationState, cursorSeq = 0): ObservationWindow {
  const all = state.operations
  const oldest = all[0]?.seq
  const historyGap = cursorSeq > 0 && oldest !== undefined && cursorSeq < oldest - 1
  const eligible = all.filter((operation) => operation.seq > cursorSeq)
  const operations = eligible.slice(-20)
  return {
    operations,
    omittedOlderOperations: eligible.length - operations.length,
    historyGap,
    ...(state.crashGap !== undefined && state.crashGap.seq > cursorSeq ? { crashGap: state.crashGap } : {}),
  }
}

/** Wire protocol for the private Orbit control socket (newline-delimited JSON). */

export const CONTROL_SOCKET_FILE = 'orbit.sock'
export const CONTROL_MAX_BYTES = 1_048_576

export type ControlMethod = 'status' | 'events' | 'stop' | 'sessions' | 'questions' | 'answer'

export interface ControlRequest {
  id: string
  method: ControlMethod
  /** Optional task id; defaults to the latest task. */
  task?: string
  /** Question record id for method=answer. */
  question?: string
  selected?: string[]
  custom?: string
}

export interface ControlError {
  code: string
  message: string
}

export type ControlResponse =
  | { id: string; ok: true; result: unknown }
  | { id: string; ok: false; error: ControlError }

export function isControlResponse(value: unknown): value is ControlResponse {
  if (typeof value !== 'object' || value === null) return false
  const record = value as Record<string, unknown>
  if (typeof record.id !== 'string' || typeof record.ok !== 'boolean') return false
  if (record.ok === true) return 'result' in record
  return typeof record.error === 'object' && record.error !== null
}

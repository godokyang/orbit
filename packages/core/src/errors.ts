export type OrbitErrorCode =
  | 'not_found'
  | 'invalid_state'
  | 'invalid_input'
  | 'check_result_invalid'
  | 'check_in_flight'
  | 'stale_input'
  | 'stale_artifact'
  | 'stop_fenced'
  | 'duplicate'
  | 'io_error'
  | 'completion_rejected'

export class OrbitError extends Error {
  readonly code: OrbitErrorCode
  readonly details?: unknown

  constructor(code: OrbitErrorCode, message: string, details?: unknown) {
    super(message)
    this.name = 'OrbitError'
    this.code = code
    this.details = details
  }
}

export function isOrbitError(error: unknown): error is OrbitError {
  return error instanceof OrbitError
}

import { newId } from './ids.js'

export const JUDGMENT_PROVIDER = 'typesafe'
export const DEFAULT_JUDGMENT_MODEL = 'jev-latest'
export const DEFAULT_JUDGMENT_ENDPOINT = 'https://api.typesafe.ai/v1/systemone'

export interface JudgmentQuestion {
  id: string
  instruction: string
  trueCriterion: string
  falseCriterion: string
}

export interface JudgmentRequest {
  /** Bounded state material for the provider. */
  state: Record<string, unknown>
  questions: JudgmentQuestion[]
}

export interface JudgmentAnswered {
  status: 'answered'
  callId: string
  provider: typeof JUDGMENT_PROVIDER
  model: string
  answers: Record<string, number>
  usage?: unknown
}

export interface JudgmentUnavailable {
  status: 'unavailable'
  callId: string
  provider: typeof JUDGMENT_PROVIDER
  reason: string
  httpStatus?: number
  actualModel?: string
  usage?: unknown
}

export type JudgmentResult = JudgmentAnswered | JudgmentUnavailable

export interface TypeSafeOptions {
  apiKey: string
  endpoint?: string
  model?: string
  timeoutMs?: number
  fetchImpl?: typeof fetch
}

interface WirePayload {
  model?: unknown
  answers?: unknown
  usage?: unknown
}

function unavailable(callId: string, reason: string, extra: Partial<JudgmentUnavailable> = {}): JudgmentUnavailable {
  return { status: 'unavailable', callId, provider: JUDGMENT_PROVIDER, reason, ...extra }
}

/**
 * TypeSafe System One adapter. Owns auth, transport, timeout and response
 * mapping only; any failure or unmappable answer is `unavailable` with no
 * partial answers, never a low score.
 */
export class TypeSafeJudgmentClient {
  readonly model: string
  private readonly endpoint: string
  private readonly apiKey: string
  private readonly timeoutMs: number
  private readonly fetchImpl: typeof fetch

  constructor(options: TypeSafeOptions) {
    this.apiKey = options.apiKey
    this.endpoint = options.endpoint ?? DEFAULT_JUDGMENT_ENDPOINT
    this.model = options.model ?? DEFAULT_JUDGMENT_MODEL
    this.timeoutMs = options.timeoutMs ?? 20_000
    this.fetchImpl = options.fetchImpl ?? fetch
  }

  async judge(request: JudgmentRequest): Promise<JudgmentResult> {
    const callId = newId('judgment')
    if (this.apiKey.trim().length === 0) return unavailable(callId, 'TYPESAFE_API_KEY is missing')
    if (request.questions.length === 0) return unavailable(callId, 'no judgment questions were provided')

    const body = {
      model: this.model,
      state: request.state,
      questions: request.questions.map((question) => ({
        id: question.id,
        instruction: question.instruction,
        true_criterion: question.trueCriterion,
        false_criterion: question.falseCriterion,
      })),
    }

    let response: Response
    try {
      response = await this.fetchImpl(this.endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${this.apiKey}` },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      })
    } catch (error) {
      return unavailable(callId, `judgment request failed: ${(error as Error).message}`)
    }

    let payload: WirePayload
    try {
      payload = (await response.json()) as WirePayload
    } catch {
      return unavailable(callId, 'judgment response was not JSON', { httpStatus: response.status })
    }

    const actualModel = typeof payload.model === 'string' && payload.model.length > 0 ? payload.model : undefined
    if (!response.ok) {
      return unavailable(callId, `judgment request returned HTTP ${response.status}`, {
        httpStatus: response.status,
        ...(actualModel === undefined ? {} : { actualModel }),
        ...(payload.usage === undefined ? {} : { usage: payload.usage }),
      })
    }
    if (actualModel === undefined) return unavailable(callId, 'judgment response has no model identity', { httpStatus: response.status })
    if (payload.answers === null || typeof payload.answers !== 'object') {
      return unavailable(callId, 'judgment response has no answers', { httpStatus: response.status, actualModel })
    }

    const answers: Record<string, number> = {}
    for (const question of request.questions) {
      const answer = (payload.answers as Record<string, unknown>)[question.id]
      const probability =
        answer !== null && typeof answer === 'object' ? (answer as { noul?: unknown }).noul : undefined
      if (typeof probability !== 'number' || !Number.isFinite(probability) || probability < 0 || probability > 1) {
        return unavailable(callId, `judgment answer for ${question.id} is missing or invalid`, {
          httpStatus: response.status,
          actualModel,
          ...(payload.usage === undefined ? {} : { usage: payload.usage }),
        })
      }
      answers[question.id] = probability
    }

    return {
      status: 'answered',
      callId,
      provider: JUDGMENT_PROVIDER,
      model: actualModel,
      answers,
      ...(payload.usage === undefined ? {} : { usage: payload.usage }),
    }
  }
}

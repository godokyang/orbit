import { describe, expect, it, vi } from 'vitest'
import { TypeSafeJudgmentClient, type JudgmentRequest } from '../src/judgment.js'

const request: JudgmentRequest = {
  state: { status: 'running' },
  questions: [
    { id: 'q1', instruction: 'stuck?', trueCriterion: 'no progress', falseCriterion: 'progress' },
    { id: 'q2', instruction: 'offtopic?', trueCriterion: 'drift', falseCriterion: 'on task' },
  ],
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

describe('TypeSafe judgment client', () => {
  it('sends the wire questions and maps valid probabilities', async () => {
    const fetchImpl = vi.fn(async () =>
      response({ model: 'jev-2026', answers: { q1: { noul: 0.8 }, q2: { noul: 0.1 } }, usage: { input: 10 } }),
    )
    const client = new TypeSafeJudgmentClient({ apiKey: 'k', fetchImpl: fetchImpl as unknown as typeof fetch })
    const result = await client.judge(request)

    expect(result).toMatchObject({ status: 'answered', model: 'jev-2026', answers: { q1: 0.8, q2: 0.1 } })
    const body = JSON.parse(String((fetchImpl.mock.calls[0]?.[1] as RequestInit).body)) as {
      model: string
      questions: Array<Record<string, string>>
    }
    expect(body.model).toBe('jev-latest')
    expect(body.questions[0]).toMatchObject({ true_criterion: 'no progress', false_criterion: 'progress' })
  })

  it('returns unavailable with identity on HTTP errors', async () => {
    const fetchImpl = vi.fn(async () => response({ model: 'jev-2026', usage: { input: 4 } }, 500))
    const client = new TypeSafeJudgmentClient({ apiKey: 'k', fetchImpl: fetchImpl as unknown as typeof fetch })
    const result = await client.judge(request)
    expect(result).toMatchObject({ status: 'unavailable', httpStatus: 500, actualModel: 'jev-2026' })
  })

  it('refuses partial or out-of-range answers', async () => {
    const partial = new TypeSafeJudgmentClient({
      apiKey: 'k',
      fetchImpl: (async () => response({ model: 'm', answers: { q1: { noul: 0.5 } } })) as unknown as typeof fetch,
    })
    expect(await partial.judge(request)).toMatchObject({ status: 'unavailable' })

    const outOfRange = new TypeSafeJudgmentClient({
      apiKey: 'k',
      fetchImpl: (async () => response({ model: 'm', answers: { q1: { noul: 1.5 }, q2: { noul: 0 } } })) as unknown as typeof fetch,
    })
    expect(await outOfRange.judge(request)).toMatchObject({ status: 'unavailable' })
  })

  it('fails closed without a key or on transport errors', async () => {
    const noKey = new TypeSafeJudgmentClient({ apiKey: ' ' })
    expect(await noKey.judge(request)).toMatchObject({ status: 'unavailable', reason: 'TYPESAFE_API_KEY is missing' })

    const failing = new TypeSafeJudgmentClient({
      apiKey: 'k',
      fetchImpl: (async () => {
        throw new Error('network down')
      }) as unknown as typeof fetch,
    })
    expect(await failing.judge(request)).toMatchObject({ status: 'unavailable' })
  })
})

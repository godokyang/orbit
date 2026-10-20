import { describe, expect, it, vi } from 'vitest'
import { InputCompactor, type CompactionInput } from '../src/compaction.js'

function input(overrides: Partial<CompactionInput> = {}): CompactionInput {
  return {
    text: 'long selection material',
    purpose: 'member selection',
    mustKeep: ['must keep this'],
    outputBudget: 100,
    rulesVersion: 'rules-1',
    explicitOverLimit: true,
    ...overrides,
  }
}

describe('bounded selection compaction', () => {
  it('does nothing without a token counter or explicit overflow', async () => {
    const compact = vi.fn(async () => 'short')
    const compactor = new InputCompactor({ compact })
    const result = await compactor.compact(input({ explicitOverLimit: false }))
    expect(result).toEqual({ status: 'not_needed', text: 'long selection material' })
    expect(compact).not.toHaveBeenCalled()
  })

  it('compacts when measured tokens exceed capacity and caches success', async () => {
    const compact = vi.fn(async () => 'short must keep this')
    const compactor = new InputCompactor({ compact, countTokens: () => 500 })
    const first = await compactor.compact(input({ capacity: 100 }))
    expect(first).toMatchObject({ status: 'compacted', text: 'short must keep this' })
    const second = await compactor.compact(input({ capacity: 100 }))
    expect(second).toMatchObject({ status: 'compacted', cached: true })
    expect(compact).toHaveBeenCalledTimes(1)
  })

  it('retries once and succeeds', async () => {
    const compact = vi.fn()
      .mockRejectedValueOnce(new Error('transport'))
      .mockResolvedValueOnce('ok must keep this')
    const compactor = new InputCompactor({ compact })
    expect(await compactor.compact(input())).toMatchObject({ status: 'compacted', text: 'ok must keep this' })
    expect(compact).toHaveBeenCalledTimes(2)
  })

  it('returns unavailable after two failures and does not cache', async () => {
    const compact = vi.fn(async () => {
      throw new Error('boom')
    })
    const compactor = new InputCompactor({ compact })
    const result = await compactor.compact(input())
    expect(result).toMatchObject({ status: 'unavailable', reason: 'boom' })
    expect(compact).toHaveBeenCalledTimes(2)
  })

  it('rejects output that lost required material and retries', async () => {
    const compact = vi.fn()
      .mockResolvedValueOnce('lost everything')
      .mockResolvedValueOnce('kept must keep this')
    const compactor = new InputCompactor({ compact })
    expect(await compactor.compact(input())).toMatchObject({ status: 'compacted', text: 'kept must keep this' })
  })

  it('does not reuse a cache for changed content', async () => {
    const compact = vi.fn(async (call: { text: string }) => `${call.text} must keep this`)
    const compactor = new InputCompactor({ compact })
    await compactor.compact(input({ text: 'one' }))
    await compactor.compact(input({ text: 'two' }))
    expect(compact).toHaveBeenCalledTimes(2)
  })
})

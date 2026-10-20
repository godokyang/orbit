import { describe, expect, it } from 'vitest'
import { planArchiveSegment } from '../src/archive.js'

const events = (from: number, to: number): Array<{ seq: number; type: string }> =>
  Array.from({ length: to - from + 1 }, (_, index) => ({ seq: from + index, type: 'event' }))

describe('archive segment planning', () => {
  it('archives everything on the first capture', () => {
    const segment = planArchiveSegment(events(1, 5), 0)
    expect(segment).toMatchObject({ first: 1, last: 5, count: 5, previousLast: 0 })
    expect(segment?.gap).toBeUndefined()
  })

  it('archives only events after the previous cursor', () => {
    const segment = planArchiveSegment(events(1, 10), 5)
    expect(segment).toMatchObject({ first: 6, last: 10, count: 5, previousLast: 5 })
    expect(segment?.gap).toBeUndefined()
  })

  it('records a gap when the host can no longer observe earlier events', () => {
    const segment = planArchiveSegment(events(8, 10), 5)
    expect(segment?.gap).toEqual({ from: 6, to: 7 })
    expect(segment?.events.map((event) => event.seq)).toEqual([8, 9, 10])
  })

  it('returns nothing when there are no new events', () => {
    expect(planArchiveSegment(events(1, 10), 10)).toBeUndefined()
    expect(planArchiveSegment([], 0)).toBeUndefined()
  })
})

export interface ArchiveSegment<T extends { seq: number }> {
  events: T[]
  first: number
  last: number
  count: number
  previousLast: number
  gap?: { from: number; to: number }
}

/**
 * Select the events not yet archived and describe any seq range the host could
 * no longer observe. Return undefined when there is nothing new.
 */
export function planArchiveSegment<T extends { seq: number }>(events: readonly T[], lastArchived: number): ArchiveSegment<T> | undefined {
  const fresh = events.filter((event) => event.seq > lastArchived)
  if (fresh.length === 0) return undefined
  const first = fresh[0]!.seq
  const last = fresh[fresh.length - 1]!.seq
  const gap = lastArchived > 0 && first > lastArchived + 1 ? { from: lastArchived + 1, to: first - 1 } : undefined
  return {
    events: fresh,
    first,
    last,
    count: fresh.length,
    previousLast: lastArchived,
    ...(gap === undefined ? {} : { gap }),
  }
}

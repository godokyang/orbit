import { sha256Hex } from './ids.js'

export interface CompactionInput {
  text: string
  purpose: string
  mustKeep: string[]
  outputBudget: number
  rulesVersion: string
  /** Measured input tokens, when the host can count them reliably. */
  tokenCount?: number
  /** Model capacity tokens, when known. */
  capacity?: number
  /** Explicit overflow signal when tokens cannot be counted reliably. */
  explicitOverLimit?: boolean
}

export type CompactionStatus = 'not_needed' | 'compacted' | 'unavailable'

export interface CompactionResult {
  status: CompactionStatus
  text?: string
  reason?: string
  cached?: boolean
}

export interface CompactionCall {
  text: string
  purpose: string
  mustKeep: string[]
  outputBudget: number
}

export type CompactFunction = (call: CompactionCall) => Promise<string>

export interface CompactorOptions {
  compact: CompactFunction
  countTokens?: (text: string) => number
  cache?: Map<string, string>
  rulesVersion?: string
}

function cacheKey(input: CompactionInput, rulesVersion: string): string {
  return sha256Hex(
    JSON.stringify({
      rules: rulesVersion,
      purpose: input.purpose,
      mustKeep: input.mustKeep,
      outputBudget: input.outputBudget,
      text: input.text,
    }),
  )
}

/**
 * Bounded compaction for long selection material. It never splits input, makes
 * at most one compact call plus one retry, caches only successful results and
 * returns `unavailable` (never a partial or fabricated result) on failure.
 */
export class InputCompactor {
  private readonly compactFn: CompactFunction
  private readonly countTokens: ((text: string) => number) | undefined
  private readonly cache: Map<string, string>
  readonly rulesVersion: string

  constructor(options: CompactorOptions) {
    this.compactFn = options.compact
    this.countTokens = options.countTokens
    this.cache = options.cache ?? new Map()
    this.rulesVersion = options.rulesVersion ?? 'orbit-compaction-v1'
  }

  private needsCompaction(input: CompactionInput): boolean {
    if (this.countTokens !== undefined && input.capacity !== undefined) {
      return this.countTokens(input.text) > input.capacity
    }
    return input.explicitOverLimit === true
  }

  async compact(input: CompactionInput): Promise<CompactionResult> {
    if (!this.needsCompaction(input)) return { status: 'not_needed', text: input.text }
    const key = cacheKey(input, this.rulesVersion)
    const cached = this.cache.get(key)
    if (cached !== undefined) return { status: 'compacted', text: cached, cached: true }

    let lastReason = 'compaction failed'
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const output = await this.compactFn({
          text: input.text,
          purpose: input.purpose,
          mustKeep: input.mustKeep,
          outputBudget: input.outputBudget,
        })
        if (typeof output !== 'string' || output.trim().length === 0) {
          lastReason = 'compactor returned empty output'
          continue
        }
        const missing = input.mustKeep.filter((item) => !output.includes(item))
        if (missing.length > 0) {
          lastReason = `compacted output lost required material: ${missing.join(', ')}`
          continue
        }
        this.cache.set(key, output)
        return { status: 'compacted', text: output }
      } catch (error) {
        lastReason = (error as Error).message
      }
    }
    return { status: 'unavailable', reason: lastReason }
  }
}

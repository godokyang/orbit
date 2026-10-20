import { z } from 'zod'
import { OrbitError } from './errors.js'
import { charLength, isBlank } from './ids.js'
import type { CheckResult, Coverage, CoverageItem } from './types.js'

const requirementMax = 1000
const textMax = 1000
const refMax = 200
const controlChars = /\p{Cc}/u

const coverageItemSchema = z.strictObject({
  requirement: z.string(),
  status: z.enum(['verified', 'unverified']),
  evidence: z.string(),
  scope: z.enum(['delivery', 'lifecycle']).optional(),
  gap_kind: z.enum(['not_checked', 'evidence_missing', 'defect']).optional(),
  ref: z.string().optional(),
})

const coverageSchema = z.strictObject({
  complete: z.boolean(),
  items: z.array(coverageItemSchema).min(1),
})

const findingSchema = z.strictObject({
  id: z.string(),
  requirement: z.string(),
  evidence: z.string(),
  action: z.string(),
})

const deliverySchema = z.strictObject({
  ready: z.boolean(),
  reason: z.string(),
})

const rawResultSchema = z.strictObject({
  verdict: z.enum(['continue', 'correct', 'pause', 'complete', 'needs_user']),
  reason: z.string(),
  findings: z.array(findingSchema),
  resolved_ids: z.array(z.string()),
  next_check_seconds: z.number().int().positive(),
  delivery: deliverySchema,
  coverage: coverageSchema.optional(),
})

export type RawCheckResult = z.infer<typeof rawResultSchema>

function fail(message: string): never {
  throw new OrbitError('check_result_invalid', message)
}

export function normalizeCoverage(input: unknown): Coverage {
  const parsed = coverageSchema.safeParse(input)
  if (!parsed.success) {
    fail(`coverage does not match the contract: ${parsed.error.issues.map((i) => `${i.path.join('.')} ${i.message}`).join('; ')}`)
  }

  const seen = new Set<string>()
  const items: CoverageItem[] = parsed.data.items.map((item) => {
    const requirement = item.requirement.trim()
    if (requirement.length === 0 || charLength(requirement) > requirementMax) {
      fail(`each coverage requirement must be 1..${requirementMax} characters`)
    }
    if (seen.has(requirement)) fail(`duplicate coverage requirement: ${JSON.stringify(requirement)}`)
    seen.add(requirement)

    const evidence = item.evidence
    if (charLength(evidence) > textMax) {
      fail(`coverage evidence must be at most ${textMax} characters`)
    }
    if (item.status === 'verified' && isBlank(evidence)) {
      fail(`coverage item ${JSON.stringify(requirement)} is verified but has no evidence`)
    }
    if (item.gap_kind !== undefined && item.status !== 'unverified') {
      fail('gap_kind is only valid on an unverified coverage item')
    }

    const normalized: CoverageItem = {
      requirement,
      scope: item.scope ?? 'delivery',
      status: item.status,
      evidence,
    }
    if (item.gap_kind !== undefined) normalized.gap_kind = item.gap_kind
    if (item.ref !== undefined) {
      if (charLength(item.ref) > refMax || controlChars.test(item.ref)) {
        fail(`coverage ref must be at most ${refMax} characters without control characters`)
      }
      if (!isBlank(item.ref)) normalized.ref = item.ref
    }
    return normalized
  })

  return { complete: parsed.data.complete, items }
}

/**
 * Validate a raw checker payload (snake_case wire shape) and return the
 * internal camelCase result. Structural bounds come from the JSON schema;
 * non-empty text, duplicate requirements and ref rules are enforced here.
 */
export function parseCheckResult(input: unknown): CheckResult {
  const parsed = rawResultSchema.safeParse(input)
  if (!parsed.success) {
    fail(`check result does not match contracts/check-result.schema.json: ${parsed.error.issues.map((i) => `${i.path.join('.')} ${i.message}`).join('; ')}`)
  }
  const raw = parsed.data

  if (raw.reason.length === 0) fail('reason must be a non-empty string')
  if (raw.delivery.reason.length === 0) fail('delivery.reason must be a non-empty string')
  for (const [index, finding] of raw.findings.entries()) {
    for (const key of ['id', 'requirement', 'evidence', 'action'] as const) {
      if (finding[key].length === 0) fail(`findings[${index}].${key} must be a non-empty string`)
    }
  }
  if (raw.resolved_ids.some((id) => id.length === 0)) {
    fail('resolved_ids must contain non-empty strings')
  }

  const result: CheckResult = {
    verdict: raw.verdict,
    reason: raw.reason,
    findings: raw.findings.map((finding) => ({ ...finding })),
    resolvedIds: [...raw.resolved_ids],
    nextCheckSeconds: raw.next_check_seconds,
    delivery: { ready: raw.delivery.ready, reason: raw.delivery.reason },
  }
  if (raw.coverage !== undefined) {
    result.coverage = normalizeCoverage(raw.coverage)
  }
  return result
}

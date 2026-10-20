import { readFileSync } from 'node:fs'
import { OrbitError } from './errors.js'
import { JEV_SELECTION_QUESTION_SETS } from './jev-selection.js'

export const SELECTION_DECISION_VERSION = 'orbit-quality-decision-4'

export interface SelectionThresholds {
  handoff_fit: number
  member_task_fit: number
  candidate_task_fit: number
  checker_task_fit: number
}

export interface SelectionRelease {
  decisionVersion: typeof SELECTION_DECISION_VERSION
  model: string
  thresholdKeys: Array<keyof SelectionThresholds>
  thresholds: SelectionThresholds
  questionSets: {
    delegation: string
    candidates: string
    checkerQuality: string
  }
}

export interface CandidateJudgment {
  index: number
  probability: number
}

export type DelegationStatus = 'facts_only' | 'no_handoff' | 'no_candidate' | 'recommended'

export interface DelegationDecision {
  status: DelegationStatus
  reason: string
  recommended?: CandidateJudgment
  candidates: Array<CandidateJudgment & { passes: boolean }>
}

export interface CheckerDecision {
  status: 'facts_only' | 'no_candidate' | 'recommended'
  reason: string
  recommended?: CandidateJudgment
  candidates: Array<CandidateJudgment & { passes: boolean }>
}

function validProbability(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1
}

function validThreshold(value: unknown): value is number {
  return validProbability(value) && value > 0
}

/** Validate a calibration release before any automatic recommendation uses it. */
export function parseSelectionRelease(value: unknown): SelectionRelease {
  if (value === null || typeof value !== 'object') throw new OrbitError('invalid_input', 'selection release must be an object')
  const record = value as Record<string, unknown>
  if (record.decision_version !== SELECTION_DECISION_VERSION) {
    throw new OrbitError('invalid_input', `selection release must target ${SELECTION_DECISION_VERSION}`)
  }
  if (typeof record.model !== 'string' || record.model.length === 0) {
    throw new OrbitError('invalid_input', 'selection release must name the judgment model')
  }
  const thresholds = record.thresholds
  const keys: Array<keyof SelectionThresholds> = ['handoff_fit', 'member_task_fit', 'candidate_task_fit', 'checker_task_fit']
  if (thresholds === null || typeof thresholds !== 'object') {
    throw new OrbitError('invalid_input', 'selection release thresholds are missing')
  }
  const values = thresholds as Record<string, unknown>
  if (Object.keys(values).sort().join(',') !== [...keys].sort().join(',')) {
    throw new OrbitError('invalid_input', 'selection release must contain exactly the current threshold keys')
  }
  const resolved = {} as SelectionThresholds
  for (const key of keys) {
    if (!validThreshold(values[key])) throw new OrbitError('invalid_input', `threshold ${key} must be in (0, 1]`)
    resolved[key] = values[key] as number
  }
  const sets = record.question_set_versions
  if (sets === null || typeof sets !== 'object') throw new OrbitError('invalid_input', 'question_set_versions are missing')
  const setValues = sets as Record<string, unknown>
  const expected = {
    delegation: JEV_SELECTION_QUESTION_SETS.delegation,
    candidates: JEV_SELECTION_QUESTION_SETS.candidates,
    checkerQuality: JEV_SELECTION_QUESTION_SETS.checkerQuality,
  }
  if (
    setValues.delegation !== expected.delegation ||
    setValues.candidates !== expected.candidates ||
    setValues.checker_quality !== expected.checkerQuality
  ) {
    throw new OrbitError('invalid_input', 'selection release question sets do not match the current versions')
  }
  return {
    decisionVersion: SELECTION_DECISION_VERSION,
    model: record.model,
    thresholdKeys: keys,
    thresholds: resolved,
    questionSets: expected,
  }
}

/** Load and validate a release file; missing files are errors, not silent defaults. */
export function loadSelectionRelease(path: string): SelectionRelease {
  let parsed: unknown
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8')) as unknown
  } catch (error) {
    throw new OrbitError('invalid_input', `selection release cannot be read: ${(error as Error).message}`)
  }
  return parseSelectionRelease(parsed)
}

/**
 * Two-stage delegation decision. Without a calibrated release only facts are
 * returned; `member_task_fit` stays diagnostic and never vetoes a candidate.
 */
export function decideDelegation(
  input: {
    handoffFit: number
    memberTaskFit?: number
    candidates: readonly CandidateJudgment[]
  },
  release?: SelectionRelease,
): DelegationDecision {
  if (!validProbability(input.handoffFit)) throw new OrbitError('invalid_input', 'handoff_fit must be a probability')
  for (const candidate of input.candidates) {
    if (!validProbability(candidate.probability)) throw new OrbitError('invalid_input', 'candidate probability must be a probability')
  }
  const facts = input.candidates.map((candidate) => ({ ...candidate, passes: false }))
  if (release === undefined) {
    return { status: 'facts_only', reason: 'no calibrated selection release; probabilities are facts only', candidates: facts }
  }
  if (input.handoffFit < release.thresholds.handoff_fit) {
    return { status: 'no_handoff', reason: 'handoff_fit is below the released threshold', candidates: facts }
  }
  const evaluated = facts.map((candidate) => ({
    ...candidate,
    passes: candidate.probability >= release.thresholds.candidate_task_fit,
  }))
  const passing = evaluated.filter((candidate) => candidate.passes)
  if (passing.length === 0) {
    return {
      status: 'no_candidate',
      reason: 'no candidate meets the released candidate_task_fit threshold',
      candidates: evaluated,
    }
  }
  const recommended = [...passing].sort((a, b) => b.probability - a.probability || a.index - b.index)[0]
  return { status: 'recommended', reason: 'handoff and candidate gates passed', recommended, candidates: evaluated }
}

/** Checker selection uses only the checker-quality gate and is never cost-ranked. */
export function decideChecker(
  candidates: readonly CandidateJudgment[],
  release?: SelectionRelease,
): CheckerDecision {
  for (const candidate of candidates) {
    if (!validProbability(candidate.probability)) throw new OrbitError('invalid_input', 'checker probability must be a probability')
  }
  const facts = candidates.map((candidate) => ({ ...candidate, passes: false }))
  if (release === undefined) {
    return { status: 'facts_only', reason: 'no calibrated selection release; probabilities are facts only', candidates: facts }
  }
  const evaluated = facts.map((candidate) => ({
    ...candidate,
    passes: candidate.probability >= release.thresholds.checker_task_fit,
  }))
  const passing = evaluated.filter((candidate) => candidate.passes)
  if (passing.length === 0) {
    return { status: 'no_candidate', reason: 'no checker meets the released threshold', candidates: evaluated }
  }
  const recommended = [...passing].sort((a, b) => b.probability - a.probability || a.index - b.index)[0]
  return { status: 'recommended', reason: 'checker gate passed', recommended, candidates: evaluated }
}

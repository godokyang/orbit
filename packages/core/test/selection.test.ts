import { describe, expect, it } from 'vitest'
import {
  SELECTION_DECISION_VERSION,
  decideChecker,
  decideDelegation,
  loadSelectionRelease,
  parseSelectionRelease,
  type SelectionRelease,
} from '../src/selection.js'

const release: SelectionRelease = {
  decisionVersion: SELECTION_DECISION_VERSION,
  model: 'jev-1.13.0',
  thresholdKeys: ['handoff_fit', 'member_task_fit', 'candidate_task_fit', 'checker_task_fit'],
  thresholds: {
    handoff_fit: 0.65,
    member_task_fit: 0.65,
    candidate_task_fit: 0.6,
    checker_task_fit: 0.6,
  },
  questionSets: { delegation: 'jev-delegation-5', candidates: 'jev-candidates-5', checkerQuality: 'jev-checker-task-fit-6' },
}

describe('selection release', () => {
  it('accepts a complete current release', () => {
    expect(parseSelectionRelease({
      decision_version: SELECTION_DECISION_VERSION,
      model: 'jev-1.13.0',
      thresholds: { handoff_fit: 0.65, member_task_fit: 0.65, candidate_task_fit: 0.6, checker_task_fit: 0.6 },
      question_set_versions: { delegation: 'jev-delegation-5', candidates: 'jev-candidates-5', checker_quality: 'jev-checker-task-fit-6' },
    })).toEqual(release)
  })

  it('rejects wrong versions, extra threshold keys and mismatched question sets', () => {
    const base = {
      decision_version: SELECTION_DECISION_VERSION,
      model: 'm',
      thresholds: { handoff_fit: 0.5, member_task_fit: 0.5, candidate_task_fit: 0.5, checker_task_fit: 0.5 },
      question_set_versions: { delegation: 'jev-delegation-5', candidates: 'jev-candidates-5', checker_quality: 'jev-checker-task-fit-6' },
    }
    expect(() => parseSelectionRelease({ ...base, decision_version: 'old' })).toThrow(/decision-4/)
    expect(() => parseSelectionRelease({ ...base, thresholds: { ...base.thresholds, cost: 0.5 } })).toThrow(/threshold keys/)
    expect(() => parseSelectionRelease({
      ...base,
      question_set_versions: { ...base.question_set_versions, delegation: 'jev-delegation-4' },
    })).toThrow(/question sets/)
    expect(() => loadSelectionRelease('/does/not/exist.json')).toThrow(/cannot be read/)
  })
})

describe('delegation decision', () => {
  it('returns facts only without a release', () => {
    const decision = decideDelegation({ handoffFit: 0.9, candidates: [{ index: 0, probability: 0.9 }] })
    expect(decision.status).toBe('facts_only')
    expect(decision.recommended).toBeUndefined()
    expect(decision.candidates[0]?.passes).toBe(false)
  })

  it('gates on handoff then per-candidate fit; member_task_fit does not veto', () => {
    expect(decideDelegation({ handoffFit: 0.1, candidates: [{ index: 0, probability: 0.9 }] }, release).status).toBe('no_handoff')
    const decision = decideDelegation(
      { handoffFit: 0.9, memberTaskFit: 0.01, candidates: [{ index: 0, probability: 0.59 }, { index: 1, probability: 0.8 }, { index: 2, probability: 0.7 }] },
      release,
    )
    expect(decision.status).toBe('recommended')
    expect(decision.recommended?.index).toBe(1)
    expect(decision.candidates.map((candidate) => candidate.passes)).toEqual([false, true, true])
  })

  it('returns no_candidate when all candidates fail the gate', () => {
    expect(decideDelegation({ handoffFit: 0.9, candidates: [{ index: 0, probability: 0.1 }] }, release).status).toBe('no_candidate')
  })
})

describe('checker decision', () => {
  it('uses only the checker gate and does not rank by cost', () => {
    expect(decideChecker([{ index: 0, probability: 0.9 }]).status).toBe('facts_only')
    const decision = decideChecker([{ index: 0, probability: 0.4 }, { index: 1, probability: 0.9 }], release)
    expect(decision.status).toBe('recommended')
    expect(decision.recommended?.index).toBe(1)
    expect(decideChecker([{ index: 0, probability: 0.1 }], release).status).toBe('no_candidate')
  })
})

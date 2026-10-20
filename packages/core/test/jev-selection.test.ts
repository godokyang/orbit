import { describe, expect, it } from 'vitest'
import {
  JEV_SELECTION_INPUT_VERSION,
  JEV_SELECTION_QUESTION_SETS,
  candidateQuestions,
  checkerQuestions,
  delegationQuestions,
  projectSelectionState,
} from '../src/jev-selection.js'

describe('JEV selection questions', () => {
  it('builds the two delegation questions', () => {
    const questions = delegationQuestions()
    expect(questions.map((question) => question.id)).toEqual(['handoff_fit', 'member_task_fit'])
    expect(questions[0]?.instruction).toContain('serial handoff')
    expect(questions[0]?.trueCriterion).toContain('concrete work unit')
    expect(JEV_SELECTION_QUESTION_SETS.delegation).toBe('jev-delegation-5')
  })

  it('labels each candidate with its index and provider/model', () => {
    const questions = candidateQuestions([
      { agent: 'a1', provider: 'p', model: 'm' },
      { provider: 'p', model: 'p/m2' },
    ])
    expect(questions.map((question) => question.id)).toEqual(['candidate_0_task_fit', 'candidate_1_task_fit'])
    expect(questions[0]?.instruction).toContain('candidate 0 (agent a1, model p/m)')
    expect(questions[1]?.instruction).toContain('candidate 1 (agent unknown, model p/m2)')
  })

  it('builds checker quality questions', () => {
    const questions = checkerQuestions([{ model: 'p/m' }, { model: 'p/n' }])
    expect(questions.map((question) => question.id)).toEqual(['quality_0', 'quality_1'])
    expect(questions[0]?.instruction).toContain('Checker candidate p/m')
    expect(questions[0]?.trueCriterion).toContain('independent review')
  })
})

describe('selection state projection', () => {
  it('strips speed, time and price facts at every depth and records omissions', () => {
    const projected = projectSelectionState({
      task_context: {
        instruction: 'Build it.',
        elapsed_seconds: 120,
        candidates: [{ model: 'p/m', latency_ms: 300, cost_tier: 'low', coding_index: 72 }],
      },
      route_costs: { total: 1 },
      catalog_priors: [{ id: 'p/m', throughput: 99 }],
      exact_evidence: [{ local_samples: 3, success: true }],
    })
    expect(projected.input_version).toBe(JEV_SELECTION_INPUT_VERSION)
    const material = JSON.stringify({
      task_context: projected.task_context,
      catalog_priors: projected.catalog_priors,
      exact_evidence: projected.exact_evidence,
    })
    expect(material).not.toMatch(/elapsed_seconds|latency_ms|cost_tier|throughput|local_samples|route_costs/)
    expect((projected.task_context as { instruction: string }).instruction).toBe('Build it.')
    expect(projected.omitted_from_judgment).toEqual(
      [...projected.omitted_from_judgment].sort(),
    )
    expect(projected.omitted_from_judgment).toEqual(
      expect.arrayContaining(['elapsed_seconds', 'latency_ms', 'cost_tier', 'route_costs', 'throughput', 'local_samples']),
    )
  })

  it('keeps quality facts and re-strips already-projected envelopes', () => {
    const projected = projectSelectionState({
      task_context: { candidates: [{ coding_index: 72, price_per_token: 0.1 }] },
      catalog_priors: [],
      exact_evidence: [],
      omitted_from_judgment: ['already_omitted'],
    })
    expect(JSON.stringify(projected.task_context)).toContain('coding_index')
    expect(JSON.stringify(projected.task_context)).not.toContain('price_per_token')
    expect(projected.omitted_from_judgment).toContain('already_omitted')
  })
})

import type { JudgmentQuestion } from './judgment.js'

export const JEV_SELECTION_INPUT_VERSION = 'jev-selection-input-3'
export const JEV_SELECTION_QUESTION_SETS = {
  delegation: 'jev-delegation-5',
  candidates: 'jev-candidates-5',
  checkerQuality: 'jev-checker-task-fit-6',
} as const

const HANDOFF_TEXT =
  'Is there a bounded work unit in the effective requirements or remaining work that an authorized member could deliver by handoff, including a serial handoff where the main agent waits and then integrates? Do not require simultaneous work on another surface. Use the instruction, basis, amendments and any supplied work unit; do not invent a work unit that is not in the input. Count only a clear result whose dependencies the handoff can satisfy. Do not count trivial, overlapping, preference-only or dependency-blocked work. Do not use speed, latency, elapsed time, tokens per second or price. Member availability is enforced separately, so unknown availability does not lower this probability.'
const HANDOFF_TRUE = 'The input describes a concrete work unit with its own result that can be handed off serially or while other work continues'
const HANDOFF_FALSE = 'The remaining work is coupled, trivial, dependency-blocked, or no bounded handoff is described'

const MEMBER_FIT_TEXT =
  'Do the supplied task-related quality facts support including at least one callable member as a reasonable option for this bounded, verifiable work unit? Judge the relationship between the work and each option’s sourced exact evidence or labeled model-level catalog prior. A relevant mapped catalog prior can support an initial handoff without exact-route success samples. Record unknown reasoning variants and measurement dates as limitations; they do not by themselves erase model-level support. An observed unmet task requirement or unresolved relevant conflict prevents positive support. This judges an evidence-supported option, not future delivery success or a reliability certificate. Do not infer capability from names, add indices to the answer, or judge speed or price.'
const FIT_TRUE = 'Usable task-related catalog evidence or exact sourced quality evidence supports a reasonable handoff for this bounded, verifiable work unit. Exact route success samples are optional; this is a heuristic, not a reliability certificate.'
const FIT_FALSE = 'Neither usable task-related catalog support nor exact sourced quality support is supplied, relevant sources conflict, or an observed capability cannot meet the task. Missing exact route evidence alone does not establish this outcome.'

const CANDIDATE_FIT_TEXT =
  'Do the supplied task-related quality facts support including THIS candidate as a reasonable option for the bounded, verifiable work unit? Judge the relationship between the work and this candidate’s sourced exact evidence or labeled model-level catalog prior. A relevant mapped catalog prior can support an initial handoff without exact-route success samples. Serial handoff is valid. Unknown reasoning variants and measurement dates remain limitations; they do not by themselves erase model-level support. An observed unmet task requirement or unresolved relevant conflict prevents positive support. This judges an evidence-supported option, not future delivery success or a reliability certificate. Do not infer capability from names, add indices to the answer, or judge speed or price.'

const CHECKER_FIT_TEXT =
  'Do the supplied task-related quality facts support including THIS checker as a reasonable option for independent read-only review of the bounded current task? Judge the relationship between the review requirements and sourced exact evidence or a labeled model-level catalog prior. Relevant mapped coding, agentic or intelligence facts may support an initial review without exact-route success samples. Unknown reasoning variants and measurement dates remain limitations. An observed unmet review requirement or unresolved relevant conflict prevents positive support. This judges an evidence-supported review option, not future defect detection or a reliability certificate. Do not infer capability from names, add indices to the answer, or judge speed or price.'
const CHECKER_TRUE = 'Usable task-related catalog evidence or exact sourced quality evidence supports a useful independent review of this bounded task. Exact route success samples are optional; this is a heuristic, not a reliability certificate.'
const CHECKER_FALSE = 'Neither usable task-related catalog support nor exact sourced quality support is supplied, relevant sources conflict, or the model cannot review this task. Missing exact route evidence alone does not establish this outcome.'

export interface SelectionCandidate {
  agent?: string
  provider: string
  model: string
}

export function delegationQuestions(): JudgmentQuestion[] {
  return [
    { id: 'handoff_fit', instruction: HANDOFF_TEXT, trueCriterion: HANDOFF_TRUE, falseCriterion: HANDOFF_FALSE },
    { id: 'member_task_fit', instruction: MEMBER_FIT_TEXT, trueCriterion: FIT_TRUE, falseCriterion: FIT_FALSE },
  ]
}

export function candidateQuestions(candidates: readonly SelectionCandidate[]): JudgmentQuestion[] {
  return candidates.map((candidate, index) => {
    const modelId = candidate.model.startsWith(`${candidate.provider}/`) ? candidate.model : `${candidate.provider}/${candidate.model}`
    const label = `candidate ${index} (agent ${candidate.agent ?? 'unknown'}, model ${modelId}): `
    return {
      id: `candidate_${index}_task_fit`,
      instruction: label + CANDIDATE_FIT_TEXT,
      trueCriterion: FIT_TRUE,
      falseCriterion: FIT_FALSE,
    }
  })
}

export function checkerQuestions(candidates: ReadonlyArray<{ model: string }>): JudgmentQuestion[] {
  return candidates.map((candidate, index) => ({
    id: `quality_${index}`,
    instruction: `Checker candidate ${candidate.model}: ` + CHECKER_FIT_TEXT,
    trueCriterion: CHECKER_TRUE,
    falseCriterion: CHECKER_FALSE,
  }))
}

const OMITTED_KEYS = new Set(['elapsed_seconds', 'time_variance_seconds', 'local_samples', 'comparison', 'usage', 'resource_calls', 'route_costs'])
const SPEED_METRIC = /latency|elapsed|tokens?_per_s|tokens?\/s|throughput|time_to_first|ttft|time_tier|critical_path|e2e_time|end_to_end|duration|speed|(?:\A|_)time(?:_|\z)|local_samples?|parallel_gain|seconds?|wall_clock/i
const PRICE_KEY = /^(?:cost|price|pricing|quota)(?:$|[._])/i

export interface SelectionProjection {
  input_version: typeof JEV_SELECTION_INPUT_VERSION
  combination: 'none'
  task_context: Record<string, unknown>
  catalog_priors: unknown[]
  exact_evidence: unknown[]
  omitted_from_judgment: string[]
}

function strip(value: unknown, omitted: Set<string>, path: string[]): unknown {
  if (Array.isArray(value)) return value.map((entry, index) => strip(entry, omitted, [...path, String(index)]))
  if (value === null || typeof value !== 'object') return value
  const result: Record<string, unknown> = {}
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    if (OMITTED_KEYS.has(key) || SPEED_METRIC.test(key) || PRICE_KEY.test(key)) {
      omitted.add(key)
      continue
    }
    result[key] = strip(entry, omitted, [...path, key])
  }
  return result
}

/**
 * Selection input projection: strips speed, elapsed-time, coarse price and
 * quota facts at every depth so they cannot influence task-fit judgments.
 * Already-projected envelopes are accepted and re-stripped.
 */
export function projectSelectionState(state: Record<string, unknown>): SelectionProjection {
  const omitted = new Set<string>()
  for (const key of (state.omitted_from_judgment as string[] | undefined) ?? []) omitted.add(String(key))
  const scrubbed = strip(state, omitted, []) as Record<string, unknown>
  return {
    input_version: JEV_SELECTION_INPUT_VERSION,
    combination: 'none',
    task_context: (scrubbed.task_context ?? scrubbed) as Record<string, unknown>,
    catalog_priors: Array.isArray(scrubbed.catalog_priors) ? (scrubbed.catalog_priors as unknown[]) : [],
    exact_evidence: Array.isArray(scrubbed.exact_evidence) ? (scrubbed.exact_evidence as unknown[]) : [],
    omitted_from_judgment: [...omitted].sort(),
  }
}

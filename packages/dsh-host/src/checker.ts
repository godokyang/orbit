import type { Agent } from '@deepseek-ai/dsh-agent'
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import type { SubagentRuntime } from '@deepseek-ai/dsh-subagent'
import type { RequirementVersion, TaskState } from '@orbit/core'

export interface CheckerPromptInput {
  state: TaskState
  taskDir: string
  artifactDigest: string
}

/** Build the independent checker's instruction from durable requirements. */
export function buildCheckerPrompt(input: CheckerPromptInput): string {
  const requirements = input.state.input.versions
    .map((version: RequirementVersion) => {
      const label = version.version === 1 ? 'Original requirement' : `Amendment v${version.version}`
      return `${label}:\n${version.text}`
    })
    .join('\n\n')

  return `You are Orbit's independent, read-only checker. Inspect the actual deliverable; do not trust claims alone.

Task: ${input.state.id}
Artifact root: ${input.state.workspace.artifactRoot}
Task record: ${input.taskDir}
Input version: ${input.state.input.versions.length}
Artifact digest: ${input.artifactDigest}

Requirements:
${requirements}

Rules:
- Read only. Do not modify files, run state-changing commands, or accept a Root claim as evidence.
- Enumerate EVERY requirement from the original instruction and every effective amendment in coverage.items.
- A verified item needs concrete evidence you actually inspected. Never mark unverified material as verified.
- scope=delivery covers artifacts, integration, required tests and the delivered answer; scope=lifecycle covers future completion/stop obligations that the runtime verifies later.
- Report real gaps as findings with stable ids; list ids you confirm resolved in resolved_ids.
- delivery.ready may be true only when the actual deliverable is inspectable at this version. No findings does not by itself mean ready.
- If you cannot inspect something required, mark it unverified with gap_kind=not_checked or evidence_missing.

Return ONLY one JSON object with this shape (snake_case, no prose, no code fence):
{
  "verdict": "continue" | "correct" | "pause" | "complete" | "needs_user",
  "reason": "non-empty explanation",
  "findings": [{"id": "...", "requirement": "...", "evidence": "...", "action": "..."}],
  "resolved_ids": ["..."],
  "next_check_seconds": 300,
  "delivery": {"ready": true, "reason": "..."},
  "coverage": {"complete": true, "items": [{"requirement": "...", "scope": "delivery", "status": "verified", "evidence": "..."}]}
}`
}

/** Extract the first complete JSON object from checker text. */
export function extractCheckerJson(text: string): unknown {
  let candidate = text.trim()
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(candidate)
  if (fenced?.[1] !== undefined) candidate = fenced[1].trim()
  const start = candidate.indexOf('{')
  const end = candidate.lastIndexOf('}')
  if (start < 0 || end <= start) throw new Error('checker output contains no JSON object')
  return JSON.parse(candidate.slice(start, end + 1)) as unknown
}

export interface ProcessCheckerPromptInput {
  state: TaskState
  taskDir: string
  signal: Array<{ id: string; probability: number }>
  operations: Array<{ name: string; status: string; target: string; declaredIntent: string }>
}

/** Prompt for a JEV-signalled process check: correction advice, never completion. */
export function buildProcessCheckerPrompt(input: ProcessCheckerPromptInput): string {
  const requirements = input.state.input.versions
    .map((version) => `${version.version === 1 ? 'Original requirement' : `Amendment v${version.version}`}:\n${version.text}`)
    .join('\n\n')
  const recent = input.operations
    .slice(-10)
    .map((operation) => `- ${operation.name} [${operation.status}] target=${operation.target} intent=${operation.declaredIntent}`)
    .join('\n')
  const signal = input.signal.map((entry) => `${entry.id}=${entry.probability.toFixed(2)}`).join(', ')
  return `You are Orbit's independent process checker. Judge whether the Root currently needs a specific correction; do not judge final delivery readiness or approve completion.

Task: ${input.state.id}
Task record: ${input.taskDir}
JEV signal: ${signal}

Requirements:
${requirements}

Recent operations (bounded, no tool payloads):
${recent || '(none observed)'}

Rules:
- Read only. Inspect the task record and workspace if needed.
- Report only concrete, actionable problems with stable finding ids; otherwise return no findings.
- coverage is optional for a process check; do not claim delivery coverage.
- verdict=complete is not a completion decision here.

Return ONLY one JSON object (snake_case, no prose, no code fence):
{"verdict":"continue"|"correct"|"pause"|"needs_user","reason":"...","findings":[{"id":"...","requirement":"...","evidence":"...","action":"..."}],"resolved_ids":[],"next_check_seconds":300,"delivery":{"ready":false,"reason":"process check does not decide delivery"}}`
}

export interface CheckerRunInput {
  subagents: SubagentRuntime
  parent: Agent
  prompt: string
  cwd: string
  signal: AbortSignal
  model?: { provider: string; model: string }
}

/** Run the checker through the independent dsh-sdk backend and return raw JSON. */
export async function runChecker(input: CheckerRunInput): Promise<unknown> {
  if (input.subagents.getProvider('dsh-sdk') === undefined) {
    throw new Error('orbit: the dsh-sdk subagent provider is not installed; install @deepseek-ai/dsh-subagent-dsh-sdk and @deepseek-ai/dsh-sdk-client in the controlled profile')
  }
  const activation = await input.subagents.startActivation({
    provider: 'dsh-sdk',
    label: 'orbit-checker',
    request: {
      prompt: [{ type: 'text', text: input.prompt }],
      parent: input.parent,
      cwd: input.cwd,
      ...(input.model === undefined
        ? {}
        : { agentOptions: { provider: input.model.provider, model: input.model.model } }),
    },
    signal: input.signal,
    delivery: 'caller',
  })
  try {
    const result = await activation.result
    if (result.structured !== undefined) return result.structured
    if (result.stopReason !== 'completed') {
      throw new Error(`orbit: checker stopped with ${result.stopReason}${result.diagnostic === undefined ? '' : `: ${result.diagnostic}`}`)
    }
    const text = result.output
      .filter((block): block is Extract<ContentBlock, { type: 'text' }> => block.type === 'text')
      .map((block) => block.text)
      .join('\n')
    return extractCheckerJson(text)
  } finally {
    await activation.dispose().catch(() => undefined)
  }
}

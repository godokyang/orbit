// Checker child fixture: a scripted fake model that returns one valid
// check-result JSON object. Runs inside the isolated checker DSH process.
import { LlmAdapter } from '@deepseek-ai/dsh-llm'

export const name = 'orbit-checker-probe'
export const inject = ['llm']

const RESULT = JSON.stringify({
  verdict: 'complete',
  reason: 'fixture checker inspected the delivered artifact',
  findings: [],
  resolved_ids: [],
  next_check_seconds: 300,
  delivery: { ready: true, reason: 'deliverable is inspectable' },
  coverage: {
    complete: true,
    items: [
      {
        requirement: 'Build the migration slice.',
        scope: 'delivery',
        status: 'verified',
        evidence: 'fixture read the workspace',
      },
    ],
  },
})

class CheckerAdapter extends LlmAdapter {
  providerInfo(provider) { return { id: provider, provider, name: 'Orbit checker probe', displayName: 'Orbit checker probe' } }
  async listModels(provider) { return [{ id: 'probe-1', provider, model: 'probe-1', name: 'probe-1', displayName: 'probe-1' }] }
  async resolveModel(provider, model) { return { provider, id: model, name: model, model, context: { contextWindow: 100000 } } }
  async *stream() {
    yield { type: 'block-start', index: 0, blockType: 'text' }
    yield { type: 'text-delta', index: 0, text: RESULT }
    yield { type: 'block-end', index: 0, block: { type: 'text', text: RESULT } }
    yield { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } }
    yield { type: 'finish', reason: { kind: 'stop' } }
  }
}

export function apply(ctx) {
  ctx.llm.registerAdapter(['probe'], new CheckerAdapter())
}

import { describe, expect, it } from 'vitest'
import { assertControlledProfile, parseProfileDump } from '../src/profile.js'

const GOOD = `# == @deepseek-ai/dsh-base
- id: tool-plugin-manager
  name: '@deepseek-ai/dsh-plugin-manager/tools'
  disabled: true
- id: hmr
  name: '@deepseek-ai/dsh-hmr'
  disabled: true
- id: session-log-deepseek
  disabled: true
- id: session-title-llm
  disabled: true
- id: goal-round-driver
  disabled: true
- id: command-goal
  disabled: true
- id: tool-goal
  disabled: true
- id: cordis-host-runner
  disabled: true
- id: cordis-client-runner
  disabled: true
- id: approval
  name: '@deepseek-ai/dsh-user-approval'
  config:
    policy: never
- id: sandbox-policy
  name: '@deepseek-ai/dsh-sandbox-policy'
  config:
    mode: workspace-write
- id: permission
  name: '@deepseek-ai/dsh-permission-presets'
  config:
    defaultPreset: orbit-controlled
    presets:
      orbit-controlled:
        sandbox: workspace-write
        approval: never
`

describe('T0 profile assertion', () => {
  it('accepts a fully controlled dump', () => {
    const result = assertControlledProfile(GOOD)
    expect(result.ok).toBe(true)
    expect(result.entries.get('hmr')?.disabled).toBe(true)
  })

  it('ignores nested preset ids with the same name', () => {
    const dump = `${GOOD}  agents:\n    - id: hmr\n      disabled: false\n`
    expect(assertControlledProfile(dump).ok).toBe(true)
  })

  it('rejects a re-enabled host runner row', () => {
    const dump = GOOD.replace("- id: hmr\n  name: '@deepseek-ai/dsh-hmr'\n  disabled: true", "- id: hmr\n  name: '@deepseek-ai/dsh-hmr'\n  disabled: false")
    const result = assertControlledProfile(dump)
    expect(result.ok).toBe(false)
    expect(result.problems.join('\n')).toContain('hmr')
  })

  it('rejects approval other than never and the wrong sandbox mode', () => {
    const dump = GOOD.replace('policy: never', 'policy: ask').replace('mode: workspace-write', 'mode: danger-full-access')
    const result = assertControlledProfile(dump)
    expect(result.ok).toBe(false)
    expect(result.problems).toContain('approval policy must be "never"')
    expect(result.problems).toContain('sandbox-policy mode must be "workspace-write"')
  })

  it('accepts read-only sandbox for the checker profile', () => {
    const dump = GOOD.replace('mode: workspace-write', 'mode: read-only')
    expect(assertControlledProfile(dump, { sandboxMode: 'read-only' }).ok).toBe(true)
  })

  it('reports a missing row', () => {
    const dump = GOOD.replace("- id: tool-goal\n  disabled: true\n", '')
    const result = assertControlledProfile(dump)
    expect(result.ok).toBe(false)
    expect(result.problems.join('\n')).toContain('"tool-goal" is missing')
  })

  it('requires an explicit permission default and approval never', () => {
    const dump = GOOD.replace('    defaultPreset: orbit-controlled\n', '')
    const result = assertControlledProfile(dump)
    expect(result.ok).toBe(false)
    expect(result.problems.join('\n')).toContain('explicit defaultPreset')
  })

  it('rejects an enabled cordis UI when present', () => {
    const dump = `${GOOD}- id: ui-cordis\n  name: '@deepseek-ai/dsh-client-ui-cordis'\n`
    const result = assertControlledProfile(dump)
    expect(result.ok).toBe(false)
    expect(result.problems.join('\n')).toContain('ui-cordis')
  })

  it('parses the id map without leaking blocks', () => {
    const entries = parseProfileDump(GOOD)
    expect([...entries.keys()]).toContain('approval')
    expect(entries.get('approval')?.block).toContain('policy: never')
  })
})

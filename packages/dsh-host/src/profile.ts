/**
 * T0 profile assertion: the effective `dsh --dump-config` output must disable
 * the listed rows and pin approval/sandbox. User home patches override bundle
 * layers, so this checks the composed config, not just our patch.
 */

export const CONTROLLED_CORE_DISABLED = [
  'tool-plugin-manager',
  'hmr',
  'session-log-deepseek',
  'session-title-llm',
  'goal-round-driver',
  'command-goal',
  'tool-goal',
] as const

export const CONTROLLED_WEB_DISABLED = ['cordis-host-runner', 'cordis-client-runner'] as const

export const CONTROLLED_DISABLED = [...CONTROLLED_CORE_DISABLED, ...CONTROLLED_WEB_DISABLED] as const

export interface ProfileEntry {
  id: string
  disabled: boolean
  block: string
}

export const CONTROLLED_DISABLE_WHEN_PRESENT = ['tool-cordis', 'cordis-inspect-providers', 'ui-cordis', 'preset-cordis'] as const

export interface T0Options {
  /** Expected sandbox mode; checker profiles use read-only. */
  sandboxMode?: 'workspace-write' | 'read-only' | 'danger-full-access'
  /** Require these ids to be present and disabled (default: CONTROLLED_DISABLED). */
  requireDisabled?: readonly string[]
  /** Ids that may be absent, but must be disabled when present. */
  disableWhenPresent?: readonly string[]
}

export interface T0Result {
  ok: boolean
  problems: string[]
  entries: Map<string, ProfileEntry>
}

/** Split top-level `- id:` entries out of the dump text. */
export function parseProfileDump(dump: string): Map<string, ProfileEntry> {
  const entries = new Map<string, ProfileEntry>()
  const lines = dump.split('\n')
  let current: { id: string; start: number } | undefined
  const flush = (end: number): void => {
    if (current === undefined) return
    const block = lines.slice(current.start, end).join('\n')
    entries.set(current.id, {
      id: current.id,
      disabled: /^  disabled: true$/m.test(block),
      block,
    })
    current = undefined
  }
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? ''
    const match = /^- id: (.+)$/.exec(line)
    if (match?.[1] !== undefined) {
      flush(index)
      current = { id: match[1].trim(), start: index }
    } else if (line.startsWith('# ==')) {
      flush(index)
    }
  }
  flush(lines.length)
  return entries
}

export function assertControlledProfile(dump: string, options: T0Options = {}): T0Result {
  const entries = parseProfileDump(dump)
  const problems: string[] = []
  const required = options.requireDisabled ?? CONTROLLED_DISABLED
  for (const id of required) {
    const entry = entries.get(id)
    if (entry === undefined) problems.push(`required row "${id}" is missing from the effective config`)
    else if (!entry.disabled) problems.push(`row "${id}" must be disabled`)
  }
  for (const id of [...CONTROLLED_DISABLE_WHEN_PRESENT, ...(options.disableWhenPresent ?? [])]) {
    const entry = entries.get(id)
    if (entry !== undefined && !entry.disabled) problems.push(`row "${id}" must be disabled when present`)
  }

  const approval = entries.get('approval')
  if (approval === undefined) problems.push('approval row is missing')
  else if (!/^\s+policy:\s*never\s*$/m.test(approval.block)) problems.push('approval policy must be "never"')

  const permission = entries.get('permission')
  if (permission === undefined) problems.push('permission-presents row is missing')
  else {
    if (!/^\s+defaultPreset:\s*\S+\s*$/m.test(permission.block)) problems.push('permission presets must set an explicit defaultPreset')
    if (!/^\s+approval:\s*never\s*$/m.test(permission.block)) problems.push('permission presets must include approval: never')
  }

  const sandbox = entries.get('sandbox-policy')
  const mode = options.sandboxMode ?? 'workspace-write'
  if (sandbox === undefined) problems.push('sandbox-policy row is missing')
  else if (!new RegExp(`^\\s+mode:\\s*${mode}\\s*$`, 'm').test(sandbox.block)) {
    problems.push(`sandbox-policy mode must be "${mode}"`)
  }

  return { ok: problems.length === 0, problems, entries }
}

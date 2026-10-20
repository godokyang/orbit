import { join } from 'node:path'

export const INTEGRATION_CONTRACT = { name: 'orbit-integration', version: '2.0.0', major: 2 } as const

export const CAPABILITIES = {
  launch: { since: '2.0.0', stdin: 'keep-open', process_owner: 'caller' },
  status: { since: '2.0.0' },
  events: { since: '2.0.0', cursor: 'opaque' },
  sessions: { since: '2.0.0', visible_text: true, user_messages: true, activities: true, questions: true, deliveries: true },
  questions: { since: '2.0.0' },
  answer: { since: '2.0.0' },
  stop: { since: '2.0.0', receipt: 'evidence' },
  export: { since: '2.0.0', self_contained: true },

} as const

export interface LaunchSpec {
  kind: 'dsh'
  contract: string
  profile: string
  cwd: string
  argv: string[]
  env: Record<string, string>
  stdin: 'keep-open'
  control_socket: string
  ready: { kind: 'socket'; timeout_ms: number }
}

export function buildLaunchSpec(input: {
  projectRoot: string
  profile?: string
  home?: string
  dshBin?: string
}): LaunchSpec {
  const profile = input.profile ?? 'orbit-node'
  const home = input.home ?? process.env.DSH_HOME ?? join(process.env.HOME ?? '', '.dsh')
  return {
    kind: 'dsh',
    contract: INTEGRATION_CONTRACT.version,
    profile,
    cwd: input.projectRoot,
    argv: ['--profile', profile],
    env: { DSH_HOME: home },
    stdin: 'keep-open',
    control_socket: join(input.projectRoot, '.orbit', 'orbit.sock'),
    ready: { kind: 'socket', timeout_ms: 30_000 },
  }
}

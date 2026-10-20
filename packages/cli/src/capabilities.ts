import { join } from 'node:path'

export const INTEGRATION_CONTRACT = { name: 'orbit-integration', version: '2.0.0-draft', major: 2, draft: true } as const

export const CAPABILITIES = {
  launch: { since: '2.0.0-draft', stdin: 'keep-open', process_owner: 'caller' },
  status: { since: '2.0.0-draft' },
  events: { since: '2.0.0-draft', cursor: 'opaque' },
  sessions: { since: '2.0.0-draft', visible_text: true, user_messages: true, activities: true, questions: true, deliveries: true },
  stop: { since: '2.0.0-draft', receipt: 'evidence' },
  export: { since: '2.0.0-draft', self_contained: true },
  models: { since: '2.0.0-draft', strict_authorization: true },
} as const

export interface LaunchSpec {
  kind: 'dsh'
  contract: string
  draft: true
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
    draft: true,
    profile,
    cwd: input.projectRoot,
    argv: ['--profile', profile],
    env: { DSH_HOME: home },
    stdin: 'keep-open',
    control_socket: join(input.projectRoot, '.orbit', 'orbit.sock'),
    ready: { kind: 'socket', timeout_ms: 30_000 },
  }
}

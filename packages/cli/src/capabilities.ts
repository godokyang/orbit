import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { isAbsolute, join, resolve } from 'node:path'

export const INTEGRATION_CONTRACT = { name: 'orbit-integration', version: '2.0.0', major: 2 } as const

export const CAPABILITIES = {
  launch: { since: '2.0.0', stdin: 'keep-open', process_owner: 'caller' },
  headless: { since: '2.0.0', spec_version: 1, env: ['ORBIT_BOOTSTRAP', 'ORBIT_BOOTSTRAP_RESULT'] },
  resume_from: { since: '2.0.0', action: 'headless', same_root_session: true, resume_wake: false },
  status: { since: '2.0.0' },
  status_by_external_ref: { since: '2.0.0', max_refs: 8, max_length: 256 },
  status_by_session: { since: '2.0.0' },
  check_coverage: { since: '2.0.0' },
  model_authorization: { since: '2.0.0' },
  events: { since: '2.0.0', cursor: 'opaque' },
  sessions: { since: '2.0.0', visible_text: true, user_messages: true, activities: true, questions: true, deliveries: true },
  questions: { since: '2.0.0' },
  answer: { since: '2.0.0' },
  prompt: { since: '2.0.0' },
  abort: { since: '2.0.0', scope: 'session' },
  stop: { since: '2.0.0', receipt: 'evidence' },
  export: { since: '2.0.0', self_contained: true },
  doctor: { since: '2.0.0' },

} as const

export interface LaunchSpec {
  kind: 'dsh'
  contract: string
  command: string
  profile: string
  cwd: string
  argv: string[]
  env: Record<string, string>
  stdin: 'keep-open'
  control_socket: string
  ready: { kind: 'socket'; timeout_ms: number }
  bootstrap?: { path: string; result: string; sha256: string }
}

export function buildLaunchSpec(input: {
  projectRoot: string
  profile?: string
  home?: string
  dshBin?: string
  bootstrap?: string
  result?: string
}): LaunchSpec {
  const profile = input.profile ?? 'orbit-node'
  const home = input.home ?? process.env.DSH_HOME ?? join(process.env.HOME ?? '', '.dsh')
  const spec: LaunchSpec = {
    kind: 'dsh',
    contract: INTEGRATION_CONTRACT.version,
    command: input.dshBin ?? process.env.DSH_BIN ?? 'dsh',
    profile,
    cwd: input.projectRoot,
    argv: ['--profile', profile],
    env: { DSH_HOME: home },
    stdin: 'keep-open',
    control_socket: join(input.projectRoot, '.orbit', 'orbit.sock'),
    ready: { kind: 'socket', timeout_ms: 30_000 },
  }
  if (input.bootstrap !== undefined) {
    const path = resolve(input.bootstrap)
    if (!isAbsolute(path)) throw new Error('bootstrap path must be absolute')
    const result = resolve(input.result ?? `${path}.result.json`)
    const sha256 = createHash('sha256').update(readFileSync(path)).digest('hex')
    spec.bootstrap = { path, result, sha256 }
    spec.env.ORBIT_BOOTSTRAP = path
    spec.env.ORBIT_BOOTSTRAP_RESULT = result
  }
  return spec
}

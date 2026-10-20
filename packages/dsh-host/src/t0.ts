#!/usr/bin/env node
// T0 entry: read the effective profile config and refuse rows that would let a
// model run code in the host, re-open goals, or skip approval/sandbox policy.
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { assertControlledProfile, CONTROLLED_CORE_DISABLED, CONTROLLED_DISABLED } from './profile.js'

interface Args {
  profile?: string
  dump?: string
  sandbox: 'workspace-write' | 'read-only' | 'danger-full-access'
  role: 'app' | 'node' | 'checker'
}

function parse(argv: string[]): Args {
  const args: Args = { sandbox: 'workspace-write', role: 'app' }
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--profile') args.profile = argv[++index]
    else if (arg === '--dump') args.dump = argv[++index]
    else if (arg === '--role') {
      const value = argv[++index]
      if (value !== 'app' && value !== 'node' && value !== 'checker') throw new Error(`invalid --role ${String(value)}`)
      args.role = value
    } else if (arg === '--sandbox') {
      const value = argv[++index]
      if (value !== 'workspace-write' && value !== 'read-only' && value !== 'danger-full-access') {
        throw new Error(`invalid --sandbox ${String(value)}`)
      }
      args.sandbox = value
    }
  }
  return args
}

function main(): number {
  const args = parse(process.argv.slice(2))
  let dump: string
  if (args.dump !== undefined) {
    dump = readFileSync(args.dump, 'utf8')
  } else {
    if (args.profile === undefined) {
      console.error('orbit-t0: --profile or --dump is required')
      return 2
    }
    const bin = process.env.DSH_BIN ?? '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh'
    dump = execFileSync(bin, ['--profile', args.profile, '--dump-config'], { encoding: 'utf8' })
  }
  const result = assertControlledProfile(dump, {
    sandboxMode: args.sandbox,
    requireDisabled: args.role === 'app' ? CONTROLLED_DISABLED : CONTROLLED_CORE_DISABLED,
  })
  if (result.ok) {
    console.log(`orbit-t0: controlled profile OK (${result.entries.size} rows, sandbox ${args.sandbox})`)
    return 0
  }
  for (const problem of result.problems) console.error(`orbit-t0: ${problem}`)
  return 1
}

process.exitCode = main()

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'

export interface DoctorCheck {
  name: string
  ok: boolean
  detail: string
}

export interface DoctorReport {
  ok: boolean
  contract: string
  home: string
  profile: string
  dsh: { binary: string; version: string | null }
  checks: DoctorCheck[]
}

/** Local, read-only install check: profile exists, bundle is enabled, host dist is present. */
export function doctor(home: string, profile: string): DoctorReport {
  const checks: DoctorCheck[] = []
  const profileDir = join(home, 'profiles', profile)
  const manifestPath = join(profileDir, 'package.json')
  let version: string | null = null
  const binary = process.env.DSH_BIN ?? 'dsh'
  try {
    const result = spawnSync(binary, ['--version'], { encoding: 'utf8', timeout: 10_000 })
    version = result.status === 0 ? result.stdout.trim() : null
    checks.push({ name: 'dsh_binary', ok: result.status === 0, detail: result.status === 0 ? version ?? '' : (result.stderr || 'exit non-zero').trim().slice(0, 200) })
  } catch (error) {
    checks.push({ name: 'dsh_binary', ok: false, detail: (error as Error).message })
  }

  let bundles: string[] = []
  if (!existsSync(manifestPath)) {
    checks.push({ name: 'profile_manifest', ok: false, detail: `${manifestPath} is missing` })
  } else {
    try {
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as { dsh?: { profile?: { bundles?: string[] } } }
      bundles = manifest.dsh?.profile?.bundles ?? []
      checks.push({ name: 'profile_manifest', ok: true, detail: manifestPath })
    } catch (error) {
      checks.push({ name: 'profile_manifest', ok: false, detail: (error as Error).message })
    }
  }
  checks.push({
    name: 'bundle_enabled',
    ok: bundles.includes('@zeen/orbit'),
    detail: bundles.includes('@zeen/orbit') ? '@zeen/orbit' : `bundles: ${bundles.join(', ') || '(none)'}`,
  })
  const hostDist = join(profileDir, 'node_modules', '@zeen', 'orbit', 'dist', 'host.mjs')
  checks.push({ name: 'host_dist', ok: existsSync(hostDist), detail: hostDist })
  return {
    ok: checks.every((check) => check.ok),
    contract: '2.0.0',
    home,
    profile,
    dsh: { binary, version },
    checks,
  }
}

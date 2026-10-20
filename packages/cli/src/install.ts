import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

export type OrbitMode = 'app' | 'node' | 'checker'

export interface InstallOptions {
  home: string
  profile: string
  template: string
  mode: OrbitMode
  dshBin?: string
  packageRoot?: string
  skipT0?: boolean
}

export interface InstallReport {
  ok: boolean
  home: string
  profile: string
  package_root: string
  overlay: string
  t0: { ok: boolean; detail: string } | null
}

const OVERLAYS: Record<OrbitMode, string> = {
  app: 'orbit-app.patch.yml',
  node: 'orbit-node.patch.yml',
  checker: 'orbit-checker.patch.yml',
}

/** Install the already-built single package into one DSH profile. */
export function installProfile(options: InstallOptions): InstallReport {
  const home = resolve(options.home)
  const packageRoot = resolve(options.packageRoot ?? join(dirname(fileURLToPath(import.meta.url)), '..'))
  const profileDir = join(home, 'profiles', options.profile)
  const dsh = options.dshBin ?? process.env.DSH_BIN ?? 'dsh'
  if (!existsSync(join(packageRoot, 'dist', 'host.mjs'))) {
    throw new Error(`package root has no built host: ${packageRoot}`)
  }
  if (!existsSync(join(profileDir, 'package.json'))) {
    mkdirSync(dirname(profileDir), { recursive: true, mode: 0o700 })
    execFileSync(dsh, ['--profile', options.profile, '--from-default-profile', options.template, '--dump-config'], {
      env: { ...process.env, DSH_HOME: home },
      stdio: 'ignore',
    })
  }
  const target = join(profileDir, 'node_modules', '@zeen', 'orbit')
  rmSync(target, { recursive: true, force: true })
  mkdirSync(target, { recursive: true })
  for (const entry of ['package.json', 'cordis.patch.yml', 'profiles', 'dist']) {
    const source = join(packageRoot, entry)
    if (existsSync(source)) cpSync(source, join(target, entry), { recursive: true })
  }
  const manifestPath = join(profileDir, 'package.json')
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as { dsh?: { profile?: { bundles?: string[] } } }
  manifest.dsh ??= {}
  manifest.dsh.profile ??= {}
  const bundles = new Set(manifest.dsh.profile.bundles ?? [])
  bundles.add('@zeen/orbit')
  manifest.dsh.profile.bundles = [...bundles]
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
  const overlay = OVERLAYS[options.mode]
  cpSync(join(packageRoot, 'profiles', overlay), join(profileDir, 'cordis.patch.yml'))
  let t0: InstallReport['t0'] = null
  if (options.skipT0 !== true) {
    const t0Path = join(target, 'dist', 't0.mjs')
    const role = options.mode
    const result = execFileSync(process.execPath, [t0Path, '--profile', options.profile, '--role', role, '--sandbox', options.mode === 'checker' ? 'read-only' : 'workspace-write'], {
      env: { ...process.env, DSH_HOME: home, ...(options.dshBin === undefined ? {} : { DSH_BIN: options.dshBin }) },
      encoding: 'utf8',
    })
    t0 = { ok: true, detail: result.trim() }
  }
  return {
    ok: true,
    home,
    profile: options.profile,
    package_root: packageRoot,
    overlay,
    t0,
  }
}

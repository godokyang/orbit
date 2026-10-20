#!/usr/bin/env node
// Local development bootstrap for a controlled Orbit profile. This copies the
// built host/bundle into the profile's node_modules (pnpm cannot install
// workspace:* dependencies outside the workspace) and writes the bundle list.
// The published single-package installer replaces this in phase D.
import { execFileSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 ? process.argv[index + 1] : fallback
}

const repo = resolve(arg('repo', fileURLToPath(new URL('../../..', import.meta.url))))
const home = resolve(arg('home', process.env.DSH_HOME ?? '/tmp/orbit-profile'))
const profile = arg('profile', 'orbit-app')
const template = arg('template', 'web')
const checker = process.argv.includes('--checker')
const dsh = process.env.DSH_BIN ?? '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh'
const packageDist = join(repo, 'packages/orbit/dist/host.mjs')
const t0 = join(repo, 'packages/orbit/dist/t0.mjs')

if (!existsSync(packageDist)) throw new Error(`missing ${packageDist}; build @orbit/orbit first`)
if (!existsSync(t0)) throw new Error(`missing ${t0}; build @orbit/orbit first`)

const profileDir = join(home, 'profiles', profile)
if (!existsSync(join(profileDir, 'package.json'))) {
  execFileSync(dsh, ['--profile', profile, '--from-default-profile', template, '--dump-config'], {
    env: { ...process.env, DSH_HOME: home },
    stdio: 'inherit',
  })
}

function installPackage(name, source) {
  const target = join(profileDir, 'node_modules', '@orbit', name)
  rmSync(target, { recursive: true, force: true })
  mkdirSync(target, { recursive: true })
  cpSync(join(source, 'package.json'), join(target, 'package.json'))
  if (existsSync(join(source, 'dist'))) cpSync(join(source, 'dist'), join(target, 'dist'), { recursive: true })
  if (existsSync(join(source, 'cordis.patch.yml'))) cpSync(join(source, 'cordis.patch.yml'), join(target, 'cordis.patch.yml'))
  if (existsSync(join(source, 'profiles'))) cpSync(join(source, 'profiles'), join(target, 'profiles'), { recursive: true })
  return target
}

installPackage('orbit', join(repo, 'packages/orbit'))

const manifestPath = join(profileDir, 'package.json')
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
manifest.dsh ??= { profile: {} }
manifest.dsh.profile ??= {}
const bundles = new Set(manifest.dsh.profile.bundles ?? [])
bundles.add('@orbit/orbit')
manifest.dsh.profile.bundles = [...bundles]
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)

const overlayName = checker ? 'orbit-checker.patch.yml' : 'orbit-app.patch.yml'
const overlay = join(repo, 'packages/orbit/profiles', overlayName)
cpSync(overlay, join(profileDir, 'cordis.patch.yml'))

const dump = execFileSync(dsh, ['--profile', profile, '--dump-config'], {
  env: { ...process.env, DSH_HOME: home },
  encoding: 'utf8',
})
const dumpPath = join(home, `${profile}-dump.yml`)
writeFileSync(dumpPath, dump)
execFileSync(process.execPath, [t0, '--dump', dumpPath, '--sandbox', checker ? 'read-only' : 'workspace-write', '--role', checker ? 'checker' : 'app'], {
  stdio: 'inherit',
})
console.log(`orbit-profile: ${profileDir} ready (bundle @orbit/orbit)`)

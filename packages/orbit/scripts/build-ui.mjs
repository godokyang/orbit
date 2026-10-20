#!/usr/bin/env node
// Compile ui-src/index.ts to the DSH client loader-factory format. No DSH
// checkout is needed: the panel is self-contained except for React, which the
// client loader provides through the factory's require.
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const work = mkdtempSync(join(tmpdir(), 'orbit-ui-'))
try {
  execFileSync(process.execPath, [join(root, '..', '..', 'node_modules', 'typescript', 'bin', 'tsc'),
    join(root, 'ui-src', 'index.ts'), '--outDir', work, '--module', 'commonjs', '--target', 'es2022',
    '--moduleResolution', 'node', '--skipLibCheck', '--esModuleInterop', '--ignoreDeprecations', '6.0', '--ignoreConfig'], { stdio: 'inherit' })
  const compiled = readFileSync(join(work, 'index.js'), 'utf8')
  const bundle = `window.__ModuleLoader__.load({\n  id: "@zeen/orbit",\n  factory: (require) => {\n    var module = { exports: {} };\n    var exports = module.exports;\n${compiled}\n    return module.exports;\n  },\n});\n`
  writeFileSync(join(root, 'dist', 'client.js'), bundle)
  console.log('orbit-ui: dist/client.js')
} finally {
  rmSync(work, { recursive: true, force: true })
}

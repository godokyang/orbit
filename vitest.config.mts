import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['packages/*/test/**/*.test.ts'],
    // The OMP-era bun tests under runners/ are not part of the TypeScript suite.
    exclude: ['runners/**', 'node_modules/**', 'lib/**'],
    testTimeout: 15_000,
  },
})

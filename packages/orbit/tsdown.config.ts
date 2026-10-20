import { defineConfig } from 'tsdown'

export default defineConfig({
  entry: ['src/host.ts', 'src/cli.ts', 'src/t0.ts'],
  format: ['esm'],
  dts: true,
  clean: true,
  sourcemap: true,
  noExternal: ['@orbit/core', '@orbit/dsh-host', '@orbit/cli'],
})

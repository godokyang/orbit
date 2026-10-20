import { defineConfig } from 'tsdown'

export default defineConfig({
  entry: ['src/index.ts', 'src/t0.ts'],
  format: ['esm'],
  dts: true,
  clean: true,
  noExternal: ['@orbit/core'],
  sourcemap: true,
})

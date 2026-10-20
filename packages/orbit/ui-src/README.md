# Orbit browser panel source

Build with `pnpm --filter @zeen/orbit build`. `scripts/build-ui.mjs` compiles this
file with the repository TypeScript and wraps it in the DSH client loader
factory format; React is resolved by the DSH client loader at runtime.

No DSH source checkout is needed. The generated `dist/client.js` ships with the
package and is declared through `dsh.client` / `exports["./client"]`.

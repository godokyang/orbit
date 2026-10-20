# Orbit browser panel source

This source is built with DSH's client bundler (`packages/client/tsdown.client.ts`)
from a DSH source checkout, then copied to `packages/orbit/dist/client.js`.

Build recipe (DSH checkout required):

1. Copy this directory to `<dsh>/packages/client/ui-orbit/src/client/`.
2. Use the `@zeen/orbit` package manifest with `dsh.client`.
3. Run `pnpm --filter @zeen/orbit bundle` in the DSH checkout.
4. Copy `lib/client.js` back to `packages/orbit/dist/client.js`.

The bundle is committed because the DSH client toolchain is not part of this
repository. Replacing this with a reproducible in-repo build is a D2 task.

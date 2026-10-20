# @zeen/orbit

The single Orbit DSH bundle: host service, CLI (`orbit`), T0 (`orbit-t0`) and
the controlled profile patches. `dist/` is self-contained except for
`@deepseek-ai/*` peers resolved by the DSH profile. The package is private
until the final npm scope and version are approved (checkpoint 1).

```sh
pnpm --filter @zeen/orbit build
node packages/orbit/scripts/derive-profile.mjs --home /tmp/orbit-profile --profile orbit-app --template web
node packages/orbit/scripts/derive-profile.mjs --home /tmp/orbit-checker --profile orbit-checker --template sdk --checker
```

`derive-profile.mjs` copies the built package into the profile, adds
`@zeen/orbit` to `dsh.profile.bundles`, applies the app or checker overlay and
runs T0. The local copy is a development shortcut; the published installer will
use `dsh plugin add` and the DSH profile manager.

Patches:

- `cordis.patch.yml` — shared controlled rows, approval/sandbox, permission preset, host insert.
- `profiles/orbit-app.patch.yml` — web-only Cordis runners and Creator preset off.
- `profiles/orbit-checker.patch.yml` — read-only sandbox/permission.
- `profiles/orbit-node.patch.yml` — Loom node sandbox default.
